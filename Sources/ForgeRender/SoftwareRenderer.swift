import ForgeCore
import ForgeKernel
import Foundation

/// A rendered frame: color plus per-pixel depth and pick IDs (the same buffers the Metal
/// viewport produces on the GPU).
public struct RenderImage: Sendable {
    public let width: Int
    public let height: Int
    /// RGBA8, row-major, top row first.
    public var rgba: [UInt8]
    /// NDC depth in [0, 1]; 1 = background.
    public var depth: [Float]
    /// objectID + 1 per pixel (0 = background).
    public var objects: [UInt32]
    /// Element per pixel: face index + 1, or (edge index + 1) | edgeFlag; 0 = none.
    public var elements: [UInt32]

    public static let edgeFlag: UInt32 = 0x8000_0000

    public func hit(x: Int, y: Int) -> PickHit? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = y * width + x
        guard objects[i] != 0, elements[i] != 0 else { return nil }
        let e = elements[i]
        if e & Self.edgeFlag != 0 {
            return PickHit(objectID: objects[i] - 1, element: .edge, index: (e & ~Self.edgeFlag) - 1, point: nil)
        }
        return PickHit(objectID: objects[i] - 1, element: .face, index: e - 1, point: nil)
    }

    /// Pick with a tolerance radius, preferring edges (as CAD selection does) and then the
    /// hit nearest the cursor.
    public func pick(x: Int, y: Int, radius: Int = 3) -> PickHit? {
        var best: (PickHit, Int)?
        for dy in -radius...radius {
            for dx in -radius...radius {
                guard let h = hit(x: x + dx, y: y + dy) else { continue }
                let d2 = dx * dx + dy * dy
                guard d2 <= radius * radius else { continue }
                // Edges win within the radius; faces only at the exact pixel ring nearest.
                let score = (h.element == .edge ? 0 : 1000) + d2
                if best == nil || score < best!.1 { best = (h, score) }
            }
        }
        return best?.0
    }
}

public struct RenderOptions: Sendable {
    public var width: Int
    public var height: Int
    public var style: RenderStyle
    public var background: RGBA
    /// Supersampling factor for anti-aliasing (1 = off).
    public var supersample: Int

    public init(width: Int = 800, height: Int = 600, style: RenderStyle = .shadedWithEdges, background: RGBA = .background, supersample: Int = 2) {
        self.width = width
        self.height = height
        self.style = style
        self.background = background
        self.supersample = supersample
    }
}

/// Headless CPU rasterizer. Used by `render_view` (agents get pictures without a GPU or a
/// window), for golden-image tests, and as the reference for the Metal viewport's picking.
public enum SoftwareRenderer {
    public static func render(_ scene: RenderScene, camera: Camera, options: RenderOptions) -> RenderImage {
        let ss = max(1, min(options.supersample, 4))
        let W = options.width * ss, H = options.height * ss
        var color = [Float](repeating: 0, count: W * H * 3)
        for i in 0..<(W * H) {
            color[3 * i] = options.background.r
            color[3 * i + 1] = options.background.g
            color[3 * i + 2] = options.background.b
        }
        var depth = [Float](repeating: 1, count: W * H)
        var objects = [UInt32](repeating: 0, count: W * H)
        var elements = [UInt32](repeating: 0, count: W * H)

        let aspect = Double(options.width) / Double(options.height)
        let bounds = scene.bounds
        let radius = bounds.map { max(($0.center - camera.target).length + $0.diagonal / 2, 1e-3) } ?? 1
        let viewProj = camera.projectionMatrix(aspect: aspect, sceneRadius: radius) * camera.viewMatrix
        let lightDir = (camera.back + camera.up * 0.25 + camera.right * 0.15).normalized
        let viewDir = camera.back

        func project(_ p: Vec3) -> (Float, Float, Float)? {
            let (x, y, z, w) = viewProj.transform(p)
            guard w > 1e-9 else { return nil }
            let nx = x / w, ny = y / w, nz = z / w
            return (Float((nx + 1) * 0.5 * Double(W)), Float((1 - ny) * 0.5 * Double(H)), Float(nz))
        }

        let drawFaces = options.style != .wireframe
        let drawEdges = options.style != .shaded
        let hlr = options.style == .hiddenLinesRemoved

        // ---- triangles
        if drawFaces {
            for item in scene.items {
                let mesh = item.mesh
                var screen = [(Float, Float, Float)?](repeating: nil, count: mesh.vertexCount)
                for v in 0..<mesh.vertexCount { screen[v] = project(mesh.position(v)) }
                for t in 0..<mesh.triangleCount {
                    let i0 = Int(mesh.indices[3 * t]), i1 = Int(mesh.indices[3 * t + 1]), i2 = Int(mesh.indices[3 * t + 2])
                    guard let a = screen[i0], let b = screen[i1], let c = screen[i2] else { continue }
                    let face = mesh.triangleFaces[t]
                    let highlighted = item.highlightAll || item.highlightedFaces.contains(face)
                    let base = hlr ? RGBA.white : (highlighted ? RGBA.highlight : item.color)
                    let n0 = normal(mesh, i0), n1 = normal(mesh, i1), n2 = normal(mesh, i2)
                    rasterTriangle(
                        a, b, c, W: W, H: H,
                        shade: { w0, w1, w2 in
                            if hlr { return (1, 1, 1) }
                            let n = (n0 * Double(w0) + n1 * Double(w1) + n2 * Double(w2)).normalized
                            return shade(base: base, normal: n, light: lightDir, view: viewDir)
                        },
                        objectID: item.objectID + 1, element: face + 1,
                        color: &color, depth: &depth, objects: &objects, elements: &elements)
                }
            }
        }

        // ---- edges (depth-tested with a bias so they sit on top of their faces)
        if drawEdges {
            let lineWidth = ss >= 2 ? ss : 1
            for item in scene.items {
                let mesh = item.mesh
                for e in 0..<mesh.edgeCount {
                    let start = Int(mesh.edgeOffsets[e]), end = Int(mesh.edgeOffsets[e + 1])
                    let edgeID = mesh.edgeIDs[e]
                    let highlighted = item.highlightAll || item.highlightedEdges.contains(edgeID)
                    let c = highlighted ? RGBA.highlight : (item.edgeColors[edgeID] ?? RGBA.edge)
                    guard end - start >= 2 else { continue }
                    for k in start..<(end - 1) {
                        let p = Vec3(Double(mesh.edgePoints[3 * k]), Double(mesh.edgePoints[3 * k + 1]), Double(mesh.edgePoints[3 * k + 2]))
                        let q = Vec3(Double(mesh.edgePoints[3 * k + 3]), Double(mesh.edgePoints[3 * k + 4]), Double(mesh.edgePoints[3 * k + 5]))
                        guard let a = project(p), let b = project(q) else { continue }
                        rasterLine(
                            a, b, width: lineWidth, W: W, H: H, rgb: (c.r, c.g, c.b), depthTest: drawFaces,
                            objectID: item.objectID + 1, element: (edgeID + 1) | RenderImage.edgeFlag,
                            color: &color, depth: &depth, objects: &objects, elements: &elements)
                    }
                }
            }
        }

        // ---- resolve supersampling: average color, take IDs/depth from the centre sample
        let w = options.width, h = options.height
        var out = RenderImage(
            width: w, height: h, rgba: [UInt8](repeating: 255, count: w * h * 4), depth: [Float](repeating: 1, count: w * h),
            objects: [UInt32](repeating: 0, count: w * h), elements: [UInt32](repeating: 0, count: w * h))
        let inv = 1 / Float(ss * ss)
        for y in 0..<h {
            for x in 0..<w {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let i = (y * ss + sy) * W + (x * ss + sx)
                        r += color[3 * i]
                        g += color[3 * i + 1]
                        b += color[3 * i + 2]
                    }
                }
                let o = y * w + x
                out.rgba[4 * o] = toByte(r * inv)
                out.rgba[4 * o + 1] = toByte(g * inv)
                out.rgba[4 * o + 2] = toByte(b * inv)
                let c = (y * ss + ss / 2) * W + (x * ss + ss / 2)
                // Prefer any edge sample within the pixel so thin edges stay pickable.
                var obj = objects[c], el = elements[c], dep = depth[c]
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let i = (y * ss + sy) * W + (x * ss + sx)
                        if elements[i] & RenderImage.edgeFlag != 0 {
                            obj = objects[i]
                            el = elements[i]
                            dep = depth[i]
                        }
                    }
                }
                out.objects[o] = obj
                out.elements[o] = el
                out.depth[o] = dep
            }
        }
        return out
    }

    static func toByte(_ v: Float) -> UInt8 {
        // sRGB-ish gamma for display.
        let g = powf(max(0, min(1, v)), 1 / 1.1)
        return UInt8(max(0, min(255, (g * 255).rounded())))
    }

    static func normal(_ m: Mesh, _ i: Int) -> Vec3 {
        guard m.normals.count >= 3 * i + 3 else { return .unitZ }
        return Vec3(Double(m.normals[3 * i]), Double(m.normals[3 * i + 1]), Double(m.normals[3 * i + 2]))
    }

    static func shade(base: RGBA, normal n: Vec3, light: Vec3, view: Vec3) -> (Float, Float, Float) {
        // Two-sided headlight Lambert + Blinn-Phong highlight + ambient.
        var nn = n
        if nn.dot(view) < 0 { nn = -nn }
        let diffuse = max(0, nn.dot(light))
        let halfV = (light + view).normalized
        let spec = pow(max(0, nn.dot(halfV)), 40) * 0.25
        let ambient = 0.3
        let k = Float(ambient + 0.7 * diffuse)
        let s = Float(spec)
        return (min(1, base.r * k + s), min(1, base.g * k + s), min(1, base.b * k + s))
    }

    // Half-open top-left rule rasterization with linear (screen-space) depth, which is
    // exact for NDC depth.
    static func rasterTriangle(
        _ a: (Float, Float, Float), _ b: (Float, Float, Float), _ c: (Float, Float, Float), W: Int, H: Int,
        shade: (Float, Float, Float) -> (Float, Float, Float), objectID: UInt32, element: UInt32,
        color: inout [Float], depth: inout [Float], objects: inout [UInt32], elements: inout [UInt32]
    ) {
        let area = (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
        guard abs(area) > 1e-12 else { return }
        let minX = max(0, Int(floor(min(a.0, b.0, c.0)))), maxX = min(W - 1, Int(ceil(max(a.0, b.0, c.0))))
        let minY = max(0, Int(floor(min(a.1, b.1, c.1)))), maxY = min(H - 1, Int(ceil(max(a.1, b.1, c.1))))
        guard minX <= maxX, minY <= maxY else { return }
        let invArea = 1 / area
        for y in minY...maxY {
            let py = Float(y) + 0.5
            for x in minX...maxX {
                let px = Float(x) + 0.5
                let w0 = ((b.0 - px) * (c.1 - py) - (b.1 - py) * (c.0 - px)) * invArea
                let w1 = ((c.0 - px) * (a.1 - py) - (c.1 - py) * (a.0 - px)) * invArea
                let w2 = 1 - w0 - w1
                guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                let z = w0 * a.2 + w1 * b.2 + w2 * c.2
                guard z >= 0, z <= 1 else { continue }
                let i = y * W + x
                guard z < depth[i] else { continue }
                depth[i] = z
                let (r, g, bb) = shade(w0, w1, w2)
                color[3 * i] = r
                color[3 * i + 1] = g
                color[3 * i + 2] = bb
                objects[i] = objectID
                elements[i] = element
            }
        }
    }

    static func rasterLine(
        _ a: (Float, Float, Float), _ b: (Float, Float, Float), width: Int, W: Int, H: Int, rgb: (Float, Float, Float),
        depthTest: Bool, objectID: UInt32, element: UInt32,
        color: inout [Float], depth: inout [Float], objects: inout [UInt32], elements: inout [UInt32]
    ) {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let steps = max(1, Int(ceil(max(abs(dx), abs(dy)))))
        let half = width / 2
        let bias: Float = 2e-3
        for s in 0...steps {
            let t = Float(s) / Float(steps)
            let x = Int((a.0 + dx * t).rounded(.down)), y = Int((a.1 + dy * t).rounded(.down))
            let z = a.2 + (b.2 - a.2) * t
            for oy in -half...(width - 1 - half) {
                for ox in -half...(width - 1 - half) {
                    let px = x + ox, py = y + oy
                    guard px >= 0, py >= 0, px < W, py < H else { continue }
                    let i = py * W + px
                    if depthTest && z - bias > depth[i] { continue }
                    depth[i] = min(depth[i], z)
                    color[3 * i] = rgb.0
                    color[3 * i + 1] = rgb.1
                    color[3 * i + 2] = rgb.2
                    objects[i] = objectID
                    elements[i] = element
                }
            }
        }
    }
}
