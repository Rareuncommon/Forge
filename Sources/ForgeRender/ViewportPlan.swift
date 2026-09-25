// What the interactive viewport draws, in which order and with which uniforms — shared by the
// GPU back ends (Metal on macOS, Direct3D 11 on Windows) so they cannot drift apart. A back end
// only uploads the vertex bytes built here and executes the draw list with its own pipelines
// (docs/adr/0009-viewport-rendering.md, docs/adr/0012-windows-app.md).

import ForgeCore
import ForgeKernel

/// Interleaved vertex data of a render item.
///
/// Triangles are de-indexed so each vertex carries its B-rep face index:
///   TriVertex  = float3 position, float3 normal, uint element (face + 1), uint highlighted  (32 bytes)
///   LineVertex = float3 position, uint element (edge + 1 | edgeFlag), uint highlighted, float3 color  (32 bytes)
public enum ViewportVertices {
    public static let triangleStride = 32
    public static let lineStride = 32

    public static func triangles(_ item: RenderItem) -> [UInt8] {
        let m = item.mesh
        var tri = [UInt8]()
        tri.reserveCapacity(m.triangleCount * 3 * triangleStride)
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
        return tri
    }

    public static func lines(_ item: RenderItem) -> [UInt8] {
        let m = item.mesh
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
        return lines
    }

    private static func append(_ buf: inout [UInt8], floats: [Float]) {
        for f in floats { withUnsafeBytes(of: f.bitPattern.littleEndian) { buf.append(contentsOf: $0) } }
    }

    private static func append(_ buf: inout [UInt8], uints: [UInt32]) {
        for u in uints { withUnsafeBytes(of: u.littleEndian) { buf.append(contentsOf: $0) } }
    }
}

/// The pipelines a back end provides (shader pairs as in the Metal source).
public enum ViewportPipeline: Int32, Sendable {
    /// Lit triangles in the uniform colour (highlighted faces in the highlight colour).
    case shaded = 0
    /// Lines in their vertex colour.
    case lines = 1
    /// Translucent lit triangles (blending on).
    case preview = 2
    /// Object / element ids into two R32Uint targets.
    case pickTriangles = 3
    case pickLines = 4
}

/// Depth modes: test and write, test only, or none (overlay on top).
public enum ViewportDepth: Int32, Sendable {
    case write = 0, test = 1, none = 2
}

/// A render item uploaded by a back end: its buffers (`Buffer` is the back end's handle).
public struct ViewportBatch<Buffer> {
    public var objectID: UInt32
    public var triangles: Buffer?
    public var triangleVertexCount: Int
    public var lines: Buffer?
    public var lineVertexCount: Int
    public var color: RGBA

    public init(objectID: UInt32, triangles: Buffer?, triangleVertexCount: Int, lines: Buffer?, lineVertexCount: Int, color: RGBA) {
        self.objectID = objectID
        self.triangles = triangles
        self.triangleVertexCount = triangleVertexCount
        self.lines = lines
        self.lineVertexCount = lineVertexCount
        self.color = color
    }

    /// Upload `item` with `make` (nil for empty data).
    public init(_ item: RenderItem, make: ([UInt8]) -> Buffer?) {
        let tri = ViewportVertices.triangles(item), lines = ViewportVertices.lines(item)
        self.init(
            objectID: item.objectID, triangles: tri.isEmpty ? nil : make(tri), triangleVertexCount: tri.count / ViewportVertices.triangleStride,
            lines: lines.isEmpty ? nil : make(lines), lineVertexCount: lines.count / ViewportVertices.lineStride, color: item.color)
    }
}

/// One draw call.
public struct ViewportDraw<Buffer> {
    public var pipeline: ViewportPipeline
    public var depth: ViewportDepth
    public var buffer: Buffer
    public var vertexCount: Int
    /// 36 floats: float4x4 viewProj (column-major); float4 color; float4 highlight;
    /// float4 lightDir; float4 viewDir; uint4 ids (bit patterns: objectID + 1, hidden-line flag).
    public var uniforms: [Float]
}

/// Everything besides the buffers that decides a frame.
public struct ViewportFrame: Sendable {
    public var camera: Camera
    public var style: RenderStyle
    /// Scene objects not drawn (still picked): bodies an opaque preview replaces.
    public var hiddenObjects: Set<UInt32>
    public var sceneBounds: BoundingBox?
    public var previewBounds: BoundingBox?
    public var aspect: Double

    public init(camera: Camera, style: RenderStyle, hiddenObjects: Set<UInt32> = [], sceneBounds: BoundingBox?, previewBounds: BoundingBox?, aspect: Double) {
        self.camera = camera
        self.style = style
        self.hiddenObjects = hiddenObjects
        self.sceneBounds = sceneBounds
        self.previewBounds = previewBounds
        self.aspect = aspect
    }

    /// Uniforms for an item (see ViewportDraw.uniforms).
    public func uniforms(objectID: UInt32, color: RGBA, lineColor: RGBA? = nil) -> [Float] {
        let bounds = [sceneBounds, previewBounds].compactMap { $0 }.reduce(BoundingBox?.none) { acc, b in acc.map { $0.union(b) } ?? b }
        let radius = bounds.map { max(($0.center - camera.target).length + $0.diagonal / 2, 1e-3) } ?? 1
        let vp = camera.projectionMatrix(aspect: aspect, sceneRadius: radius) * camera.viewMatrix
        let light = (camera.back + camera.up * 0.25 + camera.right * 0.15).normalized
        let c = lineColor ?? (style == .hiddenLinesRemoved ? .white : color)
        let hlrFlag: UInt32 = style == .hiddenLinesRemoved ? 1 : 0
        return vp.floats + [c.r, c.g, c.b, c.a] + [RGBA.highlight.r, RGBA.highlight.g, RGBA.highlight.b, 1]
            + [Float(light.x), Float(light.y), Float(light.z), 0] + [Float(camera.back.x), Float(camera.back.y), Float(camera.back.z), 0]
            + [Float(bitPattern: objectID + 1), Float(bitPattern: hlrFlag), 0, 0]
    }

    /// The draw calls of a frame (or of the pick pass), in order:
    /// scene faces, scene edges, then (not when picking) opaque previews, preview edges,
    /// translucent previews and the overlay.
    public func draws<Buffer>(scene: [ViewportBatch<Buffer>], preview: [ViewportBatch<Buffer>], overlay: [ViewportBatch<Buffer>], pick: Bool) -> [ViewportDraw<Buffer>] {
        var out: [ViewportDraw<Buffer>] = []
        func faces(_ b: ViewportBatch<Buffer>, _ p: ViewportPipeline, _ d: ViewportDepth) {
            guard let t = b.triangles else { return }
            out.append(ViewportDraw(pipeline: p, depth: d, buffer: t, vertexCount: b.triangleVertexCount, uniforms: uniforms(objectID: b.objectID, color: b.color)))
        }
        func edges(_ b: ViewportBatch<Buffer>, _ p: ViewportPipeline, _ d: ViewportDepth) {
            guard let l = b.lines else { return }
            out.append(ViewportDraw(pipeline: p, depth: d, buffer: l, vertexCount: b.lineVertexCount, uniforms: uniforms(objectID: b.objectID, color: b.color, lineColor: .edge)))
        }
        if style != .wireframe {
            for b in scene where pick || !hiddenObjects.contains(b.objectID) { faces(b, pick ? .pickTriangles : .shaded, .write) }
        }
        // In "shaded" style body edges are hidden, but line-only items (sketches, reference
        // geometry) are always drawn.
        for b in scene where (style != .shaded || b.triangles == nil) && (pick || !hiddenObjects.contains(b.objectID)) {
            edges(b, pick ? .pickLines : .lines, .write)
        }
        guard !pick else { return out }
        // Opaque previews (a modified body shown in place of the original) are depth-tested
        // and written like the scene; translucent ones blend over it without writing depth.
        for b in preview where b.color.a >= 0.999 { faces(b, .shaded, .write) }
        for b in preview { edges(b, .lines, .write) }
        for b in preview where b.color.a < 0.999 { faces(b, .preview, .test) }
        for b in overlay { edges(b, .lines, .none) }
        return out
    }
}
