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

// MARK: - 演员与职员（Apple TV 的 Cast & Crew）

struct PersonPhoto: View {
    let name: String
    let url: URL?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Theme.surface2)
            Text(String(name.prefix(1)))
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            if url != nil {
                RemoteImage(url: url, maxPixel: size * 3, placeholder: .clear)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// 整页名单：导演在最前，然后是演员（头像、名字、角色），发丝线从文字那一列起头
struct CastView: View {
    let title: String
    let people: [CastMember]
    let director: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let d = director, !d.isEmpty {
                    PersonRow(name: d, role: "导演", url: nil)
                }
                ForEach(Array(people.enumerated()), id: \.offset) { _, p in
                    PersonRow(name: p.name, role: p.character ?? "", url: p.profileURL)
                }
            }
            .padding(.vertical, 6)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .navigationTitle("演员与职员")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct PersonRow: View {
    let name: String
    let role: String
    let url: URL?

    var body: some View {
        HStack(spacing: 16) {
            PersonPhoto(name: name, url: url, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 17)).foregroundStyle(.white).lineLimit(1)
                if !role.isEmpty {
                    Text(role).font(.system(size: 15)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, Theme.gutter + 64 + 16)
        }
    }
}

// MARK: - 某一年：电影与剧集

struct YearView: View {
    @Environment(AppModel.self) private var model
    let year: Int

    var body: some View {
        let movies = model.movies(inYear: year)
        let series = model.seriesInYear(year)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !series.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "剧集", count: series.count)
                        PosterGrid {
                            ForEach(series) { s in
                                ZoomLink(route: .series(s), slot: "year") { SeriesPosterTile(series: s) }.seriesMenu(s)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "电影", count: movies.count)
                    PosterGrid {
                        ForEach(movies) { v in
                            ZoomLink(route: .movie(v), slot: "year") { MoviePosterTile(video: v) }.movieMenu(v)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.bg)
        .navigationTitle(String(year))
        .navigationBarTitleDisplayMode(.large)
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
