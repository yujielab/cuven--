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

// MARK: - 某一年（首页「2026 ›」进来）
//
// 系统大标题「2026 年」、副标题「N 部影片」（C13；iOS 26 的 navigationSubtitle），下面一张系统列表（C29、C31）：
// 一行一部——前面竖版小海报，片名与一行灰字，行尾系统的「›」进详情（系统推入：F53）。
// 「播放 / 想看」在长按菜单里（C21、C43、C45），不再有行尾「…」、自绘的底部弹层和提示条。
// 电影和剧集都有时才分两节、带节标题（只有一类时标题是多余的字：F84）。

struct YearView: View {
    @Environment(AppModel.self) private var model
    let year: Int

    var body: some View {
        let movies = model.movies(inYear: year).sorted { model.title($0).localizedCompare(model.title($1)) == .orderedAscending }
        let series = model.seriesInYear(year)
        List {
            if !movies.isEmpty && !series.isEmpty {
                Section { movieRows(movies) } header: { header("电影") }
                Section { seriesRows(series) } header: { header("剧集") }
            } else {
                movieRows(movies)
                seriesRows(series)
            }
        }
        .listStyle(.plain)
        .overlay {
            if movies.isEmpty && series.isEmpty {
                ContentUnavailableView("这一年还没有影片", systemImage: "film",
                                       description: Text("片库里加入这一年的电影或剧集后，会出现在这里。"))
            }
        }
        .navigationTitle(Text(verbatim: "\(year) 年"))
        .navigationSubtitle(Self.subtitle(movies: movies.count, series: series.count))
        .navigationBarTitleDisplayMode(.large)
    }

    /// 「12 部影片」；有剧集时「12 部电影、2 部剧集」
    static func subtitle(movies: Int, series: Int) -> String {
        if movies == 0 && series == 0 { return "" }
        if series == 0 { return "\(movies) 部影片" }
        if movies == 0 { return "\(series) 部剧集" }
        return "\(movies) 部电影、\(series) 部剧集"
    }

    /// 同一年，灰字里不再重复年份：电影写类型，剧集写类型与集数
    private func movieRows(_ list: [Video]) -> some View {
        ForEach(list) { v in
            LibraryMovieRow(video: v, subtitle: LibraryMovieRow.genres(model.meta(v)) ?? "电影", identifier: "year-movie")
        }
    }

    private func seriesRows(_ list: [Series]) -> some View {
        ForEach(list) { s in
            LibrarySeriesRow(series: s, showYear: false, identifier: "year-series")
        }
    }

    /// 节标题：Title 3 半粗（F15、F19），不全大写（F86）
    private func header(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
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
