import Foundation

// MARK: - Cuven Pass Pro（全自动，不再有开关）
//
// 用户要求：在设置中允许启用 Cuven Pass Pro 服务，提高速度；后来要求「智能优选最快的 Cloudflare 边缘节点」；
// 再后来要求「移除 Cuven Pass Pro 开关和测速对比，智能调整是否开 Pass、自动管理网络」：
// 现在一直是自动的。普通线路（Worker 直连）本身就是候选之一，优选出来是它就走普通线路，是别的入口就走那个入口——
// 「开不开 Pass」由测出来的速度决定，用户不用管。换了网络（Wi‑Fi / 蜂窝 / 热点）或者结果超过 6 小时，后台自己重新优选。
// 影片（HLS 主列表 / 二级列表 / 分段、直链）走「优选出来的那个入口」：
//   · Cloudflare 边缘入口：绑到同一个 stream Worker 的几个主机名（Worker 变量 EDGE_HOSTS；DNS 里各自指向一批优选 IP /
//     优选域名，见 Stream_v25.js 开头「优选」那一节）。/api/edge 会把这几个列出来（当前这个排第一）；
//     「获取软件更新」下发的 pass.edges 也算；
//   · 加速节点（VPS 上的 nginx，只转发影片、把分段缓存在本机磁盘，部署见 vps/pass-pro/）：「获取软件更新」下发的 pass.nodes。
// 签名只盖路径不盖主机名，同一条地址换成哪个入口的主机名都有效，不用重新签。资料、接口（小请求）照旧直连 Worker。
//
// 怎么优选（像 CloudflareSpeedTest，但只测自家的几个入口）：
//   1. 延迟：所有候选同时发空探针（/api/edge/ping?b=0，经入口转到 Worker 的那一条），各取两次里快的那次，3 秒不回的不要；
//   2. 速度：延迟最低的三个，一个接一个真下一段（NetworkProbe：256 KB 起、按需加大；Wi‑Fi 最多 2 MB，按流量计费的网络最多 512 KB），
//      按 Mbps 比；差不到 8% 的算一样快，延迟低的胜；
//   3. 用赢的那个，记在本机：6 小时内、同一种网络（Wi‑Fi / 蜂窝 / 热点）直接用；过期或者换了网络，先照用、后台重新优选。
// 稳：
// · 播放前确认入口能用（5 分钟内确认过就不再问；没确认过最多等 2.5 秒）；不能用就走普通线路，后台重新优选
// · 播放中入口出错：播放器从当前位置改走普通线路接着放（Player.swift）；这个入口 10 分钟内不参加优选，马上从别的里重新选
// · 只认 cuven.us / cuven.online 下面的主机名（RuntimeUpdate.allowedHost）；演示数据不走这条

@MainActor
@Observable
final class PassPro {
    static let shared = PassPro()

    /// 现在用的入口（主机名，可能带端口）：优选出来的那个；还没优选过是普通线路（Worker 直连）
    private(set) var host: String = PassPro.defaultHost
    var origin: String { "https://" + host }
    private static let bestKey = "cuven_pass_best"
    /// 还没优选过时用的：普通线路（Worker 直连）——不先把影片送去一个没测过的节点
    nonisolated static let defaultHost = URL(string: APIClient.base)?.host?.lowercased() ?? "stream.cuven.online"

    enum State: Equatable {
        case off
        case checking
        case ready(rttMs: Int)
        case down
    }

    /// 存在本机的优选结果
    private struct Best: Codable {
        var host: String
        var network: String
        var at: Date
        var mbps: Double?
        var rtt: Int
    }

    private(set) var state: State = .off
    /// 赢的那个入口测出来的下载速度（账户页「加速节点」那一行写）
    private(set) var bestMbps: Double?
    @ObservationIgnored private var lastOK: Date?
    @ObservationIgnored private var downUntil: Date?
    @ObservationIgnored private var best: Best?
    /// 出过错的入口：到这个时刻之前不参加优选
    @ObservationIgnored private var badUntil: [String: Date] = [:]
    @ObservationIgnored private var optimizing: Task<Void, Never>?
    /// /api/edge 列出来的 Cloudflare 入口（一次会话里问一次就够，6 小时后再问）
    @ObservationIgnored private var edgeList: (hosts: [String], at: Date)?

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.bestKey), let b = try? JSONDecoder().decode(Best.self, from: d),
           RuntimeUpdate.allowedHost(b.host) {
            best = b
            host = b.host
            bestMbps = b.mbps
        }
        // 一开始就在后台优选一次（结果新的、同一种网络就不测）
        if isStale { startOptimizing() } else if let b = best { state = .ready(rttMs: b.rtt) }
    }

    /// 优选结果多久算旧（换了网络也算旧）
    private static let freshFor: TimeInterval = 6 * 3600

    /// 现在是哪一种网络（Wi‑Fi / 有线 / 蜂窝 / 别的，带不带计费）：优选结果按它分开记
    private var networkKey: String {
        guard let p = NetworkAuto.shared.currentPath else { return "unknown" }
        return "\(p.kind.rawValue)\(p.expensive ? "-metered" : "")"
    }

    private var isStale: Bool {
        guard let b = best else { return true }
        if Date().timeIntervalSince(b.at) > Self.freshFor { return true }
        let k = networkKey
        return k != "unknown" && b.network != k
    }

    /// Worker 直连的那个主机名（优选出来是它，就当普通线路用：出错时不必改道）
    private static let directHost: String? = defaultHost

    /// 播放用哪个地址：优选出来的入口能用就用它（是普通线路就是普通线路）；不能用走普通线路
    func mediaBase() async -> (base: String, viaPass: Bool) {
        guard !DemoData.enabled else { return (APIClient.base, false) }
        if let u = downUntil, u > Date() { return (APIClient.base, false) }
        // 优选结果旧了（6 小时、或者换了网络）：这一次先用着现在的，后台重新优选
        if isStale { startOptimizing() }
        if host.lowercased() == Self.directHost { return (APIClient.base, false) }
        if let ok = lastOK, Date().timeIntervalSince(ok) < 300 { return (origin, true) }
        if await EdgeProbe.ping(host, timeout: 2.5) != nil {
            lastOK = Date()
            return (origin, true)
        }
        // 现在这个入口不通：这一次走普通线路，后台从别的里重新选
        lastOK = nil
        badUntil[host] = Date().addingTimeInterval(600)
        startOptimizing()
        return (APIClient.base, false)
    }

    /// 播放中入口出错：这个入口 10 分钟内不参加优选；先走 1 分钟普通线路，同时从别的入口里重新选
    func markDown() {
        lastOK = nil
        badUntil[host] = Date().addingTimeInterval(600)
        downUntil = Date().addingTimeInterval(60)
        state = .down
        startOptimizing()
    }

    /// 马上优选一次
    func check() async {
        await optimize()
    }

    /// 网络变了（NetworkAuto 通知）：换了一种网络、或者结果旧了，等 2 秒（刚换过来常常还不稳）后台重新优选
    func networkChanged(online: Bool) {
        guard online, !DemoData.enabled, isStale, optimizing == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if self.isStale { self.startOptimizing() }
        }
    }

    /// 「获取软件更新」换了节点表：重新优选
    func nodesChanged() {
        best = nil
        lastOK = nil
        downUntil = nil
        startOptimizing()
    }

    private func startOptimizing() {
        guard optimizing == nil else { return }
        Task { await optimize() }
    }

    /// 同一时间只跑一轮：已经在跑就等它跑完
    private func optimize() async {
        if let running = optimizing {
            await running.value
            return
        }
        let t = Task { @MainActor in await self.runOptimize() }
        optimizing = t
        await t.value
        optimizing = nil
    }

    private func runOptimize() async {
        guard !DemoData.enabled else { return }
        // 已经有能用的入口时不把状态改成「正在检测」（账户页那一行不闪），只有第一次、或者不通了才显示
        if case .ready = state {} else { state = .checking }
        let hosts = await candidates()
        // 1. 延迟：同时问，每个两次取快的
        var rtts: [(host: String, rtt: Int)] = []
        await withTaskGroup(of: (String, Int?).self) { group in
            for h in hosts {
                group.addTask {
                    let a = await EdgeProbe.ping(h, timeout: 3)
                    guard a != nil else { return (h, nil) }
                    let b = await EdgeProbe.ping(h, timeout: 3)
                    return (h, [a, b].compactMap { $0 }.min())
                }
            }
            for await (h, r) in group {
                if let r { rtts.append((h, r)) }
            }
        }
        guard !rtts.isEmpty else {
            lastOK = nil
            state = .down
            return
        }
        rtts.sort { $0.rtt < $1.rtt }
        // 2. 速度：延迟最低的三个，一个接一个下（同时下会互相抢带宽，测不准）
        // 全自动以后每换一种网络都会测：测得省一点（Wi‑Fi 每个最多 1 MB，按流量计费的网络 256 KB）
        let cap = NetworkAuto.shared.metered ? 256 << 10 : 1 << 20
        var winner: (host: String, rtt: Int, mbps: Double?) = (rtts[0].host, rtts[0].rtt, nil)
        for c in rtts.prefix(3) {
            let r = await NetworkProbe.run(maxBytes: cap, base: "https://" + c.host)
            guard let m = r.mbps else { continue }
            let rtt = r.rttMs.map { Int($0.rounded()) } ?? c.rtt
            if let w = winner.mbps {
                // 快 8% 以上才算更快；差不到 8% 的看延迟
                if m > w * 1.08 || (m >= w * 0.92 && rtt < winner.rtt) { winner = (c.host, rtt, m) }
            } else {
                winner = (c.host, rtt, m)
            }
        }
        host = winner.host
        bestMbps = winner.mbps
        lastOK = Date()
        downUntil = nil
        state = .ready(rttMs: winner.rtt)
        let b = Best(host: winner.host, network: networkKey, at: Date(), mbps: winner.mbps, rtt: winner.rtt)
        best = b
        if let d = try? JSONEncoder().encode(b) { UserDefaults.standard.set(d, forKey: Self.bestKey) }
        Perf.log("pass optimize: \(rtts.count)/\(hosts.count) reachable, using \(winner.host) (\(winner.rtt) ms, \(winner.mbps.map { String(format: "%.1f", $0) } ?? "-") Mbps)")
    }

    /// 参加优选的入口：Worker 列出来的 Cloudflare 入口 + 下发的边缘入口 + 下发的加速节点（去重；最近出过错的先不要）
    private func candidates() async -> [String] {
        var out: [String] = []
        func add(_ raw: String) {
            let h = raw.lowercased()
            if RuntimeUpdate.allowedHost(h), !out.contains(h) { out.append(h) }
        }
        for h in await edgeHosts() { add(h) }
        for h in RuntimeUpdate.shared.passEdges { add(h) }
        for h in RuntimeUpdate.shared.passNodes { add(h) }
        let now = Date()
        let usable = out.filter { (badUntil[$0] ?? .distantPast) < now }
        // 全都出过错：还是都试一遍（总比一个都不试好）
        return usable.isEmpty ? out : usable
    }

    /// /api/edge 里的 hosts（Worker 变量 EDGE_HOSTS 配的那几个，当前这个排第一）；问不到就只有 Worker 直连那一个
    private func edgeHosts() async -> [String] {
        if let e = edgeList, Date().timeIntervalSince(e.at) < Self.freshFor { return e.hosts }
        let hosts = await EdgeProbe.edgeHosts() ?? Self.directHost.map { [$0] } ?? []
        edgeList = (hosts, Date())
        return hosts
    }
}

/// 入口探针：不在主线程上（优选时同时问好几个入口）
enum EdgeProbe {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// 经这个入口转到 Worker 的那一条通不通：通了回延迟（毫秒）
    static func ping(_ host: String, timeout: TimeInterval) async -> Int? {
        guard let url = URL(string: "https://" + host + "/api/edge/ping?b=0") else { return nil }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        let t0 = Date()
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return max(1, Int(Date().timeIntervalSince(t0) * 1000))
    }

    private struct EdgeInfo: Decodable {
        let hosts: [String]?
    }

    /// Worker 列出来的入口（/api/edge 的 hosts）
    static func edgeHosts() async -> [String]? {
        guard let url = URL(string: APIClient.base + "/api/edge") else { return nil }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let info = try? JSONDecoder().decode(EdgeInfo.self, from: data),
              let hosts = info.hosts, !hosts.isEmpty else { return nil }
        return hosts
    }
}
