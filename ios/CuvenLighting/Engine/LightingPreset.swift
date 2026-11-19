import Foundation

/// The three selectable looks of the control surface (Cinematic Reflection Mode).
///
/// · standard   — the plain dark material. No video analysis at all (the GPU only redraws when a card is pressed or
///                the layout changes), no motion sensors.
/// · cinematic  — the recommended default. Video-derived ambient light, a restrained mirror reflection, soft
///                directional highlights from up to two light sources, a faint spill on the panel behind the cards.
/// · immersive  — more analysis detail (larger samples, a finer projection grid, four light sources), stronger
///                localized reflections, two-layer highlights, Fresnel edge light and full spatial response.
///                Still capped for readability: the white symbols never lose contrast.
public enum LightingPreset: String, CaseIterable, Sendable, Codable {
    case standard
    case cinematic
    case immersive

    /// Video-derived lighting runs at all
    public var usesVideoLight: Bool { self != .standard }
}
