import CoreGraphics
import Foundation
import simd

// MARK: - Public value types (Sendable, no UIKit / SwiftUI)

/// One control card the renderer paints, in the lighting surface view's points
public struct LightingCard: Sendable, Equatable {
    public var id: String
    public var frame: CGRect
    public var cornerRadius: CGFloat
    /// 0…1: how strongly this card reflects (the play button is the most prominent surface)
    public var emphasis: Float
    /// A white "on" surface (the screen lock while it is engaged)
    public var isLit: Bool

    public init(id: String, frame: CGRect, cornerRadius: CGFloat = 19, emphasis: Float = 0.5, isLit: Bool = false) {
        self.id = id
        self.frame = frame
        self.cornerRadius = cornerRadius
        self.emphasis = emphasis
        self.isLit = isLit
    }
}

/// Where the picture sits relative to the panel, all in the surface view's points
public struct LightingGeometry: Sendable, Equatable {
    /// The area the picture is laid out in (aspect-fit happens inside it). Usually outside the surface view:
    /// above it (video on top) or beside it (video on the leading side).
    public var videoContainer: CGRect
    /// A point on the hinge line
    public var hingePoint: CGPoint
    /// Unit vector from the hinge toward the panel: (0, 1) when the video is above, (1, 0) when it is on the left
    public var awayFromHinge: CGVector
    /// Fold angle the layout implies when no hardware reading or simulation is active (180° = flat)
    public var layoutFoldDegrees: Double

    public init(videoContainer: CGRect, hingePoint: CGPoint, awayFromHinge: CGVector = CGVector(dx: 0, dy: 1),
                layoutFoldDegrees: Double = 180) {
        self.videoContainer = videoContainer
        self.hingePoint = hingePoint
        self.awayFromHinge = awayFromHinge
        self.layoutFoldDegrees = layoutFoldDegrees
    }
}

public enum LightingQuality: String, Sendable {
    /// 30 Hz lighting, 60 Hz composite, 32 × 18 projection grid
    case high
    /// 15 Hz lighting, 30 Hz composite, 16 × 9 grid (thermal "serious" or Low Power Mode)
    case reduced
    /// Lighting frozen on the last frame, 30 Hz composite (thermal "critical")
    case minimal
    /// App in the background: nothing is encoded
    case suspended
}

public struct LightingDiagnostics: Sendable, Equatable {
    public var displayFPS: Double = 0
    public var lightingFPS: Double = 0
    public var gpuMilliseconds: Double = 0
    public var cpuMilliseconds: Double = 0
    public var skippedFrames: Int = 0
    public var textureBytes: Int = 0
    public var quality: LightingQuality = .high
    public var thermalState: ProcessInfo.ThermalState = .nominal
    public var hasVideo = false
    public var foldDegrees: Double = 180
    public var shaderError: String?
    /// Cinematic Reflection Mode
    public var preset: LightingPreset = .cinematic
    public var adaptation: LightingAdaptation = .none
    /// Target analysis rate right now (after idle / adaptive)
    public var targetAnalysisHz: Int = 0
    /// Controls hidden: lower rates, ambient light kept
    public var idle = false
    /// Device tilt against the resting posture (screen axes, −1…1) and the resulting light factor
    public var tilt: SIMD2<Float> = .zero
    public var spatialIntensity: Float = 1
    /// Effective look after easing (what the shaders get this frame)
    public var effectiveIntensity: Float = 0
    public var effectiveSpecular: Float = 0
    public var lightingMix: Float = 0
    public var gpuTier = 0

    public init() {}
}

public struct SampledLight: Sendable, Equatable {
    /// Position in the picture, 0…1
    public var position: SIMD2<Float>
    public var radius: Float
    public var intensity: Float
    /// Chroma, max component 1
    public var color: SIMD3<Float>
    public var presence: Float
}

/// What the analysis saw, read back a few times a second for the lab's colour visualisation
public struct SampledPalette: Sendable, Equatable {
    /// 16 × 9 cells, row-major: linear rgb + luminance
    public var cells: [SIMD4<Float>]
    public var average: SIMD4<Float>
    public var sceneChange: Float
    public var lights: [SampledLight]

    public static let columns = 16
    public static let rows = 9
}

// MARK: - GPU mirrors of LightingShaderTypes.h (16-byte vectors only: identical layout)

struct GPUFrameUniforms {
    var viewport = SIMD4<Float>.zero
    var panel = SIMD4<Float>.zero
    var videoRect = SIMD4<Float>.zero
    var hinge = SIMD4<Float>.zero
    var axes = SIMD4<Float>.zero
    var eye = SIMD4<Float>.zero
    var material = SIMD4<Float>.zero
    var analysis = SIMD4<Float>.zero
    var look = SIMD4<Float>.zero
    var look2 = SIMD4<Float>.zero
}

struct GPUCardInstance {
    var rect = SIMD4<Float>.zero
    var shape = SIMD4<Float>.zero
    var tint = SIMD4<Float>.zero
}

enum GPULayout {
    static let lightmapWidth = 64
    static let lightmapHeight = 36
    static let cellCount = 144
    static let maxLights = 4
    static let maxCards = 32
    /// CuvenSceneState: average + stats + 4 × (position + color) = 10 vectors
    static let sceneStateBytes = MemoryLayout<SIMD4<Float>>.stride * 10
    /// cells[0…143] this frame, cells[144…287] previous frame
    static let cellsBytes = MemoryLayout<SIMD4<Float>>.stride * 288

    static func check() {
        assert(MemoryLayout<GPUFrameUniforms>.stride == 160, "CuvenFrameUniforms layout drifted")
        assert(MemoryLayout<GPUCardInstance>.stride == 48, "CuvenCardInstance layout drifted")
    }
}

/// Carries a value the compiler cannot prove Sendable (a CVMetalTexture, an MTLBuffer) into a Metal completion
/// handler. Only used for values that are not touched again until the GPU has finished with them.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
