import SwiftUI

// MARK: - 清除缓存（用户要求「清除缓存的时候要有这样的动画」，参照用户发来的录屏：Prismatic Data Dissolution）
//
// 整屏黑底，上半截浮着一张 3D 的「缓存卡」（卡面写着这次要清的大小），下面一枚小胶囊「Cuven 缓存」、一行「清除 1.2 GB 缓存？」、
// 「取消」「清除」两颗胶囊。点「清除」：两颗按钮收成一枚玻璃进度胶囊（转圈 + 「正在清除 0.6 GB / 1.2 GB」，数字跟着溶解前沿走），
// 卡从下沿化成光点、流成光纤、汇进胶囊那一点的光里（CacheDissolveRenderer）；真的清除同时在做（清三样缓存、重新取片库）。
// 动画走完、清除也做完：胶囊换成「已清除 1.2 GB」和一枚勾，1.3 秒后自己收起。

struct CacheDissolveSheet: View {
    let bytes: Int64
    let clear: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var engine = CacheDissolveEngine()
    @State private var phase: Phase = .idle
    /// 打开时那一刻的大小：清的过程中外面的数会变小，卡面和胶囊上的总数不跟着变
    @State private var total: Int64
    @Namespace private var ns

    init(bytes: Int64, clear: @escaping () async -> Void) {
        self.bytes = bytes
        self.clear = clear
        _total = State(initialValue: bytes)
    }

    enum Phase { case idle, clearing, done }

    private var sizeText: String {
        let s = Format.size(total)
        return s.isEmpty ? "0 MB" : s
    }

    var body: some View {
        // 这一层的 GeometryReader 不忽略安全区：size 是安全区里的大小，safeAreaInsets 是上下留出来的
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                CacheDissolveCanvas(engine: engine, sizeLabel: sizeText)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        if phase == .idle { closeButton.transition(.opacity) }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 20)
                    Spacer(minLength: 0)
                    if phase == .idle {
                        prompt
                            .padding(.bottom, 26)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    actions
                        .padding(.bottom, Self.bottomPad)
                }
            }
            .onAppear { place(geo) }
            .onChange(of: geo.size) { _, _ in place(geo) }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(phase != .idle)
        .sensoryFeedback(.impact(weight: .medium), trigger: phase == .clearing)
        .sensoryFeedback(.success, trigger: phase == .done)
        .onAppear { engine.reduceMotion = reduceMotion }
    }

    private static let bottomPad: CGFloat = 24

    /// 光流汇聚的那一点：进度胶囊的正中（胶囊 46 点高，在安全区底下居中），换算成整屏（画布铺满整屏）里的比例。
    /// 横向也按安全区算：iPhone Duo 一边有一列状态栏，内容区不在屏幕正中，卡和光都要对着胶囊
    private func place(_ geo: GeometryProxy) {
        let fullH = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
        let fullW = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        guard fullH > 0, fullW > 0 else { return }
        let cx = (geo.safeAreaInsets.leading + geo.size.width / 2) / fullW
        engine.centerX = cx
        engine.target = CGPoint(x: cx, y: (geo.safeAreaInsets.top + geo.size.height - Self.bottomPad - 23) / fullH)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
        .accessibilityIdentifier("cache-dissolve-close")
    }

    private var prompt: some View {
        VStack(spacing: 14) {
            Label("Cuven 缓存", systemImage: "internaldrive")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
            Text("清除 \(sizeText) 缓存？")
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var actions: some View {
        if phase == .idle {
            HStack(spacing: 14) {
                Button("取消") { dismiss() }
                    .buttonStyle(CacheDissolvePill(prominent: false))
                    .accessibilityIdentifier("cache-dissolve-cancel")
                Button("清除") { start() }
                    .buttonStyle(CacheDissolvePill(prominent: true))
                    .matchedGeometryEffect(id: "action", in: ns)
                    .accessibilityIdentifier("cache-dissolve-clear")
            }
        } else {
            progressCapsule
                .matchedGeometryEffect(id: "action", in: ns)
                .accessibilityIdentifier("cache-dissolve-progress")
        }
    }

    /// 玻璃进度胶囊：转圈 + 「正在清除 已清 / 总共」，完了换成勾 +「已清除」
    private var progressCapsule: some View {
        TimelineView(.animation(paused: phase == .done)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = engine.progress()
            HStack(spacing: 10) {
                if phase == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle()
                        .trim(from: 0.08, to: 0.78)
                        .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 16, height: 16)
                        .rotationEffect(.radians(t * 5.2))
                }
                Text(phase == .done ? "已清除 \(sizeText)" : "正在清除 \(clearedText(p)) / \(sizeText)")
                    .lineLimit(1)
                    .fixedSize()
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 20)
            .frame(height: 46)
            .glassEffect(.regular, in: Capsule())
        }
        // 胶囊多大：渲染器里那一圈光贴着它的形状
        .onGeometryChange(for: CGSize.self) { $0.size } action: { engine.capsulePt = $0 }
    }

    private func clearedText(_ p: Double) -> String {
        let s = Format.size(Int64(Double(total) * p))
        return s.isEmpty ? "0 MB" : s
    }

    private func start() {
        guard phase == .idle else { return }
        engine.reduceMotion = reduceMotion
        engine.start = CACurrentMediaTime()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { phase = .clearing }
        let work = Task { @MainActor in await clear() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(CacheDissolveEngine.duration))
            await work.value
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { phase = .done }
            try? await Task.sleep(for: .seconds(1.3))
            dismiss()
        }
    }
}

/// 白底黑字（主要的）/ 半透明白底白字（次要的）胶囊，按下缩一点
private struct CacheDissolvePill: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(minWidth: 116)
            .frame(height: 46)
            .padding(.horizontal, 8)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
