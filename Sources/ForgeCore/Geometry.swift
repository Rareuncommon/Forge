import Foundation

/// Double-precision 3-vector. (We avoid the Apple-only `simd` module so the engine builds on Linux.)
public struct Vec3: Codable, Sendable, Hashable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let unitX = Vec3(1, 0, 0)
    public static let unitY = Vec3(0, 1, 0)
    public static let unitZ = Vec3(0, 0, 1)

    public var array: [Double] { [x, y, z] }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vec3) -> Vec3 { a * s }
    public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }

    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { dot(self).squareRoot() }
    public var normalized: Vec3 {
        let l = length
        return l > 0 ? self / l : self
    }

    public var description: String { "(\(x), \(y), \(z))" }

    // Encoded as [x, y, z] — compact and agent-friendly.
    public init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let x = try c.decode(Double.self), y = try c.decode(Double.self), z = try c.decode(Double.self)
        guard c.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected exactly 3 numbers")
        }
        guard x.isFinite, y.isFinite, z.isFinite else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "vector components must be finite")
        }
        self.init(x, y, z)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
        try c.encode(z)
    }
}

/// Axis-aligned bounding box.
public struct BoundingBox: Codable, Sendable, Hashable {
    public var min: Vec3
    public var max: Vec3

    public init(min: Vec3, max: Vec3) {
        self.min = min
        self.max = max
    }

    public var size: Vec3 { max - min }
    public var center: Vec3 { (min + max) * 0.5 }
    public var diagonal: Double { size.length }

    public func union(_ o: BoundingBox) -> BoundingBox {
        BoundingBox(
            min: Vec3(Swift.min(min.x, o.min.x), Swift.min(min.y, o.min.y), Swift.min(min.z, o.min.z)),
            max: Vec3(Swift.max(max.x, o.max.x), Swift.max(max.y, o.max.y), Swift.max(max.z, o.max.z)))
    }
}

/// Row-major 3x4 affine transform [R | t] (rotation/uniform scale + translation).
public struct Transform3: Codable, Sendable, Hashable {
    public var m: [Double]  // 12 values

    public init(m: [Double]) {
        precondition(m.count == 12)
        self.m = m
    }

    public static let identity = Transform3(m: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])

    public static func translation(_ t: Vec3) -> Transform3 {
        Transform3(m: [1, 0, 0, t.x, 0, 1, 0, t.y, 0, 0, 1, t.z])
    }

    /// Mirror about the plane through `origin` with normal `normal`: p' = p − 2n (n·(p − o)).
    public static func reflection(origin o: Vec3, normal: Vec3) -> Transform3 {
        let n = normal.normalized
        let t = n * (2 * n.dot(o))
        return Transform3(m: [
            1 - 2 * n.x * n.x, -2 * n.x * n.y, -2 * n.x * n.z, t.x,
            -2 * n.x * n.y, 1 - 2 * n.y * n.y, -2 * n.y * n.z, t.y,
            -2 * n.x * n.z, -2 * n.y * n.z, 1 - 2 * n.z * n.z, t.z,
        ])
    }

    /// `self` then `b` (b ∘ self).
    public func then(_ b: Transform3) -> Transform3 {
        var r = [Double](repeating: 0, count: 12)
        for i in 0..<3 {
            for j in 0..<3 { r[4 * i + j] = (0..<3).reduce(0) { $0 + b.m[4 * i + $1] * m[4 * $1 + j] } }
            r[4 * i + 3] = (0..<3).reduce(b.m[4 * i + 3]) { $0 + b.m[4 * i + $1] * m[4 * $1 + 3] }
        }
        return Transform3(m: r)
    }

    /// Rotation by `angle` radians about `axis` through `origin` (Rodrigues).
    public static func rotation(axis: Vec3, angle: Double, origin: Vec3 = .zero) -> Transform3 {
        let k = axis.normalized
        let c = cos(angle), s = sin(angle), t = 1 - c
        let r: [Double] = [
            t * k.x * k.x + c, t * k.x * k.y - s * k.z, t * k.x * k.z + s * k.y,
            t * k.x * k.y + s * k.z, t * k.y * k.y + c, t * k.y * k.z - s * k.x,
            t * k.x * k.z - s * k.y, t * k.y * k.z + s * k.x, t * k.z * k.z + c,
        ]
        // p' = R (p - o) + o  =>  t = o - R o
        let ro = Vec3(
            r[0] * origin.x + r[1] * origin.y + r[2] * origin.z,
            r[3] * origin.x + r[4] * origin.y + r[5] * origin.z,
            r[6] * origin.x + r[7] * origin.y + r[8] * origin.z)
        let tr = origin - ro
        return Transform3(m: [r[0], r[1], r[2], tr.x, r[3], r[4], r[5], tr.y, r[6], r[7], r[8], tr.z])
    }

    public func apply(_ p: Vec3) -> Vec3 {
        Vec3(
            m[0] * p.x + m[1] * p.y + m[2] * p.z + m[3],
            m[4] * p.x + m[5] * p.y + m[6] * p.z + m[7],
            m[8] * p.x + m[9] * p.y + m[10] * p.z + m[11])
    }
}
