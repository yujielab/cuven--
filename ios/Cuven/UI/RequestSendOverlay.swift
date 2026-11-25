import SwiftUI
import UIKit

// MARK: - 请求添加：发往请求中心（用户要求「为可申请添加的影片和电视剧添加并更新交互设计与动效并 UI」，
//         上滑或按下申请添加按钮后 → 粒子箭头飞行、屏幕显示「正在发往请求中心」→ 打勾、显示已添加至请求中心和时间）
//
// 照用户发来的 Swipe-to-Send 录屏和四页动效说明排的（金额那一格换成片名）：
//   · 发送中：整屏压暗，下半截一团蓝紫的云，一枚发光的箭头从云里往上飞、越飞越小越柔（SendGlowCanvas 画）；
//     屏幕正中略偏上一行「正在发往请求中心」——说明要求状态行放在光最亮的那一块上面。
//   · 加进去了：一枚勾、片名（剧集后面跟着浅一点的「第 N 季」，像录屏里浅灰的「.00」）、
//     「已添加至请求中心，等待您进一步操作」、添加的时间（「今天 18:22」，本地 24 小时制），
//     下面一颗白色的「好」，再下面一行轻一点的「前往请求中心」。
//     勾出来的那一刻，一圈波从这一组字的中间扩到屏幕圆角（画布画），扫过这一组字时把它们折射一下、RGB 三色错开
//     （sendRefraction，最强在成功后 60–90 毫秒），0.4 秒内恢复清晰；之后屏幕边上留一圈光，慢慢从紫漂向青，勾也跟着漂一点青。
//   · 没加成（请求中心满了、没登录）：不放波，安静地说原因，只有一颗「好」。
// 加进请求中心是本地的、一瞬间的事，所以「发送中」至少停 1.1 秒，让箭头那一段飞得完（说明里发送状态由结果驱动，
// 这里结果来得太快，人看不清发生了什么）。
// 「减弱动态效果」：没有波、没有折射、不缩放不模糊，全换成淡入淡出（画布那边同样收掉）。

/// 要加进请求中心的那一部（剧集带季号；海报给接入的那一边用）
struct RequestSendItem: Equatable {
    let title: String
    let season: Int?
    let poster: URL?
}

/// 加的结果：加进去了 / 早就在请求中心里（都带加进去的时间）/ 没加成（给人看的原因）
enum RequestSendResult: Equatable {
    case added(Date)
    case already(Date)
    case failed(String)
}

/// 整屏的「发往请求中心」。自己管时间线：出现就进「发送中」，拿到结果（并且至少飞了 1.1 秒）再进成功 / 失败。
/// 光铺满整屏（忽略安全区），字留在安全区里；不要在外面再给它加 ignoresSafeArea
struct RequestSendOverlay: View {
    let item: RequestSendItem
    let result: RequestSendResult?
    let onDone: () -> Void
    let onOpenCenter: () -> Void

    init(item: RequestSendItem, result: RequestSendResult?, onDone: @escaping () -> Void, onOpenCenter: @escaping () -> Void) {
        self.item = item
        self.result = result
        self.onDone = onDone
        self.onOpenCenter = onOpenCenter
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Stage { case sending, success, failure }

    @State private var stage: Stage = .sending
    /// 定下来要显示的那个结果（之后外面再改 result 也不换）
    @State private var shown: RequestSendResult?
    @State private var started = false
    /// 已经飞够最短时间
    @State private var held = false
    @State private var sendStart: CFTimeInterval = 0
    @State private var resolvedAt: CFTimeInterval = 0
    /// 成功那一刻（折射的时钟）
    @State private var resolvedDate = Date()
    @State private var labelIn = false
    @State private var visible = false
    @State private var leaving = false
    /// 很久都没等到结果：露出一颗「关闭」，免得整屏卡住
    @State private var stuck = false
    /// 第几次发送（换了一部重新开始时，旧的计时作废）
    @State private var run = 0
    /// 片名的正中（安全区里的坐标）：画布那一道环从这儿往外走
    @State private var ringFocus: CGPoint?

    var body: some View {
        // 这一层的 GeometryReader 不忽略安全区：size 是安全区里的大小，安全区外的光由画布自己铺
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            // 状态行按整屏的比例放（画布的云按整屏画），换算成安全区里的比例
            let statusY = (RequestSendTiming.statusY * full.height - insets.top) / max(1, geo.size.height)
            ZStack {
                RequestSendPalette.ink.ignoresSafeArea()
                canvas(corner: Self.screenCorner(full: full, insets: insets), focus: ringUnit(full: full, insets: insets))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                // 状态行和结果各放各的高度（各自一层）：交叉淡入淡出时，淡出去的那一行不跟着挪
                RequestSendCenterLayout(y: statusY) {
                    if stage == .sending { statusLine.transition(.opacity) }
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                RequestSendCenterLayout(y: RequestSendTiming.focusY) {
                    outcome
                }
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                if stuck && stage == .sending {
                    closeHint.transition(.opacity)
                }
            }
            .coordinateSpace(.named(requestSendRootSpace))
        }
        .opacity(visible ? 1 : 0)
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("request-send-overlay")
        .onAppear { begin() }
        .onChange(of: item) { _, _ in begin() }
        .onChange(of: result) { _, _ in resolveIfReady() }
        // 飞够 1.1 秒以后在这里看结果：onChange 拿的是当下的视图（result 是新的）；
        // task 里抓的是它开始那一刻的视图，result 还是旧的 nil（结果早到时会一直卡在「正在发往请求中心」）
        .onChange(of: held) { _, h in if h { resolveIfReady() } }
        .task(id: run) { await hold(run) }
    }

    // MARK: 画布

    private var glowPhase: SendGlowPhase {
        guard started else { return .idle }
        switch stage {
        case .sending: return .sending(start: sendStart)
        case .success: return .success(sendStart: sendStart, at: resolvedAt)
        case .failure: return .failure(at: resolvedAt)
        }
    }

    /// 只按名字设属性（不靠成员初始化器里参数的先后），画布那边加了别的带默认值的属性也照样能编
    private func canvas(corner: CGFloat, focus: UnitPoint?) -> SendGlowCanvas {
        var c = SendGlowCanvas(phase: glowPhase)
        c.reduceMotion = reduceMotion
        c.cornerRadius = corner
        // 环从片名的正中出发（录屏里环围着金额）；还没量到就用画布自己的默认位置
        if let focus { c.focus = focus }
        return c
    }

    /// 量到的片名正中，换成占整块画布的比例（画布比安全区多出上、左两边那一截）
    private func ringUnit(full: CGSize, insets: EdgeInsets) -> UnitPoint? {
        guard let p = ringFocus, full.width > 0, full.height > 0 else { return nil }
        return UnitPoint(x: (p.x + insets.leading) / full.width, y: (p.y + insets.top) / full.height)
    }

    /// 屏幕圆角（点）：边上那圈光要贴着它走（用户要的「光贴着圆角屏走」；估错十几点，边角会露出一道暗缝）。
    /// 系统没有公开的读法（UIScreen._displayCornerRadius 是私有接口，不用）：iPhone 按屏幕物理像素查已知机型，
    /// 查不到的新机型才按短边的 14% 估；圆角屏的 iPad 18 点；有 Home 键的方屏 0
    @MainActor
    private static func screenCorner(full: CGSize, insets: EdgeInsets) -> CGFloat {
        let short = min(full.width, full.height)
        guard short > 0, insets.bottom > 0 else { return 0 }
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return knownPhoneCorner() ?? min(62, max(39, (short * 0.14).rounded()))
        case .pad: return 18
        default: return 0
        }
    }

    /// 已知 iPhone 的屏幕圆角：按物理像素（竖拿，短 × 长）认机型。「放大显示」时同一块屏点数变少，
    /// 同样的物理圆角折成的点数也按比例变小（标准显示下比例是 1）
    @MainActor
    private static func knownPhoneCorner() -> CGFloat? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let screen = (scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)?.screen else { return nil }
        let px = screen.nativeBounds.size
        let w = Int(min(px.width, px.height).rounded())
        let h = Int(max(px.width, px.height).rounded())
        // 圆角点数，标准显示下的短边点数
        let known: (radius: CGFloat, short: CGFloat)
        switch (w, h) {
        case (1125, 2436): known = (39, 375)     // X / XS / 11 Pro
        case (1242, 2688): known = (39, 414)     // XS Max / 11 Pro Max
        case (828, 1792): known = (41.5, 414)    // XR / 11
        case (1080, 2340): known = (44, 375)     // 12 mini / 13 mini
        case (1170, 2532): known = (47.33, 390)  // 12 / 12 Pro / 13 / 13 Pro / 14 / 16e
        case (1284, 2778): known = (53.33, 428)  // 12 Pro Max / 13 Pro Max / 14 Plus
        case (1179, 2556): known = (55, 393)     // 14 Pro / 15 / 15 Pro / 16
        case (1290, 2796): known = (55, 430)     // 14 Pro Max / 15 Plus / 15 Pro Max / 16 Plus
        case (1206, 2622): known = (62, 402)     // 16 Pro
        case (1320, 2868): known = (62, 440)     // 16 Pro Max
        default: return nil
        }
        let short = min(screen.bounds.width, screen.bounds.height)
        guard short > 0 else { return known.radius }
        return known.radius * min(1, max(0.7, short / known.short))
    }

    // MARK: 中间那一组

    @ViewBuilder
    private var outcome: some View {
        if stage != .sending, let shown {
            switch shown {
            case .added(let at):
                confirmation(at: at, already: false)
            case .already(let at):
                confirmation(at: at, already: true)
            case .failed(let why):
                RequestSendFailure(item: item, reason: why, reduceMotion: reduceMotion, done: { finish(onDone) })
                    .transition(.opacity)
            }
        }
    }

    /// 「正在发往请求中心」：松手后 0.15 秒起、0.45 秒淡入并略升（说明：armed release 450–650 毫秒里状态行淡入）
    private var statusLine: some View {
        Text("正在发往\(Text("请求中心").foregroundStyle(RequestSendPalette.periwinkle))")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .opacity(labelIn ? 1 : 0)
            .offset(y: labelIn || reduceMotion ? 0 : 12)
            .blur(radius: labelIn || reduceMotion ? 0 : 6)
            .accessibilityIdentifier("request-send-status")
    }

    private func confirmation(at: Date, already: Bool) -> some View {
        RequestSendConfirmation(item: item, added: at, already: already, since: resolvedDate, reduceMotion: reduceMotion,
                                done: { finish(onDone) }, openCenter: { finish(onOpenCenter) }, onFocus: { ringFocus = $0 })
            .transition(.opacity)
    }

    /// 等了很久还没有结果（本地加入不该发生）：底下露出一颗轻的「关闭」
    private var closeHint: some View {
        VStack {
            Spacer(minLength: 0)
            Button { finish(onDone) } label: {
                Text("关闭")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DSInk.secondary)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("request-send-close")
            .padding(.bottom, 16)
        }
    }

    // MARK: 时间线

    private func begin() {
        run += 1
        started = true
        stage = .sending
        shown = nil
        held = false
        stuck = false
        leaving = false
        ringFocus = nil
        sendStart = CACurrentMediaTime()
        // 状态行先不带动画地归零；淡入放到 hold() 里（这一下提交以后才跑），重来一遍时也照样从下面淡入升起（用户要的那一段）
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { labelIn = false }
        withAnimation(.easeOut(duration: RequestSendTiming.enter)) { visible = true }
        // 第一次盖上来时旁白自己会落到「正在发往请求中心」那一行上念出来，不再另外念一遍；
        // 换了一部重来时原先那一组没了，焦点无处可落，才念一声
        if run > 1 { announce("正在发往请求中心", after: 0.3) }
    }

    /// 状态行淡入；至少飞 1.1 秒再看结果（交给 onChange(of: held)）；8 秒多还没有结果就露出「关闭」
    private func hold(_ id: Int) async {
        guard id > 0 else { return }
        // 说明：松手后 0.15 秒起、0.45 秒里状态行淡入并略升
        let label: Animation = reduceMotion ? Animation.easeOut(duration: 0.3) : Animation.easeOut(duration: 0.45).delay(0.15)
        withAnimation(label) { labelIn = true }
        try? await Task.sleep(for: .seconds(RequestSendTiming.minSending))
        guard !Task.isCancelled, id == run else { return }
        // 只记下「飞够了」，不在这里读 result（这个 task 抓的是旧视图）
        held = true
        try? await Task.sleep(for: .seconds(RequestSendTiming.stuckAfter))
        guard !Task.isCancelled, id == run, stage == .sending else { return }
        withAnimation(.easeOut(duration: 0.3)) { stuck = true }
    }

    private func resolveIfReady() {
        guard started, stage == .sending, held, !leaving, let r = result else { return }
        shown = r
        resolvedAt = CACurrentMediaTime()
        resolvedDate = Date()
        switch r {
        case .added, .already:
            // 说明：0–150 毫秒里勾和片名就到位，「浮现」那一下交给折射（最强在 60–90 毫秒），所以这一组几乎立刻淡入
            withAnimation(.easeOut(duration: reduceMotion ? 0.3 : 0.06)) { stage = .success }
            Haptics.success()
            // 两种都照用户给的那句说（早就在里面的，时间那一行写「添加于 …」）
            announce("已添加至请求中心：\(item.spoken)", after: 0.1)
        case .failed(let why):
            withAnimation(.easeInOut(duration: 0.35)) { stage = .failure }
            Haptics.error()
            announce("未能添加：\(why)", after: 0.1)
        }
    }

    /// 「好」「前往请求中心」：先淡出（露出底下的页面），再交给外面收起
    private func finish(_ action: @escaping () -> Void) {
        guard !leaving else { return }
        leaving = true
        withAnimation(.easeIn(duration: RequestSendTiming.exit)) { visible = false }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(RequestSendTiming.exit))
            action()
        }
    }

    private func announce(_ text: String, after delay: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            // 排队念：旁白正在念（换屏后重新落焦点）时不打断、也不被吞掉
            let queued = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            UIAccessibility.post(notification: .announcement, argument: queued)
        }
    }
}

// MARK: - 成功那一组：勾 · 片名 · 一行说明 · 时间 · 好 · 前往请求中心

private struct RequestSendConfirmation: View {
    let item: RequestSendItem
    let added: Date
    let already: Bool
    /// 成功那一刻：折射按它走
    let since: Date
    let reduceMotion: Bool
    let done: () -> Void
    let openCenter: () -> Void
    /// 片名的正中在整个浮层（安全区）里的位置：交给画布，让环从这儿出发
    let onFocus: (CGPoint) -> Void
    /// 时间那一行（用户要求显示添加的时间）：建这一组时排一次；折射那半秒里每帧都重画，不要每帧新建 DateFormatter
    private let timeLine: String

    // 写明初始化器：下面有 private 的存储属性，自动合成的成员初始化器会变成 private，同一文件里的 RequestSendOverlay 用不了
    init(item: RequestSendItem, added: Date, already: Bool, since: Date, reduceMotion: Bool,
         done: @escaping () -> Void, openCenter: @escaping () -> Void, onFocus: @escaping (CGPoint) -> Void) {
        self.item = item
        self.added = added
        self.already = already
        self.since = since
        self.reduceMotion = reduceMotion
        self.done = done
        self.openCenter = openCenter
        self.onFocus = onFocus
        let t = RequestSendTime.text(added)
        // 早就在请求中心里的：只在时间前面写「添加于」点明是先前加的
        self.timeLine = already ? "添加于 \(t)" : t
    }

    @State var onset = false
    /// 折射那一段还在走（之后时间线停下，不再每帧重画）
    @State var waving = true
    /// 落定以后勾慢慢漂向青（跟屏幕边上那圈光一起：录屏 7 秒时勾和边都偏青了）
    @State var drift = false
    /// 片名的正中（在加了余量的这一组里的坐标）：波和折射从这里出发
    @State var focus: CGPoint = .zero
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ScaledMetric(relativeTo: .largeTitle) private var checkSize: CGFloat = 46

    var body: some View {
        TimelineView(.animation(minimumInterval: Compat.legacyDevice ? 1.0 / 30 : nil, paused: reduceMotion || !waving)) { tl in
            let t = max(0, tl.date.timeIntervalSince(since))
            group
                // 四周留出余量：RGB 错开、往外推的那几个像素要有地方画（画完再收回来，不占版面）
                .padding(RequestSendTiming.fringe)
                .coordinateSpace(.named(requestSendSpace))
                .sendRefraction(time: t, center: focus,
                                active: !reduceMotion && waving && focus != .zero && t < RequestSendTiming.refractEnd)
                .padding(-RequestSendTiming.fringe)
        }
        .onAppear { onset = true }
        .task {
            guard !reduceMotion else { waving = false; return }
            try? await Task.sleep(for: .seconds(RequestSendTiming.refractEnd + 0.05))
            guard !Task.isCancelled else { return }
            waving = false
            try? await Task.sleep(for: .seconds(RequestSendTiming.settle - RequestSendTiming.refractEnd))
            guard !Task.isCancelled else { return }
            drift = true
        }
    }

    /// 横拿的手机（矮）：勾小一点、间距紧一点，整组放得下
    private var tight: Bool { verticalSizeClass == .compact }

    private func motion(_ a: Animation) -> Animation { DSMotion.adapt(a, reduce: reduceMotion) }

    private var group: some View {
        VStack(spacing: 0) {
            check
            texts
            buttons
        }
        .frame(maxWidth: RequestSendTiming.maxWidth)
        .padding(.horizontal, 28)
    }

    /// 勾：成功后 0.12 秒画出来（说明：0–150 毫秒里勾和金额出现，60–90 毫秒折射最强时已经差不多画完），带一点紫的光晕
    private var check: some View {
        let size = tight ? min(checkSize, 34) : checkSize
        let draw: Animation? = reduceMotion ? nil : Animation.easeOut(duration: 0.12)
        return RequestSendCheck(size: size, drawn: onset || reduceMotion ? 1 : 0, cyan: drift ? 0.8 : 0)
            .animation(draw, value: onset)
            .animation(.easeInOut(duration: 3.1), value: drift)
            .scaleEffect(onset || reduceMotion ? 1 : 0.82)
            .opacity(onset ? 1 : 0)
            .animation(motion(.spring(response: 0.18, dampingFraction: 0.72)), value: onset)
            .padding(.bottom, tight ? 10 : 18)
            .accessibilityHidden(true)
    }

    private var titleText: Text {
        guard let s = item.season else { return Text(item.title) }
        return Text("\(Text(item.title)) \(Text("第 \(s) 季").foregroundStyle(RequestSendPalette.dim))")
    }

    /// 用户给的原话：「已添加至请求中心，等待您进一步操作」（早就在里面的也一样，时间那一行写「添加于」）
    private var lineText: Text {
        let centre = Text("请求中心").foregroundStyle(Color.white).fontWeight(.semibold)
        return Text("已添加至\(centre)，等待您进一步操作")
    }

    private var texts: some View {
        VStack(spacing: 0) {
            titleText
                .font((tight ? Font.title : Font.largeTitle).weight(.semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let f = proxy.frame(in: .named(requestSendSpace))
                    return CGPoint(x: f.midX, y: f.midY)
                } action: { focus = $0 }
                .onGeometryChange(for: CGPoint.self) { proxy in
                    let f = proxy.frame(in: .named(requestSendRootSpace))
                    return CGPoint(x: f.midX, y: f.midY)
                } action: { onFocus($0) }
                // 0.1 秒就清楚（只带一点点模糊）：折射最强那一刻（60–90 毫秒）片名已经看得见，RGB 错开才显得出来
                .opacity(onset ? 1 : 0)
                .blur(radius: onset || reduceMotion ? 0 : 3)
                .scaleEffect(onset || reduceMotion ? 1 : 0.97)
                .animation(motion(.easeOut(duration: 0.1)), value: onset)
                .padding(.bottom, 10)
            VStack(spacing: 4) {
                lineText
                    .font(.subheadline)
                    .foregroundStyle(DSInk.secondary)
                Text(timeLine)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(DSInk.tertiary)
            }
            .multilineTextAlignment(.center)
            .opacity(onset ? 1 : 0)
            .animation(motion(.easeOut(duration: 0.12)).delay(reduceMotion ? 0 : 0.02), value: onset)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("request-send-message")
    }

    private var buttons: some View {
        VStack(spacing: tight ? 0 : 6) {
            Button("好") { done() }
                .buttonStyle(RequestSendPillStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("request-send-done")
            Button { openCenter() } label: {
                Text("前往请求中心")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DSInk.secondary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("request-send-open-center")
        }
        .padding(.top, tight ? 16 : 30)
        // 波大约 0.12–0.16 秒扫到「好」：那时它得已经亮出来，才有录屏里「Got it」被折射、发亮的那一下
        .opacity(onset ? 1 : 0)
        .offset(y: onset || reduceMotion ? 0 : 10)
        .animation(motion(.easeOut(duration: 0.14)).delay(reduceMotion ? 0 : 0.04), value: onset)
    }
}

// MARK: - 没加成：安静地说原因

private struct RequestSendFailure: View {
    let item: RequestSendItem
    let reason: String
    let reduceMotion: Bool
    let done: () -> Void

    init(item: RequestSendItem, reason: String, reduceMotion: Bool, done: @escaping () -> Void) {
        self.item = item
        self.reason = reason
        self.reduceMotion = reduceMotion
        self.done = done
    }

    @State var onset = false

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.circle")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(RequestSendPalette.lilac)
                .padding(.bottom, 16)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("未能添加至请求中心")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
                Text(item.spoken)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DSInk.secondary)
                    .lineLimit(2)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(DSInk.secondary)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("request-send-message")
            Button("好") { done() }
                .buttonStyle(RequestSendPillStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("request-send-done")
                .padding(.top, 28)
        }
        .frame(maxWidth: RequestSendTiming.maxWidth)
        .padding(.horizontal, 28)
        .opacity(onset ? 1 : 0)
        .offset(y: onset || reduceMotion ? 0 : 8)
        .animation(DSMotion.adapt(.easeOut(duration: 0.35), reduce: reduceMotion), value: onset)
        .onAppear { onset = true }
    }
}

// MARK: - 零件

/// 勾：紫到白的渐变（录屏里勾的下半截偏粉紫、上端发白），上面叠一层青到白的，落定后慢慢浮出来
private struct RequestSendCheck: View {
    let size: CGFloat
    var drawn: CGFloat
    var cyan: Double

    var body: some View {
        let style = StrokeStyle(lineWidth: max(2.5, size * 0.1), lineCap: .round, lineJoin: .round)
        ZStack {
            RequestSendCheckShape()
                .trim(from: 0, to: drawn)
                .stroke(LinearGradient(colors: [RequestSendPalette.lilac, Color.white], startPoint: .bottomLeading, endPoint: .topTrailing),
                        style: style)
            RequestSendCheckShape()
                .trim(from: 0, to: drawn)
                .stroke(LinearGradient(colors: [RequestSendPalette.cyan, Color.white], startPoint: .bottomLeading, endPoint: .topTrailing),
                        style: style)
                .opacity(cyan)
        }
        .frame(width: size, height: size)
        .shadow(color: RequestSendPalette.violet.opacity(0.5), radius: size * 0.16)
    }
}

/// 勾的笔画：左边短的一笔落下，再往右上长长地一挑
private struct RequestSendCheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.54))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.39, y: r.minY + r.height * 0.80))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.90, y: r.minY + r.height * 0.20))
        return p
    }
}

/// 白底黑字的「好」（录屏里的「Got it」），按下缩一点
private struct RequestSendPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.black)
            .lineLimit(1)
            .padding(.horizontal, 30)
            .frame(minWidth: 112, minHeight: 48)
            .background(Capsule().fill(Color.white))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(DSMotion.press, value: configuration.isPressed)
    }
}

/// 把子视图的正中放在容器高度的 y 处（放不下就贴着上下边），横向居中：录屏里内容在屏幕正中略偏上
private struct RequestSendCenterLayout: Layout {
    var y: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            let fit = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let h = min(fit.height, bounds.height)
            let top = min(max(bounds.minY, bounds.minY + bounds.height * y - h / 2), bounds.maxY - h)
            s.place(at: CGPoint(x: bounds.midX, y: top), anchor: .top, proposal: ProposedViewSize(width: bounds.width, height: h))
        }
    }
}

/// 加了余量的成功那一组的坐标系名字（折射的中心按它量）
private let requestSendSpace = "request-send-confirmation"
/// 整个浮层（安全区那一块）的坐标系名字（环的中心按它量）
private let requestSendRootSpace = "request-send-root"

/// 时间和尺寸（说明里的建议值）
private enum RequestSendTiming {
    /// 「发送中」至少停这么久，箭头那一段才飞得完
    static let minSending: Double = 1.1
    /// 再等这么久还没有结果就露出「关闭」
    static let stuckAfter: Double = 7
    /// 折射在这之前走完（最强在 60–90 毫秒，0.4 秒左右散干净）
    static let refractEnd: Double = 0.45
    /// 落定（说明：700–850 毫秒）；0.9 秒起勾慢慢漂青，和画布边缘光往青漂（0.9–4.0 秒）同一段
    static let settle: Double = 0.9
    static let enter: Double = 0.28
    static let exit: Double = 0.22
    /// 中间那一组的正中放在安全区高度的这里（略高于正中）
    static let focusY: CGFloat = 0.47
    /// 「正在发往请求中心」占整屏高的位置：在云顶（画布里约 0.50 屏高）上面、光最亮的那一块之上（设计说明 Sending composition）
    static let statusY: CGFloat = 0.42
    /// iPad、展开的 Duo：这一组不随屏变宽
    static let maxWidth: CGFloat = 440
    /// 折射的余量（点）
    static let fringe: CGFloat = 56
}

/// 说明里的起始配色：墨 #0B0B12、紫 #8268FF、青 #71D9FF；另两种是字和勾用的浅色
private enum RequestSendPalette {
    static let ink = Color(red: 11 / 255, green: 11 / 255, blue: 18 / 255)
    static let violet = Color(red: 130 / 255, green: 104 / 255, blue: 255 / 255)
    static let cyan = Color(red: 113 / 255, green: 217 / 255, blue: 255 / 255)
    /// 勾的下半截（录屏里偏粉的淡紫）
    static let lilac = Color(red: 0.80, green: 0.72, blue: 1.0)
    /// 状态行里的「请求中心」（录屏里收款人名字那种蓝紫）
    static let periwinkle = Color(red: 0.62, green: 0.67, blue: 1.0)
    /// 片名后面的「第 N 季」（录屏里浅灰的「.00」）
    static let dim = Color.white.opacity(0.5)
}

/// 添加的时间：「今天 18:22」「昨天 09:05」「11月20日 18:22」「2025年11月20日 18:22」——本地时间、24 小时制（用户要求显示时间）
enum RequestSendTime {
    static func text(_ date: Date, now: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm"
        let hm = f.string(from: date)
        if cal.isDate(date, inSameDayAs: now) { return "今天 \(hm)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "昨天 \(hm)" }
        f.dateFormat = cal.isDate(date, equalTo: now, toGranularity: .year) ? "M月d日 HH:mm" : "y年M月d日 HH:mm"
        return f.string(from: date)
    }
}

private extension RequestSendItem {
    /// 念给旁白、写在失败页上的名字：剧集带「第 N 季」
    var spoken: String {
        guard let s = season else { return title }
        return "\(title) 第 \(s) 季"
    }
}
