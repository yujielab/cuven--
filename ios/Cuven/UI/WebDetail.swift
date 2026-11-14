import SwiftUI
import UIKit

// MARK: - 详情页（电影 / 剧集同一页）：按 Apple HIG 收拾成 Apple TV 的样子（规则编号见 docs/ios-design.md）
//
// 头部：全幅画面（竖拿用 Apple TV 的竖版全屏图，横拿 16:9：S15），往下渐暗（F34），字压在左下（F1、F2）：
// 字标（没有字标就是 Large Title 的片名）→ 一行信息「类型 · 年份 · 片长 · ★评分」（F18）→
// 一颗白色「播放」+ 一颗「…」系统菜单（从头播放、复制直链、分享：S17、C11、C15、C35、C45）。
// 下面只靠留白分区（F3、F12）：简介（三行后「更多」：F21、F24）→ 分集（剧集）→ 预告片（有才有）→
// 演员（圆形照片：T21）→ 信息（左灰右白的几行）。
// 不放玻璃卡、印章、法务行、剧照「第 N 幕」、分隔线（F38、F80、F84）；导航栏不垫底、不压自制的渐暗，
// 系统的滚动边缘效果就够（C17、C27）；头部滚走了片名才出现在导航栏里（C12）。
// 展开的 Duo 是同一套设计长大：边距、卡宽、字号都从 DSMetrics 来（S1、D2、I11）。

// MARK: - 电影

struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    let video: Video
    @State private var full: Meta?
    /// Apple TV 上对上的那一部：有就用它的无字背景、竖版全屏图、字标和预告片（对不上就是 TMDB 的）
    @State private var atv: AtvLookup?
    @State private var trailers: [Trailer] = []

    var body: some View {
        let meta = full ?? model.meta(video)
        // C89：「播放」自己接着上次的地方放，不问；从头看放进「…」菜单
        let resume = model.playback.resumePosition(video.path) != nil

        DetailScaffold(
            title: model.title(video),
            // 画面：这一部的 Apple TV 查询（顺带预告片）先到就用它的；还没回来先用全片库的 Apple TV 素材，最后才是 TMDB
            // （详情页的 TMDB 是全量结果，字标只有它有：放在最后兜底）
            wideArt: atv?.background ?? model.backgroundArtString(video) ?? meta?.backdrop ?? meta?.poster,
            tallArt: atv?.imageTall ?? model.tallArtString(video),
            logo: atv?.logo ?? model.logoArtString(video) ?? meta?.logo,
            metaLine: metaLine(meta),
            playTitle: resume ? "继续播放" : "播放",
            playID: "detail-play",
            onPlay: { play(meta) },
            onRestart: restartAction(meta),
            file: (path: video.path, name: video.name),
            shareURL: DetailText.tmdbPage(kind: "movie", id: meta?.id),
            overview: meta?.overview,
            cast: meta?.cast ?? [],
            trailers: trailers,
            trailerArt: trailerArt(meta),
            infoRows: infoRows(meta)
        ) { _ in
            EmptyView()
        }
        .task { full = await model.fullMeta(for: video) }
        .task(id: video.path) {
            atv = await model.atv(for: video)
            // 和资料库展映同一份：Apple TV 上的公开预告（订阅才看得了的不要）；atv 已经记在内存里，不再走网络
            trailers = await model.trailers(for: video)
        }
    }

    /// 头部那一行：「科幻 · 2026 · 1 小时 32 分钟 · ★ 7.5」（F84：短、平实）
    private func metaLine(_ m: Meta?) -> String {
        DetailText.line([
            m?.genres?.first,
            model.year(video).map { String($0) },
            Format.runtime(m?.runtime),
            DetailText.rating(m?.rating),
        ])
    }

    /// 「信息」：类型、年份、片长、评分、导演、格式；没有的项不写
    private func infoRows(_ m: Meta?) -> [DetailInfoRow] {
        [
            DetailInfoRow(label: "类型", value: (m?.genres ?? []).joined(separator: "、")),
            DetailInfoRow(label: "年份", value: model.year(video).map { String($0) } ?? ""),
            DetailInfoRow(label: "片长", value: Format.runtime(m?.runtime)),
            DetailInfoRow(label: "评分", value: DetailText.rating(m?.rating) ?? ""),
            DetailInfoRow(label: "导演", value: m?.director ?? ""),
            DetailInfoRow(label: "格式", value: WebFormat.line(name: video.name)),
        ].filter { !$0.value.isEmpty && $0.value != "—" }
    }

    /// 预告片卡的画面：剧照轮着用；没有剧照就是背景图
    private func trailerArt(_ m: Meta?) -> [String] {
        let stills = (m?.stills ?? []).compactMap { $0.url ?? $0.thumb }.filter { !$0.isEmpty }
        if !stills.isEmpty { return stills }
        return [atv?.background ?? model.backgroundArtString(video)].compactMap { $0 }
    }

    /// 「从头播放」：只在有进度时出现。先清掉这部的进度，播放器就从头开始
    private func restartAction(_ meta: Meta?) -> (() -> Void)? {
        guard model.playback.resumePosition(video.path) != nil else { return nil }
        let path = video.path
        return {
            model.playback.finish(path)
            play(meta)
        }
    }

    private func play(_ meta: Meta?) {
        PlayerCoordinator.shared.play(PlayRequest(path: video.path, name: video.name, title: model.title(video),
                                                  subtitle: model.year(video).map { String($0) },
                                                  artwork: atv?.background ?? model.backgroundArtString(video) ?? meta?.poster), model: model)
    }
}

// MARK: - 剧集（同一个页面：按钮写「播放第 1 集 / 继续看第 n 集」，多一段分集）

struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    let series: Series
    /// 季切换：分集标题右边的季菜单（C45）
    @State private var picked: Series?
    @State private var files: [EpisodeFile] = []
    @State private var info: [Int: SeasonEpisode] = [:]
    @State private var loading = true
    @State private var failed: String?
    @State private var atv: AtvLookup?

    private var current: Series { picked ?? series }

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
        let next = nextEpisode()
        let fallbackArt = atv?.background ?? meta?.backdrop

        DetailScaffold(
            title: meta?.title ?? current.name,
            wideArt: atv?.background ?? meta?.backdrop ?? meta?.poster,
            tallArt: atv?.imageTall,
            logo: atv?.logo ?? meta?.logo,
            metaLine: metaLine(meta),
            playTitle: playLabel(next),
            playID: "series-play",
            playDisabled: next == nil,
            onPlay: { if let next, let i = files.firstIndex(of: next.file) { play(index: i) } },
            onRestart: restartAction(next),
            file: next.map { (path: $0.file.path, name: $0.file.name) },
            shareURL: DetailText.tmdbPage(kind: "tv", id: current.tmdbId ?? meta?.id),
            overview: meta?.overview,
            cast: meta?.cast ?? [],
            trailers: DetailText.playable(atv?.trailers),
            trailerArt: trailerArt(meta),
            infoRows: infoRows(meta)
        ) { m in
            episodes(m, fallbackArt: fallbackArt)
        }
        .task(id: current.path) { await load() }
        .task(id: current.path) {
            atv = nil
            await model.ensureSeriesMeta(current)
            atv = await model.atv(for: current)
        }
    }

    // MARK: 分集

    /// 「剧集」+ 右边的季菜单；下面一排 16:9 的分集卡（T23：标准的横排；S8：停在左侧基准线上）
    private func episodes(_ m: DSMetrics, fallbackArt: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("剧集")
                    .font(.dsShelfTitle(wide: m.wide))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if seasons.count > 1 { seasonMenu }
            }
            .padding(.horizontal, m.margin)

            if files.isEmpty {
                if loading {
                    // C66：先放占位卡，不留白屏；卡和真卡一样大，换上来时排不跳（C23）
                    DSShelf(metrics: m) {
                        ForEach(0..<3, id: \.self) { i in
                            DSWideLockup(art: nil, title: "第 \(i + 1) 集", subtitle: "45 分钟", metrics: m)
                        }
                    }
                    .redacted(reason: .placeholder)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                } else {
                    // F87：说清楚怎么了，不怪人
                    Text(failed ?? "暂无可播放文件")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, m.margin)
                        .padding(.vertical, 8)
                }
            } else {
                DSShelf(metrics: m) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                        episodeCard(f, index: i, metrics: m, fallbackArt: fallbackArt)
                    }
                }
            }
        }
    }

    /// 一集：剧照 + 「第 1 集 · 集名」+ 片长（看完的写「已看」：F36 状态不只靠颜色）；看到一半的带进度条。
    /// 点一下就放这一集（C88）；长按出菜单，预览里是这一集的整段简介（C21）
    private func episodeCard(_ f: EpisodeFile, index i: Int, metrics m: DSMetrics, fallbackArt: String?) -> some View {
        let ep = f.ep.flatMap { info[$0] }
        let fraction = model.playback.entry(f.path)?.fraction ?? 0
        let done = fraction >= 0.9
        let art = TMDBImage.url(ep?.still ?? fallbackArt, "w780")
        let runtime = Format.runtime(ep?.runtime)
        return Button { play(index: i) } label: {
            DSWideLockup(art: art, title: Self.episodeTitle(f, ep),
                         subtitle: DetailText.line([runtime, done ? "已看" : nil]),
                         progress: done ? nil : fraction, metrics: m)
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("episode-card")
        .contextMenu {
            Button(done ? "重看这一集" : "播放这一集", systemImage: "play.fill") { play(index: i) }
        } preview: {
            DetailEpisodePreview(art: art, kicker: DetailText.line([Self.badge(f), runtime]),
                                 title: Self.episodeName(ep) ?? Self.badge(f), overview: ep?.overview)
        }
    }

    /// 季：分区标题右边一个系统菜单（C45：用来挑一个值的控件是菜单；C31：当前那一季打勾）
    private var seasonMenu: some View {
        Menu {
            Picker("季", selection: Binding(get: { current.path }, set: { p in
                guard let s = seasons.first(where: { $0.path == p }), s.path != current.path else { return }
                Haptics.selection()
                withAnimation(.snappy) { picked = s }
            })) {
                ForEach(seasons, id: \.path) { s in Text(Self.seasonName(s)).tag(s.path) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(Self.seasonName(current))
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            // 点得到的高度够 44（F74），版面上收回去，标题行不因此变高（F12）
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .padding(.vertical, -12)
        .accessibilityIdentifier("season-menu")
    }

    /// 「第 1 集」（没有集号就是文件名）
    static func badge(_ f: EpisodeFile) -> String {
        f.ep.map { "第 \($0) 集" } ?? FileName.stem(f.name)
    }

    /// 集名（空的算没有）
    static func episodeName(_ ep: SeasonEpisode?) -> String? {
        guard let n = ep?.name, !n.isEmpty else { return nil }
        return n
    }

    /// 卡下的字：「第 1 集 · 集名」；没有集名就只写「第 1 集」
    static func episodeTitle(_ f: EpisodeFile, _ ep: SeasonEpisode?) -> String {
        guard let n = episodeName(ep) else { return badge(f) }
        return f.ep == nil ? n : badge(f) + " · " + n
    }

    private static func seasonName(_ s: Series) -> String {
        s.seasonLabel ?? s.season.map { "第 \($0) 季" } ?? s.name
    }

    // MARK: 文字

    /// 头部那一行：「剧情 · 2026 · 第 1 季 · ★ 8.0」
    private func metaLine(_ m: Meta?) -> String {
        DetailText.line([m?.genres?.first, year(m), current.seasonLabel, DetailText.rating(m?.rating)])
    }

    private func year(_ m: Meta?) -> String? {
        if let y = current.year, !y.isEmpty { return y }
        return m?.year.map { String($0.prefix(4)) }
    }

    /// 网页版 tvNextEp：没看过是第 1 集；看过就接着下一集（这一集没看完就还是这一集）；看到最后一集是「重看」
    private func nextEpisode() -> (file: EpisodeFile, label: String)? {
        guard let first = files.first else { return nil }
        guard let last = model.playback.lastEpisode(of: current.path),
              let i = files.firstIndex(where: { $0.path == last.path }) else {
            return (first, "播放第 \(first.ep ?? 1) 集")
        }
        let f = files[i]
        if last.fraction < 0.9 { return (f, "继续看第 \(f.ep ?? i + 1) 集") }
        if i + 1 < files.count { let n = files[i + 1]; return (n, "继续看第 \(n.ep ?? i + 2) 集") }
        return (f, "重看第 \(f.ep ?? i + 1) 集")
    }

    private func playLabel(_ next: (file: EpisodeFile, label: String)?) -> String {
        if let next { return next.label }
        return loading ? "播放第 1 集" : "暂无可播放文件"
    }

    /// 「从头播放」：要放的那一集有进度时才有，清掉它的进度再放
    private func restartAction(_ next: (file: EpisodeFile, label: String)?) -> (() -> Void)? {
        guard let next, model.playback.resumePosition(next.file.path) != nil,
              let i = files.firstIndex(of: next.file) else { return nil }
        let path = next.file.path
        return {
            model.playback.finish(path)
            play(index: i)
        }
    }

    private var audioLine: String? {
        guard let langs = current.langs, !langs.isEmpty else { return nil }
        var s = langs.joined(separator: "、")
        if let a = current.audio, !a.isEmpty { s += "（" + (a == "Atmos" ? "Dolby Atmos" : a) + "）" }
        return s
    }

    /// 「信息」：类型、年份、剧集（季 · 集数）、评分、导演、语言、格式；没有的项不写
    private func infoRows(_ m: Meta?) -> [DetailInfoRow] {
        [
            DetailInfoRow(label: "类型", value: (m?.genres ?? []).joined(separator: "、")),
            DetailInfoRow(label: "年份", value: year(m) ?? ""),
            DetailInfoRow(label: "剧集", value: DetailText.line([current.seasonLabel, current.countLabel])),
            DetailInfoRow(label: "评分", value: DetailText.rating(m?.rating) ?? ""),
            DetailInfoRow(label: "导演", value: m?.director ?? ""),
            DetailInfoRow(label: "语言", value: audioLine ?? ""),
            DetailInfoRow(label: "格式", value: WebFormat.line(series: current, firstFile: files.first?.name)),
        ].filter { !$0.value.isEmpty && $0.value != "—" }
    }

    private func trailerArt(_ m: Meta?) -> [String] {
        let stills = (m?.stills ?? []).compactMap { $0.url ?? $0.thumb }.filter { !$0.isEmpty }
        if !stills.isEmpty { return stills }
        return [atv?.background ?? m?.backdrop].compactMap { $0 }
    }

    // MARK: 数据与播放

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

// MARK: - 骨架（电影、剧集共用）

/// 「信息」里的一行：左边灰色的项，右边白色的值
struct DetailInfoRow: Hashable {
    let label: String
    let value: String
}

/// 全屏放第几段预告片（fullScreenCover(item:) 要一个能区分的值）
struct DetailTrailerPick: Identifiable {
    let index: Int
    var id: Int { index }
}

struct DetailScaffold<Episodes: View>: View {
    let title: String
    /// 16:9 的无字背景（横拿、展开横拿用）
    let wideArt: String?
    /// Apple TV 的竖版全屏图：头部比宽还高（竖拿）时用它，铺满不用裁横图
    let tallArt: String?
    let logo: String?
    /// 「类型 · 年份 · 片长 · ★评分」
    let metaLine: String
    let playTitle: String
    let playID: String
    var playDisabled = false
    let onPlay: () -> Void
    /// 「从头播放」：有进度才有
    var onRestart: (() -> Void)? = nil
    /// 「复制直链」对着的文件（剧集是下一集）
    let file: (path: String, name: String)?
    /// 「分享」：TMDB 上这一部的页面
    let shareURL: URL?
    let overview: String?
    let cast: [CastMember]
    let trailers: [Trailer]
    /// 预告片卡的画面（轮着用）
    let trailerArt: [String]
    let infoRows: [DetailInfoRow]
    /// 分集那一段（电影没有）：拿到当前宽度的版面尺寸再排
    @ViewBuilder var episodes: (DSMetrics) -> Episodes

    @State private var showTitle = false
    @State private var toast: String?
    @State private var castSheet: CastSheetRequest?
    @State private var trailerPick: DetailTrailerPick?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let m = DSMetrics(width: geo.size.width)
            // 整个窗口的高：把顶上的状态栏 / 导航栏、底下的标签栏加回来（画面从屏幕最顶上开始）
            let fullH = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let heroH = Self.heroHeight(width: geo.size.width, height: fullH)
            // 系统栏压住的那一截（展开横拿、外屏时栏在侧边一列，顶上几乎没有：D5、D6）
            let barBottom = geo.safeAreaInsets.top
            // 左下那一列字的顶边升到栏底下、快淡完时，片名出现在导航栏里（字块约高：字标 + 一行信息 + 按钮）
            let blockH: CGFloat = m.wide ? 192 : 168
            let titleAt: CGFloat = heroH - blockH - barBottom + 6
            // 简介限一个好读的宽度：展开的 Duo 上不拉满一整行（F8）
            let synopsisMax: CGFloat = m.wide ? 640 : .infinity
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(m, height: heroH, barBottom: barBottom)
                    // 分区之间只靠同一种留白（F3、F12）
                    VStack(alignment: .leading, spacing: m.shelfGap) {
                        if let o = overview, !o.isEmpty {
                            DetailSynopsis(text: o)
                                .frame(maxWidth: synopsisMax, alignment: .leading)
                                .padding(.horizontal, m.margin)
                        }
                        episodes(m)
                        if !trailers.isEmpty { trailerSection(m) }
                        if !cast.isEmpty { castSection(m) }
                        if !infoRows.isEmpty { infoSection(m) }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, m.shelfGap)
                }
            }
            .scrollIndicators(.hidden)
            // 画面铺到状态栏和导航栏底下（F6）；字和按钮还在安全区里（F7）
            .ignoresSafeArea(edges: .top)
            // C12：头部滚走了，片名才出现在导航栏里
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > titleAt
            } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { showTitle = v }
            }
        }
        .background(Theme.bg)
        .webToast($toast)
        .navigationTitle(showTitle ? title : "")
        .navigationBarTitleDisplayMode(.inline)
        // 全部演员：一张弹层，点演员在弹层里推进去，不叠第二层（C50、C56）
        .sheet(item: $castSheet) { r in CastSheet(people: cast, start: r.start) }
        // 预告片：全屏，系统那一套手势和关闭（C49、S22）
        .fullScreenCover(item: $trailerPick) { p in
            TrailerPlayerView(movieTitle: title, trailers: trailers, start: p.index)
        }
    }

    // MARK: 头部

    /// 竖拿约屏高的七成五（S15：65–75%）；横拿 16:9，但不高过屏幕的八成五，播放钮留在第一屏里（F1）
    static func heroHeight(width w: CGFloat, height h: CGFloat) -> CGFloat {
        if h > w { return max(420, (h * 0.75).rounded()) }
        return max(280, min((w * 9 / 16).rounded(), (h * 0.85).rounded()))
    }

    private func hero(_ m: DSMetrics, height: CGFloat, barBottom: CGFloat) -> some View {
        // 头部比宽还高就用竖版全屏图，否则用 16:9（和首页头图同一条规则：S15）
        let tall = height > m.width
        let art = tall ? (tallArt ?? wideArt) : (wideArt ?? tallArt)
        let still = reduceMotion
        // 字块的顶边从栏底下 40 点开始淡，升到栏底上方 40 点时淡完（没滚动时字块离栏底远得多，是全亮的）
        let fadeFrom = barBottom - 40
        return ZStack(alignment: .bottomLeading) {
            Color.black
                .overlay {
                    RemoteImage(url: TMDBImage.url(art, "w1280"), maxPixel: 1800, placeholder: .clear)
                        .visualEffect { c, proxy in
                            // 往上滚时画面比字走得慢一点（两层视差：S12；幅度小：F61）；「减弱动态效果」时不动（F59）
                            let minY = proxy.frame(in: .scrollView(axis: .vertical)).minY
                            return c.offset(y: still ? 0 : max(0, -minY) * 0.2)
                        }
                }
                .overlay {
                    // 顶上浅浅压暗：状态栏和返回钮停在画面上也看得清（F34）。是画面的一部分，跟着内容走，不是盖在栏下的渐暗（C27）
                    LinearGradient(colors: [.black.opacity(0.4), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2))
                }
                .overlay {
                    if !tall {
                        // 横拿时字在左下，左边再压暗一点（F34）
                        LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.6, y: 0.5))
                    }
                }
                .overlay {
                    // 底部渐暗，最后融进页面的黑：字在画面上的对比度靠它（F34、S17、C58）
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.6), location: 0.72),
                        .init(color: .black, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .clipped()
                // 横拿时侧边那一列底下也是画面（镜像模糊：F6、S19）
                .backgroundExtensionEffect()
                .frame(height: height)
                // 下拉时以底边为准撑大，填满拉出来的空隙（跟着手指走：S10）
                .stretchy()
                .accessibilityHidden(true)

            heroInfo(m)
                .padding(.horizontal, m.margin)
                .padding(.bottom, 24)
                .visualEffect { c, proxy in
                    // 字块升到导航栏底下就淡出，片名交给导航栏（C12）；淡入淡出在「减弱动态效果」时也合适（F60）
                    let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    return c.opacity(Double(max(0, min(1, (y - fadeFrom) / 80))))
                }
        }
        .frame(height: height)
    }

    /// 左下一列：字标或片名、一行信息、播放 +「…」（F1、F2）
    private func heroInfo(_ m: DSMetrics) -> some View {
        let maxW: CGFloat = m.wide ? 560 : .infinity
        return VStack(alignment: .leading, spacing: 12) {
            if let logo, !logo.isEmpty {
                LogoImage(url: TMDBImage.url(logo, "w500"), height: m.wide ? 96 : 72, alignment: .leading,
                          fallback: title, maxWidth: min(m.width * 0.7, 360))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
            }
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                playButton(m)
                moreMenu
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: maxW, alignment: .leading)
    }

    /// 主操作：白色胶囊黑字（S17、C35：一页只有这一颗醒目的钮）；折起时拉满一行，展开时按字的宽度
    private func playButton(_ m: DSMetrics) -> some View {
        let minW: CGFloat = m.wide ? 180 : 0
        let maxW: CGFloat? = m.wide ? nil : CGFloat.infinity
        return Button(action: onPlay) {
            Label(playTitle, systemImage: "play.fill")
                .lineLimit(1)
                .frame(minWidth: minW, maxWidth: maxW)
        }
        .buttonStyle(.dsPlay)
        .disabled(playDisabled)
        .opacity(playDisabled ? 0.5 : 1)
        .accessibilityIdentifier(playID)
    }

    /// 「…」：系统菜单，符号是不带圈的 ellipsis（C11、C15、C45）；底是一层半透明材质，像 tvOS 没聚焦的钮（S17、C35）。
    /// 菜单项都带 SF Symbol（F50），常用的在前（C41）；没有的项不出现
    private var moreMenu: some View {
        Menu {
            if let onRestart {
                Button("从头播放", systemImage: "arrow.counterclockwise", action: onRestart)
                    .accessibilityIdentifier("detail-restart")
            }
            if file != nil {
                Button("复制直链", systemImage: "link") { copyLink() }
                    .accessibilityIdentifier("detail-copy")
            }
            if let shareURL {
                ShareLink(item: shareURL, subject: Text(title)) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("detail-share")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.thinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
                .contentShape(Circle())
        }
        .disabled(onRestart == nil && file == nil && shareURL == nil)
        .accessibilityLabel("更多")
        .accessibilityIdentifier("detail-more")
    }

    /// 「复制直链」：签好名的 /stream 地址（可在 VLC 等播放器里打开）；复制完底部一句「直链已复制」
    private func copyLink() {
        guard let file else { return }
        Task { @MainActor in
            await StreamLink.copy(path: file.path, name: file.name)
            withAnimation(.snappy) { toast = "直链已复制" }
        }
    }

    // MARK: 分区

    /// 预告片：一排 16:9 卡，点一张全屏放（从这一段开始，左右滑换下一段）
    private func trailerSection(_ m: DSMetrics) -> some View {
        DSSection(title: "预告片", metrics: m) {
            DSShelf(metrics: m) {
                ForEach(Array(trailers.enumerated()), id: \.offset) { i, t in
                    Button { trailerPick = DetailTrailerPick(index: i) } label: {
                        DSWideLockup(art: TMDBImage.url(trailerArt.isEmpty ? nil : trailerArt[i % trailerArt.count], "w780"),
                                     title: t.title ?? "预告片", metrics: m)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("trailer-card")
                }
            }
        }
    }

    /// 演员：标题「演员 ›」点开全部名单；下面一排圆形照片（T21 monogram），点一位直接看那一位
    private func castSection(_ m: DSMetrics) -> some View {
        let d = (m.posterWidth * 0.86).rounded()
        return VStack(alignment: .leading, spacing: 6) {
            DetailLinkHeader(title: "演员", metrics: m, id: "cast-link") {
                castSheet = CastSheetRequest(start: nil)
            }
            DSShelf(metrics: m) {
                ForEach(Array(cast.prefix(20).enumerated()), id: \.offset) { _, c in
                    Button { castSheet = CastSheetRequest(start: c) } label: {
                        DetailMonogram(member: c, diameter: d, metrics: m)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("cast-card")
                }
            }
        }
    }

    /// 信息：几行左灰右白的字，不垫底板、不画线（F3）；展开时限宽，左右不隔太远（F8）
    private func infoSection(_ m: DSMetrics) -> some View {
        let maxW: CGFloat = m.wide ? 520 : .infinity
        return DSSection(title: "信息", metrics: m) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(infoRows, id: \.self) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(r.label)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        Text(r.value)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: maxW, alignment: .leading)
            .padding(.horizontal, m.margin)
            .padding(.top, 8)
        }
    }
}

// MARK: - 小部件

/// 简介：Body、宽松行距（F21），次要色；三行后一枚「更多」，点了就地展开（F24：截断了就要能看全文）。
/// 真被截断了才有「更多」：量一份不限行数的同一段字，比三行高才露出来
struct DetailSynopsis: View {
    let text: String
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    var body: some View {
        let clipped = fullHeight > shownHeight + 1
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.body.leading(.loose))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in shownHeight = h }
                .background(alignment: .top) {
                    Text(text)
                        .font(.body.leading(.loose))
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in fullHeight = h }
                }
            if clipped || expanded {
                Button {
                    withAnimation(.smooth(duration: 0.35)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "收起" : "更多")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        // 点得到的高度够 44（F74），版面上收回去
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .accessibilityIdentifier("synopsis-more")
            }
        }
    }
}

/// 分区标题（和 DSShelfTitle 一个样子：F2、F86），整行是一颗钮，标题后面一个「›」（有去处才带：C31）
struct DetailLinkHeader: View {
    let title: String
    let metrics: DSMetrics
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.dsShelfTitle(wide: metrics.wide))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            // 点得到的高度够 44（F74），版面上收回去，和别的分区标题一样高（F12）
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -10)
        .padding(.horizontal, metrics.margin)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(id)
    }
}

/// 演员那一排的一位（T21 monogram：圆形照片 + 名字，角色在第二行）。
/// 停在左侧基准线上的那位像 tvOS 的焦点一样微微放大（S7–S9）；字一直在，名字是要读的
struct DetailMonogram: View {
    let member: CastMember
    let diameter: CGFloat
    let metrics: DSMetrics

    var body: some View {
        let role = member.character ?? ""
        VStack(spacing: 10) {
            // 圆有近百点宽：取大一号的照片，按 点 × 屏幕倍率 要像素（F62）
            CastPhoto(member: member, size: diameter, large: true)
            VStack(spacing: 2) {
                Text(member.name.isEmpty ? "未知演员" : member.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(role.isEmpty ? " " : role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .frame(width: diameter)
        }
        .frame(width: diameter)
        .modifier(DSFocusEffect(metrics: metrics, cardWidth: diameter, poster: true))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([member.name, role.isEmpty ? nil : "饰 " + role].compactMap { $0 }.joined(separator: "，"))
    }
}

/// 长按分集卡时的预览（C21）：剧照、「第 1 集 · 45 分钟」、集名、整段简介——卡上只放最要紧的字
struct DetailEpisodePreview: View {
    let art: URL?
    let kicker: String
    let title: String
    let overview: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color(uiColor: .systemGray5)
                .overlay { RemoteImage(url: art, maxPixel: 1000, placeholder: .clear) }
                .frame(width: 340, height: 191)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                if !kicker.isEmpty {
                    Text(kicker)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let overview, !overview.isEmpty {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: 340, alignment: .leading)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .environment(\.colorScheme, .dark)
    }
}

/// 详情页的几句字
enum DetailText {
    /// 几段字用「 · 」连起来，空的跳过
    static func line(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 「★ 7.5」：没有评分就是 nil
    static func rating(_ r: Double?) -> String? {
        guard let r, r > 0 else { return nil }
        return String(format: "★ %.1f", r)
    }

    /// TMDB 上这一部的页面（「…」里的「分享」）
    static func tmdbPage(kind: String, id: Int?) -> URL? {
        guard let id else { return nil }
        return URL(string: "https://www.themoviedb.org/\(kind)/\(id)")
    }

    /// 放得了的预告片：和 AppModel.trailers(for:) 同一条规矩（订阅才看得了的不要）
    static func playable(_ t: [Trailer]?) -> [Trailer] {
        (t ?? []).filter { !$0.hls.isEmpty && !$0.hls.contains("/subscription/") }
    }
}

// MARK: - 复制直链与底部提示（详情页「…」菜单里的「复制直链」用）

/// 签好名的 /stream 直链（网页版 copyStreamLink），复制到剪贴板
enum StreamLink {
    @MainActor static func copy(path: String, name: String) async {
        let sign = try? await APIClient.shared.streamSign(path: path)
        let url = APIClient.shared.streamURL(path: path, name: name, sign: sign)
        UIPasteboard.general.string = url.absoluteString
        Haptics.success()
    }
}

/// 页面底部一枚玻璃小胶囊（「直链已复制」），1.6 秒后自己退
struct WebToast: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = text {
                Text(t)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation(.easeOut(duration: 0.3)) { text = nil }
                    }
            }
        }
    }
}

extension View {
    func webToast(_ text: Binding<String?>) -> some View { modifier(WebToast(text: text)) }
}

// MARK: - 「格式」那一格（网页版：扩展名 · 8K+ UHD（4K 片源）/ 高动态（1080p）· DV / HDR）

enum WebFormat {
    /// 电影：读文件名（规则照抄网页版 parse()）
    static func line(name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        func has(_ p: String) -> Bool { name.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        let dv = has("DOLBY[. _-]?VISION|[. _-]DV[. _-]|[. _-]DoVi")
        let hdr = !dv && has("HDR10\\+?|[. _-]HDR[. _-]")
        let uhd = has("2160P|[. _-]4K[. _-]|UHD")
        let hd = !uhd && has("1080P")
        return compose(ext: ext, uhd: uhd, hd: hd, top: dv ? "DV" : (hdr ? "HDR" : nil))
    }

    /// 剧集：目录名解析出来的分辨率 / HDR（网页版 tvSeriesTags），扩展名取第一集
    static func line(series s: Series, firstFile: String?) -> String {
        let ext = ((firstFile ?? "") as NSString).pathExtension.uppercased()
        let res = (s.res ?? "").uppercased()
        let hdr = s.hdr ?? ""
        return compose(ext: ext, uhd: res == "4K" || res == "8K", hd: !res.isEmpty && res != "4K" && res != "8K",
                       top: hdr == "DV" ? "DV" : (hdr.isEmpty ? nil : "HDR"))
    }

    private static func compose(ext: String, uhd: Bool, hd: Bool, top: String?) -> String {
        var s = ext
        if uhd { s += " · 8K+ UHD" } else if hd { s += " · 高动态" }
        if let top { s += (s.isEmpty ? "" : " · ") + top }
        return s.isEmpty ? "—" : s
    }
}
