# ADR 0003 — 2D sketch constraint solver

- Status: accepted (implementation in M1)
- Date: 2026-09-23

## Context

SPEC §2 asks to evaluate FreeCAD's `planegcs` against a custom Newton-Raphson/DogLeg solver.
Requirements: DOF analysis, over/under-constrained diagnosis, drag solving, structured
(agent-readable) conflict reports, determinism, and a license compatible with closed
distribution (no GPL in-process).

Findings (FreeCAD **1.1.3**, the latest release on 2026-09-23):

- `planegcs` lives in `src/Mod/Sketcher/App/planegcs` under **LGPL 2.1+**. It implements
  DogLeg, Levenberg–Marquardt and BFGS, with QR-based redundancy/conflict detection (Eigen,
  MPL 2.0) — a proven design.
- It is not a standalone library: `GCS.cpp` includes FreeCAD's `Base/Console.h` and
  `FCConfig.h` and uses Boost.Graph for component decomposition. Using it means maintaining
  a fork, building Boost + Eigen for macOS, and dynamically linking a LGPL library we would
  patch (patched LGPL code must be released).
- Its diagnostics are index-based and tuned for FreeCAD's UI, not for structured,
  entity-id-based error reports with executable fixes (SPEC §5.4).

## Decision

Build a **custom solver** in `ForgeSketch` (Swift, with Accelerate/LAPACK on macOS and a
portable dense/sparse fallback for Linux CI), following the same proven structure:

1. Parameters (point x/y, radii, angles…) and constraint residual functions with analytic
   Jacobians.
2. Decomposition into independent connected components (union–find, deterministic order).
3. Per component: DogLeg trust-region (primary), Levenberg–Marquardt fallback.
4. **DOF & diagnosis:** rank of the Jacobian via column-pivoted QR (rank-revealing, with a
   scale-aware tolerance). Redundant constraints = dependent rows; conflicting = redundant
   and unsatisfied. Reported per constraint id with human text and suggested removals.
5. **Drag solving:** the dragged parameters become soft targets with low weight
   (minimal-movement solve), so unconstrained geometry follows and fixed geometry stays.
6. Determinism: fixed iteration order, no parallel reductions whose order can vary.

`planegcs` remains the **reference oracle**: an out-of-tree test harness (separate process,
not shipped) compares solutions and DOF counts on the M1 regression corpus.

## Consequences

- More initial work in M1 than wrapping planegcs, but full control of diagnostics,
  identifiers, determinism and licensing, and no Boost/FreeCAD build dependency.
- Revisit if the solver's robustness on the regression corpus falls short of planegcs.
