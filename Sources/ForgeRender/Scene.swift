import ForgeCore
import ForgeKernel
import Foundation

public struct RGBA: Sendable, Hashable, Codable {
    public var r, g, b, a: Float

    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
    public static let edge = RGBA(0.08, 0.09, 0.11)
    public static let highlight = RGBA(1.0, 0.55, 0.1)
    public static let background = RGBA(0.93, 0.94, 0.96)
    // Sketch colours by constraint state (SolidWorks convention).
    public static let sketchUnder = RGBA(0.10, 0.35, 0.90)
    public static let sketchFully = RGBA(0.05, 0.05, 0.05)
    public static let sketchOver = RGBA(0.90, 0.10, 0.10)
    public static let sketchConstruction = RGBA(0.55, 0.55, 0.60)

    /// Default body palette (stable by index).
    public static func bodyColor(_ i: Int) -> RGBA {
        let palette: [RGBA] = [
            RGBA(0.62, 0.68, 0.76), RGBA(0.74, 0.62, 0.52), RGBA(0.56, 0.70, 0.58),
            RGBA(0.70, 0.60, 0.74), RGBA(0.78, 0.74, 0.52), RGBA(0.52, 0.70, 0.74),
        ]
        return palette[i % palette.count]
    }
}

public enum RenderStyle: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case shadedWithEdges = "shaded_with_edges"
    case shaded
    case wireframe
    case hiddenLinesRemoved = "hidden_lines_removed"
}

/// One drawable: a tessellated body with display attributes. `objectID` is what picking
/// returns for this item (e.g. the body's index in the scene).
public struct RenderItem: Sendable {
    public var objectID: UInt32
    public var mesh: Mesh
    public var color: RGBA
    /// Face indices drawn with the highlight color.
    public var highlightedFaces: Set<UInt32>
    public var highlightedEdges: Set<UInt32>
    public var highlightAll: Bool
    /// Per-edge colours (e.g. sketch curves by constraint state); default is RGBA.edge.
    public var edgeColors: [UInt32: RGBA]

    public init(
        objectID: UInt32, mesh: Mesh, color: RGBA, highlightedFaces: Set<UInt32> = [], highlightedEdges: Set<UInt32> = [],
        highlightAll: Bool = false, edgeColors: [UInt32: RGBA] = [:]
    ) {
        self.edgeColors = edgeColors
        self.objectID = objectID
        self.mesh = mesh
        self.color = color
        self.highlightedFaces = highlightedFaces
        self.highlightedEdges = highlightedEdges
        self.highlightAll = highlightAll
    }
}

public struct RenderScene: Sendable {
    public var items: [RenderItem]

    public init(items: [RenderItem]) { self.items = items }

    public var bounds: BoundingBox? {
        items.compactMap(\.mesh.bounds).reduce(nil) { acc, b in acc.map { $0.union(b) } ?? b }
    }
}

/// What a pixel shows, for picking.
public struct PickHit: Sendable, Hashable, Codable {
    public enum Element: String, Sendable, Codable { case face, edge }
    public var objectID: UInt32
    public var element: Element
    public var index: UInt32
    /// World-space point (for faces: ray hit; for edges: nearest polyline point).
    public var point: Vec3?
}
