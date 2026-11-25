import SwiftUI

// MARK: - 新登录页：落地页「ideas in motion.」
//
// 用户要求新登录页的内容：标题「ideas in motion.」、说明「Cuven Max为充满好奇心的灵魂而专门设计并精心调整以提供超高品质的影片内容」、
// 两颗按钮「使用光学配对登录」「使用账号密码登录」；UI、动效和其他细节照用户发的 Brink 录屏和 PDF 做。
// 三层，从下往上：
// · LoginCoverPlane（LoginCoverPlane.swift）：黑底、顶部柔光（1.27 秒）、三列海报从灵动岛下面沿一个斜平面推过来（1.33 秒起，一直流动），
//   上面压着从 40% 屏高开始变暗、65%–72% 收黑的渐变。
// · 前景（这个文件）：标题、说明、两颗胶囊按钮。0.5 秒起整组从屏底带模糊上浮，约 0.72 秒越过落点、0.83 秒高出约 2% 屏高，
//   1.17 秒落稳（PDF「登录组上浮与回落」；中间值是录屏 60 帧逐帧量的主按钮上沿）。
// · BrandCollapseLayer（LoginIntro.swift）：整屏品牌蓝 + 白色「Cuven max」字标，0.5 秒起收束成落在 iconRect 的图标。
//   底板压在前景上面（录屏 0.67 秒：底板挡住标题中间那几个字）。
// 只有一条时间线（TimelineView）：开场 1.17 秒里三层一起按它走；之后前景和图标不再变（不重算），只有封面平面接着走；
// 场景不在前台、落地页被账号密码流程或粒子云盖住时停下来，停着的那段不算时间（回来接着放，开场不会被跳过）。
// 减弱动态效果：画面定下来以后时间线整个停掉。
// 落点（占整屏，Y 从屏顶算；PDF 第 3 页 D）：图标中心 54%、宽 21% 屏宽；标题中心 64%；按钮宽 86%，主按钮上沿 80%、次按钮上沿 87%。
// 宽窗口（iPad、iPhone Duo 展开）：图标最大 120、按钮最宽 440、文字最宽 520，竖向比例不变；iPhone Duo 折起照手机的比例
// （横向在安全区里居中，侧边那一列不算）；矮横屏（高不到 500）从按钮往上排。
// 旁白：只念标题、说明、两颗按钮（开场和封面不进旁白）。动态字体放到 xxLarge 为止。
// 减弱动态效果：不做形变（整屏品牌 0.3 秒淡成图标）、前景同时淡入、不上浮不模糊；封面静止（或很慢）。

/// UI 测试 / 截图：-CuvenLoginLanding YES —— 演示数据、已登录时也盖上登录层，从落地页开始（和 -CuvenWelcome 一样读启动参数）
enum LoginLandingFlag {
    static var forced: Bool { UserDefaults.standard.bool(forKey: "CuvenLoginLanding") }
}

struct LoginLanding: View {
    let onPair: () -> Void
    let onAccount: () -> Void
    /// 落地页在不在屏幕上：进了账号密码流程、粒子云盖着的时候传 false，时间线停下来（回来时封面接着流动，开场不重放）
    var active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// 落地页出现的那一刻：所有时间都从这里算（停着的那段时间不算：恢复时把它往后挪，见 hold）
    @State private var start = Date()
    /// 时间线停下的那一刻；停着的时候时间就截在这里
    @State private var pausedAt: Date?
    @State private var begun = false
    /// 开场和封面入场都放完了（按放了多久算，停着的不算）：减弱动态效果时画面从此不变，时间线停掉
    @State private var introDone = false
    /// 时间线走不走：active 变 false 以后再走半秒（落地页淡出、粒子云往上盖的那一段里封面还在流动），然后停
    @State private var running = true
    /// 量到的标题一行高、标题 + 说明整块高（动态字体放大、说明折成好几行时据此把字和图标往上挪，不压到按钮）
    @State private var titleHeight: CGFloat = 0
    @State private var textHeight: CGFloat = 0

    init(onPair: @escaping () -> Void, onAccount: @escaping () -> Void, active: Bool = true) {
        self.onPair = onPair
        self.onAccount = onAccount
        self.active = active
    }

    var body: some View {
        // 海报单子在时间线外面读：减弱动态效果时时间线停了，单子后到也要把那一帧刷新一次
        let covers = LoginCovers.shared.urls
        GeometryReader { geo in
            // 按整个屏幕排（PDF 的百分比都是整屏的）：把安全区加回来，整块摆回屏幕原点（和 LoginScreen 同一种做法）
            let ins = geo.safeAreaInsets
            let size = CGSize(width: geo.size.width + ins.leading + ins.trailing,
                              height: geo.size.height + ins.top + ins.bottom)
            let layout = LoginLandingLayout(size: size, safe: ins).fitted(titleHeight: titleHeight, textHeight: textHeight)
            let still = reduceMotion && introDone
            TimelineView(.animation(minimumInterval: frameInterval, paused: !running || scenePhase != .active || still)) { tl in
                // 停着的时候时间截在停下那一刻（恢复的那一帧 start 还没挪，也不会跳一下）；
                // 减弱动态效果放完以后画面不再变，给一个放完以后的固定时间（不靠停住的时间线给的日期）
                let t = still ? 3 : max(0, (pausedAt ?? tl.date).timeIntervalSince(start))
                scene(t: t, size: size, layout: layout, covers: covers)
            }
            .frame(width: size.width, height: size.height)
            .position(x: geo.size.width / 2 + (ins.trailing - ins.leading) / 2,
                      y: geo.size.height / 2 + (ins.bottom - ins.top) / 2)
        }
        .ignoresSafeArea(.keyboard)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("login-landing")
        .onAppear {
            if !begun {
                // 冷启动时第一帧可能晚一点才上屏、场景也可能还没到前台：时钟从真正出现、到了前台才开始走，0.5 秒的品牌整屏不被吃掉
                let now = Date()
                begun = true
                start = now
                pausedAt = scenePhase == .active ? nil : now
            } else {
                hold(!running || scenePhase != .active)
            }
        }
        // 粒子云整屏盖上来时这一层会被移出窗口：那段也不算时间
        .onDisappear { hold(true) }
        .onChange(of: scenePhase) { _, p in hold(p != .active || !running) }
        .onChange(of: running) { _, r in hold(scenePhase != .active || !r) }
        // 封面：本机缓存的海报地址先用上（下次打开立刻有），后台再刷新（LoginCovers）
        .task { await LoginCovers.shared.load() }
        .task {
            // 开场按「放了多久」算：停着的时候不往前走，放够 3 秒才算放完
            while !introDone && !Task.isCancelled {
                let left = 3 - (pausedAt ?? Date()).timeIntervalSince(start)
                if left <= 0 {
                    introDone = true
                    break
                }
                try? await Task.sleep(for: .seconds(max(0.2, left)))
            }
        }
        .task(id: active) {
            if active {
                running = true
            } else {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { running = false }
            }
        }
    }

    /// 用户要的开场不能被打断吃掉：停着的那段时间不算（首次联网的系统弹窗、拉下控制中心、进了账号密码流程），回来接着放
    private func hold(_ paused: Bool) {
        if paused {
            if pausedAt == nil { pausedAt = Date() }
        } else if let p = pausedAt {
            start = start.addingTimeInterval(Date().timeIntervalSince(p))
            pausedAt = nil
        }
    }

    /// 旧机型（Compat.legacyDevice）最多 60 帧；别的跟屏幕走（ProMotion 120）
    private var frameInterval: Double? {
        Compat.legacyDevice ? 1.0 / 60 : nil
    }

    private func scene(t: Double, size: CGSize, layout: LoginLandingLayout, covers: [URL]) -> some View {
        // 用户要的封面从图标那条中轴涌出：iPhone Duo 折起时前景在安全区里居中，平面跟着挪，两边加宽不露边
        let dx = layout.centerX - size.width / 2
        let plane = CGSize(width: size.width + abs(dx) * 2, height: size.height)
        return ZStack(alignment: .topLeading) {
            Color.black
            LoginCoverPlane(t: t, size: plane, covers: covers, reduceMotion: reduceMotion)
                .frame(width: plane.width, height: plane.height)
                .offset(x: dx - abs(dx))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            // 前景只在开场那 1.17 秒里变：时间截住以后每帧传进去的都一样，SwiftUI 不再重算它（Equatable）
            LoginLandingForeground(t: min(t, LandingRise.frozen), layout: layout, reduceMotion: reduceMotion,
                                   onPair: onPair, onAccount: onAccount,
                                   measured: { kind, v in measure(kind, v) })
                .equatable()
                // 动态字体放到 xxLarge 为止（标题一行、按钮一行，再大就挤了）
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            // 品牌底板压在前景上面；落稳以后姿态不变，时间同样截住
            BrandCollapseLayer(t: min(t, 2), size: size, target: layout.iconRect, reduceMotion: reduceMotion)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    private func measure(_ kind: LandingMeasure, _ v: CGFloat) {
        switch kind {
        case .title: if abs(titleHeight - v) > 0.5 { titleHeight = v }
        case .text: if abs(textHeight - v) > 0.5 { textHeight = v }
        }
    }
}

// MARK: - 排版

/// 落地页的落点（坐标原点是屏幕左上角，按整屏算；安全区只用来让开状态栏、底部横条和 iPhone Duo 侧边那一列）
struct LoginLandingLayout: Equatable, Sendable {
    /// 图标落点（BrandCollapseLayer 的 target）
    var iconRect: CGRect
    /// 标题一行的中心
    var titleCenterY: CGFloat
    /// 主按钮、次按钮的上沿
    var primaryTop: CGFloat
    var secondaryTop: CGFloat
    var buttonWidth: CGFloat
    var buttonHeight: CGFloat

    /// 整屏大小
    var size: CGSize
    /// 前景的中轴：安全区里居中（iPhone Duo 折起时侧边那一列不算）
    var centerX: CGFloat
    var textWidth: CGFloat
    /// 标题 + 说明这一块的上沿
    var textTop: CGFloat
    /// 标题和说明之间
    var textGap: CGFloat
    /// 字号（动态字体在前景里再乘上去）
    var titleSize: CGFloat
    var bodySize: CGFloat
    var labelSize: CGFloat
    /// 矮横屏：从按钮往上排
    var compact: Bool

    private var safeTop: CGFloat
    /// 照 PDF 比例算出来的位置（fitted 每次都从这里出发）
    private var nominalTitleY: CGFloat
    private var nominalIcon: CGRect

    init(size: CGSize, safe: EdgeInsets) {
        let W = max(1, size.width), H = max(1, size.height)
        let left = max(0, safe.leading), right = max(0, safe.trailing)
        let avail = max(1, W - left - right)
        let minSide = min(W, H)
        let compact = W > H && H < 500
        let cx = left + avail / 2
        // 参考是 402 宽的手机：标题 28 粗、说明 16、按钮字 17 半粗；iPad 上到 34 / 18 / 18 为止
        let titleSize = min(34, max(24, minSide * 0.07))
        let bodySize = min(18, max(15, minSide * 0.04))
        // 按钮高约 6.3% 屏高（参考 55 点），两颗之间约 0.75% 屏高（参考 6.6 点）
        let bh = min(56, max(compact ? 44 : 50, H * 0.063))
        let gap = min(10, max(6, H * 0.0075))
        // 图标宽 21% 屏宽，最大 120；矮的窗口按高再限一下
        let side = max(44, min(W * 0.21, 120, H * 0.15))
        let bottomLimit = H - max(safe.bottom + 10, 20)
        var primary: CGFloat
        var secondary: CGFloat
        if compact {
            secondary = bottomLimit - bh
            primary = secondary - gap - bh
        } else {
            primary = H * 0.80
            secondary = primary + bh + gap
            // 矮一点的手机（SE）：次按钮别压到底边，两颗一起往上让
            let over = secondary + bh - bottomLimit
            if over > 0 { primary -= over; secondary -= over }
        }
        let icon = CGRect(x: cx - side / 2, y: H * 0.54 - side / 2, width: side, height: side)

        self.size = CGSize(width: W, height: H)
        self.compact = compact
        self.centerX = cx
        self.titleSize = titleSize
        self.bodySize = bodySize
        self.labelSize = min(18, max(16, minSide * 0.043))
        // 标题和说明之间：照用户发的录屏量（标题基线到说明第一行基线约 41 点），手机上约 19 点
        self.textGap = (titleSize * 0.66).rounded()
        self.buttonWidth = min(440, avail * 0.86)
        self.textWidth = min(520, avail * 0.86)
        self.buttonHeight = bh
        self.primaryTop = primary
        self.secondaryTop = secondary
        self.titleCenterY = H * 0.64
        self.textTop = H * 0.64 - titleSize * 0.6
        self.iconRect = icon
        self.safeTop = max(0, safe.top)
        self.nominalTitleY = H * 0.64
        self.nominalIcon = icon
        // 还没量到字的时候按估计的高先排一遍
        self = fitted(titleHeight: 0, textHeight: 0)
    }

    private var estimatedTitleHeight: CGFloat { titleSize * 1.2 }
    private var estimatedTextHeight: CGFloat { estimatedTitleHeight + textGap + bodySize * 1.45 * 2 }

    /// 按量到的字高再排一遍：说明折成好几行（动态字体放大、窄窗口）时字往上让，图标跟着让，都不压到按钮
    func fitted(titleHeight: CGFloat, textHeight: CGFloat) -> LoginLandingLayout {
        var L = self
        let th = titleHeight > 1 ? titleHeight : estimatedTitleHeight
        let block = max(th, textHeight > 1 ? textHeight : estimatedTextHeight)
        let iconGap: CGFloat = compact ? 12 : 14
        L.iconRect = nominalIcon
        if compact {
            // 矮横屏：字块底边离主按钮 16，图标贴在字块上面
            L.textTop = primaryTop - 16 - block
            L.iconRect.origin.y = L.textTop - iconGap - L.iconRect.height
        } else {
            L.textTop = nominalTitleY - th / 2
            let over = L.textTop + block - (primaryTop - 18)
            if over > 0 {
                L.textTop -= over
                L.iconRect.origin.y -= over
            }
            let clash = L.iconRect.maxY - (L.textTop - iconGap)
            if clash > 0 { L.iconRect.origin.y -= clash }
        }
        // 图标顶到状态栏了：贴着字块上面放，缩小一点（最小 36）
        let topLimit = safeTop + 8
        if L.iconRect.minY < topLimit {
            let room = L.textTop - iconGap - topLimit
            let s = max(36, min(L.iconRect.width, room))
            L.iconRect = CGRect(x: centerX - s / 2, y: L.textTop - iconGap - s, width: s, height: s)
        }
        L.titleCenterY = L.textTop + th / 2
        return L
    }
}

// MARK: - 前景：标题、说明、两颗按钮

private enum LandingMeasure { case title, text }

private struct LoginLandingForeground: View, Equatable {
    /// 截住的时间（开场放完以后恒定）
    let t: Double
    let layout: LoginLandingLayout
    let reduceMotion: Bool
    let onPair: () -> Void
    let onAccount: () -> Void
    let measured: (LandingMeasure, CGFloat) -> Void

    /// 动态字体：字号按系统设置放大（外面限到 xxLarge）
    @ScaledMetric(relativeTo: .title) private var titleScale: CGFloat = 100
    @ScaledMetric(relativeTo: .body) private var bodyScale: CGFloat = 100

    init(t: Double, layout: LoginLandingLayout, reduceMotion: Bool, onPair: @escaping () -> Void,
         onAccount: @escaping () -> Void, measured: @escaping (LandingMeasure, CGFloat) -> Void) {
        self.t = t
        self.layout = layout
        self.reduceMotion = reduceMotion
        self.onPair = onPair
        self.onAccount = onAccount
        self.measured = measured
    }

    /// 只比数值（回调不比）：开场放完以后每帧都相等，不再重算
    nonisolated static func == (a: LoginLandingForeground, b: LoginLandingForeground) -> Bool {
        a.t == b.t && a.layout == b.layout && a.reduceMotion == b.reduceMotion
    }

    var body: some View {
        let L = layout
        let kt = titleScale / 100
        let kb = bodyScale / 100
        let fx = LandingRise.fx(t, reduceMotion: reduceMotion)
        ZStack(alignment: .topLeading) {
            VStack(spacing: (L.textGap * kb).rounded()) {
                Text("ideas in motion.")
                    .font(.system(size: L.titleSize * kt, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilitySortPriority(4)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { v in measured(.title, v) }
                Text("Cuven Max为充满好奇心的灵魂而专门设计并精心调整以提供超高品质的影片内容")
                    .font(.system(size: L.bodySize * kb))
                    .foregroundStyle(LandingInk.body)
                    .multilineTextAlignment(.center)
                    .lineSpacing(L.bodySize * kb * 0.22)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilitySortPriority(3)
            }
            .frame(width: L.textWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { v in measured(.text, v) }
            .offset(x: L.centerX - L.textWidth / 2, y: L.textTop)

            LandingButton(title: "使用光学配对登录", primary: true, fontSize: L.labelSize * kb,
                          width: L.buttonWidth, height: L.buttonHeight, action: onPair)
                .accessibilityIdentifier("login-pair-button")
                .accessibilitySortPriority(2)
                .offset(x: L.centerX - L.buttonWidth / 2, y: L.primaryTop)
            LandingButton(title: "使用账号密码登录", primary: false, fontSize: L.labelSize * kb,
                          width: L.buttonWidth, height: L.buttonHeight, action: onAccount)
                .accessibilityIdentifier("login-account-button")
                .accessibilitySortPriority(1)
                .offset(x: L.centerX - L.buttonWidth / 2, y: L.secondaryTop)
        }
        .frame(width: L.size.width, height: L.size.height, alignment: .topLeading)
        // 整组一起上浮、去模糊、淡入（PDF：文案和按钮带模糊从底部上浮，主按钮越过落点约 2% 屏高再回落）
        .offset(y: CGFloat(fx.dy) * L.size.height)
        .blur(radius: CGFloat(fx.blur))
        .opacity(fx.opacity)
        // 还看不清的时候不接触摸
        .allowsHitTesting(fx.opacity > 0.6)
    }
}

/// 胶囊按钮：主按钮近白底黑字，次按钮深灰底白字（一圈很淡的亮边）；按下缩到 0.98、底色压深
private struct LandingButton: View {
    let title: String
    let primary: Bool
    let fontSize: CGFloat
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 20)
                .frame(width: width, height: height)
                .contentShape(Capsule())
        }
        .buttonStyle(LandingButtonStyle(primary: primary))
    }
}

private struct LandingButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        let fill: Color = primary ? (down ? LandingInk.primaryDown : LandingInk.primary)
                                  : (down ? LandingInk.secondaryDown : LandingInk.secondary)
        configuration.label
            .foregroundStyle(primary ? Color.black : Color.white)
            .background { Capsule().fill(fill) }
            .overlay {
                if !primary {
                    Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
            }
            .scaleEffect(down ? 0.98 : 1)
            .animation(CSSBezier.easeOut.animation(0.25), value: down)
    }
}

private enum LandingInk {
    /// 说明用中灰（参考里量到约 #818181）
    static let body = LoginInk.rgb(0x86868B)
    static let primary = LoginInk.rgb(0xFAFAFA)
    static let primaryDown = LoginInk.rgb(0xD9D9DD)
    /// 次按钮：用户发的录屏里量到是平的 #161616（不带蓝），按下亮一档、对比不变
    static let secondary = LoginInk.rgb(0x161616)
    static let secondaryDown = LoginInk.rgb(0x262626)
}

// MARK: - 登录组的上浮与回落

private enum LandingRise {
    /// 前景的时间截到这里（之后恒定）
    static let frozen = 1.25

    /// 相对落点的位移（占屏高，正的往下）：录屏 60 帧逐帧量的主按钮上沿（去掉模糊把边往下拖的那一点）
    static let lift = LandingCurve([
        (0.50, 0.30), (0.55, 0.235), (0.60, 0.150), (0.633, 0.098), (0.65, 0.070), (0.667, 0.047), (0.683, 0.031),
        (0.70, 0.014), (0.717, 0.001), (0.733, -0.008), (0.75, -0.013), (0.767, -0.018), (0.80, -0.0215), (0.833, -0.022),
        (0.85, -0.021), (0.90, -0.015), (0.95, -0.009), (1.0, -0.004), (1.05, -0.0012), (1.10, -0.0002), (1.17, 0),
    ])
    /// 不透明度：0.6 秒前后还是一团亮雾，0.73 秒完全显出来
    static let opacity = LandingCurve([(0.50, 0), (0.56, 0.3), (0.60, 0.55), (0.65, 0.82), (0.70, 0.96), (0.733, 1)])
    /// 模糊半径（点）：0.63 秒字还读不出，0.67 秒略糊，0.73 秒清楚（PDF）
    static let blur = LandingCurve([(0.50, 16), (0.60, 11), (0.65, 6), (0.683, 3), (0.717, 1), (0.75, 0)])

    static func fx(_ t: Double, reduceMotion: Bool) -> (dy: Double, blur: Double, opacity: Double) {
        if reduceMotion {
            // 减弱动态效果：和品牌整屏淡成图标同一段（0.5–0.8 秒）原地淡入
            let p = min(1, max(0, (t - 0.5) / 0.3))
            return (0, 0, p * p * (3 - 2 * p))
        }
        return (lift(t), max(0, blur(t)), min(1, max(0, opacity(t))))
    }
}

/// 单调三次插值：穿过每个关键帧，段内不冲过头（最高点、最低点斜率为 0），首尾从静止起步、落稳不抖
private struct LandingCurve: Sendable {
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
                guard d0 * d1 > 0 else { continue }
                let w1 = 2 * h1 + h0, w2 = h1 + 2 * h0
                ms[i] = (w1 + w2) / (w1 / d0 + w2 / d1)
            }
        }
        self.ts = ts
        self.vs = vs
        self.ms = ms
    }

    func callAsFunction(_ x: Double) -> Double {
        guard let first = ts.first, let last = ts.last else { return 0 }
        if x <= first { return vs[0] }
        if x >= last { return vs[vs.count - 1] }
        var i = 0
        while i < ts.count - 2 && x > ts[i + 1] { i += 1 }
        let h = ts[i + 1] - ts[i]
        let s = (x - ts[i]) / h
        let s2 = s * s, s3 = s2 * s
        let a = (2 * s3 - 3 * s2 + 1) * vs[i] + (s3 - 2 * s2 + s) * h * ms[i]
        let b = (-2 * s3 + 3 * s2) * vs[i + 1] + (s3 - s2) * h * ms[i + 1]
        return a + b
    }
}
