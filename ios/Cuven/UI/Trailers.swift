import SwiftUI
import AVFoundation
import UIKit

// MARK: - 全屏预告片（Apple TV 的 Trailers）
//
// 黑底，画面居中；顶上：关闭、「预告片」、声音开关；底下：片名、这一段的名字、翻页胶囊（当前那颗随播放进度填满）。
// 左右滑换上一段 / 下一段，放完自动接下一段；点画面暂停 / 继续，往下滑关闭。预告片是 Apple TV 的 HLS，系统播放器直接能放。

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
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
        progress = min(1, max(0, t.seconds / d))
    }

    private func ended() {
        if index + 1 < trailers.count { load(index + 1) } else { progress = 1; paused = true }
    }
}

struct TrailerPlayerView: View {
    let movieTitle: String
    @State private var deck: TrailerDeck
    @Environment(\.dismiss) private var dismiss

    init(movieTitle: String, trailers: [Trailer], start: Int) {
        self.movieTitle = movieTitle
        _deck = State(initialValue: TrailerDeck(trailers: trailers, index: start))
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
                            dismiss()
                        }
                    }
                )
                .accessibilityIdentifier("trailer-video")

            if deck.failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30))
                    Text("这段预告片放不了").font(.system(size: 15, weight: .semibold))
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
                    .transition(.scale.combined(with: .opacity))
            }

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 46, height: 46)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("关闭")
                    .accessibilityIdentifier("trailer-close")
                    Spacer()
                    Text("预告片").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button { deck.toggleMute() } label: {
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    Text(deck.current?.title ?? "预告片")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)
                if deck.trailers.count > 1 {
                    TrailerDots(count: deck.trailers.count, index: deck.index, progress: deck.progress)
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 20)
        }
        .foregroundStyle(.white)
        .animation(.snappy(duration: 0.25), value: deck.paused)
        .onAppear { deck.start() }
        .onDisappear { deck.stop() }
        .preferredColorScheme(.dark)
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
                if i == index {
                    Capsule().fill(Color.white.opacity(0.3))
                        .frame(width: 28, height: 7)
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white).frame(width: max(7, 28 * progress))
                        }
                } else {
                    Circle().fill(Color.white.opacity(0.45)).frame(width: 7, height: 7)
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

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
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
