import SwiftUI
import UIKit

// MARK: - 详情页的「+」：点开形变成一条选择滑块（iPhone Duo「侧边一列」的形态）
//
// 来历：系统把详情页的返回、下载、分享竖着放进侧边那一列，压到了底下的导航胶囊上（用户截图），于是收成一颗「+」；
// 后来「+」挪进「播放」那一行、顶替「…」（用户要求），「分享」移除。
// 现在（用户要求「更新这个按钮的设计和动效，参考图 2：点击无缝形变展开，然后滑动或轻触选择功能」）：
//   · 收着：48 点的玻璃圆钮，白色「+」
//   · 点一下：同一块玻璃往左拉长成一条胶囊（高 60），染成白色磨砂；里面一条青绿色的轨道，几个淡色的点是各档位，
//     白色的滑块头就是刚才那颗「+」——它停在最右边「收起」那一档、没挪地方，所以看上去是「+」变成了滑块，没有跳一下；
//     胶囊上方一行大字写着滑块现在在哪一档（参考图的「高」）
//   · 档位（从左到右）：返回、下载（状态跟着变：下载 / 下载中 42% / 已暂停 / 已下载）、有进度时「从头播放」、收起
//   · 按住滑块往左拖，经过一档轻震一下、上面的字跟着换；松手停在哪一档就做哪一件事。也可以直接点某一档：滑块滑过去再做
//   · 后面的页面轻微模糊（用户要求，像 Vision Pro 的景深：详情页那一层做；后来要求不往后退、不压暗）；点空白处收起
// 下载在下载中 / 已下载时，选它弹出系统的选项（暂停 / 继续 / 取消 / 删除下载），和别的 iPhone 右上角那颗菜单一样。
// 旁白：收着时这颗钮上直接有「返回」「下载」「从头播放」几个动作，不必展开。
// 系统返回钮藏起来以后边缘右滑返回会失灵：同一页里把它接回来（SwipeBackEnabler）。

/// 详情页那一行操作里「…」原来的位置（「+」摆在这里）：那一格每次排版、每次跟着页面滚动都把自己在屏幕上的框记在这里。
/// 单独一个可观察的小对象：滚动时只有这一层跟着重画，整页的 body 不跟着每帧重算
@MainActor @Observable
final class DetailArcAnchor {
    var rect: CGRect = .zero
    /// 展开着（和刚收起那一会儿）：后面的页面往后退（缩一点），那一格的框跟着变，「+」不能跟着挪——这时不再更新 rect
    @ObservationIgnored var frozen = false
}

struct DetailArcMenuLayer: View {
    let video: Video
    let title: String
    let runtime: Int?
    let tmdbID: Int?
    @Binding var alert: PrecacheAlert?
    /// 开没开：详情页那一层也要知道（开着时后面的页面轻微模糊、往后退）
    @Binding var open: Bool
    /// 「+」摆在哪（详情页那一行里「…」原来那一格）
    let anchor: DetailArcAnchor
    /// 「从头播放」（有进度才有）
    var onRestart: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 滑块停在哪一档（下标）；收着时是最后一档「收起」
    @State private var selected = 0
    /// 手指拖着的时候滑块头在哪（胶囊里的 x）；没在拖是 nil（停在 selected 那一档）
    @State private var dragX: CGFloat?
    /// 下载中 / 已下载时选「下载」：弹系统的选项
    @State private var downloadOptions = false
    @State private var releaser: Task<Void, Never>?

    /// 收着的圆钮多大；展开的胶囊多高；轨道离胶囊边多远；滑块头离轨道边多远；相邻两档隔多远（最多）
    private static let button: CGFloat = 48
    private static let barHeight: CGFloat = 60
    private static let trackInset: CGFloat = 7
    private static let knobInset: CGFloat = 4
    private static let maxStep: CGFloat = 66
    private static var knob: CGFloat { barHeight - 2 * trackInset - 2 * knobInset }
    /// 滑块头的圆心离胶囊左右两端多远（第一档、最后一档）
    private static var endInset: CGFloat { trackInset + knobInset + knob / 2 }
    /// 收着的玻璃深一点（白色「+」看得清）；展开是白色磨砂（参考图）
    private static let darkGlass = Glass.regular.tint(Color.black.opacity(0.32)).interactive()
    /// 轨道的青绿（参考图）
    private static let track = Color(red: 0.33, green: 0.72, blue: 0.63)

    private struct Stop: Equatable {
        let id: String
        let title: String
        let symbol: String
    }

    private var stops: [Stop] {
        var s = [Stop(id: "back", title: "返回", symbol: "chevron.backward"), downloadStop]
        if onRestart != nil { s.append(Stop(id: "restart", title: "从头播放", symbol: "arrow.counterclockwise")) }
        s.append(Stop(id: "close", title: "收起", symbol: "xmark"))
        return s
    }

    /// 「下载」那一档：字和符号跟着下载状态变
    private var downloadStop: Stop {
        guard let it = Precache.shared.item(path: video.path), it.isFull else {
            return Stop(id: "download", title: "下载", symbol: "arrow.down")
        }
        switch it.phase {
        case .done: return Stop(id: "download", title: "已下载", symbol: "checkmark")
        case .downloading, .queued, .preparing:
            return Stop(id: "download", title: "下载中 \(Int((it.progress * 100).rounded()))%", symbol: "pause")
        case .paused, .failed, .noSpace: return Stop(id: "download", title: "已暂停", symbol: "arrow.clockwise")
        }
    }

    var body: some View {
        GeometryReader { full in
            let ff = full.frame(in: .global)
            let a = anchor.rect
            let anchored = a.width > 0
            let center = CGPoint(x: a.midX - ff.minX, y: a.midY - ff.minY)
            // 「+」在「…」原来那一格：跟着页面滚；滚到顶上那一截（钉住的条、状态栏）或者滚出屏幕底就藏起来。
            // 还没量到那一格（第一帧）也先藏着
            let visible = anchored && center.y > 96 && center.y < full.size.height - 24
            let n = stops.count
            // 胶囊多宽：每档最多隔 66，左边不超出页面边距（留 16）
            let room = max(Self.button, center.x + Self.endInset - 16)
            let step = min(Self.maxStep, max(36, (room - 2 * Self.endInset) / CGFloat(max(1, n - 1))))
            let width = 2 * Self.endInset + step * CGFloat(n - 1)
            ZStack(alignment: .topLeading) {
                if open { scrim }
                if open {
                    label
                        .position(x: center.x + Self.endInset - width / 2, y: center.y - Self.barHeight / 2 - 26)
                        .transition(.opacity)
                }
                control(width: width, step: step, count: n)
                    .frame(width: open ? width : Self.button, height: open ? Self.barHeight : Self.button)
                    // 右端的滑块头正好落在「+」原来的圆心上：胶囊往左长出来
                    .position(x: open ? center.x + Self.endInset - width / 2 : center.x, y: center.y)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .animation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion), value: visible)
            }
            .frame(width: full.size.width, height: full.size.height, alignment: .topLeading)
            // 开着的时候滚走了：收起来
            .onChange(of: visible) { _, v in if !v && open { setOpen(false) } }
        }
        .ignoresSafeArea()
        .background { SwipeBackEnabler() }
        .confirmationDialog(downloadStop.title, isPresented: $downloadOptions, titleVisibility: .visible) {
            downloadOptionButtons
        }
    }

    /// 胶囊上方的大字：滑块现在在哪一档（参考图的「高」）
    private var label: some View {
        let i = currentIndex
        return Text(stops.indices.contains(i) ? stops[i].title : "")
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .contentTransition(.opacity)
            .animation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion), value: i)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 手指在哪一档上（拖着时按位置算，没拖时是 selected）
    private var currentIndex: Int {
        guard let x = dragX else { return selected }
        let n = stops.count
        let step = n > 1 ? (lastStopX(n) - Self.endInset) / CGFloat(n - 1) : 1
        return min(n - 1, max(0, Int(((x - Self.endInset) / max(1, step)).rounded())))
    }

    @State private var barWidth: CGFloat = 0
    private func lastStopX(_ n: Int) -> CGFloat { max(Self.endInset, barWidth - Self.endInset) }

    /// 同一块玻璃：收着是圆钮（深色玻璃 + 白色「+」），展开拉长成胶囊（白色磨砂 + 轨道 + 档位 + 滑块头）
    @ViewBuilder
    private func control(width: CGFloat, step: CGFloat, count n: Int) -> some View {
        ZStack {
            if open {
                // 靠右排、裁在胶囊里：玻璃往左长的时候里面的东西跟着露出来，右端的滑块头一直在「+」原来的地方
                expanded(width: width, step: step, count: n)
                    .transition(.opacity)
            } else {
                ArcPlusGlyph()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 18, height: 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .glassEffect(open ? DSGlass.whiteFrost.interactive() : Self.darkGlass, in: Capsule())
        .onTapGesture { if !open { toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(open ? "选择操作" : "更多操作")
        .accessibilityValue(open && stops.indices.contains(selected) ? stops[selected].title : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if open { perform(selected) } else { toggle() }
        }
        .accessibilityAdjustableAction { dir in
            guard open else { return }
            let n = stops.count
            switch dir {
            case .increment: selected = min(n - 1, selected + 1)
            case .decrement: selected = max(0, selected - 1)
            @unknown default: break
            }
        }
        // 收着时旁白直接给几个动作，不必展开
        .accessibilityAction(named: "返回") { close(); dismiss() }
        .accessibilityAction(named: "下载") { runDownload() }
        .accessibilityIdentifier("detail-arc-menu")
    }

    /// 展开以后胶囊里面：青绿的轨道、各档的淡点、白色滑块头（头里是这一档的符号）
    private func expanded(width: CGFloat, step: CGFloat, count n: Int) -> some View {
        let knobX = dragX ?? (Self.endInset + step * CGFloat(selected))
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Self.track)
                .padding(Self.trackInset)
            ForEach(0..<n, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 12, height: 12)
                    .position(x: Self.endInset + step * CGFloat(i), y: Self.barHeight / 2)
            }
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                .frame(width: Self.knob, height: Self.knob)
                .overlay {
                    let i = currentIndex
                    Image(systemName: stops.indices.contains(i) ? stops[i].symbol : "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Self.track)
                        .contentTransition(.symbolEffect(.replace))
                }
                .position(x: knobX, y: Self.barHeight / 2)
        }
        .frame(width: width, height: Self.barHeight)
        .onAppear { barWidth = width }
        .onChange(of: width) { _, w in barWidth = w }
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let x = min(width - Self.endInset, max(Self.endInset, v.location.x))
                    let before = currentIndex
                    dragX = x
                    if currentIndex != before { Haptics.selection() }
                }
                .onEnded { v in
                    let x = min(width - Self.endInset, max(Self.endInset, v.location.x))
                    let i = min(n - 1, max(0, Int(((x - Self.endInset) / max(1, step)).rounded())))
                    // 松手：滑块头落到那一档（带一点回弹），落稳了再做那件事
                    withAnimation(DSMotion.adapt(.spring(response: 0.3, dampingFraction: 0.8), reduce: reduceMotion)) {
                        dragX = nil
                        selected = i
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(reduceMotion ? 60 : 180))
                        perform(i)
                    }
                }
        )
    }

    private func toggle() {
        Haptics.light()
        setOpen(!open)
    }

    /// 展开带一点回弹，收起干脆利落。展开时滑块停在最右边「收起」那一档（正是「+」原来的位置）
    private func setOpen(_ on: Bool) {
        releaser?.cancel()
        if on {
            anchor.frozen = true
            selected = max(0, stops.count - 1)
            dragX = nil
        }
        let curve = DSMotion.adapt(on ? Animation.spring(response: 0.42, dampingFraction: 0.82) : DSMotion.snap, reduce: reduceMotion)
        withAnimation(curve) { open = on }
        if !on {
            // 收完、后面的页面也回到原大以后，「+」再跟着那一格走
            releaser = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                if Task.isCancelled || open { return }
                anchor.frozen = false
            }
        }
    }

    private func close() {
        if open { setOpen(false) }
    }

    /// 做第 i 档的事
    private func perform(_ i: Int) {
        guard stops.indices.contains(i) else { return }
        switch stops[i].id {
        case "back":
            Haptics.light()
            close()
            dismiss()
        case "download":
            close()
            runDownload()
        case "restart":
            Haptics.light()
            close()
            onRestart?()
        default:
            Haptics.light()
            close()
        }
    }

    /// 「下载」：还没下就开始下（开不了说一声）；下载中 / 暂停了 / 下好了弹系统的选项
    private func runDownload() {
        if let it = Precache.shared.item(path: video.path), it.isFull {
            downloadOptions = true
        } else {
            alert = DetailDownloadStarter.start(video: video, title: title, runtime: runtime)
        }
    }

    @ViewBuilder
    private var downloadOptionButtons: some View {
        if let it = Precache.shared.item(path: video.path), it.isFull {
            switch it.phase {
            case .done:
                Button("删除下载", role: .destructive) { Precache.shared.delete(path: video.path) }
            case .downloading, .queued, .preparing:
                Button("暂停下载") { Precache.shared.pause(path: video.path) }
                Button("取消下载", role: .destructive) { Precache.shared.delete(path: video.path) }
            case .paused, .failed, .noSpace:
                Button("继续下载") { Precache.shared.resume(path: video.path) }
                Button("取消下载", role: .destructive) { Precache.shared.delete(path: video.path) }
            }
        }
        Button("好", role: .cancel) {}
    }

    /// 点空白处收起：透明的一层（用户要求不压暗，后面的页面只轻微模糊）
    private var scrim: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .transition(.opacity)
            .accessibilityHidden(true)
    }
}

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
