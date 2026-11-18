import Foundation
import UIKit

// MARK: - 下载整部影片（详情页右上 / iPhone Duo 侧边那一列返回钮下面的「下载」）
//
// 用户要求：详情页加「下载」「分享」，分享的结果可以直接用隔空投送给别人。
// · 下的是片库里的原始文件（和直连播放同一个签了名的地址：Worker 从 Dropbox 原样转过来，支持断点续传），
//   存在 App 的「文稿/Downloads」（不进 iCloud 备份），文件名是「片名 (年份).扩展名」——隔空投送过去对方看到的就是这个名字；
// · 系统的后台下载：退到后台、锁屏照样下；暂停 / 断网时留下续传数据，接着下不用从头；
// · 开始前看可用空间：文件大小 + 留出 max(5 GB, 总容量的 5%) 放不下就说空间不足、不开始；
// · 分享：下好的文件交给系统的分享面板（隔空投送、存到「文件」……）；还没下好时先提示下载。
//   这是用户明确要的「把文件发给别人」，不是站外链接：签名地址、片库路径都不会分享出去。
// 演示数据（UI 测试）时不下。

@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()
    static let sessionID = "us.cuven.tv.downloads"

    enum State: String, Codable { case downloading, paused, done, failed }

    struct Item: Codable, Equatable, Identifiable {
        var id: String
        var path: String
        var name: String
        var title: String
        /// 存下来的文件名（「片名 (年份).mkv」）
        var fileName: String
        /// 文件大小（字节，片库给的；0 = 不知道，下的时候按服务器说的）
        var size: Int64
        var written: Int64
        var state: State
        var created: Double

        var progress: Double { size > 0 ? min(1, Double(written) / Double(size)) : 0 }
    }

    enum StartResult: Equatable {
        case started
        case noSpace(needed: Int64)
        case unavailable
        case failed
    }

    private(set) var items: [String: Item] = [:]

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private let delegate = DownloadsDelegate()
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    /// 正在暂停的（cancel(byProducingResumeData:) 之后那一声「任务结束」不算失败）
    @ObservationIgnored private var pausing = Set<String>()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var wakeWaiters: [CheckedContinuation<Void, Never>] = []

    /// 文稿/Downloads：下好的影片；不进 iCloud 备份
    nonisolated static let folder: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? dir.setResourceValues(v)
        return dir
    }()

    /// 续传数据（暂停、断网时系统给的）
    nonisolated static let resumeFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DownloadResume", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var indexURL: URL { resumeFolder.appendingPathComponent("index.json") }

    /// 后台任务的说明：「编号|文件名」
    nonisolated static func describe(_ id: String, _ fileName: String) -> String { id + "|" + fileName }
    nonisolated static func parse(_ s: String?) -> (id: String, fileName: String)? {
        guard let s, let bar = s.firstIndex(of: "|") else { return nil }
        let id = String(s[..<bar]), file = String(s[s.index(after: bar)...])
        guard !id.isEmpty, !file.isEmpty, !file.contains("/"), !file.hasPrefix(".") else { return nil }
        return (id, file)
    }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL), let list = try? JSONDecoder().decode([Item].self, from: data) {
            for var it in list {
                // 下好了但文件没了（用户在「文件」里删了）：不算
                if it.state == .done, !FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(it.fileName).path) { continue }
                if it.state == .downloading { it.state = .paused }
                items[it.id] = it
            }
        }
    }

    // MARK: 给界面用

    func item(path: String) -> Item? { items[PrecacheFiles.id(for: path)] }

    func fileURL(_ it: Item) -> URL { Self.folder.appendingPathComponent(it.fileName) }

    /// 按了「下载」
    func start(path: String, name: String, title: String, year: Int?, size: Int64?) async -> StartResult {
        guard !DemoData.enabled else { return .unavailable }
        boot()
        let id = PrecacheFiles.id(for: path)
        if let it = items[id] {
            if it.state == .paused || it.state == .failed { await resume(path: path) }
            return .started
        }
        let need = max(0, size ?? 0)
        let space = Precache.freeSpace()
        let reserve = max(Int64(5) << 30, space.total / 20)
        if need > 0, space.total > 0, space.free - reserve < need { return .noSpace(needed: need + reserve) }
        guard let url = await signedURL(path: path, name: name) else { return .failed }
        let fileName = uniqueName(Self.fileName(title: title, year: year, ext: (name as NSString).pathExtension))
        items[id] = Item(id: id, path: path, name: name, title: title, fileName: fileName, size: need, written: 0,
                         state: .downloading, created: Date().timeIntervalSince1970)
        save()
        run(id, task: session?.downloadTask(with: url))
        Perf.log("download: start (\(need >> 20) MB)")
        return .started
    }

    func pause(path: String) {
        let id = PrecacheFiles.id(for: path)
        guard let task = tasks[id] else { return }
        pausing.insert(id)
        items[id]?.state = .paused
        task.cancel(byProducingResumeData: { data in
            if let data { try? data.write(to: Self.resumeFolder.appendingPathComponent(id), options: .atomic) }
        })
        save()
    }

    func resume(path: String) async {
        let id = PrecacheFiles.id(for: path)
        guard let it = items[id], tasks[id] == nil else { return }
        boot()
        items[id]?.state = .downloading
        let resumeURL = Self.resumeFolder.appendingPathComponent(id)
        if let data = try? Data(contentsOf: resumeURL), let task = session?.downloadTask(withResumeData: data) {
            try? FileManager.default.removeItem(at: resumeURL)
            run(id, task: task)
        } else if let url = await signedURL(path: it.path, name: it.name) {
            // 没有续传数据（服务器不给续传、数据过期了）：从头下
            items[id]?.written = 0
            run(id, task: session?.downloadTask(with: url))
        } else {
            items[id]?.state = .failed
        }
        save()
    }

    /// 取消下载 / 删除下好的文件
    func delete(path: String) {
        let id = PrecacheFiles.id(for: path)
        guard let it = items[id] else { return }
        if let t = tasks[id] {
            pausing.insert(id)
            t.cancel()
        }
        tasks[id] = nil
        items[id] = nil
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(it.fileName))
        try? FileManager.default.removeItem(at: Self.resumeFolder.appendingPathComponent(id))
        save()
    }

    // MARK: 后台

    func boot() {
        guard !started, !DemoData.enabled else { return }
        started = true
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        session?.getAllTasks { list in
            let found = list.compactMap { t -> (String, URLSessionDownloadTask)? in
                guard let d = t as? URLSessionDownloadTask, let p = Downloads.parse(d.taskDescription) else { return nil }
                return (p.id, d)
            }
            Task { @MainActor in Downloads.shared.adopt(found) }
        }
    }

    /// 系统为后台下载叫醒了 App（CuvenApp 的 backgroundTask）：接上会话，等它把结果交完（最多 25 秒）
    func handleBackgroundWake() async {
        boot()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wakeWaiters.append(c)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self.releaseWaiters()
            }
        }
    }

    fileprivate func eventsDone() { releaseWaiters() }

    private func releaseWaiters() {
        let w = wakeWaiters
        wakeWaiters = []
        for c in w { c.resume() }
    }

    private func adopt(_ found: [(String, URLSessionDownloadTask)]) {
        for (id, task) in found {
            guard items[id] != nil else { task.cancel(); continue }
            tasks[id] = task
            items[id]?.state = .downloading
        }
    }

    // MARK: 内部

    private func run(_ id: String, task: URLSessionDownloadTask?) {
        guard let task, let it = items[id] else {
            items[id]?.state = .failed
            return
        }
        task.taskDescription = Self.describe(id, it.fileName)
        tasks[id] = task
        task.resume()
    }

    private func signedURL(path: String, name: String) async -> URL? {
        guard let sign = try? await APIClient.shared.streamSign(path: path) else { return nil }
        return APIClient.shared.streamURL(path: path, name: name, sign: sign)
    }

    fileprivate func progressed(id: String, written: Int64, expected: Int64) {
        guard items[id] != nil else { return }
        items[id]?.written = written
        if expected > 0, (items[id]?.size ?? 0) <= 0 { items[id]?.size = expected }
    }

    fileprivate func completed(id: String, ok: Bool, size: Int64, resumeData: Data?) {
        tasks[id] = nil
        let wasPausing = pausing.remove(id) != nil
        guard items[id] != nil else { return }
        if ok {
            items[id]?.state = .done
            items[id]?.written = size
            if size > 0 { items[id]?.size = size }
            try? FileManager.default.removeItem(at: Self.resumeFolder.appendingPathComponent(id))
            Perf.log("download: done (\(size >> 20) MB)")
        } else if !wasPausing {
            // 断网、服务器出错：留下续传数据，按「继续下载」接着下
            if let resumeData { try? resumeData.write(to: Self.resumeFolder.appendingPathComponent(id), options: .atomic) }
            items[id]?.state = .failed
            Perf.log("download: failed")
        }
        save()
    }

    /// 「片名 (年份).mkv」：去掉文件名里不能有的字
    private static func fileName(title: String, year: Int?, ext: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var base = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if base.isEmpty || base.hasPrefix(".") { base = "Cuven" }
        if let year { base += " (\(year))" }
        return base + "." + (ext.isEmpty ? "mp4" : ext.lowercased())
    }

    /// 同名的已经有了（另一部同名片）：加上「 2」「 3」
    private func uniqueName(_ name: String) -> String {
        let used = Set(items.values.map(\.fileName))
        guard used.contains(name) || FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(name).path) else { return name }
        let ns = name as NSString
        let stem = ns.deletingPathExtension, ext = ns.pathExtension
        var n = 2
        while true {
            let candidate = "\(stem) \(n).\(ext)"
            if !used.contains(candidate), !FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(items.values)) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}

/// 后台下载的回调（系统在它自己的队列上叫）：下好的文件当场挪进「文稿/Downloads」，进度和结果交回 Downloads
final class DownloadsDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport: [Int: Date] = [:]
    private var moved: [Int: Int64] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let p = Downloads.parse(downloadTask.taskDescription) else { return }
        // 一秒报两次就够（界面上一圈进度）
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastReport[downloadTask.taskIdentifier] ?? .distantPast) > 0.5
        if due { lastReport[downloadTask.taskIdentifier] = now }
        lock.unlock()
        guard due else { return }
        Task { @MainActor in Downloads.shared.progressed(id: p.id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard let p = Downloads.parse(downloadTask.taskDescription), status == 200 || status == 206 else { return }
        let fm = FileManager.default
        let dest = Downloads.folder.appendingPathComponent(p.fileName)
        try? fm.removeItem(at: dest)
        guard (try? fm.moveItem(at: location, to: dest)) != nil else { return }
        let size = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber)?.int64Value ?? 0
        lock.lock()
        moved[downloadTask.taskIdentifier] = size
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = Downloads.parse(task.taskDescription) else { return }
        lock.lock()
        let size = moved.removeValue(forKey: task.taskIdentifier)
        lastReport[task.taskIdentifier] = nil
        lock.unlock()
        let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let ok = error == nil && size != nil
        Task { @MainActor in Downloads.shared.completed(id: p.id, ok: ok, size: size ?? 0, resumeData: resume) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in Downloads.shared.eventsDone() }
    }
}
