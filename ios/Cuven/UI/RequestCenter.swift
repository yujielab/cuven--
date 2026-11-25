import SwiftUI

// MARK: - 请求中心（标签栏「请求」）
//
// 用户要求：导航栏里加一格「请求」，一个和现在 App 同样风格的请求中心，保留最近 10 个请求，可以复用现有的步进器。
// 和搜索页一样是系统大标题「请求」（C13，往上滚收成小标题），下面两段：
// · 进行中：一张一张液态玻璃卡，上面一行小海报 + 片名 + 「电影 · 2026」，下面就是详情页那张五步进度卡（RequestProgressCard 原样复用：
//   STEP X OF 5、绿色百分比、五段胶囊、五步的名字、那一行固定的说明）。展开的屏两张一排。点整张卡进那部的详情页
// · 最近：一行一部（和搜索结果的列表行同一个样子：小海报、片名、一行灰字），成功和出错的分开两张卡（用户要求「错误和成功的列表分离」）：
//   「已就绪」一张（右边一颗半透明「播放」，按下去直接放片库里的这部：RequestPlayback，和详情页的「立即播放」同一套），
//   「未能添加」一张（没能添加的、取消了的；点进去是那部的详情页，可以再请求一次）
// 只保留最近 10 个（按提交的先后）；空的时候说下一步去哪儿（F88），给一颗「去搜索」。下拉刷新、打开时马上问一次服务器。
// 标签栏那一格上的角标是进行中的个数。
// 批量流程（用户要求）：最上面是「Luminous Data Flow」那张卡（RequestFlowCard：四段的数和漏斗占满整张卡、批量传输的进度条），
// 下面「待确认」是请求篮（详情页按「请求添加」放进来的，最多 50 部），按「确认请求」一次提交；进行中的全部列出来（一批最多 50 部，不止 10 个）。

struct RequestCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opening: Int?
    @State private var problem: RequestPlayback.Problem?
    @State private var basketCleared = false

    static let keep = 10
    private var store: RequestStore { RequestStore.shared }

    var body: some View {
        ZoomStack {
            GeometryReader { geo in
                let insets = geo.safeAreaInsets
                content(DSMetrics(width: geo.size.width, leadingInset: insets.leading, trailingInset: insets.trailing, height: geo.size.height))
            }
            .background(Theme.bg)
            .navigationTitle("请求")
            .navigationBarTitleDisplayMode(.large)
        }
        .task { await store.refreshNow() }
        // 开着的时候一直问传输流（凑批的进度、正在跑的那一批），关了就停
        .task { await store.watchFlow() }
        .alert(problem?.title ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }), presenting: problem) { _ in
            Button("好", role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
    }

    private var basket: RequestBasket { RequestBasket.shared }

    /// 版面跟着变的那几样：哪几部在进行中、哪几部结束了（就绪的和没成的分开记）、请求篮空没空、流程卡在不在、卡底那一条是哪一种。
    /// 它们一变，整页一起平滑地挪过去（以前只有请求篮里增减带动画：一部走完从「进行中」换到「已就绪」、
    /// 流程卡和卡底的进度条冒出来、最后一部清掉变回空页，都是硬切的）
    private struct LayoutKey: Equatable {
        let active: [Int]
        let ended: [Int]
        let basketEmpty: Bool
        let showFlow: Bool
        let footer: Int
    }

    private func layoutKey(active: [RequestStatus], ended: [RequestStatus], showFlow: Bool) -> LayoutKey {
        // 卡底那一条：2 = 批量传输的进度条，1 = 凑批，0 = 没有（和 RequestFlowCard 的 footer 同一个判断）
        let footer: Int
        if store.flow?.batch != nil {
            footer = 2
        } else if let g = store.flow?.gate, g.ready > 0 {
            footer = 1
        } else {
            footer = 0
        }
        return LayoutKey(active: active.map { $0.id },
                         ended: ended.map { $0.state == .done ? $0.id : -$0.id },
                         basketEmpty: basket.items.isEmpty, showFlow: showFlow, footer: footer)
    }

    /// 整页挪动的那条曲线；「减弱动态效果」打开时换成短淡入（DSMotion.adapt）
    private var shift: Animation { DSMotion.adapt(.smooth(duration: 0.35), reduce: reduceMotion) }

    @ViewBuilder
    private func content(_ m: DSMetrics) -> some View {
        let active = store.mine.filter { $0.state == .active }
        // 已就绪、没成的各留最近 10 个（分开两张卡，一边多了不挤掉另一边）
        let ended = Array(store.mine.filter { $0.state == .done }.prefix(Self.keep))
            + Array(store.mine.filter { $0.state != .active && $0.state != .done }.prefix(Self.keep))
        let showFlow = !RequestFlowStats.inFlow(store.mine).isEmpty || store.flow?.batch != nil
        if showFlow && m.width >= Self.splitWidth {
            split(m, active: active, ended: ended)
        } else {
            single(m, active: active, ended: ended, showFlow: showFlow)
        }
    }

    /// iPad 横拿（窗口宽于 1100 点：普通 iPad、Pro 11 / 13 寸横拿）：左右两栏（用户要求按 Apple 的做法给 iPad 定制）——
    /// 左边一栏滚动：待确认、进行中（一列）、最近；右边一栏是那张 Luminous Data Flow 卡，钉在顶上不跟着滚
    static let splitWidth: CGFloat = 1100

    private func split(_ m: DSMetrics, active: [RequestStatus], ended: [RequestStatus]) -> some View {
        let right = min(640, max(600, (m.width * 0.46).rounded()))
        // 两栏之间留一道缝（一个半卡距）：以前左栏的卡右边直接贴着流程卡，读着像一整块（用户要求「保持一定的留白，整个界面看上去不会拥挤」）。
        // 缝从左栏里扣，HStack 的间距补回去，两栏加起来还是原来那么宽
        let columnGap = (m.gutter * 1.5).rounded()
        let leftW = m.width - right - m.margin - columnGap
        let lm = DSMetrics(width: leftW, leadingInset: m.leadingInset, trailingInset: 0, height: m.height)
        let rm = DSMetrics(width: right, height: m.height)
        return HStack(alignment: .top, spacing: columnGap) {
            ScrollView {
                VStack(alignment: .leading, spacing: lm.shelfGap) {
                    if !basket.items.isEmpty { basketSection(lm) }
                    if !active.isEmpty { activeSection(active, lm, columns: 1) }
                    if !ended.isEmpty { recentSections(ended, lm) }
                }
                // 上下留白用全页统一的 pageTop / pageBottom（以前 4 / 40，大标题下面贴得太紧）；两栏用同一个 m，顶上对齐
                .padding(.top, m.pageTop)
                .padding(.bottom, m.pageBottom)
                .padding(.leading, m.leadingInset)
                .animation(shift, value: basket.items)
            }
            .scrollIndicators(.hidden)
            .frame(width: leftW + m.leadingInset)
            // 不用系统的 .refreshable：演示数据、没登录时刷新一瞬间就做完，转圈会卡在「刷新中」（见 SettledRefresh）
            .settledRefreshable { await store.refreshNow() }
            RequestFlowCard(requests: store.mine, flow: store.flow, flowAt: store.flowAt, metrics: rm)
                .frame(width: right)
                .padding(.top, m.pageTop)
                .padding(.trailing, m.margin)
                .accessibilityIdentifier("request-flow-card")
        }
        .animation(shift, value: layoutKey(active: active, ended: ended, showFlow: true))
        .ignoresSafeArea(edges: .horizontal)
    }

    private func single(_ m: DSMetrics, active: [RequestStatus], ended: [RequestStatus], showFlow: Bool) -> some View {
        ScrollView {
            Group {
                if active.isEmpty && ended.isEmpty && basket.items.isEmpty && !showFlow {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: m.shelfGap) {
                        if showFlow {
                            RequestFlowCard(requests: store.mine, flow: store.flow, flowAt: store.flowAt, metrics: m)
                                .frame(maxWidth: 980, alignment: .leading)
                                .padding(.horizontal, m.margin)
                                .accessibilityIdentifier("request-flow-card")
                        }
                        if !basket.items.isEmpty { basketSection(m) }
                        if !active.isEmpty { activeSection(active, m) }
                        if !ended.isEmpty { recentSections(ended, m) }
                    }
                    // 大标题到第一块、页底留白和别的页一样（以前 4 / 40）
                    .padding(.top, m.pageTop)
                    .padding(.bottom, m.pageBottom)
                    .animation(shift, value: basket.items)
                }
            }
            // 字和卡留在安全区里（和搜索页一样）
            .padding(.leading, m.leadingInset)
            .padding(.trailing, m.trailingInset)
            // 挂在外面这一层：空页和有内容的那一列互相换的时候也带得上
            .animation(shift, value: layoutKey(active: active, ended: ended, showFlow: showFlow))
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .horizontal)
        // 不用系统的 .refreshable：演示数据、没登录时刷新一瞬间就做完，转圈会卡在「刷新中」（见 SettledRefresh）
        .settledRefreshable { await store.refreshNow() }
    }

    // MARK: 待确认（请求篮）

    /// 详情页按「请求添加」放进来的：一行一部，右边一颗「移除」；最下面「清空」和「确认请求 · N 部」
    private func basketSection(_ m: DSMetrics) -> some View {
        // 标题下面是一张卡（不是横排的 DSShelf，没有那 4 点回弹的余量）：用 blockTitleGap，看上去和别的页标题到一排卡一样远
        VStack(alignment: .leading, spacing: m.blockTitleGap) {
            HStack(alignment: .firstTextBaseline) {
                DSShelfTitle(title: "待确认", metrics: m)
                Spacer(minLength: 8)
                Text("\(basket.items.count) / \(RequestBasket.limit)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(DSInk.tertiary)
                    .contentTransition(.numericText())
                    .padding(.trailing, m.margin)
            }
            // 和下面那张卡同宽（卡最宽 720）：iPad 上右边的数停在卡的右边线上，不跑到屏幕最右边去
            .frame(maxWidth: 720 + m.margin * 2, alignment: .leading)
            VStack(spacing: 0) {
                ForEach(Array(basket.items.enumerated()), id: \.element.key) { i, item in
                    basketRow(item)
                    if i < basket.items.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).padding(.leading, 20 + 44 + 14)
                    }
                }
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5)
                basketFooter
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.07)))
            // 和上面那张流程卡、账户页的卡一样有一圈细边（以前只有底色，没有边：设计复查）
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(DSFill.hairline, lineWidth: 1))
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, m.margin)
        }
        .confirmationDialog("清空请求中心里还没确认的 \(basket.items.count) 部？", isPresented: $basketCleared, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                basket.clear()
                // 和一部一部移除时同一下轻震
                Haptics.light()
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 请求篮最下面那一行：「清空」和「确认请求 · N 部」。
    /// 两颗的点按区都够 44 点高（F74；以前「清空」只有那两个字那么大、白胶囊 38 高），画出来和这一行的高都没变（9 + 44 + 9 = 12 + 38 + 12）
    private var basketFooter: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) { basketCleared = true } label: {
                Text("清空")
                    .font(.subheadline)
                    .foregroundStyle(DSInk.secondary)
                    // 提交中按不了：字淡下去（自己的按压样式不会像系统的那样自动变淡）
                    .opacity(basket.submitting ? 0.4 : 1)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.95))
            .disabled(basket.submitting)
            .accessibilityIdentifier("basket-clear")
            Spacer(minLength: 8)
            Button { confirmBasket() } label: {
                HStack(spacing: 8) {
                    if basket.submitting {
                        ProgressView().controlSize(.small).tint(.black)
                    }
                    Text("确认请求 · \(basket.items.count) 部")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(minHeight: 38)
                .background(Capsule().fill(Color.white))
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.95))
            .disabled(basket.submitting)
            .accessibilityIdentifier("basket-confirm")
        }
        // 卡里的字离卡边 20（以前 16）：圆角 22 的卡里字贴着边，看着挤
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        // 转圈冒出来、收回去时白胶囊平滑地变宽，不跳
        .animation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion), value: basket.submitting)
    }

    private func basketRow(_ item: RequestBasket.Item) -> some View {
        HStack(spacing: 12) {
            ZoomLink(route: .catalog(item.catalogTitle), slot: "request-basket", press: true) {
                HStack(spacing: 14) {
                    DSThumb(url: TMDBImage.url(item.poster, "w185"), width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title.isEmpty ? "未知影片" : item.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text([item.kind == .tv ? "剧集" : "电影",
                              item.kind == .tv && item.season > 0 ? "第 \(item.season) 季" : nil,
                              item.year.isEmpty ? nil : item.year].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(DSInk.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            Button {
                withAnimation(DSMotion.adapt(.smooth(duration: 0.3), reduce: reduceMotion)) { basket.remove(item) }
                Haptics.light()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(DSInk.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(basket.submitting)
            .accessibilityLabel("从请求中心移除 \(item.title)")
            .accessibilityIdentifier("basket-remove")
        }
        .padding(.leading, 20)
        // 「移除」那颗圆（约 24 点宽，在 44 点的点按区正中）右边线离卡边 20：和底下白胶囊、另外两张卡的「播放」「›」同一条线（以前 6，圆比它们靠外 4 点）
        .padding(.trailing, 10)
        .accessibilityIdentifier("basket-row")
    }

    private func confirmBasket() {
        guard !basket.submitting else { return }
        Haptics.light()
        Task { @MainActor in
            do {
                let r = try await basket.submit()
                var notes: [String] = []
                if r.joined > 0 { notes.append("\(r.joined) 部已经有人在请求，已为你跟上。") }
                if r.failedRecently > 0 { notes.append("\(r.failedRecently) 部刚刚没能添加，请稍后再试。") }
                if r.refused > 0 { notes.append("\(r.refused) 部超出了同时进行的上限，已留在待确认里。") }
                if notes.isEmpty {
                    Haptics.success()
                } else {
                    problem = RequestPlayback.Problem(title: "已提交 \(r.accepted + r.joined) 部", message: notes.joined(separator: "\n"))
                }
            } catch {
                Haptics.error()
                problem = RequestPlayback.Problem(title: "没能提交", message: error.localizedDescription)
            }
        }
    }

    // MARK: 进行中

    private func activeSection(_ list: [RequestStatus], _ m: DSMetrics, columns n: Int? = nil) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: m.gutter, alignment: .top), count: n ?? (m.wide ? 2 : 1))
        return VStack(alignment: .leading, spacing: m.blockTitleGap) {
            DSShelfTitle(title: "进行中", metrics: m)
            LazyVGrid(columns: columns, alignment: .leading, spacing: m.gutter) {
                ForEach(list) { s in
                    ZoomLink(route: .catalog(s.catalogTitle), slot: "request-center", press: true) {
                        RequestCenterCard(status: s)
                    }
                    .accessibilityIdentifier("request-center-card")
                }
            }
            .padding(.horizontal, m.margin)
        }
    }

    // MARK: 最近：成功和出错分开

    /// 「已就绪」「未能添加」两张卡（用户要求「错误和成功的列表分离」）；哪一边没有就不出那一张。两张之间隔一道排距
    @ViewBuilder
    private func recentSections(_ ended: [RequestStatus], _ m: DSMetrics) -> some View {
        let done = ended.filter { $0.state == .done }
        let other = ended.filter { $0.state != .done }
        VStack(alignment: .leading, spacing: m.shelfGap) {
            if !done.isEmpty { recentSection("已就绪", done, m) }
            if !other.isEmpty { recentSection("未能添加", other, m) }
        }
    }

    private func recentSection(_ title: String, _ list: [RequestStatus], _ m: DSMetrics) -> some View {
        VStack(alignment: .leading, spacing: m.blockTitleGap) {
            DSShelfTitle(title: title, metrics: m)
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                    recentRow(s)
                    if i < list.count - 1 {
                        // 细线从字的左边线开始（C51）
                        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).padding(.leading, 20 + 44 + 14)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.07)))
            // 和上面那张流程卡、账户页的卡一样有一圈细边（以前只有底色，没有边：设计复查）
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(DSFill.hairline, lineWidth: 1))
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, m.margin)
        }
    }

    private func recentRow(_ s: RequestStatus) -> some View {
        HStack(spacing: 12) {
            ZoomLink(route: .catalog(s.catalogTitle), slot: "request-recent", press: true) {
                HStack(spacing: 14) {
                    DSThumb(url: TMDBImage.url(s.poster, "w185"), width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title.isEmpty ? "未知影片" : s.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(dotColor(s)).frame(width: 7, height: 7)
                            Text(statusLine(s))
                                .font(.subheadline)
                                .foregroundStyle(DSInk.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if s.state != .done {
                        // 只是样子，不念给旁白（和分区标题后面的「›」一样）
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DSInk.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("request-center-row")
            if s.state == .done { playButton(s) }
        }
        // 和待确认那张卡一样离卡边 20，细线也跟着从 20 + 44 + 14 起
        .padding(.horizontal, 20)
    }

    /// 已就绪的：半透明胶囊「播放」，直接放片库里的这部。
    /// 以前是白胶囊黑字，几部就绪时右边一列白胶囊，抢了「确认请求」那颗主操作；一行一颗的操作改成轻的（16% 白底白字，和详情页相关卡的胶囊一样：设计复查）
    private func playButton(_ s: RequestStatus) -> some View {
        Button {
            guard opening == nil else { return }
            opening = s.id
            Task { @MainActor in
                problem = await RequestPlayback.play(s.catalogTitle, season: s.season, model: model, artwork: nil)
                opening = nil
            }
        } label: {
            HStack(spacing: 6) {
                // 转圈压在三角那一格上（三角只是藏起来、位置还占着）：等片库的那一会儿胶囊不变宽、「播放」两个字不挪，两样交叉淡入淡出
                Image(systemName: "play.fill").font(.footnote.weight(.bold))
                    .opacity(opening == s.id ? 0 : 1)
                    .overlay {
                        if opening == s.id { ProgressView().controlSize(.small).tint(.white) }
                    }
                    .animation(DSMotion.adapt(DSMotion.snap, reduce: reduceMotion), value: opening)
                Text("播放").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .accessibilityLabel("播放 \(s.title)")
        .accessibilityIdentifier("request-center-play")
    }

    private func statusLine(_ s: RequestStatus) -> String {
        let what: String
        switch s.state {
        case .done: what = "已就绪"
        case .failed: what = "未能添加"
        case .cancelled: what = "已取消"
        case .active: what = RequestStatus.labels[max(0, min(4, s.step - 1))]
        }
        let season = s.season > 0 ? "第 \(s.season) 季 · " : ""
        let ago = s.updated > 0 ? " · " + Relative.string(Date(timeIntervalSince1970: s.updated / 1000)) : ""
        return season + what + ago
    }

    private func dotColor(_ s: RequestStatus) -> Color {
        switch s.state {
        case .done: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .failed: return Color(red: 1.0, green: 0.27, blue: 0.23)
        case .cancelled, .active: return Color.white.opacity(0.35)
        }
    }

    // MARK: 空的时候

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有请求", systemImage: "tray")
        } description: {
            Text("在搜索里找到片库还没有的影片，打开详情页点「请求添加」，再回到这里确认。")
        } actions: {
            Button("去搜索") { model.searchRequest = "" }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("request-center-search")
        }
        .padding(.top, 80)
    }
}

/// 请求中心里进行中的一张卡：上面一行小海报 + 片名 + 「电影 · 2026」，下面是五步进度卡（和详情页同一个 RequestProgressCard），
/// 整张是一块液态玻璃（和详情页那张卡同一个圆角）
struct RequestCenterCard: View {
    let status: RequestStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                DSThumb(url: TMDBImage.url(status.poster, "w185"), width: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title.isEmpty ? "未知影片" : status.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(DSInk.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DSInk.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            RequestProgressCard(status: status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, .dark)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        // 服务器的进度到了：百分比滚过去、那一段胶囊平滑地填上（和详情页那张卡同一条曲线）。
        // 以前这里没有动画，卡里的 numericText 从来没跑过，数和胶囊都是跳的
        .animation(DSMotion.adapt(.smooth(duration: 0.45), reduce: reduceMotion), value: status)
    }

    private var line: String {
        [status.src == "tv" ? "剧集" : "电影",
         status.season > 0 ? "第 \(status.season) 季" : nil,
         status.year.isEmpty ? nil : status.year].compactMap { $0 }.joined(separator: " · ")
    }
}
