import ForgeCore
import Foundation
import Testing

@testable import ForgeKernel

@Suite("Kernel primitives and queries")
struct KernelTests {
    @Test func versionIsReported() {
        #expect(Kernel.version.hasPrefix("OCCT "))
    }

    @Test func boxMassPropertiesAndTopology() throws {
        let box = try Kernel.box(origin: Vec3(1, 2, 3), size: Vec3(10, 20, 30))
        #expect(box.kind == .solid)
        let mp = try box.massProperties()
        #expect(abs(mp.volume - 6000) < 1e-6)
        #expect(abs(mp.surfaceArea - 2 * (200 + 600 + 300)) < 1e-6)
        #expect((mp.centroid - Vec3(6, 12, 18)).length < 1e-9)
        // Ixx about centroid for unit density = m (b² + c²) / 12 = 6000 (400 + 900) / 12
        #expect(abs(mp.inertia[0] - 6000.0 * 1300 / 12) < 1e-3)
        let topo = try box.topology()
        #expect(topo == Shape.Topology(solids: 1, shells: 1, faces: 6, wires: 6, edges: 12, vertices: 8))
        let bb = try box.boundingBox()
        #expect((bb.min - Vec3(1, 2, 3)).length < 1e-6)
        #expect((bb.max - Vec3(11, 22, 33)).length < 1e-6)
        let v = try box.check()
        #expect(v.isValid && v.isClosed && v.freeEdges == 0)
    }

    @Test func cylinderAndSphereVolumes() throws {
        let cyl = try Kernel.cylinder(radius: 5, height: 10)
        #expect(abs(try cyl.massProperties().volume - .pi * 250) < 1e-6)
        #expect(try cyl.topology().faces == 3)
        let sph = try Kernel.sphere(radius: 3)
        #expect(abs(try sph.massProperties().volume - 4.0 / 3.0 * .pi * 27) < 1e-6)
        let cone = try Kernel.cone(radius1: 4, radius2: 2, height: 6)
        #expect(abs(try cone.massProperties().volume - .pi * 6 / 3 * (16 + 8 + 4)) < 1e-6)
        let torus = try Kernel.torus(majorRadius: 10, minorRadius: 2)
        #expect(abs(try torus.massProperties().volume - 2 * .pi * .pi * 10 * 4) < 1e-6)
    }

    @Test func invalidArgumentsProduceStructuredErrors() {
        #expect(throws: ForgeError.self) { try Kernel.box(size: Vec3(0, 1, 1)) }
        do {
            _ = try Kernel.sphere(radius: -1)
            Issue.record("expected failure")
        } catch let e as ForgeError {
            #expect(e.code == .invalidParams)
            #expect(e.message.contains("radius"))
        } catch {
            Issue.record("unexpected error type \(error)")
        }
        #expect(throws: ForgeError.self) { try Kernel.torus(majorRadius: 1, minorRadius: 2) }
    }

    @Test func booleansProduceExpectedVolumesAndUnifiedTopology() throws {
        let a = try Kernel.box(size: Vec3(10, 10, 10))
        let b = try Kernel.box(origin: Vec3(10, 0, 0), size: Vec3(10, 10, 10))
        let fused = try Kernel.boolean(.fuse, a, b)
        #expect(abs(try fused.massProperties().volume - 2000) < 1e-6)
        // Flush boxes unify into a single 6-face box.
        #expect(try fused.topology().faces == 6)

        let hole = try Kernel.cylinder(origin: Vec3(5, 5, -1), radius: 2, height: 12)
        let cut = try Kernel.boolean(.cut, a, hole)
        #expect(abs(try cut.massProperties().volume - (1000 - .pi * 4 * 10)) < 1e-6)
        #expect(try cut.topology().faces == 7)
        #expect(try cut.check().isValid)

        let common = try Kernel.boolean(.common, a, try Kernel.box(origin: Vec3(5, 5, 5), size: Vec3(10, 10, 10)))
        #expect(abs(try common.massProperties().volume - 125) < 1e-6)
    }

    @Test func disjointCommonIsAnEmptyResultError() throws {
        let a = try Kernel.box(size: Vec3(1, 1, 1))
        let b = try Kernel.box(origin: Vec3(5, 5, 5), size: Vec3(1, 1, 1))
        do {
            _ = try Kernel.boolean(.common, a, b)
            Issue.record("expected empty result")
        } catch let e as ForgeError {
            #expect(e.code == .emptyResult)
        }
    }

    @Test func transformIsRigid() throws {
        let box = try Kernel.box(size: Vec3(10, 20, 30))
        let moved = try Kernel.transform(box, .rotation(axis: .unitZ, angle: .pi / 2))
        let bb = try moved.boundingBox()
        #expect((bb.min - Vec3(-20, 0, 0)).length < 1e-6)
        #expect((bb.max - Vec3(0, 10, 30)).length < 1e-6)
        #expect(abs(try moved.massProperties().volume - 6000) < 1e-6)
    }

    @Test func filletReducesVolume() throws {
        let box = try Kernel.box(size: Vec3(10, 10, 10))
        let filleted = try Kernel.fillet(box, edges: [0], radius: 1)
        let expected: Double = 1000 - (1 - Double.pi / 4) * 10
        #expect(abs(try filleted.massProperties().volume - expected) < 1e-4)
        #expect(throws: ForgeError.self) { try Kernel.fillet(box, edges: [99], radius: 1) }
    }

    @Test func faceAndEdgeQueries() throws {
        let box = try Kernel.box(size: Vec3(10, 20, 30))
        var normals: [Vec3] = []
        for i in 0..<6 {
            let f = try box.face(i)
            #expect(f.surfaceType == .plane)
            #expect(f.edgeCount == 4)
            normals.append(f.normal)
            // Outward: normal points away from the box centre.
            #expect((f.centroid - Vec3(5, 10, 15)).dot(f.normal) > 0)
        }
        #expect(Set(normals.map { $0.x + 2 * $0.y + 4 * $0.z }).count == 6)
        let e = try box.edge(0)
        #expect(e.curveType == .line)
        #expect(e.faces.count == 2)
        #expect([10.0, 20, 30].contains { abs($0 - e.length) < 1e-9 })
        #expect(throws: ForgeError.self) { try box.face(6) }
    }

    @Test func distanceBetweenShapes() throws {
        let a = try Kernel.box(size: Vec3(1, 1, 1))
        let b = try Kernel.box(origin: Vec3(4, 0, 0), size: Vec3(1, 1, 1))
        let d = try Kernel.distance(a, b)
        #expect(abs(d.distance - 3) < 1e-9)
    }

    @Test func tessellationIsWatertightAndOutward() throws {
        let cyl = try Kernel.cylinder(radius: 5, height: 10)
        let mesh = try cyl.tessellate(linearDeflection: 0.01)
        #expect(mesh.triangleCount > 0)
        #expect(mesh.triangleFaces.count == mesh.triangleCount)
        #expect(Set(mesh.triangleFaces) == [0, 1, 2])
        // Positive signed volume ⇒ triangles are wound CCW-outward; close to the exact volume.
        let exact = Double.pi * 250
        #expect(mesh.signedVolume > 0)
        #expect(abs(mesh.signedVolume - exact) / exact < 0.01)
        #expect(mesh.edgeCount == 3)  // two circles + seam
        // Unit normals.
        for i in stride(from: 0, to: mesh.normals.count, by: 3) {
            let n = Vec3(Double(mesh.normals[i]), Double(mesh.normals[i + 1]), Double(mesh.normals[i + 2]))
            #expect(abs(n.length - 1) < 1e-4)
        }
    }

    @Test func tessellationDoesNotMutateSourceShape() throws {
        let box = try Kernel.box(size: Vec3(1, 1, 1))
        let before = try box.brepData()
        _ = try box.tessellate()
        #expect(try box.brepData() == before)
    }

    @Test func brepRoundTripIsLossless() throws {
        let a = try Kernel.boolean(
            .cut, try Kernel.box(size: Vec3(10, 10, 10)), try Kernel.sphere(center: Vec3(10, 10, 10), radius: 4))
        let data = try a.brepData()
        let b = try Shape.fromBREP(data)
        #expect(abs(try a.massProperties().volume - (try b.massProperties().volume)) < 1e-9)
        #expect(try a.topology() == (try b.topology()))
        #expect(try b.brepData() == data)
        #expect(throws: ForgeError.self) { try Shape.fromBREP(Data([1, 2, 3])) }
    }

    @Test func stepAndStlExport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-kernel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let box = try Kernel.box(size: Vec3(10, 20, 30))
        let step = dir.appendingPathComponent("box.step")
        try Kernel.exportSTEP([box], to: step)
        let text = try String(contentsOf: step, encoding: .utf8)
        #expect(text.contains("ISO-10303-21"))
        let back = try Kernel.importSTEP(from: step)
        #expect(abs(try back.massProperties().volume - 6000) < 1e-6)

        let stl = dir.appendingPathComponent("box.stl")
        try Kernel.exportSTL(box, to: stl, ascii: true)
        let stlText = try String(contentsOf: stl, encoding: .utf8)
        #expect(stlText.hasPrefix("solid"))
        #expect(stlText.components(separatedBy: "facet normal").count - 1 == 12)
    }

    @Test func deterministicTopologyOrder() throws {
        func build() throws -> [Shape.FaceInfo] {
            let s = try Kernel.boolean(
                .cut, try Kernel.box(size: Vec3(10, 10, 10)), try Kernel.cylinder(origin: Vec3(5, 5, -1), radius: 2, height: 12))
            return try (0..<(try s.topology().faces)).map { try s.face($0) }
        }
        #expect(try build() == (try build()))
    }
}

@Suite("Kernel: chamfer, shell, draft, offset")
struct KernelFeatureTests {
    /// Index of the face whose outward normal is `n` (planar faces of a box).
    func face(_ s: Shape, normal n: Vec3) throws -> Int {
        let t = try s.topology()
        for i in 0..<t.faces where (try s.face(i).normal - n).length < 1e-9 { return i }
        throw ForgeError(.internalError, "no face with normal \(n)")
    }

    /// Index of an edge of the box: the one whose midpoint is `m`.
    func edge(_ s: Shape, midpoint m: Vec3) throws -> Int {
        let t = try s.topology()
        for i in 0..<t.edges where (try s.edge(i).midpoint - m).length < 1e-9 { return i }
        throw ForgeError(.internalError, "no edge at \(m)")
    }

    @Test func chamferVariants() throws {
        let box = try Kernel.box(size: Vec3(10, 10, 10))
        let e = try edge(box, midpoint: Vec3(10, 10, 5))  // a vertical edge
        // Equal distance 2: removes a 2 × 2 / 2 triangle prism, 10 long.
        #expect(abs(try Kernel.chamfer(box, edges: [e], distance: 2).massProperties().volume - (1000 - 20)) < 1e-6)
        // Distances 2 and 3: a 2 × 3 / 2 triangle.
        #expect(abs(try Kernel.chamfer(box, edges: [e], distance: 2, distance2: 3).massProperties().volume - (1000 - 30)) < 1e-6)
        // Distance 2 at 45°: the same as equal distances.
        #expect(abs(try Kernel.chamfer(box, edges: [e], distance: 2, angle: .pi / 4).massProperties().volume - (1000 - 20)) < 1e-6)
    }

    @Test func shellOpenTopInwardAndOutward() throws {
        let box = try Kernel.box(size: Vec3(10, 10, 10))
        let top = try face(box, normal: Vec3(0, 0, 1))
        // Walls 1 thick inward, top open: the cavity is 8 × 8 × 9.
        #expect(abs(try Kernel.shell(box, openFaces: [top], thickness: 1).massProperties().volume - (1000 - 576)) < 1e-6)
        // Outward: the box becomes the cavity of a 12 × 12 × 11 block.
        #expect(abs(try Kernel.shell(box, openFaces: [top], thickness: 1, outward: true).massProperties().volume - (12 * 12 * 11 - 1000)) < 1e-6)
        // No open face: a closed hollow body.
        #expect(abs(try Kernel.shell(box, openFaces: [], thickness: 1).massProperties().volume - (1000 - 512)) < 1e-6)
    }

    @Test func draftedExtrusionIsAFrustum() throws {
        let sq = try Kernel.faces(
            loops: [[.line(Vec3(0, 0, 0), Vec3(10, 0, 0)), .line(Vec3(10, 0, 0), Vec3(10, 10, 0)), .line(Vec3(10, 10, 0), Vec3(0, 10, 0)),
                     .line(Vec3(0, 10, 0), Vec3(0, 0, 0))]], regions: [0])
        let a = 5.0 * .pi / 180
        let top = 10 - 2 * 10 * tan(a)
        let frustum = 10.0 / 3 * (100 + top * top + 10 * top)
        #expect(abs(try Kernel.extrudeDrafted(sq, by: Vec3(0, 0, 10), angle: a).massProperties().volume - frustum) < 1e-6)
        let out = 10 + 2 * 10 * tan(a)
        let flared = 10.0 / 3 * (100 + out * out + 10 * out)
        #expect(abs(try Kernel.extrudeDrafted(sq, by: Vec3(0, 0, 10), angle: a, outward: true).massProperties().volume - flared) < 1e-6)
    }

    @Test func draftFacesOfABox() throws {
        let box = try Kernel.box(size: Vec3(10, 10, 10))
        let side = try face(box, normal: Vec3(1, 0, 0))
        // Neutral plane z = 0, pull +z: the +x face tilts inward by 10 tan a at the top.
        let a = 3.0 * .pi / 180
        let v = try Kernel.draft(box, faces: [side], neutralOrigin: .zero, pull: Vec3(0, 0, 1), angle: a).massProperties().volume
        #expect(abs(v - (1000 - 10 * (10 * 10 * tan(a)) / 2)) < 1e-6)
    }

    @Test func offsetFaceGrowsWithRoundCornersAndShrinks() throws {
        let sq = try Kernel.faces(
            loops: [[.line(Vec3(0, 0, 0), Vec3(10, 0, 0)), .line(Vec3(10, 0, 0), Vec3(10, 10, 0)), .line(Vec3(10, 10, 0), Vec3(0, 10, 0)),
                     .line(Vec3(0, 10, 0), Vec3(0, 0, 0))]], regions: [0])
        #expect(abs(try Kernel.offsetFace(sq, by: 1).massProperties().surfaceArea - (100 + 40 + .pi)) < 1e-6)
        #expect(abs(try Kernel.offsetFace(sq, by: -1).massProperties().surfaceArea - 64) < 1e-6)
        #expect(throws: ForgeError.self) { try Kernel.offsetFace(sq, by: -6) }
    }
}

@Suite("Kernel: transforms")
struct KernelTransformTests {
    @Test func reflectionAndComposition() throws {
        let box = try Kernel.box(origin: Vec3(1, 2, 3), size: Vec3(4, 5, 6))
        let m = try Kernel.transform(box, .reflection(origin: Vec3(10, 0, 0), normal: Vec3(1, 0, 0)))
        #expect(abs(try m.massProperties().volume - 120) < 1e-9)
        let bb = try m.boundingBox()
        #expect((bb.min - Vec3(15, 2, 3)).length < 1e-6 && (bb.max - Vec3(19, 7, 9)).length < 1e-6)
        #expect(try m.check().isValid)
        let t = Transform3.translation(Vec3(1, 0, 0)).then(.rotation(axis: .unitZ, angle: .pi / 2))
        #expect((t.apply(Vec3(1, 0, 0)) - Vec3(0, 2, 0)).length < 1e-12)
    }
}
