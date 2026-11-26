import SwiftUI
import AVFoundation
import UIKit

// MARK: - 全屏预告片（Apple TV 的 Trailers）
//
// 黑底，画面居中；顶上：关闭、「预告片」、声音开关；底下：片名、这一段的名字、翻页胶囊（当前那颗随播放进度填满）。
// 左右滑换上一段 / 下一段，放完自动接下一段；点画面暂停 / 继续，往下滑关闭。预告片是 Apple TV 的 HLS，系统播放器直接能放。

/// 预告片的时长：Apple 没给的，读一下这一段的 HLS 播放列表（AVURLAsset 只拉两个小小的 m3u8，不拉视频），按地址记在内存里
actor TrailerLength {
    static let shared = TrailerLength()
    private var known: [String: Double] = [:]
    private var pending: [String: Task<Double?, Never>] = [:]

    func seconds(_ hls: String) async -> Double? {
        if let v = known[hls] { return v }
        // 演示数据不连网；不是 http 的地址也不读
        guard !DemoData.enabled, let url = URL(string: hls), url.scheme?.hasPrefix("http") == true else { return nil }
        if let t = pending[hls] { return await t.value }
        let t = Task<Double?, Never> {
            let asset = AVURLAsset(url: url)
            guard let d = try? await asset.load(.duration) else { return nil }
            let s = d.seconds
            return s.isFinite && s > 0 ? s : nil
        }
        pending[hls] = t
        let v = await t.value
        pending[hls] = nil
        if let v { known[hls] = v }
        return v
    }

    /// 卡上第二行：「2 分钟」（不到一分钟算一分钟）
    nonisolated static func label(_ s: Double?) -> String? {
        guard let s, s.isFinite, s > 0 else { return nil }
        return "\(max(1, Int((s / 60).rounded()))) 分钟"
    }
}

@MainActor
@Observable
final class TrailerDeck {
    let trailers: [Trailer]
    private(set) var index: Int
    private(set) var progress: Double = 0
    private(set) var failed = false
    private(set) var paused = false
    private(set) var muted = false
    let player = AVPlayer()
    /// 全屏预告片用掉的流量（账户页「流量概览」的「预告片」，Usage.swift）：每 5 秒看一眼访问日志，换段、收起时结清
    private let usage = UsageTap(.trailer)

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    init(trailers: [Trailer], index: Int) {
        self.trailers = trailers
        self.index = min(max(0, index), max(0, trailers.count - 1))
    }

    var current: Trailer? { trailers.indices.contains(index) ? trailers[index] : nil }

    func start() {
        guard timeObserver == nil, !trailers.isEmpty else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor [weak self] in self?.tick(t) }
        }
        load(index)
    }

    func stop() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        dropItemObservers()
        usage.flush(nil)
        player.replaceCurrentItem(with: nil)
    }

    func go(_ i: Int) {
        guard trailers.indices.contains(i), i != index else { return }
        Haptics.selection()
        load(i)
    }

    func toggleMute() {
        muted.toggle()
        player.isMuted = muted
    }

    func togglePause() {
        guard !failed else { return }
        paused.toggle()
        if paused { player.pause() } else { player.play() }
    }

    private func load(_ i: Int) {
        index = i
        progress = 0
        failed = false
        paused = false
        dropItemObservers()
        guard let url = URL(string: trailers[i].hls) else { failed = true; return }
        let item = AVPlayerItem(url: url)
        let nc = NotificationCenter.default
        itemObservers = [
            nc.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.ended() }
            },
            nc.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.failed = true }
            },
        ]
        statusObservation = item.observe(\.status) { [weak self] it, _ in
            guard it.status == .failed else { return }
            Task { @MainActor [weak self] in self?.failed = true }
        }
        usage.flush(item)                            // 上一段最后那一截先结清
        player.replaceCurrentItem(with: item)
        player.isMuted = muted
        player.play()
    }

    private func dropItemObservers() {
        for o in itemObservers { NotificationCenter.default.removeObserver(o) }
        itemObservers = []
        statusObservation = nil
    }

    private func tick(_ t: CMTime) {
        usage.sample(player.currentItem)
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
        progress = min(1, max(0, t.seconds / d))
    }

    private func ended() {
        if index + 1 < trailers.count { load(index + 1) } else { progress = 1; paused = true }
    }
}

struct TrailerPlayerView: View {
    let movieTitle: String
    /// 用 UIKit 弹出来时（present）由它收起；没给就走 SwiftUI 的 dismiss
    var close: (() -> Void)?
    @State private var deck: TrailerDeck
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(movieTitle: String, trailers: [Trailer], start: Int, close: (() -> Void)? = nil) {
        self.movieTitle = movieTitle
        self.close = close
        _deck = State(initialValue: TrailerDeck(trailers: trailers, index: start))
    }

    /// 全屏放预告片：用 UIKit 弹一层 VideoHostingController，好管方向——除了 iPhone 展开一律横屏、
    /// 只在左右两个横向之间转（用户要求，VideoOrientation.swift；SwiftUI 的 fullScreenCover 管不了方向）
    @MainActor
    static func present(movieTitle: String, trailers: [Trailer], start: Int) {
        guard !trailers.isEmpty, let top = UIApplication.topViewController() else { return }
        let host = VideoHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(
            TrailerPlayerView(movieTitle: movieTitle, trailers: trailers, start: min(max(0, start), trailers.count - 1)) { [weak host] in
                host?.dismiss(animated: true)
            }
            .tint(.white)
        )
        host.view.backgroundColor = .black
        host.overrideUserInterfaceStyle = .dark
        host.modalPresentationStyle = .fullScreen
        top.present(host, animated: true)
    }

    private func leave() {
        if let close { close() } else { dismiss() }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface(player: deck.player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { deck.togglePause() }
                .gesture(
                    DragGesture(minimumDistance: 24).onEnded { v in
                        let dx = v.translation.width, dy = v.translation.height
                        if abs(dx) > abs(dy) {
                            if dx < -50 { deck.go(deck.index + 1) } else if dx > 50 { deck.go(deck.index - 1) }
                        } else if dy > 110 {
                            leave()
                        }
                    }
                )
                // 旁白（设计轮 2）：轻点、左右滑这些手势旁白用不了——画面是一个元素：念这一段的名字和「正在播放 / 已暂停」，
                // 轻点两下暂停 / 继续，上下轻扫换下一段 / 上一段（F75、F76）
                .accessibilityElement()
                .accessibilityLabel(deck.current?.title ?? "预告片")
                .accessibilityValue(deck.failed ? "无法播放" : (deck.paused ? "已暂停" : "正在播放"))
                .accessibilityHint(deck.trailers.count > 1 ? "轻点两下以暂停或继续，上下轻扫以切换" : "轻点两下以暂停或继续")
                .accessibilityAction { deck.togglePause() }
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: deck.go(deck.index + 1)
                    case .decrement: deck.go(deck.index - 1)
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("trailer-video")

            if deck.failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30))
                    Text("无法播放此预告片").font(.subheadline.weight(.semibold))
                    if deck.index + 1 < deck.trailers.count {
                        Button("下一段") { deck.go(deck.index + 1) }.buttonStyle(.glass)
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
            } else if deck.paused {
                Image(systemName: "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .frame(width: 72, height: 72)
                    .glassEffect(.regular, in: Circle())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    // 「减弱动态效果」时只淡入淡出（F59）
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.scale.combined(with: .opacity))
            }

            // 上下两道压暗（设计复查）：横屏、iPad、Duo 展开时画面铺满，顶上的「预告片」和底下的片名直接压在画面上，
            // 亮的镜头、白底的字卡上看不清；竖屏时落在上下的黑边上看不出来。不挡点按
            LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0),
                                   .init(color: .clear, location: 0.16),
                                   .init(color: .clear, location: 0.68),
                                   .init(color: .black.opacity(0.2), location: 0.84),
                                   .init(color: .black.opacity(0.5), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    Button { leave() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 46, height: 46)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("关闭")
                    .accessibilityIdentifier("trailer-close")
                    Spacer()
                    Text("预告片").font(.headline)
                    Spacer()
                    Button {
                        Haptics.light()
                        deck.toggleMute()
                    } label: {
                        Image(systemName: deck.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(deck.muted ? "打开声音" : "静音")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer()

                VStack(spacing: 6) {
                    Text(movieTitle.uppercased())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DSInk.secondary)
                        .lineLimit(1)
                    // 换到下一段：名字交叉淡过去，不是直接换字
                    Text(deck.current?.title ?? "预告片")
                        .font(.headline)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 24)
                .animation(DSMotion.snap, value: deck.index)
                if deck.trailers.count > 1 {
                    TrailerDotsHost(deck: deck)
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 20)
        }
        .foregroundStyle(.white)
        .animation(.snappy(duration: 0.25), value: deck.paused)
        .animation(.snappy(duration: 0.25), value: deck.failed)
        .onAppear { deck.start() }
        .onDisappear { deck.stop() }
        .preferredColorScheme(.dark)
    }
}

/// 读播放进度的只有翻页胶囊这一小块（卡顿）：deck.progress 一秒写 5 次，以前在 TrailerPlayerView 的 body 里读，
/// 全屏预告片整页（玻璃钮、手势、旁白那一串）跟着每 0.2 秒重算一遍
private struct TrailerDotsHost: View {
    let deck: TrailerDeck

    var body: some View {
        TrailerDots(count: deck.trailers.count, index: deck.index, progress: deck.progress)
    }
}

/// 翻页胶囊：当前那一段是一颗随播放进度填满的胶囊，其余是圆点
struct TrailerDots: View {
    let count: Int
    let index: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                // 每一段都是同一颗胶囊：换段时圆点长成胶囊、胶囊收回圆点（以前是圆和胶囊两种形状，换段时互相淡入淡出）
                let on = i == index
                Capsule().fill(Color.white.opacity(on ? 0.3 : 0.45))
                    .frame(width: on ? 28 : 7, height: 7)
                    .overlay(alignment: .leading) {
                        if on { Capsule().fill(.white).frame(width: max(7, 28 * progress)) }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .animation(.snappy(duration: 0.3), value: index)
        .allowsHitTesting(false)
    }
}

/// 只画面、不带系统控件的播放层
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    /// 资料库的展映画幅要铺满（.resizeAspectFill、透明底）；全屏预告片是完整画面加黑底
    var gravity: AVLayerVideoGravity = .resizeAspect
    var background: UIColor = .black

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        v.backgroundColor = background
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
