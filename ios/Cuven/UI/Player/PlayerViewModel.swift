import AVFoundation
import AVKit
import CuvenLighting
import SwiftUI
import UIKit

// MARK: - 播放面板的状态（MVVM 的 ViewModel）
//
// 半折播放器（PlayerTabletop.swift）和光影实验室（PlayerLab.swift）共用：
//   · 正在放什么：片名、第几集、画面、后面还有没有下一集；
//   · 播放状态：放着没有、位置、时长、速度——面板出来时每 0.25 秒跟播放器对一次（只有值变了才写，SwiftUI 不会每帧刷新）；
//   · 面板自己的状态：锁定、第四行展开的滑杆、拖进度条、闲置时符号淡出；
//   · 画中画、截取画面、铰链角度（iOS 27.1 的 onHingeChange 喂进来）。光影的模式和微调在 CinematicLightingSettings。
// 光影引擎本身（CuvenLighting 框架）不在这里：面板把播放器、卡片位置、设置交给它，它自己按显示刷新率画。

@MainActor
@Observable
final class CuvenPlayerViewModel {
    // 放的是哪一部（PlayerCoordinator 每开始一集写一次）
    var title = ""
    var subtitle: String?
    var artwork: String?
    var hasNext = false
    /// 片源的动态范围（服务器的 info.json、文件名）：HDR / 杜比视界的片子光影不取画面的帧（取了会改变屏上的画面：
    /// 用户真机截图，杜比视界 5 变成一片绿和品红），改用这一集的剧照打光
    var sourceRange: LightingSourceRange = .unknown

    /// 横着的折痕（半折）；没有：nil
    private(set) var fold: CGRect?
    /// 这一次半折里点了「全屏」
    private(set) var fullscreen = false
    /// 面板在用（半折时；实验室里一直是）
    private(set) var active = false
    /// 播放器在屏上、App 在前台：才挂面板那一层画面（画中画时也挂着）
    var visible = true

    private(set) var playing = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    /// 拖着进度条时指着的位置（松手才跳过去）
    var scrub: Double?
    var locked = false
    /// 第四行展开成一条滑杆：亮度 / 音量
    var tray: Tray?
    var brightness: Double = 0.5
    private(set) var audioNames: [String] = []
    private(set) var subtitleNames: [String] = []
    private(set) var audioPick = -1
    /// -1：字幕关着
    private(set) var subtitlePick = -1
    /// 闲置 5 秒（放着、没锁、没在拖、没展开滑杆）：符号淡出，卡片上的光照常
    private(set) var controlsVisible = true
    private(set) var pipPossible = false
    private(set) var pipActive = false

    /// 铰链读数（度）：系统报了才有
    var hardwareFold: Double?

    enum Tray { case brightness, volume }

    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    @ObservationIgnored weak var player: AVPlayer?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onNext: (() -> Void)?
    @ObservationIgnored var onActiveChange: ((Bool) -> Void)?
    /// 画中画开始 / 结束、要回到播放器（半折播放器交给 PlayerCoordinator 处理；实验室里不用）
    @ObservationIgnored var onPiPWillStart: (() -> Void)?
    @ObservationIgnored var onPiPDidStop: (() -> Void)?
    @ObservationIgnored var onPiPRestore: ((@escaping (Bool) -> Void) -> Void)?
    /// 截图用（DEBUG 的 -CuvenTabletop）：不接播放器，按钮只改面板上的样子
    @ObservationIgnored var preview = false
    /// 设置页里的预览：符号一直显示（不进闲置）
    @ObservationIgnored var keepsControlsVisible = false
    /// 退到后台时由面板这一层画面自动进画中画（半折播放时：那时系统播放器那一层不接画面）
    @ObservationIgnored var automaticPictureInPicture = false
    /// 光影设置开着（剧集信息卡点开的弹窗）：不进闲置
    @ObservationIgnored private var settingsOpen = false
    @ObservationIgnored weak var pipController: AVPictureInPictureController?

    @ObservationIgnored private var standalone = false
    @ObservationIgnored private var timeToken: Any?
    @ObservationIgnored private weak var timePlayer: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var audioOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var subtitleOptions: [AVMediaSelectionOption] = []
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    // MARK: 折痕 / 启用

    func setFold(_ f: CGRect?) {
        guard f != fold else { return }
        // 合上 / 摊平：「全屏」只管这一次半折，下次半折又是上下两块
        if f == nil { fullscreen = false }
        fold = f
        update()
    }

    func goFullscreen() {
        fullscreen = true
        update()
    }

    /// 实验室：不看折痕，一直在用
    func activateStandalone() {
        standalone = true
        update()
    }

    func deactivateStandalone() {
        standalone = false
        update()
    }

    private func update() {
        let now = standalone || (fold != nil && !fullscreen)
        guard now != active else { return }
        active = now
        tray = nil
        locked = false
        scrub = nil
        controlsVisible = true
        if now { bind(); poke() } else { unbind(); idleTask?.cancel() }
        onActiveChange?(now)
    }

    // MARK: 播放状态（面板出来时每 0.25 秒一次）

    private func bind() {
        brightness = Double(Self.screen?.brightness ?? 0.5)
        if preview {
            playing = true
            duration = 2_700
            position = 277
            audioNames = ["国语", "English"]
            subtitleNames = ["简体中文", "English"]
            audioPick = 0
            subtitlePick = 0
            return
        }
        guard let p = player else { return }
        unbind()
        timePlayer = p
        timeToken = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        statusObservation = p.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // 换了一集 / 换了片源：音轨和字幕重新读
        itemObservation = p.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.loadTracks()
            }
        }
        refresh()
        loadTracks()
    }

    /// 实验室换了播放器（换了本机视频）
    func rebind() {
        guard active else { return }
        unbind()
        bind()
    }

    private func unbind() {
        if let t = timeToken { timePlayer?.removeTimeObserver(t) }
        timeToken = nil
        timePlayer = nil
        statusObservation?.invalidate()
        statusObservation = nil
        itemObservation?.invalidate()
        itemObservation = nil
    }

    private func refresh() {
        guard !preview, let p = player else { return }
        let isPlaying = p.timeControlStatus != .paused
        if playing != isPlaying {
            playing = isPlaying
            poke()
        }
        if rate != p.defaultRate { rate = p.defaultRate }
        let d = p.currentItem?.duration.seconds ?? 0
        let dur = d.isFinite && d > 0 ? d : 0
        if duration != dur { duration = dur }
        let t = p.currentTime().seconds
        let pos = t.isFinite ? max(0, t) : 0
        if position != pos { position = pos }
    }

    /// 片源里的音轨、字幕（强制字幕不列：那是跟着音轨自动出的）
    private func loadTracks() {
        guard !preview, let item = player?.currentItem else {
            audioNames = []
            subtitleNames = []
            return
        }
        let asset = item.asset
        Task { @MainActor [weak self, weak item] in
            let a = try? await asset.loadMediaSelectionGroup(for: .audible)
            let l = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, let item, item === self.player?.currentItem else { return }
            self.audioGroup = a
            self.legibleGroup = l
            self.audioOptions = a?.options ?? []
            self.subtitleOptions = (l?.options ?? []).filter { !TrackPrefs.isForced($0) }
            self.audioNames = self.audioOptions.map(\.displayName)
            self.subtitleNames = self.subtitleOptions.map(\.displayName)
            self.syncPicks()
        }
    }

    private func syncPicks() {
        guard let item = player?.currentItem else { return }
        let sel = item.currentMediaSelection
        audioPick = audioGroup.flatMap { g in sel.selectedMediaOption(in: g).flatMap { audioOptions.firstIndex(of: $0) } } ?? -1
        subtitlePick = legibleGroup.flatMap { g in sel.selectedMediaOption(in: g).flatMap { subtitleOptions.firstIndex(of: $0) } } ?? -1
    }

    // MARK: 闲置

    /// 有人碰了面板（或者状态变了）：符号回来，5 秒后再看要不要淡出
    func poke() {
        if !controlsVisible { controlsVisible = true }
        idleTask?.cancel()
        guard active, !preview, !keepsControlsVisible else { return }
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            if self.playing, !self.locked, self.tray == nil, self.scrub == nil, !self.settingsOpen {
                self.controlsVisible = false
            }
        }
    }

    func setSettingsOpen(_ open: Bool) {
        settingsOpen = open
        poke()
    }

    // MARK: 按钮

    func togglePlay() {
        Haptics.light()
        poke()
        if preview { playing.toggle(); return }
        guard let p = player else { return }
        if p.timeControlStatus == .paused { p.play() } else { p.pause() }
        refresh()
    }

    func skip(_ seconds: Double) {
        Haptics.selection()
        poke()
        seek(to: position + seconds)
    }

    func seek(to t: Double) {
        let x = duration > 1 ? min(max(0, t), duration - 1) : max(0, t)
        position = x
        guard !preview, let p = player else { return }
        p.seek(to: CMTime(seconds: x, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ r: Float) {
        rate = r
        poke()
        guard !preview, let p = player else { return }
        // defaultRate：之后每次 play() 都用这个速度（暂停时改了，接着放也是它）
        p.defaultRate = r
        if p.timeControlStatus != .paused { p.rate = r }
    }

    func setBrightness(_ v: Double) {
        brightness = v
        Self.screen?.brightness = CGFloat(v)
    }

    func selectAudio(_ i: Int) {
        audioPick = i
        guard let g = audioGroup, audioOptions.indices.contains(i), let item = player?.currentItem else { return }
        item.select(audioOptions[i], in: g)
        syncPicks()
    }

    func selectSubtitle(_ i: Int) {
        subtitlePick = i
        guard let g = legibleGroup, let item = player?.currentItem else { return }
        if subtitleOptions.indices.contains(i) {
            item.select(subtitleOptions[i], in: g)
        } else if g.allowsEmptySelection {
            item.select(nil, in: g)
        }
        syncPicks()
    }

    func toggleLock() {
        Haptics.light()
        locked.toggle()
        tray = nil
        poke()
    }

    func toggleTray(_ t: Tray) {
        Haptics.selection()
        if t == .brightness { brightness = Double(Self.screen?.brightness ?? CGFloat(brightness)) }
        tray = tray == t ? nil : t
        poke()
    }

    // MARK: 画中画（面板自己那一层画面；系统播放器那一层的画中画照旧由系统处理）

    func setPiPPossible(_ on: Bool) {
        if pipPossible != on { pipPossible = on }
    }

    func startPiP() {
        Haptics.light()
        guard let c = pipController, c.isPictureInPicturePossible else { return }
        c.startPictureInPicture()
    }

    func pipWillStart() {
        pipActive = true
        onPiPWillStart?()
    }

    func pipDidStop() {
        pipActive = false
        onPiPDidStop?()
    }

    func pipRestore(_ completion: @escaping (Bool) -> Void) {
        if let onPiPRestore { onPiPRestore(completion) } else { completion(true) }
    }

    private static var screen: UIScreen? { VideoOrientation.activeScene?.screen }
}
