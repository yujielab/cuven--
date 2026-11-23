# Cuven for Windows

Windows 10 / 11（x64）上的原生 Cuven：WinUI 3 界面 + 自研的播放管线，直连和 iOS / 网页同一套后端
（片库 `stream.cuven.online`、账号中心 `check.cuven.us`、请求添加 `tj.cuven.us`）。

| 目录 | 内容 |
| --- | --- |
| `native/` | **CuvenCore.dll**（C++20）：共享的 D3D11 设备、SwapChainPanel 用的交换链、配对粒子云、播放器。C 接口见 `native/include/cuven_core.h` |
| `src/Cuven.Core/` | .NET 10 的跨平台核心：后端接口、口令 v3、光学配对的码、片库、下载、请求进度。Linux 上也能编、能测 |
| `src/Cuven.App/` | WinUI 3 程序（**不用 XAML**，界面全用 C# 搭）：登录、首页、电影 / 剧集、搜索、详情、播放、请求、下载、账户 |
| `tests/Cuven.Core.Tests/` | 核心的测试（`dotnet run`；`CUVEN_LIVE=1` 时再打一遍线上接口） |
| `tools/LinuxCheck/` | 在 Linux 上对着 Windows App SDK 编一遍 App 的 C#（查类型错误；真正的构建在 Windows 上） |
| `installer/Cuven.iss` | Inno Setup 安装程序（装在当前用户下，不要管理员） |

## 安装

- **安装程序**：`Cuven-Setup-x64.exe`，装到 `%LOCALAPPDATA%\Programs\Cuven`，开始菜单里有 Cuven；
- **免安装**：解压 `Cuven-Windows-x64.zip`，直接运行 `Cuven.exe`（自带 .NET 10 和 Windows App SDK 运行库，不用另装）。

没有代码签名：第一次运行时 SmartScreen 会拦，点「更多信息 → 仍要运行」。片库缓存、设置、下载在 `%LOCALAPPDATA%\Cuven`
（设备令牌用 DPAPI 加密，只有这个 Windows 账户能解开），日志在它下面的 `logs\`。

`main` 上的构建发布在 Release「windows-latest」；每次 CI 的包另外提交到 `refs/ci/windows/<分支>`：
`git fetch origin refs/ci/windows/<分支> && git checkout FETCH_HEAD -- .`（大于 95 MB 的切成 `.partN`，`cat` 起来就是原文件）。

## 界面：照 Mac 原生软件的样子

用户要求「UI 和布局尽可能和 Mac 原生软件靠近，在 Windows 上做磨砂玻璃、液态玻璃和类似 MacBook 软件的交互体验和动效」，之后定为「Windows 版本使用磨砂玻璃」（`src/Cuven.App/UI/Mac.cs`）：

- **窗口**：不要 Windows 的标题栏和右上角三个按钮，左上角是红黄绿（关闭 / 最小化 / 全屏，鼠标移上去才显出符号，窗口不在前台时变灰）；
  顶上那一条空白处拖动窗口、双击最大化（`InputNonClientPointerSource` 的标题栏区域，按钮让出来）。
- **磨砂玻璃**（用户要求「Windows 版本使用磨砂玻璃」，`Glass`）：Windows 自己的亚克力 —— 强模糊、噪点颗粒、烟灰（深色）/ 乳白（浅色）的底，
  一根细细的发丝边，不做液态玻璃那种高光和折射。侧边栏、顶上的后退 / 前进、按钮、播放控制条、设置卡、请求 / 下载的每一行都是磨砂的；
  侧边栏**浮在内容上**：首页 / 详情的大图、横着滑的海报都从它下面过去、被它磨砂；字和第一张卡从它右边开始（`Inset`），
  窗口窄了侧边栏自动收起，Ctrl+Alt+S 手动收起 / 展开。
- **窗口本身也是磨砂的**（`DesktopAcrylicBackdrop`：桌面在窗口后面被模糊）：电影 / 剧集 / 请求 / 下载 / 账户 / 搜索这些列表页的底是半透明的，
  磨砂透出来；首页、详情页是整幅大图，底是实色（大图和磨砂之间不留接缝）。窗口不在前台时系统自动换成实色（省电）。
- **侧边栏**：分组标题、选中那一格图标变蓝，底下那块玻璃**滑**过去（弹簧，路上竖着拉长一点再收回，像一滴水）；搜索框、底下的账户行。
- **按钮**：主按钮是白底黑字的胶囊（和 Apple TV App 一样），次要的是玻璃胶囊 / 玻璃圆钮；悬停放大、按下缩一下、松开回弹（Composition 的弹簧动画）；
  页面切换淡入 + 往上弹 10 像素。
- **播放器**：QuickTime / Apple TV 那样浮在画面下方的一条磨砂玻璃（音量、⏪ ▶ ⏩、下一集、字幕、音轨、全屏；白色进度条，右边是剩余时间），
  左上角玻璃圆钮返回 + 片名；三秒不动连红黄绿一起淡掉。
- **登录**：macOS 浅色窗口的底色；账户密码在一张浅色磨砂玻璃卡上，登录是蓝色胶囊。
- **快捷键**（Mac 的 ⌘ 换成 Ctrl）：Ctrl+F 搜索、Ctrl+[ / ] 后退 / 前进、Ctrl+1…5 切到各页、Ctrl+, 账户与设置、Ctrl+Alt+S 边栏；
  触控板两指往右滑 = 后退（往左 = 前进），鼠标侧键也行。

CI 的 App 自检两种截图都存：`<页>.png` 是从屏幕上截的（磨砂、阴影、粒子云都在），`<页>-xaml.png` 是 XAML 自己渲染的（截不到这些）。

## 登录

和网页、iOS 一样**先显示配对粒子云**：已登录 Cuven 的 iPhone 打开「账户 → 扫描登录其他设备」对准它，面容 ID 批准就登进来了
（`check.cuven.us/pair/open` → `/pair/wait` 长轮询；过期自动换一团）。下面「使用账户密码登录」：用户名 + 密码，
**口令 v3**——本机按账号中心给的 salt / 轮数算 PBKDF2-SHA256，只把结果交给 `/session` 核对，密码不离开这台电脑。

粒子云是 `web/pair.js` 那两段着色器的 D3D11 移植（点精灵 → 实例化四边形，`native/shaders/cloud.hlsl`），
粒子（xorshift）、密度校正图（`web/pair-density.png`）、码纹理（C# 按 `pairing/model/cpc1-spec.json` 算，测试里和网页版逐字节比对）全一样；
画在浅色底上、至少按 1.5 倍像素画，和网页版看起来一样，iPhone 解得出来。

## 播放管线（`native/`）

```
WinHTTP 分段读（96 MB 环形缓冲，往回留 8 MB；断线 / 5xx 从断处重连；跳转时掐掉旧请求）
  → FFmpeg 8.1 解封装（自定义 AVIO）
  → 视频：D3D11VA 硬解（显卡不支持这一路就软解）→ GPU 上拷进自己的纹理环（8 张）
  → 音频：解码 → swresample 到设备的声道 / 采样率 → WASAPI（事件驱动、MMCSS「Pro Audio」）
  → 渲染线程：按音频时钟挑帧（音频是主时钟，设备真放到哪一帧就是哪个时刻）→ HLSL 两遍 → 交换链
  → 字幕：内封的文字（ASS / SRT）和图形（PGS / VobSub）、外挂 / 在线字幕（WebVTT），Direct2D / DirectWrite 画进一张透明纹理
```

- **原文件直放**：不走 HLS 重封装，MKV / HEVC 10 位 / TrueHD / DTS-HD / PGS 都是 FFmpeg 自己解，音轨、字幕随便换；
  下载也是原文件（`Downloads/`，断点续传），离线照样放。
- **颜色**（`native/shaders/video.hlsl`）：YCbCr → RGB（601 / 709 / 2020，有限 / 完整范围，按位深归一，色度按左对齐取样）；
  PQ、HLG → 线性尼特；BT.2020 → BT.709；HDR 屏输出 scRGB（FP16，1.0 = 80 尼特，SDR 白跟着 Windows 的「SDR 内容亮度」）；
  SDR 屏用 **BT.2390** 色调映射（PQ 域、maxRGB 保色相）；**杜比视界 5**（IPTPQc2）按每帧的 RPU 做分段多项式 / MMR 重塑，
  再 IPT → LMS′ → PQ → LMS → BT.2020（和 libplacebo 同一套算法）；7 / 8 的底层兼容 HDR10，按 HDR10 放。
  放大用 Catmull-Rom（9 次双线性取样），8 位输出加有序抖动。
- **跳转**：精确到帧（从关键帧解到目标，前面的帧 / 采样丢掉）；跳的时候先停声音、清队列，第一帧马上上屏。
- **缓冲**：音频饿了 0.25 秒就进缓冲（时钟停住），排够 1.5 秒再走。

### Win11 能效

- 解码、渲染、出声线程 **HighQoS**（明确告诉调度器别节流），出声线程另加 MMCSS；下载线程 **EcoQoS**（排到能效核、降频）；
- 窗口最小化又没在播：整个进程进 **EcoQoS**（任务管理器里的「效率模式」）；
- 渲染线程用高精度可等待计时器等到下一帧该出来的时候，**暂停时不画、不 Present**；交换链是翻转模型 + 可等待对象（最多排 1 帧）；
- 配对云在 120 / 144 Hz 屏上隔一帧画一次；播放时阻止屏幕熄灭（`SetThreadExecutionState`），停了恢复。

### 播放器快捷键

空格 / K 播放暂停 · ← → 退进 10 秒 · ↑ ↓ 音量 · F 或双击 全屏 · Esc 退出全屏 / 关掉 · M 静音 · C 换字幕 · I 播放信息 · N 下一集

## 构建

在 Windows 上（Visual Studio 2022 的 C++ 工具、CMake、.NET 10 SDK）：

```
cmake -S windows/native -B build/native -A x64 -DFFMPEG_DIR=<FFmpeg 共享库（include/ lib/ bin/）>
cmake --build build/native --config Release
dotnet publish windows/src/Cuven.App/Cuven.App.csproj -c Release -r win-x64 -p:Platform=x64 -o out/Cuven
copy build\native\Release\CuvenCore.dll + FFmpeg 的 avcodec / avformat / avutil / swresample / swscale 到 out\Cuven
```

CI（`.github/workflows/windows.yml`，`windows/**` 有改动时推到 `main` / `claude/**` 就跑）：fxc 先把着色器编一遍 → MSVC 编原生核心 →
核心测试（含线上接口）→ **WARP 自检**（软件渲染、没有显卡和声卡也能跑）：画 48 帧配对粒子云（存 PNG，`pairing/py/eval.py` 能解）、
播一部合成的片子（播放、读回画面、精确跳转、暂停）、再播片库里一部 HDR10、一部杜比视界 5 的片头 → `dotnet publish` →
**App 自检**（`Cuven.exe --selftest <目录>`：依次打开各页截图）→ zip + 安装程序 → `refs/ci/windows/<分支>`。

在 Linux 上能做的：`dotnet run --project windows/tests/Cuven.Core.Tests`；`dotnet build windows/tools/LinuxCheck`（App 的 C# 类型检查）；
原生核心用 llvm-mingw 交叉编译（`-DCMAKE_TOOLCHAIN_FILE=<mingw 工具链>`）、着色器用 dxc 编一遍查语法。
