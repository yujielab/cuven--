import Foundation
import UIKit
import UserNotifications

// MARK: - 弱网预先缓存（详情页「预先画面质量处理」）
//
// 用户要求：网络不好、或者账户页「网络速度」低于 50% 时，详情页的「播放」换成「预先画面质量处理」；
// 按了就在后台把这部片「从现在看到的地方往后」先下到本机，按「立即播放」时马上用上已经下好的，同时接着往后下，弱网也放得顺。
// · 下什么：和播放器要的是同一份 HLS（Worker 实时重封装的 fMP4 分段：主列表、视频列表、默认音轨的列表、init、分段），
//   按播放列表里的时间排好，从续播的位置（没看过就从头）往后一段段下；
// · 下多少：最多这部片文件大小的一半（用户要求「缓存 max = 影片总容量的 50%」），还要放得进手机：先看可用空间，
//   留出 max(5 GB, 总容量的 10%) 不碰，再减去别的片还要下的；放不下最少的那一截（10 分钟或 1 GB）就说空间不足、不开始；
//   下的过程中可用空间掉到留着的那一截以下就停（「储存空间不足」）；
// · 下几部：最多 3 部（满了再加一部，把最久没用的那部删掉）；网络好（测得 50 Mbps 以上、延迟 250 ms 以内，或者 Wi‑Fi / 有线还没测）
//   时几部一起下，网络差时一次只下一部（正在放的、最近按的那部先下）；
// · 怎么下：系统的后台下载（URLSession 后台会话）——App 退到后台、锁屏也照样全速下；退到后台前把后面一大截先排给系统，
//   系统叫醒 App 时（CuvenApp 的 backgroundTask）再排下一截；
// · 边看边下：「立即播放」走本机的代理（PrecacheServer：只听 127.0.0.1），有的分段从本机出，没有的去 Worker 取、边转给播放器边存下；
//   代理看到播放器要到第几段，下载就跟到那儿往后接着下；存满了（50%）就把已经看过的那几段删掉腾地方，一直往后滚（动态的窗口）；
// · 缓存到 25%（能缓存的上限的四分之一）时发一条通知（用户要求）：「《影片名》现已可供观看，预先品质处理已经完成。」——
//   App 开着时也弹横幅；正在放这一部时不发（人已经在看）；每部只发一次。按「预先画面质量处理」时才问通知权限（系统还没问过的话）。
//   退到后台时先只把到 25% 的那一截排给系统：系统下完这一批就叫醒 App，通知按时发出去，再排后面的；
// · 演示数据（UI 测试）时不下。

/// 预先缓存的文件放在哪：Library/Caches/Precache/<影片>/<idh>/…（系统空间吃紧时可以清掉；不进 iCloud 备份）
enum PrecacheFiles {
    static let root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Precache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func file(_ id: String, _ rel: String) -> URL { dir(id).appendingPathComponent(rel) }

    /// rel 只许是播放列表里那种相对路径（字母数字、点、横杠、下划线、斜杠），不许「..」、不许以斜杠开头
    static func safe(_ rel: String) -> Bool {
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("..") else { return false }
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/"))
        return rel.unicodeScalars.allSatisfy { ok.contains($0) }
    }

    /// 影片的编号：路径的 FNV-1a（十六进制，只有字母数字，能直接放进代理的地址里）
    static func id(for path: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// 删掉一部的目录：先改名挪开（马上就不在原处了），真删放到后台（几十 GB 的几百个文件，不卡主线程）
    static func trash(_ id: String) {
        let fm = FileManager.default
        let folder = Self.dir(id)
        guard fm.fileExists(atPath: folder.path) else { return }
        let bin = root.appendingPathComponent(".trash-\(UUID().uuidString)", isDirectory: true)
        if (try? fm.moveItem(at: folder, to: bin)) != nil {
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: bin) }
        } else {
            try? fm.removeItem(at: folder)
        }
    }

    /// 上次没删完的（App 在删的时候被关了）
    static func emptyTrash() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let list = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for u in list where u.lastPathComponent.hasPrefix(".trash-") { try? fm.removeItem(at: u) }
        }
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 后台下载任务的说明：「影片编号|相对路径」
    static func describe(_ id: String, _ rel: String) -> String { id + "|" + rel }
    static func parse(_ s: String?) -> (id: String, rel: String)? {
        guard let s, let bar = s.firstIndex(of: "|") else { return nil }
        let id = String(s[..<bar]), rel = String(s[s.index(after: bar)...])
        guard !id.isEmpty, safe(rel) else { return nil }
        return (id, rel)
    }
}

/// 读 Worker 给的 HLS 播放列表（格式见 Stream_v25.js 的 hlsMaster / hlsMediaPl：相对地址、一条视频、可能另有音轨）
enum PrecacheHLS {
    struct Master: Equatable {
        /// 视频列表（相对主列表）：「<idh>/v.m3u8」
        var video: String
        /// 默认音轨另有列表时（没混在视频分段里）：「<idh>/a1.m3u8」「<idh>/t2.m3u8」
        var audio: String?
        var idh: String
    }

    struct Segment {
        var rel: String
        var start: Double
        var dur: Double
    }

    struct Media {
        var map: String?
        var segments: [Segment]
    }

    static func master(_ text: String) -> Master? {
        var video: String?
        var audio: String?
        var wantURI = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") { wantURI = true; continue }
            if wantURI, !line.isEmpty, !line.hasPrefix("#") {
                if video == nil { video = line }
                wantURI = false
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:"), line.contains("TYPE=AUDIO"), line.contains("DEFAULT=YES"),
               let uri = attr(line, "URI") {
                audio = uri
            }
        }
        guard let v = video, let idh = v.split(separator: "/").first.map(String.init), v.contains("/") else { return nil }
        return Master(video: v, audio: audio, idh: idh)
    }

    /// dir：这份列表所在的目录（相对主列表，带结尾的斜杠：「<idh>/」）
    static func media(_ text: String, dir: String) -> Media {
        var map: String?
        var segments: [Segment] = []
        var pending: Double?
        var t = 0.0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:"), let uri = attr(line, "URI") {
                map = dir + uri
            } else if line.hasPrefix("#EXTINF:") {
                let v = line.dropFirst(8).split(separator: ",").first.flatMap { Double(String($0)) }
                pending = max(0, v ?? 0)
            } else if !line.isEmpty, !line.hasPrefix("#"), let d = pending {
                segments.append(Segment(rel: dir + line, start: t, dur: d))
                t += d
                pending = nil
            }
        }
        return Media(map: map, segments: segments)
    }

    /// 列表的目录：「<idh>/v.m3u8」→「<idh>/」
    static func dir(of rel: String) -> String {
        guard let slash = rel.lastIndex(of: "/") else { return "" }
        return String(rel[...slash])
    }

    /// 属性：`KEY="value"` 或 `KEY=value`
    static func attr(_ line: String, _ key: String) -> String? {
        guard let r = line.range(of: key + "=") else { return nil }
        var rest = line[r.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        return String(rest.prefix { $0 != "," })
    }
}

@MainActor
@Observable
final class Precache {
    static let shared = Precache()

    enum Phase: String, Codable {
        /// 正在问片源、读播放列表、算空间
        case preparing
        /// 排着队（网络差时一次只下一部）或者在等网络
        case queued
        case downloading
        case paused
        /// 下够了（这部片的一半，或者下到了片尾）
        case done
        case failed
        /// 手机空间不够了
        case noSpace
    }

    struct Item: Codable, Equatable, Identifiable {
        var id: String
        var path: String
        var name: String
        /// 文件大小（字节）
        var size: Int64
        /// 最多下这么多（文件大小的一半，放得进手机的那么多）
        var target: Int64
        /// 本机已经有的
        var bytes: Int64 = 0
        /// 从哪儿开始下（秒）：按下时续播的位置
        var start: Double
        /// 下到哪儿了（秒）：播放器要到哪一段就跟到哪一段，往后接着下
        var cursor: Double
        var phase: Phase
        var created: Double
        var used: Double
        /// Worker 的索引编号（播放列表的目录名）：文件换了 / 引擎升级了它就变，旧的分段作废
        var idh: String?
        /// 通知里的片名（中文名）
        var title: String?
        /// 25% 的那条通知发过了
        var notified: Bool?

        var progress: Double { target > 0 ? min(1, Double(bytes) / Double(target)) : 0 }
        /// 到了能看的那一截（25%）
        var ready: Bool { target > 0 && Double(bytes) >= Double(target) * Precache.readyFraction }
    }

    enum StartResult: Equatable {
        case started
        /// 放不下：至少要这么多可用空间（字节）
        case noSpace(needed: Int64)
        case unavailable
    }

    /// 影片编号 → 一部（详情页看着它）
    private(set) var items: [String: Item] = [:]

    private struct PlanFile {
        var rel: String
        var start: Double
        var end: Double
        var isVideo: Bool
    }

    private struct Plan {
        /// init 在前（start = -1），再按开始时间排好的分段（视频和另有列表的音轨混在一起）
        var files: [PlanFile]
        var byRel: [String: Int]
        var duration: Double
        var segmentCount: Int
    }

    static let sessionID = "us.cuven.tv.precache"
    /// 缓存到上限的这么多就算「能看了」：发通知（用户要求 25%）
    nonisolated static let readyFraction = 0.25
    private static let indexName = "index.json"
    private static let maxItems = 3
    private static let perItem = 3
    private static let backgroundBatch = 160

    @ObservationIgnored private var plans: [String: Plan] = [:]
    @ObservationIgnored private var cached: [String: Set<String>] = [:]
    @ObservationIgnored private var inflight: [String: Set<String>] = [:]
    @ObservationIgnored private var failures: [String: [String: Int]] = [:]
    @ObservationIgnored private var bases: [String: (url: URL, at: Date)] = [:]
    @ObservationIgnored private var preparing = Set<String>()
    @ObservationIgnored private var playingID: String?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private let delegate = PrecacheSessionDelegate()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var errorStreak = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var wakeWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        let url = PrecacheFiles.root.appendingPathComponent(Self.indexName)
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Item].self, from: data) {
            for var it in list where FileManager.default.fileExists(atPath: PrecacheFiles.dir(it.id).path) {
                if it.phase == .preparing || it.phase == .downloading { it.phase = .queued }
                items[it.id] = it
            }
        }
    }

    // MARK: 给界面用

    func item(path: String) -> Item? { items[PrecacheFiles.id(for: path)] }

    /// 详情页要不要把「播放」换成「预先画面质量处理」：网络速度低于 50%，或者测到的网速不够这部片的码率（留 25% 余量）。
    /// 只给 HLS 的片源（MKV：Worker 重封装成 HLS 的那种），离线、演示数据时不给
    func suggested(name: String, size: Int64?, runtime: Int?) -> Bool {
        guard !DemoData.enabled, name.lowercased().hasSuffix(".mkv") else { return false }
        if NetworkSpeed.current < 50 { return true }
        guard let c = NetworkAuto.shared.last, Date().timeIntervalSince(c.at) < 3600, c.path.online else { return false }
        if c.path.constrained { return true }
        if let mbps = c.mbps {
            let need = Self.bitrateMbps(size: size, runtime: runtime) ?? 25
            return mbps < max(8, need * 1.25)
        }
        if let rtt = c.rttMs, rtt > 400 { return true }
        return false
    }

    /// 片源的平均码率（Mbps）：文件大小 ÷ 片长
    static func bitrateMbps(size: Int64?, runtime: Int?) -> Double? {
        guard let size, size > 0, let runtime, runtime > 0 else { return nil }
        return Double(size) * 8 / (Double(runtime) * 60) / 1_000_000
    }

    /// 按了「预先画面质量处理」：算好空间就开始下（从续播的位置往后）。title：通知里的片名
    func start(path: String, name: String, title: String, size: Int64?, runtime: Int?, resume: Double?) -> StartResult {
        guard !DemoData.enabled else { return .unavailable }
        boot()
        PrecacheNotice.requestPermission()
        let id = PrecacheFiles.id(for: path)
        if var it = items[id] {
            if it.phase != .downloading { it.phase = .queued }
            it.used = Date().timeIntervalSince1970
            items[id] = it
            kick(id)
            return .started
        }
        let fileSize = max(0, size ?? 0)
        let budget = Self.budget(fileSize: fileSize, runtime: runtime, others: plannedRemaining(excluding: id))
        guard budget.target > 0 else { return .noSpace(needed: budget.needed) }
        // 最多 3 部：满了把最久没用的那部（不是正在放的那部）删掉
        while items.count >= Self.maxItems,
              let old = items.values.filter({ $0.id != playingID }).min(by: { $0.used < $1.used }) {
            remove(old.id)
        }
        let now = Date().timeIntervalSince1970
        let from = max(0, resume ?? 0)
        items[id] = Item(id: id, path: path, name: name, size: fileSize, target: budget.target, start: from, cursor: from,
                         phase: .preparing, created: now, used: now, idh: nil, title: title, notified: nil)
        try? FileManager.default.createDirectory(at: PrecacheFiles.dir(id), withIntermediateDirectories: true)
        save()
        Perf.log("precache: start (target \(budget.target >> 20) MB)")
        kick(id)
        return .started
    }

    func pause(path: String) {
        let id = PrecacheFiles.id(for: path)
        guard var it = items[id] else { return }
        it.phase = .paused
        items[id] = it
        cancelTasks(id)
        save()
    }

    func resume(path: String) {
        let id = PrecacheFiles.id(for: path)
        guard var it = items[id] else { return }
        it.phase = .queued
        it.used = Date().timeIntervalSince1970
        items[id] = it
        kick(id)
    }

    func delete(path: String) { remove(PrecacheFiles.id(for: path)) }

    // MARK: 给播放器用

    /// 这部片有预先缓存：返回本机代理的地址（播放器从那儿放：有的从本机出，没有的边取边存），并接着往后下；没有就是 nil
    func playbackURL(path: String, upstreamMaster: URL) async -> URL? {
        guard !DemoData.enabled else { return nil }
        let id = PrecacheFiles.id(for: path)
        guard var it = items[id] else { return nil }
        boot()
        let base = upstreamMaster.deletingLastPathComponent()
        bases[id] = (base, Date())
        PrecacheServer.shared.setUpstream(id: id, base: base)
        guard let port = await PrecacheServer.shared.start() else {
            Perf.log("precache: proxy unavailable")
            return nil
        }
        playingID = id
        it.used = Date().timeIntervalSince1970
        if it.phase == .paused || it.phase == .done || it.phase == .failed { it.phase = .queued }
        items[id] = it
        kick(id)
        return URL(string: "http://127.0.0.1:\(port)/c/\(id)/master.m3u8")
    }

    /// 代理看到播放器要了某一段（视频）：下载跟到这儿往后接着下
    fileprivate func requested(id: String, rel: String) {
        guard var it = items[id], let plan = plans[id], let k = plan.byRel[rel] else { return }
        let f = plan.files[k]
        guard f.isVideo, abs(f.start - it.cursor) > 0.5 else { return }
        it.cursor = f.start
        if it.phase == .done { it.phase = .queued }
        items[id] = it
        playingID = id
        reconcile(id)
        pump()
    }

    /// 代理边转边存下了一个文件
    fileprivate func relayed(id: String, rel: String, size: Int64) {
        guard items[id] != nil else { return }
        if cached[id, default: []].insert(rel).inserted {
            items[id]?.bytes += size
            notifyIfReady(id)
            saveSoon()
        }
        reconcile(id)
    }

    /// 到了 25%：发「现已可供观看」的通知（每部一次；正在放这一部时不发，只记下发过了）
    private func notifyIfReady(_ id: String) {
        guard let it = items[id], it.notified != true, it.ready else { return }
        items[id]?.notified = true
        if playingID != id {
            PrecacheNotice.ready(id: id, title: it.title ?? FileName.title(it.name))
            Perf.log("precache: ready notice")
        }
        save()
    }

    // MARK: 后台

    /// 系统为后台下载叫醒了 App（CuvenApp 的 backgroundTask）：接上会话、等它把结果交完（最多 25 秒），再排下一截
    func handleBackgroundWake() async {
        boot()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wakeWaiters.append(c)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self.releaseWaiters()
            }
        }
        topUpForBackground()
    }

    fileprivate func backgroundEventsDone() {
        releaseWaiters()
    }

    private func releaseWaiters() {
        let w = wakeWaiters
        wakeWaiters = []
        for c in w { c.resume() }
    }

    // MARK: 启动

    /// 一启动就接上后台下载（上次没下完的接着下）
    func boot() {
        guard !started, !DemoData.enabled else { return }
        started = true
        PrecacheFiles.emptyTrash()
        PrecacheNotice.install()
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForResource = 24 * 3600
        let s = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        session = s
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in Precache.shared.topUpForBackground() }
            },
            nc.addObserver(forName: .cuvenPlayerClosed, object: nil, queue: .main) { _ in
                Task { @MainActor in Precache.shared.playerClosed() }
            },
        ]
        // 上次排给系统的还在下的：记回正在下（免得又排一遍）
        s.getAllTasks { list in
            let found = list.compactMap { t -> (String, String)? in
                guard let p = PrecacheFiles.parse(t.taskDescription) else { return nil }
                return (p.id, p.rel)
            }
            Task { @MainActor in Precache.shared.adopt(found) }
        }
    }

    private func adopt(_ found: [(String, String)]) {
        for (id, rel) in found {
            if items[id] == nil { continue }
            inflight[id, default: []].insert(rel)
        }
        for id in items.keys where items[id]?.phase == .queued || items[id]?.phase == .downloading {
            kick(id)
        }
    }

    private func playerClosed() {
        playingID = nil
        for id in items.keys { reconcile(id) }
        pump()
    }

    // MARK: 准备：问片源、读播放列表、排好要下的文件

    private func kick(_ id: String) {
        if plans[id] == nil {
            guard !preparing.contains(id) else { return }
            preparing.insert(id)
            Task { @MainActor in
                await self.prepare(id)
                self.preparing.remove(id)
                self.pump()
            }
        } else {
            reconcile(id)
            pump()
        }
    }

    private func prepare(_ id: String) async {
        guard items[id] != nil else { return }
        guard let base = await freshBase(id) else { return waitAndRetry(id) }
        // 主列表：每次都问一次（在线字幕会变）；问不到就用上次存下的
        let masterText = await fetchText(base.appendingPathComponent("master.m3u8")) ?? readCached(id, "master.m3u8")
        guard let masterText, let master = PrecacheHLS.master(masterText) else { return waitAndRetry(id) }
        writeCached(id, "master.m3u8", masterText)
        if let old = items[id]?.idh, old != master.idh {
            // 文件换了 / 引擎升级了：旧的分段作废
            PrecacheFiles.trash(id)
            try? FileManager.default.createDirectory(at: PrecacheFiles.dir(id), withIntermediateDirectories: true)
            cached[id] = []
            items[id]?.bytes = 0
        }
        items[id]?.idh = master.idh
        guard let videoText = await playlist(id, base: base, rel: master.video) else { return waitAndRetry(id) }
        let video = PrecacheHLS.media(videoText, dir: PrecacheHLS.dir(of: master.video))
        var audio: PrecacheHLS.Media?
        if let a = master.audio, let text = await playlist(id, base: base, rel: a) {
            audio = PrecacheHLS.media(text, dir: PrecacheHLS.dir(of: a))
        }
        guard !video.segments.isEmpty else { return waitAndRetry(id) }
        var files: [PlanFile] = []
        if let m = video.map { files.append(PlanFile(rel: m, start: -1, end: 0, isVideo: false)) }
        if let m = audio?.map { files.append(PlanFile(rel: m, start: -1, end: 0, isVideo: false)) }
        var segs = video.segments.map { PlanFile(rel: $0.rel, start: $0.start, end: $0.start + $0.dur, isVideo: true) }
        segs += (audio?.segments ?? []).map { PlanFile(rel: $0.rel, start: $0.start, end: $0.start + $0.dur, isVideo: false) }
        segs.sort { $0.start != $1.start ? $0.start < $1.start : ($0.isVideo && !$1.isVideo) }
        files += segs
        var byRel: [String: Int] = [:]
        for (i, f) in files.enumerated() { byRel[f.rel] = i }
        let duration = video.segments.last.map { $0.start + $0.dur } ?? 0
        plans[id] = Plan(files: files, byRel: byRel, duration: duration, segmentCount: video.segments.count)
        // 本机已经有的（上次下的、播放时边看边存的）
        if cached[id] == nil {
            var have = Set<String>()
            var bytes: Int64 = 0
            for f in files {
                let url = PrecacheFiles.file(id, f.rel)
                if FileManager.default.fileExists(atPath: url.path) {
                    have.insert(f.rel)
                    bytes += PrecacheFiles.size(url)
                }
            }
            cached[id] = have
            items[id]?.bytes = bytes
        }
        if items[id]?.phase == .preparing { items[id]?.phase = .queued }
        save()
        Perf.log("precache: planned \(files.count) files, \(Int(duration)) s")
        reconcile(id)
    }

    /// 二级列表：问 Worker（存下）；问不到用上次存的
    private func playlist(_ id: String, base: URL, rel: String) async -> String? {
        if let t = await fetchText(base.appendingPathComponent(rel)) {
            writeCached(id, rel, t)
            return t
        }
        return readCached(id, rel)
    }

    private func waitAndRetry(_ id: String) {
        guard items[id] != nil else { return }
        if items[id]?.phase == .preparing || items[id]?.phase == .downloading { items[id]?.phase = .queued }
        scheduleRetry()
    }

    /// 片源的签名地址（12 小时有效，6 小时换一次）
    private func freshBase(_ id: String) async -> URL? {
        if let b = bases[id], Date().timeIntervalSince(b.at) < 6 * 3600 { return b.url }
        guard let it = items[id], let sign = try? await APIClient.shared.streamSign(path: it.path),
              let hls = sign.hls, !hls.isEmpty, let master = URL(string: APIClient.base + hls) else { return nil }
        let base = master.deletingLastPathComponent()
        bases[id] = (base, Date())
        PrecacheServer.shared.setUpstream(id: id, base: base)
        return base
    }

    private func fetchText(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readCached(_ id: String, _ rel: String) -> String? {
        try? String(contentsOf: PrecacheFiles.file(id, rel), encoding: .utf8)
    }

    private func writeCached(_ id: String, _ rel: String, _ text: String) {
        let url = PrecacheFiles.file(id, rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: 排下载

    /// 网络好：几部一起下；网络差：一次只下一部
    private var networkGood: Bool {
        guard let c = NetworkAuto.shared.last, c.path.online, !c.path.constrained else { return false }
        if let m = c.mbps { return m >= 50 && (c.rttMs ?? 0) < 250 }
        return c.path.kind == .wifi || c.path.kind == .wired
    }

    private func pump() {
        guard started, let session else { return }
        let active = items.values.filter { ($0.phase == .queued || $0.phase == .downloading) && plans[$0.id] != nil }
            .sorted { a, b in
                let pa = a.id == playingID ? 1 : 0, pb = b.id == playingID ? 1 : 0
                return pa != pb ? pa > pb : a.used > b.used
            }
        let allowed = Set((networkGood ? active.prefix(Self.maxItems) : active.prefix(1)).map(\.id))
        for it in active {
            guard allowed.contains(it.id) else {
                if it.phase != .queued { items[it.id]?.phase = .queued }
                continue
            }
            guard let base = bases[it.id]?.url, Date().timeIntervalSince(bases[it.id]?.at ?? .distantPast) < 6 * 3600 else {
                // 签名快过期了：先换一个再排
                Task { @MainActor in
                    if await self.freshBase(it.id) != nil { self.pump() } else { self.waitAndRetry(it.id) }
                }
                continue
            }
            let room = Self.perItem - (inflight[it.id]?.count ?? 0)
            let next = room > 0 ? nextFiles(it.id, limit: room) : []
            if next.isEmpty && (inflight[it.id]?.isEmpty ?? true) { reconcile(it.id); continue }
            if items[it.id]?.phase != .downloading { items[it.id]?.phase = .downloading }
            for rel in next { enqueue(session, id: it.id, base: base, rel: rel) }
        }
    }

    private func enqueue(_ session: URLSession, id: String, base: URL, rel: String) {
        var req = URLRequest(url: base.appendingPathComponent(rel))
        req.timeoutInterval = 60
        let task = session.downloadTask(with: req)
        task.taskDescription = PrecacheFiles.describe(id, rel)
        inflight[id, default: []].insert(rel)
        task.resume()
    }

    /// 接下来要下的：从下到的地方（往前留 8 秒）往后、还没有、没在下、没连着失败三次的；估算会不会超过上限
    private func nextFiles(_ id: String, limit: Int) -> [String] {
        guard let plan = plans[id], let it = items[id], limit > 0 else { return [] }
        let have = cached[id] ?? [], busy = inflight[id] ?? [], bad = failures[id] ?? [:]
        let avg = averageFileSize(id)
        var budget = it.target - it.bytes - Int64(busy.count) * avg
        var out: [String] = []
        for f in plan.files where f.start < 0 || f.end > it.cursor - 8 {
            if have.contains(f.rel) || busy.contains(f.rel) || (bad[f.rel] ?? 0) >= 3 { continue }
            if f.start >= 0 {
                guard budget > 0 else { break }
                budget -= avg
            }
            out.append(f.rel)
            if out.count >= limit { break }
        }
        return out
    }

    /// 一个文件大概多大：下过的平均；还没下过就按文件大小 ÷ 分段数估
    private func averageFileSize(_ id: String) -> Int64 {
        guard let it = items[id] else { return 1 << 20 }
        let n = Int64(cached[id]?.count ?? 0)
        if n >= 3, it.bytes > 0 { return max(64 << 10, it.bytes / n) }
        let segs = Int64(max(1, plans[id]?.segmentCount ?? 1))
        return max(256 << 10, it.size / segs)
    }

    /// 退到后台前：把后面一大截先排给系统（App 睡着时系统照样全速下）
    private func topUpForBackground() {
        guard started, let session else { return }
        let active = items.values.filter { ($0.phase == .queued || $0.phase == .downloading) && plans[$0.id] != nil }
            .sorted { $0.used > $1.used }
        let picked = networkGood ? Array(active.prefix(Self.maxItems)) : Array(active.prefix(1))
        for it in picked {
            guard let base = bases[it.id]?.url else { continue }
            var room = Self.backgroundBatch - (inflight[it.id]?.count ?? 0)
            // 还没到 25%：这一批只排到 25%——系统下完一批才叫醒 App，这样「现已可供观看」的通知能按时发出去
            if it.notified != true, it.target > 0 {
                let short = Int64(Double(it.target) * Self.readyFraction) - it.bytes
                if short > 0 {
                    let n = Int((Double(short) / Double(max(1, averageFileSize(it.id)))).rounded(.up)) + 1
                    room = min(room, max(1, n - (inflight[it.id]?.count ?? 0)))
                }
            }
            for rel in nextFiles(it.id, limit: room) { enqueue(session, id: it.id, base: base, rel: rel) }
            if items[it.id]?.phase != .downloading { items[it.id]?.phase = .downloading }
        }
    }

    /// 看看这一部到没到头：存满了在放就把看过的删掉往后滚，没在放就算下完；下到片尾也算下完
    private func reconcile(_ id: String) {
        guard var it = items[id], let plan = plans[id] else { return }
        guard it.phase != .paused, it.phase != .noSpace, it.phase != .preparing else { return }
        if it.bytes >= it.target {
            if id == playingID {
                // 动态的窗口：删掉已经看过的（播放位置往前 30 秒以前的），腾出一成半再接着往后下
                var freed: Int64 = 0
                let goal = it.bytes - Int64(Double(it.target) * 0.85)
                for f in plan.files where f.start >= 0 && f.end < it.cursor - 30 {
                    guard freed < goal else { break }
                    guard cached[id]?.contains(f.rel) == true else { continue }
                    let url = PrecacheFiles.file(id, f.rel)
                    freed += PrecacheFiles.size(url)
                    try? FileManager.default.removeItem(at: url)
                    cached[id]?.remove(f.rel)
                }
                it.bytes = max(0, it.bytes - freed)
                if it.bytes >= it.target, inflight[id]?.isEmpty ?? true { it.phase = .done }
            } else if inflight[id]?.isEmpty ?? true {
                it.phase = .done
            }
        }
        // 从下到的地方往后都有了（下到了片尾）
        let have = cached[id] ?? []
        let remaining = plan.files.contains { ($0.start < 0 || $0.end > it.cursor - 8) && !have.contains($0.rel) && (failures[id]?[$0.rel] ?? 0) < 3 }
        if !remaining, inflight[id]?.isEmpty ?? true { it.phase = .done }
        if it.phase == .done, items[id]?.phase != .done { Perf.log("precache: done (\(it.bytes >> 20) MB)") }
        items[id] = it
    }

    // MARK: 下载的结果

    fileprivate func finished(id: String, rel: String, status: Int, size: Int64, failed: Bool, cancelled: Bool) {
        inflight[id]?.remove(rel)
        guard items[id] != nil else {
            // 这一部已经删了：刚下好的也删掉
            try? FileManager.default.removeItem(at: PrecacheFiles.file(id, rel))
            return
        }
        if !failed, status == 200, size >= 0 {
            if cached[id, default: []].insert(rel).inserted {
                items[id]?.bytes += size
                notifyIfReady(id)
            }
            failures[id]?[rel] = nil
            errorStreak = 0
            checkSpace()
            saveSoon()
        } else if !cancelled {
            if status == 401 || status == 403 { bases[id] = nil }          // 签名过期：换一个
            if status == 410 { plans[id] = nil }                           // 文件换了：重读播放列表
            failures[id, default: [:]][rel, default: 0] += 1
            errorStreak += 1
            if errorStreak >= 6 {
                // 连着失败（断网、服务器出错）：歇 20 秒再试
                for k in items.keys where items[k]?.phase == .downloading { items[k]?.phase = .queued }
                scheduleRetry()
                return
            }
        }
        reconcile(id)
        if plans[id] == nil { kick(id) } else { pump() }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self.retryTask = nil
            self.errorStreak = 0
            for id in self.items.keys where self.items[id]?.phase == .queued { self.kick(id) }
            self.pump()
        }
    }

    // MARK: 空间

    struct Budget {
        var target: Int64
        var needed: Int64
    }

    /// 能下多少：文件的一半，放得进手机（留出 max(5 GB, 总容量的 10%)，减去别的片还要下的）；最少要有 10 分钟或 1 GB，不然算放不下
    static func budget(fileSize: Int64, runtime: Int?, others: Int64) -> Budget {
        let half = fileSize > 0 ? fileSize / 2 : 20 << 30
        let space = freeSpace()
        let reserve = max(Int64(5) << 30, space.total / 10)
        let avail = space.free - reserve - others
        var minimum = Int64(1) << 30
        if let mbps = bitrateMbps(size: fileSize, runtime: runtime) {
            minimum = max(minimum, Int64(mbps * 1_000_000 / 8 * 600))
        }
        minimum = min(minimum, half)
        let target = min(half, avail)
        guard target >= minimum else { return Budget(target: 0, needed: minimum + reserve + others) }
        return Budget(target: target, needed: 0)
    }

    static func freeSpace() -> (free: Int64, total: Int64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
    }

    private func plannedRemaining(excluding id: String) -> Int64 {
        items.values.filter { $0.id != id && $0.phase != .done }.reduce(0) { $0 + max(0, $1.target - $1.bytes) }
    }

    /// 下的过程中：可用空间掉到留着的那一截以下就都停下（「储存空间不足」）
    private func checkSpace() {
        let space = Self.freeSpace()
        let reserve = max(Int64(5) << 30, space.total / 10)
        guard space.total > 0, space.free < reserve else { return }
        for id in items.keys where items[id]?.phase == .downloading || items[id]?.phase == .queued {
            items[id]?.phase = .noSpace
            cancelTasks(id)
        }
        Perf.log("precache: out of space")
        save()
    }

    // MARK: 删 / 存

    private func remove(_ id: String) {
        cancelTasks(id)
        items[id] = nil
        plans[id] = nil
        cached[id] = nil
        inflight[id] = nil
        failures[id] = nil
        bases[id] = nil
        if playingID == id { playingID = nil }
        PrecacheFiles.trash(id)
        save()
    }

    private func cancelTasks(_ id: String) {
        inflight[id] = []
        session?.getAllTasks { list in
            for t in list where PrecacheFiles.parse(t.taskDescription)?.id == id { t.cancel() }
        }
    }

    private func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.saveTask = nil
            self.save()
        }
    }

    private func save() {
        let list = Array(items.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: PrecacheFiles.root.appendingPathComponent(Self.indexName), options: .atomic)
    }
}

/// 后台下载的回调（系统在它自己的队列上叫）：下好的文件当场挪进缓存目录（回调一返回系统就把临时文件删了），结果交回 Precache
final class PrecacheSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    /// 任务编号 → （状态码、挪好的文件大小）：「下载完成」先到，「任务结束」后到，在后者里一起交回去
    private var results: [Int: (status: Int, size: Int64)] = [:]

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var size: Int64 = -1
        if status == 200, let p = PrecacheFiles.parse(downloadTask.taskDescription),
           FileManager.default.fileExists(atPath: PrecacheFiles.dir(p.id).path) {
            let dest = PrecacheFiles.file(p.id, p.rel)
            let fm = FileManager.default
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: location, to: dest)) != nil { size = PrecacheFiles.size(dest) }
        }
        lock.lock()
        results[downloadTask.taskIdentifier] = (status, size)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = PrecacheFiles.parse(task.taskDescription) else { return }
        lock.lock()
        let r = results.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        let status = r?.status ?? (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let size = r?.size ?? -1
        let cancelled = (error as? URLError)?.code == .cancelled
        let failed = error != nil || size < 0
        Task { @MainActor in
            Precache.shared.finished(id: p.id, rel: p.rel, status: status, size: size, failed: failed, cancelled: cancelled)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in Precache.shared.backgroundEventsDone() }
    }
}

/// 代理那边（PrecacheServer 的队列上）交回来的事
enum PrecacheEvents {
    static func requested(id: String, rel: String) {
        Task { @MainActor in Precache.shared.requested(id: id, rel: rel) }
    }

    static func relayed(id: String, rel: String, size: Int64) {
        Task { @MainActor in Precache.shared.relayed(id: id, rel: rel, size: size) }
    }
}

/// 「现已可供观看」的通知（本机通知，不经服务器）
enum PrecacheNotice {
    private static let presenter = PrecacheNoticePresenter()

    /// App 开着时也弹横幅（不设的话前台收不到）
    static func install() {
        UNUserNotificationCenter.current().delegate = presenter
    }

    /// 按「预先画面质量处理」时：系统还没问过就问一次（拒绝过的不再问，通知就不发）
    static func requestPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let s = await center.notificationSettings()
            guard s.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    static func ready(id: String, title: String) {
        let c = UNMutableNotificationContent()
        c.body = "《\(title)》现已可供观看，预先品质处理已经完成。"
        c.sound = .default
        c.threadIdentifier = "precache"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "precache-\(id)", content: c, trigger: nil))
    }
}

final class PrecacheNoticePresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
