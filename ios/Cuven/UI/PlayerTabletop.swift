import SwiftUI
import UIKit
import AVKit
import AVFoundation
import MediaPlayer

// MARK: - 半折（桌面形态）的播放器：上面画面、下面控制面板
//
// 用户要求：「添加类似 Netflix 在 iPhone Duo 半折的上视频下控制面板的设计」（附截图：内屏竖拿、半折立在桌上）。
// iPhone Duo 展开竖拿再半折，像一台小笔记本立在桌上，内屏被横着的折痕分成上下两块：
//   · 上面那块放画面（按比例放进去，不裁不拉），远一点也看得清；
//   · 下面那块是控制面板，手够得着。照截图分四行深灰圆角块，块与块之间、离屏边都是 8 点：
//       ① 关闭 | 片名卡（小画面 + 片名 + 第几集） | 隔空播放 | 锁定
//       ② 后退 10 秒 | 播放 / 暂停 | 前进 10 秒（三块大的）
//       ③ 进度条 + 剩余时间
//       ④ 播放速度 | 亮度 | 音量 | 音频与字幕 | 下一集（剧集后面还有才有） | 全屏
//     四行的高按 77 : 142 : 51 : 51 分（截图在 669 点宽的内屏上量的），面板矮一点、高一点都照这个比例，行高有上下限。
//     截图里的「剪辑」Cuven 没有这个功能，不放；「画中画」换成隔空播放：AVKit 没有让自己画的按钮启动系统播放器画中画的接口
//     （画中画照旧由系统处理）。用 Cuven 自己的样子：白色进度条，不用截图里那家的红色和字标。
//
// 折痕在哪：iOS 27.1 的 GeometryProxy.reservedRegions(kind: .division)——只有半折时才有「生效」的那一块，frame 已经含着
// 系统要求留出的边距（D10、D11）。横着的（宽 > 高）才是桌面形态；竖着的折痕（横拿半折，像一本书）、平着展开、折起、
// 别的 iPhone / iPad 一律照旧用系统播放器。版面跟着折痕排、不看铰链角度（D12；Apple 的示例也是这么建议的）；
// 合上或摊平时折痕不再生效，面板淡出、系统播放器的控件回来（D3：两种版面同一个播放状态）。
//
// 画面：系统播放器自己的画面铺满整屏、会横跨折痕，所以半折时这里另挂一层 AVPlayerLayer 接同一个 AVPlayer
// （一个播放器可以同时画到几层上，只解码一次），盖住底下系统播放器的画面和控件（showsPlaybackControls 关掉）；
// 面板收起、播放器不在屏上、App 退到后台（画中画接手）时这一层先摘掉，只留系统播放器那一层。
//
// 「全屏」：这一次半折里回到系统播放器（画面铺满、系统控件）；合上 / 摊平以后再半折，又是上下两块。
// 「锁定」：除了这颗锁，面板上的按钮都变暗、点不动（放在桌上看的时候不会碰到）；再点锁解开。

/// 折痕：只认横着的那一种
enum TabletopFold {
    /// 半折、横着的折痕在屏里的位置（含系统要求留的边距）；没有：nil
    static func horizontal(in proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            // 只取生效的（半折时才有）：平着展开时那一块还在，但不生效、宽或高是 0
            guard let f = proxy.reservedRegions(kind: .division).first?.frame,
                  f.width > f.height, f.minY > 0, f.maxY < proxy.size.height else { return nil }
            return f
        }
        return nil
    }

    /// 截图用（DEBUG 的 -CuvenTabletop）：模拟器折不了，竖着的屏把折痕固定在正中、上下各留 28 点
    static func preview(_ size: CGSize) -> CGRect? {
        guard size.height > size.width else { return nil }
        return CGRect(x: 0, y: (size.height / 2 - 28).rounded(), width: size.width, height: 56)
    }
}

// MARK: - 状态

@MainActor
@Observable
final class TabletopPlayerModel {
    /// 放的是哪一部（PlayerCoordinator 每开始一集写一次）
    var title = ""
    var subtitle: String?
    var artwork: String?
    /// 剧集后面还有下一集
    var hasNext = false

    /// 横着的折痕（半折）；没有：nil
    private(set) var fold: CGRect?
    /// 这一次半折里点了「全屏」
    private(set) var fullscreen = false
    /// 正在用上下两块的版面（系统播放器的控件收起）
    private(set) var active = false
    /// 播放器在屏上、App 在前台：才挂自己那一层画面
    var visible = true

    private(set) var playing = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    /// 拖着进度条时指着的位置（松手才跳过去）
    var scrub: Double?
    var locked = false
    /// 第四行展开成一条滑杆：亮度 / 音量
    var tray: Tray?
    var brightness: Double = 0.5
    private(set) var audioNames: [String] = []
    private(set) var subtitleNames: [String] = []
    private(set) var audioPick = -1
    /// -1：字幕关着
    private(set) var subtitlePick = -1

    enum Tray { case brightness, volume }

    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    @ObservationIgnored weak var player: AVPlayer?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onNext: (() -> Void)?
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?
    /// 截图用（DEBUG 的 -CuvenTabletop）：不接播放器，折痕固定在屏正中，按钮只改面板上的样子
    @ObservationIgnored var preview = false

    @ObservationIgnored private var timeToken: Any?
    @ObservationIgnored private weak var timePlayer: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var audioOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var subtitleOptions: [AVMediaSelectionOption] = []

    // MARK: 折痕

    func setFold(_ f: CGRect?) {
        guard f != fold else { return }
        // 合上 / 摊平：「全屏」只管这一次半折，下次半折又是上下两块
        if f == nil { fullscreen = false }
        fold = f
        update()
    }

    func goFullscreen() {
        fullscreen = true
        update()
    }

    private func update() {
        let now = fold != nil && !fullscreen
        guard now != active else { return }
        active = now
        tray = nil
        locked = false
        scrub = nil
        if now { bind() } else { unbind() }
        onActiveChange?(now)
    }

    // MARK: 播放状态（只在面板出来时跟着播放器走：每 0.25 秒一次）

    private func bind() {
        brightness = Double(Self.screen?.brightness ?? 0.5)
        if preview {
            playing = true
            duration = 2_700
            position = 277
            audioNames = ["国语", "English"]
            subtitleNames = ["简体中文", "English"]
            audioPick = 0
            subtitlePick = 0
            return
        }
        guard let p = player else { return }
        unbind()
        timePlayer = p
        timeToken = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        statusObservation = p.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // 换了一集（剧集接下一集时播放器不关、换片源）：音轨和字幕重新读
        itemObservation = p.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.loadTracks()
            }
        }
        refresh()
        loadTracks()
    }

    private func unbind() {
        if let t = timeToken { timePlayer?.removeTimeObserver(t) }
        timeToken = nil
        timePlayer = nil
        statusObservation?.invalidate()
        statusObservation = nil
        itemObservation?.invalidate()
        itemObservation = nil
    }

    private func refresh() {
        guard !preview, let p = player else { return }
        let isPlaying = p.timeControlStatus != .paused
        if playing != isPlaying { playing = isPlaying }
        if rate != p.defaultRate { rate = p.defaultRate }
        let d = p.currentItem?.duration.seconds ?? 0
        let dur = d.isFinite && d > 0 ? d : 0
        if duration != dur { duration = dur }
        let t = p.currentTime().seconds
        let pos = t.isFinite ? max(0, t) : 0
        if position != pos { position = pos }
    }

    /// 片源里的音轨、字幕（强制字幕不列：那是跟着音轨自动出的）
    private func loadTracks() {
        guard !preview, let item = player?.currentItem else {
            audioNames = []
            subtitleNames = []
            return
        }
        let asset = item.asset
        Task { @MainActor [weak self, weak item] in
            let a = try? await asset.loadMediaSelectionGroup(for: .audible)
            let l = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, let item, item === self.player?.currentItem else { return }
            self.audioGroup = a
            self.legibleGroup = l
            self.audioOptions = a?.options ?? []
            self.subtitleOptions = (l?.options ?? []).filter { !TrackPrefs.isForced($0) }
            self.audioNames = self.audioOptions.map(\.displayName)
            self.subtitleNames = self.subtitleOptions.map(\.displayName)
            self.syncPicks()
        }
    }

    private func syncPicks() {
        guard let item = player?.currentItem else { return }
        let sel = item.currentMediaSelection
        audioPick = audioGroup.flatMap { g in sel.selectedMediaOption(in: g).flatMap { audioOptions.firstIndex(of: $0) } } ?? -1
        subtitlePick = legibleGroup.flatMap { g in sel.selectedMediaOption(in: g).flatMap { subtitleOptions.firstIndex(of: $0) } } ?? -1
    }

    // MARK: 按钮

    func togglePlay() {
        Haptics.light()
        if preview { playing.toggle(); return }
        guard let p = player else { return }
        if p.timeControlStatus == .paused { p.play() } else { p.pause() }
        refresh()
    }

    func skip(_ seconds: Double) {
        Haptics.selection()
        seek(to: position + seconds)
    }

    func seek(to t: Double) {
        let x = duration > 1 ? min(max(0, t), duration - 1) : max(0, t)
        position = x
        guard !preview, let p = player else { return }
        p.seek(to: CMTime(seconds: x, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ r: Float) {
        rate = r
        guard !preview, let p = player else { return }
        // defaultRate：之后每次 play() 都用这个速度（暂停时改了，接着放也是它）
        p.defaultRate = r
        if p.timeControlStatus != .paused { p.rate = r }
    }

    func setBrightness(_ v: Double) {
        brightness = v
        Self.screen?.brightness = CGFloat(v)
    }

    func selectAudio(_ i: Int) {
        audioPick = i
        guard let g = audioGroup, audioOptions.indices.contains(i), let item = player?.currentItem else { return }
        item.select(audioOptions[i], in: g)
        syncPicks()
    }

    func selectSubtitle(_ i: Int) {
        subtitlePick = i
        guard let g = legibleGroup, let item = player?.currentItem else { return }
        if subtitleOptions.indices.contains(i) {
            item.select(subtitleOptions[i], in: g)
        } else if g.allowsEmptySelection {
            item.select(nil, in: g)
        }
        syncPicks()
    }

    func toggleLock() {
        Haptics.light()
        locked.toggle()
        tray = nil
    }

    func toggleTray(_ t: Tray) {
        Haptics.selection()
        if t == .brightness { brightness = Double(Self.screen?.brightness ?? CGFloat(brightness)) }
        tray = tray == t ? nil : t
    }

    private static var screen: UIScreen? { VideoOrientation.activeScene?.screen }
}

// MARK: - 挂进系统播放器

/// CuvenPlayerViewController 里挂的那一层：平时完全透明、不接点按；半折（横着的折痕）时整层变成上下两块，
/// 同时收起系统播放器自己的控件
@MainActor
final class TabletopPlayerHost {
    let model = TabletopPlayerModel()
    private var host: UIHostingController<TabletopPlayerLayer>?

    func install(in vc: AVPlayerViewController, onActiveChange: @escaping (Bool) -> Void) {
        let h = UIHostingController(rootView: TabletopPlayerLayer(model: model))
        h.view.backgroundColor = .clear
        h.view.isUserInteractionEnabled = false
        vc.addChild(h)
        h.view.frame = vc.view.bounds
        h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.addSubview(h.view)
        h.didMove(toParent: vc)
        host = h
        model.onClose = { [weak vc] in vc?.dismiss(animated: true) }
        model.onActiveChange = { [weak vc, weak h] on in
            h?.view.isUserInteractionEnabled = on
            vc?.showsPlaybackControls = !on
            onActiveChange(on)
        }
    }

    /// 系统播放器自己也往这一层里加东西：每次排版都把面板放回最上面
    func keepOnTop() {
        guard let v = host?.view, let s = v.superview, s.subviews.last !== v else { return }
        s.bringSubviewToFront(v)
    }

    /// 开始放一集（剧集接下一集也是）：片名卡、「下一集」跟着换
    func show(_ req: PlayRequest) {
        model.title = req.title
        model.subtitle = req.subtitle
        model.artwork = req.artwork
        model.hasNext = !req.queue.isEmpty
    }
}

// MARK: - 版面

/// 盖在系统播放器上的整层。外面一层守着安全区、里面一层铺满整屏，两层的框一比就是四边的安全区
///（加了 .ignoresSafeArea() 的那一层自己读到的安全区是 0，和 DuoNavLayer 同一个量法）
struct TabletopPlayerLayer: View {
    let model: TabletopPlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { safe in
            let sf = safe.frame(in: .global)
            GeometryReader { full in
                let ff = full.frame(in: .global)
                let insets = EdgeInsets(top: max(0, sf.minY - ff.minY), leading: max(0, sf.minX - ff.minX),
                                        bottom: max(0, ff.maxY - sf.maxY), trailing: max(0, ff.maxX - sf.maxX))
                let fold = model.preview ? TabletopFold.preview(full.size) : TabletopFold.horizontal(in: full)
                ZStack {
                    if model.active, let f = model.fold {
                        TabletopLayout(model: model, fold: f, size: full.size, insets: insets)
                            .transition(.opacity)
                    }
                }
                .frame(width: full.size.width, height: full.size.height)
                .onChange(of: fold, initial: true) { _, f in model.setFold(f) }
            }
            .ignoresSafeArea()
        }
        // 半折 / 摊平时整层淡入淡出（「减弱动态效果」时直接换：F59）
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.active)
    }
}

private struct TabletopLayout: View {
    let model: TabletopPlayerModel
    let fold: CGRect
    let size: CGSize
    let insets: EdgeInsets

    var body: some View {
        let g = TabletopStyle.gap
        VStack(spacing: 0) {
            TabletopVideo(model: model)
                .frame(width: size.width, height: max(0, fold.minY))
            // 折痕那一条（含系统要求的边距）空着
            Color.clear
                .frame(height: fold.height)
            TabletopPanel(model: model)
                .frame(maxWidth: 720)
                .padding(.leading, insets.leading + g)
                .padding(.trailing, insets.trailing + g)
                .padding(.top, g)
                .padding(.bottom, max(insets.bottom, g) + g)
                .frame(width: size.width, height: max(0, size.height - fold.maxY))
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
    }
}

/// 上面那块：画面按比例放进去。播放器在屏上、App 在前台时才接上（不然交回系统播放器那一层，画中画也用它）
private struct TabletopVideo: View {
    let model: TabletopPlayerModel

    var body: some View {
        if model.preview {
            RemoteImage(url: model.artwork.flatMap { URL(string: $0) }, maxPixel: 1400, contentMode: .fit,
                        placeholder: DSFill.placeholder)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        } else {
            PlayerLayerSurface(player: model.visible ? model.player : nil)
                .accessibilityHidden(true)
        }
    }
}

private struct PlayerLayerSurface: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> TabletopVideoView { TabletopVideoView() }

    func updateUIView(_ v: TabletopVideoView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }

    static func dismantleUIView(_ v: TabletopVideoView, coordinator: ()) {
        v.playerLayer.player = nil
    }
}

private final class TabletopVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum TabletopStyle {
    /// 块与块之间、离屏边（截图量的：约 8.6 点）
    static let gap: CGFloat = 8
    static let radius: CGFloat = 19
    static let tile = Color(white: 0.13)
    static let tilePressed = Color(white: 0.2)
    static let edge = Color.white.opacity(0.07)
}

/// 下面那块：四行
private struct TabletopPanel: View {
    let model: TabletopPlayerModel

    var body: some View {
        GeometryReader { geo in
            let g = TabletopStyle.gap
            let avail = max(0, geo.size.height - g * 3)
            // 截图的比例 77 : 142 : 51 : 51；面板很高（iPad）时多出来的都给中间那行大块
            let top = min(92, max(52, avail * 0.24))
            let bar = min(60, max(44, avail * 0.16))
            let mid = max(56, avail - top - bar * 2)
            VStack(spacing: g) {
                TabletopTopRow(model: model, height: top)
                    .frame(height: top)
                TabletopTransport(model: model, height: mid)
                    .frame(height: mid)
                TabletopScrubber(model: model)
                    .frame(height: bar)
                    .tabletopLockable(model.locked)
                Group {
                    switch model.tray {
                    case .brightness: TabletopTray(model: model, kind: .brightness)
                    case .volume: TabletopTray(model: model, kind: .volume)
                    case nil: TabletopTools(model: model)
                    }
                }
                .frame(height: bar)
                .tabletopLockable(model.locked)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabletop-panel")
    }
}

// MARK: 第一行：关闭 | 片名卡 | 隔空播放 | 锁定

private struct TabletopTopRow: View {
    let model: TabletopPlayerModel
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let g = TabletopStyle.gap
            // 截图：三颗小块各占（行宽 − 三个间隔）的 16%，片名卡占剩下的
            let unit = ((geo.size.width - g * 3) * 0.162).rounded()
            HStack(spacing: g) {
                Button(action: { model.onClose?() }) {
                    TabletopIcon("xmark", size: 22, weight: .regular)
                }
                .buttonStyle(TabletopTileStyle())
                .frame(width: unit)
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("tabletop-close")
                .tabletopLockable(model.locked)

                TabletopTitleCard(model: model, height: height)
                    .tabletopLockable(model.locked)

                // 系统的选择器按自己的大小画图标（铺满整块时图标有 70 点高：CI 截图）：给它 36 点见方，图标约 25 点，
                // 和别的块上的符号差不多大
                AirPlayButton()
                    .frame(width: 36, height: 36)
                    .frame(width: unit)
                    .frame(maxHeight: .infinity)
                    .background(TabletopTileBackground(pressed: false))
                    .accessibilityLabel("隔空播放")
                    .tabletopLockable(model.locked)

                // 锁着时这一块亮起来（白底黑锁），一眼看得出现在点不动
                Button(action: { model.toggleLock() }) {
                    TabletopIcon(model.locked ? "lock.fill" : "lock.open", size: 21, weight: .medium,
                                 color: model.locked ? .black : .white)
                }
                .buttonStyle(TabletopTileStyle(lit: model.locked))
                .frame(width: unit)
                .accessibilityLabel(model.locked ? "解锁控制" : "锁定控制")
                .accessibilityIdentifier("tabletop-lock")
            }
        }
    }
}

/// 片名卡：小画面 + 片名 + 第几集（只是看的，不是按钮）
private struct TabletopTitleCard: View {
    let model: TabletopPlayerModel
    let height: CGFloat

    var body: some View {
        let thumbH = min(44, max(28, height - 32))
        HStack(spacing: 14) {
            if let url = Self.thumbURL(model.artwork) {
                RemoteImage(url: url, maxPixel: 240, placeholder: DSFill.placeholder)
                    .frame(width: (thumbH * 16 / 9).rounded(), height: thumbH)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DSFill.hairline, lineWidth: 0.5))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let s = model.subtitle, !s.isEmpty {
                    Text(s)
                        .font(.subheadline)
                        .foregroundStyle(DSInk.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TabletopTileBackground(pressed: false))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tabletop-title")
    }

    /// Apple 图床按宽度要小图，TMDB 换小一档
    static func thumbURL(_ raw: String?) -> URL? {
        TMDBImage.url(AppleImage.sized(raw, width: 240), "w300")
    }
}

/// 隔空播放：系统的选择器（列出 Apple TV、隔空播放音箱）
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = UIColor(Theme.accent)
        v.prioritizesVideoDevices = true
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

// MARK: 第二行：后退 10 秒 | 播放 / 暂停 | 前进 10 秒

private struct TabletopTransport: View {
    let model: TabletopPlayerModel
    let height: CGFloat

    var body: some View {
        let skip = min(46, max(28, height * 0.3))
        HStack(spacing: TabletopStyle.gap) {
            Button(action: { model.skip(-10) }) {
                TabletopIcon("gobackward.10", size: skip, weight: .light)
            }
            .buttonStyle(TabletopTileStyle())
            .accessibilityLabel("后退 10 秒")
            .accessibilityIdentifier("tabletop-back")

            Button(action: { model.togglePlay() }) {
                TabletopIcon(model.playing ? "pause.fill" : "play.fill", size: skip * 1.15, weight: .bold)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(TabletopTileStyle())
            .accessibilityLabel(model.playing ? "暂停" : "播放")
            .accessibilityIdentifier("tabletop-play")

            Button(action: { model.skip(10) }) {
                TabletopIcon("goforward.10", size: skip, weight: .light)
            }
            .buttonStyle(TabletopTileStyle())
            .accessibilityLabel("前进 10 秒")
            .accessibilityIdentifier("tabletop-forward")
        }
        .tabletopLockable(model.locked)
    }
}

// MARK: 第三行：进度条 + 剩余时间

private struct TabletopScrubber: View {
    let model: TabletopPlayerModel

    var body: some View {
        let dur = model.duration
        let at = model.scrub ?? model.position
        let frac = dur > 0 ? min(1, max(0, at / dur)) : 0
        let dragging = model.scrub != nil
        HStack(spacing: 22) {
            GeometryReader { geo in
                let w = geo.size.width
                let knob: CGFloat = dragging ? 26 : 18
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3))
                        .frame(height: 4)
                    Capsule().fill(Color.white)
                        .frame(width: max(4, w * frac), height: 4)
                    Circle().fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: w * frac - knob / 2)
                        .animation(DSMotion.snap, value: dragging)
                }
                .frame(width: w, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard dur > 0, w > 0 else { return }
                            if model.scrub == nil { Haptics.selection() }
                            model.scrub = Double(min(1, max(0, v.location.x / w))) * dur
                        }
                        .onEnded { _ in
                            if let s = model.scrub { model.seek(to: s) }
                            model.scrub = nil
                        }
                )
            }
            Text(dur > 0 ? "-" + Self.clock(max(0, dur - at)) : "--:--")
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .fixedSize()
        }
        .padding(.leading, 26)
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TabletopTileBackground(pressed: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue(dur > 0 ? "已播放 \(Self.spoken(at))，剩余 \(Self.spoken(max(0, dur - at)))" : "")
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: model.skip(10)
            case .decrement: model.skip(-10)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("tabletop-scrubber")
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        let h = t / 3600, m = t / 60 % 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func spoken(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        let h = t / 3600, m = t / 60 % 60, sec = t % 60
        return (h > 0 ? "\(h) 小时 " : "") + "\(m) 分 \(sec) 秒"
    }
}

// MARK: 第四行：播放速度 | 亮度 | 音量 | 音频与字幕 | 下一集 | 全屏

private struct TabletopTools: View {
    let model: TabletopPlayerModel

    var body: some View {
        HStack(spacing: TabletopStyle.gap) {
            Menu {
                Picker("播放速度", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
                    ForEach(TabletopPlayerModel.rates, id: \.self) { r in
                        Text(Self.rateLabel(r)).tag(r)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                TabletopIcon("gauge.with.dots.needle.67percent", size: 21)
            }
            .menuStyle(.button)
            .buttonStyle(TabletopTileStyle())
            .accessibilityLabel("播放速度")
            .accessibilityValue(Self.rateLabel(model.rate))
            .accessibilityIdentifier("tabletop-speed")

            Button(action: { model.toggleTray(.brightness) }) {
                TabletopIcon("sun.max", size: 21)
            }
            .buttonStyle(TabletopTileStyle())
            .accessibilityLabel("亮度")
            .accessibilityIdentifier("tabletop-brightness")

            Button(action: { model.toggleTray(.volume) }) {
                TabletopIcon("speaker.wave.2", size: 21)
            }
            .buttonStyle(TabletopTileStyle())
            .accessibilityLabel("音量")
            .accessibilityIdentifier("tabletop-volume")

            Menu {
                if model.audioNames.count > 1 {
                    Picker("音频", selection: Binding(get: { model.audioPick }, set: { model.selectAudio($0) })) {
                        ForEach(model.audioNames.indices, id: \.self) { i in
                            Text(model.audioNames[i]).tag(i)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Picker("字幕", selection: Binding(get: { model.subtitlePick }, set: { model.selectSubtitle($0) })) {
                    Text("关").tag(-1)
                    ForEach(model.subtitleNames.indices, id: \.self) { i in
                        Text(model.subtitleNames[i]).tag(i)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                TabletopIcon("captions.bubble", size: 21)
            }
            .menuStyle(.button)
            .buttonStyle(TabletopTileStyle())
            .accessibilityLabel("音频与字幕")
            .accessibilityIdentifier("tabletop-tracks")

            if model.hasNext {
                Button(action: {
                    Haptics.light()
                    model.onNext?()
                }) {
                    TabletopIcon("forward.end", size: 21)
                }
                .buttonStyle(TabletopTileStyle())
                .accessibilityLabel("下一集")
                .accessibilityIdentifier("tabletop-next")
            }

            Button(action: {
                Haptics.light()
                model.goFullscreen()
            }) {
                TabletopIcon("arrow.up.left.and.arrow.down.right", size: 20)
            }
            .buttonStyle(TabletopTileStyle())
            .accessibilityLabel("全屏")
            .accessibilityIdentifier("tabletop-fullscreen")
        }
    }

    /// 0.5×、0.75×、1×（正常）、1.25×……
    static func rateLabel(_ r: Float) -> String {
        r == 1 ? "1×（正常）" : String(format: "%g×", Double(r))
    }
}

/// 第四行展开成一条：亮度（屏幕亮度）/ 音量（系统音量，和侧边的音量键同一个）
private struct TabletopTray: View {
    let model: TabletopPlayerModel
    let kind: TabletopPlayerModel.Tray

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: kind == .brightness ? "sun.max.fill" : "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24)
                .accessibilityHidden(true)
            switch kind {
            case .brightness:
                Slider(value: Binding(get: { model.brightness }, set: { model.setBrightness($0) }), in: 0...1)
                    .tint(.white)
                    .accessibilityLabel("亮度")
            case .volume:
                SystemVolumeSlider()
                    .frame(height: 34)
                    .accessibilityLabel("音量")
            }
            Button(action: { model.toggleTray(kind) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("收起")
            .accessibilityIdentifier("tabletop-tray-close")
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TabletopTileBackground(pressed: false))
        .transition(.opacity)
    }
}

/// 系统音量：只有滑杆（隔空播放在第一行）
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .white
        return v
    }

    func updateUIView(_ v: MPVolumeView, context: Context) {}
}

// MARK: - 块的样子

private struct TabletopIcon: View {
    let name: String
    let size: CGFloat
    let weight: Font.Weight
    let color: Color

    init(_ name: String, size: CGFloat, weight: Font.Weight = .regular, color: Color = .white) {
        self.name = name
        self.size = size
        self.weight = weight
        self.color = color
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

/// 深灰圆角块 + 一圈很淡的边（截图的样子）；按下去略亮
private struct TabletopTileBackground: View {
    var pressed: Bool
    var lit = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TabletopStyle.radius, style: .continuous)
        shape
            .fill(lit ? Color.white : (pressed ? TabletopStyle.tilePressed : TabletopStyle.tile))
            .overlay(shape.strokeBorder(TabletopStyle.edge, lineWidth: 1))
    }
}

/// 整块都是按钮（点得到的范围就是那一块：C33 / I4）；按下去略亮、略缩（「减弱动态效果」时不缩：F59）
private struct TabletopTileStyle: ButtonStyle {
    var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TabletopTileBackground(pressed: configuration.isPressed, lit: lit))
            .contentShape(RoundedRectangle(cornerRadius: TabletopStyle.radius, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(DSMotion.press, value: configuration.isPressed)
    }
}

private extension View {
    /// 锁定时：变暗、点不动
    func tabletopLockable(_ locked: Bool) -> some View {
        self
            .opacity(locked ? 0.3 : 1)
            .allowsHitTesting(!locked)
            .disabled(locked)
            .animation(DSMotion.snap, value: locked)
    }
}

// MARK: - 截图用（DEBUG）

#if DEBUG
/// UI 测试 / 截图：演示数据加上 -CuvenTabletop YES，启动后弹一个假的播放页，折痕固定在屏正中（模拟器折不了）。
/// 不接播放器（演示数据本来就放不了），画面是演示用的合成图
@MainActor
enum TabletopPreview {
    static func presentIfRequested() {
        guard DemoData.enabled, UserDefaults.standard.bool(forKey: "CuvenTabletop") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let m = TabletopPlayerModel()
            m.preview = true
            m.title = "灯火人间"
            m.subtitle = "第 2 集 · 别回头"
            m.artwork = "demo://backdrop/41"
            m.hasNext = true
            // 不锁方向（不用 VideoHostingController）：iPad 上要竖着才有那条横着的折痕
            let vc = UIHostingController(rootView: TabletopPlayerLayer(model: m))
            vc.view.backgroundColor = .black
            vc.modalPresentationStyle = .fullScreen
            m.onClose = { [weak vc] in vc?.dismiss(animated: true) }
            UIApplication.topViewController()?.present(vc, animated: true)
        }
    }
}
#endif
