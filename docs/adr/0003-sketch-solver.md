# ADR 0003 — 2D sketch constraint solver

- Status: accepted; implemented in M1 (see "Implementation notes")
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

## Implementation notes (M1, 2026-09-23)

- **Exact Jacobians by forward-mode AD.** Residuals are written once, generic over a
  `SolverScalar` protocol, and evaluated with `Double` or with a dual number carrying 16
  partials (`SIMD16<Double>`; the largest constraint touches 12 parameters). No hand-derived
  derivatives, no finite differences.
- **Solve:** components by union–find; Levenberg–Marquardt in dual form
  δ = −Jᵀ(JJᵀ + λI)⁻¹r (Cholesky), giving minimum-norm steps so free geometry moves least.
  Dense linear algebra is in-tree (Linux has no Accelerate); fine for sketch sizes to date.
- **Diagnosis:** Jacobian rows are orthogonalised (modified Gram–Schmidt, twice) in
  constraint creation order, so the *newest* dependent constraint is the one reported.
  Satisfied + dependent → `redundant`; unsatisfied + dependent → `conflicting`; unsatisfied
  and independent → `failed`. A parameter is "determined" when its unit vector lies in the
  row space; an entity is fully defined when all its parameters are.
- **Policy:** `sketch.add_relation` / `add_dimension` / `set_dimension` refuse changes that
  make the sketch redundant, conflicting or unsolvable (`sketch_redundant`,
  `sketch_conflict`, `solver_failed`) and return executable fixes (add as driven, delete the
  conflicting constraint). The sketch is never left over-defined by a command.
- **Lesson — tangency at a shared endpoint:** the distance form |d(centre, line)| = r is only
  second-order at the tangent point when the curves also share that point, which makes the
  Jacobian rank-deficient and flagged a legitimate slot as over-defined. Tangency between
  curves that share an endpoint therefore uses a first-order *endpoint* form (line ⟂ radius
  at the point; arc–arc: centres collinear with the point), chosen when the constraint is
  created. Distance form is kept for unconnected curves.
- **Orientation (`side`)** of signed constraints (line–circle side, internal/external
  tangency, horizontal/vertical dimension sign, angle sense) is fixed at creation from the
  current geometry, keeping residuals smooth and solutions near the drawn configuration.
- **Dragging:** the dragged point is held at the target and the rest solved; if that is
  impossible the whole sketch is solved from the target (minimal movement).
- **Tests:** unit tests with analytic answers, 40 seeded property tests (random closed
  polygons + circle, dimensions measured from a known configuration, parameters perturbed,
  re-solved), and golden sketch models. The planegcs oracle harness is still to do.
