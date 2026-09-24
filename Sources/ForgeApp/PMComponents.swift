// PropertyManager building blocks (docs/design; docs/research §1.3): title with OK / Cancel,
// yellow message box, collapsible group boxes (optionally with an enabling checkbox), fields
// with units, type lists, selection boxes.

import ForgeCommands
import ForgeCore
import SwiftUI


struct PMHeader: View {
    let icon: ForgeIcon
    let title: String
    var subtitle: String = ""
    var onOK: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var okEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                IconView(icon: icon, size: 22, accent: Theme.accent)
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(2) }
                }
            }
            if onOK != nil || onCancel != nil {
                HStack(spacing: 6) {
                    if let onOK {
                        Button(action: onOK) {
                            IconView(icon: .check, size: 17).foregroundStyle(.white)
                                .frame(width: 34, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!okEnabled)
                        .opacity(okEnabled ? 1 : 0.45)
                        .help("OK (↩)")
                    }
                    if let onCancel {
                        Button(action: onCancel) {
                            IconView(icon: .xmark, size: 17).foregroundStyle(Theme.text2)
                                .frame(width: 34, height: 28)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .help("Cancel (Esc)")
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// A collapsible group box.
struct PMGroup<Content: View>: View {
    let title: String
    @Binding var isOpen: Bool
    @ViewBuilder let content: Content

    init(_ title: String, isOpen: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isOpen = isOpen
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 7) {
                    IconView(icon: isOpen ? .chevronDown : .chevronRight, size: 12).foregroundStyle(Theme.text3)
                    Text(title).font(Theme.groupTitle).foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 9) { content }
                    .padding(EdgeInsets(top: 2, leading: 14, bottom: 14, trailing: 14))
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
    }
}

/// A group that stays open (most option groups).
struct PMSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @State private var open = true

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        PMGroup(title, isOpen: $open) { content }
    }
}

struct PMField: View {
    let label: String
    @Binding var text: String
    var unit = ""
    var icon: ForgeIcon? = nil
    var help = ""
    /// Return in the field (parameter fields that act immediately).
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let icon { IconView(icon: icon, size: 16, accent: Theme.accent).foregroundStyle(Theme.text2) }
            Text(label).font(Theme.label).foregroundStyle(Theme.text2).frame(width: 74, alignment: .leading)
            HStack(spacing: 4) {
                TextField(label, text: $text)
                    .onSubmit { onSubmit?() }
                    .textFieldStyle(.plain)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.text)
                    .labelsHidden()
                if !unit.isEmpty { Text(unit).font(.system(size: 11.5)).foregroundStyle(Theme.text3) }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.fieldLine))
        }
        .help(help)
    }
}

struct PMPicker<Value: Hashable, Options: View>: View {
    let label: String
    @Binding var selection: Value
    var icon: ForgeIcon? = nil
    @ViewBuilder let options: Options

    var body: some View {
        HStack(spacing: 8) {
            if let icon { IconView(icon: icon, size: 16, accent: Theme.accent).foregroundStyle(Theme.text2) }
            if !label.isEmpty { Text(label).font(Theme.label).foregroundStyle(Theme.text2).frame(width: 74, alignment: .leading) }
            Picker(label, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
        }
    }
}

struct PMCheckbox: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text) }
            .toggleStyle(.checkbox)
    }
}

/// A selection box: the entities an operation acts on, outlined in the accent colour.
struct PMSelectionBox: View {
    let items: [(icon: ForgeIcon, text: String)]
    var placeholder = ""
    /// The box receiving picks (SolidWorks highlights the active box).
    var active: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty {
                Text(placeholder).font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    IconView(icon: item.icon, size: 14, accent: Theme.accent)
                    Text(item.text).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.accentText)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accentSoft))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder((active ?? !items.isEmpty) ? Theme.accent : Theme.line, lineWidth: active == true ? 2 : 1.5))
        .background(RoundedRectangle(cornerRadius: 7).fill(active == true ? Theme.accentSoft.opacity(0.5) : .clear))
    }
}

struct PMNote: View {
    let text: String
    var warning = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(warning ? Theme.overDefined : Theme.text2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chrome2))
    }
}


/// SolidWorks' message box: what to select or do next, tinted yellow.
struct PMMessage: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("i").font(.system(size: 11, weight: .bold, design: .serif)).foregroundStyle(Color(red: 0.55, green: 0.42, blue: 0.0))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color(red: 0.55, green: 0.42, blue: 0.0), lineWidth: 1))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.dynamic(0xFFF6D6, 0x3A3320)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.dynamic(0xEBD58A, 0x5A4E2A)))
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 2, trailing: 14))
    }
}

/// A list of mutually exclusive types (Rectangle Type, Arc Type…), one row each.
struct PMTypeList<T: Hashable>: View {
    let options: [(value: T, icon: ForgeIcon, title: String)]
    @Binding var selection: T

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.value == selection
                Button { selection = o.value } label: {
                    HStack(spacing: 8) {
                        IconView(icon: o.icon, size: 17, accent: Theme.accent)
                        Text(o.title).font(.system(size: 12.5))
                        Spacer()
                        if on { IconView(icon: .check, size: 13) }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                }
                .buttonStyle(ToolButtonStyle(active: on, cornerRadius: 6))
            }
        }
    }
}

/// A group whose title checkbox enables it (Direction 2, Thin Feature…).
struct PMCheckGroup<Content: View>: View {
    let title: String
    @Binding var isOn: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Toggle(isOn: $isOn) { Text(title).font(Theme.groupTitle).foregroundStyle(Theme.text) }
                    .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            if isOn {
                VStack(alignment: .leading, spacing: 9) { content }
                    .padding(EdgeInsets(top: 2, leading: 14, bottom: 14, trailing: 14))
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
    }
}

/// A read-only value row (measured lengths, angles).
struct PMValue: View {
    let label: String
    let value: String
    var icon: ForgeIcon? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let icon { IconView(icon: icon, size: 16, accent: Theme.accent).foregroundStyle(Theme.text2) }
            Text(label).font(Theme.label).foregroundStyle(Theme.text2).frame(width: 74, alignment: .leading)
            Text(value).font(Theme.mono).foregroundStyle(Theme.text).textSelection(.enabled)
            Spacer()
        }
        .frame(height: 22)
    }
}

/// A JSON result as readable rows (nested objects flattened, numbers rounded).
struct KeyValueList: View {
    let value: JSONValue

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(Array(rows(value, prefix: "").enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(Theme.text2)
                    Text(row.1).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
                }
                .font(.system(size: 11.5))
            }
        }
    }

    private func rows(_ v: JSONValue, prefix: String) -> [(String, String)] {
        switch v {
        case .object(let o):
            return o.keys.sorted().flatMap { k in rows(o[k]!, prefix: prefix.isEmpty ? k : "\(prefix).\(k)") }
        default:
            return [(prefix.replacingOccurrences(of: "_", with: " "), format(v))]
        }
    }

    private func format(_ v: JSONValue) -> String {
        switch v {
        case .number(let d): return d == d.rounded() && abs(d) < 1e12 ? String(Int(d)) : String(format: "%.4g", d)
        case .string(let s): return s
        case .bool(let b): return b ? "yes" : "no"
        case .array(let a): return "(" + a.map(format).joined(separator: ", ") + ")"
        case .null: return "—"
        case .object: return "…"
        }
    }
}
