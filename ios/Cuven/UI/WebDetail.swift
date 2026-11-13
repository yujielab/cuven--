import SwiftUI
import UIKit

// MARK: - 详情页：和网页版一致（web/index.html 的 openDetail；尺寸是在 iPhone Duo 上量出来的）
//
// 头部画面高 75vh（至少 540），下半段渐隐进黑，顶上一层压暗。内容从「头部底边往上 35vh」起，居中一列：
// 字标（最大 320×110）→「导演 … · 主演 …」→ 评分 ≥ 8 时「Cuven 品质保证」→ 白胶囊「▶ 立即播放」+ 玻璃圆钮（更多操作）。
// 下面是简介（超过 140 字收成三行，下面一枚「更多」）、演员阵容（查看全部 ›），
// 再是一段铺满宽度的画廊（电影「剧照」第 N 幕；剧集「剧集 · 全 8 集」分集卡），「影片信息」，
// 「尖端色彩和画面质量技术」「语言」两块玻璃卡，最后一行法务说明。剧集和电影是同一个页面，只有画廊那一段不同。

/// 网页版 isCuvenPick：评分 ≥ 8.0 才盖「品质保证」
let cuvenSealMin = 8.0

// MARK: - 电影

struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    let video: Video
    @State private var full: Meta?
    /// Apple TV 上对上的那一部：有就用它的无字背景、竖版全屏图和字标（对不上就是 TMDB 的）
    @State private var atv: AtvLookup?

    var body: some View {
        let meta = full ?? model.meta(video)
        let title = model.title(video)
        let stills = (meta?.stills ?? []).compactMap { $0.url ?? $0.thumb }

        WebDetailScaffold(
            art: atv?.background ?? meta?.backdrop ?? meta?.poster,
            tallArt: atv?.imageTall,
            logo: atv?.logo ?? meta?.logo,
            title: title,
            director: meta?.director,
            cast: meta?.cast ?? [],
            rating: meta?.rating,
            overview: meta?.overview,
            playTitle: "立即播放",
            playID: "detail-play",
            onPlay: { play(meta) },
            file: (path: video.path, name: video.name),
            infoRows: infoRows(meta)
        ) {
            if stills.count >= 2 {
                WebStillsSection(stills: Array(stills.prefix(12)))
            }
        }
        .task { full = await model.fullMeta(for: video) }
        .task(id: video.path) { atv = await model.atv(for: video) }
    }

    /// 网页版「影片信息」：类型 / 格式 / 评分
    private func infoRows(_ m: Meta?) -> [WebInfoRow] {
        let genres = (m?.genres ?? []).joined(separator: " · ")
        var rows = [WebInfoRow(label: "类型", value: "Feature Film · " + (genres.isEmpty ? "未知类型" : genres))]
        rows.append(WebInfoRow(label: "格式", value: WebFormat.line(name: video.name)))
        if let r = m?.rating, r > 0 { rows.append(WebInfoRow(label: "评分", value: String(format: "★ %.1f", r), rating: r)) }
        return rows
    }

    private func play(_ meta: Meta?) {
        PlayerCoordinator.shared.play(PlayRequest(path: video.path, name: video.name, title: model.title(video),
                                                  subtitle: model.year(video).map { String($0) },
                                                  artwork: meta?.backdrop ?? meta?.poster), model: model)
    }
}

// MARK: - 剧集（同一个页面：按钮写「播放第 1 集 / 继续看第 n 集」，画廊换成分集卡）

struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    let series: Series
    /// 季切换：网页版分集标题右边的「第 1 季 ›」
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
        let title = meta?.title ?? current.name
        let next = nextEpisode()

        WebDetailScaffold(
            art: atv?.background ?? meta?.backdrop ?? meta?.poster,
            tallArt: atv?.imageTall,
            logo: atv?.logo ?? meta?.logo,
            title: title,
            director: meta?.director,
            cast: meta?.cast ?? [],
            rating: meta?.rating,
            overview: meta?.overview,
            playTitle: playLabel(next),
            playID: "series-play",
            playDisabled: next == nil,
            onPlay: { if let next, let i = files.firstIndex(of: next.file) { play(index: i) } },
            file: next.map { (path: $0.file.path, name: $0.file.name) },
            infoRows: infoRows(meta),
            audio: audioLine
        ) {
            WebEpisodesSection(
                heading: "剧集 · " + current.countLabel,
                files: files,
                info: info,
                fallbackArt: meta?.backdrop,
                loading: loading,
                failed: failed,
                seasons: seasons,
                current: current,
                pick: { s in withAnimation(.snappy) { picked = s } },
                play: { i in play(index: i) }
            )
        }
        .task(id: current.path) { await load() }
        .task(id: current.path) {
            atv = nil
            await model.ensureSeriesMeta(current)
            atv = await model.atv(for: current)
        }
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

    private var audioLine: String? {
        guard let langs = current.langs, !langs.isEmpty else { return nil }
        var s = langs.joined(separator: "、")
        if let a = current.audio, !a.isEmpty { s += "（" + (a == "Atmos" ? "Dolby Atmos" : a) + "）" }
        return s
    }

    private func infoRows(_ m: Meta?) -> [WebInfoRow] {
        let genres = (m?.genres ?? []).joined(separator: " · ")
        var rows = [WebInfoRow(label: "类型", value: "TV Series · " + (genres.isEmpty ? "未知类型" : genres))]
        rows.append(WebInfoRow(label: "剧集", value: [current.seasonLabel, current.countLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")))
        rows.append(WebInfoRow(label: "格式", value: WebFormat.line(series: current, firstFile: files.first?.name)))
        if let r = m?.rating, r > 0 { rows.append(WebInfoRow(label: "评分", value: String(format: "★ %.1f", r), rating: r)) }
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

// MARK: - 骨架

struct WebInfoRow: Hashable {
    let label: String
    let value: String
    var rating: Double? = nil
}

struct WebDetailScaffold<Gallery: View>: View {
    let art: String?
    /// Apple TV 的竖版全屏图：头部比宽还高（竖拿）时用它，铺满不用裁横图
    var tallArt: String? = nil
    let logo: String?
    let title: String
    let director: String?
    let cast: [CastMember]
    let rating: Double?
    let overview: String?
    let playTitle: String
    let playID: String
    var playDisabled = false
    let onPlay: () -> Void
    /// 「更多操作」弹层对着的文件（剧集是下一集）
    let file: (path: String, name: String)?
    let infoRows: [WebInfoRow]
    var audio: String? = nil
    @ViewBuilder var gallery: () -> Gallery

    @State private var showSheet = false
    @State private var showTitle = false
    @State private var toast: String?

    var body: some View {
        GeometryReader { geo in
            // 网页版的 vh / vw 是整个窗口：把安全区（侧边那一列、底部指示条）加回来
            let vh = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let vw = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
            let heroH = max(540, vh * 0.75)
            let bodyTop = max(220, heroH - vh * 0.35)
            ScrollView {
                ZStack(alignment: .top) {
                    WebDetailBackdrop(art: heroH > vw * 1.05 ? (tallArt ?? art) : art, height: heroH)
                    VStack(alignment: .leading, spacing: 0) {
                        head(vw: vw)
                            .padding(.top, bodyTop)
                        if let o = overview, !o.isEmpty {
                            WebSynopsis(text: o)
                                .padding(.horizontal, Theme.gutter)
                        }
                        if !cast.isEmpty {
                            WebCastSection(people: cast)
                                .padding(.top, 32)
                        }
                        gallery()
                        WebInfoSection(rows: infoRows)
                            .padding(.top, 40)
                            .padding(.horizontal, Theme.gutter)
                        WebTechAndLanguage(audio: audio)
                            .padding(.top, 32)
                            .padding(.horizontal, Theme.gutter)
                    }
                    .padding(.bottom, 80)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            // 滚过字标，片名才出现在导航栏里
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y > bodyTop + 40 } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { showTitle = v }
            }
        }
        .background(Theme.bg)
        .overlay(alignment: .top) { StatusBarScrim() }
        .webToast($toast)
        .navigationTitle(showTitle ? title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // 网页版右上角那颗玻璃圆钮：同一个「更多操作」
            if file != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSheet = true } label: {
                        Label("更多操作", systemImage: "arrow.up.left.and.arrow.down.right.circle")
                            .labelStyle(.iconOnly)
                            .rotationEffect(.degrees(90))
                    }
                }
            }
        }
        .sheet(isPresented: $showSheet) {
            WebFileSheet(title: title, onPlay: onPlay, onCopy: copyLink)
        }
    }

    /// 居中的一列：字标、导演 / 主演、品质保证、按钮
    private func head(vw: CGFloat) -> some View {
        VStack(spacing: 0) {
            Group {
                if let logo, !logo.isEmpty {
                    LogoImage(url: TMDBImage.url(logo, "w500"), height: 110, fallback: title, maxWidth: 320)
                        .frame(maxWidth: 320)
                } else {
                    Text(title)
                        .font(.system(size: min(48, max(32, vw * 0.08)), weight: .heavy))
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.9), radius: 12, y: 4)
                }
            }
            .padding(.bottom, 20)

            if let c = credits {
                Text(c)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                    .padding(.bottom, 24)
            }
            if let r = rating, r >= cuvenSealMin {
                QualitySeal(note: true, size: 12.5, hPad: 12)
                    .padding(.top, -6)
                    .padding(.bottom, 22)
            }
            HStack(spacing: 12) {
                WebPlayButton(title: playTitle, identifier: playID, disabled: playDisabled, action: onPlay)
                Button { showSheet = true } label: { WebCircleLabel() }
                    .buttonStyle(PressableStyle(scale: 0.93))
                    .disabled(file == nil)
                    .accessibilityLabel("更多操作")
                    .accessibilityIdentifier("detail-more")
            }
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.gutter)
    }

    /// 「导演 苏念 · 主演 陈默 · 许晴 · 顾言」：标签 40% 白、半粗；名字 65% 白；中间的点再淡一半
    private var credits: AttributedString? {
        func part(_ label: String, _ value: String) -> AttributedString {
            var l = AttributedString(label + " ")
            l.font = .system(size: 13, weight: .semibold)
            l.foregroundColor = .white.opacity(0.4)
            var v = AttributedString(value)
            v.font = .system(size: 13)
            v.foregroundColor = .white.opacity(0.65)
            return l + v
        }
        var parts: [AttributedString] = []
        if let d = director, !d.isEmpty { parts.append(part("导演", d)) }
        if !cast.isEmpty { parts.append(part("主演", cast.prefix(3).map(\.name).joined(separator: " · "))) }
        guard var out = parts.first else { return nil }
        var sep = AttributedString("  ·  ")
        sep.font = .system(size: 13)
        sep.foregroundColor = .white.opacity(0.2)
        for p in parts.dropFirst() { out += sep + p }
        return out
    }

    /// 「复制直链」：和网页版一样，签好名的 /stream 地址（可在 VLC 等播放器里打开）
    private func copyLink() {
        guard let file else { return }
        Task { @MainActor in
            await StreamLink.copy(path: file.path, name: file.name)
            withAnimation(.snappy) { toast = "直链已复制" }
        }
    }
}

/// 头部画面：铺满、往下渐隐进黑（网页版 mask：50% 以下渐隐），顶上 25% 压暗；侧边那一列底下延伸，下拉时撑大
struct WebDetailBackdrop: View {
    let art: String?
    let height: CGFloat

    var body: some View {
        Color.black
            .overlay { RemoteImage(url: TMDBImage.url(art, "w1280"), maxPixel: 1800, placeholder: .clear) }
            .clipped()
            .overlay {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
            }
            .overlay {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.5),
                    .init(color: .black.opacity(0.5), location: 0.75),
                    .init(color: .black, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .backgroundExtensionEffect()
            .frame(height: height)
            .stretchy()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 白色胶囊播放钮（网页版 .detail-actions .btn-play：高 50、左右 48、16 号粗体黑字，白色微光）
struct WebPlayButton: View {
    let title: String
    let identifier: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill").font(.system(size: 15, weight: .bold))
                Text(title).font(.system(size: 16, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 48)
            .frame(height: 50)
            .background(Color.white, in: Capsule())
            .shadow(color: .white.opacity(0.15), radius: 12, y: 8)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
        .accessibilityIdentifier(identifier)
    }
}

/// 玻璃圆钮（网页版 .btn-circle：50×50、图标 22）
struct WebCircleLabel: View {
    var body: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right.circle")
            .rotationEffect(.degrees(90))
            .font(.system(size: 22))
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
    }
}

/// 简介：15 号、行高 1.6、88% 白；超过 140 字收成三行，下面一枚「更多 ⌄ / 收起 ⌃」
struct WebSynopsis: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        let long = text.count > 140
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 15))
                .lineSpacing(6)
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(long && !expanded ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
            if long {
                Button {
                    withAnimation(.smooth(duration: 0.4)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "收起" : "更多")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 14)
                    .padding(.trailing, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.94))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「演员阵容」（22 粗体）+ 右边「查看全部 ›」（整行可点，弹出完整的演员阵容）；下面一排 120 的圆头像、名字（15 半粗）、
/// 角色（14、65% 白），点一位弹出那位演员（网页版 setupCastClicks：横排头像 → openActorSheet，标题行 → openFullCastSheet）
struct WebCastSection: View {
    let people: [CastMember]
    @State private var showAll = false
    @State private var picked: ActorPick?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                Haptics.light()
                showAll = true
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Text("演员阵容")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        if people.count > 12 {
                            Text("共 \(people.count) 位").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                        }
                        Text("查看全部")
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .accessibilityIdentifier("cast-link")
            .padding(.horizontal, Theme.gutter)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Array(people.prefix(12).enumerated()), id: \.offset) { _, c in
                        Button {
                            Haptics.light()
                            picked = ActorPick(member: c)
                        } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                WebCastAvatar(name: c.name, url: c.profileURL)
                                    .padding(.bottom, 12)
                                Text(c.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.bottom, 3)
                                if let ch = c.character, !ch.isEmpty {
                                    Text(ch)
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white.opacity(0.65))
                                        .lineLimit(2)
                                }
                            }
                            .frame(width: 120, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle(scale: 0.96))
                        .accessibilityIdentifier("cast-card")
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Theme.gutter, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
        .sheet(isPresented: $showAll) { CastSheet(people: people) }
        .sheet(item: $picked) { p in ActorSheet(member: p.member) }
    }
}

/// 网页版 .cast-avatar-small：120 的圆，发丝描边、投影；没有照片时是名字的头一个字（38 粗体）压在深灰渐变上
struct WebCastAvatar: View {
    let name: String
    let url: URL?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255), Color(red: 26 / 255, green: 26 / 255, blue: 28 / 255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            if url != nil {
                RemoteImage(url: url, maxPixel: 360, placeholder: .clear)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 8)
    }
}

/// 画廊那一段的壳（网页版 .stills-section）：上面 40、一条铺满宽度的发丝线、28，标题 18 粗体，下面 24 是横排
struct WebGallerySection<Trailing: View, Content: View>: View {
    let heading: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                .padding(.top, 40)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(heading)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 28)
            .padding(.bottom, 24)
            content()
        }
    }
}

/// 「剧照」：260×300 的竖卡（圆角 18），卡下一行「第 N 幕」
struct WebStillsSection: View {
    let stills: [String]

    var body: some View {
        WebGallerySection(heading: "剧照") { EmptyView() } content: {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(Array(stills.enumerated()), id: \.offset) { i, s in
                        VStack(alignment: .leading, spacing: 0) {
                            Color.white.opacity(0.04)
                                .overlay { RemoteImage(url: TMDBImage.url(s, "w780"), maxPixel: 900, placeholder: .clear) }
                                .frame(width: 260, height: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
                            Text("第 \(i + 1) 幕")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255))
                                .padding(.horizontal, 4)
                                .padding(.top, 16)
                        }
                        .frame(width: 260, alignment: .leading)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Theme.gutter, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// 「剧集 · 全 8 集」+ 右边「第 1 季 ›」（不止一季才有）；下面一排分集卡
struct WebEpisodesSection: View {
    @Environment(AppModel.self) private var model
    let heading: String
    let files: [EpisodeFile]
    let info: [Int: SeasonEpisode]
    let fallbackArt: String?
    let loading: Bool
    let failed: String?
    let seasons: [Series]
    let current: Series
    let pick: (Series) -> Void
    let play: (Int) -> Void
    @State private var tileWidth: CGFloat = 300
    /// 分集简介的「更多」：网页版 tvEpDescSheet
    @State private var episodeSheet: EpisodeSheetItem?

    var body: some View {
        WebGallerySection(heading: heading) {
            if seasons.count > 1 {
                Menu {
                    Picker("季", selection: Binding(get: { current.path }, set: { p in
                        guard let s = seasons.first(where: { $0.path == p }), s.path != current.path else { return }
                        Haptics.selection()
                        pick(s)
                    })) {
                        ForEach(seasons, id: \.path) { s in Text(s.seasonLabel ?? s.season.map { "第 \($0) 季" } ?? s.name).tag(s.path) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(current.seasonLabel ?? "选择季")
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("season-menu")
            }
        } content: {
            if files.isEmpty {
                Group {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        Text(failed ?? "暂无可播放文件").font(.system(size: 14)).foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, Theme.gutter)
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                            let ep = f.ep.flatMap { info[$0] }
                            WebEpisodeTile(file: f, info: ep, fallbackArt: fallbackArt,
                                           progress: model.playback.entry(f.path)?.fraction, width: tileWidth,
                                           onPlay: { play(i) },
                                           onMore: { episodeSheet = WebEpisodeTile.sheetItem(file: f, info: ep) })
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, Theme.gutter, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
            }
        }
        // 网页版：卡宽 min(74vw, 300)、高按 300:169
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            tileWidth = min(300, max(220, w * 0.78))
        }
        .sheet(item: $episodeSheet) { EpisodeSheet(item: $0) }
    }
}

/// 网页版的分集卡：16:9 剧照（圆角 18），左上「第 1 集」小牌（看完了带「· 已看」、剧照暗一档），右下播放圆钮；
/// 卡下集名（半粗）接着简介（三行封顶，真被截断了第三行末尾压一枚「更多」，点开是整段简介的弹层），再一行「45 分钟」。
/// 点卡（剧照或下面的字）放这一集；「更多」是单独的一颗钮，不顺手把这一集放了
struct WebEpisodeTile: View {
    let file: EpisodeFile
    let info: SeasonEpisode?
    let fallbackArt: String?
    let progress: Double?
    let width: CGFloat
    let onPlay: () -> Void
    var onMore: (() -> Void)? = nil
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    var body: some View {
        let done = (progress ?? 0) >= 0.9
        let still = info?.still
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onPlay) {
                ZStack {
                    Color.white.opacity(0.04)
                    if let still {
                        RemoteImage(url: TMDBImage.url(still, "w780"), maxPixel: width * 3, placeholder: .clear)
                            .opacity(done ? 0.52 : 1)
                    } else {
                        Text(String(format: "%02d", file.ep ?? 0))
                            .font(.system(size: 46, weight: .heavy))
                            .tracking(-1.4)
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.14))
                    }
                    Text(Self.badge(file) + (done ? " · 已看" : ""))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .background(Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255).opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                        .environment(\.colorScheme, .dark)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                    Image(systemName: "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255).opacity(0.5), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                        .environment(\.colorScheme, .dark)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(11)
                    if let p = progress, p > 0.01, !done {
                        ProgressCapsule(fraction: p)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(.leading, 14).padding(.trailing, 62).padding(.bottom, 26)
                    }
                }
                .frame(width: width, height: width * 169 / 300)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("episode-card")

            VStack(alignment: .leading, spacing: 0) {
                Text(caption(done: done))
                    .lineLimit(3)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in shownHeight = h }
                    // 不限行数的同一段字（看不见），只用来量全文多高：比三行高才露出「更多」（网页版 tvEpClampCheck）
                    .background(alignment: .top) {
                        Text(caption(done: done))
                            .lineSpacing(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in fullHeight = h }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let onMore, fullHeight > shownHeight + 1 {
                            moreButton(onMore)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 16)
                    .frame(width: width, alignment: .leading)
                let rt = info?.runtime.map { "\($0) 分钟" } ?? ""
                if !rt.isEmpty {
                    Text(rt)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)
        }
        .frame(width: width, alignment: .leading)
    }

    /// 「第 1 集」（没有集号就是文件名）
    static func badge(_ f: EpisodeFile) -> String {
        f.ep.map { "第 \($0) 集" } ?? FileName.stem(f.name)
    }

    /// 网页版 tvEpDescSheet 的那张：「第 1 集 · 45 分钟」、集名、整段简介
    static func sheetItem(file: EpisodeFile, info: SeasonEpisode?) -> EpisodeSheetItem {
        let kicker = [badge(file), info?.runtime.map { "\($0) 分钟" }].compactMap { $0 }.joined(separator: " · ")
        let title = info?.name.flatMap { $0.isEmpty ? nil : $0 } ?? badge(file)
        return EpisodeSheetItem(kicker: kicker, title: title, overview: info?.overview ?? "")
    }

    /// 压在第三行行尾的「更多」（网页版 .ep-more：高 20、左右 9、11.5 号半粗，深灰半透明 + 模糊，发丝描边）；
    /// 左边一条 56 宽的收尾带，字先淡掉再碰到它
    private func moreButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("更多")
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(-0.07)
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color(red: 66 / 255, green: 66 / 255, blue: 70 / 255).opacity(0.86), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                .environment(\.colorScheme, .dark)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .background(alignment: .leading) {
            LinearGradient(stops: [.init(color: Theme.bg.opacity(0), location: 0), .init(color: Theme.bg, location: 0.82)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 56)
                .padding(.vertical, -4)
                .offset(x: -56)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("更多")
        .accessibilityIdentifier("episode-more")
    }

    /// 「第 1 个故事 演示分集简介…」：标题 13 半粗白字，简介同字号 60% 灰
    private func caption(done: Bool) -> AttributedString {
        let name = info?.name ?? Self.badge(file)
        var t = AttributedString(name)
        t.font = .system(size: 13, weight: .semibold)
        t.foregroundColor = done ? .white.opacity(0.65) : Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
        if let o = info?.overview, !o.isEmpty {
            var d = AttributedString(" " + o)
            d.font = .system(size: 13)
            d.foregroundColor = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.6)
            t += d
        }
        return t
    }
}

/// 「影片信息」（18 粗体）：一行一项，左边 40% 白、右边白色半粗，行下 5% 发丝线；评分后面跟 TMDB 与「品质保证」
struct WebInfoSection: View {
    let rows: [WebInfoRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                .padding(.bottom, 28)
            Text("影片信息")
                .font(.system(size: 18, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(.white)
                .padding(.bottom, 16)
            ForEach(rows, id: \.self) { r in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(r.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(r.value)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.trailing)
                        if let rating = r.rating {
                            Text(" TMDB").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                            if rating >= cuvenSealMin {
                                QualitySeal(hPad: 9)
                                    .padding(.leading, 8)
                                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5) }
            }
        }
    }
}

/// 「尖端色彩和画面质量技术」两张说明 +「语言」+ 法务一行（文案与网页版一致）
struct WebTechAndLanguage: View {
    var audio: String? = nil

    private static let soft = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("尖端色彩和画面质量技术")
            VStack(alignment: .leading, spacing: 0) {
                techGroup("HDR Ultimate", "高动态技术 (HDR Ultimate) 绚丽生动的色彩、更锐利的对比度和更丰富的细节，为你呈现精致鲜活的迷人画质。")
                separator
                techGroup("Dolby Atmos", "声音以前所未有的层次感、清晰度和细节，让你尽享全方位萦绕的声音体验。")
            }
            .webGlassCard()

            sectionTitle("语言")
                .padding(.top, 28)
            VStack(alignment: .leading, spacing: 0) {
                langItem("原始音频", "English")
                separator
                langItem("音频", audio ?? "English (Dolby Atmos、Dolby Digital 7.1、Dolby 5.1、AAC、AD)")
                separator
                langItem("字幕", "Arabic、Bulgarian、Croatian、Czech、Danish、Dutch、English (SDH)、Estonian、Finnish、Greek、Hebrew、Hungarian、Icelandic、Latvian、Lithuanian、Norwegian、Polish、Portuguese、Slovak、Slovenian、Swedish、Turkish、Ukrainian")
            }
            .webGlassCard()

            Text("有关法律责任和信息 CUVEN 均不受理 适用法务归属为卢森堡地区")
                .font(.system(size: 13))
                .tracking(0.2)
                .foregroundStyle(Self.soft.opacity(0.3))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Self.soft.opacity(0.55))
            .padding(.bottom, 8)
    }

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5).padding(.horizontal, 20)
    }

    private func techGroup(_ badge: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(badge.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
            Text(desc)
                .font(.system(size: 14))
                .tracking(0.2)
                .lineSpacing(6)
                .foregroundStyle(Self.soft.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private func langItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 15))
                .tracking(0.2)
                .foregroundStyle(Self.soft.opacity(0.45))
            Text(value)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

extension View {
    /// 网页版 .detail-info-glass：白 4% 底、1px 白 8% 描边、圆角 20、上沿一道高光
    func webGlassCard() -> some View {
        self
            .padding(.vertical, 4)
            .background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.08)), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - 弹层（网页版 openSheet：片名、一两行大按钮、取消）

struct WebSheetRow {
    let symbol: String
    let tint: Color
    let label: String
    let note: String
    let id: String
    let action: () -> Void

    static let orange = Color.orange
    static let blue = Color(red: 10 / 255, green: 132 / 255, blue: 1)
}

struct WebActionSheet: View {
    let title: String
    let rows: [WebSheetRow]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 24)
                .padding(.top, 26)
                .padding(.bottom, 24)
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                Button {
                    dismiss()
                    r.action()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: r.symbol)
                            .font(.system(size: 22))
                            .foregroundStyle(r.tint)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.label).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            Text(r.note).font(.system(size: 13)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 24)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.98))
                .padding(.bottom, 12)
                .accessibilityIdentifier(r.id)
            }
            Button { dismiss() } label: {
                Text("取消")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .padding(.top, 12)
            .accessibilityIdentifier("sheet-cancel")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .presentationDetents([.height(CGFloat(150 + rows.count * 80))])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .environment(\.colorScheme, .dark)
    }
}

/// 网页版 openSheetForFile：「播放」（站内播放 · 杜比视界 · HDR · 多音轨字幕）「复制直链」（在 VLC 等其它播放器中打开）
struct WebFileSheet: View {
    let title: String
    let onPlay: () -> Void
    let onCopy: () -> Void

    var body: some View {
        WebActionSheet(title: title, rows: [
            WebSheetRow(symbol: "play.circle.fill", tint: WebSheetRow.orange, label: "播放", note: "站内播放 · 杜比视界 · HDR · 多音轨字幕", id: "sheet-play", action: onPlay),
            WebSheetRow(symbol: "link", tint: WebSheetRow.blue, label: "复制直链", note: "在 VLC 等其它播放器中打开", id: "sheet-copy", action: onCopy),
        ])
    }
}

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

/// 剧集「接着看」：取分集清单，按网页版 tvNextEp 的规矩挑一集放（年份页、搜索结果的「…」用）
enum SeriesPlayback {
    @MainActor static func playNext(_ s: Series, model: AppModel) async -> Bool {
        var files: [EpisodeFile]
        if DemoData.enabled {
            files = DemoData.episodes(s)
        } else {
            files = (try? await APIClient.shared.episodes(seriesPath: s.path)) ?? []
            files.sort { ($0.ep ?? Int.max, $0.name) < ($1.ep ?? Int.max, $1.name) }
        }
        guard !files.isEmpty else { return false }
        var index = 0
        if let last = model.playback.lastEpisode(of: s.path), let i = files.firstIndex(where: { $0.path == last.path }) {
            index = last.fraction < 0.9 ? i : min(i + 1, files.count - 1)
        }
        let meta = model.seriesMetas[s.path]
        func req(_ f: EpisodeFile) -> PlayRequest {
            PlayRequest(path: f.path, name: f.name, title: meta?.title ?? s.name, subtitle: f.ep.map { "第 \($0) 集" },
                        artwork: meta?.backdrop, seriesPath: s.path, episode: f.ep)
        }
        var r = req(files[index])
        r.queue = files[(index + 1)...].map { req($0) }
        PlayerCoordinator.shared.play(r, model: model)
        return true
    }
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
