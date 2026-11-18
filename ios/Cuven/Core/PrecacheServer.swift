import Foundation
import Network

// MARK: - 本机代理（只听 127.0.0.1）：「立即播放」时播放器从这里取这部片的 HLS
//
// 地址：http://127.0.0.1:<端口>/c/<影片编号>/<Worker 那边 /hls/<签名>/ 后面的那一截>。主列表、二级列表里都是相对地址，
// 播放器自己会拼到代理上，内容一个字不用改：
// · 本机有的（预先缓存下好的、之前边看边存下的）直接从本机出，支持 Range；
// · 没有的去 Worker 取，边转给播放器边写进缓存（下完整了才算数），下次就有了；
// · 主列表每次都问一次 Worker（在线字幕会变），问不到才用上次存下的；
// · 播放器要到了第几段视频，告诉 Precache：后台下载跟到那儿往后接着下（PrecacheEvents.requested）。
// 只接受本机的连接；不认识的路径、带「..」的一律 404。

final class PrecacheServer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = PrecacheServer()

    /// 所有状态都只在这条队列上动
    private let q = DispatchQueue(label: "us.cuven.precache.server")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var waiters: [CheckedContinuation<UInt16?, Never>] = []
    /// 影片编号 → Worker 那边的 /hls/<签名>/
    private var upstream: [String: URL] = [:]
    private var relays: [Int: Relay] = [:]

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 6
        let oq = OperationQueue()
        oq.maxConcurrentOperationCount = 1
        oq.underlyingQueue = q
        return URLSession(configuration: cfg, delegate: self, delegateQueue: oq)
    }()

    /// 一个边取边转的请求
    private final class Relay {
        let conn: NWConnection
        let id: String
        let rel: String
        let headOnly: Bool
        let ranged: Bool
        var part: URL?
        var out: FileHandle?
        var started = false
        var expected: Int64 = -1
        var received: Int64 = 0

        init(conn: NWConnection, id: String, rel: String, headOnly: Bool, ranged: Bool) {
            self.conn = conn
            self.id = id
            self.rel = rel
            self.headOnly = headOnly
            self.ranged = ranged
        }
    }

    /// 「bytes=0-1023」「bytes=100-」「bytes=-500」
    private struct ByteRange {
        var start: Int64?
        var end: Int64?
        var header: String

        init?(_ s: String) {
            let v = s.trimmingCharacters(in: .whitespaces)
            guard v.lowercased().hasPrefix("bytes="), !v.contains(",") else { return nil }
            let parts = v.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            start = Int64(parts[0].trimmingCharacters(in: .whitespaces))
            end = Int64(parts[1].trimmingCharacters(in: .whitespaces))
            guard start != nil || end != nil else { return nil }
            header = v
        }

        func resolve(size: Int64) -> (from: Int64, to: Int64)? {
            if let s = start {
                let e = min(end ?? size - 1, size - 1)
                return s <= e ? (s, e) : nil
            }
            guard let n = end, n > 0 else { return nil }
            return (max(0, size - n), size - 1)
        }
    }

    // MARK: 启动

    func setUpstream(id: String, base: URL) {
        q.async { self.upstream[id] = base }
    }

    /// 开起来（已经开着就直接给端口）；3 秒还没好就是 nil（这次走网上）
    func start() async -> UInt16? {
        await withCheckedContinuation { (c: CheckedContinuation<UInt16?, Never>) in
            q.async {
                if self.listener != nil, self.port != 0 {
                    c.resume(returning: self.port)
                    return
                }
                self.waiters.append(c)
                if self.listener == nil { self.listen() }
            }
        }
    }

    private func listen() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else {
            flush(nil)
            return
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            self.listenerChanged(state, l)
        }
        listener = l
        l.start(queue: q)
        q.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.port == 0 else { return }
            self.flush(nil)
        }
    }

    private func listenerChanged(_ state: NWListener.State, _ l: NWListener) {
        switch state {
        case .ready:
            port = l.port?.rawValue ?? 0
            flush(port == 0 ? nil : port)
        case .failed:
            // App 在后台被系统收了监听：下一次再开（换一个端口）
            if listener === l { listener = nil; port = 0 }
            l.cancel()
            flush(nil)
        case .cancelled:
            if listener === l { listener = nil; port = 0 }
            flush(nil)
        default:
            break
        }
    }

    private func flush(_ p: UInt16?) {
        let w = waiters
        waiters = []
        for c in w { c.resume(returning: p) }
    }

    // MARK: 一个连接

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 32 << 10) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data([13, 10, 13, 10])) {
                self.handle(c, String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil || buf.count > 64 << 10 {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private func handle(_ c: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count >= 2 else { return status(c, 400) }
        let method = first[0].uppercased()
        guard method == "GET" || method == "HEAD" else { return status(c, 405) }
        let headOnly = method == "HEAD"
        var range: ByteRange?
        for l in lines.dropFirst() where l.lowercased().hasPrefix("range:") {
            range = ByteRange(String(l.dropFirst(6)))
        }
        let path = first[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let comps = path.split(separator: "/").map(String.init)
        guard comps.count >= 3, comps[0] == "c" else { return status(c, 404) }
        let id = comps[1], rel = comps.dropFirst(2).joined(separator: "/")
        guard !id.isEmpty, id.allSatisfy(\.isHexDigit), PrecacheFiles.safe(rel), !rel.hasSuffix(".part") else { return status(c, 404) }
        if rel == "master.m3u8" { return master(c, id: id, headOnly: headOnly) }
        if rel.contains("/v/") { PrecacheEvents.requested(id: id, rel: rel) }
        let file = PrecacheFiles.file(id, rel)
        if FileManager.default.fileExists(atPath: file.path) {
            serve(c, file, rel: rel, range: range, headOnly: headOnly)
        } else {
            relay(c, id: id, rel: rel, range: range, headOnly: headOnly)
        }
    }

    // MARK: 本机有的：从文件出

    private func serve(_ c: NWConnection, _ url: URL, rel: String, range: ByteRange?, headOnly: Bool) {
        let size = PrecacheFiles.size(url)
        guard size > 0, let fh = try? FileHandle(forReadingFrom: url) else { return status(c, 404) }
        var from: Int64 = 0, to = size - 1, partial = false
        if let range {
            guard let r = range.resolve(size: size) else {
                try? fh.close()
                return status(c, 416, extra: "Content-Range: bytes */\(size)\r\n")
            }
            from = r.from
            to = r.to
            partial = true
        }
        var h = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        h += "Content-Type: \(Self.type(rel))\r\nContent-Length: \(to - from + 1)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        if partial { h += "Content-Range: bytes \(from)-\(to)/\(size)\r\n" }
        h += "\r\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        guard !headOnly else {
            try? fh.close()
            return close(c)
        }
        do { try fh.seek(toOffset: UInt64(from)) } catch {
            try? fh.close()
            return c.cancel()
        }
        pumpFile(c, fh, left: to - from + 1)
    }

    /// 一次 256 KB，发完一块再读下一块（大分段不整个读进内存）
    private func pumpFile(_ c: NWConnection, _ fh: FileHandle, left: Int64) {
        guard left > 0 else {
            try? fh.close()
            return close(c)
        }
        let chunk = try? fh.read(upToCount: Int(min(left, 256 << 10)))
        guard let data = chunk, !data.isEmpty else {
            try? fh.close()
            return c.cancel()
        }
        c.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self, err == nil else {
                try? fh.close()
                c.cancel()
                return
            }
            self.pumpFile(c, fh, left: left - Int64(data.count))
        })
    }

    // MARK: 主列表：每次问 Worker，问不到用存下的

    private func master(_ c: NWConnection, id: String, headOnly: Bool) {
        let saved = PrecacheFiles.file(id, "master.m3u8")
        guard let base = upstream[id] else {
            if FileManager.default.fileExists(atPath: saved.path) {
                serve(c, saved, rel: "master.m3u8", range: nil, headOnly: headOnly)
            } else {
                status(c, 503)
            }
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("master.m3u8"))
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            self.q.async {
                if ok, let data {
                    if FileManager.default.fileExists(atPath: PrecacheFiles.dir(id).path) {
                        try? data.write(to: saved, options: .atomic)
                    }
                    self.send(c, data, type: "application/vnd.apple.mpegurl", headOnly: headOnly)
                } else if FileManager.default.fileExists(atPath: saved.path) {
                    self.serve(c, saved, rel: "master.m3u8", range: nil, headOnly: headOnly)
                } else {
                    self.status(c, 502)
                }
            }
        }.resume()
    }

    // MARK: 本机没有的：去 Worker 取，边转边存

    private func relay(_ c: NWConnection, id: String, rel: String, range: ByteRange?, headOnly: Bool) {
        guard let base = upstream[id] else { return status(c, 503) }
        var req = URLRequest(url: base.appendingPathComponent(rel))
        req.timeoutInterval = 30
        if headOnly { req.httpMethod = "HEAD" }
        if let range { req.setValue(range.header, forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: req)
        relays[task.taskIdentifier] = Relay(conn: c, id: id, rel: rel, headOnly: headOnly, ranged: range != nil)
        // 播放器那头断了（跳走、关掉）：上游也停
        c.stateUpdateHandler = { [weak task] st in
            switch st {
            case .failed, .cancelled: task?.cancel()
            default: break
            }
        }
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let r = relays[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let code = http.statusCode
        let reason = code == 200 ? "OK" : (code == 206 ? "Partial Content" : "Upstream")
        var h = "HTTP/1.1 \(code) \(reason)\r\n"
        h += "Content-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? Self.type(r.rel))\r\n"
        // 压缩过的（Cloudflare 给播放列表压 gzip）：拿到的是解开以后的，长度对不上，不写长度、靠关连接结束
        let encoded = !(http.value(forHTTPHeaderField: "Content-Encoding") ?? "").isEmpty
        if !encoded, response.expectedContentLength >= 0 {
            h += "Content-Length: \(response.expectedContentLength)\r\n"
            r.expected = response.expectedContentLength
        }
        if let cr = http.value(forHTTPHeaderField: "Content-Range") { h += "Content-Range: \(cr)\r\n" }
        h += "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        r.conn.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        r.started = true
        if code == 200, !r.ranged, !r.headOnly, FileManager.default.fileExists(atPath: PrecacheFiles.dir(r.id).path) {
            let part = PrecacheFiles.file(r.id, r.rel + ".part")
            try? FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.createFile(atPath: part.path, contents: nil) {
                r.part = part
                r.out = try? FileHandle(forWritingTo: part)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let r = relays[dataTask.taskIdentifier] else { return }
        r.received += Int64(data.count)
        if !r.headOnly { r.conn.send(content: data, completion: .contentProcessed { _ in }) }
        if let out = r.out {
            do { try out.write(contentsOf: data) } catch {
                try? out.close()
                r.out = nil
                if let part = r.part { try? FileManager.default.removeItem(at: part) }
                r.part = nil
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let r = relays.removeValue(forKey: task.taskIdentifier) else { return }
        try? r.out?.close()
        if let part = r.part {
            let complete = error == nil && r.received > 0 && (r.expected < 0 || r.received == r.expected)
            let dest = PrecacheFiles.file(r.id, r.rel)
            if complete, FileManager.default.fileExists(atPath: PrecacheFiles.dir(r.id).path) {
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.moveItem(at: part, to: dest)) != nil {
                    PrecacheEvents.relayed(id: r.id, rel: r.rel, size: r.received)
                } else {
                    try? FileManager.default.removeItem(at: part)
                }
            } else {
                try? FileManager.default.removeItem(at: part)
            }
        }
        if r.started { close(r.conn) } else { status(r.conn, 502) }
    }

    // MARK: 回应

    private func send(_ c: NWConnection, _ data: Data, type: String, headOnly: Bool) {
        let h = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        if !headOnly { c.send(content: data, completion: .contentProcessed { _ in }) }
        close(c)
    }

    private func status(_ c: NWConnection, _ code: Int, extra: String = "") {
        let reasons = [400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable",
                       502: "Bad Gateway", 503: "Service Unavailable"]
        let h = "HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Length: 0\r\nConnection: close\r\n\(extra)\r\n"
        c.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        close(c)
    }

    /// 发完再关：最后一条消息发出去以后断开
    private func close(_ c: NWConnection) {
        c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    /// 本机出文件时的类型：音轨（a<i> / t<i>）是 audio/mp4，视频是 video/mp4
    private static func type(_ rel: String) -> String {
        if rel.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if rel.hasSuffix(".vtt") { return "text/vtt" }
        if rel.hasSuffix(".json") { return "application/json" }
        if rel.hasSuffix(".mp4") || rel.hasSuffix(".m4s") {
            let parts = rel.split(separator: "/")
            let track = parts.count >= 2 ? parts[1] : ""
            return track.hasPrefix("a") || track.hasPrefix("t") ? "audio/mp4" : "video/mp4"
        }
        return "application/octet-stream"
    }
}
