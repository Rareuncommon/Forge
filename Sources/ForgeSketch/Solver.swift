import ForgeCore
import Foundation

public enum SolveStatus: String, Codable, Sendable, SchemaEnum {
    /// All constraints satisfied, some freedom remains.
    case underDefined = "under_defined"
    /// All constraints satisfied, no freedom remains.
    case fullyDefined = "fully_defined"
    /// Satisfied, but some constraints are redundant (implied by others).
    case redundant
    /// Constraints contradict each other; the listed ones cannot all hold.
    case conflicting
    /// The solver did not converge although no contradiction was identified.
    case failed
}

public enum EntityState: String, Codable, Sendable, SchemaEnum {
    case underDefined = "under_defined", fullyDefined = "fully_defined", overDefined = "over_defined"
}

public struct SolveReport: Codable, Sendable, Hashable {
    public var status: SolveStatus
    /// Remaining degrees of freedom.
    public var dof: Int
    public var iterations: Int
    public var maxResidual: Double
    /// Constraints implied by earlier ones (satisfied but superfluous).
    public var redundant: [String]
    /// Constraints that cannot be satisfied together with earlier ones.
    public var conflicting: [String]
    /// Per-entity constraint state, in entity order.
    public var entityStates: [String: EntityState]

    enum CodingKeys: String, CodingKey {
        case status, dof, iterations, redundant, conflicting
        case maxResidual = "max_residual"
        case entityStates = "entity_states"
    }
}

/// Deterministic sketch solver (docs/adr/0003-sketch-solver.md).
///
/// 1. Parameters of fixed entities (the origin, `fix` relations, temporarily dragged points)
///    are removed from the unknowns.
/// 2. Constraints are split into independent components (union–find over shared unknowns).
/// 3. Each component is solved by Levenberg–Marquardt in its dual (minimum-norm) form,
///    δ = −Jᵀ (J Jᵀ + λI)⁻¹ r, so under-constrained geometry moves as little as possible.
/// 4. Diagnosis: rows of the exact (forward-mode AD) Jacobian are orthogonalised in creation
///    order; rows dependent on earlier ones are redundant (or conflicting if the system is
///    unsatisfied). Rank gives the DOF; the row space tells which parameters are determined.
public enum SketchSolver {
    public static func solve(_ sketch: inout Sketch, extraFixed: Set<Int> = [], maxIterations: Int = 200) -> SolveReport {
        // Parameters in use and fixed ones.
        var used = Set<Int>()
        for e in sketch.entities.values { used.formUnion(e.params) }
        var fixed = Set(sketch.entities[Sketch.originID]!.params).union(extraFixed)
        for c in sketch.constraints where c.kind == .fix {
            for e in c.entities { fixed.formUnion(sketch.paramIndices(e) + (sketch.entities[e]?.params ?? [])) }
        }
        let unknowns = used.subtracting(fixed).sorted()
        let scale = max(1, sketch.params.map(abs).max() ?? 1)
        let tol = 1e-10 * scale

        // Rows (constraint, local params) — only active constraints.
        struct Row {
            var constraint: Int
            var params: [Int]
            var count: Int
        }
        var rows: [Row] = []
        for (i, c) in sketch.constraints.enumerated() {
            let n = sketch.rowCount(c)
            guard n > 0 else { continue }
            rows.append(Row(constraint: i, params: sketch.constraintParams(c), count: n))
        }

        // Union–find over unknowns.
        var parent = Dictionary(uniqueKeysWithValues: unknowns.map { ($0, $0) })
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r]! != r { r = parent[r]! }
            var y = x
            while parent[y]! != r {
                let next = parent[y]!
                parent[y] = r
                y = next
            }
            return r
        }
        for row in rows {
            let us = row.params.filter { parent[$0] != nil }
            guard let first = us.first else { continue }
            for u in us.dropFirst() {
                let a = find(first), b = find(u)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        var components: [Int: (params: [Int], rows: [Int])] = [:]
        for u in unknowns { components[find(u), default: ([], [])].params.append(u) }
        var constantRows: [Int] = []
        for (ri, row) in rows.enumerated() {
            if let u = row.params.first(where: { parent[$0] != nil }) {
                components[find(u)]!.rows.append(ri)
            } else {
                constantRows.append(ri)
            }
        }

        var redundant = Set<String>(), conflicting = Set<String>()
        var determined = Set<Int>(fixed)
        var rank = 0
        var iterations = 0
        var failed = false

        // Rows touching only fixed parameters: satisfied → redundant, else conflicting.
        for ri in constantRows {
            let c = sketch.constraints[rows[ri].constraint]
            let r = sketch.residuals(c) { sketch.params[$0] }
            if r.allSatisfy({ abs($0.value) <= tol * 10 }) { redundant.insert(c.id) } else { conflicting.insert(c.id) }
        }

        for key in components.keys.sorted() {
            let comp = components[key]!
            let local = comp.params
            let index = Dictionary(uniqueKeysWithValues: local.enumerated().map { ($1, $0) })
            let compRows = comp.rows
            let m = compRows.reduce(0) { $0 + rows[$1].count }
            let n = local.count
            if m == 0 { continue }

            func evaluate(_ values: [Double], jacobian: Bool) -> (r: [Double], J: [[Double]]) {
                var r = [Double](), J = [[Double]]()
                r.reserveCapacity(m)
                for ri in compRows {
                    let row = rows[ri]
                    let c = sketch.constraints[row.constraint]
                    if jacobian {
                        let slot = Dictionary(uniqueKeysWithValues: row.params.enumerated().map { ($1, $0) })
                        let res: [Dual] = sketch.residuals(c) { g in
                            if let li = index[g] { return Dual(variable: values[li], index: slot[g]!) }
                            return Dual(constant: sketch.params[g])
                        }
                        for d in res {
                            r.append(d.v)
                            var jr = [Double](repeating: 0, count: n)
                            for (k, g) in row.params.enumerated() { if let li = index[g] { jr[li] = d.g[k] } }
                            J.append(jr)
                        }
                    } else {
                        let res: [Double] = sketch.residuals(c) { g in index[g].map { values[$0] } ?? sketch.params[g] }
                        r.append(contentsOf: res)
                    }
                }
                return (r, J)
            }

            var x = local.map { sketch.params[$0] }
            var (r, J) = evaluate(x, jacobian: true)
            var cost = r.reduce(0) { $0 + $1 * $1 }
            var lambda = 1e-9
            var converged = r.allSatisfy { abs($0) <= tol }
            var it = 0
            while !converged && it < maxIterations {
                it += 1
                // A = J Jᵀ + λ I
                var A = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
                var trace = 0.0
                for i in 0..<m {
                    for j in i..<m {
                        var s = 0.0
                        for k in 0..<n { s += J[i][k] * J[j][k] }
                        A[i][j] = s
                        A[j][i] = s
                    }
                    trace += A[i][i]
                }
                let mu = lambda * max(trace / Double(m), 1e-12)
                for i in 0..<m { A[i][i] += mu }
                guard let y = LinearAlgebra.choleskySolve(A, r) else {
                    lambda *= 10
                    if lambda > 1e12 { break }
                    continue
                }
                var step = [Double](repeating: 0, count: n)
                for k in 0..<n {
                    var s = 0.0
                    for i in 0..<m { s += J[i][k] * y[i] }
                    step[k] = -s
                }
                let trial = zip(x, step).map { $0 + $1 }
                let tr = evaluate(trial, jacobian: false).r
                let trialCost = tr.reduce(0) { $0 + $1 * $1 }
                if trialCost < cost {
                    x = trial
                    (r, J) = evaluate(x, jacobian: true)
                    cost = trialCost
                    lambda = max(lambda / 3, 1e-15)
                    converged = r.allSatisfy { abs($0) <= tol }
                } else {
                    lambda *= 4
                    if lambda > 1e12 { break }
                }
            }
            iterations += it
            if converged {
                for (li, g) in local.enumerated() { sketch.params[g] = x[li] }
            } else {
                failed = true
                // Keep the pre-solve geometry for an unsatisfiable component, but diagnose at
                // the best point found.
            }

            // Diagnosis: Gram–Schmidt over rows in creation order.
            var basis: [[Double]] = []
            var rowIndex = 0
            for ri in compRows {
                let c = sketch.constraints[rows[ri].constraint]
                var dependent = false
                for _ in 0..<rows[ri].count {
                    var v = J[rowIndex]
                    rowIndex += 1
                    let norm0 = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
                    if norm0 < 1e-12 {
                        dependent = true
                        continue
                    }
                    for _ in 0..<2 {
                        for b in basis {
                            var d = 0.0
                            for k in 0..<n { d += v[k] * b[k] }
                            for k in 0..<n { v[k] -= d * b[k] }
                        }
                    }
                    let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
                    if norm < 1e-8 * norm0 {
                        dependent = true
                    } else {
                        basis.append(v.map { $0 / norm })
                    }
                }
                if dependent && !c.isInternal {
                    if converged { redundant.insert(c.id) } else { conflicting.insert(c.id) }
                }
            }
            rank += basis.count
            for (li, g) in local.enumerated() {
                let inRowSpace = basis.reduce(0) { $0 + $1[li] * $1[li] }
                if 1 - inRowSpace < 1e-8 { determined.insert(g) }
            }
        }

        let unknownCount = unknowns.count
        let dof = unknownCount - rank
        var maxResidual = 0.0
        for c in sketch.constraints where sketch.rowCount(c) > 0 {
            for v in sketch.residuals(c, { sketch.params[$0] }) { maxResidual = max(maxResidual, abs(v)) }
        }

        // Entity states.
        let troubled = redundant.union(conflicting)
        var overEntities = Set<String>()
        for c in sketch.constraints where troubled.contains(c.id) { overEntities.formUnion(c.entities) }
        var states: [String: EntityState] = [:]
        for e in sketch.orderedEntities {
            let ps = e.kind == .point ? e.params : sketch.paramIndices(e.id)
            if overEntities.contains(e.id) {
                states[e.id] = .overDefined
            } else {
                states[e.id] = ps.allSatisfy(determined.contains) ? .fullyDefined : .underDefined
            }
        }

        let status: SolveStatus
        if !conflicting.isEmpty {
            status = .conflicting
        } else if failed {
            status = .failed
        } else if !redundant.isEmpty {
            status = .redundant
        } else {
            status = dof == 0 ? .fullyDefined : .underDefined
        }
        let order = Dictionary(uniqueKeysWithValues: sketch.constraints.enumerated().map { ($1.id, $0) })
        let report = SolveReport(
            status: status, dof: dof, iterations: iterations, maxResidual: maxResidual,
            redundant: redundant.sorted { order[$0]! < order[$1]! }, conflicting: conflicting.sorted { order[$0]! < order[$1]! },
            entityStates: states)
        sketch.report = report
        return report
    }
}

enum LinearAlgebra {
    /// Solve A x = b for symmetric positive-definite A; nil if not SPD.
    static func choleskySolve(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var s = A[i][j]
                for k in 0..<j { s -= L[i][k] * L[j][k] }
                if i == j {
                    guard s > 0, s.isFinite else { return nil }
                    L[i][i] = s.squareRoot()
                } else {
                    L[i][j] = s / L[j][j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = b[i]
            for k in 0..<i { s -= L[i][k] * y[k] }
            y[i] = s / L[i][i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for k in (i + 1)..<n { s -= L[k][i] * x[k] }
            x[i] = s / L[i][i]
        }
        return x
    }
}
