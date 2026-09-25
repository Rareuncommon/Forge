import ForgeRender

/// Viewport colours shared by the front ends (the renderers take plain RGBA).
package enum Palette {
    /// Sketch colours for the current appearance: fully / under / over defined, points, preview.
    package static func sketch(dark: Bool) -> (fully: RGBA, under: RGBA, over: RGBA, point: RGBA, preview: RGBA) {
        dark
            ? (RGBA(0.95, 0.95, 0.96), RGBA(0.37, 0.61, 1.0), RGBA(1.0, 0.42, 0.36), RGBA(0.85, 0.86, 0.88), RGBA(1.0, 0.70, 0.24))
            : (RGBA(0.11, 0.11, 0.12), RGBA(0.12, 0.37, 0.84), RGBA(0.78, 0.18, 0.13), RGBA(0.10, 0.10, 0.12), RGBA(0.85, 0.51, 0.0))
    }
}
