import SwiftUI
import UIKit

// MARK: - 登录 Cuven max：和网页版一模一样（web/index.html 的 #cvlHost；用户要求「登录和播放加载应该和web端一模一样」）
//
// 以前这一页按 Apple HIG 做成了系统导航栈；用户明确要求和网页版一模一样，这里照网页版逐项重做（HIG 让位，记在 docs/ios-design.md「登录」）：
// · 底图：网页版「Sky Pro 流体」着色器逐行移植（SkyFluid.metal），0.9 秒淡入；上面一层暗幕（0.34 → 0.16 → 0.30）。
// · 品牌区（上 24% 屏高，118…250）：居中的「Cuven max」圆体字标；打开时、登录成功时，蓝色光晕和光环从字标往外扩。
// · 下面一整张白色面板（上圆角 40）：「Cuven 账户」小字标 → 左对齐大标题 → 浅灰填充的输入框 → 黑色胶囊主按钮 → 分割线 + 账户体系说明。
//   宽屏（宽 ≥ 640 且高 ≥ 540）收成居中的一张卡；矮横屏（高 ≤ 539）品牌区压扁、字标排成一行、内容收在 560 宽里。
// · 六页（登录 / 电子邮件 / 验证码 / 设定密码 / 面容 ID / 完成）在同一张面板里交叉淡入淡出，页容器的高度跟着当前页走（0.5 秒）。
// · 输入法弹起：面板整体上移（品牌区让出来），底边骑在键盘上沿。
// · 入场：面板 0.72 秒从屏底滑上来，字标从模糊里放大浮出，内容逐行浮起；
//   成功：表单逐条淡出，字标「吸一口气」，脉冲扩散，「已登录」浮现，约 3.7 秒后自动进入（也可以点「开始观看」）。
// 流程与网页版一致：
//   ① 账户：输用户名或电子邮件，停顿 0.48 秒自动查找
//        · 用户名、有密码 → 展开密码框登录（本机开过面容 ID 的可以直接用面容 ID）
//        · 电子邮件       → 直接发 6 位验证码（这个账户有密码时，可以改用密码登录）
//        · 旧版账户（没设过密码）→ 邮箱验证码，登录后补设密码
//        · 用户名不存在   → 建立账户：验证邮箱 → 设定密码 → 面容 ID（可以暂不启用）
//   ② 电子邮件 ③ 验证码 ④ 设定密码 ⑤ 面容 ID ⑥ 完成
// 登录状态在最后一步才写进钥匙串（写进去登录层就淡出了）。

@MainActor
@Observable
final class LoginFlow {
    enum Pane: Hashable, CaseIterable { case signin, email, code, password, faceID, done }
    enum Mode { case idle, login, otp, legacy, register }
    enum Intent { case login, register, legacy, forgot }
    enum PassMode { case register, upgrade, renew }
    enum Kind { case login, register }
    /// 状态行的颜色（网页版 .cvl-status 的 found / good / bad）
    enum Tone { case plain, found, good, bad }

    struct Status: Equatable {
        var text = ""
        var tone: Tone = .plain
    }

    /// 验证邮箱、设定密码时带着的账户（网页版 st.passCtx）
    struct Context {
        var name = ""
        var email = ""
        var record: AccountRecord?
    }

    /// 让界面过一小会儿把光标放进某个字段（网页版 go(name, focusEl) 的 260 毫秒）
    struct FocusRequest: Equatable {
        var field: LoginFocus?
        var delay: Double = 0
        var serial = 0
    }

    private(set) var pane: Pane = .signin

    // ① 账户
    private(set) var mode: Mode = .idle
    private(set) var input = ""
    var password = ""
    /// 输入框里的绿勾：认出了这个账户
    private(set) var accountFound = false
    private var faceIDUnavailable = false

    // ② 电子邮件
    private(set) var emailInput = ""

    // ③ 验证码
    private(set) var code = ""
    private(set) var codeError = false
    /// 验证通过、正在读账户：主按钮保持不可点
    private(set) var codeLocked = false
    private(set) var resendLeft = 0
    private(set) var resending = false

    // ④ 设定密码
    private(set) var pw1 = ""
    private(set) var pw2 = ""

    // ⑤ 面容 ID
    private(set) var faceBusy = false
    private(set) var faceSaving = false

    // 公用
    private(set) var statuses: [Pane: Status] = [:]
    private(set) var busy = false
    /// 哪一页的主按钮在转圈
    private(set) var spinning: Pane?
    private(set) var focusRequest = FocusRequest()

    // ⑥ 完成
    private(set) var doneTitle = "已登录 Cuven Max"
    private(set) var doneSub = "欢迎回来"
    private(set) var successAt: Date?
    private(set) var successFrom: Pane = .signin
    var reduceMotion = false

    private(set) var intent: Intent = .login
    private(set) var passMode: PassMode = .register
    private(set) var user = ""
    private(set) var record: AccountRecord?
    private(set) var otpEmail = ""
    private var otpUser = ""
    private var ctx = Context()
    private var codeBack: Pane = .signin
    private var lastTried = ""
    private var lastResolved = ""
    private var seq = 0
    private var checkTask: Task<Void, Never>?
    private var countdown: Task<Void, Never>?
    private var faceTask: Task<Void, Never>?
    private var autoFinish: Task<Void, Never>?
    private var faceRecord: AccountRecord?
    private var finished = false

    /// 验证通过、还没写进钥匙串的身份
    private(set) var pending: AccountSession?
    private(set) var pendingKind: Kind = .login

    let account: AccountStore
    /// 这台设备的生物识别叫什么（面容 ID / 触控 ID / 光学 ID）；网页版写死「面容 ID」
    let bio: String
    /// 「请在系统弹窗中完成面容验证…」那一句里的说法
    private var bioVerb: String { bio == "面容 ID" ? "面容" : bio + " " }

    init(account: AccountStore) {
        self.account = account
        bio = account.biometryName
        // 网页版：本机开过面容 ID 的账户、或上次登录的账户，直接预填并查找
        let preset = account.faceIDUser ?? UserDefaults.standard.string(forKey: "cuven_last_user") ?? ""
        input = preset.trimmingCharacters(in: .whitespaces)
    }

    static func isEmail(_ s: String) -> Bool {
        s.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    func status(_ p: Pane) -> Status { statuses[p] ?? Status() }

    private func set(_ p: Pane, _ text: String, _ tone: Tone = .plain) {
        statuses[p] = Status(text: text, tone: tone)
    }

    private func request(_ f: LoginFocus?, after delay: Double = 0) {
        focusRequest = FocusRequest(field: f, delay: delay, serial: focusRequest.serial + 1)
    }

    /// 换一页；要放光标的话 260 毫秒后放（网页版 go）
    private func go(_ p: Pane, focus f: LoginFocus? = nil) {
        pane = p
        if let f { request(f, after: 0.26) }
    }

    /// 打开登录层：有预填的账户就直接去查（不自动弹键盘：网页版说一进来就弹输入法，屏幕会先被顶一下再回落）
    func start() {
        if !input.isEmpty { resolveAccount() }
    }

    // MARK: ① 账户

    /// 输入框里打字：停顿 0.48 秒再查（网页版 input 事件）
    func userTyped(_ v: String) {
        input = v
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(480))
            guard !Task.isCancelled else { return }
            self?.resolveAccount()
        }
    }

    /// 回车：马上查，认出是有密码的账户就把光标推到密码框
    func userSubmitted() {
        checkTask?.cancel()
        resolveAccount(focusNext: true)
    }

    /// 离开输入框：还没查过（或改过以后还没查）就查一次
    func userBlurred() {
        guard successAt == nil else { return }
        checkTask?.cancel()
        let raw = input.trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty && (mode == .idle || raw != lastResolved) { resolveAccount() }
    }

    private func resetSignin() {
        mode = .idle
        record = nil
        user = ""
        accountFound = false
        password = ""
        faceIDUnavailable = false
    }

    func resolveAccount(focusNext: Bool = false) {
        checkTask?.cancel()
        let raw = input.trimmingCharacters(in: .whitespaces)
        seq += 1
        let my = seq
        resetSignin()
        lastResolved = raw
        if raw.isEmpty { set(.signin, ""); return }
        // 邮箱还没打完就别去查，否则一路「未找到账户」闪个不停
        if raw.contains("@") && !Self.isEmail(raw) { set(.signin, "继续输入电子邮件…"); return }
        set(.signin, "正在查找账户…")
        Task { await resolve(raw, seq: my, focusNext: focusNext) }
    }

    private func resolve(_ raw: String, seq my: Int, focusNext: Bool) async {
        let byEmail = raw.contains("@")
        var name = raw
        if byEmail {
            let n = await AccountAPI.lookupEmail(raw)
            guard my == seq else { return }
            guard let n else { set(.signin, "无法连接账户服务，请检查网络", .bad); return }
            if n.isEmpty { set(.signin, "未找到绑定此邮箱的账户 · 可改用用户名登录", .bad); return }
            name = n
        }
        let r = await AccountAPI.fetchRecord(name)
        guard my == seq else { return }
        switch r {
        case .offline:
            set(.signin, "无法连接账户服务，请检查网络", .bad)
        case .missing:
            if byEmail {
                set(.signin, "未找到绑定此邮箱的账户 · 可改用用户名登录", .bad)
            } else {
                mode = .register
                user = name
                set(.signin, "新用户 — 将建立您的账户", .found)
            }
        case .found(let rec):
            guard let rec else { set(.signin, "读取账户资料失败，请稍后再试", .bad); return }
            record = rec
            user = name
            accountFound = true
            if byEmail {
                // 打的是邮箱 → 直接走验证码，不问密码（旧版账户也一样）
                mode = .otp
                otpEmail = raw.lowercased()
                set(.signin, "以 \(name) 的身份登录 · 验证码将发送至此邮箱", .found)
            } else if rec.hasPass {
                mode = .login
                set(.signin, "以 \(name) 的身份登录", .found)
                if focusNext { request(.password) }
            } else {
                // 旧版账户：用邮箱验证码验明身份，登录后设定密码完成升级
                mode = .legacy
                set(.signin, "旧版账户 · 请用邮箱验证码登录", .found)
            }
        }
    }

    var primaryTitle: String {
        switch mode {
        case .idle: return "继续"
        case .login: return "登录"
        case .otp: return "发送验证码"
        case .legacy: return "邮箱验证登录"
        case .register: return "建立账户"
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

    /// 「使用面容 ID 登录」：本机为这个账户开过面容 ID
    var faceIDOffered: Bool {
        mode == .login && !faceIDUnavailable && account.faceIDUser == user && account.biometryAvailable
    }

    /// 次级链接：密码登录时是「忘记密码？」；邮箱登录、而这个账户有密码时是「改用密码登录」
    var otpAltTitle: String? {
        if mode == .login { return "忘记密码？" }
        if mode == .otp && record?.hasPass == true { return "改用密码登录" }
        return nil
    }

    func signinSubmit() async {
        guard !busy else { return }
        switch mode {
        case .idle: break
        case .otp: await doSend(email: otpEmail.isEmpty ? input : otpEmail, intent: .login, ctx: Context(), from: .signin)
        case .legacy: openEmail(.legacy, ctx: Context(name: user, record: record))
        case .register: openEmail(.register, ctx: Context(name: user))
        case .login: await passwordLogin()
        }
    }

    private func passwordLogin() async {
        guard mode == .login, !password.isEmpty else { return }
        busy = true
        spinning = .signin
        set(.signin, "正在验证…")
        var rec = record
        if rec?.hasPass != true {
            if case .found(let r) = await AccountAPI.fetchRecord(user) { rec = r } else { rec = nil }
        }
        guard let rec, let pass = rec.pass, rec.hasPass else {
            busy = false
            spinning = nil
            set(.signin, "无法读取账户资料，请稍后再试", .bad)
            return
        }
        let ok = await PasswordHash.check(password, pass)
        busy = false
        spinning = nil
        guard ok else {
            set(.signin, "密码不正确，请重试", .bad)
            Haptics.error()
            request(.password)
            return
        }
        set(.signin, "")
        succeed(user, email: rec.email ?? "", method: "password", kind: .login)
    }

    func faceIDLogin() async {
        guard !busy else { return }
        busy = true
        spinning = .signin
        set(.signin, "请在系统弹窗中完成\(bioVerb)验证…")
        let (session, outcome) = await account.faceIDSession()
        busy = false
        spinning = nil
        if outcome == .ok, let session {
            set(.signin, "")
            succeed(session.username, email: session.email, method: "faceid", kind: .login)
            return
        }
        switch outcome {
        case .cancelled:
            set(.signin, "已取消\(bio) 验证")
        case .failed:
            set(.signin, "\(bio) 验证未通过", .bad)
        case .ok, .unavailable:
            set(.signin, "\(bio) 不可用，请输入密码登录", .bad)
            faceIDUnavailable = true
        }
    }

    func otpAltTapped() {
        if mode == .login {
            openEmail(.forgot, ctx: Context(name: user, record: record))
        } else if mode == .otp && record?.hasPass == true {
            // 邮箱那条路的软出口：留在这一页，只是把密码框展开
            mode = .login
            set(.signin, "以 \(user) 的身份登录", .found)
            Haptics.selection()
            request(.password, after: 0.2)
        }
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

    var emailSendEnabled: Bool {
        !busy && Self.isEmail(emailInput.trimmingCharacters(in: .whitespaces))
    }

    private func openEmail(_ i: Intent, ctx c: Context) {
        intent = i
        ctx = c
        var preset = ""
        if i == .login { preset = UserDefaults.standard.string(forKey: "cuven_email") ?? "" }
        else if i == .legacy || i == .forgot { preset = c.record?.email ?? "" }
        emailInput = preset
        set(.email, "")
        spinning = nil
        go(.email, focus: .email)
    }

    func emailTyped(_ v: String) {
        emailInput = v
        set(.email, "")
    }

    func sendEmailCode() async {
        await doSend(email: emailInput, intent: intent, ctx: ctx, from: .email)
    }

    /// 查邮箱 → 发验证码（网页版 doSend；从登录页直接发时，状态写在登录页）
    private func doSend(email raw: String, intent i: Intent, ctx c: Context, from p: Pane) async {
        guard !busy else { return }
        let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.isEmail(email) else { return }
        intent = i
        ctx = c
        busy = true
        spinning = p
        set(p, i == .register ? "正在检查邮箱…" : "正在查找账户…")
        func fail(_ msg: String) {
            busy = false
            spinning = nil
            set(p, msg, .bad)
        }
        guard let found = await AccountAPI.lookupEmail(email) else { fail("网络错误，请稍后再试"); return }
        switch i {
        case .register:
            if !found.isEmpty { fail("此电子邮件已绑定其他账户"); return }
            otpUser = c.name
        case .legacy, .forgot:
            if found.isEmpty { fail("此电子邮件未绑定任何账户，请确认拼写"); return }
            if found != c.name { fail("此邮箱绑定的是其他账户"); return }
            otpUser = c.name
        case .login:
            if found.isEmpty { fail("此电子邮件未绑定任何账户"); return }
            otpUser = found
        }
        otpEmail = email
        set(p, "正在发送验证码…")
        let j = await AccountAPI.sendCode(email)
        busy = false
        spinning = nil
        guard j?.ok == true else {
            set(p, j?.message ?? "发送失败，请稍后再试", .bad)
            return
        }
        set(p, "")
        openCode(from: p)
    }

    // MARK: ③ 验证码

    private func openCode(from p: Pane) {
        codeBack = p == .signin ? .signin : .email
        code = ""
        codeError = false
        codeLocked = false
        lastTried = ""
        set(.code, "")
        startCountdown(60)
        go(.code, focus: .code)
    }

    var codeEnabled: Bool { code.count == 6 && !busy && !codeLocked }

    /// 输入、粘贴、自动填充都走这里（清空格子不走：出错时的红框和提示要留着）
    func codeTyped(_ v: String) {
        let digits = String(v.filter(\.isNumber).prefix(6))
        code = digits
        codeError = false
        set(.code, "")
        // 同一组验证码只自动试一次，防止自动填充的错码被反复提交
        if digits.count == 6 && digits != lastTried { Task { await verifyCode() } }
    }

    func verifyCode() async {
        guard !busy, !codeLocked, code.count == 6 else { return }
        lastTried = code
        busy = true
        spinning = .code
        set(.code, "正在验证…")
        let j = await AccountAPI.verifyCode(otpEmail, code: code)
        busy = false
        spinning = nil
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
            set(.code, msg, .bad)
            codeError = true
            code = ""
            request(.code)
            Haptics.error()
            return
        }
        stopCountdown()
        switch intent {
        case .register:
            openPass(.register, ctx: Context(name: ctx.name, email: otpEmail))
        case .legacy:
            openPass(.upgrade, ctx: Context(name: ctx.name, email: otpEmail, record: ctx.record))
        case .forgot:
            openPass(.renew, ctx: Context(name: ctx.name, email: otpEmail, record: ctx.record))
        case .login:
            // 旧版账户 → 引导设定密码完成升级；v2 → 直接登录
            codeLocked = true
            set(.code, "登录成功，正在读取账户…")
            if case .found(let r) = await AccountAPI.fetchRecord(otpUser), let r, !r.hasPass {
                set(.code, "")
                openPass(.upgrade, ctx: Context(name: otpUser, email: otpEmail, record: r))
                return
            }
            succeed(otpUser, email: otpEmail, method: "email_otp", kind: .login)
        }
    }

    var resendTitle: String { resendLeft > 0 ? "\(resendLeft) 秒后可重新发送" : "重新发送" }
    var resendEnabled: Bool { resendLeft == 0 && !resending }

    func resend() async {
        guard resendEnabled, !otpEmail.isEmpty else { return }
        resending = true
        set(.code, "正在重新发送…")
        let j = await AccountAPI.sendCode(otpEmail)
        guard j?.ok == true else {
            set(.code, j?.message ?? "重新发送失败", .bad)
            resending = false
            return
        }
        set(.code, "验证码已重新发送")
        code = ""
        codeError = false
        lastTried = ""
        resending = false
        request(.code)
        startCountdown(60)
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

    private func stopCountdown() {
        countdown?.cancel()
        countdown = nil
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
        case .register: return "继续"
        case .upgrade: return "设定并登录"
        case .renew: return "更新并登录"
        }
    }

    var passEnabled: Bool { PasswordHash.isStrong(pw1) && pw1 == pw2 && !busy }

    private func openPass(_ m: PassMode, ctx c: Context) {
        passMode = m
        ctx = c
        pw1 = ""
        pw2 = ""
        set(.password, "")
        spinning = nil
        go(.password, focus: .pw1)
    }

    func pw1Typed(_ v: String) { pw1 = v; pwValidate() }
    func pw2Typed(_ v: String) { pw2 = v; pwValidate() }

    /// 边打边核对（网页版 pwValidate：提示是灰字，不是红字）
    private func pwValidate() {
        if !pw1.isEmpty && !PasswordHash.isStrong(pw1) { set(.password, "至少 8 个字元，需包含字母与数字") }
        else if !pw2.isEmpty && pw1 != pw2 { set(.password, "两次输入的密码不一致") }
        else { set(.password, "") }
    }

    func savePassword() async {
        guard passEnabled else { return }
        let name = ctx.name, prev = ctx.record
        busy = true
        spinning = .password
        set(.password, "正在加密…")
        let pass = await PasswordHash.make(pw1)
        let rec = AccountRecord.build(name: name, email: ctx.email, pass: pass, previous: prev)
        if passMode == .register {
            busy = false
            spinning = nil
            // 网页版：注册先到面容 ID 那一页，账户档在那一页最后才写。这台设备没有可用的生物识别就直接保存
            if account.biometryAvailable {
                set(.password, "")
                openFace(rec)
            } else {
                await finalize(rec, on: .password)
            }
            return
        }
        set(.password, "正在保存…")
        let ok = await AccountAPI.putRecord(rec)
        busy = false
        spinning = nil
        guard ok else {
            pwValidate()
            set(.password, "保存失败，请重试", .bad)
            return
        }
        if let e = rec.email, !e.isEmpty { Task { await AccountAPI.putEmailMap(e, username: name) } }
        AccountAPI.notify(passMode == .renew ? "password_changed" : "password_set", username: name)
        succeed(name, email: rec.email ?? "", method: "email_otp", kind: .login)
    }

    /// 旧版账户：暂不设定密码，直接登录（账户档保持旧版，下次仍走邮箱验证）
    func skipPassword() {
        guard passMode == .upgrade, !busy else { return }
        succeed(ctx.name, email: ctx.email, method: "email_otp", kind: .login)
    }

    // MARK: ⑤ 面容 ID（只在建立账户时出现，和网页版一样）

    var faceTitle: String { "启用\(bio)" }
    var faceSubtitle: String {
        let data = bio == "触控 ID" ? "指纹数据" : (bio == "光学 ID" ? "虹膜数据" : "面容数据")
        return "下次轻点一下即可登录。\(data)只保存在此设备的安全隔区，Cuven 不会接触。"
    }

    private func openFace(_ rec: AccountRecord) {
        faceRecord = rec
        faceBusy = false
        faceSaving = false
        set(.faceID, "正在准备\(bio)")
        go(.faceID)
        faceTask?.cancel()
        // 网页版：进来 0.62 秒后自动弹系统的验证
        faceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(620))
            guard !Task.isCancelled else { return }
            await self?.enrollFace()
        }
    }

    func enrollFace() async {
        guard !faceBusy, !faceSaving, let rec = faceRecord else { return }
        let name = rec.username ?? ""
        // 这台设备已经为这个账户开过（网页版 InvalidStateError）：当作已启用
        if account.faceIDUser == name {
            set(.faceID, "此设备已启用过\(bio)", .good)
            try? await Task.sleep(for: .milliseconds(520))
            await finalize(rec, on: .faceID)
            return
        }
        faceBusy = true
        spinning = .faceID
        set(.faceID, "请在系统弹窗中完成\(bioVerb)验证…")
        let session = AccountSession(username: name, email: (rec.email ?? "").lowercased(), method: "register", at: Date())
        let outcome = await account.enableFaceID(for: session)
        faceBusy = false
        spinning = nil
        switch outcome {
        case .ok:
            set(.faceID, "\(bio) 已启用", .good)
            Haptics.success()
            try? await Task.sleep(for: .milliseconds(520))
            await finalize(rec, on: .faceID)
        case .cancelled:
            set(.faceID, "已取消 · 可重试或暂不启用")
        case .failed, .unavailable:
            set(.faceID, "此设备暂无法启用\(bio)，可暂不启用", .bad)
        }
    }

    func skipFace() async {
        guard !faceBusy, !faceSaving, let rec = faceRecord else { return }
        faceTask?.cancel()
        await finalize(rec, on: .faceID)
    }

    /// 写账户档 + 邮箱映射 → 成功（网页版 finalize）
    private func finalize(_ rec: AccountRecord, on p: Pane) async {
        let name = rec.username ?? ""
        set(p, "正在保存…")
        busy = true
        spinning = p
        if p == .faceID { faceSaving = true }
        let code = await AccountAPI.putRecordStatus(rec)
        busy = false
        spinning = nil
        faceSaving = false
        guard (200..<300).contains(code) else {
            set(p, "保存失败（\(code == 0 ? "网络错误" : String(code))）· 请重试", .bad)
            return
        }
        if let e = rec.email, !e.isEmpty { Task { await AccountAPI.putEmailMap(e, username: name) } }
        AccountAPI.notify("welcome", username: name)
        succeed(name, email: rec.email ?? "", method: "register", kind: .register,
                title: "账户已建立", sub: "欢迎加入 Cuven Max，\(name)")
    }

    // MARK: ⑥ 完成

    private func succeed(_ name: String, email: String, method: String, kind: Kind, title: String? = nil, sub: String? = nil) {
        pending = AccountSession(username: name, email: email.lowercased(), method: method, at: Date())
        pendingKind = kind
        user = name
        UserDefaults.standard.set(name, forKey: "cuven_last_user")
        if !email.isEmpty { UserDefaults.standard.set(email.lowercased(), forKey: "cuven_email") }
        doneTitle = title ?? "已登录 Cuven Max"
        doneSub = sub ?? "欢迎回来，\(name)"
        successFrom = pane
        successAt = Date()
        pane = .done
        Haptics.success()
        // 网页版：整段成功动效（2.27 秒）放完再停 1.4 秒自动进入；「减弱动态效果」时 0.9 秒
        let wait = reduceMotion ? 0.9 : 3.67
        autoFinish?.cancel()
        autoFinish = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// 写进钥匙串：登录层随之淡出（网页版 closeTVAccount：0.2 秒，cubic-bezier(.55, .06, .68, .35)）
    func finish() {
        guard !finished, let p = pending else { return }
        finished = true
        autoFinish?.cancel()
        withAnimation(.timingCurve(0.55, 0.06, 0.68, 0.35, duration: 0.2)) {
            account.signIn(username: p.username, email: p.email, method: p.method, alert: pendingKind == .login)
        }
    }

    // MARK: 左上角的返回

    /// nil：不显示（登录页不能关、面容 ID 与完成两页不能退）
    var navShowsBack: Bool {
        pane == .email || pane == .code || pane == .password
    }

    func navTapped() {
        Haptics.selection()
        switch pane {
        case .code:
            stopCountdown()
            if codeBack == .signin { go(.signin) } else { go(.email, focus: .email) }
        case .email, .password:
            // 中途放弃：回到登录页、重新查一次
            go(.signin)
            set(.signin, "")
            resolveAccount()
        default:
            break
        }
    }
}

// MARK: - 界面

/// 光标在哪个字段里
enum LoginFocus: Hashable { case input, password, email, code, pw1, pw2 }

struct LoginView: View {
    @Environment(AccountStore.self) private var account
    @State private var flow: LoginFlow?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let flow { LoginScreen(flow: flow) }
        }
        .onAppear {
            guard flow == nil else { return }
            let f = LoginFlow(account: account)
            flow = f
            f.start()
        }
    }
}

/// 网页版 #cvlHost 的尺寸（全部按整个屏幕算，和网页版的视口一样）
private struct LoginMetrics {
    let W: CGFloat
    let H: CGFloat
    let safe: EdgeInsets
    let kb: CGFloat

    /// @media (min-width: 640px) and (min-height: 540px)：居中的一张卡
    var wide: Bool { W >= 640 && H >= 540 }
    /// @media (orientation: landscape) and (max-height: 539px)：品牌区压扁、字标一行
    var short: Bool { W > H && H <= 539 }
    /// --cvl-head：面板上沿离屏顶（含状态栏）
    var head: CGFloat {
        if wide { return min(280, max(170, H * 0.27)) }
        if short { return max(84, H * 0.22) }
        return min(250, max(118, H * 0.24))
    }
    var w1: CGFloat { min(25, max(16, H * 0.027)) }
    var w2: CGFloat { short ? min(44, max(30, H * 0.09)) : min(64, max(38, H * 0.066)) }
    /// 字标与脉冲的圆心：安全区以下的品牌区正中
    var headCenterY: CGFloat { safe.top + (head - safe.top) / 2 }
    var titleSize: CGFloat { min(33, max(27, W * 0.078)) }
    var dockTop: CGFloat { max(safe.top + (wide ? 72 : 64), head - kb) }
    var cardWidth: CGFloat { min(480, W - 48) }
    var cardMaxHeight: CGFloat { max(160, H - head - 40) }
    var padTop: CGFloat { wide ? 40 : (short ? 24 : 34) }
    var padLeading: CGFloat { wide ? 40 : max(24, safe.leading + 16) }
    var padTrailing: CGFloat { wide ? 40 : max(24, safe.trailing + 16) }
    var padBottom: CGFloat { wide ? 36 : 30 + safe.bottom }
}

private struct LoginScreen: View {
    @Bindable var flow: LoginFlow
    @FocusState private var focus: LoginFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 打开的那一刻（第一帧就在动效里：不会先闪一帧终态）
    @State private var openAt = Date()
    @State private var fxTick = 0
    /// 面板滑到位以后，流体只画露在面板上面的那一截
    @State private var settled = false
    @State private var heights: [LoginFlow.Pane: CGFloat] = [:]
    @State private var cardContent: CGFloat = 0
    @State private var keyboardTop = CGFloat.greatestFiniteMagnitude
    @State private var passRevealed = false
    @State private var pwRevealed = false

    var body: some View {
        GeometryReader { geo in
            let ins = geo.safeAreaInsets
            let W = geo.size.width + ins.leading + ins.trailing
            let H = geo.size.height + ins.top + ins.bottom
            let overlap = keyboardTop == .greatestFiniteMagnitude ? 0 : max(0, H - keyboardTop)
            // 网页版：48 点以下当作地址栏抖动，不算键盘
            let m = LoginMetrics(W: W, H: H, safe: ins, kb: overlap > 48 ? overlap : 0)
            let _ = fxTick
            let running = Date() < fxEnd
            TimelineView(.animation(paused: !running)) { tl in
                stage(m, fx(running ? tl.date : .distantFuture))
            }
            .frame(width: W, height: H)
            .position(x: geo.size.width / 2 + (ins.trailing - ins.leading) / 2,
                      y: geo.size.height / 2 + (ins.bottom - ins.top) / 2)
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            flow.reduceMotion = reduceMotion
            scheduleFxStop()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(760))
                settled = true
            }
        }
        .onChange(of: flow.successAt) { _, at in
            guard at != nil else { return }
            focus = nil
            scheduleFxStop()
        }
        .onChange(of: flow.focusRequest) { _, r in
            Task { @MainActor in
                if r.delay > 0 { try? await Task.sleep(for: .seconds(r.delay)) }
                guard flow.focusRequest == r else { return }
                focus = r.field
            }
        }
        .onChange(of: focus) { old, new in
            if old == .input && new != .input { flow.userBlurred() }
        }
        .onChange(of: flow.mode) { _, _ in passRevealed = false }
        .onChange(of: flow.pane) { _, p in if p == .password { pwRevealed = false } }
        // 输入法：面板整体上移、底边骑在键盘上沿（网页版 top / bottom .36s 的 iOS 曲线）
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
            guard let f = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            withAnimation(reduceMotion ? nil : CSSBezier.ios.animation(0.36)) { keyboardTop = f.minY }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(reduceMotion ? nil : CSSBezier.ios.animation(0.36)) { keyboardTop = .greatestFiniteMagnitude }
        }
        .accessibilityElement(children: .contain)
    }

    /// 入场（1.95 秒）/ 成功（2.5 秒）那几段动效：在这段时间里逐帧算（网页版 WAAPI），放完就停
    private var fxEnd: Date {
        var end = openAt.addingTimeInterval(1.95)
        if let at = flow.successAt { end = max(end, at.addingTimeInterval(2.5)) }
        return end
    }

    /// 动效放完时让时间线停下来（换一下 fxTick，整页重算一次、拿到终态）
    private func scheduleFxStop() {
        let wait = max(0, fxEnd.timeIntervalSinceNow) + 0.05
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            fxTick += 1
        }
    }

    private func fx(_ now: Date) -> LoginFx {
        let opened = now == .distantFuture ? Double.infinity : now.timeIntervalSince(openAt) * 1000
        var success: Double?
        if let at = flow.successAt {
            success = now == .distantFuture ? Double.infinity : now.timeIntervalSince(at) * 1000
        }
        return LoginFx(opened: opened, success: success, reduce: reduceMotion)
    }

    // MARK: 整层

    private func stage(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
                .frame(width: m.W, height: m.H)
            SkyFluidView(size: CGSize(width: m.W, height: m.H), drawHeight: fluidHeight(m), still: reduceMotion)
                .opacity(fx.fluid)
            // 品牌区压一点暗，白色字标在流体最亮的那一刻也读得清
            LinearGradient(stops: [.init(color: .black.opacity(0.34), location: 0),
                                   .init(color: .black.opacity(0.16), location: 0.26),
                                   .init(color: .black.opacity(0.30), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: m.W, height: m.H)
                .opacity(fx.scrim)
                .allowsHitTesting(false)
            pulses(m, fx)
            head(m, fx)
            if flow.navShowsBack {
                Button { flow.navTapped() } label: { LoginNavGlyph() }
                    .buttonStyle(LoginNavStyle())
                    .accessibilityLabel("返回")
                    .accessibilityIdentifier("login-back")
                    .offset(x: 16, y: m.safe.top + 12)
            }
            dock(m, fx)
        }
        .frame(width: m.W, height: m.H, alignment: .topLeading)
        .clipped()
    }

    /// 流体只画看得见的那一截（面板到位以后，手机上只有品牌区和面板的圆角露出来）；着色器按整屏算，图案不变
    private func fluidHeight(_ m: LoginMetrics) -> CGFloat {
        guard settled, !m.wide else { return m.H }
        return min(m.H, max(m.head, m.safe.top + 64) + 48)
    }

    // MARK: 蓝色脉冲（中心落在字标上，压在白色面板之下）

    private func pulses(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        let g = fx.glow, r1 = fx.ring1, r2 = fx.ring2
        return ZStack {
            if g.opacity > 0.001 {
                PulseDisc(stops: LoginInk.glowStops, blur: 22).scaleEffect(g.scale).opacity(g.opacity)
            }
            if r1.opacity > 0.001 {
                PulseDisc(stops: LoginInk.ringStops, blur: 26).scaleEffect(r1.scale).opacity(r1.opacity)
            }
            if r2.opacity > 0.001 {
                PulseDisc(stops: LoginInk.ringStops, blur: 26).scaleEffect(r2.scale).opacity(r2.opacity)
            }
        }
        .frame(width: 760, height: 760)
        .position(x: m.W / 2, y: m.headCenterY)
        .frame(width: m.W, height: m.H)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 品牌区：Cuven max 字标（面容 ID 那一页外面一圈呼吸的扫描环）

    private func head(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        ZStack {
            if flow.pane == .faceID {
                LoginScanRing(reduce: reduceMotion)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            }
            LoginWordmark(m: m)
                .overlay {
                    // 成功时字标上闪一下（网页版 .cvl-tile-flash）
                    Ellipse()
                        .fill(EllipticalGradient(stops: [.init(color: .white.opacity(0.55), location: 0),
                                                         .init(color: LoginInk.glow.opacity(0.3), location: 0.55),
                                                         .init(color: LoginInk.glow.opacity(0), location: 1)],
                                                 center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                        .frame(width: 220, height: 150)
                        .opacity(fx.flash)
                }
                .scaleEffect(fx.innerScale)
                .scaleEffect(fx.tileScale)
                .opacity(fx.tileOpacity)
                .blur(radius: fx.tileBlur)
        }
        .frame(width: m.W, height: max(1, m.head - m.safe.top))
        .offset(y: m.safe.top)
        .allowsHitTesting(false)
    }

    // MARK: 白色面板

    @ViewBuilder
    private func dock(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        if m.wide {
            let w = m.cardWidth
            let h = max(1, min(cardContent > 0 ? cardContent : m.cardMaxHeight, m.cardMaxHeight))
            ScrollView(.vertical) {
                sheetContent(m, fx)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { v in
                        // 页容器高度那 0.5 秒的过渡，卡片跟着一起变（成功动效逐帧变时直接跟）
                        if cardContent == 0 || fx.drivesHeight || reduceMotion { cardContent = v }
                        else { withAnimation(CSSBezier.ios.animation(0.5)) { cardContent = v } }
                    }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .circular))
            .background {
                RoundedRectangle(cornerRadius: 34, style: .circular)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.45), radius: 45, y: 30)
                    .background(RoundedRectangle(cornerRadius: 35, style: .circular).fill(Color.white.opacity(0.06)).padding(-1))
            }
            .offset(x: (m.W - w) / 2, y: m.dockTop + h * 1.04 * CGFloat(fx.sheetShift))
        } else {
            let top = m.dockTop
            let h = max(1, m.H - top - m.kb)
            let shape = UnevenRoundedRectangle(topLeadingRadius: 40, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                               topTrailingRadius: 40, style: .circular)
            ZStack(alignment: .top) {
                // 白底一直铺到屏幕外：键盘起落的那一瞬，面板和键盘之间也不会露出流体
                shape
                    .fill(Color.white)
                    .frame(width: m.W, height: m.H - top + 80)
                    .shadow(color: .black.opacity(0.28), radius: 22, y: -12)
                ScrollView(.vertical) {
                    sheetContent(m, fx)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: m.W, height: h)
                .clipShape(shape)
            }
            .frame(width: m.W, height: m.H - top + 80, alignment: .top)
            .offset(y: top + h * 1.04 * CGFloat(fx.sheetShift))
        }
    }

    private func sheetContent(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LoginMark()
                .padding(.top, 2)
                .padding(.bottom, m.short ? 18 : 30)
            panes(m, fx)
            // 账户体系说明：只在输入账户 / 电子邮件这两页出现
            if flow.pane == .signin || flow.pane == .email {
                LoginFooter()
                    .padding(.top, 32)
            }
        }
        // 矮横屏：一行字拉满整屏读不动，内容收在中间 560 宽里
        .frame(maxWidth: m.short ? 560 : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.top, m.padTop)
        .padding(.leading, m.padLeading)
        .padding(.trailing, m.padTrailing)
        .padding(.bottom, m.padBottom)
        .contentShape(Rectangle())
        // 点空白处收起键盘（网页版：输入框失焦）
        .onTapGesture { focus = nil }
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("登录到 Cuven max")
    }

    // MARK: 各页

    private func panes(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        let current = heights[flow.pane]
        let from = flow.successAt != nil ? heights[flow.successFrom] : nil
        let driven = fx.panesHeight(from: from ?? current ?? 0, done: heights[.done] ?? 0)
        // 网页版 --cvl-h 起始是 496：第一次量到真值时从 496 过渡过去
        let height = driven ?? current ?? 496
        return ZStack(alignment: .topLeading) {
            ForEach(LoginFlow.Pane.allCases, id: \.self) { p in
                pane(p, m, fx)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { v in heights[p] = v }
                    .modifier(LoginPaneShow(phase: phase(p)))
                    .zIndex(p == flow.pane ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(driven != nil || reduceMotion ? nil : CSSBezier.ios.animation(0.5)) { content in
            content.frame(height: max(0, height), alignment: .top)
        }
    }

    private func phase(_ p: LoginFlow.Pane) -> LoginPaneShow.Phase {
        if p == flow.pane { return .on }
        if flow.successAt != nil && p == flow.successFrom && !reduceMotion { return .exiting }
        return .off
    }

    @ViewBuilder
    private func pane(_ p: LoginFlow.Pane, _ m: LoginMetrics, _ fx: LoginFx) -> some View {
        switch p {
        case .signin: signinPane(m, fx)
        case .email: emailPane(m, fx)
        case .code: codePane(m, fx)
        case .password: passwordPane(m, fx)
        case .faceID: facePane(m, fx)
        case .done: donePane(m, fx)
        }
    }

    /// 一页里第 i 个元素的动效：打开时逐个浮起（只有登录页），成功时逐条淡出（j = nil 是主按钮）
    private func child(_ p: LoginFlow.Pane, _ i: Int, _ j: Int?, _ fx: LoginFx) -> LoginChildFx {
        var r = LoginChildFx()
        if p == .signin { r = r.combined(fx.openChild(i)) }
        if flow.successAt != nil && p == flow.successFrom && p != .done { r = r.combined(fx.exitChild(j)) }
        return r
    }

    // ① 登录
    private func signinPane(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        let p = LoginFlow.Pane.signin
        return VStack(alignment: .leading, spacing: 0) {
            title("输入电子邮件以继续", m)
                .modifier(LoginChildMod(fx: child(p, 0, 0, fx)))
            sub(Text("使用你的 Cuven 账户登录 Cuven max。"))
                .modifier(LoginChildMod(fx: child(p, 1, 1, fx)))
                .padding(.top, 14)
            userField
                .modifier(LoginChildMod(fx: child(p, 2, 2, fx)))
                .padding(.top, 30)
            if flow.mode == .login {
                passwordField
                    .modifier(LoginRevealIn())
                    .modifier(LoginChildMod(fx: child(p, 3, 3, fx)))
                    .padding(.top, 12)
            }
            statusLine(p)
                .modifier(LoginChildMod(fx: child(p, 4, 4, fx)))
            LoginCTA(title: flow.primaryTitle, enabled: flow.primaryEnabled, busy: flow.spinning == p) {
                Task { await flow.signinSubmit() }
            }
            .accessibilityIdentifier("login-primary")
            .modifier(LoginChildMod(fx: child(p, 5, nil, fx)))
            .padding(.top, 24)
            if flow.faceIDOffered {
                LoginAlt(title: "使用\(flow.bio) 登录", enabled: !flow.busy) { Task { await flow.faceIDLogin() } }
                    .accessibilityIdentifier("login-biometric")
                    .modifier(LoginChildMod(fx: child(p, 6, 5, fx)))
                    .padding(.top, 6)
            }
            if let alt = flow.otpAltTitle {
                LoginAlt(title: alt) { flow.otpAltTapped() }
                    .accessibilityIdentifier("login-alt")
                    .modifier(LoginChildMod(fx: child(p, 7, 6, fx)))
                    .padding(.top, 6)
            }
        }
    }

    // ② 电子邮件
    private func emailPane(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        let p = LoginFlow.Pane.email
        return VStack(alignment: .leading, spacing: 0) {
            title(flow.emailTitle, m)
                .modifier(LoginChildMod(fx: child(p, 0, 0, fx)))
            sub(Text(flow.emailSubtitle))
                .modifier(LoginChildMod(fx: child(p, 1, 1, fx)))
                .padding(.top, 14)
            LoginInputBox(focused: focus == .email) {
                TextField("", text: Binding(get: { flow.emailInput }, set: { flow.emailTyped($0) }),
                          prompt: LoginInk.prompt("you@example.com"))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($focus, equals: .email)
                    .onSubmit { if flow.emailSendEnabled { Task { await flow.sendEmailCode() } } }
                    .accessibilityLabel("电子邮件")
                    .accessibilityIdentifier("login-email")
            } tap: { focus = .email }
            .modifier(LoginChildMod(fx: child(p, 2, 2, fx)))
            .padding(.top, 30)
            statusLine(p)
                .modifier(LoginChildMod(fx: child(p, 3, 3, fx)))
            LoginCTA(title: "发送验证码", enabled: flow.emailSendEnabled, busy: flow.spinning == p) {
                Task { await flow.sendEmailCode() }
            }
            .accessibilityIdentifier("login-send-code")
            .modifier(LoginChildMod(fx: child(p, 4, nil, fx)))
            .padding(.top, 24)
        }
    }

    // ③ 验证码
    private func codePane(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        let p = LoginFlow.Pane.code
        var lead = AttributedString("验证码已发送至 ")
        var mail = AttributedString(flow.otpEmail)
        mail.foregroundColor = LoginInk.ink
        mail.font = .system(size: 17, weight: .semibold)
        lead.append(mail)
        return VStack(alignment: .leading, spacing: 0) {
            title("输入验证码", m)
                .modifier(LoginChildMod(fx: child(p, 0, 0, fx)))
            sub(Text(lead))
                .modifier(LoginChildMod(fx: child(p, 1, 1, fx)))
                .padding(.top, 14)
            codeRow
                .modifier(LoginChildMod(fx: child(p, 2, 2, fx)))
                .padding(.top, 30)
            statusLine(p)
                .modifier(LoginChildMod(fx: child(p, 3, 3, fx)))
            LoginCTA(title: flow.verifyTitle, enabled: flow.codeEnabled, busy: flow.spinning == p) {
                Task { await flow.verifyCode() }
            }
            .accessibilityIdentifier("login-verify")
            .modifier(LoginChildMod(fx: child(p, 4, nil, fx)))
            .padding(.top, 24)
            LoginAlt(title: flow.resendTitle, enabled: flow.resendEnabled) { Task { await flow.resend() } }
                .accessibilityIdentifier("login-resend")
                .modifier(LoginChildMod(fx: child(p, 5, 4, fx)))
                .padding(.top, 6)
        }
    }

    // ④ 设定密码
    private func passwordPane(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        let p = LoginFlow.Pane.password
        return VStack(alignment: .leading, spacing: 0) {
            title(flow.passTitle, m)
                .modifier(LoginChildMod(fx: child(p, 0, 0, fx)))
            sub(Text(flow.passSubtitle))
                .modifier(LoginChildMod(fx: child(p, 1, 1, fx)))
                .padding(.top, 14)
            LoginInputBox(focused: focus == .pw1) {
                secureOrPlain(pwRevealed, text: Binding(get: { flow.pw1 }, set: { flow.pw1Typed($0) }), prompt: "密码")
                    .textContentType(.newPassword)
                    .submitLabel(.next)
                    .focused($focus, equals: .pw1)
                    .onSubmit {
                        if flow.pw2.isEmpty { focus = .pw2 }
                        else if flow.passEnabled { Task { await flow.savePassword() } }
                    }
                    .accessibilityLabel("密码")
                    .accessibilityIdentifier("login-new-password")
            } tap: { focus = .pw1 }
            .overlay(alignment: .topTrailing) {
                LoginEyeButton {
                    let was = focus
                    pwRevealed.toggle()
                    Haptics.selection()
                    keepFocus(was)
                }
                .padding(.top, 10)
                .padding(.trailing, 8)
            }
            .modifier(LoginChildMod(fx: child(p, 2, 2, fx)))
            .padding(.top, 30)
            LoginInputBox(focused: focus == .pw2) {
                secureOrPlain(pwRevealed, text: Binding(get: { flow.pw2 }, set: { flow.pw2Typed($0) }), prompt: "再次输入密码")
                    .textContentType(.newPassword)
                    .submitLabel(.go)
                    .focused($focus, equals: .pw2)
                    .onSubmit { if flow.passEnabled { Task { await flow.savePassword() } } }
                    .accessibilityLabel("再次输入密码")
                    .accessibilityIdentifier("login-confirm-password")
            } tap: { focus = .pw2 }
            .modifier(LoginChildMod(fx: child(p, 3, 3, fx)))
            .padding(.top, 12)
            statusLine(p)
                .modifier(LoginChildMod(fx: child(p, 4, 4, fx)))
            LoginCTA(title: flow.passButton, enabled: flow.passEnabled, busy: flow.spinning == p) {
                Task { await flow.savePassword() }
            }
            .accessibilityIdentifier("login-save-password")
            .modifier(LoginChildMod(fx: child(p, 5, nil, fx)))
            .padding(.top, 24)
            if flow.passMode == .upgrade {
                LoginAlt(title: "暂不设定，直接登录") { flow.skipPassword() }
                    .modifier(LoginChildMod(fx: child(p, 6, 5, fx)))
                    .padding(.top, 6)
            }
        }
    }

    // ⑤ 面容 ID
    private func facePane(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        let p = LoginFlow.Pane.faceID
        return VStack(alignment: .leading, spacing: 0) {
            title(flow.faceTitle, m)
                .modifier(LoginChildMod(fx: child(p, 0, 0, fx)))
            sub(Text(flow.faceSubtitle))
                .modifier(LoginChildMod(fx: child(p, 1, 1, fx)))
                .padding(.top, 14)
            statusLine(p)
                .modifier(LoginChildMod(fx: child(p, 2, 2, fx)))
            LoginCTA(title: flow.faceTitle, enabled: !flow.faceBusy && !flow.faceSaving,
                     busy: flow.spinning == p) {
                Task { await flow.enrollFace() }
            }
            .accessibilityIdentifier("login-enable-biometric")
            .modifier(LoginChildMod(fx: child(p, 3, nil, fx)))
            .padding(.top, 24)
            LoginAlt(title: "暂不启用，直接完成", enabled: !flow.faceSaving) { Task { await flow.skipFace() } }
                .modifier(LoginChildMod(fx: child(p, 4, 3, fx)))
                .padding(.top, 6)
        }
    }

    // ⑥ 完成：标题、问候、「开始观看」在成功动效里依次浮现
    private func donePane(_ m: LoginMetrics, _ fx: LoginFx) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            title(flow.doneTitle, m)
                .modifier(LoginChildMod(fx: fx.doneItem(0)))
            sub(Text(flow.doneSub))
                .modifier(LoginChildMod(fx: fx.doneItem(1)))
                .padding(.top, 10)
            LoginCTA(title: "开始观看", enabled: true, busy: false, dark: true) { flow.finish() }
                .accessibilityIdentifier("login-done")
                .modifier(LoginChildMod(fx: fx.doneItem(2)))
                .padding(.top, 34)
        }
    }

    // MARK: 字段

    private var userField: some View {
        LoginInputBox(focused: focus == .input) {
            TextField("", text: Binding(get: { flow.input }, set: { flow.userTyped($0) }),
                      prompt: LoginInk.prompt("电子邮件或用户名"))
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .input)
                .onSubmit { flow.userSubmitted() }
                .accessibilityLabel("电子邮件或用户名")
                .accessibilityIdentifier("login-user")
        } tap: { focus = .input }
        .overlay(alignment: .topTrailing) {
            // 认出账户：右侧一枚绿勾
            LoginGlyph(kind: .check)
                .stroke(LoginInk.good, style: StrokeStyle(lineWidth: 2.6 * 19 / 24, lineCap: .round, lineJoin: .round))
                .frame(width: 19, height: 19)
                .frame(width: 36, height: 36)
                .opacity(flow.accountFound ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: flow.accountFound)
                .padding(.top, 12)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var passwordField: some View {
        LoginInputBox(focused: focus == .password) {
            secureOrPlain(passRevealed, text: $flow.password, prompt: "密码")
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit { Task { await flow.signinSubmit() } }
                .accessibilityLabel("密码")
                .accessibilityIdentifier("login-password")
        } tap: { focus = .password }
        .overlay(alignment: .topTrailing) {
            LoginEyeButton {
                let was = focus
                passRevealed.toggle()
                Haptics.selection()
                keepFocus(was)
            }
            .padding(.top, 10)
            .padding(.trailing, 8)
        }
    }

    /// 「显示密码」换了一个字段（密文 ↔ 明文）：光标放回原来那一格（网页版只是改 input 的 type，光标不动）
    private func keepFocus(_ f: LoginFocus?) {
        guard let f else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            focus = f
        }
    }

    @ViewBuilder
    private func secureOrPlain(_ plain: Bool, text: Binding<String>, prompt: String) -> some View {
        if plain {
            TextField("", text: text, prompt: LoginInk.prompt(prompt))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            SecureField("", text: text, prompt: LoginInk.prompt(prompt))
        }
    }

    /// 6 位验证码：一个看不见的系统字段收字（短信 / 邮件验证码自动填充、整段粘贴都走它），上面 6 个格子只负责显示
    private var codeRow: some View {
        let chars = Array(flow.code)
        let active = focus == .code ? min(chars.count, 5) : -1
        return ZStack(alignment: .leading) {
            TextField("", text: Binding(get: { flow.code }, set: { flow.codeTyped($0) }))
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 62)
                .focused($focus, equals: .code)
                .accessibilityLabel("验证码")
                .accessibilityIdentifier("login-code")
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    LoginCodeBox(char: i < chars.count ? String(chars[i]) : "", focused: i == active, error: flow.codeError)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus = .code }
    }

    // MARK: 文字

    private func title(_ s: String, _ m: LoginMetrics) -> some View {
        Text(s)
            .font(.system(size: m.titleSize, weight: .bold))
            .tracking(-0.02 * m.titleSize)
            .foregroundStyle(LoginInk.ink)
            .cssLineHeight(1.2 * m.titleSize, size: m.titleSize, weight: .bold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func sub(_ t: Text) -> some View {
        t.font(.system(size: 17))
            .foregroundStyle(LoginInk.ink2)
            .cssLineHeight(25.5, size: 17, weight: .regular)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 状态行：没字的时候不占地方；有字时上面空 10、14 号字、行高 18
    @ViewBuilder
    private func statusLine(_ p: LoginFlow.Pane) -> some View {
        let s = flow.status(p)
        if !s.text.isEmpty {
            Text(s.text)
                .font(.system(size: 14, weight: s.tone == .plain ? .medium : .semibold))
                .foregroundStyle(LoginInk.tone(s.tone))
                .cssLineHeight(18, size: 14, weight: s.tone == .plain ? .medium : .semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .animation(.easeInOut(duration: 0.3), value: s.tone)
        }
    }
}

// MARK: - 动效（网页版 WAAPI 的关键帧、缓动、延迟逐项照搬；时间都是毫秒）

/// CSS 的 cubic-bezier(x1, y1, x2, y2)：给定进度求缓动后的值
struct CSSBezier {
    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// 网页版 --cvl-ios / --cvl-out / --cvl-in
    static let ios = CSSBezier(0.32, 0.72, 0, 1)
    static let easeOut = CSSBezier(0.22, 1, 0.36, 1)
    static let easeIn = CSSBezier(0.4, 0, 1, 1)
    static let linear = CSSBezier(0, 0, 1, 1)

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        if x1 == y1 && x2 == y2 { return x }
        let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
        let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
        func sx(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        func sy(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
        func dx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }
        var t = x
        for _ in 0..<8 {
            let e = sx(t) - x
            if abs(e) < 1e-7 { return sy(t) }
            let d = dx(t)
            if abs(d) < 1e-7 { break }
            t -= e / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<40 {
            let v = sx(t)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sy(t)
    }

    func animation(_ duration: Double) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }
}

/// 一个关键帧：offset、值、到下一帧这一段的缓动
private struct KF {
    let at: Double
    let v: Double
    let ease: CSSBezier

    init(_ at: Double, _ v: Double, _ ease: CSSBezier = .linear) {
        self.at = at; self.v = v; self.ease = ease
    }
}

private func track(_ p: Double, _ k: [KF]) -> Double {
    guard let first = k.first, let last = k.last else { return 0 }
    if p <= first.at { return first.v }
    for i in 0..<(k.count - 1) where p <= k[i + 1].at {
        let a = k[i], b = k[i + 1]
        let local = (p - a.at) / max(1e-9, b.at - a.at)
        return a.v + (b.v - a.v) * a.ease(local)
    }
    return last.v
}

/// WAAPI 的进度：延迟之前是 0、走完是 1（fill both / backwards），再套整段的缓动
private func prog(_ t: Double, _ delay: Double, _ dur: Double, _ ease: CSSBezier = .linear) -> Double {
    ease(min(1, max(0, (t - delay) / dur)))
}

struct LoginChildFx {
    var opacity = 1.0
    var dy = 0.0
    var blur = 0.0
    var scale = 1.0

    func combined(_ o: LoginChildFx) -> LoginChildFx {
        LoginChildFx(opacity: opacity * o.opacity, dy: dy + o.dy, blur: blur + o.blur, scale: scale * o.scale)
    }
}

private struct LoginFx {
    /// 打开以后过了多少毫秒（动效放完以后是 ∞）
    let opened: Double
    /// 成功以后过了多少毫秒
    let success: Double?
    let reduce: Bool

    private static let c1 = CSSBezier(0.1, 0.7, 0.3, 1)
    private static let c2 = CSSBezier(0.3, 0.1, 0.4, 1)

    // 打开：底图 0.9 秒淡入（--silk-present 的贝塞尔版），暗幕 0.62 秒，面板 0.72 秒从 104% 滑上来
    var fluid: Double { CSSBezier(0.30, 0.52, 0.07, 1)(min(1, max(0, opened / 900))) }
    var scrim: Double { prog(opened, 0, 620, .ios) }
    var sheetShift: Double { 1 - prog(opened, 0, 720, .ios) }

    // 字标：延迟 180 毫秒，0.68 秒里从 0.86 倍、模糊 8 放大浮出；成功时先微缩、再过冲、末端回落
    var tileOpacity: Double { prog(opened, 180, 680, .ios) }
    var tileBlur: Double { 8 * (1 - prog(opened, 180, 680, .ios)) }
    var tileScale: Double {
        let base = 0.86 + 0.14 * prog(opened, 180, 680, .ios)
        guard let t = success, !reduce else { return base }
        let td = 1110.0, s0 = 450.0 / td
        return base * track(prog(t, 0, td), [KF(0, 1), KF(s0, 1, CSSBezier(0.4, 0, 0.6, 1)),
                                             KF(s0 + (1 - s0) * 0.38, 0.94, CSSBezier(0.2, 0.7, 0.2, 1)),
                                             KF(s0 + (1 - s0) * 0.76, 1.07, CSSBezier(0.4, 0, 0.3, 1)), KF(1, 1)])
    }
    var innerScale: Double {
        guard let t = success, !reduce else { return 1 }
        return track(prog(t, 940, 760), [KF(0, 1, CSSBezier(0.2, 0.8, 0.2, 1)), KF(0.16, 1.05, .easeOut), KF(1, 1)])
    }
    var flash: Double {
        guard let t = success, !reduce else { return 0 }
        return track(prog(t, 940, 900), [KF(0, 0), KF(0.13, 0.3, .easeIn), KF(1, 0)])
    }

    // 蓝色脉冲：打开时光晕 + 一道光环；成功时光晕 + 两道光环
    var glow: (scale: Double, opacity: Double) {
        if let t = success, !reduce {
            let p = prog(t, 940, 1150)
            return (track(p, [KF(0, 0.26, Self.c1), KF(0.22, 0.74, Self.c2), KF(1, 1.5)]),
                    track(p, [KF(0, 0, Self.c1), KF(0.22, 1, Self.c2), KF(1, 0)]))
        }
        guard !reduce else { return (1, 0) }
        let p = prog(opened, 420, 1300)
        return (track(p, [KF(0, 0.3, Self.c1), KF(0.24, 0.78, Self.c2), KF(1, 1.45)]),
                track(p, [KF(0, 0, Self.c1), KF(0.24, 0.7, Self.c2), KF(1, 0)]))
    }
    var ring1: (scale: Double, opacity: Double) {
        if let t = success, !reduce {
            let p = prog(t, 1000, 1250)
            return (track(p, [KF(0, 0.2, .easeOut), KF(0.2, 0.7, Self.c2), KF(1, 1.75)]),
                    track(p, [KF(0, 0, .easeOut), KF(0.2, 0.6, Self.c2), KF(1, 0)]))
        }
        guard !reduce else { return (1, 0) }
        let p = prog(opened, 480, 1400)
        return (track(p, [KF(0, 0.24, .easeOut), KF(0.2, 0.72, Self.c2), KF(1, 1.7)]),
                track(p, [KF(0, 0, .easeOut), KF(0.2, 0.45, Self.c2), KF(1, 0)]))
    }
    var ring2: (scale: Double, opacity: Double) {
        guard let t = success, !reduce else { return (1, 0) }
        let p = prog(t, 1160, 1250)
        return (track(p, [KF(0, 0.16, .easeOut), KF(0.2, 0.66, Self.c2), KF(1, 2.0)]),
                track(p, [KF(0, 0, .easeOut), KF(0.2, 0.4, Self.c2), KF(1, 0)]))
    }

    /// 成功时页容器的高度：先收到「完成」页 + 12，再落位（1.09 秒）；不在这段里就是 nil
    func panesHeight(from h0: CGFloat, done hd: CGFloat) -> CGFloat? {
        guard let t = success, !reduce, t < 1090, hd > 0 else { return nil }
        let hm = Double(hd) + 12
        let p = prog(t, 0, 1090)
        return CGFloat(track(p, [KF(0, Double(h0), .ios), KF(420.0 / 1090, hm), KF(450.0 / 1090, hm, .ios), KF(1, Double(hd))]))
    }

    var drivesHeight: Bool {
        guard let t = success, !reduce else { return false }
        return t < 1090
    }

    /// 打开时登录页的第 i 个元素：延迟 250 + 40i 毫秒、0.56 秒里从下面 12 点浮起
    func openChild(_ i: Int) -> LoginChildFx {
        let p = prog(opened, 250 + 40 * Double(i), 560, .ios)
        return LoginChildFx(opacity: p, dy: 12 * (1 - p))
    }

    /// 成功时原来那一页逐条淡出：第 j 条延迟 18j 毫秒、0.22 秒里上移 8、模糊 6；主按钮（nil）留到 0.4 秒再原地淡出
    func exitChild(_ j: Int?) -> LoginChildFx {
        guard let t = success, !reduce else { return LoginChildFx() }
        if let j {
            let p = prog(t, 18 * Double(j), 220, .easeIn)
            return LoginChildFx(opacity: 1 - p, dy: -8 * p, blur: 6 * p)
        }
        let p = prog(t, 400, 280, .easeIn)
        return LoginChildFx(opacity: 1 - p, dy: 10 * p, scale: 1 - 0.06 * p)
    }

    /// 完成页：标题 1.28 秒、问候 1.37 秒、按钮 1.45 秒依次浮现
    func doneItem(_ k: Int) -> LoginChildFx {
        guard let t = success else { return LoginChildFx(opacity: 0) }
        if reduce { return LoginChildFx() }
        switch k {
        case 0:
            let p = prog(t, 1280, 560, .ios)
            return LoginChildFx(opacity: p, dy: 14 * (1 - p), blur: 10 * (1 - p))
        case 1:
            let p = prog(t, 1370, 560, .ios)
            return LoginChildFx(opacity: p, dy: 14 * (1 - p), blur: 10 * (1 - p))
        default:
            let p = prog(t, 1450, 620, .ios)
            return LoginChildFx(opacity: p, dy: 22 * (1 - p), scale: 0.985 + 0.015 * p)
        }
    }
}

private struct LoginChildMod: ViewModifier {
    let fx: LoginChildFx

    func body(content: Content) -> some View {
        content
            .blur(radius: fx.blur)
            .scaleEffect(fx.scale)
            .offset(y: fx.dy)
            .opacity(fx.opacity)
    }
}

/// 每一页的显隐（网页版 .cvl-pane / .is-on / .cvl-exiting）：
/// 进来 opacity 0.34 秒、位移 0.44 秒（iOS 曲线，晚 0.06 秒）；出去 opacity 0.24 秒（ease-in）、往下 8 点 0.3 秒（ease-out）；
/// 成功时原来那一页留在原地，交给逐条淡出
private struct LoginPaneShow: ViewModifier {
    enum Phase { case on, off, exiting }
    let phase: Phase

    func body(content: Content) -> some View {
        let on = phase != .off
        let still = phase == .exiting
        content
            .animation(still ? nil : (on ? CSSBezier.ios.animation(0.34).delay(0.06) : CSSBezier.easeIn.animation(0.24))) {
                $0.opacity(on ? 1 : 0)
            }
            .animation(still ? nil : (on ? CSSBezier.ios.animation(0.44).delay(0.06) : CSSBezier.easeOut.animation(0.3))) {
                $0.offset(y: on ? 0 : 8)
            }
            .allowsHitTesting(phase == .on)
            .accessibilityHidden(phase != .on)
    }
}

/// 密码框按需展开：先占好位置，下一帧再淡入、从上面 8 点落下（网页版 .cvl-reveal）
private struct LoginRevealIn: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .animation(CSSBezier.ios.animation(0.34).delay(0.06)) { $0.opacity(on ? 1 : 0) }
            .animation(CSSBezier.ios.animation(0.42).delay(0.06)) { $0.offset(y: on ? 0 : -8) }
            .task {
                try? await Task.sleep(for: .milliseconds(16))
                on = true
            }
    }
}

// MARK: - 部件

enum LoginInk {
    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: alpha)
    }

    static let ink = rgb(0x1d1d1f)
    static let ink2 = rgb(0x3a3a3c)
    static let ink3 = rgb(0x6e6e73)
    static let fill = rgb(0xececf0)
    static let line = rgb(0xe4e4e9)
    static let found = rgb(0x0066cc)
    static let good = rgb(0x248a3d)
    static let bad = rgb(0xd70015)
    static let ctaOff = rgb(0xd1d1d6)
    static let ctaDown = rgb(0x2c2c2e)
    static let eye = rgb(0x8e8e93)
    static let footHead = rgb(0x55575d)
    static let footText = rgb(0x6b6e75)
    /// 环境脉冲的品牌蓝 rgb(52, 116, 255)
    static let glow = rgb(0x3474ff)
    static let shade = rgb(0x0a090f)

    static func tone(_ t: LoginFlow.Tone) -> Color {
        switch t {
        case .plain: return ink3
        case .found: return found
        case .good: return good
        case .bad: return bad
        }
    }

    static func prompt(_ s: String) -> Text {
        Text(s).font(.system(size: 17, weight: .regular)).foregroundStyle(ink3)
    }

    // radial-gradient(circle at center, …)：半径是到角的距离（760 方块 → 537），圆本身只到 380（≈ 70.7%）
    static let glowStops: [Gradient.Stop] = [
        .init(color: glow.opacity(0.03), location: 0), .init(color: glow.opacity(0.08), location: 0.14),
        .init(color: glow.opacity(0.20), location: 0.32), .init(color: glow.opacity(0.13), location: 0.47),
        .init(color: glow.opacity(0.055), location: 0.62), .init(color: glow.opacity(0), location: 0.80)]
    static let ringStops: [Gradient.Stop] = [
        .init(color: glow.opacity(0), location: 0.46), .init(color: glow.opacity(0.04), location: 0.54),
        .init(color: glow.opacity(0.135), location: 0.62), .init(color: glow.opacity(0.05), location: 0.70),
        .init(color: glow.opacity(0), location: 0.80)]
}

/// 照 CSS 的 line-height 排字：每行的行框是 lineHeight，字落在行框正中
private enum CSSLineMetrics {
    nonisolated(unsafe) private static var cache: [String: CGFloat] = [:]

    /// 系统字（中文落到苹方）一行的自然高度
    static func natural(size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        let key = "\(size)-\(weight.rawValue)"
        if let v = cache[key] { return v }
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let text = NSAttributedString(string: "账户Ag", attributes: [.font: font])
        let h = text.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin], context: nil).height
        let v = max(font.lineHeight, h)
        cache[key] = v
        return v
    }
}

private extension View {
    func cssLineHeight(_ lineHeight: CGFloat, size: CGFloat, weight: UIFont.Weight) -> some View {
        let extra = lineHeight - CSSLineMetrics.natural(size: size, weight: weight)
        return self
            .lineSpacing(max(0, extra))
            .padding(.vertical, extra / 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 「Cuven max」字标：圆体，「Cuven」中等粗、「max」特粗而大，行高 1，投影 0 2 24 rgba(10,9,15,.34)
private struct LoginWordmark: View {
    let m: LoginMetrics

    var body: some View {
        let s1 = m.w1, s2 = m.w2
        let cuven = Text("Cuven").font(.system(size: s1, weight: .medium, design: .rounded)).tracking(-0.01 * s1)
        let big = Text("max").font(.system(size: s2, weight: .heavy, design: .rounded)).tracking(-0.045 * s2)
        Group {
            if m.short {
                // 矮横屏：排成一行，基线对齐，中间空 0.28em
                HStack(alignment: .firstTextBaseline, spacing: 0.28 * 16) {
                    cuven.frame(height: s1)
                    big.frame(height: s2)
                }
            } else {
                VStack(spacing: 0) {
                    cuven.frame(height: s1)
                    big.frame(height: s2).padding(.top, -0.03 * s2)
                }
            }
        }
        .foregroundStyle(.white)
        .fixedSize()
        .shadow(color: LoginInk.shade.opacity(0.34), radius: 12, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cuven max")
    }
}

/// 面板里的「Cuven 账户」小字标（圆体 27 号特粗 + 18 号「账户」，基线对齐，间距 5）
private struct LoginMark: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("Cuven")
                .font(.system(size: 27, weight: .heavy, design: .rounded))
                .tracking(-0.035 * 27)
                .frame(height: 27)
            Text("账户")
                .font(.system(size: 18, weight: .semibold))
                .tracking(0.04 * 18)
                .frame(height: 18)
        }
        .foregroundStyle(.black)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// 分割线之下的账户体系说明
private struct LoginFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(LoginInk.line)
                .frame(height: 1)
            Text("Cuven max 属于 Cuven 账户体系")
                .font(.system(size: 20, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(LoginInk.footHead)
                .cssLineHeight(28, size: 20, weight: .bold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 30)
            Text("一个 Cuven 账户即可登录 Cuven max、Cuven TV 以及 Cuven 的其他服务。观看进度、收藏与偏好随账户同步，换一台设备也能接着看。")
                .font(.system(size: 16))
                .foregroundStyle(LoginInk.footText)
                .cssLineHeight(26.4, size: 16, weight: .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
        }
    }
}

/// 输入框：高 60、圆角 12、浅灰填充；聚焦时白底 + 1.5 点深色描边 + 一圈 4 点的浅影（0.2 秒过渡）
private struct LoginInputBox<Field: View>: View {
    let focused: Bool
    @ViewBuilder var field: () -> Field
    var tap: () -> Void

    var body: some View {
        field()
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(LoginInk.ink)
            .tint(LoginInk.ink)
            .padding(.leading, 18)
            .padding(.trailing, 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 60)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .circular)
                        .fill(Color.black.opacity(focused ? 0.06 : 0))
                        .padding(-4)
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .fill(focused ? Color.white : LoginInk.fill)
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .strokeBorder(focused ? LoginInk.ink : Color.clear, lineWidth: 1.5)
                }
                .animation(.easeInOut(duration: 0.2), value: focused)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
    }
}

/// 验证码的一格：最宽 54、高 62、24 号字
private struct LoginCodeBox: View {
    let char: String
    let focused: Bool
    let error: Bool

    var body: some View {
        Text(char)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(LoginInk.ink)
            .frame(maxWidth: 54)
            .frame(height: 62)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .circular)
                        .fill(Color.black.opacity(focused ? 0.06 : 0))
                        .padding(-4)
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .fill(focused ? Color.white : LoginInk.fill)
                    RoundedRectangle(cornerRadius: 12, style: .circular)
                        .strokeBorder(error ? LoginInk.bad.opacity(0.7) : (focused ? LoginInk.ink : Color.clear), lineWidth: 1.5)
                }
                .animation(.easeInOut(duration: 0.2), value: focused)
                .animation(.easeInOut(duration: 0.2), value: error)
            }
    }
}

/// 主按钮：黑色胶囊、白字 17 号；不可点时浅灰底；按下缩到 0.98、底色 #2c2c2e；忙的时候字换成转子
private struct LoginCTA: View {
    let title: String
    let enabled: Bool
    let busy: Bool
    var dark = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .opacity(busy ? 0 : 1)
                if busy {
                    LoginSpinner()
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: busy)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Capsule())
        }
        .buttonStyle(LoginCTAStyle(enabled: enabled, dark: dark))
        .disabled(!enabled)
    }
}

private struct LoginCTAStyle: ButtonStyle {
    let enabled: Bool
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed && enabled
        configuration.label
            .background {
                Capsule()
                    .fill(enabled ? (down ? LoginInk.ctaDown : Color.black) : LoginInk.ctaOff)
                    .animation(.easeInOut(duration: 0.2), value: enabled)
                    .animation(.easeInOut(duration: 0.2), value: down)
            }
            .scaleEffect(down ? (dark ? 0.985 : 0.98) : 1)
            .animation(CSSBezier.easeOut.animation(0.3), value: down)
    }
}

/// 次级链接（忘记密码 / 改用密码 / 重新发送 / 暂不设定…）：高 44、15 号半粗、#3a3a3c；按下变黑、底上一层 5% 黑
private struct LoginAlt: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(LoginAltStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: enabled)
    }
}

private struct LoginAltStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.black : LoginInk.ink2)
            .background(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.05 : 0)))
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// 12 根辐条的转子（网页版 .cvl-spinner：2 × 5.5、每根晚 1/12 秒，1 秒一圈地从实到淡）
private struct LoginSpinner: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<12, id: \.self) { i in
                    let phase = (t + Double(11 - i) / 12).truncatingRemainder(dividingBy: 1)
                    RoundedRectangle(cornerRadius: 1, style: .circular)
                        .frame(width: 2, height: 5.5)
                        .opacity(1 - 0.88 * phase)
                        .offset(y: -7.25)
                        .rotationEffect(.degrees(Double(i) * 30))
                }
            }
            .frame(width: 20, height: 20)
        }
        .accessibilityLabel("正在处理")
    }
}

/// 网页版的几枚 SVG（viewBox 24）：绿勾、眼睛、返回
private struct LoginGlyph: Shape {
    enum Kind { case check, eye, back }
    let kind: Kind

    func path(in r: CGRect) -> Path {
        let s = r.width / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var p = Path()
        switch kind {
        case .check:
            p.move(to: pt(20, 6)); p.addLine(to: pt(9, 17)); p.addLine(to: pt(4, 12))
        case .back:
            p.move(to: pt(15, 5)); p.addLine(to: pt(8, 12)); p.addLine(to: pt(15, 19))
        case .eye:
            // M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z + 圆心 (12, 12) 半径 3
            p.move(to: pt(1, 12))
            p.addCurve(to: pt(12, 4), control1: pt(1, 12), control2: pt(5, 4))
            p.addCurve(to: pt(23, 12), control1: pt(19, 4), control2: pt(23, 12))
            p.addCurve(to: pt(12, 20), control1: pt(23, 12), control2: pt(19, 20))
            p.addCurve(to: pt(1, 12), control1: pt(5, 20), control2: pt(1, 12))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: r.minX + 9 * s, y: r.minY + 9 * s, width: 6 * s, height: 6 * s))
        }
        return p
    }
}

/// 密码框右边的「显示密码」：40 点圆钮、20 点的眼睛、#8e8e93；按下变深、底上一层 6% 黑
private struct LoginEyeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LoginGlyph(kind: .eye)
                .stroke(style: StrokeStyle(lineWidth: 2 * 20 / 24, lineCap: .round, lineJoin: .round))
                .frame(width: 20, height: 20)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(LoginEyeStyle())
        .accessibilityLabel("显示密码")
    }
}

private struct LoginEyeStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? LoginInk.ink : LoginInk.eye)
            .background(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.06 : 0)))
    }
}

/// 左上角的返回：40 点圆、16% 白 + 模糊底、18 点的「‹」（线宽 2.2 / 24）；按下缩到 0.92、底色 26%
private struct LoginNavGlyph: View {
    var body: some View {
        LoginGlyph(kind: .back)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2 * 18 / 24, lineCap: .round, lineJoin: .round))
            .frame(width: 18, height: 18)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
    }
}

private struct LoginNavStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.26 : 0.16)))
            .background(.ultraThinMaterial, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(CSSBezier.easeOut.animation(0.18), value: configuration.isPressed)
    }
}

/// 蓝色脉冲的一片：760 的圆、径向渐变（到角为 100%）、模糊、滤色叠在流体上
private struct PulseDisc: View {
    let stops: [Gradient.Stop]
    let blur: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(stops: stops, center: .center, startRadius: 0, endRadius: 380 * 1.41421356))
            .frame(width: 760, height: 760)
            .blur(radius: blur)
            .blendMode(.screen)
    }
}

/// 面容 ID 那一页：字标外一圈呼吸的扫描环（170 × 118、圆角 40；1.5 点蓝边 + 28 点的外发光；2.1 秒一呼一吸）
private struct LoginScanRing: View {
    let reduce: Bool
    @State private var breathe = false

    var body: some View {
        ZStack {
            // 外发光：只在框外（CSS 的外阴影不画进框里）
            RoundedRectangle(cornerRadius: 40, style: .circular)
                .fill(LoginInk.glow.opacity(0.35))
                .frame(width: 170, height: 118)
                .blur(radius: 14)
                .mask {
                    LoginOutside(cornerRadius: 40, inset: 60)
                        .fill(style: FillStyle(eoFill: true))
                        .frame(width: 290, height: 238)
                }
            RoundedRectangle(cornerRadius: 41.5, style: .circular)
                .strokeBorder(LoginInk.glow.opacity(0.6), lineWidth: 1.5)
                .frame(width: 173, height: 121)
        }
        .frame(width: 290, height: 238)
        .scaleEffect(reduce ? 1 : (breathe ? 1.16 : 1))
        .opacity(reduce ? 0.8 : (breathe ? 0.12 : 0.85))
        .onAppear {
            guard !reduce else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) { breathe = true }
        }
        .accessibilityHidden(true)
    }
}

/// 一个大矩形挖掉中间的圆角矩形（奇偶填充）：外发光的遮罩
private struct LoginOutside: Shape {
    let cornerRadius: CGFloat
    let inset: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path(r)
        p.addRoundedRect(in: r.insetBy(dx: inset, dy: inset), cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        return p
    }
}

// MARK: - 流体底图

/// 网页版 Sky Pro 流体（SkyFluid.metal）：每帧 time += dt × 0.275（dt 最多 0.05 秒），60 帧；「减弱动态效果」时停在第一帧
struct SkyFluidView: View {
    /// 整屏大小：着色器按它算坐标
    let size: CGSize
    /// 实际画多高（从顶上算）
    let drawHeight: CGFloat
    var still = false
    @State private var clock = SkyFluidClock()

    var body: some View {
        let h = max(1, min(size.height, drawHeight))
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: still)) { tl in
            Rectangle()
                .frame(width: size.width, height: h)
                .colorEffect(ShaderLibrary.cuvenSkyFluid(.float2(Float(size.width), Float(size.height)),
                                                         .float(clock.step(tl.date, still: still))))
        }
        .frame(width: size.width, height: h, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

final class SkyFluidClock {
    private var elapsed: Double = 0
    private var last: Date?

    func step(_ now: Date, still: Bool) -> Float {
        if still { return 0 }
        let dt = last.map { min(0.05, max(0, now.timeIntervalSince($0))) } ?? 0
        last = now
        elapsed += dt * 0.275
        return Float(elapsed)
    }
}
