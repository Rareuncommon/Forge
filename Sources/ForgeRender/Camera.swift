import ForgeCore
import Foundation

/// Standard view orientations. World is Y-up like SolidWorks: Front looks down -Z onto the
/// XY plane, Top looks down -Y onto XZ, Right looks down -X onto YZ.
public enum ViewOrientation: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case front, back, left, right, top, bottom, isometric, dimetric, trimetric

    /// (direction from target to eye, up vector)
    public var basis: (toEye: Vec3, up: Vec3) {
        switch self {
        case .front: (.unitZ, .unitY)
        case .back: (-.unitZ, .unitY)
        case .right: (.unitX, .unitY)
        case .left: (-.unitX, .unitY)
        case .top: (.unitY, -.unitZ)
        case .bottom: (-.unitY, .unitZ)
        case .isometric: (Vec3(1, 1, 1).normalized, .unitY)
        case .dimetric: (Vec3(0.9354, 0.3536, 1).normalized, .unitY)
        case .trimetric: (Vec3(0.6, 0.45, 1).normalized, .unitY)
        }
    }
}

public enum ProjectionKind: String, Codable, Sendable, CaseIterable, SchemaEnum {
    case orthographic, perspective
}

/// A CAD camera: orbit about a target, pan in the view plane, zoom toward a point.
/// Orientation is a quaternion so free (SolidWorks-style) rotation never gimbal-locks.
public struct Camera: Sendable, Hashable {
    public var target: Vec3
    /// Distance from eye to target.
    public var distance: Double
    public var orientation: Quat
    public var projection: ProjectionKind
    public var fovY: Double
    /// Half the visible height at the target plane (orthographic zoom).
    public var orthoHalfHeight: Double

    public init(
        target: Vec3 = .zero, distance: Double = 100, orientation: Quat = .identity, projection: ProjectionKind = .orthographic,
        fovY: Double = 35 * .pi / 180, orthoHalfHeight: Double = 50
    ) {
        self.target = target
        self.distance = distance
        self.orientation = orientation
        self.projection = projection
        self.fovY = fovY
        self.orthoHalfHeight = orthoHalfHeight
    }

    public var right: Vec3 { orientation.rotate(.unitX) }
    public var up: Vec3 { orientation.rotate(.unitY) }
    /// Unit vector from target toward the eye.
    public var back: Vec3 { orientation.rotate(.unitZ) }
    public var eye: Vec3 { target + back * distance }

    public mutating func setOrientation(_ view: ViewOrientation) {
        let (toEye, up0) = view.basis
        let back = toEye.normalized
        let right = up0.cross(back).normalized
        let up = back.cross(right)
        orientation = Quat.fromBasis(right: right, up: up, back: back)
    }

    /// Look along -back with the given up direction (normal to a sketch plane: back = its
    /// normal, up = its y axis).
    public mutating func setBasis(back b: Vec3, up u: Vec3) {
        let back = b.normalized
        let right = u.cross(back).normalized
        let up = back.cross(right)
        orientation = Quat.fromBasis(right: right, up: up, back: back)
    }

    /// Free orbit: horizontal drag rotates about the camera's up, vertical about its right.
    public mutating func orbit(dx: Double, dy: Double) {
        let qy = Quat(axis: up, angle: -dx)
        let qx = Quat(axis: right, angle: -dy)
        orientation = (qx * qy * orientation).normalized
    }

    /// Turntable orbit about world +Y (keeps the model upright).
    public mutating func turntable(dx: Double, dy: Double) {
        let qy = Quat(axis: .unitY, angle: -dx)
        orientation = (qy * orientation).normalized
        let qx = Quat(axis: right, angle: -dy)
        orientation = (qx * orientation).normalized
    }

    /// Pan by a viewport-pixel delta, given the viewport height in pixels.
    public mutating func pan(dxPixels: Double, dyPixels: Double, viewportHeight: Double) {
        let worldPerPixel = 2 * visibleHalfHeight / max(viewportHeight, 1)
        target = target - right * (dxPixels * worldPerPixel) + up * (dyPixels * worldPerPixel)
    }

    /// Zoom by `factor` (> 1 zooms in) keeping `anchor` (a world point under the cursor) fixed.
    public mutating func zoom(factor: Double, anchor: Vec3? = nil) {
        guard factor > 0, factor.isFinite else { return }
        let anchor = anchor ?? target
        switch projection {
        case .orthographic:
            orthoHalfHeight /= factor
        case .perspective:
            distance /= factor
        }
        // Move the target toward the anchor so the anchor stays under the cursor.
        target = anchor + (target - anchor) / factor
    }

    public var visibleHalfHeight: Double {
        projection == .orthographic ? orthoHalfHeight : distance * tan(fovY / 2)
    }

    /// Frame the bounds with a margin.
    public mutating func fit(_ bounds: BoundingBox, margin: Double = 1.1, aspect: Double = 1) {
        target = bounds.center
        let radius = max(bounds.diagonal / 2, 1e-6)
        let halfH = radius * margin / min(aspect, 1)
        orthoHalfHeight = halfH
        distance = projection == .perspective ? halfH / tan(fovY / 2) + radius : radius * 4
    }

    public var viewMatrix: Mat4 { Mat4.lookAt(eye: eye, target: target, up: up) }

    /// Near/far planes chosen to contain a sphere of `sceneRadius` around the target.
    public func projectionMatrix(aspect: Double, sceneRadius: Double) -> Mat4 {
        let r = max(sceneRadius, 1e-6)
        switch projection {
        case .orthographic:
            let near = distance - r * 1.5, far = distance + r * 1.5
            return .orthographic(halfWidth: orthoHalfHeight * aspect, halfHeight: orthoHalfHeight, near: near, far: far)
        case .perspective:
            let near = max(distance - r * 1.5, r * 0.01), far = distance + r * 1.5
            return .perspective(fovY: fovY, aspect: aspect, near: near, far: far)
        }
    }

    /// View position (origin top-left, y down) of a world point: the inverse of `ray`. Nil
    /// for a point behind a perspective camera.
    public func project(_ p: Vec3, width: Double, height: Double) -> (x: Double, y: Double)? {
        guard width > 0, height > 0 else { return nil }
        let aspect = width / height
        let rel = p - eye
        let x = rel.dot(right), y = rel.dot(up)
        let ndcX: Double, ndcY: Double
        switch projection {
        case .orthographic:
            ndcX = x / (orthoHalfHeight * aspect)
            ndcY = y / orthoHalfHeight
        case .perspective:
            let depth = -rel.dot(back)
            guard depth > 1e-9 else { return nil }
            let t = tan(fovY / 2)
            ndcX = x / (depth * t * aspect)
            ndcY = y / (depth * t)
        }
        return ((ndcX + 1) / 2 * width, (1 - ndcY) / 2 * height)
    }

    /// World-space ray through a pixel (origin top-left, y down).
    public func ray(pixelX: Double, pixelY: Double, width: Double, height: Double) -> (origin: Vec3, direction: Vec3) {
        let aspect = width / height
        let ndcX = (pixelX / width) * 2 - 1
        let ndcY = 1 - (pixelY / height) * 2
        switch projection {
        case .orthographic:
            let origin = eye + right * (ndcX * orthoHalfHeight * aspect) + up * (ndcY * orthoHalfHeight)
            return (origin, -back)
        case .perspective:
            let t = tan(fovY / 2)
            let dir = (-back + right * (ndcX * t * aspect) + up * (ndcY * t)).normalized
            return (eye, dir)
        }
    }
}
