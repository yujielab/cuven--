import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import QuartzCore
import UIKit
import VideoToolbox
import os

// MARK: - 流畅插帧（系统自带的低延迟插帧：VideoToolbox VTFrameProcessor + VTLowLatencyFrameInterpolationConfiguration）
//
// 用户要求「系统自带插帧」，先做 1080p 及以下的普通画面（SDR）；4K、HDR、杜比视界照旧原样播。
//
// 做法：系统播放器照常播放（声音、进度、控件、画中画、隔空播放都是它的），画面另走一路：
//   AVPlayerItemVideoOutput 取解码好的帧（往前多取一两帧）
//     → 每两帧之间按屏幕刷新的时刻要几帧，交给系统的低延迟插帧
//     → 原帧 + 插出来的帧按时间送进 AVSampleBufferDisplayLayer（时基用播放器自己的，跟着暂停、拖动、缓冲）
//   这一层放在系统播放器的 contentOverlayView 里：盖在系统画面上面、控件下面。
//
// 插在哪：输出按屏幕刷新率排成等间隔的一串时刻（120 Hz 屏 1/120 秒一格，60 Hz 屏 1/60 秒），每一格算它落在前后两帧之间的哪个位置。
// 低延迟插帧只能插在 k / 2^n 处（numberOfInterpolatedFrames = n，这里 n = 3：1/8、2/8 … 7/8），所以就近取最近的那一点，
// 显示时刻仍是那一格：24 → 120 时内容位置最多差 1/16 帧（约 2.6 ms），看不出来。
//
// 镜头切换：前后两帧的亮度分布差得很多就当作切镜，这一对不插，前一半显示前一帧、后一半显示后一帧（不出两个镜头叠在一起的帧）。
//
// 跟不上时：插好的帧送出去时已经过了显示时刻，就把整串画面往后挪一格（最多约 66 ms）；还是来不及的那几格用原帧顶上。
// 画面时间往前走了却一直送不出帧、出错连着 5 次，就清掉这一层，下面的系统画面露出来（不会卡在一帧上）。
//
// 字幕：这一层盖住了系统画面，也就盖住了系统画的字幕。所以插帧开着时字幕由这里画（AVPlayerItemLegibleOutput，
// 同时让系统不画，免得两份）；插帧停下（半折、画中画、倍速、投屏、退到后台、出错）时把字幕交还给系统。
//
// 设置：账户页「播放」里的「流畅插帧」：关闭 / 开启 / 开启 · 显示诊断（左上角一块小字：系统上限、帧率、每次耗时、迟到次数）。

private let interpLog = Logger(subsystem: "us.cuven.tv", category: "interpolation")

@MainActor
private func ilog(_ s: String) {
    interpLog.info("\(s, privacy: .public)")
    Perf.file("interp: " + s)
}

enum FrameInterpolation {
    static let key = "frame_interpolation_v1"

    enum Mode: String, CaseIterable, Identifiable {
        case off, on, diagnostics
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "关闭"
            case .on: return "开启"
            case .diagnostics: return "开启 · 显示诊断"
            }
        }
    }

    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .off }

    /// numberOfInterpolatedFrames：可插的点是 k / 2^depth（depth = 3 → 1/8 … 7/8）
    static let depth = 3
    /// 这一版只给 1080p 及以下（横竖都算）
    static let maxLongSide = 1920
    static let maxPixels = 1920 * 1088

    static func fourCC(_ v: OSType) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        let s = String(bytes: bytes, encoding: .ascii) ?? ""
        return s.allSatisfy { $0.isASCII && !$0.isWhitespace } && s.count == 4 ? s : String(v)
    }

    static func rate(_ fps: Double) -> String {
        guard fps > 0 else { return "?" }
        let r = (fps * 1000).rounded() / 1000
        return r == r.rounded() ? String(Int(r)) : String(format: "%.3f", r)
    }
}

// MARK: - 引擎（自己的串行队列：取帧、插帧、送进显示层）

final class InterpolationEngine: @unchecked Sendable {
    struct Snapshot: Sendable {
        var sourceFPS: Double
        var outputFPS: Double
        var interpolatedPerSecond: Double
        var callMs: Double
        var delayMs: Double
        var late: Int
        var cuts: Int
        var errors: Int
        var stalls: Int
        var failure: String?
    }

    private struct Source {
        let buffer: CVPixelBuffer
        let time: Double
        /// 48 × 27 的亮度取样（切镜判断用；不是 8 bit 4:2:0 的格式没有）
        let luma: [UInt8]?
    }

    private enum Job {
        case single(Source)
        case pair(Source, Source)
    }

    /// 输出的一格：显示时刻和内容取哪里（0：前一帧原样；points：后一帧原样；其余：插在 k / points 处）
    private struct Target {
        let time: Double
        var k: Int
    }

    private struct Inflight {
        let a: Source
        let b: Source
        let targets: [Target]
        let buffers: [Int: CVPixelBuffer]
        let started: CFTimeInterval
        let generation: Int
    }

    private let queue = DispatchQueue(label: "us.cuven.tv.interpolation", qos: .userInteractive)
    private let output: AVPlayerItemVideoOutput
    private let renderer: AVSampleBufferVideoRenderer
    private let configuration: VTLowLatencyFrameInterpolationConfiguration
    private let processor = VTFrameProcessor()
    private let width: Int
    private let height: Int
    private let format: OSType
    /// 输出一格的长度（1 / 屏幕刷新率）
    private let step: Double
    private let points: Int
    /// 整串画面最多往后挪多少（再多口型就对不上了）
    private let maxDelay = 0.067

    private var pool: CVPixelBufferPool?
    private var sessionOpen = false
    private var paused = false
    private var failure: String?

    private var generation = 0
    private var previous: Source?
    private var lastFetched: Double?
    private var interval: Double
    private var anchor: Double?
    private var jobs: [Job] = []
    private var inflight: Inflight?
    private var busy = false
    private var delay = 0.0
    /// 最后送进显示层的那一帧的显示时刻（已含 delay）
    private var lastEnqueued: Double?
    private var consecutiveErrors = 0

    private var callMs = 0.0
    private var late = 0
    private var cuts = 0
    private var errors = 0
    private var stalls = 0
    private var windowStart = CACurrentMediaTime()
    private var windowEnqueued = 0
    private var windowInterpolated = 0
    private var outputFPS = 0.0
    private var interpolatedPerSecond = 0.0

    init(output: AVPlayerItemVideoOutput, renderer: AVSampleBufferVideoRenderer,
         configuration: VTLowLatencyFrameInterpolationConfiguration,
         width: Int, height: Int, format: OSType, displayRate: Int, sourceFPS: Double) {
        self.output = output
        self.renderer = renderer
        self.configuration = configuration
        self.width = width
        self.height = height
        self.format = format
        self.step = 1 / Double(max(displayRate, 30))
        self.points = 1 << FrameInterpolation.depth
        self.interval = sourceFPS > 1 ? 1 / sourceFPS : 1 / 24
    }

    // MARK: 对外（都排到自己的队列上）

    /// 载入插帧模型（可能比一帧长得多，所以不在主线程）；done 在这个队列上回调，nil 是成功
    func start(_ done: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                try self.processor.startSession(configuration: self.configuration)
                self.sessionOpen = true
                self.pool = self.makePool()
                if self.pool == nil {
                    self.processor.endSession()
                    self.sessionOpen = false
                    done("建不了插帧输出的缓冲区")
                } else {
                    done(nil)
                }
            } catch {
                done("插帧启动失败（\((error as NSError).code)）")
            }
        }
    }

    /// 屏幕每刷新一次叫一下：取新帧、排插帧
    func pump() {
        queue.async { self.tick() }
    }

    /// 暂停（半折、画中画、倍速、投屏、后台）：清掉这一层，露出系统画面；恢复时从当前位置重新接
    func setPaused(_ on: Bool) {
        queue.async {
            guard self.paused != on else { return }
            self.paused = on
            self.restart(clear: true)
        }
    }

    /// 进度跳了（拖动、从后台回来）
    func reset() {
        queue.async { self.restart(clear: true) }
    }

    func stop() {
        queue.async {
            self.restart(clear: true)
            if self.sessionOpen {
                self.processor.endSession()
                self.sessionOpen = false
            }
        }
    }

    func snapshot(_ done: @escaping @Sendable (Snapshot) -> Void) {
        queue.async {
            done(Snapshot(sourceFPS: self.interval > 0 ? 1 / self.interval : 0, outputFPS: self.outputFPS,
                          interpolatedPerSecond: self.interpolatedPerSecond, callMs: self.callMs,
                          delayMs: self.delay * 1000, late: self.late, cuts: self.cuts, errors: self.errors,
                          stalls: self.stalls, failure: self.failure))
        }
    }

    // MARK: 取帧

    private func currentItemTime() -> Double? {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        return t.isNumeric ? t.seconds : nil
    }

    private func tick() {
        guard sessionOpen, !paused, failure == nil else { return }
        let host = CACurrentMediaTime()
        rollWindow(host)
        guard let now = currentItemTime() else { return }

        // 插帧一直没回来（不该发生）：当作出错，接着往下走
        if busy, let f = inflight, host - f.started > 1.0 {
            busy = false
            inflight = nil
            errors += 1
            consecutiveErrors += 1
            if consecutiveErrors >= 5 { fail("插帧没有响应"); return }
            startNext()
        }

        // 进度跳了：从当前位置重新接
        if let lf = lastFetched, now - lf > 1.0 || lf - now > 1.5 {
            restart(clear: true)
        }

        // 画面时间往前走了，这一层却一直没有新帧：清掉，露出系统画面，从当前位置重新接
        if let last = lastEnqueued, now - (last - delay) > 0.75 {
            stalls += 1
            restart(clear: true)
            if stalls > 8 { fail("一直跟不上，已改回原样播放"); return }
        }

        var taken = 0
        while taken < 8 {
            var probe = now
            if let lf = lastFetched {
                // 下一帧大约在 lf + interval：问 lf + 1.5 个间隔，正好拿到下一帧、不跳帧；落后了就直接追到现在
                probe = max(lf + interval * 1.5, now)
                if probe > now + 0.15 { break }
            }
            let pt = CMTime(seconds: probe, preferredTimescale: 1_000_000)
            guard output.hasNewPixelBuffer(forItemTime: pt) else { break }
            var shown = CMTime.invalid
            guard let pb = output.copyPixelBuffer(forItemTime: pt, itemTimeForDisplay: &shown) else { break }
            taken += 1
            accept(pb, at: shown.isNumeric ? shown.seconds : probe)
        }
    }

    private func accept(_ buffer: CVPixelBuffer, at time: Double) {
        let src = Source(buffer: buffer, time: time, luma: Self.luma(buffer))
        guard let prev = previous else {
            begin(src)
            startNext()
            return
        }
        let gap = time - prev.time
        if gap <= 0.0005 {
            // 往回跳了一大截（拖回去）：从这一帧重新接；同一帧再来一次：不管
            if gap < -0.05 {
                restart(clear: true)
                begin(src)
                startNext()
            }
            return
        }
        lastFetched = time
        previous = src
        if gap > 0.25 {
            // 中间断了（缓冲、丢了一段）：不跨着插，从这一帧重新排格子
            anchor = time
            jobs.append(.single(src))
        } else {
            interval = interval * 0.9 + gap * 0.1
            jobs.append(.pair(prev, src))
        }
        startNext()
    }

    private func begin(_ src: Source) {
        previous = src
        lastFetched = src.time
        anchor = src.time
        jobs.append(.single(src))
    }

    private func restart(clear: Bool) {
        generation += 1
        jobs.removeAll()
        previous = nil
        lastFetched = nil
        anchor = nil
        lastEnqueued = nil
        renderer.flush(removingDisplayedImage: clear, completionHandler: nil)
    }

    private func fail(_ why: String) {
        failure = why
        restart(clear: true)
        if sessionOpen {
            processor.endSession()
            sessionOpen = false
        }
    }

    // MARK: 插帧

    private func startNext() {
        while !busy, !jobs.isEmpty {
            switch jobs.removeFirst() {
            case .single(let s):
                emit(s.buffer, at: s.time, propagatingFrom: nil)
            case .pair(let a, let b):
                run(a, b)
            }
        }
    }

    private func run(_ a: Source, _ b: Source) {
        let span = b.time - a.time
        guard let anchor, span > 0 else {
            emit(b.buffer, at: b.time, propagatingFrom: nil)
            return
        }
        // 落在 [a, b) 里的输出格
        var targets: [Target] = []
        var j = ((a.time - anchor) / step - 1e-3).rounded(.up)
        while targets.count < 64 {
            let t = anchor + j * step
            if t >= b.time - step * 1e-3 { break }
            let k = Int(((t - a.time) / span * Double(points)).rounded())
            targets.append(Target(time: t, k: min(max(k, 0), points)))
            j += 1
        }
        guard !targets.isEmpty else { return }

        func nearest(_ k: Int) -> Int { k * 2 < points ? 0 : points }

        // 切镜：这一对不插
        if isCut(a, b) {
            cuts += 1
            for i in targets.indices { targets[i].k = nearest(targets[i].k) }
        }

        // 算完就过了显示时刻的格：用原帧顶上，整串往后挪一格
        if let now = currentItemTime() {
            let ready = now + callMs / 1000 * 1.5 + 0.003
            var lateHere = false
            for i in targets.indices where targets[i].k > 0 && targets[i].k < points && targets[i].time + delay < ready {
                targets[i].k = nearest(targets[i].k)
                lateHere = true
            }
            if lateHere {
                late += 1
                bumpDelay()
            }
        }

        let ks = Array(Set(targets.map(\.k).filter { $0 > 0 && $0 < points })).sorted()
        guard !ks.isEmpty, let pool else {
            for t in targets { emit(t.k * 2 < points ? a.buffer : b.buffer, at: t.time, propagatingFrom: nil) }
            return
        }

        var buffers: [Int: CVPixelBuffer] = [:]
        var destinations: [VTFrameProcessorFrame] = []
        for k in ks {
            var pb: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess, let pb,
                  let frame = VTFrameProcessorFrame(buffer: pb, presentationTimeStamp: Self.cm(a.time + span * Double(k) / Double(points)))
            else {
                for t in targets { emit(t.k * 2 < points ? a.buffer : b.buffer, at: t.time, propagatingFrom: nil) }
                return
            }
            buffers[k] = pb
            destinations.append(frame)
        }
        guard let previousFrame = VTFrameProcessorFrame(buffer: a.buffer, presentationTimeStamp: Self.cm(a.time)),
              let sourceFrame = VTFrameProcessorFrame(buffer: b.buffer, presentationTimeStamp: Self.cm(b.time)),
              let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: sourceFrame, previousFrame: previousFrame,
                                                                        interpolationPhase: ks.map { Float($0) / Float(points) },
                                                                        destinationFrames: destinations)
        else {
            for t in targets { emit(t.k * 2 < points ? a.buffer : b.buffer, at: t.time, propagatingFrom: nil) }
            return
        }

        busy = true
        let gen = generation
        inflight = Inflight(a: a, b: b, targets: targets, buffers: buffers, started: CACurrentMediaTime(), generation: gen)
        processor.process(parameters: parameters) { [weak self] _, error in
            let code = error.map { ($0 as NSError).code }
            guard let self else { return }
            self.queue.async { self.finish(gen, errorCode: code) }
        }
    }

    private func finish(_ gen: Int, errorCode: Int?) {
        busy = false
        guard let job = inflight, job.generation == gen, gen == generation else {
            if inflight?.generation == gen { inflight = nil }
            startNext()
            return
        }
        inflight = nil
        let ms = (CACurrentMediaTime() - job.started) * 1000
        callMs = callMs == 0 ? ms : callMs * 0.9 + ms * 0.1
        if let errorCode {
            errors += 1
            consecutiveErrors += 1
            if consecutiveErrors >= 5 { fail("插帧出错（\(errorCode)），已改回原样播放"); return }
        } else {
            consecutiveErrors = 0
            windowInterpolated += job.buffers.count
            for pb in job.buffers.values { CVBufferPropagateAttachments(job.a.buffer, pb) }
        }
        for t in job.targets {
            if t.k == 0 {
                emit(job.a.buffer, at: t.time, propagatingFrom: nil)
            } else if t.k == points {
                emit(job.b.buffer, at: t.time, propagatingFrom: nil)
            } else if errorCode == nil, let pb = job.buffers[t.k] {
                emit(pb, at: t.time, propagatingFrom: nil)
            } else {
                emit(t.k * 2 < points ? job.a.buffer : job.b.buffer, at: t.time, propagatingFrom: nil)
            }
        }
        startNext()
    }

    private func bumpDelay() {
        delay = min(maxDelay, delay + step)
    }

    // MARK: 送进显示层

    private func emit(_ buffer: CVPixelBuffer, at time: Double, propagatingFrom source: CVPixelBuffer?) {
        let shown = time + delay
        if let last = lastEnqueued, shown <= last + 0.0005 { return }
        if let source { CVBufferPropagateAttachments(source, buffer) }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &description) == noErr,
              let description else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: step, preferredTimescale: 1_000_000),
                                        presentationTimeStamp: Self.cm(shown), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                       formatDescription: description, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        renderer.enqueue(sample)
        lastEnqueued = shown
        windowEnqueued += 1
        // 送进去时已经过了显示时刻：以后整串多留一格
        if let now = currentItemTime(), shown < now {
            late += 1
            bumpDelay()
        }
    }

    private func rollWindow(_ host: CFTimeInterval) {
        let dt = host - windowStart
        guard dt >= 1 else { return }
        outputFPS = Double(windowEnqueued) / dt
        interpolatedPerSecond = Double(windowInterpolated) / dt
        windowEnqueued = 0
        windowInterpolated = 0
        windowStart = host
    }

    private func makePool() -> CVPixelBufferPool? {
        var attrs: [String: Any] = [:]
        for (k, v) in configuration.destinationPixelBufferAttributes { attrs[k] = v }
        attrs[kCVPixelBufferPixelFormatTypeKey as String] = format
        attrs[kCVPixelBufferWidthKey as String] = width
        attrs[kCVPixelBufferHeightKey as String] = height
        if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 8]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool) == kCVReturnSuccess
        else { return nil }
        return pool
    }

    private static func cm(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }

    // MARK: 切镜

    private static let lumaColumns = 48
    private static let lumaRows = 27

    private static func luma(_ pb: CVPixelBuffer) -> [UInt8]? {
        let f = CVPixelBufferGetPixelFormatType(pb)
        guard f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w > 0, h > 0 else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: lumaColumns * lumaRows)
        for y in 0..<lumaRows {
            let yy = (y * 2 + 1) * h / (lumaRows * 2)
            for x in 0..<lumaColumns {
                let xx = (x * 2 + 1) * w / (lumaColumns * 2)
                out[y * lumaColumns + x] = p[yy * row + xx]
            }
        }
        return out
    }

    /// 两帧的亮度分布差得多（直方图）且逐点也差得多：当作换了镜头。快速平移时逐点差很大但分布差不多，不算
    private func isCut(_ a: Source, _ b: Source) -> Bool {
        guard let la = a.luma, let lb = b.luma, la.count == lb.count, !la.isEmpty else { return false }
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
        let histDiff = Double(hd) / n          // 0…2
        return (histDiff > 0.5 && meanDiff > 20) || meanDiff > 60
    }
}

// MARK: - 叠在系统画面上的那一层（主线程）

/// 显示层 + 字幕 + 诊断小字
private final class InterpolationRootView: UIView {
    final class VideoView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    let video = VideoView()
    let subtitle = UILabel()
    let hudBox = UIView()
    let hud = UILabel()
    /// 画面的原始尺寸（字幕排在画面里靠下）
    var videoSize: CGSize = .zero { didSet { if videoSize != oldValue { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        video.backgroundColor = .clear
        video.displayLayer.videoGravity = .resizeAspect
        addSubview(video)

        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center
        subtitle.textColor = .white
        subtitle.layer.shadowColor = UIColor.black.cgColor
        subtitle.layer.shadowOpacity = 0.9
        subtitle.layer.shadowRadius = 3
        subtitle.layer.shadowOffset = CGSize(width: 0, height: 1)
        subtitle.isHidden = true
        addSubview(subtitle)

        hudBox.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hudBox.layer.cornerRadius = 8
        hudBox.layer.cornerCurve = .continuous
        hudBox.isHidden = true
        hud.numberOfLines = 0
        hud.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hud.textColor = UIColor.white.withAlphaComponent(0.92)
        hudBox.addSubview(hud)
        addSubview(hudBox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSubtitle(_ text: String?) {
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        subtitle.text = (t?.isEmpty ?? true) ? nil : t
        subtitle.isHidden = subtitle.text == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        video.frame = bounds

        let rect = videoSize.width > 0 && videoSize.height > 0 ? AVMakeRect(aspectRatio: videoSize, insideRect: bounds) : bounds
        let fontSize = max(15, min(34, rect.height * 0.052))
        if subtitle.font.pointSize != fontSize { subtitle.font = .systemFont(ofSize: fontSize, weight: .semibold) }
        let maxWidth = rect.width * 0.9
        let fit = subtitle.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let bottom = min(rect.maxY, bounds.maxY - safeAreaInsets.bottom) - rect.height * 0.06
        subtitle.frame = CGRect(x: rect.midX - min(fit.width, maxWidth) / 2, y: bottom - fit.height,
                                width: min(fit.width, maxWidth), height: fit.height)

        let pad: CGFloat = 8
        let hudFit = hud.sizeThatFits(CGSize(width: bounds.width * 0.6, height: .greatestFiniteMagnitude))
        hudBox.frame = CGRect(x: safeAreaInsets.left + 12, y: safeAreaInsets.top + 12,
                              width: hudFit.width + pad * 2, height: hudFit.height + pad * 2)
        hud.frame = CGRect(x: pad, y: pad, width: hudFit.width, height: hudFit.height)
    }
}

/// 计时器、刷新回调的 target（不让它们反过来留住整层）
@MainActor
private final class InterpolationTicker: NSObject {
    weak var owner: FrameInterpolationOverlay?
    init(owner: FrameInterpolationOverlay) { self.owner = owner }
    @objc func displayTick() { owner?.displayTick() }
    @objc func refreshTick() { owner?.refresh() }
}

/// 系统画的字幕被这一层盖住：插帧开着时字幕从这里拿、在这里画
private final class LegibleRelay: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var onText: (@MainActor (String?) -> Void)?

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).joined(separator: "\n")
        MainActor.assumeIsolated { self.onText?(text) }
    }
}

@MainActor
final class FrameInterpolationOverlay {
    private let root = InterpolationRootView()
    private lazy var ticker = InterpolationTicker(owner: self)
    private let legibleRelay = LegibleRelay()

    /// 现在接着的播放器（半折时系统播放器那一层放开了播放器，但这里仍拿得到）
    var player: () -> AVPlayer? = { nil }
    /// 系统播放器的画面怎么放（双击放大）：显示层跟着
    var gravity: () -> AVLayerVideoGravity = { .resizeAspect }

    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var legible: AVPlayerItemLegibleOutput?
    private var engine: InterpolationEngine?
    private var starting = false
    private var running = false
    private var engineBlocked = false
    private var link: CADisplayLink?
    private var timer: Timer?
    private var itemObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []

    private var sourceInfo: HLSVideoInfo?
    private var nameSaysHDR = false
    private var suspended = false
    private var pictureInPicture = false
    private var inBackground = false

    /// 这一集已经定了不插（原因在 status）
    private var decided = false
    private var status = "等待片源"
    private var header = ""
    private var formatsLine = ""
    private var snapshot: InterpolationEngine.Snapshot?
    private var lastLogged = ""

    func install(in container: UIView) {
        root.frame = container.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(root)
        legibleRelay.onText = { [weak self] text in self?.root.setSubtitle(text) }
    }

    /// 播放器弹出来（含画中画还原）：开始看片源
    func activate() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: ticker, selector: #selector(InterpolationTicker.refreshTick),
                                     userInfo: nil, repeats: true)
        let nc = NotificationCenter.default
        appObservers = [
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.inBackground = true
                    self?.refresh()
                }
            },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.inBackground = false
                    self?.engine?.reset()
                    self?.refresh()
                }
            },
        ]
        refresh()
    }

    /// 播放器收起：全部停掉（再弹出来时 activate 重新开始）
    func shutdown() {
        tearDown()
        timer?.invalidate()
        timer = nil
        for o in appObservers { NotificationCenter.default.removeObserver(o) }
        appObservers = []
        if let itemObserver { NotificationCenter.default.removeObserver(itemObserver) }
        itemObserver = nil
        item = nil
        decided = false
        pictureInPicture = false
        inBackground = false
    }

    /// 点了播放 / 换了一集：先按文件名判断（「杜比视界」「HDR」）；服务器的 info.json 晚一点来
    func prepare(name: String) {
        nameSaysHDR = FileName.specs(name).contains { $0 == "杜比视界" || $0.hasPrefix("HDR") }
        sourceInfo = nil
    }

    func setInfo(_ info: HLSVideoInfo?) {
        sourceInfo = info
    }

    /// 半折时画面在面板那一层：这里停下
    func setSuspended(_ on: Bool) {
        suspended = on
        refresh()
    }

    func setPictureInPicture(_ on: Bool) {
        pictureInPicture = on
        refresh()
    }

    // MARK: 节拍

    fileprivate func displayTick() {
        engine?.pump()
        let g = gravity()
        if root.video.displayLayer.videoGravity != g { root.video.displayLayer.videoGravity = g }
    }

    fileprivate func refresh() {
        let mode = FrameInterpolation.mode
        let current = player()?.currentItem
        if current !== item { switchItem(to: current) }

        if mode == .off {
            if engine != nil { tearDown() }
            decided = false
            status = "已关闭"
            updateHUD(mode)
            return
        }

        if let engine {
            let p = player()
            let rate = p?.rate ?? 0
            let speedChanged = rate != 0 && abs(rate - 1) > 0.01
            let blocked = suspended || pictureInPicture || inBackground || p?.isExternalPlaybackActive == true || speedChanged
            if running, blocked != engineBlocked {
                engineBlocked = blocked
                engine.setPaused(blocked)
                setLegible(!blocked)
            }
            if running {
                status = blocked ? "暂停（\(Self.blockReason(suspended: suspended, pip: pictureInPicture, background: inBackground, speed: speedChanged))）" : "插帧中"
            }
            engine.snapshot { snap in
                Task { @MainActor [weak self] in self?.received(snap, from: engine) }
            }
        } else if !decided {
            decide()
        }
        root.videoSize = item?.presentationSize ?? .zero
        updateHUD(mode)
    }

    private static func blockReason(suspended: Bool, pip: Bool, background: Bool, speed: Bool) -> String {
        if suspended { return "半折" }
        if pip { return "画中画" }
        if background { return "后台" }
        if speed { return "倍速" }
        return "投屏"
    }

    private func received(_ snap: InterpolationEngine.Snapshot, from e: InterpolationEngine) {
        guard e === engine else { return }
        snapshot = snap
        if let failure = snap.failure {
            tearDown()
            verdict(failure)
        }
    }

    private func switchItem(to current: AVPlayerItem?) {
        tearDown()
        if let itemObserver { NotificationCenter.default.removeObserver(itemObserver) }
        itemObserver = nil
        item = current
        decided = false
        status = "等待片源"
        header = ""
        formatsLine = ""
        if let current {
            itemObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: current,
                                                                  queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.engine?.reset() }
            }
        }
    }

    // MARK: 这一集插不插

    private func decide() {
        guard let item, item.status == .readyToPlay else { status = "等待片源"; return }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else { verdict("这台设备不支持系统插帧"); return }
        if nameSaysHDR || Self.infoSaysHDR(sourceInfo) { verdict("HDR / 杜比视界：原样播放"); return }
        let formats = Self.videoFormats(item)
        guard !formats.isEmpty else { status = "等待视频格式"; return }
        if formats.contains(where: Self.isHDRFormat) { verdict("HDR / 杜比视界：原样播放"); return }

        let size = item.presentationSize
        var w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { status = "等待画面尺寸"; return }
        w -= w % 2
        h -= h % 2
        guard max(w, h) <= FrameInterpolation.maxLongSide, w * h <= FrameInterpolation.maxPixels else {
            verdict("\(w)×\(h) 超过 1080p：原样播放")
            return
        }
        if let md = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1),
           let mp = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1),
           max(w, h) > md || w * h > mp {
            verdict("超出系统插帧上限：\(w)×\(h)")
            return
        }
        let rate = displayRate()
        let fps = Double(Self.videoTrack(item)?.nominalFrameRate ?? 0)
        if fps > 0, fps * 1.5 > Double(rate) {
            verdict("片源 \(FrameInterpolation.rate(fps)) fps、屏幕 \(rate) Hz：无需插帧")
            return
        }
        guard let timebase = item.timebase else { status = "等待时基"; return }
        guard let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h,
                                                                       numberOfInterpolatedFrames: FrameInterpolation.depth) else {
            verdict("系统插帧不接受 \(w)×\(h)")
            return
        }
        let supported = config.supportedPixelFormats
        let preferred: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        guard let format = preferred.first(where: { supported.contains($0) }) ?? supported.first else {
            verdict("系统插帧没有可用的像素格式")
            return
        }
        formatsLine = "可用格式 " + supported.map(FrameInterpolation.fourCC).joined(separator: " ")

        var attrs: [String: any Sendable] = [:]
        for (k, v) in config.sourcePixelBufferAttributes { attrs[k] = v }
        attrs[kCVPixelBufferPixelFormatTypeKey as String] = format
        attrs[kCVPixelBufferWidthKey as String] = w
        attrs[kCVPixelBufferHeightKey as String] = h
        if attrs[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: any Sendable]()
        }
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        out.suppressesPlayerRendering = false
        item.add(out)
        output = out

        let layer = root.video.displayLayer
        layer.controlTimebase = timebase
        let e = InterpolationEngine(output: out, renderer: layer.sampleBufferRenderer, configuration: config,
                                    width: w, height: h, format: format, displayRate: rate, sourceFPS: fps)
        engine = e
        starting = true
        running = false
        engineBlocked = false
        snapshot = nil
        header = "\(w)×\(h) · \(FrameInterpolation.fourCC(format)) · 屏幕 \(rate) Hz"
        status = "正在载入插帧模型"
        ilog("start \(w)x\(h) \(FrameInterpolation.fourCC(format)) source \(FrameInterpolation.rate(fps)) fps, display \(rate) Hz; \(formatsLine)")
        e.start { error in
            Task { @MainActor [weak self] in self?.started(e, error: error) }
        }
    }

    private func started(_ e: InterpolationEngine, error: String?) {
        guard e === engine else { return }
        starting = false
        if let error {
            tearDown()
            verdict(error)
            return
        }
        running = true
        status = "插帧中"
        setLegible(true)
        startLink(rate: displayRate())
        refresh()
    }

    private func verdict(_ why: String) {
        decided = true
        status = why
        if why != lastLogged {
            lastLogged = why
            ilog(why)
        }
    }

    private func tearDown() {
        link?.invalidate()
        link = nil
        engine?.stop()
        engine = nil
        starting = false
        running = false
        engineBlocked = false
        if let output, let item, item.outputs.contains(where: { $0 === output }) { item.remove(output) }
        output = nil
        setLegible(false)
        root.video.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        snapshot = nil
    }

    private func setLegible(_ on: Bool) {
        if on, legible == nil, let item {
            let l = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
            l.suppressesPlayerRendering = true
            l.setDelegate(legibleRelay, queue: .main)
            item.add(l)
            legible = l
        } else if !on, let l = legible {
            if let item, item.outputs.contains(where: { $0 === l }) { item.remove(l) }
            legible = nil
            root.setSubtitle(nil)
        }
    }

    private func startLink(rate: Int) {
        link?.invalidate()
        let l = CADisplayLink(target: ticker, selector: #selector(InterpolationTicker.displayTick))
        let r = Float(rate)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: r, maximum: r, preferred: r)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func displayRate() -> Int {
        let r = root.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        return r > 0 ? r : 60
    }

    // MARK: 诊断小字

    private func updateHUD(_ mode: FrameInterpolation.Mode) {
        guard mode == .diagnostics else {
            if !root.hudBox.isHidden { root.hudBox.isHidden = true }
            return
        }
        let llfi = VTLowLatencyFrameInterpolationConfiguration.self
        var lines = ["流畅插帧 · \(status)"]
        if llfi.isSupported {
            let md = llfi.maximumDimension(forSpatialScaleFactor: 1).map { String($0) } ?? "?"
            let mp = llfi.maximumPixelCount(forSpatialScaleFactor: 1).map { String($0) } ?? "?"
            lines.append("系统上限 最长边 \(md) · 最多 \(mp) 像素")
        } else {
            lines.append("低延迟插帧：不支持")
        }
        lines.append("全质量帧率转换：\(VTFrameRateConversionConfiguration.isSupported ? "支持" : "不支持")")
        if !header.isEmpty { lines.append(header) }
        if !formatsLine.isEmpty { lines.append(formatsLine) }
        if let s = snapshot, running {
            lines.append("片源 \(FrameInterpolation.rate(s.sourceFPS)) → 输出 \(Int(s.outputFPS.rounded())) fps · 每秒插 \(Int(s.interpolatedPerSecond.rounded())) 帧")
            lines.append(String(format: "每次 %.1f ms · 延后 %ld ms", s.callMs, Int(s.delayMs.rounded())))
            lines.append("迟到 \(s.late) · 切镜 \(s.cuts) · 出错 \(s.errors) · 重接 \(s.stalls)")
        }
        let text = lines.joined(separator: "\n")
        if root.hud.text != text {
            root.hud.text = text
            root.setNeedsLayout()
        }
        root.hudBox.isHidden = false
    }

    // MARK: 片源格式

    private static func infoSaysHDR(_ info: HLSVideoInfo?) -> Bool {
        guard let info else { return false }
        let range = (info.range ?? "").uppercased()
        return info.dvProfile != nil || range == "PQ" || range == "HLG" || range.contains("HDR")
    }

    private static func videoTrack(_ item: AVPlayerItem) -> AVAssetTrack? {
        item.tracks.compactMap(\.assetTrack).first { $0.mediaType == .video }
    }

    /// 播放器轨道上的格式（同步的旧接口：播放器的轨道已经载好了）
    private static func videoFormats(_ item: AVPlayerItem) -> [CMFormatDescription] {
        item.tracks.compactMap(\.assetTrack)
            .filter { $0.mediaType == .video }
            .flatMap { $0.formatDescriptions.map { $0 as! CMFormatDescription } }
    }

    /// PQ / HLG 传递函数，或杜比视界的编码类型
    private static func isHDRFormat(_ fd: CMFormatDescription) -> Bool {
        let dolbyVision: Set<FourCharCode> = [0x6476_6831, 0x6476_6865, 0x6476_6131, 0x6476_6176]   // dvh1 dvhe dva1 dvav
        if dolbyVision.contains(CMFormatDescriptionGetMediaSubType(fd)) { return true }
        if let transfer = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
            return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
                || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        }
        return false
    }
}
