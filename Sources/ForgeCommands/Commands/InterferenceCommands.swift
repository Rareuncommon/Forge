import ForgeCore
import ForgeKernel
import Foundation

public enum QueryInterference: Command {
    public struct Params: Codable, Sendable, SchemaDocumented, ValidatableParams {
        public var bodies: [String]?
        public var minVolumeMM3: Double?
        enum CodingKeys: String, CodingKey {
            case bodies
            case minVolumeMM3 = "min_volume_mm3"
        }
        public static let fieldDocs: [String: FieldDoc] = [
            "bodies": FieldDoc("Two to 100 distinct body ids or unique names; omitted checks all bodies (maximum 100)", default: "all bodies"),
            "min_volume_mm3": FieldDoc("Report only overlap volumes strictly greater than this threshold in cubic millimetres, independent of document units; finite and nonnegative", default: 1e-9),
        ]
        public func validate() throws {
            if let bodies, !(2...100).contains(bodies.count) {
                throw ForgeError(.invalidParams, "bodies must contain two to 100 distinct bodies")
            }
            if let v = minVolumeMM3, !v.isFinite || v < 0 {
                throw ForgeError(.invalidParams, "min_volume_mm3 must be finite and nonnegative")
            }
        }
    }
    public struct Interference: Codable, Sendable {
        public var bodyA: String
        public var bodyB: String
        public var volumeMM3: Double
        public var bboxMM: BoxResult
        enum CodingKeys: String, CodingKey {
            case bodyA = "body_a", bodyB = "body_b"
            case volumeMM3 = "volume_mm3", bboxMM = "bbox_mm"
        }
    }
    public struct Output: Codable, Sendable {
        public var bodies: [String]
        public var checkedPairs: Int
        public var interferenceCount: Int
        public var interferences: [Interference]
        public var minVolumeMM3: Double
        enum CodingKeys: String, CodingKey {
            case bodies, interferences
            case checkedPairs = "checked_pairs", interferenceCount = "interference_count"
            case minVolumeMM3 = "min_volume_mm3"
        }
    }
    public static let name = "query.interference"
    public static let summary = "Check solid bodies for interference with exact B-rep overlap volumes and bounding boxes"
    public static let discussion = "Checks each unique pair in document creation order using OCCT solid intersections, without modifying the document. Touching faces/edges and separated bodies are not interference. The volume threshold is in mm³; it filters results and does not alter kernel geometric tolerances. Empty and single-body documents return zero pairs. At most 100 bodies per call; select subsets for larger models. This checks multibody parts, not assembly components or moving collisions."
    public static let category = CommandCategory.query
    public static let undo = UndoBehavior.none
    public static let errors: [ErrorCode] = [.preconditionFailed, .invalidParams, .unknownEntity, .booleanFailed, .kernelFailure]
    public static let examples: [JSONValue] = [["bodies": ["body-1", "body-2"], "min_volume_mm3": 0.001]]

    public static func run(_ p: Params, _ ctx: inout CommandContext) throws -> Output {
        let doc = try ctx.requireDocument()
        let selected: [Body]
        if let refs = p.bodies {
            let resolved = try refs.map { try doc.body($0) }
            let ids = Set(resolved.map(\.id))
            guard ids.count == refs.count else {
                throw ForgeError(.invalidParams, "bodies must identify distinct bodies (including names and ids that refer to the same body)", entities: refs,
                                 suggestions: [SuggestedFix(description: "List available bodies", command: "query.bodies", params: [:])])
            }
            selected = doc.orderedBodies.filter { ids.contains($0.id) }
        } else {
            selected = doc.orderedBodies
        }
        guard selected.count <= 100 else {
            throw ForgeError(.invalidParams, "Interference checks support at most 100 bodies per call; select a smaller subset",
                             suggestions: [SuggestedFix(description: "List bodies to choose a subset", command: "query.bodies", params: [:])])
        }
        let threshold = p.minVolumeMM3 ?? 1e-9
        var overlaps: [Interference] = []
        for (i, a) in selected.enumerated() {
            for b in selected.dropFirst(i + 1) {
                do {
                    guard let common = try Kernel.intersection(a.shape, b.shape) else { continue }
                    let volume = try common.massProperties().volume
                    guard volume.isFinite, volume >= 0 else {
                        throw ForgeError(.kernelFailure, "Intersection returned an invalid volume")
                    }
                    if volume > threshold {
                        overlaps.append(Interference(bodyA: a.id, bodyB: b.id, volumeMM3: volume,
                                                     bboxMM: BoxResult(try common.boundingBox())))
                    }
                } catch var error as ForgeError {
                    error.entities = [a.id, b.id]
                    throw error
                }
            }
        }
        return Output(bodies: selected.map(\.id), checkedPairs: selected.count * (selected.count - 1) / 2,
                      interferenceCount: overlaps.count, interferences: overlaps, minVolumeMM3: threshold)
    }
}
