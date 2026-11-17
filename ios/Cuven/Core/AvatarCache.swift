import SwiftUI
import UIKit

// MARK: - 头像存在本机（用户要求「预先在设备上缓存头像，仅在确认没有头像时才回退成默认头像兜底，不要使用首字母」）
//
// · 本机一份：Application Support/cuven/avatar 是服务器给的原始字节（不进 iCloud 备份），UserDefaults 里记是谁的。
//   启动时同步读出来、解码好：主页右上、账户页、欢迎页第一帧就是它。「清除缓存」不清它；退出登录才清，换账户不串。
// · 登录、启动、回到前台、打开账户页都在后台按账户设置再拉一次（同一张 10 分钟内拉过就不拉）：字节变了才换（淡入），没变不动。
// · 「没有头像」要服务器确认才算：设置里写的是默认头像（几号就是几号；从没设置过是 4 号），
//   或者设置里是自己的照片、照片却 404 / 410——这时才用默认头像（4 号）兜底。
//   断网、超时、服务器出错、图解不开都不算确认：留着本机那一份；本机也没有，就只是一个空的圆（不写首字母）。
// · 换头像：上传的照片就是那一份字节，直接存进来；选了默认头像就把那一张拉下来存进来。
// · 演示数据：本地画的默认头像，不连网、不落盘。

@MainActor
@Observable
final class AvatarCache {
    static let shared = AvatarCache()

    /// 现在的头像（解码好的，最长边 600 像素，够账户页 180 点的大头像用）；nil = 还不知道
    private(set) var image: UIImage?
    /// 这张是谁的（不是现在登录的这位就不给）
    private(set) var owner: String?
    /// 换了一张就加一（账户页按它重新取头部的颜色）
    private(set) var version = 0

    /// 本机那一份的字节（拉回来一样就不换、不写盘）
    @ObservationIgnored private var bytes: Data?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    /// 上次拉成功（或确认没有）的是哪个地址、什么时候
    @ObservationIgnored private var fetchedKey: String?
    @ObservationIgnored private var fetchedAt: Date?

    private static let ownerKey = "cuven_avatar_owner_v1"
    private static let maxPixel: CGFloat = 600
    /// 同一张 10 分钟内拉过就不再拉
    private static let freshFor: TimeInterval = 600

    /// 不走 URLCache：每次都要服务器的真话（404 才算确认没有）
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cuven", isDirectory: true)
            .appendingPathComponent("avatar", isDirectory: false)
    }

    /// 启动时：本机有就同步读出来（一张小图，几毫秒），第一帧就有头像
    init() {
        guard !DemoData.enabled, let who = UserDefaults.standard.string(forKey: Self.ownerKey),
              let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let img = ImagePipeline.decode(data, maxPixel: Self.maxPixel) else { return }
        owner = who
        bytes = data
        image = img
    }

    /// 这位的头像（本机那份不是这位的、或者还不知道：nil）
    func avatar(for user: String?) -> UIImage? {
        guard let user, !user.isEmpty, owner == user else { return nil }
        return image
    }

    /// 现在登录的是这位：本机那份不是这位的，先不给（等拉到这位的）
    func bind(_ user: String) {
        guard owner != user else { return }
        inflight?.cancel()
        inflight = nil
        owner = user
        bytes = nil
        image = nil
        fetchedKey = nil
        fetchedAt = nil
        version += 1
    }

    /// 按账户设置拉一次头像。url：设置里现在的那张；fallback：确认没有时用的默认头像。force：不管 10 分钟
    func refresh(_ url: URL?, for user: String, fallback: URL?, force: Bool = false) async {
        guard let url, !user.isEmpty else { return }
        bind(user)
        let key = url.absoluteString
        if let running = inflight { await running.value }
        guard owner == user else { return }
        if !force, image != nil, fetchedKey == key, let at = fetchedAt, Date().timeIntervalSince(at) < Self.freshFor { return }
        let task = Task { await self.run(url, key: key, user: user, fallback: fallback) }
        inflight = task
        await task.value
        if inflight == task { inflight = nil }
    }

    private func run(_ url: URL, key: String, user: String, fallback: URL?) async {
        let result = await Self.fetch(url)
        guard !Task.isCancelled, owner == user else { return }
        switch result {
        case .image(let data, let img):
            fetchedKey = key
            fetchedAt = Date()
            set(data, img)
        case .missing:
            // 服务器确认这张没有：默认头像兜底（默认头像本身也没有，就留着现在的）
            fetchedKey = key
            fetchedAt = Date()
            if let fallback, fallback != url, case .image(let data, let img) = await Self.fetch(fallback),
               !Task.isCancelled, owner == user {
                set(data, img)
            }
        case .failed:
            break   // 没确认：本机那份照旧
        }
    }

    /// 刚上传的照片：就是这一份字节，直接存（不再下载一遍）
    func store(_ data: Data, for user: String) {
        bind(user)
        guard let img = ImagePipeline.decode(data, maxPixel: Self.maxPixel) else { return }
        fetchedKey = nil
        fetchedAt = Date()
        set(data, img)
    }

    /// 改了姓名：本机这份跟着换主人（服务器上的头像也跟过去了）
    func rename(from old: String, to new: String) {
        guard owner == old, !new.isEmpty else { return }
        owner = new
        fetchedKey = nil
        if bytes != nil { UserDefaults.standard.set(new, forKey: Self.ownerKey) }
    }

    /// 退出登录：本机这份删掉
    func clear() {
        inflight?.cancel()
        inflight = nil
        owner = nil
        bytes = nil
        image = nil
        fetchedKey = nil
        fetchedAt = nil
        version += 1
        UserDefaults.standard.removeObject(forKey: Self.ownerKey)
        if let url = Self.fileURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: 内部

    /// 换上新的一张；字节和本机那份一样就不动（演示数据的图没有字节，不落盘）
    private func set(_ data: Data, _ img: UIImage) {
        if !data.isEmpty, data == bytes, image != nil { return }
        bytes = data.isEmpty ? nil : data
        withAnimation(.easeOut(duration: 0.3)) { image = img }
        version += 1
        guard !data.isEmpty, !DemoData.enabled, let who = owner, let url = Self.fileURL else { return }
        UserDefaults.standard.set(who, forKey: Self.ownerKey)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            var target = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? target.setResourceValues(values)
        }
    }

    private enum Fetched {
        /// 拿到了（演示数据：字节是空的）
        case image(Data, UIImage)
        /// 服务器说没有（404 / 410）
        case missing
        /// 没拿到：断网、超时、服务器出错、解不开
        case failed
    }

    private static func fetch(_ url: URL) async -> Fetched {
        let px = maxPixel
        if url.scheme == "demo" {
            guard let img = DemoData.render(url, maxPixel: px) else { return .failed }
            return .image(Data(), img)
        }
        guard let (data, resp) = try? await session.data(from: url), let http = resp as? HTTPURLResponse else { return .failed }
        if http.statusCode == 404 || http.statusCode == 410 { return .missing }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else { return .failed }
        UsageMeter.shared.add(data.count, to: .data)
        guard let img = await Task.detached(priority: .userInitiated, operation: { ImagePipeline.decode(data, maxPixel: px) }).value
        else { return .failed }
        return .image(data, img)
    }
}
