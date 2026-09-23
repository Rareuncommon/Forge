import Foundation

/// Arithmetic needed by constraint residuals. Residual functions are written once, generic
/// over this protocol, and evaluated either with `Double` (values) or `Dual` (values plus
/// exact partial derivatives — forward-mode automatic differentiation). This gives analytic
/// Jacobians without hand-derived derivative code (docs/adr/0003-sketch-solver.md).
public protocol SolverScalar {
    init(constant: Double)
    var value: Double { get }
    static func + (a: Self, b: Self) -> Self
    static func - (a: Self, b: Self) -> Self
    static func * (a: Self, b: Self) -> Self
    static func / (a: Self, b: Self) -> Self
    static prefix func - (a: Self) -> Self
    static func sqrt(_ a: Self) -> Self
    static func sin(_ a: Self) -> Self
    static func cos(_ a: Self) -> Self
    static func atan2(_ y: Self, _ x: Self) -> Self
}

extension SolverScalar {
    static func * (a: Self, k: Double) -> Self { a * Self(constant: k) }
    static func * (k: Double, a: Self) -> Self { Self(constant: k) * a }
    static func - (a: Self, k: Double) -> Self { a - Self(constant: k) }
    static func + (a: Self, k: Double) -> Self { a + Self(constant: k) }
}

extension Double: SolverScalar {
    public init(constant: Double) { self = constant }
    public var value: Double { self }
    public static func sqrt(_ a: Double) -> Double { a.squareRoot() }
    public static func sin(_ a: Double) -> Double { Foundation.sin(a) }
    public static func cos(_ a: Double) -> Double { Foundation.cos(a) }
    public static func atan2(_ y: Double, _ x: Double) -> Double { Foundation.atan2(y, x) }
}

/// Dual number with up to 16 partial derivatives (the most local parameters any sketch
/// constraint touches is 12: tangency between two arcs).
public struct Dual: SolverScalar {
    public var v: Double
    public var g: SIMD16<Double>

    public static let maxVariables = 16

    public init(constant: Double) {
        v = constant
        g = .zero
    }

    public init(variable value: Double, index: Int) {
        v = value
        g = .zero
        g[index] = 1
    }

    init(_ v: Double, _ g: SIMD16<Double>) {
        self.v = v
        self.g = g
    }

    public var value: Double { v }

    public static func + (a: Dual, b: Dual) -> Dual { Dual(a.v + b.v, a.g + b.g) }
    public static func - (a: Dual, b: Dual) -> Dual { Dual(a.v - b.v, a.g - b.g) }
    public static func * (a: Dual, b: Dual) -> Dual { Dual(a.v * b.v, a.g * b.v + b.g * a.v) }
    public static func / (a: Dual, b: Dual) -> Dual {
        let inv = 1 / b.v
        return Dual(a.v * inv, (a.g * b.v - b.g * a.v) * (inv * inv))
    }
    public static prefix func - (a: Dual) -> Dual { Dual(-a.v, -a.g) }

    public static func sqrt(_ a: Dual) -> Dual {
        let r = a.v.squareRoot()
        // At 0 the derivative is unbounded; use 0 (the solver treats it as a flat direction).
        return Dual(r, r > 1e-150 ? a.g * (0.5 / r) : .zero)
    }
    public static func sin(_ a: Dual) -> Dual { Dual(Foundation.sin(a.v), a.g * Foundation.cos(a.v)) }
    public static func cos(_ a: Dual) -> Dual { Dual(Foundation.cos(a.v), a.g * -Foundation.sin(a.v)) }
    public static func atan2(_ y: Dual, _ x: Dual) -> Dual {
        let d = x.v * x.v + y.v * y.v
        guard d > 1e-300 else { return Dual(0, .zero) }
        return Dual(Foundation.atan2(y.v, x.v), (y.g * x.v - x.g * y.v) * (1 / d))
    }
}

/// 2D vector over any solver scalar.
struct V2<D: SolverScalar> {
    var x: D
    var y: D

    static func + (a: V2, b: V2) -> V2 { V2(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: V2, b: V2) -> V2 { V2(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: V2, k: D) -> V2 { V2(x: a.x * k, y: a.y * k) }
    func dot(_ b: V2) -> D { x * b.x + y * b.y }
    func cross(_ b: V2) -> D { x * b.y - y * b.x }
    var length: D { D.sqrt(x * x + y * y) }
}
