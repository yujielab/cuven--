import SwiftUI

// MARK: - 电影详情
//
// 版式参考 Apple TV：剧照铺满（在 iPhone Duo 上延伸到侧边那一列底下）、字标、信息行、播放；
// 下面是简介（可展开）、版本、演员，再是「信息」「文件」两块（宽屏上排成几列）。
// 工具栏：系统返回 + 分享（标题和符号都给：iPhone Duo 上竖着放进侧边那一列，用符号；溢出菜单里用标题）。

struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hsc
    let video: Video
    @State private var full: Meta?
    @State private var selected: Video?
    @State private var showTitle = false
    @State private var related: [Video] = []
    @State private var trailers: [Trailer] = []
    @State private var trailerStart: TrailerStart?

    var body: some View {
        let meta = full ?? model.meta(video)
        let versions = model.versions(of: video)
        let file = selected ?? video
        let resume = model.playback.resumePosition(file.path)
        let title = model.title(video)
        let primaryTitle = resume.map { "继续播放 · \(Format.clock($0))" } ?? "播放"
        let restart: DetailAction? = resume == nil ? nil : DetailAction(title: "从头播放", symbol: "arrow.counterclockwise", action: {
            model.playback.finish(file.path)
            play(file, meta: meta)
        })

        GeometryReader { geo in
            let wide = hsc == .regular || geo.size.width > geo.size.height
            // 竖拿：头部几乎一整屏（Apple TV：画面在上、取色的底在下，下一块的标题刚好露出来）
            let heroH = wide ? min(geo.size.height * 0.92, 640) : max(520, geo.size.height * 0.95)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailHero(art: (wide ? meta?.backdrop : (meta?.posterClean ?? meta?.backdrop)) ?? meta?.backdrop ?? meta?.poster,
                               logo: meta?.logo, title: title, kicker: kicker(meta), meta: infoLine(meta),
                               badges: FileName.specs(file.name), overview: meta?.overview,
                               cast: meta?.cast?.prefix(3).map(\.name).joined(separator: "、"),
                               wide: wide, height: heroH) {
                        DetailActions(wide: wide, primary: primaryTitle, primaryID: "detail-play",
                                      play: { play(file, meta: meta) }, secondary: restart,
                                      watchKey: video.path, watchKind: .movie)
                    }

                    VStack(alignment: .leading, spacing: 28) {
                        if !trailers.isEmpty {
                            TrailerRow(trailers: trailers, stills: (meta?.stills ?? []).compactMap { $0.url ?? $0.thumb },
                                       backdrop: meta?.backdrop) { i in trailerStart = TrailerStart(index: i) }
                        }

                        if versions.count > 1 {
                            VStack(alignment: .leading, spacing: 10) {
                                DetailSectionTitle("版本")
                                ForEach(versions) { v in
                                    Button { selected = v; Haptics.selection() } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: v.path == file.path ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(v.path == file.path ? Theme.accent : Theme.tertiary)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(FileName.specs(v.name).joined(separator: " · ").isEmpty ? FileName.stem(v.name) : FileName.specs(v.name).joined(separator: " · "))
                                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                                Text(Format.size(v.size)).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                                            }
                                            Spacer()
                                        }
                                        .padding(12)
                                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if let cast = meta?.cast, !cast.isEmpty {
                            CastRail(people: cast, route: .cast(title: title, people: Array(cast.prefix(40)), director: meta?.director))
                        }

                        if !related.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                DetailSectionTitle("你可能还喜欢")
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 12) {
                                        ForEach(related) { v in
                                            ZoomLink(route: .movie(v), slot: "related") { PosterCard(video: v, width: 118) }
                                                .movieMenu(v)
                                        }
                                    }
                                    .scrollTargetLayout()
                                }
                                .scrollTargetBehavior(.viewAligned)
                                .scrollClipDisabled()
                            }
                        }

                        InfoSections(sections: [
                            ("信息", movieInfo(meta)),
                            ("文件", fileInfo(file)),
                        ])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 22)
                    .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .ignoresSafeArea(edges: .top)
            // 滚过头部大图，片名才出现在导航栏里（Apple TV 的做法）
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y > heroH - 150 } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { showTitle = v }
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .top) { StatusBarScrim() }
        .navigationTitle(showTitle ? title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let url = TMDBLink.url(meta, kind: "movie") {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url, subject: Text(title), message: Text(title)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .fullScreenCover(item: $trailerStart) { s in
            TrailerPlayerView(movieTitle: title, trailers: trailers, start: s.index)
        }
        .task {
            related = model.related(to: video)
            full = await model.fullMeta(for: video)
        }
        .task(id: video.path) { trailers = await model.trailers(for: video) }
    }

    /// 第一行：「电影 · 类型 · 类型」
    private func kicker(_ m: Meta?) -> String {
        (["电影"] + (m?.genres?.prefix(2).map { $0 } ?? [])).joined(separator: " · ")
    }

    /// 第二行：年份、片长、评分（后面跟着规格徽标）
    private func infoLine(_ m: Meta?) -> String {
        var parts: [String] = []
        if let y = model.year(video) { parts.append("\(y) 年") }
        let rt = Format.runtime(m?.runtime)
        if !rt.isEmpty { parts.append(rt) }
        if let r = m?.rating, r > 0 { parts.append(String(format: "★ %.1f", r)) }
        return parts.joined(separator: " · ")
    }

    private func movieInfo(_ m: Meta?) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let y = model.year(video) { rows.append(("发行年份", "\(y) 年")) }
        let rt = Format.runtime(m?.runtime)
        if !rt.isEmpty { rows.append(("片长", rt)) }
        if let g = m?.genres, !g.isEmpty { rows.append(("类型", g.joined(separator: "、"))) }
        if let r = m?.rating, r > 0 { rows.append(("评分", String(format: "★ %.1f（TMDB）", r))) }
        if let d = m?.director, !d.isEmpty { rows.append(("导演", d)) }
        let original = [m?.originalTitle, m?.en].compactMap { $0 }.first { !$0.isEmpty && $0 != model.title(video) }
        if let original { rows.append(("原名", original)) }
        return rows
    }

    private func fileInfo(_ f: Video) -> [(String, String)] {
        var rows: [(String, String)] = [("文件名", f.name)]
        let size = Format.size(f.size)
        if !size.isEmpty { rows.append(("大小", size)) }
        let specs = FileName.specs(f.name)
        if !specs.isEmpty { rows.append(("规格", specs.joined(separator: "、"))) }
        return rows
    }

    private func play(_ v: Video, meta: Meta?) {
        PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(video),
                                                  subtitle: model.year(video).map { String($0) },
                                                  artwork: meta?.backdrop ?? meta?.poster), model: model)
    }
}

/// 详情页头部（Apple TV 的样子）：画面铺满，往下化进一块从画面本身取的颜色（不是一律黑），内容一律靠左：
/// 字标；「电影 · 类型」；简介（两行，「更多」是叠在行尾的小胶囊）；年份 · 片长 · 评分 + 规格徽标；按钮。
/// 宽屏：内容在左边一栏，右下角「主演 …」。画面带 backgroundExtensionEffect（iPhone Duo 上延伸到侧边那一列底下），下拉时往上撑大
struct DetailHero<Actions: View>: View {
    let art: String?
    let logo: String?
    let title: String
    let kicker: String
    let meta: String
    let badges: [String]
    let overview: String?
    let cast: String?
    let wide: Bool
    let height: CGFloat
    @ViewBuilder var actions: () -> Actions
    @State private var tint: Color = Theme.bg

    var body: some View {
        ZStack(alignment: .bottom) {
            tint
            Color.clear
                .overlay { RemoteImage(url: TMDBImage.url(art, "w1280"), maxPixel: 1800) }
                .clipped()
                .backgroundExtensionEffect()
                .stretchy()
            LinearGradient(stops: [
                .init(color: .black.opacity(0.3), location: 0),
                .init(color: .clear, location: 0.16),
                .init(color: .clear, location: wide ? 0.34 : 0.36),
                .init(color: tint.opacity(0.9), location: wide ? 0.72 : 0.6),
                .init(color: tint, location: wide ? 0.94 : 0.78),
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)

            if wide {
                HStack(alignment: .bottom, spacing: 24) {
                    column
                        .frame(maxWidth: 520, alignment: .leading)
                    Spacer(minLength: 0)
                    if let cast, !cast.isEmpty {
                        (Text("主演 ").foregroundStyle(Theme.tertiary) + Text(cast).foregroundStyle(.white.opacity(0.85)))
                            .font(.system(size: 14, weight: .medium))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .frame(maxWidth: 280, alignment: .trailing)
                    }
                }
                .padding(.horizontal, Theme.gutter + 6)
                .padding(.bottom, 26)
            } else {
                column
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, 22)
            }
        }
        .frame(height: height)
        .task(id: art) {
            // 和画面同一个地址（磁盘缓存里已经有），只是解成一张小图来取色
            guard let u = TMDBImage.url(art, "w1280"), let c = await ArtTint.color(for: u) else { return }
            withAnimation(.easeOut(duration: 0.4)) { tint = c }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 10) {
            LogoImage(url: TMDBImage.url(logo, "w500"), height: wide ? 96 : 80, alignment: .leading, fallback: title)
                .frame(maxWidth: wide ? 440 : 280, alignment: .leading)
                .padding(.bottom, 4)
            if !kicker.isEmpty {
                Text(kicker)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            if let o = overview, !o.isEmpty {
                ExpandableText(text: o, lines: 2, fade: tint)
            }
            if !meta.isEmpty || !badges.isEmpty {
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    if !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    ForEach(badges.prefix(6), id: \.self) { SpecBadge(text: $0) }
                }
            }
            actions()
                .padding(.top, 8)
        }
    }
}

/// 详情页的次要按钮
struct DetailAction {
    let title: String
    let symbol: String
    let action: () -> Void
}

/// 详情页的按钮（Apple TV）：一颗宽的白色主按钮；竖拿时下面一行是次要按钮（有的话）和「+」，宽屏上排成一行
struct DetailActions: View {
    let wide: Bool
    let primary: String
    let primaryID: String
    var disabled = false
    let play: () -> Void
    var secondary: DetailAction? = nil
    let watchKey: String
    let watchKind: WatchItem.Kind

    var body: some View {
        if wide {
            HStack(spacing: 12) {
                primaryButton
                    .frame(minWidth: 200)
                    .fixedSize()
                if let secondary { secondaryButton(secondary) }
                WatchlistButton(key: watchKey, kind: watchKind)
            }
        } else if let secondary {
            VStack(alignment: .leading, spacing: 12) {
                primaryButton
                    .frame(width: 236)
                HStack(spacing: 12) {
                    secondaryButton(secondary)
                    WatchlistButton(key: watchKey, kind: watchKind)
                }
            }
        } else {
            // 没有次要按钮时「+」就跟在主按钮右边，不单独占一行
            HStack(spacing: 12) {
                primaryButton
                    .frame(width: 236)
                WatchlistButton(key: watchKey, kind: watchKind)
            }
        }
    }

    private var primaryButton: some View {
        Button(action: play) {
            PrimaryLabel(title: primary, systemImage: "play.fill")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(disabled)
        .accessibilityIdentifier(primaryID)
    }

    private func secondaryButton(_ a: DetailAction) -> some View {
        Button(action: a.action) {
            Label(a.title, systemImage: a.symbol)
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 8)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

/// 从画面取色：画面最下面一截的平均色（Apple TV 详情页：画面往下化进同一种颜色，不是一律黑）。
/// ceiling 是亮度上限：详情页的底色压得暗（白字始终看得清），名次卡这类整块底色可以亮一些。一张图只算一次
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
struct TrailerStart: Identifiable {
    let index: Int
    var id: Int { index }
}

/// TMDB 的公开页面（分享用：分享的是片子的公开资料，不是片库里的文件）
enum TMDBLink {
    static func url(_ m: Meta?, kind: String) -> URL? {
        guard let id = m?.id else { return nil }
        return URL(string: "https://www.themoviedb.org/\(kind)/\(id)")
    }
}

struct DetailSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
    }
}

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

/// 「信息」「文件」这类分区：小标题在上、值在下（Apple TV 的样子）；宽屏上几块并排成列
struct InfoSections: View {
    @Environment(\.horizontalSizeClass) private var hsc
    let sections: [(String, [(String, String)])]

    var body: some View {
        let shown = sections.filter { !$0.1.isEmpty }
        if hsc == .regular {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 28, alignment: .top)], alignment: .leading, spacing: 24) {
                ForEach(shown.indices, id: \.self) { i in block(shown[i]) }
            }
        } else {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(shown.indices, id: \.self) { i in block(shown[i]) }
            }
        }
    }

    private func block(_ s: (String, [(String, String)])) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailSectionTitle(s.0)
            ForEach(s.1.indices, id: \.self) { j in
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.1[j].0).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(s.1[j].1).font(.system(size: 15)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 演员与职员（Apple TV 的 Cast & Crew）

/// 详情页里的一排演员：标题「演员与职员 ›」点进整页名单；下面横排圆头像
struct CastRail: View {
    let people: [CastMember]
    let route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: route) {
                HStack(spacing: 6) {
                    Text("演员与职员").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(Theme.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .accessibilityIdentifier("cast-link")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(people.prefix(20).enumerated()), id: \.offset) { _, c in
                        VStack(spacing: 6) {
                            PersonPhoto(name: c.name, url: c.profileURL, size: 72)
                            Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            if let ch = c.character, !ch.isEmpty {
                                Text(ch).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                            }
                        }
                        .frame(width: 84)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }
}

/// 圆头像；没有照片时是名字的第一个字
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

// MARK: - 预告片（详情页里的一排）

/// 「预告片」：横排的 16:9 卡（画面用这部片的剧照，正中一颗玻璃播放钮），点了全屏放，左右滑换下一段
struct TrailerRow: View {
    let trailers: [Trailer]
    let stills: [String]
    let backdrop: String?
    let onPlay: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionTitle("预告片")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(trailers.enumerated()), id: \.element.id) { i, t in
                        Button { onPlay(i) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                ZStack {
                                    Color.clear
                                        .overlay { RemoteImage(url: TMDBImage.url(image(i), "w780"), maxPixel: 760) }
                                        .clipped()
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 50, height: 50)
                                        .glassEffect(.regular, in: Circle())
                                }
                                .frame(width: 256, height: 144)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                                Text(t.title ?? "预告片")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .frame(width: 256, alignment: .leading)
                            }
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityIdentifier("trailer-card")
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollClipDisabled()
        }
    }

    private func image(_ i: Int) -> String? {
        stills.isEmpty ? backdrop : stills[i % stills.count]
    }
}

// MARK: - 剧集详情
//
// 同电影：剧照 + 字标 + 播放（接着上次那一集）；下面是简介、这一季的分集（横排的大卡：剧照、第几集、集名、简介、时长、进度），
// 再是「信息」。

struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hsc
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let series: Series
    /// 季切换：同一部剧的别的季（同一个 TMDB 编号，没有就同名）；没切过就是传进来的那一季
    @State private var picked: Series?
    @State private var files: [EpisodeFile] = []
    @State private var info: [Int: SeasonEpisode] = [:]
    @State private var loading = true
    @State private var failed: String?
    @State private var showTitle = false

    private var current: Series { picked ?? series }

    /// 同一部剧的所有季，按季号排
    private var seasons: [Series] {
        let key = current.tmdbId ?? model.seriesMetas[current.path]?.id
        let same = model.series.filter { s in
            if let key { return (s.tmdbId ?? model.seriesMetas[s.path]?.id) == key }
            return s.name == current.name
        }
        let list = same.contains(where: { $0.path == current.path }) ? same : same + [current]
        return list.sorted { ($0.season ?? 0) < ($1.season ?? 0) }
    }

    var body: some View {
        let meta = model.seriesMetas[current.path]
        let last = model.playback.lastEpisode(of: current.path)
        let title = meta?.title ?? current.name
        let calm = reduceMotion

        GeometryReader { geo in
            let wide = hsc == .regular || geo.size.width > geo.size.height
            let heroH = wide ? min(geo.size.height * 0.92, 640) : max(520, geo.size.height * 0.95)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailHero(art: (wide ? meta?.backdrop : (meta?.posterClean ?? meta?.backdrop)) ?? meta?.backdrop ?? meta?.poster,
                               logo: meta?.logo, title: title, kicker: kicker(meta), meta: infoLine(meta),
                               badges: (current.tags ?? []).filter { !$0.isEmpty }, overview: meta?.overview,
                               cast: meta?.cast?.prefix(3).map(\.name).joined(separator: "、"),
                               wide: wide, height: heroH) {
                        DetailActions(wide: wide, primary: resumeLabel(last), primaryID: "series-play",
                                      disabled: files.isEmpty, play: { playFirstOrResume(last) },
                                      watchKey: current.path, watchKind: .series)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        seasonHeader
                            .padding(.horizontal, Theme.gutter)
                        if loading && files.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                        } else if let failed, files.isEmpty {
                            Text(failed).font(.system(size: 14)).foregroundStyle(Theme.secondary).padding(.horizontal, Theme.gutter)
                        }
                        // Apple TV：一张卡约六成宽，右边露出下一张
                        let cardW = min(hsc == .regular ? 300 : geo.size.width * 0.62, 320)
                        let upNext = last.flatMap { l in files.firstIndex { $0.path == l.path } } ?? 0
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                                    let progress = model.playback.entry(f.path)?.fraction
                                    Button { play(index: i) } label: {
                                        EpisodeCard(file: f, info: f.ep.flatMap { info[$0] }, fallbackArt: meta?.backdrop,
                                                    progress: progress, width: cardW, upNext: i == upNext)
                                    }
                                    .buttonStyle(PressableStyle())
                                    .accessibilityIdentifier("episode-card")
                                    // 「…」叠在卡片右下角（不嵌在卡片的按钮里）
                                    .overlay(alignment: .bottomTrailing) {
                                        Menu {
                                            Button("播放", systemImage: "play.fill") { play(index: i) }
                                            if (progress ?? 0) > 0.01 {
                                                Button("从头播放", systemImage: "arrow.counterclockwise") {
                                                    model.playback.finish(f.path)
                                                    play(index: i)
                                                }
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis")
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundStyle(.white.opacity(0.85))
                                                .frame(width: 44, height: 40)
                                                .contentShape(Rectangle())
                                        }
                                        .accessibilityLabel("更多操作")
                                        .padding(.trailing, 4)
                                        .padding(.bottom, 3)
                                    }
                                    .scrollTransition(.interactive, axis: .horizontal) { c, phase in
                                        c.scaleEffect(phase.isIdentity || calm ? 1 : 0.95).opacity(phase.isIdentity ? 1 : 0.8)
                                    }
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, Theme.gutter)
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollClipDisabled()
                    }
                    .padding(.top, 22)

                    InfoSections(sections: [("信息", seriesInfo(meta))])
                        .padding(.horizontal, Theme.gutter)
                        .padding(.top, 30)
                        .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y > heroH - 150 } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { showTitle = v }
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .top) { StatusBarScrim() }
        .navigationTitle(showTitle ? title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let url = TMDBLink.url(meta, kind: "tv") {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url, subject: Text(title), message: Text(title)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: current.path) { await load() }
    }

    /// 「第 1 季 ⌃⌄」：同一部剧不止一季时，点开是季的菜单（Apple TV 的季切换）
    @ViewBuilder private var seasonHeader: some View {
        let all = seasons
        if all.count > 1 {
            Menu {
                Picker("季", selection: Binding(get: { current.path }, set: { p in
                    guard let s = all.first(where: { $0.path == p }), s.path != current.path else { return }
                    Haptics.selection()
                    withAnimation(.snappy) { picked = s }
                })) {
                    ForEach(all, id: \.path) { s in Text(s.seasonLabel ?? s.season.map { "第 \($0) 季" } ?? s.name).tag(s.path) }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(current.seasonLabel ?? "剧集").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("season-menu")
        } else {
            DetailSectionTitle(current.seasonLabel ?? "剧集")
        }
    }

    /// 第一行：「剧集 · 类型 · 类型」
    private func kicker(_ m: Meta?) -> String {
        (["剧集"] + (m?.genres?.prefix(2).map { $0 } ?? [])).joined(separator: " · ")
    }

    /// 第二行：年份、第几季、集数、评分（后面跟着规格徽标）
    private func infoLine(_ m: Meta?) -> String {
        var parts = [current.year.map { "\($0) 年" }, current.seasonLabel, current.countLabel.isEmpty ? nil : current.countLabel]
            .compactMap { $0 }.filter { !$0.isEmpty }
        if let r = m?.rating, r > 0 { parts.append(String(format: "★ %.1f", r)) }
        return parts.joined(separator: " · ")
    }

    private func seriesInfo(_ m: Meta?) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let y = current.year, !y.isEmpty { rows.append(("年份", "\(y) 年")) }
        if let s = current.seasonLabel, !s.isEmpty { rows.append(("季", s)) }
        if !current.countLabel.isEmpty { rows.append(("集数", current.countLabel)) }
        if let g = m?.genres, !g.isEmpty { rows.append(("类型", g.joined(separator: "、"))) }
        if let r = m?.rating, r > 0 { rows.append(("评分", String(format: "★ %.1f（TMDB）", r))) }
        if let en = current.en ?? m?.en, !en.isEmpty, en != (m?.title ?? current.name) { rows.append(("原名", en)) }
        return rows
    }

    private func load() async {
        files = []
        info = [:]
        failed = nil
        if DemoData.enabled {
            files = DemoData.episodes(current)
            info = DemoData.season(current)
            loading = false
            return
        }
        loading = true
        await model.ensureSeriesMeta(current)
        do {
            let list = try await APIClient.shared.episodes(seriesPath: current.path)
            files = list.sorted { ($0.ep ?? Int.max, $0.name) < ($1.ep ?? Int.max, $1.name) }
        } catch {
            failed = "分集清单没取到：\(error.localizedDescription)"
        }
        loading = false
        if let id = current.tmdbId ?? model.seriesMetas[current.path]?.id, let s = current.season {
            if let eps = try? await APIClient.shared.season(tmdbId: id, season: s) {
                var d: [Int: SeasonEpisode] = [:]
                for e in eps { if let n = e.ep { d[n] = e } }
                info = d
            }
        }
    }

    private func resumeLabel(_ last: WatchEntry?) -> String {
        if let last, let ep = last.episode { return "继续观看 · 第 \(ep) 集" }
        return "播放第 1 集"
    }

    private func playFirstOrResume(_ last: WatchEntry?) {
        if let last, let i = files.firstIndex(where: { $0.path == last.path }) { play(index: i) } else { play(index: 0) }
    }

    private func request(_ f: EpisodeFile) -> PlayRequest {
        let meta = model.seriesMetas[current.path]
        let name = f.ep.flatMap { info[$0]?.name }
        let sub = [f.ep.map { "第 \($0) 集" }, name].compactMap { $0 }.joined(separator: " · ")
        return PlayRequest(path: f.path, name: f.name, title: meta?.title ?? current.name, subtitle: sub,
                           artwork: f.ep.flatMap { info[$0]?.still } ?? meta?.backdrop,
                           seriesPath: current.path, episode: f.ep)
    }

    private func play(index: Int) {
        guard files.indices.contains(index) else { return }
        var req = request(files[index])
        req.queue = files[(index + 1)...].map { request($0) }
        PlayerCoordinator.shared.play(req, model: model)
    }
}

/// 分集卡（Apple TV）：上半截是剧照，往下化进同一张图的毛玻璃（越往下越糊、略压暗），
/// 上面写第几集、集名、三行简介；最下面一行：「▶」（按「播放」会从这一集开始的那张才有）、进度、时长，右下角留给叠上来的「…」
struct EpisodeCard: View {
    let file: EpisodeFile
    let info: SeasonEpisode?
    let fallbackArt: String?
    let progress: Double?
    let width: CGFloat
    var upNext = false

    var body: some View {
        let height = width * 0.99
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay { RemoteImage(url: TMDBImage.url(info?.still ?? fallbackArt, "w780"), maxPixel: width * 3) }
                .clipped()
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: .black, location: 0.58),
                ], startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
            LinearGradient(stops: [
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.3), location: 0.58),
                .init(color: .black.opacity(0.5), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.ep.map { "第 \($0) 集" } ?? FileName.stem(file.name))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                if let name = info?.name, !name.isEmpty {
                    Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                if let o = info?.overview, !o.isEmpty {
                    Text(o).font(.system(size: 14)).foregroundStyle(.white.opacity(0.72)).lineLimit(3)
                }
                HStack(spacing: 7) {
                    if upNext {
                        Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                    }
                    if let p = progress, p > 0.01 {
                        ProgressCapsule(fraction: p).frame(width: 56)
                    }
                    let rt = Format.runtime(info?.runtime)
                    if !rt.isEmpty { Text(rt).font(.system(size: 14, weight: .semibold)) }
                    Spacer(minLength: 44)
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(height: 20)
                .padding(.top, 6)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 13)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .contentShape(Rectangle())
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
