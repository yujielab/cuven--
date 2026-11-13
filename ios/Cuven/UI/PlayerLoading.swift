import SwiftUI
import UIKit
import AVKit
import MetalKit

// MARK: - 播放加载画面：和网页版一样（web/index.html 的 .np-load + Aurora）
//
// 点「播放」到真正开播之间，盖在系统播放器的画面层上（contentOverlayView，系统的关闭钮等控件在它上面，照常能点）：
// · 背景：复刻 Framer「Aurora Flow」的极光（网页版同一份着色器、同一组参数：底色 rgb(10,9,15)、
//   颜色 rgb(46,85,242) / rgb(133,231,255)、角度 −119°、尺寸 114%、速度 50、内部分辨率 25%）；
//   着色器在运行时编译（不需要编译机装 Metal 工具链），没有 Metal 或编译失败就退回网页版自带的三团径向渐变。
// · 居中「Cuven / max」字标（圆体，max 粗而大），整组上移 3% 屏高。
// · iOS 更新式的胶囊进度条：按真实阶段推进 —— 拿到片源 → 元数据 → 首批数据 → 可以播 → 开播，
//   阶段之间缓缓爬升（不倒退，开播前不走满）；后三段读系统播放器那一项的状态（网页版 loadedmetadata / loadeddata / canplay）。
// · 下面一句句文案，2.4 秒换一句：先模糊消散（0.52 秒），再换字、从模糊里进来；十句轮完还没开播就如实说网络慢。
// · 开播：进度条走满，0.26 秒后 0.46 秒淡出；淡完停掉显示链接与 GPU（留给 4K / HDR 解码）。

final class PlayerLoadingCover: UIView {
    /// 网页版 TIPS，一字不差
    nonisolated static let tips = ["请保持屏幕亮起", "正在渲染绚烂颜色", "正在预热画面质量", "正在添加全景声系统", "正在为您的设备优化",
                       "正在量身定制体验", "正为您添加动态字幕", "一切几乎就绪", "还需要一小会", "即将完成"]
    /// 十句都轮完了（约 24 秒）还没开播：不再停在「即将完成」
    nonisolated static let slowTip = "网络较慢，正在为您缓冲"
    static let ink = UIColor(red: 10 / 255, green: 9 / 255, blue: 15 / 255, alpha: 1)

    /// 网页版 STAGE：这一段从哪起、最多爬到哪
    private enum Stage {
        static let open: (Double, Double) = (0.04, 0.2)
        static let source: (Double, Double) = (0.18, 0.4)
        static let meta: (Double, Double) = (0.4, 0.64)
        static let data: (Double, Double) = (0.62, 0.82)
        static let ready: (Double, Double) = (0.8, 0.94)
        static let play: (Double, Double) = (1, 1)
    }
    private static let tipEvery: CFTimeInterval = 2.4
    private static let tipSwap: CFTimeInterval = 0.52

    private let aurora = AuroraView()
    private let fallback = AuroraFallbackView()
    private let state = PlayerLoadingState()
    private var host: UIHostingController<PlayerLoadingOverlay>?
    private var link: CADisplayLink?

    private var running = false
    private var finishing = false
    // 进度条（网页版 ld：p 当前、base / cap 这一段的起止、stageAt 进这一段的时刻）
    private var p: Double = 0
    private var base: Double = 0
    private var cap: Double = 0
    private var stageAt: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var probeAt: CFTimeInterval = 0
    // 文案
    private var tipIndex = 0
    private var tipAt: CFTimeInterval = 0
    private var swapAt: CFTimeInterval?
    private var enterAt: CFTimeInterval?
    private var pendingTip: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.ink
        isUserInteractionEnabled = false
        for v in [fallback, aurora] as [UIView] {
            v.frame = bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(v)
        }
        fallback.isHidden = aurora.available
        aurora.onUnavailable = { [weak self] in self?.fallback.isHidden = false }

        let h = UIHostingController(rootView: PlayerLoadingOverlay(state: state))
        h.view.backgroundColor = .clear
        h.view.isUserInteractionEnabled = false
        h.safeAreaRegions = []
        h.view.frame = bounds
        h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(h.view)
        host = h
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 片名只给读屏用（网页版的加载画面上没有片名与剧照）
    func configure(title: String, artwork: URL?) {
        state.title = title
    }

    func setPhase(_ phase: CuvenPlayerViewController.Phase) {
        switch phase {
        case .preparing:
            show()
            stage(Stage.open)
        case .buffering:
            if !running || finishing { show(); stage(Stage.open) }   // 兜底弹出的那条路没经过 preparing
            stage(Stage.source)
        case .playing:
            done()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopLink() } else if running { startLink() }
    }

    // MARK: 显示 / 开播 / 停

    private func show() {
        layer.removeAllAnimations()
        finishing = false
        running = true
        isHidden = false
        alpha = 1
        p = 0; base = 0; cap = 0
        stageAt = CACurrentMediaTime()
        last = 0
        probeAt = 0
        tipIndex = 0
        tipAt = stageAt
        swapAt = nil; enterAt = nil; pendingTip = nil
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            state.progress = 0
            state.tip = Self.tips[0]
            state.tipPhase = .shown
        }
        aurora.restart()
        startLink()
    }

    /// 开播：进度条走满再淡出（系统播放器这时已经在出画面）
    private func done() {
        guard running else { isHidden = true; return }
        guard !finishing else { return }
        stage(Stage.play)
        finishing = true
        swapAt = nil; enterAt = nil; pendingTip = nil
        UIView.animate(withDuration: 0.46, delay: 0.26, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.alpha = 0
        } completion: { [weak self] finished in
            guard let self, finished, self.finishing else { return }
            self.stopAll()
        }
    }

    private func stopAll() {
        stopLink()
        running = false
        finishing = false
        isHidden = true
        swapAt = nil; enterAt = nil; pendingTip = nil
    }

    private func stage(_ s: (Double, Double)) {
        guard running, s.0 > base else { return }
        base = s.0
        cap = s.1
        stageAt = CACurrentMediaTime()
    }

    private func startLink() {
        guard link == nil, window != nil else { return }
        let l = CADisplayLink(target: LoadingLinkProxy(self), selector: #selector(LoadingLinkProxy.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    // MARK: 每一帧

    fileprivate func step(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = last > 0 ? min(0.1, now - last) : 0
        last = now
        aurora.advance(dt)

        // 后三段：读系统播放器那一项（四分之一秒看一次）
        if !finishing && base >= Stage.source.0 && now - probeAt > 0.25 {
            probeAt = now
            probe()
        }

        // 网页版 barFrame：这一段的目标按 2.6 秒的指数慢慢逼近上限；当前值再平滑地追目标（开播后追得快）
        let goal = base + (cap - base) * (1 - exp(-max(0, now - stageAt) / 2.6))
        p += (goal - p) * (1 - exp(-dt * (base >= 1 ? 14 : 5)))
        state.progress = p

        guard !finishing else { return }
        if let at = enterAt, now >= at {
            enterAt = nil
            withAnimation(Self.tipCurve) { state.tipPhase = .shown }
        }
        if let at = swapAt, now >= at { swapTip(now) }
        if now - tipAt >= Self.tipEvery {
            tipAt += Self.tipEvery
            nextTip(now)
        }
    }

    private static let tipCurve = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.52)

    /// 先模糊消散
    private func nextTip(_ now: CFTimeInterval) {
        let text: String
        if tipIndex >= Self.tips.count - 1 {
            if state.tip == Self.slowTip || pendingTip == Self.slowTip { return }
            text = Self.slowTip
        } else {
            tipIndex += 1
            text = Self.tips[tipIndex]
        }
        pendingTip = text
        withAnimation(Self.tipCurve) { state.tipPhase = .leaving }
        swapAt = now + Self.tipSwap
    }

    /// 换字：先落在模糊态（不带动画），隔两帧再过渡到清晰
    private func swapTip(_ now: CFTimeInterval) {
        swapAt = nil
        guard let text = pendingTip else { return }
        pendingTip = nil
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            state.tip = text
            state.tipPhase = .entering
        }
        enterAt = now + 0.03
    }

    /// 系统播放器那一项走到哪了：可以播（且缓冲够）→ 有了首批数据 → 有了元数据
    private func probe() {
        guard let item = currentItem else { return }
        if item.status == .readyToPlay && item.isPlaybackLikelyToKeepUp {
            stage(Stage.ready)
        } else if !item.loadedTimeRanges.isEmpty {
            stage(Stage.data)
        } else if item.status == .readyToPlay || item.duration.isNumeric {
            stage(Stage.meta)
        }
    }

    /// 顺着响应链找到盖着的那台系统播放器
    private var currentItem: AVPlayerItem? {
        var r: UIResponder? = self
        while let cur = r {
            if let vc = cur as? AVPlayerViewController { return vc.player?.currentItem }
            r = cur.next
        }
        return nil
    }
}

/// CADisplayLink 会强引用 target：经一层弱引用转一下，加载画面本身跟着页面释放；目标没了就自己停
@MainActor
private final class LoadingLinkProxy: NSObject {
    weak var target: PlayerLoadingCover?

    init(_ target: PlayerLoadingCover) {
        self.target = target
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let t = target else { link.invalidate(); return }
        t.step(link)
    }
}

// MARK: - 字标、进度条、文案（SwiftUI，嵌在加载画面里）

@MainActor
@Observable
final class PlayerLoadingState {
    enum TipPhase { case shown, leaving, entering }
    var progress: Double = 0
    var tip: String = PlayerLoadingCover.tips[0]
    var tipPhase: TipPhase = .shown
    var title: String = ""
}

/// 网页版 .np-mid：字标（Cuven 7.4vw、max 17.5vw，各有上下限）、进度条（min(50vw, 232) × 6）、文案（15 号）；
/// 矮横屏（高 ≤ 500）按屏高取字号
struct PlayerLoadingOverlay: View {
    let state: PlayerLoadingState
    private static let ink = Color(red: 10 / 255, green: 9 / 255, blue: 15 / 255)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let short = w > h && h <= 500
            let b1 = short ? Self.clamp(h * 0.054, 20, 30) : Self.clamp(w * 0.074, 25, 38)
            let b2 = short ? Self.clamp(h * 0.13, 44, 68) : Self.clamp(w * 0.175, 58, 92)
            let barW = min(w * 0.5, 232)
            let barGap = short ? 24 : Self.clamp(h * 0.06, 34, 56)
            VStack(spacing: 0) {
                brand(b1, b2)
                bar(width: barW)
                    .padding(.top, barGap)
                tip
                    .padding(.top, 18)
            }
            .padding(.horizontal, 24)
            .frame(width: w, height: h)
            .offset(y: -h * 0.03)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.title.isEmpty ? "正在载入" : "正在载入：" + state.title)
        .accessibilityValue("\(Int((state.progress * 100).rounded()))%")
        .accessibilityIdentifier("player-loading")
    }

    /// 「Cuven」500、「max」800，圆体；行高 1（网页版 line-height: 1）
    private func brand(_ b1: CGFloat, _ b2: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(verbatim: "Cuven")
                .font(.system(size: b1, weight: .medium, design: .rounded))
                .tracking(-0.01 * b1)
                .frame(height: b1)
            Text(verbatim: "max")
                .font(.system(size: b2, weight: .heavy, design: .rounded))
                .tracking(-0.045 * b2)
                .frame(height: b2)
                .padding(.top, -0.02 * b2)
        }
        .foregroundStyle(.white)
        .fixedSize()
        .shadow(color: Self.ink.opacity(0.32), radius: 11, y: 2)
    }

    /// 白 24% 的槽，白色的条从左边推进来（网页版 translateX((p − 1) × 100%)）
    private func bar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.24))
            Capsule().fill(Color.white)
                .frame(width: width)
                .offset(x: CGFloat(state.progress - 1) * width)
        }
        .frame(width: width, height: 6)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Self.ink.opacity(0.14), lineWidth: 0.5))
        .shadow(color: Self.ink.opacity(0.22), radius: 7, y: 2)
    }

    /// 消散：透明 + 模糊 10 + 放大到 1.06；进入：从透明 + 模糊 10 + 0.94 回到清晰
    private var tip: some View {
        let phase = state.tipPhase
        return Text(verbatim: state.tip)
            .font(.system(size: 15, weight: .medium))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(1)
            .fixedSize()
            .shadow(color: Self.ink.opacity(0.5), radius: 6, y: 1)
            .opacity(phase == .shown ? 1 : 0)
            .blur(radius: phase == .shown ? 0 : 10)
            .scaleEffect(phase == .leaving ? 1.06 : (phase == .entering ? 0.94 : 1))
            .frame(height: 22)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
}

// MARK: - 极光背景（Metal）

/// 一张全屏三角形跑网页版那段片元着色器：84 层极光场 → 色调映射 → 与底色合成。
/// 画在 25%（以 2 倍像素为准）的小画布上，由图层放大铺满（与网页版「内部分辨率 25%」同一个意思，光带本来就是糊的）。
/// 不自己跑循环：加载画面的显示链接每一帧推一次时间、画一帧，停了就不画
final class AuroraView: MTKView {
    var onUnavailable: (() -> Void)?
    private(set) var available: Bool
    private var time: Float = 0

    init() {
        let device = MTLCreateSystemDefaultDevice()
        available = device != nil
        super.init(frame: .zero, device: device)
        backgroundColor = PlayerLoadingCover.ink
        isOpaque = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = false
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 10.0 / 255, green: 9.0 / 255, blue: 15.0 / 255, alpha: 1)
        isUserInteractionEnabled = false
        if let device {
            AuroraPipeline.prepare(device) { [weak self] ok in
                guard let self, !ok else { return }
                self.available = false
                self.onUnavailable?()
            }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(traitCollection.displayScale, 2) * 0.25
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if drawableSize != size { drawableSize = size }
    }

    /// 每次盖上来都从头开始（网页版 start() 把时间归零）
    func restart() {
        time = 0
    }

    /// 推进时间（一帧最多算 0.05 秒，卡了一下不会跳一大截）并画一帧
    func advance(_ dt: CFTimeInterval) {
        guard available else { return }
        time = (time + Float(min(dt, 0.05))).truncatingRemainder(dividingBy: 3600)
        draw()
    }

    override func draw(_ rect: CGRect) {
        guard available, let pipeline = AuroraPipeline.state, let queue = AuroraPipeline.queue,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = AuroraUniforms(size: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)), time: time)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<AuroraUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// 与着色器里的 AuroraU 同一个布局：float2 + float，按 8 字节对齐共 16 字节
private struct AuroraUniforms {
    var size: SIMD2<Float>
    var time: Float
}

/// 着色器只编一次（在后台编，编好之前画面就是底色），所有加载画面共用
private enum AuroraPipeline {
    static var state: MTLRenderPipelineState?
    static var queue: MTLCommandQueue?
    private static var building = false
    private static var failed = false
    private static var waiting: [(Bool) -> Void] = []

    /// 只在主线程调；done 也在主线程回来
    static func prepare(_ device: MTLDevice, done: @escaping (Bool) -> Void) {
        if state != nil { done(true); return }
        if failed { done(false); return }
        waiting.append(done)
        guard !building else { return }
        building = true
        queue = device.makeCommandQueue()
        device.makeLibrary(source: auroraShaderSource, options: nil) { library, _ in
            guard let library,
                  let vertex = library.makeFunction(name: "auroraVertex"),
                  let fragment = library.makeFunction(name: "auroraFragment") else {
                DispatchQueue.main.async { AuroraPipeline.finish(nil) }
                return
            }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vertex
            d.fragmentFunction = fragment
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            device.makeRenderPipelineState(descriptor: d) { pipeline, _ in
                DispatchQueue.main.async { AuroraPipeline.finish(pipeline) }
            }
        }
    }

    fileprivate static func finish(_ pipeline: MTLRenderPipelineState?) {
        building = false
        state = pipeline
        failed = pipeline == nil
        let list = waiting
        waiting = []
        for cb in list { cb(pipeline != nil) }
    }
}

/// 网页版 Aurora 的着色器（FIELD + FINISH），逐行改写成 Metal：
/// 网页的 gl_FragCoord 原点在左下，Metal 的像素坐标原点在左上 —— 先翻成左下再算；
/// 鼠标扭动那一段（悬停 / 拖动）在手机上用不到，略去；底色很深（paper = 0），合成就是 bg + L·(1 − bg)
private let auroraShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct AuroraOut { float4 position [[position]]; };
struct AuroraU { float2 size; float time; };

vertex AuroraOut auroraVertex(uint vid [[vertex_id]]) {
    AuroraOut o;
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    o.position = float4(p, 0.0, 1.0);
    return o;
}

static float2x2 auroraRot(float a) {
    float c = cos(a);
    float s = sin(a);
    return float2x2(float2(c, s), float2(-s, c));
}

fragment float4 auroraFragment(AuroraOut in [[stage_in]], constant AuroraU &u [[buffer(0)]]) {
    const float3 C1 = float3(46.0, 85.0, 242.0) / 255.0;
    const float3 C2 = float3(133.0, 231.0, 255.0) / 255.0;
    const float3 BG = float3(10.0, 9.0, 15.0) / 255.0;

    float2 frag = float2(in.position.x, u.size.y - in.position.y);
    float2 pos = (frag - 0.5 * u.size) / u.size.y;
    pos = auroraRot(-119.0 * M_PI_F / 180.0) * pos / 1.14;

    float t = u.time * 0.49 + 12.0;
    float breath = (-sin(u.time * 0.735) + sin(u.time * 0.49 + 1.0)) * 0.25 + 0.5;
    float2 v = auroraRot(0.6) * ((pos - float2(-0.62, 0.24)) * (1.05 - breath * 0.085));
    float2x2 fold = float2x2(float2(cos(2.13), sin(2.13)), float2(-0.963, cos(2.13)));

    float3 col = float3(0.0);
    for (int n = 1; n <= 84; n++) {
        float i = float(n);
        v.x -= sin(v.y * 0.42 + t + i * 0.007) * 0.13;
        v.y -= sin(v.x * 2.4 - t + i * 0.02) * 0.027;
        v = fold * v * 0.953;
        float2 q = (v - float2(0.36 + breath * 0.1, 0.0)) * float2(2.1, 0.17);
        float g = 0.0021 / (dot(q, q) + 0.0019) * (0.25 + breath * 0.4);
        float r = length(v);
        float k = sin(i * 0.16 + t * 1.2 + r * 2.0) * 0.5 + 0.5;
        col += g * mix(C1, C2, float3(k)) * (0.62 + 0.5 * k) * exp2(-r * 0.37);
    }
    float3 x = max(col * 0.62, float3(0.0));
    col = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
    col = pow(saturate(col), float3(0.85, 0.92, 0.98));
    col *= 1.0 - smoothstep(0.5, 1.6, length(pos)) * 0.07;
    return float4(BG + col * (1.0 - BG), 1.0);
}
"""

/// 没有 Metal（或着色器没编过）：网页版自带的退路 —— 三团径向渐变，半透明
private final class AuroraFallbackView: UIView {
    private let blobs: [CAGradientLayer] = (0..<3).map { _ in CAGradientLayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0.5
        let c1 = UIColor(red: 46 / 255, green: 85 / 255, blue: 242 / 255, alpha: 1)
        let c2 = UIColor(red: 133 / 255, green: 231 / 255, blue: 1, alpha: 1)
        // (颜色, 中心, 半径（占宽 / 高的比例）, 渐隐到哪)：radial-gradient(70% 35% at 25% 45%, c1 0%, transparent 70%) 等三团
        let specs: [(UIColor, CGPoint, CGSize, Double)] = [
            (c1, CGPoint(x: 0.25, y: 0.45), CGSize(width: 0.7, height: 0.35), 0.7),
            (c2, CGPoint(x: 0.75, y: 0.55), CGSize(width: 0.6, height: 0.3), 0.7),
            (c1, CGPoint(x: 0.5, y: 0.5), CGSize(width: 0.5, height: 0.25), 0.75),
        ]
        for (blob, s) in zip(blobs, specs) {
            blob.type = .radial
            blob.colors = [s.0.cgColor, s.0.withAlphaComponent(0).cgColor]
            blob.locations = [0, NSNumber(value: s.3)]
            blob.startPoint = s.1
            blob.endPoint = CGPoint(x: s.1.x + s.2.width, y: s.1.y + s.2.height)
            layer.addSublayer(blob)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for blob in blobs { blob.frame = bounds }
    }
}
