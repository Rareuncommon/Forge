# ADR 0010 — SolidWorks native files (.sldprt / .sldasm / .slddrw)

- Status: proposed (research item for M3; SPEC §7.20 requires an ADR)
- Date: 2026-09-23

## Context

SolidWorks files are proprietary compound documents. They typically embed a preview image
and (for parts/assemblies) a Parasolid geometry stream. Parasolid is a proprietary kernel
(Siemens) and reading its transmit format requires a license. Reverse-engineering the
feature history would be both technically fragile and legally risky (EULA terms,
anti-circumvention law in some jurisdictions).

## Decision (proposed)

1. **Primary migration path:** STEP AP242 (with PMI where present) exported from SolidWorks,
   followed by a FeatureWorks-style **feature recognition** pass in Forge (M3) that rebuilds
   an editable feature tree (extrudes, revolves, holes, fillets, chamfers, patterns) on the
   imported B-rep.
2. **Preview only:** reading the embedded thumbnail for Finder/Quick Look display of
   `.sld*` files is low-risk and may be implemented after legal review of the container
   format's documentation status.
3. **No parsing of the Parasolid stream or feature data** unless (a) Forge obtains a
   Parasolid license or (b) counsel confirms a specific approach is permitted. This is a
   **product/legal decision for the owner**.
4. Offer a SolidWorks-side export macro (VBA/C#, our own code, run by the user in their
   licensed SolidWorks) that writes STEP + a JSON sidecar of feature names, dimensions,
   configurations and custom properties via the official SolidWorks API. This is the most
   faithful legal route to carry design intent across, and it feeds the recognition pass.

## Open question for the owner

Whether to license Parasolid (commercial cost) for direct `.x_t`/embedded-stream import.
