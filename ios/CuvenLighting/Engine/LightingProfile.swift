import Foundation

/// Every number the pipeline runs with for one frame: derived from the preset, the user's tuning, the adaptive
/// quality level and whether the controls are idle. The renderer eases its look toward a new profile over ~0.6 s,
/// so switching presets during playback is a gradual cross-fade rather than a jump.
public struct LightingProfile: Sendable, Equatable {
    // Analysis
    /// Video frames are analysed at all
    public var analysisEnabled: Bool
    /// Analysis updates per second while the controls are shown / while idle
    public var analysisHz: Int
    public var idleAnalysisHz: Int
    /// Size the video output delivers frames at (the decoder's scaler does the work)
    public var sampleWidth: Int
    public var sampleHeight: Int
    /// Area-light grid used for the irradiance projection
    public var gridColumns: Int
    public var gridRows: Int
    /// Tracked light sources used for highlights (0…4)
    public var lightCount: Int

    // Look (linear multipliers; 1 = the preset's design value)
    public var intensity: Float
    public var ambient: Float
    public var mirror: Float
    public var specular: Float
    public var edgeGlow: Float
    /// 0 = sharp reflections, 1 = fully diffused
    public var blur: Float
    /// Second, broader highlight lobe (0…1)
    public var multiLayer: Float
    /// Light spilling onto the black panel between the cards (never a uniform glow: it follows the irradiance)
    public var backdrop: Float
    /// How far device attitude moves the reflections (0…1)
    public var spatial: Float
    /// Highest linear luminance light may push a dark card to (white symbols stay ≥ 4.5 : 1)
    public var readabilityCap: Float

    // Pacing
    public var displayFPS: Int
    public var idleDisplayFPS: Int

    public static func base(for preset: LightingPreset) -> LightingProfile {
        switch preset {
        case .standard:
            return LightingProfile(analysisEnabled: false, analysisHz: 0, idleAnalysisHz: 0,
                                   sampleWidth: 256, sampleHeight: 144, gridColumns: 16, gridRows: 9, lightCount: 0,
                                   intensity: 0, ambient: 0, mirror: 0, specular: 0, edgeGlow: 0, blur: 0.5,
                                   multiLayer: 0, backdrop: 0, spatial: 0, readabilityCap: 0.12,
                                   displayFPS: 60, idleDisplayFPS: 30)
        case .cinematic:
            return LightingProfile(analysisEnabled: true, analysisHz: 24, idleAnalysisHz: 12,
                                   sampleWidth: 256, sampleHeight: 144, gridColumns: 16, gridRows: 9, lightCount: 2,
                                   intensity: 0.9, ambient: 1.0, mirror: 0.45, specular: 0.65, edgeGlow: 0.8, blur: 0.6,
                                   multiLayer: 0, backdrop: 0.3, spatial: 0.5, readabilityCap: 0.12,
                                   displayFPS: 60, idleDisplayFPS: 30)
        case .immersive:
            return LightingProfile(analysisEnabled: true, analysisHz: 30, idleAnalysisHz: 15,
                                   sampleWidth: 384, sampleHeight: 216, gridColumns: 32, gridRows: 18, lightCount: 4,
                                   intensity: 1.0, ambient: 1.15, mirror: 0.75, specular: 1.0, edgeGlow: 1.0, blur: 0.35,
                                   multiLayer: 1, backdrop: 0.5, spatial: 1.0, readabilityCap: 0.13,
                                   displayFPS: 60, idleDisplayFPS: 30)
        }
    }

    /// Scale the analysis down for the adaptive quality level; the look stays (only finer detail goes)
    public func adapted(to quality: LightingQuality) -> LightingProfile {
        var p = self
        switch quality {
        case .high:
            break
        case .reduced:
            p.analysisHz = max(analysisHz / 2, analysisEnabled ? 10 : 0)
            p.idleAnalysisHz = max(idleAnalysisHz / 2, analysisEnabled ? 6 : 0)
            p.sampleWidth = min(sampleWidth, 256)
            p.sampleHeight = min(sampleHeight, 144)
            p.gridColumns = min(gridColumns, 16)
            p.gridRows = min(gridRows, 9)
            p.multiLayer = 0
            p.displayFPS = 30
        case .minimal, .suspended:
            // Frozen on the last analysed frame: the light stays, nothing new is computed
            p.analysisHz = 0
            p.idleAnalysisHz = 0
            p.multiLayer = 0
            p.displayFPS = 30
            p.idleDisplayFPS = 20
        }
        return p
    }
}
