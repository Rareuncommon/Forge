# SolidWorks workflow parity audit

Audit date: 2026-09-28. Baseline: the Forge checkout and official SOLIDWORKS Design
2026 help linked below. This is a targeted core-workflow gap assessment, not an
exhaustive review of every SOLIDWORKS option, release, add-in, or Forge source line.
The earlier [reference inventory](solidworks.md) remains useful, but its claimed
research volume has not been independently reproduced in this audit.

## What exists

At audit start, `FEATURES.md` recorded 1,000 rows: 843 not started, 131 in progress,
26 done, and zero verified. Rows overlap and differ in size; these counts are not a
percentage of product functionality. `Sources/ForgeCommands/StandardRegistry.swift`
registered 97 commands. `Tests/GoldenModelTests/Models` contained 31 scenarios.
These are inventory observations, not assertions that every command is correct.

The implemented foundation is an OCCT-backed part modeler with a constrained 2D
sketcher, a replayable feature history, native platform shells, document packages,
STEP/STL export, and shared CLI/MCP commands. `Package.swift` has no ForgeAssembly,
ForgeDrawing, ForgeSim, ForgeCAM, or ForgeRouting target. Those are proposed modules
in `SPEC.md`, not shipped implementations. A rendered view is not a drawing, and a
transformed body is not a component with assembly mates.

## Acceptance criteria by workflow

The criteria below are proposed Forge acceptance tests inferred from the documented
SOLIDWORKS behaviors. They do not imply that a test or implementation already exists.
Every completed feature must additionally meet SPEC §0: rebuild, persistence,
undo/redo, documented command/MCP exposure, and regression coverage.

| Workflow and official reference | Forge evidence and gap | Required acceptance scenario |
|---|---|---|
| Sketch relations: SOLIDWORKS specifies relation behavior by entity type ([relations](https://help.solidworks.com/2026/english/solidworks/sldworks/c_Description_of_Sketch_Relations.htm)). | `ForgeSketch/Constraints.swift`, `Solver.swift`, and sketch commands implement a substantial 2D subset; `SolverTests.swift` and `SketchCommandTests.swift` exercise it. Spline interior tangency, spline trim/split, and ellipse/spline offset explicitly remain unimplemented. Full 3D sketch parity is absent. | Fully constrain a profile with geometry and dimensions, report remaining freedom and contradictory constraints, edit and drag it, rebuild its extrusion, save/reopen, and reproduce the same outcome through MCP. Test unsupported entity combinations explicitly. |
| Rebuild: changed-feature and force rebuild, including configurations, are separate operations ([rebuild tools](https://help.solidworks.com/2026/english/SolidWorks/sldworks/c_fundamentals_rebuild_tools_help.htm)). | `Features.swift`, feature commands, `FeatureTreeTests.swift`, and `NamingTests.swift` provide replay, editing, suppression, rollback, and reference repair. Configuration-aware rebuilding and the full history-management scope are absent. Persistent vertex naming remains a known gap in PROGRESS. | Change an upstream dimension; preserve intended downstream references, isolate a failed feature, repair it, and verify subsequent edits and undo. Compare full and incremental rebuild results; add configuration variants once configurations exist. |
| Part creation and interaction: shaded previews persist during view navigation and supported dynamic previews react to editing ([previews](https://help.solidworks.com/2026/english/SolidWorks/sldworks/c_shaded_dynamic_previews.htm)). | Extrude, revolve, fillet, chamfer, shell, draft, holes, patterns, sweep, loft, and rib have command implementations. `SweepLoftRibTests.swift` and golden models cover selected cases. PROGRESS lists absent sweep guide curves/twist, loft tangency/guide curves, and curved rib profiles. Surfacing and many advanced feature variants remain missing. | Preview, cancel, commit, reopen, and edit each feature from every supported shell; prove preview leaves document state unchanged and commit uses the same parameters. Verify volumes analytically and reference identity across upstream edits. |
| Assemblies and mates: valid mate types depend on both selected geometric entities ([mate compatibility](https://help.solidworks.com/2026/english/SolidWorks/sldworks/r_Standard_Mates_by_Entity.htm)). | No assembly component/mate command family or solver target is registered. FEATURES §7.7 lists standard, advanced, and mechanical mates as not started. | Insert repeated instances of a part, ground one component, mate plane and cylindrical references, drag remaining freedom, diagnose redundancy, suppress a mate, and reopen with consistent transforms. Extend to subassemblies, limits, mechanical mates, interference, and patterns. |
| Drawings and BOM: views reference models and derived views; BOM can be attached to assemblies or drawings ([views](https://help.solidworks.com/2026/english/SolidWorks/sldworks/c_views_of_parts_and_assemblies.htm), [BOM](https://help.solidworks.com/2026/english/SolidWorks/sldworks/c_Bill_of_Materials1.htm)). | No drawing sheet/view/annotation/BOM commands or drawing target. Raster rendering commands do not implement associative drafting or tabulation. | Create a scaled sheet with projected/section/detail views, dimensions linked to geometry, and a BOM. Modify the assembly and verify drawing geometry, quantities, item numbers, and balloons update; verify print and vector export. |
| Configurations and design tables can vary dimensions, suppression, properties, mates, and configuration relationships ([design tables](https://help.solidworks.com/2026/English/SolidWorks/Sldworks/c_Design_Table_Configurations.htm)). | FEATURES `P/parameters` is not started. The registry contains no configuration, equation, global-variable, or design-table command family. | Define two dimension/suppression variants, switch without contaminating the other, save/reopen both, and rebuild all variants. Add unit-aware equations with cycle/error diagnosis, then design-table import and BOM configuration rules. |
| Exchange: STEP AP242 has its own publication workflow ([STEP242](https://help.solidworks.com/2026/english/SolidWorks/sldworks/r_publish_step242.htm)); PMI attachments require the relevant MBD capability ([PMI](https://help.solidworks.com/2026/english/edrawings/c_step_files_in_edrawings_files.htm)). | The registry exposes STEP and STL export and native document open/save. No general neutral-file import, feature recognition, or PMI authoring command family exists. STEP export alone does not establish AP242 semantic PMI or native SOLIDWORKS compatibility. | Round-trip neutral geometry with units, orientation, tolerances, and body counts checked independently; test malformed files. Add assembly hierarchy/material transfer, then PMI with independent reader validation. Keep native-file licensing/dependency decisions explicit per SPEC §7.20. |
| Analysis: SOLIDWORKS organizes distinct study types, setup, and generated results in study trees ([simulation studies](https://help.solidworks.com/2026/english/SolidWorks/Cworks/c_Simulation_Study_Tree.htm)). | Mass properties, geometric measurement, validation, and compare-to-spec queries exist. There is no study/mesh/load/material/solve/results command pipeline or simulation target. | Begin with a linear static benchmark: material, fixtures, load, mesh convergence, solver diagnostics, reactions, displacement/stress, reproducible saved study, and plotted results. Thermal, frequency, nonlinear, CFD, plastics, and coupled analyses need separate validated milestones. |

## Delivery order and proof

1. Stabilize the existing part workflow and shared command boundary. Regress invalid
   numeric inputs, transaction rollback, save/open failures, reference repair, and
   preview/cancel behavior before increasing breadth.
2. Complete M2/M3 foundations: materials, parameter/equation/configuration model,
   missing feature variants, neutral import with diagnostics, and dependable naming.
3. Implement M4 assemblies as a real component/reference/solver model, then M5
   associative drawings and BOM. Test cross-document dependency updates explicitly.
4. Follow M6–M13 for manufacturing, simulation, rendering, data management, and
   automation; each requires domain-specific models and independent verification.
5. Repeat M14 against release-specific official documentation, using reproducible
   workflow evidence rather than matching toolbar labels or counting commands.

All steps retain the full SPEC scope. CAM, routing/electrical, PDM, advanced rendering,
sheet metal, weldments, molds, MBD, quality, and specialized simulation were checked
against the inventory only in this pass; their detailed algorithms and workflows
still require dedicated research and implementation audits. A single PR cannot
honestly claim the remaining product has been implemented or all bugs eliminated.

## Build/packaging findings addressed with this audit

- Xcode selection used an unmatched `ls` glob inside a pipe under `pipefail`, which
  could exit before the intended fallback. Directory discovery now tolerates no
  preferred match and emits a clear failure if no Xcode installation exists.
- The Windows screenshot step previously allowed failures without failing CI. It
  now checks executable existence, exit status, and nonempty screenshot output.
- The Windows OCCT downloader could accept a stale ZIP after failed downloads,
  write a cache marker before installation validation, and split DLL directories
  containing spaces. It now tracks successful downloads, marks validated installs,
  and shell-quotes generated environment values. Failed partial optional downloads
  are discarded rather than treated as archives.
- `Tests/PackagingTests/test_fetch_occt_windows.py` adds offline mocked-download
  regressions for failure/cache handling and paths with spaces and quotes. These
  tests pass on Linux. This is not validation of a real Windows dependency archive
  or native macOS/Windows execution; those remain CI/platform checks.
