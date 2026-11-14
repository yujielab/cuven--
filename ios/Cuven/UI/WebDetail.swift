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
    /// 头部的画面和字标：定下来就不再换（DetailArt）
    @State private var art: DetailArt?

    var body: some View {
        let meta = full ?? model.meta(video)
        // C89：「播放」自己接着上次的地方放，不问；从头看放进「…」菜单
        let resume = model.playback.resumePosition(video.path) != nil

        DetailScaffold(
            title: model.title(video),
            art: art,
            metaLine: metaLine(meta),
            playTitle: resume ? "继续播放" : "播放",
            playID: "detail-play",
            onPlay: { play(meta) },
            onRestart: restartAction(meta),
            file: (path: video.path, name: video.name),
            shareURL: DetailText.tmdbPage(kind: "movie", id: meta?.id),
            about: aboutCards(meta),
            cast: meta?.cast ?? [],
            trailers: trailers,
            trailerArt: trailerArt(meta)
        ) { _ in
            EmptyView()
        }
        .task { full = await model.fullMeta(for: video) }
        // 在线字幕：打开详情页时先让后台去找（不等），点播放时主列表里就有这一条备选
        .task(id: video.path) {
            guard !DemoData.enabled else { return }
            await APIClient.shared.warmSubs(path: video.path)
        }
        .task(id: video.path) {
            // 画面和字标只定一次（用户要求：不先出一张、过一会儿又跳成另一张）：
            // 这一部的 Apple TV 这次已经问过 → 全片库的 Apple TV 素材（本地就有）→ 等这一部的 Apple TV 最多 0.8 秒 → TMDB
            if art == nil { art = quickArt() }
            if art == nil {
                let fallback = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if !Task.isCancelled && art == nil { art = tmdbArt() }
                }
                atv = await model.atv(for: video)
                fallback.cancel()
                if art == nil { art = lookupArt(atv) ?? tmdbArt() }
            } else {
                atv = await model.atv(for: video)
            }
            // 和资料库展映同一份：Apple TV 上的公开预告（订阅才看得了的不要）；atv 已经记在内存里，不再走网络
            trailers = await model.trailers(for: video)
        }
        // TMDB 全量结果里才有字标的：原来没有字标（写的是片名）才补上；已经有字标就不换
        .onChange(of: full?.logo) { _, l in
            if let l, !l.isEmpty, art != nil, (art?.logo ?? "").isEmpty { art?.logo = l }
        }
    }

    /// 本地马上就有的：这一部的 Apple TV 这次已经问过 → 全片库的 Apple TV 素材；都没有是 nil（再等一下）
    private func quickArt() -> DetailArt? {
        if let hit = model.atvCached(path: video.path) { return lookupArt(hit) ?? tmdbArt() }
        if let a = model.appleArt(video), a.tall != nil || a.background != nil || a.wide != nil {
            return tmdbArt()
        }
        return nil
    }

    /// 这一部的 Apple TV：竖版全屏图、无字背景、字标；缺的项按全片库的 Apple TV 素材、TMDB 补
    private func lookupArt(_ r: AtvLookup?) -> DetailArt? {
        guard let r else { return nil }
        let m = full ?? model.meta(video)
        return DetailArt(wide: r.background ?? model.backgroundArtString(video) ?? m?.backdrop ?? m?.poster,
                         tall: r.imageTall ?? model.tallArtString(video),
                         logo: r.logo ?? model.logoArtString(video) ?? m?.logo)
    }

    /// 全片库的 Apple TV 素材 → TMDB
    private func tmdbArt() -> DetailArt {
        let m = full ?? model.meta(video)
        return DetailArt(wide: model.backgroundArtString(video) ?? m?.backdrop ?? m?.poster,
                         tall: model.tallArtString(video),
                         logo: model.logoArtString(video) ?? m?.logo)
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

    /// 「简介」那一排：简介、评分、影片规格；原来页面最底下「信息」的几行（类型、上映、片长、导演、格式）并进影片规格的弹层
    private func aboutCards(_ m: Meta?) -> [DetailAboutCard] {
        var out: [DetailAboutCard] = []
        if let o = m?.overview, !o.isEmpty {
            out.append(.synopsis(title: model.title(video), genres: m?.genres ?? [], overview: o))
        }
        if let r = m?.rating, r > 0 {
            out.append(.rating(r, percentile: model.ratingPercentile(r, series: false), pool: "电影"))
        }
        let spec = MediaSpec(name: video.name, size: video.size)
        let runtime = Format.runtime(m?.runtime)
        let year = model.year(video).map { String($0) }
        let rows = [
            DetailInfoRow(label: "类型", value: (m?.genres ?? []).joined(separator: "、")),
            DetailInfoRow(label: "上映", value: year ?? ""),
            DetailInfoRow(label: "片长", value: runtime),
            DetailInfoRow(label: "导演", value: m?.director ?? ""),
            DetailInfoRow(label: "分辨率", value: spec.resolution ?? ""),
            DetailInfoRow(label: "动态范围", value: spec.range ?? ""),
            DetailInfoRow(label: "视频", value: spec.video ?? ""),
            DetailInfoRow(label: "音频", value: spec.audio ?? ""),
            DetailInfoRow(label: "封装", value: spec.container ?? ""),
            DetailInfoRow(label: "大小", value: spec.size ?? ""),
            DetailInfoRow(label: "文件", value: video.name),
        ].filter { !$0.value.isEmpty }
        // 大字：分辨率 · 动态范围；文件名里读不出来就写片长
        let title = spec.headline ?? (runtime.isEmpty ? (spec.container ?? "影片规格") : runtime)
        let text = DetailText.line([spec.headline == nil ? nil : runtime, year, spec.video, spec.audio, spec.container, spec.size])
        out.append(DetailAboutCard(id: "specs", title: title, caption: "影片规格", text: text, sheetTitle: "影片规格", rows: rows))
        return out
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
    /// 分集菜单里「复制直链」之后底部那一句
    @State private var toast: String?
    /// 头部的画面和字标：定下来就不再换（换季也不换：同一部剧）
    @State private var art: DetailArt?

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
            art: art,
            metaLine: metaLine(meta),
            playTitle: playLabel(next),
            playID: "series-play",
            playDisabled: next == nil,
            onPlay: { if let next, let i = files.firstIndex(of: next.file) { play(index: i) } },
            onRestart: restartAction(next),
            file: next.map { (path: $0.file.path, name: $0.file.name) },
            shareURL: DetailText.tmdbPage(kind: "tv", id: current.tmdbId ?? meta?.id),
            about: aboutCards(meta),
            cast: meta?.cast ?? [],
            trailers: DetailText.playable(atv?.trailers),
            trailerArt: trailerArt(meta)
        ) { m in
            episodes(m, fallbackArt: fallbackArt)
        }
        .webToast($toast)
        .task(id: current.path) { await load() }
        .task(id: current.path) {
            atv = nil
            await model.ensureSeriesMeta(current)
            // 画面和字标只定一次：这部剧的 Apple TV 这次问过就直接用；没问过最多等 0.8 秒，等不到用 TMDB 的，之后不换
            if art == nil, let hit = model.atvCached(path: current.path) { art = seriesArt(hit) }
            if art == nil {
                let fallback = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if !Task.isCancelled && art == nil { art = seriesArt(nil) }
                }
                atv = await model.atv(for: current)
                fallback.cancel()
                if art == nil { art = seriesArt(atv) }
            } else {
                atv = await model.atv(for: current)
            }
        }
        .onChange(of: model.seriesMetas[current.path]?.logo) { _, l in
            if let l, !l.isEmpty, art != nil, (art?.logo ?? "").isEmpty { art?.logo = l }
        }
    }

    /// 这部剧的头部：Apple TV 的竖版全屏图、无字背景、字标优先，缺的用 TMDB 补
    private func seriesArt(_ r: AtvLookup?) -> DetailArt {
        let m = model.seriesMetas[current.path]
        return DetailArt(wide: r?.background ?? m?.backdrop ?? m?.poster, tall: r?.imageTall, logo: r?.logo ?? m?.logo)
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
                            DSMediaCard(art: nil, title: "第 \(i + 1) 集", detail: "45 分钟", metrics: m, action: {}) { EmptyView() }
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
                // 两种卡（用户要求）：这一季大半的集有简介就用长文案的方卡，不然用短文案的 16:9 卡；一排里样子统一
                let long = files.filter { !(($0.ep.flatMap { info[$0]?.overview }) ?? "").isEmpty }.count * 2 >= files.count
                DSShelf(metrics: m) {
                    ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                        episodeCard(f, index: i, metrics: m, fallbackArt: fallbackArt, long: long)
                    }
                }
            }
        }
    }

    /// 一集：16:9 剧照，字压在底部的渐进式模糊上（Apple TV 的分集卡）：「第 1 集 · 集名」和「▶ 45 分钟」；
    /// 看到一半是「▶ ▬▬ 剩余 12 分钟」，看完的写「已看」（F36：状态不只靠颜色）。点一下就放这一集（C88）；
    /// 右下的「•••」和长按是同一份菜单，长按的预览是这一集的整段简介（C21）
    private func episodeCard(_ f: EpisodeFile, index i: Int, metrics m: DSMetrics, fallbackArt: String?, long: Bool) -> some View {
        let ep = f.ep.flatMap { info[$0] }
        let entry = model.playback.entry(f.path)
        let fraction = entry?.fraction ?? 0
        let done = fraction >= 0.9
        let partial = !done && model.playback.resumePosition(f.path) != nil
        let art = TMDBImage.url(ep?.still ?? fallbackArt, "w780")
        let runtime = Format.runtime(ep?.runtime)
        let detail: String
        if done {
            detail = DetailText.line([runtime, "已看"])
        } else if partial, let e = entry {
            detail = "剩余 " + Format.runtime(max(1, Int((e.remaining / 60).rounded())))
        } else {
            detail = runtime
        }
        // 长文案：上面一行「第 2 集」、标题只写集名（没有集名就写「第 2 集」、上面那行不写），下面三行简介
        let name = Self.episodeName(ep)
        return DSMediaCard(art: art,
                           title: long ? (name ?? Self.badge(f)) : Self.episodeTitle(f, ep),
                           detail: detail,
                           progress: partial ? fraction : nil,
                           tall: long,
                           kicker: long && name != nil ? Self.badge(f) : nil,
                           overview: long ? ep?.overview : nil,
                           metrics: m, identifier: "episode-card",
                           action: { play(index: i) }) {
            episodeMenu(f, index: i, done: done, partial: partial)
        }
        .contextMenu {
            episodeMenu(f, index: i, done: done, partial: partial)
        } preview: {
            DetailEpisodePreview(art: art, kicker: DetailText.line([Self.badge(f), runtime]),
                                 title: Self.episodeName(ep) ?? Self.badge(f), overview: ep?.overview)
        }
    }

    /// 一集的菜单（「•••」和长按共用）：播放 / 继续播放 / 重看，有进度时「从头播放」，「复制直链」（C45）
    @ViewBuilder private func episodeMenu(_ f: EpisodeFile, index i: Int, done: Bool, partial: Bool) -> some View {
        Button(done ? "重看这一集" : (partial ? "继续播放" : "播放这一集"), systemImage: "play.fill") { play(index: i) }
        if partial {
            Button("从头播放", systemImage: "arrow.counterclockwise") {
                model.playback.finish(f.path)
                play(index: i)
            }
        }
        // 演示数据不连网：没有直链可复制
        if !DemoData.enabled {
            Button("复制直链", systemImage: "link") { copyLink(f) }
        }
    }

    /// 「复制直链」：这一集签好名的 /stream 地址；复制完底部一句「直链已复制」
    private func copyLink(_ f: EpisodeFile) {
        Task { @MainActor in
            await StreamLink.copy(path: f.path, name: f.name)
            withAnimation(.snappy) { toast = "直链已复制" }
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

    /// 「简介」那一排：简介、评分、影片规格（季与集数、语言、分辨率、动态范围、音频、封装；原来「信息」的几行也在影片规格的弹层里）
    private func aboutCards(_ m: Meta?) -> [DetailAboutCard] {
        var out: [DetailAboutCard] = []
        if let o = m?.overview, !o.isEmpty {
            out.append(.synopsis(title: m?.title ?? current.name, genres: m?.genres ?? [], overview: o))
        }
        if let r = m?.rating, r > 0 {
            out.append(.rating(r, percentile: model.ratingPercentile(r, series: true), pool: "剧集"))
        }
        let spec = MediaSpec.series(current, firstFile: files.first?.name)
        let langs = (current.langs ?? []).joined(separator: "、")
        let episodes = DetailText.line([current.seasonLabel, current.countLabel])
        let rows = [
            DetailInfoRow(label: "类型", value: (m?.genres ?? []).joined(separator: "、")),
            DetailInfoRow(label: "年份", value: year(m) ?? ""),
            DetailInfoRow(label: "剧集", value: episodes),
            DetailInfoRow(label: "导演", value: m?.director ?? ""),
            DetailInfoRow(label: "语言", value: langs),
            DetailInfoRow(label: "分辨率", value: spec.resolution ?? ""),
            DetailInfoRow(label: "动态范围", value: spec.range ?? ""),
            DetailInfoRow(label: "视频", value: spec.video ?? ""),
            DetailInfoRow(label: "音频", value: spec.audio ?? ""),
            DetailInfoRow(label: "封装", value: spec.container ?? ""),
        ].filter { !$0.value.isEmpty }
        let title = spec.headline ?? (current.seasonLabel ?? "影片规格")
        let text = DetailText.line([episodes, langs.isEmpty ? nil : langs, spec.audio, spec.container])
        out.append(DetailAboutCard(id: "specs", title: title, caption: "影片规格", text: text, sheetTitle: "影片规格", rows: rows))
        return out
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

/// 详情页头部用哪张画面、哪枚字标：定下来就不再换（免得先出一张、过一会儿又跳成另一张：用户要求）
struct DetailArt: Equatable {
    /// 16:9 的无字背景（横着的屏用）
    var wide: String?
    /// Apple TV 的竖版全屏图（竖着的屏用；没有就裁横图）
    var tall: String?
    var logo: String?
}

struct DetailScaffold<Episodes: View>: View {
    let title: String
    /// 头部的画面和字标；nil 是还没定（只有底色，字标那一格空着，定了再模糊淡入）
    let art: DetailArt?
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
    /// 「简介」那一排卡：简介、评分、影片规格（DetailAbout.swift）
    let about: [DetailAboutCard]
    let cast: [CastMember]
    let trailers: [Trailer]
    /// 预告片卡的画面（轮着用）
    let trailerArt: [String]
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
            let insets = geo.safeAreaInsets
            // 整个窗口：把顶上的状态栏 / 导航栏、底下的标签栏、侧边那一列加回来（画面从屏幕最顶上开始、连同侧边那一列一起平铺）
            let fullH = geo.size.height + insets.top + insets.bottom
            let fullW = geo.size.width + insets.leading + insets.trailing
            let heroH = Self.heroHeight(width: fullW, height: fullH)
            // 系统栏压住的那一截（展开横拿、外屏时栏在侧边一列，顶上几乎没有：D5、D6）
            let barBottom = geo.safeAreaInsets.top
            // 左下那一列字的顶边升到栏底下、快淡完时，片名出现在导航栏里（字块约高：字标 + 一行信息 + 按钮）
            let blockH: CGFloat = m.wide ? 192 : 168
            let titleAt: CGFloat = heroH - blockH - barBottom + 6
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(m, width: fullW, height: heroH, insets: insets, barBottom: barBottom)
                    // 分区之间只靠同一种留白（F3、F12）
                    VStack(alignment: .leading, spacing: m.shelfGap) {
                        // 简介、评分、影片规格：一排卡（Apple TV 的简介卡）
                        if !about.isEmpty {
                            DSSection(title: "简介", metrics: m) {
                                DetailAboutRow(cards: about, metrics: m)
                            }
                        }
                        episodes(m)
                        if !trailers.isEmpty { trailerSection(m) }
                        if !cast.isEmpty { castSection(m) }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, m.shelfGap)
                    // 下面的内容留在安全区里（卡往右滑出去时从侧边那一列底下过去）
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                }
            }
            .scrollIndicators(.hidden)
            // 画面铺到状态栏、导航栏和侧边那一列底下（F6）；字和按钮还在安全区里（F7）
            .ignoresSafeArea(edges: [.top, .horizontal])
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

    /// 头部一样高（用户要求：统一高度，比画面稍高）：竖着的屏九成屏高，横着的屏九成二；画面只占上面那一截
    static func heroHeight(width w: CGFloat, height h: CGFloat) -> CGFloat {
        max(420, (h * (h > w ? 0.9 : 0.92)).rounded())
    }

    private func hero(_ m: DSMetrics, width: CGFloat, height: CGFloat, insets: EdgeInsets, barBottom: CGFloat) -> some View {
        // 头部比宽还高就用竖版全屏图，否则用 16:9（和首页头图同一条规则：S15）；画面占头部上面七成（横着的屏八成）
        let tall = height > width
        let imageH = (height * (tall ? 0.7 : 0.8)).rounded()
        let pick = art.flatMap { tall ? ($0.tall ?? $0.wide) : ($0.wide ?? $0.tall) }
        // 字块的顶边从栏底下 40 点开始淡，升到栏底上方 40 点时淡完（没滚动时字块离栏底远得多，是全亮的）
        let fadeFrom = barBottom - 40
        return ZStack(alignment: .bottomLeading) {
            DetailHeroBackdrop(url: TMDBImage.url(pick, "w1280"), width: width, height: height, imageHeight: imageH)
                // 下拉时以底边为准撑大，填满拉出来的空隙（跟着手指走：S10）
                .stretchy()
                .accessibilityHidden(true)

            heroInfo(m)
                .padding(.leading, insets.leading + m.margin)
                .padding(.trailing, insets.trailing + m.margin)
                .padding(.bottom, 32)
                .visualEffect { c, proxy in
                    // 字块升到导航栏底下就淡出，片名交给导航栏（C12）；淡入淡出在「减弱动态效果」时也合适（F60）
                    let y = proxy.frame(in: .scrollView(axis: .vertical)).minY
                    return c.opacity(Double(max(0, min(1, (y - fadeFrom) / 80))))
                }
        }
        .frame(width: width, height: height)
    }

    /// 左下一列：字标或片名、一行信息、播放 +「…」（F1、F2）
    private func heroInfo(_ m: DSMetrics) -> some View {
        let maxW: CGFloat = m.wide ? 560 : .infinity
        let logoH: CGFloat = m.wide ? 96 : 72
        return VStack(alignment: .leading, spacing: 12) {
            // 字标那一格：画面和字标定下来之前空着（占住位置，下面的字不跳），定了模糊淡入；以后不再换
            ZStack(alignment: .bottomLeading) {
                if let art {
                    if let logo = art.logo, !logo.isEmpty {
                        LogoImage(url: TMDBImage.url(logo, "w500"), height: logoH, alignment: .leading,
                                  fallback: title, maxWidth: min(m.width * 0.7, 360))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(title)
                            .accessibilityAddTraits(.isHeader)
                            .transition(.dsBlurFade)
                    } else {
                        Text(title)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .accessibilityAddTraits(.isHeader)
                            .transition(.dsBlurFade)
                    }
                } else {
                    Color.clear.frame(height: logoH)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: art)
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
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

    /// 预告片：一排 16:9 卡，和分集卡同一个样子（字压在渐进式模糊上）；点一张全屏放（从这一段开始，左右滑换下一段）
    private func trailerSection(_ m: DSMetrics) -> some View {
        DSSection(title: "预告片", metrics: m) {
            DSShelf(metrics: m) {
                ForEach(Array(trailers.enumerated()), id: \.offset) { i, t in
                    DetailTrailerCard(trailer: t, art: t.image ?? (trailerArt.isEmpty ? nil : trailerArt[i % trailerArt.count]),
                                      metrics: m, onPlay: { trailerPick = DetailTrailerPick(index: i) })
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

}

// MARK: - 小部件

/// 详情页头部的底（用户要求）：画面铺满整个窗口宽（含 iPhone Duo 侧边那一列，不做镜像模糊），只占头部上面那一截；
/// 画面下段渐进式模糊，慢慢化进从画面底边取出来的主色（压暗到白字看得清），这块颜色铺到头部底、最后一小段融进页面的黑。
/// 画面裁好、糊好、取好色才出现，出现时模糊淡入；换图（转屏）也是模糊淡入，不会突然跳成另一张
struct DetailHeroBackdrop: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    let imageHeight: CGFloat
    @State private var shown: Shown?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Shown: Equatable {
        let key: String
        let art: HeroArt
        static func == (a: Shown, b: Shown) -> Bool { a.key == b.key }
    }

    var body: some View {
        let tone = Color(uiColor: shown.map { ImageEffects.heroTone($0.art.edge) } ?? UIColor(white: 0.07, alpha: 1))
        let imgEnd = min(1, imageHeight / max(1, height))
        let key = "\(url?.absoluteString ?? "")#\(Int(width))x\(Int(imageHeight))"
        ZStack(alignment: .top) {
            tone
            ZStack {
                if let s = shown {
                    Image(uiImage: s.art.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: imageHeight)
                        .clipped()
                        .id(s.key)
                        .transition(reduceMotion ? .opacity : .dsBlurFade)
                }
            }
            .frame(width: width, height: imageHeight)
            .clipped()
            // 画面下段化进底色：配合画面里那段渐进式模糊，看不出接缝
            LinearGradient(stops: Self.dissolve(tone, from: imgEnd * 0.58, to: imgEnd), startPoint: .top, endPoint: .bottom)
            // 顶上浅浅压暗：状态栏和返回钮停在画面上也看得清（F34）
            LinearGradient(colors: [.black.opacity(0.38), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.18))
            // 头部最后一小段融进页面的黑
            LinearGradient(stops: [
                .init(color: .clear, location: max(0, 1 - 48 / max(1, height))),
                .init(color: Theme.bg, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: width, height: height)
        .animation(.easeInOut(duration: 0.8), value: shown?.key)
        .task(id: key) {
            guard let url else { return }
            if shown?.key == key { return }
            let aspect = width / max(1, imageHeight)
            let px = min(2400, max(width, imageHeight) * 3)
            guard let art = await ImagePipeline.shared.heroArt(url, maxPixel: px, aspect: aspect), !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.8)) { shown = Shown(key: key, art: art) }
        }
    }

    /// 由透明到底色的一段，alpha 走 smoothstep（OLED 上不起条带）
    private static func dissolve(_ c: Color, from a: CGFloat, to b: CGFloat) -> [Gradient.Stop] {
        (0...8).map { i in
            let t = CGFloat(i) / 8
            let s = t * t * (3 - 2 * t)
            return Gradient.Stop(color: c.opacity(Double(s)), location: a + (b - a) * t)
        }
    }
}

/// 一段预告片：卡上是这一段自己的画面（Apple 给了就用，没给就轮着用剧照）、片名和「▶ 2 分钟」
/// （时长 Apple 给了就用，没给就读一下这段预告片的播放列表：TrailerLength）；「•••」里是播放和分享
struct DetailTrailerCard: View {
    let trailer: Trailer
    let art: String?
    let metrics: DSMetrics
    let onPlay: () -> Void
    @State private var seconds: Double?

    var body: some View {
        let title = trailer.title.flatMap { $0.isEmpty ? nil : $0 }
        DSMediaCard(art: TMDBImage.url(art, "w780"), title: title ?? "预告片",
                    detail: TrailerLength.label(trailer.duration ?? seconds) ?? (title == nil ? nil : "预告片"),
                    metrics: metrics, identifier: "trailer-card", action: onPlay) {
            Button("播放", systemImage: "play.fill", action: onPlay)
            if let url = URL(string: trailer.hls), url.scheme?.hasPrefix("http") == true {
                ShareLink(item: url, subject: Text(title ?? "预告片")) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
            }
        }
        .task(id: trailer.hls) {
            guard trailer.duration == nil, seconds == nil else { return }
            seconds = await TrailerLength.shared.seconds(trailer.hls)
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
/// 圆和字都不随滑动放大（卡在排里一动不动）；字一直在，名字是要读的
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
        // 演示数据不连网（截图、UI 测试）：不去签名
        if DemoData.enabled { return }
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

