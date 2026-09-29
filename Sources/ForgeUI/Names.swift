import ForgeCore
import ForgeCommands
import ForgeSketch

/// Use the command bus parser so transient indices and persistent topology names behave alike.
package func entityKind(_ ref: String) -> EntityRef.Kind? {
    EntityRef(parsing: ref)?.kind
}

/// Icon of a selected reference (face, edge, vertex, sketch entity).
package func entityIcon(_ ref: String) -> ForgeIcon {
    if entityKind(ref) == .face { return .plane }
    if entityKind(ref) == .edge { return .line }
    if entityKind(ref) == .vertex { return .point }
    let local = ref.split(separator: "/").last.map(String.init) ?? ref
    for (prefix, icon) in [("line", ForgeIcon.line), ("circle", .circle), ("arc", .arc), ("point", .point), ("spline", .spline), ("ellipse", .ellipse)]
    where local.hasPrefix(prefix) {
        return icon
    }
    return ref.hasPrefix("sketch-") ? .sketch : .part
}

/// A reference as shown in lists ("body-1 · face-3").
package func shortName(_ ref: String) -> String {
    ref.split(separator: "/").map(String.init).joined(separator: " · ")
}

extension RelationType {
    package var title: String {
        switch self {
        case .onEntity: "On Entity"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}
