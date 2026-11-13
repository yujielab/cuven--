import SwiftUI

@MainActor
enum ArtTint {
    private static var cache: [URL: (h: CGFloat, s: CGFloat, b: CGFloat)] = [:]

    static func color(for url: URL, ceiling: CGFloat = 0.42) async -> Color? {
        let hsb: (h: CGFloat, s: CGFloat, b: CGFloat)
        if let hit = cache[url] {
            hsb = hit
        } else {
            guard let img = await ImagePipeline.shared.image(url, maxPixel: 120), let cg = img.cgImage,
                  let v = average(cg) else { return nil }
            cache[url] = v
            hsb = v
        }
        return Color(UIColor(hue: hsb.h, saturation: min(1, hsb.s * 1.1), brightness: min(hsb.b, ceiling) * 0.85, alpha: 1))
    }

    nonisolated static func average(_ cg: CGImage) -> (h: CGFloat, s: CGFloat, b: CGFloat)? {
        let h = cg.height, w = cg.width
        guard h > 4, w > 4,
              let strip = cg.cropping(to: CGRect(x: 0, y: h * 3 / 4, width: w, height: h - h * 3 / 4)) else { return nil }
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(strip, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2])
        }
        let total = Double(n * n) * 255
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: r / total, green: g / total, blue: b / total, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return (hue, sat, bri)
    }
}

/// 全屏预告片从第几段开始
/// 简介：默认 4 行，真的被截断了才带「更多」（量出全文和截断后的高度来比，不靠字数猜）。
/// 给了 fade：「更多」是叠在最后一行末尾的小胶囊，底下的字往这个颜色里淡出去（Apple TV 详情页的写法）
struct ExpandableText: View {
    let text: String
    var lines: Int = 4
    var fade: Color? = nil
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    var body: some View {
        let truncated = !expanded && fullHeight > shownHeight + 1
        if let fade {
            styled
                .lineLimit(expanded ? nil : lines)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in shownHeight = h }
                .background(alignment: .top) { measure }
                .overlay(alignment: .bottomTrailing) {
                    if truncated {
                        moreButton
                            .padding(.leading, 40)
                            .background(LinearGradient(colors: [fade.opacity(0), fade, fade], startPoint: .leading, endPoint: .trailing))
                    }
                }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                styled
                    .lineLimit(expanded ? nil : lines)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in shownHeight = h }
                    .background(alignment: .top) { measure }
                if truncated { moreButton }
            }
        }
    }

    private var styled: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.86))
            .lineSpacing(4)
    }

    /// 不限行数的同一段字（看不见），只用来量全文多高
    private var measure: some View {
        styled
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in fullHeight = h }
    }

    private var moreButton: some View {
        Button { withAnimation(.snappy) { expanded = true } } label: {
            Text("更多")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.white.opacity(fade == nil ? 0 : 0.2), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("overview-more")
    }
}

// MARK: - 某一年：和网页版的年份页一样（「2026 年 / N 部影片」，电影一组、剧集一组，一行一部）
//
// 一行：竖版海报（56 宽、圆角 8）、片名（17 半粗）、下面一行灰字（电影「科幻 · 冒险」，剧集「剧情 · 全 8 集」），
// 行尾「…」：电影是「播放 / 复制直链」那张弹层，剧集是「继续看 / 查看分集」；行与行之间一条发丝线，从文字那一列起头。

struct YearView: View {
    @Environment(AppModel.self) private var model
    let year: Int
    @State private var sheetMovie: Video?
    @State private var sheetSeries: Series?
    @State private var openSeries: Series?
    @State private var toast: String?
    @State private var showTitle = false

    var body: some View {
        let movies = model.movies(inYear: year).sorted { model.title($0).localizedCompare(model.title($1)) == .orderedAscending }
        let series = model.seriesInYear(year)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "\(year) 年")
                        .font(.system(size: 32, weight: .heavy))
                        .tracking(-0.64)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(verbatim: "\(movies.count) 部影片")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 12)
                .padding(.bottom, 20)

                if movies.isEmpty && series.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "film").font(.system(size: 36)).foregroundStyle(.white.opacity(0.3))
                        Text("该年份暂无影片").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
                if !movies.isEmpty {
                    YearGroup(label: "电影", count: movies.count) {
                        ForEach(Array(movies.enumerated()), id: \.element.id) { i, v in
                            YearMovieRow(video: v, first: i == 0) { sheetMovie = v }
                        }
                    }
                    .padding(.top, 10)
                }
                if !series.isEmpty {
                    YearGroup(label: "剧集", count: series.count) {
                        ForEach(Array(series.enumerated()), id: \.element.id) { i, s in
                            YearSeriesRow(series: s, first: i == 0) { sheetSeries = s }
                        }
                    }
                    .padding(.top, movies.isEmpty ? 10 : 34)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.contentInsets.top > 60 } action: { _, v in
            withAnimation(.easeOut(duration: 0.2)) { showTitle = v }
        }
        .navigationTitle(showTitle ? "\(String(year)) 年" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openSeries) { SeriesDetailView(series: $0) }
        .sheet(item: $sheetMovie) { v in
            WebFileSheet(title: model.title(v), onPlay: {
                let m = model.meta(v)
                PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(v),
                                                          subtitle: model.year(v).map { String($0) },
                                                          artwork: m?.backdrop ?? m?.poster), model: model)
            }, onCopy: {
                Task { @MainActor in
                    await StreamLink.copy(path: v.path, name: v.name)
                    withAnimation(.snappy) { toast = "直链已复制" }
                }
            })
        }
        .sheet(item: $sheetSeries) { s in
            let seen = model.playback.lastEpisode(of: s.path) != nil
            WebActionSheet(title: YearSeriesRow.name(s), rows: [
                WebSheetRow(symbol: "play.circle.fill", tint: WebSheetRow.orange, label: seen ? "继续看" : "从第 1 集看起",
                            note: s.countLabel, id: "sheet-play") {
                    Task { @MainActor in
                        if !(await SeriesPlayback.playNext(s, model: model)) { withAnimation(.snappy) { toast = "暂无可播放文件" } }
                    }
                },
                WebSheetRow(symbol: "info.circle", tint: WebSheetRow.blue, label: "查看分集", note: "简介、演员与每一集", id: "sheet-detail") {
                    openSeries = s
                },
            ])
        }
        .webToast($toast)
    }
}

/// 「电影 4」：20 粗体 + 13 半粗灰色数字，下面一行一部
struct YearGroup<Rows: View>: View {
    let label: String
    let count: Int
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.28)
                    .foregroundStyle(.white)
                Text(verbatim: String(count))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
            }
            LazyVStack(spacing: 0) { rows() }
        }
        .padding(.leading, Theme.gutter)
        .padding(.trailing, Theme.gutter)
    }
}

/// 一行（网页版 .yl-row）：海报 56×84、片名、灰字、「…」；顶上一条从文字那一列起头的发丝线（第一行没有）。
/// 点这一行进详情；「…」是单独的一颗钮（不嵌在行的链接里）
struct YearRowShell<Thumb: View>: View {
    let route: Route
    let id: String
    let title: String
    let subtitle: String
    let first: Bool
    let onMore: () -> Void
    @ViewBuilder var thumb: () -> Thumb

    var body: some View {
        HStack(spacing: 0) {
            NavigationLink(value: route) {
                HStack(spacing: 16) {
                    thumb()
                        .frame(width: 56, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.32), radius: 6, y: 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.92))
            .accessibilityLabel("更多操作：" + title)
            .accessibilityIdentifier("year-more")
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(Color.white.opacity(0.13)).frame(height: 0.5).padding(.leading, 56 + 16)
            }
        }
    }
}

struct YearMovieRow: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let first: Bool
    let onMore: () -> Void

    var body: some View {
        let m = model.meta(video)
        let genres = (m?.genres ?? []).prefix(2).joined(separator: " · ")
        YearRowShell(route: .movie(video), id: "year-movie", title: model.title(video), subtitle: genres.isEmpty ? "电影" : genres,
                     first: first, onMore: onMore) {
            RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), maxPixel: 200)
        }
    }
}

struct YearSeriesRow: View {
    @Environment(AppModel.self) private var model
    let series: Series
    let first: Bool
    let onMore: () -> Void

    /// 网页版：第二季起片名后面带「第 n 季」
    static func name(_ s: Series) -> String {
        if let n = s.season, n > 1 { return s.name + " 第 \(n) 季" }
        return s.name
    }

    var body: some View {
        let m = model.seriesMetas[series.path]
        let sub = [(m?.genres ?? []).prefix(2).joined(separator: " · "), series.countLabel].filter { !$0.isEmpty }.joined(separator: " · ")
        YearRowShell(route: .series(series), id: "year-series", title: Self.name(series), subtitle: sub, first: first, onMore: onMore) {
            RemoteImage(url: TMDBImage.url(m?.poster ?? m?.posterClean, "w185"), maxPixel: 200)
        }
        .task { await model.ensureSeriesMeta(series) }
    }
}

/// 内容滚到状态栏底下时压一层渐暗（详情页没有导航栏底色）
struct StatusBarScrim: View {
    var body: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: geo.safeAreaInsets.top + 24)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
    }
}
