import Foundation
import LocalAuthentication

// MARK: - 光学配对的后端（check.cuven.us /pair/*）与设备令牌
//
// 要登录的设备（这台 iPhone 的登录页「用 iPhone 扫描登录」，或者网页）：open → 显示粒子云 → wait 长轮询（快到期、没人扫过就提前换一团）
// 已登录的 iPhone（账户页「扫描登录其他设备」）：扫到 → peek 看是哪台设备、离你多远 → 面容 ID → approve
// 扫描端要带设备令牌（登录时领、存钥匙串）—— 不然谁都能「批准」一次。没有令牌（以前登录的、用面容 ID 登录的）先验证一次身份。
// 6 位数字那条路后端已经关了（只能扫粒子云）。

enum PairService {
    static let base = AccountAPI.base

    /// exp：毫秒（后端的时钟）；ttl：秒。后端还会回一个空的 code（旧版 App 要），这里不用
    struct Opened: Decodable { let ok: Bool?; let id: UInt32; let secret: UInt32; let poll: String; let ttl: Int?; let exp: Double }
    /// 要登录的那台设备：自报的名字（后端滤过）、大概在哪儿、IP 前几段、那边的当地时间。缺哪项都按空的算
    struct Who: Decodable {
        let device: String; let geo: String; let ip: String; let time: String
        private enum CodingKeys: String, CodingKey { case device, geo, ip, time }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            device = (try? c.decodeIfPresent(String.self, forKey: .device)) ?? ""
            geo = (try? c.decodeIfPresent(String.self, forKey: .geo)) ?? ""
            ip = (try? c.decodeIfPresent(String.self, forKey: .ip)) ?? ""
            time = (try? c.decodeIfPresent(String.self, forKey: .time)) ?? ""
        }
    }
    /// 后端拿扫描端自己的请求和那台设备比：level = same_network（同一个网段 / 同一家运营商）、same_country、foreign、unknown；
    /// org、country 是那台设备的网络运营方、国家或地区（两位代码）。旧版后端不回 → nil
    struct Near: Decodable { let level: String?; let org: String?; let country: String? }
    struct Waited: Decodable {
        let ok: Bool?; let status: String?; let username: String?; let email: String?; let code: String?; let device: String?
        let error: String?; let message: String?
        /// status == open 时：现在的到期时间（毫秒；有人扫过会延长一次）、有没有人扫过（peek）。旧版后端不回 peeked
        let exp: Double?; let peeked: Bool?
    }
    struct Reply: Decodable {
        let ok: Bool?; let error: String?; let message: String?; let who: Who?; let username: String?; let device: String?; let code: String?
        let near: Near?; let age: Double?; let exp: Double?
    }
    /// peek 看到的：哪台设备、离你多远、打开了多久（秒）
    struct Peeked { let who: Who; let near: Near?; let age: Double? }

    enum Failure: Error { case network, server(String, String) }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static func post<T: Decodable>(_ path: String, _ body: [String: Any], as: T.Type, timeout: TimeInterval = 15) async throws -> (Int, T) {
        guard let u = URL(string: base + path) else { throw Failure.network }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let (d, resp) = try? await session.data(for: r) else { throw Failure.network }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let v = try? JSONDecoder().decode(T.self, from: d) else { throw Failure.server("bad_reply", "后端回的东西看不懂（HTTP \(code)）") }
        return (code, v)
    }

    // MARK: 设备令牌

    private static let tokenKey = "pair-device"
    static var deviceToken: String? {
        Keychain.get(account: tokenKey).flatMap { String(data: $0, encoding: .utf8) }
    }
    /// 存进钥匙串；存不进去（或者不是设备令牌）回 false
    @discardableResult
    static func saveDevice(_ t: String?) -> Bool {
        guard let t, t.hasPrefix("d1.") else { return false }
        return Keychain.set(Data(t.utf8), account: tokenKey) && deviceToken == t
    }
    static func clearDevice() { Keychain.delete(account: tokenKey) }

    /// 设备令牌是哪个账户的：d1.<用户名 base64url>.<编号>.<到期>.<签名>
    static func tokenUser(_ t: String) -> String? {
        let p = t.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 5, p[0] == "d1" else { return nil }
        var b = String(p[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).flatMap { String(data: $0, encoding: .utf8) }
    }
    /// 这个账户的设备令牌。钥匙串里那一枚不是它的（换过账户：钥匙串退出登录、甚至删掉 App 都还在）→ 作废、回 nil，
    /// 扫描前先给当前账户验证一次身份。以前不核对：一直用最早那个账户的令牌批准，别的设备总登录到同一个号
    static func accountDevice(_ username: String) -> String? {
        guard let t = deviceToken else { return nil }
        guard !username.isEmpty, tokenUser(t) == username else { clearDevice(); return nil }
        return t
    }
    /// 登录 / 换账户 / 退出时调用：令牌不是这个账户的就扔掉（nil = 退出登录，全扔）
    static func keepDevice(onlyFor username: String?) {
        guard let t = deviceToken else { return }
        if let username, tokenUser(t) == username { return }
        clearDevice()
    }

    /// 登录 / 验证通过的回复 → 设备令牌存好（请求里都带了 device: true，账号中心直接发）。
    /// 以前没带时拿识别代码去 /device 换一枚：那条路后端关了（识别代码不能再换出长期令牌）。成功回 nil，否则回给用户看的一句话
    private static func adoptDevice(from r: Reply, for username: String? = nil) async -> String? {
        AccountAPI.remember(code: r.code)
        guard let token = r.device else { return "账号中心没有发设备令牌，稍后再试" }
        if let username, tokenUser(token) != username { return "账号中心发来的设备令牌不是这个账户的，重新登录一次" }
        return saveDevice(token) ? nil : "设备令牌存不进钥匙串，重启 App 再试"
    }

    /// 没通过时给用户看的话：后端说了就用后端的；没说按状态码猜
    private static func failureText(_ r: Reply, status: Int, wrong: String) -> String {
        if let m = r.message, !m.isEmpty { return m }
        switch r.error {
        case "bad_credentials", "wrong_code": return wrong
        case "client_update": return "账号中心要求更新 App（新版在本机算密码摘要）"
        default: return status == 0 ? "连不上账号中心，稍后再试" : "验证没通过（\(r.error ?? "HTTP \(status)")）"
        }
    }

    /// 密码登录（旧版账号中心、本机比对）成功后补领一枚（后台，失败不影响登录）
    static func fetchDevice(username: String, key: String) {
        Task.detached {
            if let (_, r) = try? await post("/session", ["username": username, "key": key, "device": true], as: Reply.self), r.ok == true {
                _ = await adoptDevice(from: r, for: username)
            }
        }
    }

    /// 扫描前验证一次身份：密码。口令 v3：本机算好 key 交给账号中心（不发密码）；旧版账号中心不认 key 再发一次明文
    static func verifyPassword(username: String, password: String) async -> String? {
        guard let params = await AccountAPI.passParams(username) else { return "连不上账号中心，稍后再试" }
        guard let key = await PasswordHash.key(password, params) else { return "这个账户的密码参数读不懂" }
        guard let (status, r) = try? await post("/session", ["username": username, "key": key, "device": true], as: Reply.self) else { return "连不上账号中心，稍后再试" }
        if r.ok == true || r.device != nil { return await adoptDevice(from: r, for: username) }
        if r.error == "bad_request" {
            guard let (s2, r2) = try? await post("/session", ["username": username, "password": password, "device": true], as: Reply.self) else { return "连不上账号中心，稍后再试" }
            if r2.ok == true || r2.device != nil { return await adoptDevice(from: r2, for: username) }
            return failureText(r2, status: s2, wrong: "密码不对")
        }
        return failureText(r, status: status, wrong: "密码不对")
    }
    /// 扫描前验证一次身份：邮箱验证码（发）
    static func sendOtp(username: String) async -> (hint: String?, error: String?) {
        struct S: Decodable { let ok: Bool?; let hint: String?; let message: String? }
        guard let (_, r) = try? await post("/session-otp/send", ["username": username], as: S.self) else { return (nil, "连不上账号中心，稍后再试") }
        return r.ok == true ? (r.hint, nil) : (nil, r.message ?? "验证码发送失败")
    }
    /// 扫描前验证一次身份：邮箱验证码（核对）
    static func verifyOtp(username: String, code: String) async -> String? {
        guard let (status, r) = try? await post("/session-otp/verify", ["username": username, "code": code, "device": true], as: Reply.self) else { return "连不上账号中心，稍后再试" }
        if r.ok == true || r.device != nil { return await adoptDevice(from: r, for: username) }
        return failureText(r, status: status, wrong: "验证码不正确")
    }

    // MARK: 显示的那一边
    // 只有 iPhone / iPad 的显示端要设备令牌（want_device / device: true）：登录以后它自己也能扫码批准别的设备。网页、Windows 不要

    static func open(device: String) async throws -> Opened {
        let (code, r) = try await post("/pair/open", ["device": device, "want_device": true], as: Opened.self)
        guard code == 200 else { throw Failure.server("open", "暂时开不了，稍后再试") }
        return r
    }
    /// ms：后端最多等多久（0…20000）。到点前没结果回 status = open
    static func wait(_ o: Opened, ms: Int = 20000) async -> Waited? {
        let w = max(0, min(20000, ms))
        return try? await post("/pair/wait", ["id": o.id, "poll": o.poll, "device": true, "wait": w], as: Waited.self, timeout: 30).1
    }
    static func cancel(_ o: Opened) {
        let id = o.id, poll = o.poll
        Task.detached { _ = try? await post("/pair/cancel", ["id": id, "poll": poll], as: Reply.self) }
    }

    /// 显示端下一步：drop = 不画这一团了（本机时钟都过了到期时间，还没等到后端回话）；
    /// rotate = 快到期了、上一次 wait 时还没人扫过 → 先开下一团换上去，再取消这一团（以前等后端说过期才换：最后那几秒扫到的，批准时都会失败）；
    /// wait(ms) = 长轮询这么久（有人扫过、或者换不了：一直等；不然等到「该换了」那一刻）
    enum DisplayStep: Equatable { case drop, rotate, wait(Int) }
    static let rotateAhead: Double = 8
    static func displayStep(left: Double, peeked: Bool, noRotate: Bool) -> DisplayStep {
        if !(left >= -1) { return .drop }
        if left < rotateAhead, !peeked, !noRotate { return .rotate }
        if peeked || noRotate { return .wait(20000) }
        return .wait(Int(max(0, min(20000, (left - rotateAhead) * 1000))))
    }

    // MARK: 扫描的那一边

    /// 扫到的（编号, 密钥）
    struct Target: Equatable, Sendable {
        let id: UInt32; let secret: UInt32
        var key: UInt64 { PairCodec.key(id: id, secret: secret) }
    }
    /// username：这台 iPhone 现在登录的账户。账号中心核对设备令牌是不是它的，不是 → device_mismatch。
    /// caps: near —— 这一版看得懂「离你多远」（后端才会在那台设备不在同一个国家时要求 ack）
    private static func body(_ t: Target, _ device: String, _ username: String) -> [String: Any] {
        ["id": t.id, "secret": t.secret, "device": device, "username": username, "caps": ["near"]]
    }
    /// 令牌作废（吊销 / 过期 / 不是这个账户的）→ 扔掉，界面回到「先验证一下身份」
    private static func deviceRejected(_ r: Reply) -> Bool {
        guard r.error == "bad_device" || r.error == "device_mismatch" else { return false }
        clearDevice()
        return true
    }
    /// 错误码：not_found（没认清：编号不存在或者密钥不对 —— 多半是误读）、expired（真有这一团，但过期 / 取消 / 用过了）、
    /// bad_device（令牌作废）、rate_limited……
    static func peek(_ t: Target, as username: String) async -> Result<Peeked, Failure> {
        guard let dev = accountDevice(username) else { return .failure(.server("bad_device", "")) }
        guard let (_, r) = try? await post("/pair/peek", body(t, dev, username), as: Reply.self) else { return .failure(.network) }
        if let w = r.who {
            // 旧版账号中心不核对：回来的账户对不上也当作废
            if let u = r.username, u != username { clearDevice(); return .failure(.server("bad_device", "")) }
            return .success(Peeked(who: w, near: r.near, age: r.age))
        }
        if deviceRejected(r) { return .failure(.server("bad_device", "")) }
        return .failure(.server(r.error ?? "error", r.message ?? "出错了"))
    }
    /// ackFar：那台设备不在同一个国家或地区，用户点了第二下确认它就在面前（不带 → 后端回 409 far）
    static func approve(_ t: Target, as username: String, ackFar: Bool = false) async -> Result<String, Failure> {
        guard let dev = accountDevice(username) else { return .failure(.server("bad_device", "")) }
        var b = body(t, dev, username)
        if ackFar { b["ack"] = "far" }
        guard let (_, r) = try? await post("/pair/approve", b, as: Reply.self) else { return .failure(.network) }
        if r.ok == true, let u = r.username { return .success(u) }
        if deviceRejected(r) { return .failure(.server("bad_device", "")) }
        return .failure(.server(r.error ?? "error", r.message ?? "出错了"))
    }

    enum OwnerCheck: Equatable { case ok, cancelled, refused(String) }
    static let noPasscodeText = "要先在「设置」里设置设备密码，才能批准其他设备登录"
    /// 批准之前：面容 ID / 触控 ID / 设备密码。提示语是固定的（不放那台设备自报的名字）。
    /// 没设设备密码的设备不让批准（以前直接放过：谁拿着没锁的手机都能批准）
    static func confirmOwner() async -> OwnerCheck {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            if let e = err, e.domain == LAErrorDomain, e.code == LAError.Code.passcodeNotSet.rawValue { return .refused(noPasscodeText) }
            return .refused("这台设备现在验证不了身份（\(err?.code ?? 0)），稍后再试")
        }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "批准另一台设备登录你的 Cuven 账户") ? .ok : .cancelled
        } catch let e as LAError where e.code == .passcodeNotSet {
            return .refused(noPasscodeText)
        } catch {
            return .cancelled
        }
    }
}
