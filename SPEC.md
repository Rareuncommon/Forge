# Build Prompt: "Forge" — SolidWorks-Parity Parametric CAD for macOS 27, AI-First

> Paste this into Claude Code at the root of an empty repo, or save it as `SPEC.md` and tell Claude Code: "Read SPEC.md and begin Milestone 0." Rename "Forge" to whatever you want.

---

## 0. Read this first — how you (Claude Code) must work

You are building a native macOS 27 parametric 3D CAD application with full feature parity with SolidWorks (Premium tier plus Simulation, Flow Simulation, Plastics, Electrical/Routing, Visualize, CAM, Inspection, MBD, PDM), redesigned so that (a) an AI agent can drive every capability through MCP and a plugin API, and (b) a human finds it more intuitive than SolidWorks.

This is a multi-year-scale scope. Do not pretend otherwise and do not compress it into a demo. Rules:

1. **Full scope is the target; milestones are the delivery order.** Every feature in Section 7 must end up implemented. Nothing is dropped. Order is set by Section 8.
2. **Never stub-and-claim.** A feature is only "done" when it regenerates correctly, round-trips save/load, has undo/redo, is exposed via the command API and MCP, and has tests. Placeholders must be marked `// NOT IMPLEMENTED` and listed as such in `FEATURES.md`.
3. **Maintain `FEATURES.md`** — a matrix of every item in Section 7 with status (`not started / in progress / done / verified`), owning module, test file, and MCP tool name. Update it every session. This is the source of truth for parity.
4. **Verify before you depend.** Check current versions, APIs, and licenses of every dependency (Xcode, Swift, OCCT, MCP Swift SDK, macOS 27 SDK APIs) against the live source before using them. Don't rely on memorized APIs. If a macOS 27 API you want doesn't exist, say so and pick an alternative.
5. **Tests before breadth.** Each milestone ends with a passing test suite, including golden-model regression tests (known parts whose volume, mass properties, face count, and bounding box are asserted).
6. **Work in small, reviewable commits.** At the end of each session, write `PROGRESS.md`: what was done, what's verified, what's broken, next steps.
7. **Ask me** only for decisions that are genuinely product-level (naming, licensing trade-offs, paid dependencies). Decide engineering details yourself and document the rationale in `docs/adr/` (architecture decision records).

---

## 1. Product goals

1. **Parity:** every SolidWorks modeling, assembly, drawing, analysis, and data-management capability listed in Section 7.
2. **AI-native:** every action a user can perform in the UI is a typed, documented, deterministic command that an agent can invoke via MCP, with rich introspection and stable geometric references. The UI is a client of the same command layer — no UI-only functionality.
3. **More intuitive than SolidWorks:** fewer modal dialogs, predictable selection, explainable errors, discoverable commands, live previews, and non-destructive editing everywhere.
4. **Native Mac:** Apple Silicon only, Metal rendering, SwiftUI shell, trackpad/Magic Mouse/3Dconnexion support, Apple Pencil via Sidecar, iCloud/Finder integration, Quick Look previews for its files.

---

## 2. Technology stack (verify versions before starting)

| Layer | Choice | Notes |
|---|---|---|
| Language | Swift 6 (strict concurrency) + C++20 | Swift/C++ interop for the kernel bridge |
| UI | SwiftUI, AppKit where SwiftUI falls short (viewport host, complex tree views, tables) | |
| Rendering | Metal (custom renderer) | Tessellation from kernel, GPU picking, edge/silhouette rendering, section caps, RealView-style PBR, path tracer for photoreal |
| B-rep geometry kernel | Open CASCADE Technology (OCCT), latest stable | LGPL 2.1 + exception: link dynamically. Wrap it — no OCCT types leak outside `ForgeKernel` |
| 2D sketch constraint solver | Evaluate FreeCAD's `planegcs` (LGPL) vs. building a custom Newton-Raphson/DogLeg solver | Must support DOF analysis, over/under-constrained diagnosis, drag solving. Record choice in ADR |
| Assembly mate solver | Custom rigid-body constraint solver | Must handle redundancy, limit mates, mechanical mates, flexible subassemblies |
| Meshing (FEA/CFD) | Netgen (LGPL) linked; Gmsh (GPL) only as an external process | Keep GPL code across a process boundary |
| FEA solver | CalculiX (GPL) as external process, plus own linear static solver for fast in-UI studies | Accelerate/Metal for sparse linear algebra where it helps |
| CFD | OpenFOAM as external process (GPL) behind an adapter | Long term: evaluate own solver |
| Scripting / plugins | Swift plugins (bundles) + embedded JavaScriptCore scripting + Python via external process | Macro recorder emits JS/Python |
| AI interface | MCP server (official Swift SDK if mature; otherwise implement the spec) — stdio + local Unix socket | See Section 5 |
| Persistence | Custom document format (Section 4.5) | |
| Build | Swift Package Manager + Xcode project for the app target; CMake for C++ deps via prebuilt xcframeworks | Reproducible dependency build script in `scripts/` |

License constraint: the app itself must remain distributable closed- or open-source at my choice. Therefore no GPL code linked into the app process. Document every dependency and its license in `docs/LICENSES.md`.

---

## 3. Architecture

```
ForgeKernel        C++/Swift wrapper over OCCT: B-rep ops, tessellation, healing, measurements
ForgeSketch        2D/3D sketch entities + constraint solver
ForgeModel         Parametric feature tree, regeneration engine, persistent naming, configurations, equations
ForgeAssembly      Components, mates, solver, motion, interference
ForgeDrawing       Sheets, views, projection, HLR, annotations, BOM, tables, GD&T
ForgeSim           FEA, motion, flow, plastics adapters, meshing, results
ForgeCAM           Toolpaths, feature recognition, post-processors
ForgeRouting       Electrical, piping, tubing, harness
ForgeData          File format, import/export, PDM, versioning
ForgeCommands      Typed command schema, validation, undo/redo transactions, macro recording
ForgeMCP           MCP server exposing ForgeCommands + query + render APIs
ForgeRender        Metal viewport, picking, photoreal renderer
ForgeApp           SwiftUI application shell
forge-cli          Headless engine: run commands, scripts, batch export, CI tests
```

Hard rules:
- **Headless first.** Everything except `ForgeApp` and the interactive parts of `ForgeRender` runs without a GUI. `forge-cli` must be able to build any model the UI can.
- **Single command bus.** UI, MCP, scripts, macros, and plugins all go through `ForgeCommands`. One implementation path.
- **Deterministic regeneration.** Same inputs → identical topology and identifiers, bit-for-bit where feasible. Tested.
- **Background regeneration** on a dedicated actor with cancellation; UI never blocks.

---

## 4. Core model design

### 4.1 Feature tree / history
- Ordered, parametric feature history with rollback bar, reorder, suppress/unsuppress, freeze bar, folders, and per-feature error/warning state.
- Dependency graph (parent/child) queryable by users and agents.
- Partial regeneration: only regenerate downstream of what changed.

### 4.2 Persistent naming (topological naming) — critical
The single biggest source of fragility in parametric CAD. Design this up front:
- Every face/edge/vertex gets a stable, generation-history-based identifier (feature ID + generator entity + operation role + disambiguator).
- References survive upstream edits that don't delete the referenced geometry. When they can't be resolved, fail explicitly with a repair UI and a machine-readable repair suggestion — never silently rebind to wrong geometry.
- Write an ADR and an extensive test suite (upstream dimension changes, feature reorder, pattern count changes, fillet insertion).

### 4.3 Semantic references (for AI and humans)
Beyond stable IDs, geometry must be addressable semantically, e.g.:
- `face(feature:"Boss-Extrude1", role:"end_cap")`
- `edges(of: "Cut-Extrude2", where: "concave && length > 5mm")`
- `face(nearest: [x,y,z], normal: +Z)`
- `plane("Top")`, `axis(of: "Hole1")`
Query results return IDs plus descriptors (type, area/length, normal, centroid, adjacency) so an agent can verify it picked the right entity.

### 4.4 Parameters
Global variables, equations (with functions, conditionals, unit-aware math), linked dimensions, design tables (CSV/Numbers/Excel import), configurations (derived configurations, per-config suppression, per-config properties), custom properties (file, config, cut-list).

### 4.5 File format
- Package bundle (`.forgepart`, `.forgeasm`, `.forgedrw`) containing: JSON-serialized feature history + parameters (human-diffable), cached B-rep (OCCT BREP binary), cached tessellation, thumbnails, and a manifest with schema version.
- Git-friendly: the history file must diff cleanly.
- Forward migration for schema versions; tested.
- Quick Look and Spotlight extensions.

---

## 5. AI interface (MCP + plugin API)

Design goal: an agent with no screen access can build, inspect, verify, and fix any model as reliably as a skilled user.

### 5.1 Command schema
- Every command has: name, JSON Schema for params, units, preconditions, return type, errors, undo behavior, and a human-readable doc string. Generated from Swift types — single source of truth.
- Support `dry_run: true` → returns what would change (new/modified/deleted entities, predicted errors) without committing.
- Transactions: `begin_transaction` / `commit` / `rollback`, so an agent can try multi-step edits atomically.
- Batch execution of command lists.

### 5.2 MCP tools (minimum set; expand as features land)
- **Discovery:** `list_commands`, `describe_command`, `search_commands(query)`.
- **Document:** `new_document`, `open`, `save`, `export`, `list_documents`, `get_document_state`.
- **Query:** `get_feature_tree`, `get_feature(id)`, `get_sketch(id)` (entities, constraints, DOF, solver status), `query_geometry(semantic query)`, `get_parameters`, `get_mass_properties`, `measure`, `check_interference`, `get_errors`.
- **Mutate:** `execute(command, params)`, `execute_batch`, `edit_feature`, `edit_dimension`, `set_parameter`, `delete`, `undo`, `redo`.
- **Vision:** `render_view(orientation, style, size, highlight_ids, section)` → PNG so multimodal agents can visually verify; `render_multiview` (standard 4-view sheet in one image); `pick(x,y)` on a rendered image → entity ID.
- **Verification:** `validate_model` (geometry check, open edges, self-intersection, zero-thickness), `compare_to_spec(spec)` (dimensions/volume/bbox assertions), `explain_error(id)` with fix suggestions.
- **Resources:** expose the feature tree, parameters, and the command catalog as MCP resources; feature-edit events as notifications.
- **Prompts:** built-in MCP prompts for common workflows ("model from dimensioned sketch description", "create drawing from part", "run static study").

### 5.3 Plugin API
- Swift plugin bundles loaded at runtime (sandbox-compatible) that can register new commands, features (custom parametric features with their own regeneration code), panels, and file translators.
- JavaScript scripting in-app; Python via `forge-cli`/socket.
- Macro recorder that records UI actions as replayable scripts using semantic references, not screen coordinates.

### 5.4 AI-friendliness requirements
- Every error is structured: code, message, offending entity IDs, suggested fixes as executable commands.
- No hidden state: selection, active sketch, active configuration, and edit mode are explicit and queryable/settable.
- Stable ordering of all lists.
- Unit handling explicit on every numeric param (`"25 mm"`, `"1 in"`, or number + document units).

---

## 6. UX principles (where to beat SolidWorks)

1. **Command palette** (⌘K) that searches every command, feature, parameter, and entity by name, with inline parameter entry.
2. **Inspector panel instead of modal PropertyManagers**: feature parameters editable any time, live preview, no OK/Cancel modality trap; ⌘Z always works.
3. **Direct-manipulation handles** on everything (drag extrude depth, fillet radius, sketch dims) with numeric entry on click.
4. **Explainable failures**: when a feature fails, highlight the cause in the viewport, show *why* in plain language, and offer one-click fixes.
5. **Smart selection**: hover preview, selection filters as a persistent toolbar, "select other" as a radial picker, loop/chain/tangent selection by modifier keys.
6. **Sketch clarity**: color by constraint state, DOF counter, drag to see remaining freedom, auto-dimension suggestions, conflict resolution panel.
7. **Timeline + tree hybrid** history with thumbnails, dependency highlighting on hover.
8. **Built-in onboarding**: interactive tutorials, contextual "what does this do" with animated previews.
9. **Mac-native input**: trackpad orbit/pan/zoom gestures, 3Dconnexion SpaceMouse, customizable mouse gestures, full keyboard shortcut customization, SolidWorks-compatible keymap preset.
10. **Accessibility**: VoiceOver for trees/panels, keyboard-only operation, high-contrast themes, Dynamic Type in panels.
11. **Performance targets**: 60 fps (120 on ProMotion) orbit on a 5,000-part assembly on M-series Pro; feature regen feedback < 100 ms for simple edits.

---

## 7. Complete feature inventory (parity checklist)

Every line below goes into `FEATURES.md`. If you discover a SolidWorks capability not listed, add it — the goal is nothing left out.

### 7.1 Sketching (2D and 3D)
- Entities: line, centerline, midpoint line, rectangle (corner, center, 3-point, parallelogram), slot (straight, center, arc, 3-point arc), circle (center, perimeter), arc (center, tangent, 3-point), polygon, ellipse, partial ellipse, parabola, conic, spline (point/control-vertex, style spline, equation-driven curve, fit spline), point, text (with fonts), construction geometry, fillet/chamfer (sketch).
- Tools: trim (power, corner, inside/outside), extend, offset (bi-directional, cap ends, construction), convert entities, intersection curve, silhouette entities, mirror (static + dynamic), linear/circular sketch patterns, move/copy/rotate/scale/stretch, split entities, jog line, sketch picture (with scale calibration), Autotrace, sketch blocks (create, insert, edit, explode, belts/chains), derived sketch, shared sketches, 3D sketch (with plane switching, 3D sketch on plane), sketch on face/surface, spline tools (tangency/curvature handles, simplify, fit, add tangency control, curvature combs), Instant2D, SketchXpert (conflict repair), Check Sketch for Feature, Repair Sketch, sketch contours/regions selection, Sketch Ink (pencil) equivalent.
- Relations: coincident, collinear, coradial, concentric, horizontal, vertical, parallel, perpendicular, tangent, equal, symmetric, midpoint, fix, merge, pierce, intersection, along X/Y/Z (3D), equal curvature, on-edge, curve length equal, automatic relations with inference, display/delete relations.
- Dimensions: smart dimension (linear, angular, radial, diameter, arc length, path length), driven/reference, ordinate, chain, baseline, fully define sketch, dimension to min/max arc condition, equations in dimension fields.

### 7.2 Part features
- Reference geometry: planes (all definitions), axes, coordinate systems, points, center of mass, mate references, bounding box, reference curves (projected, helix/spiral, composite, split line, curve through XYZ points, curve through reference points).
- Boss/base & cut: extrude (blind, through all, up to next/vertex/surface/offset, mid-plane, thin feature, draft, direction-2, contour selection), revolve, sweep (profile, solid-body tool sweep, twist, guide curves, path alignment), loft (guide curves, centerline, start/end constraints, tangency), boundary boss/cut, thicken/thicken cut, cut with surface.
- Applied: fillet (constant, variable, face, full-round, setback, FilletXpert, conic/curvature-continuous profiles), chamfer (angle-distance, distance-distance, vertex, offset face, face-face), draft (neutral plane, parting line, step, DraftXpert), shell (multi-thickness), rib, hole wizard (all standards and types: counterbore, countersink, straight, tapped, pipe tap, legacy, slot, counterbore/countersink slot; ANSI, ISO, DIN, JIS, GB, BSI, KS, AS, IS, PEM etc.), advanced hole, cosmetic thread, thread feature, stud wizard, dome, wrap (emboss, deboss, scribe), indent, flex (bend, twist, taper, stretch), deform, intersect, freeform, lip/groove, mounting boss, snap hook/groove, vent, fastening features.
- Patterns & mirror: linear, circular, curve-driven, sketch-driven, table-driven, fill pattern, variable pattern, chain pattern, mirror (features, faces, bodies), geometry pattern, instance skipping/varying.
- Multibody: combine (add/subtract/common), split, move/copy body, delete/keep body, insert part, insert into new part, save bodies, body folders, cut list.
- Direct editing: move/rotate/offset/replace/delete face, delete hole, simplify/defeature, Instant3D, import diagnostics & healing, FeatureWorks (feature recognition on imported bodies).
- Scale, fillet-aware undo, library features, design library, smart features, forming tools, cosmetic patterns, decals, appearances, materials database (with custom materials), sensors, feature freeze, feature statistics, performance evaluation.
- Mesh/BREP: import mesh (STL/OBJ/3MF), mesh bodies, convert mesh to body, graphics bodies, segment mesh, 3D Texture.

### 7.3 Surfacing
- Extruded, revolved, swept, lofted, boundary, planar, fill (with constraints/curvature), freeform, offset, ruled, radiated, knit (with gap control), untrim, extend, trim (standard/mutual), delete face/hole, replace face, thicken, surface flatten, mid-surface, face curves, parting surface, shut-off surface, sew/heal, curvature continuity checks.

### 7.4 Sheet metal
- Base flange/tab, edge flange (all positions, custom profile), miter flange, hem (all types), jog, sketched bend, cross break, closed corner, welded corner, break/relief corner (all relief types), corner trim, forming tools (and custom forming tools), vent, lofted bend (formed and bent), swept flange, convert to sheet metal, insert bends/rip, flatten/unfold/fold, flat pattern (with bend lines, bend notes, grain direction, flat-pattern export to DXF/DWG), gauge tables, bend tables, K-factor/bend allowance/bend deduction, tab & slot, normal cut, multibody sheet metal, sheet metal cut list properties.

### 7.5 Weldments
- Structural member (profiles library: ANSI/ISO, custom profiles, corner treatments, trim/extend, groups), end caps, gussets, fillet beads, weld beads, cut lists with properties, weldment drawings/cut list tables, 3D-sketch-driven frames.

### 7.6 Mold / tooling
- Draft analysis, undercut analysis, parting lines, shut-off surfaces, parting surfaces, tooling split, core/cavity, core pins, scale for shrinkage, ruled surface for molds, mold base integration.

### 7.7 Assemblies
- Top-down and bottom-up design; insert components, virtual components, subassemblies (rigid/flexible), component patterns (linear, circular, pattern-driven, sketch-driven, curve-driven, chain), mirror components (opposite-hand), smart components, smart fasteners, Toolbox (full standard hardware library: bolts, screws, nuts, washers, pins, bearings, gears, cams, pulleys, sprockets, structural steel, O-rings, keyways).
- Mates: standard (coincident, parallel, perpendicular, tangent, concentric, lock, distance, angle), advanced (profile center, symmetric, width, path, linear/linear coupler, limit distance/angle), mechanical (cam, slot, hinge, gear, rack & pinion, screw, universal joint), mate references, SmartMates, Quick Mates, MateXpert/mate diagnostics, mate folders, mate controller, copy with mates.
- Tools: move/rotate component (with collision detection, dynamic clearance, physical dynamics), interference detection, clearance verification, hole alignment, assembly visualization, AssemblyXpert, exploded views (with explode lines, radial/regular steps, animation), section views, configurations, display states, Large Assembly Mode, Large Design Review, lightweight components, SpeedPak, defeature, envelopes, Treehouse (structure planning), assembly features (cuts, holes, weld beads), in-context references (external reference management, lock/break), replace components, Pack and Go, magnetic mates / Asset Publisher, belts/chains, structure system, assembly layout sketches, BOM in assembly, Isolate, component preview, envelope publisher.

### 7.8 Motion
- Animation (keyframe timeline, camera animation, walk-through), Basic Motion (motors, springs, contact, gravity), Motion Analysis (dynamic: forces, dampers, bushings, 3D contact, friction, results & plots, export loads to FEA), Motion optimization, event-based motion, interference during motion, trace paths.

### 7.9 Drawings
- Sheets and formats (all ANSI/ISO/DIN/JIS/GB templates, editable title blocks with property links, multiple sheets, sheet scaling), drafting standards editor.
- Views: standard 3-view, model view, projected, auxiliary, section (with section view assist, aligned, half, offset, partial), detail (circular/profile), broken-out section, break, crop, alternate position, relative-to-model, 3D drawing view, flat pattern views, exploded views, empty views, view palette, rotate views, HLR/HLV, tangent edge options, shaded/wireframe, isometric, live section.
- Annotations: model items import, smart dimension (all types incl. ordinate, chamfer, baseline, chain, angular running), DimXpert for drawings, notes (linked properties, hyperlinks, balloons in notes), balloons (auto-balloon, stacked), surface finish, weld symbols (ANSI/ISO), GD&T (feature control frames, datums, datum targets, composite frames), center marks, centerlines, cosmetic threads, hole callouts, revision clouds, area hatch/fill, blocks, magnetic lines, layers, dimension tolerance display (all types, fits, tables).
- Tables: BOM (top-level, parts-only, indented, weldment cut list, with custom columns & equations), hole table, revision table, general table, bend table, punch table, weld table, design table, title block table, general table templates.
- Drawing tools: Auto-arrange dimensions, dimension palette, format painter, sketch in drawing, Design Checker, drawing compare, detailing mode, DWG/DXF editing parity basics, print/plot (with pen tables), PDF with layers/3D PDF.

### 7.10 Model-Based Definition (MBD)
- DimXpert, 3D annotations, 3D PMI views, annotation views, 3D PDF publishing, STEP AP242 PMI export, tolerance status display.

### 7.11 Tolerance & quality
- TolAnalyst (tolerance stack-up, worst-case/RSS), Inspection (ballooning, inspection reports from drawings and 3D, CMM data import), Design Checker (standards compliance), Compare Documents/Features/Geometry/BOMs, Equations diagnostics.

### 7.12 Analysis tools (in-part)
- Measure (all modes, point-to-point, min/max/normal, projected), mass properties (with overrides, per-config), section properties, geometry check, draft analysis, undercut analysis, thickness analysis, curvature display, zebra stripes, deviation analysis, parting line analysis, symmetry check, interference check between bodies, DFMXpress (manufacturability rules), Costing (machining, sheet metal, weldments, casting, plastic, 3D printed; cost templates), Sustainability (environmental impact, material comparison), Feature Statistics.

### 7.13 Simulation (FEA)
- Study types: linear static, frequency, buckling, thermal (steady/transient), drop test, fatigue (S-N, event-based), nonlinear (static/dynamic, material & geometric nonlinearity, contact), linear dynamic (modal time history, harmonic, random vibration, response spectrum), pressure vessel design, submodeling, design study/optimization, topology optimization (with manufacturing constraints), 2D simplification, beam/truss elements, shells (sheet metal/midsurface auto), composites.
- Setup: materials (linear/nonlinear/orthotropic/composite), fixtures (all types), loads (force, pressure, torque, gravity, centrifugal, bearing, remote, distributed mass, temperature, thermal loads), connectors (bolts, pins, springs, bearings, welds, rigid, link, edge weld), contacts (bonded, no-penetration, shrink fit, virtual wall, contact visualization), mesh (standard/curvature-based/blended, controls, adaptive h/p, mesh quality diagnostics).
- Results: stress (von Mises, principal, components), displacement, strain, factor of safety, reaction forces, free-body forces, probing, iso-clipping, section clipping, animation, charts, compare studies, trend tracking, report generator, results export (CSV, images, video).
- Motion→FEA load transfer; Flow→FEA pressure/thermal transfer.

### 7.14 Flow Simulation (CFD)
- Internal/external flow, compressible/incompressible, steady/transient, heat transfer (conduction, convection, radiation, conjugate), rotating regions, porous media, fans, perforated plates, electronics cooling (PCB, heat sinks, TEC, heat pipes), HVAC (comfort params), free surface, cavitation, humidity; goals, parametric studies, results (cut plots, surface plots, flow trajectories, particle studies, iso-surfaces, animations, XY plots), mesh control, engineering database.

### 7.15 Plastics
- Mold fill, pack, cool, warp; gate location advisor, runner design, cooling channel design, weld line / air trap prediction, sink marks, clamp force, material database, results & report.

### 7.16 Routing & electrical
- Electrical routing (cables, wires, harnesses, connectors, clips, from-to lists, harness flattening, harness drawings), piping (pipes, fittings, flanges, valves, spools, isometric drawings with PCF export), tubing (flexible/rigid, bends), routing library manager, auto-route, orthogonal routing, route properties, P&ID-driven routing.
- Electrical schematic module (Electrical Schematic equivalent): schematics, line diagrams, symbols library, wire numbering, terminal strips, PLC I/O, reports, bidirectional 2D↔3D sync; PCB import (IDF/IDX/ECAD collaboration), CircuitWorks equivalent.

### 7.17 Rendering & visualization
- RealView-style realtime PBR, ambient occlusion, shadows, perspective, scenes/environments (HDRI), appearances library, decals, lights (directional, point, spot, area), cameras (with DOF), photoreal path-traced renderer (PhotoView 360 / Visualize parity: denoising, render regions, turntables, animation rendering, sun study, render queue), exploded/animated presentations, 3D Views and PDF/web publishing, eDrawings-equivalent lightweight viewer (Mac, iOS/visionOS stretch goal, AR Quick Look via USDZ export).

### 7.18 CAM
- Feature recognition (AFR) for machinable features, 2.5-axis mill, 3-axis mill, 4/5-axis indexed & simultaneous (later milestone), turning, mill-turn, probing, technology database (tools, feeds/speeds, strategies), stock definition, toolpath simulation with material removal, collision/gouge checking, post-processors (Fanuc, Haas, Mazak, Siemens, Heidenhain, GRBL, and a custom post language), setup sheets, G-code output.

### 7.19 Data management
- PDM: vault (local and server-based), check-in/out, version and revision control, lifecycle states & workflows, where-used/contains, references management, BOM management, search, change requests/ECOs, permissions, replication. Minimum viable: git-backed local vault; full: server component (Swift on server or equivalent).
- Pack and Go, rename with references, reference repair, Task Scheduler (batch export/print/convert), design library, file references and external reference management, backup/auto-recover, collaboration (shared links, markup/comments — eDrawings Markup parity).

### 7.20 Import / export
- Native: own formats (Section 4.5).
- Neutral: STEP AP203/214/242 (with PMI), IGES, Parasolid via STEP only (no direct x_t unless licensed), ACIS SAT (evaluate), JT (evaluate), VDA-FS, 3MF, STL, OBJ, PLY, USDZ/USD, glTF, VRML, DXF/DWG (2D in/out, 3D DWG out), PDF / 3D PDF, SVG, IFC (BIM), IDF/IDX (ECAD), Rhino .3dm (via openNURBS).
- **SolidWorks native files (.sldprt/.sldasm/.slddrw):** proprietary; investigate what is legally and technically possible (e.g., reading the embedded preview/Parasolid stream). Do not reverse-engineer in ways that violate license terms. Primary migration path is STEP + a FeatureWorks-style feature recognition pass. Write an ADR.
- 3D printing: 3MF with color/materials, print-bed preview, support/overhang analysis, hollowing, lattice generation.

### 7.21 Customization & automation
- Full API (Section 5), macros, add-in manager, toolbar/palette customization, keyboard/mouse gesture mapping, templates (part/assembly/drawing), document properties and system options (every SolidWorks option category mapped), units systems, material/appearance/library authoring, task scheduler.

---

## 8. Milestones (delivery order)

Each milestone has exit criteria: tests pass, `FEATURES.md` updated, `forge-cli` can reproduce every demo, MCP tools exist for every new command.

- **M0 — Foundations:** repo, build system, OCCT xcframework build script, `ForgeKernel` bridge, `ForgeCommands` schema + undo/redo, `forge-cli`, MCP server skeleton with `list_commands`/`describe_command`, CI running headless tests. Metal viewport rendering a tessellated OCCT box with orbit/pan/zoom and picking.
- **M1 — Sketch:** 2D sketch entities, constraint solver with DOF analysis, dimensions, sketch UI, sketch MCP tools, solver regression tests.
- **M2 — Core part modeling:** feature tree, regeneration engine, persistent naming v1, extrude/revolve/cut, fillet/chamfer, shell, hole wizard (subset), patterns, mirror, reference geometry, equations/global variables, materials, mass properties, measure, file format v1, STEP/STL export, `render_view` MCP tool. **Golden-model suite starts here.**
- **M3 — Advanced part + surfaces:** sweep, loft, boundary, draft, rib, multibody, full surfacing set, direct editing, configurations, design tables, remaining hole wizard standards, STEP/IGES import with healing.
- **M4 — Assemblies:** components, all mate types, solver, interference, exploded views, subassemblies, patterns, Toolbox v1, BOM, large assembly performance work.
- **M5 — Drawings:** views, HLR, dimensions/annotations, GD&T, tables, templates, PDF/DXF/DWG export.
- **M6 — Sheet metal + weldments + mold tools.**
- **M7 — Simulation v1:** meshing, linear static/frequency/thermal, results viz; then Motion (basic + dynamic).
- **M8 — Rendering:** PBR viewport polish, path tracer, animation rendering, USDZ/AR.
- **M9 — MBD, tolerance analysis, inspection, DFM, costing, sustainability, design checker.**
- **M10 — Advanced simulation:** nonlinear, dynamics, fatigue, drop test, topology optimization; Flow Simulation adapter; Plastics.
- **M11 — Routing & electrical.**
- **M12 — CAM.**
- **M13 — PDM & collaboration.**
- **M14 — Parity sweep:** audit `FEATURES.md` against current SolidWorks release notes and help documentation; close every gap.

---

## 9. Testing & quality

- Unit tests per module; property-based tests for the constraint solver and boolean ops.
- Golden models: a growing library of parts/assemblies defined as command scripts, with asserted volume, surface area, mass properties, topology counts, and bounding boxes. Run on every commit.
- Persistent-naming torture tests (upstream edits must not break or silently rebind downstream references).
- MCP end-to-end tests: scripted agent sessions that build models only through MCP and verify with `compare_to_spec`.
- Performance benchmarks tracked over time (regen time, frame time, memory) with regression alerts.
- Fuzzing for file import.

---

## 10. First session instructions

1. Verify current stable versions and licenses of: Xcode/Swift for macOS 27, OCCT, MCP Swift SDK, planegcs, Netgen. Report findings.
2. Write ADRs for: kernel wrapping strategy, persistent naming design, sketch solver choice, file format, GPL process-boundary policy.
3. Generate `FEATURES.md` from Section 7 (every line as a row, status `not started`).
4. Execute Milestone 0. Stop when M0 exit criteria are met and report with `PROGRESS.md`.
