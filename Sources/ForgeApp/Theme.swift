// Design tokens from the Forge interface kit (docs/design). Colours adapt to light and dark
// appearance; numbers the user edits use the monospaced system font.

import AppKit
import ForgeRender
import SwiftUI

enum Theme {
    static let chrome = Color.dynamic(0xE9E9EC, 0x1F2023)
    static let chrome2 = Color.dynamic(0xF2F2F4, 0x26272B)
    static let panel = Color.dynamic(0xFBFBFC, 0x232427)
    static let surface = Color.dynamic(0xFFFFFF, 0x2C2D31)
    static let line = Color.dynamic(0xD5D5DA, 0x3A3B40)
    static let line2 = Color.dynamic(0xE4E4E8, 0x323338)
    static let text = Color.dynamic(0x1D1D1F, 0xEDEDEF)
    static let text2 = Color.dynamic(0x5E5E66, 0xA6A6AE)
    static let text3 = Color.dynamic(0x8A8A91, 0x7C7C84)
    static let accent = Color.dynamic(0x1F5FD6, 0x4C8DFF)
    static let accentText = Color.dynamic(0x1A4FB3, 0x8DB6FF)
    static let accentSoft = Color.dynamic(0xE1EAFB, 0x243452)
    static let hover = Color.dynamic(0xE2E2E7, 0x34353A)
    static let field = Color.dynamic(0xFFFFFF, 0x1B1C1F)
    static let fieldLine = Color.dynamic(0xC9C9CF, 0x45464C)
    static let viewportTop = Color.dynamic(0xF6F7F9, 0x2E323A)
    static let viewportBottom = Color.dynamic(0xD8DDE5, 0x17191D)
    static let hud = Color.dynamic(0xFFFFFF, 0x2C2D31, alpha: 0.88)
    // Sketch state (SolidWorks convention: black / blue / red), and previews.
    static let fullyDefined = Color.dynamic(0x1D1D1F, 0xF2F2F4)
    static let underDefined = Color.dynamic(0x1F5FD6, 0x5E9BFF)
    static let overDefined = Color.dynamic(0xC62F20, 0xFF6B5B)
    static let preview = Color.dynamic(0xD98200, 0xFFB23E)
    static let relation = Color.dynamic(0x2F9E55, 0x4CC27A)
    static let axisX = Color(red: 0.84, green: 0.27, blue: 0.23)
    static let axisY = Color(red: 0.18, green: 0.62, blue: 0.33)
    static let axisZ = Color(red: 0.18, green: 0.42, blue: 0.88)

    static let mono = Font.system(size: 12.5, design: .monospaced)
    static let label = Font.system(size: 12)
    static let groupTitle = Font.system(size: 12, weight: .semibold)

    static let shadowColor = Color.black.opacity(0.16)

    /// Viewport colours for the current appearance (the renderer takes plain RGBA).
    static func sketchRGBA(dark: Bool) -> (fully: RGBA, under: RGBA, over: RGBA, point: RGBA, preview: RGBA) {
        dark
            ? (RGBA(0.95, 0.95, 0.96), RGBA(0.37, 0.61, 1.0), RGBA(1.0, 0.42, 0.36), RGBA(0.85, 0.86, 0.88), RGBA(1.0, 0.70, 0.24))
            : (RGBA(0.11, 0.11, 0.12), RGBA(0.12, 0.37, 0.84), RGBA(0.78, 0.18, 0.13), RGBA(0.10, 0.10, 0.12), RGBA(0.85, 0.51, 0.0))
    }
}

extension Color {
    /// A colour that follows the window's light/dark appearance.
    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Plain button with the kit's hover and active states.
struct ToolButtonStyle: ButtonStyle {
    var active = false
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, active: active, cornerRadius: cornerRadius)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        let cornerRadius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(active ? Theme.accentText : Theme.text)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(active ? Theme.accentSoft : (hovering && enabled) || configuration.isPressed ? Theme.hover : .clear))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                .onHover { hovering = $0 }
        }
    }
}

/// Bordered secondary button (panel actions).
struct PanelButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(prominent ? Theme.accent : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(prominent ? Color.clear : Theme.line))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
