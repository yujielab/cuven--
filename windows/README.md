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

## 界面：布局照网页版，材质是磨砂玻璃

先是「UI 和布局尽可能和 Mac 原生软件靠近」「Windows 版本使用磨砂玻璃」，最后定为「布局和 UI 尽可能接近网页版」（tv.cuven.us）。
布局、文案照 `web/index.html`，材质是磨砂玻璃，窗口按钮是 Mac 的红黄绿（`src/Cuven.App/UI/Mac.cs`、`WebParts.cs`）：

- **窗口**：不要 Windows 的标题栏和右上角三个按钮，左上角是红黄绿（关闭 / 最小化 / 全屏，鼠标移上去才显出符号，窗口不在前台时变灰）；
  顶上那一条空白处拖动窗口、双击最大化（`InputNonClientPointerSource` 的标题栏区域，按钮让出来）。底是纯黑（和网页版一样）。
- **底部导航**（网页版的 dock，`Shell.cs` 的 `Dock`）：底下正中浮着一条磨砂玻璃胶囊——头像（账户与设置）、主页、资料库、请求、下载，
  选中那一格变蓝、底下一块玻璃弹簧滑过去；右边隔开一颗磨砂搜索圆钮。**搜索**时和网页版一样变形：标签那一条收成只包住头像的圆钮，
  让出的宽度全给搜索框（两边同一条弹簧，总宽不变），放大镜淡出、「取消」胶囊弹进来；Esc 取消、Enter 记进「最近搜索」。
  进了详情等下一层，左上角红黄绿旁边一颗磨砂圆钮返回。
- **主页**：整屏大图轮播，正中「年份 · 电影」胶囊、字标、「Cuven TV 严选影片」、白色「播放」+ 磨砂圆钮，底下暂停钮和翻页点（当前那一点里一条白的走 9 秒）；
  「今日推荐」前十（空心大数字 + 海报）、「最新加入」16:9 卡（「N 天前」）、「剧集」竖大卡（字标 +「查看剧集 ›」）、继续观看、
  每一年一条磨砂年份栏（右边蓝色「查看电影和剧集 ›」）+ 那一年的海报、可请求添加。栏目标题是磨砂胶囊，横排鼠标移上去才出左右翻页钮。
- **资料库**：「资料库 / Cuven 为你提供严格品质的影片」，下面一部一大块往下排（`LibraryFeed.cs`，滚到哪一块才建、才取全量资料）：
  整幅剧照（中间「年份 · 类型 · 时长」+ 字标）、简介、评分胶囊、导演 / 主演、「播放」「影片详情」、剧照一排。
- **详情**：整幅剧照铺满一屏，正中字标、「导演 · 主演」、8 分以上「Cuven 品质保证」、白色「立即播放」+ 磨砂圆钮（从头播放、下载、版本 / 选季）、简介；
  演员阵容（圆头像，「共 N 位 · 查看全部」）、剧照（竖的大卡「第 N 幕」）、剧集的分集；影片信息（类型 / 格式 / 评分）、
  尖端色彩和画面质量技术、语言、最底下版权一行——文案和网页版一字不差。
- **搜索页**：没输字时「最近搜索」胶囊（可删、可清除全部）和「最近添加」；输了字「“片名” · N 个结果」，剧集竖大卡在上、电影海报网格在下，
  再下面是片库里没有、可以请求添加的；没找到时「未找到「片名」相关结果」。
- **磨砂玻璃**（`Glass`）：Windows 自己的亚克力——强模糊、噪点颗粒、烟灰的底、一根发丝边，不做液态玻璃的高光和折射。
  底部导航、栏目胶囊、圆钮、播放控制条、设置卡、请求 / 下载的每一行都是磨砂的。
- **按钮**：主按钮是白底黑字的胶囊，次要的是磨砂圆钮；悬停放大、按下缩一下、松开回弹（Composition 的弹簧动画）；页面切换淡入 + 往上弹 10 像素。
- **播放器**：QuickTime / Apple TV 那样浮在画面下方的一条磨砂玻璃（音量、⏪ ▶ ⏩、下一集、字幕、音轨、全屏；白色进度条，右边是剩余时间），
  左上角磨砂圆钮返回 + 片名；三秒不动连红黄绿一起淡掉。
- **登录**：浅色底上的蓝色粒子云（光学配对）；账户密码在一张浅色磨砂卡上，登录是蓝色胶囊。
- **快捷键**：Ctrl+F 搜索、Ctrl+[ / ] 后退 / 前进、Ctrl+1…4 主页 / 资料库 / 请求 / 下载、Ctrl+, 账户与设置；
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
