// Forge's own icon set, drawn on a 24×24 grid. The same path strings drive the design mockups
// (docs/design) and the app, so what was designed is what ships.
//
// Each icon is layers separated by " | ". A layer's prefix sets how it is painted:
//   (none) stroke in the label colour     a:  stroke in the accent colour
//   d:     dashed stroke, label colour     ad: dashed stroke, accent colour
//   f:     filled, label colour            af: filled, accent colour at low opacity
// Paths use the SVG path subset M L H V C Q A Z (absolute and relative).

import SwiftUI

enum ForgeIcon: String, CaseIterable, Sendable {
    // Features
    case extrude, cutExtrude, revolve, cutRevolve, sweep, loft, hole, fillet, chamfer, shell, draft, rib
    case linearPattern, circularPattern, mirror, plane, axis, point3d, coordSys
    case box, cylinder, sphere, combine
    // Evaluate
    case measure, massProps, section, interference, zebra
    // Sketch
    case sketch, exitSketch, line, centerline, rectangle, circle, arc, tangentArc, slot, polygon, spline, point, ellipse
    case sketchFillet, sketchChamfer, offset, trim, extend, move, smartDimension, addRelation, construction, grid
    // View
    case zoomFit, zoomArea, prevView, viewOrient, displayStyle, hideShow, appearance, viewSettings
    // Document and UI
    case part, folder, sensor, annotation, material, origin, history, equations, warning
    case search, check, xmark, pin, chevronDown, chevronRight, sparkle, undo, redo, save, newDoc, open, rebuild, command, trash

    static let paths: [ForgeIcon: String] = [
        .extrude: "af:M4 12 L12 16 L20 12 L12 8 Z | M4 12 L12 16 L20 12 L12 8 Z M4 12 V17 L12 21 L20 17 V12 M12 16 V21 | a:M12 12 V2.5 M9.5 5 L12 2.5 L14.5 5",
        .cutExtrude: "M4 11 L12 15 L20 11 L12 7 Z M4 11 V17 L12 21 L20 17 V11 M12 15 V21 | af:M8.5 11 L12 12.8 L15.5 11 L12 9.2 Z | a:M8.5 11 L12 12.8 L15.5 11 L12 9.2 Z | a:M12 1.5 V9 M9.5 6.5 L12 9 L14.5 6.5",
        .revolve: "d:M12 2 V22 | af:M12 6 H17 V10 H15 V18 H12 Z | M12 6 H17 V10 H15 V18 H12 | a:M8.5 7 C5.5 8 4 10 4 12 C4 14.5 6.5 16.5 10 17 M7.8 15 L10 17 L7.8 19",
        .cutRevolve: "d:M12 2 V22 | M12 5 H19 V19 H12 | af:M12 9 H16 V15 H12 Z | a:M12 9 H16 V15 H12 | a:M8.5 7 C5.5 8 4 10 4 12 C4 14.5 6.5 16.5 10 17 M7.8 15 L10 17 L7.8 19",
        .sweep: "a:M5 19 C5 11 11 6 19 6 | af:M2.5 19 A2.5 2.5 0 1 0 7.5 19 A2.5 2.5 0 1 0 2.5 19 Z | M2.5 19 A2.5 2.5 0 1 0 7.5 19 A2.5 2.5 0 1 0 2.5 19 Z M19 3.5 A1.4 2.5 0 1 0 19 8.5 A1.4 2.5 0 1 0 19 3.5 Z | M3.2 17.2 C3.8 9.5 10 3.5 19 3.5 M7.2 20.2 C8 13 13 8.5 19 8.5",
        .loft: "af:M3 17 L10 20 L17 17 L10 14 Z | M3 17 L10 20 L17 17 L10 14 Z | a:M10 6 A4 2 0 1 0 18 6 A4 2 0 1 0 10 6 Z | M3 17 L10 6 M17 17 L18 6 M10 20 L14 8",
        .hole: "M4 11 L12 15 L20 11 L12 7 Z M4 11 V17 L12 21 L20 17 V11 M12 15 V21 | af:M9 11 A3 1.5 0 1 0 15 11 A3 1.5 0 1 0 9 11 Z | a:M9 11 A3 1.5 0 1 0 15 11 A3 1.5 0 1 0 9 11 Z M10 11.8 V1.5 M14 11.8 V1.5",
        .fillet: "M5 20 H20 V5 | M5 20 V12 M12 5 H20 | af:M5 20 V12 A7 7 0 0 1 12 5 H20 V20 Z | a:M5 12 A7 7 0 0 1 12 5",
        .chamfer: "M5 20 H20 V5 | M5 20 V11 M11 5 H20 | af:M5 20 V11 L11 5 H20 V20 Z | a:M5 11 L11 5",
        .shell: "M3 9 L12 13 L21 9 L12 5 Z M3 9 V16 L12 20 L21 16 V9 M12 13 V20 | af:M6.5 9 L12 11.4 L17.5 9 L12 6.6 Z | a:M6.5 9 L12 11.4 L17.5 9 L12 6.6 Z",
        .draft: "M8 5 H16 L18 20 H6 | af:M6 20 L8 5 H16 L18 20 Z | a:M6 20 L8 5 | d:M6 20 V4",
        .rib: "M4 20 H20 M4 20 V4 | af:M4 8 L16 20 H4 Z | a:M4 8 L16 20",
        .linearPattern: "af:M3 13 h7 v7 h-7 Z | a:M3 13 h7 v7 h-7 Z | d:M14 13 h7 v7 h-7 Z M3 3 h7 v7 h-7 Z M14 3 h7 v7 h-7 Z",
        .circularPattern: "af:M9.5 4.5 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z | a:M9.5 4.5 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z | d:M17 12 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z M9.5 19.5 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z M2 12 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z | f:M11 12 a1 1 0 1 0 2 0 a1 1 0 1 0 -2 0 Z",
        .mirror: "d:M12 2 V22 | af:M3 7 L9 5 V19 L3 17 Z | a:M3 7 L9 5 V19 L3 17 Z | d:M21 7 L15 5 V19 L21 17 Z",
        .plane: "af:M3 17 L8 7 H21 L16 17 Z | a:M3 17 L8 7 H21 L16 17 Z",
        .axis: "a:M4 20 L20 4 | M2 18 L6 22 M18 2 L22 6",
        .point3d: "af:M9 12 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0 Z | a:M9 12 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0 Z | M12 3 V8 M12 16 V21 M3 12 H8 M16 12 H21",
        .coordSys: "M6 18 V4 M3.5 6.5 L6 4 L8.5 6.5 | a:M6 18 H20 M17.5 15.5 L20 18 L17.5 20.5 | M6 18 L2.5 21.5",
        .box: "af:M12 3 L20 7.5 L12 12 L4 7.5 Z | M12 3 L20 7.5 V16.5 L12 21 L4 16.5 V7.5 Z M4 7.5 L12 12 L20 7.5 M12 12 V21",
        .cylinder: "af:M5 6 A7 3 0 1 0 19 6 A7 3 0 1 0 5 6 Z | M5 6 A7 3 0 1 0 19 6 A7 3 0 1 0 5 6 Z M5 6 V18 A7 3 0 0 0 19 18 V6",
        .sphere: "af:M3 12 a9 9 0 1 0 18 0 a9 9 0 1 0 -18 0 Z | M3 12 a9 9 0 1 0 18 0 a9 9 0 1 0 -18 0 Z | d:M3 12 A9 3 0 0 0 21 12",
        .combine: "M3 12 a6 6 0 1 0 12 0 a6 6 0 1 0 -12 0 Z M9 12 a6 6 0 1 0 12 0 a6 6 0 1 0 -12 0 Z | af:M12 6.8 A6 6 0 0 1 12 17.2 A6 6 0 0 1 12 6.8 Z",
        .measure: "M3 16 L16 3 L21 8 L8 21 Z | a:M7 12 L9 14 M10 9 L12 11 M13 6 L15 8",
        .massProps: "af:M6 9 H18 L20 21 H4 Z | M6 9 H18 L20 21 H4 Z M9 9 A3 3 0 1 1 15 9",
        .section: "M12 3 L20 7.5 V16.5 L12 21 | d:M12 3 L4 7.5 V16.5 L12 21 | af:M12 3 V21 L7 18 V6 Z | a:M12 3 V21 L7 18 V6 Z",
        .interference: "M3 12 a6 6 0 1 0 12 0 a6 6 0 1 0 -12 0 Z M9 12 a6 6 0 1 0 12 0 a6 6 0 1 0 -12 0 Z | af:M12 6.8 A6 6 0 0 1 12 17.2 A6 6 0 0 1 12 6.8 Z | a:M12 6.8 A6 6 0 0 1 12 17.2 A6 6 0 0 1 12 6.8 Z",
        .zebra: "M3 20 C7 12 17 12 21 20 | a:M3 15 C7 7 17 7 21 15 | M3 10 C7 2 17 2 21 10",
        .sketch: "M2 19 L6 15 H22 L18 19 Z | af:M9 13 L17 5 L19 7 L11 15 L8 16 Z | a:M9 13 L17 5 L19 7 L11 15 L8 16 Z M15.5 6.5 L17.5 8.5",
        .exitSketch: "M3 6 A3 3 0 0 1 6 3 H18 A3 3 0 0 1 21 6 V18 A3 3 0 0 1 18 21 H6 A3 3 0 0 1 3 18 Z | a:M7.5 12.5 L10.5 15.5 L16.5 9",
        .line: "a:M5 19 L19 5 | f:M3 17 h4 v4 h-4 Z M17 3 h4 v4 h-4 Z",
        .centerline: "ad:M4 20 L20 4 | f:M2.5 18.5 h3 v3 h-3 Z M18.5 2.5 h3 v3 h-3 Z",
        .rectangle: "af:M4 6 H20 V18 H4 Z | a:M4 6 H20 V18 H4 Z | f:M2.5 4.5 h3 v3 h-3 Z M18.5 16.5 h3 v3 h-3 Z",
        .circle: "af:M4 12 a8 8 0 1 0 16 0 a8 8 0 1 0 -16 0 Z | a:M4 12 a8 8 0 1 0 16 0 a8 8 0 1 0 -16 0 Z | M12 12 L17.7 6.3 | f:M10.8 12 a1.2 1.2 0 1 0 2.4 0 a1.2 1.2 0 1 0 -2.4 0 Z",
        .arc: "a:M4 17 A9 9 0 0 1 20 17 | f:M2.5 15.5 h3 v3 h-3 Z M18.5 15.5 h3 v3 h-3 Z M10.5 10.6 h3 v3 h-3 Z",
        .tangentArc: "M3 18 H10 | a:M10 18 A6 6 0 0 0 16 12 A6 6 0 0 0 10 6 | f:M8.5 16.5 h3 v3 h-3 Z",
        .slot: "af:M8 7 H16 A5 5 0 0 1 16 17 H8 A5 5 0 0 1 8 7 Z | a:M8 7 H16 A5 5 0 0 1 16 17 H8 A5 5 0 0 1 8 7 Z | d:M8 12 H16",
        .polygon: "af:M12 3 L19.8 7.5 V16.5 L12 21 L4.2 16.5 V7.5 Z | a:M12 3 L19.8 7.5 V16.5 L12 21 L4.2 16.5 V7.5 Z | d:M4.2 12 a7.8 7.8 0 1 0 15.6 0 a7.8 7.8 0 1 0 -15.6 0 Z",
        .spline: "d:M3 18 L7 3 M13 21 L21 6 | a:M3 18 C7 3 13 21 21 6 | f:M1.5 16.5 h3 v3 h-3 Z M19.5 4.5 h3 v3 h-3 Z",
        .point: "f:M9.5 12 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z | M12 3 V7.5 M12 16.5 V21 M3 12 H7.5 M16.5 12 H21",
        .ellipse: "af:M3 12 a9 5.5 0 1 0 18 0 a9 5.5 0 1 0 -18 0 Z | a:M3 12 a9 5.5 0 1 0 18 0 a9 5.5 0 1 0 -18 0 Z | d:M3 12 H21 M12 6.5 V17.5",
        .sketchFillet: "d:M5 12 V5 H12 | M5 21 V12 M12 5 H21 | a:M5 12 A7 7 0 0 1 12 5",
        .sketchChamfer: "d:M5 12 V5 H12 | M5 21 V12 M12 5 H21 | a:M5 12 L12 5",
        .offset: "M4 19 C6 11 11 6 20 5 | a:M8 21 C10 14 14 10 20 9.5 | a:M11 11 L13.4 13.4 M13.4 10.4 V13.4 H10.4",
        .trim: "M3.5 17.5 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z M15.5 17.5 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z | a:M7.5 15.5 L17 3 M16.5 15.5 L7 3",
        .extend: "M20 4 V20 | M3 12 H11 | ad:M11 12 H19 | a:M16.5 9.5 L19 12 L16.5 14.5",
        .move: "M12 3 V21 M3 12 H21 | a:M9.5 5.5 L12 3 L14.5 5.5 M9.5 18.5 L12 21 L14.5 18.5 M5.5 9.5 L3 12 L5.5 14.5 M18.5 9.5 L21 12 L18.5 14.5",
        .smartDimension: "M4 5 V17 M20 5 V17 | a:M4 11 H20 M7 8.5 L4 11 L7 13.5 M17 8.5 L20 11 L17 13.5 | M8 20 H16",
        .addRelation: "M4 20 H20 M9 20 V4 | af:M9 15 H14 V20 H9 Z | a:M9 15 H14 V20",
        .construction: "ad:M4 20 L20 4",
        .grid: "M4 4 H20 V20 H4 Z | d:M4 9.3 H20 M4 14.6 H20 M9.3 4 V20 M14.6 4 V20",
        .zoomFit: "M4 9 V4 H9 M15 4 H20 V9 M20 15 V20 H15 M9 20 H4 V15 | af:M8 8 H16 V16 H8 Z | a:M8 8 H16 V16 H8 Z",
        .zoomArea: "M3 10 a7 7 0 1 0 14 0 a7 7 0 1 0 -14 0 Z M15 15 L21 21 | ad:M7 7 H13 V13 H7 Z",
        .prevView: "M8 6 L3 11 L8 16 M3 11 H14 A6 6 0 0 1 20 17 V20",
        .viewOrient: "af:M12 3 L20 7.5 L12 12 L4 7.5 Z | M12 3 L20 7.5 V16.5 L12 21 L4 16.5 V7.5 Z M4 7.5 L12 12 L20 7.5 M12 12 V21",
        .displayStyle: "af:M4 7.5 L12 12 V21 L4 16.5 Z | f:M12 12 L20 7.5 V16.5 L12 21 Z | M12 3 L20 7.5 V16.5 L12 21 L4 16.5 V7.5 Z M4 7.5 L12 12 L20 7.5 M12 12 V21",
        .hideShow: "M2 12 C5 6.5 8.5 5 12 5 C15.5 5 19 6.5 22 12 C19 17.5 15.5 19 12 19 C8.5 19 5 17.5 2 12 Z | af:M9 12 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0 Z | a:M9 12 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0 Z",
        .appearance: "af:M12 3 C12 3 5 11 5 15 A7 7 0 0 0 19 15 C19 11 12 3 12 3 Z | M12 3 C12 3 5 11 5 15 A7 7 0 0 0 19 15 C19 11 12 3 12 3 Z",
        .viewSettings: "M4 7 H20 M4 17 H20 | f:M13 7 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z M6 17 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0 Z",
        .part: "af:M12 3 L20 7.5 L12 12 L4 7.5 Z | M12 3 L20 7.5 V16.5 L12 21 L4 16.5 V7.5 Z M4 7.5 L12 12 L20 7.5 M12 12 V21",
        .folder: "af:M3 6 H9 L11 8 H21 V19 H3 Z | M3 6 H9 L11 8 H21 V19 H3 Z",
        .sensor: "M4 12 A8 8 0 0 1 20 12 M7.5 12 A4.5 4.5 0 0 1 16.5 12 | f:M10.5 12 a1.5 1.5 0 1 0 3 0 a1.5 1.5 0 1 0 -3 0 Z | M12 13.5 V20",
        .annotation: "M5 19 L12 4 L19 19 | a:M8 13 H16",
        .material: "af:M12 4 L21 8.5 L12 13 L3 8.5 Z | M12 4 L21 8.5 L12 13 L3 8.5 Z M3 12.5 L12 17 L21 12.5 M3 16.5 L12 21 L21 16.5",
        .origin: "a:M12 12 H20 M17.5 9.5 L20 12 L17.5 14.5 | M12 12 V4 M9.5 6.5 L12 4 L14.5 6.5 | f:M10.5 12 a1.5 1.5 0 1 0 3 0 a1.5 1.5 0 1 0 -3 0 Z",
        .history: "M4 12 a8 8 0 1 0 16 0 a8 8 0 1 0 -16 0 Z | a:M12 7 V12 L15 14",
        .equations: "M18 5 H6 L12 12 L6 19 H18",
        .warning: "af:M12 3 L22 20 H2 Z | M12 3 L22 20 H2 Z M12 9 V14 M12 17 V17.5",
        .search: "M4 10.5 a6.5 6.5 0 1 0 13 0 a6.5 6.5 0 1 0 -13 0 Z M15.5 15.5 L20.5 20.5",
        .check: "M5 12.5 L10 17.5 L19 7",
        .xmark: "M6 6 L18 18 M18 6 L6 18",
        .pin: "M9 3 H15 M10 3 V9 L7 13 H17 L14 9 V3 M12 13 V21",
        .chevronDown: "M6 9 L12 15 L18 9",
        .chevronRight: "M9 6 L15 12 L9 18",
        .sparkle: "af:M12 3 C12.8 8 16 11.2 21 12 C16 12.8 12.8 16 12 21 C11.2 16 8 12.8 3 12 C8 11.2 11.2 8 12 3 Z | a:M12 3 C12.8 8 16 11.2 21 12 C16 12.8 12.8 16 12 21 C11.2 16 8 12.8 3 12 C8 11.2 11.2 8 12 3 Z | M19 2 V6 M17 4 H21",
        .undo: "M9 4 L4 9 L9 14 M4 9 H14 A6 6 0 0 1 14 21 H11",
        .redo: "M15 4 L20 9 L15 14 M20 9 H10 A6 6 0 0 0 10 21 H13",
        .save: "M4 4 H16 L20 8 V20 H4 Z M8 4 V9 H15 V4 | a:M7 20 V14 H17 V20",
        .newDoc: "M6 3 H14 L19 8 V21 H6 Z M14 3 V8 H19 | a:M12.5 11 V18 M9 14.5 H16",
        .open: "M3 6 H9 L11 8 H21 V19 H3 Z | a:M3 19 L6 11 H22 L19 19",
        .rebuild: "M20 12 a8 8 0 1 1 -2.34 -5.66 | a:M20 3.5 V8 H15.5",
        .command: "M9 9 H15 V15 H9 Z M9 9 V6 A3 3 0 1 0 6 9 H9 M15 9 V6 A3 3 0 1 1 18 9 H15 M9 15 V18 A3 3 0 1 1 6 15 H9 M15 15 V18 A3 3 0 1 0 18 15 H15",
        .trash: "M4 6 H20 M9 6 V3.5 H15 V6 M6 6 L7 21 H17 L18 6 | a:M10 10 V17 M14 10 V17",
    ]

    /// The icon's layers, parsed once.
    var layers: [IconLayer] { IconLayer.cache[self] ?? [] }
}

struct IconLayer {
    enum Paint { case stroke, accentStroke, dashed, accentDashed, fill, accentFill }
    let paint: Paint
    let path: Path

    static let cache: [ForgeIcon: [IconLayer]] = Dictionary(uniqueKeysWithValues: ForgeIcon.allCases.map { icon in
        (icon, (ForgeIcon.paths[icon] ?? "").components(separatedBy: " | ").map(IconLayer.init))
    })

    init(_ source: String) {
        let s = source.trimmingCharacters(in: .whitespaces)
        let prefixes: [(String, Paint)] = [("ad:", .accentDashed), ("af:", .accentFill), ("a:", .accentStroke), ("d:", .dashed), ("f:", .fill)]
        var paint = Paint.stroke
        var body = Substring(s)
        for (p, kind) in prefixes where s.hasPrefix(p) {
            paint = kind
            body = s.dropFirst(p.count)
            break
        }
        self.paint = paint
        self.path = SVGPath.parse(String(body))
    }
}

/// An icon at any size. `accent` tints the a:/ad:/af: layers; the rest use the foreground style.
struct IconView: View {
    let icon: ForgeIcon
    var size: CGFloat = 20
    var accent: Color = .accentColor
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { ctx, canvas in
            let k = canvas.width / 24
            let transform = CGAffineTransform(scaleX: k, y: k)
            let solid = StrokeStyle(lineWidth: lineWidth * k, lineCap: .round, lineJoin: .round)
            let dashed = StrokeStyle(lineWidth: lineWidth * k, lineCap: .round, lineJoin: .round, dash: [2 * k, 2.5 * k])
            let ink = GraphicsContext.Shading.foreground
            for layer in icon.layers {
                let p = layer.path.applying(transform)
                switch layer.paint {
                case .stroke: ctx.stroke(p, with: ink, style: solid)
                case .accentStroke: ctx.stroke(p, with: .color(accent), style: solid)
                case .dashed: ctx.stroke(p, with: ink, style: dashed)
                case .accentDashed: ctx.stroke(p, with: .color(accent), style: dashed)
                case .fill: ctx.fill(p, with: ink)
                case .accentFill: ctx.fill(p, with: .color(accent.opacity(0.22)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Parser for the SVG path subset the icons use.
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var tokens = tokenize(d)[...]
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero

        func num() -> CGFloat {
            if case .number(let v)? = tokens.first { tokens.removeFirst(); return v }
            return 0
        }
        func hasNumber() -> Bool { if case .number? = tokens.first { return true }; return false }

        while !tokens.isEmpty {
            if case .command(let c) = tokens.first! {
                cmd = c
                tokens.removeFirst()
            }
            let rel = cmd.isLowercase
            func pt() -> CGPoint {
                let x = num(), y = num()
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd.uppercased().first! {
            case "M":
                cur = pt(); start = cur
                path.move(to: cur)
                cmd = rel ? "l" : "L"  // further pairs are line-tos
            case "L":
                cur = pt(); path.addLine(to: cur)
            case "H":
                let x = num(); cur.x = rel ? cur.x + x : x; path.addLine(to: cur)
            case "V":
                let y = num(); cur.y = rel ? cur.y + y : y; path.addLine(to: cur)
            case "C":
                let c1 = pt(), c2 = pt(), e = pt()
                path.addCurve(to: e, control1: c1, control2: c2); cur = e
            case "Q":
                let c = pt(), e = pt()
                path.addQuadCurve(to: e, control: c); cur = e
            case "A":
                let rx = num(), ry = num(), rot = num(), large = num() != 0, sweep = num() != 0
                let e = pt()
                addArc(&path, from: cur, to: e, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = e
            case "Z":
                path.closeSubpath(); cur = start
                if hasNumber() { tokens.removeFirst() }
                continue
            default:
                tokens.removeFirst()
            }
        }
        return path
    }

    private enum Token { case command(Character), number(CGFloat) }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        var numberText = ""
        func flush() {
            if let v = Double(numberText) { out.append(.number(CGFloat(v))) }
            numberText = ""
        }
        for ch in d {
            if ch.isLetter {
                flush(); out.append(.command(ch))
            } else if ch == "-" {
                if !numberText.isEmpty && numberText.last != "e" { flush() }
                numberText.append(ch)
            } else if ch == "." && numberText.contains(".") {
                flush(); numberText = "0."
            } else if ch.isNumber || ch == "." {
                numberText.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// SVG endpoint arc → cubic Béziers (SVG 1.1 implementation notes, F.6.5).
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, c = cos(phi), s = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = c * dx + s * dy, y1 = -s * dx + c * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = (max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = c * cxp - s * cyp + (p0.x + p1.x) / 2
        let cy = s * cxp + c * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let t1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dt = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi }
        if sweep && dt < 0 { dt += 2 * .pi }
        let segments = max(1, Int((abs(dt) / (.pi / 2)).rounded(.up)))
        let step = dt / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * c - ry * sin(t) * s, y: cy + rx * cos(t) * s + ry * sin(t) * c)
        }
        func deriv(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * c - ry * cos(t) * s, y: -rx * sin(t) * s + ry * cos(t) * c)
        }
        var t = t1
        for _ in 0..<segments {
            let a = point(t), b = point(t + step), da = deriv(t), db = deriv(t + step)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }
}
