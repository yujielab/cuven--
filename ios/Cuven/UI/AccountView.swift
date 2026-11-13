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

struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var haptics = Haptics.enabled
    @AppStorage(PlayerCoordinator.autoplayKey) private var autoplayNext = true
    @State private var cacheSize: Int64 = DiskCache.size()
    @State private var refreshing = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AvatarView(size: 62)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.displayName.isEmpty ? "Cuven 账户" : account.displayName)
                                .font(.system(size: 21, weight: .bold))
                            if let e = account.session?.email, !e.isEmpty {
                                Text(e).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            }
                            Text("Cuven 账户 · 登录 Cuven max、Cuven TV 与 Cuven 的其他服务")
                                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                if account.loginRequired {
                    Section("登录与安全") {
                        if account.biometryAvailable {
                            Toggle("使用\(account.biometryName)快速登录", isOn: faceIDBinding)
                                .tint(Theme.accent)
                        }
                        if let s = account.session {
                            LabeledContent("登录方式", value: methodName(s.method))
                            LabeledContent("登录于", value: s.at.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("退出登录", role: .destructive) { confirmSignOut = true }
                            .accessibilityIdentifier("account-signout")
                    }
                }

                Section("播放") {
                    Toggle("自动播放下一集", isOn: $autoplayNext).tint(Theme.accent)
                    Toggle("触感反馈", isOn: $haptics)
                        .tint(Theme.accent)
                        .onChange(of: haptics) { _, v in Haptics.enabled = v }
                }

                Section("片库") {
                    LabeledContent("电影", value: "\(model.movies.count) 部")
                    LabeledContent("剧集", value: "\(model.series.count) 部")
                    LabeledContent("继续观看", value: "\(model.playback.continueWatching.count) 部")
                    Button {
                        refreshing = true
                        Task { await model.refreshAll(); refreshing = false; cacheSize = DiskCache.size() }
                    } label: {
                        HStack { Text("刷新片库"); Spacer(); if refreshing { ProgressView() } }
                    }
                    .disabled(refreshing)
                }

                Section("存储") {
                    LabeledContent("本地缓存", value: Format.size(cacheSize).isEmpty ? "0 MB" : Format.size(cacheSize))
                    Button("清除缓存（片库清单、海报、元数据）") {
                        model.clearCaches()
                        cacheSize = DiskCache.size()
                        Task { await model.refreshAll(); cacheSize = DiskCache.size() }
                    }
                    Button("清除继续观看", role: .destructive) { model.playback.clearAll() }
                }

                Section("关于") {
                    HStack(spacing: 12) {
                        Image("BrandIcon")
                            .resizable()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cuven max").font(.system(size: 15, weight: .semibold))
                            Text("版本 \(Bundle.main.appVersion)").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    LabeledContent("片源", value: "stream.cuven.online")
                    LabeledContent("账户服务", value: "check.cuven.us")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                        .accessibilityIdentifier("account-done")
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
