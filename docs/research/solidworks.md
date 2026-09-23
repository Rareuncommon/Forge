# SOLIDWORKS reference for Forge (2025 / 2026 releases)

Research date: 2026-09-23. Scope: SOLIDWORKS Design 2025 (SP0–SP5) and 2026 (SP0–SP2/FD02).
Purpose: a factual map of SOLIDWORKS' UI and capabilities for Forge's parity work. It is
cross-referenced against `SPEC.md` §6–§7 and `FEATURES.md` as of this date.

**How this was researched.** Most facts come from the official SOLIDWORKS 2025 web help
(`help.solidworks.com/2025/english/SolidWorks/sldworks/…`). About 4,100 help pages were fetched
and read, and the page for each claim is linked inline. A few items are not in the help: default
RGB colours, some default toolbar layouts and the meaning of inference-line colours. For those,
community sources are cited and the claim is marked *(community)*. Anything I could not confirm
is marked *(unverified)*. The Forge columns come from `FEATURES.md` feature IDs (e.g.
`7.2/applied/shell`).

Abbreviation used in links below: every `help:` link is
`https://help.solidworks.com/2025/english/SolidWorks/sldworks/<page>`; the full URL is written out.

---

## Contents

1. [UI anatomy](#1-ui-anatomy)
2. [Feature inventory](#2-feature-inventory)
   - 2.1 Sketch · 2.2 Reference geometry · 2.3 Curves · 2.4 Boss/base & cut · 2.5 Applied features ·
     2.6 Holes & threads · 2.7 Patterns & mirror · 2.8 Multibody & direct editing ·
     2.9 Surfaces · 2.10 Sheet metal · 2.11 Weldments · 2.12 Mold tools ·
     2.13 Parameters: equations, global variables, configurations, design tables ·
     2.14 Materials, appearances, scenes · 2.15 Assemblies · 2.16 Drawings ·
     2.17 Evaluate tools · 2.18 Import / export
3. [Recent changes (2025 / 2026)](#3-recent-changes-2025--2026)
4. [Priority for Forge](#4-priority-for-forge)

---

## 1. UI anatomy

The main window is described in
[User Interface Overview](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_user_interface_overview.htm).
Its parts are the Menu Bar, toolbars, the **CommandManager** ribbon, the **Manager Pane** on the
left, the graphics area, the **Heads-up View toolbar**, **Selection Breadcrumbs**, the **Task
Pane** on the right, Search and the Help menu. The Manager Pane has tabs for FeatureManager,
PropertyManager, ConfigurationManager, DimXpertManager and DisplayManager, plus a tree filter.

### 1.1 CommandManager

- A context-sensitive toolbar ("ribbon"). It changes when you click a tab below it, and by default
  it holds the toolbars that suit the document type
  ([CommandManager](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_commandmanager.htm)).
- **Button style:** right-click → *Use Large Buttons with Text* gives the large icon with a label
  underneath. Per button you can pick *Show Text* or *Text Below*. Ctrl+PgUp/PgDn cycles the tabs.
  The CommandManager can be floated, or docked above, left or right. Custom tabs can be added
  (right-click tab → Customize → New Tab) and filled by dragging from the Customize → Commands tab.
- **Default part tabs:** Features, Sketch, Markup, Evaluate, MBD Dimensions, SOLIDWORKS Add-Ins
  and MBD. More can be enabled by right-clicking a tab: Surfaces, Sheet Metal, Weldments, Mold
  Tools, Direct Editing, Data Migration, DimXpert, Render Tools, Structure System and others
  *(community: [CATI](https://www.cati.com/blog/exploring-the-solidworks-commandmanager/))*.
  Assemblies show Assembly, Layout, Sketch, Markup, Evaluate and more. Drawings show Drawing
  (View Layout), Annotation, Sketch, Markup, Evaluate and Sheet Format.
- **Flyout buttons:** related commands share one button with a flyout arrow (all rectangle types
  under one button, for example). For some tools, such as Sketch, the button always runs the
  first command. For others, such as Rectangle, it runs the variant used last
  ([Flyout Tool Buttons](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_flyout_tool_buttons.htm)).
- **Contents of the main tabs.** These come from the default toolbar definitions:
  - *Features:* see [Features Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_features_toolbar_features.htm)
    (Extruded/Revolved/Swept/Lofted/Boundary Boss and Cut, Thicken, Cut With Surface, Fillet,
    Chamfer, Rib, Shell, Draft, Hole Wizard, Advanced Hole, Thread, Dome, Wrap, Intersect,
    Linear/Circular/Curve Driven/Sketch Driven/Table Driven/Fill/Variable Pattern, Mirror,
    Reference Geometry, Curves, Instant3D, Live Section Plane, Combine, Split, Move/Copy Bodies,
    Delete/Keep Body, Scale, Move Face, Freeform, Deform, Flex, Indent, 3D Texture…).
  - *Sketch:* see [Sketch Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_sketch_toolbar.htm).
  - *Evaluate:* measurement and analysis tools from the
    [Tools Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_tools_toolbar.htm)
    (Measure, Mass Properties, Section Properties, Sensor, Check, Geometry Analysis, Import
    Diagnostics, Deviation Analysis, Thickness Analysis, Symmetry Check, Compare, Design Checker,
    Costing, Sustainability, SimulationXpress/FloXpress/DFMXpress, Performance Evaluation), plus
    display analyses: Zebra Stripes, Curvature, Draft Analysis, Undercut Analysis, Parting Line Analysis.
  - *Markup:* pen and touch markups (Sketch Ink, markup notes).

### 1.2 FeatureManager design tree

Sources: [Overview](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_featuremanager_design_tree_overview.htm),
[Conventions](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_FeatureManager_Design_Tree_Conventions.htm),
[Rollback Bar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_rollback_bar.htm).

- **Linked to the graphics area:** selecting in either pane selects in both. The tree can be
  split into two panes, or shown alongside the ConfigurationManager or PropertyManager. F9 toggles it.
- **Default contents of a new part:** document name (with configuration and display state),
  *History*, *Sensors*, *Annotations*, *Material <not specified>*, *Front Plane*, *Top Plane*,
  *Right Plane*, *Origin*, then features in regeneration order. More folders appear when needed:
  *Solid Bodies (n)* and *Surface Bodies (n)*, *Equations* (after the first equation), *Design
  Binder*, *Favorites*, *Selection Sets*, *Tables*, *Comments*, *Lights, Cameras and Scene*
  (some are hidden by default). Custom folders can be created, and features dragged into them.
- **Actions:** select by name; filter the tree; drag to reorder, which changes regeneration order;
  double-click a feature to show its dimensions; slow double-click to rename; suppress or
  unsuppress; *Parent/Child…*; *What's Wrong?* for errors; show feature descriptions and
  component configuration names. Shift+C collapses all items.
- **Rollback bar:** a horizontal bar you drag up or down to regenerate only the features above it.
  Rolled-back icons go grey. You can add new features or edit while rolled back. The rollback
  position is saved with the document. Right-click offers *Roll Forward*, *Roll to Previous* and
  *Roll to End*, and features below the bar can be deleted. Arrow keys move the bar when *Arrow key
  navigation* is on. Absorbed features (such as a sketch inside an extrude) can be rolled back to.
  There is also a *Freeze bar* that locks features above it so they are not rebuilt.
- **Sketch status prefixes** in the tree: `(+)` over defined, `(-)` under defined, `(?)` cannot be
  solved, no prefix fully defined.
- **Assembly prefixes:** `(+)` over defined, `(-)` under defined, `(?)` not solved, `(f)` fixed,
  instance number `<n>`. Mates show `(+)` when over defining and `(?)` when not solved.
  A folder shows `(-)` or `(+)` if something inside it has that state.
- **Error and warning icons:** there are distinct icons for "error in model", "error with feature",
  "warning underneath node" and "warning with feature". They are a red circle with "!" for errors
  and a yellow triangle for warnings. A rebuild-needed icon (traffic-light/arrow) appears before
  features that need regeneration. Suppressed features are shown greyed.
- **Flyout FeatureManager:** while a PropertyManager fills the left pane, a transparent copy of the
  tree can be expanded in the top-left of the graphics area to pick items.

### 1.3 PropertyManager

Source: [PropertyManager Overview](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_pm_overview.htm).

- **Title bar:** the feature icon and name (e.g. `Boss-Extrude1`).
- **Buttons:** **OK** (green check ✓), **Cancel** (red ✗), **Detailed Preview** (eye icon),
  **Help**, and **Keep Visible** (pushpin). The pushpin keeps the PropertyManager open so you can
  create several features in a row. From 2025 SP2 the Fillet and Chamfer PropertyManagers can be
  pinned too
  ([What's New](https://help.solidworks.com/2025/english/WhatsNew/c_wn2025_parts_PinFilletChamferPM.htm)).
  Wizard PropertyManagers add Back, Next and Undo.
- **Message box:** a yellow-tinted box at the top that tells you what to select next.
- **Group boxes:** titled groups (for example *Direction 1*) that expand and collapse. Optional
  groups such as *Direction 2*, *Thin Feature* and *Draft* have a checkbox in the title that turns
  the group on or off.
- **Selection boxes:** accept picks from the graphics area or the tree. The active box is shown
  highlighted ("When active, the boxes are pink"). Items in a box highlight in the graphics area
  with colour callouts. Right-click a box for *Delete* or *Clear Selections*. The box grows as items
  are added and can be resized; right-click → Autosize resets it.
- **Keyboard:** Tab moves between controls, Space toggles checkboxes, arrow keys change options,
  Enter means OK and Esc means Cancel.
- **Equations in fields:** type `=` in a numeric field to enter an equation. It can use global
  variables, functions and file properties
  ([Direct Input of Equations](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_direct_input_of_equations2.htm)).
- **Example layout — Extrude:** From → Direction 1 (end condition, reverse, depth, flip side to
  cut, draft) → Direction 2 (checkbox) → Thin Feature (checkbox) → Selected Contours → Feature Scope.
  All options are listed in §2.4.

### 1.4 ConfigurationManager, DimXpertManager, DisplayManager

- **ConfigurationManager:** lists configurations as a tree. Icons show manual versus design-table
  configurations, explode states, derived configurations and whether the configuration's data is
  up to date. It also shows the Excel design table, the configuration table and a custom
  PropertyManager, and has a section for display states. Configurations can be sorted Numeric,
  Literal, Manual, History-Based or Design Table. Right-click → Show Preview
  ([Configuration Views](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_ConfigurationManager.htm)).
  On 3DEXPERIENCE-connected models the tab is *ConfigurationManager: CAD Family*, with Physical
  Products and Representations.
- **DimXpertManager:** manages the DimXpert (MBD) scheme: manufacturing features (boss, chamfer,
  cone, cylinder, fillet, counterbore/countersink/simple hole, notch, plane, pocket, slot,
  surface, width, sphere, intersect point/line/plane/circle), datums, size and location
  dimensions, and geometric tolerances to ASME Y14.41-2019 / ISO 16792. Tools include Auto
  Dimension Scheme, Show Tolerance Status and Copy Scheme
  ([DimXpert for Parts](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_dimxpert_for_parts.htm)).
- **DisplayManager:** lists the model's appearances, decals, scene, lights and cameras
  ([DisplayManager](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_display_manager.htm)).
  The tree also has a **Display Pane**, an expandable column that shows the hide/show, display
  style, appearance and transparency of each item.

### 1.5 Heads-up View toolbar

- "A transparent toolbar in each viewport provides all the common tools required for manipulating
  the view." It sits at the top centre of the graphics area. Custom and camera views appear in the
  View Orientation flyout. It can be customised through Tools > Customize
  ([Heads-up View Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_heads_up_view_toolbar.htm)).
- **Default part/assembly buttons, left to right:** **Zoom to Fit** (F), **Zoom to Area**,
  **Previous View**, **Section View**, **Dynamic Annotation Views** (MBD), **View Orientation**
  flyout, **Display Style** flyout, **Hide/Show Items** flyout, **Edit Appearance**, **Apply
  Scene** flyout, **View Settings** flyout, and a Viewport flyout (Single / Two Horizontal / Two
  Vertical / Four View / Link Views)
  *(community: [solidworkstutorialsforbeginners](https://solidworkstutorialsforbeginners.com/solidworks-heads-up-view-toolbar/))*.
- **View Orientation flyout:** Front, Back, Left, Right, Top, Bottom, Isometric, Trimetric,
  Dimetric, Normal To, the viewport layouts, the **View Selector** (a cube around the model with
  clickable faces, edges and corners) and **New View**
  ([Standard Views Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_standard_views_toolbar.htm)).
  Spacebar opens the Orientation dialog.
- **Display Style flyout:** Shaded With Edges, Shaded, Hidden Lines Removed, Hidden Lines Visible,
  Wireframe.
- **Hide/Show Items flyout:** one toggle per class: axes, temporary axes, planes, origins,
  coordinate systems, points, curves, sketches, 3D sketch planes, sketch relations, dimension
  names, annotations, parting lines, lights, cameras, decals, grid, weld beads, routing points and
  so on. A *View Sketch Relations* toggle sits here.
- **View Settings flyout:** RealView Graphics, Shadows In Shaded Mode, Ambient Occlusion,
  Perspective, Cartoon
  ([RealView](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_realview.htm),
  [Ambient Occlusion](https://help.solidworks.com/2025/english/SolidWorks/sldworks/t_ambient_occlusion.htm)).
- **Section View (models):** *Planar* (1–3 section planes) or *Zonal*. Options: Offset Method
  (reference plane / selected plane), Show section cap (with cap colour), Keep cap color,
  Graphics-only section. Each section plane has offset and rotation handles, can be flipped, and
  can be rotated about an axis
  ([Section View PropertyManager (Models)](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_DYNAMIC_SECTION.htm)).

### 1.6 Task Pane (right side)

Tabs: *SOLIDWORKS Resources*, *Design Library* (Toolbox, library features, SOLIDWORKS Content),
*File Explorer*, *View Palette* (views to drag onto drawings), *Appearances, Scenes, and Decals*,
*Custom Properties* (built with Property Tab Builder), *3DEXPERIENCE Marketplace*, *Compare*,
*User Forum* and *Search*. Documents drag in from File Explorer and Design Library. The pane can
be pinned, floated or collapsed
([Task Pane](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_task_pane.htm)).

### 1.7 Status bar

It shows a tool description on hover, a rebuild icon, **sketch status and pointer coordinates**
while sketching, common measurements for the current selection (such as edge length), an
"Editing Part" message in context, collaboration reload, the **Unit System** (click to change, e.g.
MMGS / IPS / custom) and the Tags box
([Status Bar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_status_bar.htm)).
There are five sketch states: *Fully Defined*, *Over Defined*, *Under Defined*, *No Solution
Found* and *Invalid Solution Found*. The option *Use fully defined sketches* can be set to require
full definition
([Sketch Status Conventions](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Sketch_Status_Conventions.htm)).

### 1.8 Shortcut bar ("S" key), context toolbars, mouse gestures, keyboard

- **Shortcut bars:** separate customisable command bars for Part, Assembly, Drawing and Sketch.
  They open at the pointer with the **S** key. *Search All Commands* is built in, and a command
  found there can be added with *Insert Command*. Arrow keys, Enter and Esc work inside the bar
  ([Shortcut Bars](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_shortcut_bars.htm)).
- **Context toolbars:** a small icon toolbar appears next to the pointer when you select an item
  in the graphics area or tree. It holds common actions such as Edit Feature, Edit Sketch,
  Suppress, Hide, Normal To and Sketch. Right-click shows the context toolbar plus a menu. Options
  include *Show on selection*, *Show quick configurations*, *Show quick mates* (the assembly Quick
  Mates bar) and *Show in shortcut menu*. Shift+F10 opens it from the keyboard
  ([Context Toolbars](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_context_toolbars.htm)).
- **Mouse gestures:** right-drag in the graphics area to bring up a radial guide of 2, 3, 4, 8 or
  12 commands (default 4), with separate sets for part, assembly, drawing and sketch. Release on a
  command to run it. Customised by drag-and-drop in Tools > Customize > Mouse Gestures
  ([Mouse Gestures](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_mouse_sestures.htm)).
- **Mouse navigation** (defaults): middle-drag rotates, Ctrl+middle-drag pans, Shift+middle-drag
  zooms, the wheel zooms about the pointer, a middle-button double-click is Zoom to Fit, and
  Alt+middle-drag rolls about the view normal. Middle-click on an edge, vertex or face sets the
  rotation centre.
- **Default keyboard** (subset, customisable): Ctrl+1…7 give Front, Back, Left, Right, Top, Bottom
  and Isometric; Ctrl+8 Normal To; Space opens View Orientation; F Zoom to Fit; Z / Shift+Z zoom
  out / in; G magnifying glass; Ctrl+B rebuild; Ctrl+Q force rebuild; Enter repeats the last
  command; S shortcut bar; D moves the confirmation corner or breadcrumbs to the pointer; F5 shows
  the Selection Filter toolbar; F6 toggles filters; E, X and V filter edges, faces and vertices;
  F9 toggles the FeatureManager; F11 full screen; Shift+C collapses the tree; Tab / Shift+Tab hide
  or show the component under the pointer
  ([Selected Keyboard Shortcuts](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_time_saving_keyboard_shortcuts.htm),
  [Selection Filter Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_selection_filter.htm)).

### 1.9 Selection aids

- **Selection Breadcrumbs:** appear in the upper-left of the graphics area when you select an
  entity or tree node. They show the chain face → body/feature → sketch → part → subassembly →
  top assembly, with mates for a component. Every crumb can be clicked or right-clicked, and each
  shows its suppression state. D moves them to the pointer. They can be turned off in System
  Options > Display
  ([Selection Breadcrumbs](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_selection_breadcrumbs.htm)).
- **Selection Filter:** filters for vertices, edges, faces, surface bodies, solid bodies, axes,
  planes, sketch points, sketches, sketch segments, midpoints, centre marks, centerlines,
  dimensions/hole callouts, surface finish, geometric tolerances, notes/balloons, datum
  features/targets, weld symbols/beads, cosmetic threads, blocks, mesh facets/edges/vertices and more.
  Tools include *Clear All*, *Select All* and *Invert Selection*.
- Other tools: **Select Other** (right-click to cycle through hidden faces), box and cross
  selection, lasso, **Select Tangency**, **Selection sets**, **Magnifying Glass** (G),
  **SelectionManager** (picks open or closed chains and regions for sweeps and lofts), and
  **Power Select**.

### 1.10 Confirmation Corner

In the top-right corner of the graphics area. When a PropertyManager is open it shows **OK /
Cancel**. In a sketch it shows **Exit Sketch** (a sketch icon with a check) and **Cancel Sketch**
(red ✗). D moves these buttons to the pointer. Right-click in the graphics area also offers
OK/Cancel. It can be turned off with *Enable Confirmation Corner*
([Accepting Features](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_accepting_features.htm)).

### 1.11 Instant3D and the triad

- **Instant3D** (a toggle on the Features toolbar): select a face and drag its arrow handle to
  change the feature. On-screen **rulers** give precise values, and you can snap to geometry.
  Features can be created by dragging a sketch contour. Internal sketch contours can be edited.
  Mirrored and patterned instances carry the same handles as the seed. **Live Section Planes**
  let you edit through a section
  ([Instant3D](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_instant3d_functionality.htm)).
- **Triad (manipulator):** drag an arm to move along X, Y or Z; a wing to move in a plane; a ring
  to rotate; the centre ball to move freely (Alt aligns to geometry). Ctrl-drag copies. Right-click
  offers Show Translate XYZ Box, Move to Selection and Align with Selection. A ring snaps in 90°
  steps near the ring, with finer steps further away. The triad appears in Move/Copy Body, Flex,
  Deform, 3D-sketch *Show Sketcher Triad*, assembly components and explode steps
  ([Triad](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_triad.htm)).
- **Reference triad** (bottom-left): shows orientation. Click an axis to view normal to it;
  Shift-click rotates 90°; Alt-click rotates by the arrow-key increment
  ([Reference Triad](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_reference_triad.htm)).

### 1.12 Sketch inference, relations and status colours

- **Inferencing:** dotted *inferencing lines* show while sketching, along with pointer glyphs
  (e.g. the pointer gains a small horizontal/coincident icon) and highlighted cues such as midpoints
  and endpoints. Sketch Snaps and Quick Snaps work with them. Automatic relations can be turned off
  in Tools > Sketch Settings > Automatic Relations
  ([Inferencing](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Inferencing.htm)).
- **Inference-line colours** *(community: [CATI](https://www.cati.com/blog/solidworks-what-are-inference-lines-and-did-you-know-you-could-change-there-colors/))*:
  **blue** dotted lines are visual guides only, such as alignment with another endpoint, and do
  **not** add a relation. **Yellow** (the default, configurable) dotted lines add a relation such
  as tangent, perpendicular, horizontal or vertical when you click on them.
- **Relation glyphs:** once an entity is placed, small icons next to it show its relations
  (horizontal, vertical, coincident, tangent, equal and so on). They are toggled with View >
  Hide/Show > Sketch Relations. Selecting a glyph selects the relation, which Delete removes.
- **Entity colours** ([Sketch Geometry Status](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Sketch_Geometry_Status.htm)):

  | State | Colour | Meaning |
  |---|---|---|
  | Under Defined | **blue** | still has free degrees of freedom |
  | Fully Defined | **black** | all positions fixed by dimensions and relations |
  | Over Defined / Item is unsolvable | **red** | conflicting constraints; the solver cannot position the entity |
  | Item Conflicts (redundant) / Invalid | **yellow** | redundant dimension or unnecessary relation; or invalid geometry (zero length, self-intersecting spline) |
  | Dangling | **brown** (golden brown) | its reference is missing, e.g. a converted edge was deleted |
  | Driven dimension | **grey** | reference (driven) dimension |
  | Construction geometry | dashed, same status colour | excluded from profiles |

  All of these can be changed in System Options > Colors.

### 1.13 Colours, background and highlight

- **System Colors** ([System Colors Options](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_OPTIONS_SYSTEM_COLORS.htm)):
  - *Icon Colors* Default or Classic.
  - UI *Background* Light (default), Medium Light, Medium or Dark. This changes the chrome around
    the graphics area, not the graphics area itself.
  - *Current color scheme* Blue, Green or Orange highlight, or a saved custom scheme.
  - *Background appearance*: Use document scene background / Plain (Viewport Background colour) /
    Gradient (Top Gradient Color → Bottom Gradient Color) / Image file.
  - Pattern instances highlight in *Selected Item 1* and the seed in *Selected Item 2*.
  - The colour list also includes sketch status colours, dimension colours, drawing paper colours
    and more.
- **Default viewport:** a subtle light gradient, near-white to light blue-grey, from the default
  scene. Dassault does not publish exact RGB values *(community: [Javelin](https://www.javelin-tech.com/blog/2022/12/solidworks-background-colors/))*.
- **Default part colour:** the default appearance is a neutral light grey with a slight blue tint
  ("color" appearance). The exact RGB is *(unverified)*.
- **Selection highlight:** with the default *Blue* scheme, selected faces and edges show in
  light/medium blue and pre-selection (hover) shows in orange-ish or light highlight *(unverified exact values)*.
  Interference results highlight in red
  ([Interference Detection PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_INTERFERENCE.htm)).
- **Editing a component in an assembly:** the component being edited shows in its own colour and
  the others go transparent or grey
  ([Colors When Editing a Component](https://help.solidworks.com/2025/english/SolidWorks/sldworks/t_Colors_When_Editing_a_Component.htm)).

---

## 2. Feature inventory

Each line gives a one-line description followed by its key options. The source link is the help
page that was read.

### 2.1 Sketch

**Entities** ([Sketch Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_sketch_toolbar.htm),
[Sketch Entities](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_sketch_entities_top.htm)):

| Entity | Description / key options |
|---|---|
| Line | Line; chains by default. Orientation: As sketched / Horizontal / Vertical / Angle; *For construction*; *Infinite length*; *Midpoint line* variant. |
| Centerline | Construction line; the axis for revolves and mirrors; also drives diameter dimensions for revolves. |
| Midpoint Line | Line symmetric about its first click. |
| Rectangle | Corner, Center, 3 Point Corner, 3 Point Center, Parallelogram; option to add construction diagonals. |
| Slot | Straight, Centerpoint Straight, 3 Point Arc, Centerpoint Arc; *Add dimensions*; overall length or center-to-center. |
| Circle | Center or Perimeter (3-point). |
| Arc | Centerpoint Arc, Tangent Arc (also reached by moving back to the endpoint while drawing lines), 3 Point Arc. |
| Polygon | 3–40 sides, inscribed or circumscribed construction circle. |
| Ellipse / Partial Ellipse | Center, major and minor axis; partial ellipse adds start and end angles. |
| Parabola | Focus, apex and endpoints. |
| Conic | Endpoints plus a Rho value (elliptic, parabolic or hyperbolic). |
| Spline | Through-point spline, *Style Spline* (Bezier control polygon), *Spline on Surface*, *Equation Driven Curve* (explicit y=f(x) or parametric), *Fit Spline*. |
| Point | Sketch point; also *Segment* (equal segments on arcs and circles). |
| Text | Sketch text with font, along a curve, flip and spacing; used for emboss and deboss. |
| Construction Geometry | Toggles any entity to construction. |
| Sketch Fillet / Sketch Chamfer | Corner round or chamfer, keeping a virtual sharp and its dimensions. |
| Sketch Picture | Inserts an image with scale calibration and transparency; Autotrace add-in. |
| Blocks | Make, insert, edit and explode blocks; *Belt/Chain* layouts. |
| 3D Sketch / 3D Sketch On Plane | 3D lines, splines and points; Tab switches the sketch plane; relations such as AlongX, AlongY, AlongZ. |

**Tools** ([Sketch Tools](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_sketch_tools_top.htm),
[Spline Tools Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_spline_tools_toolbar.htm)):

| Tool | Description / key options |
|---|---|
| Trim Entities | Power trim (drag across), Corner, Trim away inside, Trim away outside, Trim to closest. |
| Extend Entities | Extends to the next intersection. |
| Offset Entities | Distance, *Add dimensions*, *Reverse*, *Select chain*, *Bi-directional*, *Cap ends* (arcs or lines), *Construction geometry* (base or offset). |
| Offset On Surface | Offsets 3D edges along a face. |
| Convert Entities | Projects model edges, loops, faces or external sketch curves into the sketch with an On Edge relation; *Select chain*; *Inner loops*. |
| Intersection Curve | Sketch curve where a plane, face or surface intersects the model. |
| Silhouette Entities | Projects the outline of bodies onto the sketch plane. |
| Face Curves | Iso-parametric U/V curves on a face. |
| Segment | Divides an entity into equal segments or points. |
| Mirror Entities / Dynamic Mirror | Mirrors about a centerline with a Symmetric relation; dynamic mirror copies as you draw. |
| Move / Copy / Rotate / Scale / Stretch Entities | From/To or X/Y deltas; *Keep relations*; copies. |
| Linear / Circular Sketch Pattern | Count, spacing, angle, skip instances; dimensions can be shown. |
| Split Entities | Splits at a point. |
| Jog Line | Adds a rectangular jog in a line. |
| Make Path | Joins a chain into a path used by Path mates and Belt. |
| Sketch Contours / Shaded Sketch Contours | Picks closed regions for features and shades closed regions. |
| Check Sketch for Feature | Validates a sketch for a feature type (open or closed, nested, self-intersecting) ([Check Sketch for Feature Usage](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_SKETCH_DIAGNOSTICS.htm)). |
| Repair Sketch | Fixes small gaps and overlaps. |
| Instant2D | Drag sketch dimensions on screen. |
| Rapid Sketch | Change the sketch plane on the fly. |
| SketchXpert | Diagnoses over-defined sketches and proposes sets of relations or dimensions to delete ([Resolving Over Defined Sketches](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Resolving_Over_Defined_Sketches.htm)). |
| Replace Entity | Swaps an entity while keeping its references. |
| Spline tools | Add Tangency/Curvature Control, Insert Spline Point, Insert Control Vertex, Simplify Spline, Fit Spline, Show Curvature Combs / Inflection Points / Minimum Radius, Convert to Style Spline, Display Control Polygon. |
| Sketch Ink / Pen | Freehand strokes turned into geometry (touch devices). |
| Sketch Numeric Input, No Solve Move, Detach Segment On Drag | Sketch behaviour toggles. |
| Derived / Shared sketch | A sketch linked to a parent sketch. |

**Relations** ([Description of Sketch Relations](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Description_of_Sketch_Relations.htm)):
Horizontal, Vertical, Collinear, Coradial, Perpendicular, Parallel, ParallelYZ, ParallelZX, AlongX,
AlongY, AlongZ (3D), Tangent, Concentric, Midpoint, Intersection, Coincident, Equal, Equal
Curvature, Symmetric, Fix, Fix Slot, Pierce, Merge Points, Doubled Distance, Equal Slots, On Edge,
On Plane, On Surface, Tangent to Face, Traction (belts), Torsion Continuity. Relations are added
automatically by inferencing and manually with **Add Relation**. **Display/Delete Relations**
lists each relation with its status (Satisfied, Dangling, Over Defining, Not Solved) and offers
*Replace*. A relation to a line applies to the infinite line, and a relation to an arc applies to
the full circle.

**Dimensions** ([Dimensions/Relations Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_dimensions_relations_toolbar_and_menus.htm)):
Smart Dimension, which infers linear, angular, radial, diameter or arc length from what you pick,
including min/max arc conditions and angles over 180°. Also: Horizontal and Vertical dimension,
Baseline, Chain, Ordinate (horizontal and vertical), Path Length, Angular Running, Chamfer,
Symmetric Linear Diameter (for revolves), Driven/Reference, **Fully Define Sketch** (adds
relations and dimensions from a chosen datum:
[Fully Defined Sketches](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Fully_Defined_Sketches.htm)),
Auto Insert Dimension, Isolate Changed Dimensions. The Modify box accepts equations, units and
global variables.

### 2.2 Reference geometry

Source: [Reference Geometry Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_reference_geometry_toolbar.htm).

| Item | Description / key options |
|---|---|
| Plane | Up to 3 references, each with a constraint: **Coincident, Parallel, Perpendicular, Project, Parallel to screen, Tangent, At angle, Offset distance** (with count for multiple planes), **Mid Plane**, Flip normal, *Set origin on curve*. Covers offset, angle, 3-point, normal-to-curve, tangent-to-surface and mid planes ([Plane PropertyManager](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_CREATE_PLANE.htm)). |
| Axis | One Line/Edge/Axis; Two Planes; Two Points/Vertices; Cylindrical/Conical Face; Point and Face/Plane. Temporary axes appear on every cylinder. |
| Coordinate System | Origin (vertex or point, or numeric X/Y/Z), axis directions from edges, faces or points, *Reverse*, numeric X/Y/Z rotation ([Coordinate System PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_COORD_SYS.htm)). |
| Point | Arc Center, Center of Face, Intersection, Projection, On point, Along curve distance (Distance / Percentage / Evenly Distribute with count); 2026 adds absolute XYZ values ([Point PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/hidd_dve_refpoint.htm)). |
| Center of Mass (COM) | Reference point that updates with the geometry; can be dimensioned to. |
| Mate Reference | Primary, secondary and tertiary entities with default mate types, for SmartMates when the part is dropped into an assembly ([Mate Reference PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_mate_reference_pm.htm)). |
| Bounding Box | Rectangular or Cylindrical; Best Fit or Custom Plane (2026: coordinate system); include hidden bodies and surfaces; writes custom properties ([Bounding Box PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_bounding_box_pm_parts.htm)). |
| Patterned planes/axes | 2025: linear and circular patterns can pattern planes and axes. |

### 2.3 Curves

Source: [Curves Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_curves_toolbar.htm).

| Curve | Description / key options |
|---|---|
| Split Line | Splits faces by **Projection** (sketch onto faces, single direction, reverse), **Silhouette** (pull direction and angle) or **Intersection** (bodies, faces or planes; split all, natural or linear). Used for parting lines, draft, face fillets and decals ([Split Lines](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_PLINE.htm)). |
| Projected Curve | *Sketch on faces* (with direction, reverse, bi-directional) or *Sketch on sketch* (two sketches on intersecting planes, making a 3D curve) ([Projected Curve PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_projected_curves_pm.htm)). |
| Composite Curve | Joins end-to-end edges and curves into one curve for sweep paths and guides ([Creating Composite Curves](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_COMPOSITE_CURVE.htm)). |
| Curve Through XYZ Points | Point table (typed or from a .sldcrv/.txt file); 2025 adds a PropertyManager with a coordinate-system choice. |
| Curve Through Reference Points | Spline through selected points and vertices, with a closed option. |
| Helix / Spiral | Defined by Pitch and Revolution, Height and Revolution, Height and Pitch, or Spiral. Constant or variable pitch (region table), reverse, start angle, Clockwise/Counterclockwise, taper angle and taper outward ([Helix/Spiral PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_HELIX.htm)). |

### 2.4 Boss/base and cut features

**Extruded Boss/Base, Extruded Cut, Extruded Surface** ([Extrude PropertyManager](https://help.solidworks.com/2025/english/solidworks/sldworks/r_extrude_propertymanager.htm),
[End Condition Extrude](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_end_condition_extrude.htm)):

- **From:** Sketch Plane / Surface/Face/Plane (planar or not; the sketch wraps onto a non-planar
  start) / Vertex / Offset.
- **Direction 1 end conditions:**
  - **Blind**: a depth.
  - **Through All**: through all existing geometry.
  - **Through All - Both**: through all geometry in both directions.
  - **Up To Next**: to the next surface that intercepts the *entire* profile, on the same part.
  - **Up To Vertex**: to a plane parallel to the sketch plane through the vertex. Sketch vertices are valid.
  - **Up To Surface**: to a face or plane. Double-clicking a surface sets this. Analytic faces can
    be extended automatically.
  - **Offset From Surface**: face or plane plus an offset distance, with *Translate surface* and *Reverse offset*.
  - **Up To Body**: to a solid or surface body; useful in assemblies and molds.
  - **Mid Plane**: the depth split equally in both directions.
- **Other Direction 1 options:** *Reverse Direction*; *Direction of Extrusion* (a vector, for
  extruding off the normal); *Flip side to cut* (cuts); *Normal cut* (sheet metal); *Merge
  result* (boss; clear it to make a separate body); *Link to thickness* (sheet metal); **Draft
  On/Off** with angle and *Draft outward*.
- **Direction 2:** the same options, independent of Direction 1.
- **Thin Feature:** One-Direction / Mid-Plane / Two-Direction thickness; *Auto-fillet corners*
  with radius (open sketches); *Cap ends* with cap thickness (first body only). Required for open
  profiles.
- **Selected Contours:** use some of a sketch's regions or open contours, and model edges.
- **Feature Scope:** All bodies, or selected bodies with *Auto-select* (multibody and assemblies).
- Numeric fields accept `=` equations.

**Revolved Boss/Base / Cut / Surface** ([Revolve PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_FEAT_REV.htm)):
Axis of Revolution (centerline, line or edge). End conditions for Direction 1 and 2: **Blind**
(angle), **Up to Vertex**, **Up to Surface**, **Offset from Surface**, **Mid-Plane**. Also
*Flip side to cut*, *Merge result*, Thin Feature (One-Direction, Mid-Plane, Two-Direction),
Selected Contours and Feature Scope.

**Swept Boss/Base / Cut / Surface** ([Swept Boss/Base PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_swept_boss_base_property_manager.htm)):
- Profile type: **Sketch Profile** or **Circular Profile** (diameter only, with no sketch).
  Swept cut adds **Solid Profile** (a tool body such as an end mill).
- Path: open or closed; can be Bidirectional, with Direction 1 / Direction 2.
- Guide Curves: Move Up/Down, *Merge smooth faces*, *Show Sections*.
- **Profile Orientation:** Follow Path / Keep Normal Constant.
- **Profile Twist:** None, Minimum Twist, Follow First Guide Curve, Follow First and Second Guide
  Curves, Specify Twist Angle (degrees, radians or revolutions), Specify Direction Vector, Tangent
  to Adjacent Faces, Natural.
- Merge tangent faces.
- Start/End Tangency: None, Path Tangent.
- Thin Feature, Feature Scope, Curvature Display (mesh, zebra, combs).

**Lofted Boss/Base / Cut / Surface** ([Loft PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_FEAT_LOFT.htm)):
- Profiles are ordered, with Move Up/Down; connectors can be dragged.
- **Start/End Constraints:** Default, None, Direction Vector, Normal to Profile, Tangency to Face,
  Curvature to Face, each with draft angle and tangent length; *Apply to all*.
- **Guide curves influence:** To next guide, To next sharp, To next edge, Global. Guide tangency:
  None, Normal to Profile, Direction Vector, Tangency to Face.
- **Centerline parameters:** centerline plus number of sections.
- Sketch tools: Drag Sketch, Undo sketch drag.
- Options: Merge tangent faces, Close loft, Show preview, Merge result, Micro tolerance.
- Thin Feature, Feature Scope, Curvature Display.

**Boundary Boss/Base / Cut / Surface** ([Boundary PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_boundary_pm.htm)):
- Curves in Direction 1 and Direction 2. Curve influence: Global, To next curve, To next sharp,
  To next edge, Linear.
- Tangent type: Default, None, Normal to Profile, Direction Vector, Tangency to Face, Curvature to
  Face; alignment, draft angle, tangent influence % and tangent length.
- Options: Merge tangent faces, Close surface, Trim by direction 1 and direction 2, Drag Sketch.
- Curvature display: mesh preview, zebra stripes, curvature combs.
- Gives higher quality than a loft when curves run in both directions.

**Thicken / Thickened Cut:** turns a surface body into a solid by adding thickness on side 1, side
2 or both; *Create solid from enclosed volume*
([Thicken](https://help.solidworks.com/2025/english/SolidWorks/sldworks/t_thicken_feature.htm)).
**Cut With Surface:** cuts a body with a surface or plane, with a flip option.

### 2.5 Applied features

**Fillet** ([Fillet PropertyManager](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_fillet_propertymanager.htm)) — there are two modes: *Manual* and *FilletXpert*, which has Add, Change and Corner tabs for constant fillets.

| Type | Key options |
|---|---|
| **Constant Size** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_constant_size_fillets.htm)) | Items: edges, faces, features, loops; selection toolbar; *Tangent propagation*; Full / Partial / No preview. Parameters: **Symmetric** (Radius, *Multiple radius fillet*) or **Asymmetric** (Distance 1 and 2, Reverse). Profile: **Circular, Conic Rho, Conic Radius, Curvature continuous** (Elliptic for asymmetric). Radius or chord length. **Setback Parameters** (distance, setback vertices, Set Unassigned / Set All). **Partial Edge Parameters** (start and end condition). Fillet Options: *Select through faces*, *Keep features*, *Round corners*, **Overflow type** (Default, Keep edge, Keep surface), *Omit attach edges*. |
| **Variable Size** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_Variable_Size_Fillet.htm)) | Attached radii at vertices; *Number of instances* (control points, each with its own radius and position %); Smooth or Straight transition; Symmetric or Asymmetric; profiles as above; setbacks; 2025 adds *Continuous edge blend*. |
| **Face** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_Face_Fillets.htm)) | Face Set 1 and Face Set 2 (not adjacent); Symmetric, **Chord Width**, Asymmetric or **Hold Line** (edges or split lines); *Constant width*; *Help point*; for surfaces, *Trim and attach* or *Don't trim or attach*. |
| **Full Round** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_Full_Round_Fillets.htm)) | Side Face Set 1, Center Face Set, Side Face Set 2; tangent across three faces. |

**Chamfer** ([Chamfer PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_chamfer_pm.htm)):
- Types: **Angle Distance**, **Distance Distance** (Symmetric or Asymmetric), **Vertex** (three
  distances, or *Equal distance*), **Offset Face** (solved by offsetting faces; *Multi Distance
  Chamfer*), **Face Face** (Symmetric, Asymmetric, **Chord width**, **Hold line**).
- Other options: *Tangent propagation*, Flip direction, **Partial Edge Parameters**, Repair
  Missing References, and options like the fillet's.

**Shell** ([Shells](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Shells_Folder.htm)):
thickness; faces to remove (none gives a hollow closed body); *Shell outward*; **Multi-thickness
faces**, each with its own thickness; *Show preview*. **Shell Feature Diagnostics** finds faces
that cannot offset and reports their minimum radius of curvature.

**Draft** ([Draft PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_DRAFT.htm)):
Manual or DraftXpert (Add and Change tabs, neutral plane only). Types: **Neutral Plane**,
**Parting Line**, **Step Draft** (Tapered or Perpendicular steps). Draft angle for Direction 1
and 2, or *Symmetrical draft*. Face propagation: None, Along Tangent, All Faces, Inner Faces,
Outer Faces. Direction of Pull. Parting lines with *Other Face*. *Allow reduced angle*. Detailed
preview.

**Rib** ([Rib PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_FEAT_RIB.htm)):
thickness on the First side, Both sides or Second side; thickness measured *At sketch plane* or
*At wall interface*; extrusion direction Parallel to Sketch or Normal to Sketch; Flip material
side; Draft On/Off with *Draft outward*; Type Linear or Natural (for Normal to Sketch); works
from an open sketch.

**Dome:** faces, distance, *Elliptical dome*, *Continuous dome*, reverse, constraint point or sketch.
**Wrap:** sketch wrapped onto a face as **Emboss**, **Deboss** or **Scribe**; method *Analytical*
or *Spline Surface*; depth and pull direction.
**Intersect:** creates solids from the regions where selected solids, surfaces and planes
intersect; *Create* or *Keep* regions; option to consume surfaces
([Intersect PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_FEAT_SCULPT.htm)).
**Scale:** about the centroid, origin or a coordinate system; uniform or X/Y/Z factors
([Scale PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_INSERT_SCALE.htm)).
**Indent, Flex** (Bending, Twisting, Tapering, Stretching with trim planes and triad),
**Deform** (Point, Curve to Curve, Surface Push), **Freeform** (control curves and points on a
face), **3D Texture** (bitmap to displacement on mesh). **Fastening features:** Mounting Boss,
Snap Hook, Snap Hook Groove, Vent, Lip/Groove. **Library features** and **Forming tools** come
from the Design Library.

### 2.6 Holes and threads

**Hole Wizard** ([Type PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_HIDD_DVE_HW_HOLE_SPEC.htm),
[Positions PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_HW_INSERT_HOLE.htm),
[Overview](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Hole_Wizard_Overview.htm)):

- **Type tab:**
  - *Favorites*: apply, add, update, delete, save or load.
  - Hole types: **Counterbore, Countersink, Hole, Straight Tap, Tapered Tap, Legacy Hole,
    Counterbore Slot, Countersink Slot, Slot**.
  - **Standard**: ANSI Inch, ANSI Metric, AS, BSI, DIN, GB, IS, ISO, JIS, KS, PEM, DME, Helicoil,
    Hilti, Progressive, Superior…
  - **Type** (fastener type), **Size**, **Fit** (Close, Normal, Loose), *Show custom sizing*.
  - **End Condition:** Blind, Through All, Up To Next, Up To Vertex, Up To Surface, Offset From
    Surface. Depth to shoulder or to tip, with *auto-calculate depth*.
  - **Options:** Head clearance, Near side countersink, Under head countersink, Far side
    countersink, Cosmetic thread (with or without thread callout), *Thread class*.
- **Positions tab:** place points on planar or non-planar faces, then locate them with dimensions,
  relations and inference lines. One Hole Wizard feature holds one hole type and many points.
- The result is a 2-sketch feature (position sketch plus profile sketch). **Hole callouts** read
  its parameters.

**Advanced Hole** ([Advanced Hole Type PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_advanced_hole_type_pm.htm)):
a stack of elements on the Near Side and Far Side (Counterbore, Countersink, Tapered Tap, Hole,
Straight Tap). Elements can be inserted above or below, deleted, and the stack reversed. Each
element has its own Standard, Type, Size and End Condition: Blind, Through All, Up To Next, Up To
Next Element, Offset From Surface, Up To Selection. Also *Use baseline dimensions*, customisable
callouts and Favorites.

**Hole Series** (assemblies), **Simple Hole** (legacy), **Stud Wizard** (a stud on a cylinder or
a new stud).

**Thread** ([Thread PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_thread_propertymanager.htm)):
- Location: an edge of a cylinder, an optional start face, offset and start angle.
- End Condition: Blind, Revolutions, Up to Selection; *Maintain thread length*.
- Specification: Type and Size from thread profile library parts, Override Diameter and Pitch,
  **Cut Thread / Extrude Thread**, mirror profile, rotation angle, locate profile.
- Options: Right- or Left-hand, **Multiple Start**, Trim with start face or end face.
- Preview: Shaded, Wireframe or Partial.
- Makes real helical geometry.

**Cosmetic Thread** ([Cosmetic Threads PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_CTHREAD.htm)):
circular edge; Standard, Type and Size; Minor, Major or Conical offset diameter; End condition
Blind, Through or Up to Next; thread callout text; configurations; *Show type*; layer. It is
drawn as a texture or dashed circle and appears in drawings with the ANSI or ISO convention.

### 2.7 Patterns and mirror

| Pattern | Description / key options |
|---|---|
| **Linear** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/t_Linear_Patterns_Overview.htm)) | Direction 1 and 2 (edge, axis, dimension, face or plane), reverse; **Spacing and instances** or **Up to reference** (reference geometry, offset distance, Centroid or Selected reference, seed reference); Direction 2 *Symmetric* or *Pattern seed only*; items: Features and Faces / Bodies / Reference geometry (planes and axes, 2025); **Instances to Skip**; **Instances to Vary** (spacing or dimension increments per instance); Options: *Vary sketch*, *Geometry pattern*, *Propagate visual properties*, Full or Partial preview; Feature Scope. |
| **Circular** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_CPATTERN.htm)) | Axis (axis, circular or linear edge, cylindrical or revolved face, angular dimension); **Equal spacing** (total angle) or instance angle; number of instances; Direction 2 (Symmetric); features, faces, bodies, planes and axes; Instances to Skip; Instances to Vary; Options (Vary sketch, geometry pattern, propagate visuals); Feature Scope. |
| **Curve Driven** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/t_Curve_Driven_Pattern_Overview.htm)) | Along an edge or sketch curve; Equal spacing or spacing; Curve method *Transform curve* / *Offset curve*; Alignment *Tangent to curve* / *Align to seed*; face normal for 3D curves; two directions. |
| **Sketch Driven** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_PATTERN_BY_SKETCH.htm)) | Instances at sketch points; reference point Centroid or Selected point; Geometry pattern; Propagate visual properties. |
| **Table Driven** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_PATTERN_TABLE2.htm)) | X-Y coordinate table (typed, or read from a .sldptab or .txt file) relative to a coordinate system; reference point Centroid or selected point. |
| **Fill** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_AREA_FILL_PATTERN.htm)) | Fills a face or sketch boundary. Layout: **Perforation** (spacing, stagger angle), **Circular**, **Square** or **Polygon** (loop spacing, target spacing or instances per loop/side), margins, direction, *Validate count*. Seed: an existing feature or a *Create seed cut* (Circle, Square, Diamond, Polygon). |
| **Variable** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_variable_pattern_property_manager.htm)) | Each instance's dimensions and reference geometry come from a pattern table (Excel-like); failed instances are listed. |
| **Chain** (assembly) ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_chain_pattern_pm.htm)) | Components along a closed or open path; Distance, Distance Linkage or Connected Linkage. |
| **Mirror** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_FEAT_MIRROR.htm)) | Mirror face or plane, optional secondary plane (perpendicular, with *Mirror seed only*); Features / Faces / Bodies; *Geometry Pattern*, *Merge solids*, *Knit surfaces*, *Propagate visual properties*; Feature Scope. Also *Mirror Part* (opposite-hand derived part) and *Mirror Components*. |
| Cosmetic Pattern | Texture-only pattern on faces. |

### 2.8 Multibody and direct editing

- **Combine:** **Add**, **Subtract** (main body plus bodies to subtract, *Make main body
  transparent*) or **Common**
  ([Combine PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_FEAT_COMBINE_BODIES.htm)).
- **Split:** trim tools (planes, faces, sketches) cut bodies into pieces, which can be saved as
  parts with *Consume cut bodies*
  ([Split and Save Bodies](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_FEAT_SPLIT.htm)).
- **Move/Copy Body:** Copy with number of copies; Translate (reference, ΔX/ΔY/ΔZ, distance, to
  vertex); Rotate (axis, or origin plus X/Y/Z angles); triad; **Constraints mode** with
  mate-style constraints; values can be equations or configurations
  ([Move/Copy Body PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/t_move_copy_body_pm_features.htm)).
- **Delete/Keep Body:** delete or keep the selected bodies.
- **Insert Part** (a derived part, with transfer options), **Insert into New Part**, **Save
  Bodies**, **Make Multibody Part**, **Body folders** and the **Cut List** (weldments and sheet metal).
- **Direct Editing tab:**
  - **Move Face**: Offset, Translate, Rotate
    ([Move Face](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_FEAT_MOVE_FACE.htm)).
  - **Delete Face**: Delete, Delete and Patch, Delete and Fill
    ([Delete Face](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DELETE_FACE.htm)).
  - **Delete Hole**, **Replace Face**, **Offset Surface**, **Heal Edges**, **Simplify/Defeature**
    (2025 adds the Silhouette method).
  - **Import Diagnostics** (heal faces and gaps:
    [Import Diagnostics PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_HEALING.htm)).
  - **FeatureWorks** (Recognize Features: automatic or interactive extrude, revolve, fillet,
    chamfer, hole, pattern and so on) and **Instant3D**.
- **Mesh:** import STL/OBJ/3MF as mesh BREP or graphics bodies; **Segment Mesh**; **Convert Mesh
  to Standard BREP** (2025; 2026 can force conversion); **Surface From Mesh**.

### 2.9 Surfaces

Source: [Surfaces Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_surfaces_toolbar.htm).

| Surface tool | Description / key options |
|---|---|
| Extruded / Revolved / Swept / Lofted / Boundary Surface | As for the solid versions; open profiles allowed; *Cap end* for extrudes. |
| Planar Surface | Fills a closed planar boundary. |
| Filled Surface | N-sided patch; each edge Contact, Tangent or Curvature; constraint curves; *Optimize surface*; *Merge result*; *Try to form solid* ([Filled Surface](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Filled_Surface.htm)). |
| Offset Surface | Offset distance (0 gives a copy). |
| Radiate Surface | Radiates from a parting line parallel to a plane (molds). |
| Ruled Surface | Tangent to surface, Normal to surface, Tapered to vector, Perpendicular to vector, Sweep. |
| Knit Surface | Joins surfaces; *Create solid*; *Merge entities*; gap control (tolerance). |
| Extend Surface | Distance or up to point/surface; Same surface or Linear. |
| Trim Surface | Standard (a tool trims) or Mutual; keep or remove selections; split all. |
| Untrim Surface | Extends to natural boundaries or fills holes. |
| Delete Face / Delete Hole / Replace Face | Surface and direct editing. |
| Mid-Surface | Mid-faces from face pairs (for FEA). |
| Surface Flatten | Develops a surface to flat, with relief cuts. |
| Parting Surface / Shut-off Surfaces | Mold tools (§2.12). |
| Thicken, Cut With Surface | See §2.4. |
| Surface From Mesh | Fits surfaces to mesh facets. |

### 2.10 Sheet metal

Source: [Sheet Metal Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_sheet_metal_toolbar.htm).

- **Base Flange/Tab:** thickness, bend radius and gauge table; bend allowance (K-factor, bend
  allowance, bend deduction, bend table, bend calculation); auto relief (rectangular, tear,
  obround with ratio).
- **Edge Flange:** length (Blind, Up to Vertex; inner, outer or tangent virtual sharp), flange
  position (Material Inside, Material Outside, Bend Outside, Bend from Virtual Sharp, Tangent to
  Bend), trim side bends, offset, custom profile, and 2026 **offset flanges**.
- **Miter Flange, Hem** (Closed, Open, Tear Drop, Rolled), **Jog**, **Sketched Bend**,
  **Cross-Break**, **Swept Flange**, **Lofted-Bend** (Formed or Bent).
- **Closed Corner**, **Welded Corner**, **Break-Corner/Corner-Trim** (chamfer or fillet, relief
  types), **Corner Relief**, and 2026 **quick corner break**.
- **Tab and Slot**, **Normal Cut**, **Forming Tool**, **Vent**, **Stamp**, **Gusset**, **Bend Notch**.
- **Convert to Sheet Metal**, **Insert Bends**, **Rip**, **Unfold / Fold**, **Flatten** (flat
  pattern with bend lines, bend notes and grain direction), **No Bends**.
- Flat pattern export to DXF/DWG; the cut list holds bounding-box properties.

### 2.11 Weldments

Source: [Weldments Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_weldments_toolbar.htm).

- **Weldment** feature: turns the part into a weldment and creates a cut list.
- **Structural Member:** standard (ANSI, ISO), type and size; groups; corner treatment (end miter,
  end butt 1 and 2); gap; mirror and rotate profile; locate profile (pierce point); merge
  arc-segment bodies
  ([Structural Member PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_FEAT_WELD_MEMBER.htm)).
- **Structure System** (primary and secondary members from points, lengths or planes, with corner
  management; improved in 2026).
- **Trim/Extend, End Cap, Gusset, Fillet Bead, Weld Bead**.
- **Cut List** folders with properties (length, angles, description; 2026 adds properties that work
  with PLM/ERP) and **cut list tables** in drawings.

### 2.12 Mold tools

Source: [Mold Tools Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_mold_tools_toolbar.htm).

Draft Analysis, Undercut Analysis, Parting Line Analysis, **Scale** (shrink factor), **Parting
Lines** (direction of pull, angle), **Shut-off Surfaces** (Contact, Tangent, No fill),
**Parting Surfaces** (Tangent to surface, Normal to surface, Perpendicular to pull; smoothing),
**Tooling Split** (block sketch, core and cavity depths, interlock surfaces), **Core** (core
pins), **Cavity** (assembly), Insert Mold Folders, Ruled Surface, Radiate Surface, Split Line,
Draft, Move Face, Knit, Planar and Filled Surface.

### 2.13 Parameters: equations, global variables, configurations, design tables

- **Equations dialog** ([Equations](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_EQUATION_MANAGER.htm),
  [Global Variables](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_global_variables.htm)):
  - Three views: Equation View, Sketch Equation View, Dimension View, plus an Ordered View.
  - **Global variables**, e.g. `"Height" = "Well_Volume"/(pi*("D1@Sketch4"/2)^2)`.
  - Dimension equations (`"D1@Boss-Extrude1" = "Height"`) and feature suppression
    (`"Fillet1" = "suppressed"` with IIF).
  - Functions: sin, cos, tan, sec, cosec, cotan, arcsin, arccos, atn, arcsec, arccosec, arccotan,
    abs, exp, log, sqr, int, sgn, **iif**, max, min, pi, **mass properties** functions and file properties.
  - Units in expressions; configure equations per configuration; link to an external .txt file;
    import and export.
  - `=` can be typed in any numeric PropertyManager field or in the Modify dialog.
- **Linked values / shared values**, which are being replaced by global variables.
- **Configurations**
  ([Configurations](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Configurations_Overview.htm)):
  - Manual, design table or derived (child) configurations.
  - What can be configured: dimensions, suppression state, equations, material, colour,
    component configuration and suppression, custom properties, part number, sketch relations,
    cosmetic threads, and more.
  - The **Configuration Table** edits parameters for all configurations in a grid.
  - **Display States** hold appearance and visibility and can be linked to a configuration.
  - 2026: **split configurations out into individual files**.
- **Design tables:** an embedded or linked Excel sheet. Rows are configurations; columns are
  parameters such as `D1@Sketch1`, `$STATE@Feature`, `$PRP@Property`, `$COLOR`, `$PARENT`,
  `$Enable@<id>@Equations`
  ([Design Tables and Equations](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_equations_and_design_tables.htm)).
- **Sensors:** Mass Properties, Dimension, Measurement, Costing Data, Sheet Metal Bounding Box,
  Interference Detection and Proximity (assemblies), Simulation Data. Each can alert when out of
  limits, and the Sensors folder is flagged
  ([Sensors](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Sensors_oh.htm)).
- **Custom properties:** file and configuration properties, the Property Tab Builder, and linked
  values in notes and title blocks.

### 2.14 Materials, appearances, scenes

- **Material:** right-click Material → Edit Material. The library holds metals, plastics and so on
  with density, E, ν, yield, thermal properties, cross-hatch pattern and appearance. Custom
  libraries (.sldmat) and per-configuration materials are supported. The material drives mass
  properties, Simulation and the Sustainability tool
  ([Materials](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_materials_overview.htm)).
- **Appearances:** can be applied at face, feature, body, part or component level, with that
  order of precedence. The PropertyManager has Color/Image, Mapping, Illumination and Surface
  Finish tabs. Appearance classes include plastic, metal, painted, rubber, glass, light sources,
  organic, stone and so on
  ([Appearances](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_appearances_overview.htm)).
- **Decals:** an image mapped onto faces.
- **Scenes:** background (plain, gradient, image, environment), floor and HDR environment
  lighting. Set the default scene from the Task Pane. **RealView**, **Shadows**, **Ambient
  Occlusion** and **Perspective** are toggled in View Settings
  ([Scenes](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_Scenes.htm)).
- **Lights** (ambient, directional, point, spot) and **cameras** are managed in the DisplayManager.

### 2.15 Assemblies

Source: [Assembly Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_assembly_toolbar.htm).

- **Mates**
  ([Mate PM – Standard](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_NEW_ADD_MATE.htm),
  [Advanced Mates](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_advanced_mates.htm),
  [Mechanical Mates](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_mechanical_mates.htm)):
  - *Standard:* Coincident, Parallel, Perpendicular, Tangent, Concentric (with *Lock rotation*),
    Lock, Distance, Angle.
  - *Advanced:* Profile Center, Symmetric, Width, Path (with pitch, yaw and roll control),
    Linear/Linear Coupler, Limit Distance, Limit Angle.
  - *Mechanical:* Cam-Follower, Slot, Hinge, Gear, Rack and Pinion, Screw, Universal Joint.
  - Mate alignment: Aligned or Anti-Aligned.
  - Multiple mate mode and Multi-Mate folders; *Analysis* tab (mate properties for Motion).
  - **SmartMates** (Alt-drag), **Quick Mates** context toolbar, **Magnetic Mates** (Asset
    Publisher), **Mate References**, **Mate Controller**, **MateXpert / auto-repair mates**,
    **Copy with Mates**.
- **Components:** insert (with or without an origin), new part, new assembly (virtual), rigid or
  flexible subassemblies, Replace Components, Make Smart Component, **Smart Fasteners** and the
  **Toolbox** library (2026: fastener automation), SpeedPak, Lightweight / Resolved / Large
  Assembly Mode / Large Design Review, **Selective Open** (2026: selective loading), Envelope
  Publisher, Defeature.
- **Patterns:** Linear, Circular, Pattern Driven, Sketch Driven, Curve Driven, Chain; **Mirror
  Components** (opposite-hand); **Belt/Chain**.
- **Movement:** Move and Rotate Component (free drag, along an entity, by delta XYZ, to XYZ
  position, collision detection, physical dynamics, dynamic clearance), triad, Temporary Fix/Group.
- **Exploded views:** Regular steps (triad drag; distance and angle; auto-space; rotate about the
  component origin), Radial steps, sub-assembly explode, **Explode Lines** (smart explode lines or
  sketched lines), animate collapse and explode
  ([Explode PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_EXPLODE.htm)).
  Multibody parts can also be exploded.
- **Evaluation:**
  - **Interference Detection** (components to check, excluded components, results by interference
    or by component, ignore, save to Excel; options such as *Treat coincidence as interference*,
    *Treat subassemblies as components*, *Include multibody part interferences*, fasteners
    folder, hide transparency)
    ([Interference Detection PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_INTERFERENCE.htm)).
  - **Clearance Verification** ([PM](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_CLEARANCE.htm)).
  - **Hole Alignment**, Assembly Visualization, AssemblyXpert and Performance Evaluation.
  - **Large displacement warnings** (2026).
- **In-context design:** Edit Component; external references (lock, break, list); assembly
  features (cut, hole, fillet, weld bead); **Layout** sketches and blocks; Treehouse; Pack and Go.

### 2.16 Drawings

Sources: [Drawing Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_drawing_toolbar.htm),
[Annotation Toolbar](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_annotations_toolbar.htm).

- **Sheets and formats:** multiple sheets; sheet formats and title blocks with property links;
  sheet scale; drafting standards (ANSI, ISO, DIN, JIS, BSI, GOST, GB) set in Document Properties.
- **Views:**
  - Standard 3 View, Model View, **Projected**, **Auxiliary**.
  - **Section** (Section View Assist: horizontal, vertical, auxiliary or aligned cutting line,
    offsets, half sections; partial section; slice; excluded components; emphasize outline)
    ([Section View PM (Drawings)](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_DVE_SECTION_PROP.htm)).
  - **Removed Section**, **Detail** (circle or profile; connected or broken), **Broken-out
    Section**, **Break** (zig-zag, curved, small or large jagged cut), **Crop**, **Alternate
    Position**, Relative View, Predefined View, Empty View, 3D drawing view.
  - Flat pattern and exploded views; **View Palette**.
  - Display modes: HLR, HLV, wireframe, shaded, tangent edges.
- **Annotations:**
  - Model Items (import sketch and feature dimensions); **Smart Dimension** and all dimension
    types; **DimXpert** for drawings; Auto Arrange Dimensions; dimension palette.
  - Note (linked properties); **Balloon, Auto Balloon, Stacked Balloon**; Surface Finish; Weld
    Symbol; **Geometric Tolerance** (feature control frame); Datum Feature; Datum Target.
  - Hole Callout, Center Mark (single, linear, circular), Centerline, Cosmetic Thread, Revision
    Symbol, Revision Cloud, Area Hatch/Fill, Blocks, Magnetic Line, Multi-jog Leader, Dowel Pin
    Symbol, Caterpillar, End Treatment, Location Label, Linear and Circular Note Patterns.
  - Layers; Format Painter; tolerance and precision display (bilateral, limit, fit, basic and so on).
- **Tables:** **Bill of Materials** (Top-level only, Parts only, Indented; custom columns;
  equations; balloons linked; BOM in the assembly too), Hole Table, Revision Table, General
  Table, Bend Table, Punch Table, Weld Table, Weldment Cut List table, Design Table, Title Block Table.
- **Tools:** Design Checker, Compare Drawings, Detailing Mode, Auto-Generate Drawings (2026 SP4
  beta: creates sheets with views and proposed dimensions), Save as PDF / DXF / DWG.

### 2.17 Evaluate tools

| Tool | Description / key options |
|---|---|
| **Measure** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_MEASURE.htm)) | Distance, angle, radius, length, area and perimeter from up to 6 selections. Arc/circle mode: Center to Center, Minimum, Maximum or Custom distance. Units/Precision. *Show XYZ measurements* (dX, dY, dZ). **Point-to-Point** mode. Relative to part origin or a coordinate system. *Projected on* None, Screen or a selected plane. Measurement History. **Create Sensor**. Pin; quick copy. Results also show in the status bar. |
| **Mass Properties** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_MASSPROPERTY_TEXT_DLG.htm)) | Density, mass, volume, surface area, centre of mass, principal axes and moments, moments and products of inertia (at the centroid, and at the output coordinate system), in positive or negative tensor notation. *Override Mass Properties*; include hidden bodies; *Create Center of Mass feature*; report relative to a coordinate system; per-body or per-selection; copy and print. |
| **Section Properties** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_section_properties.htm)) | Area, centroid, area moments of inertia and polar moment for planar faces, section faces or sketches lying in parallel planes. |
| **Check** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/HIDD_CHECK_ENTITY.htm)) | Stringent solid/surface check; checks All, Selected items or Features. Finds invalid faces and edges, short edges, open surfaces, minimum radius of curvature, maximum edge gap and maximum vertex gap. |
| **Geometry Analysis** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_geometry_analysis_overview.htm)) | Finds sliver faces, small faces, short edges, knife edges and vertices, and discontinuous edges and faces, against set thresholds. |
| **Draft Analysis** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/r_draft_analysis.htm)) | Direction of pull, reference draft angle, adjustment triad, *Face classification*, *Find steep faces*, gradual transition. Colours for positive draft, negative draft, requires draft and straddle faces, each with hide/show and editable colour. |
| **Undercut Analysis** | Direction of pull or parting line; colour classes for direction 1 undercut, direction 2 undercut, occluded undercut, straddle and no undercut. |
| **Parting Line Analysis** | Finds candidate parting lines. |
| **Thickness Analysis** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_thickness_analysis.htm)) | Target thickness; show thin or thick regions; colour bands; reports. |
| **Zebra Stripes** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_zebra_stripes.htm)) | Stripe count, width and precision, direction, colour; shows continuity (G0, G1 or G2) between faces. |
| **Curvature** ([page](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_curvature.htm)) | Colour map of Gaussian or mean curvature; curvature scale. Also **Surface Curvature Combs** and spline curvature combs. |
| **Deviation Analysis** | Angular deviation between faces along shared edges; sample points. |
| **Symmetry Check** | Symmetric, asymmetric and unique faces about a plane. |
| **Interference Detection (bodies)** | For multibody parts and assemblies (see §2.15). |
| **Import Diagnostics** | Faulty faces and gaps; heal. |
| **Compare** | Documents, Features, Geometry, BOMs; 3D PMI Compare. |
| **Performance Evaluation** | Rebuild time per feature. |
| **DFMXpress, Costing, Sustainability, SimulationXpress, FloXpress, Design Checker** | Add-on analyses (Tools toolbar). |

### 2.18 Import / export

Source: [File Types](https://help.solidworks.com/2025/english/SolidWorks/sldworks/c_File_Types.htm).

| Format | Direction / notes |
|---|---|
| Native | .sldprt, .sldasm, .slddrw; templates .prtdot, .asmdot, .drwdot; .sldlfp (library feature), .sldblk, .sldmat, .sldclr, .sldcrv, .sldptab. |
| **STEP** (.step/.stp) | Import and export; AP203, AP214 (body, face and curve colours) and **AP242** (PMI export, custom properties); import of STEP configuration data. |
| **Parasolid** (.x_t, .x_b) | Import and export; the native kernel format. |
| IGES (.igs/.iges) | Surfaces and BREP solids, in and out. |
| ACIS (.sat) | In and out, with colours, curves and wireframe. |
| DXF / DWG | 2D in (to a sketch or drawing) and out (drawings, sheet-metal flat patterns, faces); DXF 3D import. |
| STL, OBJ, OFF, PLY, PLY2, 3MF, VRML (.wrl) | Mesh import (graphics body, solid or surface body); STL, 3MF and AMF export for 3D printing; PLY export. |
| glTF / GLB | Extended-reality import and export. |
| PDF / 3D PDF | Drawings to PDF; parts and assemblies to 3D PDF (MBD). |
| Images | JPEG, PNG, TIFF, PSD, Adobe Illustrator (.ai). |
| eDrawings (.eprt, .easm, .edrw), 3D XML, HCG, HOOPS (.hsf), XPS, SMG (Composer) | Export. |
| IFC 2x3 / IFC 4 | Export (and import). |
| VDAFS (.vda) | Surfaces. |
| Rhino (.3dm) | Import. |
| CATIA V5 (.CATPart, .CATProduct) | Import (Premium); CATIA graphics export. |
| Creo / Pro/E, NX / Unigraphics, Solid Edge, Inventor, CADKEY, Mechanical Desktop | Import, often Parasolid-based (without features); Creo export. |
| IDF (.emn, .brd…) | PCB import through CircuitWorks. |
| JT | Import and export in recent releases *(unverified for 2025; not on the File Types page read)*. |
| Import behaviours | 3D Interconnect (associative link to native third-party files), Import Diagnostics, FeatureWorks recognition, 2026 background import processing. |

---

## 3. Recent changes (2025 / 2026)

- **2025**
  ([What's New – Parts](https://help.solidworks.com/2025/English/WhatsNew/c_wn_parts.htm),
  [Top Enhancements](https://help.solidworks.com/2025/english/WhatsNew/c_wn2025_top_enhancements.htm),
  [Fundamentals](https://help.solidworks.com/2025/english/WhatsNew/c_wn_fundamentals.htm)):
  - Z-up templates.
  - Defeature Silhouette method.
  - Patterning of reference planes and axes.
  - Repair of dangling relations.
  - Convert Mesh BREP to Standard BREP.
  - Segment Mesh improvements.
  - Move/Copy Body equations and configurations.
  - Continuous edge blend for variable fillets.
  - Curve Through XYZ Points PropertyManager with a coordinate system.
  - Esc cancels long Combine, Intersect and Split operations (SP2).
  - Pinning of the Fillet and Chamfer PropertyManagers (SP2).
  - Hole Wizard keeps its sketch options (SP3).
- **2026**
  ([What's New – Parts](https://help.solidworks.com/2026/English/WhatsNew/c_wn_parts.htm),
  [Top Enhancements](https://help.solidworks.com/2026/english/WhatsNew/c_wn2026_top_enhancements.htm),
  [SOLIDWORKS blog](https://blogs.solidworks.com/solidworksblog/2025/10/whats-new-in-solidworks-2026-design.html)):
  - Reference points by XYZ values.
  - Bounding box defined by a coordinate system.
  - Geometry pattern turned on automatically for fill, table and sketch patterns of cuts and holes.
  - Esc cancels long pattern, fillet and chamfer operations.
  - Hole Wizard accuracy and performance fixes.
  - Sheet-metal offset flanges and quick corner breaks.
  - Structure-system corner treatments.
  - Configurations split out into individual files.
  - Selective loading of large assemblies and large displacement warnings.
  - Fastener automation.
  - Auto-Generate Drawings (beta).
  - Better command search with custom keywords.

---

## 4. Priority for Forge

The table below is ordered by how often each item comes up in typical part modelling (single
parts, then simple multibody and drawings). The ranking is my judgement, based on the typical
model structure seen in SOLIDWORKS training, the default toolbar layout (commands placed first
on the Features and Sketch tabs) and my own experience. It is not a measured statistic.

**Forge status** comes from `FEATURES.md` on 2026-09-23:
- **Have (partial)** means `in progress`, in the sense of the SPEC: it works at kernel or sketch
  level but is not yet a parametric feature-tree item.
- **Missing** means `not started`.

No part-modelling item is `done` yet. The `done` rows in FEATURES.md are platform rows such as
the kernel, command bus and MCP.

| # | SOLIDWORKS item | Forge ID(s) | Forge status |
|---|---|---|---|
| 1 | Sketch: line, centerline, rectangle, circle, arc, slot, polygon, point | `7.1/entities/*` | Have (partial): solver, save/load; no feature tree; 3-point-arc slot missing |
| 2 | Smart Dimension (linear, angular, radial, diameter) | `7.1/dimensions/smart-dimension/*` | Have (partial): typed dimensions; no UI picking; arc length and path length missing |
| 3 | Sketch relations (coincident, H/V, parallel, perpendicular, tangent, equal, concentric, midpoint, symmetric, fix) | `7.1/relations/*` | Have (partial); intersection and equal curvature missing |
| 4 | Sketch on a planar face / reference plane | `7.1/tools/sketch-on-face-surface` | **Missing** |
| 5 | Extruded Boss/Base, Blind and Mid Plane | `7.2/boss-base-and-cut/extrude{,/blind,/mid-plane}` | Have (partial): kernel-level only; not parametric |
| 6 | **Extruded Cut** plus end conditions Through All, Up To Next/Vertex/Surface, Offset From Surface | `7.2/boss-base-and-cut/extrude/through-all`, `…/up-to-next-vertex-surface-offset` | **Missing** |
| 7 | FeatureManager tree: rollback, reorder, suppress, edit feature, rebuild | `P/feature-tree`, `P/persistent-naming` | **Missing** (planned M2) |
| 8 | Fillet: constant size | `7.2/applied/fillet/constant` | Have (partial): kernel-level, transient edge IDs |
| 9 | Chamfer (distance-distance, angle-distance) | `7.2/applied/chamfer/*` | **Missing** |
| 10 | Hole Wizard (counterbore, countersink, straight, tapped; ANSI and ISO) | `7.2/applied/hole-wizard/*` | **Missing** |
| 11 | Reference Plane (offset, angle, 3-point, mid plane, normal to curve) | `7.2/reference-geometry/planes` | **Missing** |
| 12 | Revolved Boss/Base | `7.2/boss-base-and-cut/revolve` | Have (partial): kernel-level |
| 13 | Revolved Cut | (within `…/revolve`) | **Missing** |
| 14 | Mirror feature / face / body | `7.2/patterns-and-mirror/mirror/*` | **Missing** |
| 15 | Linear Pattern | `7.2/patterns-and-mirror/linear` | **Missing** |
| 16 | Circular Pattern | `7.2/patterns-and-mirror/circular` | **Missing** |
| 17 | Convert Entities | `7.1/tools/convert-entities` | **Missing** |
| 18 | Offset Entities | `7.1/tools/offset/*` | Have (partial): no arc-join or ellipses |
| 19 | Trim / Extend / Split | `7.1/tools/trim`, `…/extend`, `…/split-entities` | Have (partial): corner and inside/outside trim missing |
| 20 | Sketch mirror / sketch patterns / move-copy-rotate | `7.1/tools/mirror`, `…/linear-circular-sketch-patterns`, `…/move-copy-rotate-scale-stretch` | Have (partial): dynamic mirror and stretch missing |
| 21 | Sketch fillet / chamfer | `7.1/entities/fillet-chamfer` | Have (partial) |
| 22 | Shell (uniform; multi-thickness) | `7.2/applied/shell{,/multi-thickness}` | **Missing** |
| 23 | Material assignment (density drives mass) | `7.2/materials-database` | **Missing** (mass properties takes a density parameter) |
| 24 | Measure | `7.12/measure` | Have (partial): body↔body minimum distance only |
| 25 | Mass Properties | `7.12/mass-properties` | Have (partial): no materials or overrides |
| 26 | Extrude options: Thin Feature, Draft, Direction 2, Selected Contours | `…/extrude/thin-feature`, `…/draft`, `…/direction-2`, `…/contour-selection` | **Missing** |
| 27 | Equations / global variables / linked dimensions | `P/parameters`, `7.1/dimensions/equations-in-dimension-fields` | **Missing** |
| 28 | Cosmetic Thread | `7.2/applied/cosmetic-thread` | **Missing** |
| 29 | Draft (neutral plane) | `7.2/applied/draft/neutral-plane` | **Missing** |
| 30 | Rib | `7.2/applied/rib` | **Missing** |
| 31 | Reference Axis, Coordinate System, Point | `7.2/reference-geometry/{axes,coordinate-systems,points}` | **Missing** |
| 32 | Appearances (part/face colour) | `7.2/appearances` | **Missing** |
| 33 | Section View (model) | (render: `P/mcp-vision` section parameter) | **Missing** (section parameter pending) |
| 34 | Configurations | `P/parameters` | **Missing** |
| 35 | Sweep (profile + path; twist; guide curves) | `7.2/boss-base-and-cut/sweep/*` | **Missing** |
| 36 | Loft (profiles; start/end constraints; guides) | `7.2/boss-base-and-cut/loft/*` | **Missing** |
| 37 | Fillet: variable, face, full round, setback, conic | `7.2/applied/fillet/{variable,face,full-round,setback,conic-…}` | **Missing** |
| 38 | Chamfer: vertex, offset face, face-face | `7.2/applied/chamfer/{vertex,offset-face,face-face}` | **Missing** |
| 39 | Helix / spiral | `7.2/reference-geometry/reference-curves/helix-spiral` | **Missing** |
| 40 | Thread feature (modelled) | `7.2/applied/thread-feature` | **Missing** |
| 41 | 3D Sketch | `7.1/tools/3d-sketch` | **Missing** |
| 42 | Spline editing tools (handles, curvature combs) | `7.1/tools/spline-tools/*` | **Missing** (spline entity partial) |
| 43 | Split Line (projection, silhouette, intersection) | `7.2/reference-geometry/reference-curves/split-line` | **Missing** |
| 44 | Projected / Composite curve; curve through XYZ points | `7.2/reference-geometry/reference-curves/*` | **Missing** |
| 45 | Combine (add / subtract / common) | `7.2/multibody/combine` | Have (partial): kernel-level |
| 46 | Move/Copy Body; Delete/Keep Body | `7.2/multibody/move-copy-body`, `…/delete-keep-body` | Have (partial) |
| 47 | Split (bodies), Insert Part, Save Bodies | `7.2/multibody/{split,insert-part,save-bodies}` | **Missing** |
| 48 | Curve-, sketch-, table-driven, fill and variable patterns | `7.2/patterns-and-mirror/*` | **Missing** |
| 49 | Advanced Hole | `7.2/applied/advanced-hole` | **Missing** |
| 50 | Boundary Boss/Cut | `7.2/boss-base-and-cut/boundary-boss-cut` | **Missing** |
| 51 | Thicken / Cut with surface | `7.2/boss-base-and-cut/thicken-thicken-cut` | **Missing** |
| 52 | Dome, Wrap, Intersect, Scale | `7.2/applied/{dome,wrap,intersect}`, `7.2/scale` | **Missing** |
| 53 | Direct editing: Move/Delete/Replace Face, Instant3D drag handles | `7.2/direct-editing/*`, `P/handles` | **Missing** |
| 54 | Check (geometry validity) | `7.12/geometry-check` | Have (partial): BRepCheck + free edges |
| 55 | Section Properties, Zebra, Curvature, Draft Analysis, Thickness Analysis | `7.12/*`, `7.6/draft-analysis` | **Missing** |
| 56 | Surfaces: extruded, planar, offset, knit, trim, fill, extend | `7.3/*` | **Missing** |
| 57 | STEP import/export | `7.20/neutral/step-ap203-214-242` | Have (partial): AP214 export; import at kernel level only; no PMI |
| 58 | STL export (and import) | `7.20/neutral/stl` | Have (partial): export only |
| 59 | DXF/DWG, IGES, 3MF, OBJ, glTF, PDF | `7.20/neutral/*` | **Missing** |
| 60 | Drawings: standard 3 view, projected, section, detail views; dimensions; BOM | `7.9/*` | **Missing** |
| 61 | Assemblies: insert, standard mates, interference detection, exploded view | `7.7/*`, `P/mcp-interference` | **Missing** |
| 62 | Sheet metal (base/edge flange, flatten) | `7.4/*` | **Missing** |
| 63 | Weldments (structural member, cut list) | `7.5/*` | **Missing** |
| 64 | Mold tools (parting line, tooling split) | `7.6/*` | **Missing** |
| 65 | Sensors, library features, design library | `7.2/{sensors,library-features,design-library}` | **Missing** |

### 4.1 UI parity items (from §1) against Forge

| SOLIDWORKS UI element | Forge counterpart | Status |
|---|---|---|
| CommandManager tabs + shortcut bar (S) + command search | `P/command-palette` (⌘K) | Have (partial): search and JSON parameters; no ribbon |
| PropertyManager (✓/✗/pushpin, group boxes, selection boxes) | `P/inspector` (non-modal, SPEC §6.2) | Have (partial): read-only |
| FeatureManager tree, rollback bar, status prefixes, error icons | `P/feature-tree`, `P/explainable-failures` | Missing |
| Sketch status colours (blue/black/red/yellow/brown) and status-bar state | `7.1` solver status (DOF and conflicts reported) | Solver state exists; colour rendering unverified (Metal viewport not compiled) |
| Inference lines, relation glyphs, automatic relations | `7.1/relations/automatic-relations-with-inference` | Have (partial): exact-coordinate inference only |
| Heads-up View toolbar (zoom fit/area, view orientation, display style, hide/show, section) | `P/metal-viewport`, `P/app-shell` | Have (partial), unverified on macOS |
| Selection filter, breadcrumbs, Select Other | `P/smart-selection` | Missing |
| Instant3D drag handles, triad | `P/handles` | Missing |
| Mouse gestures, keymaps (SolidWorks preset) | `P/input-devices` | Have (partial) |
| ConfigurationManager / design tables | `P/parameters` | Missing |
| Task Pane (Design Library, Appearances, View Palette) | `7.2/design-library`, `7.2/appearances` | Missing |

### 4.2 Top 20 missing items, in priority order

1. Extruded **Cut**, and the full end-condition set (Through All, Through All-Both, Up To
   Next/Vertex/Surface/Body, Offset From Surface)
2. Parametric **feature tree** (rollback, reorder, suppress, edit) with persistent naming
3. **Sketch on face / plane** selection
4. **Chamfer** (distance-distance, angle-distance)
5. **Hole Wizard** (counterbore, countersink, straight, tapped; ANSI/ISO)
6. **Reference plane** (all constraint types)
7. **Revolved Cut**
8. **Mirror** (features, faces, bodies)
9. **Linear Pattern**
10. **Circular Pattern**
11. **Convert Entities** (project model edges)
12. **Shell**
13. **Extrude options:** Thin Feature, Draft, Direction 2, Selected Contours
14. **Materials** database, which also drives mass properties
15. **Equations / global variables**
16. **Cosmetic thread**
17. **Draft** (neutral plane)
18. **Rib**
19. **Reference axis / coordinate system / point**
20. **Sweep**, with **Loft** close behind; also Configurations and Appearances
