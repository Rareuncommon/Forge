import ForgeCore
import Foundation

/// Clamped uniform B-splines (SPEC 7.1 "spline"). Knots are 0 (degree+1 times), 1/s, 2/s, …,
/// 1 (degree+1 times) for s = poles − degree spans, the same convention the kernel uses, so the
/// sketch curve and the solid edge are the same curve.
enum BSpline {
    static func knots(poles n: Int, degree p: Int) -> [Double] {
        let spans = n - p
        return Array(repeating: 0, count: p) + (0...spans).map { Double($0) / Double(spans) } + Array(repeating: 1, count: p)
    }

    /// Span index k with knots[k] ≤ t < knots[k+1] (the last span for t = 1).
    static func span(_ t: Double, _ U: [Double], poles n: Int, degree p: Int) -> Int {
        if t >= U[n] { return n - 1 }
        var k = p
        while k < n - 1 && t >= U[k + 1] { k += 1 }
        return k
    }

    /// Non-zero basis functions N[k−p…k] at t (Cox–de Boor).
    static func basis(_ t: Double, _ k: Int, _ U: [Double], degree p: Int) -> [Double] {
        var N = [Double](repeating: 0, count: p + 1)
        var left = [Double](repeating: 0, count: p + 1), right = [Double](repeating: 0, count: p + 1)
        N[0] = 1
        for j in 1...max(1, p) where p >= 1 {
            left[j] = t - U[k + 1 - j]
            right[j] = U[k + j] - t
            var saved = 0.0
            for r in 0..<j {
                let den = right[r + 1] + left[j - r]
                let tmp = den == 0 ? 0 : N[r] / den
                N[r] = saved + right[r + 1] * tmp
                saved = left[j - r] * tmp
            }
            N[j] = saved
        }
        return N
    }

    static func point(_ P: [(Double, Double)], degree p: Int, at t: Double) -> (Double, Double) {
        let U = knots(poles: P.count, degree: p)
        let k = span(t, U, poles: P.count, degree: p)
        let N = basis(t, k, U, degree: p)
        var x = 0.0, y = 0.0
        for j in 0...p {
            x += N[j] * P[k - p + j].0
            y += N[j] * P[k - p + j].1
        }
        return (x, y)
    }

    /// Derivative control points (a clamped B-spline of degree p−1 on the inner knots).
    static func derivative(_ P: [(Double, Double)], degree p: Int) -> [(Double, Double)] {
        let U = knots(poles: P.count, degree: p)
        return (0..<(P.count - 1)).map { i in
            let f = Double(p) / (U[i + p + 1] - U[i + 1])
            return ((P[i + 1].0 - P[i].0) * f, (P[i + 1].1 - P[i].1) * f)
        }
    }

    /// ½∮(x dy − y dx) along the curve: exact, since on each span the integrand is a polynomial
    /// of degree 2p−1 and p-point Gauss–Legendre integrates degree 2p−1 exactly.
    static func greenArea(_ P: [(Double, Double)], degree p: Int) -> Double {
        let D = derivative(P, degree: p)
        let U = knots(poles: P.count, degree: p)
        let (xs, ws) = gauss(max(p, 1))
        var area = 0.0
        for k in p..<(P.count) where U[k + 1] > U[k] {
            let a = U[k], b = U[k + 1]
            for (x, w) in zip(xs, ws) {
                let t = (a + b) / 2 + (b - a) / 2 * x
                let q = point(P, degree: p, at: t)
                let d = p > 1 ? point(D, degree: p - 1, at: t) : D[min(k - p, D.count - 1)]
                area += w * (b - a) / 2 * (q.0 * d.1 - q.1 * d.0) / 2
            }
        }
        return area
    }

    /// Gauss–Legendre nodes and weights on [−1, 1] (Newton on Legendre polynomials).
    static func gauss(_ n: Int) -> ([Double], [Double]) {
        var xs: [Double] = [], ws: [Double] = []
        for i in 1...n {
            var x = cos(Double.pi * (Double(i) - 0.25) / (Double(n) + 0.5))
            var dp = 0.0
            for _ in 0..<100 {
                var p0 = 1.0, p1 = x
                for k in 2...max(2, n) where n >= 2 {
                    let pk = ((2 * Double(k) - 1) * x * p1 - (Double(k) - 1) * p0) / Double(k)
                    p0 = p1
                    p1 = pk
                }
                if n == 1 { p1 = x; p0 = 1 }
                dp = Double(n) * (x * p1 - p0) / (x * x - 1)
                let dx = p1 / dp
                x -= dx
                if abs(dx) < 1e-16 { break }
            }
            xs.append(x)
            ws.append(2 / ((1 - x * x) * dp * dp))
        }
        return (xs, ws)
    }

    /// Global interpolation through points with chord-length parameters (clamped uniform
    /// knots as above, so the result is a curve the kernel reproduces exactly). Poles = points.
    static func interpolate(_ Q: [(Double, Double)], degree p: Int) throws -> [(Double, Double)] {
        let n = Q.count
        guard n > p else { throw ForgeError(.invalidParams, "a degree-\(p) spline needs at least \(p + 1) points") }
        let U = knots(poles: n, degree: p)
        var chord = [0.0]
        for i in 1..<n { chord.append(chord[i - 1] + hypot(Q[i].0 - Q[i - 1].0, Q[i].1 - Q[i - 1].1)) }
        guard chord[n - 1] > 0 else { throw ForgeError(.invalidParams, "spline points must not all coincide") }
        let ts = chord.map { $0 / chord[n - 1] }
        // A[i][j] = N_j(t_i); solve A·P = Q by Gaussian elimination with partial pivoting.
        var A = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for (i, t) in ts.enumerated() {
            let k = span(t, U, poles: n, degree: p)
            let N = basis(t, k, U, degree: p)
            for j in 0...p { A[i][k - p + j] = N[j] }
        }
        var bx = Q.map(\.0), by = Q.map(\.1)
        for c in 0..<n {
            let piv = (c..<n).max { abs(A[$0][c]) < abs(A[$1][c]) }!
            guard abs(A[piv][c]) > 1e-12 else {
                throw ForgeError(.invalidParams, "these points cannot be interpolated by a degree-\(p) spline with uniform knots; space them more evenly or give control points")
            }
            A.swapAt(c, piv)
            bx.swapAt(c, piv)
            by.swapAt(c, piv)
            for r in (c + 1)..<n where A[r][c] != 0 {
                let f = A[r][c] / A[c][c]
                for k in c..<n { A[r][k] -= f * A[c][k] }
                bx[r] -= f * bx[c]
                by[r] -= f * by[c]
            }
        }
        var P = [(Double, Double)](repeating: (0, 0), count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sx = bx[r], sy = by[r]
            for k in (r + 1)..<n {
                sx -= A[r][k] * P[k].0
                sy -= A[r][k] * P[k].1
            }
            P[r] = (sx / A[r][r], sy / A[r][r])
        }
        return P
    }
}

extension Sketch {
    public static let maxSplineDegree = 5

    /// Spline by control points (poles). The first and last poles are the curve's ends; the
    /// poles are sketch points, so relations and dimensions apply to them directly.
    @discardableResult
    public mutating func addSpline(poles: [(Double, Double)], degree: Int = 3, construction: Bool = false) throws -> String {
        guard poles.count >= 2 else { throw ForgeError(.invalidParams, "a spline needs at least 2 control points") }
        guard (1...Self.maxSplineDegree).contains(degree) else { throw ForgeError(.invalidParams, "spline degree must be 1…\(Self.maxSplineDegree)") }
        return insertSpline(poles: poles, degree: min(degree, poles.count - 1), construction: construction)
    }

    mutating func insertSpline(poles: [(Double, Double)], degree p: Int, construction: Bool) -> String {
        let id = newID(.spline)
        // Interior poles are construction (they are handles, not geometry); the ends follow the curve.
        let pts = poles.enumerated().map { i, q in
            addPoint(q.0, q.1, construction: construction || (i > 0 && i < poles.count - 1), owner: id)
        }
        insert(SketchEntity(id: id, kind: .spline, construction: construction, owner: nil, points: pts, params: [], degree: p))
        return id
    }

    /// Spline through points (interpolated once; afterwards its control points are edited).
    @discardableResult
    public mutating func addSpline(through q: [(Double, Double)], degree: Int = 3, construction: Bool = false) throws -> String {
        guard q.count >= 2 else { throw ForgeError(.invalidParams, "a spline needs at least 2 points") }
        let p = min(degree, q.count - 1)
        return try addSpline(poles: try BSpline.interpolate(q, degree: p), degree: p, construction: construction)
    }

    func splinePoles(_ id: String) -> [(Double, Double)] { entities[id]!.points.map { point($0) } }

    /// Point on a spline at parameter t ∈ [0, 1].
    public func splinePoint(_ id: String, at t: Double) -> (Double, Double) {
        BSpline.point(splinePoles(id), degree: entities[id]!.degree ?? 3, at: t)
    }
}
