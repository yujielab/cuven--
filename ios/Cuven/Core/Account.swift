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
//   头像：/default/<id>、/user/<用户名>
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

    var hasPass: Bool { !(pass?.hash.isEmpty ?? true) && !(pass?.salt.isEmpty ?? true) }

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
        guard let name = r.username else { return false }
        let (code, _) = await send("PUT", "/file/" + component("username_\(name).json"), json: r)
        return (200..<300).contains(code)
    }

    static func putEmailMap(_ email: String, username: String) async {
        struct Map: Encodable { var username: String; var created_at: String }
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        _ = await send("PUT", "/file/" + component("email_\(e).json"),
                       json: Map(username: username, created_at: ISO8601DateFormatter.cuven.string(from: Date())))
    }

    struct CodeReply: Decodable {
        var ok: Bool?
        var error: String?
        var message: String?
        var attemptsLeft: Int?
    }

    static func sendCode(_ email: String) async -> CodeReply? {
        struct Body: Encodable { var email: String }
        let (code, data) = await send("POST", "/send-code", json: Body(email: email))
        guard code > 0, let data else { return nil }
        return try? JSONDecoder().decode(CodeReply.self, from: data)
    }

    static func verifyCode(_ email: String, code: String) async -> CodeReply? {
        struct Body: Encodable { var email: String; var code: String }
        let (status, data) = await send("POST", "/verify-code", json: Body(email: email, code: code))
        guard status > 0, let data else { return nil }
        return try? JSONDecoder().decode(CodeReply.self, from: data)
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

    func signIn(username: String, email: String, method: String) {
        let s = AccountSession(username: username, email: email.lowercased(), method: method, at: Date())
        if let d = try? JSONEncoder().encode(s) { Keychain.set(d, account: "session") }
        session = s
        // 邮箱 → 用户名的映射只在注册 / 改邮箱时写过，老账户查不到：任意一次成功登录后补写一次（与网页版一致）
        let mapKey = "cuven_emailmap_\(username)"
        if !email.isEmpty, UserDefaults.standard.string(forKey: mapKey) != email.lowercased() {
            Task { await AccountAPI.putEmailMap(email, username: username) }
            UserDefaults.standard.set(email.lowercased(), forKey: mapKey)
        }
        AccountAPI.notify("login_alert", username: username, method: method)
        Task { await refreshAvatar() }
    }

    func signOut() {
        Keychain.delete(account: "session")
        session = nil
        avatarURL = nil
    }

    func refreshAvatar() async {
        guard let name = session?.username, session?.method != "demo" else { return }
        if let u = await AccountAPI.avatarURL(name) { avatarURL = u }
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

    /// 为当前账户开启：先验一次生物识别，再把账户写进受生物识别保护的钥匙串项
    func enableFaceID() async -> Bool {
        guard let s = session else { return false }
        let ctx = LAContext()
        guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "开启后，下次轻点一下即可登录 Cuven max")) == true,
              let d = try? JSONEncoder().encode(s), Keychain.set(d, account: "faceid", biometric: true) else { return false }
        faceIDUser = s.username
        UserDefaults.standard.set(s.username, forKey: "cuven_faceid_user")
        return true
    }

    func disableFaceID() {
        Keychain.delete(account: "faceid")
        faceIDUser = nil
        UserDefaults.standard.removeObject(forKey: "cuven_faceid_user")
    }

    /// 读受保护的钥匙串项会弹系统的面容 ID 验证；通过即登录
    func faceIDLogin() async -> Bool {
        let ctx = LAContext()
        ctx.localizedReason = "登录 Cuven max"
        guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "登录 Cuven max")) == true,
              let d = Keychain.get(account: "faceid", context: ctx),
              let s = try? JSONDecoder().decode(AccountSession.self, from: d) else { return false }
        signIn(username: s.username, email: s.email, method: "faceid")
        return true
    }
}
