import SwiftUI
import UIKit

// MARK: - 登录 Cuven max（与网页版同一套流程与文案）
//
//   ① 账户：输用户名或电子邮件，停顿 0.45 秒自动查找
//        · 用户名、有密码 → 密码登录（本机可用面容 ID 快速登录）
//        · 电子邮件       → 直接发 6 位验证码
//        · 旧版账户（没设过密码）→ 邮箱验证码，登录后补设密码
//        · 用户名不存在   → 新建账户：验证邮箱 → 设定密码
//   ② 电子邮件 ③ 验证码 ④ 设定密码 ⑤ 面容 ID（可跳过）⑥ 完成
// 登录状态在最后一步「开始使用」时才写进钥匙串（写进去登录层就收起了）。

@MainActor
@Observable
final class LoginFlow {
    enum Pane: Equatable { case signin, email, code, password, faceID, done }
    enum Mode { case idle, login, otp, legacy, register }
    enum Intent { case login, register, legacy, forgot }
    enum PassMode { case register, upgrade, renew }
    enum Kind { case login, register }

    var pane: Pane = .signin
    var mode: Mode = .idle
    var input = ""
    var password = ""
    var status = ""
    var statusBad = false
    var busy = false

    var emailInput = ""
    var code = ""
    var resendLeft = 0
    var pw1 = ""
    var pw2 = ""

    private(set) var intent: Intent = .login
    private(set) var passMode: PassMode = .register
    private(set) var user = ""
    private(set) var record: AccountRecord?
    private(set) var otpEmail = ""
    private var otpUser = ""
    private var seq = 0
    private var resolveTask: Task<Void, Never>?
    private var countdown: Task<Void, Never>?

    /// 验证通过、还没写进钥匙串的身份
    private(set) var pending: AccountSession?
    private(set) var pendingKind: Kind = .login

    let account: AccountStore

    init(account: AccountStore) {
        self.account = account
        // 上次登录过的账户预先填上
        if let last = UserDefaults.standard.string(forKey: "cuven_last_user"), !last.isEmpty {
            input = last
        }
    }

    static func isEmail(_ s: String) -> Bool {
        s.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    private func set(_ msg: String, bad: Bool = false) {
        status = msg
        statusBad = bad
    }

    func go(_ p: Pane) {
        withAnimation(.snappy(duration: 0.32)) { pane = p }
    }

    // MARK: ① 账户

    func inputChanged() {
        resolveTask?.cancel()
        seq += 1
        mode = .idle
        record = nil
        user = ""
        password = ""
        let raw = input.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { set(""); return }
        if raw.contains("@") && !Self.isEmail(raw) { set("继续输入电子邮件…"); return }
        set("正在查找账户…")
        let my = seq
        resolveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.resolve(raw, seq: my)
        }
    }

    private func resolve(_ raw: String, seq my: Int) async {
        let byEmail = raw.contains("@")
        var name = raw
        if byEmail {
            guard let n = await AccountAPI.lookupEmail(raw) else {
                if my == seq { set("无法连接账户服务，请检查网络", bad: true) }
                return
            }
            guard my == seq else { return }
            if n.isEmpty { set("未找到绑定此邮箱的账户 · 可改用用户名登录", bad: true); return }
            name = n
        }
        let r = await AccountAPI.fetchRecord(name)
        guard my == seq else { return }
        switch r {
        case .offline:
            set("无法连接账户服务，请检查网络", bad: true)
        case .missing:
            if byEmail { set("未找到绑定此邮箱的账户 · 可改用用户名登录", bad: true) }
            else { mode = .register; user = name; set("新用户 — 将建立您的账户") }
        case .found(let rec):
            guard let rec else { set("读取账户资料失败，请稍后再试", bad: true); return }
            record = rec
            user = name
            if byEmail {
                mode = .otp
                otpEmail = raw.lowercased()
                set("以 \(name) 的身份登录 · 验证码将发送至此邮箱")
            } else if rec.hasPass {
                mode = .login
                set("以 \(name) 的身份登录")
            } else {
                mode = .legacy
                set("旧版账户 · 请用邮箱验证码登录")
            }
        }
    }

    var primaryTitle: String {
        switch mode {
        case .idle: return "继续"
        case .login: return "登录"
        case .otp: return "发送验证码"
        case .legacy: return "邮箱验证码登录"
        case .register: return "创建账户"
        }
    }

    var primaryEnabled: Bool {
        guard !busy else { return false }
        switch mode {
        case .idle: return false
        case .login: return !password.isEmpty
        default: return true
        }
    }

    var faceIDOffered: Bool {
        mode == .login && account.faceIDUser == user && account.biometryAvailable
    }

    func submit() async {
        switch mode {
        case .idle: break
        case .otp: await sendCode(email: otpEmail, intent: .login)
        case .legacy: openEmail(.legacy)
        case .register: openEmail(.register)
        case .login: await passwordLogin()
        }
    }

    private func passwordLogin() async {
        guard !password.isEmpty, !busy else { return }
        busy = true
        set("正在验证…")
        var rec = record
        if rec?.hasPass != true, case .found(let r) = await AccountAPI.fetchRecord(user) { rec = r }
        guard let rec, let pass = rec.pass, rec.hasPass else {
            busy = false
            set("无法读取账户资料，请稍后再试", bad: true)
            return
        }
        let ok = await PasswordHash.check(password, pass)
        busy = false
        guard ok else {
            set("密码不正确，请重试", bad: true)
            Haptics.error()
            return
        }
        succeed(user, email: rec.email ?? "", method: "password", kind: .login)
    }

    func faceIDLogin() async {
        busy = true
        set("请完成\(account.biometryName)验证…")
        let ok = await account.faceIDLogin()
        busy = false
        if !ok { set("\(account.biometryName)验证未通过，请输入密码", bad: true) }
    }

    // MARK: ② 电子邮件

    var emailTitle: String {
        switch intent {
        case .login: return "电子邮件登录"
        case .register: return "验证电子邮件"
        case .legacy: return "旧版账户登录"
        case .forgot: return "重设密码"
        }
    }

    var emailSubtitle: String {
        switch intent {
        case .login: return "输入账户绑定的电子邮件，我们将发送 6 位验证码"
        case .register: return "输入您的电子邮件以绑定账户，我们将发送 6 位验证码"
        case .legacy: return "此账户建立于旧版本 · 验证绑定的电子邮件后即可登录"
        case .forgot: return "验证账户绑定的电子邮件后，即可设定新密码"
        }
    }

    var verifyTitle: String {
        switch intent {
        case .login: return "验证并登录"
        case .register, .forgot: return "验证"
        case .legacy: return "验证并继续"
        }
    }

    func openEmail(_ i: Intent) {
        intent = i
        emailInput = i == .register ? "" : (record?.email ?? "")
        set("")
        go(.email)
    }

    func sendCode(email raw: String, intent i: Intent) async {
        let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.isEmail(email), !busy else { return }
        intent = i
        busy = true
        set(i == .register ? "正在检查邮箱…" : "正在查找账户…")
        guard let found = await AccountAPI.lookupEmail(email) else {
            busy = false
            set("网络错误，请稍后再试", bad: true)
            return
        }
        switch i {
        case .register:
            if !found.isEmpty { busy = false; set("此电子邮件已绑定其他账户", bad: true); return }
            otpUser = user
        case .legacy, .forgot:
            if found.isEmpty { busy = false; set("此电子邮件未绑定任何账户，请确认拼写", bad: true); return }
            if found != user { busy = false; set("此邮箱绑定的是其他账户", bad: true); return }
            otpUser = user
        case .login:
            if found.isEmpty { busy = false; set("此电子邮件未绑定任何账户", bad: true); return }
            otpUser = found
        }
        otpEmail = email
        set("正在发送验证码…")
        let j = await AccountAPI.sendCode(email)
        busy = false
        guard j?.ok == true else {
            set(j?.message ?? "发送失败，请稍后再试", bad: true)
            return
        }
        set("")
        code = ""
        startCountdown(60)
        go(.code)
    }

    // MARK: ③ 验证码

    func resend() async {
        guard resendLeft == 0 else { return }
        await sendCode(email: otpEmail, intent: intent)
    }

    private func startCountdown(_ sec: Int) {
        countdown?.cancel()
        resendLeft = sec
        countdown = Task { [weak self] in
            while let self, self.resendLeft > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                self.resendLeft -= 1
            }
        }
    }

    func codeChanged() {
        let digits = String(code.filter(\.isNumber).prefix(6))
        if digits != code { code = digits }
        if code.count == 6 { Task { await verify() } }
    }

    func verify() async {
        guard code.count == 6, !busy else { return }
        busy = true
        set("正在验证…")
        let j = await AccountAPI.verifyCode(otpEmail, code: code)
        busy = false
        guard j?.ok == true else {
            var msg = j?.message ?? "验证失败，请重试"
            switch j?.error {
            case "wrong_code"?:
                msg = "验证码不正确，请重新输入"
                if let left = j?.attemptsLeft, left <= 2 { msg += "（还可尝试 \(left) 次）" }
            case "expired"?: msg = "验证码已过期，请重新发送"
            case "too_many_attempts"?: msg = "尝试次数过多，请重新发送验证码"
            default: break
            }
            set(msg, bad: true)
            code = ""
            Haptics.error()
            return
        }
        countdown?.cancel()
        resendLeft = 0
        switch intent {
        case .register: openPassword(.register)
        case .legacy: openPassword(.upgrade)
        case .forgot: openPassword(.renew)
        case .login:
            set("登录成功，正在读取账户…")
            if case .found(let r) = await AccountAPI.fetchRecord(otpUser), let r, !r.hasPass {
                record = r
                user = otpUser
                openPassword(.upgrade)
                return
            }
            succeed(otpUser, email: otpEmail, method: "email_otp", kind: .login)
        }
    }

    // MARK: ④ 设定密码

    var passTitle: String { passMode == .renew ? "设定新密码" : "设定密码" }
    var passSubtitle: String {
        switch passMode {
        case .register: return "至少 8 个字元，需包含字母与数字"
        case .upgrade: return "为账户设定密码，下次即可直接密码登录"
        case .renew: return "验证成功 · 请设定新的登录密码"
        }
    }
    var passButton: String {
        switch passMode {
        case .register: return "创建账户"
        case .upgrade: return "设定并登录"
        case .renew: return "更新并登录"
        }
    }

    var passValid: Bool { PasswordHash.isStrong(pw1) && pw1 == pw2 }
    var passHint: String {
        if !pw1.isEmpty && !PasswordHash.isStrong(pw1) { return "至少 8 个字元，需包含字母与数字" }
        if !pw2.isEmpty && pw1 != pw2 { return "两次输入的密码不一致" }
        return ""
    }

    func openPassword(_ m: PassMode) {
        passMode = m
        pw1 = ""
        pw2 = ""
        set("")
        go(.password)
    }

    func savePassword() async {
        guard passValid, !busy else { return }
        busy = true
        set("正在加密…")
        let pass = await PasswordHash.make(pw1)
        let name = passMode == .register ? user : (otpUser.isEmpty ? user : otpUser)
        var prev: AccountRecord? = passMode == .register ? nil : record
        if passMode != .register, prev == nil, case .found(let r) = await AccountAPI.fetchRecord(name) { prev = r }
        let rec = AccountRecord.build(name: name, email: otpEmail, pass: pass, previous: prev)
        set("正在保存…")
        guard await AccountAPI.putRecord(rec) else {
            busy = false
            set("保存失败，请重试", bad: true)
            return
        }
        if let e = rec.email, !e.isEmpty { await AccountAPI.putEmailMap(e, username: name) }
        busy = false
        switch passMode {
        case .register:
            AccountAPI.notify("welcome", username: name)
            succeed(name, email: rec.email ?? "", method: "register", kind: .register)
        case .upgrade:
            AccountAPI.notify("password_set", username: name)
            succeed(name, email: rec.email ?? "", method: "email_otp", kind: .login)
        case .renew:
            AccountAPI.notify("password_changed", username: name)
            succeed(name, email: rec.email ?? "", method: "email_otp", kind: .login)
        }
    }

    /// 旧版账户可以先不设密码，直接登录
    func skipPassword() {
        succeed(otpUser.isEmpty ? user : otpUser, email: otpEmail, method: "email_otp", kind: .login)
    }

    // MARK: ⑤ 面容 ID ⑥ 完成

    private func succeed(_ name: String, email: String, method: String, kind: Kind) {
        pending = AccountSession(username: name, email: email.lowercased(), method: method, at: Date())
        pendingKind = kind
        set("")
        Haptics.success()
        UserDefaults.standard.set(name, forKey: "cuven_last_user")
        if account.biometryAvailable && account.faceIDUser != name {
            go(.faceID)
        } else {
            go(.done)
        }
    }

    func enableFaceID() async {
        guard let p = pending else { return }
        busy = true
        _ = await account.enableFaceID(for: p)
        busy = false
        go(.done)
    }

    var doneTitle: String { pendingKind == .register ? "账户已建立" : "已登录 Cuven max" }
    var doneSubtitle: String {
        let name = pending?.username ?? ""
        return pendingKind == .register ? "欢迎加入，\(name)" : "欢迎回来，\(name)"
    }

    /// 写进钥匙串：登录层随之收起
    func finish() {
        guard let p = pending else { return }
        account.signIn(username: p.username, email: p.email, method: p.method, alert: pendingKind == .login)
    }

    func back() {
        switch pane {
        case .email: go(.signin)
        case .code: go(intent == .login && mode == .otp ? .signin : .email)
        case .password: go(.signin)
        default: break
        }
        set("")
    }
}

// MARK: - 界面

struct LoginView: View {
    @Environment(AccountStore.self) private var account
    @State private var flow: LoginFlow?

    var body: some View {
        Group {
            if let flow {
                LoginScreen(flow: flow)
            } else {
                Color.black
            }
        }
        .onAppear { if flow == nil { flow = LoginFlow(account: account) } }
    }
}

private struct LoginScreen: View {
    @Bindable var flow: LoginFlow
    @FocusState private var focus: Field?
    enum Field { case input, password, email, code, pw1, pw2 }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    LoginBrand(pulse: flow.pane == .done)
                    Spacer(minLength: 24)
                    panel
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(LoginBackdrop())
        .onAppear { if flow.input.isEmpty { focus = .input } else { flow.inputChanged() } }
        .onChange(of: flow.pane) { _, p in
            switch p {
            case .email: focus = .email
            case .code: focus = .code
            case .password: focus = .pw1
            default: focus = nil
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if [LoginFlow.Pane.email, .code, .password].contains(flow.pane) {
                Button { flow.back() } label: {
                    Label("返回", systemImage: "chevron.left").font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("login-back")
            }
            switch flow.pane {
            case .signin: signin
            case .email: emailPane
            case .code: codePane
            case .password: passwordPane
            case .faceID: faceIDPane
            case .done: donePane
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .environment(\.colorScheme, .light)
        .foregroundStyle(.black)
        .tint(Color(red: 0.0, green: 0.48, blue: 1.0))
    }

    // ① 账户
    private var signin: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("登录", "使用你的 Cuven 账户登录 Cuven max。")
            LoginField(text: $flow.input, placeholder: "用户名或电子邮件", secure: false, content: .username)
                .focused($focus, equals: .input)
                .submitLabel(flow.mode == .login ? .next : .go)
                .onSubmit { if flow.mode == .login { focus = .password } else { Task { await flow.submit() } } }
                .onChange(of: flow.input) { _, _ in flow.inputChanged() }
                .accessibilityIdentifier("login-user")
            if flow.mode == .login {
                LoginField(text: $flow.password, placeholder: "密码", secure: true, content: .password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await flow.submit() } }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("login-password")
            }
            StatusLine(text: flow.status, bad: flow.statusBad)
            PrimaryButton(title: flow.primaryTitle, busy: flow.busy, enabled: flow.primaryEnabled) {
                Task { await flow.submit() }
            }
            .accessibilityIdentifier("login-primary")
            if flow.faceIDOffered {
                SecondaryButton(title: "使用\(flow.account.biometryName)登录", systemImage: "faceid") { Task { await flow.faceIDLogin() } }
            }
            if flow.mode == .login {
                HStack {
                    LinkButton(title: "改用邮箱验证码登录") { flow.openEmail(.login) }
                    Spacer()
                    LinkButton(title: "忘记密码？") { flow.openEmail(.forgot) }
                }
            } else if flow.mode == .idle {
                LinkButton(title: "使用电子邮件验证码登录") { flow.openEmail(.login) }
            }
            Text("一个 Cuven 账户即可登录 Cuven max、Cuven TV 以及 Cuven 的其他服务。")
                .font(.system(size: 12))
                .foregroundStyle(.black.opacity(0.45))
                .padding(.top, 4)
        }
        .animation(.snappy(duration: 0.28), value: flow.mode)
    }

    // ② 电子邮件
    private var emailPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(flow.emailTitle, flow.emailSubtitle)
            LoginField(text: $flow.emailInput, placeholder: "电子邮件", secure: false, content: .emailAddress)
                .focused($focus, equals: .email)
                .keyboardType(.emailAddress)
                .submitLabel(.send)
                .onSubmit { Task { await flow.sendCode(email: flow.emailInput, intent: flow.intent) } }
                .accessibilityIdentifier("login-email")
            StatusLine(text: flow.status, bad: flow.statusBad)
            PrimaryButton(title: "发送验证码", busy: flow.busy, enabled: LoginFlow.isEmail(flow.emailInput.trimmingCharacters(in: .whitespaces)) && !flow.busy) {
                Task { await flow.sendCode(email: flow.emailInput, intent: flow.intent) }
            }
        }
    }

    // ③ 验证码
    private var codePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("输入验证码", "验证码已发送至 \(flow.otpEmail)")
            CodeBoxes(code: $flow.code, bad: flow.statusBad)
                .focused($focus, equals: .code)
                .onChange(of: flow.code) { _, _ in flow.codeChanged() }
            StatusLine(text: flow.status, bad: flow.statusBad)
            PrimaryButton(title: flow.verifyTitle, busy: flow.busy, enabled: flow.code.count == 6 && !flow.busy) {
                Task { await flow.verify() }
            }
            LinkButton(title: flow.resendLeft > 0 ? "\(flow.resendLeft) 秒后可重新发送" : "重新发送") {
                Task { await flow.resend() }
            }
            .disabled(flow.resendLeft > 0)
        }
    }

    // ④ 设定密码
    private var passwordPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(flow.passTitle, flow.passSubtitle)
            LoginField(text: $flow.pw1, placeholder: "新密码", secure: true, content: .newPassword)
                .focused($focus, equals: .pw1)
                .submitLabel(.next)
                .onSubmit { focus = .pw2 }
            LoginField(text: $flow.pw2, placeholder: "再输一次", secure: true, content: .newPassword)
                .focused($focus, equals: .pw2)
                .submitLabel(.done)
                .onSubmit { Task { await flow.savePassword() } }
            StatusLine(text: flow.passHint.isEmpty ? flow.status : flow.passHint, bad: !flow.passHint.isEmpty || flow.statusBad)
            PrimaryButton(title: flow.passButton, busy: flow.busy, enabled: flow.passValid && !flow.busy) {
                Task { await flow.savePassword() }
            }
            if flow.passMode == .upgrade {
                LinkButton(title: "暂不设定，直接登录") { flow.skipPassword() }
            }
        }
    }

    // ⑤ 面容 ID
    private var faceIDPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "faceid")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.accentColor)
            header("启用\(flow.account.biometryName)", "下次轻点一下即可登录。面容数据只保存在此设备的安全隔区，Cuven 不会接触。")
            PrimaryButton(title: "启用\(flow.account.biometryName)", busy: flow.busy, enabled: !flow.busy) {
                Task { await flow.enableFaceID() }
            }
            SecondaryButton(title: "以后再说", systemImage: nil) { flow.go(.done) }
        }
    }

    // ⑥ 完成
    private var donePane: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.bounce, value: flow.pane)
            Text(flow.doneTitle).font(.system(size: 24, weight: .bold))
            Text(flow.doneSubtitle).font(.system(size: 15)).foregroundStyle(.black.opacity(0.6))
            PrimaryButton(title: "开始使用", busy: false, enabled: true) { flow.finish() }
                .padding(.top, 6)
                .accessibilityIdentifier("login-done")
        }
        .frame(maxWidth: .infinity)
    }

    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(sub).font(.system(size: 14)).foregroundStyle(.black.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 组件

private struct LoginField: View {
    @Binding var text: String
    let placeholder: String
    let secure: Bool
    let content: UITextContentType

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .textContentType(content)
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 6 位验证码：一个隐藏的输入框 + 6 个格子（系统能从短信 / 邮件自动填）
private struct CodeBoxes: View {
    @Binding var code: String
    let bad: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accessibilityIdentifier("login-code")
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let ch = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
                    Text(ch)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(bad ? Color.red.opacity(0.6) : (i == code.count ? Color.accentColor : .clear), lineWidth: 1.5))
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct StatusLine: View {
    let text: String
    let bad: Bool
    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(bad ? Color.red : Color.black.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let busy: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(.white) }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(enabled || busy ? Color.black : Color.black.opacity(0.25), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct SecondaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.black.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .font(.system(size: 14, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
    }
}

/// 登录页上半截：Cuven max 字标；完成时从字标往外扩一圈蓝光
private struct LoginBrand: View {
    let pulse: Bool
    @State private var ring = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color(red: 0.2, green: 0.55, blue: 1.0).opacity(ring ? 0 : 0.6), lineWidth: 2)
                    .frame(width: 96, height: 96)
                    .scaleEffect(ring ? 2.4 : 1)
                Image("BrandIcon")
                    .resizable()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color(red: 0.1, green: 0.4, blue: 1).opacity(0.45), radius: 24)
            }
            Text("Cuven max")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .onChange(of: pulse) { _, on in
            guard on else { return }
            ring = false
            withAnimation(.easeOut(duration: 1.1)) { ring = true }
        }
    }
}

/// 背景：深色底 + 两团慢慢呼吸的蓝光
private struct LoginBackdrop: View {
    @State private var phase = false

    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [Color(red: 0.05, green: 0.35, blue: 1.0).opacity(0.55), .clear],
                           center: .init(x: 0.3, y: phase ? 0.18 : 0.26), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.35, green: 0.2, blue: 1.0).opacity(0.35), .clear],
                           center: .init(x: 0.8, y: phase ? 0.34 : 0.24), startRadius: 0, endRadius: 360)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { phase = true } }
    }
}
