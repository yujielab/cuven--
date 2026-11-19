import AVFoundation
import CuvenLighting
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 光影实验室：用本机视频试播放器的画面光影
//
// 用户要求做一个能实际运行的演示：放本机视频（相册 / 文件）或内置的测试画面（火光、海面、夜色、霓虹），
// 看卡片上的光跟着画面走；开关动态光影、调光影强度和反射、开关空间响应（Core Motion）、模拟铰链角度，
// 看帧率 / GPU 时间 / 内存 / 降档状态，以及分析出来的 16 × 9 分区颜色和追踪到的光源。
// 入口：账户与设置 →「播放」→「光影实验室」；Debug 构建认 -CuvenPlayerLab YES（自动放测试画面，UI 测试截图用）。

@MainActor
enum PlayerLab {
    private static weak var controller: UIViewController?

    static func present(autoplayTestPattern: Bool = false) {
        guard controller == nil, let top = UIApplication.topViewController() else { return }
        let vc = UIHostingController(rootView: PlayerLabView(autoplayTestPattern: autoplayTestPattern))
        vc.modalPresentationStyle = .fullScreen
        vc.view.backgroundColor = .black
        controller = vc
        top.present(vc, animated: true)
    }

    static func dismiss() {
        controller?.dismiss(animated: true)
    }

    #if DEBUG
    static func presentIfRequested() {
        guard UserDefaults.standard.bool(forKey: "CuvenPlayerLab") else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            present(autoplayTestPattern: true)
        }
    }
    #endif

    /// 进程实际占用的内存（和 Xcode 内存表一样的口径：phys_footprint）
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// 从相册拿到的视频：拷进临时目录再放
struct LabMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dst)
            return LabMovie(url: dst)
        }
    }
}

struct PlayerLabView: View {
    let autoplayTestPattern: Bool

    @State private var model = CuvenPlayerViewModel()
    @State private var player: AVPlayer?
    @State private var sourceName = ""
    @State private var isTestPattern = false
    @State private var options = PlayerLightingOptions()
    @State private var simulateHinge = false
    @State private var hingeDegrees = 110.0
    @State private var diagnostics = LightingDiagnostics()
    @State private var palette: SampledPalette?
    @State private var memoryMB = 0.0
    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var loading = false
    @State private var message: String?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            Group {
                if landscape {
                    HStack(spacing: 0) {
                        stage(layout: .sideBySide)
                        ScrollView { controls.padding(16) }
                            .frame(width: min(360, geo.size.width * 0.34))
                            .background(Color(white: 0.06))
                    }
                } else {
                    VStack(spacing: 0) {
                        stage(layout: .stacked)
                            .frame(height: geo.size.height * 0.62)
                        ScrollView { controls.padding(16) }
                            .background(Color(white: 0.06))
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            model.onClose = { close() }
            model.activateStandalone()
            if autoplayTestPattern { loadTestPattern() }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loadFromPhotos(item)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result { loadFromFile(url) }
        }
        .task {
            // 内存每秒看一次（只是显示，不影响渲染）
            while !Task.isCancelled {
                memoryMB = PlayerLab.footprintMB()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: 播放器那一块

    private func stage(layout: CuvenPlayerLayout) -> some View {
        var opts = options
        opts.simulatedFold = simulateHinge ? hingeDegrees : nil
        return CuvenPlayerView(model: model, player: player, layout: layout, options: opts,
                               onDiagnostics: { diagnostics = $0 },
                               onPalette: { palette = $0 })
            .overlay {
                if player == nil {
                    VStack(spacing: 10) {
                        if loading {
                            ProgressView().tint(.white)
                        }
                        Text(loading ? "正在准备视频…" : "选一段视频，或放内置的测试画面")
                            .font(.subheadline)
                            .foregroundStyle(DSInk.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }
    }

    // MARK: 调节

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("光影实验室")
                    .font(.title2.bold())
                Spacer()
                Button("完成") { close() }
                    .font(.body.weight(.semibold))
                    .accessibilityIdentifier("lab-close")
            }

            section("视频") {
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .videos) {
                        Label("相册", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                    Button { importing = true } label: {
                        Label("文件", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    Button { loadTestPattern() } label: {
                        Label("测试画面", systemImage: "sparkles.tv")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("lab-test-pattern")
                }
                if !sourceName.isEmpty {
                    Text(sourceName)
                        .font(.footnote)
                        .foregroundStyle(DSInk.secondary)
                        .lineLimit(1)
                }
                if isTestPattern {
                    HStack(spacing: 8) {
                        ForEach(TestPatternVideo.sceneNames.indices, id: \.self) { i in
                            Button(TestPatternVideo.sceneNames[i]) { jump(toScene: i) }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("lab-scene-\(i)")
                        }
                    }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
                if player != nil {
                    // UI 测试等这一行出来再截图
                    Text(model.playing ? "播放中" : "已暂停")
                        .font(.caption)
                        .foregroundStyle(DSInk.tertiary)
                        .accessibilityIdentifier("lab-ready")
                }
            }

            section("光影") {
                Toggle("动态光影", isOn: Binding(get: { model.lightingEnabled }, set: { model.setLightingEnabled($0) }))
                    .accessibilityIdentifier("lab-lighting")
                labeledSlider("强度", value: Binding(get: { model.lightingIntensity }, set: { model.setLightingIntensity($0) }),
                              range: 0...1.5, format: "%.2f")
                labeledSlider("反射", value: Binding(get: { Double(options.reflectivity) }, set: { options.reflectivity = Float($0) }),
                              range: 0...1, format: "%.2f")
                Toggle("空间响应（陀螺仪）", isOn: $options.spatialResponse)
                Toggle("模拟铰链角度", isOn: $simulateHinge)
                if simulateHinge {
                    labeledSlider("铰链", value: $hingeDegrees, range: 30...180, format: "%.0f°")
                }
            }

            section("性能") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    metric("画面帧率", String(format: "%.0f fps", diagnostics.displayFPS))
                    metric("光影更新", String(format: "%.0f 次/秒", diagnostics.lightingFPS))
                    metric("GPU", String(format: "%.2f ms", diagnostics.gpuMilliseconds))
                    metric("CPU 编码", String(format: "%.2f ms", diagnostics.cpuMilliseconds))
                    metric("档位", qualityName(diagnostics.quality))
                    metric("热状态", thermalName(diagnostics.thermalState))
                    metric("纹理", String(format: "%.1f MB", Double(diagnostics.textureBytes) / 1_048_576))
                    metric("内存", String(format: "%.0f MB", memoryMB))
                    metric("跳过的帧", "\(diagnostics.skippedFrames)")
                    metric("折叠角度", String(format: "%.0f°%@", diagnostics.foldDegrees, model.hardwareFold != nil ? "（铰链）" : ""))
                }
                .font(.footnote.monospacedDigit())
                if !MetalRenderer.shaderFailures.isEmpty {
                    Text("Metal 不可用：\(MetalRenderer.shaderFailures.joined(separator: "；"))")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            section("取样到的颜色") {
                PaletteView(palette: palette)
                    .frame(height: 150)
                if let p = palette {
                    Text(String(format: "平均亮度 %.3f · 转场 %.2f · 光源 %d 个", p.average.w, p.sceneChange, p.lights.count))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(DSInk.secondary)
                }
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(DSInk.secondary)
            content()
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 40, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.footnote.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(DSInk.secondary)
            Text(value)
        }
    }

    private func qualityName(_ q: LightingQuality) -> String {
        switch q {
        case .high: return "高（30 次/秒 · 60 fps）"
        case .reduced: return "省电（15 次/秒 · 30 fps）"
        case .minimal: return "过热（光影冻结）"
        case .suspended: return "后台（暂停）"
        }
    }

    private func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "正常"
        case .fair: return "微热"
        case .serious: return "偏热"
        case .critical: return "过热"
        @unknown default: return "—"
        }
    }

    // MARK: 片源

    private func loadTestPattern() {
        loading = true
        message = nil
        Task { @MainActor in
            do {
                let url = try await TestPatternVideo.make()
                play(url: url, name: "测试画面：火光 → 海面 → 夜色 → 霓虹（每段 4 秒）", testPattern: true)
            } catch {
                message = "测试画面生成失败：\(error.localizedDescription)"
            }
            loading = false
        }
    }

    private func loadFromPhotos(_ item: PhotosPickerItem) {
        loading = true
        message = nil
        Task { @MainActor in
            do {
                if let movie = try await item.loadTransferable(type: LabMovie.self) {
                    play(url: movie.url, name: "相册中的视频", testPattern: false)
                } else {
                    message = "这段视频读不出来。"
                }
            } catch {
                message = "读取失败：\(error.localizedDescription)"
            }
            loading = false
            photoItem = nil
        }
    }

    private func loadFromFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: dst)
            play(url: dst, name: url.lastPathComponent, testPattern: false)
        } catch {
            message = "拷贝失败：\(error.localizedDescription)"
        }
    }

    /// 换片源：旧的停掉，新的循环播放；面板、光影引擎都跟着换
    private func play(url: URL, name: String, testPattern: Bool) {
        player?.pause()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }
        player = p
        model.player = p
        model.title = testPattern ? "测试画面" : name
        model.subtitle = testPattern ? "火光 · 海面 · 夜色 · 霓虹" : "本机视频"
        model.artwork = nil
        model.rebind()
        sourceName = name
        isTestPattern = testPattern
        p.play()
    }

    private func jump(toScene index: Int) {
        guard let p = player else { return }
        let t = (Double(index) + 0.35) * TestPatternVideo.sceneDuration
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        p.play()
    }

    private func close() {
        player?.pause()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        model.deactivateStandalone()
        PlayerLab.dismiss()
    }
}

/// 16 × 9 分区的颜色（线性转回显示用的 sRGB）+ 追踪到的光源（圈的大小 = 光源半径）
private struct PaletteView: View {
    let palette: SampledPalette?

    var body: some View {
        Canvas { ctx, size in
            guard let p = palette, p.cells.count == SampledPalette.columns * SampledPalette.rows else {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.1)))
                return
            }
            let cw = size.width / CGFloat(SampledPalette.columns)
            let ch = size.height / CGFloat(SampledPalette.rows)
            for row in 0..<SampledPalette.rows {
                for col in 0..<SampledPalette.columns {
                    let c = p.cells[row * SampledPalette.columns + col]
                    let rect = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * ch, width: cw + 0.5, height: ch + 0.5)
                    ctx.fill(Path(rect), with: .color(Self.display(c.x, c.y, c.z)))
                }
            }
            for light in p.lights {
                let center = CGPoint(x: CGFloat(light.position.x) * size.width, y: CGFloat(light.position.y) * size.height)
                let r = max(6, CGFloat(light.radius) * size.width)
                let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                ctx.stroke(circle, with: .color(.white.opacity(Double(light.presence))), lineWidth: 2)
                let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
                ctx.fill(dot, with: .color(Self.display(light.color.x, light.color.y, light.color.z)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("取样到的颜色")
    }

    static func display(_ r: Float, _ g: Float, _ b: Float) -> Color {
        func encode(_ v: Float) -> Double { Double(pow(max(min(v, 1), 0), 1 / 2.2)) }
        return Color(red: encode(r), green: encode(g), blue: encode(b))
    }
}
