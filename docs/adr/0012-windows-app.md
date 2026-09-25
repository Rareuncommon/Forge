# ADR 0012 — Native Windows app

Status: accepted (2026-09-25)

## Context

The user asked for Forge on Windows as well as macOS, as a native app (not a web UI). The
engine (ForgeCore, ForgeKernel over OCCT, ForgeSketch, ForgeData, ForgeCommands, ForgeRender,
ForgeMCP, forge-cli) was already portable Swift and C++. The macOS app was SwiftUI + AppKit +
Metal, about 6,200 lines. Its model logic (operations, previews, sketch tools, selection) lived
in the same target as its views.

Options checked against live sources (2026-09):

- **WinUI 3 from Swift.** The Browser Company's ready-made bindings (swift-winui,
  swift-windowsappsdk) were archived in 2025 as "an outdated snapshot". You would have to
  generate projections with swift-winrt, which needs their own toolchain. SwapChainPanel
  (Direct3D inside XAML) is not projected, and the Windows App SDK runtime must be installed.
- **Win32 + Direct3D 11.** Both ship with every Windows 10/11 and are reachable from the
  standard Swift 6.4 toolchain (C/C++ targets; `WinSDK` also exposes DirectX).

## Decision

1. **Shared model: `ForgeUI`.** The app model moves out of the macOS target into a target
   with no UI framework, using `package` access:
   - AppModel, operations and their invocations, previews, sketch tools, dimensions, overlays.
   - `PanelSpec`, `RibbonSpec` and `TreeSpec`: the PropertyManager, ribbon and
     FeatureManager tree as data.

   It builds and is unit-tested on Linux (Tests/ForgeUITests). Native dialogs go through
   `PlatformServices`.
2. **Shared draw plan.** `ForgeRender.ViewportPlan` holds the vertex packing, uniforms and
   draw order of the interactive viewport. The Metal renderer executes it, and so does the
   Direct3D 11 renderer.
3. **Windows shell in C++ (`CForgeWin`), behind a plain C API.** It contains:
   - the Win32 window: menus, accelerators, ribbon tabs and buttons with flyouts, a TreeView
     tree, the PropertyManager built from control descriptions, status bar, Modify box,
     TaskDialog and file dialogs;
   - Direct3D 11 with HLSL equivalents of the Metal shaders, GPU picking into two R32_UINT
     targets, and Direct2D/DirectWrite labels.

   COM and Win32 stay in C++, where they are idiomatic. Common controls v6 are activated at
   run time, so no manifest has to be embedded.
4. **Swift front end (`ForgeWin`).** It pushes the specs to the shell whenever what they read
   changes (Observation), routes native events to the specs' actions, and drives the viewport
   the way ViewportView does on macOS. It contains no Win32 code.

## Verification

- Linux CI type-checks ForgeWin against a headless implementation of the shell API
  (`FORGE_WIN_CHECK=1 swift build --product ForgeWin`).
- The C++ shell compiles and links with MinGW and runs under Wine. A C driver replays real
  draw lists produced by ViewportPlan: shading, edges, highlight, picking, labels, ribbon,
  tree and panel.
- Windows CI (windows-2025, Swift 6.4, OCCT's official MSVC build via
  `scripts/fetch-occt-windows.sh`) does the following:
  - builds the engine and runs the tests and the golden models;
  - builds ForgeWin;
  - runs `ForgeWin --screenshot`, which builds a part, opens Fillet with its live preview and
    saves a PNG.

## Consequences

- The macOS SwiftUI pages and the shared `PanelSpec` describe the same pages twice; a change
  to one must be made in the other. (Moving the macOS pages onto the spec is a follow-up.)
- The Windows ribbon uses text buttons; the icon set (SVG paths) is not rendered there yet.
- The MCP local-socket transport is not available on Windows yet (stdio is).
- Wine is used only as a development check of the C++ shell. It is not a target.
