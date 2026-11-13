import SwiftUI

// MARK: - 文件夹：和网页版一样（folderCardHTML / enterFolder）
//
// 首页最后那排「文件夹」：一张张竖版卡（与竖版海报同宽、2:3、圆角 14），黄色的淡渐变底、黄色细描边，
// 正中一个大号文件夹图标，下面文件夹名。点进去是文件夹页：标题是文件夹名（28 号 800 粗），
// 有子文件夹先是一排文件夹卡；视频按文件名里的年份分组（新的在前，没年份的归「其他」），
// 每组「2026 年  N 部」，下面是瀑布流（两列、间距 7；格子的高宽比按网页版那条固定的序列排，
// 矮格用剧照、高格用海报，压一层暗场，左下角片名与「年份 · 4K · 杜比视界」）。

/// 网页版 .card-folder
struct FolderCard: View {
    let folder: LibraryFolder
    var width: CGFloat = 191

    private static let yellow = Color(red: 1, green: 214 / 255, blue: 10 / 255)

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 56))
                .foregroundStyle(Self.yellow)
            Text(folder.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: width, height: width * 1.5)
        .background(
            LinearGradient(colors: [Color(red: 1, green: 214 / 255, blue: 10 / 255).opacity(0.18),
                                    Color(red: 1, green: 159 / 255, blue: 10 / 255).opacity(0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color(red: 1, green: 214 / 255, blue: 10 / 255).opacity(0.22), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("文件夹 " + folder.name)
    }
}

/// 文件夹页（网页版 enterFolder）
struct FolderView: View {
    @Environment(AppModel.self) private var model
    let folder: LibraryFolder
    @State private var subfolders: [LibraryFolder] = []
    @State private var videos: [Video] = []
    @State private var loading = true
    @State private var failed: String?
    @State private var showTitle = false

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(folder.name)
                        .font(.system(size: 28, weight: .heavy))
                        .tracking(-0.56)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.horizontal, Theme.gutter)
                        .padding(.top, 12)
                        .padding(.bottom, 8)

                    if loading && subfolders.isEmpty && videos.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else if let failed, subfolders.isEmpty, videos.isEmpty {
                        FolderEmpty(symbol: "exclamationmark.circle", title: "加载失败", detail: failed)
                    } else {
                        content(width: geo.size.width)
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { g in g.contentOffset.y + g.contentInsets.top > 50 } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { showTitle = v }
            }
        }
        .background(Theme.bg)
        .navigationTitle(showTitle ? folder.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: folder.path) { await load() }
    }

    @ViewBuilder private func content(width: CGFloat) -> some View {
        // 没有封面的不显示（网页版 ArtGate.filter）
        let shown = videos.filter { !model.hidden.contains($0.name) }
        if !subfolders.isEmpty {
            Rail(spacing: 17) {
                ForEach(subfolders) { f in
                    ZoomLink(route: .folder(f), slot: "folder") { FolderCard(folder: f) }
                        .accessibilityIdentifier("folder-card")
                }
            }
            .padding(.top, 16)
        }
        ForEach(Self.groups(shown)) { g in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(g.label)
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.28)
                        .foregroundStyle(.white)
                    Text(verbatim: "\(g.items.count) 部")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, FolderMasonry.pad(width) + 3)
                .padding(.top, 26)
                .padding(.bottom, 12)
                FolderMasonry(items: g.items, width: width)
            }
        }
        if subfolders.isEmpty && shown.isEmpty && !loading {
            FolderEmpty(symbol: "folder", title: "空文件夹", detail: nil)
        }
    }

    struct YearBucket: Identifiable {
        let id: String
        let label: String
        let items: [Video]
    }

    /// 按文件名里的年份分组（网页版 parse(v.name).year），新的在前；没有年份的归「其他」，放最后
    private static func groups(_ list: [Video]) -> [YearBucket] {
        var by: [Int: [Video]] = [:]
        var other: [Video] = []
        for v in list {
            if let y = FileName.year(v.name) { by[y, default: []].append(v) } else { other.append(v) }
        }
        var out = by.keys.sorted(by: >).map { y in YearBucket(id: "y\(y)", label: "\(y) 年", items: by[y] ?? []) }
        if !other.isEmpty { out.append(YearBucket(id: "other", label: "其他", items: other)) }
        return out
    }

    private func load() async {
        failed = nil
        loading = true
        do {
            let r = try await model.folderContents(folder)
            subfolders = r.folders
            videos = r.videos
            loading = false
            await model.ensureMetas(for: r.videos)
        } catch {
            failed = error.localizedDescription
            loading = false
        }
    }
}

/// 网页版 .empty：一个图标、一行标题、一行灰字
private struct FolderEmpty: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.white.opacity(0.3))
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 14)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 80)
    }
}

// MARK: - 瀑布流（网页版 masonryHTML：等宽的列，格子按「最短的那列先放」）

struct FolderMasonry: View {
    let items: [Video]
    let width: CGFloat

    /// 网页版 MAS_RATIOS（高 / 宽）：比例先定死，版面不等图片
    static let ratios: [CGFloat] = [
        1.02, 1.14, 1.30, 1.00, 1.42, 1.36, 0.78, 1.00, 1.24, 1.06,
        1.34, 1.18, 0.86, 1.08, 1.00, 0.82, 1.00, 1.26, 1.20, 1.30,
        0.80, 1.44, 1.12, 0.92, 1.22, 0.84, 1.38, 1.00, 1.28, 0.88,
    ]

    struct Cell: Hashable {
        let index: Int
        let ratio: CGFloat
    }

    static func columns(_ width: CGFloat) -> Int { width < 560 ? 2 : width < 900 ? 3 : width < 1280 ? 4 : 5 }
    static func gap(_ width: CGFloat) -> CGFloat { width < 560 ? 7 : 11 }
    static func pad(_ width: CGFloat) -> CGFloat { width < 560 ? 7 : 16 }

    /// 每一格放进当前最矮的那一列（等宽，所以列高正比于比例之和）
    static func layout(count: Int, columns: Int) -> [[Cell]] {
        var cols = Array(repeating: [Cell](), count: columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        for i in 0..<count {
            let r = ratios[i % ratios.count]
            var c = 0
            for j in 1..<max(columns, 1) where heights[j] < heights[c] - 0.000001 { c = j }
            cols[c].append(Cell(index: i, ratio: r))
            heights[c] += r
        }
        return cols
    }

    var body: some View {
        let n = Self.columns(width)
        let gap = Self.gap(width)
        let pad = Self.pad(width)
        let colW = max(60, (width - pad * 2 - gap * CGFloat(n - 1)) / CGFloat(n))
        let cols = Self.layout(count: items.count, columns: n)
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<n, id: \.self) { c in
                LazyVStack(spacing: gap) {
                    ForEach(cols[c], id: \.self) { cell in
                        let v = items[cell.index]
                        ZoomLink(route: .movie(v), slot: "folder-mas") {
                            FolderMasonryCard(video: v, ratio: cell.ratio, width: colW)
                        }
                        .accessibilityIdentifier("folder-movie")
                        .movieMenu(v)
                    }
                }
                .frame(width: colW)
            }
        }
        .padding(.horizontal, pad)
        .padding(.bottom, 34)
    }
}

/// 网页版 .mas-card：底图铺满整格（矮格用剧照、高格用海报），暗场压在下半截，左下角片名与规格
struct FolderMasonryCard: View {
    @Environment(AppModel.self) private var model
    let video: Video
    let ratio: CGFloat
    let width: CGFloat

    var body: some View {
        let m = model.meta(video)
        let wide = ratio < 1.05
        let art = wide ? (m?.backdrop ?? m?.posterClean ?? m?.poster) : (m?.poster ?? m?.posterClean ?? m?.backdrop)
        ZStack(alignment: .bottomLeading) {
            Color(red: 14 / 255, green: 14 / 255, blue: 16 / 255)
            RemoteImage(url: TMDBImage.url(art, wide ? "w780" : "w342"), maxPixel: width * 3, placeholder: .clear)
            LinearGradient(stops: [
                .init(color: Color(red: 6 / 255, green: 6 / 255, blue: 9 / 255).opacity(0.06), location: 0),
                .init(color: .clear, location: 0.34),
                .init(color: Color(red: 6 / 255, green: 6 / 255, blue: 9 / 255).opacity(0.62), location: 0.76),
                .init(color: Color(red: 4 / 255, green: 4 / 255, blue: 6 / 255).opacity(0.9), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title(video))
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.16)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                let spec = Self.spec(video.name)
                if !spec.isEmpty {
                    Text(spec)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: width, height: width * ratio)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }

    /// 「2024 · 4K · 杜比视界」：年份、分辨率、HDR，都从文件名读（规则同网页版 parse / topTag）
    static func spec(_ name: String) -> String {
        func has(_ p: String) -> Bool { name.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        var parts: [String] = []
        if let y = FileName.year(name) { parts.append(String(y)) }
        if has("2160P|[. _-]4K[. _-]|UHD") { parts.append("4K") } else if has("1080P") { parts.append("HD") }
        if has("DOLBY[. _-]?VISION|[. _-]DV[. _-]|[. _-]DoVi") { parts.append("杜比视界") }
        else if has("HDR10\\+?|[. _-]HDR[. _-]") { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }
}
