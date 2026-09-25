# Working on Forge

Read SPEC.md (the product spec), then PROGRESS.md (where the last session stopped) and the
relevant ADRs in docs/adr/ before changing architecture.

## Build & test

- Linux: `scripts/bootstrap-linux.sh` once, then `export PATH=/opt/swift/usr/bin:$PATH`.
- `swift build --build-tests && swift test` — must be green before every commit.
- Golden models: `.build/debug/forge-cli run Tests/GoldenModelTests/Models/*.json --quiet`.
- Against OCCT 8: `FORGE_OCCT_PREFIX=<prefix> swift test --scratch-path .build-occt8`
  (build OCCT with `scripts/build-occt.sh --prefix <prefix>`).
- `python3 scripts/features.py --check` — FEATURES.md in sync with SPEC.md §7.
- Windows (docs/adr/0012): `scripts/fetch-occt-windows.sh`, `. Vendor/occt/windows-x64/forge-env.sh`,
  then `swift build --product ForgeWin` (Git Bash, Swift 6.4). Off Windows,
  `FORGE_WIN_CHECK=1 swift build --product ForgeWin` type-checks the Windows front end.
- App logic belongs in ForgeUI (shared by macOS and Windows, tested in Tests/ForgeUITests);
  a PropertyManager page change goes in both `PanelSpec.swift` and the macOS `PMPages.swift`.

## Rules (from SPEC §0)

- Never stub-and-claim. Placeholders say `// NOT IMPLEMENTED` and are listed in FEATURES.md.
- Every capability is a `Command` (ForgeCommands) — UI, MCP, CLI and scripts share it. Add
  new commands to `StandardRegistry.swift`; the MCP `execute` tool picks them up.
- Params: `Codable` struct, snake_case `CodingKeys`, `fieldDocs` for every key, no
  validation inside `init(from:)` (use `ValidatableParams`), units via `Length`/`Angle`/`Point3`.
- Errors: throw `ForgeError` with a stable `ErrorCode`, entity ids and executable
  `SuggestedFix`es.
- Golden-model expectations are derived analytically, never copied from program output.
- No OCCT types outside `CForgeKernel`; no GPL code linked (docs/adr/0005).
- Update FEATURES.md statuses (then `scripts/features.py`) and PROGRESS.md every session.
