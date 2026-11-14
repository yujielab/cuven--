import SwiftUI
import AVFoundation

// MARK: - 资料库：和网页版的「展映」（lib-showcase）同一套逻辑，一部电影一章
//
// · 顺序：上映新的在前，同一天按入库时间（AppModel.showcaseOrder，和网页版 sortOrder 一样）；全片库查过一轮以后首尾相接、一直往下放（网页版的环形队列）。
// · 只放有预告片的电影：预告片就是详情页拿到的那一份（Apple TV 上的公开预告，AppModel.trailers(for:)）；
//   哪部有、哪部没有在后台查（AppModel.scanTrailers），查到的记在本地；还没查到的那一部后面先不放，查到了再往后接。
// · 每一章：
//   ① 画幅：一块 16:9 先放大到铺满整屏，钉住不动；中间是一行「年份 · 类型 · 片长」和字标（没有字标就是片名），往上滚先淡出、压暗层跟着退；
//      再往上滚，画幅收回成一整幅 16:9，下沿始终咬着介绍面板的上沿（网页版同一套几何：k = 间隙 / 16:9 的高，跟着手指走：F54、S10）。
//      在屏幕中间那一章放它的预告片：静音、从第 10 秒起、循环；系统关了「自动播放视频预览」就停着等人点（F77、S17），右上角播放 / 暂停 + 进度环。
//   ② 介绍面板（黑底，平口顶边压上来）：简介、评分、导演与主演、「播放」「影片详情」、一排剧照，章与章之间一道两头渐隐的细线（网页版的内容）。
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
                let vw = geo.size.width
                let top = geo.safeAreaInsets.top
                let margin = DSMetrics(width: vw).margin
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if feed.isEmpty {
                            emptyState
                                .frame(height: vh)
                                .overlay(alignment: .top) { ShowcaseHeader(top: top, margin: margin).allowsHitTesting(false) }
                        }
                        ForEach(feed) { e in
                            ShowcaseChapter(video: e.video, vw: vw, vh: vh, top: top, trailer: trailer,
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
                .ignoresSafeArea(edges: .top)
                .background(Color.black)
                .refreshable {
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
        // 打开资料库时把没查过的接着查（单独起一个任务：切走标签不打断它，正在查就什么也不做）
        .onAppear { Task { await model.scanTrailers() } }
    }

    /// 有预告片的电影：按资料库的顺序；这一屏上已经排好的保持原位，新查到的接在后面
    private var base: [Video] {
        let live = model.showcaseMovies
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
                Label("没能载入资料库", systemImage: "wifi.exclamationmark")
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
                Label("没能查到预告片", systemImage: "wifi.exclamationmark")
            } description: {
                Text("资料库只放有预告片的电影。网络恢复后再试一次。")
            } actions: {
                Button("重试") { Task { await model.scanTrailers() } }
            }
        } else {
            ContentUnavailableView {
                Label("还没有带预告片的电影", systemImage: "film.stack")
            } description: {
                Text("资料库只放有预告片的电影。片库里有了这样的电影，会一部一章地出现在这里。")
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
            Text("资料库")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("Cuven 为你提供严格品质的影片")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
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
    let trailer: ShowcaseTrailer
    let isActive: Bool
    /// (这一章跨着屏幕中线, 画幅已经整个滚出屏幕)
    let report: (Bool, Bool) -> Void
    /// Apple TV 上对上的那一部：画幅用它的无字 16:9 背景、标题用它的字标（预告片也是这一次问来的）
    @State private var atv: AtvLookup?
    /// 全量的 TMDB（导演、主演、剧照）
    @State private var full: Meta?

    var body: some View {
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
        let margin = DSMetrics(width: vw).margin
        let m = full ?? model.meta(video)

        // 章的高度 = 面板的顶边 + 面板本身（不再按画幅的行程定高：面板短的那一章底下不会空出一块黑）
        VStack(spacing: 0) {
            Color.clear.frame(height: contentTop)
            ShowcaseIntro(video: video, meta: m, vw: vw)
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
                        let k = min(max(gap / boxH, 1), cover)
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
                            .scaleEffect(1 - 0.025 * cp)
                            .offset(y: pin - 26 * cp)
                            .opacity(1 - cp)
                    }
                    .allowsHitTesting(false)

                // 右上角：预告片的播放 / 暂停 + 进度环（拿到预告片才出现：F77 自动播放的预览要有看得见的停止钮）
                if isActive && trailer.loaded && trailer.path == video.path {
                    ShowcaseControl(trailer: trailer)
                        .padding(.top, top + 12)
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
            }
            .frame(width: vw, height: portalH, alignment: .top)
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
        let w = min(vw * 0.84, 460)
        VStack(spacing: 14) {
            let line = eyebrow(m)
            if !line.isEmpty {
                Text(line)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
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
        }
        .frame(width: w)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 2)
        .position(x: vw / 2, y: vh * 0.5)
    }

    /// 「2026 · 科幻 · 冒险 · 116 分钟」
    private func eyebrow(_ m: Meta?) -> String {
        var parts: [String] = []
        if let y = model.year(video) { parts.append(String(y)) }
        if let g = m?.genres, !g.isEmpty { parts.append(g.prefix(2).joined(separator: " · ")) }
        if let r = m?.runtime, r > 0 { parts.append("\(r) 分钟") }
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

/// 介绍面板（黑底，平口顶边压上来；网页版 sc-content）：简介、评分、导演与主演、「播放」「影片详情」、一排剧照，
/// 最底下一道两头渐隐的细线隔开下一章
struct ShowcaseIntro: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let meta: Meta?
    let vw: CGFloat

    var body: some View {
        let metrics = DSMetrics(width: vw)
        let resume = model.playback.resumePosition(video.path) != nil
        let stills = (meta?.stills ?? []).compactMap { s -> URL? in TMDBImage.url(s.url ?? s.thumb, "w780") }.prefix(10)
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text((meta?.overview).flatMap { $0.isEmpty ? nil : $0 } ?? "这部影片暂时没有简介。")
                    .font(.body.leading(.loose))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: 620, alignment: .leading)
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
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, metrics.margin)

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
            .padding(.horizontal, metrics.margin)

            if !stills.isEmpty {
                // 剧照：一排 16:9（网页版 sc-gallery），停在左边线上、右边露出下一张一截（S8）
                VStack(alignment: .leading, spacing: metrics.titleGap) {
                    Text("剧照")
                        .font(.dsShelfTitle(wide: metrics.wide))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, metrics.margin)
                        .accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: metrics.gutter) {
                            ForEach(Array(stills.enumerated()), id: \.offset) { _, url in
                                let w = metrics.wideCardWidth
                                Color(white: 0.11)
                                    .overlay { RemoteImage(url: url, maxPixel: w * 3, placeholder: .clear) }
                                    .frame(width: w, height: (w * 9 / 16).rounded())
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityHidden(true)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, metrics.margin, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                }
            }

            // 章与章之间：一道两头渐隐的细线（网页版 sc-rule）
            LinearGradient(colors: [.clear, .white.opacity(0.14), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
                .padding(.horizontal, metrics.margin)
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
