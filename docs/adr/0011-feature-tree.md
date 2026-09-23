# ADR 0011 — Feature tree and regeneration engine

- Status: proposed (M2 design; to be accepted with the first feature that uses it)
- Date: 2026-09-23
- Builds on: ADR 0002 (persistent naming), ADR 0004 (file format), ADR 0008 (commands)

## Context

Through M1 the document holds *bodies* (kernel shapes produced directly by `body.*`
commands) and *sketches*. That is not parametric: changing a sketch dimension does not
update the extrusion made from it, and references to faces/edges are transient indices.
SPEC §7.2 (part features), §4.2 (persistent naming) and the "done" definition in §0.2
("regenerates, round-trips save/load, undo/redo, command + MCP, tests") all require a
history-based feature tree. This ADR fixes its shape before any feature is written.

## Decision

### 1. The document is the tree; bodies are derived

- `Document.features: [Feature]` — an ordered list (the FeatureManager tree), plus a
  `rollback: Int?` position. Folders are presentation only (`FeatureFolder` entries that group
  ids) and never change regeneration order.
- A `Feature` is a value: `id` (stable, `feature-N`, never reused), `kind`, `name`,
  `suppressed`, `params` (the feature kind's own `Codable` struct, snake_case, like command
  params), and `references` — every upstream dependency as an ADR 0002 *name* (or a sketch
  entity id), never a transient index.
- Sketches become features (`sketch`), owning their `Sketch` value and a placement
  reference (a standard plane, a reference plane feature, or a planar face *name*).
- **Bodies are outputs of regeneration**, not stored state. `Document.bodies` becomes the
  result cache of the last regeneration: `[bodyName: NamedShape]` where `NamedShape` is a
  kernel shape plus its `index → name` table (ADR 0002). Undo/redo, transactions and dry-run
  keep working unchanged because the tree is a value type inside `Document`.

### 2. Feature kinds are types with a naming table

```swift
protocol FeatureKind {
    associatedtype Params: Codable & Sendable & SchemaDocumented & ValidatableParams
    static var kind: String { get }                   // "extrude", "fillet", …
    static var roles: [String] { get }                // closed role vocabulary (ADR 0002)
    static func references(_ p: Params) -> [Reference] // what it depends on
    static func regenerate(_ p: Params, _ ctx: inout RegenContext) throws -> FeatureOutput
}
```

- `FeatureOutput` = new/modified bodies as `NamedShape`s. Every face/edge/vertex in them
  carries a name built from kernel history (`Generated`/`Modified`/`IsDeleted`), which the
  C ABI gains as `fk_*_with_history` variants returning `(input sub-shape → output
  sub-shapes, relation)` lists (ADR 0001 rules: no OCCT types cross the boundary).
- A registry test enforces ADR 0002's rule: a kind without a role table, or one that emits an
  unnamed face/edge, cannot be registered.
- Each kind is also exposed as commands through one generic adapter: `feature.<kind>` creates
  it (params = the kind's `Params` + optional `name`, `insert_after`), `feature.edit` changes
  params by id. So the MCP `execute` tool and schemas come from the same types (ADR 0008).

### 3. Regeneration

- `regenerate(tree, upTo: rollback)` is a pure function of the tree: walk features in order,
  resolve each feature's references against the names produced so far, run it, record a
  per-feature status: `ok`, `warning` (e.g. a set reference partly split — ADR 0002 rule 2),
  or `error(ForgeError)`.
- **Errors do not stop the walk.** A failed feature produces no output; features whose
  references resolve only through it fail with `upstream_failed` (their own error names the
  root cause); independent later features still regenerate. This is SolidWorks behaviour and
  keeps the model inspectable.
- Determinism: same tree ⇒ bit-identical BREP and identical names (already tested for bodies
  in the golden suite; extended to names).
- **Incremental:** each feature's output is cached under a key = hash(kind, params, resolved
  input names + input shape hashes). An edit re-runs only features whose key changed. The
  cache is in memory and optional in the file; correctness never depends on it.
- Rollback: features after `rollback` are skipped (shown rolled back); new features insert at
  the rollback position.

### 4. References and repair

- Commands that take geometry (`edges`, `faces`, `sketch plane`) accept today's transient
  refs (`body-1/edge-3`), semantic queries (ADR 0002 §semantic) or names; all are resolved to
  **names at command time** and only names are stored.
- A lost reference fails with `reference_lost`, the old descriptor, and ranked candidates as
  `SuggestedFix { command: "feature.repair_reference", params: {feature, old, new} }` — never
  a silent rebind.

### 5. Migration of M0/M1 commands

- `body.create_box` & co. become features (`box`, `cylinder`, …) with the same params; the
  old command names remain as aliases that insert the feature. `body.extrude`/`body.revolve`
  become `feature.extrude`/`feature.revolve` (aliases kept). `body.boolean`, `body.fillet`,
  `body.transform` become `combine`, `fillet`, `move_copy_body` features.
- File format v2 (ADR 0004 migration table gets its first real step): `model.json` stores
  the tree; v1 documents migrate by turning each stored body into an `imported_body` feature
  (a dumb solid, as SolidWorks does for imported geometry) and each sketch into a `sketch`
  feature. `bodies/*.brep` stay in the package as the regeneration cache and for Quick Look,
  and are verified against regeneration on open (mismatch ⇒ warning, regenerated result wins).

### 6. Commands (first set)

`feature.list` (tree with statuses), `feature.get`, `feature.edit`, `feature.rename`,
`feature.suppress`/`unsuppress`, `feature.delete` (with dependants: refuse unless
`cascade: true`, listing them), `feature.reorder` (refuse if it breaks a reference),
`feature.rollback`, `feature.repair_reference`, `document.regenerate` (forced, full).
MCP: `get_feature_tree`, `edit_feature` aliases; the tree is also an MCP resource with update
notifications (as the document state already is).

## Order of work (M2)

1. Kernel history ABI + `NamedShape` + naming for primitives and extrude (unit tests on names).
2. `Feature`, registry, regeneration walk, statuses, rollback; `sketch` and `extrude` kinds;
   sketch-dimension edit → extrusion updates (first truly parametric golden model).
3. File format v2 + migration of v1 packages (golden save/open round trip covers it).
4. `revolve`, `fillet`, `chamfer`, `combine` with role tables; the ADR 0002 torture suite.
5. Remaining §7.2 features in SPEC order, each done only when it meets §0.2.

## Consequences

- Every existing golden model keeps passing through the aliases; new golden models assert
  regeneration after upstream edits (not just final geometry).
- The app's inspector becomes a tree view over `feature.list`; editing goes through
  `feature.edit` like every other client.
- Cost: kernel calls now return history, and every feature needs a role table — deliberate,
  since that is what makes references stable.
