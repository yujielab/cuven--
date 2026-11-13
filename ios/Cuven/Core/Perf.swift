import Foundation
import os

/// 性能日志：只有数量与耗时，不含片名与地址（仓库公开，模拟器预览会把这些日志打在 CI 里）。
/// Debug 构建另开一条主线程看门狗：主线程卡住超过 1 秒记一笔；每秒记一次各视图的重绘次数，
/// 用来抓「首页一直在重绘 / 主线程被什么占住」这一类问题。
enum Perf {
    static let logger = Logger(subsystem: "us.cuven.tv", category: "perf")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
    static func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }

    #if DEBUG
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        func bump(_ k: String) { lock.lock(); values[k, default: 0] += 1; lock.unlock() }
        func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private static let counters = Counters()

    static func count(_ name: String) { counters.bump(name) }

    static func startWatchdog() {
        let t = Thread {
            var last: [String: Int] = [:]
            var lastReport = Date()
            while true {
                let sent = Date()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 1) == .timedOut {
                    sem.wait()
                    logger.error("main blocked \(ms(since: sent), privacy: .public) ms")
                }
                Thread.sleep(forTimeInterval: 0.25)
                if Date().timeIntervalSince(lastReport) >= 1 {
                    lastReport = Date()
                    let now = counters.snapshot()
                    let delta = now.compactMap { k, v -> String? in
                        let d = v - (last[k] ?? 0)
                        return d > 0 ? "\(k)=\(d)" : nil
                    }.sorted().joined(separator: " ")
                    if !delta.isEmpty { logger.info("renders \(delta, privacy: .public)") }
                    last = now
                }
            }
        }
        t.name = "cuven.watchdog"
        t.qualityOfService = .userInteractive
        t.start()
    }
    #else
    @inline(__always) static func count(_ name: String) {}
    static func startWatchdog() {}
    #endif
}
