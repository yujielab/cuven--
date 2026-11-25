import SwiftUI

// MARK: - 登录落地页开场：品牌蓝整屏收束成 Cuven max 图标
//
// 用户要求新登录页「UI 和动效参考我发你的视频和文档」：照 Brink 品牌启动那一段做（PDF 第 1 页的读数 + 录屏逐帧量的中间值）。
// · 0–0.5 秒：整屏品牌蓝（BrandIcon 的渐变），白色「Cuven max」字标居中。
// · 0.5 秒起底板收束：先往下收（黑底从上下露出，字标跟着下移）→ 0.63 秒竖矩形 → 0.67 秒下探到最低点（中心约 61% 屏高）
//   → 反向上提，0.73 秒首次成方 → 0.83 秒压到最扁、越过落点 → 1.17 秒回弹成圆角方形图标，落在 target。
// · 底板（宽、高、圆角、中心 Y）和字标分两条轨：字标只沿中轴等比缩到初始约 56%；按最大的样子排字、只往小缩，一直清晰。
//   压扁最狠的那几帧字标两端略出底板（参考里就是这样）。
// · 关键帧按参考屏 403 × 877、落点 85 × 85 记。换到别的屏：比落点大的那段按「整屏 → 落点」的比例换算，
//   比落点小的那段（压扁、越位）按落点尺寸的倍数换算，下探按屏高换算。关键帧之间用单调三次插值，不会多出参考里没有的晃动。
// · 落稳以后就停在落点上当图标：用户要求直接用开场收束出来的这一枚，不再换成 BrandIcon 图（以前最后 0.12 秒淡到图上，
//   画出来的字标和图上的字差一点点，换的那一下看得出在抖）。
// · 减弱动态效果：不做形变，0.5 秒起整屏品牌 0.3 秒淡成落点上的同一枚图标。

/// 全屏一层：坐标和 size 同一套（左上角是屏幕左上角，要铺到安全区外面），target 是图标的落点。
/// 不接触摸、不进旁白（标题和按钮在下面那层；字标只是品牌画面）。落稳以后画的就是落点上的图标
struct BrandCollapseLayer: View {
    /// 落地页出现以后过了多少秒
    let t: Double
    let size: CGSize
    let target: CGRect
    var reduceMotion = false

    /// 从这一刻起画面不再变（就是落点上的图标）：落地页可以据此判断开场放完了
    nonisolated static func settleTime(reduceMotion: Bool) -> Double {
        reduceMotion ? BrandCollapseTrack.reducedEnd : BrandCollapseTrack.end
    }

    var body: some View {
        // 每帧只在这里算一次姿态；落稳以后姿态不变，下面那层就不再重画（时间线还在为封面平面走）
        BrandCollapseCanvas(pose: BrandCollapsePose(t: t, size: size, target: target, reduceMotion: reduceMotion), size: size)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - 姿态

/// 某一刻要画成什么样（全是数值，落稳以后每帧都相等）
private struct BrandCollapsePose: Equatable {
    /// 品牌底板（屏幕坐标）
    var panel: CGRect = .zero
    var radius: CGFloat = 0
    /// 字标按「初始大小」排字的边长；markScale 只往小缩
    var markSide: CGFloat = 0
    var markScale: CGFloat = 1
    /// 底板 + 字标这一组的不透明度
    var morph: Double = 0
    /// 减弱动态效果：落点上的那一枚（同样的底板 + 字标）淡入，整屏那一组同时淡出
    var icon: CGRect = .zero
    var iconRadius: CGFloat = 0
    var iconOpacity: Double = 0

    init(t: Double, size: CGSize, target rawTarget: CGRect, reduceMotion: Bool) {
        // 第一次排版可能拿到 0 尺寸：什么都不画
        guard size.width > 1, size.height > 1 else { return }
        let K = BrandCollapseTrack.self
        let target = K.resolved(rawTarget, in: size)
        let r0 = target.width * K.iconRadius
        markSide = target.width * K.markStart
        icon = target
        iconRadius = r0

        if reduceMotion {
            // 不做形变：整屏品牌（字标在屏幕正中、初始大小）0.3 秒淡成落点上的图标
            let p = K.smooth((t - K.hold) / (K.reducedEnd - K.hold))
            guard p < 1 else { settle(target, r0); return }
            panel = CGRect(origin: .zero, size: size)
            radius = 0
            markScale = 1
            morph = 1 - p
            iconOpacity = p
            return
        }

        guard t < K.end else { settle(target, r0); return }
        let tt = max(0, t)
        let W = size.width, H = size.height
        let wp = K.width(tt), hp = K.height(tt)
        let w = K.map(wp, phoneFull: K.phoneW, full: W, target: target.width)
        let h = K.map(hp, phoneFull: K.phoneH, full: H, target: target.height)
        // 还剩多少「整屏 → 落点」没走完：中心从屏幕正中挪到落点用的就是它；下探（参考里比落点低 6%–7% 屏高）另外按屏高加上
        let aw = K.far(wp, phoneFull: K.phoneW)
        let ah = K.far(hp, phoneFull: K.phoneH)
        let cx = target.midX + (W / 2 - target.midX) * aw
        let dip = K.centerY(tt) - K.phoneIconY + (K.phoneIconY - 0.5) * ah
        let cy = target.midY + (H / 2 - target.midY) * ah + H * dip
        let r = min(r0 * K.radius(tt), w / 2, h / 2)

        panel = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        radius = r
        markScale = K.mark(tt) / K.markStart
        morph = 1
    }

    /// 落稳：收束出来的这一枚停在落点上（关键帧最后一帧就是这个样子，接得上，不跳）
    private mutating func settle(_ target: CGRect, _ r0: CGFloat) {
        panel = target
        radius = r0
        markScale = 1 / BrandCollapseTrack.markStart
        morph = 1
        iconOpacity = 0
    }
}

// MARK: - 关键帧

/// 参考录屏的读数（403 × 877 的手机屏，时间以落地页出现为起点；PDF 表里那几格原样对上，中间值逐帧量的）
private enum BrandCollapseTrack {
    static let phoneW: CGFloat = 403
    static let phoneH: CGFloat = 877
    /// 参考里落稳的图标约 85 × 85，中心在 54% 屏高
    static let phoneIcon: CGFloat = 85
    static let phoneIconY: CGFloat = 0.54
    /// 字标缩到初始约 56%（PDF）：初始大小 = 落点大小 ÷ 0.56
    static let markStart: CGFloat = 1 / 0.56
    /// iOS 图标的连续圆角约为边长的 22.37%
    static let iconRadius: CGFloat = 0.2237
    /// 首屏停留到这里（减弱动态效果时从这里开始淡）
    static let hold = 0.5
    static let end = 1.17
    static let reducedEnd = 0.8

    /// 底板宽（参考屏的点）：比高晚一点动；0.83 秒压到最窄 63，再回到 85
    static let width = BrandCollapseCurve([
        (0.50, 403), (0.533, 398), (0.567, 352), (0.60, 290), (0.63, 198), (0.67, 144), (0.70, 108), (0.73, 85),
        (0.767, 70), (0.80, 64), (0.83, 63), (0.867, 65), (0.90, 68.5), (0.95, 74.5), (1.0, 79.5), (1.05, 82.8),
        (1.10, 84.5), (1.17, 85),
    ])
    /// 底板高：先收（0.5 秒上下露黑）、0.83 秒压到最扁 38，回弹时略高过落点一点再落稳
    static let height = BrandCollapseCurve([
        (0.46, 877), (0.50, 805), (0.533, 745), (0.567, 660), (0.60, 530), (0.63, 336), (0.67, 217), (0.70, 147),
        (0.73, 86), (0.75, 68), (0.767, 56), (0.80, 42), (0.83, 38), (0.85, 39), (0.883, 46), (0.917, 56), (0.95, 64),
        (0.983, 72), (1.017, 78), (1.05, 82), (1.083, 84.6), (1.12, 85.8), (1.17, 85),
    ])
    /// 底板中心 Y（占屏高）：0.67 秒下探到 61%，反向上提，0.83 秒 55%，越过落点一丁点再落到 54%
    static let centerY = BrandCollapseCurve([
        (0.46, 0.50), (0.50, 0.513), (0.533, 0.524), (0.567, 0.538), (0.60, 0.56), (0.63, 0.60), (0.67, 0.61),
        (0.70, 0.602), (0.73, 0.59), (0.767, 0.576), (0.80, 0.56), (0.83, 0.55), (0.867, 0.5445), (0.90, 0.541),
        (0.95, 0.538), (1.0, 0.5385), (1.05, 0.5395), (1.12, 0.54),
    ])
    /// 圆角（落点圆角的倍数，另外不超过短边一半：压扁时就是胶囊）。整屏时是直角，大矩形时圆角偏小
    static let radius = BrandCollapseCurve([
        (0.46, 0), (0.533, 0.15), (0.60, 0.40), (0.63, 0.52), (0.67, 0.62), (0.70, 0.78), (0.73, 0.95), (0.77, 1),
    ])
    /// 字标大小（落点大小的倍数）：0.5 秒起缩，0.8–0.88 秒比落点小 5%，再回到 1
    static let mark = BrandCollapseCurve([
        (0.50, 1 / 0.56), (0.533, 1.77), (0.567, 1.65), (0.60, 1.47), (0.63, 1.28), (0.67, 1.12), (0.70, 1.035),
        (0.73, 0.985), (0.767, 0.96), (0.80, 0.952), (0.883, 0.952), (0.917, 0.972), (0.95, 0.99), (1.0, 1),
    ])

    /// 参考屏上的一个尺寸换算到这块屏：比落点大的按「整屏 → 落点」的比例，比落点小的按落点的倍数
    static func map(_ v: CGFloat, phoneFull: CGFloat, full: CGFloat, target: CGFloat) -> CGFloat {
        if v >= phoneIcon {
            return target + (v - phoneIcon) / (phoneFull - phoneIcon) * (full - target)
        }
        return target * v / phoneIcon
    }

    /// 「整屏 → 落点」还剩多少（1 是整屏，0 是到了落点或更小）
    static func far(_ v: CGFloat, phoneFull: CGFloat) -> CGFloat {
        min(1, max(0, (v - phoneIcon) / (phoneFull - phoneIcon)))
    }

    static func smooth(_ x: Double) -> Double {
        let u = min(1, max(0, x))
        return u * u * (3 - 2 * u)
    }

    /// 落地页还没给出落点（第一次排版）：按手机的规矩先放在 54% 屏高、宽 21% 屏宽（最多 120）
    static func resolved(_ target: CGRect, in size: CGSize) -> CGRect {
        if target.width >= 1, target.height >= 1 { return target }
        let side = min(120, size.width * 0.21)
        return CGRect(x: size.width / 2 - side / 2, y: size.height * phoneIconY - side / 2, width: side, height: side)
    }
}

/// 单调三次插值（Fritsch–Butland）：穿过每个关键帧，段内不过冲；首尾斜率为 0（从静止起步、落稳不抖）
private struct BrandCollapseCurve: Sendable {
    private let ts: [Double]
    private let vs: [Double]
    private let ms: [Double]

    init(_ keys: [(Double, Double)]) {
        let ts = keys.map { $0.0 }
        let vs = keys.map { $0.1 }
        let n = ts.count
        var ms = [Double](repeating: 0, count: n)
        if n > 2 {
            for i in 1..<(n - 1) {
                let h0 = ts[i] - ts[i - 1], h1 = ts[i + 1] - ts[i]
                let d0 = (vs[i] - vs[i - 1]) / h0
                let d1 = (vs[i + 1] - vs[i]) / h1
                // 拐点（下探最低点、压扁最扁处）斜率取 0，不会冲过关键帧
                guard d0 * d1 > 0 else { continue }
                let w1 = 2 * h1 + h0, w2 = h1 + 2 * h0
                ms[i] = (w1 + w2) / (w1 / d0 + w2 / d1)
            }
        }
        self.ts = ts
        self.vs = vs
        self.ms = ms
    }

    func callAsFunction(_ x: Double) -> CGFloat {
        guard let first = ts.first, let last = ts.last else { return 0 }
        if x <= first { return CGFloat(vs[0]) }
        if x >= last { return CGFloat(vs[vs.count - 1]) }
        var i = 0
        while i < ts.count - 2 && x > ts[i + 1] { i += 1 }
        let h = ts[i + 1] - ts[i]
        let s = (x - ts[i]) / h
        let s2 = s * s, s3 = s2 * s
        let a = (2 * s3 - 3 * s2 + 1) * vs[i] + (s3 - 2 * s2 + s) * h * ms[i]
        let b = (-2 * s3 + 3 * s2) * vs[i + 1] + (s3 - s2) * h * ms[i + 1]
        return CGFloat(a + b)
    }
}

// MARK: - 画面

private struct BrandCollapseCanvas: View {
    let pose: BrandCollapsePose
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            if pose.morph > 0.001 {
                // 底板和字标分两条轨：字标不裁进底板（压扁时两端会略出去）
                ZStack(alignment: .topLeading) {
                    BrandCollapsePanel(radius: pose.radius)
                        .frame(width: pose.panel.width, height: pose.panel.height)
                        .position(x: pose.panel.midX, y: pose.panel.midY)
                    BrandCollapseWordmark(side: pose.markSide)
                        .scaleEffect(pose.markScale)
                        .position(x: pose.panel.midX, y: pose.panel.midY)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .opacity(pose.morph)
            }
            if pose.iconOpacity > 0.001 {
                // 减弱动态效果淡入的那一枚：和收束落稳的样子一模一样（同一块底板、同一个字标、同样的缩放）
                ZStack(alignment: .topLeading) {
                    BrandCollapsePanel(radius: pose.iconRadius)
                        .frame(width: pose.icon.width, height: pose.icon.height)
                        .position(x: pose.icon.midX, y: pose.icon.midY)
                    BrandCollapseWordmark(side: pose.markSide)
                        .scaleEffect(1 / BrandCollapseTrack.markStart)
                        .position(x: pose.icon.midX, y: pose.icon.midY)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .opacity(pose.iconOpacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// 品牌底板：BrandIcon 的蓝（左上深蓝 #001DC0 往下变亮，右下角一团 #019BFE 的亮光），渐变跟着底板走（整屏时也是这张图的配色）
private struct BrandCollapsePanel: View {
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(BrandCollapseInk.base)
            .overlay { shape.fill(BrandCollapseInk.bloom) }
    }
}

/// 「Cuven max」白字标：和登录页的字标同一套写法（圆体，「Cuven」中等粗、「max」特粗而大、字距收紧），
/// 字号和两行的基线按 BrandIcon 图上量的比例摆（边长 side 的方块里）：落稳以后看上去就是 App 图标
private struct BrandCollapseWordmark: View {
    let side: CGFloat

    var body: some View {
        let k = side, s1 = side * 0.162, s2 = side * 0.305
        ZStack(alignment: .top) {
            Color.clear
                .frame(width: side, height: side)
            Text(verbatim: "Cuven")
                .font(.system(size: s1, weight: .medium, design: .rounded))
                .tracking(-0.01 * s1)
                .fixedSize()
                .alignmentGuide(.top) { d in d[VerticalAlignment.firstTextBaseline] - k * 0.443 }
            Text(verbatim: "max")
                .font(.system(size: s2, weight: .heavy, design: .rounded))
                .tracking(-0.045 * s2)
                .fixedSize()
                .alignmentGuide(.top) { d in d[VerticalAlignment.firstTextBaseline] - k * 0.652 }
        }
        .frame(width: side, height: side)
        .foregroundStyle(.white)
        // 图标上的字标压着一圈淡淡的暗影（和登录页字标的投影同色）
        .shadow(color: BrandCollapseInk.shade.opacity(0.3), radius: side * 0.04, y: side * 0.008)
    }
}

private enum BrandCollapseInk {
    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: alpha)
    }

    /// 底色：BrandIcon 上量的，往下比往右变得快（右下角超出的部分交给亮光）
    static var base: LinearGradient {
        LinearGradient(colors: [rgb(0x001DC0), rgb(0x0047FF)], startPoint: .topLeading, endPoint: UnitPoint(x: 0.36, y: 1.19))
    }

    /// 右下角的亮光：BrandIcon 上按离右下角的距离量的
    static var bloom: EllipticalGradient {
        let c = rgb(0x019BFE)
        return EllipticalGradient(stops: [.init(color: c, location: 0), .init(color: c.opacity(0.79), location: 0.15),
                                          .init(color: c.opacity(0.62), location: 0.30), .init(color: c.opacity(0.42), location: 0.45),
                                          .init(color: c.opacity(0.25), location: 0.60), .init(color: c.opacity(0.12), location: 0.78),
                                          .init(color: c.opacity(0), location: 1)],
                                  center: .bottomTrailing, startRadiusFraction: 0, endRadiusFraction: 1)
    }

    static var shade: Color { rgb(0x0A090F) }
}
