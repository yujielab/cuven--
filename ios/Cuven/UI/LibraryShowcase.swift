import SwiftUI
import AVFoundation

// MARK: - 探索（以前叫「资料库」，用户要求改名）：和网页版的「展映」（lib-showcase）同一套版式，一部电影一章
//
// · 顺序（用户要求「随机排序，高分和值得一看的优先，允许不同年份，每次打开都不一样」）：AppModel.exploreMovies——
//   按这一轮的种子加权随机排（分高的大概率在前），同一类型、同一年不挨着；每次启动、离开半小时以上回来、再点一下「探索」换一轮。
//   全片库放完一轮以后首尾相接、一直往下放（网页版的环形队列）。
// · 只放有预告片的电影：预告片就是详情页拿到的那一份（Apple TV 上的公开预告，AppModel.trailers(for:)）；
//   哪部有、哪部没有在后台查（AppModel.scanTrailers），查到的记在本地；还没查到的那一部后面先不放，查到了再往后接。
// · 每一章：
//   ① 画幅：一块 16:9 先放大到铺满整屏，钉住不动；中间是一行「年份 · 类型 · 片长」和字标（没有字标就是片名），往上滚先淡出、压暗层跟着退；
//      再往上滚，画幅收回成一整幅 16:9，下沿始终咬着介绍面板的上沿（网页版同一套几何：k = 间隙 / 16:9 的高，跟着手指走：F54、S10）。
//      在屏幕中间那一章放它的预告片：静音、从第 10 秒起、循环；系统关了「自动播放视频预览」就停着等人点（F77、S17），右上角播放 / 暂停 + 进度环。
//   ② 介绍面板（黑底，平口顶边压上来）：评分、导演与主演（简介只在详情页：用户要求）、「播放」「影片详情」、一排剧照，章与章之间一道两头渐隐的细线（网页版的内容）。
//   章的高度跟着介绍面板走（之前按画幅的行程定高，面板短的那一章底下会空出一大块黑）。
// · 标题「资料库」与一句「Cuven 为你提供严格品质的影片」压在第一章的画面上、随页面滚走（网页版的 library-header）。

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var trailer = ShowcaseTrailer()
    /// 正跨着屏幕中线的那一章（id 带着圈数：同一部片转第二圈是另一章）
    @State private var active: String?
    @State private var covered = false
    /// 这一屏上的先后（各部第一次出现的顺序）：之后后台再查到的新片接在后面，不插进已经排好的位置，画面不会跳一章
    @State private var joined: [String] = []

    /// 一章：第几圈 + 哪一部
    private struct Entry: Identifiable {
        let lap: Int
        let video: Video
        var id: String { "\(lap)|\(video.path)" }
    }

    var body: some View {
        let feed = self.feed
        ZoomStack {
            GeometryReader { geo in
                let vh = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
                // 整页铺满（用户要求：所有元素都能越过安全区）：画幅、预告片连同侧边那一列一起铺满；字留在安全区里
                let lead = geo.safeAreaInsets.leading, trail = geo.safeAreaInsets.trailing
                let vw = geo.size.width + lead + trail
                let top = geo.safeAreaInsets.top
                let margin = DSMetrics(width: geo.size.width).margin + lead
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if feed.isEmpty {
                            emptyState
                                .frame(height: vh)
                                .overlay(alignment: .top) { ShowcaseHeader(top: top, margin: margin).allowsHitTesting(false) }
                        }
                        ForEach(feed) { e in
                            ShowcaseChapter(video: e.video, vw: vw, vh: vh, top: top, lead: lead, trail: trail, trailer: trailer,
                                            isActive: active == e.id,
                                            report: { center, isCovered in
                                                // 换章时连「画面是否滚出屏幕」一起换成这一章的
                                                if center && active != e.id {
                                                    active = e.id
                                                    covered = isCovered
                                                } else if active == e.id && covered != isCovered {
                                                    covered = isCovered
                                                }
                                            })
                            .id(e.id)
                            // 标题压在第一章的画面上、随页面滚走（不是钉在顶上的导航栏）
                            .overlay(alignment: .top) {
                                if e.lap == 0 && e.video.path == feed.first?.video.path {
                                    ShowcaseHeader(top: top, margin: margin).allowsHitTesting(false)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: [.top, .horizontal])
                .background(Color.black)
                .settledRefreshable {
                    await model.refreshAll()
                    // 下拉刷新以后重新按上映日期排（人就在最上面，不会跳）
                    joined = []
                }
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            // 挂在导航栈的根内容上：推进详情页时根内容才算「不在屏上」，预告片跟着停
            .onAppear { trailer.setVisible(true) }
            .onDisappear { trailer.setVisible(false) }
        }
        .onChange(of: active) { _, id in
            guard let id, let e = feed.first(where: { $0.id == id }) else { return }
            trailer.mount(e.video, model: model)
        }
        .onChange(of: covered) { _, c in trailer.setCovered(c) }
        .onChange(of: base.map(\.path), initial: true) { _, paths in joined = paths }
        // 换了一轮（种子变了）：按新的顺序从头排，不再守着上一轮排好的位置
        .onChange(of: model.exploreSeed) { _, _ in joined = [] }
        // 打开资料库时把没查过的接着查（单独起一个任务：切走标签不打断它，正在查就什么也不做）
        .onAppear { Task { await model.scanTrailers() } }
    }

    /// 有预告片的电影：按资料库的顺序；这一屏上已经排好的保持原位，新查到的接在后面
    private var base: [Video] {
        let live = model.exploreMovies
        guard !joined.isEmpty else { return live }
        var fresh: [String: Video] = [:]
        for v in live { fresh[v.path] = v }
        var out = joined.compactMap { fresh.removeValue(forKey: $0) }
        out += live.filter { fresh[$0.path] != nil }
        return out
    }

    /// 放哪些章：全片库查完一轮以后首尾相接（网页版的环形队列），最多铺到 400 章；不到三部不循环
    private var feed: [Entry] {
        let base = self.base
        guard !base.isEmpty else { return [] }
        let laps = model.trailerScanDone && base.count >= 3 ? max(1, min(12, 400 / base.count)) : 1
        return (0..<laps).flatMap { lap in base.map { Entry(lap: lap, video: $0) } }
    }

    /// 还没有能放的：查着的时候只是一个系统转圈（C69）；查完了一部都没有、失败了，说清下一步，带一颗钮（F87、F88）
    @ViewBuilder private var emptyState: some View {
        if case .failed(let message) = model.phase {
            ContentUnavailableView {
                Label("无法载入影片", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await model.refreshAll() } }
            }
        } else if model.trailerScanning || !model.trailerScanDone || model.phase != .ready {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        } else if model.trailerScanFailed {
            ContentUnavailableView {
                Label("无法载入预告片", systemImage: "wifi.exclamationmark")
            } description: {
                Text("请检查网络连接后重试。")
            } actions: {
                Button("重试") { Task { await model.scanTrailers() } }
            }
        } else {
            ContentUnavailableView {
                Label("暂无影片", systemImage: "film.stack")
            } description: {
                Text("带预告片的电影会显示在这里。")
            } actions: {
                Button("重新载入") { Task { await model.refreshAll() } }
            }
        }
    }
}

/// 标题：「资料库」Large Title 粗体（F15、F19）和下面一句「Cuven 为你提供严格品质的影片」（网页版 library-sub），和介绍同一条左边线（F2）。
/// 底下一层由暗到透明的渐变，让状态栏和标题在画面上看得清（F34）
struct ShowcaseHeader: View {
    let top: CGFloat
    let margin: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("探索")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("Cuven 精选的高品质影片")
                .font(.subheadline)
                .foregroundStyle(DSInk.secondary)
        }
        .padding(.top, top + 10)
        .padding(.horizontal, margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .black.opacity(0.25), location: 0.55),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: top + 150)
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
    /// 两侧安全区（侧边那一列）：画幅铺满整个窗口，字、钮按它们留在安全区里
    var lead: CGFloat = 0
    var trail: CGFloat = 0
    let trailer: ShowcaseTrailer
    let isActive: Bool
    /// (这一章跨着屏幕中线, 画幅已经整个滚出屏幕)
    let report: (Bool, Bool) -> Void
    /// Apple TV 上对上的那一部：画幅用它的无字 16:9 背景、标题用它的字标（预告片也是这一次问来的）
    @State private var atv: AtvLookup?
    /// 全量的 TMDB（导演、主演、剧照）
    @State private var full: Meta?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 「减弱动态效果」（设计轮 2（并行·library）：F59、F60）：画幅不跟着滚动缩放，一直铺满、钉住，介绍面板从下面盖上来；
        // 中间那一行信息和字标只淡出、不缩不挪。visualEffect 的闭包里只能拿值，先取出来
        let still = reduceMotion
        // 右上那颗钮出现 / 消失时淡入淡出（以前预告片一拿到就「啪」地冒出来）
        let controlOn = isActive && trailer.loaded && trailer.path == video.path
        // 几何（网页版 measure / paint）：画幅先是一块 16:9（高不超过 74% 屏），放大到铺满；
        // 钉住的行程 = 一屏 + 面板压上来的那段 + 停一会儿；面板的顶边落在 contentTop
        let boxH = min(vw * 9 / 16, vh * 0.74)
        let boxW = boxH * 16 / 9
        let overlap = vh - (top + boxH)
        let hold = vh * 0.16
        let portalH = max(620, vh + overlap + hold)
        let pinMax = max(0, portalH - vh)
        let cover = max(vw / boxW, (vh - top) / boxH)
        let contentTop = portalH - overlap
        let H = vh, T = top
        let margin = DSMetrics(width: vw - lead - trail).margin
        let m = full ?? model.meta(video)

        // 章的高度 = 面板的顶边 + 面板本身（不再按画幅的行程定高：面板短的那一章底下不会空出一块黑）
        VStack(spacing: 0) {
            Color.clear.frame(height: contentTop)
            ShowcaseIntro(video: video, meta: m, vw: vw, lead: lead, trail: trail)
        }
        .frame(width: vw, alignment: .top)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                // ① 画幅：一块 16:9，按滚动放大 / 收回，钉在屏上
                ShowcaseMedia(video: video, art: atv?.background ?? model.backgroundArtString(video), trailer: trailer, isActive: isActive)
                    .frame(width: boxW, height: boxH)
                    .visualEffect { content, proxy in
                        let y = proxy.frame(in: .scrollView(axis: .vertical)).minY - T
                        let pin = min(max(-y, 0), pinMax)
                        let gap = contentTop - pin - T
                        let k = still ? cover : min(max(gap / boxH, 1), cover)
                        return content
                            .scaleEffect(k, anchor: .top)
                            .offset(y: pin)
                    }
                    .padding(.top, top)
                    .frame(width: vw, height: portalH, alignment: .top)
                    .clipped()

                // 均匀压暗：字在场时压住画面，字走了就还画面一个干净的满屏（F34）
                Color.black
                    .frame(width: vw, height: vh)
                    .visualEffect { content, proxy in
                        let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                        let pin = min(max(-y, 0), pinMax)
                        let cp = min(max((-y - H * 0.16) / (H * 0.36), 0), 1)
                        return content.opacity(0.42 * (1 - cp)).offset(y: pin)
                    }
                    .allowsHitTesting(false)

                // 一行信息 + 字标：居中，往上滚先淡出、略缩、上移（网页版的节奏）
                copy(m)
                    .frame(width: vw, height: vh)
                    .visualEffect { content, proxy in
                        let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                        let pin = min(max(-y, 0), pinMax)
                        let cp = min(max((-y - H * 0.16) / (H * 0.36), 0), 1)
                        return content
                            .scaleEffect(still ? 1 : 1 - 0.025 * cp)
                            .offset(y: pin - (still ? 0 : 26 * cp))
                            .opacity(1 - cp)
                    }
                    .allowsHitTesting(false)

                // 右上角：预告片的播放 / 暂停 + 进度环（拿到预告片才出现：F77 自动播放的预览要有看得见的停止钮）
                if controlOn {
                    ShowcaseControl(trailer: trailer)
                        .padding(.top, top + 12)
                        .padding(.trailing, max(8, margin - 5) + trail)
                        .frame(width: vw, alignment: .topTrailing)
                        .visualEffect { content, proxy in
                            let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                            let pin = min(max(-y, 0), pinMax)
                            let co = 1 - min(max((-y - H * 0.62) / (H * 0.28), 0), 1)
                            return content.opacity(co).offset(y: pin)
                        }
                        .transition(.opacity)
                }
            }
            .frame(width: vw, height: portalH, alignment: .top)
            .animation(DSMotion.fade, value: controlOn)
        }
        .clipped()
        .task(id: video.path) { atv = await model.atv(for: video) }
        .task(id: video.path) { full = await model.fullMeta(for: video) }
        .onGeometryChange(for: [Bool].self) { proxy in
            let f = proxy.frame(in: .scrollView(axis: .vertical))
            let center = f.minY <= H * 0.5 && f.maxY > H * 0.5
            let gone = f.minY + contentTop <= 1
            return [center, gone]
        } action: { v in
            report(v[0], v[1])
        }
    }

    /// 居中：一行「年份 · 类型 · 片长」（网页版 sc-eyebrow）在上，字标（没有字标就是片名，Large Title 粗体）在下
    @ViewBuilder private func copy(_ m: Meta?) -> some View {
        let safeW = vw - lead - trail
        let w = min(safeW * 0.84, 460)
        let line = eyebrow(m)
        VStack(spacing: 14) {
            if !line.isEmpty {
                Text(line)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    // 小字压在预告片上：再垫一层贴身的暗影，亮的画面上也读得清（F34、F72；设计轮 2（并行·library））
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
            }
            if let logo = atv?.logo ?? model.logoArtString(video), !logo.isEmpty {
                LogoImage(url: TMDBImage.url(logo, "w500"), height: safeW >= 600 ? 120 : 96, fallback: model.title(video), maxWidth: w * 0.8)
                    .frame(maxWidth: w * 0.8)
            } else {
                Text(model.title(video))
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: w)
        // 旁白：一章一个标题（片名 + 一行信息），转子里按「标题」一章一章跳（字标是图，以前念不出片名：F76）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([model.title(video), line].filter { !$0.isEmpty }.joined(separator: "，"))
        .accessibilityAddTraits(.isHeader)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 2)
        // 居中在安全区的正中（不是整个窗口的正中：不压到侧边那一列）
        .position(x: lead + safeW / 2, y: vh * 0.5)
    }

    /// 「2026 · 科幻 · 冒险 · 1 小时 56 分钟」
    private func eyebrow(_ m: Meta?) -> String {
        var parts: [String] = []
        if let y = model.year(video) { parts.append(String(y)) }
        if let g = m?.genres, !g.isEmpty { parts.append(g.prefix(2).joined(separator: " · ")) }
        // 不写片长（用户要求移除）
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
            // 放在 Color.clear 的 overlay 里：图按 fill 铺，比例不是正好 16:9 时也不会把这一层撑大、画到画幅外面去
            Color.clear.overlay {
                RemoteImage(url: TMDBImage.url(art, "w1280"), maxPixel: 1280, placeholder: .clear)
                    .scaleEffect(drift ? 1.12 : 1.02)
            }
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
            // 预告片还没起来时：画面极慢地推近、再拉远（26 秒一趟）；「减弱动态效果」打开时不推（F59）
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

/// 介绍面板（黑底，平口顶边压上来；网页版 sc-content）：评分、导演与主演、「播放」「影片详情」、一排剧照（简介只在详情页：用户要求），
/// 最底下一道两头渐隐的细线隔开下一章
struct ShowcaseIntro: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let meta: Meta?
    let vw: CGFloat
    var lead: CGFloat = 0
    var trail: CGFloat = 0

    var body: some View {
        let metrics = DSMetrics(width: vw - lead - trail)
        let resume = model.playback.resumePosition(video.path) != nil
        let stills = (meta?.stills ?? []).compactMap { s -> URL? in TMDBImage.url(s.url ?? s.thumb, "w780") }.prefix(10)
        VStack(alignment: .leading, spacing: 20) {
            // 简介不放（用户要求：简介只出现在详情页，「影片详情」进去看）
            VStack(alignment: .leading, spacing: 14) {
                if let r = meta?.rating, r > 0 {
                    // 介绍下面那枚小胶囊：只留评分（网页版 sc-facts）
                    Text("评分 " + String(format: "%.1f", r))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                let credits = self.credits
                if !credits.isEmpty {
                    Text(credits)
                        .font(.footnote)
                        .foregroundStyle(DSInk.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.leading, metrics.margin + lead).padding(.trailing, metrics.margin + trail)

            HStack(spacing: 12) {
                // F85：按钮是动词；看了一半的直接接着放（S17）
                Button { play() } label: {
                    Label(resume ? "继续播放" : "播放", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsPlay)
                .accessibilityIdentifier("showcase-play")

                NavigationLink(value: Route.movie(video)) {
                    Text("影片详情")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsSecondary)
                .accessibilityIdentifier("library-movie")
            }
            .frame(maxWidth: 460)
            .padding(.leading, metrics.margin + lead).padding(.trailing, metrics.margin + trail)

            if !stills.isEmpty {
                // 剧照：一排 16:9（网页版 sc-gallery），停在左边线上、右边露出下一张一截（S8）。
                // 这一排不是 DSShelf（上下没有那 4 点回弹的空）：标题到剧照用 blockTitleGap，看上去和别处标题到一排卡一样远
                VStack(alignment: .leading, spacing: metrics.blockTitleGap) {
                    Text("剧照")
                        .font(.dsSectionTitle)
                        .foregroundStyle(.white)
                        .padding(.leading, metrics.margin + lead).padding(.trailing, metrics.margin + trail)
                        // 剧照本身不念（只是画面、点不开）：标题后面补一句说明，不念一个后面什么都没有的「剧照」（F76）；
                        // 不再念「N 张」（用户要求全局去掉计数）
                        .accessibilityHint("剧照")
                        .accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: metrics.gutter) {
                            ForEach(Array(stills.enumerated()), id: \.offset) { _, url in
                                let w = metrics.wideCardWidth
                                // 圆角和别处同宽的 16:9 卡一样（DSRadius.card：折起 283 点宽是 16，以前写死 12）
                                DSFill.placeholder
                                    .overlay { RemoteImage(url: url, maxPixel: w * 3, placeholder: .clear) }
                                    .frame(width: w, height: (w * 9 / 16).rounded())
                                    .clipShape(RoundedRectangle(cornerRadius: DSRadius.card(w), style: .continuous))
                                    .accessibilityHidden(true)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    // 剧照一排铺满整个宽（连同侧边那一列），第一张停在安全区的左边线上
                    .contentMargins(.leading, metrics.margin + lead, for: .scrollContent)
                    .contentMargins(.trailing, metrics.margin + trail, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                }
                // 「剧照」是新的一组：钮到标题 20 → 28（标题到剧照 blockTitleGap），和「播放」那一行分得开（F3、F12）
                .padding(.top, 8)
            }

            // 章与章之间：一道两头渐隐的细线（网页版 sc-rule）
            LinearGradient(colors: [.clear, .white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .padding(.leading, metrics.margin + lead).padding(.trailing, metrics.margin + trail)
                .padding(.top, 12)
                .accessibilityHidden(true)
        }
        .padding(.top, 28)
        .padding(.bottom, metrics.shelfGap)
        .frame(width: vw, alignment: .leading)
        .background(Color.black)
    }

    /// 「导演 张三　　主演 甲、乙、丙」（网页版 sc-credits）
    private var credits: String {
        var parts: [String] = []
        if let d = meta?.director, !d.isEmpty { parts.append("导演 " + d) }
        let cast = (meta?.cast ?? []).prefix(3).map(\.name).filter { !$0.isEmpty }
        if !cast.isEmpty { parts.append("主演 " + cast.joined(separator: "、")) }
        return parts.joined(separator: "　　")
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
    /// App 退到后台：预告片停着（后台只让编辑推荐那一段接着下载：TrailerCache）
    private var background = false
    /// 放的是本机那份（TrailerCache 下好的）：一开始就清楚，一放就露；不占网，不挡后台下载
    @ObservationIgnored private var local = false
    /// 码流还没升到下限就先露了（等了几秒还低）：之后不再因为码流低淡回静态画面，免得一闪一闪
    @ObservationIgnored private var relaxed = false

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var start: Double = 10

    @ObservationIgnored private var playerObservers: [NSObjectProtocol] = []
    /// 预告片用掉的流量（账户页「流量概览」的「预告片」）：tick 里每 5 秒看一眼访问日志，卸下时结清
    private let usage = UsageTap(.trailer)
    /// 码流（HLS 的档位）的画面至少这么高才露出来：开头几秒自适应码率还在最低档，画面糊，先停在静态画面上
    @ObservationIgnored private let revealHeight: CGFloat
    /// 这一段开始出画面的时间（到了起点、真的在走）；放了很久还没升上去就不等了（降一档要求再露）
    @ObservationIgnored private var playingSince: Date?
    /// 露出来以后码流掉到下限以下的那一刻（网变差）：糊着超过两秒就退回清楚的静态画面
    @ObservationIgnored private var lowSince: Date?

    init(revealHeight: CGFloat = 720) {
        self.revealHeight = revealHeight
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .pause
        // 静音的背景画面不显示字幕：不照系统「字幕与隐藏式字幕」的设置自动选字幕，也就不去网上拉字幕（attach 里再明确关掉一次）
        player.appliesMediaSelectionCriteriaAutomatically = false
        let nc = NotificationCenter.default
        playerObservers = [
            nc.addObserver(forName: .cuvenPlayerPresented, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.playerUp = true; self?.sync() }
            },
            nc.addObserver(forName: .cuvenPlayerClosed, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.playerUp = false; self?.sync() }
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.background = true; self?.sync() }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.background = false; self?.sync() }
            },
        ]
    }

    /// userStarted：是人按了「播放预告」才挂上的（主页编辑推荐）：照样放，不看系统「自动播放视频预览」和省流量
    func mount(_ v: Video, model: AppModel, userStarted: Bool = false) {
        mount(key: v.path, userStarted: userStarted) { await model.trailers(for: v) }
    }

    /// 任意一部（电影、剧集）：key 认是哪一部（同一部再挂一次什么都不做），fetch 去拿它的预告片
    func mount(key: String, userStarted: Bool = false, fetch: @escaping () async -> [Trailer]) {
        guard path != key else { return }
        unmount()
        path = key
        // F77、S17：系统「自动播放视频预览」关着时不自己放，停在那儿等人点那颗播放钮；
        // 账户页「网络速度」调到 25% 以下（省流量）也一样。人明明白白按了播放就放
        paused = userStarted ? false : (!UIAccessibility.isVideoAutoplayEnabled || NetworkSpeed.dataSaver)
        loadTask = Task { [weak self] in
            let list = await fetch()
            guard let self, !Task.isCancelled, self.path == key,
                  let t = list.first, let url = URL(string: t.hls), url.scheme?.hasPrefix("http") == true else { return }
            // 本机有下好的（编辑推荐：TrailerCache）就放本机那份
            if let file = TrailerCache.shared.localURL(key: key, hls: t.hls) {
                self.attach(file, local: true)
            } else {
                self.attach(url, local: false)
            }
        }
    }

    /// 主页头图：只放 TrailerCache 下好的本机那份（不从网上放）。只在允许自动放的时候挂（HomeView / DSHeroCarousel 先看过系统设置）
    func mountLocal(key: String, file: URL) {
        guard path != key else { return }
        unmount()
        path = key
        attach(file, local: true)
    }

    /// 放到头了（主页头图用它翻到下一页）；不设就照旧回到起点接着放
    @ObservationIgnored var onEnd: (() -> Void)?

    func unmount() {
        TrailerFocus.shared.drop(self)
        TrailerCache.shared.trailer(self, streaming: false)
        loadTask?.cancel()
        loadTask = nil
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        statusObservation = nil
        player.pause()
        usage.flush(nil)
        player.replaceCurrentItem(with: nil)
        path = nil
        loaded = false
        showing = false
        playingSince = nil
        lowSince = nil
        local = false
        relaxed = false
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

    /// 想放（挂着片子、在屏上、没被暂停、正片没盖上来）：同一时刻只有最后一个想放的真的在放（TrailerFocus）
    private func sync() {
        let wants = player.currentItem != nil && visible && !covered && !paused && !playerUp && !background
        if wants { TrailerFocus.shared.want(self) } else { TrailerFocus.shared.drop(self) }
    }

    /// TrailerFocus 定了谁放：放 / 停
    fileprivate func apply(allowed: Bool) {
        guard player.currentItem != nil else { return }
        let wants = visible && !covered && !paused && !playerUp && !background
        if wants && allowed { player.play() } else { player.pause() }
        // 从网上放着的时候，编辑推荐的后台下载让一让（TrailerCache）；放本机那份不占网，不用让
        TrailerCache.shared.trailer(self, streaming: wants && allowed && !local)
    }

    private func attach(_ url: URL, local: Bool) {
        self.local = local
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
                    self.hideSubtitles(it)
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
                let ended = self.player.currentItem
                self.onEnd?()
                // onEnd 里可能已经换了一段（翻到下一页）：那就不再回到起点
                guard ended != nil, self.player.currentItem === ended else { return }
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
        usage.sample(item)
        let d = item.duration.seconds
        if d.isFinite, d > start { progress = min(1, max(0, (t.seconds - start) / (d - start))) }
        let on = player.timeControlStatus == .playing && t.seconds >= start - 0.5
        // 什么时候露（presentationSize 是当前档位的画面大小）：见下面「guard on」那一段
        let h = item.presentationSize.height
        let minH = revealHeight * 0.6
        if showing {
            // 本机那份、或者是等不及码流先露的：不再淡回去（用户要求：预告片在放，背景就不能还是剧照）
            if local || relaxed { return }
            // 露出来以后码流又掉到下限以下（网变差，用户截图里年份卡的画面糊成色块）：糊着超过两秒就淡回静态画面，等它再升上去
            if h > 0 && h < minH {
                if lowSince == nil { lowSince = Date() }
                if Date().timeIntervalSince(lowSince ?? Date()) > 2 {
                    showing = false
                    playingSince = nil
                    lowSince = nil
                }
            } else {
                lowSince = nil
            }
            return
        }
        guard on, h > 0 else { return }
        if playingSince == nil { playingSince = Date() }
        let waited = Date().timeIntervalSince(playingSince ?? Date())
        // 用户截图：预告片已经在放（右上角是暂停钮），背景却一直是剧照——以前要等码流升到 1080（或 10 秒后 648）才露，
        // 网慢的时候一直等不到。现在：本机那份一放就露；从网上放的，码流够清楚马上露，放了 2 秒到了六成也露，
        // 放了 4 秒不管多少都露（这时不再因为码流低退回剧照）
        if local || h >= revealHeight || (waited > 2 && h >= minH) || waited > 4 {
            showing = true
            relaxed = !local && h < minH
            lowSince = nil
        }
    }

    /// 关掉字幕：静音的背景画面上不压字，也不去拉字幕的播放列表
    private func hideSubtitles(_ item: AVPlayerItem) {
        Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            guard let self, self.player.currentItem === item else { return }
            item.select(nil, in: group)
        }
    }
}

/// 同一时刻只放一段预告片（主页的年份那两排、编辑推荐，资料库）：最后一个想放的放，别的停在当前那一帧；
/// 放着的那段滑走 / 换页 / 卸下了，再让还想放的那段里最近的一个接着放
@MainActor
final class TrailerFocus {
    static let shared = TrailerFocus()

    private final class Box {
        weak var value: ShowcaseTrailer?
        init(_ v: ShowcaseTrailer) { value = v }
    }

    /// 想放的，最近的在最后
    private var queue: [Box] = []

    func want(_ t: ShowcaseTrailer) {
        queue.removeAll { $0.value == nil || $0.value === t }
        queue.append(Box(t))
        refresh()
    }

    func drop(_ t: ShowcaseTrailer) {
        queue.removeAll { $0.value == nil || $0.value === t }
        t.apply(allowed: false)
        refresh()
    }

    private func refresh() {
        let top = queue.last?.value
        for b in queue { b.value?.apply(allowed: b.value === top) }
    }
}
