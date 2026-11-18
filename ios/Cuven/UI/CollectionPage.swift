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
    @State private var titleInBar = false

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let m = DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing, height: geo.size.height)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FeaturedCollectionHeader(title: shelf.title, blurb: shelf.blurb ?? "", covers: covers,
                                             metrics: m, page: true)
                    if entries.isEmpty {
                        ContentUnavailableView("暂无影片", systemImage: "film",
                                               description: Text("这一类的电影和剧集会显示在这里。"))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                    } else {
                        list(m)
                    }
                }
                .padding(.bottom, 44)
                // 卡留在安全区里；头部的颜色自己铺到侧边那一列底下
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .horizontal)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > FeaturedCollectionHeader.titleBottom(m)
            } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { titleInBar = v }
            }
        }
        .background(Color.black)
        .navigationTitle(titleInBar ? shelf.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    /// 顶上三张立体海报：排在最前的三部（印着片名的海报）
    private var covers: [URL?] {
        entries.prefix(3).map { (e: HomeEntry) -> URL? in
            switch e {
            case .movie(let v):
                return model.coverArt(v)
            case .series(let s):
                let sm = model.seriesMetas[s.path]
                return TMDBImage.url(sm?.poster ?? sm?.posterClean, "w500")
            }
        }
    }

    /// 一列大卡；宽的屏（展开的 Duo、横拿）一行两张、三张
    private func list(_ m: DSMetrics) -> some View {
        let avail = max(200, m.width - m.margin * 2)
        let n = avail >= 1100 ? 3 : (avail >= 620 ? 2 : 1)
        let w = ((avail - m.gutter * CGFloat(n - 1)) / CGFloat(n)).rounded(.down)
        // 设计轮 2：行距就是列距（m.gutter），宽的屏上不再一个 24、一个按宽算
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: m.gutter, alignment: .top), count: n),
                         alignment: .leading, spacing: m.gutter) {
            ForEach(entries) { e in card(e, width: w) }
        }
        .padding(.horizontal, m.margin)
    }

    @ViewBuilder private func card(_ e: HomeEntry, width w: CGFloat) -> some View {
        let slot = "collection-" + shelf.key
        switch e {
        case .movie(let v):
            let meta = model.meta(v)
            let year: String? = model.year(v).map { String($0) }
            // 卡底那一行只写年份 · 类型（用户要求：简介只出现在详情页）
            let line: String = DetailText.line([year, meta?.genres?.first])
            ZoomLink(route: .movie(v), slot: slot) {
                CollectionCard(art: model.wideLockupArt(v).url, cover: model.thumbArt(v), title: model.title(v),
                               line: line, width: w)
            }
            .accessibilityIdentifier("collection-movie")
            .movieMenu(v)
        case .series(let s):
            let sm = model.seriesMetas[s.path]
            let line: String = DetailText.line([s.seasonLabel, sm?.genres?.first])
            ZoomLink(route: .series(s), slot: slot) {
                CollectionCard(art: model.seriesWideArt(s).url, cover: TMDBImage.url(sm?.poster ?? sm?.posterClean, "w185"),
                               title: sm?.title ?? s.name, line: line, width: w)
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
    /// 底条的颜色：画面最下面那一截的平均色，压暗、收一点饱和度（白字看得清）；取到之前是深灰
    @State private var tone: Color?

    /// 写明的 init：tone 是 private，系统生成的那个只在这个文件里能用；主页展开时也要用这张卡
    init(art: URL?, cover: URL?, title: String, line: String, width: CGFloat, kicker: String = "Cuven 独占") {
        self.art = art
        self.cover = cover
        self.title = title
        self.line = line
        self.width = width
        self.kicker = kicker
    }

    var body: some View {
        let artH = (width / 1.85).rounded()
        let shape = RoundedRectangle(cornerRadius: DSRadius.feature, style: .continuous)
        VStack(spacing: 0) {
            ZStack {
                DSFill.placeholder
                RemoteImage(url: art, maxPixel: width * 3, placeholder: .clear)
                    .frame(width: width, height: artH)
            }
            .frame(width: width, height: artH)
            .clipped()
            bar
        }
        .frame(width: width)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DSFill.hairline, lineWidth: 1))
        .contentShape(shape)
        .task(id: art) { await loadTone() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, line].filter { !$0.isEmpty }.joined(separator: "，"))
    }

    private var bar: some View {
        HStack(spacing: 14) {
            // 设计轮 2：和主页精选卡底条同一个小海报（44 点宽，以前 42）
            DSThumb(url: cover, width: 44)
            VStack(alignment: .leading, spacing: 1) {
                if !kicker.isEmpty {
                    Text(kicker)
                        .font(.footnote)
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
            DSViewPill()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: width, alignment: .leading)
        .background(tone ?? Color(white: 0.16))
    }

    /// 设计轮 2：和编辑推荐的面板同一个取色（DSTint.panel）：亮度最高 0.42 → 0.36，亮的画面下面那条上灰字也有 4.5 : 1
    private func loadTone() async {
        guard let art, let img = await ImagePipeline.shared.image(art, maxPixel: 64), let cg = img.cgImage,
              let c = ImageEffects.averageColor(cg, bottom: 0.3), let t = DSTint.panel(c) else { return }
        withAnimation(DSMotion.fade) { tone = t }
    }
}
