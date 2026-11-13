import SwiftUI
import AVFoundation

// MARK: - 资料库：和网页版一样的「展映」（web/index.html 的 lib-showcase）
//
// 顶上「资料库 / Cuven 为你提供严格品质的影片」，浮在第一章的画面上，底下一层渐进模糊。
// 一部电影一章（新片在前），每章三段：
//   ① 画幅：一块 16:9 先放大到铺满整屏，钉住不动；「2026 · 科幻 · 冒险 · 116 分钟」和字标居中，往上滚先淡出，
//      压暗层跟着退；再往上滚，画幅收回成一整幅 16:9，下沿始终咬着介绍面板的上沿（同一套几何：k = 间隙 / 16:9 的高）。
//      这一章在屏幕中间时放它的预告片（Apple TV 的公开预告，静音、从第 10 秒起、循环），右上角一颗播放 / 暂停 + 进度环；
//      没有预告片就给剧照一段极慢的推镜。
//   ② 介绍：简介、「评分 6.5」小胶囊、「导演 …　　主演 …」、两颗等宽的钮「▶ 播放」「影片详情」。
//   ③ 剧照：「剧照」一排 16:9 大图；最后一条两端渐隐的分隔线。

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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if list.isEmpty {
                            emptyState.frame(height: vh)
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
                            // 标题跟网页版一样压在第一章的画面上、随页面滚走（不是钉在顶上的导航栏）
                            .overlay(alignment: .top) {
                                if v.path == list.first?.path {
                                    ShowcaseHeader(top: top).allowsHitTesting(false)
                                }
                            }
                        }
                        if !list.isEmpty {
                            Text("共 \(list.count) 部")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(height: 120)
                                .frame(maxWidth: .infinity)
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

    /// 网页版 sortOrder：上映日期新的在前；同一天按入库时间；再按片名
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(.white.opacity(0.3))
            Text(model.phase == .loading || model.phase == .idle ? "正在载入资料库…" : "资料库是空的").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }
}

/// 标题浮在画面上：「资料库」32 号 800 粗，「Cuven 为你提供严格品质的影片」14 号 40% 白；底下四层模糊叠出来的渐进模糊 + 一层由暗到透明
struct ShowcaseHeader: View {
    let top: CGFloat

    var body: some View {
        let h = top + 104
        VStack(alignment: .leading, spacing: 6) {
            Text("资料库")
                .font(.system(size: 32, weight: .heavy))
                .tracking(-0.64)
                .foregroundStyle(.white)
            Text("Cuven 为你提供严格品质的影片")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, top + 28)
        .padding(.horizontal, Theme.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: h, alignment: .top)
        .background(alignment: .top) {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.3), .init(color: .clear, location: 0.8)],
                                         startPoint: .top, endPoint: .bottom))
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.66), location: 0),
                    .init(color: .black.opacity(0.5), location: 0.3),
                    .init(color: .black.opacity(0.26), location: 0.6),
                    .init(color: .black.opacity(0.08), location: 0.84),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: h + 64)
            .environment(\.colorScheme, .dark)
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
        // 网页版的几何：画幅先是一块 16:9（高不超过 74% 屏），放大到铺满；钉住的行程 = 一屏 + 面板压上来的那段 + 停一会儿
        let boxH = min(vw * 9 / 16, vh * 0.74)
        let boxW = boxH * 16 / 9
        let overlap = vh - (top + boxH)
        let hold = vh * 0.16
        let portalH = max(620, vh + overlap + hold)
        let pinMax = max(0, portalH - vh)
        let cover = max(vw / boxW, (vh - top) / boxH)
        let contentTop = portalH - overlap
        let H = vh, T = top
        let m = model.meta(video)

        ZStack(alignment: .top) {
            // ① 画幅：一块 16:9，按滚动放大 / 收回，钉在屏上
            ShowcaseMedia(video: video, art: atv?.background ?? m?.backdrop ?? m?.poster, trailer: trailer, isActive: isActive)
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

            // 均匀压暗：标题在场时压住画面，标题走了就还画面一个干净的满屏
            Color.black
                .frame(width: vw, height: vh)
                .visualEffect { content, proxy in
                    let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    let pin = min(max(-y, 0), pinMax)
                    let cp = min(max((-y - H * 0.16) / (H * 0.36), 0), 1)
                    return content.opacity(0.42 * (1 - cp)).offset(y: pin)
                }
                .allowsHitTesting(false)

            // 「2026 · 科幻 · 冒险 · 116 分钟」+ 字标：居中，往上滚先淡出、略缩、上移
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

            // 右上角：预告片的播放 / 暂停 + 进度环（拿到预告片才出现）
            if isActive && trailer.loaded && trailer.path == video.path {
                ShowcaseControl(trailer: trailer)
                    .padding(.top, top + 18)
                    .padding(.trailing, 20)
                    .frame(width: vw, alignment: .topTrailing)
                    .visualEffect { content, proxy in
                        let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                        let pin = min(max(-y, 0), pinMax)
                        let co = 1 - min(max((-y - H * 0.62) / (H * 0.28), 0), 1)
                        return content.opacity(co).offset(y: pin)
                    }
                    .transition(.opacity)
            }

            // ② ③ 介绍面板（黑底，平口顶边压上来）
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

    @ViewBuilder private func copy(_ m: Meta?) -> some View {
        let w = min(vw * 0.88, 420)
        VStack(spacing: 0) {
            let line = eyebrow(m)
            if !line.isEmpty {
                Text(line)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(0.18)
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
            }
            if let logo = atv?.logo ?? m?.logo, !logo.isEmpty {
                LogoImage(url: TMDBImage.url(logo, "w500"), height: 96, fallback: model.title(video), maxWidth: w * 0.78)
                    .frame(maxWidth: w * 0.78)
                    .padding(.top, 14)
            } else {
                Text(model.title(video))
                    .font(.system(size: 38, weight: .semibold))
                    .tracking(-0.23)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 10)
            }
        }
        .frame(width: w)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
        // 网页版 top: 49%
        .position(x: vw / 2, y: vh * 0.49)
    }

    /// 网页版的 eyebrow：年份 · 两个类型 · 片长
    private func eyebrow(_ m: Meta?) -> String {
        var parts: [String] = []
        if let y = m?.year?.prefix(4), !y.isEmpty { parts.append(String(y)) } else if let y = model.year(video) { parts.append(String(y)) }
        if let g = m?.genres, !g.isEmpty { parts.append(g.prefix(2).joined(separator: " · ")) }
        if let r = m?.runtime, r > 0 { parts.append("\(r) 分钟") }
        return parts.joined(separator: " · ")
    }
}

/// 画幅里的内容：剧照（没有预告片时慢慢推镜）、预告片（就绪才淡入）、上下两道缓动渐变
struct ShowcaseMedia: View {
    let video: Video
    let art: String?
    let trailer: ShowcaseTrailer
    let isActive: Bool
    @State private var drift = false

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
            // 网页版 .sc-scrim：上沿 34% → 0（26%），下沿 42% → 0（34%），alpha 走 smoothstep 免得 OLED 上起条带
            LinearGradient(stops: Self.ease(0.34, span: 0.26), startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: Self.ease(0.42, span: 0.34), startPoint: .bottom, endPoint: .top)
        }
        .clipped()
        .onChange(of: isActive && !(mine && trailer.showing), initial: true) { _, still in
            // 拿不到预告片的那一章：剧照极慢地推近、再拉远（26 秒一趟）
            if still && isActive {
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

/// 右上角那颗：播放 / 暂停 + 进度环（38，环 2.5 宽：底 34% 白、值纯白）
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
            }
            .frame(width: 34, height: 34)
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel(trailer.paused ? "播放预告片" : "暂停预告片")
        .accessibilityIdentifier("showcase-trailer")
    }
}

/// 介绍面板：简介（17 半粗 62% 白）、「评分 6.5」、演职员、两颗等宽的钮；剧照一排；分隔线
struct ShowcaseIntro: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let meta: Meta?
    let vw: CGFloat

    var body: some View {
        let gutter = max(20, vw * 0.056)
        let stills = (meta?.stills ?? []).compactMap { $0.thumb ?? $0.url }.prefix(10)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(meta?.overview.flatMap { $0.isEmpty ? nil : $0 } ?? "这部影片暂时没有简介。")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(0.19)
                    .lineSpacing(7)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                if let r = meta?.rating, r > 0 {
                    Text(String(format: "评分 %.1f", r))
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(0.24)
                        .foregroundStyle(.white.opacity(0.74))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        .padding(.top, 22)
                }
                let credits = creditsLine
                if !credits.isEmpty {
                    Text(credits)
                        .font(.system(size: 14, weight: .semibold))
                        .lineSpacing(5)
                        .foregroundStyle(.white.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 20)
                }
                HStack(spacing: 10) {
                    Button { play() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill").font(.system(size: 14))
                            Text("播放")
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Color.white, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.96))
                    .accessibilityIdentifier("showcase-play")

                    NavigationLink(value: Route.movie(video)) {
                        Text("影片详情")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.96))
                    .accessibilityIdentifier("library-movie")
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, gutter)
            .padding(.top, 38)

            if !stills.isEmpty {
                Text("剧照")
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.78)
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, gutter)
                    .padding(.top, 34)
                    .padding(.bottom, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(Array(stills.enumerated()), id: \.offset) { _, s in
                            Color(red: 17 / 255, green: 17 / 255, blue: 20 / 255)
                                .overlay { RemoteImage(url: TMDBImage.url(s, "w780"), maxPixel: 900, placeholder: .clear) }
                                .frame(width: vw * 0.78, height: vw * 0.78 * 9 / 16)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.bottom, 6)
                }
                .contentMargins(.horizontal, gutter, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            }

            // 章与章之间：一条两端渐隐的线
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.12), location: 0.2),
                .init(color: .white.opacity(0.12), location: 0.8),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .padding(.horizontal, gutter)
            .padding(.top, 40)
        }
        .padding(.bottom, 48)
        .frame(width: vw, alignment: .leading)
        .background(Color.black)
    }

    /// 「导演 许晴　　主演 叶舟、林夏、沈川」
    private var creditsLine: String {
        var parts: [String] = []
        if let d = meta?.director, !d.isEmpty { parts.append("导演 " + d) }
        if let c = meta?.cast, !c.isEmpty { parts.append("主演 " + c.prefix(3).map(\.name).joined(separator: "、")) }
        return parts.joined(separator: "　　")
    }

    private func play() {
        PlayerCoordinator.shared.play(PlayRequest(path: video.path, name: video.name, title: model.title(video),
                                                  subtitle: model.year(video).map { String($0) },
                                                  artwork: meta?.backdrop ?? meta?.poster), model: model)
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
