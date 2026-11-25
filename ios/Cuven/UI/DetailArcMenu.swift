import SwiftUI
import UIKit

// MARK: - 详情页的弧形菜单（iPhone Duo「侧边一列」的形态）
//
// 用户要求「把详情页的返回按钮换成展开弧形菜单按钮（参考图 2）以解决重叠问题」：
// 系统把详情页的返回、下载、分享竖着放进侧边那一列，下载 / 分享那一组往下压到了底下的导航胶囊上。
// 现在这几种形态里这三颗都收起来，换成一颗 48 点的玻璃圆钮（「+」）。用户后来要求「更新展开按钮位置并替换更多按钮」：
// 「+」摆在「播放」那一行里「…」原来那一格（跟着页面滚，滚到顶上那一截就藏起来），「…」里的「从头播放」挪到弧上最后一项；
// 点一下，三颗圆形的玻璃从它左边沿一道弧展开（参考图 2）：上「返回」、中「下载」、下「分享」，「+」转成「×」，后面的页面压暗一点；
// 再点一下或点空白处收起。三颗从上到下一颗接一颗地从圆钮那儿长出来，收起也是从上到下一颗接一颗；
// 三颗各是各的正圆玻璃（用户要求：不互相粘连、改成圆形○），整颗都点得到。
// 折起横拿那种矮的一列放不下：圆钮挪到页面左上角，弧往右下展开。别的 iPhone、iPad 照旧是系统右上角的那几颗。
// 系统返回钮藏起来以后边缘右滑返回会失灵：同一页里把它接回来（SwipeBackEnabler）。

/// 详情页那一行操作里「…」原来的位置（用户要求「更新展开按钮位置并替换更多按钮」：「+」挪到这里）：
/// 那一格每次排版、每次跟着页面滚动都把自己在屏幕上的框记在这里。单独一个可观察的小对象：
/// 滚动时只有弧形菜单那一层跟着重画，整页的 body 不跟着每帧重算
@MainActor @Observable
final class DetailArcAnchor {
    var rect: CGRect = .zero
}

struct DetailArcMenuLayer: View {
    let video: Video
    let title: String
    let runtime: Int?
    let tmdbID: Int?
    @Binding var alert: PrecacheAlert?
    /// 「+」摆在哪（详情页那一行里「…」原来那一格）；还没量到就按以前的摆法放进侧边那一列
    let anchor: DetailArcAnchor
    /// 「从头播放」（有进度才有）：以前在「…」菜单里，「…」被「+」顶替以后作为弧上最后一项
    var onRestart: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false
    /// 弧上各项出来了没有（从上到下）：展开、收起都是从上到下一项接一项
    @State private var shown = [false, false, false, false]
    /// 一块接一块的节拍：中途再点一下就停掉它，从眼下的样子接着走
    @State private var stepper: Task<Void, Never>?

    /// 圆钮多大（中间的「+」和弧上的「返回」「分享」一样大）、三项离「+」的圆心多远、相邻两项隔多少度。
    /// 用户要求（真机截图）：「返回」「分享」的玻璃改成正圆，「下载」保留原来那段圆头的弧带（厚 42、看得见的弧长 50°）。
    /// 都摆在同一道弧上，位置照旧——离圆心 62、隔 62°，相邻两项之间、和「+」之间都空出约 14 点
    private static let button: CGFloat = 48
    private static let radius: CGFloat = 62
    private static let step: Double = 62
    private static let thickness: CGFloat = 42
    private static let span: Double = 50
    /// 弧上的圆最外沿离圆心多远（两头那两颗绕到「+」的正上方、正下方附近）
    private static let reach: CGFloat = radius + button / 2
    /// 三块的玻璃压暗一点：亮的海报上白色图标也看得清（真机截图：返回、下载几乎看不见）
    private static let glassInk = Glass.regular.tint(Color.black.opacity(0.32)).interactive()
    /// 圆钮周围那一块多大：「+」在正中，三颗（最外沿离圆心 reach）都落在里面，外面再留一圈
    private static let box: CGFloat = reach * 2 + 40
    /// 展开：带一点回弹。收起用 DSMotion.snap：干脆利落、不弹
    private static let spring = Animation.bouncy(duration: 0.42, extraBounce: 0.08)

    /// 圆钮摆在哪、弧朝哪边展开（屏幕坐标的角度：0° 朝右，90° 朝下）
    private struct Spot {
        var center: CGPoint
        var toward: Double
    }

    /// 弧上一共几项：返回、下载、分享，有进度时再加「从头播放」
    private var count: Int { onRestart == nil ? 3 : 4 }

    var body: some View {
        GeometryReader { safe in
            let sf = safe.frame(in: .global)
            GeometryReader { full in
                let ff = full.frame(in: .global)
                let a = anchor.rect
                // 「+」在「…」原来那一格：跟着页面滚；滚到顶上那一截（钉住的条、状态栏）或者滚出屏幕底就藏起来
                let anchored = a.width > 0
                let center = anchored
                    ? CGPoint(x: a.midX - ff.minX, y: a.midY - ff.minY)
                    : place(in: full.size, lead: max(0, sf.minX - ff.minX), trail: max(0, ff.maxX - sf.maxX),
                            top: max(0, sf.minY - ff.minY)).center
                let toward = anchored ? 180 : place(in: full.size, lead: max(0, sf.minX - ff.minX),
                                                    trail: max(0, ff.maxX - sf.maxX), top: max(0, sf.minY - ff.minY)).toward
                // 还没量到那一格（第一帧）也先藏着：不先在侧边那一列里闪一下再跳过去
                let visible = anchored && center.y > max(sf.minY - ff.minY, 0) + 96 && center.y < full.size.height - 24
                ZStack(alignment: .topLeading) {
                    if open { scrim }
                    fan(toward: toward)
                        .position(center)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                        .animation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion), value: visible)
                }
                .frame(width: full.size.width, height: full.size.height, alignment: .topLeading)
                // 开着的时候滚走了：收起来（压暗还盖着整页，弧却跟着「+」不见了）
                .onChange(of: visible) { _, v in if !v && open { setOpen(false) } }
            }
            .ignoresSafeArea()
        }
        .background { SwipeBackEnabler() }
    }

    private func place(in size: CGSize, lead: CGFloat, trail: CGFloat, top: CGFloat) -> Spot {
        let columnLeading = lead > trail && lead >= 44
        let rail = max(DuoRail.shared.fromTrailing ?? DuoNavLayer.statusAxis, DuoNavLayer.statusAxis)
        let cap = DuoNavLayer.capsule(columnHeight: size.height)
        // 侧边那一列里放得下：摆在返回钮原来的地方，弧往内容那一边展开（圆钮在后缘那一列里就往左 180°，在前缘那一列里往右 0°）。
        // 最下面那块的圆头会绕到圆钮正下方：圆钮离胶囊顶至少留 reach + 9 点，展开了也碰不到导航胶囊；
        // 最上面那块同样绕到正上方：圆钮不高过 250，弧顶不压到状态栏
        let y = min(288, cap.top - Self.reach - 9)
        if y >= 250 {
            return Spot(center: CGPoint(x: columnLeading ? rail : size.width - rail, y: y),
                        toward: columnLeading ? 0 : 180)
        }
        // 放不下（折起横拿那种矮的一列）：挪到页面左上角，往右下（45°）展开。两头那两颗会绕到圆钮的上面和左边：
        // 圆钮离上、左两边要留够这一截再加 10 点。以前离左 44、离上 48，「分享」那块出了屏幕左边 6 点、「返回」那块顶出屏幕上沿；
        // 那一列在前缘时还把前缘的安全区当成 0，圆钮正压在那一列顶上的状态栏上
        let inset = (Self.cornerReach + 10).rounded()
        return Spot(center: CGPoint(x: lead + inset, y: top + inset), toward: 45)
    }

    /// 往右下 45° 展开时，两头那两颗最靠上 / 最靠左的地方离圆心多远：那一颗的圆心，再加半个圆（约 42 点）
    private static var cornerReach: CGFloat {
        radius * CGFloat(sin((step - 45) * .pi / 180)) + button / 2
    }

    private func toggle() {
        Haptics.light()
        setOpen(!open)
    }

    /// 展开带一点回弹，收起干脆利落。「+」和后面的压暗马上跟手；三块弧从上到下一块接一块，展开、收起都是这个顺序
    /// （用户要求）。每一块是各自的一次状态变化，玻璃和图标同一拍；以前三块同一下插进去，只靠过渡上各晚 35 毫秒去错开。
    /// 「减弱动态效果」打开时三块一起、一小段淡入淡出（以前是直接跳出来）
    private func setOpen(_ on: Bool) {
        stepper?.cancel()
        let curve = DSMotion.adapt(on ? Self.spring : DSMotion.snap, reduce: reduceMotion)
        if reduceMotion {
            withAnimation(curve) {
                open = on
                shown = [on, on, on, on]
            }
            return
        }
        // 最上面那块和「+」同一下动，后两块各隔一拍
        withAnimation(curve) {
            open = on
            shown[0] = on
        }
        let beat = on ? 110 : 80
        stepper = Task { @MainActor in
            for i in 1..<count {
                try? await Task.sleep(for: .milliseconds(beat))
                if Task.isCancelled { return }
                withAnimation(curve) { shown[i] = on }
            }
        }
    }

    /// 后面压暗一点，点空白处收起
    private var scrim: some View {
        Color.black.opacity(0.28)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// 圆钮和三块弧：只占圆钮周围这一块，不铺满整页。四块各是各的玻璃——
    /// 以前放在同一个玻璃容器里（间距 18，比两块弧之间的缝还宽）、再用 glassEffectID 互相形变，
    /// 三块的玻璃会粘成连着的一整条（用户要求：三块不能粘连）
    private func fan(toward: Double) -> some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                if shown[i] {
                    segment(i, toward: toward)
                        // 正在收起的那几项不再接点按
                        .allowsHitTesting(open)
                        .transition(grow)
                }
            }
            mainButton
        }
        .frame(width: Self.box, height: Self.box)
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
        .glassEffect(Self.glassInk, in: Circle())
        .accessibilityLabel(open ? "收起菜单" : "更多操作")
        .accessibilityHint(open ? "" : "返回、下载、分享")
        .accessibilityIdentifier("detail-arc-menu")
    }

    /// 第 i 项（上、中、下）：「返回」「分享」是一颗 48 点的正圆玻璃，「下载」是一段圆头的弧带玻璃（用户要求保留原来的样子）。
    /// 整块玻璃就是这一项的按钮；玻璃贴在按钮自己身上：按在哪儿，玻璃的回弹和这一项的动作都是同一下
    @ViewBuilder
    private func segment(_ i: Int, toward: Double) -> some View {
        // 中间那项正对着展开的方向，上下两项各偏一个 step。屏幕坐标 y 往下：往右展开时「上」是角度减，往左展开时是角度加
        // 几项一起以展开的方向为中线左右对开（三项时中间那项正对着；四项时中线落在第二、三项之间）
        let offset = (Double(i) - Double(count - 1) / 2) * Self.step
        let deg = toward > 90 && toward < 270 ? toward - offset : toward + offset
        if i == 1 {
            let slot = ArcSlot(band: ArcBand(midDegrees: deg, spanDegrees: Self.span, radius: Self.radius, thickness: Self.thickness))
            item(i, slot: slot)
                .glassEffect(Self.glassInk, in: slot)
                .position(x: Self.box / 2 + slot.middle.x, y: Self.box / 2 + slot.middle.y)
        } else {
            let mid = deg * .pi / 180
            item(i, slot: nil)
                .glassEffect(Self.glassInk, in: Circle())
                .position(x: Self.box / 2 + Self.radius * CGFloat(cos(mid)), y: Self.box / 2 + Self.radius * CGFloat(sin(mid)))
        }
    }

    /// 从圆钮那儿长出来、收回去：这一块铺满圆钮周围那一块（position），缩放的中心就是圆钮。
    /// 从 64% 起：最小的时候里沿也在圆钮外面，玻璃不压到圆钮的玻璃上。
    /// 「减弱动态效果」打开时只淡入淡出、不缩放（以前照样从 55% 放大）
    private var grow: AnyTransition {
        reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.64, anchor: .center))
    }

    @ViewBuilder
    private func item(_ i: Int, slot: ArcSlot?) -> some View {
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
                    .detailHit(Self.button)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("返回")
            .accessibilityIdentifier("detail-arc-back")
        case 1:
            DetailDownloadButton(video: video, title: title, runtime: runtime, alert: $alert, slot: slot)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .tint(.white)
        case 3:
            Button {
                Haptics.light()
                setOpen(false)
                onRestart?()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .detailHit(Self.button)
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("从头播放")
            .accessibilityIdentifier("detail-restart")
        default:
            DetailShareButton(video: video, title: title, tmdbID: tmdbID, hit: Self.button)
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
