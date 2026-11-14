import UIKit
import AVKit   // CuvenPlayerViewController.Phase（系统播放器的子类里）

// MARK: - 播放加载画面：照 Apple 的做法（HIG › Playing video › Loading content；docs/hig/components.md C90）
//
// 点「播放」到真正开播之间，盖在系统播放器的画面层上（contentOverlayView：系统的关闭钮等控件在它上面，照常能点）。
// · 两秒内就开播：什么都不出，系统播放器本来就是黑底（C90）。
// · 过了两秒还没开播：淡入黑底，正中一个系统转圈（UIActivityIndicatorView，和 SwiftUI 的 ProgressView() 同一个样子），
//   下面一行片名（subheadline、次要色）——告诉人在等哪一部，不写「正在加载」这类空话（C69）。
// · 不放动画背景、字标、轮播文案，也不画分段爬升的进度条：不知道还要多久，就不假装知道（C68、C69、C90）。
// · 开播那一刻就收起（0.2 秒淡出）。淡入淡出只动透明度，「减弱动态效果」开着也合适（F60）。

final class PlayerLoadingCover: UIView {
    /// 等这么久还没开播才出加载画面（C90：两秒）
    private static let delayNanos: UInt64 = 2_000_000_000

    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    /// 两秒的计时：开播就取消
    private var pending: Task<Void, Never>?
    /// 正在等开播（preparing / buffering 以后、playing 以前）
    private var waiting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        isUserInteractionEnabled = false
        isHidden = true
        alpha = 0

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])

        // 读屏：整块一个元素，「正在载入：片名」
        isAccessibilityElement = true
        accessibilityLabel = "正在载入"
        accessibilityIdentifier = "player-loading"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 片名：转圈下面那一行，也给读屏用。剧照不用（C90：黑底，不放别的内容）
    func configure(title: String, artwork: URL?) {
        titleLabel.text = title
        accessibilityLabel = title.isEmpty ? "正在载入" : "正在载入：" + title
    }

    /// preparing / buffering：开始等（两秒后还在等才出现）；playing：马上收起
    func setPhase(_ phase: CuvenPlayerViewController.Phase) {
        switch phase {
        case .preparing, .buffering:
            arm()
        case .playing:
            finish()
        }
    }

    // MARK: 等 / 出现 / 收起

    /// 开始等开播。已经在等（buffering 紧跟着 preparing）就接着原来的计时，不重新算两秒
    private func arm() {
        guard !waiting else { return }
        waiting = true
        pending?.cancel()
        let delay = Self.delayNanos
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.reveal()
        }
    }

    private func reveal() {
        guard waiting else { return }
        isHidden = false
        spinner.startAnimating()
        UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.alpha = 1
        }
    }

    /// 开播：马上收起；两秒没到的，就一直不出现
    private func finish() {
        waiting = false
        pending?.cancel()
        pending = nil
        guard !isHidden else { return }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
            self.alpha = 0
        } completion: { [weak self] _ in
            // 淡出途中又开始等下一集（自动接下一集）：留着，等它自己的两秒
            guard let self, !self.waiting else { return }
            self.isHidden = true
            self.spinner.stopAnimating()
        }
    }
}
