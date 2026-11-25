import SwiftUI
import UIKit
import QuartzCore

// MARK: - 登录页背景：海报沿一条「花瓶形」的通道从灵动岛下面流下来
//
// 用户要求新登录页照 Brink 的录屏和动效文档（第 2、3 页）做背景：黑底，顶端中轴一团柔灰光晕（1.27 秒亮起）；
// 1.30 秒起三列圆角封面从灵动岛平的下缘（Y 5.7%，X 39%–61%）底下钻出来，一直往下流（底下暗区回收、顶上补入）。
// 用户在录屏上画的线（「海报流的动线不对」）：两侧列走的不是汇聚到一点的直线，而是花瓶的轮廓——出口窄（约三分之一屏宽），
// 往下先向外弯开，Y 31% 左右外沿碰到屏边，再往下几乎竖直；近处的卡大、正、被屏边裁掉。中列纵向错开半格。
// 封面上压一层黑色渐变：Y 40% 起变暗、68% 全黑，正文和按钮背后是纯黑。我们的封面是影片海报（2 : 3 竖版），黑缝隔开。
//
// 形状和节奏是按录屏逐帧量出来拟合的（屏上的比例；不是一个斜平面）：
//   · 横向：x = 中轴 + v × L(y)。v 以卡宽计，第 c 列卡的两边在 c × 1.105 ± 0.5（列缝 0.105 卡宽）；三列共用一个宽度函数 L(y)：
//     灵动岛下面 0.069 屏宽、斜率 0.4（窄脖子），Y 9%–31% 斜率涨到 1.15（向外弯开），Y 36% 往下只剩 0.125（几乎竖直）；
//   · 纵向：y = Y(u)，u 是沿流向走过的距离（以录屏的一排计），匀速时每秒 1 排。上面慢、往下越来越快
//     （Y 33% 以上近似指数，往下基本匀速），一张卡从灵动岛走到 Y 68% 全黑约 5.85 秒；
//   · 每张卡上下沿的 u 定下来，四个角就在所在那列的两条边上取：远处窄、扁，近处大、正，两侧列先甩开再竖直往下；
//   · 入场：6.6 倍速冲出来，1.31 → 3.47 秒平滑减到 1 倍（录屏领头一排下沿：1.70 秒 18%、2.00 秒 37%、2.30 秒 65%）。
// 录屏里的方形卡占 0.91 排、排缝 0.09 排；海报按 2 : 3 占 1.365 排，一排 1.455 秒。
//
// 做法：一个 CALayer 当平面，每张封面一个容器图层，里面几条横切的子图层；每帧按上面的函数算出每一条四个角在屏上的位置，
// 用透视变换（矩形 → 四边形）贴上去。录屏里过弯的卡是跟着列边弯的：卡过弯那一段切成 2–6 条（每条一段直边，离真正的列边
// 不超过 0.75 点、列缝不变窄），直道上一条就够。手机上一屏最多十七张、三十来条，每帧只改 transform，旧机型 60 / 120 帧也顺；
// 封面滑进暗区就回收，换下一张海报从顶上再进来。图走 ImagePipeline（解码在后台，内存 / 磁盘缓存全 App 共用）。
// 图层顺序照 PDF 第 3 页：光晕在平面下面；平面自带一块黑底（卡缝是黑的、上半屏的封面不被光晕冲灰），出口以上用遮罩切掉。
// 宽窗口（iPad、展开的 Duo）：花瓶的轮廓不变（出口约 22% 屏宽、Y 31% 碰到屏边），多铺几列；iPhone Duo 折起时照安全区那一段宽排。
// iPhone Duo 折起（顶上没有灵动岛，状态栏在侧边那一列）：用户要求瀑布从屏幕上沿出来——平面当成往上多出 5.7% 的高屏来排，
// 出口那条线正好落在屏幕上沿，花瓶的样子、卡的宽高比都不变；底下的黑色渐变照旧按屏幕算。
// 不抖（用户真机反馈「海报封面抖动的有点明显」）：
//   · 每帧的位置按这一帧真正上屏的时刻算（CADisplayLink 的 targetTimestamp），不跟 SwiftUI 什么时候刷新走——
//     以前每帧拿 TimelineView 给的日期，主线程早一点晚一点，卡每帧走的距离就忽长忽短；
//   · 每列的卡切几条在排版时就定下来（按这一列一路上最弯的那一段算），飞的途中不变——以前按位置随时改条数，
//     改的那一下卡边跳零点几个点。

/// 登录页的时钟：从哪一刻算起、停在哪一刻（LoginLanding 的 start / pausedAt；停着的那段不算时间，恢复时 start 往后挪）
struct LandingClock: Equatable {
    var start: Date
    var pausedAt: Date?

    /// 某一刻是登录页出现以来的第几秒（停着的时候截在停下那一刻）
    func time(at date: Date) -> Double {
        max(0, (pausedAt ?? date).timeIntervalSince(start))
    }
}

/// 登录页的封面背景（全屏；放在最底下，前景、状态栏都在它上面）。自己跟着屏幕刷新按 clock 算每一帧（停着的时候不走）
struct LoginCoverPlane: View {
    let clock: LandingClock
    let size: CGSize
    /// 中轴（平面的竖中线）到较近那条看得见的屏边有多远（点）。iPhone Duo 折起时前景在安全区里居中、平面两边加宽了，
    /// 通道照安全区那一段宽排（和同样宽的手机一个样子），不照加宽以后的平面。nil：半个平面宽
    var reach: CGFloat? = nil
    /// 出口放在屏幕上沿（iPhone Duo 折起：顶上没有灵动岛）；false 是灵动岛平的下缘
    var edgeStart = false
    let covers: [URL]
    var reduceMotion = false

    var body: some View {
        CoverPlaneCanvas(clock: clock, size: size, reach: reach ?? size.width / 2, edgeStart: edgeStart, covers: covers,
                         reduceMotion: reduceMotion)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - 通道的几何和节奏

/// 屏上的 Y 都是屏高的比例（从顶往下）；横向以「参考屏宽」lateral（点）为单位，录屏那台手机就是屏宽。u：沿流向的距离（排）
private enum CoverPlaneModel {
    /// 录屏那台手机的屏宽 : 屏高（402 × 874）
    static let refAspect = 0.46
    /// 封面露头的那条线：灵动岛平的下缘
    static let emerge = 0.0569

    // 宽度 L(y)（参考屏宽的比例）= l0 + k(y − emerge) + 两段软折线（softplus）：Y 8.4% 附近斜率往上加 1.04，Y 31% 附近再减回去。
    // 和录屏量的差最多 0.0016
    static let widthBase = 0.0694
    static let widthSlope = 0.1249
    static let flare = 1.0389
    static let flareY = 0.0841
    static let flareSoft = 0.0240
    static let settleY = 0.3132
    static let settleSoft = 0.0265

    // 走过 u 排以后在屏上的 Y：起步每排 3% 屏高，u ≈ 3.5 附近软转到每排 13.9%，再加一点匀加速。和录屏量的差最多 0.0007
    static let crawl = 0.0299
    static let cruise = 0.1391
    static let rampU = 3.544
    static let rampSoft = 0.437
    static let drift = 0.0115

    /// 相邻两列中心隔几个卡宽（多出来的 0.105 是黑缝）
    static let columnPitch = 1.105
    /// 一张海报沿流向占几排（录屏的方形卡 0.91 排，2 : 3 竖版 × 1.5），排间黑缝几排（和列缝一样宽）
    static let cardLength = 1.365
    static let rowGap = 0.09
    /// 匀速每秒 1 排；入场：1.30 秒起，先 6.6 倍速，1.309 → 3.474 秒平滑减到 1 倍
    static let start = 1.300
    static let rush = 6.6
    static let easeFrom = 1.309
    static let easeTo = 3.474
    /// 卡的上沿过了 Y 70%（渐变 68% 已经全黑）就回收
    static let recycleY = 0.70
    /// 出口：灵动岛下缘往上一点点看不见，往下一点点完全露出来（没有灵动岛的机型像从光晕里钻出来）
    static let fadeTop = emerge - 0.005
    static let fadeFull = emerge + 0.006
    /// 海报沿流向的长度跟着横向一起缩放（宽高比不变），但别缩放得太离谱
    static let minScale = 0.75
    static let maxScale = 1.35
    /// 中列两边最多各铺几列
    static let maxSides = 3
    /// 一张卡最多切几条、每条直边离列边最多差几点、相邻两条往下多盖多少（卡长的比例；接缝不露底）
    static let maxStrips = 6
    static let bendTolerance = 0.75
    static let stripOverlap = 0.012

    static func softplus(_ z: Double) -> Double { z > 20 ? z : log1p(exp(z)) }

    private static func widthTerm(_ y: Double) -> Double {
        widthSlope * (y - emerge)
            + flare * flareSoft * softplus((y - flareY) / flareSoft)
            - flare * settleSoft * softplus((y - settleY) / settleSoft)
    }
    private static let widthAtEmerge = widthTerm(emerge)

    /// Y 处一个卡宽占几个参考屏宽
    static func width(_ y: Double) -> Double { widthBase + widthTerm(y) - widthAtEmerge }

    private static let rampAtZero = softplus(-rampU / rampSoft)
    private static let slopeAtZero = crawl + (cruise - crawl) / (1 + exp(rampU / rampSoft))

    /// 走过 u 排的那条线在屏上的 Y。u < 0（还在灵动岛底下）按出口的速度直线外推：卡整张贴上去，出口以上的部分由遮罩挡住，
    /// 看上去是从底下滑出来，不是被压扁了挤出来
    static func screenY(_ u: Double) -> Double {
        guard u > 0 else { return emerge + slopeAtZero * u }
        return emerge + crawl * u + (cruise - crawl) * rampSoft * (softplus((u - rampU) / rampSoft) - rampAtZero)
            + drift * u * u / 2
    }

    /// screenY 的反函数（二分；只在初始化时用）
    static func along(atY y: Double) -> Double {
        var lo = -3.0, hi = 12.0
        for _ in 0..<60 {
            let m = (lo + hi) / 2
            if screenY(m) < y { lo = m } else { hi = m }
        }
        return (lo + hi) / 2
    }

    /// 上沿走过这里就回收
    static let cutU = along(atY: recycleY)
    /// 下沿走过这里（遮罩还全透明的那条线）就把卡贴上去：露头是从全透明慢慢显出来，不是半透明的一截一下子冒出来
    static let appearU = along(atY: fadeTop)

    /// 录屏里两侧列的外沿（v = 1.605）在 L = 0.3115（Y 31%）处碰到屏边（离中轴 0.5 个屏宽）
    static let edgeWidth = 0.5 / (columnPitch + 0.5)

    struct Layout {
        /// 参考屏宽（点）
        let lateral: Double
        /// 海报沿流向的长度乘几
        let scale: Double
        /// 中列两边各几列
        let sides: Int
    }

    /// 按中轴到近处屏边的距离排：最外一列的外沿要在 Y 31% 碰到屏边（花瓶的轮廓和录屏一样），列数挑卡的大小最接近录屏的那个
    /// （手机竖拿就是左右各一列、参考屏宽 = 屏宽；iPad 竖拿两列、横拿三列）。海报的长度跟着横向一起缩放，宽高比不变
    static func layout(_ size: CGSize, reach: Double) -> Layout {
        let ref = refAspect * Double(size.height)
        let r = max(1, reach)
        var best = (sides: 1, lateral: 2 * r, score: Double.infinity)
        for s in 1...maxSides {
            let lx = r / ((Double(s) * columnPitch + 0.5) * edgeWidth)
            let score = abs(log(lx / ref))
            if score < best.score { best = (sides: s, lateral: lx, score: score) }
        }
        return Layout(lateral: best.lateral, scale: min(maxScale, max(minScale, best.lateral / ref)), sides: best.sides)
    }

    /// 一张卡（沿流向 top…bottom）切几条才跟得上列边的弯：拿直边连它上下沿的两个角，量它离真正的列边差几点
    /// （列边在屏外的按屏边算）；差 bendTolerance 以内一条就够，差得多就切细（误差约按条数的平方缩小）
    static func strips(top: Double, bottom: Double, edge: Double, lateral: Double, half: Double) -> Int {
        let yt = screenY(top), yb = screenY(bottom)
        guard yb - yt > 1e-6 else { return 1 }
        let lt = width(yt), lb = width(yb)
        var miss = 0.0
        for f in stride(from: 0.25, through: 0.75, by: 0.25) {
            let y = screenY(top + (bottom - top) * f)
            let l = width(y)
            let chord = lt + (lb - lt) * (y - yt) / (yb - yt)
            miss = max(miss, abs(l - chord) * min(edge * lateral, half / max(l, 1e-6)))
        }
        let n = (miss / bendTolerance).squareRoot().rounded(.up)
        return n.isFinite ? Int(min(Double(maxStrips), max(1, n))) : 1
    }

    /// 1.30 秒起一共走了几排：速度 = 1 ×（1 + 5.6 ×（1 − smoothstep(1.309…3.474)）），这里是它的积分
    static func travel(_ t: Double) -> Double {
        guard t > start else { return 0 }
        let w = easeTo - easeFrom
        let p = min(1, max(0, (t - easeFrom) / w))
        // smoothstep 从 easeFrom 积到 t：w·(p³ − p⁴/2)，过了 easeTo 以后每秒都是 1
        let eased = w * (p * p * p - p * p * p * p / 2) + max(0, t - easeTo)
        let s = t - start
        return s + (rush - 1) * (s - eased)
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
    let clock: LandingClock
    let size: CGSize
    let reach: CGFloat
    let edgeStart: Bool
    let covers: [URL]
    let reduceMotion: Bool

    func makeUIView(context: Context) -> CoverPlaneView {
        CoverPlaneView(frame: CGRect(origin: .zero, size: size))
    }

    func updateUIView(_ view: CoverPlaneView, context: Context) {
        view.configure(clock: clock, size: size, reach: reach, edgeStart: edgeStart, covers: covers, reduceMotion: reduceMotion)
    }

    static func dismantleUIView(_ view: CoverPlaneView, coordinator: ()) {
        view.stop()
    }
}

/// 显示链的目标：弱引用平面（显示链强引用它的目标，平面不在了它自己停）
@MainActor
private final class CoverPlaneTick: NSObject {
    weak var owner: CoverPlaneView?

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.tick(link)
    }
}

private final class CoverPlaneView: UIView {
    /// 通道上的一格：第几列（中间是 0）、第几排（领头一排是 0，往后数）
    private struct Slot: Hashable {
        let column: Int
        let row: Int
    }

    private final class Card {
        /// 容器（不变形）；里面 maxStrips 条横切的子图层，用到几条显示几条（见 shape）
        let layer: CALayer
        let strips: [CALayer]
        var url: URL?
        var hasImage = false
        /// 图上取哪一块（单位坐标，按 2 : 3 居中裁，等于 aspect fill）：每一条再取其中自己那一段
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        /// 现在切成几条（0：还没配过）
        var cut = 0
        init(layer: CALayer, strips: [CALayer]) {
            self.layer = layer
            self.strips = strips
        }
    }

    /// 认的是哪一份海报单子（换了单子，预取从头记）
    private struct CoverList: Equatable {
        let count: Int
        let first: URL?
    }

    private let plane = CALayer()
    /// 平面自己的黑底（只铺通道那块花瓶形）：卡之间的缝是黑的，通道外面透出底下的光晕（录屏第 6 秒顶上就是这样）。
    /// 外面套一层裁切，只往下伸到领头一排：入场时黑底跟着封面一起往下铺，还没铺到的地方照旧是光晕
    private let sheetClip = CALayer()
    private let sheet = CAShapeLayer()
    /// 平面的遮罩：出口以上看不见（封面从灵动岛下面钻出来；光晕不在平面里，不受它影响）
    private let topFade = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let shade = CAGradientLayer()

    private var active: [Slot: Card] = [:]
    private var pool: [Card] = []
    private var loading: Set<URL> = []
    /// 取不到的图：这么久以内不再试（没网时不反复打）
    private var failedAt: [URL: CFTimeInterval] = [:]
    /// 每列已经预取到第几排（见 place）
    private var prefetchedTo: [Int: Int] = [:]
    private var lastList: CoverList?

    /// 平面按多大排（出口贴屏幕上沿时比屏幕高 lift，往上伸出去）
    private var laidOut: CGSize = .zero
    private var laidScreen: CGSize = .zero
    private var laidReach: CGFloat = 0
    private var laidEdge = false
    private var lift: CGFloat = 0
    /// 每列的卡切几条（下标是离中列几列）：排版时定下来，飞的途中不变
    private var columnStrips: [Int] = [1]

    // SwiftUI 给的设置（configure）；显示链每帧按它们画
    private var clock = LandingClock(start: Date(), pausedAt: Date())
    private var screen: CGSize = .zero
    private var reachIn: CGFloat = 0
    private var edgeStart = false
    private var covers: [URL] = []
    private var reduceMotion = false
    private var link: CADisplayLink?
    /// CACurrentMediaTime 的秒数 + 这个 = Date 的秒数（显示链给的时刻在 CACurrentMediaTime 的时间轴上）
    private var mediaToDate: Double = 0
    /// 减弱动态效果：光晕 1.36 秒亮完、封面 1.7 秒淡完，过了这里画面不再变，显示链停掉
    private static let restAfter = 1.8
    /// 中列两边各几列、参考屏宽（点）、海报长度乘几（CoverPlaneModel.layout）
    private var side = 1
    private var lateral = 0.0
    private var scale = 1.0
    /// 用户的 iPad 布局：参考屏宽过 500 点，上半屏还亮着的卡比 w342 大（拉伸 1.3–1.7 倍会发虚），改要 w500、按 760 像素解码。
    /// 旧机型不换（省内存、省流量）
    private var hiRes = false
    private var placed: (travel: Double, count: Int, first: URL?)?

    /// 卡在自己坐标系里的大小（2 : 3）：透视变换把它（的每一条）贴到屏上的四边形，圆角跟着透视一起缩放
    private static let cardSize = CGSize(width: 100, height: 150)
    fileprivate static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// 没网、图还没到：暗色占位
    private static let placeholder = UIColor(white: 0.1, alpha: 1).cgColor

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        // 两侧的卡跨过屏边：放在不满屏的容器里（分屏、iPad 小窗）也不画到外面去
        clipsToBounds = true
        isOpaque = true
        backgroundColor = .black

        // 出口：遮罩透明 → 不透明，封面（连同平面的黑底）从灵动岛下面钻出来；只遮平面，光晕的亮心照旧露着
        topFade.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor]
        topFade.locations = [0, NSNumber(value: CoverPlaneModel.fadeTop), NSNumber(value: CoverPlaneModel.fadeFull)]
        topFade.startPoint = CGPoint(x: 0.5, y: 0)
        topFade.endPoint = CGPoint(x: 0.5, y: 1)
        plane.mask = topFade

        // 平面的黑底：平面最底下一层，卡都压在它上面（makeCard 往后加）
        sheet.fillColor = UIColor.black.cgColor
        sheetClip.masksToBounds = true
        sheetClip.isHidden = true
        sheetClip.addSublayer(sheet)
        plane.addSublayer(sheetClip)

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

        // 用户要求照 PDF 第 3 页的图层顺序：A 黑底 + 顶部柔光在最下面，B 封面平面压在光晕上（中上部的封面保留亮度和饱和度、
        // 卡缝是黑的），C 黑色渐变再压在封面上
        for l in [glow, plane, shade] as [CALayer] { layer.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// SwiftUI 每次更新给一遍设置。显示链在走：下一帧自己按新的设置画；没在走（停着、还没进窗口、减弱动态效果已经定住）就现在画一帧
    func configure(clock: LandingClock, size: CGSize, reach: CGFloat, edgeStart: Bool, covers: [URL], reduceMotion: Bool) {
        self.clock = clock
        screen = size
        reachIn = reach
        self.edgeStart = edgeStart
        self.covers = covers
        self.reduceMotion = reduceMotion
        syncLink()
        if link == nil { render(t: clock.time(at: Date())) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncLink()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// 显示链只在看得见、没停、画面还在变的时候走
    private func syncLink() {
        let want = window != nil && clock.pausedAt == nil && !(reduceMotion && clock.time(at: Date()) > Self.restAfter)
        if want, link == nil {
            mediaToDate = Date().timeIntervalSinceReferenceDate - CACurrentMediaTime()
            let target = CoverPlaneTick()
            target.owner = self
            let l = CADisplayLink(target: target, selector: #selector(CoverPlaneTick.tick(_:)))
            // 旧机型（Compat.legacyDevice）最多 60 帧；别的跟屏幕走（ProMotion 120）
            l.preferredFrameRateRange = Compat.legacyDevice
                ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                : CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        } else if !want {
            stop()
        }
    }

    /// 一帧：按这一帧真正上屏的时刻（targetTimestamp）算，每帧走的距离一样，不跟着主线程什么时候被叫到忽快忽慢
    fileprivate func tick(_ l: CADisplayLink) {
        let t = clock.time(at: Date(timeIntervalSinceReferenceDate: l.targetTimestamp + mediaToDate))
        render(t: t)
        if reduceMotion, t > Self.restAfter { syncLink() }
    }

    private func render(t: Double) {
        let screenSize = screen
        guard screenSize.width > 1, screenSize.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let near = min(max(1, reachIn), screenSize.width / 2)
        if screenSize != laidScreen || near != laidReach || edgeStart != laidEdge {
            laidScreen = screenSize
            laidReach = near
            laidEdge = edgeStart
            // 出口贴屏幕上沿：平面当成往上多出一截的高屏来排，出口那条线（emerge）正好落在屏幕上沿
            let modelH = edgeStart ? screenSize.height / (1 - CoverPlaneModel.emerge) : screenSize.height
            lift = modelH - screenSize.height
            let size = CGSize(width: screenSize.width, height: modelH)
            laidOut = size
            let r = CGRect(origin: .zero, size: size)
            // 平面和光晕往上伸出去 lift（屏外那截被 clipsToBounds 裁掉）；平面里面的东西都按平面自己的坐标
            for l in [glow, plane] as [CALayer] { l.frame = r.offsetBy(dx: 0, dy: -lift) }
            for l in [sheetClip, sheet] as [CALayer] { l.frame = r }
            // 黑色渐变按屏幕算（Y 40% 起变暗、68% 全黑，和图标、标题的位置对得上）
            shade.frame = CGRect(origin: .zero, size: screenSize)
            // 遮罩不在图层树里，单独给（平面自己的坐标）
            topFade.frame = r
            for card in active.values { card.layer.frame = r }
            for card in pool { card.layer.frame = r }
            let fit = CoverPlaneModel.layout(size, reach: Double(near))
            side = fit.sides
            lateral = fit.lateral
            scale = fit.scale
            sheet.path = footprint(size)
            columnStrips = (0...side).map { stripCount(column: $0, half: Double(size.width) / 2) }
            hiRes = lateral > 500 && !Compat.legacyDevice
            // 下次打开要用的那份海报按同一个尺寸先下（LoginCovers.prefetch）
            LoginCovers.shared.hiRes = hiRes
            // 光晕的横向半径约参考屏宽的 0.58，纵向到 Y 22%
            glow.endPoint = CGPoint(x: 0.5 + 0.58 * lateral / Double(size.width), y: 0.22)
            prefetchedTo = [:]
            placed = nil
        }
        let size = laidOut
        let list = CoverList(count: covers.count, first: covers.first)
        if list != lastList {
            lastList = list
            prefetchedTo = [:]
        }

        // 顶上的光先亮、封面再露头（PDF：1.27 秒顶部先亮，1.37 秒卡片露头）。按录屏量的：1.20 秒还是黑的，
        // 1.28 秒约一半，1.33 秒九成，1.36 秒全亮——第一排封面出来的时候光已经在了（减弱动态效果也一样，本来就只是淡入）
        glow.opacity = Float(planeSmooth((t - 1.19) / 0.17))

        let travel: Double
        let show: Bool
        if reduceMotion {
            // 减弱动态效果：封面不推进，停在铺满的样子，1.30 秒起淡入
            plane.opacity = Float(planeSmooth((t - CoverPlaneModel.start) / 0.4))
            travel = CoverPlaneModel.restTravel
            show = plane.opacity > 0
        } else {
            plane.opacity = 1
            travel = CoverPlaneModel.travel(t)
            show = t > CoverPlaneModel.start
        }

        // 没往前走、海报单子也没变（减弱动态效果、停住的那几帧）：不用重排
        let key = (travel: show ? travel : -1, count: covers.count, first: covers.first)
        if let p = placed, p.travel == key.travel, p.count == key.count, p.first == key.first { return }
        placed = key
        // 往后预取几排：入场前先取开场冲过来的那六排（三列就是 18 张）；之后每列多取还没露头的下一两排；
        // 减弱动态效果不动，只取看得见的
        let ahead = reduceMotion ? 0 : (show ? 2 : 5)
        place(travel: travel, show: show, ahead: ahead, size: size, covers: covers)
    }

    /// 第 column 列（离中列几列）的卡切几条：沿整条路（从露头到回收）每 0.05 排量一次，取最多的那次。
    /// 这样一张卡飞的途中条数不变，卡边不会在改条数的那一下跳一点
    private func stripCount(column: Int, half: Double) -> Int {
        let edge = Double(column) * CoverPlaneModel.columnPitch + 0.5
        let length = CoverPlaneModel.cardLength * scale
        var n = 1
        var top = CoverPlaneModel.appearU - length
        while top < CoverPlaneModel.cutU, n < CoverPlaneModel.maxStrips {
            n = max(n, CoverPlaneModel.strips(top: top, bottom: top + length, edge: edge, lateral: lateral, half: half))
            top += 0.05
        }
        return n
    }

    /// 通道在屏上的那块花瓶形（最外两列的外沿之间，从出口一直到屏底）
    private func footprint(_ size: CGSize) -> CGPath {
        let W = Double(size.width), H = Double(size.height)
        let half = Double(side) * CoverPlaneModel.columnPitch + 0.5
        var right: [CGPoint] = []
        var left: [CGPoint] = []
        let n = 48
        for i in 0...n {
            // 上面弯得急，点排密一些
            let y = CoverPlaneModel.fadeTop + (1 - CoverPlaneModel.fadeTop) * pow(Double(i) / Double(n), 1.6)
            let dx = half * CoverPlaneModel.width(y) * lateral
            right.append(CGPoint(x: W / 2 + dx, y: y * H))
            left.append(CGPoint(x: W / 2 - dx, y: y * H))
        }
        let path = CGMutablePath()
        path.addLines(between: right + left.reversed())
        path.closeSubpath()
        return path
    }

    private var pixel: CGFloat { LoginCovers.pixel(hiRes: hiRes) }
    private func source(_ url: URL) -> URL { LoginCovers.source(url, hiRes: hiRes) }

    private func place(travel: Double, show: Bool, ahead: Int, size: CGSize, covers: [URL]) {
        var seen = Set<Slot>()
        let W = Double(size.width), H = Double(size.height)
        let lx = lateral
        let columns = side * 2 + 1
        let length = CoverPlaneModel.cardLength * scale
        let pitch = (CoverPlaneModel.cardLength + CoverPlaneModel.rowGap) * scale
        let cut = CoverPlaneModel.cutU
        let px = pixel

        // 平面的黑底跟着领头一排往下铺，按落后半格的中列算（中间那张还没出来的地方照旧透出光晕，录屏 1.36 秒就是这样）；
        // 那一排走进暗区以后就一直铺到屏底
        sheetClip.isHidden = !show
        if show {
            let front = travel - 0.5 * pitch
            let bottom = front < cut ? min(1, max(0, CoverPlaneModel.screenY(front))) : 1
            sheetClip.frame = CGRect(x: 0, y: 0, width: size.width, height: CGFloat(bottom * H))
        }

        for c in -side...side {
            // 中列（和隔一列的）往后错开半格，两侧列对齐。第 r 排的下沿走到了 travel − (r + phase) × pitch
            let phase = c % 2 == 0 ? 0.5 : 0
            let lo = max(0, Int(((travel - length - cut) / pitch - phase).rounded(.down)))
            let hi = Int(((travel - CoverPlaneModel.appearU) / pitch - phase).rounded(.up))

            // 用户要求上半屏的封面是亮的：新的一排从顶上露头前图就先取好（多半已经解码完），不是暗块一路走过最亮的那段。
            // 每列记着取到了第几排，每排只问一次；内存里已经有的不再取
            if !covers.isEmpty {
                let to = hi + ahead
                let from = max(0, prefetchedTo[c].map { $0 + 1 } ?? (show ? hi + 1 : lo))
                if from <= to {
                    prefetchedTo[c] = to
                    for r in from...to {
                        let url = source(covers[(r * columns + c + side) % covers.count])
                        if ImagePipeline.shared.cached(url, maxPixel: px) == nil { load(url) }
                    }
                }
            }

            guard show, lo <= hi else { continue }
            let center = Double(c) * CoverPlaneModel.columnPitch
            for r in lo...hi {
                let bottom = travel - (Double(r) + phase) * pitch
                let top = bottom - length
                // 下沿还在遮罩全透明的地方，或者上沿已经进了暗区
                guard bottom > CoverPlaneModel.appearU, top < cut else { continue }
                // 整张卡都在平面外面（宽窗口最外几列的近处）：不占图层
                if c != 0, (abs(center) - 0.5) * CoverPlaneModel.width(CoverPlaneModel.screenY(top)) * lx > W / 2 { continue }
                let slot = Slot(column: c, row: r)
                seen.insert(slot)
                let index = r * columns + c + side
                let card = active[slot] ?? claim(slot)
                // 刚才没有海报单子（第一次装、没网）的占位卡：单子到了就补上图
                if card.url == nil, !covers.isEmpty {
                    let url = source(covers[index % covers.count])
                    card.url = url
                    fill(card, url)
                }
                let n = columnStrips[min(abs(c), columnStrips.count - 1)]
                shape(card, n)
                // 每一条：沿流向取卡上 f0…f1 那一段，四个角落在所在那列的两条边上
                for i in 0..<n {
                    let (f0, f1) = Self.span(i, n)
                    let ya = CoverPlaneModel.screenY(top + length * f0)
                    let yb = CoverPlaneModel.screenY(top + length * f1)
                    let wa = CoverPlaneModel.width(ya) * lx
                    let wb = CoverPlaneModel.width(yb) * lx
                    card.strips[i].transform = Self.quad(
                        CGSize(width: Self.cardSize.width, height: Self.cardSize.height * CGFloat(f1 - f0)),
                        CGPoint(x: W / 2 + (center - 0.5) * wa, y: ya * H),
                        CGPoint(x: W / 2 + (center + 0.5) * wa, y: ya * H),
                        CGPoint(x: W / 2 + (center + 0.5) * wb, y: yb * H),
                        CGPoint(x: W / 2 + (center - 0.5) * wb, y: yb * H)
                    )
                }
            }
        }
        // 滑进暗区（或者还没入场）的卡回收，留给后面补进来的
        let gone = active.keys.filter { !seen.contains($0) }
        for slot in gone {
            guard let card = active.removeValue(forKey: slot) else { continue }
            wipe(card)
            card.layer.isHidden = true
            pool.append(card)
        }
    }

    private func claim(_ slot: Slot) -> Card {
        let card = pool.popLast() ?? makeCard()
        card.layer.isHidden = false
        wipe(card)
        active[slot] = card
        return card
    }

    /// 卡回收或者重新领用：图、裁切、条数都清掉（下次用的时候重新配条，contentsRect 跟着新图的裁切）
    private func wipe(_ card: Card) {
        for l in card.strips {
            l.removeAllAnimations()
            l.contents = nil
        }
        card.url = nil
        card.hasImage = false
        card.crop = Self.fullCrop
        card.cut = 0
    }

    private func makeCard() -> Card {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: laidOut)
        var strips: [CALayer] = []
        for _ in 0..<CoverPlaneModel.maxStrips {
            let l = CALayer()
            // 锚点在左上、position 为 0：transform 直接把这一条上的点映到平面图层的坐标（见 quad）
            l.anchorPoint = .zero
            l.bounds = CGRect(origin: .zero, size: Self.cardSize)
            l.position = .zero
            l.cornerRadius = 8
            l.cornerCurve = .continuous
            l.masksToBounds = true
            l.allowsEdgeAntialiasing = true
            // 裁切自己算（crop + contentsRect），每一条按自己那一段拉满
            l.contentsGravity = .resize
            // 远处的卡缩得很小：带 mipmap 的三线性过滤，不闪烁
            l.minificationFilter = .trilinear
            l.backgroundColor = Self.placeholder
            l.isHidden = true
            // 后加的在上面：每一条往下多盖的那一点被下一条压住
            container.addSublayer(l)
            strips.append(l)
        }
        plane.addSublayer(container)
        return Card(layer: container, strips: strips)
    }

    /// 切成 n 条：第 i 条管卡上 [i/n, (i+1)/n] 那一段，往下多盖 stripOverlap（接缝不露底）；
    /// 只有第一条带上面两个圆角、最后一条带下面两个，抗锯齿也只开卡的外沿（中间的接缝不描边）
    private func shape(_ card: Card, _ n: Int) {
        guard card.cut != n else { return }
        card.cut = n
        for (i, l) in card.strips.enumerated() {
            guard i < n else {
                l.isHidden = true
                continue
            }
            let (f0, f1) = Self.span(i, n)
            l.isHidden = false
            l.bounds = CGRect(x: 0, y: 0, width: Self.cardSize.width, height: Self.cardSize.height * CGFloat(f1 - f0))
            var corners: CACornerMask = []
            var edges: CAEdgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge]
            if i == 0 {
                corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner])
                // minY 那条边（CA 叫它 bottom）：卡的上沿
                edges.insert(.layerBottomEdge)
            }
            if i == n - 1 {
                corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
                // maxY 那条边（CA 叫它 top）：卡的下沿
                edges.insert(.layerTopEdge)
            }
            l.maskedCorners = corners
            l.edgeAntialiasingMask = edges
            l.contentsRect = Self.slice(card.crop, f0, f1)
        }
    }

    /// 第 i 条（共 n 条）管卡上沿流向的哪一段（0 是上沿、1 是下沿）
    private static func span(_ i: Int, _ n: Int) -> (Double, Double) {
        let f0 = Double(i) / Double(n)
        let f1 = i == n - 1 ? 1 : min(1, Double(i + 1) / Double(n) + CoverPlaneModel.stripOverlap)
        return (f0, f1)
    }

    private static func slice(_ crop: CGRect, _ f0: Double, _ f1: Double) -> CGRect {
        CGRect(x: crop.minX, y: crop.minY + crop.height * CGFloat(f0),
               width: crop.width, height: crop.height * CGFloat(f1 - f0))
    }

    /// 图按 2 : 3 居中裁（aspect fill）：宽了裁两边，长了裁上下
    private static func crop(_ image: CGImage) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return fullCrop }
        let card = cardSize.width / cardSize.height
        let aspect = w / h
        if aspect > card {
            let cw = card / aspect
            return CGRect(x: (1 - cw) / 2, y: 0, width: cw, height: 1)
        }
        let ch = aspect / card
        return CGRect(x: 0, y: (1 - ch) / 2, width: 1, height: ch)
    }

    /// 贴图：每一条都是同一张图（不多占内存），各取自己那一段
    private func paint(_ card: Card, _ image: CGImage) {
        card.crop = Self.crop(image)
        for (i, l) in card.strips.enumerated() {
            l.contents = image
            if i < card.cut {
                let (f0, f1) = Self.span(i, card.cut)
                l.contentsRect = Self.slice(card.crop, f0, f1)
            }
        }
        card.hasImage = true
    }

    /// 内存里有就直接贴（不淡入）；没有就去取，到了淡入
    private func fill(_ card: Card, _ url: URL) {
        if let img = ImagePipeline.shared.cached(url, maxPixel: pixel)?.cgImage {
            paint(card, img)
            return
        }
        load(url)
    }

    private func load(_ url: URL) {
        guard !loading.contains(url) else { return }
        if let at = failedAt[url], CACurrentMediaTime() - at < 20 { return }
        loading.insert(url)
        let px = pixel
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
            // 从暗色占位淡入海报（录屏里封面是一张张亮起来的）；每一条都淡，没露出来的那几条换条数时接着淡
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.45
            for l in card.strips { l.add(fade, forKey: "fade") }
            paint(card, cg)
        }
        CATransaction.commit()
    }

    /// 把一条（0…w × 0…h）贴到屏上的四边形（左上、右上、右下、左下）：单位正方形 → 四边形的透视映射（Heckbert），
    /// 再按这一条的宽高缩放。CA 是行向量乘矩阵：[x y 0 1]·M，第 4 列（m14、m24）是透视的分母
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
/// 存一份在本机（Caches/cuven），下次打开立刻就有；每次进程问一次新的，新单子留到下次打开再换（不在半路换掉屏上正流着的）；
/// 手上一张都没有又没问成的，登录页开着就隔一会儿再问。
/// 演示数据：本地画的海报（demo://poster/N）
@MainActor
@Observable
final class LoginCovers {
    static let shared = LoginCovers()

    /// 平面上按这个顺序取海报（空的：平面上是暗色占位）
    private(set) var urls: [URL]

    /// 海报按这个尺寸解码：TMDB 的 w342 是 342 × 513，按 520（旧机型 400 省内存）；大图（w500，见 source）按 760
    nonisolated static func pixel(hiRes: Bool) -> CGFloat {
        hiRes ? 760 : (Compat.legacyDevice ? 400 : 520)
    }

    /// 用户的 iPad 布局：平面宽过 500 点时卡比 w342 大，改要 TMDB 的 w500（换的是地址里的尺寸段；演示海报、别的图床原样）
    nonisolated static func source(_ url: URL, hiRes: Bool) -> URL {
        hiRes ? (TMDBImage.url(url.absoluteString, "w500") ?? url) : url
    }

    /// 平面上回排的是不是大图（CoverPlaneView 按窗口大小设）：下次打开要用的那份按同一个尺寸先下
    @ObservationIgnored var hiRes = false

    @ObservationIgnored private var restored = false
    @ObservationIgnored private var refreshed = false
    @ObservationIgnored private var refreshing = false
    /// 没问成时隔多久再问（2、4、8…最多 30 秒）
    @ObservationIgnored private var retryDelay: Double = 2

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
            // 本机存的上一份（后台读，不卡主线程）。领头几排的图由平面自己按窗口大小先取（CoverPlaneView 的预取，尺寸对得上）
            let file = Self.file
            let saved = await Task.detached(priority: .userInitiated) { () -> [URL] in
                guard let data = try? Data(contentsOf: file),
                      let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
                return list.compactMap { URL(string: $0) }
            }.value
            if urls.isEmpty, !saved.isEmpty { urls = saved }
        }
        guard !refreshed, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let year = Calendar.current.component(.year, from: Date())
        while !refreshed, !Task.isCancelled {
            let etag = urls.isEmpty ? nil : UserDefaults.standard.string(forKey: Self.etagKey)
            do {
                let r = try await RequestAPI.years(from: year - 6, to: year, per: 12, etag: etag)
                refreshed = true
                retryDelay = 2
                // 304：本机那份就是最新的；404：老版本没有这个接口，留着本机的
                guard let page = r.page else { return }
                let fresh = Self.pick(page)
                guard !fresh.isEmpty else { return }
                Self.save(fresh, etag: r.etag)
                if urls.isEmpty {
                    urls = fresh
                } else {
                    // 屏上已经在流本机那份：新的留给下次打开
                    Self.prefetch(fresh, hiRes: hiRes)
                }
            } catch {
                // 用户要的海报背景：第一次打开就没网（服务暂时不可用、首次联网的弹窗还没点）时别一整次都是暗块，隔一会儿再问；
                // 登录页不在了（调用方的任务取消）就停。本机有上一份的不急，留着它，下次调用再问
                guard urls.isEmpty, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(retryDelay))
                retryDelay = min(retryDelay * 2, 30)
            }
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

    /// 用户要求下次打开立刻有海报：新单子领头几排（三列 × 六排）的图只下到磁盘缓存（URLCache），不解码进内存（这次用不上）；
    /// 晚几秒、一张一张下，不和屏上正在进来的那几排抢连接
    private static func prefetch(_ list: [URL], hiRes: Bool) {
        let first = list.prefix(18).map { source($0, hiRes: hiRes) }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(8))
            for u in first { _ = await ImagePipeline.shared.data(u) }
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
