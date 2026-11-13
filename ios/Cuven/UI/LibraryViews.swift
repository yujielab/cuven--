import SwiftUI

// MARK: - 资料库用过的小部件（资料库本身见 LibraryShowcase.swift）


/// 资料库顶上的快捷大卡（Games「更新与活动」「成就」那种）：渐变底、左边一枚图标、标题与一行说明、右边「›」
struct ShortcutTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let colors: [Color]
    let route: Route

    static let amber = [Color(red: 0.45, green: 0.30, blue: 0.15), Color(red: 0.30, green: 0.22, blue: 0.16)]
    static let ocean = [Color(red: 0.16, green: 0.31, blue: 0.42), Color(red: 0.14, green: 0.23, blue: 0.31)]

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(LinearGradient(colors: [colors[0].opacity(1).mix(with: .white, by: 0.28), colors[0]],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)
                .rotationEffect(.degrees(-6))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 15)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 20)
            .frame(height: 92)
            .background(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }
}

/// 资料库里的一部电影（Games「你的游戏」那一行）：海报、片名、上次看到 / 加入时间，行尾「播放」胶囊；点别处进详情
struct LibraryMovieRow: View {
    @Environment(AppModel.self) private var model
    let video: Video

    var body: some View {
        let m = model.meta(video)
        let entry = model.playback.entry(video.path)
        ZStack(alignment: .trailing) {
            ZoomLink(route: .movie(video), slot: "library", press: false) {
                HStack(spacing: 16) {
                    RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), maxPixel: 260)
                        .frame(width: 58, height: 87)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                        .overlay(alignment: .bottom) {
                            if let e = entry, e.fraction > 0.01 {
                                ProgressCapsule(fraction: e.fraction).padding(.horizontal, 5).padding(.bottom, 5)
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title(video))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(subtitle(m, entry))
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 96)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("library-movie")
            .movieMenu(video)
            PlayPill(video: video)
        }
        .padding(.horizontal, Theme.gutter)
    }

    private func subtitle(_ m: Meta?, _ e: WatchEntry?) -> String {
        if let e, e.position > 30 { return "上次看到 · " + Relative.string(e.updated) }
        if let d = Relative.date(video.added) { return "加入于 " + Relative.string(d) }
        return [model.year(video).map { String($0) }, m?.genres?.first].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 资料库里的一部剧：海报、剧名、上次看到第几集 / 第几季与集数，行尾「查看」
struct LibrarySeriesRow: View {
    @Environment(AppModel.self) private var model
    let series: Series

    var body: some View {
        let m = model.seriesMetas[series.path]
        ZoomLink(route: .series(series), slot: "library", press: false) {
            HStack(spacing: 16) {
                ZStack {
                    Theme.surface
                    RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), maxPixel: 260, placeholder: .clear)
                }
                .frame(width: 58, height: 87)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 4) {
                    Text(m?.title ?? series.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text("查看")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("library-series")
        .seriesMenu(series)
        .padding(.horizontal, Theme.gutter)
        .task { await model.ensureSeriesMeta(series) }
    }

    private var subtitle: String {
        if let e = model.playback.lastEpisode(of: series.path), let ep = e.episode {
            return "上次看到第 \(ep) 集 · " + Relative.string(e.updated)
        }
        return [series.seasonLabel, series.countLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 「2 小时前」「昨天」这类相对时间；入库时间是 ISO 8601（有的带毫秒）
enum Relative {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    static func string(_ d: Date) -> String {
        d.formatted(.relative(presentation: .named))
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

/// 搜索（Apple TV「搜索」的版式）：大标题 + 右上头像，搜索框在标题下面；
/// 没输入时是三列竖版画面格子（最新加入、剧集、想看，再是片库里的类型），输入了就是结果列表
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
        }
    }

    private func results(width: CGFloat) -> some View {
        ScrollView {
            let hits = model.search(query)
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    discover()
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

    /// 没输入时：Apple TV「搜索」那样，搜索框下面直接是一格格竖版画面（几个清单 + 片库里的类型）
    private func discover() -> some View {
        BrowseGrid(tiles: model.browseTiles)
            .padding(.top, 14)
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
