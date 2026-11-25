import SwiftUI

// MARK: - 账户页移植（网页版）：网络速度、使用洞察 · 流量概览
//
// 网页版账户页的第二、三张卡，样子换成这一页的（Apple「游戏」App 的个人页：组名 + 圆角 26 的半透明卡、白字、灰色说明，见 AccountView）：
// · 网络速度：45 根竖条的波浪滑块（拇指那一处凹下去，左亮右暗），整条都能拖，拖的时候拇指上方一颗气泡写着数，每 5% 一下选择触感；
//   旁白是一个可调的元素（上下轻扫 ±5%）。存在 cuven_network_speed（和网页版的 settings.networkSpeed 同步），在 iOS 上真的管播放（NetworkSpeed）。
//   滑块下面一行「自动调整」（用户要求）：检测网络情况和速度、自动选百分比（NetworkAuto）；自动选的数只在本机，手动拖一下就关掉自动。
// · 使用洞察 · 流量概览：网页版的数是随机的，这里是这台设备真的下载了多少（UsageMeter）：本月 / 日均 / 较上月、近 24 小时每小时一根柱、
//   本月三类的构成。收起 / 展开存在 cuven_traffic_expanded（同步 settings.trafficExpanded）。

// MARK: - 网络速度

/// 「网络」一组：标题 + 一张卡（「网络速度」那一行）+ 卡下一行说明这个设置在 iOS 上管什么。直接放进账户页的组里用
struct NetworkSpeedCard: View {
    var body: some View {
        // 网络速度 + 自动调整，下面接着 Cuven Pass Pro（用户要求并进「网络」这一张卡）
        AccountGroup(title: "网络") {
            NetworkSpeedRow()
            AccountDivider()
            PassProRows()
            AccountDivider()
            // 获取软件更新（用户要求）：热更新 Cuven Pass 的加速节点
            RuntimeUpdateRow(scope: .network)
        }
    }
}

/// 「网络速度」一行（不带卡、不带组名）：要放进别的组（比如「播放」）时用它，前面加一条 AccountDivider
struct NetworkSpeedRow: View {
    @AppStorage(NetworkSpeed.key) private var speed = NetworkSpeed.defaultValue
    @AppStorage(NetworkSpeed.autoKey) private var auto = false
    @AppStorage(NetworkSpeed.autoValueKey) private var autoValue = -1
    /// 正在拖：松手才写回设置（拖一下不存几十次）
    @State private var dragValue: Int?
    /// 和 AccountRow 的符号一样大（21 点；以前这里还是 24）
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 21
    @ScaledMetric(relativeTo: .title3) private var iconColumn: CGFloat = AccountMetrics.iconColumn

    static let hint = "调高更流畅，调低更省流量。"

    /// 现在生效的：开着自动调整而且测过 → 自动选的；不然是手动设的
    private var stored: Int { auto && autoValue >= 0 ? min(100, autoValue) : min(100, max(0, speed)) }
    private var shown: Int { dragValue ?? stored }
    private var valueText: String { auto ? "\(stored)%，自动调整" : "\(stored)%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                NetworkWaveSlider(value: shown, dragging: dragValue != nil, onDrag: drag, onEnd: commit)
            }
            // 每过一个 5% 一下选择触感；只在手指拖的时候（同步回来的值、自动调整选的值变了不震：F41）
            .sensoryFeedback(.selection, trigger: shown) { old, new in
                dragValue != nil && old / 5 != new / 5
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("网络速度")
            .accessibilityValue(valueText)
            .accessibilityHint(Self.hint)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setManual(min(100, stored + 5))
                case .decrement: setManual(max(0, stored - 5))
                @unknown default: break
                }
            }
            // 自动调整（用户要求「添加自动调整按钮，自动检测网络情况和速度匹配合适的百分比」）：和「使用洞察」卡底下
            // 「清除缓存」那一行同一个样子——一条细线，左边标题 + 一行灰字（检测到的网络、速度、延迟），右边一颗胶囊
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 0.5)
                .padding(.top, 20)
            NetworkAutoRow()
                .padding(.top, 12)
        }
        .padding(.horizontal, AccountMetrics.inset)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    /// 符号、「网络速度」、右边的百分比；下面一行灰色提示（和账户页的行同一套字、同一条左边线）。
    /// AccountRow 收过一轮（标题 Title 3 → Body 半粗、说明 Callout → Subheadline、符号 24 → 21）以后这一行没跟上，
    /// 同一张卡里它比下面「自动调整」「Cuven Pass Pro」大一号、细一级：现在是同一套；百分比仍比标题大一级（Title 3 半粗）
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AccountMetrics.gap) {
            Image(systemName: "speedometer")
                .font(.system(size: iconSize, weight: .regular))
                // 和 AccountRow 的符号同一级灰（DSInk.secondary）：比下面的说明亮一级（设计复查）
                .foregroundStyle(DSInk.secondary)
                .frame(width: iconColumn)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("网络速度")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(shown)%")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        // 自动调整选了新的数：数字滚过去（手指拖的时候不滚，跟手）
                        .contentTransition(.numericText(value: Double(shown)))
                        .animation(dragValue == nil ? Animation.smooth(duration: 0.5) : nil, value: shown)
                }
                Text(Self.hint)
                    .font(.subheadline)
                    .foregroundStyle(DSInk.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func drag(_ v: Int) {
        if dragValue == nil {
            withAnimation(DSMotion.snap) { dragValue = v }
        } else if dragValue != v {
            dragValue = v
        }
    }

    private func commit() {
        guard let v = dragValue else { return }
        setManual(v)
        withAnimation(DSMotion.snap) { dragValue = nil }
    }

    /// 手动定一个数（拖滑块、旁白上下轻扫）：就是要自己定，自动调整跟着关掉
    private func setManual(_ v: Int) {
        if auto { NetworkAuto.shared.setEnabled(false, keepValue: false) }
        speed = v
    }
}

/// 「自动调整」一行：左边标题 + 一行灰字（关着：说这颗钮做什么；检测中；开着：检测到的网络、速度、延迟），
/// 右边一颗胶囊——关着是玻璃「开启」，开着是白底「✓ 已开启」（选中的样子：C11），检测时胶囊里转圈、不变窄。
/// 按「开启」马上测一次、测完给一下成功触感；按「已开启」关掉，停在现在的数上
private struct NetworkAutoRow: View {
    @AppStorage(NetworkSpeed.autoKey) private var auto = false
    @State private var taps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let engine = NetworkAuto.shared
        let measuring = engine.phase == .measuring
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("自动调整")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Text(status(engine, measuring: measuring))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DSInk.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            pill(measuring: measuring)
        }
        .animation(reduceMotion ? nil : Animation.snappy(duration: 0.3), value: auto)
        .animation(reduceMotion ? nil : Animation.smooth(duration: 0.3), value: engine.phase)
        .sensoryFeedback(.selection, trigger: taps)
        .sensoryFeedback(.success, trigger: engine.userRuns)
    }

    private func status(_ engine: NetworkAuto, measuring: Bool) -> String {
        if measuring { return "正在检测网络…" }
        guard auto else { return "根据网络状况自动调整" }
        if engine.phase == .offline { return "未连接网络" }
        return engine.last?.summary ?? "即将检测"
    }

    private func pill(measuring: Bool) -> some View {
        Button {
            taps += 1
            NetworkAuto.shared.setEnabled(!auto)
        } label: {
            ZStack {
                HStack(spacing: 5) {
                    if auto { Image(systemName: "checkmark").font(.footnote.weight(.bold)) }
                    Text(auto ? "已开启" : "开启")
                }
                .opacity(measuring ? 0 : 1)
                if measuring { ProgressView().controlSize(.small).tint(auto ? .black : .white) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(auto ? Color.black : Color.white)
            // 和「更改」「测速」同一号胶囊（30 高、左右 13；以前 34 / 18：设计复查），点按区仍 44
            .padding(.horizontal, 13)
            .frame(minHeight: 30)
            .background { if auto { Capsule().fill(Color.white) } }
            .glassEffect(.regular.interactive(), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("自动调整网络速度")
        .accessibilityValue(auto ? "已开启" : "已关闭")
        .accessibilityAddTraits(auto ? .isSelected : [])
        .accessibilityHint(auto ? "关闭后保持当前设置" : "根据网络状况自动调整")
        .accessibilityIdentifier("account-network-auto")
    }
}

/// 45 根竖条的波浪滑块（网页版 buildSliderBars / updateWave）：离拇指 d 根的竖条高 1 − 0.85·e^(−d²/8)（拇指那儿最矮 15%），
/// 拉满（100%）时 45 根一样高（94% 起凹得越来越浅）；拇指和它左边的亮、右边的暗；整条都能拖，按下就跳到手指那儿（网页版 pointerdown 同样）
private struct NetworkWaveSlider: View {
    let value: Int
    let dragging: Bool
    let onDrag: (Int) -> Void
    let onEnd: () -> Void

    static let count = 45
    fileprivate static let height: CGFloat = 56
    fileprivate static let barsHeight: CGFloat = 28
    fileprivate static let pad: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let m = WaveMetrics(width: geo.size.width)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                bars(m)
                    .frame(width: m.avail, height: Self.barsHeight, alignment: .bottom)
                    .position(x: geo.size.width / 2, y: Self.height / 2)
                if dragging {
                    NetworkSpeedBubble(value: value)
                        .position(x: m.x(value), y: -24)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                }
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in onDrag(m.value(at: g.location.x)) }
                    .onEnded { _ in onEnd() }
            )
        }
        .frame(height: Self.height)
    }

    private func bars(_ m: WaveMetrics) -> some View {
        let active = Double(value) / 100 * Double(Self.count - 1)
        let lit = Int(active.rounded())
        return HStack(alignment: .bottom, spacing: m.gap) {
            ForEach(0..<Self.count, id: \.self) { i in
                Capsule()
                    .fill(i <= lit ? Color.white.opacity(0.92) : Color.white.opacity(0.2))
                    .frame(width: m.barWidth, height: Self.barsHeight * Self.heightFactor(Double(i), active, value: value))
            }
        }
        // 手指拖的时候跟手（0.1 秒）；自动调整、同步回来、旁白改的数慢一点滑过去
        .animation(reduceMotion ? nil : (dragging ? Animation.easeOut(duration: 0.1) : Animation.smooth(duration: 0.55)), value: value)
    }

    /// 网页版的波形：离拇指越近越矮（拇指那儿最矮 15%）。拉满时不凹（用户要求「100% 时所有柱状高度应该一致」）：
    /// 从 94% 起凹得越来越浅，到 100% 正好平——拖到头时是慢慢抹平的，不是一下子跳平
    private static func heightFactor(_ i: Double, _ active: Double, value: Int) -> CGFloat {
        let d = i - active
        let depth = 0.85 * min(1, max(0, Double(100 - value) / 6))
        return CGFloat(1 - depth * exp(-(d * d) / 8))
    }
}

/// 滑块的几个尺寸：竖条那一段的宽、每根的宽（约一格的 55%）、间距；数 ↔ 横坐标（第 0 根到第 44 根的正中）
private struct WaveMetrics {
    let avail: CGFloat
    let barWidth: CGFloat
    let gap: CGFloat

    init(width: CGFloat) {
        let n = CGFloat(NetworkWaveSlider.count)
        avail = max(n * 2, width - NetworkWaveSlider.pad * 2)
        barWidth = max(1.5, avail / n * 0.55)
        gap = (avail - barWidth * n) / (n - 1)
    }

    func x(_ value: Int) -> CGFloat {
        NetworkWaveSlider.pad + barWidth / 2 + CGFloat(value) / 100 * (avail - barWidth)
    }

    func value(at x: CGFloat) -> Int {
        let f = (x - NetworkWaveSlider.pad - barWidth / 2) / max(1, avail - barWidth)
        return Int((min(1, max(0, f)) * 100).rounded())
    }
}

/// 拖的时候拇指上方的气泡：白底黑字「80 %」，下面一个小尖
private struct NetworkSpeedBubble: View {
    let value: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: "\(value)")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.black)
                Text(verbatim: "%")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.white))
            BubbleTip()
                .fill(.white)
                .frame(width: 10, height: 5)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .fixedSize()
        .accessibilityHidden(true)
    }
}

private struct BubbleTip: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 使用洞察 · 流量概览

/// 「使用洞察」组名 + 「流量概览」卡（可收起）。不要参数，直接放进账户页
struct UsageInsightsCard: View {
    static let expandedKey = "cuven_traffic_expanded"

    @AppStorage(UsageInsightsCard.expandedKey) private var expanded = true
    @State private var summary: UsageSummary?
    @State private var taps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    /// 缓存占了多少（AppModel.cacheUsage：片库清单与影片信息、接口回包、海报和剧照）
    @State private var cacheBytes: Int64 = AppModel.cacheUsage
    @State private var clearing = false
    @State private var cleared = 0
    /// 清除缓存的整屏动画（CacheDissolveSheet：卡化成光流）
    @State private var dissolving = false

    var body: some View {
        AccountGroup(title: "使用洞察") {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded, let summary {
                    UsageOverview(summary: summary)
                        .padding(.top, 20)
                        .transition(.opacity)
                }
                // 清除缓存（用户要求：从「存储」那一组挪进这张卡、改成胶囊钮）：收起时也在
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 0.5)
                    .padding(.top, 20)
                cacheRow
                    .padding(.top, 12)
            }
            .padding(.horizontal, AccountMetrics.inset)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if summary == nil { summary = Self.load() }
        }
        .task {
            // 开着这一页时每 15 秒刷新一次（正在放的预告片、刚载入的海报都会算进来）
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                let s = Self.load()
                if s != summary { summary = s }
            }
        }
    }

    private static func load() -> UsageSummary {
        DemoData.enabled ? .demo : UsageMeter.shared.summary()
    }

    /// 应用图标那一格 + 右上「收起 / 展开」，下面标题和说明（网页版 acc-powerup-header / -text）
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                UsageAppIcon()
                Spacer(minLength: 0)
                togglePill
            }
            // 卡里的标题和账户页的行同一号（17 半粗）：以前 Title 3，和上面的组名「使用洞察」差不多大（设计复查）
            Text("流量概览")
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// 和头部「个人档案」同一种玻璃胶囊：看上去 30 高、左右 13（和「更改」「重设」同一号：设计复查），点按区 44（F74）
    private var togglePill: some View {
        Button {
            taps += 1
            withAnimation(DSMotion.adapt(DSMotion.hero, reduce: reduceMotion)) { expanded.toggle() }
        } label: {
            Text(expanded ? "收起" : "展开")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(minHeight: 30)
                .glassEffect(.regular.interactive(), in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: taps)
        .accessibilityLabel(expanded ? "收起流量概览" : "展开流量概览")
    }

    /// 卡下一行：统计的是什么、从哪天起（演示模式直说是示例数）；清除缓存会怎样（以前写在「存储」那一组下面）
    // MARK: 清除缓存

    /// 左边「缓存」+ 占了多少，右边一颗和「收起 / 展开」同一种玻璃胶囊「清除缓存」
    private var cacheRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("缓存")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Text(clearing ? "正在清除…" : "已用 \(cacheText)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DSInk.tertiary)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            clearPill
        }
        .onAppear { cacheBytes = AppModel.cacheUsage }
    }

    private var clearPill: some View {
        Button { dissolving = true } label: {
            ZStack {
                // 转圈时胶囊不变窄
                Text("清除缓存").opacity(clearing ? 0 : 1)
                if clearing { ProgressView().controlSize(.small).tint(.white) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(minHeight: 30)
            .glassEffect(.regular.interactive(), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(clearing)
        .sensoryFeedback(.success, trigger: cleared)
        .accessibilityLabel("清除缓存")
        .accessibilityHint("清除后，片库、海报和影片信息将重新下载。")
        .accessibilityIdentifier("account-clear-cache")
        .fullScreenCover(isPresented: $dissolving) {
            CacheDissolveSheet(bytes: cacheBytes) { await clearCache() }
        }
    }

    private var cacheText: String {
        let s = Format.size(cacheBytes)
        return s.isEmpty ? "0 MB" : s
    }

    /// 清掉三样缓存，再把片库重新取一遍（和以前「存储」里那一行一样），完了给一下成功触感。
    /// 由清除动画（CacheDissolveSheet）在点「清除」时调用，动画和它同时进行
    @MainActor
    private func clearCache() async {
        clearing = true
        model.clearCaches()
        withAnimation(.snappy) { cacheBytes = AppModel.cacheUsage }
        await model.refreshAll()
        withAnimation(.snappy) { cacheBytes = AppModel.cacheUsage }
        clearing = false
        cleared += 1
    }
}

/// 网页版那枚「趋势」图标（acc-app-icon：一条往上走的折线）
private struct UsageAppIcon: View {
    @ScaledMetric(relativeTo: .title3) private var side: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
            .fill(Color.white.opacity(0.1))
            .overlay(
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: side * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// 展开后：一条虚线，然后三个数、近 24 小时的柱、本月构成；还没记过就是一段空状态。
/// 柱子和构成条滚到看得见时才长出来（错开一点的弹簧；减弱动态效果时直接出现：F59）
private struct UsageOverview: View {
    let summary: UsageSummary
    @State private var risen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DashedRule()
            if summary.isEmpty {
                UsageEmptyState()
            } else {
                UsageStats(summary: summary)
                UsageHourlyChart(hours: summary.hours, risen: risen)
                UsageShare(bytes: summary.monthByCategory, risen: risen)
            }
        }
        .onScrollVisibilityChange(threshold: 0.2) { visible in
            if visible { rise() }
        }
        .task {
            // 不在滚动视图里（或系统没报可见性）也别一直是平的
            try? await Task.sleep(for: .seconds(1.2))
            rise()
        }
    }

    private func rise() {
        guard !risen else { return }
        if reduceMotion {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { risen = true }
        } else {
            risen = true
        }
    }
}

private struct DashedRule: View {
    var body: some View {
        HLine()
            .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

private struct HLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}

/// 三个数：本月、日均、较上月（日均对日均）；中间两条细竖线隔开（网页版 acc-chart-stats-top：标签在上、数在下）
private struct UsageStats: View {
    let summary: UsageSummary

    var body: some View {
        HStack(spacing: 0) {
            tile("本月", UsageFormat.bytes(summary.monthTotal), spoken: UsageFormat.text(summary.monthTotal))
            separator
            tile("日均", UsageFormat.bytes(summary.dailyAverage), spoken: UsageFormat.text(summary.dailyAverage))
            separator
            tile("较上月", UsageFormat.trend(summary.trend), spoken: UsageFormat.spokenTrend(summary.trend))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 0.5)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }

    private func tile(_ label: String, _ value: (number: String, unit: String), spoken: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(DSInk.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.number)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if !value.unit.isEmpty {
                    Text(value.unit)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DSInk.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken)
    }
}

/// 近 24 小时：每小时一根柱，按类叠起来（视频在下、预告片、图片与资料在上，Apple「屏幕使用时间」那样）；
/// 「高」是这 24 小时里最多的那一小时、「中」是它的一半；横轴是每根柱那一小时的整点，最右「现在」。点一根柱，上面那行写这一小时用了多少
private struct UsageHourlyChart: View {
    let hours: [UsageSummary.Hour]
    let risen: Bool
    @State private var picked: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption2) private var axisHeight: CGFloat = 14

    private static let plotHeight: CGFloat = 108
    private static let labelColumn: CGFloat = 22

    private var peak: Int64 { max(1, hours.map(\.total).max() ?? 1) }
    private var sum: Int64 { hours.reduce(0) { $0 + $1.total } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            caption
            HStack(alignment: .top, spacing: 0) {
                yLabels
                VStack(spacing: 6) {
                    plot
                        .frame(height: Self.plotHeight)
                    xLabels
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("近 24 小时流量")
        .accessibilityValue(spokenSummary)
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("近 24 小时")
                .foregroundStyle(DSInk.secondary)
            Spacer(minLength: 8)
            Text(detail)
                .monospacedDigit()
                .foregroundStyle(picked == nil ? DSInk.tertiary : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.footnote.weight(.medium))
    }

    private var detail: String {
        guard let i = picked, hours.indices.contains(i) else { return "共 " + UsageFormat.text(sum) }
        let h = Self.hour(hours[i].start)
        let span = i == hours.count - 1 ? "\(h):00 至今" : "\(h):00–\((h + 1) % 24):00"
        return span + " · " + UsageFormat.text(hours[i].total)
    }

    /// 「高」「中」：字的正中压在那条线上
    private var yLabels: some View {
        ZStack(alignment: .topLeading) {
            Text("高").alignmentGuide(.top) { d in d[VerticalAlignment.center] }
            Text("中").alignmentGuide(.top) { d in d[VerticalAlignment.center] - Self.plotHeight / 2 }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(DSInk.tertiary)
        .frame(width: Self.labelColumn, height: Self.plotHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var plot: some View {
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(max(1, hours.count))
            let barWidth = min(12, max(2, slot * 0.62))
            ZStack(alignment: .bottomLeading) {
                grid(geo.size)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(hours.indices, id: \.self) { i in
                        bar(i, width: barWidth)
                            .frame(width: slot, height: geo.size.height, alignment: .bottom)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: hours)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let i = Int(location.x / max(1, slot))
                guard hours.indices.contains(i) else { return }
                withAnimation(DSMotion.snap) { picked = picked == i ? nil : i }
            }
            .sensoryFeedback(.selection, trigger: picked)
        }
    }

    /// 虚线：顶（高）和正中（中）；底下一条实线
    private func grid(_ size: CGSize) -> some View {
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: size.width, y: 0.5))
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            }
            .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Path { p in
                p.move(to: CGPoint(x: 0, y: size.height - 0.5))
                p.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            }
            .stroke(Color.white.opacity(0.2), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func bar(_ i: Int, width: CGFloat) -> some View {
        let radius = min(4, width / 2)
        let segments = Self.segments(hours[i], scale: (Self.plotHeight - 2) / CGFloat(peak))
        let dimmed = picked != nil && picked != i
        return VStack(spacing: 1) {
            ForEach(segments, id: \.category) { s in
                Rectangle()
                    .fill(UsagePalette.color(s.category))
                    .frame(height: s.height)
            }
        }
        .frame(width: width)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous))
        .opacity(dimmed ? 0.35 : 1)
        .scaleEffect(x: 1, y: risen ? 1 : 0, anchor: .bottom)
        .animation(reduceMotion ? nil : Animation.spring(response: 0.55, dampingFraction: 0.72).delay(Double(i) * 0.02), value: risen)
    }

    private struct Segment {
        let category: UsageMeter.Category
        let height: CGFloat
    }

    /// 从上到下：图片与资料、预告片、视频；不到 0.75 点的不画
    private static func segments(_ h: UsageSummary.Hour, scale: CGFloat) -> [Segment] {
        [UsageMeter.Category.data, .trailer, .video].compactMap { c in
            let height = CGFloat(h.bytes[c.rawValue]) * scale
            return height >= 0.75 ? Segment(category: c, height: height) : nil
        }
    }

    /// 横轴：第 0、6、12、18 根柱那一小时的整点（滚动的 24 小时，不是今天的 0 点），最右「现在」
    private var xLabels: some View {
        GeometryReader { geo in
            let slot = geo.size.width / 24
            ZStack(alignment: .topLeading) {
                // 特大字号时五个字挤不下（折起时柱那一段约 254 点）：只写 0、12 两处和「现在」
                ForEach(typeSize.isAccessibilitySize ? [0, 12] : [0, 6, 12, 18], id: \.self) { i in
                    if hours.indices.contains(i) {
                        Text(verbatim: "\(Self.hour(hours[i].start)):00")
                            .fixedSize()
                            .offset(x: CGFloat(i) * slot)
                    }
                }
                Text("现在")
                    .fixedSize()
                    .frame(width: geo.size.width, alignment: .trailing)
            }
        }
        .frame(height: axisHeight)
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(DSInk.tertiary)
        .accessibilityHidden(true)
    }

    private var spokenSummary: String {
        guard sum > 0, let top = hours.indices.max(by: { hours[$0].total < hours[$1].total }) else {
            return "过去 24 小时未使用流量"
        }
        return "共 \(UsageFormat.text(sum))，\(Self.hour(hours[top].start)) 点最多，为 \(UsageFormat.text(hours[top].total))"
    }

    private static func hour(_ d: Date) -> Int {
        Calendar.current.component(.hour, from: d)
    }
}

/// 本月构成：一条细的分段条（三类首尾相接、中间 2 点空隙、圆头，没有的那类不画），下面图例：色块、「视频播放 · 62%」、多少 GB。
/// 放得下就三列（左、中、右），放不下（折起的 Duo、大字号）就一类一行
private struct UsageShare: View {
    let bytes: [Int64]
    let risen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Int64 { bytes.reduce(0, +) }
    private var percents: [Int] { UsageFormat.percents(bytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本月构成")
                .font(.footnote.weight(.medium))
                .foregroundStyle(DSInk.secondary)
            bar
            ViewThatFits(in: .horizontal) {
                columns
                rows
            }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let parts = UsageMeter.Category.allCases.filter { bytes[$0.rawValue] > 0 }
            let room = geo.size.width - CGFloat(max(0, parts.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(parts, id: \.self) { c in
                    Capsule()
                        .fill(UsagePalette.color(c))
                        .frame(width: max(1, room * CGFloat(bytes[c.rawValue]) / CGFloat(max(1, total))))
                }
            }
            .scaleEffect(x: risen ? 1 : 0.001, y: 1, anchor: .leading)
            .animation(reduceMotion ? nil : Animation.spring(response: 0.7, dampingFraction: 0.86).delay(0.15), value: risen)
        }
        .frame(height: 10)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .accessibilityHidden(true)
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 12) {
            legend(.video, alignment: .leading)
            legend(.trailer, alignment: .center)
            legend(.data, alignment: .trailing)
        }
    }

    private func legend(_ c: UsageMeter.Category, alignment: HorizontalAlignment) -> some View {
        let frameAlignment: Alignment = alignment == .leading ? .leading : (alignment == .center ? .center : .trailing)
        return VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                swatch(c)
                Text(title(c))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DSInk.secondary)
            }
            amount(c)
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(c))
        .accessibilityValue(UsageFormat.text(bytes[c.rawValue]))
    }

    private var rows: some View {
        VStack(spacing: 10) {
            ForEach(UsageMeter.Category.allCases, id: \.self) { c in
                HStack(spacing: 8) {
                    swatch(c)
                    Text(title(c))
                        .font(.subheadline)
                        .foregroundStyle(DSInk.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    amount(c)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title(c))
                .accessibilityValue(UsageFormat.text(bytes[c.rawValue]))
            }
        }
    }

    private func title(_ c: UsageMeter.Category) -> String {
        UsagePalette.name(c) + " · \(percents[c.rawValue])%"
    }

    private func swatch(_ c: UsageMeter.Category) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(UsagePalette.color(c))
            .frame(width: 10, height: 10)
    }

    private func amount(_ c: UsageMeter.Category) -> some View {
        let v = UsageFormat.bytes(bytes[c.rawValue])
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(v.number)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(v.unit)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DSInk.tertiary)
        }
        .lineLimit(1)
    }
}

/// 还没有记录
private struct UsageEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(DSInk.tertiary)
                .accessibilityHidden(true)
            Text("暂无流量记录")
                .font(.headline)
                .foregroundStyle(.white)
            Text("播放或浏览后，这里会按小时显示流量使用情况。")
                .font(.subheadline)
                .foregroundStyle(DSInk.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 颜色、名字、数的写法

/// 三类的颜色：视频是网页版图表的那种橙，预告片蓝、图片与资料青绿（在深色卡上过了色盲区分、对比度检查；字一律用白 / 灰，不用这几个色）
enum UsagePalette {
    static let video = Color(red: 0xE8 / 255.0, green: 0x69 / 255.0, blue: 0x2A / 255.0)
    static let trailer = Color(red: 0x39 / 255.0, green: 0x87 / 255.0, blue: 0xE5 / 255.0)
    static let data = Color(red: 0x19 / 255.0, green: 0x9E / 255.0, blue: 0x70 / 255.0)

    static func color(_ c: UsageMeter.Category) -> Color {
        switch c {
        case .video: return video
        case .trailer: return trailer
        case .data: return data
        }
    }

    static func name(_ c: UsageMeter.Category) -> String {
        switch c {
        case .video: return "视频播放"
        case .trailer: return "预告片"
        case .data: return "图片与资料"
        }
    }
}

enum UsageFormat {
    /// 数和单位分开（单位排小一号）：不到 1 GB 用 MB（10 MB 以下带一位小数），1 GB 起用 GB（100 以下带一位小数）；按 1000 进位（和系统的「存储空间」一样）
    static func bytes(_ b: Int64) -> (number: String, unit: String) {
        let mb = Double(max(0, b)) / 1_000_000
        if mb < 999.5 {
            if b <= 0 { return ("0", "MB") }
            if mb < 0.1 { return ("<0.1", "MB") }
            return (mb < 10 ? String(format: "%.1f", mb) : String(format: "%.0f", mb), "MB")
        }
        let gb = mb / 1000
        return (gb < 99.95 ? String(format: "%.1f", gb) : String(format: "%.0f", gb), "GB")
    }

    static func text(_ b: Int64) -> String {
        let v = bytes(b)
        return v.number + " " + v.unit
    }

    /// 较上月：「↑12 %」「↓8 %」，没有上个月的数据是「—」
    static func trend(_ t: Double?) -> (number: String, unit: String) {
        guard let t, t.isFinite else { return ("—", "") }
        let n = Int(min(999, abs(t)).rounded())
        if n == 0 { return ("0", "%") }
        return ((t > 0 ? "↑" : "↓") + "\(n)", "%")
    }

    static func spokenTrend(_ t: Double?) -> String {
        guard let t, t.isFinite else { return "暂无上月数据" }
        let n = Int(min(999, abs(t)).rounded())
        if n == 0 { return "与上月持平" }
        return (t > 0 ? "日均多 " : "日均少 ") + "\(n)%"
    }

    /// 百分比凑满 100（最大余数法）
    static func percents(_ v: [Int64]) -> [Int] {
        let total = v.reduce(0, +)
        guard total > 0 else { return v.map { _ in 0 } }
        let raw = v.map { Double($0) * 100 / Double(total) }
        var out = raw.map { Int($0.rounded(.down)) }
        var left = 100 - out.reduce(0, +)
        let order = raw.indices.sorted { (raw[$0] - Double(out[$0])) > (raw[$1] - Double(out[$1])) }
        for i in order where left > 0 {
            out[i] += 1
            left -= 1
        }
        return out
    }
}

// MARK: - 演示模式

extension UsageSummary {
    /// 演示模式（截图用，不连网、不计量）：一组固定的示例数——和演示片库一样是假的，只为看得到版式；不是随机数
    static var demo: UsageSummary {
        let cal = Calendar.current
        let now = Date()
        let hourNow = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let start = hourNow.addingTimeInterval(-23 * 3600)
        // 按钟点：晚上看得多、半夜和白天少（MB）
        let byClock: [Double] = [180, 60, 0, 0, 0, 0, 0, 12, 30, 8, 0, 25, 60, 40, 10, 0, 20, 45, 120, 260, 420, 380, 310, 240]
        let hours = (0..<24).map { i -> Hour in
            let t = start.addingTimeInterval(TimeInterval(i) * 3600)
            let mb = byClock[cal.component(.hour, from: t) % 24]
            return Hour(start: t, bytes: [Int64(mb * 780_000), Int64(mb * 150_000), Int64(mb * 70_000)])
        }
        return UsageSummary(hours: hours, monthByCategory: [9_800_000_000, 2_100_000_000, 720_000_000],
                            monthTotal: 12_620_000_000, dailyAverage: 742_000_000, trend: 12, since: nil, isEmpty: false)
    }
}
