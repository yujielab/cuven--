import SwiftUI
import UIKit

// MARK: - 播放加载画面：和网页版一样（web/index.html 的 np-load；用户要求）
//
// 点「播放」到真正开播之间，一整个顶层窗口盖在所有东西上面（正在升起的系统播放器、iPhone Duo 侧边的导航都在它下面），
// 直到首帧出来才收起。
// · 极光背景：深色底上一条蓝到青的光带慢慢流动、呼吸（网页版 Aurora 的配色与节奏；这里用 MeshGradient 画）。
// · 正中「Cuven max」字标（圆体，Cuven 细、max 粗而大）。
// · 下面一条 iOS 更新式的胶囊进度条：按真实阶段推进——拿到片源 → 播放列表 → 挂上片源 → 可以播 → 开播；
//   阶段之间缓缓爬升，不倒退，开播前不走满；开播时走满，0.26 秒后淡出（网页版 STAGE / loaderDone 同一套数）。
// · 再下面一句句提示，每 2.4 秒换一句：旧的模糊、放大着散掉，新的从模糊里缩回来；十句都轮完还没开播，如实说网络慢。
// · 左上一颗关闭钮（44 点，玻璃圆）：不想等了随时退出。
// · 「减弱动态效果」时极光停在一帧，提示只淡入淡出（F59、F60）。

/// 加载的阶段：进度条在 [起点, 上限] 里缓缓爬升（和网页版 STAGE 一样）
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
    var stage: PlayerLoadStage = .open
    var stageAt = Date()
    /// 换阶段那一刻进度条已经到了哪：新阶段从不低于它的地方起步（不倒退）
    var floor: Double = 0
    var leaving = false

    /// 此刻的进度：从阶段起点（或上一刻的位置）按指数曲线爬向这一阶段的上限；开播那一段很快走满
    func progress(at now: Date) -> Double {
        let (base, cap) = stage.range
        let b = max(base, floor)
        let t = max(0, now.timeIntervalSince(stageAt))
        if stage == .play { return b + (1 - b) * (1 - exp(-t / 0.09)) }
        return b + (max(b, cap) - b) * (1 - exp(-t / 2.6))
    }
}

/// 顶层窗口的开关：PlayerCoordinator 在每个阶段调一下
@MainActor
final class PlayerLoadingOverlay {
    static let shared = PlayerLoadingOverlay()
    private var window: UIWindow?
    private let model = PlayerLoadingModel()
    private var hideTask: Task<Void, Never>?
    /// 点了左上角的关闭
    var onClose: (() -> Void)?

    var isShowing: Bool { window != nil }

    func show(title: String) {
        hideTask?.cancel()
        model.title = title
        model.stage = .open
        model.stageAt = Date()
        model.floor = 0
        model.leaving = false
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
        guard window != nil, s > model.stage else { return }
        model.floor = model.progress(at: Date())
        model.stage = s
        model.stageAt = Date()
    }

    /// 开播：进度条走满，0.26 秒后淡出、拿掉窗口
    func finish() {
        guard window != nil, !model.leaving else { return }
        stage(.play)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.46)) { self.model.leaving = true }
            try? await Task.sleep(nanoseconds: 480_000_000)
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

struct PlayerLoadingView: View {
    let model: PlayerLoadingModel
    let onClose: () -> Void
    @State private var appeared = false
    @State private var tip = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 和网页版同一组提示
    private static let tips = ["请保持屏幕亮起", "正在渲染绚烂颜色", "正在预热画面质量", "正在添加全景声系统", "正在为您的设备优化",
                               "正在量身定制体验", "正为您添加动态字幕", "一切几乎就绪", "还需要一小会", "即将完成"]
    static let ink = Color(red: 10 / 255, green: 9 / 255, blue: 15 / 255)

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height && geo.size.height < 500
            ZStack {
                Self.ink
                AuroraBackground()
                VStack(spacing: 0) {
                    wordmark(landscape: landscape)
                    progressBar(width: min(geo.size.width * 0.5, 232))
                        .padding(.top, landscape ? 24 : 44)
                    tipLine
                        .padding(.top, 18)
                }
                .offset(y: -geo.size.height * 0.03)
                .padding(.horizontal, 24)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle(scale: 0.92))
                .padding(.top, geo.safeAreaInsets.top + 8)
                .padding(.leading, geo.safeAreaInsets.leading + 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("player-loading-close")
            }
            .ignoresSafeArea()
        }
        .opacity(model.leaving ? 0 : (appeared ? 1 : 0))
        .onAppear { withAnimation(.easeOut(duration: 0.25)) { appeared = true } }
        .task {
            // 每 2.4 秒换一句；十句都轮完还停在最后一条（如实说网络慢）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_400_000_000)
                guard !Task.isCancelled, tip < Self.tips.count else { return }
                withAnimation(.easeInOut(duration: 0.52)) { tip += 1 }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title.isEmpty ? "正在载入" : "正在载入：" + model.title)
        .accessibilityIdentifier("player-loading")
    }

    /// 「Cuven」细、「max」粗而大，圆体（和网页版 np-brand 同一套比例）
    private func wordmark(landscape: Bool) -> some View {
        VStack(spacing: landscape ? -4 : -6) {
            Text("Cuven")
                .font(.system(size: landscape ? 26 : 34, weight: .medium, design: .rounded))
            Text("max")
                .font(.system(size: landscape ? 60 : 84, weight: .heavy, design: .rounded))
                .tracking(landscape ? -2.4 : -3.6)
        }
        .foregroundStyle(.white)
        .shadow(color: Self.ink.opacity(0.32), radius: 11, y: 2)
        .accessibilityHidden(true)
    }

    /// 胶囊进度条：232 宽、6 高，底 24% 白、值纯白
    private func progressBar(width: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { tl in
            let p = model.progress(at: tl.date)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.24))
                Capsule().fill(Color.white).frame(width: max(6, width * p))
            }
            .frame(width: width, height: 6)
            .shadow(color: Self.ink.opacity(0.22), radius: 7, y: 2)
            .accessibilityElement()
            .accessibilityLabel("加载进度")
            .accessibilityValue("\(Int((p * 100).rounded()))%")
        }
    }

    /// 一句提示：旧的模糊、放大着散掉，新的从模糊里缩回来（网页版 np-tip 的 leave / enter）
    private var tipLine: some View {
        let text = tip < Self.tips.count ? Self.tips[tip] : "网络较慢，正在为您缓冲"
        return ZStack {
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .shadow(color: Self.ink.opacity(0.5), radius: 6, y: 1)
                .id(tip)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .modifier(active: TipFX(blur: 10, scale: 0.94, opacity: 0), identity: TipFX(blur: 0, scale: 1, opacity: 1)),
                    removal: .modifier(active: TipFX(blur: 10, scale: 1.06, opacity: 0), identity: TipFX(blur: 0, scale: 1, opacity: 1))))
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}

private struct TipFX: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: blur).scaleEffect(scale).opacity(opacity)
    }
}

/// 极光（网页版 Aurora 的配色：底 #0A090F，光 #2E55F2 → #85E7FF）：一张 4×4 的网格渐变，
/// 中间几个点绕着慢慢转、整体一呼一吸；「减弱动态效果」时停在一帧
struct AuroraBackground: View {
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { tl in
            let t = tl.date.timeIntervalSince(start)
            MeshGradient(width: 4, height: 4, points: Self.points(t), colors: Self.colors(t), smoothsColors: true)
        }
        .accessibilityHidden(true)
    }

    private static func points(_ t: Double) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for j in 0..<4 {
            for i in 0..<4 {
                var x = Double(i) / 3, y = Double(j) / 3
                let inner = (1...2).contains(i) && (1...2).contains(j)
                if inner {
                    x += 0.09 * sin(t * 0.49 + Double(i) * 1.7 + Double(j) * 0.9)
                    y += 0.08 * cos(t * 0.37 + Double(j) * 1.3 + Double(i) * 0.6)
                } else if i == 0 || i == 3 {
                    if j == 1 || j == 2 { y += 0.05 * sin(t * 0.31 + Double(j) * 2.1 + Double(i)) }
                } else {
                    x += 0.05 * sin(t * 0.29 + Double(i) * 1.9 + Double(j))
                }
                out.append(SIMD2(Float(x), Float(y)))
            }
        }
        return out
    }

    private static func colors(_ t: Double) -> [Color] {
        // 一呼一吸（网页版 breath 的两条正弦）
        let breath = ((-sin(t * 0.735) + sin(t * 0.49 + 1)) * 0.25 + 0.5)
        let k = 0.7 + 0.3 * breath
        let bg = PlayerLoadingView.ink
        func blue(_ a: Double) -> Color { Color(red: 46 / 255, green: 85 / 255, blue: 242 / 255).opacity(a * k) }
        func cyan(_ a: Double) -> Color { Color(red: 133 / 255, green: 231 / 255, blue: 1).opacity(a * k) }
        // 光带从左下斜到右上（网页版 angle -119°）
        return [
            bg, bg, blue(0.25), bg,
            bg, blue(0.75), cyan(0.55), blue(0.3),
            blue(0.35), cyan(0.7), blue(0.6), bg,
            bg, blue(0.3), bg, bg,
        ]
    }
}
