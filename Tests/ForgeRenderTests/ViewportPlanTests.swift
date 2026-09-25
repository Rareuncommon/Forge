import ForgeCore
import Testing
@testable import ForgeRender

@Suite("Viewport draw plan")
struct ViewportPlanTests {
    typealias B = ViewportBatch<String>

    func batch(_ id: UInt32, faces: Bool = true, alpha: Float = 1) -> B {
        B(objectID: id, triangles: faces ? "t\(id)" : nil, triangleVertexCount: 3, lines: "l\(id)", lineVertexCount: 2, color: RGBA(0.5, 0.5, 0.5, alpha))
    }

    func frame(_ style: RenderStyle = .shadedWithEdges, hidden: Set<UInt32> = []) -> ViewportFrame {
        ViewportFrame(camera: Camera(), style: style, hiddenObjects: hidden, sceneBounds: nil, previewBounds: nil, aspect: 1.5)
    }

    @Test func order() {
        let d = frame().draws(scene: [batch(0)], preview: [batch(7), batch(8, alpha: 0.4)], overlay: [batch(9, faces: false)], pick: false)
        #expect(d.map(\.buffer) == ["t0", "l0", "t7", "l7", "l8", "t8", "l9"])
        #expect(d.map(\.pipeline) == [.shaded, .lines, .shaded, .lines, .lines, .preview, .lines])
        #expect(d.map(\.depth) == [.write, .write, .write, .write, .write, .test, .none])
        #expect(d.allSatisfy { $0.uniforms.count == 36 })
    }

    @Test func hiddenBodiesAreStillPicked() {
        let scene = [batch(0), batch(1)]
        #expect(frame(hidden: [1]).draws(scene: scene, preview: [], overlay: [], pick: false).map(\.buffer) == ["t0", "l0"])
        let pick = frame(hidden: [1]).draws(scene: scene, preview: [batch(5)], overlay: [batch(6)], pick: true)
        #expect(pick.map(\.buffer) == ["t0", "t1", "l0", "l1"])
        #expect(pick.map(\.pipeline) == [.pickTriangles, .pickTriangles, .pickLines, .pickLines])
        // The pick id is objectID + 1 (0 = background).
        #expect(pick[1].uniforms[32].bitPattern == 2)
    }

    @Test func styles() {
        let scene = [batch(0), batch(1, faces: false)]
        #expect(frame(.shaded).draws(scene: scene, preview: [], overlay: [], pick: false).map(\.buffer) == ["t0", "l1"])
        #expect(frame(.wireframe).draws(scene: scene, preview: [], overlay: [], pick: false).map(\.buffer) == ["l0", "l1"])
    }
}
