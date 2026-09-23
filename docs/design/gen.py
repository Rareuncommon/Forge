#!/usr/bin/env python3
"""Generates the Forge UI design artboards (.dc.html) from the app's own icon set."""
import math, re, json, datetime, os

ROOT = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(ROOT, "..", "..", "Sources", "ForgeApp", "Icons.swift")
ICONS = dict(re.findall(r'^\s*\.(\w+):\s*"([^"]*)",?$', open(SWIFT).read(), re.M))

LIGHT = dict(
    chrome="#E9E9EC", chrome2="#F2F2F4", panel="#FBFBFC", surface="#FFFFFF", line="#D5D5DA", line2="#E4E4E8",
    text="#1D1D1F", text2="#5E5E66", text3="#8A8A91", accent="#1F5FD6", accentText="#1A4FB3", accentSoft="#E1EAFB",
    hover="#E2E2E7", field="#FFFFFF", fieldLine="#C9C9CF", ok="#1F5FD6",
    vpTop="#F6F7F9", vpBottom="#D8DDE5", under="#1F5FD6", full="#1D1D1F", over="#C62F20", preview="#D98200",
    glyphBg="#FFFFFF", grid="#C9CFD8", grid2="#B3BBC7", shadow="0 8px 24px rgba(20,24,33,0.14), 0 1px 3px rgba(20,24,33,0.12)",
    hud="rgba(255,255,255,0.86)", dim="#1D1D1F",
)
DARK = dict(
    chrome="#1F2023", chrome2="#26272B", panel="#232427", surface="#2C2D31", line="#3A3B40", line2="#323338",
    text="#EDEDEF", text2="#A6A6AE", text3="#7C7C84", accent="#4C8DFF", accentText="#8DB6FF", accentSoft="#243452",
    hover="#34353A", field="#1B1C1F", fieldLine="#45464C", ok="#4C8DFF",
    vpTop="#2E323A", vpBottom="#17191D", under="#5E9BFF", full="#F2F2F4", over="#FF6B5B", preview="#FFB23E",
    glyphBg="#2C2D31", grid="#2A2E35", grid2="#3A404A", shadow="0 10px 30px rgba(0,0,0,0.45), 0 1px 3px rgba(0,0,0,0.5)",
    hud="rgba(44,45,49,0.88)", dim="#D9DBE0",
)
SANS = "-apple-system, BlinkMacSystemFont, &#39;SF Pro Text&#39;, &#39;IBM Plex Sans&#39;, sans-serif"
MONO = "&#39;SF Mono&#39;, &#39;IBM Plex Mono&#39;, ui-monospace, monospace"
SANS_CSS = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'IBM Plex Sans', sans-serif"
MONO_CSS = "'SF Mono', 'IBM Plex Mono', ui-monospace, monospace"
FONTS = '<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&amp;family=IBM+Plex+Sans:wght@400;500;600&amp;display=swap">'


def icon(name, size=20, accent=None, color="currentColor"):
    accent = accent or "currentColor"
    parts = []
    for layer in ICONS[name].split(" | "):
        layer = layer.strip()
        kind = "s"
        for p, k in (("ad:", "ad"), ("af:", "af"), ("a:", "a"), ("d:", "d"), ("f:", "f")):
            if layer.startswith(p):
                kind, layer = k, layer[len(p):]
                break
        base = 'stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"'
        if kind == "s": attrs = f'fill="none" stroke="{color}" {base}'
        elif kind == "a": attrs = f'fill="none" stroke="{accent}" {base}'
        elif kind == "d": attrs = f'fill="none" stroke="{color}" stroke-dasharray="2 2.5" {base}'
        elif kind == "ad": attrs = f'fill="none" stroke="{accent}" stroke-dasharray="2 2.5" {base}'
        elif kind == "f": attrs = f'fill="{color}" stroke="none"'
        else: attrs = f'fill="{accent}" fill-opacity="0.22" stroke="none"'
        parts.append(f'<path d="{layer}" {attrs}></path>')
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" aria-hidden="true" '
            f'style="flex-shrink: 0; display: block">' + "".join(parts) + "</svg>")


def page(title, w, h, body, T, extra_css=""):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
{FONTS}
<style>
body{{margin:0;font-family:{SANS_CSS};background:{T['chrome']};color:{T['text']};-webkit-font-smoothing:antialiased}}
a{{color:{T['accentText']}}}a:hover{{color:{T['accent']}}}
button{{font-family:inherit}}
input,select{{font-family:inherit}}
{extra_css}
</style>
</helmet>
{body}
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":{w},"height":{h}}}}}'>
class Component extends DCLogic {{
renderVals() {{
return {{}};
}}
}}
</script>
</body>
</html>
"""

# ---------------------------------------------------------------- window chrome


def titlebar(T, tabs, active, doc="Bracket", sub="Part · Edited"):
    tab_html = ""
    for t in tabs:
        on = t == active
        style = (f"height: 26px; padding: 0 12px; border: none; border-radius: 6px; font-size: 12.5px; "
                 f"font-weight: {600 if on else 500}; color: {T['text'] if on else T['text2']}; "
                 f"background: {T['surface'] if on else 'transparent'}; "
                 f"box-shadow: {'0 1px 2px rgba(0,0,0,0.12), 0 0 0 0.5px rgba(0,0,0,0.06)' if on else 'none'}")
        tab_html += f'<button type="button" style="{style}">{t}</button>'
    light = lambda c: f'<div style="width: 12px; height: 12px; border-radius: 6px; background: {c}; box-shadow: inset 0 0 0 0.5px rgba(0,0,0,0.18)"></div>'
    ib = lambda n, label: (f'<button type="button" aria-label="{label}" style="width: 30px; height: 28px; border: none; border-radius: 6px; '
                           f'background: transparent; color: {T["text2"]}; display: flex; align-items: center; justify-content: center">{icon(n, 18)}</button>')
    return f"""<div style="height: 52px; flex-shrink: 0; display: flex; align-items: center; gap: 14px; padding: 0 14px 0 18px; background: {T['chrome']}; border-bottom: 1px solid {T['line']}">
<div style="display: flex; gap: 8px" aria-hidden="true">{light('#FF5F57')}{light('#FEBC2E')}{light('#28C840')}</div>
<div style="display: flex; align-items: center; gap: 8px; margin-left: 10px; min-width: 200px">
<div style="color: {T['accent']}">{icon('part', 22, T['accent'], T['text'])}</div>
<div style="display: flex; flex-direction: column; line-height: 1.15"><span style="font-size: 13px; font-weight: 600">{doc}</span><span style="font-size: 11px; color: {T['text2']}">{sub}</span></div>
</div>
<div style="display: flex; gap: 2px">{ib('undo', 'Undo')}{ib('redo', 'Redo')}{ib('save', 'Save')}</div>
<div style="flex-grow: 1; display: flex; justify-content: center">
<div role="tablist" style="display: flex; gap: 2px; padding: 3px; border-radius: 8px; background: {T['line2']}">{tab_html}</div>
</div>
<label style="display: flex; align-items: center; gap: 8px; width: 250px; height: 28px; padding: 0 10px; box-sizing: border-box; border-radius: 7px; background: {T['line2']}; color: {T['text2']}; font-size: 12.5px">
{icon('search', 15)}<input type="text" placeholder="Search commands" aria-label="Search commands" style="flex-grow: 1; min-width: 0; border: none; background: transparent; font-size: 12.5px; color: {T['text']}; outline: none"><span style="font-family: {MONO_CSS}; font-size: 11px; color: {T['text3']}">⌘K</span>
</label>
<button type="button" style="height: 28px; display: flex; align-items: center; gap: 6px; padding: 0 12px; border-radius: 7px; border: 1px solid {T['line']}; background: {T['surface']}; color: {T['text']}; font-size: 12.5px; font-weight: 500">{icon('sparkle', 15, T['accent'])}Ask Forge</button>
</div>"""


def rb_large(T, name, label, active=False, chevron=False, disabled=False):
    bg = T['accentSoft'] if active else "transparent"
    fg = T['accentText'] if active else T['text']
    op = "0.4" if disabled else "1"
    chev = f'<span style="position: absolute; right: 3px; top: 24px; color: {T["text3"]}">{icon("chevronDown", 10)}</span>' if chevron else ""
    return (f'<button type="button" style="position: relative; width: 66px; height: 64px; flex-shrink: 0; display: flex; flex-direction: column; align-items: center; '
            f'justify-content: flex-start; gap: 5px; padding: 7px 2px 0; box-sizing: border-box; border: none; border-radius: 8px; background: {bg}; color: {fg}; opacity: {op}">'
            f'{icon(name, 26, T["accent"])}<span style="font-size: 11px; line-height: 1.2; text-align: center; white-space: pre-line">{label}</span>{chev}</button>')


def rb_small(T, name, label, active=False):
    bg = T['accentSoft'] if active else "transparent"
    fg = T['accentText'] if active else T['text']
    return (f'<button type="button" style="height: 21px; display: flex; align-items: center; gap: 6px; padding: 0 8px 0 5px; border: none; border-radius: 5px; '
            f'background: {bg}; color: {fg}; font-size: 12px; white-space: nowrap">{icon(name, 16, T["accent"])}{label}</button>')


def rb_group(T, label, items):
    return (f'<div style="display: flex; flex-direction: column; justify-content: space-between; height: 84px; padding: 0 6px; flex-shrink: 0">'
            f'<div style="display: flex; gap: 2px; align-items: flex-start">{"".join(items)}</div>'
            f'<div style="font-size: 10.5px; color: {T["text2"]}; text-align: center; letter-spacing: 0.02em">{label}</div></div>')


def rb_col(items):
    return f'<div style="display: flex; flex-direction: column; gap: 0px">{"".join(items)}</div>'


def rb_sep(T):
    return f'<div style="width: 1px; height: 70px; background: {T["line"]}; flex-shrink: 0; align-self: flex-start; margin-top: 4px"></div>'


def ribbon(T, groups):
    inner = rb_sep(T).join(groups)
    return (f'<div style="height: 92px; flex-shrink: 0; display: flex; align-items: flex-start; gap: 4px; padding: 6px 10px 0; box-sizing: border-box; '
            f'background: {T["chrome2"]}; border-bottom: 1px solid {T["line"]}; overflow: hidden">{inner}</div>')


def statusbar(T, left, items):
    cells = "".join(f'<div style="display: flex; align-items: center; gap: 6px; padding: 0 12px; height: 100%; border-left: 1px solid {T["line"]}">{c}</div>' for c in items)
    return (f'<div style="height: 28px; flex-shrink: 0; display: flex; align-items: center; background: {T["chrome"]}; border-top: 1px solid {T["line"]}; font-size: 11.5px; color: {T["text2"]}">'
            f'<div style="flex-grow: 1; padding: 0 14px; display: flex; align-items: center; gap: 8px">{left}</div>{cells}</div>')


def chip(T, text, color, filled=False):
    if filled:
        return f'<span style="display: inline-flex; align-items: center; gap: 5px; height: 18px; padding: 0 7px; border-radius: 9px; background: {color}; color: #FFFFFF; font-size: 11px; font-weight: 600">{text}</span>'
    return (f'<span style="display: inline-flex; align-items: center; gap: 5px; font-size: 11.5px; color: {color}; font-weight: 500">'
            f'<span style="width: 7px; height: 7px; border-radius: 4px; background: {color}"></span>{text}</span>')

# ---------------------------------------------------------------- feature tree


def tree_row(T, name, label, depth=0, disclosure=None, selected=False, muted=False, trail="", bold=False, tint=None):
    disc = ""
    if disclosure == "open": disc = icon("chevronDown", 11)
    elif disclosure == "closed": disc = icon("chevronRight", 11)
    bg = T['accentSoft'] if selected else "transparent"
    fg = T['text3'] if muted else (T['accentText'] if selected else T['text'])
    return (f'<button type="button" style="width: 100%; height: 25px; display: flex; align-items: center; gap: 6px; padding: 0 8px 0 {6 + depth * 16}px; box-sizing: border-box; '
            f'border: none; border-radius: 6px; background: {bg}; color: {fg}; font-size: 12.5px; font-weight: {600 if bold else 400}; text-align: left">'
            f'<span style="width: 11px; display: flex; color: {T["text3"]}">{disc}</span>'
            f'<span style="color: {T["text2"] if not selected else T["accentText"]}">{icon(name, 17, tint or T["accent"])}</span>'
            f'<span style="flex-grow: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{label}</span>{trail}</button>')


def sidebar(T, rows, width=272):
    tabs = ""
    for i, (n, label) in enumerate((("part", "Feature tree"), ("folder", "Configurations"), ("appearance", "Display states"), ("equations", "Equations"))):
        on = i == 0
        tabs += (f'<button type="button" aria-label="{label}" style="flex-grow: 1; height: 28px; border: none; border-radius: 6px; display: flex; align-items: center; justify-content: center; '
                 f'background: {T["surface"] if on else "transparent"}; color: {T["accentText"] if on else T["text2"]}; box-shadow: {"0 1px 2px rgba(0,0,0,0.1)" if on else "none"}">{icon(n, 17, T["accent"])}</button>')
    return f"""<div style="width: {width}px; flex-shrink: 0; display: flex; flex-direction: column; background: {T['panel']}; border-right: 1px solid {T['line']}">
<div style="display: flex; gap: 2px; margin: 10px 10px 8px; padding: 2px; border-radius: 8px; background: {T['line2']}">{tabs}</div>
<label style="display: flex; align-items: center; gap: 6px; margin: 0 10px 8px; height: 26px; padding: 0 8px; border-radius: 6px; background: {T['field']}; border: 1px solid {T['line']}; color: {T['text3']}">{icon('search', 14)}<input type="text" placeholder="Filter features" aria-label="Filter features" style="flex-grow: 1; min-width: 0; border: none; background: transparent; font-size: 12px; color: {T['text']}; outline: none"></label>
<div style="display: flex; flex-direction: column; gap: 1px; padding: 0 6px">{''.join(rows)}</div>
</div>"""


def rollback(T):
    return (f'<div style="height: 14px; display: flex; align-items: center; padding: 0 8px" aria-label="Rollback bar">'
            f'<div style="flex-grow: 1; height: 3px; border-radius: 2px; background: {T["accent"]}"></div></div>')


def status_dot(T, color, label):
    return f'<span aria-label="{label}" title="{label}" style="width: 7px; height: 7px; border-radius: 4px; background: {color}; flex-shrink: 0"></span>'

# ---------------------------------------------------------------- property manager


def pm_header(T, name, title, sub):
    btn = lambda n, label, primary=False: (
        f'<button type="button" aria-label="{label}" title="{label}" style="width: 34px; height: 28px; border-radius: 7px; display: flex; align-items: center; justify-content: center; '
        + (f'border: none; background: {T["ok"]}; color: #FFFFFF">' if primary else f'border: 1px solid {T["line"]}; background: {T["surface"]}; color: {T["text2"]}">')
        + icon(n, 17) + '</button>')
    return f"""<div style="padding: 14px 14px 12px; border-bottom: 1px solid {T['line']}">
<div style="display: flex; align-items: center; gap: 9px">
<div style="width: 32px; height: 32px; border-radius: 8px; background: {T['accentSoft']}; color: {T['accentText']}; display: flex; align-items: center; justify-content: center">{icon(name, 22, T['accent'])}</div>
<div style="flex-grow: 1; display: flex; flex-direction: column; line-height: 1.2"><span style="font-size: 14px; font-weight: 600">{title}</span><span style="font-size: 11.5px; color: {T['text2']}">{sub}</span></div>
</div>
<div style="display: flex; gap: 6px; margin-top: 12px">{btn('check', 'OK (Return)', True)}{btn('xmark', 'Cancel (Esc)')}<div style="flex-grow: 1"></div>{btn('hideShow', 'Preview')}{btn('pin', 'Keep open')}</div>
</div>"""


def pm_group(T, title, body, open_=True, checkbox=None):
    chev = icon("chevronDown" if open_ else "chevronRight", 12)
    cb = ""
    if checkbox is not None:
        cb = f'<input type="checkbox" aria-label="{title}" {"checked" if checkbox else ""} style="margin: 0; accent-color: {T["accent"]}">'
    content = f'<div style="display: flex; flex-direction: column; gap: 9px; padding: 2px 14px 14px">{body}</div>' if open_ else ""
    return (f'<div style="border-bottom: 1px solid {T["line2"]}">'
            f'<button type="button" style="width: 100%; height: 34px; display: flex; align-items: center; gap: 7px; padding: 0 14px; border: none; background: transparent; color: {T["text"]}; font-size: 12px; font-weight: 600; text-align: left">'
            f'<span style="color: {T["text3"]}; display: flex">{chev}</span>{cb}<span style="flex-grow: 1">{title}</span></button>{content}</div>')


def field(T, label, value, unit="", icon_name=None, mono=True, width=None, disabled=False):
    ic = f'<span style="color: {T["text2"]}; display: flex">{icon(icon_name, 16, T["accent"])}</span>' if icon_name else ""
    op = "opacity: 0.45;" if disabled else ""
    uid = re.sub(r"\W", "", label.lower())
    return (f'<div style="display: flex; align-items: center; gap: 8px; {op}">{ic}<label for="f-{uid}" style="font-size: 12px; color: {T["text2"]}; width: 74px; flex-shrink: 0">{label}</label>'
            f'<div style="flex-grow: 1; min-width: 0; display: flex; align-items: center; height: 26px; padding: 0 8px; border-radius: 6px; background: {T["field"]}; border: 1px solid {T["fieldLine"]}">'
            f'<input id="f-{uid}" type="text" value="{value}" {"disabled" if disabled else ""} style="flex-grow: 1; min-width: 0; border: none; background: transparent; outline: none; color: {T["text"]}; font-size: 12.5px; font-family: {MONO_CSS if mono else SANS_CSS}">'
            f'<span style="font-size: 11.5px; color: {T["text3"]}">{unit}</span></div></div>')


def select(T, label, value, icon_name=None, extra=""):
    ic = f'<span style="color: {T["text2"]}; display: flex">{icon(icon_name, 16, T["accent"])}</span>' if icon_name else ""
    uid = re.sub(r"\W", "", label.lower())
    lab = f'<label for="s-{uid}" style="font-size: 12px; color: {T["text2"]}; width: 74px; flex-shrink: 0">{label}</label>' if label else ""
    return (f'<div style="display: flex; align-items: center; gap: 8px">{ic}{lab}'
            f'<div style="position: relative; flex-grow: 1; min-width: 0; display: flex; align-items: center; height: 26px; border-radius: 6px; background: {T["surface"]}; border: 1px solid {T["fieldLine"]}; box-shadow: 0 1px 1px rgba(0,0,0,0.04)">'
            f'<select id="s-{uid}" aria-label="{label or value}" style="appearance: none; -webkit-appearance: none; flex-grow: 1; height: 100%; padding: 0 26px 0 8px; border: none; background: transparent; color: {T["text"]}; font-size: 12.5px"><option>{value}</option></select>'
            f'<span style="position: absolute; right: 7px; color: {T["text2"]}; display: flex; pointer-events: none">{icon("chevronDown", 12)}</span></div>{extra}</div>')


def sel_box(T, color, items, placeholder):
    inner = "".join(f'<div style="display: flex; align-items: center; gap: 6px; height: 22px; padding: 0 7px; border-radius: 5px; background: {T["accentSoft"]}; color: {T["accentText"]}; font-size: 12px">{icon(i, 14, T["accent"])}{t}</div>' for i, t in items)
    if not items:
        inner = f'<span style="font-size: 12px; color: {T["text3"]}">{placeholder}</span>'
    return (f'<div style="display: flex; flex-direction: column; gap: 4px; min-height: 40px; padding: 6px; box-sizing: border-box; border-radius: 7px; '
            f'background: {T["field"]}; border: 1.5px solid {color}">{inner}</div>')


def checkbox(T, label, checked=False):
    uid = re.sub(r"\W", "", label.lower())
    return (f'<div style="display: flex; align-items: center; gap: 8px"><input id="c-{uid}" type="checkbox" {"checked" if checked else ""} style="margin: 0; accent-color: {T["accent"]}">'
            f'<label for="c-{uid}" style="font-size: 12.5px; color: {T["text"]}">{label}</label></div>')


def hud(T, items, x, y):
    cells = []
    for it in items:
        if it == "|":
            cells.append(f'<div style="width: 1px; height: 20px; background: {T["line"]}; margin: 0 3px"></div>')
            continue
        n, label, drop = it
        chev = f'<span style="color: {T["text3"]}; display: flex">{icon("chevronDown", 9)}</span>' if drop else ""
        cells.append(f'<button type="button" aria-label="{label}" title="{label}" style="height: 30px; display: flex; align-items: center; gap: 1px; padding: 0 6px; border: none; border-radius: 6px; background: transparent; color: {T["text"]}">{icon(n, 19, T["accent"])}{chev}</button>')
    return (f'<div style="position: absolute; left: {x}px; top: {y}px; transform: translateX(-50%); display: flex; align-items: center; gap: 1px; padding: 3px 5px; '
            f'border-radius: 10px; background: {T["hud"]}; box-shadow: {T["shadow"]}; border: 1px solid {T["line"]}">{"".join(cells)}</div>')


HUD_ITEMS = [("zoomFit", "Zoom to fit (F)", False), ("zoomArea", "Zoom to area", False), ("prevView", "Previous view", False), "|",
             ("section", "Section view", False), ("viewOrient", "View orientation (Space)", True), ("displayStyle", "Display style", True),
             ("hideShow", "Hide/show items", True), ("appearance", "Edit appearance", True), ("viewSettings", "View settings", True)]


def confirm_corner(T, x, y):
    return (f'<div style="position: absolute; left: {x}px; top: {y}px; display: flex; gap: 6px">'
            f'<button type="button" aria-label="OK" style="width: 40px; height: 40px; border-radius: 10px; border: none; background: {T["ok"]}; color: #FFFFFF; display: flex; align-items: center; justify-content: center; box-shadow: {T["shadow"]}">{icon("check", 24)}</button>'
            f'<button type="button" aria-label="Cancel" style="width: 40px; height: 40px; border-radius: 10px; border: 1px solid {T["line"]}; background: {T["hud"]}; color: {T["text"]}; display: flex; align-items: center; justify-content: center; box-shadow: {T["shadow"]}">{icon("xmark", 22)}</button></div>')

# ---------------------------------------------------------------- 3D part (isometric, analytic)

S, OX, OY = 2.75, 450, 250
def P(x, y, z):
    return (OX + S * 0.8660254 * (x - y), OY + S * (0.5 * (x + y) - z))

def poly(pts, **attrs):
    d = "M" + " L".join(f"{a:.1f} {b:.1f}" for a, b in pts) + " Z"
    a = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in attrs.items())
    return f'<path d="{d}" {a}></path>'

def circle3(cx, cy, cz, r, plane, n=72):
    out = []
    for i in range(n):
        t = 2 * math.pi * i / n
        if plane == "xy": out.append(P(cx + r * math.cos(t), cy + r * math.sin(t), cz))
        else: out.append(P(cx + r * math.cos(t), cy, cz + r * math.sin(t)))
    return out

def hull(points):
    pts = sorted(set((round(a, 2), round(b, 2)) for a, b in points))
    def cross(o, a, b): return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0: lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0: up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]


def part_svg(T, w, h, preview=True, selected_face=False):
    edge = "#262B33"
    top, right, front = "url(#gTop)", "url(#gRight)", "url(#gFront)"
    g = []
    g.append(f"""<defs>
<linearGradient id="gTop" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#E3E8EF"></stop><stop offset="1" stop-color="#C7D0DC"></stop></linearGradient>
<linearGradient id="gRight" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#A2AFC0"></stop><stop offset="1" stop-color="#8795A8"></stop></linearGradient>
<linearGradient id="gFront" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#B9C4D2"></stop><stop offset="1" stop-color="#A5B2C3"></stop></linearGradient>
<linearGradient id="gCyl" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="{T['preview']}" stop-opacity="0.28"></stop><stop offset="0.45" stop-color="{T['preview']}" stop-opacity="0.12"></stop><stop offset="1" stop-color="{T['preview']}" stop-opacity="0.34"></stop></linearGradient>
</defs>""")
    E = dict(stroke=edge, stroke_width="1.3", stroke_linejoin="round")
    # upright top (z=70), +X faces, upright front (y=12) with holes, base top (z=12), base front (y=80)
    g.append(poly([P(0, 0, 70), P(120, 0, 70), P(120, 12, 70), P(0, 12, 70)], fill=top, **E))
    g.append(poly([P(120, 0, 70), P(120, 12, 70), P(120, 12, 12), P(120, 80, 12), P(120, 80, 0), P(120, 0, 0)], fill=right, **E))
    g.append(poly([P(0, 12, 70), P(120, 12, 70), P(120, 12, 12), P(0, 12, 12)], fill=front, **E))
    for i, hx in enumerate((28, 92)):
        near = circle3(hx, 12, 46, 8, "xz")
        far = [(a - S * 0.8660254 * -12 * -1 * 1, b) for a, b in near]  # placeholder, replaced below
        far = [P(hx + 8 * math.cos(2 * math.pi * k / 72), 0, 46 + 8 * math.sin(2 * math.pi * k / 72)) for k in range(72)]
        g.append(f'<clipPath id="hole{i}">{poly(near)}</clipPath>')
        g.append(poly(near, fill="#56617280", stroke="none"))
        g.append(poly(near, fill="#4A5465", stroke="none"))
        g.append(f'<g clip-path="url(#hole{i})">{poly(far, fill=T["vpBottom"], stroke="none")}</g>')
        g.append(poly(near, fill="none", **E))
    base_top = [P(0, 12, 12), P(120, 12, 12), P(120, 80, 12), P(0, 80, 12)]
    g.append(poly(base_top, fill=top, **E))
    if selected_face:
        g.append(poly(base_top, fill=T['accent'], fill_opacity="0.18", stroke=T['accent'], stroke_width="2"))
    g.append(poly([P(0, 80, 12), P(120, 80, 12), P(120, 80, 0), P(0, 80, 0)], fill=front, **E))
    # fillet between upright front and base top: shaded strip
    g.append(poly([P(0, 12, 17), P(120, 12, 17), P(120, 17, 12), P(0, 17, 12)], fill="#D1D9E3", stroke="none"))
    g.append(f'<path d="M{P(0,12,17)[0]:.1f} {P(0,12,17)[1]:.1f} L{P(120,12,17)[0]:.1f} {P(120,12,17)[1]:.1f} M{P(0,17,12)[0]:.1f} {P(0,17,12)[1]:.1f} L{P(120,17,12)[0]:.1f} {P(120,17,12)[1]:.1f}" stroke="{edge}" stroke-opacity="0.35" stroke-width="1" fill="none"></path>')
    if preview:
        cx, cy, r, z0, z1 = 60, 50, 15, 12, 37
        bot, topc = circle3(cx, cy, z0, r, "xy"), circle3(cx, cy, z1, r, "xy")
        g.append(poly(hull(bot + topc), fill="url(#gCyl)", stroke=T['preview'], stroke_width="1.4"))
        g.append(poly(bot, fill="none", stroke=T['under'], stroke_width="2"))
        g.append(poly(topc, fill=T['preview'], fill_opacity="0.22", stroke=T['preview'], stroke_width="1.6"))
        # Instant3D drag arrow and value callout
        ax, ay = P(cx, cy, z1)
        g.append(f'<path d="M{ax:.1f} {ay:.1f} V{ay-64:.1f}" stroke="{T["preview"]}" stroke-width="2.5" stroke-linecap="round"></path>')
        g.append(f'<path d="M{ax-7:.1f} {ay-56:.1f} L{ax:.1f} {ay-70:.1f} L{ax+7:.1f} {ay-56:.1f} Z" fill="{T["preview"]}"></path>')
        g.append(f'<circle cx="{ax:.1f}" cy="{ay:.1f}" r="3.5" fill="{T["preview"]}"></circle>')
    return f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" aria-label="Isometric view of the bracket with an extrude preview" style="position: absolute; left: 0; top: 0">{"".join(g)}</svg>'


def triad(T, x, y, labels=("X", "Y", "Z"), dirs=((0.866, 0.5), (0, -1), (-0.866, 0.5))):
    cols = ("#D6453A", "#2F9E55", "#2F6BE0")
    parts = []
    for (dx, dy), c, l in zip(dirs, cols, labels):
        ex, ey = 40 + dx * 26, 40 + dy * 26
        parts.append(f'<path d="M40 40 L{ex:.1f} {ey:.1f}" stroke="{c}" stroke-width="2.2" stroke-linecap="round"></path>')
        parts.append(f'<text x="{40 + dx * 34:.1f}" y="{40 + dy * 34 + 4:.1f}" text-anchor="middle" font-size="11" font-weight="600" fill="{c}" font-family="{SANS}">{l}</text>')
    return f'<svg width="80" height="80" viewBox="0 0 80 80" aria-label="Axis triad" style="position: absolute; left: {x}px; top: {y}px">{"".join(parts)}</svg>'

# ---------------------------------------------------------------- artboards


def features_ribbon(T, active="extrude"):
    L, Sm = lambda *a, **k: rb_large(T, *a, **k), lambda *a, **k: rb_small(T, *a, **k)
    return ribbon(T, [
        rb_group(T, "Boss / Base", [L("extrude", "Extruded\nBoss/Base", active == "extrude"), L("revolve", "Revolved\nBoss/Base"),
                                     rb_col([Sm("sweep", "Swept"), Sm("loft", "Lofted"), Sm("combine", "Boundary")])]),
        rb_group(T, "Cut", [L("cutExtrude", "Extruded\nCut"), L("hole", "Hole\nWizard", chevron=True),
                             rb_col([Sm("cutRevolve", "Revolved Cut"), Sm("sweep", "Swept Cut"), Sm("loft", "Lofted Cut")])]),
        rb_group(T, "Modify", [L("fillet", "Fillet", chevron=True),
                                rb_col([Sm("chamfer", "Chamfer"), Sm("shell", "Shell"), Sm("draft", "Draft")]), rb_col([Sm("rib", "Rib"), Sm("combine", "Combine"), Sm("move", "Move/Copy")])]),
        rb_group(T, "Pattern", [L("linearPattern", "Linear\nPattern", chevron=True), rb_col([Sm("circularPattern", "Circular"), Sm("mirror", "Mirror"), Sm("spline", "Curve Driven")])]),
        rb_group(T, "Reference", [rb_col([Sm("plane", "Plane"), Sm("axis", "Axis"), Sm("coordSys", "Coordinate System")])]),
        rb_group(T, "Evaluate", [L("measure", "Measure"), L("massProps", "Mass\nProperties")]),
    ])


def main_board():
    T = LIGHT
    rows = [
        tree_row(T, "part", "Bracket", disclosure="open", bold=True),
        tree_row(T, "history", "History", 1, "closed"),
        tree_row(T, "sensor", "Sensors", 1),
        tree_row(T, "annotation", "Annotations", 1, "closed"),
        tree_row(T, "material", "6061-T6 Aluminium", 1),
        tree_row(T, "plane", "Front Plane", 1, tint=T['text3']),
        tree_row(T, "plane", "Top Plane", 1, tint=T['text3']),
        tree_row(T, "plane", "Right Plane", 1, tint=T['text3']),
        tree_row(T, "origin", "Origin", 1, tint="#D6453A"),
        tree_row(T, "extrude", "Base Plate", 1, "closed"),
        tree_row(T, "extrude", "Upright", 1, "closed"),
        tree_row(T, "cutExtrude", "Mounting Holes", 1, "closed"),
        tree_row(T, "fillet", "Fillet1", 1),
        tree_row(T, "sketch", "Sketch3", 1, selected=True, trail=status_dot(T, T['full'], "Fully defined")),
        rollback(T),
    ]
    pm = (pm_header(T, "extrude", "Boss-Extrude", "Sketch3 · Front of base")
          + pm_group(T, "From", select(T, "", "Sketch Plane"))
          + pm_group(T, "Direction 1",
                     select(T, "", "Blind", "extrude", extra=f'<button type="button" aria-label="Reverse direction" style="width: 28px; height: 26px; border-radius: 6px; border: 1px solid {T["fieldLine"]}; background: {T["surface"]}; color: {T["text2"]}; display: flex; align-items: center; justify-content: center">{icon("prevView", 15)}</button>')
                     + sel_box(T, T['line'], [], "Direction vector (optional)")
                     + field(T, "Depth", "25.00", "mm", "smartDimension")
                     + checkbox(T, "Draft outward")
                     + field(T, "Draft angle", "0.00", "°", disabled=True)
                     + checkbox(T, "Merge result", True))
          + pm_group(T, "Direction 2", "", open_=False, checkbox=False)
          + pm_group(T, "Thin Feature", "", open_=False, checkbox=False)
          + pm_group(T, "Selected Contours", sel_box(T, T['accent'], [("sketch", "Sketch3 · Region 1")], ""))
          + pm_group(T, "Feature Scope", "", open_=False))
    tip = (f'<div style="margin: 14px; padding: 10px 12px; border-radius: 8px; background: {T["chrome2"]}; font-size: 11.5px; line-height: 1.45; color: {T["text2"]}">'
           f'Drag the arrow in the view or type a depth. Units work anywhere: <span style="font-family: {MONO_CSS}; color: {T["text"]}">1 in</span>, <span style="font-family: {MONO_CSS}; color: {T["text"]}">=Thickness*2</span>.</div>')
    vp_w, vp_h = 1440 - 272 - 312, 900 - 52 - 92 - 28
    viewport = f"""<div style="position: relative; flex-grow: 1; overflow: hidden; background: linear-gradient(180deg, {T['vpTop']} 0%, {T['vpBottom']} 100%)">
{part_svg(T, vp_w, vp_h)}
{hud(T, HUD_ITEMS, vp_w // 2, 12)}
{confirm_corner(T, vp_w - 104, 14)}
<div style="position: absolute; left: {int(P(60,50,37)[0]) + 18}px; top: {int(P(60,50,37)[1]) - 64}px; display: flex; align-items: center; gap: 6px; height: 28px; padding: 0 4px 0 10px; border-radius: 7px; background: {T['surface']}; border: 1.5px solid {T['preview']}; box-shadow: {T['shadow']}">
<label for="depth-callout" style="font-size: 11px; color: {T['text2']}">Depth</label>
<input id="depth-callout" type="text" value="25.00 mm" style="width: 76px; border: none; background: transparent; outline: none; font-family: {MONO_CSS}; font-size: 13px; font-weight: 500; color: {T['text']}">
</div>
{triad(T, 16, vp_h - 84)}
<div style="position: absolute; left: 90px; top: {vp_h - 34}px; font-size: 11.5px; color: {T['text2']}">Isometric</div>
</div>"""
    body = f"""<div style="width: 1440px; height: 900px; display: flex; flex-direction: column; overflow: hidden; background: {T['chrome']}">
{titlebar(T, ["Features", "Sketch", "Surfaces", "Sheet Metal", "Evaluate", "View"], "Features")}
{features_ribbon(T)}
<div style="flex-grow: 1; display: flex; min-height: 0">
{sidebar(T, rows)}
{viewport}
<div style="width: 312px; flex-shrink: 0; display: flex; flex-direction: column; background: {T['panel']}; border-left: 1px solid {T['line']}; overflow: hidden">{pm}{tip}</div>
</div>
{statusbar(T, f'{icon("extrude", 14, T["accent"])}Boss-Extrude · set the depth of Direction 1', [f'<span style="font-family: {MONO_CSS}">X 42.18  Y 25.00  Z −6.40</span>', chip(T, "Editing Part", T['text2']), '<span>MMGS</span>' + icon("chevronDown", 10), f'{icon("rebuild", 13, T["accent"])}<span>Rebuilt in 38 ms</span>'])}
</div>"""
    return page("Forge — Part", 1440, 900, body, T)


def sketch_ribbon(T):
    L, Sm = lambda *a, **k: rb_large(T, *a, **k), lambda *a, **k: rb_small(T, *a, **k)
    return ribbon(T, [
        rb_group(T, "Sketch", [L("exitSketch", "Exit\nSketch"), L("smartDimension", "Smart\nDimension")]),
        rb_group(T, "Draw", [L("line", "Line", True, chevron=True), L("rectangle", "Rectangle", chevron=True), L("circle", "Circle", chevron=True),
                              rb_col([Sm("arc", "3-Point Arc"), Sm("tangentArc", "Tangent Arc"), Sm("slot", "Slot")]),
                              rb_col([Sm("spline", "Spline"), Sm("ellipse", "Ellipse"), Sm("polygon", "Polygon")]),
                              rb_col([Sm("point", "Point"), Sm("centerline", "Centerline"), Sm("construction", "Construction")])]),
        rb_group(T, "Modify", [L("trim", "Trim\nEntities"), rb_col([Sm("extend", "Extend"), Sm("offset", "Offset"), Sm("sketchFillet", "Fillet")]),
                                rb_col([Sm("sketchChamfer", "Chamfer"), Sm("mirror", "Mirror"), Sm("move", "Move")])]),
        rb_group(T, "Pattern", [rb_col([Sm("linearPattern", "Linear"), Sm("circularPattern", "Circular")])]),
        rb_group(T, "Relations", [L("addRelation", "Add\nRelation"), rb_col([Sm("hideShow", "Show Relations"), Sm("grid", "Grid &amp; Snap")])]),
    ])


def sketch_svg(T, w, h):
    k, ox, oy = 6.0, 250, 560
    X = lambda x: ox + k * x
    Y = lambda y: oy - k * y
    g = []
    # grid: 10 mm minor, 50 mm major, aligned to the origin
    for i in range(-8, 18):
        x = X(i * 10)
        if 0 <= x <= w: g.append(f'<path d="M{x:.1f} 0 V{h}" stroke="{T["grid2"] if i % 5 == 0 else T["grid"]}" stroke-width="1"></path>')
    for j in range(-6, 16):
        y = Y(j * 10)
        if 0 <= y <= h: g.append(f'<path d="M0 {y:.1f} H{w}" stroke="{T["grid2"] if j % 5 == 0 else T["grid"]}" stroke-width="1"></path>')
    # origin
    g.append(f'<path d="M{X(0)} {Y(0)} H{X(0)+34} M{X(0)} {Y(0)} V{Y(0)-34}" stroke="#E0574B" stroke-width="2" stroke-linecap="round"></path>')
    g.append(f'<path d="M{X(0)+28} {Y(0)-5} L{X(0)+36} {Y(0)} L{X(0)+28} {Y(0)+5} Z M{X(0)-5} {Y(0)-28} L{X(0)} {Y(0)-36} L{X(0)+5} {Y(0)-28} Z" fill="#E0574B"></path>')
    full, under, prev = T['full'], T['under'], T['preview']
    def seg(a, b, c, wdt=2):
        g.append(f'<path d="M{X(a[0]):.1f} {Y(a[1]):.1f} L{X(b[0]):.1f} {Y(b[1]):.1f}" stroke="{c}" stroke-width="{wdt}" stroke-linecap="round"></path>')
    segs = [((0, 0), (80, 0), full), ((80, 0), (80, 12), full), ((80, 12), (12, 12), under), ((0, 0), (0, 70), full), ((0, 70), (12, 70), full)]
    for a, b, c in segs: seg(a, b, c)
    for p, c in (((0, 0), full), ((80, 0), full), ((80, 12), full), ((12, 12), under), ((0, 70), full), ((12, 70), full)):
        g.append(f'<rect x="{X(p[0])-3:.1f}" y="{Y(p[1])-3:.1f}" width="6" height="6" fill="{c}"></rect>')
    # rubber band from (12,12) to the cursor at (12,70), snapped to the endpoint
    g.append(f'<path d="M{X(12)} {Y(12)} L{X(12)} {Y(70)}" stroke="{prev}" stroke-width="2" stroke-dasharray="7 5" stroke-linecap="round"></path>')
    g.append(f'<circle cx="{X(12)}" cy="{Y(70)}" r="8" fill="none" stroke="{prev}" stroke-width="2"></circle>')
    # inference line: horizontal alignment with the top-left endpoint, extended
    g.append(f'<path d="M{X(12)+12} {Y(70)} H{X(58)}" stroke="{prev}" stroke-width="1.2" stroke-dasharray="2 4" opacity="0.9"></path>')
    # dimensions
    def hdim(x0, x1, y, off, text):
        yy = Y(y) + off
        g.append(f'<path d="M{X(x0)} {Y(y)+ (6 if off>0 else -6)} V{yy + (6 if off>0 else -6)} M{X(x1)} {Y(y)+(6 if off>0 else -6)} V{yy+(6 if off>0 else -6)}" stroke="{T["dim"]}" stroke-width="1" opacity="0.7"></path>')
        g.append(f'<path d="M{X(x0)} {yy} H{X(x1)}" stroke="{T["dim"]}" stroke-width="1"></path>')
        g.append(f'<path d="M{X(x0)+10} {yy-3.5} L{X(x0)} {yy} L{X(x0)+10} {yy+3.5} Z M{X(x1)-10} {yy-3.5} L{X(x1)} {yy} L{X(x1)-10} {yy+3.5} Z" fill="{T["dim"]}"></path>')
        mx = (X(x0) + X(x1)) / 2
        g.append(f'<rect x="{mx-28}" y="{yy-11}" width="56" height="22" rx="5" fill="{T["glyphBg"]}" stroke="{T["line"]}"></rect>')
        g.append(f'<text x="{mx}" y="{yy+4.5}" text-anchor="middle" font-size="12.5" font-family="{MONO}" fill="{T["dim"]}">{text}</text>')
    def vdim(y0, y1, x, off, text):
        xx = X(x) + off
        s = 6 if off > 0 else -6
        g.append(f'<path d="M{X(x)+s} {Y(y0)} H{xx+s} M{X(x)+s} {Y(y1)} H{xx+s}" stroke="{T["dim"]}" stroke-width="1" opacity="0.7"></path>')
        g.append(f'<path d="M{xx} {Y(y0)} V{Y(y1)}" stroke="{T["dim"]}" stroke-width="1"></path>')
        g.append(f'<path d="M{xx-3.5} {Y(y0)-10} L{xx} {Y(y0)} L{xx+3.5} {Y(y0)-10} Z M{xx-3.5} {Y(y1)+10} L{xx} {Y(y1)} L{xx+3.5} {Y(y1)+10} Z" fill="{T["dim"]}"></path>')
        my = (Y(y0) + Y(y1)) / 2
        g.append(f'<rect x="{xx-28}" y="{my-11}" width="56" height="22" rx="5" fill="{T["glyphBg"]}" stroke="{T["line"]}"></rect>')
        g.append(f'<text x="{xx}" y="{my+4.5}" text-anchor="middle" font-size="12.5" font-family="{MONO}" fill="{T["dim"]}">{text}</text>')
    hdim(0, 80, 0, 44, "80.00")
    vdim(0, 12, 80, 44, "12.00")
    vdim(0, 70, 0, -48, "70.00")
    hdim(0, 12, 70, -40, "12.00")
    # relation glyphs
    def glyph(x, y, label):
        g.append(f'<rect x="{x-9}" y="{y-9}" width="18" height="18" rx="4" fill="{T["glyphBg"]}" stroke="#2F9E55" stroke-width="1.2"></rect>')
        g.append(f'<text x="{x}" y="{y+4}" text-anchor="middle" font-size="10.5" font-weight="700" font-family="{SANS}" fill="#2F9E55">{label}</text>')
    glyph(X(40), Y(0) - 16, "H"); glyph(X(80) + 16, Y(6) - 18, "V"); glyph(X(0) + 16, Y(35), "V"); glyph(X(6), Y(70) - 16, "H"); glyph(X(46), Y(12) - 16, "H")
    # cursor tooltip
    cx, cy = X(12), Y(70)
    g.append(f'<rect x="{cx+18}" y="{cy+14}" width="118" height="44" rx="7" fill="{T["surface"]}" stroke="{prev}" stroke-width="1.2"></rect>')
    g.append(f'<text x="{cx+28}" y="{cy+32}" font-size="12" font-family="{MONO}" fill="{T["text"]}">L  58.00</text>')
    g.append(f'<text x="{cx+28}" y="{cy+49}" font-size="12" font-family="{MONO}" fill="{T["text2"]}">∠  90.0°</text>')
    for i, (lab) in enumerate(("V", "⊙")):
        gx = cx + 100 - i * 0
    g.append(f'<rect x="{cx+104}" y="{cy+22}" width="22" height="18" rx="4" fill="{prev}"></rect>')
    g.append(f'<text x="{cx+115}" y="{cy+35}" text-anchor="middle" font-size="10.5" font-weight="700" font-family="{SANS}" fill="#1F2023">V</text>')
    # pencil cursor
    g.append(f'<g transform="translate({cx+6} {cy-26})"><path d="M0 20 L3 12 L15 0 L20 5 L8 17 Z" fill="{T["surface"]}" stroke="{T["text"]}" stroke-width="1.3" stroke-linejoin="round"></path><path d="M0 20 L3 12 L8 17 Z" fill="{T["text"]}"></path></g>')
    return f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" aria-label="Sketch on the Front Plane: an L profile with dimensions, relation glyphs and a line being drawn" style="position: absolute; left: 0; top: 0">{"".join(g)}</svg>'


def sketch_board():
    T = DARK
    rows = [
        tree_row(T, "part", "Bracket", disclosure="open", bold=True),
        tree_row(T, "history", "History", 1, "closed"),
        tree_row(T, "material", "6061-T6 Aluminium", 1),
        tree_row(T, "plane", "Front Plane", 1, tint=T['text3']),
        tree_row(T, "plane", "Top Plane", 1, tint=T['text3']),
        tree_row(T, "plane", "Right Plane", 1, tint=T['text3']),
        tree_row(T, "origin", "Origin", 1, tint="#E0574B"),
        tree_row(T, "sketch", "Sketch1", 1, selected=True, trail=status_dot(T, T['under'], "Under defined")),
        rollback(T),
        tree_row(T, "extrude", "Base Plate", 1, "closed", muted=True),
        tree_row(T, "cutExtrude", "Mounting Holes", 1, "closed", muted=True),
        tree_row(T, "fillet", "Fillet1", 1, muted=True),
    ]
    rel = lambda t, n: (f'<div style="display: flex; align-items: center; gap: 8px; height: 24px; padding: 0 8px; border-radius: 5px; background: {T["field"]}; font-size: 12px">'
                        f'<span style="width: 16px; height: 16px; border-radius: 4px; border: 1.2px solid #2F9E55; color: #2F9E55; font-size: 10px; font-weight: 700; display: flex; align-items: center; justify-content: center">{n}</span>{t}</div>')
    addrel = "".join(f'<button type="button" style="height: 26px; padding: 0 10px; border-radius: 6px; border: 1px solid {T["line"]}; background: {T["surface"]}; color: {T["text"]}; font-size: 12px">{t}</button>' for t in ("Horizontal", "Vertical", "Fix", "Coincident"))
    dof = (f'<div style="margin: 12px 14px 4px; padding: 12px; border-radius: 10px; background: {T["surface"]}; border: 1px solid {T["line"]}">'
           f'<div style="display: flex; align-items: center; justify-content: space-between"><span style="font-size: 12px; font-weight: 600">Sketch1</span>{chip(T, "Under defined", T["under"])}</div>'
           f'<div style="display: flex; gap: 3px; margin-top: 10px">' + "".join(f'<div style="flex-grow: 1; height: 5px; border-radius: 3px; background: {T["under"] if i < 1 else T["line"]}"></div>' for i in range(12)) + '</div>'
           f'<div style="display: flex; justify-content: space-between; margin-top: 7px; font-size: 11.5px; color: {T["text2"]}"><span>1 degree of freedom left</span><span style="font-family: {MONO_CSS}">11 / 12</span></div></div>')
    pm = (pm_header(T, "line", "Line", "Drawing · click to place, double-click to end")
          + dof
          + pm_group(T, "Existing Relations", rel("Horizontal", "H") + rel("Coincident to Point4", "⊙"))
          + pm_group(T, "Add Relations", f'<div style="display: flex; flex-wrap: wrap; gap: 6px">{addrel}</div>')
          + pm_group(T, "Orientation", select(T, "", "As sketched"))
          + pm_group(T, "Options", checkbox(T, "For construction") + checkbox(T, "Infinite length") + checkbox(T, "Midpoint line"))
          + pm_group(T, "Parameters", field(T, "Length", "58.00", "mm", "smartDimension") + field(T, "Angle", "90.00", "°", "arc")))
    vp_w, vp_h = 1440 - 272 - 312, 900 - 52 - 92 - 28
    viewport = f"""<div style="position: relative; flex-grow: 1; overflow: hidden; background: linear-gradient(180deg, {T['vpTop']} 0%, {T['vpBottom']} 100%)">
{sketch_svg(T, vp_w, vp_h)}
{hud(T, HUD_ITEMS, vp_w // 2, 12)}
<div style="position: absolute; left: 14px; top: 14px; display: flex; align-items: center; gap: 8px; height: 30px; padding: 0 12px; border-radius: 8px; background: {T['hud']}; border: 1px solid {T['line']}; font-size: 12px; color: {T['text2']}">
{icon('sketch', 16, T['accent'], T['text'])}<span style="color: {T['text']}; font-weight: 600">Sketch1</span><span>on Front Plane</span></div>
{confirm_corner(T, vp_w - 104, 14)}
{triad(T, 16, vp_h - 84, ("X", "Y", ""), ((1, 0), (0, -1), (0, 0)))}
<div style="position: absolute; left: 90px; top: {vp_h - 34}px; font-size: 11.5px; color: {T['text2']}">Front · Normal To</div>
</div>"""
    body = f"""<div style="width: 1440px; height: 900px; display: flex; flex-direction: column; overflow: hidden; background: {T['chrome']}">
{titlebar(T, ["Features", "Sketch", "Surfaces", "Sheet Metal", "Evaluate", "View"], "Sketch")}
{sketch_ribbon(T)}
<div style="flex-grow: 1; display: flex; min-height: 0">
{sidebar(T, rows)}
{viewport}
<div style="width: 312px; flex-shrink: 0; display: flex; flex-direction: column; background: {T['panel']}; border-left: 1px solid {T['line']}; overflow: hidden">{pm}</div>
</div>
{statusbar(T, f'{icon("line", 14, T["accent"])}Line · snapped to endpoint, vertical', [f'<span style="font-family: {MONO_CSS}">X 12.00  Y 70.00 mm</span>', chip(T, "Under defined · 1 DOF", T['under']), '<span>MMGS</span>' + icon("chevronDown", 10), chip(T, "Editing Sketch1", T['text2'])])}
</div>"""
    return page("Forge — Sketch", 1440, 900, body, T)


def system_board():
    W, H = 1440, 1880
    T, D = LIGHT, DARK
    sw = lambda c, n, v: (f'<div style="display: flex; flex-direction: column; gap: 6px; width: 96px"><div style="height: 44px; border-radius: 8px; background: {c}; box-shadow: inset 0 0 0 1px rgba(0,0,0,0.08)"></div>'
                          f'<span style="font-size: 12px; font-weight: 500">{n}</span><span style="font-size: 11px; color: {T["text2"]}; font-family: {MONO_CSS}">{v}</span></div>')
    def palette(Th, label):
        keys = [("chrome", "Chrome"), ("panel", "Panel"), ("surface", "Surface"), ("line", "Hairline"), ("text", "Text"), ("text2", "Text 2"), ("accent", "Accent")]
        return (f'<div style="display: flex; flex-direction: column; gap: 10px"><span style="font-size: 12px; font-weight: 600; color: {T["text2"]}; text-transform: uppercase; letter-spacing: 0.06em">{label}</span>'
                f'<div style="display: flex; gap: 12px">{"".join(sw(Th[k], n, Th[k]) for k, n in keys)}</div></div>')
    def status_row(Th, label):
        keys = [("full", "Fully defined"), ("under", "Under defined"), ("over", "Over defined"), ("preview", "Preview · inference")]
        return (f'<div style="display: flex; flex-direction: column; gap: 10px"><span style="font-size: 12px; font-weight: 600; color: {T["text2"]}; text-transform: uppercase; letter-spacing: 0.06em">{label}</span>'
                f'<div style="display: flex; gap: 12px">{"".join(sw(Th[k], n, Th[k]) for k, n in keys)}</div></div>')
    icon_names = ["extrude", "cutExtrude", "revolve", "cutRevolve", "sweep", "loft", "hole", "fillet", "chamfer", "shell", "draft", "rib", "linearPattern", "circularPattern", "mirror", "plane", "axis", "point3d", "coordSys", "box", "cylinder", "sphere", "combine",
                  "measure", "massProps", "section", "interference", "zebra", "sketch", "exitSketch", "line", "centerline", "rectangle", "circle", "arc", "tangentArc", "slot", "polygon", "spline", "point", "ellipse",
                  "sketchFillet", "sketchChamfer", "offset", "trim", "extend", "move", "smartDimension", "addRelation", "construction", "grid",
                  "zoomFit", "zoomArea", "prevView", "viewOrient", "displayStyle", "hideShow", "appearance", "viewSettings",
                  "part", "folder", "sensor", "annotation", "material", "origin", "history", "equations", "warning", "search", "check", "xmark", "pin", "sparkle", "undo", "redo", "save", "newDoc", "open", "rebuild", "command", "trash"]
    grid = "".join(f'<div style="display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 10px 0 8px; border-radius: 8px; background: {T["surface"]}; border: 1px solid {T["line2"]}; color: {T["text"]}">{icon(n, 26, T["accent"])}<span style="font-size: 10px; color: {T["text2"]}">{n}</span></div>' for n in icon_names)
    heading = lambda t, s: f'<div style="display: flex; flex-direction: column; gap: 4px"><h2 style="margin: 0; font-size: 20px; font-weight: 600">{t}</h2><p style="margin: 0; font-size: 13px; color: {T["text2"]}; max-width: 620px">{s}</p></div>'
    buttons = (f'<div style="display: flex; gap: 6px; align-items: flex-start; padding: 12px; border-radius: 10px; background: {T["chrome2"]}; border: 1px solid {T["line"]}">'
               + rb_large(T, "extrude", "Extruded\nBoss/Base") + rb_large(T, "extrude", "Hover", False).replace("background: transparent", f"background: {T['hover']}")
               + rb_large(T, "extrude", "Active\ncommand", True) + rb_large(T, "extrude", "Disabled", disabled=True) + rb_large(T, "fillet", "With\nflyout", chevron=True)
               + rb_col([rb_small(T, "chamfer", "Small"), rb_small(T, "shell", "Small active", True), rb_small(T, "draft", "Draft")]) + '</div>')
    tree = (f'<div style="width: 272px; padding: 8px 6px; border-radius: 10px; background: {T["panel"]}; border: 1px solid {T["line"]}; display: flex; flex-direction: column; gap: 1px">'
            + tree_row(T, "extrude", "Feature", 0, "closed")
            + tree_row(T, "sketch", "Selected sketch", 1, selected=True, trail=status_dot(T, T['full'], "Fully defined"))
            + tree_row(T, "sketch", "Under-defined sketch", 1, trail=status_dot(T, T['under'], "Under defined"))
            + tree_row(T, "sketch", "Over-defined sketch", 1, trail=status_dot(T, T['over'], "Over defined"))
            + tree_row(T, "fillet", "Feature with error", 0, trail=f'<span style="color: {T["over"]}; display: flex">{icon("warning", 15, T["over"], T["over"])}</span>')
            + rollback(T) + tree_row(T, "chamfer", "Rolled back", 0, muted=True) + '</div>')
    pmcard = (f'<div style="width: 312px; border-radius: 10px; overflow: hidden; background: {T["panel"]}; border: 1px solid {T["line"]}">'
              + pm_header(T, "fillet", "Fillet", "Constant radius")
              + pm_group(T, "Items to Fillet", sel_box(T, T['accent'], [("line", "Edge 12"), ("line", "Edge 14")], "") + field(T, "Radius", "2.00", "mm", "smartDimension") + checkbox(T, "Tangent propagation", True))
              + pm_group(T, "Fillet Options", "", open_=False) + '</div>')
    palette_ui = (f'<div style="width: 560px; border-radius: 14px; overflow: hidden; background: {T["surface"]}; border: 1px solid {T["line"]}; box-shadow: {T["shadow"]}">'
                  f'<div style="display: flex; align-items: center; gap: 10px; height: 48px; padding: 0 16px; border-bottom: 1px solid {T["line2"]}">{icon("search", 18)}<input type="text" value="fillet 2mm on the top edges" aria-label="Command or request" style="flex-grow: 1; border: none; outline: none; font-size: 15px; color: {T["text"]}; background: transparent"></div>'
                  + "".join(f'<div style="display: flex; align-items: center; gap: 12px; height: 44px; padding: 0 16px; background: {T["accentSoft"] if i == 0 else "transparent"}">'
                            f'<span style="color: {T["accentText"] if i == 0 else T["text2"]}; display: flex">{icon(n, 20, T["accent"])}</span><div style="flex-grow: 1; display: flex; flex-direction: column; line-height: 1.25"><span style="font-size: 13px; font-weight: 500">{a}</span><span style="font-size: 11.5px; color: {T["text2"]}">{b}</span></div>'
                            f'<span style="font-family: {MONO_CSS}; font-size: 11px; color: {T["text3"]}">{c}</span></div>'
                            for i, (n, a, b, c) in enumerate([("sparkle", "Ask Forge: fillet 2 mm on the top edges", "Plans the commands and shows a preview first", "↩"),
                                                              ("fillet", "Fillet", "body.fillet_edges", "F"), ("chamfer", "Chamfer", "body.chamfer_edges", ""), ("massProps", "Mass Properties", "query.mass_properties", "")])) + '</div>')
    body = f"""<div style="width: {W}px; height: {H}px; box-sizing: border-box; padding: 56px 64px; display: flex; flex-direction: column; gap: 40px; background: {T['chrome2']}; color: {T['text']}">
<div style="display: flex; flex-direction: column; gap: 6px"><h1 style="margin: 0; font-size: 34px; font-weight: 600; letter-spacing: -0.01em">Forge interface kit</h1>
<p style="margin: 0; font-size: 14px; color: {T['text2']}; max-width: 760px">Native macOS chrome, SolidWorks muscle memory. System font for UI, monospace for every number the user can edit. One accent blue; sketch state colours follow SolidWorks (black / blue / red) so they read at a glance.</p></div>
<div style="display: flex; gap: 56px">{palette(T, "Light")}</div>
<div style="display: flex; gap: 56px">{palette(D, "Dark")}</div>
<div style="display: flex; gap: 56px">{status_row(T, "Sketch state · light")}{status_row(D, "Sketch state · dark")}</div>
<div style="display: flex; gap: 40px; align-items: flex-start">
<div style="display: flex; flex-direction: column; gap: 14px">{heading("CommandManager buttons", "Large 26 pt icon over a two-line label; small 16 pt icon beside a label for secondary tools.")}{buttons}</div>
<div style="display: flex; flex-direction: column; gap: 14px">{heading("Command palette", "⌘K. Commands by name, or a plain-language request.")}{palette_ui}</div>
</div>
<div style="display: flex; gap: 40px; align-items: flex-start">
<div style="display: flex; flex-direction: column; gap: 14px">{heading("Feature tree states", "Status dot per sketch; errors carry a warning glyph; rows below the rollback bar are dimmed.")}{tree}</div>
<div style="display: flex; flex-direction: column; gap: 14px">{heading("PropertyManager", "OK / Cancel first, collapsible groups, selection boxes outlined in the accent colour when active.")}{pmcard}</div>
</div>
<div style="display: flex; flex-direction: column; gap: 14px">{heading("Icons", "Drawn for Forge on a 24 pt grid. The app renders these same paths.")}<div style="display: grid; grid-template-columns: repeat(14, minmax(0, 1fr)); gap: 6px">{grid}</div></div>
</div>"""
    return page("Forge — Interface kit", W, H, body, T)


if __name__ == "__main__":
    out = os.path.join(ROOT, "project") if os.path.isdir(os.path.join(ROOT, "project")) else ROOT
    boards = {"Main.dc.html": main_board(), "Sketch.dc.html": sketch_board(), "System.dc.html": system_board()}
    for n, s in boards.items():
        open(os.path.join(out, n), "w").write(s)
    canvas = {"v": 3, "createdOnFiles": {"v": 1, "at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
              "title": "Forge CAD — macOS UI", "launch": {"view": "canvas"}, "pages": [],
              "boards": {"Main.dc.html": {"x": 0, "y": 0, "w": 1440, "h": 900, "title": "Part · Extrude in progress (light)", "radius": 12},
                         "Sketch.dc.html": {"x": 1520, "y": 0, "w": 1440, "h": 900, "title": "Sketch · drawing a line (dark)", "radius": 12},
                         "System.dc.html": {"x": 0, "y": 1020, "w": 1440, "h": 1880, "title": "Interface kit"}},
              "order": ["Main.dc.html", "Sketch.dc.html", "System.dc.html"],
              "notes": {"t1": {"x": 0, "y": -300, "text": "Forge — SolidWorks-grade CAD, native to macOS", "kind": "title1", "maxW": 2960}},
              "designSystems": []}
    json.dump(canvas, open(os.path.join(out, "canvas.json"), "w"), indent=1, ensure_ascii=False)
    print("icons:", len(ICONS), "sizes:", {n: len(s) for n, s in boards.items()})
