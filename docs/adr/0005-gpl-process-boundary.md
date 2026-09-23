# ADR 0005 — GPL process-boundary policy

- Status: accepted
- Date: 2026-09-23

## Context

The Forge app must stay distributable under a license of the owner's choosing, closed or
open (SPEC §2). Several best-in-class engineering tools are GPL (Gmsh, CalculiX, OpenFOAM).

## Decision

1. **In-process (linked into the app, `forge-cli` or any plugin we ship):** only permissive
   (MIT, BSD, Apache-2.0, MPL-2.0 file-level, zlib, Boost) or **LGPL linked dynamically**
   (OCCT, Netgen) with the LGPL obligations met: unmodified or published sources, the
   ability for users to replace the library, license texts and notices in the app bundle.
2. **GPL / AGPL code runs only as a separate executable** that Forge talks to over files,
   pipes or sockets using documented, generic formats (e.g. CalculiX `.inp`/`.frd`, Gmsh
   `.msh`, OpenFOAM case directories). No GPL headers are included, no GPL code is linked,
   no shared-memory ABI coupling. Adapters live in `ForgeSim` and are written by us.
3. GPL executables are **not bundled** in closed-source distributions by default; the app
   locates a user-installed copy or offers a separate, clearly-licensed download. (Bundling
   an unmodified GPL binary next to a proprietary app is generally permissible "mere
   aggregation", but the owner decides per release — this is a product/legal decision.)
4. Every dependency, its version, its license and how it is linked is recorded in
   `docs/LICENSES.md`; CI will fail if a new dependency appears in `Package.resolved` or the
   OCCT/xcframework manifest without an entry (M1 task).
5. No code is copied from GPL projects into Forge sources. Reading GPL code for ideas is
   fine; transcription is not.

## Consequences

- Gmsh, CalculiX, OpenFOAM: external processes behind adapters.
- Netgen (LGPL 2.1, verified at v6.2.2607): may be linked dynamically.
- FreeCAD planegcs (LGPL 2.1+): may be linked dynamically — see ADR 0003 (not used).
