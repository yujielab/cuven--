import SwiftUI
import UIKit

// MARK: - 详情页的弧形菜单（iPhone Duo「侧边一列」的形态）
//
// 用户要求「把详情页的返回按钮换成展开弧形菜单按钮（参考图 2）以解决重叠问题」：
// 系统把详情页的返回、下载、分享竖着放进侧边那一列，下载 / 分享那一组往下压到了底下的导航胶囊上。
// 现在这几种形态里这三颗都收起来，换成一颗 48 点的玻璃圆钮（「+」）：摆在返回钮原来的地方（状态栏中线上、状态栏和导航胶囊之间）；
// 点一下，三块弧形的玻璃从它左边展开成一道弧（参考图 2）：上「返回」、中「下载」、下「分享」，「+」转成「×」，后面的页面压暗一点；
// 再点一下或点空白处收起。三块是同一个玻璃容器里的，从圆钮里长出来、收回去（glassEffectID）。
// 折起横拿那种矮的一列放不下：圆钮挪到页面左上角，弧往右展开。别的 iPhone、iPad 照旧是系统右上角的那几颗。
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

    var body: some View {
        GeometryReader { safe in
            let sf = safe.frame(in: .global)
            GeometryReader { full in
                let ff = full.frame(in: .global)
                let lead = max(0, sf.minX - ff.minX)
                let trail = max(0, ff.maxX - sf.maxX)
                let columnLeading = lead > trail && lead >= 44
                let rail = max(DuoRail.shared.fromTrailing ?? DuoNavLayer.statusAxis, DuoNavLayer.statusAxis)
                let cap = DuoNavLayer.capsule(columnHeight: full.size.height)
                // 侧边那一列里放得下（状态栏下面、胶囊上面留得出这一颗）：摆在返回钮原来的地方；放不下就挪到页面左上角
                let inColumn = cap.top - 40 >= 236
                let center: CGPoint = inColumn
                    ? CGPoint(x: columnLeading ? rail : full.size.width - rail, y: min(288, cap.top - 40))
                    : CGPoint(x: (columnLeading ? 0 : lead) + 20 + Self.button / 2, y: max(sf.minY - ff.minY, 12) + 12 + Self.button / 2)
                // 弧往内容那一边展开：圆钮在后缘那一列里就往左（180°），在前缘那一列里往右（0°）；挪到左上角时往右下（45°），不出屏幕
                let toward: Double = inColumn ? (columnLeading ? 0 : 180) : 45
                ZStack(alignment: .topLeading) {
                    if open {
                        // 后面压暗一点，点空白处收起
                        Color.black.opacity(0.28)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle() }
                            .transition(.opacity)
                            .accessibilityHidden(true)
                    }
                    GlassEffectContainer(spacing: 18) {
                        ZStack(alignment: .topLeading) {
                            if open {
                                ForEach(0..<3, id: \.self) { i in
                                    segment(i, center: center, toward: toward, size: full.size)
                                }
                            }
                            mainButton
                                .position(center)
                        }
                        .frame(width: full.size.width, height: full.size.height, alignment: .topLeading)
                    }
                }
                .frame(width: full.size.width, height: full.size.height, alignment: .topLeading)
            }
            .ignoresSafeArea()
        }
        .background { SwipeBackEnabler() }
    }

    private func toggle() {
        Haptics.light()
        if reduceMotion {
            open.toggle()
        } else {
            withAnimation(.bouncy(duration: 0.42, extraBounce: 0.08)) { open.toggle() }
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

    /// 第 i 块（上、中、下）：一段圆头的弧形玻璃，中间放这一项的按钮
    @ViewBuilder
    private func segment(_ i: Int, center: CGPoint, toward: Double, size: CGSize) -> some View {
        // 中间那块正对着展开的方向，上下两块各偏一个（跨度 + 间隔）。屏幕坐标 y 往下：往右展开时「上」是角度减，往左展开时是角度加
        let offset = Double(i - 1) * (Self.span + Self.gap)
        let mid = toward > 90 && toward < 270 ? -offset : offset
        let angle = (toward + mid) * .pi / 180
        let r = Self.radius
        let box = (r + Self.thickness) * 2
        let p = CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
        ZStack {
            ArcBand(midDegrees: toward + mid, spanDegrees: Self.span, radius: r, thickness: Self.thickness)
                .fill(Color.clear)
                .glassEffect(.regular.interactive(), in: ArcBand(midDegrees: toward + mid, spanDegrees: Self.span, radius: r, thickness: Self.thickness))
                .glassEffectID("arc-\(i)", in: glass)
                .frame(width: box, height: box)
                .position(center)
            item(i)
                .position(p)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 从圆钮那儿长出来，一块接一块（各晚 35 毫秒）
        .transition(
            AnyTransition.opacity
                .combined(with: .scale(scale: 0.55, anchor: UnitPoint(x: center.x / max(1, size.width), y: center.y / max(1, size.height))))
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .bouncy(duration: 0.42, extraBounce: 0.08).delay(0.035 * Double(i)))
        )
    }

    @ViewBuilder
    private func item(_ i: Int) -> some View {
        switch i {
        case 0:
            Button {
                Haptics.light()
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("返回")
            .accessibilityIdentifier("detail-arc-back")
        case 1:
            DetailDownloadButton(video: video, title: title, runtime: runtime, alert: $alert, hit: 46)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .tint(.white)
        default:
            DetailShareButton(video: video, title: title, tmdbID: tmdbID, hit: 46)
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
