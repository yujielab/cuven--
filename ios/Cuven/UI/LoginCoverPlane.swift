import SwiftUI
import UIKit
import QuartzCore

// MARK: - 登录页背景：海报沿一个斜向纵深平面从灵动岛下面推向镜头
//
// 用户要求新登录页照 Brink 的录屏和动效文档（第 2、3 页）做背景：黑底，顶端中轴一团柔灰光晕（1.27 秒亮起）；
// 1.33 秒起三列圆角封面从灵动岛下缘（X 50%、Y 6%）露出，沿同一个斜向纵深平面推向镜头——远处小、扁、密，
// 近处大、开，两侧列向外展开、跨过屏边被裁掉，中列纵向错开半格；约 2.3–2.6 秒铺满，之后一直往前流
// （底下暗区回收、顶上补入）。封面上压一层黑色渐变：Y 40% 起变暗、68% 全黑，正文和按钮背后是纯黑。
// 我们的封面是影片海报（2 : 3 竖版），黑缝隔开。
//
// 做法：一个 CALayer 当平面，每张封面一个子图层；每帧按平面上的位置算出四个角在屏上的位置，用透视变换
// （矩形 → 四边形）贴上去。CA 在 GPU 上画，手机上一屏最多十七张、每帧只改 transform，旧机型 60 / 120 帧也顺；
// 封面滑进暗区就回收，换下一张海报从顶上再进来。图走 ImagePipeline（解码在后台，内存 / 磁盘缓存全 App 共用）。
//
// 形状和节奏是按录屏逐帧量的（屏高、屏宽的比例）：
//   · 列线汇聚点（地平线）在屏顶以上 15% 屏高：卡宽、两侧列的偏移都和「到这条线的距离」成正比（录屏里量出来是一条直线）；
//   · Y 35% 以上就是平面透视（屏上速度 ∝ 距离²，录屏各高度一致）；再往下录屏明显放缓、近处的卡也没那么拉长，
//     那一段按距离软收（CoverPlaneModel.g），近端不会一下冲出屏外；
//   · 匀速时一张封面从灵动岛下面走到屏底约 6.6 秒；入场先 6 倍速，1.78 秒起平滑减到 1 倍（3.12 秒），
//     对得上录屏：1.73 秒领头一排下沿在 18%、2.03 秒在 40%、2.2 秒进暗区。

/// 登录页的封面背景（全屏；放在最底下，前景、状态栏都在它上面）。t：登录页出现以来的秒数（LoginLanding 的时间线给）
struct LoginCoverPlane: View {
    let t: Double
    let size: CGSize
    let covers: [URL]
    var reduceMotion = false

    var body: some View {
        CoverPlaneCanvas(t: t, size: size, covers: covers, reduceMotion: reduceMotion)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - 平面的几何和节奏

/// 屏上的 Y 都是屏高的比例（从顶往下），深度是平面上的相对距离（越大越远）
private enum CoverPlaneModel {
    /// 地平线：屏顶以上 15% 屏高
    static let horizon = -0.15
    /// 一个卡宽在屏上占「平面宽」的 0.63 ×（到地平线的距离）
    static let lateral = 0.63
    /// 相邻两列中心隔几个卡宽（多出来的是黑缝）
    static let columnPitch = 1.08
    /// 一排占多深、卡本身多深（剩下的是排间的黑缝）。录屏里的方形卡约 0.68 深，海报竖版，长一些
    static let rowPitch = 1.0
    static let cardDepth = 0.92
    /// 近端软收：到地平线的距离过了 0.45（约 Y 30%）以后按 x / (1 + 1.3x) 收（录屏 Y 35% 往下的放缓）
    static let knee = 0.45
    static let soften = 1.3
    /// 匀速：每秒 0.7 个深度单位（从 Y 6% 走到屏底约 6.6 秒）
    static let speed = 0.7
    /// 入场：1.33 秒起，领头一排下沿在 Y 6.5%（灵动岛下缘）；先 6 倍速，1.78 → 3.12 秒平滑减到 1 倍
    static let start = 1.33
    static let leadY = 0.065
    static let rush = 6.0
    static let easeFrom = 1.78
    static let easeTo = 3.12
    /// 卡的上沿过了 Y 80%（早就全黑了）就回收
    static let recycleY = 0.80
    /// 顶上淡入：3.5% 以上看不见（灵动岛、状态栏那一条），8.5% 起完全露出来
    static let fadeTop = 0.035
    static let fadeFull = 0.085
    /// 「平面宽」：手机就是屏宽；宽窗口（iPad、展开的 Duo）按屏高收，不至于一张卡比手机整屏还大
    static func planeWidth(_ s: CGSize) -> Double { Double(min(s.width, s.height * 0.62)) }

    /// 到地平线的「透视距离」q（= 1 / 深度）→ 屏上到地平线的距离：上半段原样，过了 knee 软收
    static func g(_ q: Double) -> Double {
        guard q > knee else { return q }
        let e = q - knee
        return knee + e / (1 + soften * e)
    }

    static func gInverse(_ y: Double) -> Double {
        guard y > knee else { return y }
        let e = y - knee
        let den = 1 - soften * e
        return den > 0 ? knee + e / den : .infinity
    }

    /// 深度 d 处在屏上的 Y
    static func screenY(_ d: Double) -> Double { horizon + g(1 / d) }

    /// 屏上 Y 处的深度
    static func depth(atY y: Double) -> Double { 1 / max(1e-6, gInverse(y - horizon)) }

    /// 1.33 秒起平面一共往前走了多少：速度 = 匀速 ×（1 + 5 ×（1 − smoothstep(1.78…3.12)）），这里是它的积分
    static func travel(_ t: Double) -> Double {
        guard t > start else { return 0 }
        let w = easeTo - easeFrom
        let p = min(1, max(0, (t - easeFrom) / w))
        // smoothstep 从 easeFrom 积到 t：w·(p³ − p⁴/2)，过了 easeTo 以后每秒都是 1
        let eased = w * (p * p * p - p * p * p * p / 2) + max(0, t - easeTo)
        let s = t - start
        return speed * (s + (rush - 1) * (s - eased))
    }

    /// 减弱动态效果：不推进，停在铺满以后的样子（第 6 秒那一帧）
    static let restTravel = CoverPlaneModel.travel(6)
}

private func planeSmooth(_ x: Double) -> Double {
    let c = min(1, max(0, x))
    return c * c * (3 - 2 * c)
}

// MARK: - 画布（UIKit / Core Animation）

private struct CoverPlaneCanvas: UIViewRepresentable {
    let t: Double
    let size: CGSize
    let covers: [URL]
    let reduceMotion: Bool

    func makeUIView(context: Context) -> CoverPlaneView {
        CoverPlaneView(frame: CGRect(origin: .zero, size: size))
    }

    func updateUIView(_ view: CoverPlaneView, context: Context) {
        view.update(t: t, size: size, covers: covers, reduceMotion: reduceMotion)
    }
}

private final class CoverPlaneView: UIView {
    /// 平面上的一格：第几列（中间是 0）、第几排（领头一排是 0，往远处数）
    private struct Slot: Hashable {
        let column: Int
        let row: Int
    }

    private final class Card {
        let layer: CALayer
        var url: URL?
        var hasImage = false
        init(layer: CALayer) { self.layer = layer }
    }

    private let plane = CALayer()
    private let topFade = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let shade = CAGradientLayer()

    private var active: [Slot: Card] = [:]
    private var pool: [Card] = []
    private var loading: Set<URL> = []
    /// 取不到的图：这么久以内不再试（没网时不反复打）
    private var failedAt: [URL: CFTimeInterval] = [:]

    private var laidOut: CGSize = .zero
    private var placed: (travel: Double, count: Int, first: URL?)?

    /// 卡在自己坐标系里的大小（2 : 3）：透视变换把它贴到屏上的四边形，圆角跟着透视一起缩放
    private static let cardSize = CGSize(width: 100, height: 150)
    /// 没网、图还没到：暗色占位
    private static let placeholder = UIColor(white: 0.1, alpha: 1).cgColor

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // 两侧的卡跨过屏边：放在不满屏的容器里（分屏、iPad 小窗）也不画到外面去
        clipsToBounds = true
        isOpaque = true
        backgroundColor = .black

        // 顶上：黑 → 透明，封面从灵动岛下面「冒」出来
        let clearBlack = UIColor(white: 0, alpha: 0).cgColor
        topFade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, clearBlack]
        topFade.locations = [0, NSNumber(value: CoverPlaneModel.fadeTop), NSNumber(value: CoverPlaneModel.fadeFull)]
        topFade.startPoint = CGPoint(x: 0.5, y: 0)
        topFade.endPoint = CGPoint(x: 0.5, y: 1)

        // 顶端中轴的柔灰光晕（径向：中心在顶上，往下、往两边淡掉）
        glow.type = .radial
        let glowAlpha: [CGFloat] = [0.22, 0.13, 0.05, 0]
        glow.colors = glowAlpha.map { UIColor(white: 1, alpha: $0).cgColor }
        glow.locations = [0, 0.35, 0.7, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.02)
        glow.endPoint = CGPoint(x: 1, y: 0.22)
        glow.opacity = 0

        // 封面上的黑色渐变：Y 40% 起变暗，68% 全黑（图标附近已经明显暗了，正文和按钮背后是纯黑）
        let stops: [(Double, CGFloat)] = [(0.40, 0), (0.47, 0.22), (0.54, 0.58), (0.61, 0.86), (0.68, 1), (1, 1)]
        shade.colors = stops.map { UIColor(white: 0, alpha: $0.1).cgColor }
        shade.locations = stops.map { NSNumber(value: $0.0) }
        shade.startPoint = CGPoint(x: 0.5, y: 0)
        shade.endPoint = CGPoint(x: 0.5, y: 1)

        // 光晕叠在封面上面：顶上那几排像是从一团灰雾里出来
        for l in [plane, topFade, glow, shade] as [CALayer] { layer.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(t: Double, size: CGSize, covers: [URL], reduceMotion: Bool) {
        guard size.width > 1, size.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if size != laidOut {
            laidOut = size
            let r = CGRect(origin: .zero, size: size)
            for l in [plane, topFade, glow, shade] as [CALayer] { l.frame = r }
            // 光晕的横向半径约平面宽的 0.58，纵向到 Y 22%
            glow.endPoint = CGPoint(x: 0.5 + 0.58 * CoverPlaneModel.planeWidth(size) / Double(size.width), y: 0.22)
            placed = nil
        }

        // 1.27 秒起顶上的光先亮（减弱动态效果也只是淡入）
        glow.opacity = Float(planeSmooth((t - 1.27) / 0.35))

        let travel: Double
        let show: Bool
        if reduceMotion {
            // 减弱动态效果：封面不推进，停在铺满的样子，1.33 秒起淡入
            plane.opacity = Float(planeSmooth((t - CoverPlaneModel.start) / 0.4))
            travel = CoverPlaneModel.restTravel
            show = plane.opacity > 0
        } else {
            plane.opacity = 1
            travel = CoverPlaneModel.travel(t)
            show = t > CoverPlaneModel.start
        }

        // 平面没动、海报单子也没变（减弱动态效果、停住的那几帧）：不用重排
        let key = (travel: show ? travel : -1, count: covers.count, first: covers.first)
        if let p = placed, p.travel == key.travel, p.count == key.count, p.first == key.first { return }
        placed = key
        place(travel: travel, show: show, size: size, covers: covers)
    }

    private func place(travel: Double, show: Bool, size: CGSize, covers: [URL]) {
        var seen = Set<Slot>()
        if show {
            let W = Double(size.width), H = Double(size.height)
            let wp = CoverPlaneModel.planeWidth(size)
            // 宽窗口两边多铺几列，Y 55% 处要盖到屏边（手机上算出来就是左右各一列）
            let reach = W / 2 / (CoverPlaneModel.lateral * (0.55 - CoverPlaneModel.horizon) * wp)
            let side = max(1, min(3, Int(((reach - 0.5) / CoverPlaneModel.columnPitch).rounded(.up))))
            let columns = side * 2 + 1
            let lead = CoverPlaneModel.depth(atY: CoverPlaneModel.leadY)
            let cut = CoverPlaneModel.depth(atY: CoverPlaneModel.recycleY)
            let top = CoverPlaneModel.depth(atY: CoverPlaneModel.fadeTop)

            func screenX(_ lateral: Double, _ y: Double) -> CGFloat {
                CGFloat(W / 2 + wp * CoverPlaneModel.lateral * lateral * (y - CoverPlaneModel.horizon))
            }

            for c in -side...side {
                // 中列（和隔一列的）往远处错开半格，两侧列对齐
                let phase = c % 2 == 0 ? 0.5 : 0
                let lo = max(0, Int(((cut - CoverPlaneModel.cardDepth + travel - lead) / CoverPlaneModel.rowPitch - phase).rounded(.up)))
                let hi = Int(((top + travel - lead) / CoverPlaneModel.rowPitch - phase).rounded(.down))
                guard lo <= hi else { continue }
                let center = Double(c) * CoverPlaneModel.columnPitch
                for r in lo...hi {
                    let near = lead + (Double(r) + phase) * CoverPlaneModel.rowPitch - travel
                    guard near > 0.02 else { continue }
                    let yn = CoverPlaneModel.screenY(near), yf = CoverPlaneModel.screenY(near + CoverPlaneModel.cardDepth)
                    guard yf < CoverPlaneModel.recycleY, yn > CoverPlaneModel.fadeTop else { continue }
                    let slot = Slot(column: c, row: r)
                    seen.insert(slot)
                    let index = r * columns + c + side
                    let card = active[slot] ?? claim(slot)
                    // 刚才没有海报单子（第一次装、没网）的占位卡：单子到了就补上图
                    if card.url == nil, !covers.isEmpty {
                        let url = covers[index % covers.count]
                        card.url = url
                        fill(card, url)
                    }
                    card.layer.transform = Self.quad(
                        Self.cardSize,
                        CGPoint(x: screenX(center - 0.5, yf), y: CGFloat(yf * H)),
                        CGPoint(x: screenX(center + 0.5, yf), y: CGFloat(yf * H)),
                        CGPoint(x: screenX(center + 0.5, yn), y: CGFloat(yn * H)),
                        CGPoint(x: screenX(center - 0.5, yn), y: CGFloat(yn * H))
                    )
                }
            }
        }
        // 滑进暗区（或者还没入场）的卡回收，留给后面补进来的
        let gone = active.keys.filter { !seen.contains($0) }
        for slot in gone {
            guard let card = active.removeValue(forKey: slot) else { continue }
            card.layer.removeAllAnimations()
            card.layer.contents = nil
            card.layer.isHidden = true
            card.url = nil
            card.hasImage = false
            pool.append(card)
        }
    }

    private func claim(_ slot: Slot) -> Card {
        let card = pool.popLast() ?? makeCard()
        card.layer.isHidden = false
        card.layer.contents = nil
        card.url = nil
        card.hasImage = false
        active[slot] = card
        return card
    }

    private func makeCard() -> Card {
        let l = CALayer()
        // 锚点在左上、position 为 0：transform 直接把卡上的点映到平面图层的坐标（见 quad）
        l.anchorPoint = .zero
        l.bounds = CGRect(origin: .zero, size: Self.cardSize)
        l.position = .zero
        l.cornerRadius = 8
        l.cornerCurve = .continuous
        l.masksToBounds = true
        l.allowsEdgeAntialiasing = true
        l.contentsGravity = .resizeAspectFill
        // 远处的卡缩得很小：带 mipmap 的三线性过滤，不闪烁
        l.minificationFilter = .trilinear
        l.backgroundColor = Self.placeholder
        plane.addSublayer(l)
        return Card(layer: l)
    }

    /// 内存里有就直接贴（不淡入）；没有就去取，到了淡入
    private func fill(_ card: Card, _ url: URL) {
        if let img = ImagePipeline.shared.cached(url, maxPixel: LoginCovers.posterPixel)?.cgImage {
            card.layer.contents = img
            card.hasImage = true
            return
        }
        load(url)
    }

    private func load(_ url: URL) {
        guard !loading.contains(url) else { return }
        if let at = failedAt[url], CACurrentMediaTime() - at < 20 { return }
        loading.insert(url)
        let px = LoginCovers.posterPixel
        Task { [weak self] in
            let img = await ImagePipeline.shared.image(url, maxPixel: px)
            self?.loaded(url, img)
        }
    }

    private func loaded(_ url: URL, _ image: UIImage?) {
        loading.remove(url)
        guard let cg = image?.cgImage else {
            failedAt[url] = CACurrentMediaTime()
            return
        }
        failedAt[url] = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for card in active.values where card.url == url && !card.hasImage {
            // 从暗色占位淡入海报（录屏里封面是一张张亮起来的）
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.45
            card.layer.add(fade, forKey: "fade")
            card.layer.contents = cg
            card.hasImage = true
        }
        CATransaction.commit()
    }

    /// 把卡（0…w × 0…h）贴到屏上的四边形（左上、右上、右下、左下）：单位正方形 → 四边形的透视映射（Heckbert），
    /// 再按卡的宽高缩放。CA 是行向量乘矩阵：[x y 0 1]·M，第 4 列（m14、m24）是透视的分母
    private static func quad(_ size: CGSize, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CATransform3D {
        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y
        let det = dx1 * dy2 - dx2 * dy1
        var g: CGFloat = 0, h: CGFloat = 0
        if abs(det) > 1e-9 {
            g = (dx3 * dy2 - dx2 * dy3) / det
            h = (dx1 * dy3 - dx3 * dy1) / det
        }
        let a = p1.x - p0.x + g * p1.x, b = p3.x - p0.x + h * p3.x
        let d = p1.y - p0.y + g * p1.y, e = p3.y - p0.y + h * p3.y
        let w = size.width, ht = size.height
        var m = CATransform3DIdentity
        m.m11 = a / w; m.m12 = d / w; m.m13 = 0; m.m14 = g / w
        m.m21 = b / ht; m.m22 = e / ht; m.m23 = 0; m.m24 = h / ht
        m.m31 = 0; m.m32 = 0; m.m33 = 1; m.m34 = 0
        m.m41 = p0.x; m.m42 = p0.y; m.m43 = 0; m.m44 = 1
        return m
    }
}

// MARK: - 海报单子

/// 登录页背景用的海报：请求添加 Worker 的公开片单（/app/years，近 7 年 × 电影 / 剧集），登录前不碰影片库。
/// 存一份在本机（Caches/cuven），下次打开立刻就有；每次进程问一次新的，新单子留到下次打开再换（不在半路换掉屏上正流着的）。
/// 演示数据：本地画的海报（demo://poster/N）
@MainActor
@Observable
final class LoginCovers {
    static let shared = LoginCovers()

    /// 平面上按这个顺序取海报（空的：平面上是暗色占位）
    private(set) var urls: [URL]

    /// 海报按这个尺寸取（TMDB 的 w342 是 342 × 513；旧机型取小一点省内存）
    nonisolated static let posterPixel: CGFloat = Compat.legacyDevice ? 400 : 520

    @ObservationIgnored private var restored = false
    @ObservationIgnored private var refreshed = false
    @ObservationIgnored private var refreshing = false

    private static let etagKey = "cuven_login_covers_etag"
    private static let demo: [URL] = (0..<32).compactMap { URL(string: "demo://poster/\(60 + $0)") }

    private init() {
        urls = DemoData.enabled ? Self.demo : []
    }

    func load() async {
        if DemoData.enabled {
            if urls.isEmpty { urls = Self.demo }
            return
        }
        if !restored {
            restored = true
            // 本机存的上一份（后台读，不卡主线程）：领头几排的图顺手先取好
            let file = Self.file
            let saved = await Task.detached(priority: .userInitiated) { () -> [URL] in
                guard let data = try? Data(contentsOf: file),
                      let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
                return list.compactMap { URL(string: $0) }
            }.value
            if urls.isEmpty, !saved.isEmpty {
                urls = saved
                Self.warm(saved, priority: .userInitiated)
            }
        }
        guard !refreshed, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let year = Calendar.current.component(.year, from: Date())
        let etag = urls.isEmpty ? nil : UserDefaults.standard.string(forKey: Self.etagKey)
        do {
            let r = try await RequestAPI.years(from: year - 6, to: year, per: 12, etag: etag)
            refreshed = true
            // 304：本机那份就是最新的；404：老版本没有这个接口，留着本机的
            guard let page = r.page else { return }
            let fresh = Self.pick(page)
            guard !fresh.isEmpty else { return }
            Self.save(fresh, etag: r.etag)
            if urls.isEmpty {
                urls = fresh
                Self.warm(fresh, priority: .userInitiated)
            } else {
                // 屏上已经在流本机那份：新的留给下次打开，先把领头几张的图下到磁盘缓存里
                Self.warm(fresh, priority: .utility)
            }
        } catch {
            // 没网 / 服务暂时不可用：留着本机的（空的就一直是暗色占位），下次调用再问
        }
    }

    /// 有海报的都要（按地址去重），评分高的先（认得出来的多一些），取 96 张打乱：每次流过去的顺序不一样
    private static func pick(_ page: RequestAPI.YearsPage) -> [URL] {
        var seen = Set<String>()
        var found: [(url: URL, vote: Double)] = []
        for cells in page.years.values {
            for cell in cells.values where !cell.failed {
                for item in cell.items {
                    guard let p = item.poster, !p.isEmpty, let u = TMDBImage.url(p, "w342"),
                          seen.insert(u.absoluteString).inserted else { continue }
                    found.append((url: u, vote: item.vote ?? 0))
                }
            }
        }
        found.sort { $0.vote > $1.vote }
        return found.prefix(96).map { $0.url }.shuffled()
    }

    /// 领头几排（三列 × 六排）的图先取好：第一排一露头就是海报，不是占位
    private static func warm(_ list: [URL], priority: TaskPriority) {
        let first = Array(list.prefix(18))
        let px = posterPixel
        Task.detached(priority: priority) {
            await withTaskGroup(of: Void.self) { group in
                for u in first {
                    group.addTask { _ = await ImagePipeline.shared.image(u, maxPixel: px) }
                }
            }
        }
    }

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cuven", isDirectory: true)
            .appendingPathComponent("login-covers.v1.json")
    }

    /// 存到本机（后台写）；写成了才记 ETag，两个对得上
    private static func save(_ list: [URL], etag: String?) {
        let file = Self.file, key = etagKey
        let strings = list.map { $0.absoluteString }
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(strings) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return }
            UserDefaults.standard.set(etag, forKey: key)
        }
    }
}
