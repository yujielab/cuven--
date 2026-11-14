import SwiftUI
import UIKit
import UserNotifications

// MARK: - 账户与设置（「账户」标签）

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

/// 账户与设置：系统的 Form、分组样式——在 iPhone 上就是 inset grouped，行高、留白、分隔线都用系统的（C30、F14）。
/// 顶上头像、名字、邮箱；下面依次是观看、通知、播放、片库、存储、登录与安全、关于，最底下单独一组「退出登录」。
/// 不放和系统重复的开关：「触感」归系统的「声音与触感」管（C95），Haptics.enabled 保持默认的开。
/// 标签用平实的短词，开着会怎样写在组的脚注里（F84、F89）。
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PlayerCoordinator.autoplayKey) private var autoplayNext = true
    /// 「新片上架通知」：自己选的开 / 关。系统那边的通知权限另看（notifyBlocked）
    @AppStorage(AccountView.notifyKey) private var notifyWanted = false
    /// 系统设置里 Cuven 的通知是关着的（拒绝过，或者后来到设置里关了）
    @State private var notifyBlocked = false
    @State private var notifyAsking = false
    @State private var cacheSize: Int64 = DiskCache.size()
    @State private var refreshing = false
    @State private var confirmSignOut = false
    /// 当标签页用（「账户」标签）：没有关闭钮
    var asTab = false

    static let notifyKey = "cuven_notify_new_titles"

    var body: some View {
        ZoomStack {
            Form {
                profileSection
                watchingSection
                notifySection
                playbackSection
                librarySection
                storageSection
                securitySection
                aboutSection
                signOutSection
            }
            .formStyle(.grouped)
            .tint(Theme.accent)
            // 顶层页用大标题，滚动时收成小标题（C13）；弹出来用时是小标题
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(asTab ? .large : .inline)
            .toolbar {
                if !asTab {
                    // 弹出来用时：标准的关闭（xmark），不写「完成」——这一页没有要保存的编辑（C14、C53）
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭", systemImage: "xmark") { dismiss() }
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
            .task {
                seedNotifyPreference()
                await refreshNotify()
            }
            .onChange(of: scenePhase) { _, phase in
                // 从系统设置回来：通知权限可能变了
                if phase == .active { Task { @MainActor in await refreshNotify() } }
            }
        }
    }

    // MARK: 各组

    /// 顶上：头像、名字、邮箱，居中，不垫底色（像系统「Apple 账户」页的头部）
    private var profileSection: some View {
        Section {
            VStack(spacing: 4) {
                AvatarView(size: 80)
                    .accessibilityHidden(true)
                    .padding(.bottom, 8)
                Text(account.displayName.isEmpty ? "访客" : account.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if let e = account.session?.email, !e.isEmpty {
                    Text(e)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("未设置电子邮件")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .listRowBackground(Color.clear)
        }
    }

    /// 观看：点进去是整页清单（在这一页里推进去，行尾是系统的「›」：C31）
    private var watchingSection: some View {
        Section("观看") {
            NavigationLink(value: Route.shelf(.continueWatching)) {
                LabeledContent("继续观看", value: "\(model.playback.continueWatching.count) 部")
            }
            NavigationLink(value: Route.shelf(.watchlist)) {
                LabeledContent("想看", value: "\(model.watchlist.items.count) 部")
            }
        }
    }

    /// 新片上架通知：打开开关的那一刻才向系统要通知权限，不在启动时、也不在隐私闸门里问（C78、C79）。
    /// 系统里关着就给一行说明和「打开设置」，直接跳到系统里 Cuven 的通知设置，不描述路径（C97、F89）
    private var notifySection: some View {
        Section {
            Toggle("新片上架通知", isOn: notifyBinding)
                .tint(.green)
                .accessibilityIdentifier("account-notify")
            if notifyWanted && notifyBlocked {
                Button("打开设置") { openNotificationSettings() }
                    .accessibilityIdentifier("account-notify-settings")
            }
        } header: {
            Text("通知")
        } footer: {
            Text(notifyWanted && notifyBlocked ? "系统设置里关掉了 Cuven 的通知。" : "开着时，有新影片入库会提醒你。")
        }
    }

    private var playbackSection: some View {
        Section("播放") {
            Toggle("自动播放下一集", isOn: $autoplayNext)
                .tint(.green)
        }
    }

    /// 片库：数量 + 刷新（慢的操作：按钮里换成转圈和「正在刷新…」，不挡整屏：C39）
    private var librarySection: some View {
        Section("片库") {
            LabeledContent("电影", value: "\(model.movies.count) 部")
            LabeledContent("剧集", value: "\(model.series.count) 部")
            Button {
                refreshLibrary()
            } label: {
                HStack {
                    Text(refreshing ? "正在刷新…" : "刷新片库")
                    Spacer(minLength: 8)
                    if refreshing { ProgressView() }
                }
            }
            .disabled(refreshing)
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("缓存", value: cacheText)
            Button("清除缓存") { clearCache() }
            Button("清除继续观看", role: .destructive) { model.playback.clearAll() }
        } header: {
            Text("存储")
        } footer: {
            Text("清除缓存后，片库清单、海报和影片信息会重新下载。")
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        if account.loginRequired {
            Section("登录与安全") {
                if account.biometryAvailable {
                    Toggle("使用\(account.biometryName)登录", isOn: faceIDBinding)
                        .tint(.green)
                }
                if let s = account.session {
                    LabeledContent("登录方式", value: methodName(s.method))
                    LabeledContent("登录时间", value: s.at.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: Bundle.main.appVersion)
            LabeledContent("片源", value: "stream.cuven.online")
            LabeledContent("账户服务", value: "check.cuven.us")
        }
    }

    /// 退出登录单独放在最底下（红字、居中），点了先用系统的确认（C44、C47）
    @ViewBuilder
    private var signOutSection: some View {
        if account.loginRequired {
            Section {
                Button("退出登录", role: .destructive) { confirmSignOut = true }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("account-signout")
            }
        }
    }

    // MARK: 通知

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { notifyWanted },
            set: { on in
                notifyWanted = on
                if on { askNotify() }
            })
    }

    /// 打开开关时：系统还没问过就弹系统的询问；问过了就只看结果（拒绝过的只能到设置里开）
    private func askNotify() {
        guard !notifyAsking else { return }
        notifyAsking = true
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let before = await center.notificationSettings()
            if before.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            }
            let after = await center.notificationSettings()
            notifyBlocked = after.authorizationStatus == .denied
            notifyAsking = false
        }
    }

    /// 看一眼系统里的通知权限（打开这一页时、从系统设置回来时）
    private func refreshNotify() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        notifyBlocked = s.authorizationStatus == .denied
    }

    /// 以前在隐私闸门里开过通知的人：这里的开关一开始就是开着（只在还没有这项设置时看一次）
    private func seedNotifyPreference() {
        guard UserDefaults.standard.object(forKey: Self.notifyKey) == nil,
              let raw = UserDefaults.standard.string(forKey: PrivacyGate.key)?.data(using: .utf8),
              let r = try? JSONDecoder().decode(PrivacyGate.Record.self, from: raw) else { return }
        notifyWanted = r.scopes.notifications
    }

    /// 直接打开系统设置里 Cuven 的通知那一页（C97）
    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        openURL(url)
    }

    // MARK: 片库与存储

    private func refreshLibrary() {
        refreshing = true
        Task { @MainActor in
            await model.refreshAll()
            refreshing = false
            cacheSize = DiskCache.size()
        }
    }

    private func clearCache() {
        model.clearCaches()
        cacheSize = DiskCache.size()
        Task { @MainActor in
            await model.refreshAll()
            cacheSize = DiskCache.size()
        }
    }

    private var cacheText: String {
        let s = Format.size(cacheSize)
        return s.isEmpty ? "0 MB" : s
    }

    // MARK: 登录

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
