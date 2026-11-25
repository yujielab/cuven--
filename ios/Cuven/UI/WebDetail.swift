import Metal
import SwiftUI
import UIKit

// MARK: - 详情页（电影 / 剧集同一页）：按 Apple HIG 收拾成 Apple TV 的样子（规则编号见 docs/ios-design.md）
//
// 头部：全幅画面（竖拿用 Apple TV 的竖版全屏图，横拿 16:9：S15），往下渐暗（F34），字压在左下（F1、F2）：
// 字标（没有字标就是 Large Title 的片名）→ 一行信息「类型 · 年份 · 片长 · ★评分」（F18）→
// 一颗白色「播放」+ 有进度时一颗「…」系统菜单（从头播放：S17、C11、C15、C35、C45；发行版不再有站外操作）。
// 下面照用户给的参考图（Apple「游戏」App 的详情页，DetailInfo.swift）：整页染上画面的颜色，一组一行粗体标题 + 一张半透明大圆角卡——
// 简介（几行 + 导演）→ 分集（剧集）→ 预告片（有才有）→ 演员（圆形照片：T21）→ 影片详细信息（上映时间、时长、流量能效、推荐等级）
// → 更多同类型的几部；往上滚过头部，顶上钉住一条：海报、片名、「播放」。
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
    /// 预先缓存、下载开不了（空间不够、演示数据）时说一声
    @State private var precacheAlert: PrecacheAlert?

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
            genres: meta?.genres ?? [],
            overview: meta?.overview,
            director: meta?.director,
            stats: stats(meta),
            related: related(meta),
            thumb: TMDBImage.url(meta?.poster ?? meta?.posterClean, "w185"),
            cast: meta?.cast ?? [],
            trailers: trailers,
            trailerArt: trailerArt(meta),
            stills: DetailText.stills(meta),
            precache: precacheState(meta),
            downloadPath: video.path
        ) { _ in
            EmptyView()
        }
        // 「下载」「分享」（用户要求：iPhone Duo 侧边那一列返回钮下面；别的 iPhone 在右上角）：分享的是下好的文件，可以直接隔空投送
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                DetailDownloadButton(video: video, title: model.title(video), runtime: meta?.runtime, alert: $precacheAlert)
                DetailShareButton(video: video, title: model.title(video), tmdbID: meta?.id)
            }
        }
        .alert(precacheAlert?.title ?? "", isPresented: Binding(get: { precacheAlert != nil }, set: { if !$0 { precacheAlert = nil } }),
               presenting: precacheAlert) { _ in
            Button("好", role: .cancel) {}
        } message: { a in
            Text(a.message)
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

    /// 弱网预先缓存（用户要求）：已经在缓存 / 缓存过的 → 「立即播放」+ 圆形进度钮；网络不好或网络速度低于 50% → 「预先画面质量处理」；
    /// 都不是 → nil（平常的「播放」）
    private func precacheState(_ meta: Meta?) -> DetailPrecache? {
        let pre = Precache.shared
        let item = pre.item(path: video.path)
        guard item != nil || pre.suggested(name: video.name, size: video.size, runtime: meta?.runtime) else { return nil }
        let path = video.path
        return DetailPrecache(
            mode: item == nil ? .suggest : .active,
            phase: item?.phase,
            progress: item?.progress ?? 0,
            bytes: item?.bytes ?? 0,
            onStart: { startPrecache(meta) },
            onPause: { Precache.shared.pause(path: path) },
            onResume: { Precache.shared.resume(path: path) },
            onDelete: { Precache.shared.delete(path: path) })
    }

    private func startPrecache(_ meta: Meta?) {
        let r = Precache.shared.start(path: video.path, name: video.name, title: model.title(video), size: video.size,
                                      runtime: meta?.runtime, resume: model.playback.resumePosition(video.path))
        switch r {
        case .started:
            Haptics.light()
        case .noSpace(let needed):
            Haptics.error()
            let gb = max(1, Int((Double(needed) / 1_000_000_000).rounded(.up)))
            precacheAlert = PrecacheAlert(title: "iPhone 储存空间不足",
                                          message: "预先缓存这部影片需要至少 \(gb) GB 可用空间。请在「设置」>「通用」>「iPhone 储存空间」中清理后再试。")
        case .unavailable:
            precacheAlert = PrecacheAlert(title: "无法预先缓存", message: "演示模式下无法缓存影片。")
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

    /// 「影片详细信息」那几块（用户要求只留四样）：上映时间、时长、流量能效（高 / 中 / 低）、推荐等级（高 / 中 / 低）；
    /// 版式是天气 App 那种方块（DetailStatsGrid）
    private func stats(_ m: Meta?) -> DetailStats {
        var s = DetailStats()
        let day = DetailFacts.day(m?.releaseDate)
        let y = model.year(video)
        if day != nil || y != nil { s.release = DetailStats.Release(date: day, year: y, verb: "上映", season: nil) }
        if let r = m?.runtime, r > 0 { s.runtime = DetailStats.Runtime(minutes: r, perEpisode: false) }
        s.efficiency = DetailFacts.efficiency(bytes: video.size, minutes: m?.runtime)
        if let r = m?.rating, r > 0 { s.rating = r }
        return s
    }

    /// 「更多××电影 ›」：同类型的几部（同的类型越多越靠前，再按评分）；标题点进这一类的全部
    private func related(_ m: Meta?) -> DetailRelated? {
        guard let g = m?.genres?.first else { return nil }
        let items = model.related(to: video, limit: 3).map { v -> DetailRelatedItem in
            let mm = model.meta(v)
            return DetailRelatedItem(id: v.path, title: model.title(v),
                                     subtitle: DetailText.line([model.year(v).map { String($0) }, mm?.genres?.first, DetailText.rating(mm?.rating)]),
                                     art: TMDBImage.url(mm?.poster ?? mm?.posterClean, "w342"), route: .movie(v))
        }
        guard !items.isEmpty else { return nil }
        return DetailRelated(title: "更多\(g)电影", route: .shelf(.genre(g)), items: items)
    }

    /// 预告片卡的画面（Apple 给了这段预告片自己的画面就不用这个），见 DetailMediaArt.trailerArt
    private func trailerArt(_ m: Meta?) -> [String] {
        let stills = (m?.stills ?? []).compactMap { $0.url ?? $0.thumb }.filter { !$0.isEmpty }
        let wide = AppleImage.sized(atv?.background, width: 1280) ?? model.backgroundArtString(video)
        return DetailMediaArt.trailerArt(wide: wide, stills: stills)
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
    /// 头部的画面和字标：定下来就不再换（换季也不换：同一部剧）
    @State private var art: DetailArt?

    private var current: Series { picked ?? series }

    /// 这部剧的几季：和主页、合集页去重用同一条认法（AppModel.showKey），季菜单里的就是主页那张卡代表的那几季。
    /// 同一季有两份（/auto 里请求添加来的那份和整理进剧集目录的那份，用户截图里重复的「铁拳教育 · 第 1 季」）：菜单里只出一个，
    /// 留 preferredSeason 挑的那份；正在看的那份一定留
    private var seasons: [Series] {
        let key = model.showKey(current)
        let same = model.series.filter { model.showKey($0) == key }
        let list = same.contains(where: { $0.path == current.path }) ? same : same + [current]
        var bySeason: [Int: Series] = [:]
        for s in list {
            let n = s.season ?? 0
            guard let have = bySeason[n] else { bySeason[n] = s; continue }
            if have.path == current.path { continue }
            if s.path == current.path || AppModel.preferredSeason(s, over: have) { bySeason[n] = s }
        }
        return bySeason.values.sorted { ($0.season ?? 0) < ($1.season ?? 0) }
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
            genres: meta?.genres ?? [],
            overview: meta?.overview,
            director: meta?.director,
            stats: stats(meta),
            related: related(meta),
            thumb: TMDBImage.url(meta?.poster ?? meta?.posterClean, "w185"),
            cast: meta?.cast ?? [],
            trailers: DetailText.playable(atv?.trailers),
            trailerArt: trailerArt(meta),
            stills: DetailText.stills(meta)
        ) { m in
            episodes(m, fallbackArt: fallbackArt)
        }
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

    /// 「剧集」+ 右边的季菜单；下面一排 16:9 的分集卡（T23：标准的横排；S8：停在左侧基准线上）。
    /// 标题到卡和别的分区一样是 titleGap（设计轮 2：以前 6）
    private func episodes(_ m: DSMetrics, fallbackArt: String?) -> some View {
        VStack(alignment: .leading, spacing: m.titleGap) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("剧集")
                    .font(.dsSectionTitle)
                    .foregroundStyle(.white)
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
                    Text(failed ?? "暂无可播放的剧集")
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
        // 长文案：上面一行「第 2 集」、标题只写集名（没有集名就写「第 2 集」、上面那行不写），下面两行简介（用户要求折起来，整段在长按的预览里）
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

    /// 一集的菜单（「•••」和长按共用）：播放 / 继续播放 / 重看，有进度时「从头播放」（C45）
    @ViewBuilder private func episodeMenu(_ f: EpisodeFile, index i: Int, done: Bool, partial: Bool) -> some View {
        Button(done ? "重看这一集" : (partial ? "继续播放" : "播放这一集"), systemImage: "play.fill") { play(index: i) }
        if partial {
            Button("从头播放", systemImage: "arrow.counterclockwise") {
                model.playback.finish(f.path)
                play(index: i)
            }
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
            .foregroundStyle(DSInk.secondary)
            // 点得到的高度够 44（F74），版面上收回去，标题行不因此变高（F12）
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .padding(.vertical, -12)
        // 旁白：「选择季，第 1 季」（以前念「第 1 季」再加上下箭头符号的名字）
        .accessibilityLabel("选择季")
        .accessibilityValue(Self.seasonName(current))
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
        return loading ? "播放第 1 集" : "暂无可播放的剧集"
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

    /// 「影片详细信息」那几块（用户要求只留四样）：首播时间（和这一季）、每集时长、流量能效（按这一季的分集平均）、推荐等级；
    /// 版式是天气 App 那种方块（DetailStatsGrid）。不写「全 8 集」「更新至第 5 集」这类集数（用户要求全局去掉计数）；没有片长就没有时长那一块
    private func stats(_ m: Meta?) -> DetailStats {
        var s = DetailStats()
        let day = DetailFacts.day(m?.releaseDate)
        let y = year(m).flatMap { Int($0) }
        if day != nil || y != nil { s.release = DetailStats.Release(date: day, year: y, verb: "首播", season: current.seasonLabel) }
        if let r = m?.runtime, r > 0 { s.runtime = DetailStats.Runtime(minutes: r, perEpisode: true) }
        let sizes = files.compactMap(\.size).filter { $0 > 0 }
        let avg: Int64? = sizes.isEmpty ? nil : sizes.reduce(0, +) / Int64(sizes.count)
        s.efficiency = DetailFacts.efficiency(bytes: avg, minutes: m?.runtime)
        if let r = m?.rating, r > 0 { s.rating = r }
        return s
    }

    /// 「更多××剧集 ›」：同类型的几部剧（同一部剧的别的季不算，一部只出一次）
    private func related(_ m: Meta?) -> DetailRelated? {
        guard let g = m?.genres?.first else { return nil }
        let mine = current.tmdbId ?? m?.id
        var seen = Set<String>()
        var items: [DetailRelatedItem] = []
        for s in model.series(inGenre: g) {
            let sm = model.seriesMetas[s.path]
            let key = (s.tmdbId ?? sm?.id).map { "t\($0)" } ?? "n" + s.name
            if let mine, (s.tmdbId ?? sm?.id) == mine { continue }
            if s.name == current.name || !seen.insert(key).inserted { continue }
            items.append(DetailRelatedItem(id: s.path, title: sm?.title ?? s.name,
                                           subtitle: DetailText.line([s.year, sm?.genres?.first, DetailText.rating(sm?.rating)]),
                                           art: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w342"), route: .series(s)))
            if items.count == 3 { break }
        }
        guard !items.isEmpty else { return nil }
        return DetailRelated(title: "更多\(g)剧集", route: .shelf(.genre(g)), items: items)
    }

    /// 预告片卡的画面（Apple 给了这段预告片自己的画面就不用这个），见 DetailMediaArt.trailerArt
    private func trailerArt(_ m: Meta?) -> [String] {
        let stills = (m?.stills ?? []).compactMap { $0.url ?? $0.thumb }.filter { !$0.isEmpty }
        let wide = AppleImage.sized(atv?.background, width: 1280) ?? m?.backdropClean ?? m?.backdrop
        return DetailMediaArt.trailerArt(wide: wide, stills: stills)
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
            failed = "无法载入剧集。" + FriendlyError.message(error)
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

/// 点开的是第几张剧照
struct DetailStillPick: Identifiable {
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
    /// 「简介」卡：类型（弹层里用）、整段简介、导演
    let genres: [String]
    let overview: String?
    let director: String?
    /// 「影片详细信息」那几块（DetailInfo.swift 的 DetailStatsGrid）
    let stats: DetailStats
    /// 「更多××」那一张卡
    let related: DetailRelated?
    /// 顶上钉住的那一条里的小海报
    let thumb: URL?
    let cast: [CastMember]
    let trailers: [Trailer]
    /// 预告片卡的画面（轮着用）
    let trailerArt: [String]
    /// 「剧照」那一排（TMDB 的剧照；两张以上才出这一段）
    var stills: [String] = []
    /// 弱网预先缓存（电影才有）：有就把「播放」换成「预先画面质量处理」/「立即播放」+ 圆形进度钮（PrecachePlayRow）
    var precache: DetailPrecache? = nil
    /// 下载角标看哪一部（电影才有）：在下载 / 下好了，那一行信息的右端一颗角标
    var downloadPath: String? = nil
    /// 换掉「播放」的那一块（片库里没有的那部：「请求添加」按钮 / 五步进度卡，RequestViews.swift）
    var customAction: AnyView? = nil
    /// 分集那一段（电影没有）：拿到当前宽度的版面尺寸再排
    @ViewBuilder var episodes: (DSMetrics) -> Episodes

    @State private var showTitle = false
    /// 头部画面底边的主色：整页跟着染（DetailPalette）
    @State private var edge: UIColor?
    @State private var castSheet: CastSheetRequest?
    /// 点开的是第几张剧照（全屏大图，从那张卡上放大出来）
    @State private var stillPick: DetailStillPick?
    @Namespace private var stillsNS
    /// 演员名单里点的那一位：收起弹层以后推进去
    @State private var personPush: CastMember?
    /// 字标粒子转场（用户要求：往下滚，头部大字标化成粒子飞进顶上那条，往回滚原路拼回来）：进度和两个框放在一个小对象里，
    /// 每一帧只让读它的几小块（粒子层、钉住的条、头部字标）重画，整页不跟着每帧重算
    @State private var motion = DetailLogoMotion()
    /// 处理好的字标图（和 LogoImage 同一条管线、同一份缓存）：粒子从它的形状和颜色上取样，条里的小字标也画它；没有就是以前的样子
    @State private var logoImage: UIImage?
    /// logoImage 是哪一枚字标的（回到这一页时同一枚就不重取，见 loadLogo）
    @State private var logoImageURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            // 横着的一排（简介卡、分集、预告片、演员）一直铺到侧边那一列底下
            let m = DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing, height: geo.size.height)
            // 整个窗口：把顶上的状态栏 / 导航栏、底下的标签栏、侧边那一列加回来（画面从屏幕最顶上开始、连同侧边那一列一起平铺）
            let fullH = geo.size.height + insets.top + insets.bottom
            let fullW = geo.size.width + insets.leading + insets.trailing
            let heroH = Self.heroHeight(width: fullW, height: fullH)
            // 系统栏压住的那一截（展开横拿、外屏时栏在侧边一列，顶上几乎没有：D5、D6）
            let barBottom = geo.safeAreaInsets.top
            // 「播放」那一行滚到顶上那条底下时，顶上钉住一条：海报、片名、「播放」（参考图）
            let pinAt: CGFloat = heroH - 32 - 52 - barBottom - 66
            let palette = DetailPalette.from(edge)
            // 头部字标实际画多大（和 LogoImage 同一个算法）；条里那一格是它的 42%，同比例、同左边距（用户要求）
            let heroLogo: CGSize? = logoImage.map { Self.logoSize($0, box: Self.heroLogoBox(m)) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(m, width: fullW, height: heroH, insets: insets, barBottom: barBottom)
                    // 一组一行粗体标题 + 一张卡（参考图）；分区之间同一种留白（F3、F12）
                    VStack(alignment: .leading, spacing: m.shelfGap) {
                        if Self.twoColumns(m) && hasOverview && !stats.isEmpty {
                            // iPad 宽窗口（960 点以上）：简介和影片详细信息并排两栏，不再一张 720 宽的卡、右边空一大块。
                            // 影片详细信息那一栏定宽，方块和单栏时一行四块（720 宽、间距 12）一样大，(720 − 3×12) / 4 = 171；简介那一栏拿剩下的。
                            // 以前对半分，方块撑到近 300 点见方、字缩在角上，这一栏比简介高出几百点，下面整排都被往下推。
                            // 放得下一行四块（720）、简介还剩 420 点以上（Pro 13 横拿 1376）就一行，和简介差不多高；
                            // 再窄（普通 iPad、Pro 11 横拿，简介只剩两三百点）两块一行、两行。只有一两块时两块一行本来就只一行，不撑到 720
                            let gap = (m.gutter * 2.5).rounded()
                            let statTile: CGFloat = (720 - 3 * 12) / 4
                            let tileCount = [stats.release != nil, stats.runtime != nil, stats.efficiency != nil,
                                             DetailFacts.recommendation(stats.rating) != nil].filter { $0 }.count
                            let statsRow = tileCount > 2 && m.width - 2 * m.margin - gap - 720 >= 420
                            HStack(alignment: .top, spacing: gap) {
                                column(m, "简介") {
                                    DetailDescriptionCard(title: title, genres: genres, overview: overview ?? "",
                                                          director: director, palette: palette)
                                }
                                column(m, "影片详细信息") {
                                    DetailStatsGrid(stats: stats, palette: palette, wide: statsRow)
                                }
                                .frame(width: statsRow ? 720 : statTile * 2 + 12)
                            }
                            .padding(.horizontal, m.margin)
                        } else if hasOverview {
                            group(m, "简介") {
                                DetailDescriptionCard(title: title, genres: genres, overview: overview ?? "",
                                                      director: director, palette: palette)
                            }
                        }
                        episodes(m)
                        if !trailers.isEmpty || stills.count >= 2 { mediaSection(m) }
                        if !cast.isEmpty { castSection(m) }
                        if !stats.isEmpty && !(Self.twoColumns(m) && hasOverview) {
                            group(m, "影片详细信息") {
                                DetailStatsGrid(stats: stats, palette: palette, wide: m.wide)
                            }
                        }
                        if let related, !related.items.isEmpty {
                            group(m, related.title, route: related.route) {
                                DetailRelatedCard(related: related, palette: palette, wide: m.wide)
                            }
                        }
                    }
                    .padding(.top, 28)
                    .padding(.bottom, m.shelfGap)
                    // 下面的内容留在安全区里（卡往右滑出去时从侧边那一列底下过去）
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                }
                // 有字标转场时（用户要求：字标要能一路滚到落进条里）：页面再短也至少能滚 pinAt 那么远，
                // 进度只看滚了多远，简介、演员这些后到的内容把页面撑高时不会让停住的那一帧自己跳
                .frame(minHeight: logoImage != nil ? fullH + max(0, pinAt) : nil, alignment: .topLeading)
                // 整页的颜色：头部下面从画面的主色开始，往下慢慢沉到同色相的深色（参考图）
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: heroH)
                        LinearGradient(colors: [palette.base, palette.deep], startPoint: .top, endPoint: .bottom)
                            .frame(height: max(600, fullH * 1.4))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background(palette.deep)
            // 画面铺到状态栏、导航栏和侧边那一列底下（F6）；字和按钮还在安全区里（F7）
            .ignoresSafeArea(edges: [.top, .horizontal])
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > pinAt
            } action: { _, v in
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)) { showTitle = v }
            }
            // 字标粒子转场的进度（用户要求：跟着滚动走，停下就停在这一帧，往回滚原路倒回去）：
            // 0 = 没滚（字标在头部原位），1 = 滚到以前钉住那条出现的位置（字标已经落进条里）。
            // 只看滚动距离、不看页面多高（停住就是同一帧）；页面短的时候上面那个最小高度保证滚得到 1，粒子不会停在半路上
            .onScrollGeometryChange(for: Double.self) { g in
                let d = g.contentOffset.y + g.contentInsets.top
                return Double(min(1, max(0, d / max(1, pinAt))))
            } action: { _, v in
                motion.setProgress(v)
            }
            // 钉在顶上的条：从上面滑下来（参考图的「取得」那一条）；片名在这条里，导航栏里不再写
            .overlay(alignment: .top) {
                pinnedBar(m, insets: insets, barBottom: barBottom, palette: palette, heroLogo: heroLogo)
            }
            // 粒子层盖在整页和顶上那条上面（用户要求：字标化成细粒子，沿一条往右鼓的弧线飞进左上角再拼好）
            .overlay {
                particleLayer(heroLogo)
            }
        }
        .background(DetailPalette.from(edge).deep)
        // 字标粒子转场要的那张图：和 LogoImage 走同一条管线（深色反白、HDR），粒子直接从字标本身取样（用户要求）
        .task(id: logoURL) { await loadLogo() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // 全部演员：一张弹层，点演员在弹层里推进去，不叠第二层（C50、C56）
        .sheet(item: $castSheet) { r in
            CastSheet(people: cast) { m in
                // 名单里点一位：先收起弹层，再在详情页这一栈里推进那位演员的个人页
                castSheet = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(380))
                    personPush = m
                }
            }
        }
        // 推进去的每一页都要挂 duoHidesTabBar：以前这里没挂，iPhone Duo「侧边一列」的形态里一进演员页系统标签栏就回来了，
        // 回到详情页也不再藏，和侧边导航叠成两份（用户截图）
        .navigationDestination(item: $personPush) { m in ActorPage(member: m).duoHidesTabBar() }
        // 预告片：全屏（C49、S22），由 TrailerPlayerView.present 用 UIKit 弹——好管方向：除了 iPhone 展开一律横屏（用户要求）
        // 剧照：全屏黑底的大图，从点的那张卡上放大出来、收回到那张卡上（F57）
        .fullScreenCover(item: $stillPick) { p in
            DetailStillsViewer(stills: stillShown.map { TMDBImage.url($0, "w1280") }, index: p.index)
                .navigationTransition(.zoom(sourceID: p.index, in: stillsNS))
        }
    }

    /// 剧照浏览台里放出来的剧照（最多 12 张，和网页版一样）
    private var stillShown: [String] { Array(stills.prefix(12)) }

    private var hasOverview: Bool { !(overview ?? "").isEmpty }

    /// 钉在顶上的那一条。有字标（用户要求）：条不再整条滑下来，底色、字标、「继续播放」都跟着滚动进度走，
    /// 字标那一格是头部字标的 42%（同比例、同左边距）；没有字标（或字标图还没到手）和以前一样从上面滑下来
    @ViewBuilder
    private func pinnedBar(_ m: DSMetrics, insets: EdgeInsets, barBottom: CGFloat, palette: DetailPalette, heroLogo: CGSize?) -> some View {
        if let logoImage, let heroLogo {
            let slot = CGSize(width: heroLogo.width * 0.42, height: heroLogo.height * 0.42)
            let particles = logoParticles
            DetailLogoBarHost(motion: motion) { p, ready in
                // 粒子层画不出来（「减弱动态效果」、没有 Metal、框还没量到、粒子还没切好或画布出错：ready 是 DetailLogoMotion.handoff）时
                // 条里那枚跟着进度淡入，不会到 1 才突然冒出来
                DetailPinnedBar(title: title, thumb: thumb, logo: logoURL,
                                playTitle: playTitle, playDisabled: playDisabled, palette: palette,
                                topInset: barBottom, leading: insets.leading + m.margin, trailing: insets.trailing + m.margin,
                                onPlay: onPlay, logoImage: logoImage, logoSlot: slot, progress: p,
                                onLogoSlot: { r in motion.setSlot(r) }, crossFade: !(particles && ready))
            }
            .ignoresSafeArea(edges: [.top, .horizontal])
        } else {
            DetailPinnedBar(title: title, thumb: thumb, logo: logoURL,
                            playTitle: playTitle, playDisabled: playDisabled, palette: palette,
                            topInset: barBottom, leading: insets.leading + m.margin, trailing: insets.trailing + m.margin,
                            onPlay: onPlay)
                // 「减弱动态效果」时只淡入淡出、不从上面滑下来（F59；以前只换了曲线，照样滑 100 多点）
                .offset(y: showTitle || reduceMotion ? 0 : -(barBottom + 90))
                .opacity(showTitle ? 1 : 0)
                .allowsHitTesting(showTitle)
                .accessibilityHidden(!showTitle)
                .ignoresSafeArea(edges: [.top, .horizontal])
        }
    }

    /// 字标的粒子层：铺满整个窗口，不接手势、旁白不念；「减弱动态效果」或画不出来时不放粒子（两枚字标交叉淡入淡出），没有字标就没有这一层
    @ViewBuilder
    private func particleLayer(_ heroLogo: CGSize?) -> some View {
        if let logoImage, let heroLogo, logoParticles {
            DetailLogoParticleLayer(motion: motion, image: logoImage, heroSize: heroLogo)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 放不放粒子（用户要求的字标粒子转场）：没开「减弱动态效果」、这台设备有 Metal、字标图能取样（粒子层要 CGImage）。
    /// 放不了就是两枚真字标跟着进度交叉淡入淡出：头部字标不会在半路上藏起来却没有粒子顶上
    private var logoParticles: Bool {
        !reduceMotion && DetailLogoGPU.available && logoImage?.cgImage != nil
    }

    /// 这一页的字标地址（头部、条里、粒子层都是这一张）；没有字标是 nil
    private var logoURL: URL? { art?.logo.flatMap { $0.isEmpty ? nil : TMDBImage.url($0, "w500") } }

    /// 取处理好的字标图：和 LogoImage 同一套步骤（原图 → 判明暗 → 字标管线），都命中同一份缓存，不多走网络。
    /// 取不到就一直是 nil：整页照以前的样子（条整条滑下来）
    private func loadLogo() async {
        guard let url = logoURL else { logoImage = nil; logoImageURL = nil; return }
        // .task 每回到这一页都会再跑一遍：这一枚字标图已经在手就不换。内存里那份被清过的话拿回来的是另一张，
        // 粒子层得重切一遍，这段时间里只能交叉淡入淡出
        if logoImage != nil, logoImageURL == url { return }
        LogoHDR.prepare()
        if let d = LogoTone.shared.cached(url), let hit = ImagePipeline.shared.cachedLogo(url, dark: d) {
            setLogoImage(hit, for: url)
            return
        }
        guard await ImagePipeline.shared.image(url, maxPixel: ImagePipeline.logoPixel) != nil, !Task.isCancelled else { return }
        let d = await LogoTone.shared.isDark(url)
        let img = await ImagePipeline.shared.logo(url, dark: d)
        guard !Task.isCancelled else { return }
        setLogoImage(img, for: url)
    }

    private func setLogoImage(_ img: UIImage?, for url: URL) {
        logoImage = img
        logoImageURL = img == nil ? nil : url
        // 设备日志里看得出这一页为什么没有粒子（用户真机「详情页海报 logo 没有粒子特效」）：只记三个开关，不记片名、地址
        if let img, reduceMotion || !DetailLogoGPU.available || img.cgImage == nil {
            Perf.log("detail logo: particles off (reduce motion \(reduceMotion), metal \(DetailLogoGPU.available), bitmap \(img.cgImage != nil))")
        }
    }

    /// 头部字标那一格：高（展开 96、折起 72）和最宽（屏宽七成、最多 360）
    static func heroLogoBox(_ m: DSMetrics) -> (height: CGFloat, maxWidth: CGFloat) {
        (m.wide ? 96 : 72, min(m.width * 0.7, 360))
    }

    /// 字标实际画出来多大：和 LogoImage 同一个算法（统一高度，超出最宽才按宽收）
    static func logoSize(_ image: UIImage, box: (height: CGFloat, maxWidth: CGFloat)) -> CGSize {
        let aspect = max(0.1, image.size.width / max(1, image.size.height))
        let h = min(box.height, box.maxWidth / aspect)
        return CGSize(width: h * aspect, height: h)
    }

    /// iPad 宽窗口（960 点以上）：简介、影片详细信息并排
    /// 960 点（不是 1100）：13 寸横拿时侧边栏占去约 320 点，详情页只剩约 1050 点宽，1100 的门槛会把最大的 iPad 排成单栏（CI 截图）；
    /// 960 时简介那一栏仍有约 460 点（右边 2×2 的影片详细信息 354 点）
    static func twoColumns(_ m: DSMetrics) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && m.width >= 960
    }

    // MARK: 头部

    /// 头部一样高（用户要求：统一高度，比画面稍高）：竖着的屏九成屏高，横着的屏九成二；画面只占上面那一截
    static func heroHeight(width w: CGFloat, height h: CGFloat) -> CGFloat {
        // iPad：竖拿约三分之二、横拿约八成屏高（满屏的头部在 11 / 13 寸上太高，往下滑半天才到简介）
        if UIDevice.current.userInterfaceIdiom == .pad { return max(420, (h * (h > w ? 0.66 : 0.78)).rounded()) }
        return max(420, (h * (h > w ? 0.9 : 0.92)).rounded())
    }

    /// 左下那一列字（字标格 + 一行信息 + 按钮）大约多高
    static func blockHeight(_ m: DSMetrics) -> CGFloat { m.wide ? 192 : 168 }

    private func hero(_ m: DSMetrics, width: CGFloat, height: CGFloat, insets: EdgeInsets, barBottom: CGFloat) -> some View {
        // 头部比宽还高就用竖版全屏图，否则用 16:9（和首页头图同一条规则：S15）。
        // 画面连同下段那一截渐进式模糊，刚好收在字标上沿（用户要求：模糊落在字标上方那条线上）：
        // 字块离底 32、高 blockHeight，画面底边比字块顶边低 16（字标在格子里靠下放，看得见的上沿还要再低一点）
        let tall = height > width
        let imageH = min((height * 0.85).rounded(), max((height * 0.5).rounded(), (height - 32 - Self.blockHeight(m) + 16).rounded()))
        let pick = art.flatMap { tall ? ($0.tall ?? $0.wide) : ($0.wide ?? $0.tall) }
        // 字块的顶边从栏底下 40 点开始淡，升到栏底上方 40 点时淡完（没滚动时字块离栏底远得多，是全亮的）
        let fadeFrom = barBottom - 40
        return ZStack(alignment: .bottomLeading) {
            DetailHeroBackdrop(url: TMDBImage.url(pick, "w1280"), width: width, height: height, imageHeight: imageH) { e in
                if edge != e { withAnimation(.easeInOut(duration: 0.8)) { edge = e } }
            }
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
        let box = Self.heroLogoBox(m)
        let logoH: CGFloat = box.height
        return VStack(alignment: .leading, spacing: 12) {
            // 字标那一格：画面和字标定下来之前空着（占住位置，下面的字不跳），定了模糊淡入；以后不再换
            ZStack(alignment: .bottomLeading) {
                if let art {
                    if let logo = art.logo, !logo.isEmpty {
                        // 字标粒子转场（用户要求）：一开始往下滚（p > 0）这枚真字标就藏起来，交给粒子层（同一张图、同一个框）；
                        // 滚回顶上（p = 0）再亮出来。粒子层画不出来时不藏，跟着进度淡出。旁白照样念它（外面那层元素不跟着藏），它还是这一页的标题
                        DetailHeroLogoGate(motion: motion, active: logoImage != nil, crossFade: !logoParticles) {
                            LogoImage(url: TMDBImage.url(logo, "w500"), height: logoH, alignment: .leading,
                                      fallback: title, maxWidth: box.maxWidth)
                        }
                        // 量它在窗口里的框：粒子从这里出发（跟着页面往上走）。
                        // 字标已经落进条里、这一块又滚出了屏幕顶上（在看演员、分集）时不再每帧写：粒子层不跟着整页滚动重算；
                        // 滚回来一露头就接着写（那时进度还是 1，粒子层要用它之前已经是新的）
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { r in
                            if motion.progress >= 1, r.maxY < 0, r.size == motion.heroBox.size { return }
                            motion.setHeroBox(r)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(title)
                        .accessibilityAddTraits(.isHeader)
                        // 透明底的模糊淡入：不透明的模糊会把字标四周的透明糊成一块黑框（「字标闪一下」）
                        .transition(.dsBlurFadeClear())
                    } else {
                        Text(title)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .accessibilityAddTraits(.isHeader)
                            .transition(.dsBlurFadeClear())
                    }
                } else {
                    Color.clear.frame(height: logoH)
                }
            }
            .animation(.easeInOut(duration: 0.6), value: art)
            // 一行信息；这一部在下载 / 下好了，右端一颗下载角标（用户要求：详情页合适的角落）
            if !metaLine.isEmpty || downloadPath != nil {
                HStack(alignment: .center, spacing: 8) {
                    if !metaLine.isEmpty {
                        Text(metaLine)
                            .font(.subheadline)
                            .foregroundStyle(DSInk.secondary)
                            .lineLimit(1)
                            // 旁白不念「黑星」和间隔号：「爱情，2024，1 小时 38 分钟，评分 7.0」
                            .accessibilityLabel(DetailText.spoken(metaLine))
                    }
                    Spacer(minLength: 8)
                    if let downloadPath { DownloadBadge(path: downloadPath, size: 24) }
                }
            }
            HStack(spacing: 12) {
                if let customAction {
                    customAction
                } else if let precache {
                    // 网络不好 / 网络速度低于 50%：「预先画面质量处理」，按了变成「立即播放」+ 右边一颗圆形进度钮（用户要求）
                    PrecachePlayRow(precache: precache, wide: m.wide, playID: playID, playDisabled: playDisabled, onPlay: onPlay)
                } else {
                    playButton(m)
                }
                // 「…」里只剩「从头播放」：有进度才出现（发行版不再有「分享」「复制直链」这类站外操作）
                if onRestart != nil { moreMenu }
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

    /// 「…」：系统菜单，符号是不带圈的 ellipsis（C11、C15、C45）；底是一层 Liquid Glass，像 tvOS 没聚焦的钮（S17、C35）。
    /// 设计轮 2（并行·detail）：以前是 thinMaterial 的灰圆，在染了色的页面上发闷、按下也没有反馈；玻璃只给控件（F38），
    /// 按下是玻璃自带的回弹，和钉住那一条的「播放」、演员页的圆钮同一种。
    /// 菜单项都带 SF Symbol（F50），常用的在前（C41）；没有的项不出现
    private var moreMenu: some View {
        Menu {
            if let onRestart {
                Button("从头播放", systemImage: "arrow.counterclockwise", action: onRestart)
                    .accessibilityIdentifier("detail-restart")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: Circle())
                .environment(\.colorScheme, .dark)
                .contentShape(Circle())
        }
        .accessibilityLabel("更多")
        .accessibilityIdentifier("detail-more")
    }

    // MARK: 分区

    /// 一组：粗体标题（可以带「›」）+ 一张卡；卡在展开的屏上最宽 720，不拉满一整行。
    /// 标题到卡和标题到一排卡同一个距离（设计轮 2）：titleGap + 4（一排卡上下各垫 4），折起 16、展开 20
    private func group<Content: View>(_ m: DSMetrics, _ title: String, route: Route? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.titleGap + 4) {
            DetailGroupTitle(title: title, route: route)
            content()
                .frame(maxWidth: 720, alignment: .leading)
        }
        .padding(.horizontal, m.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 并排两栏里的一栏：标题 + 卡。影片详细信息那一栏外面给定宽，简介这一栏拿剩下的（外面那一层管左右边距）
    private func column<Content: View>(_ m: DSMetrics, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.titleGap + 4) {
            DetailGroupTitle(title: title, route: nil)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 预告片与剧照（用户要求：两样现在是同一种卡，合成一组、不再分开，同一横排里用间距分开）：
    /// 先是预告片（点一张全屏放，从这一段开始，左右滑换下一段），隔一段宽一点的空（卡间距的 2.5 倍），再是剧照（点一张全屏看大图，
    /// 从这张卡上放大出来）。卡都是 16:9、字压在渐进式模糊上（DSMediaCard），剧照两张以上才放、最多 12 张。
    /// 那段空放在最后一张预告片的右边：滑到剧照时第一张剧照照样停在左边线上。
    /// 修（用户截图：这一排中间空出一张卡的位置、停的位置不对）：以前两样各一个 ForEach、都拿序号当 id，预告片 0 号和剧照 0 号
    /// 在同一个 LazyHStack 里撞了 id——「第 1 幕」那张根本不画出来，按卡对齐的停位也跟着算错。现在一个 ForEach，id 是「t0」「s0」这样分开的
    private func mediaSection(_ m: DSMetrics) -> some View {
        let shown = stills.count >= 2 ? stillShown : []
        // 不叫 title：会把这一页的片名（self.title，全屏预告片的标题要用它）挡住
        let sectionTitle = !trailers.isEmpty && !shown.isEmpty ? "预告片与剧照" : (trailers.isEmpty ? "剧照" : "预告片")
        let groupGap = (m.gutter * 1.5).rounded()
        let items = trailers.indices.map { DetailMediaItem.trailer($0) } + shown.indices.map { DetailMediaItem.still($0) }
        return DSSection(title: sectionTitle, metrics: m) {
            DSShelf(metrics: m) {
                ForEach(items) { item in
                    switch item {
                    case .trailer(let i):
                        let t = trailers[i]
                        DetailTrailerCard(trailer: t, art: t.image ?? (trailerArt.isEmpty ? nil : trailerArt[i % trailerArt.count]),
                                          metrics: m, onPlay: { TrailerPlayerView.present(movieTitle: title, trailers: trailers, start: i) })
                            .padding(.trailing, i == trailers.count - 1 && !shown.isEmpty ? groupGap : 0)
                    case .still(let i):
                        DetailStillCard(art: TMDBImage.url(shown[i], "w1280"), title: "第 \(i + 1) 幕", detail: "剧照",
                                        metrics: m) { stillPick = DetailStillPick(index: i) }
                            .matchedTransitionSource(id: i, in: stillsNS)
                    }
                }
            }
        }
    }

    /// 演员：标题「演员 ›」点开全部名单；下面一排圆形照片（T21 monogram），点一位直接看那一位。
    /// 标题到照片和「预告片」「剧照」一样是 titleGap（设计轮 2：以前 6，比别的分区挤 6–10 点）
    private func castSection(_ m: DSMetrics) -> some View {
        let d = (m.posterWidth * 0.86).rounded()
        return VStack(alignment: .leading, spacing: m.titleGap) {
            DetailLinkHeader(title: "演员", metrics: m, id: "cast-link") {
                castSheet = CastSheetRequest(start: nil)
            }
            DSShelf(metrics: m) {
                ForEach(Array(cast.prefix(20).enumerated()), id: \.offset) { i, c in
                    // 点一位：推进这位演员的个人页（从这张圆照片上放大出来）
                    ZoomLink(route: .person(c), slot: "cast-\(i)") {
                        DetailMonogram(member: c, diameter: d, metrics: m)
                    }
                    .accessibilityIdentifier("cast-card")
                }
            }
        }
    }

}

// MARK: - 字标粒子转场（用户要求：滚动驱动，头部大字标 → 顶上条里的小字标）

/// 这台设备能不能跑粒子层（有 Metal）：没有就不放粒子，两枚真字标交叉淡入淡出（用户要求：半路上字标不能凭空没了）
enum DetailLogoGPU {
    static let available: Bool = MTLCreateSystemDefaultDevice() != nil
}

/// 转场的滚动状态：DetailScaffold 在滚动 / 排版回调里写，粒子层、钉住的条、头部字标读。
/// 单独一个可观察的小对象：每一帧只有读它的那几小块重画，整页（DetailScaffold）不跟着每帧重算
@MainActor @Observable
final class DetailLogoMotion {
    /// 0 = 字标在头部原位，1 = 字标已经落进顶上的条（滚到以前钉住那条出现的位置）
    private(set) var progress: Double = 0
    /// 已经离开原位（p > 0）：头部真字标藏起来，交给粒子层。单独一个开关：头部那一块只在它翻转时重画
    private(set) var moving = false
    /// 头部字标（LogoImage 那一块，字标靠左下画在里面）在窗口里的框
    private(set) var heroBox: CGRect = .zero
    /// 顶上条里字标那一格在窗口里的框（粒子的落点）
    private(set) var slot: CGRect = .zero
    /// 两个框都量到了。没量到之前头部字标不藏（跟着进度淡出），不会半路上两头都没有。
    /// 单独一个开关：头部那一块、条只在它翻转时重画，不跟着每帧的框
    private(set) var ready = false
    /// 粒子层自己说画得出来（LogoParticleField 的 onReady：Metal 建好、粒子切好、这块画布真交出去过一帧）。
    /// 以前只看两个框量到没有：粒子层哪一步没过（用户真机 iPhone Duo），往下滚头部字标照样藏起来，粒子却没出来——字标凭空没了，
    /// 条里那枚到 1 才突然冒出来。现在没到 true 之前、或者画到一半说了 false，两枚真字标都跟着进度交叉淡入淡出
    private(set) var canvasReady = false
    /// 粒子层说画得出来的时候正滚在半路上（0 < p < 1）：等回到顶上或者落定再换成粒子，不从交叉淡入淡出半路上一下跳成粒子
    @ObservationIgnored private var canvasPending = false
    /// 「这一页在交叉淡入淡出」只记一次日志
    @ObservationIgnored private var loggedFallback = false

    /// 头部字标在 p > 0 时藏起来、条里那枚等到 1 才出来（交给粒子层）：两个框都量到了，粒子层也画得出来
    var handoff: Bool { ready && canvasReady }

    func setProgress(_ p: Double) {
        if progress != p { progress = p }
        let m = p > 0
        if moving != m {
            moving = m
            // 设备日志里看得出这一页为什么没有粒子（只记开关，不记片名）
            if m, !handoff, !loggedFallback {
                loggedFallback = true
                Perf.log("detail logo: cross-fading the real logos (frames measured \(ready), particle canvas ready \(canvasReady))")
            }
        }
        if canvasPending, p <= 0 || p >= 1 {
            canvasPending = false
            canvasReady = true
        }
    }

    /// LogoParticleField.onReady：false 马上生效（两枚真字标交叉淡入淡出）；true 在半路上就等到两头再生效
    func setCanvasReady(_ r: Bool) {
        guard r else {
            canvasPending = false
            if canvasReady { canvasReady = false }
            return
        }
        guard !canvasReady else { return }
        if progress > 0 && progress < 1 {
            canvasPending = true
        } else {
            canvasReady = true
        }
    }

    func setHeroBox(_ r: CGRect) {
        if heroBox != r { heroBox = r }
        syncReady()
    }

    func setSlot(_ r: CGRect) {
        if slot != r { slot = r }
        syncReady()
    }

    private func syncReady() {
        let r = heroBox.width > 0 && heroBox.height > 0 && slot.width > 0 && slot.height > 0
        if ready != r { ready = r }
    }
}

/// 头部的真字标：p > 0 时藏起来（粒子层在画同一张图）；不放粒子（「减弱动态效果」、画不了）或粒子层还画不出来
/// （框没量到、粒子还在切、画布出错）时不藏，跟着进度淡出（条里那枚同时淡入）
private struct DetailHeroLogoGate<Content: View>: View {
    let motion: DetailLogoMotion
    /// 转场开着（字标图到手了）；没开就和以前一样一直显示
    let active: Bool
    /// 不放粒子：两枚真字标交叉淡入淡出
    let crossFade: Bool
    let content: Content

    init(motion: DetailLogoMotion, active: Bool, crossFade: Bool, @ViewBuilder content: () -> Content) {
        self.motion = motion
        self.active = active
        self.crossFade = crossFade
        self.content = content()
    }

    var body: some View {
        content.opacity(shown)
    }

    private var shown: Double {
        guard active else { return 1 }
        if crossFade || !motion.handoff { return 1 - motion.progress }
        return motion.moving ? 0 : 1
    }
}

/// 有字标时钉住的那一条：按当下的进度现做（只有这一小块每帧重画）；第二个参数是粒子层画不画得出来
/// （两个框量到了、粒子层也说画得出来：DetailLogoMotion.handoff）
private struct DetailLogoBarHost: View {
    let motion: DetailLogoMotion
    let bar: (Double, Bool) -> DetailPinnedBar

    var body: some View {
        let p = motion.progress
        bar(p, motion.handoff)
            // 字标落定、「继续播放」出齐了才接手势、旁白才念这一条（没有字标时是看钉住那条有没有出来）
            .allowsHitTesting(p >= 1)
            .accessibilityHidden(p < 1)
    }
}

/// 粒子层：从头部字标（跟着页面走的那个框）飞到条里那一格；两个框都是 SwiftUI 的 .global。
/// 框还没量到、或者粒子层还没说画得出来时进度给 0（什么都不画；头部字标这时也不藏，两枚真字标交叉淡入淡出）
private struct DetailLogoParticleLayer: View {
    let motion: DetailLogoMotion
    let image: UIImage
    /// 头部字标实际画出来的大小（在 LogoImage 那一块里靠左下）
    let heroSize: CGSize

    var body: some View {
        let box = motion.heroBox
        let slot = motion.slot
        let p = motion.progress
        let live = motion.handoff && heroSize.width > 0 && heroSize.height > 0
        let from = CGRect(x: box.minX, y: box.maxY - heroSize.height, width: heroSize.width, height: heroSize.height)
        // 画布自己的左上角也在 .global 里量（和两个框同一个坐标系）：详情页嵌在别的宿主里（导航栈、缩放转场、Duo 侧边一列）时，
        // UIKit 的窗口坐标和 SwiftUI 的 .global 可能差一截，粒子和两枚字标会整体偏出画布
        GeometryReader { g in
            LogoParticleField(image: image, from: from, to: slot, progress: live ? p : 0,
                              origin: g.frame(in: .global).origin,
                              onReady: { motion.setCanvasReady($0) })
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
    /// 取到画面底边的主色：告诉详情页，整页跟着染（DetailPalette）
    var onEdge: (UIColor) -> Void = { _ in }
    @State private var shown: Shown?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Shown: Equatable {
        let key: String
        let art: HeroArt
        static func == (a: Shown, b: Shown) -> Bool { a.key == b.key }
    }

    /// 处理好的头部画面内存里已经有（再打开同一部片）：第一次画就直接是它，不闪底色、不再淡入
    init(url: URL?, width: CGFloat, height: CGFloat, imageHeight: CGFloat, onEdge: @escaping (UIColor) -> Void = { _ in }) {
        self.url = url
        self.width = width
        self.height = height
        self.imageHeight = imageHeight
        self.onEdge = onEdge
        if let url, let art = ImagePipeline.shared.cachedHeroArt(url, maxPixel: Self.pixels(width, imageHeight),
                                                                 aspect: width / max(1, imageHeight)) {
            _shown = State(initialValue: Shown(key: Self.key(url, width, imageHeight), art: art))
        }
    }

    private static func pixels(_ w: CGFloat, _ h: CGFloat) -> CGFloat { min(2400, max(w, h) * 3) }
    private static func key(_ url: URL?, _ w: CGFloat, _ h: CGFloat) -> String { "\(url?.absoluteString ?? "")#\(Int(w))x\(Int(h))" }

    var body: some View {
        // 画面化进去的颜色就是整页的颜色（DetailPalette.base）：头部底下和下面的卡接得上
        let tone = DetailPalette.baseColor(shown?.art.edge)
        let imgEnd = min(1, imageHeight / max(1, height))
        let key = Self.key(url, width, imageHeight)
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
            // 画面最下面那一段化进底色：和画面里那段渐进式模糊在同一截（画面高的 83% 起，到底边——也就是字标上沿），看不出接缝
            LinearGradient(stops: Self.dissolve(tone, from: imgEnd * 0.83, to: imgEnd), startPoint: .top, endPoint: .bottom)
            // 顶上浅浅压暗：状态栏和返回钮停在画面上也看得清（F34）
            LinearGradient(colors: [.black.opacity(0.38), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.18))
        }
        .frame(width: width, height: height)
        .animation(.easeInOut(duration: 0.8), value: shown?.key)
        .onAppear { if let s = shown { onEdge(s.art.edge) } }
        .onChange(of: shown?.key) { _, _ in if let s = shown { onEdge(s.art.edge) } }
        .task(id: key) {
            guard let url else { return }
            if shown?.key == key { return }
            let aspect = width / max(1, imageHeight)
            guard let art = await ImagePipeline.shared.heroArt(url, maxPixel: Self.pixels(width, imageHeight), aspect: aspect),
                  !Task.isCancelled else { return }
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
/// （时长 Apple 给了就用，没给就读一下这段预告片的播放列表：TrailerLength）；「•••」里是播放
/// 预告片与剧照那一排里的一张卡。两样在同一个 LazyHStack 里，id 必须分开（「t0」「s0」）：以前都用序号，同号的撞了，剧照不出来
enum DetailMediaItem: Identifiable, Hashable {
    case trailer(Int)
    case still(Int)

    var id: String {
        switch self {
        case .trailer(let i): return "t\(i)"
        case .still(let i): return "s\(i)"
        }
    }
}

enum DetailMediaArt {
    /// 预告片卡轮着用的画面（Apple 没给这段预告片画面时）。剧照现在和预告片在同一排，第一张预告片不能再借第一张剧照
    /// （用户截图：同一张图在这一排里出现两次）：先用无字的横版背景，再用剧照那一段放不下的（第 shown + 1 张起），
    /// 最后才从剧照末尾往前借；同一张只用一次
    static func trailerArt(wide: String?, stills: [String], shown: Int = 12) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let pool = [wide].compactMap { $0 } + Array(stills.dropFirst(shown)) + Array(stills.prefix(shown).reversed())
        for s in pool where !s.isEmpty && seen.insert(s).inserted { out.append(s) }
        return out
    }
}

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
            DSSectionLabel(title: title, chevron: true)
                // 点得到的高度够 44（F74），版面上收回去，和别的分区标题一样高（F12）
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .padding(.vertical, -10)
        .padding(.horizontal, metrics.margin)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint("查看全部")
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
                    .foregroundStyle(.white)
                // 角色和页上别的第二行同一级灰（DSInk.secondary 72%；以前是系统 .secondary，约 60%，染色的底上偏暗）
                Text(role.isEmpty ? " " : role)
                    .font(.caption)
                    .foregroundStyle(DSInk.secondary)
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
    /// 「剧照」那一排：TMDB 的剧照（大图地址，没有就用缩略图的）
    static func stills(_ m: Meta?) -> [String] {
        (m?.stills ?? []).compactMap { $0.url ?? $0.thumb }.filter { !$0.isEmpty }
    }

    /// 几段字用「 · 」连起来，空的跳过
    static func line(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 给旁白念的（设计轮 2）：「 · 」换成停顿，「★ 7.5」念成「评分 7.5」（不念「黑星」「间隔号」）
    static func spoken(_ s: String) -> String {
        s.replacingOccurrences(of: "★ ", with: "评分 ").replacingOccurrences(of: " · ", with: "，")
    }

    /// 「★ 7.5」：没有评分就是 nil
    static func rating(_ r: Double?) -> String? {
        guard let r, r > 0 else { return nil }
        return String(format: "★ %.1f", r)
    }

    /// 放得了的预告片：和 AppModel.trailers(for:) 同一条规矩（订阅才看得了的不要）
    static func playable(_ t: [Trailer]?) -> [Trailer] {
        (t ?? []).filter { !$0.hls.isEmpty && !$0.hls.contains("/subscription/") }
    }
}


