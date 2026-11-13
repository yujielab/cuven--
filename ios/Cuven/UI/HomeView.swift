import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let wide = geo.size.width > geo.size.height || geo.size.width >= 700
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 34) {
                        HeroPager(items: heroItems, wide: wide, width: geo.size.width,
                                  height: wide ? min(geo.size.height * 0.82, geo.size.width * 9 / 16 + 60) : min(geo.size.height * 0.78, 720))
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
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
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
            let cw = model.playback.continueWatching
            if !cw.isEmpty {
                section("继续观看", count: cw.count) {
                    Rail {
                        ForEach(cw) { e in
                            Button { resume(e) } label: { ContinueCard(entry: e) }.buttonStyle(.plain)
                        }
                    }
                }
            }

            let picks = model.todayPicks
            if !picks.isEmpty {
                section("今日推荐", count: picks.count) {
                    Rail(spacing: 6) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { i, v in
                            NavigationLink(value: Route.movie(v)) { RankCard(rank: i + 1, video: v) }.buttonStyle(.plain)
                        }
                    }
                }
            }

            section("最新加入", count: nil) {
                Rail {
                    ForEach(model.newest) { v in
                        NavigationLink(value: Route.movie(v)) { PosterCard(video: v) }.buttonStyle(.plain)
                            .accessibilityIdentifier("newest-poster")
                    }
                }
            }

            let tv = Array(model.homeSeries.prefix(12))
            if !tv.isEmpty {
                section("Cuven TV · 剧集", count: nil) {
                    Rail(spacing: 14) {
                        ForEach(tv) { s in
                            NavigationLink(value: Route.series(s)) { SeriesCard(series: s, width: min(width * 0.86, 440)) }.buttonStyle(.plain)
                                .accessibilityIdentifier("series-card")
                        }
                    }
                }
            }

            ForEach(model.yearGroups, id: \.year) { g in
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: Route.year(g.year)) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(g.year)).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                            Text("\(g.videos.count)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.tertiary)
                            Spacer()
                            Text("查看电影和剧集")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.accent, in: Capsule())
                        }
                        .padding(.horizontal, Theme.gutter)
                    }
                    .buttonStyle(.plain)
                    Rail {
                        ForEach(g.videos.prefix(15)) { v in
                            NavigationLink(value: Route.movie(v)) { PosterCard(video: v) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, count: Int?, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, count: count)
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
        let json: [String: Any] = ["path": path, "background": backdrop, "poster": poster ?? backdrop]
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return (try? JSONDecoder().decode(Hero.self, from: data)) ?? (try! JSONDecoder().decode(Hero.self, from: Data("{\"path\":\"\"}".utf8)))
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

    var body: some View {
        ZStack(alignment: .bottom) {
            if items.isEmpty {
                LinearGradient(colors: [Theme.surface2, Theme.bg], startPoint: .top, endPoint: .bottom)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(items) { it in
                            HeroPage(item: it, wide: wide)
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
                    HStack(spacing: 7) {
                        ForEach(items) { it in
                            Capsule()
                                .fill(it.id == (current ?? items.first?.id) ? Color.white : Color.white.opacity(0.4))
                                .frame(width: it.id == (current ?? items.first?.id) ? 18 : 7, height: 7)
                        }
                    }
                    .animation(.snappy, value: current)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 14)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .task(id: items.map(\.id).joined(separator: "|")) {
            guard items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                let idx = items.firstIndex { $0.id == current } ?? 0
                withAnimation(.easeInOut(duration: 0.6)) { current = items[(idx + 1) % items.count].id }
            }
        }
    }
}

struct HeroPage: View {
    @Environment(AppModel.self) private var model
    let item: HeroItem
    let wide: Bool

    var body: some View {
        let m = model.meta(item.video)
        let art = wide ? (item.hero.background ?? item.hero.poster) : (item.hero.poster ?? item.hero.background)
        ZStack(alignment: .bottom) {
            // 铺满裁切的图放在 overlay 里：图比框大时不会把框撑大（只设 max 的弹性框会跟着子视图变大）
            Color.clear
                .overlay { RemoteImage(url: URL(string: art ?? ""), maxPixel: 1600) }
                .clipped()
            LinearGradient(stops: [
                .init(color: .black.opacity(0.35), location: 0),
                .init(color: .clear, location: 0.18),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.7), location: 0.78),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                LogoImage(url: URL(string: item.hero.logo ?? "") ?? TMDBImage.url(m?.logo, "w500"), height: wide ? 90 : 72,
                          fallback: model.title(item.video))
                    .frame(maxWidth: wide ? 420 : 300)
                Text(line(m))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Button {
                        PlayerCoordinator.shared.play(PlayRequest(path: item.video.path, name: item.video.name, title: model.title(item.video),
                                                                  subtitle: model.year(item.video).map { String($0) },
                                                                  artwork: m?.backdrop ?? item.hero.background), model: model)
                    } label: {
                        PrimaryLabel(title: model.playback.resumePosition(item.video.path) != nil ? "继续播放" : "播放", systemImage: "play.fill")
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("hero-play")
                    NavigationLink(value: Route.movie(item.video)) {
                        Label("详情", systemImage: "info.circle")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .accessibilityIdentifier("hero-detail")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 66)          // 下面留给翻页圆点
        }
    }

    private func line(_ m: Meta?) -> String {
        var parts: [String] = []
        if let t = m?.title, !t.isEmpty { parts.append(t) }
        if let y = model.year(item.video) { parts.append(String(y)) }
        if let g = m?.genres?.first { parts.append(g) }
        return parts.joined(separator: " · ")
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
        }
    }
}
