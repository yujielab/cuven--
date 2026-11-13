import SwiftUI

// MARK: - 账户与设置（主页 / 资料库右上角的头像打开；取代原来的「我的」标签）

/// 「打开账户页」：根视图注入，头像按钮调用
private struct OpenAccountKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var openAccount: () -> Void {
        get { self[OpenAccountKey.self] }
        set { self[OpenAccountKey.self] = newValue }
    }
}

/// 圆形头像：账户设置里的头像（默认头像或自己上传的），取不到就是首字母
struct AvatarView: View {
    @Environment(AccountStore.self) private var account
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Theme.accent, Color(red: 0.36, green: 0.27, blue: 1.0)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initial)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if let u = account.avatarURL {
                RemoteImage(url: u, maxPixel: size * 3, placeholder: .clear)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        .task(id: account.session?.username) { await account.refreshAvatar() }
    }

    private var initial: String {
        let n = account.displayName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "C" : String(n.prefix(1)).uppercased()
    }
}

/// 头像按钮（自定义视图的工具栏项：在 iPhone Duo 上也留在横向的顶栏里，不进侧边那一列）
struct AvatarButton: View {
    @Environment(\.openAccount) private var openAccount

    var body: some View {
        Button(action: openAccount) { AvatarView(size: 34) }
            .buttonStyle(.plain)
            .accessibilityLabel("账户")
            .accessibilityIdentifier("account-button")
    }
}

/// 账户与设置（版式参考 Games App 的个人页）：顶上一片渐变（颜色取自头像），大头像、用户名、邮箱；
/// 下面一组组圆角卡片：观看、登录与安全、播放、片库、存储、关于。观看那组点进去是整页清单（在这一页里推进去）
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var haptics = Haptics.enabled
    @AppStorage(PlayerCoordinator.autoplayKey) private var autoplayNext = true
    @State private var cacheSize: Int64 = DiskCache.size()
    @State private var refreshing = false
    @State private var confirmSignOut = false
    @State private var tint = Color(red: 0.22, green: 0.24, blue: 0.62)
    /// 当标签页用（网页版导航胶囊里的头像）：没有「完成」
    var asTab = false

    var body: some View {
        ZoomStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    profile
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)

                    AccountGroup("观看") {
                        AccountRow(symbol: "play.circle.fill", title: "继续观看",
                                   detail: "\(model.playback.continueWatching.count) 部", route: .shelf(.continueWatching))
                        AccountRow(symbol: "bookmark.circle.fill", title: "想看",
                                   detail: "\(model.watchlist.items.count) 部", route: .shelf(.watchlist))
                    }

                    if account.loginRequired {
                        AccountGroup("登录与安全") {
                            if account.biometryAvailable {
                                AccountToggleRow(symbol: "faceid", title: "使用\(account.biometryName)快速登录", isOn: faceIDBinding)
                            }
                            if let s = account.session {
                                AccountRow(symbol: "key.fill", title: "登录方式", detail: methodName(s.method))
                                AccountRow(symbol: "clock.fill", title: "登录于", detail: s.at.formatted(date: .abbreviated, time: .shortened))
                            }
                            AccountButtonRow(symbol: "rectangle.portrait.and.arrow.right", title: "退出登录", destructive: true) {
                                confirmSignOut = true
                            }
                            .accessibilityIdentifier("account-signout")
                        }
                    }

                    AccountGroup("播放") {
                        AccountToggleRow(symbol: "forward.end.circle.fill", title: "自动播放下一集", isOn: $autoplayNext)
                        AccountToggleRow(symbol: "hand.tap.fill", title: "触感反馈", isOn: $haptics)
                            .onChange(of: haptics) { _, v in Haptics.enabled = v }
                    }

                    AccountGroup("片库") {
                        AccountRow(symbol: "film.fill", title: "电影", detail: "\(model.movies.count) 部")
                        AccountRow(symbol: "tv.fill", title: "剧集", detail: "\(model.series.count) 部")
                        AccountButtonRow(symbol: "arrow.clockwise", title: refreshing ? "正在刷新…" : "刷新片库", busy: refreshing) {
                            refreshing = true
                            Task { await model.refreshAll(); refreshing = false; cacheSize = DiskCache.size() }
                        }
                    }

                    AccountGroup("存储") {
                        AccountRow(symbol: "internaldrive.fill", title: "本地缓存",
                                   detail: Format.size(cacheSize).isEmpty ? "0 MB" : Format.size(cacheSize))
                        AccountButtonRow(symbol: "trash.fill", title: "清除缓存（片库清单、海报、元数据）") {
                            model.clearCaches()
                            cacheSize = DiskCache.size()
                            Task { await model.refreshAll(); cacheSize = DiskCache.size() }
                        }
                        AccountButtonRow(symbol: "xmark.circle.fill", title: "清除继续观看", destructive: true) {
                            model.playback.clearAll()
                        }
                    }

                    AccountGroup("关于") {
                        HStack(spacing: 14) {
                            Image("BrandIcon")
                                .resizable()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cuven max").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                                Text("版本 \(Bundle.main.appVersion)").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        AccountRow(symbol: "server.rack", title: "片源", detail: "stream.cuven.online")
                        AccountRow(symbol: "person.badge.key.fill", title: "账户服务", detail: "check.cuven.us")
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(alignment: .top) {
                // 顶上一片渐变，颜色取自头像（没有头像就是 Cuven 的蓝紫）
                LinearGradient(colors: [tint, tint.opacity(0.55), Theme.bg], startPoint: .top, endPoint: .bottom)
                    .frame(height: 520)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .ignoresSafeArea()
            }
            .background(Theme.bg)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !asTab {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成", systemImage: "checkmark") { dismiss() }
                            .accessibilityIdentifier("account-done")
                    }
                }
            }
            .confirmationDialog("退出登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    dismiss()
                    account.signOut()
                }
            } message: {
                Text("退出后需要重新登录才能观看。观看进度保留在这台设备上。")
            }
            .task(id: account.avatarURL) {
                guard let u = account.avatarURL, let c = await ArtTint.color(for: u, ceiling: 0.6) else { return }
                withAnimation(.easeOut(duration: 0.4)) { tint = c }
            }
        }
    }

    /// 大头像、用户名、邮箱，下面一颗小胶囊说明这是 Cuven 账户
    private var profile: some View {
        VStack(spacing: 10) {
            AvatarView(size: 96)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            Text(account.displayName.isEmpty ? "Cuven 账户" : account.displayName)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
            if let e = account.session?.email, !e.isEmpty {
                Text(e).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75))
            }
            Text("Cuven 账户 · 网页版与 Cuven TV 通用")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.white.opacity(0.16), in: Capsule())
                .padding(.top, 2)
        }
    }

    private var faceIDBinding: Binding<Bool> {
        Binding(
            get: { account.faceIDUser != nil && account.faceIDUser == account.session?.username },
            set: { on in
                if on { Task { _ = await account.enableFaceID() } } else { account.disableFaceID() }
            })
    }

    private func methodName(_ m: String) -> String {
        switch m {
        case "password": return "密码"
        case "email_otp": return "电子邮件验证码"
        case "faceid": return account.biometryName
        case "register": return "新建账户"
        case "demo": return "演示"
        default: return m
        }
    }
}


// MARK: - 账户页的分组卡片（Games 个人页那种：组标题在上，下面一块圆角卡片，行与行之间一道发丝线）

struct AccountGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
            VStack(spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        row
                        if i < rows.count - 1 {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 60)
                        }
                    }
                }
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
    }
}

/// 一行：左边符号，标题，右边值；给了 route 就是可点进去的一行（带「›」）
struct AccountRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var route: Route? = nil

    var body: some View {
        if let route {
            NavigationLink(value: route) { content(chevron: true) }
                .buttonStyle(PressableStyle(scale: 0.98))
        } else {
            content(chevron: false)
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack(spacing: 14) {
            AccountSymbol(name: symbol)
            Text(title).font(.system(size: 17)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.system(size: 15)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

struct AccountToggleRow: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            AccountSymbol(name: symbol)
            Toggle(title, isOn: $isOn)
                .font(.system(size: 17))
                .tint(Theme.accent)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
    }
}

struct AccountButtonRow: View {
    let symbol: String
    let title: String
    var destructive = false
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AccountSymbol(name: symbol, destructive: destructive)
                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(destructive ? Color.red : Theme.accent)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if busy { ProgressView() }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .disabled(busy)
    }
}

/// 行首的符号：一枚小圆角方块里放白色符号
struct AccountSymbol: View {
    let name: String
    var destructive = false

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background((destructive ? Color.red : Color.white).opacity(destructive ? 0.75 : 0.16),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
