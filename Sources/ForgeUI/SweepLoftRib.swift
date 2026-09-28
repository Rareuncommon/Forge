// Sweep, Loft and Rib pages: starting the operation, its invocation, filling the page from a
// feature being edited, and the page's sections (shared with Windows; the macOS pages mirror
// them in Sources/ForgeApp/PMPages.swift).

import ForgeCommands
import ForgeCore
import Foundation

extension AppModel {
    /// Sketches picked in the tree or the view, in pick order.
    private var pickedSketches: [String] {
        selection.filter { $0.hasPrefix("sketch-") && !$0.contains("/") }
    }

    func beginSweepLoftRib(_ op: Operation) {
        let ids = sketches.map(\.id)
        switch op {
        case .sweep, .cutSweep:
            // SolidWorks order: profile, then path; else the last two sketches.
            let picked = pickedSketches
            if picked.count >= 2 {
                form.sweepProfile = picked[0]
                form.sweepPath = picked[1]
            } else {
                form.sweepPath = picked.first ?? ids.last ?? ""
                form.sweepProfile = ids.last { $0 != form.sweepPath } ?? ""
            }
            form.sweepCircular = form.sweepProfile.isEmpty
        case .loft, .cutLoft:
            let picked = pickedSketches
            form.loftProfiles = picked.count >= 2 ? picked : Array(ids.suffix(2))
        case .rib:
            if operationSketch == nil || !ids.contains(operationSketch!) {
                operationSketch = activeSketch ?? pickedSketches.first ?? ids.last
            }
            form.ribGrow = "auto"
        default:
            break
        }
        form.scope = []
    }

    func sweepLoftRibInvocation(_ op: Operation) -> [Invocation]? {
        switch op {
        case .sweep, .cutSweep:
            guard !form.sweepPath.isEmpty else { return nil }
            var p: [String: JSONValue] = ["path": .string(form.sweepPath), "orientation": .string(form.sweepOrientation)]
            if form.sweepCircular {
                p["circular_diameter"] = quantity(form.sweepDiameter)
            } else {
                guard !form.sweepProfile.isEmpty, form.sweepProfile != form.sweepPath else { return nil }
                p["profile"] = .string(form.sweepProfile)
            }
            if op == .cutSweep { p["operation"] = "cut" } else if form.merge && !bodies.isEmpty { p["merge"] = true }
            return [Invocation("body.sweep", .object(p))]
        case .loft, .cutLoft:
            guard form.loftProfiles.count >= 2 else { return nil }
            var p: [String: JSONValue] = ["profiles": .array(form.loftProfiles.map { .string($0) })]
            if form.loftRuled { p["ruled"] = true }
            if op == .cutLoft { p["operation"] = "cut" } else if form.merge && !bodies.isEmpty { p["merge"] = true }
            return [Invocation("body.loft", .object(p))]
        case .rib:
            guard let sk = operationSketch, !bodies.isEmpty else { return nil }
            var p: [String: JSONValue] = [
                "sketch": .string(sk), "thickness": quantity(form.ribThickness), "direction": .string(form.ribDirection),
                "thickness_side": .string(form.ribSide),
            ]
            if form.ribGrow != "auto" { p["flip"] = .bool(form.ribGrow == "flipped") }
            return [Invocation("body.rib", .object(p))]
        default:
            return nil
        }
    }

    func fillSweepLoftRib(_ op: Operation, _ p: JSONValue) {
        let t = Self.fieldText
        switch op {
        case .sweep, .cutSweep:
            form.sweepPath = p["path"]?.stringValue ?? ""
            form.sweepProfile = p["profile"]?.stringValue ?? ""
            form.sweepCircular = p["circular_diameter"] != nil
            form.sweepDiameter = t(p["circular_diameter"]) ?? form.sweepDiameter
            form.sweepOrientation = p["orientation"]?.stringValue ?? "follow_path"
            form.merge = p["merge"]?.boolValue ?? false
        case .loft, .cutLoft:
            form.loftProfiles = p["profiles"]?.arrayValue?.compactMap(\.stringValue) ?? []
            form.loftRuled = p["ruled"]?.boolValue ?? false
            form.merge = p["merge"]?.boolValue ?? false
        case .rib:
            operationSketch = p["sketch"]?.stringValue ?? operationSketch
            form.ribThickness = t(p["thickness"]) ?? form.ribThickness
            form.ribDirection = p["direction"]?.stringValue ?? "parallel_to_sketch"
            form.ribSide = p["thickness_side"]?.stringValue ?? "both"
            form.ribGrow = p["flip"]?.boolValue.map { $0 ? "flipped" : "normal" } ?? "auto"
        default:
            break
        }
    }

    func sweepLoftRibSections(_ op: Operation) -> [PanelSection] {
        let sketchOptions = sketches.map { (tag: $0.id, title: $0.name) }
        let canMerge = (op == .sweep || op == .loft) && !bodies.isEmpty && editingFeatureCreatesBody != true
        switch op {
        case .sweep, .cutSweep:
            var profile: [PanelControl] = [check("sweepCircular", "Circular profile", \.sweepCircular)]
            if form.sweepCircular {
                profile.append(field("sweepDiameter", "Diameter", unit: "mm", \.sweepDiameter))
            } else {
                profile.append(choice("sweepProfile", "Profile", [("", "Select a sketch")] + sketchOptions, \.sweepProfile))
            }
            profile.append(choice("sweepPath", "Path", [("", "Select a sketch")] + sketchOptions, \.sweepPath))
            var options = [choice("sweepOrientation", "Orientation", [("follow_path", "Follow Path"), ("keep_normal_constant", "Keep Normal Constant")], \.sweepOrientation)]
            if canMerge { options.append(check("merge", "Merge result", \.merge)) }
            return [PanelSection("Profile and Path", controls: profile), PanelSection("Options", controls: options)]
        case .loft, .cutLoft:
            var rows: [PanelControl] = [
                PanelControl(id: "loftProfiles", kind: .list(
                    items: form.loftProfiles.map { id in sketches.first { $0.id == id }?.name ?? id }, placeholder: "Profiles (in order)", active: true, activate: nil)),
            ]
            for s in sketches {
                rows.append(PanelControl(id: "loft-" + s.id, kind: .check(
                    label: s.name, get: { [unowned self] in form.loftProfiles.contains(s.id) },
                    set: { [unowned self] on in if on { form.loftProfiles.append(s.id) } else { form.loftProfiles.removeAll { $0 == s.id } } })))
            }
            var options = [check("loftRuled", "Ruled (straight between profiles)", \.loftRuled)]
            if canMerge { options.append(check("merge", "Merge result", \.merge)) }
            return [PanelSection("Profiles", controls: rows), PanelSection("Options", controls: options)]
        case .rib:
            return [
                PanelSection("Parameters", controls: [
                    field("ribThickness", "Thickness", unit: "mm", \.ribThickness),
                    choice("ribSide", "Thickness side", [("first", "First Side"), ("both", "Both Sides"), ("second", "Second Side")], \.ribSide),
                    choice("ribDirection", "Extrusion direction", [("parallel_to_sketch", "Parallel to Sketch"), ("normal_to_sketch", "Normal to Sketch")], \.ribDirection),
                    choice("ribGrow", "Material side", [("auto", "Toward the body"), ("normal", "Side 1"), ("flipped", "Side 2 (flipped)")], \.ribGrow),
                ]),
                PanelSection("Selected Contours", controls: [sketchChoice, note("ribNote", "An open chain of lines; its ends extend until they meet the body.")]),
            ]
        default:
            return []
        }
    }

    package func sweepLoftRibMessage(_ op: Operation) -> String? {
        switch op {
        case .sweep, .cutSweep:
            if form.sweepPath.isEmpty { return "Choose the path sketch: one chain of lines, arcs or splines." }
            if !form.sweepCircular && form.sweepProfile.isEmpty { return "Choose the profile sketch, placed at the start of the path, or use a circular profile." }
            return nil
        case .loft, .cutLoft:
            return form.loftProfiles.count < 2 ? "Tick two or more profile sketches, in loft order." : nil
        case .rib:
            return bodies.isEmpty ? "A rib needs a body to meet." : sketches.isEmpty ? "Sketch the rib's open profile first." : nil
        default:
            return nil
        }
    }
}
