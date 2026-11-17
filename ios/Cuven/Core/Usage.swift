import Foundation
import AVFoundation
import UIKit

// MARK: - 流量计（账户页「使用洞察 · 流量概览」，账户页移植（网页版））
//
// 网页版那张卡上的数都是随机数（generateRandomTraffic，每次进来换一组）。这里换成这台设备上真的下载了多少：
// · 视频：正片播放器（PlayerCoordinator）每隔几秒看一眼当前片源访问日志（accessLog）里累计收到的字节，只记新增的那一截；
// · 预告片：主页、资料库里自己放的那段预告片（ShowcaseTrailer），同样的办法；
// · 图片与资料：海报、剧照、字标真的走了网络的那一次（缓存命中不算），加上片库、影片信息这些接口的回包。
// 一小时一格、按类记字节，存在 Application Support（不跟着「清除缓存」一起没了），只留最近约两个月；不上传。
// 演示模式不记、不写文件。

/// 按小时、分三类记这台设备下载的字节数。任何线程都能调 add（内部一把锁）；存盘有节流（最多 15 秒一次，进后台立刻存）
final class UsageMeter: @unchecked Sendable {
    static let shared = UsageMeter()

    enum Category: Int, CaseIterable, Sendable {
        /// 正片
        case video
        /// 预告片
        case trailer
        /// 图片与资料（海报、剧照、字标、接口回包）
        case data
    }

    /// 只留最近 64 天：本月和上个月整月都还在（上个月一号离今天最多 62 天）
    private static let keepSeconds: Int64 = 64 * 24 * 3600

    private let lock = NSLock()
    /// 小时起点（本地时间那一小时的整点，秒）→ 三类字节
    private var buckets: [Int64: [Int64]] = [:]
    /// 第一次记账的时间：日均从这天起算，之前没有数据不算 0
    private var since: Date?
    private var dirty = false
    private var saveScheduled = false
    /// 当前这一小时的起止（秒）：每次 add 不必都问一遍日历
    private var hourStart: Int64 = 0
    private var hourEnd: Int64 = 0

    private let io = DispatchQueue(label: "us.cuven.usage", qos: .utility)
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cuven", isDirectory: true)
        fileURL = dir.appendingPathComponent("usage.json")
        load()
        // 进后台 / 被关掉前把没存的存掉（通知名在主线程上取）
        Task { @MainActor [weak self] in self?.observeLifecycle() }
    }

    // MARK: 记账

    /// 记一笔：bytes ≤ 0 不记；演示模式不记
    func add(_ bytes: Int64, to category: Category, at date: Date = Date()) {
        guard bytes > 0, !DemoData.enabled else { return }
        let t = Int64(date.timeIntervalSince1970)
        let schedule: Bool = lock.withLock {
            if t < hourStart || t >= hourEnd {
                let iv = Calendar.current.dateInterval(of: .hour, for: date)
                    ?? DateInterval(start: Date(timeIntervalSince1970: TimeInterval(t - t % 3600)), duration: 3600)
                hourStart = Int64(iv.start.timeIntervalSince1970)
                hourEnd = Int64(iv.end.timeIntervalSince1970)
            }
            var row = buckets[hourStart] ?? [0, 0, 0]
            row[category.rawValue] += bytes
            buckets[hourStart] = row
            if since == nil { since = date }
            dirty = true
            if saveScheduled { return false }
            saveScheduled = true
            return true
        }
        if schedule {
            io.asyncAfter(deadline: .now() + 15) { [weak self] in self?.write() }
        }
    }

    func add(_ bytes: Int, to category: Category) {
        add(Int64(bytes), to: category)
    }

    /// 立刻存（进后台时）
    func flush() {
        io.sync { write() }
    }

    // MARK: 查询

    /// 账户页那张卡要的数：近 24 小时（24 格）、本月合计 / 日均 / 各类、较上月（日均对日均）
    func summary(now: Date = Date(), calendar cal: Calendar = .current) -> UsageSummary {
        let (rows, first) = lock.withLock { (buckets, since) }
        let hourNow = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let windowStart = hourNow.addingTimeInterval(-23 * 3600)
        let w0 = windowStart.timeIntervalSince1970
        var hours = (0..<24).map { UsageSummary.Hour(start: windowStart.addingTimeInterval(TimeInterval($0) * 3600)) }

        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? cal.startOfDay(for: now)
        let lastMonthStart = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let ms = monthStart.timeIntervalSince1970, ls = lastMonthStart.timeIntervalSince1970
        let nowT = now.timeIntervalSince1970
        var month: [Int64] = [0, 0, 0]
        var lastMonth: Int64 = 0

        for (h, row) in rows {
            let t = TimeInterval(h)
            let i = Int(((t - w0) / 3600).rounded(.down))
            if i >= 0 && i < 24 {
                for c in 0..<3 { hours[i].bytes[c] += row[c] }
            }
            if t >= ms && t <= nowT {
                for c in 0..<3 { month[c] += row[c] }
            } else if t >= ls && t < ms {
                lastMonth += row.reduce(0, +)
            }
        }

        let monthTotal = month.reduce(0, +)
        // 日均：本月里从开始记账那天（或一号）到今天，按自然日算（今天算一天）
        let firstDay = cal.startOfDay(for: max(monthStart, first ?? now))
        let today = cal.startOfDay(for: now)
        let days = max(1, (cal.dateComponents([.day], from: firstDay, to: today).day ?? 0) + 1)
        let daily = monthTotal / Int64(days)

        // 较上月：上个月里记过账的那几天的日均；上个月没有数据（或那时还没开始记）就不比
        var trend: Double?
        if let first, first < monthStart, lastMonth > 0 {
            let lastFirst = cal.startOfDay(for: max(lastMonthStart, first))
            let lastDays = cal.dateComponents([.day], from: lastFirst, to: monthStart).day ?? 0
            if lastDays > 0 {
                let lastDaily = Double(lastMonth) / Double(lastDays)
                trend = (Double(daily) / lastDaily - 1) * 100
            }
        }

        return UsageSummary(hours: hours, monthByCategory: month, monthTotal: monthTotal, dailyAverage: daily,
                            trend: trend, since: first, isEmpty: rows.isEmpty)
    }

    // MARK: 存取

    private struct File: Codable {
        /// 第一次记账（秒）
        var since: Double?
        var hours: [Row]
        /// h：这一小时的起点（秒）；b：视频、预告片、图片与资料三类字节
        struct Row: Codable { var h: Int64; var b: [Int64] }
    }

    private func load() {
        guard !DemoData.enabled, let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        let cutoff = Int64(Date().timeIntervalSince1970) - Self.keepSeconds
        var out: [Int64: [Int64]] = [:]
        for r in file.hours where r.h >= cutoff && r.b.count == 3 {
            out[r.h] = r.b.map { max(0, $0) }
        }
        buckets = out
        since = file.since.map { Date(timeIntervalSince1970: $0) }
    }

    /// 只在 io 队列上调：拍一份快照（顺手剪掉两个月前的），写成 JSON
    private func write() {
        let cutoff = Int64(Date().timeIntervalSince1970) - Self.keepSeconds
        let snapshot: File? = lock.withLock {
            saveScheduled = false
            guard dirty else { return nil }
            dirty = false
            buckets = buckets.filter { $0.key >= cutoff }
            let rows = buckets.keys.sorted().map { File.Row(h: $0, b: buckets[$0] ?? [0, 0, 0]) }
            return File(since: since?.timeIntervalSince1970, hours: rows)
        }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    @MainActor
    private func observeLifecycle() {
        let nc = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            _ = nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.flush() }
        }
    }
}

/// 账户页「流量概览」要的一份数（UsageMeter.summary）
struct UsageSummary: Equatable, Sendable {
    struct Hour: Equatable, Sendable {
        /// 这一小时的起点
        var start: Date
        /// 视频、预告片、图片与资料
        var bytes: [Int64] = [0, 0, 0]
        var total: Int64 { bytes.reduce(0, +) }
    }

    /// 近 24 小时，旧的在前；最后一格是现在这一小时（还没过完）
    var hours: [Hour]
    /// 本月各类：视频、预告片、图片与资料
    var monthByCategory: [Int64]
    var monthTotal: Int64
    var dailyAverage: Int64
    /// 本月日均比上个月日均多（正）/ 少（负）百分之几；上个月没有数据是 nil
    var trend: Double?
    /// 从哪天开始记的
    var since: Date?
    /// 一笔都还没记过（或者两个月没用）
    var isEmpty: Bool
}

// MARK: - 播放器的流量：访问日志里累计收到的字节

/// 一个播放器一个：每隔几秒看一眼当前片源的 accessLog（各段 numberOfBytesTransferred 之和），只把比上次多出来的记进 UsageMeter。
/// 换片、播完、关掉之前调一次 flush，把旧片源最后那一截结清
@MainActor
final class UsageTap {
    let category: UsageMeter.Category
    private weak var item: AVPlayerItem?
    /// 当前片源已经记过的字节
    private var counted: Int64 = 0
    private var lastSample = Date.distantPast

    init(_ category: UsageMeter.Category) {
        self.category = category
    }

    /// 播放器的时间回调里随手调：不到 interval 秒就跳过（换了片源不等）
    func sample(_ current: AVPlayerItem?, every interval: TimeInterval = 5) {
        if current === item, Date().timeIntervalSince(lastSample) < interval { return }
        flush(current)
    }

    /// 立刻结一次：current 是接下来挂着的片源（nil = 卸下）；换了就先把旧的结清、再从零记新的
    func flush(_ current: AVPlayerItem?) {
        lastSample = Date()
        if let old = item, old !== current {
            settle(Self.bytes(old))
        }
        if current !== item {
            item = current
            counted = 0
        }
        if let current { settle(Self.bytes(current)) }
    }

    private func settle(_ total: Int64) {
        if total > counted {
            UsageMeter.shared.add(total - counted, to: category)
            counted = total
        } else if total < counted {
            counted = total          // 日志被系统截短了（少见）：从这里重新起算，不倒扣
        }
    }

    /// 这个片源到现在一共收到的字节（未知的段是负数，不算）
    static func bytes(_ item: AVPlayerItem) -> Int64 {
        guard let events = item.accessLog()?.events else { return 0 }
        return events.reduce(Int64(0)) { $0 + max(0, $1.numberOfBytesTransferred) }
    }
}

// MARK: - 网络速度（账户页那条 45 根柱的滑块）

/// 账户页「网络速度」：0…100，默认 80（和网页版的 settings.networkSpeed 同步，见 ProfileStore）。
/// 在 iOS 上它真的管播放：正片往前缓冲多少秒；调到 25% 以下是省流量，预告片不自己放。
/// 「自动调整」开着时用自动选的那个数（NetworkAuto）：存在另一个键里、只在本机——
/// 手动设的那个照旧和网页版同步，不会被这台手机此刻的网络带着走
enum NetworkSpeed {
    static let key = "cuven_network_speed"
    /// 「自动调整」开着没有（只在本机）
    static let autoKey = "cuven_network_speed_auto"
    /// 「自动调整」最近一次选的百分比（-1 / 没有 = 还没测过）
    static let autoValueKey = "cuven_network_speed_auto_value"
    static let defaultValue = 80

    /// 手动设的（没设过是 80）
    static var manual: Int {
        guard let n = UserDefaults.standard.object(forKey: key) as? NSNumber else { return defaultValue }
        return min(100, max(0, n.intValue))
    }

    static var isAuto: Bool { UserDefaults.standard.bool(forKey: autoKey) }

    /// 现在生效的：开着「自动调整」而且测过 → 自动选的；不然是手动设的
    static var current: Int {
        if isAuto, let n = UserDefaults.standard.object(forKey: autoValueKey) as? NSNumber, n.intValue >= 0 {
            return min(100, n.intValue)
        }
        return manual
    }

    /// 正片的 preferredForwardBufferDuration：100% = 0（交给系统，不设上限）；其余 10 秒 + 每 1% 一秒（80% → 90 秒，0% → 10 秒）。
    /// 缓冲得多，网一抖也接得上；缓冲得少，中途不看了白下的就少
    static func forwardBuffer(_ percent: Int = current) -> TimeInterval {
        percent >= 100 ? 0 : 10 + TimeInterval(max(0, percent))
    }

    /// 低于 25%：省流量，主页、资料库里的预告片停在第一帧，等人点播放钮
    static var dataSaver: Bool { current < 25 }
}
