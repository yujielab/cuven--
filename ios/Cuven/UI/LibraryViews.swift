import SwiftUI

// MARK: - 资料库

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    enum Kind: String, CaseIterable, Identifiable { case movies = "电影", series = "剧集"; var id: String { rawValue } }
    enum Order: String, CaseIterable, Identifiable { case added = "最新加入", year = "年份", rating = "评分"; var id: String { rawValue } }

    @State private var kind: Kind = .movies
    @State private var order: Order = .added
    @State private var year: Int?

    var body: some View {
        ZoomStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("类型", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.gutter)

                    if kind == .movies {
                        let list = movies
                        Text(verbatim: year.map { "\($0) 年 · \(list.count) 部" } ?? "\(list.count) 部电影")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, Theme.gutter)
                        PosterGrid {
                            ForEach(list) { v in
                                ZoomLink(route: .movie(v), slot: "library") { MoviePosterTile(video: v) }
                                    .accessibilityIdentifier("library-movie")
                                    .movieMenu(v)
                            }
                        }
                    } else {
                        let list = seriesList
                        Text(verbatim: year.map { "\($0) 年 · \(list.count) 部" } ?? "\(list.count) 部剧集")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, Theme.gutter)
                        PosterGrid {
                            ForEach(list) { s in
                                ZoomLink(route: .series(s), slot: "library") { SeriesPosterTile(series: s) }
                                    .accessibilityIdentifier("library-series")
                                    .seriesMenu(s)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .navigationTitle("资料库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序", selection: $order) {
                            ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("年份", selection: $year) {
                            Text("全部年份").tag(Int?.none)
                            ForEach(years, id: \.self) { y in Text(String(y)).tag(Int?.some(y)) }
                        }
                    } label: {
                        // 标题 + 符号都给：系统在竖向栏里用符号，溢出菜单里用标题
                        Label("排序与筛选", systemImage: "line.3.horizontal.decrease")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AvatarButton()
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .refreshable { await model.refreshAll() }
        }
    }

    private var years: [Int] {
        let ys = Set(model.movies.compactMap { model.year($0) } + model.series.compactMap { Int($0.year ?? "") })
        return ys.sorted(by: >)
    }

    private var movies: [Video] {
        var list = model.movies
        if let year { list = list.filter { model.year($0) == year } }
        switch order {
        case .added: break
        case .year: list.sort { (model.year($0) ?? 0) > (model.year($1) ?? 0) }
        case .rating: list.sort { (model.meta($0)?.rating ?? 0) > (model.meta($1)?.rating ?? 0) }
        }
        return list
    }

    private var seriesList: [Series] {
        var list = model.series
        if let year { list = list.filter { Int($0.year ?? "") == year } }
        switch order {
        case .added: break
        case .year: list.sort { (Int($0.year ?? "") ?? 0) > (Int($1.year ?? "") ?? 0) }
        case .rating: list.sort { (model.seriesMetas[$0.path]?.rating ?? 0) > (model.seriesMetas[$1.path]?.rating ?? 0) }
        }
        return list
    }
}

/// 自适应列数的海报网格
struct PosterGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 12, alignment: .top)], alignment: .leading, spacing: 18) {
            content()
        }
        .padding(.horizontal, 16)
    }
}

struct MoviePosterTile: View {
    @Environment(AppModel.self) private var model
    let video: Video

    var body: some View {
        let m = model.meta(video)
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w342"), maxPixel: 520) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .overlay(alignment: .bottom) {
                    if let e = model.playback.entry(video.path), e.fraction > 0.01 {
                        ProgressCapsule(fraction: e.fraction).padding(.horizontal, 6).padding(.bottom, 6)
                    }
                }
            Text(model.title(video)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(model.year(video).map { String($0) } ?? " ").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }
}

struct SeriesPosterTile: View {
    @Environment(AppModel.self) private var model
    let series: Series

    var body: some View {
        let m = model.seriesMetas[series.path]
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    ZStack {
                        Text(series.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.tertiary)
                            .multilineTextAlignment(.center).padding(8)
                        RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w342"), maxPixel: 520, placeholder: .clear)
                    }
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            Text(m?.title ?? series.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text([series.seasonLabel, series.countLabel].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .task { await model.ensureSeriesMeta(series) }
    }
}

// MARK: - 搜索

/// 搜索（App Store「搜寻」的版式）：大标题 + 右上头像，搜索框在标题下面；
/// 没输入时是「为你推荐 ›」（横着一页一页翻、每页三行、行尾「播放」胶囊）和「浏览 ›」（按类型的彩色格子）；输入了就是结果列表
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        ZoomStack {
            GeometryReader { geo in
                // 系统栏竖在侧边（iPhone Duo 折起时 / 展开横拿时）：左右安全区一边宽一边窄。
                // 这时搜索标签不再把搜索框挂在底部的标签栏上，得在标题下面一直显示一个
                let sideBars = abs(geo.safeAreaInsets.leading - geo.safeAreaInsets.trailing) > 30
                results(width: geo.size.width)
                    .searchable(text: $query, placement: sideBars ? .navigationBarDrawer(displayMode: .always) : .automatic,
                                prompt: "电影、剧集、年份")
            }
            .background(Theme.bg)
            .navigationTitle("搜索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AvatarButton()
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private func results(width: CGFloat) -> some View {
        ScrollView {
            let hits = model.search(query)
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    discover(width: width)
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 60)
                } else {
                    ForEach(hits) { h in
                        ZoomLink(route: route(h), slot: "search-row", press: false) { SearchRow(hit: h) }
                        Divider().overlay(Theme.hairline).padding(.leading, 84)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.bg)
    }

    @ViewBuilder private func discover(width: CGFloat) -> some View {
        let picks = model.todayPicks
        if !picks.isEmpty {
            SectionHeader(title: "为你推荐", route: .shelf(.picks))
                .padding(.top, 12)
                .padding(.bottom, 4)
            PagedRows(videos: Array(picks.prefix(12)), width: width, slot: "search-picks")
        }
        let genres = model.genres.prefix(8).map { $0.name }
        if !genres.isEmpty {
            SectionHeader(title: "浏览", route: .browse)
                .padding(.top, 28)
                .padding(.bottom, 12)
            GenreGrid(genres: genres)
        }
    }

    private func route(_ h: AppModel.SearchHit) -> Route {
        switch h.kind {
        case .movie(let v): return .movie(v)
        case .series(let s): return .series(s)
        }
    }
}

struct SearchRow: View {
    let hit: AppModel.SearchHit
    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: hit.image, maxPixel: 200)
                .frame(width: 52, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(hit.subtitle).font(.system(size: 13)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - 我的

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v)（\(b)）"
    }
}
