// Icon geometry for front ends that draw the icon set themselves (Windows, Linux): each
// ForgeIcon's layers (Icons.swift) parsed into absolute move / line / cubic / close elements,
// with arcs and quadratic curves converted to cubics, so a native shell only has to stroke or
// fill simple paths. The macOS app draws the same paths through SwiftUI (IconView.swift).

import Foundation

package enum IconPaint: String, Sendable {
    /// Stroke in the label colour.
    case stroke = "s"
    /// Stroke in the accent colour.
    case accentStroke = "a"
    /// Dashed stroke, label colour.
    case dashed = "d"
    /// Dashed stroke, accent colour.
    case accentDashed = "ad"
    /// Filled, label colour.
    case fill = "f"
    /// Filled, accent colour at low opacity.
    case accentFill = "af"
}

package enum IconElement: Equatable, Sendable {
    case move(Double, Double)
    case line(Double, Double)
    case cubic(Double, Double, Double, Double, Double, Double)
    case close
}

package struct IconPath: Sendable {
    package var paint: IconPaint
    package var elements: [IconElement]
}

extension ForgeIcon {
    /// The icon's layers on its 24 × 24 grid.
    package var drawing: [IconPath] {
        (ForgeIcon.paths[self] ?? "").components(separatedBy: " | ").map(IconGeometry.layer)
    }

    /// The layers as text for the native shells' fw_icon_define: layers separated by "|", each
    /// "<paint> <elements>" with absolute M x y / L x y / C x1 y1 x2 y2 x y / Z.
    package var geometry: String {
        drawing.map { layer in
            ([layer.paint.rawValue] + layer.elements.map(IconGeometry.text)).joined(separator: " ")
        }.joined(separator: "|")
    }
}

package enum IconGeometry {
    static func layer(_ source: String) -> IconPath {
        let s = source.trimmingCharacters(in: .whitespaces)
        for (prefix, paint) in [("ad:", IconPaint.accentDashed), ("af:", .accentFill), ("a:", .accentStroke), ("d:", .dashed), ("f:", .fill)]
        where s.hasPrefix(prefix) {
            return IconPath(paint: paint, elements: parse(String(s.dropFirst(prefix.count))))
        }
        return IconPath(paint: .stroke, elements: parse(s))
    }

    static func text(_ e: IconElement) -> String {
        func f(_ v: Double) -> String {
            let r = (v * 1000).rounded() / 1000
            return r == r.rounded() ? String(Int(r)) : String(r)
        }
        switch e {
        case .move(let x, let y): return "M \(f(x)) \(f(y))"
        case .line(let x, let y): return "L \(f(x)) \(f(y))"
        case .cubic(let a, let b, let c, let d, let x, let y): return "C \(f(a)) \(f(b)) \(f(c)) \(f(d)) \(f(x)) \(f(y))"
        case .close: return "Z"
        }
    }

    private enum Token { case command(Character), number(Double) }

    /// The SVG path subset the icons use: M L H V C Q A Z, absolute and relative.
    package static func parse(_ d: String) -> [IconElement] {
        var out: [IconElement] = []
        var tokens = tokenize(d)[...]
        var cmd: Character = "M"
        var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0

        func num() -> Double {
            if case .number(let v)? = tokens.first {
                tokens.removeFirst()
                return v
            }
            return 0
        }
        func hasNumber() -> Bool {
            if case .number? = tokens.first { return true }
            return false
        }

        while !tokens.isEmpty {
            if case .command(let c) = tokens.first! {
                cmd = c
                tokens.removeFirst()
            } else if !hasNumber() {
                tokens.removeFirst()
                continue
            }
            let rel = cmd.isLowercase
            func pt() -> (Double, Double) {
                let x = num(), y = num()
                return rel ? (cx + x, cy + y) : (x, y)
            }
            switch cmd.uppercased().first! {
            case "M":
                (cx, cy) = pt()
                (sx, sy) = (cx, cy)
                out.append(.move(cx, cy))
                cmd = rel ? "l" : "L"  // further pairs are line-tos
            case "L":
                (cx, cy) = pt()
                out.append(.line(cx, cy))
            case "H":
                let x = num()
                cx = rel ? cx + x : x
                out.append(.line(cx, cy))
            case "V":
                let y = num()
                cy = rel ? cy + y : y
                out.append(.line(cx, cy))
            case "C":
                let c1 = pt(), c2 = pt(), e = pt()
                out.append(.cubic(c1.0, c1.1, c2.0, c2.1, e.0, e.1))
                (cx, cy) = e
            case "Q":
                let c = pt(), e = pt()
                // Degree elevation: the cubic through the same curve.
                out.append(.cubic(
                    cx + 2.0 / 3.0 * (c.0 - cx), cy + 2.0 / 3.0 * (c.1 - cy),
                    e.0 + 2.0 / 3.0 * (c.0 - e.0), e.1 + 2.0 / 3.0 * (c.1 - e.1), e.0, e.1))
                (cx, cy) = e
            case "A":
                let rx = num(), ry = num(), rot = num(), large = num() != 0, sweep = num() != 0
                let e = pt()
                out += arc(from: (cx, cy), to: e, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                (cx, cy) = e
            case "Z":
                out.append(.close)
                (cx, cy) = (sx, sy)
                if hasNumber() { tokens.removeFirst() }
                cmd = "M"
                continue
            default:
                if hasNumber() { tokens.removeFirst() }
            }
        }
        return out
    }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        var numberText = ""
        func flush() {
            if let v = Double(numberText) { out.append(.number(v)) }
            numberText = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" {
                flush()
                out.append(.command(ch))
            } else if ch == "-" {
                if !numberText.isEmpty && numberText.last != "e" { flush() }
                numberText.append(ch)
            } else if ch == "." && numberText.contains(".") {
                flush()
                numberText = "0."
            } else if ch.isNumber || ch == "." || ch == "e" {
                numberText.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// SVG endpoint arc → cubic Béziers (SVG 1.1 implementation notes, F.6.5).
    private static func arc(from p0: (Double, Double), to p1: (Double, Double), rx rxIn: Double, ry ryIn: Double, rotation: Double,
                            large: Bool, sweep: Bool) -> [IconElement] {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p1 else { return [.line(p1.0, p1.1)] }
        let phi = rotation * .pi / 180, c = cos(phi), s = sin(phi)
        let dx = (p0.0 - p1.0) / 2, dy = (p0.1 - p1.1) / 2
        let x1 = c * dx + s * dy, y1 = -s * dx + c * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = (max(0, num) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let ccx = c * cxp - s * cyp + (p0.0 + p1.0) / 2
        let ccy = s * cxp + c * cyp + (p0.1 + p1.1) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double { atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
        let t1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dt = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi }
        if sweep && dt < 0 { dt += 2 * .pi }
        let segments = max(1, Int((abs(dt) / (.pi / 2)).rounded(.up)))
        let step = dt / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ t: Double) -> (Double, Double) { (ccx + rx * cos(t) * c - ry * sin(t) * s, ccy + rx * cos(t) * s + ry * sin(t) * c) }
        func deriv(_ t: Double) -> (Double, Double) { (-rx * sin(t) * c - ry * cos(t) * s, -rx * sin(t) * s + ry * cos(t) * c) }
        var out: [IconElement] = []
        var t = t1
        for _ in 0..<segments {
            let a = point(t), b = point(t + step), da = deriv(t), db = deriv(t + step)
            out.append(.cubic(a.0 + k * da.0, a.1 + k * da.1, b.0 - k * db.0, b.1 - k * db.1, b.0, b.1))
            t += step
        }
        return out
    }
}
