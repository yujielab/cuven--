import Foundation
import Network
import UIKit

// MARK: - 网络速度「自动调整」（用户要求「添加自动调整按钮，自动检测网络情况和速度，匹配合适的百分比」）
//
// 账户页「网络速度」卡里一颗「开启」胶囊。开着时：
// · 网络情况：系统的 NWPathMonitor——连没连上、Wi‑Fi / 有线 / 蜂窝、是不是按流量计费（蜂窝、个人热点）、
//   是不是开着「低数据模式」；
// · 速度：打 Worker 的测速探针 /api/edge/ping（随机字节、不缓存；网页版「优选入口」测速用的同一个）——
//   先三次空请求量延迟（取最快的），再下载 256 KB 起、每级 ×4（按流量计费的最多 1 MB，别的最多 4 MB），
//   哪一级花了 2 秒以上就够准了；一级 8 秒还没下完，按「最多这么快」算。低数据模式、演示数据不测速；
// · 按下面的规则选百分比（percent），存在本机（NetworkSpeed.autoValueKey），不改手动设的那个数、不同步到账户；
// · 什么时候重测：按下开启时马上测；换了网络（类型、计费、低数据模式变了）等 2 秒再测；
//   回到 App 时上次测的超过半小时也重测。只在 App 在前台时测。
// 拖滑块（或旁白调）就是要自己定：自动关掉。按胶囊关掉时停在现在的数上（自动选的数变成手动设的，像关掉自动亮度）。

/// 网络情况（从 NWPath 抄出来的几样，可以存、可以比）
struct NetworkPath: Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case wifi, wired, cellular, other }
    var online: Bool
    var kind: Kind
    var expensive: Bool
    var constrained: Bool

    /// 按流量计费：蜂窝、个人热点（系统标的 isExpensive）
    var metered: Bool { expensive || kind == .cellular }

    /// 账户页那一行写的网络名
    var label: String {
        guard online else { return "未连接网络" }
        switch kind {
        case .wifi: return expensive ? "个人热点" : "Wi‑Fi"
        case .wired: return "有线网络"
        case .cellular: return "蜂窝网络"
        case .other: return expensive ? "按流量计费的网络" : "网络"
        }
    }
}

extension NetworkPath {
    init(_ p: NWPath) {
        online = p.status == .satisfied
        if p.usesInterfaceType(.wifi) { kind = .wifi }
        else if p.usesInterfaceType(.wiredEthernet) { kind = .wired }
        else if p.usesInterfaceType(.cellular) { kind = .cellular }
        else { kind = .other }
        expensive = p.isExpensive
        constrained = p.isConstrained
    }
}

/// 一次检测的结果
struct NetworkCheck: Codable, Equatable, Sendable {
    var path: NetworkPath
    /// 下载速度（Mbps）；没测（低数据模式、演示数据）或者没测出来：nil
    var mbps: Double?
    /// 延迟（毫秒）
    var rttMs: Double?
    var percent: Int
    var at: Date
    /// 演示数据：不连网，只按网络类型估
    var demo = false

    /// 账户页那一行：「Wi‑Fi · 86 Mbps」（延迟只用来挑百分比，不写给人看）
    var summary: String {
        var parts = [path.label]
        if path.constrained { parts.append("低数据模式") }
        if let mbps {
            parts.append(mbps < 10 ? String(format: "%.1f Mbps", mbps) : "\(Int(mbps.rounded())) Mbps")
        } else if demo {
            parts.append("演示数据不测速")
        } else if !path.constrained {
            parts.append("无法测速")
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class NetworkAuto {
    static let shared = NetworkAuto()

    enum Phase: Equatable { case idle, measuring, offline }

    private(set) var phase: Phase = .idle
    /// 最近一次检测（账户页那一行显示；存在本机）
    private(set) var last: NetworkCheck?
    /// 按「开启」以后测完的次数：账户页据此给一下成功触感（换网络时后台自己测的不震）
    private(set) var userRuns = 0

    private let monitor = NWPathMonitor()
    @ObservationIgnored private var path: NetworkPath?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?

    private static let lastKey = "cuven_network_speed_auto_last"
    /// 开着时多久重测一次（回到 App 时看）
    private static let staleAfter: TimeInterval = 30 * 60

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.lastKey), let c = try? JSONDecoder().decode(NetworkCheck.self, from: d) {
            last = c
        }
    }

    var enabled: Bool { NetworkSpeed.isAuto }
    /// 现在是不是按流量计费的网络（蜂窝、个人热点）：测速别下太多（Cuven Pass Pro 的测速对比也看它）
    var metered: Bool { path?.metered ?? false }

    /// 启动时调一次：开始看网络变化
    func start() {
        guard !started else { return }
        started = true
        // 在监视器自己的队列上调：先抄成 NetworkPath，再回主线程
        monitor.pathUpdateHandler = { @Sendable p in
            let info = NetworkPath(p)
            Task { @MainActor in NetworkAuto.shared.pathChanged(info) }
        }
        monitor.start(queue: DispatchQueue(label: "us.cuven.network-path", qos: .utility))
    }

    /// 回到 App：开着自动、上次测的超过半小时（或者网络和上次不一样），重测
    func appBecameActive() {
        start()
        guard enabled, let p = path, p.online, !fresh(for: p) else { return }
        schedule(after: 1)
    }

    /// 打开 / 关掉「自动调整」（账户页那颗胶囊）。打开就马上测一次；
    /// 关掉时 keepValue = true 停在现在的数上（自动选的数变成手动设的）
    func setEnabled(_ on: Bool, keepValue: Bool = true) {
        let d = UserDefaults.standard
        if !on {
            if keepValue, NetworkSpeed.isAuto, let n = d.object(forKey: NetworkSpeed.autoValueKey) as? NSNumber, n.intValue >= 0 {
                d.set(min(100, n.intValue), forKey: NetworkSpeed.key)
            }
            pending?.cancel()
            pending = nil
            task?.cancel()
            task = nil
            phase = .idle
        }
        d.set(on, forKey: NetworkSpeed.autoKey)
        if on { run(user: true) }
    }

    // MARK: 内部

    private func pathChanged(_ info: NetworkPath) {
        path = info
        guard enabled else { return }
        guard info.online else {
            if phase != .measuring { phase = .offline }
            return
        }
        if phase == .offline { phase = .idle }
        if fresh(for: info) { return }
        // 网络刚换过来时常常还不稳：等 2 秒再测
        schedule(after: 2)
    }

    /// 上次测的就是这种网络、而且没过半小时
    private func fresh(for p: NetworkPath) -> Bool {
        guard let last else { return false }
        return last.path == p && Date().timeIntervalSince(last.at) < Self.staleAfter
    }

    private func schedule(after seconds: Double) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.enabled, UIApplication.shared.applicationState == .active else { return }
            self.run(user: false)
        }
    }

    private func run(user: Bool) {
        task?.cancel()
        let p = path ?? NetworkPath(monitor.currentPath)
        guard p.online else {
            phase = .offline
            return
        }
        phase = .measuring
        task = Task { [weak self] in
            var mbps: Double?
            var rtt: Double?
            let demo = DemoData.enabled
            // 低数据模式：不测速（结果反正是省流量那一档）；演示数据：不连网
            if !demo, !p.constrained {
                let r = await NetworkProbe.run(maxBytes: p.metered ? 1 << 20 : 4 << 20)
                mbps = r.mbps
                rtt = r.rttMs
            }
            guard !Task.isCancelled, let self else { return }
            let check = NetworkCheck(path: p, mbps: mbps, rttMs: rtt, percent: NetworkAuto.percent(for: p, mbps: mbps), at: Date(), demo: demo)
            self.last = check
            if let d = try? JSONEncoder().encode(check) { UserDefaults.standard.set(d, forKey: Self.lastKey) }
            self.phase = .idle
            // 测的时候被关掉了：结果不用
            guard self.enabled else { return }
            UserDefaults.standard.set(check.percent, forKey: NetworkSpeed.autoValueKey)
            if user { self.userRuns += 1 }
        }
    }

    /// 按网络情况和速度选百分比（百分比管什么见 NetworkSpeed：正片往前缓冲 10 秒 + 每 1% 一秒，100% 交给系统；低于 25% 省流量）：
    /// · 低数据模式 → 20%（省流量：预告片不自己放）；
    /// · 很慢（不到 3 Mbps）→ 20%：带宽留给正片；
    /// · 按流量计费（蜂窝、个人热点）：25 Mbps 以上 60%、10 以上 50%、再慢 40%——缓冲够用，中途不看了白下的少；
    /// · 不计费（Wi‑Fi、有线）：25 Mbps 以上 100%（交给系统，能缓冲多少缓冲多少）、10 以上 90%、再慢 75%；
    /// · 没测出速度（探针不通）：只看网络类型，计费的 45%、不计费的 90%
    static func percent(for p: NetworkPath, mbps: Double?) -> Int {
        if p.constrained { return 20 }
        guard let mbps else { return p.metered ? 45 : 90 }
        if mbps < 3 { return 20 }
        if p.metered { return mbps >= 25 ? 60 : mbps >= 10 ? 50 : 40 }
        return mbps >= 25 ? 100 : mbps >= 10 ? 90 : 75
    }
}

/// 测速：Worker 的 /api/edge/ping?b=字节数（随机字节——可压缩的负载会被中间层压掉；不缓存）
enum NetworkProbe {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 5
        // 一次请求最多 8 秒（下载速度按它估上限）
        cfg.timeoutIntervalForResource = maxSeconds
        return URLSession(configuration: cfg)
    }()

    private static let maxSeconds: TimeInterval = 8

    private enum Outcome {
        case ok(seconds: Double, bytes: Int)
        case timedOut
        case failed
    }

    /// 延迟（三次空请求取最快的：第一次常带着建连接、握手）+ 下载速度（256 KB 起、每级 ×4，最多 maxBytes；
    /// 哪一级花了 2 秒以上就够准了，不再加大）。探针不通：两样都是 nil
    /// base：打哪个入口（默认 Worker 直连；Cuven Pass Pro 的测速对比也打加速节点，节点把探针转给 Worker）
    static func run(maxBytes: Int, base entry: String = APIClient.base) async -> (mbps: Double?, rttMs: Double?) {
        var rtt: Double?
        for _ in 0..<3 {
            guard case .ok(let s, _) = await fetch(0, base: entry) else { return (nil, nil) }
            rtt = min(rtt ?? s, s)
        }
        let base = rtt ?? 0
        var mbps: Double?
        var size = 256 << 10
        while !Task.isCancelled {
            switch await fetch(size, base: entry) {
            case .ok(let s, let n) where n == size:
                // 扣掉一来一回的延迟才是传输的时间（扣多了也至少算一半）
                mbps = Double(n) * 8 / max(s - base, s * 0.5) / 1_000_000
                if s > 2 || size >= maxBytes { return (mbps, base * 1000) }
                size = min(maxBytes, size * 4)
            case .timedOut:
                // 8 秒都没下完：最多这么快
                let bound = Double(size) * 8 / maxSeconds / 1_000_000
                return (min(mbps ?? bound, bound), base * 1000)
            default:
                return (mbps, base * 1000)
            }
        }
        return (mbps, base * 1000)
    }

    private static func fetch(_ bytes: Int, base: String) async -> Outcome {
        guard let url = URL(string: base + "/api/edge/ping?b=\(bytes)") else { return .failed }
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        let clock = ContinuousClock()
        let t0 = clock.now
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return .failed }
            // 测速下的也是这台设备的流量（账户页「流量概览」的「图片与资料」）
            UsageMeter.shared.add(data.count, to: .data)
            let d = t0.duration(to: clock.now)
            return .ok(seconds: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18, bytes: data.count)
        } catch let e as URLError where e.code == .timedOut {
            return .timedOut
        } catch {
            return .failed
        }
    }
}
