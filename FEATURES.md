# Forge feature parity matrix

Source of truth for parity (SPEC §0.3). Generated from SPEC.md §7 by `scripts/features.py`,
which preserves the Status / Module / Test / MCP tool / Notes columns of existing rows —
edit those columns by hand, then re-run the script.

**Status definitions** (SPEC §0.2): `not started` · `in progress` (partial, or working below
the feature-tree level) · `done` (regenerates, round-trips save/load, undo/redo, command +
MCP, tests) · `verified` (done + golden/e2e coverage + reviewed on macOS).

**Totals:** 995 rows — not started: 873 · in progress: 100 · done: 22 · verified: 0

## Platform (SPEC §2–§6, §8–§9)

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `P/kernel-bridge` | Kernel bridge: C ABI over OCCT, no OCCT types outside ForgeKernel (§2, §3) | done | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift | — | C ABI (docs/adr/0001). Tested on Linux with OCCT 7.6.3; OCCT 8.0.1 compile check in PROGRESS.md |
| `P/kernel-primitives` | Kernel: primitives (box, cylinder, cone, sphere, torus) | done | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift | execute:body.create_* |  |
| `P/kernel-booleans` | Kernel: booleans with same-domain unification | done | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift | execute:body.boolean | ShapeUpgrade_UnifySameDomain after every boolean |
| `P/kernel-queries` | Kernel: topology, mass properties, bbox, validity, face/edge descriptors, distance | done | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift | query_faces, query_edges, get_mass_properties, measure |  |
| `P/kernel-tessellation` | Kernel: tessellation with face/edge IDs for picking | done | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift | — | meshes a private copy so shapes stay immutable |
| `P/kernel-brep-io` | Kernel: binary BREP serialisation (canonical, byte-stable) | done | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift | — | canonicalised write→read→write; save(load(x)) byte-identical |
| `P/command-bus` | Single command bus (Engine actor) (§3) | done | ForgeCommands | Tests/ForgeCommandsTests/EngineTests.swift | execute |  |
| `P/command-schema` | Command schema generated from Swift types (§5.1) | done | ForgeCore / ForgeCommands | Tests/ForgeCoreTests/CoreTests.swift, Tests/ForgeCommandsTests/EngineTests.swift | describe_command | recording Decoder derives schemas from init(from:) (docs/adr/0008) |
| `P/units` | Unit-aware parameters: "25 mm", "1 in", bare numbers in document units (§5.4) | done | ForgeCore | Tests/ForgeCoreTests/CoreTests.swift | — | length (mm, cm, m, um, in, ft) and angle (deg, rad); other quantities as needed |
| `P/structured-errors` | Structured errors with executable suggested fixes (§5.4) | done | ForgeCore | Tests/ForgeCommandsTests/EngineTests.swift, Tests/ForgeMCPTests/MCPTests.swift | (all tools) |  |
| `P/undo-redo` | Undo/redo (§4, §6.2) | done | ForgeCommands | Tests/ForgeCommandsTests/EngineTests.swift | undo, redo | document snapshots; delta history when the feature tree lands |
| `P/transactions` | Transactions: begin/commit/rollback (§5.1) | done | ForgeCommands | Tests/ForgeCommandsTests/EngineTests.swift | begin_transaction, commit_transaction, rollback_transaction |  |
| `P/dry-run` | dry_run with predicted changes (§5.1) | done | ForgeCommands | Tests/ForgeCommandsTests/EngineTests.swift, Tests/ForgeMCPTests/MCPTests.swift | execute(dry_run), execute_batch(dry_run) |  |
| `P/batch` | Batch execution (atomic) (§5.1) | done | ForgeCommands | Tests/ForgeCommandsTests/EngineTests.swift, Tests/ForgeMCPTests/MCPTests.swift | execute_batch |  |
| `P/explicit-state` | No hidden state: selection/active document explicit & queryable (§5.4) | in progress | ForgeCommands | Tests/ForgeCommandsTests | get_document_state | selection, active document, active sketch (edit mode) explicit; active configuration arrives with configurations |
| `P/journal` | Command journal replayable as a script (macro recorder foundation) (§5.3) | in progress | ForgeCommands | Tests/ForgeCommandsTests/EngineTests.swift | resource forge://document/journal | replayable; uses transient refs until persistent naming (M2) |
| `P/forge-cli` | forge-cli headless engine (§3) | done | forge-cli | CI golden run | — | run, exec, commands, describe, search, mcp, version |
| `P/golden-models` | Golden-model regression suite (§9) | in progress | Tests | Tests/GoldenModelTests | compare_to_spec | 22 models (16 body, 6 sketch) with analytic expectations |
| `P/determinism` | Deterministic regeneration, bit-for-bit (§3) | in progress | ForgeKernel / ForgeCommands | Tests/GoldenModelTests | — | bit-identical BREP across regenerations tested; persistent IDs pending (M2) |
| `P/mcp-stdio` | MCP server over stdio (§5) | done | ForgeMCP | Tests/ForgeMCPTests/MCPTests.swift | — | own JSON-RPC implementation (docs/adr/0006); protocol 2025-11-25 with fallbacks |
| `P/mcp-socket` | MCP server over local Unix socket (§5) | done | ForgeMCP | Tests/ForgeMCPTests/MCPTests.swift | — | 0600 permissions |
| `P/mcp-discovery` | MCP tools: list_commands, describe_command, search_commands (§5.2) | done | ForgeMCP | Tests/ForgeMCPTests/MCPTests.swift | list_commands, describe_command, search_commands |  |
| `P/mcp-document` | MCP tools: new_document, list_documents, get_document_state (§5.2) | done | ForgeMCP | Tests/ForgeMCPTests/MCPTests.swift | new_document, list_documents, activate_document, get_document_state |  |
| `P/mcp-open-save` | MCP tools: open, save (§5.2) | in progress | ForgeMCP | Tests/ForgeCommandsTests/FileTests.swift | open, save | bodies + sketches; no feature tree yet |
| `P/mcp-export` | MCP tools: export (§5.2) | done | ForgeMCP | Tests/ForgeCommandsTests/EngineTests.swift | export_step, export_stl |  |
| `P/mcp-mutate` | MCP tools: execute, execute_batch, undo, redo, transactions (§5.2) | done | ForgeMCP | Tests/ForgeMCPTests/MCPTests.swift | execute, execute_batch, undo, redo, *_transaction | edit_feature/edit_dimension/set_parameter/delete need the feature tree (M2) |
| `P/mcp-feature-tools` | MCP tools: get_feature_tree, get_feature, get_sketch, edit_feature, edit_dimension, set_parameter, get_parameters, get_errors, explain_error (§5.2) | in progress | ForgeMCP | Tests/ForgeMCPTests/MCPTests.swift | get_sketch, edit_dimension | get_sketch and edit_dimension done; feature-tree tools need M2 |
| `P/mcp-query-geometry` | MCP tool: query_geometry (semantic references, §4.3) | not started | — | — | — |  |
| `P/mcp-vision` | MCP tools: render_view, render_multiview, pick (§5.2) | in progress | ForgeMCP / ForgeRender | Tests/ForgeMCPTests/MCPTests.swift, Tests/ForgeCommandsTests/EngineTests.swift | render_view, render_multiview, pick | section parameter pending |
| `P/mcp-verification` | MCP tools: validate_model, compare_to_spec (§5.2) | in progress | ForgeMCP / ForgeCommands | Tests/ForgeMCPTests/MCPTests.swift, Tests/GoldenModelTests | validate_model, compare_to_spec | validate_model: validity + free edges; self-intersection/zero-thickness detail and explain_error pending |
| `P/mcp-interference` | MCP tool: check_interference (§5.2) | not started | — | — | — |  |
| `P/mcp-resources` | MCP resources + update notifications (§5.2) | in progress | ForgeMCP | Tests/ForgeMCPTests/MCPTests.swift | forge://commands, forge://document/state, forge://document/journal | feature tree & parameter resources pending (M2) |
| `P/mcp-prompts` | MCP prompts (§5.2) | in progress | ForgeMCP | Tests/ForgeMCPTests/MCPTests.swift | model_from_description, verify_model | drawing/static-study prompts land with M5/M7 |
| `P/plugins-swift` | Swift plugin bundles: commands, features, panels, translators (§5.3) | not started | — | — | — |  |
| `P/scripting-js` | JavaScriptCore scripting (§5.3) | not started | — | — | — |  |
| `P/scripting-python` | Python via forge-cli/socket (§5.3) | not started | — | — | — |  |
| `P/macro-recorder` | Macro recorder with semantic references (§5.3) | not started | — | — | — |  |
| `P/feature-tree` | Feature tree: rollback, reorder, suppress, freeze, folders, errors (§4.1) | not started | — | — | — |  |
| `P/persistent-naming` | Persistent naming (§4.2) | not started | — | — | — |  |
| `P/semantic-refs` | Semantic references (§4.3) | not started | — | — | — |  |
| `P/parameters` | Global variables, equations, linked dims, design tables, configurations (§4.4) | not started | — | — | — |  |
| `P/file-format` | Package file format, schema migration, Quick Look/Spotlight (§4.5) | in progress | ForgeData | Tests/ForgeCommandsTests/FileTests.swift, Tests/GoldenModelTests/GoldenModelTests.swift | execute:document.save, execute:document.open | v1 package (ADR 0004): manifest, model.json, BREP bodies, thumbnail; byte-identical save→open→save; migration table empty; Quick Look/Spotlight NOT IMPLEMENTED |
| `P/background-regen` | Background regeneration with cancellation (§3) | in progress | ForgeCommands | — | — | Engine actor keeps work off the main thread; cancellation pending (M2) |
| `P/metal-viewport` | Metal viewport: shaded+edges, orbit/pan/zoom, GPU picking (§2, M0) | in progress | ForgeRender | — | — | unverified: written, never compiled (Linux session). See PROGRESS.md |
| `P/headless-render` | Headless software renderer + PNG (render_view backend) | done | ForgeRender | Tests/ForgeRenderTests/RenderTests.swift | render_view |  |
| `P/app-shell` | SwiftUI app shell (§1.4) | in progress | ForgeApp | — | — | written, never compiled (Linux session) |
| `P/command-palette` | Command palette ⌘K with inline parameter entry (§6.1) | in progress | ForgeApp | — | — | search + JSON params; inline typed entry pending |
| `P/inspector` | Inspector panel instead of modal PropertyManagers (§6.2) | in progress | ForgeApp | — | — | read-only entity descriptors |
| `P/handles` | Direct-manipulation handles (§6.3) | not started | — | — | — |  |
| `P/explainable-failures` | Explainable failures in the viewport (§6.4) | not started | — | — | — |  |
| `P/smart-selection` | Smart selection, filters, select-other (§6.5) | not started | — | — | — |  |
| `P/input-devices` | Trackpad gestures, 3Dconnexion, Pencil/Sidecar, keymaps (§1.4, §6.9) | in progress | ForgeApp | — | — | mouse + trackpad written, unverified; 3Dconnexion/keymaps pending |
| `P/accessibility` | VoiceOver, keyboard-only, high contrast, Dynamic Type (§6.10) | not started | — | — | — |  |
| `P/performance` | Performance targets + benchmarks with regression alerts (§6.11, §9) | not started | — | — | — |  |
| `P/ci` | CI running headless tests (M0) | in progress | .github/workflows | — | — | Linux headless job verified locally; macOS job unverified |
| `P/fuzzing` | Import fuzzing (§9) | not started | — | — | — |  |

## 7.1 Sketching (2D and 3D)

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.1/entities/line` | Entities: line | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_line | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/entities/centerline` | Entities: centerline | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_line(construction) | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/entities/midpoint-line` | Entities: midpoint line | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_line(midpoint) | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/entities/rectangle` | Entities: rectangle | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_rectangle | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/entities/rectangle/corner` | ↳ corner | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_rectangle | DOF 4 tested |
| `7.1/entities/rectangle/center` | ↳ center | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_rectangle | construction diagonal + midpoint centre |
| `7.1/entities/rectangle/3-point` | ↳ 3-point | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_rectangle | DOF 5 tested |
| `7.1/entities/rectangle/parallelogram` | ↳ parallelogram | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_rectangle | DOF 6 tested |
| `7.1/entities/slot` | Entities: slot | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_slot | straight and center-point slots; arc slots not started |
| `7.1/entities/slot/straight` | ↳ straight | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_slot | DOF 5, exact area tested; golden 102 |
| `7.1/entities/slot/center` | ↳ center | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_slot |  |
| `7.1/entities/slot/arc` | ↳ arc | not started | ForgeSketch | — | — |  |
| `7.1/entities/slot/3-point-arc` | ↳ 3-point arc | not started | ForgeSketch | — | — |  |
| `7.1/entities/circle` | Entities: circle | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_circle | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/entities/circle/center` | ↳ center | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_circle |  |
| `7.1/entities/circle/perimeter` | ↳ perimeter | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_circle(through) |  |
| `7.1/entities/arc` | Entities: arc | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_arc | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/entities/arc/center` | ↳ center | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_arc |  |
| `7.1/entities/arc/tangent` | ↳ tangent | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_arc(tangent) | first-order endpoint tangency |
| `7.1/entities/arc/3-point` | ↳ 3-point | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_arc(three_point) |  |
| `7.1/entities/polygon` | Entities: polygon | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_polygon | inscribed/circumscribed; golden 104 |
| `7.1/entities/ellipse` | Entities: ellipse | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_ellipse | relations: on_entity, concentric; ellipse dimensions pending |
| `7.1/entities/partial-ellipse` | Entities: partial ellipse | not started | ForgeSketch | — | — |  |
| `7.1/entities/parabola` | Entities: parabola | not started | ForgeSketch | — | — |  |
| `7.1/entities/conic` | Entities: conic | not started | ForgeSketch | — | — |  |
| `7.1/entities/spline` | Entities: spline | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/GoldenModelTests/Models/020_spline_profile_extruded.json | execute:sketch.add_spline | clamped uniform B-spline (degree 1–5), same curve in sketch and solid; point-on-spline and end tangency supported; tangency away from the ends and spline trim/split/offset NOT IMPLEMENTED |
| `7.1/entities/spline/point-control-vertex` | ↳ point/control-vertex | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/GoldenModelTests/Models/020_spline_profile_extruded.json | execute:sketch.add_spline(through | poles) |
| `7.1/entities/spline/style-spline` | ↳ style spline | not started | ForgeSketch | — | — |  |
| `7.1/entities/spline/equation-driven-curve` | ↳ equation-driven curve | not started | ForgeSketch | — | — |  |
| `7.1/entities/spline/fit-spline` | ↳ fit spline | not started | ForgeSketch | — | — |  |
| `7.1/entities/point` | Entities: point | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_point | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/entities/text` | Entities: text | not started | ForgeSketch | — | — |  |
| `7.1/entities/text/with-fonts` | ↳ with fonts | not started | ForgeSketch | — | — |  |
| `7.1/entities/construction-geometry` | Entities: construction geometry | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.set_construction | excluded from profiles, drawn grey |
| `7.1/entities/fillet-chamfer` | Entities: fillet/chamfer | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, golden 106 | execute:sketch.fillet, execute:sketch.chamfer | fillet and chamfer (distance–distance, distance–angle) with virtual sharps |
| `7.1/entities/fillet-chamfer/sketch` | ↳ sketch | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift | execute:sketch.fillet | see parent |
| `7.1/tools/trim` | Tools: trim | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift, Tests/GoldenModelTests/Models/018_trimmed_circle_segment.json | execute:sketch.trim | lines, arcs, circles; ellipses NOT IMPLEMENTED; not yet a feature-tree item (M2) |
| `7.1/tools/trim/power` | ↳ power | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift, Tests/GoldenModelTests/Models/018_trimmed_circle_segment.json | execute:sketch.trim | one pick per call (no drag-across-curves gesture in the UI yet) |
| `7.1/tools/trim/corner` | ↳ corner | not started | ForgeSketch | — | — |  |
| `7.1/tools/trim/inside-outside` | ↳ inside/outside | not started | ForgeSketch | — | — |  |
| `7.1/tools/extend` | Tools: extend | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.extend | lines and arcs |
| `7.1/tools/offset` | Tools: offset | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift, Tests/GoldenModelTests/Models/019_offset_rectangle_frame.json | execute:sketch.offset | lines/arcs chains + circles, one driving dimension; ellipses NOT IMPLEMENTED; corners joined by extension only (no arc-join option); not yet a feature-tree item (M2) |
| `7.1/tools/offset/bi-directional` | ↳ bi-directional | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.offset(bidirectional) |  |
| `7.1/tools/offset/cap-ends` | ↳ cap ends | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.offset(cap_ends) | line caps only (arc caps NOT IMPLEMENTED) |
| `7.1/tools/offset/construction` | ↳ construction | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.offset(make_base_construction) |  |
| `7.1/tools/convert-entities` | Tools: convert entities | not started | ForgeSketch | — | — |  |
| `7.1/tools/intersection-curve` | Tools: intersection curve | not started | ForgeSketch | — | — |  |
| `7.1/tools/silhouette-entities` | Tools: silhouette entities | not started | ForgeSketch | — | — |  |
| `7.1/tools/mirror` | Tools: mirror | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift, Tests/GoldenModelTests/Models/017_mirrored_profile_extruded.json | execute:sketch.mirror | copies with symmetric relations (circles/arcs as wholes); ellipses copied unrelated; not yet a feature-tree item (M2) |
| `7.1/tools/mirror/static-dynamic` | ↳ static + dynamic | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.mirror | static mirror only; dynamic mirror (mirror while sketching) NOT IMPLEMENTED |
| `7.1/tools/linear-circular-sketch-patterns` | Tools: linear/circular sketch patterns | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.pattern_linear, execute:sketch.pattern_circular | instances tied to the seed by equal/parallel; spacing/angle not yet driven by dimensions |
| `7.1/tools/move-copy-rotate-scale-stretch` | Tools: move/copy/rotate/scale/stretch | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.move, execute:sketch.rotate, execute:sketch.scale | move/copy/rotate/scale done at sketch level; stretch NOT IMPLEMENTED |
| `7.1/tools/split-entities` | Tools: split entities | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.split | lines, arcs, circles; ellipses NOT IMPLEMENTED; not yet a feature-tree item (M2) |
| `7.1/tools/jog-line` | Tools: jog line | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-picture` | Tools: sketch picture | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-picture/with-scale-calibration` | ↳ with scale calibration | not started | ForgeSketch | — | — |  |
| `7.1/tools/autotrace` | Tools: Autotrace | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-blocks` | Tools: sketch blocks | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-blocks/create` | ↳ create | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-blocks/insert` | ↳ insert | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-blocks/edit` | ↳ edit | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-blocks/explode` | ↳ explode | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-blocks/belts-chains` | ↳ belts/chains | not started | ForgeSketch | — | — |  |
| `7.1/tools/derived-sketch` | Tools: derived sketch | not started | ForgeSketch | — | — |  |
| `7.1/tools/shared-sketches` | Tools: shared sketches | not started | ForgeSketch | — | — |  |
| `7.1/tools/3d-sketch` | Tools: 3D sketch | not started | ForgeSketch | — | — |  |
| `7.1/tools/3d-sketch/with-plane-switching` | ↳ with plane switching | not started | ForgeSketch | — | — |  |
| `7.1/tools/3d-sketch/3d-sketch-on-plane` | ↳ 3D sketch on plane | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-on-face-surface` | Tools: sketch on face/surface | not started | ForgeSketch | — | — |  |
| `7.1/tools/spline-tools` | Tools: spline tools | not started | ForgeSketch | — | — |  |
| `7.1/tools/spline-tools/tangency-curvature-handles` | ↳ tangency/curvature handles | not started | ForgeSketch | — | — |  |
| `7.1/tools/spline-tools/simplify` | ↳ simplify | not started | ForgeSketch | — | — |  |
| `7.1/tools/spline-tools/fit` | ↳ fit | not started | ForgeSketch | — | — |  |
| `7.1/tools/spline-tools/add-tangency-control` | ↳ add tangency control | not started | ForgeSketch | — | — |  |
| `7.1/tools/spline-tools/curvature-combs` | ↳ curvature combs | not started | ForgeSketch | — | — |  |
| `7.1/tools/instant2d` | Tools: Instant2D | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketchxpert` | Tools: SketchXpert | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | — | conflicts/redundancies rejected with executable fixes (delete / make driven); interactive repair UI pending |
| `7.1/tools/sketchxpert/conflict-repair` | ↳ conflict repair | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | — | see parent |
| `7.1/tools/check-sketch-for-feature` | Tools: Check Sketch for Feature | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | check_sketch | loops, nesting, open ends, branches, crossings; exact areas |
| `7.1/tools/repair-sketch` | Tools: Repair Sketch | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-contours-regions-selection` | Tools: sketch contours/regions selection | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | check_sketch | loop/region detection done; picking a region for a feature lands with extrude (M2) |
| `7.1/tools/sketch-ink-equivalent` | Tools: Sketch Ink equivalent | not started | ForgeSketch | — | — |  |
| `7.1/tools/sketch-ink-equivalent/pencil` | ↳ pencil | not started | ForgeSketch | — | — |  |
| `7.1/relations/coincident` | Relations: coincident | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/collinear` | Relations: collinear | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/coradial` | Relations: coradial | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/concentric` | Relations: concentric | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/horizontal` | Relations: horizontal | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/vertical` | Relations: vertical | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/parallel` | Relations: parallel | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/perpendicular` | Relations: perpendicular | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/tangent` | Relations: tangent | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | line–circle/arc and circle–circle, distance or endpoint form |
| `7.1/relations/equal` | Relations: equal | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | lines and radii |
| `7.1/relations/symmetric` | Relations: symmetric | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/midpoint` | Relations: midpoint | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/fix` | Relations: fix | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation | round-trips document.save/open (golden test); not yet a feature-tree item (M2) |
| `7.1/relations/merge` | Relations: merge | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation(coincident) | modelled as coincident points |
| `7.1/relations/pierce` | Relations: pierce | not started | ForgeSketch | — | — |  |
| `7.1/relations/intersection` | Relations: intersection | not started | ForgeSketch | — | — |  |
| `7.1/relations/along-x-y-z` | Relations: along X/Y/Z | not started | ForgeSketch | — | — |  |
| `7.1/relations/along-x-y-z/3d` | ↳ 3D | not started | ForgeSketch | — | — |  |
| `7.1/relations/equal-curvature` | Relations: equal curvature | not started | ForgeSketch | — | — |  |
| `7.1/relations/on-edge` | Relations: on-edge | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_relation(on_entity) | point on line/circle/arc/ellipse; projection of model edges pending |
| `7.1/relations/curve-length-equal` | Relations: curve length equal | not started | ForgeSketch | — | — |  |
| `7.1/relations/automatic-relations-with-inference` | Relations: automatic relations with inference | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | (infer parameter) | coincident + horizontal/vertical from exact coordinates; tolerance-based UI inference pending |
| `7.1/relations/display-delete-relations` | Relations: display/delete relations | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | get_sketch, execute:sketch.delete |  |
| `7.1/dimensions/smart-dimension` | Dimensions: smart dimension | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_dimension | explicit typed dimensions; UI smart-dimension picking pending |
| `7.1/dimensions/smart-dimension/linear` | ↳ linear | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_dimension | distance, horizontal, vertical |
| `7.1/dimensions/smart-dimension/angular` | ↳ angular | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_dimension | line–line |
| `7.1/dimensions/smart-dimension/radial` | ↳ radial | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_dimension |  |
| `7.1/dimensions/smart-dimension/diameter` | ↳ diameter | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_dimension |  |
| `7.1/dimensions/smart-dimension/arc-length` | ↳ arc length | not started | ForgeSketch | — | — |  |
| `7.1/dimensions/smart-dimension/path-length` | ↳ path length | not started | ForgeSketch | — | — |  |
| `7.1/dimensions/driven-reference` | Dimensions: driven/reference | in progress | ForgeSketch | Tests/ForgeSketchTests/SolverTests.swift, Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:sketch.add_dimension(driven) | measured values refresh after every solve |
| `7.1/dimensions/ordinate` | Dimensions: ordinate | not started | ForgeSketch | — | — |  |
| `7.1/dimensions/chain` | Dimensions: chain | not started | ForgeSketch | — | — |  |
| `7.1/dimensions/baseline` | Dimensions: baseline | not started | ForgeSketch | — | — |  |
| `7.1/dimensions/fully-define-sketch` | Dimensions: fully define sketch | not started | ForgeSketch | — | — |  |
| `7.1/dimensions/dimension-to-min-max-arc-condition` | Dimensions: dimension to min/max arc condition | not started | ForgeSketch | — | — |  |
| `7.1/dimensions/equations-in-dimension-fields` | Dimensions: equations in dimension fields | not started | ForgeSketch | — | — |  |

## 7.2 Part features

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.2/reference-geometry/planes` | Reference geometry: planes | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/planes/all-definitions` | ↳ all definitions | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/axes` | Reference geometry: axes | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/coordinate-systems` | Reference geometry: coordinate systems | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/points` | Reference geometry: points | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/center-of-mass` | Reference geometry: center of mass | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/mate-references` | Reference geometry: mate references | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/bounding-box` | Reference geometry: bounding box | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/reference-curves` | Reference geometry: reference curves | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/reference-curves/projected` | ↳ projected | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/reference-curves/helix-spiral` | ↳ helix/spiral | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/reference-curves/composite` | ↳ composite | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/reference-curves/split-line` | ↳ split line | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/reference-curves/curve-through-xyz-points` | ↳ curve through XYZ points | not started | ForgeModel | — | — |  |
| `7.2/reference-geometry/reference-curves/curve-through-reference-points` | ↳ curve through reference points | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/extrude` | Boss/base & cut: extrude | in progress | ForgeKernel / ForgeCommands | Tests/GoldenModelTests (013–016), Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:body.extrude | kernel-level from sketch profiles (holes, islands); parametric feature, cut and end conditions in M2 |
| `7.2/boss-base-and-cut/extrude/blind` | ↳ blind | in progress | ForgeCommands | Tests/GoldenModelTests (013–016), Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:body.extrude | normal/reverse |
| `7.2/boss-base-and-cut/extrude/through-all` | ↳ through all | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/extrude/up-to-next-vertex-surface-offset` | ↳ up to next/vertex/surface/offset | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/extrude/mid-plane` | ↳ mid-plane | in progress | ForgeCommands | Tests/GoldenModelTests (013–016), Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:body.extrude(mid_plane) |  |
| `7.2/boss-base-and-cut/extrude/thin-feature` | ↳ thin feature | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/extrude/draft` | ↳ draft | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/extrude/direction-2` | ↳ direction-2 | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/extrude/contour-selection` | ↳ contour selection | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/revolve` | Boss/base & cut: revolve | in progress | ForgeKernel / ForgeCommands | Tests/GoldenModelTests (013–016), Tests/ForgeCommandsTests/SketchCommandTests.swift | execute:body.revolve | about a sketch line, any angle; parametric feature in M2 |
| `7.2/boss-base-and-cut/sweep` | Boss/base & cut: sweep | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/sweep/profile` | ↳ profile | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/sweep/solid-body-tool-sweep` | ↳ solid-body tool sweep | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/sweep/twist` | ↳ twist | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/sweep/guide-curves` | ↳ guide curves | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/sweep/path-alignment` | ↳ path alignment | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/loft` | Boss/base & cut: loft | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/loft/guide-curves` | ↳ guide curves | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/loft/centerline` | ↳ centerline | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/loft/start-end-constraints` | ↳ start/end constraints | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/loft/tangency` | ↳ tangency | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/boundary-boss-cut` | Boss/base & cut: boundary boss/cut | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/thicken-thicken-cut` | Boss/base & cut: thicken/thicken cut | not started | ForgeModel | — | — |  |
| `7.2/boss-base-and-cut/cut-with-surface` | Boss/base & cut: cut with surface | not started | ForgeModel | — | — |  |
| `7.2/applied/fillet` | Applied: fillet | in progress | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift, Tests/GoldenModelTests/006 | execute:body.fillet_edges | constant radius on transient edge indices; no feature tree yet |
| `7.2/applied/fillet/constant` | ↳ constant | in progress | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift, Tests/GoldenModelTests/006 | execute:body.fillet_edges | kernel-level; parametric feature in M2 |
| `7.2/applied/fillet/variable` | ↳ variable | not started | ForgeModel | — | — |  |
| `7.2/applied/fillet/face` | ↳ face | not started | ForgeModel | — | — |  |
| `7.2/applied/fillet/full-round` | ↳ full-round | not started | ForgeModel | — | — |  |
| `7.2/applied/fillet/setback` | ↳ setback | not started | ForgeModel | — | — |  |
| `7.2/applied/fillet/filletxpert` | ↳ FilletXpert | not started | ForgeModel | — | — |  |
| `7.2/applied/fillet/conic-curvature-continuous-profiles` | ↳ conic/curvature-continuous profiles | not started | ForgeModel | — | — |  |
| `7.2/applied/chamfer` | Applied: chamfer | not started | ForgeModel | — | — |  |
| `7.2/applied/chamfer/angle-distance` | ↳ angle-distance | not started | ForgeModel | — | — |  |
| `7.2/applied/chamfer/distance-distance` | ↳ distance-distance | not started | ForgeModel | — | — |  |
| `7.2/applied/chamfer/vertex` | ↳ vertex | not started | ForgeModel | — | — |  |
| `7.2/applied/chamfer/offset-face` | ↳ offset face | not started | ForgeModel | — | — |  |
| `7.2/applied/chamfer/face-face` | ↳ face-face | not started | ForgeModel | — | — |  |
| `7.2/applied/draft` | Applied: draft | not started | ForgeModel | — | — |  |
| `7.2/applied/draft/neutral-plane` | ↳ neutral plane | not started | ForgeModel | — | — |  |
| `7.2/applied/draft/parting-line` | ↳ parting line | not started | ForgeModel | — | — |  |
| `7.2/applied/draft/step` | ↳ step | not started | ForgeModel | — | — |  |
| `7.2/applied/draft/draftxpert` | ↳ DraftXpert | not started | ForgeModel | — | — |  |
| `7.2/applied/shell` | Applied: shell | not started | ForgeModel | — | — |  |
| `7.2/applied/shell/multi-thickness` | ↳ multi-thickness | not started | ForgeModel | — | — |  |
| `7.2/applied/rib` | Applied: rib | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard` | Applied: hole wizard | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/counterbore` | ↳ counterbore | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/countersink` | ↳ countersink | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/straight` | ↳ straight | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/tapped` | ↳ tapped | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/pipe-tap` | ↳ pipe tap | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/legacy` | ↳ legacy | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/slot` | ↳ slot | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/counterbore-countersink-slot` | ↳ counterbore/countersink slot | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/ansi` | ↳ ANSI | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/iso` | ↳ ISO | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/din` | ↳ DIN | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/jis` | ↳ JIS | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/gb` | ↳ GB | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/bsi` | ↳ BSI | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/ks` | ↳ KS | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/as` | ↳ AS | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/is` | ↳ IS | not started | ForgeModel | — | — |  |
| `7.2/applied/hole-wizard/pem-etc` | ↳ PEM etc. | not started | ForgeModel | — | — |  |
| `7.2/applied/advanced-hole` | Applied: advanced hole | not started | ForgeModel | — | — |  |
| `7.2/applied/cosmetic-thread` | Applied: cosmetic thread | not started | ForgeModel | — | — |  |
| `7.2/applied/thread-feature` | Applied: thread feature | not started | ForgeModel | — | — |  |
| `7.2/applied/stud-wizard` | Applied: stud wizard | not started | ForgeModel | — | — |  |
| `7.2/applied/dome` | Applied: dome | not started | ForgeModel | — | — |  |
| `7.2/applied/wrap` | Applied: wrap | not started | ForgeModel | — | — |  |
| `7.2/applied/wrap/emboss` | ↳ emboss | not started | ForgeModel | — | — |  |
| `7.2/applied/wrap/deboss` | ↳ deboss | not started | ForgeModel | — | — |  |
| `7.2/applied/wrap/scribe` | ↳ scribe | not started | ForgeModel | — | — |  |
| `7.2/applied/indent` | Applied: indent | not started | ForgeModel | — | — |  |
| `7.2/applied/flex` | Applied: flex | not started | ForgeModel | — | — |  |
| `7.2/applied/flex/bend` | ↳ bend | not started | ForgeModel | — | — |  |
| `7.2/applied/flex/twist` | ↳ twist | not started | ForgeModel | — | — |  |
| `7.2/applied/flex/taper` | ↳ taper | not started | ForgeModel | — | — |  |
| `7.2/applied/flex/stretch` | ↳ stretch | not started | ForgeModel | — | — |  |
| `7.2/applied/deform` | Applied: deform | not started | ForgeModel | — | — |  |
| `7.2/applied/intersect` | Applied: intersect | not started | ForgeModel | — | — |  |
| `7.2/applied/freeform` | Applied: freeform | not started | ForgeModel | — | — |  |
| `7.2/applied/lip-groove` | Applied: lip/groove | not started | ForgeModel | — | — |  |
| `7.2/applied/mounting-boss` | Applied: mounting boss | not started | ForgeModel | — | — |  |
| `7.2/applied/snap-hook-groove` | Applied: snap hook/groove | not started | ForgeModel | — | — |  |
| `7.2/applied/vent` | Applied: vent | not started | ForgeModel | — | — |  |
| `7.2/applied/fastening-features` | Applied: fastening features | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/linear` | Patterns & mirror: linear | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/circular` | Patterns & mirror: circular | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/curve-driven` | Patterns & mirror: curve-driven | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/sketch-driven` | Patterns & mirror: sketch-driven | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/table-driven` | Patterns & mirror: table-driven | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/fill-pattern` | Patterns & mirror: fill pattern | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/variable-pattern` | Patterns & mirror: variable pattern | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/chain-pattern` | Patterns & mirror: chain pattern | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/mirror` | Patterns & mirror: mirror | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/mirror/features` | ↳ features | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/mirror/faces` | ↳ faces | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/mirror/bodies` | ↳ bodies | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/geometry-pattern` | Patterns & mirror: geometry pattern | not started | ForgeModel | — | — |  |
| `7.2/patterns-and-mirror/instance-skipping-varying` | Patterns & mirror: instance skipping/varying | not started | ForgeModel | — | — |  |
| `7.2/multibody/combine` | Multibody: combine | in progress | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift, Tests/GoldenModelTests | execute:body.boolean | kernel-level; Combine feature in M2/M3 |
| `7.2/multibody/combine/add-subtract-common` | ↳ add/subtract/common | in progress | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift, Tests/GoldenModelTests | execute:body.boolean |  |
| `7.2/multibody/split` | Multibody: split | not started | ForgeModel | — | — |  |
| `7.2/multibody/move-copy-body` | Multibody: move/copy body | in progress | ForgeCommands | Tests/ForgeCommandsTests/EngineTests.swift, Tests/GoldenModelTests/005 | execute:body.transform |  |
| `7.2/multibody/delete-keep-body` | Multibody: delete/keep body | in progress | ForgeCommands | Tests/ForgeCommandsTests/EngineTests.swift | execute:body.delete | delete only |
| `7.2/multibody/insert-part` | Multibody: insert part | not started | ForgeModel | — | — |  |
| `7.2/multibody/insert-into-new-part` | Multibody: insert into new part | not started | ForgeModel | — | — |  |
| `7.2/multibody/save-bodies` | Multibody: save bodies | not started | ForgeModel | — | — |  |
| `7.2/multibody/body-folders` | Multibody: body folders | not started | ForgeModel | — | — |  |
| `7.2/multibody/cut-list` | Multibody: cut list | not started | ForgeModel | — | — |  |
| `7.2/direct-editing/move-rotate-offset-replace-delete-face` | Direct editing: move/rotate/offset/replace/delete face | not started | ForgeModel | — | — |  |
| `7.2/direct-editing/delete-hole` | Direct editing: delete hole | not started | ForgeModel | — | — |  |
| `7.2/direct-editing/simplify-defeature` | Direct editing: simplify/defeature | not started | ForgeModel | — | — |  |
| `7.2/direct-editing/instant3d` | Direct editing: Instant3D | not started | ForgeModel | — | — |  |
| `7.2/direct-editing/import-diagnostics-and-healing` | Direct editing: import diagnostics & healing | not started | ForgeModel | — | — |  |
| `7.2/direct-editing/featureworks` | Direct editing: FeatureWorks | not started | ForgeModel | — | — |  |
| `7.2/direct-editing/featureworks/feature-recognition-on-imported-bodies` | ↳ feature recognition on imported bodies | not started | ForgeModel | — | — |  |
| `7.2/scale` | Scale | not started | ForgeModel | — | — |  |
| `7.2/fillet-aware-undo` | fillet-aware undo | not started | ForgeModel | — | — |  |
| `7.2/library-features` | library features | not started | ForgeModel | — | — |  |
| `7.2/design-library` | design library | not started | ForgeModel | — | — |  |
| `7.2/smart-features` | smart features | not started | ForgeModel | — | — |  |
| `7.2/forming-tools` | forming tools | not started | ForgeModel | — | — |  |
| `7.2/cosmetic-patterns` | cosmetic patterns | not started | ForgeModel | — | — |  |
| `7.2/decals` | decals | not started | ForgeModel | — | — |  |
| `7.2/appearances` | appearances | not started | ForgeModel | — | — |  |
| `7.2/materials-database` | materials database | not started | ForgeModel | — | — |  |
| `7.2/materials-database/with-custom-materials` | ↳ with custom materials | not started | ForgeModel | — | — |  |
| `7.2/sensors` | sensors | not started | ForgeModel | — | — |  |
| `7.2/feature-freeze` | feature freeze | not started | ForgeModel | — | — |  |
| `7.2/feature-statistics` | feature statistics | not started | ForgeModel | — | — |  |
| `7.2/performance-evaluation` | performance evaluation | not started | ForgeModel | — | — |  |
| `7.2/mesh-brep/import-mesh` | Mesh/BREP: import mesh | not started | ForgeModel | — | — |  |
| `7.2/mesh-brep/import-mesh/stl-obj-3mf` | ↳ STL/OBJ/3MF | not started | ForgeModel | — | — |  |
| `7.2/mesh-brep/mesh-bodies` | Mesh/BREP: mesh bodies | not started | ForgeModel | — | — |  |
| `7.2/mesh-brep/convert-mesh-to-body` | Mesh/BREP: convert mesh to body | not started | ForgeModel | — | — |  |
| `7.2/mesh-brep/graphics-bodies` | Mesh/BREP: graphics bodies | not started | ForgeModel | — | — |  |
| `7.2/mesh-brep/segment-mesh` | Mesh/BREP: segment mesh | not started | ForgeModel | — | — |  |
| `7.2/mesh-brep/3d-texture` | Mesh/BREP: 3D Texture | not started | ForgeModel | — | — |  |

## 7.3 Surfacing

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.3/extruded` | Extruded | not started | ForgeModel | — | — |  |
| `7.3/revolved` | revolved | not started | ForgeModel | — | — |  |
| `7.3/swept` | swept | not started | ForgeModel | — | — |  |
| `7.3/lofted` | lofted | not started | ForgeModel | — | — |  |
| `7.3/boundary` | boundary | not started | ForgeModel | — | — |  |
| `7.3/planar` | planar | not started | ForgeModel | — | — |  |
| `7.3/fill` | fill | not started | ForgeModel | — | — |  |
| `7.3/fill/with-constraints-curvature` | ↳ with constraints/curvature | not started | ForgeModel | — | — |  |
| `7.3/freeform` | freeform | not started | ForgeModel | — | — |  |
| `7.3/offset` | offset | not started | ForgeModel | — | — |  |
| `7.3/ruled` | ruled | not started | ForgeModel | — | — |  |
| `7.3/radiated` | radiated | not started | ForgeModel | — | — |  |
| `7.3/knit` | knit | not started | ForgeModel | — | — |  |
| `7.3/knit/with-gap-control` | ↳ with gap control | not started | ForgeModel | — | — |  |
| `7.3/untrim` | untrim | not started | ForgeModel | — | — |  |
| `7.3/extend` | extend | not started | ForgeModel | — | — |  |
| `7.3/trim` | trim | not started | ForgeModel | — | — |  |
| `7.3/trim/standard-mutual` | ↳ standard/mutual | not started | ForgeModel | — | — |  |
| `7.3/delete-face-hole` | delete face/hole | not started | ForgeModel | — | — |  |
| `7.3/replace-face` | replace face | not started | ForgeModel | — | — |  |
| `7.3/thicken` | thicken | not started | ForgeModel | — | — |  |
| `7.3/surface-flatten` | surface flatten | not started | ForgeModel | — | — |  |
| `7.3/mid-surface` | mid-surface | not started | ForgeModel | — | — |  |
| `7.3/face-curves` | face curves | not started | ForgeModel | — | — |  |
| `7.3/parting-surface` | parting surface | not started | ForgeModel | — | — |  |
| `7.3/shut-off-surface` | shut-off surface | not started | ForgeModel | — | — |  |
| `7.3/sew-heal` | sew/heal | not started | ForgeModel | — | — |  |
| `7.3/curvature-continuity-checks` | curvature continuity checks | not started | ForgeModel | — | — |  |

## 7.4 Sheet metal

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.4/base-flange-tab` | Base flange/tab | not started | ForgeModel | — | — |  |
| `7.4/edge-flange` | edge flange | not started | ForgeModel | — | — |  |
| `7.4/edge-flange/all-positions` | ↳ all positions | not started | ForgeModel | — | — |  |
| `7.4/edge-flange/custom-profile` | ↳ custom profile | not started | ForgeModel | — | — |  |
| `7.4/miter-flange` | miter flange | not started | ForgeModel | — | — |  |
| `7.4/hem` | hem | not started | ForgeModel | — | — |  |
| `7.4/hem/all-types` | ↳ all types | not started | ForgeModel | — | — |  |
| `7.4/jog` | jog | not started | ForgeModel | — | — |  |
| `7.4/sketched-bend` | sketched bend | not started | ForgeModel | — | — |  |
| `7.4/cross-break` | cross break | not started | ForgeModel | — | — |  |
| `7.4/closed-corner` | closed corner | not started | ForgeModel | — | — |  |
| `7.4/welded-corner` | welded corner | not started | ForgeModel | — | — |  |
| `7.4/break-relief-corner` | break/relief corner | not started | ForgeModel | — | — |  |
| `7.4/break-relief-corner/all-relief-types` | ↳ all relief types | not started | ForgeModel | — | — |  |
| `7.4/corner-trim` | corner trim | not started | ForgeModel | — | — |  |
| `7.4/forming-tools` | forming tools | not started | ForgeModel | — | — |  |
| `7.4/forming-tools/and-custom-forming-tools` | ↳ and custom forming tools | not started | ForgeModel | — | — |  |
| `7.4/vent` | vent | not started | ForgeModel | — | — |  |
| `7.4/lofted-bend` | lofted bend | not started | ForgeModel | — | — |  |
| `7.4/lofted-bend/formed-and-bent` | ↳ formed and bent | not started | ForgeModel | — | — |  |
| `7.4/swept-flange` | swept flange | not started | ForgeModel | — | — |  |
| `7.4/convert-to-sheet-metal` | convert to sheet metal | not started | ForgeModel | — | — |  |
| `7.4/insert-bends-rip` | insert bends/rip | not started | ForgeModel | — | — |  |
| `7.4/flatten-unfold-fold` | flatten/unfold/fold | not started | ForgeModel | — | — |  |
| `7.4/flat-pattern` | flat pattern | not started | ForgeModel | — | — |  |
| `7.4/flat-pattern/with-bend-lines` | ↳ with bend lines | not started | ForgeModel | — | — |  |
| `7.4/flat-pattern/bend-notes` | ↳ bend notes | not started | ForgeModel | — | — |  |
| `7.4/flat-pattern/grain-direction` | ↳ grain direction | not started | ForgeModel | — | — |  |
| `7.4/flat-pattern/flat-pattern-export-to-dxf-dwg` | ↳ flat-pattern export to DXF/DWG | not started | ForgeModel | — | — |  |
| `7.4/gauge-tables` | gauge tables | not started | ForgeModel | — | — |  |
| `7.4/bend-tables` | bend tables | not started | ForgeModel | — | — |  |
| `7.4/k-factor-bend-allowance-bend-deduction` | K-factor/bend allowance/bend deduction | not started | ForgeModel | — | — |  |
| `7.4/tab-and-slot` | tab & slot | not started | ForgeModel | — | — |  |
| `7.4/normal-cut` | normal cut | not started | ForgeModel | — | — |  |
| `7.4/multibody-sheet-metal` | multibody sheet metal | not started | ForgeModel | — | — |  |
| `7.4/sheet-metal-cut-list-properties` | sheet metal cut list properties | not started | ForgeModel | — | — |  |

## 7.5 Weldments

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.5/structural-member` | Structural member | not started | ForgeModel | — | — |  |
| `7.5/structural-member/ansi-iso` | ↳ ANSI/ISO | not started | ForgeModel | — | — |  |
| `7.5/structural-member/custom-profiles` | ↳ custom profiles | not started | ForgeModel | — | — |  |
| `7.5/structural-member/corner-treatments` | ↳ corner treatments | not started | ForgeModel | — | — |  |
| `7.5/structural-member/trim-extend` | ↳ trim/extend | not started | ForgeModel | — | — |  |
| `7.5/structural-member/groups` | ↳ groups | not started | ForgeModel | — | — |  |
| `7.5/end-caps` | end caps | not started | ForgeModel | — | — |  |
| `7.5/gussets` | gussets | not started | ForgeModel | — | — |  |
| `7.5/fillet-beads` | fillet beads | not started | ForgeModel | — | — |  |
| `7.5/weld-beads` | weld beads | not started | ForgeModel | — | — |  |
| `7.5/cut-lists-with-properties` | cut lists with properties | not started | ForgeModel | — | — |  |
| `7.5/weldment-drawings-cut-list-tables` | weldment drawings/cut list tables | not started | ForgeModel | — | — |  |
| `7.5/3d-sketch-driven-frames` | 3D-sketch-driven frames | not started | ForgeModel | — | — |  |

## 7.6 Mold / tooling

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.6/draft-analysis` | Draft analysis | not started | ForgeModel | — | — |  |
| `7.6/undercut-analysis` | undercut analysis | not started | ForgeModel | — | — |  |
| `7.6/parting-lines` | parting lines | not started | ForgeModel | — | — |  |
| `7.6/shut-off-surfaces` | shut-off surfaces | not started | ForgeModel | — | — |  |
| `7.6/parting-surfaces` | parting surfaces | not started | ForgeModel | — | — |  |
| `7.6/tooling-split` | tooling split | not started | ForgeModel | — | — |  |
| `7.6/core-cavity` | core/cavity | not started | ForgeModel | — | — |  |
| `7.6/core-pins` | core pins | not started | ForgeModel | — | — |  |
| `7.6/scale-for-shrinkage` | scale for shrinkage | not started | ForgeModel | — | — |  |
| `7.6/ruled-surface-for-molds` | ruled surface for molds | not started | ForgeModel | — | — |  |
| `7.6/mold-base-integration` | mold base integration | not started | ForgeModel | — | — |  |

## 7.7 Assemblies

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.7/top-down-and-bottom-up-design` | Top-down and bottom-up design | not started | ForgeAssembly | — | — |  |
| `7.7/insert-components` | insert components | not started | ForgeAssembly | — | — |  |
| `7.7/virtual-components` | virtual components | not started | ForgeAssembly | — | — |  |
| `7.7/subassemblies` | subassemblies | not started | ForgeAssembly | — | — |  |
| `7.7/subassemblies/rigid-flexible` | ↳ rigid/flexible | not started | ForgeAssembly | — | — |  |
| `7.7/component-patterns` | component patterns | not started | ForgeAssembly | — | — |  |
| `7.7/component-patterns/linear` | ↳ linear | not started | ForgeAssembly | — | — |  |
| `7.7/component-patterns/circular` | ↳ circular | not started | ForgeAssembly | — | — |  |
| `7.7/component-patterns/pattern-driven` | ↳ pattern-driven | not started | ForgeAssembly | — | — |  |
| `7.7/component-patterns/sketch-driven` | ↳ sketch-driven | not started | ForgeAssembly | — | — |  |
| `7.7/component-patterns/curve-driven` | ↳ curve-driven | not started | ForgeAssembly | — | — |  |
| `7.7/component-patterns/chain` | ↳ chain | not started | ForgeAssembly | — | — |  |
| `7.7/mirror-components` | mirror components | not started | ForgeAssembly | — | — |  |
| `7.7/mirror-components/opposite-hand` | ↳ opposite-hand | not started | ForgeAssembly | — | — |  |
| `7.7/smart-components` | smart components | not started | ForgeAssembly | — | — |  |
| `7.7/smart-fasteners` | smart fasteners | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox` | Toolbox | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/bolts` | ↳ bolts | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/screws` | ↳ screws | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/nuts` | ↳ nuts | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/washers` | ↳ washers | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/pins` | ↳ pins | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/bearings` | ↳ bearings | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/gears` | ↳ gears | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/cams` | ↳ cams | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/pulleys` | ↳ pulleys | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/sprockets` | ↳ sprockets | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/structural-steel` | ↳ structural steel | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/o-rings` | ↳ O-rings | not started | ForgeAssembly | — | — |  |
| `7.7/toolbox/keyways` | ↳ keyways | not started | ForgeAssembly | — | — |  |
| `7.7/mates/standard` | Mates: standard | not started | ForgeAssembly | — | — |  |
| `7.7/mates/standard/coincident` | ↳ coincident | not started | ForgeAssembly | — | — |  |
| `7.7/mates/standard/parallel` | ↳ parallel | not started | ForgeAssembly | — | — |  |
| `7.7/mates/standard/perpendicular` | ↳ perpendicular | not started | ForgeAssembly | — | — |  |
| `7.7/mates/standard/tangent` | ↳ tangent | not started | ForgeAssembly | — | — |  |
| `7.7/mates/standard/concentric` | ↳ concentric | not started | ForgeAssembly | — | — |  |
| `7.7/mates/standard/lock` | ↳ lock | not started | ForgeAssembly | — | — |  |
| `7.7/mates/standard/distance` | ↳ distance | not started | ForgeAssembly | — | — |  |
| `7.7/mates/standard/angle` | ↳ angle | not started | ForgeAssembly | — | — |  |
| `7.7/mates/advanced` | Mates: advanced | not started | ForgeAssembly | — | — |  |
| `7.7/mates/advanced/profile-center` | ↳ profile center | not started | ForgeAssembly | — | — |  |
| `7.7/mates/advanced/symmetric` | ↳ symmetric | not started | ForgeAssembly | — | — |  |
| `7.7/mates/advanced/width` | ↳ width | not started | ForgeAssembly | — | — |  |
| `7.7/mates/advanced/path` | ↳ path | not started | ForgeAssembly | — | — |  |
| `7.7/mates/advanced/linear-linear-coupler` | ↳ linear/linear coupler | not started | ForgeAssembly | — | — |  |
| `7.7/mates/advanced/limit-distance-angle` | ↳ limit distance/angle | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mechanical` | Mates: mechanical | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mechanical/cam` | ↳ cam | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mechanical/slot` | ↳ slot | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mechanical/hinge` | ↳ hinge | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mechanical/gear` | ↳ gear | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mechanical/rack-and-pinion` | ↳ rack & pinion | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mechanical/screw` | ↳ screw | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mechanical/universal-joint` | ↳ universal joint | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mate-references` | Mates: mate references | not started | ForgeAssembly | — | — |  |
| `7.7/mates/smartmates` | Mates: SmartMates | not started | ForgeAssembly | — | — |  |
| `7.7/mates/quick-mates` | Mates: Quick Mates | not started | ForgeAssembly | — | — |  |
| `7.7/mates/matexpert-mate-diagnostics` | Mates: MateXpert/mate diagnostics | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mate-folders` | Mates: mate folders | not started | ForgeAssembly | — | — |  |
| `7.7/mates/mate-controller` | Mates: mate controller | not started | ForgeAssembly | — | — |  |
| `7.7/mates/copy-with-mates` | Mates: copy with mates | not started | ForgeAssembly | — | — |  |
| `7.7/tools/move-rotate-component` | Tools: move/rotate component | not started | ForgeAssembly | — | — |  |
| `7.7/tools/move-rotate-component/with-collision-detection` | ↳ with collision detection | not started | ForgeAssembly | — | — |  |
| `7.7/tools/move-rotate-component/dynamic-clearance` | ↳ dynamic clearance | not started | ForgeAssembly | — | — |  |
| `7.7/tools/move-rotate-component/physical-dynamics` | ↳ physical dynamics | not started | ForgeAssembly | — | — |  |
| `7.7/tools/interference-detection` | Tools: interference detection | not started | ForgeAssembly | — | — |  |
| `7.7/tools/clearance-verification` | Tools: clearance verification | not started | ForgeAssembly | — | — |  |
| `7.7/tools/hole-alignment` | Tools: hole alignment | not started | ForgeAssembly | — | — |  |
| `7.7/tools/assembly-visualization` | Tools: assembly visualization | not started | ForgeAssembly | — | — |  |
| `7.7/tools/assemblyxpert` | Tools: AssemblyXpert | not started | ForgeAssembly | — | — |  |
| `7.7/tools/exploded-views` | Tools: exploded views | not started | ForgeAssembly | — | — |  |
| `7.7/tools/exploded-views/with-explode-lines` | ↳ with explode lines | not started | ForgeAssembly | — | — |  |
| `7.7/tools/exploded-views/radial-regular-steps` | ↳ radial/regular steps | not started | ForgeAssembly | — | — |  |
| `7.7/tools/exploded-views/animation` | ↳ animation | not started | ForgeAssembly | — | — |  |
| `7.7/tools/section-views` | Tools: section views | not started | ForgeAssembly | — | — |  |
| `7.7/tools/configurations` | Tools: configurations | not started | ForgeAssembly | — | — |  |
| `7.7/tools/display-states` | Tools: display states | not started | ForgeAssembly | — | — |  |
| `7.7/tools/large-assembly-mode` | Tools: Large Assembly Mode | not started | ForgeAssembly | — | — |  |
| `7.7/tools/large-design-review` | Tools: Large Design Review | not started | ForgeAssembly | — | — |  |
| `7.7/tools/lightweight-components` | Tools: lightweight components | not started | ForgeAssembly | — | — |  |
| `7.7/tools/speedpak` | Tools: SpeedPak | not started | ForgeAssembly | — | — |  |
| `7.7/tools/defeature` | Tools: defeature | not started | ForgeAssembly | — | — |  |
| `7.7/tools/envelopes` | Tools: envelopes | not started | ForgeAssembly | — | — |  |
| `7.7/tools/treehouse` | Tools: Treehouse | not started | ForgeAssembly | — | — |  |
| `7.7/tools/treehouse/structure-planning` | ↳ structure planning | not started | ForgeAssembly | — | — |  |
| `7.7/tools/assembly-features` | Tools: assembly features | not started | ForgeAssembly | — | — |  |
| `7.7/tools/assembly-features/cuts` | ↳ cuts | not started | ForgeAssembly | — | — |  |
| `7.7/tools/assembly-features/holes` | ↳ holes | not started | ForgeAssembly | — | — |  |
| `7.7/tools/assembly-features/weld-beads` | ↳ weld beads | not started | ForgeAssembly | — | — |  |
| `7.7/tools/in-context-references` | Tools: in-context references | not started | ForgeAssembly | — | — |  |
| `7.7/tools/in-context-references/external-reference-management` | ↳ external reference management | not started | ForgeAssembly | — | — |  |
| `7.7/tools/in-context-references/lock-break` | ↳ lock/break | not started | ForgeAssembly | — | — |  |
| `7.7/tools/replace-components` | Tools: replace components | not started | ForgeAssembly | — | — |  |
| `7.7/tools/pack-and-go` | Tools: Pack and Go | not started | ForgeAssembly | — | — |  |
| `7.7/tools/magnetic-mates-asset-publisher` | Tools: magnetic mates / Asset Publisher | not started | ForgeAssembly | — | — |  |
| `7.7/tools/belts-chains` | Tools: belts/chains | not started | ForgeAssembly | — | — |  |
| `7.7/tools/structure-system` | Tools: structure system | not started | ForgeAssembly | — | — |  |
| `7.7/tools/assembly-layout-sketches` | Tools: assembly layout sketches | not started | ForgeAssembly | — | — |  |
| `7.7/tools/bom-in-assembly` | Tools: BOM in assembly | not started | ForgeAssembly | — | — |  |
| `7.7/tools/isolate` | Tools: Isolate | not started | ForgeAssembly | — | — |  |
| `7.7/tools/component-preview` | Tools: component preview | not started | ForgeAssembly | — | — |  |
| `7.7/tools/envelope-publisher` | Tools: envelope publisher | not started | ForgeAssembly | — | — |  |

## 7.8 Motion

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.8/animation` | Animation | not started | ForgeSim | — | — |  |
| `7.8/animation/keyframe-timeline` | ↳ keyframe timeline | not started | ForgeSim | — | — |  |
| `7.8/animation/camera-animation` | ↳ camera animation | not started | ForgeSim | — | — |  |
| `7.8/animation/walk-through` | ↳ walk-through | not started | ForgeSim | — | — |  |
| `7.8/basic-motion` | Basic Motion | not started | ForgeSim | — | — |  |
| `7.8/basic-motion/motors` | ↳ motors | not started | ForgeSim | — | — |  |
| `7.8/basic-motion/springs` | ↳ springs | not started | ForgeSim | — | — |  |
| `7.8/basic-motion/contact` | ↳ contact | not started | ForgeSim | — | — |  |
| `7.8/basic-motion/gravity` | ↳ gravity | not started | ForgeSim | — | — |  |
| `7.8/motion-analysis` | Motion Analysis | not started | ForgeSim | — | — |  |
| `7.8/motion-analysis/forces` | ↳ forces | not started | ForgeSim | — | — |  |
| `7.8/motion-analysis/dampers` | ↳ dampers | not started | ForgeSim | — | — |  |
| `7.8/motion-analysis/bushings` | ↳ bushings | not started | ForgeSim | — | — |  |
| `7.8/motion-analysis/3d-contact` | ↳ 3D contact | not started | ForgeSim | — | — |  |
| `7.8/motion-analysis/friction` | ↳ friction | not started | ForgeSim | — | — |  |
| `7.8/motion-analysis/results-and-plots` | ↳ results & plots | not started | ForgeSim | — | — |  |
| `7.8/motion-analysis/export-loads-to-fea` | ↳ export loads to FEA | not started | ForgeSim | — | — |  |
| `7.8/motion-optimization` | Motion optimization | not started | ForgeSim | — | — |  |
| `7.8/event-based-motion` | event-based motion | not started | ForgeSim | — | — |  |
| `7.8/interference-during-motion` | interference during motion | not started | ForgeSim | — | — |  |
| `7.8/trace-paths` | trace paths | not started | ForgeSim | — | — |  |

## 7.9 Drawings

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.9/sheets-and-formats` | Sheets and formats | not started | ForgeDrawing | — | — |  |
| `7.9/sheets-and-formats/all-ansi-iso-din-jis-gb-templates` | ↳ all ANSI/ISO/DIN/JIS/GB templates | not started | ForgeDrawing | — | — |  |
| `7.9/sheets-and-formats/editable-title-blocks-with-property-links` | ↳ editable title blocks with property links | not started | ForgeDrawing | — | — |  |
| `7.9/sheets-and-formats/multiple-sheets` | ↳ multiple sheets | not started | ForgeDrawing | — | — |  |
| `7.9/sheets-and-formats/sheet-scaling` | ↳ sheet scaling | not started | ForgeDrawing | — | — |  |
| `7.9/drafting-standards-editor` | drafting standards editor | not started | ForgeDrawing | — | — |  |
| `7.9/views/standard-3-view` | Views: standard 3-view | not started | ForgeDrawing | — | — |  |
| `7.9/views/model-view` | Views: model view | not started | ForgeDrawing | — | — |  |
| `7.9/views/projected` | Views: projected | not started | ForgeDrawing | — | — |  |
| `7.9/views/auxiliary` | Views: auxiliary | not started | ForgeDrawing | — | — |  |
| `7.9/views/section` | Views: section | not started | ForgeDrawing | — | — |  |
| `7.9/views/section/with-section-view-assist` | ↳ with section view assist | not started | ForgeDrawing | — | — |  |
| `7.9/views/section/aligned` | ↳ aligned | not started | ForgeDrawing | — | — |  |
| `7.9/views/section/half` | ↳ half | not started | ForgeDrawing | — | — |  |
| `7.9/views/section/offset` | ↳ offset | not started | ForgeDrawing | — | — |  |
| `7.9/views/section/partial` | ↳ partial | not started | ForgeDrawing | — | — |  |
| `7.9/views/detail` | Views: detail | not started | ForgeDrawing | — | — |  |
| `7.9/views/detail/circular-profile` | ↳ circular/profile | not started | ForgeDrawing | — | — |  |
| `7.9/views/broken-out-section` | Views: broken-out section | not started | ForgeDrawing | — | — |  |
| `7.9/views/break` | Views: break | not started | ForgeDrawing | — | — |  |
| `7.9/views/crop` | Views: crop | not started | ForgeDrawing | — | — |  |
| `7.9/views/alternate-position` | Views: alternate position | not started | ForgeDrawing | — | — |  |
| `7.9/views/relative-to-model` | Views: relative-to-model | not started | ForgeDrawing | — | — |  |
| `7.9/views/3d-drawing-view` | Views: 3D drawing view | not started | ForgeDrawing | — | — |  |
| `7.9/views/flat-pattern-views` | Views: flat pattern views | not started | ForgeDrawing | — | — |  |
| `7.9/views/exploded-views` | Views: exploded views | not started | ForgeDrawing | — | — |  |
| `7.9/views/empty-views` | Views: empty views | not started | ForgeDrawing | — | — |  |
| `7.9/views/view-palette` | Views: view palette | not started | ForgeDrawing | — | — |  |
| `7.9/views/rotate-views` | Views: rotate views | not started | ForgeDrawing | — | — |  |
| `7.9/views/hlr-hlv` | Views: HLR/HLV | not started | ForgeDrawing | — | — |  |
| `7.9/views/tangent-edge-options` | Views: tangent edge options | not started | ForgeDrawing | — | — |  |
| `7.9/views/shaded-wireframe` | Views: shaded/wireframe | not started | ForgeDrawing | — | — |  |
| `7.9/views/isometric` | Views: isometric | not started | ForgeDrawing | — | — |  |
| `7.9/views/live-section` | Views: live section | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/model-items-import` | Annotations: model items import | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/smart-dimension` | Annotations: smart dimension | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/smart-dimension/all-types-incl-ordinate` | ↳ all types incl. ordinate | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/smart-dimension/chamfer` | ↳ chamfer | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/smart-dimension/baseline` | ↳ baseline | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/smart-dimension/chain` | ↳ chain | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/smart-dimension/angular-running` | ↳ angular running | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/dimxpert-for-drawings` | Annotations: DimXpert for drawings | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/notes` | Annotations: notes | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/notes/linked-properties` | ↳ linked properties | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/notes/hyperlinks` | ↳ hyperlinks | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/notes/balloons-in-notes` | ↳ balloons in notes | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/balloons` | Annotations: balloons | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/balloons/auto-balloon` | ↳ auto-balloon | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/balloons/stacked` | ↳ stacked | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/surface-finish` | Annotations: surface finish | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/weld-symbols` | Annotations: weld symbols | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/weld-symbols/ansi-iso` | ↳ ANSI/ISO | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/gdandt` | Annotations: GD&T | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/gdandt/feature-control-frames` | ↳ feature control frames | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/gdandt/datums` | ↳ datums | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/gdandt/datum-targets` | ↳ datum targets | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/gdandt/composite-frames` | ↳ composite frames | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/center-marks` | Annotations: center marks | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/centerlines` | Annotations: centerlines | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/cosmetic-threads` | Annotations: cosmetic threads | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/hole-callouts` | Annotations: hole callouts | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/revision-clouds` | Annotations: revision clouds | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/area-hatch-fill` | Annotations: area hatch/fill | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/blocks` | Annotations: blocks | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/magnetic-lines` | Annotations: magnetic lines | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/layers` | Annotations: layers | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/dimension-tolerance-display` | Annotations: dimension tolerance display | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/dimension-tolerance-display/all-types` | ↳ all types | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/dimension-tolerance-display/fits` | ↳ fits | not started | ForgeDrawing | — | — |  |
| `7.9/annotations/dimension-tolerance-display/tables` | ↳ tables | not started | ForgeDrawing | — | — |  |
| `7.9/tables/bom` | Tables: BOM | not started | ForgeDrawing | — | — |  |
| `7.9/tables/bom/top-level` | ↳ top-level | not started | ForgeDrawing | — | — |  |
| `7.9/tables/bom/parts-only` | ↳ parts-only | not started | ForgeDrawing | — | — |  |
| `7.9/tables/bom/indented` | ↳ indented | not started | ForgeDrawing | — | — |  |
| `7.9/tables/bom/weldment-cut-list` | ↳ weldment cut list | not started | ForgeDrawing | — | — |  |
| `7.9/tables/bom/with-custom-columns-and-equations` | ↳ with custom columns & equations | not started | ForgeDrawing | — | — |  |
| `7.9/tables/hole-table` | Tables: hole table | not started | ForgeDrawing | — | — |  |
| `7.9/tables/revision-table` | Tables: revision table | not started | ForgeDrawing | — | — |  |
| `7.9/tables/general-table` | Tables: general table | not started | ForgeDrawing | — | — |  |
| `7.9/tables/bend-table` | Tables: bend table | not started | ForgeDrawing | — | — |  |
| `7.9/tables/punch-table` | Tables: punch table | not started | ForgeDrawing | — | — |  |
| `7.9/tables/weld-table` | Tables: weld table | not started | ForgeDrawing | — | — |  |
| `7.9/tables/design-table` | Tables: design table | not started | ForgeDrawing | — | — |  |
| `7.9/tables/title-block-table` | Tables: title block table | not started | ForgeDrawing | — | — |  |
| `7.9/tables/general-table-templates` | Tables: general table templates | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/auto-arrange-dimensions` | Drawing tools: Auto-arrange dimensions | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/dimension-palette` | Drawing tools: dimension palette | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/format-painter` | Drawing tools: format painter | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/sketch-in-drawing` | Drawing tools: sketch in drawing | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/design-checker` | Drawing tools: Design Checker | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/drawing-compare` | Drawing tools: drawing compare | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/detailing-mode` | Drawing tools: detailing mode | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/dwg-dxf-editing-parity-basics` | Drawing tools: DWG/DXF editing parity basics | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/print-plot` | Drawing tools: print/plot | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/print-plot/with-pen-tables` | ↳ with pen tables | not started | ForgeDrawing | — | — |  |
| `7.9/drawing-tools/pdf-with-layers-3d-pdf` | Drawing tools: PDF with layers/3D PDF | not started | ForgeDrawing | — | — |  |

## 7.10 Model-Based Definition (MBD)

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.10/dimxpert` | DimXpert | not started | ForgeDrawing | — | — |  |
| `7.10/3d-annotations` | 3D annotations | not started | ForgeDrawing | — | — |  |
| `7.10/3d-pmi-views` | 3D PMI views | not started | ForgeDrawing | — | — |  |
| `7.10/annotation-views` | annotation views | not started | ForgeDrawing | — | — |  |
| `7.10/3d-pdf-publishing` | 3D PDF publishing | not started | ForgeDrawing | — | — |  |
| `7.10/step-ap242-pmi-export` | STEP AP242 PMI export | not started | ForgeDrawing | — | — |  |
| `7.10/tolerance-status-display` | tolerance status display | not started | ForgeDrawing | — | — |  |

## 7.11 Tolerance & quality

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.11/tolanalyst` | TolAnalyst | not started | ForgeData | — | — |  |
| `7.11/tolanalyst/tolerance-stack-up` | ↳ tolerance stack-up | not started | ForgeData | — | — |  |
| `7.11/tolanalyst/worst-case-rss` | ↳ worst-case/RSS | not started | ForgeData | — | — |  |
| `7.11/inspection` | Inspection | not started | ForgeData | — | — |  |
| `7.11/inspection/ballooning` | ↳ ballooning | not started | ForgeData | — | — |  |
| `7.11/inspection/inspection-reports-from-drawings-and-3d` | ↳ inspection reports from drawings and 3D | not started | ForgeData | — | — |  |
| `7.11/inspection/cmm-data-import` | ↳ CMM data import | not started | ForgeData | — | — |  |
| `7.11/design-checker` | Design Checker | not started | ForgeData | — | — |  |
| `7.11/design-checker/standards-compliance` | ↳ standards compliance | not started | ForgeData | — | — |  |
| `7.11/compare-documents-features-geometry-boms` | Compare Documents/Features/Geometry/BOMs | not started | ForgeData | — | — |  |
| `7.11/equations-diagnostics` | Equations diagnostics | not started | ForgeData | — | — |  |

## 7.12 Analysis tools (in-part)

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.12/measure` | Measure | in progress | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift, Tests/ForgeCommandsTests/EngineTests.swift | measure | body↔body minimum distance only |
| `7.12/measure/all-modes` | ↳ all modes | not started | ForgeModel | — | — |  |
| `7.12/measure/point-to-point` | ↳ point-to-point | not started | ForgeModel | — | — |  |
| `7.12/measure/min-max-normal` | ↳ min/max/normal | not started | ForgeModel | — | — |  |
| `7.12/measure/projected` | ↳ projected | not started | ForgeModel | — | — |  |
| `7.12/mass-properties` | mass properties | in progress | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift, Tests/GoldenModelTests | get_mass_properties | density parameter; materials/overrides pending |
| `7.12/mass-properties/with-overrides` | ↳ with overrides | not started | ForgeModel | — | — |  |
| `7.12/mass-properties/per-config` | ↳ per-config | not started | ForgeModel | — | — |  |
| `7.12/section-properties` | section properties | not started | ForgeModel | — | — |  |
| `7.12/geometry-check` | geometry check | in progress | ForgeKernel | Tests/ForgeCommandsTests/EngineTests.swift | validate_model | BRepCheck validity + free edges |
| `7.12/draft-analysis` | draft analysis | not started | ForgeModel | — | — |  |
| `7.12/undercut-analysis` | undercut analysis | not started | ForgeModel | — | — |  |
| `7.12/thickness-analysis` | thickness analysis | not started | ForgeModel | — | — |  |
| `7.12/curvature-display` | curvature display | not started | ForgeModel | — | — |  |
| `7.12/zebra-stripes` | zebra stripes | not started | ForgeModel | — | — |  |
| `7.12/deviation-analysis` | deviation analysis | not started | ForgeModel | — | — |  |
| `7.12/parting-line-analysis` | parting line analysis | not started | ForgeModel | — | — |  |
| `7.12/symmetry-check` | symmetry check | not started | ForgeModel | — | — |  |
| `7.12/interference-check-between-bodies` | interference check between bodies | not started | ForgeModel | — | — |  |
| `7.12/dfmxpress` | DFMXpress | not started | ForgeModel | — | — |  |
| `7.12/dfmxpress/manufacturability-rules` | ↳ manufacturability rules | not started | ForgeModel | — | — |  |
| `7.12/costing` | Costing | not started | ForgeModel | — | — |  |
| `7.12/costing/machining` | ↳ machining | not started | ForgeModel | — | — |  |
| `7.12/costing/sheet-metal` | ↳ sheet metal | not started | ForgeModel | — | — |  |
| `7.12/costing/weldments` | ↳ weldments | not started | ForgeModel | — | — |  |
| `7.12/costing/casting` | ↳ casting | not started | ForgeModel | — | — |  |
| `7.12/costing/plastic` | ↳ plastic | not started | ForgeModel | — | — |  |
| `7.12/costing/3d-printed` | ↳ 3D printed | not started | ForgeModel | — | — |  |
| `7.12/costing/cost-templates` | ↳ cost templates | not started | ForgeModel | — | — |  |
| `7.12/sustainability` | Sustainability | not started | ForgeModel | — | — |  |
| `7.12/sustainability/environmental-impact` | ↳ environmental impact | not started | ForgeModel | — | — |  |
| `7.12/sustainability/material-comparison` | ↳ material comparison | not started | ForgeModel | — | — |  |
| `7.12/feature-statistics` | Feature Statistics | not started | ForgeModel | — | — |  |

## 7.13 Simulation (FEA)

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.13/study-types/linear-static` | Study types: linear static | not started | ForgeSim | — | — |  |
| `7.13/study-types/frequency` | Study types: frequency | not started | ForgeSim | — | — |  |
| `7.13/study-types/buckling` | Study types: buckling | not started | ForgeSim | — | — |  |
| `7.13/study-types/thermal` | Study types: thermal | not started | ForgeSim | — | — |  |
| `7.13/study-types/thermal/steady-transient` | ↳ steady/transient | not started | ForgeSim | — | — |  |
| `7.13/study-types/drop-test` | Study types: drop test | not started | ForgeSim | — | — |  |
| `7.13/study-types/fatigue` | Study types: fatigue | not started | ForgeSim | — | — |  |
| `7.13/study-types/fatigue/s-n` | ↳ S-N | not started | ForgeSim | — | — |  |
| `7.13/study-types/fatigue/event-based` | ↳ event-based | not started | ForgeSim | — | — |  |
| `7.13/study-types/nonlinear` | Study types: nonlinear | not started | ForgeSim | — | — |  |
| `7.13/study-types/nonlinear/static-dynamic` | ↳ static/dynamic | not started | ForgeSim | — | — |  |
| `7.13/study-types/nonlinear/material-and-geometric-nonlinearity` | ↳ material & geometric nonlinearity | not started | ForgeSim | — | — |  |
| `7.13/study-types/nonlinear/contact` | ↳ contact | not started | ForgeSim | — | — |  |
| `7.13/study-types/linear-dynamic` | Study types: linear dynamic | not started | ForgeSim | — | — |  |
| `7.13/study-types/linear-dynamic/modal-time-history` | ↳ modal time history | not started | ForgeSim | — | — |  |
| `7.13/study-types/linear-dynamic/harmonic` | ↳ harmonic | not started | ForgeSim | — | — |  |
| `7.13/study-types/linear-dynamic/random-vibration` | ↳ random vibration | not started | ForgeSim | — | — |  |
| `7.13/study-types/linear-dynamic/response-spectrum` | ↳ response spectrum | not started | ForgeSim | — | — |  |
| `7.13/study-types/pressure-vessel-design` | Study types: pressure vessel design | not started | ForgeSim | — | — |  |
| `7.13/study-types/submodeling` | Study types: submodeling | not started | ForgeSim | — | — |  |
| `7.13/study-types/design-study-optimization` | Study types: design study/optimization | not started | ForgeSim | — | — |  |
| `7.13/study-types/topology-optimization` | Study types: topology optimization | not started | ForgeSim | — | — |  |
| `7.13/study-types/topology-optimization/with-manufacturing-constraints` | ↳ with manufacturing constraints | not started | ForgeSim | — | — |  |
| `7.13/study-types/2d-simplification` | Study types: 2D simplification | not started | ForgeSim | — | — |  |
| `7.13/study-types/beam-truss-elements` | Study types: beam/truss elements | not started | ForgeSim | — | — |  |
| `7.13/study-types/shells` | Study types: shells | not started | ForgeSim | — | — |  |
| `7.13/study-types/shells/sheet-metal-midsurface-auto` | ↳ sheet metal/midsurface auto | not started | ForgeSim | — | — |  |
| `7.13/study-types/composites` | Study types: composites | not started | ForgeSim | — | — |  |
| `7.13/setup/materials` | Setup: materials | not started | ForgeSim | — | — |  |
| `7.13/setup/materials/linear-nonlinear-orthotropic-composite` | ↳ linear/nonlinear/orthotropic/composite | not started | ForgeSim | — | — |  |
| `7.13/setup/fixtures` | Setup: fixtures | not started | ForgeSim | — | — |  |
| `7.13/setup/fixtures/all-types` | ↳ all types | not started | ForgeSim | — | — |  |
| `7.13/setup/loads` | Setup: loads | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/force` | ↳ force | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/pressure` | ↳ pressure | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/torque` | ↳ torque | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/gravity` | ↳ gravity | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/centrifugal` | ↳ centrifugal | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/bearing` | ↳ bearing | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/remote` | ↳ remote | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/distributed-mass` | ↳ distributed mass | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/temperature` | ↳ temperature | not started | ForgeSim | — | — |  |
| `7.13/setup/loads/thermal-loads` | ↳ thermal loads | not started | ForgeSim | — | — |  |
| `7.13/setup/connectors` | Setup: connectors | not started | ForgeSim | — | — |  |
| `7.13/setup/connectors/bolts` | ↳ bolts | not started | ForgeSim | — | — |  |
| `7.13/setup/connectors/pins` | ↳ pins | not started | ForgeSim | — | — |  |
| `7.13/setup/connectors/springs` | ↳ springs | not started | ForgeSim | — | — |  |
| `7.13/setup/connectors/bearings` | ↳ bearings | not started | ForgeSim | — | — |  |
| `7.13/setup/connectors/welds` | ↳ welds | not started | ForgeSim | — | — |  |
| `7.13/setup/connectors/rigid` | ↳ rigid | not started | ForgeSim | — | — |  |
| `7.13/setup/connectors/link` | ↳ link | not started | ForgeSim | — | — |  |
| `7.13/setup/connectors/edge-weld` | ↳ edge weld | not started | ForgeSim | — | — |  |
| `7.13/setup/contacts` | Setup: contacts | not started | ForgeSim | — | — |  |
| `7.13/setup/contacts/bonded` | ↳ bonded | not started | ForgeSim | — | — |  |
| `7.13/setup/contacts/no-penetration` | ↳ no-penetration | not started | ForgeSim | — | — |  |
| `7.13/setup/contacts/shrink-fit` | ↳ shrink fit | not started | ForgeSim | — | — |  |
| `7.13/setup/contacts/virtual-wall` | ↳ virtual wall | not started | ForgeSim | — | — |  |
| `7.13/setup/contacts/contact-visualization` | ↳ contact visualization | not started | ForgeSim | — | — |  |
| `7.13/setup/mesh` | Setup: mesh | not started | ForgeSim | — | — |  |
| `7.13/setup/mesh/standard-curvature-based-blended` | ↳ standard/curvature-based/blended | not started | ForgeSim | — | — |  |
| `7.13/setup/mesh/controls` | ↳ controls | not started | ForgeSim | — | — |  |
| `7.13/setup/mesh/adaptive-h-p` | ↳ adaptive h/p | not started | ForgeSim | — | — |  |
| `7.13/setup/mesh/mesh-quality-diagnostics` | ↳ mesh quality diagnostics | not started | ForgeSim | — | — |  |
| `7.13/results/stress` | Results: stress | not started | ForgeSim | — | — |  |
| `7.13/results/stress/von-mises` | ↳ von Mises | not started | ForgeSim | — | — |  |
| `7.13/results/stress/principal` | ↳ principal | not started | ForgeSim | — | — |  |
| `7.13/results/stress/components` | ↳ components | not started | ForgeSim | — | — |  |
| `7.13/results/displacement` | Results: displacement | not started | ForgeSim | — | — |  |
| `7.13/results/strain` | Results: strain | not started | ForgeSim | — | — |  |
| `7.13/results/factor-of-safety` | Results: factor of safety | not started | ForgeSim | — | — |  |
| `7.13/results/reaction-forces` | Results: reaction forces | not started | ForgeSim | — | — |  |
| `7.13/results/free-body-forces` | Results: free-body forces | not started | ForgeSim | — | — |  |
| `7.13/results/probing` | Results: probing | not started | ForgeSim | — | — |  |
| `7.13/results/iso-clipping` | Results: iso-clipping | not started | ForgeSim | — | — |  |
| `7.13/results/section-clipping` | Results: section clipping | not started | ForgeSim | — | — |  |
| `7.13/results/animation` | Results: animation | not started | ForgeSim | — | — |  |
| `7.13/results/charts` | Results: charts | not started | ForgeSim | — | — |  |
| `7.13/results/compare-studies` | Results: compare studies | not started | ForgeSim | — | — |  |
| `7.13/results/trend-tracking` | Results: trend tracking | not started | ForgeSim | — | — |  |
| `7.13/results/report-generator` | Results: report generator | not started | ForgeSim | — | — |  |
| `7.13/results/results-export` | Results: results export | not started | ForgeSim | — | — |  |
| `7.13/results/results-export/csv` | ↳ CSV | not started | ForgeSim | — | — |  |
| `7.13/results/results-export/images` | ↳ images | not started | ForgeSim | — | — |  |
| `7.13/results/results-export/video` | ↳ video | not started | ForgeSim | — | — |  |
| `7.13/motion-to-fea-load-transfer` | Motion→FEA load transfer | not started | ForgeSim | — | — |  |
| `7.13/flow-to-fea-pressure-thermal-transfer` | Flow→FEA pressure/thermal transfer | not started | ForgeSim | — | — |  |

## 7.14 Flow Simulation (CFD)

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.14/internal-external-flow` | Internal/external flow | not started | ForgeSim | — | — |  |
| `7.14/compressible-incompressible` | compressible/incompressible | not started | ForgeSim | — | — |  |
| `7.14/steady-transient` | steady/transient | not started | ForgeSim | — | — |  |
| `7.14/heat-transfer` | heat transfer | not started | ForgeSim | — | — |  |
| `7.14/heat-transfer/conduction` | ↳ conduction | not started | ForgeSim | — | — |  |
| `7.14/heat-transfer/convection` | ↳ convection | not started | ForgeSim | — | — |  |
| `7.14/heat-transfer/radiation` | ↳ radiation | not started | ForgeSim | — | — |  |
| `7.14/heat-transfer/conjugate` | ↳ conjugate | not started | ForgeSim | — | — |  |
| `7.14/rotating-regions` | rotating regions | not started | ForgeSim | — | — |  |
| `7.14/porous-media` | porous media | not started | ForgeSim | — | — |  |
| `7.14/fans` | fans | not started | ForgeSim | — | — |  |
| `7.14/perforated-plates` | perforated plates | not started | ForgeSim | — | — |  |
| `7.14/electronics-cooling` | electronics cooling | not started | ForgeSim | — | — |  |
| `7.14/electronics-cooling/pcb` | ↳ PCB | not started | ForgeSim | — | — |  |
| `7.14/electronics-cooling/heat-sinks` | ↳ heat sinks | not started | ForgeSim | — | — |  |
| `7.14/electronics-cooling/tec` | ↳ TEC | not started | ForgeSim | — | — |  |
| `7.14/electronics-cooling/heat-pipes` | ↳ heat pipes | not started | ForgeSim | — | — |  |
| `7.14/hvac` | HVAC | not started | ForgeSim | — | — |  |
| `7.14/hvac/comfort-params` | ↳ comfort params | not started | ForgeSim | — | — |  |
| `7.14/free-surface` | free surface | not started | ForgeSim | — | — |  |
| `7.14/cavitation` | cavitation | not started | ForgeSim | — | — |  |
| `7.14/humidity` | humidity | not started | ForgeSim | — | — |  |
| `7.14/goals` | goals | not started | ForgeSim | — | — |  |
| `7.14/parametric-studies` | parametric studies | not started | ForgeSim | — | — |  |
| `7.14/results` | results | not started | ForgeSim | — | — |  |
| `7.14/results/cut-plots` | ↳ cut plots | not started | ForgeSim | — | — |  |
| `7.14/results/surface-plots` | ↳ surface plots | not started | ForgeSim | — | — |  |
| `7.14/results/flow-trajectories` | ↳ flow trajectories | not started | ForgeSim | — | — |  |
| `7.14/results/particle-studies` | ↳ particle studies | not started | ForgeSim | — | — |  |
| `7.14/results/iso-surfaces` | ↳ iso-surfaces | not started | ForgeSim | — | — |  |
| `7.14/results/animations` | ↳ animations | not started | ForgeSim | — | — |  |
| `7.14/results/xy-plots` | ↳ XY plots | not started | ForgeSim | — | — |  |
| `7.14/mesh-control` | mesh control | not started | ForgeSim | — | — |  |
| `7.14/engineering-database` | engineering database | not started | ForgeSim | — | — |  |

## 7.15 Plastics

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.15/mold-fill` | Mold fill | not started | ForgeSim | — | — |  |
| `7.15/pack` | pack | not started | ForgeSim | — | — |  |
| `7.15/cool` | cool | not started | ForgeSim | — | — |  |
| `7.15/warp` | warp | not started | ForgeSim | — | — |  |
| `7.15/gate-location-advisor` | gate location advisor | not started | ForgeSim | — | — |  |
| `7.15/runner-design` | runner design | not started | ForgeSim | — | — |  |
| `7.15/cooling-channel-design` | cooling channel design | not started | ForgeSim | — | — |  |
| `7.15/weld-line-air-trap-prediction` | weld line / air trap prediction | not started | ForgeSim | — | — |  |
| `7.15/sink-marks` | sink marks | not started | ForgeSim | — | — |  |
| `7.15/clamp-force` | clamp force | not started | ForgeSim | — | — |  |
| `7.15/material-database` | material database | not started | ForgeSim | — | — |  |
| `7.15/results-and-report` | results & report | not started | ForgeSim | — | — |  |

## 7.16 Routing & electrical

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.16/electrical-routing` | Electrical routing | not started | ForgeRouting | — | — |  |
| `7.16/electrical-routing/cables` | ↳ cables | not started | ForgeRouting | — | — |  |
| `7.16/electrical-routing/wires` | ↳ wires | not started | ForgeRouting | — | — |  |
| `7.16/electrical-routing/harnesses` | ↳ harnesses | not started | ForgeRouting | — | — |  |
| `7.16/electrical-routing/connectors` | ↳ connectors | not started | ForgeRouting | — | — |  |
| `7.16/electrical-routing/clips` | ↳ clips | not started | ForgeRouting | — | — |  |
| `7.16/electrical-routing/from-to-lists` | ↳ from-to lists | not started | ForgeRouting | — | — |  |
| `7.16/electrical-routing/harness-flattening` | ↳ harness flattening | not started | ForgeRouting | — | — |  |
| `7.16/electrical-routing/harness-drawings` | ↳ harness drawings | not started | ForgeRouting | — | — |  |
| `7.16/piping` | piping | not started | ForgeRouting | — | — |  |
| `7.16/piping/pipes` | ↳ pipes | not started | ForgeRouting | — | — |  |
| `7.16/piping/fittings` | ↳ fittings | not started | ForgeRouting | — | — |  |
| `7.16/piping/flanges` | ↳ flanges | not started | ForgeRouting | — | — |  |
| `7.16/piping/valves` | ↳ valves | not started | ForgeRouting | — | — |  |
| `7.16/piping/spools` | ↳ spools | not started | ForgeRouting | — | — |  |
| `7.16/piping/isometric-drawings-with-pcf-export` | ↳ isometric drawings with PCF export | not started | ForgeRouting | — | — |  |
| `7.16/tubing` | tubing | not started | ForgeRouting | — | — |  |
| `7.16/tubing/flexible-rigid` | ↳ flexible/rigid | not started | ForgeRouting | — | — |  |
| `7.16/tubing/bends` | ↳ bends | not started | ForgeRouting | — | — |  |
| `7.16/routing-library-manager` | routing library manager | not started | ForgeRouting | — | — |  |
| `7.16/auto-route` | auto-route | not started | ForgeRouting | — | — |  |
| `7.16/orthogonal-routing` | orthogonal routing | not started | ForgeRouting | — | — |  |
| `7.16/route-properties` | route properties | not started | ForgeRouting | — | — |  |
| `7.16/pandid-driven-routing` | P&ID-driven routing | not started | ForgeRouting | — | — |  |
| `7.16/electrical-schematic-module-schematics` | Electrical schematic module : schematics | not started | ForgeRouting | — | — |  |
| `7.16/electrical-schematic-module-schematics/electrical-schematic-equivalent` | ↳ Electrical Schematic equivalent | not started | ForgeRouting | — | — |  |
| `7.16/line-diagrams` | line diagrams | not started | ForgeRouting | — | — |  |
| `7.16/symbols-library` | symbols library | not started | ForgeRouting | — | — |  |
| `7.16/wire-numbering` | wire numbering | not started | ForgeRouting | — | — |  |
| `7.16/terminal-strips` | terminal strips | not started | ForgeRouting | — | — |  |
| `7.16/plc-i-o` | PLC I/O | not started | ForgeRouting | — | — |  |
| `7.16/reports` | reports | not started | ForgeRouting | — | — |  |
| `7.16/bidirectional-2d-3d-sync` | bidirectional 2D↔3D sync | not started | ForgeRouting | — | — |  |
| `7.16/pcb-import` | PCB import | not started | ForgeRouting | — | — |  |
| `7.16/pcb-import/idf-idx-ecad-collaboration` | ↳ IDF/IDX/ECAD collaboration | not started | ForgeRouting | — | — |  |
| `7.16/circuitworks-equivalent` | CircuitWorks equivalent | not started | ForgeRouting | — | — |  |

## 7.17 Rendering & visualization

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.17/realview-style-realtime-pbr` | RealView-style realtime PBR | not started | ForgeRender | — | — |  |
| `7.17/ambient-occlusion` | ambient occlusion | not started | ForgeRender | — | — |  |
| `7.17/shadows` | shadows | not started | ForgeRender | — | — |  |
| `7.17/perspective` | perspective | not started | ForgeRender | — | — |  |
| `7.17/scenes-environments` | scenes/environments | not started | ForgeRender | — | — |  |
| `7.17/scenes-environments/hdri` | ↳ HDRI | not started | ForgeRender | — | — |  |
| `7.17/appearances-library` | appearances library | not started | ForgeRender | — | — |  |
| `7.17/decals` | decals | not started | ForgeRender | — | — |  |
| `7.17/lights` | lights | not started | ForgeRender | — | — |  |
| `7.17/lights/directional` | ↳ directional | not started | ForgeRender | — | — |  |
| `7.17/lights/point` | ↳ point | not started | ForgeRender | — | — |  |
| `7.17/lights/spot` | ↳ spot | not started | ForgeRender | — | — |  |
| `7.17/lights/area` | ↳ area | not started | ForgeRender | — | — |  |
| `7.17/cameras` | cameras | not started | ForgeRender | — | — |  |
| `7.17/cameras/with-dof` | ↳ with DOF | not started | ForgeRender | — | — |  |
| `7.17/photoreal-path-traced-renderer` | photoreal path-traced renderer | not started | ForgeRender | — | — |  |
| `7.17/photoreal-path-traced-renderer/photoview-360-visualize-parity-denoising` | ↳ PhotoView 360 / Visualize parity: denoising | not started | ForgeRender | — | — |  |
| `7.17/photoreal-path-traced-renderer/render-regions` | ↳ render regions | not started | ForgeRender | — | — |  |
| `7.17/photoreal-path-traced-renderer/turntables` | ↳ turntables | not started | ForgeRender | — | — |  |
| `7.17/photoreal-path-traced-renderer/animation-rendering` | ↳ animation rendering | not started | ForgeRender | — | — |  |
| `7.17/photoreal-path-traced-renderer/sun-study` | ↳ sun study | not started | ForgeRender | — | — |  |
| `7.17/photoreal-path-traced-renderer/render-queue` | ↳ render queue | not started | ForgeRender | — | — |  |
| `7.17/exploded-animated-presentations` | exploded/animated presentations | not started | ForgeRender | — | — |  |
| `7.17/3d-views-and-pdf-web-publishing` | 3D Views and PDF/web publishing | not started | ForgeRender | — | — |  |
| `7.17/edrawings-equivalent-lightweight-viewer` | eDrawings-equivalent lightweight viewer | not started | ForgeRender | — | — |  |
| `7.17/edrawings-equivalent-lightweight-viewer/mac` | ↳ Mac | not started | ForgeRender | — | — |  |
| `7.17/edrawings-equivalent-lightweight-viewer/ios-visionos-stretch-goal` | ↳ iOS/visionOS stretch goal | not started | ForgeRender | — | — |  |
| `7.17/edrawings-equivalent-lightweight-viewer/ar-quick-look-via-usdz-export` | ↳ AR Quick Look via USDZ export | not started | ForgeRender | — | — |  |

## 7.18 CAM

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.18/feature-recognition-for-machinable-features` | Feature recognition for machinable features | not started | ForgeCAM | — | — |  |
| `7.18/feature-recognition-for-machinable-features/afr` | ↳ AFR | not started | ForgeCAM | — | — |  |
| `7.18/2-5-axis-mill` | 2.5-axis mill | not started | ForgeCAM | — | — |  |
| `7.18/3-axis-mill` | 3-axis mill | not started | ForgeCAM | — | — |  |
| `7.18/4-5-axis-indexed-and-simultaneous` | 4/5-axis indexed & simultaneous | not started | ForgeCAM | — | — |  |
| `7.18/4-5-axis-indexed-and-simultaneous/later-milestone` | ↳ later milestone | not started | ForgeCAM | — | — |  |
| `7.18/turning` | turning | not started | ForgeCAM | — | — |  |
| `7.18/mill-turn` | mill-turn | not started | ForgeCAM | — | — |  |
| `7.18/probing` | probing | not started | ForgeCAM | — | — |  |
| `7.18/technology-database` | technology database | not started | ForgeCAM | — | — |  |
| `7.18/technology-database/tools` | ↳ tools | not started | ForgeCAM | — | — |  |
| `7.18/technology-database/feeds-speeds` | ↳ feeds/speeds | not started | ForgeCAM | — | — |  |
| `7.18/technology-database/strategies` | ↳ strategies | not started | ForgeCAM | — | — |  |
| `7.18/stock-definition` | stock definition | not started | ForgeCAM | — | — |  |
| `7.18/toolpath-simulation-with-material-removal` | toolpath simulation with material removal | not started | ForgeCAM | — | — |  |
| `7.18/collision-gouge-checking` | collision/gouge checking | not started | ForgeCAM | — | — |  |
| `7.18/post-processors` | post-processors | not started | ForgeCAM | — | — |  |
| `7.18/post-processors/fanuc` | ↳ Fanuc | not started | ForgeCAM | — | — |  |
| `7.18/post-processors/haas` | ↳ Haas | not started | ForgeCAM | — | — |  |
| `7.18/post-processors/mazak` | ↳ Mazak | not started | ForgeCAM | — | — |  |
| `7.18/post-processors/siemens` | ↳ Siemens | not started | ForgeCAM | — | — |  |
| `7.18/post-processors/heidenhain` | ↳ Heidenhain | not started | ForgeCAM | — | — |  |
| `7.18/post-processors/grbl` | ↳ GRBL | not started | ForgeCAM | — | — |  |
| `7.18/post-processors/and-a-custom-post-language` | ↳ and a custom post language | not started | ForgeCAM | — | — |  |
| `7.18/setup-sheets` | setup sheets | not started | ForgeCAM | — | — |  |
| `7.18/g-code-output` | G-code output | not started | ForgeCAM | — | — |  |

## 7.19 Data management

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.19/pdm/vault` | PDM: vault | not started | ForgeData | — | — |  |
| `7.19/pdm/vault/local-and-server-based` | ↳ local and server-based | not started | ForgeData | — | — |  |
| `7.19/pdm/check-in-out` | PDM: check-in/out | not started | ForgeData | — | — |  |
| `7.19/pdm/version-and-revision-control` | PDM: version and revision control | not started | ForgeData | — | — |  |
| `7.19/pdm/lifecycle-states-and-workflows` | PDM: lifecycle states & workflows | not started | ForgeData | — | — |  |
| `7.19/pdm/where-used-contains` | PDM: where-used/contains | not started | ForgeData | — | — |  |
| `7.19/pdm/references-management` | PDM: references management | not started | ForgeData | — | — |  |
| `7.19/pdm/bom-management` | PDM: BOM management | not started | ForgeData | — | — |  |
| `7.19/pdm/search` | PDM: search | not started | ForgeData | — | — |  |
| `7.19/pdm/change-requests-ecos` | PDM: change requests/ECOs | not started | ForgeData | — | — |  |
| `7.19/pdm/permissions` | PDM: permissions | not started | ForgeData | — | — |  |
| `7.19/pdm/replication` | PDM: replication | not started | ForgeData | — | — |  |
| `7.19/pdm/minimum-viable-git-backed-local-vault` | PDM: Minimum viable: git-backed local vault | not started | ForgeData | — | — |  |
| `7.19/pdm/full-server-component` | PDM: full: server component | not started | ForgeData | — | — |  |
| `7.19/pdm/full-server-component/swift-on-server-or-equivalent` | ↳ Swift on server or equivalent | not started | ForgeData | — | — |  |
| `7.19/pack-and-go` | Pack and Go | not started | ForgeData | — | — |  |
| `7.19/rename-with-references` | rename with references | not started | ForgeData | — | — |  |
| `7.19/reference-repair` | reference repair | not started | ForgeData | — | — |  |
| `7.19/task-scheduler` | Task Scheduler | not started | ForgeData | — | — |  |
| `7.19/task-scheduler/batch-export-print-convert` | ↳ batch export/print/convert | not started | ForgeData | — | — |  |
| `7.19/design-library` | design library | not started | ForgeData | — | — |  |
| `7.19/file-references-and-external-reference-management` | file references and external reference management | not started | ForgeData | — | — |  |
| `7.19/backup-auto-recover` | backup/auto-recover | not started | ForgeData | — | — |  |
| `7.19/collaboration` | collaboration | not started | ForgeData | — | — |  |
| `7.19/collaboration/shared-links` | ↳ shared links | not started | ForgeData | — | — |  |
| `7.19/collaboration/markup-comments-edrawings-markup-parity` | ↳ markup/comments — eDrawings Markup parity | not started | ForgeData | — | — |  |

## 7.20 Import / export

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.20/native/own-formats` | Native: own formats | not started | ForgeData | — | — |  |
| `7.20/native/own-formats/section-4-5` | ↳ Section 4.5 | not started | ForgeData | — | — |  |
| `7.20/neutral/step-ap203-214-242` | Neutral: STEP AP203/214/242 | in progress | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift, Tests/ForgeCommandsTests/EngineTests.swift | export_step | AP214 export; kernel-level import (no command yet); no PMI |
| `7.20/neutral/step-ap203-214-242/with-pmi` | ↳ with PMI | not started | ForgeData | — | — |  |
| `7.20/neutral/iges` | Neutral: IGES | not started | ForgeData | — | — |  |
| `7.20/neutral/parasolid-via-step-only` | Neutral: Parasolid via STEP only | not started | ForgeData | — | — |  |
| `7.20/neutral/parasolid-via-step-only/no-direct-x-t-unless-licensed` | ↳ no direct x_t unless licensed | not started | ForgeData | — | — |  |
| `7.20/neutral/acis-sat` | Neutral: ACIS SAT | not started | ForgeData | — | — |  |
| `7.20/neutral/acis-sat/evaluate` | ↳ evaluate | not started | ForgeData | — | — |  |
| `7.20/neutral/jt` | Neutral: JT | not started | ForgeData | — | — |  |
| `7.20/neutral/jt/evaluate` | ↳ evaluate | not started | ForgeData | — | — |  |
| `7.20/neutral/vda-fs` | Neutral: VDA-FS | not started | ForgeData | — | — |  |
| `7.20/neutral/3mf` | Neutral: 3MF | not started | ForgeData | — | — |  |
| `7.20/neutral/stl` | Neutral: STL | in progress | ForgeKernel | Tests/ForgeKernelTests/KernelTests.swift, Tests/ForgeCommandsTests/EngineTests.swift | export_stl | export only |
| `7.20/neutral/obj` | Neutral: OBJ | not started | ForgeData | — | — |  |
| `7.20/neutral/ply` | Neutral: PLY | not started | ForgeData | — | — |  |
| `7.20/neutral/usdz-usd` | Neutral: USDZ/USD | not started | ForgeData | — | — |  |
| `7.20/neutral/gltf` | Neutral: glTF | not started | ForgeData | — | — |  |
| `7.20/neutral/vrml` | Neutral: VRML | not started | ForgeData | — | — |  |
| `7.20/neutral/dxf-dwg` | Neutral: DXF/DWG | not started | ForgeData | — | — |  |
| `7.20/neutral/dxf-dwg/2d-in-out` | ↳ 2D in/out | not started | ForgeData | — | — |  |
| `7.20/neutral/dxf-dwg/3d-dwg-out` | ↳ 3D DWG out | not started | ForgeData | — | — |  |
| `7.20/neutral/pdf-3d-pdf` | Neutral: PDF / 3D PDF | not started | ForgeData | — | — |  |
| `7.20/neutral/svg` | Neutral: SVG | not started | ForgeData | — | — |  |
| `7.20/neutral/ifc` | Neutral: IFC | not started | ForgeData | — | — |  |
| `7.20/neutral/ifc/bim` | ↳ BIM | not started | ForgeData | — | — |  |
| `7.20/neutral/idf-idx` | Neutral: IDF/IDX | not started | ForgeData | — | — |  |
| `7.20/neutral/idf-idx/ecad` | ↳ ECAD | not started | ForgeData | — | — |  |
| `7.20/neutral/rhino-3dm` | Neutral: Rhino .3dm | not started | ForgeData | — | — |  |
| `7.20/neutral/rhino-3dm/via-opennurbs` | ↳ via openNURBS | not started | ForgeData | — | — |  |
| `7.20/solidworks-native-files-sldprt-sldasm-slddrw` | SolidWorks native files (.sldprt/.sldasm/.slddrw): proprietary; investigate what is legally and technically possible (e.g., reading the embedded preview/Parasolid stream). Do not reverse-engineer in ways that violate license terms. Primary migration path is STEP + a FeatureWorks-style feature recognition pass. Write an ADR | not started | ForgeData | — | — |  |
| `7.20/3d-printing/3mf-with-color-materials` | 3D printing: 3MF with color/materials | not started | ForgeData | — | — |  |
| `7.20/3d-printing/print-bed-preview` | 3D printing: print-bed preview | not started | ForgeData | — | — |  |
| `7.20/3d-printing/support-overhang-analysis` | 3D printing: support/overhang analysis | not started | ForgeData | — | — |  |
| `7.20/3d-printing/hollowing` | 3D printing: hollowing | not started | ForgeData | — | — |  |
| `7.20/3d-printing/lattice-generation` | 3D printing: lattice generation | not started | ForgeData | — | — |  |

## 7.21 Customization & automation

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `7.21/full-api` | Full API | in progress | ForgeCommands | Tests/ForgeCommandsTests/EngineTests.swift, Tests/ForgeMCPTests/MCPTests.swift | execute | command bus + MCP; plugins/scripting pending |
| `7.21/full-api/section-5` | ↳ Section 5 | not started | ForgeCommands | — | — |  |
| `7.21/macros` | macros | not started | ForgeCommands | — | — |  |
| `7.21/add-in-manager` | add-in manager | not started | ForgeCommands | — | — |  |
| `7.21/toolbar-palette-customization` | toolbar/palette customization | not started | ForgeCommands | — | — |  |
| `7.21/keyboard-mouse-gesture-mapping` | keyboard/mouse gesture mapping | not started | ForgeCommands | — | — |  |
| `7.21/templates` | templates | not started | ForgeCommands | — | — |  |
| `7.21/templates/part-assembly-drawing` | ↳ part/assembly/drawing | not started | ForgeCommands | — | — |  |
| `7.21/document-properties-and-system-options` | document properties and system options | not started | ForgeCommands | — | — |  |
| `7.21/document-properties-and-system-options/every-solidworks-option-category-mapped` | ↳ every SolidWorks option category mapped | not started | ForgeCommands | — | — |  |
| `7.21/units-systems` | units systems | in progress | ForgeCore | Tests/ForgeCoreTests/CoreTests.swift | new_document(units) | MMGS-style length/angle units; mass/force/time units pending |
| `7.21/material-appearance-library-authoring` | material/appearance/library authoring | not started | ForgeCommands | — | — |  |
| `7.21/task-scheduler` | task scheduler | not started | ForgeCommands | — | — |  |

## Discovered (SolidWorks capabilities not listed in SPEC §7)

| ID | Feature | Status | Module | Test | MCP tool | Notes |
|---|---|---|---|---|---|---|
| `D/hide-show` | Hide/show bodies, components, sketches, planes (display pane) | not started | ForgeModel | — | — |  |
| `D/transparency` | Per-body/component transparency | not started | ForgeModel | — | — |  |
| `D/section-view-part` | Section view (dynamic display section in parts/assemblies) | not started | ForgeModel | — | — |  |
| `D/view-selector` | View selector cube, named/saved views, previous view | not started | ForgeModel | — | — |  |
| `D/zoom-to-selection` | Zoom to selection / zoom to area | not started | ForgeModel | — | — |  |
| `D/display-states-part` | Display states in parts | not started | ForgeModel | — | — |  |
| `D/feature-comments` | Comments/notes on features | not started | ForgeModel | — | — |  |
| `D/selection-sets` | Selection sets (saved selections) | not started | ForgeModel | — | — |  |
