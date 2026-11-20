import Foundation

/// Cinematic Reflection Mode: one of the three presets. This is the only lighting configuration the renderer takes;
/// it resolves to a concrete LightingProfile for the current quality level.
///
/// The tuning is fixed (user decision: "固定参数, 允许调整的只是三种模式"): the values the user had dialled in —
/// reflection intensity, ambient light, specular highlights and edge glow at 150 %, reflection softness at 200 % —
/// with spatial response and adaptive quality always on. Only the preset is stored and can be changed.
public struct CinematicReflectionMode: Sendable, Equatable, Codable {
    public var preset: LightingPreset = .cinematic

    /// Overall strength of the video light (× the preset's design value)
    public static let reflectionIntensity: Float = 1.5
    /// Diffuse light and the spill on the panel
    public static let ambientLight: Float = 1.5
    /// Highlights of the tracked light sources
    public static let specularHighlight: Float = 1.5
    /// Light along card rims
    public static let edgeGlow: Float = 1.5
    /// Softness of the mirror reflection (× the preset's blur, capped at fully diffused)
    public static let reflectionBlur: Float = 2

    /// Device attitude (and a hinge reading when there is one) moves the reflections
    public var spatialResponse: Bool { true }
    /// Lower the analysis detail and rate on heat, Low Power Mode, low battery, older GPUs, heavy sources
    public var adaptiveLighting: Bool { true }

    public init() {}

    public init(preset: LightingPreset) {
        self.preset = preset
    }

    /// The concrete numbers for this frame
    public func profile(quality: LightingQuality) -> LightingProfile {
        var p = LightingProfile.base(for: preset).adapted(to: quality)
        p.intensity *= Self.reflectionIntensity
        p.ambient *= Self.ambientLight
        p.backdrop *= Self.ambientLight
        p.specular *= Self.specularHighlight
        p.edgeGlow *= Self.edgeGlow
        p.blur = min(max(p.blur * Self.reflectionBlur, 0), 1)
        return p
    }
}
