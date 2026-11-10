# cuven Stream —— Dropbox 视频代理（Cloudflare Worker）

`Stream_v25.js` 是主 Worker（单文件，部署方式与之前完全相同）。v25 起，Safari / iOS 上的
MKV 不再交给浏览器硬解，而是在 Worker 里**实时重封装成 fMP4 HLS**，由系统原生播放器播放，
HDR10、HLG、杜比视界都能真正点亮，并且支持全屏、画中画、AirPlay，以及系统自带的音轨 / 字幕菜单。

| 路径 | 内容 |
| --- | --- |
| `Stream_v25.js` | 主 Worker：Dropbox 代理、`/stream` 直连、MKV → HLS、自带的首页与 `/watch` 播放页 |
| `web/index.html` | 前端（Stream · Cinematic Edition，单文件 SPA），站内播放器，不再依赖 Infuse |
| `audio-tx/` | 可选的 DTS / TrueHD → AC-3 转码 Worker |
| `tests/` | 回归测试：Worker（`run.mjs`）与前端（`web.mjs`） |

## MKV → HLS 链路

| 环节 | 做法 |
| --- | --- |
| 入口 | `/hls/<exp>.<sig>.<path>/master.m3u8`（签名写在路径里，与 `/stream` 同一枚 HMAC 签名） |
| 索引 | 读文件头 + Cues + 首簇（3~4 个小 Range），按文件 `content_hash` 缓存 |
| 分段 | 以视频关键帧为界（目标 6 秒，起播前两段 2s / 4s），每段只回源自己那段字节 |
| 回源 | 每段开头 1 MB 直通（压低首字节），其余按 4 MB 切片并行取（默认同时 3 片，`HLS_WINDOW` 可调） |
| 预取 | 播第 k 段时后台把第 k+1 段取好放进边缘缓存；拖动回看直接从缓存出 |
| 起播 | 主列表一到就开始取第 0 段；播放器取完二级列表、init 再来要第 0 段时，从头「跟上」那一路，不再回源第二次 |
| 视频 | 不转码，负载零拷贝直通；DTS 由 PTS 与 SPS 重排深度推出，跨分段连续 |
| 杜比视界 | P5 → `dvh1`+`dvcC`；P8.1 / 8.4 → `hvc1`+`dvvC`+`SUPPLEMENTAL-CODECS`（`db1p` / `db4h`）；**P7（UHD 蓝光双层）逐帧丢弃增强层并把 RPU 改写为 8.1** |
| HDR | 依 VUI / MKV Colour 写 `VIDEO-RANGE` 与 `colr` / `mdcv` / `clli` |
| 音频直通 | AAC、AC-3、E-AC-3（含 Atmos：`CHANNELS="16/JOC"`）、FLAC、ALAC。默认音轨复用在视频分段里，其余为备选音轨 |
| 音频转码（可选） | DTS、TrueHD、Opus、Vorbis、MP2/MP3、PCM → AC-3 5.1（640 kbps），需要 `audio-tx` Worker |
| 字幕 | 内封 SRT / ASS（含 zlib 压缩）、同目录外挂 `.srt/.ass/.vtt` → 分段 WebVTT（带 `X-TIMESTAMP-MAP`），中文（简体优先）默认开启。没有字幕 Cues 的文件：字幕块在转视频那一遍顺手收下，不再为字幕把整段视频重读一遍 |

播放页（`/watch`）、首页弹窗和前端站内播放器在 Apple 的原生播放器（macOS Safari，以及 iOS / iPadOS
上的所有浏览器）里打开 MKV 时自动走这条链路。徽章按码流实测显示（Dolby Vision / HDR10 / HLG）。
签名过期或文件被替换时，会换新签名并从原位置重载。
其它浏览器、MP4/MOV 文件仍走 `/stream` 直连（v24 的 FourCC 热修补照旧生效）。新版桌面 Chrome 虽然也
声称支持 HLS，但只要 `CODECS` 里有一个它解不了的编码（例如备选音轨的 `ac-3`）就整条拒播，
杜比视界、AC-3 / E-AC-3 它也解不了，所以不给它 HLS；它能直接播放 MKV。

调试用：`/hls/<token>/info.json` 返回识别结果（编码、HDR / 杜比、各音轨是否可播 / 是否转码）。

## 前端：播放页（`web/index.html`）

以前点「播放」是用 `infuse://` 把直链交给 Infuse：没装 Infuse 什么也放不了，续播进度也记在 Infuse 里。
现在全部在页面里完成，详情页保持原样：

- **播放页是一张 iOS 式 sheet**：从底部升起、盖住全屏，顶上留一道缝透出变暗的背景，有抓手条。按住头部或画面往下一拉
  就收起（与详情页的下拉同一套弹簧：轻轻一甩也能关，拉到一半停住会弹回去）。返回手势、返回键、Esc、⌄ 都能收起。
  手机横过来是整屏沉浸。
- **控件全部自绘**：播放 / 暂停、±10 秒、可拖动的进度条（带缓冲进度）、双击左右快退快进、轻点显隐（播放中 3 秒自动收起）、
  隔空播放、画中画、全屏（iPhone 交给系统播放器，iPad 与电脑是整块全屏）。电脑上空格 / ← → / F / M 都能用。
- **下面是播放页信息**：片名、分集、按码流实测的标签（Dolby Vision / HDR10 / HLG / 4K / Dolby Atmos / 5.1）、剩余时间，
  音轨、字幕、画面（分辨率、杜比视界 profile、是否由 P7 转换）、「接下来」的分集，以及复制直链（交给 VLC、Infuse 等）。
- **片源**：Safari / iOS 上 MKV 走上面的 HLS 链路，MP4 / MOV 和其它浏览器走 `/stream` 直连。
- **字幕**：由播放页自己画（跟着画面走、不被控件压住，HLS 跨分段重复的 cue 只画一次）。直连时自动挂上同目录外挂字幕。
  选择会记住（包括「关闭」）；没选过就用片源标的默认或中文。进 iPhone 系统全屏时交给系统画。
- **起播**：打开详情页时就把签名和 HLS 索引（`info.json`）取好，点「播放」直接交给播放器。
- **优选入口**：Worker 配了 `EDGE_HOSTS` 时，页面会在空闲时实测各入口（`/api/edge/ping`），选最快的来放片，6 小时测一次；出错退回默认入口。
- **续播**：进度记在本地（`play_progress_v1`）：每 5 秒、暂停、收起、切到后台各记一次。再次打开从上次的位置继续，
  并提示「从 m:ss 继续播放 · 从头开始」；看完自动清掉。「继续观看」卡片上有进度条。
- **剧集**：片尾弹出「下一集」，8 秒后自动播放，可以取消；「接下来」里点哪集播哪集。
- **出错**：签名过期或网络中断时，换新签名从原位置重连（最多两次）。文件本身转不了 HLS（比如缺 Cues）时，直接显示原因。
- **iPhone Duo**：按 Safari 27.1 实测视口适配：折起竖拿 382×580、折起横拿 594×368、展开竖拿 669×825、展开横拿 951×543。
  - 问题：首页主视觉、资料库展厅、详情页剧照、欢迎页原来带着按竖屏手机定的最小高度。在矮屏上，片名、按钮、轮播点会落进底部导航条下面；
    折起横拿时，详情页的「播放」甚至掉到屏幕外。
  - 现在：矮屏下这些区块刚好一屏、停在导航条之上。展开横拿时播放页整屏沉浸；折叠、展开、横竖切换时视频不中断。
  - 这些都是只在矮屏（≤ 640）或矮横屏（≤ 600）下生效的 CSS 条件，其它设备不受影响。
  - Safari 的折叠 API（Device Posture / Viewport Segments）默认关闭，半折时 Safari 也会回到外屏，所以不依赖它们。
- **预告片**：资料库展厅第一章的预告片地址晚到（TMDB + IMDb 两跳）时，以前要滚走再滚回来才会播；详情页开过一会儿再关掉、
  从后台切回来时也一样停在剧照上。现在条件一凑齐就挂上开播。播放页升起时背景里的预告片、轮播一律让路，收起后接着放。

用到的后端接口：`/api/stream-sign`（v25 起多返回一个 `hls` 字段）、`/hls/<token>/info.json`、
`/hls/<token>/master.m3u8`、`/stream/<文件名>?path=`。后端还是旧版（没有 `/hls`）时，MKV 会退回直连。

上传的页面经过了「网页另存为」类工具，有 5 行脚本被改坏，整个主脚本因此无法运行；另有两段 Cloudflare 边缘注入的
验证脚本被一起存了下来。仓库里是修好的版本（见提交记录）。

## 部署

主 Worker 照旧部署 `Stream_v25.js` 即可，不需要新的绑定。可选环境变量：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `HLS_DISABLE` | — | 设为 `1` 关闭 HLS，MKV 回到 v24 的直连方式 |
| `HLS_SEG_SEC` | `6` | 分段目标时长（2~10 秒） |
| `HLS_DV_MODE` | `auto` | `auto`：按 Apple 规范；`dvh1`：P8 改用 `dvh1` 样本入口；`off`：不发杜比信令（按 HDR10 播放，P5 除外）。主列表加 `?dv=` 可临时覆盖，方便在真机上对比 |
| `HLS_WINDOW` | `3` | 每段并行回源的切片数（1~5；加上开头直通那一路，每次调用最多 6 条连接）。高码率片源卡顿时可调大 |
| `HLS_PREFETCH` | `1` | 播第 k 段时预取后面几段进边缘缓存（0~3）。`0` 关闭预取、起播跟车与字幕借道，回到逐段现取 |

建议使用 **Workers 付费计划**：一个 4K remux 分段大约消耗 20~40ms CPU，免费计划每次请求只有 10ms 上限。

### 可选：DTS / TrueHD 转码 Worker（`audio-tx/`）

Workers 不允许运行时编译 WASM，所以转码器是一个单独的小 Worker（精简的 FFmpeg 6.1.1：DTS、TrueHD、MLP、
Opus、Vorbis、MP2/MP3、PCM 解码器 + AC-3 编码器 + libswresample，编成 1 MB 的 WASM，已编好放在仓库里）。

```bash
cd audio-tx
npx wrangler deploy
```

然后在主 Worker 的 `wrangler.toml` 里加：

```toml
[[services]]
binding = "AUDIO_TX"
service = "cuven-audio-tx"
```

绑定后，这些音轨会以「DTS → Dolby Digital 5.1」之类的名字出现在音轨菜单里。如果片源只有 DTS / TrueHD，
转码轨就是默认音轨。转码轨的分段落在全局 AC-3 帧网格上，跨分段时先预热、并越过分段边界多读一点，
所以接缝处不会出爆音。转好的分段会进边缘缓存，拖动回看时不必重新转码。
不绑定时，这些音轨不进播放列表，播放页会给出提示。

从源码重建 WASM：`audio-tx/build.sh`（需要 emscripten 与 FFmpeg 6.1.1 源码）。

## 限制

- 需要 MKV 的 Cues 关键帧索引（mkvmerge、MakeMKV、ffmpeg 产出的文件都有）。没有索引的文件返回 422，播放页自动回退直连。
- 不做自适应码率：始终是原始码率，4K remux 需要相应的网络带宽。
- 图形字幕（PGS / VobSub）无法转成 WebVTT，不会列出。
- 双轨式杜比视界（BL 与 EL 分在两条 MKV 轨道）按 HDR10 播放。单轨 P7（MakeMKV / mkvmerge 默认）会被正确转为 8.1。
- TrueHD Atmos 转码后是 5.1 声道床（没有开源的 Atmos 编码器）。E-AC-3 Atmos（WEB-DL）是直通的，Atmos 完整保留。

## 测试

```bash
tests/make-samples.sh     # 用 ffmpeg / mkvmerge 生成样片（约 30 秒）
node tests/run.mjs        # Worker：37 项回归，约 15 秒
node tests/web.mjs        # 前端：50 项，需要 Playwright + Chromium（PLAYWRIGHT_PATH 可指定其 index.js），约 2 分钟
```

测试台直接运行 `Stream_v25.js` 的真实代码，并模拟 Dropbox（OAuth、临时链接、目录列表、带 Range 的下载）和 Cache API。
`audio-tx/tx.wasm` 存在时，会把转码 Worker 当作 Service Binding 挂上一起测。

`web.mjs` 在 Chromium（桌面与 iPhone 模拟）里打开 `web/index.html`，所有发往 `stream.cuven.online`（以及测试用的第二入口）
的请求都交给本地运行的同一个 Worker。它检查这些行为：
- **播放页**：sheet 升起与历史栈、控件自动收起、±10 秒、拖进度条、暂停记进度、返回键 / Esc / 下拉收起并释放视频、
  拉一下没过界会弹回、再次打开续播；
- **字幕**：外挂字幕自动选中中文、重复 cue 只画一次、切换与关闭并记住；
- **剧集**：「接下来」与片尾接下一集；
- **片源**：Chrome 上 MKV 走直连，模拟 Safari 时打开详情页就预热 `info.json`、MKV 走 HLS、标签显示杜比视界；
- **iPhone Duo**：四种实测视口下主视觉不压导航条、没有横向溢出；折起横拿时欢迎页与详情页的关键按钮在第一屏；
  展开横拿时播放页整屏沉浸，折叠 / 展开 / 横过来视频不中断；
- **其它**：展厅预告片自动开播、给播放页与详情页让路后接着放，优选入口实测与放片，Worker 自带 `/watch` 页的同样判定。

## 已验证（本地测试台：真实 Worker 代码 + 模拟 Dropbox）

- **视频直通**：HEVC 10bit HDR10（开放 GOP + B 帧金字塔）、H.264（B 帧金字塔）的每个包都与源 MKV 逐字节一致；DTS 单调且不大于 PTS，跨分段连续。
- **音频直通**：E-AC-3 / AC-3 / AAC / FLAC 逐包一致，时间轴吸附到精确的采样网格。
- **杜比视界**：P5、P8.1、P7 FEL 三种样片的信令都正确。P7 的增强层全部丢弃，RPU 全部转为 profile 8。RPU 改写逐字节对照了 dovi_tool 的测试向量：MEL/FEL→8.1 与参考输出完全一致，705 个 RPU 往返中有 704 个一致；剩下那个是测试素材本身缺少防竞争字节。
- **兼容性**：ffmpeg 作为 HLS 客户端完整解码所有渲染，帧 MD5 与源一致；Chromium MSE 接受输出的 fMP4，缓冲区连续，可播放、可跳转。
- **转码**：DTS / TrueHD / Opus → AC-3 与参考解码逐采样对齐（偏移 0），信噪比约 77 dB；分段接缝处的误差最多是中位误差的 1.3 倍（无爆音）。
- **字幕**：内封 SRT / ASS（含 zlib）、字幕没有 Cues 时的扫描兜底、外挂字幕都正确。乱序请求分段与顺序请求的输出逐字节一致。
- **管线**：并行窗口 1 / 3 / 5 的输出逐字节一致。起播第 0 段：在半路跟上后台那一路，或两个请求同时要，都逐字节正确，且只回源一遍。
  第 k+1 段从边缘缓存出、不再回源。没有字幕 Cues 的文件，字幕分段直接用视频那一遍写好的 VTT，与扫描结果逐字一致。

> 没有在 iPhone 真机上测试。上线后建议用一两部片子在 iPhone 上确认。如果 P8 片源没有点亮杜比视界，
> 可以在主列表 URL 上加 `?dv=dvh1` 对比一下。
