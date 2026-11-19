import AVFoundation
import CoreGraphics
import Foundation
import Metal
import simd

/// The lighting model: turns the analysed video, the spatial state and the Cinematic Reflection Mode into what the
/// surfaces need — the per-frame uniforms and a quarter-resolution irradiance texture of the panel.
///
/// Presets do not switch pipelines: one pipeline runs with the numbers of a LightingProfile, and the look the
/// shaders receive is eased toward the current profile (τ ≈ 0.22 s, so a switch settles in ~0.6 s). Standard
/// fades the video light out and then stops analysing altogether.
/// Independent of any view: driven by MetalRenderer, owns no UI, talks in points and textures.
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

    var mode = CinematicReflectionMode()
    var geometry = LightingGeometry(videoContainer: .zero, hingePoint: .zero)
    /// Controls hidden: lower analysis rate, highlights quieter, ambient light kept
    var idle = false
    private(set) var profile = LightingProfile.base(for: .cinematic)

    /// Eased look (what the shaders get)
    private(set) var lightingMix: Float = 0
    private(set) var look = SIMD4<Float>.zero        // ambient, specular, edge, blur
    private(set) var look2 = SIMD4<Float>.zero       // layers, backdrop, idle, light count
    private(set) var intensity: Float = 0
    private(set) var mirror: Float = 0
    private(set) var spatialAmount: Float = 0
    private var lastAnalysis: CFTimeInterval = 0
    private var projectedSignature: [Float] = []
    private var sourceGeneration = -1

    init?(shaders: MetalShaderLibrary, pool: TexturePool) {
        guard let analysis = ColorAnalysisEngine(shaders: shaders, pool: pool) else { return nil }
        self.shaders = shaders
        self.pool = pool
        self.analysis = analysis
        self.frames = VideoFrameProcessor(textureCache: shaders.textureCache, device: shaders.device)
        self.spatial = SpatialResponseEngine()
    }

    /// The picture's aspect-fit rect inside the container (letterbox bars do not emit light)
    var pictureRect: CGRect {
        let container = geometry.videoContainer
        let size = frames.presentationSize
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else { return container }
        return AVMakeRect(aspectRatio: size, insideRect: container)
    }

    /// Resolve the profile for this frame's quality level
    func resolve(quality: LightingQuality) {
        profile = mode.profile(quality: quality)
        frames.setSampleSize(width: profile.sampleWidth, height: profile.sampleHeight)
    }

    var wantsMotion: Bool { profile.spatial > 0.001 }

    /// Still moving toward the profile
    private(set) var isEasing = true

    /// Ease the look toward the profile
    func step(dt: Double) {
        let k = Float(1 - exp(-dt / 0.22))
        let kMix = Float(1 - exp(-dt / 0.16))
        let p = profile
        let mixTarget: Float = p.analysisEnabled && analysis.hasData ? 1 : 0
        let lookTarget = SIMD4<Float>(p.ambient, p.specular, p.edgeGlow, p.blur)
        let look2Target = SIMD4<Float>(p.multiLayer, p.backdrop, idle ? 1 : 0, Float(p.lightCount))
        var moving = false
        func ease(_ v: inout Float, _ t: Float, _ k: Float) {
            v += (t - v) * k
            if abs(t - v) < 0.002 { v = t } else { moving = true }
        }
        func ease4(_ v: inout SIMD4<Float>, _ t: SIMD4<Float>) {
            v += (t - v) * k
            if simd_reduce_max(simd_abs(t - v)) < 0.002 { v = t } else { moving = true }
        }
        ease(&lightingMix, mixTarget, kMix)
        ease(&intensity, p.intensity, k)
        ease(&mirror, p.mirror, k)
        ease(&spatialAmount, p.spatial, k)
        ease4(&look, lookTarget)
        // Light count steps immediately (slots fade on their own); the rest eases
        var l2 = look2
        l2.w = look2Target.w
        ease4(&l2, look2Target)
        look2 = l2
        isEasing = moving
    }

    func uniforms(viewSize: CGSize, scale: CGFloat, time: CFTimeInterval, dt: Double, cardCount: Int) -> GPUFrameUniforms {
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
        let tilt = s.tilt * spatialAmount
        let eye = SIMD4<Float>(centerAlong + tilt.x * 260,
                               max(farEdge, 1) + 520 - tilt.y * 160,
                               620 + tilt.y * 220,
                               0)

        var u = GPUFrameUniforms()
        u.viewport = SIMD4(Float(viewSize.width * scale), Float(viewSize.height * scale), Float(scale),
                           Float(time.truncatingRemainder(dividingBy: 3600)))
        u.panel = SIMD4(Float(viewSize.width), Float(viewSize.height), irradianceScale, Float(cardCount))
        u.videoRect = SIMD4(Float(picture.minX), Float(picture.minY), Float(picture.width), Float(picture.height))
        // Spill: light that leaks over the bezel keeps an unfolded (flat) layout faintly lit
        u.hinge = SIMD4(hinge.x, hinge.y, s.foldRadians, 46)
        u.axes = SIMD4(along.x, along.y, away.x, away.y)
        u.eye = eye
        let spatialIntensity = 1 + (s.intensity - 1) * spatialAmount
        u.material = SIMD4(intensity * spatialIntensity, lightingMix, mirror, profile.readabilityCap)
        u.analysis = SIMD4(Float(dt), Float(profile.gridColumns), Float(profile.gridRows), 3.2)
        u.look = look
        u.look2 = look2
        return u
    }

    /// Analysis updates per second right now
    var targetAnalysisHz: Int { idle ? profile.idleAnalysisHz : profile.analysisHz }

    /// Is a new analysis due now?
    func analysisDue(now: CFTimeInterval) -> Bool {
        let hz = targetAnalysisHz
        guard profile.analysisEnabled, hz > 0 else { return false }
        return now - lastAnalysis >= 1.0 / Double(hz) - 0.002
    }

    /// Pull a frame (or the still) and encode the analysis; returns what to keep alive until the GPU is done
    func encodeAnalysis(now: CFTimeInterval, commandBuffer: any MTLCommandBuffer, uniforms: GPUFrameUniforms) -> AnyObject? {
        syncSource()
        guard let frame = frames.nextFrame(hostTime: now) else { return nil }
        var u = uniforms
        u.analysis.x = Float(min(max(now - lastAnalysis, 1.0 / 120), 0.25))
        lastAnalysis = now
        analysis.encode(frame: frame.texture, into: commandBuffer, uniforms: u)
        return frame.holder
    }

    /// Follow the player's current item (a new source fades its light in from black)
    func syncSource() {
        if frames.syncItem() || frames.sourceGeneration != sourceGeneration {
            sourceGeneration = frames.sourceGeneration
            analysis.reset()
        }
    }

    /// Re-project the irradiance when the light map, the layout or the fold changed
    func encodeProjection(commandBuffer: any MTLCommandBuffer, uniforms: GPUFrameUniforms, viewSize: CGSize, force: Bool) {
        guard analysis.hasData, lightingMix > 0.0005, let pipeline = shaders.projectIrradiance,
              let near = analysis.near, let far = analysis.far else { return }
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
        encoder.setTexture(far, index: 2)
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
