import SwiftUI

// MARK: - 欢迎页：和网页版一样（web/index.html 的 #wc-root）
//
// 什么时候出：和网页版同一条规矩——打开 App 时已经登录（30 天内）就先盖这一屏；没登录直接是登录页，
// 登录成功以后也不再出（网页版只在载入那一刻判断一次）。不记「看过了」：每次冷启动都有。
// 这一屏：深色底（#04060a）上 620 颗光点按黄金角排成一朵「葵花」，圆心是头像；一波亮度从里往外一遍遍扫过（3.2 秒一趟），
// 每颗各自闪烁、偶尔泛一下蓝，手指按住会把附近的光点推开、提亮。
// 上面「Good Morning !」（按时段）和「欢迎回来 · 用户名」先后模糊淡入，中间 132 的玻璃圆头像，
// 底下一颗玻璃大胶囊「确认并继续」；点了整屏淡出（0.45 秒）。
// 排版照网页版的三段：上 35%（问候，顶 56）、中 50%（头像，往下 28）、下 15%；底部安全区不算在里面。矮横屏（高 ≤ 420）收紧。

/// 打开 App 时要不要先出欢迎页
enum WelcomeGate {
    @MainActor static func shouldShow(_ account: AccountStore) -> Bool {
        // UI 测试 / 截图：-CuvenWelcome YES 强制显示（演示数据、跳过登录时默认不出，免得挡住别的测试）
        if UserDefaults.standard.bool(forKey: "CuvenWelcome") { return true }
        return account.loginRequired && account.isLoggedIn
    }
}

struct WelcomeView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onContinue: () -> Void
    @State private var appeared = false
    @State private var touch: CGPoint?

    static let background = Color(red: 4 / 255, green: 6 / 255, blue: 10 / 255)

    var body: some View {
        GeometryReader { geo in
            // 网页版按整个窗口排（position: fixed; inset: 0）：把安全区加回来，整块摆回屏幕原点
            let ins = geo.safeAreaInsets
            let w = geo.size.width + ins.leading + ins.trailing
            let h = geo.size.height + ins.top + ins.bottom
            let short = h <= 420
            let layoutH = h - ins.bottom
            let topZone = layoutH * (short ? 0.24 : 0.35)
            let greetTop = short ? max(16, ins.top + 10) : max(56, ins.top + 18)
            let avatar: CGFloat = short ? 88 : 132
            let avatarTop = topZone + (short ? 6 : 28)
            let ctaH: CGFloat = short ? 50 : 58
            let ctaBottom = ins.bottom + (short ? 14 : 32)
            let center = CGPoint(x: w / 2, y: avatarTop + avatar / 2)

            ZStack(alignment: .top) {
                WelcomeField(center: center, size: CGSize(width: w, height: h), touch: touch)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { touch = $0.location }
                            .onEnded { _ in touch = nil }
                    )
                    .accessibilityHidden(true)

                greeting(width: w)
                    .padding(.top, greetTop)
                    .allowsHitTesting(false)

                avatarView(size: avatar)
                    .position(x: w / 2, y: avatarTop + avatar / 2)
                    .allowsHitTesting(false)

                Button(action: onContinue) {
                    Text("确认并继续")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(0.17)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Capsule())
                }
                .buttonStyle(WelcomeButtonStyle())
                .frame(width: min(w - 48, 440), height: ctaH)
                .position(x: w / 2, y: h - ctaBottom - ctaH / 2)
                .accessibilityIdentifier("welcome-continue")
            }
            .frame(width: w, height: h)
            .background(Self.background)
            .position(x: geo.size.width / 2 + (ins.trailing - ins.leading) / 2,
                      y: geo.size.height / 2 + (ins.bottom - ins.top) / 2)
        }
        .environment(\.colorScheme, .dark)
        .onAppear { appeared = true }
        .task(id: account.session?.username) { await account.refreshAvatar() }
    }

    /// 「Good Evening !」（46.6 号 500 粗，10vw）和「欢迎回来 · 用户名」（31 号 700 粗，50% 白，6.65vw），中间 18
    private func greeting(width w: CGFloat) -> some View {
        let s1 = min(52, max(22, w * 0.10))
        let s2 = min(33.6, max(12.6, w * 0.0665))
        let name = account.displayName.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 0) {
            Text(Self.salutation(Date()))
                .font(.system(size: s1, weight: .medium))
                .tracking(-0.02 * s1)
                .foregroundStyle(.white)
                .modifier(BlurIn(on: appeared, delay: 0.2, reduce: reduceMotion))
            Text(name.isEmpty ? "欢迎回来" : "欢迎回来 · " + name)
                .font(.system(size: s2, weight: .bold))
                .tracking(-0.03 * s2)
                .foregroundStyle(.white.opacity(0.5))
                .shadow(color: .black.opacity(0.4), radius: 15, y: 2)
                // 网页版行高 1.05：SwiftUI 的行框高一截，间距相应收一点，第二行才落在同一个位置
                .padding(.top, max(4, 18 - 0.14 * s1))
                .modifier(BlurIn(on: appeared, delay: 0.55, reduce: reduceMotion))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .frame(width: w)
    }

    /// 网页版：5 点前 / 22 点后「Good Night」，12 点前「Good Morning」，18 点前「Good Afternoon」，再往后「Good Evening」
    static func salutation(_ now: Date) -> String {
        let h = Calendar.current.component(.hour, from: now)
        let g: String
        switch h {
        case ..<5: g = "Good Night"
        case ..<12: g = "Good Morning"
        case ..<18: g = "Good Afternoon"
        case ..<22: g = "Good Evening"
        default: g = "Good Night"
        }
        return g + " !"
    }

    /// 132 的玻璃圆（白 6% + 模糊，1px 白 18% 描边，上沿一道高光，投影）；没头像是一个人形剪影，头像到了盖在上面
    private func avatarView(size: CGFloat) -> some View {
        ZStack {
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .frame(height: size * 0.47)
                .foregroundStyle(.white.opacity(0.5))
            if let u = account.avatarURL {
                RemoteImage(url: u, maxPixel: size * 3, placeholder: .clear)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.06), in: Circle())
        .background(.ultraThinMaterial, in: Circle())
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .overlay(
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2)),
                                  lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
    }
}

/// 网页版 wcBlurIn：1 秒，从糊 14、低 10、透明，到清楚落位（cubic-bezier(.32,.72,0,1)）；「减弱动态效果」时直接出现
private struct BlurIn: ViewModifier {
    let on: Bool
    let delay: Double
    let reduce: Bool

    func body(content: Content) -> some View {
        let shown = on || reduce
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 14)
            .offset(y: shown ? 0 : 10)
            .animation(reduce ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: 1.0).delay(delay), value: on)
    }
}

/// 「确认并继续」：白 12% 玻璃胶囊（1px 白 22% 描边、上沿高光、投影），按下去缩到 96%、亮一点
private struct WelcomeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.12), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .overlay(
                Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)),
                                       lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.32), value: configuration.isPressed)
    }
}

/// 网页版 #wc-stage 的光点：620 颗按黄金角排开（越往外越大、越淡），亮度波 3.2 秒一趟从圆心往外扫，
/// 各自闪烁（相位、快慢、幅度随机），每颗隔 2.4–6 秒泛一下蓝（占一趟的 15%）；按住的地方 120 以内的光点被推开最多 30、提亮
struct WelcomeField: View {
    let center: CGPoint
    let size: CGSize
    let touch: CGPoint?
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { ctx, _ in
                Self.draw(&ctx, t: t, center: center, size: size, touch: touch)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private static let count = 620
    private static let golden = Double.pi * (3 - 5.0.squareRoot())

    /// 每颗光点自己的「随机」参数：按序号算出来，不存表，每一帧都一样
    private static func rnd(_ i: Int, _ salt: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    private static func draw(_ ctx: inout GraphicsContext, t: Double, center: CGPoint, size: CGSize, touch: CGPoint?) {
        let w = Double(size.width), h = Double(size.height)
        let maxR = (w * w + h * h).squareRoot() / 2 * 0.26
        let cx = Double(center.x), cy = Double(center.y)
        let period = 3.2
        for i in 0..<count {
            let idx = Double(i) + 0.5
            let frac = idx / Double(count)
            let r = frac.squareRoot() * maxR
            let theta = idx * golden
            var px = cx + r * cos(theta)
            var py = cy + r * sin(theta)
            let dotR = 0.9 * (0.35 + 0.9 * frac)
            let edge = 1 - 0.85 * pow(frac, 2.2)

            // 亮度波：三角波过一道三次缓动，0.18 → 1
            var phase = (t - frac * period).truncatingRemainder(dividingBy: period)
            if phase < 0 { phase += period }
            phase /= period
            let tri = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            let e = tri < 0.5 ? 4 * tri * tri * tri : 1 - pow(-2 * tri + 2, 3) / 2
            let twAmt = 0.45 + rnd(i, 3) * 0.55
            let star = (1 - twAmt) + twAmt * (0.5 + 0.5 * sin(t * (0.5 + rnd(i, 2) * 1.4) + rnd(i, 1) * 2 * .pi))

            // 偶尔泛蓝
            let cycle = 2.4 + rnd(i, 4) * 3.6
            let bp = (t / cycle + rnd(i, 5)).truncatingRemainder(dividingBy: 1)
            let blue = bp < 0.15 ? sin(bp / 0.15 * .pi) : 0

            var alpha = (0.18 + 0.82 * e) * star * edge
            if let p = touch {
                let dx = px - Double(p.x), dy = py - Double(p.y)
                let d2 = dx * dx + dy * dy
                if d2 < 120 * 120 {
                    let dist = max(d2.squareRoot(), 0.001)
                    let force = 1 - dist / 120
                    let ease = force * force
                    px += dx / dist * ease * 30
                    py += dy / dist * ease * 30
                    alpha = min(1, alpha + ease * 0.7)
                }
            }
            let a = min(1, alpha + blue * 0.25 * edge)
            let red = (228 + (120 - 228) * blue) / 255
            let green = (234 + (165 - 234) * blue) / 255
            let bl = (245 + (255 - 245) * blue) / 255
            let rect = CGRect(x: px - dotR, y: py - dotR, width: dotR * 2, height: dotR * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(.sRGB, red: red, green: green, blue: bl, opacity: a)))
        }
    }
}
