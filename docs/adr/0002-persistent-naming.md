# ADR 0002 — Persistent (topological) naming

- Status: accepted; implemented for faces and edges (2026-09-28, see "Implementation")
- Date: 2026-09-23

## Context

References from downstream features to upstream geometry ("fillet *this* edge", "sketch on
*that* face") are the main source of fragility in parametric CAD (the FreeCAD "toponaming
problem"). SPEC §4.2 requires stable, history-based identifiers that survive upstream edits,
and explicit failure — never silent rebinding — when a reference cannot be resolved.

## Decision

### Identifier structure

Every face, edge and vertex produced during regeneration receives a **name**:

```
name := feature_id ":" role [ "(" generator_names ")" ] [ "#" disambiguator ]
```

- `feature_id` — the stable id of the feature that created or last split/merged the entity.
- `role` — what the entity *is* to that feature, from a closed vocabulary per feature type:
  extrude `start_cap`, `end_cap`, `side`, `side_edge`, `cap_edge`; revolve `start_face`,
  `end_face`, `swept`; fillet `blend`, `blend_edge`; boolean `from_target`, `from_tool`;
  pattern `instance[i]` wrapping the seed's name; etc.
- `generator_names` — the names of the entities it was generated from (for an extrude side
  face: the name of the sketch segment; for a fillet face: the edge it replaced). Sketch
  entities carry sketch-stable ids, so this chain bottoms out in user-created objects.
- `disambiguator` — only when the above is not unique (e.g. a side face split in two by a
  later cut): an ordinal assigned by a **geometric sort key** (centroid projected on the
  generator's parametric direction), never by kernel iteration order.

Names are computed from OCCT's history API (`Generated`, `Modified`, `IsDeleted` on every
`BRepBuilderAPI_MakeShape`/`BRepAlgoAPI_BuilderAlgo`), which the kernel ABI (ADR 0001) will
expose as `(input sub-shape → output sub-shapes, relation)` lists.

### Storage and resolution

- The regenerated model stores a `name → current transient index` map per body, plus an
  entity descriptor (type, area/length, centroid, normal, adjacency) for each name.
- Features store references as names, never indices.
- Resolution on regeneration:
  1. Exact name match → resolved.
  2. Name missing but its ancestors exist with the entity split: resolve to the full set when
     the feature accepts sets (fillet/chamfer/edge selections); otherwise **fail**.
  3. Name missing: the feature fails with error `reference_lost`, carrying the old
     descriptor and **ranked repair candidates** (by descriptor similarity) as executable
     `SuggestedFix`es (`feature.repair_reference {feature, old, new}`). No automatic rebind.

### Semantic references (SPEC §4.3)

Semantic queries (`face(feature:"Extrude1", role:"end_cap")`, `edges(of:…, where:…)`,
`face(nearest:…, normal:…)`) are resolved to names at *command time* and the **name** is
stored — so a query's meaning is frozen when the user/agent issued it, and later edits are
handled by the rules above.

### Test plan ("torture suite", SPEC §9)

For each reference-taking feature, golden scripts that: change upstream dimensions (bigger,
smaller, sign-flip), reorder independent features, change pattern counts up/down, insert a
fillet/chamfer upstream, suppress/unsuppress upstream features, and replace sketch
segments. Each asserts that references either resolve to the geometrically-intended entity
(checked by descriptor) or fail with `reference_lost` — a silent rebind fails the test.

## Consequences

- M0 exposes transient `body-N/face-K` references and documents them as transient.
- Every M2+ feature must define its role vocabulary and emit history; this is enforced by a
  registry test (features without a naming table cannot be registered).

## Implementation (2026-09-28)

- **Kernel history.** `fk_history_begin` installs a per-thread recorder that the next
  operation fills with `(operand, input sub-shape, output face, same | generated)` records,
  traced through every stage the operation runs (e.g. boolean → UnifySameDomain). Recorded by
  booleans, transform, fillet, chamfer, shell (walls from faces, rims from edges), draft
  (`ModifiedShape`), extrude / drafted extrude / revolve (sides from profile edges, caps from
  `FirstShape`/`LastShape`) and `fk_make_faces` (which profile segment each edge lies on,
  matched by midpoint because wire building may rebuild edges). The Swift wrapper attaches
  the records to the result (`Shape.history`).
- **Names** (`Sources/ForgeCommands/Naming.swift`). Faces carry base names; roles:
  extrude `side(<sketch entity>)`, `start_cap`, `end_cap`; revolve `swept(<entity>)`,
  `start_face`, `end_face`; fillet/chamfer `blend(<edge name>)`, `corner`; shell
  `wall(<face>)`, `rim(<edge>)`; box `+x`…`-z`; cylinder/cone `side`, `top`, `bottom`;
  sphere/torus `surface`; holes `hole(<point>).drill:side` etc.; pattern instances and
  copies append `@k`. Faces without history are `<feature>:new` / `:face`. Split pieces are
  numbered `#k` by centroid (x, then y, then z); merged faces keep every base name.
  Edge names are the sorted names of their two faces joined by `|`, `~k` when repeated.
  The feature id is the feature being regenerated (`Document.namingFeature`), else the id the
  running command will be recorded as.
- **References.** `body-1/face@<name>`, `body-1/edge@<name>`. The engine rewrites transient
  references in a feature's parameters to names when it records the feature (and in
  `feature.edit`, against the model before the feature), storing a descriptor (type,
  centroid, size) of each. Sketch placements on faces are stored by name. Face and edge
  resolution: exact name; else the pieces of the split entity (all of them for fillet,
  chamfer, shell and draft faces; an error with the pieces as candidates for single
  references such as a draft's neutral plane or a sketch face); else `reference_lost` with
  the three most similar entities as `feature.repair_reference` fixes. `feature.list` shows
  the fixes. Names are saved with each body (`face_names`); older files get positional names.
- **Queries.** `query.faces` / `query.edges` return `persistent_id`; `query.find_faces`
  finds faces by feature and role.
- **UI.** Editing a feature rolls the model back to just before it inside a transaction (as
  SolidWorks does), so stored references are shown and picked on the geometry they name;
  OK rolls forward and commits one undo step, Cancel discards.

Not yet: vertex references; the registry test that rejects features without a naming table.
