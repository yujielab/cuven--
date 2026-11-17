import AVFoundation

// MARK: - 字幕与音轨首选项（用户要求「允许设置字幕和音轨首选项」）
//
// 账户页「播放」里选；正片每个片源（换下一集也算）一挂上就按它挑一次：
// · 音轨：第一条语言对得上的（跳过评论音轨）；
// · 字幕：语言最对得上的那条（不挑「强制」字幕——那种只翻外语对白；同样对得上时片子自带的排在在线找来的前面）；
//   「关闭」是不显示字幕。
// 对不上就照片源 / 服务器默认的那条，和以前一样（自动 = 不插手）。只在开始时挑一次，播放中在系统播放器里手动换的不动。
// 语言按 HLS 播放列表里的 LANGUAGE 认：Worker 给的是 BCP-47（zh / zh-Hans / zh-Hant / yue / en / ja / ko …），
// 中文音轨按轨道名分出了粤语；字幕抽样认出繁体的已经标成 zh-Hant。

enum TrackPrefs {
    static let audioKey = "cuven_pref_audio"
    static let subtitleKey = "cuven_pref_subtitle"

    enum Audio: String, CaseIterable, Identifiable {
        case auto, mandarin, cantonese, english, japanese, korean

        var id: String { rawValue }

        var label: String {
            switch self {
            case .auto: return "自动"
            case .mandarin: return "国语"
            case .cantonese: return "粤语"
            case .english: return "英语"
            case .japanese: return "日语"
            case .korean: return "韩语"
            }
        }

        /// 账户页那一行下面的灰字
        var hint: String {
            self == .auto ? "片源默认的那条，通常是原声" : "有\(label)音轨就先放它，没有就用片源默认的"
        }

        func matches(_ tag: String) -> Bool {
            let t = tag.lowercased()
            func lang(_ code: String) -> Bool { t == code || t.hasPrefix(code + "-") || t.hasPrefix(code + "_") }
            switch self {
            case .auto: return false
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
            case .auto: return "片子自带的中文优先，没有再用在线字幕"
            case .off: return "不显示字幕"
            default: return "有\(label)字幕就先选它，没有就照默认的"
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

    /// 按首选项给这个片源挑音轨和字幕。片源一建好就调（和播放器读播放列表同时进行），通常赶在首帧之前挑好
    @MainActor
    static func apply(to item: AVPlayerItem) async {
        let a = audio, s = subtitle
        guard a != .auto || s != .auto else { return }
        let asset = item.asset
        if a != .auto, let g = try? await asset.loadMediaSelectionGroup(for: .audible),
           let pick = g.options.first(where: { !isCommentary($0) && a.matches(tag($0)) }) {
            item.select(pick, in: g)
        }
        if s != .auto, let g = try? await asset.loadMediaSelectionGroup(for: .legible) {
            if s == .off {
                if g.allowsEmptySelection { item.select(nil, in: g) }
            } else {
                // 同样对得上时，片子自带的（播放列表里排在前面）先于在线找来的（名字里写着「在线」）
                let scored = g.options.compactMap { o -> (option: AVMediaSelectionOption, score: Int)? in
                    guard !o.hasMediaCharacteristic(.containsOnlyForcedSubtitles), let r = s.rank(tag(o)) else { return nil }
                    return (o, r * 2 + (o.displayName.contains("在线") ? 1 : 0))
                }
                if let pick = scored.min(by: { $0.score < $1.score })?.option {
                    item.select(pick, in: g)
                }
            }
        }
    }

    static func tag(_ o: AVMediaSelectionOption) -> String {
        o.extendedLanguageTag ?? o.locale?.identifier ?? ""
    }

    /// 评论音轨（导演解说之类）不当成「国语 / 英语」那条正经的音轨
    static func isCommentary(_ o: AVMediaSelectionOption) -> Bool {
        o.hasMediaCharacteristic(.isAuxiliaryContent)
            || o.displayName.contains("评论") || o.displayName.contains("解说")
            || o.displayName.localizedCaseInsensitiveContains("comment")
    }
}
