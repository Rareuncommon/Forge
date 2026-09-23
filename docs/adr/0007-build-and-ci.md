# ADR 0007 — Build system, platforms and CI

- Status: accepted (M0)
- Date: 2026-09-23

## Decision

- **SwiftPM is the single build description.** `Package.swift` builds the C++ kernel bridge,
  all engine modules, `forge-cli` and tests. On macOS it additionally builds the `ForgeApp`
  executable target (SwiftUI + Metal). Xcode opens `Package.swift` directly;
  `scripts/make-app-bundle.sh` wraps the executable into `Forge.app` (Info.plist, icons,
  embedded OCCT dylibs, codesigning). A generated `.xcodeproj` is unnecessary until we add
  extensions (Quick Look/Spotlight, M2), at which point we add an XcodeGen spec.
- **OCCT** is built by `scripts/build-occt.sh` (CMake, shared libraries, headless modules
  only: no Visualization/Draw/Tcl/Tk/X11/OpenGL) into `Vendor/occt/<os>-<arch>`; on macOS
  it also emits per-toolkit `.xcframework`s. `Package.swift` finds OCCT via
  `FORGE_OCCT_PREFIX` and detects the 7.x vs ≥ 7.8 toolkit layout.
- **Headless engine builds on Linux.** Everything except `ForgeApp` and the Metal renderer
  compiles and is tested on Ubuntu 24.04 with Swift 6.4 and the distribution's OCCT 7.6.3.
  This gives fast, cheap CI and proves the "headless first" rule. The Metal renderer is
  guarded by `#if canImport(MetalKit)`.
- **CI** (`.github/workflows/ci.yml`):
  - `linux-headless`: Swift 6.4 toolchain + apt OCCT → `swift build`, `swift test`, all
    golden scripts through `forge-cli run`, `scripts/features.py --check`.
  - `macos-app`: builds OCCT 8.0.1 (cached), then `swift build` including `ForgeApp` and
    runs the tests against OCCT 8. Requires a runner with Xcode 27.
- Swift 6 language mode (strict concurrency) everywhere, plus the `ExistentialAny` upcoming
  feature. C++20 for the bridge.

## Consequences

- Two OCCT versions are exercised (7.6 on Linux, 8.0.x on macOS); the bridge sticks to APIs
  present in both, and any divergence must be `#if OCC_VERSION_HEX`-guarded in the bridge.
- The shipping app always uses the OCCT built by our script, never a system copy.
