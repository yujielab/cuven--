import SwiftUI

// MARK: - 主页（按 Apple HIG 重做；规则编号见 docs/ios-design.md 与 docs/hig/*.md）
//
// 和 Apple TV 的主页一样只有两样东西：最上面一张铺满的轮播头图（S15–S17），下面一排排海报（T23、S8）。
// 头图几乎占满一屏，连同 iPhone Duo 侧边那一列一起平铺（画面在系统栏底下过去，不做镜像模糊：F6、S19），
// 左上一行白色大字「Home」、右上一枚头像（点开账户与设置），页码点浮在画面底部。
// 下面的顺序：继续观看（有才有）→ 今年 → 去年（电影和剧集一起，最新入库的在前）→ 精选电影 → 精选剧集 → 五个大类（引人入胜的剧情、令人坐立难安、
// 科幻和奇幻之旅、动作演员就位、刺激犯罪与偷窃）。卡上只有画面：无字主视觉 + 官方字标，或本来就印着片名的海报，卡下不写字（T20、F80）。
// 分区之间只靠留白（F3、F12、F38）。折起的外屏、展开的竖拿 / 横拿是同一套部件，只按可用宽度长大（S1、D2、F9）。

struct HomeView: View {
    @Environment(AppModel.self) private var model
    /// 右上头像点开的账户与设置（用户要求：头像从侧边导航里拿出来，放在主页标题这一行的右边）
    @State private var showAccount = false

    var body: some View {
        let _ = Perf.count("home")
        ZoomStack {
            GeometryReader { geo in
                let insets = geo.safeAreaInsets
                // 内容区的宽（不算侧边那一列）：边距、卡宽、排间距都从它算（F9、D4、S3、S5、S6）；
                // 安全区也带上：横着的一排一直铺到侧边那一列底下
                let m = DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing)
                let fullWidth = geo.size.width + insets.leading + insets.trailing
                let fullHeight = geo.size.height + insets.top + insets.bottom
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        hero(m, fullWidth: fullWidth, fullHeight: fullHeight, insets: insets)
                        shelves(m)
                            .padding(.top, m.wide ? 36 : 28)
                            // 货架留在安全区里（卡往右滑出去时从侧边那一列底下过去）
                            .padding(.leading, insets.leading)
                            .padding(.trailing, insets.trailing)
                    }
                    .padding(.bottom, m.shelfGap)
                }
                .scrollIndicators(.hidden)
                .background(Theme.bg)
                // 头图从屏幕最上沿、连同侧边那一列一起铺满（F6、S19）
                .ignoresSafeArea(edges: [.top, .horizontal])
                .refreshable { await model.refreshAll() }
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showAccount) { AccountView() }
    }

    // MARK: 头图

    /// 头图（S15）：竖着的屏约 86% 屏高、用竖版全屏图（下面露出下一排的标题，告诉人还能往下滑：S8）；
    /// 横着的屏 94% 屏高、用横版背景。宽度是整个窗口（含侧边那一列），字留在安全区里
    @ViewBuilder
    private func hero(_ m: DSMetrics, fullWidth: CGFloat, fullHeight: CGFloat, insets: EdgeInsets) -> some View {
        let tall = fullHeight > fullWidth
        let height = (fullHeight * (tall ? 0.86 : 0.94)).rounded()
        let pages = heroPages
        ZStack(alignment: .topLeading) {
            if !pages.isEmpty {
                DSHeroCarousel(pages: pages, metrics: m, height: height, fullWidth: fullWidth,
                               leadingInset: insets.leading, trailingInset: insets.trailing)
            } else if (model.movies.isEmpty || !model.heroResolved) && !loadFailed {
                // 还在载入 / 还在挑头图：先占住头图的位置，不留白屏（C66），也不先放一张不合格的
                LinearGradient(colors: [Color(white: 0.12), Theme.bg], startPoint: .top, endPoint: .bottom)
                    .frame(width: fullWidth, height: height)
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: fullWidth, height: max(insets.top, 12) + 64)
            }
            // 最上面一行：左边白字「Home」（Apple TV 主页那样的大标题，压在画面上、跟着头图一起滚走：C13、F34），
            // 右边一枚头像（玻璃圈里的圆头像），点开是账户与设置——头像不再放在侧边导航里（用户要求）
            HStack(alignment: .center, spacing: 12) {
                Text("Home")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                accountButton
            }
            .padding(.top, max(insets.top, 12) + 8)
            .padding(.leading, insets.leading + m.margin)
            .padding(.trailing, insets.trailing + m.margin)
            .frame(width: fullWidth)
        }
        .frame(width: fullWidth, alignment: .topLeading)
    }

    /// 头像：38 点的圆头像套在一圈 Liquid Glass 里（共 46 点，点得到的范围够大：F74）
    private var accountButton: some View {
        Button { showAccount = true } label: {
            AvatarView(size: 38)
                .padding(4)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("账户与设置")
        .accessibilityIdentifier("home-account")
    }

    /// 头图的每一页（T30–T32）：只放拿到了无字背景 + 字标的，最多 5 部（AppModel.resolveHeroes 挑）。
    /// 横着的屏用无字的横图，竖着的屏用竖版无字图（没有就把横图居中裁）。看了一半的直接「继续播放」，不再问（S17、F85）
    private var heroPages: [DSHeroPage] {
        model.heroPicks.map { p in
            let v = p.video
            return DSHeroPage(id: p.id,
                              wideArt: p.wide,
                              tallArt: p.tall ?? p.wide,
                              logo: p.logo,
                              title: model.title(v),
                              meta: heroMeta(p),
                              playTitle: model.playback.resumePosition(v.path) != nil ? "继续播放" : "播放",
                              play: { playHero(p) },
                              detail: .movie(v))
        }
    }

    /// 「电影 · 2026 · 科幻」：一行、短、平实（F84、S15）
    private func heroMeta(_ p: HeroPick) -> String {
        let kind = (p.hero?.type ?? "Movie").lowercased().hasPrefix("show") ? "剧集" : "电影"
        let year = (p.hero?.year ?? model.year(p.video)).map { String($0) }
        let genre = model.meta(p.video)?.genres?.first
        return [kind, year, genre].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func playHero(_ p: HeroPick) {
        let v = p.video
        PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(v),
                                                  subtitle: model.year(v).map { String($0) },
                                                  artwork: p.wide), model: model)
    }

    private var loadFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    // MARK: 货架

    /// 今年和去年（「2026」「2025」）
    private var homeYears: [Int] {
        let y = Calendar.current.component(.year, from: Date())
        return [y, y - 1]
    }

    /// 顺序：继续观看 → 今年 → 去年 → 精选电影 → 五个大类（docs/ios-design.md「主页」；F1：最要紧的在上）
    @ViewBuilder
    private func shelves(_ m: DSMetrics) -> some View {
        if model.movies.isEmpty {
            switch model.phase {
            case .failed(let msg):
                // 连不上：说清楚哪里不对、该怎么办（F87）；按钮是动词（F85）
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
                VStack(alignment: .leading, spacing: m.shelfGap) {
                    SkeletonRow(metrics: m)
                    SkeletonRow(metrics: m)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: m.shelfGap) {
                continueWatching(m)
                ForEach(homeYears, id: \.self) { y in yearShelf(y, m) }
                featuredShelf(m)
                featuredSeriesShelf(m)
                ForEach(HomeCategory.allCases) { c in categoryShelf(c, m) }
            }
        }
    }

    /// 继续观看（T22）：16:9 画面 + 字标 + 进度条（F36）；点一下直接接着放（S17、C89）
    @ViewBuilder
    private func continueWatching(_ m: DSMetrics) -> some View {
        let entries = model.playback.continueWatching
        if !entries.isEmpty {
            DSSection(title: "继续观看", metrics: m) {
                DSShelf(metrics: m) {
                    ForEach(entries) { e in
                        let art = continueArt(e)
                        Button { resume(e) } label: {
                            DSWideLockup(art: art.url, title: e.title, subtitle: remainingLabel(e),
                                         progress: e.fraction, metrics: m, logo: art.logo)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("continue-card")
                    }
                }
            }
        }
    }

    /// 某一年（今年 / 去年）：电影和剧集一起，最新入库的在前；标题「2026 ›」进年份页（F86、T25）
    @ViewBuilder
    private func yearShelf(_ y: Int, _ m: DSMetrics) -> some View {
        let items = model.homeYear(y, limit: 24)
        if !items.isEmpty {
            DSSection(title: String(y), metrics: m, route: .year(y)) {
                DSShelf(metrics: m) {
                    ForEach(items) { e in posterCard(e, m, slot: "year-\(y)") }
                }
            }
        }
    }

    /// 精选电影：评分高的在前；照用户给的参考图（游戏 App 的合集页）做成一整块：立体海报封面 + 大标题 + 说明 + 一排带底栏的大卡；
    /// 那排的标题点进全部（按评分的海报网格）
    @ViewBuilder
    private func featuredShelf(_ m: DSMetrics) -> some View {
        let items = model.featuredMovies(limit: 10)
        if !items.isEmpty {
            // 照参考图（游戏 App 的合集页）：立体海报封面 + 大标题 + 一段说明，下面一排带底栏的大卡
            FeaturedCollection(title: Shelf.featured.title, blurb: "Cuven 按评分为你挑出片库里最值得一看的电影。",
                               rowTitle: "为您的口味量身定制的内容", rowRoute: .shelf(.featured),
                               covers: items.prefix(3).map { model.coverArt($0) }, metrics: m) {
                ForEach(items, id: \.path) { v in featuredCard(v, m) }
            }
        }
    }

    /// 一张精选卡：整幅画面 + 底下的磨砂条（小海报、片名、「Cuven 独占 · 类型」、「查看」）；
    /// 点开是详情（从这张卡上放大出来），长按是播放 / 想看（C21）
    private func featuredCard(_ v: Video, _ m: DSMetrics) -> some View {
        let w = m.featureCardWidth
        return ZoomLink(route: .movie(v), slot: "featured") {
            FeaturedCollectionCard(art: model.wideLockupArt(v).url, cover: model.coverArt(v), title: model.title(v),
                                   subtitle: DetailText.line(["Cuven 独占", model.meta(v)?.genres?.first]), width: w)
        }
        .accessibilityIdentifier("featured-card")
        .movieMenu(v)
    }

    /// 精选剧集：和精选电影同一种样子，片库里评分最高的剧（一部剧只出一次）
    @ViewBuilder
    private func featuredSeriesShelf(_ m: DSMetrics) -> some View {
        let items = model.featuredSeries(limit: 10)
        if items.count >= 3 {
            FeaturedCollection(title: "精选剧集", blurb: "Cuven 按评分为你挑出片库里最值得追的剧集。",
                               rowTitle: "一集接一集停不下来", rowRoute: .shelf(.series),
                               covers: items.prefix(3).map { s in
                                   let sm = model.seriesMetas[s.path]
                                   return TMDBImage.url(sm?.poster ?? sm?.posterClean, "w500")
                               }, metrics: m) {
                ForEach(items, id: \.path) { s in featuredSeriesCard(s, m) }
            }
        }
    }

    private func featuredSeriesCard(_ s: Series, _ m: DSMetrics) -> some View {
        let w = m.featureCardWidth
        let sm = model.seriesMetas[s.path]
        return ZoomLink(route: .series(s), slot: "featured-tv") {
            FeaturedCollectionCard(art: model.seriesWideArt(s).url, cover: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w342"),
                                   title: sm?.title ?? s.name,
                                   subtitle: DetailText.line(["Cuven 独占", sm?.genres?.first]), width: w)
        }
        .accessibilityIdentifier("featured-series-card")
        .seriesMenu(s)
    }

    /// 五个大类之一：电影和剧集一起，新的在前；标题「›」进这一类的全部
    @ViewBuilder
    private func categoryShelf(_ c: HomeCategory, _ m: DSMetrics) -> some View {
        let items = model.categoryEntries(c, limit: 20)
        if !items.isEmpty {
            DSSection(title: c.title, metrics: m, route: .shelf(.category(c))) {
                DSShelf(metrics: m) {
                    ForEach(items) { e in posterCard(e, m, slot: "cat-\(c.rawValue)") }
                }
            }
        }
    }

    /// 一张海报卡：纯净画面 + 字标（AppModel.posterArt / seriesPosterArt 定先后），长按是播放 / 想看（C21）
    @ViewBuilder
    private func posterCard(_ e: HomeEntry, _ m: DSMetrics, slot: String) -> some View {
        switch e {
        case .movie(let v):
            let art = model.posterArt(v, width: m.posterWidth)
            ZoomLink(route: .movie(v), slot: slot) {
                DSPosterLockup(art: art.url, title: model.title(v), subtitle: model.year(v).map { String($0) },
                               metrics: m, logo: art.logo)
            }
            .accessibilityIdentifier("movie-card")
            .movieMenu(v)
        case .series(let s):
            let art = model.seriesPosterArt(s, width: m.posterWidth)
            ZoomLink(route: .series(s), slot: slot) {
                DSPosterLockup(art: art.url, title: model.seriesMetas[s.path]?.title ?? s.name, subtitle: s.seasonLabel,
                               metrics: m, logo: art.logo)
            }
            .accessibilityIdentifier("series-card")
            .seriesMenu(s)
            .task { await model.ensureSeriesMeta(s) }
        }
    }

    /// 继续观看的画面：电影按片库里的那一部取（Apple TV 无字背景 + 字标优先：AppModel.wideLockupArt）；
    /// 剧集用这部剧的剧照 + 字标（集的剧照上认不出是哪一部）；都找不到就用存进度时记下的那张
    private func continueArt(_ e: WatchEntry) -> (url: URL?, logo: URL?) {
        if let sp = e.seriesPath, let s = model.series.first(where: { $0.path == sp }) { return model.seriesWideArt(s) }
        if e.seriesPath == nil, let v = model.video(path: e.path) { return model.wideLockupArt(v) }
        return (TMDBImage.url(e.artwork, "w780"), nil)
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
