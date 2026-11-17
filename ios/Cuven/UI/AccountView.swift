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
/// · 头部居中：88 点的圆头像（右下角一枚 Cuven 小图标；点它换头像）、大号粗体的名字；
/// · 头部下面是个人资料卡（账户页移植（网页版）：头像、姓名、电子邮件、登录面容，见 AccountProfile.swift；「订阅」那一行用户要求移除），
///   顶替以前那颗「个人档案」胶囊钮和它推进去的那一页（那一页的「登录方式」「登录时间」挪到「登录与安全」）；
/// · 下面每一组是一行粗体的组名 + 一张圆角 26 的半透明卡，卡里一行一项：左边一枚灰色符号，标题 + 一行灰色说明，右边「›」、开关或数值；
/// · 右上是系统的关闭钮（iOS 26 的玻璃圆钮），往上滚过头部，名字接到导航栏里。
/// 内容：个人资料卡、网络、使用洞察（含「清除缓存」）、观看（含「清除继续观看」）、通知、播放、登录与安全（「片库」「关于」「存储」三组用户要求移除 / 并走），最底下单独一张「退出登录」（先用系统的确认：C44、C47；文案照网页版）。
/// 「新片上架通知」打开的那一刻才向系统要权限（C78、C79）；系统里关着就多一行「打开设置」（C97）。
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PlayerCoordinator.autoplayKey) private var autoplayNext = true
    /// 首选音轨 / 首选字幕（用户要求，TrackPrefs.swift）
    @AppStorage(TrackPrefs.audioKey) private var audioPref = TrackPrefs.Audio.auto.rawValue
    @AppStorage(TrackPrefs.subtitleKey) private var subtitlePref = TrackPrefs.Subtitle.auto.rawValue
    /// 「新片上架通知」：自己选的开 / 关。系统那边的通知权限另看（notifyBlocked）
    @AppStorage(AccountView.notifyKey) private var notifyWanted = false
    /// 和账户设置同步的两个本机设置（网络速度、流量概览展开；「使用」那两张卡改它们）：一变就防抖存回账户
    @AppStorage(ProfileKeys.networkSpeed) private var networkSpeed = 80
    @AppStorage(ProfileKeys.trafficExpanded) private var trafficExpanded = true
    /// 个人资料卡、头部头像打开的弹层（头像、电子邮件、更改姓名、重设登录面容）
    @State private var profileSheet: ProfileSheet?
    /// 系统设置里 Cuven 的通知是关着的（拒绝过，或者后来到设置里关了）
    @State private var notifyBlocked = false
    @State private var notifyAsking = false
    @State private var confirmSignOut = false
    /// 顶上那一截的颜色：头像的主色（取不到是紫色）
    @State private var tint = AccountPalette.fallback
    /// 头部滚出去了：名字接到导航栏里
    @State private var showName = false

    static let notifyKey = "cuven_notify_new_titles"
    @Environment(\.horizontalSizeClass) private var hsc

    private var displayName: String { account.displayName.isEmpty ? "访客" : account.displayName }

    var body: some View {
        ZoomStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    VStack(alignment: .leading, spacing: 34) {
                        // 个人资料卡（账户页移植（网页版）：网页版账户页的第一张卡）
                        ProfileCard { profileSheet = $0 }
                        // 网络速度（网页版的第二张卡：45 根竖条的滑块，在 iOS 上管正片缓冲多少秒，AccountUsage.swift）
                        NetworkSpeedCard()
                        // 使用洞察 · 流量概览（网页版的第三张卡；数是这台设备真的下载了多少，不是网页版的随机数）
                        UsageInsightsCard()
                        watchingGroup
                        notifyGroup
                        playbackGroup
                        securityGroup
                        signOutGroup
                    }
                    // 名字下面直接是个人资料卡（没有组名），比以前到第一个组名（40）近一点
                    .padding(.top, 28)
                }
                // 卡更宽一点（用户要求卡片更精致）：窄屏（iPhone、折起的 Duo）左右 24 → 16 点，和系统分组列表一样；宽屏照旧 24
                .padding(.horizontal, hsc == .compact ? 16 : 24)
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
            // 头部（头像 88 + 16 + 名字）约 150 点高：名字滚出去了才接到导航栏里（以前还有一颗胶囊，是 200）
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.contentInsets.top > 150
            } action: { _, v in
                withAnimation(.easeOut(duration: 0.2)) { showName = v }
            }
            // 文案照网页版的退出确认（logout-sheet）；仍是系统的确认（C44、C47）
            .confirmationDialog("要退出登录吗？", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    dismiss()
                    // 登录层淡入（网页版鉴权层打开：0.28 秒 --silk-in）
                    withAnimation(.timingCurve(0.22, 0.68, 0.28, 1, duration: 0.28)) { account.signOut() }
                }
            } message: {
                Text("退出后，本机将不再保留当前登录状态。下次进入需要重新验证身份。")
            }
            .sheet(item: $profileSheet) { ProfileSheetView(sheet: $0) }
            // 网络速度、流量概览展开改了：0.8 秒内不再变就存回账户设置（服务器读回来写进本机时也会走到这里，值没变不发请求）
            .onChange(of: networkSpeed) { _, _ in ProfileStore.shared.scheduleSave() }
            .onChange(of: trafficExpanded) { _, _ in ProfileStore.shared.scheduleSave() }
            .task {
                seedNotifyPreference()
                await refreshNotify()
            }
            // 账户资料（设置、电子邮件）：每次打开都刷新，缓存先上屏（网页版每次进账户屏都刷新）
            .task(id: account.session?.username) {
                guard let s = account.session else { return }
                await ProfileStore.shared.load(for: s.username, sessionEmail: s.email)
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

    /// 头像（右下角一枚 Cuven 小图标；点它打开头像选择，和资料卡「头像」那一行同一个）、名字。
    /// 以前名字下面还有一颗「个人档案」胶囊钮，推进去看用户名、电子邮件、登录方式与时间：
    /// 现在由下面的个人资料卡顶替（登录方式、登录时间挪到「登录与安全」）
    private var header: some View {
        VStack(spacing: 0) {
            Button { profileSheet = .avatar } label: {
                AvatarView(size: 88)
                    .overlay(alignment: .bottomTrailing) {
                        Image("BrandIcon")
                            .resizable()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                            .offset(x: 6, y: 4)
                            .accessibilityHidden(true)
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.96))
            .accessibilityLabel("头像")
            .accessibilityHint("更改个人形象")
            .accessibilityIdentifier("account-header-avatar")
            Text(displayName)
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    // MARK: 各组

    /// 观看：点进去是整页清单（在这一页里推进去）。行里不写「共 N 部」（用户要求全局去掉影片计数）
    private var watchingGroup: some View {
        AccountGroup(title: "观看") {
            NavigationLink(value: Route.shelf(.continueWatching)) {
                AccountRow(icon: "play.circle", title: "继续观看") { AccountChevron() }
            }
            .buttonStyle(AccountRowPress())
            AccountDivider()
            NavigationLink(value: Route.shelf(.watchlist)) {
                AccountRow(icon: "bookmark", title: "想看") { AccountChevron() }
            }
            .buttonStyle(AccountRowPress())
            AccountDivider()
            // 以前在「存储」那一组；「清除缓存」挪进「使用洞察」那张卡以后，这一组只剩它，挪到这里和继续观看放在一起
            Button { model.playback.clearAll() } label: {
                AccountRow(icon: "clock.arrow.circlepath", title: "清除继续观看", titleColor: Color(red: 1, green: 0.42, blue: 0.38)) { EmptyView() }
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
        let audio = TrackPrefs.Audio(rawValue: audioPref) ?? .auto
        let subtitle = TrackPrefs.Subtitle(rawValue: subtitlePref) ?? .auto
        return AccountGroup(title: "播放", footer: "每一集开始时按这里选一次；播放中在播放器里换的不受影响。") {
            AccountRow(icon: "forward.end", title: "自动播放下一集", subtitle: "一集看完，接着放下一集") {
                Toggle("自动播放下一集", isOn: $autoplayNext)
                    .labelsHidden()
                    .tint(.green)
            }
            AccountDivider()
            // 首选音轨 / 首选字幕（用户要求「允许设置字幕和音轨首选项」）：整行是一颗系统弹出菜单，勾着当前那一项（C11）
            Menu {
                Picker("首选音轨", selection: $audioPref) {
                    ForEach(TrackPrefs.Audio.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                AccountRow(icon: "waveform", title: "首选音轨", subtitle: audio.hint) {
                    AccountMenuValue(audio.label)
                }
            }
            .menuStyle(.button)
            .buttonStyle(AccountRowPress())
            .accessibilityLabel("首选音轨")
            .accessibilityValue(audio.label)
            .accessibilityHint(audio.hint)
            AccountDivider()
            Menu {
                Picker("首选字幕", selection: $subtitlePref) {
                    ForEach(TrackPrefs.Subtitle.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                AccountRow(icon: "captions.bubble", title: "首选字幕", subtitle: subtitle.hint) {
                    AccountMenuValue(subtitle.label)
                }
            }
            .menuStyle(.button)
            .buttonStyle(AccountRowPress())
            .accessibilityLabel("首选字幕")
            .accessibilityValue(subtitle.label)
            .accessibilityHint(subtitle.hint)
        }
        .sensoryFeedback(.selection, trigger: audioPref)
        .sensoryFeedback(.selection, trigger: subtitlePref)
    }

    // 「片库」（片子数量、刷新片库）和「关于」（版本、片源、账户服务）两组用户要求移除；片库照常在主页下拉刷新


    /// 面容 ID 快速登录的开关；下面两行（这次怎么登录的、什么时候）以前在「个人档案」那一页，那一页由个人资料卡顶替后挪到这里
    @ViewBuilder
    private var securityGroup: some View {
        if let s = account.session {
            AccountGroup(title: "登录与安全") {
                if account.loginRequired && account.biometryAvailable {
                    AccountRow(icon: account.biometrySymbol, title: "使用\(account.biometryName) 登录", subtitle: "下次轻点一下即可登录") {
                        Toggle("使用\(account.biometryName) 登录", isOn: faceIDBinding)
                            .labelsHidden()
                            .tint(.green)
                    }
                    AccountDivider()
                }
                AccountRow(icon: "key", title: "登录方式") { AccountValue(Self.methodName(s.method, bio: account.biometryName)) }
                AccountDivider()
                AccountRow(icon: "clock", title: "登录时间") { AccountValue(s.at.formatted(date: .abbreviated, time: .shortened)) }
            }
        }
    }

    /// 退出登录单独一张卡、红字居中，点了先用系统的确认（C44、C47）
    @ViewBuilder
    private var signOutGroup: some View {
        if account.loginRequired {
            AccountCard {
                Button { confirmSignOut = true } label: {
                    Text("退出登录")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.38))
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AccountRowPress())
                .accessibilityIdentifier("account-signout")
            }
        }
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

    // MARK: 登录

    private var faceIDBinding: Binding<Bool> {
        Binding(
            get: { account.faceIDUser != nil && account.faceIDUser == account.session?.username },
            set: { on in
                if on { Task { _ = await account.enableFaceID() } } else { account.disableFaceID() }
            })
    }

}

// 以前这里是「个人档案」那一页（头部胶囊钮推进去：用户名、电子邮件、登录方式、登录时间）。
// 账户页移植（网页版）后由头部下面的个人资料卡顶替（AccountProfile.swift），登录方式与时间挪到「登录与安全」。

// MARK: - 部件（参考图：Apple「游戏」App 的个人页）

/// 一组：粗体组名 + 一张卡（+ 卡下一行灰色说明）
struct AccountGroup<Rows: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.dsSectionTitle)
                .foregroundStyle(.white)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            AccountCard(content: rows)
            if let footer {
                // 卡下的说明和卡里那一列符号同一条左边线（离卡边 20；以前 8，和什么都对不上：F2），灰度用全 App 的第三级（50% → 55%）
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(DSInk.tertiary)
                    .padding(.horizontal, AccountMetrics.inset)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 圆角 24 的半透明卡：一层 7% 的白、一圈 9% 白的细边（行矮了以后圆角跟着收一点：26 → 24）
struct AccountCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(spacing: 0) { content() }
            .background(shape.fill(Color.white.opacity(0.07)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }
}

/// 卡里一行的几个距离（设计轮 2（并行·library））：行的左右内边距、符号那一列的宽、符号到字的间距。
/// 细线和卡下的说明都按它们对齐，不再各写各的数
enum AccountMetrics {
    /// 卡边到符号（也是卡下说明的左边线）
    static let inset: CGFloat = 20
    /// 符号那一列（默认字号时；跟着动态字体放大）。用户要求卡片更精致：40 → 32
    static let iconColumn: CGFloat = 32
    /// 符号到字（16 → 14）
    static let gap: CGFloat = 14
}

/// 卡里的一行：左边一枚灰色符号，标题 + 一行灰色说明，右边「›」、开关或数值。
/// 符号和它那一列跟着动态字体放大（@ScaledMetric：以前写死 24 点，字放大了符号还是那么小：F23、F71）；
/// 标题放不下时折成两行，不截断（F24）
struct AccountRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var titleColor: Color = .white
    /// 说明最多几行；电子邮件、姓名这种一个值的写 1（放不下从中间省略，不在地址中间折行：用户截图）
    var subtitleLines: Int = 2
    var subtitleTruncation: Text.TruncationMode = .tail
    @ViewBuilder var trailing: () -> Trailing
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 21
    @ScaledMetric(relativeTo: .title3) private var iconColumn: CGFloat = AccountMetrics.iconColumn

    var body: some View {
        // 用户要求个人信息页的卡片「在视觉上优雅精致」：标题 Title 3 → Body 半粗（20 → 17 点）、说明 Callout → Subheadline，
        // 符号 24 → 21、符号列 40 → 32、间距 16 → 14，一行 66 / 78 → 54 / 64 点高——
        // 字那一列宽出 16 点，折起的 Duo 上邮箱、「用于登录的面容数据」不再折成两行，整张卡矮了约四分之一
        HStack(spacing: AccountMetrics.gap) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(DSInk.tertiary)
                        .lineLimit(subtitleLines)
                        .truncationMode(subtitleTruncation)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, AccountMetrics.inset)
        .padding(.vertical, 10)
        .frame(minHeight: subtitle == nil ? 54 : 64)
        .contentShape(Rectangle())
    }
}

/// 两行之间的细线：从字的左边线起头、一直到卡的右边（设计轮 2（并行·library）：以前从卡边往里 16 点起头，
/// 比符号还靠左 4 点；系统分组列表的分隔线都从字那一列开始：F2、C30）
struct AccountDivider: View {
    @ScaledMetric(relativeTo: .title3) private var iconColumn: CGFloat = AccountMetrics.iconColumn

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 0.5)
            .padding(.leading, AccountMetrics.inset + iconColumn + AccountMetrics.gap)
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
            // 缓存大小这种会变的数：等宽数字，清掉以后不跳宽窄
            .monospacedDigit()
            .foregroundStyle(DSInk.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// 行尾的弹出菜单：当前选的那一项 + 上下箭头（系统弹出按钮的样子）
struct AccountMenuValue: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: 5) {
            AccountValue(text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
                .accessibilityHidden(true)
        }
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
