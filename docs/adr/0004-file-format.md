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

## Implemented layout and schema 3 (2026-09-29)

The preceding sections describe the target format. The current implementation uses a
package directory with `manifest.json`, `model.json`, `bodies/<id>.brep` (current body
results), `bodies/base/<id>.brep` (authoritative original base geometry), and an optional
256-pixel `thumbnails/thumbnail.png`. Zip transport, cache hashes, mesh caches,
Quick Look/Spotlight extensions and auto-recovery remain unimplemented.

Schema 2 introduced recorded command features, rollback, stable output ids and
`base_bodies`. Schema 3 adds optional `base_sources` records, each with an id, name,
producer, payload path and persistent face names. Every base id must have exactly one
source record, even if a downstream feature modifies or deletes its current output.
Base BREP is authoritative input, not a derived cache. Saving only the current result
would apply transformations twice on reopen/rebuild or lose consumed originals.

STEP import creates these base bodies before modeling begins; it never records a
command that reopens an external path during regeneration. Multiple imports are
allowed until the first sketch or feature. Source-file deletion therefore does not
prevent rebuild, undo/redo or save/open. Imported geometry contains closed solids only;
assembly structure, PMI, source metadata and automatic repair are outside this change.

The reader migrates schema 1 to schema 2 by treating its bodies as bases. The additive
2-to-3 JSON migration is followed by loading legacy base payloads into independent
source records. Older packages only contain their saved geometry; the migration cannot
recover an original that an older writer already overwrote. A schema-3 package with
base ids but missing source records is rejected. Duplicate ids, mismatched source
records, unsafe payload paths, aliased payload paths and external symlinks are rejected.

Tests: `STEPImportTests.swift` exercises modified/deleted imported outputs, source-file
removal and legacy migration; `PackageValidationTests.swift` exercises malformed
source records and payload paths. Current schema-3 writers are intentionally not
readable by older Forge builds.
