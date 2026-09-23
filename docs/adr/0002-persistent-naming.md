# ADR 0002 — Persistent (topological) naming

- Status: accepted (design); implementation in M2
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
