// The CommandManager ribbon as data (groups of buttons with their state and action), for front
// ends without SwiftUI (Windows). Mirrors Sources/ForgeApp/Ribbon.swift.

import ForgeCommands
import ForgeCore
import ForgeSketch

package struct RibbonButton {
    package var id: String
    package var icon: ForgeIcon
    package var title: String
    package var help: String
    package var active: Bool
    package var enabled: Bool
    /// Large (icon over label) or small (icon beside label, stacked).
    package var large: Bool
    package var action: () -> Void
    /// Flyout variants (title, action); empty for a plain button.
    package var variants: [(title: String, action: () -> Void)]
}

package struct RibbonGroupSpec {
    package var title: String
    package var buttons: [RibbonButton]
}

extension AppModel {
    /// The groups of the current ribbon tab.
    package var ribbonGroups: [RibbonGroupSpec] {
        let groups: [RibbonGroupSpec] = switch ribbonTab {
        case .features: featureGroups
        case .sketch: sketchGroups
        case .evaluate: evaluateGroups
        }
        return [selectionGroup] + groups
    }

    private var selectionGroup: RibbonGroupSpec {
        RibbonGroupSpec(title: "Selection", buttons: SelectionFilter.allCases.map { filter in
            button("filter-" + filter.rawValue, .part, filter.title,
                   help: "Filter viewport selection to \(filter.title.lowercased()); drawing tools and tree selection are unaffected",
                   active: selectionFilter == filter, large: false) { [unowned self] in Task { await setSelectionFilter(filter) } }
        } + [button("selectOther", .hideShow, "Select Other (Tab)",
                    help: "Click geometry, then cycle through all candidates beneath that point, including occluded faces",
                    enabled: canSelectOther, large: false) { [unowned self] in Task { await selectOther() } }])
    }

    private func button(
        _ id: String, _ icon: ForgeIcon, _ title: String, help: String = "", active: Bool = false, enabled: Bool = true, large: Bool = true,
        variants: [(title: String, action: () -> Void)] = [], _ action: @escaping () -> Void
    ) -> RibbonButton {
        RibbonButton(id: id, icon: icon, title: title, help: help.isEmpty ? title : help, active: active, enabled: enabled, large: large, action: action, variants: variants)
    }

    private func op(_ o: Operation) -> () -> Void { { [unowned self] in begin(o) } }

    private var featureGroups: [RibbonGroupSpec] {
        let hasSketch = !sketches.isEmpty, hasBody = !bodies.isEmpty
        let o = operation
        return [
            RibbonGroupSpec(title: "Sketch", buttons: [
                button("startSketch", .sketch, sketchStartTitle, help: "Start a sketch on the selected planar face; use the Sketch tab to choose another plane", enabled: activeSketch == nil) { [unowned self] in
                    Task { await startSketchFromSelection() }
                },
            ]),
            RibbonGroupSpec(title: "Boss / Base", buttons: [
                button("extrude", .extrude, "Extruded Boss/Base", help: "Extrude a closed sketch profile into a new body", active: o == .extrude, enabled: hasSketch, op(.extrude)),
                button("revolve", .revolve, "Revolved Boss/Base", help: "Revolve a sketch profile about a sketch line", active: o == .revolve, enabled: hasSketch, op(.revolve)),
                button("sweep", .sweep, "Swept Boss/Base", help: "Sweep a profile (or a circle) along a path sketch", active: o == .sweep, enabled: hasSketch,
                       large: false, op(.sweep)),
                button("loft", .loft, "Lofted Boss/Base", help: "Loft through two or more profile sketches", active: o == .loft, enabled: sketches.count >= 2,
                       large: false, op(.loft)),
            ]),
            RibbonGroupSpec(title: "Cut", buttons: [
                button("cutExtrude", .cutExtrude, "Extruded Cut", help: "Extrude a sketch profile and remove it from a body", active: o == .cutExtrude,
                       enabled: hasSketch && hasBody, op(.cutExtrude)),
                button("cutRevolve", .cutRevolve, "Revolved Cut", help: "Revolve a sketch profile and remove it from a body", active: o == .cutRevolve,
                       enabled: hasSketch && hasBody, op(.cutRevolve)),
                button("hole", .hole, "Hole Wizard", help: "Standard holes (ISO) at the points of a sketch", active: o == .hole, enabled: hasSketch && hasBody, op(.hole)),
                button("cutSweep", .sweep, "Swept Cut", help: "Sweep a profile along a path and remove it from a body", active: o == .cutSweep,
                       enabled: hasSketch && hasBody, large: false, op(.cutSweep)),
                button("cutLoft", .loft, "Lofted Cut", help: "Loft through profiles and remove it from a body", active: o == .cutLoft,
                       enabled: sketches.count >= 2 && hasBody, large: false, op(.cutLoft)),
            ]),
            RibbonGroupSpec(title: "Modify", buttons: [
                button("moveBody", .move, "Move/Copy Bodies", enabled: hasBody, large: false, op(.moveBody)),
                button("fillet", o == .chamfer ? .chamfer : .fillet, o == .chamfer ? "Chamfer" : "Fillet", active: o == .fillet || o == .chamfer, enabled: hasBody,
                       variants: [("Fillet", op(.fillet)), ("Chamfer", op(.chamfer))], op(o == .chamfer ? .chamfer : .fillet)),
                button("rib", .rib, "Rib", help: "A wall from an open sketch profile, extended to meet the body", active: o == .rib, enabled: hasSketch && hasBody,
                       large: false, op(.rib)),
                button("draft", .draft, "Draft", active: o == .draft, enabled: hasBody, large: false, op(.draft)),
                button("shell", .shell, "Shell", active: o == .shell, enabled: hasBody, large: false, op(.shell)),
                button("combine", .combine, "Combine", active: o == .combine, enabled: bodies.count >= 2, large: false, op(.combine)),
                button("deleteBody", .trash, "Delete Body", enabled: !selectedBodies.isEmpty, large: false) { [unowned self] in
                    let picked = selectedBodies
                    Task { for b in picked { await run("body.delete", ["body": .string(b)]) } }
                },
            ]),
            RibbonGroupSpec(title: "Pattern", buttons: [
                button("pattern", o == .circularPattern ? .circularPattern : .linearPattern, o == .circularPattern ? "Circular Pattern" : "Linear Pattern",
                       active: o == .linearPattern || o == .circularPattern, enabled: hasBody,
                       variants: [("Linear Pattern", op(.linearPattern)), ("Circular Pattern", op(.circularPattern))], op(o == .circularPattern ? .circularPattern : .linearPattern)),
                button("mirror", .mirror, "Mirror", help: "Mirror features about a plane or planar face", active: o == .mirror, enabled: hasBody, op(.mirror)),
            ]),
            RibbonGroupSpec(title: "Reference", buttons: [
                button("plane", .plane, "Reference Geometry", active: o == .plane, variants: [("Plane", op(.plane))], op(.plane)),
            ]),
            RibbonGroupSpec(title: "Visibility", buttons: [
                button("hideBodies", .hideShow, "Hide Bodies", enabled: !selectedBodies.isEmpty, large: false) { [unowned self] in Task { await setBodiesVisible(selectedBodies, false) } },
                button("showBodies", .hideShow, "Show Bodies", enabled: !selectedBodies.isEmpty, large: false) { [unowned self] in Task { await setBodiesVisible(selectedBodies, true) } },
                button("isolateBodies", .part, "Isolate Bodies", active: isIsolatingBodies, enabled: !selectedBodies.isEmpty, large: false) { [unowned self] in Task { await isolateBodies(selectedBodies) } },
                button("exitIsolation", .part, "Exit Isolation", enabled: isIsolatingBodies, large: false) { [unowned self] in Task { await exitBodyIsolation() } },
                button("showAllBodies", .hideShow, "Show All Bodies", enabled: !hiddenBodyIDs.isEmpty || isIsolatingBodies, large: false) { [unowned self] in Task { await showAllBodies() } },
            ]),
            RibbonGroupSpec(title: "Primitives", buttons: Primitive.allCases.map { p in
                button("prim-" + p.rawValue, p.icon, p.title, active: o == .primitive(p), large: false, op(.primitive(p)))
            }),
            RibbonGroupSpec(title: "Evaluate", buttons: [
                button("measure", .measure, "Measure", active: o == .measure, enabled: hasBody, op(.measure)),
                button("massProps", .massProps, "Mass Properties", active: o == .massProperties, enabled: hasBody, op(.massProperties)),
            ]),
        ]
    }

    private func tool(_ t: SketchTool) -> () -> Void { { [unowned self] in chooseTool(sketchState.tool == t ? nil : t) } }

    private var sketchGroups: [RibbonGroupSpec] {
        let editing = activeSketch != nil, picked = !sketchSelection.isEmpty
        let st = sketchState, o = operation
        var planes: [(title: String, action: () -> Void)] = []
        for p in StandardPlane.allCases {
            planes.append((title: "\(p.rawValue.capitalized) Plane", action: { [unowned self] in Task { await newSketch(on: p) } }))
        }
        for r in refPlanes {
            let id = r.id
            planes.append((title: r.name, action: { [unowned self] in Task { await newSketch(onPlaneOrFace: id) } }))
        }
        if let f = selectedFace {
            planes.append((title: "On Selected Face", action: { [unowned self] in Task { await newSketch(onPlaneOrFace: f) } }))
        }
        let sketchButton: RibbonButton
        if editing {
            sketchButton = button("exitSketch", .exitSketch, "Exit Sketch", help: "Finish editing the sketch") { [unowned self] in Task { await exitSketch() } }
        } else {
            sketchButton = button("sketch", .sketch, sketchStartTitle, help: "Start a sketch on a plane (or the selected face)", variants: planes) { [unowned self] in
                Task { await startSketchFromSelection() }
            }
        }
        func kinds<T: RawRepresentable & CaseIterable>(_ key: WritableKeyPath<SketchUIState, T>, _ t: SketchTool) -> [(title: String, action: () -> Void)]
        where T.RawValue == String {
            T.allCases.map { k in (k.rawValue, { [unowned self] in sketchState[keyPath: key] = k; chooseTool(t) }) }
        }
        return [
            RibbonGroupSpec(title: "Sketch", buttons: [
                sketchButton,
                button("dimension", .smartDimension, "Smart Dimension", help: "Dimension one or two entities; the value is typed in the Modify box",
                       active: st.tool == .dimension, enabled: editing) { [unowned self] in
                    if sketchSelection.isEmpty { chooseTool(sketchState.tool == .dimension ? nil : .dimension) } else { dimensionSelection() }
                },
            ]),
            RibbonGroupSpec(title: "Entities", buttons: [
                button("line", st.lineKind == .centerline ? .centerline : .line, st.lineKind == .line ? "Line" : st.lineKind.rawValue, active: st.tool == .line,
                       enabled: editing, variants: kinds(\.lineKind, .line), tool(.line)),
                button("rectangle", .rectangle, "Rectangle", active: st.tool == .rectangle, enabled: editing, variants: kinds(\.rectangleType, .rectangle), tool(.rectangle)),
                button("slot", .slot, "Slot", active: st.tool == .slot, enabled: editing, variants: kinds(\.slotType, .slot), tool(.slot)),
                button("circle", .circle, "Circle", active: st.tool == .circle, enabled: editing, variants: kinds(\.circleType, .circle), tool(.circle)),
                button("arc", st.arcType == .tangent ? .tangentArc : .arc, "Arc", active: st.tool == .arc, enabled: editing, variants: kinds(\.arcType, .arc), tool(.arc)),
                button("polygon", .polygon, "Polygon", active: st.tool == .polygon, enabled: editing, large: false, tool(.polygon)),
                button("spline", .spline, "Spline", active: st.tool == .spline, enabled: editing, large: false, tool(.spline)),
                button("point", .point, "Point", active: st.tool == .point, enabled: editing, large: false, tool(.point)),
                button("ellipse", .ellipse, "Ellipse", active: st.tool == .ellipse, enabled: editing, large: false, variants: kinds(\.ellipseType, .ellipse), tool(.ellipse)),
                button("construction", .construction, "Construction", help: "Toggle construction geometry", enabled: editing && picked, large: false) { [unowned self] in
                    Task { await toggleConstruction() }
                },
            ]),
            RibbonGroupSpec(title: "Tools", buttons: [
                button("selectModelGeometry", .sketch, "Select Model Geometry", help: "Stop drawing to select body edges or faces for Convert Entities", enabled: editing, large: false) { [unowned self] in selectModelGeometry() },
                button("splitEntities", .trim, "Split Entities", help: "Split lines and arcs with one click; circles and ellipses with two", active: st.tool == .split, enabled: editing, large: false, tool(.split)),
                button("convertEntities", .sketch, "Convert Entities", help: "Project selected edges or face boundaries into this sketch as fixed copies; copies do not follow later model edits", enabled: editing && !selectedModelGeometry.isEmpty, large: false) { [unowned self] in
                    Task { await convertSelectedModelGeometry() }
                },
                button("sketchFillet", st.tool == .chamfer ? .sketchChamfer : .sketchFillet, st.tool == .chamfer ? "Sketch Chamfer" : "Sketch Fillet",
                       active: st.tool == .fillet || st.tool == .chamfer, enabled: editing,
                       variants: [("Sketch Fillet", { [unowned self] in chooseTool(.fillet) }), ("Sketch Chamfer", { [unowned self] in chooseTool(.chamfer) })],
                       tool(st.tool == .chamfer ? .chamfer : .fillet)),
                button("trim", st.tool == .extend ? .extend : .trim, st.tool == .extend ? "Extend Entities" : "Trim Entities",
                       active: st.tool == .trim || st.tool == .extend, enabled: editing,
                       variants: [("Trim Entities", { [unowned self] in chooseTool(.trim) }), ("Extend Entities", { [unowned self] in chooseTool(.extend) })],
                       tool(st.tool == .extend ? .extend : .trim)),
                button("offset", .offset, "Offset Entities", active: o == .sketchOffset, enabled: editing && picked, op(.sketchOffset)),
                button("sketchMirror", .mirror, "Mirror Entities", active: o == .sketchMirror, enabled: editing && picked, op(.sketchMirror)),
                button("sketchPattern", .linearPattern, "Sketch Pattern", active: o == .sketchLinearPattern || o == .sketchCircularPattern, enabled: editing && picked,
                       variants: [("Linear Sketch Pattern", op(.sketchLinearPattern)), ("Circular Sketch Pattern", op(.sketchCircularPattern))], op(.sketchLinearPattern)),
                button("move", .move, "Move Entities", active: [Operation.sketchMove, .sketchRotate, .sketchScale].contains(o ?? .check), enabled: editing && picked,
                       variants: [("Move Entities", { [unowned self] in form.copy = false; begin(.sketchMove) }),
                                  ("Copy Entities", { [unowned self] in form.copy = true; begin(.sketchMove) }),
                                  ("Rotate Entities", op(.sketchRotate)), ("Scale Entities", op(.sketchScale))], op(.sketchMove)),
            ]),
            RibbonGroupSpec(title: "Relations", buttons: [
                button("relations", .hideShow, "Display/Delete Relations", active: o == .displayRelations || o == .addRelation, enabled: editing,
                       variants: [("Display/Delete Relations", op(.displayRelations)), ("Add Relation", op(.addRelation))], op(.displayRelations)),
                button("addRelation", .addRelation, "Add Relation", active: o == .addRelation, enabled: editing && picked, large: false, op(.addRelation)),
                button("viewRelations", .hideShow, "View Relations", active: display.relations, large: false) { [unowned self] in display.relations.toggle() },
                button("viewDimensions", .smartDimension, "View Dimensions", active: display.dimensions, large: false) { [unowned self] in display.dimensions.toggle() },
            ]),
        ]
    }

    private var evaluateGroups: [RibbonGroupSpec] {
        let hasBody = !bodies.isEmpty
        return [
            RibbonGroupSpec(title: "Evaluate", buttons: [
                button("measure", .measure, "Measure", help: "Distance between two selected entities", active: operation == .measure, enabled: hasBody, op(.measure)),
                button("massProps", .massProps, "Mass Properties", help: "Volume, surface area and centre of mass", active: operation == .massProperties, enabled: hasBody,
                       op(.massProperties)),
                button("interference", .combine, "Interference Detection", help: "Find overlapping solid volume between selected bodies, or all bodies", active: operation == .interference, enabled: bodies.count >= 2, op(.interference)),
                button("check", .check, "Check", help: "Validate body geometry and topology", active: operation == .check, enabled: hasBody, op(.check)),
            ]),
        ]
    }
}
