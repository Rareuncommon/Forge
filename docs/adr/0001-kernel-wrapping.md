# ADR 0001 — Kernel wrapping strategy

- Status: accepted (M0)
- Date: 2026-09-23

## Context

Forge uses Open CASCADE Technology (OCCT) as its B-rep kernel (SPEC §2). OCCT is a very large
C++ library with intrusive handles (`Handle(T)`), exceptions (`Standard_Failure`), global
state (e.g. `Interface_Static` in data exchange) and lazily-mutated shapes (meshing writes
triangulations into shared `TShape`s). SPEC requires that no OCCT type leaks outside
`ForgeKernel`, that the kernel is linked dynamically (LGPL 2.1 + OCCT exception), and that
regeneration is deterministic.

Versions verified on 2026-09-23: OCCT **8.0.1** is the latest release (tag `V8_0_1`);
Ubuntu 24.04 ships **7.6.3**. Swift **6.4.0** (Xcode 27, macOS 27 SDK). OCCT 7.8 renamed the
data-exchange toolkits (`TKSTEP*` → `TKDESTEP`, etc.).

Options considered:

1. **Swift/C++ interop directly over OCCT headers.** Swift 6 can import C++ APIs, but OCCT's
   templates, macros and `Handle` types import poorly, compile times explode, and every
   Swift file touching geometry would see OCCT types — violating the no-leak rule.
2. **A C++ façade consumed through Swift/C++ interop.** Better isolation, but still couples
   Swift build settings (`-cxx-interoperability-mode`) to every dependent module and
   exposes C++ exceptions/ownership at the boundary.
3. **A C ABI façade (`forge_kernel.h`) implemented in C++20.** Opaque handles, plain structs,
   error out-parameters.

## Decision

Option 3. `Sources/CForgeKernel` is a C++20 target whose only public header is pure C:

- Opaque `FKShape` / `FKMesh` handles; `fk_*_release` for ownership. Swift wraps them in
  `Shape` (final class, `@unchecked Sendable`) and `Mesh` (value type) in `ForgeKernel`.
- Every function catches `Standard_Failure`, `std::exception` and `...` and reports through
  `FKError { code, message }` — no exception crosses the ABI. Swift maps codes onto
  `ForgeError` (`kernel_failure`, `boolean_failed`, `empty_result`, …).
- **Shapes are immutable.** Operations return new handles. Tessellation meshes a deep copy
  (`BRepBuilderAPI_Copy`) so a shape can be read concurrently from any thread; the data
  exchange layer is serialised with a mutex because of OCCT's global parameters.
- **Determinism:** booleans run with `SetRunParallel(false)` and are followed by
  `ShapeUpgrade_UnifySameDomain`; topological indices follow `TopExp::MapShapes` order.
  Binary BREP output is canonicalised (write → read → write) because OCCT's reader sets
  per-TShape status flags, which otherwise makes `save(load(file)) != file`.
- Units: millimetres and radians throughout the ABI.
- The same source compiles against OCCT 7.6 (Linux CI) and 8.0.x (macOS app); the toolkit
  set is chosen in `Package.swift` by detecting `libTKDESTEP`.

## Consequences

- Adding kernel functionality means adding a C function + Swift wrapper: a little more
  boilerplate, in exchange for a hard isolation boundary, stable ABI, trivial Swift build
  settings, and the ability to swap or supplement the kernel later.
- Topological indices exposed by the kernel are *transient*. Stable identity is the job of
  the persistent-naming layer (ADR 0002), which will need generation history from OCCT's
  `BRepBuilderAPI_MakeShape::Generated/Modified/Deleted` — to be added to this ABI in M2.
