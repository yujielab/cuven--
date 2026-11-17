import Foundation
import LocalAuthentication
import Observation

// MARK: - 账户页移植（网页版）：头像、设置、电子邮件、更改姓名
//
// 和网页版账户页调的是同一组接口（登录仍走 check.cuven.us，见 Account.swift）：
//   https://user.cuven.online
//     GET  /settings/<姓名>      { exists, settings: { avatar: { type: default | custom, id: 1…7 }, networkSpeed, trafficExpanded, familyExpanded } }
//     PUT  /settings/<姓名>      { avatar, networkSpeed, trafficExpanded, familyExpanded } → { settings }（四项每次都带上）
//     PUT  /user/<姓名>          请求体是图片本身（Content-Type 是图片类型，最大 5 MB）
//     头像图：/default/<1…7>、/user/<姓名>?v=<防缓存>
//     GET  /email/<姓名>         { exists, email }
//     PUT  /email/<姓名>         { email } → 409：这个地址已绑定别的账户
//     POST /rename               { from, to } → { ok }，409：新姓名被占用
//   https://verification.cuven.online
//     POST /send-code            { email } → { ok, message }
//     POST /verify-code          { email, code } → { ok, error: wrong_code | expired | too_many_attempts, attemptsLeft, message }
//   https://safety.cuven.online
//     GET  /check/<姓名>         { exists }
// 演示数据（-CuvenDemo YES）一律不连网：每个请求在发出去之前就返回失败，默认头像用本地画的图。

/// 和「使用」那边共用的两个本机设置（@AppStorage 用同样的键）：打开账户页时服务器的值为准，本机改了以后防抖 0.8 秒存回去
enum ProfileKeys {
    /// 网络速度 0…100，默认 80
    static let networkSpeed = "cuven_network_speed"
    /// 流量概览展开，默认 true
    static let trafficExpanded = "cuven_traffic_expanded"
}

/// 头像设置：默认头像（1…7，蜂窝正中的 4 号是默认）或自己上传的照片
struct ProfileAvatar: Codable, Equatable {
    var type: String
    var id: Int?

    static let defaultID = 4
    static let standard = ProfileAvatar(type: "default", id: defaultID)
    static let custom = ProfileAvatar(type: "custom", id: nil)
    static func preset(_ id: Int) -> ProfileAvatar { ProfileAvatar(type: "default", id: id) }

    var isCustom: Bool { type == "custom" }
    /// 默认头像的编号（不在 1…7 里的按 4 号）
    var presetID: Int {
        if let id, (1...7).contains(id) { return id }
        return Self.defaultID
    }

    init(type: String, id: Int?) {
        self.type = type
        self.id = id
    }

    private enum CodingKeys: String, CodingKey { case type, id }

    /// 宽松解码：编号可能是数字，也可能是字符串
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? "default"
        if let n = try? c.decode(Int.self, forKey: .id) {
            id = n
        } else if let d = try? c.decode(Double.self, forKey: .id) {
            id = Int(exactly: d.rounded())
        } else if let s = try? c.decode(String.self, forKey: .id) {
            id = Int(s)
        } else {
            id = nil
        }
    }

    /// 和网页版一样：自己的照片只写 type，默认头像带编号
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if !isCustom { try c.encode(presetID, forKey: .id) }
    }
}

/// 账户设置（网页版 settings.json）。familyExpanded 是网页版家庭卡的展开状态：iOS 没有这张卡，读到什么原样写回去
struct ProfileSettings: Codable, Equatable {
    var avatar: ProfileAvatar
    var networkSpeed: Int
    var trafficExpanded: Bool
    var familyExpanded: Bool

    /// 服务器上还没有这份设置时（网页版同一组默认值）
    static let defaults = ProfileSettings(avatar: .standard, networkSpeed: 80, trafficExpanded: true, familyExpanded: true)

    init(avatar: ProfileAvatar, networkSpeed: Int, trafficExpanded: Bool, familyExpanded: Bool) {
        self.avatar = avatar
        self.networkSpeed = networkSpeed
        self.trafficExpanded = trafficExpanded
        self.familyExpanded = familyExpanded
    }

    /// 宽松解码：缺的项用默认值，网络速度夹在 0…100
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        avatar = (try? c.decode(ProfileAvatar.self, forKey: .avatar)) ?? .standard
        if let n = try? c.decode(Double.self, forKey: .networkSpeed), n.isFinite {
            networkSpeed = Int(max(0, min(100, n.rounded())))
        } else {
            networkSpeed = 80
        }
        trafficExpanded = (try? c.decode(Bool.self, forKey: .trafficExpanded)) ?? true
        familyExpanded = (try? c.decode(Bool.self, forKey: .familyExpanded)) ?? true
    }
}

// MARK: - 接口

enum ProfileAPI {
    static let userBase = "https://user.cuven.online"
    static let verificationBase = "https://verification.cuven.online"
    static let safetyBase = "https://safety.cuven.online"
    /// 上传的照片最大 5 MB（网页版 MAX_UPLOAD_BYTES）
    static let maxUpload = 5 * 1024 * 1024

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private static func url(_ base: String, _ path: String) -> URL? { URL(string: base + path) }
    private static func name(_ s: String) -> String { AccountAPI.component(s) }

    /// 演示数据：不发请求，直接当作连不上（状态码 0）
    private static func get(_ url: URL?) async -> (Int, Data?) {
        guard !DemoData.enabled, let url else { return (0, nil) }
        guard let (data, resp) = try? await session.data(from: url) else { return (0, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func send(_ method: String, _ url: URL?, body: Data?, type: String = "application/json") async -> (Int, Data?) {
        guard !DemoData.enabled, let url else { return (0, nil) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await session.data(for: req) else { return (0, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func json<T: Encodable>(_ v: T) -> Data? { try? JSONEncoder().encode(v) }

    // MARK: 头像图

    /// 默认头像（演示数据用本地画的图，不连网）
    static func presetURL(_ id: Int) -> URL? {
        let n = (1...7).contains(id) ? id : ProfileAvatar.defaultID
        if DemoData.enabled { return URL(string: "demo://face/\(n)") }
        return url(userBase, "/default/\(n)")
    }

    /// 自己上传的照片（bust：换了照片以后换一个，图片缓存才会重新取）
    static func customURL(_ username: String, bust: Int) -> URL? {
        guard !DemoData.enabled else { return nil }
        return url(userBase, "/user/" + name(username) + "?v=\(bust)")
    }

    // MARK: 设置

    /// nil = 没读到（网络错误 / 不是 2xx / 内容不对）：留着缓存里的；exists 为 false：网页版的默认值
    static func settings(_ username: String) async -> ProfileSettings? {
        struct Reply: Decodable { var exists: Bool?; var settings: ProfileSettings? }
        let (code, data) = await get(url(userBase, "/settings/" + name(username)))
        guard (200..<300).contains(code), let data,
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        if reply.exists == true, let s = reply.settings { return s }
        return .defaults
    }

    /// 存设置：成功时返回服务器写下的那一份（没带回来就是发出去的那一份）
    static func saveSettings(_ username: String, _ s: ProfileSettings) async -> (code: Int, settings: ProfileSettings?) {
        struct Reply: Decodable { var settings: ProfileSettings? }
        let (code, data) = await send("PUT", url(userBase, "/settings/" + name(username)), body: json(s))
        guard (200..<300).contains(code) else { return (code, nil) }
        let reply = data.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) }
        return (code, reply?.settings ?? s)
    }

    /// 上传头像照片（JPEG），返回状态码（0 = 网络错误）
    static func uploadAvatar(_ username: String, jpeg: Data) async -> Int {
        guard jpeg.count <= maxUpload else { return 413 }
        let (code, _) = await send("PUT", url(userBase, "/user/" + name(username)), body: jpeg, type: "image/jpeg")
        return code
    }

    // MARK: 电子邮件

    enum EmailLookup { case found(String), missing, failed }

    static func email(_ username: String) async -> EmailLookup {
        struct Reply: Decodable { var exists: Bool?; var email: String? }
        let (code, data) = await get(url(userBase, "/email/" + name(username)))
        guard (200..<300).contains(code), let data,
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return .failed }
        if reply.exists == true, let e = reply.email?.trimmingCharacters(in: .whitespaces), !e.isEmpty { return .found(e) }
        return reply.exists == false ? .missing : .failed
    }

    /// 写电子邮件，返回状态码（409 = 已绑定别的账户，0 = 网络错误）
    static func putEmail(_ username: String, _ email: String) async -> Int {
        struct Body: Encodable { var email: String }
        let (code, _) = await send("PUT", url(userBase, "/email/" + name(username)), body: json(Body(email: email)))
        return code
    }

    // MARK: 验证码（与网页版 callSendCode / callVerifyCode 同样处理：不是 2xx 也先读回复里的说明）

    private static func codeReply(_ code: Int, _ data: Data?) -> AccountAPI.CodeReply {
        let offline = AccountAPI.CodeReply(ok: false, error: "network",
                                           message: DemoData.enabled ? "演示模式下不连接账户服务" : "网络连接异常", attemptsLeft: nil)
        guard code > 0 else { return offline }
        let parsed = data.flatMap { try? JSONDecoder().decode(AccountAPI.CodeReply.self, from: $0) }
        if (200..<300).contains(code) { return parsed ?? offline }
        return parsed ?? AccountAPI.CodeReply(ok: false, error: "http_\(code)", message: "服务器响应异常", attemptsLeft: nil)
    }

    static func sendCode(_ email: String) async -> AccountAPI.CodeReply {
        struct Body: Encodable { var email: String }
        let (code, data) = await send("POST", url(verificationBase, "/send-code"), body: json(Body(email: email)))
        return codeReply(code, data)
    }

    static func verifyCode(_ email: String, code: String) async -> AccountAPI.CodeReply {
        struct Body: Encodable { var email: String; var code: String }
        let (status, data) = await send("POST", url(verificationBase, "/verify-code"), body: json(Body(email: email, code: code)))
        return codeReply(status, data)
    }

    // MARK: 姓名

    enum NameCheck { case taken, available, invalid, network }

    /// 新姓名有没有人用（网页版不看状态码，只看回复里的 exists）
    static func checkName(_ candidate: String) async -> NameCheck {
        struct Reply: Decodable { var exists: Bool? }
        let (code, data) = await get(url(safetyBase, "/check/" + name(candidate)))
        guard code > 0 else { return .network }
        guard let data, let reply = try? JSONDecoder().decode(Reply.self, from: data), let exists = reply.exists else { return .invalid }
        return exists ? .taken : .available
    }

    enum RenameResult { case ok, taken, failed(String?) }

    /// 改姓名：服务器把头像、设置、电子邮件迁到新姓名，并清掉旧的面容数据
    static func rename(from: String, to: String) async -> RenameResult {
        struct Body: Encodable { var from: String; var to: String }
        struct Reply: Decodable { var ok: Bool?; var message: String?; var error: String? }
        let (code, data) = await send("POST", url(userBase, "/rename"), body: json(Body(from: from, to: to)))
        let reply = data.flatMap { try? JSONDecoder().decode(Reply.self, from: $0) }
        if reply?.ok == true { return .ok }
        if code == 409 { return .taken }
        return .failed(reply?.message ?? reply?.error)
    }
}

// MARK: - 身份验证（更改姓名 / 重设登录面容前）

enum IdentityCheck {
    /// 本机的面容 ID / 触控 ID（网页版用的是本机通行密钥，iOS 直接用系统的生物识别）
    @MainActor
    static func biometric(reason: String) async -> BiometricOutcome {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return .unavailable }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return ok ? .ok : .failed
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: return .cancelled
            case .authenticationFailed: return .failed
            default: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }
}

// MARK: - 账户资料（头像、设置、电子邮件）

/// 本机缓存（网页版 cuven_avatar_cache_v1：30 天，按姓名）：打开账户页、启动时先用它上屏，后台再拉
private struct ProfileCache: Codable {
    var username: String
    var settings: ProfileSettings
    var bust: Int
    var email: String?
    var at: Date
}

@MainActor
@Observable
final class ProfileStore {
    /// 全 App 一份：主页右上的头像（AccountStore.refreshAvatar）和账户页读的是同一份
    static let shared = ProfileStore()

    private static let cacheKey = "cuven_profile_cache_v1"
    private static let cacheTTL: TimeInterval = 30 * 86400

    /// 绑定的账户（空 = 没登录）
    private(set) var username = ""
    private(set) var settings = ProfileSettings.defaults
    /// 自己上传的照片的防缓存号（上传那一刻的秒数）
    private(set) var avatarBust = 0
    /// 电子邮件（服务器为准）；nil = 还不知道
    private(set) var email: String?
    /// 第一次拿到资料（缓存或服务器）之前是 false：个人资料卡显示骨架
    private(set) var loaded = false
    /// settings 是真拿到的（缓存或服务器），不是默认值：没拿到之前不往回写，免得把服务器上的头像盖成默认的
    private(set) var known = false

    @ObservationIgnored private var settingsTask: Task<Bool, Never>?
    @ObservationIgnored private var settingsAt: Date?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveGeneration = 0
    @ObservationIgnored private var syncedSpeed: Int?
    @ObservationIgnored private var syncedTraffic: Bool?

    /// 演示数据、没登录：只在本机，不连网
    var syncEnabled: Bool { !DemoData.enabled && !username.isEmpty }

    /// 现在的头像图（自己的照片按小时换一次防缓存号；刚上传的用上传那一刻）
    var avatarURL: URL? {
        let a = settings.avatar
        guard a.isCustom else { return ProfileAPI.presetURL(a.presetID) }
        guard syncEnabled else { return ProfileAPI.presetURL(ProfileAvatar.defaultID) }
        let hour = Int(Date().timeIntervalSince1970 / 3600) * 3600
        return ProfileAPI.customURL(username, bust: max(avatarBust, hour))
    }

    /// 真拿到过设置时的头像（启动时缓存先上屏用；没拿到过是 nil，不先闪一张默认头像）
    var knownAvatarURL: URL? { known ? avatarURL : nil }

    /// 本机那两个共用设置现在的值
    var localSpeed: Int { min(100, max(0, (UserDefaults.standard.object(forKey: ProfileKeys.networkSpeed) as? Int) ?? 80)) }
    var localTraffic: Bool { (UserDefaults.standard.object(forKey: ProfileKeys.trafficExpanded) as? Bool) ?? true }

    // MARK: 绑定账户、载入

    /// 换了账户（或第一次）：清掉上一位的，读这一位的本机缓存
    func bind(_ name: String) {
        guard name != username else { return }
        saveTask?.cancel()
        saveTask = nil
        settingsTask = nil
        settingsAt = nil
        syncedSpeed = nil
        syncedTraffic = nil
        username = name
        settings = .defaults
        avatarBust = 0
        email = nil
        known = false
        loaded = false
        guard syncEnabled else {
            // 演示数据 / 没登录：本地占位，不出骨架
            loaded = true
            return
        }
        if let c = readCache(name) {
            settings = c.settings
            avatarBust = c.bust
            email = c.email
            known = true
            loaded = true
        }
    }

    /// 打开账户页：设置和电子邮件一起拉（网页版每次进账户屏都刷新）
    func load(for name: String, sessionEmail: String) async {
        bind(name)
        guard syncEnabled else {
            loaded = true
            return
        }
        let settingsFetch = Task { await self.refreshSettings(for: name) }
        await refreshEmail(for: name, fallback: sessionEmail)
        _ = await settingsFetch.value
        if username == name { loaded = true }
    }

    /// 拉设置（同时来的几处只发一次；15 秒内拉过就不再拉）。成功返回 true
    @discardableResult
    func refreshSettings(for name: String) async -> Bool {
        guard syncEnabled, name == username else { return false }
        if let running = settingsTask { return await running.value }
        if let at = settingsAt, Date().timeIntervalSince(at) < 15 { return true }
        let task = Task<Bool, Never> { [weak self] in
            guard let fetched = await ProfileAPI.settings(name) else { return false }
            guard let self, self.username == name else { return false }
            self.applyServer(fetched)
            return true
        }
        settingsTask = task
        let ok = await task.value
        if username == name {
            settingsTask = nil
            if ok { settingsAt = Date() }
        }
        return ok
    }

    /// 服务器的设置为准；本机还有没存上去的改动（防抖中）时，那两个共用设置不盖
    private func applyServer(_ s: ProfileSettings) {
        settings = s
        known = true
        if saveTask == nil {
            syncedSpeed = s.networkSpeed
            syncedTraffic = s.trafficExpanded
            if localSpeed != s.networkSpeed { UserDefaults.standard.set(s.networkSpeed, forKey: ProfileKeys.networkSpeed) }
            if localTraffic != s.trafficExpanded { UserDefaults.standard.set(s.trafficExpanded, forKey: ProfileKeys.trafficExpanded) }
        }
        writeCache()
    }

    /// 电子邮件：服务器为准；服务器上没有、本机（登录时的）有 → 补写上去（网页版的历史迁移，失败不管）
    private func refreshEmail(for name: String, fallback: String) async {
        let result = await ProfileAPI.email(name)
        guard username == name else { return }
        switch result {
        case .found(let e):
            email = e
            writeCache()
        case .missing:
            let local = fallback.trimmingCharacters(in: .whitespaces)
            if Self.isEmail(local) {
                email = local
                Task { _ = await ProfileAPI.putEmail(name, local) }
            } else {
                email = ""
            }
            writeCache()
        case .failed:
            if email == nil, !fallback.isEmpty { email = fallback }
        }
    }

    // MARK: 存设置

    /// 那两个共用设置变了（网络速度滑块、流量概览展开）：0.8 秒内不再变才存
    func scheduleSave() {
        guard syncEnabled else { return }
        saveTask?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.flushSettings()
            if self.saveGeneration == generation { self.saveTask = nil }
        }
    }

    private func flushSettings() async {
        let name = username
        guard syncEnabled else { return }
        // 还没拿到过服务器的设置：先拉一次，拿不到就不写（不然头像会被写成默认的）
        if !known { await refreshSettings(for: name) }
        guard known, username == name else { return }
        guard localSpeed != syncedSpeed || localTraffic != syncedTraffic else { return }
        let body = outgoing(avatar: settings.avatar)
        let (_, saved) = await ProfileAPI.saveSettings(name, body)
        guard let saved, username == name else { return }
        settings = saved
        syncedSpeed = body.networkSpeed
        syncedTraffic = body.trafficExpanded
        settingsAt = Date()
        writeCache()
    }

    /// 发出去的设置：头像 + 本机的两个共用设置 + 读到的家庭卡状态（四项都带上）
    private func outgoing(avatar: ProfileAvatar) -> ProfileSettings {
        ProfileSettings(avatar: avatar, networkSpeed: localSpeed, trafficExpanded: localTraffic,
                        familyExpanded: settings.familyExpanded)
    }

    // MARK: 头像

    enum AvatarChoice { case preset(Int), photo(Data) }

    /// 存头像：照片先上传，再写设置。返回出错的说明（网页版的文案），nil = 成功。
    /// 演示数据 / 没登录：只在本机生效（网页版：自己的照片存不了，退回默认头像）
    func saveAvatar(_ choice: AvatarChoice) async -> String? {
        let name = username
        guard syncEnabled else {
            if case .preset(let id) = choice { settings.avatar = .preset(id) } else { settings.avatar = .standard }
            return nil
        }
        let avatar: ProfileAvatar
        switch choice {
        case .preset(let id):
            avatar = .preset(id)
        case .photo(let jpeg):
            let code = await ProfileAPI.uploadAvatar(name, jpeg: jpeg)
            guard (200..<300).contains(code) else {
                return code == 0 ? "未能保存，请再试一次" : "照片上传失败 (\(code))"
            }
            avatar = .custom
        }
        let body = outgoing(avatar: avatar)
        let (code, saved) = await ProfileAPI.saveSettings(name, body)
        guard let saved else { return code == 0 ? "未能保存，请再试一次" : "设置未能保存 (\(code))" }
        guard username == name else { return nil }
        settings = saved
        if saved.avatar.isCustom { avatarBust = Int(Date().timeIntervalSince1970) }
        known = true
        syncedSpeed = body.networkSpeed
        syncedTraffic = body.trafficExpanded
        settingsAt = Date()
        writeCache()
        return nil
    }

    // MARK: 电子邮件、姓名、退出

    func applyEmail(_ e: String) {
        email = e.trimmingCharacters(in: .whitespaces)
        writeCache()
    }

    /// 改了姓名：头像、设置、电子邮件在服务器上已经跟过去了，这里换个名字接着用
    func applyRename(to newName: String) {
        guard !newName.isEmpty, newName != username else { return }
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        username = newName
        settingsTask = nil
        settingsAt = nil
        writeCache()
    }

    /// 退出登录（网页版 clearLogin：头像缓存一起清掉）
    func reset() {
        saveTask?.cancel()
        saveTask = nil
        settingsTask = nil
        settingsAt = nil
        syncedSpeed = nil
        syncedTraffic = nil
        username = ""
        settings = .defaults
        avatarBust = 0
        email = nil
        known = false
        loaded = false
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    // MARK: 缓存

    private func readCache(_ name: String) -> ProfileCache? {
        guard let d = UserDefaults.standard.data(forKey: Self.cacheKey),
              let c = try? JSONDecoder().decode(ProfileCache.self, from: d),
              c.username == name, Date().timeIntervalSince(c.at) < Self.cacheTTL else { return nil }
        return c
    }

    private func writeCache() {
        guard syncEnabled, known else { return }
        let c = ProfileCache(username: username, settings: settings, bust: avatarBust, email: email, at: Date())
        if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: Self.cacheKey) }
    }

    // MARK: 校验（与网页版同一条）

    nonisolated static func isEmail(_ s: String) -> Bool {
        s.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
    }

    /// 姓名：中日文、字母、数字、空格及 . - _，1–64 个字（网页版 NAME_RE；JS 的 \w 只是 ASCII，这里照写）
    nonisolated static func isValidName(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9_\\u4E00-\\u9FFF\\u3040-\\u30FF. \\-]{1,64}$", options: .regularExpression) != nil
    }
}
