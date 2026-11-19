import AVFoundation
import CoreGraphics
import Foundation
import Metal
import simd

/// The lighting model: turns the analysed video and the spatial state into what the surfaces need —
/// the per-frame uniforms and a quarter-resolution irradiance texture of the panel.
///
/// Independent of any view: it is driven by MetalRenderer, owns no UI, and talks in points and textures.
@MainActor
final class DynamicLightingEngine {
    private let shaders: MetalShaderLibrary
    private let pool: TexturePool
    let analysis: ColorAnalysisEngine
    let frames: VideoFrameProcessor
    let spatial: SpatialResponseEngine
    private(set) var irradiance: (any MTLTexture)?
    private var irradianceSize = (0, 0)
    /// Quarter resolution of the panel, in texels per point
    let irradianceScale: Float = 0.25

    var settings = LightingSettings()
    var geometry = LightingGeometry(videoContainer: .zero, hingePoint: .zero)
    /// Lighting on/off cross-fade, 0…1 (≈ 0.4 s)
    private(set) var lightingMix: Float = 0
    private var lastAnalysis: CFTimeInterval = 0
    private var projectedSignature: [Float] = []
    private var sourceGeneration = -1

    init?(shaders: MetalShaderLibrary, pool: TexturePool) {
        guard let analysis = ColorAnalysisEngine(shaders: shaders, pool: pool) else { return nil }
        self.shaders = shaders
        self.pool = pool
        self.analysis = analysis
        self.frames = VideoFrameProcessor(textureCache: shaders.textureCache)
        self.spatial = SpatialResponseEngine()
    }

    /// The picture's aspect-fit rect inside the container (letterbox bars do not emit light)
    var pictureRect: CGRect {
        let container = geometry.videoContainer
        let size = frames.presentationSize
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return container }
        return AVMakeRect(aspectRatio: size, insideRect: container)
    }

    func uniforms(viewSize: CGSize, scale: CGFloat, time: CFTimeInterval, dt: Double,
                  quality: LightingQuality, cardCount: Int) -> GPUFrameUniforms {
        let s = spatial.state
        let picture = pictureRect
        var away = SIMD2<Float>(Float(geometry.awayFromHinge.dx), Float(geometry.awayFromHinge.dy))
        if simd_length(away) < 0.01 { away = SIMD2(0, 1) }
        away = simd_normalize(away)
        let along = SIMD2<Float>(away.y, -away.x)
        let hinge = SIMD2<Float>(Float(geometry.hingePoint.x), Float(geometry.hingePoint.y))

        // The viewer sits in front of the panel, above it, centred on the panel; tilting the device moves the eye
        let size = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        let center = size * 0.5
        let centerAlong = simd_dot(center - hinge, along)
        // Distance from the hinge to the far edge of the panel (the edge nearest the viewer)
        let corners = [SIMD2<Float>(0, 0), SIMD2<Float>(size.x, 0), SIMD2<Float>(0, size.y), size]
        let farEdge = corners.map { simd_dot($0 - hinge, away) }.max() ?? size.y
        let tilt = settings.spatialResponse ? s.tilt : .zero
        let eye = SIMD4<Float>(centerAlong + tilt.x * 260,
                               max(farEdge, 1) + 520 - tilt.y * 160,
                               620 + tilt.y * 220,
                               0)

        let grid: SIMD2<Float> = quality == .high ? SIMD2(32, 18) : SIMD2(16, 9)
        var u = GPUFrameUniforms()
        u.viewport = SIMD4(Float(viewSize.width * scale), Float(viewSize.height * scale), Float(scale),
                           Float(time.truncatingRemainder(dividingBy: 3600)))
        u.panel = SIMD4(Float(viewSize.width), Float(viewSize.height), irradianceScale, Float(cardCount))
        u.videoRect = SIMD4(Float(picture.minX), Float(picture.minY), Float(picture.width), Float(picture.height))
        // Spill: light that leaks over the bezel keeps an unfolded (flat) layout faintly lit
        u.hinge = SIMD4(hinge.x, hinge.y, s.foldRadians, 46)
        u.axes = SIMD4(along.x, along.y, away.x, away.y)
        u.eye = eye
        let intensity = settings.intensity * (settings.spatialResponse ? s.intensity : 1)
        u.material = SIMD4(intensity, lightingMix, settings.reflectivity, settings.readabilityCap)
        u.analysis = SIMD4(Float(dt), grid.x, grid.y, 3.2)
        return u
    }

    /// Ease the on/off mix
    func step(dt: Double) {
        let target: Float = settings.isEnabled && analysis.hasData ? 1 : 0
        let k = Float(1 - exp(-dt / 0.14))
        lightingMix += (target - lightingMix) * k
        if abs(target - lightingMix) < 0.002 { lightingMix = target }
    }

    /// Is a new analysis due now?
    func analysisDue(now: CFTimeInterval, quality: LightingQuality) -> Bool {
        guard settings.isEnabled, quality == .high || quality == .reduced else { return false }
        let hz = quality == .high ? max(settings.lightingFPS, 1) : max(settings.lightingFPS / 2, 1)
        return now - lastAnalysis >= 1.0 / Double(hz) - 0.002
    }

    /// Pull a frame and encode the analysis; returns the CVMetalTexture to keep alive until the GPU is done
    func encodeAnalysis(now: CFTimeInterval, commandBuffer: any MTLCommandBuffer, uniforms: GPUFrameUniforms) -> CVMetalTexture? {
        if frames.syncItem() || frames.sourceGeneration != sourceGeneration {
            sourceGeneration = frames.sourceGeneration
            analysis.reset()
        }
        guard let frame = frames.nextFrame(hostTime: now) else { return nil }
        var u = uniforms
        u.analysis.x = Float(min(max(now - lastAnalysis, 1.0 / 120), 0.25))
        lastAnalysis = now
        analysis.encode(frame: frame.texture, into: commandBuffer, uniforms: u)
        return frame.holder
    }

    /// Re-project the irradiance when the light map, the layout or the fold changed
    func encodeProjection(commandBuffer: any MTLCommandBuffer, uniforms: GPUFrameUniforms, viewSize: CGSize, force: Bool) {
        guard analysis.hasData, let pipeline = shaders.projectIrradiance, let near = analysis.near else { return }
        let w = max(Int((Float(viewSize.width) * irradianceScale).rounded(.up)), 1)
        let h = max(Int((Float(viewSize.height) * irradianceScale).rounded(.up)), 1)
        if irradiance == nil || irradianceSize != (w, h) {
            pool.recycle(irradiance)
            irradiance = pool.make(width: w, height: h, format: MetalShaderLibrary.offscreenFormat,
                                   usage: [.shaderRead, .shaderWrite], label: "panel irradiance")
            irradianceSize = (w, h)
        }
        guard let irradiance else { return }
        let signature = [uniforms.videoRect.x, uniforms.videoRect.y, uniforms.videoRect.z, uniforms.videoRect.w,
                         uniforms.hinge.x, uniforms.hinge.y, uniforms.hinge.z, uniforms.analysis.y, Float(w), Float(h)]
        guard force || signature != projectedSignature else { return }
        projectedSignature = signature
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "irradiance projection"
        var u = uniforms
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(near, index: 0)
        encoder.setTexture(irradiance, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<GPUFrameUniforms>.stride, index: 0)
        dispatch(encoder, pipeline, grid: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
    }

    func release() {
        frames.detach()
        frames.flush()
        analysis.release()
        pool.recycle(irradiance)
        irradiance = nil
        projectedSignature = []
    }
}
