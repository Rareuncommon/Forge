// Metal viewport renderer (macOS). Mirrors SoftwareRenderer: shaded triangles + edges, and a
// pick pass writing object/element IDs to integer render targets (GPU picking).
//
// STATUS: written against the Metal API but NOT yet compiled or run — the M0 development
// environment was Linux. Verification on macOS 27 is the first item in PROGRESS.md.

#if canImport(MetalKit)
import ForgeCore
import ForgeKernel
import Metal
import MetalKit

public final class MetalViewportRenderer: NSObject, MTKViewDelegate {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let shadedPipeline: any MTLRenderPipelineState
    private let linePipeline: any MTLRenderPipelineState
    private let pickTrianglePipeline: any MTLRenderPipelineState
    private let pickLinePipeline: any MTLRenderPipelineState
    private let depthState: any MTLDepthStencilState

    public var camera = Camera()
    public var style: RenderStyle = .shadedWithEdges
    public var background = RGBA.background
    private var items: [GPUItem] = []
    private var sceneBounds: BoundingBox?

    struct GPUItem {
        var objectID: UInt32
        var triangles: (any MTLBuffer)?
        var triangleVertexCount: Int
        var lines: (any MTLBuffer)?
        var lineVertexCount: Int
        var color: RGBA
    }

    // Vertex layouts (must match the MSL structs below).
    // TriVertex: packed_float3 position, packed_float3 normal, uint element, uint highlighted = 32 bytes
    // LineVertex: packed_float3 position, uint element, uint highlighted, packed_float3 color = 32 bytes
    static let triStride = 32
    static let lineStride = 32

    public init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(), colorFormat: MTLPixelFormat = .bgra8Unorm_srgb) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            func pipeline(_ vfn: String, _ ffn: String, colors: [MTLPixelFormat]) throws -> any MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vfn)
                d.fragmentFunction = library.makeFunction(name: ffn)
                for (i, f) in colors.enumerated() { d.colorAttachments[i].pixelFormat = f }
                d.depthAttachmentPixelFormat = .depth32Float
                return try device.makeRenderPipelineState(descriptor: d)
            }
            shadedPipeline = try pipeline("tri_vertex", "tri_fragment", colors: [colorFormat])
            linePipeline = try pipeline("line_vertex", "line_fragment", colors: [colorFormat])
            pickTrianglePipeline = try pipeline("tri_vertex", "pick_tri_fragment", colors: [.r32Uint, .r32Uint])
            pickLinePipeline = try pipeline("line_vertex", "pick_line_fragment", colors: [.r32Uint, .r32Uint])
        } catch {
            return nil
        }
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .lessEqual
        ds.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: ds) else { return nil }
        depthState = depth
        super.init()
    }

    /// Upload a scene. Triangles are de-indexed so each vertex carries its B-rep face index
    /// (portable alternative to [[primitive_id]]; see docs/adr/0009-viewport-rendering.md).
    public func setScene(_ scene: RenderScene) {
        sceneBounds = scene.bounds
        items = scene.items.map { item in
            let m = item.mesh
            var tri = [UInt8]()
            tri.reserveCapacity(m.triangleCount * 3 * Self.triStride)
            for t in 0..<m.triangleCount {
                let face = m.triangleFaces[t]
                let hl: UInt32 = item.highlightAll || item.highlightedFaces.contains(face) ? 1 : 0
                for k in 0..<3 {
                    let v = Int(m.indices[3 * t + k])
                    append(&tri, floats: [m.positions[3 * v], m.positions[3 * v + 1], m.positions[3 * v + 2]])
                    append(&tri, floats: [m.normals[3 * v], m.normals[3 * v + 1], m.normals[3 * v + 2]])
                    append(&tri, uints: [face + 1, hl])
                }
            }
            var lines = [UInt8]()
            for e in 0..<m.edgeCount {
                let s = Int(m.edgeOffsets[e]), en = Int(m.edgeOffsets[e + 1])
                guard en - s >= 2 else { continue }
                let id = (m.edgeIDs[e] + 1) | RenderImage.edgeFlag
                let hl: UInt32 = item.highlightAll || item.highlightedEdges.contains(m.edgeIDs[e]) ? 1 : 0
                let color = item.edgeColors[m.edgeIDs[e]] ?? RGBA.edge
                for k in s..<(en - 1) {
                    for p in [k, k + 1] {
                        append(&lines, floats: [m.edgePoints[3 * p], m.edgePoints[3 * p + 1], m.edgePoints[3 * p + 2]])
                        append(&lines, uints: [id, hl])
                        append(&lines, floats: [color.r, color.g, color.b])
                    }
                }
            }
            return GPUItem(
                objectID: item.objectID,
                triangles: tri.isEmpty ? nil : device.makeBuffer(bytes: tri, length: tri.count, options: .storageModeShared),
                triangleVertexCount: m.triangleCount * 3,
                lines: lines.isEmpty ? nil : device.makeBuffer(bytes: lines, length: lines.count, options: .storageModeShared),
                lineVertexCount: lines.count / Self.lineStride, color: item.color)
        }
    }

    private func append(_ buf: inout [UInt8], floats: [Float]) {
        for f in floats { withUnsafeBytes(of: f.bitPattern.littleEndian) { buf.append(contentsOf: $0) } }
    }

    private func append(_ buf: inout [UInt8], uints: [UInt32]) {
        for u in uints { withUnsafeBytes(of: u.littleEndian) { buf.append(contentsOf: $0) } }
    }

    /// Uniforms: float4x4 viewProj; float4 color; float4 highlight; float4 lightDir; float4 viewDir; uint4 ids.
    private func uniforms(aspect: Double, item: GPUItem, lineColor: RGBA? = nil) -> [Float] {
        let radius = sceneBounds.map { max(($0.center - camera.target).length + $0.diagonal / 2, 1e-3) } ?? 1
        let vp = camera.projectionMatrix(aspect: aspect, sceneRadius: radius) * camera.viewMatrix
        let light = (camera.back + camera.up * 0.25 + camera.right * 0.15).normalized
        let c = lineColor ?? (style == .hiddenLinesRemoved ? .white : item.color)
        let hlrFlag: UInt32 = style == .hiddenLinesRemoved ? 1 : 0
        return vp.floats + [c.r, c.g, c.b, c.a] + [RGBA.highlight.r, RGBA.highlight.g, RGBA.highlight.b, 1]
            + [Float(light.x), Float(light.y), Float(light.z), 0] + [Float(camera.back.x), Float(camera.back.y), Float(camera.back.z), 0]
            + [Float(bitPattern: item.objectID + 1), Float(bitPattern: hlrFlag), 0, 0]
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let cmd = queue.makeCommandBuffer()
        else { return }
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(background.r), green: Double(background.g), blue: Double(background.b), alpha: 1)
        pass.depthAttachment.clearDepth = 1
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let aspect = Double(view.drawableSize.width / max(view.drawableSize.height, 1))
        encode(enc, aspect: aspect, pick: false)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func encode(_ enc: any MTLRenderCommandEncoder, aspect: Double, pick: Bool) {
        enc.setDepthStencilState(depthState)
        if style != .wireframe {
            enc.setRenderPipelineState(pick ? pickTrianglePipeline : shadedPipeline)
            for item in items {
                guard let tri = item.triangles else { continue }
                var u = uniforms(aspect: aspect, item: item)
                enc.setVertexBuffer(tri, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: u.count * 4, index: 1)
                enc.setFragmentBytes(&u, length: u.count * 4, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: item.triangleVertexCount)
            }
        }
        if style != .shaded {
            enc.setRenderPipelineState(pick ? pickLinePipeline : linePipeline)
            for item in items {
                guard let lines = item.lines else { continue }
                var u = uniforms(aspect: aspect, item: item, lineColor: .edge)
                enc.setVertexBuffer(lines, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: u.count * 4, index: 1)
                enc.setFragmentBytes(&u, length: u.count * 4, index: 1)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: item.lineVertexCount)
            }
        }
    }

    /// GPU pick at a drawable-pixel position (origin top-left). Renders the ID pass into a
    /// small offscreen target around the cursor and applies the same edge-preferring rule as
    /// `RenderImage.pick`.
    public func pick(x: Int, y: Int, drawableWidth: Int, drawableHeight: Int, radius: Int = 4) -> PickHit? {
        guard drawableWidth > 0, drawableHeight > 0 else { return nil }
        func target(_ format: MTLPixelFormat) -> (any MTLTexture)? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: drawableWidth, height: drawableHeight, mipmapped: false)
            d.usage = [.renderTarget]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let objTex = target(.r32Uint), let elTex = target(.r32Uint), let depthTex = target(.depth32Float),
            let cmd = queue.makeCommandBuffer()
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        for (i, tex) in [objTex, elTex].enumerated() {
            pass.colorAttachments[i].texture = tex
            pass.colorAttachments[i].loadAction = .clear
            pass.colorAttachments[i].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[i].storeAction = .store
        }
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.loadAction = .clear
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(enc, aspect: Double(drawableWidth) / Double(drawableHeight), pick: true)
        enc.endEncoding()

        let x0 = max(0, x - radius), y0 = max(0, y - radius)
        let w = min(drawableWidth - x0, 2 * radius + 1), h = min(drawableHeight - y0, 2 * radius + 1)
        guard w > 0, h > 0, let readback = device.makeBuffer(length: w * h * 4 * 2, options: .storageModeShared),
            let blit = cmd.makeBlitCommandEncoder()
        else { return nil }
        for (i, tex) in [objTex, elTex].enumerated() {
            blit.copy(
                from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                to: readback, destinationOffset: i * w * h * 4, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        }
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let ids = readback.contents().bindMemory(to: UInt32.self, capacity: w * h * 2)
        let region = RenderImage(
            width: w, height: h, rgba: [], depth: [],
            objects: (0..<(w * h)).map { ids[$0] }, elements: (0..<(w * h)).map { ids[w * h + $0] })
        return region.pick(x: x - x0, y: y - y0, radius: radius)
    }

    // MARK: shaders

    static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float4x4 viewProj;
            float4 color;
            float4 highlight;
            float4 lightDir;
            float4 viewDir;
            uint4 ids;   // x = objectID + 1, y = hidden-line mode
        };

        struct TriVertex { packed_float3 position; packed_float3 normal; uint element; uint highlighted; };
        struct LineVertex { packed_float3 position; uint element; uint highlighted; packed_float3 color; };

        struct VOut {
            float4 position [[position]];
            float3 normal;
            float3 color;
            uint element [[flat]];
            uint highlighted [[flat]];
        };

        vertex VOut tri_vertex(uint vid [[vertex_id]], const device TriVertex* v [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
            VOut o;
            o.position = u.viewProj * float4(float3(v[vid].position), 1.0);
            o.normal = float3(v[vid].normal);
            o.color = float3(0.0);
            o.element = v[vid].element;
            o.highlighted = v[vid].highlighted;
            return o;
        }

        vertex VOut line_vertex(uint vid [[vertex_id]], const device LineVertex* v [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
            VOut o;
            o.position = u.viewProj * float4(float3(v[vid].position), 1.0);
            o.position.z -= 0.0015 * o.position.w;   // draw edges on top of their faces
            o.normal = float3(0.0);
            o.color = float3(v[vid].color);
            o.element = v[vid].element;
            o.highlighted = v[vid].highlighted;
            return o;
        }

        fragment float4 tri_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
            if (u.ids.y != 0) { return float4(1.0); }
            float3 base = in.highlighted != 0 ? u.highlight.rgb : u.color.rgb;
            float3 n = normalize(in.normal);
            if (dot(n, u.viewDir.xyz) < 0.0) { n = -n; }
            float diffuse = max(0.0, dot(n, u.lightDir.xyz));
            float3 h = normalize(u.lightDir.xyz + u.viewDir.xyz);
            float spec = pow(max(0.0, dot(n, h)), 40.0) * 0.25;
            return float4(min(float3(1.0), base * (0.3 + 0.7 * diffuse) + spec), 1.0);
        }

        fragment float4 line_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
            return in.highlighted != 0 ? float4(u.highlight.rgb, 1.0) : float4(in.color, 1.0);
        }

        struct PickOut { uint object [[color(0)]]; uint element [[color(1)]]; };

        fragment PickOut pick_tri_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
            PickOut o; o.object = u.ids.x; o.element = in.element; return o;
        }

        fragment PickOut pick_line_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
            PickOut o; o.object = u.ids.x; o.element = in.element; return o;
        }
        """
}
#endif
