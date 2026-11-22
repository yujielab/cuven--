import Foundation
import LocalAuthentication

// MARK: - 光学配对的后端（check.cuven.us /pair/*）与设备令牌
//
// 要登录的设备（这台 iPhone 的登录页「用 iPhone 扫描登录」，或者网页）：open → 显示粒子云和 6 位数字 → wait 长轮询
// 已登录的 iPhone（账户页「扫描登录其他设备」）：扫到 → peek 看是哪台设备 → 面容 ID → approve
// 扫描端要带设备令牌（登录时领、存钥匙串）—— 不然谁都能「批准」一次。没有令牌（以前登录的、用面容 ID 登录的）先验证一次身份。

enum PairService {
    static let base = AccountAPI.base

    struct Opened: Decodable { let ok: Bool?; let id: UInt32; let secret: UInt32; let poll: String; let code: String; let ttl: Int; let exp: Double }
    struct Who: Decodable { let device: String; let geo: String; let ip: String; let time: String }
    struct Waited: Decodable {
        let ok: Bool?; let status: String?; let username: String?; let email: String?; let code: String?; let device: String?
        let error: String?; let message: String?
    }
    struct Reply: Decodable { let ok: Bool?; let error: String?; let message: String?; let who: Who?; let username: String?; let device: String?; let code: String? }

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
    static func saveDevice(_ t: String?) {
        guard let t, t.hasPrefix("d1.") else { return }
        Keychain.set(Data(t.utf8), account: tokenKey)
    }
    static func clearDevice() { Keychain.delete(account: tokenKey) }

    /// 密码登录成功后顺手领一枚（后台，失败不影响登录）
    static func fetchDevice(username: String, password: String) {
        Task.detached {
            if let (_, r) = try? await post("/session", ["username": username, "password": password, "device": true], as: Reply.self) {
                saveDevice(r.device)
            }
        }
    }

    /// 扫描前验证一次身份：密码
    static func verifyPassword(username: String, password: String) async -> String? {
        guard let (_, r) = try? await post("/session", ["username": username, "password": password, "device": true], as: Reply.self) else { return "连不上账号中心，稍后再试" }
        if let t = r.device { saveDevice(t); return nil }
        return r.message ?? "密码不对"
    }
    /// 扫描前验证一次身份：邮箱验证码（发）
    static func sendOtp(username: String) async -> (hint: String?, error: String?) {
        struct S: Decodable { let ok: Bool?; let hint: String?; let message: String? }
        guard let (_, r) = try? await post("/session-otp/send", ["username": username], as: S.self) else { return (nil, "连不上账号中心，稍后再试") }
        return r.ok == true ? (r.hint, nil) : (nil, r.message ?? "验证码发送失败")
    }
    /// 扫描前验证一次身份：邮箱验证码（核对）
    static func verifyOtp(username: String, code: String) async -> String? {
        guard let (_, r) = try? await post("/session-otp/verify", ["username": username, "code": code, "device": true], as: Reply.self) else { return "连不上账号中心，稍后再试" }
        if let t = r.device { saveDevice(t); return nil }
        return r.message ?? "验证码不正确"
    }

    // MARK: 显示的那一边

    static func open(device: String) async throws -> Opened {
        let (code, r) = try await post("/pair/open", ["device": device], as: Opened.self)
        guard code == 200 else { throw Failure.server("open", "暂时开不了，稍后再试") }
        return r
    }
    static func wait(_ o: Opened) async -> Waited? {
        try? await post("/pair/wait", ["id": o.id, "poll": o.poll], as: Waited.self, timeout: 30).1
    }
    static func cancel(_ o: Opened) {
        Task.detached { _ = try? await post("/pair/cancel", ["id": o.id, "poll": o.poll], as: Reply.self) }
    }

    // MARK: 扫描的那一边

    /// target：扫到的（编号, 密钥），或者手动输的 6 位数字
    enum Target { case code(id: UInt32, secret: UInt32), digits(String) }
    private static func body(_ t: Target, _ device: String) -> [String: Any] {
        switch t {
        case .code(let id, let s): return ["id": id, "secret": s, "device": device]
        case .digits(let d): return ["code": d, "device": device]
        }
    }
    static func peek(_ t: Target) async -> Result<Who, Failure> {
        guard let dev = deviceToken else { return .failure(.server("bad_device", "")) }
        guard let (_, r) = try? await post("/pair/peek", body(t, dev), as: Reply.self) else { return .failure(.network) }
        if let w = r.who { return .success(w) }
        if r.error == "bad_device" { clearDevice() }
        return .failure(.server(r.error ?? "error", r.message ?? "出错了"))
    }
    static func approve(_ t: Target) async -> Result<String, Failure> {
        guard let dev = deviceToken else { return .failure(.server("bad_device", "")) }
        guard let (_, r) = try? await post("/pair/approve", body(t, dev), as: Reply.self) else { return .failure(.network) }
        if r.ok == true, let u = r.username { return .success(u) }
        if r.error == "bad_device" { clearDevice() }
        return .failure(.server(r.error ?? "error", r.message ?? "出错了"))
    }

    /// 批准之前：面容 ID / 触控 ID / 设备密码（没设的设备直接过）
    static func confirmOwner(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
