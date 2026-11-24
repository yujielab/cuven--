import SwiftUI
import AVFoundation

// MARK: - 主页「编辑推荐」（照用户给的参考图：Apple「游戏」App 首页的「重磅更新」大卡）
//
// 一整块铺满窗口宽（连同 iPhone Duo 侧边那一列）：
// · 底下是这一部的预告片（静音、从第 10 秒起、放完回到第 10 秒；和资料库同一个 ShowcaseTrailer），起来之前
//   （或者没有预告片）是 Apple TV 的竖版主视觉（横着的屏用横版背景），预告片出画面时模糊淡入；
// · 左上一行大号粗体「编辑推荐」；右上一颗播放 / 暂停 + 进度环（有预告片才出现：F77）；
// · 预告片（用户要求）：本机下好了（TrailerCache：主页一知道这一部的预告片就在后台下）一出现就放；没下好的在屏上停留超过 3 秒才放；
//   系统「自动播放视频预览」关着、省流量时不自己放，右上「播放预告」按了才放；
// · 底部一张从画面取色的圆角面板（用户要求矮 35%）：小海报 + 字标（没有字标写片名）、「科幻 · 2024」，右边「查看」胶囊（简介只在详情页：用户要求）；
// · 整块点进详情（从这一块上放大出来）。只在屏上、这一页在前台时放；同一时刻全 App 只放一段（TrailerFocus）。
// 每天换一部（AppModel.editorsPick：评分高、有字标和竖版画面、不和头图撞车，查到有预告片的优先）。

struct EditorsPick: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let metrics: DSMetrics
    /// 窗口的高：折起的屏这一块约是宽的 1.3 倍高，展开竖拿 0.9 倍，横着的屏 0.56 倍，最多窗口高的 82%
    let fullHeight: CGFloat
    /// 竖着的这一块按高铺满、横向裁掉两边：码流到 1080 马上露，放了 2 秒到六成、4 秒不管多少都露；本机那份一放就露（ShowcaseTrailer.tick）
    @State private var trailer = ShowcaseTrailer(revealHeight: 1080)
    @State private var tone: Color?
    @State private var onScreen = false
    /// 有预告片（右上那颗「播放预告」才出现）；hls 是那一段（问本机有没有下好）
    @State private var hasTrailer = false
    @State private var trailerHLS: String?
    @State private var started = false
    /// 停留计时：在屏上超过 3 秒、本机还没有下好的，到点从网上放（用户要求）
    @State private var dwell: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func height(fullWidth w: CGFloat, fullHeight: CGFloat) -> CGFloat {
        // 展开竖拿（宽过 600、又比宽高）：以前按横屏的 0.56 算，只有三百多点高，字和面板把画面盖满了
        let ratio: CGFloat = w < 600 ? 1.3 : (fullHeight > w ? 0.9 : 0.56)
        return min(w * ratio, fullHeight * 0.82).rounded()
    }

    var body: some View {
        let fullW = metrics.width + metrics.leadingInset + metrics.trailingInset
        let h = Self.height(fullWidth: fullW, fullHeight: fullHeight)
        // 预告片放起来之前是剧照（用户要求「未播放预告片时要有剧照兜底」）
        let still = stillArt(fullWidth: fullW)
        ZStack(alignment: .topTrailing) {
            ZoomLink(route: .movie(video), slot: "editors-pick", press: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("编辑推荐")
                        .font(.dsDisplay(wide: metrics.wide))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 16)
                    panel
                }
                .padding(.horizontal, metrics.margin)
                .padding(.top, metrics.wide ? 30 : 24)
                .padding(.bottom, metrics.margin)
                .frame(width: metrics.width, height: h, alignment: .leading)
                // 画面铺到侧边那一列底下（F6），字和面板留在安全区里（F7）
                .background {
                    media(still: still, pixel: max(fullW, h) * 2)
                        .padding(.leading, -metrics.leadingInset)
                        .padding(.trailing, -metrics.trailingInset)
                }
                .contentShape(Rectangle())
                // 设计轮 2：旁白把整块念成一句「编辑推荐，片名，类型 · 年份，简介」。字标是图，以前念不出片名，
                // 还多念一个「查看」；它也是一个标题，按标题跳的时候跳得到（F76）
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenLabel)
            }
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("editors-pick")
            Group {
                if started && trailer.showing && trailer.path == video.path {
                    // 画面真的出来了：播放 / 暂停 + 进度环（以前一拿到预告片就换成这颗，画面还没出来，背景还是剧照：用户截图）
                    ShowcaseControl(trailer: trailer)
                } else if hasTrailer {
                    // 还没放：按「播放预告」马上放；放起来到出画面之间胶囊里转圈
                    EditorsPickTrailerButton(loading: started && !trailer.paused && trailer.path == video.path) { startTrailer(userStarted: true) }
                }
            }
            .padding(.trailing, metrics.margin - 6)
            .padding(.top, metrics.wide ? 30 : 22)
            // 「减弱动态效果」时只淡入（F59）
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.8)))
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: trailer.showing)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: hasTrailer)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: started)
        .onScrollVisibilityChange(threshold: 0.4) { visible in
            onScreen = visible
            // 挂上以后滑出去停、滑回来接着放；还没挂的：本机有就放，没有就从现在起算 3 秒
            trailer.setCovered(!visible)
            autoplay()
        }
        .onAppear { trailer.setVisible(true); autoplay() }
        .onDisappear { trailer.setVisible(false); cancelDwell() }
        // 有没有预告片先问一下（只是清单；和详情页同一次查询，查过的记着）：有才放那颗钮，
        // 同时交给 TrailerCache 在后台下到本机（空闲时才下、只在 Wi-Fi）
        .task(id: video.path) {
            let list = await model.trailers(for: video)
            hasTrailer = !list.isEmpty
            trailerHLS = list.first?.hls
            if let hls = trailerHLS { TrailerCache.shared.want(key: video.path, hls: hls) }
            autoplay()
        }
        .onChange(of: video.path) {
            // 每天换一部：回到「播放预告」
            cancelDwell()
            trailer.unmount()
            started = false
            hasTrailer = false
            trailerHLS = nil
        }
        .task(id: still) { await loadTone(still) }
    }

    /// 挂上这一部的预告片、放起来，出画面时从模糊里淡入。userStarted：按了「播放预告」（不看系统「自动播放视频预览」——是人按的）；
    /// 已经挂上但停着（自动挂上时系统不让自动放）按了也放
    private func startTrailer(userStarted: Bool) {
        cancelDwell()
        // 已经挂着这一部（停着的按了就放）；挂过但没放成（预告片打不开，卸下了）按了再挂一次
        if started && trailer.path == video.path {
            if userStarted && trailer.paused { trailer.togglePause() }
            return
        }
        if started && !userStarted { return }
        if userStarted { Haptics.light() }
        started = true
        trailer.mount(video, model: model, userStarted: userStarted)
        trailer.setCovered(!onScreen)
    }

    /// 自己放（用户要求）：本机下好了，一出现就放；没下好，在屏上停留超过 3 秒才放。
    /// 系统「自动播放视频预览」关着、省流量时不自己放（F77、S17），只等人按「播放预告」
    private func autoplay() {
        guard hasTrailer, !started, onScreen, UIAccessibility.isVideoAutoplayEnabled, !NetworkSpeed.dataSaver else {
            if !onScreen { cancelDwell() }
            return
        }
        if let hls = trailerHLS, TrailerCache.shared.localURL(key: video.path, hls: hls) != nil {
            startTrailer(userStarted: false)
            return
        }
        guard dwell == nil else { return }
        let path = video.path
        dwell = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            dwell = nil
            guard onScreen, !started, video.path == path else { return }
            startTrailer(userStarted: false)
        }
    }

    private func cancelDwell() {
        dwell?.cancel()
        dwell = nil
    }

    /// 预告片起来之前（没按「播放预告」时）的画面——剧照（用户要求「未播放预告片时要有剧照兜底」）：
    /// Apple TV 无字的横版背景 → TMDB 横版剧照（无字的那张优先）→ TMDB 剧照里的第一张 → Apple 带片名的 16:9 → 竖版主视觉。
    /// 以前竖着的这一块用竖版主视觉：那种图下半截是给字留的一大片纯色，按 fill 裁进这一块常常只剩那一片（用户截图：整块空着）
    private func stillArt(fullWidth: CGFloat) -> URL? {
        let a = model.appleArt(video), m = model.meta(video)
        func some(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
        if let b = some(a?.background) { return URL(string: AppleImage.sized(b, width: 1920) ?? b) }
        if let b = some(m?.backdropClean) ?? some(m?.backdrop) { return TMDBImage.url(b, "w1280") }
        if let s = m?.stills?.lazy.compactMap({ some($0.url) ?? some($0.thumb) }).first { return TMDBImage.url(s, "w1280") }
        if let w = some(a?.wide) { return URL(string: AppleImage.sized(w, width: 1920) ?? w) }
        return model.featuredArt(video, width: fullWidth)?.url
    }

    private func media(still: URL?, pixel: CGFloat) -> some View {
        ZStack {
            DSFill.placeholder
            // 图按 fill 铺，自己会比这一块大（竖版主视觉放进扁一点的块里，上下各多出一两百点）：
            // 放在 Color.clear 的 overlay 里，这一层的大小就是这一块，下面的 clipped 才真的裁在块的边上——
            // 以前多出来的那截画在上面一排精选卡的下半截上（展开竖拿、折起时卡底那条被盖住）
            Color.clear.overlay { RemoteImage(url: still, maxPixel: pixel, placeholder: .clear) }
            if trailer.path == video.path {
                VideoSurface(player: trailer.player, gravity: .resizeAspectFill, background: .clear)
                    .opacity(trailer.showing ? 1 : 0)
                    .blur(radius: trailer.showing ? 0 : 18)
                    .animation(.easeInOut(duration: 0.8), value: trailer.showing)
                    .allowsHitTesting(false)
            }
            // 上沿一层淡暗：「编辑推荐」压在上面看得清（F34）
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                   .init(color: .black.opacity(0), location: 0.32)],
                           startPoint: .top, endPoint: .bottom)
            // 下沿也压一点：面板和画面分得开
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.55),
                                   .init(color: .black.opacity(0.32), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// 底部那张面板（参考图「一起玩 / Sneaky Sasquatch / 拿起相機，出發賞鳥吧 / 查看遊戲 ›」）
    private var panel: some View {
        let meta = model.meta(video)
        let year: String? = model.year(video).map { String($0) }
        let kicker = DetailText.line([meta?.genres?.first, year])
        // 用户要求：这块面板矮 35%（折起约 163 → 105 点）：小海报、字标小一号；简介不放（用户要求：简介只出现在详情页），
        // 「查看影片 ›」那一行收进右边一颗「查看」胶囊（和年份卡、精选卡同一个样子），上下边距 12
        let posterW: CGFloat = metrics.wide ? 60 : 52
        return HStack(alignment: .center, spacing: 12) {
            DSThumb(url: model.thumbArt(video), width: posterW, maxPixel: 270)
            VStack(alignment: .leading, spacing: 3) {
                if !kicker.isEmpty {
                    Text(kicker)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(DSInk.secondary)
                        .lineLimit(1)
                }
                LogoImage(url: model.wideLockupArt(video).logo, height: metrics.wide ? 34 : 28, alignment: .leading,
                          fallback: model.title(video), maxWidth: metrics.wide ? 260 : 180)
            }
            Spacer(minLength: 8)
            DSViewPill()
        }
        // 面板压在固定高的这一块画面上：字号最大到 xxxLarge（和分集卡、精选卡一样封顶），不把「编辑推荐」顶出去（F23）
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill((tone ?? Color(white: 0.16)).opacity(0.94)))
    }

    /// 旁白念的那一句：编辑推荐，片名，类型 · 年份（简介只在详情页）
    private var spokenLabel: String {
        let meta = model.meta(video)
        let kicker = DetailText.line([meta?.genres?.first, model.year(video).map { String($0) }])
        let parts: [String?] = ["编辑推荐", model.title(video), kicker]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "，")
    }

    /// 面板的颜色：画面最下面那一截的平均色，压暗、收一点饱和度（白字看得清；设计轮 2：和合集卡的底条同一个 DSTint.panel）
    private func loadTone(_ url: URL?) async {
        guard let url, let img = await ImagePipeline.shared.image(url, maxPixel: 64), let cg = img.cgImage,
              let c = ImageEffects.averageColor(cg, bottom: 0.3), let t = DSTint.panel(c) else { return }
        withAnimation(DSMotion.fade) { tone = t }
    }
}

// MARK: - 主页「2026 ›」「2025 ›」（照用户给的参考图：游戏 App「Arcade 名人堂」那一排）
//
// 标题一行大号粗体 +「›」（点进年份页），下面一行灰字；一排卡：16:9 的预告片，
// 下面小海报、字标、片名、一行灰字，右边「查看」（用户要求：卡上面不放简介；没有字标的不进这两排）。同一排同一时刻只放一段：最靠左、整张露出来的那一张
// （静音、从第 10 秒起；这一排滑出屏幕、换页、正片盖上来就停；全 App 同一时刻只放一段：TrailerFocus）。
// 没有预告片的那张停在横版背景上。

/// 编辑推荐右上那颗「▶ 播放预告」（用户要求：预告片不自己放，按了才在背景里放）：玻璃胶囊，看上去 36 高、点按区 44（F74）；
/// 按下到出画面之间符号换成转圈，胶囊不变宽
struct EditorsPickTrailerButton: View {
    let loading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Image(systemName: "play.fill").opacity(loading ? 0 : 1)
                    if loading { ProgressView().controlSize(.mini).tint(.white) }
                }
                .frame(width: 14)
                Text("播放预告")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .glassEffect(.regular.interactive(), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .accessibilityLabel(loading ? "正在载入预告片" : "播放预告片")
        .accessibilityIdentifier("editors-pick-trailer")
    }
}

struct YearTrailerRow: View {
    @Environment(AppModel.self) private var model
    let year: Int
    let items: [HomeEntry]
    let metrics: DSMetrics
    // 卡上只放剧照（用户要求「移除长按预告片播放，仅剧照就好」）：不挂预告片、不自动放、长按也不放；长按是「播放 / 想看」菜单，和别的卡一样

    var body: some View {
        if metrics.wide { spotlight } else { row }
    }

    /// 折起：一排卡（横着滑）
    private var row: some View {
        // 展开时卡至少 300 点宽：下面那一行小海报 + 片名 + 灰字 +「查看」放得下（DSMetrics.trailerCardWidth）
        let w = metrics.trailerCardWidth
        return VStack(alignment: .leading, spacing: metrics.titleGap + 2) {
            header
            DSShelf(metrics: metrics) {
                ForEach(items) { e in card(e, width: w) }
            }
        }
    }

    /// 展开（用户给的参考图：游戏 App 展开时「新作快報 ›」）：标题下面先一张横向大卡（WideLeadCard：左六成剧照，
    /// 右四成从画面取色的一块），再两张一排的卡（画面 + 取色的底条：CollectionCard）；更多的在年份页（标题「2026 ›」）。
    /// 横向大卡至少 300 点高（右边那一块放得下小海报、两行片名、灰字、「查看」），宽的 36%，不高过屏高的 55%
    private var spotlight: some View {
        let full = max(200, metrics.width - metrics.margin * 2)
        let half = metrics.cardWidth(columns: 2)
        let cap = metrics.height > 0 ? (metrics.height * 0.55).rounded() : 420
        let leadH = min(max(300, (full * 0.36).rounded()), max(300, cap))
        let rest = Array(items.dropFirst().prefix(2))
        return VStack(alignment: .leading, spacing: metrics.titleGap + 2) {
            header
            VStack(alignment: .leading, spacing: metrics.gutter) {
                if let lead = items.first {
                    leadCard(lead, width: full, height: leadH)
                }
                if !rest.isEmpty {
                    HStack(alignment: .top, spacing: metrics.gutter) {
                        ForEach(rest) { e in halfCard(e, width: half) }
                    }
                }
            }
            .padding(.horizontal, metrics.margin)
        }
    }

    /// 「2026 ›」+ 灰字（参考图「Arcade 名人堂 › / 知名角色等你來相遇」）
    private var header: some View {
        let current = Calendar.current.component(.year, from: Date())
        let sub = year == current ? "今年上映的新片与新剧" : "\(year) 年上映的电影和剧集"
        // 设计轮 1：和别的分区标题同一个部件（DSSectionLabel），只是大一级；副标题从 Title 3 收成 Body，「2026」更突出
        return NavigationLink(value: Route.year(year)) {
            DSSectionLabel(title: String(year), subtitle: sub, chevron: true, showcase: true, wide: metrics.wide)
                .padding(.horizontal, metrics.margin)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityIdentifier("section-\(year)")
    }

    @ViewBuilder private func card(_ e: HomeEntry, width w: CGFloat) -> some View {
        switch e {
        case .movie(let v):
            let meta = model.meta(v)
            let y: String? = model.year(v).map { String($0) }
            let sub = DetailText.line([y, meta?.genres?.first])
            ZoomLink(route: .movie(v), slot: "year-\(year)") {
                YearTrailerCard(still: TMDBImage.url(model.backgroundArtString(v), "w1280"),
                                cover: model.thumbArt(v), logo: model.wideLockupArt(v).logo,
                                title: model.title(v), subtitle: sub, width: w)
                    .downloadBadge(v.path, inset: 10)
            }
            .accessibilityIdentifier("movie-card")
            .movieMenu(v)
        case .series(let s):
            let sm = model.seriesMetas[s.path]
            let art = model.seriesWideArt(s)
            let sub = DetailText.line([s.seasonLabel, sm?.genres?.first])
            ZoomLink(route: .series(s), slot: "year-\(year)") {
                YearTrailerCard(still: art.url, cover: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w185"), logo: art.logo,
                                title: sm?.title ?? s.name, subtitle: sub, width: w)
            }
            .accessibilityIdentifier("series-card")
            .seriesMenu(s)
            .task { await model.ensureSeriesMeta(s) }
        }
    }

    // MARK: 展开：打头的横向大卡 + 两张一排的卡

    @ViewBuilder private func leadCard(_ e: HomeEntry, width w: CGFloat, height h: CGFloat) -> some View {
        switch e {
        case .movie(let v):
            let sub = DetailText.line([model.year(v).map { String($0) }, model.meta(v)?.genres?.first])
            ZoomLink(route: .movie(v), slot: "year-\(year)") {
                WideLeadCard(art: TMDBImage.url(model.backgroundArtString(v), "w1280"), cover: model.thumbArt(v),
                             logo: model.wideLockupArt(v).logo,
                             kicker: "电影", title: model.title(v), subtitle: sub, width: w, height: h)
                    .downloadBadge(v.path, inset: 14, size: 26)
            }
            .accessibilityIdentifier("movie-card")
            .movieMenu(v)
        case .series(let s):
            let sm = model.seriesMetas[s.path]
            let sub = DetailText.line([s.seasonLabel, sm?.genres?.first])
            ZoomLink(route: .series(s), slot: "year-\(year)") {
                WideLeadCard(art: model.seriesWideArt(s).url, cover: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w185"),
                             logo: model.seriesWideArt(s).logo,
                             kicker: "剧集", title: sm?.title ?? s.name, subtitle: sub, width: w, height: h)
            }
            .accessibilityIdentifier("series-card")
            .seriesMenu(s)
            .task { await model.ensureSeriesMeta(s) }
        }
    }

    @ViewBuilder private func halfCard(_ e: HomeEntry, width w: CGFloat) -> some View {
        switch e {
        case .movie(let v):
            let sub = DetailText.line([model.year(v).map { String($0) }, model.meta(v)?.genres?.first])
            ZoomLink(route: .movie(v), slot: "year-\(year)") {
                CollectionCard(art: TMDBImage.url(model.backgroundArtString(v), "w1280"), cover: model.thumbArt(v),
                               title: model.title(v), line: sub, width: w, kicker: "电影")
                    .downloadBadge(v.path, inset: 12)
            }
            .accessibilityIdentifier("movie-card")
            .movieMenu(v)
        case .series(let s):
            let sm = model.seriesMetas[s.path]
            let sub = DetailText.line([s.seasonLabel, sm?.genres?.first])
            ZoomLink(route: .series(s), slot: "year-\(year)") {
                CollectionCard(art: model.seriesWideArt(s).url, cover: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w185"),
                               title: sm?.title ?? s.name, line: sub, width: w, kicker: "剧集")
            }
            .accessibilityIdentifier("series-card")
            .seriesMenu(s)
            .task { await model.ensureSeriesMeta(s) }
        }
    }
}

/// 展开时年份分区打头的那张横向大卡（用户给的参考图：游戏 App 展开时「新作快報」打头那张）：
/// 左边六成是剧照（只放剧照，不放预告片：用户要求），右边沿渐变融进右边四成那一块从画面取色的底（DSTint.panel，和合集卡、编辑推荐同一个取色）。
/// 右边那一块（用户要求「海报旁边添加字标，放大展示，限制高度和最大宽度；调整文字大小，优化设计和布局」）：
/// 上面一行小海报 + 旁边放大的字标（高不过这一块的 24%、最多 84 点，宽不过 260 点，按比例收）；
/// 下面贴底一组字：一行小字（「电影」「剧集」）、片名（有字标时一行 Title 3，没有字标时两行 Title 2，名字就靠它）、一行灰字（年份 · 类型）、「查看」胶囊。
/// 整张卡点进详情；不放简介（用户要求：简介只出现在详情页）
struct WideLeadCard: View {
    let art: URL?
    let cover: URL?
    let logo: URL?
    let kicker: String
    let title: String
    let subtitle: String
    let width: CGFloat
    let height: CGFloat
    @State private var tone: Color?

    init(art: URL?, cover: URL?, logo: URL? = nil, kicker: String, title: String, subtitle: String, width: CGFloat, height: CGFloat) {
        self.art = art
        self.cover = cover
        self.logo = logo
        self.kicker = kicker
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.height = height
    }

    var body: some View {
        let imageW = (width * 0.6).rounded()
        let panelW = width - imageW
        let pad: CGFloat = panelW >= 360 ? 28 : 24
        let thumbW: CGFloat = panelW >= 360 ? 68 : 60
        let logoH = min(84, (height * 0.24).rounded())
        let logoW = min(260, max(80, panelW - pad * 2 - thumbW - 18))
        let fill = tone ?? Color(white: 0.16)
        let shape = RoundedRectangle(cornerRadius: DSRadius.feature, style: .continuous)
        HStack(spacing: 0) {
            // 画面用 Color.clear 撑出那一块的大小再盖上去：fill 的图不会把这一层撑大；右边 56 点渐变成右边那一块的底色，接缝看不出来
            Color.clear
                .frame(width: imageW, height: height)
                .overlay { RemoteImage(url: art, maxPixel: imageW * 3, placeholder: .clear) }
                .overlay(alignment: .trailing) {
                    LinearGradient(colors: [fill.opacity(0), fill], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 56)
                }
                .clipped()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 18) {
                    DSThumb(url: cover, width: thumbW, maxPixel: 300)
                    if logo != nil {
                        LogoImage(url: logo, height: logoH, alignment: .leading, maxWidth: logoW)
                            .frame(maxWidth: logoW, alignment: .leading)
                    }
                }
                Spacer(minLength: 14)
                Text(kicker)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DSInk.secondary)
                Text(title)
                    .font(logo != nil ? .title3.bold() : .title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(logo != nil ? 1 : 2)
                    .padding(.top, 3)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(DSInk.secondary)
                        .lineLimit(1)
                        .padding(.top, 3)
                }
                DSViewPill()
                    .padding(.top, 14)
            }
            // 字压在固定高的一块上：字号最大到 xxLarge，小海报 + 字标、片名、灰字、「查看」还放得下
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .padding(pad)
            .frame(width: panelW, height: height, alignment: .topLeading)
            .background(fill)
        }
        .frame(width: width, height: height)
        .background(DSFill.placeholder)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DSFill.hairline, lineWidth: 1))
        .contentShape(shape)
        .task(id: art) { await loadTone() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([kicker, title, subtitle].filter { !$0.isEmpty }.joined(separator: "，"))
    }

    private func loadTone() async {
        guard let art, let img = await ImagePipeline.shared.image(art, maxPixel: 64), let cg = img.cgImage,
              let c = ImageEffects.averageColor(cg, bottom: 0.3), let t = DSTint.panel(c) else { return }
        withAnimation(DSMotion.fade) { tone = t }
    }
}

/// 年份那两排的一张卡：16:9 的剧照（只放剧照，不放预告片：用户要求）；
/// 下面一行：小海报、字标、片名、一行灰字，右边蓝字「查看」（参考图卡底那一行）。上面不放简介（用户要求）
struct YearTrailerCard: View {
    let still: URL?
    let cover: URL?
    let logo: URL?
    let title: String
    let subtitle: String
    let width: CGFloat
    /// 「全部影片 › 可申请」：剧照还没取到（或 TMDB 上没有）时，用竖版海报糊开垫底
    var fallback: URL? = nil
    /// 右边那颗胶囊换成请求的状态（「申请」「已加入」「已请求 42%」……）；nil = 「查看」
    var badge: YearCardBadge? = nil
    /// 剧照底边一道细进度（请求进行中）
    var progress: Double? = nil
    /// 剧照已经整张盖住了（取到了、淡入也走完了）：底下那张糊的海报拿掉——
    /// 它在不透明的剧照底下看不见，留着的话滑动时每张卡每帧都要再糊一遍（可申请那几排一屏十几张）
    @State private var stillCovered: Bool

    init(still: URL?, cover: URL?, logo: URL?, title: String, subtitle: String, width: CGFloat,
         fallback: URL? = nil, badge: YearCardBadge? = nil, progress: Double? = nil) {
        self.still = still
        self.cover = cover
        self.logo = logo
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.fallback = fallback
        self.badge = badge
        self.progress = progress
        // 剧照内存里就有：下面的 RemoteImage 第一次画就是它（不淡入），一开始就不用垫、也不去取那张海报
        let hit = still.flatMap { ImagePipeline.shared.cached($0, maxPixel: width * 3) }
        _stillCovered = State(initialValue: hit != nil)
    }

    var body: some View {
        let h = (width * 9 / 16).rounded()
        // 设计轮 2：圆角取 DSRadius.card（和上面继续观看那排一样宽的卡一样圆；以前 6%、16–24）
        let shape = RoundedRectangle(cornerRadius: DSRadius.card(width), style: .continuous)
        // 窄于 300 点：小海报、间距、「查看」都收一点。不只展开竖拿（最窄 270）：折起时卡宽跟着窗口走，
        // iPhone 竖拿约 245–293，500–600 宽的分屏窗口一排两张多，一张只有 200–245
        let compact = width < 300
        // 字标的宽是定死的（LogoImage 按比例给了固定宽，外面那层 maxWidth: .infinity 窄不过它），是这一行挤不动的那一截。
        // 按小海报、三道间距、Spacer 最短那一截之外剩下的宽收：有状态胶囊时给字标约四成（「已请求 42%」放得下），
        // 只有「查看」时约五成半（200 出头的卡上「查看」也不出卡）；宽的卡上照旧最宽 120
        let rowFixed: CGFloat = compact ? 76 : 92
        let logoShare: CGFloat = badge != nil ? 0.4 : 0.55
        let logoMax = min(120, max(40, ((width - rowFixed) * logoShare).rounded()))
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                DSFill.placeholder
                // 剧照地址到了也先垫着：剧照那张的占位是透明的，地址一到就拿掉会先露灰底、再淡入剧照（糊 → 灰 → 剧照闪一下）；
                // 剧照不透明，淡入走完（stillCovered）才拿掉，取不到时一直是这张糊的
                if let fallback, !stillCovered {
                    RemoteImage(url: fallback, maxPixel: 120, placeholder: .clear)
                        .frame(width: width, height: h)
                        .blur(radius: 22, opaque: true)
                        .opacity(0.55)
                }
                RemoteImage(url: still, maxPixel: width * 3, placeholder: .clear)
            }
            .frame(width: width, height: h)
            .overlay(alignment: .bottomLeading) {
                if let progress {
                    // 和「继续观看」那排同一种：剧照底边一道细线
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.22))
                        Rectangle().fill(Color.white).frame(width: (width * min(1, max(0, progress))).rounded())
                    }
                    .frame(width: width, height: 3)
                    .animation(.smooth(duration: 0.6), value: progress)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(DSFill.hairline, lineWidth: 1))
            HStack(spacing: compact ? 10 : 12) {
                DSThumb(url: cover, width: compact ? 40 : 48)
                VStack(alignment: .leading, spacing: 3) {
                    if logo != nil {
                        LogoImage(url: logo, height: 18, alignment: .leading, maxWidth: logoMax)
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(DSInk.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: compact ? 6 : 8)
                // 在黑的页面上：蓝字、12% 白的底（DSViewPill）
                if let badge {
                    badge.view(compact: compact)
                } else {
                    DSViewPill(onArt: false, compact: compact)
                }
            }
            // 换成请求状态的胶囊（「已请求 42%」）比「查看」长得多，特大字号时连小海报一起比卡还宽、冲到旁边那张上：
            // 有状态时字号最大到 xxLarge（和精选卡一样封顶）；只有「查看」的卡上限放到最大，和以前一样。
            // 光封顶不够（200 出头的窄卡、宽字标，默认字号也放不下）：字标按卡宽收（logoMax），胶囊放不下时字缩一点（YearCardBadge）
            .dynamicTypeSize(...(badge != nil ? DynamicTypeSize.xxLarge : DynamicTypeSize.accessibility5))
        }
        .frame(width: width, alignment: .leading)
        // 剧照取到以后等它淡入（0.32 秒）走完，再把底下那张糊的拿掉：半透明的时候底下不露灰。
        // 和上面那张剧照同一个地址、同一个尺寸：ImagePipeline 里是同一次下载（或内存里现成的），不多取
        .task(id: still) {
            guard fallback != nil, let still,
                  await ImagePipeline.shared.image(still, maxPixel: width * 3) != nil else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            stillCovered = true
        }
        // 换了一张剧照（剧照那张会先清空再淡入）：先垫回去
        .onChange(of: still) { stillCovered = false }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        // 灰字可能是「2024 · ★ 7.2」：走 DetailText.spoken，念「评分 7.2」，不念「黑星」「间隔号」
        .accessibilityLabel(DetailText.spoken([title, subtitle, badge?.text ?? ""].filter { !$0.isEmpty }.joined(separator: "，")))
    }
}

/// 年份卡右边那颗胶囊换成的状态：和「查看」同一个样子（12% 白的底），只是字和颜色不同
struct YearCardBadge: Equatable {
    enum Tone: Equatable { case accent, plain, alert }
    var text: String
    var tone: Tone

    @MainActor
    func view(compact: Bool) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tone == .accent ? Theme.accent : tone == .alert ? Color(red: 1.0, green: 0.27, blue: 0.23) : Color.white)
            .lineLimit(1)
            // 这一行实在放不下（窄窗口里 200 出头的卡、特大字号）：字缩一点，不再把整行撑得比卡还宽
            .minimumScaleFactor(0.6)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: 32)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            // 只定高、不定宽：以前 .fixedSize() 连宽也定死，放不下时整行冲到旁边那张卡上
            .fixedSize(horizontal: false, vertical: true)
            // 宁可片名截断，状态不被挤扁（和「查看」同一条规矩）：排的时候先给它宽，放得下就是原来的大小，放不下才缩字
            .layoutPriority(1)
            .contentTransition(.numericText())
    }
}

// MARK: - 主页结尾（照用户给的参考图：Apple TV+ 那一页的结尾）
//
// 两排 16:9 的卡（带片名字标：Apple 带片名排版的成品图，没有的用无字背景 + 字标：AppModel.finaleTiles），
// 上一排往左、下一排往右，慢慢横着走（不在屏上、「减弱动态效果」、按了暂停时停：F59）；
// 下面正中一颗描边的胶囊「查看全部影片 ›」进全部影片（AllFilmsView：2026 → 2020 按年份，电影 / 剧集、可立即播放 / 可申请分开），同一行最右边一颗圆的暂停 / 继续
// （参考图：会自己动的内容要停得下来）；手机（折起）上再加一颗铺满宽的白色「立即观看」（参考图手机版的「Stream now」），
// 直接放今天的编辑推荐

/// 结尾那两排里的一张：画面 +（片名没有印在图上时）字标
struct FinaleTile: Hashable, Identifiable {
    let id: String
    let art: URL?
    let logo: URL?
}

struct HomeFinale: View {
    @Environment(AppModel.self) private var model
    let tiles: [FinaleTile]
    let metrics: DSMetrics
    @State private var onScreen = false
    /// 第一次滑到这里才把两排卡建出来。主页这一列不是懒加载的：一启动就建会把这里几十张图连同下载都做了，人多半还没滑到这里
    @State private var built = false
    /// 人按了暂停（右边那颗圆钮）
    @State private var userPaused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tileW: CGFloat = metrics.wide ? 300 : 220
        let tileH = (tileW * 9 / 16).rounded()
        let gap: CGFloat = metrics.wide ? 16 : 12
        let half = (tiles.count + 1) / 2
        // 整个窗口宽（连同侧边那一列）：两排卡铺满它；按钮在内容区（metrics.width）里
        let fullW = metrics.width + metrics.leadingInset + metrics.trailingInset
        // 演示数据只给 UI 测试用：不走（持续的动画会让 XCUITest 一直等不到 App 空闲）；「减弱动态效果」时也不走，暂停钮就不出
        let canMove = !reduceMotion && !DemoData.enabled
        let running = onScreen && canMove && !userPaused
        VStack(spacing: 0) {
            Group {
                if built {
                    VStack(alignment: .leading, spacing: gap) {
                        TileMarquee(tiles: Array(tiles.prefix(half)), tileW: tileW, gap: gap, rightward: false,
                                    shift: 0, running: running)
                        TileMarquee(tiles: Array(tiles.dropFirst(half)), tileW: tileW, gap: gap, rightward: true,
                                    shift: -(tileW + gap) / 2, running: running)
                    }
                } else {
                    // 还没滑到：先占住两排卡一样的高，版面不跳
                    Color.clear.frame(height: tileH * 2 + gap)
                }
            }
            // 宽度写死：一排卡有几千点宽，绝不能让它把这一块（和整个主页那一列）撑宽
            .frame(width: fullW, alignment: .leading)
            .clipped()
            // 裁完再往两边伸：铺到侧边那一列底下，版面上仍只占内容区那么宽
            .padding(.leading, -metrics.leadingInset)
            .padding(.trailing, -metrics.trailingInset)
            .accessibilityHidden(true)
            ZStack {
                NavigationLink(value: Route.shelf(.all)) { lineupPill }
                    .buttonStyle(PressableStyle())
                    .accessibilityIdentifier("home-show-all")
                if canMove {
                    HStack {
                        Spacer(minLength: 0)
                        pauseButton
                    }
                }
            }
            .padding(.horizontal, metrics.margin)
            .padding(.top, metrics.wide ? 32 : 26)
            if !metrics.wide, let pick = model.editorsPick() {
                Button { watchNow(pick) } label: {
                    Text("立即观看")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, metrics.margin)
                .padding(.top, 20)
                .accessibilityHint("播放今天的编辑推荐")
                .accessibilityIdentifier("home-watch-now")
            }
        }
        .frame(width: metrics.width)
        .onScrollVisibilityChange(threshold: 0.1) { v in
            onScreen = v
            if v { built = true }
        }
    }

    /// 「查看全部影片 ›」：描边的胶囊（参考图「See full lineup ›」），看上去 44 高
    private var lineupPill: some View {
        HStack(spacing: 5) {
            Text("查看全部影片")
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
        }
        .font(.headline)
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 22)
        .frame(minHeight: 44)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
        .contentShape(Capsule())
    }

    /// 暂停 / 继续两排卡的走动：看上去 36 点的圆，点按区 44（F74）
    private var pauseButton: some View {
        Button {
            Haptics.light()
            userPaused.toggle()
        } label: {
            Image(systemName: userPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.16)))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(userPaused ? "继续播放滚动画面" : "暂停滚动画面")
        .accessibilityIdentifier("home-finale-pause")
    }

    /// 「立即观看」：直接放今天的编辑推荐（看了一半的从上次的地方接着放）
    private func watchNow(_ v: Video) {
        PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(v),
                                                  subtitle: model.year(v).map { String($0) },
                                                  artwork: model.backgroundArtString(v)), model: model)
    }
}

/// 一排 16:9 的卡，首尾相接地慢慢横着走（每秒约 16 点；一圈是这一行的长度，内容排三遍，接缝看不出来）。
/// 用 30 帧的 TimelineView 推（不是一直跑满屏幕刷新率的无限动画），卡那一排单独成一块、内容不变就不重算；
/// 停下（不在屏上、按了暂停）再走时从停下的地方接着走，不跳
struct TileMarquee: View {
    let tiles: [FinaleTile]
    let tileW: CGFloat
    let gap: CGFloat
    /// true 往右走，false 往左
    let rightward: Bool
    /// 整排先错开多少（第二排错开半张，和第一排交错）
    var shift: CGFloat = 0
    let running: Bool
    @State private var since = Date()
    /// 之前几段走过的时间（秒）
    @State private var elapsed: Double = 0

    var body: some View {
        let unit = (tileW + gap) * CGFloat(tiles.count)
        let row = TileRow(tiles: tiles, tileW: tileW, gap: gap).equatable()
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running || tiles.count < 2)) { ctx in
            let t = elapsed + (running ? max(0, ctx.date.timeIntervalSince(since)) : 0)
            let travel = unit > 0 ? CGFloat((t * 16).truncatingRemainder(dividingBy: Double(unit))) : 0
            row.offset(x: shift + (rightward ? travel - unit : -travel))
        }
        // 两头都给：框就是父视图给的宽，不跟着几千点宽的那一排撑开（多出来的由外面 clipped 裁掉）
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onAppear { if running { since = Date() } }
        .onChange(of: running) { _, now in
            if now { since = Date() } else { elapsed += max(0, Date().timeIntervalSince(since)) }
        }
    }
}

/// 结尾的一排（排三遍）：内容不变时 SwiftUI 不再重算它（Equatable），横移只是挪这一块。
/// 片名没印在图上的那张：底下压一点暗，正中偏下放字标
struct TileRow: View, Equatable {
    let tiles: [FinaleTile]
    let tileW: CGFloat
    let gap: CGFloat

    var body: some View {
        let h = (tileW * 9 / 16).rounded()
        let shape = RoundedRectangle(cornerRadius: DSRadius.card(tileW), style: .continuous)
        HStack(spacing: gap) {
            ForEach(0..<(tiles.count * 3), id: \.self) { i in
                let t = tiles[i % tiles.count]
                ZStack(alignment: .bottom) {
                    Color(white: 0.12)
                    RemoteImage(url: t.art, maxPixel: tileW * 3)
                        .frame(width: tileW, height: h)
                    if let logo = t.logo {
                        LinearGradient(colors: [.black.opacity(0), .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                        LogoImage(url: logo, height: (h * 0.28).rounded(), maxWidth: (tileW * 0.62).rounded())
                            .padding(.bottom, (h * 0.1).rounded())
                    }
                }
                .frame(width: tileW, height: h)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            }
        }
    }
}
