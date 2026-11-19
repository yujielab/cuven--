# 画面光影：Cuven 原生动态反射播放器

半折的 iPhone Duo 上，播放器分成上下两块：上面是画面，下面是控制面板（参照 Netflix 在半折时的样子）。
面板上每块卡片的「面」由 Metal 实时绘制，**画面里真实的光**会映在卡片上：火光是暖的，海面是冷的，
夜景只剩局部的灯，霓虹是几种分开的颜色；光从画面的哪个位置来，就照亮哪一边的卡片。
所有代码都是原生的：SwiftUI、AVFoundation、AVKit、Metal、MetalKit、Core Video、Core Motion、UIKit。
不用 WebView，也不用 Web 渲染。

## 工程结构

| 目标 | 语言模式 | 内容 |
| --- | --- | --- |
| `CuvenLighting`（框架，`ios/CuvenLighting/`） | **Swift 6**（严格并发检查） | 光影引擎与 Metal 着色器，不依赖 SwiftUI |
| `Cuven`（App） | Swift 5（原有代码不动） | 播放器界面、半折接入、光影实验室 |

App 原本有约 2.7 万行 Swift 5 代码，整体迁到 Swift 6 的风险太大。所以新引擎单独放进一个 Swift 6 框架：
渲染与 SwiftUI 无关，并发检查是完整的。App 通过 `import CuvenLighting` 使用它。

```
ios/CuvenLighting/
  Engine/
    LightingTypes.swift            公开的值类型（卡片、几何、设置、诊断、取样颜色）+ 与着色器同布局的结构体
    MetalShaderLibrary.swift       设备、命令队列、着色器库、全部管线（一次建好、逐个校验）、纹理池
    VideoFrameProcessor.swift      AVPlayerItemVideoOutput → CVPixelBuffer → CVMetalTextureCache 纹理（零拷贝）
    ColorAnalysisEngine.swift      光照图、分区统计、转场检测、时间平滑、模糊、光源追踪（全在 GPU）
    DynamicLightingEngine.swift    光照模型：每帧的 uniforms、¼ 分辨率辐照度投影
    SpatialResponseEngine.swift    折叠角度（模拟 / 铰链读数 / 版面默认）、Core Motion 姿态、平滑过渡
    ReflectiveSurfaceRenderer.swift 每块卡片的材质（实例化绘制）、按下 / 闲置动画
    SpecularHighlightRenderer.swift 高光（½ 分辨率、叠加）
    LightingCompositor.swift       最终合成（全分辨率、sRGB、抖动）
    MetalRenderer.swift            渲染循环（MTKView）、档位、生命周期、诊断
  Shaders/
    LightingShaderTypes.h          着色器与 Swift 共用的结构体（全是 16 字节向量）+ 几何函数
    VideoSampling.metal            视频帧 → 64×36 光照图
    LuminanceAnalysis.metal        分区统计 / 转场检测；四个光源的挑选与追踪
    ColorExtraction.metal          时间平滑；可分离高斯模糊
    ReflectionProjection.metal     辐照度投影；卡片材质（漫反射、菲涅耳镜面反射、边缘光）
    SpecularHighlight.metal        归一化 Blinn–Phong 高光
    FinalCompositor.metal          合成、sRGB 编码、抖动
ios/Cuven/UI/Player/
  CuvenPlayerView.swift            画面 + 面板，三种摆法（半折 / 竖拿 / 横拿），AVPlayerLayer + 画中画，铰链读数
  PlayerControlPanel.swift         四行卡片；LightingHost（SwiftUI ↔ 渲染器）；卡片位置 / 按下状态上报
  PlayerToolbar.swift              第一行、第四行、亮度 / 音量滑杆、截取画面的分享
  PlaybackTimeline.swift           红色进度条、可拖圆点、当前时间 / 总时长
  PlayerViewModel.swift            CuvenPlayerViewModel（MVVM）
  PlayerLab.swift                  光影实验室
  TestPatternVideo.swift           测试画面（火光、海面、夜色、霓虹）的合成与编码
ios/Cuven/UI/PlayerTabletop.swift  折痕检测、挂进系统播放器
```

## 界面（照参照图）

四行深灰圆角卡片，块间距 8 点，圆角 19。行高按参照图的比例 77 : 142 : 51 : 51 分配。

1. 关闭 | 剧集信息卡（这一集的小画面 + 片名 + 第几集；参照图里那家的字标不用）| 画中画 | 锁定
2. 后退 10 秒 | 播放 / 暂停 | 前进 10 秒
3. 红色进度条 + 可拖的圆点 + 「当前时间 / 总时长」
4. 截取画面 | 播放速度 | 亮度 | 音量 | 音频与字幕 | 下一集（剧集后面还有才有）| 全屏（半折时才有）

- **底色与符号**：纯黑底，SF Symbols 由 SwiftUI 画在 Metal 卡面之上，所以符号始终清晰。
- **按下**：符号和卡面一起缩到 0.97；卡面的弹簧动画由渲染器跑，和 SwiftUI 同步。
- **闲置 5 秒**（播放中、没锁、没在拖、没展开滑杆）：符号 0.3 秒淡出，卡面只暗到 72%，画面映在卡上的光一直在。碰一下面板就回来，这一下不会误触按钮。
- **锁定**：锁那一块亮起来（白底黑锁），别的块变暗、点不动。
- **截取画面**：取这一帧的原始分辨率画面，交给系统分享面板（存到照片、隔空投送……）。
- **画中画**：用面板自己的画面层；半折时播放器收起回到 App，「还原」再弹回来。
- **全屏**：只管这一次半折，切回系统播放器。

摆法：

| 摆法 | 什么时候 | 画面 | 面板 | 默认折叠角度 |
| --- | --- | --- | --- | --- |
| `folded` | 半折（`reservedRegions(kind: .division)` 里生效、横着的折痕） | 折痕以上 | 折痕以下 | 105°，有铰链读数就用读数 |
| `stacked` | 实验室，竖着的屏 | 上（16:9） | 下 | 180°（摊平） |
| `sideBySide` | 实验室，横着的屏 | 左 58% | 右 | 180° |

其余情况（摊平、合上、横拿半折、普通 iPhone）照旧用系统播放器（`AVPlayerViewController`）。

## 渲染管线

```
AVPlayer ──► AVPlayerLayer（画面本身：硬件解码、HDR、画中画，全是系统的）
   │
   └─► AVPlayerItemVideoOutput（256×144 BGRA、IOSurface、Metal 兼容）
          │ CVMetalTextureCache（零拷贝，没有 CPU 读）
          ▼
  ① cuven_sampleVideo       → 光照图 64×36 RGBA16F（线性光，亮的地方权重最高 7 倍，保住局部光源）
  ② cuven_analyzeScene      → 16×9 分区颜色、整帧平均、峰值亮度、亮区覆盖、转场值（和上一帧比）
  ③ cuven_temporalBlend     → 平滑后的光照图（双缓冲；τ 平时 0.10 s，转场时 0.38 s）
  ④ cuven_gaussianBlur ×4   → near（σ≈1.5）、far（σ≈4.5）
  ⑤ cuven_selectLights      → 最多 4 个光源：位置、颜色、半径、亮度；跨帧匹配、淡入淡出
  ⑥ cuven_projectIrradiance → 面板 ¼ 分辨率的辐照度（画面折起来当面光源积分）
  ⑦ 卡片材质（全分辨率）    → 漫反射 + 菲涅耳镜面反射 + 边缘光 + 可读性上限
  ⑧ 高光（½ 分辨率，叠加）  → 4 个光源的 Blinn–Phong
  ⑨ 合成（全分辨率）        → 卡面 + 高光（5 点 tent 上采样）→ sRGB → 抖动 → 屏幕
```

①～⑥ 每 1/30 秒跑一次，前提是视频有新帧。⑦～⑨ 跟显示刷新率走（60 Hz），没有变化的帧整帧跳过。
全部编码在同一个命令缓冲里，GPU 按顺序执行，中间结果不回 CPU。
唯一的 CPU 读取是实验室的取样颜色：一个 2.3 KB 的共享缓冲，每秒最多读 4 次。

### 光照模型（`LightingShaderTypes.h`）

- **铰链空间**：x 沿铰链；y 从铰链指向面板（也就是朝着观看的人）；z 垂直于面板向上。面板是 z = 0 平面。画面那一半以折叠角 φ 从铰链立起来：φ = 180° 是摊平，90° 是竖直，像笔记本屏幕。
- **画面上一点**：距铰链 h，沿铰链 s，三维位置 Q = (s, h·cos φ, h·sin φ + spill)。spill（46 点）模拟屏幕边缘漏出来的光，让摊平的版面也有一点光。
- **屏幕正面法线**：n = (0, sin φ, −cos φ)。

- **漫反射**：把画面看成 32×18 个面光源。面板上每个 ¼ 分辨率的点 P 收到的辐照度是

  E = Σ L · (0.3 + 0.7·max(0, cos θs)) · max(0, cos θp) / (d² + 30²) · ΔA / π · 3.2

  其中 cos θs = n·(P−Q)/d，是屏幕向 P 发光的角度；cos θp = (Q.z − P.z)/d，是面板接收光的角度。距离按平方衰减，所以离铰链近的卡更亮，左边的光照亮左边的卡。多个光源、各自的颜色和位置都在同一个求和里，没有任何「平均颜色」。
- **镜面反射**：
  1. 视线 V 从眼睛到卡面上的点，按卡片法线 N 反射成 R。N 在中间是平的，靠边缘 9 点的倒角里向外翻，整面还带一点微拱。
  2. R 与折起来的屏幕平面求交，得到它「看到」画面的哪个位置，在那里取样光照图：距离越远越糊，从 near 过渡到 far。
  3. 乘上菲涅耳系数 F = 0.06 + 0.94·(1 − N·V)⁵、反射强度和卡片的光泽度。
  4. 交点落在画面外就渐隐。
  5. 摊平时射线碰不到屏幕，镜面反射自然消失。
- **高光**：对 ⑤ 找到的每个光源算归一化 Blinn–Phong：(n+8)/(8π)·(N·H)ⁿ。光源越小 n 越大：小灯是一个亮点，大片亮窗是一层宽光泽。再乘屏幕朝 P 的发光量和 1/(1 + d²/700²) 衰减。
- **边缘光**：卡片边缘内侧 2 点的一条细带，接收「漫反射 × 1.8 + 镜面 × 1.2」；朝向屏幕的那条边最亮。
- **可读性**：暗卡片受光后的亮度用软上限压在线性 0.12 以内，高光另压在 0.06 以内，合起来约等于 sRGB 0.46。白色符号对卡面的对比度因此至少 4.6 : 1（WCAG AA）。亮着的卡（锁定）不压。
- **眼睛位置**：面板正前方 520 点、高 620 点。Core Motion 测到的倾斜会把眼睛左右挪最多 260 点、前后 160 点、上下 220 点，反射和高光随设备转动在卡上移动。

### 时间与转场

- `cuven_analyzeScene` 在开方空间里比较每个分区和上一帧的颜色，这样两个暗场之间的切换也能测到。比较结果映射成 0～1 的转场值。
- 时间平滑的 τ = mix(0.10 s, 0.38 s, 转场值)：同一个镜头里光跟得紧（火光会闪），换镜头时用约 0.4 秒交叉淡化，不会一下跳过去。
- 光源每个槽位跨帧匹配到最近的新光源，以 τ = 0.25 s 靠过去；没匹配上的淡出，新出现的淡入。
- 换片源（下一集、换本机视频、循环）时整个分析清零，新片源的光从黑里淡入。
- 光影开关是约 0.4 秒的交叉淡化。按下用 τ = 0.06 s 的弹簧，闲置变暗用 τ = 0.15 s。折叠角是约 0.3 秒的临界阻尼弹簧，姿态倾斜用 τ = 0.18 s。

## 与 AVPlayer 的接入

- 画面由 `AVPlayerLayer` 画，光影另外从同一个 `AVPlayer` 取帧，两者互不影响。
- **取帧**（`VideoFrameProcessor`）：每个 `AVPlayerItem` 挂一个 `AVPlayerItemVideoOutput`。每个渲染帧检查 `player.currentItem` 换没换，所以换集、循环、换片源都会自动重新挂。
- **只取需要的帧**：每次只在 `hasNewPixelBuffer(forItemTime:)` 为真时取一帧。暂停、缓冲时什么都不取，卡上留着最后的光。
- **帧尺寸**：解码器的缩放器直接给出 256×144 的帧，没有全分辨率的 CPU 拷贝。`CVMetalTexture` 一直保留到读它的命令缓冲完成为止。
- **几何**：画面按 `presentationSize` 等比放进画面区（`AVMakeRect`），黑边不发光。
- **截取画面**：临时挂一个不缩放的输出取一帧（暂停时原地精确 seek 一下逼出一帧），用完马上拿掉。
- **半折播放器**：系统播放器（`AVPlayerViewController`）照常放；半折时上面盖一层 SwiftUI，关掉系统控件，换成这里的面板。
  - 进度、音轨与字幕的首选项、自动下一集、流量统计，仍由 `PlayerCoordinator` 管。
  - 面板的画中画走 `PlayerCoordinator.panelPictureInPicture*`。

## 性能

| 项目 | 做法 |
| --- | --- |
| 界面 | 60 fps；SwiftUI 不按帧刷新。卡片位置只在排版变了时上报，诊断每秒 2 次，取样颜色每秒最多 4 次 |
| 光影更新 | 30 次/秒（热或低电量模式 15 次，过热冻结在最后一帧） |
| 分辨率 | 分析 64×36；辐照度为面板的 ¼；高光 ½；只有卡片材质和合成是全分辨率 |
| CPU↔GPU 同步 | 最多 3 帧在途；GPU 跟不上就跳过这一帧，不在主线程等 |
| 资源复用 | 管线一次建好；纹理池按尺寸 / 格式 / 用途复用；uniforms 与卡片走 `setBytes`；每帧不分配 Metal 资源 |
| 帧跳过 | 没有新视频帧、没有动画、姿态没变时整帧不画 |
| 档位 | `thermalState` 与低电量模式每秒检查一次：high（30 次 / 60 fps / 32×18）→ reduced（15 / 30 / 16×9）→ minimal（冻结 / 30） |
| 生命周期 | 进后台立即停（后台不允许跑 GPU），清掉纹理缓存和空闲纹理，停 Core Motion；回前台恢复；内存警告时清缓存 |
| 诊断 | 实验室显示画面帧率、光影更新率、GPU 时间（`gpuStartTime` / `gpuEndTime`）、CPU 编码时间、档位、热状态、纹理占用、进程内存（`phys_footprint`）、跳过的帧、折叠角度 |

纹理占用：光照图 6 张 64×36 RGBA16F，约 110 KB；辐照度约 170×90 RGBA16F，约 120 KB；全分辨率卡面 + ½ 高光 RGBA16F，669×350 点 @3× 时约 17 MB。

## 设备限制

- **折痕位置**：用 iOS 27.1 的 `GeometryProxy.reservedRegions(kind: .division)`，更早的系统不会进入半折版面。
- **铰链角度**：用 iOS 27.1 SwiftUI 的 `onHingeChange`（`DeviceHinge.angle`），只在系统报告铰链的设备上才有。
  - 引擎**不假设**任何设备都能读到铰链角度：`SpatialResponseEngine` 的折叠角来源依次是模拟值、`updateHardwareFold(_:)` 喂进来的读数、版面默认值。
  - 实验室可以开「模拟铰链角度」。
- **模拟器**：折不了，铰链没有读数，Core Motion 没有数据，空间响应在模拟器里不动。
  - UI 测试用 `-CuvenTabletop YES` 弹一个折痕固定在正中的演示页。
  - 用 `-CuvenPlayerLab YES` 打开实验室放测试画面。
- **HDR / 杜比视界**：光影取的是 8 位 BGRA，系统已映射到 SDR。画面本身照常 HDR。
- **画中画**：面板按钮启动的是面板那一层画面的画中画。系统播放器那一层的画中画（例如退到后台时自动开始）照旧由系统处理。
- **没有 Metal、或着色器建不起来**：面板退回 SwiftUI 画的深灰卡片，功能不变。实验室的「性能」里会写出原因。
- **只用 BGRA 8 位**：10 位源会先被转成 8 位再分析，对光影足够。

## 构建与运行

工程由 XcodeGen 生成：

```sh
brew install xcodegen
cd ios && xcodegen generate && open Cuven.xcodeproj
```

- **构建**：选 `Cuven` scheme，用 Xcode 27.1 以上（iOS 27.1 SDK）构建。
  - `CuvenLighting` 是 App 的依赖，会一起编译并嵌入 `Cuven.app/Frameworks/`。
  - 它的着色器编进框架自己的 `default.metallib`，运行时用 `makeDefaultLibrary(bundle:)` 加载。
- **着色器校验**：编译期由 Metal 编译器检查。运行时 `MetalShaderLibrary` 一开始就建好全部 9 条管线，有失败会记日志（`us.cuven.tv` / `lighting`），实验室里也会显示。
- **CI**：
  - `ios.yml` 编 Release IPA，并把 IPA 推到 `refs/ci/ios-ipa/<分支>`。
  - `ios-preview.yml` 在 iPhone Duo 与 iPad mini 模拟器上跑 UI 测试。实验室的截图是 `duo-39*` / `duo-49*`：测试画面四段各一张，外加一张横屏。
- **在手机上看**：
  - 半折播放：在 iPhone Duo 上放任意一部片子，展开竖拿再半折立起来。
  - 光影实验室：账户与设置 → 播放 → 光影实验室。选相册或文件里的视频，或者放「测试画面」，里面的「火光 / 海面 / 夜色 / 霓虹」可以直接跳到对应场景。
  - 关掉光影：账户与设置 → 播放 →「画面光影」。
