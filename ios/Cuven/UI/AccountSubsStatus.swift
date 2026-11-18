import SwiftUI

// MARK: - 在线字幕服务的状态（账户页「播放」里「首选字幕」下面那一行；用户要求「添加在线字幕服务状态」）
//
// 在线字幕是 Worker 去 OpenSubtitles 找的（没有中文字幕的片子自动补一条）。这一行告诉人它现在好不好用：
// 正常（今天还能下载几条、响应多快）/ 今天的下载额度用完了（几点恢复）/ 账号或 API Key 不对 / 连不上 / 服务器没开启。
// 数据来自后端 /api/subs/status：后端缓存 10 分钟；点这一行重新检测（后端 1 分钟内最多真问一次 OpenSubtitles）。
// 后端只回状态和数字，不带账号名。演示数据不连网，给一份合成的「正常」。

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

/// 「在线字幕」那一行：左边符号 + 标题 + 一行说明，右边一颗状态胶囊（颜色圆点 + 两三个字）；检测时换成转圈。点整行重新检测
struct SubsStatusRow: View {
    let probe: SubsStatusProbe

    var body: some View {
        let look = SubsStatusLook(probe.outcome)
        Button {
            Haptics.light()
            Task { await probe.load(fresh: true) }
        } label: {
            AccountRow(icon: "captions.bubble.fill", title: "在线字幕", subtitle: probe.outcome == nil ? "正在检测…" : look.detail) {
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
                .frame(minWidth: 44, alignment: .trailing)
                .animation(DSMotion.snap, value: probe.checking)
            }
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
                detail = "OpenSubtitles 的账号、密码或 API Key 不对，请检查 Worker 里的设置"
            case "off":
                badge = "未开启"; color = .gray
                detail = "服务器没开启在线字幕（没配 OpenSubtitles）：只用片子自带和同目录的字幕"
            default:
                badge = "不可用"; color = .red
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
