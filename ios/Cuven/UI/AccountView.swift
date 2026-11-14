import SwiftUI
import UIKit
import UserNotifications

// MARK: - 账户与设置（主页右上的头像点开）

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

/// 账户与设置（主页右上的头像点开，是一张弹层）。照用户给的参考图（Apple「游戏」App 的个人页）重做：
/// · 底：从头像取主色（取不到用紫色）往下渐暗到深灰，顶上那一截是这个颜色；
/// · 头部居中：88 点的圆头像（右下角一枚 Cuven 小图标）、大号粗体的名字、一颗「个人档案」胶囊钮（推进去看账户资料）；
/// · 下面每一组是一行粗体的组名 + 一张圆角 26 的半透明卡，卡里一行一项：左边一枚灰色符号，标题 + 一行灰色说明，右边「›」、开关或数值；
/// · 右上是系统的关闭钮（iOS 26 的玻璃圆钮），往上滚过头部，名字接到导航栏里。
/// 内容和以前一样：观看、通知、播放、片库、存储、登录与安全、关于，最底下单独一张「退出登录」（先用系统的确认：C44、C47）。
/// 「新片上架通知」打开的那一刻才向系统要权限（C78、C79）；系统里关着就多一行「打开设置」（C97）。
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
    /// 顶上那一截的颜色：头像的主色（取不到是紫色）
    @State private var tint = AccountPalette.fallback
    /// 头部滚出去了：名字接到导航栏里
    @State private var showName = false

    static let notifyKey = "cuven_notify_new_titles"

    private var displayName: String { account.displayName.isEmpty ? "访客" : account.displayName }

    var body: some View {
        ZoomStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 34) {
                        watchingGroup
                        notifyGroup
                        playbackGroup
                        libraryGroup
                        storageGroup
                        securityGroup
                        aboutGroup
                        signOutGroup
                    }
                    .padding(.top, 40)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 44)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background { AccountBackdrop(tint: tint).ignoresSafeArea() }
            .navigationTitle(showName ? displayName : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                // 系统的关闭（iOS 26 是右上一颗玻璃圆钮里的「×」：C14、C53）
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                        .accessibilityIdentifier("account-done")
                }
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > 200
            } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { showName = v }
            }
            .confirmationDialog("退出登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    dismiss()
                    // 登录层淡入（网页版鉴权层打开：0.28 秒 --silk-in）
                    withAnimation(.timingCurve(0.22, 0.68, 0.28, 1, duration: 0.28)) { account.signOut() }
                }
            } message: {
                Text("退出后需要重新登录才能观看。观看进度保留在这台设备上。")
            }
            .task {
                seedNotifyPreference()
                await refreshNotify()
            }
            .task(id: account.avatarURL) { await loadTint() }
            .onChange(of: scenePhase) { _, phase in
                // 从系统设置回来：通知权限可能变了
                if phase == .active { Task { @MainActor in await refreshNotify() } }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    // MARK: 头部

    /// 头像（右下角一枚 Cuven 小图标）、名字、「个人档案」胶囊钮
    private var header: some View {
        VStack(spacing: 0) {
            AvatarView(size: 88)
                .overlay(alignment: .bottomTrailing) {
                    Image("BrandIcon")
                        .resizable()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .offset(x: 6, y: 4)
                }
                .accessibilityHidden(true)
            Text(displayName)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            NavigationLink {
                AccountProfileView(tint: tint)
            } label: {
                Text("个人档案")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 34)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .accessibilityIdentifier("account-profile")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    // MARK: 各组

    /// 观看：点进去是整页清单（在这一页里推进去）
    private var watchingGroup: some View {
        AccountGroup(title: "观看") {
            NavigationLink(value: Route.shelf(.continueWatching)) {
                AccountRow(icon: "play.circle", title: "继续观看", subtitle: "共 \(model.playback.continueWatching.count) 部") { AccountChevron() }
            }
            .buttonStyle(AccountRowPress())
            AccountDivider()
            NavigationLink(value: Route.shelf(.watchlist)) {
                AccountRow(icon: "bookmark", title: "想看", subtitle: "共 \(model.watchlist.items.count) 部") { AccountChevron() }
            }
            .buttonStyle(AccountRowPress())
        }
    }

    /// 新片上架通知：打开开关的那一刻才向系统要通知权限，不在启动时、也不在隐私闸门里问（C78、C79）。
    /// 系统里关着就多一行「打开设置」，直接跳到系统里 Cuven 的通知设置，不描述路径（C97、F89）
    private var notifyGroup: some View {
        AccountGroup(title: "通知") {
            AccountRow(icon: "bell", title: "新片上架通知",
                       subtitle: notifyWanted && notifyBlocked ? "系统设置里关掉了 Cuven 的通知" : "有新影片入库时提醒你") {
                Toggle("新片上架通知", isOn: notifyBinding)
                    .labelsHidden()
                    .tint(.green)
                    .accessibilityIdentifier("account-notify")
            }
            if notifyWanted && notifyBlocked {
                AccountDivider()
                Button { openNotificationSettings() } label: {
                    AccountRow(icon: "gearshape", title: "打开设置") { AccountChevron() }
                }
                .buttonStyle(AccountRowPress())
                .accessibilityIdentifier("account-notify-settings")
            }
        }
    }

    private var playbackGroup: some View {
        AccountGroup(title: "播放") {
            AccountRow(icon: "forward.end", title: "自动播放下一集", subtitle: "一集看完，接着放下一集") {
                Toggle("自动播放下一集", isOn: $autoplayNext)
                    .labelsHidden()
                    .tint(.green)
            }
        }
    }

    /// 片库：数量 + 刷新（慢的操作：右边换成转圈、写「正在刷新…」，不挡整屏：C39）
    private var libraryGroup: some View {
        AccountGroup(title: "片库") {
            AccountRow(icon: "film.stack", title: "电影与剧集",
                       subtitle: "电影 \(model.movies.count) 部 · 剧集 \(model.series.count) 部") { EmptyView() }
            AccountDivider()
            Button { refreshLibrary() } label: {
                AccountRow(icon: "arrow.clockwise", title: refreshing ? "正在刷新…" : "刷新片库") {
                    if refreshing { ProgressView() }
                }
            }
            .buttonStyle(AccountRowPress())
            .disabled(refreshing)
        }
    }

    private var storageGroup: some View {
        AccountGroup(title: "存储", footer: "清除缓存后，片库清单、海报和影片信息会重新下载。") {
            Button { clearCache() } label: {
                AccountRow(icon: "internaldrive", title: "清除缓存", subtitle: "已用 \(cacheText)") { AccountChevron() }
            }
            .buttonStyle(AccountRowPress())
            AccountDivider()
            Button { model.playback.clearAll() } label: {
                AccountRow(icon: "clock.arrow.circlepath", title: "清除继续观看", titleColor: Color(red: 1, green: 0.42, blue: 0.38)) { EmptyView() }
            }
            .buttonStyle(AccountRowPress())
        }
    }

    @ViewBuilder
    private var securityGroup: some View {
        if account.loginRequired && account.biometryAvailable {
            AccountGroup(title: "登录与安全") {
                AccountRow(icon: biometrySymbol, title: "使用\(account.biometryName) 登录", subtitle: "下次轻点一下即可登录") {
                    Toggle("使用\(account.biometryName) 登录", isOn: faceIDBinding)
                        .labelsHidden()
                        .tint(.green)
                }
            }
        }
    }

    private var aboutGroup: some View {
        AccountGroup(title: "关于") {
            AccountRow(icon: "info.circle", title: "版本") { AccountValue(Bundle.main.appVersion) }
            AccountDivider()
            AccountRow(icon: "antenna.radiowaves.left.and.right", title: "片源") { AccountValue("stream.cuven.online") }
            AccountDivider()
            AccountRow(icon: "person.badge.key", title: "账户服务") { AccountValue("check.cuven.us") }
        }
    }

    /// 退出登录单独一张卡、红字居中，点了先用系统的确认（C44、C47）
    @ViewBuilder
    private var signOutGroup: some View {
        if account.loginRequired {
            AccountCard {
                Button { confirmSignOut = true } label: {
                    Text("退出登录")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.38))
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AccountRowPress())
                .accessibilityIdentifier("account-signout")
            }
        }
    }

    private var biometrySymbol: String {
        switch account.biometryName {
        case "触控 ID": return "touchid"
        case "光学 ID": return "opticid"
        default: return "faceid"
        }
    }

    /// 顶上那一截的颜色：取头像的平均色（只用色相，饱和度、亮度压到参考图那样）
    private func loadTint() async {
        guard let u = account.avatarURL,
              let img = await ImagePipeline.shared.image(u, maxPixel: 96), let cg = img.cgImage,
              let c = ImageEffects.averageColor(cg, bottom: 1) else { return }
        withAnimation(.easeInOut(duration: 0.6)) { tint = AccountPalette.tint(from: c) }
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

}

// MARK: - 个人档案（头部的胶囊钮推进去）

/// 账户资料：用户名、电子邮件、这次怎么登录的、什么时候登录的。同一套底和卡
struct AccountProfileView: View {
    @Environment(AccountStore.self) private var account
    let tint: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                AccountGroup(title: "账户") {
                    AccountRow(icon: "person", title: "用户名") { AccountValue(account.displayName.isEmpty ? "—" : account.displayName) }
                    AccountDivider()
                    AccountRow(icon: "envelope", title: "电子邮件") {
                        AccountValue(account.session.map { $0.email.isEmpty ? "未设置" : $0.email } ?? "未设置")
                    }
                }
                if let s = account.session {
                    AccountGroup(title: "这次登录") {
                        AccountRow(icon: "key", title: "登录方式") { AccountValue(Self.methodName(s.method, bio: account.biometryName)) }
                        AccountDivider()
                        AccountRow(icon: "clock", title: "登录时间") { AccountValue(s.at.formatted(date: .abbreviated, time: .shortened)) }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 44)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background { AccountBackdrop(tint: tint).ignoresSafeArea() }
        .navigationTitle("个人档案")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    static func methodName(_ m: String, bio: String) -> String {
        switch m {
        case "password": return "密码"
        case "email_otp": return "电子邮件验证码"
        case "faceid": return bio
        case "register": return "新建账户"
        case "demo": return "演示"
        default: return m
        }
    }
}

// MARK: - 部件（参考图：Apple「游戏」App 的个人页）

/// 一组：粗体组名 + 一张卡（+ 卡下一行灰色说明）
struct AccountGroup<Rows: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            AccountCard(content: rows)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 圆角 26 的半透明卡：一层 7% 的白、一圈 9% 白的细边
struct AccountCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 0) { content() }
            .background(shape.fill(Color.white.opacity(0.07)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }
}

/// 卡里的一行：左边一枚灰色符号，标题 + 一行灰色说明，右边「›」、开关或数值
struct AccountRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var titleColor: Color = .white
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(minHeight: subtitle == nil ? 66 : 78)
        .contentShape(Rectangle())
    }
}

/// 两行之间的细线（从卡的左边往里一点，一直到右边）
struct AccountDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

struct AccountChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white.opacity(0.45))
            .accessibilityHidden(true)
    }
}

/// 行尾的灰字数值
struct AccountValue: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// 整行可点的按下效果：底上一层淡白
struct AccountRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.07 : 0))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 整页的底：顶上是头像的主色，往下渐暗到深灰（参考图：紫 → 深紫 → 灰）
struct AccountBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color(white: 0.09)
            LinearGradient(stops: [
                .init(color: tint, location: 0),
                .init(color: tint.opacity(0.45), location: 0.28),
                .init(color: Color.black.opacity(0.0), location: 0.62),
            ], startPoint: .top, endPoint: .bottom)
            // 中段压暗一点，卡里的白字读得清
            LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0.1),
                .init(color: .black.opacity(0.45), location: 0.42),
                .init(color: .black.opacity(0), location: 0.78),
            ], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// 头像取色：保留色相，饱和度和亮度落到参考图那种「带一点颜色的深紫」；太灰（几乎没颜色）的头像用默认紫
enum AccountPalette {
    static let fallback = Color(hue: 0.70, saturation: 0.55, brightness: 0.52)

    static func tint(from c: UIColor) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s > 0.12 else { return fallback }
        return Color(hue: Double(h), saturation: Double(min(0.7, max(0.38, s))), brightness: 0.5)
    }
}
