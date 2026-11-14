import SwiftUI

// MARK: - 主页（按 Apple HIG 重做；规则编号见 docs/ios-design.md 与 docs/hig/*.md）
//
// 和 Apple TV 的主页一样只有两样东西：最上面一张全屏轮播头图（S15–S17），下面一排排货架（T23、S8）。
// 货架之间只靠留白分开，不画胶囊、年份条、描边、底板和分隔线（F3、F12、F38）；不放口号、印章、描边大数字（F80）。
// 折起的外屏、展开的竖拿 / 横拿是同一套部件，只按可用宽度长大：头图更大、每排更多卡、留白更从容（S1、D2、F9）。

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = Perf.count("home")
        ZoomStack {
            GeometryReader { geo in
                // 尺寸只看可用的宽高，不看机型和方向（F9、D4）；边距、卡宽、排间距都从宽度算（S3、S5、S6）
                let m = DSMetrics(width: geo.size.width)
                ScrollView {
                    // 分区之间只有一种间距（F12、T24）
                    LazyVStack(alignment: .leading, spacing: m.shelfGap) {
                        hero(metrics: m, size: geo.size, insets: geo.safeAreaInsets)
                        shelves(metrics: m)
                    }
                    .padding(.bottom, m.shelfGap)
                }
                .scrollIndicators(.hidden)
                .background(Theme.bg)
                // 头图从屏幕最上沿铺起，状态栏和灵动岛浮在画面上（F6）。
                // 状态栏下面不再盖一条自绘的渐暗：滚动边缘只用系统的（C27）
                .ignoresSafeArea(edges: .top)
                .refreshable { await model.refreshAll() }
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: 头图

    /// 头图（S15）：可用区域是竖的（外屏、竖拿）就约 70% 屏高、用竖版全屏图；是横的就全宽 16:9、用横版背景
    @ViewBuilder
    private func hero(metrics m: DSMetrics, size: CGSize, insets: EdgeInsets) -> some View {
        let screen = size.height + insets.top + insets.bottom
        let tall = size.height > size.width
        // 竖：65–75% 屏高（S15），并且至少比宽多 1 点——轮播按「高 > 宽」取竖版图，展开竖拿（669 宽）时 70% 只有 666；
        // 横：全宽 16:9，但不超过屏高的八成（手机横拿时 16:9 会比整屏还高）
        let height = (tall ? min(max(screen * 0.7, size.width + 1), screen * 0.78)
                           : min(size.width * 9 / 16, screen * 0.8)).rounded()
        let pages = heroPages
        if !pages.isEmpty {
            DSHeroCarousel(pages: pages, metrics: m, height: height)
                // 静止时状态栏的字也要看得清（F34）：在内容层里把画面顶上压暗一点，跟着头图一起滚走
                // （是画面的一部分，不是 C27 说的那种盖在滚动视图上的自绘边缘效果）
                .overlay(alignment: .top) {
                    if insets.top > 0 {
                        LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: insets.top + 40)
                            .allowsHitTesting(false)
                    }
                }
                // iPhone Duo 的系统栏竖在侧边那一列时（D6：外屏在后缘），画面在那一列底下延伸（F6、S19、D9）
                .backgroundExtensionEffect()
        } else if model.movies.isEmpty && !loadFailed {
            // 还在载入：先占住头图的位置，不留白屏（C66）
            LinearGradient(colors: [Color(white: 0.1), Theme.bg], startPoint: .top, endPoint: .bottom)
                .frame(height: height)
                .accessibilityHidden(true)
        } else {
            // 没有头图：下面的内容从状态栏以下开始
            Color.clear.frame(height: insets.top)
        }
    }

    /// 头图的每一页（T30–T32）：画面、字标、一行信息、播放 / 详情。看了一半的直接「继续播放」，不再问（S17、F85）
    private var heroPages: [DSHeroPage] {
        heroItems.map { it in
            let v = it.video
            let meta = model.meta(v)
            // 头图源本来就是 Apple TV 的素材；缺哪样先补全片库的 Apple TV 素材，再退 TMDB
            let logo = (it.hero.logo?.isEmpty == false ? it.hero.logo : nil) ?? model.logoArtString(v)
            return DSHeroPage(id: it.id,
                              wideArt: it.hero.background ?? model.backgroundArtString(v),
                              tallArt: it.hero.poster ?? model.appleArt(v)?.tall ?? meta?.posterClean ?? meta?.poster,
                              logo: logo,
                              title: model.title(v),
                              meta: heroMeta(it),
                              playTitle: model.playback.resumePosition(v.path) != nil ? "继续播放" : "播放",
                              play: { playHero(it) },
                              detail: .movie(v))
        }
    }

    private var heroItems: [HeroItem] {
        var out: [HeroItem] = []
        var seen = Set<String>()
        for h in model.heroes {
            guard let v = model.video(path: h.path), seen.insert(v.path).inserted else { continue }
            out.append(HeroItem(hero: h, video: v))
        }
        if out.isEmpty {
            // 大图源取不到：退回最新加入、带横版剧照的几部
            for v in model.newest.prefix(6) {
                let m = model.meta(v)
                let apple = model.appleArt(v)
                guard let bd = apple?.background ?? m?.backdrop else { continue }
                out.append(HeroItem(hero: Hero.fallback(path: v.path, backdrop: bd, poster: apple?.tall ?? m?.posterClean ?? m?.poster), video: v))
            }
        }
        return out
    }

    /// 「电影 · 2026 · 科幻」：一行、短、平实（F84、S15）
    private func heroMeta(_ it: HeroItem) -> String {
        let kind = (it.hero.type ?? "Movie").lowercased().hasPrefix("show") ? "剧集" : "电影"
        let year = (it.hero.year ?? model.year(it.video)).map { String($0) }
        let genre = model.meta(it.video)?.genres?.first
        return [kind, year, genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func playHero(_ it: HeroItem) {
        let v = it.video
        PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(v),
                                                  subtitle: model.year(v).map { String($0) },
                                                  artwork: it.hero.background ?? model.backgroundArtString(v)), model: model)
    }

    private var loadFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    // MARK: 货架

    /// 顺序：继续观看 → 今日推荐 → 最新加入 → 剧集 → 各年份 → 文件夹（docs/ios-design.md「主页」；F1：最要紧的在上）
    @ViewBuilder
    private func shelves(metrics m: DSMetrics) -> some View {
        if model.movies.isEmpty {
            switch model.phase {
            case .failed(let msg):
                // 连不上：说清楚哪里不对、该怎么办（F87）；按钮是动词（F85）。内容里的按钮不用玻璃（F38）
                ContentUnavailableView {
                    Label("连不上服务器", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(msg)
                } actions: {
                    Button("重试") { Task { await model.refreshAll() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            default:
                // 载入中：先出和真货架同样大小的占位（C66）
                SkeletonRow(metrics: m)
                SkeletonRow(metrics: m)
            }
        } else {
            continueWatching(m)
            todayPicks(m)
            newest(m)
            seriesShelf(m)
            yearShelves(m)
            folderShelf(m)
        }
    }

    /// 继续观看（T20、T22）：16:9 卡带进度（F36：进度用形状表达）；卡下一行「还剩 …」。点一下直接接着放（S17、C89）。
    /// 只剩一张时不再垫「没有更多了」的占位卡（F3、F80）
    @ViewBuilder
    private func continueWatching(_ m: DSMetrics) -> some View {
        let entries = model.playback.continueWatching
        if !entries.isEmpty {
            DSSection(title: "继续观看", metrics: m) {
                DSShelf(metrics: m) {
                    ForEach(entries) { e in
                        Button { resume(e) } label: {
                            DSWideLockup(art: continueArt(e), title: e.title,
                                         subtitle: remainingLabel(e), progress: e.fraction, metrics: m)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("continue-card")
                    }
                }
            }
        }
    }

    /// 今日推荐：竖版海报（T20：海报自带片名，卡下的字只在焦点那张浮现）；名次写进卡下的字「第 1 名 · 科幻」，
    /// 不再画描边大数字和「品质保证」章（F3、F80）。标题「›」进整张排行（F4、T25）
    @ViewBuilder
    private func todayPicks(_ m: DSMetrics) -> some View {
        let list = model.todayPicks
        if !list.isEmpty {
            DSSection(title: "今日推荐", metrics: m, route: .shelf(.picks)) {
                DSShelf(metrics: m) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, v in
                        let art = model.posterArt(v, width: m.posterWidth)
                        ZoomLink(route: .movie(v), slot: "picks") {
                            DSPosterLockup(art: art.url, title: model.title(v), subtitle: rankLabel(i + 1, v), metrics: m,
                                           logo: art.logo)
                        }
                        // 长按：播放 / 想看（C21、C43、S23）
                        .movieMenu(v)
                    }
                }
            }
        }
    }

    /// 最新加入：16:9（T22）；上次打开以后才入库的，画面左上角一枚强调色的「新」（F32：强调色只给状态；F36：有字，不只靠颜色）。
    /// 卡下一行是入库时间（F84）
    @ViewBuilder
    private func newest(_ m: DSMetrics) -> some View {
        let list = model.newest
        if !list.isEmpty {
            DSSection(title: "最新加入", metrics: m, route: .shelf(.newest)) {
                DSShelf(metrics: m) {
                    ForEach(list) { v in
                        ZoomLink(route: .movie(v), slot: "newest") {
                            DSWideLockup(art: model.wideArt(v),
                                         title: model.title(v), subtitle: addedLabel(v),
                                         progress: model.playback.entry(v.path)?.fraction, metrics: m)
                                .overlay {
                                    if model.freshPaths.contains(v.path) { FreshMark(metrics: m) }
                                }
                        }
                        .accessibilityIdentifier("newest-poster")
                        .movieMenu(v)
                    }
                }
            }
        }
    }

    /// 剧集：16:9 的横版背景，左下角压官方字标（T20、S12）；卡下一行季与集数。
    /// 取代原来那排竖着的高卡（F3：同一种卡、同一种排法）
    @ViewBuilder
    private func seriesShelf(_ m: DSMetrics) -> some View {
        let list = Array(model.homeSeries.prefix(12))
        if !list.isEmpty {
            DSSection(title: "剧集", metrics: m, route: .shelf(.series)) {
                DSShelf(metrics: m) {
                    ForEach(list) { s in
                        let meta = model.seriesMetas[s.path]
                        let name = meta?.title ?? s.name
                        let info = [s.seasonLabel, s.countLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        ZoomLink(route: .series(s), slot: "series") {
                            DSWideLockup(art: TMDBImage.url(meta?.backdrop ?? meta?.posterClean ?? meta?.poster, "w780"),
                                         title: name, subtitle: info, metrics: m)
                                .overlay { SeriesLogoMark(logo: meta?.logo, title: name, metrics: m) }
                        }
                        .accessibilityIdentifier("series-card")
                        .seriesMenu(s)
                        .task { await model.ensureSeriesMeta(s) }
                    }
                }
            }
        }
    }

    /// 各年份：标题「2026 ›」整行进年份页（F86、T25：不再是玻璃年份条），下面一排竖版海报（T20）
    @ViewBuilder
    private func yearShelves(_ m: DSMetrics) -> some View {
        ForEach(model.yearGroups, id: \.year) { g in
            DSSection(title: String(g.year), metrics: m, route: .year(g.year)) {
                DSShelf(metrics: m) {
                    ForEach(g.videos.prefix(15)) { v in
                        let art = model.posterArt(v, width: m.posterWidth)
                        ZoomLink(route: .movie(v), slot: "year-\(g.year)") {
                            DSPosterLockup(art: art.url, title: model.title(v), subtitle: genreLabel(v), metrics: m,
                                           logo: art.logo)
                        }
                        .movieMenu(v)
                    }
                }
            }
        }
    }

    /// 文件夹（有才出）：和海报同宽、同一种焦点（S6、S9）
    @ViewBuilder
    private func folderShelf(_ m: DSMetrics) -> some View {
        if !model.folders.isEmpty {
            DSSection(title: "文件夹", metrics: m) {
                DSShelf(metrics: m) {
                    ForEach(model.folders) { f in
                        ZoomLink(route: .folder(f), slot: "home-folder") {
                            FolderCard(folder: f, width: m.posterWidth)
                                .modifier(DSFocusEffect(metrics: m, cardWidth: m.posterWidth, poster: true))
                        }
                        .accessibilityIdentifier("folder-card")
                    }
                }
            }
        }
    }

    // MARK: 卡下的字（F84：短、平实）

    /// 继续观看的画面：电影按片库里的那一部取（Apple TV 优先、TMDB 兜底：AppModel.wideArt）；
    /// 剧集用存进度时记下的那一集剧照
    private func continueArt(_ e: WatchEntry) -> URL? {
        if e.seriesPath == nil, let v = model.video(path: e.path) { return model.wideArt(v) }
        return TMDBImage.url(e.artwork, "w780")
    }

    /// 「第 1 名 · 科幻」：名次进卡下的字，不再画描边大数字（F3、F80）
    private func rankLabel(_ rank: Int, _ v: Video) -> String {
        guard let g = model.meta(v)?.genres?.first, !g.isEmpty else { return "第 \(rank) 名" }
        return "第 \(rank) 名 · \(g)"
    }

    /// 「科幻 · 冒险」；没有类型时退回年份
    private func genreLabel(_ v: Video) -> String? {
        if let g = model.meta(v)?.genres?.prefix(2).joined(separator: " · "), !g.isEmpty { return g }
        return model.year(v).map { String($0) }
    }

    /// 「今天」「昨天」「3 天前」「2 周前」（按入库时间）
    private func addedLabel(_ v: Video) -> String? {
        guard let d = Relative.date(v.added) else { return genreLabel(v) }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0
        switch days {
        case ..<1: return "今天"
        case 1: return "昨天"
        case 2..<7: return "\(days) 天前"
        case 7..<30: return "\(days / 7) 周前"
        case 30..<365: return "\(days / 30) 个月前"
        default: return "\(days / 365) 年前"
        }
    }

    /// 「第 3 集 · 还剩 22 分钟」/「还剩 1 小时 20 分钟」
    private func remainingLabel(_ e: WatchEntry) -> String {
        let seconds = e.remaining.isFinite ? e.remaining : 0
        let left = "还剩 " + Format.runtime(max(1, Int((seconds / 60).rounded(.up))))
        if e.seriesPath != nil, let s = e.subtitle, !s.isEmpty { return s + " · " + left }
        return left
    }

    private func resume(_ e: WatchEntry) {
        if let sp = e.seriesPath, model.series.contains(where: { $0.path == sp }) {
            // 剧集：接着放这一集，后面的几集排进队列
            Task {
                let files = (try? await APIClient.shared.episodes(seriesPath: sp)) ?? []
                let sorted = files.sorted { ($0.ep ?? 0) < ($1.ep ?? 0) }
                let idx = sorted.firstIndex { $0.path == e.path }
                let queue = idx.map { Array(sorted[($0 + 1)...]) } ?? []
                let title = e.title
                PlayerCoordinator.shared.play(PlayRequest(path: e.path, name: e.name, title: title, subtitle: e.subtitle, artwork: e.artwork,
                                                          seriesPath: sp, episode: e.episode,
                                                          queue: queue.map { f in
                                                              PlayRequest(path: f.path, name: f.name, title: title,
                                                                          subtitle: f.ep.map { "第 \($0) 集" }, artwork: e.artwork,
                                                                          seriesPath: sp, episode: f.ep)
                                                          }), model: model)
            }
        } else {
            PlayerCoordinator.shared.play(PlayRequest(path: e.path, name: e.name, title: e.title, subtitle: e.subtitle, artwork: e.artwork), model: model)
        }
    }
}

struct HeroItem: Identifiable {
    let hero: Hero
    let video: Video
    var id: String { hero.id }
}

extension Hero {
    static func fallback(path: String, backdrop: String, poster: String?) -> Hero {
        Hero(path: path, background: backdrop, poster: poster ?? backdrop)
    }
}

// MARK: - 压在 16:9 卡上的东西
//
// DSWideLockup 的焦点放大是在卡里面做的（S9）。压在卡上的角标 / 字标放在一层和卡一样大的透明层上，
// 用同一个 DSFocusEffect：两者按同一个位置算、以同一个中心放大，所以跟着卡一起走，不会滑开

/// 「新」：画面左上角（F32）
private struct FreshMark: View {
    let metrics: DSMetrics

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) { FreshBadge().padding(10) }
            .modifier(DSFocusEffect(metrics: metrics, cardWidth: metrics.wideCardWidth, poster: false))
            .allowsHitTesting(false)
    }
}

/// 剧集的官方字标：画面左下角，下面垫一层渐暗保证对比度（C58、S24）；深色字标由 LogoImage 自动反白
private struct SeriesLogoMark: View {
    let logo: String?
    let title: String
    let metrics: DSMetrics

    var body: some View {
        let w = metrics.wideCardWidth
        let h = (w * 9 / 16).rounded()
        Color.clear
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.6), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    LogoImage(url: TMDBImage.url(logo, "w500"), height: (h * 0.26).rounded(), alignment: .leading,
                              fallback: title, maxWidth: (w * 0.55).rounded())
                        .padding(12)
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .modifier(DSFocusEffect(metrics: metrics, cardWidth: w, poster: false))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - 导航目标

struct RouteView: View {
    let route: Route
    var body: some View {
        switch route {
        case .folder(let f): FolderView(folder: f)
        case .movie(let v): MovieDetailView(video: v)
        case .series(let s): SeriesDetailView(series: s)
        case .year(let y): YearView(year: y)
        case .shelf(let s): ShelfView(shelf: s)
        }
    }
}
