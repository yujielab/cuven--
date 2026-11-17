import SwiftUI
import UIKit
import PhotosUI

// MARK: - 账户页移植（网页版）：个人资料卡与三个弹层
//
// 网页版账户页（#scr-account）的第一张卡和它打开的弹层，按 iOS 账户页那一套（游戏 App 个人页：AccountCard / AccountRow）重做：
// · 个人资料卡：头像、姓名、电子邮件、登录面容（网页版还有一行「订阅」，用户要求移除）；第一次还没拿到资料时是一张闪光的骨架；
// · 头像选择（网页版 avt-*）：大头像 ↔ 2 / 3 / 2 蜂窝的七个默认头像，上传照片（系统照片选取器，压成 JPEG，最大 5 MB）；
// · 电子邮件（em-*）：两步，6 格验证码，60 秒后才能重发；
// · 更改姓名 / 重设登录面容（nm-*）：面容 ID（没有就用绑定邮箱的验证码）验证身份 → 新姓名（停 0.4 秒查重）→ 确认 → 完成。
// 文案与网页版逐字一致；iOS 上做法不一样的地方（登录面容就是本机的面容 ID 快速登录）另写。

/// 账户页上打开的弹层
enum ProfileSheet: String, Identifiable {
    case avatar, email, rename, faceReset
    var id: String { rawValue }
}

extension AccountStore {
    /// 生物识别的符号：面容 ID / 触控 ID / 光学 ID
    var biometrySymbol: String {
        switch biometryName {
        case "触控 ID": return "touchid"
        case "光学 ID": return "opticid"
        default: return "faceid"
        }
    }
}

/// 弹层里的几种颜色（网页版的红、绿、琥珀，放到深色上提亮一些）
enum ProfileInk {
    static let bad = Color(red: 1, green: 0.42, blue: 0.38)
    static let good = Color(red: 0.25, green: 0.84, blue: 0.5)
    static let check = Color(red: 0.2, green: 0.78, blue: 0.35)
    static let warnText = Color(red: 1, green: 0.85, blue: 0.6)
    static let warnIcon = Color(red: 1, green: 0.7, blue: 0.28)
}

enum ProfileText {
    /// 一段灰字里夹几截白色粗体（网页版 em-sub 里的 <b>）：拼成一个 AttributedString，不拼 Text + Text
    static func rich(_ parts: [(String, Bool)], font: Font = .subheadline, ink: Color = DSInk.secondary,
                     strong: Color = .white) -> AttributedString {
        var out = AttributedString()
        for (text, bold) in parts {
            var run = AttributedString(text)
            run.font = bold ? font.weight(.semibold) : font
            run.foregroundColor = bold ? strong : ink
            out.append(run)
        }
        return out
    }

    /// 验证码出错（网页版同一套说法）
    static func codeError(_ r: AccountAPI.CodeReply, fallback: String) -> String {
        switch r.error {
        case "wrong_code"?:
            var m = "验证码不正确"
            if let left = r.attemptsLeft, left <= 2 { m += "（还可尝试 \(left) 次）" }
            return m
        case "expired"?:
            return "验证码已过期，请重新发送"
        case "too_many_attempts"?:
            return "尝试次数过多，请重新发送验证码"
        default:
            return r.message ?? fallback
        }
    }

    /// a***b@x.com（网页版 maskEmail）
    static func mask(_ e: String) -> String {
        guard let at = e.firstIndex(of: "@") else { return e }
        let local = e[..<at]
        let domain = String(e[at...])
        if local.count <= 1 { return "*" + domain }
        return String(local.prefix(1)) + "***" + String(local.suffix(1)) + domain
    }
}

/// 弹层里那一行状态：红 = 出错、灰 = 进行中、绿 = 成功（网页版 em-error / em-info / em-success）
struct ProfileStatus: Equatable {
    enum Kind { case error, info, success }
    var text: String
    var kind: Kind

    static let empty = ProfileStatus(text: "", kind: .info)
    static func error(_ t: String) -> ProfileStatus { ProfileStatus(text: t, kind: .error) }
    static func info(_ t: String) -> ProfileStatus { ProfileStatus(text: t, kind: .info) }
    static func success(_ t: String) -> ProfileStatus { ProfileStatus(text: t, kind: .success) }

    var isError: Bool { kind == .error && !text.isEmpty }
}

struct ProfileStatusLine: View {
    let status: ProfileStatus
    var centered = false

    var body: some View {
        // 没字时也占一行，出字时版面不跳
        Text(status.text.isEmpty ? " " : status.text)
            .font(.footnote)
            .foregroundStyle(color)
            .multilineTextAlignment(centered ? .center : .leading)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: centered ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeInOut(duration: 0.25), value: status)
            .accessibilityHidden(status.text.isEmpty)
    }

    private var color: Color {
        switch status.kind {
        case .error: return ProfileInk.bad
        case .info: return DSInk.tertiary
        case .success: return ProfileInk.good
        }
    }
}

// MARK: - 个人资料卡

/// 个人资料卡（网页版账户页的第一张卡）：头像（整行可点，打开头像选择）、姓名「更改」、电子邮件「设置 / 更改」、
/// 登录面容「重设」。
/// 第一次还没拿到账户资料时是一张闪光的骨架（网页版 acc-skeleton-overlay），拿到了从一点点模糊里淡入
struct ProfileCard: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var present: (ProfileSheet) -> Void

    private var profile: ProfileStore { .shared }

    var body: some View {
        AccountCard {
            ZStack {
                if profile.loaded {
                    rows.transition(reduceMotion ? .opacity : .dsBlurFadeClear(radius: 12))
                } else {
                    ProfileSkeleton().transition(.opacity)
                }
            }
            .animation(DSMotion.adapt(DSMotion.fade, reduce: reduceMotion), value: profile.loaded)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-profile")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            Button { present(.avatar) } label: {
                AccountRow(icon: "person.crop.circle", title: "头像", subtitle: "个人形象") {
                    AvatarView(size: 40)
                }
            }
            .buttonStyle(AccountRowPress())
            .accessibilityIdentifier("account-avatar")
            AccountDivider()
            AccountRow(icon: "person.text.rectangle", title: "姓名", subtitle: nameText, subtitleLines: 1) {
                ProfilePill(title: "更改", label: "更改姓名") { present(.rename) }
                    .accessibilityIdentifier("account-name-edit")
            }
            AccountDivider()
            // 地址一行放下，放不下从中间省略（以前在「gmail.」后面折成两行：用户截图）
            AccountRow(icon: "envelope", title: "电子邮件", subtitle: emailText, subtitleLines: 1, subtitleTruncation: .middle) {
                ProfilePill(title: hasEmail ? "更改" : "设置", label: hasEmail ? "更改电子邮件" : "设置电子邮件",
                            prominent: !hasEmail) { present(.email) }
                    .accessibilityIdentifier("account-email-edit")
            }
            AccountDivider()
            AccountRow(icon: account.biometrySymbol, title: "登录面容", subtitle: "用于登录的面容数据") {
                ProfilePill(title: "重设", label: "重设登录面容") { present(.faceReset) }
                    .accessibilityIdentifier("account-face-reset")
            }
            // 「订阅」那一行（Max Core+ 尊享 · 管理）用户要求移除
        }
    }

    private var nameText: String { account.displayName.isEmpty ? "—" : account.displayName }

    /// 演示数据 / 没登录：「—」；有账户没设：「未设置」
    private var placeholderOnly: Bool { DemoData.enabled || account.session == nil }

    private var emailValue: String {
        guard !placeholderOnly else { return "" }
        return (profile.email ?? account.session?.email ?? "").trimmingCharacters(in: .whitespaces)
    }

    private var hasEmail: Bool { !emailValue.isEmpty }

    private var emailText: String {
        if placeholderOnly { return "—" }
        return hasEmail ? emailValue : "未设置"
    }

}

/// 骨架：五行的样子，字是灰块，一道光从左往右扫（网页版 accSkeletonShimmer，2 秒一趟）；「减弱动态效果」时不扫
private struct ProfileSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            row("person.crop.circle", "头像", "个人形象", round: true)
            AccountDivider()
            row("person.text.rectangle", "姓名", "用户名占位")
            AccountDivider()
            row("envelope", "电子邮件", "user@example.com")
            AccountDivider()
            row("faceid", "登录面容", "已录入")
        }
        .redacted(reason: .placeholder)
        .modifier(ProfileShimmer())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在载入账户资料")
    }

    private func row(_ icon: String, _ title: String, _ subtitle: String, round: Bool = false) -> some View {
        AccountRow(icon: icon, title: title, subtitle: subtitle) {
            if round {
                Circle().fill(Color.white.opacity(0.12)).frame(width: 40, height: 40)
            } else {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 56, height: 30)
            }
        }
    }
}

private struct ProfileShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, Color.white.opacity(0.22), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.6)
                            .offset(x: g.size.width * (phase * 1.6 - 0.6))
                    }
                    .mask { content }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// 行尾的玻璃胶囊（网页版 acc-glass-btn）：看上去 30 高（用户要求卡片更精致：32 → 30、左右 16 → 13），点按区撑到 44（F74）；
/// 没设电子邮件时是一颗蓝色的「设置」（网页版 acc-email-cta）
struct ProfilePill: View {
    let title: String
    var label: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 13)
                .frame(minHeight: 30)
                .glassEffect(glass, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(label ?? title)
    }

    private var glass: Glass {
        prominent ? Glass.regular.tint(Theme.accent.opacity(0.6)).interactive() : Glass.regular.interactive()
    }
}

// MARK: - 弹层里的部件

/// 主按钮（网页版 em-primary）：整宽 52 高的胶囊；深色页面上是白底黑字。不可点时淡下去，忙的时候字换成转圈
struct ProfilePrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var enabled = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol).accessibilityHidden(true)
                    }
                    Text(title)
                }
                .opacity(busy ? 0 : 1)
                if busy {
                    ProgressView().tint(.black)
                }
            }
            .font(.headline)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(Color.white.opacity(busy ? 0.82 : 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .disabled(!enabled || busy)
        .opacity(enabled || busy ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: enabled)
        .animation(.easeInOut(duration: 0.2), value: busy)
        .accessibilityLabel(title)
    }
}

/// 弹层里的文字钮（「‹ 返回修改电子邮件」「改用邮箱验证码验证」）：点按区 44 高
struct ProfileLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(DSInk.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 输入框（网页版 em-input）：圆角 14 的淡白底，聚焦时一圈蓝、出错时一圈红
struct ProfileFieldStyle: ViewModifier {
    let focused: Bool
    var error = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let stroke: Color = error ? ProfileInk.bad : (focused ? Theme.accent : Color.white.opacity(0.12))
        return content
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .tint(Theme.accent)
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(shape.fill(Color.white.opacity(focused ? 0.12 : 0.08)))
            .overlay(shape.strokeBorder(stroke, lineWidth: focused || error ? 1.5 : 1))
            .animation(.easeInOut(duration: 0.25), value: focused)
            .animation(.easeInOut(duration: 0.25), value: error)
    }
}

/// 6 格验证码里的一格（只负责显示；字由一个看不见的系统字段收）
private struct ProfileCodeBox: View {
    let char: String
    let focused: Bool
    let error: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let stroke: Color = error ? ProfileInk.bad : (focused ? Theme.accent : Color.white.opacity(0.12))
        Text(char)
            .font(.title2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(shape.fill(Color.white.opacity(focused ? 0.14 : 0.08)))
            .overlay(shape.strokeBorder(stroke, lineWidth: focused || error ? 1.5 : 1))
            .animation(.easeInOut(duration: 0.2), value: focused)
            .animation(.easeInOut(duration: 0.2), value: error)
    }
}

/// 「60 秒后可重新发送」……「重新发送」
struct ProfileResendRow: View {
    let countdown: Int
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if countdown > 0 {
                Text(ProfileText.rich([(String(countdown), true), (" 秒后可重新发送", false)],
                                      font: .footnote, ink: DSInk.tertiary, strong: DSInk.secondary))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: countdown)
            }
            Spacer(minLength: 0)
            Button(action: action) {
                Text("重新发送")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(countdown > 0 || disabled ? DSInk.tertiary : Theme.accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(countdown > 0 || disabled)
        }
    }
}

/// 琥珀色的提醒框（网页版 nm-warn）
struct ProfileWarning: View {
    let text: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ProfileInk.warnIcon)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(ProfileInk.warnText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.orange.opacity(0.14)))
        .overlay(shape.strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
    }
}

/// 电子邮件、姓名两个弹层的外框（网页版 em-card：底部弹层、顶上一根把手、往下拖能收起）：
/// 系统弹层（大尺寸、显示把手）+ 导航栏里的标题和关闭钮；内容放在滚动视图里，键盘弹起时滚得到
struct ProfileSheetFrame<Content: View>: View {
    let title: String
    var busy = false
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content()
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 460, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .disabled(busy)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy)
    }
}

/// 账户页的 .sheet(item:) 里放哪一个
struct ProfileSheetView: View {
    let sheet: ProfileSheet

    var body: some View {
        switch sheet {
        case .avatar: AvatarPickerSheet()
        case .email: EmailChangeSheet()
        case .rename: IdentitySheet(mode: .rename)
        case .faceReset: IdentitySheet(mode: .faceReset)
        }
    }
}

// MARK: - 头像选择

/// 上传前处理好的照片：裁成正方形（头像是圆的）、最长边 1024、压成 JPEG（网页版直接传原图；这里先压小，5 MB 以内）
struct PreparedAvatar: Equatable, @unchecked Sendable {
    let id = UUID()
    let image: UIImage
    let jpeg: Data

    static func == (a: PreparedAvatar, b: PreparedAvatar) -> Bool { a.id == b.id }

    static func make(from data: Data) async -> PreparedAvatar? {
        await Task.detached(priority: .userInitiated) { () async -> PreparedAvatar? in
            guard let source = UIImage(data: data) else { return nil }
            let w = source.size.width
            let h = source.size.height
            guard w > 0, h > 0 else { return nil }
            let side = min(w, h)
            let target = min(1024, side)
            let scale = target / side
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format)
            let image = renderer.image { _ in
                let dw = w * scale
                let dh = h * scale
                source.draw(in: CGRect(x: (target - dw) / 2, y: (target - dh) / 2, width: dw, height: dh))
            }
            var quality: CGFloat = 0.85
            var jpeg = image.jpegData(compressionQuality: quality)
            while let j = jpeg, j.count > ProfileAPI.maxUpload, quality > 0.35 {
                quality -= 0.15
                jpeg = image.jpegData(compressionQuality: quality)
            }
            guard let out = jpeg else { return nil }
            return PreparedAvatar(image: image, jpeg: out)
        }.value
    }
}

/// 圆里一张头像图；还没载入时一层淡白
struct ProfileAvatarImage: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Color.clear
            .overlay { RemoteImage(url: url, maxPixel: size * 3, placeholder: Color.white.opacity(0.08)) }
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

/// 大头像轻轻上下浮动（网页版 avtBreatheHero：6 秒一个来回、往上 5 点）
private struct ProfileBreathe: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        content.phaseAnimator([CGFloat(0), CGFloat(-5)]) { view, y in
            view.offset(y: on ? y : 0)
        } animation: { _ in
            .easeInOut(duration: 3)
        }
    }
}

/// 头像选择（网页版 avt-*）：大标题「个人形象」+ 一行说明；中间一块舞台——预览时是 180 点的大头像（轻轻浮动），
/// 编辑时大头像放大、糊掉、淡出，七个默认头像按 2 / 3 / 2 蜂窝弹出来（正中的 4 号是默认）；底下「上传照片」+ 主按钮。
/// 选一个默认头像或传一张照片就退出编辑：蜂窝糊掉，大头像换成选的那张；点大头像回到编辑。
/// 主按钮：有改动 →「完成」保存；编辑中没改动 →「完成」直接关；预览且没改动 →「更改头像」进编辑
struct AvatarPickerSheet: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Pending: Equatable {
        case preset(Int)
        case photo(PreparedAvatar)
    }

    /// 打开就是编辑（网页版：点进来就是想改，直接展开蜂窝）
    @State private var editing = true
    @State private var pending: Pending?
    @State private var saving = false
    @State private var error: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var picks = 0
    @State private var failures = 0

    private var profile: ProfileStore { .shared }
    private var saved: ProfileAvatar { profile.settings.avatar }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                header
                stage
                    .padding(.top, 32)
                actions
                    .padding(.top, 32)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { backdrop }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .disabled(saving)
                }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(saving)
        .sensoryFeedback(.selection, trigger: picks)
        .sensoryFeedback(.error, trigger: failures)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { @MainActor in await loadPhoto(item) }
        }
    }

    // MARK: 状态

    /// 和已保存的不一样
    private var changed: Bool {
        switch pending {
        case .some(.photo): return true
        case .some(.preset(let id)): return saved.isCustom || saved.presetID != id
        case .none: return false
        }
    }

    /// 蜂窝里选中的那一个（自己的照片时都不选）
    private var selectedID: Int? {
        switch pending {
        case .some(.preset(let id)): return id
        case .some(.photo): return nil
        case .none: return saved.isCustom ? nil : saved.presetID
        }
    }

    private var subtitle: String {
        if saving { return "正在保存…" }
        if let error { return error }
        if editing { return "选择默认形象，或上传一张照片。" }
        if changed {
            if case .some(.photo) = pending { return "轻点“完成”保存这张照片。" }
            return "轻点“完成”保存所选形象。"
        }
        return "为账户选择清晰、自然的显示形象。"
    }

    private var buttonTitle: String { editing || changed ? "完成" : "更改头像" }

    private var stageAnimation: Animation {
        DSMotion.adapt(.timingCurve(0.32, 0.72, 0, 1, duration: 0.7), reduce: reduceMotion)
    }

    private var swapTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.65).combined(with: .opacity)
    }

    // MARK: 版面

    /// 网页版叠层顶上那一团淡淡的光
    private var backdrop: some View {
        RadialGradient(colors: [Color.white.opacity(0.08), .clear], center: UnitPoint(x: 0.5, y: 0.2),
                       startRadius: 0, endRadius: 420)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("个人形象")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(error != nil && !saving ? ProfileInk.bad : DSInk.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 21)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: subtitle)
        }
    }

    /// 舞台：大头像和蜂窝叠在一起，编辑 / 预览之间互相糊掉换过去（0.7 秒，网页版 --avt-ease-spatial）
    private var stage: some View {
        ZStack {
            hero
                .opacity(editing ? 0 : 1)
                .scaleEffect(editing && !reduceMotion ? 1.15 : 1)
                .blur(radius: editing && !reduceMotion ? 15 : 0)
                .allowsHitTesting(!editing)
            honeycomb
                .opacity(editing ? 1 : 0)
                .scaleEffect(!editing && !reduceMotion ? 0.9 : 1)
                .blur(radius: !editing && !reduceMotion ? 10 : 0)
                .allowsHitTesting(editing)
        }
        .frame(height: 300)
        .animation(stageAnimation, value: editing)
    }

    private var hero: some View {
        Button { reopen() } label: {
            ZStack { heroImage }
                .frame(width: 180, height: 180)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
                .modifier(ProfileBreathe(on: !editing && !reduceMotion))
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .disabled(saving)
        .accessibilityLabel("头像")
        .accessibilityHint("轻点重新选择")
    }

    @ViewBuilder
    private var heroImage: some View {
        switch pending {
        case .some(.preset(let id)):
            ProfileAvatarImage(url: ProfileAPI.presetURL(id), size: 180)
                .id("preset-\(id)")
                .transition(swapTransition)
        case .some(.photo(let p)):
            Image(uiImage: p.image)
                .resizable()
                .scaledToFill()
                .frame(width: 180, height: 180)
                .clipShape(Circle())
                .id(p.id)
                .transition(swapTransition)
        case .none:
            AvatarView(size: 180)
                .id("current")
                .transition(swapTransition)
        }
    }

    /// 蜂窝：2 / 3 / 2，中间那一排上下各收 4 点；弹出来时正中先、两边再、上下两排最后（网页版的延迟）
    private var honeycomb: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                dot(1, delay: 0.2)
                dot(2, delay: 0.2)
            }
            HStack(spacing: 18) {
                dot(3, delay: 0.15)
                dot(4, delay: 0.1)
                dot(5, delay: 0.15)
            }
            .padding(.vertical, -4)
            HStack(spacing: 18) {
                dot(6, delay: 0.2)
                dot(7, delay: 0.2)
            }
        }
    }

    private func dot(_ id: Int, delay: Double) -> some View {
        let selected = selectedID == id
        let entrance: Animation = reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.6, dampingFraction: 0.62).delay(editing ? delay : 0)
        return Button { pick(id) } label: {
            ProfileAvatarImage(url: ProfileAPI.presetURL(id), size: 78)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .background {
                    Circle()
                        .strokeBorder(Color.white.opacity(selected ? 0.55 : 0), lineWidth: 2)
                        .padding(-5)
                }
                .scaleEffect(selected ? 1.08 : 1)
                .animation(DSMotion.snap, value: selected)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .scaleEffect(editing || reduceMotion ? 1 : 0.5)
        .offset(y: editing || reduceMotion ? 0 : 20)
        .opacity(editing ? 1 : 0)
        .animation(entrance, value: editing)
        .accessibilityLabel("默认头像 \(id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var actions: some View {
        HStack(spacing: editing ? 12 : 0) {
            if editing {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("上传照片", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 20)
                        .frame(height: 52)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
            }
            Button { mainTapped() } label: {
                ZStack {
                    Text(buttonTitle)
                        .opacity(saving ? 0 : 1)
                    if saving {
                        ProgressView().tint(.black)
                    }
                }
                .font(.headline)
                .foregroundStyle(.black)
                .lineLimit(1)
                .padding(.horizontal, editing ? 26 : 32)
                .frame(minWidth: editing ? 90 : 140)
                .frame(height: 52)
                .background(Capsule().fill(Color.white))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            }
            .buttonStyle(PressableStyle(scale: 0.95))
            .disabled(saving)
            .accessibilityLabel(saving ? "正在保存" : buttonTitle)
        }
        .frame(height: 52)
        .animation(stageAnimation, value: editing)
    }

    // MARK: 动作

    private func reopen() {
        guard !saving, !editing else { return }
        error = nil
        editing = true
    }

    private func pick(_ id: Int) {
        guard editing, !saving else { return }
        error = nil
        withAnimation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion)) { pending = .preset(id) }
        picks += 1
        // 选中后退出编辑：蜂窝糊掉，大头像换成选的这一张
        editing = false
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        guard editing, !saving else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let prepared = await PreparedAvatar.make(from: data) else {
            error = "支持 PNG、JPG、WebP 或 GIF"
            failures += 1
            return
        }
        guard prepared.jpeg.count <= ProfileAPI.maxUpload else {
            error = "照片不能超过 5 MB"
            failures += 1
            return
        }
        error = nil
        withAnimation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion)) { pending = .photo(prepared) }
        picks += 1
        editing = false
    }

    private func mainTapped() {
        guard !saving else { return }
        if changed {
            Task { @MainActor in await commit() }
            return
        }
        if editing {
            dismiss()
            return
        }
        error = nil
        editing = true
    }

    /// 保存：照片先上传，再写设置；成功后主页和账户页的头像一起换，弹层收起。出错就把说明写在副标题的位置（红字）
    private func commit() async {
        guard let pending else { return }
        saving = true
        error = nil
        let choice: ProfileStore.AvatarChoice
        switch pending {
        case .preset(let id): choice = .preset(id)
        case .photo(let p): choice = .photo(p.jpeg)
        }
        let message = await profile.saveAvatar(choice)
        saving = false
        if let message {
            error = message
            failures += 1
            return
        }
        account.applyAvatar(profile.avatarURL)
        // 本机那一份马上换：上传的照片就是这份字节；选了默认头像就把那一张拉下来存上
        // （演示数据存不了自己的照片，和网页版一样退回默认头像：照常按设置刷新）
        switch pending {
        case .photo(let p) where profile.syncEnabled: AvatarCache.shared.store(p.jpeg, for: account.displayName)
        default: Task { await account.refreshAvatar(force: true) }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

// MARK: - 电子邮件

/// 设置 / 更改电子邮件（网页版 em-*）：两步在同一张弹层里换页（淡入、往上 8 点）。
/// 一：输入新地址 →「发送验证码」；二：6 格验证码（一个看不见的系统字段收字：邮件里的验证码自动填充、整段粘贴都走它，
/// 删字往回退），填满自动验证；60 秒后才能「重新发送」。验证通过后写到账户（409：这个地址已绑定别的账户），
/// 成功后主按钮变「完成」，0.9 秒后自己收起
struct EmailChangeSheet: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step { case email, code }
    private enum Field: Hashable { case email, code }

    @State private var step = Step.email
    @State private var original: String?
    @State private var input = ""
    @State private var inputError = false
    @State private var pendingEmail = ""
    @State private var code = ""
    @State private var codeError = false
    @State private var status = ProfileStatus.empty
    @State private var busy = false
    @State private var done = false
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var failures = 0
    @State private var successes = 0
    @FocusState private var focus: Field?

    private var profile: ProfileStore { .shared }

    /// 现在的电子邮件（服务器的为准；演示数据没有）
    private var current: String {
        guard !DemoData.enabled else { return "" }
        return (profile.email ?? account.session?.email ?? "").trimmingCharacters(in: .whitespaces)
    }

    private var hadEmail: Bool { !(original ?? current).isEmpty }
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity)
    }

    private var stepAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.45)
    }

    var body: some View {
        ProfileSheetFrame(title: hadEmail ? "更改电子邮件" : "设置电子邮件", busy: busy) {
            ZStack(alignment: .topLeading) {
                switch step {
                case .email:
                    emailStep.transition(stepTransition)
                case .code:
                    codeStep.transition(stepTransition)
                }
            }
        }
        .sensoryFeedback(.error, trigger: failures)
        .sensoryFeedback(.success, trigger: successes)
        .task {
            original = current
            input = current
            try? await Task.sleep(nanoseconds: 350_000_000)
            if step == .email { focus = .email }
        }
        .onDisappear { countdownTask?.cancel() }
    }

    // MARK: 第一步：电子邮件

    private var step1Subtitle: AttributedString {
        let cur = original ?? current
        guard !cur.isEmpty else {
            return ProfileText.rich([("为保护账户安全，请先验证你可访问此电子邮件地址。我们会发送 6 位验证码。", false)])
        }
        return ProfileText.rich([("当前电子邮件：", false), (cur, true),
                                 ("\n输入新的电子邮件地址。我们会发送 6 位验证码用于确认。", false)])
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step1Subtitle)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            TextField("", text: $input, prompt: Text("you@example.com").foregroundStyle(DSInk.tertiary))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($focus, equals: .email)
                .onSubmit { send() }
                .onChange(of: input) { _, _ in
                    inputError = false
                    if status.isError { status = .empty }
                }
                .modifier(ProfileFieldStyle(focused: focus == .email, error: inputError))
                .accessibilityLabel("电子邮件")
            ProfileStatusLine(status: status)
                .padding(.top, 8)
                .padding(.horizontal, 4)
            ProfilePrimaryButton(title: "发送验证码", enabled: ProfileStore.isEmail(trimmedInput), busy: busy) { send() }
                .padding(.top, 12)
        }
    }

    // MARK: 第二步：验证码

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ProfileText.rich([("验证码已发送至 ", false), (pendingEmail, true), ("。请输入收到的 6 位数字。", false)]))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            codeRow
            ProfileStatusLine(status: status)
                .padding(.top, 10)
                .padding(.horizontal, 4)
            ProfileResendRow(countdown: countdown, disabled: busy || done) { resend() }
            ProfilePrimaryButton(title: done ? "完成" : "验证并保存", enabled: code.count == 6 || done, busy: busy) {
                if done { dismiss() } else { verify() }
            }
            .padding(.top, 4)
            ProfileLinkButton(title: "‹ 返回修改电子邮件") { back() }
                .padding(.top, 6)
                .disabled(busy || done)
        }
    }

    private var codeRow: some View {
        let chars = Array(code)
        let active = focus == .code ? min(chars.count, 5) : -1
        return ZStack {
            TextField("", text: Binding(get: { code }, set: { typed($0) }))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 56)
                .focused($focus, equals: .code)
                .accessibilityLabel("验证码")
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    ProfileCodeBox(char: i < chars.count ? String(chars[i]) : "", focused: i == active, error: codeError)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus = .code }
    }

    // MARK: 动作

    /// 只收数字、最多 6 位；一改就清掉红字；填满自动验证（网页版：格子填齐时自动试一次）
    private func typed(_ raw: String) {
        let digits = String(raw.filter { $0.isASCII && $0.isNumber }.prefix(6))
        let old = code
        code = digits
        if digits != old {
            codeError = false
            if status.isError { status = .empty }
        }
        if digits.count == 6, digits != old { verify() }
    }

    private func send() {
        guard !busy else { return }
        let email = trimmedInput
        guard ProfileStore.isEmail(email) else {
            inputError = true
            status = .error("请输入有效的电子邮件地址")
            failures += 1
            return
        }
        if !current.isEmpty, current.lowercased() == email.lowercased() {
            inputError = true
            status = .error("新电子邮件与当前地址相同")
            return
        }
        busy = true
        status = .info("正在发送验证码…")
        Task { @MainActor in
            let reply = await ProfileAPI.sendCode(email)
            busy = false
            guard reply.ok == true else {
                status = .error(reply.message ?? "发送失败，请稍后再试")
                failures += 1
                return
            }
            pendingEmail = email
            code = ""
            codeError = false
            status = .empty
            withAnimation(stepAnimation) { step = .code }
            startCountdown()
            try? await Task.sleep(nanoseconds: 200_000_000)
            focus = .code
        }
    }

    private func verify() {
        guard !busy, !done else { return }
        guard code.count == 6 else {
            status = .error("请输入完整的 6 位验证码")
            return
        }
        busy = true
        status = .info("正在验证…")
        let email = pendingEmail
        let typedCode = code
        Task { @MainActor in
            let reply = await ProfileAPI.verifyCode(email, code: typedCode)
            guard reply.ok == true else {
                busy = false
                codeError = true
                status = .error(ProfileText.codeError(reply, fallback: "验证失败"))
                failures += 1
                return
            }
            // 验证通过 → 写到账户（服务器为准；写不进去不改本机）
            let name = account.session?.username ?? ""
            if profile.syncEnabled, !name.isEmpty {
                status = .info("已验证，正在保存…")
                let put = await ProfileAPI.putEmail(name, email)
                guard (200..<300).contains(put) else {
                    busy = false
                    codeError = true
                    failures += 1
                    if put == 409 {
                        status = .error("此电子邮件已绑定其他账户，请换一个地址")
                    } else {
                        let detail = put == 0 ? "网络异常" : "HTTP \(put)"
                        status = .error("已验证，但云端保存失败（\(detail)），请再试一次")
                    }
                    return
                }
            }
            busy = false
            profile.applyEmail(email)
            account.updateEmail(email)
            done = true
            successes += 1
            status = .success("已验证，电子邮件已更新")
            countdownTask?.cancel()
            try? await Task.sleep(nanoseconds: 900_000_000)
            dismiss()
        }
    }

    private func resend() {
        guard countdown == 0, !busy, !done, !pendingEmail.isEmpty else { return }
        busy = true
        status = .info("正在重新发送…")
        let email = pendingEmail
        Task { @MainActor in
            let reply = await ProfileAPI.sendCode(email)
            busy = false
            guard reply.ok == true else {
                status = .error(reply.message ?? "重新发送失败")
                return
            }
            status = .info("验证码已重新发送")
            code = ""
            codeError = false
            focus = .code
            startCountdown()
        }
    }

    private func back() {
        guard !busy else { return }
        status = .empty
        withAnimation(stepAnimation) { step = .email }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            focus = .email
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 60
        countdownTask = Task { @MainActor in
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown -= 1
            }
        }
    }
}

// MARK: - 更改姓名 / 重设登录面容

/// 更改姓名 / 重设登录面容（网页版 nm-*）：先验证身份——本机的面容 ID（网页版是本机通行密钥）；
/// 设备没有、或选了「改用邮箱验证码验证」，就把验证码发到账户绑定的电子邮件（遮掉中间几位）。
/// 更改姓名：新姓名（停 0.4 秒查重）→ 确认（旧的面容 ID 登录作废）→ 完成，「前往录入面容」重新开面容 ID 登录；
/// 重设登录面容：确认后重新录入本机的面容 ID 登录（AccountStore.enableFaceID）
struct IdentitySheet: View {
    enum Mode { case rename, faceReset }
    let mode: Mode

    @Environment(AccountStore.self) private var account
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    private enum Step { case verify, name, confirm, done }
    private enum Field: Hashable { case otp, name }

    @State private var step = Step.verify
    @State private var ready = false
    @State private var accountName = ""
    @State private var bioAvailable = false
    @State private var verifyStatus = ProfileStatus.empty
    @State private var otpMode = false
    @State private var otpEmail = ""
    @State private var otp = ""
    @State private var otpStatus = ProfileStatus.empty
    @State private var nameInput = ""
    @State private var nameStatus = ProfileStatus.empty
    @State private var nameOK = false
    @State private var newName = ""
    @State private var confirmStatus = ProfileStatus.empty
    @State private var doneStatus = ProfileStatus.empty
    @State private var busy = false
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var failures = 0
    @State private var successes = 0
    @FocusState private var focus: Field?

    private var profile: ProfileStore { .shared }
    private var bioName: String { account.biometryName }

    /// 账户绑定的电子邮件（验证码兜底用）
    private var boundEmail: String {
        guard !DemoData.enabled else { return "" }
        let e = (profile.email ?? account.session?.email ?? "").trimmingCharacters(in: .whitespaces)
        return ProfileStore.isEmail(e) ? e : ""
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity)
    }

    private var stepAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.45)
    }

    var body: some View {
        ProfileSheetFrame(title: mode == .rename ? "更改姓名" : "重设登录面容", busy: busy) {
            ZStack(alignment: .topLeading) {
                switch step {
                case .verify:
                    verifyStep.transition(stepTransition)
                case .name:
                    nameStep.transition(stepTransition)
                case .confirm:
                    confirmStep.transition(stepTransition)
                case .done:
                    doneStep.transition(stepTransition)
                }
            }
        }
        .sensoryFeedback(.error, trigger: failures)
        .sensoryFeedback(.success, trigger: successes)
        .onAppear { setup() }
        .onDisappear { countdownTask?.cancel() }
    }

    // MARK: 验证身份

    /// 能不能验证：演示数据、没登录不行；重设登录面容要本机有面容 ID；更改姓名要有面容 ID 或绑定的电子邮件
    private var canVerify: Bool {
        guard !DemoData.enabled, !accountName.isEmpty else { return false }
        if mode == .faceReset { return bioAvailable }
        return bioAvailable || !boundEmail.isEmpty
    }

    private var verifySubtitle: String {
        if DemoData.enabled { return "演示模式下不能更改账户。" }
        if accountName.isEmpty { return "未检测到登录账户。请先登录后，再进行此操作。" }
        if mode == .faceReset && !bioAvailable { return "这台设备没有可用的\(bioName)，暂时无法重设登录面容。" }
        if !bioAvailable && boundEmail.isEmpty {
            return "此设备不支持面容 ID 验证，且账户未绑定电子邮件，暂时无法验证身份。请先在账户设置中绑定电子邮件。"
        }
        return mode == .rename ? "更改姓名会影响你的登录名与账户数据，请先验证你的身份。" : "重设登录面容前，请先验证你的身份。"
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            if ready {
                Text(verifySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(DSInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 18)
                if canVerify {
                    if otpMode {
                        otpBlock
                    } else {
                        faceBlock
                    }
                }
            }
        }
    }

    private var faceBlock: some View {
        VStack(spacing: 0) {
            ProfileStatusLine(status: verifyStatus)
                .padding(.horizontal, 4)
            ProfilePrimaryButton(title: "使用\(bioName) 验证", symbol: account.biometrySymbol, busy: busy) { faceID() }
                .padding(.top, 8)
            if !boundEmail.isEmpty {
                ProfileLinkButton(title: "改用邮箱验证码验证") {
                    verifyStatus = .empty
                    enterOtp()
                }
                .padding(.top, 6)
                .disabled(busy)
            }
        }
    }

    private var otpBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !verifyStatus.text.isEmpty {
                ProfileStatusLine(status: verifyStatus)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 10)
            }
            Text(ProfileText.rich([("验证码将发送至账户绑定的电子邮件 ", false), (ProfileText.mask(otpEmail), true), ("。", false)]))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            TextField("", text: Binding(get: { otp }, set: { otpTyped($0) }),
                      prompt: Text("输入 6 位验证码").foregroundStyle(DSInk.tertiary))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title3.weight(.semibold).monospacedDigit())
                .focused($focus, equals: .otp)
                .modifier(ProfileFieldStyle(focused: focus == .otp, error: otpStatus.isError))
                .accessibilityLabel("验证码")
            ProfileStatusLine(status: otpStatus)
                .padding(.top, 8)
                .padding(.horizontal, 4)
            ProfileResendRow(countdown: countdown, disabled: busy) { sendOtp() }
            ProfilePrimaryButton(title: "验证身份", enabled: otp.count == 6, busy: busy) { otpVerify() }
                .padding(.top, 4)
        }
    }

    private func setup() {
        guard !ready else { return }
        accountName = account.session?.username ?? ""
        bioAvailable = account.biometryAvailable
        ready = true
        // 设备不支持面容 ID、有绑定邮箱 → 直接改用邮箱验证码
        guard canVerify, !bioAvailable, !boundEmail.isEmpty else { return }
        verifyStatus = .info("此设备不支持面容 ID，已改用邮箱验证码验证身份。")
        enterOtp()
    }

    private func faceID() {
        guard !busy else { return }
        busy = true
        verifyStatus = .info("请在系统弹窗中完成面容验证…")
        let reason = mode == .rename ? "验证身份以更改姓名" : "验证身份以重设登录面容"
        Task { @MainActor in
            let outcome = await IdentityCheck.biometric(reason: reason)
            busy = false
            switch outcome {
            case .ok:
                verifyStatus = .success("身份验证通过")
                successes += 1
                try? await Task.sleep(nanoseconds: 350_000_000)
                onVerified()
            case .cancelled:
                verifyStatus = .error("已取消验证")
                failures += 1
            case .failed, .unavailable:
                let tail = boundEmail.isEmpty ? "" : "，或改用邮箱验证码"
                verifyStatus = .error("\(bioName) 验证未通过，请重试" + tail)
                failures += 1
            }
        }
    }

    private func enterOtp() {
        otpEmail = boundEmail
        guard !otpEmail.isEmpty else { return }
        otp = ""
        otpStatus = .empty
        withAnimation(stepAnimation) { otpMode = true }
        sendOtp()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            focus = .otp
        }
    }

    private func otpTyped(_ raw: String) {
        let digits = String(raw.filter { $0.isASCII && $0.isNumber }.prefix(6))
        if digits != otp, otpStatus.isError { otpStatus = .empty }
        otp = digits
    }

    private func sendOtp() {
        guard countdown == 0 else { return }
        otpStatus = .info("正在发送验证码…")
        let email = otpEmail
        Task { @MainActor in
            let reply = await ProfileAPI.sendCode(email)
            if reply.ok == true {
                otpStatus = .info("验证码已发送")
                startCountdown()
            } else if reply.error == "network" {
                otpStatus = .error("网络连接异常，请稍后再试")
            } else {
                otpStatus = .error(reply.message ?? "发送失败，请稍后再试")
            }
        }
    }

    private func otpVerify() {
        guard !busy, otp.count == 6 else { return }
        busy = true
        otpStatus = .info("正在验证…")
        let email = otpEmail
        let typedCode = otp
        Task { @MainActor in
            let reply = await ProfileAPI.verifyCode(email, code: typedCode)
            busy = false
            guard reply.ok == true else {
                otpStatus = .error(ProfileText.codeError(reply, fallback: "验证失败，请重试"))
                failures += 1
                return
            }
            otpStatus = .success("身份验证通过")
            successes += 1
            try? await Task.sleep(nanoseconds: 350_000_000)
            onVerified()
        }
    }

    /// 验证通过：更改姓名 → 输新姓名；重设登录面容 → 确认
    private func onVerified() {
        countdownTask?.cancel()
        countdown = 0
        focus = nil
        if mode == .rename {
            nameInput = ""
            nameStatus = .empty
            nameOK = false
            withAnimation(stepAnimation) { step = .name }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                focus = .name
            }
        } else {
            confirmStatus = .empty
            withAnimation(stepAnimation) { step = .confirm }
        }
    }

    // MARK: 新姓名

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("身份已确认。输入新的姓名 — 它将成为你的登录名与账户标识。")
                .font(.subheadline)
                .foregroundStyle(DSInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            TextField("", text: $nameInput, prompt: Text("新的姓名").foregroundStyle(DSInk.tertiary))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .name)
                .onSubmit { next() }
                .modifier(ProfileFieldStyle(focused: focus == .name, error: nameStatus.isError))
                .accessibilityLabel("新的姓名")
            ProfileStatusLine(status: nameStatus)
                .padding(.top, 8)
                .padding(.horizontal, 4)
            ProfilePrimaryButton(title: "继续", enabled: nameOK) { next() }
                .padding(.top, 12)
        }
        // 停 0.4 秒再去查有没有人用（换了字，上一次的查询作废）
        .task(id: nameInput) { await checkName() }
    }

    private func checkName() async {
        let v = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        nameOK = false
        if v.isEmpty {
            nameStatus = .empty
            return
        }
        if v == accountName {
            nameStatus = .error("新姓名与当前姓名相同")
            return
        }
        guard ProfileStore.isValidName(v) else {
            nameStatus = .error("姓名仅支持中日文、字母、数字、空格及 . - _，最长 64 字")
            return
        }
        nameStatus = .info("正在检查可用性…")
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !Task.isCancelled else { return }
        let result = await ProfileAPI.checkName(v)
        guard !Task.isCancelled, nameInput.trimmingCharacters(in: .whitespacesAndNewlines) == v else { return }
        switch result {
        case .taken:
            nameStatus = .error("该姓名已被使用，请换一个")
        case .available:
            nameStatus = .success("此姓名可以使用")
            nameOK = true
        case .invalid:
            nameStatus = .error("检查失败，请稍后再试")
        case .network:
            nameStatus = .error("网络错误，无法检查姓名可用性")
        }
    }

    private func next() {
        guard nameOK else { return }
        newName = nameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        confirmStatus = .empty
        focus = nil
        withAnimation(stepAnimation) { step = .confirm }
    }

    // MARK: 确认

    private var confirmText: AttributedString {
        if mode == .rename {
            return ProfileText.rich([("将把姓名从 ", false), (accountName, true), (" 更改为 ", false), (newName, true),
                                     ("。头像、电子邮件与账户设置会自动迁移。", false)])
        }
        return ProfileText.rich([("即将重设 ", false), (accountName, true), (" 的登录面容。", false)])
    }

    private var confirmWarning: String {
        if mode == .rename {
            return "出于安全考虑，更改姓名后旧的面容数据将被清除，需要重新录入面容才能继续使用面容登录。"
        }
        return "接下来按系统提示完成一次\(bioName) 验证即可生效；本机旧的面容登录凭据将被覆盖。"
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(confirmText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            ProfileWarning(text: confirmWarning)
                .padding(.bottom, 10)
            ProfileStatusLine(status: confirmStatus)
                .padding(.horizontal, 4)
            ProfilePrimaryButton(title: mode == .rename ? "确认更改" : "前往重新录入", busy: busy) { confirm() }
                .padding(.top, 8)
            ProfileLinkButton(title: "‹ 返回") { backFromConfirm() }
                .padding(.top, 6)
                .disabled(busy)
        }
    }

    private func backFromConfirm() {
        guard !busy else { return }
        confirmStatus = .empty
        withAnimation(stepAnimation) { step = mode == .rename ? .name : .verify }
    }

    private func confirm() {
        guard !busy else { return }
        if mode == .faceReset {
            // 重设 = 验证过身份以后，为这个账户重新开一次本机的面容 ID 登录
            busy = true
            confirmStatus = .info("请在系统弹窗中完成面容验证…")
            Task { @MainActor in
                let outcome = await account.enableFaceID()
                busy = false
                if outcome == .ok {
                    successes += 1
                    withAnimation(stepAnimation) { step = .done }
                } else {
                    confirmStatus = .error(faceIDError(outcome))
                    failures += 1
                }
            }
            return
        }
        busy = true
        confirmStatus = .info("正在更改姓名…")
        let from = accountName
        let to = newName
        Task { @MainActor in
            let result = await ProfileAPI.rename(from: from, to: to)
            busy = false
            switch result {
            case .ok:
                profile.applyRename(to: to)
                account.applyRename(to: to)
                successes += 1
                withAnimation(stepAnimation) { step = .done }
            case .taken:
                confirmStatus = .error("该姓名刚刚被占用，请返回换一个")
                failures += 1
            case .failed(let message):
                confirmStatus = .error(message.map { "更改失败：\($0)" } ?? "更改失败，请检查网络后重试")
                failures += 1
            }
        }
    }

    private func faceIDError(_ outcome: BiometricOutcome) -> String {
        switch outcome {
        case .cancelled: return "已取消验证"
        case .failed: return "\(bioName) 验证未通过，请重试"
        default: return "这台设备暂时无法使用\(bioName)"
        }
    }

    // MARK: 完成

    private var doneText: AttributedString {
        if mode == .rename {
            let tail = bioAvailable ? "。\n需要重新录入面容后，才能继续使用面容登录。" : "。"
            return ProfileText.rich([("姓名已更改为 ", false), (newName, true), (tail, false)])
        }
        return ProfileText.rich([("已重设 ", false), (accountName, true), (" 的登录面容，下次轻点一下即可登录。", false)])
    }

    private var goEnroll: Bool { mode == .rename && bioAvailable }

    private var doneStep: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(ProfileInk.check)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            .shadow(color: ProfileInk.check.opacity(0.35), radius: 12, y: 8)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
            Text(doneText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            ProfileStatusLine(status: doneStatus, centered: true)
            ProfilePrimaryButton(title: goEnroll ? "前往录入面容" : "完成", symbol: goEnroll ? account.biometrySymbol : nil,
                                 busy: busy) { doneTapped() }
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    /// 「前往录入面容」：为新姓名开本机的面容 ID 登录（网页版跳到面容录入页）
    private func doneTapped() {
        guard !busy else { return }
        guard goEnroll else {
            dismiss()
            return
        }
        busy = true
        doneStatus = .info("请在系统弹窗中完成面容验证…")
        Task { @MainActor in
            let outcome = await account.enableFaceID()
            busy = false
            if outcome == .ok {
                successes += 1
                dismiss()
            } else {
                doneStatus = .error(faceIDError(outcome))
                failures += 1
            }
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 60
        countdownTask = Task { @MainActor in
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown -= 1
            }
        }
    }
}
