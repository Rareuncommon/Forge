// Metal viewport renderer (macOS). Mirrors SoftwareRenderer: shaded triangles + edges, and a
// pick pass writing object/element IDs to integer render targets (GPU picking).
//
// An overlay layer (sketch previews, snap markers) is drawn last, on top, without depth test
// and is never picked.

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
    private let previewPipeline: any MTLRenderPipelineState
    private let previewDepthState: any MTLDepthStencilState
    private let overlayDepthState: any MTLDepthStencilState

    public var camera = Camera()
    public var style: RenderStyle = .shadedWithEdges
    public var background = RGBA.background
    /// Items not drawn (still pickable): bodies replaced on screen by an opaque preview.
    public var hiddenObjects: Set<UInt32> = []
    /// Clear to transparent so the view behind (e.g. a gradient) shows through.
    public var transparentBackground = false
    private var items: [GPUItem] = []
    private var overlay: [GPUItem] = []
    private var preview: [GPUItem] = []
    private var sceneBounds: BoundingBox?
    private var previewBounds: BoundingBox?

    typealias GPUItem = ViewportBatch<any MTLBuffer>

    // Vertex layouts (must match the MSL structs below).
    // TriVertex: packed_float3 position, packed_float3 normal, uint element, uint highlighted = 32 bytes
    // LineVertex: packed_float3 position, uint element, uint highlighted, packed_float3 color = 32 bytes
    static let triStride = ViewportVertices.triangleStride
    static let lineStride = ViewportVertices.lineStride

    public init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(), colorFormat: MTLPixelFormat = .bgra8Unorm_srgb) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            func pipeline(_ vfn: String, _ ffn: String, colors: [MTLPixelFormat], blend: Bool = false) throws -> any MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vfn)
                d.fragmentFunction = library.makeFunction(name: ffn)
                for (i, f) in colors.enumerated() { d.colorAttachments[i].pixelFormat = f }
                if blend {
                    let a = d.colorAttachments[0]!
                    a.isBlendingEnabled = true
                    a.sourceRGBBlendFactor = .sourceAlpha
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    a.sourceAlphaBlendFactor = .one
                    a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                d.depthAttachmentPixelFormat = .depth32Float
                return try device.makeRenderPipelineState(descriptor: d)
            }
            shadedPipeline = try pipeline("tri_vertex", "tri_fragment", colors: [colorFormat])
            linePipeline = try pipeline("line_vertex", "line_fragment", colors: [colorFormat])
            previewPipeline = try pipeline("tri_vertex", "preview_fragment", colors: [colorFormat], blend: true)
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
        let ods = MTLDepthStencilDescriptor()
        ods.depthCompareFunction = .always
        ods.isDepthWriteEnabled = false
        guard let odepth = device.makeDepthStencilState(descriptor: ods) else { return nil }
        overlayDepthState = odepth
        let pds = MTLDepthStencilDescriptor()
        pds.depthCompareFunction = .lessEqual
        pds.isDepthWriteEnabled = false
        guard let pdepth = device.makeDepthStencilState(descriptor: pds) else { return nil }
        previewDepthState = pdepth
        super.init()
    }

    /// Upload a scene. Triangles are de-indexed so each vertex carries its B-rep face index
    /// (portable alternative to [[primitive_id]]; see docs/adr/0009-viewport-rendering.md).
    public func setScene(_ scene: RenderScene) {
        sceneBounds = scene.bounds
        items = scene.items.map(gpuItem)
    }

    /// Replace the preview: bodies an operation would create, drawn translucent in their
    /// colour's alpha with their edges, depth-tested against the scene, not pickable.
    public func setPreview(_ previewItems: [RenderItem]) {
        preview = previewItems.map(gpuItem)
        previewBounds = RenderScene(items: previewItems).bounds
    }

    /// Replace the overlay (drawn on top of everything, not pickable).
    public func setOverlay(_ overlayItems: [RenderItem]) {
        overlay = overlayItems.map(gpuItem)
    }

    private func gpuItem(_ item: RenderItem) -> GPUItem {
        GPUItem(item) { bytes in device.makeBuffer(bytes: bytes, length: bytes.count, options: .storageModeShared) }
    }

    private func frame(aspect: Double) -> ViewportFrame {
        ViewportFrame(camera: camera, style: style, hiddenObjects: hiddenObjects, sceneBounds: sceneBounds, previewBounds: previewBounds, aspect: aspect)
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let cmd = queue.makeCommandBuffer()
        else { return }
        pass.colorAttachments[0].clearColor =
            transparentBackground
            ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: Double(background.r), green: Double(background.g), blue: Double(background.b), alpha: 1)
        pass.depthAttachment.clearDepth = 1
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let aspect = Double(view.drawableSize.width / max(view.drawableSize.height, 1))
        encode(enc, aspect: aspect, pick: false)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Execute the shared draw plan (ViewportFrame.draws) with this back end's pipelines.
    private func encode(_ enc: any MTLRenderCommandEncoder, aspect: Double, pick: Bool) {
        let draws = frame(aspect: aspect).draws(scene: items, preview: preview, overlay: overlay, pick: pick)
        var pipeline: ViewportPipeline?
        var depth: ViewportDepth?
        for d in draws {
            if d.pipeline != pipeline {
                pipeline = d.pipeline
                enc.setRenderPipelineState(
                    switch d.pipeline {
                    case .shaded: shadedPipeline
                    case .lines: linePipeline
                    case .preview: previewPipeline
                    case .pickTriangles: pickTrianglePipeline
                    case .pickLines: pickLinePipeline
                    })
            }
            if d.depth != depth {
                depth = d.depth
                enc.setDepthStencilState(
                    switch d.depth {
                    case .write: depthState
                    case .test: previewDepthState
                    case .none: overlayDepthState
                    })
            }
            var u = d.uniforms
            enc.setVertexBuffer(d.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: u.count * 4, index: 1)
            enc.setFragmentBytes(&u, length: u.count * 4, index: 1)
            enc.drawPrimitives(type: d.pipeline == .lines || d.pipeline == .pickLines ? .line : .triangle, vertexStart: 0, vertexCount: d.vertexCount)
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

        fragment float4 preview_fragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
            float3 n = normalize(in.normal);
            if (dot(n, u.viewDir.xyz) < 0.0) { n = -n; }
            float diffuse = max(0.0, dot(n, u.lightDir.xyz));
            return float4(u.color.rgb * (0.55 + 0.45 * diffuse), u.color.a);
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
