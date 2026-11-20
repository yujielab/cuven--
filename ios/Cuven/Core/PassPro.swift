import Foundation

// MARK: - Cuven Pass Pro（账户页「Cuven Pass Pro」开关）
//
// 用户要求：在设置中允许启用 Cuven Pass Pro 服务，让 Worker → VPS → 用户，提高速度。
// 开着时，影片（HLS 主列表 / 二级列表 / 分段、直链）不再直接从 Cloudflare 边缘拿，而是走加速节点 pass.cuven.us：
// 一台 VPS 上的 nginx，只转发影片、把分段缓存在本机磁盘（部署见仓库 vps/pass-pro/）。签名只盖路径不盖主机名，
// 同一条地址换成节点的主机名照样有效，不用重新签。资料、接口（小请求）照旧直连 Worker。
//
// 稳：
// · 播放前确认节点能用（5 分钟内确认过就不再问；没确认过最多等 2.5 秒）——问的是节点转发到 Worker 的那一条
//   （/api/edge/ping?b=0），节点自己活着、到 Worker 不通也算不能用
// · 不能用就走普通线路；播放中节点出错，播放器从当前位置改走普通线路接着放（Player.swift），节点 10 分钟内不再用
// · 演示数据不走节点

@MainActor
@Observable
final class PassPro {
    static let shared = PassPro()

    /// 加速节点（VPS，DNS 只解析、不经 Cloudflare 代理）
    static let host = "pass.cuven.us"
    static var origin: String { "https://" + host }
    private static let enabledKey = "cuven_pass_pro"

    enum State: Equatable {
        case off
        case checking
        case ready(rttMs: Int)
        case down
    }

    struct Speed: Equatable {
        var direct: Double?
        var pass: Double?
        var at: Date
    }

    private(set) var enabled: Bool = UserDefaults.standard.bool(forKey: PassPro.enabledKey)

    /// 账户页的开关：存在本机；打开就马上检测一次节点
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            downUntil = nil
            Task { await check() }
        } else {
            state = .off
        }
    }

    private(set) var state: State = .off
    private(set) var speed: Speed?
    private(set) var testing = false
    @ObservationIgnored private var lastOK: Date?
    @ObservationIgnored private var downUntil: Date?

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private init() {
        if enabled { state = .checking; Task { await check() } }
    }

    /// 播放用哪个地址：开着、节点能用 → 节点；否则普通线路（Worker 直连）
    func mediaBase() async -> (base: String, viaPass: Bool) {
        guard enabled, !DemoData.enabled else { return (APIClient.base, false) }
        if let u = downUntil, u > Date() { return (APIClient.base, false) }
        if let ok = lastOK, Date().timeIntervalSince(ok) < 300 { return (Self.origin, true) }
        return await probe(timeout: 2.5) != nil ? (Self.origin, true) : (APIClient.base, false)
    }

    /// 播放中节点出错：10 分钟内不再用（这期间走普通线路），之后再试
    func markDown() {
        lastOK = nil
        downUntil = Date().addingTimeInterval(600)
        if enabled { state = .down }
    }

    /// 账户页：重新看一眼节点
    func check() async {
        guard enabled else { state = .off; return }
        state = .checking
        if let rtt = await probe(timeout: 4) {
            downUntil = nil
            state = .ready(rttMs: rtt)
        } else {
            state = .down
        }
    }

    /// 测速对比：普通线路和 Pass Pro 各测一次（同一个探针、同样的大小；按流量计费的网络最多 1 MB，别的最多 4 MB）
    func compare() async {
        guard !testing, !DemoData.enabled else { return }
        testing = true
        defer { testing = false }
        let cap = NetworkAuto.shared.metered ? 1 << 20 : 4 << 20
        let direct = await NetworkProbe.run(maxBytes: cap, base: APIClient.base)
        let pass = await NetworkProbe.run(maxBytes: cap, base: Self.origin)
        speed = Speed(direct: direct.mbps, pass: pass.mbps, at: Date())
        if pass.mbps != nil { lastOK = Date(); downUntil = nil; if enabled, let r = pass.rttMs { state = .ready(rttMs: Int(r.rounded())) } }
    }

    /// 经节点转发到 Worker 的那一条通不通：通了回延迟（毫秒）
    private func probe(timeout: TimeInterval) async -> Int? {
        guard let url = URL(string: Self.origin + "/api/edge/ping?b=0") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let t0 = Date()
        guard let (_, resp) = try? await Self.session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            lastOK = nil
            return nil
        }
        lastOK = Date()
        return max(1, Int(Date().timeIntervalSince(t0) * 1000))
    }
}
