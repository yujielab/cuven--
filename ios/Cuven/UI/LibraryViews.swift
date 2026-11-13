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

// MARK: - 搜索：和网页版一样（「搜索或提问」）
//
// 没输入：「最近添加」两列竖版海报（片名、年份），最近入库的 12 部。
// 输入了：「“夜” · 4 个结果」，剧集在上（「剧集 · 1」一排宽卡：剧照、「更新至第 15 集 / 共 19 集」、字标或片名，
// 底栏缩略图 + 剧名 + 「详情」），电影在下（「电影 · 3」，同样的两列海报）。没结果：「未找到「夜」相关结果」。

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        ZoomStack {
            GeometryReader { geo in
                // 系统栏竖在侧边（iPhone Duo 折起时 / 展开横拿时）：搜索框不挂在底部的标签栏上，得在标题下面一直显示
                let sideBars = abs(geo.safeAreaInsets.leading - geo.safeAreaInsets.trailing) > 30
                content(width: geo.size.width)
                    .searchable(text: $query, placement: sideBars ? .navigationBarDrawer(displayMode: .always) : .automatic,
                                prompt: "搜索或提问")
            }
            .background(Theme.bg)
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
        }
        // 详情页演员弹层「在资料库中搜索」：把名字填进搜索框（网页版 searchByActor）
        .onChange(of: model.searchRequest, initial: true) { _, q in
            guard let q else { return }
            query = q
            model.searchRequest = nil
        }
    }

    private func content(width: CGFloat) -> some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if q.isEmpty {
                    let recent = model.movies.sorted { $0.addedKey > $1.addedKey }.prefix(12)
                    if recent.isEmpty {
                        emptyHint(title: "搜索电影、剧集", detail: "输入片名开始，结果会即时出现")
                    } else {
                        Text("最近添加")
                            .font(.system(size: 14, weight: .bold))
                            .tracking(1.1)
                            .foregroundStyle(.white.opacity(0.65))
                            .padding(.horizontal, Theme.gutter)
                            .padding(.top, 20)
                            .padding(.bottom, 16)
                        SearchPosterGrid(videos: Array(recent))
                    }
                } else {
                    let hits = model.search(q)
                    let tv = hits.compactMap { h -> Series? in if case .series(let s) = h.kind { return s } else { return nil } }
                    let mv = hits.compactMap { h -> Video? in if case .movie(let v) = h.kind { return v } else { return nil } }
                    if hits.isEmpty {
                        emptyHint(title: "未找到「\(q)」相关结果", detail: "试试不同的关键词，或检查拼写")
                    } else {
                        (Text("“\(q)”").fontWeight(.semibold).foregroundStyle(.white.opacity(0.65))
                         + Text(" · \(tv.count + mv.count) 个结果").foregroundStyle(.white.opacity(0.4)))
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, Theme.gutter)
                            .padding(.top, 22)
                            .padding(.bottom, 4)
                        if !tv.isEmpty {
                            subhead("剧集 · \(tv.count)")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(tv) { s in
                                        ZoomLink(route: .series(s), slot: "search-tv") {
                                            SearchTVCard(series: s, width: min(width * 0.86, 560))
                                        }
                                        .accessibilityIdentifier("search-series")
                                    }
                                }
                                .scrollTargetLayout()
                                .padding(.vertical, 6)
                            }
                            .contentMargins(.horizontal, Theme.gutter, for: .scrollContent)
                            .scrollTargetBehavior(.viewAligned)
                            .padding(.top, 6)
                        }
                        if !mv.isEmpty {
                            if !tv.isEmpty { subhead("电影 · \(mv.count)") }
                            SearchPosterGrid(videos: mv)
                                .padding(.top, 8)
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.bg)
    }

    private func subhead(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 15, weight: .bold))
            .tracking(-0.15)
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 14)
    }

    private func emptyHint(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Text(detail).font(.system(size: 14)).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 80)
    }
}

/// 网页版 .library-grid：两列（最小 158 宽）竖版海报，行距 32、列距 16；海报下片名（15 粗）、年份（13 灰）
struct SearchPosterGrid: View {
    @Environment(AppModel.self) private var model
    let videos: [Video]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 16, alignment: .top)], alignment: .leading, spacing: 32) {
            ForEach(videos) { v in
                ZoomLink(route: .movie(v), slot: "search-grid") {
                    let m = model.meta(v)
                    VStack(alignment: .leading, spacing: 0) {
                        Color.white.opacity(0.06)
                            .aspectRatio(2 / 3, contentMode: .fit)
                            .overlay { RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w342"), maxPixel: 600, placeholder: .clear) }
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        Text(model.title(v))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.top, 12)
                        Text(model.year(v).map { String($0) } ?? " ")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.top, 2)
                    }
                }
                .accessibilityIdentifier("search-movie")
                .movieMenu(v)
            }
        }
        .padding(.horizontal, Theme.gutter)
    }
}

/// 网页版 .tv-card：15:13 的大卡（圆角 26）——上面一张清楚的 16:9 剧照，往下化进同一张图的失焦版；
/// 文案压在下半截（「更新至第 15 集 / 共 19 集」、字标或片名），最底下一条毛玻璃底栏：缩略图、剧名、「详情」
struct SearchTVCard: View {
    @Environment(AppModel.self) private var model
    let series: Series
    let width: CGFloat

    var body: some View {
        let m = model.seriesMetas[series.path]
        let art = m?.backdrop ?? m?.posterClean ?? m?.poster
        let height = width * 13 / 15
        let footName = (series.en?.isEmpty == false && series.zh?.isEmpty == false) ? series.en! : (m?.title ?? series.name)
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255), Color(red: 23 / 255, green: 23 / 255, blue: 26 / 255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // 失焦的那层铺满整卡，清楚的那张贴顶、16:9、底缘往下淡出
            RemoteImage(url: TMDBImage.url(art, "w342"), maxPixel: 400, placeholder: .clear)
                .scaleEffect(1.3)
                .blur(radius: 28)
                .opacity(0.9)
            RemoteImage(url: TMDBImage.url(art, "w780"), maxPixel: width * 3, placeholder: .clear)
                .frame(width: width, height: width * 9 / 16)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.86), location: 0),
                .init(color: .black.opacity(0.78), location: 0.2),
                .init(color: .black.opacity(0.6), location: 0.38),
                .init(color: .black.opacity(0.32), location: 0.52),
                .init(color: .black.opacity(0.06), location: 0.68),
                .init(color: .clear, location: 0.84),
            ], startPoint: .bottom, endPoint: .top)

            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(series.countLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    Group {
                        if let logo = m?.logo, !logo.isEmpty {
                            LogoImage(url: TMDBImage.url(logo, "w500"), height: 60, fallback: m?.title ?? series.name, maxWidth: width - 40)
                        } else {
                            Text(m?.title ?? series.name)
                                .font(.system(size: min(27, max(21, width * 0.07)), weight: .heavy))
                                .tracking(-0.6)
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                    }
                    .frame(minHeight: 66, alignment: .bottom)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                HStack(spacing: 10) {
                    Color.white.opacity(0.1)
                        .overlay {
                            if let still = m?.stills?.first?.thumb ?? m?.stills?.first?.url ?? m?.poster {
                                RemoteImage(url: TMDBImage.url(still, "w300"), maxPixel: 220, placeholder: .clear)
                            } else {
                                Text(String(series.name.prefix(1))).font(.system(size: 17, weight: .heavy)).foregroundStyle(.white.opacity(0.72))
                            }
                        }
                        .frame(width: 68, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    Text(footName)
                        .font(.system(size: 16, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("详情")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(minWidth: 84, minHeight: 34)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Color.white.opacity(0.24), in: Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 13)
                .background(.ultraThinMaterial.opacity(0.6))
                .background(Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255).opacity(0.42))
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5) }
            }
            .environment(\.colorScheme, .dark)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 27, y: 22)
        .task { await model.ensureSeriesMeta(series) }
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
