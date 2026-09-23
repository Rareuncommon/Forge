# Progress

## Session 2 — 2026-09-23 — Milestone 1 (sketcher) + first sketch-to-solid

### CI status
- `linux-headless`: **green** on every pushed commit.
- `macos-app`: **green** on `b601dc4` (run #7, `macos-26` runner): OCCT 8.0.1 built from source
  and cached; engine + 110 tests + all golden models pass on macOS; **`ForgeApp` (SwiftUI) and
  `MetalViewportRenderer` compile and link** for the first time. The app has still not been
  *run* interactively (no display on CI), so orbit/pan/zoom/picking in the Metal viewport and
  the sketch UI remain unverified at runtime.

### Done this session (all verified on Linux, OCCT 7.6.3 and 8.0.1)
- **ForgeSketch** (new module): sketch model (points, lines, circles, arcs, ellipses,
  construction geometry, standard planes with offset), constraint solver per ADR 0003 with
  implementation notes (forward-mode AD Jacobians, minimum-norm Levenberg–Marquardt,
  creation-ordered rank analysis → DOF, per-entity fully/under/over-defined, redundant vs
  conflicting vs failed), dragging, relation inference from exact coordinates, rectangles
  (corner/center/3-point/parallelogram), slots (straight/center), polygons, sketch fillet
  with a virtual sharp that preserves dimensions, and profile analysis (closed loops,
  nesting, exact areas incl. arc segments, open ends, branches, crossings).
- **21 sketch commands** (`sketch.*`) with generated schemas; conflicts and redundancies are
  refused with executable fixes; sketches participate in undo/redo, transactions, dry-run,
  document state (incl. the sketch being edited), selection, render_view/pick (curves coloured
  by constraint state) and compare_to_spec (status, DOF, point positions, loops, area).
- **MCP:** `create_sketch`, `get_sketch`, `edit_dimension`, `check_sketch` (32 tools).
- **Sketch → solid:** kernel faces from profile regions (holes and islands), extrude, revolve;
  `body.extrude` (normal / reverse / mid-plane) and `body.revolve` (about a sketch line).
- **Tests:** 105 test functions incl. 40 seeded property tests of the solver; golden suite is
  now 22 models (16 body, 6 sketch), each regenerated twice for bit-identical results.

- **File format v1** (ADR 0004, new `ForgeData` module): `.forgepart` package with
  `manifest.json`, `model.json` (bodies + sketches, canonical sorted JSON), `bodies/*.brep`
  and a rendered thumbnail; atomic writes, schema-version check and a migration table.
  `document.save` / `document.open` commands and MCP `save` / `open` tools. Every golden
  model now does save → open → re-check spec → save and requires byte-identical files.
- **Sketch mirror and patterns:** `sketch.mirror` (copies related by symmetric relations —
  `symmetric` now also relates two lines, circles or arcs as wholes; an arc pair uses a
  5-row form so it is never redundant with the copy's internal radius), `sketch.pattern_linear`
  (1 or 2 directions, direction by angle or along a line) and `sketch.pattern_circular` (full
  or partial angle, about coordinates or a point/circle). Copies keep the seed's topology
  (coincident / on-curve / tangent), dropping relations the symmetry already implies. Golden
  model 017: a mirrored half profile extruded (analytic area 198 mm², 10 faces).
- **Trim and extend:** `sketch.trim` (power trim of lines, arcs and circles: end pieces,
  middle pieces that split the curve into collinear/coradial pieces, circle → arc, uncrossed
  curve deleted) and `sketch.extend` (lines and arcs to the next curve). New ends are held by
  coincident/on-curve relations; relations that depended on the removed extent are deleted
  and listed. Golden model 018: circle and chord trimmed to a segment and extruded.
- **Offset:** `sketch.offset` for chains of lines/arcs (corners extended/trimmed to meet,
  tangent joints kept smooth) and circles; one driving `offset` dimension (also available in
  `sketch.add_dimension`) with the other copies linked to it; bi-directional, line caps,
  base-to-construction. Golden model 019: rectangle offset, offset re-dimensioned, extruded
  as a frame. See ADR 0003 notes for how tangent joints avoid rank deficiency.
- **Move / copy / rotate / scale:** `sketch.move` (by a vector or from→to), `sketch.rotate`,
  `sketch.scale`, each in place or as copies. In place, relations to unmoved geometry are
  dropped unless `keep_relations`; rotation drops horizontal/vertical relations (a half turn
  keeps them and flips signed distances); scaling scales the dimensions among the scaled
  geometry. Stretch is not implemented.
- **Split:** `sketch.split` — a line or arc at one point, a circle at two points (into two
  concentric arcs). The solver's rank analysis now considers internal (structural) rows last,
  so relations that imply an arc's own radius equality are not reported redundant (ADR 0003).
- **Splines:** `sketch.add_spline` (through points or control points, degree 1–5) — solver,
  profiles (exact Green's-theorem areas), rendering, mirror/patterns/move, save/open, and a
  B-spline segment in the kernel bridge (`FK_SEG_BSPLINE`) so splines extrude and revolve.
  Golden model 020: spline profile extruded (area 360 mm², centroid ȳ = 45/7 derived with
  exact fractions). Then point-on-spline (the curve parameter is an extra solver unknown
  owned by the relation) and tangency at spline ends (with lines, arcs, splines). Spline
  trim/split/offset and tangency away from the ends are explicit `not_implemented` errors.
- **Partial ellipse:** `ellipse_arc` entity via `sketch.add_ellipse` with `start`/`end` —
  ends held on the ellipse by internal relations (7 DOF), exact loop areas (the affine image of
  the circular-segment formula), rendering, mirror/move/scale, and an elliptical-arc edge in the
  kernel bridge (`FK_SEG_ELLIPSE_ARC`; `FKSegment` grew to 13 doubles). Golden model 021: half
  ellipse extruded (volume 1000π, centroid height 40/3π).
- **Ellipse trim/split/extend:** intersections with ellipses are found along the ellipse's
  parameter from the other carrier's implicit form; pieces of one ellipse share its axis and
  rotation unknowns (so they stay one ellipse without extra relations) and are concentric.
  Golden model 022: ellipse trimmed by a chord (area and x-centroid analytic, DOF 6).
- **planegcs oracle:** FreeCAD 1.1.3's planegcs now builds out of tree here and in CI
  (`tools/planegcs-oracle`, three header shims, Eigen + Boost.Graph) as a test-only process.
  `PlanegcsOracleTests` compares DOF, redundancy/conflict verdicts and, for fully defined
  sketches, re-solved positions on the golden sketches plus 60 random sketches. Final run:
  44 position matches, 19 diagnosis-only agreements, 3 mirror-branch cases (planegcs's
  side-less tangency), 2 ill-conditioned (excluded from positions), 8 outside the mapped subset.

### Findings
- The oracle found three real solver problems, all fixed: (1) parallel/perpendicular could be
  "satisfied" by collapsing a line to zero length (cross/dot residuals) — now angle-based;
  (2) two opposite-side tangencies were "satisfied" by shrinking the circle to radius 0, and
  a right angle in a triangle with a horizontal and a vertical side shrank the base to
  1.5e-4 mm — a relation whose solution collapses a curve (to ~0, or 10⁴-fold as a side
  effect) is now refused as a conflict; the angle rows use atan2 so a solve from exactly
  perpendicular lines does not stall; (3) the earlier
  "internal rows last" rank order hid genuine redundancy (radius + centre-to-end distance on
  one arc) — only split pieces' implied rows now yield.
- Oracle-side limitations found and documented: planegcs's tangency has no side and its point
  symmetry is singular on the axis.
- The ellipse root-finder mishandled a sample lying exactly on the other curve (bisection
  from a zero end); a line along the major axis extended to (19.9992, 0.087) instead of
  (20, 0). Exact zeros are now recorded directly.
- The AD Jacobian seeded one SIMD16 lane per parameter a row touches, so any row over 16
  parameters (a spline with 7+ control points in a tangency) would have trapped. Rows are
  now differentiated in 16-parameter chunks; a 10-pole spline test covers it.
- Relation choice matters for rank: after a split the pieces share a point, which makes
  collinear's first row (line) and equal radius at diametral split points (circle)
  degenerate; the tests' exact DOF expectations caught both.
- Two of my new tests assumed an under-defined original stays put when a dimension changes;
  the minimum-norm solver moves both (correct). Tests now fully define the original or check
  the dimensioned quantity itself.
- Trimming a line to an arc's end first left the two joined only by position: the arc end's
  earlier on-line relation made the new coincidence look redundant. The trim now replaces
  that relation with the coincidence; golden 018 checks the resulting DOF (4).
- JSONEncoder wrote `-0` for a plane axis that decodes to `0`, so the second save differed.
  model.json is now written through `JSONValue` canonicalisation.
- Distance-form tangency is only second-order when the curves also share the tangent point,
  so the Jacobian lost rank and a legitimate slot was flagged over-defined. Fixed with a
  first-order endpoint-tangency form (recorded in ADR 0003).
- Tests caught an inverted orientation test in the three-point arc and a wrong assumption in
  one of my own tests (symmetry axis not anchored); both fixed.

### Not done / known gaps
- Sketch UI in the app (click-to-draw, dimension editing on canvas, DOF colouring in the
  Metal viewport) is not written; M1's "sketch UI" exit criterion is open. The command
  palette can already drive every sketch command.
- Pattern instances are placed exactly and tied to the seed's size, but spacing/angle are
  not yet dimensions that drive them; dynamic mirror is not implemented.
- Splines cannot be trimmed/split yet; trim is one pick per call.
- Offset: ellipses and arc-joined corners/arc caps are not implemented.
- Not started in 7.1: spline tools (tangency/curvature handles, fit, simplify), parabola, conic, text,
  move/copy/rotate/scale, split, and the other sketch tools, arc slots, 3D sketches,
  arc-length/path-length/ordinate/chain/baseline dimensions, equations in dimension fields.
- `body.extrude`/`body.revolve` are kernel-level (no feature tree yet), so nothing in §7 is
  "done" even though bodies and sketches now round-trip through the file format.
- Quick Look / Spotlight importers for the package are not written.

### Next steps
1. Run the app on a Mac (or add a UI smoke test) to verify the viewport and sketch UI at runtime.
2. Remaining M1: stretch, spline tools (fit/simplify/curvature), conics/parabola, text.
3. M2: feature tree + regeneration engine per ADR 0011 (proposed): kernel history ABI and
   named shapes first, then sketch + extrude as the first parametric features, then file
   format v2 with v1 migration.

## Session 1 — 2026-09-23 — Milestone 0 (foundations)

Environment: cloud Linux container (Ubuntu 24.04, x86_64, 4 cores). **No macOS machine was
available**, so everything headless was built and tested here; the Metal viewport, SwiftUI
app and macOS CI job were written but never compiled. That is the one M0 exit criterion not
yet met (see "Not verified").

### 1. Dependency verification (SPEC §10.1), checked against live sources

| Item | Finding | Source |
|---|---|---|
| Xcode / Swift / macOS SDK | Xcode 27 (released 2026-09-14) ships **Swift 6.4** and the **macOS 27 SDK**; requires macOS Tahoe 26.6+ | Apple Xcode 27 release notes |
| Swift on Linux | **6.4.0** release (swift.org install API); installed and used here | swift.org |
| OCCT | Latest release **8.0.1** (`V8_0_1`); license LGPL 2.1 + Open CASCADE exception 1.0. Ubuntu 24.04 ships 7.6.3. OCCT 8 changed `Standard_Failure` (now a `std::exception`, no `DynamicType()`); 7.8+ renamed data-exchange toolkits (`TKDESTEP`…) | github.com/Open-Cascade-SAS/OCCT tags, `LICENSE_LGPL_21.txt`, `OCCT_LGPL_EXCEPTION.txt` |
| MCP Swift SDK | **0.12.1**, MIT, targets MCP spec **2025-11-25**, supports Linux; depends on `swift-docc-plugin` at `branch: main` and swift-nio; no Unix-socket server transport | github.com/modelcontextprotocol/swift-sdk |
| planegcs | Part of FreeCAD **1.1.3**, LGPL 2.1+; depends on FreeCAD `Base/Console.h`, Boost.Graph, Eigen — not standalone | FreeCAD `src/Mod/Sketcher/App/planegcs/GCS.cpp` |
| Netgen | **v6.2.2607**, LGPL 2.1 | github.com/NGSolve/netgen |

### 2. ADRs written (SPEC §10.2)

0001 kernel wrapping (C ABI) · 0002 persistent naming · 0003 sketch solver (custom, planegcs
as oracle) · 0004 file format · 0005 GPL process boundary · 0006 MCP server (own
implementation) · 0007 build & CI · 0008 command schema from Swift types · 0009 viewport
rendering & picking · 0010 SolidWorks native files (proposed; needs an owner decision).

### 3. FEATURES.md (SPEC §10.3)

Generated from SPEC §7 by `scripts/features.py`: 931 spec rows (items + sub-variants), 56
platform rows, 8 "discovered" SolidWorks capabilities not in the spec. Totals: 945 not
started · 28 in progress · 22 done · 0 verified. No §7 item is "done" — the M0 body commands
work below the feature tree, so they are "in progress" by the SPEC §0.2 definition.

### 4. Milestone 0 — what exists and is verified (Linux)

- **Build system:** SwiftPM package (Swift 6 language mode + `ExistentialAny`), C++20 bridge
  target, OCCT located via `FORGE_OCCT_PREFIX` with automatic 7.x/8.x toolkit detection.
- **OCCT build script:** `scripts/build-occt.sh` built **OCCT 8.0.1 from source** here
  (shared, headless modules, `$ORIGIN`/`@loader_path` rpaths). The xcframework step is
  macOS-only and unverified.
- **ForgeKernel bridge:** primitives, booleans (+ same-domain unification), transform,
  constant fillet, topology/mass/bbox/validity/face/edge/distance queries, tessellation with
  face/edge IDs, canonical binary BREP, STEP export/import, STL export. Verified against
  **both OCCT 7.6.3 and 8.0.1** (full test suite + golden models green on each).
- **ForgeCommands:** 39 commands; schemas generated from Swift types; unit-aware params;
  structured errors with executable fixes; undo/redo, transactions, dry-run, atomic batch,
  journal; explicit selection and active-document state.
- **forge-cli:** `run` (scripts + expectations), `exec`, `commands`, `describe`, `search`,
  `mcp [--socket]`, `version`.
- **MCP server:** JSON-RPC over stdio and Unix socket; 28 tools generated from the registry
  (discovery, document, query, execute/batch/undo/redo/transactions, render_view,
  render_multiview, pick, validate_model, compare_to_spec, export); 3 resources with
  update notifications; 2 prompts. End-to-end tested in-process, over a real socket, and
  through the `forge-cli mcp` binary.
- **Rendering:** camera (orbit/turntable/pan/zoom-to-cursor, standard views, rays),
  software rasterizer with ID buffers, edge-preferring picking, CPU ray picker (tested to
  agree with the ID buffer), in-tree PNG/deflate encoder validated against reference zlib.
  See `docs/images/`.
- **Tests:** 68 test functions (Swift Testing) across 6 targets; 12 golden models with
  analytically derived expectations (volumes, areas, centroids, bboxes, topology),
  each also regenerated twice to assert bit-identical BREP.
- **CI:** `.github/workflows/ci.yml` — the Linux job's steps were all run locally in this
  session; it has not yet run on GitHub.

Findings worth recording:
- OCCT's BREP reader sets per-shape "checked" flags, so naive save(load(file)) ≠ file. Fixed
  by canonicalising on write (ADR 0001).
- A golden spec was wrong, not the kernel: a radius-10 pocket in a 20 mm face is tangent to
  all four edges and splits the face into 4 (10 faces). Model changed to radius 8.
- Swift's non-generic `decodeIfPresent` overloads route through `decode`; the schema
  recorder overrides all of them so optional primitives aren't marked required.

### 5. Not verified / known gaps (honest list)

- **Metal viewport + SwiftUI app never compiled** (`Sources/ForgeRender/MetalViewportRenderer.swift`,
  `Sources/ForgeApp/*`). M0's "Metal viewport rendering a tessellated OCCT box with
  orbit/pan/zoom and picking" is therefore **not yet met on macOS**; the equivalent pipeline
  is verified headlessly (software renderer + ID-buffer picking).
- `scripts/make-app-bundle.sh` and the `macos-app` CI job are unverified; the runner label
  `macos-26` + Xcode 27 path must be confirmed against GitHub's current runner images.
- The app builds the render scene (tessellation) on the main actor; move it off-main.
- Command palette takes JSON params (inline typed entry pending); inspector is read-only.
- Cancellation of long commands is not implemented (Engine runs commands serially).
- M0 entity references (`body-1/face-3`) are transient kernel indices by design (ADR 0002).

### 6. Next steps

1. On a Mac with Xcode 27: `scripts/build-occt.sh`, `swift build`, `swift run ForgeApp`;
   fix compile errors in the Metal/SwiftUI code; confirm orbit/pan/zoom/picking on a box;
   get the `macos-app` CI job green. This closes M0.
2. M1 (sketch): `ForgeSketch` entities, custom DogLeg/LM solver with QR-based DOF and
   conflict diagnosis (ADR 0003), dimensions, sketch commands + MCP tools, solver
   regression corpus, planegcs oracle harness (out of tree).
3. Owner decisions pending: ADR 0010 (Parasolid licensing / SolidWorks file strategy);
   whether GPL solver binaries may be bundled in releases (ADR 0005 §3).
