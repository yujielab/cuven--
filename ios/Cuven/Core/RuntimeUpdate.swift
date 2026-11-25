import Foundation

// MARK: - 获取软件更新（用户要求：账户页「网络」「兼容性」两组各一颗「获取软件更新」，
//         热更新 Cuven Pass 的服务器和兼容性更好的组件，不用重装 App）
//
// 一份运行时配置，从 stream Worker 的 /api/app/runtime 取（Stream_v25.js 的 handleAppRuntime；
// 在 Worker 变量 APP_RUNTIME 里改就能下发，不用重新部署代码）：
//   · pass.nodes：Cuven Pass Pro 的加速节点，按优先顺序。PassPro 检测时从第一个开始试，用第一个通的；
//     只认 cuven.us / cuven.online 下面的主机名（下发错了也不会把影片送去别处）
//   · compat：改进兼容性改「标记」时用的上限（HEVC / 杜比视界的 level、分辨率、码率、帧率），按安全范围收住
// 拿到就生效、存在本机，下次启动直接用；没取过或取不到，用 App 里自带的那份（和以前写死的值一样）。
// 按「获取软件更新」时去取；账户页打开时，离上次取超过一天也会悄悄取一次。

/// 服务器下发的那一份
struct RuntimeConfig: Codable, Equatable {
    var version: Int
    var pass: PassNodes?
    var compat: CompatRules?

    struct PassNodes: Codable, Equatable {
        /// 加速节点的主机名，按优先顺序
        var nodes: [String]
    }

    struct CompatRules: Codable, Equatable {
        var maxHevcLevel: Int?
        var maxDvLevel: Int?
        var maxWidth: Int?
        var maxBandwidth: Int?
        var maxFrameRate: Double?
    }

    /// App 里自带的那份（和以前写死在 PassPro / CompatHLS 里的值一样）
    static let builtIn = RuntimeConfig(
        version: 1,
        pass: PassNodes(nodes: ["pass.cuven.us"]),
        compat: CompatRules(maxHevcLevel: 153, maxDvLevel: 7, maxWidth: 1920, maxBandwidth: 40_000_000, maxFrameRate: 60))
}

/// 兼容性组件眼下用的上限。播放器的本机代理（PrecacheServer）在后台线程上读，所以单独一个加锁的小盒子，不放在主线程上
final class RuntimeRules: @unchecked Sendable {
    static let shared = RuntimeRules()

    struct Limits: Equatable {
        /// HEVC 的 level_idc 上限（153 = 5.1）
        var maxHevcLevel = 153
        /// 杜比视界的 level 上限（苹果规范是 7）
        var maxDvLevel = 7
        /// 增强级：分辨率写成不超过这么宽
        var maxWidth = 1920
        /// 增强级：码率写成不超过这么多（bps）
        var maxBandwidth = 40_000_000
        /// 增强级：帧率写成不超过这么多
        var maxFrameRate = 60.0
    }

    private let lock = NSLock()
    private var limits = Limits()

    var current: Limits {
        lock.lock()
        defer { lock.unlock() }
        return limits
    }

    /// 下发的值按安全范围收住：配错了也不至于把放得了的片子改坏
    func apply(_ c: RuntimeConfig.CompatRules?) {
        var l = Limits()
        if let c {
            if let v = c.maxHevcLevel { l.maxHevcLevel = min(186, max(120, v)) }
            if let v = c.maxDvLevel { l.maxDvLevel = min(13, max(4, v)) }
            if let v = c.maxWidth { l.maxWidth = min(3840, max(1280, v)) }
            if let v = c.maxBandwidth { l.maxBandwidth = min(120_000_000, max(8_000_000, v)) }
            if let v = c.maxFrameRate { l.maxFrameRate = min(120, max(24, v)) }
        }
        lock.lock()
        limits = l
        lock.unlock()
    }
}

@MainActor
@Observable
final class RuntimeUpdate {
    static let shared = RuntimeUpdate()

    enum Phase: Equatable {
        case idle
        case checking
        /// 取到了新的一份，已经生效
        case updated(version: Int)
        /// 取到了，和本机的一样
        case current(version: Int)
        /// 取不到（没网、Worker 还没这个接口）
        case failed
    }

    private(set) var config: RuntimeConfig
    private(set) var phase: Phase = .idle

    private static let cacheKey = "cuven_runtime_config"
    private static let checkedKey = "cuven_runtime_checked"

    private init() {
        var c = RuntimeConfig.builtIn
        if let d = UserDefaults.standard.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode(RuntimeConfig.self, from: d), saved.version >= 1 {
            c = saved
        }
        config = c
        RuntimeRules.shared.apply(c.compat)
    }

    /// Cuven Pass Pro 的节点（按顺序；下发的不能用就是自带的）
    var passNodes: [String] {
        let nodes = (config.pass?.nodes ?? []).map { $0.lowercased() }.filter(Self.allowedHost)
        return nodes.isEmpty ? (RuntimeConfig.builtIn.pass?.nodes ?? ["pass.cuven.us"]) : nodes
    }

    /// 只认这两个域名下面的主机名（字母、数字、点、连字符）
    static func allowedHost(_ h: String) -> Bool {
        guard h.count <= 100, !h.isEmpty,
              h.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return false }
        return h == "cuven.us" || h.hasSuffix(".cuven.us") || h == "cuven.online" || h.hasSuffix(".cuven.online")
    }

    /// 「获取软件更新」：去取一份，有变化就生效
    func check() async {
        guard phase != .checking else { return }
        phase = .checking
        guard let fresh = await Self.fetch() else {
            phase = .failed
            return
        }
        UserDefaults.standard.set(Date(), forKey: Self.checkedKey)
        if fresh != config {
            adopt(fresh)
            phase = .updated(version: fresh.version)
        } else {
            phase = .current(version: fresh.version)
        }
    }

    /// 账户页打开时：离上次取超过一天就悄悄取一次（取不到不提示）
    func checkIfStale() async {
        let last = UserDefaults.standard.object(forKey: Self.checkedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400, phase != .checking, !DemoData.enabled else { return }
        guard let fresh = await Self.fetch() else { return }
        UserDefaults.standard.set(Date(), forKey: Self.checkedKey)
        if fresh != config { adopt(fresh) }
    }

    private func adopt(_ c: RuntimeConfig) {
        let nodesChanged = c.pass != config.pass
        config = c
        if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: Self.cacheKey) }
        RuntimeRules.shared.apply(c.compat)
        if nodesChanged { PassPro.shared.nodesChanged() }
        Perf.log("runtime config v\(c.version): \(passNodes.count) pass node(s)")
    }

    private static func fetch() async -> RuntimeConfig? {
        guard let url = URL(string: APIClient.base + "/api/app/runtime") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "GET"
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let c = try? JSONDecoder().decode(RuntimeConfig.self, from: data), c.version >= 1 else { return nil }
        return c
    }
}
