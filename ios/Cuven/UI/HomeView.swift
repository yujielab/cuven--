import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hsc

    var body: some View {
        let _ = Perf.count("home")
        ZoomStack {
            GeometryReader { geo in
                let wide = geo.size.width > geo.size.height || geo.size.width >= 700
                // 卡片态：紧凑宽度、竖着、但比普通 iPhone 矮得多（iPhone Duo 折起时的外屏，系统栏在侧边那一列）
                let cards = hsc == .compact && geo.size.height > geo.size.width && geo.size.height < geo.size.width * 1.95
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 48) {
                        if cards {
                            // 和网页版一样：没有页面标题，卡片占满一屏（网页版 hero-stage：卡 324×557，下面一排页码）
                            HeroCards(items: heroItems, width: geo.size.width,
                                      cardHeight: max(360, geo.size.height - 92))
                                .padding(.top, geo.safeAreaInsets.top + 18)
                        } else {
                            HeroPager(items: heroItems, wide: wide, width: geo.size.width,
                                      height: wide ? min(geo.size.height * 0.82, geo.size.width * 9 / 16 + 60) : min(geo.size.height * 0.86, 820))
                        }
                        content(width: geo.size.width)
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .background(Theme.bg)
                .ignoresSafeArea(edges: .top)
                .refreshable { await model.refreshAll() }
                // 内容滚到状态栏底下时压一层渐暗，时间和电量不至于压在海报上看不清
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: geo.safeAreaInsets.top + 18)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
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
                guard let bd = m?.backdrop else { continue }
                out.append(HeroItem(hero: Hero.fallback(path: v.path, backdrop: bd, poster: m?.posterClean ?? m?.poster), video: v))
            }
        }
        return out
    }

    @ViewBuilder private func content(width: CGFloat) -> some View {
        let movies = model.movies
        if movies.isEmpty {
            switch model.phase {
            case .failed(let msg):
                ContentUnavailableView {
                    Label("连不上服务器", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(msg)
                } actions: {
                    Button("重试") { Task { await model.refreshAll() } }.buttonStyle(.glass)
                }
                .frame(minHeight: 300)
            default:
                SkeletonRow()
                SkeletonRow()
            }
        } else {
            // 和网页版同样的顺序：今日推荐 → 继续观看 → 最新加入 → Cuven TV → 按年份
            let picks = model.todayPicks
            if !picks.isEmpty {
                chipSection("今日推荐") {
                    Rail(spacing: 17) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { i, v in
                            ZoomLink(route: .movie(v), slot: "picks") { RankCard(rank: i + 1, video: v) }.movieMenu(v)
                        }
                    }
                }
            }

            let cw = model.playback.continueWatching
            if !cw.isEmpty {
                chipSection("继续观看") {
                    Rail(spacing: 16) {
                        ForEach(cw) { e in
                            Button { resume(e) } label: { ContinueCard(entry: e, width: landscapeWidth(width)) }
                                .buttonStyle(PressableStyle())
                        }
                    }
                }
            }

            chipSection("最新加入") {
                Rail(spacing: 16) {
                    ForEach(model.newest) { v in
                        ZoomLink(route: .movie(v), slot: "newest") { LandscapeCard(video: v, width: landscapeWidth(width)) }
                            .accessibilityIdentifier("newest-poster")
                            .movieMenu(v)
                    }
                }
            }

            let tv = Array(model.homeSeries.prefix(12))
            if !tv.isEmpty {
                TVHeroRail(series: tv, width: width)
            }

            ForEach(model.yearGroups, id: \.year) { g in
                let yearSeries = tv.filter { Int($0.year ?? "") == g.year }
                VStack(alignment: .leading, spacing: 20) {
                    YearBar(year: g.year)
                        .padding(.horizontal, Theme.gutter)
                    if !yearSeries.isEmpty {
                        Rail(spacing: 14) {
                            ForEach(yearSeries) { s in
                                ZoomLink(route: .series(s), slot: "year-tv-\(g.year)") {
                                    SeriesCard(series: s, width: landscapeWidth(width))
                                }
                                .seriesMenu(s)
                            }
                        }
                        Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.horizontal, Theme.gutter)
                    }
                    Rail(spacing: 17) {
                        ForEach(g.videos.prefix(15)) { v in
                            ZoomLink(route: .movie(v), slot: "year-\(g.year)") { PortraitCard(video: v) }.movieMenu(v)
                        }
                    }
                }
            }
        }
    }

    /// 横版卡的宽度（网页版 399 / 466 宽的视口：右边露出下一张的一截）
    private func landscapeWidth(_ width: CGFloat) -> CGFloat {
        min(440, max(260, width - Theme.gutter - 40))
    }

    /// 网页版的分区：上面一颗玻璃胶囊标题，下面一排
    private func chipSection<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionChip(title: title)
                .padding(.horizontal, Theme.gutter)
            body()
        }
    }

    private func section<C: View>(_ title: String, count: Int?, subtitle: String? = nil, route: Route? = nil,
                                  @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, count: count, subtitle: subtitle, route: route)
            body()
        }
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

// MARK: - 首页大图：竖屏用 Apple TV 的竖版海报，横屏 / iPad 用 16:9 背景；字标 + 播放 / 详情

struct HeroPager: View {
    @Environment(AppModel.self) private var model
    let items: [HeroItem]
    let wide: Bool
    let width: CGFloat
    let height: CGFloat
    @State private var current: String?
    /// 当前这一页从什么时候开始（翻页指示器里那颗胶囊的进度、自动翻页都按它算；手动翻页时重新计时）
    @State private var pageStart = Date()
    /// 网页版点点左边那颗 ⏸：停在这一页，不再自动翻
    @State private var paused = false
    static let interval: Double = 8

    var body: some View {
        let _ = Perf.count("heroPager")
        let currentID = current ?? items.first?.id
        ZStack(alignment: .bottom) {
            if items.isEmpty {
                LinearGradient(colors: [Theme.surface2, Theme.bg], startPoint: .top, endPoint: .bottom)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(items) { it in
                            HeroPage(item: it, wide: wide, width: width, active: it.id == currentID)
                                .frame(width: width, height: height)
                                .clipped()
                                .id(it.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $current)

                if items.count > 1 {
                    HStack(spacing: 10) {
                        Button {
                            paused.toggle()
                            if !paused { pageStart = Date() }
                            Haptics.light()
                        } label: {
                            Image(systemName: paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel(paused ? "继续自动翻页" : "暂停自动翻页")
                        HeroIndicator(ids: items.map(\.id), current: currentID, start: pageStart, duration: Self.interval, paused: paused)
                    }
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .stretchy()
        .onChange(of: current) { _, _ in pageStart = Date() }
        .task(id: items.map(\.id).joined(separator: "|")) {
            guard items.count > 1 else { return }
            pageStart = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !paused && Date().timeIntervalSince(pageStart) >= Self.interval {
                    let idx = items.firstIndex { $0.id == current } ?? 0
                    withAnimation(.smooth(duration: 0.8)) { current = items[(idx + 1) % items.count].id }
                    pageStart = Date()
                }
            }
        }
    }
}

/// Apple TV 的翻页指示器：当前这一页是一颗会慢慢填满的胶囊，满了就翻到下一页
struct HeroIndicator: View {
    let ids: [String]
    let current: String?
    let start: Date
    let duration: Double
    var paused = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(ids, id: \.self) { id in
                if id == current {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { tl in
                        let p = paused ? 1 : min(1, max(0, tl.date.timeIntervalSince(start) / duration))
                        Capsule().fill(Color.white.opacity(0.32))
                            .frame(width: 28, height: 7)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white).frame(width: max(7, 28 * p))
                            }
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Circle().fill(Color.white.opacity(0.45)).frame(width: 7, height: 7)
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: current)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .allowsHitTesting(false)
    }
}

/// 一页大图：整幅画面点进详情（缩放转场）；当前页的画面慢慢推近，翻页时画面带视差；
/// 字标、信息行，下面「播放」+「想看」
struct HeroPage: View {
    @Environment(AppModel.self) private var model
    /// 「减弱动态效果」打开时：不推近、不做视差（只是装饰的动效都收起来）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: HeroItem
    let wide: Bool
    let width: CGFloat
    let active: Bool

    var body: some View {
        let m = model.meta(item.video)
        let calm = reduceMotion
        let w = width
        let art = wide ? (item.hero.background ?? item.hero.poster) : (item.hero.poster ?? item.hero.background)
        ZStack(alignment: .bottom) {
            ZoomLink(route: .movie(item.video), slot: "hero", press: false) {
                // 铺满裁切的图放在 overlay 里：图比框大时不会把框撑大（只设 max 的弹性框会跟着子视图变大）
                Color.clear
                    .overlay {
                        RemoteImage(url: URL(string: art ?? ""), maxPixel: 1600)
                            .scaleEffect(active && !calm ? 1.07 : 1.0)
                            .animation(.linear(duration: HeroPager.interval + 1.5), value: active)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content.offset(x: calm ? 0 : CGFloat(phase.value) * -w * 0.28)
                            }
                    }
                    .clipped()
                    .backgroundExtensionEffect()      // iPhone Duo：系统栏竖在侧边时，画面延伸到那一列底下
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("hero-detail")

            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.18),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.7), location: 0.78),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)

            VStack(spacing: 14) {
                // 网页版：「2025 · Feature Film」小胶囊、字标、「Cuven TV 严选影片」
                Text(chip)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .environment(\.colorScheme, .dark)
                    .allowsHitTesting(false)
                LogoImage(url: URL(string: item.hero.logo ?? "") ?? TMDBImage.url(m?.logo, "w500"), height: wide ? 90 : 72,
                          fallback: model.title(item.video))
                    .frame(maxWidth: wide ? 420 : 300)
                    .allowsHitTesting(false)
                Label("Cuven TV 严选影片", systemImage: "play.tv")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                HStack(spacing: 12) {
                    Button {
                        PlayerCoordinator.shared.play(PlayRequest(path: item.video.path, name: item.video.name, title: model.title(item.video),
                                                                  subtitle: model.year(item.video).map { String($0) },
                                                                  artwork: m?.backdrop ?? item.hero.background), model: model)
                    } label: {
                        PrimaryLabel(title: model.playback.resumePosition(item.video.path) != nil ? "继续播放" : "播放", systemImage: "play.fill")
                            .padding(.horizontal, 22)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("hero-play")
                    WatchlistButton(key: item.video.path, kind: .movie, size: 50)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 92)          // 下面留给 ⏸ 和翻页指示器
        }
    }

    /// 「2025 · Feature Film」（和网页版一样用 Apple TV 的英文类型）
    private var chip: String {
        let y = item.hero.year ?? model.year(item.video)
        let kind = (item.hero.type ?? "Movie").lowercased().hasPrefix("show") ? "TV Series" : "Feature Film"
        return [y.map { String($0) }, kind].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - 导航目标

struct RouteView: View {
    let route: Route
    var body: some View {
        switch route {
        case .movie(let v): MovieDetailView(video: v)
        case .series(let s): SeriesDetailView(series: s)
        case .year(let y): YearView(year: y)
        case .shelf(let s): ShelfView(shelf: s)
        }
    }
}

/// 主页顶上：大标题「主页」+ 右上角头像（账户与设置）—— 压在大图上，跟着大图一起滚走
