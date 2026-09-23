import ForgeCore
import ForgeKernel
import Foundation
import Testing

@testable import ForgeRender

@Suite("Camera")
struct CameraTests {
    @Test func standardOrientationsAreOrthonormalAndCorrect() {
        for o in ViewOrientation.allCases {
            var c = Camera()
            c.setOrientation(o)
            #expect(abs(c.right.dot(c.up)) < 1e-9)
            #expect(abs(c.right.cross(c.up).dot(c.back) - 1) < 1e-9, "\(o) must be right-handed")
            #expect((c.back - o.basis.toEye.normalized).length < 1e-9)
        }
        var front = Camera()
        front.setOrientation(.front)
        #expect((front.right - .unitX).length < 1e-9 && (front.up - .unitY).length < 1e-9)
    }

    @Test func orbitPreservesDistanceAndPanMovesTarget() {
        var c = Camera(target: Vec3(1, 2, 3), distance: 50)
        c.setOrientation(.isometric)
        let eye0 = c.eye
        c.orbit(dx: 0.3, dy: -0.2)
        #expect(abs((c.eye - c.target).length - 50) < 1e-9)
        #expect((c.eye - eye0).length > 1)
        let t0 = c.target
        c.pan(dxPixels: 100, dyPixels: 0, viewportHeight: 1000)
        #expect(((c.target - t0).normalized + c.right).length < 1e-9)
    }

    @Test func zoomKeepsAnchorFixedInOrtho() {
        var c = Camera(orthoHalfHeight: 10)
        c.setOrientation(.front)
        let anchor = Vec3(5, 5, 0)
        // Anchor's position relative to the view centre, in view-height units, before/after.
        func rel(_ c: Camera) -> Double { (anchor - c.target).dot(c.right) / c.orthoHalfHeight }
        let before = rel(c)
        c.zoom(factor: 2, anchor: anchor)
        #expect(abs(c.orthoHalfHeight - 5) < 1e-12)
        #expect(abs(rel(c) - before) < 1e-12)
    }

    @Test func rayThroughCentreHitsTarget() {
        for proj in ProjectionKind.allCases {
            var c = Camera(target: Vec3(3, 4, 5), distance: 100, projection: proj)
            c.setOrientation(.trimetric)
            let (o, d) = c.ray(pixelX: 50, pixelY: 50, width: 100, height: 100)
            let t = (c.target - o).dot(d)
            #expect((o + d * t - c.target).length < 1e-9)
        }
    }
}

@Suite("Software renderer and picking")
struct RendererTests {
    func boxScene() throws -> RenderScene {
        let box = try Kernel.box(origin: Vec3(-5, -5, -5), size: Vec3(10, 10, 10))
        return RenderScene(items: [RenderItem(objectID: 0, mesh: try box.tessellate(), color: .bodyColor(0))])
    }

    @Test func renderedFrontViewShowsTheFrontFace() throws {
        let scene = try boxScene()
        var cam = Camera()
        cam.setOrientation(.front)
        cam.fit(scene.bounds!)
        let img = SoftwareRenderer.render(scene, camera: cam, options: RenderOptions(width: 120, height: 100))
        let hit = img.hit(x: 60, y: 50)
        #expect(hit?.element == .face)
        let box = try Kernel.box(origin: Vec3(-5, -5, -5), size: Vec3(10, 10, 10))
        let face = try box.face(Int(hit!.index))
        #expect((face.normal - .unitZ).length < 1e-9)
        #expect(img.hit(x: 1, y: 1) == nil)  // background
        #expect(img.depth[50 * 120 + 60] < 1)
    }

    @Test func picksEdgesWithTolerance() throws {
        let scene = try boxScene()
        var cam = Camera()
        cam.setOrientation(.front)
        cam.fit(scene.bounds!)
        let img = SoftwareRenderer.render(scene, camera: cam, options: RenderOptions(width: 200, height: 200))
        // Find the silhouette's left edge on the middle row and pick near it.
        let row = 100
        let firstCovered = (0..<200).first { img.objects[row * 200 + $0] != 0 }!
        let hit = img.pick(x: firstCovered + 1, y: row, radius: 3)
        #expect(hit?.element == .edge)
    }

    @Test func rayPickerAgreesWithIDBuffer() throws {
        let scene = try boxScene()
        var cam = Camera(projection: .perspective)
        cam.setOrientation(.isometric)
        cam.fit(scene.bounds!)
        let w = 160, h = 120
        let img = SoftwareRenderer.render(scene, camera: cam, options: RenderOptions(width: w, height: h, supersample: 1))
        var agree = 0, total = 0
        for y in stride(from: 5, to: h, by: 10) {
            for x in stride(from: 5, to: w, by: 10) {
                guard let a = img.hit(x: x, y: y), a.element == .face else { continue }
                let (o, d) = cam.ray(pixelX: Double(x) + 0.5, pixelY: Double(y) + 0.5, width: Double(w), height: Double(h))
                total += 1
                if let b = RayPicker.pick(scene, origin: o, direction: d), b.index == a.index { agree += 1 }
            }
        }
        #expect(total > 20)
        #expect(Double(agree) / Double(total) > 0.95)
    }

    @Test func stylesProduceDifferentImages() throws {
        let scene = try boxScene()
        var cam = Camera()
        cam.setOrientation(.isometric)
        cam.fit(scene.bounds!)
        let imgs = RenderStyle.allCases.map {
            SoftwareRenderer.render(scene, camera: cam, options: RenderOptions(width: 64, height: 64, style: $0)).rgba
        }
        #expect(Set(imgs).count == RenderStyle.allCases.count)
    }
}

@Suite("PNG encoding")
struct PNGTests {
    @Test func crcAndAdlerKnownValues() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(Zlib.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
    }

    @Test func pngStructure() {
        let w = 37, h = 11
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[4 * i] = UInt8(i % 256); px[4 * i + 3] = 255 }
        let png = PNG.encode(rgba: px, width: w, height: h)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(png.suffix(12).prefix(8) == Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44]))
    }

    /// Independent verification with Python's zlib (skipped when python3 is unavailable).
    @Test func deflateStreamDecodesWithReferenceZlib() throws {
        var input = [UInt8]()
        for i in 0..<70_000 { input.append(UInt8((i / 7) % 13)) }  // long repeats and literals
        input += Array("the quick brown fox jumps over the lazy dog".utf8)
        input += [UInt8](repeating: 9, count: 1000)  // length-258 matches
        let compressed = Zlib.compress(input)
        #expect(compressed.count < input.count / 10)
        let dir = FileManager.default.temporaryDirectory
        let inURL = dir.appendingPathComponent("forge-z-\(UUID().uuidString)")
        try Data(compressed).write(to: inURL)
        defer { try? FileManager.default.removeItem(at: inURL) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", "import sys,zlib,hashlib;print(hashlib.sha256(zlib.decompress(open(sys.argv[1],'rb').read())).hexdigest())", inURL.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return }  // no python: nothing to compare against
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            Issue.record("python zlib failed to decode our stream")
            return
        }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out == sha256Hex(input))
    }
}

/// Minimal SHA-256 for the test (Foundation has no digest API on Linux).
func sha256Hex(_ message: [UInt8]) -> String {
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var msg = message
    let bitLen = UInt64(message.count) * 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for chunk in stride(from: 0, to: msg.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(msg[chunk + 4 * i]) << 24 | UInt32(msg[chunk + 4 * i + 1]) << 16 | UInt32(msg[chunk + 4 * i + 2]) << 8 | UInt32(msg[chunk + 4 * i + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }
    return h.map { String(format: "%08x", $0) }.joined()
}
