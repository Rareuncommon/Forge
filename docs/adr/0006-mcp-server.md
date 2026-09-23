# ADR 0006 — MCP server implementation

- Status: accepted (M0)
- Date: 2026-09-23

## Context

SPEC §2: "MCP server (official Swift SDK if mature; otherwise implement the spec) — stdio +
local Unix socket". Verified 2026-09-23: `modelcontextprotocol/swift-sdk` **0.12.1**
(pre-1.0), targets MCP spec **2025-11-25**, supports Linux. Its manifest depends on
`swift-docc-plugin` pinned to `branch: "main"` (not reproducible), plus swift-nio,
swift-system, swift-log and eventsource. It has no Unix-socket server transport.

## Decision

Implement the MCP server protocol layer ourselves in `ForgeMCP` (~500 lines):
JSON-RPC 2.0 over newline-delimited JSON, `initialize` with version negotiation
(2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05), `tools/*`, `resources/*` (with
subscriptions and `notifications/resources/updated`), `prompts/*`, `ping`, logging and
completion stubs. Transports: stdio and a Unix-domain socket (mode 0600) sharing one
`Engine`.

Tool design:

- **Tools are generated from the command registry**: each tool's `inputSchema` is the
  command's generated params schema, so MCP cannot drift from the command layer.
- A generic `execute` / `execute_batch` reaches every command (present and future, including
  plugin commands) with `dry_run`; convenience tools cover the SPEC §5.2 minimum set.
- Tool failures are **tool results with `isError: true`** carrying the structured
  `ForgeError` (code, message, entities, executable suggestions) — the model sees them.
  Protocol problems (unknown tool, malformed JSON) are JSON-RPC errors.
- `structuredContent` is included for protocol versions ≥ 2025-06-18; images (render_view)
  are MCP `image` content.

## Consequences

- No third-party runtime dependencies; deterministic builds; socket transport available.
- We track spec revisions ourselves. Re-evaluate the official SDK at 1.0 — the transport
  and dispatch layer is small and isolated, so switching is cheap.
- HTTP transport (streamable HTTP + auth) is out of scope until collaboration (M13).
