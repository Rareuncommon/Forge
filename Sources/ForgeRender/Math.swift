import ForgeCore
import Foundation

/// Column-major 4x4 matrix (matches Metal's float4x4 memory layout when converted to Float).
public struct Mat4: Sendable, Hashable {
    /// Columns c0..c3, each [x, y, z, w].
    public var m: [Double]  // 16, column-major: m[col * 4 + row]

    public init(_ m: [Double]) {
        precondition(m.count == 16)
        self.m = m
    }

    public static let identity = Mat4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public subscript(row: Int, col: Int) -> Double {
        get { m[col * 4 + row] }
        set { m[col * 4 + row] = newValue }
    }

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        var r = Mat4(Array(repeating: 0, count: 16))
        for i in 0..<4 {
            for j in 0..<4 {
                var s = 0.0
                for k in 0..<4 { s += a[i, k] * b[k, j] }
                r[i, j] = s
            }
        }
        return r
    }

    /// Transform a point (w = 1) and return homogeneous (x, y, z, w).
    public func transform(_ p: Vec3) -> (Double, Double, Double, Double) {
        (
            self[0, 0] * p.x + self[0, 1] * p.y + self[0, 2] * p.z + self[0, 3],
            self[1, 0] * p.x + self[1, 1] * p.y + self[1, 2] * p.z + self[1, 3],
            self[2, 0] * p.x + self[2, 1] * p.y + self[2, 2] * p.z + self[2, 3],
            self[3, 0] * p.x + self[3, 1] * p.y + self[3, 2] * p.z + self[3, 3]
        )
    }

    public func transformDirection(_ d: Vec3) -> Vec3 {
        Vec3(
            self[0, 0] * d.x + self[0, 1] * d.y + self[0, 2] * d.z,
            self[1, 0] * d.x + self[1, 1] * d.y + self[1, 2] * d.z,
            self[2, 0] * d.x + self[2, 1] * d.y + self[2, 2] * d.z)
    }

    /// Right-handed look-at view matrix.
    public static func lookAt(eye: Vec3, target: Vec3, up: Vec3) -> Mat4 {
        let f = (target - eye).normalized
        let s = f.cross(up).normalized
        let u = s.cross(f)
        var r = Mat4.identity
        r[0, 0] = s.x; r[0, 1] = s.y; r[0, 2] = s.z; r[0, 3] = -s.dot(eye)
        r[1, 0] = u.x; r[1, 1] = u.y; r[1, 2] = u.z; r[1, 3] = -u.dot(eye)
        r[2, 0] = -f.x; r[2, 1] = -f.y; r[2, 2] = -f.z; r[2, 3] = f.dot(eye)
        return r
    }

    /// Orthographic projection to Metal clip space (z in [0, 1]).
    public static func orthographic(halfWidth: Double, halfHeight: Double, near: Double, far: Double) -> Mat4 {
        var r = Mat4.identity
        r[0, 0] = 1 / halfWidth
        r[1, 1] = 1 / halfHeight
        r[2, 2] = -1 / (far - near)
        r[2, 3] = -near / (far - near)
        return r
    }

    /// Perspective projection to Metal clip space (z in [0, 1]).
    public static func perspective(fovY: Double, aspect: Double, near: Double, far: Double) -> Mat4 {
        let y = 1 / tan(fovY / 2)
        var r = Mat4(Array(repeating: 0, count: 16))
        r[0, 0] = y / aspect
        r[1, 1] = y
        r[2, 2] = far / (near - far)
        r[2, 3] = near * far / (near - far)
        r[3, 2] = -1
        return r
    }

    public var floats: [Float] { m.map { Float($0) } }
}

/// Unit quaternion for camera orientation.
public struct Quat: Sendable, Hashable {
    public var w, x, y, z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quat(w: 1, x: 0, y: 0, z: 0)

    public init(axis: Vec3, angle: Double) {
        let a = axis.normalized, s = sin(angle / 2)
        self.init(w: cos(angle / 2), x: a.x * s, y: a.y * s, z: a.z * s)
    }

    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }

    public var normalized: Quat {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        return Quat(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public func rotate(_ v: Vec3) -> Vec3 {
        let q = Vec3(x, y, z)
        let t = 2 * q.cross(v)
        return v + w * t + q.cross(t)
    }

    /// Rotation that maps the camera's local axes (+X right, +Y up, +Z back) onto the given
    /// world vectors (right-handed, orthonormal).
    public static func fromBasis(right: Vec3, up: Vec3, back: Vec3) -> Quat {
        let m00 = right.x, m01 = up.x, m02 = back.x
        let m10 = right.y, m11 = up.y, m12 = back.y
        let m20 = right.z, m21 = up.z, m22 = back.z
        let trace = m00 + m11 + m22
        var q: Quat
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            q = Quat(w: 0.25 * s, x: (m21 - m12) / s, y: (m02 - m20) / s, z: (m10 - m01) / s)
        } else if m00 > m11 && m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            q = Quat(w: (m21 - m12) / s, x: 0.25 * s, y: (m01 + m10) / s, z: (m02 + m20) / s)
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            q = Quat(w: (m02 - m20) / s, x: (m01 + m10) / s, y: 0.25 * s, z: (m12 + m21) / s)
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            q = Quat(w: (m10 - m01) / s, x: (m02 + m20) / s, y: (m12 + m21) / s, z: 0.25 * s)
        }
        return q.normalized
    }
}
