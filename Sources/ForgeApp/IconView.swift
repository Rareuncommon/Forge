import ForgeUI
import SwiftUI

extension ForgeIcon {
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
