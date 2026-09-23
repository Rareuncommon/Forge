import Foundation

/// Length units supported in parameters. Internal (kernel) unit is the millimetre.
public enum LengthUnit: String, Codable, Sendable, CaseIterable {
    case millimeter = "mm"
    case centimeter = "cm"
    case meter = "m"
    case micrometer = "um"
    case inch = "in"
    case foot = "ft"

    public var millimeters: Double {
        switch self {
        case .millimeter: 1
        case .centimeter: 10
        case .meter: 1000
        case .micrometer: 0.001
        case .inch: 25.4
        case .foot: 304.8
        }
    }

    static let aliases: [String: LengthUnit] = [
        "mm": .millimeter, "millimeter": .millimeter, "millimeters": .millimeter, "millimetre": .millimeter,
        "millimetres": .millimeter,
        "cm": .centimeter, "centimeter": .centimeter, "centimeters": .centimeter,
        "m": .meter, "meter": .meter, "meters": .meter, "metre": .meter, "metres": .meter,
        "um": .micrometer, "µm": .micrometer, "micron": .micrometer, "microns": .micrometer,
        "in": .inch, "inch": .inch, "inches": .inch, "\"": .inch,
        "ft": .foot, "foot": .foot, "feet": .foot, "'": .foot,
    ]
}

/// Angle units. Internal unit is the radian.
public enum AngleUnit: String, Codable, Sendable, CaseIterable {
    case degree = "deg"
    case radian = "rad"

    public var radians: Double { self == .degree ? .pi / 180 : 1 }

    static let aliases: [String: AngleUnit] = [
        "deg": .degree, "degree": .degree, "degrees": .degree, "°": .degree,
        "rad": .radian, "radian": .radian, "radians": .radian,
    ]
}

/// The unit system of a document: how bare numbers are interpreted (SPEC §5.4).
public struct UnitSystem: Codable, Sendable, Hashable {
    public var length: LengthUnit
    public var angle: AngleUnit

    public init(length: LengthUnit = .millimeter, angle: AngleUnit = .degree) {
        self.length = length
        self.angle = angle
    }

    public static let mmgs = UnitSystem(length: .millimeter, angle: .degree)
}

/// Parses quantity strings like "25 mm", "1in", "90 deg", "-2.5e-1 m".
public enum QuantityParser {
    public static func split(_ text: String) -> (Double, String)? {
        let s = text.trimmingCharacters(in: .whitespaces)
        var idx = s.startIndex
        // Scan a floating-point literal prefix.
        let numberChars = Set("+-0123456789.eE")
        while idx < s.endIndex, numberChars.contains(s[idx]) {
            // Stop at an 'e' that is not followed by a digit or sign (e.g. "5 elephants").
            if s[idx] == "e" || s[idx] == "E" {
                let next = s.index(after: idx)
                guard next < s.endIndex, "+-0123456789".contains(s[next]) else { break }
            }
            idx = s.index(after: idx)
        }
        guard let value = Double(s[s.startIndex..<idx]), value.isFinite else { return nil }
        let unit = s[idx...].trimmingCharacters(in: .whitespaces).lowercased()
        return (value, unit)
    }

    public static func length(_ text: String, default unit: LengthUnit) throws -> Double {
        guard let (v, u) = split(text) else {
            throw ForgeError(.invalidUnit, "'\(text)' is not a length (expected e.g. \"25 mm\" or \"1 in\")")
        }
        if u.isEmpty { return v * unit.millimeters }
        guard let lu = LengthUnit.aliases[u] else {
            throw ForgeError(
                .invalidUnit,
                "unknown length unit '\(u)' in '\(text)'; supported: \(LengthUnit.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return v * lu.millimeters
    }

    public static func angle(_ text: String, default unit: AngleUnit) throws -> Double {
        guard let (v, u) = split(text) else {
            throw ForgeError(.invalidUnit, "'\(text)' is not an angle (expected e.g. \"90 deg\")")
        }
        if u.isEmpty { return v * unit.radians }
        guard let au = AngleUnit.aliases[u] else {
            throw ForgeError(.invalidUnit, "unknown angle unit '\(u)' in '\(text)'; supported: deg, rad")
        }
        return v * au.radians
    }
}

/// Unit-context for decoding: bare numbers are interpreted in the document unit system.
/// Set per decode via `Decoder.userInfo[.unitSystem]`.
extension CodingUserInfoKey {
    public static let unitSystem = CodingUserInfoKey(rawValue: "forge.unitSystem")!
}

/// A length parameter. Decodes from a number (document units) or a string with units.
/// `value` is always millimetres.
public struct Length: Codable, Sendable, Hashable, CustomStringConvertible {
    public var millimeters: Double

    public init(millimeters: Double) { self.millimeters = millimeters }
    public static func mm(_ v: Double) -> Length { Length(millimeters: v) }

    public init(from decoder: any Decoder) throws {
        let units = decoder.userInfo[.unitSystem] as? UnitSystem ?? .mmgs
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            millimeters = d * units.length.millimeters
        } else {
            let s = try c.decode(String.self)
            millimeters = try QuantityParser.length(s, default: units.length)
        }
        guard millimeters.isFinite else { throw ForgeError(.invalidParams, "length must be finite") }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode("\(Self.format(millimeters)) mm")
    }

    static func format(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 1e15 { return String(Int64(v)) }
        return String(v)
    }

    public var description: String { "\(Self.format(millimeters)) mm" }
}

/// An angle parameter. Decodes from a number (document units) or a string with units.
public struct Angle: Codable, Sendable, Hashable, CustomStringConvertible {
    public var radians: Double

    public init(radians: Double) { self.radians = radians }
    public static func degrees(_ d: Double) -> Angle { Angle(radians: d * .pi / 180) }
    public var degrees: Double { radians * 180 / .pi }

    public init(from decoder: any Decoder) throws {
        let units = decoder.userInfo[.unitSystem] as? UnitSystem ?? .mmgs
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            radians = d * units.angle.radians
        } else {
            radians = try QuantityParser.angle(try c.decode(String.self), default: units.angle)
        }
        guard radians.isFinite else { throw ForgeError(.invalidParams, "angle must be finite") }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode("\(Length.format((degrees * 1e9).rounded() / 1e9)) deg")
    }

    public var description: String { "\(Length.format(degrees)) deg" }
}
