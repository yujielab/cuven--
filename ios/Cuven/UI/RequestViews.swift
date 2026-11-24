import SwiftUI

// MARK: - 请求添加：按钮 → 五步进度卡（同一块液态玻璃变形过去）
//
// 片库里没有的那部（影片库索引里有），详情页的「播放」换成一颗「请求添加」：白色的玻璃胶囊。按下去，这块玻璃原地长成一张
// 矩形的玻璃卡（同一个视图、同一块玻璃，圆角和大小跟着版面一起动画，不是淡出淡入两样东西：见 RequestMorphControl），卡上是
// 「STEP 3 OF 5」「40% Complete」（绿）、五段胶囊进度（走完的实心绿、正在走的绿边 + 走了多少、没到的暗）和五步的名字：
// 等待制片商 → 等待回应 → 等待品质管理 → 等待传输 → 最终发行审批（用户定的说法），底下一行固定的说明。
// 内部在做什么（推到 PikPak、清洗、传到 Dropbox、哪个版本、出了什么错）不显示，服务器给 App 的也不带。

private let requestGreen = Color(red: 0.19, green: 0.82, blue: 0.35)
private let requestRed = Color(red: 1.0, green: 0.27, blue: 0.23)

/// 头部那颗按钮 / 那张卡的三种样子：请求添加（按钮）→ 五步进度（卡）→ 立即播放（按钮）
enum RequestButtonMode: Equatable {
    case request(title: String, symbol: String, enabled: Bool)
    case progress(RequestStatus)
    /// 发行了、片库里有了：卡收回成「立即播放」（用户要求：完成后自动还原形变为立即播放）
    case play(busy: Bool)

    var isCard: Bool { if case .progress = self { return true }; return false }
}

/// 头部那颗按钮 / 那张卡。
/// 是同一个视图、同一块玻璃：按钮时高 48、圆角 24（正好是胶囊），卡时圆角 26、高度跟着内容。玻璃挂在一直在的那个框上，
/// 框的大小随版面一起动画——玻璃的边、上面的片名和那一行信息在同一个动画里一起走，不会有一刻卡先铺满、盖住上面的字
/// （第一版用两个视图 + glassEffectID 变形：截图里变形到一半，玻璃已经是卡的大小，片名还在往上走）。
/// 里面的字交叉淡入淡出，裁在玻璃里面。请求添加 → 卡、卡 → 立即播放 都是这一块玻璃变过去
struct RequestMorphControl: View {
    let mode: RequestButtonMode
    let wide: Bool
    let onRequest: () -> Void
    let onPlay: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let card = mode.isCard
        let shape = RoundedRectangle(cornerRadius: card ? 26 : 24, style: .continuous)
        let maxW: CGFloat? = card ? (wide ? 520 : .infinity) : (wide ? nil : .infinity)
        let tappable: Bool = {
            switch mode {
            case .request(_, _, let enabled): return enabled
            case .play(let busy): return !busy
            case .progress: return false
            }
        }()
        ZStack(alignment: .topLeading) {
            switch mode {
            case .progress(let status):
                RequestProgressCard(status: status)
                    .transition(.opacity)
            case .request(let title, let symbol, let enabled):
                buttonLabel(title, symbol: symbol, dark: enabled)
                    .transition(.opacity)
            case .play(let busy):
                buttonLabel(busy ? "正在准备…" : "立即播放", symbol: "play.fill", dark: true)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: wide ? 180 : 0, maxWidth: maxW, alignment: .topLeading)
        .fixedSize(horizontal: wide && !card, vertical: false)
        .clipShape(shape)
        .contentShape(shape)
        .glassEffect(card ? .regular : (tappable || isPlay ? .regular.tint(.white.opacity(0.92)).interactive() : .regular), in: shape)
        .environment(\.colorScheme, .dark)
        .onTapGesture { tap() }
        .accessibilityElement(children: card ? .contain : .combine)
        .accessibilityAddTraits(card ? [] : .isButton)
        .accessibilityAction { tap() }
        .accessibilityIdentifier(card ? "request-card" : (isPlay ? "request-play" : "request-add"))
        // 按钮 ↔ 卡的那一下由详情页用 morph 这条曲线包起来（版面和玻璃同一个动画）；这里只管卡里的进度更新
        .animation(DSMotion.adapt(.smooth(duration: 0.45), reduce: reduceMotion), value: mode)
    }

    private var isPlay: Bool { if case .play = mode { return true }; return false }

    private func tap() {
        switch mode {
        case .request(_, _, let enabled): if enabled { onRequest() }
        case .play(let busy): if !busy { onPlay() }
        case .progress: break
        }
    }

    private func buttonLabel(_ title: String, symbol: String, dark: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(dark ? Color.black : Color.white.opacity(0.75))
            .lineLimit(1)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 48)
    }

    /// 按钮 ↔ 卡：详情页改状态时用这一条（整个头部的版面一起走）
    static func morph(reduce: Bool) -> Animation {
        DSMotion.adapt(.spring(response: 0.55, dampingFraction: 0.84), reduce: reduce)
    }
}

/// 卡里的内容：STEP X OF 5 · N% Complete · 五段胶囊 · 五步的名字 · 一行给用户的说明。
/// 用户要求：不展示用户不该知道的内容——内部在做什么（推到 PikPak、清洗、传到 Dropbox、哪个版本、出了什么错）一律不显示，
/// 服务器给 App 的进度里也不再带这些（只在控制面板里看得到）
struct RequestProgressCard: View {
    let status: RequestStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("STEP \(status.step) OF \(status.steps)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(trailingColor)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(status.pct)))
            }
            RequestSegments(status: status)
            HStack(alignment: .top, spacing: 6) {
                ForEach(0..<RequestStatus.labels.count, id: \.self) { i in
                    let reached = status.state == .done || i + 1 <= status.step
                    Text(RequestStatus.labels[i])
                        .font(.caption2.weight(i + 1 == status.step ? .semibold : .regular))
                        .foregroundStyle(reached ? Color.white : DSInk.tertiary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(DSInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("请求添加，第 \(status.step) 步，共 \(status.steps) 步：\(RequestStatus.labels[max(0, min(4, status.step - 1))])。\(trailing)。\(footnote)")
    }

    /// 卡底下那一行小字（进行中的是用户定的说法）
    private var footnote: String {
        switch status.state {
        case .active: return "您可以返回，我们将在影片就绪时提醒您。添加流程一般不会超过一个小时。"
        case .done: return "影片已就绪，现在可以观看。"
        case .failed: return "暂时无法添加这部影片，请稍后再试。"
        case .cancelled: return "这次添加已取消。"
        }
    }

    private var trailing: String {
        switch status.state {
        case .active, .done: return "\(status.pct)% Complete"
        case .failed: return "未能添加"
        case .cancelled: return "已取消"
        }
    }

    private var trailingColor: Color {
        switch status.state {
        case .active, .done: return requestGreen
        case .failed: return requestRed
        case .cancelled: return DSInk.tertiary
        }
    }
}

/// 五段胶囊：走完的实心绿；正在走的绿边，里面按这一步走了多少填上；没到的暗
struct RequestSegments: View {
    let status: RequestStatus

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(1, status.steps), id: \.self) { i in segment(i) }
        }
        .frame(height: 8)
    }

    private func segment(_ i: Int) -> some View {
        let done = status.state == .done || i < status.step
        let current = !done && i == status.step
        let tint = status.state == .failed ? requestRed : requestGreen
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(done ? 0 : 0.14))
                if done {
                    Capsule().fill(requestGreen)
                } else if current {
                    if status.stepProgress > 0 {
                        Capsule().fill(tint)
                            .frame(width: max(8, g.size.width * status.stepProgress))
                    }
                    Capsule().strokeBorder(tint, lineWidth: 1.5)
                }
            }
        }
    }
}

// MARK: - 详情页（影片库索引里有、片库里没有的那部）

struct CatalogDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountStore.self) private var account
    let title: CatalogTitle
    @State private var meta: Meta?
    @State private var detail: CatalogDetail?
    @State private var art: DetailArt?
    /// 剧集：选的是哪一季（0 = 还没定，用服务器挑的最新一季）
    @State private var season = 0
    @State private var loading = true
    @State private var busy = false
    /// 刚按下去、服务器还没回话：先把卡变出来（第 1 步），回话了换成真的
    @State private var pending: RequestStatus?
    @State private var alert: DetailAlert?
    /// 完成了（发行了 / 片库里本来就有）：卡收回成「立即播放」。看着页面时刚完成的，先让 100% 的卡停一下再收回
    @State private var showPlay = false
    /// 按了「立即播放」：片库还没刷新到这部、正在找
    @State private var opening = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct DetailAlert: Identifiable { let title: String; let message: String; var id: String { title + message } }

    private var store: RequestStore { RequestStore.shared }
    private var basket: RequestBasket { RequestBasket.shared }
    private var seasonKey: Int { title.kind == .tv ? (season > 0 ? season : (detail?.season ?? 0)) : 0 }
    private var ownedSeasons: Set<Int> { title.kind == .tv ? (model.ownedSeasons[title.id] ?? []) : [] }

    var body: some View {
        // 进行中 / 失败了的请求才变成五步进度卡；取消了的当没请求过（可以重新放进请求中心）
        let raw = pending ?? store.status(src: title.kind.rawValue, id: title.id, season: seasonKey)
        let status = raw?.state == .cancelled ? nil : raw
        let inLibrary = libraryMovie != nil || librarySeries != nil
        let done = inLibrary || status?.state == .done
        let available = (detail?.count ?? 0) > 0 && !inLibrary
        let queued = basket.contains(title, season: seasonKey)
        let mode: RequestButtonMode = done && (showPlay || status == nil)
            ? .play(busy: opening)
            : (status.map { .progress($0) }
               ?? (queued
                   ? .request(title: "已加入请求中心", symbol: "checkmark", enabled: true)
                   : .request(title: buttonTitle(available: available), symbol: available ? "plus" : "clock", enabled: available && !busy)))
        let playing: Bool = { if case .play = mode { return true }; return false }()
        DetailScaffold(
            title: displayTitle,
            art: art,
            metaLine: metaLine,
            playTitle: playing ? "播放" : (status != nil ? "已请求" : (queued ? "已加入" : "请求添加")),
            playID: "request-pinned",
            playDisabled: playing ? opening : (status != nil || (!available && !queued) || busy),
            onPlay: { if playing { playNow() } else { request() } },
            genres: meta?.genres ?? [],
            overview: meta?.overview,
            director: meta?.director,
            stats: stats,
            related: nil,
            thumb: TMDBImage.url(meta?.poster ?? meta?.posterClean ?? title.poster, "w185"),
            cast: meta?.cast ?? [],
            trailers: [],
            trailerArt: [],
            stills: DetailText.stills(meta),
            customAction: AnyView(
                RequestMorphControl(mode: mode, wide: false, onRequest: { request() }, onPlay: { playNow() })
            )
        ) { m in
            sections(m)
        }
        .task(id: title) { await load() }
        .onAppear { if done { showPlay = true } }
        // 完成了：100% 的卡停 1.5 秒，再收回成「立即播放」（刚打开页面、还在载入时就完成的，直接是「立即播放」）
        .onChange(of: done) { _, now in
            guard now else { showPlay = false; return }
            if loading || status == nil { showPlay = true; return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                withAnimation(RequestMorphControl.morph(reduce: reduceMotion)) { showPlay = true }
                Haptics.success()
            }
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }), presenting: alert) { _ in
            Button("好", role: .cancel) {}
        } message: { a in
            Text(a.message)
        }
    }

    // MARK: 立即播放（发行以后：这部已经在片库里了）

    private var libraryMovie: Video? { RequestPlayback.movie(title, model: model) }
    private var librarySeries: Series? { RequestPlayback.series(title, season: seasonKey, model: model) }

    private func playNow() {
        guard !opening else { return }
        opening = true
        Task { @MainActor in
            let problem = await RequestPlayback.play(title, season: seasonKey, model: model, artwork: meta?.backdrop ?? meta?.poster)
            opening = false
            if let problem { alert = DetailAlert(title: problem.title, message: problem.message) }
        }
    }

    private var displayTitle: String {
        if let t = meta?.title, !t.isEmpty { return t }
        return title.title
    }

    private func buttonTitle(available: Bool) -> String {
        if available { return busy ? "正在提交…" : "请求添加" }
        return loading ? "正在查询…" : "暂无可用资源"
    }

    private var metaLine: String {
        DetailText.line([
            title.kind == .tv ? "剧集" : "电影",
            meta?.genres?.first,
            (meta?.year ?? title.year).isEmpty ? nil : (meta?.year ?? title.year),
            title.kind == .movie ? Format.runtime(meta?.runtime) : nil,
            DetailText.rating(meta?.rating),
        ])
    }

    private var stats: DetailStats {
        var s = DetailStats()
        let day = DetailFacts.day(meta?.releaseDate)
        let y = Int(meta?.year ?? title.year)
        if day != nil || y != nil {
            s.release = DetailStats.Release(date: day, year: y, verb: title.kind == .tv ? "首播" : "上映", season: nil)
        }
        if let r = meta?.runtime, r > 0 { s.runtime = DetailStats.Runtime(minutes: r, perEpisode: title.kind == .tv) }
        if let r = meta?.rating, r > 0 { s.rating = r }
        return s
    }

    // MARK: 下面一段：选季（剧集）。用户要求：不放「资源」那张卡（规格、版本数、怎么下载都是用户不该知道的）

    @ViewBuilder
    private func sections(_ m: DSMetrics) -> some View {
        if title.kind == .tv, let d = detail, !d.seasons.isEmpty {
            group(m, "季") {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(d.seasons, id: \.self) { n in seasonChip(n) }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func seasonChip(_ n: Int) -> some View {
        let on = n == seasonKey
        let st = store.status(src: "tv", id: title.id, season: n)
        return Button {
            guard !on else { return }
            Haptics.selection()
            withAnimation(DSMotion.snap) { season = n; pending = nil }
            Task { await reload(season: n) }
        } label: {
            HStack(spacing: 6) {
                Text("第 \(n) 季").font(.subheadline.weight(.semibold))
                if ownedSeasons.contains(n) {
                    Image(systemName: "checkmark.circle.fill").font(.caption)
                } else if let st {
                    Text(st.state == .done ? "已就绪" : st.state == .failed ? "未能添加" : "\(st.pct)%")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(on ? Color.black.opacity(0.6) : (st.state == .failed ? requestRed : requestGreen))
                }
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.12)))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("request-season-\(n)")
    }

    /// 和详情页别的分区同一个样子：粗体标题 + 内容，展开的屏上最宽 720
    private func group<Content: View>(_ m: DSMetrics, _ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.titleGap + 4) {
            DetailGroupTitle(title: name)
            content().frame(maxWidth: 720, alignment: .leading)
        }
        .padding(.horizontal, m.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 载入、请求

    private func load() async {
        if DemoData.enabled { loadDemo(); return }
        let fallback = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled && art == nil { art = DetailArt(wide: title.poster, tall: title.poster, logo: nil) }
        }
        async let m = APIClient.shared.tmdb(query: title.title, year: title.year.isEmpty ? nil : title.year,
                                            type: title.kind == .tv ? "tv" : "movie", id: title.id, full: true)
        async let d = RequestAPI.detail(title, season: nil)
        let mm = (try? await m) ?? nil
        meta = mm
        fallback.cancel()
        if art == nil || art?.logo == nil {
            art = DetailArt(wide: mm?.backdropClean ?? mm?.backdrop ?? mm?.poster ?? title.poster,
                            tall: mm?.posterClean ?? mm?.poster ?? title.poster, logo: mm?.logo)
        }
        let dd = try? await d
        detail = dd
        loading = false
        if let dd {
            store.merge(dd.req)
            for (_, r) in dd.reqs { store.merge(r) }
        }
    }

    private func reload(season n: Int) async {
        guard !DemoData.enabled else { return }
        loading = true
        if let dd = try? await RequestAPI.detail(title, season: n) {
            detail = dd
            store.merge(dd.req)
        }
        loading = false
    }

    /// 用户要求的批量流程：「请求添加」先放进请求中心（最多 50 部），在请求中心按「确认」才一起提交。
    /// 已经在请求中心里的，再按一下就切到请求中心去确认
    private func request() {
        guard !busy, pending == nil else { return }
        if !DemoData.enabled && !account.isLoggedIn { alert = DetailAlert(title: "无法请求添加", message: "登录后才能请求添加。"); return }
        let s = seasonKey
        if basket.contains(title, season: s) {
            Haptics.selection()
            basket.openCenter = true
            return
        }
        switch basket.add(title, season: s) {
        case .added, .already:
            Haptics.success()
        case .full:
            Haptics.error()
            alert = DetailAlert(title: "请求中心已满", message: "请求中心最多放 \(RequestBasket.limit) 部，先在请求中心确认这一批，再加新的。")
        }
    }

    /// 演示数据（截图用）：本地的画面和简介，三个版本，剧集两季
    private func loadDemo() {
        var m = Meta(id: title.id, title: title.title, en: "The Long Night", year: title.year,
                     poster: title.poster, posterClean: title.poster, backdrop: "demo://backdrop/12",
                     overview: "演示数据：影片库索引里有、片库里还没有的一部。按「请求添加」以后，这块玻璃会变成五步进度卡。",
                     rating: 8.1, type: title.kind.rawValue, runtime: 52, genres: ["剧情", "悬疑"])
        m.director = "林夏"
        meta = m
        art = DetailArt(wide: "demo://backdrop/12", tall: "demo://poster/12", logo: nil)
        detail = CatalogDetail(demo: title, seasons: title.kind == .tv ? [1, 2] : [], count: 3,
                               best: RequestStatus.Spec(res: "2160p", labels: ["4K", "杜比视界"], size: "58.6 GB"))
        loading = false
    }
}

// MARK: - 立即播放：片库里的这部（详情页、请求中心共用）

@MainActor
enum RequestPlayback {
    struct Problem { let title: String; let message: String }

    /// 片库里的这部电影：先看名字（或所在文件夹）里的追踪码 [auto-m550-r13]——确定的 TMDB 编号，不用等片名认出来；
    /// 没有追踪码的再按 TMDB 编号对
    static func movie(_ t: CatalogTitle, model: AppModel) -> Video? {
        guard t.kind == .movie else { return nil }
        if let v = model.videos.first(where: { v in
            guard let i = AutoTag.info(in: v.path) else { return false }
            return !i.tv && i.tmdb == t.id
        }) { return v }
        return model.movies.first { model.meta($0)?.id == t.id }
    }

    /// 片库里这部剧的这一季（season 0 = 哪一季都行）：先看文件夹名里的追踪码 [auto-tv1399s2-r14]，再按 TMDB 编号对
    static func series(_ t: CatalogTitle, season: Int, model: AppModel) -> Series? {
        guard t.kind == .tv else { return nil }
        if let s = model.series.first(where: { s in
            guard let i = AutoTag.info(in: s.path), i.tv, i.tmdb == t.id else { return false }
            return season == 0 || i.season == season || (i.season == 0 && (s.season ?? 1) == season)
        }) { return s }
        return model.series.first { s in
            (s.tmdbId ?? model.seriesMetas[s.path]?.id) == t.id && (season == 0 || max(1, s.season ?? 1) == season)
        }
    }

    /// 放片库里的这部；刚发行、片库清单还没刷新到的先刷新一次再找。放不了回给人看的说明
    static func play(_ t: CatalogTitle, season: Int, model: AppModel, artwork: String?) async -> Problem? {
        if let v = movie(t, model: model) { playMovie(v, model: model, artwork: artwork); return nil }
        if let s = series(t, season: season, model: model) { return await playSeries(s, title: t.title, model: model, artwork: artwork) }
        await model.refreshLibrary()
        if t.kind == .tv { await model.refreshSeries() }
        if let v = movie(t, model: model) { playMovie(v, model: model, artwork: artwork); return nil }
        if let s = series(t, season: season, model: model) { return await playSeries(s, title: t.title, model: model, artwork: artwork) }
        // 文件刚抵达 /auto、自动通过了最终审核，片库清单里还没有：请片库马上收录一次，再找
        await APIClient.shared.autoSync()
        await model.refreshLibrary()
        if t.kind == .tv { await model.refreshSeries() }
        if let v = movie(t, model: model) { playMovie(v, model: model, artwork: artwork); return nil }
        if let s = series(t, season: season, model: model) { return await playSeries(s, title: t.title, model: model, artwork: artwork) }
        return Problem(title: "影片正在上架", message: "影片已经就绪，片库还在更新。请稍后再试一次。")
    }

    private static func playMovie(_ v: Video, model: AppModel, artwork: String?) {
        Haptics.light()
        PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(v),
                                                  subtitle: model.year(v).map { String($0) },
                                                  artwork: model.backgroundArtString(v) ?? artwork), model: model)
    }

    /// 剧集：从这一季第 1 集放起，后面几集接着排上（看过一半的，播放器自己接着上次的地方）
    private static func playSeries(_ s: Series, title: String, model: AppModel, artwork: String?) async -> Problem? {
        guard let list = try? await APIClient.shared.episodes(seriesPath: s.path), !list.isEmpty else {
            return Problem(title: "暂时无法播放", message: "无法载入剧集，请稍后再试。")
        }
        let files = list.sorted { ($0.ep ?? Int.max, $0.name) < ($1.ep ?? Int.max, $1.name) }
        let sm = model.seriesMetas[s.path]
        func req(_ f: EpisodeFile) -> PlayRequest {
            PlayRequest(path: f.path, name: f.name, title: sm?.title ?? title, subtitle: f.ep.map { "第 \($0) 集" },
                        artwork: sm?.backdrop ?? artwork, seriesPath: s.path, episode: f.ep)
        }
        var first = req(files[0])
        first.queue = files.dropFirst().map(req)
        Haptics.light()
        PlayerCoordinator.shared.play(first, model: model)
        return nil
    }
}

// MARK: - 目录卡（主页「可请求添加」、搜索结果）

struct CatalogPosterLink: View {
    let item: CatalogItem
    let metrics: DSMetrics
    let slot: String

    var body: some View {
        let st = RequestStore.shared.anyStatus(src: item.src, id: item.id) ?? item.req
        let queued = st == nil && RequestBasket.shared.containsAny(src: item.src, id: item.id)
        ZoomLink(route: .catalog(item.catalogTitle), slot: slot) {
            DSPosterLockup(art: TMDBImage.url(item.poster, "w342"), title: item.title,
                           subtitle: [item.src == "tv" ? "剧集" : "电影", item.year].filter { !$0.isEmpty }.joined(separator: "，"),
                           metrics: metrics)
                .overlay(alignment: .bottomLeading) {
                    if let st { badge(st).padding(8) } else if queued { pill("已加入", color: .white).padding(8) }
                }
        }
        .accessibilityIdentifier("catalog-card")
    }

    private func badge(_ s: RequestStatus) -> some View {
        let text = s.state == .done ? "已就绪" : s.state == .failed ? "未能添加" : s.stage == "release" ? "发行审批" : "已请求 \(s.pct)%"
        return pill(text, color: s.state == .failed ? requestRed : .white)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

/// 主页：「可请求添加」一排（影片库里最新收录、片库里还没有的；数据由 RequestStore.loadShelf 取）
struct RequestableShelf: View {
    @Environment(AppModel.self) private var model
    let metrics: DSMetrics

    var body: some View {
        let movies = model.ownedMovieIDs, shows = model.ownedSeasons
        let items = Array(RequestStore.shared.shelf.filter { !model.owns($0, movies: movies, shows: shows) }.prefix(20))
        if !items.isEmpty {
            DSSection(title: "可请求添加", metrics: metrics) {
                DSShelf(metrics: metrics) {
                    ForEach(items, id: \.uid) { it in CatalogPosterLink(item: it, metrics: metrics, slot: "home-request") }
                }
            }
        }
    }
}

/// 搜索：片库之外，影片库索引里对得上的（「可请求添加」）。showEmpty：片库里一部都没搜到时，这里也没有就说「没有找到」
struct RequestableSearchSection: View {
    @Environment(AppModel.self) private var model
    let query: String
    let metrics: DSMetrics
    var showEmpty = false
    /// nil = 还在查
    @State private var items: [CatalogItem]?

    var body: some View {
        content
            .task(id: query) {
                items = nil
                guard !DemoData.enabled else { items = []; return }
                try? await Task.sleep(for: .milliseconds(450))     // 打字时不每个字都去问
                guard !Task.isCancelled else { return }
                let r = try? await RequestAPI.catalog(src: "all", query: query)
                guard !Task.isCancelled else { return }
                items = r ?? []
                for i in r ?? [] { if let s = i.req { RequestStore.shared.merge(s) } }
            }
    }

    @ViewBuilder private var content: some View {
        let movies = model.ownedMovieIDs, shows = model.ownedSeasons
        let list = (items ?? []).filter { !model.owns($0, movies: movies, shows: shows) }
        if !list.isEmpty {
            DSSection(title: "可请求添加", metrics: metrics) {
                DSShelf(metrics: metrics) {
                    ForEach(list.prefix(24), id: \.uid) { it in CatalogPosterLink(item: it, metrics: metrics, slot: "search-request") }
                }
            }
        } else if showEmpty && items != nil {
            ContentUnavailableView {
                Label("没有找到“\(query)”", systemImage: "magnifyingglass")
            } description: {
                Text("请尝试其他片名或年份。")
            } actions: {
                NavigationLink(value: Route.shelf(.all)) {
                    Text("浏览所有影片")
                }
                .accessibilityIdentifier("search-browse-all")
            }
            .padding(.top, 60)
        } else if showEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else {
            Color.clear.frame(height: 0)
        }
    }
}

// MARK: - 截图用：演示数据里推进一部「可请求添加」的剧集详情页（-CuvenRequestPreview YES）

#if DEBUG
@MainActor
enum RequestPreview {
    static func presentIfRequested(_ model: AppModel) {
        guard DemoData.enabled, UserDefaults.standard.bool(forKey: "CuvenRequestPreview") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            model.openRequest = .catalog(CatalogTitle(kind: .tv, id: 1399, title: "长夜将明", year: "2025", poster: "demo://poster/12"))
        }
    }
}
#endif
