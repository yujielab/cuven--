import SwiftUI

// MARK: - 请求中心（标签栏「请求」）
//
// 用户要求：导航栏里加一格「请求」，一个和现在 App 同样风格的请求中心，保留最近 10 个请求，可以复用现有的步进器。
// 和搜索页一样是系统大标题「请求」（C13，往上滚收成小标题），下面两段：
// · 进行中：一张一张液态玻璃卡，上面一行小海报 + 片名 + 「电影 · 2026」，下面就是详情页那张五步进度卡（RequestProgressCard 原样复用：
//   STEP X OF 5、绿色百分比、五段胶囊、五步的名字、那一行固定的说明）。展开的屏两张一排。点整张卡进那部的详情页
// · 最近：已就绪 / 没能添加 / 取消了的，一行一部（和搜索结果的列表行同一个样子：小海报、片名、一行灰字），已就绪的右边一颗白色「播放」，
//   按下去直接放片库里的这部（RequestPlayback，和详情页的「立即播放」同一套）
// 只保留最近 10 个（按提交的先后）；空的时候说下一步去哪儿（F88），给一颗「去搜索」。下拉刷新、打开时马上问一次服务器。
// 标签栏那一格上的角标是进行中的个数。

struct RequestCenterView: View {
    @Environment(AppModel.self) private var model
    @State private var opening: Int?
    @State private var problem: RequestPlayback.Problem?

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
        .alert(problem?.title ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }), presenting: problem) { _ in
            Button("好", role: .cancel) {}
        } message: { p in
            Text(p.message)
        }
    }

    private func content(_ m: DSMetrics) -> some View {
        let recent = Array(store.mine.prefix(Self.keep))
        let active = recent.filter { $0.state == .active }
        let ended = recent.filter { $0.state != .active }
        return ScrollView {
            Group {
                if recent.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: m.shelfGap) {
                        summary(active: active, ended: ended, m)
                        if !active.isEmpty { activeSection(active, m) }
                        if !ended.isEmpty { recentSection(ended, m) }
                        Text("请求中心只保留最近 \(Self.keep) 个请求。")
                            .font(.footnote)
                            .foregroundStyle(DSInk.tertiary)
                            .padding(.horizontal, m.margin)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 40)
                }
            }
            // 字和卡留在安全区里（和搜索页一样）
            .padding(.leading, m.leadingInset)
            .padding(.trailing, m.trailingInset)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .horizontal)
        .refreshable { await store.refreshNow() }
    }

    // MARK: 顶上一行

    /// 「3 个进行中 · 2 部已就绪」：一眼看到现在的情况（只写有的）
    @ViewBuilder
    private func summary(active: [RequestStatus], ended: [RequestStatus], _ m: DSMetrics) -> some View {
        let waiting = active.filter { $0.stage == "release" }.count
        let ready = ended.filter { $0.state == .done }.count
        let parts = [
            active.count - waiting > 0 ? "\(active.count - waiting) 个进行中" : nil,
            waiting > 0 ? "\(waiting) 个等待最终发行审批" : nil,
            ready > 0 ? "\(ready) 部已就绪" : nil,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(DSInk.secondary)
                .padding(.horizontal, m.margin)
        }
    }

    // MARK: 进行中

    private func activeSection(_ list: [RequestStatus], _ m: DSMetrics) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: m.gutter, alignment: .top), count: m.wide ? 2 : 1)
        return VStack(alignment: .leading, spacing: m.titleGap) {
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

    // MARK: 最近

    private func recentSection(_ list: [RequestStatus], _ m: DSMetrics) -> some View {
        VStack(alignment: .leading, spacing: m.titleGap) {
            DSShelfTitle(title: "最近", metrics: m)
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                    recentRow(s)
                    if i < list.count - 1 {
                        // 细线从字的左边线开始（C51）
                        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).padding(.leading, 16 + 44 + 14)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.07)))
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
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DSInk.tertiary)
                    }
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("request-center-row")
            if s.state == .done { playButton(s) }
        }
        .padding(.horizontal, 16)
    }

    /// 已就绪的：白色胶囊「播放」（和详情页的主操作同一种颜色），直接放片库里的这部
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
                if opening == s.id {
                    ProgressView().controlSize(.small).tint(.black)
                } else {
                    Image(systemName: "play.fill").font(.footnote.weight(.bold))
                }
                Text("播放").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(Color.white))
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
            Text("在搜索里找到片库还没有的影片，打开详情页点「请求添加」。")
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
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            RequestProgressCard(status: status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, .dark)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var line: String {
        [status.src == "tv" ? "剧集" : "电影",
         status.season > 0 ? "第 \(status.season) 季" : nil,
         status.year.isEmpty ? nil : status.year].compactMap { $0 }.joined(separator: " · ")
    }
}
