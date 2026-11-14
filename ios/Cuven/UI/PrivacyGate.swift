import SwiftUI
import UIKit

// MARK: - 数据与隐私：和网页版的「隐私同意闸门」一样（web/index.html 的 #pgSheet / __privacyGate）
//
// 什么时候出：登录以后、欢迎页退场以后（网页版在欢迎页淡出 0.5 秒后调 __privacyGate），没同意过就整屏盖上。
// 同意记在 cuven_privacy_consent_v1（与网页版同一个键、同一份 JSON：{ v, at, scopes }），
// 存的版本号对不上（政策换了版本）就重新问。
// 这一屏：深色压暗 + 模糊的底，下面推上来一张 92% 屏高的玻璃弹层（顶边圆角 28，没有关闭钮，不能下滑关掉）：
// 数据和隐私图标、「数据与隐私」、四条要点、「阅读完整隐私说明」（展开是全文），
// 「您的选择」：隐私三项（勾选），三项都勾上「同意并继续」才亮；点了按钮变绿「已同意」，0.62 秒后弹层退下去。
// 弹层顶上不画把手：把手表示能拖动改高度，这张弹层拖不动（C51）。
// 整屏只有一颗醒目的按钮「同意并继续」（C35、C81）。
// 通知不在这里问，也不是放行的条件：权限挪到有人打开「账户」里「新片上架通知」的那一刻再向系统要（C78、C79）。
// 记录还是同一个键、同一份 JSON，scopes.notifications 这一栏照旧写，这里一律记 false。

/// 网页版 hasConsent / onAgree 的那一份记录
enum PrivacyGate {
    static let key = "cuven_privacy_consent_v1"
    static let version = "2026-07-18"

    struct Record: Codable {
        struct Scopes: Codable {
            var privacy: Bool
            var crossBorder: Bool
            var age: Bool
            var notifications: Bool
        }
        var v: String
        var at: String
        var scopes: Scopes
    }

    /// 存的那一份是不是当前这一版政策的同意
    static func hasConsent(_ raw: String) -> Bool {
        guard let d = raw.data(using: .utf8), let r = try? JSONDecoder().decode(Record.self, from: d) else { return false }
        return r.v == version
    }

    /// 打开 App / 登录以后要不要先问。-CuvenPrivacy YES：测试 / 截图强制显示；演示数据、跳过登录时不出（免得挡住别的测试）
    @MainActor static func shouldShow(_ account: AccountStore) -> Bool {
        if UserDefaults.standard.bool(forKey: "CuvenPrivacy") { return true }
        guard account.loginRequired, account.isLoggedIn else { return false }
        return !hasConsent(UserDefaults.standard.string(forKey: key) ?? "")
    }

    static func record(privacy: Bool, crossBorder: Bool, age: Bool, notifications: Bool) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let r = Record(v: version, at: f.string(from: Date()),
                       scopes: .init(privacy: privacy, crossBorder: crossBorder, age: age, notifications: notifications))
        guard let d = try? JSONEncoder().encode(r) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

struct PrivacyGateView: View {
    let onDone: () -> Void

    @AppStorage(PrivacyGate.key) private var consent = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var privacy = false
    @State private var crossBorder = false
    @State private var age = false

    @State private var expanded = false
    @State private var agreed = false
    @State private var pulse = false
    @State private var sheetIn = false
    @State private var appeared = false

    static let blue = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    static let green = Color(red: 50 / 255, green: 215 / 255, blue: 75 / 255)
    static let text2 = Color.white.opacity(0.65)
    static let text3 = Color.white.opacity(0.4)

    /// 网页版的 silk 曲线
    private static let present = Animation.timingCurve(0.30, 0.52, 0.07, 1, duration: 0.604)
    private static let pop = Animation.timingCurve(0.33, 0.40, 0.12, 1.23, duration: 0.241)
    private static let dismiss = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.42)

    /// 还差几项：只算隐私三项（通知不是放行条件：C78、C79）
    private var missing: Int {
        [privacy, crossBorder, age].filter { !$0 }.count
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let w = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
            let wide = w >= 520
            let sheetH = wide ? min(h * 0.9, 780) : h * 0.92
            ZStack(alignment: .bottom) {
                // 压暗 + 模糊的底：挡住后面的主页，点它什么也不发生（必须同意才放行）
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.55))
                    .opacity(sheetIn ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)

                sheet(height: sheetH, bottomInset: geo.safeAreaInsets.bottom)
                    .frame(maxWidth: 520)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: wide ? 28 : 0,
                                                      bottomTrailingRadius: wide ? 28 : 0, topTrailingRadius: 28, style: .continuous))
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: wide ? 28 : 0,
                                               bottomTrailingRadius: wide ? 28 : 0, topTrailingRadius: 28, style: .continuous)
                            .stroke(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.07)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.04)),
                                    lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 30, y: -24)
                    .offset(y: sheetIn ? 0 : sheetH + 40)
            }
            .frame(width: w, height: h)
            .position(x: geo.size.width / 2 + (geo.safeAreaInsets.trailing - geo.safeAreaInsets.leading) / 2,
                      y: geo.size.height / 2 + (geo.safeAreaInsets.bottom - geo.safeAreaInsets.top) / 2)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.01) : Self.present) { sheetIn = true }
            appeared = true
        }
    }

    // MARK: 弹层

    private func sheet(height: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 不画把手：把手表示可以拖着改高度，这张弹层拖不动（C51）。原来把手占的 22 点并进标题上方的留白
            ScrollView {
                VStack(spacing: 0) {
                    head
                    points
                    details
                    choices
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)

            footer(bottomInset: bottomInset)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Color(red: 26 / 255, green: 26 / 255, blue: 28 / 255).opacity(0.72))
        .background(.ultraThickMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy-gate")
    }

    /// 图标（0.32 秒后弹出来）、「数据与隐私」（28 粗体）、一句说明（16 号 65% 白），依次升上来
    private var head: some View {
        VStack(spacing: 0) {
            Image("PrivacyIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .padding(.bottom, 16)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown ? 1 : 0.78)
                .animation(reduceMotion ? nil : Self.pop.delay(0.32), value: appeared)
                .accessibilityLabel("Cuven 数据和隐私图标")
            Text("数据与隐私")
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.62)
                .foregroundStyle(.white)
                .modifier(Rise(on: shown, delay: 0.42, reduce: reduceMotion))
                .accessibilityAddTraits(.isHeader)
            Text("Cuven TV+ 在为您呈现高画质影片的同时，同样用心保护您的个人信息。")
                .font(.system(size: 16))
                .lineSpacing(16 * 0.55 - 4)
                .foregroundStyle(Self.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 304)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .modifier(Rise(on: shown, delay: 0.5, reduce: reduceMotion))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 46)
        .padding(.horizontal, 8)
    }

    private var shown: Bool { appeared || reduceMotion }

    /// 四条要点：16 号 500，行间一条白 8% 的线，依次升上来（0.56 / 0.62 / 0.68 / 0.74 秒）
    private var points: some View {
        let items = ["只收集必需的信息", "仅在有正当依据时使用", "您始终掌控自己的信息", "端到端加密保护传输"]
        return VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Text(items[i])
                    .font(.system(size: 16, weight: .medium))
                    .tracking(-0.19)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 2)
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                    }
                    .modifier(Rise(on: shown, delay: 0.56 + Double(i) * 0.06, reduce: reduceMotion))
            }
        }
        .padding(.top, 40)
    }

    /// 「阅读完整隐私说明」：白 5% 的圆角 14 的条，右边 ›（展开时转成朝下、变蓝），下面滑出全文
    private var details: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Self.present) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text("阅读完整隐私说明")
                        .font(.system(size: 15, weight: .medium))
                        .tracking(-0.15)
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(expanded ? Self.blue : Self.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 18, height: 18)
                }
                .padding(16)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(GlassEdge(radius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressTint(radius: 14))
            .accessibilityIdentifier("pg-disclose")
            .accessibilityValue(expanded ? "已展开" : "已收起")

            if expanded {
                prose
                    .padding(.top, 8)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .padding(.top, 24)
    }

    /// 全文（网页版 .pg-prose：14.5 号、行高 1.64、65% 白；小标题 16 半粗白字）
    private var prose: some View {
        VStack(alignment: .leading, spacing: 0) {
            proseHeading("个人信息跨境传输", first: true)
            proseText("您的个人信息可能会被传输到世界各地的实体或被其访问；此类实体包括 Cuven 附属公司，例如：")
            VStack(spacing: 8) {
                recipient("Cuven Inc.", "美国")
                recipient("Cuven International Limited", "香港")
            }
            .padding(.top, 10)
            proseText("您的个人信息将仅出于向您提供产品或服务、履行我们与您达成的协议，在中国大陆以外的国家/地区进行传输或被访问。Cuven 和 Cuven 附属公司还可能聘请第三方担任我们的服务提供商并代表我们执行某些任务，例如出于上述目的处理或存储个人信息。Cuven 服务提供商有义务仅按照本隐私政策的规定和我们的指示处理个人信息。")
            proseHeading("您的权利")
            proseText("在 Cuven，我们尊重中国大陆消费者根据《中华人民共和国个人信息保护法》享有的获知、访问、更正、传输、限制处理和删除其个人信息的权利。中国大陆消费者还有权要求 Cuven 提供其个人信息的副本、解释 Cuven 隐私政策和本披露，以及其他相关的个人信息处理规则。")
            proseHeading("数据和隐私图标")
            (Text("Cuven 会在其隐私政策中提供有关我们隐私惯例的声明；此外，针对某些会要求使用您个人信息的产品和功能，Cuven 会嵌入包含此类声明的数据和隐私信息。这些特定于产品的信息会随我们的数据和隐私图标")
             + Text(Image(uiImage: Self.inlineIcon)).baselineOffset(-3.5)
             + Text("一并显示。"))
                .font(.system(size: 14.5))
                .lineSpacing(14.5 * 0.64 - 5)
                .foregroundStyle(Self.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            proseHeading("儿童个人信息")
            proseText("Cuven 深知保护儿童个人信息的重要性；在中国大陆，我们对儿童的定义是未满 14 周岁的个人。Cuven 将根据其隐私权政策处理儿童个人信息。Cuven 还将儿童个人信息视为敏感个人信息，依法遵守敏感个人信息的特定规则。")
            proseHeading("数据传输安全")
            proseText("您的个人信息在传输过程中采用端到端加密，借助 Cuven 自研的网络架构保障其安全。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func proseHeading(_ t: String, first: Bool = false) -> some View {
        Text(t)
            .font(.system(size: 16, weight: .semibold))
            .tracking(-0.19)
            .foregroundStyle(.white)
            .padding(.top, first ? 4 : 24)
            .padding(.bottom, 8 - 12)   // 下面紧跟的段落自带 12 的上间距；网页版小标题下沿 8
    }

    private func proseText(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 14.5))
            .lineSpacing(14.5 * 0.64 - 5)
            .foregroundStyle(Self.text2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
    }

    /// 跨境接收方：白 5%、圆角 12 的一条，左边公司名（14.5 号 500），右边地区（12.5 号 40% 白）
    private func recipient(_ name: String, _ region: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name).font(.system(size: 14.5, weight: .medium)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(region).font(.system(size: 12.5)).foregroundStyle(Self.text3)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(GlassEdge(radius: 12))
    }

    /// 正文里那枚小图标（1.2 倍字高）
    private static let inlineIcon: UIImage = {
        let side: CGFloat = 17
        guard let src = UIImage(named: "PrivacyIcon") else { return UIImage() }
        let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return r.image { _ in
            let a = src.size.width / max(1, src.size.height)
            let w = a >= 1 ? side : side * a
            let hh = a >= 1 ? side / a : side
            src.draw(in: CGRect(x: (side - w) / 2, y: (side - hh) / 2, width: w, height: hh))
        }
    }()

    // MARK: 您的选择

    private var choices: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("您的选择")
                .font(.system(size: 21, weight: .bold))
                .tracking(-0.38)
                .foregroundStyle(.white)
                .padding(.bottom, 4)
            Text("以下均为使用 Cuven TV+ 所必需。我们不会预先替您勾选任何一项。")
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(Self.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16 - 24)   // 下面分组标签自带 24 的上间距；网页版说明下沿 16

            groupLabel("隐私")
            VStack(spacing: 0) {
                checkRow(isOn: $privacy, title: "我已阅读并同意上述个人信息处理规则", note: nil, id: "pg-privacy", first: true)
                checkRow(isOn: $crossBorder, title: "我单独同意个人信息跨境传输",
                         note: "同意 Cuven 将我的个人信息传输至中国大陆境外，由上述接收方处理。依《个人信息保护法》第三十九条需单独同意。",
                         id: "pg-cross", first: false)
                checkRow(isOn: $age, title: "我已年满 14 周岁", note: "未满 14 周岁的，须由监护人阅读本页并代为同意。", id: "pg-age", first: false)
            }
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(GlassEdge(radius: 14))
            // 「开启新片上架通知」不再放在这里：挪到「账户」，有人打开时才问系统（C78、C79）
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 40)
    }

    private func groupLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12, weight: .medium))
            .tracking(0.24)
            .foregroundStyle(Self.text3)
            .padding(.horizontal, 4)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    /// 一行勾选：24 的圆圈（勾上变蓝、白色对勾弹出来）、标题 16 号、说明 12.5 号；行间线从文字那一列起头
    private func checkRow(isOn: Binding<Bool>, title: String, note: String?, id: String, first: Bool) -> some View {
        Button {
            Haptics.selection()
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(isOn.wrappedValue ? Self.blue : Self.text3, lineWidth: 1.5)
                        .background(Circle().fill(isOn.wrappedValue ? Self.blue : .clear))
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(isOn.wrappedValue ? 1 : 0)
                        .scaleEffect(isOn.wrappedValue ? 1 : 0.3)
                        .animation(Self.pop, value: isOn.wrappedValue)
                }
                .frame(width: 24, height: 24)
                .animation(.easeOut(duration: 0.2), value: isOn.wrappedValue)
                rowText(title: title, note: note)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressTint(radius: 0))
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, 54) }
        }
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func rowText(title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16))
                .tracking(-0.19)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
            if let note {
                Text(note)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(Self.text2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 底部：提示一行 + 唯一一颗醒目的「同意并继续」（C35、C81）

    private func footer(bottomInset: CGFloat) -> some View {
        let ready = missing == 0
        let hint = agreed ? "欢迎使用 Cuven TV+" : (ready ? "已完成全部必选项" : "请完成剩余 \(missing) 项以继续")
        return VStack(spacing: 0) {
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(ready || agreed ? Self.green : Self.text3)
                .frame(maxWidth: .infinity, minHeight: 16)
                .multilineTextAlignment(.center)
                .padding(.bottom, 11)
                .animation(.easeOut(duration: 0.2), value: hint)
                .accessibilityIdentifier("pg-hint")
            Button(action: agree) {
                Text(agreed ? "已同意" : "同意并继续")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(agreed ? Color(red: 5 / 255, green: 36 / 255, blue: 14 / 255) : (ready ? .white : Self.text3))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(agreed ? Self.green : (ready ? Self.blue : Color.white.opacity(0.1)),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { if ready || agreed { GlassEdge(radius: 14) } }
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressScale())
            .scaleEffect(pulse ? 1.025 : 1)
            .disabled(!ready || agreed)
            .animation(.easeOut(duration: 0.2), value: ready)
            .accessibilityIdentifier("pg-agree")
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 14 + bottomInset)
        .background(
            LinearGradient(stops: [
                .init(color: Color(red: 26 / 255, green: 26 / 255, blue: 28 / 255).opacity(0), location: 0),
                .init(color: Color(red: 26 / 255, green: 26 / 255, blue: 28 / 255).opacity(0.72), location: 0.4),
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: 动作

    private func agree() {
        guard missing == 0, !agreed else { return }
        // 通知不在这里问：scopes.notifications 记 false（键与 JSON 的样子不变）
        consent = PrivacyGate.record(privacy: privacy, crossBorder: crossBorder, age: age, notifications: false)
        Haptics.success()
        withAnimation(.easeOut(duration: 0.2)) { agreed = true }
        // 按钮轻轻鼓一下（网页版 pgPulse）
        withAnimation(.timingCurve(0.30, 0.52, 0.07, 1, duration: 0.24)) { pulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.timingCurve(0.30, 0.52, 0.07, 1, duration: 0.36)) { pulse = false }
        }
        // 0.62 秒后弹层退下去，再交回去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            withAnimation(reduceMotion ? .easeOut(duration: 0.01) : Self.dismiss) { sheetIn = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.05 : 0.42)) { onDone() }
        }
    }
}

// MARK: - 小部件

/// 网页版 pgRise：10 往上、透明到清楚（silk-settle 0.365 秒），各自的延时；「减弱动态效果」时直接出现
private struct Rise: ViewModifier {
    let on: Bool
    let delay: Double
    let reduce: Bool

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 10)
            .animation(reduce ? nil : .timingCurve(0.24, 0.17, 0.17, 1.04, duration: 0.365).delay(delay), value: on)
    }
}

/// 网页版 --glass-edge：上沿半像素高光 + 一圈极淡的描边
private struct GlassEdge: View {
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.07)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12)),
                          lineWidth: 0.5)
            .allowsHitTesting(false)
    }
}

/// 行按下去：一层白 6% 的底（网页版 :active）
private struct PressTint: ButtonStyle {
    let radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 大按钮按下去缩到 97.5%
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.timingCurve(0.24, 0.17, 0.17, 1.04, duration: 0.2), value: configuration.isPressed)
    }
}
