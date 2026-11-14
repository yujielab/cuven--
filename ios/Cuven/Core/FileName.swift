import Foundation

/// 从文件名里读年份、片名与规格（4K / 杜比视界 / 全景声 …）。
/// 片名优先用 TMDB 的中文名；这里只是 TMDB 没回来时的兜底，以及按年份分组用。
enum FileName {
    private static let yearRegex = try! NSRegularExpression(pattern: "(?<![0-9A-Za-z])(19[2-9][0-9]|20[0-4][0-9])(?![0-9])")
    private static let cutRegex = try! NSRegularExpression(
        pattern: "(?i)[ ._\\-\\[(](2160p|1080p|720p|480p|4k|8k|uhd|bluray|blu-ray|web-?dl|webrip|hdtv|remux|hdr|dv|x26[45]|h\\.?26[45]|hevc|s[0-9]{1,2}e[0-9]{1,3}|s[0-9]{1,2}(?![0-9a-z]))")

    static func stem(_ name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    /// 年份取「最后一个」像年份的数：1917.2019 取 2019，Blade.Runner.2049.2017 取 2017
    static func year(_ name: String) -> Int? {
        let s = stem(name)
        let ns = s as NSString
        let ms = yearRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard let m = ms.last else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    /// 片名：年份（或第一个规格词）之前那一截，点与下划线换成空格
    static func title(_ name: String) -> String {
        let s = stem(name)
        let ns = s as NSString
        var end = ns.length
        let ms = yearRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if let m = ms.last, m.range.location > 0 { end = min(end, m.range.location) }
        if let c = cutRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), c.range.location > 0 {
            end = min(end, c.range.location)
        }
        var t = ns.substring(to: end)
        t = t.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -([").union(.whitespaces))
        return t.isEmpty ? s : t
    }

    /// 详情页的规格徽标（首页 / 列表不出，见网页版的规矩）
    static func specs(_ name: String) -> [String] {
        let n = name.lowercased()
        func has(_ p: String) -> Bool { n.range(of: p, options: .regularExpression) != nil }
        var out: [String] = []
        if has("(^|[^0-9])(4320p|8k)([^0-9a-z]|$)") { out.append("8K") }
        else if has("(^|[^0-9])(2160p|4k|uhd)([^0-9a-z]|$)") { out.append("4K") }
        else if has("1080p") { out.append("1080p") }
        if has("(^|[^a-z])(dv|dovi|dolby[ ._]?vision)([^a-z]|$)") { out.append("杜比视界") }
        if has("hdr10\\+|hdr10plus") { out.append("HDR10+") }
        else if has("(^|[^a-z])hdr(10)?([^a-z]|$)") { out.append("HDR") }
        if has("atmos") { out.append("杜比全景声") }
        else if has("truehd") { out.append("TrueHD") }
        else if has("dts[ ._-]?(hd|x)") { out.append("DTS-HD") }
        if has("remux") { out.append("REMUX") }
        if has("imax") { out.append("IMAX") }
        return out
    }

    static let playableExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "ts", "m2ts", "avi", "webm"]

    static func isVideo(_ name: String) -> Bool {
        playableExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

enum Format {
    static func size(_ bytes: Int64?) -> String {
        guard let b = bytes, b > 0 else { return "" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    static func runtime(_ minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return "" }
        let h = m / 60, r = m % 60
        if h > 0 && r > 0 { return "\(h) 小时 \(r) 分钟" }
        if h > 0 { return "\(h) 小时" }
        return "\(r) 分钟"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func relative(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "\(days) 天前" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日"
        return f.string(from: date)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return iso.date(from: s)
    }
}

/// TMDB 图片换尺寸：后端给的是 w342 / w780 / w1280 / w500，按要显示的像素换一档
enum TMDBImage {
    static func url(_ raw: String?, _ size: String) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.contains("image.tmdb.org") && !raw.lowercased().hasSuffix(".svg") {
            let swapped = raw.replacingOccurrences(of: "/t/p/(original|w[0-9]+|h[0-9]+)/", with: "/t/p/\(size)/", options: .regularExpression)
            return URL(string: swapped)
        }
        if raw.hasPrefix("/") { return URL(string: "https://image.tmdb.org/t/p/\(size)\(raw)") }
        return URL(string: raw)
    }
}

/// Apple 图床（mzstatic）的地址：末尾一段是「宽x高[裁切码].格式」，图床按这段现做（与 Worker 的 atvFill 同一个规矩）。
/// 换一个宽度、按原比例算高，就能要到合适大小的图：卡片要小图，全屏头部要大图（F62：按 点 × 屏幕倍率 要像素）
enum AppleImage {
    private static let tail = try! NSRegularExpression(pattern: "/([0-9]+)x([0-9]+)([A-Za-z]*)\\.([A-Za-z0-9]+)$")

    static func sized(_ raw: String?, width: Int) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard width > 0, raw.contains("mzstatic.com") else { return raw }
        let ns = raw as NSString
        guard let m = tail.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              let w = Int(ns.substring(with: m.range(at: 1))), let h = Int(ns.substring(with: m.range(at: 2))),
              w > 0, h > 0 else { return raw }
        let nh = Int((Double(width) * Double(h) / Double(w)).rounded())
        let code = ns.substring(with: m.range(at: 3)), ext = ns.substring(with: m.range(at: 4))
        return ns.replacingCharacters(in: m.range, with: "/\(width)x\(nh)\(code).\(ext)")
    }
}
