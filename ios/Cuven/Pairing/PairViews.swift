import SwiftUI
import AVFoundation

// MARK: - 光学配对的界面
//
// · PairShowView（登录页「用 iPhone 扫描登录」）：这台设备要登录 —— 显示粒子云和 6 位数字，等另一台已登录的 iPhone 扫
// · PairScanSheet（账户页「扫描登录其他设备」）：照 Apple 配对的样子 ——「将图案放在圆圈中」、圆形取景框、蓝圈、「手动验证」；
//   扫到 → 确认卡（哪台设备、在哪儿、几点）→ 面容 ID → 批准
// · PairLabView（启动参数 -pairLab，自检）：编码对照、离屏画一团云再解出来

private let pairBlue = Color(red: 0.36, green: 0.62, blue: 0.95)

// MARK: 显示的那一边

struct PairShowView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var opened: PairService.Opened?
    @State private var status = "正在准备…"
    @State private var showDigits = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { close() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.black.opacity(0.75))
                            .frame(width: 44, height: 44).background(Circle().fill(Color.black.opacity(0.06)))
                    }
                    .accessibilityLabel("关闭")
                    .accessibilityIdentifier("pair-show-close")
                }
                .padding(.horizontal, 20)
                Text("用 iPhone 扫描登录")
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(.black)
                    .padding(.top, 8)
                Text("在已登录 Cuven 的 iPhone 上打开「账户 → 扫描登录其他设备」，对准这团粒子云。")
                    .font(.system(size: 16)).foregroundStyle(.black.opacity(0.6))
                    .multilineTextAlignment(.center).padding(.horizontal, 36).padding(.top, 10)
                PairCloudView(id: opened?.id, secret: opened?.secret)
                    .frame(width: 330, height: 330)
                    .padding(.top, 18)
                    .accessibilityIdentifier("pair-cloud")
                Text(status)
                    .font(.system(size: 15)).foregroundStyle(.black.opacity(0.55))
                    .padding(.top, 6)
                Spacer()
                if showDigits, let code = opened?.code {
                    VStack(spacing: 6) {
                        Text("在 iPhone 上选「手动验证」，输入：").font(.system(size: 14)).foregroundStyle(.black.opacity(0.55))
                        Text(code.map(String.init).joined(separator: " "))
                            .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.black)
                            .accessibilityIdentifier("pair-show-digits")
                    }
                    .padding(.bottom, 14)
                    .transition(.opacity)
                }
                Button { withAnimation(.easeInOut(duration: 0.25)) { showDigits.toggle() } } label: {
                    Text(showDigits ? "隐藏数字" : "手动验证")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(Capsule().fill(.white))
                        .overlay(Capsule().stroke(Color.black.opacity(0.12)))
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
                .accessibilityIdentifier("pair-show-manual")
            }
        }
        .onAppear { if task == nil { task = Task { await run() } } }
        .onDisappear { task?.cancel(); if let o = opened { PairService.cancel(o) } }
    }

    private func run() async {
        while !Task.isCancelled {
            guard let o = try? await PairService.open(device: UIDevice.current.userInterfaceIdiom == .pad ? "iPad · Cuven" : "iPhone · Cuven") else {
                status = "暂时连不上，稍后再试"
                try? await Task.sleep(for: .seconds(5)); continue
            }
            opened = o
            status = "等待另一台 iPhone 扫描…"
            var renew = false
            while !Task.isCancelled && !renew {
                guard let r = await PairService.wait(o) else { try? await Task.sleep(for: .seconds(2)); continue }
                switch r.status {
                case "approved":
                    if let u = r.username {
                        PairService.saveDevice(r.device)
                        Haptics.success()
                        status = "已批准"
                        account.signIn(username: u, email: r.email ?? "", method: "pair", alert: false)
                        dismiss()
                    }
                    return
                case "open": continue
                default: renew = true                                   // 过期 / 作废 / 取消：换一团
                }
            }
        }
    }

    private func close() {
        task?.cancel()
        if let o = opened { PairService.cancel(o) }
        dismiss()
    }
}

// MARK: 扫描的那一边

struct PairScanSheet: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    enum Stage: Equatable { case verify, scanning, manual, confirm, working, done, failed(String) }
    @State private var stage: Stage = .scanning
    @State private var target: PairService.Target?
    @State private var who: PairService.Who?
    @State private var digits = ""
    @State private var password = ""
    @State private var otpHint: String?
    @State private var otpCode = ""
    @State private var verifyError: String?
    @State private var busy = false
    @State private var scanner = PairScanner()
    @State private var camDenied = false
    /// 相机读出来、后端说「不存在 / 过期」的码。CRC-8 挡不住所有误读（约 1/256 的乱码能过），乱码的编号是随机的：
    /// 第一次被拒先接着扫；同一个码再被拒一次（真的过期了）才报错
    @State private var rejected: Set<UInt64> = []

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
        .onDisappear { scanner?.stop() }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .verify: verifyView
        case .scanning: scanView
        case .manual: manualView
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
                    Text("Cuven 没有相机权限。\n到「设置」里打开，或者用手动验证。").font(.system(size: 15)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(30)
                } else if let s = scanner {
                    PairCameraPreview(session: s.session).clipShape(Circle())
                } else {
                    Circle().fill(Color.black.opacity(0.85))
                }
                Circle().stroke(pairBlue, lineWidth: 10)
            }
            .frame(width: 300, height: 300)
            .padding(.top, 40)
            .accessibilityIdentifier("pair-scan-viewfinder")
            Spacer(minLength: 40)
            Button { stage = .manual; scanner?.stop() } label: {
                Text("手动验证").font(.system(size: 18, weight: .semibold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .background(Capsule().fill(Color.white.opacity(0.85)))
                    .overlay(Capsule().stroke(Color.black.opacity(0.12)))
            }
            .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 28)
            .accessibilityIdentifier("pair-scan-manual")
        }
        .padding(.top, 4)
    }

    private var manualView: some View {
        VStack(spacing: 0) {
            titleBlock("手动验证", "输入另一台设备上显示的 6 位数字。")
            TextField("000000", text: $digits)
                .keyboardType(.numberPad)
                .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                .multilineTextAlignment(.center)
                .foregroundStyle(.black)
                .padding(.vertical, 18)
                .background(RoundedRectangle(cornerRadius: 18).fill(.white))
                .padding(.horizontal, 48).padding(.top, 50)
                .onChange(of: digits) { _, v in
                    let d = String(v.filter(\.isNumber).prefix(6))
                    if d != v { digits = d }
                    if d.count == 6 { found(.digits(d)) }
                }
                .accessibilityIdentifier("pair-manual-field")
            Button("改用相机扫描") { digits = ""; stage = .scanning; scanner?.start() }
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(pairBlue).padding(.top, 24)
        }
    }

    private var confirmView: some View {
        VStack(spacing: 0) {
            titleBlock("在这台设备上登录？", "用你的账户「\(account.displayName)」登录：")
            VStack(alignment: .leading, spacing: 14) {
                row("desktopcomputer", who?.device ?? "未知设备")
                row("mappin.and.ellipse", (who?.geo ?? "") + ((who?.ip ?? "").isEmpty ? "" : " · \(who!.ip)"))
                row("clock", who?.time ?? "")
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 24).fill(.white))
            .padding(.horizontal, 28).padding(.top, 30)
            Text("只批准你自己面前的设备。别人发来的粒子云、截图，不要扫。")
                .font(.system(size: 14)).foregroundStyle(.black.opacity(0.55)).multilineTextAlignment(.center)
                .padding(.horizontal, 36).padding(.top, 16)
            Spacer(minLength: 30)
            Button { Task { await approve() } } label: {
                Text("登录").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 58).background(Capsule().fill(Color.black))
            }
            .padding(.horizontal, 32)
            .accessibilityIdentifier("pair-confirm")
            Button("取消") { dismiss() }.font(.system(size: 17)).foregroundStyle(.black.opacity(0.7)).padding(.vertical, 16)
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(.black.opacity(0.55)).frame(width: 24)
            Text(text).font(.system(size: 17)).foregroundStyle(.black)
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
            Button("重新扫描") { target = nil; who = nil; digits = ""; stage = .scanning; scanner?.start() }
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
        guard PairService.deviceToken != nil else { stage = .verify; return }
        stage = .scanning
        startCamera()
    }

    private func startCamera() {
        Task {
            if !PairScanner.authorized, !(await PairScanner.requestAccess()) { camDenied = true; return }
            scanner?.onResult = { id, secret in found(.code(id: id, secret: secret)) }
            scanner?.start()
        }
    }

    private func found(_ t: PairService.Target) {
        guard stage == .scanning || stage == .manual else { return }
        Haptics.light()
        scanner?.stop()
        target = t
        stage = .working
        Task {
            switch await PairService.peek(t) {
            case .success(let w): who = w; stage = .confirm
            case .failure(.server("bad_device", _)): stage = .verify
            case .failure(.server("expired", let m)):
                if case .code(let id, let sec) = t, rejected.insert(UInt64(id) << 32 | UInt64(sec)).inserted {
                    target = nil; stage = .scanning; scanner?.start()
                } else {
                    stage = .failed(m)
                }
            case .failure(.server(_, let m)): stage = .failed(m)
            case .failure(.network): stage = .failed("连不上账号中心，稍后再试")
            }
        }
    }

    private func approve() async {
        guard let t = target else { return }
        guard await PairService.confirmOwner(reason: "批准「\(who?.device ?? "这台设备")」登录你的 Cuven 账户") else { return }
        stage = .working
        switch await PairService.approve(t) {
        case .success: Haptics.success(); stage = .done
        case .failure(.server("bad_device", _)): stage = .verify
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
        if target != nil { stage = .working; if let t = target { found2(t) } } else { stage = .scanning; startCamera() }
    }

    private func found2(_ t: PairService.Target) { stage = .scanning; found(t) }

    private func sendOtp() async {
        let r = await PairService.sendOtp(username: account.displayName)
        if let e = r.error { verifyError = e } else { otpHint = r.hint; verifyError = nil }
    }
}

/// 相机取景（铺满、裁成圆形）
struct PairCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class V: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> V {
        let v = V()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: V, context: Context) {}
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
