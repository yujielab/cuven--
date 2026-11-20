import Foundation

// MARK: - 半折面板下面那块（PlayerInfoDeck）的内容：从片库、TMDB 和看过的记录里拼出来
//
// PlayerCoordinator 每开始一集调一次（换集、接着放下一集都是）；剧集的分集标题、简介要再问一次 TMDB 的这一季，晚一点补上。
// 「继续观看」的画面和剩余时间的说法和主页那一排是同一套（HomeView 也用这里的）。

@MainActor
enum PlayerPanelData {
    // MARK: 简介 + InSight

    static func info(for req: PlayRequest, model: AppModel) -> PlayerInfo {
        var info = PlayerInfo()
        info.badges = FileName.specs(req.name)
        if let sp = req.seriesPath {
            let s = model.series.first { $0.path == sp }
            let meta = model.seriesMetas[sp]
            info.heading = req.subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? req.episode.map { "第 \($0) 集" } ?? req.title
            info.overview = meta?.overview
            info.facts = [meta?.genres?.first, s?.seasonLabel, req.episode.map { "第 \($0) 集" }].compactMap { $0 }
            info.cast = cast(meta)
            info.canGoToShow = s != nil
        } else {
            let v = model.video(path: req.path)
            let meta = v.flatMap { model.meta($0) }
            info.heading = v.map { model.title($0) } ?? req.title
            info.overview = meta?.overview
            info.facts = [meta?.genres?.first, v.flatMap { model.year($0) }.map(String.init),
                          meta?.runtime.flatMap { $0 > 0 ? Format.runtime($0) : nil }].compactMap { $0 }
            info.cast = cast(meta)
            info.canGoToShow = v != nil
        }
        return info
    }

    /// 晚一点补上的：剧集是这一集的标题、简介、时长（TMDB 的这一季）；电影是全量资料里的演员表和简介
    static func refine(_ info: PlayerInfo, for req: PlayRequest, model: AppModel) async -> PlayerInfo? {
        var out = info
        if let sp = req.seriesPath {
            guard let id = model.seriesMetas[sp]?.id, let ep = req.episode else { return nil }
            let season = model.series.first { $0.path == sp }?.season ?? 1
            guard let eps = try? await APIClient.shared.season(tmdbId: id, season: season),
                  let e = eps.first(where: { $0.ep == ep }) else { return nil }
            if let n = e.name, !n.isEmpty { out.heading = n }
            if let o = e.overview, !o.isEmpty { out.overview = o }
            if let r = e.runtime, r > 0 { out.facts.append(Format.runtime(r)) }
        } else {
            guard info.cast.isEmpty || info.overview == nil, let v = model.video(path: req.path),
                  let full = await model.fullMeta(for: v) else { return nil }
            if out.overview == nil { out.overview = full.overview }
            if out.cast.isEmpty { out.cast = cast(full) }
        }
        return out == info ? nil : out
    }

    private static func cast(_ meta: Meta?) -> [PlayerCastItem] {
        (meta?.cast ?? []).prefix(16).map { c in
            PlayerCastItem(id: "\(c.id ?? 0)-\(c.name)", name: c.name, role: c.character,
                           photo: TMDBImage.url(c.profilePath, "w185"))
        }
    }

    // MARK: 继续观看

    static func continueItems(excluding req: PlayRequest, model: AppModel) -> [PlayerShelfItem] {
        model.playback.continueWatching
            .filter { $0.path != req.path && ($0.seriesPath == nil || $0.seriesPath != req.seriesPath) }
            .prefix(12)
            .map { e in
                let art = continueArt(e, model: model)
                return PlayerShelfItem(id: e.path, title: e.title, subtitle: remainingLabel(e), art: art.url, logo: art.logo,
                                       progress: e.fraction)
            }
    }

    /// 继续观看的画面：电影按片库里的那一部取（Apple TV 无字背景 + 字标优先：AppModel.wideLockupArt）；
    /// 剧集用这部剧的剧照 + 字标（集的剧照上认不出是哪一部）；都找不到就用存进度时记下的那张
    static func continueArt(_ e: WatchEntry, model: AppModel) -> (url: URL?, logo: URL?) {
        if let sp = e.seriesPath, let s = model.series.first(where: { $0.path == sp }) { return model.seriesWideArt(s) }
        if e.seriesPath == nil, let v = model.video(path: e.path) { return model.wideLockupArt(v) }
        return (TMDBImage.url(e.artwork, "w780"), nil)
    }

    /// 「第 3 集 · 剩余 22 分钟」/「剩余 1 小时 20 分钟」（和分集卡上同一个说法）
    static func remainingLabel(_ e: WatchEntry) -> String {
        let seconds = e.remaining.isFinite ? e.remaining : 0
        let left = "剩余 " + Format.runtime(max(1, Int((seconds / 60).rounded(.up))))
        if e.seriesPath != nil, let s = e.subtitle, !s.isEmpty { return s + " · " + left }
        return left
    }

    // MARK: 推荐

    static func recommendations(for req: PlayRequest, model: AppModel) -> [PlayerShelfItem] {
        let base: [Video]
        if req.seriesPath == nil, let v = model.video(path: req.path) {
            let related = model.related(to: v, limit: 12)
            base = related.isEmpty ? model.featuredMovies(limit: 12) : related
        } else {
            base = model.featuredMovies(limit: 12)
        }
        return base.filter { $0.path != req.path }.map { v in
            let meta = model.meta(v)
            let line = [meta?.genres?.first, model.year(v).map(String.init)].compactMap { $0 }.joined(separator: " · ")
            return PlayerShelfItem(id: v.path, title: model.title(v), subtitle: line.isEmpty ? nil : line,
                                   art: model.wideArt(v), logo: model.logoArt(v), progress: nil,
                                   rating: meta?.rating.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil },
                                   watchKey: v.path)
        }
    }

    // MARK: 前往节目

    static func route(for req: PlayRequest, model: AppModel) -> Route? {
        if let sp = req.seriesPath {
            return model.series.first { $0.path == sp }.map { .series($0) }
        }
        return model.video(path: req.path).map { .movie($0) }
    }
}
