# Forge interface design

The UI is designed in Claude Design. The canvas is https://claude.ai/artifact/1JMggK7ESLfNdPaWmnK8bB
(private to the owner; share it from the page's Share menu).

| Artboard | What it shows |
|---|---|
| `Main.dc.html` | Part window, light: CommandManager ribbon, feature tree, Boss-Extrude PropertyManager, viewport with heads-up toolbar, confirmation corner and triad |
| `Sketch.dc.html` | Sketch mode, dark: sketch tools, dimensions, relation glyphs, rubber-band line with snap tooltip, Line PropertyManager with DOF card |
| `System.dc.html` | Interface kit: light/dark tokens, sketch-state colours, ribbon button states, tree states, PropertyManager, command palette, icon set |

`gen.py` generates the artboards. It reads the icon paths straight from
`Sources/ForgeApp/Icons.swift`, so the icons in the design and in the app are the same
drawings. Colour tokens live in `LIGHT`/`DARK` in `gen.py` and in `Sources/ForgeApp/Theme.swift`;
keep them in step.

Run `python3 docs/design/gen.py` to regenerate the `.dc.html` files next to it.
