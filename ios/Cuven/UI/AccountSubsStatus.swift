import SwiftUI

// MARK: - 在线字幕服务的状态（账户页「播放」里「首选字幕」下面那一行；用户要求「添加在线字幕服务状态」）
//
// 在线字幕是 Worker 去 OpenSubtitles 找的（没有中文字幕的片子自动补一条）。这一行告诉人它现在好不好用：
// 正常（今天还能下载几条、响应多快）/ 今天的下载额度用完了（几点恢复）/ 账号或 API Key 不对 / 连不上 / 服务器没开启。
// 数据来自后端 /api/subs/status：后端缓存 10 分钟（Worker 里改了账号、密码、API Key 就不用旧结果）；
// 点这一行重新检测（后端 1 分钟内最多真问一次 OpenSubtitles）。
// 登录被拒时后端说清是哪一项（reason：login 用户名或密码 / key API Key；emailUser 用户名填成了邮箱——OpenSubtitles 的接口只认用户名），
// 这一行把「怎么改」整段写出来，不截断（用户截图：只看到「OpenSubtitles 的账号、密码或 A…」，不知道该改哪个）。
// 后端只回状态和数字（外加对方自己说的原因，去掉了账号、密码），不带账号名。演示数据不连网，给一份合成的「正常」。

/// /api/subs/status 的回包
struct SubsServiceStatus: Decodable, Equatable, Sendable {
    /// ok 正常 / quota 今天的下载额度用完了 / auth 账号或 API Key 不对 / error 连不上、接口出错 / off 服务器没开启
    var state: String
    var configured: Bool?
    /// 用的是 OpenSubtitles 账号（额度按账号算）；false = 只有 API Key（额度按共享出口 IP 算）
    var account: Bool?
    var latency: Int?
    var remaining: Int?
    var allowed: Int?
    var resetAt: String?
    var message: String?
    /// state 是 auth / error 时是哪一项：login 用户名或密码不对 / key API Key 不对 / rate 登录被限流
    var reason: String?
    /// 用户名里有 @（填成了邮箱）
    var emailUser: Bool?
    /// OpenSubtitles 自己说的原因（「Error, invalid username/password」这类；后端已去掉账号、密码、API Key）
    var osMessage: String?
}

@MainActor @Observable
final class SubsStatusProbe {
    enum Outcome: Equatable {
        case status(SubsServiceStatus)
        /// 后端还是旧版本（没有这个接口，404）：要重新部署 Worker
        case serverTooOld
        /// 连不上我们的服务器
        case unreachable
    }

    private(set) var outcome: Outcome?
    private(set) var checking = false
    /// 人点了「重新检测」、结果回来了（触感跟着它）
    private(set) var rechecks = 0

    func load(fresh: Bool) async {
        guard !checking else { return }
        checking = true
        defer {
            checking = false
            if fresh { rechecks += 1 }
        }
        if DemoData.enabled {
            try? await Task.sleep(for: .milliseconds(fresh ? 600 : 150))
            outcome = .status(SubsServiceStatus(state: "ok", configured: true, account: true, latency: 180, remaining: 96, allowed: 100))
            return
        }
        do {
            outcome = .status(try await APIClient.shared.subsStatus(fresh: fresh))
        } catch APIError.http(let code, _) where code == 404 {
            outcome = .serverTooOld
        } catch {
            outcome = .unreachable
        }
    }
}

/// 「在线字幕」那一行：和 AccountRow 一样的符号列、字号、边距；状态胶囊（颜色圆点 + 两三个字）放在标题那一行的右边，
/// 检测时换成转圈；说明占满整行、不限行数——出问题时那段「怎么改」有三四行，放在胶囊左边那一窄条里会被截断。点整行重新检测
struct SubsStatusRow: View {
    let probe: SubsStatusProbe
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 21
    @ScaledMetric(relativeTo: .title3) private var iconColumn: CGFloat = AccountMetrics.iconColumn

    var body: some View {
        let look = SubsStatusLook(probe.outcome)
        Button {
            Haptics.light()
            Task { await probe.load(fresh: true) }
        } label: {
            HStack(spacing: AccountMetrics.gap) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: iconSize, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: iconColumn)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("在线字幕")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Group {
                            if probe.checking {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else if probe.outcome != nil {
                                SubsStatusBadge(text: look.badge, color: look.color)
                                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            }
                        }
                        .frame(minWidth: 44, minHeight: 26, alignment: .trailing)
                        .animation(DSMotion.snap, value: probe.checking)
                    }
                    Text(probe.outcome == nil ? "正在检测…" : look.detail)
                        .font(.subheadline)
                        .foregroundStyle(DSInk.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let said = look.said {
                        Text(verbatim: "OpenSubtitles：\(said)")
                            .font(.footnote)
                            .foregroundStyle(DSInk.tertiary.opacity(0.8))
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AccountMetrics.inset)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(AccountRowPress())
        .disabled(probe.checking)
        .sensoryFeedback(look.isGood ? .success : .warning, trigger: probe.rechecks)
        .accessibilityLabel("在线字幕")
        .accessibilityValue(probe.outcome == nil ? "正在检测" : "\(look.badge)，\(look.detail)")
        .accessibilityHint("轻点重新检测")
        .accessibilityIdentifier("account-subs-status")
        .task { if probe.outcome == nil { await probe.load(fresh: false) } }
    }
}

/// 右边那颗胶囊：颜色圆点 + 两三个字（12% 白的底，和这一页别的胶囊一样）
private struct SubsStatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .accessibilityHidden(true)
    }
}

/// 状态 → 胶囊上的字、颜色、第二行的说明
private struct SubsStatusLook {
    var badge = "未知"
    var color = Color.gray
    var detail = ""
    /// OpenSubtitles 自己说的原因（出问题时才有，放在说明底下一小行）
    var said: String?
    var isGood = false

    init(_ outcome: SubsStatusProbe.Outcome?) {
        switch outcome {
        case nil:
            break
        case .serverTooOld:
            badge = "未知"; color = .gray
            detail = "服务器还是旧版本，看不到在线字幕的状态：重新部署 Worker 后就有了"
        case .unreachable:
            badge = "连不上"; color = .red
            detail = "现在连不上服务器，检查网络后点这里重试"
        case .status(let s):
            switch s.state {
            case "ok":
                badge = "正常"; color = .green; isGood = true
                var parts: [String] = []
                if let left = s.remaining {
                    if let all = s.allowed, all > 0 { parts.append("今天还能下载 \(left) / \(all) 条") }
                    else { parts.append("还能下载 \(left) 条") }
                } else {
                    parts.append("OpenSubtitles 连接正常")
                }
                if let ms = s.latency { parts.append("响应 \(Self.duration(ms))") }
                if s.account == false { parts.append("未登录账号，额度按出口 IP 算") }
                detail = parts.joined(separator: " · ")
            case "quota":
                badge = "额度用完"; color = .orange
                if let at = Self.resetTime(s.resetAt) {
                    detail = "今天的字幕下载额度用完了，\(at)恢复；已经找到的字幕照常能用"
                } else {
                    detail = "今天的字幕下载额度用完了，明天恢复；已经找到的字幕照常能用"
                }
            case "auth":
                badge = "需要设置"; color = .orange
                said = s.osMessage
                switch s.reason {
                case "key"?:
                    detail = "API Key 不对：到 opensubtitles.com 的 API 页面重新复制，填进 Worker 的 OPENSUBTITLES_API_KEY，再点这里重新检测"
                case "login"? where s.emailUser == true:
                    // 用户截图：用户名填的是邮箱。OpenSubtitles 的接口只认用户名（网站能用邮箱登录，接口不行）
                    detail = "用户名填成了邮箱：OpenSubtitles 的接口只认用户名。把 Worker 里的 OPENSUBTITLES_USERNAME 换成你在 opensubtitles.com 的用户名，再点这里重新检测。在此之前，在线字幕只用 API Key 下载，每天能下的很少"
                case "login"?:
                    detail = "登录不上：用户名或密码不对。要用 opensubtitles.com 的账号（opensubtitles.org 的旧账号不通用），用户名不是邮箱；改好后点这里重新检测。在此之前，在线字幕只用 API Key 下载，每天能下的很少"
                default:
                    // 旧版后端没有 reason
                    detail = "OpenSubtitles 的用户名、密码或 API Key 不对：检查 Worker 里的 OPENSUBTITLES_USERNAME、OPENSUBTITLES_PASSWORD、OPENSUBTITLES_API_KEY（用户名不是邮箱）"
                }
            case "off":
                badge = "未开启"; color = .gray
                detail = "服务器没开启在线字幕（没配 OpenSubtitles）：只用片子自带和同目录的字幕"
            case "error" where s.reason == "rate":
                badge = "限流中"; color = .orange
                said = s.osMessage
                detail = "OpenSubtitles 暂时不让登录（请求太频繁），过一会儿自动恢复；已经找到的字幕照常能用"
            default:
                badge = "不可用"; color = .red
                said = s.osMessage
                // 后端给的原因：timeout / unreachable / HTTP 503 / login HTTP 503
                let why: String
                switch s.message {
                case "timeout"?: why = "（超时）"
                case let m? where m.contains("HTTP"): why = "（\(m.replacingOccurrences(of: "login ", with: "登录 "))）"
                default: why = ""
                }
                detail = "现在连不上 OpenSubtitles\(why)，过一会儿再试；已经找到的字幕照常能用"
            }
        }
    }

    /// 230 毫秒 / 1.2 秒
    static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) 毫秒" : String(format: "%.1f 秒", Double(ms) / 1000)
    }

    /// 恢复时间：24 小时内只写几点几分，再远写日期
    static func resetTime(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso), d > Date() else { return nil }
        if d.timeIntervalSinceNow < 24 * 3600 { return d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.month().day().hour().minute())
    }
}
