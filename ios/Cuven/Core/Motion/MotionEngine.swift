import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import UIKit
import VideoToolbox

// MARK: - 自研运动补偿插帧（用户要求「自研管线和思路，最大化利用插帧」）
//
// 思路：把「估运动」和「出画面」拆开。
//   · 估运动：每对相邻的片源帧只做一次（24 fps 片源每秒 24 次），在 GPU 上算出这一对帧之间每个像素的运动和可信度
//     （着色器和算法说明见 MotionFlow.metal）。
//   · 出画面：屏幕每刷新一次，按这一帧真正上屏的时刻算它落在两帧之间的哪个位置，片元着色器现画一帧直接上屏。
//     所以片源是 24 / 25 / 30 / 50 / 60 fps、屏幕是 60 / 120 Hz 都是同一条路，没有固定的几档帧率；
//     出图按屏幕像素，4K 片源不用先缩小。
//   · 系统自带的插帧（VideoToolbox 低延迟插帧）只当「神经关键帧」用：每对帧只让它算正中间那一帧（它最省的用法），
//     只在自己的运动估计信不过的像素上拿来用。来不及、片源超过它的尺寸上限、这台设备不支持时，这些像素退回
//     时间上更近的那张原帧（等于局部不插帧），不造假画面。
//
// 时序：CAMetalDisplayLink 在自己的线程上回调，给出这一帧的上屏时刻 T；片源时间 τ = 播放器在 T 时的时间 − 延后量。
// 一对帧要等后一帧取到、运动估完才能用：能从播放器提前取到后面的帧（前瞻）就不用延后；取不到时画面整体晚一点出来
// （上限 90 ms，按实际需要自己收敛，慢慢放回）。还没估完的那一对先原样显示前一帧（等于那一小段没插帧）。
//
// 所有状态只在渲染线程上改；别的线程（主线程、GPU 完成回调、VideoToolbox 回调）一律把闭包投到信箱里，下一次刷新时执行。

enum MotionTuning {
    static let baseWidth = 960
    static let coarseRadius: Float = 6
    static let window: Float = 8
    static let lamZero: Float = 0.002
    static let lamDeviation: Float = 0.004
    static let lamUpdate: Float = 0.002
    static let contrastGain: Float = 0.5
    static let noiseFloor: Float = 0.02
    static let gate = SIMD2<Float>(0.6, 1.6)
    static let blendEdges = SIMD2<Float>(0.1, 0.9)
    static let holdEdges = SIMD2<Float>(0.4, 0.6)
    /// 可信度的软门限（在半尺寸那一层上量的残差）
    static let trustGate = SIMD2<Float>(0.45, 1.2)
    /// 逐像素选向量时，周围四个块的向量差在这以内（基层像素）就直接取平均
    static let uniformSpread: Float = 0.75
    /// 画面最多晚这么多出来（真机上播放器能提前给 90～140 ms 的帧，正常用不到）
    static let maxDelay = 0.060
    static let maxDelayForNeural = 0.045
    static let initialDelay = 0.020
    /// 一对帧里可信的面积不到这么多：整对不插（画面太乱，插出来是一块一块的）
    static let minTrust: Float = 0.3
}

struct MFParams {
    var search: SIMD4<Float>
    var refine: SIMD4<Float>
    var extra: SIMD4<Float>
}

struct MFDraw {
    var phase: SIMD4<Float>
    var uv: SIMD4<Float>
    var gate: SIMD4<Float>
    var weights: SIMD4<Float>
    var range: SIMD4<Float>
    var toR: SIMD4<Float>
    var toG: SIMD4<Float>
    var toB: SIMD4<Float>
}

// MARK: - GPU 资源（管线、纹理池）

final class MotionGPU: @unchecked Sendable {
    let device: any MTLDevice
    let analysisQueue: any MTLCommandQueue
    let drawQueue: any MTLCommandQueue
    let cache: CVMetalTextureCache

    let lumaBase: any MTLComputePipelineState
    let packContrast: any MTLComputePipelineState
    let down2: any MTLComputePipelineState
    let searchCoarse: any MTLComputePipelineState
    let refine: any MTLComputePipelineState
    let propagate: any MTLComputePipelineState
    let median: any MTLComputePipelineState
    let densify: any MTLComputePipelineState
    let trust: any MTLComputePipelineState
    let blur3: any MTLComputePipelineState
    private let presentSDR: any MTLRenderPipelineState
    private let presentHDR: any MTLRenderPipelineState

    private let lock = NSLock()
    private var pool: [String: [any MTLTexture]] = [:]
    private var limbo: [(tick: Int, texture: any MTLTexture)] = []

    /// 建一次就一直留着（管线编译要几十毫秒）
    static let shared: MotionGPU? = MotionGPU()

    private init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), dev.supportsFamily(.apple4),
              let aq = dev.makeCommandQueue(), let dq = dev.makeCommandQueue(),
              let lib = dev.makeDefaultLibrary() else { return nil }
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &c) == kCVReturnSuccess, let c else { return nil }
        func compute(_ name: String) -> (any MTLComputePipelineState)? {
            guard let f = lib.makeFunction(name: name) else { return nil }
            return try? dev.makeComputePipelineState(function: f)
        }
        func render(_ format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "mf_vertex")
            d.fragmentFunction = lib.makeFunction(name: "mf_present")
            d.colorAttachments[0].pixelFormat = format
            return try? dev.makeRenderPipelineState(descriptor: d)
        }
        guard let k0 = compute("mf_luma_base"), let k1 = compute("mf_pack_contrast"), let k2 = compute("mf_down2"),
              let k3 = compute("mf_search_coarse"), let k4 = compute("mf_refine"), let k5 = compute("mf_propagate"),
              let k6 = compute("mf_median"), let k7 = compute("mf_densify"), let k8 = compute("mf_trust"),
              let k9 = compute("mf_blur3"),
              let sdr = render(.bgra8Unorm), let hdr = render(.bgr10a2Unorm) else { return nil }
        device = dev
        analysisQueue = aq
        drawQueue = dq
        cache = c
        lumaBase = k0; packContrast = k1; down2 = k2; searchCoarse = k3; refine = k4; propagate = k5
        median = k6; densify = k7; trust = k8; blur3 = k9
        presentSDR = sdr
        presentHDR = hdr
        aq.label = "cuven.motion.analysis"
        dq.label = "cuven.motion.draw"
    }

    func presentPipeline(_ format: MTLPixelFormat) -> any MTLRenderPipelineState {
        format == .bgr10a2Unorm ? presentHDR : presentSDR
    }

    func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, shared: Bool = false) -> (any MTLTexture)? {
        let key = "\(format.rawValue)-\(width)-\(height)-\(shared ? 1 : 0)"
        lock.lock()
        if var list = pool[key], let t = list.popLast() {
            pool[key] = list
            lock.unlock()
            return t
        }
        lock.unlock()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, width), height: max(1, height),
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = shared ? .shared : .private
        return device.makeTexture(descriptor: d)
    }

    /// 还回去：先搁几次刷新（可能还有已经提交、没跑完的命令在用），再进池子
    func retire(_ textures: [(any MTLTexture)?], tick: Int) {
        lock.lock()
        for t in textures { if let t { limbo.append((tick + 8, t)) } }
        lock.unlock()
    }

    func expire(tick: Int) {
        lock.lock()
        var keep: [(tick: Int, texture: any MTLTexture)] = []
        for e in limbo {
            if e.tick <= tick {
                let t = e.texture
                let key = "\(t.pixelFormat.rawValue)-\(t.width)-\(t.height)-\(t.storageMode == .shared ? 1 : 0)"
                var list = pool[key] ?? []
                if list.count < 12 { list.append(t) }
                pool[key] = list
            } else {
                keep.append(e)
            }
        }
        limbo = keep
        lock.unlock()
    }

    /// 没人用的时候把池子清掉（播放器收起）
    func drain() {
        lock.lock()
        pool.removeAll()
        limbo.removeAll()
        lock.unlock()
        CVMetalTextureCacheFlush(cache, 0)
    }

    func planes(of buffer: CVPixelBuffer, tenBit: Bool) -> (y: any MTLTexture, c: any MTLTexture, holders: [CVMetalTexture])? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }
        func plane(_ index: Int, _ format: MTLPixelFormat) -> (any MTLTexture, CVMetalTexture)? {
            var cv: CVMetalTexture?
            let w = CVPixelBufferGetWidthOfPlane(buffer, index)
            let h = CVPixelBufferGetHeightOfPlane(buffer, index)
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, format, w, h, index, &cv)
                    == kCVReturnSuccess, let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
            return (t, cv)
        }
        guard let y = plane(0, tenBit ? .r16Unorm : .r8Unorm), let c = plane(1, tenBit ? .rg16Unorm : .rg8Unorm) else { return nil }
        return (y.0, c.0, [y.1, c.1])
    }
}

// MARK: - 帧、帧对

final class MotionFrame {
    let buffer: CVPixelBuffer
    let time: Double
    let y: any MTLTexture
    let c: any MTLTexture
    let holders: [CVMetalTexture]
    var packed: (any MTLTexture)?
    var l1: (any MTLTexture)?
    var l2: (any MTLTexture)?
    var l3: (any MTLTexture)?
    let thumb: [UInt8]?

    init(buffer: CVPixelBuffer, time: Double, y: any MTLTexture, c: any MTLTexture, holders: [CVMetalTexture], thumb: [UInt8]?) {
        self.buffer = buffer
        self.time = time
        self.y = y
        self.c = c
        self.holders = holders
        self.thumb = thumb
    }
}

/// 画过的东西（一样就不再画）
struct DrawKey: Equatable {
    var time: Double
    var phi: Float
    var mode: Int
    var width: Int
    var height: Int
}

final class MotionPair {
    enum State { case pending, ready, failed }
    let a: MotionFrame
    let b: MotionFrame
    var state = State.pending
    /// 整对不插（切镜、断档、太乱、积压）
    var hold = false
    var dense: (any MTLTexture)?
    var trust: (any MTLTexture)?
    var neural: MotionFrame?
    var neuralRequested = false
    /// 画面走进这一对的那一刻定下来怎么画，这一对之内不再变（中途换会跳一下）
    enum Latch { case hold, interpolate, neural }
    var latch: Latch?

    init(a: MotionFrame, b: MotionFrame) {
        self.a = a
        self.b = b
    }
}

// MARK: - 引擎

final class MotionEngine: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    struct Source {
        var width: Int
        var height: Int
        var format: OSType
        var tenBit: Bool
        var fullRange: Bool
        var hdr: Bool
        var fps: Double
        var displayRate: Int
    }

    struct Snapshot: Sendable {
        var sourceFPS = 0.0
        var drawFPS = 0.0
        var interpolatedShare = 0.0
        var lookaheadMs = 0.0
        var analysisMs = 0.0
        var drawMs = 0.0
        var delayMs = 0.0
        var trusted = 0.0
        var cuts = 0
        var misses = 0
        var stalls = 0
        var neuralState = "关"
        var neuralMs = 0.0
        var neuralShare = 0.0
        var presented = 0
        var failure: String?
    }

    private let gpu: MotionGPU
    private let output: AVPlayerItemVideoOutput
    private let layer: CAMetalLayer
    private let source: Source
    private let neuralConfig: VTLowLatencyFrameInterpolationConfiguration?

    private let lock = NSLock()
    private var mailbox: [() -> Void] = []
    private var stopRequested = false
    private var thread: Thread?

    // 以下只在渲染线程上用
    private var link: CAMetalDisplayLink?
    private var tick = 0
    private var frames: [MotionFrame] = []
    private var pairs: [MotionPair] = []
    private var lastFetched: Double?
    private var lastFetchHost = CACurrentMediaTime()
    private var interval: Double
    private var lastNow: Double?
    private var lastHost = CACurrentMediaTime()
    private var lastContent: Double?
    private var delay = MotionTuning.initialDelay
    private var needs: [Double] = []
    private var pendingAnalyses = 0
    private var uvCrop = SIMD4<Float>(1, 1, 0, 0)
    private var showRoutes = false
    private var colorRows: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)?
    private var lastDrawKey: DrawKey?
    private var statLead = 0.017
    private var failure: String?

    private var processor: VTFrameProcessor?
    private var neuralPool: CVPixelBufferPool?
    private var neuralBusy = false
    private var neuralState = "关"

    // 统计
    private var statLookahead = 0.0
    private var statAnalysis = 0.0
    private var statDraw = 0.0
    private var statTrust = 1.0
    private var statNeuralMs = 0.0
    private var cuts = 0
    private var misses = 0
    private var stalls = 0
    private var presented = 0
    private var windowStart = CACurrentMediaTime()
    private var windowDraws = 0
    private var windowInterpolated = 0
    private var windowMisses = 0
    private var windowPairs = 0
    private var windowNeural = 0
    private var fetched = 0
    private var drawFPS = 0.0
    private var interpolatedShare = 0.0
    private var neuralShare = 0.0
    private var badWindows = 0

    /// 第一帧上屏（主线程上回调）
    var onFirstPresent: (@Sendable () -> Void)?

    init(gpu: MotionGPU, output: AVPlayerItemVideoOutput, layer: CAMetalLayer, source: Source,
         neural: VTLowLatencyFrameInterpolationConfiguration?) {
        self.gpu = gpu
        self.output = output
        self.layer = layer
        self.source = source
        self.neuralConfig = neural
        self.interval = source.fps > 1 ? 1 / source.fps : 1 / 24
        super.init()
    }

    // MARK: 对外（任何线程）

    func start() {
        let t = Thread { [self] in self.threadMain() }
        t.name = "cuven.motion.render"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    func post(_ work: @escaping () -> Void) {
        lock.lock()
        mailbox.append(work)
        lock.unlock()
    }

    /// 进度跳了
    func reset() {
        post { [weak self] in self?.resetTimeline() }
    }

    func setCrop(_ uv: SIMD4<Float>) {
        post { [weak self] in
            self?.uvCrop = uv
            self?.lastDrawKey = nil
        }
    }

    func setShowRoutes(_ on: Bool) {
        post { [weak self] in
            self?.showRoutes = on
            self?.lastDrawKey = nil
        }
    }

    func snapshot(_ done: @escaping @Sendable (Snapshot) -> Void) {
        post { [weak self] in
            guard let self else { return }
            var s = Snapshot()
            s.sourceFPS = self.interval > 0 ? 1 / self.interval : 0
            s.drawFPS = self.drawFPS
            s.interpolatedShare = self.interpolatedShare
            s.lookaheadMs = self.statLookahead * 1000
            s.analysisMs = self.statAnalysis * 1000
            s.drawMs = self.statDraw * 1000
            s.delayMs = self.delay * 1000
            s.trusted = self.statTrust
            s.cuts = self.cuts
            s.misses = self.misses
            s.stalls = self.stalls
            s.neuralState = self.neuralState
            s.neuralMs = self.statNeuralMs * 1000
            s.neuralShare = self.neuralShare
            s.presented = self.presented
            s.failure = self.failure
            done(s)
        }
    }

    // MARK: 渲染线程

    private func threadMain() {
        autoreleasepool {
            let l = CAMetalDisplayLink(metalLayer: layer)
            l.delegate = self
            l.preferredFrameLatency = 2
            let r = Float(source.displayRate)
            l.preferredFrameRateRange = CAFrameRateRange(minimum: r, maximum: r, preferred: r)
            l.add(to: .current, forMode: .default)
            link = l
        }
        startNeural()
        while true {
            lock.lock()
            let stop = stopRequested
            lock.unlock()
            if stop { break }
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
                // 显示层没在刷新时（还没排好版、被盖住）信箱也要清，不然越积越多
                drainMailbox()
            }
        }
        link?.invalidate()
        link = nil
        onFirstPresent = nil
        dropAll()
        if let processor {
            processor.endSession()
        }
        processor = nil
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        autoreleasepool {
            step(drawable: update.drawable, presentAt: update.targetPresentationTimestamp)
        }
    }

    private func drainMailbox() {
        lock.lock()
        let work = mailbox
        mailbox.removeAll()
        lock.unlock()
        for w in work { w() }
    }

    private func seconds(_ t: CMTime) -> Double? {
        t.isNumeric ? t.seconds : nil
    }

    private func step(drawable: any CAMetalDrawable, presentAt: CFTimeInterval) {
        drainMailbox()
        tick += 1
        gpu.expire(tick: tick)
        guard failure == nil else { return }
        let host = CACurrentMediaTime()
        rollWindow(host)
        guard let now = seconds(output.itemTime(forHostTime: host)),
              let atPresent = seconds(output.itemTime(forHostTime: presentAt)) else { return }
        let lead = max(0.001, presentAt - host)
        let rate = (atPresent - now) / lead
        let playing = rate > 0.5
        statLead = statLead * 0.95 + min(0.05, lead) * 0.05
        if !playing { lastFetchHost = host }

        // 进度跳了：重新接
        if let last = lastNow {
            let expected = (host - lastHost) * max(0, rate)
            if abs(now - last - expected) > 0.5 { resetTimeline() }
        }
        lastNow = now
        lastHost = host

        fetch(now: now, host: host)

        // 播着，却一直取不到新帧：重新接；总是这样就放弃，露出系统画面
        if playing, host - lastFetchHost > 0.8 {
            stalls += 1
            lastFetchHost = host
            resetTimeline()
            if stalls > 8 { failure = "一直取不到画面，已改回原样播放"; return }
        }

        adjustDelay()
        // 播着：片源时间 = 上屏那一刻的时间 − 延后量，只进不退（延后量变大时停一下，不往回跳）。
        // 暂停：停在系统画面的那一帧上（原帧）；接着放时从这里起步，等延后量追上再往前走
        var content = atPresent
        if playing {
            content = atPresent - delay
            if let last = lastContent, content < last, last - content < 0.3 { content = last }
        }
        lastContent = content
        render(content: content, playing: playing, drawable: drawable)
    }

    // MARK: 取帧

    private func fetch(now: Double, host: CFTimeInterval) {
        var taken = 0
        // 手上最多留 5 帧：片源的帧来自解码器自己的缓冲池，占多了它出不了新帧
        // 一次刷新最多取两帧：刚拖动完不要一口气交上去三对分析
        while taken < 2, frames.count < 5 {
            var probe = now
            if let lf = lastFetched {
                // 下一帧大约在 lf + interval：问 lf + 1.5 个间隔，正好拿到下一帧、不跳帧；落后了就追到现在
                probe = max(lf + interval * 1.5, now)
                if probe > now + 0.3 { break }
            }
            let pt = CMTime(seconds: probe, preferredTimescale: 1_000_000)
            guard output.hasNewPixelBuffer(forItemTime: pt) else { break }
            var shown = CMTime.invalid
            guard let pb = output.copyPixelBuffer(forItemTime: pt, itemTimeForDisplay: &shown) else { break }
            taken += 1
            accept(pb, time: seconds(shown) ?? probe, now: now, host: host)
        }
    }

    private func accept(_ buffer: CVPixelBuffer, time: Double, now: Double, host: CFTimeInterval) {
        if let last = frames.last {
            let gap = time - last.time
            if gap <= 0.0005 {
                if gap < -0.05 { resetTimeline() } else { return }
            }
        }
        guard CVPixelBufferGetWidth(buffer) == source.width, CVPixelBufferGetHeight(buffer) == source.height,
              let planes = gpu.planes(of: buffer, tenBit: source.tenBit) else {
            failure = "片源的帧格式变了，已改回原样播放"
            return
        }
        if colorRows == nil { colorRows = Self.matrix(for: buffer, source: source) }
        let frame = MotionFrame(buffer: buffer, time: time, y: planes.y, c: planes.c, holders: planes.holders,
                                thumb: Self.thumbnail(buffer, tenBit: source.tenBit))
        guard buildPyramid(frame) else {
            failure = "建不了分析用的纹理，已改回原样播放"
            return
        }
        lastFetchHost = host
        fetched += 1
        statLookahead = statLookahead * 0.9 + (time - now) * 0.1
        if let prev = frames.last {
            let gap = time - prev.time
            let pair = MotionPair(a: prev, b: frame)
            if gap > 0.25 {
                pair.hold = true
            } else {
                interval = interval * 0.9 + gap * 0.1
                if Self.isCut(prev.thumb, frame.thumb) {
                    pair.hold = true
                    cuts += 1
                } else if pendingAnalyses >= 3 {
                    // 分析积压：这一对不插
                    pair.hold = true
                    misses += 1
                    windowMisses += 1
                } else {
                    analyse(pair)
                    requestNeural(pair)
                }
            }
            if pair.hold { pair.state = .ready }
            pairs.append(pair)
        }
        frames.append(frame)
        lastFetched = time
    }

    private func resetTimeline() {
        dropAll()
        lastFetched = nil
        lastNow = nil
        lastContent = nil
        lastDrawKey = nil
    }

    private func dropAll() {
        for p in pairs { retire(p) }
        for f in frames { retire(f) }
        pairs.removeAll()
        frames.removeAll()
    }

    private func retire(_ f: MotionFrame) {
        gpu.retire([f.packed, f.l1, f.l2, f.l3], tick: tick)
        f.packed = nil; f.l1 = nil; f.l2 = nil; f.l3 = nil
    }

    private func retire(_ p: MotionPair) {
        gpu.retire([p.dense, p.trust], tick: tick)
        p.dense = nil
        p.trust = nil
        p.neural = nil
    }

    // MARK: 分析

    private func dispatch(_ enc: any MTLComputeCommandEncoder, _ pipeline: any MTLComputePipelineState,
                          _ textures: [any MTLTexture], params: MFParams? = nil) {
        guard let out = textures.last else { return }
        enc.setComputePipelineState(pipeline)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        if var p = params {
            enc.setBytes(&p, length: MemoryLayout<MFParams>.stride, index: 0)
        }
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: out.width, height: out.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    /// 这一帧的亮度金字塔（基层带局部对比度）。和后面用到它的分析排在同一条命令队列上，先后有保证
    private func buildPyramid(_ f: MotionFrame) -> Bool {
        let scale = max(1, Int((Double(source.width) / Double(MotionTuning.baseWidth)).rounded()))
        let w0 = max(16, source.width / scale), h0 = max(16, source.height / scale)
        guard let base = gpu.texture(.r16Float, w0, h0),
              let packed = gpu.texture(.rg16Float, w0, h0),
              let l1 = gpu.texture(.r16Float, w0 / 2, h0 / 2),
              let l2 = gpu.texture(.r16Float, w0 / 4, h0 / 4),
              let l3 = gpu.texture(.r16Float, w0 / 8, h0 / 8),
              let cb = gpu.analysisQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return false }
        dispatch(enc, gpu.lumaBase, [f.y, base])
        dispatch(enc, gpu.packContrast, [base, packed])
        dispatch(enc, gpu.down2, [packed, l1])
        dispatch(enc, gpu.down2, [l1, l2])
        dispatch(enc, gpu.down2, [l2, l3])
        enc.endEncoding()
        let holders = f.holders
        cb.addCompletedHandler { _ in _ = holders }
        cb.commit()
        f.packed = packed; f.l1 = l1; f.l2 = l2; f.l3 = l3
        gpu.retire([base], tick: tick)
        return true
    }

    private func analyse(_ pair: MotionPair) {
        guard let a0 = pair.a.packed, let a1 = pair.a.l1, let a2 = pair.a.l2, let a3 = pair.a.l3,
              let b0 = pair.b.packed, let b1 = pair.b.l1, let b2 = pair.b.l2, let b3 = pair.b.l3 else {
            pair.hold = true
            return
        }
        let g3w = (a3.width + 7) / 8, g3h = (a3.height + 7) / 8
        func field(_ k: Int) -> (any MTLTexture)? { gpu.texture(.rgba16Float, g3w * k, g3h * k) }
        // 逐像素的向量在半尺寸那一层（a1）上，可信度再小一半
        let tw = max(1, a1.width / 2), th = max(1, a1.height / 2)
        guard let f3a = field(1), let f3b = field(1), let f2a = field(2), let f2b = field(2),
              let f1a = field(4), let f1b = field(4), let f0a = field(8), let f0c = field(8),
              let d1 = gpu.texture(.rgba16Float, a1.width, a1.height),
              let d2 = gpu.texture(.rgba16Float, a1.width, a1.height),
              let t1 = gpu.texture(.r8Unorm, tw, th),
              let t2 = gpu.texture(.r8Unorm, tw, th, shared: true) else {
            pair.hold = true
            return
        }
        func params(window: Float, spacing: Float, half: Bool) -> MFParams {
            MFParams(search: SIMD4(MotionTuning.coarseRadius, window, MotionTuning.lamZero, MotionTuning.lamDeviation),
                     refine: SIMD4(MotionTuning.lamUpdate, half ? 1 : 0, MotionTuning.contrastGain, MotionTuning.noiseFloor),
                     extra: SIMD4(spacing, MotionTuning.trustGate.x, MotionTuning.trustGate.y, MotionTuning.uniformSpread))
        }
        // 最粗一层用完整的 8×8 窗口（那里要稳）；细的几层用 4×4 个落在像素角上的采样点（同样盖住 8×8，省四分之三）
        let coarse = params(window: MotionTuning.window, spacing: 1, half: false)
        let fine = params(window: 4, spacing: 2, half: false)
        let finest = params(window: 4, spacing: 2, half: true)
        // 拆成几小段各自提交：出画面的命令（另一条队列）可以插在两段之间，不被一整块分析挡住
        var buffers: [any MTLCommandBuffer] = []
        func stage(_ body: (any MTLComputeCommandEncoder) -> Void) {
            guard let cb = gpu.analysisQueue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
            body(enc)
            enc.endEncoding()
            buffers.append(cb)
        }
        stage { enc in
            dispatch(enc, gpu.searchCoarse, [a3, b3, f3a], params: coarse)
            dispatch(enc, gpu.propagate, [a3, b3, f3a, f3b], params: coarse)
            dispatch(enc, gpu.refine, [a2, b2, f3b, f2a], params: fine)
            dispatch(enc, gpu.propagate, [a2, b2, f2a, f2b], params: fine)
        }
        stage { enc in
            dispatch(enc, gpu.refine, [a1, b1, f2b, f1a], params: fine)
            dispatch(enc, gpu.propagate, [a1, b1, f1a, f1b], params: fine)
        }
        stage { enc in dispatch(enc, gpu.refine, [a0, b0, f1b, f0a], params: finest) }
        stage { enc in
            dispatch(enc, gpu.median, [f0a, f0c])
            dispatch(enc, gpu.densify, [a1, b1, f0c, d1], params: fine)
            dispatch(enc, gpu.median, [d1, d2])
            dispatch(enc, gpu.trust, [d2, a0, b0, t1], params: fine)
            dispatch(enc, gpu.blur3, [t1, t2])
        }
        guard buffers.count == 4, let cb = buffers.last else {
            pair.hold = true
            gpu.retire([f3a, f3b, f2a, f2b, f1a, f1b, f0a, f0c, d1, d2, t1, t2], tick: tick)
            return
        }
        pair.dense = d2
        pair.trust = t2
        pendingAnalyses += 1
        gpu.retire([f3a, f3b, f2a, f2b, f1a, f1b, f0a, f0c, d1, t1], tick: tick + 30)
        let submitted = CACurrentMediaTime()
        let trustTexture = UncheckedTexture(t2)
        let weakPair = WeakBox(pair)
        cb.addCompletedHandler { [weak self] cb in
            let ok = cb.status == .completed
            let readyHost = CACurrentMediaTime()
            var mean: Float = 1
            if ok {
                let t = trustTexture.texture
                var bytes = [UInt8](repeating: 0, count: t.width * t.height)
                bytes.withUnsafeMutableBytes { raw in
                    if let base = raw.baseAddress {
                        t.getBytes(base, bytesPerRow: t.width, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
                    }
                }
                var sum = 0
                for b in bytes { sum += Int(b) }
                mean = bytes.isEmpty ? 1 : Float(sum) / Float(bytes.count) / 255
            }
            self?.post { [weak self] in
                guard let self else { return }
                self.pendingAnalyses = max(0, self.pendingAnalyses - 1)
                // 从提交到全部算完（含排队），就是这一对要等多久
                self.statAnalysis = self.statAnalysis * 0.9 + (readyHost - submitted) * 0.1
                guard let pair = weakPair.value else { return }
                pair.state = ok ? .ready : .failed
                if !ok { pair.hold = true }
                self.statTrust = self.statTrust * 0.9 + Double(mean) * 0.1
                if mean < MotionTuning.minTrust { pair.hold = true }
                self.noteReady(pair, readyHost: readyHost, cap: MotionTuning.maxDelay)
            }
        }
        for b in buffers { b.commit() }
    }

    /// 这一对在片源时间 τ（准备好的那一刻）才能用：要想赶上它的起点 tA，画面得晚 τ + 提前量 − tA
    private func noteReady(_ pair: MotionPair, readyHost: CFTimeInterval, cap: Double) {
        guard let now = lastNow else { return }
        let itemAtReady = now - (lastHost - readyHost)
        let need = itemAtReady + statLead + 0.004 - pair.a.time
        needs.append(min(cap, max(0, need)))
        if needs.count > 32 { needs.removeFirst(needs.count - 32) }
    }

    private func adjustDelay() {
        guard needs.count >= 4 else { return }
        // 取第三大的那个：偶尔一对慢了（刚拖动完、系统忙了一下）不该把整段画面一直往后拖
        let target = needs.sorted(by: >)[2]
        let goal = min(MotionTuning.maxDelay, target + 0.003)
        if goal > delay {
            delay += min(goal - delay, 0.002)
        } else if goal < delay - 0.003 {
            delay -= 0.0005
        }
    }

    // MARK: 神经关键帧（系统低延迟插帧，只算正中间那一帧）

    private func startNeural() {
        guard let config = neuralConfig else { return }
        neuralState = "载入中"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = VTFrameProcessor()
            var pool: CVPixelBufferPool?
            var problem: String?
            do {
                try p.startSession(configuration: config)
                var attrs: [String: Any] = [:]
                for (k, v) in config.destinationPixelBufferAttributes { attrs[k] = v }
                guard let self else { p.endSession(); return }
                attrs[kCVPixelBufferPixelFormatTypeKey as String] = self.source.format
                attrs[kCVPixelBufferWidthKey as String] = self.source.width
                attrs[kCVPixelBufferHeightKey as String] = self.source.height
                attrs[kCVPixelBufferMetalCompatibilityKey as String] = true
                if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
                    attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
                }
                let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
                if CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool) != kCVReturnSuccess {
                    pool = nil
                }
                if pool == nil {
                    p.endSession()
                    problem = "建不了缓冲区"
                }
            } catch {
                problem = "启动失败（\((error as NSError).code)）"
            }
            let processor = UncheckedBox(p)
            let boxedPool = UncheckedBox(pool)
            self?.post { [weak self] in
                guard let self else { return }
                if let problem {
                    self.neuralState = problem
                } else {
                    self.processor = processor.value
                    self.neuralPool = boxedPool.value
                    self.neuralState = "开"
                }
            }
        }
    }

    private func requestNeural(_ pair: MotionPair) {
        guard let processor, let pool = neuralPool, !neuralBusy else { return }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let out,
              let prev = VTFrameProcessorFrame(buffer: pair.a.buffer, presentationTimeStamp: Self.cm(pair.a.time)),
              let cur = VTFrameProcessorFrame(buffer: pair.b.buffer, presentationTimeStamp: Self.cm(pair.b.time)),
              let dst = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: Self.cm((pair.a.time + pair.b.time) / 2)),
              let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: cur, previousFrame: prev,
                                                                    interpolationPhase: [0.5], destinationFrames: [dst])
        else { return }
        CVBufferPropagateAttachments(pair.a.buffer, out)
        neuralBusy = true
        pair.neuralRequested = true
        let started = CACurrentMediaTime()
        let boxed = UncheckedBox(out)
        let weakPair = WeakBox(pair)
        processor.process(parameters: params) { [weak self] _, error in
            let failed = error != nil
            let readyHost = CACurrentMediaTime()
            self?.post { [weak self] in
                guard let self else { return }
                self.neuralBusy = false
                self.statNeuralMs = self.statNeuralMs * 0.9 + (readyHost - started) * 0.1
                guard !failed, let pair = weakPair.value, let planes = self.gpu.planes(of: boxed.value, tenBit: self.source.tenBit) else { return }
                pair.neural = MotionFrame(buffer: boxed.value, time: (pair.a.time + pair.b.time) / 2, y: planes.y, c: planes.c,
                                          holders: planes.holders, thumb: nil)
                self.noteReady(pair, readyHost: readyHost, cap: MotionTuning.maxDelayForNeural)
            }
        }
    }

    // MARK: 出画面

    private func render(content: Double, playing: Bool, drawable: any CAMetalDrawable) {
        guard let first = frames.first else { return }
        // content 落在哪一对里
        var index = 0
        if content >= first.time {
            for i in stride(from: frames.count - 1, through: 0, by: -1) where frames[i].time <= content {
                index = i
                break
            }
        }
        // 用不着的旧帧丢掉
        if index > 0 {
            for i in 0..<index {
                retire(frames[i])
                if i < pairs.count { retire(pairs[i]) }
            }
            frames.removeFirst(index)
            pairs.removeFirst(min(index, pairs.count))
        }
        guard let a = frames.first else { return }
        guard let pair = pairs.first, content >= a.time else {
            draw(single: a, drawable: drawable)
            return
        }
        if !playing {
            draw(single: pair.a, drawable: drawable)
            return
        }
        let phi = Float((content - pair.a.time) / max(1e-6, pair.b.time - pair.a.time))
        if pair.latch == nil {
            windowPairs += 1
            if pair.hold {
                pair.latch = .hold
            } else if pair.state == .ready, pair.dense != nil, pair.trust != nil {
                pair.latch = pair.neural != nil ? .neural : .interpolate
                if pair.neural != nil { windowNeural += 1 }
            } else {
                // 这一对还没估完：整对原样显示前一帧（等于这一小段没插帧）
                pair.latch = .hold
                misses += 1
                windowMisses += 1
            }
        }
        if pair.latch == .hold || phi < 0.02 {
            draw(single: pair.a, drawable: drawable)
            return
        }
        if phi > 0.98 {
            draw(single: pair.b, drawable: drawable)
            return
        }
        guard let dense = pair.dense, let trust = pair.trust, let pa = pair.a.packed, let pb = pair.b.packed else {
            draw(single: pair.a, drawable: drawable)
            return
        }
        let neural = pair.latch == .neural ? pair.neural : nil
        let key = DrawKey(time: pair.a.time, phi: phi, mode: neural != nil ? 2 : 1,
                          width: drawable.texture.width, height: drawable.texture.height)
        if key == lastDrawKey { return }
        var u = uniforms(phi: phi, mode: neural != nil ? 2 : 1)
        guard let cb = gpu.drawQueue.makeCommandBuffer(), let enc = encoder(cb, drawable) else { return }
        enc.setFragmentTexture(pair.a.y, index: 0)
        enc.setFragmentTexture(pair.a.c, index: 1)
        enc.setFragmentTexture(pair.b.y, index: 2)
        enc.setFragmentTexture(pair.b.c, index: 3)
        enc.setFragmentTexture(pa, index: 4)
        enc.setFragmentTexture(pb, index: 5)
        enc.setFragmentTexture(dense, index: 6)
        enc.setFragmentTexture(trust, index: 7)
        enc.setFragmentTexture(neural?.y ?? pair.a.y, index: 8)
        enc.setFragmentTexture(neural?.c ?? pair.a.c, index: 9)
        enc.setFragmentBytes(&u, length: MemoryLayout<MFDraw>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        finish(cb, drawable, keep: [pair.a, pair.b] + (neural.map { [$0] } ?? []), interpolated: true)
        lastDrawKey = key
    }

    private func encoder(_ cb: any MTLCommandBuffer, _ drawable: any CAMetalDrawable) -> (any MTLRenderCommandEncoder)? {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.setRenderPipelineState(gpu.presentPipeline(drawable.texture.pixelFormat))
        return enc
    }

    /// 原样画一帧。内容没变（暂停着）就不再画，屏上留着上一次的
    private func draw(single f: MotionFrame, drawable: any CAMetalDrawable) {
        let key = DrawKey(time: f.time, phi: 0, mode: 0, width: drawable.texture.width, height: drawable.texture.height)
        if key == lastDrawKey { return }
        var u = uniforms(phi: 0, mode: 0)
        guard let cb = gpu.drawQueue.makeCommandBuffer(), let enc = encoder(cb, drawable) else { return }
        for i in stride(from: 0, to: 10, by: 2) {
            enc.setFragmentTexture(f.y, index: i)
            enc.setFragmentTexture(f.c, index: i + 1)
        }
        enc.setFragmentBytes(&u, length: MemoryLayout<MFDraw>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        finish(cb, drawable, keep: [f], interpolated: false)
        lastDrawKey = key
    }

    private func finish(_ cb: any MTLCommandBuffer, _ drawable: any CAMetalDrawable, keep: [MotionFrame], interpolated: Bool) {
        let first = presented == 0
        presented += 1
        windowDraws += 1
        if interpolated { windowInterpolated += 1 }
        let kept = UncheckedBox(keep)
        let notify = first ? onFirstPresent : nil
        cb.addCompletedHandler { [weak self] cb in
            _ = kept
            let t = cb.gpuEndTime - cb.gpuStartTime
            if let notify { DispatchQueue.main.async { notify() } }
            guard t > 0 else { return }
            self?.post { [weak self] in
                guard let self else { return }
                self.statDraw = self.statDraw * 0.95 + t * 0.05
            }
        }
        cb.present(drawable)
        cb.commit()
    }

    private func uniforms(phi: Float, mode: Float) -> MFDraw {
        let rows = colorRows ?? Self.matrixRows(.bt709)
        let s: Float = source.tenBit ? 65535.0 / 65472.0 : 1
        let range: SIMD4<Float>
        if source.fullRange {
            range = SIMD4(s, 0, s, (source.tenBit ? 512.0 / 1023.0 : 128.0 / 255.0) / s)
        } else if source.tenBit {
            range = SIMD4(s * 1023.0 / 876.0, 64.0 / 1023.0 / s, s * 1023.0 / 896.0, 512.0 / 1023.0 / s)
        } else {
            range = SIMD4(255.0 / 219.0, 16.0 / 255.0, 255.0 / 224.0, 128.0 / 255.0)
        }
        return MFDraw(phase: SIMD4(phi, mode, showRoutes ? 1 : 0, 0),
                      uv: uvCrop,
                      gate: SIMD4(MotionTuning.gate.x, MotionTuning.gate.y, MotionTuning.contrastGain, MotionTuning.noiseFloor),
                      weights: SIMD4(MotionTuning.blendEdges.x, MotionTuning.blendEdges.y,
                                     MotionTuning.holdEdges.x, MotionTuning.holdEdges.y),
                      range: range, toR: rows.0, toG: rows.1, toB: rows.2)
    }

    private func rollWindow(_ host: CFTimeInterval) {
        let dt = host - windowStart
        guard dt >= 2 else { return }
        drawFPS = Double(windowDraws) / dt
        if fetched > 24, interval > 0, 1.5 / interval > Double(source.displayRate) {
            failure = "片源约 \(Int((1 / interval).rounded())) fps、屏幕 \(source.displayRate) Hz：无需插帧"
        }
        interpolatedShare = windowDraws > 0 ? Double(windowInterpolated) / Double(windowDraws) : 0
        neuralShare = windowPairs > 0 ? Double(windowNeural) / Double(windowPairs) : 0
        // 大半时间都在等分析：这台设备跟不上，再这样下去就放弃
        if windowPairs > 10, windowMisses * 10 > windowPairs * 6 {
            badWindows += 1
            if badWindows >= 4 { failure = "这台设备跟不上自研插帧，已改回原样播放" }
        } else {
            badWindows = 0
        }
        windowDraws = 0
        windowInterpolated = 0
        windowMisses = 0
        windowPairs = 0
        windowNeural = 0
        windowStart = host
    }

    // MARK: 颜色

    enum Matrix { case bt601, bt709, bt2020 }

    static func matrixRows(_ m: Matrix) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        switch m {
        case .bt601: return (SIMD4(1, 0, 1.402, 0), SIMD4(1, -0.344136, -0.714136, 0), SIMD4(1, 1.772, 0, 0))
        case .bt709: return (SIMD4(1, 0, 1.5748, 0), SIMD4(1, -0.187324, -0.468124, 0), SIMD4(1, 1.8556, 0, 0))
        case .bt2020: return (SIMD4(1, 0, 1.4746, 0), SIMD4(1, -0.164553, -0.571353, 0), SIMD4(1, 1.8814, 0, 0))
        }
    }

    private static func matrix(for buffer: CVPixelBuffer, source: Source) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        if let name = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String {
            if name == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return matrixRows(.bt2020) }
            if name == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) { return matrixRows(.bt601) }
            if name == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { return matrixRows(.bt709) }
        }
        if source.hdr { return matrixRows(.bt2020) }
        return matrixRows(source.height >= 720 || source.width >= 1280 ? .bt709 : .bt601)
    }

    // MARK: 切镜（CPU：48 × 27 的亮度取样）

    private static let thumbColumns = 48
    private static let thumbRows = 27

    private static func thumbnail(_ pb: CVPixelBuffer, tenBit: Bool) -> [UInt8]? {
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w > 0, h > 0 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: thumbColumns * thumbRows)
        for y in 0..<thumbRows {
            let yy = (y * 2 + 1) * h / (thumbRows * 2)
            for x in 0..<thumbColumns {
                let xx = (x * 2 + 1) * w / (thumbColumns * 2)
                // 10 bit：每个样本两个字节、小端，高字节就是高 8 位
                out[y * thumbColumns + x] = tenBit ? p[yy * row + xx * 2 + 1] : p[yy * row + xx]
            }
        }
        return out
    }

    /// 两帧的亮度分布差得多（直方图）且逐点也差得多：当作换了镜头。快速平移时逐点差很大但分布差不多，不算
    private static func isCut(_ la: [UInt8]?, _ lb: [UInt8]?) -> Bool {
        guard let la, let lb, la.count == lb.count, !la.isEmpty else { return false }
        var mad = 0
        var ha = [Int](repeating: 0, count: 16)
        var hb = [Int](repeating: 0, count: 16)
        for i in 0..<la.count {
            mad += abs(Int(la[i]) - Int(lb[i]))
            ha[Int(la[i] >> 4)] += 1
            hb[Int(lb[i] >> 4)] += 1
        }
        let n = Double(la.count)
        let meanDiff = Double(mad) / n
        var hd = 0
        for i in 0..<16 { hd += abs(ha[i] - hb[i]) }
        let histDiff = Double(hd) / n
        return (histDiff > 0.5 && meanDiff > 20) || meanDiff > 60
    }

    private static func cm(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }
}

/// 只在一个线程上用、但要穿过 @Sendable 闭包的东西
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

final class UncheckedTexture: @unchecked Sendable {
    let texture: any MTLTexture
    init(_ texture: any MTLTexture) { self.texture = texture }
}
