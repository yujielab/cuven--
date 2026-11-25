import SwiftUI
// 上滑那颗胶囊的手势要自己定 state（RequestSwipeUpRecognizer）
import UIKit.UIGestureRecognizerSubclass

// MARK: - 请求添加：按钮 → 五步进度卡（同一块液态玻璃变形过去）
//
// 片库里没有的那部（影片库索引里有），详情页的「播放」换成一颗「请求添加」：白色的玻璃胶囊。按下去，这块玻璃原地长成一张
// 矩形的玻璃卡（同一个视图、同一块玻璃，圆角和大小跟着版面一起动画，不是淡出淡入两样东西：见 RequestMorphControl），卡上是
// 「STEP 3 OF 5」「40% Complete」（绿）、五段胶囊进度（走完的实心绿、正在走的绿边 + 走了多少、没到的暗）和五步的名字：
// 等待制片商 → 等待回应 → 等待品质管理 → 等待传输 → 最终发行审批（用户定的说法），底下一行固定的说明。
// 内部在做什么（推到 PikPak、清洗、传到 Dropbox、哪个版本、出了什么错）不显示，服务器给 App 的也不带。
//
// 可以申请的那一刻（用户要求，参考 Swipe-to-Send 视频和规格）：胶囊写「↑ 上滑申请添加」，底下一层淡淡的青紫光；
// 往上拖，胶囊和光一起跟着手指走（约 1.5 个胶囊高，到顶有点阻力），过线停在上沿、底下出「松手即可申请」；
// 过线松手（或直接按一下）就放进请求中心，盖上 RequestSendOverlay：粒子箭头「正在发往请求中心」→ 打勾「已添加至请求中心」+ 时间。

private let requestGreen = Color(red: 0.19, green: 0.82, blue: 0.35)
private let requestRed = Color(red: 1.0, green: 0.27, blue: 0.23)

/// 头部那颗按钮 / 那张卡的三种样子：请求添加（按钮）→ 五步进度（卡）→ 立即播放（按钮）
enum RequestButtonMode: Equatable {
    case request(title: String, symbol: String, enabled: Bool)
    /// 可以申请：上滑（或按下）发往请求中心的那颗胶囊（用户要求，参考 Swipe-to-Send 视频）
    case send
    case progress(RequestStatus)
    /// 发行了、片库里有了：卡收回成「立即播放」（用户要求：完成后自动还原形变为立即播放）
    case play(busy: Bool)

    var isCard: Bool { if case .progress = self { return true }; return false }
}

/// 头部那颗按钮 / 那张卡。
/// 是同一个视图、同一块玻璃：按钮时高 48、圆角 24（正好是胶囊），卡时圆角 26、高度跟着内容。玻璃挂在一直在的那个框上，
/// 框的大小随版面一起动画——玻璃的边、上面的片名和那一行信息在同一个动画里一起走，不会有一刻卡先铺满、盖住上面的字
/// （第一版用两个视图 + glassEffectID 变形：截图里变形到一半，玻璃已经是卡的大小，片名还在往上走）。
/// 里面的字交叉淡入淡出，裁在玻璃里面。请求添加 → 卡、卡 → 立即播放 都是这一块玻璃变过去。
/// 可以申请时（.send）这块玻璃还能往上拖（用户要求的上滑发送）：胶囊和底下的光跟着手指走，过线松手 / 按一下就发往请求中心
struct RequestMorphControl: View {
    let mode: RequestButtonMode
    let wide: Bool
    let onRequest: () -> Void
    let onPlay: () -> Void
    /// 上滑发送（用户要求）：返回 true = 发出去了（胶囊停在上沿化开淡出，详情页接着盖上「正在发往请求中心」那一屏）；
    /// false = 没发出去（没登录等），胶囊弹回原位。没给的话按一下就走 onRequest
    var onSend: (() -> Bool)? = nil
    /// 已经发出、那一屏正盖在上面：胶囊化开淡出；那一屏关掉（变回 false）以后回到原位再淡回来
    var launched = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 往上拖了多少点（手指的真实位移，往上为正）
    @State private var dragLift: CGFloat = 0
    /// 过没过线：过了线胶囊停在上沿，底下出「松手即可申请」
    @State private var armed = false
    /// 什么时候过的线：过线停一下再松手才算（往上甩着滚页面的那一下不算）
    @State private var armedAt: Date?

    /// 行程：1.5 个胶囊高（规格：拖动约一个半胶囊高）
    static let travel: CGFloat = 48 * 1.5
    /// 拖过行程的 72% 算过线；退回 55% 以下才算没过（停在线上抖，不会来回闪）
    private static let commit: CGFloat = 0.72
    private static let uncommit: CGFloat = 0.55
    /// 整段手势里手指离按下那一点最远也没走到这么远就松手：当成按了一下
    private static let tapSlop: CGFloat = 10
    /// 过线以后至少停这么久再松手才发（用户要求上滑申请添加，但往上甩着滚页面不该误发）
    private static let armHold: TimeInterval = 0.12

    var body: some View {
        let card = mode.isCard
        let shape = RoundedRectangle(cornerRadius: card ? 26 : 24, style: .continuous)
        let maxW: CGFloat? = card ? (wide ? 520 : .infinity) : (wide ? nil : .infinity)
        let tappable: Bool = {
            switch mode {
            case .request(_, _, let enabled): return enabled
            case .send: return true
            case .play(let busy): return !busy
            case .progress: return false
            }
        }()
        let hint: String = isSend ? "轻点两下发往请求中心" : ""
        // 旁白念「请求添加」（用户要求），语音控制说屏上的「上滑申请添加」也能按
        let voiceLabels: [Text] = isSend ? [Text("请求添加"), Text("上滑申请添加"), Text("申请添加")] : []
        let soften: Bool = launched && !reduceMotion
        let rise: CGFloat = -shownLift * Self.travel
        // 外面单独一层容器给测试认胶囊（用户要求的上滑发送）：同一串修饰器里再来一次 accessibilityElement 可能把里面那颗
        // 「请求添加」按钮改成容器、换掉它的标识；包一层 ZStack，里面的按钮和旁白提示不受影响
        ZStack {
            ZStack(alignment: .topLeading) {
                switch mode {
                case .progress(let status):
                    RequestProgressCard(status: status)
                        .transition(.opacity)
                case .request(let title, let symbol, let enabled):
                    buttonLabel(title, symbol: symbol, dark: enabled)
                        .transition(.opacity)
                case .send:
                    sendLabel
                        .transition(.opacity)
                case .play(let busy):
                    buttonLabel(busy ? "正在准备…" : "立即播放", symbol: "play.fill", dark: true)
                        .transition(.opacity)
                }
            }
            .frame(minWidth: wide ? 180 : 0, maxWidth: maxW, alignment: .topLeading)
            .fixedSize(horizontal: wide && !card, vertical: false)
            .clipShape(shape)
            .contentShape(shape)
            .glassEffect(card ? .regular : (tappable || isPlay ? .regular.tint(.white.opacity(0.92)).interactive() : .regular), in: shape)
            // 胶囊底下那层青紫光（用户要求，参考视频）：挂在胶囊上、跟着它往上走，拖得越高越亮
            .background { glow }
            .environment(\.colorScheme, .dark)
            // 只认往上的拖：往下、横着的照常滚页面（见 RequestSwipeUpRecognizer）
            .gesture(RequestSwipeUpGesture(isEnabled: isSend && !launched,
                                           onChanged: { dragChanged($0) },
                                           onEnded: { dragEnded(reach: $0) },
                                           onCancelled: { settle() }))
            .onTapGesture { tap() }
            .accessibilityElement(children: card ? .contain : .combine)
            .accessibilityAddTraits(card ? [] : .isButton)
            .accessibilityHint(Text(hint))
            .accessibilityInputLabels(voiceLabels)
            .accessibilityAction { tap() }
            // 「request-add」留着：DuoUnfoldedTests 用它找这颗钮
            .accessibilityIdentifier(card ? "request-card" : (isPlay ? "request-play" : "request-add"))
            // 发出去了：停在上沿化开、淡出（减弱动态效果时只淡出）
            .scaleEffect(soften ? 1.05 : 1)
            .blur(radius: soften ? 8 : 0)
            .opacity(launched ? 0 : 1)
            .offset(y: rise)
            // 「松手即可申请」留在原位：胶囊升到上沿以后正好在它底下（规格：Release to send 出现在胶囊下面）
            .overlay { releaseHint }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isSend ? "request-send-capsule" : "request-control")
        .onChange(of: launched) { _, now in
            // 那一屏关掉了：不带动画地放回原位，再由详情页的动画淡回来（不从上沿掉下来）
            guard !now else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                dragLift = 0
                armed = false
                armedAt = nil
            }
        }
        .onChange(of: isSend) { _, now in
            // 拖着的时候这一部不再是「可以申请」了（状态更新）：回原位
            if !now && !launched { settle() }
        }
        // 按钮 ↔ 卡的那一下由详情页用 morph 这条曲线包起来（版面和玻璃同一个动画）；这里只管卡里的进度更新
        .animation(DSMotion.adapt(.smooth(duration: 0.45), reduce: reduceMotion), value: mode)
    }

    private var isPlay: Bool { if case .play = mode { return true }; return false }
    private var isSend: Bool { if case .send = mode { return true }; return false }

    private func tap() {
        switch mode {
        case .request(_, _, let enabled): if enabled { onRequest() }
        case .send: send()
        case .play(let busy): if !busy { onPlay() }
        case .progress: break
        }
    }

    private func buttonLabel(_ title: String, symbol: String, dark: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(dark ? Color.black : Color.white.opacity(0.75))
            .lineLimit(1)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 48)
    }

    // MARK: 上滑发送（用户要求：上滑或按下「请求添加」→ 粒子箭头「正在发往请求中心」→ 打勾 + 时间）

    /// 可以申请时胶囊上的字：一个小「↑」+「上滑申请添加」（参考视频的 ↑ Swipe to send）。旁白念「请求添加」
    private var sendLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.subheadline.weight(.bold))
            Text("上滑申请添加")
                .font(.headline)
        }
        .foregroundStyle(Color.black)
        .lineLimit(1)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, minHeight: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("请求添加")
    }

    /// 一个归一化的拖动值同时管位置和光（规格：Drive vertical position and bloom with one normalized drag value）。
    /// 0 = 原位，1 = 上沿。过了线停在上沿；再往上拉只多走一点、越拉越紧（减弱动态效果时没有这一下橡皮筋）
    private var shownLift: CGFloat {
        let r = max(0, dragLift) / Self.travel
        guard armed else { return min(r, 1) }
        guard !reduceMotion else { return 1 }
        let over = max(0, r - 1)
        return 1 + 0.25 * over / (over + 0.5)
    }

    /// 胶囊底下的光：原位时淡淡一层，拖到上沿最亮
    @ViewBuilder private var glow: some View {
        if isSend {
            SendCapsuleGlow(intensity: 0.22 + 0.78 * Double(min(1, shownLift)))
                .frame(height: 120)
                .padding(.horizontal, -28)
                .offset(y: 24)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var releaseHint: some View {
        if isSend && armed && !launched {
            Text("松手即可申请")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.8))
                .offset(y: -8)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 6)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 过线时缓缓停进上沿（减弱动态效果：短短的缓出，不弹）
    private var armAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.78)
    }

    private func dragChanged(_ lift: CGFloat) {
        guard isSend, !launched else { return }
        dragLift = max(0, lift)
        let r = dragLift / Self.travel
        if !armed && r >= Self.commit {
            Haptics.selection()
            armedAt = Date()
            withAnimation(armAnimation) { armed = true }
        } else if armed && r < Self.uncommit {
            armedAt = nil
            withAnimation(armAnimation) { armed = false }
        }
    }

    /// reach：整段手势里手指离按下那一点最远走了多远（不是松手那一刻的位置）
    private func dragEnded(reach: CGFloat) {
        guard !launched else { return }
        guard isSend else { settle(); return }
        // 过线、停了一下再松手：发出去（只发一次）。用户要求上滑申请添加，但往上甩着滚页面不该误发：过线停一下再松手才算
        let heldArmed = armed && Date().timeIntervalSince(armedAt ?? .distantFuture) >= Self.armHold
        // 用户要求：没过线就松手要弹回；拖上去又拖回原位松手不算按一下，只有从头到尾几乎没动才当成按了一下
        if heldArmed || reach < Self.tapSlop {
            send()
        } else {
            settle()
        }
    }

    /// 发出去（过线松手 / 按一下 / 旁白轻点两下）。发出以后由 launched 接着管，不会再发第二次
    private func send() {
        guard !launched else { return }
        guard let onSend else {
            onRequest()
            settle()
            return
        }
        if onSend() {
            // 发出去了：胶囊升到上沿停住（按一下的也一样），在那一屏底下化开淡出。
            // 减弱动态效果（用户要求）：按一下发出只原地淡出，不往上飞（上滑过线的本来就停在上沿）
            if !reduceMotion {
                withAnimation(armAnimation) {
                    armed = true
                    dragLift = max(dragLift, Self.travel)
                }
            }
        } else {
            settle()
        }
    }

    /// 没过线就松手：短促、带一点阻尼地回到原位（规格：160–220 ms）
    private func settle() {
        armedAt = nil
        guard dragLift != 0 || armed else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.2, dampingFraction: 0.86)) {
            dragLift = 0
            armed = false
        }
    }

    /// 按钮 ↔ 卡：详情页改状态时用这一条（整个头部的版面一起走）
    static func morph(reduce: Bool) -> Animation {
        DSMotion.adapt(.spring(response: 0.55, dampingFraction: 0.84), reduce: reduce)
    }
}

/// 「上滑申请添加」那颗胶囊的手势（用户要求：上滑发往请求中心，但往下拖、横着拖、从别处拖都照常滚页面）。
/// SwiftUI 的 DragGesture 一接住就不再让给外面的滚动视图，也没法按方向放弃，所以用一个先看方向的 UIKit 手势：
/// 一开始往上（竖着为主）走过几点才接住，同时停掉外面那个滚动视图的拖动（结束 / 取消时还原）；
/// 往下、横着的直接放弃，交给页面滚动；没怎么动就松手的也放弃，交给按一下（onTapGesture）；
/// 一按下就飞快往上甩的（滚页面的那一甩）也放弃，交给页面滚动
final class RequestSwipeUpRecognizer: UIGestureRecognizer {
    /// 往上拖了多少点（往上为正）。新的一下开始时才清零：结束那一下的值留给动作回调读
    private(set) var lift: CGFloat = 0
    /// 整段手势里手指离按下那一点最远走了多远（用户要求：拖上去又拖回原位松手要弹回，不能当成按了一下）
    private(set) var reach: CGFloat = 0
    private var tracked: UITouch?
    private var start: CGPoint = .zero
    private var startTime: TimeInterval = 0
    /// 拖动期间停掉的那个滚动视图（只在往上拖着胶囊时停，结束就还原）
    private weak var heldScroll: UIScrollView?
    /// 认方向之前要走多少点
    private static let slop: CGFloat = 6
    /// 从按下到走过 slop 的平均速度比这还快（点/秒）：是往上甩着滚页面，不是拖胶囊
    private static let flickSpeed: CGFloat = 1500

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard tracked == nil, touches.count == 1, let t = touches.first else {
            // 第二根手指：还没接住的就不接了（已经接住的继续跟第一根）
            if state == .possible { state = .failed }
            return
        }
        tracked = t
        start = t.location(in: nil)
        startTime = t.timestamp
        lift = 0
        reach = 0
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let t = tracked, touches.contains(t) else { return }
        let p = t.location(in: nil)
        let dx = p.x - start.x
        let dy = p.y - start.y
        switch state {
        case .possible:
            if dy <= -Self.slop && -dy > abs(dx) {
                // 用户要求上滑申请添加，但往上甩着滚页面不该误发：一按下就飞快往上走的交还给页面滚动
                let dt = CGFloat(t.timestamp - startTime)
                if dt > 0 && -dy / dt > Self.flickSpeed {
                    state = .failed
                    return
                }
                lift = -dy
                reach = hypot(dx, dy)
                holdScroll(from: t)
                state = .began
            } else if dy >= Self.slop || abs(dx) >= Self.slop * 2 {
                state = .failed
            }
        case .began, .changed:
            lift = -dy
            reach = max(reach, hypot(dx, dy))
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let t = tracked, touches.contains(t) else { return }
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let t = tracked, touches.contains(t) else { return }
        state = (state == .began || state == .changed) ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        heldScroll?.panGestureRecognizer.isEnabled = true
        heldScroll = nil
        tracked = nil
    }

    /// 从手指按着的那个视图往上找最近的滚动视图（详情页那一页），拖着胶囊时先不让它滚
    private func holdScroll(from t: UITouch) {
        var v = t.view
        while let cur = v, !(cur is UIScrollView) { v = cur.superview }
        guard let scroll = v as? UIScrollView, scroll.panGestureRecognizer.isEnabled else { return }
        scroll.panGestureRecognizer.isEnabled = false
        heldScroll = scroll
    }
}

/// 把 RequestSwipeUpRecognizer 挂到 SwiftUI 视图上（iOS 18 起的 UIGestureRecognizerRepresentable）
struct RequestSwipeUpGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    /// 松手：给的是整段手势里手指最远走了多远（recognizer.reach），用来分「按了一下」和「拖了又拖回来」
    var onEnded: (CGFloat) -> Void
    var onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> RequestSwipeUpRecognizer {
        let r = RequestSwipeUpRecognizer()
        r.isEnabled = isEnabled
        return r
    }

    func updateUIGestureRecognizer(_ recognizer: RequestSwipeUpRecognizer, context: Context) {
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ recognizer: RequestSwipeUpRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChanged(recognizer.lift)
        case .ended: onEnded(recognizer.reach)
        case .cancelled: onCancelled()
        default: break
        }
    }
}

/// 卡里的内容：STEP X OF 5 · N% Complete · 五段胶囊 · 五步的名字 · 一行给用户的说明。
/// 用户要求：不展示用户不该知道的内容——内部在做什么（推到 PikPak、清洗、传到 Dropbox、哪个版本、出了什么错）一律不显示，
/// 服务器给 App 的进度里也不再带这些（只在控制面板里看得到）
struct RequestProgressCard: View {
    let status: RequestStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("STEP \(status.step) OF \(status.steps)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    // 进到下一步时那个数滚过去（和右边的百分比同一下），不是整行硬换
                    .contentTransition(.numericText(value: Double(status.step)))
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(trailingColor)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(status.pct)))
            }
            RequestSegments(status: status)
            HStack(alignment: .top, spacing: 6) {
                ForEach(0..<RequestStatus.labels.count, id: \.self) { i in
                    let reached = status.state == .done || i + 1 <= status.step
                    Text(Self.stacked(RequestStatus.labels[i]))
                        .font(.caption2.weight(i + 1 == status.step ? .semibold : .regular))
                        .foregroundStyle(reached ? Color.white : DSInk.tertiary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(DSInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("请求添加，第 \(status.step) 步，共 \(status.steps) 步：\(RequestStatus.labels[max(0, min(4, status.step - 1))])。\(trailing)。\(footnote)")
    }

    /// 五步的名字都是两个字的动词加对象（等待… / 最终…），在动词后面断行，五个都是整齐的两行；
    /// 以前让系统自己断，窄的时候有的一行、有的两行，还会断成「等待品质 / 管理」（设计复查）
    private static func stacked(_ s: String) -> String {
        s.count > 3 ? String(s.prefix(2)) + "\n" + String(s.dropFirst(2)) : s
    }

    /// 卡底下那一行小字（进行中的是用户定的说法）
    private var footnote: String {
        switch status.state {
        case .active: return "您可以返回，我们将在影片就绪时提醒您。添加流程一般不会超过一个小时。"
        case .done: return "影片已就绪，现在可以观看。"
        case .failed: return "暂时无法添加这部影片，请稍后再试。"
        case .cancelled: return "这次添加已取消。"
        }
    }

    private var trailing: String {
        switch status.state {
        case .active, .done: return "\(status.pct)% Complete"
        case .failed: return "未能添加"
        case .cancelled: return "已取消"
        }
    }

    private var trailingColor: Color {
        switch status.state {
        case .active, .done: return requestGreen
        case .failed: return requestRed
        case .cancelled: return DSInk.tertiary
        }
    }
}

/// 五段胶囊：走完的实心绿；正在走的绿边，里面按这一步走了多少填上；没到的暗
struct RequestSegments: View {
    let status: RequestStatus

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...max(1, status.steps), id: \.self) { i in segment(i) }
        }
        .frame(height: 8)
    }

    private func segment(_ i: Int) -> some View {
        let done = status.state == .done || i < status.step
        let current = !done && i == status.step
        let tint = status.state == .failed ? requestRed : requestGreen
        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(done ? 0 : 0.14))
                if done {
                    Capsule().fill(requestGreen)
                } else if current {
                    if status.stepProgress > 0 {
                        Capsule().fill(tint)
                            .frame(width: max(8, g.size.width * status.stepProgress))
                    }
                    Capsule().strokeBorder(tint, lineWidth: 1.5)
                }
            }
        }
    }
}

// MARK: - 详情页（影片库索引里有、片库里没有的那部）

struct CatalogDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountStore.self) private var account
    let title: CatalogTitle
    @State private var meta: Meta?
    @State private var detail: CatalogDetail?
    @State private var art: DetailArt?
    /// 剧集：选的是哪一季（0 = 还没定，用服务器挑的最新一季）
    @State private var season = 0
    @State private var loading = true
    @State private var busy = false
    /// 刚按下去、服务器还没回话：先把卡变出来（第 1 步），回话了换成真的
    @State private var pending: RequestStatus?
    @State private var alert: DetailAlert?
    /// 完成了（发行了 / 片库里本来就有）：卡收回成「立即播放」。看着页面时刚完成的，先让 100% 的卡停一下再收回
    @State private var showPlay = false
    /// 按了「立即播放」：片库还没刷新到这部、正在找
    @State private var opening = false
    /// 上滑（或按下）发往请求中心以后盖上去的那一屏（用户要求：粒子箭头「正在发往请求中心」→ 打勾「已添加至请求中心」+ 时间）
    @State private var sendItem: RequestSendItem?
    /// 那一屏的结果：nil = 还在「正在发往请求中心」
    @State private var sendResult: RequestSendResult?
    @State private var sendShowing = false
    /// 已经发出：胶囊停在上沿化开淡出；那一屏关掉以后淡回来（那时已经是「已加入请求中心」）
    @State private var sendLaunched = false
    /// 那一屏按的是「前往请求中心」：关掉以后切过去
    @State private var sendOpensCenter = false
    /// 用户要求先「正在发往请求中心」再「已添加」：那一屏盖着的时候胶囊还是上滑那颗（光也在），关掉、放回原位以后才换成「已加入请求中心」
    @State private var sendHold = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct DetailAlert: Identifiable { let title: String; let message: String; var id: String { title + message } }

    private var store: RequestStore { RequestStore.shared }
    private var basket: RequestBasket { RequestBasket.shared }
    private var seasonKey: Int { title.kind == .tv ? (season > 0 ? season : (detail?.season ?? 0)) : 0 }
    private var ownedSeasons: Set<Int> { title.kind == .tv ? (model.ownedSeasons[title.id] ?? []) : [] }

    var body: some View {
        // 进行中 / 失败了的请求才变成五步进度卡；取消了的当没请求过（可以重新放进请求中心）
        let raw = pending ?? store.status(src: title.kind.rawValue, id: title.id, season: seasonKey)
        let status = raw?.state == .cancelled ? nil : raw
        let inLibrary = libraryMovie != nil || librarySeries != nil
        let done = inLibrary || status?.state == .done
        let available = (detail?.count ?? 0) > 0 && !inLibrary
        let queued = basket.contains(title, season: seasonKey)
        // 头部那颗：发出去、那一屏还盖着时不换成「已加入」（见 sendHold）；底下固定条照旧按 queued
        let mode = buttonMode(status: status, done: done, available: available, queued: queued && !sendHold)
        let playing: Bool = { if case .play = mode { return true }; return false }()
        DetailScaffold(
            title: displayTitle,
            art: art,
            metaLine: metaLine,
            playTitle: playing ? "播放" : (status != nil ? "已请求" : (queued ? "已加入" : "请求添加")),
            playID: "request-pinned",
            playDisabled: playing ? opening : (status != nil || (!available && !queued) || busy),
            onPlay: { if playing { playNow() } else { _ = request() } },
            genres: meta?.genres ?? [],
            overview: meta?.overview,
            director: meta?.director,
            stats: stats,
            related: nil,
            thumb: TMDBImage.url(meta?.poster ?? meta?.posterClean ?? title.poster, "w185"),
            cast: meta?.cast ?? [],
            trailers: [],
            trailerArt: [],
            stills: DetailText.stills(meta),
            customAction: AnyView(
                RequestMorphControl(mode: mode, wide: false, onRequest: { _ = request() }, onPlay: { playNow() },
                                    onSend: { request() }, launched: sendLaunched)
            )
        ) { m in
            sections(m)
        }
        .task(id: title) { await load() }
        .onAppear { if done { showPlay = true } }
        // 完成了：100% 的卡停 1.5 秒，再收回成「立即播放」（刚打开页面、还在载入时就完成的，直接是「立即播放」）
        .onChange(of: done) { _, now in
            guard now else { showPlay = false; return }
            if loading || status == nil { showPlay = true; return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                withAnimation(RequestMorphControl.morph(reduce: reduceMotion)) { showPlay = true }
                Haptics.success()
            }
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }), presenting: alert) { _ in
            Button("好", role: .cancel) {}
        } message: { a in
            Text(a.message)
        }
        .modifier(RequestSendCover(showing: $sendShowing, item: sendItem, result: sendResult,
                                   onDone: { closeSend(openCenter: false) },
                                   onOpenCenter: { closeSend(openCenter: true) },
                                   onDismiss: { sendDismissed() }))
    }

    /// 头部那颗钮现在是哪个样子：立即播放 / 五步进度卡 / 已加入请求中心 / 上滑申请添加 / 查询中、暂无可用资源
    private func buttonMode(status: RequestStatus?, done: Bool, available: Bool, queued: Bool) -> RequestButtonMode {
        if done && (showPlay || status == nil) { return .play(busy: opening) }
        if let status { return .progress(status) }
        // 已经在请求中心里：和以前一样，按一下切到请求中心去确认（没有上滑那颗胶囊）
        if queued { return .request(title: "已加入请求中心", symbol: "checkmark", enabled: true) }
        // 可以申请：上滑（或按下）发往请求中心（用户要求）
        if available && !busy { return .send }
        return .request(title: buttonTitle(available: available), symbol: available ? "plus" : "clock", enabled: false)
    }

    // MARK: 立即播放（发行以后：这部已经在片库里了）

    private var libraryMovie: Video? { RequestPlayback.movie(title, model: model) }
    private var librarySeries: Series? { RequestPlayback.series(title, season: seasonKey, model: model) }

    private func playNow() {
        guard !opening else { return }
        opening = true
        Task { @MainActor in
            let problem = await RequestPlayback.play(title, season: seasonKey, model: model, artwork: meta?.backdrop ?? meta?.poster)
            opening = false
            if let problem { alert = DetailAlert(title: problem.title, message: problem.message) }
        }
    }

    private var displayTitle: String {
        if let t = meta?.title, !t.isEmpty { return t }
        return title.title
    }

    private func buttonTitle(available: Bool) -> String {
        if available { return busy ? "正在提交…" : "请求添加" }
        return loading ? "正在查询…" : "暂无可用资源"
    }

    private var metaLine: String {
        DetailText.line([
            title.kind == .tv ? "剧集" : "电影",
            meta?.genres?.first,
            (meta?.year ?? title.year).isEmpty ? nil : (meta?.year ?? title.year),
            title.kind == .movie ? Format.runtime(meta?.runtime) : nil,
            DetailText.rating(meta?.rating),
        ])
    }

    private var stats: DetailStats {
        var s = DetailStats()
        let day = DetailFacts.day(meta?.releaseDate)
        let y = Int(meta?.year ?? title.year)
        if day != nil || y != nil {
            s.release = DetailStats.Release(date: day, year: y, verb: title.kind == .tv ? "首播" : "上映", season: nil)
        }
        if let r = meta?.runtime, r > 0 { s.runtime = DetailStats.Runtime(minutes: r, perEpisode: title.kind == .tv) }
        if let r = meta?.rating, r > 0 { s.rating = r }
        return s
    }

    // MARK: 下面一段：选季（剧集）。用户要求：不放「资源」那张卡（规格、版本数、怎么下载都是用户不该知道的）

    @ViewBuilder
    private func sections(_ m: DSMetrics) -> some View {
        if title.kind == .tv, let d = detail, !d.seasons.isEmpty {
            group(m, "季") {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(d.seasons, id: \.self) { n in seasonChip(n) }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                // 季多的时候往左滑：胶囊从页边距上滑过去，不在边距那条线上被齐齐切掉（和别的横排一样不裁）
                .scrollClipDisabled()
            }
        }
    }

    private func seasonChip(_ n: Int) -> some View {
        let on = n == seasonKey
        let st = store.status(src: "tv", id: title.id, season: n)
        return Button {
            guard !on else { return }
            Haptics.selection()
            withAnimation(DSMotion.snap) { season = n; pending = nil }
            Task { await reload(season: n) }
        } label: {
            HStack(spacing: 6) {
                Text("第 \(n) 季").font(.subheadline.weight(.semibold))
                if ownedSeasons.contains(n) {
                    Image(systemName: "checkmark.circle.fill").font(.caption)
                } else if let st {
                    Text(st.state == .done ? "已就绪" : st.state == .failed ? "未能添加" : "\(st.pct)%")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(on ? Color.black.opacity(0.6) : (st.state == .failed ? requestRed : requestGreen))
                }
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.12)))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("request-season-\(n)")
    }

    /// 和详情页别的分区同一个样子：粗体标题 + 内容，展开的屏上最宽 720
    private func group<Content: View>(_ m: DSMetrics, _ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.titleGap + 4) {
            DetailGroupTitle(title: name)
            content().frame(maxWidth: 720, alignment: .leading)
        }
        .padding(.horizontal, m.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 载入、请求

    private func load() async {
        if DemoData.enabled { loadDemo(); return }
        let fallback = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled && art == nil { art = DetailArt(wide: title.poster, tall: title.poster, logo: nil) }
        }
        async let m = APIClient.shared.tmdb(query: title.title, year: title.year.isEmpty ? nil : title.year,
                                            type: title.kind == .tv ? "tv" : "movie", id: title.id, full: true)
        async let d = RequestAPI.detail(title, season: nil)
        let mm = (try? await m) ?? nil
        meta = mm
        fallback.cancel()
        if art == nil || art?.logo == nil {
            art = DetailArt(wide: mm?.backdropClean ?? mm?.backdrop ?? mm?.poster ?? title.poster,
                            tall: mm?.posterClean ?? mm?.poster ?? title.poster, logo: mm?.logo)
        }
        let dd = try? await d
        detail = dd
        loading = false
        if let dd {
            store.merge(dd.req)
            for (_, r) in dd.reqs { store.merge(r) }
        }
    }

    private func reload(season n: Int) async {
        guard !DemoData.enabled else { return }
        loading = true
        if let dd = try? await RequestAPI.detail(title, season: n) {
            detail = dd
            store.merge(dd.req)
        }
        loading = false
    }

    /// 用户要求的批量流程：「请求添加」先放进请求中心（最多 50 部），在请求中心按「确认」才一起提交。
    /// 已经在请求中心里的，再按一下就切到请求中心去确认。
    /// 上滑（或按下）那颗胶囊（用户要求）：放进请求中心，盖上「正在发往请求中心 → 已添加至请求中心」那一屏（RequestSendOverlay）。
    /// 返回 true = 发出去了（胶囊停在上沿淡出）；false = 没发（没登录、已经在请求中心里、那一屏还盖着）
    @discardableResult
    private func request() -> Bool {
        guard !busy, pending == nil, !sendShowing else { return false }
        if !DemoData.enabled && !account.isLoggedIn { alert = DetailAlert(title: "无法请求添加", message: "登录后才能请求添加。"); return false }
        let s = seasonKey
        if basket.contains(title, season: s) {
            Haptics.selection()
            basket.openCenter = true
            return false
        }
        let result: RequestSendResult
        switch basket.add(title, season: s) {
        case .added:
            result = .added(Date())
        case .already:
            result = .already(basketDate(season: s) ?? Date())
        case .full:
            result = .failed("请求中心最多放 \(RequestBasket.limit) 部，先在请求中心确认这一批，再加新的。")
        }
        launchSend(result)
        return true
    }

    /// 这一部（这一季）放进请求中心的时间
    private func basketDate(season s: Int) -> Date? {
        let key = RequestStatus.key(src: title.kind.rawValue, id: title.id, season: title.kind == .tv ? s : 0)
        return basket.items.first { $0.key == key }?.added
    }

    /// 盖上那一屏：先是「正在发往请求中心」（粒子箭头往上飞），停一会儿再给结果（打勾 + 时间）。
    /// 放进请求中心是本地的、一下就好；停这一下是用户要的那段飞行（规格：发送状态一直保持到结果回来）
    private func launchSend(_ result: RequestSendResult) {
        let s = seasonKey
        sendItem = RequestSendItem(title: displayTitle,
                                   season: title.kind == .tv && s > 0 ? s : nil,
                                   poster: TMDBImage.url(meta?.poster ?? meta?.posterClean ?? title.poster, "w342"))
        sendResult = nil
        sendOpensCenter = false
        Haptics.light()
        // 不要系统从下往上推的那一下（那一屏自己从透明里亮起来）；底是透明的，不会闪白
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { sendShowing = true }
        // 和 basket.add 同一次更新：胶囊不换成「已加入」，还是上滑那颗、光最亮，在那一屏底下化开淡出
        sendHold = true
        withAnimation(DSMotion.adapt(.easeOut(duration: 0.5), reduce: reduceMotion)) { sendLaunched = true }
        let hold = reduceMotion ? 700 : 1500
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(hold))
            guard sendShowing else { return }
            // 打勾那一下的震动由 RequestSendOverlay 给（和打勾同一刻）：用户要求的成功反馈只要一次，这里不再重复
            sendResult = result
        }
    }

    /// 那一屏上的「好」/「前往请求中心」：关掉回到详情页（这时已经是「已加入请求中心」）；前往的话关掉以后切到请求中心
    private func closeSend(openCenter: Bool) {
        sendOpensCenter = openCenter
        // 那一屏已经自己淡出了（用户要求的收起）：不要系统再往下滑一次，那一下看不见却挡着点按
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { sendShowing = false }
    }

    private func sendDismissed() {
        sendItem = nil
        sendResult = nil
        // 胶囊先不带动画地放回原位（RequestMorphControl 的 onChange(of: launched)）再淡回来；
        // 下一拍才换成「已加入请求中心」，免得那颗胶囊从上沿掉下来（用户要求的顺序：先发送，回来时才是已加入）
        withAnimation(DSMotion.adapt(.easeOut(duration: 0.35), reduce: reduceMotion)) { sendLaunched = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            // 这 50 毫秒里又发了一次（那一屏又盖上了）：留给那一次关掉时再放开
            guard !sendShowing else { return }
            sendHold = false
        }
        if sendOpensCenter {
            sendOpensCenter = false
            basket.openCenter = true
        }
    }

    /// 演示数据（截图用）：本地的画面和简介，三个版本，剧集两季
    private func loadDemo() {
        var m = Meta(id: title.id, title: title.title, en: "The Long Night", year: title.year,
                     poster: title.poster, posterClean: title.poster, backdrop: "demo://backdrop/12",
                     overview: "演示数据：影片库索引里有、片库里还没有的一部。按「请求添加」以后，这块玻璃会变成五步进度卡。",
                     rating: 8.1, type: title.kind.rawValue, runtime: 52, genres: ["剧情", "悬疑"])
        m.director = "林夏"
        meta = m
        art = DetailArt(wide: "demo://backdrop/12", tall: "demo://poster/12", logo: nil)
        detail = CatalogDetail(demo: title, seasons: title.kind == .tv ? [1, 2] : [], count: 3,
                               best: RequestStatus.Spec(res: "2160p", labels: ["4K", "杜比视界"], size: "58.6 GB"))
        loading = false
    }
}

/// 详情页上滑发送以后盖上去的那一屏（用户要求）：整屏，底透明（那一屏自己画暗底和光），没有系统推上来的那一下。
/// 单独一个修饰器：详情页那一长串修饰器再长，编译器就推不动类型了
private struct RequestSendCover: ViewModifier {
    @Binding var showing: Bool
    let item: RequestSendItem?
    let result: RequestSendResult?
    let onDone: () -> Void
    let onOpenCenter: () -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $showing, onDismiss: onDismiss) {
            if let item {
                RequestSendOverlay(item: item, result: result, onDone: onDone, onOpenCenter: onOpenCenter)
                    .presentationBackground(.clear)
                    .environment(\.colorScheme, .dark)
            }
        }
    }
}

// MARK: - 立即播放：片库里的这部（详情页、请求中心共用）

@MainActor
enum RequestPlayback {
    struct Problem { let title: String; let message: String }

    /// 片库里的这部电影：先看名字（或所在文件夹）里的追踪码 [auto-m550-r13]——确定的 TMDB 编号，不用等片名认出来；
    /// 没有追踪码的再按 TMDB 编号对
    static func movie(_ t: CatalogTitle, model: AppModel) -> Video? {
        guard t.kind == .movie else { return nil }
        if let v = model.videos.first(where: { v in
            guard let i = AutoTag.info(in: v.path) else { return false }
            return !i.tv && i.tmdb == t.id
        }) { return v }
        return model.movies.first { model.meta($0)?.id == t.id }
    }

    /// 片库里这部剧的这一季（season 0 = 哪一季都行）：先看文件夹名里的追踪码 [auto-tv1399s2-r14]，再按 TMDB 编号对
    static func series(_ t: CatalogTitle, season: Int, model: AppModel) -> Series? {
        guard t.kind == .tv else { return nil }
        if let s = model.series.first(where: { s in
            guard let i = AutoTag.info(in: s.path), i.tv, i.tmdb == t.id else { return false }
            return season == 0 || i.season == season || (i.season == 0 && (s.season ?? 1) == season)
        }) { return s }
        return model.series.first { s in
            (s.tmdbId ?? model.seriesMetas[s.path]?.id) == t.id && (season == 0 || max(1, s.season ?? 1) == season)
        }
    }

    /// 放片库里的这部；刚发行、片库清单还没刷新到的先刷新一次再找。放不了回给人看的说明
    static func play(_ t: CatalogTitle, season: Int, model: AppModel, artwork: String?) async -> Problem? {
        if let v = movie(t, model: model) { playMovie(v, model: model, artwork: artwork); return nil }
        if let s = series(t, season: season, model: model) { return await playSeries(s, title: t.title, model: model, artwork: artwork) }
        await model.refreshLibrary()
        if t.kind == .tv { await model.refreshSeries() }
        if let v = movie(t, model: model) { playMovie(v, model: model, artwork: artwork); return nil }
        if let s = series(t, season: season, model: model) { return await playSeries(s, title: t.title, model: model, artwork: artwork) }
        // 文件刚抵达 /auto、自动通过了最终审核，片库清单里还没有：请片库马上收录一次，再找
        await APIClient.shared.autoSync()
        await model.refreshLibrary()
        if t.kind == .tv { await model.refreshSeries() }
        if let v = movie(t, model: model) { playMovie(v, model: model, artwork: artwork); return nil }
        if let s = series(t, season: season, model: model) { return await playSeries(s, title: t.title, model: model, artwork: artwork) }
        return Problem(title: "影片正在上架", message: "影片已经就绪，片库还在更新。请稍后再试一次。")
    }

    private static func playMovie(_ v: Video, model: AppModel, artwork: String?) {
        Haptics.light()
        PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(v),
                                                  subtitle: model.year(v).map { String($0) },
                                                  artwork: model.backgroundArtString(v) ?? artwork), model: model)
    }

    /// 剧集：从这一季第 1 集放起，后面几集接着排上（看过一半的，播放器自己接着上次的地方）
    private static func playSeries(_ s: Series, title: String, model: AppModel, artwork: String?) async -> Problem? {
        guard let list = try? await APIClient.shared.episodes(seriesPath: s.path), !list.isEmpty else {
            return Problem(title: "暂时无法播放", message: "无法载入剧集，请稍后再试。")
        }
        let files = list.sorted { ($0.ep ?? Int.max, $0.name) < ($1.ep ?? Int.max, $1.name) }
        let sm = model.seriesMetas[s.path]
        func req(_ f: EpisodeFile) -> PlayRequest {
            PlayRequest(path: f.path, name: f.name, title: sm?.title ?? title, subtitle: f.ep.map { "第 \($0) 集" },
                        artwork: sm?.backdrop ?? artwork, seriesPath: s.path, episode: f.ep)
        }
        var first = req(files[0])
        first.queue = files.dropFirst().map(req)
        Haptics.light()
        PlayerCoordinator.shared.play(first, model: model)
        return nil
    }
}

// MARK: - 目录卡（搜索结果「可请求添加」）

struct CatalogPosterLink: View {
    let item: CatalogItem
    let metrics: DSMetrics
    let slot: String

    var body: some View {
        // 取消了的当没有；放进了请求中心的，上一次没能添加 / 取消了也写「已加入」（和「全部影片 › 可申请」的横卡一样）
        let raw = RequestStore.shared.anyStatus(src: item.src, id: item.id) ?? item.req
        let st = raw?.state == .cancelled ? nil : raw
        let queued = RequestBasket.shared.containsAny(src: item.src, id: item.id)
        let showStatus = st.map { $0.state == .done || $0.state == .active || !queued } ?? false
        ZoomLink(route: .catalog(item.catalogTitle), slot: slot) {
            DSPosterLockup(art: TMDBImage.url(item.poster, "w342"), title: item.title,
                           subtitle: [item.src == "tv" ? "剧集" : "电影", item.year].filter { !$0.isEmpty }.joined(separator: "，"),
                           metrics: metrics)
                .overlay(alignment: .bottomLeading) {
                    if let st, showStatus { badge(st).padding(8) } else if queued { pill("已加入", color: .white).padding(8) }
                }
        }
        .accessibilityIdentifier("catalog-card")
    }

    private func badge(_ s: RequestStatus) -> some View {
        let text = s.state == .done ? "已就绪" : s.state == .failed ? "未能添加" : s.stage == "release" ? "发行审批" : "已请求 \(s.pct)%"
        return pill(text, color: s.state == .failed ? requestRed : .white)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
            .environment(\.colorScheme, .dark)
    }
}

/// 搜索：片库之外，影片库索引里对得上的（「可请求添加」）。showEmpty：片库里一部都没搜到时，这里也没有就说「没有找到」
struct RequestableSearchSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let query: String
    let metrics: DSMetrics
    var showEmpty = false
    /// nil = 还在查
    @State private var items: [CatalogItem]?

    var body: some View {
        content
            // 查到了：那一排（或「没有找到」）淡进来，不是啪地冒出来
            .animation(DSMotion.adapt(DSMotion.fade, reduce: reduceMotion), value: items == nil)
            .task(id: query) {
                items = nil
                guard !DemoData.enabled else { items = []; return }
                try? await Task.sleep(for: .milliseconds(450))     // 打字时不每个字都去问
                guard !Task.isCancelled else { return }
                let r = try? await RequestAPI.catalog(src: "all", query: query)
                guard !Task.isCancelled else { return }
                items = r ?? []
                for i in r ?? [] { if let s = i.req { RequestStore.shared.merge(s) } }
            }
    }

    /// 只淡入、不淡出：换了字重新查时旧的那一排照旧马上收掉（外面的版面不带这个动画，慢慢淡出会和挪上来的东西叠在一起）
    private var fadeIn: AnyTransition { .asymmetric(insertion: .opacity, removal: .identity) }

    @ViewBuilder private var content: some View {
        let movies = model.ownedMovieIDs, shows = model.ownedSeasons
        let list = (items ?? []).filter { !model.owns($0, movies: movies, shows: shows) }
        if !list.isEmpty {
            DSSection(title: "可请求添加", metrics: metrics) {
                DSShelf(metrics: metrics) {
                    ForEach(list.prefix(24), id: \.uid) { it in CatalogPosterLink(item: it, metrics: metrics, slot: "search-request") }
                }
            }
            .transition(fadeIn)
        } else if showEmpty && items != nil {
            ContentUnavailableView {
                Label("没有找到“\(query)”", systemImage: "magnifyingglass")
            } description: {
                Text("请尝试其他片名或年份。")
            } actions: {
                NavigationLink(value: Route.shelf(.all)) {
                    Text("浏览所有影片")
                }
                .accessibilityIdentifier("search-browse-all")
            }
            .padding(.top, 60)
            .transition(fadeIn)
        } else if showEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                .transition(fadeIn)
        } else {
            Color.clear.frame(height: 0)
        }
    }
}

// MARK: - 截图用：演示数据里推进一部「可请求添加」的剧集详情页（-CuvenRequestPreview YES）

#if DEBUG
@MainActor
enum RequestPreview {
    static func presentIfRequested(_ model: AppModel) {
        guard DemoData.enabled, UserDefaults.standard.bool(forKey: "CuvenRequestPreview") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            model.openRequest = .catalog(CatalogTitle(kind: .tv, id: 1399, title: "长夜将明", year: "2025", poster: "demo://poster/12"))
        }
    }
}
#endif
