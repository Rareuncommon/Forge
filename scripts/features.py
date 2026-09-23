#!/usr/bin/env python3
"""Generate / refresh FEATURES.md from SPEC.md Section 7.

Every item in SPEC §7 becomes a row with a stable slug ID (section/item[/variant]).
Parenthesised variant lists become child rows so parity is tracked at the granularity
SolidWorks exposes. Re-running preserves Status/Module/Test/MCP/Notes of existing rows
(matched by ID), so FEATURES.md stays the hand-maintained source of truth while the row
set follows the spec. Rows whose ID disappears from the spec are kept under "Orphaned".

Usage: scripts/features.py            # rewrite FEATURES.md
       scripts/features.py --check    # exit 1 if FEATURES.md is out of date
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "SPEC.md"
OUT = ROOT / "FEATURES.md"

STATUSES = ["not started", "in progress", "done", "verified"]

SECTION_MODULE = {
    "7.1": "ForgeSketch", "7.2": "ForgeModel", "7.3": "ForgeModel", "7.4": "ForgeModel",
    "7.5": "ForgeModel", "7.6": "ForgeModel", "7.7": "ForgeAssembly", "7.8": "ForgeSim",
    "7.9": "ForgeDrawing", "7.10": "ForgeDrawing", "7.11": "ForgeData", "7.12": "ForgeModel",
    "7.13": "ForgeSim", "7.14": "ForgeSim", "7.15": "ForgeSim", "7.16": "ForgeRouting",
    "7.17": "ForgeRender", "7.18": "ForgeCAM", "7.19": "ForgeData", "7.20": "ForgeData",
    "7.21": "ForgeCommands",
}

# Platform capabilities from SPEC §3–§6 (not in §7 but tracked with the same rigour).
PLATFORM = [
    ("P/kernel-bridge", "Kernel bridge: C ABI over OCCT, no OCCT types outside ForgeKernel (§2, §3)"),
    ("P/kernel-primitives", "Kernel: primitives (box, cylinder, cone, sphere, torus)"),
    ("P/kernel-booleans", "Kernel: booleans with same-domain unification"),
    ("P/kernel-queries", "Kernel: topology, mass properties, bbox, validity, face/edge descriptors, distance"),
    ("P/kernel-tessellation", "Kernel: tessellation with face/edge IDs for picking"),
    ("P/kernel-brep-io", "Kernel: binary BREP serialisation (canonical, byte-stable)"),
    ("P/command-bus", "Single command bus (Engine actor) (§3)"),
    ("P/command-schema", "Command schema generated from Swift types (§5.1)"),
    ("P/units", "Unit-aware parameters: \"25 mm\", \"1 in\", bare numbers in document units (§5.4)"),
    ("P/structured-errors", "Structured errors with executable suggested fixes (§5.4)"),
    ("P/undo-redo", "Undo/redo (§4, §6.2)"),
    ("P/transactions", "Transactions: begin/commit/rollback (§5.1)"),
    ("P/dry-run", "dry_run with predicted changes (§5.1)"),
    ("P/batch", "Batch execution (atomic) (§5.1)"),
    ("P/explicit-state", "No hidden state: selection/active document explicit & queryable (§5.4)"),
    ("P/journal", "Command journal replayable as a script (macro recorder foundation) (§5.3)"),
    ("P/forge-cli", "forge-cli headless engine (§3)"),
    ("P/golden-models", "Golden-model regression suite (§9)"),
    ("P/determinism", "Deterministic regeneration, bit-for-bit (§3)"),
    ("P/mcp-stdio", "MCP server over stdio (§5)"),
    ("P/mcp-socket", "MCP server over local Unix socket (§5)"),
    ("P/mcp-discovery", "MCP tools: list_commands, describe_command, search_commands (§5.2)"),
    ("P/mcp-document", "MCP tools: new_document, list_documents, get_document_state (§5.2)"),
    ("P/mcp-open-save", "MCP tools: open, save (§5.2)"),
    ("P/mcp-export", "MCP tools: export (§5.2)"),
    ("P/mcp-mutate", "MCP tools: execute, execute_batch, undo, redo, transactions (§5.2)"),
    ("P/mcp-feature-tools", "MCP tools: get_feature_tree, get_feature, get_sketch, edit_feature, edit_dimension, set_parameter, get_parameters, get_errors, explain_error (§5.2)"),
    ("P/mcp-query-geometry", "MCP tool: query_geometry (semantic references, §4.3)"),
    ("P/mcp-vision", "MCP tools: render_view, render_multiview, pick (§5.2)"),
    ("P/mcp-verification", "MCP tools: validate_model, compare_to_spec (§5.2)"),
    ("P/mcp-interference", "MCP tool: check_interference (§5.2)"),
    ("P/mcp-resources", "MCP resources + update notifications (§5.2)"),
    ("P/mcp-prompts", "MCP prompts (§5.2)"),
    ("P/plugins-swift", "Swift plugin bundles: commands, features, panels, translators (§5.3)"),
    ("P/scripting-js", "JavaScriptCore scripting (§5.3)"),
    ("P/scripting-python", "Python via forge-cli/socket (§5.3)"),
    ("P/macro-recorder", "Macro recorder with semantic references (§5.3)"),
    ("P/feature-tree", "Feature tree: rollback, reorder, suppress, freeze, folders, errors (§4.1)"),
    ("P/persistent-naming", "Persistent naming (§4.2)"),
    ("P/semantic-refs", "Semantic references (§4.3)"),
    ("P/parameters", "Global variables, equations, linked dims, design tables, configurations (§4.4)"),
    ("P/file-format", "Package file format, schema migration, Quick Look/Spotlight (§4.5)"),
    ("P/background-regen", "Background regeneration with cancellation (§3)"),
    ("P/metal-viewport", "Metal viewport: shaded+edges, orbit/pan/zoom, GPU picking (§2, M0)"),
    ("P/headless-render", "Headless software renderer + PNG (render_view backend)"),
    ("P/app-shell", "SwiftUI app shell (§1.4)"),
    ("P/command-palette", "Command palette ⌘K with inline parameter entry (§6.1)"),
    ("P/inspector", "Inspector panel instead of modal PropertyManagers (§6.2)"),
    ("P/handles", "Direct-manipulation handles (§6.3)"),
    ("P/explainable-failures", "Explainable failures in the viewport (§6.4)"),
    ("P/smart-selection", "Smart selection, filters, select-other (§6.5)"),
    ("P/input-devices", "Trackpad gestures, 3Dconnexion, Pencil/Sidecar, keymaps (§1.4, §6.9)"),
    ("P/accessibility", "VoiceOver, keyboard-only, high contrast, Dynamic Type (§6.10)"),
    ("P/performance", "Performance targets + benchmarks with regression alerts (§6.11, §9)"),
    ("P/ci", "CI running headless tests (M0)"),
    ("P/fuzzing", "Import fuzzing (§9)"),
]

# Items discovered beyond SPEC §7 (SPEC: "If you discover a SolidWorks capability not listed, add it").
DISCOVERED = [
    ("D/hide-show", "Hide/show bodies, components, sketches, planes (display pane)"),
    ("D/transparency", "Per-body/component transparency"),
    ("D/section-view-part", "Section view (dynamic display section in parts/assemblies)"),
    ("D/view-selector", "View selector cube, named/saved views, previous view"),
    ("D/zoom-to-selection", "Zoom to selection / zoom to area"),
    ("D/display-states-part", "Display states in parts"),
    ("D/feature-comments", "Comments/notes on features"),
    ("D/selection-sets", "Selection sets (saved selections)"),
]


def split_top(text, seps=",;"):
    """Split on separators that are not inside parentheses."""
    parts, depth, cur = [], 0, []
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        if ch in seps and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


def slug(s):
    s = s.lower().replace("&", "and").replace("→", "-to-").replace("↔", "-")
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s[:60] or "item"


def parse_item(item):
    """'rectangle (corner, center)' -> ('rectangle', ['corner', 'center'])."""
    m = re.match(r"^(.*?)\s*\((.*)\)\s*(.*)$", item)
    if not m:
        return item, []
    head, inner, tail = m.group(1).strip(), m.group(2), m.group(3).strip()
    name = (head + (" " + tail if tail else "")).strip() or inner
    children = []
    for c in split_top(inner):
        c = re.sub(r"^[^:()]*:\s*", "", c) if re.match(r"^[A-Za-z /-]+:\s", c) else c
        children.extend(split_top(c, ","))
    return name, children


def spec_rows():
    text = SPEC.read_text()
    sec7 = text.split("## 7.", 1)[1].split("\n## 8.", 1)[0]
    rows, section, title = [], None, None
    seen = set()
    for line in ("## 7." + sec7).splitlines():
        h = re.match(r"^### (7\.\d+) (.*)$", line)
        if h:
            section, title = h.group(1), h.group(2)
            rows.append(("section", section, title))
            continue
        if not line.startswith("- ") or section is None:
            continue
        body = line[2:].strip().rstrip(".")
        if body.startswith("**"):
            name = re.sub(r"\*\*", "", body)
            rid = f"{section}/{slug(name.split(':')[0])}"
            rows.append(("item", rid, name, 0))
            continue
        label = None
        m = re.match(r"^([A-Z0-9][A-Za-z0-9 /&-]{0,40}):\s+(.*)$", body)
        if m:
            label, body = m.group(1), m.group(2)
        sentences = [s for s in re.split(r"\.\s+(?=[A-Z])", body) if s]
        for sentence in sentences:
            for item in split_top(sentence):
                name, children = parse_item(item)
                display = f"{label}: {name}" if label else name
                base = f"{section}/{slug(label) + '/' if label else ''}{slug(name)}"
                rid, n = base, 2
                while rid in seen:
                    rid, n = f"{base}-{n}", n + 1
                seen.add(rid)
                rows.append(("item", rid, display, 0))
                for c in children:
                    cid, k = f"{rid}/{slug(c)}", 2
                    while cid in seen:
                        cid, k = f"{rid}/{slug(c)}-{k}", k + 1
                    seen.add(cid)
                    rows.append(("item", cid, c, 1))
    return rows


def existing_status():
    status = {}
    if not OUT.exists():
        return status
    for line in OUT.read_text().splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 7 and cells[0].startswith("`"):
            status[cells[0].strip("`")] = cells[2:7]
    return status


def render(rows, status):
    def cols(rid, default_module):
        s = status.get(rid)
        if s:
            return s
        return ["not started", default_module, "—", "—", ""]

    counts = {k: 0 for k in STATUSES}
    lines = []

    def row(rid, name, default_module, indent=0):
        c = cols(rid, default_module)
        counts[c[0]] = counts.get(c[0], 0) + 1
        prefix = "↳ " if indent else ""
        name = name.replace("|", "\\|")
        lines.append(f"| `{rid}` | {prefix}{name} | {c[0]} | {c[1]} | {c[2]} | {c[3]} | {c[4]} |")

    header = "| ID | Feature | Status | Module | Test | MCP tool | Notes |\n|---|---|---|---|---|---|---|"
    lines.append("## Platform (SPEC §2–§6, §8–§9)\n")
    lines.append(header)
    for rid, name in PLATFORM:
        row(rid, name, "—")
    ids = {r[1] for r in rows if r[0] == "item"} | {p[0] for p in PLATFORM} | {d[0] for d in DISCOVERED}
    for r in rows:
        if r[0] == "section":
            lines.append(f"\n## {r[1]} {r[2]}\n")
            lines.append(header)
        else:
            _, rid, name, indent = r
            row(rid, name, SECTION_MODULE.get(rid.split("/")[0], "—"), indent)
    lines.append("\n## Discovered (SolidWorks capabilities not listed in SPEC §7)\n")
    lines.append(header)
    for rid, name in DISCOVERED:
        row(rid, name, SECTION_MODULE.get("7.2"))
    orphans = [k for k in status if k not in ids]
    if orphans:
        lines.append("\n## Orphaned (no longer in SPEC; review)\n")
        lines.append(header)
        for k in sorted(orphans):
            row(k, "(removed from spec)", "—")

    total = sum(counts.values())
    summary = " · ".join(f"{k}: {counts.get(k, 0)}" for k in STATUSES)
    head = f"""# Forge feature parity matrix

Source of truth for parity (SPEC §0.3). Generated from SPEC.md §7 by `scripts/features.py`,
which preserves the Status / Module / Test / MCP tool / Notes columns of existing rows —
edit those columns by hand, then re-run the script.

**Status definitions** (SPEC §0.2): `not started` · `in progress` (partial, or working below
the feature-tree level) · `done` (regenerates, round-trips save/load, undo/redo, command +
MCP, tests) · `verified` (done + golden/e2e coverage + reviewed on macOS).

**Totals:** {total} rows — {summary}
"""
    return head + "\n" + "\n".join(lines) + "\n"


def main():
    rows = spec_rows()
    content = render(rows, existing_status())
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != content:
            print("FEATURES.md is out of date; run scripts/features.py", file=sys.stderr)
            sys.exit(1)
        return
    OUT.write_text(content)
    print(f"wrote {OUT} ({sum(1 for r in rows if r[0] == 'item')} spec rows)")


if __name__ == "__main__":
    main()
