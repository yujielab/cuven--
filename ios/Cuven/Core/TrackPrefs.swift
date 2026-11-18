import AVFoundation
import os

// MARK: - 字幕与音轨首选项（用户要求「允许设置字幕和音轨首选项」）
//
// 账户页「播放」里选；正片每个片源（换下一集也算）一挂上就按它挑一次，挑了就真的选上（用户要求「iOS 内建播放器默认打开首选字幕、
// 默认播放首选项音轨」）——「自动」也一样，不再交给系统：系统的自动选择按手机的语言挑音轨（中文手机会放国语配音，
// 不是片源默认的原声），字幕只开「强制」那种（不说话的部分才有字），服务器标成默认的中文字幕不会自己打开。
// · 音轨：「自动」是片源默认的那条（播放列表里 DEFAULT=YES 的，Worker 标的是片子里默认的那条，通常是原声）；
//   选了语种的：第一条语言对得上的（跳过评论音轨、口述影像），没有就片源默认的；
// · 「自然」（用户要求「自然模式下使用影片原始发行 / 制作地区的语言做为首选音轨，如果没有则降级到英文」）：
//   先放原声——TMDB 给的原始语言（TMDB 把粤语记成 cn；记成 zh、只在香港出品的，粤语排在国语前面）；
//   老结果里没有原始语言就按原名的文字猜（韩文、日文假名、泰文……；只有汉字算国语，拉丁字母猜不出就不猜）；
//   没有原声那条再找轨道名写着「原声 / Original」的，再没有用英语，都没有就片源默认的；
// · 字幕：「自动」打开服务器标成默认的那条（Worker 按「片子自带的中文优先，没有再用在线字幕」标的；直连的 MP4 没有标，
//   照同一个顺序自己挑：简体 > 中文 > 在线中文 > 繁体 > 粤语 > 在线的别的语言），一条中文都没有就不开；
//   选了语种的：语言最对得上的那条（不挑「强制」字幕；同样对得上时片子自带的排在在线找来的前面），没有就照「自动」挑的；
//   「关闭」是不显示字幕。
// 系统的自动选择可能在片源「可以播了」时又改一遍：播放器在那一刻和开播那一刻各对一次（reassert），被改了就改回来。
// 只在开始时挑；开播以后在系统播放器里手动换的不动。
// 语言按 HLS 播放列表里的 LANGUAGE 认：Worker 给的是 BCP-47（zh / zh-Hans / zh-Hant / yue / en / ja / ko …），
// 中文音轨按轨道名分出了粤语；字幕抽样认出繁体的已经标成 zh-Hant。直连的 MP4 是文件里写的（常是 eng / jpn 这种三个字母的）。

enum TrackPrefs {
    static let audioKey = "cuven_pref_audio"
    static let subtitleKey = "cuven_pref_subtitle"

    enum Audio: String, CaseIterable, Identifiable {
        case auto, natural, mandarin, cantonese, english, japanese, korean

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "自动"
            case .natural: return "自然"
            case .mandarin: return "国语"
            case .cantonese: return "粤语"
            case .english: return "英语"
            case .japanese: return "日语"
            case .korean: return "韩语"
            }
        }

        /// 账户页那一行下面的灰字
        var hint: String {
            switch self {
            case .auto: return "影片默认音轨，通常是原声"
            case .natural: return "优先原产地语言，其次英语"
            default: return "优先\(label)，没有时用默认音轨"
            }
        }

        func matches(_ tag: String) -> Bool {
            let t = tag.lowercased()
            func lang(_ code: String) -> Bool { t == code || t.hasPrefix(code + "-") || t.hasPrefix(code + "_") }
            switch self {
            case .auto, .natural: return false
            case .mandarin: return (lang("zh") || lang("cmn") || lang("chi") || lang("zho")) && !t.contains("yue")
            case .cantonese: return lang("yue") || t == "zh-yue"
            case .english: return lang("en") || lang("eng")
            case .japanese: return lang("ja") || lang("jpn")
            case .korean: return lang("ko") || lang("kor")
            }
        }
    }

    enum Subtitle: String, CaseIterable, Identifiable {
        case auto, simplified, traditional, english, off

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "自动"
            case .simplified: return "简体中文"
            case .traditional: return "繁体中文"
            case .english: return "英文"
            case .off: return "关闭"
            }
        }

        var hint: String {
            switch self {
            case .auto: return "优先影片自带的中文字幕，其次智能字幕"
            case .off: return "不显示字幕"
            default: return "优先\(label)字幕，没有时自动选择"
            }
        }

        /// 这条字幕有多对得上（越小越好；nil 是对不上）
        func rank(_ tag: String) -> Int? {
            let t = tag.lowercased()
            let hans = t.hasPrefix("zh-hans") || t == "zh-cn" || t == "zh-sg"
            let hant = t.hasPrefix("zh-hant") || t == "zh-tw" || t == "zh-hk" || t == "zh-mo"
            let zh = t == "zh" || t == "chi" || t == "zho"
            switch self {
            case .simplified: return hans ? 0 : zh ? 1 : hant ? 3 : nil
            case .traditional: return hant ? 0 : zh ? 1 : hans ? 3 : nil
            case .english: return (t == "en" || t.hasPrefix("en-") || t == "eng") ? 0 : nil
            case .auto, .off: return nil
            }
        }
    }

    static var audio: Audio { Audio(rawValue: UserDefaults.standard.string(forKey: audioKey) ?? "") ?? .auto }
    static var subtitle: Subtitle { Subtitle(rawValue: UserDefaults.standard.string(forKey: subtitleKey) ?? "") ?? .auto }

    /// 这一集挑好的字幕和音轨。播放器一挂上片源就建一个交给 apply，挑一条记一条；
    /// 「可以播了」「开播了」两个时刻拿它和片源现在选着的对一遍（reassert）
    @MainActor
    final class Picks {
        fileprivate(set) var legible: (group: AVMediaSelectionGroup, option: AVMediaSelectionOption?)?
        fileprivate(set) var audible: (group: AVMediaSelectionGroup, option: AVMediaSelectionOption)?
        /// 诊断用：只有语种标签（不带轨道名：轨道名可能带着片名、字幕组）
        var summary: String {
            let s = legible.map { "subs \($0.option.map(TrackPrefs.describe) ?? "off")" } ?? "subs -"
            let a = audible.map { "audio \(TrackPrefs.describe($0.option))" } ?? "audio -"
            return "\(a), \(s)"
        }
    }

    /// 按首选项给这个片源挑字幕和音轨，挑了就选上（「自动」也选，见文件头）。片源一挂上就调（和播放器读播放列表同时进行），
    /// 通常赶在首帧之前挑好。origin / refresh：「自然」用的原声语种——手上已有的，和（手上的不是 TMDB 给的时候）正在重新问的那一次
    @MainActor
    static func apply(to item: AVPlayerItem, picks: Picks, origin: Origin? = nil, refresh: Task<Origin?, Never>? = nil) async {
        let a = audio, s = subtitle
        let asset = item.asset
        // 字幕先挑：不用等「自然」查原声语种
        if let g = try? await asset.loadMediaSelectionGroup(for: .legible) {
            let pick: AVMediaSelectionOption?
            switch s {
            case .off:
                pick = nil
            case .auto:
                pick = autoSubtitle(g)
            default:
                // 同样对得上时，片子自带的（播放列表里排在前面）先于在线找来的（名字里写着「在线」）
                let scored = g.options.compactMap { o -> (option: AVMediaSelectionOption, score: Int)? in
                    guard !isForced(o), let r = s.rank(tag(o)) else { return nil }
                    return (o, r * 2 + (isOnline(o) ? 1 : 0))
                }
                pick = scored.min(by: { $0.score < $1.score })?.option ?? autoSubtitle(g)
            }
            if let pick {
                item.select(pick, in: g)
                picks.legible = (g, pick)
            } else if s == .off, g.allowsEmptySelection {
                item.select(nil, in: g)
                picks.legible = (g, nil)
            }
            // 别的情况（「自动」而一条中文都没有）：不开，也不去关系统选着的（强制字幕之类）
        }
        guard let g = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
        let pick: AVMediaSelectionOption?
        switch a {
        case .auto:
            pick = nil
        case .natural:
            var o = origin
            // 重新问的那一次最多再等 2.5 秒（通常早就回来了：和取片源同时开始的）；等不到就用手上的
            if let refresh, let fresh = await value(of: refresh, within: 2.5) { o = fresh }
            pick = naturalPick(g.options, origin: o, current: item.currentMediaSelection.selectedMediaOption(in: g))
        default:
            pick = g.options.first(where: { !isSideTrack($0) && a.matches(tag($0)) })
        }
        // 「自动」、对不上的：片源默认的那条（DEFAULT=YES）。没有默认的（直连的 MP4 有时没标）就不动
        guard let chosen = pick ?? g.defaultOption else { return }
        if item.currentMediaSelection.selectedMediaOption(in: g) != chosen { item.select(chosen, in: g) }
        picks.audible = (g, chosen)
    }

    /// 开播前后再对一遍：系统的自动选择把挑好的换掉了（按手机语言换了音轨、只留强制字幕）就改回来。改了：true
    @MainActor
    @discardableResult
    static func reassert(_ picks: Picks, on item: AVPlayerItem) -> Bool {
        var changed = false
        let now = item.currentMediaSelection
        if let l = picks.legible, now.selectedMediaOption(in: l.group) != l.option {
            item.select(l.option, in: l.group)
            changed = true
        }
        if let a = picks.audible, now.selectedMediaOption(in: a.group) != a.option {
            item.select(a.option, in: a.group)
            changed = true
        }
        return changed
    }

    /// 「自动」的字幕：服务器标成默认的那条（Worker 按「片子自带的中文优先，没有再用在线字幕」标的）；
    /// 没标（直连的 MP4、旧 Worker）就照同一个顺序自己挑；一条都对不上：nil（不开）
    static func autoSubtitle(_ g: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        let usable = g.options.filter { !isForced($0) }
        if let d = g.defaultOption, usable.contains(d) { return d }
        let scored = usable.compactMap { o -> (option: AVMediaSelectionOption, rank: Int)? in
            guard let r = autoRank(tag(o), online: isOnline(o)) else { return nil }
            return (o, r)
        }
        // 一样好的取播放列表里靠前的（片子自带的排在前面）
        return scored.min(by: { $0.rank < $1.rank })?.option
    }

    /// 和 Worker 标默认字幕同一个顺序（越小越好）：简体 1、中文 2、在线中文 3、繁体 4、粤语 5、在线的别的语言 8；
    /// 片子自带的别的语言：nil（「自动」不为它打开字幕）
    static func autoRank(_ tag: String, online: Bool) -> Int? {
        let t = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        let hans = t.hasPrefix("zh-hans") || t == "zh-cn" || t == "zh-sg"
        let hant = t.hasPrefix("zh-hant") || t == "zh-tw" || t == "zh-hk" || t == "zh-mo"
        let zh = t == "zh" || t == "chi" || t == "zho" || t == "cmn"
        let yue = t == "yue" || t.hasPrefix("yue-") || t == "zh-yue"
        if online { return hans || zh || hant ? 3 : 8 }
        if hans { return 1 }
        if zh { return 2 }
        if hant { return 4 }
        if yue { return 5 }
        return nil
    }

    static func isForced(_ o: AVMediaSelectionOption) -> Bool {
        o.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
    }

    /// Worker 在线找来的那条：名字是「简体中文-(智能)」这样的（还没重新部署的旧 Worker 写的是「（在线）」）
    static func isOnline(_ o: AVMediaSelectionOption) -> Bool {
        o.displayName.contains("(智能)") || o.displayName.contains("（在线")
    }

    /// 诊断里写的：语种标签 + 在线 / 强制，不写轨道名
    static func describe(_ o: AVMediaSelectionOption) -> String {
        let t = tag(o)
        return (t.isEmpty ? "und" : t) + (isOnline(o) ? " online" : "") + (isForced(o) ? " forced" : "")
    }

    static func tag(_ o: AVMediaSelectionOption) -> String {
        o.extendedLanguageTag ?? o.locale?.identifier ?? ""
    }

    /// 评论音轨（导演解说之类）、口述影像（给视障观众的）不当成「国语 / 英语」那条正经的音轨
    static func isSideTrack(_ o: AVMediaSelectionOption) -> Bool {
        o.hasMediaCharacteristic(.isAuxiliaryContent) || o.hasMediaCharacteristic(.describesVideoForAccessibility)
            || o.displayName.contains("评论") || o.displayName.contains("解说")
            || o.displayName.localizedCaseInsensitiveContains("comment")
    }

    // MARK: 自然：原声语种

    /// 一部片的原声是什么语言：languages 按顺序试（zh = 国语、yue = 粤语，别的是 ISO 639-1 两个字母）。
    /// fromTMDB：是 TMDB 给的原始语言（false = 按原名的文字猜的）
    struct Origin: Equatable, Sendable {
        var languages: [String]
        var fromTMDB: Bool
    }

    /// 从 TMDB 结果里取原声语种。有原始语言就用它；没有（老 Worker、存在本机的旧结果）就按原名的文字猜；都没有：nil
    static func origin(of m: Meta?) -> Origin? {
        guard let m else { return nil }
        if let raw = m.originalLanguage?.lowercased(), !raw.isEmpty, raw != "xx" {
            let countries = Set((m.originCountry ?? []).map { $0.uppercased() })
            let hongKong = countries.contains("HK") && !countries.contains("CN") && !countries.contains("TW")
            switch raw {
            case "cn": return Origin(languages: ["yue"], fromTMDB: true)           // TMDB 的 cn 是粤语
            case "zh": return Origin(languages: hongKong ? ["yue", "zh"] : ["zh"], fromTMDB: true)
            default: return Origin(languages: [canonical(raw)], fromTMDB: true)
            }
        }
        if let t = m.originalTitle, let guess = scriptLanguages(t) { return Origin(languages: guess, fromTMDB: false) }
        return nil
    }

    /// 按原名的文字猜语种（老结果里没有原始语言时用）。拉丁字母、只有数字和符号的猜不出：nil
    static func scriptLanguages(_ title: String) -> [String]? {
        var han = false
        for u in title.unicodeScalars {
            switch u.value {
            case 0x30FB: break                                                 // 「・」中文片名里也用
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return ["ko"]
            case 0x3040...0x30FF, 0x31F0...0x31FF: return ["ja"]               // 假名：汉字夹着假名的也是日语
            case 0x0E00...0x0E7F: return ["th"]
            case 0x0400...0x04FF: return ["ru"]
            case 0x0370...0x03FF: return ["el"]
            case 0x0590...0x05FF: return ["he"]
            case 0x0600...0x06FF: return ["ar"]
            case 0x0900...0x097F: return ["hi"]
            case 0x0980...0x09FF: return ["bn"]
            case 0x0B80...0x0BFF: return ["ta"]
            case 0x0C00...0x0C7F: return ["te"]
            case 0x0C80...0x0CFF: return ["kn"]
            case 0x0D00...0x0D7F: return ["ml"]
            case 0x0530...0x058F: return ["hy"]
            case 0x10A0...0x10FF: return ["ka"]
            case 0x1780...0x17FF: return ["km"]
            case 0x0E80...0x0EFF: return ["lo"]
            case 0x1000...0x109F: return ["my"]
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF: han = true
            default: break
            }
        }
        guard han else { return nil }
        // 只有汉字：国语；带粤语专用字的粤语在前
        return title.contains(where: { "嘅咗喺唔冇佢哋嘢啲嚟乜".contains($0) }) ? ["yue", "zh"] : ["zh"]
    }

    /// 一条音轨是什么语种（规范化；und / mul / zxx 这类不算：nil）。
    /// 中文音轨按轨道名再认一次粤语（直连的 MP4 没经过 Worker 细分）
    static func language(of o: AVMediaSelectionOption) -> String? {
        let parts = tag(o).lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }
        let lang = canonical(first)
        if ["und", "mul", "zxx", "mis", "qaa"].contains(lang) { return nil }
        if lang == "zh", parts.contains("yue") || o.displayName.contains("粤") || o.displayName.localizedCaseInsensitiveContains("cantonese") {
            return "yue"
        }
        return lang
    }

    /// 轨道名里写着「原声 / 原音 / Original」的那条（语种标签常是 und）
    static func isLabeledOriginal(_ o: AVMediaSelectionOption) -> Bool {
        let n = o.displayName
        return n.contains("原声") || n.contains("原音") || n.localizedCaseInsensitiveContains("original")
    }

    /// 「自然」挑哪一条：原声语种（按顺序）→ 轨道名写着原声的 → 英语；都没有：nil（照片源默认的）。
    /// 现在选着的那条已经对得上就留着它：同一种语言有好几条时不乱换（片源默认的那条往往是音质最好的）
    static func naturalPick(_ options: [AVMediaSelectionOption], origin: Origin?,
                            current: AVMediaSelectionOption?) -> AVMediaSelectionOption? {
        let main = options.filter { !isSideTrack($0) }
        func best(_ match: (AVMediaSelectionOption) -> Bool) -> AVMediaSelectionOption? {
            if let c = current, main.contains(c), match(c) { return c }
            return main.first(where: match)
        }
        for lang in origin?.languages ?? [] {
            if let o = best({ language(of: $0) == lang }) { return o }
        }
        if let o = best({ isLabeledOriginal($0) }) { return o }
        return best { language(of: $0) == "en" }
    }

    /// 语种代码规范化：三个字母的（ISO 639-2，B / T 两套）换成两个字母的、旧代码换新代码；挪威语三种写法算一种
    static func canonical(_ code: String) -> String {
        let c = code.lowercased()
        switch c {
        case "cmn", "chi", "zho": return "zh"
        case "iw": return "he"
        case "in": return "id"
        case "ji": return "yi"
        case "nb", "nn", "nob", "nno", "nor": return "no"
        case "fil", "tgl": return "tl"
        default: return iso639_2[c] ?? c
        }
    }

    private static let iso639_2: [String: String] = [
        "eng": "en", "jpn": "ja", "kor": "ko", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es", "ita": "it",
        "rus": "ru", "por": "pt", "ara": "ar", "hin": "hi", "tha": "th", "vie": "vi", "ind": "id", "may": "ms", "msa": "ms",
        "tur": "tr", "pol": "pl", "dut": "nl", "nld": "nl", "swe": "sv", "dan": "da", "fin": "fi", "gre": "el", "ell": "el",
        "heb": "he", "hun": "hu", "cze": "cs", "ces": "cs", "slo": "sk", "slk": "sk", "rum": "ro", "ron": "ro", "bul": "bg",
        "ukr": "uk", "hrv": "hr", "srp": "sr", "slv": "sl", "est": "et", "lav": "lv", "lit": "lt", "ice": "is", "isl": "is",
        "per": "fa", "fas": "fa", "urd": "ur", "ben": "bn", "tam": "ta", "tel": "te", "mal": "ml", "kan": "kn", "mar": "mr",
        "guj": "gu", "pan": "pa", "cat": "ca", "baq": "eu", "eus": "eu", "glg": "gl", "wel": "cy", "cym": "cy", "gle": "ga",
        "alb": "sq", "sqi": "sq", "mac": "mk", "mkd": "mk", "bos": "bs", "geo": "ka", "kat": "ka", "arm": "hy", "hye": "hy",
        "kaz": "kk", "uzb": "uz", "mon": "mn", "bur": "my", "mya": "my", "khm": "km", "lao": "lo", "nep": "ne", "sin": "si",
        "afr": "af", "swa": "sw", "amh": "am", "yid": "yi", "lat": "la",
    ]

    /// 等一个查询最多 seconds 秒：到点还没回来就当它没有（查询照样在后台跑完，结果记下来下次用）
    static func value<T: Sendable>(of task: Task<T?, Never>, within seconds: Double) async -> T? {
        let gate = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            Task {
                let v = await task.value
                if gate.withLock({ (done: inout Bool) -> Bool in let first = !done; done = true; return first }) {
                    c.resume(returning: v)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.withLock({ (done: inout Bool) -> Bool in let first = !done; done = true; return first }) {
                    c.resume(returning: nil)
                }
            }
        }
    }
}
