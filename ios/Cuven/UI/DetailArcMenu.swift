import SwiftUI
import UIKit

// MARK: - 详情页的弧形菜单（iPhone Duo「侧边一列」的形态）
//
// 用户要求「把详情页的返回按钮换成展开弧形菜单按钮（参考图 2）以解决重叠问题」：
// 系统把详情页的返回、下载、分享竖着放进侧边那一列，下载 / 分享那一组往下压到了底下的导航胶囊上。
// 现在这几种形态里这三颗都收起来，换成一颗 48 点的玻璃圆钮（「+」）：摆在返回钮原来的地方（状态栏中线上、状态栏和导航胶囊之间）；
// 点一下，三块弧形的玻璃从它左边展开成一道弧（参考图 2）：上「返回」、中「下载」、下「分享」，「+」转成「×」，后面的页面压暗一点；
// 再点一下或点空白处收起。三块和圆钮在同一个玻璃容器里，从圆钮那儿长出来、收回去；停下来是分开的三块圆头弧，整块弧带都点得到。
// 折起横拿那种矮的一列放不下：圆钮挪到页面左上角，弧往右下展开。别的 iPhone、iPad 照旧是系统右上角的那几颗。
// 系统返回钮藏起来以后边缘右滑返回会失灵：同一页里把它接回来（SwipeBackEnabler）。

struct DetailArcMenuLayer: View {
    let video: Video
    let title: String
    let runtime: Int?
    let tmdbID: Int?
    @Binding var alert: PrecacheAlert?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false
    @Namespace private var glass

    /// 圆钮多大、弧离圆心多远、多厚
    private static let button: CGFloat = 48
    private static let radius: CGFloat = 64
    private static let thickness: CGFloat = 46
    /// 三块各占多少度、中间隔多少度（看得见的弧长，含圆头）
    private static let span: Double = 56
    private static let gap: Double = 7
    /// 玻璃容器那一块多大：圆钮在正中，弧的最外沿（离圆心 radius + thickness / 2）外面再留一圈
    private static let box: CGFloat = (radius + thickness) * 2 + 40
    /// 展开：带一点回弹。收起用 DSMotion.snap：干脆利落、不弹
    private static let spring = Animation.bouncy(duration: 0.42, extraBounce: 0.08)

    /// 圆钮摆在哪、弧朝哪边展开（屏幕坐标的角度：0° 朝右，90° 朝下）
    private struct Spot {
        var center: CGPoint
        var toward: Double
    }

    var body: some View {
        GeometryReader { safe in
            let sf = safe.frame(in: .global)
            GeometryReader { full in
                let ff = full.frame(in: .global)
                let spot = place(in: full.size, lead: max(0, sf.minX - ff.minX), trail: max(0, ff.maxX - sf.maxX),
                                 top: max(0, sf.minY - ff.minY))
                ZStack(alignment: .topLeading) {
                    if open { scrim }
                    fan(toward: spot.toward)
                        .position(spot.center)
                }
                .frame(width: full.size.width, height: full.size.height, alignment: .topLeading)
            }
            .ignoresSafeArea()
        }
        .background { SwipeBackEnabler() }
    }

    private func place(in size: CGSize, lead: CGFloat, trail: CGFloat, top: CGFloat) -> Spot {
        let columnLeading = lead > trail && lead >= 44
        let rail = max(DuoRail.shared.fromTrailing ?? DuoNavLayer.statusAxis, DuoNavLayer.statusAxis)
        let cap = DuoNavLayer.capsule(columnHeight: size.height)
        // 侧边那一列里放得下（状态栏下面、胶囊上面留得出这一颗）：摆在返回钮原来的地方，
        // 弧往内容那一边展开：圆钮在后缘那一列里就往左（180°），在前缘那一列里往右（0°）
        if cap.top - 40 >= 236 {
            return Spot(center: CGPoint(x: columnLeading ? rail : size.width - rail, y: min(288, cap.top - 40)),
                        toward: columnLeading ? 0 : 180)
        }
        // 放不下（折起横拿那种矮的一列）：挪到页面左上角，往右下（45°）展开。三块一共占 182°，两头那两块会绕到圆钮的上面和左边：
        // 圆钮离上、左两边要留够这一截再加 10 点。以前离左 44、离上 48，「分享」那块出了屏幕左边 6 点、「返回」那块顶出屏幕上沿；
        // 那一列在前缘时还把前缘的安全区当成 0，圆钮正压在那一列顶上的状态栏上
        let inset = (Self.cornerReach + 10).rounded()
        return Spot(center: CGPoint(x: lead + inset, y: top + inset), toward: 45)
    }

    /// 往右下 45° 展开时，两头那两块最靠上 / 最靠左的地方离圆心多远：那一头圆头的圆心，再加半个厚度（约 50 点）
    private static var cornerReach: CGFloat {
        let capDeg = Double(thickness / 2 / radius) * 180 / .pi
        let core = max(1, span - capDeg * 2)
        let edge = (span + gap - 45 + core / 2) * .pi / 180
        return radius * CGFloat(sin(edge)) + thickness / 2
    }

    private func toggle() {
        Haptics.light()
        setOpen(!open)
    }

    /// 展开带一点回弹，收起干脆利落；「减弱动态效果」打开时都是一小段淡入淡出（以前是直接跳出来）
    private func setOpen(_ on: Bool) {
        withAnimation(DSMotion.adapt(on ? Self.spring : DSMotion.snap, reduce: reduceMotion)) { open = on }
    }

    /// 后面压暗一点，点空白处收起
    private var scrim: some View {
        Color.black.opacity(0.28)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// 圆钮和三块弧：同一个玻璃容器（弧从圆钮那儿长出来、收回去），只占圆钮周围这一块，不铺满整页。
    /// 容器的间距比两块弧之间的缝（约 6 点）小：停下来是分开的三块圆头弧，不化成连着的一整条（以前 18，比缝宽，三块会粘在一起）
    private func fan(toward: Double) -> some View {
        GlassEffectContainer(spacing: 6) {
            ZStack {
                if open {
                    ForEach(0..<3, id: \.self) { i in
                        segment(i, toward: toward)
                    }
                }
                mainButton
            }
            .frame(width: Self.box, height: Self.box)
        }
    }

    /// 中间那颗：「+」，展开时转 45° 成「×」
    private var mainButton: some View {
        Button { toggle() } label: {
            ArcPlusGlyph()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(open ? 45 : 0))
                .frame(width: Self.button, height: Self.button)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .glassEffect(.regular.interactive(), in: Circle())
        .glassEffectID("arc-main", in: glass)
        .accessibilityLabel(open ? "收起菜单" : "更多操作")
        .accessibilityHint(open ? "" : "返回、下载、分享")
        .accessibilityIdentifier("detail-arc-menu")
    }

    /// 第 i 块（上、中、下）：一段圆头的弧形玻璃，整块就是这一项的按钮（图标在弧带的中线上、这一块的正中）。
    /// 玻璃贴在按钮自己身上：按在弧带的哪儿，玻璃的回弹和这一项的动作都是同一下
    private func segment(_ i: Int, toward: Double) -> some View {
        // 中间那块正对着展开的方向，上下两块各偏一个（跨度 + 间隔）。屏幕坐标 y 往下：往右展开时「上」是角度减，往左展开时是角度加
        let offset = Double(i - 1) * (Self.span + Self.gap)
        let mid = toward > 90 && toward < 270 ? toward - offset : toward + offset
        let slot = ArcSlot(band: ArcBand(midDegrees: mid, spanDegrees: Self.span, radius: Self.radius, thickness: Self.thickness))
        return item(i, slot: slot)
            .glassEffect(.regular.interactive(), in: slot)
            .glassEffectID("arc-\(i)", in: glass)
            .position(x: Self.box / 2 + slot.middle.x, y: Self.box / 2 + slot.middle.y)
            .transition(grow(i))
    }

    /// 从圆钮那儿长出来，一块接一块（各晚 35 毫秒）；收起时倒过来，「分享」先走、「返回」最后。
    /// 「减弱动态效果」打开时只淡入淡出：不缩放、不错开（以前照样从 55% 放大）
    private func grow(_ i: Int) -> AnyTransition {
        if reduceMotion { return AnyTransition.opacity.animation(.easeInOut(duration: 0.2)) }
        // 这一块铺满容器那一块（position），缩放的中心就是圆钮
        let pop = AnyTransition.opacity.combined(with: .scale(scale: 0.55, anchor: .center))
        return AnyTransition.asymmetric(
            insertion: pop.animation(Self.spring.delay(0.035 * Double(i))),
            removal: pop.animation(DSMotion.snap.delay(0.03 * Double(2 - i))))
    }

    @ViewBuilder
    private func item(_ i: Int, slot: ArcSlot) -> some View {
        switch i {
        case 0:
            Button {
                Haptics.light()
                // 菜单跟着这一页一起收：返回的转场里不拖着一层压暗和三块弧
                setOpen(false)
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .detailHit(slot)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("返回")
            .accessibilityIdentifier("detail-arc-back")
        case 1:
            DetailDownloadButton(video: video, title: title, runtime: runtime, alert: $alert, slot: slot)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .tint(.white)
        default:
            DetailShareButton(video: video, title: title, tmdbID: tmdbID, slot: slot)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .tint(.white)
        }
    }
}

/// 一段圆头的弧带：圆心在框的中心，半径 radius（弧带的中线），厚 thickness；看得见的弧长（含两头的圆头）是 spanDegrees，
/// 中线对着 midDegrees（屏幕坐标：0° 朝右，90° 朝下）
struct ArcBand: Shape {
    var midDegrees: Double
    var spanDegrees: Double
    var radius: CGFloat
    var thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // 圆头往两头各伸出 thickness / 2：扣掉这一截角度，看上去整块正好 spanDegrees
        let capDeg = Double(thickness / 2 / radius) * 180 / .pi
        let core = max(1, spanDegrees - capDeg * 2)
        var arc = Path()
        arc.addArc(center: c, radius: radius,
                   startAngle: .degrees(midDegrees - core / 2), endAngle: .degrees(midDegrees + core / 2), clockwise: false)
        return arc.strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round))
    }
}

/// 一块弧带和它自己的小框。小框是弧带的外接矩形：按钮就这么大（「下载」的菜单从这儿弹出来），
/// 点得到的范围和玻璃的形状都是弧带本身。以前按钮只有正中 46 点见方，弧带两头按下去玻璃有反应、却什么都不做
struct ArcSlot: Shape {
    let band: ArcBand
    /// 弧带的外接矩形（原点是弧的圆心）
    let bounds: CGRect

    init(band: ArcBand) {
        self.band = band
        let side = (band.radius + band.thickness) * 2
        let whole = band.path(in: CGRect(x: 0, y: 0, width: side, height: side))
        bounds = whole.boundingRect.offsetBy(dx: -side / 2, dy: -side / 2)
    }

    /// 小框多大
    var frameSize: CGSize { bounds.size }
    /// 小框的中心离圆心多远
    var middle: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    /// 图标离小框的中心多远：正落在弧带的中线上、这一块的正中（弧带是弯的，外接矩形的中心差一点点）
    var glyph: CGSize {
        let a = band.midDegrees * .pi / 180
        return CGSize(width: band.radius * CGFloat(cos(a)) - bounds.midX, height: band.radius * CGFloat(sin(a)) - bounds.midY)
    }

    func path(in rect: CGRect) -> Path {
        // 圆心在小框外面：按它相对小框的位置放回去，弧带正好落进小框
        let side = (band.radius + band.thickness) * 2
        return band.path(in: CGRect(x: rect.minX - bounds.minX - side / 2, y: rect.minY - bounds.minY - side / 2,
                                    width: side, height: side))
    }
}

/// 「+」：两笔
struct ArcPlusGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

/// 系统返回钮藏起来以后，边缘右滑返回会跟着失灵：所在的导航栈里把它接回来（栈里不止一页才让它开始）
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ vc: Probe, context: Context) {}

    final class Probe: UIViewController, UIGestureRecognizerDelegate {
        /// 系统原来的那个：离开这一页就还回去（不然回到根页面再右滑会卡住）
        private weak var original: UIGestureRecognizerDelegate?

        override func loadView() {
            let v = UIView()
            v.isUserInteractionEnabled = false
            v.accessibilityElementsHidden = true
            view = v
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let nav = navigationController, let pop = nav.interactivePopGestureRecognizer else { return }
            if pop.delegate !== self { original = pop.delegate }
            pop.isEnabled = true
            pop.delegate = self
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if let pop = navigationController?.interactivePopGestureRecognizer, pop.delegate === self {
                pop.delegate = original
            }
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
