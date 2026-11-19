import SwiftUI

// MARK: - 进度条用到的颜色和念法
//
// 进度条本身在 Touch Bar 里（PlayerToolbar.swift 的 TouchBarScrubber）：细、轻，Cuven 蓝的已播放部分，中性灰的剩余部分，
// 一颗小圆点；播放时每 0.25 秒更新一次、中间线性补平；拖动时圆点放大、时间跟着手指走，松手才跳过去。
// 旁白：「播放进度」，值是「已播放 x，共 y」，上下扫动前进 / 后退 10 秒。

enum PlayerPalette {
    /// 已播放：Cuven 的蓝（Theme.accent）
    static let progress = Theme.accent
    static let track = Color.white.opacity(0.24)
}

enum PlaybackClock {
    /// 旁白念的：「1 小时 2 分 3 秒」
    static func spoken(_ s: Double) -> String {
        let t = Int(max(0, s.isFinite ? s : 0).rounded(.down))
        let h = t / 3600, m = t / 60 % 60, sec = t % 60
        return (h > 0 ? "\(h) 小时 " : "") + "\(m) 分 \(sec) 秒"
    }
}
