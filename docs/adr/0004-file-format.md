# ADR 0004 — Document file format

- Status: accepted (design); implementation in M2
- Date: 2026-09-23

## Decision

A document is a **package directory** (macOS bundle, `LSTypeIsPackage`) with extension
`.forgepart`, `.forgeasm` or `.forgedrw`:

```
Bracket.forgepart/
  manifest.json          schema version, app version, document kind, units, content hashes
  model.json             feature history + parameters + configurations (authoritative)
  cache/
    brep/<body>.brep     canonical OCCT binary BREP per body (derived; see below)
    mesh/<body>.fmesh    display tessellation (derived)
  thumbnails/
    thumbnail.png        512x512 isometric (Quick Look, Finder)
  journal.json           optional: command journal for audit/macro recording
```

- **`model.json` is authoritative**; everything under `cache/` is derivable and is ignored
  by diff/merge. Opening a file whose cache hash does not match `model.json` regenerates.
- **Git-friendly JSON:** UTF-8, 2-space indentation, object keys sorted, one feature per
  array element, numbers written with the shortest round-trip representation, lengths in
  millimetres with the user-entered expression preserved alongside
  (`{"expr": "1 in", "mm": 25.4}`). Stable ids (not array positions) for all references.
- **Canonical BREP:** written through the kernel's canonicalising writer (ADR 0001), so a
  load/save cycle without edits is byte-identical — important for git and PDM.
- **Schema migration:** `manifest.json.schema` is an integer. Each bump ships a pure
  function `migrate_N_to_N+1(model.json) -> model.json`, with golden fixtures of every past
  version under `Tests/Fixtures/format/vN/` that must open and regenerate identically.
- **Write safety:** save writes a sibling temp package and swaps it in atomically
  (`FileManager.replaceItemAt`), keeping the previous version for auto-recover.
- **Quick Look / Spotlight:** a Quick Look preview extension renders `thumbnails/` (and
  later the mesh cache in 3D); a Spotlight importer indexes name, units, custom properties,
  materials and feature names from `manifest.json` + `model.json`.
- On Linux (CI/headless) the same package is a plain directory; `forge-cli` can also read a
  single-file zip variant (`.forgepartz`) for transport, containing the same tree.

## Consequences

- Diffs of real model changes are small and reviewable; caches never create merge conflicts.
- Files are larger than a single binary blob; acceptable, and caches can be dropped
  (`forge-cli pack --no-cache`).
