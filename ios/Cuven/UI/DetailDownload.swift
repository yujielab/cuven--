import SwiftUI

// MARK: - 详情页的「下载」「分享」（用户给的图：iPhone Duo 侧边那一列，返回钮下面一枚竖着的玻璃胶囊，↓ 和分享）
//
// 放在导航栏右边的一组工具栏按钮里：侧边一列的形态下系统把它们排在返回钮下面、包进一枚玻璃胶囊；别的 iPhone 上在右上角。
// · 下载（用户要求「下载指的是预先缓存 100%」：Precache.download）：整部缓存到本机，在 App 里放（离线也行）。
//   ↓ → 一圈进度 + 停止方块（下载中，点开是「暂停 / 取消」）→ 一圈进度 + ↓（暂停了、断了，点开是「继续 / 取消」）→ ✓（点开是「删除下载」）；
// · 分享（用户要求「分享仅让对方打开相同的详情页就可以了」）：系统的分享面板，发出去的是一条 cuven://movie/<TMDB 编号> 的链接，
//   对方装了 Cuven max 一点就打开同一部的详情页（DeepLink）；可以直接隔空投送。不分享文件、签名地址或片库路径。

struct DetailDownloadButton: View {
    let video: Video
    let title: String
    let runtime: Int?
    @Binding var alert: PrecacheAlert?
    /// 点得到的范围多大（弧形菜单里给 46 点；工具栏里不用给，系统自己管）
    var hit: CGFloat? = nil

    var body: some View {
        let it = Precache.shared.item(path: video.path)
        // 只在预先缓存（不是整部）的，也当还没下载：按了升级成整部
        if let it, it.isFull {
            switch it.phase {
            case .done:
                Menu {
                    Button("删除下载", systemImage: "trash", role: .destructive) { Precache.shared.delete(path: video.path) }
                } label: {
                    Image(systemName: "checkmark").detailHit(hit)
                }
                .accessibilityLabel("已下载")
                .accessibilityIdentifier("detail-download")
            case .downloading, .queued, .preparing:
                Menu {
                    Button("暂停下载", systemImage: "pause") { Precache.shared.pause(path: video.path) }
                    Button("取消下载", systemImage: "xmark", role: .destructive) { Precache.shared.delete(path: video.path) }
                } label: {
                    DownloadRing(progress: it.progress, running: true).detailHit(hit)
                }
                .accessibilityLabel("正在下载")
                .accessibilityValue("\(Int((it.progress * 100).rounded()))%")
                .accessibilityIdentifier("detail-download")
            case .paused, .failed, .noSpace:
                Menu {
                    Button("继续下载", systemImage: "arrow.down") { Precache.shared.resume(path: video.path) }
                    Button("取消下载", systemImage: "xmark", role: .destructive) { Precache.shared.delete(path: video.path) }
                } label: {
                    DownloadRing(progress: it.progress, running: false).detailHit(hit)
                }
                .accessibilityLabel(it.phase == .noSpace ? "储存空间不足" : "下载已暂停")
                .accessibilityValue("\(Int((it.progress * 100).rounded()))%")
                .accessibilityIdentifier("detail-download")
            }
        } else {
            Button {
                alert = DetailDownloadStarter.start(video: video, title: title, runtime: runtime)
            } label: {
                Image(systemName: "arrow.down").detailHit(hit)
            }
            .accessibilityLabel("下载")
            .accessibilityHint("把整部影片缓存到这台 iPhone")
            .accessibilityIdentifier("detail-download")
        }
    }
}

/// 分享：一条打开同一部详情页的链接（隔空投送给附近装了 Cuven max 的人，对方点开就是这一页）
struct DetailShareButton: View {
    let video: Video
    let title: String
    let tmdbID: Int?
    var hit: CGFloat? = nil

    var body: some View {
        ShareLink(item: DeepLink.movie(path: video.path, tmdbID: tmdbID),
                  subject: Text(title),
                  message: Text("在 Cuven max 中查看《\(title)》"),
                  preview: SharePreview(title)) {
            Image(systemName: "square.and.arrow.up").detailHit(hit)
        }
        .accessibilityLabel("分享")
        .accessibilityHint("发给别人，对方可以打开这部影片的详情页")
        .accessibilityIdentifier("detail-share")
    }
}

extension View {
    /// 给了多大就把点得到的范围撑到多大（不给就原样）
    @ViewBuilder
    func detailHit(_ size: CGFloat?) -> some View {
        if let size {
            frame(width: size, height: size).contentShape(Rectangle())
        } else {
            self
        }
    }
}

/// 开始下载：开不了就回一个提示
enum DetailDownloadStarter {
    @MainActor
    static func start(video: Video, title: String, runtime: Int?) -> PrecacheAlert? {
        switch Precache.shared.download(path: video.path, name: video.name, title: title, size: video.size, runtime: runtime) {
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
        }
    }
}

/// 下载钮上的那一圈：灰圈 + 白色进度，中间停止方块（下载中）或 ↓（暂停了）
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
// 主页的海报封面右上角、详情页那一行信息的右端：这一部在下载（整部）时是一圈进度（暗圈 + 白色的一段，刚开始是一个白点），
// 下好了是一颗浅灰的圆、里面一个黑色的 ↓；暂停了 / 断了是那一圈淡一点。没有下载（或者只是弱网时的预先缓存）就什么都不画

struct DownloadBadge: View {
    let path: String
    var size: CGFloat = 22

    var body: some View {
        if let it = Precache.shared.item(path: path), it.isFull {
            Group {
                if it.phase == .done {
                    Image(systemName: "arrow.down")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: size, height: size)
                        .background(Circle().fill(Color(white: 0.72)))
                } else {
                    let p = max(0.001, min(1, it.progress))
                    let running = it.phase == .downloading || it.phase == .queued || it.phase == .preparing
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
                    .opacity(running ? 1 : 0.6)
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
