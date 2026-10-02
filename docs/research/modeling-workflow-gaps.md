# Modeling workflow gaps and complete matrix inventory

Audit date: 2026-09-30. Source baseline: `2ab8a66`, before the follow-up workflow fixes.
This document compares the repository's declared scope with actual command registrations,
shared UI models, native shell bindings, and public SOLIDWORKS documentation. It is a
source audit, not a completed interactive test on all three operating systems. Findings
remain baseline findings if the implementation changes after this audit.

The scope in [SPEC](../../SPEC.md) is explicitly a multi-year product. The appendix
accounts for **every one of the 1,000 FEATURES rows**, grouped by its original section.
It does not claim to enumerate every behavior of every SOLIDWORKS release/add-in, nor
that reading a row independently verifies its implementation. Rows overlap and vary
in size; status counts are not a percentage of product functionality.

## Follow-up delivery: eight everyday workflows

The follow-up changes address the following eight workflows. This section describes
implemented source paths and their regression coverage; the baseline findings and
1,000-row appendix below are intentionally preserved as the pre-change snapshot.
Native macOS/Windows interactive behavior still requires validation on those systems.

| Workflow delivered | Actual scope and evidence | Remaining boundary |
|---|---|---|
| 1. Start a sketch on the selected face | `SketchPlacementWorkflows.swift` and both ribbons expose Sketch on Face from the Features tab as well as the Sketch tab. The shared action respects the selected face; body/edge selections no longer silently choose Front. `SketchPlacementWorkflowTests` covers viewport face picking, placement/camera, drawing a profile and cutting, and invalid/curved selections. | Builds on existing planar-face engine support; arbitrary curved-surface sketching and automatic face-selected Cut → sketch → resume are still absent. |
| 2. Convert selected model edges/face boundaries | New registered `sketch.convert_entities` plus Select Model Geometry and Convert Entities UI actions. Exact projections support lines and circular edges parallel to the sketch plane, deduplicate shared boundaries, optionally mark construction geometry, and fix curves by default. `SketchConvertTests` and `SketchPlacementWorkflowTests` cover engine/UI paths. | These are detached snapshots, not associative On Edge references. Source edits do not resize converted curves. Oblique circular, ellipse, spline and degenerate projections are rejected atomically. |
| 3. Split sketch entities interactively | Shared `SketchTool.split`, both ribbons, on-curve clicks, pending-point state for closed curves and cancellation call the existing `sketch.split` command. `SketchSplitWorkflowTests` covers supported interactions. | Unsupported splines remain unsupported; this does not implement the entire sketch repair or combine-split-entities workflow. |
| 4. Move/Copy Bodies from the inspector | New Move/Copy Bodies operation, shared/mac property pages and ribbon action expose translation, rotation and copy. Existing transform features can be reopened; arbitrary stored rotation axes are retained. `BodyPlacementWorkflowTests` covers copy/rotate/translate, edit/undo and custom-axis round-trip. | No direct-manipulation triad, mate-based placement or assembly components are implied. |
| 5. Edit Up To Vertex extrusions faithfully | Both inspector paths now represent Up To Vertex and its coordinate values, including direction 2, rather than defaulting a stored end condition to Blind. Feature editing retains this supported mode. | A coordinate termination is not a persistent topological vertex reference. Up-to-surface/next/body and selected-contour support remain separate gaps. |
| 6. Normal To selected geometry | Shared `normalToSelection()` resolves a picked planar face or plane, and Normal To availability includes suitable selection without an active sketch. Existing active-sketch alignment remains. `BodyPlacementWorkflowTests` covers face alignment. | Cylindrical/conical alignment, two-face orientation, reverse-normal toggling, named views and complete plane-selection affordances are not claimed. |
| 7. Rename bodies from the tree | Shared `RenameWorkflows.swift`, body-tree Rename actions and native name dialogs call `body.rename` by stable identity. `RenameWorkflowTests` covers Unicode, cancellation/no-op, invalid names, undo/redo and package reopen. | This edits the body's display name; it does not rename external files or implement reference-preserving Pack and Go. |
| 8. Rename features and absorbed sketches on each desktop | Shared/mac tree Rename actions call `feature.rename`; absorbed sketch rows use their owning sketch feature. macOS, GTK and Win32 provide native text entry; headless services cancel by default. The same rename regression suite checks action availability and persistence. | This supplies consistent naming access; folders, feature freeze, configuration-specific naming and native-platform accessibility certification remain outside this change. |

The follow-up also fixes supporting feature-edit and persistent-reference issues found
while exercising these paths. It does **not** complete the remaining families below:
selection filters/Select Other, hide/show/isolate, face/edge measurement, region picking,
assemblies, drawings, simulation, manufacturing and the remaining matrix backlog.
Full test/build outcomes belong in the PR and PROGRESS record; this document makes no
independent all-tests-passed claim.

## Further delivery: measurement, body visibility and curved slots

The next implementation adds `query.measure` for bodies and individual faces, edges
and vertices, including persistent face/edge names. One selection reports its physical
size or coordinates; two report B-rep minimum distance, closest points and XYZ deltas.
The desktop accepts either selection count and displays command errors. Angles,
maximum/normal distances and sketch-entity measurement remain pending.

Body visibility now has registered show/hide/isolate/exit/show-all commands. Hidden
bodies remain in modeling and export, but are excluded from rendering, picking and
framing. Ordinary hidden state persists, including suppressed feature output intent;
isolation is temporary and exits to the prior state. Tree, ribbon and macOS View/context
actions expose the commands. Components, individual sketch and plane visibility still
need their own display-pane workflows.

Centerpoint and three-point arc slots create editable concentric sides and tangent
semicircular caps, with a construction centerline. All four slot variants are available
in desktop tool choices; curved slots use four clicks with a live boundary preview.
Command and desktop regressions cover analytic extrusion volume, solver degrees of
freedom, width editing, construction, atomic validation, undo and persistence. Grouped
Fix Slot/Equal Slots relations remain pending.


## Further delivery: selected contours, planar limits and selection filters

Extrusions now store complete outer-curve ID sets as contour intent. Region discovery
returns holes, nested islands, analytic area, sampled display outlines and point hits.
Desktop checklists and explicit ray picking share these selectors, including while
starting an extrusion from an active drawing tool. Unrelated open geometry can be ignored
for explicit selections; crossing/branching sketches still need intersection-cell decomposition.

Planar Up To Surface and Offset From Surface use exact clipped geometry for parallel or
oblique limits, true perpendicular offset, both directions, persistent references and
upstream dependency tracking. The supporting plane of a face is extended. Curved limits,
Translate Surface, Up To Next and draft combined with surface limits remain pending.
[Official Extrude PropertyManager](https://help.solidworks.com/2021/english/solidworks/sldworks/r_extrude_propertymanager.htm).

All/body/face/edge filters and Select Other candidate cycling now share CPU ray candidate
queries across the native desktops and MCP. Hidden bodies and reference overlays are
excluded. Filters are session preferences; explicit/tree selections stay unrestricted.
The UI provides Tab/ribbon/menu cycling. Radial candidate UI, vertex filters, hover previews
and chain/tangent selection remain pending.

## How to interpret the evidence

- **Engine available, guided UI missing** means there is a registered command but no
  corresponding ordinary tool/property page found. The macOS JSON command palette,
  CLI, or MCP may still reach it. Windows/Linux do not have equivalent command palettes.
- **Partial** means an actual implementation exists but its supported options or
  platform path are narrower than the workflow. A toolbar label does not establish parity.
- **Absent** means the relevant model/command/UI was not found, corroborated by the
  matrix. A kernel operation or rendered picture is not a finished product workflow.
- **Present, verify interaction** means source contains a viable path. It must not be
  described as absent solely because FEATURES or an older research note is stale.

Every delivered model operation still needs SPEC §0 proof: deterministic rebuild,
persistence, undo/redo, command/MCP exposure, and regression coverage. UI features
add selection, preview/cancel, edit-existing, keyboard, and per-platform interaction tests.

## Highest-value everyday gaps

| Priority / workflow | Baseline classification and evidence | Concrete implementation and acceptance criterion |
|---|---|---|
| P0: edit an extrusion without changing its meaning | Partial, with a data-integrity hazard. `Commands/ProfileCommands.swift` supports `up_to_vertex`; `ForgeUI/PropertyManager.swift` has only four `EndConditionUI` cases and maps unknown stored values to `.blind` in `editFeature`. | Preserve or explicitly reject unsupported edit options; preferably expose Up To Vertex for both directions. An MCP-created up-to-vertex feature opened and committed unchanged must retain its termination reference/value and geometry. Changing only its name or unrelated option must not turn it into Blind. |
| P1: Normal To a selected face/plane | Engine camera primitive available, guided selection workflow missing. `AppModel.normalToSketch()` only reads `sketchState.plane`; the macOS command is disabled without an active sketch. WinShell uses the same method. | Resolve a selected planar face/reference plane without creating a sketch; support explicit failure for unsuitable geometry. Align, retain target/zoom sensibly, and return using Previous View. Test on an offset and tilted planar face. [Official Normal To behavior](https://help.solidworks.com/2014/English/solidworks/sldworks/t_viewing_models_normal_to.htm). |
| P1: Split Entities with the mouse | Engine available, guided UI missing. `SketchSplit` is registered and implemented; `SketchTool`, shared ribbon and macOS ribbon expose Trim/Extend but not Split. | Add a split tool: one on-curve point for open entities, two for closed entities; preview pending points, cancel safely, preserve constraints or explain removals. Undo restores the original curve. Spline support remains a separate kernel/solver gap. [Official Split Entities](https://help.solidworks.com/2026/english/SolidWorks/sldworks/c_split_entities.htm). |
| P1: Move/Copy Body | Engine available, guided UI missing. `BodyTransform` is registered, but `Operation` and `FeatureRow.operation` have no body-transform property page. A move icon alone does not allow editing. | Provide body selection, translation/rotation, copy choice, numeric units and preview. Reopen/edit the resulting feature without losing its transform. Test rotate then translate and copy versus move independently. [Official features toolbar](https://help.solidworks.com/2026/english/SolidWorks/sldworks/r_Features_Toolbar.htm). |
| P1: Rename features and bodies on every desktop | Engine available, platform UI gap. `FeatureRename`/`BodyRename` registered. macOS `FeatureTree.swift` has feature rename; shared `TreeSpec` menus do not. Body menus only measure/export. | Add shared rename affordances with current value, cancellation and invalid-input errors. Verify tree refresh, document reopen and undo; identity-based references must survive renames. |
| P1: Measure two selected faces/edges | Partial, misleading UI/error handling. `QueryMeasure.run` rejects non-body references. UI `computeMeasure()` passes selected refs and uses `try?`; the mac context Measure button accepts any two selections. | Either restrict and explain supported body-only scope or implement topology-level distance/angle measurement. Picking two faces must produce a value with units or a visible supported-scope error, never a silently blank result. |
| P1: Convert Entities | Absent. FEATURES `7.1/tools/convert-entities`; no conversion command in registry. | Project selected model edges/loops into the active sketch and retain external references through rebuild. A face sketch should copy an existing hole boundary without redrawing it. Start with planar lines/circles; explicitly reject unsupported curves. [Official Convert Entities](https://help.solidworks.com/2026/english/SolidWorks/Sldworks/c_Convert_Entities.htm). |
| P1: Hide/show/isolate solids and sketches | Absent as a persisted per-entity workflow. `DisplayOptions` controls global overlays; no hide/show body command in the registry or body tree menus. Preview hiding is temporary rendering machinery. | Hide an obstructing body without suppressing its features; restore it from the tree; isolate then restore prior states; reflect state through MCP and save/open. [Official Hide and Show Bodies](https://help.solidworks.com/2026/english/SolidWorks/sldworks/HIDD_HIDE_SHOW.htm). |
| P1: Selection filters / Select Other | Absent. `P/smart-selection` is not started; native pick calls return a single hit and no filter/candidate-cycle UI was found. | Choose faces/edges/sketch entities explicitly; list candidates behind the pointer with hover highlight. Hidden selections must not require rotating the whole model. [Filters](https://help.solidworks.com/2026/english/SolidWorks/sldworks/r_selection_filter.htm), [Select Other](https://help.solidworks.com/2024/English/solidworks/sldworks/HIDD_SelectOther_dlg.htm). |
| P1: Extrude only one region | Partial geometry detection, absent region-selection workflow. `PanelSpec` explicitly says all closed regions are used; `7.2/.../contour-selection` not started. | Pick a region in a multi-loop sketch, preview exactly that region, store stable contour intent, and retain it after an unrelated sketch edit. Closed nested holes must remain distinct from independently selectable regions. |

## Face-based sketching: implemented path and remaining pitfalls

`SketchMode.newSketch(onPlaneOrFace:)` already passes a face reference to `sketch.create`,
aligns to the resulting sketch, and enters the line tool. `RibbonSpec.sketchGroups`
selects the chosen face for its primary action and adds an On Selected Face flyout.
`ForgeApp/Ribbon.swift` also offers On Selected Face; `ViewportOverlays` offers a
context Sketch action on macOS. Standard and reference planes have tree actions.
This is **present, verify interaction**, not absent.

The important gaps are discoverability and consistency. `selectedFace` checks only
entity kind, despite its comment saying planar; it can offer sketch-on-face for a
curved surface and defer rejection to the command. There is no guided plane-selection
step after pressing Sketch with no suitable selection; the shared primary action
silently uses Front. Native Win/Linux lack the mac context bar. Clicking Extruded Cut
with a face selected does not start a face sketch and resume the pending feature:
feature buttons are gated by existing sketches. That SOLIDWORKS workflow is documented
in [the lip tutorial](https://help.solidworks.com/2026/english/swtutorialonline/t_tut_lesson2_creatinglip.htm).

Acceptance: create a box, select each of its six planar faces in turn, create a sketch,
place a dimensioned circle, cut through the body, change the parent box thickness,
and save/reopen. Confirm face normal, origin, sketch coordinates, downstream reference
identity and camera orientation. Repeat on a transformed body and an imported solid.
A cylindrical side face should receive an actionable explanation, with no empty sketch
left behind. Full sketch-on-arbitrary-surface and 3D sketching remain separate missing work.

## Sketching: remaining work beyond exposing existing commands

- Geometry: arc slots, parabola/conic, sketch text/fonts, style/fit/equation-driven
  splines, sketch pictures/calibration/autotrace, blocks, derived sketches and full
  3D sketching remain matrix gaps. Existing point/control-point splines are not a
  full surface-design toolset.
- Tools: convert/intersection/silhouette entities, dynamic mirror, stretch, jog,
  repair/fully-define sketch, and spline curvature controls remain absent. Existing
  offset handles line/arc chains and circles, not exact ellipse/spline offsets;
  cap ends are straight. Trim/split lack splines. Sketch patterns place instances
  but their spacing/angle is not an editable driving pattern dimension.
- Constraints: existing 2D solver handles substantial ordinary relations, but
  equal curvature, curve-length equality, 3D axis/plane/surface relations, pierce,
  and external on-edge references need separate work. Spline tangency away from
  endpoints is explicitly not implemented in `Constraints.swift`.
- Dimensions: ordinary linear/radial/diameter/angular and driven values exist;
  ordinate/baseline/chain, arc/path length, min/max arc conditions, unit-aware
  expressions/global variables and auto fully-definition are not completed.
- Repair UX: errors and executable suggestions exist, but a complete conflict
  exploration/repair panel is not equivalent to a transient error banner. Test
  delete/make-driven suggestions and cancellation without creating solver drift.

[Official sketch relations](https://help.solidworks.com/2026/english/solidworks/sldworks/c_Description_of_Sketch_Relations.htm)
define entity-specific semantics; acceptance must measure residuals and degrees of
freedom after drag/edit, not count relation icons.

## Features, editing and navigation

The registry and property pages already expose extrude/revolve, sweep/loft/rib,
fillet/chamfer/shell/draft, holes, patterns/mirror, booleans and reference planes.
History supports suppression, rollback, edit, rename, reorder, parent/child lookup,
and reference repair. These are real starting points, not complete family parity.

Remaining feature variants include up-to-next/surface/body/offset extrusion,
open-profile thin features, revolve direction 2/up-to modes, sweep twist/guide curves/
solid tool, loft guide curves/centerline/tangency/point profiles, curved ribs,
variable/full-round/setback fillets, expanded chamfers/draft/shell variants, full hole
standards/types, surface creation/editing, direct face editing, recognition and
mesh-to-BREP tools. `PatternCommands` restricts feature seeds to extrusions,
revolutions and Hole Wizard holes; exposing Pattern for every body is not evidence
that every feature can be patterned. See the row inventory for all named variants.
[Official extrusion conditions](https://help.solidworks.com/2023/english/solidworks/sldworks/c_end_condition_extrude.htm)
and [features toolbar](https://help.solidworks.com/2026/english/SolidWorks/sldworks/r_Features_Toolbar.htm)
provide behavioral/reference scope.

Editing additionally needs global variables, equations, linked dimensions,
configurations/design tables, folders/freeze, robust vertex naming, full preview
cancellation and topology repair UI, and feature parameter coverage on every shell.
The whole edit pipeline should preserve unknown/unexposed stored parameters or
explicitly refuse editing; reconstructing only visible controls is a corruption risk.

Navigation has fit, previous view, standard orientations, styles, projection,
orbit/pan/zoom, sketch normal and a mac orientation palette. The 2026-10-02 follow-on
adds Zoom to Selection across desktop shells and the typed/MCP command bus, including
explicit subshape bounds and previous-view history. Sketch outlines remain sampled.
The baseline appendix below is historical; FEATURES.md tracks current delivery.
Remaining workflows: rectangle zoom-to-area, custom named views, selected-face normal including reverse,
section clipping/caps, per-entity transparency/display states, selection sets,
3Dconnexion and configurable shortcuts. Reference planes are rendered under a shared
non-document object ID and picks ignore them; use tree selection until meaningful
viewport plane selection is implemented. Keyboard-only/accessibility and large-model
performance require measured tests, not only API hooks.

## Broader product scope: do not conflate neighboring capabilities

| Group | Current audit conclusion | First coherent delivery slice |
|---|---|---|
| Surfacing, sheet metal, weldments, mold/tooling | Families overwhelmingly/not started; solid loft/sweep do not provide surface editing or manufacturable flat patterns. | Valid surface body model; separate bend/flat-pattern and weldment profile/cut-list milestones. |
| Assemblies / motion | No ForgeAssembly target or component/mate command family. Multibody transforms and `query.interference` are not components, mates or motion studies. | Saved instances with stable document references, ground/float, plane/concentric mates, DOF/conflict diagnostics; then subassemblies/interference/motion. [Mate compatibility](https://help.solidworks.com/2022/English/SolidWorks/sldworks/r_Standard_Mates_by_Entity.htm). |
| Drawings / BOM / MBD / tolerance | No ForgeDrawing or associative drawing command family. Raster multiview rendering is not drafting or semantic PMI. | Sheet/scale/model views, projected/section/detail views and associative dimensions; then BOM/balloons, GD&T and export. [Drawing views](https://help.solidworks.com/2026/english/SolidWorks/Sldworks/c_derived_drawing_views.htm), [BOM updates](https://help.solidworks.com/2020/english/SolidWorks/sldworks/c_bill_of_materials_-_overview2.htm). |
| Analysis / FEA / CFD / plastics | Geometry validity, distance, volume/area/centroid and solid interference are implemented subsets. No study/mesh/load/solve/result pipeline or simulation target. | Materials plus calibrated mass/inertia; independent linear-static benchmark with convergence, then additional physics as separate verified studies. |
| Routing / electrical / CAM | No corresponding package target/command pipelines. All enumerated specialized workflows remain future work. | Typed route/component/netlist and manufacturing stock/tool/operation models before user-facing authoring or generated manufacturing output. |
| Rendering | Working viewport/headless rendering is a subset; photoreal, PBR/material authoring, advanced lighting/environment, animations and publishing remain gaps. | Persist appearances and display states, then physically based lighting and independent image-quality/performance fixtures. |
| Data management | Local package persistence/history exists; not vault/check-in/out/revision workflows, permissions or server collaboration. | Explicit file references, recovery/backup and reference-preserving pack-and-go before managed vault workflows. |
| Exchange | STEP solid import plus STEP/STL export and native packages exist. Mixed surface/wire STEP is explicitly rejected; no assembly-instance import model, PMI, native SOLIDWORKS translator or general mesh import. | Round-trip fixtures for supported solid units/topology; separate assembly, surface and PMI support. [Official file support](https://help.solidworks.com/2026/english/SolidWorks/sldworks/c_import_export_file_information.htm). |
| Automation / ease of use | Shared command/MCP/CLI foundation exists; plugins, macro recording, typed inline palette inputs, customization and all-platform discoverability are incomplete. | Shared UI actions over commands, queryable active state, realistic tutorials and end-to-end MCP/UI equivalence fixtures. |

## Inventory discrepancies to reconcile

The matrix should remain conservative, but some notes are stale. Sketch-on-face is
marked not started despite actual planar support. Many sketch rows still say no
feature-tree item although sketches are features. Power trim says no drag-across UI
although `SketchMode` contains trimmed-in-drag handling. Some command descriptions
claim ellipse split/trim and point-on-spline are absent while implementations/matrix
show later work. Counts of golden models and older engine/import capability notes
also predate later changes. Reconcile each with its actual tests; do not bulk-upgrade
statuses from names alone. The appendix deliberately preserves the matrix's reported
status instead of converting these discrepancies into unsupported completion claims.

## Complete matrix coverage at baseline

The following inventory includes every matrix row ID exactly once. Group-level
acceptance is specified above and in [the earlier parity audit](solidworks-parity-audit.md).
For individual ownership, named tests, MCP tool and existing limitations, follow the
same ID in [FEATURES.md](../../FEATURES.md). `not started` means a backlog entry,
`in progress` means partial, `done` is the repository's declared completion status,
and `verified` requires the additional SPEC review criteria. None is a new result
of running tests during this read-only audit.

| Matrix group | Rows | Not started | In progress | Done | Verified |
|---|---:|---:|---:|---:|---:|
| Platform (SPEC §2–§6, §8–§9) | 61 | 13 | 22 | 26 | 0 |
| 7.1 Sketching (2D and 3D) | 120 | 54 | 66 | 0 | 0 |
| 7.2 Part features | 156 | 119 | 36 | 1 | 0 |
| 7.3 Surfacing | 28 | 28 | 0 | 0 | 0 |
| 7.4 Sheet metal | 36 | 36 | 0 | 0 | 0 |
| 7.5 Weldments | 13 | 13 | 0 | 0 | 0 |
| 7.6 Mold / tooling | 11 | 11 | 0 | 0 | 0 |
| 7.7 Assemblies | 102 | 102 | 0 | 0 | 0 |
| 7.8 Motion | 21 | 21 | 0 | 0 | 0 |
| 7.9 Drawings | 96 | 96 | 0 | 0 | 0 |
| 7.10 Model-Based Definition (MBD) | 7 | 7 | 0 | 0 | 0 |
| 7.11 Tolerance & quality | 11 | 11 | 0 | 0 | 0 |
| 7.12 Analysis tools (in-part) | 33 | 29 | 3 | 1 | 0 |
| 7.13 Simulation (FEA) | 86 | 86 | 0 | 0 | 0 |
| 7.14 Flow Simulation (CFD) | 34 | 34 | 0 | 0 | 0 |
| 7.15 Plastics | 12 | 12 | 0 | 0 | 0 |
| 7.16 Routing & electrical | 36 | 36 | 0 | 0 | 0 |
| 7.17 Rendering & visualization | 28 | 28 | 0 | 0 | 0 |
| 7.18 CAM | 26 | 26 | 0 | 0 | 0 |
| 7.19 Data management | 26 | 26 | 0 | 0 | 0 |
| 7.20 Import / export | 36 | 34 | 2 | 0 | 0 |
| 7.21 Customization & automation | 13 | 11 | 2 | 0 | 0 |
| Discovered (SolidWorks capabilities not listed in SPEC §7) | 8 | 8 | 0 | 0 | 0 |
| **Total** | **1000** | **841** | **131** | **28** | **0** |

### Platform (SPEC §2–§6, §8–§9)

| Matrix ID | Recorded status |
|---|---|
| `P/kernel-bridge` | done |
| `P/kernel-primitives` | done |
| `P/kernel-booleans` | done |
| `P/kernel-queries` | done |
| `P/kernel-tessellation` | done |
| `P/kernel-brep-io` | done |
| `P/command-bus` | done |
| `P/command-schema` | done |
| `P/units` | done |
| `P/structured-errors` | done |
| `P/undo-redo` | done |
| `P/transactions` | done |
| `P/dry-run` | done |
| `P/batch` | done |
| `P/explicit-state` | in progress |
| `P/journal` | in progress |
| `P/forge-cli` | done |
| `P/golden-models` | in progress |
| `P/determinism` | in progress |
| `P/mcp-stdio` | done |
| `P/mcp-socket` | done |
| `P/mcp-discovery` | done |
| `P/mcp-document` | done |
| `P/mcp-open-save` | in progress |
| `P/mcp-export` | done |
| `P/mcp-mutate` | done |
| `P/mcp-feature-tools` | in progress |
| `P/mcp-query-geometry` | not started |
| `P/mcp-vision` | in progress |
| `P/mcp-verification` | in progress |
| `P/mcp-interference` | done |
| `P/mcp-resources` | in progress |
| `P/mcp-prompts` | in progress |
| `P/plugins-swift` | not started |
| `P/scripting-js` | not started |
| `P/scripting-python` | not started |
| `P/macro-recorder` | not started |
| `P/feature-tree` | in progress |
| `P/persistent-naming` | in progress |
| `P/semantic-refs` | not started |
| `P/parameters` | not started |
| `P/file-format` | in progress |
| `P/background-regen` | in progress |
| `P/metal-viewport` | in progress |
| `P/headless-render` | done |
| `P/app-shell` | in progress |
| `P/app-model-shared` | done |
| `P/windows-app` | in progress |
| `P/windows-engine` | done |
| `P/linux-app` | in progress |
| `P/linux-install` | done |
| `P/command-palette` | in progress |
| `P/inspector` | in progress |
| `P/handles` | not started |
| `P/explainable-failures` | not started |
| `P/smart-selection` | not started |
| `P/input-devices` | in progress |
| `P/accessibility` | not started |
| `P/performance` | not started |
| `P/ci` | in progress |
| `P/fuzzing` | not started |

### 7.1 Sketching (2D and 3D)

| Matrix ID | Recorded status |
|---|---|
| `7.1/entities/line` | in progress |
| `7.1/entities/centerline` | in progress |
| `7.1/entities/midpoint-line` | in progress |
| `7.1/entities/rectangle` | in progress |
| `7.1/entities/rectangle/corner` | in progress |
| `7.1/entities/rectangle/center` | in progress |
| `7.1/entities/rectangle/3-point` | in progress |
| `7.1/entities/rectangle/parallelogram` | in progress |
| `7.1/entities/slot` | in progress |
| `7.1/entities/slot/straight` | in progress |
| `7.1/entities/slot/center` | in progress |
| `7.1/entities/slot/arc` | not started |
| `7.1/entities/slot/3-point-arc` | not started |
| `7.1/entities/circle` | in progress |
| `7.1/entities/circle/center` | in progress |
| `7.1/entities/circle/perimeter` | in progress |
| `7.1/entities/arc` | in progress |
| `7.1/entities/arc/center` | in progress |
| `7.1/entities/arc/tangent` | in progress |
| `7.1/entities/arc/3-point` | in progress |
| `7.1/entities/polygon` | in progress |
| `7.1/entities/ellipse` | in progress |
| `7.1/entities/partial-ellipse` | in progress |
| `7.1/entities/parabola` | not started |
| `7.1/entities/conic` | not started |
| `7.1/entities/spline` | in progress |
| `7.1/entities/spline/point-control-vertex` | in progress |
| `7.1/entities/spline/style-spline` | not started |
| `7.1/entities/spline/equation-driven-curve` | not started |
| `7.1/entities/spline/fit-spline` | not started |
| `7.1/entities/point` | in progress |
| `7.1/entities/text` | not started |
| `7.1/entities/text/with-fonts` | not started |
| `7.1/entities/construction-geometry` | in progress |
| `7.1/entities/fillet-chamfer` | in progress |
| `7.1/entities/fillet-chamfer/sketch` | in progress |
| `7.1/tools/trim` | in progress |
| `7.1/tools/trim/power` | in progress |
| `7.1/tools/trim/corner` | not started |
| `7.1/tools/trim/inside-outside` | not started |
| `7.1/tools/extend` | in progress |
| `7.1/tools/offset` | in progress |
| `7.1/tools/offset/bi-directional` | in progress |
| `7.1/tools/offset/cap-ends` | in progress |
| `7.1/tools/offset/construction` | in progress |
| `7.1/tools/convert-entities` | not started |
| `7.1/tools/intersection-curve` | not started |
| `7.1/tools/silhouette-entities` | not started |
| `7.1/tools/mirror` | in progress |
| `7.1/tools/mirror/static-dynamic` | in progress |
| `7.1/tools/linear-circular-sketch-patterns` | in progress |
| `7.1/tools/move-copy-rotate-scale-stretch` | in progress |
| `7.1/tools/split-entities` | in progress |
| `7.1/tools/jog-line` | not started |
| `7.1/tools/sketch-picture` | not started |
| `7.1/tools/sketch-picture/with-scale-calibration` | not started |
| `7.1/tools/autotrace` | not started |
| `7.1/tools/sketch-blocks` | not started |
| `7.1/tools/sketch-blocks/create` | not started |
| `7.1/tools/sketch-blocks/insert` | not started |
| `7.1/tools/sketch-blocks/edit` | not started |
| `7.1/tools/sketch-blocks/explode` | not started |
| `7.1/tools/sketch-blocks/belts-chains` | not started |
| `7.1/tools/derived-sketch` | not started |
| `7.1/tools/shared-sketches` | not started |
| `7.1/tools/3d-sketch` | not started |
| `7.1/tools/3d-sketch/with-plane-switching` | not started |
| `7.1/tools/3d-sketch/3d-sketch-on-plane` | not started |
| `7.1/tools/sketch-on-face-surface` | not started |
| `7.1/tools/spline-tools` | not started |
| `7.1/tools/spline-tools/tangency-curvature-handles` | not started |
| `7.1/tools/spline-tools/simplify` | not started |
| `7.1/tools/spline-tools/fit` | not started |
| `7.1/tools/spline-tools/add-tangency-control` | not started |
| `7.1/tools/spline-tools/curvature-combs` | not started |
| `7.1/tools/instant2d` | not started |
| `7.1/tools/sketchxpert` | in progress |
| `7.1/tools/sketchxpert/conflict-repair` | in progress |
| `7.1/tools/check-sketch-for-feature` | in progress |
| `7.1/tools/repair-sketch` | not started |
| `7.1/tools/sketch-contours-regions-selection` | in progress |
| `7.1/tools/sketch-ink-equivalent` | not started |
| `7.1/tools/sketch-ink-equivalent/pencil` | not started |
| `7.1/relations/coincident` | in progress |
| `7.1/relations/collinear` | in progress |
| `7.1/relations/coradial` | in progress |
| `7.1/relations/concentric` | in progress |
| `7.1/relations/horizontal` | in progress |
| `7.1/relations/vertical` | in progress |
| `7.1/relations/parallel` | in progress |
| `7.1/relations/perpendicular` | in progress |
| `7.1/relations/tangent` | in progress |
| `7.1/relations/equal` | in progress |
| `7.1/relations/symmetric` | in progress |
| `7.1/relations/midpoint` | in progress |
| `7.1/relations/fix` | in progress |
| `7.1/relations/merge` | in progress |
| `7.1/relations/pierce` | not started |
| `7.1/relations/intersection` | not started |
| `7.1/relations/along-x-y-z` | not started |
| `7.1/relations/along-x-y-z/3d` | not started |
| `7.1/relations/equal-curvature` | not started |
| `7.1/relations/on-edge` | in progress |
| `7.1/relations/curve-length-equal` | not started |
| `7.1/relations/automatic-relations-with-inference` | in progress |
| `7.1/relations/display-delete-relations` | in progress |
| `7.1/dimensions/smart-dimension` | in progress |
| `7.1/dimensions/smart-dimension/linear` | in progress |
| `7.1/dimensions/smart-dimension/angular` | in progress |
| `7.1/dimensions/smart-dimension/radial` | in progress |
| `7.1/dimensions/smart-dimension/diameter` | in progress |
| `7.1/dimensions/smart-dimension/arc-length` | not started |
| `7.1/dimensions/smart-dimension/path-length` | not started |
| `7.1/dimensions/driven-reference` | in progress |
| `7.1/dimensions/ordinate` | not started |
| `7.1/dimensions/chain` | not started |
| `7.1/dimensions/baseline` | not started |
| `7.1/dimensions/fully-define-sketch` | not started |
| `7.1/dimensions/dimension-to-min-max-arc-condition` | not started |
| `7.1/dimensions/equations-in-dimension-fields` | not started |

### 7.2 Part features

| Matrix ID | Recorded status |
|---|---|
| `7.2/reference-geometry/planes` | in progress |
| `7.2/reference-geometry/planes/all-definitions` | not started |
| `7.2/reference-geometry/axes` | not started |
| `7.2/reference-geometry/coordinate-systems` | not started |
| `7.2/reference-geometry/points` | not started |
| `7.2/reference-geometry/center-of-mass` | not started |
| `7.2/reference-geometry/mate-references` | not started |
| `7.2/reference-geometry/bounding-box` | not started |
| `7.2/reference-geometry/reference-curves` | not started |
| `7.2/reference-geometry/reference-curves/projected` | not started |
| `7.2/reference-geometry/reference-curves/helix-spiral` | not started |
| `7.2/reference-geometry/reference-curves/composite` | not started |
| `7.2/reference-geometry/reference-curves/split-line` | not started |
| `7.2/reference-geometry/reference-curves/curve-through-xyz-points` | not started |
| `7.2/reference-geometry/reference-curves/curve-through-reference-points` | not started |
| `7.2/boss-base-and-cut/extrude` | in progress |
| `7.2/boss-base-and-cut/extrude/blind` | in progress |
| `7.2/boss-base-and-cut/extrude/through-all` | in progress |
| `7.2/boss-base-and-cut/extrude/up-to-next-vertex-surface-offset` | in progress |
| `7.2/boss-base-and-cut/extrude/mid-plane` | in progress |
| `7.2/boss-base-and-cut/extrude/thin-feature` | in progress |
| `7.2/boss-base-and-cut/extrude/draft` | in progress |
| `7.2/boss-base-and-cut/extrude/direction-2` | in progress |
| `7.2/boss-base-and-cut/extrude/contour-selection` | not started |
| `7.2/boss-base-and-cut/revolve` | in progress |
| `7.2/boss-base-and-cut/sweep` | in progress |
| `7.2/boss-base-and-cut/sweep/profile` | done |
| `7.2/boss-base-and-cut/sweep/solid-body-tool-sweep` | not started |
| `7.2/boss-base-and-cut/sweep/twist` | not started |
| `7.2/boss-base-and-cut/sweep/guide-curves` | not started |
| `7.2/boss-base-and-cut/sweep/path-alignment` | in progress |
| `7.2/boss-base-and-cut/loft` | in progress |
| `7.2/boss-base-and-cut/loft/guide-curves` | not started |
| `7.2/boss-base-and-cut/loft/centerline` | not started |
| `7.2/boss-base-and-cut/loft/start-end-constraints` | not started |
| `7.2/boss-base-and-cut/loft/tangency` | not started |
| `7.2/boss-base-and-cut/boundary-boss-cut` | not started |
| `7.2/boss-base-and-cut/thicken-thicken-cut` | not started |
| `7.2/boss-base-and-cut/cut-with-surface` | not started |
| `7.2/applied/fillet` | in progress |
| `7.2/applied/fillet/constant` | in progress |
| `7.2/applied/fillet/variable` | not started |
| `7.2/applied/fillet/face` | not started |
| `7.2/applied/fillet/full-round` | not started |
| `7.2/applied/fillet/setback` | not started |
| `7.2/applied/fillet/filletxpert` | not started |
| `7.2/applied/fillet/conic-curvature-continuous-profiles` | not started |
| `7.2/applied/chamfer` | in progress |
| `7.2/applied/chamfer/angle-distance` | in progress |
| `7.2/applied/chamfer/distance-distance` | in progress |
| `7.2/applied/chamfer/vertex` | not started |
| `7.2/applied/chamfer/offset-face` | not started |
| `7.2/applied/chamfer/face-face` | not started |
| `7.2/applied/draft` | in progress |
| `7.2/applied/draft/neutral-plane` | in progress |
| `7.2/applied/draft/parting-line` | not started |
| `7.2/applied/draft/step` | not started |
| `7.2/applied/draft/draftxpert` | not started |
| `7.2/applied/shell` | in progress |
| `7.2/applied/shell/multi-thickness` | not started |
| `7.2/applied/rib` | in progress |
| `7.2/applied/hole-wizard` | in progress |
| `7.2/applied/hole-wizard/counterbore` | in progress |
| `7.2/applied/hole-wizard/countersink` | in progress |
| `7.2/applied/hole-wizard/straight` | in progress |
| `7.2/applied/hole-wizard/tapped` | in progress |
| `7.2/applied/hole-wizard/pipe-tap` | not started |
| `7.2/applied/hole-wizard/legacy` | not started |
| `7.2/applied/hole-wizard/slot` | not started |
| `7.2/applied/hole-wizard/counterbore-countersink-slot` | not started |
| `7.2/applied/hole-wizard/ansi` | not started |
| `7.2/applied/hole-wizard/iso` | in progress |
| `7.2/applied/hole-wizard/din` | not started |
| `7.2/applied/hole-wizard/jis` | not started |
| `7.2/applied/hole-wizard/gb` | not started |
| `7.2/applied/hole-wizard/bsi` | not started |
| `7.2/applied/hole-wizard/ks` | not started |
| `7.2/applied/hole-wizard/as` | not started |
| `7.2/applied/hole-wizard/is` | not started |
| `7.2/applied/hole-wizard/pem-etc` | not started |
| `7.2/applied/advanced-hole` | not started |
| `7.2/applied/cosmetic-thread` | not started |
| `7.2/applied/thread-feature` | not started |
| `7.2/applied/stud-wizard` | not started |
| `7.2/applied/dome` | not started |
| `7.2/applied/wrap` | not started |
| `7.2/applied/wrap/emboss` | not started |
| `7.2/applied/wrap/deboss` | not started |
| `7.2/applied/wrap/scribe` | not started |
| `7.2/applied/indent` | not started |
| `7.2/applied/flex` | not started |
| `7.2/applied/flex/bend` | not started |
| `7.2/applied/flex/twist` | not started |
| `7.2/applied/flex/taper` | not started |
| `7.2/applied/flex/stretch` | not started |
| `7.2/applied/deform` | not started |
| `7.2/applied/intersect` | not started |
| `7.2/applied/freeform` | not started |
| `7.2/applied/lip-groove` | not started |
| `7.2/applied/mounting-boss` | not started |
| `7.2/applied/snap-hook-groove` | not started |
| `7.2/applied/vent` | not started |
| `7.2/applied/fastening-features` | not started |
| `7.2/patterns-and-mirror/linear` | in progress |
| `7.2/patterns-and-mirror/circular` | in progress |
| `7.2/patterns-and-mirror/curve-driven` | not started |
| `7.2/patterns-and-mirror/sketch-driven` | not started |
| `7.2/patterns-and-mirror/table-driven` | not started |
| `7.2/patterns-and-mirror/fill-pattern` | not started |
| `7.2/patterns-and-mirror/variable-pattern` | not started |
| `7.2/patterns-and-mirror/chain-pattern` | not started |
| `7.2/patterns-and-mirror/mirror` | in progress |
| `7.2/patterns-and-mirror/mirror/features` | in progress |
| `7.2/patterns-and-mirror/mirror/faces` | not started |
| `7.2/patterns-and-mirror/mirror/bodies` | not started |
| `7.2/patterns-and-mirror/geometry-pattern` | not started |
| `7.2/patterns-and-mirror/instance-skipping-varying` | not started |
| `7.2/multibody/combine` | in progress |
| `7.2/multibody/combine/add-subtract-common` | in progress |
| `7.2/multibody/split` | not started |
| `7.2/multibody/move-copy-body` | in progress |
| `7.2/multibody/delete-keep-body` | in progress |
| `7.2/multibody/insert-part` | not started |
| `7.2/multibody/insert-into-new-part` | not started |
| `7.2/multibody/save-bodies` | not started |
| `7.2/multibody/body-folders` | not started |
| `7.2/multibody/cut-list` | not started |
| `7.2/direct-editing/move-rotate-offset-replace-delete-face` | not started |
| `7.2/direct-editing/delete-hole` | not started |
| `7.2/direct-editing/simplify-defeature` | not started |
| `7.2/direct-editing/instant3d` | not started |
| `7.2/direct-editing/import-diagnostics-and-healing` | not started |
| `7.2/direct-editing/featureworks` | not started |
| `7.2/direct-editing/featureworks/feature-recognition-on-imported-bodies` | not started |
| `7.2/scale` | not started |
| `7.2/fillet-aware-undo` | not started |
| `7.2/library-features` | not started |
| `7.2/design-library` | not started |
| `7.2/smart-features` | not started |
| `7.2/forming-tools` | not started |
| `7.2/cosmetic-patterns` | not started |
| `7.2/decals` | not started |
| `7.2/appearances` | not started |
| `7.2/materials-database` | not started |
| `7.2/materials-database/with-custom-materials` | not started |
| `7.2/sensors` | not started |
| `7.2/feature-freeze` | not started |
| `7.2/feature-statistics` | not started |
| `7.2/performance-evaluation` | not started |
| `7.2/mesh-brep/import-mesh` | not started |
| `7.2/mesh-brep/import-mesh/stl-obj-3mf` | not started |
| `7.2/mesh-brep/mesh-bodies` | not started |
| `7.2/mesh-brep/convert-mesh-to-body` | not started |
| `7.2/mesh-brep/graphics-bodies` | not started |
| `7.2/mesh-brep/segment-mesh` | not started |
| `7.2/mesh-brep/3d-texture` | not started |

### 7.3 Surfacing

| Matrix ID | Recorded status |
|---|---|
| `7.3/extruded` | not started |
| `7.3/revolved` | not started |
| `7.3/swept` | not started |
| `7.3/lofted` | not started |
| `7.3/boundary` | not started |
| `7.3/planar` | not started |
| `7.3/fill` | not started |
| `7.3/fill/with-constraints-curvature` | not started |
| `7.3/freeform` | not started |
| `7.3/offset` | not started |
| `7.3/ruled` | not started |
| `7.3/radiated` | not started |
| `7.3/knit` | not started |
| `7.3/knit/with-gap-control` | not started |
| `7.3/untrim` | not started |
| `7.3/extend` | not started |
| `7.3/trim` | not started |
| `7.3/trim/standard-mutual` | not started |
| `7.3/delete-face-hole` | not started |
| `7.3/replace-face` | not started |
| `7.3/thicken` | not started |
| `7.3/surface-flatten` | not started |
| `7.3/mid-surface` | not started |
| `7.3/face-curves` | not started |
| `7.3/parting-surface` | not started |
| `7.3/shut-off-surface` | not started |
| `7.3/sew-heal` | not started |
| `7.3/curvature-continuity-checks` | not started |

### 7.4 Sheet metal

| Matrix ID | Recorded status |
|---|---|
| `7.4/base-flange-tab` | not started |
| `7.4/edge-flange` | not started |
| `7.4/edge-flange/all-positions` | not started |
| `7.4/edge-flange/custom-profile` | not started |
| `7.4/miter-flange` | not started |
| `7.4/hem` | not started |
| `7.4/hem/all-types` | not started |
| `7.4/jog` | not started |
| `7.4/sketched-bend` | not started |
| `7.4/cross-break` | not started |
| `7.4/closed-corner` | not started |
| `7.4/welded-corner` | not started |
| `7.4/break-relief-corner` | not started |
| `7.4/break-relief-corner/all-relief-types` | not started |
| `7.4/corner-trim` | not started |
| `7.4/forming-tools` | not started |
| `7.4/forming-tools/and-custom-forming-tools` | not started |
| `7.4/vent` | not started |
| `7.4/lofted-bend` | not started |
| `7.4/lofted-bend/formed-and-bent` | not started |
| `7.4/swept-flange` | not started |
| `7.4/convert-to-sheet-metal` | not started |
| `7.4/insert-bends-rip` | not started |
| `7.4/flatten-unfold-fold` | not started |
| `7.4/flat-pattern` | not started |
| `7.4/flat-pattern/with-bend-lines` | not started |
| `7.4/flat-pattern/bend-notes` | not started |
| `7.4/flat-pattern/grain-direction` | not started |
| `7.4/flat-pattern/flat-pattern-export-to-dxf-dwg` | not started |
| `7.4/gauge-tables` | not started |
| `7.4/bend-tables` | not started |
| `7.4/k-factor-bend-allowance-bend-deduction` | not started |
| `7.4/tab-and-slot` | not started |
| `7.4/normal-cut` | not started |
| `7.4/multibody-sheet-metal` | not started |
| `7.4/sheet-metal-cut-list-properties` | not started |

### 7.5 Weldments

| Matrix ID | Recorded status |
|---|---|
| `7.5/structural-member` | not started |
| `7.5/structural-member/ansi-iso` | not started |
| `7.5/structural-member/custom-profiles` | not started |
| `7.5/structural-member/corner-treatments` | not started |
| `7.5/structural-member/trim-extend` | not started |
| `7.5/structural-member/groups` | not started |
| `7.5/end-caps` | not started |
| `7.5/gussets` | not started |
| `7.5/fillet-beads` | not started |
| `7.5/weld-beads` | not started |
| `7.5/cut-lists-with-properties` | not started |
| `7.5/weldment-drawings-cut-list-tables` | not started |
| `7.5/3d-sketch-driven-frames` | not started |

### 7.6 Mold / tooling

| Matrix ID | Recorded status |
|---|---|
| `7.6/draft-analysis` | not started |
| `7.6/undercut-analysis` | not started |
| `7.6/parting-lines` | not started |
| `7.6/shut-off-surfaces` | not started |
| `7.6/parting-surfaces` | not started |
| `7.6/tooling-split` | not started |
| `7.6/core-cavity` | not started |
| `7.6/core-pins` | not started |
| `7.6/scale-for-shrinkage` | not started |
| `7.6/ruled-surface-for-molds` | not started |
| `7.6/mold-base-integration` | not started |

### 7.7 Assemblies

| Matrix ID | Recorded status |
|---|---|
| `7.7/top-down-and-bottom-up-design` | not started |
| `7.7/insert-components` | not started |
| `7.7/virtual-components` | not started |
| `7.7/subassemblies` | not started |
| `7.7/subassemblies/rigid-flexible` | not started |
| `7.7/component-patterns` | not started |
| `7.7/component-patterns/linear` | not started |
| `7.7/component-patterns/circular` | not started |
| `7.7/component-patterns/pattern-driven` | not started |
| `7.7/component-patterns/sketch-driven` | not started |
| `7.7/component-patterns/curve-driven` | not started |
| `7.7/component-patterns/chain` | not started |
| `7.7/mirror-components` | not started |
| `7.7/mirror-components/opposite-hand` | not started |
| `7.7/smart-components` | not started |
| `7.7/smart-fasteners` | not started |
| `7.7/toolbox` | not started |
| `7.7/toolbox/bolts` | not started |
| `7.7/toolbox/screws` | not started |
| `7.7/toolbox/nuts` | not started |
| `7.7/toolbox/washers` | not started |
| `7.7/toolbox/pins` | not started |
| `7.7/toolbox/bearings` | not started |
| `7.7/toolbox/gears` | not started |
| `7.7/toolbox/cams` | not started |
| `7.7/toolbox/pulleys` | not started |
| `7.7/toolbox/sprockets` | not started |
| `7.7/toolbox/structural-steel` | not started |
| `7.7/toolbox/o-rings` | not started |
| `7.7/toolbox/keyways` | not started |
| `7.7/mates/standard` | not started |
| `7.7/mates/standard/coincident` | not started |
| `7.7/mates/standard/parallel` | not started |
| `7.7/mates/standard/perpendicular` | not started |
| `7.7/mates/standard/tangent` | not started |
| `7.7/mates/standard/concentric` | not started |
| `7.7/mates/standard/lock` | not started |
| `7.7/mates/standard/distance` | not started |
| `7.7/mates/standard/angle` | not started |
| `7.7/mates/advanced` | not started |
| `7.7/mates/advanced/profile-center` | not started |
| `7.7/mates/advanced/symmetric` | not started |
| `7.7/mates/advanced/width` | not started |
| `7.7/mates/advanced/path` | not started |
| `7.7/mates/advanced/linear-linear-coupler` | not started |
| `7.7/mates/advanced/limit-distance-angle` | not started |
| `7.7/mates/mechanical` | not started |
| `7.7/mates/mechanical/cam` | not started |
| `7.7/mates/mechanical/slot` | not started |
| `7.7/mates/mechanical/hinge` | not started |
| `7.7/mates/mechanical/gear` | not started |
| `7.7/mates/mechanical/rack-and-pinion` | not started |
| `7.7/mates/mechanical/screw` | not started |
| `7.7/mates/mechanical/universal-joint` | not started |
| `7.7/mates/mate-references` | not started |
| `7.7/mates/smartmates` | not started |
| `7.7/mates/quick-mates` | not started |
| `7.7/mates/matexpert-mate-diagnostics` | not started |
| `7.7/mates/mate-folders` | not started |
| `7.7/mates/mate-controller` | not started |
| `7.7/mates/copy-with-mates` | not started |
| `7.7/tools/move-rotate-component` | not started |
| `7.7/tools/move-rotate-component/with-collision-detection` | not started |
| `7.7/tools/move-rotate-component/dynamic-clearance` | not started |
| `7.7/tools/move-rotate-component/physical-dynamics` | not started |
| `7.7/tools/interference-detection` | not started |
| `7.7/tools/clearance-verification` | not started |
| `7.7/tools/hole-alignment` | not started |
| `7.7/tools/assembly-visualization` | not started |
| `7.7/tools/assemblyxpert` | not started |
| `7.7/tools/exploded-views` | not started |
| `7.7/tools/exploded-views/with-explode-lines` | not started |
| `7.7/tools/exploded-views/radial-regular-steps` | not started |
| `7.7/tools/exploded-views/animation` | not started |
| `7.7/tools/section-views` | not started |
| `7.7/tools/configurations` | not started |
| `7.7/tools/display-states` | not started |
| `7.7/tools/large-assembly-mode` | not started |
| `7.7/tools/large-design-review` | not started |
| `7.7/tools/lightweight-components` | not started |
| `7.7/tools/speedpak` | not started |
| `7.7/tools/defeature` | not started |
| `7.7/tools/envelopes` | not started |
| `7.7/tools/treehouse` | not started |
| `7.7/tools/treehouse/structure-planning` | not started |
| `7.7/tools/assembly-features` | not started |
| `7.7/tools/assembly-features/cuts` | not started |
| `7.7/tools/assembly-features/holes` | not started |
| `7.7/tools/assembly-features/weld-beads` | not started |
| `7.7/tools/in-context-references` | not started |
| `7.7/tools/in-context-references/external-reference-management` | not started |
| `7.7/tools/in-context-references/lock-break` | not started |
| `7.7/tools/replace-components` | not started |
| `7.7/tools/pack-and-go` | not started |
| `7.7/tools/magnetic-mates-asset-publisher` | not started |
| `7.7/tools/belts-chains` | not started |
| `7.7/tools/structure-system` | not started |
| `7.7/tools/assembly-layout-sketches` | not started |
| `7.7/tools/bom-in-assembly` | not started |
| `7.7/tools/isolate` | not started |
| `7.7/tools/component-preview` | not started |
| `7.7/tools/envelope-publisher` | not started |

### 7.8 Motion

| Matrix ID | Recorded status |
|---|---|
| `7.8/animation` | not started |
| `7.8/animation/keyframe-timeline` | not started |
| `7.8/animation/camera-animation` | not started |
| `7.8/animation/walk-through` | not started |
| `7.8/basic-motion` | not started |
| `7.8/basic-motion/motors` | not started |
| `7.8/basic-motion/springs` | not started |
| `7.8/basic-motion/contact` | not started |
| `7.8/basic-motion/gravity` | not started |
| `7.8/motion-analysis` | not started |
| `7.8/motion-analysis/forces` | not started |
| `7.8/motion-analysis/dampers` | not started |
| `7.8/motion-analysis/bushings` | not started |
| `7.8/motion-analysis/3d-contact` | not started |
| `7.8/motion-analysis/friction` | not started |
| `7.8/motion-analysis/results-and-plots` | not started |
| `7.8/motion-analysis/export-loads-to-fea` | not started |
| `7.8/motion-optimization` | not started |
| `7.8/event-based-motion` | not started |
| `7.8/interference-during-motion` | not started |
| `7.8/trace-paths` | not started |

### 7.9 Drawings

| Matrix ID | Recorded status |
|---|---|
| `7.9/sheets-and-formats` | not started |
| `7.9/sheets-and-formats/all-ansi-iso-din-jis-gb-templates` | not started |
| `7.9/sheets-and-formats/editable-title-blocks-with-property-links` | not started |
| `7.9/sheets-and-formats/multiple-sheets` | not started |
| `7.9/sheets-and-formats/sheet-scaling` | not started |
| `7.9/drafting-standards-editor` | not started |
| `7.9/views/standard-3-view` | not started |
| `7.9/views/model-view` | not started |
| `7.9/views/projected` | not started |
| `7.9/views/auxiliary` | not started |
| `7.9/views/section` | not started |
| `7.9/views/section/with-section-view-assist` | not started |
| `7.9/views/section/aligned` | not started |
| `7.9/views/section/half` | not started |
| `7.9/views/section/offset` | not started |
| `7.9/views/section/partial` | not started |
| `7.9/views/detail` | not started |
| `7.9/views/detail/circular-profile` | not started |
| `7.9/views/broken-out-section` | not started |
| `7.9/views/break` | not started |
| `7.9/views/crop` | not started |
| `7.9/views/alternate-position` | not started |
| `7.9/views/relative-to-model` | not started |
| `7.9/views/3d-drawing-view` | not started |
| `7.9/views/flat-pattern-views` | not started |
| `7.9/views/exploded-views` | not started |
| `7.9/views/empty-views` | not started |
| `7.9/views/view-palette` | not started |
| `7.9/views/rotate-views` | not started |
| `7.9/views/hlr-hlv` | not started |
| `7.9/views/tangent-edge-options` | not started |
| `7.9/views/shaded-wireframe` | not started |
| `7.9/views/isometric` | not started |
| `7.9/views/live-section` | not started |
| `7.9/annotations/model-items-import` | not started |
| `7.9/annotations/smart-dimension` | not started |
| `7.9/annotations/smart-dimension/all-types-incl-ordinate` | not started |
| `7.9/annotations/smart-dimension/chamfer` | not started |
| `7.9/annotations/smart-dimension/baseline` | not started |
| `7.9/annotations/smart-dimension/chain` | not started |
| `7.9/annotations/smart-dimension/angular-running` | not started |
| `7.9/annotations/dimxpert-for-drawings` | not started |
| `7.9/annotations/notes` | not started |
| `7.9/annotations/notes/linked-properties` | not started |
| `7.9/annotations/notes/hyperlinks` | not started |
| `7.9/annotations/notes/balloons-in-notes` | not started |
| `7.9/annotations/balloons` | not started |
| `7.9/annotations/balloons/auto-balloon` | not started |
| `7.9/annotations/balloons/stacked` | not started |
| `7.9/annotations/surface-finish` | not started |
| `7.9/annotations/weld-symbols` | not started |
| `7.9/annotations/weld-symbols/ansi-iso` | not started |
| `7.9/annotations/gdandt` | not started |
| `7.9/annotations/gdandt/feature-control-frames` | not started |
| `7.9/annotations/gdandt/datums` | not started |
| `7.9/annotations/gdandt/datum-targets` | not started |
| `7.9/annotations/gdandt/composite-frames` | not started |
| `7.9/annotations/center-marks` | not started |
| `7.9/annotations/centerlines` | not started |
| `7.9/annotations/cosmetic-threads` | not started |
| `7.9/annotations/hole-callouts` | not started |
| `7.9/annotations/revision-clouds` | not started |
| `7.9/annotations/area-hatch-fill` | not started |
| `7.9/annotations/blocks` | not started |
| `7.9/annotations/magnetic-lines` | not started |
| `7.9/annotations/layers` | not started |
| `7.9/annotations/dimension-tolerance-display` | not started |
| `7.9/annotations/dimension-tolerance-display/all-types` | not started |
| `7.9/annotations/dimension-tolerance-display/fits` | not started |
| `7.9/annotations/dimension-tolerance-display/tables` | not started |
| `7.9/tables/bom` | not started |
| `7.9/tables/bom/top-level` | not started |
| `7.9/tables/bom/parts-only` | not started |
| `7.9/tables/bom/indented` | not started |
| `7.9/tables/bom/weldment-cut-list` | not started |
| `7.9/tables/bom/with-custom-columns-and-equations` | not started |
| `7.9/tables/hole-table` | not started |
| `7.9/tables/revision-table` | not started |
| `7.9/tables/general-table` | not started |
| `7.9/tables/bend-table` | not started |
| `7.9/tables/punch-table` | not started |
| `7.9/tables/weld-table` | not started |
| `7.9/tables/design-table` | not started |
| `7.9/tables/title-block-table` | not started |
| `7.9/tables/general-table-templates` | not started |
| `7.9/drawing-tools/auto-arrange-dimensions` | not started |
| `7.9/drawing-tools/dimension-palette` | not started |
| `7.9/drawing-tools/format-painter` | not started |
| `7.9/drawing-tools/sketch-in-drawing` | not started |
| `7.9/drawing-tools/design-checker` | not started |
| `7.9/drawing-tools/drawing-compare` | not started |
| `7.9/drawing-tools/detailing-mode` | not started |
| `7.9/drawing-tools/dwg-dxf-editing-parity-basics` | not started |
| `7.9/drawing-tools/print-plot` | not started |
| `7.9/drawing-tools/print-plot/with-pen-tables` | not started |
| `7.9/drawing-tools/pdf-with-layers-3d-pdf` | not started |

### 7.10 Model-Based Definition (MBD)

| Matrix ID | Recorded status |
|---|---|
| `7.10/dimxpert` | not started |
| `7.10/3d-annotations` | not started |
| `7.10/3d-pmi-views` | not started |
| `7.10/annotation-views` | not started |
| `7.10/3d-pdf-publishing` | not started |
| `7.10/step-ap242-pmi-export` | not started |
| `7.10/tolerance-status-display` | not started |

### 7.11 Tolerance & quality

| Matrix ID | Recorded status |
|---|---|
| `7.11/tolanalyst` | not started |
| `7.11/tolanalyst/tolerance-stack-up` | not started |
| `7.11/tolanalyst/worst-case-rss` | not started |
| `7.11/inspection` | not started |
| `7.11/inspection/ballooning` | not started |
| `7.11/inspection/inspection-reports-from-drawings-and-3d` | not started |
| `7.11/inspection/cmm-data-import` | not started |
| `7.11/design-checker` | not started |
| `7.11/design-checker/standards-compliance` | not started |
| `7.11/compare-documents-features-geometry-boms` | not started |
| `7.11/equations-diagnostics` | not started |

### 7.12 Analysis tools (in-part)

| Matrix ID | Recorded status |
|---|---|
| `7.12/measure` | in progress |
| `7.12/measure/all-modes` | not started |
| `7.12/measure/point-to-point` | not started |
| `7.12/measure/min-max-normal` | not started |
| `7.12/measure/projected` | not started |
| `7.12/mass-properties` | in progress |
| `7.12/mass-properties/with-overrides` | not started |
| `7.12/mass-properties/per-config` | not started |
| `7.12/section-properties` | not started |
| `7.12/geometry-check` | in progress |
| `7.12/draft-analysis` | not started |
| `7.12/undercut-analysis` | not started |
| `7.12/thickness-analysis` | not started |
| `7.12/curvature-display` | not started |
| `7.12/zebra-stripes` | not started |
| `7.12/deviation-analysis` | not started |
| `7.12/parting-line-analysis` | not started |
| `7.12/symmetry-check` | not started |
| `7.12/interference-check-between-bodies` | done |
| `7.12/dfmxpress` | not started |
| `7.12/dfmxpress/manufacturability-rules` | not started |
| `7.12/costing` | not started |
| `7.12/costing/machining` | not started |
| `7.12/costing/sheet-metal` | not started |
| `7.12/costing/weldments` | not started |
| `7.12/costing/casting` | not started |
| `7.12/costing/plastic` | not started |
| `7.12/costing/3d-printed` | not started |
| `7.12/costing/cost-templates` | not started |
| `7.12/sustainability` | not started |
| `7.12/sustainability/environmental-impact` | not started |
| `7.12/sustainability/material-comparison` | not started |
| `7.12/feature-statistics` | not started |

### 7.13 Simulation (FEA)

| Matrix ID | Recorded status |
|---|---|
| `7.13/study-types/linear-static` | not started |
| `7.13/study-types/frequency` | not started |
| `7.13/study-types/buckling` | not started |
| `7.13/study-types/thermal` | not started |
| `7.13/study-types/thermal/steady-transient` | not started |
| `7.13/study-types/drop-test` | not started |
| `7.13/study-types/fatigue` | not started |
| `7.13/study-types/fatigue/s-n` | not started |
| `7.13/study-types/fatigue/event-based` | not started |
| `7.13/study-types/nonlinear` | not started |
| `7.13/study-types/nonlinear/static-dynamic` | not started |
| `7.13/study-types/nonlinear/material-and-geometric-nonlinearity` | not started |
| `7.13/study-types/nonlinear/contact` | not started |
| `7.13/study-types/linear-dynamic` | not started |
| `7.13/study-types/linear-dynamic/modal-time-history` | not started |
| `7.13/study-types/linear-dynamic/harmonic` | not started |
| `7.13/study-types/linear-dynamic/random-vibration` | not started |
| `7.13/study-types/linear-dynamic/response-spectrum` | not started |
| `7.13/study-types/pressure-vessel-design` | not started |
| `7.13/study-types/submodeling` | not started |
| `7.13/study-types/design-study-optimization` | not started |
| `7.13/study-types/topology-optimization` | not started |
| `7.13/study-types/topology-optimization/with-manufacturing-constraints` | not started |
| `7.13/study-types/2d-simplification` | not started |
| `7.13/study-types/beam-truss-elements` | not started |
| `7.13/study-types/shells` | not started |
| `7.13/study-types/shells/sheet-metal-midsurface-auto` | not started |
| `7.13/study-types/composites` | not started |
| `7.13/setup/materials` | not started |
| `7.13/setup/materials/linear-nonlinear-orthotropic-composite` | not started |
| `7.13/setup/fixtures` | not started |
| `7.13/setup/fixtures/all-types` | not started |
| `7.13/setup/loads` | not started |
| `7.13/setup/loads/force` | not started |
| `7.13/setup/loads/pressure` | not started |
| `7.13/setup/loads/torque` | not started |
| `7.13/setup/loads/gravity` | not started |
| `7.13/setup/loads/centrifugal` | not started |
| `7.13/setup/loads/bearing` | not started |
| `7.13/setup/loads/remote` | not started |
| `7.13/setup/loads/distributed-mass` | not started |
| `7.13/setup/loads/temperature` | not started |
| `7.13/setup/loads/thermal-loads` | not started |
| `7.13/setup/connectors` | not started |
| `7.13/setup/connectors/bolts` | not started |
| `7.13/setup/connectors/pins` | not started |
| `7.13/setup/connectors/springs` | not started |
| `7.13/setup/connectors/bearings` | not started |
| `7.13/setup/connectors/welds` | not started |
| `7.13/setup/connectors/rigid` | not started |
| `7.13/setup/connectors/link` | not started |
| `7.13/setup/connectors/edge-weld` | not started |
| `7.13/setup/contacts` | not started |
| `7.13/setup/contacts/bonded` | not started |
| `7.13/setup/contacts/no-penetration` | not started |
| `7.13/setup/contacts/shrink-fit` | not started |
| `7.13/setup/contacts/virtual-wall` | not started |
| `7.13/setup/contacts/contact-visualization` | not started |
| `7.13/setup/mesh` | not started |
| `7.13/setup/mesh/standard-curvature-based-blended` | not started |
| `7.13/setup/mesh/controls` | not started |
| `7.13/setup/mesh/adaptive-h-p` | not started |
| `7.13/setup/mesh/mesh-quality-diagnostics` | not started |
| `7.13/results/stress` | not started |
| `7.13/results/stress/von-mises` | not started |
| `7.13/results/stress/principal` | not started |
| `7.13/results/stress/components` | not started |
| `7.13/results/displacement` | not started |
| `7.13/results/strain` | not started |
| `7.13/results/factor-of-safety` | not started |
| `7.13/results/reaction-forces` | not started |
| `7.13/results/free-body-forces` | not started |
| `7.13/results/probing` | not started |
| `7.13/results/iso-clipping` | not started |
| `7.13/results/section-clipping` | not started |
| `7.13/results/animation` | not started |
| `7.13/results/charts` | not started |
| `7.13/results/compare-studies` | not started |
| `7.13/results/trend-tracking` | not started |
| `7.13/results/report-generator` | not started |
| `7.13/results/results-export` | not started |
| `7.13/results/results-export/csv` | not started |
| `7.13/results/results-export/images` | not started |
| `7.13/results/results-export/video` | not started |
| `7.13/motion-to-fea-load-transfer` | not started |
| `7.13/flow-to-fea-pressure-thermal-transfer` | not started |

### 7.14 Flow Simulation (CFD)

| Matrix ID | Recorded status |
|---|---|
| `7.14/internal-external-flow` | not started |
| `7.14/compressible-incompressible` | not started |
| `7.14/steady-transient` | not started |
| `7.14/heat-transfer` | not started |
| `7.14/heat-transfer/conduction` | not started |
| `7.14/heat-transfer/convection` | not started |
| `7.14/heat-transfer/radiation` | not started |
| `7.14/heat-transfer/conjugate` | not started |
| `7.14/rotating-regions` | not started |
| `7.14/porous-media` | not started |
| `7.14/fans` | not started |
| `7.14/perforated-plates` | not started |
| `7.14/electronics-cooling` | not started |
| `7.14/electronics-cooling/pcb` | not started |
| `7.14/electronics-cooling/heat-sinks` | not started |
| `7.14/electronics-cooling/tec` | not started |
| `7.14/electronics-cooling/heat-pipes` | not started |
| `7.14/hvac` | not started |
| `7.14/hvac/comfort-params` | not started |
| `7.14/free-surface` | not started |
| `7.14/cavitation` | not started |
| `7.14/humidity` | not started |
| `7.14/goals` | not started |
| `7.14/parametric-studies` | not started |
| `7.14/results` | not started |
| `7.14/results/cut-plots` | not started |
| `7.14/results/surface-plots` | not started |
| `7.14/results/flow-trajectories` | not started |
| `7.14/results/particle-studies` | not started |
| `7.14/results/iso-surfaces` | not started |
| `7.14/results/animations` | not started |
| `7.14/results/xy-plots` | not started |
| `7.14/mesh-control` | not started |
| `7.14/engineering-database` | not started |

### 7.15 Plastics

| Matrix ID | Recorded status |
|---|---|
| `7.15/mold-fill` | not started |
| `7.15/pack` | not started |
| `7.15/cool` | not started |
| `7.15/warp` | not started |
| `7.15/gate-location-advisor` | not started |
| `7.15/runner-design` | not started |
| `7.15/cooling-channel-design` | not started |
| `7.15/weld-line-air-trap-prediction` | not started |
| `7.15/sink-marks` | not started |
| `7.15/clamp-force` | not started |
| `7.15/material-database` | not started |
| `7.15/results-and-report` | not started |

### 7.16 Routing & electrical

| Matrix ID | Recorded status |
|---|---|
| `7.16/electrical-routing` | not started |
| `7.16/electrical-routing/cables` | not started |
| `7.16/electrical-routing/wires` | not started |
| `7.16/electrical-routing/harnesses` | not started |
| `7.16/electrical-routing/connectors` | not started |
| `7.16/electrical-routing/clips` | not started |
| `7.16/electrical-routing/from-to-lists` | not started |
| `7.16/electrical-routing/harness-flattening` | not started |
| `7.16/electrical-routing/harness-drawings` | not started |
| `7.16/piping` | not started |
| `7.16/piping/pipes` | not started |
| `7.16/piping/fittings` | not started |
| `7.16/piping/flanges` | not started |
| `7.16/piping/valves` | not started |
| `7.16/piping/spools` | not started |
| `7.16/piping/isometric-drawings-with-pcf-export` | not started |
| `7.16/tubing` | not started |
| `7.16/tubing/flexible-rigid` | not started |
| `7.16/tubing/bends` | not started |
| `7.16/routing-library-manager` | not started |
| `7.16/auto-route` | not started |
| `7.16/orthogonal-routing` | not started |
| `7.16/route-properties` | not started |
| `7.16/pandid-driven-routing` | not started |
| `7.16/electrical-schematic-module-schematics` | not started |
| `7.16/electrical-schematic-module-schematics/electrical-schematic-equivalent` | not started |
| `7.16/line-diagrams` | not started |
| `7.16/symbols-library` | not started |
| `7.16/wire-numbering` | not started |
| `7.16/terminal-strips` | not started |
| `7.16/plc-i-o` | not started |
| `7.16/reports` | not started |
| `7.16/bidirectional-2d-3d-sync` | not started |
| `7.16/pcb-import` | not started |
| `7.16/pcb-import/idf-idx-ecad-collaboration` | not started |
| `7.16/circuitworks-equivalent` | not started |

### 7.17 Rendering & visualization

| Matrix ID | Recorded status |
|---|---|
| `7.17/realview-style-realtime-pbr` | not started |
| `7.17/ambient-occlusion` | not started |
| `7.17/shadows` | not started |
| `7.17/perspective` | not started |
| `7.17/scenes-environments` | not started |
| `7.17/scenes-environments/hdri` | not started |
| `7.17/appearances-library` | not started |
| `7.17/decals` | not started |
| `7.17/lights` | not started |
| `7.17/lights/directional` | not started |
| `7.17/lights/point` | not started |
| `7.17/lights/spot` | not started |
| `7.17/lights/area` | not started |
| `7.17/cameras` | not started |
| `7.17/cameras/with-dof` | not started |
| `7.17/photoreal-path-traced-renderer` | not started |
| `7.17/photoreal-path-traced-renderer/photoview-360-visualize-parity-denoising` | not started |
| `7.17/photoreal-path-traced-renderer/render-regions` | not started |
| `7.17/photoreal-path-traced-renderer/turntables` | not started |
| `7.17/photoreal-path-traced-renderer/animation-rendering` | not started |
| `7.17/photoreal-path-traced-renderer/sun-study` | not started |
| `7.17/photoreal-path-traced-renderer/render-queue` | not started |
| `7.17/exploded-animated-presentations` | not started |
| `7.17/3d-views-and-pdf-web-publishing` | not started |
| `7.17/edrawings-equivalent-lightweight-viewer` | not started |
| `7.17/edrawings-equivalent-lightweight-viewer/mac` | not started |
| `7.17/edrawings-equivalent-lightweight-viewer/ios-visionos-stretch-goal` | not started |
| `7.17/edrawings-equivalent-lightweight-viewer/ar-quick-look-via-usdz-export` | not started |

### 7.18 CAM

| Matrix ID | Recorded status |
|---|---|
| `7.18/feature-recognition-for-machinable-features` | not started |
| `7.18/feature-recognition-for-machinable-features/afr` | not started |
| `7.18/2-5-axis-mill` | not started |
| `7.18/3-axis-mill` | not started |
| `7.18/4-5-axis-indexed-and-simultaneous` | not started |
| `7.18/4-5-axis-indexed-and-simultaneous/later-milestone` | not started |
| `7.18/turning` | not started |
| `7.18/mill-turn` | not started |
| `7.18/probing` | not started |
| `7.18/technology-database` | not started |
| `7.18/technology-database/tools` | not started |
| `7.18/technology-database/feeds-speeds` | not started |
| `7.18/technology-database/strategies` | not started |
| `7.18/stock-definition` | not started |
| `7.18/toolpath-simulation-with-material-removal` | not started |
| `7.18/collision-gouge-checking` | not started |
| `7.18/post-processors` | not started |
| `7.18/post-processors/fanuc` | not started |
| `7.18/post-processors/haas` | not started |
| `7.18/post-processors/mazak` | not started |
| `7.18/post-processors/siemens` | not started |
| `7.18/post-processors/heidenhain` | not started |
| `7.18/post-processors/grbl` | not started |
| `7.18/post-processors/and-a-custom-post-language` | not started |
| `7.18/setup-sheets` | not started |
| `7.18/g-code-output` | not started |

### 7.19 Data management

| Matrix ID | Recorded status |
|---|---|
| `7.19/pdm/vault` | not started |
| `7.19/pdm/vault/local-and-server-based` | not started |
| `7.19/pdm/check-in-out` | not started |
| `7.19/pdm/version-and-revision-control` | not started |
| `7.19/pdm/lifecycle-states-and-workflows` | not started |
| `7.19/pdm/where-used-contains` | not started |
| `7.19/pdm/references-management` | not started |
| `7.19/pdm/bom-management` | not started |
| `7.19/pdm/search` | not started |
| `7.19/pdm/change-requests-ecos` | not started |
| `7.19/pdm/permissions` | not started |
| `7.19/pdm/replication` | not started |
| `7.19/pdm/minimum-viable-git-backed-local-vault` | not started |
| `7.19/pdm/full-server-component` | not started |
| `7.19/pdm/full-server-component/swift-on-server-or-equivalent` | not started |
| `7.19/pack-and-go` | not started |
| `7.19/rename-with-references` | not started |
| `7.19/reference-repair` | not started |
| `7.19/task-scheduler` | not started |
| `7.19/task-scheduler/batch-export-print-convert` | not started |
| `7.19/design-library` | not started |
| `7.19/file-references-and-external-reference-management` | not started |
| `7.19/backup-auto-recover` | not started |
| `7.19/collaboration` | not started |
| `7.19/collaboration/shared-links` | not started |
| `7.19/collaboration/markup-comments-edrawings-markup-parity` | not started |

### 7.20 Import / export

| Matrix ID | Recorded status |
|---|---|
| `7.20/native/own-formats` | not started |
| `7.20/native/own-formats/section-4-5` | not started |
| `7.20/neutral/step-ap203-214-242` | in progress |
| `7.20/neutral/step-ap203-214-242/with-pmi` | not started |
| `7.20/neutral/iges` | not started |
| `7.20/neutral/parasolid-via-step-only` | not started |
| `7.20/neutral/parasolid-via-step-only/no-direct-x-t-unless-licensed` | not started |
| `7.20/neutral/acis-sat` | not started |
| `7.20/neutral/acis-sat/evaluate` | not started |
| `7.20/neutral/jt` | not started |
| `7.20/neutral/jt/evaluate` | not started |
| `7.20/neutral/vda-fs` | not started |
| `7.20/neutral/3mf` | not started |
| `7.20/neutral/stl` | in progress |
| `7.20/neutral/obj` | not started |
| `7.20/neutral/ply` | not started |
| `7.20/neutral/usdz-usd` | not started |
| `7.20/neutral/gltf` | not started |
| `7.20/neutral/vrml` | not started |
| `7.20/neutral/dxf-dwg` | not started |
| `7.20/neutral/dxf-dwg/2d-in-out` | not started |
| `7.20/neutral/dxf-dwg/3d-dwg-out` | not started |
| `7.20/neutral/pdf-3d-pdf` | not started |
| `7.20/neutral/svg` | not started |
| `7.20/neutral/ifc` | not started |
| `7.20/neutral/ifc/bim` | not started |
| `7.20/neutral/idf-idx` | not started |
| `7.20/neutral/idf-idx/ecad` | not started |
| `7.20/neutral/rhino-3dm` | not started |
| `7.20/neutral/rhino-3dm/via-opennurbs` | not started |
| `7.20/solidworks-native-files-sldprt-sldasm-slddrw` | not started |
| `7.20/3d-printing/3mf-with-color-materials` | not started |
| `7.20/3d-printing/print-bed-preview` | not started |
| `7.20/3d-printing/support-overhang-analysis` | not started |
| `7.20/3d-printing/hollowing` | not started |
| `7.20/3d-printing/lattice-generation` | not started |

### 7.21 Customization & automation

| Matrix ID | Recorded status |
|---|---|
| `7.21/full-api` | in progress |
| `7.21/full-api/section-5` | not started |
| `7.21/macros` | not started |
| `7.21/add-in-manager` | not started |
| `7.21/toolbar-palette-customization` | not started |
| `7.21/keyboard-mouse-gesture-mapping` | not started |
| `7.21/templates` | not started |
| `7.21/templates/part-assembly-drawing` | not started |
| `7.21/document-properties-and-system-options` | not started |
| `7.21/document-properties-and-system-options/every-solidworks-option-category-mapped` | not started |
| `7.21/units-systems` | in progress |
| `7.21/material-appearance-library-authoring` | not started |
| `7.21/task-scheduler` | not started |

### Discovered (SolidWorks capabilities not listed in SPEC §7)

| Matrix ID | Recorded status |
|---|---|
| `D/hide-show` | not started |
| `D/transparency` | not started |
| `D/section-view-part` | not started |
| `D/view-selector` | not started |
| `D/zoom-to-selection` | not started |
| `D/display-states-part` | not started |
| `D/feature-comments` | not started |
| `D/selection-sets` | not started |
