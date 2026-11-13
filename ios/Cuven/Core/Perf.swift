import Foundation
import os

/// 性能 / 播放诊断：只有数量、耗时与状态，不含片名与地址（仓库公开，模拟器预览会把这些打在 CI 里）。
/// 写进系统日志（os_log）；Debug 构建另外逐行写进 Caches/cuven-diag.log —— 模拟器的系统日志不留 info 级别，
/// CI 跑完测试直接从 App 容器里读这个文件。Debug 构建还开一条主线程看门狗：主线程卡住超过 1 秒记一笔；
/// 一秒里重绘超过 30 次也记一笔（抓「首页一直在重绘 / 主线程被什么占住」这一类问题）。
enum Perf {
    static let logger = Logger(subsystem: "us.cuven.tv", category: "perf")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        file(message)
    }

    static func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
    static func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }

    #if DEBUG
    private final class Diag: @unchecked Sendable {
        private let lock = NSLock()
        private var handle: FileHandle?
        private let t0 = ProcessInfo.processInfo.systemUptime
        private var counts: [String: Int] = [:]

        init() {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("cuven-diag.log")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }

        func write(_ line: String) {
            let t = ProcessInfo.processInfo.systemUptime - t0
            let s = String(format: "+%7.2fs  ", t) + line + "\n"
            lock.lock(); defer { lock.unlock() }
            try? handle?.write(contentsOf: Data(s.utf8))
        }

        func bump(_ k: String) { lock.lock(); counts[k, default: 0] += 1; lock.unlock() }
        func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
    }
    private static let diag = Diag()

    static func file(_ message: String) { diag.write(message) }
    static func count(_ name: String) { diag.bump(name) }

    static func startWatchdog() {
        let args = ProcessInfo.processInfo.arguments
        let flags = ["-CuvenDemo", "-CuvenDuo"].compactMap { k in args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? "\(k) \(args[$0 + 1])" : nil } }
        diag.write("==== launch \(Date()) \(flags.joined(separator: " "))")
        let t = Thread {
            var last: [String: Int] = [:]
            var lastReport = Date()
            while true {
                let sent = Date()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 1) == .timedOut {
                    sem.wait()
                    let m = Perf.ms(since: sent)
                    Perf.logger.error("main blocked \(m, privacy: .public) ms")
                    Perf.diag.write("main blocked \(m) ms")
                }
                Thread.sleep(forTimeInterval: 0.25)
                if Date().timeIntervalSince(lastReport) >= 1 {
                    lastReport = Date()
                    let now = Perf.diag.snapshot()
                    var total = 0
                    let delta = now.compactMap { k, v -> String? in
                        let d = v - (last[k] ?? 0)
                        total += max(0, d)
                        return d > 0 ? "\(k)=\(d)" : nil
                    }.sorted().joined(separator: " ")
                    if total > 30 { Perf.diag.write("renders/s \(delta)") }
                    last = now
                }
            }
        }
        t.name = "cuven.watchdog"
        t.qualityOfService = .userInteractive
        t.start()
    }
    #else
    @inline(__always) static func file(_ message: String) {}
    @inline(__always) static func count(_ name: String) {}
    static func startWatchdog() {}
    #endif
}
