import SwiftUI

// MARK: - 文件夹（首页最后那排「文件夹」点进来）
//
// 系统大标题（文件夹名：C13），有子文件夹先是一排文件夹卡，下面是和搜索页同一个海报网格（T23、C20）：
// 新的年份在前，同一年按片名。不再按年份分组、不用高低错落的瀑布流（T23：只用标准的排与网格），
// 也不再在画面上压片名与规格（F1：画面归画面，字在卡下）。

/// 文件夹卡：系统的 folder.fill 图标 + 文件夹名。不垫底板、不描边（F3），不用玻璃（F38），不用强调色（F32）。
/// 宽度跟着所在那一排（文件夹页里是 DSMetrics 的海报宽），图标按宽度等比放大（S1：展开是同一张卡长大）
struct FolderCard: View {
    let folder: LibraryFolder
    var width: CGFloat = 191

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: max(28, (width * 0.4).rounded())))
                .foregroundStyle(.secondary)
                .frame(width: width, height: max(44, (width * 0.62).rounded()))
            Text(folder.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("文件夹 " + folder.name)
    }
}

/// 文件夹页
struct FolderView: View {
    @Environment(AppModel.self) private var model
    let folder: LibraryFolder
    @State private var subfolders: [LibraryFolder] = []
    @State private var videos: [Video] = []
    @State private var loading = true
    @State private var failed: String?

    var body: some View {
        GeometryReader { geo in
            let metrics = DSMetrics(width: geo.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: max(16, metrics.shelfGap - 14)) {
                    if loading && subfolders.isEmpty && videos.isEmpty {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else if let failed, subfolders.isEmpty, videos.isEmpty {
                        // F87：不怪人，说怎么办（再试一次）
                        ContentUnavailableView {
                            Label("没能打开这个文件夹", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(failed)
                        } actions: {
                            Button("重试") { Task { await load() } }
                        }
                        .padding(.top, 40)
                    } else {
                        content(metrics)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.bg)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.large)
        .task(id: folder.path) { await load() }
    }

    @ViewBuilder private func content(_ metrics: DSMetrics) -> some View {
        // 没有封面的不显示（与资料库同一条规矩）
        let shown = ordered(videos.filter { !model.hidden.contains($0.name) })
        if !subfolders.isEmpty {
            // 子文件夹：一排（DSShelf：卡停在左边线上，右边露出下一张一截：S8）
            DSShelf(metrics: metrics) {
                ForEach(subfolders) { f in
                    ZoomLink(route: .folder(f), slot: "folder") {
                        FolderCard(folder: f, width: metrics.posterWidth)
                    }
                    .accessibilityIdentifier("folder-card")
                }
            }
        }
        if !shown.isEmpty {
            LibraryGrid(videos: shown, metrics: metrics, slot: "folder-grid", identifier: "folder-movie")
                .padding(.top, subfolders.isEmpty ? 6 : 0)
        }
        if subfolders.isEmpty && shown.isEmpty && !loading {
            ContentUnavailableView("空文件夹", systemImage: "folder",
                                   description: Text("这个文件夹里还没有能播放的影片。"))
                .padding(.top, 40)
        }
    }

    /// 新的年份在前（没有年份的排最后），同一年按片名
    private func ordered(_ list: [Video]) -> [Video] {
        list.sorted { a, b in
            let ya = model.year(a) ?? 0, yb = model.year(b) ?? 0
            if ya != yb { return ya > yb }
            return model.title(a).localizedCompare(model.title(b)) == .orderedAscending
        }
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
