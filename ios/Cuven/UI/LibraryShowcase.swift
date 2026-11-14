import SwiftUI
import AVFoundation

// MARK: - 资料库：电影感的「展映」，一部电影一章（新片在前）
//
// 依据（编号见 docs/ios-design.md）：保留满屏画幅、钉住、收回 16:9、静音预告片与播放 / 暂停 + 进度环（T1、T30、F77），
// 每章只留三样：
//   ① 画幅：一块 16:9 先放大到铺满整屏，钉住不动；居中是字标和一行「年份 · 类型」，往上滚先淡出、压暗层跟着退；
//      再往上滚，画幅收回成一整幅 16:9，下沿始终咬着介绍面板的上沿（同一套几何：k = 间隙 / 16:9 的高；跟着手指走：F54、S10）。
//      这一章在屏幕中间时放它的预告片（静音、从第 10 秒起、循环；系统关了「自动播放视频预览」就停在那儿等人点：F77、S17），
//      右上角一颗播放 / 暂停 + 进度环；没有预告片就给画面一段极慢的推镜（「减弱动态效果」打开时不推：F59）。
//   ② 介绍：简介（三行）和两颗同样大小的钮「播放」「详情」（C35、C36、S17）。
//   ③ 章与章之间只有留白（F3、F12）。
// 去掉了：评分胶囊、演职员一行、剧照排、章间的渐隐线、头部的口号（F80、F3）。
// 标题「资料库」是 Large Title 粗体，压在第一章的画面上、随页面滚走（C13、F15、F19）。

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var trailer = ShowcaseTrailer()
    @State private var active: String?
    @State private var covered = false

    var body: some View {
        let list = order
        ZoomStack {
            GeometryReader { geo in
                let vh = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
                let vw = geo.size.width
                let top = geo.safeAreaInsets.top
                let margin = DSMetrics(width: vw).margin
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if list.isEmpty {
                            emptyState
                                .frame(height: vh)
                                .overlay(alignment: .top) { ShowcaseHeader(top: top, margin: margin).allowsHitTesting(false) }
                        }
                        ForEach(list) { v in
                            ShowcaseChapter(video: v, vw: vw, vh: vh, top: top, trailer: trailer,
                                            isActive: active == v.path,
                                            report: { center, isCovered in
                                                // 换章时连「画面是否滚出屏幕」一起换成这一章的（不依赖刚写进去的 active 能不能马上读回来）
                                                if center && active != v.path {
                                                    active = v.path
                                                    covered = isCovered
                                                } else if active == v.path && covered != isCovered {
                                                    covered = isCovered
                                                }
                                            })
                            // 标题压在第一章的画面上、随页面滚走（不是钉在顶上的导航栏）
                            .overlay(alignment: .top) {
                                if v.path == list.first?.path {
                                    ShowcaseHeader(top: top, margin: margin).allowsHitTesting(false)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
                .background(Color.black)
                .refreshable { await model.refreshAll() }
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            // 挂在导航栈的根内容上（不是挂在 ZoomStack 外面）：推进详情页时根内容才算「不在屏上」，预告片跟着停；
            // 挂在外面的话导航栈本身一直在屏上，推进去以后预告片还在后面静音地放
            .onAppear { trailer.setVisible(true) }
            .onDisappear { trailer.setVisible(false) }
        }
        .onChange(of: active) { _, path in
            guard let path, let v = list.first(where: { $0.path == path }) else { return }
            trailer.mount(v, model: model)
        }
        .onChange(of: covered) { _, c in trailer.setCovered(c) }
    }

    /// 上映日期新的在前；同一天按入库时间；再按片名
    private var order: [Video] {
        model.movies.sorted { a, b in
            let ra = releaseKey(a), rb = releaseKey(b)
            if ra != rb { return ra > rb }
            if a.addedKey != b.addedKey { return a.addedKey > b.addedKey }
            return model.title(a).localizedCompare(model.title(b)) == .orderedAscending
        }
    }

    private func releaseKey(_ v: Video) -> String {
        if let d = model.meta(v)?.releaseDate, !d.isEmpty { return d }
        if let y = model.year(v) { return String(y) + "-00-00" }
        return ""
    }

    /// 还没有片子：载入中只是一个系统转圈（C69：不写含糊的「正在载入…」）；空了、失败了说清下一步，带一颗钮（F87、F88）
    @ViewBuilder private var emptyState: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("没能载入资料库", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await model.refreshAll() } }
            }
        case .ready:
            ContentUnavailableView {
                Label("资料库是空的", systemImage: "film.stack")
            } description: {
                Text("片库里加入电影后，会一部一章地出现在这里。")
            } actions: {
                Button("重新载入") { Task { await model.refreshAll() } }
            }
        }
    }
}

/// 标题：「资料库」Large Title 粗体（F15、F19），和下面的简介、钮同一条左边线（F2）；不放口号（F80）。
/// 底下一层由暗到透明的渐变，让状态栏和标题在画面上看得清（F34）；不用材质（F38：玻璃只给功能层）
struct ShowcaseHeader: View {
    let top: CGFloat
    let margin: CGFloat

    var body: some View {
        Text("资料库")
            .font(.largeTitle.bold())
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, top + 10)
            .padding(.horizontal, margin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .top) {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .black.opacity(0.22), location: 0.55),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: top + 120)
            }
    }
}

// MARK: - 一章

struct ShowcaseChapter: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let vw: CGFloat
    let vh: CGFloat
    let top: CGFloat
    let trailer: ShowcaseTrailer
    let isActive: Bool
    /// (这一章跨着屏幕中线, 画幅已经整个滚出屏幕)
    let report: (Bool, Bool) -> Void
    /// Apple TV 上对上的那一部：画幅用它的无字 16:9 背景、标题用它的字标（预告片也是这一次问来的）
    @State private var atv: AtvLookup?

    var body: some View {
        // 几何：画幅先是一块 16:9（高不超过 74% 屏），放大到铺满；钉住的行程 = 一屏 + 面板压上来的那段 + 停一会儿
        let boxH = min(vw * 9 / 16, vh * 0.74)
        let boxW = boxH * 16 / 9
        let overlap = vh - (top + boxH)
        let hold = vh * 0.16
        let portalH = max(620, vh + overlap + hold)
        let pinMax = max(0, portalH - vh)
        let cover = max(vw / boxW, (vh - top) / boxH)
        let contentTop = portalH - overlap
        let H = vh, T = top
        let margin = DSMetrics(width: vw).margin
        let m = model.meta(video)

        ZStack(alignment: .top) {
            // ① 画幅：一块 16:9，按滚动放大 / 收回，钉在屏上
            // 画幅：这一章的 Apple TV 查询（顺带预告片）→ 全片库的 Apple TV 素材 → TMDB
            ShowcaseMedia(video: video, art: atv?.background ?? model.backgroundArtString(video), trailer: trailer, isActive: isActive)
                .frame(width: boxW, height: boxH)
                .visualEffect { content, proxy in
                    let y = proxy.frame(in: .scrollView(axis: .vertical)).minY - T
                    let pin = min(max(-y, 0), pinMax)
                    let gap = contentTop - pin - T
                    let k = min(max(gap / boxH, 1), cover)
                    return content
                        .scaleEffect(k, anchor: .top)
                        .offset(y: pin)
                }
                .padding(.top, top)
                .frame(width: vw, height: portalH, alignment: .top)
                .clipped()

            // 均匀压暗：字在场时压住画面，字走了就还画面一个干净的满屏（F34：字在画面上要看得清）
            Color.black
                .frame(width: vw, height: vh)
                .visualEffect { content, proxy in
                    let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    let pin = min(max(-y, 0), pinMax)
                    let cp = min(max((-y - H * 0.16) / (H * 0.36), 0), 1)
                    return content.opacity(0.42 * (1 - cp)).offset(y: pin)
                }
                .allowsHitTesting(false)

            // 字标 + 一行信息：居中，往上滚先淡出、略缩、上移
            copy(m)
                .frame(width: vw, height: vh)
                .visualEffect { content, proxy in
                    let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    let pin = min(max(-y, 0), pinMax)
                    let cp = min(max((-y - H * 0.16) / (H * 0.36), 0), 1)
                    return content
                        .scaleEffect(1 - 0.025 * cp)
                        .offset(y: pin - 26 * cp)
                        .opacity(1 - cp)
                }
                .allowsHitTesting(false)

            // 右上角：预告片的播放 / 暂停 + 进度环（拿到预告片才出现：F77 自动播放的预览要有看得见的停止钮）
            if isActive && trailer.loaded && trailer.path == video.path {
                ShowcaseControl(trailer: trailer)
                    .padding(.top, top + 12)
                    // 44 的点按区里画 34 的环：环的右缘落在边距上（F2）
                    .padding(.trailing, max(8, margin - 5))
                    .frame(width: vw, alignment: .topTrailing)
                    .visualEffect { content, proxy in
                        let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                        let pin = min(max(-y, 0), pinMax)
                        let co = 1 - min(max((-y - H * 0.62) / (H * 0.28), 0), 1)
                        return content.opacity(co).offset(y: pin)
                    }
                    .transition(.opacity)
            }

            // ② 介绍面板（黑底，平口顶边压上来）
            ShowcaseIntro(video: video, meta: m, vw: vw)
                .padding(.top, contentTop)
        }
        .frame(width: vw, alignment: .top)
        .task(id: video.path) { atv = await model.atv(for: video) }
        .onGeometryChange(for: [Bool].self) { proxy in
            let f = proxy.frame(in: .scrollView(axis: .vertical))
            let center = f.minY <= H * 0.5 && f.maxY > H * 0.5
            let gone = f.minY + contentTop <= 1
            return [center, gone]
        } action: { v in
            report(v[0], v[1])
        }
    }

    /// 居中：字标（没有字标就是片名，Large Title 粗体），下面一行「年份 · 类型」（Subheadline：F15、F84）
    @ViewBuilder private func copy(_ m: Meta?) -> some View {
        let w = min(vw * 0.84, 460)
        VStack(spacing: 12) {
            if let logo = atv?.logo ?? model.logoArtString(video), !logo.isEmpty {
                LogoImage(url: TMDBImage.url(logo, "w500"), height: vw >= 600 ? 120 : 96, fallback: model.title(video), maxWidth: w * 0.8)
                    .frame(maxWidth: w * 0.8)
            } else {
                Text(model.title(video))
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            let line = info(m)
            if !line.isEmpty {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(width: w)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 2)
        .position(x: vw / 2, y: vh * 0.5)
    }

    /// 一行信息：年份 · 类型（最多两个）
    private func info(_ m: Meta?) -> String {
        var parts: [String] = []
        if let y = model.year(video) { parts.append(String(y)) }
        if let g = m?.genres { parts.append(contentsOf: g.prefix(2)) }
        return parts.joined(separator: " · ")
    }
}

/// 画幅里的内容：画面（没有预告片时慢慢推镜）、预告片（就绪才淡入）、上下两道缓动渐变
struct ShowcaseMedia: View {
    let video: Video
    let art: String?
    let trailer: ShowcaseTrailer
    let isActive: Bool
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mine = isActive && trailer.path == video.path
        ZStack {
            RadialGradient(colors: [Color(red: 27 / 255, green: 39 / 255, blue: 64 / 255), Color(red: 10 / 255, green: 15 / 255, blue: 24 / 255), .black],
                           center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0, endRadius: 400)
            RemoteImage(url: TMDBImage.url(art, "w1280"), maxPixel: 1280, placeholder: .clear)
                .scaleEffect(drift ? 1.12 : 1.02)
            if mine {
                VideoSurface(player: trailer.player, gravity: .resizeAspectFill, background: .clear)
                    .opacity(trailer.showing ? 1 : 0)
                    .animation(.easeInOut(duration: 0.8), value: trailer.showing)
                    .allowsHitTesting(false)
            }
            // 上沿 34% → 0（26%），下沿 42% → 0（34%），alpha 走 smoothstep 免得 OLED 上起条带
            LinearGradient(stops: Self.ease(0.34, span: 0.26), startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: Self.ease(0.42, span: 0.34), startPoint: .bottom, endPoint: .top)
        }
        .clipped()
        .onChange(of: isActive && !(mine && trailer.showing) && !reduceMotion, initial: true) { _, still in
            // 拿不到预告片的那一章：画面极慢地推近、再拉远（26 秒一趟）；「减弱动态效果」打开时不推（F59）
            if still {
                withAnimation(.easeInOut(duration: 26).repeatForever(autoreverses: true)) { drift = true }
            } else {
                withAnimation(.easeOut(duration: 0.6)) { drift = false }
            }
        }
    }

    private static func ease(_ peak: Double, span: Double) -> [Gradient.Stop] {
        (0...10).map { i in
            let t = Double(i) / 10
            let s = 1 - t * t * (3 - 2 * t)
            return Gradient.Stop(color: .black.opacity(peak * s), location: span * t)
        } + [Gradient.Stop(color: .clear, location: 1)]
    }
}

/// 右上角那颗：播放 / 暂停 + 进度环（环 34、2.5 宽：底 34% 白、值纯白），点按区 44（C33）；
/// 播放 ↔ 暂停用系统的符号替换动效（F57）
struct ShowcaseControl: View {
    let trailer: ShowcaseTrailer

    var body: some View {
        Button { trailer.togglePause() } label: {
            ZStack {
                Circle().stroke(Color.white.opacity(0.34), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.001, trailer.progress))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: trailer.progress)
                Image(systemName: trailer.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.25), value: trailer.paused)
            }
            .frame(width: 34, height: 34)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel(trailer.paused ? "播放预告片" : "暂停预告片")
        .accessibilityIdentifier("showcase-trailer")
    }
}

/// 介绍面板（黑底，平口顶边压上来）：只留简介（三行，Body 宽松行距：F21；全文在「详情」里：F24）
/// 和两颗同样大小的钮（C36：主次靠样子不靠大小）——「播放」白色胶囊黑字、「详情」半透明材质（S17、.dsPlay / .dsSecondary）。
/// 和下一章之间只靠留白（F3、F12）
struct ShowcaseIntro: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let meta: Meta?
    let vw: CGFloat

    var body: some View {
        let metrics = DSMetrics(width: vw)
        let resume = model.playback.resumePosition(video.path) != nil
        VStack(alignment: .leading, spacing: 22) {
            if let text = meta?.overview, !text.isEmpty {
                Text(text)
                    .font(.body.leading(.loose))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: 620, alignment: .leading)
            }
            HStack(spacing: 12) {
                // F85：按钮是动词；看了一半的直接接着放（S17）
                Button { play() } label: {
                    Label(resume ? "继续播放" : "播放", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsPlay)
                .accessibilityIdentifier("showcase-play")

                NavigationLink(value: Route.movie(video)) {
                    Text("详情")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsSecondary)
                .accessibilityIdentifier("library-movie")
            }
            .frame(maxWidth: 460)
        }
        .padding(.horizontal, metrics.margin)
        .padding(.top, 28)
        .padding(.bottom, metrics.shelfGap + 16)
        .frame(width: vw, alignment: .leading)
        .background(Color.black)
    }

    private func play() {
        PlayerCoordinator.shared.play(PlayRequest(path: video.path, name: video.name, title: model.title(video),
                                                  subtitle: model.year(video).map { String($0) },
                                                  artwork: model.backgroundArtString(video)), model: model)
    }
}

// MARK: - 预告片：同一时刻只挂一段（在屏幕中间那一章），静音、从第 10 秒起、放完回到第 10 秒

@MainActor
@Observable
final class ShowcaseTrailer {
    let player = AVPlayer()
    private(set) var path: String?
    /// 拿到了预告片（右上角那颗钮才出现）
    private(set) var loaded = false
    /// 真的在出画面了（画面这时才淡入，免得黑一下）
    private(set) var showing = false
    private(set) var progress: Double = 0
    private(set) var paused = false
    private var visible = true
    private var covered = false
    /// 正片播放器盖在上面（全屏）：预告片停着
    private var playerUp = false

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var start: Double = 10

    @ObservationIgnored private var playerObservers: [NSObjectProtocol] = []

    init() {
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .pause
        let nc = NotificationCenter.default
        playerObservers = [
            nc.addObserver(forName: .cuvenPlayerPresented, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.playerUp = true; self?.sync() }
            },
            nc.addObserver(forName: .cuvenPlayerClosed, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.playerUp = false; self?.sync() }
            },
        ]
    }

    func mount(_ v: Video, model: AppModel) {
        guard path != v.path else { return }
        unmount()
        path = v.path
        // F77、S17：系统「自动播放视频预览」关着时不自己放，停在那儿等人点右上角那颗钮
        paused = !UIAccessibility.isVideoAutoplayEnabled
        loadTask = Task { [weak self] in
            let list = await model.trailers(for: v)
            guard let self, !Task.isCancelled, self.path == v.path,
                  let t = list.first, let url = URL(string: t.hls) else { return }
            self.attach(url)
        }
    }

    func unmount() {
        loadTask?.cancel()
        loadTask = nil
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        path = nil
        loaded = false
        showing = false
        progress = 0
        paused = false
    }

    func togglePause() {
        paused.toggle()
        Haptics.light()
        sync()
    }

    /// 切到别的标签 / 回来
    func setVisible(_ on: Bool) {
        visible = on
        sync()
    }

    /// 这一章的画面整个滚出屏幕：停，但不卸载
    func setCovered(_ on: Bool) {
        covered = on
        sync()
    }

    private func sync() {
        guard player.currentItem != nil else { return }
        if visible && !covered && !paused && !playerUp { player.play() } else { player.pause() }
    }

    private func attach(_ url: URL) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 6
        statusObservation = item.observe(\.status) { [weak self] it, _ in
            let status = it.status
            let duration = it.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === it else { return }
                if status == .readyToPlay, !self.loaded {
                    // 预告片开头那几秒基本都是发行方厂标、分级卡：从第 10 秒进（太短的片子从头）
                    self.start = duration.isFinite && duration > 25 ? 10 : 0
                    self.loaded = true
                    self.player.seek(to: CMTime(seconds: self.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { _ in
                        Task { @MainActor [weak self] in self?.sync() }
                    }
                } else if status == .failed {
                    self.unmount()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.seek(to: CMTime(seconds: self.start, preferredTimescale: 600)) { _ in
                    Task { @MainActor [weak self] in self?.sync() }
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor [weak self] in self?.tick(t) }
        }
        player.replaceCurrentItem(with: item)
    }

    private func tick(_ t: CMTime) {
        guard let item = player.currentItem else { return }
        let d = item.duration.seconds
        if d.isFinite, d > start { progress = min(1, max(0, (t.seconds - start) / (d - start))) }
        let on = player.timeControlStatus == .playing && t.seconds >= start - 0.5
        if on && !showing { showing = true }
    }
}
