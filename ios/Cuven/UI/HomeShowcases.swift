import SwiftUI
import AVFoundation

// MARK: - 主页「编辑推荐」（照用户给的参考图：Apple「游戏」App 首页的「重磅更新」大卡）
//
// 一整块铺满窗口宽（连同 iPhone Duo 侧边那一列）：
// · 底下是这一部的预告片（静音、从第 10 秒起、放完回到第 10 秒；和资料库同一个 ShowcaseTrailer），起来之前
//   （或者没有预告片）是 Apple TV 的竖版主视觉（横着的屏用横版背景），预告片出画面时模糊淡入；
// · 左上一行大号粗体「编辑推荐」；右上一颗播放 / 暂停 + 进度环（有预告片才出现：F77）；
// · 底部一张从画面取色的圆角面板：小海报 + 字标（没有字标写片名）、「科幻 · 2024」、简介的第一句、「查看影片 ›」；
// · 整块点进详情（从这一块上放大出来）。只在屏上、这一页在前台时放；同一时刻全 App 只放一段（TrailerFocus）。
// 每天换一部（AppModel.editorsPick：评分高、有字标和竖版画面、不和头图撞车，查到有预告片的优先）。

struct EditorsPick: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let metrics: DSMetrics
    /// 窗口的高：竖着的屏这一块约是宽的 1.3 倍高，横着的屏 0.56 倍，最多窗口高的 82%
    let fullHeight: CGFloat
    /// 竖着的这一块按高铺满、横向裁掉两边：画面被放大，要 1080 的码流才露出来（低码率的开头先停在海报画面上）
    @State private var trailer = ShowcaseTrailer(revealHeight: 1080)
    @State private var tone: Color?
    @State private var onScreen = false

    static func height(fullWidth w: CGFloat, fullHeight: CGFloat) -> CGFloat {
        min(w < 600 ? w * 1.3 : w * 0.56, fullHeight * 0.82).rounded()
    }

    var body: some View {
        let fullW = metrics.width + metrics.leadingInset + metrics.trailingInset
        let h = Self.height(fullWidth: fullW, fullHeight: fullHeight)
        let still = stillArt(portrait: h > fullW * 0.9, fullWidth: fullW)
        ZStack(alignment: .topTrailing) {
            ZoomLink(route: .movie(video), slot: "editors-pick", press: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("编辑推荐")
                        .font(.system(size: metrics.wide ? 44 : 36, weight: .heavy))
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
            }
            .accessibilityIdentifier("editors-pick")
            if trailer.loaded && trailer.path == video.path {
                ShowcaseControl(trailer: trailer)
                    .padding(.trailing, metrics.margin - 6)
                    .padding(.top, metrics.wide ? 30 : 22)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: trailer.loaded)
        .onScrollVisibilityChange(threshold: 0.4) { visible in
            onScreen = visible
            if visible { trailer.mount(video, model: model) }
            trailer.setCovered(!visible)
        }
        .onAppear { trailer.setVisible(true) }
        .onDisappear { trailer.setVisible(false) }
        .onChange(of: video.path) {
            trailer.unmount()
            if onScreen { trailer.mount(video, model: model) }
        }
        .task(id: still) { await loadTone(still) }
    }

    /// 预告片起来之前的画面：竖着的这一块用 Apple TV 的竖版主视觉（没有就横版背景），横着的用横版背景
    private func stillArt(portrait: Bool, fullWidth: CGFloat) -> URL? {
        let wide = TMDBImage.url(model.backgroundArtString(video), "w1280")
        guard portrait else { return wide }
        return model.featuredArt(video, width: fullWidth)?.url ?? wide
    }

    private func media(still: URL?, pixel: CGFloat) -> some View {
        ZStack {
            Color(white: 0.08)
            RemoteImage(url: still, maxPixel: pixel, placeholder: .clear)
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
        let line = CollectionText.tagline(meta?.overview)
        return HStack(alignment: .center, spacing: 16) {
            RemoteImage(url: model.thumbArt(video), maxPixel: 300)
                .frame(width: 66, height: 99)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                if !kicker.isEmpty {
                    Text(kicker)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
                LogoImage(url: model.wideLockupArt(video).logo, height: metrics.wide ? 46 : 38, alignment: .leading,
                          fallback: model.title(video), maxWidth: 220)
                if let line {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    Text("查看影片")
                    Image(systemName: "chevron.forward")
                        .font(.subheadline.weight(.bold))
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill((tone ?? Color(white: 0.16)).opacity(0.94)))
        .accessibilityElement(children: .combine)
    }

    /// 面板的颜色：画面最下面那一截的平均色，压暗、收一点饱和度（白字看得清）
    private func loadTone(_ url: URL?) async {
        guard let url, let img = await ImagePipeline.shared.image(url, maxPixel: 64), let cg = img.cgImage,
              let c = ImageEffects.averageColor(cg, bottom: 0.3) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return }
        let t = Color(hue: Double(h), saturation: Double(min(0.5, s)), brightness: Double(min(0.38, max(0.2, b * 0.7))))
        withAnimation(.easeInOut(duration: 0.5)) { tone = t }
    }
}

// MARK: - 主页「2026 ›」「2025 ›」（照用户给的参考图：游戏 App「Arcade 名人堂」那一排）
//
// 标题一行大号粗体 +「›」（点进年份页），下面一行灰字；一排卡：上面一行标语（简介的第一句），中间 16:9 的预告片，
// 下面小海报、字标、片名、一行灰字，右边「查看」。同一排同一时刻只放一段：最靠左、整张露出来的那一张
// （静音、从第 10 秒起；这一排滑出屏幕、换页、正片盖上来就停；全 App 同一时刻只放一段：TrailerFocus）。
// 没有预告片的那张停在横版背景上。

struct YearTrailerRow: View {
    @Environment(AppModel.self) private var model
    let year: Int
    let items: [HomeEntry]
    let metrics: DSMetrics
    /// 卡上的画面约 490 像素高：码流升到 540 再露出来（开头那几秒的低码率画面糊，先停在横版背景上）
    @State private var trailer = ShowcaseTrailer(revealHeight: 540)
    /// 横着这一排里整张露出来的卡
    @State private var shown: Set<String> = []
    /// 这一排在屏上（竖着滚）
    @State private var onScreen = false

    var body: some View {
        let w = metrics.wideCardWidth
        VStack(alignment: .leading, spacing: metrics.titleGap + 2) {
            header
            DSShelf(metrics: metrics) {
                ForEach(items) { e in
                    card(e, width: w)
                        .onScrollVisibilityChange(threshold: 0.7) { v in
                            if v { shown.insert(e.id) } else { shown.remove(e.id) }
                            sync()
                        }
                }
            }
        }
        .onScrollVisibilityChange(threshold: 0.35) { v in
            onScreen = v
            sync()
        }
        .onAppear { trailer.setVisible(true) }
        .onDisappear { trailer.setVisible(false) }
    }

    /// 放哪一张：这一排在屏上时，最靠左、整张露出来的那一张
    private func sync() {
        guard onScreen, let e = items.first(where: { shown.contains($0.id) }) else {
            trailer.setCovered(true)
            return
        }
        switch e {
        case .movie(let v):
            trailer.mount(v, model: model)
        case .series(let s):
            trailer.mount(key: Self.key(e)) { @MainActor [model] in
                let hit = await model.atv(for: s)
                return AppModel.playable(hit?.trailers)
            }
        }
        trailer.setCovered(false)
    }

    static func key(_ e: HomeEntry) -> String {
        switch e {
        case .movie(let v): return v.path
        case .series(let s): return "s:" + s.path
        }
    }

    /// 「2026 ›」+ 灰字（参考图「Arcade 名人堂 › / 知名角色等你來相遇」）
    private var header: some View {
        let current = Calendar.current.component(.year, from: Date())
        let sub = year == current ? "今年上映的新片与新剧" : "\(year) 年上映的电影和剧集"
        return NavigationLink(value: Route.year(year)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(year))
                        .font(metrics.wide ? .largeTitle.bold() : .title.bold())
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.forward")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer(minLength: 0)
                }
                Text(sub)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, metrics.margin)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .accessibilityIdentifier("section-\(year)")
    }

    @ViewBuilder private func card(_ e: HomeEntry, width w: CGFloat) -> some View {
        let playing: ShowcaseTrailer? = trailer.path == Self.key(e) ? trailer : nil
        switch e {
        case .movie(let v):
            let meta = model.meta(v)
            let y: String? = model.year(v).map { String($0) }
            let sub = DetailText.line([y, meta?.genres?.first])
            ZoomLink(route: .movie(v), slot: "year-\(year)") {
                YearTrailerCard(line: CollectionText.tagline(meta?.overview) ?? sub,
                                still: TMDBImage.url(model.backgroundArtString(v), "w1280"),
                                cover: model.thumbArt(v), logo: model.wideLockupArt(v).logo,
                                title: model.title(v), subtitle: sub, width: w, trailer: playing)
            }
            .accessibilityIdentifier("movie-card")
            .movieMenu(v)
        case .series(let s):
            let sm = model.seriesMetas[s.path]
            let art = model.seriesWideArt(s)
            let sub = DetailText.line([s.seasonLabel, sm?.genres?.first])
            ZoomLink(route: .series(s), slot: "year-\(year)") {
                YearTrailerCard(line: CollectionText.tagline(sm?.overview) ?? sub,
                                still: art.url, cover: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w185"), logo: art.logo,
                                title: sm?.title ?? s.name, subtitle: sub, width: w, trailer: playing)
            }
            .accessibilityIdentifier("series-card")
            .seriesMenu(s)
            .task { await model.ensureSeriesMeta(s) }
        }
    }
}

/// 年份那两排的一张卡：上面一行标语；中间 16:9 的画面（正在放的那一张，预告片出画面时从模糊里淡入）；
/// 下面一行：小海报、字标、片名、一行灰字，右边蓝字「查看」（参考图卡底那一行）
struct YearTrailerCard: View {
    let line: String
    let still: URL?
    let cover: URL?
    let logo: URL?
    let title: String
    let subtitle: String
    let width: CGFloat
    /// 这一张正在放：那一段的播放器（nil = 只放画面）
    let trailer: ShowcaseTrailer?

    var body: some View {
        let h = (width * 9 / 16).rounded()
        let radius: CGFloat = max(16, min(24, (width * 0.06).rounded()))
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Text(line)
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            ZStack {
                Color(white: 0.1)
                RemoteImage(url: still, maxPixel: width * 3, placeholder: .clear)
                if let trailer {
                    VideoSurface(player: trailer.player, gravity: .resizeAspectFill, background: .clear)
                        .opacity(trailer.showing ? 1 : 0)
                        .blur(radius: trailer.showing ? 0 : 14)
                        .animation(.easeInOut(duration: 0.8), value: trailer.showing)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: h)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            HStack(spacing: 12) {
                RemoteImage(url: cover, maxPixel: 200)
                    .frame(width: 48, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 3) {
                    if logo != nil {
                        LogoImage(url: logo, height: 18, alignment: .leading, maxWidth: 120)
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                Text("查看")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 32)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle, line].filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

// MARK: - 主页结尾（照用户给的参考图：游戏 App「Arcade」页的结尾）
//
// 两行圆角海报错开排着、慢慢横着走（上一行往左、下一行往右；不在屏上、「减弱动态效果」时停：F59），
// 下面「Cuven max」字标，一颗胶囊「显示所有影片」进全部影片（电影和剧集一起的海报网格）

struct HomeFinale: View {
    let posters: [URL]
    let metrics: DSMetrics
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tileW: CGFloat = metrics.wide ? 118 : 92
        let gap: CGFloat = metrics.wide ? 16 : 12
        let half = (posters.count + 1) / 2
        // 演示数据只给 UI 测试用：海报墙不走（持续的动画会让 XCUITest 一直等不到 App 空闲）
        let running = onScreen && !reduceMotion && !DemoData.enabled
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: gap) {
                PosterMarquee(posters: Array(posters.prefix(half)), tileW: tileW, gap: gap, rightward: false, running: running)
                PosterMarquee(posters: Array(posters.dropFirst(half)), tileW: tileW, gap: gap, rightward: true, running: running)
                    .padding(.leading, -(tileW + gap) / 2)
            }
            // minWidth + maxWidth 两头都给：一排海报有三千多点宽，只给 maxWidth 的话框会跟着孩子撑宽，
            // 整个主页那一列跟着变成三千多点宽（居中的字标、按钮、精选区的立体海报都跑到屏幕外面去）
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            // 铺到侧边那一列底下
            .padding(.leading, -metrics.leadingInset)
            .padding(.trailing, -metrics.trailingInset)
            .clipped()
            .accessibilityHidden(true)
            CuvenWordmark()
                .padding(.top, metrics.wide ? 40 : 32)
            NavigationLink(value: Route.shelf(.all)) {
                Text("显示所有影片")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: 360)
                    .frame(height: 54)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .padding(.top, 18)
            .padding(.horizontal, metrics.margin)
            .accessibilityIdentifier("home-show-all")
        }
        .frame(maxWidth: .infinity)
        .onScrollVisibilityChange(threshold: 0.1) { onScreen = $0 }
    }
}

/// 一行海报，首尾相接地慢慢横着走（每秒约 16 点；一圈是这一行的长度，内容排三遍，接缝看不出来）。
/// 用 30 帧的 TimelineView 推（不是一直跑满屏幕刷新率的无限动画），海报那一排单独成一块、内容不变就不重算；
/// 不在屏上、「减弱动态效果」、演示数据（UI 测试）时停
struct PosterMarquee: View {
    let posters: [URL]
    let tileW: CGFloat
    let gap: CGFloat
    /// true 往右走，false 往左
    let rightward: Bool
    let running: Bool
    @State private var since = Date()

    var body: some View {
        let unit = (tileW + gap) * CGFloat(posters.count)
        let row = PosterRow(posters: posters, tileW: tileW, gap: gap).equatable()
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running || posters.count < 2)) { ctx in
            let t = max(0, ctx.date.timeIntervalSince(since))
            let travel = unit > 0 ? CGFloat((t * 16).truncatingRemainder(dividingBy: Double(unit))) : 0
            row.offset(x: rightward ? travel - unit : -travel)
        }
        // 两头都给：框就是父视图给的宽，不跟着三千多点宽的那一排撑开（多出来的由外面 clipped 裁掉）
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// 海报墙的一排（排三遍）：内容不变时 SwiftUI 不再重算它（Equatable），横移只是挪这一块
struct PosterRow: View, Equatable {
    let posters: [URL]
    let tileW: CGFloat
    let gap: CGFloat

    var body: some View {
        let radius = (tileW * 0.16).rounded()
        HStack(spacing: gap) {
            ForEach(0..<(posters.count * 3), id: \.self) { i in
                RemoteImage(url: posters[i % posters.count], maxPixel: tileW * 3)
                    .frame(width: tileW, height: (tileW * 1.5).rounded())
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            }
        }
    }
}

/// 「Cuven max」字标（登录页同一套字：圆体，Cuven 中等、max 特粗）
struct CuvenWordmark: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("Cuven")
                .font(.system(size: 24, weight: .medium, design: .rounded))
            Text("max")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .tracking(-0.8)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cuven max")
    }
}
