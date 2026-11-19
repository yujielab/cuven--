import CoreGraphics

// MARK: - 面板的格子：按「离折痕多远」排，跟着姿态转过去（参照 Netflix 在 iPhone Duo 上的播放器）
//
// Netflix：「控制跟着你动——全屏、书本、桌面，不管怎么看都排得过来，始终够得着」。参照它的样机：
//   · 桌面（折痕在面板上边）：从折痕往下四行——
//       ① 关闭 | 剧集信息卡（最宽）| 画中画 | 锁定       （矮）
//       ② 后退 10 秒 | 播放 / 暂停 | 前进 10 秒          （最高，三块一样宽）
//       ③ 进度条（一整块）
//       ④ 播放速度 | 亮度 | 音量 | 音频与字幕 | 下一集 | 全屏（一样宽）
//   · 书本（折痕在面板旁边）：同一套格子转 90°——离折痕最近的一列是 ①，往外依次 ②③④；
//     沿着折痕从上往下就是桌面时从左往右的顺序，进度条竖着走（从上往下）。
// 格子在「沿折痕 u、离折痕 v」的坐标里算一次，再按折痕在面板的哪一边换到屏上。换姿态时每一块从旧位置形变到新位置
// （卡面由渲染器的弹簧带过去，符号由 SwiftUI 的弹簧带过去）。

/// 折痕在面板的哪一边
enum PanelFoldEdge: Equatable {
    /// 桌面：画面在上
    case top
    /// 书本：画面在右页，面板在左页（Netflix 样机的摆法）
    case trailing
    /// 书本：画面在左页，面板在右页
    case leading

    /// 格子是一列一列的（书本）
    var isColumns: Bool { self != .top }
}

/// 面板上的每一块
enum PlayerTile: String, CaseIterable, Hashable {
    case close, title, pip, lock
    case back, play, forward
    case timeline
    case speed, brightness, volume, tracks, next, fullscreen
    /// 第四排整条（亮度 / 音量展开成的那一条滑杆）
    case tray
}

struct PlayerPanelGrid: Equatable {
    private(set) var frames: [PlayerTile: CGRect] = [:]
    let foldEdge: PanelFoldEdge

    var isColumns: Bool { foldEdge.isColumns }

    func frame(_ t: PlayerTile) -> CGRect? { frames[t] }

    /// size：卡片区（面板去掉边距）；tools：第四排有哪些（顺序就是沿折痕的顺序）
    init(size: CGSize, foldEdge: PanelFoldEdge, tools: [PlayerTile], gap g: CGFloat = PlayerPanelStyle.gap) {
        self.foldEdge = foldEdge
        let edge = foldEdge
        let columns = edge.isColumns
        // A：沿折痕的长度；B：离折痕的深度
        let A = max(0, columns ? size.height : size.width)
        let B = max(0, columns ? size.width : size.height)
        let avail = max(0, B - g * 3)

        // 四排的厚度。桌面：参照图量的 77 : 142 : 51 : 51，很高时多出来的都给第二排；
        // 书本：一列至少要放得下一颗符号和两行字
        let header, bar, mid: CGFloat
        if columns {
            header = min(104, max(64, avail * 0.23)).rounded()
            bar = min(84, max(56, avail * 0.17)).rounded()
            mid = max(64, avail - header - bar * 2)
        } else {
            header = min(84, max(52, avail * 0.22)).rounded()
            bar = min(58, max(44, avail * 0.16)).rounded()
            mid = max(56, avail - header - bar * 2)
        }

        var f: [PlayerTile: CGRect] = [:]
        func put(_ t: PlayerTile, u: CGFloat, v: CGFloat, du: CGFloat, dv: CGFloat) {
            let r: CGRect
            switch edge {
            case .top: r = CGRect(x: u, y: v, width: du, height: dv)
            case .leading: r = CGRect(x: v, y: u, width: dv, height: du)
            case .trailing: r = CGRect(x: B - v - dv, y: u, width: dv, height: du)
            }
            f[t] = CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
        }
        /// 沿折痕排一排：fixed 里给了长度的照给，剩下的平分给其余的
        func row(_ items: [PlayerTile], v: CGFloat, dv: CGFloat, fixed: [PlayerTile: CGFloat] = [:]) {
            guard !items.isEmpty else { return }
            let gaps = g * CGFloat(items.count - 1)
            let fixedSum = items.compactMap { fixed[$0] }.reduce(0, +)
            let flexible = items.filter { fixed[$0] == nil }.count
            let share = flexible > 0 ? max(0, (A - gaps - fixedSum) / CGFloat(flexible)) : 0
            var u: CGFloat = 0
            for t in items {
                let du = fixed[t] ?? share
                put(t, u: u, v: v, du: du, dv: dv)
                u += du + g
            }
        }

        var v: CGFloat = 0
        // ① 关闭 | 信息卡 | 画中画 | 锁定：三颗小块（桌面时各占行宽的 16%；书本时近似正方形），信息卡占剩下的
        let unit = columns ? min(header, ((A - g * 3) * 0.2)).rounded() : ((A - g * 3) * 0.162).rounded()
        row([.close, .title, .pip, .lock], v: v, dv: header, fixed: [.close: unit, .pip: unit, .lock: unit])
        v += header + g
        // ② 三块一样大
        row([.back, .play, .forward], v: v, dv: mid)
        v += mid + g
        // ③ 进度条一整块
        row([.timeline], v: v, dv: bar)
        v += bar + g
        // ④ 工具一样宽；整条（亮度 / 音量的滑杆）占满这一排
        row(tools, v: v, dv: bar)
        put(.tray, u: 0, v: v, du: A, dv: bar)
        frames = f
    }
}
