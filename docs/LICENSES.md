# Dependencies and licenses

Policy: docs/adr/0005-gpl-process-boundary.md. Every dependency that is linked, bundled or
invoked is listed here with its version, license and linkage. Verified 2026-09-23.

## Linked into Forge processes

| Dependency | Version | License | Linkage | Used by |
|---|---|---|---|---|
| Open CASCADE Technology (OCCT) | 8.0.1 (macOS app, built by `scripts/build-occt.sh`); 7.6.3 (Ubuntu 24.04 packages, Linux CI) | LGPL 2.1 + Open CASCADE exception 1.0 | Dynamic (shared libraries / dylibs, shipped unmodified and replaceable in `Forge.app/Contents/Frameworks`) | ForgeKernel (`CForgeKernel`) |
| Swift standard library, Foundation, Swift Testing | Swift 6.4.0 | Apache-2.0 with Runtime Library Exception | Dynamic (Linux) / OS-provided (macOS) | all modules |
| Apple SDK frameworks (SwiftUI, AppKit, Metal, MetalKit) | macOS 27 SDK (Xcode 27) | Apple SDK license | System frameworks | ForgeApp, ForgeRender (Metal) |

OCCT build configuration: FoundationClasses, ModelingData, ModelingAlgorithms,
ApplicationFramework, DataExchange; no Visualization, Draw, Tcl/Tk, FreeType, FreeImage,
RapidJSON, Draco, TBB, VTK, OpenVR or FFmpeg — so none of their licenses apply.

No third-party Swift packages are used (`Package.swift` has no dependencies).

## Evaluated, not currently used

| Dependency | Version checked | License | Notes |
|---|---|---|---|
| MCP Swift SDK (`modelcontextprotocol/swift-sdk`) | 0.12.1 | MIT | Own implementation chosen (ADR 0006) |
| FreeCAD planegcs | FreeCAD 1.1.3 | LGPL 2.1+ (Eigen MPL-2.0, Boost BSL-1.0) | Custom solver chosen; planegcs kept as out-of-tree test oracle (ADR 0003) |
| Netgen | 6.2.2607 | LGPL 2.1 | Planned for meshing (M7), dynamic linking |

## Planned external processes (never linked)

| Tool | License | Integration |
|---|---|---|
| Gmsh | GPL 2+ | External process, `.msh` files (M7+) |
| CalculiX | GPL 2 | External process, `.inp`/`.frd` (M7+) |
| OpenFOAM | GPL 3 | External process, case directories (M10) |

## In-tree implementations (no external code)

PNG/zlib/deflate encoder, CRC-32, Adler-32 (`ForgeRender/PNG.swift`), JSON-RPC/MCP
(`ForgeMCP`), JSON Schema extraction (`ForgeCore/Schema.swift`) — written for Forge.
