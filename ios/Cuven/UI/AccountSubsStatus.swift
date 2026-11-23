import SwiftUI

// MARK: - 在线字幕服务的状态（账户页「播放」里「首选字幕」下面那一行；用户要求「添加在线字幕服务状态」）
//
// 在线字幕是服务器去 OpenSubtitles 找的（没有中文字幕的影片自动补一条）。这一行只用普通人看得懂的话说它现在好不好用：
// 正常（今天还能下载几条）/ 已达上限（几点恢复）/ 暂不可用 / 未开启 / 无法连接。
// 发行版不写开发者才看得懂的东西（用户要求「移除用户不应该看到的信息」）：不提 Worker、API Key、环境变量名、
// HTTP 状态码、OpenSubtitles 的英文原话，也不写响应毫秒数。为什么不可用（账号填错、API Key 不对、限流）后端照样报在
// /api/subs/status 的 reason / emailUser / osMessage 里，管理员看那里（README「在线字幕」）。
// 数据来自后端 /api/subs/status：后端缓存 10 分钟（Worker 里改了账号、密码、API Key 就不用旧结果）；
// 点这一行重新检测（后端 1 分钟内最多真问一次 OpenSubtitles）。演示数据不连网，给一份合成的「正常」。

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
                        Text("智能字幕")
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
        .accessibilityLabel("智能字幕")
        .accessibilityValue(probe.outcome == nil ? "正在检测" : "\(look.badge)，\(look.detail)")
        .accessibilityHint("重新检测")
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

/// 状态 → 胶囊上的字、颜色、第二行的说明（Apple 式：短、直说，不写技术细节）
private struct SubsStatusLook {
    var badge = "未知"
    var color = Color.gray
    var detail = ""
    var isGood = false

    init(_ outcome: SubsStatusProbe.Outcome?) {
        switch outcome {
        case nil:
            break
        case .serverTooOld:
            badge = "未知"; color = .gray
            detail = "暂时无法获取状态"
        case .unreachable:
            badge = "无法连接"; color = .red
            detail = "请检查网络连接后重试"
        case .status(let s):
            switch s.state {
            case "ok":
                badge = "正常"; color = .green; isGood = true
                detail = "可以正常使用"          // 不写今天还能下载多少条（用户要求）
            case "quota":
                badge = "已达上限"; color = .orange
                let at = Self.resetTime(s.resetAt).map { "\($0)恢复" } ?? "明天恢复"
                detail = "今天的下载次数已用完，\(at)。已下载的字幕仍可使用"
            case "off":
                badge = "未开启"; color = .gray
                detail = "只使用影片自带的字幕"
            default:
                // auth（账号设置有误）、error（连不上 OpenSubtitles）、限流：对看的人来说都一样——现在用不了、已有的照常能用
                badge = "暂不可用"; color = .orange
                detail = "已下载的字幕仍可使用"
            }
        }
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
