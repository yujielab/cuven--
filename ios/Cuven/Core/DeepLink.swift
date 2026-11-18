import Foundation

// MARK: - 分享出去的链接（用户要求「分享仅让对方打开相同的详情页就可以了」）
//
// cuven://movie/<TMDB 编号>?p=<路径编号>：对方装了 Cuven max（Info.plist 里登记了 cuven 这个前缀），
// 隔空投送过来一点就打开 App、切到主页、推进同一部的详情页（RootView 的 onOpenURL → AppModel.openLink → HomeView）。
// 先按 TMDB 编号在对方的片库里找（同一部片的不同文件也对得上），找不到再按路径编号（同一个片库）；
// 片库还没载入就先记着，载入了再找；都找不到就说一声「没有找到这部影片」。
// 链接里没有签名地址、片库路径（路径编号是路径的散列，倒推不出路径）

enum DeepLink {
    static let scheme = "cuven"

    struct Target: Equatable {
        var tmdbID: Int?
        var pathID: String?
    }

    static func movie(path: String, tmdbID: Int?) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "movie"
        c.path = "/" + String(tmdbID ?? 0)
        c.queryItems = [URLQueryItem(name: "p", value: PrecacheFiles.id(for: path))]
        return c.url ?? URL(string: "cuven://movie/0")!
    }

    static func parse(_ url: URL) -> Target? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "movie" else { return nil }
        let id = Int(url.lastPathComponent).flatMap { $0 > 0 ? $0 : nil }
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value
        guard id != nil || !(p ?? "").isEmpty else { return nil }
        return Target(tmdbID: id, pathID: p)
    }
}
