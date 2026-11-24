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
//
// 增强级（用户要求「允许启用增强级兼容性设置，想办法 fix」：截图是「播放失败 · 当前显示屏不支持这部影片的画面格式（4K 或 HDR）」，
// 也就是 AVFoundation -11868：系统按主列表里写的规格挑，挑不出一个「这块屏放得了」的版本，连解码都不试就拒播）。
// 在标准级的基础上再多做几件事，还是只改「标记」、不动画面数据：
//   · 主列表：去掉 VIDEO-RANGE（HDR / 杜比视界的标记：系统照它判断屏幕支不支持）、HDCP-LEVEL、ALLOWED-CPC（外接屏、隔空播放没有
//     HDCP 时整条拒播）；RESOLUTION 写成不超过 1920 宽（按比例）、BANDWIDTH 不超过 40 Mbps、FRAME-RATE 不超过 60；
//     杜比视界 8 档的 CODECS 换成它的 HDR10 基础层（hvc1），5 档照旧（5 档没有能单独看的基础层）
//   · 初始化分段：杜比视界 8 档的样本入口 dvh1 / dvhe 改名 hvc1 / hev1、dvcC / dvvC 改名 free —— 解码器把它当普通的
//     HEVC HDR10（8.1）/ HLG（8.4）/ SDR（8.2）放，系统照常把 HDR 映射到这块屏的亮度
//   · 播放器：外接显示器、隔空播放开着时画面仍在本机放（不交给外接屏去挑版本）
// 起播失败（不是网络错）时一档一档往上试：原样 → 标准 → 增强 → 这部片的另一个规格更低的版本（Player.swift）。

enum Compat {
    /// 以前的开关（开 / 关）：用户开关过的照旧认
    static let key = "cuven_compat_mode"
    /// 现在的档位：关闭 / 标准 / 增强
    static let levelKey = "cuven_compat_level"

    enum Level: String, CaseIterable, Identifiable, Comparable {
        case off, standard, enhanced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "关闭"
            case .standard: "标准"
            case .enhanced: "增强"
            }
        }
        private var order: Int { self == .off ? 0 : (self == .standard ? 1 : 2) }
        static func < (a: Level, b: Level) -> Bool { a.order < b.order }
    }

    /// 现在的档位（没选过 = 按机型：旧机型标准，别的关闭；以前只开关过的：开 = 标准）
    static var level: Level {
        get {
            let d = UserDefaults.standard
            if let s = d.string(forKey: levelKey), let l = Level(rawValue: s) { return l }
            if d.object(forKey: key) != nil { return d.bool(forKey: key) ? .standard : .off }
            return legacyDevice ? .standard : .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: levelKey)
            UserDefaults.standard.set(newValue != .off, forKey: key)
        }
    }

    /// 开着没有（标准或增强）
    static var isOn: Bool { level != .off }

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

    /// 主列表：改 CODECS、去掉 SUPPLEMENTAL-CODECS（增强级再去掉 HDR / HDCP 的标记、把分辨率和码率写小）；
    /// 视频的二级列表走代理（proxy + 相对地址），别的地址一律补成绝对的（base）
    static func master(_ text: String, base: URL, proxy: String, enhanced: Bool = false) -> String {
        var out: [String] = []
        var nextIsVideo = false
        for raw in text.components(separatedBy: "\n") {
            var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("#EXT-X-STREAM-INF:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                // I 帧列表不走代理（它的初始化分段还是杜比的样本入口）：CODECS 只照标准级改，杜比 8 档不改成 hvc1
                let iframe = line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                line = enhanced && !iframe ? rewriteCodecsEnhanced(line) : rewriteCodecs(line)
                // 不管排在第几个都去掉（以前只认前面有逗号的）
                line = dropBareAttribute("SUPPLEMENTAL-CODECS", in: line)
                if enhanced { line = relax(line) }
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

    /// 原地改 hvcC / dvcC，dvvC 改名 free（只在样本入口是 hvc1 / hev1 的时候：入口是 dvh1 的 8 档还得靠它）。
    /// 增强级：杜比视界 8 档先把样本入口改成普通 HEVC、杜比配置改名 free（按 HDR10 / HLG / SDR 基础层放）
    static func patchInit(_ input: Data, enhanced: Bool = false) -> Data {
        var d = [UInt8](input)
        if enhanced, dvProfile(d) == 8 { demoteProfile8(&d) }
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
        // 文件头 ftyp 整个跳过：里面的兼容品牌（可能正好是 dvh1 / hvc1）不是盒子，前面的 minor_version 又可能被当成盒子的长度
        if d.count >= 8, d[4] == 0x66, d[5] == 0x74, d[6] == 0x79, d[7] == 0x70 {
            let s = Int(d[0]) << 24 | Int(d[1]) << 16 | Int(d[2]) << 8 | Int(d[3])
            if s >= 8, s <= d.count { i = s + 4 }
        }
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

    /// 杜比视界档位（dvcC / dvvC 里的 dv_profile）；不是杜比视界 = nil
    static func dvProfile(_ d: [UInt8]) -> Int? {
        for t in ["dvcC", "dvvC"] {
            if let at = boxes(d, t).first, at.payload + 3 <= at.end { return Int(d[at.payload + 2] >> 1) }
        }
        return nil
    }

    /// 杜比视界 8 档 → 普通 HEVC：样本入口 dvh1 → hvc1、dvhe → hev1，dvcC / dvvC 改名 free（字节数不变）。
    /// 只认长度说得通的盒子（boxes 从 ftyp 后面开始找：文件头里的兼容品牌不会被当成盒子改掉）
    static func demoteProfile8(_ d: inout [UInt8]) {
        for (from, to) in [("dvh1", "hvc1"), ("dvhe", "hev1")] {
            for at in boxes(d, from) { d.replaceSubrange((at.payload - 4)..<at.payload, with: Array(to.utf8)) }
        }
        for t in ["dvcC", "dvvC"] {
            for at in boxes(d, t) { d.replaceSubrange((at.payload - 4)..<at.payload, with: Array("free".utf8)) }
        }
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

    /// 增强级的 CODECS：先照标准级改；杜比视界 8 档（dvh1.08.xx / dvhe.08.xx）换成 HDR10 基础层的 HEVC Main 10
    ///（同一行里已经有 hvc1 / hev1 的就只去掉杜比那一项）
    static func codecsEnhanced(_ v: String) -> String {
        let list = v.split(separator: ",").map { codec(String($0).trimmingCharacters(in: .whitespaces)) }
        let hasHevc = list.contains { $0.hasPrefix("hvc1") || $0.hasPrefix("hev1") }
        var out: [String] = []
        for c in list {
            let p = c.split(separator: ".")
            if p.count >= 2, p[0] == "dvh1" || p[0] == "dvhe", Int(p[1]) == 8 {
                // 和初始化分段里改的样本入口一致：dvh1 → hvc1、dvhe → hev1。Level 按上限写（4K 片子本来就要 5.1；1080p 的写高了也只是标记）
                if !hasHevc { out.append("\(p[0] == "dvhe" ? "hev1" : "hvc1").2.4.L\(maxHevcLevel).B0") }
                continue
            }
            out.append(c)
        }
        return out.joined(separator: ",")
    }

    private static func rewriteCodecsEnhanced(_ line: String) -> String {
        replaceAttribute("CODECS", in: line) { codecsEnhanced($0) }
    }

    /// 增强级：去掉系统拿来判断「这块屏放不放得了」的标记，分辨率、码率、帧率写成一般的屏都认的范围（只是标记，画面不变）
    static func relax(_ line: String) -> String {
        var l = line
        // 杜比视界 5 档没有能单独看的基础层：VIDEO-RANGE=PQ 是它的规定写法，去掉了反而成了「SDR 的杜比视界」，留着
        let p5 = line.contains("dvh1.05") || line.contains("dvhe.05")
        for a in ["VIDEO-RANGE", "HDCP-LEVEL", "ALLOWED-CPC", "REQ-VIDEO-LAYOUT"] where !(p5 && a == "VIDEO-RANGE") {
            l = dropBareAttribute(a, in: l)
        }
        l = replaceBare("RESOLUTION", in: l) { v in
            let wh = v.lowercased().split(separator: "x").compactMap { Int($0) }
            guard wh.count == 2, wh[0] > 1920 else { return v }
            return "1920x\(Int((Double(wh[1]) * 1920 / Double(wh[0])).rounded()) & ~1)"
        }
        for a in ["BANDWIDTH", "AVERAGE-BANDWIDTH"] {
            l = replaceBare(a, in: l) { v in Int(v).map { String(min($0, 40_000_000)) } ?? v }
        }
        l = replaceBare("FRAME-RATE", in: l) { v in Double(v).map { $0 > 60 ? "60.000" : v } ?? v }
        return l
    }

    /// 属性的起点（前一个字符是 : 或 ,，免得把 AVERAGE-BANDWIDTH 当成 BANDWIDTH；引号里面的不算，比如 URI 里的查询参数）
    private static func attributeStart(_ name: String, in line: String) -> Range<String.Index>? {
        var from = line.startIndex
        while let r = line.range(of: name + "=", range: from..<line.endIndex) {
            if r.lowerBound > line.startIndex {
                let prev = line[line.index(before: r.lowerBound)]
                let quotes = line[line.startIndex..<r.lowerBound].reduce(0) { $1 == "\"" ? $0 + 1 : $0 }
                if (prev == ":" || prev == ","), quotes % 2 == 0 { return r }
            }
            from = r.upperBound
        }
        return nil
    }

    /// 属性值的范围（带引号的取到下一个引号，不带的取到下一个逗号）
    private static func valueRange(after r: Range<String.Index>, in line: String) -> Range<String.Index> {
        if r.upperBound < line.endIndex, line[r.upperBound] == "\"" {
            let vs = line.index(after: r.upperBound)
            let close = line[vs...].firstIndex(of: "\"").map { line.index(after: $0) } ?? line.endIndex
            return r.upperBound..<close
        }
        let end = line[r.upperBound...].firstIndex(of: ",") ?? line.endIndex
        return r.upperBound..<end
    }

    /// 去掉一个属性（带不带引号都行），连同它前面的逗号（它是第一个时连同后面的逗号）
    static func dropBareAttribute(_ name: String, in line: String) -> String {
        guard let r = attributeStart(name, in: line) else { return line }
        let v = valueRange(after: r, in: line)
        let prev = line.index(before: r.lowerBound)
        if line[prev] == "," { return String(line[..<prev]) + String(line[v.upperBound...]) }
        // 第一个属性：去掉它和后面的逗号
        var after = v.upperBound
        if after < line.endIndex, line[after] == "," { after = line.index(after: after) }
        return String(line[..<r.lowerBound]) + String(line[after...])
    }

    /// 改一个不带引号的属性值
    static func replaceBare(_ name: String, in line: String, _ f: (String) -> String) -> String {
        guard let r = attributeStart(name, in: line) else { return line }
        let v = valueRange(after: r, in: line)
        let raw = String(line[v])
        guard !raw.hasPrefix("\"") else { return line }
        return String(line[..<v.lowerBound]) + f(raw) + String(line[v.upperBound...])
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
