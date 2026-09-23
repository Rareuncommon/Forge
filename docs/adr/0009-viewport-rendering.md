# ADR 0009 — Viewport rendering and picking

- Status: accepted (M0)
- Date: 2026-09-23

## Decision

- **Two renderers with one contract.** `SoftwareRenderer` (CPU, portable, headless) and
  `MetalViewportRenderer` (GPU, macOS) both draw shaded triangles + B-rep edges and both
  produce per-pixel **object and element IDs** (`face index + 1`, or
  `(edge index + 1) | 0x8000_0000`). `RenderImage.pick` applies the same selection rule to
  either buffer: edges win within the pick radius, then nearest pixel.
- The software renderer powers `render_view` / `render_multiview` / `pick` for agents
  (no GPU, no window, deterministic output) and is the test oracle for picking.
  `RayPicker` provides analytic CPU picking; tests assert it agrees with the ID buffer.
- **World convention:** Y-up, like SolidWorks (Front = XY plane viewed from +Z).
  Orthographic projection by default; Metal clip-space depth [0, 1].
- **Camera:** quaternion orientation (free orbit without gimbal lock) plus turntable mode,
  pan in the view plane scaled to pixels, zoom toward the cursor anchor.
- **GPU picking:** M0 de-indexes triangles so every vertex carries its face ID (portable,
  simple). Later: indexed geometry + a per-triangle face-ID buffer read via
  `[[primitive_id]]`, instancing for assemblies, and meshlet culling for the 5,000-part
  performance target (SPEC §6.11).
- PNG encoding is in-tree (zlib/deflate with LZ77 + fixed Huffman), validated against the
  reference zlib in tests, because Foundation has no image codecs on Linux.

## Consequences

- Agents and humans see the same geometry and pick the same entities.
- The M0 Metal path is unverified until built on macOS (see PROGRESS.md).
