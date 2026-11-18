import SwiftUI

// MARK: - 详情页的「下载」「分享」（用户给的图：iPhone Duo 侧边那一列，返回钮下面一枚竖着的玻璃胶囊，↓ 和分享）
//
// 放在导航栏右边的一组工具栏按钮里：侧边一列的形态下系统把它们排在返回钮下面、包进一枚玻璃胶囊；别的 iPhone 上在右上角。
// · 下载：↓ → 一圈进度 + 停止方块（下载中，点开是「暂停 / 取消」）→ 一圈进度 + ↓（暂停了、断了，点开是「继续 / 取消」）→ ✓（下好了，点开是「删除下载」）；
// · 分享：下好了就是系统的分享面板（隔空投送给附近的人、存到「文件」……），分享的是文件本身；还没下好先问要不要下载。

struct DetailDownloadButton: View {
    let video: Video
    let title: String
    let year: Int?
    @Binding var alert: PrecacheAlert?

    var body: some View {
        let it = Downloads.shared.item(path: video.path)
        switch it?.state {
        case nil:
            Button {
                Task { alert = await DetailDownloadStarter.start(video: video, title: title, year: year) }
            } label: {
                Image(systemName: "arrow.down")
            }
            .accessibilityLabel("下载")
            .accessibilityIdentifier("detail-download")
        case .done?:
            Menu {
                Button("删除下载", systemImage: "trash", role: .destructive) { Downloads.shared.delete(path: video.path) }
            } label: {
                Image(systemName: "checkmark")
            }
            .accessibilityLabel("已下载")
            .accessibilityIdentifier("detail-download")
        case .some(let state):
            let p = it?.progress ?? 0
            Menu {
                if state == .downloading {
                    Button("暂停下载", systemImage: "pause") { Downloads.shared.pause(path: video.path) }
                } else {
                    Button("继续下载", systemImage: "arrow.down") { Task { await Downloads.shared.resume(path: video.path) } }
                }
                Button("取消下载", systemImage: "xmark", role: .destructive) { Downloads.shared.delete(path: video.path) }
            } label: {
                DownloadRing(progress: p, running: state == .downloading)
            }
            .accessibilityLabel(state == .downloading ? "正在下载" : (state == .failed ? "下载中断" : "下载已暂停"))
            .accessibilityValue("\(Int((p * 100).rounded()))%")
            .accessibilityIdentifier("detail-download")
        }
    }
}

struct DetailShareButton: View {
    let video: Video
    let title: String
    @Binding var askDownload: Bool

    var body: some View {
        if let it = Downloads.shared.item(path: video.path), it.state == .done {
            ShareLink(item: Downloads.shared.fileURL(it), preview: SharePreview(title)) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("分享")
            .accessibilityIdentifier("detail-share")
        } else {
            Button { askDownload = true } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("分享")
            .accessibilityHint("下载完成后可以通过隔空投送分享")
            .accessibilityIdentifier("detail-share")
        }
    }
}

/// 开始下载（「下载」钮、分享时问的「下载」都走这里）：开不了就回一个提示
enum DetailDownloadStarter {
    @MainActor
    static func start(video: Video, title: String, year: Int?) async -> PrecacheAlert? {
        switch await Downloads.shared.start(path: video.path, name: video.name, title: title, year: year, size: video.size) {
        case .started:
            Haptics.light()
            return nil
        case .noSpace(let needed):
            Haptics.error()
            let gb = max(1, Int((Double(needed) / 1_000_000_000).rounded(.up)))
            return PrecacheAlert(title: "iPhone 储存空间不足",
                                 message: "下载这部影片需要至少 \(gb) GB 可用空间。请在「设置」>「通用」>「iPhone 储存空间」中清理后再试。")
        case .unavailable:
            return PrecacheAlert(title: "无法下载", message: "演示模式下无法下载影片。")
        case .failed:
            Haptics.error()
            return PrecacheAlert(title: "无法下载", message: "暂时连不上服务器，请稍后再试。")
        }
    }
}

/// 下载中的那一圈：灰圈 + 白色进度，中间停止方块（下载中）或 ↓（暂停了）
struct DownloadRing: View {
    let progress: Double
    let running: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if running {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.primary)
                    .frame(width: 6, height: 6)
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .frame(width: 20, height: 20)
        .animation(.easeInOut(duration: 0.4), value: progress)
    }
}

// MARK: - 下载角标（用户给的两张图：下载中一圈进度、下好了一颗灰底黑箭头的圆）
//
// 主页的海报封面右上角、详情页那一行信息的右端：这一部在下载时是一圈进度（暗圈 + 白色的一段，刚开始是一个白点），
// 下好了是一颗浅灰的圆、里面一个黑色的 ↓；暂停了 / 断了是那一圈淡一点。没有下载就什么都不画

struct DownloadBadge: View {
    let path: String
    var size: CGFloat = 22

    var body: some View {
        if let it = Downloads.shared.item(path: path) {
            Group {
                if it.state == .done {
                    Image(systemName: "arrow.down")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: size, height: size)
                        .background(Circle().fill(Color(white: 0.72)))
                } else {
                    let p = max(0.001, min(1, it.progress))
                    ZStack {
                        Circle().fill(Color.black.opacity(0.45))
                        Circle().stroke(Color.white.opacity(0.22), lineWidth: size * 0.14)
                        // 刚开始那一点也看得见：圆头的线，进度为 0 时就是一个白点
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .padding(size * 0.07)
                    .frame(width: size, height: size)
                    .opacity(it.state == .downloading ? 1 : 0.6)
                    .animation(.easeInOut(duration: 0.4), value: p)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// 卡的右上角压一颗下载角标（这一部没在下载、没下好就什么都没有）
    func downloadBadge(_ path: String?, inset: CGFloat = 8, size: CGFloat = 22) -> some View {
        overlay(alignment: .topTrailing) {
            if let path {
                DownloadBadge(path: path, size: size)
                    .padding(inset)
                    .allowsHitTesting(false)
            }
        }
    }
}
