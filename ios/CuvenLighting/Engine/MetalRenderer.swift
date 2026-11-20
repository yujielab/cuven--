import AVFoundation
import Foundation
import Metal
import MetalKit
import QuartzCore
import UIKit
import os

/// The render loop of the reflective control surfaces (Cinematic Reflection Mode).
///
/// Owns the lighting engine, the adaptive quality controller, the three passes (surfaces → highlights → composite)
/// and the MTKView they draw into. The host (SwiftUI, through a UIViewRepresentable) only hands over the player,
/// the layout geometry, the cards, the mode and the idle state; nothing here updates SwiftUI state per frame —
/// diagnostics and the sampled palette are delivered through callbacks a few times a second.
///
/// Per display frame (60 Hz; 30 Hz when idle, warm, in Low Power Mode or on battery saver):
///   · resolve the profile (preset × tuning × adaptive quality × idle), ease the look toward it;
///   · when an analysis is due (Cinematic 24 Hz, Immersive 30 Hz; half of that idle or reduced; never in Standard
///     or when the device is critically hot): pull a new video frame if there is one and encode the analysis,
///     then re-project the irradiance (also when the layout or the fold angle changed);
///   · draw the backdrop and the cards, the highlights, composite into the drawable.
///   Frames where nothing changed (paused video, no animation, Standard at rest) are skipped entirely.
/// At most three frames are in flight; if the GPU falls behind, the frame is skipped rather than blocking the main
/// thread — the video itself is never waited on. Everything stops in the background (no GPU work is allowed there).
@MainActor
public final class MetalRenderer: NSObject {
    public let view: LightingSurfaceView
    public var onDiagnostics: ((LightingDiagnostics) -> Void)?
    /// Called ~4×/s with what the analysis saw (only while set: the read-back costs nothing when nil)
    public var onPalette: ((SampledPalette) -> Void)?

    /// Preset + tuning. Changing it mid-playback cross-fades the look (~0.6 s)
    public var mode: CinematicReflectionMode {
        get { engine.mode }
        set {
            guard newValue != engine.mode else { return }
            engine.mode = newValue
            adaptive.resetClock()
            needsRender = true
        }
    }

    public var player: AVPlayer? {
        get { engine.frames.player }
        set { engine.frames.player = newValue; needsRender = true }
    }

    /// What the host knows about the source's dynamic range (the server's stream info, the file name). HDR and
    /// Dolby Vision items are never tapped — a video output on them changes the picture on screen — and are lit from
    /// the still image instead (VideoFrameProcessor)
    public var sourceRange: LightingSourceRange {
        get { engine.frames.rangeHint }
        set { engine.frames.rangeHint = newValue; needsRender = true }
    }

    /// The title's artwork: what the lighting reads while the video itself cannot be tapped
    public func setStillImage(_ image: CGImage?) {
        engine.frames.setStill(image)
        needsRender = true
    }

    public var geometry: LightingGeometry {
        get { engine.geometry }
        set {
            guard newValue != engine.geometry else { return }
            engine.geometry = newValue
            needsRender = true
        }
    }

    /// Controls hidden: keep the ambient light, quiet the highlights, update at a lower rate
    public var isIdle: Bool {
        get { engine.idle }
        set {
            guard newValue != engine.idle else { return }
            engine.idle = newValue
            needsRender = true
        }
    }

    public var spatial: SpatialResponseEngine { engine.spatial }

    private let shaders: MetalShaderLibrary
    private let pool: TexturePool
    private let engine: DynamicLightingEngine
    private let adaptive: AdaptiveLightingController
    private let surfaces: ReflectiveSurfaceRenderer
    private let highlights: SpecularHighlightRenderer
    private let compositor: LightingCompositor
    private let inflight = DispatchSemaphore(value: 3)
    private let stats = FrameStats()
    private let placeholder: any MTLTexture
    private var surfaceTarget: (any MTLTexture)?
    private var specularTarget: (any MTLTexture)?
    private var targetSize = (0, 0)

    private var isActive = false
    private var isForeground = true
    private var needsRender = true
    private var lastDraw: CFTimeInterval = 0
    private var lastPublish: CFTimeInterval = 0
    private var lastPalette: CFTimeInterval = 0
    private var displayTicks = TickCounter()
    private var lightingTicks = TickCounter()
    private var skipped = 0
    private var cpuMilliseconds: Double = 0
    private var gpuMilliseconds: Double = 0
    private var lastSpatial = SpatialResponseEngine.State()
    private var lastSize = CGSize.zero

    /// nil when Metal or the shader library is unavailable (the host then falls back to plain SwiftUI surfaces)
    public static func make() -> MetalRenderer? {
        guard let shaders = MetalShaderLibrary.shared, shaders.isComplete else { return nil }
        return MetalRenderer(shaders: shaders)
    }

    /// Pipelines that failed to build, for diagnostics
    public static var shaderFailures: [String] { MetalShaderLibrary.shared?.failures ?? ["Metal unavailable"] }

    private init?(shaders: MetalShaderLibrary) {
        let pool = TexturePool(device: shaders.device)
        guard let engine = DynamicLightingEngine(shaders: shaders, pool: pool) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalShaderLibrary.offscreenFormat, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let placeholder = shaders.device.makeTexture(descriptor: d) else { return nil }
        var zero = [UInt16](repeating: 0, count: 4)
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 8)
        self.shaders = shaders
        self.pool = pool
        self.engine = engine
        self.adaptive = AdaptiveLightingController(device: shaders.device)
        self.surfaces = ReflectiveSurfaceRenderer(shaders: shaders)
        self.highlights = SpecularHighlightRenderer(shaders: shaders)
        self.compositor = LightingCompositor(shaders: shaders)
        self.placeholder = placeholder
        self.view = LightingSurfaceView(device: shaders.device)
        super.init()
        view.renderer = self

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }

    // MARK: Cards

    public func setCard(_ card: LightingCard) {
        surfaces.setCard(card)
        needsRender = true
    }

    public func removeCard(id: String) {
        surfaces.removeCard(id: id)
        needsRender = true
    }

    public func setPressed(_ pressed: Bool, id: String) {
        surfaces.setPressed(pressed, id: id)
        needsRender = true
    }

    /// Idle: the cards dim a little while the symbols fade (the ambient reflections stay)
    public func setSurfaceOpacity(_ opacity: Float) {
        surfaces.opacityTarget = min(max(opacity, 0), 1)
        needsRender = true
    }

    /// Release the GPU resources and stop sensors (the host's dismantle)
    public func stop() {
        isActive = false
        view.isPaused = true
        engine.spatial.stop()
        engine.release()
        pool.recycle(surfaceTarget)
        pool.recycle(specularTarget)
        surfaceTarget = nil
        specularTarget = nil
        pool.purge()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Lifecycle

    func windowChanged(inWindow: Bool) {
        isActive = inWindow
        if inWindow {
            view.isPaused = !isForeground
            needsRender = true
        } else {
            engine.spatial.stop()
            view.isPaused = true
        }
    }

    @objc private func didEnterBackground() {
        isForeground = false
        view.isPaused = true
        adaptive.setBackground()
        engine.spatial.stop()
        engine.frames.flush()
        pool.purge()
    }

    @objc private func willEnterForeground() {
        isForeground = true
        adaptive.resetClock()
        if isActive { view.isPaused = false }
        needsRender = true
    }

    @objc private func memoryWarning() {
        engine.frames.flush()
        pool.purge()
    }

    /// Quality level, profile, sensors and display rate for this frame
    private func updatePacing(now: CFTimeInterval) {
        adaptive.update(now: now, foreground: isForeground, mode: engine.mode, gpuMilliseconds: gpuMilliseconds,
                        sourceSize: engine.frames.presentationSize)
        engine.resolve(quality: adaptive.quality)
        let p = engine.profile
        let fps = engine.idle ? p.idleDisplayFPS : p.displayFPS
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }
        // Core Motion only while something uses it (Standard and spatial-off never start the sensors)
        if isActive && isForeground && engine.wantsMotion { engine.spatial.start() } else { engine.spatial.stop() }
    }

    // MARK: Frame

    func draw(in view: LightingSurfaceView) {
        let now = CACurrentMediaTime()
        let dt = lastDraw == 0 ? 1.0 / 60 : min(now - lastDraw, 0.1)
        lastDraw = now
        updatePacing(now: now)
        guard adaptive.quality != .suspended else { return }

        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let scale = view.drawableSize.width / max(size.width, 1)

        // Ease everything first: this decides whether the frame needs drawing at all
        let orientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        engine.spatial.update(dt: dt, layoutFoldDegrees: engine.geometry.layoutFoldDegrees, orientation: orientation)
        engine.step(dt: dt)
        surfaces.step(dt: dt)
        let analysisDue = engine.analysisDue(now: now)
        let spatialMoved = engine.lightingMix > 0 && engine.spatial.state != lastSpatial
        if size != lastSize { needsRender = true; lastSize = size }
        guard needsRender || analysisDue || spatialMoved || surfaces.isAnimating || engine.isEasing else {
            publish(now: now)
            return
        }

        // Never block the main thread on the GPU: skip the frame instead
        guard inflight.wait(timeout: .now()) == .success else {
            skipped += 1
            return
        }
        guard let drawable = view.currentDrawable, let commandBuffer = shaders.queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }
        commandBuffer.label = "lighting frame"
        displayTicks.tick(now)
        ensureTargets(width: Int(view.drawableSize.width), height: Int(view.drawableSize.height))
        guard let surfaceTarget, let specularTarget else {
            inflight.signal()
            return
        }

        let uniforms = engine.uniforms(viewSize: size, scale: scale, time: now, dt: dt, cardCount: surfaces.instances.count)
        var holder: AnyObject?
        if analysisDue {
            holder = engine.encodeAnalysis(now: now, commandBuffer: commandBuffer, uniforms: uniforms)
            if holder != nil { lightingTicks.tick(now) }
        } else {
            engine.syncSource()
        }
        engine.encodeProjection(commandBuffer: commandBuffer, uniforms: uniforms, viewSize: size, force: holder != nil)

        let near = engine.analysis.near ?? placeholder
        let far = engine.analysis.far ?? placeholder
        surfaces.encode(commandBuffer: commandBuffer, target: surfaceTarget, uniforms: uniforms,
                        irradiance: engine.irradiance ?? placeholder, near: near, far: far)
        highlights.encode(commandBuffer: commandBuffer, target: specularTarget, uniforms: uniforms,
                          instances: surfaces.instances, scene: engine.analysis.scene,
                          enabled: engine.lightingMix > 0.001 && engine.analysis.hasData && uniforms.look2.w > 0.5)
        compositor.encode(commandBuffer: commandBuffer, drawable: drawable.texture, surface: surfaceTarget, specular: specularTarget)
        commandBuffer.present(drawable)

        // Completion: keep the video texture alive until the GPU is done, record GPU time, read the palette
        let keep = UncheckedSendable(value: holder)
        let semaphore = inflight
        let stats = self.stats
        let wantsPalette = onPalette != nil && holder != nil && now - lastPalette > 0.25
        if wantsPalette { lastPalette = now }
        let readback: UncheckedSendable<(any MTLBuffer, any MTLBuffer)>? =
            wantsPalette ? UncheckedSendable(value: (engine.analysis.cells, engine.analysis.scene)) : nil
        commandBuffer.addCompletedHandler { @Sendable buffer in
            _ = keep
            let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            if gpu > 0 { stats.recordGPU(gpu) }
            if let readback {
                let palette = ColorAnalysisEngine.palette(cells: UnsafeRawPointer(readback.value.0.contents()),
                                                          scene: UnsafeRawPointer(readback.value.1.contents()))
                stats.storePalette(palette)
            }
            semaphore.signal()
        }
        commandBuffer.commit()

        needsRender = false
        lastSpatial = engine.spatial.state
        let cpu = (CACurrentMediaTime() - now) * 1000
        cpuMilliseconds = cpuMilliseconds * 0.9 + cpu * 0.1
        publish(now: now)
    }

    private func ensureTargets(width: Int, height: Int) {
        guard width > 0, height > 0, targetSize != (width, height) || surfaceTarget == nil else { return }
        pool.recycle(surfaceTarget)
        pool.recycle(specularTarget)
        let usage: MTLTextureUsage = [.renderTarget, .shaderRead]
        surfaceTarget = pool.make(width: width, height: height, format: MetalShaderLibrary.offscreenFormat,
                                  usage: usage, label: "card surfaces")
        specularTarget = pool.make(width: max(width / 2, 1), height: max(height / 2, 1), format: MetalShaderLibrary.offscreenFormat,
                                   usage: usage, label: "card highlights")
        targetSize = (width, height)
    }

    private func publish(now: CFTimeInterval) {
        let taken = stats.take()
        gpuMilliseconds = taken.gpu
        if let palette = taken.palette { onPalette?(palette) }
        guard now - lastPublish >= 0.5, let onDiagnostics else { return }
        lastPublish = now
        var d = LightingDiagnostics()
        d.displayFPS = displayTicks.rate(now: now)
        d.lightingFPS = lightingTicks.rate(now: now)
        d.gpuMilliseconds = taken.gpu
        d.cpuMilliseconds = cpuMilliseconds
        d.skippedFrames = skipped
        d.textureBytes = pool.allocatedBytes
        d.quality = adaptive.quality
        d.adaptation = adaptive.adaptation
        d.gpuTier = adaptive.gpuTier
        d.thermalState = ProcessInfo.processInfo.thermalState
        d.hasVideo = engine.frames.hasVideo
        d.foldDegrees = engine.spatial.foldDegrees
        d.preset = engine.mode.preset
        d.targetAnalysisHz = engine.profile.analysisEnabled ? engine.targetAnalysisHz : 0
        d.idle = engine.idle
        d.tilt = engine.spatial.state.tilt
        d.spatialIntensity = engine.spatial.state.intensity
        d.effectiveIntensity = engine.intensity
        d.effectiveSpecular = engine.look.y
        d.lightingMix = engine.lightingMix
        onDiagnostics(d)
    }
}

/// Frames per second over the last second
struct TickCounter {
    private var times: [CFTimeInterval] = []

    mutating func tick(_ now: CFTimeInterval) {
        times.append(now)
        if times.count > 240 { times.removeFirst(times.count - 240) }
    }

    mutating func rate(now: CFTimeInterval) -> Double {
        times.removeAll { now - $0 > 1 }
        return Double(times.count)
    }
}

/// Written from Metal completion handlers, read on the main thread
final class FrameStats: Sendable {
    private struct State: Sendable {
        var gpu: Double = 0
        var palette: SampledPalette?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func recordGPU(_ milliseconds: Double) {
        lock.withLock { $0.gpu = $0.gpu == 0 ? milliseconds : $0.gpu * 0.9 + milliseconds * 0.1 }
    }

    func storePalette(_ palette: SampledPalette) {
        lock.withLock { $0.palette = palette }
    }

    func take() -> (gpu: Double, palette: SampledPalette?) {
        lock.withLock { state in
            let p = state.palette
            state.palette = nil
            return (state.gpu, p)
        }
    }
}

/// The MTKView the cards are drawn into. Not interactive: the SwiftUI controls above it take the touches.
public final class LightingSurfaceView: MTKView {
    weak var renderer: MetalRenderer?

    init(device: any MTLDevice) {
        super.init(frame: .zero, device: device)
        colorPixelFormat = MetalShaderLibrary.drawableFormat
        framebufferOnly = true
        isOpaque = true
        backgroundColor = .black
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = true
        autoResizeDrawable = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func draw(_ rect: CGRect) {
        renderer?.draw(in: self)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        renderer?.windowChanged(inWindow: window != nil)
    }
}
