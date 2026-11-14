import SwiftUI
import UIKit

// MARK: - 登录 Cuven max（与网页版同一套流程；界面按 Apple HIG，规则编号见 docs/ios-design.md「登录」）
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
    /// 一步一页：界面用系统的导航栈推进（Hashable：导航栈的路径要用）
    enum Pane: Hashable { case signin, email, code, password, faceID, done }
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
        case .legacy: return "用邮箱验证码登录"
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
        case .login: return "输入账户绑定的电子邮件，6 位验证码会发到这个邮箱。"
        case .register: return "输入要绑定到账户的电子邮件，6 位验证码会发到这个邮箱。"
        case .legacy: return "这个账户建立于旧版本，验证绑定的电子邮件后即可登录。"
        case .forgot: return "验证账户绑定的电子邮件后，即可设定新密码。"
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
        case .register: return "至少 8 个字符，需包含字母和数字。"
        case .upgrade: return "设定密码以后，下次可以直接用密码登录。"
        case .renew: return "验证成功，请设定新的登录密码。"
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
        if !pw1.isEmpty && !PasswordHash.isStrong(pw1) { return "至少 8 个字符，需包含字母和数字" }
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
//
// 按 Apple HIG 收拾（docs/ios-design.md「登录」；C 是 docs/hig/components.md，F 是 docs/hig/foundations.md）：
// · 整屏深色、系统文字样式，一列居中（展开的 Duo 上不超过 440 宽：F8），只靠留白分组（F3、F12）；
//   不放背景光斑、白色面板、玻璃和装饰动画（F38、F80），品牌只留一枚小图标。
// · 一步一页，用系统的导航栈推进：系统的返回钮、右滑返回（C14、F53）；动效只有系统的推入和字段的淡入（F52–F61）。
// · 每一步一颗醒目的白色主按钮（C35），要的数据没填好之前是灰的（C110）；忙的时候按钮里转圈（C66–C69）；其余都是纯文字按钮。
// · 字段：上面一行标签、里面一句提示（C105），竖排、同宽、间距一样（C109）；密码用 SecureField、从不预填（C106）；
//   键盘和 textContentType 对得上，系统的自动填充、短信 / 邮件里的验证码、整段粘贴都能直接填进来（C107、C111、C112）。
// · 出错就写在字段下面，平实的一句话，红字加一枚符号（F36、F87、C83）。

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

/// 光标在哪个字段里
private enum LoginFocus: Hashable { case input, password, email, code, pw1, pw2 }

private struct LoginScreen: View {
    @Bindable var flow: LoginFlow
    @FocusState private var focus: LoginFocus?
    /// 导航栈里推进去的那几步（根是「登录」）
    @State private var path: [LoginFlow.Pane] = []
    /// 完成那一步的勾：出现时轻轻弹一下（F52：动效用来回应）
    @State private var celebrate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack(path: pathBinding) {
            LoginPage { signin }
                // 根这一页没有可返回的地方，不要一条空的导航栏
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: LoginFlow.Pane.self) { p in destination(p) }
        }
        // 只在登录层第一次出现时：没有上次的账户就把光标放进账户字段；有就直接去查
        .onAppear { if flow.input.isEmpty { focus = .input } else { flow.inputChanged() } }
        .onChange(of: flow.pane) { _, p in sync(to: p) }
    }

    /// 系统返回钮或右滑把一页弹掉了：流程跟着退一步（退到哪一步还是 LoginFlow.back 的规矩）
    private var pathBinding: Binding<[LoginFlow.Pane]> {
        Binding(
            get: { path },
            set: { new in
                let popped = new.count < path.count
                path = new
                if popped { flow.back() }
            }
        )
    }

    /// 流程换了一步：退回到栈里已有的那一步，或者推进新的一步
    private func sync(to p: LoginFlow.Pane) {
        if p == .signin { path = []; return }
        if let i = path.firstIndex(of: p) { path = Array(path.prefix(i + 1)); return }
        path.append(p)
    }

    @ViewBuilder
    private func destination(_ p: LoginFlow.Pane) -> some View {
        switch p {
        case .signin:
            LoginPage { signin }
        case .email:
            LoginPage { emailPane }
        case .code:
            LoginPage { codePane }
        case .password:
            // 设定密码时「返回」是回到登录、整段作废：写成「取消」（C14 只管返回和关闭的符号，取消用字）
            LoginPage { passwordPane }
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { flow.back() }
                            .accessibilityIdentifier("login-cancel")
                    }
                }
        case .faceID:
            // 已经验证过身份：这两步不能再退回去
            LoginPage { faceIDPane }
                .navigationBarBackButtonHidden(true)
        case .done:
            LoginPage { donePane }
                .navigationBarBackButtonHidden(true)
        }
    }

    // MARK: ① 账户

    private var signin: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌只留一枚小图标，不放大字标和光效（F80）
            Image("BrandIcon")
                .resizable()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .accessibilityHidden(true)
                .padding(.bottom, 24)
            header("登录", "使用你的 Cuven 账户登录 Cuven max。")

            VStack(alignment: .leading, spacing: 20) {
                LoginField(label: "用户名或电子邮件", placeholder: "用户名或 name@example.com", text: $flow.input,
                           kind: .account, focus: $focus, field: .input, id: "login-user")
                    .submitLabel(flow.mode == .login ? .next : .go)
                    .onSubmit { if flow.mode == .login { focus = .password } else { Task { await flow.submit() } } }
                    .onChange(of: flow.input) { _, _ in flow.inputChanged() }
                if flow.mode == .login {
                    // 查到账户、有密码才出现密码字段（C109：同宽、同样的间距）
                    LoginField(label: "密码", placeholder: "必填", text: $flow.password,
                               kind: .password, focus: $focus, field: .password, id: "login-password")
                        .submitLabel(.go)
                        .onSubmit { Task { await flow.submit() } }
                        .transition(reduceMotion ? AnyTransition.opacity
                                                 : AnyTransition.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 32)

            StatusLine(text: flow.status, bad: flow.statusBad)
                .padding(.top, 10)

            Button { Task { await flow.submit() } } label: {
                LoginButtonLabel(title: flow.primaryTitle, busy: flow.busy)
            }
            .buttonStyle(LoginPrimaryStyle(busy: flow.busy))
            .disabled(!flow.primaryEnabled)
            .padding(.top, 24)
            .accessibilityIdentifier("login-primary")

            if flow.faceIDOffered {
                // C100、C101：按钮写明是哪一种方法，设备上没有就不出现（faceIDOffered 已经看过 biometryAvailable）
                let name = flow.account.biometryName
                Button { Task { await flow.faceIDLogin() } } label: {
                    Label("使用\(name)登录", systemImage: biometrySymbol(name))
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(flow.busy)
                .padding(.top, 12)
                .accessibilityIdentifier("login-biometric")
            }

            // 其余的路都是纯文字按钮（C35：一页只有一颗醒目的钮）
            Group {
                if flow.mode == .login {
                    HStack {
                        Button("改用邮箱验证码登录") { flow.openEmail(.login) }
                        Spacer(minLength: 16)
                        Button("忘记密码？") { flow.openEmail(.forgot) }
                    }
                } else if flow.mode == .idle {
                    Button("使用电子邮件验证码登录") { flow.openEmail(.login) }
                }
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
            .padding(.top, 20)

            // C98：为什么要账户、账户还能用在哪——一句就够
            Text("片库只对 Cuven 账户开放。一个账户即可登录 Cuven max、Cuven TV 以及 Cuven 的其他服务。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 40)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: flow.mode)
    }

    // MARK: ② 电子邮件

    private var emailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(flow.emailTitle, flow.emailSubtitle)
            LoginField(label: "电子邮件", placeholder: "name@example.com", text: $flow.emailInput,
                       kind: .email, focus: $focus, field: .email, id: "login-email")
                .submitLabel(.send)
                .onSubmit { Task { await flow.sendCode(email: flow.emailInput, intent: flow.intent) } }
                .padding(.top, 32)
            StatusLine(text: flow.status, bad: flow.statusBad)
                .padding(.top, 10)
            Button { Task { await flow.sendCode(email: flow.emailInput, intent: flow.intent) } } label: {
                LoginButtonLabel(title: "发送验证码", busy: flow.busy)
            }
            .buttonStyle(LoginPrimaryStyle(busy: flow.busy))
            // C110：地址像样了才能发
            .disabled(!LoginFlow.isEmail(flow.emailInput.trimmingCharacters(in: .whitespaces)) || flow.busy)
            .padding(.top, 24)
            .accessibilityIdentifier("login-send-code")
        }
        .task { await focusSoon(.email) }
    }

    // MARK: ③ 验证码

    private var codePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("输入验证码", "验证码已发送至 \(flow.otpEmail)")
            CodeBoxes(code: $flow.code, bad: flow.statusBad, focus: $focus)
                .onChange(of: flow.code) { _, _ in flow.codeChanged() }
                .padding(.top, 32)
            StatusLine(text: flow.status, bad: flow.statusBad)
                .padding(.top, 10)
            Button { Task { await flow.verify() } } label: {
                LoginButtonLabel(title: flow.verifyTitle, busy: flow.busy)
            }
            .buttonStyle(LoginPrimaryStyle(busy: flow.busy))
            .disabled(flow.code.count < 6 || flow.busy)
            .padding(.top, 24)
            .accessibilityIdentifier("login-verify")
            Button { Task { await flow.resend() } } label: {
                Text(resendTitle)
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
            .disabled(flow.resendLeft > 0)
            .padding(.top, 20)
            .accessibilityIdentifier("login-resend")
        }
        .task { await focusSoon(.code) }
    }

    // MARK: ④ 设定密码

    private var passwordPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(flow.passTitle, flow.passSubtitle)
            VStack(alignment: .leading, spacing: 20) {
                LoginField(label: "新密码", placeholder: "至少 8 个字符，含字母和数字", text: $flow.pw1,
                           kind: .newPassword, focus: $focus, field: .pw1, id: "login-new-password")
                    .submitLabel(.next)
                    .onSubmit { focus = .pw2 }
                LoginField(label: "确认密码", placeholder: "再输入一次", text: $flow.pw2,
                           kind: .newPassword, focus: $focus, field: .pw2, id: "login-confirm-password")
                    .submitLabel(.done)
                    .onSubmit { Task { await flow.savePassword() } }
            }
            .padding(.top, 32)
            StatusLine(text: flow.passHint.isEmpty ? flow.status : flow.passHint,
                       bad: flow.passHint.isEmpty ? flow.statusBad : passHintBad)
                .padding(.top, 10)
            Button { Task { await flow.savePassword() } } label: {
                LoginButtonLabel(title: flow.passButton, busy: flow.busy)
            }
            .buttonStyle(LoginPrimaryStyle(busy: flow.busy))
            .disabled(!flow.passValid || flow.busy)
            .padding(.top, 24)
            .accessibilityIdentifier("login-save-password")
            if flow.passMode == .upgrade {
                Button("暂不设定，直接登录") { flow.skipPassword() }
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 20)
            }
        }
        .task { await focusSoon(.pw1) }
    }

    /// 「重新发送验证码」；倒计时没走完时写还要等几秒（C69：说具体的）
    private var resendTitle: String {
        flow.resendLeft > 0 ? "\(flow.resendLeft) 秒后可重新发送" : "重新发送验证码"
    }

    /// C110：新密码在输入时就核对；还在写的那个字段里只是灰字提示，离开了还不对才变红
    private var passHintBad: Bool {
        if !flow.pw1.isEmpty && !PasswordHash.isStrong(flow.pw1) { return focus != .pw1 }
        if !flow.pw2.isEmpty && flow.pw1 != flow.pw2 { return focus != .pw2 || flow.pw2.count >= flow.pw1.count }
        return false
    }

    // MARK: ⑤ 生物识别

    private var faceIDPane: some View {
        let name = flow.account.biometryName
        return VStack(alignment: .leading, spacing: 0) {
            Image(systemName: biometrySymbol(name))
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
                .padding(.bottom, 20)
            header("启用\(name)", "下次用\(name)即可登录，不用再输入密码。\(name)的数据由系统保管在这台设备的安全隔区里，Cuven 接触不到。")
            Button { Task { await flow.enableFaceID() } } label: {
                LoginButtonLabel(title: "启用\(name)", busy: flow.busy)
            }
            .buttonStyle(LoginPrimaryStyle(busy: flow.busy))
            .disabled(flow.busy)
            .padding(.top, 32)
            .accessibilityIdentifier("login-enable-biometric")
            Button("以后再说") { flow.go(.done) }
                .buttonStyle(.borderless)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.top, 12)
                .disabled(flow.busy)
        }
        .task { focus = nil }
    }

    // MARK: ⑥ 完成

    private var donePane: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Theme.accent)
                .symbolEffect(.bounce, value: celebrate)
                .accessibilityHidden(true)
                .padding(.bottom, 20)
            Text(flow.doneTitle)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(flow.doneSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Button { flow.finish() } label: { Text("开始使用") }
                .buttonStyle(LoginPrimaryStyle())
                .padding(.top, 32)
                .accessibilityIdentifier("login-done")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .task {
            focus = nil
            // 推入动画走完再弹那一下；「减弱动态效果」打开时不弹（F59）
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(400))
            celebrate.toggle()
        }
    }

    // MARK: 小件

    /// 每一页的标题：Large Title 粗体 + 一句 Body 次要色（F15、F18、F84）
    private func header(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(sub)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 推进来的那一页：等推入动画走完再把光标放进字段（动画途中弹键盘会抖一下）
    private func focusSoon(_ f: LoginFocus) async {
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 450))
        guard !Task.isCancelled else { return }
        focus = f
    }
}

/// 这台设备上的生物识别用哪个符号（C101：只说设备真有的那一种，名字由 AccountStore.biometryName 给）
private func biometrySymbol(_ name: String) -> String {
    switch name {
    case "触控 ID": return "touchid"
    case "光学 ID": return "opticid"
    default: return "faceid"
    }
}

// MARK: - 组件

/// 每一步的版面：一列，展开的 Duo 上不超过 440 宽、居中（F8），左右边距按屏宽（S3），上下留足白（F12）；
/// 内容比屏幕矮时也从上往下排；往下拖就收起键盘
private struct LoginPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: 440, alignment: .leading)
                .padding(.horizontal, max(24, (geo.size.width * 80 / 1920).rounded()))
                .padding(.top, max(16, (geo.size.height * 0.06).rounded()))
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// 一个字段：上面一行标签（C105）、框里一句提示；竖排、同宽（C109）。
/// 账户和电子邮件的字段在尾部有一颗清除钮（C108）；密码是 SecureField，从不预填（C106）。
/// 底色是系统的分组单元格色，不画描边（F3）
private struct LoginField: View {
    enum Kind { case account, email, password, newPassword }

    let label: String
    let placeholder: String
    @Binding var text: String
    let kind: Kind
    var focus: FocusState<LoginFocus?>.Binding
    let field: LoginFocus
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                // 字段自己念同一个标签，这一行不再单独念
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                input
                    .focused(focus, equals: field)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(id)
                if showsClear {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除")
                }
            }
            .font(.body)
            .padding(.leading, 16)
            .padding(.trailing, showsClear ? 8 : 16)
            .frame(minHeight: 50)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var showsClear: Bool {
        (kind == .account || kind == .email) && !text.isEmpty && focus.wrappedValue == field
    }

    /// C107、C111：键盘和内容类型对得上，系统才知道往这里自动填什么
    @ViewBuilder
    private var input: some View {
        switch kind {
        case .account:
            TextField(placeholder, text: $text)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .email:
            TextField(placeholder, text: $text)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .password:
            SecureField(placeholder, text: $text)
                .textContentType(.password)
        case .newPassword:
            SecureField(placeholder, text: $text)
                .textContentType(.newPassword)
        }
    }
}

/// 6 位验证码：一个看不见的系统字段收字——短信 / 邮件里的验证码自动填充、整段粘贴都走它（C111、C112）；
/// 上面 6 个格子只负责显示，正在等的那一格描一圈强调色（F32：强调色只给状态）
private struct CodeBoxes: View {
    @Binding var code: String
    let bad: Bool
    var focus: FocusState<LoginFocus?>.Binding

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
                .focused(focus, equals: .code)
                .accessibilityLabel("验证码")
                .accessibilityIdentifier("login-code")
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in box(i) }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func box(_ i: Int) -> some View {
        let chars = Array(code)
        let ch = i < chars.count ? String(chars[i]) : ""
        let waiting = focus.wrappedValue == .code && chars.count < 6 && i == chars.count
        return Text(ch)
            .font(.title2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(bad ? Color.red : (waiting ? Theme.accent : Color.clear), lineWidth: 1.5)
            }
    }
}

/// 字段下面的一行（C69：说清楚正在做什么）。出错时红字加一枚符号，不只靠颜色（F36、F87）；
/// 没有字时也占着一行，字出现、消失时版面不跳（C23）
private struct StatusLine: View {
    let text: String
    let bad: Bool

    var body: some View {
        Group {
            if bad && !text.isEmpty {
                Label(text, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Text(text.isEmpty ? " " : text)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(text.isEmpty)
    }
}

/// 主按钮里的字；忙的时候换成系统的转圈，按钮大小不变（C66–C69）
private struct LoginButtonLabel: View {
    let title: String
    let busy: Bool

    var body: some View {
        ZStack {
            Text(title).opacity(busy ? 0 : 1)
            if busy { ProgressView().tint(.black) }
        }
    }
}

/// 主按钮：白色胶囊黑字（和全 App 的 .dsPlay 一个样子：C35、S17），拉满一行、至少 50 高（F74）。
/// 要的数据没填好时是灰的（C110）；忙的时候虽然点不了，颜色保持不变，只有里面在转圈
private struct LoginPrimaryStyle: ButtonStyle {
    var busy = false

    func makeBody(configuration: Configuration) -> some View {
        LoginPrimaryBody(configuration: configuration, busy: busy)
    }
}

private struct LoginPrimaryBody: View {
    let configuration: ButtonStyleConfiguration
    let busy: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let on = isEnabled || busy
        configuration.label
            .font(.headline)
            .foregroundStyle(on ? Color.black : Color.white.opacity(0.35))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(on ? Color.white : Color.white.opacity(0.14), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
