import SwiftUI
import UIKit
import Network

// MARK: - 播放加载画面：和网页版一模一样（web/index.html 的 .np / .np-load；用户要求）
//
// 点「播放」到真正开播之间，一整个顶层窗口盖在所有东西上面（正在升起的系统播放器、iPhone Duo 侧边的导航都在它下面），
// 首帧出来才收起。每一项都照网页版：
// · 整层 0.2 秒淡入（.np.on）；底色 rgb(10, 9, 15)。
// · 极光：网页版 Aurora 的着色器逐行移植（Aurora.metal），同样的推进（time += dt，dt 最多 0.05 秒）、同样 25% 的分辨率，
//   手指按住时光带绕着手指转（网页版的 pointer：uOn 0.2 秒级缓入缓出、位置 16/s 跟随、速度 8/s 平滑）。
// · 正中一列整体上移 3% 屏高：「Cuven」clamp(25, 7.4vw, 38) 中等粗、字距 −0.01em；「max」clamp(58, 17.5vw, 92) 特粗、
//   字距 −0.045em、上移 0.02em；行高 1；投影 0 2 22 rgba(10,9,15,.32)。
// · 进度条：min(50vw, 232) × 6、圆角 3、底 24% 白、值纯白，上边距 clamp(34, 6vh, 56)；
//   进度按真实阶段推进（STAGE 同网页版），目标 = 起点 +（上限 − 起点）×(1 − e^(−t/2.6 秒))，
//   进度条以每秒 5（开播后 14）的速率追目标——不倒退、开播前不走满。
// · 提示：上边距 18、15 号中等粗、字距 0.02em、86% 白；每 2.4 秒换一句：旧的 0.52 秒里模糊 10、放大到 1.06、淡出，
//   再换字、从模糊 10、0.94 倍缩回清楚（cubic-bezier(.4,0,.2,1)）；十句都轮完还没开播，如实说网络的情况。
// · 横着的矮屏（高 ≤ 500）：「Cuven」clamp(20, 5.4vh, 30)、「max」clamp(44, 13vh, 68)、进度条上边距 24。
// · 左上关闭钮（.np-x）：40 点圆、16% 白 + 模糊底、20 点的「×」，离安全区上沿 10、左沿 12；按下缩到 0.92。
// · 开播：进度条走满，0.26 秒后 0.46 秒淡出（ease），再拿掉窗口。

/// 加载的阶段：进度条在 [起点, 上限] 里爬（网页版 STAGE）
enum PlayerLoadStage: Int, Comparable {
    case open, source, meta, data, ready, play

    var range: (Double, Double) {
        switch self {
        case .open: return (0.04, 0.2)
        case .source: return (0.18, 0.4)
        case .meta: return (0.4, 0.64)
        case .data: return (0.62, 0.82)
        case .ready: return (0.8, 0.94)
        case .play: return (1, 1)
        }
    }

    static func < (a: PlayerLoadStage, b: PlayerLoadStage) -> Bool { a.rawValue < b.rawValue }
}

@MainActor
@Observable
final class PlayerLoadingModel {
    var title = ""
    /// 每次重新开始加载（换一集也算）加一：进度条、提示从头来
    var generation = 0
    var base: Double = 0
    var cap: Double = 0
    var stageAt = Date()
    var leaving = false
}

/// 顶层窗口的开关：PlayerCoordinator 在每个阶段调一下
@MainActor
final class PlayerLoadingOverlay {
    static let shared = PlayerLoadingOverlay()
    private var window: UIWindow?
    private let model = PlayerLoadingModel()
    private var hideTask: Task<Void, Never>?
    private var current: PlayerLoadStage = .open
    /// 点了左上角的关闭
    var onClose: (() -> Void)?

    var isShowing: Bool { window != nil }

    func show(title: String) {
        hideTask?.cancel()
        model.title = title
        model.generation += 1
        model.leaving = false
        model.base = 0
        model.cap = 0
        current = .open
        apply(.open, force: true)
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        w.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: PlayerLoadingView(model: model) { [weak self] in self?.onClose?() })
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
    }

    func stage(_ s: PlayerLoadStage) {
        guard window != nil, s > current else { return }
        current = s
        apply(s, force: false)
    }

    /// 网页版 loaderStage：起点只往上走
    private func apply(_ s: PlayerLoadStage, force: Bool) {
        let (base, cap) = s.range
        guard force || base > model.base else { return }
        model.base = base
        model.cap = cap
        model.stageAt = Date()
    }

    /// 开播：进度条走满，0.26 秒后 0.46 秒淡出，再拿掉窗口（网页版 loaderDone）
    func finish() {
        guard window != nil, !model.leaving, current < .play else { return }
        stage(.play)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.46)) { self.model.leaving = true }
            try? await Task.sleep(nanoseconds: 460_000_000)
            guard !Task.isCancelled else { return }
            self.remove()
        }
    }

    /// 关了、出错了：马上拿掉
    func hide() {
        hideTask?.cancel()
        hideTask = nil
        remove()
    }

    private func remove() {
        window?.isHidden = true
        window = nil
    }
}

/// 网络断没断（十句提示轮完还没开播时，如实说是断网还是慢）
final class LoaderNet: @unchecked Sendable {
    static let shared = LoaderNet()
    private let monitor = NWPathMonitor()
    private(set) var offline = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] p in self?.offline = p.status != .satisfied }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}

/// 进度条的追随（网页版 barFrame）：每帧往目标追一段
@MainActor
final class LoaderBarSim {
    var p: Double = 0
    var last: Date?
    var generation = -1

    func step(_ now: Date, model: PlayerLoadingModel) -> Double {
        if generation != model.generation {
            generation = model.generation
            p = 0
            last = nil
        }
        let dt = last.map { min(0.1, max(0, now.timeIntervalSince($0))) } ?? 0
        last = now
        let base = model.base, cap = model.cap
        let goal = base + (cap - base) * (1 - exp(-max(0, now.timeIntervalSince(model.stageAt)) / 2.6))
        p += (goal - p) * (1 - exp(-dt * (base >= 1 ? 14 : 5)))
        return p
    }
}

struct PlayerLoadingView: View {
    let model: PlayerLoadingModel
    let onClose: () -> Void
    @State private var appeared = false
    @State private var bar = LoaderBarSim()
    @State private var aurora = AuroraSim()
    @State private var tip = 0
    @State private var tipText = Self.tips[0]
    @State private var tipPhase: TipPhase = .shown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum TipPhase { case shown, leaving, entering }

    /// 和网页版同一组提示
    private static let tips = ["请保持屏幕亮起", "正在渲染绚烂颜色", "正在预热画面质量", "正在添加全景声系统", "正在为您的设备优化",
                               "正在量身定制体验", "正为您添加动态字幕", "一切几乎就绪", "还需要一小会", "即将完成"]
    static let ink = Color(red: 10 / 255, green: 9 / 255, blue: 15 / 255)
    private static let tipCurve = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.52)

    var body: some View {
        GeometryReader { geo in
            // 整个屏幕（这一层铺满、不让安全区）；安全区只用来摆左上的关闭钮
            let insets = geo.safeAreaInsets
            let W = geo.size.width
            let H = geo.size.height
            // 网页版 @media (orientation: landscape) and (max-height: 500px)
            let short = W > H && H <= 500
            TimelineView(.animation) { tl in
                ZStack {
                    Self.ink
                    AuroraView(sim: aurora, date: tl.date, width: W, height: H, still: reduceMotion)
                    VStack(spacing: 0) {
                        wordmark(W: W, H: H, short: short)
                        progressBar(width: min(W * 0.5, 232), p: bar.step(tl.date, model: model))
                            .padding(.top, short ? 24 : min(56, max(34, H * 0.06)))
                        tipLine
                            .padding(.top, 18)
                    }
                    .padding(.horizontal, 24)
                    .frame(width: W)
                    .offset(y: -H * 0.03)
                }
                .frame(width: W, height: H)
                // 手指按住：光带绕着手指转（网页版 pointermove / pointerdown，抬手就缓缓收回）
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { aurora.pointer($0.location) }
                    .onEnded { _ in aurora.release() })
            }
            .overlay(alignment: .topLeading) {
                closeButton
                    .padding(.top, insets.top + 10)
                    .padding(.leading, insets.leading + 12)
            }
        }
        .ignoresSafeArea()
        .opacity(model.leaving ? 0 : (appeared ? 1 : 0))
        // 网页版 .np.on：opacity .2s ease
        .onAppear { withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.2)) { appeared = true } }
        .task(id: model.generation) { await rotateTips() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title.isEmpty ? "正在载入" : "正在载入：" + model.title)
        .accessibilityIdentifier("player-loading")
    }

    /// 「Cuven」细、「max」粗而大，圆体，行高 1（网页版 np-brand / np-b1 / np-b2）
    private func wordmark(W: CGFloat, H: CGFloat, short: Bool) -> some View {
        let s1 = short ? min(30, max(20, H * 0.054)) : min(38, max(25, W * 0.074))
        let s2 = short ? min(68, max(44, H * 0.13)) : min(92, max(58, W * 0.175))
        // SwiftUI 的字比 CSS 行高 1 的行框高出约 0.19 em（上下各半）：收回来，再照网页版上移 max 0.02em
        let spacing = -(s1 * 0.095 + s2 * 0.095) - s2 * 0.02
        return VStack(spacing: spacing) {
            Text("Cuven")
                .font(.system(size: s1, weight: .medium, design: .rounded))
                .tracking(-0.01 * s1)
            Text("max")
                .font(.system(size: s2, weight: .heavy, design: .rounded))
                .tracking(-0.045 * s2)
        }
        .foregroundStyle(.white)
        .shadow(color: Self.ink.opacity(0.32), radius: 11, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cuven max")
    }

    /// 胶囊进度条：底 24% 白、值纯白，外面一圈 0.5 点的暗边和一层柔影（网页版 np-bar）
    private func progressBar(width: CGFloat, p: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.24))
            Capsule().fill(Color.white).frame(width: width * min(1, max(0, p)))
        }
        .frame(width: width, height: 6)
        .clipShape(Capsule())
        .background(Capsule().fill(Self.ink.opacity(0.14)).padding(-0.5))
        .shadow(color: Self.ink.opacity(0.22), radius: 7, y: 2)
        .accessibilityElement()
        .accessibilityLabel("加载进度")
        .accessibilityValue("\(Int((p * 100).rounded()))%")
    }

    /// 一句提示（网页版 np-tips / np-tip）
    private var tipLine: some View {
        Text(tipText)
            .font(.system(size: 15, weight: .medium))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(1)
            .fixedSize()
            .shadow(color: Self.ink.opacity(0.5), radius: 6, y: 1)
            .blur(radius: reduceMotion || tipPhase == .shown ? 0 : 10)
            .scaleEffect(reduceMotion ? 1 : (tipPhase == .leaving ? 1.06 : (tipPhase == .entering ? 0.94 : 1)))
            .opacity(tipPhase == .shown ? 1 : 0)
            .frame(height: 22)
            .accessibilityHidden(true)
    }

    /// 每 2.4 秒换一句：旧的模糊、放大着散掉（0.52 秒），换字，新的从模糊里缩回来（网页版 nextTip）
    private func rotateTips() async {
        tip = 0
        tipText = Self.tips[0]
        tipPhase = .shown
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            let next: String
            if tip >= Self.tips.count - 1 {
                // 十句都轮完了还没开播（约 24 秒）：不再停在「即将完成」，如实说网络的情况
                next = LoaderNet.shared.offline ? "网络已断开，恢复后自动继续" : "网络较慢，正在为您缓冲"
                if tipText == next { continue }
            } else {
                tip += 1
                next = Self.tips[tip]
            }
            withAnimation(Self.tipCurve) { tipPhase = .leaving }
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard !Task.isCancelled else { return }
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                tipText = next
                tipPhase = .entering
            }
            try? await Task.sleep(nanoseconds: 16_000_000)
            withAnimation(Self.tipCurve) { tipPhase = .shown }
        }
    }

    /// 左上关闭（网页版 .np-x）：40 点圆、16% 白 + 模糊底、20 点的「×」（线宽 2.2 / 24）
    private var closeButton: some View {
        Button(action: onClose) {
            Path { p in
                p.move(to: CGPoint(x: 6.5, y: 6.5)); p.addLine(to: CGPoint(x: 17.5, y: 17.5))
                p.move(to: CGPoint(x: 17.5, y: 6.5)); p.addLine(to: CGPoint(x: 6.5, y: 17.5))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .frame(width: 24, height: 24)
            .scaleEffect(20.0 / 24.0)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.white.opacity(0.16)))
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .accessibilityLabel("关闭")
        .accessibilityIdentifier("player-loading-close")
    }
}

// MARK: - 极光（网页版 Aurora 的推进与手指交互；着色器在 Aurora.metal）

/// 每帧推进（网页版 draw 里的那一套状态）
final class AuroraSim {
    private var time: Double = 0
    private var last: Date?
    private var mx = 0.0, my = 0.0, vx = 0.0, vy = 0.0, on = 0.0
    private var tx = 0.0, ty = 0.0, inside = false

    struct Uniforms {
        var time: Float
        var mouse: SIMD2<Float>
        var on: Float
        var reach: Float
        var vel: SIMD2<Float>
    }

    func pointer(_ p: CGPoint) {
        tx = Double(p.x)
        ty = Double(p.y)
        inside = true
    }

    func release() { inside = false }

    func step(_ now: Date, W: Double, H: Double) -> Uniforms {
        let t = last.map { min(0.05, max(0, now.timeIntervalSince($0))) } ?? 0     // 网页版：一帧最多算 0.05 秒
        last = now
        time = (time + t).truncatingRemainder(dividingBy: 3600)                     // speed 50 → ×1
        let want: Double = inside ? 1 : 0
        if want > 0 && on < 0.02 { mx = tx; my = ty }
        on += (want - on) * (1 - exp(-t * 5))
        let k = 1 - exp(-t * 16)
        let nx = mx + (tx - mx) * k, ny = my + (ty - my) * k
        if t > 0 {
            let e = 1 - exp(-t * 8)
            vx += ((nx - mx) / t - vx) * e
            vy += ((ny - my) / t - vy) * e
        }
        mx = nx
        my = ny
        let h = max(1, H)
        let sp = hypot(vx, vy) / h, lim = sp > 3 ? 3 / sp : 1
        return Uniforms(time: Float(time),
                        mouse: SIMD2(Float((mx - W / 2) / h), Float((h / 2 - my) / h)),
                        on: Float(on * 1.45),                                       // hover 145
                        reach: Float(240 / h),                                      // reach 240
                        vel: SIMD2(Float(vx / h * lim), Float(-vy / h * lim)))
    }
}

/// 极光那一层：在一块小画布上跑着色器（网页版的离屏纹理：屏幕像素 × 0.25，倍率最多 2），再整块线性放大到全屏
struct AuroraView: View {
    let sim: AuroraSim
    let date: Date
    let width: CGFloat
    let height: CGFloat
    var still = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // 网页版画布 = 点 × min(倍率, 2)，极光那一张纹理再 × 0.25：每个点 min(倍率, 2) × 0.25 个像素。
        // 这里小画布按屏幕倍率出像素，所以它的尺寸（点）= 全屏 × min(倍率, 2) × 0.25 ÷ 屏幕倍率
        let k = min(displayScale, 2) * 0.25 / max(1, displayScale)
        let fw = max(1, (width * k).rounded()), fh = max(1, (height * k).rounded())
        let u = sim.step(still ? Date(timeIntervalSinceReferenceDate: 0) : date, W: Double(width), H: Double(height))
        Rectangle()
            .frame(width: fw, height: fh)
            .colorEffect(ShaderLibrary.cuvenAurora(
                .float2(Float(fw), Float(fh)),
                .float(u.time),
                .float2(u.mouse.x, u.mouse.y),
                .float(u.on),
                .float(u.reach),
                .float2(u.vel.x, u.vel.y)))
            .drawingGroup()
            .scaleEffect(x: width / fw, y: height / fh, anchor: .topLeading)
            .frame(width: width, height: height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
