import ForgeCore
import Foundation

/// The plane a sketch lives on. Sketch coordinates (u, v) map to model space as
/// origin + u·xAxis + v·yAxis. Standard planes follow SolidWorks (Y-up world).
public struct SketchPlane: Codable, Sendable, Hashable {
    public var name: String
    public var origin: Vec3
    public var xAxis: Vec3
    public var yAxis: Vec3

    public init(name: String, origin: Vec3, xAxis: Vec3, yAxis: Vec3) {
        self.name = name
        self.origin = origin
        self.xAxis = xAxis.normalized
        self.yAxis = yAxis.normalized
    }

    enum CodingKeys: String, CodingKey {
        case name, origin
        case xAxis = "x_axis"
        case yAxis = "y_axis"
    }

    public var normal: Vec3 { xAxis.cross(yAxis).normalized }

    /// Front plane: XY, viewed from +Z.
    public static let front = SketchPlane(name: "Front", origin: .zero, xAxis: .unitX, yAxis: .unitY)
    /// Top plane: XZ, viewed from +Y (sketch +v is model -Z).
    public static let top = SketchPlane(name: "Top", origin: .zero, xAxis: .unitX, yAxis: -.unitZ)
    /// Right plane: YZ, viewed from +X (sketch +u is model -Z).
    public static let right = SketchPlane(name: "Right", origin: .zero, xAxis: -.unitZ, yAxis: .unitY)

    public func point(_ u: Double, _ v: Double) -> Vec3 { origin + xAxis * u + yAxis * v }
}

public enum SketchEntityKind: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case point, line, circle, arc, ellipse, ellipseArc = "ellipse_arc", spline
}

/// A sketch entity. Curves reference their defining points (which are entities too, owned
/// by the curve); scalar parameters (radii, ellipse axes/rotation) index `Sketch.params`.
public struct SketchEntity: Codable, Sendable, Hashable {
    public var id: String
    public var kind: SketchEntityKind
    public var construction: Bool
    /// For points created by a curve (line endpoints, arc centre/ends...): the curve's id.
    public var owner: String?
    /// line: [start, end]; circle: [center]; arc: [center, start, end] (CCW start→end);
    /// ellipse: [center]; ellipse_arc: [center, start, end] (CCW start→end); spline: control
    /// points; point: [].
    public var points: [String]
    /// point: [x, y]; circle: [radius]; ellipse/ellipse_arc: [major, minor, rotation];
    /// line/arc/spline: [].
    public var params: [Int]
    /// Spline degree (spline: points are its control points, first and last are its ends).
    public var degree: Int? = nil
}

public enum ConstraintKind: String, Codable, Sendable, CaseIterable, SchemaEnum {
    // relations
    case coincident, onEntity = "on_entity", horizontal, vertical, parallel, perpendicular, tangent, equal,
        symmetric, midpoint, concentric, collinear, coradial, fix
    // dimensions
    case distance, horizontalDistance = "horizontal_distance", verticalDistance = "vertical_distance",
        radius, diameter, angle, offset
    // internal (created with geometry, not user-visible as relations)
    case arcRadius = "arc_radius"

    public var isDimension: Bool {
        switch self {
        case .distance, .horizontalDistance, .verticalDistance, .radius, .diameter, .angle, .offset: true
        default: false
        }
    }

    public var isAngular: Bool { self == .angle }
}

public struct SketchConstraint: Codable, Sendable, Hashable {
    public var id: String
    public var kind: ConstraintKind
    public var entities: [String]
    /// Dimension value in mm or radians.
    public var value: Double?
    /// Driven (reference) dimensions measure but do not constrain.
    public var driven: Bool
    /// Orientation chosen when the constraint was created (which side of a line, internal vs
    /// external tangency, sign of a horizontal distance...). Keeps residuals smooth.
    public var side: Double
    public var isInternal: Bool
    /// For tangency between curves that share an endpoint: the endpoint (of a circular curve)
    /// where the tangency holds. Endpoint tangency uses a first-order formulation.
    public var at: String? = nil
    /// Offset: the driving offset this one follows (one dimension drives a whole chain).
    public var linkedTo: String? = nil
    /// Offset: endpoints of the copy held on the normal through the original's matching end
    /// (the free ends of an open chain).
    public var alignedEnds: [String]? = nil
    /// Offset: copy endpoints at a tangent joint of a chain. There the neighbouring copy already
    /// fixes the point's normal position, so this copy holds it only tangentially (aligned with
    /// the original's end) and drops its own distance row (line) or radius row (arc).
    public var tangentEnds: [String]? = nil
    /// Extra solver unknowns owned by the constraint (point on spline: the curve parameter t).
    public var aux: [Int]? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, entities, value, driven, side, at
        case isInternal = "is_internal"
        case linkedTo = "linked_to"
        case alignedEnds = "aligned_ends"
        case tangentEnds = "tangent_ends"
        case aux = "aux_params"
    }
}

/// A 2D sketch: geometry, constraints, and the last solver report. A value type, so undo,
/// transactions and dry-run work exactly like the rest of the document.
public struct Sketch: Codable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var plane: SketchPlane
    public internal(set) var params: [Double] = []
    public internal(set) var entities: [String: SketchEntity] = [:]
    public internal(set) var entityOrder: [String] = []
    public internal(set) var constraints: [SketchConstraint] = []
    public internal(set) var report: SolveReport?
    var nextEntity = 1
    var nextConstraint = 1

    /// Persisted form (document files): everything except the derived solver report, which
    /// is recomputed on load.
    enum CodingKeys: String, CodingKey {
        case id, name, plane, params, entities, constraints
        case entityOrder = "entity_order"
        case nextEntity = "next_entity"
        case nextConstraint = "next_constraint"
    }

    public static let originID = "point-0"

    public init(id: String, name: String, plane: SketchPlane) {
        self.id = id
        self.name = name
        self.plane = plane
        // The sketch origin: a fixed point everything can be related to.
        let p = addParams([0, 0])
        insert(SketchEntity(id: Self.originID, kind: .point, construction: true, owner: nil, points: [], params: p))
    }

    public var orderedEntities: [SketchEntity] { entityOrder.compactMap { entities[$0] } }
    public var userConstraints: [SketchConstraint] { constraints.filter { !$0.isInternal } }

    public func entity(_ id: String) throws -> SketchEntity {
        guard let e = entities[id] else {
            throw ForgeError(
                .unknownEntity, "sketch \(self.id) has no entity '\(id)'", entities: ["\(self.id)/\(id)"],
                suggestions: [SuggestedFix(description: "List the sketch's entities", command: "sketch.get", params: ["sketch": .string(self.id)])])
        }
        return e
    }

    public func constraint(_ id: String) throws -> SketchConstraint {
        guard let c = constraints.first(where: { $0.id == id }) else {
            throw ForgeError(.unknownEntity, "sketch \(self.id) has no constraint '\(id)'", entities: ["\(self.id)/\(id)"])
        }
        return c
    }

    // MARK: geometry creation

    mutating func addParams(_ values: [Double]) -> [Int] {
        let start = params.count
        params.append(contentsOf: values)
        return Array(start..<params.count)
    }

    mutating func insert(_ e: SketchEntity) {
        entities[e.id] = e
        entityOrder.append(e.id)
    }

    mutating func newID(_ kind: SketchEntityKind) -> String {
        defer { nextEntity += 1 }
        return "\(kind.rawValue)-\(nextEntity)"
    }

    @discardableResult
    public mutating func addPoint(_ u: Double, _ v: Double, construction: Bool = false, owner: String? = nil) -> String {
        let id = newID(.point)
        insert(SketchEntity(id: id, kind: .point, construction: construction, owner: owner, points: [], params: addParams([u, v])))
        return id
    }

    @discardableResult
    public mutating func addLine(from a: (Double, Double), to b: (Double, Double), construction: Bool = false) -> String {
        let id = newID(.line)
        let p1 = addPoint(a.0, a.1, construction: construction, owner: id)
        let p2 = addPoint(b.0, b.1, construction: construction, owner: id)
        insert(SketchEntity(id: id, kind: .line, construction: construction, owner: nil, points: [p1, p2], params: []))
        return id
    }

    @discardableResult
    public mutating func addCircle(center: (Double, Double), radius: Double, construction: Bool = false) -> String {
        let id = newID(.circle)
        let c = addPoint(center.0, center.1, construction: true, owner: id)
        insert(SketchEntity(id: id, kind: .circle, construction: construction, owner: nil, points: [c], params: addParams([radius])))
        return id
    }

    /// Arc from start to end, counter-clockwise around the centre.
    @discardableResult
    public mutating func addArc(center: (Double, Double), start: (Double, Double), end: (Double, Double), construction: Bool = false) -> String {
        let id = newID(.arc)
        let c = addPoint(center.0, center.1, construction: true, owner: id)
        let s = addPoint(start.0, start.1, construction: construction, owner: id)
        let e = addPoint(end.0, end.1, construction: construction, owner: id)
        insert(SketchEntity(id: id, kind: .arc, construction: construction, owner: nil, points: [c, s, e], params: []))
        constraints.append(
            SketchConstraint(id: "\(id)#radius", kind: .arcRadius, entities: [id], value: nil, driven: false, side: 1, isInternal: true))
        return id
    }

    @discardableResult
    public mutating func addEllipse(center: (Double, Double), major: Double, minor: Double, rotation: Double, construction: Bool = false) -> String {
        let id = newID(.ellipse)
        let c = addPoint(center.0, center.1, construction: true, owner: id)
        insert(SketchEntity(id: id, kind: .ellipse, construction: construction, owner: nil, points: [c], params: addParams([major, minor, rotation])))
        return id
    }

    /// Partial ellipse from parametric angle `from` to `to` (counter-clockwise). Its ends are
    /// held on the ellipse by internal relations.
    @discardableResult
    public mutating func addEllipseArc(
        center: (Double, Double), major: Double, minor: Double, rotation: Double, from: Double, to: Double, construction: Bool = false
    ) -> String {
        insertEllipseArc(center: center, shape: addParams([major, minor, rotation]), from: from, to: to, construction: construction)
    }

    /// Partial ellipse on the ellipse whose [major, minor, rotation] live at `shape` (indices,
    /// possibly shared with another piece of the same ellipse, so they stay one ellipse).
    @discardableResult
    mutating func insertEllipseArc(center: (Double, Double), shape: [Int], from: Double, to: Double, construction: Bool) -> String {
        let (major, minor, rotation) = (params[shape[0]], params[shape[1]], params[shape[2]])
        let id = newID(.ellipseArc)
        func at(_ phi: Double) -> (Double, Double) {
            let u = major * cos(phi), w = minor * sin(phi)
            return (center.0 + u * cos(rotation) - w * sin(rotation), center.1 + u * sin(rotation) + w * cos(rotation))
        }
        let c = addPoint(center.0, center.1, construction: true, owner: id)
        let a = at(from), b = at(to)
        let sp = addPoint(a.0, a.1, construction: construction, owner: id)
        let ep = addPoint(b.0, b.1, construction: construction, owner: id)
        insert(SketchEntity(id: id, kind: .ellipseArc, construction: construction, owner: nil, points: [c, sp, ep], params: shape))
        for (tag, p) in [("start", sp), ("end", ep)] {
            constraints.append(SketchConstraint(id: "\(id)#\(tag)", kind: .onEntity, entities: [p, id], value: nil, driven: false, side: 1, isInternal: true))
        }
        return id
    }

    public mutating func setConstruction(_ id: String, _ value: Bool) throws {
        guard var e = entities[id], id != Self.originID else { throw ForgeError(.unknownEntity, "no entity '\(id)'") }
        e.construction = value
        entities[id] = e
        if e.kind == .line || e.kind == .arc || e.kind == .ellipseArc {
            for p in e.points where entities[p]?.owner == id && !(e.kind != .line && p == e.points[0]) {
                entities[p]!.construction = value
            }
        }
    }

    // MARK: deletion

    /// Delete entities (curves take their owned points) and every constraint that references
    /// a deleted entity. Returns the ids actually removed.
    public mutating func delete(entities ids: [String]) throws -> (entities: [String], constraints: [String]) {
        var remove = Set<String>()
        for id in ids {
            guard id != Self.originID else { throw ForgeError(.invalidParams, "the sketch origin cannot be deleted") }
            let e = try entity(id)
            if e.kind == .point, let owner = e.owner {
                throw ForgeError(
                    .invalidParams, "\(id) is an endpoint of \(owner); delete the curve instead", entities: [id],
                    suggestions: [SuggestedFix(description: "Delete the owning curve", command: "sketch.delete", params: ["items": [.string(owner)]])])
            }
            remove.insert(id)
            for p in e.points where entities[p]?.owner == id { remove.insert(p) }
        }
        // Requested items first, then what they took with them (owned points), in sketch order.
        let removedEntities = ids + entityOrder.filter { remove.contains($0) && !ids.contains($0) }
        let removedConstraints = constraints.filter { $0.entities.contains(where: remove.contains) }.map(\.id)
        constraints.removeAll { $0.entities.contains(where: remove.contains) }
        for id in remove { entities.removeValue(forKey: id) }
        entityOrder.removeAll { remove.contains($0) }
        return (removedEntities, removedConstraints)
    }

    public mutating func delete(constraints ids: [String]) throws {
        for id in ids {
            let c = try constraint(id)
            guard !c.isInternal else { throw ForgeError(.invalidParams, "\(id) is internal to its arc and cannot be deleted") }
        }
        constraints.removeAll { ids.contains($0.id) }
    }

    mutating func appendConstraint(_ c: SketchConstraint) -> String {
        var c = c
        c.id = "constraint-\(nextConstraint)"
        nextConstraint += 1
        constraints.append(c)
        return c.id
    }

    mutating func setValue(_ id: String, _ value: Double) {
        for i in constraints.indices where constraints[i].id == id || constraints[i].linkedTo == id {
            constraints[i].value = value
        }
    }

    mutating func setDriven(_ id: String, _ driven: Bool) {
        if let i = constraints.firstIndex(where: { $0.id == id }) { constraints[i].driven = driven }
    }

    // MARK: geometry access (current values)

    public func point(_ id: String) -> (Double, Double) {
        let e = entities[id]!
        return (params[e.params[0]], params[e.params[1]])
    }

    /// All parameter indices an entity's shape depends on.
    func paramIndices(_ id: String) -> [Int] {
        guard let e = entities[id] else { return [] }
        return e.points.flatMap { entities[$0]!.params } + e.params
    }
}
