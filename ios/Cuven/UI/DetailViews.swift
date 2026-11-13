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

    var body: some View {
        let meta = full ?? model.meta(video)
        let versions = model.versions(of: video)
        let file = selected ?? video
        let resume = model.playback.resumePosition(file.path)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(backdrop: meta?.backdrop ?? meta?.posterClean ?? meta?.poster,
                             logo: meta?.logo, title: model.title(video))

                VStack(alignment: .leading, spacing: 22) {
                    Text(infoLine(meta))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    VStack(spacing: 10) {
                        Button { play(file, meta: meta) } label: {
                            PrimaryLabel(title: resume.map { "继续播放 · \(Format.clock($0))" } ?? "播放", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("detail-play")
                        if resume != nil {
                            Button {
                                model.playback.finish(file.path)
                                play(file, meta: meta)
                            } label: {
                                Label("从头播放", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                        }
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)

                    let specs = FileName.specs(file.name)
                    if !specs.isEmpty {
                        FlowLayout { ForEach(specs, id: \.self) { SpecBadge(text: $0) } }
                    }

                    if let o = meta?.overview, !o.isEmpty {
                        ExpandableText(text: o)
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
                        VStack(alignment: .leading, spacing: 12) {
                            DetailSectionTitle("演员")
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(Array(cast.prefix(20).enumerated()), id: \.offset) { _, c in
                                        VStack(spacing: 6) {
                                            RemoteImage(url: c.profileURL, maxPixel: 240)
                                                .frame(width: 72, height: 72)
                                                .clipShape(Circle())
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

                    InfoSections(sections: [
                        ("信息", movieInfo(meta)),
                        ("文件", fileInfo(file)),
                    ])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .top) { StatusBarScrim() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let url = TMDBLink.url(meta, kind: "movie") {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url, subject: Text(model.title(video)), message: Text(model.title(video))) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { full = await model.fullMeta(for: video) }
    }

    private func infoLine(_ m: Meta?) -> String {
        var parts: [String] = []
        if let y = model.year(video) { parts.append(String(y)) }
        if let g = m?.genres, !g.isEmpty { parts.append(g.prefix(3).joined(separator: " · ")) }
        let rt = Format.runtime(m?.runtime)
        if !rt.isEmpty { parts.append(rt) }
        if let r = m?.rating, r > 0 { parts.append(String(format: "★ %.1f", r)) }
        return parts.joined(separator: "  ·  ")
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

/// 详情页顶上：剧照铺满、往下压暗，字标压在底部（深色字标自动反白）。
/// 剧照带 backgroundExtensionEffect：iPhone Duo 上系统栏竖在侧边时，画面延伸到那一列底下（镜像 + 模糊）
struct DetailHeader: View {
    let backdrop: String?
    let logo: String?
    let title: String

    var body: some View {
        ZStack(alignment: .bottom) {
            // 同首页大图：图放在 overlay 里裁切，16:9 的剧照铺满 460 高时不会把整列撑宽
            Color.clear
                .frame(height: 460)
                .overlay { RemoteImage(url: TMDBImage.url(backdrop, "w1280"), maxPixel: 1800) }
                .clipped()
                .backgroundExtensionEffect()
            LinearGradient(stops: [
                .init(color: .black.opacity(0.45), location: 0),
                .init(color: .clear, location: 0.22),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.75), location: 0.8),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            LogoImage(url: TMDBImage.url(logo, "w500"), height: 80, fallback: title)
                .frame(maxWidth: 320)
                .padding(.horizontal, 30)
                .padding(.bottom, 18)
        }
        .frame(height: 460)
    }
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

/// 简介：默认 4 行，长的带「更多」
struct ExpandableText: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.86))
                .lineSpacing(4)
                .lineLimit(expanded ? nil : 4)
            if !expanded && text.count > 110 {
                Button("更多") { withAnimation(.snappy) { expanded = true } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
            }
        }
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

// MARK: - 剧集详情
//
// 同电影：剧照 + 字标 + 播放（接着上次那一集）；下面是简介、这一季的分集（横排的大卡：剧照、第几集、集名、简介、时长、进度），
// 再是「信息」。

struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hsc
    let series: Series
    @State private var files: [EpisodeFile] = []
    @State private var info: [Int: SeasonEpisode] = [:]
    @State private var loading = true
    @State private var failed: String?

    var body: some View {
        let meta = model.seriesMetas[series.path]
        let last = model.playback.lastEpisode(of: series.path)

        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DetailHeader(backdrop: meta?.backdrop ?? meta?.posterClean ?? meta?.poster, logo: meta?.logo, title: meta?.title ?? series.name)

                    VStack(alignment: .leading, spacing: 22) {
                        Text([series.year, series.seasonLabel, series.countLabel, meta?.genres?.prefix(2).joined(separator: " · ")]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)

                        if !files.isEmpty {
                            Button { playFirstOrResume(last) } label: {
                                PrimaryLabel(title: resumeLabel(last), systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .frame(maxWidth: 520)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("series-play")
                        }

                        let specs = (series.tags ?? []).filter { !$0.isEmpty }
                        if !specs.isEmpty {
                            FlowLayout { ForEach(specs, id: \.self) { SpecBadge(text: $0) } }
                        }

                        if let o = meta?.overview, !o.isEmpty {
                            ExpandableText(text: o)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 14) {
                        DetailSectionTitle(series.seasonLabel ?? "剧集")
                            .padding(.horizontal, Theme.gutter)
                        if loading && files.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                        } else if let failed, files.isEmpty {
                            Text(failed).font(.system(size: 14)).foregroundStyle(Theme.secondary).padding(.horizontal, Theme.gutter)
                        }
                        let cardW = min(hsc == .regular ? 340 : geo.size.width * 0.8, 380)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                                    Button { play(index: i) } label: {
                                        EpisodeCard(file: f, info: f.ep.flatMap { info[$0] }, fallbackArt: meta?.backdrop,
                                                    progress: model.playback.entry(f.path)?.fraction, width: cardW)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("episode-card")
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, Theme.gutter)
                        }
                        .scrollTargetBehavior(.viewAligned)
                    }
                    .padding(.top, 28)

                    InfoSections(sections: [("信息", seriesInfo(meta))])
                        .padding(.horizontal, Theme.gutter)
                        .padding(.top, 30)
                        .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .ignoresSafeArea(edges: .top)
        }
        .background(Theme.bg)
        .overlay(alignment: .top) { StatusBarScrim() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let url = TMDBLink.url(meta, kind: "tv") {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url, subject: Text(meta?.title ?? series.name), message: Text(meta?.title ?? series.name)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await load() }
    }

    private func seriesInfo(_ m: Meta?) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let y = series.year, !y.isEmpty { rows.append(("年份", "\(y) 年")) }
        if let s = series.seasonLabel, !s.isEmpty { rows.append(("季", s)) }
        if !series.countLabel.isEmpty { rows.append(("集数", series.countLabel)) }
        if let g = m?.genres, !g.isEmpty { rows.append(("类型", g.joined(separator: "、"))) }
        if let r = m?.rating, r > 0 { rows.append(("评分", String(format: "★ %.1f（TMDB）", r))) }
        if let en = series.en ?? m?.en, !en.isEmpty, en != (m?.title ?? series.name) { rows.append(("原名", en)) }
        return rows
    }

    private func load() async {
        if DemoData.enabled {
            files = DemoData.episodes(series)
            info = DemoData.season(series)
            loading = false
            return
        }
        loading = true
        await model.ensureSeriesMeta(series)
        do {
            let list = try await APIClient.shared.episodes(seriesPath: series.path)
            files = list.sorted { ($0.ep ?? Int.max, $0.name) < ($1.ep ?? Int.max, $1.name) }
        } catch {
            failed = "分集清单没取到：\(error.localizedDescription)"
        }
        loading = false
        if let id = series.tmdbId ?? model.seriesMetas[series.path]?.id, let s = series.season {
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
        let meta = model.seriesMetas[series.path]
        let name = f.ep.flatMap { info[$0]?.name }
        let sub = [f.ep.map { "第 \($0) 集" }, name].compactMap { $0 }.joined(separator: " · ")
        return PlayRequest(path: f.path, name: f.name, title: meta?.title ?? series.name, subtitle: sub,
                           artwork: f.ep.flatMap { info[$0]?.still } ?? meta?.backdrop,
                           seriesPath: series.path, episode: f.ep)
    }

    private func play(index: Int) {
        guard files.indices.contains(index) else { return }
        var req = request(files[index])
        req.queue = files[(index + 1)...].map { request($0) }
        PlayerCoordinator.shared.play(req, model: model)
    }
}

/// 分集大卡：剧照铺满整张卡、下半截压暗，上面写第几集、集名、简介、时长；看过的带进度条
struct EpisodeCard: View {
    let file: EpisodeFile
    let info: SeasonEpisode?
    let fallbackArt: String?
    let progress: Double?
    let width: CGFloat

    var body: some View {
        let height = width * 0.92
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay { RemoteImage(url: TMDBImage.url(info?.still ?? fallbackArt, "w780"), maxPixel: width * 3) }
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.3),
                .init(color: .black.opacity(0.7), location: 0.6),
                .init(color: .black.opacity(0.92), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.ep.map { "第 \($0) 集" } ?? FileName.stem(file.name))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                if let name = info?.name, !name.isEmpty {
                    Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                if let o = info?.overview, !o.isEmpty {
                    Text(o).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(3)
                }
                HStack(spacing: 8) {
                    let rt = Format.runtime(info?.runtime)
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                    if !rt.isEmpty { Text(rt).font(.system(size: 13, weight: .semibold)) }
                    if let p = progress, p > 0.01 {
                        ProgressCapsule(fraction: p).frame(maxWidth: 80)
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, 4)
            }
            .padding(14)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
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
                                NavigationLink(value: Route.series(s)) { SeriesPosterTile(series: s) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "电影", count: movies.count)
                    PosterGrid {
                        ForEach(movies) { v in
                            NavigationLink(value: Route.movie(v)) { MoviePosterTile(video: v) }.buttonStyle(.plain)
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
