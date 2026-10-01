import ForgeCore
import ForgeKernel
import ForgeRender
import Testing

@Suite("Candidate segment visibility")
struct CandidatePickingTests {
    @Test func nearerOccludedSegmentCannotHideVisiblePartOfSameEdge() {
        // The face is at z=5. Edge 7 bends from a visible x=.1 segment at z=6
        // around the side to an exactly-on-ray segment at z=0 behind that face.
        let mesh = Mesh(positions: [-2,-2,5, 2,-2,5, 0,2,5], normals: [], indices: [0,1,2], triangleFaces: [3],
                        edgeOffsets: [0,6], edgeIDs: [7],
                        edgePoints: [0.1,-1,6, 0.1,1,6, 3,1,6, 3,1,0, 0,1,0, 0,-1,0])
        let scene = RenderScene(items: [RenderItem(objectID: 0, mesh: mesh, color: RGBA(1,1,1))])
        for includeOccluded in [false, true] {
            let hits = RayPicker.candidates(scene, origin: Vec3(0,0,10), direction: Vec3(0,0,-1),
                                            edgeTolerance: 0.2, includeOccluded: includeOccluded)
            #expect(hits.count == 2)
            #expect(hits.first?.element == .edge)
            #expect(hits.first?.index == 7)
            #expect(abs((hits.first?.point?.z ?? 0) - 6) < 1e-7)
            #expect(hits.last?.element == .face)
        }
    }
}
