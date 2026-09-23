import ForgeCore
import ForgeKernel
import Foundation

/// An expected scalar with tolerance. Passes if |actual - value| <= max(tol, rel * |value|).
public struct ScalarExpectation: Codable, Sendable, Hashable, SchemaDocumented {
    public var value: Double
    public var tol: Double?
    public var rel: Double?
    public static let fieldDocs: [String: FieldDoc] = [
        "value": "Expected value (mm-based units, see the property name)",
        "tol": FieldDoc("Absolute tolerance", default: 1e-6),
        "rel": FieldDoc("Relative tolerance", default: 1e-9),
    ]

    func allowed() -> Double { max(tol ?? 1e-6, (rel ?? 1e-9) * abs(value)) }
}

public struct VectorExpectation: Codable, Sendable, Hashable, SchemaDocumented {
    public var value: [Double]
    public var tol: Double?
    public static let fieldDocs: [String: FieldDoc] = [
        "value": "Expected [x, y, z] in mm",
        "tol": FieldDoc("Absolute tolerance per component", default: 1e-6),
    ]
}

public struct BodyExpectation: Codable, Sendable, Hashable, SchemaDocumented {
    public var body: String
    public var volumeMM3: ScalarExpectation?
    public var surfaceAreaMM2: ScalarExpectation?
    public var centroid: VectorExpectation?
    public var bboxMin: VectorExpectation?
    public var bboxMax: VectorExpectation?
    public var bboxSize: VectorExpectation?
    public var solids: Int?
    public var faces: Int?
    public var edges: Int?
    public var vertices: Int?
    public var valid: Bool?
    public var closed: Bool?

    enum CodingKeys: String, CodingKey {
        case body, centroid, solids, faces, edges, vertices, valid, closed
        case volumeMM3 = "volume_mm3"
        case surfaceAreaMM2 = "surface_area_mm2"
        case bboxMin = "bbox_min"
        case bboxMax = "bbox_max"
        case bboxSize = "bbox_size"
    }

    public static let fieldDocs: [String: FieldDoc] = [
        "body": "Body id or unique name",
        "volume_mm3": "Expected volume",
        "surface_area_mm2": "Expected surface area",
        "centroid": "Expected centre of mass",
        "bbox_min": "Expected bounding-box minimum corner",
        "bbox_max": "Expected bounding-box maximum corner",
        "bbox_size": "Expected bounding-box size",
        "solids": "Expected number of solids",
        "faces": "Expected number of faces",
        "edges": "Expected number of edges",
        "vertices": "Expected number of vertices",
        "valid": "Expected B-rep validity",
        "closed": "Expected watertightness",
    ]
}

public struct ModelSpec: Codable, Sendable, Hashable, SchemaDocumented {
    public var bodyCount: Int?
    public var bodies: [BodyExpectation]?

    enum CodingKeys: String, CodingKey {
        case bodies
        case bodyCount = "body_count"
    }

    public static let fieldDocs: [String: FieldDoc] = [
        "body_count": "Expected number of bodies in the document",
        "bodies": "Per-body expectations",
    ]
}

public struct SpecCheck: Codable, Sendable, Hashable {
    public var subject: String
    public var property: String
    public var expected: JSONValue
    public var actual: JSONValue
    public var passed: Bool
}

public struct SpecReport: Codable, Sendable {
    public var passed: Bool
    public var failures: Int
    public var checks: [SpecCheck]
}

public enum QueryCompareToSpec: Command {
    public struct Params: Codable, Sendable, SchemaDocumented {
        public var spec: ModelSpec
        public static let fieldDocs: [String: FieldDoc] = ["spec": "Expectations to check the active document against"]
    }
    public typealias Output = SpecReport

    public static let name = "query.compare_to_spec"
    public static let summary = "Check the model against expected dimensions, volumes, bounding boxes and topology counts"
    public static let discussion = "Returns every individual check with expected vs actual, so an agent can see exactly what is off. The golden-model regression suite uses this same format."
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.unknownEntity]
    public static let examples: [JSONValue] = [
        ["spec": ["body_count": 1, "bodies": [["body": "body-1", "volume_mm3": ["value": 1000, "tol": 0.01], "faces": 6]]]]
    ]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        try evaluate(p.spec, document: try ctx.requireDocument())
    }

    public static func evaluate(_ spec: ModelSpec, document doc: Document) throws -> SpecReport {
        var checks: [SpecCheck] = []
        if let n = spec.bodyCount {
            checks.append(SpecCheck(subject: "document", property: "body_count", expected: .number(Double(n)), actual: .number(Double(doc.bodyOrder.count)), passed: n == doc.bodyOrder.count))
        }
        for e in spec.bodies ?? [] {
            guard let b = try? doc.body(e.body) else {
                checks.append(SpecCheck(subject: e.body, property: "exists", expected: true, actual: false, passed: false))
                continue
            }
            let mp = try b.shape.massProperties()
            let bb = try b.shape.boundingBox()
            let topo = try b.shape.topology()
            let validity = try b.shape.check()
            func scalar(_ prop: String, _ x: ScalarExpectation?, _ actual: Double) {
                guard let x else { return }
                checks.append(SpecCheck(
                    subject: b.id, property: prop, expected: ["value": .number(x.value), "allowed_deviation": .number(x.allowed())],
                    actual: .number(actual), passed: abs(actual - x.value) <= x.allowed()))
            }
            func vector(_ prop: String, _ x: VectorExpectation?, _ actual: Vec3) {
                guard let x else { return }
                let a = actual.array
                let ok = x.value.count == 3 && zip(x.value, a).allSatisfy { abs($0 - $1) <= (x.tol ?? 1e-6) }
                checks.append(SpecCheck(
                    subject: b.id, property: prop, expected: ["value": .array(x.value.map { .number($0) }), "tol": .number(x.tol ?? 1e-6)],
                    actual: .array(a.map { .number($0) }), passed: ok))
            }
            func count(_ prop: String, _ x: Int?, _ actual: Int) {
                guard let x else { return }
                checks.append(SpecCheck(subject: b.id, property: prop, expected: .number(Double(x)), actual: .number(Double(actual)), passed: x == actual))
            }
            func flag(_ prop: String, _ x: Bool?, _ actual: Bool) {
                guard let x else { return }
                checks.append(SpecCheck(subject: b.id, property: prop, expected: .bool(x), actual: .bool(actual), passed: x == actual))
            }
            scalar("volume_mm3", e.volumeMM3, mp.volume)
            scalar("surface_area_mm2", e.surfaceAreaMM2, mp.surfaceArea)
            vector("centroid", e.centroid, mp.centroid)
            vector("bbox_min", e.bboxMin, bb.min)
            vector("bbox_max", e.bboxMax, bb.max)
            vector("bbox_size", e.bboxSize, bb.size)
            count("solids", e.solids, topo.solids)
            count("faces", e.faces, topo.faces)
            count("edges", e.edges, topo.edges)
            count("vertices", e.vertices, topo.vertices)
            flag("valid", e.valid, validity.isValid)
            flag("closed", e.closed, validity.isClosed)
        }
        let failures = checks.filter { !$0.passed }.count
        return SpecReport(passed: failures == 0, failures: failures, checks: checks)
    }
}

/// A Forge script: commands plus an optional expectation (golden models, macros, CLI runs).
public struct ForgeScript: Codable, Sendable {
    public var forgeScript: Int
    public var name: String?
    public var description: String?
    public var commands: [Invocation]
    public var expect: ModelSpec?

    enum CodingKeys: String, CodingKey {
        case name, description, commands, expect
        case forgeScript = "forge_script"
    }

    public init(name: String? = nil, commands: [Invocation], expect: ModelSpec? = nil) {
        forgeScript = 1
        self.name = name
        self.commands = commands
        self.expect = expect
    }

    public static func load(_ url: URL) throws -> ForgeScript {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ForgeError(.ioError, "cannot read \(url.path): \(error.localizedDescription)") }
        do {
            let s = try JSONCoding.decoder().decode(ForgeScript.self, from: data)
            guard s.forgeScript == 1 else { throw ForgeError(.unsupported, "unsupported forge_script version \(s.forgeScript)") }
            return s
        } catch let e as ForgeError {
            throw e
        } catch {
            throw ForgeError(.invalidParams, "\(url.lastPathComponent) is not a valid forge script: \(ForgeError.wrap(error).message)")
        }
    }
}

public struct ScriptResult: Sendable {
    public var outcomes: [CommandOutcome]
    public var report: SpecReport?
}

extension Engine {
    /// Run a script (non-atomically, stopping at the first error) and evaluate its expectations.
    public func run(_ script: ForgeScript) throws -> ScriptResult {
        var outcomes: [CommandOutcome] = []
        for (i, inv) in script.commands.enumerated() {
            do {
                outcomes.append(try execute(inv.command, inv.params))
            } catch {
                var e = ForgeError.wrap(error)
                e.message = "step \(i + 1) (\(inv.command)): \(e.message)"
                throw e
            }
        }
        var report: SpecReport?
        if let spec = script.expect {
            guard let doc = activeDocument else { throw ForgeError(.preconditionFailed, "script left no active document to check") }
            report = try QueryCompareToSpec.evaluate(spec, document: doc)
        }
        return ScriptResult(outcomes: outcomes, report: report)
    }
}
