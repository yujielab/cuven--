import Foundation
#if canImport(Metal)
import Metal
#endif

// MARK: - 改进兼容性（用户要求：iPad（第 9 代）和更早的机型放不了片子；设置里随时开关）
//
// 为什么放不了：片库里大多是 4K HEVC / 杜比视界，片源在 HLS 主列表和初始化分段里标的规格经常超出苹果的
// HLS 规范（HEVC 最高 Main 10 · Level 5.1；杜比视界最高 Profile 5 · Level 7）——编码器爱把 4K24 标成 Level 6.0 / 6.1，
// 60 帧的杜比视界标 Level 8 / 9。新机型的系统不跟这些标记较真，A13 及更早的芯片照着标记判断「解不了」，直接拒播。
//
// 打开以后，播放经过本机代理（PrecacheServer 的 /x/ 路径），只改「标记」、不动画面数据：
//   · 主列表：CODECS 里的 HEVC 改成 Main tier、Level 不超过 5.1；杜比视界 5 档的 Level 不超过 7；
//     去掉 SUPPLEMENTAL-CODECS（杜比视界 8 档按 HDR10 播 —— 基础层本来就是标准 HDR10）；
//   · 初始化分段（v.mp4）：hvcC 的 tier / level（连同里面 VPS、SPS 的 profile_tier_level）、dvcC 的 level 原地改，
//     dvvC（8 档的杜比配置）改名成 free 让播放器忽略。字节数一个不变，分段照旧直接从 Worker（或预先缓存的代理）取。
// 默认：认出是旧机型（GPU 不到 Apple 7 代 = A14，或者内存不到 3.5 GB）就开，别的机型关；用户开关过以后一律听用户的。
// 没开的机型起播失败、而且不是网络错时，也会自动按兼容方式再试一次（Player.swift）。

enum Compat {
    static let key = "cuven_compat_mode"

    /// 现在开着没有（没选过 = 按机型）
    static var isOn: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil ? legacyDevice : d.bool(forKey: key)
    }

    /// 这台是不是旧机型
    static let legacyDevice: Bool = {
        #if targetEnvironment(simulator) || !canImport(Metal)
        return false
        #else
        let oldGPU = MTLCreateSystemDefaultDevice().map { !$0.supportsFamily(.apple7) } ?? true
        let smallRAM = ProcessInfo.processInfo.physicalMemory < 3_500_000_000
        return oldGPU || smallRAM
        #endif
    }()
}

// MARK: - 改标记（纯函数，PrecacheServer 调用）

enum CompatHLS {
    /// HEVC 的 level_idc 上限：5.1（3840 × 2160 · 60 帧够用）
    static let maxHevcLevel = 153
    /// 杜比视界的 level 上限：苹果规范是 7
    static let maxDvLevel = 7

    /// CODECS 里的一项
    static func codec(_ c: String) -> String {
        let p = c.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if p.count >= 4, p[0] == "hvc1" || p[0] == "hev1", let t = p[3].first, t == "L" || t == "H", let lv = Int(p[3].dropFirst()) {
            var q = p
            q[3] = "L\(min(lv, maxHevcLevel))"
            return q.joined(separator: ".")
        }
        if p.count == 3, p[0] == "dvh1" || p[0] == "dvhe", let lv = Int(p[2]) {
            return "\(p[0]).\(p[1]).\(String(format: "%02d", min(lv, maxDvLevel)))"
        }
        return c
    }

    /// 主列表：改 CODECS、去掉 SUPPLEMENTAL-CODECS；视频的二级列表走代理（proxy + 相对地址），别的地址一律补成绝对的（base）
    static func master(_ text: String, base: URL, proxy: String) -> String {
        var out: [String] = []
        var nextIsVideo = false
        for raw in text.components(separatedBy: "\n") {
            var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("#EXT-X-STREAM-INF:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                line = rewriteCodecs(line)
                line = dropAttribute("SUPPLEMENTAL-CODECS", in: line)
                if line.hasPrefix("#EXT-X-STREAM-INF:") { nextIsVideo = true }
                else { line = rewriteURIs(line) { absolute($0, base) } }
            } else if line.hasPrefix("#") {
                line = rewriteURIs(line) { absolute($0, base) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if nextIsVideo, !isAbsolute(line) { line = proxy + line } else { line = absolute(line, base) }
                nextIsVideo = false
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// 视频的二级列表：初始化分段走代理，媒体分段补成绝对地址（直接去取）。dir：这个列表所在的目录（相对主列表）
    static func media(_ text: String, base: URL, dir: String, proxy: String) -> String {
        let here = URL(string: dir.isEmpty ? "" : dir + "/", relativeTo: base)?.absoluteURL ?? base
        var out: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("#EXT-X-MAP:") {
                line = rewriteURIs(line) { u in isAbsolute(u) ? u : proxy + (dir.isEmpty ? "" : dir + "/") + u }
            } else if line.hasPrefix("#") {
                line = rewriteURIs(line) { absolute($0, here) }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                line = absolute(line, here)
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: 初始化分段

    /// 原地改 hvcC / dvcC，dvvC 改名 free（只在样本入口是 hvc1 / hev1 的时候：入口是 dvh1 的 8 档还得靠它）
    static func patchInit(_ input: Data) -> Data {
        var d = [UInt8](input)
        let dvEntry = find(d, "dvh1") != nil || find(d, "dvhe") != nil
        for at in boxes(d, "hvcC") { patchHvcC(&d, at.payload, at.end) }
        for at in boxes(d, "dvcC") { patchDvLevel(&d, at.payload, at.end) }
        for at in boxes(d, "dvvC") {
            if dvEntry { patchDvLevel(&d, at.payload, at.end) }
            else { d.replaceSubrange((at.payload - 4)..<at.payload, with: Array("free".utf8)) }
        }
        return Data(d)
    }

    /// 某种盒子出现的地方（payload：盒子内容的起点；end：盒子结尾）。前面 4 个字节的大小要说得通才算
    static func boxes(_ d: [UInt8], _ type: String) -> [(payload: Int, end: Int)] {
        let t = Array(type.utf8)
        var r: [(Int, Int)] = []
        var i = 4
        while i + 4 <= d.count {
            if d[i] == t[0], d[i + 1] == t[1], d[i + 2] == t[2], d[i + 3] == t[3] {
                let size = Int(d[i - 4]) << 24 | Int(d[i - 3]) << 16 | Int(d[i - 2]) << 8 | Int(d[i - 1])
                if size >= 8, i - 4 + size <= d.count { r.append((i + 4, i - 4 + size)); i += size - 4; continue }
            }
            i += 1
        }
        return r
    }

    private static func find(_ d: [UInt8], _ type: String) -> Int? { boxes(d, type).first?.payload }

    /// hvcC：tier 改 Main、level 不超过 5.1；数组里的 VPS（RBSP 第 4 字节起）、SPS（第 1 字节起）的 profile_tier_level 同样改
    static func patchHvcC(_ d: inout [UInt8], _ p: Int, _ end: Int) {
        guard p + 23 <= end, d[p] == 1 else { return }
        d[p + 1] &= ~0x20
        if Int(d[p + 12]) > maxHevcLevel { d[p + 12] = UInt8(maxHevcLevel) }
        var i = p + 23
        let arrays = Int(d[p + 22])
        for _ in 0..<arrays {
            guard i + 3 <= end else { return }
            let type = Int(d[i] & 0x3f)
            let n = Int(d[i + 1]) << 8 | Int(d[i + 2])
            i += 3
            for _ in 0..<n {
                guard i + 2 <= end else { return }
                let len = Int(d[i]) << 8 | Int(d[i + 1])
                let nal = i + 2
                guard nal + len <= end else { return }
                // nuh_layer_id 不是 0 的（多层扩展）不动
                let layer = len >= 2 ? (Int(d[nal] & 1) << 5 | Int(d[nal + 1] >> 3)) : 1
                if layer == 0, type == 32 { patchPTL(&d, nal: nal, len: len, at: 4) }
                if layer == 0, type == 33 { patchPTL(&d, nal: nal, len: len, at: 1) }
                i = nal + len
            }
        }
    }

    /// NAL（带 2 字节头、带防竞争字节）里 RBSP 第 at 个字节起是 general profile_tier_level：那一字节清 tier 位，往后第 11 字节是 level
    static func patchPTL(_ d: inout [UInt8], nal: Int, len: Int, at: Int) {
        guard let prof = escaped(d, nal: nal, len: len, rbsp: at), let lvl = escaped(d, nal: nal, len: len, rbsp: at + 11) else { return }
        d[prof] &= ~0x20
        if Int(d[lvl]) > maxHevcLevel { d[lvl] = UInt8(maxHevcLevel) }
    }

    /// RBSP 第 k 个字节在 NAL 里的位置（跳过 00 00 03 里的 03）
    static func escaped(_ d: [UInt8], nal: Int, len: Int, rbsp k: Int) -> Int? {
        var zeros = 0, r = 0, i = nal + 2
        while i < nal + len {
            let b = d[i]
            if zeros >= 2, b == 3 { zeros = 0; i += 1; continue }
            if r == k { return i }
            zeros = b == 0 ? zeros + 1 : 0
            r += 1
            i += 1
        }
        return nil
    }

    /// DOVIDecoderConfigurationRecord：第 2、3 字节是 profile(7) level(6) rpu el bl
    static func patchDvLevel(_ d: inout [UInt8], _ p: Int, _ end: Int) {
        guard p + 4 <= end else { return }
        var v = Int(d[p + 2]) << 8 | Int(d[p + 3])
        let level = (v >> 3) & 0x3f
        guard level > maxDvLevel else { return }
        v = (v & ~(0x3f << 3)) | (maxDvLevel << 3)
        d[p + 2] = UInt8(v >> 8)
        d[p + 3] = UInt8(v & 0xff)
    }

    // MARK: 列表里的属性

    private static func rewriteCodecs(_ line: String) -> String {
        replaceAttribute("CODECS", in: line) { v in v.split(separator: ",").map { codec(String($0)) }.joined(separator: ",") }
    }

    private static func replaceAttribute(_ name: String, in line: String, _ f: (String) -> String) -> String {
        guard let r = line.range(of: name + "=\"") else { return line }
        // 前一个字符得是 : 或 ,（别把 SUPPLEMENTAL-CODECS 当成 CODECS）
        if r.lowerBound > line.startIndex {
            let prev = line[line.index(before: r.lowerBound)]
            if prev != ":" && prev != "," {
                guard let next = line.range(of: "," + name + "=\"", range: r.upperBound..<line.endIndex) else { return line }
                return replaceAt(line, line.index(after: next.lowerBound), name, f)
            }
        }
        return replaceAt(line, r.lowerBound, name, f)
    }

    private static func replaceAt(_ line: String, _ start: String.Index, _ name: String, _ f: (String) -> String) -> String {
        let vStart = line.index(start, offsetBy: name.count + 2)
        guard let close = line[vStart...].firstIndex(of: "\"") else { return line }
        return String(line[..<vStart]) + f(String(line[vStart..<close])) + String(line[close...])
    }

    private static func dropAttribute(_ name: String, in line: String) -> String {
        guard let r = line.range(of: "," + name + "=\"") else { return line }
        let vStart = r.upperBound
        guard let close = line[vStart...].firstIndex(of: "\"") else { return line }
        return String(line[..<r.lowerBound]) + String(line[line.index(after: close)...])
    }

    private static func rewriteURIs(_ line: String, _ f: (String) -> String) -> String {
        var out = ""
        var rest = Substring(line)
        while let r = rest.range(of: "URI=\"") {
            out += rest[..<r.upperBound]
            let after = rest[r.upperBound...]
            guard let close = after.firstIndex(of: "\"") else { return out + after }
            out += f(String(after[..<close]))
            rest = after[close...]
        }
        return out + rest
    }

    private static func isAbsolute(_ u: String) -> Bool { u.hasPrefix("http://") || u.hasPrefix("https://") }

    private static func absolute(_ u: String, _ base: URL) -> String {
        isAbsolute(u) ? u : (URL(string: u, relativeTo: base)?.absoluteString ?? u)
    }
}
