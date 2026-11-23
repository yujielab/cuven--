import SwiftUI
import AVFoundation

// MARK: - 光学配对的界面
//
// · PairShowView（登录页一出来先显示它，也可以点「用 iPhone 扫描登录」）：这台设备要登录 —— 显示粒子云，等另一台已登录的 iPhone 扫；
//   下面「使用账户密码登录」回到登录页
// · PairScanSheet（账户页「扫描登录其他设备」）：照 Apple 配对的样子 ——「将图案放在圆圈中」、圆形取景框、蓝圈；
//   扫到 → 确认卡（哪台设备、在哪儿、几点、离你多远）→ 面容 ID → 批准。误读（后端说没认清）不报错，相机开着接着扫
// · PairLabView（启动参数 -pairLab，自检）：编码对照、离屏画一团云再解出来

private let pairBlue = Color(red: 0.36, green: 0.62, blue: 0.95)
private let pairGreen = Color(red: 0.13, green: 0.6, blue: 0.3)
private let pairRed = Color(red: 0.86, green: 0.18, blue: 0.16)

// MARK: 显示的那一边

struct PairShowView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    /// 屏幕上画的这一团（nil = 不画：过期 / 作废以后马上清掉，不让一团用不了的码挂在屏幕上）
    @State private var shown: PairCloudCode?
    /// 现在这一团的配对（离开 / 关掉时取消它）
    @State private var opened: PairService.Opened?
    /// 只在准备中、出错时有字；云出来以后空着
    @State private var status = "正在准备…"
    @State private var task: Task<Void, Never>?
    /// 第几轮配对：只有最新的那一轮能登录（离开、关掉以后，旧的那一轮就算等回来「已批准」也不算）
    @State private var gen = 0

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 0) {
                Text("用 iPhone 扫描登录")
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(.black)
                    .padding(.top, 52)
                Text("Cuven 光学安全保护措施是迄今为止最安全的加密保护措施，Cuven 的安全团队日夜保护您的账户。")
                    .font(.system(size: 16)).foregroundStyle(.black.opacity(0.6))
                    .multilineTextAlignment(.center).padding(.horizontal, 36).padding(.top, 10)
                PairCloudView(code: shown)
                    .frame(width: 330, height: 330)
                    .padding(.top, 18)
                    .accessibilityIdentifier("pair-cloud")
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 15)).foregroundStyle(.black.opacity(0.55))
                        .multilineTextAlignment(.center).padding(.horizontal, 36)
                        .padding(.top, 6)
                }
                Spacer()
                Button { close() } label: {
                    Text("使用账户密码登录")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 54)
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
                .accessibilityIdentifier("pair-show-password")
            }
        }
        .onAppear {
            guard task == nil else { return }
            gen += 1
            let g = gen
            task = Task { await run(g) }
        }
        .onDisappear { stopPairing() }
    }

    /// 一团云：配对、算好的纹理、到期时间（后端的时钟，换算到本机）、上一次 wait 时有没有人扫过
    private struct Live {
        var opened: PairService.Opened
        var code: PairCloudCode
        /// 后端时钟 − 本机时钟（毫秒，open 回来时估的）
        var skew: Double
        var exp: Double
        var peeked = false
        /// 提前换一团没开出来：守着这一团等后端说过期
        var noRotate = false
        /// 离到期还有几秒（本机时钟）
        var left: Double { (exp - skew) / 1000 - Date().timeIntervalSince1970 }
    }

    private func run(_ g: Int) async {
        let label = UIDevice.current.userInterfaceIdiom == .pad ? "iPad · Cuven" : "iPhone · Cuven"
        PairCodec.prewarm()                                     // 稀疏基底和 /pair/open 同时在后台建
        func current() -> Bool { !Task.isCancelled && g == gen }
        var cur: Live?
        var note: String?                                       // 新的一团出来以后显示的话
        while current() {
            guard var c = cur else {
                guard let n = await openLive(label) else {
                    guard current() else { return }
                    status = "暂时连不上，稍后再试"
                    try? await Task.sleep(for: .seconds(5)); continue
                }
                guard current() else { PairService.cancel(n.opened); return }
                cur = n; opened = n.opened; shown = n.code
                status = note ?? ""; note = nil
                continue
            }
            let ms: Int
            switch PairService.displayStep(left: c.left, peeked: c.peeked, noRotate: c.noRotate) {
            case .drop:
                // 本机时钟都过了到期时间还没等到后端回话（断网）：先不画了
                shown = nil; opened = nil; cur = nil
                continue
            case .rotate:
                // 快到期、还没人扫过：先开下一团、换上去，再取消这一团
                if let n = await openLive(label) {
                    guard current() else { PairService.cancel(n.opened); return }
                    PairService.cancel(c.opened)
                    cur = n; opened = n.opened; shown = n.code; status = ""
                } else {
                    guard current() else { return }
                    c.noRotate = true; cur = c                  // 开不出新的：守着这一团等后端说过期
                }
                continue
            case .wait(let w):
                ms = w
            }
            guard let r = await PairService.wait(c.opened, ms: ms) else {
                guard current() else { return }
                try? await Task.sleep(for: .seconds(2)); continue
            }
            guard current() else { return }
            if r.status == "approved", let u = r.username, !u.isEmpty {
                signIn(u, r)
                return
            }
            if r.status == "open" {
                if let e = r.exp, e.isFinite { c.exp = e }
                c.peeked = r.peeked == true
                cur = c
                continue
            }
            // 过期 / 作废 / 取消 / 已经用过（done）、或者后端不认这一团了：马上不画它，再开一团
            shown = nil; opened = nil; cur = nil
            if r.status == "done" { note = "那边已经批准了，但这台设备没收到结果：请再扫一次" }
        }
    }

    /// 开一团：/pair/open → 纹理在后台线程上算（稀疏基底，几毫秒）
    private func openLive(_ label: String) async -> Live? {
        guard let spec = PairSpec.shared, let o = try? await PairService.open(device: label) else { return nil }
        let skew = o.ttl.map { o.exp - Double($0) * 1000 - Date().timeIntervalSince1970 * 1000 } ?? 0
        let id = o.id, secret = o.secret
        let bytes = await Task.detached(priority: .userInitiated) { PairCodec.codeTexture(id: id, secret: secret, spec: spec) }.value
        return Live(opened: o, code: PairCloudCode(id: id, secret: secret, size: spec.codeGrid, bytes: bytes), skew: skew, exp: o.exp)
    }

    private func signIn(_ u: String, _ r: PairService.Waited) {
        // 和密码登录一样记下这次的识别代码（5 分钟）：登录后写账户档、邮箱映射都要带上（账号中心开了 STRICT_AUTH 时）
        AccountAPI.remember(code: r.code)
        PairService.keepDevice(onlyFor: u)
        if let d = r.device, PairService.tokenUser(d) == u { PairService.saveDevice(d) }
        opened = nil                                            // 用过了，不用再取消
        Haptics.success()
        account.signIn(username: u, email: r.email ?? "", method: "pair", alert: false)
        dismiss()
    }

    private func stopPairing() {
        gen += 1
        task?.cancel(); task = nil
        if let o = opened { PairService.cancel(o) }
        opened = nil
    }

    private func close() {
        stopPairing()
        dismiss()
    }
}

// MARK: 扫描的那一边

struct PairScanSheet: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    enum Stage: Equatable { case verify, scanning, confirm, working, done, failed(String) }
    @State private var stage: Stage = .scanning
    @State private var target: PairService.Target?
    @State private var peeked: PairService.Peeked?
    @State private var password = ""
    @State private var otpHint: String?
    @State private var otpCode = ""
    @State private var verifyError: String?
    @State private var busy = false
    /// 解码器在后台建（第一次约 0.1–0.2 秒，之后整个 App 共用一个）；以前每次初始化这个视图都在主线程上建一遍
    @State private var scanner: PairScanner?
    @State private var scannerFailed = false
    @State private var camDenied = false
    @State private var camState: PairScanner.CamState = .starting
    @State private var active = false
    /// 正在问后端扫到的是哪台设备（相机开着，只是先不处理画面）
    @State private var peeking = false
    /// 连着几次后端说「没认清」（CRC-8 挡不住所有误读，约 1/256 的乱码能过）。不报错、接着扫；6 次以后圆圈下面提示一句
    @State private var misreads = 0
    @State private var hint: String?
    /// 后端说过期了的码（真有这一团，只是不能用了）→ 那句话。显示端会换一团；这一团一直还在画面里才说
    @State private var expiredKeys: [UInt64: String] = [:]
    @State private var confirmError: String?
    /// 后端回了 409 far（不在同一个国家或地区，这边没看到 near）：也要两下确认
    @State private var farRequired = false
    /// 不在同一个国家或地区：点了第一下的时间。第二下才批准
    @State private var farArmedAt: Date?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.black.opacity(0.8))
                        .frame(width: 44, height: 44).background(Circle().fill(Color.black.opacity(0.06)))
                }
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 18).padding(.top, 16)
            content
            Spacer(minLength: 0)
        }
        .background(Color(white: 0.89).ignoresSafeArea())
        .presentationDetents([.large])
        .presentationCornerRadius(44)
        .onAppear { begin() }
        .onDisappear { active = false; scanner?.stop() }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .verify: verifyView
        case .scanning: scanView
        case .confirm: confirmView
        case .working: VStack(spacing: 16) { ProgressView().controlSize(.large); Text("正在登录…").foregroundStyle(.black.opacity(0.6)) }.padding(.top, 120)
        case .done: doneView
        case .failed(let m): failedView(m)
        }
    }

    private func titleBlock(_ t: String, _ s: String) -> some View {
        VStack(spacing: 10) {
            Text(t).font(.system(size: 32, weight: .bold)).foregroundStyle(.black).multilineTextAlignment(.center)
            Text(s).font(.system(size: 17)).foregroundStyle(.black.opacity(0.75)).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    private var scanView: some View {
        VStack(spacing: 0) {
            titleBlock("将图案放在圆圈中", "将设备靠近相机。")
            ZStack {
                if camDenied {
                    Circle().fill(Color.black.opacity(0.85))
                    Text("Cuven 没有相机权限。\n到「设置」里打开。").font(.system(size: 15)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(30)
                } else if let s = scanner {
                    Circle().fill(Color.black.opacity(0.85))
                    PairCameraPreview(scanner: s, state: camState).clipShape(Circle())
                } else if scannerFailed {
                    Circle().fill(Color.black.opacity(0.85))
                    Text("这台设备上扫描用不了（解码器没加载起来）。").font(.system(size: 15)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(30)
                } else {
                    Circle().fill(Color.black.opacity(0.85))             // 解码器还在后台建
                }
                Circle().stroke(pairBlue, lineWidth: 10)
            }
            .frame(width: 300, height: 300)
            .padding(.top, 40)
            .accessibilityIdentifier("pair-scan-viewfinder")
            if let note = scanNote {
                Text(note).font(.system(size: 15)).foregroundStyle(.black.opacity(0.6)).multilineTextAlignment(.center)
                    .padding(.horizontal, 36).padding(.top, 16)
                    .accessibilityIdentifier("pair-scan-status")
            }
            Spacer(minLength: 40)
        }
        .padding(.top, 4)
    }

    /// 圆圈下面那一句：相机不在正常取景时说为什么；正常取景时是「正在确认」或者没认清的提示
    private var scanNote: String? {
        guard !camDenied, !scannerFailed else { return nil }
        guard scanner != nil else { return "正在打开相机…" }
        switch camState {
        case .starting: return "正在打开相机…"
        case .running: return peeking ? "正在确认是哪台设备…" : hint
        case .noCamera: return "找不到后置相机"
        case .paused(let m), .failed(let m): return m
        }
    }

    private var confirmView: some View {
        let w = peeked?.who
        let near = peeked?.near
        let far = near?.level == "foreign" || farRequired
        let armed = far && farArmedAt != nil
        return VStack(spacing: 0) {
            titleBlock("让那台设备登录？", "它会登录你的账户「\(account.displayName)」：")
            VStack(alignment: .leading, spacing: 14) {
                row("desktopcomputer", (w?.device).flatMap { $0.isEmpty ? nil : $0 } ?? "未知设备")
                row("mappin.and.ellipse", place(w))
                row("clock", when(w))
                if near?.level == "same_network" {
                    HStack(spacing: 12) {
                        Image(systemName: "wifi").font(.system(size: 17, weight: .semibold)).foregroundStyle(pairGreen).frame(width: 24)
                        Text("和你在同一个网络").font(.system(size: 17, weight: .semibold)).foregroundStyle(pairGreen)
                    }
                    .accessibilityIdentifier("pair-near")
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 24).fill(.white))
            .padding(.horizontal, 28).padding(.top, 30)
            if far {
                farBanner(near)
            } else {
                Text("只批准你自己面前的设备。别人发来的粒子云、截图，不要扫。")
                    .font(.system(size: 14)).foregroundStyle(.black.opacity(0.55)).multilineTextAlignment(.center)
                    .padding(.horizontal, 36).padding(.top, 16)
            }
            if let e = confirmError {
                Text(e).font(.system(size: 15, weight: .medium)).foregroundStyle(pairRed).multilineTextAlignment(.center)
                    .padding(.horizontal, 36).padding(.top, 12)
                    .accessibilityIdentifier("pair-confirm-error")
            }
            Spacer(minLength: 30)
            Button { Task { await approve() } } label: {
                Text(armed ? "它就在我面前，仍然登录" : "登录").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 58).background(Capsule().fill(armed ? pairRed : Color.black))
            }
            .disabled(busy)
            .padding(.horizontal, 32)
            .accessibilityIdentifier("pair-confirm")
            Button("取消") { dismiss() }.font(.system(size: 17)).foregroundStyle(.black.opacity(0.7)).padding(.vertical, 16)
        }
    }

    /// 不在同一个国家或地区：红色提示（哪个国家或地区、网络是谁的），要点第二下才批准
    private func farBanner(_ near: PairService.Near?) -> some View {
        var facts: [String] = []
        if let cc = near?.country, !cc.isEmpty { facts.append("它在\(Self.regionName(cc))") }
        if let org = near?.org, !org.isEmpty { facts.append("网络属于 \(org)") }
        let detail = (facts.isEmpty ? "" : facts.joined(separator: "，") + "。\n") + "确认它就在你面前再批准；别人发来的图案、截图、视频，点「取消」。"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16, weight: .semibold))
                Text("这台设备和你不在同一个国家或地区").font(.system(size: 16, weight: .semibold))
            }
            Text(detail).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(pairRed)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(pairRed.opacity(0.1)))
        .padding(.horizontal, 28).padding(.top, 14)
        .accessibilityIdentifier("pair-far")
    }

    /// 两位的国家或地区代码 → 中文名（认不出就原样）
    private static func regionName(_ cc: String) -> String {
        Locale(identifier: "zh_Hans").localizedString(forRegionCode: cc.uppercased()) ?? cc
    }

    private func place(_ w: PairService.Who?) -> String {
        guard let w else { return "" }
        return [w.geo, w.ip].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func when(_ w: PairService.Who?) -> String {
        var parts: [String] = []
        if let t = w?.time, !t.isEmpty { parts.append(t) }
        if let a = peeked?.age, a.isFinite, a >= 0 { parts.append(a < 90 ? "\(Int(a)) 秒前打开" : "\(Int(a / 60)) 分钟前打开") }
        return parts.joined(separator: " · ")
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.black.opacity(0.55)).frame(width: 24)
            Text(text).font(.system(size: 17)).foregroundStyle(.black).lineLimit(2)
        }
    }

    private var doneView: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 76)).foregroundStyle(pairBlue)
            Text("已登录").font(.system(size: 30, weight: .bold)).foregroundStyle(.black)
            Text("那台设备已经登录了你的 Cuven 账户。").font(.system(size: 16)).foregroundStyle(.black.opacity(0.6))
        }
        .padding(.top, 120)
        .task { try? await Task.sleep(for: .seconds(1.6)); dismiss() }
    }

    private func failedView(_ m: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 64)).foregroundStyle(.black.opacity(0.5))
            Text(m).font(.system(size: 17)).foregroundStyle(.black.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal, 36)
            Button("重新扫描") { rescan() }
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(pairBlue)
        }
        .padding(.top, 110)
    }

    // 第一次扫描：先验证一次身份（领设备令牌）
    private var verifyView: some View {
        VStack(spacing: 0) {
            titleBlock("先验证一下身份", "第一次用这台 iPhone 批准别的设备登录，需要确认是你本人。")
            Text("账户：\(account.displayName)")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(.black.opacity(0.55)).padding(.top, 18)
                .accessibilityIdentifier("pair-verify-account")
            SecureField("", text: $password, prompt: Text("这个账号的密码").foregroundStyle(.black.opacity(0.35)))
                .textContentType(.password)
                .font(.system(size: 18)).foregroundStyle(.black)
                .padding(16).background(RoundedRectangle(cornerRadius: 14).fill(.white))
                .padding(.horizontal, 32).padding(.top, 14)
                .accessibilityIdentifier("pair-verify-password")
            if let hint = otpHint {
                TextField("", text: $otpCode, prompt: Text("邮箱验证码（发到 \(hint)）").foregroundStyle(.black.opacity(0.35)))
                    .keyboardType(.numberPad).font(.system(size: 18)).foregroundStyle(.black)
                    .padding(16).background(RoundedRectangle(cornerRadius: 14).fill(.white))
                    .padding(.horizontal, 32).padding(.top, 12)
            }
            if let e = verifyError { Text(e).font(.system(size: 14)).foregroundStyle(.red).padding(.top, 10) }
            Button { Task { await verify() } } label: {
                HStack { if busy { ProgressView().tint(.white) }; Text("验证").font(.system(size: 18, weight: .semibold)) }
                    .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 56).background(Capsule().fill(Color.black))
            }
            .disabled(busy || (password.isEmpty && otpCode.count < 6))
            .padding(.horizontal, 32).padding(.top, 24)
            Button(otpHint == nil ? "没有密码？用邮箱验证码" : "重新发送验证码") { Task { await sendOtp() } }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(pairBlue).padding(.top, 16)
        }
    }

    // MARK: 流程

    private func begin() {
        guard !active else { return }
        active = true
        guard PairService.accountDevice(account.displayName) != nil else {
            stage = .verify
            Task { _ = await loadScanner() }                         // 验证身份的时候解码器在后台建好
            return
        }
        stage = .scanning
        startCamera()
    }

    private func loadScanner() async -> PairScanner? {
        if let s = scanner { return s }
        let s = await PairScanner.shared()
        scanner = s
        scannerFailed = s == nil
        return s
    }

    private func startCamera() {
        Task {
            if !PairScanner.authorized, !(await PairScanner.requestAccess()) { camDenied = true; return }
            guard let s = await loadScanner(), active, stage == .scanning else { return }
            s.onResult = { id, secret in found(PairService.Target(id: id, secret: secret)) }
            s.onRejectedAgain = { id, secret in seenAgain(id, secret) }
            s.onState = { camState = $0 }
            s.start()
        }
    }

    /// 出错以后「重新扫描」：从头开始（窗口、被拒过的码都清掉）
    private func rescan() {
        target = nil; peeked = nil
        misreads = 0; hint = nil; expiredKeys = [:]
        stage = .scanning
        startCamera()
    }

    private func found(_ t: PairService.Target) {
        guard active, stage == .scanning, !peeking else { return }
        // 后端从不发编号 0（全零码字：画面整体偏暗时最容易「解」出来）
        guard t.id != 0 else { scanner?.resume(skipping: t.id, secret: t.secret); return }
        peek(t)
    }

    /// 问后端扫到的是哪台设备。相机一直开着（扫描器只是停了处理）：是误读就接着扫，不用重开相机、不清窗口
    private func peek(_ t: PairService.Target) {
        peeking = true
        Task {
            let r = await PairService.peek(t, as: account.displayName)
            peeking = false
            guard active, stage == .scanning else { return }
            switch r {
            case .success(let p):
                Haptics.light()
                scanner?.stop()
                misreads = 0; hint = nil
                target = t; peeked = p
                confirmError = nil; farRequired = false; farArmedAt = nil
                stage = .confirm
            case .failure(.server("bad_device", _)):
                scanner?.stop()
                target = t; stage = .verify
            case .failure(.server("not_found", _)), .failure(.server("wrong", _)):
                // 没认清（编号不存在 / 密钥不对）：多半是误读。不报错、不关相机，跳过这个码接着扫
                misread(t)
            case .failure(.server("expired", let m)):
                // 真有这一团，但过期 / 取消 / 用过了：显示端会换一团，接着扫；这一团一直还在画面里才提示
                expiredKeys[t.key] = m
                misread(t)
            case .failure(.server(_, let m)):
                scanner?.stop(); stage = .failed(m)
            case .failure(.network):
                scanner?.stop(); stage = .failed("连不上账号中心，稍后再试")
            }
        }
    }

    private func misread(_ t: PairService.Target) {
        misreads += 1
        if misreads >= 6 { hint = "没认清，靠近一点、拿稳再试" }
        scanner?.resume(skipping: t.id, secret: t.secret)
    }

    /// 被拒过的码一直还在画面里（扫描器跳过它好一阵了）：说一句为什么扫不出来
    private func seenAgain(_ id: UInt32, _ secret: UInt32) {
        guard active, stage == .scanning else { return }
        hint = expiredKeys[PairCodec.key(id: id, secret: secret)] ?? "这团粒子云认不出来，让那台设备换一团"
    }

    private func approve() async {
        guard let t = target, stage == .confirm, !busy else { return }
        let far = peeked?.near?.level == "foreign" || farRequired
        if far {
            // 不在同一个国家或地区：第一下只是亮出确认，第二下（隔一会儿，防连点）才批准
            guard let at = farArmedAt else { farArmedAt = Date(); Haptics.light(); return }
            guard Date().timeIntervalSince(at) > 0.6 else { return }
        }
        confirmError = nil
        busy = true
        let check = await PairService.confirmOwner()
        busy = false
        switch check {
        case .ok: break
        case .cancelled: return
        case .refused(let m): confirmError = m; return
        }
        guard active, stage == .confirm else { return }
        stage = .working
        switch await PairService.approve(t, as: account.displayName, ackFar: far) {
        case .success: Haptics.success(); stage = .done
        case .failure(.server("bad_device", _)): stage = .verify
        case .failure(.server("far", _)):
            // 后端比出来不在同一个国家或地区（peek 时没看出来）：亮出红色提示，再点两下
            farRequired = true; farArmedAt = nil; stage = .confirm
        case .failure(.server(_, let m)): stage = .failed(m)
        case .failure(.network): stage = .failed("连不上账号中心，稍后再试")
        }
    }

    private func verify() async {
        busy = true; verifyError = nil
        defer { busy = false }
        let name = account.displayName
        let err = otpCode.count == 6 ? await PairService.verifyOtp(username: name, code: otpCode) : await PairService.verifyPassword(username: name, password: password)
        if let err { verifyError = err; return }
        password = ""; otpCode = ""
        stage = .scanning
        startCamera()
        if let t = target { peek(t) }                               // 扫到过（令牌作废才来验证的）：直接接着问
    }

    private func sendOtp() async {
        let r = await PairService.sendOtp(username: account.displayName)
        if let e = r.error { verifyError = e } else { otpHint = r.hint; verifyError = nil }
    }
}

/// 相机取景（铺满、裁成圆形）
struct PairCameraPreview: UIViewRepresentable {
    let scanner: PairScanner
    var state: PairScanner.CamState = .starting

    final class V: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        weak var scanner: PairScanner?
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var watch: NSKeyValueObservation?

        /// 预览转到和屏幕一致的方向（Duo 内屏横着拿、iPad 横屏时不然是歪的）；相机输入接上以后才建得了
        func syncRotation() {
            guard rotation == nil, let cam = scanner?.camera else { return }
            let rc = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: preview)
            rotation = rc
            watch = rc.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] rc, _ in
                let a = rc.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async {
                    guard let c = self?.preview.connection, c.isVideoRotationAngleSupported(a) else { return }
                    c.videoRotationAngle = a
                }
            }
        }
        override func layoutSubviews() { super.layoutSubviews(); syncRotation() }
    }

    func makeUIView(context: Context) -> V {
        let v = V()
        v.backgroundColor = .black
        v.scanner = scanner
        v.preview.session = scanner.session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: V, context: Context) {
        if state == .running { v.syncRotation() }
    }
}

// MARK: 自检（启动参数 -CuvenPairLab YES）

enum PairLab {
    static func presentIfRequested() {
        guard UserDefaults.standard.bool(forKey: "CuvenPairLab") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let top = UIApplication.topViewController() else { return }
            let vc = UIHostingController(rootView: PairLabView())
            vc.modalPresentationStyle = .fullScreen
            top.present(vc, animated: false)
        }
    }
}

struct PairLabView: View {
    @State private var lines: [String] = []
    @State private var verdict = "运行中…"
    @State private var cloud: UIImage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("光学配对自检").font(.title.bold())
                Text(verdict).font(.headline).accessibilityIdentifier("pair-lab-result")
                ForEach(lines, id: \.self) { Text($0).font(.system(.footnote, design: .monospaced)) }
                if let cloud {
                    Image(uiImage: cloud).resizable().interpolation(.none).frame(width: 300, height: 300)
                        .accessibilityIdentifier("pair-lab-cloud")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.white.ignoresSafeArea())
        .foregroundStyle(.black)
        .task { await run() }
    }

    private func log(_ s: String) { lines.append(s) }

    private func run() async {
        guard let spec = PairSpec.shared else { verdict = "失败：缺 cpc1-spec.json"; return }
        var ok = true
        // 1) 编码 / 场：和 Python 规范的对照用例
        if let u = Bundle.main.url(forResource: "cpc1-vectors", withExtension: "json"), let d = try? Data(contentsOf: u),
           let vecs = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            var worst = 0.0, signsOK = true
            for v in vecs {
                let id = UInt32(v["id"] as! Int), sec = UInt32(v["secret"] as! Int)
                let b = PairCodec.cellSigns(id: id, secret: sec, spec: spec)
                if b.map({ Int($0) }) != (v["signs"] as! [Int]) { signsOK = false }
                let pts = v["pts"] as! [[Double]], Ds = v["D"] as! [Double], ms = v["m"] as! [Double]
                for (i, p) in pts.enumerated() {
                    let f = PairCodec.field(b, p[0], p[1], spec: spec)
                    let m = PairCodec.modulation(f.D, f.E, spec: spec)
                    worst = max(worst, abs(f.D - Ds[i]), abs(m - ms[i]))
                }
            }
            log("编码对照：正负\(signsOK ? "一致" : "不一致")，场最大误差 \(String(format: "%.1e", worst))")
            ok = ok && signsOK && worst < 1e-3
        } else { log("缺 cpc1-vectors.json"); ok = false }
        // 1b) 调制网格的快算法（稀疏基底，显示端用的）和逐点算的 8 位纹理一样（四舍五入卡在边上的点最多差 1）
        do {
            let tb = Date()
            _ = PairCodec.basis(spec: spec, size: spec.codeGrid)
            let buildMs = Int(Date().timeIntervalSince(tb) * 1000)
            let samples: [(UInt32, UInt32)] = [(0x5A3C1F, 0xC0FFEE42), (0x000001, 0x00000000), (0xFFFFFF, 0xFFFFFFFF)]
            var maxd = 0, nd = 0
            for (cid, csec) in samples {
                let dense = PairCodec.textureBytes(PairCodec.modulationGrid(PairCodec.cellSigns(id: cid, secret: csec, spec: spec), size: spec.codeGrid, spec: spec), spec: spec)
                let fast = PairCodec.codeTexture(id: cid, secret: csec, spec: spec)
                if dense.count != fast.count { maxd = 255; continue }
                for k in 0..<dense.count {
                    let dd = abs(Int(dense[k]) - Int(fast[k]))
                    maxd = max(maxd, dd); if dd > 0 { nd += 1 }
                }
            }
            log("调制网格快算法：最大差 \(maxd)，不同 \(nd) 个点（建基底 \(buildMs) ms）")
            ok = ok && maxd <= 1 && nd < 20
        }
        // 2) Viterbi：加噪声也解得回
        let pb = PairCodec.payloadBits(id: 0xABCDEF, secret: 0x12345678)
        let coded = PairCodec.convEncode(pb, spec: spec)
        var g = SystemRandomNumberGenerator()
        let soft = coded.map { Float($0 == 1 ? 1 : -1) + Float.random(in: -0.9...0.9, using: &g) }
        let back = PairCodec.parse(PairCodec.viterbi(soft, spec: spec))
        log("Viterbi：\(back.map { String(format: "%06X / %08X", $0.id, $0.secret) } ?? "解不出")")
        ok = ok && back?.id == 0xABCDEF && back?.secret == 0x12345678
        // 3) 离屏画一团云（连着 40 帧，每帧 1/30 秒）→ 当成相机画面 → 解码（最近 16 帧平均 + GPU 网络）
        guard let net = PairNet(), let dec = PairDecoder(spec: spec, net: net), let r = PairCloudRenderer() else {
            verdict = "失败：Metal / 网络权重不可用"; return
        }
        log("网络：\(net.usesGPU ? "Metal GPU" : "CPU")，\(net.layers.count) 层")
        let id: UInt32 = 0x5A3C1F, secret: UInt32 = 0xC0FFEE42
        r.setCode(id: id, secret: secret, spec: spec)
        let side = 600, cam = spec.decode.cam
        var hit: (UInt32, UInt32)?
        let t0 = Date()
        for k in 0..<40 {
            guard let px = r.renderOffscreen(side: side, time: 2 + Double(k) / 30, codeTime: Double(k) / 30) else { break }
            if k == 0 { cloud = Self.image(px, side: side) }
            // 白底上的预乘颜色 → 和相机看到的一样：蓝色程度 = B − R（透明底按白底合成：c + (1 − a)·白）
            // 缩小时按块平均（和扫描时 GPU 上的 pair_ink 一样），不是隔点取：粒子是一个个小点，隔点取会很花
            var ink = [Float](repeating: 0, count: cam * cam)
            let scale = Float(side) / Float(cam), k = max(1, Int(scale))
            for y in 0..<cam {
                for x in 0..<cam {
                    let x0 = Int(Float(x) * scale), y0 = Int(Float(y) * scale)
                    var acc: Float = 0, n: Float = 0
                    for yy in y0..<min(side, y0 + k) {
                        for xx in x0..<min(side, x0 + k) {
                            let o = (yy * side + xx) * 4
                            let a = Float(px[o + 3]) / 255
                            let bch = Float(px[o]) / 255 + (1 - a), rch = Float(px[o + 2]) / 255 + (1 - a)
                            acc += max(bch - rch, 0); n += 1
                        }
                    }
                    ink[y * cam + x] = min(1, max(0, acc / max(n, 1) * 1.6))
                }
            }
            if let h = dec.feed(ink: ink) { hit = h; break }
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if let hit, hit.0 == id, hit.1 == secret {
            log("离屏粒子云解码：\(String(format: "%06X / %08X", hit.0, hit.1))（\(ms) ms，导频 \(String(format: "%.2f", dec.lastScore))）")
        } else {
            log("离屏粒子云解码失败（导频 \(String(format: "%.2f", dec.lastScore))）"); ok = false
        }
        verdict = ok ? "全部通过" : "有失败"
    }

    /// 预乘过的 BGRA（透明底）→ 白底上的图（截图里看得到 GPU 画出来的样子）
    private static func image(_ px: [UInt8], side: Int) -> UIImage? {
        var rgba = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            let a = Float(px[i * 4 + 3]) / 255
            rgba[i * 4] = UInt8(min(255, Float(px[i * 4 + 2]) + (1 - a) * 255))
            rgba[i * 4 + 1] = UInt8(min(255, Float(px[i * 4 + 1]) + (1 - a) * 255))
            rgba[i * 4 + 2] = UInt8(min(255, Float(px[i * 4]) + (1 - a) * 255))
        }
        guard let prov = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
