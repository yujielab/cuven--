import SwiftUI
import UIKit

// MARK: - 全部影片的分类页（分段控件下面「电影 ›」「剧集 ›」进来的）
//
// 用户要求：「为可立即播放的影片和电视剧与可申请的影片和电视剧添加打开分类按钮，电视剧和电影分开，UI 和布局参考（专区），
// 并且使用 3 个可滑动卡片（参考图片，3 个卡片中的图片我等等提供）替换 3D 卡片区」。四页：可立即播放 / 可申请 × 电影 / 剧集。
// · 版式和专区（CollectionPage）一样：页顶一片从排在最前那部取的主色、往下沉到黑；大号粗体标题 + 一句灰字，滚过大标题才接到导航栏里；
//   下面一列同一张大卡（CollectionCard），折起一列、宽的屏一行两张 / 三张（CollectionScaffold、CollectionGrid、CollectionHeader 都是共用的）
// · 专区顶上那一扇立体海报换成三张横滑的大卡（参考图：Apple TV App 那一排大圆角卡，用户给的图是 3 : 4）：手机上一张约占八成宽、
//   下一张露出一截，停在左边线上；宽的屏三张都放得下。卡上是用户给的三张图（网上的，见 CategoryCardRemote），取不到才用这一页
//   排在最前那三部的画面（点了进那一部），怎么换图见 CategoryCardRow
// · 可立即播放：片库里的全部电影 / 全部剧集（一部剧一张卡），新的年份在前、同一年最新入库的在前（AppModel.playableEntries，按片库缓存）
// · 可申请：影片库索引里有、片库里没有的全部（不分年份，新的在前），滑到底接着取下一页；取的时候出骨架卡，没问成给「重试」。
//   卡上右边那颗是请求的状态（和全部影片可申请那排同一条规矩：CatalogRequestState），长按电影可以放进请求中心

struct FilmCategoryPage: View {
    let category: FilmCategory

    var body: some View {
        if category.playable {
            PlayableCategoryPage(category: category)
        } else {
            RequestableCategoryPage(category: category)
        }
    }
}

// MARK: - 可立即播放：片库里的全部电影 / 全部剧集

private struct PlayableCategoryPage: View {
    @Environment(AppModel.self) private var model
    let category: FilmCategory

    var body: some View {
        // 按片库缓存好的：几千部也不在每次重画时排一遍
        let entries = model.playableEntries(series: category.series)
        let head = Array(entries.prefix(3))
        // 顶上三张卡要排在最前那三部剧的画面：还没取到资料的先取（下面的卡要滑到了才取）
        let headShows = head.compactMap { (e: HomeEntry) -> Series? in
            if case .series(let s) = e { return s }
            return nil
        }
        let kind = category.series ? "剧集" : "电影"
        CollectionScaffold(title: category.title, titleBottom: { CategoryHeader.titleBottom($0) }) { m in
            CategoryHeader(category: category, arts: headerArts(head),
                           lead: head.first.flatMap { CollectionPage.cover($0, model: model) }, metrics: m)
            if entries.isEmpty {
                ContentUnavailableView("暂无\(kind)", systemImage: category.series ? "tv" : "film",
                                       description: Text("片库中的\(kind)会显示在这里。"))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            } else {
                CollectionGrid(metrics: m) { w in
                    ForEach(entries) { e in
                        CollectionEntryCard(entry: e, width: w, slot: "category-" + category.rawValue)
                    }
                }
            }
        }
        .task(id: headShows.map(\.path).joined(separator: ",")) {
            for s in headShows { await model.ensureSeriesMeta(s) }
        }
    }

    /// 顶上三张卡的画面（用户的图取不到时）：排在最前那三部的竖版画面，点了进那一部。
    /// 竖版的裁得最少（3 : 4 的卡竖着裁，横的剧照只剩中间一截、还要放大），可立即播放、可申请两边一个样：
    /// 电影 Apple TV 竖版主视觉 → TMDB 纯净海报 → 海报 → 剧照；剧集纯净海报 → 海报（中文剧常常没有纯净的）→ 剧照（大一号）
    private func headerArts(_ head: [HomeEntry]) -> [CategoryCardArt] {
        head.map { (e: HomeEntry) -> CategoryCardArt in
            switch e {
            case .movie(let v):
                let meta = model.meta(v)
                let url = TMDBImage.url(model.tallArtString(v), "w780")
                    ?? TMDBImage.url(meta?.posterClean, "w780")
                    ?? TMDBImage.url(meta?.poster, "w780")
                    ?? model.backgroundArt(v)
                return CategoryCardArt(url: url, route: .movie(v), label: model.title(v))
            case .series(let s):
                let sm = model.seriesMetas[s.path]
                let url = TMDBImage.url(sm?.posterClean, "w780")
                    ?? TMDBImage.url(sm?.poster, "w780")
                    ?? TMDBImage.url(sm?.backdrop, "w1280")
                return CategoryCardArt(url: url, route: .series(s), label: sm?.title ?? s.name)
            }
        }
    }
}

// MARK: - 可申请：影片库索引里有、片库里没有的全部

private struct RequestableCategoryPage: View {
    @Environment(AppModel.self) private var model
    let category: FilmCategory

    var body: some View {
        let feed = CatalogFeed.shared(category.src)
        // 片库里已经有的滤掉（影片库按 own=hide 已经滤过一遍；刚入库、请求刚完成的这里再滤）
        let owned = model.ownedMovieIDs, shows = model.ownedSeasons
        let items = feed.items.filter { !model.owns($0, movies: owned, shows: shows) }
        let head = Array(items.prefix(3))
        // 滑到最后这几张就接着取下一页（不等滑到骨架卡）
        let tail = Set(items.suffix(4).map(\.uid))
        CollectionScaffold(title: category.title, titleBottom: { CategoryHeader.titleBottom($0) }) { m in
            // 头单拆一个视图、只传那三部：它要读 CatalogArt 的剧照，剧照一批一批到时只重画头，不连带整列大卡
            RequestableCategoryHeader(category: category, head: head, metrics: m)
            list(m, feed: feed, items: items, tail: tail)
        }
        // 本机存的剧照、字标先读进来（不在画卡的时候改状态），再从第一页问（问过了的：5 分钟内、往后翻过的不重问）
        .task {
            _ = CatalogArt.shared
            await feed.start()
        }
        // 排在最前那三部的剧照、字标：顶上的卡没有海报时用剧照，下面那三张大卡也要（列表里的卡出现了也会要，这里不等它）
        .task(id: head.map(\.uid).joined(separator: ",")) {
            for it in head { CatalogArt.shared.want(it) }
        }
    }

    @ViewBuilder
    private func list(_ m: DSMetrics, feed: CatalogFeed, items: [CatalogItem], tail: Set<String>) -> some View {
        let kind = category.series ? "剧集" : "电影"
        if items.isEmpty && feed.failed {
            ContentUnavailableView {
                Label("无法载入", systemImage: "wifi.exclamationmark")
            } description: {
                Text("没能取到可申请的\(kind)，请稍后再试。")
            } actions: {
                Button("重试") { Task { await feed.retry() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("category-retry")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        } else if items.isEmpty && feed.done {
            ContentUnavailableView("暂无可申请的\(kind)", systemImage: category.series ? "tv" : "film",
                                   description: Text("影片库中的\(kind)都已在片库里。"))
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
        } else {
            let slot = "category-" + category.rawValue
            CollectionGrid(metrics: m) { w in
                ForEach(items, id: \.uid) { it in
                    CatalogCollectionCard(item: it, width: w, slot: slot)
                        .onAppear {
                            if tail.contains(it.uid) { Task { await feed.loadMore() } }
                        }
                }
                if !feed.done && !feed.failed {
                    // 骨架卡：一行（一张都还没有时两行）。编号跟着下一页走：取回来的全被滤掉了、骨架卡还在屏上时，
                    // 换了编号的骨架卡再「出现」一次，接着取；滑走了的不会出现，不会一直往后取
                    let n = m.collectionGrid.columns * (items.isEmpty ? 2 : 1)
                    // 骨架卡旁白听不到：第一张给旁白念一句在载入（首屏一张都没有时，旁白不至于念完标题就没声了）
                    let loadingLabel = items.isEmpty ? "正在载入可申请的\(kind)" : "正在载入更多\(kind)"
                    ForEach((0..<n).map { feed.next * 100 + $0 }, id: \.self) { k in
                        SkeletonCollectionCard(width: w, label: k % 100 == 0 ? loadingLabel : nil)
                            .onAppear {
                                if k % 100 == 0 { Task { await feed.loadMore() } }
                            }
                    }
                }
            }
            if feed.failed {
                // 往后取的那一页没问成：已经有的留着，底下一颗「重试」（和「电影 ›」「剧集 ›」同一种描边胶囊）
                Button {
                    Task { await feed.retry() }
                } label: {
                    Label("载入失败，点按重试", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 40)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .frame(maxWidth: .infinity)
                .padding(.top, m.gutter)
                .accessibilityIdentifier("category-retry")
            }
        }
    }
}

/// 可申请的一张大卡：和专区同一张（CollectionCard）。画面是影片库那一部的剧照（还没取到时是海报），
/// 片名上面那一行小字不写（「Cuven 独占」是片库里的才有），右边那颗是请求的状态，请求进行中画面底边一道进度
private struct CatalogCollectionCard: View {
    let item: CatalogItem
    let width: CGFloat
    let slot: String

    var body: some View {
        let art = CatalogArt.shared.art(item)
        let state = CatalogRequestState(item)
        ZoomLink(route: .catalog(item.catalogTitle), slot: slot) {
            CollectionCard(art: TMDBImage.url(art?.backdrop, "w1280") ?? TMDBImage.url(item.poster, "w780"),
                           cover: TMDBImage.url(item.poster, "w185"), title: item.title,
                           line: CatalogRequestState.line(item, art: art), width: width, kicker: "",
                           badge: state.badge, progress: state.progress)
        }
        .accessibilityIdentifier("collection-request")
        .onAppear { CatalogArt.shared.want(item) }
        .contextMenu { CatalogRequestMenu(item: item, state: state) }
    }
}

/// 可申请那一页的头：顶上三张卡的画面在这里取。单拆一个视图（只拿那三部）：画面可能要读 CatalogArt 的剧照，
/// 剧照一批一批到（列表里的卡出现了就要）时只重画这个头，不连带整页、整列大卡重算一遍
private struct RequestableCategoryHeader: View {
    let category: FilmCategory
    let head: [CatalogItem]
    let metrics: DSMetrics

    var body: some View {
        CategoryHeader(category: category, arts: head.map { Self.art($0) },
                       lead: TMDBImage.url(head.first?.poster, "w500"), metrics: metrics)
    }

    /// 顶上一张卡的画面（用户的图取不到时），点了进它的详情（请求添加）。和可立即播放那边一样竖版的先：
    /// 索引里本来就有的海报（马上出来，剧照到了也不换一张、不跳）；没有海报才用剧照（3 : 4 竖着裁只剩中间一截，要原图才不糊）
    static func art(_ it: CatalogItem) -> CategoryCardArt {
        let url = TMDBImage.url(it.poster, "w780") ?? TMDBImage.url(CatalogArt.shared.art(it)?.backdrop, "original")
        return CategoryCardArt(url: url, route: .catalog(it.catalogTitle), label: it.title)
    }
}

/// 还没取到时的大卡（和 CollectionCard 一样大：宽银幕的画面 + 底条）。label：给旁白念的（一排骨架卡只第一张有），没有就旁白跳过
private struct SkeletonCollectionCard: View {
    let width: CGFloat
    var label: String? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.feature, style: .continuous)
        VStack(spacing: 0) {
            DSFill.placeholder
                .frame(width: width, height: (width / 1.85).rounded())
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: DSRadius.thumb(44), style: .continuous)
                    .fill(DSFill.placeholder)
                    .frame(width: 44, height: 66)
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(DSFill.placeholder).frame(width: width * 0.36, height: 12)
                    Capsule().fill(DSFill.placeholder).frame(width: width * 0.22, height: 10)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: width, alignment: .leading)
            .background(Color(white: 0.16))
        }
        .frame(width: width)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DSFill.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }
}

// MARK: - 头：三张横滑的大卡 + 大标题 + 一句说明

/// 顶上一张卡在用户的图取不到时用的画面：这一页排在第几的那一部（点了进它）
private struct CategoryCardArt {
    let url: URL?
    let route: Route?
    /// 旁白念的：那一部的片名
    let label: String
}

/// 顶上三张卡的图：用户给的（「图片就绪了」），四页共用一套，从左到右。传在 data.cuven.us/logo/<名字>.png，
/// 走 App 的图片管线（内存 + 磁盘缓存）。要换图：把新图换个名字传上去、改下面的地址（顺序就是从左到右，label 是旁白念的）——
/// 同一个地址换了内容，已经存进手机磁盘缓存的不会重新下载；
/// 新图也要 3 : 4，白边左右各不超过宽的 2.8%、上下各不超过高的 2.8%（放大 zoom 每边裁掉的就这么多），
/// 图里那张卡的圆角不比现在这三张大（约卡宽的 10%）；不带白边的也行
private struct CategoryCardRemote {
    let url: URL?
    let label: String

    static let all: [CategoryCardRemote] = [
        // 浅灰底：MLS | Cuven max
        CategoryCardRemote(url: URL(string: "https://data.cuven.us/logo/764B6BC6-EF80-45E1-9CF6-7EB59F57294E.png"), label: "MLS"),
        // 深青底：Cuven Max · Friday Night Baseball
        CategoryCardRemote(url: URL(string: "https://data.cuven.us/logo/AA1583FB-1610-49F9-9475-D2801C8681BD.png"),
                           label: "Friday Night Baseball"),
        // 红底：F1 | Cuven max
        CategoryCardRemote(url: URL(string: "https://data.cuven.us/logo/33B0C220-FFC8-49B8-856B-0174DC1C428D.png"), label: "F1"),
    ]

    /// 用户的图是画在白底上的一张卡（白边左右约宽的 1.4–2.3%、上下约高的 1.2–2.1%，自己的圆角约卡宽的 9–10%）：
    /// 铺满以后绕中心放大 6%、再按卡宽 11% 的大圆角裁（CategoryCardFace），白边、白角都落在外面
    static let zoom: CGFloat = 1.06
}

/// 分类页的头：专区的立体海报换成三张横滑的大卡（用户要求），底色、大标题、说明和专区同一套（CollectionHeader）
private struct CategoryHeader: View {
    let category: FilmCategory
    let arts: [CategoryCardArt]
    let lead: URL?
    let metrics: DSMetrics

    /// 卡那一排上面留多少（排里上下各还有 4 点）：看上去和专区的立体海报离导航栏一样远（22）
    private static let rowTop: CGFloat = 18

    /// 大标题的底边离这一块顶上多远（滚过它，才把标题接到导航栏里）
    static func titleBottom(_ m: DSMetrics) -> CGFloat {
        rowTop + CategoryCardRow.height(m) + 22 + (m.wide ? 52 : 43)
    }

    var body: some View {
        CollectionHeader(title: category.title, blurb: category.blurb, lead: lead, metrics: metrics, page: true) {
            CategoryCardRow(category: category, arts: arts, metrics: metrics)
                .padding(.top, Self.rowTop)
        }
    }
}

/// 顶上三张横滑的大卡（照用户给的参考图：Apple TV App 那一排大圆角、整张是图的卡，3 : 4（用户给的图就是这个比例）；
/// 第一张停在左边线上，下一张露出一截）。
///
/// 卡上的图，按这个顺序找，前面有的就用前面的：
/// 1. 本机资产（以后想换成打包进 App 的图，不用改代码）：在 ios/Cuven/Resources/Assets.xcassets 里新建图片集（Image Set）：
///    · 四页共用一套：CategoryCard1、CategoryCard2、CategoryCard3（从左到右）；
///    · 某一页要自己的一套：CategoryCard-<页>-1、-2、-3，<页> 是 playableMovie（可立即播放 · 电影）、playableSeries（可立即播放 · 剧集）、
///      requestableMovie（可申请 · 电影）、requestableSeries（可申请 · 剧集），例如 CategoryCard-playableMovie-1。这一页自己的优先，没有再用共用的。
///    图铺满卡、按 3 : 4 居中裁（多出来的裁掉；不放大，要不带白边的图），给 1200 × 1600 像素左右就清楚。
/// 2. 用户给的三张图（网上的，CategoryCardRemote）：现在用的就是它们。
/// 3. 那张图取不到（地址失效、没网）：这一页排在第几的那一部的画面，点了进那一部。
/// 用户的图点了先不做什么（用户还没说点了去哪）
private struct CategoryCardRow: View {
    let category: FilmCategory
    let arts: [CategoryCardArt]
    let metrics: DSMetrics
    /// 用户的图取不到的那几张（第几张）：换回那一部的画面。离开这一页再进来重试
    @State private var failed: Set<Int> = []

    /// 一张卡多大（3 : 4）：手机上约屏宽的 78%，下一张露出一截（参考图）；宽的屏三张一行放得下。
    /// 卡高不过屏高的 56%（宽的屏 50%）：横拿、展开横拿那种矮的屏，一屏还看得到大标题
    static func cardSize(_ m: DSMetrics) -> CGSize {
        var w: CGFloat = m.wide
            ? ((m.width - m.margin * 2 - m.gutter * 2) / 3).rounded(.down)
            : (m.width * 0.78).rounded(.down)
        if m.height > 0 { w = min(w, max(180, (m.height * (m.wide ? 0.5 : 0.56) * 0.75).rounded(.down))) }
        return CGSize(width: w, height: (w * 4 / 3).rounded())
    }

    /// 这一排占的高：卡高 + 上下各 4 点（按下去时略缩的那一点空）
    static func height(_ m: DSMetrics) -> CGFloat { cardSize(m).height + 8 }

    var body: some View {
        let size = Self.cardSize(metrics)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: metrics.gutter) {
                ForEach(0..<3, id: \.self) { i in card(i, size: size) }
            }
            .scrollTargetLayout()
            .padding(.vertical, 4)
        }
        // 头部那一块左右留着页边距：这一排先伸回整个宽，再和别的横排一样铺到侧边那一列底下（dsBleedRow），第一张仍停在左边线上
        .padding(.horizontal, -metrics.margin)
        .dsBleedRow(metrics)
        // 一张一张停（参考图：滑完停在左边线上）
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .frame(height: Self.height(metrics))
    }

    @ViewBuilder
    private func card(_ i: Int, size: CGSize) -> some View {
        let art: CategoryCardArt? = i < arts.count ? arts[i] : nil
        let remote: CategoryCardRemote? = i < CategoryCardRemote.all.count ? CategoryCardRemote.all[i] : nil
        if let image = Self.userImage(category, i + 1) {
            // 三张都是用户的图：旁白念第几张（不然三张念得一模一样）
            CategoryCardFace(image: image, url: nil, size: size)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(category.title)，第 \(i + 1) 张，共 3 张")
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("category-header-card")
        } else if let remote, let url = remote.url, !failed.contains(i) {
            // 用户给的图：一张静态的图，旁白念图上是什么；点了不做什么（不包 ZoomLink）
            CategoryCardFace(image: nil, url: nil, size: size, remote: url, onRemoteFail: { _ = failed.insert(i) })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(remote.label)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("category-header-card")
        } else if let art, let route = art.route {
            ZoomLink(route: route, slot: "category-header-" + category.rawValue) {
                CategoryCardFace(image: nil, url: art.url, size: size)
            }
            .accessibilityLabel(art.label)
            .accessibilityIdentifier("category-header-card")
        } else {
            // 这一页还没有第几部（还在取、片库里不到三部）：先是一张空的卡，版面不跳
            CategoryCardFace(image: nil, url: nil, size: size)
                .accessibilityHidden(true)
        }
    }

    /// 用户的图：这一页自己的一套（CategoryCard-<页>-<n>）优先，再是四页共用的一套（CategoryCard<n>）
    @MainActor
    static func userImage(_ c: FilmCategory, _ n: Int) -> UIImage? {
        let k = "\(c.rawValue)-\(n)"
        if let hit = userImages[k] { return hit }
        let image = UIImage(named: "CategoryCard-\(c.rawValue)-\(n)") ?? UIImage(named: "CategoryCard\(n)")
        userImages.updateValue(image, forKey: k)
        return image
    }

    /// 找过的（按「页-第几张」记，没有的也记一笔 nil）：头部跟着剧照、剧集资料一直重画，每次都去资产目录里找两遍太费
    /// （找不到的系统不记）。App 运行中资产目录不会变，不用清
    @MainActor private static var userImages: [String: UIImage?] = [:]
}

/// 一张卡：整张是图（铺满、居中裁），连续曲率的大圆角、一圈细边（参考图）。还没取到时是一块同样形状的暗色占位（不闪白）
private struct CategoryCardFace: View {
    let image: UIImage?
    let url: URL?
    let size: CGSize
    /// 用户给的图（CategoryCardRemote）：放大 zoom 再裁，白边不露出来；取不到时叫 onRemoteFail，外面换回那一部的画面
    var remote: URL? = nil
    var onRemoteFail: () -> Void = {}

    var body: some View {
        // 圆角约卡宽的 11%：用户的图自己带约 8–10% 的圆角，裁得比它圆一点才不露白角（宽的屏卡大，不封顶）；一排三张同一个圆角
        let shape = RoundedRectangle(cornerRadius: (size.width * 0.11).rounded(), style: .continuous)
        ZStack {
            DSFill.placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
            } else if let remote {
                // 图的最长边是高：按卡高（再放大的那一截）取，3 倍屏下也清楚
                CategoryCardRemoteImage(url: remote, maxPixel: (size.height * 3 * CategoryCardRemote.zoom).rounded(),
                                        onFail: onRemoteFail)
                    .id(remote)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(CategoryCardRemote.zoom)
            } else {
                RemoteImage(url: url, maxPixel: size.width * 3, placeholder: .clear)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DSFill.hairline, lineWidth: 1))
        .contentShape(shape)
    }
}

/// 用户给的一张卡图：走 App 的图片管线（ImagePipeline：内存 + 磁盘缓存、按显示尺寸解码）。不用 RemoteImage：
/// 它从模糊里淡入，会把图四周那圈白边糊进卡里（淡入那一下卡边泛白），也不告诉外面取没取到——这里只淡入，取不到叫 onFail
private struct CategoryCardRemoteImage: View {
    let url: URL
    let maxPixel: CGFloat
    let onFail: () -> Void

    @State private var image: UIImage?
    /// 手里这张按多大取的（转屏、分屏后卡变大了换更清楚的，原地换、不再淡入）
    @State private var loadedPixel: CGFloat = 0

    init(url: URL, maxPixel: CGFloat, onFail: @escaping () -> Void) {
        self.url = url
        self.maxPixel = maxPixel
        self.onFail = onFail
        // 内存里已经有（再打开这一页、换一页分类）：第一帧就是它，不闪占位
        let hit = maxPixel < RemoteImage.minPixel ? nil : ImagePipeline.shared.cached(url, maxPixel: maxPixel)
        _image = State(initialValue: hit)
        _loadedPixel = State(initialValue: hit == nil ? 0 : maxPixel)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: maxPixel.isFinite ? Int(maxPixel) : 0) {
            guard maxPixel.isFinite, maxPixel >= RemoteImage.minPixel else { return }
            let had = image != nil
            if had, loadedPixel >= maxPixel * 0.8 { return }
            let img = await ImagePipeline.shared.image(url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            if let img {
                if had {
                    image = img
                } else {
                    withAnimation(.easeOut(duration: 0.32)) { image = img }
                }
                loadedPixel = maxPixel
            } else if !had {
                onFail()
            }
        }
    }
}

// MARK: - 可申请的全部：一页一页往后取

/// 影片库索引里有、片库里没有的全部（/app/catalog，own=hide、新的在前，不分年份）：电影、剧集各一份，全 App 共用——
/// 再打开分类页直接是上次的；5 分钟以前问的、又没往后翻过的，从第一页重问一次（问到了才换掉）
@MainActor
@Observable
final class CatalogFeed {
    static let movies = CatalogFeed(src: "movie")
    static let series = CatalogFeed(src: "tv")
    static func shared(_ src: String) -> CatalogFeed { src == "tv" ? series : movies }

    /// 影片库的类别：movie / tv
    let src: String
    private(set) var items: [CatalogItem] = []
    /// 接着取第几页（骨架卡的编号也跟着它，见 RequestableCategoryPage）
    private(set) var next = 1
    private(set) var loading = false
    /// 上一次没问成：一张都没有时整页是「重试」，有了的底下一颗「重试」
    private(set) var failed = false
    /// 取完了
    private(set) var done = false
    /// 第一页问到了
    private(set) var started = false

    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var fetchedAt: Date?
    /// 往后翻过（滑到底又取了一页）：再打开时不从第一页重问（一换，翻到的那些就没了）
    @ObservationIgnored private var paged = false
    /// 正在取的时候滑到了底（那几张卡、骨架卡已经出现过，不会再出现一次）：记下来，这一次取完接着取下一页
    @ObservationIgnored private var wantMore = false

    /// tj 的 /app/catalog 最多翻到第 500 页（再往后问回的还是第 500 页）
    private static let lastPage = 500

    private init(src: String) { self.src = src }

    /// 打开分类页：没问到过的从第一页问；问过了的，5 分钟以前问的、又没往后翻过的从第一页重问一次
    func start() async {
        if DemoData.enabled {
            if !started { fillDemo() }
            return
        }
        // 上次没问成的：再打开先不挂「重试」。一张都没有的从第一页重问，问的时候是骨架卡（不是整页「无法载入」、点「重试」没反应）；
        // 有了的滑到底照常接着取。这次再没问成，fetch 会再挂上
        failed = false
        if !started {
            await fetch(fresh: true)
        } else if !paged, let fetchedAt, Date().timeIntervalSince(fetchedAt) > 300 {
            await fetch(fresh: true)
        }
    }

    /// 滑到底（最后几张、骨架卡出现了）：取下一页（同时只取一次；正在取的，取完接着取）
    func loadMore() async {
        guard started, !done, !failed, !DemoData.enabled else { return }
        if loading {
            wantMore = true
            return
        }
        await fetch(fresh: false)
    }

    /// 「重试」：一张都没有就从第一页问，有了的接着往后取（正在取的：取完接着往后取，不另问一次）
    func retry() async {
        failed = false
        if loading {
            wantMore = true
            return
        }
        await fetch(fresh: items.isEmpty)
    }

    /// fresh：从第一页问，问到了才换掉；否则从 next 接着取、按 uid 去重接上
    private func fetch(fresh: Bool) async {
        guard !loading else { return }
        loading = true
        let page = fresh ? 1 : next
        do {
            // 要全部（用户要求：影片库有、片库没有的全部）：不带年份时服务器默认 min 6（首页那一刀），这里明说 0
            let r = try await RequestAPI.catalogPage(src: src, sort: "new", own: "hide", page: page, minVote: 0)
            for i in r.items { if let s = i.req { RequestStore.shared.merge(s) } }
            var list = fresh ? [] : items
            var have = fresh ? Set<String>() : seen
            for i in r.items {
                guard have.insert(i.uid).inserted else { continue }
                list.append(i)
            }
            items = list
            seen = have
            next = page + 1
            // 第 500 页就是最后一页：再往后问回的还是它（全是见过的，一张也接不上），骨架卡换了编号又出现、一页一页白问
            done = r.items.isEmpty || (r.pages > 0 && page >= r.pages) || page >= Self.lastPage
            started = true
            failed = false
            if fresh {
                fetchedAt = Date()
                paged = false
            } else {
                paged = true
            }
        } catch {
            // 离开了页面（任务被取消）不算没问成；已经有一列时从第一页重问（5 分钟一次）没问成也不算：
            // 屏上的留着、照常往后翻，下次打开再重问
            if !CatalogYears.cancelled(error) && !(fresh && !items.isEmpty) { failed = true }
        }
        loading = false
        // 取的时候滑到了底、点了「重试」：接着取下一页
        if wantMore {
            wantMore = false
            if started && !done && !failed && !Task.isCancelled { await fetch(fresh: false) }
        }
    }

    /// 演示数据（UI 测试用，不连网）：全部影片「可申请」那几年的几条，新的年份在前
    private func fillDemo() {
        let y = Calendar.current.component(.year, from: Date())
        var list: [CatalogItem] = []
        var have = Set<String>()
        for year in (y - 6...y).reversed() {
            for i in CatalogYears.demo(CatalogYears.Key(year: year, src: src)).items {
                guard have.insert(i.uid).inserted else { continue }
                list.append(i)
            }
        }
        items = list
        seen = have
        next = 2
        done = true
        started = true
        fetchedAt = Date()
    }
}
