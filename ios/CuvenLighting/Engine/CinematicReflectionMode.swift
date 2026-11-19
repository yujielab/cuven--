import Foundation

/// Cinematic Reflection Mode: the preset plus the viewer's tuning. This is the only lighting configuration the
/// renderer takes; it resolves to a concrete LightingProfile for the current quality level.
public struct CinematicReflectionMode: Sendable, Equatable, Codable {
    public var preset: LightingPreset = .cinematic
    /// Overall strength of the video light (0…1.5; 1 = the preset's design value)
    public var reflectionIntensity: Float = 1
    /// Diffuse light and the spill on the panel (0…1.5)
    public var ambientLight: Float = 1
    /// Highlights of the tracked light sources (0…1.5)
    public var specularHighlight: Float = 1
    /// Light along the card rims (0…1.5)
    public var edgeGlow: Float = 1
    /// Softness of the mirror reflection (0…2 × the preset's blur)
    public var reflectionBlur: Float = 1
    /// Device attitude (and a hinge reading when there is one) moves the reflections
    public var spatialResponse = true
    /// Lower the analysis detail and rate on heat, Low Power Mode, low battery, older GPUs, heavy sources
    public var adaptiveLighting = true

    public init() {}

    public init(preset: LightingPreset) {
        self.preset = preset
    }

    /// The concrete numbers for this frame
    public func profile(quality: LightingQuality) -> LightingProfile {
        var p = LightingProfile.base(for: preset).adapted(to: quality)
        p.intensity *= clamp(reflectionIntensity, 0, 1.5)
        p.ambient *= clamp(ambientLight, 0, 1.5)
        p.backdrop *= clamp(ambientLight, 0, 1.5)
        p.specular *= clamp(specularHighlight, 0, 1.5)
        p.edgeGlow *= clamp(edgeGlow, 0, 1.5)
        p.blur = clamp(p.blur * clamp(reflectionBlur, 0, 2), 0, 1)
        if !spatialResponse { p.spatial = 0 }
        return p
    }

    private func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }
}
