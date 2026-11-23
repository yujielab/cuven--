import Foundation
import CommonCrypto
import LocalAuthentication
import Security
import Observation

// MARK: - Cuven 账户（与网页版同一个后端、同一套规矩）
//
// 后端：https://check.cuven.us
//   GET  /check/<用户名>                    { exists, data? }   账户在不在（可能直接带着账户档）
//   GET  /file/username_<用户名>.json        账户档 v2
//   PUT  /file/username_<用户名>.json        写账户档（注册、设定 / 重设密码）
//   GET  /file/email_<邮箱>.json             { username }       邮箱 → 用户名
//   PUT  /file/email_<邮箱>.json             { username, created_at }
//   GET  /email-lookup/<邮箱>                { exists, username } 旧账户反查兜底
//   POST /send-code   { email }             { ok, message }
//   POST /verify-code { email, code }       { ok, error: wrong_code | expired | too_many_attempts, attemptsLeft, message }
//   POST /notify      { type, username, method }   账户邮件通知（即发即忘）
//   GET  /settings/<用户名>                  { settings: { avatar: { type: default | custom, id } } }
//   头像：/default/<id>、/user/<用户名>（现在先读网页版账户页的 user.cuven.online，读不到才退回这里：见 Profile.swift）
// 账户档 v2：{ version: 2, auth: "password", username, email, pass: { algo, iter, salt, hash }, webauthn, created_at, updated_at }
// 密码只在本机做 PBKDF2-SHA256（310000 轮，16 字节盐，base64url）比对，与网页版逐字节一致。

/// 账户档里只需原样带回的字段（网页版的 webauthn 凭据）
enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

struct AccountRecord: Codable {
    struct PassHash: Codable {
        var algo: String?
        var iter: Int?
        var salt: String
        var hash: String

        init(algo: String?, iter: Int?, salt: String, hash: String) {
            self.algo = algo; self.iter = iter; self.salt = salt; self.hash = hash
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            algo = c.str(.algo)
            iter = c.int(.iter)
            salt = c.str(.salt) ?? ""
            hash = c.str(.hash) ?? ""
        }
    }

    var version: Int?
    var auth: String?
    var username: String?
    var email: String?
    var pass: PassHash?
    var webauthn: JSONValue?
    var created_at: String?
    var updated_at: String?

    /// 设过密码：有盐就算（账号中心开了 STRICT_AUTH 时公开的账户档不再带摘要，只有 salt / iter）
    var hasPass: Bool { !(pass?.salt.isEmpty ?? true) }

    init(version: Int?, auth: String?, username: String?, email: String?, pass: PassHash?, webauthn: JSONValue?,
         created_at: String?, updated_at: String?) {
        self.version = version; self.auth = auth; self.username = username; self.email = email; self.pass = pass
        self.webauthn = webauthn; self.created_at = created_at; self.updated_at = updated_at
    }

    /// 宽松解码：个别字段类型不对（数字写成字符串之类）也不至于整份档读不出来
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.int(.version)
        auth = c.str(.auth)
        username = c.str(.username)
        email = c.str(.email)
        pass = try? c.decodeIfPresent(PassHash.self, forKey: .pass)
        webauthn = try? c.decodeIfPresent(JSONValue.self, forKey: .webauthn)
        created_at = c.str(.created_at)
        updated_at = c.str(.updated_at)
    }

    /// 与网页版 buildRecord 一致：保留原来的 webauthn 与建立时间
    static func build(name: String, email: String, pass: PassHash, previous: AccountRecord?) -> AccountRecord {
        let now = ISO8601DateFormatter.cuven.string(from: Date())
        let mail = (email.isEmpty ? (previous?.email ?? "") : email).trimmingCharacters(in: .whitespaces).lowercased()
        return AccountRecord(version: 2, auth: "password", username: name, email: mail, pass: pass,
                             webauthn: previous?.webauthn ?? .null, created_at: previous?.created_at ?? now, updated_at: now)
    }
}

extension ISO8601DateFormatter {
    /// 与 JS 的 toISOString 同格式（带毫秒、Z 结尾）
    static let cuven: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - 密码（PBKDF2-SHA256）

enum PasswordHash {
    static let iterations = 310_000

    static func derive(_ password: String, salt: Data, iterations: Int) -> Data {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        guard !pw.isEmpty, !salt.isEmpty else { return Data() }
        let status = out.withUnsafeMutableBytes { o in
            salt.withUnsafeBytes { s in
                pw.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pw.count) { pc in
                        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pc, pw.count,
                                             s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                             o.bindMemory(to: UInt8.self).baseAddress, 32)
                    }
                }
            }
        }
        return status == Int32(kCCSuccess) ? out : Data()
    }

    /// 比对：慢（31 万轮），在后台线程算
    static func check(_ password: String, _ pass: AccountRecord.PassHash) async -> Bool {
        guard !password.isEmpty, let salt = Base64URL.decode(pass.salt) else { return false }
        let iter = pass.iter ?? iterations
        return await Task.detached(priority: .userInitiated) {
            Base64URL.encode(derive(password, salt: salt, iterations: iter)) == pass.hash
        }.value
    }

    /// 口令 v3：本机算 PBKDF2 得到 key（base64url），只把 key 发给账号中心核对；密码本身不离开设备
    static func key(_ password: String, _ pass: AccountRecord.PassHash) async -> String? {
        guard !password.isEmpty, let salt = Base64URL.decode(pass.salt), !salt.isEmpty else { return nil }
        let iter = pass.iter ?? iterations
        let k = await Task.detached(priority: .userInitiated) { derive(password, salt: salt, iterations: iter) }.value
        return k.isEmpty ? nil : Base64URL.encode(k)
    }

    static func make(_ password: String) async -> AccountRecord.PassHash {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let hash = await Task.detached(priority: .userInitiated) { derive(password, salt: salt, iterations: iterations) }.value
        return .init(algo: "PBKDF2-SHA256", iter: iterations, salt: Base64URL.encode(salt), hash: Base64URL.encode(hash))
    }

    /// 至少 8 个字元，需包含字母与数字（与网页版同一条）
    static func isStrong(_ p: String) -> Bool {
        p.count >= 8 && p.range(of: "[A-Za-z]", options: .regularExpression) != nil && p.range(of: "[0-9]", options: .regularExpression) != nil
    }
}

enum Base64URL {
    static func encode(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}

// MARK: - 接口

enum AccountAPI {
    static let base = "https://check.cuven.us"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 与 JS encodeURIComponent 同一套保留字符
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    static func component(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func url(_ path: String) -> URL? { URL(string: base + path) }

    // 识别代码（c1.…，5 分钟）：登录 / 验证码核对时账号中心给的。写账户档、邮箱映射时带上（Authorization: Bearer），
    // 账号中心开了 STRICT_AUTH 以后，改已有账户必须有它
    private static let identityLock = NSLock()
    nonisolated(unsafe) private static var identity: (code: String, until: Date)?
    static func remember(code: String?) {
        guard let code, code.hasPrefix("c1.") else { return }
        identityLock.lock(); identity = (code, Date().addingTimeInterval(280)); identityLock.unlock()
    }
    private static var freshIdentity: String? {
        identityLock.lock(); defer { identityLock.unlock() }
        guard let i = identity, i.until > Date() else { return nil }
        return i.code
    }

    private static func getJSON<T: Decodable>(_ path: String, as: T.Type) async throws -> (Int, T?) {
        guard let u = url(path) else { throw URLError(.badURL) }
        let (data, resp) = try await session.data(from: u)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (code, (200..<300).contains(code) ? try? JSONDecoder().decode(T.self, from: data) : nil)
    }

    private static func send(_ method: String, _ path: String, json: some Encodable) async -> (Int, Data?) {
        guard let u = url(path) else { return (0, nil) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if method != "GET", let code = freshIdentity { req.setValue("Bearer " + code, forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONEncoder().encode(json)
        guard let (data, resp) = try? await session.data(for: req) else { return (0, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    enum Lookup { case found(AccountRecord?), missing, offline }

    /// 账户在不在；在的话带上账户档（读不到档 → found(nil)）
    static func fetchRecord(_ name: String) async -> Lookup {
        struct Check: Decodable { var exists: Bool?; var data: AccountRecord? }
        guard let reply = try? await getJSON("/check/" + component(name), as: Check.self), reply.0 > 0 else { return .offline }
        guard let check = reply.1, check.exists == true else { return reply.0 == 200 ? .missing : .offline }
        if let d = check.data { return .found(d) }
        let file = try? await getJSON("/file/" + component("username_\(name).json"), as: AccountRecord.self)
        return .found(file?.1)
    }

    /// 邮箱 → 用户名。"" = 没有绑定，nil = 网络错误
    static func lookupEmail(_ raw: String) async -> String? {
        let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
        struct Map: Decodable { var username: String? }
        struct Legacy: Decodable { var exists: Bool?; var username: String? }
        do {
            let (_, m) = try await getJSON("/file/" + component("email_\(email).json"), as: Map.self)
            if let n = m?.username, !n.isEmpty { return n }
            let (code, k) = try await getJSON("/email-lookup/" + component(email), as: Legacy.self)
            if code == 0 { return nil }
            return (k?.exists == true ? k?.username : nil) ?? ""
        } catch {
            return nil
        }
    }

    static func putRecord(_ r: AccountRecord) async -> Bool {
        (200..<300).contains(await putRecordStatus(r))
    }

    /// 写账户档，返回 HTTP 状态码（0 = 网络错误；登录页「保存失败（状态码）· 请重试」要用）
    static func putRecordStatus(_ r: AccountRecord) async -> Int {
        guard let name = r.username else { return 0 }
        let (code, _) = await send("PUT", "/file/" + component("username_\(name).json"), json: r)
        return code
    }

    /// 写「邮箱 → 用户名」对照。写成了（2xx）回 true：调用方这时才记「写过了」，没写成下次登录再写
    @discardableResult
    static func putEmailMap(_ email: String, username: String) async -> Bool {
        struct Map: Encodable { var username: String; var created_at: String }
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        let (code, _) = await send("PUT", "/file/" + component("email_\(e).json"),
                                   json: Map(username: username, created_at: ISO8601DateFormatter.cuven.string(from: Date())))
        return (200..<300).contains(code)
    }

    struct CodeReply: Decodable {
        var ok: Bool?
        var error: String?
        var message: String?
        var attemptsLeft: Int?
        var code: String?          // 带了用户名、邮箱是他绑的：识别代码
    }

    static func sendCode(_ email: String) async -> CodeReply? {
        struct Body: Encodable { var email: String }
        let (code, data) = await send("POST", "/send-code", json: Body(email: email))
        guard code > 0, let data else { return nil }
        return try? JSONDecoder().decode(CodeReply.self, from: data)
    }

    static func verifyCode(_ email: String, code: String, username: String? = nil) async -> CodeReply? {
        struct Body: Encodable { var email: String; var code: String; var username: String? }
        let (status, data) = await send("POST", "/verify-code", json: Body(email: email, code: code, username: username))
        guard status > 0, let data else { return nil }
        let r = try? JSONDecoder().decode(CodeReply.self, from: data)
        if r?.ok == true { remember(code: r?.code) }
        return r
    }

    /// 口令参数（salt / iter）：新版账号中心有 /auth/params，旧版从账户档里读
    static func passParams(_ name: String) async -> AccountRecord.PassHash? {
        struct P: Decodable { var ok: Bool?; var algo: String?; var iter: Int?; var salt: String? }
        if let (code, p) = try? await getJSON("/auth/params/" + component(name), as: P.self), code == 200, let p, let salt = p.salt, !salt.isEmpty {
            return .init(algo: p.algo, iter: p.iter, salt: salt, hash: "")
        }
        if case .found(let r) = await fetchRecord(name), let pass = r?.pass, !pass.salt.isEmpty { return pass }
        return nil
    }

    enum SessionResult { case ok(device: String?), wrong, throttled(String), unsupported, offline }

    /// 口令 v3：把本机算好的 key 交给账号中心核对（顺便领设备令牌、记下识别代码）。
    /// 旧版账号中心不认 key（回 bad_request）、服务端出错 → unsupported：调用方退回本机比对
    static func session(username: String, key: String) async -> SessionResult {
        struct Body: Encodable { var username: String; var key: String; var device: Bool }
        struct Reply: Decodable { var ok: Bool?; var code: String?; var device: String?; var error: String?; var message: String? }
        let (status, data) = await send("POST", "/session", json: Body(username: username, key: key, device: true))
        guard status > 0, let data else { return .offline }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data) else { return .unsupported }
        if r.ok == true { remember(code: r.code); return .ok(device: r.device) }
        switch r.error {
        case "bad_credentials": return .wrong
        case "rate_limited": return .throttled(r.message ?? "尝试太多次了，15 分钟后再试")
        default: return .unsupported
        }
    }

    /// 账户通知：收件人 / IP / 设备 / 时间由服务端解析；失败不影响任何流程
    static func notify(_ type: String, username: String, method: String? = nil) {
        struct Body: Encodable { var type: String; var username: String; var method: String? }
        Task.detached { _ = await AccountAPI.send("POST", "/notify", json: Body(type: type, username: username, method: method)) }
    }

    /// 头像：账户设置里选的默认头像或自己上传的
    static func avatarURL(_ name: String) async -> URL? {
        struct Avatar: Decodable { var type: String?; var id: JSONValue? }
        struct Settings: Decodable { var avatar: Avatar? }
        struct Reply: Decodable { var settings: Settings? }
        guard let reply = try? await getJSON("/settings/" + component(name), as: Reply.self), let av = reply.1?.settings?.avatar else { return nil }
        if av.type == "custom" { return url("/user/" + component(name) + "?v=\(Int(Date().timeIntervalSince1970 / 3600))") }
        var id = "4"
        switch av.id {
        case .number(let n)?: id = String(Int(n))
        case .string(let s)? where !s.isEmpty: id = s
        default: break
        }
        return url("/default/" + component(id))
    }
}

// MARK: - 钥匙串

enum Keychain {
    private static let service = "us.cuven.tv.account"

    @discardableResult
    static func set(_ data: Data, account: String, biometric: Bool = false) -> Bool {
        delete(account: account)
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        if biometric {
            guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil) else { return false }
            q[kSecAttrAccessControl as String] = ac
        } else {
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String, context: LAContext? = nil) -> Data? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let context { q[kSecUseAuthenticationContext as String] = context }
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - 登录状态

struct AccountSession: Codable, Equatable {
    var username: String
    var email: String
    var method: String
    var at: Date
}

/// 生物识别的结果：登录页照网页版分开说——取消了、没通过、这台设备用不了
enum BiometricOutcome { case ok, cancelled, failed, unavailable }

@MainActor
@Observable
final class AccountStore {
    /// 与网页版一致：登录 30 天有效
    static let ttl: TimeInterval = 30 * 86400

    private(set) var session: AccountSession?
    private(set) var avatarURL: URL?
    /// 本机为哪个账户开了面容 ID 快速登录（只存用户名作提示，凭据本身在受生物识别保护的钥匙串里）
    private(set) var faceIDUser: String? = UserDefaults.standard.string(forKey: "cuven_faceid_user")

    /// 演示数据 / UI 测试不需要登录（-CuvenSkipLogin 只在 Debug 构建里认）
    let loginRequired: Bool

    init() {
        #if DEBUG
        let skip = UserDefaults.standard.bool(forKey: "CuvenSkipLogin")
        #else
        let skip = false
        #endif
        loginRequired = !(DemoData.enabled || skip)
        if let d = Keychain.get(account: "session"), let s = try? JSONDecoder().decode(AccountSession.self, from: d),
           Date().timeIntervalSince(s.at) < Self.ttl {
            session = s
        }
        if !loginRequired && session == nil && DemoData.enabled {
            session = AccountSession(username: "演示账户", email: "", method: "demo", at: Date())
        }
    }

    var isLoggedIn: Bool { session != nil }
    var displayName: String { session?.username ?? "" }

    /// alert：登录通知邮件（网页版的 login_alert；注册走 welcome，不发这封）
    func signIn(username: String, email: String, method: String, alert: Bool = true) {
        let s = AccountSession(username: username, email: email.lowercased(), method: method, at: Date())
        if let d = try? JSONEncoder().encode(s) { Keychain.set(d, account: "session") }
        // 光学配对的设备令牌只认它自己的账户：换了账户，上一个账户的令牌作废（不然扫码批准出去的是上一个账户）
        PairService.keepDevice(onlyFor: username)
        session = s
        // 邮箱 → 用户名的映射只在注册 / 改邮箱时写过，老账户查不到：任意一次成功登录后补写一次（与网页版一致）。
        // 写成了才记下来（以前先记：账号中心开了 STRICT_AUTH 时扫码登录那一次没带识别代码、401，之后就再也不补了）
        let mapKey = "cuven_emailmap_\(username)"
        let lower = email.lowercased()
        if !email.isEmpty, UserDefaults.standard.string(forKey: mapKey) != lower {
            Task {
                if await AccountAPI.putEmailMap(email, username: username) { UserDefaults.standard.set(lower, forKey: mapKey) }
            }
        }
        if alert { AccountAPI.notify("login_alert", username: username, method: method) }
        Task { await refreshAvatar() }
    }

    func signOut() {
        Keychain.delete(account: "session")
        PairService.keepDevice(onlyFor: nil)
        session = nil
        avatarURL = nil
        // 网页版 clearLogin：头像 / 设置的本机缓存一起清掉（存在本机的头像图也删掉）
        ProfileStore.shared.reset()
        AvatarCache.shared.clear()
    }

    /// 头像：先读网页版账户页那一份设置（user.cuven.online；本机缓存先上屏），读不到再退回 check.cuven.us 的老路由；
    /// 再把那张图拉下来存在本机（AvatarCache：用户要求「预先在设备上缓存头像，仅在确认没有头像时才回退成默认头像兜底」）。
    /// 设置一个都没读到（断网之类）不算确认：本机已有头像就不动；本机没有才按缓存里的设置试着拉一次
    func refreshAvatar(force: Bool = false) async {
        guard let name = session?.username else { return }
        let profile = ProfileStore.shared
        profile.bind(name)
        let avatars = AvatarCache.shared
        avatars.bind(name)
        let fallback = ProfileAPI.presetURL(ProfileAvatar.defaultID)
        guard profile.syncEnabled, session?.method != "demo" else {
            // 演示数据：本地画的头像（选了几号就是几号；自己的照片存不了，是默认的），不连网
            await avatars.refresh(profile.avatarURL ?? fallback, for: name, fallback: nil, force: force)
            return
        }
        if avatarURL == nil, let cached = profile.knownAvatarURL { avatarURL = cached }
        var confirmed: URL?
        if await profile.refreshSettings(for: name) {
            confirmed = profile.avatarURL
        } else {
            confirmed = await AccountAPI.avatarURL(name)
        }
        guard session?.username == name else { return }
        if let confirmed { avatarURL = confirmed }
        guard let target = confirmed ?? (avatars.avatar(for: name) == nil ? avatarURL : nil) else { return }
        await avatars.refresh(target, for: name, fallback: fallback, force: force)
    }

    /// 账户页换了头像：主页右上、账户页头部跟着换
    func applyAvatar(_ url: URL?) {
        avatarURL = url
    }

    // MARK: 账户页改了电子邮件 / 姓名（账户页移植（网页版））

    /// 改了电子邮件：钥匙串里的登录状态、面容 ID 快速登录存的那一份、登录用的「邮箱 → 用户名」对照（check.cuven.us）都换成新的
    func updateEmail(_ raw: String) {
        guard var s = session else { return }
        let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !email.isEmpty, email != s.email else { return }
        s.email = email
        persist(s)
        let name = s.username
        // 邮箱映射写成功了才记「写过了」（失败的话下次登录再补）
        Task { if await AccountAPI.putEmailMap(email, username: name) { UserDefaults.standard.set(email, forKey: "cuven_emailmap_\(name)") } }
    }

    /// 改了姓名：登录状态换成新姓名；本机的面容 ID 快速登录是旧姓名的，关掉（网页版：改名后旧的面容数据清除、要重新录入）；
    /// 登录用的「邮箱 → 用户名」对照指到新姓名
    func applyRename(to newName: String) {
        guard var s = session, !newName.isEmpty, s.username != newName else { return }
        let old = s.username
        s.username = newName
        AvatarCache.shared.rename(from: old, to: newName)
        if faceIDUser == old { disableFaceID() }
        persist(s)
        UserDefaults.standard.removeObject(forKey: "cuven_emailmap_\(old)")
        let email = s.email
        if !email.isEmpty {
            Task { if await AccountAPI.putEmailMap(email, username: newName) { UserDefaults.standard.set(email, forKey: "cuven_emailmap_\(newName)") } }
        }
        Task { await refreshAvatar() }
    }

    /// 写回钥匙串；本机为这个账户开着面容 ID 快速登录时，受保护的那一份也换掉（写入不用验面容；写不进去就关掉，免得登录时拿到旧的）
    private func persist(_ s: AccountSession) {
        guard let d = try? JSONEncoder().encode(s) else { return }
        Keychain.set(d, account: "session")
        session = s
        if faceIDUser == s.username, !Keychain.set(d, account: "faceid", biometric: true) { disableFaceID() }
    }

    // MARK: 面容 ID 快速登录

    var biometryAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .touchID: return "触控 ID"
        case .opticID: return "光学 ID"
        default: return "面容 ID"
        }
    }

    /// 开启：先验一次生物识别，再把账户写进受生物识别保护的钥匙串项（登录流程里身份还没写进钥匙串时传进来）
    @discardableResult
    func enableFaceID(for pending: AccountSession? = nil) async -> BiometricOutcome {
        guard let s = pending ?? session else { return .unavailable }
        let ctx = LAContext()
        do {
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                               localizedReason: "开启后，下次轻点一下即可登录 Cuven max") else { return .failed }
        } catch {
            return Self.outcome(error)
        }
        guard let d = try? JSONEncoder().encode(s), Keychain.set(d, account: "faceid", biometric: true) else { return .unavailable }
        faceIDUser = s.username
        UserDefaults.standard.set(s.username, forKey: "cuven_faceid_user")
        return .ok
    }

    func disableFaceID() {
        Keychain.delete(account: "faceid")
        faceIDUser = nil
        UserDefaults.standard.removeObject(forKey: "cuven_faceid_user")
    }

    /// 面容 ID 快速登录：验过以后从受保护的钥匙串项里取出账户。这里不写登录状态——
    /// 登录页先放完成功的那一段（和网页版一样），最后一步才 signIn
    func faceIDSession() async -> (session: AccountSession?, outcome: BiometricOutcome) {
        let ctx = LAContext()
        ctx.localizedReason = "登录 Cuven max"
        do {
            guard try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                               localizedReason: "登录 Cuven max") else { return (nil, .failed) }
        } catch {
            return (nil, Self.outcome(error))
        }
        guard let d = Keychain.get(account: "faceid", context: ctx),
              let s = try? JSONDecoder().decode(AccountSession.self, from: d) else { return (nil, .unavailable) }
        return (s, .ok)
    }

    /// 系统的生物识别错误 → 登录页分开说的三种情况（网页版：NotAllowedError 是取消，其余是用不了）
    private static func outcome(_ error: Error) -> BiometricOutcome {
        guard let e = error as? LAError else { return .unavailable }
        switch e.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
        case .authenticationFailed: return .failed
        default: return .unavailable
        }
    }
}
