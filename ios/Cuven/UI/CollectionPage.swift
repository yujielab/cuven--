import SwiftUI

// MARK: - 合集页：四个大类、某一类、精选电影、精选剧集（主页分区标题「›」进来的）
//
// 照用户给的参考图（Apple「游戏」App 的合集页「花一個週末來破關」）：
// · 整页最顶上一片主色（从排在最前那部的海报取），往下沉到黑；铺到状态栏、导航栏和侧边那一列底下；
// · 三张立体海报封面斜着叠成一扇（和主页精选区同一套：第一次出现时弹开、在屏上时轻轻浮动、滚动时比字慢）；
// · 大号粗体标题 + 一句灰字说明；导航栏里先不写字（只有返回钮），滚过大标题才把标题接上去；
// · 下面一列大卡：宽银幕的画面，底下一条从画面取色的条——小海报、「Cuven 独占」、片名、「年份 · 类型」、「查看」（简介只在详情页：用户要求）；
//   点卡进详情（从卡上放大出来），长按是「播放 / 想看」菜单（C21、C45）。宽的屏一行两张、三张。

struct CollectionPage: View {
    @Environment(AppModel.self) private var model
    let shelf: Shelf
    let entries: [HomeEntry]

    var body: some View {
        CollectionScaffold(title: shelf.title, titleBottom: { FeaturedCollectionHeader.titleBottom($0) }) { m in
            FeaturedCollectionHeader(title: shelf.title, blurb: shelf.blurb ?? "", covers: covers,
                                     metrics: m, page: true)
            if entries.isEmpty {
                ContentUnavailableView("暂无影片", systemImage: "film",
                                       description: Text("这一类的电影和剧集会显示在这里。"))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            } else {
                CollectionGrid(metrics: m) { w in
                    ForEach(entries) { e in CollectionEntryCard(entry: e, width: w, slot: "collection-" + shelf.key) }
                }
            }
        }
    }

    /// 顶上三张立体海报：排在最前的三部（印着片名的海报）
    private var covers: [URL?] {
        entries.prefix(3).map { (e: HomeEntry) -> URL? in Self.cover(e, model: model) }
    }

    /// 一部的封面（印着片名的海报）：立体海报用它，页顶的底色也从排在最前那部的这一张取（分类页也是）
    static func cover(_ e: HomeEntry, model: AppModel) -> URL? {
        switch e {
        case .movie(let v):
            return model.coverArt(v)
        case .series(let s):
            let sm = model.seriesMetas[s.path]
            return TMDBImage.url(sm?.poster ?? sm?.posterClean, "w500")
        }
    }
}

// MARK: - 合集页的架子（专区页、「全部影片」的分类页共用）

/// 整页黑底，头部的颜色自己铺到状态栏、导航栏和侧边那一列底下；导航栏里先不写字（只有返回钮），
/// 滚过大标题（titleBottom：大标题的底边离页顶多远）才把标题接上去
struct CollectionScaffold<Content: View>: View {
    let title: String
    let titleBottom: (DSMetrics) -> CGFloat
    let content: (DSMetrics) -> Content

    init(title: String, titleBottom: @escaping (DSMetrics) -> CGFloat,
         @ViewBuilder content: @escaping (DSMetrics) -> Content) {
        self.title = title
        self.titleBottom = titleBottom
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let m = DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing, height: geo.size.height)
            let bottom = titleBottom(m)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content(m)
                }
                // 页底留一道排距（和别的页同一个 pageBottom，以前写死 44）
                .padding(.bottom, m.pageBottom)
                // 卡留在安全区里；头部的颜色自己铺到侧边那一列底下
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .horizontal)
            // 滚过大标题才把标题接到导航栏里：开关放在一个小修饰器里（卡顿）——以前是这一层的状态，
            // 一翻过去整页（头部连同那一列大卡）都要重算一遍，滑过大标题那一下会顿
            .modifier(CollectionBarTitle(title: title, threshold: bottom))
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// 合集页导航栏里的标题：滚过大标题（threshold：大标题的底边离页顶多远）才接上去。
/// 只有这一个修饰器跟着开关重算，滚动区里的内容不动
private struct CollectionBarTitle: ViewModifier {
    let title: String
    let threshold: CGFloat
    @State private var inBar = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > threshold
            } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { inBar = v }
            }
            .navigationTitle(inBar ? title : "")
    }
}

extension DSMetrics {
    /// 合集页那一列大卡：一行几张、每张多宽。折起一列；宽的屏（展开的 Duo、横拿）一行两张、三张
    var collectionGrid: (columns: Int, width: CGFloat) {
        let avail = max(200, width - margin * 2)
        let n = avail >= 1100 ? 3 : (avail >= 620 ? 2 : 1)
        return (n, ((avail - gutter * CGFloat(n - 1)) / CGFloat(n)).rounded(.down))
    }
}

/// 一列大卡（懒加载：几千部也只建看得到的那几张）；content 拿到每张卡多宽
struct CollectionGrid<Content: View>: View {
    let metrics: DSMetrics
    let content: (CGFloat) -> Content

    init(metrics: DSMetrics, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.metrics = metrics
        self.content = content
    }

    var body: some View {
        let g = metrics.collectionGrid
        // 列距还是 gutter；行距比列距宽一些（gridRowGap）：一列大卡带着底下那条色条，行距和列距一样时上下连成一条
        // （用户要求「保持一定的留白，整个界面看上去不会拥挤」）
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(g.width), spacing: metrics.gutter, alignment: .top), count: g.columns),
                  alignment: .leading, spacing: metrics.gridRowGap) {
            content(g.width)
        }
        .padding(.horizontal, metrics.margin)
    }
}

/// 合集页里片库的一部（电影或剧集）：点卡进详情（从卡上放大出来），长按是「播放 / 想看」菜单（C21、C45）
struct CollectionEntryCard: View {
    @Environment(AppModel.self) private var model
    let entry: HomeEntry
    let width: CGFloat
    /// 缩放转场的来源（同一部片在不同的页里各算各的）
    let slot: String

    var body: some View {
        switch entry {
        case .movie(let v):
            let meta = model.meta(v)
            let year: String? = model.year(v).map { String($0) }
            // 卡底那一行只写年份 · 类型（用户要求：简介只出现在详情页）
            let line: String = DetailText.line([year, meta?.genres?.first])
            ZoomLink(route: .movie(v), slot: slot) {
                CollectionCard(art: model.wideLockupArt(v).url, cover: model.thumbArt(v), title: model.title(v),
                               line: line, width: width)
            }
            .accessibilityIdentifier("collection-movie")
            .movieMenu(v)
        case .series(let s):
            let sm = model.seriesMetas[s.path]
            let line: String = DetailText.line([s.seasonLabel, sm?.genres?.first])
            ZoomLink(route: .series(s), slot: slot) {
                CollectionCard(art: model.seriesWideArt(s).url, cover: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w185"),
                               title: sm?.title ?? s.name, line: line, width: width)
            }
            .accessibilityIdentifier("collection-series")
            .seriesMenu(s)
            .task { await model.ensureSeriesMeta(s) }
        }
    }
}

// MARK: - 合集页的一张大卡

/// 宽银幕的画面（1.85 : 1），底下一条从画面取色的条（参考图卡底那一条）：
/// 小海报、「Cuven 独占」、片名、一句简介，右边「查看」。整张卡点进详情，「查看」只是样子
struct CollectionCard: View {
    let art: URL?
    let cover: URL?
    let title: String
    let line: String
    let width: CGFloat
    /// 片名上面那一行小字（参考图「Apple Arcade」）：合集页是「Cuven 独占」，主页展开时的年份分区是「电影」「剧集」
    let kicker: String
    /// 右边那颗胶囊换成请求的状态（分类页「可申请」：申请 / 已加入 / 已请求 42% / 已就绪 / 未能添加）；nil = 「查看」
    let badge: YearCardBadge?
    /// 画面底边一道细进度（请求进行中）
    let progress: Double?
    /// 底条的颜色：画面最下面那一截的平均色，压暗、收一点饱和度（白字看得清）；取到之前是深灰
    @State private var tone: Color?

    /// 写明的 init：tone 是 private，系统生成的那个只在这个文件里能用；主页展开时也要用这张卡
    init(art: URL?, cover: URL?, title: String, line: String, width: CGFloat, kicker: String = "Cuven 独占",
         badge: YearCardBadge? = nil, progress: Double? = nil) {
        self.art = art
        self.cover = cover
        self.title = title
        self.line = line
        self.width = width
        self.kicker = kicker
        self.badge = badge
        self.progress = progress
    }

    var body: some View {
        let artH = (width / 1.85).rounded()
        let shape = RoundedRectangle(cornerRadius: DSRadius.feature, style: .continuous)
        let fill = tone ?? Color(white: 0.16)
        VStack(spacing: 0) {
            ZStack {
                DSFill.placeholder
                RemoteImage(url: art, maxPixel: width * 3, placeholder: .clear)
                    .frame(width: width, height: artH)
                // 画面最下面一截融进底条的颜色（和展开时打头的横向大卡 WideLeadCard 同一个做法）：
                // 以前亮的画面和暗的底条之间是一道硬线
                LinearGradient(stops: [.init(color: fill.opacity(0), location: 0.8),
                                       .init(color: fill, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: width, height: artH)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if let progress {
                    // 和「全部影片」可申请那排的卡同一种：画面底边一道细线
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.22))
                        Rectangle().fill(Color.white).frame(width: (width * min(1, max(0, progress))).rounded())
                    }
                    .frame(width: width, height: 3)
                    .animation(.smooth(duration: 0.6), value: progress)
                }
            }
            bar
        }
        .frame(width: width)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DSFill.hairline, lineWidth: 1))
        .contentShape(shape)
        .task(id: art) { await loadTone() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, line, badge?.text ?? ""].filter { !$0.isEmpty }.joined(separator: "，"))
    }

    private var bar: some View {
        HStack(spacing: 14) {
            // 设计轮 2：和主页精选卡底条同一个小海报（44 点宽，以前 42）
            DSThumb(url: cover, width: 44)
            VStack(alignment: .leading, spacing: 1) {
                if !kicker.isEmpty {
                    // 和编辑推荐、分集卡、展开时的横向大卡同一个字重（以前这里是常规）
                    Text(kicker)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(DSInk.secondary)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                if !line.isEmpty {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(DSInk.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let badge {
                badge.view(compact: false)
            } else {
                DSViewPill()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: width, alignment: .leading)
        .background(tone ?? Color(white: 0.16))
    }

    /// 设计轮 2：和编辑推荐的面板同一个取色（DSTint.panel）：亮度最高 0.42 → 0.36，亮的画面下面那条上灰字也有 4.5 : 1
    private func loadTone() async {
        guard let art, let img = await ImagePipeline.shared.image(art, maxPixel: 64) else { return }
        // 取色放到后台（卡顿）：Core Image 渲染一个像素要同步等 GPU，以前在主线程上——合集页往下滑，每滑进来一张卡顿一下
        let tint = await Task.detached(priority: .userInitiated) { () -> Color? in
            guard let cg = img.cgImage, let c = ImageEffects.averageColor(cg, bottom: 0.3) else { return nil }
            return DSTint.panel(c)
        }.value
        guard let t = tint else { return }
        withAnimation(DSMotion.fade) { tone = t }
    }
}
