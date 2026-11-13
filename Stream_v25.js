/**
 * Dropbox Video Proxy — Cloudflare Worker (v25 · 2026-11-10)
 * ────────────────────────────────────────────────────────────────
 * v25 变更 —— 主题：MKV → HLS → iOS Safari 完整链路（HDR10 / HLG / 杜比视界）
 *
 *   ▸ /hls/<签名>/master.m3u8：MKV 在 Worker 里实时重封装为 fMP4 HLS，交给系统
 *     原生播放器（AVPlayer）——全屏、画中画、AirPlay、系统音轨 / 字幕菜单全部可用。
 *     不转码视频：负载零拷贝直通，一个 6 秒分段只回源它自己那段字节。
 *   ▸ 参数集：hvcC / avcC / av1C 齐全时原样用；参数集只在码流里（hev1 / avc3 风格）、没有
 *     CodecPrivate、帧是 Annex B 起始码时，从片头几帧里捞出 VPS / SPS / PPS（AV1 是序列头 OBU）
 *     重建配置盒、帧就地转成长度前缀 —— 苹果的 hvc1 / avc1 只认参数集齐全的配置盒。
 *   ▸ 杜比视界：P5 → dvh1 + dvcC；P8.1 / 8.4 → hvc1 + dvvC + SUPPLEMENTAL-CODECS
 *     （dvh1.08.LL/db1p | db4h，与 VIDEO-RANGE 交叉校验，遵循 Apple HLS 规范）；
 *     P7（UHD 蓝光双层 FEL/MEL）逐帧丢弃增强层、把 RPU 改写为 8.1
 *     （与 dovi_tool mode 2 逐位一致，已用其测试向量逐字节校验）。
 *     HDR10 / HLG 依 VUI 或 MKV Colour 信令，并写入 colr / mdcv / clli。
 *   ▸ 音频：AAC / AC-3 / E-AC-3（含 Atmos JOC，CHANNELS="16/JOC"）/ FLAC / ALAC 直通。
 *     默认音轨复用在视频分段里（Dropbox 只读一遍）；其余音轨是 HLS 备选音轨。
 *   ▸ DTS / TrueHD / Opus / Vorbis / MP2 / MP3 / PCM：接上 audio-tx 转码 Worker
 *     （Service Binding AUDIO_TX，或变量 AUDIO_TX_URL + 共享密钥 AUDIO_TX_KEY，见仓库 audio-tx/）
 *     后实时转为 AC-3（5.1 @ 640k），帧落在全局网格上、跨分段预热与越界多读，接缝无爆音；
 *     转好的分段进边缘缓存。没接时这些音轨不进播放列表，播放页会提示。
 *   ▸ 字幕：内封 SRT / ASS（含 zlib 压缩）靠 Cues 精确定位只读字幕块；同目录外挂
 *     .srt/.ass/.vtt 一并进 HLS 字幕组；全部为带 X-TIMESTAMP-MAP 的分段 WebVTT，
 *     中文字幕（简体优先）默认开启。图形字幕（PGS / VobSub）无法转换，不列出。
 *   ▸ 播放页 / 首页弹窗：Safari 打开 MKV 自动走 HLS，徽章按码流实测显示
 *     （Dolby Vision / HDR10 / HLG）；签名过期或文件被替换会换签名原位重载。
 *     v24 的 MSE「MKV 引擎」从未向 SourceBuffer 写入数据（且在 iPhone 上
 *     ManagedMediaSource 因 disableRemotePlayback=false 不会打开），已移除。
 *   ▸ 需要 Cues 关键帧索引（mkvmerge / MakeMKV / ffmpeg 产出的文件都有）；
 *     没有的文件回 422，播放页自动回退直连。
 *   ▸ 新环境变量：HLS_DISABLE=1（关闭）、HLS_SEG_SEC（分段目标时长，默认 6）、
 *     HLS_DV_MODE=auto|dvh1|off（杜比信令策略，主列表也可加 ?dv= 临时覆盖）。
 *   ▸ 管线：每段开头 1MB 直通、其余 4MB 切片并行回源（HLS_WINDOW，默认 3，1~5）；
 *     主列表一到先取第 0 段、第 k 段取完再取 k+1 段，都进边缘缓存（HLS_PREFETCH=0 关闭）。缓存只认完整写完的段：
 *     数据写在一次性的键下，写完才发指针，半截的永远读不到。没有字幕 Cues 的内封字幕在视频
 *     那一遍顺手收下、写成该段 VTT —— 开字幕不再把整段视频字节重读一遍。请求之间只读彼此的
 *     进度数字，不跨请求 await、不共享流；每个 isolate 同时只跑一路预取。
 *   ▸ 建议 Workers 付费计划：一个 4K remux 分段约 20~40ms CPU，免费计划的
 *     10ms 上限在高码率片源上可能不够。
 *
 * ────────────────────────────────────────────────────────────────
 * v24 变更 —— 主题：原生 Safari 杜比视界 / HDR、完整音轨与内/外挂字幕支持
 *
 *   ▸ MP4 / MOV / M4V 零拷贝流式 FourCC 热修补（?safari=1）：
 *     在 /stream 流式管道中通过滑动窗口识别 ISO-BMFF VisualSampleEntry，
 *     原地将 hev1 替换为 hvc1，将 dvhe 或内含 dvcC/dvvC 配置盒的流升级为 dvh1。
 *     字节长度与偏移 100% 不变，不影响 Range 与 Content-Length，直接点亮原生杜比视界与 HDR。
 *   ▸ Dropbox 同目录外挂字幕自动发现与实时转换（/api/subs · /api/subs/vtt）：
 *     自动匹配同目录 .srt / .ass / .ssa / .vtt 字幕，内置 UTF-8 / UTF-16 / GB18030(GBK)
 *     编码自愈与双语 ASS 时间轴合并，实时转换为 WebVTT 并挂载到 Safari 原生字幕轨。
 *   ▸ MKV 流式解复用 + fMP4 重封装 + DTS/TrueHD WASM 软解引擎：
 *     当播放 .mkv 或 Safari 原生 <video> 报 MEDIA_ERR_SRC_NOT_SUPPORTED (code 4) 时，
 *     自动启动流式解复用引擎，提取 HEVC / Dolby Vision (dvh1/hvc1) 视频流喂入
 *     ManagedMediaSource / MediaSource，按需调用 libav.js WASM 软解 DTS / TrueHD 音轨，
 *     并实时提取 MKV 内封 S_TEXT/UTF8 与 S_TEXT/ASS 字幕注入原生 VTTCue。
 *   ▸ 主目录页（/）与播放页（/watch）同步升级：
 *     主目录新增 Dolby Vision / HDR10+ / 4K / Atmos / TrueHD / DTS 规格徽章与内嵌弹窗播放器；
 *     顶栏新增音轨切换（♫）与字幕切换 / 本地字幕文件挂载（CC）菜单。
 *
 * ────────────────────────────────────────────────────────────────
 * v23 变更 —— 主题：首次起播稳定性
 *
 *   ▸ 首次 bytes=0- 不再误入 seek 并行突发：起播只保留一条可续传主链路
 *     （慢响应仍可对冲），避免首屏同时放大成 4~5 个 Dropbox Range 请求。
 *     只有 start > 0 的真实拖动才启用分片并发；拖动速度不受影响。
 *   ▸ 页面预热默认只获取并缓存临时链接，不再额外下载 bytes=0-0 与真正
 *     起播争抢连接；如确需 TLS 预热可显式设置 STREAM_PREWARM_RANGE=1。
 *   ▸ HEAD 现在遵守 Range / If-Range，返回准确的 206、Content-Range 与
 *     Content-Length，兼容起播前先做 Range HEAD 探测的播放器。
 *   ▸ 优选入口在真正挂给 video 前先做短 HEAD 自检；失效 Cookie、DNS 或路由
 *     会自动回退当前页面入口。当前 host 保留非标准端口，不再被 hostname 截掉。
 *   ▸ 测速延后到 playing 之后，避免首播尚未成功时探针抢带宽；恢复时先绑定
 *     监听器再 load，消除极快失败事件先于监听器注册的竞态。
 *
 * ────────────────────────────────────────────────────────────────
 * v22 变更 —— 主题：拖动后快速恢复、请求去重与失败熔断
 *
 *   ▸ 修正 seek 突发与对冲叠加导致的请求放大：后台分片不再逐片对冲，
 *     首片仍保留对冲以压低 TTFB，避免慢网时越过 Workers 的并发连接上限。
 *   ▸ STREAM_OPEN_MAX 改为整次 /stream 请求共享的硬预算；默认 36，给免费
 *     计划的 50 次子请求限制预留链接缓存、Dropbox API 与分片缓存额度。
 *   ▸ 用户再次拖动、客户端断开或流出错时，立即 Abort 全部旧分片与重连等待；
 *     旧 seek 不再后台跑完，更不会继续与新 seek 抢带宽。
 *   ▸ 429/5xx 对冲只接受真正成功的响应；一条路先回限流页时会等另一条，
 *     不再把可能成功的请求误杀。重试使用有限退避并显式返回 Retry-After。
 *   ▸ 206 的 Content-Length 由 Content-Range 精确计算，不再信任可能错误的
 *     上游长度；区间不一致直接失败，杜绝播放器等待永远不会到达的字节。
 *   ▸ 播放页增加受控错误恢复：保留播放位置、刷新过期签名、指数退避重载；
 *     有次数与稳定播放窗口限制，不会陷入无限 reload / 无限失败循环。
 *
 *   v22 默认值
 *     STREAM_RESUME_MAX   连续无进展续传 8 次（有进展仍会自动清零）
 *     STREAM_OPEN_MAX     整次请求最多 36 个上游下载 fetch（共享硬预算）
 *
 * ────────────────────────────────────────────────────────────────
 * v21 变更 —— 主题：播到一半卡死、无限转圈
 *
 *   这个毛病有两个成因，v20 之前两个都在，而且都不是偶发 —— 是必然。
 *
 *   ▸ 成因一：短 body（响应头承诺 N 字节，实际只给了 M 字节）
 *     v20 及以前，接力段与直通路径都是这么写的：
 *         const r = await reader.read();
 *         if (r.done) return c.close();          // ← 这里
 *     上游一旦提前断流（临时链接到期、Dropbox 抖动、限速、连接被回收），
 *     reader 就会「正常地」done。我们于是把响应正常关掉 —— 可 Content-Length
 *     里已经写死了 N。播放器拿到一个短了几 MB 的"完整"响应，只能一直等
 *     剩下的字节。等不到，就是无限转圈。
 *     ⚠︎ 更糟的是它没有任何报错：日志干净、状态码 206、看起来一切正常。
 *
 *   ▸ 成因二：上游静默（连接没断，但再也不吐字节）
 *     v18 立过一条规矩：body 传输期间绝不设超时，怕误伤长片。代价是
 *     一条僵死的连接会让 read() 永远挂着 —— 同样是无限转圈，而且更彻底，
 *     连"短 body"都算不上，什么都不会发生。
 *
 *   v21 的答案不是「加个超时把它掐掉」（那退回 v18 修过的截断问题），
 *   而是：把断点续传做进 body 里。
 *
 *   ★ 可续传读取器 resumableReader
 *     → 与 ReadableStreamDefaultReader 同接口（read / cancel），但它记着
 *       自己负责的绝对区间 [start,end] 与当前位置 pos。
 *     → 上游提前 done、报错、或静默超过 STREAM_STALL_MS → 不关闭、不报错，
 *       而是断开重连，发 Range: bytes=<pos>-<end> 从断点续上。
 *     → 遇 403/410 顺手换一条新的临时链接再续。
 *     → 契约只有一句：要么把 [start,end] 一个字节不少地交出去，要么抛错。
 *       它永远不会「读着读着就 done 了」。
 *
 *   ★ 静默看门狗只在「正在等字节」时武装
 *     → 播放器缓冲满了不来读时，我们根本不调用 read()，看门狗自然不计时。
 *       所以它不会误伤慢速连接，只打真正僵死的那种。
 *     → 顺带治好另一个老毛病：暂停十分钟再播 —— 空闲连接早被上游回收了，
 *       现在会自动重连续上，而不是转圈到天荒地老。
 *
 *   ★ 两个计数器，管两件不同的事
 *     → stuck：连续「几乎没跑动」的续传次数，上限 STREAM_RESUME_MAX（默认 30）。
 *       它判的是「原地打转」。一次续传只要推进了 256KB 就清零 ——
 *       一条每隔 1MB 断一次的破线路，该一路续到底，不该被判死刑。
 *     → opens：本次请求的总重连数，上限 STREAM_OPEN_MAX（默认 150）。
 *       它守的是 Workers 的子请求配额，跟线路好坏无关，所以永不清零。
 *     → 任一撞顶就 c.error() —— 让播放器干净地重试一次，
 *       好过端给它一个永远补不齐的响应。
 *
 *   ★ 三条路径全部接上：分片路径的直通首片、接力段，以及 v19 回落直通。
 *     v20 那条「首片短了要报错」的断言留着当安全带，正常情况下不该再触发。
 *
 *   新增环境变量
 *     STREAM_STALL_MS     上游静默多久算僵死，默认 20000；0 = 关闭看门狗
 *     STREAM_RESUME_MAX   连续无进展的最大续传次数，默认 30
 *     STREAM_OPEN_MAX     单次请求的重连总预算，默认 150（子请求配额护栏）
 *
 * ────────────────────────────────────────────────────────────────
 * v19 → v20 变更 —— 主题：拖动进度条之后的那几秒
 *
 *   先拆一下这几秒到底花在哪 —— 不拆清楚就只能瞎优化：
 *
 *     拖动后的等待 = ① 上游首字节  +  ② 播放器缓冲填满
 *
 *   ① 是 Dropbox 对「大文件 + 大偏移」的 Range 读取要多久才吐出第一个字节。
 *      v19 的对冲只削掉了它的长尾（偶发的三五秒），中位数那一下削不掉。
 *   ② 才是大头：播放器要攒够几秒钟的画面才肯继续放。10Mbps 的片子攒 5 秒
 *      就是 6MB —— 单条连接跑 3MB/s 的话，光这一步就 2 秒。
 *      而单条连接的速度不由我们决定，由 Dropbox 那一端决定。
 *
 *   所以 v20 做两件事：把 ① 尽量变成「本地取」，把 ② 从单车道改成多车道。
 *
 *   ★ ① Range 自己解析，不再整条透传
 *     → bytes=N- / bytes=N-M / bytes=-N 三种形式都解，越界直接本地回 416，
 *       不再为一个必然失败的请求先跑一趟 Dropbox。
 *     → 解析失败（多段、畸形）一律退回 v19 的原样透传，行为不变。
 *
 *   ★ ② 4MB 对齐分片 + 边缘缓存（内容寻址，键里带 content_hash）
 *     → 播放器在 seek 前后会连打好几个小 Range 探路（MKV 的 Cues/SeekHead、
 *       MP4 的 moov、关键帧对齐）。每个都要一次完整往返，几百毫秒×N。
 *     → 现在这些落在对齐分片上，命中边缘缓存就是几毫秒。
 *     → 更实用的一条：往回拖（重看刚才那几十秒）几乎必然命中缓存，
 *       因为那些分片就是刚才播过去时写进去的。
 *     → 内容寻址意味着同路径换了文件自动换键，不会串味。
 *
 *   ★ ③ 并行突发 + 单连接接力 —— 这条是对着 ② 的
 *     ⚠︎ 第一片必须直通、不能缓冲：缓冲的话首字节要等一整片下完
 *        （4MB @ 3MB/s = 1.3 秒），等于为了总吞吐把「拖完到出画面」
 *        这段亲手拖慢，方向就反了。现在是第一片直通 + 后面几片背景并行，
 *        任一时刻手上的字节都 ≥ v19 —— 严格更优，没有变慢的角落。
 *     → 拖动后的第一个 bytes=N- 请求，前 SEEK_BURST_MB（默认 16MB）
 *       拆成 4MB 分片，窗口 3 并发去取、按序拼进响应体；
 *       剩下的部分再挂一条普通连接直通到底。
 *     → 效果是「起播那一段跑多车道，之后回到单车道」：缓冲填满的时间被
 *       并发数除了一遍，而长片的稳态传输一如既往地简单可靠。
 *     ⚠︎ 为什么不整片都分片：Workers 的子请求有上限，30GB 拆到底是几千次，
 *        必然撞墙。突发窗口把子请求钉死在 5~6 次，与文件大小无关。
 *     ⚠︎ 内存：窗口 3 × 4MB = 12MB 在飞，远低于 128MB 上限。
 *
 *   ★ ④ 「先拿到第一片再返回响应」—— 这条是安全带
 *     → 分片路径在响应头发出之前就把第一片取到手。它不额外增加等待
 *       （那一片本来就要等），换来的是：分片路径出任何问题都能静默回落到
 *       v19 的直通路径。优化只可能更快，不可能把原本能播的搞成不能播。
 *     → 接力段中途遇到链接过期（403/410）会就地换一条新链接续上，
 *       长片播到第三小时不再从头挂掉。
 *
 *   新增环境变量（全部可选，不配即用默认值；SEEK_BURST_MB=0 整条路径关闭）
 *     SEEK_BURST_MB      拖动后并行预读多少 MB，默认 16，0 = 退回 v19 行为
 *     SEEK_CHUNK_MB      对齐分片粒度，默认 4
 *     SEEK_WINDOW        并发窗口，默认 3
 *     SEEK_CHUNK_CACHE   '0' 关闭分片边缘缓存（默认开）
 *
 * ────────────────────────────────────────────────────────────────
 * v18 → v19 变更 —— 主题：优选入口 与 上游对冲（起播 · 串流 · 稳定性）
 *
 *   先把最容易搞错的一句说在前面：
 *   ⚠︎ 「Cloudflare 优选 IP」本身是 DNS 层的事，写不进 worker.js。
 *      它的完整链路是 ——
 *        灰云 A 记录（或 CNAME 到优选域名） → Workers 路由 → 本 Worker
 *      配置在 DNS 商 + Cloudflare 面板那边，代码里做不了、也不该做。
 *      任何声称"在 worker.js 里填几个 IP 就优选了"的写法都是假的：
 *      客户端连的是谁，只由它解析到的那个 A 记录决定。
 *
 *   但优选这套东西有一半确实落在 Worker 侧，而且恰好是决定体感的那一半：
 *   入口不止一个时，谁来选、拿什么指标选、选完怎么真的用上。v19 补的是这半边。
 *
 *   ★ ① EDGE_HOSTS —— 承认「入口不止一个」
 *     → 环境变量填所有绑到本 Worker 的优选主机名（逗号分隔，可带非标端口）：
 *         EDGE_HOSTS = "s1.cuven.us,s2.cuven.us:2053,s3.cuven.us:8443"
 *       每个主机名在 DNS 侧各自指向一批优选 IP / 优选域名，互为备份。
 *     → 当前请求所在的 host 永远排第一位，没配 EDGE_HOSTS 时行为与 v18 完全一致。
 *
 *   ★ ② /api/edge 与 /api/edge/ping —— 让「优选生效了没有」变成可测量的数字
 *     → /api/edge 回 colo / country / asn / clientTcpRtt / httpProtocol。
 *       优选有没有真的换 PoP，看 colo；换了之后好不好，看 clientTcpRtt。
 *     → /api/edge/ping?b=<字节> 是一个可配大小的不可压缩负载源
 *       （CloudflareSpeedTest 的浏览器版）。客户端并发打各入口，
 *       按 TTFB + 实测带宽打分，选出对「这条网线、这个时段」最快的那个。
 *     ⚠︎ 优选入口是不同 hostname，Cookie 天然带不过去 → 探针复用 /stream 那套
 *        HMAC 签名（伪路径 __probe__），fail-closed 语义一字未改。
 *
 *   ★ ③ 选出来的入口真的被用上 —— 而且几乎零成本
 *     → 播放页跑完实测写 Cookie edge=<host>；下一次 /watch 直接把 <video src>
 *       与「外部播放器直链」渲染在赢家 host 上。
 *     → 这一步能成立，靠的是 v14 那次签名设计的意外红利：
 *       签名只覆盖 path，不含 host。同一个 AUTH_SECRET 下，一条直链在任意
 *       入口都有效 —— 换 host 不需要重新签名，Infuse 里存着的链接也不会失效。
 *     → 服务端只认 EDGE_HOSTS 白名单内的值，Cookie 被改也只能在自家入口里打转。
 *
 *   ★ ④ 上游对冲（hedged request）—— 起播长尾的正解，这是串流提速的大头
 *     → Dropbox 的 temp link 落在一组 uc*.dl.dropboxusercontent.com 实例上，
 *       偶尔会摊到一个响应头要三五秒的。起播「卡一下」绝大多数就是这一下。
 *     → 重试是"等它失败再来一发"，对冲是"它慢过 STREAM_HEDGE_MS 就再来一发，
 *       谁先回响应头用谁，落败那路连 body 一起 abort"。默认 400ms。
 *     ⚠︎ v18 那条不变量原样守住：对冲只可能发生在【响应头到达之前】。
 *        赢家的 body 一旦开始传输就不受任何超时/abort 约束 —— 长片 seek
 *        到哪都不会被截断。落败方的 body 从未被读，不占带宽也不计费。
 *     → 首发直接网络错误时不等 400ms，立刻补发第二路。
 *
 *   ★ ⑤ Accept-Encoding: identity —— 顺手拔掉的一个隐患
 *     → mkv/mp4 本就是压缩容器，让上游再协商一次 gzip 只白烧两边 CPU；
 *       更要紧的是压缩响应会让 Content-Length 与字节区间不再一一对应，
 *       Range 语义变脏。视频代理一律走裸字节。
 *
 *   ★ ⑥ 起播预热
 *     → /watch 页面渲染的同时 waitUntil 取 temp link 并向上游要 bytes=0-0：
 *       ① 把 Dropbox API 那次往返从起播关键路径上摘掉
 *       ② 让本 colo → Dropbox 的 TLS 连接进池，播放器真正 GET 时省一次握手
 *       失败/超时全吞，不影响页面返回。
 *
 *   ★ ⑦ Timing-Allow-Origin: *（/stream 与探针）
 *     → 少了它，跨入口的 Resource Timing 全被浏览器打成 0，实测就是瞎测。
 *
 * ────────────────────────────────────────────────────────────────
 * 部署侧清单（这部分不在代码里，但不做的话 ①②③ 等于白写）
 *
 *   1. 用 Workers 路由，不要用「添加自定义域」
 *      自定义域会由 Cloudflare 托管解析并强制写死 CNAME，改不动 →
 *      优选无从谈起。正确做法：DNS 处添加记录，然后在域名的
 *      Workers 路由里填 s1.example.com/*（末尾的 /* 不能少）指向本 Worker。
 *   2. 该记录必须是灰云（关闭代理）
 *      A 记录直接指向实测出来的优选 IP；或 CNAME 到社区优选域名
 *      （由对方持续扫描维护，IP 变了不用动自己的 DNS，省心得多）。
 *   3. 域名解析托管在 Cloudflare 时，上面这条往往改不了
 *      → 把 DNS 放到第三方（华为云国际版 / DNSPod 国际版等），
 *        还能顺带按线路分别解析：电信/联通/移动各给一组优选 IP。
 *   4. 端口
 *      443 被干扰时换 Cloudflare 支持的备用 HTTPS 端口（2053 / 2083 /
 *      2087 / 2096 / 8443），EDGE_HOSTS 里带上端口即可。
 *   5. 优选 IP 会过期
 *      今天最快的明天未必 —— 所以 ③ 的选择是「每次播放页现测」而不是
 *      写死在代码里，且只缓存 6 小时。
 *   6. Smart Placement（wrangler 里 placement.mode = "smart"）
 *      对"客户端很远、上游更远"的代理通常是净收益，但它与优选是两段独立的
 *      优化（优选管客户端→PoP，Placement 管 Worker 跑在哪）。开或不开都要
 *      拿 /api/edge 的 clientTcpRtt 与实际起播时间实测，别凭感觉。
 *
 * 新增环境变量（全部可选，不配即退回 v18 行为）
 *   EDGE_HOSTS        逗号分隔的优选入口主机名，可带端口
 *   STREAM_HEDGE_MS   上游对冲触发阈值，默认 400；填 0 关闭对冲
 *   EDGE_PROBE_BYTES  播放页实测的单入口负载大小，默认 262144（256KB）
 *
 * ────────────────────────────────────────────────────────────────
 * v17 → v18 变更 —— 主题：资料库「展映」的片源
 *
 *   ★ 新端点 GET /api/imdb/video
 *       ?id=tt0111161            —— 直接给 IMDb 编号（首选）
 *       ?query=肖申克的救赎&year=1994  —— 没编号时让 TMDB 现查一次
 *       ?stills=10               —— 顺带回几张 IMDb 高清剧照（0 = 不要）
 *     回 { video: { mp4:{1080p,720p,480p,SD}, hls, thumb, expires }, stills:[] }
 *     取不到一律 { video: null }，前端退回静态剧照 hero —— 不弹错误。
 *
 *   ★ /api/tmdb 与 /api/tmdb-batch 的 payload 新增 imdb 字段
 *     （movie 读 imdb_id，tv 读 external_ids.imdb_id）
 *     边缘缓存命名空间同步 tmdb-v6 → tmdb-v7，否则新字段要等旧缓存过期。
 *
 *   ⚠︎ IMDb 的播放地址是 CloudFront 签名 URL，Expires 恰好 24 小时。
 *      所以该端点的边缘缓存写死 6 小时，且不带 stale-while-revalidate。
 *
 * ────────────────────────────────────────────────────────────────
 * v16 → v17 变更 —— 主题：重复影片的「看得见」与「自动清掉」
 *
 *   一个库跑久了必然长出重复：同一部片先存了 1080p，后来又转了 4K；
 *   同一份资源换个组名再下一遍；转存两次只差个后缀。占空间是小事，
 *   真正难受的是首页、featured、hero 候选里反复出现同一部片。
 *
 *   ★ ① 身份签名 + 并查集分组（这套东西唯一的难点）
 *     → 逐个文件生成 1~2 枚签名，共享任意一枚即并入同组：
 *         拉丁轨 l|集|年|去噪拉丁名   「阿凡达.Avatar.2009」↔「Avatar.2009」
 *         中文轨 c|集|年|去噪中文名   「阿凡达.2009」  ↔「阿凡达.Avatar.2009」
 *       —— 字符串相等只能抓「同名不同后缀」，双轨签名才抓得住
 *          中英混写、组名前缀、规格后缀这些真实世界的命名
 *     → 去噪只剥技术规格与语言字幕词；SxxExx / 第N集 进签名，剧集不误伤
 *     → 刻意不剥版本词（导演剪辑版 / 加长版 / 未删减 / 剧场版）：
 *       那是不同的成品，剥了就会拿导剪版去顶掉公映版。宁可漏判不可错删
 *
 *   ★ ② 保留规则：一律留体积最大的那个
 *     → 同规格如此，跨规格同样如此（按需求固定，不做智能猜测）
 *     → 跨规格且被删者分辨率更高时打「⚠︎ 降规格」标记：行为不变，
 *       但 4K WEB-DL 输给 1080p REMUX 这种事你能一眼看见
 *
 *   ★ ③ 自动删除的三道保险（删除是不可撤销语义，必须比读路径更保守）
 *     → 体积门槛 DUPE_MIN_MB（默认 200MB）：预告片 / 样片不入清理名单
 *     → 通名黑名单：trailer / sample / 预告 / 片段… 只列出、永不自动删
 *     → 单轮上限 DUPE_MAX_DELETE（默认 50）：判定万一失手，损失有天花板
 *     → delete_v2 → Dropbox 回收站，30 天可还原；不是 permanently_delete
 *
 *   ★ ④ confirm=<gen> —— 「你确认的就是你看到的那份列表」
 *     → 清理端点要求带确认令牌；带 gen 时服务端比对当前库指纹，
 *       不一致 → 409 + 新报告。绝不出现「按旧列表删新文件」
 *     → 复用 v16 的内容寻址指针：报告的边缘缓存键同样带 g
 *
 *   ★ ⑤ 邮件报告：复用 cuven-core（登录 Worker）那条通道，不另起一套
 *     → 同一个 RESEND_API_KEY、同一个已验证域 cuven.online，
 *       版式沿用 persona 通知邮件的瑞士国际主义骨架（mailShell）；
 *       品牌方块改 STREAM、显示名 'Cuven Stream'，收件箱里一眼可分
 *     → 清单是行级数据，为此给 mailShell 加了一个 list 槽：
 *       保留 / 删除 不靠红绿，靠 KEEP 黑体 与 DEL 灰体加删除线区分
 *     → 每日巡检：列表没变化就不发信 —— 天天发同一封只会训练你忽略它；
 *       真删了东西一定发信
 *
 *   新增端点
 *     GET  /dupes                    重复列表页（玻璃卡片 + 一键清理）
 *     GET  /api/dupes                报告 JSON（键含 gen，边缘可长缓存）
 *     GET  /api/dupes?mail=1         立刻邮件发我
 *     POST /api/dupes/prune?confirm=<gen|1>   执行清理并发信
 *
 *   新增环境变量（全可选；默认只报告不删）
 *     DUPE_AUTO_PRUNE="1" 每日自动清理   DUPE_HOUR="1" 巡检 UTC 时
 *     DUPE_MIN_MB="200"   最小体积       DUPE_MAX_DELETE="50" 单轮上限
 *     DUPE_CRON="0"       关闭每日巡检
 *     RESEND_API_KEY（与登录 Worker 同一个）  MAIL_FROM / MAIL_TO / MAIL_TZ
 *
 * ────────────────────────────────────────────────────────────────
 * v15 → v16 变更 —— 主题：影片更新延迟 从「小时级」压到「秒级」
 *
 *   诊断：v15 新片可见延迟 = 感知(cron ≤10min) + 边缘缓存寿命。
 *   后者才是大头 —— hero/featured 的 edge key 不含内容版本，
 *   s-maxage 分别是 6h / 4h，且 /api/refresh 只能逐出「当前 PoP」。
 *   于是同一部新片：北京用户 3 分钟看到，洛杉矶用户 4 小时后才看到。
 *   （也是「改了 hero 却还是旧内容、只能靠手动 ATV_HERO_VER++」的根因）
 *
 *   ★ ① 推送感知：Dropbox Webhook（/dbx/webhook）
 *     → GET ?challenge= 回显握手；POST 校验 X-Dropbox-Signature
 *       = HMAC-SHA256(APP_SECRET, raw body)，恒时比较，fail-closed
 *     → 命中即 3s 去抖 → warmCaches；10min 轮询降级为兜底网
 *     → 感知延迟：10 min → ~2 s
 *
 *   ★ ② 增量拉取：list_folder/continue 游标 delta（取代全量递归）
 *     → 快照持久化 _cursor；每次只取「变化的条目」，O(Δ) 而非 O(库)
 *     → 处理 deleted（含删目录 → 前缀级联清理）、非视频扩展名转出
 *     → 409 reset / 无游标 → 自动全量重建兜底
 *     → 5000 部的库：单次刷新 ~15 次 API × 分页 → 1 次、~150ms
 *       ⇒ cron 才敢降到 1 分钟，webhook 才敢来一次刷一次
 *
 *   ★ ③ 内容寻址缓存键（本次真正的「高明」处）
 *     → gen = fnv1a(所有 path + server_modified)，内容变则变、否则恒定
 *     → /api/all · /api/list · /api/featured · /api/atv/hero 的 edge key
 *       全部带 &g=<gen>：内容一变，全球所有 PoP 的旧键「自然失联」，
 *       无需逐出、无需枚举、无需等 TTL —— 缓存失效问题变成缓存命名问题
 *     → 随之：删掉 /api/refresh 里那串硬编码 cache.delete 枚举；
 *       ATV_HERO_VER 回归「改代码才升版」的本义
 *     → 浏览器侧 max-age 相应收短（60~120s），边缘侧可长命百岁
 *     → 指针读取：KV（LIB_STATE，可选，~1ms）→ R2 快照回退 → 5s 内存层
 *
 *   ★ ④ 排序真源：server_modified（新增 added 字段）
 *     → client_modified 是「文件自称的修改时间」，转存/下载的片子普遍
 *       带着 2009 年的时间戳入库 —— 按它排「最新」，新片可能永不上首屏
 *     → added = server_modified（落库时间）才是「上新」的语义
 *     → featured / atv-hero 候选排序改用 added，modified 保留供展示
 *
 *   ★ ⑤ 增量精排：只算「新出现的那几部」
 *     → hero：按 path 复用上一版已解析条目 + 未命中名单（24h 负缓存）
 *       ⇒ 新增 1 部 = 1 次 uts 搜索（原 32 次）；超龄重建才做全量刷新
 *     → featured：R2 成品内嵌 releaseDate 记忆表（title|year → rd）
 *       ⇒ 新增 1 部 = 1 次 TMDB（原 ~60 次）
 *     → 重建从 ~20s 降到 <1s，这才让「webhook 到位即可见」成立
 *
 *   ★ ⑥ /api/gen —— 40 字节的版本指针端点
 *     → 前端 visibilitychange / focus 时轮询；gen 变了才重拉数据
 *     → 已打开的页面无需刷新即可上新，代价近似于零
 *
 *   端到端：上传完成 → ~2s webhook → ~0.3s delta → ~0.5s 增量精排
 *           → gen 翻转 → 全球所有 PoP 下一次请求即新内容
 *
 *   新增可选绑定
 *     [[kv_namespaces]]  binding = "LIB_STATE"   # 仅存 gen 指针，可不配
 *   Dropbox App Console → Webhooks → https://<worker>/dbx/webhook
 *   建议 crons = ["* * * * *"]（每分钟；delta 后成本可忽略，纯兜底）
 *
 * ────────────────────────────────────────────────────────────────
 * v14 → v15 变更
 *
 *   ★ /stream 签名直链（取代 v14 的 ?key= 内联放行 —— BREAKING）
 *     → sig = HMAC-SHA256(AUTH_SECRET, `${path}|${exp}`)，默认 12h 有效
 *       （env.STREAM_SIGN_TTL 秒数可覆盖）
 *     → 可分享、会过期、不含主密钥；/watch 顶栏一键复制外部播放器直链
 *     → 浏览器 <video> 同走签名 src：Cookie 过期不再导致长片中途 seek 401
 *     → 迁移：v14 的 ?key= 直链会把主密钥留在播放器历史与访问日志中，
 *       已移除 —— 外部播放器请到 /watch 页重新复制链接
 *
 *   ★ 登录与密钥加固
 *     → 登录改 POST /auth 设 Cookie（密钥不再以 GET query 进历史/日志）
 *     → 所有密钥/签名比较恒时化（CF timingSafeEqual，含降级实现）
 *     → GET ?key= 入口保留为兼容（老书签仍可用，UI 不再产生）
 *
 *   ★ Cron 预热（wrangler.toml：[triggers] crons = ["0,10,20,30,40,50 * * * *"]，即每 10 分钟）
 *     → scheduled()：文件列表每 10min 刷入 R2 → 全局免冷
 *     → featured / now-playing「成品」落 R2 作全局真源
 *       （Edge Cache 按 PoP，cron 只能暖单机房；R2 才是全局层）
 *       featured 仅在候选集变化或超 6h 时重建，不空跑 TMDB；
 *       一份 top-16 成品服务所有 n，featured 首屏 modified 排序的
 *       过渡态在成品在位后自然消失
 *     → /api/refresh 与 cron 共用 warmCaches()（同一把 singleFlight 锁），
 *       refresh 强制重建 featured 成品
 *     → 成品超龄自愈：kickWarm 节流每分钟至多一次
 *
 *   ★ 正确性
 *     → 递归分页中途失败改为抛错：不再把截断的「半个片库」持久化进 R2
 *       （SWR 后台刷新失败自动保留旧数据）
 *     → stale-if-error：冷路径回源失败时读超过 SWR 窗口的 R2 旧数据兜底
 *     → If-Range 与当前 ETag 不符 → 按 RFC 9110 忽略 Range 回 200，
 *       防止新旧文件字节混拼
 *     → 多段 Range（bytes=a-b,c-d）只透传第一段，避免 multipart/byteranges
 *       与覆写的视频 Content-Type 冲突
 *     → /api/coming-soon/remind 改每条独立 R2 对象，消除读改写竞态丢单
 *     → /api/all 的 depth clamp 到 1..5（防 edge cache key 无界膨胀）
 *
 * ────────────────────────────────────────────────────────────────
 * v13 → v14 变更
 *
 *   ★ 稳定性
 *     → /stream 304 / 4xx / 5xx 响应补 CORS 头
 *       （跨域播放器的条件请求不再被浏览器当作 CORS 失败）
 *     → /stream 上游错误显式化：自愈后仍 403/410、或 416/5xx 时
 *       回 416/502，不再伪装成带完整 Content-Length 的「正常响应」
 *     → /stream 鉴权短路真正落地：?key= 内联校验直接放行
 *       （不 302、不写 Cookie），Infuse / VLC 等外部播放器可用
 *     → Token 刷新：expires_in 缺失兜底 4h（避免 NaN 退化成每请求刷新）；
 *       缺 access_token 显式抛错；重试收紧为 retries:2 / timeout:8s
 *     → SWR 后台刷新 singleFlight 去重：stale 窗口内串行请求
 *       不再各自触发一次全量递归 list_folder
 *     → fetchRetry：抛错路径补 clearTimeout；5xx/429 重试前 cancel body
 *       释放连接；429 尊重 Retry-After（封顶 10s）
 *     → /api/tmdb-batch：单条元数据抛错置 null（不再整 key 消失），
 *       瞬时失败不写负缓存
 *
 *   ★ 速度
 *     → /api/list 真缓存：Edge Cache + 按 folder 的 singleFlight + ETag/304
 *       （Worker 响应不吃 s-maxage，此前等于零缓存；冷 300-800ms → 热 <20ms）
 *     → /api/featured 冷路径 SWR：立即按 modified 秒回，
 *       TMDB 精排转 waitUntil 后台（singleFlight 保护），冷 TTFB 秒级 → ~100ms
 *     → /stream HEAD 快速路径：直接用缓存 metadata 应答，起播探测省一次回源
 *     → 排序预计算 timestamp，比较器不再每次比较创建 2 个 Date 对象
 *
 * ────────────────────────────────────────────────────────────────
 * v12 → v13 变更
 *
 *   ★ /api/now-playing（新）
 *     → TMDB「正在热映」院线片单：海报 + 背景图 + PNG Logo 组合
 *     → cn 区优先、全球区兜底，双区并发合并去重
 *     → 优先保留带 Logo 的影片（前端可做 海报+Logo 组合展示）
 *     → Edge Cache 6h + SWR 24h + Single-Flight，冷启动仅 2+N 次 TMDB
 *
 *   ★ /api/coming-soon/remind（新）
 *     → 前端「加入时邮件提醒我」上报端点：202 秒回，R2 尾部追加存档
 *     → 修复：v12 中该 POST 会落入 default 分支返回整页 HTML(200)
 *
 *   ★ Token 刷新加固
 *     → oauth2/token 改走 fetchRetry（10s 超时 + 1 次重试），
 *       避免一次挂起的令牌请求拖垮所有并发请求
 *
 *   ★ /stream 二次回源加固
 *     → 自愈重试路径上的最后一次 fetch 也有显式 502 兜底
 *
 *   ★ /api/refresh 同步逐出 now-playing 缓存
 *
 * ────────────────────────────────────────────────────────────────
 * Apple-quality 工程改进（v11 → v12
 *
 *   ★ 请求合并（Coalescing）
 *     → 多个并发冷请求只触发 1 次 Dropbox / TMDB 回源
 *     → Token 刷新、文件列表、临时链接均受保护
 *
 *   ★ 临时链接自愈
 *     → 缓存的 Dropbox link 过期（403/410）时自动逐出并重取
 *     → 对客户端完全透明，无需重试
 *
 *   ★ iTunes 并发查询
 *     → cn / us 两区并行，取先到的有效结果，减少 ~200ms
 *
 *   ★ 全链路 Server-Timing
 *     → 每个端点返回 Server-Timing 头，可在 DevTools 直接看到
 *       各阶段耗时（cache-hit / r2 / dropbox / tmdb / itunes / upstream）
 *
 *   ★ 零拷贝 CORS
 *     → 冻结 CORS 头对象，addCors 直接 set 而非 rebuild Response
 *
 *   ★ 鉴权短路
 *     → /health、/stream（带缓存链接时）优先于 cookie 解析
 *
 *   ★ 优雅降级
 *     → 任何外部 API（Dropbox / TMDB / iTunes）超时或失败
 *       均有显式 fallback，不会白屏
 *
 *   ★ Apple TV 桥（/api/atv/*）
 *     → uts-api 直连，pfm=appletv 解锁全量目录（TV+ 与商店片）
 *     → hero（唯一源管线）：库中影片 → 商店英文片名搜索匹配（标点折叠 +
 *       年份 ±1 消歧）→ 详情页一次取齐双海报 + logo；条目自带库内 path，
 *       前端免匹配直接可播；成品「R2 全局真源（模板态）+ edge」双层，
 *       库候选集变化或超龄由 cron 重建；素材双轨：横版 posterArt（iPad / 桌面）
 *       + 竖版 contentImageTall（iPhone），前端按断点选轨；hero 已零 TMDB 依赖
 *     → lookup / search 保留（前端严选区已下线，接口留给外部调用）；edge 缓存 6h
 *
 * 环境变量
 *   DROPBOX_REFRESH_TOKEN, DROPBOX_APP_KEY, DROPBOX_APP_SECRET
 *   ROOT_FOLDER, AUTH_SECRET, TMDB_API_KEY
 *   STREAM_SIGN_TTL（可选：签名直链有效期秒数，默认 43200 = 12h。
 *     外部播放器把 URL 存进片库长期复用的场景可调大，如 604800 = 7d；
 *     TTL 越长，单条泄露链接的可用窗口越大 —— 按威胁模型权衡）
 *   SEEK_BURST_MB（默认 16；0 关闭 seek 并行突发）
 *   SEEK_BURST_AT_START（默认关闭；设为 1 才允许 bytes=0- 也并行，通常不建议）
 *   SEEK_CHUNK_MB（默认 4）、SEEK_WINDOW（默认/最大 3）
 *   SEEK_CHUNK_CACHE（默认开启；设为 0 关闭）
 *   STREAM_PREWARM_RANGE（默认关闭；设为 1 恢复 bytes=0-0 TLS 预热）
 *   STREAM_HEDGE_MS（默认 400；0 关闭首片对冲）
 *   STREAM_STALL_MS（默认 20000；0 关闭静默看门狗）
 *   STREAM_RESUME_MAX（默认 8；连续无进展重连上限）
 *   STREAM_OPEN_MAX（默认 36；整次 /stream 共享上游 fetch 硬预算）
 *
 * 定时触发（预热，强烈建议启用）
 *   [triggers]
 *   crons = ["0,10,20,30,40,50 * * * *"]
 *   （等价于每 10 分钟；星号斜杠写法会终结本块注释，故此处用枚举形式，
 *     wrangler.toml 里两种写法均可）
 *
 * R2 绑定
 *   [[r2_buckets]]
 *   binding = "FILE_CACHE"
 *   bucket_name = "<your-bucket>"
 *
 * 邮件（v17）—— 与登录 Worker cuven-core 共用凭据，无需新建任何绑定
 *   Secret  RESEND_API_KEY = <与 cuven-core 相同的 Resend key>
 *   Var     MAIL_FROM = "Cuven Stream <noreply@cuven.online>"
 *   Var     MAIL_TO   = "yujie.lab@gmail.com"（可省，代码内默认即此）
 */

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Entry
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // ── Preflight（不解析 cookie，零开销）──
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    // ── 鉴权 ──
    // /dbx/webhook 走 Dropbox 自己的 HMAC 签名鉴权（见 handleDbxWebhook），
    // 不能套 Cookie 门 —— Dropbox 的通知请求不带 Cookie
    if (env.AUTH_SECRET && path !== '/health' && path !== '/auth' && path !== '/dbx/webhook') {
      const cookie = parseCookies(request.headers.get('Cookie') || '');
      const paramKey = url.searchParams.get('key');
      const isStream = path === '/stream' || path.startsWith('/stream/');
      // 优选入口是不同 hostname，Cookie 带不过去 → 测速探针复用与 /stream
      // 完全相同的 HMAC 签名（伪路径 __probe__），fail-closed 语义不变。
      const isProbe = path === EDGE_PING_PATH;
      // v24：允许跨优选入口的 <track> 字幕请求通过与 /stream 相同的 HMAC 签名鉴权
      const isSubVtt = path === '/api/subs/vtt';
      // v25：HLS 的签名在路径里（/hls/<exp>.<sig>.<path>/…），相对 URI 自动继承
      const isHls = path.startsWith('/hls/');

      // /stream 鉴权短路：HMAC 签名直链（?exp=&sig=）内联校验放行。
      // 外部播放器（Infuse/VLC）不处理 Set-Cookie，必须在本次请求内完成校验；
      // v14 的 ?key= 内联放行会把主密钥留在播放器历史、分享链接与各级访问
      // 日志里 —— 已由「可分享、会过期、不含主密钥」的签名取代。
      const authed =
        (cookie.auth && await verifySession(cookie.auth, env)) ||
        ((isStream || isProbe || isSubVtt) && await verifyStreamSig(url, env)) ||
        (isHls && await hlsVerifyPath(path, env));

      // 原生播放器拿到 HTML 登录页只会报「无法播放」—— HLS 一律回 401，
      // 播放页据此换签名重载
      if (!authed && isHls) return hlsFail(401, 'signature expired');

      if (!authed) {
        // 兼容入口：GET ?key= 通过 → 写 Cookie 并 302 跳回干净 URL
        //（老书签仍可用；登录表单本身已改 POST /auth，不再产生此类 URL）
        if (paramKey && timingSafeEqualStr(paramKey, env.AUTH_SECRET)) {
          const cleanParams = new URLSearchParams(url.search);
          cleanParams.delete('key');
          const cleanQs = cleanParams.toString();
          return new Response(null, {
            status: 302,
            headers: {
              'Location': url.pathname + (cleanQs ? `?${cleanQs}` : ''),
              'Set-Cookie': sessionCookie(await mintSession(env)),
            },
          });
        }
        // 401 登录页：携带回跳路径（剔除 key），成功后 302 回原地
        const clean = new URLSearchParams(url.search);
        clean.delete('key');
        const qs = clean.toString();
        return new Response(loginPage(url.pathname + (qs ? `?${qs}` : '')), {
          status: 401,
          headers: {
            'Content-Type': 'text/html; charset=utf-8',
            'Cache-Control': 'no-store',
            ...HTML_SEC,
          },
        });
      }
    }

    try {
      // ── 路由 ──
      // /stream 兼容 /stream 和 /stream/<filename>
      // 让 Infuse / VLC 等播放器以 URL 路径里的文件名区分不同影片，避免进度共享
      if (path === '/stream' || path.startsWith('/stream/')) {
        return await handleStream(url, request, env, ctx);
      }
      // v25：MKV → HLS（fMP4）实时重封装，iOS / Safari 原生播放
      if (path.startsWith('/hls/')) {
        return await handleHls(url, request, env, ctx);
      }
      switch (path) {
        case '/health':         return handleHealth(env, request);
        // 优选入口：自检（打到哪个 PoP、RTT 多少）与浏览器侧测速探针
        case '/api/edge':       return cors(handleEdge(request, env));
        case EDGE_PING_PATH:    return handleEdgePing(url);
        case '/auth':           return await handleAuthLogin(request, env);
        case '/api/list':       return cors(await handleList(url, request, env, ctx));
        case '/api/all':        return cors(await handleListAll(url, request, env, ctx));
        case '/api/featured':   return cors(await handleFeatured(url, env, ctx));
        case '/api/tmdb':       return cors(await handleTmdb(url, env, ctx));
        // 剧集（TV_FOLDER，默认 /ram2）：剧集表 / 分集表 / TMDB 一季的分集信息
        case '/api/tv':          return cors(await handleTv(url, env, ctx));
        case '/api/tv/episodes': return cors(await handleTvEpisodes(url, env, ctx));
        case '/api/tmdb/season': return cors(await handleTmdbSeason(url, env, ctx));
        case '/api/tmdb-batch': return cors(await handleTmdbBatch(request, env, ctx));
        case '/api/imdb/video': return cors(await handleImdbVideo(url, env, ctx));
        // 播放页在签名过期或受控恢复前换取新直链；仍受 Cookie 鉴权保护。
        case '/api/stream-sign': return cors(await handleStreamSign(url, env));
        // v24：外挂字幕自动发现与 SRT/ASS -> WebVTT 实时转换
        case '/api/subs':        return cors(await handleSubsList(url, env, ctx));
        case '/api/subs/vtt':    return cors(await handleSubVtt(url, env, ctx));
        case '/api/now-playing':        return cors(await handleNowPlaying(url, env, ctx));
        case '/api/atv/hero':           return cors(await handleAtvHero(url, env, ctx));
        case '/api/atv/lookup':         return cors(await handleAtvLookup(url, env, ctx));
        case '/api/atv/search':         return cors(await handleAtvSearch(url, env, ctx));
        case '/api/coming-soon/remind': return cors(await handleRemind(request, env, ctx));
        case '/api/refresh':    return cors(await handleRefreshCache(env, ctx));
        // 重复影片：列表（纯读，带 gen 可长缓存）/ 清理（写，需 confirm）
        case '/api/dupes':       return cors(await handleDupes(url, request, env, ctx));
        case '/api/dupes/prune': return cors(await handleDupePrune(request, url, env, ctx));
        // 库版本指针：前端轮询它决定「要不要重拉」，~40 字节
        case '/api/gen':        return cors(await handleGen(env, ctx));
        // Dropbox 变更推送入口（无 Cookie 门，签名自证）
        case '/dbx/webhook':    return await handleDbxWebhook(request, env, ctx);
        // ⚠️ handleWatch 已异步（生成签名直链）：必须 return await，
        // 否则 rejection 会绕过本 try/catch 直接变成未处理异常
        case '/watch':          return await handleWatch(url, request, env, ctx);
        // 重复影片列表页：页面零数据，进来现取 /api/dupes
        case '/dupes':
          return new Response(dupesPage(), {
            headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', ...HTML_SEC },
          });
        case '/robots.txt':
          return new Response('User-agent: *\nDisallow: /\n',
            { headers: { 'Content-Type': 'text/plain; charset=utf-8', ...HTML_SEC } });
        case '/favicon.ico':
          return new Response(null, { status: 204, headers: { 'Cache-Control': 'public, max-age=86400' } });
        default:
          // 以前任何未知路径都回一整页 HTML —— 包括 /apple-touch-icon.png、
          // /.env 这类探测，也包括前端写错的 API 路径（拿到 200 + HTML 之后
          // JSON.parse 失败，报的是解析错误而不是"路由不存在"）。
          // 看起来像资源或 API 的路径一律 404，剩下的才当页面路由。
          if (/\.[a-z0-9]{1,5}$/i.test(path) || path.startsWith('/api/')) {
            return cors(jsonResponse({ error: 'Not found', path }, 404));
          }
          return new Response(browserPage(env), {
            headers: { 'Content-Type': 'text/html; charset=utf-8', ...HTML_SEC },
          });
      }
    } catch (e) {
      // 异常信息里可能夹着上游 URL、临时链接、token 片段 —— 不外泄。
      // 详情进 console，前端只拿到一个可定位的 ref。
      const ref = fnv1a(`${Date.now()}|${path}|${e && e.message}`);
      console.error(`[${ref}] ${path}:`, e && e.stack || e);
      return cors(jsonResponse({ error: 'Internal error', ref }, 500));
    }
  },

  // ── Cron 预热（v16 起降级为「兜底网」）──
  //  主路径是 Dropbox webhook；cron 只负责补漏（webhook 丢包 / 应用外改动 /
  //  游标失效自愈）。因为刷新已是游标增量，成本≈0，可以放心调到每分钟：
  //    [triggers]
  //    crons = ["* * * * *"]
  //  singleFlight('warm') 与 /api/refresh、webhook、stale 自愈共用同一把锁
  async scheduled(event, env, ctx) {
    // 每 30 次（≈30min）做一次全量对账，纠正游标漂移 / 应用外的静默改动
    const full = Math.floor(Date.now() / 60_000) % 30 === 0;
    ctx.waitUntil(singleFlight('warm', () => warmCaches(env, { full })).catch(() => {}));
    // 每日一次的重复影片巡检：只在 DUPE_HOUR 那一小时内动手，
    // R2 里的 lastRunDay 记账保证「一天一次」，与 cron 的触发频率解耦
    ctx.waitUntil(dupeCron(env, ctx).catch(() => {}));
    // 剧集表跟着一起热：用户打开首页时 /api/tv 直接给现成的，不等 Dropbox 列目录
    ctx.waitUntil(singleFlight('tv-scan', () => tvRefresh(env, ctx)).catch(e => console.error('tv cron:', e && e.message)));
  },
};

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  常量 & 工具
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

const VIDEO_EXTS = new Set(['.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v']);
const MIME_MAP = {
  '.mp4': 'video/mp4', '.mkv': 'video/x-matroska', '.webm': 'video/webm',
  '.mov': 'video/quicktime', '.avi': 'video/x-msvideo', '.m4v': 'video/x-m4v',
};

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  v24：外挂字幕发现 & SRT/ASS → WebVTT 实时转换
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

const SUB_EXTS = new Set(['.srt', '.ass', '.ssa', '.vtt']);
const SUB_CACHE = 'https://cache.internal/sub-vtt-v1/';

function inferSubLang(subName, videoStem) {
  const rest = subName.slice(0, subName.lastIndexOf('.'))
    .slice(videoStem.length).toLowerCase();
  if (/chs.*eng|简英|中英/.test(rest)) return { srclang: 'zh-Hans', label: '简英双语' };
  if (/cht.*eng|繁英/.test(rest))     return { srclang: 'zh-Hant', label: '繁英双语' };
  if (/chs|sc|zh[-_.]?cn|zh[-_.]?hans|简/.test(rest)) return { srclang: 'zh-Hans', label: '简体中文' };
  if (/cht|tc|zh[-_.]?tw|zh[-_.]?hk|zh[-_.]?hant|繁/.test(rest)) return { srclang: 'zh-Hant', label: '繁体中文' };
  if (/zh|chi|zho|中/.test(rest))      return { srclang: 'zh', label: '中文' };
  if (/eng|(?:\b|[._-])en(?:\b|[._-])|英/.test(rest)) return { srclang: 'en', label: 'English' };
  if (/jpn|(?:\b|[._-])ja(?:\b|[._-])|日/.test(rest)) return { srclang: 'ja', label: '日本語' };
  if (/kor|(?:\b|[._-])ko(?:\b|[._-])|韩/.test(rest)) return { srclang: 'ko', label: '한국어' };
  const clean = rest.replace(/^[._\-\s]+/, '').trim();
  return { srclang: 'zh', label: clean || subName };
}

/** 自动识别 UTF-8 / UTF-16LE / UTF-16BE / GB18030(GBK)，彻底杜绝中文字幕乱码 */
function decodeSubtitleBytes(u8) {
  if (u8.length >= 3 && u8[0] === 0xEF && u8[1] === 0xBB && u8[2] === 0xBF) {
    return new TextDecoder('utf-8').decode(u8.subarray(3));
  }
  if (u8.length >= 2 && u8[0] === 0xFF && u8[1] === 0xFE) {
    return new TextDecoder('utf-16le').decode(u8.subarray(2));
  }
  if (u8.length >= 2 && u8[0] === 0xFE && u8[1] === 0xFF) {
    return new TextDecoder('utf-16be').decode(u8.subarray(2));
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(u8);
  } catch {
    try { return new TextDecoder('gb18030').decode(u8); }
    catch { return new TextDecoder('utf-8').decode(u8); }
  }
}

function assTimeToVtt(t) {
  const m = /^\s*(\d+):(\d{2}):(\d{2})[.:](\d{1,3})\s*$/.exec(t || '');
  if (!m) return null;
  const hh = m[1].padStart(2, '0');
  const mm = m[2];
  const ss = m[3];
  const ms = m[4].length === 2 ? m[4] + '0' : m[4].padEnd(3, '0');
  return `${hh}:${mm}:${ss}.${ms}`;
}

function cleanSubText(raw) {
  return String(raw || '')
    .replace(/\{\\pos\([^)]*\)\}/gi, '')
    .replace(/\{[^}]*\}/g, '')
    .replace(/\\N/g, '\n')
    .replace(/\\n/g, '\n')
    .replace(/\\h/g, ' ')
    .replace(/[ \t]+\n/g, '\n')
    .trim();
}

function convertToWebVtt(text, ext) {
  const norm = text.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
  if (ext === '.vtt' || /^WEBVTT(?:\s|$)/.test(norm)) {
    return norm.startsWith('WEBVTT') ? norm : `WEBVTT\n\n${norm}`;
  }
  if (ext === '.ass' || ext === '.ssa' || /\[Events\]/i.test(norm)) {
    const lines = norm.split('\n');
    let inEvents = false;
    let startIdx = 1, endIdx = 2, textIdx = 9;
    const cueMap = new Map();
    for (const line of lines) {
      const trimmed = line.trim();
      if (/^\[Events\]/i.test(trimmed)) { inEvents = true; continue; }
      if (/^\[.*\]$/.test(trimmed)) { if (inEvents) break; continue; }
      if (!inEvents) continue;
      if (/^Format\s*:/i.test(trimmed)) {
        const cols = trimmed.slice(trimmed.indexOf(':') + 1).split(',').map(s => s.trim().toLowerCase());
        const si = cols.indexOf('start'), ei = cols.indexOf('end'), ti = cols.indexOf('text');
        if (si >= 0) startIdx = si;
        if (ei >= 0) endIdx = ei;
        if (ti >= 0) textIdx = ti;
        continue;
      }
      if (!/^Dialogue\s*:/i.test(trimmed)) continue;
      const body = trimmed.slice(trimmed.indexOf(':') + 1);
      const parts = [];
      let cur = 0;
      for (let i = 0; i < textIdx; i++) {
        const comma = body.indexOf(',', cur);
        if (comma < 0) break;
        parts.push(body.slice(cur, comma));
        cur = comma + 1;
      }
      parts.push(body.slice(cur));
      if (parts.length <= textIdx) continue;
      const st = assTimeToVtt(parts[startIdx]);
      const et = assTimeToVtt(parts[endIdx]);
      if (!st || !et || st >= et) continue;
      const cleaned = cleanSubText(parts[textIdx]);
      if (!cleaned) continue;
      const key = `${st} --> ${et}`;
      const prev = cueMap.get(key);
      if (prev && !prev.includes(cleaned)) cueMap.set(key, `${prev}\n${cleaned}`);
      else if (!prev) cueMap.set(key, cleaned);
    }
    const out = ['WEBVTT', ''];
    for (const [timing, payload] of cueMap) {
      out.push(timing, payload, '');
    }
    return out.join('\n');
  }

  const blocks = norm.split(/\n{2,}/);
  const out = ['WEBVTT', ''];
  for (const b of blocks) {
    const ls = b.trim().split('\n');
    if (!ls.length) continue;
    let idx = 0;
    if (/^\d+$/.test(ls[0].trim()) && ls.length > 1) idx = 1;
    const tLine = ls[idx] || '';
    const m = /(\d{1,2}:\d{2}:\d{2})[,.](\d{3})\s*-->\s*(\d{1,2}:\d{2}:\d{2})[,.](\d{3})(.*)/.exec(tLine);
    if (!m) continue;
    const s1 = m[1].length === 7 ? '0' + m[1] : m[1];
    const s2 = m[3].length === 7 ? '0' + m[3] : m[3];
    const body = cleanSubText(ls.slice(idx + 1).join('\n'));
    if (!body) continue;
    out.push(`${s1}.${m[2]} --> ${s2}.${m[4]}${m[5] || ''}`, body, '');
  }
  return out.join('\n');
}

async function handleSubsList(url, env, ctx) {
  const filePath = url.searchParams.get('path') || '';
  if (!filePath) return jsonResponse({ subs: [] });
  const slash = filePath.lastIndexOf('/');
  const folder = slash > 0 ? filePath.slice(0, slash) : (env.ROOT_FOLDER || '');
  const fileName = filePath.slice(slash + 1);
  const dot = fileName.lastIndexOf('.');
  const stem = (dot > 0 ? fileName.slice(0, dot) : fileName).toLowerCase();

  let entries = [];
  try {
    entries = await singleFlight(`sub-dir:${folder}`, async () => {
      const list = [];
      let res = await dbxListFolder(folder, env);
      list.push(...(res.entries || []));
      while (res.has_more) {
        res = await dbxListFolder(null, env, res.cursor);
        list.push(...(res.entries || []));
      }
      return list;
    });
  } catch {
    return jsonResponse({ subs: [] });
  }

  const videoCount = entries.filter(e => e['.tag'] === 'file' && VIDEO_EXTS.has(getExt(e.name))).length;
  const subFiles = entries.filter(e => {
    if (e['.tag'] !== 'file') return false;
    const ext = getExt(e.name);
    if (!SUB_EXTS.has(ext)) return false;
    const nl = e.name.toLowerCase();
    return nl.startsWith(stem) || videoCount <= 1;
  });

  const subs = await Promise.all(subFiles.map(async f => {
    const meta = inferSubLang(f.name, stem);
    const sign = env.AUTH_SECRET ? await signStreamPath(f.path_display, env) : null;
    const qs = new URLSearchParams({ path: f.path_display });
    if (sign) { qs.set('exp', String(sign.exp)); qs.set('sig', sign.sig); }
    return {
      name: f.name,
      path: f.path_display,
      ext: getExt(f.name),
      srclang: meta.srclang,
      label: meta.label,
      url: `/api/subs/vtt?${qs.toString()}`,
    };
  }));

  // 没有简体中文的片子：带上 OpenSubtitles 自动找来的那一条（warm=1 只在后台开始查，立刻回）
  let pending = false;
  if (osOn(env)) {
    const os = await subsOnline(filePath, fileName, stem, subFiles, env, ctx,
      url.searchParams.get('warm') === '1' ? 0 : OS_LIST_WAIT_MS).catch(() => null);
    if (os && os.rec) {
      const sign = env.AUTH_SECRET ? await signStreamPath(filePath, env) : null;
      const qs = new URLSearchParams({ path: filePath, os: '1' });
      if (sign) { qs.set('exp', String(sign.exp)); qs.set('sig', sign.sig); }
      qs.set('v', `${(os.rec.src && os.rec.src.file) || ''}.${syncId(os.rec.sync)}`);   // 换了字幕或对齐：链接跟着变，浏览器不会拿旧时间
      subs.push({ name: os.rec.label, path: filePath, ext: '.vtt', srclang: os.rec.lang, label: os.rec.label, online: true,
        url: `/api/subs/vtt?${qs.toString()}` });
    }
    pending = !!(os && !os.rec && os.pending);                 // 还在查：别让浏览器缓存这份「还没有」
  }
  return jsonResponse({ subs }, 200, { 'Cache-Control': pending ? 'no-store' : 'public, max-age=60' });
}

/** 直连这边的在线字幕：已有字幕 = 同目录外挂（内封的这边看不到；Chrome 也画不出 MKV 内封字幕） */
async function subsOnline(filePath, fileName, stem, subFiles, env, ctx, waitMs) {
  const linkData = await getTempLink(filePath, env, ctx);
  const meta = linkData && linkData.metadata;
  if (!meta || !Number.isFinite(meta.size)) return null;
  const tracks = subFiles.map((f, i) => {
    const x = { path: f.path_display, rev: f.rev || f.content_hash || '', ext: getExt(f.name) };
    return { id: 'x' + i, lang: inferSubLang(f.name, stem).srclang, rev: x.rev,
      sample: async () => (await hlsSidecarCues(x, env, ctx)).slice(0, 400).map(c => c.text).join('\n') };
  });
  const cx = { filePath, linkData, env, ctx };
  const xs = subFiles.map(f => ({ name: f.name, path: f.path_display, rev: f.rev || f.content_hash || '', ext: getExt(f.name) }));
  const refs = () => syncRefFromSidecars(xs, env, ctx);
  return osFor(env, ctx, { filePath, name: fileName, meta, read: hlsSmallReader(cx), fps: 0, dur: 0, refs }, tracks, waitMs);
}

async function handleSubVtt(url, env, ctx) {
  const filePath = url.searchParams.get('path') || '';
  if (!filePath) return new Response('Missing path', { status: 400 });
  // OpenSubtitles 找来的那一条（path 是视频本身）
  if (url.searchParams.get('os') === '1') {
    const empty = () => new Response('WEBVTT\n', { headers: { 'Content-Type': 'text/vtt; charset=utf-8', 'Cache-Control': 'no-store' } });
    if (!osOn(env)) return empty();
    const linkData = await getTempLink(filePath, env, ctx);
    const rec = await osLoad(env, await osKeyOf(osIdentity(filePath, linkData.metadata))).catch(() => null);
    if (!rec || rec.status !== 'ok') return empty();
    return new Response(osVttFull(osCuesOut(rec)), {
      headers: { 'Content-Type': 'text/vtt; charset=utf-8', 'Cache-Control': 'public, max-age=3600' },
    });
  }
  const ext = getExt(filePath);
  if (!SUB_EXTS.has(ext)) return new Response('Unsupported subtitle format', { status: 400 });

  const { g } = await ptrGet(env);
  const ck = new Request(`${SUB_CACHE}?p=${encodeURIComponent(filePath)}&g=${g}&c=${SUB_CLEAN_V}`);
  const cache = caches.default;
  const hit = await cache.match(ck);
  if (hit) return new Response(hit.body, { headers: hit.headers });

  const linkData = await getTempLink(filePath, env, ctx);
  const res = await fetchRetry(linkData.link, {}, { retries: 1, timeout: 10_000 });
  if (!res.ok) return new Response('Upstream subtitle error', { status: 502 });

  const u8 = new Uint8Array(await res.arrayBuffer());
  const rawText = decodeSubtitleBytes(u8);
  // 解析成字幕条 → 清洗（字幕组、网址、声明、广告）→ 整份 VTT；解析不出的怪格式退回逐字转换
  const cues = hlsParseSubFile(rawText, ext);
  const vtt = cues.length ? osVttFull(cues) : convertToWebVtt(rawText, ext);

  const resp = new Response(vtt, {
    headers: {
      'Content-Type': 'text/vtt; charset=utf-8',
      'Cache-Control': 'public, max-age=3600, s-maxage=86400',
    },
  });
  ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  OpenSubtitles：没有简体中文字幕（或一条字幕都没有）的片子，自动补一条
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  全自动，不用挑：
//  · 什么时候查：打开详情页（HLS 的 info.json、直连的 /api/subs?warm=1）就在后台查；
//    主列表最多再等 2.5 秒，/api/subs（前端异步取，不挡起播）最多等 6 秒。
//  · 缺不缺：已有简体（zh-Hans，非强制）就不查。只标了「中文」的那条抽一段文字认繁简 ——
//    是繁体才算缺，并在播放列表里改标「繁体中文」；认不出就当它是简体（不白花下载配额）。
//  · 怎么找：先按文件哈希（moviehash：文件大小 + 头尾各 64KB；命中的字幕与这个文件逐帧同步），
//    再按 TMDB 编号（配了 TMDB_API_KEY 时）或片名 + 年份；剧集带季 / 集号。
//  · 要什么语言：简体 → 简英双语（ze）→ 繁体（逐字转成简体）；整部片一条字幕都没有时，最后才要英文。
//  · 怎么挑：哈希命中 > 发布名接近（片源 / 分辨率 / 压制组）> 帧率一致 > 可信上传者 > 下载量；
//    机翻 / AI 翻译、只翻外语部分的往后排；条数太少、时长对不上片长的跳过换下一个。
//    帧率对不上时让 OpenSubtitles 下载时换算（in_fps / out_fps）。
//  · 存哪：结果（含「没找到」）按视频文件存 R2（没绑 R2 就放边缘缓存），HLS 与直连共用，每部片只用
//    一次下载配额；没找到 7 天后再查，配额用完 6 小时后（或按它给的重置时间），接口出错 1 小时后。
//  · 请求之间只读进程内的结果数据，不 await 别的请求的 Promise。
//  · 需要 Secret OPENSUBTITLES_API_KEY；建议再配 OPENSUBTITLES_USERNAME / OPENSUBTITLES_PASSWORD
//    —— 登录后下载配额按账号算，否则按（Workers 共享的）出口 IP 算，基本拿不到。OPENSUBTITLES_DISABLE=1 关闭。

const OS_API = 'https://api.opensubtitles.com/api/v1';
const OS_UA = 'CuvenStream v25';
const OS_FMT = 1;                                   // 记录格式；变了就整体重查
const OS_R2 = 'opensubs/v1/';
const OS_CACHE = 'https://cache.internal/opensubs-v1/';
const OS_RETRY = { none: 7 * 86400e3, quota: 6 * 3600e3, error: 3600e3 };
const OS_WAIT_MS = 2500;                            // 主列表最多等后台那一查这么久
const OS_LIST_WAIT_MS = 6000;                       // /api/subs 等得久一点（不挡起播）
const OS_STD_FPS = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60];
const OS_LANGS = {
  'zh-cn': { lang: 'zh-Hans', label: '简体中文（在线）', score: 40 },
  ze: { lang: 'zh-Hans', label: '简英双语（在线）', score: 34 },
  'zh-tw': { lang: 'zh-Hans', label: '简体中文（在线 · 繁转简）', score: 30, toSimp: true },
  en: { lang: 'en', label: 'English（在线）', score: -20 },      // 只在没有像样的中文时才用：有对齐以后，哈希不一致的中文也能对上时间
};
const OS_MEM = new Map();                           // 记录键 → 记录（进程内，最近 24 条）
const OS_BUSY = new Map();                          // 记录键 → 开始时刻（同一 isolate 不重复查）
const OS_NEED = new Map();                          // 字幕组合 → 要不要补（进程内）
let osAuth = null;                                  // { token, base, exp, user }

const osOn = env => !!(env && env.OPENSUBTITLES_API_KEY) && env.OPENSUBTITLES_DISABLE !== '1';
const osIdentity = (filePath, meta) => `${filePath}|${meta.content_hash || meta.rev || meta.size}`;

/* ── 繁 → 简（逐字；OpenCC TSCharacters，Apache-2.0，只收字形不同的 4105 对）──
   同一张表也拿来认一段中文是繁体还是简体：数两边各自独有的字 */
const ZH_T = `㑮㑯㑳㑶㒓㓄㓨㔋㖮㗲㗿㘉㘓㘔㘚㛝㜄㜏㜐㜗㜢㜷㞞㟺㠏㠣㢗㢝㥮㦎㦛㦞㨻㩋㩜㩳㩵㪎㯤㰙㵗㵾㶆㷍㷿㸇㹽㺏㺜㻶㿖㿗㿧䀉䀹䁪䁻䂎䃮䅐䅳䆉䉑䉙䉬䉲䉶䊭䊷䊺䋃䋔䋙䋚䋦䋹䋻䋼䋿䌈䌋䌖䌝䌟䌥䌰䍤䍦䍽䎙䎱䓣䕤䕳䖅䗅䗿䙔䙡䙱䚩䛄䛳䜀䜖䝭䝻䝼䞈䞋䞓䟃䟆䟐䠆䠱䡐䡩䡵䢨䤤䥄䥇䥑䥕䥗䥩䥯䥱䦘䦛䦟䦯䦳䧢䪊䪏䪗䪘䪴䪾䫀䫂䫟䫴䫶䫻䫾䬓䬘䬝䬞䬧䭀䭃䭑䭔䭿䮄䮝䮞䮠䮫䮰䮳䮾䯀䯤䰾䱀䱁䱙䱧䱬䱰䱷䱸䱽䲁䲅䲖䲘䲰䳜䳢䳤䳧䳫䴉䴋䴬䴱䴴䴽䵳䵴䶕䶲丟並乾亂亙亞佇佈佔併來侖侶侷俁係俓俔俠俥俬倀倆倈倉個們倖倫倲偉偑側偵偽傌傑傖傘備傢傭傯傳傴債傷傾僂僅僉僑僕僞僤僥僨僱價儀儁儂億儈儉儎儐儔儕儘償儣優儭儲儷儸儺儻儼兇兌兒兗內兩冊冑冪凈凍凙凜凱別刪剄則剋剎剗剛剝剮剴創剷剾劃劇劉劊劌劍劏劑劚勁勑動務勛勝勞勢勣勩勱勳勵勸勻匭匯匱區協卹卻卽厙厠厤厭厲厴參叄叢吒吳吶呂咼員哯唄唓唸問啓啞啟啢喎喚喪喫喬單喲嗆嗇嗊嗎嗚嗩嗰嗶嗹嘆嘍嘓嘔嘖嘗嘜嘩嘪嘮嘯嘰嘳嘵嘸嘺嘽噁噅噓噚噝噞噠噥噦噯噲噴噸噹嚀嚇嚌嚐嚕嚙嚛嚥嚦嚧嚨嚮嚲嚳嚴嚶嚽囀囁囂囃囅囈囉囌囑囒囪圇國圍園圓圖團圞垻埡埨埬埰執堅堊堖堚堝堯報場塊塋塏塒塗塚塢塤塵塸塹塿墊墜墠墮墰墲墳墶墻墾壇壈壋壎壓壗壘壙壚壜壞壟壠壢壣壩壪壯壺壼壽夠夢夥夾奐奧奩奪奬奮奼妝姍姦娙娛婁婡婦婭媈媧媯媰媼媽嫋嫗嫵嫺嫻嫿嬀嬃嬇嬈嬋嬌嬙嬡嬣嬤嬦嬪嬰嬸嬻孃孄孆孇孋孌孎孫學孻孾孿宮寀寠寢實寧審寫寬寵寶將專尋對導尷屆屍屓屜屢層屨屩屬岡峯峴島峽崍崑崗崙崢崬嵐嵗嵼嵽嵾嶁嶄嶇嶈嶔嶗嶘嶠嶢嶧嶨嶮嶸嶹嶺嶼嶽巊巋巒巔巖巗巘巰巹帥師帳帶幀幃幓幗幘幝幟幣幩幫幬幹幾庫廁廂廄廈廎廕廚廝廞廟廠廡廢廣廧廩廬廳弒弔弳張強彃彄彆彈彌彎彔彙彠彥彫彲彿後徑從徠復徵徹徿恆恥悅悞悵悶悽惡惱惲惻愛愜愨愴愷愻愾慄態慍慘慚慟慣慤慪慫慮慳慶慺慼慾憂憊憐憑憒憖憚憢憤憫憮憲憶憸憹懀懇應懌懍懎懞懟懣懤懨懲懶懷懸懺懼懾戀戇戔戧戩戰戱戲戶拋挩挱挾捨捫捱捲掃掄掆掗掙掚掛採揀揚換揮揯損搖搗搵搶摋摐摑摜摟摯摳摶摺摻撈撊撏撐撓撝撟撣撥撧撫撲撳撻撾撿擁擄擇擊擋擓擔據擟擠擣擫擬擯擰擱擲擴擷擺擻擼擽擾攄攆攋攏攔攖攙攛攜攝攢攣攤攪攬敎敓敗敘敵數斂斃斅斆斕斬斷斸於旂旣昇時晉晛晝暈暉暐暘暢暫曄曆曇曉曊曏曖曠曥曨曬書會朥朧朮東枴柵柺査桱桿梔梖梘梜條梟梲棄棊棖棗棟棡棧棲棶椏椲楇楊楓楨業極榘榦榪榮榲榿構槍槓槤槧槨槫槮槳槶槼樁樂樅樑樓標樞樠樢樣樤樧樫樳樸樹樺樿橈橋機橢橫橯檁檉檔檜檟檢檣檭檮檯檳檵檸檻櫃櫅櫍櫓櫚櫛櫝櫞櫟櫠櫥櫧櫨櫪櫫櫬櫱櫳櫸櫻欄欅欇權欍欏欐欑欒欓欖欘欞欽歎歐歟歡歲歷歸歿殘殞殢殤殨殫殭殮殯殰殲殺殻殼毀毆毊毿氂氈氌氣氫氬氭氳氾汎汙決沒沖況泝洩洶浹浿涇涗涼淒淚淥淨淩淪淵淶淺渙減渢渦測渾湊湋湞湧湯溈準溝溡溫溮溳溼滄滅滌滎滙滬滯滲滷滸滻滾滿漁漊漍漚漢漣漬漲漵漸漿潁潑潔潕潙潚潛潣潤潯潰潷潿澀澅澆澇澐澗澠澤澦澩澫澬澮澱澾濁濃濄濆濕濘濚濛濜濟濤濧濫濰濱濺濼濾濿瀂瀃瀅瀆瀇瀉瀋瀏瀕瀘瀝瀟瀠瀦瀧瀨瀰瀲瀾灃灄灍灑灒灕灘灙灝灡灣灤灧灩災為烏烴無煇煉煒煙煢煥煩煬煱熂熅熉熌熒熓熗熚熡熰熱熲熾燀燁燈燉燒燖燙燜營燦燬燭燴燶燻燼燾爃爄爇爍爐爖爛爥爧爭爲爺爾牀牆牘牽犖犛犞犢犧狀狹狽猌猙猶猻獁獃獄獅獊獎獨獩獪獫獮獰獱獲獵獷獸獺獻獼玀玁珼現琱琺琿瑋瑒瑣瑤瑩瑪瑲瑻瑽璉璊璕璗璝璡璣璦璫璯環璵璸璼璽璾璿瓄瓅瓊瓏瓔瓕瓚瓛甌甕產産甦甯畝畢畫異畵當畼疇疊痙痠痮痾瘂瘋瘍瘓瘞瘡瘧瘮瘱瘲瘺瘻療癆癇癉癐癒癘癟癡癢癤癥癧癩癬癭癮癰癱癲發皁皚皟皰皸皺盃盜盞盡監盤盧盨盪眝眞眥眾睍睏睜睞瞘瞜瞞瞤瞶瞼矇矉矑矓矚矯硃硜硤硨硯碕碙碩碭碸確碼碽磑磚磠磣磧磯磽磾礄礆礎礐礒礙礦礪礫礬礮礱祕祿禍禎禕禡禦禪禮禰禱禿秈稅稈稏稜稟種稱穀穇穌積穎穠穡穢穩穫穭窩窪窮窯窵窶窺竄竅竇竈竊竚竪竱競筆筍筧筴箇箋箏節範築篋篔篘篠篢篤篩篳篸簀簂簍簑簞簡簢簣簫簹簽簾籃籅籋籌籔籙籛籜籟籠籤籩籪籬籮籲粵糉糝糞糧糰糲糴糶糹糺糾紀紂紃約紅紆紇紈紉紋納紐紓純紕紖紗紘紙級紛紜紝紞紟紡紬紮細紱紲紳紵紹紺紼紿絀絁終絃組絅絆絍絎結絕絙絛絝絞絡絢絥給絧絨絪絰統絲絳絶絹絺綀綁綃綄綆綇綈綉綋綌綎綏綐綑經綖綜綝綞綟綠綡綢綣綧綪綫綬維綯綰綱網綳綴綵綸綹綺綻綽綾綿緄緇緊緋緍緑緒緓緔緗緘緙線緝緞緟締緡緣緤緦編緩緬緮緯緰緱緲練緶緷緸緹緻緼縈縉縊縋縍縎縐縑縕縗縛縝縞縟縣縧縫縬縭縮縯縰縱縲縳縴縵縶縷縸縹縺總績繂繃繅繆繈繏繐繒繓織繕繚繞繟繡繢繨繩繪繫繬繭繮繯繰繳繶繷繸繹繻繼繽繾繿纁纆纇纈纊續纍纏纓纔纕纖纗纘纚纜缽罃罈罌罎罰罵罷羅羆羈羋羣羥羨義羵羶習翫翬翹翽耬耮聖聞聯聰聲聳聵聶職聹聻聽聾肅脅脈脛脣脥脩脫脹腎腖腡腦腪腫腳腸膃膕膚膞膠膢膩膹膽膾膿臉臍臏臗臘臚臟臠臢臥臨臺與興舉舊舘艙艣艤艦艫艱艷芻苧茲荊莊莖莢莧菕華菴菸萇萊萬萴萵葉葒葝葤葦葯葷蒍蒐蒓蒔蒕蒞蒭蒼蓀蓆蓋蓧蓮蓯蓴蓽蔄蔔蔘蔞蔣蔥蔦蔭蔯蔿蕁蕆蕎蕒蕓蕕蕘蕝蕢蕩蕪蕭蕳蕷蕽薀薆薈薊薌薑薔薘薟薦薩薳薴薵薹薺藍藎藝藥藪藭藴藶藷藹藺蘀蘄蘆蘇蘊蘋蘚蘞蘟蘢蘭蘺蘿虆虉處虛虜號虧虯蛺蛻蜆蝀蝕蝟蝦蝨蝸螄螞螢螮螻螿蟂蟄蟈蟎蟘蟜蟣蟬蟯蟲蟳蟶蟻蠀蠁蠅蠆蠍蠐蠑蠔蠙蠟蠣蠦蠨蠱蠶蠻蠾衆衊術衕衚衛衝袞裊裏補裝裡製複褌褘褲褳褸褻襀襇襉襏襓襖襗襘襝襠襤襪襬襯襰襲襴襵覈見覎規覓視覘覛覡覥覦親覬覯覲覷覹覺覼覽覿觀觴觶觸訁訂訃計訊訌討訏訐訑訒訓訕訖託記訛訜訝訞訟訢訣訥訨訩訪設許訴訶診註証詀詁詆詊詎詐詑詒詓詔評詖詗詘詛詝詞詠詡詢詣試詩詪詫詬詭詮詰話該詳詵詷詼詿誂誄誅誆誇誋誌認誑誒誕誘誚語誠誡誣誤誥誦誨說誫説誰課誳誴誶誷誹誺誼誾調諂諄談諉請諍諏諑諒諓論諗諛諜諝諞諟諡諢諣諤諥諦諧諫諭諮諯諰諱諲諳諴諶諷諸諺諼諾謀謁謂謄謅謆謉謊謎謏謐謔謖謗謙謚講謝謠謡謨謫謬謭謯謱謳謸謹謾譁譂譅譆證譊譎譏譑譓譖識譙譚譜譞譟譨譫譭譯議譴護譸譽譾讀讅變讋讌讎讒讓讕讖讚讜讞豈豎豐豔豬豵豶貓貗貙貝貞貟負財貢貧貨販貪貫責貯貰貲貳貴貶買貸貺費貼貽貿賀賁賂賃賄賅資賈賊賑賒賓賕賙賚賜賝賞賟賠賡賢賣賤賦賧質賫賬賭賰賴賵賺賻購賽賾贃贄贅贇贈贉贊贋贍贏贐贑贓贔贖贗贚贛贜赬趕趙趨趲跡踐踰踴蹌蹔蹕蹟蹠蹣蹤蹳蹺蹻躂躉躊躋躍躎躑躒躓躕躘躚躝躡躥躦躪軀軉車軋軌軍軏軑軒軔軕軗軛軜軝軟軤軨軫軬軲軷軸軹軺軻軼軾軿較輄輅輇輈載輊輋輒輓輔輕輖輗輛輜輝輞輟輢輥輦輨輩輪輬輮輯輳輶輷輸輻輼輾輿轀轂轄轅轆轇轉轊轍轎轐轔轗轟轠轡轢轣轤辦辭辮辯農迴逕這連週進遊運過達違遙遜遞遠遡適遱遲遷選遺遼邁還邇邊邏邐郟郵鄆鄉鄒鄔鄖鄟鄧鄩鄭鄰鄲鄳鄴鄶鄺酇酈醃醖醜醞醟醣醫醬醱醲醶釀釁釃釅釋釐釒釓釔釕釗釘釙釚針釟釣釤釦釧釨釩釲釳釴釵釷釹釺釾釿鈀鈁鈃鈄鈅鈆鈇鈈鈉鈋鈍鈎鈐鈑鈒鈔鈕鈖鈗鈛鈞鈠鈡鈣鈥鈦鈧鈮鈯鈰鈲鈳鈴鈷鈸鈹鈺鈽鈾鈿鉀鉁鉅鉆鉈鉉鉊鉋鉍鉑鉔鉕鉗鉚鉛鉝鉞鉠鉢鉤鉥鉦鉧鉬鉭鉮鉳鉶鉷鉸鉺鉻鉽鉾鉿銀銁銂銃銅銈銊銍銏銑銓銖銘銚銛銜銠銣銥銦銨銩銪銫銬銱銳銶銷銹銻銼鋁鋂鋃鋅鋇鋉鋌鋏鋐鋒鋗鋙鋝鋟鋠鋣鋤鋥鋦鋨鋩鋪鋭鋮鋯鋰鋱鋶鋸鋹鋼錀錁錂錄錆錇錈錏錐錒錕錘錙錚錛錜錝錞錟錠錡錢錤錥錦錨錩錫錮錯録錳錶錸錼錽鍀鍁鍃鍄鍅鍆鍇鍈鍉鍊鍋鍍鍒鍔鍘鍚鍛鍠鍤鍥鍩鍬鍭鍮鍰鍵鍶鍺鍼鍾鎂鎄鎇鎈鎊鎌鎍鎓鎔鎖鎘鎙鎚鎛鎝鎞鎡鎢鎣鎦鎧鎩鎪鎬鎭鎮鎯鎰鎲鎳鎵鎶鎷鎸鎿鏃鏆鏇鏈鏉鏌鏍鏏鏐鏑鏗鏘鏚鏜鏝鏞鏟鏡鏢鏤鏥鏦鏨鏰鏵鏷鏹鏺鏻鏽鏾鐃鐄鐇鐈鐋鐍鐎鐏鐐鐒鐓鐔鐘鐙鐝鐠鐥鐦鐧鐨鐩鐪鐫鐮鐯鐲鐳鐵鐶鐸鐺鐼鐽鐿鑀鑄鑉鑊鑌鑑鑒鑔鑕鑞鑠鑣鑥鑪鑭鑰鑱鑲鑴鑷鑹鑼鑽鑾鑿钁钂長門閂閃閆閈閉開閌閍閎閏閐閑閒間閔閗閘閝閞閡閣閤閥閨閩閫閬閭閱閲閵閶閹閻閼閽閾閿闃闆闇闈闉闊闋闌闍闐闑闒闓闔闕闖關闞闠闡闢闤闥陘陝陞陣陰陳陸陽隉隊階隑隕際隤隨險隮隯隱隴隸隻雋雖雙雛雜雞離難雲電霑霢霣霧霼霽靂靄靆靈靉靚靜靝靦靧靨鞏鞝鞦鞽鞾韁韃韆韉韋韌韍韓韙韚韛韜韝韞韠韻響頁頂頃項順頇須頊頌頍頎頏預頑頒頓頔頗領頜頠頡頤頦頫頭頮頰頲頴頵頷頸頹頻頽顂顃顅顆題額顎顏顒顓顔顗願顙顛類顢顣顥顧顫顬顯顰顱顳顴風颭颮颯颰颱颳颶颷颸颺颻颼颾飀飄飆飈飋飛飠飢飣飥飦飩飪飫飭飯飱飲飴飵飶飼飽飾飿餃餄餅餈餉養餌餎餏餑餒餓餔餕餖餗餘餚餛餜餞餡餦餧館餪餫餬餭餱餳餵餶餷餸餺餼餾餿饁饃饅饈饉饊饋饌饑饒饗饘饜饞饟饠饢馬馭馮馯馱馳馴馹馼駁駃駉駊駎駐駑駒駓駔駕駘駙駚駛駝駞駟駡駢駤駧駩駪駫駭駰駱駶駸駻駼駿騁騂騃騄騅騉騊騌騍騎騏騑騔騖騙騚騜騝騞騟騠騤騧騪騫騭騮騰騱騴騵騶騷騸騻騼騾驀驁驂驃驄驅驊驋驌驍驎驏驓驕驗驙驚驛驟驢驤驥驦驨驪驫骯髏髒體髕髖髮鬆鬍鬖鬚鬠鬢鬥鬧鬨鬩鬮鬱鬹魎魘魚魛魟魢魥魦魨魯魴魵魷魺魽鮀鮁鮃鮄鮅鮆鮈鮊鮋鮍鮎鮐鮑鮒鮓鮚鮜鮝鮞鮟鮠鮡鮣鮤鮦鮪鮫鮭鮮鮯鮰鮳鮵鮶鮸鮺鮿鯀鯁鯄鯆鯇鯉鯊鯒鯔鯕鯖鯗鯛鯝鯞鯡鯢鯤鯧鯨鯪鯫鯬鯰鯱鯴鯶鯷鯻鯽鯾鯿鰁鰂鰃鰆鰈鰉鰊鰋鰌鰍鰏鰐鰑鰒鰓鰕鰛鰜鰟鰠鰣鰤鰥鰦鰧鰨鰩鰫鰭鰮鰱鰲鰳鰵鰶鰷鰹鰺鰻鰼鰽鰾鱀鱂鱄鱅鱆鱇鱈鱉鱊鱒鱔鱖鱗鱘鱚鱝鱟鱠鱢鱣鱤鱧鱨鱭鱮鱯鱲鱷鱸鱺鳥鳧鳩鳬鳲鳳鳴鳶鳷鳼鳽鳾鴀鴃鴅鴆鴇鴉鴐鴒鴔鴕鴗鴛鴜鴝鴞鴟鴣鴥鴦鴨鴮鴯鴰鴲鴳鴴鴷鴻鴽鴿鵁鵂鵃鵊鵏鵐鵑鵒鵓鵚鵜鵝鵟鵠鵡鵧鵩鵪鵫鵬鵮鵯鵰鵲鵷鵾鶄鶇鶉鶊鶌鶒鶓鶖鶗鶘鶚鶠鶡鶥鶦鶩鶪鶬鶭鶯鶰鶱鶲鶴鶹鶺鶻鶼鶿鷀鷁鷂鷄鷅鷉鷊鷐鷓鷔鷖鷗鷙鷚鷟鷣鷤鷥鷦鷨鷩鷫鷭鷯鷲鷳鷴鷷鷸鷹鷺鷽鷿鸂鸇鸊鸋鸌鸏鸑鸕鸗鸘鸚鸛鸝鸞鹵鹹鹺鹼鹽麗麥麨麩麪麫麬麯麲麳麴麵麷麼麽黃黌點黨黲黴黶黷黽黿鼂鼉鼕鼴齊齋齎齏齒齔齕齗齘齙齜齟齠齡齣齦齧齩齪齬齭齮齯齰齲齴齶齷齼齾龍龎龐龑龓龔龕龜龭龯鿁鿓𠁞𠌥𠏢𠐊𠗣𠞆𠠎𠬙𠽃𠿕𡂡𡃄𡃕𡃤𡄔𡄣𡅏𡅯𡑍𡑭𡓁𡓾𡔖𡞵𡟫𡠹𡢃𡮉𡮣𡳳𡸗𡹬𡻕𡽗𡾱𡿖𢍰𢠼𢣐𢣚𢣭𢤩𢤱𢤿𢯷𢶒𢶫𢷮𢹿𢺳𣈶𣋋𣍐𣙎𣜬𣝕𣞻𣠩𣠲𣯩𣯴𣯶𣽏𣾷𣿉𤁣𤄷𤅶𤑳𤑹𤒎𤒻𤓌𤓎𤓩𤘀𤛮𤛱𤜆𤠮𤢟𤢻𤩂𤪺𤫩𤬅𤳷𤳸𤷃𤸫𤺔𥊝𥌃𥏝𥕥𥖅𥖲𥗇𥗽𥜐𥜰𥞵𥢢𥢶𥢷𥨐𥪂𥯤𥴨𥴼𥵃𥵊𥶽𥸠𥻦𥼽𥽖𥾯𥿊𦀖𦂅𦃄𦃩𦅇𦅈𦆲𦒀𦔖𦘧𦟼𦠅𦡝𦢈𦣎𦧺𦪙𦪽𦱌𦾟𧎈𧒯𧔥𧕟𧜗𧜵𧝞𧞫𧟀𧡴𧢄𧦝𧦧𧩕𧩙𧩼𧫝𧬤𧭈𧭹𧳟𧵳𧶔𧶧𧷎𧸘𧹈𧽯𨂐𨄣𨅍𨆪𨇁𨇞𨇤𨇰𨇽𨈊𨈌𨊰𨊸𨊻𨋢𨌈𨍰𨎌𨎮𨏠𨏥𨞺𨟊𨢿𨣈𨣞𨣧𨤻𨥛𨥟𨦫𨧀𨧜𨧰𨧱𨨏𨨛𨨢𨩰𨪕𨫒𨬖𨭆𨭎𨭖𨭸𨮂𨮳𨯅𨯟𨰃𨰋𨰥𨰲𨲳𨳑𨳕𨴗𨴹𨵩𨵸𨶀𨶏𨶮𨶲𨷲𨼳𨽏𩀨𩅙𩎖𩎢𩏂𩏠𩏪𩏷𩑔𩒎𩓣𩓥𩔑𩔳𩖰𩗀𩗓𩗴𩘀𩘝𩘹𩘺𩙈𩚛𩚥𩚩𩚵𩛆𩛌𩛡𩛩𩜇𩜦𩜵𩝔𩝽𩞄𩞦𩞯𩟐𩟗𩠴𩡣𩡺𩢡𩢴𩢸𩢾𩣏𩣑𩣫𩣵𩣺𩤊𩤙𩤲𩤸𩥄𩥇𩥉𩥑𩦠𩧆𩭙𩯁𩯳𩰀𩰹𩳤𩴵𩵦𩵩𩵹𩶁𩶘𩶰𩶱𩷰𩸃𩸄𩸡𩸦𩻗𩻬𩻮𩼶𩽇𩿅𩿤𩿪𪀖𪀦𪀾𪁈𪁖𪂆𪃍𪃏𪃒𪃧𪄆𪄕𪅂𪆷𪇳𪈼𪉸𪋿𪌭𪍠𪓰𪔵𪘀𪘯𪙏𪟖𪷓𫒡𫜦`;
const ZH_S = `𫝈㑔㑇㐹𠉂𪠟刾𪟎𪠵𠵾𪡛𠰱𪢌𫬐㘎𫝦㚯㛣𫝧𡞋𡞱𡝠𪨊𪩇㟆𫵷𪪑𢋈㤘𢛯𢗓𪫷𪮃𪮋㨫㧐擜𪯋𣘐𣗙𣳆𪷍𫞛𤆢𤈷𤎺𫞣𤠋𪺻𪼋𪽮𤻊𤽯𥁢𥅴𥇢䀥𥎝鿎𫀨𫀬𫁂𫁲𥬀𫂈𥮜𫁷𥺅䌶𫄚𫄜𫄞䌺䌻𫄩䌿䌾𫄮𦈓𦈖𦈘𦈜𦈟𦈞𦈠𦈙𫅅䍠𦍠𫅭䎬𬜯𫟕𦰴𫟑𫊪𧉞𫋲䙌𧜭𫌯𫍠𫍫䜧𫟢𫎧𧹕䞍𧹑𫎪𫎭𫎺𫎳𫎱𫏃𨅛𫟤𫟥𫟦𨑹𫟺𫠀䦂鿏𬭯𫔋𨱖𫔆䥾𨸄䦶䦷𫔵𨷿𨸟𫖅𩏼𩐀𩏿𫖫𫖬𫖱𫖰𫖲𩖗𫖺𫗇𫠈𫗊𩙮𩙯𩙧𫗟𩠇𩠈𫗱𫗰𩧭𫠊𩧰𩨁𩧿𩨇𫘮𩨏𩧪䯅𩩈鲃𫚐𫚏𩾈𫚠𩾊𩾋䲣𫠑䲝鳚𫚜𩾂鳤𪉂𫛬𫛰𫛮𫛺𫛼鹮𫜅𪎈𫜒𪎋𫜔𪑅𫜙𫜨𫜳丢并干乱亘亚伫布占并来仑侣局俣系𠇹伣侠伡私伥俩俫仓个们幸伦㑈伟㐽侧侦伪㐷杰伧伞备家佣偬传伛债伤倾偻仅佥侨仆伪𫢸侥偾雇价仪俊侬亿侩俭傤傧俦侪尽偿𠆲优𠋆储俪㑩傩傥俨凶兑儿兖内两册胄幂净冻𪞝凛凯别删刭则克刹刬刚剥剐剀创铲𠛅划剧刘刽刿剑㓥剂㔉劲𠡠动务勋胜劳势𪟝勚劢勋励劝匀匦汇匮区协恤却即厍厕历厌厉厣参叁丛咤吴呐吕呙员𠯟呗𪠳念问启哑启唡㖞唤丧吃乔单哟呛啬唝吗呜唢𠮶哔𪡏叹喽啯呕啧尝唛哗𪡃唠啸叽𪡞哓呒𪡀啴恶𠯠嘘㖊咝𪡋哒哝哕嗳哙喷吨当咛吓哜尝噜啮𪠸咽呖𠰷咙向亸喾严嘤𪢕啭嗫嚣𠱞冁呓啰苏嘱𪢠囱囵国围园圆图团𪢮坝垭𫭢𪣆采执坚垩垴𪣒埚尧报场块茔垲埘涂冢坞埙尘𫭟堑𪣻垫坠𫮃堕坛𪢸坟垯墙垦坛𡒄垱埙压𡋤垒圹垆坛坏垄垅坜𪤚坝塆壮壶壸寿够梦伙夹奂奥奁夺奖奋姹妆姗奸𫰛娱娄𫝫妇娅𫝨娲妫㛀媪妈袅妪妩娴娴婳妫媭𫝬娆婵娇嫱嫒𪥰嬷𫝩嫔婴婶𪥿娘𫝮𫝭𪥫㛤娈𡠟孙学𡥧𪧀孪宫采𪧘寝实宁审写宽宠宝将专寻对导尴届尸屃屉屡层屦𪨗属冈峰岘岛峡崃昆岗仑峥岽岚岁𡶴𫶇㟥嵝崭岖𡺃嵚崂𡺄峤峣峄峃崄嵘𫝵岭屿岳𪩎岿峦巅岩𪨷𪩘巯卺帅师帐带帧帏㡎帼帻𪩷帜币𪩸帮帱干几库厕厢厩厦庼荫厨厮𫷷庙厂庑废广𪪞廪庐厅弑吊弪张强𪪼𫸩别弹弥弯录汇彟彦雕彨佛后径从徕复征彻𪫌恒耻悦悮怅闷凄恶恼恽恻爱惬悫怆恺𢙏忾栗态愠惨惭恸惯悫怄怂虑悭庆㥪戚欲忧惫怜凭愦慭惮𢙒愤悯怃宪忆𪫺𢙐𢙓恳应怿懔𢠁蒙怼懑㤽恹惩懒怀悬忏惧慑恋戆戋戗戬战戯戏户抛捝挲挟舍扪挨卷扫抡㧏挜挣𪭵挂采拣扬换挥搄损摇捣揾抢𢫬𪭢掴掼搂挚抠抟折掺捞𪭾挦撑挠㧑挢掸拨𪮖抚扑揿挞挝捡拥掳择击挡㧟担据𪭧挤捣𢬍拟摈拧搁掷扩撷摆擞撸㧰扰摅撵𪮶拢拦撄搀撺携摄攒挛摊搅揽教敚败叙敌数敛毙𢽾敩斓斩断𣃁于旗既升时晋𬀪昼晕晖𬀩旸畅暂晔历昙晓𪰶向暧旷𣆐昽晒书会𦛨胧术东拐栅拐查𣐕杆栀𪱷枧𬂩条枭棁弃棋枨枣栋㭎栈栖梾桠㭏𣒌杨枫桢业极矩干杩荣榅桤构枪杠梿椠椁𣏢椮桨椢椝桩乐枞梁楼标枢𣗊㭤样𣔌榝㭴桪朴树桦椫桡桥机椭横𣓿檩柽档桧槚检樯𣘴梼台槟𪲛柠槛柜𪲎𬃊橹榈栉椟橼栎𪲮橱槠栌枥橥榇蘖栊榉樱栏榉𪳍权𣐤椤𪲔𪴙栾𣗋榄𣚚棂钦叹欧欤欢岁历归殁残殒𣨼殇㱮殚僵殓殡㱩歼杀壳壳毁殴𪵑毵牦毡氇气氢氩𣱝氲泛泛污决没冲况溯泄汹浃𬇙泾涚凉凄泪渌净凌沦渊涞浅涣减沨涡测浑凑𣲗浈涌汤沩准沟𪶄温浉涢湿沧灭涤荥汇沪滞渗卤浒浐滚满渔溇𬇹沤汉涟渍涨溆渐浆颍泼洁𣲘沩㴋潜𫞗润浔溃滗涠涩𣶩浇涝沄涧渑泽滪泶𬇕𫞚浍淀㳠浊浓㳡𣸣湿泞溁蒙浕济涛㳔滥潍滨溅泺滤𪵱澛𣽷滢渎㲿泻沈浏濒泸沥潇潆潴泷濑弥潋澜沣滠𫞝洒𪷽漓滩𣺼灏㳕湾滦滟滟灾为乌烃无𪸩炼炜烟茕焕烦炀㶽𪸕煴𤈶𤇄荧𤆡炝𤇹𤋏𬉼热颎炽𬊤烨灯炖烧𬊈烫焖营灿毁烛烩㶶熏烬焘𫞡𤇃𦶟烁炉𤇭烂𪹳𫞠争为爷尔床墙牍牵荦牦𪺭犊牺状狭狈𪺽狰犹狲犸呆狱狮𪺷奖独𤞃狯猃狝狞㺍获猎犷兽獭献猕猡𤞤𫞥现雕珐珲玮玚琐瑶莹玛玱𪻲𪻐琏𫞩𬍤𬍡𪻺琎玑瑷珰㻅环玙瑸𫞨玺𫞦璇𪻨𬍛琼珑璎𤦀瓒𤩽瓯瓮产产苏宁亩毕画异画当𪽈畴叠痉酸𪽪疴痖疯疡痪瘗疮疟瘆𪽷疭瘘瘘疗痨痫瘅𤶊愈疠瘪痴痒疖症疬癞癣瘿瘾痈瘫癫发皂皑𤾀疱皲皱杯盗盏尽监盘卢𪾔荡𪾣真眦众𪾢困睁睐眍䁖瞒𥆧瞆睑蒙𪾸𪾦眬瞩矫朱硁硖砗砚埼𥐻硕砀砜确码䂵硙砖硵碜碛矶硗䃅硚硷础𬒈𥐟碍矿砺砾矾𪿫砻秘禄祸祯祎祃御禅礼祢祷秃籼税秆䅉棱禀种称谷䅟稣积颖秾穑秽稳获穞窝洼穷窑窎窭窥窜窍窦灶窃𥩟竖𫁟竞笔笋笕䇲个笺筝节范筑箧筼𥬠筿𬕂笃筛筚𥮾箦𫂆篓蓑箪简𫂃篑箫筜签帘篮𥫣𥬞筹䉤箓篯箨籁笼签笾簖篱箩吁粤粽糁粪粮团粝籴粜纟𫄙纠纪纣𬘓约红纡纥纨纫纹纳纽纾纯纰纼纱纮纸级纷纭纴𬘘𫄛纺䌷扎细绂绁绅纻绍绀绋绐绌𫄟终弦组䌹绊𫟃绗结绝𫄠绦绔绞络绚𫄢给𫄡绒𬘡绖统丝绛绝绢𫄨𦈌绑绡𬘫绠𦈋绨绣𫟄绤𬘩绥䌼捆经𫄧综𬘭缍𫄫绿𫟅绸绻𬘯𬘬线绶维绹绾纲网绷缀彩纶绺绮绽绰绫绵绲缁紧绯𦈏绿绪绬绱缃缄缂线缉缎𫟆缔缗缘𫄬缌编缓缅𫄭纬𦈕缑缈练缏𦈉𦈑缇致缊萦缙缢缒𫄰𦈔绉缣缊缞缚缜缟缛县绦缝𦈚缡缩𬙂𫄳纵缧䌸纤缦絷缕𫄲缥𦈐总绩𫄴绷缫缪𫄶𦈝𰬸缯𦈛织缮缭绕𦈎绣缋𫄤绳绘系𫄱茧缰缳缲缴𫄷𫄣䍁绎𦈡继缤缱䍀𫄸𬙊颣缬纩续累缠缨才𬙋纤𫄹缵𫄥缆钵䓨坛罂坛罚骂罢罗罴羁芈群羟羡义𫅗膻习玩翚翘翙耧耢圣闻联聪声耸聩聂职聍𫆏听聋肃胁脉胫唇𣍰修脱胀肾胨脶脑𣍯肿脚肠腽腘肤䏝胶𦝼腻𪱥胆脍脓脸脐膑𣎑腊胪脏脔臜卧临台与兴举旧馆舱𫇛舣舰舻艰艳刍苎兹荆庄茎荚苋𰰨华庵烟苌莱万荝莴叶荭𫈎荮苇药荤𫇭搜莼莳蒀莅𫇴苍荪席盖𦰏莲苁莼荜𬜬卜参蒌蒋葱茑荫𫈟𫇭荨蒇荞荬芸莸荛𫈵蒉荡芜萧𫈉蓣𫇽蕰𫉁荟蓟芗姜蔷荙莶荐萨䓕苧䓓苔荠蓝荩艺药薮䓖蕴苈𫉄蔼蔺萚蕲芦苏蕴苹藓蔹𦻕茏兰蓠萝蔂𬟁处虚虏号亏虬蛱蜕蚬𬟽蚀猬虾虱蜗蛳蚂萤䗖蝼螀𫋇蛰蝈螨𫋌𫊸虮蝉蛲虫𫊻蛏蚁𧏗蚃蝇虿蝎蛴蝾蚝𧏖蜡蛎𫊮蟏蛊蚕蛮𧑏众蔑术同胡卫冲衮袅里补装里制复裈袆裤裢褛亵𫌀裥裥袯𫋹袄𫋷𫋻裣裆褴袜摆衬𧝝袭襕𫌇核见觃规觅视觇𫌪觋觍觎亲觊觏觐觑𫌭觉𫌨览觌观觞觯触讠订讣计讯讧讨𬣙讦𫍙讱训讪讫托记讹𫍛讶𫍚讼䜣诀讷𫟞讻访设许诉诃诊注证𧮪诂诋𫟟讵诈𫍡诒𫍜诏评诐诇诎诅𬣞词咏诩询诣试诗𬣳诧诟诡诠诘话该详诜𫍣诙诖𫍥诔诛诓夸𫍪志认诳诶诞诱诮语诚诫诬误诰诵诲说𫍨说谁课𫍮𫟡谇𫍬诽𫍧谊訚调谄谆谈诿请诤诹诼谅𬣡论谂谀谍谞谝𬤊谥诨𫍩谔𫍳谛谐谏谕咨𫍱𫍰讳𬤇谙𫍯谌讽诸谚谖诺谋谒谓誊诌𫍸𫍷谎谜𫍲谧谑谡谤谦谥讲谢谣谣谟谪谬谫𫍹𫍴讴𫍵谨谩哗𫟠𰶎𫍻证𫍢谲讥𫍤𬤝谮识谯谭谱𫍽噪𫍦谵毁译议谴护诪誉谫读谉变詟䜩雠谗让谰谶赞谠谳岂竖丰艳猪𫎆豮猫𫎌䝙贝贞贠负财贡贫货贩贪贯责贮贳赀贰贵贬买贷贶费贴贻贸贺贲赂赁贿赅资贾贼赈赊宾赇赒赉赐𫎩赏𧹖赔赓贤卖贱赋赕质赍账赌䞐赖赗赚赙购赛赜𧹗贽赘赟赠𫎫赞赝赡赢赆𫎬赃赑赎赝𫎦赣赃赪赶赵趋趱迹践逾踊跄𫏐跸迹跖蹒踪𫏆跷𫏋跶趸踌跻跃䟢踯跞踬蹰𨀁跹𨅬蹑蹿躜躏躯𨉗车轧轨军𫐄轪轩轫𫐅𨐅轭𫐇𬨂软轷𫐉轸𫐊轱𫐈轴轵轺轲轶轼𫐌较𨐈辂辁辀载轾𪨶辄挽辅轻𫐏𫐐辆辎辉辋辍𫐎辊辇𫐑辈轮辌𫐓辑辏𬨎𫐒输辐辒辗舆辒毂辖辕辘𫐖转𫐕辙轿𫐗辚𫐘轰𫐙辔轹𫐆轳办辞辫辩农回迳这连周进游运过达违遥逊递远溯适𫐷迟迁选遗辽迈还迩边逻逦郏邮郓乡邹邬郧𫑘邓𬩽郑邻郸𫑡邺郐邝酂郦腌酝丑酝蒏糖医酱酦𬪩𫑷酿衅酾酽释厘钅钆钇钌钊钉钋𫟲针𫓥钓钐扣钏𫓦钒𫟳𨰿𬬩钗钍钕钎䥺𬬱钯钫钘钭钥𫓪𫓧钚钠𨱂钝钩钤钣钑钞钮𫟴𫟵𫓨钧𨱁钟钙钬钛钪铌𨱄铈𨱃钶铃钴钹铍钰钸铀钿钾𨱅巨钻铊铉𬬿铇铋铂𫓬钷钳铆铅𫟷钺𫓭钵钩𬬸钲𬭁钼钽𬬹锫铏𫟹铰铒铬𫟸𫓴铪银𫓲𫟻铳铜𫓯𫓰铚𫟶铣铨铢铭铫铦衔铑铷铱铟铵铥铕铯铐铞锐𨱇销锈锑锉铝𰾄锒锌钡𨱈铤铗𬭎锋𫓶铻锊锓𫓵铘锄锃锔锇铓铺锐铖锆锂铽锍锯𬬮钢𬬭锞𨱋录锖锫锩铔锥锕锟锤锱铮锛𫓻𫓽𬭚锬锭锜钱𫓹𫓾锦锚锠锡锢错录锰表铼镎𫓸锝锨锪𨱉钫钔锴锳𫔂炼锅镀𫔄锷铡钖锻锽锸锲锘锹𬭤𨱎锾键锶锗针钟镁锿镅𫟿镑镰𫔅𬭩镕锁镉𫔈锤镈𨱏𫔇镃钨蓥镏铠铩锼镐镇镇𨱍镒镋镍镓鿔𨰾镌镎镞𨱌旋链𨱒镆镙𬭬镠镝铿锵𬭭镗镘镛铲镜镖镂𫔊𫓩錾镚铧镤镪䥽𬭸锈𫔌铙𨱑𫔍𫓱铴𫔎𨱓𨱔镣铹镦镡钟镫镢镨䦅锎锏镄𬭼𫓺镌镰䦃镯镭铁镮铎铛𫔁𫟼镱𰾭铸𫠁镬镔鉴鉴镲锧镴铄镳镥𬬻镧钥镵镶𫔔镊镩锣钻銮凿镢镋长门闩闪闫闬闭开闶𨸂闳闰𨸃闲闲间闵𫔯闸𫠂𫔰阂阁合阀闺闽阃阆闾阅阅𫔴阊阉阎阏阍阈阌阒板暗闱𬮱阔阕阑阇阗𫔶阘闿阖阙闯关阚阓阐辟阛闼陉陕升阵阴陈陆阳陧队阶𬮿陨际𬯎随险𬯀陦隐陇隶只隽虽双雏杂鸡离难云电沾霡𫕥雾𪵣霁雳霭叇灵叆靓静靔腼𫖃靥巩绱秋鞒𫖇缰鞑千鞯韦韧韨韩韪𫠅𫖔韬鞲韫𫖒韵响页顶顷项顺顸须顼颂𫠆颀颃预顽颁顿𬱖颇领颌𬱟颉颐颏𫖯头颒颊颋颕𫖳颔颈颓频颓𩓋𩖖𫖶颗题额颚颜颙颛颜𫖮愿颡颠类颟𫖹颢顾颤颥显颦颅颞颧风飐飑飒𩙥台刮飓𩙪飔飏飖飕𩙫飗飘飙飚𫗋飞饣饥饤饦𫗞饨饪饫饬饭飧饮饴𫗢𫗣饲饱饰饳饺饸饼糍饷养饵饹饻饽馁饿𫗦馂饾𫗧余肴馄馃饯馅𫗠𫗪馆𫗬𫗥糊𫗮糇饧喂馉馇𩠌馎饩馏馊馌馍馒馐馑馓馈馔饥饶飨𫗴餍馋𫗵𫗩馕马驭冯𫘛驮驰驯驲𫘜驳𫘝𬳶𫘟𩧨驻驽驹𬳵驵驾骀驸𩧫驶驼𫘞驷骂骈𫘠𩧲𩧴𬳽𫘡骇骃骆𩧺骎𫘣𬳿骏骋骍𫘤𫘧骓𫘥𫘦骔骒骑骐𬴂𩨀骛骗𩨊𫘩𩨃𬴃𩨈𫘨骙䯄𩨄骞骘骝腾𫘬𫘫𫘪驺骚骟𫘭𫠋骡蓦骜骖骠骢驱骅𩧯骕骁𬴊骣𫘯骄验𫘰惊驿骤驴骧骥骦𫘱骊骉肮髅脏体髌髋发松胡𩭹须𫘽鬓斗闹哄阋阄郁鬶魉魇鱼鱽𫚉鱾𩽹𫚌鲀鲁鲂𫚍鱿鲄𫠐𬶍鲅鲆𫚒𫚑𫚖𬶋鲌鲉鲏鲇鲐鲍鲋鲊鲒鲘鲞鲕𩽾𬶏𬶐䲟𫚓鲖鲔鲛鲑鲜𫚗𫚔鲓𫚛鲪𩾃鲝𫚚鲧鲠𩾁𫚙鲩鲤鲨鲬鲻鲯鲭鲞鲷鲴𫚡鲱鲵鲲鲳鲸鲮鲰𫚞鲶𩾇鲺𩽼鳀𬶟鲫𫚣鳊鳈鲗鳂䲠鲽鳇𬶠𫚢䲡鳅鲾鳄𫚊鳆鳃𫚥鳁鳒鳑鳋鲥𫚕鳏𫚤䲢鳎鳐𫚦鳍鳁鲢鳌鳓鳘𬶭鲦鲣鲹鳗鳛𫚧鳔𬶨鳉𫚋鳙𫠒𩾌鳕鳖𫚪鳟鳝鳜鳞鲟𬶮鲼鲎鲙𫚫鳣鳡鳢鲿鲚𫚈鳠𫚭鳄鲈鲡鸟凫鸠凫鸤凤鸣鸢𫛛𪉃𫛚䴓𫛜𫛞𫛝鸩鸨鸦𫛤鸰𫛡鸵𫁡鸳𪉈鸲鸮鸱鸪𫛣鸯鸭𫛦鸸鸹𪉆𫛩鸻䴕鸿𫛪鸽䴔鸺鸼𫛥𬷕鹀鹃鹆鹁𪉍鹈鹅𫛭鹄鹉𫛨𫛳鹌𫛱鹏鹐鹎雕鹊鹓鹍䴖鸫鹑鹒𫛵𫛶鹋鹙𫛸鹕鹗𬸘鹖鹛𫛷鹜䴗鸧𫛯莺𫛫𬸣鹟鹤鹠鹡鹘鹣鹚鹚鹢鹞鸡𫛽䴘鹝𫜀鹧𪉑鹥鸥鸷鹨𬸦𫜃𫛴鸶鹪𪉊𫜁鹔𬸪鹩鹫鹇鹇𫜄鹬鹰鹭鸴𬸯㶉鹯䴙𫛢鹱鹲𬸚鸬𫛟鹴鹦鹳鹂鸾卤咸鹾碱盐丽麦𪎊麸面面𤿲曲𪎉𪎌曲面𫜑么么黄黉点党黪霉黡黩黾鼋鼌鼍冬鼹齐斋赍齑齿龀龁龂𬹼龅龇龃龆龄出龈啮𫜪龊龉𫜭𬺈𫠜𫜬龋𫜮腭龌𬺓𫜰龙厐庞䶮𫜲龚龛龟𩨎𨱆䜤鿒𠀾𠆿𠉗𫝋㓆𠛆𠚳𪠡𪠺𪜎𪢒𪡺𠴛𪢐𠴢𠵸𠲥𪢖𫭼𡋗𪤄𡋀𡍣㛟𫝪㛿㛠𡭜𡭬𡳃𪨩𪨹岁𡸃㟜𪩛𪪴𢙑𪬚𢘝𢘞𪫡𢘙𪬯𪭝𪭯𢫞𢫊𢬦𪮳暅𣈣𫧃㭣𪳗𣘷𣘓𣞎𣑶𣯣𣭤毶𪶮㳢𣶫𣺽𪶒𣷷𤎻𪹀𤊀𪹹𪹠𤎺𤊰𪺣𤙯𫞢𪺪𪺸𤝢𢢐𫞧㻘㻏𪼴𪽝𤳄𪽭𤶧𪽴𥅿𥅘𪿊𥐰𥐯𪿞𪿵𬒗𫀓𫀌𥞦䅪𫞷𫀮𥧂𥩺𫁳𫂖𫁺𥱔𥭉𫁱𥮋𫂿𥹥𥺇𫄝𦈈𫄦𦈒𦈗𫄯𫄪𫄵𫟇𫅥𫅼𡳒𫆝𫞅𫆫𣍨𦟗𫇘䑽𦨩𫇪𦶻𧌥𫊹𧒭𧉐䘞䙊䘛𫌋𧝧𫌫𫌬𫍞𫍟𫍭䜥𫍶𫍺𫍼𫍾𫍐𧳕䞌𧹓䞎𪠀𫎨𪥠𫎸𫏌𨀱𨁴𫏕𧿈𨅫𫏨𫏞𫏑𨂺𨄄䢀䢁𨐆䢂𫐍𫐔𫐋𨐉𨐇𨐊𫟫𫟬𨡙𨡺𨟳𨠨𨤰𨱀𫓫䦀𬭊䦁𫟽𨱊𬭛𫓼𫓿𫟾𫓮𨱐𫔏𬭶𬭳𫔑𫔐𨱕𫔒䥿𫔓𫔉𫓳𫔕𫔃𫔖𨸁𨸀𨸅𫔲𨸆𨸇𨸉𨸊𨸌𨸋𨸎𫔽𨸘𫕚𫕨𫖑𩏾𫖓𫖖𩏽𫃗𫖪𫖭𩖕𫖵𫖷𫖴𫠇𩙦𫗈𫗉𩙩𩙭𩙨𩙬𩙰𩟿𩠀𫗡𩠁𩠂𫗤𫗨𩠃𩠉𩠆𩠊𩠋𫗳𩠎𩠏䭪𩠅𫗚𩠠𩡖𩧦𩧬𩧵𩧳𩧮𩧶䯃𩧸𩧻𩧼𩧩𩨆𩨉𩨅𩨋𩨍𩧱𩨌𫠌𩨐𩬣𫙂𩯒𩬤𩰰𩲒𩴌𫠏𩽺𩽻𫚎䲞𩽿𩽽𩾄𩾅𫚝𫚟𩾆𫚨𫚩𫚘𫚬𩾎𫠖𫛠𪉄𫛧𪉅𪉋𪉉𪉌𪉎𪉐𪉏𫛻𫛹𪉔𪉒𫜂𫛾𪉕𱊜𫜊𫧮𫜓𫜕𫜟𪔭𪚏𪚐𫜯𠛾𣶭𫓷𫜫`;
let zhMap = null, zhSimp = null;
function zhTable() {
  if (!zhMap) {
    zhMap = new Map();
    const t = [...ZH_T], s = [...ZH_S];
    for (let i = 0; i < t.length; i++) zhMap.set(t[i], s[i]);
    zhSimp = new Set(s.filter(c => !zhMap.has(c)));
  }
  return zhMap;
}
function zhToSimp(str) {
  const m = zhTable();
  let out = '';
  for (const ch of str) out += m.get(ch) || ch;
  return out;
}
/** 'hant' 繁体 / 'hans' 简体 / 'mixed' 分不清 / 'none' 没有能分辨的字 */
function zhScript(text) {
  const m = zhTable();
  let t = 0, s = 0;
  for (const ch of String(text || '')) { if (m.has(ch)) t++; else if (zhSimp.has(ch)) s++; }
  if (t >= 6 && t > s * 3) return 'hant';
  if (s >= 6 && s > t * 3) return 'hans';
  return t + s ? 'mixed' : 'none';
}

/** OpenSubtitles 的文件哈希：文件大小 + 头尾各 64KB（按 64 位小端整数）之和，取低 64 位 */
async function osMovieHash(read, size) {
  if (!(size >= 131072)) return null;
  const [a, b] = await Promise.all([read(0, 65535), read(size - 65536, size - 1)]);
  if (!a || !b || a.length !== 65536 || b.length !== 65536) return null;
  let h = BigInt(size);
  for (const u of [a, b]) {
    const dv = new DataView(u.buffer, u.byteOffset, u.byteLength);
    for (let i = 0; i < 65536; i += 8) h += dv.getBigUint64(i, true);
  }
  return (h & 0xFFFFFFFFFFFFFFFFn).toString(16).padStart(16, '0');
}

const osTokens = s => new Set(String(s || '').toLowerCase().split(/[^a-z0-9]+/).filter(t => t.length > 1));
/** 文件名 → 片名 / 年份 / 季集 / 发布名里的词 */
function osGuess(name) {
  const stem = String(name || '').replace(/\.[^./]+$/, '');
  const ep = /(?:^|[ ._\-[(])S(\d{1,2})[ ._-]?E(\d{1,3})(?!\d)/i.exec(stem) || /(?:^|[ ._-])(\d{1,2})x(\d{2,3})(?!\d)/.exec(stem);
  const p = parseFilename((ep ? stem.slice(0, ep.index) : stem) + '.x');
  return { title: p.title, year: p.year, q: p, season: ep ? +ep[1] : null, episode: ep ? +ep[2] : null, tokens: osTokens(stem) };
}
/** 发布名有多像：两边词集合的 Jaccard */
function osSim(tokens, release) {
  const r = osTokens(release);
  if (!r.size || !tokens.size) return 0;
  let both = 0;
  for (const t of r) if (tokens.has(t)) both++;
  return both / (tokens.size + r.size - both);
}

/** 查询参数要按名字排序、值小写 —— 否则 OpenSubtitles 先 301 到规范形式，白多一个来回 */
function osQs(p) {
  return Object.keys(p).filter(k => p[k] != null && p[k] !== '').sort()
    .map(k => `${k}=${encodeURIComponent(String(p[k]).toLowerCase()).replace(/%20/g, '+')}`).join('&');
}
function osError(status, what, extra) {
  const e = new Error(`opensubtitles ${what}: HTTP ${status}`);
  e.status = status;
  return Object.assign(e, extra || {});
}
async function osCall(env, auth, path, init = {}) {
  const headers = { 'Api-Key': env.OPENSUBTITLES_API_KEY, 'User-Agent': env.OPENSUBTITLES_UA || OS_UA, Accept: 'application/json' };
  if (init.body) headers['Content-Type'] = 'application/json';
  if (auth && auth.token) headers.Authorization = `Bearer ${auth.token}`;
  return fetchRetry(`${(auth && auth.base) || OS_API}${path}`, { ...init, headers }, { retries: 1, timeout: 12_000 });
}
async function osDrop(res) { try { if (res && res.body) await res.body.cancel(); } catch {} }

/** 登录换 token（24 小时有效，这里只信 20 小时）：进程内 → R2 → 登录。登录失败就只用 API Key */
async function osLogin(env) {
  const user = env.OPENSUBTITLES_USERNAME, pass = env.OPENSUBTITLES_PASSWORD;
  if (!user || !pass) return null;
  if (osAuth && osAuth.user === user && osAuth.exp > Date.now()) return osAuth;
  const saved = await r2GetJson(env, OS_R2 + 'token.json');
  if (saved && saved.token && saved.user === user && saved.exp > Date.now()) return (osAuth = saved);
  const res = await osCall(env, null, '/login', { method: 'POST', body: JSON.stringify({ username: user, password: pass }) });
  if (!res.ok) { await osDrop(res); console.error('opensubtitles login: HTTP', res.status); return null; }
  const j = await res.json().catch(() => ({}));
  if (!j.token) return null;
  const host = String(j.base_url || '').replace(/^https?:\/\//, '').replace(/\/.*$/, '');
  osAuth = { token: j.token, base: /^[a-z0-9.-]+$/i.test(host) ? `https://${host}/api/v1` : OS_API, exp: Date.now() + 20 * 3600e3, user };
  await r2PutJson(env, OS_R2 + 'token.json', osAuth);
  return osAuth;
}

async function osSearch(env, auth, params) {
  const res = await osCall(env, auth, `/subtitles?${osQs(params)}`);
  if (!res.ok) { await osDrop(res); throw osError(res.status, 'search'); }
  const j = await res.json().catch(() => null);
  return Array.isArray(j && j.data) ? j.data : [];
}

/** 候选打分（越大越好），不合格的丢掉 */
function osRank(items, job, g) {
  const out = new Map();
  for (const it of items) {
    const a = it && it.attributes;
    const L = a && OS_LANGS[String(a.language || '').toLowerCase()];
    if (!L || (L.lang === 'en' && !job.allowEn)) continue;
    const files = Array.isArray(a.files) ? a.files : [];
    if (files.length !== 1 || !files[0].file_id) continue;            // 多 CD 拼不起来
    const fd = a.feature_details || {};
    if (g.season != null && fd.season_number != null && (+fd.season_number !== g.season || +fd.episode_number !== g.episode)) continue;
    if (g.year && fd.year && Math.abs(+fd.year - +g.year) > 1 && !a.moviehash_match) continue;
    let s = L.score;
    if (a.moviehash_match === true) s += 30;
    s += Math.round(osSim(g.tokens, a.release || files[0].file_name || '') * 20);
    if (job.fps && a.fps && Math.abs(+a.fps - job.fps) < 0.05) s += 5;
    if (a.from_trusted) s += 3;
    s += Math.min(10, Math.log10((+a.download_count || 0) + 1) * 2);
    if (a.machine_translated || a.ai_translated) s -= 25;
    if (a.foreign_parts_only) s -= 60;
    if (a.hearing_impaired) s -= 2;
    const c = { id: String(it.id), file: files[0].file_id, language: String(a.language).toLowerCase(), release: a.release || '',
      fps: +a.fps || 0, hash: a.moviehash_match === true, score: Math.round(s * 10) / 10 };
    const had = out.get(c.id);
    if (!had || had.score < c.score) out.set(c.id, c);
  }
  return [...out.values()].sort((x, y) => y.score - x.score);
}

/** 下载一条：要 SRT；帧率对不上（两边都是常见帧率）时让对方换算 */
async function osDownload(env, auth, c, fps) {
  const body = { file_id: c.file, sub_format: 'srt' };
  const std = f => OS_STD_FPS.some(x => Math.abs(x - f) < 0.01);
  if (fps && c.fps && Math.abs(c.fps - fps) > 0.05 && std(c.fps) && std(fps)) { body.in_fps = c.fps; body.out_fps = +fps.toFixed(3); }
  const res = await osCall(env, auth, '/download', { method: 'POST', body: JSON.stringify(body) });
  if (res.status === 406 || res.status === 429) {
    const j = await res.json().catch(() => ({}));
    throw osError(res.status, 'download quota', { quota: true, resetAt: Date.parse(j.reset_time_utc || '') || 0 });
  }
  if (!res.ok) { await osDrop(res); throw osError(res.status, 'download'); }
  const j = await res.json().catch(() => ({}));
  if (!j.link) throw osError(502, 'download link');
  const f = await fetchRetry(j.link, {}, { retries: 1, timeout: 15_000 });
  if (!f.ok) { await osDrop(f); throw osError(f.status, 'file'); }
  return { text: decodeSubtitleBytes(new Uint8Array(await f.arrayBuffer())), fpsFix: body.in_fps ? [body.in_fps, body.out_fps] : null, remaining: j.remaining };
}

/** TMDB 编号（有 TMDB_API_KEY 时）：电影 → tmdb_id；剧集 → 剧的编号（parent_tmdb_id） */
async function osTmdb(g, env) {
  if (!env.TMDB_API_KEY || !g.title) return null;
  if (g.season != null) { const h = await tmdbSearch('tv', g.title, '', env).catch(() => null); return h && h.id ? { id: h.id, type: 'tv' } : null; }
  const ck = tmdbCacheKey(g.q || g.title, g.year, false);
  const hit = await caches.default.match(ck).catch(() => null);
  let m = null;
  if (hit) { try { m = await hit.json(); } catch {} }
  if (!m) m = await fetchMetadata(g.q || g.title, g.year, false, env).catch(() => null);
  return m && m.id && m.type === 'movie' ? { id: m.id, type: 'movie' } : null;
}

/** 本地没有参照时的退路：OpenSubtitles 上与这个文件哈希一致（为这个文件做的）、条数够的那一条，任何语种 */
async function osHashRef(env, auth, items, chosen, job) {
  if (!items || !items.length) return null;
  const pick = items.map(it => it && it.attributes).filter(a => a && a.moviehash_match === true && Array.isArray(a.files) && a.files.length === 1
    && a.files[0].file_id && String(a.files[0].file_id) !== String(chosen.file) && !a.foreign_parts_only)
    .sort((x, y) => (+y.download_count || 0) - (+x.download_count || 0))[0];
  if (!pick) return null;
  // 哈希一致 = 本来就是这个文件的时间，不做帧率换算
  const got = await osDownload(env, auth, { file: pick.files[0].file_id, fps: 0 }, 0).catch(() => null);
  if (!got) return null;
  const cues = hlsParseSubFile(got.text, /\[Events\]/i.test(got.text) ? '.ass' : '.srt');
  return cues.length >= 40 ? { label: `OpenSubtitles 同哈希（${pick.language || '?'}）`, pointsOnly: false, cues, rank: SYNC_RANK.os } : null;
}

/** 真正去查一遍：job = { filePath, name, size, read, fps, dur, allowEn, refs } → 存储记录 */
async function osRun(env, job) {
  const g = osGuess(job.name);
  const langs = ['ze', 'zh-cn', 'zh-tw', ...(job.allowEn ? ['en'] : [])].sort().join(',');
  const base = { v: OS_FMT, at: Date.now(), langs };
  try {
    const [auth, hash, tm] = await Promise.all([
      osLogin(env).catch(() => null),
      osMovieHash(job.read, job.size).catch(() => null),
      osTmdb(g, env).catch(() => null),
    ]);
    const ep = g.season != null ? { season_number: g.season, episode_number: g.episode } : {};
    const searches = [];
    if (hash) searches.push({ moviehash: hash, languages: langs });
    if (tm) searches.push(tm.type === 'tv' ? { parent_tmdb_id: tm.id, ...ep, languages: langs } : { tmdb_id: tm.id, languages: langs });
    else if (g.title) searches.push({ query: g.title, year: g.year || null, type: g.season != null ? 'episode' : 'movie', ...ep, languages: langs });
    const lists = await Promise.all(searches.map(p => osSearch(env, auth, p).catch(e => { if (e.status === 429) throw e; return []; })));
    const cands = osRank(lists.flat(), job, g);
    for (const c of cands.slice(0, 2)) {                               // 最多花两次下载配额
      const got = await osDownload(env, auth, c, job.fps);
      const cues = hlsParseSubFile(got.text, /\[Events\]/i.test(got.text) ? '.ass' : '.srt');
      const last = cues.reduce((m, x) => Math.max(m, x.e), 0);
      if (cues.length < 10) continue;
      if (job.dur && (last > job.dur + 600 || last < job.dur * 0.4)) continue;   // 片长对不上：多半不是这一版
      const L = OS_LANGS[c.language];
      let converted = false;
      if (L.lang === 'zh-Hans' && (L.toSimp || zhScript(cues.slice(0, 400).map(x => x.text).join('')) === 'hant')) {
        for (const x of cues) x.text = zhToSimp(x.text);
        converted = true;
      }
      // 对齐：记录里存原始时间与对齐参数（参照以后变好了还能重算，见 hlsOnline）
      let sync = null;
      try {
        const ref = job.refs ? await job.refs() : null;
        if (ref) sync = osSyncWith(cues, ref);
        else if (!c.hash) {
          const hr = await osHashRef(env, auth, lists[0] || [], c, job);
          if (hr) sync = osSyncWith(cues, hr);
        }
      } catch (e) { console.error('subsync:', job.filePath, e && e.message); }
      return { ...base, status: 'ok', lang: L.lang, label: L.label, cues, sync,
        src: { id: c.id, file: c.file, language: c.language, release: c.release, hash: c.hash, fps: c.fps, score: c.score, converted, fpsFix: got.fpsFix } };
    }
    return { ...base, status: 'none', retryAt: Date.now() + OS_RETRY.none, tried: cands.length };
  } catch (e) {
    if (e && (e.quota || e.status === 429)) {
      return { ...base, status: 'quota', retryAt: e.resetAt > Date.now() ? e.resetAt + 60e3 : Date.now() + OS_RETRY.quota };
    }
    console.error('opensubtitles:', job.filePath, e && e.message);
    return { ...base, status: 'error', retryAt: Date.now() + OS_RETRY.error };
  }
}

async function osKeyOf(identity) {
  const d = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(identity));
  return [...new Uint8Array(d)].map(b => b.toString(16).padStart(2, '0')).join('');
}
function osRemember(key, rec) {
  OS_MEM.delete(key);
  OS_MEM.set(key, rec);
  while (OS_MEM.size > 24) OS_MEM.delete(OS_MEM.keys().next().value);
}
async function osLoad(env, key) {
  if (OS_MEM.has(key)) return OS_MEM.get(key);
  let rec = await r2GetJson(env, OS_R2 + key + '.json');
  if (!rec) {
    const h = await caches.default.match(new Request(OS_CACHE + key)).catch(() => null);
    if (h) rec = await h.json().catch(() => null);
  }
  if (!rec || rec.v !== OS_FMT) return null;
  osRemember(key, rec);
  return rec;
}
/** 先写 R2 / 边缘缓存，再放进进程内 —— 主列表一引用它，别的 isolate 也读得到 */
async function osSave(env, key, rec) {
  await r2PutJson(env, OS_R2 + key + '.json', rec);
  await caches.default.put(new Request(OS_CACHE + key), new Response(JSON.stringify(rec), {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=2592000' },
  })).catch(() => {});
  osRemember(key, rec);
}
const osFresh = (rec, allowEn) => !!rec && (rec.status === 'ok'
  || (Date.now() < (rec.retryAt || 0) && !(allowEn && rec.status === 'none' && !String(rec.langs || '').includes('en'))));

/** 已有字幕里有没有简体。tracks：[{ id, lang, forced, sample() }]，sample 取一段文字认繁简 */
async function osNeed(sig, tracks) {
  if (OS_NEED.has(sig)) return OS_NEED.get(sig);
  const real = tracks.filter(t => !t.forced);
  let res;
  if (!real.length) res = { need: true, allowEn: !tracks.length, trad: [] };
  else if (real.some(t => t.lang === 'zh-Hans')) res = { need: false, trad: [] };
  else {
    const trad = [];
    let simp = false;
    for (const t of real.filter(t => t.lang === 'zh')) {
      const sc = zhScript(await Promise.resolve().then(t.sample).catch(() => ''));
      if (sc === 'hant') trad.push(t.id); else { simp = true; break; }
    }
    res = simp ? { need: false, trad: [] } : { need: true, allowEn: false, trad };
  }
  OS_NEED.set(sig, res);
  while (OS_NEED.size > 200) OS_NEED.delete(OS_NEED.keys().next().value);
  return res;
}

/** 后台查一遍（同一 isolate 里同一部片只查一次），查完存起来 */
function osKick(env, ctx, key, job) {
  const t = OS_BUSY.get(key);
  if (t && Date.now() - t < 90_000) return;
  OS_BUSY.set(key, Date.now());
  const p = osRun(env, job)
    .then(rec => osSave(env, key, rec))
    .catch(e => console.error('opensubtitles save:', e && e.message))
    .finally(() => { OS_BUSY.delete(key); });
  ctx?.waitUntil?.(p);
}
/** 等后台那一查：只读进程内的结果，不 await 它的 Promise */
async function osAwait(key, ms, allowEn) {
  const until = Date.now() + ms;
  for (;;) {
    const rec = OS_MEM.get(key);
    if (osFresh(rec, allowEn) || !OS_BUSY.has(key) || Date.now() >= until) return rec || null;
    await new Promise(r => setTimeout(r, 100));
  }
}

/**
 * 这部片的在线字幕。file = { filePath, name, meta, read, fps, dur }，tracks 见 osNeed。
 * 返回 { rec, need }：rec 是可用的记录（status 'ok'）或 null；waitMs > 0 时最多等后台那一查这么久
 */
async function osFor(env, ctx, file, tracks, waitMs) {
  if (!osOn(env)) return null;
  const sig = osIdentity(file.filePath, file.meta) + '|' + tracks.map(t => `${t.id}:${t.lang}:${t.rev || ''}:${t.forced ? 1 : 0}`).join(',');
  const need = await osNeed(sig, tracks);
  if (!need.need) return { rec: null, need };
  const key = await osKeyOf(osIdentity(file.filePath, file.meta));
  let rec = await osLoad(env, key);
  if (!osFresh(rec, need.allowEn)) {
    osKick(env, ctx, key, { filePath: file.filePath, name: file.name, size: file.meta.size, read: file.read, fps: file.fps, dur: file.dur, allowEn: need.allowEn, refs: file.refs });
    if (waitMs) rec = (await osAwait(key, waitMs, need.allowEn)) || rec;
  }
  return { rec: rec && rec.status === 'ok' ? rec : null, need, key, pending: OS_BUSY.has(key) };
}

/** 整份 WebVTT（直连的 <track> 用；HLS 分段用 hlsVtt）。先清洗：dur 不知道就按最后一条字幕算 */
function osVttFull(cues, dur) {
  const out = ['WEBVTT', ''];
  for (const c of subClean(cues, dur).slice().sort((a, b) => a.s - b.s || a.e - b.e)) out.push(`${hlsVttTime(c.s)} --> ${hlsVttTime(c.e)}${c.settings || ''}`, c.text, '');
  return out.join('\n');
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  在线字幕自动对齐（只给 OpenSubtitles 找来的那条；内封 / 外挂字幕原样用）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  在线字幕常常是给另一个版本做的：整体早 / 晚几秒（片头长短不同）、越放越偏（23.976 ↔ 25 帧的 PAL 加速、
//  1.001 的 NTSC 误差）、中途突然错开一截（多 / 少一段剧情）。对齐要一份「这个文件自己的时间」做参照 ——
//  不必是同一种语言，只要时间来自这个文件：
//    ① 内封字幕（文字或 PGS 图形，任何语言）：MKV Cues 里就有每一条的起止时间，一个字节都不用多读；
//    ② 同目录的外挂字幕；
//    ③ 都没有时：OpenSubtitles 里与这个文件哈希一致（就是为这个文件做的）的其他语种字幕。
//  算法与 alass / ffsubsync 同一思路，按「事件」对齐：
//    · 两边各取字幕出现 / 消失的时刻当事件（出现只和出现比、消失只和消失比），两两相减投票
//      （直方图 + 三角核平滑）；每个候选帧率比（1、25/23.976、24/23.976 …）各投一次；
//    · 全局投票里的几个高峰当候选偏移，逐条字幕动态规划选偏移、每换一次扣分 —— 偏移成台阶就自然切成几段，
//      切点落在两条字幕之间；每段要比用相邻段的偏移明显对得更好才保留，再在 ±0.4s 内用 20ms 的格子细调（syncFit）；
//    · 最后核对：字幕按单双条分两半各自对齐、拿去给另一半用（交叉验证），对上的比例都要显著高于随机水平；
//      整体也要明显好于对齐前、好于随机水平才采用，否则原样不动 —— 宁可不改，也不能改坏（subSync）。
const SYNC_V = 2;
const SYNC_SCALES = [1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25, 30 / 29.97, 29.97 / 30];
const SYNC_RANGE = 900;          // 全局偏移最多 ±15 分钟
const SYNC_TOL = 0.25;           // 「对上了」：参照事件落在 ±0.25s 内
const SYNC_KER = 0.3;            // 分段打分用的软核半宽
const SYNC_PEN = 6;              // 换一次偏移（切一刀）至少要多对上这么多分
const SYNC_SHIFTS = [-151.3, -97.3, -61.7, -43.1, -29.9, -17.3, 13.1, 23.9, 37.7, 53.3, 79.1, 113.9];   // 随机水平：整体挪开这些秒数再数

/** 字幕 → 事件：出现时刻 s、消失时刻 e 各一列，排好序。出现只和出现比、消失只和消失比（消失权重 0.6）；
    参照只有时刻（PGS 不分出现消失）时两列都是全部时刻 */
function syncEvents(cues, pointsOnly) {
  const s = [], e = [];
  for (const c of cues || []) {
    if (!c || !Number.isFinite(c.s) || c.s < 0) continue;
    s.push(c.s);
    if (Number.isFinite(c.e) && c.e > c.s + 0.05) e.push(c.e);
  }
  if (pointsOnly) { const all = Float64Array.from([...s, ...e]).sort(); return { s: all, e: all, pts: true }; }
  return { s: Float64Array.from(s).sort(), e: Float64Array.from(e).sort(), pts: false };
}

/** 偏移直方图：每对（目标事件 x，参照事件 y）投 d = y − 比例 × x 一票，只统计 d ∈ [lo, hi] */
function syncVote(h, xs, ys, scale, lo, hi, bin, w) {
  let j0 = 0;
  for (let i = 0; i < xs.length; i++) {
    const x = xs[i] * scale;
    while (j0 < ys.length && ys[j0] < x + lo) j0++;
    for (let j = j0; j < ys.length; j++) {
      const d = ys[j] - x;
      if (d > hi) break;
      h[Math.round((d - lo) / bin)] += w;
    }
  }
}
function syncHist(tg, rf, scale, lo, hi, bin) {
  const h = new Float32Array(Math.ceil((hi - lo) / bin) + 1);
  syncVote(h, tg.s, rf.s, scale, lo, hi, bin, 1);
  syncVote(h, tg.e, rf.e, scale, lo, hi, bin, 0.6);
  return h;
}
/** 三角核平滑（半宽 k 格） */
function syncSmooth(h, k) {
  const out = new Float32Array(h.length), norm = (k + 1) * (k + 1);
  for (let i = 0; i < h.length; i++) {
    let s = 0;
    for (let d = -k; d <= k; d++) { const j = i + d; if (j >= 0 && j < h.length) s += h[j] * (k + 1 - Math.abs(d)); }
    out[i] = s / norm;
  }
  return out;
}
/** 峰：位置（抛物线插值到格子以下）、高度、相对背景的稳健 z 分（中位数 + MAD，峰两侧 excl 秒不算背景）；
    顺带给出背景的 med / sd，挑候选峰时用 */
function syncPeak(h, lo, bin, excl) {
  let bi = 0;
  for (let i = 1; i < h.length; i++) if (h[i] > h[bi]) bi = i;
  const ex = Math.max(1, Math.round(excl / bin));
  const rest = [];
  for (let i = 0; i < h.length; i += (h.length > 4000 ? 3 : 1)) if (Math.abs(i - bi) > ex) rest.push(h[i]);
  rest.sort((a, b) => a - b);
  const med = rest.length ? rest[rest.length >> 1] : 0;
  const dev = rest.map(v => Math.abs(v - med)).sort((a, b) => a - b);
  const mad = dev.length ? dev[dev.length >> 1] : 0;
  let mean = 0, sq = 0;
  for (const v of rest) { mean += v; sq += v * v; }
  mean /= rest.length || 1;
  const sd = Math.max(1.4826 * mad, Math.sqrt(Math.max(0, sq / (rest.length || 1) - mean * mean)) * 0.5, 1e-6);
  return { off: lo + syncSub(h, bi) * bin, v: h[bi], z: (h[bi] - med) / sd, med, sd };
}
/** 抛物线插值：峰在第 i 格附近的亚格位置 */
function syncSub(h, i) {
  if (i <= 0 || i >= h.length - 1) return i;
  const a = h[i - 1], b = h[i], c = h[i + 1], den = a - 2 * b + c;
  return den < 0 ? i + Math.max(-0.5, Math.min(0.5, 0.5 * (a - c) / den)) : i;
}
/** 前 k 个彼此相距 ≥ sep 秒、且高出背景 zmin 个 sd 的峰（偏移，从高到低） */
function syncPeaks(h, lo, bin, pk, k, sep, zmin) {
  const idx = [];
  for (let i = 1; i < h.length - 1; i++) if (h[i] >= h[i - 1] && h[i] > h[i + 1] && (h[i] - pk.med) / pk.sd >= zmin) idx.push(i);
  idx.sort((a, b) => h[b] - h[a]);
  const out = [], gap = sep / bin;
  for (const i of idx) {
    if (out.length >= k) break;
    if (!out.some(j => Math.abs(j - i) < gap)) out.push(i);
  }
  return out.map(i => lo + syncSub(h, i) * bin);
}

/** 映射：比例 + 分段偏移。segs = [{ until, off }]（until：目标时间，这一段管到哪；最后一段 until = null） */
function syncMap(sync, t) {
  const segs = sync.segs;
  let off = segs[segs.length - 1].off;
  for (const s of segs) if (s.until == null || t < s.until) { off = s.off; break; }
  return t * sync.scale + off;
}
/** 排好序的时刻表 ys 里离 x 最近的有多远 */
function syncNear(ys, x) {
  if (!ys.length) return Infinity;
  let lo = 0, hi = ys.length - 1;
  while (lo < hi) { const m = (lo + hi) >> 1; if (ys[m] < x) lo = m + 1; else hi = m; }
  let d = Math.abs(ys[lo] - x);
  if (lo > 0) d = Math.min(d, Math.abs(ys[lo - 1] - x));
  return d;
}
/** 对上的比例：目标字幕的出现时刻映射过去后，±tol 内有参照字幕出现的占多少 */
function syncRate(tgStarts, rf, map, tol = SYNC_TOL) {
  if (!tgStarts.length || !rf.s.length) return 0;
  let hit = 0;
  for (const s of tgStarts) if (syncNear(rf.s, map(s)) <= tol) hit++;
  return hit / tgStarts.length;
}
/** 随机水平：把映射整体挪开若干秒再数，均值与标准差（标准差不小于二项分布那么大） */
function syncChance(starts, rf, map) {
  const r = SYNC_SHIFTS.map(d => syncRate(starts, rf, t => map(t) + d));
  const mu = r.reduce((a, b) => a + b, 0) / r.length;
  const sd = Math.sqrt(r.reduce((a, b) => a + (b - mu) * (b - mu), 0) / r.length);
  return { mu, sd: Math.max(sd, Math.sqrt(Math.max(mu * (1 - mu), 0.01) / starts.length)) };
}

/**
 * 拟合一组目标字幕 cs（按出现排好）：hs = 每个比例的平滑全局直方图（这组字幕自己的）
 *   ① 比例：每个候选比例的直方图取最尖的峰（非 1 的比例要明显更尖才换）；
 *   ② 候选偏移：这个比例下全局直方图前 12 个彼此相距 ≥ 0.5s 的峰（剪辑差、广告切口各成一个峰）；
 *   ③ 每条字幕对每个候选偏移打分（出现 / 消失离最近参照事件多近，软核），
 *      逐条动态规划选偏移：换一次偏移扣 SYNC_PEN 分 —— 自然切成若干段，切点落在两条字幕之间；
 *   ④ 每段要「挣得到」：比用相邻段的偏移多对上 max(罚分, 段长 × 8%) 才保留，不然并进去；
 *   ⑤ 每段在 ±0.4s 内用 20ms 的格子细调；细调后相差不到 0.25s 的相邻段合并。
 */
function syncFit(cs, hs, rf) {
  // 比例 1 一定试；别的比例只试峰最尖的两个（且不比 1 的峰差太多）。各自走完分段，总分高的胜（非 1 要高 3% 才换）——
  // 一级一级往后错的台阶（广告切口）近似一条斜线，光比峰会误认成帧率差，比分段后的总分就不会
  const peaks = SYNC_SCALES.map(sc => ({ ...syncPeak(hs.get(sc), -SYNC_RANGE, 0.1, 2), scale: sc }));
  const one = peaks[0];
  const tries = [one, ...peaks.slice(1).sort((a, b) => b.z - a.z).slice(0, 2).filter(p => p.z >= Math.max(6, one.z * 0.8))];
  let best = null;
  for (const p of tries) {
    const m = syncFitAt(cs, hs.get(p.scale), rf, p);
    if (!best || m.obj > best.obj * 1.03) best = m;
  }
  return best;
}
function syncFitAt(cs, h, rf, best) {
  const scale = best.scale, n = cs.length;
  const cands = syncPeaks(h, -SYNC_RANGE, 0.1, best, 12, 0.5, 4);
  if (!cands.length) cands.push(best.off);
  const K = cands.length, sc = new Float32Array(n * K);
  const ker = d => d >= SYNC_KER ? 0 : 1 - d / SYNC_KER;
  for (let i = 0; i < n; i++) for (let k = 0; k < K; k++) {
    const c = cs[i];
    sc[i * K + k] = ker(syncNear(rf.s, c.s * scale + cands[k])) + (c.e != null ? 0.6 * ker(syncNear(rf.e, c.e * scale + cands[k])) : 0);
  }
  // ③ 动态规划（Viterbi）
  const back = new Uint8Array(n * K);
  let V = new Float64Array(K), NV = new Float64Array(K);
  for (let k = 0; k < K; k++) V[k] = sc[k];
  for (let i = 1; i < n; i++) {
    let bp = 0;
    for (let k = 1; k < K; k++) if (V[k] > V[bp]) bp = k;
    for (let k = 0; k < K; k++) {
      const sw = V[bp] - SYNC_PEN;
      if (sw > V[k]) { NV[k] = sw + sc[i * K + k]; back[i * K + k] = bp; } else { NV[k] = V[k] + sc[i * K + k]; back[i * K + k] = k; }
    }
    [V, NV] = [NV, V];
  }
  const pick = new Uint8Array(n);
  let k = 0;
  for (let j = 1; j < K; j++) if (V[j] > V[k]) k = j;
  const obj = V[k];
  for (let i = n - 1; i >= 0; i--) { pick[i] = k; k = back[i * K + k]; }
  // 连续同一偏移 → 段 { i0, i1, k }
  let runs = [];
  for (let i = 0; i < n; i++) {
    if (runs.length && runs[runs.length - 1].k === pick[i]) runs[runs.length - 1].i1 = i + 1;
    else runs.push({ i0: i, i1: i + 1, k: pick[i] });
  }
  const sum = (r, kk) => { let s = 0; for (let i = r.i0; i < r.i1; i++) s += sc[i * K + kk]; return s; };
  // ④ 挣不到的段并给相邻段（每次并掉最不值的那段，直到都站得住）
  for (;;) {
    let worst = -1, wv = Infinity, wto = -1;
    runs.forEach((r, j) => {
      if (runs.length === 1) return;
      const own = sum(r, r.k);
      let alt = -Infinity, to = -1;
      for (const q of [j - 1, j + 1]) if (q >= 0 && q < runs.length) { const v = sum(r, runs[q].k); if (v > alt) { alt = v; to = q; } }
      const need = Math.max(SYNC_PEN, 0.08 * (r.i1 - r.i0));
      if (own - alt < need && own - alt - need < wv) { wv = own - alt - need; worst = j; wto = to; }
    });
    if (worst < 0) break;
    runs[worst].k = runs[wto].k;
    const merged = [];
    for (const r of runs) {
      if (merged.length && merged[merged.length - 1].k === r.k) merged[merged.length - 1].i1 = r.i1;
      else merged.push({ ...r });
    }
    runs = merged;
  }
  // 切点：交界两侧各 15 条里重新挑总分最高的位置；平手（交界附近对不上参照的字幕两边都是 0 分，动态规划随便切）
  // 就挑两条字幕之间空档最大的那个 —— 剪辑点通常就是那段空白
  for (let j = 1; j < runs.length; j++) {
    const A = runs[j - 1], B = runs[j], lo = Math.max(A.i0 + 1, B.i0 - 15), hi = Math.min(B.i1 - 1, B.i0 + 15);
    if (hi <= lo) continue;
    const tot = [];
    for (let p = lo; p <= hi; p++) {
      let v = 0;
      for (let i = lo - 1; i < p; i++) v += sc[i * K + A.k];
      for (let i = p; i <= hi; i++) v += sc[i * K + B.k];
      tot.push(v);
    }
    const mx = Math.max(...tot);
    let bp = B.i0, bg = -1;
    tot.forEach((v, q) => { const p = lo + q, g = cs[p].s - cs[p - 1].s; if (v >= mx - 0.01 && g > bg) { bg = g; bp = p; } });
    A.i1 = bp; B.i0 = bp;
  }
  // ⑤ 细调：这一段的全部事件在候选偏移 ±0.4s 内找峰
  const refine = (r, off) => {
    const ev = syncEvents(cs.slice(r.i0, r.i1));
    if (ev.s.length < 4) return off;
    const h = syncSmooth(syncHist(ev, rf, scale, off - 0.4, off + 0.4, 0.02), 2);
    let bi = 0;
    for (let i = 1; i < h.length; i++) if (h[i] > h[bi]) bi = i;
    return h[bi] > 0 ? off - 0.4 + syncSub(h, bi) * 0.02 : off;
  };
  let segs = runs.map(r => ({ i0: r.i0, i1: r.i1, off: refine(r, cands[r.k]) }));
  for (let j = segs.length - 1; j > 0; j--) {
    if (Math.abs(segs[j].off - segs[j - 1].off) < 0.25) {
      const m = { i0: segs[j - 1].i0, i1: segs[j].i1 };
      m.off = refine(m, (segs[j - 1].off * (segs[j - 1].i1 - segs[j - 1].i0) + segs[j].off * (segs[j].i1 - segs[j].i0)) / (m.i1 - m.i0));
      segs.splice(j - 1, 2, m);
    }
  }
  return {
    scale, z: best.z, obj,
    segs: segs.map((g, j) => ({ until: j < segs.length - 1 ? +((cs[g.i1 - 1].s + cs[g.i1].s) / 2).toFixed(3) : null, off: Math.round(g.off * 1000) / 1000 })),
  };
}

/**
 * 主入口。target：在线字幕 [{s,e}]（秒）；ref：参照字幕 [{s,e}]，pointsOnly = 参照只有时刻（PGS）。
 * 返回 { v, scale, segs, before, after, chance, cv, applied, why }；applied=false 时 scale=1、segs=[{until:null,off:0}]
 * 核对（宁可不改，也不能改坏）：
 *   · 交叉验证：字幕按单双条分两半，各自独立拟合，拿去给另一半用 —— 对上的比例都要显著高于随机水平
 *     （z ≥ 3 且高 8 个百分点以上）。和片子对不上的字幕找到的「峰」是凑出来的，换一半就不灵；
 *   · 整体：对齐后对上的比例要比随机水平高 10 个百分点、比对齐前高 4 个百分点。
 */
function subSync(target, ref, opts = {}) {
  const ident = { scale: 1, segs: [{ until: null, off: 0 }] };
  const out = why => ({ v: SYNC_V, ...ident, applied: false, why });
  const cs = (target || []).filter(c => c && Number.isFinite(c.s) && c.s >= 0)
    .map(c => ({ s: c.s, e: Number.isFinite(c.e) && c.e > c.s + 0.05 ? c.e : null })).sort((a, b) => a.s - b.s);
  const rf = syncEvents(ref, !!opts.pointsOnly);
  if (cs.length < 40 || rf.s.length < 40) return out('too-few');
  const A = cs.filter((_, i) => i % 2 === 0), B = cs.filter((_, i) => i % 2 === 1);
  const eA = syncEvents(A), eB = syncEvents(B);
  const hA = new Map(), hB = new Map(), hF = new Map();
  for (const s of SYNC_SCALES) {
    const a = syncHist(eA, rf, s, -SYNC_RANGE, SYNC_RANGE, 0.1), b = syncHist(eB, rf, s, -SYNC_RANGE, SYNC_RANGE, 0.1);
    const f = new Float32Array(a.length);
    for (let i = 0; i < a.length; i++) f[i] = a[i] + b[i];
    hA.set(s, syncSmooth(a, 3)); hB.set(s, syncSmooth(b, 3)); hF.set(s, syncSmooth(f, 3));
  }
  const fit = syncFit(cs, hF, rf);
  if (fit.z < 6) return out('no-peak');
  const starts = cs.map(c => c.s);
  const f = t => syncMap(fit, t);
  const before = syncRate(starts, rf, t => t), after = syncRate(starts, rf, f);
  const ch = syncChance(starts, rf, f);
  const res = { v: SYNC_V, scale: fit.scale, segs: fit.segs, before: +before.toFixed(3), after: +after.toFixed(3), chance: +ch.mu.toFixed(3), z: +fit.z.toFixed(1) };
  let moved = 0;
  for (const s of starts) moved = Math.max(moved, Math.abs(f(s) - s));
  if (moved < 0.12) return { ...res, ...ident, applied: false, why: 'in-sync' };
  const cvz = (half, m) => {
    const st = half.map(c => c.s), mp = t => syncMap(m, t);
    const r = syncRate(st, rf, mp), c = syncChance(st, rf, mp);
    return r - c.mu < 0.08 ? Math.min(0, (r - c.mu) / c.sd) : (r - c.mu) / c.sd;
  };
  res.cv = +Math.min(cvz(B, syncFit(A, hA, rf)), cvz(A, syncFit(B, hB, rf))).toFixed(1);
  if (res.cv < 3) return { ...res, ...ident, applied: false, why: 'unstable' };
  if (after < ch.mu + 0.1 || after < before + 0.04) return { ...res, ...ident, applied: false, why: 'not-better' };
  return { ...res, applied: true, why: 'ok' };
}

/** 把对齐用到一组字幕上（新数组，原样不动）；落到 0 秒以前的整条丢掉 */
function syncApply(cues, sync) {
  if (!sync || !sync.applied) return cues;
  const out = [];
  for (const c of cues) {
    const s = syncMap(sync, c.s), e = syncMap(sync, c.s) + (c.e - c.s) * sync.scale;
    if (e <= 0.05) continue;
    out.push({ ...c, s: Math.max(0, s), e });
  }
  return out;
}

/* ── 参照来源 ──────────────────────────────────────────────────────────
   都只取时间，不看内容；取「字幕最多、不是 forced（只翻外语对白的那种）」的那一条。
   rank：3 = 这个文件自己的字幕（内封 / 外挂），2 = OpenSubtitles 上与这个文件哈希一致的 */
const SYNC_RANK = { local: 3, os: 2 };
/** 内封字幕：文字轨（idx.subs，Cues 里有起止）与图形轨（idx.subRefs：PGS / VobSub，Cues 里只有时刻） */
function syncRefFromIdx(idx) {
  if (!idx) return null;
  const sec = u => u * idx.scaleNs / 1e9;
  const cand = [];
  (idx.subs || []).forEach((sub, i) => {
    if (sub.forced || !sub.cues || sub.cues.length < 40) return;
    cand.push({ label: `内封 #${i}（${sub.lang || '未知'}）`, pointsOnly: false, n: sub.cues.length,
      cues: () => sub.cues.map(c => { const st = sec(c[0]); return { s: st, e: c[1] >= 0 ? st + sec(c[1]) : null }; }) });
  });
  for (const r of idx.subRefs || []) {
    if (r.forced || !r.t || r.t.length < 60) continue;
    cand.push({ label: `内封图形字幕（${r.lang || '未知'}）`, pointsOnly: true, n: r.t.length / 2,
      cues: () => r.t.map(ms => ({ s: ms / 1000 })) });
  }
  if (!cand.length) return null;
  cand.sort((a, b) => (b.pointsOnly ? b.n * 0.8 : b.n) - (a.pointsOnly ? a.n * 0.8 : a.n));
  const c = cand[0];
  return { label: c.label, pointsOnly: c.pointsOnly, cues: c.cues(), rank: SYNC_RANK.local };
}
/** 同目录外挂字幕：挑条数最多的那份 */
async function syncRefFromSidecars(xs, env, ctx) {
  let best = null;
  for (const x of xs || []) {
    const cues = await hlsSidecarCues(x, env, ctx).catch(() => null);
    if (cues && cues.length >= 40 && (!best || cues.length > best.cues.length)) best = { label: `外挂 ${x.name || x.path}`, pointsOnly: false, cues, rank: SYNC_RANK.local };
  }
  return best;
}
/** 对齐结果的指纹：HLS 字幕分段的缓存键带上它，换了对齐就不会读到旧分段 */
const syncId = sync => (sync && sync.applied) ? fnv1a(`${sync.scale.toFixed(6)}|${sync.segs.map(g => `${g.off}@${g.until == null ? '' : g.until.toFixed(2)}`).join(',')}`) : 'n';
/** 在线字幕的成品时间轴：原始时间 + 对齐（记录里只存原始字幕与对齐参数，对齐可以后补、可以重算） */
const _osOut = new WeakMap();
function osCuesOut(rec) {
  if (!rec || !rec.cues) return [];
  if (!rec.sync || !rec.sync.applied) return rec.cues;
  let o = _osOut.get(rec);
  if (!o || o.id !== syncId(rec.sync)) { o = { id: syncId(rec.sync), cues: syncApply(rec.cues, rec.sync) }; _osOut.set(rec, o); }
  return o.cues;
}
/** 对齐一条在线字幕：ref = { cues, pointsOnly, label, rank } */
function osSyncWith(cues, ref) {
  const r = subSync(cues, ref.cues, { pointsOnly: ref.pointsOnly });
  return { ...r, ref: ref.label, rank: ref.rank, at: Date.now() };
}
/** 记录里的对齐还能不能更好：没有对齐过，或者当时只有更弱的参照 */
const osSyncWeaker = (rec, rank) => !!rec && rec.status === 'ok' && (!rec.sync || (rec.sync.rank || 0) < rank || rec.sync.v !== SYNC_V);

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  v24：Safari MP4/MOV FourCC 零拷贝流式热修补
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/**
 * hev1 / dvhe 样本入口里的 hvcC 带没带齐 VPS / SPS / PPS：true / false；读不全（跨块）→ null。
 * hev1 允许参数集只放在码流里，这种流改名成 hvc1 / dvh1 之后配置盒里没有参数集，
 * 苹果的解码器反而彻底拒播 —— 只有带齐了才改名。
 */
function mp4HvccHasParams(buf, from, to) {
  for (let j = from; j + 8 <= to; j++) {
    if (buf[j] !== 0x68 || buf[j + 1] !== 0x76 || buf[j + 2] !== 0x63 || buf[j + 3] !== 0x43) continue;   // 'hvcC'
    const c = j + 4;
    if (c + 23 > buf.length) return null;
    let p = c + 23;
    const seen = new Set();
    for (let a = 0, na = buf[c + 22]; a < na; a++) {
      if (p + 3 > buf.length) return null;
      const type = buf[p] & 0x3F, cnt = (buf[p + 1] << 8) | buf[p + 2];
      p += 3;
      if (cnt) seen.add(type);
      for (let k = 0; k < cnt; k++) {
        if (p + 2 > buf.length) return null;
        p += 2 + ((buf[p] << 8) | buf[p + 1]);
      }
    }
    return seen.has(32) && seen.has(33) && seen.has(34);
  }
  return null;
}

function patchSafariMp4Buffer(buf) {
  const n = buf.length;
  for (let i = 0; i <= n - 12; i++) {
    if (
      buf[i + 4] !== 0 || buf[i + 5] !== 0 || buf[i + 6] !== 0 ||
      buf[i + 7] !== 0 || buf[i + 8] !== 0 || buf[i + 9] !== 0 ||
      buf[i + 10] !== 0 || buf[i + 11] !== 1
    ) continue;

    const c0 = buf[i], c1 = buf[i + 1], c2 = buf[i + 2], c3 = buf[i + 3];
    const isHev1 = c0 === 0x68 && c1 === 0x65 && c2 === 0x76 && c3 === 0x31;
    const isHvc1 = c0 === 0x68 && c1 === 0x76 && c2 === 0x63 && c3 === 0x31;
    const isDvhe = c0 === 0x64 && c1 === 0x76 && c2 === 0x68 && c3 === 0x65;

    // 参数集只在码流里的 hev1 / dvhe：改了名苹果更播不了，原样放过（见 mp4HvccHasParams）
    const paramsOk = isHev1 || isDvhe ? mp4HvccHasParams(buf, i + 78, Math.min(n, i + 600)) !== false : true;
    if (isDvhe) {
      if (paramsOk) { buf[i] = 0x64; buf[i + 1] = 0x76; buf[i + 2] = 0x68; buf[i + 3] = 0x31; } // dvh1
      continue;
    }
    if ((isHev1 && paramsOk) || isHvc1) {
      const scanEnd = Math.min(n - 4, i + 600);
      let hasDolbyVisionBox = false;
      for (let j = i + 78; j <= scanEnd; j++) {
        if (
          buf[j] === 0x64 && buf[j + 1] === 0x76 &&
          (buf[j + 2] === 0x63 || buf[j + 2] === 0x76) && buf[j + 3] === 0x43
        ) {
          hasDolbyVisionBox = true;
          break;
        }
      }
      if (hasDolbyVisionBox) {
        buf[i] = 0x64; buf[i + 1] = 0x76; buf[i + 2] = 0x68; buf[i + 3] = 0x31; // dvh1
      } else if (isHev1) {
        buf[i] = 0x68; buf[i + 1] = 0x76; buf[i + 2] = 0x63; buf[i + 3] = 0x31; // hvc1
      }
    }
  }
}

function wrapSafariMp4PatchStream(readable) {
  if (!readable) return readable;
  const OVERLAP = 640;
  let carry = new Uint8Array(0);

  return readable.pipeThrough(new TransformStream({
    transform(chunk, controller) {
      const incoming = chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk);
      const merged = new Uint8Array(carry.length + incoming.length);
      merged.set(carry, 0);
      merged.set(incoming, carry.length);

      patchSafariMp4Buffer(merged);

      if (merged.length > OVERLAP) {
        const emitLen = merged.length - OVERLAP;
        controller.enqueue(merged.subarray(0, emitLen));
        carry = merged.slice(emitLen);
      } else {
        carry = merged;
      }
    },
    flush(controller) {
      if (carry.length > 0) {
        patchSafariMp4Buffer(carry);
        controller.enqueue(carry);
        carry = new Uint8Array(0);
      }
    },
  }));
}

function getExt(name) {
  const i = name.lastIndexOf('.');
  return i >= 0 ? name.slice(i).toLowerCase() : '';
}

function jsonResponse(data, status = 200, extra = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...extra },
  });
}

function parseCookies(str) {
  const obj = {};
  for (const pair of str.split(';')) {
    const eq = pair.indexOf('=');
    if (eq > 0) obj[pair.slice(0, eq).trim()] = pair.slice(eq + 1).trim();
  }
  return obj;
}

/** HTML 转义（属性值与文本节点通用） */
function escHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[c]);
}

// ── 计时 ──

function timer() {
  const t0 = Date.now();
  const marks = [];
  return {
    mark(name) { marks.push(`${name};dur=${Date.now() - t0}`); },
    header() { return marks.join(', '); },
  };
}

// ── 快速哈希（用于 ETag，比 SHA-1 轻量得多）──

function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(36);
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  安全原语（HMAC 签名 & 恒时比较）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

const _hmacKeys = new Map(); // secret → CryptoKey（importKey 结果按 isolate 生命周期复用）

async function hmacKey(secret) {
  let k = _hmacKeys.get(secret);
  if (!k) {
    k = await crypto.subtle.importKey(
      'raw', new TextEncoder().encode(secret),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
    );
    _hmacKeys.set(secret, k);
  }
  return k;
}

async function hmacHex(secret, msg) {
  const sig = await crypto.subtle.sign(
    'HMAC', await hmacKey(secret), new TextEncoder().encode(msg),
  );
  let out = '';
  for (const b of new Uint8Array(sig)) out += b.toString(16).padStart(2, '0');
  return out;
}

/** 恒时字符串比较：长度不同直接 false（长度本身不是秘密） */
function timingSafeEqualStr(a, b) {
  const ea = new TextEncoder().encode(String(a));
  const eb = new TextEncoder().encode(String(b));
  if (ea.byteLength !== eb.byteLength) return false;
  // CF Workers 非标扩展；等长前提下不会 throw。没有这个扩展（本地单测等）走手写恒时比较 ——
  // 先判断再分流，不靠每次抛一个异常（抛接异常比比较本身贵得多）
  if (typeof crypto.subtle.timingSafeEqual === 'function') {
    try { return crypto.subtle.timingSafeEqual(ea, eb); } catch {}
  }
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

// ── 会话 Cookie ──
//  v16 之前 Cookie 里直接放 AUTH_SECRET 本身。两个后果：
//    · 主密钥常驻浏览器 Cookie 罐，且随每个请求上行
//    · Max-Age 只是浏览器侧的君子协定 —— 抄走那串值，它永远有效
//  改成 `<exp>.<HMAC(secret, "sess|"+exp)>`：服务端能真正判过期，
//  值本身也不是主密钥。老 Cookie 继续放行，换页即自动升级，不用重新登录。

const SESS_TTL = 30 * 86400;  // 秒。签发即固定，服务端按 exp 判定

async function mintSession(env) {
  const exp = Math.floor(Date.now() / 1000) + SESS_TTL;
  return `${exp}.${await hmacHex(env.AUTH_SECRET, `sess|${exp}`)}`;
}

async function verifySession(value, env) {
  if (!value) return false;
  const dot = value.indexOf('.');
  if (dot > 0) {
    const exp = parseInt(value.slice(0, dot), 10);
    if (!Number.isFinite(exp) || exp * 1000 < Date.now()) return false;
    return timingSafeEqualStr(value.slice(dot + 1), await hmacHex(env.AUTH_SECRET, `sess|${exp}`));
  }
  // 兼容路径：v15 及以前直接存主密钥的 Cookie
  return timingSafeEqualStr(value, env.AUTH_SECRET);
}

function sessionCookie(token) {
  return `auth=${token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${SESS_TTL}`;
}

// ── 登录节流 ──
//  /auth 是唯一能穷举 AUTH_SECRET 的入口，原来不限次数。Worker 无共享状态，
//  按 isolate 记账 —— 挡不住分布式暴破，但足以把单点穷举的速率打下来，
//  且零依赖、零延迟。真要更强的可以换 KV / Durable Object。
const _authFails = new Map();
const AUTH_WINDOW = 15 * 60_000, AUTH_MAX = 12;

function authThrottled(ip) {
  const e = _authFails.get(ip);
  if (!e || Date.now() - e.at > AUTH_WINDOW) return 0;
  return e.n >= AUTH_MAX ? Math.ceil((AUTH_WINDOW - (Date.now() - e.at)) / 1000) : 0;
}
function authFailed(ip) {
  const e = _authFails.get(ip);
  if (!e || Date.now() - e.at > AUTH_WINDOW) _authFails.set(ip, { n: 1, at: Date.now() });
  else e.n++;
  if (_authFails.size > 2000) {                    // 上限兜底，别让它变成内存泄漏
    const cut = Date.now() - AUTH_WINDOW;
    for (const [k, v] of _authFails) if (v.at < cut) _authFails.delete(k);
  }
}

// ── /stream 签名直链 ──
//  sig = HMAC-SHA256(AUTH_SECRET, `${path}|${exp}`)，exp 为 unix 秒。
//  签名只覆盖 ?path= 与 exp —— /stream/<文件名> 路径段是给播放器
//  识别进度用的装饰，不参与鉴权。
//  · 可分享：不含主密钥，泄露只影响单个文件、且会过期
//  · 浏览器 <video> 同样用它：Cookie 过期不再导致长片中途 seek 401

const STREAM_SIGN_TTL = 12 * 3600; // 秒；env.STREAM_SIGN_TTL 可覆盖

function signTtl(env) {
  const v = parseInt(env.STREAM_SIGN_TTL || '', 10);
  return Number.isFinite(v) && v > 0 ? v : STREAM_SIGN_TTL;
}

async function signStreamPath(filePath, env) {
  const exp = Math.floor(Date.now() / 1000) + signTtl(env);
  const sig = await hmacHex(env.AUTH_SECRET, `${filePath}|${exp}`);
  return { exp, sig };
}

async function verifyStreamSig(url, env) {
  // 本函数在鉴权短路里被 await，而鉴权块在路由 try/catch 之外 ——
  // 任何意外抛错（crypto 环境异常等）会绕过统一 500，产生不可控的运行时错误。
  // 整体兜底：出错一律按「未通过」处理（fail-closed），绝不 fail-open。
  try {
    const filePath = url.searchParams.get('path') || '';
    const exp = parseInt(url.searchParams.get('exp') || '', 10);
    const sig = url.searchParams.get('sig') || '';
    if (!filePath || !sig || !Number.isFinite(exp)) return false;
    if (exp * 1000 < Date.now()) return false; // 已过期
    const expect = await hmacHex(env.AUTH_SECRET, `${filePath}|${exp}`);
    return timingSafeEqualStr(sig, expect);
  } catch {
    return false;
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  CORS（冻结，零分配）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

const CORS_HEADERS = Object.freeze({
  'Access-Control-Allow-Origin':   '*',
  'Access-Control-Allow-Methods':  'GET, HEAD, POST, OPTIONS',
  'Access-Control-Allow-Headers':  'Content-Type, Range, If-Range, If-None-Match',
  'Access-Control-Expose-Headers': 'Content-Range, Content-Length, ETag, Server-Timing, Retry-After, X-Stream-Mode',
  'Access-Control-Max-Age':        '86400',
});

function cors(response) {
  const h = new Headers(response.headers);
  for (const k in CORS_HEADERS) h.set(k, CORS_HEADERS[k]);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: h,
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  请求合并（Coalescing / Single-Flight）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  同一 key 的并发请求共享同一个 Promise，
//  避免 10 个用户同时打开页面 → 10 次 Dropbox API。

const _inflight = new Map();

function singleFlight(key, fn) {
  if (_inflight.has(key)) return _inflight.get(key);
  const p = fn().then(
    result => { _inflight.delete(key); return result; },
    err    => { _inflight.delete(key); throw err; },
  );
  _inflight.set(key, p);
  return p;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  并发控制（Semaphore 模式，比 worker-pool 更轻量）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function parallel(tasks, concurrency) {
  const results = new Array(tasks.length);
  let idx = 0;
  const run = async () => {
    while (idx < tasks.length) {
      const i = idx++;
      try { results[i] = await tasks[i](); } catch (e) { results[i] = e; }
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(concurrency, tasks.length) }, run)
  );
  return results;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  带重试 & 超时的 fetch
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  ⚠️ timeout 仅限制拿到响应头的时间，不截断 body 传输。
//  对流式视频代理至关重要：Dropbox 可能 2s 返回头，但 body
//  要传几分钟。如果 AbortController 在 body 传输中触发，
//  会直接截断播放。

async function fetchRetry(url, opts = {}, { retries = 2, timeout = 15_000 } = {}) {
  let lastErr;
  for (let i = 0; i <= retries; i++) {
    const ctrl = new AbortController();
    const tid = setTimeout(() => ctrl.abort(), timeout);
    try {
      const res = await fetch(url, { ...opts, signal: ctrl.signal });
      // ✅ 拿到响应头后立即 clear timeout，body 传输不受限制
      clearTimeout(tid);
      if ((res.status >= 500 || res.status === 429) && i < retries) {
        // 重试前显式 cancel 不再读的 body，释放连接（否则占用连接池）
        try { res.body && await res.body.cancel(); } catch {}
        // 429 优先尊重 Retry-After（秒；HTTP-date 解析不出则退化为退避），封顶 10s
        const ra = res.status === 429
          ? parseInt(res.headers.get('Retry-After') || '', 10)
          : NaN;
        await sleep(Number.isFinite(ra) && ra >= 0 ? Math.min(ra * 1000, 10_000) : 250 * (i + 1));
        continue;
      }
      return res;
    } catch (e) {
      // ✅ 修复：抛错路径此前不 clearTimeout，定时器泄漏到 timeout 才释放
      clearTimeout(tid);
      lastErr = e;
      // 超时（AbortError）与网络错误统一退避重试
      if (i < retries) await sleep(300 * (i + 1));
    }
  }
  throw lastErr || new Error('fetch failed after retries');
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Dropbox Token（单航班保护 + 内存缓存）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let _token = null;
let _tokenExp = 0;

function getAccessToken(env) {
  if (_token && Date.now() < _tokenExp - 300_000) {
    return Promise.resolve(_token);
  }
  return singleFlight('token', async () => {
    // Double-check after acquiring the flight
    if (_token && Date.now() < _tokenExp - 300_000) return _token;
    // 全链路最关键的单点：一次挂起会让 coalesce 在 singleFlight 上的所有
    // 请求集体等待 —— 8s 拿不到响应头就重试（共 3 次尝试）
    const res = await fetchRetry('https://api.dropboxapi.com/oauth2/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: env.DROPBOX_REFRESH_TOKEN,
        client_id: env.DROPBOX_APP_KEY,
        client_secret: env.DROPBOX_APP_SECRET,
      }),
    }, { retries: 2, timeout: 8_000 });
    if (!res.ok) throw new Error(`Token refresh failed (${res.status})`);
    const data = await res.json();
    if (!data.access_token) throw new Error('Token refresh: no access_token in response');
    _token = data.access_token;
    // expires_in 缺失兜底 4h：否则 _tokenExp = NaN，所有比较恒为 false，
    // 退化成每个请求都刷新 token
    _tokenExp = Date.now() + (data.expires_in ?? 14_400) * 1000;
    return _token;
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Dropbox API
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function dbxListFolder(folderPath, env, cursor = null) {
  const token = await getAccessToken(env);
  const endpoint = cursor
    ? 'https://api.dropboxapi.com/2/files/list_folder/continue'
    : 'https://api.dropboxapi.com/2/files/list_folder';
  const body = cursor
    ? { cursor }
    : { path: folderPath || '', recursive: false, limit: 2000 };
  const res = await fetchRetry(endpoint, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`list_folder failed: ${res.status}`);
  return res.json();
}

async function dbxGetTempLink(filePath, env) {
  const token = await getAccessToken(env);
  const res = await fetchRetry('https://api.dropboxapi.com/2/files/get_temporary_link', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: filePath }),
  });
  if (!res.ok) throw new Error(`get_temporary_link failed: ${res.status}`);
  return res.json();
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  R2 文件列表持久缓存（真 SWR：过期也先返回旧数据）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

const R2_KEY = 'file-list-v2.json';
const R2_TTL = 10 * 60_000;       // 10 min 新鲜
const R2_STALE_TTL = 60 * 60_000; // 60 min 过期但可用（SWR 窗口）

// 同一 Worker isolate 内的内存缓存（避免同一请求周期重复读 R2）
let _memCache = null;
let _memCacheTs = 0;
const MEM_TTL = 30_000; // 30s

async function r2Get(env, { allowExpired = false } = {}) {
  // 1. 内存缓存
  if (_memCache && Date.now() - _memCacheTs < MEM_TTL) return _memCache;

  if (!env.FILE_CACHE) return null;
  try {
    const obj = await env.FILE_CACHE.get(R2_KEY);
    if (!obj) return null;
    const data = await obj.json();
    const age = Date.now() - (data._ts || 0);
    // 超过 stale 窗口 → 视为无效；allowExpired 仅供 stale-if-error 兜底
    if (age > R2_STALE_TTL && !allowExpired) return null;
    // 只有窗口内的数据才写入内存缓存 —— 过期兜底数据若进内存层，
    // 后续 30s 内的请求会把它当「可用」数据、跳过本应发生的回源
    if (age <= R2_STALE_TTL) {
      _memCache = data;
      _memCacheTs = Date.now();
    }
    return data;
  } catch { return null; }
}

/** R2 数据是否在 TTL 内（新鲜） */
function r2IsFresh(data) {
  return data && (Date.now() - (data._ts || 0) < R2_TTL);
}

async function r2Put(env, payload) {
  if (!env.FILE_CACHE) return;
  try {
    const data = { ...payload, _ts: Date.now() };
    await env.FILE_CACHE.put(R2_KEY, JSON.stringify(data), {
      httpMetadata: { contentType: 'application/json' },
    });
    // 同步更新内存缓存
    _memCache = data;
    _memCacheTs = Date.now();
  } catch {}
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  版本指针 —— 内容寻址缓存的地基
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  核心换位：不去「让缓存失效」，而是「换个名字存」。
//  缓存键里带上一枚只由内容决定的指纹，于是
//    · 内容变 → 全球所有 PoP 的旧键瞬间无人问津（自然淘汰，无需逐出）
//    · 内容不变 → 命中率与从前一模一样，零额外回源
//  缓存失效这个分布式难题，就此退化成一次字符串拼接。
//
//  指针是三分量的，而不是一个总 gen：
//    g = 库快照指纹    → /api/all · /api/list
//    f = featured 成品 candHash → /api/featured
//    h = hero 成品 candHash     → /api/atv/hero
//  若三者共用一个总 gen，库里任意角落改一个文件都会把 hero / featured
//  的全球缓存一起打掉，白白回源 —— 分量化后各自只在自己真变了时才翻。
//
//  ★ 指针在成品落库之后才发布（warmCaches 末尾一次性写）。
//    顺序反了会出大事：新键先亮、旧内容后进 → 旧内容被钉死在新键上，
//    而新键的 s-maxage 是一天。发布顺序即正确性。
//
//  读取成本：5s isolate 内存层 → KV（cacheTtl，~1ms）→ R2 兜底。
//  LIB_STATE 未绑定也能跑，只是回退到 R2 读。

const PTR_KV_KEY = 'lib-ptr';
const PTR_R2_KEY = 'lib-ptr.json';
const PTR_MEM_TTL = 5_000;
const PTR_ZERO = Object.freeze({ g: '0', f: '0', h: '0' });

let _ptrMem = null, _ptrMemTs = 0;

/** 库内容指纹：条目数 + 每条 path:入库时间（新增/删除/改名/替换都会翻转） */
const libGen = videos =>
  fnv1a(videos.length + '|' + videos.map(v => `${v.path}:${v.added || v.modified || ''}`).join('\n'));

function ptrNorm(o) {
  return o && typeof o === 'object'
    ? { g: o.g || '0', f: o.f || '0', h: o.h || '0' }
    : { ...PTR_ZERO };
}

async function ptrGet(env) {
  if (_ptrMem && Date.now() - _ptrMemTs < PTR_MEM_TTL) return _ptrMem;
  let raw = null;
  if (env.LIB_STATE) {
    try { raw = await env.LIB_STATE.get(PTR_KV_KEY, { type: 'json', cacheTtl: 10 }); } catch {}
  }
  if (!raw) {
    try { raw = await r2GetJson(env, PTR_R2_KEY); } catch {}
  }
  // 冷启动兜底：还没有指针 → 用快照现算 g，f/h 归零（成品端点先走 R2 路径）
  if (!raw) {
    const d = await r2Get(env, { allowExpired: true });
    raw = d?.videos ? { g: d._gen || libGen(d.videos), f: '0', h: '0' } : null;
  }
  _ptrMem = ptrNorm(raw); _ptrMemTs = Date.now();
  return _ptrMem;
}

/** 发布指针：KV 与 R2 双写（KV 为主，R2 保证未绑定 KV 时也可用） */
async function ptrSet(env, ptr) {
  const p = ptrNorm(ptr);
  _ptrMem = p; _ptrMemTs = Date.now();
  await Promise.allSettled([
    env.LIB_STATE ? env.LIB_STATE.put(PTR_KV_KEY, JSON.stringify(p)) : null,
    r2PutJson(env, PTR_R2_KEY, p),
  ]);
  return p;
}

/** 落快照的唯一入口：算 g → 写 R2。指针交由调用方在成品就绪后发布 */
async function snapshotPut(env, data) {
  data._gen = libGen(data.videos);
  await r2Put(env, data);
  return data;
}

/** 快照写在成品之外的路径（SWR 后台刷新 / 冷启动回源）：
 *  只推进 g 分量，f/h 保持不动 —— 那两份成品此刻并没有重建 */
async function ptrBumpLib(env, gen) {
  const cur = await ptrGet(env);
  if (cur.g === gen) return cur;
  return ptrSet(env, { ...cur, g: gen });
}

async function handleGen(env, ctx) {
  const ptr = await ptrGet(env);
  const data = await r2Get(env, { allowExpired: true });
  // 前端本来就在轮询这个端点 —— 顺手当心跳，超龄就触发一次自愈
  if (!r2IsFresh(data)) kickWarm(env, ctx);
  return jsonResponse({
    gen: ptr.g, feat: ptr.f, hero: ptr.h,
    count: data?.videos?.length || 0,
    ts: data?._ts || 0,
  }, 200, { 'Cache-Control': 'no-store' });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  增量同步（list_folder/continue 游标 delta）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  全量递归 list_folder 的成本 ∝ 库大小；delta 的成本 ∝ 这次改了几个文件。
//  这一步是「webhook 来一次刷一次」在经济上成立的前提。

/** 拉取自 cursor 以来的全部变化；游标失效（409 reset）返回 null → 调用方全量兜底 */
async function dbxDelta(env, cursor) {
  const token = await getAccessToken(env);
  const entries = [];
  let cur = cursor;
  for (let guard = 0; guard < 200; guard++) {
    const res = await fetchRetry('https://api.dropboxapi.com/2/files/list_folder/continue', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ cursor: cur }),
    }, { retries: 1, timeout: 12_000 });
    if (res.status === 409) { try { await res.body?.cancel(); } catch {} return null; } // reset / 游标过期
    if (!res.ok) throw new Error(`delta failed: ${res.status}`);
    const page = await res.json();
    entries.push(...(page.entries || []));
    cur = page.cursor;
    if (!page.has_more) return { entries, cursor: cur };
  }
  throw new Error('delta: too many pages');
}

/** 把 delta 条目合并进上一份快照（纯函数，不碰网络）
 *  路径以小写为主键（Dropbox 路径大小写不敏感）。极端 Unicode 归一化差异
 *  下 path_lower 可能与 toLowerCase() 不完全一致 —— 由每 30min 的全量对账兜底。 */
function applyDelta(prev, entries) {
  const rootLen = prev.rootLen;
  const vids = new Map(prev.videos.map(v => [v.path.toLowerCase(), v]));
  const dirs = new Map(prev.folders.map(f => [f.path.toLowerCase(), f]));

  for (const e of entries) {
    const pl = e.path_lower || (e.path_display || '').toLowerCase();
    if (!pl) continue;

    if (e['.tag'] === 'deleted') {
      // 删目录时 Dropbox 只回一条 deleted —— 目录内条目须按前缀级联清理
      vids.delete(pl); dirs.delete(pl);
      const pfx = pl + '/';
      for (const k of vids.keys()) if (k.startsWith(pfx)) vids.delete(k);
      for (const k of dirs.keys()) if (k.startsWith(pfx)) dirs.delete(k);
      continue;
    }

    if (e['.tag'] === 'file') {
      // 改名成非视频扩展名 / 转码后换壳 → 从库里移除旧条目
      if (!VIDEO_EXTS.has(getExt(e.name))) { vids.delete(pl); continue; }
      vids.set(pl, {
        name: e.name, path: e.path_display, type: 'file',
        size: e.size || 0,
        modified: e.client_modified || null,
        added: e.server_modified || e.client_modified || null,
      });
      continue;
    }

    if (e['.tag'] === 'folder') {
      // folders 只收录根下一级（与全量路径的口径保持一致）
      if (e.path_display.slice(rootLen).split('/').filter(Boolean).length === 1) {
        dirs.set(pl, { name: e.name, path: e.path_display, type: 'folder' });
      }
    }
  }

  return {
    root: prev.root, rootLen,
    videos: [...vids.values()],
    folders: [...dirs.values()],
  };
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Dropbox Webhook —— 把 10 分钟轮询换成 2 秒推送
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Dropbox App Console → Webhooks 填 https://<worker>/dbx/webhook
//  · GET  ?challenge=xxx  → 原样回显（握手，必须 text/plain + nosniff）
//  · POST                 → X-Dropbox-Signature = HMAC-SHA256(APP_SECRET, raw body)
//  必须 10s 内返回 → 校验完立刻 200，真活儿丢给 waitUntil

let _warmSeq = 0;

/** 去抖：一次批量上传会连着来好几条通知，只让最后一条真正落地。
 *  去抖与 singleFlight 都是 isolate 内的 —— 两个 PoP 同时收到通知会各刷一次。
 *  delta 是幂等的（同一游标读到同一批变化），最坏情况只是多一次空转刷新。 */
function debouncedWarm(env, delay = 3_000) {
  const mine = ++_warmSeq;
  return sleep(delay).then(() => {
    if (mine !== _warmSeq) return;                       // 已被更晚的通知取代
    return singleFlight('warm', () => warmCaches(env)).catch(() => {});
  });
}

async function handleDbxWebhook(request, env, ctx) {
  const url = new URL(request.url);

  if (request.method === 'GET') {
    return new Response(url.searchParams.get('challenge') || '', {
      headers: {
        'Content-Type': 'text/plain',
        'X-Content-Type-Options': 'nosniff',
        'Cache-Control': 'no-store',
      },
    });
  }
  if (request.method !== 'POST') return new Response('Method Not Allowed', { status: 405 });
  if (!env.DROPBOX_APP_SECRET) return new Response('not configured', { status: 503 });

  // 签名覆盖的是「原始字节」——先 text() 再校验，不要提前 JSON.parse
  const raw = await request.text();
  const sig = request.headers.get('X-Dropbox-Signature') || '';
  let ok = false;
  try { ok = timingSafeEqualStr(sig, await hmacHex(env.DROPBOX_APP_SECRET, raw)); } catch {}
  if (!ok) return new Response('bad signature', { status: 403 });

  ctx?.waitUntil?.(debouncedWarm(env));
  return new Response('ok', { headers: { 'Cache-Control': 'no-store' } });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  缓存预热（scheduled cron 与 /api/refresh 共用）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Edge Cache 是按 PoP 的，cron 只能暖到自己所在机房 —— 因此把
//  featured / now-playing 的「成品」落 R2 作全局真源，edge 退化为
//  纯加速层。cron 常备成品后，冷路径（含 featured 首屏 modified
//  排序的过渡态）在正常运行时基本消失。

async function warmCaches(env, { force = false, full = false } = {}) {
  const out = { mode: 'full', videos: 0, folders: 0, delta: 0, gen: null, libChanged: false,
                featured: false, nowPlaying: false, atvHero: false, ms: 0 };
  const t0 = Date.now();

  // 1. 文件列表：优先游标增量，其次全量
  const prevSnap = await r2Get(env, { allowExpired: true });
  let fresh = null;

  if (!full && !force && prevSnap?._cursor && Array.isArray(prevSnap.videos)) {
    try {
      const d = await dbxDelta(env, prevSnap._cursor);
      if (d) {
        out.mode = d.entries.length ? 'delta' : 'noop';
        out.delta = d.entries.length;
        fresh = d.entries.length ? applyDelta(prevSnap, d.entries)
                                 : { root: prevSnap.root, rootLen: prevSnap.rootLen,
                                     videos: prevSnap.videos, folders: prevSnap.folders };
        fresh._cursor = d.cursor;
      }
    } catch { /* delta 失败（游标损坏 / 网络）→ 落回全量，不影响正确性 */ }
  }

  if (!fresh) {
    fresh = await fetchVideosFromDropbox(env);   // 自带 _cursor
    out.mode = 'full';
  }

  // g 只由内容决定：delta 空转 / 无关改动 → g 不变 → 全球缓存继续命中。
  // 快照始终回写：即使内容没变，也要推进 _ts（保住 SWR 新鲜窗）与游标。
  await snapshotPut(env, fresh);
  out.gen = fresh._gen;
  out.libChanged = fresh._gen !== prevSnap?._gen;
  out.videos = fresh.videos.length;
  out.folders = fresh.folders.length;

  // 指针的 f / h 分量 = 「R2 里那份成品实际对应的 candHash」。
  // 重建成功才推进，失败/跳过就保留旧值 —— 指针永远描述已经存在的东西，
  // 绝不描述「本该存在的东西」。
  const prevPtr = await ptrGet(env);
  let featPtr = prevPtr.f, heroPtr = prevPtr.h;

  // 指针发布：必须在所有成品落库之后。顺序反了 = 旧内容被钉死在新键上一整天。
  const publish = () => ptrSet(env, { g: fresh._gen, f: featPtr, h: heroPtr })
    .then(() => { out.ms = Date.now() - t0; return out; });

  // 2. atv-hero 成品：候选集变化 → 增量重建（只解析新面孔）；
  //    超龄 → 全量重建（顺便刷新商店素材 URL）
  try {
    const heroHash = atvHeroHash(fresh.videos);
    const ahPrev = await r2GetJson(env, R2_ATV_HERO_KEY);
    const ahAged = !ahPrev || Date.now() - (ahPrev._ts || 0) > ATV_HERO_R2_TTL;
    if (force || ahAged || ahPrev.candHash !== heroHash) {
      const reuse = (force || ahAged) ? null : ahPrev;      // 超龄/手动刷 = 不复用
      const built = await buildAtvHeroPool(env, fresh.videos, reuse);
      if (built.heroes.length) {
        await r2PutJson(env, R2_ATV_HERO_KEY, {
          heroes: built.heroes, misses: built.misses, candHash: heroHash, _ts: Date.now(),
        });
        out.atvHero = true;
        heroPtr = heroHash;
      }
    } else {
      heroPtr = ahPrev.candHash || heroPtr;                 // 无需重建：对齐现存成品
    }
  } catch {}

  if (!env.TMDB_API_KEY) return publish();

  // 3. featured 成品：候选集变化 或 超龄 才重建
  //    成品内嵌 releaseDate 记忆表 → 重建只为「新出现的片名」打 TMDB
  const candidates = featuredCandidates(fresh.videos);
  const candHash = fnv1a(candidates.map(v => v.path).join('\n'));
  const prev = await r2GetJson(env, R2_FEATURED_KEY);
  const aged = !prev || Date.now() - (prev._ts || 0) > FEATURED_R2_TTL;
  const changed = !prev || prev.candHash !== candHash;
  if (force || aged || changed) {
    try {
      const memo = (force || aged) ? null : prev?.memo;     // 超龄/手动刷 = 记忆表作废
      const built = await buildFeatured(candidates, FEATURED_MAX, env, memo);
      await r2PutJson(env, R2_FEATURED_KEY, {
        list: built.list, memo: built.memo, candHash, _ts: Date.now(),
      });
      out.featured = true;
      featPtr = candHash;
    } catch {}
  } else {
    featPtr = prev.candHash || featPtr;
  }

  // 4. now-playing 成品：只按超龄重建（院线片单以周为单位变化，
  //    与库内容无关，force 也不必强刷；它的缓存键不吃指针）
  const npPrev = await r2GetJson(env, R2_NP_KEY);
  if (!npPrev || Date.now() - (npPrev._ts || 0) > NP_R2_TTL) {
    try {
      const results = await buildNowPlaying(env);
      if (results.length) {
        await r2PutJson(env, R2_NP_KEY, { results, _ts: Date.now() });
        out.nowPlaying = true;
      }
    } catch {}
  }

  return publish();
}

// 成品超龄时的自愈（cron 缺位 / 构建持续失败的场景）：
// 节流到每分钟至多一次，singleFlight 保证同 isolate 内不叠跑
let _lastWarmKick = 0;

function kickWarm(env, ctx) {
  if (!ctx?.waitUntil) return;
  const now = Date.now();
  if (now - _lastWarmKick < 60_000) return;
  _lastWarmKick = now;
  ctx.waitUntil(singleFlight('warm', () => warmCaches(env)).catch(() => {}));
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /api/refresh
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function handleRefreshCache(env, ctx) {
  // 与 cron 共用 warm 路径；手动刷新语义 = 「我改了片库，且不信任任何缓存」
  //   → full: 全量重列（不吃游标）  force: hero/featured 弃用复用与记忆表重建
  const warmed = await singleFlight('warm', () => warmCaches(env, { force: true, full: true }));

  // v16：/api/all · /api/list · /api/featured · /api/atv/hero 的键都带 gen，
  // 内容一变旧键即刻无人访问 —— 那串「猜 d / 猜 n」的硬编码逐出已无必要，
  // 而且它本来也只能清掉当前 PoP。这里只剩与库无关的 now-playing 需要手动逐出。
  const cache = caches.default;
  const deletes = [];
  for (const n of [4, 6, 8, 10, 12]) {
    deletes.push(cache.delete(new Request(`${NP_CACHE}?n=${n}`)));
  }
  ctx?.waitUntil?.(Promise.allSettled(deletes));

  return jsonResponse({ ok: true, ...warmed, ts: new Date().toISOString() });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  重复影片 —— 识别 / 清理 / 邮件报告（v17）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  规则（按需求固定，不做花活）：
//    · 同一部片的多个文件 → 只保留 size 最大的那个，其余删除
//    · 同规格（同分辨率/HDR/来源/编码）如此，跨规格同样如此
//      —— 跨规格时若被删的那份分辨率更高（4K WEB-DL 小于 1080p REMUX），
//         报告里打 ⚠︎ 降规格 标记；行为不变，但你能一眼看见
//    · 删除走 Dropbox files/delete_v2 → 进回收站（30 天内可还原），不是抹掉
//
//  「哪些算同一部片」是这套东西唯一真正的难点。文件名千奇百怪，
//  单靠字符串相等只能抓到「同名不同后缀」这种最弱的重复。做法是给每个
//  文件生成 1~2 枚身份签名，共享任意一枚即并入同组（并查集）：
//    拉丁轨 l|集|卷|版本|年|去噪拉丁名  ←「阿凡达.Avatar.2009」↔「Avatar.2009」
//    中文轨 c|集|卷|版本|年|去噪中文名  ←「阿凡达.2009」  ↔「阿凡达.Avatar.2009」
//  签名前四段是「作用域」，任一不同即不同片：
//    集   SxxExx / 第N集 / EPnn
//    卷   CD1 / Disc2 / 第二碟      —— 漏了它会把上下两卷判成重复删掉半部
//    版本 导演剪辑 / 加长 / 未删减 / 公映 / IMAX / 修复 / 3D / 特别版
//         —— 不同版本是不同成品，绝不能拿 3 小时导剪去顶掉 2 小时公映版
//    年   发行年（取最后一个 ≤ 明年的 19xx/20xx —— Blade Runner 2049 那种
//         片名自带年份的，第一个匹配属于片名）
//  名字部分只剥「技术规格 + 语言字幕 + 营销填充」，与身份无关，剥掉安全。
//
//  自动删除的四道保险：
//    ① 阈值：参与自动删除的文件须 ≥ DUPE_MIN_MB（默认 200MB）
//       —— 预告片 / 样片 / 片段不会被当成正片的重复
//    ② 通名黑名单：trailer/sample/预告/片段… 这类名字只列出、永不自动删
//    ③ 认不出来就不碰：拿不到有效签名的文件（「01.mkv」这种裸集数）
//       不进任何组 —— 宁可漏判，不可错删
//    ④ 单轮上限 DUPE_MAX_DELETE（默认 50）—— 判定逻辑万一失手，
//       损失有天花板，且下一轮巡检前你已经收到邮件
//
//  端点
//    GET  /dupes                     重复列表页（可视化 + 一键清理）
//    GET  /api/dupes                 报告 JSON（键含 gen，边缘可长缓存）
//    GET  /api/dupes?mail=1          立刻把当前列表邮件发我
//    POST /api/dupes/prune?confirm=<gen|1>   执行清理（并发信）
//      confirm 用 gen：确认的就是你刚看到的那一份列表；片库中途变了
//      → 409 并回新报告，绝不「按旧列表删新文件」
//
//  环境变量（全部可选，缺省即只报告不删）
//    DUPE_AUTO_PRUNE = "1"   每日巡检自动执行清理（默认仅邮件报告）
//    DUPE_HOUR       = "1"   每日巡检的 UTC 小时（默认 1 ≈ 巴黎 03:00）
//    DUPE_MIN_MB     = "200" 参与自动删除的最小文件体积
//    DUPE_MAX_DELETE = "50"  单轮删除上限
//    RESEND_API_KEY  与登录 Worker（cuven-core）共用同一个 key
//    MAIL_FROM       默认 'Cuven Stream <noreply@cuven.online>'（域名已验证）
//    MAIL_TO         默认 yujie.lab@gmail.com
//    MAIL_TZ         默认 Europe/Paris（邮件里的时间按此排版）

const DUPE_R2_KEY   = 'dupes-v1.json';
const DUPE_MAIL_TO  = 'yujie.lab@gmail.com';   // env.MAIL_TO 可覆盖
const DUPE_MAIL_FROM = 'stream@cuven.us';      // env.MAIL_FROM 可覆盖
const DUPE_MAIL_MAX_ROWS = 60;                 // 邮件里最多列多少组，其余"另有 N 组"

function envInt(v, def, lo, hi) {
  const n = parseInt(v ?? '', 10);
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : def;
}
const dupeMinMb = env => envInt(env.DUPE_MIN_MB, 200, 0, 1_000_000);
const dupeLimit = env => envInt(env.DUPE_MAX_DELETE, 50, 1, 500);

function fmtSize(n) {
  const b = Number(n) || 0;
  if (b >= 1024 ** 3) return `${(b / 1024 ** 3).toFixed(2)} GB`;
  if (b >= 1024 ** 2) return `${(b / 1024 ** 2).toFixed(0)} MB`;
  if (b >= 1024) return `${(b / 1024).toFixed(0)} KB`;
  return `${b} B`;
}

// ── 规格解析（顺序即优先级，先命中先返回）──
const SPEC_RES = [
  [2160, /(?:2160[pi]|\b4k\b|uhd|ultra[\s._-]?hd)/i], [1440, /1440[pi]/i],
  [1080, /(?:1080[pi]|\bfhd\b)/i], [720, /(?:720[pi]|\bhd720\b)/i],
  [576, /576[pi]/i], [480, /480[pi]/i],
];
const SPEC_HDR = [
  ['DV', /(?:dolby[\s._-]?vision|dovi|\bdv\b|杜比视界)/i],
  ['HDR10+', /hdr[\s._-]?10\+|hdr10plus/i],
  ['HDR', /\bhdr\b|\bhlg\b/i],
];
const SPEC_CODEC = [
  ['H.265', /x265|h[\s._-]?265|hevc/i], ['AV1', /\bav1\b/i],
  ['H.264', /x264|h[\s._-]?264|\bavc\b/i],
];
const SPEC_SRC = [
  ['REMUX', /remux|原盘/i], ['BluRay', /blu[\s._-]?ray|bdrip|\bbd\b|bdmv|蓝光/i],
  ['WEB-DL', /web[\s._-]?dl/i], ['WEBRip', /web[\s._-]?rip|\bweb\b/i],
  ['HDTV', /hdtv/i], ['DVD', /dvdrip|\bdvd\b/i],
];

function specPick(table, s) {
  for (const [v, re] of table) if (re.test(s)) return v;
  return '';
}

/** 从文件名解析规格。key 用于判「同规格 / 跨规格」，label 用于展示 */
function parseSpec(name) {
  const res = specPick(SPEC_RES, name) || 0;
  const hdr = specPick(SPEC_HDR, name);
  const codec = specPick(SPEC_CODEC, name);
  const src = specPick(SPEC_SRC, name);
  const label = [res ? (res >= 2160 ? '4K' : `${res}p`) : '未标注', hdr, src, codec]
    .filter(Boolean).join(' · ');
  return { res, hdr, codec, src, label, key: `${res}|${hdr}|${codec}|${src}` };
}

// ── 身份签名 ──
//  去噪词表只含「技术规格 + 语言/字幕 + 营销填充」—— 与影片身份无关，剥掉安全。
const DUPE_NOISE_LAT = /\b(?:blu[\s._-]?ray|bdrip|bdmv|bd|web[\s._-]?rip|web[\s._-]?dl|web|hdtv|dvdrip|dvd|remux|uhd|4k|2160[pi]|1440[pi]|1080[pi]|720[pi]|576[pi]|480[pi]|hdr10\+?|hdr|hlg|dovi|dolby|vision|atmos|truehd|dts(?:[\s._-]?hd)?(?:[\s._-]?ma)?|ddp?\+?\d(?:\.\d)?|eac3|ac3|aac\d?|flac|opus|mp3|x26[45]|h[\s._-]?26[45]|hevc|avc|av1|10bit|8bit|60fps|30fps|24fps|proper|repack|internal|multi|dual|audio|subs?|chs|cht|eng|jpn|cn)\b/gi;
const DUPE_NOISE_CJK = /(?:国粤双语|国粤|国语|粤语|台配|英语|日语|韩语|双语|中英双字|中英字幕|简繁英字幕|简繁双字|简繁字幕|简体|繁体|中字|内嵌|外挂字幕|特效字幕|无水印|高清|超清|全景声|完整版|正式版)/g;

//  ★ 版本轨（导演剪辑 / 加长 / 未删减 / IMAX / 修复…）必须单独抽，且要从
//    「整个文件名」抽，不能靠留在标题里 —— 版本词几乎总在年份之后
//    （Aliens.1986.Extended.1080p），而标题是在年份处截断的，根本轮不到它。
//    第一版就是这么漏的：导演剪辑版被判成公映版的重复，差一点拿 3 小时的
//    导剪去顶掉 2 小时的公映版。版本进签名 → 不同版本各自成组，互不吞并。
const DUPE_VER = [
  ['导演剪辑', /(?:director'?s?[\s._-]?cut|\bdc\b|导演剪辑版?|导剪)/i],
  ['加长',     /(?:extended|加长版?)/i],
  ['未删减',   /(?:uncut|unrated|未删减版?|无删减)/i],
  ['最终剪辑', /(?:final[\s._-]?cut|最终剪辑版?)/i],
  ['公映',     /(?:theatrical|公映版|剧场版)/i],
  ['IMAX',     /\bimax\b/i],
  ['修复',     /(?:remaster(?:ed)?|修复|重制)/i],
  ['3D',       /\b3d\b/i],
  ['特别版',   /(?:special[\s._-]?edition|ultimate[\s._-]?edition|典藏版|收藏版|特别版)/i],
];
// 通名：命中即只列出、永不自动删除
const DUPE_GENERIC = new Set([
  'trailer', 'trailers', 'sample', 'samples', 'preview', 'teaser', 'clip', 'clips',
  'video', 'movie', 'output', 'untitled', 'new', 'temp', 'tmp', 'test', 'demo',
  '预告', '预告片', '样片', '片段', '花絮', '正片', '未命名', '新建', '测试',
]);
const DUPE_CJK_TEST = /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af]/;
const DUPE_YEAR_RE = /(?<!\d)((?:19|20)\d{2})(?!\d)/g;
const DUPE_SPEC_CUT = /[.\s_\-](?:2160[pi]|1440[pi]|1080[pi]|720[pi]|480[pi]|4k|uhd|blu[.\s_-]?ray|bdrip|web[.\s_-]?dl|web[.\s_-]?rip|hdtv|remux|x26[45]|h\.?26[45]|hevc|av1|aac|dts|flac|truehd|atmos|ddp?\d|hdr|dovi|10bit)/i;

/** 发行年 = 「最后一个不晚于明年」的 19xx/20xx。
 *  片名自带年份时（Blade Runner 2049 / 1917 / Space 1999）第一个匹配属于片名，
 *  取最后一个才对；2049 这种未来数字也就自然被上界挡在标题里。 */
function dupeTitleYear(name) {
  const base = name.replace(/\.[^.]+$/, '');
  const maxY = new Date().getUTCFullYear() + 2;
  let year = '', cut = -1;
  for (const m of base.matchAll(DUPE_YEAR_RE)) {
    const y = +m[1];
    if (y >= 1900 && y <= maxY) { year = m[1]; cut = m.index; }
  }
  const raw = cut >= 0 ? base.slice(0, cut) : base.split(DUPE_SPEC_CUT)[0];
  const title = raw.replace(/\[.*?\]|\{.*?\}|\(.*?\)/g, ' ')
    .replace(/[._]+/g, ' ').replace(/\s+/g, ' ').trim();
  return { title, year };
}

function dupeIdent(name) {
  const { title, year } = dupeTitleYear(name);
  // 剧集：SxxExx / 第N集 / EPnn 进签名 —— 不同集数天然不同组
  const epRaw = (name.match(/(?:S\d{1,2}[\s._-]?E\d{1,3}|第\s*\d{1,4}\s*[集話话]|\bEP\.?\d{1,3}\b)/i) || [''])[0];
  const ep = epRaw.toLowerCase().replace(/[^a-z0-9集話话]/g, '');
  // 分卷：CD1/CD2、Disc2、第二碟 —— 同样在年份之后出现，必须从整名抽。
  // 漏了它，「Movie.2001.CD1.avi / CD2.avi」会被判成同一部片的重复，
  // 然后把下半部删掉 —— 这是这套逻辑里后果最脏的一种误判
  const partRaw = (name.match(/\b(?:cd|disc|disk|dvd|part|pt)[\s._-]?\d{1,2}\b|第\s*[0-9一二三四五六七八九十]{1,2}\s*[部碟盘]/i) || [''])[0];
  const part = partRaw.toLowerCase().replace(/[\s._-]+/g, '');
  const ver = DUPE_VER.filter(([, re]) => re.test(name)).map(([k]) => k).join('+');

  const cleaned = ` ${(title || name).toLowerCase().replace(/&/g, ' and ')} `
    .replace(DUPE_NOISE_LAT, ' ').replace(DUPE_NOISE_CJK, ' ');
  // 按「非字母非数字」切词，中英混排的 token 保持完整（'流浪地球2' 不被拆开）
  const toks = cleaned.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const cjkT = [], latT = [];
  for (const tk of toks) (DUPE_CJK_TEST.test(tk) ? cjkT : latT).push(tk);
  // 中文片名的续集数字常被分隔符切开（「流浪地球 2」）→ 归回中文轨。
  // 不归的话：「流浪地球2」与「流浪地球 2」互不相认（漏判，无害），
  // 而「流浪地球2」与「流浪地球3」会因为都被削成「流浪地球」而合并（错删，致命）
  const latK = [], cjkExtra = [];
  for (const tk of latT) (cjkT.length && /^\d{1,2}$/.test(tk) ? cjkExtra : latK).push(tk);
  const lat = latK.join('');
  const cjk = cjkT.join('') + cjkExtra.join('');

  const scope = `${ep}|${part}|${ver}|${year}`;
  const sigs = [];
  if (lat.length >= 3) sigs.push(`l|${scope}|${lat}`);
  if (cjk.length >= 2) sigs.push(`c|${scope}|${cjk}`);
  // 两轨都短到不足以做签名（"Up"、纯数字名）→ 只在「有年份且不是纯数字」时
  // 才给一枚兜底签名。「01.mkv / 02.mkv」这类没有年份的裸集数文件因此
  // 拿不到任何签名 → 永不成组。识别不出来的东西就不要碰，这是底线
  if (!sigs.length) {
    const both = lat + cjk;
    if (both.length >= 2 && year && !/^\d+$/.test(both)) sigs.push(`n|${scope}|${both}`);
  }

  const generic = DUPE_GENERIC.has(lat) || DUPE_GENERIC.has(cjk);
  return { title: (title || name).trim(), year, ep, part, ver, sigs, generic };
}

/** 分组：共享任一签名即同组（并查集），组内按 size 降序，首个为保留者 */
function findDupeGroups(videos, { minMb = 200 } = {}) {
  const items = (videos || []).map((v, i) => ({
    i, name: v.name, path: v.path, size: v.size || 0, added: v.added || v.modified || null,
    id: dupeIdent(v.name), spec: parseSpec(v.name),
  }));

  const parent = items.map((_, i) => i);
  const find = x => { while (parent[x] !== x) { parent[x] = parent[parent[x]]; x = parent[x]; } return x; };
  const union = (a, b) => { a = find(a); b = find(b); if (a !== b) parent[b] = a; };

  const bySig = new Map();
  for (const it of items) {
    for (const s of it.id.sigs) {   // sigs 为空 = 无法识别 → 天然不进任何组
      const seen = bySig.get(s);
      if (seen === undefined) bySig.set(s, it.i); else union(seen, it.i);
    }
  }

  const buckets = new Map();
  for (const it of items) {
    const r = find(it.i);
    const arr = buckets.get(r);
    if (arr) arr.push(it); else buckets.set(r, [it]);
  }

  const minBytes = Math.max(0, minMb) * 1024 * 1024;
  const wire = it => ({
    name: it.name, path: it.path, size: it.size, added: it.added,
    spec: it.spec.label, res: it.spec.res,
  });

  const groups = [];
  const sum = { videos: items.length, groups: 0, files: 0, reclaim: 0, same: 0, cross: 0, downgrade: 0, hold: 0 };

  for (const mem of buckets.values()) {
    if (mem.length < 2) continue;
    // 保留规则：size 降序 → 入库时间新者优先 → path 字典序（保证幂等）
    mem.sort((a, b) =>
      b.size - a.size ||
      (Date.parse(b.added || 0) || 0) - (Date.parse(a.added || 0) || 0) ||
      a.path.localeCompare(b.path));

    const keep = mem[0], losers = mem.slice(1);
    const sameSpec = losers.every(d => d.spec.key === keep.spec.key);
    const maxLoserRes = Math.max(...losers.map(d => d.spec.res));
    const downgrade = keep.spec.res > 0 && maxLoserRes > keep.spec.res;

    const drop = losers.map(d => {
      let hold = '';
      if (keep.id.generic || d.id.generic) hold = '通名';
      else if (d.size <= 0 || keep.size <= 0) hold = '体积未知';
      else if (d.size < minBytes || keep.size < minBytes) hold = `小于 ${minMb}MB`;
      return { ...wire(d), hold, delta: keep.size - d.size };
    });

    const reclaim = drop.reduce((n, d) => n + (d.hold ? 0 : d.size), 0);
    const live = drop.filter(d => !d.hold).length;
    groups.push({
      title: keep.id.title, year: keep.id.year, ep: keep.id.ep, ver: keep.id.ver,
      kind: sameSpec ? 'same' : 'cross', downgrade,
      keep: wire(keep), drop, reclaim, live,
    });

    sum.groups++;
    sum.files += live;
    sum.hold += drop.length - live;
    sum.reclaim += reclaim;
    if (sameSpec) sum.same++; else sum.cross++;
    if (downgrade) sum.downgrade++;
  }

  // 能省的空间多的排前面 —— 报告与清理的优先级一致
  groups.sort((a, b) => b.reclaim - a.reclaim || b.drop.length - a.drop.length);
  return { groups, summary: sum, minMb };
}

async function buildDupeReport(env, ctx, { minMb } = {}) {
  const snap = await fetchAllVideosList(env, ctx);
  const mb = minMb ?? dupeMinMb(env);
  const r = findDupeGroups(snap?.videos || [], { minMb: mb });
  const gen = snap?._gen || (await ptrGet(env)).g;
  return { ok: true, ts: new Date().toISOString(), gen, ...r };
}

/** 报告指纹：只由「哪些文件被判为重复」决定 —— 用来避免每天重复发同一封信 */
const dupeHash = report => fnv1a(
  report.groups.map(g => `${g.keep.path}<${g.drop.map(d => d.path).join(',')}`).join('\n')
);

// ── 删除 ──
//  delete_v2 → 移入 Dropbox 回收站（30 天内可还原）。逐个删而非 delete_batch：
//  拿得到每个文件的成败，邮件报告才能说清「删了哪几个、哪个失败了、为什么」。

async function dbxDeleteFile(filePath, env) {
  const token = await getAccessToken(env);
  const res = await fetchRetry('https://api.dropboxapi.com/2/files/delete_v2', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: filePath }),
  }, { retries: 1, timeout: 15_000 });
  if (res.ok) { try { await res.body?.cancel(); } catch {} return { ok: true }; }
  let detail = '';
  try { detail = (await res.json())?.error_summary || ''; } catch {}
  return { ok: false, error: detail || `HTTP ${res.status}` };
}

async function pruneDupes(env, report, { limit }) {
  const targets = [];
  for (const g of report.groups) {
    for (const d of g.drop) {
      if (!d.hold) targets.push({ ...d, title: g.title, year: g.year, keepName: g.keep.name, kind: g.kind });
    }
  }
  const batch = targets.slice(0, limit);
  const results = await parallel(batch.map(t => () => dbxDeleteFile(t.path, env)), 4);

  const deleted = [], failed = [];
  batch.forEach((t, i) => {
    const r = results[i];
    if (r && r.ok) deleted.push(t);
    else failed.push({ ...t, error: (r && (r.error || r.message)) || 'unknown' });
  });
  return {
    attempted: batch.length,
    deferred: Math.max(0, targets.length - batch.length),
    freed: deleted.reduce((n, d) => n + d.size, 0),
    deleted, failed, ts: new Date().toISOString(),
  };
}

/** 就地把删掉的条目从快照里摘掉：立刻正确、零回源，并推进 g 指针 */
async function snapshotDrop(env, paths) {
  const snap = await r2Get(env, { allowExpired: true });
  if (!snap?.videos) return null;
  const gone = new Set(paths.map(p => p.toLowerCase()));
  const videos = snap.videos.filter(v => !gone.has((v.path || '').toLowerCase()));
  if (videos.length === snap.videos.length) return null;
  const next = await snapshotPut(env, { ...snap, videos });
  await ptrBumpLib(env, next._gen);
  return next._gen;
}

/** 删除之后的收尾：摘快照 → 重建成品。
 *  ⚠️ 这里刻意不复用 singleFlight('warm')：cron 每分钟都在起 warm，
 *  那把锁里装着的很可能是一个「在删除动作之前就已起飞」的航班 —— 拿回来的
 *  是删除前的库，于是 deferred 的文件下一轮还在名单里、已删的文件被反复
 *  重试 404。用一次性键，保证这趟航班看到的是删除后的世界。 */
async function afterPrune(env, ctx, prune) {
  if (!prune.deleted.length) return null;
  const gen = await snapshotDrop(env, prune.deleted.map(d => d.path));
  const job = singleFlight(`warm-post-prune:${Date.now()}`, () => warmCaches(env, { full: true })).catch(() => {});
  if (ctx?.waitUntil) ctx.waitUntil(job); else await job;
  return gen;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  邮件 —— 与 cuven-core（登录 Worker）同一条通道、同一套版式
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  没有另起一套：Resend + 同样的 RESEND_API_KEY / MAIL_FROM，
//  版式沿用 persona 通知邮件那副瑞士国际主义骨架（mailShell）。
//  一个人的邮箱里不该出现两种「自己家」的信 —— 品牌一致性优先于实现方便。
//
//  · 凭据：与登录 Worker 共用同一个 Resend key，发件域名 cuven.online
//  · MAIL_FROM 默认 'Cuven Stream <noreply@cuven.online>'
//    （域名同为已验证的 cuven.online，只换显示名 —— 影库的信与账户安全信
//     在收件箱里一眼可分，却仍是同一个发件域）
//  · 失败只记 console + 回传错误，绝不抛出：邮件发不出去不该让清理失败

const MAIL_FONT = "'Helvetica Neue',Helvetica,Arial,'PingFang TC','PingFang SC','Hiragino Sans','Microsoft YaHei',sans-serif";
const MAIL_BLUE = '#0047bb';
const MAIL_FROM_DEFAULT = 'Cuven Stream <noreply@cuven.online>';

async function sendMail(env, to, { subject, html, text }) {
  const rcpt = to || env.MAIL_TO || DUPE_MAIL_TO;
  if (!env.RESEND_API_KEY) {
    console.error('RESEND_API_KEY missing');
    return { ok: false, to: rcpt, error: 'RESEND_API_KEY 未配置（与登录 Worker 同一个 key）' };
  }
  const from = env.MAIL_FROM || MAIL_FROM_DEFAULT;
  try {
    const r = await fetchRetry('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${env.RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ from, to: [rcpt], subject, html, text }),
    }, { retries: 1, timeout: 10_000 });
    const j = await r.json().catch(() => null);
    if (r.ok) return { ok: true, via: 'resend', to: rcpt, id: j?.id || null };
    // 403 十有八九是 MAIL_FROM 的域名没在 Resend 验证 —— 把原文带回来，别猜
    console.error('Resend failed:', r.status, JSON.stringify(j || {}).slice(0, 240));
    return { ok: false, to: rcpt, error: `resend ${r.status} ${(j?.message || j?.name || '')}`.trim() };
  } catch (e) {
    console.error('Resend error:', e?.message || e);
    return { ok: false, to: rcpt, error: `resend ${String(e?.message || e).slice(0, 120)}` };
  }
}

/** 时间按巴黎时区排版（env.MAIL_TZ 可改）—— cron 里没有 request.cf 可用 */
function mailTime(tz) {
  const zone = tz || 'Europe/Paris';
  try {
    return new Intl.DateTimeFormat('zh-CN', {
      timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', hour12: false,
    }).format(new Date()) + ` (${zone})`;
  } catch {
    return new Date().toISOString().replace('T', ' ').slice(0, 16) + ' (UTC)';
  }
}

// ── 版面：瑞士国际主义（与 persona 通知邮件同源）──
//   白底、Helvetica、严格网格、一律左对齐、细线分栏、大量留白、零装饰。
//   层级靠字级与字重的悬殊比例拉开，而非颜色或色块；彩色只出现在「标记」上。
//   本文件多加一个 list 槽：重复清单是行级数据，硬塞进 rows 的键值网格会
//   把片名和文件名压成一坨 —— 但它仍然只用同一套字级、同一种细线、同一个
//   蓝色区段标记，视觉上与登录邮件出自同一只手。
//   保留 / 删除 不靠红绿区分，靠字重与删除线：KEEP 黑体、DEL 灰体加删除线。
function mailShell({ heading, zh, en, rows, big, list, footZh, footEn }) {
  const F = MAIL_FONT;
  const [hZh, hEn] = String(heading).split(' · ');

  const marker = t => `
      <tr><td style="padding:42px 0 0;font-family:${F};">
        <div style="border-top:1px solid #000000;padding-top:10px;font-size:9px;font-weight:700;letter-spacing:0.16em;color:${MAIL_BLUE};">${t}</div>
      </td></tr>`;

  const rowHtml = (rows || []).map(([k, v]) => {
    const [kZh, kEn] = String(k).split(' / ');
    return `
        <tr>
          <td style="padding:14px 30px 14px 0;border-top:1px solid #ededed;vertical-align:top;white-space:nowrap;font-family:${F};font-size:12px;color:#000000;">${escHtml(kZh || '')}<span style="font-size:9px;letter-spacing:0.09em;color:#bcbcbc;">&nbsp;&nbsp;${escHtml((kEn || '').toUpperCase())}</span></td>
          <td style="padding:14px 0;border-top:1px solid #ededed;font-family:${F};font-size:13px;line-height:1.5;color:#000000;word-break:break-word;vertical-align:top;">${escHtml(v)}</td>
        </tr>`;
  }).join('');

  const bigHtml = big ? `
      <tr><td style="padding:34px 0 2px;font-family:${F};">
        <div style="font-size:52px;font-weight:700;letter-spacing:0.1em;line-height:1.05;color:#000000;word-break:break-all;">${escHtml(big)}</div>
      </td></tr>` : '';

  const rowsHtml = rowHtml ? `
      <tr><td style="padding:34px 0 0;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">${rowHtml}
        </table>
      </td></tr>` : '';

  const listHtml = list ? `${marker('DUPLICATES')}
      <tr><td style="padding:6px 0 0;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">${list}
        </table>
      </td></tr>` : '';

  return `<!DOCTYPE html>
<html><body style="margin:0;padding:0;background:#ffffff;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#ffffff;">
  <tr><td align="center" style="padding:0 20px 60px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;text-align:left;">

      <tr><td style="padding:48px 0 0;font-family:${F};">
        <table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
          <tr>
            <td width="9" height="9" style="width:9px;height:9px;background:${MAIL_BLUE};font-size:0;line-height:0;">&nbsp;</td>
            <td style="padding-left:11px;font-size:11px;font-weight:700;letter-spacing:0.34em;color:#000000;white-space:nowrap;">STREAM</td>
          </tr>
        </table>
      </td></tr>

      <tr><td style="padding:62px 0 0;font-family:${F};">
        <div style="font-size:38px;font-weight:700;letter-spacing:-0.022em;line-height:1.2;color:#000000;word-break:break-word;">${escHtml(hZh || '')}</div>
        <div style="font-size:10px;letter-spacing:0.2em;line-height:1.6;color:#b4b4b4;padding-top:11px;">${escHtml((hEn || '').toUpperCase())}</div>
      </td></tr>
${marker('ZH')}
      <tr><td style="padding:13px 0 0;font-family:${F};font-size:14.5px;line-height:1.85;color:#000000;">${zh}</td></tr>
${bigHtml}${rowsHtml}
${marker('EN')}
      <tr><td style="padding:13px 0 0;font-family:${F};font-size:13px;line-height:1.85;color:#5a5a5a;">${en}</td></tr>
${listHtml}
      <tr><td style="padding:46px 0 0;font-family:${F};">
        <div style="border-top:1px solid #ededed;padding-top:17px;font-size:11px;line-height:1.7;color:#8a8a8a;">
          ${escHtml(footZh)}<br>${escHtml(footEn)}
        </div>
      </td></tr>

      <tr><td style="padding:34px 0 0;font-family:${F};">
        <div style="font-size:9px;letter-spacing:0.22em;color:#c8c8c8;">SECURED BY CUVEN LAB</div>
      </td></tr>

    </table>
  </td></tr>
</table>
</body></html>`;
}

/** 重复清单：每组一个标题行 + 每文件一行（标签 / 文件名 / 体积三栏） */
function dupeListHTML(groups) {
  const F = MAIL_FONT;
  const fileRow = (f, tag, dim, strike, note) => `
        <tr>
          <td style="padding:10px 14px 10px 0;border-top:1px solid #ededed;vertical-align:top;white-space:nowrap;font-family:${F};font-size:9px;font-weight:700;letter-spacing:0.14em;color:${dim ? '#bcbcbc' : '#000000'};">${tag}</td>
          <td style="padding:10px 14px 10px 0;border-top:1px solid #ededed;vertical-align:top;font-family:${F};font-size:12px;line-height:1.45;word-break:break-all;color:${dim ? '#8a8a8a' : '#000000'};${strike ? 'text-decoration:line-through;' : ''}">${escHtml(f.name)}
            <div style="font-size:9px;letter-spacing:0.09em;color:#bcbcbc;padding-top:3px;text-decoration:none;">${escHtml(f.spec)}${note ? ' · ' + escHtml(note) : ''}</div>
          </td>
          <td style="padding:10px 0;border-top:1px solid #ededed;vertical-align:top;text-align:right;white-space:nowrap;font-family:${F};font-size:12px;color:${dim ? '#8a8a8a' : '#000000'};">${fmtSize(f.size)}</td>
        </tr>`;

  return groups.slice(0, DUPE_MAIL_MAX_ROWS).map(g => {
    const meta = [
      g.kind === 'same' ? '同规格 / SAME SPEC' : '跨规格 / MIXED SPEC',
      g.ver ? `${g.ver}版` : '',
      `可释放 ${fmtSize(g.reclaim)}`,
    ].filter(Boolean).join(' · ');
    const head = `
        <tr><td colspan="3" style="padding:30px 0 6px;font-family:${F};">
          <div style="font-size:9px;font-weight:700;letter-spacing:0.14em;color:#bcbcbc;">${escHtml(meta)}${g.downgrade ? `<span style="color:#000000;"> · 降规格 / DOWNGRADE</span>` : ''}</div>
          <div style="font-size:15px;font-weight:700;letter-spacing:-0.01em;line-height:1.35;color:#000000;padding-top:5px;word-break:break-word;">${escHtml(g.title)}${g.year ? ` (${escHtml(g.year)})` : ''}${g.ep ? ` · ${escHtml(g.ep)}` : ''}</div>
        </td></tr>`;
    const keep = fileRow(g.keep, 'KEEP', false, false, '');
    const drops = g.drop.map(d => d.hold
      ? fileRow(d, 'SKIP', true, false, `跳过：${d.hold}`)
      : fileRow(d, 'DEL', true, true, '')).join('');
    return head + keep + drops;
  }).join('');
}

function dupeMailHTML(report, prune) {
  const s = report.summary;
  const rows = [
    ['时间 / Time', mailTime(report.tz)],
    ['库内 / Library', `${s.videos} 部`],
    ['重复组 / Groups', `${s.groups} 组`],
    [prune ? '已删除 / Deleted' : '可删除 / Removable',
      prune ? `${prune.deleted.length} 个文件` : `${s.files} 个文件`],
    [prune ? '已释放 / Reclaimed' : '可释放 / Reclaimable',
      fmtSize(prune ? prune.freed : s.reclaim)],
  ];
  if (s.hold) rows.push(['已跳过 / Skipped', `${s.hold} 个（体积过小或通名）`]);
  if (prune?.failed.length) rows.push(['失败 / Failed', `${prune.failed.length} 个：${prune.failed.slice(0, 3).map(f => f.error).join('；')}`]);
  if (prune?.deferred) rows.push(['顺延 / Deferred', `${prune.deferred} 个（单轮上限，下一轮继续）`]);

  const more = report.groups.length > DUPE_MAIL_MAX_ROWS
    ? `<tr><td colspan="3" style="padding:22px 0 0;font-family:${MAIL_FONT};font-size:11px;color:#8a8a8a;">另有 ${report.groups.length - DUPE_MAIL_MAX_ROWS} 组未列出，见 /dupes 完整列表。</td></tr>`
    : '';

  return mailShell({
    heading: prune ? '重复影片已清理 · Duplicates cleaned' : '发现重复影片 · Duplicates found',
    zh: prune
      ? `影库巡检已完成清理：每组只保留体积最大的那一个文件，其余移入 Dropbox 回收站（<b>30 天内可还原</b>）。明细见下。`
      : `影库巡检发现下列重复影片，本次<b>未做任何删除</b>。打开 <b>/dupes</b> 可一键清理，或设 <b>DUPE_AUTO_PRUNE=1</b> 让每日巡检自动执行。`,
    en: prune
      ? `Cleanup complete — the largest file in each group was kept, the rest moved to the Dropbox trash and recoverable for 30 days.`
      : `The library scan found the duplicates listed below. <b style="color:#000000">Nothing was deleted.</b> Open /dupes to clean them up in one tap.`,
    rows,
    list: dupeListHTML(report.groups) + more,
    footZh: '保留规则：同一部片一律保留体积最大的文件，同规格与跨规格一致；「降规格」表示保留者分辨率低于被删者。不同版本（导演剪辑 / 加长 / 未删减 / 公映）视为不同影片，不参与合并。',
    footEn: 'Rule: keep the largest file per title, regardless of spec. Different cuts are treated as different films.',
  });
}

function dupeMailText(report, prune) {
  const s = report.summary;
  const head = [
    `Cuven Stream · 重复影片${prune ? '已清理 / cleaned' : ' / duplicates found'}`,
    `${mailTime(report.tz)} · 库内 ${s.videos} 部`,
    `重复组 ${s.groups} · 可删文件 ${s.files} · 可释放 ${fmtSize(s.reclaim)} · 跨规格 ${s.cross} 组 · 跳过 ${s.hold}`,
  ];
  if (prune) head.push(`已删除 ${prune.deleted.length} 个 · 释放 ${fmtSize(prune.freed)} · 失败 ${prune.failed.length} · 顺延 ${prune.deferred}（回收站 30 天可还原）`);
  const body = report.groups.slice(0, DUPE_MAIL_MAX_ROWS).map(g => [
    ``,
    `▸ ${g.title}${g.year ? ` (${g.year})` : ''}${g.ep ? ` ${g.ep}` : ''}${g.ver ? ` [${g.ver}版]` : ''} — ${g.kind === 'same' ? '同规格' : '跨规格'}${g.downgrade ? ' ⚠︎降规格' : ''}`,
    `  KEEP ${g.keep.name} [${g.keep.spec} · ${fmtSize(g.keep.size)}]`,
    ...g.drop.map(d => `  ${d.hold ? 'SKIP' : 'DEL '} ${d.name} [${d.spec} · ${fmtSize(d.size)}]${d.hold ? `（${d.hold}）` : ''}`),
  ].join('\n')).join('\n');
  return head.join('\n') + '\n' + body + '\n';
}

async function dupeMail(env, report, prune) {
  const s = report.summary;
  report.tz = env.MAIL_TZ || 'Europe/Paris';
  const subject = prune
    ? `Cuven Stream · 已清理 ${prune.deleted.length} 个重复文件，释放 ${fmtSize(prune.freed)} / Duplicates cleaned`
    : `Cuven Stream · ${s.groups} 组重复影片，可释放 ${fmtSize(s.reclaim)} / Duplicates found`;
  return sendMail(env, env.MAIL_TO || DUPE_MAIL_TO, {
    subject,
    html: dupeMailHTML(report, prune),
    text: dupeMailText(report, prune),
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /api/dupes · /api/dupes/prune
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function handleDupes(url, request, env, ctx) {
  const t = timer();
  const wantMail = url.searchParams.get('mail') === '1';
  const minMb = envInt(url.searchParams.get('minMb'), dupeMinMb(env), 0, 1_000_000);
  const { g } = await ptrGet(env);
  const inm = request?.headers?.get('If-None-Match');

  // 报告是库快照的纯函数 → 键含 gen，库不变则边缘长驻，库一变旧键自然作废
  const cache = caches.default;
  const ck = new Request(`https://cache.internal/dupes-v1?g=${g}&m=${minMb}`);
  if (!wantMail) {
    const hit = await cache.match(ck);
    if (hit) {
      t.mark('edge-hit');
      const etag = hit.headers.get('ETag');
      if (inm && etag && inm === etag) {
        return new Response(null, { status: 304, headers: { ETag: etag, 'Server-Timing': t.header() } });
      }
      const h = new Headers(hit.headers);
      h.set('Server-Timing', t.header());
      return new Response(hit.body, { status: 200, headers: h });
    }
  }

  const report = await singleFlight(`dupes:${g}:${minMb}`, () => buildDupeReport(env, ctx, { minMb }));
  t.mark('scan');

  if (wantMail) {
    const mail = await dupeMail(env, report, null);
    t.mark('mail');
    return jsonResponse({ ...report, mail }, mail.ok ? 200 : 502, {
      'Cache-Control': 'no-store', 'Server-Timing': t.header(),
    });
  }

  const body = JSON.stringify(report);
  const etag = `W/"${fnv1a(body)}"`;
  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'public, max-age=30, s-maxage=86400, stale-while-revalidate=300',
    'ETag': etag,
    'Server-Timing': t.header(),
  };
  if (inm && inm === etag) {
    ctx?.waitUntil?.(cache.put(ck, new Response(body, { headers })));
    return new Response(null, { status: 304, headers });
  }
  const resp = new Response(body, { headers });
  ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
}

async function handleDupePrune(request, url, env, ctx) {
  if (request.method !== 'POST') {
    return jsonResponse({ error: 'POST required', hint: 'POST /api/dupes/prune?confirm=<gen|1>' }, 405);
  }
  // CSRF：Cookie 是 SameSite=Lax（跨站 POST 本就不带），再加一道同源校验。
  // curl / 脚本没有 Origin 头 → 放行。
  const origin = request.headers.get('Origin');
  if (origin) {
    let bad = true;
    try { bad = new URL(origin).host !== url.host; } catch {}
    if (bad) return jsonResponse({ error: 'cross-origin denied' }, 403);
  }

  let body = {};
  try { body = await request.json(); } catch {}
  const raw = url.searchParams.get('confirm') ?? (body?.confirm === true ? '1' : body?.confirm);
  const confirm = raw == null ? '' : String(raw);

  const report = await buildDupeReport(env, ctx, {});
  if (!confirm) {
    // 428：先看清楚再动手。返回的 gen 就是下一步该带的 confirm
    return jsonResponse({
      ok: false, error: 'confirm required', gen: report.gen,
      hint: `POST /api/dupes/prune?confirm=${report.gen}`,
      summary: report.summary,
    }, 428);
  }
  if (confirm !== '1' && confirm !== String(report.gen)) {
    // 你确认的是旧列表 —— 片库已经变了，绝不照旧列表删新文件
    return jsonResponse({
      ok: false, error: 'gen mismatch：片库已变化，请按新列表重新确认',
      gen: report.gen, summary: report.summary, groups: report.groups,
    }, 409);
  }

  const prune = await pruneDupes(env, report, { limit: dupeLimit(env) });

  // 删完立刻让库反映现实：g 翻转 → 全球边缘旧键作废 → 前端下一次请求即新库
  const newGen = await afterPrune(env, ctx, prune);

  const mail = url.searchParams.get('mail') === '0' ? { ok: false, error: 'skipped' }
    : await dupeMail(env, report, prune);

  ctx?.waitUntil?.(r2PutJson(env, DUPE_R2_KEY, {
    hash: dupeHash(report), summary: report.summary,
    lastPrune: { ts: prune.ts, deleted: prune.deleted.length, freed: prune.freed, failed: prune.failed.length },
    mail: mail.ok ? mail.via : mail.error, _ts: Date.now(),
  }));

  return jsonResponse({ ok: true, gen: newGen || report.gen, summary: report.summary, prune, mail });
}

// ── 每日巡检（挂在 cron 上）──
//  cron 可能每分钟触发 → 用 R2 里的 lastRunDay 记账保证一天一次；
//  「先落账、再干活」：抢在并发触发之前把日期写下去，宁可漏一天也不重复删。
async function dupeCron(env, ctx) {
  if (!env.FILE_CACHE) return;                        // 无 R2 无法记账 → 不跑
  if (env.DUPE_CRON === '0') return;
  const now = new Date();
  if (now.getUTCHours() !== envInt(env.DUPE_HOUR, 1, 0, 23)) return;

  const day = now.toISOString().slice(0, 10);
  const st = (await r2GetJson(env, DUPE_R2_KEY)) || {};
  if (st.lastRunDay === day) return;
  await r2PutJson(env, DUPE_R2_KEY, { ...st, lastRunDay: day, _ts: Date.now() });

  const report = await buildDupeReport(env, ctx, {});
  const hash = dupeHash(report);

  let prune = null;
  if (env.DUPE_AUTO_PRUNE === '1' && report.summary.files) {
    prune = await pruneDupes(env, report, { limit: dupeLimit(env) });
    await afterPrune(env, null, prune);   // cron 里同步做完，状态盘落的就是删完后的事实
  }

  // 发信条件：真删了东西，或者「重复列表」相比上次有变化。
  // 列表没变还天天发同一封信，只会训练你忽略这个发件人。
  const changed = hash !== st.hash;
  let mail = null;
  if (prune?.deleted.length || (report.summary.groups && changed)) {
    mail = await dupeMail(env, report, prune);
  }

  await r2PutJson(env, DUPE_R2_KEY, {
    lastRunDay: day, hash, summary: report.summary,
    lastPrune: prune
      ? { ts: prune.ts, deleted: prune.deleted.length, freed: prune.freed, failed: prune.failed.length }
      : (st.lastPrune || null),
    mail: mail ? (mail.ok ? mail.via : mail.error) : 'skipped(unchanged)',
    _ts: Date.now(),
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /health
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function handleHealth(env, request) {
  const c = {
    ts: new Date().toISOString(),
    token: false, account: null, folder: null,
    videos: 0, r2: false, status: 'checking',
    gen: null, snap: null, edge: null, hosts: null,
    extras: [],
  };

  // 可选功能配好了没有：部署之后看这几行就知道哪些在生效、缺什么
  const feat = async () => {
    let tx = '— 未配置（绑定 AUDIO_TX 或设 AUDIO_TX_URL；DTS / TrueHD 音轨不出现，见 README）';
    const svc = hlsTxService(env);
    if (svc) {
      const how = svc.via === 'binding' ? '已绑定' : `经 ${svc.via}`;
      try {
        const r = await svc.fetch('/');
        const guard = r.ok && /key=on/.test(await r.text().catch(() => ''));
        tx = r.ok ? `✅ ${how}，转码 Worker 在线${guard ? '，密钥一致' : ''}`
          : r.status === 401 ? `⚠️ ${how}，但密钥不对（两边的 AUDIO_TX_KEY 要填同一个值）`
          : `⚠️ ${how}，但转码 Worker 回 ${r.status}`;
        if (r.ok && svc.via !== 'binding' && !guard) tx += '（转码 Worker 没配 AUDIO_TX_KEY：公网地址谁都能调，建议两边都配）';
      } catch (e) { tx = `⚠️ ${how}，但转码 Worker 连不上`; }
    }
    c.extras = [
      ['DTS / TrueHD', tx],
      ['TMDB', env.TMDB_API_KEY ? '✅' : '❌ 未配 TMDB_API_KEY（海报、中文片名、剧集、预告片都靠它）'],
      ['OpenSubtitles', !osOn(env) ? '— 未配置' : env.OPENSUBTITLES_USERNAME ? '✅ 账号登录' : '⚠️ 只有 API Key（下载配额按共享出口 IP 算）'],
      ['剧集目录', `${tvRoot(env) || '/'}${tvMem && tvMem.root === tvRoot(env) ? ` · ${tvMem.series.length} 部` : ''}`],
      ['访问保护', env.AUTH_SECRET ? '✅ 需要登录' : '⚠️ 未开启（知道地址就能浏览和播放）'],
    ];
  };
  const featP = feat().catch(() => {});

  // v19：优选到底生效了没有，看这两行 —— colo 是打到了哪个 PoP，
  // RTT 是客户端到该 PoP 的握手往返（比任何 ping 值都诚实）。
  try {
    const cf = (request && request.cf) || {};
    const self = new URL(request.url).hostname;
    const rtt = cf.clientTcpRtt;
    c.edge = [cf.colo || '?', cf.country || '?',
      rtt == null ? 'RTT ?' : `RTT ${rtt}ms`,
      cf.httpProtocol || '?'].join(' · ');
    const hs = edgeHosts(env, self);
    c.hosts = hs.length > 1 ? hs.join(' · ') : `${hs[0] || self}（未配 EDGE_HOSTS）`;
  } catch {}

  if (!env.DROPBOX_REFRESH_TOKEN || !env.DROPBOX_APP_KEY || !env.DROPBOX_APP_SECRET) {
    c.status = '❌ Missing env vars';
    return healthHTML(c, 503);
  }

  let token;
  try {
    token = await getAccessToken(env);
    c.token = true;
  } catch (e) {
    c.status = `❌ Token: ${e.message}`;
    return healthHTML(c, 503);
  }

  // 并发：账户 + 目录 + R2
  const [acctP, listP, r2P] = await Promise.allSettled([
    fetch('https://api.dropboxapi.com/2/users/get_current_account', {
      method: 'POST', headers: { Authorization: `Bearer ${token}` },
    }).then(r => r.ok ? r.json() : null),

    fetch('https://api.dropboxapi.com/2/files/list_folder', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ path: env.ROOT_FOLDER || '', recursive: false, limit: 100 }),
    }).then(r => r.ok ? r.json() : null),

    env.FILE_CACHE ? env.FILE_CACHE.head(R2_KEY) : null,
  ]);

  if (acctP.status === 'fulfilled' && acctP.value) {
    // 健康页不需要登录：邮箱只露首字母与域名
    const em = String(acctP.value.email || '').replace(/^(.)[^@]*(@.*)$/, '$1***$2');
    c.account = `${acctP.value.name?.display_name} (${em})`;
  }
  if (listP.status === 'fulfilled' && listP.value) {
    const entries = listP.value.entries || [];
    c.folder = `${entries.filter(e => e['.tag'] === 'folder').length} dirs, ${entries.length} items`;
    c.videos = entries.filter(e => e['.tag'] === 'file' && VIDEO_EXTS.has(getExt(e.name))).length;
  }
  c.r2 = r2P.status === 'fulfilled' && !!r2P.value;

  // v16 增量管线自检：游标在不在、快照多久没动、指针三分量是否与快照同步
  try {
    const [snap, ptr] = await Promise.all([r2Get(env, { allowExpired: true }), ptrGet(env)]);
    if (snap) {
      const age = Math.max(0, Math.round((Date.now() - (snap._ts || 0)) / 1000));
      c.snap = `${snap.videos?.length || 0} 部 · ${age}s 前 · ${snap._cursor ? '游标就绪' : '⚠️ 无游标(将全量)'}`;
      // 指针落后于快照 = 上一轮 warm 中途失败；下一次 cron 会自动纠正
      const sync = !snap._gen || ptr.g === snap._gen ? '' : ' ⚠️落后';
      c.gen = `g:${ptr.g} f:${ptr.f} h:${ptr.h}${sync}`;
    }
  } catch {}

  c.status = c.account && c.folder ? '✅ OK' : '⚠️ Partial';
  await featP;

  return healthHTML(c, c.account ? 200 : 503);
}

function healthHTML(c, status) {
  const ok = status === 200;
  return new Response(`<!DOCTYPE html><html lang=zh-CN><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Health</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{min-height:100dvh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;background:#000;color:#f5f5f7}
.c{width:440px;max-width:92vw;background:#111;border-radius:20px;padding:28px;border:1px solid #222}.r{display:flex;justify-content:space-between;gap:16px;padding:10px 0;border-bottom:1px solid #1a1a1a;font-size:14px}.r span:last-child{text-align:right}.r:last-child{border:none}.l{color:#86868b;flex:none}.s{margin-top:16px;padding:12px;border-radius:12px;text-align:center;font-weight:600;font-size:15px}
.ok{background:rgba(48,209,88,.12);color:#30D158}.fail{background:rgba(255,69,58,.12);color:#FF453A}a{display:block;text-align:center;margin-top:12px;color:#0A84FF;text-decoration:none;font-size:14px}</style>
<body><div class=c>
<div class=r><span class=l>Token</span><span>${c.token ? '✅' : '❌'}</span></div>
<div class=r><span class=l>Account</span><span>${c.account || '—'}</span></div>
<div class=r><span class=l>Folder</span><span>${c.folder || '—'}</span></div>
<div class=r><span class=l>Videos</span><span>${c.videos}</span></div>
<div class=r><span class=l>R2 Cache</span><span>${c.r2 ? '✅' : '—'}</span></div>
<div class=r><span class=l>Snapshot</span><span>${escHtml(c.snap || '—')}</span></div>
<div class=r><span class=l>Pointer</span><span>${escHtml(c.gen || '—')}</span></div>
<div class=r><span class=l>Edge</span><span>${escHtml(c.edge || '—')}</span></div>
<div class=r><span class=l>入口</span><span>${escHtml(c.hosts || '—')}</span></div>
${(c.extras || []).map(([k, v]) => `<div class=r><span class=l>${escHtml(k)}</span><span>${escHtml(v)}</span></div>`).join('\n')}
<div class="s ${ok ? 'ok' : 'fail'}">${c.status}</div>
<a href="/">← Back</a></div>`, {
    status,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' },
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /api/list
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function handleList(url, request, env, ctx) {
  const t = timer();
  const root = env.ROOT_FOLDER || '';
  const sub = url.searchParams.get('path') || '';
  const folder = sub ? `${root}${sub}` : root;

  // Worker 生成的响应不会因 Cache-Control 自动进 CF Edge Cache
  //（s-maxage 对 Worker 响应是空转的）—— 必须显式走 caches.default。
  // 此前这里等于零缓存：每个用户每次进目录都在串行分页打 Dropbox。
  // v16：键里带库版本 gen —— 库一变，旧键全球同时「自然作废」，
  // 不必再靠 s-maxage 熬时间，也不必枚举子目录键去逐出
  const { g } = await ptrGet(env);
  const cache = caches.default;
  const cacheKey = new Request(
    `https://cache.internal/list-v2?f=${encodeURIComponent(folder)}&g=${g}`
  );
  const inm = request.headers.get('If-None-Match');

  const cached = await cache.match(cacheKey);
  if (cached) {
    t.mark('edge-hit');
    const etag = cached.headers.get('ETag');
    if (inm && etag && inm === etag) {
      return new Response(null, {
        status: 304,
        headers: { ETag: etag, 'Server-Timing': t.header() },
      });
    }
    const h = new Headers(cached.headers);
    h.set('Server-Timing', t.header());
    return new Response(cached.body, { status: 200, headers: h });
  }

  // 按 folder path 合并：同一目录的并发冷请求只打一次 Dropbox
  const items = await singleFlight(`list:${folder}`, async () => {
    const entries = [];
    let result = await dbxListFolder(folder, env);
    entries.push(...result.entries);
    while (result.has_more) {
      result = await dbxListFolder(null, env, result.cursor);
      entries.push(...result.entries);
    }
    return entries
      .filter(e => e['.tag'] === 'folder' || VIDEO_EXTS.has(getExt(e.name)))
      .map(e => ({
        name: e.name, path: e.path_display, type: e['.tag'],
        size: e.size || 0,
        modified: e.client_modified || null,
        added: e.server_modified || e.client_modified || null,
      }))
      .sort((a, b) =>
        a.type !== b.type
          ? (a.type === 'folder' ? -1 : 1)
          : a.name.localeCompare(b.name)
      );
  });
  t.mark('dropbox');

  const body = JSON.stringify({ folder, items });
  const etag = `W/"${fnv1a(body)}"`;
  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    // 键含 gen → 边缘副本可长命；浏览器侧收短，新片才「刷一下就在」
    'Cache-Control': 'public, max-age=30, s-maxage=86400, stale-while-revalidate=300',
    'ETag': etag,
    'Server-Timing': t.header(),
  };

  if (inm && inm === etag) {
    ctx?.waitUntil?.(cache.put(cacheKey, new Response(body, { headers })));
    return new Response(null, { status: 304, headers });
  }

  const resp = new Response(body, { headers });
  ctx?.waitUntil?.(cache.put(cacheKey, resp.clone()));
  return resp;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /api/all — 四层缓存：Edge → R2 → Coalesced Dropbox
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function fetchVideosFromDropbox(env) {
  const root = env.ROOT_FOLDER || '';
  const rootLen = root.length;
  const token = await getAccessToken(env);

  const all = [];
  let res = await fetchRetry('https://api.dropboxapi.com/2/files/list_folder', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: root || '', recursive: true, limit: 2000 }),
  });
  if (!res.ok) throw new Error(`list_folder failed: ${res.status}`);
  let page = await res.json();
  all.push(...page.entries);
  while (page.has_more) {
    res = await fetchRetry('https://api.dropboxapi.com/2/files/list_folder/continue', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ cursor: page.cursor }),
    });
    // 修复：此前 break 会把截断的「半个片库」当完整结果返回，随后被 r2Put
    // 持久化 10-60 min。改为抛错：SWR 后台刷新路径 .catch 吞掉 → 旧数据完好；
    // 冷路径由 stale-if-error 兜底（见 fetchAllVideosList）。
    if (!res.ok) throw new Error(`list_folder/continue failed: ${res.status}`);
    page = await res.json();
    all.push(...page.entries);
  }

  const videos = all
    .filter(e => e['.tag'] === 'file' && VIDEO_EXTS.has(getExt(e.name)))
    .map(e => ({
      name: e.name, path: e.path_display, type: 'file',
      size: e.size || 0,
      modified: e.client_modified || null,
      // added = server_modified：文件「落进 Dropbox」的时刻。
      // client_modified 是文件自称的时间，转存/下载来的片子常年停在很久以前
      // —— 拿它排「最新」，新片可能永远上不了首屏。
      added: e.server_modified || e.client_modified || null,
    }));

  const folders = all
    .filter(e => e['.tag'] === 'folder')
    .filter(e => e.path_display.slice(rootLen).split('/').filter(Boolean).length === 1)
    .map(e => ({ name: e.name, path: e.path_display, type: 'folder' }));

  // page.cursor：下次从这里接着取「变化的部分」（见 dbxDelta）
  return { root, rootLen, videos, folders, _cursor: page.cursor || null };
}

/** 单航班 + 内存 + R2 + Dropbox，真 SWR */
function fetchAllVideosList(env, ctx) {
  return singleFlight('video-list', async () => {
    // 1. R2（含内存缓存）
    const r2 = await r2Get(env);
    if (r2) {
      if (!r2IsFresh(r2) && ctx?.waitUntil) {
        // 过期但可用 → 立即返回旧数据，后台刷新。
        // 后台刷新单独 singleFlight：外层 'video-list' 只挡并发；stale 窗口内
        // 每个串行请求都会走到这里，不去重的话每个都触发一次全量递归
        // list_folder（目录大时这是 Dropbox 限流的主要来源）。
        // 这条路径只刷库快照、不重建成品 → 只推进指针的 g 分量
        ctx.waitUntil(
          singleFlight('video-list-refresh', () =>
            fetchVideosFromDropbox(env)
              .then(d => snapshotPut(env, d))
              .then(d => ptrBumpLib(env, d._gen))
          ).catch(() => {})
        );
      }
      return r2;
    }
    // 2. R2 无新鲜数据 → 同步回源 Dropbox。
    //    stale-if-error：回源失败时允许读超过 SWR 窗口的 R2 旧数据兜底
    //    —— Dropbox 整体故障时页面显示旧片库，而不是白屏。
    try {
      const fresh = await fetchVideosFromDropbox(env);
      // 指针要在返回前就位：调用方（/api/all）拿它拼本次响应的 edge key。
      // 若指针落后于内容，新内容会被写进旧键 —— 旧键正是别人正在读的键。
      fresh._gen = libGen(fresh.videos);
      await ptrBumpLib(env, fresh._gen);
      const put = snapshotPut(env, fresh);
      ctx?.waitUntil ? ctx.waitUntil(put) : await put;
      return fresh;
    } catch (e) {
      const stale = await r2Get(env, { allowExpired: true });
      if (stale) return stale;
      throw e;
    }
  });
}

// ── 通用 R2 JSON 读写（featured / now-playing 成品缓存用）──

async function r2GetJson(env, key) {
  if (!env.FILE_CACHE) return null;
  try {
    const obj = await env.FILE_CACHE.get(key);
    return obj ? await obj.json() : null;
  } catch { return null; }
}

async function r2PutJson(env, key, data) {
  if (!env.FILE_CACHE) return;
  try {
    await env.FILE_CACHE.put(key, JSON.stringify(data), {
      httpMetadata: { contentType: 'application/json' },
    });
  } catch {}
}

async function handleListAll(url, request, env, ctx) {
  const t = timer();
  const root = env.ROOT_FOLDER || '';
  // depth 参与 edge cache key，无界会被刷出海量缓存条目 → clamp 到 1..5；
  // NaN（depth=abc）归一到默认 3
  const rawDepth = parseInt(url.searchParams.get('depth') || '3', 10);
  const maxDepth = Math.min(Math.max(Number.isFinite(rawDepth) ? rawDepth : 3, 1), 5);

  // 只吃 g 分量：hero / featured 成品重建不该把片库列表的全球缓存打掉
  const { g } = await ptrGet(env);
  const cacheKey = new Request(
    `https://cache.internal/all-v2?r=${encodeURIComponent(root)}&d=${maxDepth}&g=${g}`
  );
  const cache = caches.default;
  const cached = await cache.match(cacheKey);
  const inm = request.headers.get('If-None-Match');

  if (cached) {
    t.mark('edge-hit');
    const etag = cached.headers.get('ETag');
    if (inm && etag && inm === etag) {
      return new Response(null, {
        status: 304,
        headers: { ETag: etag, 'Server-Timing': t.header() },
      });
    }
    const h = new Headers(cached.headers);
    h.set('Server-Timing', t.header());
    return new Response(cached.body, { status: 200, headers: h });
  }

  const data = await fetchAllVideosList(env, ctx);
  t.mark('origin');

  // 回源可能带回比指针更新的内容（冷路径自己就刚推进过指针）——
  // 按数据自身的指纹落键，避免把新内容写进一个即将没人读的旧键
  const gKey = data._gen || g;
  const putKey = gKey === g ? cacheKey : new Request(
    `https://cache.internal/all-v2?r=${encodeURIComponent(root)}&d=${maxDepth}&g=${gKey}`
  );

  const videos = data.videos.filter(v =>
    v.path.slice(data.rootLen).split('/').filter(Boolean).length <= maxDepth
  );

  const body = JSON.stringify({ root: data.root, videos, folders: data.folders });
  const etag = `W/"${fnv1a(body)}"`;

  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'public, max-age=30, s-maxage=86400, stale-while-revalidate=600',
    'ETag': etag,
    'Server-Timing': t.header(),
  };

  if (inm && inm === etag) {
    ctx?.waitUntil?.(cache.put(putKey, new Response(body, { headers })));
    return new Response(null, { status: 304, headers });
  }

  const resp = new Response(body, { headers });
  ctx?.waitUntil?.(cache.put(putKey, resp.clone()));
  return resp;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /api/featured
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// v15 的 max-age=7200/s-maxage=14400 是「新片要等 4 小时」的元凶之一：
// 键不含内容版本，只能靠 TTL 熬。v16 键含 gen → 边缘随便存，浏览器收到 60s。
const FEATURED_CC = 'public, max-age=60, s-maxage=86400, stale-while-revalidate=600';
const R2_FEATURED_KEY = 'featured-v1.json'; // { list, candHash, _ts } —— top-16 精排成品
const FEATURED_MAX = 16;                    // = n 的上限；任意 n ≤ 16 由成品切片
const FEATURED_R2_TTL = 6 * 3600_000;       // 成品 6h 内不因时间原因重建（候选变了另算）

/** 候选：最近修改的前 limit 个。预计算 timestamp —— 比较器里
 *  new Date(b) - new Date(a) 每次比较创建 2 个 Date 对象，列表大时
 *  白白多几千次分配。 */
function featuredCandidates(videos, limit = 60) {
  return videos
    .filter(v => v.added || v.modified)
    // v16：按 added（server_modified，入库时刻）排。用 client_modified 排
    // 会让「刚下好的 2011 年老片」永远排在候选集之外 —— 上新根本进不来。
    .map(v => ({ v, ts: Date.parse(v.added || v.modified) || 0 }))
    .sort((a, b) => b.ts - a.ts)
    .slice(0, limit)
    .map(x => x.v);
}

async function handleFeatured(url, env, ctx) {
  const t = timer();
  // 修复：此前只 Math.min(parseInt(...), MAX)，缺 NaN / 下界防护 ——
  //   ?n=abc → NaN → slice(0, NaN) 返回空数组（首页精选整块消失）
  //   ?n=0   → slice(0, 0) 同样为空
  //   ?n=-2  → slice(0, -2) 悄悄砍掉尾部
  // 与 /api/now-playing 对齐：NaN/0/负数归一到默认 8，再 clamp 到 1..MAX。
  const n = Math.min(Math.max(parseInt(url.searchParams.get('n') || '8', 10) || 8, 1), FEATURED_MAX);
  // 吃 f 分量（= 成品 candHash）：库里改了一部没进候选的老片，
  // featured 的全球缓存纹丝不动
  const { f } = await ptrGet(env);
  const cache = caches.default;
  const cacheKey = new Request(`https://cache.internal/feat-v3?n=${n}&f=${f}`);

  // 1. 本 PoP edge（纯加速层）
  const cached = await cache.match(cacheKey);
  if (cached) {
    t.mark('edge-hit');
    const h = new Headers(cached.headers);
    h.set('Server-Timing', t.header());
    return new Response(cached.body, { headers: h });
  }

  // 2. R2 成品（cron 预热的全局真源）：任意 n ≤ 16 直接切片。
  //    冷启动从「秒级 TMDB 精排」变成一次 R2 读（~10-30ms）
  const art = await r2GetJson(env, R2_FEATURED_KEY);
  if (art?.list?.length) {
    t.mark('r2');
    // 超龄 = cron 缺位或构建持续失败 → 节流自愈，本次仍用旧成品秒回
    if (Date.now() - (art._ts || 0) > FEATURED_R2_TTL) kickWarm(env, ctx);
    const resp = new Response(JSON.stringify({ featured: art.list.slice(0, n) }), {
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': FEATURED_CC,
        'Server-Timing': t.header(),
      },
    });
    ctx?.waitUntil?.(cache.put(cacheKey, resp.clone()));
    return resp;
  }

  // 3. 无成品（首次部署 / cron 未启用 / R2 未绑定）→ SWR 冷路径：
  //    立即按 modified 排序秒回，TMDB 精排转后台；
  //    后台产物同时写 R2 成品（全局）+ 本 PoP edge
  const { videos } = await fetchAllVideosList(env, ctx);
  t.mark('list');
  if (!videos.length) return jsonResponse({ featured: [] });

  const candidates = featuredCandidates(videos);

  if (ctx?.waitUntil) {
    ctx.waitUntil(
      singleFlight('feat-build', async () => {
        const built = await buildFeatured(candidates, FEATURED_MAX, env);
        const list = built.list;
        const candHash = fnv1a(candidates.map(v => v.path).join('\n'));
        await r2PutJson(env, R2_FEATURED_KEY, { list, memo: built.memo, candHash, _ts: Date.now() });
        await cache.put(cacheKey, new Response(JSON.stringify({ featured: list.slice(0, n) }), {
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'Cache-Control': FEATURED_CC,
          },
        }));
      }).catch(() => {})
    );
    t.mark('quick');
    // 快速版本只让浏览器缓存 60s、不写 Edge —— 避免抢在精排版本之前占坑
    return new Response(JSON.stringify({ featured: candidates.slice(0, n) }), {
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'public, max-age=60',
        'Server-Timing': t.header(),
      },
    });
  }

  // 无 waitUntil 的兜底（正常运行时不会走到）：同步精排，保持旧行为
  const featured = (await buildFeatured(candidates, n, env)).list;
  t.mark('tmdb');
  return new Response(JSON.stringify({ featured }), {
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': FEATURED_CC,
      'Server-Timing': t.header(),
    },
  });
}

/** TMDB 精排：并发查发行日期 → releaseDate > releaseYear > 入库时间
 *  v16：memo（title|year → {d, y}）随成品一起落 R2。发行日期是死数据，
 *  查过一次就不必再查 —— 候选集变一部，只为那一部打 TMDB（原来是 ~60 部全打）。
 *  传 memo = null 表示作废重查（超龄重建 / 手动 refresh）。
 *  返回 { list, memo }。 */
const FEAT_MEMO_MAX = 400;

async function buildFeatured(candidates, n, env, memo = null) {
  const memoIn = memo && typeof memo === 'object' ? memo : {};
  const memoOut = {};
  const withMeta = [];

  await parallel(
    candidates.map(video => async () => {
      const pf = parseFilename(video.name);
      const { title, year } = pf;
      const key = `${title || video.name}|${year || ''}`;
      let releaseDate = null;
      let releaseYear = year ? parseInt(year, 10) : 0;

      const cached = memoIn[key];
      if (cached) {
        releaseDate = cached.d || null;
        releaseYear = cached.y || releaseYear;
      } else if (title) {
        try {
          const p = await fetchMetadata(pf, '', false, env);
          if (p?.release_date) {
            releaseDate = p.release_date;
            releaseYear = parseInt(p.release_date.slice(0, 4), 10) || releaseYear;
          } else if (p?.year) {
            releaseYear = parseInt(p.year, 10) || releaseYear;
          }
        } catch {}
      }
      memoOut[key] = { d: releaseDate, y: releaseYear };

      // mts 预计算：排序 tiebreaker 不再反复 new Date；
      // 用 added（入库时间）而非 client_modified，见 fetchVideosFromDropbox 注释
      withMeta.push({
        video, releaseDate, releaseYear,
        mts: Date.parse(video.added || video.modified || '') || 0,
      });
    }),
    8,
  );

  withMeta.sort((a, b) => {
    if (a.releaseDate && b.releaseDate) return b.releaseDate.localeCompare(a.releaseDate);
    if (b.releaseYear !== a.releaseYear) return b.releaseYear - a.releaseYear;
    return b.mts - a.mts;
  });

  // memoOut 只含本轮候选 → 自然随候选集收缩，不会无限膨胀；再加个硬上限兜底
  const keys = Object.keys(memoOut);
  const trimmed = keys.length > FEAT_MEMO_MAX
    ? Object.fromEntries(keys.slice(0, FEAT_MEMO_MAX).map(k => [k, memoOut[k]]))
    : memoOut;

  return { list: withMeta.slice(0, n).map(m => m.video), memo: trimmed };
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /api/now-playing — 最近上映的院线电影（海报 + Logo 组合）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  设计要点：
//   1. 双区并发：region=CN 优先（贴近院线片单），无 region 全球榜兜底，
//      合并去重后 CN 结果排前 —— CN 数据稀疏时依然满额。
//   2. Logo 优先：为固定 16 个候选并发拉取 images，挑 PNG Logo
//      （zh > en > 任意 PNG > 任意），带 Logo 的影片优先排前，
//      任意 n ≤ 12 由这份有序列表切片 —— 一份成品服务所有 n。
//   3. 零额外请求的类型名：TMDB now_playing 只回 genre_ids，
//      电影类型表数年不变，内置 zh-CN 静态映射即可，省一次 API。
//   4. 缓存：R2 成品（cron 每 6h 重建）为全局真源 → Edge（按 PoP 加速）。
//      院线片单以周为单位变化，正常运行时该端点没有冷路径。

/* ────────────────────────────────────────────────────────────
 *  Apple TV 桥（uts-api）—— /api/atv/lookup · /api/atv/search
 *
 *  tv.apple.com 同源接口直连，无需任何密钥。关键参数 pfm=appletv：
 *  只有它放出全量目录（TV+ 与商店片）；pfm=web 仅剩 TV+。
 *  预告片为公开 HLS（avc1 SDR → hvc1 杜比视界 PQ 全档），无 DRM。
 * ──────────────────────────────────────────────────────────── */
const UTS_BASE = 'https://uts-api.itunes.apple.com/uts/v3';
const UTS_PARAMS = Object.freeze({
  utscf: 'OjAAAAAAAAA~',
  utsk: '6e3013c6d6fae3c2::::::235656c069bb0efb',   // tv.apple.com 网页端公开 token，多年未换
  caller: 'web', sf: '143441', v: '60',
  pfm: 'appletv',
  locale: 'en-US',
});
const ATV_CACHE = 'https://cache.internal/atv-v1';   // 合成 edge 缓存键前缀
// hero 同理：v15 是 30min 浏览器 + 6h 边缘，改 hero 只能靠手动 ATV_HERO_VER++
const ATV_CC = 'public, max-age=120, s-maxage=86400, stale-while-revalidate=86400';

async function utsGet(path, extra = {}) {
  const q = new URL(UTS_BASE + path);
  for (const [k, v] of Object.entries({ ...UTS_PARAMS, ...extra })) q.searchParams.set(k, v);
  try {
    const res = await fetchRetry(q.toString(), {
      headers: { 'Origin': 'https://tv.apple.com', 'User-Agent': 'Mozilla/5.0' },
      cf: { cacheTtl: 21600, cacheEverything: true },          // 子请求同样走 edge，6h
    }, { retries: 1, timeout: 8000 });
    return res.ok ? await res.json() : null;
  } catch (_) { return null; }
}

const atvFill  = (tpl, w, h, f) => tpl ? tpl.replace('{w}', w).replace('{h}', h).replace('{f}', f) : null;
const atvClamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
const atvOpts  = url => ({
  w: atvClamp(parseInt(url.searchParams.get('w')) || 1920, 320, 3840),
  pw: atvClamp(parseInt(url.searchParams.get('pw')) || 1080, 240, 2160),   // 竖版海报宽(hero 专用)
  f: ['webp', 'jpg', 'png'].includes(url.searchParams.get('f')) ? url.searchParams.get('f') : 'webp',
  video: url.searchParams.get('video') === '1',
});

// 详情页附加信息：预告片（Trailers shelf → playables.hlsUrl）+ 标题 logo + 4:3 内容图
// + 竖版全面屏图 contentImageTall（1680×3636，AR≈0.462，即 TV app 手机端 hero 官方素材；
//   实测最近发行片 12/12 全覆盖，搜索层不给、只在详情层）
function atvParseExtras(json) {
  const imgs = json?.data?.content?.images || {};
  const logoT = imgs.contentLogo;
  const shelf = (json?.data?.canvas?.shelves || []).find(s =>
    (s.items || []).some(i => i.type === 'Preview'));
  const trailers = (shelf?.items || [])
    .filter(i => i.type === 'Preview' && i.playables?.[0]?.assets?.hlsUrl)
    .map(i => ({ title: i.title, hls: i.playables[0].assets.hlsUrl }));
  const logo = logoT ? atvFill(logoT.url, 1000, Math.round(1000 * logoT.height / logoT.width), 'png') : null;
  return { trailers, logo, image43T: imgs.contentImage || null, imageTallT: imgs.contentImageTall || null };
}

async function atvGetExtras(id, type) {
  const json = await utsGet(`/${type === 'Movie' ? 'movies' : 'shows'}/${id}`);
  return atvParseExtras(json);
}

// 用 umc id 直查（商店片专用：搜索层排序在前的是 TV+，by-id 数据完整）
async function atvHeroById(id, type, o) {
  const json = await utsGet(`/${type === 'Movie' ? 'movies' : 'shows'}/${id}`);
  const c = json?.data?.content;
  const img = c?.images?.posterArt || c?.images?.coverArt16X9;   // 详情页的 16:9 hero 是 posterArt
  if (!c || !img?.url) return null;
  const h = Math.round(o.w * img.height / img.width);
  const { trailers, logo, image43T } = atvParseExtras(json);
  const hero = {
    source: 'appletv',
    title: c.title, type, id,
    year: c.releaseDate ? new Date(c.releaseDate).getUTCFullYear() : null,
    image: atvFill(img.url, o.w, h, o.f),
    image43: image43T ? atvFill(image43T.url, o.w, Math.round(o.w * 0.75), o.f) : null,   // 4:3 内容图
    background: null,                       // 详情接口不提供无字 16:9 背景，叠层用 image + logo
    logo,
    template: img.url,
    link: `https://tv.apple.com/us/${type === 'Movie' ? 'movie' : 'show'}/${id}`,
  };
  if (o.video) { hero.trailers = trailers; hero.video = trailers[0]?.hls || null; hero.videoType = 'hls'; }
  return hero;
}

async function atvSearchHero(term, o) {
  const json = await utsGet('/search', { searchTerm: term });
  const cands = [];
  for (const shelf of json?.data?.canvas?.shelves || [])
    for (const it of shelf.items || [])
      if ((it.type === 'Show' || it.type === 'Movie') && it.images?.shelfImage?.url) cands.push(it);
  if (!cands.length) return null;

  // 全目录下同名片变多：优先精确同名，其次取排序第一条
  const tl = term.toLowerCase();
  const it = cands.find(c => (c.title || '').toLowerCase() === tl) || cands[0];

  const img = it.images.shelfImage;                    // 16:9 带标题排版的成品 hero 图
  const h = Math.round(o.w * img.height / img.width);
  const hero = {
    source: 'appletv',
    title: it.title, type: it.type, id: it.id,
    year: it.releaseDate ? new Date(it.releaseDate).getUTCFullYear() : null,
    image: atvFill(img.url, o.w, h, o.f),
    background: atvFill(it.images.shelfImageBackground?.url, o.w, h, o.f),   // 无字幕干净背景
    template: img.url,                                                       // {w}x{h}sr.{f} 自行替换
    link: `https://tv.apple.com/us/${it.type === 'Movie' ? 'movie' : 'show'}/${it.id}`,
  };
  if (o.video) {
    const ex = await atvGetExtras(it.id, it.type);
    hero.logo = ex.logo;
    hero.image43 = ex.image43T ? atvFill(ex.image43T.url, o.w, Math.round(o.w * 0.75), o.f) : null;
    hero.trailers = ex.trailers;
    hero.video = ex.trailers[0]?.hls || null;
    hero.videoType = 'hls';
  }
  return hero;
}

async function handleAtvSearch(url, env, ctx) {
  const q = (url.searchParams.get('q') || '').trim();
  if (!q) return jsonResponse({ error: '需要 ?q= 参数' }, 400);
  const t = timer();
  const limit = atvClamp(parseInt(url.searchParams.get('limit')) || 8, 1, 24);
  const o = atvOpts(url);

  const cache = globalThis.caches?.default;
  const ck = new Request(`${ATV_CACHE}/search?q=${encodeURIComponent(q.toLowerCase())}&limit=${limit}&w=${o.w}&f=${o.f}`);
  const hit = cache && await cache.match(ck);
  if (hit) {
    t.mark('edge-hit');
    const h = new Headers(hit.headers); h.set('Server-Timing', t.header());
    return new Response(hit.body, { headers: h });
  }

  const json = await utsGet('/search', { searchTerm: q });
  t.mark('uts');
  const seen = new Set(), results = [];
  for (const shelf of json?.data?.canvas?.shelves || []) {
    for (const it of shelf.items || []) {
      const img = it?.images?.shelfImage;
      if ((it.type === 'Movie' || it.type === 'Show') && img?.url && !seen.has(it.id)) {
        seen.add(it.id);
        const h = Math.round(o.w * img.height / img.width);
        results.push({
          title: it.title, type: it.type, id: it.id,
          year: it.releaseDate ? new Date(it.releaseDate).getUTCFullYear() : null,
          image: atvFill(img.url, o.w, h, o.f),
          background: atvFill(it.images.shelfImageBackground?.url, o.w, h, o.f),
          link: `https://tv.apple.com/us/${it.type === 'Movie' ? 'movie' : 'show'}/${it.id}`,
        });
        if (results.length >= limit) break;
      }
    }
    if (results.length >= limit) break;
  }
  const resp = jsonResponse({ query: q, count: results.length, results }, 200,
    { 'Cache-Control': ATV_CC, 'Server-Timing': t.header() });
  if (cache) ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
}

async function handleAtvLookup(url, env, ctx) {
  const t = timer();
  const o = atvOpts(url);
  o.video = url.searchParams.get('video') !== '0';   // lookup 默认带预告

  // 三种姿势：片名 / TV app 分享链接 / umc id 直查
  let id = url.searchParams.get('id');
  let type = /^show/i.test(url.searchParams.get('type') || '') ? 'Show' : 'Movie';
  const link = url.searchParams.get('url');
  if (!id && link) {
    try {
      const u = new URL(link);
      id = u.searchParams.get('targetId');                                  // 分享链接带 targetId 最准
      if (id) type = u.searchParams.get('targetType') === 'Show' ? 'Show' : 'Movie';
      else {
        id = (u.pathname.match(/umc\.cmc\.[a-z0-9]+/i) || [])[0];           // 否则从路径抠 umc id
        type = /\/(show|series|episode|season)\//.test(u.pathname) ? 'Show' : 'Movie';
      }
    } catch (_) {}
  }
  id = id || url.searchParams.get('targetId');       // 容错：未编码链接的散落参数
  const tt = url.searchParams.get('targetType');
  if (tt) type = /^show/i.test(tt) ? 'Show' : 'Movie';
  if (id) id = (String(id).match(/umc\.cmc\.[a-z0-9]+/i) || [null])[0];
  const title = (url.searchParams.get('title') || '').trim();
  if (!id && !title) return jsonResponse({ error: '需要 ?title= 或 ?url= / ?id= 参数' }, 400);

  const cache = globalThis.caches?.default;
  const ck = new Request(`${ATV_CACHE}/lookup?${id ? 'id=' + id + '&type=' + type : 'title=' + encodeURIComponent(title.toLowerCase())}&w=${o.w}&f=${o.f}&v=${o.video ? 1 : 0}`);
  const hit = cache && await cache.match(ck);
  if (hit) {
    t.mark('edge-hit');
    const h = new Headers(hit.headers); h.set('Server-Timing', t.header());
    return new Response(hit.body, { status: hit.status, headers: h });
  }

  const hero = id ? await atvHeroById(id, type, o) : await atvSearchHero(title, o);
  t.mark('uts');
  const resp = hero
    ? jsonResponse(hero, 200, { 'Cache-Control': ATV_CC, 'Server-Timing': t.header() })
    : jsonResponse({
        error: (id ? 'id ' + id : '"' + title + '"') + ' 未找到',
        hint: id ? undefined : '商店片可改用 ?url=<TV app 分享链接> 或 ?id=umc.cmc.xxx 直查',
      }, 404, { 'Cache-Control': 'public, max-age=600', 'Server-Timing': t.header() });   // 未命中短缓存，扛住批量扫库
  if (cache) ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
}

// ── hero 数据源:资料库 → Apple TV 商店(hero 唯一源管线)──────────────
//    管线:库中影片(片名年份新→旧)→ 商店英文片名搜索匹配 → 详情页一次取齐
//    双海报(横 posterArt / 竖 contentImageTall,均为无字干净画面)+ contentLogo。
//    条目自带库内 path / name,前端零匹配直接可播 —— hero 不再依赖 TMDB 种子。
//    匹配安全网:片名折叠(容错撇号 / 逗号 / 弯引号 / 感叹号)+ 年份 ±1 消歧,
//    同名不同片(重制版)宁缺毋错配。成品 R2 全局真源 + edge 双层,
//    库候选集变化或超龄(6h)由 cron 重建。
const ATV_HERO_VER = 6;                        // 升版一处改:R2 成品键 + edge 缓存键同步换代,双层缓存一并失效
const R2_ATV_HERO_KEY = `atv-hero-v${ATV_HERO_VER}.json`;   // { heroes(模板态), candHash, _ts }
const ATV_HERO_POOL = 24;                      // wire 上限
const ATV_HERO_CAND = 32;                      // 库内候选数(留余量吃掉商店未收录 / 年份不合)
const ATV_HERO_R2_TTL = 6 * 3600_000;          // 与 now-playing 同节奏

// 片名折叠:小写 +「&」→ and + 去全部非字母数字
// ("Its the Easter Beagle Charlie Brown" ≍ "It's the Easter Beagle, Charlie Brown!")
const atvNorm = s => (s || '').toLowerCase().replace(/&/g, 'and').replace(/[^a-z0-9]+/g, '');

// 候选:库内影片按「文件名年份 desc → 修改时间 desc」排序,片名去重取前 N
function atvHeroCandidates(videos, limit = ATV_HERO_CAND) {
  const seen = new Set(), out = [];
  const all = (videos || [])
    .map(v => {
      const { title, year } = parseFilename(v.name);
      return { v, title, year: parseInt(year, 10) || 0, mts: Date.parse(v.added || v.modified || '') || 0 };
    })
    .filter(c => c.title)
    .sort((a, b) => (b.year - a.year) || (b.mts - a.mts));
  for (const c of all) {
    const k = atvNorm(c.title);
    if (!k || seen.has(k)) continue;
    seen.add(k); out.push(c);
    if (out.length >= limit) break;
  }
  return out;
}

// 单部匹配:搜索 → 折叠片名全等;文件名带年份时要求商店年份 ±1(防同名重制版错配),
// 匹配成功再打详情页,一次带齐双海报 + logo(模板态入池)
async function atvHeroMatchOne(cand) {
  const sj = await utsGet('/search', { searchTerm: cand.title });
  const key = atvNorm(cand.title);
  const hits = [];
  for (const shelf of sj?.data?.canvas?.shelves || [])
    for (const it of shelf.items || [])
      if (it.type === 'Movie' && atvNorm(it.title) === key) hits.push(it);
  if (!hits.length) return null;
  let it;
  if (cand.year) {
    it = hits.find(h => h.releaseDate && Math.abs(new Date(h.releaseDate).getUTCFullYear() - cand.year) <= 1);
    if (!it) return null;                       // 年份对不上:大概率同名不同片,放弃
  } else it = hits[0];

  const dj = await utsGet(`/movies/${it.id}`);
  const imgs = dj?.data?.content?.images || {};
  const land = imgs.posterArt || it.images?.shelfImageBackground || it.images?.shelfImage || null;   // 横版:详情页优先,搜索层兜底
  const tall = imgs.contentImageTall || null;                                                        // 竖版:仅详情页有
  const logoT = imgs.contentLogo;
  if (!land && !tall) return null;
  return {
    source: 'appletv',
    id: it.id,
    path: cand.v.path, name: cand.v.name,       // 库内映射:hero 条目即库文件,前端免匹配
    title: it.title, type: 'Movie',
    year: it.releaseDate ? new Date(it.releaseDate).getUTCFullYear() : (cand.year || null),
    aspect: land ? land.height / land.width : 9 / 16,
    backgroundT: land?.url || null,
    posterT: tall?.url || null,
    posterAspect: tall ? tall.width / tall.height : null,
    logo: logoT ? atvFill(logoT.url, 1000, Math.round(1000 * logoT.height / logoT.width), 'png') : null,
    link: `https://tv.apple.com/us/movie/${it.id}`,
  };
}

// v16 增量构建：新增 1 部片 ≠ 重跑 32 次商店搜索。
//   · 复用：prev.heroes 里已解析过的同 path 条目直接搬过来（模板态本就与请求无关）
//   · 负缓存：商店没收录的片（成人片/小语种/冷门纪录片）记进 misses，24h 内不再重试
//     —— 否则每次候选集一动，那些「永远搜不到」的片都要再白搜一遍，
//     它们恰恰是最慢的一类（要走完整搜索才确认无果）
// 传 prev = null 表示「全量刷新」（超龄重建 / 手动 refresh），顺便更新商店素材。
const ATV_MISS_TTL = 24 * 3600_000;

async function buildAtvHeroPool(env, videos, prev = null) {
  const cands = atvHeroCandidates(videos);
  const reuse = new Map((prev?.heroes || []).map(e => [e.path, e]));
  const misses = { ...(prev?.misses || {}) };
  const now = Date.now();
  for (const k in misses) if (now - misses[k] > ATV_MISS_TTL) delete misses[k];

  const slots = new Array(cands.length).fill(null);            // 槽位并发:保持「新→旧」候选顺序
  const jobs = [];
  cands.forEach((c, i) => {
    const hit = reuse.get(c.v.path);
    if (hit) { slots[i] = hit; return; }                       // 已解析 → 零请求
    if (misses[c.v.path]) return;                              // 已知搜不到 → 零请求
    jobs.push(async () => {
      const r = await atvHeroMatchOne(c).catch(() => null);
      if (r) slots[i] = r; else misses[c.v.path] = now;
    });
  });
  if (jobs.length) await parallel(jobs, 4);

  // 只保留仍在候选集里的 miss 记录，防止表随片库无限增长
  const live = new Set(cands.map(c => c.v.path));
  for (const k in misses) if (!live.has(k)) delete misses[k];

  return { heroes: slots.filter(Boolean).slice(0, ATV_HERO_POOL), misses };
}

const atvHeroHash = videos => fnv1a(atvHeroCandidates(videos).map(c => c.v.path).join('\n'));

// 模板态 → 线上格式(按请求 w / f 现场展开)
// 双轨:横版 background(w)与竖版 poster(pw)并行下发,设备分轨在前端完成
// (≤734px 用 poster,iPad / 桌面用 background)—— 一份缓存服务两类设备
function atvHeroWire(pool, n, o) {
  return pool.slice(0, n).map(e => {
    const h = Math.round(o.w * (e.aspect || 9 / 16));
    return {
      source: e.source, path: e.path, name: e.name,
      title: e.title, type: e.type, year: e.year,
      background: atvFill(e.backgroundT, o.w, h, o.f),
      poster: e.posterT ? atvFill(e.posterT, o.pw, Math.round(o.pw / (e.posterAspect || 0.462)), o.f) : null,
      logo: e.logo, link: e.link,
    };
  });
}

async function handleAtvHero(url, env, ctx) {
  const t = timer();
  const n = atvClamp(parseInt(url.searchParams.get('n')) || 24, 3, ATV_HERO_POOL);
  const o = atvOpts(url);

  // 1. 本 PoP edge
  // 吃 h 分量（= hero 成品 candHash）；ATV_HERO_VER 回归「改代码才升版」
  const { h } = await ptrGet(env);
  const cache = globalThis.caches?.default;
  const ck = new Request(`${ATV_CACHE}/hero?v=${ATV_HERO_VER}&h=${h}&n=${n}&w=${o.w}&pw=${o.pw}&f=${o.f}`);
  const hit = cache && await cache.match(ck);
  if (hit) {
    t.mark('edge-hit');
    const h = new Headers(hit.headers); h.set('Server-Timing', t.header());
    return new Response(hit.body, { headers: h });
  }

  // 2. R2 成品(全局真源):超龄先回旧数据 + 后台 kickWarm,永不让用户等重建
  //    (候选集变化的重建由 cron warmCaches 负责,10 分钟内跟上库变动)
  const art = await r2GetJson(env, R2_ATV_HERO_KEY);
  if (art?.heroes?.length) {
    t.mark('r2');
    if (Date.now() - (art._ts || 0) > ATV_HERO_R2_TTL) kickWarm(env, ctx);
    const heroes = atvHeroWire(art.heroes, n, o);
    const resp = jsonResponse({ count: heroes.length, heroes, ts: new Date(art._ts || Date.now()).toISOString() }, 200,
      { 'Cache-Control': ATV_CC, 'Server-Timing': t.header() });
    if (cache) ctx?.waitUntil?.(cache.put(ck, resp.clone()));
    return resp;
  }

  // 3. 冷启动:读库列表(过期兜底可用,只做匹配不做播放)→ singleFlight 构建 → 落 R2
  const lib = await r2Get(env, { allowExpired: true });
  const built = await singleFlight('atv-hero-build', () => buildAtvHeroPool(env, lib?.videos || []));
  const pool = built.heroes;
  t.mark('uts');
  if (pool.length) ctx?.waitUntil?.(r2PutJson(env, R2_ATV_HERO_KEY, { heroes: pool, misses: built.misses, candHash: atvHeroHash(lib?.videos || []), _ts: Date.now() }));

  const heroes = atvHeroWire(pool, n, o);
  const resp = jsonResponse({ count: heroes.length, heroes }, 200,
    { 'Cache-Control': ATV_CC, 'Server-Timing': t.header() });
  if (heroes.length && cache) ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
}

const NP_CACHE = 'https://cache.internal/now-playing-v1';
const R2_NP_KEY = 'now-playing-v1.json'; // { results, _ts } —— 16 部 enriched 有序成品
const NP_MAX = 16;                        // 12（n 上限）+ 4 个「优先带 Logo」替补
const NP_R2_TTL = 6 * 3600_000;
const NP_GENRES_ZH = {
  28: '动作', 12: '冒险', 16: '动画', 35: '喜剧', 80: '犯罪', 99: '纪录',
  18: '剧情', 10751: '家庭', 14: '奇幻', 36: '历史', 27: '恐怖', 10402: '音乐',
  9648: '悬疑', 10749: '爱情', 878: '科幻', 10770: '电视电影', 53: '惊悚',
  10752: '战争', 37: '西部',
};

/* 电影与剧集两套类型编号合在一起：搜索结果里只有编号（genre_ids），对照表一查就是中文类型名，
   不必为了「剧情 · 犯罪」这几个字再去取一次详情 */
const TMDB_GENRES_ZH = {
  ...NP_GENRES_ZH,
  10759: '动作冒险', 10762: '儿童', 10763: '新闻', 10764: '真人秀', 10765: '科幻奇幻', 10766: '肥皂剧', 10767: '脱口秀', 10768: '战争政治',
};
/** 一条 TMDB 结果的类型：详情里是 genres（对象，带中文名），搜索结果里是 genre_ids（编号） */
const tmdbGenres = r => (!r ? [] : (Array.isArray(r.genres) && r.genres.length
  ? r.genres.map(g => g && g.name).filter(Boolean)
  : (r.genre_ids || []).map(id => TMDB_GENRES_ZH[id]).filter(Boolean))).slice(0, 3);

function pickLogo(logos) {
  if (!Array.isArray(logos) || !logos.length) return null;
  const pick = f => logos.find(f);
  return (
    pick(l => l.iso_639_1 === 'zh' && l.file_path?.endsWith('.png')) ||
    pick(l => l.iso_639_1 === 'en' && l.file_path?.endsWith('.png')) ||
    pick(l => l.file_path?.endsWith('.png')) ||
    pick(() => true) || null
  );
}

async function tmdbNowPlayingPage(env, region) {
  const p = new URLSearchParams({ api_key: env.TMDB_API_KEY, language: 'zh-CN', page: '1' });
  if (region) p.set('region', region);
  const res = await fetchRetry(
    `https://api.themoviedb.org/3/movie/now_playing?${p}`,
    {},
    { retries: 1, timeout: 6000 },
  );
  if (!res.ok) return [];
  const data = await res.json().catch(() => null);
  return data?.results || [];
}

async function buildNowPlaying(env) {
  // 双区并发（allSettled：任一区失败不拖垮整体）
  const [cnR, glR] = await Promise.allSettled([
    tmdbNowPlayingPage(env, 'CN'),
    tmdbNowPlayingPage(env, null),
  ]);
  const cn = cnR.status === 'fulfilled' ? cnR.value : [];
  const gl = glR.status === 'fulfilled' ? glR.value : [];

  // 合并去重：CN 在前，保持各自榜单顺序
  const seen = new Set();
  const merged = [];
  for (const m of [...cn, ...gl]) {
    if (!m || !m.id || seen.has(m.id)) continue;
    if (!m.poster_path) continue;           // 无海报不参与「海报+Logo」组合
    seen.add(m.id);
    merged.push(m);
  }
  if (!merged.length) return [];

  // 固定 NP_MAX 个候选：一份成品切片服务所有 n
  const candidates = merged.slice(0, Math.min(merged.length, NP_MAX));

  // 并发取 Logo（每部 1 次 images 调用，限流 6）
  const enriched = new Array(candidates.length);
  await parallel(
    candidates.map((m, i) => async () => {
      let logo = null, logoAspect = null;
      try {
        const res = await fetchRetry(
          `https://api.themoviedb.org/3/movie/${m.id}/images?api_key=${env.TMDB_API_KEY}&include_image_language=zh,en,null`,
          {},
          { retries: 0, timeout: 5000 },
        );
        if (res.ok) {
          const img = await res.json();
          const best = pickLogo(img.logos);
          if (best) {
            logo = `https://image.tmdb.org/t/p/w500${best.file_path}`;
            logoAspect = best.aspect_ratio || null;
          }
        }
      } catch {}
      enriched[i] = {
        id: m.id,
        title: m.title || m.original_title || '',
        originalTitle: m.original_title || '',
        release_date: m.release_date || null,
        year: (m.release_date || '').slice(0, 4),
        poster: `https://image.tmdb.org/t/p/w780${m.poster_path}`,
        backdrop: m.backdrop_path ? `https://image.tmdb.org/t/p/w1280${m.backdrop_path}` : null,
        logo, logoAspect,
        overview: m.overview || '',
        rating: m.vote_average || 0,
        genres: (m.genre_ids || []).map(id => NP_GENRES_ZH[id]).filter(Boolean).slice(0, 3),
      };
    }),
    6,
  );

  // 带 Logo 优先、原榜单顺序稳定 —— 返回满额有序列表，由调用方按 n 切片
  const withLogo = enriched.filter(m => m && m.logo);
  const noLogo   = enriched.filter(m => m && !m.logo);
  return [...withLogo, ...noLogo];
}

async function handleNowPlaying(url, env, ctx) {
  if (!env.TMDB_API_KEY) return jsonResponse({ error: 'TMDB_API_KEY not set' }, 503);
  const t = timer();
  const n = Math.min(Math.max(parseInt(url.searchParams.get('n') || '8', 10) || 8, 2), 12);

  // 1. 本 PoP edge
  const cache = caches.default;
  const ck = new Request(`${NP_CACHE}?n=${n}`);
  const cached = await cache.match(ck);
  if (cached) {
    t.mark('edge-hit');
    const h = new Headers(cached.headers);
    h.set('Server-Timing', t.header());
    return new Response(cached.body, { headers: h });
  }

  // 2. R2 成品（全局真源）：Logo 优先的有序列表，直接切片
  const art = await r2GetJson(env, R2_NP_KEY);
  if (art?.results?.length) {
    t.mark('r2');
    if (Date.now() - (art._ts || 0) > NP_R2_TTL) kickWarm(env, ctx);
    const results = art.results.slice(0, n);
    const resp = new Response(
      JSON.stringify({ count: results.length, results, ts: new Date(art._ts || Date.now()).toISOString() }),
      {
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': 'public, max-age=1800, s-maxage=21600, stale-while-revalidate=86400',
          'Server-Timing': t.header(),
        },
      },
    );
    ctx?.waitUntil?.(cache.put(ck, resp.clone()));
    return resp;
  }

  // 3. 无成品 → 直接构建（singleFlight 合并并发冷请求），并顺手落 R2 成品
  const full = await singleFlight('np-build', () => buildNowPlaying(env));
  t.mark('tmdb');
  if (full.length) ctx?.waitUntil?.(r2PutJson(env, R2_NP_KEY, { results: full, _ts: Date.now() }));

  const results = full.slice(0, n);
  const body = JSON.stringify({ count: results.length, results, ts: new Date().toISOString() });
  const resp = new Response(body, {
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=1800, s-maxage=21600, stale-while-revalidate=86400',
      'Server-Timing': t.header(),
    },
  });
  if (results.length) ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /api/coming-soon/remind — 「加入时邮件提醒我」上报
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  秒回 202，落盘走 waitUntil。每条订阅写独立 R2 对象 ——
//  此前是 get → push → put 整表重写，两个并发 POST 会互相覆盖丢单。
//  独立对象天然无共享状态；key = 定宽 base36 毫秒时间戳 + 随机后缀，
//  list({ prefix }) 按 key 升序即时间序。端点在鉴权之后，写入量受控。
//  （历史聚合数据仍在旧 key remind-subs-v1.json，只读不再追加）

const REMIND_PREFIX = 'remind/v1/';

async function handleRemind(request, env, ctx) {
  if (request.method !== 'POST') return jsonResponse({ error: 'POST required' }, 405);
  let b;
  try { b = await request.json(); }
  catch { return jsonResponse({ error: 'Invalid JSON' }, 400); }

  const id = String(b?.id || '').slice(0, 80);
  if (!id) return jsonResponse({ error: 'Missing id' }, 400);
  const entry = {
    id,
    title:  String(b?.title  || '').slice(0, 200),
    email:  String(b?.email  || '').slice(0, 200),
    action: b?.action === 'unsubscribe' ? 'unsubscribe' : 'subscribe',
    ts: new Date().toISOString(),
  };

  if (env.FILE_CACHE) {
    // padStart(9)：base36 毫秒时间戳定宽到公元 5000+，保证字典序 = 时间序
    const key = `${REMIND_PREFIX}${Date.now().toString(36).padStart(9, '0')}-${crypto.randomUUID().slice(0, 8)}.json`;
    ctx?.waitUntil?.(
      env.FILE_CACHE.put(key, JSON.stringify(entry), {
        httpMetadata: { contentType: 'application/json' },
      }).catch(() => {})
    );
  }

  return jsonResponse({ ok: true, action: entry.action }, 202);
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  iTunes / Apple TV（并行双区，取先到的有效结果）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function fetchITunesArtwork(title, year, mediaType, names) {
  if (!title) return null;
  try {
    // 并发 cn + us，Promise.any 取首个成功
    const result = await Promise.any([
      _itunesSearch(title, year, mediaType, 'cn', names),
      _itunesSearch(title, year, mediaType, 'us', names),
    ]);
    return result;
  } catch { return null; }
}

/* 只认片名对得上（中文区对中文名、美区对英文名 / 原名，相似度 ≥ 0.8）、年份差不过一年的那条。
   原来拿第一条：同名的另一部、续集、纪录片都可能顶上来，详情页的海报就换成了别的片子 */
async function _itunesSearch(title, year, mediaType, country, names) {
  const entity = mediaType === 'tv' ? 'tvShow' : 'movie';
  const params = new URLSearchParams({ term: title, entity, country, limit: '5' });
  const res = await fetchRetry(
    `https://itunes.apple.com/search?${params}`,
    { headers: { 'User-Agent': 'Mozilla/5.0' } },
    { retries: 0, timeout: 4000 }, // 快速失败，不拖慢整体
  );
  if (!res.ok) throw new Error('iTunes fail');
  const data = await res.json();
  const results = data.results || [];
  if (!results.length) throw new Error('no results');

  const want = (names && names.length ? names : [title]).filter(Boolean);
  const y = parseInt(year, 10) || 0;
  const fits = r => {
    const n = r.trackName || r.collectionName || (mediaType === 'tv' ? r.artistName : '') || '';
    if (!want.some(w => mtSim(n, w) >= 0.8)) return false;
    const ry = parseInt(String(r.releaseDate || '').slice(0, 4), 10) || 0;
    return !y || !ry || Math.abs(ry - y) <= 1;
  };
  const best = results.find(fits);
  if (!best) throw new Error('no matching artwork');

  const raw = best.artworkUrl100;
  if (!raw) throw new Error('no artwork');

  const make = (size) => raw.replace(/\/[^/]*\d+x\d+[^/]*\.\w+$/, `/${size}.jpg`);
  return {
    poster: make('600x900bb'),
    backdrop: make('1920x1080bb'),
    source: 'itunes',
    trackName: best.trackName || best.collectionName || '',
    contentId: best.trackId || best.collectionId || null,
  };
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  TMDB + iTunes 融合元数据
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// v8：匹配管线重写（候选打分 + 校验）。旧缓存里的错配不换命名空间的话要再压 7 天
const TMDB_CACHE = 'https://cache.internal/tmdb-v9/';   // v9：简要结果也带类型（genres）

/** q：一句片名，或 mtParse 的结果（中英文名都进键 —— 只拿其中一个当键，两部片会互相顶掉），或 { id, type } */
function tmdbCacheKey(q, year, full, kind) {
  const obj = q && typeof q === 'object';
  const t = obj ? (q.id ? `#${q.type}:${q.id}` : [q.en, q.zh, q.alt].filter(Boolean).join('|')) : String(q || '');
  const y = obj ? (q.year || '') : (year || '');
  const p = new URLSearchParams({ q: t.toLowerCase() });
  if (y) p.set('y', y);
  if (full) p.set('f', '2');        // f=2：全量结果多了 logoChecked（见 fetchMetadata），旧的 f=1 那批不再读
  if (kind) p.set('t', kind);       // type=tv / movie 各存一份：同名的电影与剧集不能互相顶掉
  return new Request(`${TMDB_CACHE}?${p}`);
}

async function handleTmdb(url, env, ctx) {
  if (!env.TMDB_API_KEY) return jsonResponse({ error: 'TMDB_API_KEY not set' }, 503);
  const query = url.searchParams.get('query') || '';
  const year = url.searchParams.get('year') || '';
  const full = url.searchParams.get('logo') === '1';
  // type=tv 只搜剧集、type=movie 只搜电影；不带就是老规矩（电影优先，搜不到再搜剧集）
  const kind = ['tv', 'movie'].includes(url.searchParams.get('type')) ? url.searchParams.get('type') : '';
  // id：剧集表已经认好的编号 —— 剧照、详情、分集用同一部，不再按名字各认各的
  const id = parseInt(url.searchParams.get('id') || '', 10) || 0;
  if (!query && !(id && kind)) return jsonResponse({ error: 'Missing query' }, 400);

  const q = id && kind ? { id, type: kind } : mtQuery(query, year);
  const ck = tmdbCacheKey(q, year, full, kind);
  const cache = caches.default;
  const hit = await cache.match(ck);
  if (hit) return new Response(hit.body, { headers: hit.headers });

  let payload;
  try { payload = await fetchMetadata(q, year, full, env, kind); }
  catch (e) { return jsonResponse({ error: 'tmdb unavailable' }, 502, { 'Cache-Control': 'no-store' }); }   // 出错不缓存、不回 null
  const body = payload ? JSON.stringify(payload) : 'null';
  const keep = tmdbCacheable(payload, full);
  const resp = new Response(body, {
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': keep ? 'public, max-age=86400, s-maxage=604800, stale-while-revalidate=2592000' : 'public, max-age=120',
    },
  });
  if (keep) ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
}

/* 全量结果里字标那一问没问成（TMDB images 超时 / 出错）：这份只能算半份 —— 照常回给前端，但不进边缘缓存，
   浏览器也只留两分钟；否则「暂时没取到字标」会被当成「没有字标」记上一个星期 */
function tmdbCacheable(payload, full) {
  return !(full && payload && payload.logoChecked === false);
}

async function handleTmdbBatch(request, env, ctx) {
  if (!env.TMDB_API_KEY) return jsonResponse({ error: 'TMDB_API_KEY not set' }, 503);
  if (request.method !== 'POST') return jsonResponse({ error: 'POST required' }, 405);

  let body;
  try { body = await request.json(); }
  catch { return jsonResponse({ error: 'Invalid JSON' }, 400); }

  const queries = Array.isArray(body?.queries) ? body.queries.slice(0, 80) : [];
  if (!queries.length) return jsonResponse({});

  const cache = caches.default;
  const result = {};
  // 一次批量最多发这么多个 TMDB 请求（每部片 2–10 个不等）：超了的那几部这次不答，前端过会儿再问
  const budget = { left: 700 };

  await parallel(
    queries.filter(q => q?.name).map(q => async () => {
      const p = parseFilename(q.name);
      if (!p.title || p.extra) { result[q.name] = null; return; }   // 认不出片名 / 样片、预告、花絮：明确没有
      const full = !!q.logo;
      const ck = tmdbCacheKey(p, '', full);

      const hit = await cache.match(ck);
      if (hit) {
        try { result[q.name] = JSON.parse(await hit.text()); } catch { result[q.name] = null; }
        return;
      }

      // 认不上 → null（写缓存）；TMDB 出错 / 超预算 → 这个键不回（不写缓存）。
      // 前端靠这一点分清「TMDB 说没有这部」与「这次没问成」：前者不显示，后者过会儿再问
      let data = null;
      let failed = false;
      try { data = await fetchMetadata(p, '', full, env, '', budget); }
      catch { failed = true; }
      if (failed) return;
      result[q.name] = data;
      if (!tmdbCacheable(data, full)) return;
      const resp = new Response(data ? JSON.stringify(data) : 'null', {
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': 'public, max-age=86400, s-maxage=604800, stale-while-revalidate=2592000',
        },
      });
      ctx?.waitUntil?.(cache.put(ck, resp));
    }),
    6,
  );

  // 版本记号：前端据此知道这里的 null 是确定的「认不出」（旧版出错时也回 null，不能拿来藏片）
  result.__match = 2;
  return jsonResponse(result);
}

/* ══════════════════════════════════════════════════════════════════════
   IMDb 预告片 —— GET /api/imdb/video
   ──────────────────────────────────────────────────────────────────────
   资料库「展映」那一屏的片源。IMDb 的公开 GraphQL 端点一次就能给全：
   预告片的多档 MP4 + HLS、缩略图、剧情梗概、以及一批高清剧照。

   三件必须知道的事 ——
   ① 播放地址是 CloudFront 签名 URL，Expires 恰好 24 小时。所以这里的
      边缘缓存寿命必须显著短于它（IMDB_TTL = 6h），否则缓存还新鲜、
      地址已经过期，前端拿到的是一片黑。响应里回 expires 字段，
      客户端可以自己判断要不要重取。
   ② 那批 MP4 回的是 access-control-allow-origin: *，并且支持 Range。
      → 浏览器直连即可，不必让 Worker 代理视频流（省带宽、省 CPU）。
   ③ id 走 TMDB 带回来的 imdb 字段；没有就用 query+year 让 TMDB 现查一次
      ——「前端还没升级到带 imdb 的 payload」这条路必须留着。

   失败一律降级成 { video: null }，前端退回静态剧照 hero，不显示错误。
   ══════════════════════════════════════════════════════════════════════ */

const IMDB_GQL   = 'https://api.graphql.imdb.com/';
const IMDB_CACHE = 'https://cache.internal/imdb-v2/';   // v2：回包多了 yt（TMDB 登记的 YouTube 官方预告）
const IMDB_TTL   = 21600;        // 6h —— 必须 < 签名的 24h
const IMDB_MISS_TTL = 3600;      // 查无此片：缓存 1h，别每次都去打 IMDb
const YT_TTL     = 259200;       // 只有 YouTube 预告：3 天（key 不会过期，留着也好让 IMDb 恢复后能换回直链）
const IMDB_WAIT_MS = 4000;       // IMDb 最多等这么久，过了就用 YouTube 那条
/* IMDb 现在多半不接 Cloudflare Worker 的请求（403 / 超时）。失败一次就先歇 30 分钟：
   不然每个没缓存的预告片请求都要先白等一轮，前端 9 秒的超时都不够 */
let imdbDownUntil = 0;
const imdbUp = () => Date.now() >= imdbDownUntil;

const IMDB_QUERY = `query V($id: ID!, $n: Int!) {
  title(id: $id) {
    id
    titleText { text }
    releaseYear { year }
    plot { plotText { plainText } }
    primaryVideos(first: 6) {
      edges { node {
        id
        name { value }
        runtime { value }
        contentType { displayName { value } }
        thumbnail { url width height }
        playbackURLs { displayName { value } videoMimeType url }
      } }
    }
    images(first: $n) { edges { node { url width height caption { plainText } } } }
  }
}`;

/* m.media-amazon.com 的图片支持在文件名里内联变换：._V1_QL80_UX1600_.jpg
   原图动辄 8000px 宽，直连等于让手机下 10MB 一张的剧照 */
function amzImg(u, w) {
  if (typeof u !== 'string' || !u) return null;
  return u.replace(/\._V1_.*?(\.\w+)$/i, `._V1_QL80_UX${w}_$1`);
}

function imdbExpiry(u) {
  try { return Number(new URL(u).searchParams.get('Expires')) || null; } catch { return null; }
}

/* 挑预告片：正片预告优先，其次花絮 / 片段，最后随便哪一条 */
function pickImdbVideo(nodes) {
  const kind = n => (n?.contentType?.displayName?.value || '').toLowerCase();
  const hasMp4 = n => (n?.playbackURLs || []).some(p => p.videoMimeType === 'MP4');
  return nodes.find(n => kind(n).includes('trailer') && hasMp4(n))
      || nodes.find(n => kind(n).includes('clip') && hasMp4(n))
      || nodes.find(hasMp4)
      || null;
}

async function imdbGraphQL(id, stills) {
  const res = await fetchRetry(IMDB_GQL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      /* IMDb 对裸请求偶发挑剔；给一副正常浏览器的面孔，成功率稳一截 */
      'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15',
      'Origin': 'https://www.imdb.com',
      'Referer': 'https://www.imdb.com/',
    },
    body: JSON.stringify({ query: IMDB_QUERY, variables: { id, n: stills } }),
  }, { retries: 0, timeout: IMDB_WAIT_MS }).catch(e => { imdbDownUntil = Date.now() + 30 * 60e3; throw e; });
  if (!res?.ok) {
    if (res && (res.status === 403 || res.status === 429 || res.status >= 500)) imdbDownUntil = Date.now() + 30 * 60e3;
    throw new Error('imdb ' + (res?.status || 'fail'));
  }
  const j = await res.json();
  return j?.data?.title || null;
}

/* ── TMDB 登记的官方预告（YouTube）──────────────────────────────────────
   IMDb 拿不到直链时的退路，覆盖面也更广：几乎每部院线片都有片方上传的官方预告。
   前端用 YouTube 的嵌入播放器放（不经过我们的 HLS，也不经过 Worker）。
   挑法：正式预告 > 先导 > 片段；官方的优先；中文的略优先（片方中文预告常带中文字幕）；
   同等条件下清晰度高、发布晚的那条（「终极预告」通常最后发）。 */
function pickYouTube(list) {
  const ok = (list || []).filter(v => v && v.site === 'YouTube' && /^[\w-]{11}$/.test(v.key || ''));
  const score = v => (v.type === 'Trailer' ? 100 : v.type === 'Teaser' ? 60 : v.type === 'Clip' ? 20 : 0)
    + (v.official ? 30 : 0) + (v.iso_639_1 === 'zh' ? 12 : v.iso_639_1 === 'en' ? 8 : 0)
    + (v.size >= 2160 ? 6 : v.size >= 1080 ? 5 : v.size >= 720 ? 2 : 0)
    + (Date.parse(v.published_at || '') || 0) / 1e13;
  return ok.sort((a, b) => score(b) - score(a))[0] || null;
}

async function tmdbTrailer({ imdb, tmdb, type, query, year }, env) {
  if (!env.TMDB_API_KEY) return null;
  const key = env.TMDB_API_KEY;
  const get = u => fetchRetry(u, {}, { retries: 1, timeout: 5000 }).then(r => (r.ok ? r.json() : null)).catch(() => null);
  let kind = type === 'tv' || type === 'movie' ? type : '';
  let id = tmdb > 0 ? tmdb : 0;
  if (!id && imdb) {
    const f = await get(`https://api.themoviedb.org/3/find/${imdb}?api_key=${key}&external_source=imdb_id`);
    const hit = f && ((f.movie_results || [])[0] ? ['movie', f.movie_results[0]] : (f.tv_results || [])[0] ? ['tv', f.tv_results[0]] : null);
    if (hit) { kind = hit[0]; id = hit[1].id; }
  }
  if (!id && query) {
    const m = await tmdbMatch(mtQuery(query, year), env, kind).catch(() => null);
    if (m) { kind = m.c.type; id = m.c.id; }
  }
  if (!id) return null;
  const j = await get(`https://api.themoviedb.org/3/${kind || 'movie'}/${id}/videos?api_key=${key}&language=zh-CN&include_video_language=zh,en,null`);
  const v = pickYouTube(j && j.results);
  return v ? { key: v.key, name: v.name || '预告片', kind: v.type || 'Trailer', lang: v.iso_639_1 || '', size: v.size || 0,
    official: !!v.official, at: v.published_at || null } : null;
}

/* IMDb 那条：直链 MP4（多档）+ 剧照。拿不到 → null */
async function imdbTrailer(id, nStills) {
  const t = await imdbGraphQL(id, nStills);
  if (!t) return null;
  const nodes = (t.primaryVideos?.edges || []).map(e => e.node).filter(Boolean);
  const v = pickImdbVideo(nodes);
  let video = null;
  if (v) {
    const mp4 = {};
    let hls = null;
    for (const p of (v.playbackURLs || [])) {
      const label = p?.displayName?.value || '';
      if (p.videoMimeType === 'MP4') mp4[label] = p.url;
      else if (p.videoMimeType === 'M3U8' && !hls) hls = p.url;
    }
    /* 由高到低给一条优先级链；前端按网络状况自己挑，拿不到就顺位下取 */
    const order = ['1080p', '720p', '480p', 'SD'];
    const best = order.map(k => mp4[k]).find(Boolean) || Object.values(mp4)[0] || null;
    if (best) {
      video = {
        id: v.id,
        name: v.name?.value || '预告片',
        kind: v.contentType?.displayName?.value || 'Trailer',
        runtime: v.runtime?.value || null,
        thumb: v.thumbnail?.url ? amzImg(v.thumbnail.url, 1280) : null,
        mp4, hls, best,
        expires: imdbExpiry(best),
      };
    }
  }
  const stills = (t.images?.edges || []).map(e => e.node).filter(n => n?.url).map(n => ({
    url:   amzImg(n.url, 1600),
    thumb: amzImg(n.url, 640),
    w: n.width || null,
    h: n.height || null,
    caption: n.caption?.plainText || '',
  }));
  return {
    id: t.id || id,
    title: t.titleText?.text || null,
    year: t.releaseYear?.year || null,
    plot: t.plot?.plotText?.plainText || null,
    video,
    stills,
  };
}

/* 前端还没有 imdb 字段时的兜底：TMDB 现查一次拿编号 */
async function resolveImdbId(query, year, env) {
  if (!env.TMDB_API_KEY) return null;
  try {
    const m = await tmdbMatch(mtQuery(query, year), env, '');
    if (!m) return null;
    const hit = { id: m.c.id };
    const type = m.c.type;
    const r = await fetchRetry(
      `https://api.themoviedb.org/3/${type}/${hit.id}/external_ids?api_key=${env.TMDB_API_KEY}`,
      {}, { retries: 1, timeout: 6000 },
    );
    if (!r?.ok) return null;
    const j = await r.json();
    return /^tt\d+$/.test(j?.imdb_id || '') ? j.imdb_id : null;
  } catch { return null; }
}

async function handleImdbVideo(url, env, ctx) {
  let id = (url.searchParams.get('id') || '').trim();
  const query = (url.searchParams.get('query') || '').trim();
  const year  = (url.searchParams.get('year')  || '').trim();
  const tmdb  = parseInt(url.searchParams.get('tmdb') || '', 10) || 0;
  const type  = (url.searchParams.get('type') || '').trim();
  const nStills = Math.min(24, Math.max(0, Number(url.searchParams.get('stills') ?? 10) || 0));

  if (!/^tt\d+$/.test(id)) {
    if (!query && !tmdb) return jsonResponse({ error: 'Missing id or query' }, 400);
    id = imdbUp() && query ? await resolveImdbId(query, year, env) : null;
  }

  const who = id || (tmdb ? `tmdb-${type || 'movie'}-${tmdb}` : `q-${encodeURIComponent(query.toLowerCase())}-${year}`);
  const ck = new Request(`${IMDB_CACHE}${who}?n=${nStills}`);
  const cache = caches.default;
  const hit = await cache.match(ck);
  if (hit) return new Response(hit.body, { headers: hit.headers });

  // 两路一起问：IMDb（直链 MP4，最好，但常被拒）与 TMDB（YouTube 官方预告）。IMDb 最多等 IMDB_WAIT_MS
  const imdbP = id && imdbUp() ? imdbTrailer(id, nStills).catch(() => null) : Promise.resolve(null);
  const ytP = tmdbTrailer({ imdb: id, tmdb, type, query, year }, env).catch(() => null);
  const imdb = await Promise.race([imdbP, sleep(IMDB_WAIT_MS + 500).then(() => null)]);
  const yt = imdb && imdb.video ? null : await ytP;

  const payload = {
    id: (imdb && imdb.id) || id || null,
    title: (imdb && imdb.title) || null,
    year: (imdb && imdb.year) || null,
    plot: (imdb && imdb.plot) || null,
    video: (imdb && imdb.video) || null,
    stills: (imdb && imdb.stills) || [],
    yt: yt || null,
  };
  const ttl = payload.video ? IMDB_TTL : payload.yt ? YT_TTL : (imdb ? IMDB_MISS_TTL : 300);
  const resp = new Response(JSON.stringify(payload), {
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      /* stale-while-revalidate 故意不给：过期的签名地址不能再端上来 */
      'Cache-Control': `public, max-age=${ttl}`,
    },
  });
  ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
}

// ── 核心：融合 TMDB + iTunes ──

/** 按编号取（剧集表里已经认好的那部、前端带回来的编号）：与 tmdbMatch 的返回同形 */
async function mtById(type, id, env) {
  const r = await fetchRetry(`https://api.themoviedb.org/3/${type}/${encodeURIComponent(id)}?api_key=${env.TMDB_API_KEY}&language=zh-CN`, {}, { retries: 1, timeout: 6000 });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error('tmdb ' + r.status);
  const d = await r.json();
  return { sim: 1, score: null, c: { type, id: d.id, rank: 0, zh: d.title || d.name || '', en: '', orig: d.original_title || d.original_name || '',
    lang: d.original_language || '', date: d.release_date || d.first_air_date || '', votes: d.vote_count || 0, rating: d.vote_average || 0,
    poster: d.poster_path || null, backdrop: d.backdrop_path || null, overview: d.overview || '', alt: null, raw: d } };
}

/**
 * title：mtParse 的结果（文件名里解析好的中英文名 + 年份），或一句片名（配 year）；
 *        { id, type } 直接按编号取（剧集表认好的那部 —— 剧照与分集用的是同一个编号，不会两边各认一部）
 * 认不上返回 null；TMDB 出错抛错 —— 调用方不能把一次网络抖动当成「没有这部片」缓存下来
 */
async function fetchMetadata(title, year, full, env, kind = '', budget = null) {
  const q = title && typeof title === 'object' ? title : mtQuery(title, year);
  const m = q.id && (q.type === 'tv' || q.type === 'movie') ? await mtById(q.type, q.id, env) : await tmdbMatch(q, env, kind, budget);
  if (!m) return null;
  const c = m.c, type = c.type;

  const out = {
    id: c.id,
    title: c.zh || c.en || c.orig,
    en: c.en || '',
    original_title: c.orig || '',
    year: (c.date || '').slice(0, 4),
    release_date: c.date || null,
    poster: c.poster ? `https://image.tmdb.org/t/p/w342${c.poster}` : null,
    backdrop: c.backdrop ? `https://image.tmdb.org/t/p/w1280${c.backdrop}` : null,
    overview: c.overview || '',
    rating: c.rating || 0,
    type,
    match: m.score != null ? Math.round(m.score) : null,   // 匹配分（排查错配用）
    logo: null, logoAspect: null,
    imdb: null,
    runtime: null, genres: tmdbGenres(c.raw),       // 列表里那行「剧情 · 犯罪」：搜索结果自带编号，不多花请求
    cast: [], director: null, creators: [],
    artworkSource: 'tmdb',
  };

  // iTunes 按「认好的那部」的片名与年份去搜、并逐条核对 —— 不再拿文件名里的半截片名搜、取第一条
  const itTitle = c.en || c.orig || c.zh, itNames = [c.en, c.orig, c.zh].filter(Boolean);
  if (!full) {
    // TMDB 没有海报（冷门片、刚上架的）：拿 iTunes 补一张，补不到前端就不显示这部
    if (!out.poster) {
      const it = await fetchITunesArtwork(itTitle, out.year, type, itNames);
      if (it) { out.poster = it.poster; out.artworkSource = 'itunes'; }
    }
    return out;
  }

  // ── 全量模式：并发 iTunes + TMDB images/detail/credits ──
  const key = env.TMDB_API_KEY;
  const id = c.id;

  const [itunes, imgRes, detailRes, creditsRes] = await Promise.allSettled([
    fetchITunesArtwork(itTitle, out.year, type, itNames),
    fetchRetry(`https://api.themoviedb.org/3/${type}/${id}/images?api_key=${key}&include_image_language=zh,en,null`, {}, { retries: 1, timeout: 6000 }),
    fetchRetry(`https://api.themoviedb.org/3/${type}/${id}?api_key=${key}&language=zh-CN&append_to_response=external_ids`, {}, { retries: 1, timeout: 6000 }),
    fetchRetry(`https://api.themoviedb.org/3/${type}/${id}/credits?api_key=${key}&language=zh-CN`, {}, { retries: 1, timeout: 6000 }),
  ]);

  // iTunes 优先的只有海报（片名与年份核对过）。背景只在 TMDB 没有时才用 —— iTunes 给的是竖版海报，
  // 铺到横向的详情背景上只能裁出中间一条、再放大好几倍
  if (itunes.status === 'fulfilled' && itunes.value) {
    out.poster = itunes.value.poster;
    if (!out.backdrop) out.backdrop = itunes.value.backdrop;
    out.artworkSource = 'itunes';
  }

  // TMDB Logo + Stills（剧照画廊用）
  // logoChecked：images 这一问真的问到了（logo 为空 = TMDB 上确实没有字标）。没问成时 logo 也是空，
  // 但那不算数 —— 前端首页按「有没有字标」决定剧集出不出，只认问到了的答案；没问成的这份也不进长缓存（见 tmdbCacheable）
  out.logoChecked = false;
  if (imgRes.status === 'fulfilled' && imgRes.value?.ok) {
    try {
      const imgData = await imgRes.value.json();
      out.logoChecked = true;
      const logos = imgData.logos || [];
      const pick = f => logos.find(f);
      const best =
        pick(l => l.iso_639_1 === 'zh' && l.file_path?.endsWith('.png')) ||
        pick(l => l.iso_639_1 === 'en' && l.file_path?.endsWith('.png')) ||
        pick(l => l.file_path?.endsWith('.png')) ||
        pick(() => true);
      if (best) {
        out.logo = `https://image.tmdb.org/t/p/w500${best.file_path}`;
        out.logoAspect = best.aspect_ratio || null;
      }
      // 纯净海报（画面上没有片名的那版）：前端在它上面贴官方字标，普通海报自己印着片名、不能再贴
      const clean = (imgData.posters || []).filter(x => x.file_path && (!x.iso_639_1 || x.iso_639_1 === 'xx'))
        .sort((a, b) => (b.vote_average || 0) - (a.vote_average || 0))[0];
      if (clean) out.posterClean = `https://image.tmdb.org/t/p/w780${clean.file_path}`;

      // ── Stills：从 backdrops 提取剧照（用于详情页 caption-tile 画廊） ──
      // TMDB 的 backdrop 实际就是高清剧照，无水印、横版 16:9。
      // 策略：
      //   1. 优先无文字版（iso_639_1 === null）— 干净的剧照画面
      //   2. 然后是中文版（含字幕/标语）
      //   3. 再然后是英文版
      //   4. 按 vote_average 降序保证质量
      //   5. 跳过第 0 张（已用作 hero backdrop）
      //   6. 最多 12 张
      const backdrops = imgData.backdrops || [];
      const sortByVote = (a, b) => (b.vote_average || 0) - (a.vote_average || 0);
      const noLang = backdrops.filter(b => !b.iso_639_1).sort(sortByVote);
      const zhLang = backdrops.filter(b => b.iso_639_1 === 'zh').sort(sortByVote);
      const enLang = backdrops.filter(b => b.iso_639_1 === 'en').sort(sortByVote);
      const ranked = [...noLang, ...zhLang, ...enLang];
      // 排除已用作 hero backdrop 的那张（避免重复）
      const heroBdPath = c.backdrop;
      const stillsList = ranked
        .filter(b => b.file_path && b.file_path !== heroBdPath)
        .slice(0, 12)
        .map(b => ({
          url: `https://image.tmdb.org/t/p/w1280${b.file_path}`,
          thumb: `https://image.tmdb.org/t/p/w500${b.file_path}`,
          aspect: b.aspect_ratio || (16 / 9),
          width: b.width || null,
          height: b.height || null,
        }));
      if (stillsList.length) out.stills = stillsList;
    } catch {}
  }

  // Detail
  if (detailRes.status === 'fulfilled' && detailRes.value?.ok) {
    try {
      const d = await detailRes.value.json();
      out.runtime = d.runtime || d.episode_run_time?.[0] || null;
      out.genres = (d.genres || []).map(g => g.name).slice(0, 3);
      /* IMDb 编号 —— 预告片的唯一入口键。movie 详情自带 imdb_id，tv 只在
         external_ids 里给；两处都读，谁先有算谁 */
      out.imdb = d.imdb_id || d.external_ids?.imdb_id || null;
    } catch {}
  }

  // Credits
  if (creditsRes.status === 'fulfilled' && creditsRes.value?.ok) {
    try {
      const cr = await creditsRes.value.json();
      out.cast = (cr.cast || []).slice(0, 20).map(c => ({
        id: c.id, name: c.name, character: c.character || '',
        profile_path: c.profile_path || null, order: c.order ?? 99,
      }));
      out.director = (cr.crew || []).find(p => p.job === 'Director')?.name || null;
      out.creators = (cr.crew || [])
        .filter(p => p.job === 'Creator' || p.job === 'Executive Producer')
        .slice(0, 3).map(p => p.name);
    } catch {}
  }

  return out;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  片名匹配：文件名 → TMDB
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  原来是「解析出一个片名 → 搜一次 → 拿第一条」，错配主要出在四处：
//   ① 片名里本身带年份（《银翼杀手2049》《神奇女侠1984》《1917》），取第一个年份当上映年，片名被截断；
//   ② TMDB 的第一条按热度排，同名不同年（《沙丘》1984 / 2021）、续集（《玩具总动员 3 / 4》）常排在前面；
//   ③ 电影搜不到就拿剧集顶上 —— 片名噪声一大，名字沾边的剧都能「匹配」上；
//   ④ 详情页的 iTunes 海报按片名搜、拿第一条，TMDB 认对了，海报还可能换成另一部。
//  现在：
//   · 解析出中文名、英文名、上映年（取最后一个合理的年份，片名里的年份留在片名里）、季集号、样片 / 预告；
//   · 中英两种语言各搜一次、候选合在一起，按片名相似度（中文名 / 英文名 / 原名，罗马数字、数字词、
//     全角、标点、变音符都归一）、年份、类型、热度打分；续集号对不上直接压分，年份差两年以上压到认不上；
//   · 分数不够宁可不认 —— 认错比没认更糟（前端对拿不到海报的片子直接不显示）；
//   · 拿不准、但年份对得上的前两名，再取别名表与各语言译名（罗马音、繁体、港台译名）比一次。

const MT_NATIVE = /[぀-ヿ㐀-鿿豈-﫿가-힯]/;   // 汉字 / 假名 / 谚文
const MT_YEAR = /^[(（\[]?((?:19|20)\d{2})[)）\]]?$/;
const MT_SE = /^(?:s\d{1,2}(?:e\d{1,4})?(?:-?e\d{1,4})?|e\d{1,4}|ep\d{1,4}|\d{1,2}x\d{2,3}|season|第[一二三四五六七八九十\d]+[季集话話]|全\d+集)$/i;
// 片名到此为止的规格词（强）：画质、片源、编码、音轨
const MT_SPEC = /^(?:4320p|2160p|1440p|1080[pi]|720p|576p|480p|4k|8k|uhd|fhd|hdr10\+?|hdr|dv|dovi|hlg|sdr|blu-?ray|bdrip|brrip|bdremux|remux|web-?dl|web-?rip|hdtv|dvdrip|dvd|hdrip|x26[45]|h26[45]|hevc|avc|av1|xvid|divx|aac\d?(?:\.\d)?|ac3|eac3|e-ac-3|ddp?\d?(?:\.\d)?|dd\+|dts(?:-?hd)?(?:-?ma)?|truehd|atmos|flac|lpcm|opus|10bit|8bit|hi10p|60fps|120fps)$/i;
// 版本词：只收不会是片名的那些（《The Cut》《Special》这类单词不收，免得把片名削掉一截）
const MT_EDITION = /^(?:extended|unrated|uncut|remastered|restored|imax|criterion|repack|rerip|proper|internal|dubbed|subbed|multisubs?|chs|cht|中字|中英|中英字幕|双语|雙語|国语|國語|粤语|粵語|国英|国粤|國粵|未删减|未刪減|导演剪辑版|導演剪輯版|加长版|加長版|蓝光|藍光|高清)$/i;
// 两个词的版本：Director's Cut / Special Edition / Extended Edition …（只在片名末尾、年份之前时剥掉）
const MT_EDITION2 = /^(?:directors?|theatrical|special|extended|collectors?|anniversary|ultimate|final|definitive|criterion)\s(?:cut|edition|version)$/i;
const MT_EXTRA_WORD = /^(?:sample|trailer|teaser|featurette|preview|behindthescenes|deletedscenes?|makingof|ncop|nced)$/i;
const MT_EXTRA_ZH = /预告|預告|花絮|特辑|特輯|样片|樣片|片花/;
const MT_SITE = /www|\.(?:com|net|org|cn|cc|me|tv)\b|电影|電影|影视|影視|字幕|论坛|論壇|下载|下載|高清|发布|發布|首发|首發|小组|小組|压制|壓制|\bbt\b|\bpt\b/i;

/** 一个词是什么：spec（画质 / 片源 / 编码 / 音轨，带发布组后缀的也算）、ed（版本词）、se（季集号） */
function mtKind(t) {
  const base = t.split('-')[0];
  if (MT_SPEC.test(t) || (base !== t && base && MT_SPEC.test(base))) return 'spec';
  if (MT_EDITION.test(t)) return 'ed';
  if (MT_SE.test(t)) return 'se';
  return '';
}

/** 文件名 / 目录名 → { zh, en, alt, year, tv, season, extra, title } */
function mtParse(name) {
  const nowY = new Date().getUTCFullYear();
  let s = String(name || '').replace(/\.(mkv|mp4|m4v|mov|avi|webm|ts|m2ts|iso|wmv|flv|rmvb)$/i, '');
  // 方括号 / 书名号 / 花括号：站名、字幕组多半写在这里；里面是中文片名的留作备选
  let alt = '';
  s = s.replace(/[\[【{〔]([^\]】}〕]*)[\]】}〕]/g, (m, inner) => {
    const t = inner.trim();
    if (!alt && MT_NATIVE.test(t) && !MT_SITE.test(t) && !MT_EXTRA_ZH.test(t)) alt = t;
    return ' ';
  });
  s = s.replace(/《([^》]+)》/g, ' $1 ');
  // 分隔符：点、下划线、加号；「 - 」两边有空格的也是；单词里的连字符（Spider-Man）保留
  s = s.replace(/[._+]+/g, ' ').replace(/\s[-–—]+\s|\s[-–—]+$|^[-–—]+\s/g, ' ').replace(/\s+/g, ' ').trim();
  const toks = s ? s.split(' ') : [];
  const kind = mtKind;
  // 上映年：前面得有片名；取最后一个合理的年份（片名里的年份 ——《银翼杀手2049》《神奇女侠1984》——
  // 留在片名里）。规格词 / 季集号之后的不看；版本词之后只在前面还没有年份时才认
  // （「Title 2019 REMASTERED 2021」是 2019，「Avatar Extended Edition 2009」是 2009）
  let yi = -1, edSeen = false;
  for (let i = 1; i < toks.length; i++) {
    const k = kind(toks[i - 1]);
    if (k === 'spec' || k === 'se') break;
    if (k === 'ed') edSeen = true;
    const m = MT_YEAR.exec(toks[i]);
    if (m && +m[1] >= 1900 && +m[1] <= nowY + 1 && !(edSeen && yi > 0)) yi = i;
  }
  let end = toks.length;
  if (yi > 0) end = yi;
  for (let i = 0; i < end; i++) {
    const k = kind(toks[i]);
    if (i > 0 && (k === 'spec' || k === 'se')) { end = i; break; }
  }
  let head = toks.slice(0, end);
  for (;;) {
    const n = head.length;
    if (n > 2 && MT_EDITION2.test(head[n - 2].replace(/['’]/g, '') + ' ' + head[n - 1])) { head = head.slice(0, n - 2); continue; }
    if (n > 1 && kind(head[n - 1]) === 'ed') { head = head.slice(0, n - 1); continue; }
    break;
  }
  const tail = toks.slice(end);
  const out = { zh: '', en: '', alt: '', year: yi > 0 ? MT_YEAR.exec(toks[yi])[1] : '', tv: false, season: 0, extra: false, title: '' };
  // 季集号：S01E02 / 1x02 / Season 1 / 第一季
  const se = /(?:^|\s)s(\d{1,2})(?:e\d{1,4})?(?:\s|$)|(?:^|\s)(\d{1,2})x\d{2,3}(?:\s|$)|season\s?(\d{1,2})|第\s*([一二三四五六七八九十\d]{1,3})\s*季/i.exec(s);
  if (se) { out.tv = true; out.season = +(se[1] || se[2] || se[3]) || ({ 一: 1, 二: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10 })[se[4]] || +se[4] || 0; }
  else if (/(?:^|\s)(?:e|ep)\d{1,4}(?:\s|$)|第\s*\d+\s*[集话話]/i.test(s)) out.tv = true;
  // 样片 / 预告 / 花絮：片名之后出现、或整个名字就是它；中文标记在哪都算
  const tailWords = tail.join(' ').toLowerCase().replace(/[^a-z]+/g, ' ');
  out.extra = MT_EXTRA_ZH.test(String(name || ''))
    || /\b(?:sample|trailer|teaser|featurette|ncop|nced)\b|behind the scenes|deleted scenes?|making of/.test(tailWords)
    || (head.length <= 2 && head.some(t => MT_EXTRA_WORD.test(t)));
  // 中英分开：含汉字 / 假名 / 谚文的词归原文名，其余归英文名
  const nat = [], lat = [];
  for (const t of head) (MT_NATIVE.test(t) ? nat : lat).push(t);
  out.zh = nat.join(' ').replace(/[\s:：·\-–—]+$/, '').trim();
  out.en = /[a-z0-9]/i.test(lat.join('')) ? lat.join(' ').replace(/^[\s:：\-–—]+|[\s:：\-–—]+$/g, '').trim() : '';
  if (alt && alt !== out.zh) out.alt = alt;
  if (!out.zh && out.alt) { out.zh = out.alt; out.alt = ''; }
  out.title = out.en || out.zh;
  return out;
}

/** 一句自由文本的查询（前端传来的 query + year）→ 与 mtParse 同形 */
function mtQuery(query, year) {
  const q = mtParse(String(query || ''));
  // 前端传的已经是片名：解析不出东西就原样用
  if (!q.title) { const t = String(query || '').trim(); if (MT_NATIVE.test(t)) q.zh = t; else q.en = t; q.title = t; }
  if (year && /^(?:19|20)\d{2}$/.test(String(year))) q.year = String(year);
  q.extra = false;   // 前端问的是片名，不是文件名
  return q;
}

const MT_ROMAN = { ii: 2, iii: 3, iv: 4, vi: 6, vii: 7, viii: 8, ix: 9 };
const MT_WORDNUM = { one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10 };
const MT_ZHNUM = { 一: '1', 二: '2', 三: '3', 四: '4', 五: '5', 六: '6', 七: '7', 八: '8', 九: '9', 十: '10' };

function mtNorm(s) {
  let t = String(s || '').normalize('NFKC').normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase();
  t = t.replace(/&/g, ' and ').replace(/['’‘`´]/g, '').replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
  // 「第二部」「第3集」里的中文数字 → 阿拉伯数字（续集号要能比）
  t = t.replace(/第([一二三四五六七八九十])(?=[部集季章])/g, (m, d) => '第' + MT_ZHNUM[d]);
  return t.split(' ').filter(Boolean).map(w => MT_ROMAN[w] ? String(MT_ROMAN[w]) : MT_WORDNUM[w] ? String(MT_WORDNUM[w]) : w).join(' ');
}

/** 片名相似度 0–1：字二元组的 Dice（中英文都适用）；片名里的数字（续集号）对不上就压分 */
function mtSim(a, b) {
  const A = mtNorm(a), B = mtNorm(b);
  if (!A || !B) return 0;
  if (A === B) return 1;
  const a0 = A.replace(/ /g, ''), b0 = B.replace(/ /g, '');
  if (a0 === b0) return 0.97;
  const big = x => { const m = new Map(); if (x.length < 2) { m.set(x, 1); return m; } for (let i = 0; i < x.length - 1; i++) { const k = x.substr(i, 2); m.set(k, (m.get(k) || 0) + 1); } return m; };
  const x = big(a0), y = big(b0);
  let inter = 0, nx = 0, ny = 0;
  for (const v of x.values()) nx += v;
  for (const v of y.values()) ny += v;
  for (const [k, v] of x) inter += Math.min(v, y.get(k) || 0);
  let sim = (2 * inter) / (nx + ny);
  const nums = s => (s.match(/\d+/g) || []).join(',');
  const na = nums(A), nb = nums(B);
  if (na !== nb) sim *= (na && nb) ? 0.55 : 0.8;
  return sim;
}

function mtYearScore(qy, cy, tv) {
  if (!qy) return 0;
  if (!cy) return -12;
  const d = cy - qy;
  if (tv) {   // 剧集：文件里的年份常是「这一季」的年份 —— 首播不晚于它就行
    if (d === 0) return 20;
    if (d < 0 && d >= -40) return 8;
    if (d === 1) return 4;
    return -45;
  }
  const ad = Math.abs(d);
  return ad === 0 ? 25 : ad === 1 ? 12 : ad === 2 ? -10 : -45;
}

function mtScore(c, q, kind) {
  const names = [c.zh, c.en, c.orig, ...(c.alt || [])].filter(Boolean);
  const qs = [q.en, q.zh, q.alt].filter(Boolean);
  let sim = 0;
  for (const a of qs) for (const b of names) { const v = mtSim(a, b); if (v > sim) sim = v; }
  const cy = parseInt(String(c.date || '').slice(0, 4), 10) || 0;
  const ys = mtYearScore(parseInt(q.year, 10) || 0, cy, c.type === 'tv');
  const pop = Math.min(8, Math.log10(1 + (c.votes || 0)) * 2.4);
  const typeAdj = kind ? 0 : ((c.type === 'tv') !== !!q.tv ? -15 : 0);
  const first = c.rank === 0 ? 3 : 0;   // TMDB 自己也认它最相关
  return { sim, ys, score: sim * 100 + ys + pop + typeAdj + first };
}

/** 一次 TMDB 搜索（失败抛错，和「搜了没有」分开 —— 前者不能当成没有这部片） */
async function mtSearch(type, query, year, lang, env, budget) {
  if (budget) { if (budget.left <= 0) throw new Error('tmdb budget'); budget.left--; }
  const p = new URLSearchParams({ api_key: env.TMDB_API_KEY, query, language: lang, page: '1', include_adult: 'false' });
  // 剧集用 year 而不是 first_air_date_year：前者首播与任一集的播出年份都算 —— 第四季那年也能搜到
  if (year) p.set('year', year);
  const res = await fetchRetry(`https://api.themoviedb.org/3/search/${type}?${p}`, {}, { retries: 1, timeout: 6000 });
  if (!res.ok) throw new Error('tmdb search ' + res.status);
  return ((await res.json()).results || []).slice(0, 10);
}

/** 中英两种语言各搜一次，候选按「类型:编号」合并：中文名 / 海报 / 简介取中文那份，英文名取英文那份 */
async function mtCollect(cands, type, query, year, env, budget) {
  const [zh, en] = await Promise.all([
    mtSearch(type, query, year, 'zh-CN', env, budget),
    mtSearch(type, query, year, 'en-US', env, budget),
  ]);
  const add = (list, lang) => list.forEach((r, i) => {
    const k = type + ':' + r.id;
    let c = cands.get(k);
    if (!c) {
      c = { type, id: r.id, rank: i, zh: '', en: '', orig: r.original_title || r.original_name || '', lang: r.original_language || '',
        date: r.release_date || r.first_air_date || '', votes: r.vote_count || 0, rating: r.vote_average || 0,
        poster: null, backdrop: null, overview: '', alt: null, raw: r };
      cands.set(k, c);
    }
    c.rank = Math.min(c.rank, i);
    const name = r.title || r.name || '';
    if (lang === 'zh') {
      c.zh = name; c.raw = r;
      if (r.poster_path) c.poster = r.poster_path;
      if (r.backdrop_path) c.backdrop = r.backdrop_path;
      if (r.overview) c.overview = r.overview;
    } else {
      c.en = name;
      if (!c.poster && r.poster_path) c.poster = r.poster_path;
      if (!c.backdrop && r.backdrop_path) c.backdrop = r.backdrop_path;
      if (!c.overview && r.overview) c.overview = r.overview;
    }
  });
  add(zh, 'zh'); add(en, 'en');
}

/** 别名表 + 各语言译名（罗马音、繁体、港台译名）：只给拿不准的前两名补 */
async function mtAliases(c, env, budget) {
  if (c.alt) return;
  if (budget) { if (budget.left <= 0) return; budget.left--; }
  const r = await fetchRetry(`https://api.themoviedb.org/3/${c.type}/${c.id}?api_key=${env.TMDB_API_KEY}&append_to_response=alternative_titles,translations`,
    {}, { retries: 1, timeout: 6000 }).catch(() => null);
  const d = r && r.ok ? await r.json().catch(() => null) : null;
  const alt = [];
  const at = d && d.alternative_titles;
  for (const x of (at && (at.titles || at.results)) || []) if (x && x.title) alt.push(x.title);
  for (const x of (d && d.translations && d.translations.translations) || []) {
    const t = x && x.data && (x.data.title || x.data.name);
    if (t) alt.push(t);
  }
  c.alt = [...new Set(alt)].slice(0, 80);
}

const MT_ACCEPT = 75;   // 总分门槛：片名一模一样、没有年份时约 100–108；片名七成像、年份正好时约 95

/**
 * q：mtParse / mtQuery 的结果；kind：'movie' | 'tv' | ''（'' = 电影优先，剧集只在明显是剧集、或电影一个都认不上时才看）
 * 返回 { c, sim, score }，认不上返回 null；TMDB 出错抛错（调用方不能把它记成「没有这部片」）
 */
async function tmdbMatch(q, env, kind = '', budget = null) {
  if (!q || q.extra || !(q.en || q.zh || q.alt)) return null;
  const cands = new Map();
  const queries = [...new Set([q.en, q.zh, q.alt].filter(Boolean))];
  const best = () => {
    let b = null;
    for (const c of cands.values()) { const s = mtScore(c, q, kind); if (!b || s.score > b.score) b = { c, ...s }; }
    return b;
  };
  const sure = b => b && b.sim >= 0.95 && (b.ys >= 12 || !q.year);
  // strict：电影优先时拿剧集顶上 —— 片名要几乎一样，年份要正好是首播那年（不然随便哪部老剧在那年播过一季都能顶上）
  const ok = (b, strict) => b && b.sim >= (strict ? 0.85 : 0.5) && b.score >= MT_ACCEPT && (!strict || !q.year || b.ys >= 20);
  const types = kind ? [kind] : (q.tv ? ['tv', 'movie'] : ['movie', 'tv']);
  for (let ti = 0; ti < types.length; ti++) {
    const type = types[ti];
    // 不限类型时，第二类（电影优先时的剧集）只在第一类一个都认不上时才看，只搜一次，而且要更像才认
    if (ti > 0) {
      if (ok(best(), false)) break;
      await mtCollect(cands, type, queries[0], q.year, env, budget);
      continue;
    }
    for (const query of queries) {
      await mtCollect(cands, type, query, q.year, env, budget);
      if (sure(best())) return best();
    }
    // 年份可能写错（再版年 / 制作年）：去掉年份再搜一次，打分里年份照样算
    if (q.year) {
      await mtCollect(cands, type, queries[0], '', env, budget);
      if (sure(best())) return best();
    }
  }
  let b = best();
  const strictTv = c => !kind && !q.tv && c.type === 'tv';
  if (b && ok(b, strictTv(b.c))) return b;
  // 别名补救：年份对得上（±1）、TMDB 也排得靠前的两名，取别名表与各语言译名再比一次
  if (q.year) {
    const near = [...cands.values()].filter(c => mtScore(c, q, kind).ys >= 12 && c.rank <= 2)
      .sort((x, y) => x.rank - y.rank).slice(0, 2);
    for (const c of near) await mtAliases(c, env, budget);
    b = best();
    if (b && ok(b, strictTv(b.c))) return b;
  }
  return null;
}

/** 兼容外壳：按类型认一部片，返回 TMDB 搜索结果那个形状（认不上 / 出错 → null） */
async function tmdbSearch(type, query, year, env) {
  const m = await tmdbMatch(mtQuery(query, year), env, type).catch(() => null);
  return m ? Object.assign({}, m.c.raw, { id: m.c.id }) : null;
}

/** 文件名 → { title, year, zh, en, alt, tv, season, extra }（title = 英文名，没有就中文名）。
    文件名一定带扩展名（osGuess 还会特意补一个「.x」）：先去掉最后一段，再交给 mtParse */
function parseFilename(fn) { return mtParse(String(fn || '').replace(/\.[^./\s]{1,6}$/, '')); }

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  剧集（TV_FOLDER，默认 /ram2）：/api/tv、/api/tv/episodes、/api/tmdb/season
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  一级目录 = 一部剧的一季；目录里再分「Season 1 / S02 / 第三季」子目录的，每个子目录各算一季；
//  一个目录里混着几季文件（S01E01…S02E08）的，按文件里的季号拆开。
//  目录名里读出：中英文名、季、年份、分辨率、HDR / 杜比视界、编码、片源、音频、语言、平台、全集 / 共 N 集。
//  分集按文件名里的集号排（S01E02 / 1x02 / E02 / EP02 / 第2集 / [02] / 纯数字），
//  样片、预告、花絮、特别篇不算集；同一集有两个版本时留大的那个。
//  TMDB 补三样目录名给不了的东西：中文剧名（目录只有英文名时）、这一季的首播年份（首页年份行靠它）、
//  TMDB 编号（详情页分集剧照靠它）。每次请求最多补 TV_META_BUDGET 部，剩下的后台接着补。
//  整棵目录树递归列一次，剧集表、分集表、TMDB 补充信息一起存 R2（没绑 R2 就放 Cache API），
//  10 分钟内直接用；过期先给旧的、后台再刷新 —— 首页与详情页都不用等 Dropbox。

const TV_STORE = 'tv/list-v1.json';
const TV_CACHE_KEY = 'https://cache.internal/tv/list-v1';
const TV_FRESH_MS = 10 * 60e3;            // 目录表多久重扫一次
const TV_META_RETRY_MS = 3 * 86400e3;     // TMDB 查不到的剧，三天后再试
const TV_META_BUDGET = 16;                // 一次请求最多给几部剧查 TMDB（每部 2–8 个子请求）
const TV_META_V = 2;                      // 2：匹配管线重写 —— 旧算法认的编号（可能认错）整批重认
const tvRoot = env => ('/' + String(env.TV_FOLDER || '/ram2').replace(/^\/+|\/+$/g, '')).replace(/^\/$/, '');
let tvMem = null;                         // { v, at, root, series, eps, meta }

const ZH_NUM = { 零: 0, 〇: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9 };
/** 「十二」「二十三」「一百零五」「12」→ 数字 */
function zhNum(x) {
  x = String(x || '').trim();
  if (/^\d+$/.test(x)) return +x;
  let n = 0, cur = 0;
  for (const ch of x) {
    if (ch in ZH_NUM) cur = ZH_NUM[ch];
    else if (ch === '十') { n += (cur || 1) * 10; cur = 0; }
    else if (ch === '百') { n += (cur || 1) * 100; cur = 0; }
  }
  return n + cur;
}

const TV_BRANDS = [
  [/\b(NF|Netflix)\b/i, 'Netflix'], [/\b(AMZN|Amazon)\b/i, 'Prime Video'], [/\b(DSNP|Disney\+?)\b/i, 'Disney+'],
  [/\b(HMAX|HBO)\b|\bMAX\b/, 'HBO'], [/\b(ATVP|Apple\s?TV\+?)\b/i, 'Apple TV+'], [/\bHULU\b/i, 'Hulu'], [/\b(PCOK|Peacock)\b/i, 'Peacock'],
  [/\b(PMTP|Paramount\+?)\b/i, 'Paramount+'], [/iQIYI|爱奇艺|愛奇藝/i, '爱奇艺'], [/WeTV|腾讯视频|騰訊視頻|Tencent/i, '腾讯视频'],
  [/Youku|优酷|優酷/i, '优酷'], [/MGTV|芒果/i, '芒果TV'], [/Bilibili|哔哩哔哩|B站/i, '哔哩哔哩'], [/\bBBC\b/, 'BBC'],
];
// 片名到此为止：季号、年份（前面得有分隔）、画质、片源、编码、全集 / 共 N 集
const TV_SPEC = /\b(?:S\d{1,2}(?:E\d+)?|Season\s*\d{1,2}(?!\d)|4320p|2160p|1080[pi]|720p|4K|8K|UHD|WEB-?DL|WEB-?Rip|WEB|Blu-?Ray|BDRip|REMUX|HDTV|H\s?26[45]|x26[45]|HEVC|AVC|AV1|HDR10\+?|HDR|DV|DoVi|Complete|Full)\b|(?<=^|[\s\-[(（【])(?:19|20)\d{2}(?=$|[\s\-\])）】])|第\s*[一二三四五六七八九十\d]+\s*季|[全共]\s*\d+\s*[集话話]/gi;
const HAS_CJK = /[\u3400-\u9fff\uf900-\ufaff]/;

/** 剧集目录名 → 片名与规格 */
function tvParseName(raw) {
  const s = String(raw || '').replace(/[._]+/g, ' ').replace(/\s+/g, ' ').trim();
  const out = { zh: '', en: '', season: 0, seasonLabel: '', year: '', res: '', hdr: '', codec: '', source: '', audio: '',
    langs: [], tags: [], brand: '', full: false, declared: 0 };
  // 年份：取最后一个前后有分隔的 19xx / 20xx（《1923》这种片名本身就是年份的，不能取第一个）
  const years = [...s.matchAll(/(?<=^|[\s[(（【-])((?:19|20)\d{2})(?=$|[\s\])）】-])/g)];
  const yr = years.filter(m => m.index > 0).pop() || (years.length > 1 ? years[years.length - 1] : null);
  if (yr) out.year = yr[1];
  let m = /(?:^|[^a-z0-9])S(\d{1,2})(?:E\d+)?(?![\d])/i.exec(s) || /\bSeason\s*(\d{1,2})\b/i.exec(s) || /第\s*([一二三四五六七八九十\d]{1,3})\s*季/.exec(s);
  if (m) out.season = zhNum(m[1]);
  m = /Full[-\s]?(\d{1,4})/i.exec(s) || /[全共]\s*(\d{1,4})\s*[集话話]/.exec(s) || /\bE\d{1,4}\s*[-~]\s*E?(\d{1,4})\b/i.exec(s);
  if (m) out.declared = +m[1];
  out.full = /\b(Complete|Full)\b|全集|完结|完結/i.test(s) || /全\s*\d+\s*[集话話]/.test(s);
  if (/4320p|\b8K\b/i.test(s)) out.res = '8K'; else if (/2160p|\b4K\b|\bUHD\b/i.test(s)) out.res = '4K';
  else if (/1080[pi]/i.test(s)) out.res = '1080p'; else if (/720p/i.test(s)) out.res = '720p';
  if (/\b(DV|DoVi|Dolby\s*Vision)\b|杜比视界/i.test(s)) out.hdr = 'DV'; else if (/HDR10\+|HDR10Plus/i.test(s)) out.hdr = 'HDR10+';
  else if (/\bHDR(10)?\b/i.test(s)) out.hdr = 'HDR'; else if (/\bHLG\b/i.test(s)) out.hdr = 'HLG';
  if (/\b(H\s?265|x265|HEVC)\b/i.test(s)) out.codec = 'H.265'; else if (/\b(H\s?264|x264|AVC)\b/i.test(s)) out.codec = 'H.264';
  else if (/\bAV1\b/i.test(s)) out.codec = 'AV1';
  if (/WEB-?DL/i.test(s)) out.source = 'WEB-DL'; else if (/WEB-?Rip/i.test(s)) out.source = 'WEBRip';
  else if (/Blu-?Ray|BDRip|REMUX/i.test(s)) out.source = 'BluRay'; else if (/HDTV/i.test(s)) out.source = 'HDTV';
  if (/Atmos|全景声/i.test(s)) out.audio = 'Atmos'; else if (/TrueHD/i.test(s)) out.audio = 'TrueHD'; else if (/\bDTS/i.test(s)) out.audio = 'DTS';
  else if (/\bDDP|E-?AC-?3|DD\+/i.test(s)) out.audio = 'DD+'; else if (/\bAAC\b/i.test(s)) out.audio = 'AAC';
  const L = (re, v) => { if (re.test(s) && !out.langs.includes(v)) out.langs.push(v); };
  L(/国语|國語|普通话|国粤|國粵|Mandarin/i, '国语'); L(/粤语|粵語|国粤|國粵|Cantonese/i, '粤语');
  L(/英语|英語|中英|English/i, '英语'); L(/日语|日語|Japanese/i, '日语'); L(/韩语|韓語|Korean/i, '韩语');
  for (const [re, b] of TV_BRANDS) if (re.test(s)) { out.brand = b; break; }
  // 片名：去掉方括号 / 圆括号里的东西，截到第一个规格词为止（规格词在最前面的不算，片名不能为空）
  let head = s.replace(/\[[^\]]*\]|【[^】]*】|\([^)]*\)|（[^）]*）/g, ' ').replace(/\s+/g, ' ').trim();
  TV_SPEC.lastIndex = 0;
  for (const c of head.matchAll(TV_SPEC)) { if (c.index > 0) { head = head.slice(0, c.index); break; } }
  head = head.replace(/[-–—|·•:：\s]+$/, '').trim();
  // 中文名：数字只认紧贴着汉字的（《请回答1988》），隔了空格的归英文那半（「三体 3 Body Problem」）
  const zh = (head.match(/[\u3400-\u9fff\uf900-\ufaff](?:[\u3400-\u9fff\uf900-\ufaff0-9：:·！!？?，、]|\s(?=[\u3400-\u9fff\uf900-\ufaff]))*/g) || []).join(' ');
  const en = head.replace(/[\u3400-\u9fff\uf900-\ufaff][\u3400-\u9fff\uf900-\ufaff0-9：·！？，、]*/g, ' ').replace(/\s+/g, ' ').trim();
  out.zh = zh.replace(/[\s：:·，、]+$/, '').trim();
  out.en = /[a-z0-9]{2}/i.test(en) ? en.replace(/^[-:\s]+|[-:\s]+$/g, '') : '';
  out.seasonLabel = out.season ? `第 ${out.season} 季` : '';
  out.tags = [out.res, out.hdr === 'DV' ? '杜比视界' : out.hdr, out.audio === 'Atmos' ? '全景声' : ''].filter(Boolean);
  return out;
}

const TV_SKIP = /(?:^|[^a-z])(sample|trailer|teaser|featurette|preview|NCOP|NCED)(?:[^a-z]|$)|预告|預告|花絮|特辑|特輯|样片|樣片/i;
const TV_SKIP_DIR = /^(extras?|featurettes?|specials?|samples?|trailers?|bonus|behind[\s._-]the[\s._-]scenes|花絮|特辑|特輯|番外|预告|預告)$/i;
const TV_SEASON_DIR = /^(season\s*\d{1,2}|s\d{1,2}|第\s*[一二三四五六七八九十\d]+\s*季)$/i;

/** 文件名 → { season?, ep }（认不出 → null） */
function tvEpOf(name) {
  const s = String(name || '').replace(/\.[^.]+$/, '');
  let m = /(?:^|[^a-z0-9])S(\d{1,2})[ ._-]?E(\d{1,4})(?!\d)/i.exec(s);
  if (m) return { season: +m[1], ep: +m[2] };
  m = /(?:^|[^a-z0-9])(\d{1,2})x(\d{2,3})(?!\d)/i.exec(s);
  if (m) return { season: +m[1], ep: +m[2] };
  m = /(?:^|[^a-z])(?:EP?|Episode)[ .]?(\d{1,4})(?!\d)/i.exec(s);
  if (m) return { ep: +m[1] };
  m = /第\s*([一二三四五六七八九十百零〇两\d]{1,6})\s*[集话話]/.exec(s);
  if (m) return { ep: zhNum(m[1]) };
  m = /\[(\d{1,4})(?:v\d)?\]/i.exec(s) || /\s-\s(\d{1,4})(?:v\d)?(?:\s|$)/i.exec(s) || /^(\d{1,4})(?!\d)/.exec(s.trim());
  if (m && !/^(19|20)\d{2}$/.test(m[1])) return { ep: +m[1] };
  return null;
}

/** Dropbox 递归列目录（自动翻页；目录不存在 → []） */
async function dbxListTree(root, env) {
  const token = await getAccessToken(env);
  const call = async (ep, body) => {
    const r = await fetchRetry(`https://api.dropboxapi.com/2/files/${ep}`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    }, { retries: 2, timeout: 20_000 });
    if (r.status === 409) { const t = await r.text().catch(() => ''); if (/not_found/.test(t)) return null; throw new Error(`${ep}: 409 ${t.slice(0, 120)}`); }
    if (!r.ok) throw new Error(`${ep} failed: ${r.status}`);
    return r.json();
  };
  let res = await call('list_folder', { path: root, recursive: true, limit: 2000 });
  if (!res) return [];
  const out = [...(res.entries || [])];
  for (let i = 0; res.has_more && i < 100; i++) {
    res = await call('list_folder/continue', { cursor: res.cursor });
    if (!res) break;
    out.push(...(res.entries || []));
  }
  return out;
}

/** 一组文件 → 排好序的分集表 */
function tvEpisodeList(files) {
  const byEp = new Map(), loose = [];
  for (const it of files) {
    if (it.m && it.m.ep > 0) { const had = byEp.get(it.m.ep); if (!had || it.size > had.size) byEp.set(it.m.ep, it); }
    else loose.push(it);
  }
  const list = [...byEp.values()].sort((a, b) => a.m.ep - b.m.ep).map(it => ({ ...it, ep: it.m.ep }));
  // 认不出集号的（「上.mkv」「下.mkv」这类），按文件名排在最后
  let next = list.length ? list[list.length - 1].ep : 0;
  for (const it of loose.sort((a, b) => a.name.localeCompare(b.name, 'zh'))) list.push({ ...it, ep: ++next });
  return list;
}

/** 整棵 TV 目录 → { series, eps: { 剧 path 小写: [{ ep, path, name, size }] } } */
async function tvScan(env) {
  const root = tvRoot(env), rootLow = root.toLowerCase();
  const entries = await dbxListTree(root, env);
  const groups = new Map();
  for (const e of entries) {
    if (e['.tag'] !== 'file' || !VIDEO_EXTS.has(getExt(e.name || ''))) continue;
    const disp = e.path_display || '';
    if (!disp.toLowerCase().startsWith(rootLow + '/')) continue;
    const rel = disp.slice(root.length + 1).split('/');
    if (rel.length < 2) continue;                                    // TV 根目录下散放的文件不算剧
    if (rel.slice(1, -1).some(d => TV_SKIP_DIR.test(d.trim()))) continue;
    if (TV_SKIP.test(e.name)) continue;
    const seasonDir = rel.length >= 3 && TV_SEASON_DIR.test(rel[1].trim()) ? rel[1] : null;
    const dir = root + '/' + rel[0] + (seasonDir ? '/' + seasonDir : '');
    const k = dir.toLowerCase();
    if (!groups.has(k)) groups.set(k, { dir, top: rel[0], seasonDir, files: [] });
    groups.get(k).files.push({ name: e.name, path: disp, size: e.size || 0, at: e.server_modified || e.client_modified || '', m: tvEpOf(e.name) });
  }
  const series = [], eps = {};
  const emit = (g, info, files, path) => {
    const list = tvEpisodeList(files);
    if (!list.length) return;
    const k = path.toLowerCase();
    eps[k] = list.map(({ ep, path: p, name, size }) => ({ ep, path: p, name, size }));
    const added = list.reduce((a, x) => (x.at > a ? x.at : a), '');
    series.push({
      id: 'tv-' + fnv1a(k), folder: g.seasonDir ? `${g.top} · ${g.seasonDir}` : g.top, path,
      title: info.zh || info.en || g.top, zh: info.zh, en: info.en,
      season: info.season, seasonLabel: info.season ? `第 ${info.season} 季` : '', year: info.year,
      res: info.res, hdr: info.hdr, codec: info.codec, source: info.source, audio: info.audio,
      langs: info.langs, tags: info.tags, brand: info.brand,
      full: info.full, declared: info.declared, tmdbId: 0, total: 0,
      episodes: list.length, complete: !!(info.declared ? list.length >= info.declared : info.full),
      size: list.reduce((n, x) => n + (x.size || 0), 0), added: added || null,
    });
  };
  for (const g of groups.values()) {
    const info = tvParseName(g.top);
    if (g.seasonDir) {
      const sn = tvParseName(g.seasonDir).season;
      if (/^(season\s*0+|s0+)$/i.test(g.seasonDir.trim())) continue;   // Season 0 / S00 = 特别篇
      if (sn) info.season = sn;
    }
    const files = g.files.filter(f => !(f.m && f.m.season === 0));   // S00Exx 特别篇不混进正片
    const fileSeasons = [...new Set(files.map(f => f.m && f.m.season).filter(n => n > 0))].sort((a, b) => a - b);
    if (fileSeasons.length > 1 && !g.seasonDir) {
      // 一个目录装了好几季：按季拆开，每季一张卡；没写季号的文件归到最早那季
      for (const sn of fileSeasons) {
        const part = files.filter(f => (f.m && f.m.season ? f.m.season : fileSeasons[0]) === sn);
        emit(g, { ...info, season: sn, declared: 0, full: info.full }, part, `${g.dir}#S${sn}`);
      }
      continue;
    }
    if (!info.season && fileSeasons.length === 1) info.season = fileSeasons[0];
    emit(g, info, files, g.dir);
  }
  return { series, eps };
}

const tvMetaKey = s => `${String(s.en || s.zh || s.title || '').toLowerCase()}|${s.season || 0}`;

/** TMDB：编号、中文名、这一季的首播年份、这一季的集数。
    中英文名一起交给 tmdbMatch 打分（不再拿第一条）；认不上记 miss、三天后再试；TMDB 出错一小时后再试 */
async function tvLookup(s, env) {
  const q = { en: s.en || '', zh: s.zh || '', alt: '', year: s.year || '', tv: true, season: s.season || 0, extra: false, title: s.en || s.zh || '' };
  let m = null;
  try { m = await tmdbMatch(q, env, 'tv'); }
  catch { return { miss: 1, err: 1, at: Date.now() - TV_META_RETRY_MS + 3600e3 }; }
  if (!m) return { miss: 1, at: Date.now() };
  const hit = Object.assign({}, m.c.raw, { id: m.c.id });
  const d = await fetchRetry(`https://api.themoviedb.org/3/tv/${hit.id}?api_key=${env.TMDB_API_KEY}&language=zh-CN`, {}, { retries: 1, timeout: 6000 })
    .then(r => (r.ok ? r.json() : null)).catch(() => null);
  const sn = s.season || 1;
  const season = d && (d.seasons || []).find(x => x.season_number === sn);
  const date = (season && season.air_date) || (sn === 1 ? (d && d.first_air_date) || hit.first_air_date || '' : '');
  const zh = [d && d.name, hit.name].find(n => n && HAS_CJK.test(n)) || '';
  return { id: hit.id, zh, year: String(date || '').slice(0, 4), total: (season && season.episode_count) || 0, at: Date.now() };
}

/** 把 TMDB 补充信息落到剧集表上：目录名有的以目录名为准（中文名、年份），没有的才用 TMDB */
function tvApplyMeta(d) {
  for (const s of d.series) {
    const m = d.meta[tvMetaKey(s)];
    // TMDB 确定认不出这部剧（不是出错）：标出来，前端不排它 —— 没有封面的剧不显示
    if (m && m.miss && !m.err) s.tmdbMiss = true; else delete s.tmdbMiss;
    if (!m || m.miss) continue;
    s.tmdbId = m.id;
    if (!s.zh && m.zh) { s.zh = m.zh; s.title = m.zh; }
    if (m.year) s.year = m.year;           // 这一季的首播年：S04 归 2024，不归 2019
    if (m.total) s.total = m.total;
  }
}

const tvMetaPending = d => !!d.series.find(s => {
  const m = d.meta[tvMetaKey(s)];
  return !m || (m.miss && Date.now() - m.at > TV_META_RETRY_MS);
});

/** 给还没 TMDB 信息的剧补上（每次最多 TV_META_BUDGET 部；timeMs 到点就先交，剩下的下次补） */
async function tvEnrich(env, d, timeMs) {
  if (!env.TMDB_API_KEY) return false;
  const todo = [], seen = new Set();
  for (const s of d.series) {
    const k = tvMetaKey(s), m = d.meta[k];
    if (seen.has(k) || (m && !(m.miss && Date.now() - m.at > TV_META_RETRY_MS))) continue;
    seen.add(k); todo.push([k, s]);
    if (todo.length >= TV_META_BUDGET) break;
  }
  if (!todo.length) return false;
  const work = parallel(todo.map(([k, s]) => async () => { d.meta[k] = await tvLookup(s, env); }), 4);
  if (timeMs) await Promise.race([work, sleep(timeMs)]); else await work;
  tvApplyMeta(d);
  return true;
}

async function tvLoad(env) {
  const r = await r2GetJson(env, TV_STORE);
  if (r) return r;
  const hit = await caches.default.match(new Request(TV_CACHE_KEY)).catch(() => null);
  return hit ? hit.json().catch(() => null) : null;
}
async function tvSave(env, d) {
  if (env.FILE_CACHE) return r2PutJson(env, TV_STORE, d);
  await caches.default.put(new Request(TV_CACHE_KEY), new Response(JSON.stringify(d), {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=604800' },
  })).catch(() => {});
}

/** 重扫目录，带上旧的 TMDB 补充信息；首次（没有旧表）给 TMDB 留 4 秒，其余交给后台 */
async function tvRefresh(env, ctx) {
  const prev = tvMem || await tvLoad(env);
  const { series, eps } = await tvScan(env);
  const d = { v: 1, mv: TV_META_V, at: Date.now(), root: tvRoot(env), series, eps,
    meta: (prev && prev.root === tvRoot(env) && prev.mv === TV_META_V && prev.meta) || {} };
  tvApplyMeta(d);
  await tvEnrich(env, d, prev ? 0 : 4000);
  tvMem = d;
  await tvSave(env, d);
  if (tvMetaPending(d)) ctx?.waitUntil?.(singleFlight('tv-meta', () => tvEnrichMore(env)));
  return d;
}
async function tvEnrichMore(env) {
  const d = tvMem;
  if (!d || !(await tvEnrich(env, d, 0))) return;
  await tvSave(env, d);
}

/** 剧集表：内存 → R2 → 现扫。过期先给旧的、后台刷新；TMDB 还没补完的后台接着补 */
async function tvData(env, ctx, force) {
  const root = tvRoot(env);
  if (!tvMem || tvMem.root !== root) { const d = await tvLoad(env); if (d && d.root === root && d.v === 1) tvMem = d; }
  if (tvMem && tvMem.mv !== TV_META_V) tvMem.at = 0;     // 旧版匹配的表：照旧先给，后台重扫重认
  if (tvMem && tvMem.root === root && !force) {
    if (Date.now() - (tvMem.at || 0) > TV_FRESH_MS) ctx?.waitUntil?.(singleFlight('tv-scan', () => tvRefresh(env, ctx)).catch(e => console.error('tv scan:', e && e.message)));
    else if (tvMetaPending(tvMem)) ctx?.waitUntil?.(singleFlight('tv-meta', () => tvEnrichMore(env)).catch(() => {}));
    return tvMem;
  }
  return singleFlight('tv-scan', () => tvRefresh(env, ctx));
}

async function handleTv(url, env, ctx) {
  let d;
  try { d = await tvData(env, ctx, url.searchParams.get('refresh') === '1'); }
  catch (e) {
    console.error('tv:', e && e.message);
    return jsonResponse({ series: [], error: 'tv folder unavailable' }, 503, { 'Cache-Control': 'no-store' });
  }
  return jsonResponse({ root: d.root, at: d.at, series: d.series }, 200, { 'Cache-Control': 'private, max-age=60' });
}

async function handleTvEpisodes(url, env, ctx) {
  const path = (url.searchParams.get('path') || '').replace(/\/+$/, '');
  if (!path) return jsonResponse({ error: 'Missing path' }, 400);
  const k = path.toLowerCase();
  let d = await tvData(env, ctx).catch(() => null);
  // 刚放进来的新剧还不在表里：表是 30 秒前的就现扫一次
  if (d && !d.eps[k] && Date.now() - d.at > 30e3) d = await tvData(env, ctx, true).catch(() => d);
  const series = d && d.series.find(s => s.path.toLowerCase() === k);
  if (!series) return jsonResponse({ error: 'no such series' }, 404, { 'Cache-Control': 'no-store' });
  return jsonResponse({ series, episodes: d.eps[k] || [] }, 200, { 'Cache-Control': 'private, max-age=60' });
}

/** TMDB 一季的分集：中文集名 / 简介 / 剧照 / 时长；中文简介缺的集补英文 */
async function handleTmdbSeason(url, env, ctx) {
  if (!env.TMDB_API_KEY) return jsonResponse({ error: 'TMDB_API_KEY not set' }, 503);
  const id = parseInt(url.searchParams.get('id') || '', 10);
  const season = parseInt(url.searchParams.get('season') || '1', 10);
  if (!(id > 0) || !(season >= 0)) return jsonResponse({ error: 'bad id / season' }, 400);
  const ck = new Request(`${TMDB_CACHE}season?id=${id}&s=${season}`);
  const hit = await caches.default.match(ck).catch(() => null);
  if (hit) return new Response(hit.body, { headers: hit.headers });
  const get = lang => fetchRetry(`https://api.themoviedb.org/3/tv/${id}/season/${season}?api_key=${env.TMDB_API_KEY}&language=${lang}`,
    {}, { retries: 1, timeout: 8000 }).then(r => (r.ok ? r.json() : null)).catch(() => null);
  const zh = await get('zh-CN');
  if (!zh) return jsonResponse({ id, season, episodes: [] }, 200, { 'Cache-Control': 'public, max-age=600' });
  const episodes = (zh.episodes || []).map(e => ({
    ep: e.episode_number,
    // TMDB 没有中文集名时回的是「第 3 集」这种占位，留着也无妨；英文原名在下面补
    name: e.name || '', overview: e.overview || '',
    still: e.still_path ? `https://image.tmdb.org/t/p/w780${e.still_path}` : '',
    runtime: e.runtime || null, air_date: e.air_date || null,
  }));
  if (episodes.some(e => !e.overview)) {
    const en = await get('en-US');
    const by = new Map(((en && en.episodes) || []).map(e => [e.episode_number, e]));
    for (const e of episodes) {
      const x = by.get(e.ep);
      if (!x) continue;
      if (!e.overview) e.overview = x.overview || '';
      if (!e.still && x.still_path) e.still = `https://image.tmdb.org/t/p/w780${x.still_path}`;
    }
  }
  const res = jsonResponse({ id, season, name: zh.name || '', episodes }, 200,
    { 'Cache-Control': 'public, max-age=86400, stale-while-revalidate=604800' });
  ctx?.waitUntil?.(caches.default.put(ck, res.clone()).catch(() => {}));
  return res;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  优选入口（Cloudflare 优选 IP 的 Worker 侧那一半）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  ⚠️ 优选 IP 本体是 DNS 层的事，写不进这里：客户端连的是谁，只由它解析到的
//     那条 A 记录决定。链路是「灰云 A 记录 / CNAME 优选域名 → Workers 路由
//     → 本 Worker」，配置在 DNS 商与 Cloudflare 面板（步骤见文件头）。
//
//  Worker 能做、也只能做这三件 —— 恰好是决定体感的三件：
//    ① 承认「入口不止一个」                     → edgeHosts()
//    ② 让「哪个入口更快」变成可测量的数字         → /api/edge、/api/edge/ping
//    ③ 让测出来的赢家真的被用上                  → Cookie edge=<host> + 直链改写
//
//  ③ 之所以几乎零成本，靠的是 v14 签名只覆盖 path、不含 host：
//  同一个 AUTH_SECRET 下一条直链在任意入口都有效，换 host 不必重签，
//  Infuse 里存着的旧链接也不会因为换入口而失效。

const EDGE_PING_PATH   = '/api/edge/ping';
const EDGE_PROBE_PATH  = '__probe__';          // 探针伪 path，只为复用 verifyStreamSig
const EDGE_COOKIE      = 'edge';
const EDGE_COOKIE_TTL  = 6 * 3600;             // 优选结果会过期：只信 6 小时
const EDGE_PING_MAX    = 4 * 1024 * 1024;      // 单次探针上限，别成了免费带宽源
const EDGE_PING_DEF    = 256 * 1024;
const EDGE_HOST_RE     = /^[a-z0-9]([a-z0-9.\-]*[a-z0-9])?(:\d{1,5})?$/;

/**
 * 入口清单：当前请求所在 host 永远排第一（它一定可用），其后是 EDGE_HOSTS。
 * 没配 EDGE_HOSTS → 只有一个元素，全链路行为与 v18 一致。
 * 端口刻意保留：443 被干扰时优选常走 2053 / 2083 / 2087 / 2096 / 8443。
 */
function edgeHosts(env, selfHost) {
  const out = [], seen = new Set();
  for (const raw of [selfHost, ...String(env.EDGE_HOSTS || '').split(',')]) {
    const h = String(raw || '').trim()
      .replace(/^https?:\/\//, '')
      .replace(/[/?#].*$/, '')
      .toLowerCase();
    if (!h || seen.has(h) || !EDGE_HOST_RE.test(h)) continue;
    seen.add(h);
    out.push(h);
  }
  return out;
}

/** Cookie 里的优选结果只有在白名单内才作数 —— 改 Cookie 也只能在自家入口里打转 */
function pickEdgeHost(request, env, selfHost) {
  const hosts = edgeHosts(env, selfHost);
  if (hosts.length < 2) return hosts[0] || selfHost;
  const want = parseCookies(request.headers.get('Cookie') || '')[EDGE_COOKIE];
  return want && hosts.includes(want) ? want : hosts[0];
}

/**
 * /api/edge —— 「优选到底生效了没有」的唯一可信答案
 *   colo          换没换 PoP（优选的直接目的）
 *   clientTcpRtt  换完好不好（客户端 → PoP 的握手 RTT，比 ping 值诚实）
 */
function handleEdge(request, env) {
  const cf = request.cf || {};
  const url = new URL(request.url);
  return jsonResponse({
    host: url.host,
    colo: cf.colo || null,
    country: cf.country || null,
    city: cf.city || null,
    asn: cf.asn ?? null,
    asOrg: cf.asOrganization || null,
    protocol: cf.httpProtocol || null,
    tls: cf.tlsVersion || null,
    clientTcpRtt: cf.clientTcpRtt ?? null,
    hosts: edgeHosts(env, url.host),
  }, 200, { 'Cache-Control': 'no-store', 'Timing-Allow-Origin': '*', ...CORS_HEADERS });
}

/**
 * /api/edge/ping?b=<字节> —— 浏览器版 CloudflareSpeedTest 的负载源
 *
 * 两个细节决定它测得准不准：
 *   · 随机字节：可压缩的负载会被中间层压掉，测出来的是压缩比不是带宽
 *   · Timing-Allow-Origin：少了它，跨入口的 Resource Timing 全是 0
 * 流式产出，不在内存里攒 4MB。
 */
function handleEdgePing(url) {
  const want = parseInt(url.searchParams.get('b') || '', 10);
  const total = Math.min(EDGE_PING_MAX,
    Math.max(0, Number.isFinite(want) ? want : EDGE_PING_DEF));

  const CH = 65536;                    // = crypto.getRandomValues 单次上限
  const block = new Uint8Array(CH);
  crypto.getRandomValues(block);

  let sent = 0;
  const body = new ReadableStream({
    pull(c) {
      if (sent >= total) return c.close();
      const n = Math.min(CH, total - sent);
      c.enqueue(block.slice(0, n));    // slice 而非 subarray：不复用同一块底层 buffer
      sent += n;
    },
  });

  return new Response(total ? body : null, {
    headers: {
      ...CORS_HEADERS,
      'Content-Type': 'application/octet-stream',
      'Cache-Control': 'no-store',
      'Timing-Allow-Origin': '*',
    },
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /stream（透传代理 + 链接缓存 + 自愈）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  关键原则：Worker 只做 stream pipe，不截断、不缓冲。
//  客户端 Range → 原样转发 Dropbox → 上游响应头原样回传。
//  这样无论文件多大、播放器怎么 seek，都能正确续播。

const LINK_CACHE = 'https://cache.internal/link-v2/';
const LINK_TTL = 3 * 3600;

/**
 * 获取临时链接（Edge Cache + Single Flight + 自愈）
 */
async function getTempLink(filePath, env, ctx) {
  const ck = new Request(`${LINK_CACHE}?p=${encodeURIComponent(filePath)}`);
  const cache = caches.default;

  const hit = await cache.match(ck);
  if (hit) {
    try { return await hit.json(); } catch {}
  }

  return singleFlight(`link:${filePath}`, async () => {
    const data = await dbxGetTempLink(filePath, env);
    const resp = new Response(JSON.stringify(data), {
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': `public, max-age=${LINK_TTL}, s-maxage=${LINK_TTL}`,
      },
    });
    ctx?.waitUntil?.(cache.put(ck, resp));
    return data;
  });
}

/** /stream 公共响应头（GET 主路径与 HEAD 快速路径共用） */
function buildStreamHeaders(contentType, etag, rawName, t) {
  const h = new Headers();
  h.set('Content-Type', contentType);
  h.set('Accept-Ranges', 'bytes');
  h.set('ETag', etag);
  h.set('Cache-Control', 'public, max-age=14400, stale-while-revalidate=86400');
  h.set('X-Content-Type-Options', 'nosniff');
  h.set('Server-Timing', t.header());
  // 少了它，跨入口播放时浏览器把 Resource Timing 的 TTFB 一律打成 0，
  // 播放页那套「哪个入口更快」的实测就成了瞎测。
  h.set('Timing-Allow-Origin', '*');
  // Content-Disposition：让 Infuse / VLC 等播放器以真实文件名识别资源，
  // 进度条按片名独立保存（RFC 5987 双字段以兼容旧客户端）
  const asciiName = rawName.replace(/[^\x20-\x7E]/g, '_').replace(/["\\]/g, '_');
  h.set(
    'Content-Disposition',
    `inline; filename="${asciiName}"; filename*=UTF-8''${encodeURIComponent(rawName)}`
  );
  // CORS（流式路径直接设置，避免 cors() 重新包装 body）
  for (const k in CORS_HEADERS) h.set(k, CORS_HEADERS[k]);
  return h;
}

/**
 * 流式起播 fetch：只给「拿到响应头」这一步设超时，头一到立刻 clearTimeout。
 *
 * ⚠️ 关键不变量：abort 只可能在响应头到达【之前】触发。
 *    · 头在 timeout 内到达 → await fetch resolve → clearTimeout → 取消定时器，
 *      body 从此不受任何超时约束，多大文件、seek 到哪都能续播（与裸 fetch 一致）。
 *    · 头迟迟不来 → 定时器触发 abort → fetch reject（AbortError），此时 body
 *      从未产生，谈不上截断。
 * 因此它严格优于「完全不设超时」：只在 Dropbox 迟迟不回响应头（连接卡死）时
 * 快速失败（上层重试 / 502），不再干等到 CF 的 6min wall-clock；而已开始传输
 * 的 body 永不被打断（这正是此前刻意不加超时所要守护的性质）。
 */
async function fetchStreamHead(url, opts, timeout = 20_000, control = {}) {
  if (control.budget) control.budget.take(control.label || 'stream-head');
  const parent = opts && opts.signal;
  if (parent?.aborted) throw streamAbortError(parent.reason);
  const ctrl = new AbortController();
  const onAbort = () => ctrl.abort();
  if (parent) parent.addEventListener('abort', onAbort, { once: true });
  const tid = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, { ...opts, signal: ctrl.signal });
    clearTimeout(tid); // 响应头已到 → 解除超时，body 传输不再受限
    return res;
  } catch (e) {
    clearTimeout(tid);
    throw e;
  } finally {
    if (parent) parent.removeEventListener('abort', onAbort);
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  断点续传 —— 「播到一半卡死 / 无限转圈」的根治
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  一条铁律，本节所有代码都为它服务：
//
//      响应头里承诺了多少字节，body 就必须交出多少字节 —— 否则宁可报错。
//
//  短一个字节，播放器就会永远等下去（它不知道上游断了，只知道还没收满）。
//  而报错至少是干净的：播放器会重发一个 Range 请求，从头再来。
//  转圈是死局，报错是活的。

const STALL_MS_DEF    = 20_000;          // 上游静默多久算僵死
const RESUME_MAX_DEF  = 8;               // 「连续无进展」的续传上限
const OPEN_MAX_DEF    = 36;              // 整次 /stream 共享预算；给免费计划 50 次上限留余量
const RESUME_RESET    = 256 * 1024;      // 一次续传跑动这么多就算「有进展」

const stallMs   = env => envInt(env.STREAM_STALL_MS, STALL_MS_DEF, 0, 600_000);
const resumeMax = env => envInt(env.STREAM_RESUME_MAX, RESUME_MAX_DEF, 0, 500);
const openMax   = env => envInt(env.STREAM_OPEN_MAX, OPEN_MAX_DEF, 1, 900);

function streamAbortError(reason) {
  const msg = reason && reason.message ? reason.message : String(reason || 'stream cancelled');
  const e = new Error(msg);
  e.name = 'AbortError';
  return e;
}

function throwIfStreamAborted(signal) {
  if (signal?.aborted) throw streamAbortError(signal.reason);
}

function streamDelay(ms, signal) {
  if (!ms) { throwIfStreamAborted(signal); return Promise.resolve(); }
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(streamAbortError(signal.reason));
    let tid;
    const done = () => {
      if (signal) signal.removeEventListener('abort', onAbort);
      clearTimeout(tid);
    };
    const onAbort = () => { done(); reject(streamAbortError(signal.reason)); };
    if (signal) signal.addEventListener('abort', onAbort, { once: true });
    tid = setTimeout(() => { done(); resolve(); }, ms);
  });
}

function isRetryableStreamStatus(status) {
  return status === 408 || status === 425 || status === 429 || (status >= 500 && status <= 599);
}

function streamRetryAfterMs(response, fallback = 500) {
  const raw = response?.headers?.get('Retry-After');
  if (raw) {
    const seconds = Number(raw);
    if (Number.isFinite(seconds)) return Math.min(5_000, Math.max(0, seconds * 1000));
    const at = Date.parse(raw);
    if (Number.isFinite(at)) return Math.min(5_000, Math.max(0, at - Date.now()));
  }
  return fallback;
}

/**
 * 上游下载 fetch 的整次请求共享硬预算。v21 把 150 次预算分别发给每个分片，
 * 四个读取器理论上能烧到 600 次；现在所有首片、后台片、接力与直通共用一个计数器。
 */
function makeStreamBudget(env) {
  const limit = openMax(env);
  let used = 0;
  return {
    take(label = 'upstream') {
      if (used >= limit) {
        const e = new Error(`stream fetch budget exhausted (${used}/${limit}, ${label})`);
        e.code = 'STREAM_BUDGET';
        throw e;
      }
      used++;
    },
    get used() { return used; },
    get limit() { return limit; },
  };
}

/** ctx 在流式传输期间可能已经不接受 waitUntil 了，包一层免得抛出去 */
const safeCtx = ctx => ({
  waitUntil(p) { try { if (ctx && ctx.waitUntil) ctx.waitUntil(p); } catch {} return p; },
});

/**
 * 带静默看门狗的一次读取。
 *
 * ⚠️ 看门狗只在「我们正在等字节」的这一刻武装：播放器缓冲满了不来读时，
 *    read() 根本不会被调用，也就不存在误伤慢速连接的可能。它打的只有
 *    一种情况 —— 连接还在、但上游再也不吐东西了。
 */
function readWithStall(reader, ms, signal) {
  throwIfStreamAborted(signal);
  if (!ms && !signal) return reader.read();
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer = null;
    const cleanup = () => {
      if (timer) clearTimeout(timer);
      if (signal) signal.removeEventListener('abort', onAbort);
    };
    const fail = e => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(e);
    };
    const onAbort = () => fail(streamAbortError(signal.reason));
    if (signal) signal.addEventListener('abort', onAbort, { once: true });
    if (ms) timer = setTimeout(() => fail(new Error('upstream silent')), ms);
    reader.read().then(
      r => { if (!settled) { settled = true; cleanup(); resolve(r); } },
      e => fail(e),
    );
    // 看门狗先响时，上面那个 read() 会被随后的 reader.cancel() 收尾，
    // 两个分支都已带处理函数，不会留下未处理拒绝。
  });
}

/**
 * 造一个「从任意偏移打开上游」的函数，链接过期会就地换新的。
 * linkRef 是共享的，换完之后同一次请求里的其它分片也跟着用新链接。
 */
function upstreamOpener(filePath, linkRef, env, ctx, control = {}) {
  const sctx = safeCtx(ctx);
  if (!Number.isFinite(linkRef.relinks)) linkRef.relinks = 0;

  const refreshLink = async () => {
    if (linkRef.refreshing) return linkRef.refreshing;
    if (linkRef.relinks >= 3) throw new Error('temporary-link refresh limit reached');
    linkRef.relinks++;
    linkRef.refreshing = (async () => {
      await caches.default.delete(new Request(`${LINK_CACHE}?p=${encodeURIComponent(filePath)}`));
      _inflight.delete(`link:${filePath}`);
      const fresh = await getTempLink(filePath, env, sctx);
      const id = fresh.metadata?.content_hash || fresh.metadata?.rev || String(fresh.metadata?.size || '');
      // 播放过程中同路径文件被替换时绝不能把新旧字节拼在一起。
      if (linkRef.identity && id && linkRef.identity !== id) {
        const e = new Error('file changed while streaming');
        e.code = 'STREAM_FILE_CHANGED';
        throw e;
      }
      linkRef.link = fresh.link;
      linkRef.metadata = fresh.metadata;
    })().finally(() => { linkRef.refreshing = null; });
    return linkRef.refreshing;
  };

  return async (pos, end, readerSignal) => {
    // resumableReader 会把自己的内部 signal 作为第三参传来；它包含直接 cancel()
    // 的状态，优先级高于请求级 signal，因此播放器拖动能中止正在 open 的 fetch。
    const activeSignal = readerSignal || control.signal;
    throwIfStreamAborted(activeSignal);
    const headers = { Range: `bytes=${pos}-${end}`, 'Accept-Encoding': 'identity' };
    let res = await fetchStreamHedged(linkRef.link, { headers, signal: activeSignal }, env, 20_000, {
      budget: control.budget,
      hedge: control.hedge !== false,
      label: control.label || 'range-open',
    });
    if (res.status === 403 || res.status === 410) {
      try { if (res.body) await res.body.cancel(); } catch {}
      await refreshLink();
      res = await fetchStreamHedged(linkRef.link, { headers, signal: activeSignal }, env, 20_000, {
        budget: control.budget,
        hedge: control.hedge !== false,
        label: control.label || 'range-reopen',
      });
    }
    if (res.status !== 206 || !res.body) {
      const retryMs = streamRetryAfterMs(res, 500);
      const status = res.status;
      try { if (res.body) await res.body.cancel(); } catch {}
      const e = new Error(`open@${pos} → ${status}`);
      e.status = status;
      e.retryable = isRetryableStreamStatus(status);
      e.retryAfterMs = retryMs;
      throw e;
    }
    // 上游给的必须就是我们要的那一段，否则续上去的是错位的字节 ——
    // 那比卡住还糟，播放器会拿到一段看似合法、实则花屏的数据。
    const cr = res.headers.get('Content-Range') || '';
    const seg = parseContentRange(cr);
    const sizeMismatch = seg?.size != null && linkRef.size != null && seg.size !== linkRef.size;
    if (!seg || seg.start !== pos || seg.end !== end || sizeMismatch) {
      try { await res.body.cancel(); } catch {}
      throw new Error(`open@${pos} range mismatch: ${cr}`);
    }
    return res.body.getReader();
  };
}

/**
 * 可续传读取器。接口与 ReadableStreamDefaultReader 一致（read / cancel），
 * 但内部会在上游断流、报错、静默时重连并从断点续上。
 *
 * 契约：要么把 [start,end] 一个字节不少地读完，要么抛错。
 *       它永远不会「读着读着就 done 了」—— 那正是无限转圈的成因。
 *
 * opt.reader 可选：调用方已经打开了第一段连接时传进来，省一次往返。
 */
function resumableReader(opt) {
  const { start, end, open, label } = opt;
  const ms = opt.stallMs == null ? STALL_MS_DEF : opt.stallMs;
  const maxResume = opt.maxResume == null ? RESUME_MAX_DEF : opt.maxResume;
  const maxOpen = opt.maxOpen == null ? OPEN_MAX_DEF : opt.maxOpen;

  // 每个读取器都有自己的中止信号；外层 seek 的中止会向内传，直接调用
  // cancel() 也能立刻打断正在等待的 read / backoff，而不是等定时器自己走完。
  const aborter = new AbortController();
  const outerSignal = opt.signal;
  const forwardAbort = () => aborter.abort(outerSignal.reason);
  if (outerSignal?.aborted) forwardAbort();
  else if (outerSignal) outerSignal.addEventListener('abort', forwardAbort, { once: true });
  const signal = aborter.signal;

  let pos = start;
  let reader = opt.reader || null;
  // stuck = 连续「没跑动多少」的续传次数；opens = 总重连数（子请求预算）
  // 两个计数管两件不同的事：前者判「原地打转」，后者防「把配额烧光」。
  let stuck = 0, opens = 0, moved = 0, dead = null;

  // cancel()、静默看门狗与外层 abort 可能在同一时刻到达。先把所有权原子地
  // 从 reader 变量取走，再 await，保证同一条上游 body 永远只 cancel 一次。
  const cancelActive = async reason => {
    const active = reader;
    reader = null;
    if (active) { try { await active.cancel(reason); } catch {} }
  };

  const reconnect = async (cause) => {
    if (dead) throw dead;
    throwIfStreamAborted(signal);
    const firstWhy = cause?.message || String(cause || 'stream error');
    let last = null;
    for (;;) {
      throwIfStreamAborted(signal);
      if (stuck >= maxResume || opens >= maxOpen) {
        dead = new Error(`${label}: 续传放弃 @${pos} `
          + `(无进展 ${stuck}/${maxResume}，重连 ${opens}/${maxOpen}；${firstWhy}`
          + `${last ? '; ' + last.message : ''})`);
        throw dead;
      }
      stuck++; opens++;
      await cancelActive(cause);
      const retryMs = Math.max(
        Math.min(3000, 250 * stuck),
        Math.min(5000, Number(last?.retryAfterMs || cause?.retryAfterMs || 0)),
      );
      await streamDelay(retryMs, signal);
      try {
        reader = await open(pos, end, signal);
        moved = 0;
        console.log(`stream resume ${label} @${pos}/${end} (${firstWhy}) [${opens} 次]`);
        return;
      } catch (e) {
        if (signal.aborted || e?.name === 'AbortError') throw streamAbortError(signal.reason || e);
        last = e;
      }                               // 打不开就接着试，直到用尽预算
    }
  };

  return {
    async read() {
      for (;;) {
        throwIfStreamAborted(signal);
        if (pos > end) {
          await cancelActive('range complete');
          if (outerSignal) outerSignal.removeEventListener('abort', forwardAbort);
          return { done: true, value: undefined };
        }
        if (!reader) {
          // 第一次打开不算续传（调用方没预先传 reader 时走这里）
          try {
            if (opens >= maxOpen) throw new Error('reader open budget exhausted');
            opens++;
            reader = await open(pos, end, signal);
            moved = 0;
          } catch (e) {
            if (signal.aborted || e?.name === 'AbortError') throw streamAbortError(signal.reason || e);
            await reconnect(e);
          }
          continue;
        }

        let r;
        try {
          r = await readWithStall(reader, ms, signal);
        } catch (e) {
          if (signal.aborted || e?.name === 'AbortError') {
            await cancelActive(e);
            throw streamAbortError(signal.reason || e);
          }
          await reconnect(e);
          continue;
        }

        if (r.done) {
          if (pos > end) return { done: true, value: undefined };
          // 上游提前断流。这里绝不能 return done —— 那就是短 body。
          await reconnect('early EOF');
          continue;
        }

        let v = r.value;
        if (!v || v.length === 0) continue;
        const remain = end - pos + 1;
        if (v.length > remain) v = v.subarray(0, remain);   // 绝不超发
        pos += v.length;
        moved += v.length;
        // 这一程真的跑动了 → 不算"原地打转"，把 stuck 清零。
        // 一条每隔 1MB 就断一次的破线路，只要每次都能推进，就该一路续到底；
        // 而真正卡死在同一个字节上的，几次之内就会撞上 maxResume。
        // opens 不清零 —— 它守的是子请求配额，那是另一件事。
        if (moved >= RESUME_RESET && stuck) { stuck = 0; moved = 0; }
        return { done: false, value: v };
      }
    },
    async cancel(reason) {
      if (!aborter.signal.aborted) aborter.abort(reason);
      dead = dead || streamAbortError(reason);
      if (outerSignal) outerSignal.removeEventListener('abort', forwardAbort);
      await cancelActive(reason);
    },
    get position() { return pos; },
  };
}

/** 把可续传读取器包成 ReadableStream，直接塞进 Response */
function resumableStream(opt) {
  const rr = resumableReader(opt);
  return new ReadableStream({
    async pull(c) {
      try {
        const r = await rr.read();
        if (r.done) return c.close();
        c.enqueue(r.value);
      } catch (e) {
        await rr.cancel(e);
        c.error(e);      // 补不齐了 → 干净报错，让播放器重试，好过端给它一个永远补不齐的响应
      }
    },
    cancel(reason) { return rr.cancel(reason); },
  });
}

/** 'bytes 100-199/1000' → { start, end, size } */
function parseContentRange(cr) {
  const m = /^bytes\s+(\d+)-(\d+)\/(\d+|\*)$/.exec(String(cr || '').trim());
  if (!m) return null;
  const start = +m[1], end = +m[2];
  if (!(end >= start)) return null;
  return { start, end, size: m[3] === '*' ? null : +m[3] };
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  快速定位（seek）—— 对齐分片 · 边缘缓存 · 并行突发
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  这一节是 v20 的全部内容，也是唯一敢动 /stream 主路径的地方。
//  贯穿它的一条纪律：任何一步出问题都要能退回 v19 的原样透传 ——
//  所以响应头在「第一片已经拿到手」之后才发出去（见 seekResponse）。

const SEEK_CHUNK_DEF   = 4;              // MB，对齐粒度
const SEEK_BURST_DEF   = 16;             // MB，拖动后并行预读多少
const SEEK_WINDOW_DEF  = 3;              // 并发窗口
const CHUNK_CACHE      = 'https://cache.internal/chunk-v1/';
const CHUNK_TTL        = 7 * 86400;      // 分片是内容寻址的，可以放心存久一点

const seekChunk  = env => envInt(env.SEEK_CHUNK_MB, SEEK_CHUNK_DEF, 1, 16) * 1048576;
const seekBurst  = env => envInt(env.SEEK_BURST_MB, SEEK_BURST_DEF, 0, 256) * 1048576;
// 首片最多 2 路（含对冲）+ 后台最多 3 路 = 5，给 Workers 的 6 路等待响应头
// 限制留一格安全余量。即便旧配置写了 4~6，v22 也会安全钳制为 3。
const seekWindow = env => envInt(env.SEEK_WINDOW, SEEK_WINDOW_DEF, 1, 3);

/**
 * Range 解析。返回 { start, end } / 'unsatisfiable' / null（无 Range）/ 'bad'。
 * 'bad' 是刻意留的逃生口：任何我们没把握的写法都退回 v19 原样透传，
 * 宁可不优化，不可解错一个字节。
 */
function parseRange(header, size) {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m) return 'bad';
  const a = m[1], b = m[2];
  let start, end;
  if (a === '') {
    // bytes=-N：末尾 N 字节
    const n = parseInt(b, 10);
    if (!Number.isFinite(n) || n <= 0) return 'bad';
    if (size <= 0) return 'unsatisfiable';
    start = Math.max(0, size - n);
    end = size - 1;
  } else {
    start = parseInt(a, 10);
    if (!Number.isFinite(start) || start < 0) return 'bad';
    if (start >= size) return 'unsatisfiable';
    end = b === '' ? size - 1 : parseInt(b, 10);
    if (!Number.isFinite(end)) return 'bad';
    end = Math.min(end, size - 1);
    if (end < start) return 'unsatisfiable';
  }
  return { start, end };
}

/**
 * 把 [start,end] 切成分片。落在 4MB 对齐边界上的整片带 idx（可缓存），
 * 头尾那两块残片 idx = -1（只取不存 —— 存了也没人会用同样的偏移再要一次）。
 */
function planSlices(start, end, size, chunk) {
  const out = [];
  let p = start;
  while (p <= end) {
    const bound = (Math.floor(p / chunk) + 1) * chunk;   // 下一个对齐边界
    const e = Math.min(end, bound - 1);
    const full = Math.min(bound, size) - 1;              // 这一片作为「整片」时的末字节
    out.push({
      start: p, end: e,
      idx: (p % chunk === 0 && e === full) ? Math.floor(p / chunk) : -1,
    });
    p = e + 1;
  }
  return out;
}

/**
 * 精确取一段字节，攒成一个完整 buffer。
 *
 * ⚠️ v21：这里以前是「一次 fetch + arrayBuffer()，长度对不上就整片重来」。
 *    在一条每隔几百 KB 就断一次的线路上，那个写法对 4MB 的分片是必然失败的 ——
 *    每次重来都从头开始，永远跑不完一整片，最后整条流报错。
 *    现在同样走可续传读取器：断在哪续在哪，只补没拿到的那部分。
 */
async function fetchExact(open, start, end, rOpt) {
  const want = end - start + 1;
  const rd = resumableReader({ ...rOpt, start, end, open, label: 'chunk' });
  const buf = new Uint8Array(want);
  let off = 0;
  let complete = false;
  try {
    for (;;) {
      const r = await rd.read();
      if (r.done) break;
      if (off + r.value.length > want) throw new Error('chunk overrun');
      buf.set(r.value, off);
      off += r.value.length;
    }
    if (off !== want) throw new Error(`chunk short ${off}/${want}`);
    complete = true;
    return buf;
  } finally {
    if (!complete) await rd.cancel('chunk failed').catch(() => {});
  }
}

const chunkKey = (tag, idx) => new Request(`${CHUNK_CACHE}${tag}/${idx}`);

/** 对齐整片：先问边缘缓存，miss 才回源，回源后异步写回 */
async function getChunk(open, slice, tag, rOpt, ctx) {
  const want = slice.end - slice.start + 1;
  const key = chunkKey(tag, slice.idx);
  try {
    const hit = await caches.default.match(key);
    if (hit) {
      const buf = new Uint8Array(await hit.arrayBuffer());
      if (buf.length === want) return buf;               // 长度对不上 = 脏数据，当没命中
    }
  } catch {}
  const buf = await fetchExact(open, slice.start, slice.end, rOpt);
  if (ctx && ctx.waitUntil) {
    ctx.waitUntil(caches.default.put(key, new Response(buf, {
      headers: {
        'Content-Type': 'application/octet-stream',
        'Cache-Control': `public, max-age=${CHUNK_TTL}`,
      },
    })).catch(() => {}));
  }
  return buf;
}

/**
 * seek 主路径。返回 Response；返回 null 或抛错 = 调用方回落 v19 直通。
 *
 * 结构就三段：
 *   突发段  [start, start+burst)   → 分片、并发、按序拼接（命中缓存则零回源）
 *   接力段  [start+burst, end]     → 一条普通连接直通到底
 *   安全带  响应头发出前先把第一片拿到手
 */
async function seekResponse(rr, cx) {
  const { filePath, fileSize, contentType, etag, env, ctx, t } = cx;
  const aborter = new AbortController();
  const requestSignal = cx.signal;
  const forwardAbort = () => aborter.abort(requestSignal.reason);
  if (requestSignal?.aborted) forwardAbort();
  else if (requestSignal) requestSignal.addEventListener('abort', forwardAbort, { once: true });

  // 共享引用：中途换了临时链接，本次请求里其它分片也跟着用新的；identity
  // 用来阻止播放过程中同路径替换文件后发生新旧字节拼接。
  const meta = cx.linkData.metadata;
  const linkRef = {
    link: cx.linkData.link,
    metadata: meta,
    identity: meta.content_hash || meta.rev || String(meta.size || ''),
    size: fileSize,
  };
  const budget = cx.budget || makeStreamBudget(env);
  const fastOpen = upstreamOpener(filePath, linkRef, env, ctx, {
    budget, signal: aborter.signal, hedge: true, label: 'seek-priority',
  });
  // v22：后台片不对冲。首片 1+1 对冲、后台最多 3 路，最坏仍只有 5 个
  // 等响应头的连接，留在 Workers 每次调用 6 个连接的硬限制以内。
  const chunkOpen = upstreamOpener(filePath, linkRef, env, ctx, {
    budget, signal: aborter.signal, hedge: false, label: 'seek-background',
  });
  const rOpt = {
    stallMs: stallMs(env), maxResume: resumeMax(env), maxOpen: openMax(env),
    signal: aborter.signal,
  };

  const chunk = seekChunk(env);
  const total = rr.end - rr.start + 1;
  const burst = Math.min(total, Math.max(chunk, seekBurst(env)));
  const slices = planSlices(rr.start, rr.start + burst - 1, fileSize, chunk);
  const useCache = env.SEEK_CHUNK_CACHE !== '0';
  const win = seekWindow(env);
  // 内容寻址：同路径换了文件，content_hash 变 → 键自动换代，不会串味
  const tag = encodeURIComponent(String(etag).replace(/"/g, '')).slice(0, 128);

  // ⚠️ 这一行是整节最容易写错、也最要紧的一个判断。
  //
  //   分片是「攒满一片再吐」的，所以一旦把第一片也拿去缓冲，首字节就要等
  //   一整片下完 —— 4MB 在 3MB/s 的连接上就是 1.3 秒。而 v19 的直通是
  //   上游一吐字节我们就转发，首字节只等一个 TTFB。那等于为了总吞吐把
  //   「拖完到出画面」这段亲手拖慢了，方向反了。
  //
  //   所以：第一片直通（首字节延迟与 v19 一模一样），后面几片在背景里
  //   并行下完。这样每个时刻手上的字节都 ≥ v19 —— 严格更优，不存在
  //   「某些情况下反而更慢」的角落。
  //
  //   例外是单片请求（元数据探路的那些小 Range）：它没有"后面几片"，
  //   缓冲下来写进边缘缓存才是对的，下次几毫秒就能返回。这类请求本来就小，
  //   缓冲不产生可感知的延迟。
  const streamHead = slices.length > 1;

  const inflight = new Map();
  let headReader = null, tailReader = null, stopped = false;
  const stop = async reason => {
    if (stopped) return;
    stopped = true;
    if (!aborter.signal.aborted) aborter.abort(reason);
    if (requestSignal) requestSignal.removeEventListener('abort', forwardAbort);
    const closing = [];
    if (headReader) closing.push(headReader.cancel(reason));
    if (tailReader) closing.push(tailReader.cancel(reason));
    if (closing.length) await Promise.allSettled(closing);
  };

  const launch = (i) => {
    if (i >= slices.length || inflight.has(i)) return;
    const sl = slices[i];
    // 单片元数据探路没有后台并发，仍允许对冲；多片请求只有直通首片可对冲。
    const opener = (!streamHead && i === 0) ? fastOpen : chunkOpen;
    const p = (useCache && sl.idx >= 0)
      ? getChunk(opener, sl, tag, rOpt, ctx)
      : fetchExact(opener, sl.start, sl.end, rOpt);
    p.catch(() => {});                 // 前面的片先失败时，这些不会变成未处理拒绝
    inflight.set(i, p);
  };

  // 安全带：响应头在「第一片已确认可取」之后才发出去 ——
  // 直通片是拿到 206 响应头，缓冲片是整片到手。都不额外增加等待
  //（本来就要等这一下），换来的是分片路径出问题可以静默回落 v19 直通。
  let headLeft = 0;
  let next = streamHead ? 1 : 0;

  try {
    if (streamHead) {
      for (let i = 1; i <= win; i++) launch(i);
      const sl = slices[0];
      // 第一次连接不经过 resumableReader：它同时是「安全带」——
      // 这一下失败要能抛出去让 handleStream 回落直通。失败时 stop() 会
      // 立即取消已启动的后台片，旧实现正是在这里留下了失控的重复请求。
      const first = await fastOpen(sl.start, sl.end);
      headReader = resumableReader({
        ...rOpt, start: sl.start, end: sl.end, reader: first, label: 'head',
      });
      headLeft = sl.end - sl.start + 1;
    } else {
      for (let i = 0; i < win; i++) launch(i);
      await inflight.get(0);
    }
  } catch (e) {
    await stop(e);
    throw e;
  }
  t.mark('first');

  const tailStart = rr.start + burst;
  const tailEnd = rr.end;
  // 接力段全程交给可续传读取器：临时链接到期、上游抖动、暂停十分钟后
  // 连接被回收 —— 一律断点续上，绝不吐一个短 body 出去。
  tailReader = tailStart <= tailEnd
    ? resumableReader({ ...rOpt, open: fastOpen, start: tailStart, end: tailEnd, label: 'tail' })
    : null;

  const body = new ReadableStream({
    // ⚠️ 这个 pull 的每一条出路都必须以 enqueue / close / error 收尾。
    //    规范只在「本次 pull 结束且队列仍有空位」时才可能再叫一次，而"再叫"
    //    的触发点是 enqueue 或新的 read —— 若某条分支既不入队也不关闭就 return，
    //    读端会永久挂住（表现为拖完之后画面再也不动）。所以段与段之间用贯穿，
    //    不用 return。
    async pull(c) {
      try {
        // ① 直通的第一片：来多少转多少，首字节延迟与 v19 直通一致
        if (headReader) {
          const r = await headReader.read();
          if (!r.done) {
            headLeft -= r.value.length;
            if (headLeft < 0) throw new Error('head overrun');
            c.enqueue(r.value);
            return;
          }
          headReader = null;
          // 上游提前断流 → 与 Content-Length 承诺的字节数对不上。与其让播放器
          // 拿到一段「短了几 MB 的完整响应」，不如报错让它重试这一段。
          if (headLeft !== 0) throw new Error(`head short by ${headLeft}`);
          // 这里刻意不 return：见上面那段说明，贯穿到 ②
        }
        // ② 并行预读好的后续分片，按序拼上
        if (next < slices.length) {
          const buf = await inflight.get(next);
          inflight.delete(next);
          launch(next + win);          // 补窗口：始终保持 win 片在飞
          next++;
          c.enqueue(buf);
          return;
        }
        // ③ 接力段：剩下的部分回到一条普通连接，断了就地续上
        if (!tailReader) {
          await stop('complete');
          return c.close();
        }
        const r = await tailReader.read();
        if (r.done) {
          tailReader = null;
          await stop('complete');
          return c.close();
        }
        c.enqueue(r.value);
      } catch (e) {
        await stop(e);
        c.error(e);                    // 已经开始传输了，只能让播放器自己重试这一段
      }
    },
    async cancel(reason) {
      // 播放器又拖了一次 → 本次响应作废。v22 会真正 abort 全部在飞分片与
      // backoff；不再让旧 seek「自然结束」后继续抢新 seek 的带宽与子请求。
      await stop(reason || 'client seek/cancel');
    },
  });

  const h = buildStreamHeaders(contentType, etag, cx.linkData.metadata.name, t);
  h.set('Content-Range', `bytes ${rr.start}-${rr.end}/${fileSize}`);
  h.set('Content-Length', String(total));
  h.set('X-Stream-Mode', cx.safariPatch ? 'seek-burst-safari' : 'seek-burst');
  const outBody = cx.safariPatch ? wrapSafariMp4PatchStream(body) : body;
  return new Response(outBody, { status: 206, headers: h });
}

const STREAM_HEDGE_MS = 400;

function hedgeDelay(env) {
  const v = parseInt(env.STREAM_HEDGE_MS || '', 10);
  return Number.isFinite(v) && v >= 0 ? v : STREAM_HEDGE_MS;
}

/**
 * 上游对冲（hedged request）—— 起播长尾的正解，不是重试。
 *
 * 重试是「等它失败再来一发」；对冲是「它慢过阈值就再来一发，谁先回响应头用谁，
 * 落败那路连 body 一起 abort」。Dropbox 的 temp link 落在一组
 * uc*.dl.dropboxusercontent.com 实例上，偶尔摊到一个响应头要三五秒的 ——
 * 起播「卡一下」绝大多数就是这一下，而重试对它无能为力（它并没有失败）。
 *
 * ⚠️ 严格沿用 v18 的不变量：对冲只可能发生在【响应头到达之前】。
 *    · 赢家：一旦拿到响应头，所有定时器解除，body 传输不受任何超时/abort 约束
 *      —— 多大的文件、seek 到哪都能续播，与裸 fetch 完全一致
 *    · 落败：body 从未被读，abort 掉既不占带宽也不计费
 * 所以它不会重新引入「body 被打断 → 播放截断」那类问题。
 *
 * 成本也不会放大：只有慢于 STREAM_HEDGE_MS 才多发一发，且最多两路。
 * 首发直接网络错误时不等阈值，立刻补发 —— 那种情况干等 400ms 毫无意义。
 */
function fetchStreamHedged(link, opts, env, timeout = 20_000, control = {}) {
  const delay = hedgeDelay(env);
  if (delay <= 0 || control.hedge === false) {
    return fetchStreamHead(link, opts, timeout, control);        // 显式关闭 / 后台片 → 单路
  }

  const { signal: parentSignal, ...fetchOpts } = opts || {};
  if (parentSignal?.aborted) return Promise.reject(streamAbortError(parentSignal.reason));

  return new Promise((resolve, reject) => {
    const ctrls = [];
    let done = false, launched = 0, settled = 0, launchBlocked = false;
    let lastErr = null, candidate = null, hedgeT = null, errorT = null, guardT = null;

    const onParentAbort = () => settleErr(streamAbortError(parentSignal.reason));

    const cleanup = (keep) => {
      if (guardT) clearTimeout(guardT);
      if (hedgeT) clearTimeout(hedgeT);
      if (errorT) clearTimeout(errorT);
      if (parentSignal) parentSignal.removeEventListener('abort', onParentAbort);
      for (const c of ctrls) if (c !== keep) { try { c.abort(); } catch {} }
    };
    const settleResponse = (res, ctrl) => {
      if (done) return;
      done = true;
      cleanup(ctrl);
      resolve(res);
    };
    const settleErr = (e) => {
      if (done) return;
      done = true;
      cleanup(null);
      reject(e);
    };

    const maybeFinish = () => {
      if (done || settled < launched) return;
      if (launched < 2 && !launchBlocked) return;  // 第二路还可能由 hedge timer 启动
      if (candidate) return settleResponse(candidate.res, candidate.ctrl);
      settleErr(lastErr || new Error('upstream unavailable'));
    };

    const launch = () => {
      if (done || launched >= 2) return;
      try {
        if (control.budget) control.budget.take(control.label || 'stream-hedge');
      } catch (e) {
        launchBlocked = true;
        lastErr = e;
        maybeFinish();
        return;
      }
      launched++;
      const ctrl = new AbortController();
      ctrls.push(ctrl);
      fetch(link, { ...fetchOpts, signal: ctrl.signal }).then(
        res => {
          if (done) {
            try { if (res.body) res.body.cancel(); } catch {}
            return;
          }
          // v21 谁先回响应头就用谁，导致一条快速 429/5xx 会误杀另一条可能成功的
          // 对冲。v22 对临时错误留一个短窗口；206/200 与确定性 4xx 仍立即返回。
          if (!isRetryableStreamStatus(res.status)) return settleResponse(res, ctrl);
          settled++;
          if (!candidate) {
            candidate = { res, ctrl };
            const grace = Math.min(2500, Math.max(750, delay * 3));
            errorT = setTimeout(() => settleResponse(candidate.res, candidate.ctrl), grace);
          } else {
            try { if (res.body) res.body.cancel(); } catch {}
          }
          if (launched < 2) launch();                 // 快速限流/5xx → 立即补第二路
          maybeFinish();
        },
        err => {
          if (done) return;                     // 落败方被我们 abort，属正常，不算失败
          settled++;
          lastErr = err;
          if (parentSignal?.aborted) return settleErr(streamAbortError(parentSignal.reason));
          if (launched < 2) launch();            // 首发就挂 → 立刻补一发，不等阈值
          maybeFinish();
        },
      );
    };

    // 只给「拿响应头」设的总闸；赢家一到就在 cleanup 里解除
    guardT = setTimeout(() => {
      if (candidate) settleResponse(candidate.res, candidate.ctrl);
      else settleErr(new Error('upstream header timeout'));
    }, timeout);
    if (parentSignal) parentSignal.addEventListener('abort', onParentAbort, { once: true });
    if (parentSignal?.aborted) onParentAbort();
    if (!done) launch();
    if (!done) hedgeT = setTimeout(launch, delay);
  });
}

/**
 * 起播预热：默认只把 Dropbox API 的那次往返从关键路径上摘掉。
 *
 * v22 还会立刻向上游要 bytes=0-0。页面刚返回时，这个请求会和播放器真正
 * 的 bytes=0- 同时抵达 Dropbox；在受限或抖动线路上，它不但没有复用到连接，
 * 反而参与限流并抢首片。v23 默认不再发这条竞争请求。确实想用旧式 TLS 预热
 * 时可显式设置 STREAM_PREWARM_RANGE=1。
 */
async function prewarmStream(filePath, env, ctx) {
  const link = await getTempLink(filePath, env, ctx);
  if (env.STREAM_PREWARM_RANGE !== '1') return;
  const res = await fetchStreamHead(link.link, {
    headers: { Range: 'bytes=0-0', 'Accept-Encoding': 'identity' },
  }, 8_000);
  try { if (res.body) await res.body.cancel(); } catch {}
}

function streamFailure(t, message, status = 503, retryAfter = 2) {
  return jsonResponse({ error: message }, status, {
    ...CORS_HEADERS,
    'Cache-Control': 'no-store',
    'Retry-After': String(Math.max(0, retryAfter)),
    'Server-Timing': t.header(),
  });
}

async function handleStream(url, request, env, ctx) {
  const t = timer();
  const filePath = url.searchParams.get('path');
  if (!filePath) return new Response('Missing path', { status: 400, headers: CORS_HEADERS });

  // 1. 临时链接（缓存 + 合并）
  let linkData;
  try {
    linkData = await getTempLink(filePath, env, ctx);
  } catch {
    return streamFailure(t, 'Unable to obtain Dropbox download link', 503, 2);
  }
  if (!linkData?.link || !linkData.metadata || !Number.isFinite(linkData.metadata.size)
      || linkData.metadata.size <= 0 || !linkData.metadata.name) {
    return streamFailure(t, 'Invalid Dropbox file metadata', 502, 1);
  }
  t.mark('link');

  const fileSize = linkData.metadata.size;
  const ext = getExt(linkData.metadata.name);
  const contentType = MIME_MAP[ext] || 'application/octet-stream';
  // v24：当带 ?safari=1 且为 MP4/MOV/M4V 容器时，启用流式 hev1->hvc1 / dvhe->dvh1 热修补
  const safariPatch = url.searchParams.get('safari') === '1' &&
    (ext === '.mp4' || ext === '.m4v' || ext === '.mov');
  const etag = `"${linkData.metadata.content_hash || linkData.metadata.rev || fileSize}"`;
  const identity = linkData.metadata.content_hash || linkData.metadata.rev || String(fileSize);

  // ETag 304（修复：补 CORS 头。304 不带 CORS 时，跨域播放器的条件请求
  // 会被浏览器判为 CORS 失败，而不是「缓存仍有效」）
  if (request.headers.get('If-None-Match') === etag) {
    return new Response(null, {
      status: 304,
      headers: { ...CORS_HEADERS, ETag: etag, 'Server-Timing': t.header() },
    });
  }

  // HEAD 快速路径：size / ETag / Content-Type 全在缓存的 metadata 里，无需回源。
  // HEAD 的响应头应与同一个 GET 一致。部分播放器会先发 HEAD + Range 探测；
  // 旧版无条件回 200/full length，会让它误判服务器不支持 Range，首次加载直接失败。
  if (request.method === 'HEAD') {
    let headRange = request.headers.get('Range');
    const headIfRange = request.headers.get('If-Range');
    if (headIfRange && headRange && headIfRange !== etag) headRange = null;
    if (headRange && headRange.includes(',')) headRange = headRange.split(',')[0].trim();
    const headRr = parseRange(headRange, fileSize);
    if (headRr === 'unsatisfiable') {
      return new Response(null, {
        status: 416,
        headers: {
          ...CORS_HEADERS,
          'Content-Range': `bytes */${fileSize}`,
          ETag: etag,
          'Server-Timing': t.header(),
          'X-Stream-Mode': 'head-range-error',
        },
      });
    }
    const h = buildStreamHeaders(contentType, etag, linkData.metadata.name, t);
    if (headRr && headRr !== 'bad') {
      h.set('Content-Range', `bytes ${headRr.start}-${headRr.end}/${fileSize}`);
      h.set('Content-Length', String(headRr.end - headRr.start + 1));
      h.set('X-Stream-Mode', 'head-range');
      return new Response(null, { status: 206, headers: h });
    }
    h.set('Content-Length', String(fileSize));
    h.set('X-Stream-Mode', 'head-full');
    return new Response(null, { status: 200, headers: h });
  }

  // GET 的所有首发、对冲、分片与断点重连共用一个预算。不能放进每个 reader，
  // 否则四个并发分片会把单次请求预算乘四。
  const budget = makeStreamBudget(env);

  // 2. Range 规整后透传（不截断字节、不改写偏移）
  let rangeHeader = request.headers.get('Range');

  // If-Range：客户端持有的验证器与当前 ETag 不符（文件已被同路径替换）
  // → 按 RFC 9110 §13.1.5 忽略 Range 回 200 全量。此前直接透传会把
  // 「新文件的 206 片段」拼进旧文件的缓冲区，花屏或解码错误。
  // 日期形式的 If-Range 我们无 Last-Modified 可比 → 同样按不匹配处理（安全侧）。
  const ifRange = request.headers.get('If-Range');
  if (ifRange && rangeHeader && ifRange !== etag) rangeHeader = null;

  // 多段 Range（bytes=0-1,5-10）防御：Dropbox 可能回 multipart/byteranges，
  // 与我们强制覆写的单一视频 Content-Type 冲突 → 只取第一段。
  // 视频播放器实际只发单段，多段多见于探测工具。
  if (rangeHeader && rangeHeader.includes(',')) {
    rangeHeader = rangeHeader.split(',')[0].trim();
  }

  // Accept-Encoding: identity —— mkv/mp4 本就是压缩容器，让上游再协商一次 gzip
  // 只白烧两边 CPU；更要紧的是压缩响应会让 Content-Length 与字节区间不再一一
  // 对应，Range 语义变脏。视频代理一律走裸字节。
  const upstreamHeaders = { 'Accept-Encoding': 'identity' };
  if (rangeHeader) upstreamHeaders['Range'] = rangeHeader;

  // ── v20 快速定位路径 ────────────────────────────────────
  // 越界的 Range 在本地就回 416，不再为一个必然失败的请求先跑一趟 Dropbox。
  const rr = parseRange(rangeHeader, fileSize);
  if (rr === 'unsatisfiable') {
    return new Response(null, {
      status: 416,
      headers: { ...CORS_HEADERS, 'Content-Range': `bytes */${fileSize}`, 'Server-Timing': t.header() },
    });
  }
  // rr === 'bad'（多段 / 畸形）或关掉了突发 → 直接走下面的 v19 直通。
  // v23：bytes=0- 是首次起播，不是拖动。并行突发只服务 start > 0 的真实 seek；
  // 首播保留单链路流式转发与慢响应对冲，避免还没出画面就同时放大 4~5 个 Range。
  // 需要复现旧行为时可显式设置 SEEK_BURST_AT_START=1。
  let seekError = null;
  const isSeek = rr && rr !== 'bad' && (rr.start > 0 || env.SEEK_BURST_AT_START === '1');
  if (isSeek && seekBurst(env) > 0) {
    try {
      const fast = await seekResponse(rr, {
        filePath, linkData, fileSize, contentType, etag, env, ctx, t,
        budget, signal: request.signal, safariPatch,
      });
      if (fast) return fast;
    } catch (e) {
      seekError = e;
      // 分片路径在「第一片到手」之前失败 → 静默回落直通。
      // 优化只可能更快，不可能把原本能播的搞成不能播。
      console.error('seek fallback:', e && e.message);
      if (e?.name === 'AbortError') return streamFailure(t, 'Request cancelled', 499, 0);
      // 429/5xx 后立刻再打两路只会加重限流；先尊重 Retry-After，再用单路回落。
      if (e?.retryable) {
        try { await streamDelay(Math.min(2000, e.retryAfterMs || 500), request.signal); }
        catch { return streamFailure(t, 'Request cancelled', 499, 0); }
      }
    }
  }

  // ⚠️ 流式请求不用 fetchRetry（它的超时会一直武装到 body 传输期间 → 截断播放）。
  // 改用 fetchStreamHead：只给「拿响应头」设超时，头一到即解除，body 永不被 abort。
  // 相比裸 fetch，多了「Dropbox 连接卡在响应头前」时的快速失败，不再干等 6min。
  // v19：换成对冲。慢于 STREAM_HEDGE_MS 就并发补一发，谁先回响应头用谁。
  // 「失败后重试一次」的语义被它完全覆盖（首发挂了会立刻补发），
  // 所以这里只保留一层兜底 catch。
  let upstream;
  try {
    upstream = await fetchStreamHedged(
      linkData.link,
      { headers: upstreamHeaders, signal: request.signal },
      env,
      20_000,
      { budget, hedge: !seekError?.retryable, label: 'passthru-start' },
    );
  } catch (e) {
    return streamFailure(t, e?.name === 'AbortError' ? 'Request cancelled' : 'Upstream unreachable',
      e?.name === 'AbortError' ? 499 : 503, e?.name === 'AbortError' ? 0 : 2);
  }

  // 3. 自愈：链接过期 → 同步逐出缓存 → 重取链接 → 重试
  if (upstream.status === 403 || upstream.status === 410) {
    try { upstream.body && await upstream.body.cancel(); } catch {} // 释放旧连接
    // 同步删除缓存（不用 waitUntil），确保 getTempLink 不会命中旧缓存
    const ck = new Request(`${LINK_CACHE}?p=${encodeURIComponent(filePath)}`);
    await caches.default.delete(ck);
    // 清除 singleFlight 中可能残留的 key（防止拿到旧 promise）
    _inflight.delete(`link:${filePath}`);
    linkData = await getTempLink(filePath, env, ctx);
    const freshIdentity = linkData.metadata.content_hash || linkData.metadata.rev || String(linkData.metadata.size);
    if (freshIdentity !== identity || linkData.metadata.size !== fileSize) {
      return streamFailure(t, 'File changed during playback; retry with fresh metadata', 409, 0);
    }
    try {
      upstream = await fetchStreamHedged(
        linkData.link,
        { headers: upstreamHeaders, signal: request.signal },
        env,
        20_000,
        { budget, hedge: true, label: 'passthru-heal' },
      );
    } catch (e) {
      return streamFailure(t, e?.name === 'AbortError' ? 'Request cancelled' : 'Upstream unreachable',
        e?.name === 'AbortError' ? 499 : 503, e?.name === 'AbortError' ? 0 : 2);
    }
    t.mark('heal');
  }
  t.mark('upstream');

  // 修复：上游最终仍是错误状态（自愈后依旧 403/410、或 416/5xx）→ 显式回错。
  // 此前会落进最后的 fallback：设 Content-Length: fileSize 再透传，客户端拿到
  // 一个「声称有完整文件长度、body 却是错误页」的响应，播放器直接挂起。
  if (upstream.status !== 200 && upstream.status !== 206) {
    const upstreamStatus = upstream.status;
    try { upstream.body && await upstream.body.cancel(); } catch {}
    if (upstreamStatus === 416) {
      // Range 不可满足按规范回 416 + Content-Range: bytes */size，播放器可自行回退重试
      return new Response(null, {
        status: 416,
        headers: {
          ...CORS_HEADERS,
          'Content-Range': `bytes */${fileSize}`,
          'Server-Timing': t.header(),
        },
      });
    }
    const retryable = isRetryableStreamStatus(upstreamStatus);
    return streamFailure(t, `Upstream error (${upstreamStatus})`, retryable ? 503 : 502, retryable ? 2 : 1);
  }

  // 4. 构造响应头：透传上游 + CORS（直接设置，不经过 cors() 二次包装）
  const h = buildStreamHeaders(contentType, etag, linkData.metadata.name, t);

  // 透传上游的关键头
  const upCR = upstream.headers.get('Content-Range');
  const upCL = upstream.headers.get('Content-Length');

  // v21：直通路径同样接上可续传。这条路以前是 `new Response(upstream.body)`
  // 裸管道 —— 上游中途一断，body 就短了，而 Content-Length 已经发出去了，
  // 播放器只能永远等剩下的字节。那正是「播一会儿就无限转圈」的现场。
  const linkRef = {
    link: linkData.link, metadata: linkData.metadata, identity, size: fileSize,
  };
  const open = upstreamOpener(filePath, linkRef, env, ctx, {
    budget, signal: request.signal, hedge: true, label: 'passthru-resume',
  });
  const rOpt = {
    open, stallMs: stallMs(env), maxResume: resumeMax(env), maxOpen: openMax(env),
    signal: request.signal,
  };

  if (upstream.status === 206 && upCR) {
    const seg = parseContentRange(upCR);
    if (!seg || !upstream.body || (seg.size != null && seg.size !== fileSize)) {
      try { upstream.body && await upstream.body.cancel(); } catch {}
      return streamFailure(t, 'Invalid upstream byte range', 502, 1);
    }
    if (rr && rr !== 'bad' && (seg.start !== rr.start || seg.end !== rr.end)) {
      try { await upstream.body.cancel(); } catch {}
      return streamFailure(t, 'Upstream returned a mismatched byte range', 502, 1);
    }
    const expected = seg.end - seg.start + 1;
    if (upCL && Number(upCL) !== expected) {
      console.error(`stream length corrected: upstream=${upCL}, range=${expected}`);
    }
    h.set('Content-Range', `bytes ${seg.start}-${seg.end}/${fileSize}`);
    h.set('Content-Length', String(expected));
    h.set('X-Stream-Mode', seg.start === 0 ? 'start-direct' : 'range-direct');
    const rawOut = resumableStream({ ...rOpt, start: seg.start, end: seg.end,
      reader: upstream.body.getReader(), label: 'passthru-206' });
    return new Response(safariPatch ? wrapSafariMp4PatchStream(rawOut) : rawOut, { status: 206, headers: h });
  }

  // 无 Range 或上游返回 200 → 完整文件
  const clen = parseInt(upCL || '', 10);
  if (!upstream.body || (Number.isFinite(clen) && clen > 0 && clen !== fileSize)) {
    try { upstream.body && await upstream.body.cancel(); } catch {}
    return streamFailure(t, 'Upstream file length changed', 409, 0);
  }
  const total = fileSize;
  h.set('Content-Length', String(total));
  h.set('X-Stream-Mode', 'full-direct');
  const rawOut = (upstream.status === 200 && total > 0)
    ? resumableStream({ ...rOpt, start: 0, end: total - 1,
                        reader: upstream.body.getReader(), label: 'passthru-200' })
    : upstream.body;
  return new Response(safariPatch ? wrapSafariMp4PatchStream(rawOut) : rawOut, { status: upstream.status, headers: h });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  v25：MKV → HLS（fMP4）实时重封装 —— iOS / Safari 原生播放链路
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  iPhone 上能稳定点亮杜比视界 / HDR、能用画中画与 AirPlay 的只有原生 HLS。
//  所以 MKV 不再交给浏览器解，而是在 Worker 里实时换成 fMP4 分片：
//
//    索引   读文件头 + Cues + 首簇（三四个小 Range），得到轨道、关键帧表、
//           各音轨的 dac3 / dec3 / esds 等配置。按 content_hash 缓存，换文件自动换代。
//    分片   以视频关键帧为界按字节区间切。一个分片只回源它自己那段字节，
//           EBML 流式解析 → moof + mdat。视频负载零拷贝：只引用、不复制。
//    音频   默认音轨与视频复用在同一分片里（Dropbox 只读一遍）；其余音轨是
//           HLS 备选音轨，用户切换时才去读。
//    字幕   内封 SRT / ASS 靠 Cues 精确定位，只读字幕块本身；同目录外挂字幕
//           一起挂进 HLS 字幕组。全部是带 X-TIMESTAMP-MAP 的 WebVTT。
//    杜比   P5 → dvh1；P8.x → hvc1 + dvvC + SUPPLEMENTAL-CODECS；
//           P7（UHD 蓝光双层）→ 逐帧丢弃增强层、把 RPU 改写为 8.1。
//
//  时间轴整体后移 HLS_T0 秒（Apple 分段器同样从 10s 起），B 帧的 DTS 因此
//  永远非负；字幕用同一个偏移写进 X-TIMESTAMP-MAP，三条轨严格对齐。

const HLS_VER = 1;                          // 输出格式变更时 +1：播放列表与缓存一起换代
const HLS_IDX_CACHE = 'https://cache.internal/hls-idx/';
const HLS_IDX_V = 2;                          // 索引结构变更时 +1（只换索引缓存，不动分段缓存）：v2 参数集重建 / Annex B
const HLS_SUB_CACHE = 'https://cache.internal/hls-sub/';
const HLS_T0 = 10;                          // 秒
const HLS_HEAD = 512 * 1024;                // 索引首读
const HLS_PROBE = 2 * 1048576;              // 首簇探测
const HLS_FIRST = 1048576;                  // 分片首段直通（压低首字节延迟）
const HLS_SLICE = 4 * 1048576;              // 其余字节按 4MB 并行回源
const HLS_WINDOW = 3;                       // 默认并行窗口：首段直通 1 条 + 切片 3 条（每次调用最多 6 条连接）
const HLS_FRAG_SEC = 1;                     // 一个 moof 覆盖约 1 秒
const HLS_FRAG_BYTES = 6 * 1048576;         // 或累计到 6MB（高码率时控制内存）
const hlsSegTarget = env => envInt(env.HLS_SEG_SEC, 6, 2, 10);
const hlsWindow = env => envInt(env.HLS_WINDOW, HLS_WINDOW, 1, 5);
const hlsPrefetchN = env => envInt(env.HLS_PREFETCH, 1, 0, 1);
const HLS_FLIGHT_MAX = 1;                   // 每个 isolate 同时只跑一路后台预取（4K 一段几十 MB，isolate 只有 128MB）
const HLS_FLIGHT_MS = 25000;                // 后台取段的时限（waitUntil 只给 30 秒）
const HLS_STALL_MS = 6000;                  // 等别人的那一遍：这么久没进度就当它停了，自己现取
const HLS_POLL_MS = 50;                     // 等缓存的轮询间隔（只读进度数字，不跨请求 await）
const HLS_SUB_WAIT_MS = 12000;              // 字幕分段最多等视频那一遍这么久
const HLS_SUB_GRACE_MS = 200;               // 字幕请求常比同一段的视频请求早到一点点
const HLS_CACHE_RETRY_MS = 600000;          // 缓存写了读不出：这个 isolate 里先停用预取 10 分钟

// ── 字节与编码小工具 ──

function hlsB64(u8) {
  let s = '';
  for (let i = 0; i < u8.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  }
  return btoa(s);
}
function hlsUnB64(s) {
  const b = atob(s);
  const u = new Uint8Array(b.length);
  for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i);
  return u;
}
function hlsB64url(str) {
  return hlsB64(new TextEncoder().encode(str)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function hlsUnB64url(s) {
  let t = String(s).replace(/-/g, '+').replace(/_/g, '/');
  while (t.length % 4) t += '=';
  return new TextDecoder().decode(hlsUnB64(t));
}
/* 一个分片（moof 头 + 一串帧切片）→ 交给响应流的块。原来整个分片先拼成一个大缓冲再交出去：
   4K 片源一段几十 MB，等于每个字节多拷一遍、峰值内存多一整个分片。现在 ≥ 16KB 的切片原样交出
   （网络块上的子视图；workerd 里把视图交给响应流不会摘走底下的缓冲，实测过），零碎的小切片
   （音频帧、moof、NAL 长度头）攒到 64KB 再拷成一块，块数不至于太碎。 */
const HLS_OUT_DIRECT = 16384, HLS_OUT_CHUNK = 65536;
function hlsChunks(parts) {
  const out = [];
  let run = [], runLen = 0;
  const flush = () => {
    if (!runLen) return;
    out.push(run.length === 1 ? run[0] : hlsConcat(run));
    run = []; runLen = 0;
  };
  for (const p of parts) {
    if (!p.length) continue;
    if (p.length >= HLS_OUT_DIRECT) { flush(); out.push(p); continue; }
    run.push(p); runLen += p.length;
    if (runLen >= HLS_OUT_CHUNK) flush();
  }
  flush();
  return out;
}

function hlsConcat(parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

// ── 位读写（MSB 优先；RPU / SPS / E-AC-3 头都靠它）──

class HlsBits {
  constructor(u8, startByte = 0, endByte = u8.length) {
    this.b = u8; this.p = startByte * 8; this.end = endByte * 8;
  }
  get left() { return this.end - this.p; }
  get aligned() { return (this.p & 7) === 0; }
  u(n) {                                     // n ≤ 32，返回非负整数
    if (this.p + n > this.end) throw new Error('bitstream overrun');
    let v = 0;
    for (let i = 0; i < n; i++) {
      v = v * 2 + ((this.b[this.p >> 3] >> (7 - (this.p & 7))) & 1);
      this.p++;
    }
    return v;
  }
  skip(n) {
    if (this.p + n > this.end) throw new Error('bitstream overrun');
    this.p += n;
  }
  ue() {
    let z = 0;
    while (this.u(1) === 0) { if (++z > 31) throw new Error('bad exp-golomb'); }
    return z ? (2 ** z - 1) + this.u(z) : 0;
  }
  se() {
    const k = this.ue();
    return k & 1 ? (k + 1) / 2 : -(k / 2);
  }
}

class HlsBitWriter {
  constructor() { this.bytes = []; this.cur = 0; this.n = 0; }
  bit(b) {
    this.cur = (this.cur << 1) | (b & 1);
    if (++this.n === 8) { this.bytes.push(this.cur); this.cur = 0; this.n = 0; }
  }
  u(n, v) {                                  // v 为非负整数（有符号字段先自行转补码）
    for (let i = n - 1; i >= 0; i--) this.bit(Math.floor(v / 2 ** i) % 2);
  }
  ue(v) {
    const x = v + 1;
    let len = 0;
    while (2 ** (len + 1) <= x) len++;
    this.u(len, 0);
    this.u(len + 1, x);
  }
  se(v) { this.ue(v <= 0 ? -2 * v : 2 * v - 1); }
  get aligned() { return this.n === 0; }
  align() { while (this.n) this.bit(0); }
  out() { return Uint8Array.from(this.bytes); }
}

// CRC-32/MPEG-2（RPU 末尾校验和用的就是它）
const HLS_CRC_TAB = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i << 24;
    for (let k = 0; k < 8; k++) c = (c & 0x80000000) ? ((c << 1) ^ 0x04C11DB7) : (c << 1);
    t[i] = c >>> 0;
  }
  return t;
})();
function hlsCrc32(u8, start = 0, end = u8.length) {
  let c = 0xFFFFFFFF;
  for (let i = start; i < end; i++) c = ((c << 8) ^ HLS_CRC_TAB[((c >>> 24) ^ u8[i]) & 0xFF]) >>> 0;
  return c >>> 0;
}

// NAL 防竞争字节（00 00 03）去除 / 插入
function nalUnescape(u8) {
  const out = new Uint8Array(u8.length);
  let n = 0, zeros = 0;
  for (let i = 0; i < u8.length; i++) {
    const b = u8[i];
    if (zeros >= 2 && b === 3) { zeros = 0; continue; }
    out[n++] = b;
    zeros = b === 0 ? zeros + 1 : 0;
  }
  return out.subarray(0, n);
}
function nalEscape(u8) {
  const out = [];
  let zeros = 0;
  for (let i = 0; i < u8.length; i++) {
    const b = u8[i];
    if (zeros >= 2 && b <= 3) { out.push(3); zeros = 0; }
    out.push(b);
    zeros = b === 0 ? zeros + 1 : 0;
  }
  return Uint8Array.from(out);
}

// ── EBML ──

const MKV = Object.freeze({
  EBML: 0x1A45DFA3, DocType: 0x4282, Segment: 0x18538067,
  SeekHead: 0x114D9B74, Seek: 0x4DBB, SeekID: 0x53AB, SeekPosition: 0x53AC,
  Info: 0x1549A966, TimestampScale: 0x2AD7B1, Duration: 0x4489,
  Tracks: 0x1654AE6B, TrackEntry: 0xAE, TrackNumber: 0xD7, TrackType: 0x83,
  FlagEnabled: 0xB9, FlagDefault: 0x88, FlagForced: 0x55AA, FlagHearingImpaired: 0x55AB,
  FlagCommentary: 0x55AF, FlagOriginal: 0x55AE,
  DefaultDuration: 0x23E383, Name: 0x536E, Language: 0x22B59C, LanguageBCP47: 0x22B59D,
  CodecID: 0x86, CodecPrivate: 0x63A2, CodecDelay: 0x56AA,
  Video: 0xE0, PixelWidth: 0xB0, PixelHeight: 0xBA, DisplayWidth: 0x54B0, DisplayHeight: 0x54BA,
  DisplayUnit: 0x54B2, Colour: 0x55B0, MatrixCoefficients: 0x55B1, Range: 0x55B9,
  TransferCharacteristics: 0x55BA, Primaries: 0x55BB, MaxCLL: 0x55BC, MaxFALL: 0x55BD,
  MasteringMetadata: 0x55D0, PrimaryRX: 0x55D1, PrimaryRY: 0x55D2, PrimaryGX: 0x55D3,
  PrimaryGY: 0x55D4, PrimaryBX: 0x55D5, PrimaryBY: 0x55D6, WhiteX: 0x55D7, WhiteY: 0x55D8,
  LumMax: 0x55D9, LumMin: 0x55DA,
  Audio: 0xE1, SamplingFrequency: 0xB5, OutputSamplingFrequency: 0x78B5, Channels: 0x9F, BitDepth: 0x6264,
  ContentEncodings: 0x6D80, ContentEncoding: 0x6240, ContentEncodingType: 0x5033,
  ContentCompression: 0x5034, ContentCompAlgo: 0x4254, ContentCompSettings: 0x4255,
  BlockAdditionMapping: 0x41E4, BlockAddIDType: 0x41E7, BlockAddIDExtraData: 0x41ED,
  Cues: 0x1C53BB6B, CuePoint: 0xBB, CueTime: 0xB3, CueTrackPositions: 0xB7, CueTrack: 0xF7,
  CueClusterPosition: 0xF1, CueRelativePosition: 0xF0, CueDuration: 0xB2,
  Cluster: 0x1F43B675, Timestamp: 0xE7, SimpleBlock: 0xA3, BlockGroup: 0xA0, Block: 0xA1,
  BlockDuration: 0x9B, ReferenceBlock: 0xFB,
  Tags: 0x1254C367, Chapters: 0x1043A770, Attachments: 0x1941A469, Void: 0xEC,
});
// 出现这些顶层元素 = 簇区结束
const MKV_TOP = new Set([MKV.Cues, MKV.Tags, MKV.Chapters, MKV.Attachments, MKV.SeekHead,
  MKV.Info, MKV.Tracks, MKV.EBML, MKV.Segment]);

/** EBML ID（保留长度标记位）：返回 [id, len]；字节不够返回 null */
function ebmlId(u8, p, end) {
  if (p >= end) return null;
  const b = u8[p];
  const len = b & 0x80 ? 1 : b & 0x40 ? 2 : b & 0x20 ? 3 : b & 0x10 ? 4 : 0;
  if (!len) throw new Error('invalid EBML id');
  if (p + len > end) return null;
  let v = 0;
  for (let i = 0; i < len; i++) v = v * 256 + u8[p + i];
  return [v, len];
}
/** EBML 尺寸：返回 [size, len]，未知尺寸 size = -1 */
function ebmlSize(u8, p, end) {
  if (p >= end) return null;
  const b = u8[p];
  let len = 1, mask = 0x80;
  while (len <= 8 && !(b & mask)) { mask >>= 1; len++; }
  if (len > 8) throw new Error('invalid EBML size');
  if (p + len > end) return null;
  let v = b & (mask - 1);
  let ones = v === mask - 1;
  for (let i = 1; i < len; i++) {
    const x = u8[p + i];
    v = v * 256 + x;
    if (x !== 0xFF) ones = false;
  }
  return [ones ? -1 : v, len];
}
function ebmlUint(u8, p, n) { let v = 0; for (let i = 0; i < n; i++) v = v * 256 + u8[p + i]; return v; }
function ebmlFloat(u8, p, n) {
  const dv = new DataView(u8.buffer, u8.byteOffset + p, n);
  return n === 4 ? dv.getFloat32(0) : n === 8 ? dv.getFloat64(0) : 0;
}
function ebmlStr(u8, p, n) { return new TextDecoder().decode(u8.subarray(p, p + n)).replace(/\0+$/, ''); }

/** 遍历缓冲区内的同级元素。末尾不完整的元素照样给出（end 被截断），由调用方判断 */
function* ebmlChildren(u8, start, end) {
  let p = start;
  while (p < end) {
    const id = ebmlId(u8, p, end);
    if (!id) return;
    const sz = ebmlSize(u8, p + id[1], end);
    if (!sz) return;
    const data = p + id[1] + sz[1];
    const size = sz[0] < 0 ? end - data : sz[0];
    yield { id: id[0], pos: p, data, size, end: data + size, cut: data + size > end };
    p = data + size;
  }
}
function ebmlMap(u8, start, end) {
  const m = new Map();
  for (const e of ebmlChildren(u8, start, end)) if (!m.has(e.id)) m.set(e.id, e);
  return m;
}

// ── 语言与显示名 ──

const HLS_LANG = {
  eng: 'en', chi: 'zh', zho: 'zh', jpn: 'ja', kor: 'ko', fre: 'fr', fra: 'fr', ger: 'de', deu: 'de',
  spa: 'es', ita: 'it', rus: 'ru', por: 'pt', ara: 'ar', hin: 'hi', tha: 'th', vie: 'vi', ind: 'id',
  may: 'ms', msa: 'ms', tur: 'tr', pol: 'pl', dut: 'nl', nld: 'nl', swe: 'sv', nor: 'no', nob: 'nb',
  nno: 'nn', dan: 'da', fin: 'fi', gre: 'el', ell: 'el', heb: 'he', hun: 'hu', cze: 'cs', ces: 'cs',
  slo: 'sk', slk: 'sk', rum: 'ro', ron: 'ro', bul: 'bg', ukr: 'uk', hrv: 'hr', srp: 'sr', slv: 'sl',
  est: 'et', lav: 'lv', lit: 'lt', ice: 'is', isl: 'is', per: 'fa', fas: 'fa', urd: 'ur', ben: 'bn',
  tam: 'ta', tel: 'te', mal: 'ml', kan: 'kn', mar: 'mr', guj: 'gu', pan: 'pa', tgl: 'tl', fil: 'fil',
  cat: 'ca', baq: 'eu', eus: 'eu', glg: 'gl', wel: 'cy', cym: 'cy', gle: 'ga', alb: 'sq', sqi: 'sq',
  mac: 'mk', mkd: 'mk', bos: 'bs', geo: 'ka', kat: 'ka', arm: 'hy', hye: 'hy', kaz: 'kk', uzb: 'uz',
  mon: 'mn', bur: 'my', mya: 'my', khm: 'km', lao: 'lo', nep: 'ne', sin: 'si', afr: 'af', swa: 'sw',
  amh: 'am', yue: 'yue', und: 'und', zxx: 'zxx', mul: 'mul',
};
const HLS_LANG_ZH = {
  en: '英语', zh: '中文', 'zh-Hans': '简体中文', 'zh-Hant': '繁体中文', yue: '粤语', ja: '日语',
  ko: '韩语', fr: '法语', de: '德语', es: '西班牙语', it: '意大利语', ru: '俄语', pt: '葡萄牙语',
  th: '泰语', vi: '越南语', ar: '阿拉伯语', hi: '印地语', id: '印尼语', ms: '马来语', tr: '土耳其语',
  pl: '波兰语', nl: '荷兰语', sv: '瑞典语', no: '挪威语', nb: '挪威语', da: '丹麦语', fi: '芬兰语',
  el: '希腊语', he: '希伯来语', hu: '匈牙利语', cs: '捷克语', uk: '乌克兰语', ro: '罗马尼亚语',
  und: '未知语言',
};

/** MKV 语言 → BCP-47；中文按轨道名细分简繁粤 */
function hlsLang(t) {
  let lang = t.langBcp || HLS_LANG[String(t.lang || 'und').toLowerCase()] || String(t.lang || 'und');
  const nm = String(t.name || '');
  if (lang === 'zh' || lang === 'chi') {
    if (/粤|cantonese|yue/i.test(nm)) lang = 'yue';
    else if (/繁|cht|tc\b|traditional|hant|big5/i.test(nm)) lang = 'zh-Hant';
    else if (/简|chs|sc\b|simplified|hans|gb/i.test(nm)) lang = 'zh-Hans';
  }
  return lang;
}
function hlsLangName(lang) { return HLS_LANG_ZH[lang] || HLS_LANG_ZH[lang.split('-')[0]] || lang; }
/** 播放列表属性值里不允许出现的字符 */
function hlsAttr(s) { return String(s).replace(/["\r\n]/g, ' ').trim(); }

// ── 视频：NAL 单元与参数集 ──
//  MKV 里 HEVC / AVC 的帧本该是「长度前缀 + NAL」序列，前缀宽度与参数集（HEVC 的 VPS / SPS / PPS，
//  AVC 的 SPS / PPS）都写在 CodecPrivate（hvcC / avcC）里。hvc1 / avc1 样本入口要求参数集齐全地
//  放在配置盒里，苹果的解码器只认这一种。实际片源里三种「不本该」都见得到：
//   · 参数集只在码流里（hev1 / avc3 风格：广播录制、直播切片转封装、某些编码器）——
//     CodecPrivate 只有个头、参数集不全，或者整个没有
//   · 帧里不是长度前缀而是 Annex B 起始码（00 00 01 / 00 00 00 01）
//   · 长度前缀的宽度与 CodecPrivate 里写的对不上
//  这里把它们都收拾成标准形态：从前几帧里把参数集捞出来，与 CodecPrivate 里的按编号合并去重，
//  重建配置盒；Annex B 的帧在出分段时就地转成 4 字节长度前缀。码流里重复出现的参数集原样留着 ——
//  与配置盒里的一致，播放器不在意，视频字节也就不必改动。

/** 按给定前缀宽度能把整帧切干净（每个 NAL 头的禁止位为 0），才算长度前缀 */
function nalLenOk(f, nalLen) {
  if (!f || !(nalLen >= 1 && nalLen <= 4)) return false;
  let p = 0, n = 0;
  while (p < f.length) {
    if (p + nalLen > f.length) return false;
    let len = 0;
    for (let i = 0; i < nalLen; i++) len = len * 256 + f[p + i];
    p += nalLen;
    if (len < 1 || p + len > f.length || (f[p] & 0x80)) return false;
    p += len; n++;
  }
  return n > 0;
}
/** 帧以起始码开头 */
function nalLooksAnnexB(f) {
  return !!f && f.length > 4 && f[0] === 0 && f[1] === 0 && (f[2] === 1 || (f[2] === 0 && f[3] === 1));
}
/** Annex B → 各 NAL（不含起始码；去掉 trailing_zero_8bits） */
function nalSplitAnnexB(f) {
  const out = [];
  const n = f.length;
  let i = 0, start = -1;
  const close = e => { while (e > start && f[e - 1] === 0) e--; if (e > start) out.push(f.subarray(start, e)); };
  while (i + 2 < n) {
    if (f[i] === 0 && f[i + 1] === 0 && f[i + 2] === 1) {
      if (start >= 0) close(i);
      i += 3; start = i;
      continue;
    }
    i++;
  }
  if (start >= 0) close(n);
  return out;
}
/** 一帧 → 各 NAL（长度前缀或 Annex B；data 不含前缀 / 起始码） */
function nalUnits(f, nalLen, annexB) {
  if (!f) return [];
  if (annexB) return nalSplitAnnexB(f);
  const out = [];
  let p = 0;
  while (p + nalLen <= f.length) {
    let len = 0;
    for (let i = 0; i < nalLen; i++) len = len * 256 + f[p + i];
    p += nalLen;
    if (len < 1 || p + len > f.length) break;
    out.push(f.subarray(p, p + len));
    p += len;
  }
  return out;
}
const nalTypeOf = (codec, d) => (codec === 'hevc' ? (d[0] >> 1) & 0x3F : d[0] & 0x1F);
const nalBytesEq = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

/** Annex B 的一帧 → 4 字节长度前缀的 NAL 序列（与分段写入同一套 pieces / size 形状） */
function hlsAnnexBToLen(pieces) {
  const f = pieces.length === 1 ? pieces[0] : hlsConcat(pieces);
  const out = [];
  let size = 0;
  for (const d of nalSplitAnnexB(f)) {
    const L = new Uint8Array(4);
    new DataView(L.buffer).setUint32(0, d.length);
    out.push(L, d);
    size += 4 + d.length;
  }
  return { pieces: out, size };
}

/** 参数集的编号：同一类型同一编号只能留一份（码流里的优先 —— 那才是真在用的） */
function nalParamId(codec, type, d) {
  try {
    if (codec === 'hevc') {
      if (type === 32) return (d[2] >> 4) & 15;                               // vps_video_parameter_set_id
      if (type === 33) return hevcParseSps(d).id;
      if (type === 34) return new HlsBits(nalUnescape(d), 2).ue();           // pps_pic_parameter_set_id
    } else {
      if (type === 7 || type === 13) return new HlsBits(nalUnescape(d), type === 7 ? 4 : 1).ue();
      if (type === 8) return new HlsBits(nalUnescape(d), 1).ue();
    }
  } catch {}
  return -1;
}

/** hvcC（ISO/IEC 14496-15 §8.3.3.1）：头部字段按 SPS 现算，数组 VPS → SPS → PPS，array_completeness = 1 */
function hevcBuildHvcC(s, arrays, nalLen = 4) {
  let size = 23;
  for (const [, list] of arrays) { size += 3; for (const d of list) size += 2 + d.length; }
  const out = new Uint8Array(size);
  const dv = new DataView(out.buffer);
  const P = s.ptl || {};
  out[0] = 1;
  out[1] = ((P.ps & 3) << 6) | ((P.tier & 1) << 5) | (P.pidc & 31);
  dv.setUint32(2, (P.compat || 0) >>> 0);
  for (let i = 0; i < 6; i++) out[6 + i] = (P.cons && P.cons[i]) || 0;
  out[12] = P.level || 0;
  dv.setUint16(13, 0xF000);                        // min_spatial_segmentation_idc = 0（未知）
  out[15] = 0xFC;                                  // parallelismType = 0（未知）
  out[16] = 0xFC | ((s.chroma ?? 1) & 3);
  out[17] = 0xF8 | (((s.bdl || 8) - 8) & 7);
  out[18] = 0xF8 | (((s.bdc || s.bdl || 8) - 8) & 7);
  dv.setUint16(19, 0);                             // avgFrameRate = 0（未指定）
  out[21] = (((s.layers || 1) & 7) << 3) | ((s.nested ? 1 : 0) << 2) | ((nalLen - 1) & 3);
  out[22] = arrays.length;
  let p = 23;
  for (const [type, list] of arrays) {
    out[p++] = 0x80 | (type & 0x3F);
    dv.setUint16(p, list.length); p += 2;
    for (const d of list) { dv.setUint16(p, d.length); p += 2; out.set(d, p); p += d.length; }
  }
  return out;
}

/** avcC（ISO/IEC 14496-15 §5.3.3.1）：High 系列带上色度 / 位深扩展 */
function avcBuildAvcC(sps, pps, ext, nalLen = 4) {
  const s0 = sps[0];
  const info = avcParseSps(s0);
  const high = [100, 110, 122, 144].includes(s0[1]);
  let size = 7;
  for (const d of [...sps, ...pps]) size += 2 + d.length;
  if (high) { size += 4; for (const d of ext) size += 2 + d.length; }
  const out = new Uint8Array(size);
  const dv = new DataView(out.buffer);
  out[0] = 1; out[1] = s0[1]; out[2] = s0[2]; out[3] = s0[3];
  out[4] = 0xFC | ((nalLen - 1) & 3);
  out[5] = 0xE0 | (sps.length & 31);
  let p = 6;
  for (const d of sps) { dv.setUint16(p, d.length); p += 2; out.set(d, p); p += d.length; }
  out[p++] = pps.length & 255;
  for (const d of pps) { dv.setUint16(p, d.length); p += 2; out.set(d, p); p += d.length; }
  if (high) {
    out[p++] = 0xFC | ((info.chroma ?? 1) & 3);
    out[p++] = 0xF8 | (((info.bdl || 8) - 8) & 7);
    out[p++] = 0xF8 | (((info.bdc || info.bdl || 8) - 8) & 7);
    out[p++] = ext.length & 255;
    for (const d of ext) { dv.setUint16(p, d.length); p += 2; out.set(d, p); p += d.length; }
  }
  return out;
}

/**
 * HEVC / AVC 的配置盒。CodecPrivate 里参数集齐全、帧也是标准长度前缀时原样用（一个字节都不动）；
 * 否则从前几帧里把参数集补齐、重建。返回 { cfg, nalLen, annexB, rebuilt, sps }，
 * 实在凑不齐（缺 SPS / PPS，HEVC 还要 VPS）就抛出能直接给人看的原因。
 */
function hlsParamConfig(codec, t, probe) {
  const hevc = codec === 'hevc';
  const name = hevc ? 'HEVC' : 'H.264';
  const need = hevc ? [32, 33, 34] : [7, 8];
  const label = { 32: 'VPS', 33: 'SPS', 34: 'PPS', 7: 'SPS', 8: 'PPS' };
  let parsed = null;
  try { parsed = t.priv && t.priv.length ? (hevc ? hevcParseHvcC(t.priv) : avcParseAvcC(t.priv)) : null; } catch { parsed = null; }
  const fromCfg = !parsed ? [] : hevc ? parsed.nals.map(n => ({ type: n.type, data: n.data }))
    : [...parsed.sps.map(d => ({ type: 7, data: d })), ...parsed.pps.map(d => ({ type: 8, data: d })), ...(parsed.ext || []).map(d => ({ type: 13, data: d }))];

  // 帧的封装：按配置盒里的前缀宽度切得开就是长度前缀；切不开而以起始码开头就是 Annex B
  const frames = probe.video.map(f => f.data).filter(f => f && f.length > 4);
  let nalLen = parsed ? parsed.nalLen : 4, annexB = false;
  const sample = frames.slice(0, 6);
  if (sample.length && !sample.every(f => nalLenOk(f, nalLen))) {
    if (sample.some(nalLooksAnnexB)) annexB = true;
    else {
      const alt = [4, 2, 1].find(n => n !== nalLen && sample.every(f => nalLenOk(f, n)));
      if (alt) nalLen = alt;
    }
  }
  const cfgComplete = !!parsed && need.every(ty => fromCfg.some(n => n.type === ty));
  if (cfgComplete && !annexB && nalLen === parsed.nalLen) {
    return { cfg: t.priv, nalLen, annexB: false, rebuilt: false, sps: fromCfg.filter(n => n.type === need[hevc ? 1 : 0]).map(n => n.data) };
  }

  // 码流里的参数集优先（那才是真在用的），配置盒里同类型同编号的不再要
  const keep = new Map();                                  // type → [{ id, data }]
  const add = (type, data) => {
    if (!keep.has(type)) keep.set(type, []);
    const L = keep.get(type);
    if (L.some(x => nalBytesEq(x.data, data))) return;
    const id = nalParamId(codec, type, data);
    if (id >= 0 && L.some(x => x.id === id)) return;
    L.push({ id, data });
  };
  const paramTypes = hevc ? new Set([32, 33, 34]) : new Set([7, 8, 13]);
  for (const f of frames.slice(0, 48)) {
    for (const d of nalUnits(f, nalLen, annexB)) {
      const ty = nalTypeOf(codec, d);
      if (paramTypes.has(ty)) add(ty, d);
    }
  }
  for (const n of fromCfg) if (paramTypes.has(n.type)) add(n.type, n.data);
  const missing = need.filter(ty => !(keep.get(ty) || []).length);
  if (missing.length) {
    throw hlsErr(`${name} 参数集不全：缺 ${missing.map(ty => label[ty]).join(' / ')}（配置里没有，片头几帧里也找不到）`);
  }
  const list = ty => (keep.get(ty) || []).map(x => x.data);
  const outLen = annexB ? 4 : nalLen;
  let cfg;
  if (hevc) {
    const s = hevcParseSps(list(33)[0]);
    cfg = hevcBuildHvcC(s, [[32, list(32)], [33, list(33)], [34, list(34)]], outLen);
  } else {
    cfg = avcBuildAvcC(list(7), list(8), list(13), outLen);
  }
  return { cfg, nalLen: outLen, annexB, rebuilt: true, sps: list(hevc ? 33 : 7) };
}

// ── 视频：HEVC ──

function hevcParseHvcC(u8) {
  if (!u8 || u8.length < 23) return null;
  const b = new HlsBits(u8);
  b.u(8);
  const ps = b.u(2), tier = b.u(1), pidc = b.u(5);
  const compat = b.u(32);
  const cons = [];
  for (let i = 0; i < 6; i++) cons.push(b.u(8));
  const level = b.u(8);
  b.u(16); b.u(8);
  b.u(6); const chroma = b.u(2);
  b.u(5); const bdl = b.u(3) + 8;
  b.u(5); b.u(3);
  b.u(16); b.u(2); b.u(3); b.u(1);
  const nalLen = b.u(2) + 1;
  const n = b.u(8);
  let p = 23;
  const nals = [];
  for (let i = 0; i < n && p + 3 <= u8.length; i++) {
    const type = u8[p] & 0x3F;
    const cnt = (u8[p + 1] << 8) | u8[p + 2];
    p += 3;
    for (let j = 0; j < cnt && p + 2 <= u8.length; j++) {
      const len = (u8[p] << 8) | u8[p + 1];
      p += 2;
      nals.push({ type, data: u8.subarray(p, p + len) });
      p += len;
    }
  }
  return { ps, tier, pidc, compat, cons, level, chroma, bdl, nalLen, nals };
}

/** RFC 6381 / ISO 14496-15 附录 E：hvc1.2.4.L153.B0 */
function hevcCodecString(h) {
  let rev = 0;
  for (let j = 0; j < 32; j++) if ((h.compat >>> (31 - j)) & 1) rev += 2 ** j;
  const cons = h.cons.slice();
  while (cons.length && cons[cons.length - 1] === 0) cons.pop();
  return `hvc1.${['', 'A', 'B', 'C'][h.ps]}${h.pidc}.${rev.toString(16).toUpperCase()}`
    + `.${h.tier ? 'H' : 'L'}${h.level}` + cons.map(c => '.' + c.toString(16).toUpperCase()).join('');
}

function hevcSkipScalingList(b) {
  for (let sizeId = 0; sizeId < 4; sizeId++) {
    for (let m = 0; m < 6; m += sizeId === 3 ? 3 : 1) {
      if (!b.u(1)) { b.ue(); continue; }
      const n = Math.min(64, 1 << (4 + (sizeId << 1)));
      if (sizeId > 1) b.se();
      for (let i = 0; i < n; i++) b.se();
    }
  }
}

/** HEVC SPS：只取我们用得到的——编号、profile / tier / level（重建 hvcC 与 CODECS 串）、
 *  尺寸（按一致性窗口裁剪）、色度与位深、重排深度（推 DTS）、VUI 色彩（判 PQ/HLG）、SAR */
function hevcParseSps(nal) {
  const d = nalUnescape(nal);
  const b = new HlsBits(d, 2);
  b.u(4);                                          // sps_video_parameter_set_id
  const maxSub = b.u(3);
  const nested = b.u(1);
  const ptl = { ps: b.u(2), tier: b.u(1), pidc: b.u(5), compat: b.u(32), cons: [], level: 0 };
  for (let i = 0; i < 6; i++) ptl.cons.push(b.u(8));
  ptl.level = b.u(8);
  const subP = [], subL = [];
  for (let i = 0; i < maxSub; i++) { subP.push(b.u(1)); subL.push(b.u(1)); }
  if (maxSub > 0) for (let i = maxSub; i < 8; i++) b.u(2);
  for (let i = 0; i < maxSub; i++) {
    if (subP[i]) { b.u(32); b.u(32); b.u(24); }
    if (subL[i]) b.u(8);
  }
  const id = b.ue();                               // sps_seq_parameter_set_id
  const chroma = b.ue();
  if (chroma === 3) b.u(1);
  const out = { id, ptl, layers: maxSub + 1, nested, w: b.ue(), h: b.ue(), chroma };
  if (b.u(1)) {                                    // 一致性窗口：编码尺寸（如 1088）裁成显示尺寸（1080）
    const l = b.ue(), r = b.ue(), t = b.ue(), bt = b.ue();
    const sw = chroma === 1 || chroma === 2 ? 2 : 1, sh = chroma === 1 ? 2 : 1;
    out.w -= sw * (l + r); out.h -= sh * (t + bt);
  }
  out.bdl = b.ue() + 8;
  out.bdc = b.ue() + 8;
  const log2Poc = b.ue() + 4;
  const subInfo = b.u(1);
  for (let i = subInfo ? 0 : maxSub; i <= maxSub; i++) {
    b.ue();
    out.reorder = b.ue();
    b.ue();
  }
  try {
    for (let i = 0; i < 6; i++) b.ue();
    if (b.u(1) && b.u(1)) hevcSkipScalingList(b);
    b.u(1); b.u(1);
    if (b.u(1)) { b.u(4); b.u(4); b.ue(); b.ue(); b.u(1); }
    const nRps = b.ue();
    const numDelta = [];
    for (let i = 0; i < nRps; i++) {
      const inter = i !== 0 ? b.u(1) : 0;
      if (inter) {
        b.u(1); b.ue();
        let k = 0;
        for (let j = 0; j <= numDelta[i - 1]; j++) {
          const used = b.u(1);
          const useDelta = used ? 1 : b.u(1);
          if (used || useDelta) k++;
        }
        numDelta.push(k);
      } else {
        const neg = b.ue(), pos = b.ue();
        for (let j = 0; j < neg + pos; j++) { b.ue(); b.u(1); }
        numDelta.push(neg + pos);
      }
    }
    if (b.u(1)) { const n = b.ue(); for (let i = 0; i < n; i++) { b.u(log2Poc); b.u(1); } }
    b.u(1); b.u(1);
    if (b.u(1)) hlsParseVuiColour(b, out);
  } catch {}
  return out;
}

/** HEVC 与 AVC 的 VUI 开头几项完全一致：SAR、过扫描、视频信号类型 */
function hlsParseVuiColour(b, out) {
  if (b.u(1)) {
    const idc = b.u(8);
    if (idc === 255) { out.sarW = b.u(16); out.sarH = b.u(16); }
    else if (idc > 0 && idc < 17) {
      const t = [[1, 1], [12, 11], [10, 11], [16, 11], [40, 33], [24, 11], [20, 11], [32, 11],
        [80, 33], [18, 11], [15, 11], [64, 33], [160, 99], [4, 3], [3, 2], [2, 1]][idc - 1];
      out.sarW = t[0]; out.sarH = t[1];
    }
  }
  if (b.u(1)) b.u(1);
  if (b.u(1)) {
    b.u(3);
    out.full = b.u(1);
    if (b.u(1)) { out.prim = b.u(8); out.trc = b.u(8); out.mtx = b.u(8); }
  }
}

// ── 视频：AVC ──

function avcParseAvcC(u8) {
  if (!u8 || u8.length < 7 || u8[0] !== 1) return null;
  const out = { profile: u8[1], compat: u8[2], level: u8[3], nalLen: (u8[4] & 3) + 1, sps: [], pps: [], ext: [] };
  let p = 5;
  const take = (n, into) => {
    for (let i = 0; i < n && p + 2 <= u8.length; i++) {
      const len = (u8[p] << 8) | u8[p + 1];
      p += 2;
      if (!len || p + len > u8.length) { p = u8.length; return; }
      into.push(u8.subarray(p, p + len));
      p += len;
    }
  };
  take(u8[p++] & 0x1F, out.sps);
  if (p < u8.length) take(u8[p++], out.pps);
  if (p + 4 <= u8.length && [100, 110, 122, 144].includes(out.profile)) { p += 3; take(u8[p++], out.ext); }
  return out;
}
function avcCodecString(a) {
  const h = v => v.toString(16).padStart(2, '0');
  return `avc1.${h(a.profile)}${h(a.compat)}${h(a.level)}`;
}
function avcSkipHrd(b) {
  const n = b.ue() + 1;
  b.u(4); b.u(4);
  for (let i = 0; i < n; i++) { b.ue(); b.ue(); b.u(1); }
  b.u(5); b.u(5); b.u(5); b.u(5);
}
function avcParseSps(nal) {
  const d = nalUnescape(nal);
  const b = new HlsBits(d, 1);
  const out = { profile: b.u(8), reorder: -1, chroma: 1, bdl: 8, bdc: 8 };
  b.u(8); b.u(8); b.ue();
  try {
    if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].includes(out.profile)) {
      const chroma = b.ue();
      out.chroma = chroma;
      if (chroma === 3) b.u(1);
      out.bdl = b.ue() + 8; out.bdc = b.ue() + 8; b.u(1);
      if (b.u(1)) {
        for (let i = 0; i < (chroma !== 3 ? 8 : 12); i++) {
          if (!b.u(1)) continue;
          let last = 8, next = 8;
          for (let j = 0; j < (i < 6 ? 16 : 64); j++) {
            if (next !== 0) next = (last + b.se() + 256) % 256;
            if (next !== 0) last = next;
          }
        }
      }
    }
    b.ue();
    const poc = b.ue();
    if (poc === 0) b.ue();
    else if (poc === 1) { b.u(1); b.se(); b.se(); const n = b.ue(); for (let i = 0; i < n; i++) b.se(); }
    b.ue(); b.u(1); b.ue(); b.ue();
    if (!b.u(1)) b.u(1);
    b.u(1);
    if (b.u(1)) { b.ue(); b.ue(); b.ue(); b.ue(); }
    if (b.u(1)) {
      hlsParseVuiColour(b, out);
      if (b.u(1)) { b.ue(); b.ue(); }
      if (b.u(1)) { b.u(32); b.u(32); b.u(1); }
      const nalHrd = b.u(1); if (nalHrd) avcSkipHrd(b);
      const vclHrd = b.u(1); if (vclHrd) avcSkipHrd(b);
      if (nalHrd || vclHrd) b.u(1);
      b.u(1);
      if (b.u(1)) { b.u(1); b.ue(); b.ue(); b.ue(); b.ue(); out.reorder = b.ue(); b.ue(); }
    }
  } catch {}
  return out;
}

// ── 视频：AV1 ──

function av1Parse(u8) {
  if (!u8 || u8.length < 4 || !(u8[0] & 0x80)) return null;
  const profile = u8[1] >> 5, level = u8[1] & 0x1F, tier = u8[2] >> 7;
  const depth = (u8[2] & 0x40) ? ((u8[2] & 0x20) ? 12 : 10) : 8;
  return { profile, level, tier, depth };
}
/** AV1 的 leb128（OBU 大小字段）→ [值, 字节数] */
function av1Leb128(u8, p) {
  let v = 0, n = 0;
  for (let i = 0; i < 8 && p + i < u8.length; i++) {
    const b = u8[p + i];
    v += (b & 0x7F) * 2 ** (7 * i);
    n++;
    if (!(b & 0x80)) break;
  }
  return [v, n];
}
/** 一帧（低开销 OBU 流）里找序列头 OBU（type 1）→ { obu（含头，原样）, payload } */
function av1FindSeqHeader(frame) {
  let p = 0;
  while (frame && p < frame.length) {
    const h = frame[p];
    if (h & 0x80) return null;                                 // forbidden bit
    const type = (h >> 3) & 15, ext = (h >> 2) & 1, hasSize = (h >> 1) & 1;
    let q = p + 1 + ext, size;
    if (hasSize) { const [v, n] = av1Leb128(frame, q); size = v; q += n; } else size = frame.length - q;
    if (q + size > frame.length) return null;
    if (type === 1) return { obu: frame.subarray(p, q + size), payload: frame.subarray(q, q + size) };
    p = q + size;
  }
  return null;
}
function av1Uvlc(b) {
  let z = 0;
  while (!b.u(1)) { if (++z >= 32) return 2 ** 32 - 1; }
  return z ? b.u(z) + 2 ** z - 1 : 0;
}
/** AV1 序列头（AV1 规范 5.5）：profile / level / tier、尺寸、色彩（color_config） */
function av1ParseSeqHeader(payload) {
  const b = new HlsBits(payload);
  const o = { profile: b.u(3), level: 0, tier: 0 };
  b.u(1);                                                      // still_picture
  const reduced = b.u(1);
  if (reduced) o.level = b.u(5);
  else {
    let model = 0, delayLen = 0;
    if (b.u(1)) {                                              // timing_info_present_flag
      b.u(32); b.u(32);
      if (b.u(1)) av1Uvlc(b);                                  // equal_picture_interval
      model = b.u(1);
      if (model) { delayLen = b.u(5) + 1; b.u(32); b.u(5); b.u(5); }
    }
    const initDelay = b.u(1);
    const ops = b.u(5) + 1;
    for (let i = 0; i < ops; i++) {
      b.u(12);
      const lvl = b.u(5), tier = lvl > 7 ? b.u(1) : 0;
      if (i === 0) { o.level = lvl; o.tier = tier; }
      if (model && b.u(1)) { b.u(delayLen); b.u(delayLen); b.u(1); }
      if (initDelay && b.u(1)) b.u(4);
    }
  }
  const wb = b.u(4) + 1, hb = b.u(4) + 1;
  o.w = b.u(wb) + 1; o.h = b.u(hb) + 1;
  if (!reduced && b.u(1)) { b.u(4); b.u(3); }                 // frame_id_numbers_present_flag
  b.u(1); b.u(1); b.u(1);                                      // 128×128 超块、filter_intra、intra_edge
  if (!reduced) {
    b.u(1); b.u(1); b.u(1); b.u(1);                            // interintra、masked、warped、dual_filter
    const orderHint = b.u(1);
    if (orderHint) { b.u(1); b.u(1); }                         // jnt_comp、ref_frame_mvs
    const sct = b.u(1) ? 2 : b.u(1);                           // seq_force_screen_content_tools
    if (sct > 0 && !b.u(1)) b.u(1);                            // seq_force_integer_mv
    if (orderHint) b.u(3);
  }
  b.u(1); b.u(1); b.u(1);                                      // superres、cdef、restoration
  const hbd = b.u(1);
  o.highBd = hbd;
  o.twelve = o.profile === 2 && hbd ? b.u(1) : 0;
  o.depth = o.twelve ? 12 : hbd ? 10 : 8;
  o.mono = o.profile === 1 ? 0 : b.u(1);
  o.prim = 2; o.trc = 2; o.mtx = 2; o.csp = 0;
  if (b.u(1)) { o.prim = b.u(8); o.trc = b.u(8); o.mtx = b.u(8); }
  if (o.mono) { o.full = b.u(1); o.ssx = 1; o.ssy = 1; }
  else if (o.prim === 1 && o.trc === 13 && o.mtx === 0) { o.full = 1; o.ssx = 0; o.ssy = 0; }
  else {
    o.full = b.u(1);
    if (o.profile === 0) { o.ssx = 1; o.ssy = 1; }
    else if (o.profile === 1) { o.ssx = 0; o.ssy = 0; }
    else if (o.depth === 12) { o.ssx = b.u(1); o.ssy = o.ssx ? b.u(1) : 0; }
    else { o.ssx = 1; o.ssy = 0; }
    if (o.ssx && o.ssy) o.csp = b.u(2);
  }
  return o;
}
/** av1C（AV1-ISOBMFF §2.3）：头 4 字节按序列头现算，configOBUs = 序列头 OBU 原样 */
function av1BuildAv1C(o, seqObu) {
  const out = new Uint8Array(4 + seqObu.length);
  out[0] = 0x81;
  out[1] = ((o.profile & 7) << 5) | (o.level & 31);
  out[2] = ((o.tier & 1) << 7) | ((o.highBd & 1) << 6) | ((o.twelve & 1) << 5) | ((o.mono & 1) << 4)
    | ((o.ssx & 1) << 3) | ((o.ssy & 1) << 2) | (o.csp & 3);
  out[3] = 0;
  out.set(seqObu, 4);
  return out;
}
function av1CodecString(a) {
  return `av01.${a.profile}.${String(a.level).padStart(2, '0')}${a.tier ? 'H' : 'M'}.${String(a.depth).padStart(2, '0')}`;
}

// ── 音频：AAC ──

const AAC_RATES = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

function aacParseAsc(u8) {
  if (!u8 || u8.length < 2) return null;
  const b = new HlsBits(u8);
  const aot = () => { const a = b.u(5); return a === 31 ? 32 + b.u(6) : a; };
  const rate = () => { const i = b.u(4); return i === 15 ? b.u(24) : (AAC_RATES[i] || 0); };
  try {
    const first = aot();
    const sr = rate();
    const ch = b.u(4);
    // 显式 SBR / PS：外层 AOT 是 5（HE-AAC）或 29（HE-AACv2），CODECS 按外层写
    if (first === 5 || first === 29) { const out = rate(); aot(); return { aot: first, rate: sr, outRate: out, ch }; }
    return { aot: first, rate: sr, outRate: sr, ch };
  } catch { return null; }
}
/** 老式 A_AAC/MPEG4/LC 之类没有 CodecPrivate 的 CodecID：自己拼一个 ASC */
function aacBuildAsc(codecId, rate, ch, outRate) {
  const idx = r => { const i = AAC_RATES.indexOf(r); return i < 0 ? 3 : i; };
  const prof = /MAIN/.test(codecId) ? 1 : /SSR/.test(codecId) ? 3 : /LTP/.test(codecId) ? 4 : 2;
  if (/SBR/.test(codecId) || (outRate && outRate === rate * 2)) {
    const w = new HlsBitWriter();
    w.u(5, 5); w.u(4, idx(rate)); w.u(4, ch); w.u(4, idx(outRate || rate * 2)); w.u(5, 2); w.align();
    return w.out();
  }
  const w = new HlsBitWriter();
  w.u(5, prof); w.u(4, idx(rate)); w.u(4, ch); w.u(3, 0); w.align();
  return w.out();
}

// ── 音频：AC-3 / E-AC-3 ──

const AC3_KBPS = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640];
const AC3_CH = [2, 1, 2, 3, 3, 4, 4, 5];

/** 解析一个 AC-3 或 E-AC-3 同步帧头。E-AC-3 会一路读到 addbsi，拿到 Atmos(JOC) 标记 */
function ac3ParseHeader(d, p = 0) {
  if (d.length < p + 8 || d[p] !== 0x0B || d[p + 1] !== 0x77) return null;
  const bsid = d[p + 5] >> 3;
  if (bsid <= 10) {
    const b = new HlsBits(d, p + 4);
    const fscod = b.u(2), frmsizecod = b.u(6);
    b.u(5);
    const bsmod = b.u(3), acmod = b.u(3);
    if ((acmod & 1) && acmod !== 1) b.u(2);
    if (acmod & 4) b.u(2);
    if (acmod === 2) b.u(2);
    const lfeon = b.u(1);
    if (fscod === 3) return null;
    const rate = [48000, 44100, 32000][fscod];
    const kbps = AC3_KBPS[frmsizecod >> 1] || 0;
    const words = fscod === 1 ? Math.floor(kbps * 1000 * 1536 / 44100 / 16) + (frmsizecod & 1)
      : kbps * (fscod === 0 ? 2 : 3);
    return { eac3: false, strmtyp: 0, substreamid: 0, fscod, frmsizecod, bsid, bsmod, acmod, lfeon,
      rate, blocks: 6, frameSize: words * 2, bitrate: kbps * 1000, ch: AC3_CH[acmod] + lfeon };
  }
  if (bsid > 16) return null;
  const b = new HlsBits(d, p + 2);
  const strmtyp = b.u(2), substreamid = b.u(3), frmsiz = b.u(11);
  const fscod = b.u(2);
  let blocks = 6, rate;
  if (fscod === 3) { const f2 = b.u(2); if (f2 === 3) return null; rate = [24000, 22050, 16000][f2]; }
  else { blocks = [1, 2, 3, 6][b.u(2)]; rate = [48000, 44100, 32000][fscod]; }
  const acmod = b.u(3), lfeon = b.u(1);
  b.u(5);
  const frameSize = (frmsiz + 1) * 2;
  const h = { eac3: true, strmtyp, substreamid, fscod, bsid, bsmod: 0, acmod, lfeon, rate, blocks,
    frameSize, bitrate: frameSize * 8 * rate / (blocks * 256), ch: AC3_CH[acmod] + lfeon,
    chanmap: null, joc: false, jocCx: 0 };
  try {
    for (let i = 0; i < (acmod ? 1 : 2); i++) { b.u(5); if (b.u(1)) b.u(8); }
    if (strmtyp === 1 && b.u(1)) h.chanmap = b.u(16);
    if (b.u(1)) {                                      // mixmdate
      if (acmod > 2) b.u(2);
      if ((acmod & 1) && acmod > 2) { b.u(3); b.u(3); }
      if (acmod & 4) { b.u(3); b.u(3); }
      if (lfeon && b.u(1)) b.u(5);
      if (strmtyp === 0) {
        for (let i = 0; i < (acmod ? 1 : 2); i++) if (b.u(1)) b.u(6);
        if (b.u(1)) b.u(6);
        const mixdef = b.u(2);
        if (mixdef === 1) b.u(5);
        else if (mixdef === 2) b.u(12);
        else if (mixdef === 3) b.skip((b.u(5) + 2) * 8);
        if (acmod < 2) for (let i = 0; i < (acmod ? 1 : 2); i++) if (b.u(1)) b.u(14);
        if (b.u(1)) for (let k = 0; k < blocks; k++) if (blocks === 1 || b.u(1)) b.u(5);
      }
    }
    if (b.u(1)) {                                      // infomdate
      h.bsmod = b.u(3);
      b.u(2);
      if (acmod === 2) b.u(4);
      if (acmod >= 6) b.u(2);
      for (let i = 0; i < (acmod ? 1 : 2); i++) if (b.u(1)) b.u(8);
      if (fscod !== 3) b.u(1);
    }
    if (strmtyp === 0 && blocks !== 6) b.u(1);
    if (strmtyp === 2 && (blocks === 6 || b.u(1))) b.u(6);
    if (b.u(1)) {                                      // addbsie：首字节最低位 = flag_ec3_extension_type_a
      const len = b.u(6) + 1;
      b.u(7);
      if (b.u(1)) { h.joc = true; h.jocCx = len >= 2 ? b.u(8) : 0; }
    }
  } catch {}
  return h;
}

/** 一个 MKV 帧 = 一个 E-AC-3 访问单元（独立子流 + 其依附子流），逐个拆出帧头 */
function ac3ParseAccessUnit(d) {
  const out = [];
  let p = 0;
  while (p + 8 <= d.length && out.length < 16) {
    const h = ac3ParseHeader(d, p);
    if (!h || h.frameSize < 8) break;
    out.push(h);
    p += h.frameSize;
  }
  return out;
}
function ac3Dac3(h) {
  const w = new HlsBitWriter();
  w.u(2, h.fscod); w.u(5, h.bsid); w.u(3, h.bsmod); w.u(3, h.acmod); w.u(1, h.lfeon);
  w.u(5, h.frmsizecod >> 1); w.u(5, 0);
  return w.out();
}
/** dec3（ETSI TS 102 366 附录 F），JOC 时追加 complexity_index_type_a —— Atmos 靠它识别 */
function eac3Dec3(au) {
  const subs = [];
  let kbps = 0;
  for (const h of au) {
    kbps += h.bitrate / 1000;
    if (h.strmtyp !== 1) subs.push({ h, deps: 0, loc: 0 });
    else if (subs.length) {
      const s = subs[subs.length - 1];
      s.deps++;
      s.loc |= h.chanmap != null ? (h.chanmap >> 5) & 0x1F : h.acmod;
    }
  }
  if (!subs.length) return null;
  const first = subs[0].h;
  const w = new HlsBitWriter();
  w.u(13, Math.min(8191, Math.round(kbps)));
  w.u(3, subs.length - 1);
  for (const s of subs) {
    w.u(2, s.h.fscod); w.u(5, s.h.bsid); w.u(1, 0); w.u(1, 0);
    w.u(3, s.h.bsmod); w.u(3, s.h.acmod); w.u(1, s.h.lfeon);
    w.u(3, 0); w.u(4, s.deps);
    if (s.deps) w.u(9, s.loc); else w.u(1, 0);
  }
  if (first.joc) { w.u(7, 0); w.u(1, 1); w.u(8, first.jocCx); }
  w.align();
  return w.out();
}

// ── 音频：FLAC / ALAC ──

/** MKV 的 FLAC CodecPrivate = "fLaC" + 元数据块；dfLa 只要元数据块 */
function flacParsePrivate(u8) {
  if (!u8 || u8.length < 42) return null;
  let p = (u8[0] === 0x66 && u8[1] === 0x4C && u8[2] === 0x61 && u8[3] === 0x43) ? 4 : 0;
  const blocks = u8.subarray(p);
  if ((blocks[0] & 0x7F) !== 0) return null;          // 第一块必须是 STREAMINFO
  const si = blocks.subarray(4, 38);
  const minBlock = (si[0] << 8) | si[1], maxBlock = (si[2] << 8) | si[3];
  const rate = (si[10] << 12) | (si[11] << 4) | (si[12] >> 4);
  const ch = ((si[12] >> 1) & 7) + 1;
  const bits = (((si[12] & 1) << 4) | (si[13] >> 4)) + 1;
  // 只保留 STREAMINFO 并置「最后一块」标记：其余块（SEEKTABLE、图片…）在分片里没用
  const dfla = new Uint8Array(38);
  dfla.set(blocks.subarray(0, 38));
  dfla[0] = 0x80;
  return { dfla, rate, ch, bits, fixed: minBlock === maxBlock ? maxBlock : 0 };
}
/** FLAC 帧头里的块大小（变长块流靠它算每帧时长） */
function flacFrameSamples(d) {
  if (!d || d.length < 6 || d[0] !== 0xFF || (d[1] & 0xFE) !== 0xF8) return 0;
  const code = d[2] >> 4;
  if (code === 1) return 192;
  if (code >= 2 && code <= 5) return 576 << (code - 2);
  if (code >= 8) return 256 << (code - 8);
  if (code === 6 || code === 7) {
    let p = 4, b = d[4], n = 0;
    while (b & 0x80) { n++; b <<= 1; }
    p += n ? n : 1;
    if (code === 6) return d[p] + 1;
    return ((d[p] << 8) | d[p + 1]) + 1;
  }
  return 0;
}
function alacParsePrivate(u8) {
  if (!u8 || u8.length < 24) return null;
  let p = 0;
  // 有的封装器把 'alac' FullBox 头也带进来了
  if (u8.length >= 36 && u8[4] === 0x61 && u8[5] === 0x6C && u8[6] === 0x61 && u8[7] === 0x63) p = 12;
  const c = u8.subarray(p, p + 24);
  const dv = new DataView(c.buffer, c.byteOffset, 24);
  return { cfg: c, frame: dv.getUint32(0), bits: c[5], ch: c[9], rate: dv.getUint32(20) };
}

// ── 杜比视界 ──
//  配置盒 dvcC / dvvC：24 字节，profile 7 bit、level 6 bit、rpu/el/bl 三个标志、
//  兼容 ID 4 bit。P7 → 8.1 的 RPU 改写与 dovi_tool 的 mode 2 逐位一致：
//    · 头部 el_spatial_resampling_filter_flag = 0、disable_residual_flag = 1
//    · 去掉 NLQ（残差量化）段与分区信息
//    · FEL 片源把映射曲线置为恒等（MEL 保留原映射：它本来就无损）
//    · DM 色彩矩阵换成 8.1 的标准系数；扩展元数据块（L1/L2/L6…）原样保留

function dvParseConfig(u8) {
  if (!u8 || u8.length < 5) return null;
  return {
    major: u8[0], minor: u8[1],
    profile: u8[2] >> 1,
    level: ((u8[2] & 1) << 5) | (u8[3] >> 3),
    rpu: (u8[3] >> 2) & 1, el: (u8[3] >> 1) & 1, bl: u8[3] & 1,
    compat: u8[4] >> 4,
  };
}
function dvBuildConfig(c) {
  const out = new Uint8Array(24);
  out[0] = c.major || 1;
  out[1] = c.minor || 0;
  out[2] = (c.profile << 1) | ((c.level >> 5) & 1);
  out[3] = ((c.level & 31) << 3) | (c.rpu << 2) | (c.el << 1) | c.bl;
  out[4] = (c.compat & 15) << 4;
  return out;
}
function dvBoxType(profile) { return profile <= 7 ? 'dvcC' : profile <= 10 ? 'dvvC' : 'dvwC'; }

/** 按像素吞吐推 DV level（Dolby Vision Profiles and Levels 表） */
function dvLevelFor(w, h, fps) {
  const pps = w * h * (fps || 24);
  const T = [[1, 22118400, 1280], [2, 27648000, 1280], [3, 49766400, 1920], [4, 62208000, 2560],
    [5, 124416000, 3840], [6, 199065600, 3840], [7, 248832000, 3840], [8, 398131200, 3840],
    [9, 497664000, 3840], [10, 995328000, 3840], [11, 995328000, 7680], [12, 1990656000, 7680],
    [13, 3981312000, 7680]];
  for (const [lvl, max, maxW] of T) if (pps <= max * 1.001 && w <= maxW) return lvl;
  return 13;
}

// ── RPU 解析 / 改写 ──

const DV_P81_YCC = [9574, 0, 13802, 9574, -1540, -5348, 9574, 17610, 0];
const DV_P81_OFF = [16777216, 134217728, 134217728];
const DV_P81_LMS = [7222, 8771, 390, 2654, 12430, 1300, 0, 422, 15962];
// vdr_dm_data 固定段的字段宽度（未压缩时）
const DV_DM_FIXED = [16, 16, 16, 16, 16, 16, 16, 16, 16, 32, 32, 32,
  16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 32, 5, 2, 2, 2, 12, 12, 10];

/** 去掉起始码 / NAL 头 / 防竞争字节，得到以 0x19 开头的 RPU 负载 */
function dvRpuPayload(nal) {
  let p = 0;
  if (nal[0] === 0 && nal[1] === 0 && nal[2] === 0 && nal[3] === 1) p = 4;
  else if (nal[0] === 0 && nal[1] === 0 && nal[2] === 1) p = 3;
  if (nal[p] === 0x7C && nal[p + 1] === 0x01) p += 2;
  return nalUnescape(nal.subarray(p));
}

function dvRpuParse(data) {
  let end = data.length, tz = 0;
  while (end > 0 && data[end - 1] === 0) { end--; tz++; }
  if (end < 7 || data[0] !== 0x19 || data[end - 1] !== 0x80) throw new Error('RPU framing');
  const crc = ((data[end - 5] << 24) | (data[end - 4] << 16) | (data[end - 3] << 8) | data[end - 2]) >>> 0;
  if (hlsCrc32(data, 1, end - 5) !== crc) throw new Error('RPU CRC mismatch');
  const b = new HlsBits(data, 1, end);
  const H = { rpu_type: b.u(6) };
  if (H.rpu_type !== 2) throw new Error('RPU type');
  H.rpu_format = b.u(11);
  H.vdr_rpu_profile = b.u(4);
  H.vdr_rpu_level = b.u(4);
  H.seq = b.u(1);
  let coefLen = 0;
  if (H.seq) {
    H.chroma_explicit = b.u(1);
    H.cdt = b.u(2);
    if (H.cdt === 0) H.log2_denom = b.ue();
    H.normalized_idc = b.u(2);
    H.full_range = b.u(1);
    H.ext = (H.rpu_format & 0x700) === 0;
    if (H.ext) {
      H.bl_bit_depth_minus8 = b.ue();
      H.el_bit_depth_raw = b.ue();
      H.vdr_bit_depth_minus8 = b.ue();
      H.spatial_resampling = b.u(1);
      H.reserved3 = b.u(3);
      H.el_spatial_resampling = b.u(1);
      H.disable_residual = b.u(1);
    }
    if (H.cdt === 0) coefLen = H.log2_denom;
    else if (H.cdt === 1) coefLen = 32;
    else throw new Error('coefficient_data_type');
  }
  H.dm_present = b.u(1);
  H.use_prev = b.u(1);
  if (H.use_prev) H.prev_id = b.ue();
  const R = { H, tz, coefLen, data };
  const blDepth = (H.bl_bit_depth_minus8 || 2) + 8;

  if (!H.use_prev) {
    if (!H.seq) throw new Error('RPU without sequence info');
    const M = { id: b.ue(), cs: b.ue(), cf: b.ue(), curves: [] };
    for (let c = 0; c < 3; c++) {
      const n = b.ue();
      if (n >= 8) throw new Error('RPU pivots');
      const piv = [];
      for (let i = 0; i < n + 2; i++) piv.push(b.u(blDepth));
      M.curves.push({ n, piv, pieces: [] });
    }
    if (H.ext && !H.disable_residual) {
      M.nlq_method = b.u(3);
      if (M.nlq_method !== 0) throw new Error('NLQ method');
      M.nlq_pivots = [b.u(blDepth), b.u(blDepth)];
    }
    M.nx = b.ue();
    M.ny = b.ue();
    const coef = () => ({ i: H.cdt === 0 ? b.se() : 0, f: b.u(coefLen) });
    for (const cv of M.curves) {
      for (let k = 0; k <= cv.n; k++) {
        const idc = b.ue();
        if (idc === 0) {
          const order = b.ue();
          if (order > 1) throw new Error('poly order');
          const lin = order === 0 ? b.u(1) : 0;
          if (lin) throw new Error('poly linear interpolation');
          const c = [];
          for (let j = 0; j < order + 2; j++) c.push(coef());
          cv.pieces.push({ idc, order, lin, c });
        } else if (idc === 1) {
          const order = b.u(2);
          if (order > 2) throw new Error('mmr order');
          const k0 = coef();
          const c = [];
          for (let j = 0; j < order + 1; j++) for (let m = 0; m < 7; m++) c.push(coef());
          cv.pieces.push({ idc, order, k0, c });
        } else throw new Error('mapping idc');
      }
    }
    if (M.nlq_method != null) {
      const elDepth = (H.el_bit_depth_raw & 0xFF) + 8;
      M.nlq = [];
      for (let c = 0; c < 3; c++) {
        M.nlq.push({
          off: b.u(elDepth),
          maxI: H.cdt === 0 ? b.ue() : 0, max: b.u(coefLen),
          slI: H.cdt === 0 ? b.ue() : 0, sl: b.u(coefLen),
          thI: H.cdt === 0 ? b.ue() : 0, th: b.u(coefLen),
        });
      }
    }
    R.M = M;
  }

  if (H.dm_present) {
    const D = { compressed: H.reserved3 === 1, ids: [b.ue(), b.ue(), b.ue()] };
    if (!D.compressed) D.fixed = DV_DM_FIXED.map(n => b.u(n));
    const blocks = () => {
      const n = b.ue();
      while (!b.aligned) if (b.u(1)) throw new Error('dm alignment');
      const list = [];
      for (let i = 0; i < n; i++) {
        const len = b.ue(), level = b.u(8);
        list.push({ len, level, at: b.p, bits: len * 8 });
        b.skip(len * 8);
      }
      return list;
    };
    D.cm29 = blocks();
    if (b.left >= 56) D.cm40 = blocks();
    R.D = D;
  }
  while (!b.aligned) if (b.u(1)) throw new Error('rpu alignment');
  if (b.left > 40) { R.rest = { at: b.p, bits: b.left - 40 }; b.skip(b.left - 40); }
  return R;
}

/** 元数据层 L1/L2/L5/L6… 原样按位搬运 */
function dvCopyBits(w, data, at, bits) {
  for (let i = 0; i < bits; i++) {
    const p = at + i;
    w.bit((data[p >> 3] >> (7 - (p & 7))) & 1);
  }
}

function dvRpuWrite(R) {
  const { H, M, D, coefLen, data } = R;
  const w = new HlsBitWriter();
  const blDepth = (H.bl_bit_depth_minus8 || 2) + 8;
  w.u(8, 0x19);
  w.u(6, H.rpu_type); w.u(11, H.rpu_format); w.u(4, H.vdr_rpu_profile); w.u(4, H.vdr_rpu_level);
  w.u(1, H.seq);
  if (H.seq) {
    w.u(1, H.chroma_explicit); w.u(2, H.cdt);
    if (H.cdt === 0) w.ue(H.log2_denom);
    w.u(2, H.normalized_idc); w.u(1, H.full_range);
    if (H.ext) {
      w.ue(H.bl_bit_depth_minus8); w.ue(H.el_bit_depth_raw); w.ue(H.vdr_bit_depth_minus8);
      w.u(1, H.spatial_resampling); w.u(3, H.reserved3);
      w.u(1, H.el_spatial_resampling); w.u(1, H.disable_residual);
    }
  }
  w.u(1, H.dm_present); w.u(1, H.use_prev);
  if (H.use_prev) w.ue(H.prev_id);
  if (M) {
    w.ue(M.id); w.ue(M.cs); w.ue(M.cf);
    for (const cv of M.curves) { w.ue(cv.n); for (const p of cv.piv) w.u(blDepth, p); }
    if (H.ext && !H.disable_residual) { w.u(3, M.nlq_method); w.u(blDepth, M.nlq_pivots[0]); w.u(blDepth, M.nlq_pivots[1]); }
    w.ue(M.nx); w.ue(M.ny);
    const coef = c => { if (H.cdt === 0) w.se(c.i); w.u(coefLen, c.f); };
    for (const cv of M.curves) {
      for (const pc of cv.pieces) {
        w.ue(pc.idc);
        if (pc.idc === 0) { w.ue(pc.order); if (pc.order === 0) w.u(1, pc.lin); pc.c.forEach(coef); }
        else { w.u(2, pc.order); coef(pc.k0); pc.c.forEach(coef); }
      }
    }
    if (M.nlq && H.ext && !H.disable_residual) {
      const elDepth = (H.el_bit_depth_raw & 0xFF) + 8;
      for (const q of M.nlq) {
        w.u(elDepth, q.off);
        if (H.cdt === 0) w.ue(q.maxI);
        w.u(coefLen, q.max);
        if (H.cdt === 0) w.ue(q.slI);
        w.u(coefLen, q.sl);
        if (H.cdt === 0) w.ue(q.thI);
        w.u(coefLen, q.th);
      }
    }
  }
  if (D) {
    D.ids.forEach(v => w.ue(v));
    if (!D.compressed) DV_DM_FIXED.forEach((n, i) => w.u(n, D.fixed[i]));
    const blocks = list => {
      w.ue(list.length);
      w.align();
      for (const k of list) { w.ue(k.len); w.u(8, k.level); dvCopyBits(w, data, k.at, k.bits); }
    };
    blocks(D.cm29);
    if (D.cm40) blocks(D.cm40);
  }
  w.align();
  if (R.rest) dvCopyBits(w, data, R.rest.at, R.rest.bits);
  w.align();
  const body = w.out();
  const crc = hlsCrc32(body, 1, body.length);
  const out = new Uint8Array(body.length + 5 + R.tz);
  out.set(body);
  out[body.length] = crc >>> 24; out[body.length + 1] = (crc >>> 16) & 255;
  out[body.length + 2] = (crc >>> 8) & 255; out[body.length + 3] = crc & 255;
  out[body.length + 4] = 0x80;
  return out;
}

function dvRpuProfile(H) {
  if (H.vdr_rpu_profile === 0 && H.full_range) return 5;
  if (H.vdr_rpu_profile === 1) {
    if (H.el_spatial_resampling && !H.disable_residual) return H.vdr_bit_depth_minus8 === 4 ? 7 : 4;
    return 8;
  }
  return 0;
}
function dvRpuIsMel(M) {
  return !!M && !!M.nlq && M.nlq.every(q => q.off === 0 && q.maxI === 1 && q.max === 0
    && q.slI === 0 && q.sl === 0 && q.thI === 0 && q.th === 0);
}

/** P7 → 8.1；removeFelMapping=false 即 dovi_tool 的「保留映射」模式（只用于对照测试） */
function dvRpuTo81(R, removeFelMapping = true) {
  const H = R.H;
  const fel = R.M && R.M.nlq && !dvRpuIsMel(R.M);
  H.el_spatial_resampling = 0;
  H.disable_residual = 1;
  if (R.M) {
    delete R.M.nlq_method; delete R.M.nlq_pivots; delete R.M.nlq;
    R.M.nx = 0; R.M.ny = 0;
    if (fel && removeFelMapping) {
      for (const cv of R.M.curves) {
        cv.n = 0;
        cv.piv = [0, 1023];
        cv.pieces = [{ idc: 0, order: 0, lin: 0, c: [{ i: 0, f: 0 }, { i: 1, f: 0 }] }];
      }
    }
  }
  if (R.D && !R.D.compressed) {
    const s16 = v => (v + 65536) % 65536;
    for (let i = 0; i < 9; i++) R.D.fixed[i] = s16(DV_P81_YCC[i]);
    for (let i = 0; i < 3; i++) R.D.fixed[9 + i] = DV_P81_OFF[i];
    for (let i = 0; i < 9; i++) R.D.fixed[12 + i] = s16(DV_P81_LMS[i]);
  }
  return R;
}

/** 整个 RPU NAL（含 7C01 头）→ 8.1 RPU NAL；失败抛错 */
function dvConvertRpuNal(nal) {
  const R = dvRpuParse(dvRpuPayload(nal));
  if (dvRpuProfile(R.H) === 7) dvRpuTo81(R, true);
  const esc = nalEscape(dvRpuWrite(R));
  const out = new Uint8Array(esc.length + 2);
  out[0] = 0x7C; out[1] = 0x01;
  out.set(esc, 2);
  return out;
}

// ── MKV 块（SimpleBlock / BlockGroup）──

function hlsErr(msg, status = 422) { const e = new Error(msg); e.status = status; return e; }

/** 不把全 1 当「未知尺寸」的原始 vint（EBML lacing 的有符号差值要用） */
function ebmlVintRaw(u8, p, end) {
  if (p >= end) return null;
  const b = u8[p];
  let len = 1, mask = 0x80;
  while (len <= 8 && !(b & mask)) { mask >>= 1; len++; }
  if (len > 8 || p + len > end) return null;
  let v = b & (mask - 1);
  for (let i = 1; i < len; i++) v = v * 256 + u8[p + i];
  return [v, len];
}
function mkvBlockHead(u8, p, end) {
  const tv = ebmlVintRaw(u8, p, end);
  if (!tv) return null;
  const q = p + tv[1];
  if (q + 3 > end) return null;
  return { track: tv[0], rel: (((u8[q] << 8) | u8[q + 1]) << 16) >> 16, flags: u8[q + 2], data: q + 3 };
}
/** lacing → 每帧 [起, 止) 偏移 */
function mkvLaces(u8, p, end, flags) {
  const lacing = (flags >> 1) & 3;
  if (!lacing) return [[p, end]];
  const n = u8[p] + 1;
  let q = p + 1;
  const sizes = [];
  if (lacing === 1) {
    for (let i = 0; i < n - 1; i++) {
      let s = 0, b;
      do { b = u8[q++]; s += b; } while (b === 255 && q < end);
      sizes.push(s);
    }
  } else if (lacing === 3) {
    const f = ebmlVintRaw(u8, q, end);
    q += f[1];
    let last = f[0];
    sizes.push(last);
    for (let i = 1; i < n - 1; i++) {
      const v = ebmlVintRaw(u8, q, end);
      q += v[1];
      last += v[0] - (2 ** (7 * v[1] - 1) - 1);
      sizes.push(last);
    }
  } else {
    const each = (end - q) / n;
    for (let i = 0; i < n - 1; i++) sizes.push(each);
  }
  const out = [];
  let o = q;
  for (const s of sizes) {
    if (s < 0 || o + s > end) throw new Error('bad lacing');
    out.push([o, o + s]);
    o += s;
  }
  out.push([o, end]);
  return out;
}
/** 整个块元素都在缓冲区里时用（探测 / 字幕） */
function mkvParseBlockEl(u8, el) {
  let blk = el, dur = -1, ref = false;
  if (el.id === MKV.BlockGroup) {
    blk = null;
    for (const c of ebmlChildren(u8, el.data, el.end)) {
      if (c.id === MKV.Block) blk = c;
      else if (c.id === MKV.BlockDuration) dur = ebmlUint(u8, c.data, c.size);
      else if (c.id === MKV.ReferenceBlock) ref = true;
    }
    if (!blk) return null;
  }
  const h = mkvBlockHead(u8, blk.data, blk.end);
  if (!h) return null;
  return {
    track: h.track, rel: h.rel, dur,
    key: el.id === MKV.SimpleBlock ? !!(h.flags & 0x80) : !ref,
    frames: mkvLaces(u8, h.data, blk.end, h.flags).map(([a, b]) => u8.subarray(a, b)),
  };
}
/** 头部剥离压缩（ContentCompAlgo 3）：老版 mkvmerge 默认对 AC-3 / DTS 开这个 */
function hlsUnstrip(t, frame) {
  return t.strip ? hlsConcat([t.strip, frame]) : frame;
}

// ── Tracks / Cues ──

function mkvParseTracks(u8, a, b) {
  const tracks = [];
  for (const te of ebmlChildren(u8, a, b)) {
    if (te.id !== MKV.TrackEntry || te.cut) continue;
    const t = { num: 0, type: 0, codecId: '', priv: null, name: '', lang: 'eng', langBcp: '',
      def: true, forced: false, enabled: true, commentary: false, hi: false, dd: 0 };
    for (const c of ebmlChildren(u8, te.data, te.end)) {
      const U = () => ebmlUint(u8, c.data, c.size);
      switch (c.id) {
        case MKV.TrackNumber: t.num = U(); break;
        case MKV.TrackType: t.type = U(); break;
        case MKV.CodecID: t.codecId = ebmlStr(u8, c.data, c.size); break;
        case MKV.CodecPrivate: t.priv = u8.slice(c.data, c.end); break;
        case MKV.Name: t.name = ebmlStr(u8, c.data, c.size); break;
        case MKV.Language: t.lang = ebmlStr(u8, c.data, c.size); break;
        case MKV.LanguageBCP47: t.langBcp = ebmlStr(u8, c.data, c.size); break;
        case MKV.FlagDefault: t.def = !!U(); break;
        case MKV.FlagForced: t.forced = !!U(); break;
        case MKV.FlagEnabled: t.enabled = !!U(); break;
        case MKV.FlagCommentary: t.commentary = !!U(); break;
        case MKV.FlagHearingImpaired: t.hi = !!U(); break;
        case MKV.DefaultDuration: t.dd = U(); break;
        case MKV.Video: {
          const v = t.video = {};
          for (const x of ebmlChildren(u8, c.data, c.end)) {
            const X = () => ebmlUint(u8, x.data, x.size);
            if (x.id === MKV.PixelWidth) v.w = X();
            else if (x.id === MKV.PixelHeight) v.h = X();
            else if (x.id === MKV.DisplayWidth) v.dw = X();
            else if (x.id === MKV.DisplayHeight) v.dh = X();
            else if (x.id === MKV.DisplayUnit) v.du = X();
            else if (x.id === MKV.Colour) {
              const col = v.colour = {};
              for (const y of ebmlChildren(u8, x.data, x.end)) {
                const Y = () => ebmlUint(u8, y.data, y.size);
                if (y.id === MKV.MatrixCoefficients) col.mtx = Y();
                else if (y.id === MKV.TransferCharacteristics) col.trc = Y();
                else if (y.id === MKV.Primaries) col.prim = Y();
                else if (y.id === MKV.Range) col.range = Y();
                else if (y.id === MKV.MaxCLL) col.maxCLL = Y();
                else if (y.id === MKV.MaxFALL) col.maxFALL = Y();
                else if (y.id === MKV.MasteringMetadata) {
                  const m = col.mastering = {};
                  for (const z of ebmlChildren(u8, y.data, y.end)) m[z.id] = ebmlFloat(u8, z.data, z.size);
                }
              }
            }
          }
          break;
        }
        case MKV.Audio: {
          const au = t.audio = { rate: 8000, ch: 1 };
          for (const x of ebmlChildren(u8, c.data, c.end)) {
            if (x.id === MKV.SamplingFrequency) au.rate = Math.round(ebmlFloat(u8, x.data, x.size));
            else if (x.id === MKV.OutputSamplingFrequency) au.outRate = Math.round(ebmlFloat(u8, x.data, x.size));
            else if (x.id === MKV.Channels) au.ch = ebmlUint(u8, x.data, x.size);
            else if (x.id === MKV.BitDepth) au.bits = ebmlUint(u8, x.data, x.size);
          }
          break;
        }
        case MKV.ContentEncodings:
          for (const ce of ebmlChildren(u8, c.data, c.end)) {
            if (ce.id !== MKV.ContentEncoding) continue;
            let type = 0, algo = 0, settings = null;
            for (const x of ebmlChildren(u8, ce.data, ce.end)) {
              if (x.id === MKV.ContentEncodingType) type = ebmlUint(u8, x.data, x.size);
              else if (x.id === MKV.ContentCompression) {
                for (const y of ebmlChildren(u8, x.data, x.end)) {
                  if (y.id === MKV.ContentCompAlgo) algo = ebmlUint(u8, y.data, y.size);
                  else if (y.id === MKV.ContentCompSettings) settings = u8.slice(y.data, y.end);
                }
              }
            }
            if (type !== 0) t.encrypted = true;
            else if (algo === 3) t.strip = settings;
            else t.zlib = true;
          }
          break;
        case MKV.BlockAdditionMapping: {
          let type = 0, extra = null;
          for (const x of ebmlChildren(u8, c.data, c.end)) {
            if (x.id === MKV.BlockAddIDType) type = ebmlUint(u8, x.data, x.size);
            else if (x.id === MKV.BlockAddIDExtraData) extra = u8.slice(x.data, x.end);
          }
          // 'dvcC' / 'dvvC' / 'dvwC'
          if ((type === 0x64766343 || type === 0x64767643 || type === 0x64767743) && extra) t.dvcfg = extra;
          break;
        }
      }
    }
    tracks.push(t);
  }
  return tracks;
}

function mkvParseCues(u8, a, b) {
  const by = new Map();
  for (const cp of ebmlChildren(u8, a, b)) {
    if (cp.id !== MKV.CuePoint || cp.cut) continue;
    let t = 0;
    const tps = [];
    for (const c of ebmlChildren(u8, cp.data, cp.end)) {
      if (c.id === MKV.CueTime) t = ebmlUint(u8, c.data, c.size);
      else if (c.id === MKV.CueTrackPositions) {
        let tr = 0, cl = -1, rel = -1, dur = -1;
        for (const d of ebmlChildren(u8, c.data, c.end)) {
          const v = ebmlUint(u8, d.data, d.size);
          if (d.id === MKV.CueTrack) tr = v;
          else if (d.id === MKV.CueClusterPosition) cl = v;
          else if (d.id === MKV.CueRelativePosition) rel = v;
          else if (d.id === MKV.CueDuration) dur = v;
        }
        if (cl >= 0) tps.push([tr, cl, rel, dur]);
      }
    }
    for (const [tr, cl, rel, dur] of tps) {
      if (!by.has(tr)) by.set(tr, []);
      by.get(tr).push([t, cl, rel, dur]);
    }
  }
  for (const list of by.values()) list.sort((x, y) => x[0] - y[0] || x[1] - y[1]);
  return by;
}

// ── 视频时钟：标准帧率用精确有理数时基（23.976 → 24000/1001），帧时间戳可吸附到网格 ──

function hlsVideoClock(ddNs) {
  if (ddNs > 0) {
    const fps = 1e9 / ddNs;
    const STD = [[24000, 1001], [24, 1], [25, 1], [30000, 1001], [30, 1], [48000, 1001], [48, 1],
      [50, 1], [60000, 1001], [60, 1], [100, 1], [120000, 1001], [120, 1], [15, 1], [12, 1]];
    for (const [n, d] of STD) {
      const f = n / d;
      if (Math.abs(fps - f) / f < 0.0005) {
        return d === 1001 ? { ts: n, fd: 1001, fps: f } : { ts: 90000, fd: 90000 / n, fps: f };
      }
    }
    return { ts: 90000, fd: 0, fps };
  }
  return { ts: 90000, fd: 0, fps: 0 };
}

// ── 探测首簇：各轨第一帧（dac3/dec3 要从码流里读）、视频重排深度、杜比 RPU ──

function hlsProbe(u8, tracks, scaleNs) {
  const want = new Map(tracks.map(t => [t.num, t]));
  const out = { first: new Map(), video: [] };
  let clusterTs = 0;
  const walk = (a, b) => {
    for (const el of ebmlChildren(u8, a, b)) {
      if (el.id === MKV.Cluster) { walk(el.data, Math.min(b, el.end)); continue; }
      if (el.cut) return;
      if (el.id === MKV.Timestamp) { clusterTs = ebmlUint(u8, el.data, el.size); continue; }
      if (el.id !== MKV.SimpleBlock && el.id !== MKV.BlockGroup) continue;
      let blk;
      try { blk = mkvParseBlockEl(u8, el); } catch { continue; }
      if (!blk) continue;
      const t = want.get(blk.track);
      if (!t) continue;
      const ns = (clusterTs + blk.rel) * scaleNs;
      if (t.type === 1) {
        if (out.video.length < 96) out.video.push({ ns, key: blk.key, data: hlsUnstrip(t, blk.frames[0]) });
      } else if (!out.first.has(t.num)) {
        out.first.set(t.num, { ns, data: hlsUnstrip(t, blk.frames[0]), dur: blk.dur });
      }
    }
  };
  walk(0, u8.length);
  return out;
}

/** 解码顺序 PTS 序列 → 实际重排深度（SPS 拿不到时的兜底） */
function hlsReorderDepth(ptsList) {
  let r = 0;
  for (let j = 0; j < ptsList.length; j++) {
    let later = 0;
    for (let i = 0; i < j; i++) if (ptsList[i] > ptsList[j]) later++;
    if (later > r) r = later;
  }
  return r;
}

/** 在一帧（长度前缀或 Annex B 的 NAL 序列）里找杜比 RPU（62）与增强层（63） */
function hlsScanDvNals(frame, nalLen, annexB) {
  let rpu = null, el = false;
  for (const d of nalUnits(frame, nalLen, annexB)) {
    if (d.length < 2) continue;
    const type = (d[0] >> 1) & 0x3F;
    if (type === 62 && !rpu) rpu = d;
    else if (type === 63) el = true;
  }
  return { rpu, el };
}

// ── 轨道配置 ──

const HLS_TEXT_SUBS = new Set(['S_TEXT/UTF8', 'S_TEXT/ASCII', 'S_TEXT/ASS', 'S_TEXT/SSA', 'S_ASS', 'S_SSA', 'S_TEXT/WEBVTT']);

function hlsVideoConfig(t, probe, opts) {
  const v = { num: t.num, w: t.video?.w || 0, h: t.video?.h || 0, nalLen: 4, reorder: -1 };
  // 压缩 / 加密的帧连 NAL 都切不开：先挡掉，免得参数集扫描读一堆乱码
  if (t.encrypted || t.zlib) throw hlsErr('视频轨使用了压缩或加密的 ContentEncoding');
  let sps = {}, cfg = t.priv;
  if (t.codecId === 'V_MPEGH/ISO/HEVC' || t.codecId === 'V_MPEG4/ISO/AVC') {
    const hevc = t.codecId === 'V_MPEGH/ISO/HEVC';
    const pc = hlsParamConfig(hevc ? 'hevc' : 'avc', t, probe);
    cfg = pc.cfg;
    try { sps = (hevc ? hevcParseSps : avcParseSps)(pc.sps[0]); } catch {}
    if (hevc) {
      const hv = hevcParseHvcC(cfg);
      if (!hv) throw hlsErr('HEVC 配置无法解析');
      Object.assign(v, { codec: 'hevc', entry: 'hvc1', cfgType: 'hvcC', codecs: hevcCodecString(hv) });
    } else {
      const av = avcParseAvcC(cfg);
      if (!av) throw hlsErr('H.264 配置无法解析');
      if (sps.profile === 110 || sps.profile === 122 || sps.profile === 244) {
        throw hlsErr('H.264 10bit / 4:2:2 / 4:4:4 在 iOS 上没有硬件解码');
      }
      Object.assign(v, { codec: 'avc', entry: 'avc1', cfgType: 'avcC', codecs: avcCodecString(av) });
    }
    Object.assign(v, { nalLen: pc.nalLen, annexB: pc.annexB, psRebuilt: pc.rebuilt });
  } else if (t.codecId === 'V_AV1') {
    // 序列头：av1C 的 configOBUs 里有就用它，没有就从片头几帧里找（关键帧前必有一份）。
    // 它给两样东西：av1C 缺了时据此重建；MKV 没写 Colour 时据此判 PQ / HLG（不然 HDR 片会被标成 SDR）
    let a1 = av1Parse(t.priv);
    const seq = (t.priv && t.priv.length > 4 ? av1FindSeqHeader(t.priv.subarray(4)) : null)
      || probe.video.map(f => av1FindSeqHeader(f.data)).find(Boolean) || null;
    let si = null;
    try { si = seq && av1ParseSeqHeader(seq.payload); } catch { si = null; }
    if (!a1) {
      if (!si) throw hlsErr('AV1 配置缺失：没有 av1C，片头几帧里也找不到序列头');
      cfg = av1BuildAv1C(si, seq.obu);
      a1 = av1Parse(cfg);
      v.psRebuilt = true;
    }
    if (si) sps = { w: si.w, h: si.h, prim: si.prim, trc: si.trc, mtx: si.mtx, full: si.full };
    Object.assign(v, { codec: 'av1', entry: 'av01', cfgType: 'av1C', codecs: av1CodecString(a1), nalLen: 0 });
  } else {
    throw hlsErr(hlsUnsupportedVideo(t));
  }
  v.cfg = hlsB64(cfg);
  if (t.strip) v.strip = hlsB64(t.strip);
  v.w = v.w || sps.w || 0;
  v.h = v.h || sps.h || 0;

  // 时钟与 DTS 重排深度
  const clk = hlsVideoClock(t.dd);
  v.ts = clk.ts; v.fd = clk.fd; v.fps = clk.fps;
  const pts = probe.video.map(f => f.ns);
  if (!v.fps && pts.length > 2) {
    const s = pts.slice().sort((a, b) => a - b);
    let d = Infinity;
    for (let i = 1; i < s.length; i++) if (s[i] > s[i - 1]) d = Math.min(d, s[i] - s[i - 1]);
    if (Number.isFinite(d)) v.fps = 1e9 / d;
  }
  v.reorder = v.codec === 'av1' ? 0 : Math.max(sps.reorder >= 0 ? sps.reorder : 0, hlsReorderDepth(pts));
  v.anchor = pts.length ? Math.min(...pts.slice(0, 32)) : 0;

  // 色彩
  const col = t.video?.colour || {};
  const trc = col.trc ?? sps.trc, prim = col.prim ?? sps.prim, mtx = col.mtx ?? sps.mtx;
  const full = col.range === 2 ? 1 : col.range === 1 ? 0 : (sps.full || 0);
  if (trc != null && prim != null && mtx != null && trc !== 2) v.colr = [prim, trc, mtx, full];
  v.range = trc === 16 ? 'PQ' : trc === 18 ? 'HLG' : 'SDR';
  const m = col.mastering;
  if (m && m[MKV.LumMax]) {
    const c = x => Math.max(0, Math.min(65535, Math.round((x || 0) / 0.00002)));
    const md = new Uint8Array(24);
    const dv = new DataView(md.buffer);
    [[MKV.PrimaryGX, MKV.PrimaryGY], [MKV.PrimaryBX, MKV.PrimaryBY], [MKV.PrimaryRX, MKV.PrimaryRY]]
      .forEach(([x, y], i) => { dv.setUint16(i * 4, c(m[x])); dv.setUint16(i * 4 + 2, c(m[y])); });
    dv.setUint16(12, c(m[MKV.WhiteX])); dv.setUint16(14, c(m[MKV.WhiteY]));
    dv.setUint32(16, Math.round((m[MKV.LumMax] || 0) * 10000));
    dv.setUint32(20, Math.round((m[MKV.LumMin] || 0) * 10000));
    v.mdcv = hlsB64(md);
  }
  if (col.maxCLL || col.maxFALL) {
    const cl = new Uint8Array(4);
    new DataView(cl.buffer).setUint16(0, col.maxCLL || 0);
    new DataView(cl.buffer).setUint16(2, col.maxFALL || 0);
    v.clli = hlsB64(cl);
  }
  // 像素宽高比
  let sarW = sps.sarW || 1, sarH = sps.sarH || 1;
  const vid = t.video || {};
  if (vid.dw && vid.dh && (vid.du || 0) === 0 && v.w && v.h) {
    sarW = vid.dw * v.h; sarH = vid.dh * v.w;
    const g = (a, b) => b ? g(b, a % b) : a;
    const k = g(sarW, sarH) || 1;
    sarW /= k; sarH /= k;
    if (sarW > 65535 || sarH > 65535) { sarW = 1; sarH = 1; }
  }
  v.sar = [sarW, sarH];
  v.dw = Math.round(v.w * sarW / sarH) || v.w;

  // 杜比视界
  if (v.codec === 'hevc') hlsDvConfig(v, t, probe, opts);
  return v;
}

/** 进不了系统播放器的视频编码：说清是什么、为什么、怎么办（播放页原样展示这句话） */
function hlsUnsupportedVideo(t) {
  const id = String(t.codecId || '');
  const names = [
    [/^V_MPEG2/, 'MPEG-2'], [/^V_MPEG1/, 'MPEG-1'], [/^V_MPEG4\/ISO\/(ASP|SP|AP)/, 'MPEG-4 Part 2（DivX / Xvid）'],
    [/^V_MPEG4\/MS\//, '微软 MPEG-4'], [/^V_VP8/, 'VP8'], [/^V_VP9/, 'VP9'], [/^V_THEORA/, 'Theora'],
    [/^V_REAL\//, 'RealVideo'], [/^V_PRORES/, 'Apple ProRes'], [/^V_QUICKTIME/, 'QuickTime 旧式编码'],
    [/^V_UNCOMPRESSED/, '未压缩视频'], [/^V_FFV1/, 'FFV1'], [/^V_DIRAC/, 'Dirac'], [/^V_MJPEG/, 'Motion JPEG'],
  ];
  let name = (names.find(([re]) => re.test(id)) || [null, id || '未知编码'])[1];
  if (id === 'V_MS/VFW/FOURCC' && t.priv && t.priv.length >= 20) {
    const cc = String.fromCharCode(...t.priv.subarray(16, 20)).replace(/[^\x20-\x7e]/g, '').trim();
    const C = cc.toUpperCase();
    name = /^(WVC1|WMV3|WMVA)$/.test(C) ? `VC-1 / WMV（${cc}）`
      : /^(XVID|DIVX|DX50|FMP4|MP4V|DIV3|MP43)$/.test(C) ? `MPEG-4 Part 2（${cc}）`
      : /^(MJPG|AVRN|JPEG)$/.test(C) ? 'Motion JPEG'
      : /^(H264|X264|AVC1)$/.test(C) ? 'H.264（AVI 式的 VfW 封装，没有时间戳重排信息）'
      : `VfW 封装的 ${cc || '未知编码'}`;
  }
  return `视频是 ${name}，iPhone / iPad / Mac 的系统播放器解不了（支持 H.264、HEVC、AV1）。可以复制直链用 VLC 等播放器打开`;
}

function hlsDvConfig(v, t, probe, opts) {
  let cfg = t.dvcfg ? dvParseConfig(t.dvcfg) : null;
  let el = false, rpu = null;
  for (const f of probe.video.slice(0, 8)) {
    const s = hlsScanDvNals(f.data, v.nalLen, v.annexB);
    if (s.rpu && !rpu) rpu = s.rpu;
    if (s.el) el = true;
  }
  if (!cfg && rpu) {
    try {
      const R = dvRpuParse(dvRpuPayload(rpu));
      const profile = dvRpuProfile(R.H);
      if (profile) {
        cfg = { major: 1, minor: 0, profile, level: dvLevelFor(v.w, v.h, v.fps), rpu: 1, el: el ? 1 : 0, bl: 1,
          compat: profile === 5 ? 0 : profile === 7 ? 6 : v.range === 'HLG' ? 4 : v.range === 'SDR' ? 2 : 1 };
      }
    } catch {}
  }
  if (!cfg || ![5, 7, 8].includes(cfg.profile)) return;
  if (!cfg.level) cfg.level = dvLevelFor(v.w, v.h, v.fps);
  const mode = opts.dv;                         // 'auto' | 'dvh1' | 'off'
  const lvl = String(cfg.level).padStart(2, '0');
  if (cfg.profile === 5) {
    // P5 的基础层是 IPTPQc2，脱离杜比管线就是偏色画面 —— 'off' 对它无效
    v.dv = { profile: 5, level: cfg.level, box: 'dvcC', cfg: hlsB64(dvBuildConfig({ ...cfg, el: 0 })) };
    v.entry = 'dvh1';
    v.codecs = `dvh1.05.${lvl}`;
    v.range = 'PQ';
    delete v.colr;
    return;
  }
  if (cfg.profile === 7) {
    // 先拿首帧的 RPU 试转一次：转不动就整条退回 HDR10（丢 RPU 与增强层），绝不输出半坏的 DV
    let ok = !!rpu;
    if (rpu) { try { dvConvertRpuNal(rpu); } catch { ok = false; } }
    v.dvStrip = mode === 'off' || !ok;
    v.dvConvert = !v.dvStrip;
    if (v.dvStrip) return;
    cfg = { ...cfg, profile: 8, el: 0, compat: 1 };
  }
  if (mode === 'off') return;
  const compat = cfg.compat;
  const brand = compat === 4 ? 'db4h' : compat === 2 ? 'db2g' : 'db1p';
  v.range = compat === 4 ? 'HLG' : compat === 2 ? 'SDR' : 'PQ';
  v.dv = { profile: 8, level: cfg.level, compat, box: 'dvvC', cfg: hlsB64(dvBuildConfig({ ...cfg, profile: 8, el: 0, rpu: 1, bl: 1 })) };
  if (mode === 'dvh1') { v.entry = 'dvh1'; v.codecs = `dvh1.08.${lvl}`; }
  else v.supp = `dvh1.08.${lvl}/${brand}`;
}

/** 音频：能直通的编码给出 fMP4 所需的一切；DTS / TrueHD 等标记为需要转码 */
function hlsAudioConfig(t, first) {
  const a = { num: t.num, lang: hlsLang(t), name: t.name, def: t.def, forced: t.forced,
    commentary: t.commentary || /comment|评论|解说/i.test(t.name || ''), codecId: t.codecId,
    mode: 'none', ch: t.audio?.ch || 2 };
  if (t.encrypted || t.zlib) return a;
  if (t.strip) a.strip = hlsB64(t.strip);
  const id = t.codecId;
  const data = first?.data;
  try {
    if (id === 'A_AAC' || id.startsWith('A_AAC/')) {
      const rate = t.audio?.rate || 48000;
      const asc = t.priv && t.priv.length >= 2 ? t.priv : aacBuildAsc(id, rate, a.ch, t.audio?.outRate);
      const info = aacParseAsc(asc);
      if (!info) return a;
      a.ts = info.outRate || t.audio?.outRate || rate;
      a.fs = t.dd ? Math.round(t.dd * a.ts / 1e9) : (info.outRate > info.rate ? 2048 : 1024);
      Object.assign(a, { mode: 'copy', codec: 'aac', entry: 'mp4a', cfg: hlsB64(asc),
        codecs: `mp4a.40.${info.aot}`, ch: info.ch || a.ch });
    } else if (id === 'A_AC3' || id === 'A_EAC3') {
      const au = data ? ac3ParseAccessUnit(data) : [];
      if (!au.length) return a;
      const h = au[0];
      a.ts = h.rate;
      a.fs = 256 * h.blocks;
      if (!h.eac3 && au.length === 1) {
        Object.assign(a, { mode: 'copy', codec: 'ac3', entry: 'ac-3', cfg: hlsB64(ac3Dac3(h)), codecs: 'ac-3', ch: h.ch });
      } else {
        const dec3 = eac3Dec3(au);
        if (!dec3) return a;
        let ch = h.ch;
        for (const s of au.slice(1)) if (s.strmtyp === 1) ch = Math.max(ch, 8);
        Object.assign(a, { mode: 'copy', codec: 'eac3', entry: 'ec-3', cfg: hlsB64(dec3), codecs: 'ec-3', ch });
        if (h.joc) a.joc = h.jocCx || 16;
      }
    } else if (id === 'A_FLAC') {
      const f = flacParsePrivate(t.priv);
      if (!f) return a;
      Object.assign(a, { mode: 'copy', codec: 'flac', entry: 'fLaC', cfg: hlsB64(f.dfla), codecs: 'fLaC',
        ts: f.rate, fs: f.fixed, ch: f.ch, bits: f.bits });
    } else if (id === 'A_ALAC') {
      const f = alacParsePrivate(t.priv);
      if (!f) return a;
      Object.assign(a, { mode: 'copy', codec: 'alac', entry: 'alac', cfg: hlsB64(f.cfg), codecs: 'alac',
        ts: f.rate, fs: f.frame, ch: f.ch, bits: f.bits });
    } else {
      hlsTxConfig(a, t, first);
    }
  } catch {}
  if (a.mode === 'copy') a.anchor = first ? Math.round(first.ns * a.ts / 1e9) : 0;
  return a;
}

/** Safari 解不了的编码：记下源参数，输出定为 AC-3（需要绑定转码 Worker 才会出现在播放列表里） */
function hlsTxKind(id, bits) {
  if (id.startsWith('A_DTS')) return 1;
  if (id === 'A_TRUEHD') return 2;
  if (id === 'A_MLP') return 3;
  if (id === 'A_OPUS') return 4;
  if (id === 'A_VORBIS') return 5;
  if (id === 'A_PCM/INT/LIT') return { 8: 14, 16: 6, 24: 7, 32: 8 }[bits] || 0;
  if (id === 'A_PCM/FLOAT/IEEE') return bits === 32 ? 9 : 0;
  if (id === 'A_PCM/INT/BIG') return { 16: 10, 24: 11 }[bits] || 0;
  if (id === 'A_MPEG/L2') return 12;
  if (id === 'A_MPEG/L3') return 13;
  return 0;
}
function hlsTxConfig(a, t, first) {
  const kind = hlsTxKind(t.codecId, t.audio?.bits || 0);
  if (!kind) return;
  const rate = t.audio?.rate || 48000;
  const outRate = rate === 44100 || rate === 32000 ? rate : 48000;
  const outCh = a.ch >= 3 ? 6 : a.ch === 1 ? 1 : 2;
  const kbps = outCh === 6 ? 640 : outCh === 2 ? 256 : 128;
  // 源帧时长：决定帧时间戳吸附到哪个网格（TrueHD 一个访问单元 = 1/1200 s）
  let frameNs = t.dd || 0;
  if (!frameNs && (kind === 2 || kind === 3)) frameNs = 1e9 / (rate % 44100 === 0 ? 1102.5 : 1200);
  if (!frameNs && (kind === 12 || kind === 13)) frameNs = 1152 * 1e9 / rate;
  a.tx = { kind, rate, ch: a.ch, bits: t.audio?.bits || 0,
    extra: (kind === 4 || kind === 5) && t.priv ? hlsB64(t.priv) : null,
    frameNs, anchorNs: first ? first.ns : 0, srcCodec: t.codecId };
  Object.assign(a, {
    mode: 'tx', codec: 'ac3', entry: 'ac-3', codecs: 'ac-3', ts: outRate, fs: 1536, ch: outCh,
    bitrate: kbps * 1000, anchor: first ? Math.round(first.ns * outRate / 1e9) : 0,
    cfg: hlsB64(ac3Dac3({ fscod: outRate === 48000 ? 0 : outRate === 44100 ? 1 : 2, bsid: 8, bsmod: 0,
      acmod: outCh === 6 ? 7 : outCh === 2 ? 2 : 1, lfeon: outCh === 6 ? 1 : 0,
      frmsizecod: AC3_KBPS.indexOf(kbps) * 2 })),
  });
  if (t.strip) a.strip = hlsB64(t.strip);
}

const HLS_CODEC_LABEL = { aac: 'AAC', ac3: 'Dolby Digital', eac3: 'Dolby Digital Plus', flac: 'FLAC', alac: 'ALAC' };
function hlsChLabel(ch) { return ch === 8 ? '7.1' : ch === 6 ? '5.1' : ch === 2 ? '立体声' : ch === 1 ? '单声道' : `${ch}ch`; }
const HLS_TX_LABEL = { 1: 'DTS', 2: 'TrueHD', 3: 'MLP', 4: 'Opus', 5: 'Vorbis', 12: 'MP2', 13: 'MP3' };
function hlsAudioLabel(a) {
  let s = a.name || hlsLangName(a.lang);
  const hasCodec = /(dd|ac-?3|e-?ac-?3|dolby|aac|flac|alac|atmos|truehd|dts|pcm|opus|vorbis|mp3)/i.test(a.name || '');
  if (a.tx) s += ` · ${HLS_TX_LABEL[a.tx.kind] || 'PCM'} → Dolby Digital ${hlsChLabel(a.ch)}`;
  else if (!hasCodec) s += ` · ${HLS_CODEC_LABEL[a.codec] || a.codec} ${hlsChLabel(a.ch)}${a.joc ? ' Atmos' : ''}`;
  if (a.commentary && !/comment|评论|解说/i.test(s)) s += '（评论音轨）';
  return s;
}

// ── 索引 ──

/**
 * src = { size, read(start, end) → Promise<Uint8Array> }
 * 只读三四段小 Range：文件头、（必要时）Info/Tracks、Cues、首簇前 2MB。
 */
async function hlsBuildIndex(src, opts) {
  const size = src.size;
  const head = await src.read(0, Math.min(size, HLS_HEAD) - 1);
  const it = ebmlChildren(head, 0, head.length);
  const e0 = it.next().value;
  if (!e0 || e0.id !== MKV.EBML || e0.cut) throw hlsErr('不是 Matroska 文件');
  const dt = ebmlMap(head, e0.data, e0.end).get(MKV.DocType);
  const docType = dt ? ebmlStr(head, dt.data, dt.size) : 'matroska';
  if (docType !== 'matroska' && docType !== 'webm') throw hlsErr(`不支持的 DocType: ${docType}`);
  const segId = ebmlId(head, e0.end, head.length), segSz = segId && ebmlSize(head, e0.end + segId[1], head.length);
  if (!segId || segId[0] !== MKV.Segment || !segSz) throw hlsErr('找不到 Segment');
  const segStart = e0.end + segId[1] + segSz[1];
  const segEnd = segSz[0] > 0 ? Math.min(size, segStart + segSz[0]) : size;

  // 顶层元素：一路跳到第一个 Cluster（附件等大元素按尺寸跳过，不读内容）
  const top = new Map();
  let firstCluster = -1;
  let buf = head, bufAt = 0;
  for (let q = segStart, guard = 0; q < segEnd && guard < 512; guard++) {
    if (q + 16 > bufAt + buf.length) {
      buf = await src.read(q, Math.min(segEnd, q + 65536) - 1);
      bufAt = q;
    }
    const o = q - bufAt;
    const id = ebmlId(buf, o, buf.length), sz = id && ebmlSize(buf, o + id[1], buf.length);
    if (!id || !sz) break;
    if (id[0] === MKV.Cluster) { firstCluster = q; break; }
    if (!top.has(id[0])) top.set(id[0], { pos: q, data: q + id[1] + sz[1], size: sz[0] });
    if (sz[0] < 0) break;
    q += id[1] + sz[1] + sz[0];
  }
  const load = async el => {
    if (!el || el.size < 0) return null;
    if (el.size > 32 * 1048576) throw hlsErr('索引元素过大');
    if (el.data >= 0 && el.data + el.size <= head.length) return head.subarray(el.data, el.data + el.size);
    return src.read(el.data, el.data + el.size - 1);
  };
  const loadAt = async pos => {
    const h = await src.read(pos, Math.min(size, pos + 16) - 1);
    const id = ebmlId(h, 0, h.length), sz = id && ebmlSize(h, id[1], h.length);
    if (!id || !sz) return null;
    return { id: id[0], pos, data: pos + id[1] + sz[1], size: sz[0] };
  };

  // SeekHead：Cues 通常在文件尾，只有这里知道它在哪
  const seeks = new Map();
  const readSeeks = async el => {
    const d = await load(el);
    if (!d) return;
    for (const s of ebmlChildren(d, 0, d.length)) {
      if (s.id !== MKV.Seek) continue;
      let sid = 0, spos = -1;
      for (const c of ebmlChildren(d, s.data, s.end)) {
        if (c.id === MKV.SeekID) sid = ebmlUint(d, c.data, c.size);
        else if (c.id === MKV.SeekPosition) spos = ebmlUint(d, c.data, c.size);
      }
      if (sid && spos >= 0 && !seeks.has(sid)) seeks.set(sid, segStart + spos);
    }
  };
  const sh = top.get(MKV.SeekHead);
  if (sh) {
    await readSeeks(sh);
    // 有的封装器把 Cues 登记在文件尾的第二个 SeekHead 里，开头那个只指向它
    const second = seeks.get(MKV.SeekHead);
    if (!seeks.has(MKV.Cues) && second && second !== sh.pos) {
      const el = await loadAt(second);
      if (el && el.id === MKV.SeekHead) await readSeeks(el);
    }
  }
  const element = async id => top.get(id) || (seeks.has(id) ? await loadAt(seeks.get(id)) : null);

  const infoEl = await element(MKV.Info);
  const infoD = await load(infoEl);
  let scaleNs = 1000000, durUnits = 0;
  if (infoD) {
    for (const c of ebmlChildren(infoD, 0, infoD.length)) {
      if (c.id === MKV.TimestampScale) scaleNs = ebmlUint(infoD, c.data, c.size) || 1000000;
      else if (c.id === MKV.Duration) durUnits = ebmlFloat(infoD, c.data, c.size);
    }
  }
  const tracksD = await load(await element(MKV.Tracks));
  if (!tracksD) throw hlsErr('找不到 Tracks');
  const tracks = mkvParseTracks(tracksD, 0, tracksD.length);

  let cuesEl = await element(MKV.Cues);
  if (!cuesEl) {
    // 没登记在 SeekHead 里：去文件尾找 Cues 的 ID
    const tailStart = Math.max(0, size - 8 * 1048576);
    const tail = await src.read(tailStart, size - 1);
    for (let i = tail.length - 8; i >= 0 && !cuesEl; i--) {
      if (tail[i] === 0x1C && tail[i + 1] === 0x53 && tail[i + 2] === 0xBB && tail[i + 3] === 0x6B) {
        const sz = ebmlSize(tail, i + 4, tail.length);
        if (sz && sz[0] > 0 && i + 4 + sz[1] + sz[0] <= tail.length && tail[i + 4 + sz[1]] === MKV.CuePoint) {
          cuesEl = { pos: tailStart + i, data: tailStart + i + 4 + sz[1], size: sz[0] };
        }
      }
    }
  }
  const cuesD = await load(cuesEl);
  if (!cuesD) throw hlsErr('没有 Cues 关键帧索引，无法分段（可用 mkvmerge 重新封装一次）');
  const cues = mkvParseCues(cuesD, 0, cuesD.length);

  const vt = tracks.filter(t => t.type === 1 && t.enabled)
    .sort((a, b) => (b.def ? 1 : 0) - (a.def ? 1 : 0))[0];
  if (!vt) throw hlsErr('没有视频轨');
  const vcues = (cues.get(vt.num) || []).filter((c, i, l) => i === 0 || c[0] !== l[i - 1][0]);
  if (!vcues.length) throw hlsErr('Cues 里没有视频关键帧');
  if (firstCluster < 0) firstCluster = segStart + Math.min(...vcues.map(c => c[1]));

  // 首簇探测
  const probeTracks = tracks.filter(t => t === vt || t.type === 2);
  let probeBuf = await src.read(firstCluster, Math.min(segEnd, firstCluster + HLS_PROBE) - 1);
  let probe = hlsProbe(probeBuf, probeTracks, scaleNs);
  const audioTracks = tracks.filter(t => t.type === 2);
  if (audioTracks.some(t => !probe.first.has(t.num)) && probeBuf.length >= HLS_PROBE) {
    probeBuf = await src.read(firstCluster, Math.min(segEnd, firstCluster + 4 * HLS_PROBE) - 1);
    probe = hlsProbe(probeBuf, probeTracks, scaleNs);
  }

  const video = hlsVideoConfig(vt, probe, opts);
  const audio = audioTracks.map(t => hlsAudioConfig(t, probe.first.get(t.num)));

  // 复用进视频分片的默认音轨：MKV 默认轨能直通就用它；
  // 不能（TrueHD / DTS）就找同语言的可直通轨（蓝光 remux 通常附带 AC-3 兼容轨）
  const copyable = audio.filter(a => a.mode === 'copy');
  const defT = audio.find(a => a.def) || audio[0];
  let muxed = -1;
  if (copyable.length) {
    let pick = defT && defT.mode === 'copy' ? defT : null;
    if (!pick && defT) pick = copyable.find(a => a.lang === defT.lang && !a.commentary);
    if (!pick) pick = copyable.find(a => !a.commentary) || copyable[0];
    muxed = audio.indexOf(pick);
  }

  // 字幕
  const subs = [];
  for (const t of tracks) {
    if (t.type !== 17 || !HLS_TEXT_SUBS.has(t.codecId) || t.encrypted) continue;
    subs.push({
      num: t.num, lang: hlsLang(t), name: t.name, def: t.def, forced: t.forced, hi: t.hi,
      fmt: /ASS|SSA/.test(t.codecId) ? 'ass' : /WEBVTT/.test(t.codecId) ? 'vtt' : 'srt',
      strip: t.strip ? hlsB64(t.strip) : null, zlib: !!t.zlib,
      cues: (cues.get(t.num) || []).map(c => [c[0], c[3], c[1], c[2]]),
    });
  }
  // 图形字幕（PGS / VobSub / DVB）放不进 WebVTT，但它的时间是这个文件自己的 —— 在线字幕对齐拿它当参照。
  // Cues 里每一个显示集（出现、消失各一个）都有时刻，只记毫秒数，不读一个字节
  const subRefs = [];
  for (const t of tracks) {
    if (t.type !== 17 || HLS_TEXT_SUBS.has(t.codecId)) continue;
    const list = cues.get(t.num) || [];
    if (list.length < 60) continue;
    subRefs.push({ num: t.num, lang: hlsLang(t), codec: t.codecId, forced: !!t.forced,
      t: list.map(c => Math.round(c[0] * scaleNs / 1e6)) });
  }

  // 分段：以视频关键帧为界，尽量贴近目标时长，并且不让单段超过目标 0.5s 以上
  const toSec = u => u * scaleNs / 1e9;
  const durSec = durUnits ? toSec(durUnits) : toSec(vcues[vcues.length - 1][0]) + 1;
  const target = opts.segSec || 6;
  const firstTargets = [Math.min(2, target), Math.min(4, target)];
  const segs = [{ cl: firstCluster - segStart, rel: -2, t: 0 }];
  let startT = 0;
  for (let i = 0; i < vcues.length; i++) {
    const t = toSec(vcues[i][0]);
    const tgt = segs.length <= firstTargets.length ? firstTargets[segs.length - 1] : target;
    const el = t - startT;
    if (el < Math.min(1, tgt * 0.5)) continue;
    const next = i + 1 < vcues.length ? toSec(vcues[i + 1][0]) : durSec;
    if (el >= tgt - 0.01 || (next - startT) > tgt + 0.5) {
      segs.push({ cl: vcues[i][1], rel: vcues[i][2], t: vcues[i][0] });
      startT = t;
    }
  }
  // 簇区终点：簇后面第一个已知顶层元素（Cues / Tags …）
  let clustersEnd = segEnd;
  for (const pos of [cuesEl?.pos, ...seeks.values(), ...[...top.values()].map(e => e.pos)]) {
    if (pos != null && pos > firstCluster && pos < clustersEnd) clustersEnd = pos;
  }
  const durs = segs.map((s, i) => (i + 1 < segs.length ? toSec(segs[i + 1].t) : durSec) - toSec(s.t));
  let peak = 0, total = 0;
  segs.forEach((s, i) => {
    const a = segStart + s.cl, b = i + 1 < segs.length ? segStart + segs[i + 1].cl : clustersEnd;
    const bits = Math.max(0, b - a) * 8;
    total += bits;
    if (durs[i] > 0.5) peak = Math.max(peak, bits / durs[i]);
  });

  return {
    v: HLS_VER, size, scaleNs, segStart, firstCluster, clustersEnd, dur: durSec,
    video, audio, muxed, subs, subRefs,
    segs: segs.map(s => [s.cl, s.rel, s.t]),
    durs: durs.map(d => Math.max(0.001, Math.round(d * 1000) / 1000)),
    bw: { peak: Math.ceil(peak * 1.1), avg: Math.ceil(total / Math.max(1, durSec)) },
  };
}

// ── fMP4（ISO BMFF）写入 ──

const be16 = v => [(v >>> 8) & 255, v & 255];
const be32 = v => [(v >>> 24) & 255, (v >>> 16) & 255, (v >>> 8) & 255, v & 255];
function mp4Box(type, ...parts) {
  const list = [];
  let len = 8;
  for (const p of parts) {
    if (p == null) continue;
    const u = p instanceof Uint8Array ? p : Uint8Array.from(p);
    list.push(u);
    len += u.length;
  }
  const out = new Uint8Array(len);
  new DataView(out.buffer).setUint32(0, len);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  let o = 8;
  for (const u of list) { out.set(u, o); o += u.length; }
  return out;
}
function mp4Full(type, ver, flags, ...parts) {
  return mp4Box(type, [ver, (flags >>> 16) & 255, (flags >>> 8) & 255, flags & 255], ...parts);
}
const MP4_MATRIX = [...be32(0x00010000), ...be32(0), ...be32(0), ...be32(0), ...be32(0x00010000),
  ...be32(0), ...be32(0), ...be32(0), ...be32(0x40000000)];

function mp4Lang(lang) {
  const map = { zh: 'zho', 'zh-Hans': 'zho', 'zh-Hant': 'zho', yue: 'yue', en: 'eng', ja: 'jpn', ko: 'kor',
    fr: 'fra', de: 'deu', es: 'spa', it: 'ita', ru: 'rus', pt: 'por' };
  const c = (map[lang] || (/^[a-z]{3}$/.test(lang) ? lang : 'und'));
  return ((c.charCodeAt(0) - 0x60) << 10) | ((c.charCodeAt(1) - 0x60) << 5) | (c.charCodeAt(2) - 0x60);
}

/** MPEG-4 描述符长度（ESDS 用 4 字节扩展写法，最稳） */
function mp4Desc(tag, body) {
  const n = body.length;
  return [tag, 0x80 | ((n >> 21) & 127), 0x80 | ((n >> 14) & 127), 0x80 | ((n >> 7) & 127), n & 127, ...body];
}
function mp4Esds(asc, oti = 0x40) {
  const dsi = mp4Desc(0x05, [...asc]);
  const dcd = mp4Desc(0x04, [oti, 0x15, 0, 0, 0, ...be32(0), ...be32(0), ...dsi]);
  const es = mp4Desc(0x03, [0, 0, 0, ...dcd, ...mp4Desc(0x06, [0x02])]);
  return mp4Full('esds', 0, 0, es);
}

function mp4VideoEntry(v) {
  const head = new Uint8Array(78);
  const dv = new DataView(head.buffer);
  dv.setUint16(6, 1);
  dv.setUint16(24, v.w); dv.setUint16(26, v.h);
  dv.setUint32(28, 0x00480000); dv.setUint32(32, 0x00480000);
  dv.setUint16(40, 1);
  dv.setUint16(74, 0x0018); dv.setInt16(76, -1);
  const kids = [mp4Box(v.cfgType, hlsUnB64(v.cfg))];
  if (v.dv) kids.push(mp4Box(v.dv.box, hlsUnB64(v.dv.cfg)));
  if (v.colr) {
    kids.push(mp4Box('colr', [0x6E, 0x63, 0x6C, 0x78], be16(v.colr[0]), be16(v.colr[1]), be16(v.colr[2]),
      [v.colr[3] ? 0x80 : 0]));
  }
  if (v.mdcv) kids.push(mp4Box('mdcv', hlsUnB64(v.mdcv)));
  if (v.clli) kids.push(mp4Box('clli', hlsUnB64(v.clli)));
  kids.push(mp4Box('pasp', be32(v.sar[0]), be32(v.sar[1])));
  return mp4Box(v.entry, head, ...kids);
}

function mp4AudioEntry(a) {
  const head = new Uint8Array(28);
  const dv = new DataView(head.buffer);
  dv.setUint16(6, 1);
  dv.setUint16(16, a.ch);
  dv.setUint16(18, a.bits && a.bits > 16 ? a.bits : 16);
  dv.setUint32(24, a.ts <= 65535 ? a.ts * 65536 : 0);
  const cfg = hlsUnB64(a.cfg);
  let box;
  if (a.codec === 'aac') box = mp4Esds(cfg);
  else if (a.codec === 'ac3') box = mp4Box('dac3', cfg);
  else if (a.codec === 'eac3') box = mp4Box('dec3', cfg);
  else if (a.codec === 'flac') box = mp4Full('dfLa', 0, 0, cfg);
  else if (a.codec === 'alac') box = mp4Full('alac', 0, 0, cfg);
  return mp4Box(a.entry, head, box);
}

function mp4Trak(id, kind, ts, lang, entry, w = 0, h = 0) {
  const video = kind === 'v';
  const tkhd = mp4Full('tkhd', 0, 3, be32(0), be32(0), be32(id), be32(0), be32(0), be32(0), be32(0),
    be16(0), be16(video ? 0 : 1), be16(video ? 0 : 0x0100), be16(0), MP4_MATRIX,
    be32(w * 65536), be32(h * 65536));
  const mdhd = mp4Full('mdhd', 0, 0, be32(0), be32(0), be32(ts), be32(0), be16(mp4Lang(lang)), be16(0));
  const name = video ? 'VideoHandler' : 'SoundHandler';
  const hdlr = mp4Full('hdlr', 0, 0, be32(0), [...(video ? 'vide' : 'soun')].map(c => c.charCodeAt(0)),
    be32(0), be32(0), be32(0), [...name].map(c => c.charCodeAt(0)), [0]);
  const mhd = video ? mp4Full('vmhd', 0, 1, be16(0), be16(0), be16(0), be16(0)) : mp4Full('smhd', 0, 0, be16(0), be16(0));
  const dinf = mp4Box('dinf', mp4Full('dref', 0, 0, be32(1), mp4Full('url ', 0, 1)));
  const stbl = mp4Box('stbl', mp4Full('stsd', 0, 0, be32(1), entry), mp4Full('stts', 0, 0, be32(0)),
    mp4Full('stsc', 0, 0, be32(0)), mp4Full('stsz', 0, 0, be32(0), be32(0)), mp4Full('stco', 0, 0, be32(0)));
  return mp4Box('trak', tkhd, mp4Box('mdia', mdhd, hdlr, mp4Box('minf', mhd, dinf, stbl)));
}

/** init 段：tracks = [{ id, kind:'v'|'a', cfg }] */
function mp4Init(tracks, dvBrand) {
  const brands = ['iso6', 'iso5', 'mp41', 'dash'];
  if (dvBrand) brands.push('dby1');
  const ftyp = mp4Box('ftyp', [...'iso6'].map(c => c.charCodeAt(0)), be32(0),
    ...brands.map(b => [...b].map(c => c.charCodeAt(0))));
  const mvhd = mp4Full('mvhd', 0, 0, be32(0), be32(0), be32(1000), be32(0), be32(0x00010000), be16(0x0100),
    be16(0), be32(0), be32(0), MP4_MATRIX, new Uint8Array(24), be32(tracks.length + 1));
  const traks = tracks.map(t => t.kind === 'v'
    ? mp4Trak(t.id, 'v', t.cfg.ts, 'und', mp4VideoEntry(t.cfg), t.cfg.dw, t.cfg.h)
    : mp4Trak(t.id, 'a', t.cfg.ts, t.cfg.lang, mp4AudioEntry(t.cfg)));
  const mvex = mp4Box('mvex', ...tracks.map(t => mp4Full('trex', 0, 0, be32(t.id), be32(1), be32(0), be32(0), be32(0))));
  return hlsConcat([ftyp, mp4Box('moov', mvhd, ...traks, mvex)]);
}

/**
 * 一个 moof + mdat。返回 [头部字节, ...负载切片]：负载直接引用回源缓冲区，零拷贝。
 * runs = [{ id, video, base, samples:[{ dur, size, flags, cto, pieces }] }]
 */
function mp4Fragment(seq, runs) {
  const trafs = [];
  let moofSize = 8 + 16;
  for (const r of runs) {
    if (!r.samples.length) continue;
    const neg = r.video && r.samples.some(s => s.cto < 0);
    const per = r.video ? 16 : 8;
    const tfhd = r.video ? 16 : 20;
    const trun = 20 + r.samples.length * per;
    const size = 8 + tfhd + 20 + trun;
    trafs.push({ r, neg, per, tfhd, trun, size });
    moofSize += size;
  }
  const head = new Uint8Array(moofSize + 8);
  const dv = new DataView(head.buffer);
  let o = 0;
  const box = (size, type) => {
    dv.setUint32(o, size);
    for (let i = 0; i < 4; i++) head[o + 4 + i] = type.charCodeAt(i);
    o += 8;
  };
  box(moofSize, 'moof');
  box(16, 'mfhd'); dv.setUint32(o, 0); dv.setUint32(o + 4, seq); o += 8;
  let data = moofSize + 8;
  const pieces = [];
  for (const tr of trafs) {
    const r = tr.r;
    box(tr.size, 'traf');
    box(tr.tfhd, 'tfhd');
    dv.setUint32(o, r.video ? 0x020000 : 0x020020); dv.setUint32(o + 4, r.id); o += 8;
    if (!r.video) { dv.setUint32(o, 0x02000000); o += 4; }
    box(20, 'tfdt');
    dv.setUint32(o, 0x01000000);
    dv.setUint32(o + 4, Math.floor(r.base / 4294967296)); dv.setUint32(o + 8, r.base >>> 0);
    o += 12;
    box(tr.trun, 'trun');
    dv.setUint32(o, ((tr.neg ? 1 : 0) << 24) | (r.video ? 0x000F01 : 0x000301));
    dv.setUint32(o + 4, r.samples.length);
    dv.setInt32(o + 8, data);
    o += 12;
    for (const s of r.samples) {
      dv.setUint32(o, s.dur); dv.setUint32(o + 4, s.size); o += 8;
      if (r.video) {
        dv.setUint32(o, s.flags);
        if (tr.neg) dv.setInt32(o + 4, s.cto); else dv.setUint32(o + 4, s.cto);
        o += 8;
      }
      data += s.size;
      for (const p of s.pieces) pieces.push(p);
    }
  }
  dv.setUint32(o, data - moofSize);
  head[o + 4] = 0x6D; head[o + 5] = 0x64; head[o + 6] = 0x61; head[o + 7] = 0x74;
  return [head, ...pieces];
}

// ── 分片流水线 ──

/** 零拷贝字节队列：只记引用，take() 给出的是原缓冲区上的子视图 */
class HlsQueue {
  constructor(pos) { this.bufs = []; this.off = 0; this.len = 0; this.pos = pos; this.drop = 0; }
  push(u8) {
    if (this.drop) {
      const d = Math.min(this.drop, u8.length);
      this.drop -= d; this.pos += d;
      u8 = u8.subarray(d);
    }
    if (u8.length) { this.bufs.push(u8); this.len += u8.length; }
  }
  peek(n) {
    const m = Math.min(n, this.len);
    const b0 = this.bufs[0];
    if (b0 && b0.length - this.off >= m) return b0.subarray(this.off, this.off + m);
    const out = new Uint8Array(m);
    let o = 0, i = 0, off = this.off;
    while (o < m) {
      const b = this.bufs[i++];
      const t = Math.min(m - o, b.length - off);
      out.set(b.subarray(off, off + t), o);
      o += t; off = 0;
    }
    return out;
  }
  _advance(n, keep) {
    const out = keep ? [] : null;
    let left = n;
    while (left > 0) {
      const b = this.bufs[0];
      const t = Math.min(b.length - this.off, left);
      if (keep) out.push(b.subarray(this.off, this.off + t));
      left -= t; this.off += t;
      if (this.off === b.length) { this.bufs.shift(); this.off = 0; }
    }
    this.len -= n; this.pos += n;
    return out;
  }
  take(n) { return this._advance(n, true); }
  /** 跳过可以超过当前已缓冲的长度：剩下的在后续 push 时直接丢弃，不占内存 */
  skip(n) {
    const now = Math.min(n, this.len);
    this._advance(now, false);
    this.drop += n - now;
  }
}

/** 一串切片上的随机访问（块头解析、NAL 改写都在它上面做，不拼大缓冲） */
class HlsPieces {
  constructor(pieces) {
    this.p = pieces; this.at = [];
    let o = 0;
    for (const x of pieces) { this.at.push(o); o += x.length; }
    this.len = o;
  }
  _find(pos) {
    let lo = 0, hi = this.p.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (this.at[mid] <= pos) lo = mid; else hi = mid - 1;
    }
    return lo;
  }
  byte(pos) { const i = this._find(pos); return this.p[i][pos - this.at[i]]; }
  bytes(pos, n) {
    n = Math.max(0, Math.min(n, this.len - pos));
    const out = new Uint8Array(n);
    let i = this._find(pos), o = 0, off = pos - this.at[i];
    while (o < n) {
      const b = this.p[i++];
      const t = Math.min(n - o, b.length - off);
      out.set(b.subarray(off, off + t), o);
      o += t; off = 0;
    }
    return out;
  }
  slice(pos, n) {
    const out = [];
    if (n <= 0) return out;
    let i = this._find(pos), off = pos - this.at[i], left = n;
    while (left > 0) {
      const b = this.p[i++];
      const t = Math.min(left, b.length - off);
      out.push(b.subarray(off, off + t));
      left -= t; off = 0;
    }
    return out;
  }
}

/** 取一个切片，但不拼成大缓冲：只收集上游块的引用（省掉整段 memcpy，CPU 与 GC 都减半） */
async function hlsFetchChunks(open, start, end, rOpt) {
  const rd = resumableReader({ ...rOpt, start, end, open, label: 'hls-slice' });
  const out = [];
  let got = 0, ok = false;
  try {
    for (;;) {
      const r = await rd.read();
      if (r.done) break;
      out.push(r.value);
      got += r.value.length;
    }
    if (got !== end - start + 1) throw new Error(`slice short ${got}/${end - start + 1}`);
    ok = true;
    return out;
  } finally {
    if (!ok) await rd.cancel('slice failed').catch(() => {});
  }
}

/**
 * [start, end] 的字节流：首段 1MB 直通（首字节只等一个 TTFB），其余按切片
 * 并行预取、按序交付。切片数封顶 24，给免费计划的子请求上限留余量。
 */
function hlsByteSource(cx, start, end) {
  const aborter = new AbortController();
  const outer = cx.signal;
  const fwd = () => aborter.abort(outer.reason);
  if (outer?.aborted) fwd(); else if (outer) outer.addEventListener('abort', fwd, { once: true });
  const meta = cx.linkData.metadata;
  const linkRef = { link: cx.linkData.link, metadata: meta, size: meta.size,
    identity: meta.content_hash || meta.rev || String(meta.size || '') };
  const budget = makeStreamBudget(cx.env);
  const open = upstreamOpener(cx.filePath, linkRef, cx.env, cx.ctx, { budget, signal: aborter.signal, hedge: true, label: 'hls-head' });
  const openBg = upstreamOpener(cx.filePath, linkRef, cx.env, cx.ctx, { budget, signal: aborter.signal, hedge: false, label: 'hls-slice' });
  const rOpt = { stallMs: stallMs(cx.env), maxResume: resumeMax(cx.env), maxOpen: openMax(cx.env), signal: aborter.signal };
  const win = hlsWindow(cx.env);
  const headEnd = Math.min(end, start + HLS_FIRST - 1);
  const rest = end - headEnd;
  const sliceSize = Math.max(HLS_SLICE, Math.ceil(rest / 24 / 1048576) * 1048576);
  const slices = [];
  for (let p = headEnd + 1; p <= end; p += sliceSize) slices.push([p, Math.min(end, p + sliceSize - 1)]);
  const inflight = new Map();
  const launch = i => {
    if (i >= slices.length || inflight.has(i)) return;
    const pr = hlsFetchChunks(openBg, slices[i][0], slices[i][1], rOpt);
    pr.catch(() => {});
    inflight.set(i, pr);
  };
  let head = null, headDone = false, next = 0, closed = false, cur = null, curAt = 0;
  const close = reason => {
    if (closed) return;
    closed = true;
    if (!aborter.signal.aborted) aborter.abort(reason || 'done');
    if (outer) outer.removeEventListener('abort', fwd);
    if (head && !headDone) head.cancel(reason).catch(() => {});
    inflight.clear();
  };
  return {
    async next() {
      if (closed) return { done: true };
      if (!head) {
        head = resumableReader({ ...rOpt, open, start, end: headEnd, label: 'hls-head' });
        for (let i = 0; i < win; i++) launch(i);
      }
      if (!headDone) {
        const r = await head.read();
        if (!r.done) return { done: false, value: r.value };
        headDone = true;
      }
      if (cur && curAt < cur.length) return { done: false, value: cur[curAt++] };
      if (next < slices.length) {
        cur = await inflight.get(next);
        curAt = 0;
        inflight.delete(next);
        launch(next + win);
        next++;
        return { done: false, value: cur[curAt++] };
      }
      close('complete');
      return { done: true };
    },
    close,
  };
}

/** 分段的字节边界：起点总是某个 Cluster 的开头，终点是下一段关键帧块的位置 */
function hlsSegPlan(idx, k) {
  const S = idx.segs;
  const [cl, rel, t] = S[k];
  const nx = S[k + 1] || null;
  let fetchEnd = idx.clustersEnd - 1;
  if (nx) {
    if (nx[1] >= 0) fetchEnd = idx.segStart + nx[0] + 12 + nx[1] - 1;
    else {
      const nn = S.slice(k + 2).find(s => s[0] > nx[0]);
      fetchEnd = nn ? idx.segStart + nn[0] - 1 : idx.clustersEnd - 1;
    }
  }
  return {
    start: idx.segStart + cl, startRel: rel, startT: t, first: k === 0,
    endCl: nx ? idx.segStart + nx[0] : -1, endRel: nx ? nx[1] : -1, endT: nx ? nx[2] : Infinity,
    fetchEnd: Math.min(idx.size - 1, fetchEnd),
  };
}

/**
 * EBML 流式块解析。只吐 want 里的轨道；分段边界：
 *   · 已知 CueRelativePosition → 按字节位置精确起止
 *   · 未知 → 从簇头开始，以「时间戳 ≥ CueTime 的视频关键帧」为界
 * 两段用同一个判定，所以每个块恰好落在一个分段里，不重不漏。
 */
async function* hlsBlocks(src, plan, idx, want) {
  const q = new HlsQueue(plan.start);
  const vnum = idx.video.num;
  let clusterTs = 0, skipping = !plan.first, startBlock = -1, endBlock = -1, endPending = false;
  const need = async n => {
    while (q.len < n) {
      const r = await src.next();
      if (r.done) return false;
      q.push(r.value);
    }
    return true;
  };
  for (;;) {
    const X = q.pos;
    if (endBlock >= 0 && X >= endBlock) return;
    // 数据多半已经在队列里（一块 64KB 能装下几十个元素头）：够了就同步往下走，不够才 await ——
    // 每个元素头原来要 await 三四次，一段几千个块，微任务的来回比解析本身还贵
    if (q.len < 2 && !(await need(2))) return;
    if (q.len < 16) await need(16);
    const h = q.peek(16);
    const id = ebmlId(h, 0, h.length);
    const sz = id && ebmlSize(h, id[1], h.length);
    if (!id || !sz) return;
    const hl = id[1] + sz[1], eid = id[0], esz = sz[0];
    if (eid === MKV.Cluster) {
      q.skip(hl);
      const data = X + hl;
      if (X === plan.start && plan.startRel >= 0) startBlock = data + plan.startRel;
      if (X === plan.endCl) {
        if (plan.endRel >= 0) endBlock = data + plan.endRel;
        else endPending = true;
      }
      continue;
    }
    if (MKV_TOP.has(eid)) return;
    if (esz < 0) throw new Error('unknown-size element in cluster');
    if (eid === MKV.Timestamp) {
      if (q.len < hl + esz && !(await need(hl + esz))) return;
      clusterTs = ebmlUint(q.peek(hl + esz), hl, esz);
      q.skip(hl + esz);
      continue;
    }
    if (eid !== MKV.SimpleBlock && eid !== MKV.BlockGroup) { q.skip(hl + esz); continue; }
    if (skipping && startBlock >= 0) {
      if (X < startBlock) { q.skip(hl + esz); continue; }
      skipping = false;
    }

    // 先看块头里的轨道号，决定要不要把负载留下来。SimpleBlock 的块头（轨道号 + 时间 + 标志，通常 4 字节）
    // 多半已经在刚才那 16 字节里了，不必再取一次
    let bh = null;
    if (eid === MKV.SimpleBlock && hl + 4 <= Math.min(h.length, hl + esz)) bh = mkvBlockHead(h, hl, Math.min(h.length, hl + esz));
    const hn = Math.min(hl + esz, hl + 48);
    let hb = h;
    if (!bh) {
      if (q.len < hn) await need(hn);
      hb = q.peek(hn);
    }
    if (bh) { /* 上面已经认出来了 */ }
    else if (eid === MKV.SimpleBlock) bh = mkvBlockHead(hb, hl, hb.length);
    else {
      for (let p = hl; p < hb.length;) {
        const ci = ebmlId(hb, p, hb.length), cs = ci && ebmlSize(hb, p + ci[1], hb.length);
        if (!ci || !cs) break;
        if (ci[0] === MKV.Block) { bh = mkvBlockHead(hb, p + ci[1] + cs[1], hb.length); break; }
        p += ci[1] + cs[1] + cs[0];
      }
    }
    if (!bh) { q.skip(hl + esz); continue; }
    const isVideo = bh.track === vnum;
    const boundaryWatch = isVideo && ((skipping && startBlock < 0) || endPending);
    const keep = want.has(bh.track) && !(skipping && !boundaryWatch);
    const ts = clusterTs + bh.rel;

    if (!keep && !(boundaryWatch && eid === MKV.BlockGroup)) {
      if (boundaryWatch) {
        const key = !!(bh.flags & 0x80);
        if (endPending && key && ts >= plan.endT) return;
        if (skipping && key && ts >= plan.startT) skipping = false;
      }
      q.skip(hl + esz);
      continue;
    }

    if (q.len < hl + esz && !(await need(hl + esz))) return;
    const P = new HlsPieces(q.take(hl + esz));
    let key, dur = -1, bstart, bend, flags = bh.flags;
    if (eid === MKV.SimpleBlock) {
      key = !!(flags & 0x80);
      bstart = hl; bend = hl + esz;
    } else {
      let ref = false;
      for (let p = hl; p < hl + esz;) {
        const hdr = P.bytes(p, Math.min(12, hl + esz - p));
        const ci = ebmlId(hdr, 0, hdr.length), cs = ci && ebmlSize(hdr, ci[1], hdr.length);
        if (!ci || !cs) break;
        const d = p + ci[1] + cs[1];
        if (ci[0] === MKV.Block) { bstart = d; bend = d + cs[0]; }
        else if (ci[0] === MKV.BlockDuration) dur = ebmlUint(P.bytes(d, cs[0]), 0, cs[0]);
        else if (ci[0] === MKV.ReferenceBlock) ref = true;
        p = d + cs[0];
      }
      key = !ref;
      if (bstart == null) continue;
    }
    if (boundaryWatch && key) {
      if (endPending && ts >= plan.endT) return;
      if (skipping && ts >= plan.startT) skipping = false;
    }
    if (skipping || !want.has(bh.track)) continue;

    // 帧切分：无 lacing（视频）零拷贝；有 lacing（音频，小块）拷一份再切
    // （块可以只有几个字节 —— AV1 的「显示已有帧」—— 块头按实际长度读）
    const hb2 = P.bytes(bstart, Math.min(8, bend - bstart));
    const tv = ebmlVintRaw(hb2, 0, hb2.length);
    if (!tv || bstart + tv[1] + 3 > bend) continue;
    const dataPos = bstart + tv[1] + 3;
    let frames;
    if (!((flags >> 1) & 3)) frames = [P.slice(dataPos, bend - dataPos)];
    else {
      const raw = P.bytes(dataPos, bend - dataPos);
      frames = mkvLaces(raw, 0, raw.length, flags).map(([a, b]) => [raw.subarray(a, b)]);
    }
    yield { track: bh.track, ts, key, dur, frames };
  }
}

/* 杜比视界的 RPU 按镜头给 L1 亮度元数据：同一个镜头里相邻帧的 RPU 往往逐字节相同。
   转换是输入字节的纯函数（解析 → 改成 8.1 → 重算 CRC → 加防竞争字节），同样的输入直接用上一次的输出 ——
   比一遍字节省掉整套位级解析与重写。输出只读、只会被拷进分片，多帧共用同一份没有问题。 */
let DV_MEMO_IN = null, DV_MEMO_OUT = null;
function dvRpuMemo(raw) {
  const a = DV_MEMO_IN, n = raw.length;
  if (a && a.length === n) {
    let i = 0;
    while (i < n && a[i] === raw[i]) i++;
    if (i === n) return DV_MEMO_OUT;
  }
  const out = dvConvertRpuNal(raw);
  DV_MEMO_IN = raw; DV_MEMO_OUT = out;
  return out;
}

/** P7：丢增强层 NAL（63），RPU（62）改写为 8.1；dvStrip：两者都丢，按 HDR10 输出 */
function hlsRewriteHevc(pieces, nalLen, mode, stats) {
  const P = new HlsPieces(pieces);
  const out = [];
  let p = 0, size = 0, changed = false;
  while (p + nalLen <= P.len) {
    let len = 0;
    for (let i = 0; i < nalLen; i++) len = len * 256 + P.byte(p + i);
    const s = p + nalLen;
    if (len < 1 || s + len > P.len) { out.push(...P.slice(p, P.len - p)); size += P.len - p; changed = true; break; }
    const type = (P.byte(s) >> 1) & 0x3F;
    if (type === 63 || (type === 62 && mode === 'strip')) { changed = true; }
    else if (type === 62) {
      let nal;
      const raw = P.bytes(s, len);
      try { nal = dvRpuMemo(raw); stats.rpu++; }
      catch { nal = raw; stats.rpuFail++; }
      const lenb = new Uint8Array(nalLen);
      for (let i = 0; i < nalLen; i++) lenb[i] = (nal.length >>> (8 * (nalLen - 1 - i))) & 255;
      out.push(lenb, nal);
      size += nalLen + nal.length;
      changed = true;
    } else {
      out.push(...P.slice(p, nalLen + len));
      size += nalLen + len;
    }
    p = s + len;
  }
  return changed ? { pieces: out, size } : { pieces, size: P.len };
}

/**
 * 一个 HLS 分段 → fMP4 分片流（按 ~1s 一个 moof 交付）。
 * sel.video：视频（+ 复用的默认音轨 sel.audio）；否则只出 sel.audio 这条音轨。
 */
async function* hlsSegmentParts(cx, idx, k, sel, opts = {}) {
  const plan = hlsSegPlan(idx, k);
  const V = idx.video;
  const A = sel.audio >= 0 ? idx.audio[sel.audio] : null;
  const want = new Set();
  if (sel.video) want.add(V.num);
  if (A) want.add(A.num);
  // 没有字幕 Cues 的内封字幕：视频这一遍顺手把字幕块收下，写成这一段的 VTT 进缓存。
  // 否则一开字幕，每个字幕分段都要把整段视频字节从 Dropbox 再读一遍。
  const subGrab = new Map();
  if (sel.video && opts.subs) {
    idx.subs.forEach((s, i) => {
      if (!hlsSubNeedsScan(s)) return;
      subGrab.set(s.num, { sub: s, i, blocks: [] });
      want.add(s.num);
    });
  }
  const pass = opts.pass || null;
  if (pass && subGrab.size) pass.subs = 1;
  // 备选音轨顺路：最近有人在听某条备选音轨（HLS_ALT），视频这一遍把它的块也收下，按「只出这条音轨」
  // 那条路径同一套规则切成分片（hlsAltMux），整段写进缓存 —— 音轨请求从缓存出，同一段字节不再为了
  // 音轨从 Dropbox 再读一遍、再解析一遍
  const B = sel.video && opts.alt >= 0 ? idx.audio[opts.alt] : null;
  const alt = B && B !== A && B.mode === 'copy' ? hlsAltMux(B, k) : null;
  if (alt) { want.add(B.num); if (pass) pass.alt = { i: opts.alt, st: 1 }; }
  const raw = hlsByteSource(cx, plan.start, plan.fetchEnd);
  // 进度打点：等这一遍的请求（同一段的视频 / 字幕）据此判断它是不是还在动
  const src = !pass ? raw : {
    next: async () => { const r = await raw.next(); pass.tick = Date.now(); return r; },
    close: reason => raw.close(reason),
  };
  const vid = 1, aid = sel.video ? 2 : 1;
  const T0v = HLS_T0 * V.ts;
  const T0a = A ? HLS_T0 * A.ts : 0;
  const vStrip = V.strip ? hlsUnB64(V.strip) : null;
  const aStrip = A && A.strip ? hlsUnB64(A.strip) : null;
  const stats = { rpu: 0, rpuFail: 0 };

  // 视频：PTS 吸附帧网格；DTS_j = 第 (j−R) 小的 PTS（不足时按帧长外推）
  const R = Math.max(0, V.reorder | 0);
  const fd = V.fd || (V.fps ? Math.round(V.ts / V.fps) : 3750);
  const vAnchor = Math.round(V.anchor * V.ts / 1e9);
  const snapV = ns => {
    const u = ns * V.ts / 1e9;
    if (V.fd) {
      const s = vAnchor + Math.round((u - vAnchor) / V.fd) * V.fd;
      if (Math.abs(s - u) <= V.fd / 4) return s;
    }
    return Math.round(u);
  };
  const sorted = [];
  let vCount = 0, vEmitted = 0, lastDts = -Infinity, seenKey = false;
  const vPend = [];                       // { pts, key, pieces, size, idx }
  const dtsOf = j => (j >= R ? sorted[j - R] : sorted[0] - (R - j) * fd);

  // 音频：时间戳吸附到「首帧 + n × 帧长」的网格上，保证跨分段无缝
  let aRun = null;                        // { base, end, samples[] }
  const aRuns = [];
  const snapA = (ns, fs) => {
    const u = Math.round(ns * A.ts / 1e9);
    return fs > 0 ? A.anchor + Math.round((u - A.anchor) / fs) * fs : u;
  };

  // 帧 j 可交付 ⇔ DTS_j 与 DTS_{j+1} 都已确定 ⇔ 已见到 max(j+2, R+1) 帧
  // （重排深度为 R 时，之后的帧不可能再改变第 j−R 小的 PTS）
  const vReady = () => (vCount >= R + 1 ? Math.max(0, vCount - 1 - vEmitted) : 0);
  let seq = k * 10000 + 1, bytes = 0;
  function* flush(final) {
    const runs = [];
    if (sel.video) {
      const n = final ? vPend.length : vReady();
      if (n > 0) {
        const samples = [];
        let base = null;
        for (let i = 0; i < n; i++) {
          const f = vPend[i];
          let dts = Math.max(dtsOf(f.idx), lastDts + 1);
          let next = f.idx + 1 < vCount ? Math.max(dtsOf(f.idx + 1), dts + 1) : dts + fd;
          lastDts = dts;
          if (base === null) base = dts;
          samples.push({ dur: Math.max(1, next - dts), size: f.size, pieces: f.pieces,
            flags: f.key ? 0x02000000 : 0x01010000, cto: f.pts - dts });
        }
        vPend.splice(0, n);
        vEmitted += n;
        runs.push({ id: vid, video: true, base: base + T0v, samples });
      }
    }
    if (A) {
      if (aRun) { aRuns.push(aRun); aRun = null; }
      for (const r of aRuns) runs.push({ id: aid, video: false, base: r.base + T0a, samples: r.samples });
      aRuns.length = 0;
    }
    bytes = 0;
    // 一个 moof 里每条轨只放一个 trun：多段音频（遇到断档）拆成多个分片
    const v = runs.filter(r => r.video), a = runs.filter(r => !r.video);
    if (!v.length && !a.length) return;
    yield mp4Fragment(seq++, [...v, ...a.slice(0, 1)]);
    for (const r of a.slice(1)) yield mp4Fragment(seq++, [r]);
  }
  const readyVideoSec = () => {
    const e = vReady();
    return e < 1 ? 0 : (dtsOf(vEmitted + e) - dtsOf(vEmitted)) / V.ts;
  };

  try {
    for await (const blk of { [Symbol.asyncIterator]: () => hlsBlocks(src, plan, idx, want) }) {
      const ns = blk.ts * idx.scaleNs;
      if (blk.track === V.num) {
        if (!seenKey) { if (!blk.key) continue; seenKey = true; }
        let pieces = blk.frames[0], size = pieces.reduce((s, x) => s + x.length, 0);
        if (vStrip) { pieces = [vStrip, ...pieces]; size += vStrip.length; }
        if (V.annexB) { const r = hlsAnnexBToLen(pieces); pieces = r.pieces; size = r.size; }
        if (V.dvConvert || V.dvStrip) {
          const r = hlsRewriteHevc(pieces, V.nalLen, V.dvStrip ? 'strip' : 'convert', stats);
          pieces = r.pieces; size = r.size;
        }
        const pts = snapV(ns);
        let lo = 0, hi = sorted.length;
        while (lo < hi) { const m = (lo + hi) >> 1; if (sorted[m] < pts) lo = m + 1; else hi = m; }
        sorted.splice(lo, 0, pts);
        vPend.push({ pts, key: blk.key, pieces, size, idx: vCount });
        vCount++;
        bytes += size;
      } else if (A && blk.track === A.num) {
        const laceNs = A.fs ? A.fs * 1e9 / A.ts : 0;
        blk.frames.forEach((fr, i) => {
          let pieces = fr, size = fr.reduce((s, x) => s + x.length, 0);
          if (aStrip) { pieces = [aStrip, ...pieces]; size += aStrip.length; }
          let fs = A.fs;
          if (!fs && A.codec === 'flac') fs = flacFrameSamples(fr.length === 1 ? fr[0] : hlsConcat(fr)) || 4096;
          const t = snapA(ns + i * (laceNs || (fs * 1e9 / A.ts)), fs);
          if (aRun) {
            if (Math.abs(t - aRun.end) <= fs / 2) { /* 连续 */ }
            else if (t < aRun.end) return;                       // 重叠帧：丢弃
            else { aRuns.push(aRun); aRun = null; }               // 断档：另起一段
          }
          if (!aRun) aRun = { base: t, end: t, samples: [] };
          aRun.samples.push({ dur: fs, size, pieces });
          aRun.end += fs;
          bytes += size;
        });
      } else if (subGrab.has(blk.track)) {
        subGrab.get(blk.track).blocks.push({ ts: blk.ts, dur: blk.dur, frame: hlsConcat(blk.frames[0]) });
      } else if (alt && blk.track === B.num) {
        alt.push(blk, ns);
        continue;
      }
      const due = sel.video ? (readyVideoSec() >= HLS_FRAG_SEC || bytes >= HLS_FRAG_BYTES)
        : (aRun && (aRun.end - aRun.base) >= 2 * A.ts) || aRuns.length > 0 || bytes >= HLS_FRAG_BYTES;
      if (due) yield* flush(false);
    }
    // 这一段的字幕块已经收齐：先在后台把 VTT 写进缓存（字幕请求可能正等着），再交最后一个片段
    if (subGrab.size) hlsSubsWrite(cx, idx, k, subGrab, pass);
    if (alt) hlsAltWrite(cx, idx, k, opts.alt, alt.finish(), pass);
    yield* flush(true);
    if (stats.rpuFail) console.error(`hls: ${stats.rpuFail} RPU 转换失败（${cx.filePath} #${k}）`);
    if (pass) pass.ok = true;
  } finally {
    src.close('segment end');
    if (pass) {
      pass.ended = Date.now();
      if (pass.subs === 1) pass.subs = -1;          // 半路停了：字幕没收齐
      if (pass.alt && pass.alt.st === 1) pass.alt.st = -1;
      hlsPassDone(pass);
    }
  }
}

// ── 字幕：内封 SRT / ASS 与同目录外挂字幕 → 分段 WebVTT ──

function hlsVttTime(sec) {
  const ms = Math.max(0, Math.round(sec * 1000));
  const p = (v, n = 2) => String(v).padStart(n, '0');
  return `${p(Math.floor(ms / 3600000))}:${p(Math.floor(ms / 60000) % 60)}:${p(Math.floor(ms / 1000) % 60)}.${p(ms % 1000, 3)}`;
}
/** WebVTT 文本：只保留 <i><b><u>，其余转义；不能有空行，也不能出现 --> */
function hlsVttEscape(s) {
  const keep = [];
  s = String(s).replace(/<(\/?)(i|b|u)\b[^>]*>/gi, (m, sl, t) => { keep.push(`<${sl}${t.toLowerCase()}>`); return `\u0001${keep.length - 1}\u0002`; });
  s = s.replace(/<[^>]*>/g, '');
  s = s.replace(/&(?!(amp|lt|gt|nbsp|lrm|rlm);)/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  s = s.replace(/\u0001(\d+)\u0002/g, (m, i) => keep[+i]);
  return s.replace(/-->/g, '→').replace(/\r\n?/g, '\n').replace(/\n{2,}/g, '\n').trim();
}
/** ASS 一行对白的 Text 字段 → VTT（斜体 / 粗体保留，特效标签与绘图丢弃） */
function hlsAssText(text) {
  if (/\{[^}]*\\p[1-9]/.test(text)) return { text: '', settings: '' };
  const settings = /\{[^}]*\\an?[789]\b[^}]*\}/.test(text) ? ' line:8%' : '';
  let out = '', last = 0, it = false, bd = false, m;
  const re = /\{([^}]*)\}/g;
  const esc = s => s.replace(/\\N/gi, '\n').replace(/\\h/g, ' ').replace(/<[^>]*>/g, '');
  while ((m = re.exec(text))) {
    out += esc(text.slice(last, m.index));
    const iv = /\\i([01])(?!\d)/.exec(m[1]);
    if (iv) { if (iv[1] === '1' && !it) { out += '<i>'; it = true; } else if (iv[1] === '0' && it) { out += '</i>'; it = false; } }
    const bv = /\\b([01])(?!\d)/.exec(m[1]);
    if (bv) { if (bv[1] === '1' && !bd) { out += '<b>'; bd = true; } else if (bv[1] === '0' && bd) { out += '</b>'; bd = false; } }
    last = re.lastIndex;
  }
  out += esc(text.slice(last));
  if (bd) out += '</b>';
  if (it) out += '</i>';
  return { text: hlsVttEscape(out), settings };
}
/** MKV 字幕块 → { text, settings } */
function hlsSubFrameText(fmt, bytes) {
  const s = new TextDecoder().decode(bytes).replace(/\0+$/, '');
  if (fmt === 'ass') {
    // ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    const parts = s.split(',');
    if (parts.length >= 9 && (SUB_STAFF_STYLE.test((parts[2] || '').trim()) || SUB_STAFF_STYLE.test((parts[3] || '').trim()))) return { text: '', settings: '' };
    return hlsAssText(parts.length >= 9 ? parts.slice(8).join(',') : s);
  }
  // 文本字幕轨（S_TEXT/UTF8）：ASS 转出来的常带着 \h、\N、{\an8}
  const u = subUnAss(s);
  return { text: hlsVttEscape(u.text), settings: u.top ? ' line:8%' : '' };
}

// ── 字幕清洗：字幕组署名、发布 / 来源声明、网址、广告、水印 ──
//  内封、外挂、在线找来的字幕，输出 WebVTT 之前都过这一遍。按行打分，过线就删那一行；
//  一条字幕的行删光了（或只剩装饰符号）就整条不要。
//  · 片头 / 片尾各 SUB_EDGE_S 秒（以及最前 / 最后 SUB_EDGE_N 条）是署名与广告的重灾区：过 3 分就删；
//    那里挂得特别久的一条（≥ SUB_LONG_S 秒 —— 署名卡、片尾鸣谢）过 2 分就删
//  · 正片中间只删「几乎不可能是台词」的东西（网址、字幕组、OpenSubtitles 的广告、「仅供学习交流」
//    这类声明）：过 4 分才删 —— 台词里提到「翻译」「出品」「伊甸园」不会被误删
//  c2 起（增强型）：
//  · 打分前先把全角折成半角（ＷＷＷ．ＸＸ．ＣＯＭ 是专门躲过滤的写法）、去掉标签
//  · 像台词的行（你我他、语气词、问号叹号结尾、对白横杠）只靠弱信号（没有一条 ≥ 4 分的规则命中）
//    时减 1 分：「你愿意加入我们吗？」「关注我的公众号」不会因为一个字眼被删
//  · ASS 的矢量绘图指令（\p1 之后的 m 0 0 l 100 0 …）、整行乱码（U+FFFD）直接删 —— 不是给人看的字
//  · 署名块：片头片尾一条被删干净了，前后 SUB_BLOCK_S 秒内紧挨着它、还剩 ≥ 2 分行的那几条
//    （「鸣谢」「感谢观看」这类弱信号）一起删，连着的一串署名不会只删掉一半
//  · 水印（只在拿得到整份字幕时：外挂、在线、直连整份）：同一行在全片反复出现（≥ 3 条、首尾相隔
//    ≥ 10 分钟或片长的两成），自己又带一点署名味道（≥ 2 分，或 ≥ 1 分且长得像水印：包在括号 /
//    装饰符里、带 @、像网址、一串大写缩写）→ 全片都删。「好的」「什么？」这种高频台词 0 分，不受影响
//  · partial（HLS 分段，内封字幕逐段读，只拿得到这一段的几条）：只按时间认片头片尾，不认名次、不认水印。
//    c1 在这里按「这几条里的前 6 / 后 6 条」认片头片尾 —— 每一段几乎每条都落进去，正片台词按片头的
//    门槛（3 分）在删
//  c3 起：
//  · SRT / VTT 里残留的 ASS 写法先收拾掉（ASS 转出来的 SRT、MKV 里的文本字幕轨常见）：\h → 空格、\N → 换行、
//    {\an8} 这类标签去掉（\an7-9 仍然放到顶部）。原来只有 ASS 轨处理这些，SRT 里的 \h 原样上了屏
//  · 一个字一个空格排开的汉字（「翻 译」「时 间 轴」）打分前并回去；这种排法本身就是署名卡的样子，多算一分
//  · 只有职位的一行（「翻译」「校 对」，名字在下一行）：片头片尾删，同一条里它下面的名字一起删；
//    名字另起一条、时间一模一样的（ASS 里分开排版的署名卡）也删
//  · 认不出的职位（「海 报」这种排开写的小标题）只算弱信号：挨着已经删掉的署名卡才删（连同下面的名字）；
//    台词里强调语气的「不 可 能」留着
//  · 没有冒号的职位行（「翻译 张三」）只算弱信号：前后挨着的另一条也是职位行，或者后面跟了一串名字 / 英文 ID，才删
//  · 同一条里删了署名 / 广告，剩下带署名味道的行（≥ 2 分：@账号、邮箱、鸣谢）不留
//  · 新认得的广告：推广 / 商务 / 广告合作与「请联系……邮箱」、QQ 号 / 微信号、视频站账号、盗版片源站、博彩广告
//    （「注册送彩金」）、躲过滤的网址（www 。xx 。com、xx点com）、「严禁商用 / 请勿转载」。
//    台词里也会说的只算弱信号，凑到一起才删：邮箱地址、「在线观看」「免费下载」「提取码」「六合彩」「支持正版」
//  · 行首的英文署名（corrected by / encoded by …）只认一句话的开头：上一行没说完、接下来的那半句
//    （「The essay was / corrected by the teacher.」）不算，哪怕跨了两条字幕
const SUB_EDGE_S = 240;
const SUB_EDGE_N = 6;
const SUB_LONG_S = 8;
const SUB_BLOCK_S = 12;
const SUB_CLEAN_V = 'c3';             // 清洗规则的版本：进缓存键，规则改了旧的 VTT 不会再被端上来
const SUB_TLD = 'com|net|org|cn|cc|tv|la|io|info|xyz|top|vip|club|site|link|ru|tw|hk|me|mx|ag|lt|sx|ws|pw|app|biz|uk|jp|kr|eu|nz|vn|gg|tk|icu|cyou|asia|mobi|wang|ltd|online|store';
// 每条：[正则, 分数, 只认一句话的开头]。第三项为 true 的是行首的英文署名：这一行若是上一行没说完接下来的，不算
const SUB_RULES = [
  // 网址：带协议 / www 的一定是；裸域名只认常见后缀（e.g. / Mr.Smith 这类不会命中）
  [/(?:https?:\/\/|www\.)[^\s]+/i, 4],
  [new RegExp(`(?:^|[^\\w@.\\-])[a-z0-9][\\w-]{1,62}\\.(?:${SUB_TLD})(?:\\/[^\\s]*)?(?![\\w.])`, 'i'), 3],
  // 躲过滤的网址：www 后面拿空格 / 逗号 / 句号 /「点」隔开；「xx点com」
  [/www\s*[.,。·点]\s*[a-z0-9-]{2,}\s*[.,。·点]\s*[a-z]{2,6}(?![a-z])/i, 4],
  [/[a-z0-9-]{2,40}\s?(?:[。·点]|\(dot\)|\[dot\])\s?(?:com|net|org|cn|cc|tv)(?![a-z])/i, 3],
  // 字幕组 / 压制组 / 翻译组
  [/字幕[组組社团團坊侠俠]|翻[译譯][组組]|[压壓]制[组組]|(?:^|[^a-z])(?:fansub|sub(?:s|titles?)?\s*team)(?:[^a-z]|$)/i, 4],
  // 认得出名字的字幕站 / 字幕组（这些词不会出现在台词里）
  [/人人影[视視]|YYeTs|破[烂爛]熊|射手[网網]|字幕(?:[库庫吧网網]|天堂)|SubHD|zimuku|assrt|天天美[剧劇]|美[剧劇]天堂|澄空[学學][园園]|[圣聖]城家[园園]|FRDS|CMCT|HDChina|OurBits|SweetSub|A4Sub|[凤鳳][凰凰]天使|TSKS|[诸諸]神字幕|追新番|[韩韓][剧劇]TV/i, 4],
  // 盗版片源站：不会出现在台词里的名字 4 分；说得通是台词的（「电影天堂」）3 分，只在片头片尾删
  [/dytt|dygod|ygdy8|btbtt|rarbg|1337x|\bEZTV\b|\bYIFY\b|\bYTS\b|BT天堂|高清MP4吧|6v[电電]影|66影[视視]|80s手[机機]|比特大雄|音范[丝絲]|哔嘀影[视視]|低端影[视視]|奈[飞飛]工[厂廠]|茶杯狐|3E帝[国國]|[飘飄]花[电電]影/i, 4],
  [/[电電]影天堂|[阳陽]光[电電]影(?![节節院])|[迅訊]雷[电電]影|高清之家|[蓝藍]光[网網]/, 3],
  // 英文字幕站与 OpenSubtitles 自己插的广告（这些说法不会出现在台词里）
  [/open[\s-]*subtitles|osdb\.link|subscene|addic7ed|podnapisi|\bsubdl\b|yifysubtitles|tvsubtitles|advertise your product|become (?:a )?vip member|rate this subtitle|help other users to choose|get (?:the )?(?:latest|more) subtitles|best subtitles? (?:at|on|from)|subtitles for any video|free browser extension|watch any video online|nord\s*vpn|implement rest api|remove all ads from|americas\s*cardroom|million dollar sunday|(?:movies|tv series|tv shows),? (?:and|&) live sports/i, 4],
  // 英文署名：只认行首（台词里也会有「corrected by the teacher」）。几个动词连着写的也认：sync, corrected by / Fixed & Synced by
  [/^[\s\-=~*#\[(]*(?:(?:[a-z]+(?:\s*[,&+\/]\s*|\s+and\s+))*(?:(?:re-?)?sync(?:ed|hronized|hronised)?|corrected|ripp?ed|encoded)(?:(?:\s*[,&+\/]\s*|\s+and\s+)[a-z-]+)* by\b|re-?sync(?:ed)? for\b|(?:(?:english|chinese|spanish|french|german|italian|portuguese|dutch|arabic) )?(?:subtitles?|subs|captions?) (?:by|from|ripped|synced|corrected|edited|translated|improved|adapted|downloaded)\b|captioned by|closed captions? (?:provided )?by|captioning (?:sponsored|made possible|provided|performed) by)/i, 4, true],
  [/^[\s\-=~*#\[(]*(?:downloaded from|transcri(?:pt|bed) by|provided by|(?:improved|adapted|tweaked|reviewed|polished|fixed|extracted|uploaded|converted) by)\b/i, 3, true],
  // 声明：学习交流 / 禁止商用 / 下载后删除 / 请勿转载（「仅供参考」「未经授权」「不得入内」是台词里的常用语，不算）
  [/仅供(?:学习|交流|研究|[试試]看)|僅供(?:學習|交流|研究|試看)|(?:禁止|[严嚴]禁|不得|[请請]勿|切勿)(?:用于|用於|作)?(?:任何)?(?:商业|商業)(?:用途)?|(?:请|請)(?:于|於)下[载載]|24\s*小[时時]内?(?:删除|刪除)|(?:禁止|[严嚴]禁|[请請]勿|[谢謝][绝絕]|不得)(?:任何形式的?|私自|擅自)?(?:[转轉][载載]|二次上[传傳]|二[传傳])/, 4],
  [/版[权權](?:归|歸)|[转轉][载載](?:请|請)[注註]明|(?:本|此)(?:资源|資源|视频|視頻|影片)(?:来自|來自|由|首[发發]|仅|僅)|(?:资源|資源)(?:来自|來自)/, 3],
  [/[扫掃][码碼](?:关注|關注|加入|进群|進群)/, 4],
  [/二[维維][码碼]|(?:[购購][买買]|支持)正版/, 2],
  // 引流：QQ 群 / 群号 / QQ 号 / 微信号最像广告；公众号、微博、淘宝、招人在台词里也会出现，只在片头片尾删
  [/(?:QQ|Q)\s*群|群[号號]\s*[:：]?\s*\d|t\.me\/|(?:QQ|扣扣)\s*[号號]?\s*[:：]?\s*\d{5,12}|(?:微信|V信|VX|薇信|威信|wechat|weixin)\s*(?:[号號]|ID)?\s*[:：]\s*[\w\-]{4,}|(?:\bTG|telegram)\s*(?:群|[频頻]道)|(?:\bTG|telegram)\s*[:：]?\s*@\w/i, 4],
  [/微信\s*(?:公众号|公眾號|号|號)|公众号|公眾號|微博\s*[@：:]|新浪微博|[电電][报報]群/, 3],
  [/更多(?:中文|精彩|好看|高清|影[视視]|美[剧劇]|[电電]影|资源|資源)*(?:字幕|资源|資源|影片|[电電]影|美[剧劇])?\s*(?:请|請)?\s*(?:访问|訪問|关注|關注|搜索|下[载載]|登[录錄])|(?:欢迎|歡迎)(?:关注|關注|订阅|訂閱)/, 3],
  // 视频站 / 社交账号：带冒号、@、ID、账号的是在报账号；「YouTube 频道」「B 站主页」台词里也说，弱信号
  [/(?:B站|bilibili|哔哩哔哩|嗶哩嗶哩|抖音|快手|小[红紅][书書]|西瓜[视視][频頻]|[头頭][条條][号號]|知乎|豆瓣|YouTube|油管|Twitter|推特|Instagram|Facebook|Patreon|[爱愛][发發][电電])\s*(?:U?ID|[账賬帳][号號]|搜索?|[关關]注|[:：@])/i, 3],
  [/(?:B站|bilibili|哔哩哔哩|嗶哩嗶哩|抖音|快手|小[红紅][书書]|西瓜[视視][频頻]|YouTube|油管|Patreon|[爱愛][发發][电電])\s*(?:UP主?|[频頻]道|主[页頁]|[订訂][阅閱])/i, 2],
  [/淘[宝寶]|招募|招聘|招新|[诚誠][聘招]|加入我[们們]/, 2],
  // 推广 / 商务 / 广告合作、广告位招租（后面接「的 / 得 / 人 / 了」的是在说事：「商务合作的事明天再谈」）
  [/(?:推[广廣]|[广廣]告|商[务務]|[赞贊]助)\s*(?:合作|洽[谈談]|投放|招商|[联聯][系繫絡络]|[咨諮][询詢]|[热熱][线線])(?![的得人了吗嗎呢])|(?:合作|[广廣]告|推[广廣])洽[谈談](?![的得了吗嗎呢])|洽[谈談]合作(?![的得了吗嗎呢])|[广廣]告位\s*(?:招租|出租|招商|合作)/, 3],
  // 联系方式：「请联系……邮箱 / QQ / 微信」「邮箱：」「联系方式：」
  [/(?:[请請]|[欢歡]迎|可)(?:[联聯][系繫絡络]|[咨諮][询詢]|致[电電])[^,.!?。，！？]{0,16}(?:[邮郵]箱|信箱|e-?mail|QQ|微信|[电電][话話]|客服)/i, 3],
  [/(?:[邮郵]箱|信箱|e-?mail|[联聯][系繫](?:方式|[电電][话話]|QQ|微信|[邮郵]箱)|投稿|客服(?:QQ|微信|[电電][话話])?)\s*[:：]/i, 3],
  // 邮箱地址：台词里也会念邮箱，弱信号；整行就是一个邮箱再加一分
  [/[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+/, 2],
  [/^[\s\-=~*#★☆◆◇■□●○【\[(（<《]*[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+[\s\-=~*#★☆◆◇■□●○】\])）>》]*$/, 1],
  // 看片 / 下载引流：这些词台词里也说（「免费下载的东西别乱点」），各算弱信号；广告多半两样都提，或者带着网址 / 站名
  [/在[线線](?:[观觀]看|播放|看片)|免[费費](?:[观觀]看|在[线線]|看片)|手[机機]看片|看片神器/, 2],
  [/(?:高清|免[费費]|[迅訊]雷|BT|[种種]子|磁力|[网網][盘盤])\s*下[载載]|磁力[链鏈]|[网網][盘盤](?:[链鏈]接|提取|[资資]源)|提取[码碼]|下[载載]地址|最新(?:[电電]影|影片|大片|美[剧劇]|[剧劇]集)(?:下[载載]|[资資]源|在[线線]|免[费費]|[抢搶]先)/i, 2],
  // 博彩广告（盗版片源的字幕里最常见的一类）：「注册送彩金」「在线发牌」这类说法不会是台词；
  // 场子 / 玩法的名字（「六合彩」「娱乐城」）与招徕的字眼（「彩金」「美女荷官」）赌片里也说，各算弱信号，凑到一起才删
  [/(?:注[册冊]|[开開][户戶]|首存|充值)\s*(?:就|即|立|免[费費])?(?:送(?![货貨达達到])|返(?![回还還]))|送彩金|在[线線][发發]牌|官方直[营營]|(?:最新|唯一|永久)(?:[网網]址|官[网網]|域名)/, 4],
  [/六合彩|[娱娛][乐樂]城|博彩|棋牌|百家[乐樂]|[时時]{2}彩|北京[赛賽][车車]/, 2],
  [/彩金|[体體]育投注|(?:真人|性感|美女)荷官/, 2],
  [/(?:官[网網]|[网網]址|[网網]站|主[页頁])\s*[:：]/, 3],
  // 翻译说明：机翻 / 人工翻译 / 如有错误欢迎指正（片头片尾才删）
  [/机器翻[译譯]|機器翻[譯译]|[机機]翻|AI\s*翻[译譯]|人工(?:翻[译譯]|听[译譯]|聽[譯译])|(?:如有|若有)(?:错误|錯誤|不[当當]|疏漏)|(?:欢迎|歡迎)指正/i, 3],
  // 鸣谢 / 感谢观看：弱信号，靠「挂得久」或「挨着署名块」才删
  [/感[谢謝](?:观看|觀看|收看|大家|所有|各位|以下)|(?:谢谢|謝謝)(?:观看|觀看|收看)|[鸣鳴][谢謝]|特[别別]感[谢謝]|thanks? for watching/i, 2],
  // 「本字幕由……」
  [/^(?:本|此)?字幕(?:由|仅|僅|来自|來自|出自|提供|制作|製作|翻[译譯])/, 4],
  // 文件名 / 片源规格（一行里出现两个以上才算）
  [/(?:\b(?:480p|720p|1080[pi]|2160p|4K|BluRay|Blu-ray|BDRip|WEB-?DL|WEBRip|HDTV|x26[45]|H\.?26[45]|HEVC|AVC|REMUX|DTS(?:-HD)?|TrueHD|Atmos|DDP?5\.1|AAC)\b.*){2}/i, 4],
  // 英文署名「Translated by」：台词里也可能出现，只在片头片尾删
  [/^[\s\-=~*#\[(]*(?:translated|translation|transcribed|timed|typeset|edited|proofread|subtitled|captioned) by\b/i, 3, true],
  // 「×× 出品 / 发布 / 首发 / 压制 / 荣誉出品」结尾
  [/(?:出品|[发發]布|首[发發]|[压壓]制|[荣榮]誉出品|[倾傾]情奉[献獻]|[独獨]家(?:首[发發]|[发發]布)?|呈[现現]|presents?|releases?d?)\s*$/i, 2],
  // 署名常用的机构字眼 / 英文缩写
  [/影[视視]|字幕|[论論][坛壇]|社[区區]|[网網]站|工作室|部落|[联聯]盟|小[组組]|家[园園]|\bTV\b|\bSub\b|\bTeam\b|\bHD\b/i, 1],
  // @账号 水印
  [/(?:^|[\s【\[(（「『])@[\w一-鿿]{2,}/, 2],
  // 整行只是装饰包着的一小段：【……】、==……==、★……★
  [/^[\s\-=~*#★☆◆◇■□●○【\[]{1,}.{1,40}[\s\-=~*#★☆◆◇■□●○】\]]{1,}$/, 1],
];
// 职位。字幕组自己的（翻译、校对、时间轴……）没有冒号也认；片子的职员表里也有的（监制、制作、出品……）与「字幕」
// 要带冒号，或者整行只有它（名字在下一行）
const SUB_ROLE_FAN = '翻[译譯]|校[对對订訂]|[时時][间間]?[轴軸]|[调調打校][轴軸]|[轴軸]校|[压壓]制|后期|後期|特效|片源|[听聽][译譯翻写寫]|[终終][审審校]|[总總]校|主[翻校]|翻校|校[译譯]|初翻|[润潤]色|繁化|嵌字';
const SUB_ROLE_ALL = SUB_ROLE_FAN + '|字幕|[总總][监監]|[监監]制|美工|策[划劃]|[审審]核|整理|制作|製作|出品|[发發]布|首[发發]|分割|上[传傳]|[协協][调調]|[统統][筹籌]|海[报報]';
const subRole = set => `(?:字幕|本[片集剧劇]|中文|[总總]|主|[责責]任|后期|後期)?(?:${set})(?:人[员員]|[组組]|者)?`;
const subRoles = (set, sep) => `${subRole(set)}(?:\\s*[${sep}]\\s*${subRole(set)})*`;
const SUB_LEAD = '[\\s\\-=~*#★☆◆◇■□●○【\\[(（]*';
const SUB_TRAIL = '[\\s\\-=~*#★☆◆◇■□●○】\\])）]*';
// 职位 + 冒号开头：翻译：/ 校对：/ 时间轴：/ Translated: / Timing:
const SUB_ROLE_COLON = new RegExp(`^${SUB_LEAD}(?:${subRoles(SUB_ROLE_ALL, '\\/&、·+,|\\s')}|Translat(?:ion|ed|ors?)|Subtitles?|Timing|Typeset(?:ting)?|Encod(?:e|ing|er)|QC|Editor|Edit(?:ing)?|Proofread(?:ing|er)?|Sync)\\s*[:：]`, 'i');
// 整行只有职位（名字在下一行）：翻译 / 校对 / 翻译&校对 / 时间轴：
const SUB_ROLE_HEAD = new RegExp(`^${SUB_LEAD}${subRoles(SUB_ROLE_ALL, '\\/&、·+,|\\s')}\\s*[:：]?${SUB_TRAIL}$`);
// 职位 + 空格 + 名字（没有冒号）；GAP3 = 后面跟了两个以上的名字，或者一个英文 ID
const SUB_ROLE_GAP = new RegExp(`^${SUB_LEAD}${subRoles(SUB_ROLE_FAN, '\\/&、·+|')} \\S`);
const SUB_ROLE_GAP3 = new RegExp(`^${SUB_LEAD}${subRoles(SUB_ROLE_FAN, '\\/&、·+|')} (?:\\S+ \\S|.*[a-z][\\w.\\-]{2,})`, 'i');
// 整行就是一个发布组名 / 字幕规格
const SUB_GROUP_LINE = /^(?:TLF|SPARKS|GECKOS|FGT|NTb|FLUX|CMRG|EVO|ION10|PSA|YTS(?:\.\w+)?|YIFY|RARBG|ETRG|TGx|QxR|Tigole|UTR|BeyondHD|ADWeb|HHWEB|M-?Team|WiKi|TTG|CHD|HDSky|FFans|PTer|BtsTV|LeagueWEB|NGB|原[创創]翻[译譯]|中英(?:双语|雙語)?字幕|(?:双语|雙語)字幕|特效字幕|精校版?|校[对對]版|中文字幕|英文字幕|(?:[简簡繁][体體]|官方|[国國][语語]|[粤粵][语語]|[简簡繁][英日韩韓])(?:中文|中字|双语|雙語|字幕|特效)+)$/i;
const SUB_DECOR = /^[\s\-=~*#★☆◆◇■□●○【】\[\]()（）<>《》|_.·•…!！?？,，、:：;；'"“”‘’]*$/;
// ASS 矢量绘图（{\p1} 之后的路径指令）：m/n/l/b/s/p 加一串数，可能以 c 收尾
const SUB_DRAW = /^(?:[mnlbsp](?:\s+-?\d+(?:\.\d+)?)+\s*)+c?$/i;
// 像一句台词：人称、语气词结尾、问号叹号结尾、对白横杠、英文的人称与口语
const SUB_TALK = /[我你您他她咱俺]|[吗嗎呢吧啊呀嘛哦哇啦咯][?!。，,…~]*\s*$|[?!]\s*$|^[-–—]\s|\b(?:I|I'm|I'll|you|we|he|she|they|me|my|your|our|don't|can't|let's|yeah|okay)\b/i;
// 长得像水印：包在括号 / 装饰符里、带 @、像网址、一串大写缩写
const SUB_MARK_SHAPE = /^[\s\[【(（<《「『★☆◆◇■□●○=\-~*#|]|[\]】)）>》」』★☆◆◇■□●○=\-~*#|]\s*$|@\S|www\.|\.(?:com|net|org|cn|tv|cc|la|me)\b|\b[A-Z]{3,}\b/;
// 一个字一个空格排开的汉字：翻 译 / 时 间 轴
const SUB_SPACED = /(?<![一-鿿])[一-鿿](?: [一-鿿](?![一-鿿]))+/g;
// 整行只有排开的两到四个字（「海 报」「鸣 谢」）：多半是署名卡的小标题；强调语气也会这么写（「不 可 能」），只算弱信号
const SUB_SPACED_ONLY = /^[一-鿿](?: [一-鿿]){1,3}$/;
// 一句话说完了：句末标点收尾（打分用的文字里全角已经折成半角）
const SUB_STOP = /[.!?…。:;"”’)\]♪]\s*$/;
// 明摆着是对白：问号 / 叹号 / 句号收尾、对白横杠
const SUB_SAY = /[?!。]\s*$|^[-–—]\s/;
// SRT / VTT 里残留的 ASS 写法：\h（硬空格）、\N（换行）、{\an8} 这类标签
const SUB_ASS_LEFT = /\\[hNn]|\{[^}]*\\[^}]*\}/;

/** 非 ASS 的字幕文字里残留的 ASS 写法 → { text, top }：标签去掉（\an7-9 = 顶部，记下来），\h → 空格，\N → 换行；
 *  {\p1} 画的图形整条不要 */
function subUnAss(s) {
  s = String(s);
  if (!SUB_ASS_LEFT.test(s)) return { text: s, top: false };
  if (/\{[^}]*\\p[1-9]/.test(s)) return { text: '', top: false };
  const top = /\{[^}]*\\an?[789]\b[^}]*\}/.test(s);
  return { text: s.replace(/\{[^}]*\\[^}]*\}/g, '').replace(/\\N/gi, '\n').replace(/\\h/g, ' ').replace(/[ \t]*\n[ \t]*/g, '\n').trim(), top };
}

/** 打分用的那一份文字：去标签 / 实体 / 零宽字符，全角折半角，空白收成一个；排开的汉字（「翻 译」）并回去 */
function subNorm0(line) {
  return String(line).replace(/<[^>]*>/g, '').replace(/&(?:amp|lt|gt|nbsp);/g, ' ')
    .replace(/[\u200B-\u200F\u2060\uFEFF]/g, '')
    .replace(/[！-～]/g, ch => String.fromCharCode(ch.charCodeAt(0) - 0xFEE0))
    .replace(/[　\s]+/g, ' ').trim();
}
const subJoin = t => t.replace(SUB_SPACED, m => m.replace(/ /g, ''));
const subNorm = line => subJoin(subNorm0(line));
/** 一行 → { t（打分用的文字）, n（分数）, role（职位行：翻译 / 校对……）, head（整行只有职位，名字在下一行）}。
 *  head 的行删掉时，同一条里它下面的行（名字）跟着删。n ≥ 9 = 不是给人看的字（绘图指令、乱码），任何位置都删。
 *  cont = 这一行是上一行没说完接下来的（小写开头、上一行没有句末标点）：行首的英文署名规则不算 */
function subLineInfo(line, cont) {
  const t0 = subNorm0(line), t = subJoin(t0);
  const x = { t, n: 0, role: false, head: false };
  if (!t) return x;
  if (SUB_DRAW.test(t)) { x.n = 9; return x; }
  const bad = (t.match(/�/g) || []).length;
  if (bad && bad * 3 >= t.length) { x.n = 9; return x; }
  let n = 0, strong = false;
  for (const [re, w, lead] of SUB_RULES) if (!(lead && cont) && re.test(t)) { n += w; if (w >= 4) strong = true; }
  if (SUB_GROUP_LINE.test(t.replace(/^[\s\-=~*#★☆◆◇■□●○【\[(（]+|[\s\-=~*#★☆◆◇■□●○】\])）]+$/g, ''))) { n += 3; strong = true; }
  // 职位行：带冒号 3 分；整行只有职位 3 分；职位 + 空格 + 名字 2 分（跟了一串名字 / 英文 ID 3 分）。
  // 字是排开写的（翻 译）再加一分 —— 台词不会这么排
  x.head = SUB_ROLE_HEAD.test(t);
  if (SUB_ROLE_COLON.test(t)) { n += 3; x.role = true; }
  else if (x.head) { n += 3; x.role = true; }
  else if (SUB_ROLE_GAP.test(t)) { n += SUB_ROLE_GAP3.test(t) ? 3 : 2; x.role = true; }
  else if (SUB_SPACED_ONLY.test(t0)) { n += 2; x.head = true; }      // 认不出的职位（「海 报」）：挨着署名块才删，见 subClean
  if (x.role && t0 !== t) { n += 1; strong = true; }
  if (n > 0 && !strong && SUB_TALK.test(t)) n -= 1;
  x.n = n;
  return x;
}
function subLineScore(line, cont) { return subLineInfo(line, cont).n; }
const subMarkKey = t => t.toLowerCase().replace(/[\s\-=~*#★☆◆◇■□●○【】\[\]()<>《》「」『』|_.·•…!?,、:;'"“”‘’]/g, '');

/** [{ s, e, text, settings }] → 清洗过的（不改原数组）。dur = 片长（秒），不知道就按最后一条字幕的结束时间算。
 *  opt.partial：cues 只是一段窗口里的那几条（HLS 分段），只按时间认片头片尾、不认水印 */
function subClean(cues, dur, opt) {
  if (!cues || !cues.length) return cues || [];
  const partial = !!(opt && opt.partial);
  // 残留的 ASS 写法（\h、\N、{\an8}）：解析时已经收拾过，这里再兜一遍 —— 早先存下的在线字幕记录里还带着
  if (cues.some(c => c && c.text && SUB_ASS_LEFT.test(c.text))) {
    cues = cues.map(c => {
      if (!c || !c.text || !SUB_ASS_LEFT.test(c.text)) return c;
      const u = subUnAss(c.text);
      return { ...c, text: hlsVttEscape(u.text), settings: c.settings || (u.top ? ' line:8%' : '') };
    });
  }
  const end = dur > 0 ? dur : partial ? 0 : cues.reduce((m, c) => Math.max(m, (c && c.e) || 0), 0);
  const order = cues.map((c, i) => i).filter(i => cues[i] && cues[i].text).sort((a, b) => cues[a].s - cues[b].s);
  const rank = new Array(cues.length);
  order.forEach((i, r) => { rank[i] = r; });
  // 逐行打分。before = 这一行前面那句话的最后一行（同一条里的上一行，或紧挨着的上一条）：没有句末标点、
  // 这一行又是小写开头，就是没说完接下来的半句，行首的英文署名规则不算
  const lines = new Array(cues.length).fill(null);
  let prevEnd = -Infinity, prevLast = '';
  for (const i of order) {
    const c = cues[i];
    let before = c.s - prevEnd <= 1 ? prevLast : '';
    lines[i] = c.text.split('\n').map(l => {
      const x = subLineInfo(l, !!before && /^[a-z]/.test(l.replace(/<[^>]*>/g, '').trimStart()) && !SUB_STOP.test(before));
      x.l = l;
      if (x.t) before = x.t;
      return x;
    });
    prevEnd = c.e; prevLast = before;
  }
  // 水印：整份字幕里反复出现、带点署名味道的同一行
  let marks = null;
  if (!partial && order.length >= 20) {
    const seen = new Map();
    for (const i of order) {
      const once = new Set();
      for (const x of lines[i]) {
        const k = subMarkKey(x.t);
        if (k.length < 2 || once.has(k)) continue;
        once.add(k);
        const e = seen.get(k);
        if (e) { e.c++; e.last = cues[i].s; } else seen.set(k, { c: 1, first: cues[i].s, last: cues[i].s, n: x.n, t: x.t });
      }
    }
    const span = Math.min(600, Math.max(60, end * 0.2));
    for (const [k, e] of seen) {
      if (e.c >= 3 && e.last - e.first >= span && (e.n >= 2 || (e.n >= 1 && SUB_MARK_SHAPE.test(e.t)))) (marks || (marks = new Set())).add(k);
    }
  }
  const isEdge = i => { const c = cues[i]; return c.s < SUB_EDGE_S || (end > 0 && c.e > end - SUB_EDGE_S) || (!partial && (rank[i] < SUB_EDGE_N || rank[i] >= order.length - SUB_EDGE_N)); };
  const bar = i => isEdge(i) ? ((cues[i].e - cues[i].s) >= SUB_LONG_S ? 2 : 3) : 4;
  const kill = new Array(cues.length);            // 每条：要删的行（下标集合）
  const gone = new Array(cues.length);            // 每条：整条删干净了
  const allGone = i => kill[i].size > 0 && lines[i].every((x, j) => kill[i].has(j) || !x.t || SUB_DECOR.test(x.t));
  // 一条里有行要删：剩下带署名味道的行（≥ 2 分：@账号、邮箱、鸣谢）也不留；整行只有职位的那一行（「翻 译」）删了，
  // 名字在它下面，同一条里往下都删。返回这一条是不是删干净了
  const spread = i => {
    const k = kill[i], L = lines[i];
    if (!k.size) return false;
    L.forEach((x, j) => { if (x.n >= 2) k.add(j); });
    const h = L.findIndex((x, j) => x.head && k.has(j));
    if (h >= 0) for (let j = h + 1; j < L.length; j++) k.add(j);
    return allGone(i);
  };
  for (const i of order) {
    const b = bar(i), k = new Set(), L = lines[i];
    L.forEach((x, j) => { if (x.n >= 9 || x.n >= b || (marks && x.t && marks.has(subMarkKey(x.t)))) k.add(j); });
    kill[i] = k;
    gone[i] = spread(i);
  }
  // 一串职位行（「翻译 张三」「校对 李四」：没有冒号，各自只有 2 分）：片头片尾前后挨着的互相作证，一起删
  const roleAt = (r, s) => { const j = order[r]; return j != null && Math.abs(cues[j].s - s) <= SUB_BLOCK_S && lines[j].some(x => x.role && x.n >= 2); };
  const run = [];
  for (let r = 0; r < order.length; r++) {
    const i = order[r];
    if (!gone[i] && isEdge(i) && lines[i].some((x, j) => x.role && x.n >= 2 && !kill[i].has(j)) && (roleAt(r - 1, cues[i].s) || roleAt(r + 1, cues[i].s))) run.push(i);
  }
  for (const i of run) {
    lines[i].forEach((x, j) => { if (x.role && x.n >= 2) kill[i].add(j); });
    gone[i] = spread(i);
  }
  // 只有职位的一条（整条删了，最后一行是职位、名字不在这一条里），名字另起一条、时间一模一样
  // （ASS 里分开排版的署名卡）：一起删。明摆着是对白的（问号 / 句号收尾、对白横杠）不动
  for (let r = 0; r < order.length; r++) {
    const i = order[r];
    if (!gone[i]) continue;
    const said = lines[i].filter(x => x.t);
    if (!said.length || !said[said.length - 1].head) continue;
    for (const d of [-1, 1]) {
      for (let q = r + d; order[q] != null; q += d) {
        const j = order[q];
        if (Math.abs(cues[j].s - cues[i].s) > 0.1) break;
        if (gone[j] || Math.abs(cues[j].e - cues[i].e) > 0.1 || lines[j].some(x => SUB_SAY.test(x.t))) continue;
        lines[j].forEach((x, n) => kill[j].add(n));
        gone[j] = true;
      }
    }
  }
  // 署名块：片头片尾，挨着一条删干净的（前后 SUB_BLOCK_S 秒内），≥ 2 分的行一起删；连着的一串要传两轮
  for (let pass = 0; pass < 2; pass++) {
    for (let r = 0; r < order.length; r++) {
      const i = order[r];
      if (gone[i] || !isEdge(i)) continue;
      const near = j => j != null && gone[j] && Math.abs(cues[j].s - cues[i].s) <= SUB_BLOCK_S;
      if (!near(order[r - 1]) && !near(order[r + 1])) continue;
      let hit = false;
      lines[i].forEach((x, j) => { if (x.n >= 2 && !kill[i].has(j)) { kill[i].add(j); hit = true; } });
      if (hit) gone[i] = spread(i);
    }
  }
  const out = [];
  for (let i = 0; i < cues.length; i++) {
    const c = cues[i];
    if (!c || !c.text) continue;
    if (!kill[i] || !kill[i].size) { out.push(c); continue; }
    if (gone[i]) continue;
    const text = lines[i].filter((x, j) => !kill[i].has(j)).map(x => x.l).join('\n').trim();
    if (!text || SUB_DECOR.test(text.replace(/<[^>]*>/g, ''))) continue;
    out.push({ ...c, text: hlsVttEscape(text) });
  }
  return out;
}

/* 整份字幕洗一次、留在这个 isolate 里：外挂 / 在线字幕的 HLS 分段每段只取自己那一截，
   不必每一段都把整份读出来再洗一遍（水印也只有看得到整份才认得出） */
const SUB_MEMO = new Map();
function subMemo(key, make) {
  const hit = SUB_MEMO.get(key);
  if (hit) { SUB_MEMO.delete(key); SUB_MEMO.set(key, hit); return hit; }
  return Promise.resolve(make()).then(v => {
    SUB_MEMO.set(key, v);
    while (SUB_MEMO.size > 8) SUB_MEMO.delete(SUB_MEMO.keys().next().value);
    return v;
  });
}
// ASS 里专门放署名 / 广告的样式（Staff、Credit、字幕组……）：整条不要。注释（Note / 注释）与内容有关，留着
const SUB_STAFF_STYLE = /^(?:staff\w*|credits?|ads?|advert\w*|promo\w*|制作人?[员員]?|製作人?[員员]?|字幕[组組]|广告|廣告|声明|聲明|信息|資訊|资讯|info)$/i;

/** 分段 WebVTT。dur = 片长（秒）：清洗时分片头片尾用。
 *  cues 是这一段窗口里的那几条 → 按 partial 洗；opt.cleaned = 已经整份洗过（外挂 / 在线字幕），不再洗 */
function hlsVtt(cues, dur, opt) {
  const out = ['WEBVTT', `X-TIMESTAMP-MAP=MPEGTS:${HLS_T0 * 90000},LOCAL:00:00:00.000`, ''];
  const seen = new Set();
  const list = opt && opt.cleaned ? cues.slice() : subClean(cues, dur, { partial: true });
  for (const c of list.sort((a, b) => a.s - b.s || a.e - b.e)) {
    if (!c.text || !(c.e > c.s)) continue;
    const key = `${c.s}|${c.e}|${c.text}`;
    if (seen.has(key)) continue;          // ASS 多图层常有完全相同的对白
    seen.add(key);
    out.push(`${hlsVttTime(c.s)} --> ${hlsVttTime(c.e)}${c.settings || ''}`, c.text, '');
  }
  return out.join('\n');
}

function hlsSegWindow(idx, k) {
  const sec = u => u * idx.scaleNs / 1e9;
  const a = k === 0 ? 0 : sec(idx.segs[k][2]);
  const b = k + 1 < idx.segs.length ? sec(idx.segs[k + 1][2]) : idx.dur + 1;
  return [a, b];
}

/** 读一小段字节（字幕块 / 簇头），走与 /stream 相同的可续传上游 */
function hlsSmallReader(cx) {
  const meta = cx.linkData.metadata;
  const linkRef = { link: cx.linkData.link, metadata: meta, size: meta.size,
    identity: meta.content_hash || meta.rev || String(meta.size || '') };
  const budget = makeStreamBudget(cx.env);
  const open = upstreamOpener(cx.filePath, linkRef, cx.env, cx.ctx, { budget, signal: cx.signal, hedge: true, label: 'hls-small' });
  const rOpt = { stallMs: stallMs(cx.env), maxResume: resumeMax(cx.env), maxOpen: openMax(cx.env), signal: cx.signal };
  return (a, b) => fetchExact(open, a, Math.min(meta.size - 1, b), rOpt);
}

async function hlsSubDecode(sub, frame) {
  let d = frame;
  if (sub.strip) d = hlsConcat([hlsUnB64(sub.strip), d]);
  else if (sub.zlib) {
    const ds = new Response(new Blob([d]).stream().pipeThrough(new DecompressionStream('deflate')));
    d = new Uint8Array(await ds.arrayBuffer());
  }
  return d;
}

/** 内封字幕的第 k 段 */
async function hlsSubSegment(cx, idx, si, k) {
  const sub = idx.subs[si];
  const [T1, T2] = hlsSegWindow(idx, k);
  const sec = u => u * idx.scaleNs / 1e9;
  const cues = [];
  const pick = sub.cues.filter(c => {
    const s = sec(c[0]), e = c[1] >= 0 ? s + sec(c[1]) : s + 10;
    return s < T2 && e > T1;
  });
  if (sub.cues.length && pick.every(c => c[3] >= 0)) {
    // Cues 精确到块：簇头 16 字节 + 字幕块附近一小窗，两段并行读，绝不读整簇
    const read = hlsSmallReader(cx);
    const byCluster = new Map();
    for (const c of pick) {
      if (!byCluster.has(c[2])) byCluster.set(c[2], []);
      byCluster.get(c[2]).push(c);
    }
    await Promise.all([...byCluster].map(async ([cl, list]) => {
      const abs = idx.segStart + cl;
      const wins = [];
      for (const c of list.sort((a, b) => a[3] - b[3])) {
        const w = wins[wins.length - 1];
        if (w && c[3] - w.hi < 65536) { w.hi = c[3]; w.cues.push(c); }
        else wins.push({ lo: c[3], hi: c[3], cues: [c] });
      }
      // 簇数据起点 = abs + 4(ID) + L(尺寸字段 1~8 字节)；窗口从 abs+5+rel 开始，块在窗口内偏移 L−1
      const hdrP = read(abs, abs + 15);
      const bufs = wins.map(w => read(abs + 5 + w.lo, abs + 12 + w.hi + 16383));
      const hdr = await hdrP;
      const id = ebmlId(hdr, 0, hdr.length), sz = id && ebmlSize(hdr, id[1], hdr.length);
      if (!id || id[0] !== MKV.Cluster || !sz) return;
      const data = abs + id[1] + sz[1];
      for (let i = 0; i < wins.length; i++) {
        let buf = await bufs[i];
        const base = abs + 5 + wins[i].lo;
        for (const c of wins[i].cues) {
          let at = data + c[3] - base;
          let el = ebmlChildren(buf, at, buf.length).next().value;
          if (el && el.cut && el.size < 4 * 1048576) {
            buf = await read(base + at, base + el.end - 1);      // 罕见的超长字幕块：补读整块
            at = 0;
            el = ebmlChildren(buf, 0, buf.length).next().value;
          }
          if (!el || el.cut) continue;
          const b = mkvParseBlockEl(buf, el);
          if (!b || b.track !== sub.num) continue;
          const s = sec(c[0]);
          const dur = b.dur >= 0 ? sec(b.dur) : c[1] >= 0 ? sec(c[1]) : 3;
          const t = hlsSubFrameText(sub.fmt, await hlsSubDecode(sub, b.frames[0]));
          if (t.text) cues.push({ s, e: s + dur, ...t });
        }
      }
    }));
  } else if (!sub.cues.length || pick.length) {
    // 没有字幕 Cues（少数封装器）：扫这一段的字节
    const plan = hlsSegPlan(idx, k);
    const src = hlsByteSource(cx, plan.start, plan.fetchEnd);
    try {
      for await (const b of { [Symbol.asyncIterator]: () => hlsBlocks(src, plan, idx, new Set([sub.num])) }) {
        const s = sec(b.ts);
        const t = hlsSubFrameText(sub.fmt, await hlsSubDecode(sub, hlsConcat(b.frames[0])));
        if (t.text) cues.push({ s, e: s + (b.dur >= 0 ? sec(b.dur) : 3), ...t });
      }
    } finally { src.close('subs'); }
  }
  return hlsVtt(cues, idx.dur);
}

// ── 外挂字幕 ──

/** 同目录字幕文件（与 /api/subs 同一套匹配规则） */
async function hlsSidecarSubs(filePath, env) {
  const slash = filePath.lastIndexOf('/');
  const folder = slash > 0 ? filePath.slice(0, slash) : (env.ROOT_FOLDER || '');
  const fileName = filePath.slice(slash + 1);
  const dot = fileName.lastIndexOf('.');
  const stem = (dot > 0 ? fileName.slice(0, dot) : fileName).toLowerCase();
  let entries = [];
  try {
    entries = await singleFlight(`sub-dir:${folder}`, async () => {
      const list = [];
      let res = await dbxListFolder(folder, env);
      list.push(...(res.entries || []));
      while (res.has_more) {
        res = await dbxListFolder(null, env, res.cursor);
        list.push(...(res.entries || []));
      }
      return list;
    });
  } catch { return []; }
  const videoCount = entries.filter(e => e['.tag'] === 'file' && VIDEO_EXTS.has(getExt(e.name))).length;
  return entries
    .filter(e => e['.tag'] === 'file' && SUB_EXTS.has(getExt(e.name))
      && (e.name.toLowerCase().startsWith(stem) || videoCount <= 1))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(e => ({ name: e.name, path: e.path_display, rev: e.rev || e.content_hash || '', ext: getExt(e.name), ...inferSubLang(e.name, stem) }));
}

/** HLS 这边的在线字幕：已有字幕 = 内封 + 同目录外挂 */
function hlsOnline(cx, idx, xs, waitMs) {
  if (!osOn(cx.env)) return Promise.resolve(null);
  const bg = { ...cx, signal: undefined };                    // 后台读：请求结束了也要读完
  const tracks = [
    ...idx.subs.map((s, i) => ({ id: 's' + i, lang: s.lang, forced: s.forced, sample: () => hlsSubSample(bg, idx, i) })),
    ...xs.map((x, i) => ({ id: 'x' + i, lang: x.srclang, rev: x.rev,
      sample: async () => (await hlsSidecarCues(x, cx.env, cx.ctx)).slice(0, 400).map(c => c.text).join('\n') })),
  ];
  // 对齐参照：内封（不花一个字节）优先，再外挂
  const refs = async () => syncRefFromIdx(idx) || await syncRefFromSidecars(xs, cx.env, cx.ctx);
  const file = { filePath: cx.filePath, name: cx.filePath.split('/').pop(), meta: cx.linkData.metadata,
    read: hlsSmallReader(bg), fps: idx.video.fps || 0, dur: idx.dur || 0, refs };
  return osFor(cx.env, cx.ctx, file, tracks, waitMs).then(r => osUpgradeSync(cx.env, cx.ctx, r, refs));
}
/** 记录是直连那边先建的（只有外挂参照，或者没对齐过）：这边有内封参照就重算一次，存回去 */
async function osUpgradeSync(env, ctx, r, refs) {
  if (!r || !r.rec || !r.key || !osSyncWeaker(r.rec, SYNC_RANK.local)) return r;
  const ref = await Promise.race([refs().catch(() => null), new Promise(res => setTimeout(() => res(null), 1500))]);
  if (!ref) return r;
  const rec = { ...r.rec, sync: osSyncWith(r.rec.cues, ref) };
  ctx?.waitUntil?.(osSave(env, r.key, rec).catch(e => console.error('subsync save:', e && e.message)));
  osRemember(r.key, rec);
  return { ...r, rec };
}
/** 内封字幕抽一段文字（认繁简用）：有 Cues 才抽（精确读几个字幕块）；没有就不抽，当作认不出 */
async function hlsSubSample(cx, idx, si) {
  const sub = idx.subs[si];
  if (!sub || hlsSubNeedsScan(sub)) return '';
  const n = idx.segs.length;
  let text = '';
  for (const k of [...new Set([Math.floor(n * 0.2), Math.floor(n * 0.5)])]) {
    text += (await hlsSubSegment(cx, idx, si, k)).replace(/^(WEBVTT|X-TIMESTAMP-MAP|\d\d:\d\d:\d\d).*$/gm, '');
  }
  return text;
}

/** 字幕文件全文 → [{ s, e, text, settings }]（秒） */
function hlsParseSubFile(text, ext) {
  const norm = String(text).replace(/^﻿/, '').replace(/\r\n?/g, '\n');
  const cues = [];
  const t2s = (h, m, s, f) => (+h) * 3600 + (+m) * 60 + (+s) + (+(`${f}`.padEnd(3, '0').slice(0, 3))) / 1000;
  if (ext === '.ass' || ext === '.ssa' || /\[Events\]/i.test(norm)) {
    let inEv = false, si = 1, ei = 2, ti = 9, sti = 3, ni = 4;
    for (const raw of norm.split('\n')) {
      const l = raw.trim();
      if (/^\[Events\]/i.test(l)) { inEv = true; continue; }
      if (/^\[.*\]$/.test(l)) { if (inEv) break; continue; }
      if (!inEv) continue;
      if (/^Format\s*:/i.test(l)) {
        const cols = l.slice(l.indexOf(':') + 1).split(',').map(x => x.trim().toLowerCase());
        if (cols.includes('start')) si = cols.indexOf('start');
        if (cols.includes('end')) ei = cols.indexOf('end');
        if (cols.includes('text')) ti = cols.indexOf('text');
        sti = cols.indexOf('style'); ni = cols.indexOf('name');
        continue;
      }
      if (!/^Dialogue\s*:/i.test(l)) continue;
      const body = l.slice(l.indexOf(':') + 1);
      const ps = [];
      let cur = 0;
      for (let i = 0; i < ti; i++) { const c = body.indexOf(',', cur); if (c < 0) break; ps.push(body.slice(cur, c)); cur = c + 1; }
      ps.push(body.slice(cur));
      const a = /(\d+):(\d{2}):(\d{2})[.:](\d{1,3})/.exec(ps[si] || ''), b = /(\d+):(\d{2}):(\d{2})[.:](\d{1,3})/.exec(ps[ei] || '');
      if (!a || !b) continue;
      if ((sti >= 0 && SUB_STAFF_STYLE.test((ps[sti] || '').trim())) || (ni >= 0 && SUB_STAFF_STYLE.test((ps[ni] || '').trim()))) continue;
      const s = t2s(a[1], a[2], a[3], a[4].length === 2 ? a[4] + '0' : a[4]);
      const e = t2s(b[1], b[2], b[3], b[4].length === 2 ? b[4] + '0' : b[4]);
      const t = hlsAssText(ps[ti] || '');
      if (t.text && e > s) cues.push({ s, e, ...t });
    }
    return cues;
  }
  for (const block of norm.replace(/^WEBVTT[^\n]*\n+/, '').split(/\n{2,}/)) {
    const ls = block.trim().split('\n');
    const at = ls.findIndex(x => x.includes('-->'));
    if (at < 0) continue;
    const m = /(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[,.](\d{1,3})\s*-->\s*(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[,.](\d{1,3})/.exec(ls[at]);
    if (!m) continue;
    const s = t2s(m[1] || 0, m[2], m[3], m[4]), e = t2s(m[5] || 0, m[6], m[7], m[8]);
    const u = subUnAss(ls.slice(at + 1).join('\n'));
    const text = hlsVttEscape(u.text);
    if (text && e > s) cues.push({ s, e, text, settings: u.top ? ' line:8%' : '' });
  }
  return cues;
}

async function hlsSidecarCues(x, env, ctx) {
  const ck = new Request(`${HLS_SUB_CACHE}x?p=${encodeURIComponent(x.path)}&r=${encodeURIComponent(x.rev)}&v=${HLS_VER}&c=${SUB_CLEAN_V}`);
  const hit = await caches.default.match(ck);
  if (hit) { try { return await hit.json(); } catch {} }
  return singleFlight(`hls-x:${x.path}|${x.rev}`, async () => {
    const link = await getTempLink(x.path, env, ctx);
    const res = await fetchRetry(link.link, {}, { retries: 1, timeout: 10_000 });
    if (!res.ok) throw hlsErr('外挂字幕读取失败', 502);
    const cues = hlsParseSubFile(decodeSubtitleBytes(new Uint8Array(await res.arrayBuffer())), x.ext);
    ctx?.waitUntil?.(caches.default.put(ck, new Response(JSON.stringify(cues), {
      headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=86400' },
    })).catch(() => {}));
    return cues;
  });
}

// ── 可选：DTS / TrueHD 等音轨实时转 AC-3（接上转码 Worker 后启用：绑定 AUDIO_TX 或设 AUDIO_TX_URL）──
//  转码音轨的分段边界单独排：每段起点 S_k 落在全局 AC-3 帧网格上，并比视频分段
//  起点晚约 0.35s —— 留出「从本段第一个可解码帧预热到 S_k」的余量（TrueHD 要等
//  major sync，DTS 的 QMF 要收敛）。本段读完自己的字节后再越过边界多读一点，
//  让最后一帧的 MDCT 重叠区也用真实采样。于是相邻两段的接缝两边算的是同一段 PCM，
//  解码端的 TDAC 能正常抵消，不出爆音。

const HLS_TX_MARGIN = 0.35;

/**
 * 转码 Worker 的两种接法，调用方一视同仁：
 *  · Service Binding `AUDIO_TX`（进程内调用，最快）
 *  · 变量 `AUDIO_TX_URL`（例如 https://audio.cuven.us，转码 Worker 挂了自定义域名时用）
 * 配了 `AUDIO_TX_KEY` 就在请求头里带上共享密钥 —— 转码 Worker 那边配了同一个值时，
 * 不带或带错的请求一律 401，公网地址不会被外人拿去白耗 CPU。
 */
function hlsTxService(env) {
  if (!env) return null;
  const key = env.AUDIO_TX_KEY ? String(env.AUDIO_TX_KEY) : '';
  const bound = env.AUDIO_TX && typeof env.AUDIO_TX.fetch === 'function' ? env.AUDIO_TX : null;
  const base = !bound && env.AUDIO_TX_URL ? String(env.AUDIO_TX_URL).trim().replace(/\/+$/, '') : '';
  if (!bound && !/^https?:\/\/[^/\s]+/i.test(base)) return null;
  return {
    via: bound ? 'binding' : base.replace(/^https?:\/\//i, ''),
    fetch(path, init = {}) {
      const headers = new Headers(init.headers || undefined);
      if (key) headers.set('X-Audio-Tx-Key', key);
      return bound ? bound.fetch(`https://audio-tx${path}`, { ...init, headers }) : fetch(`${base}${path}`, { ...init, headers });
    },
  };
}
function hlsTxOn(env) { return !!hlsTxService(env); }

/** 转码音轨各分段的起点（输出采样序号），长度 = 分段数 + 1 */
function hlsTxBounds(idx, a) {
  const n = idx.segs.length, fs = 1536, r = a.ts;
  const margin = 1280 + Math.round(HLS_TX_MARGIN * r);
  const out = [a.anchor];
  for (let k = 1; k < n; k++) {
    const t = idx.segs[k][2] * idx.scaleNs / 1e9;
    const g = a.anchor + Math.ceil((t * r - a.anchor + margin) / fs) * fs;
    out.push(Math.max(out[k - 1] + fs, g));
  }
  const end = a.anchor + Math.max(fs, Math.ceil((idx.dur * r - a.anchor) / fs) * fs);
  out.push(Math.max(out[n - 1] + fs, end));
  return out;
}
function hlsTxDurs(idx, a) {
  const B = hlsTxBounds(idx, a);
  return idx.segs.map((s, k) => Math.round((B[k + 1] - B[k]) / a.ts * 1000) / 1000);
}

/** Opus 包时长（采样数，48k）——由 TOC 决定 */
function hlsOpusSamples(d) {
  if (!d || !d.length) return 960;
  const toc = d[0], cfg = toc >> 3;
  const per = cfg < 12 ? [480, 960, 1920, 2880][cfg & 3] : cfg < 16 ? [480, 960][cfg & 1] : [120, 240, 480, 960][cfg & 3];
  const code = toc & 3;
  const n = code === 0 ? 1 : code < 3 ? 2 : (d[1] & 0x3F);
  return per * n;
}

async function* hlsTxSegmentParts(cx, idx, k, ai) {
  const A = idx.audio[ai], T = A.tx;
  const B = hlsTxBounds(idx, A);
  const S0 = B[k], S1 = B[k + 1];
  const frames = Math.round((S1 - S0) / 1536);
  const base = hlsSegPlan(idx, k);
  // 不在下一段关键帧处停：越过边界读到 S1 之后的音频为止（字节上限 = 下一段末尾）
  const plan = { ...base, endCl: -1, endRel: -1, endT: Infinity,
    fetchEnd: k + 1 < idx.segs.length ? hlsSegPlan(idx, k + 1).fetchEnd : base.fetchEnd };
  const untilNs = (S1 + 256 + 2 * 1536) / A.ts * 1e9;
  const strip = A.strip ? hlsUnB64(A.strip) : null;
  const bps = Math.max(1, T.ch * ((T.bits || 16) >> 3));
  const aus = [], parts = [];
  let total = 0;
  const snap = ns => {
    if (T.frameNs > 0) ns = T.anchorNs + Math.round((ns - T.anchorNs) / T.frameNs) * T.frameNs;
    return Math.round(ns * A.ts / 1e9);
  };
  const src = hlsByteSource(cx, plan.start, plan.fetchEnd);
  try {
    outer:
    for await (const blk of { [Symbol.asyncIterator]: () => hlsBlocks(src, plan, idx, new Set([A.num])) }) {
      let ns = blk.ts * idx.scaleNs;
      for (const fr of blk.frames) {
        if (ns > untilNs) break outer;
        let size = 0;
        for (const x of fr) size += x.length;
        if (strip) { parts.push(strip); size += strip.length; }
        for (const x of fr) parts.push(x);            // 只记引用，拼请求体时才拷一次
        aus.push([snap(ns), blk.key ? 1 : 0, size]);
        total += size;
        // 帧内时间推进：laced 帧没有各自的时间戳
        if (T.kind === 4) ns += hlsOpusSamples(strip ? hlsConcat([strip, ...fr]) : fr[0]) * 1e9 / 48000;
        else if ((T.kind >= 6 && T.kind <= 11) || T.kind === 14) ns += size / bps * 1e9 / T.rate;
        else ns += T.frameNs || 20e6;
      }
      if (total > 64 * 1048576) break;
    }
  } finally {
    src.close('tx');
  }
  const head = new TextEncoder().encode(JSON.stringify({
    kind: T.kind, rate: T.rate, ch: T.ch, bits: T.bits, extra: T.extra,
    outCh: A.ch, bitrate: A.bitrate, s0: S0, frames, aus,
  }));
  const body = new Uint8Array(4 + head.length + total);
  new DataView(body.buffer).setUint32(0, head.length);
  body.set(head, 4);
  let o = 4 + head.length;
  for (const p of parts) { body.set(p, o); o += p.length; }
  const res = await hlsTxService(cx.env).fetch('/encode', { method: 'POST', body });
  if (!res.ok) throw new Error(`audio-tx ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const out = new Uint8Array(await res.arrayBuffer());
  const dv = new DataView(out.buffer, out.byteOffset);
  const n = dv.getUint32(0);
  let p = 4 + n * 4;
  const samples = [];
  for (let i = 0; i < n; i++) {
    const s = dv.getUint32(4 + i * 4);
    samples.push({ dur: 1536, size: s, pieces: [out.subarray(p, p + s)] });
    p += s;
  }
  const seq = k * 10000 + 1;
  const half = Math.ceil(samples.length / 2);
  // 两个 moof：首个更早交付，播放器可以边收边解
  yield mp4Fragment(seq, [{ id: 1, video: false, base: S0 + HLS_T0 * A.ts, samples: samples.slice(0, half) }]);
  if (samples.length > half) {
    yield mp4Fragment(seq + 1, [{ id: 1, video: false, base: S0 + half * 1536 + HLS_T0 * A.ts, samples: samples.slice(half) }]);
  }
}

// ── 路由：/hls/<exp>.<sig>.<b64url(path)>/… ──
//  令牌放在路径里而不是查询串：播放列表里的相对 URI 会自然继承它，
//  原生播放器（AVPlayer）不带 Cookie 也能一路鉴权。签名与 /stream 完全相同。

function hlsTokenFor(filePath, sign) {
  return `${sign ? sign.exp : 0}.${sign ? sign.sig : 0}.${hlsB64url(filePath)}`;
}
function hlsParseToken(seg) {
  const m = /^(\d+)\.([0-9a-f]+)\.([A-Za-z0-9_-]+)$/.exec(seg || '');
  if (!m) return null;
  try { return { exp: +m[1], sig: m[2], path: hlsUnB64url(m[3]) }; } catch { return null; }
}
/* 验过的令牌记在这个 isolate 里，直到它过期：同一次播放的几百个分段 / 字幕请求带的是同一个令牌，
   不必每个请求重算一遍 HMAC。只有验证通过的才进来，伪造的永远进不来；换了密钥就换一张表 */
const HLS_TOK_OK = new Map();
let HLS_TOK_KEY = '';
async function hlsVerifyPath(pathname, env) {
  try {
    const raw = pathname.split('/')[2];
    const tok = hlsParseToken(raw);
    if (!tok || !tok.path || tok.exp * 1000 < Date.now()) return false;
    if (HLS_TOK_KEY !== env.AUTH_SECRET) { HLS_TOK_OK.clear(); HLS_TOK_KEY = env.AUTH_SECRET; }
    if (HLS_TOK_OK.get(raw) === tok.exp) return true;
    const ok = timingSafeEqualStr(tok.sig, await hmacHex(env.AUTH_SECRET, `${tok.path}|${tok.exp}`));
    if (ok) {
      if (HLS_TOK_OK.size >= 256) HLS_TOK_OK.delete(HLS_TOK_OK.keys().next().value);
      HLS_TOK_OK.set(raw, tok.exp);
    }
    return ok;
  } catch { return false; }
}
/** 只有 MKV 走 HLS；MP4/MOV 仍由 /stream 直出（v24 的 FourCC 热修补照旧生效） */
function hlsEligible(filePath) { return getExt(filePath) === '.mkv'; }
async function hlsMasterPath(filePath, env) {
  const sign = env.AUTH_SECRET ? await signStreamPath(filePath, env) : null;
  return `/hls/${hlsTokenFor(filePath, sign)}/master.m3u8`;
}

const _hlsIdx = new Map();
function hlsRemember(key, idx) {
  _hlsIdx.delete(key);
  _hlsIdx.set(key, idx);
  while (_hlsIdx.size > 12) _hlsIdx.delete(_hlsIdx.keys().next().value);
}
async function hlsIndexFor(cx, opts) {
  const key = `${cx.identity}|${cx.size}|${opts.dv}|${opts.segSec}|v${HLS_VER}`;
  const mem = _hlsIdx.get(key);
  if (mem) { if (mem.error) throw hlsErr(mem.error, mem.status); return mem; }
  return singleFlight(`hls-idx:${key}`, async () => {
    const ck = new Request(`${HLS_IDX_CACHE}i${HLS_IDX_V}/${encodeURIComponent(key)}`);
    let idx = null;
    try { const hit = await caches.default.match(ck); if (hit) idx = await hit.json(); } catch {}
    if (!idx) {
      try {
        // 不挂请求的中止信号：首个请求被取消也要把索引建完，后面的请求都等着用
        idx = await hlsBuildIndex({ size: cx.size, read: hlsSmallReader({ ...cx, signal: undefined }) }, opts);
        idx.idh = fnv1a(key) + (opts.dv !== 'auto' ? `.${opts.dv}` : '')
          + (idx.video && (idx.video.annexB || idx.video.psRebuilt) ? '.ps' : '');
      } catch (e) {
        if (!e.status || e.status >= 500) throw e;       // 瞬时故障不落缓存
        idx = { error: e.message, status: e.status };
      }
      cx.ctx?.waitUntil?.(caches.default.put(ck, new Response(JSON.stringify(idx), {
        headers: { 'Content-Type': 'application/json',
          'Cache-Control': `public, max-age=${idx.error ? 86400 : 30 * 86400}` },
      })).catch(() => {}));
    }
    hlsRemember(key, idx);
    if (idx.error) throw hlsErr(idx.error, idx.status);
    return idx;
  });
}

/** 所有媒体列表共用一个 TARGETDURATION（Apple 规范 8.2） */
function hlsTarget(idx, env) {
  let max = Math.max(...idx.durs.map(d => Math.round(d)));
  if (hlsTxOn(env)) {
    for (const a of idx.audio) if (a.mode === 'tx') max = Math.max(max, ...hlsTxDurs(idx, a).map(d => Math.round(d)));
  }
  return Math.max(1, max);
}

function hlsMaster(idx, xs, env, os) {
  const V = idx.video, idh = idx.idh;
  const L = ['#EXTM3U', '#EXT-X-VERSION:7', '#EXT-X-INDEPENDENT-SEGMENTS'];
  const codecs = [V.codecs];
  const used = new Set();
  const uniq = s => { let n = s, i = 2; while (used.has(n)) n = `${s} (${i++})`; used.add(n); return n; };

  const copy = idx.audio.map((a, i) => i).filter(i => idx.audio[i].mode === 'copy');
  const tx = hlsTxOn(env) ? idx.audio.map((a, i) => i).filter(i => idx.audio[i].mode === 'tx') : [];
  // 默认音轨：能直通的复用轨；没有就用转码轨（DTS / TrueHD 独占的片源）
  let def = idx.muxed;
  if (def < 0 && tx.length) {
    def = tx.find(i => idx.audio[i].def && !idx.audio[i].commentary)
      ?? tx.find(i => !idx.audio[i].commentary) ?? tx[0];
  }
  const hasAudio = def >= 0;
  if (hasAudio) {
    for (const i of [def, ...copy.filter(i => i !== def), ...tx.filter(i => i !== def)]) {
      const a = idx.audio[i];
      if (!codecs.includes(a.codecs)) codecs.push(a.codecs);
      const at = ['TYPE=AUDIO', 'GROUP-ID="aud"', `LANGUAGE="${hlsAttr(a.lang)}"`,
        `NAME="${hlsAttr(uniq(hlsAudioLabel(a)))}"`, `DEFAULT=${i === def ? 'YES' : 'NO'}`,
        'AUTOSELECT=YES', `CHANNELS="${a.joc ? `${a.joc}/JOC` : a.ch}"`];
      // 无 URI = 复用在视频分段里
      if (i !== idx.muxed) at.push(`URI="${idh}/${a.mode === 'tx' ? 't' : 'a'}${i}.m3u8"`);
      L.push(`#EXT-X-MEDIA:${at.join(',')}`);
    }
  }

  // 只标了「中文」、抽样认出是繁体的那几条：改标繁体中文（在线找来的简体就排到它前面）
  const trad = new Set((os && os.need && os.need.trad) || []);
  const subs = [
    ...idx.subs.map((s, i) => trad.has('s' + i)
      ? { uri: `${idh}/s${i}.m3u8`, lang: 'zh-Hant', name: '繁体中文', forced: s.forced, hi: s.hi }
      : { uri: `${idh}/s${i}.m3u8`, lang: s.lang, name: s.name, forced: s.forced, hi: s.hi }),
    ...xs.map((x, i) => trad.has('x' + i)
      ? { uri: `${idh}/x${i}.m3u8`, lang: 'zh-Hant', name: '繁体中文', forced: false, hi: false }
      : { uri: `${idh}/x${i}.m3u8`, lang: x.srclang || 'und', name: x.label, forced: false, hi: false }),
  ];
  if (os && os.rec) subs.push({ uri: `${idh}/o0.m3u8`, lang: os.rec.lang, name: os.rec.label, forced: false, hi: false, online: true });
  // 默认显示中文字幕（简体优先）——与之前播放页自动挂第一条外挂字幕的行为一致。
  // 一条字幕都没有的片子，在线找来的那条（哪怕是英文）也默认打开 —— 本来就是为它找的
  const rank = l => ({ 'zh-Hans': 1, zh: 2, 'zh-Hant': 3, yue: 4 }[l] || 9);
  const best = subs.filter(s => !s.forced).sort((a, b) => rank(a.lang) - rank(b.lang))[0];
  const usedS = new Set();
  for (const s of subs) {
    let n = s.name || hlsLangName(s.lang);
    if (s.forced && !/强制|forced/i.test(n)) n += '（强制）';
    let nn = n, i = 2;
    while (usedS.has(nn)) nn = `${n} (${i++})`;
    usedS.add(nn);
    const at = ['TYPE=SUBTITLES', 'GROUP-ID="sub"', `LANGUAGE="${hlsAttr(s.lang)}"`, `NAME="${hlsAttr(nn)}"`,
      `DEFAULT=${best && s === best && (rank(s.lang) < 9 || s.online) ? 'YES' : 'NO'}`, 'AUTOSELECT=YES', `FORCED=${s.forced ? 'YES' : 'NO'}`];
    if (s.hi) at.push('CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound"');
    at.push(`URI="${s.uri}"`);
    L.push(`#EXT-X-MEDIA:${at.join(',')}`);
  }

  const inf = [`BANDWIDTH=${Math.max(idx.bw.peak, idx.bw.avg, 1)}`, `AVERAGE-BANDWIDTH=${Math.max(idx.bw.avg, 1)}`,
    `CODECS="${codecs.join(',')}"`];
  if (V.supp) inf.push(`SUPPLEMENTAL-CODECS="${V.supp}"`);
  inf.push(`RESOLUTION=${V.dw}x${V.h}`);
  if (V.fps) inf.push(`FRAME-RATE=${V.fps.toFixed(3)}`);
  inf.push(`VIDEO-RANGE=${V.range}`);
  if (hasAudio) inf.push('AUDIO="aud"');
  if (subs.length) inf.push('SUBTITLES="sub"');
  inf.push('CLOSED-CAPTIONS=NONE');
  L.push(`#EXT-X-STREAM-INF:${inf.join(',')}`, `${idh}/v.m3u8`);
  return L.join('\n') + '\n';
}

function hlsMediaPl(idx, map, seg, target, durs = idx.durs) {
  const L = ['#EXTM3U', '#EXT-X-VERSION:7', `#EXT-X-TARGETDURATION:${target}`, '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-PLAYLIST-TYPE:VOD', '#EXT-X-INDEPENDENT-SEGMENTS'];
  if (map) L.push(`#EXT-X-MAP:URI="${map}"`);
  durs.forEach((d, k) => L.push(`#EXTINF:${d.toFixed(3)},`, seg(k)));
  L.push('#EXT-X-ENDLIST');
  return L.join('\n') + '\n';
}

const HLS_M3U8 = 'application/vnd.apple.mpegurl';
const HLS_LONG = 'public, max-age=86400';
function hlsHeaders(type, cc) {
  return { 'Content-Type': type, 'Cache-Control': cc, 'X-Content-Type-Options': 'nosniff', ...CORS_HEADERS };
}
function hlsOut(body, type, cc = HLS_LONG) { return new Response(body, { headers: hlsHeaders(type, cc) }); }
function hlsFail(status, message) {
  return new Response(JSON.stringify({ error: message }), {
    status, headers: { ...hlsHeaders('application/json; charset=utf-8', 'no-store') },
  });
}

/**
 * 分段响应：先拿到第一个 moof 再发响应头 —— 回源失败时还能回一个干净的错误码。
 * 每个 moof 片段（约 1 秒）拼成一块连续缓冲再交付：同一上游缓冲区的多个子视图
 * 分别入队，在会转移（detach）入队缓冲区的运行时里会互相踩坏；拼一次的代价是
 * 一次 memcpy，换来的是入队次数从几百次降到每秒一次。
 *
 * 主画面（视频 + 复用音轨）先查边缘缓存；同一 isolate 里正有一路预取在取这一段，
 * 就等它写完再从缓存出。现取的这一遍取完以后，后台接着把下一段取进缓存。
 */
async function hlsSegResponse(cx, idx, k, sel, type, request) {
  if (!(k >= 0 && k < idx.segs.length)) return hlsFail(404, 'no such segment');
  if (request.method === 'HEAD') return new Response(null, { headers: hlsHeaders(type, HLS_LONG) });
  const main = sel.video && hlsCacheOn(cx);
  if (main) {
    const key = hlsSegKey(idx, k);
    let res = await hlsSegCached(key, type);
    const f = res ? null : HLS_FLIGHTS.get(key);
    if (f) res = await hlsAfterFlight(f, key, type, request.signal);
    if (res) { hlsAhead(cx, idx, k); return res; }
  }
  const ac = new AbortController();
  const fwd = () => ac.abort(request.signal.reason);
  if (request.signal?.aborted) fwd(); else request.signal?.addEventListener('abort', fwd, { once: true });
  // 登记这一遍：同一段的字幕请求等它顺手写好的 VTT（缓存不生效时没有意义，就不收）
  const pass = main ? hlsPassBegin(idx, k) : null;
  const it = hlsSegmentParts({ ...cx, signal: ac.signal }, idx, k, sel, { subs: main, pass, alt: main ? hlsAltFor(idx) : -1 });
  let queue = [], finished = false;
  // 整段取完、连接都放掉了，再在后台取下一段 —— 不跟眼前这一段抢那 6 条连接
  const finish = () => { finished = true; if (main) hlsAhead(cx, idx, k); };
  try {
    const r = await it.next();
    if (r.done) finish(); else queue = hlsChunks(r.value);
  } catch (e) {
    ac.abort(e);
    console.error('hls segment:', cx.filePath, k, e && e.message);
    return hlsFail(e?.name === 'AbortError' ? 499 : 502, 'segment unavailable');
  }
  const body = new ReadableStream({
    async pull(c) {
      try {
        while (!queue.length) {
          if (finished) { c.close(); return; }
          const r = await it.next();
          if (r.done) finish(); else queue = hlsChunks(r.value);
        }
        c.enqueue(queue.shift());
      } catch (e) {
        ac.abort(e);
        c.error(e);
      }
    },
    cancel(reason) {
      ac.abort(reason);
      it.return().catch(() => {});
    },
  });
  return new Response(body, { headers: hlsHeaders(type, HLS_LONG) });
}

// ── 分段边缘缓存与预取 ──
//
// · 只缓存完整的段：数据写在本次独有的键下，整段正常写完以后，才把「指针」写到
//   这一段的固定键上。workerd 的 cache.put 遇到 body 中途出错会报错，但已经写进去的
//   那一截照样落进缓存 —— 没有指针指着的半截数据永远不会被读到。
// · 预取只在发起它的那条请求里跑（waitUntil）。别的请求只读它的进度数字，绝不 await
//   它的 Promise、读它的流或替它中止 I/O —— 跨请求共享 I/O 在 workerd 里不可靠。
// · 每个 isolate 同时只跑一路预取：4K 的一段动辄几十 MB，isolate 只有 128MB。
// · *.workers.dev 上 Cache API 不生效：不预取、不等。

const HLS_FLIGHTS = new Map();    // 分段指针键 → 正在后台取的那一段
const HLS_PASSES = new Map();     // `${idh}|${k}` → 正在过这一段视频字节的几遍（直出 / 预取）
let hlsCacheDeadAt = -Infinity;   // 写进去却读不出来（缓存不生效）的时刻：之后一阵子不再预取

const hlsSleep = ms => new Promise(r => setTimeout(r, ms));
const hlsMainSel = idx => ({ video: true, audio: idx.muxed });
const hlsSegKey = (idx, k) => `${HLS_SUB_CACHE}seg2/${idx.idh}/v/${k}`;

function hlsCacheOn(cx) {
  return hlsPrefetchN(cx.env) > 0 && !/\.workers\.dev$/i.test(cx.host || '')
    && Date.now() - hlsCacheDeadAt > HLS_CACHE_RETRY_MS;
}

/** 缓存里这一段的完整数据：先读指针，再读指针指着的那一份 */
async function hlsSegCached(key, type) {
  const ptr = await caches.default.match(new Request(key)).catch(() => null);
  if (!ptr) return null;
  const at = await ptr.text().catch(() => '');
  if (!at.startsWith(key + '/')) return null;
  const hit = await caches.default.match(new Request(at)).catch(() => null);
  if (!hit || !hit.body) return null;
  return new Response(hit.body, { headers: hlsHeaders(type, HLS_LONG) });
}

/** 登记「正在过第 k 段视频字节」的一遍：同一段的视频 / 字幕请求据此决定等不等它 */
function hlsPassBegin(idx, k) {
  const id = `${idx.idh}|${k}`;
  // subs：0 不收字幕 · 1 收集中 · 2 正写进缓存 · 3 已写好 · -1 没写成
  const p = { id, tick: Date.now(), ended: 0, ok: false, subs: 0 };
  let set = HLS_PASSES.get(id);
  if (!set) {
    if (HLS_PASSES.size >= 64) hlsPrunePasses();
    HLS_PASSES.set(id, set = new Set());
  }
  set.add(p);
  return p;
}
/** 生成器结束、字幕也落定了，就从登记里摘掉 */
function hlsPassDone(p) {
  if (!p.ended || p.subs === 1 || p.subs === 2 || (p.alt && (p.alt.st === 1 || p.alt.st === 2))) return;
  const set = HLS_PASSES.get(p.id);
  if (set && set.delete(p) && !set.size) HLS_PASSES.delete(p.id);
}
/** 还在动：没结束且最近有进度；或刚正常结束、后面的写缓存还没收尾 */
function hlsPassAlive(p) {
  const now = Date.now();
  return p.ended ? p.ok && now - p.ended < HLS_STALL_MS : now - p.tick < HLS_STALL_MS;
}
/** 所在请求被中途回收的那几遍不会自己摘掉：太久没动静的清走 */
function hlsPrunePasses() {
  const now = Date.now();
  for (const [id, set] of HLS_PASSES) {
    for (const p of set) if (now - Math.max(p.tick, p.ended) > 60000) set.delete(p);
    if (!set.size) HLS_PASSES.delete(id);
  }
}

/** 播第 k 段时，后台把下一段取进边缘缓存 */
function hlsAhead(cx, idx, k) {
  for (let j = 1; j <= hlsPrefetchN(cx.env); j++) hlsFlight(cx, idx, k + j);
}

/** 后台把第 k 段取进边缘缓存（在发起它的这条请求里跑）。已在取 / 名额满 → null */
function hlsFlight(cx, idx, k) {
  if (!(k >= 0 && k < idx.segs.length) || !hlsCacheOn(cx)) return null;
  const key = hlsSegKey(idx, k);
  for (const [fk, f] of HLS_FLIGHTS) {
    if (!hlsPassAlive(f.pass) && Date.now() - Math.max(f.pass.tick, f.pass.ended) > 30000) HLS_FLIGHTS.delete(fk);
  }
  if (HLS_FLIGHTS.has(key) || HLS_FLIGHTS.size >= HLS_FLIGHT_MAX) return null;
  const pass = hlsPassBegin(idx, k);
  const f = { pass, done: false, ok: false };
  HLS_FLIGHTS.set(key, f);
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(new Error('prefetch timeout')), HLS_FLIGHT_MS);
  const run = (async () => {
    const have = await hlsSegCached(key, 'video/mp4');
    if (have) { await have.body.cancel().catch(() => {}); return true; }
    const at = `${key}/${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
    const it = hlsSegmentParts({ ...cx, signal: ac.signal }, idx, k, hlsMainSel(idx), { subs: true, pass, alt: hlsAltFor(idx) });
    let complete = false;
    const body = new ReadableStream({
      async pull(c) {
        try {
          const r = await it.next();
          if (r.done) { complete = true; c.close(); } else for (const ch of hlsChunks(r.value)) c.enqueue(ch);
        } catch (e) { c.error(e); }
      },
      cancel(reason) { ac.abort(reason); it.return().catch(() => {}); },
    });
    await caches.default.put(new Request(at), new Response(body, { headers: hlsHeaders('video/mp4', HLS_LONG) }));
    if (!complete) return false;
    await caches.default.put(new Request(key), new Response(at, { headers: { 'Cache-Control': HLS_LONG } }));
    return true;
  })().catch(e => {
    if (!ac.signal.aborted) console.error('hls prefetch:', cx.filePath, k, e && e.message);
    return false;
  }).then(ok => {
    clearTimeout(timer);
    if (!pass.ended) { pass.ended = Date.now(); pass.ok = ok; hlsPassDone(pass); }
    f.ok = ok;
    f.done = true;
    if (HLS_FLIGHTS.get(key) === f) HLS_FLIGHTS.delete(key);
  });
  cx.ctx?.waitUntil?.(run);
  return f;
}

/** 等那一路预取写完，再从缓存出。它停住 / 失败 / 写了却读不到 → null，由调用方自己现取 */
async function hlsAfterFlight(f, key, type, signal) {
  const until = Date.now() + HLS_FLIGHT_MS;
  while (!f.done) {
    if (signal?.aborted || Date.now() > until || !hlsPassAlive(f.pass)) return null;
    await hlsSleep(HLS_POLL_MS);
  }
  if (!f.ok) return null;
  const res = await hlsSegCached(key, type);
  if (!res) hlsCacheDeadAt = Date.now();
  return res;
}

/** 这条内封字幕有没有可用的 Cues（每条都带块内偏移）—— 没有就只能扫字节 */
function hlsSubNeedsScan(sub) {
  return !sub.cues.length || sub.cues.some(c => !(c[3] >= 0));
}

/** 视频这一遍收下的字幕块 → 这一段的 VTT（与 hlsSubSegment 的扫描路径同一套规则） */
async function hlsPutSubs(idx, k, grab) {
  const sec = u => u * idx.scaleNs / 1e9;
  await Promise.all([...grab.values()].map(async g => {
    const cues = [];
    for (const b of g.blocks) {
      const t = hlsSubFrameText(g.sub.fmt, await hlsSubDecode(g.sub, b.frame));
      const s0 = sec(b.ts);
      if (t.text) cues.push({ s: s0, e: s0 + (b.dur >= 0 ? sec(b.dur) : 3), ...t });
    }
    const ck = new Request(`${HLS_SUB_CACHE}s${SUB_CLEAN_V}/${idx.idh}/${g.i}/${k}`);
    await caches.default.put(ck, hlsOut(hlsVtt(cues, idx.dur), 'text/vtt; charset=utf-8'));
  }));
}

/** 后台把这一遍收下的字幕写进缓存（不拖住视频分段收尾），结果记在这一遍上 */
function hlsSubsWrite(cx, idx, k, grab, pass) {
  if (pass) pass.subs = 2;
  const p = hlsPutSubs(idx, k, grab).then(() => true, e => {
    console.error('hls subs grab:', cx.filePath, k, e && e.message);
    return false;
  }).then(ok => { if (pass) { pass.subs = ok ? 3 : -1; hlsPassDone(pass); } });
  cx.ctx?.waitUntil?.(p);
}

/**
 * 等第 k 段的某一遍把字幕顺手写进缓存：只要还有一遍在收这一段的字幕块（而且在动），
 * 就轮询缓存。等到 → VTT 文本；没人在收 / 停住了 / 超时 → null
 */
async function hlsSubAwait(idx, k, ck, signal) {
  const id = `${idx.idh}|${k}`;
  const until = Date.now() + HLS_SUB_WAIT_MS;
  for (;;) {
    const set = HLS_PASSES.get(id);
    const live = !!set && [...set].some(p => p.subs === 2 || (p.subs === 1 && hlsPassAlive(p)));
    const h = await caches.default.match(ck).catch(() => null);
    if (h) return h.text();
    if (!live || signal?.aborted || Date.now() > until) return null;
    await hlsSleep(HLS_POLL_MS);
  }
}

// ── 备选音轨顺路 ──
//  默认音轨复用在视频分段里；换成别的音轨时，播放器除了视频分段，还要这条音轨自己的分段。
//  MKV 里音视频交错存放，音轨分段只能把这一段的字节整个再读一遍、再解析一遍，挑出这条音轨的块 ——
//  等于这一段从 Dropbox 读两遍。现在：有人在听某条备选音轨，就记下来（HLS_ALT，90 秒不再有人要就作罢），
//  之后视频那一遍（直出 / 预取）把这条音轨的块一起收下，切好写进缓存；音轨请求先等它，等不到才自己读。
const HLS_ALT = new Map();          // idh → { i, at }：这部片最近在听的备选音轨
const HLS_ALT_TTL = 90000;
const hlsAltKey = (idx, i, k) => `${HLS_SUB_CACHE}seg2/${idx.idh}/a${i}/${k}`;
function hlsAltFor(idx) {
  const a = HLS_ALT.get(idx.idh);
  if (!a) return -1;
  if (Date.now() - a.at > HLS_ALT_TTL) { HLS_ALT.delete(idx.idh); return -1; }
  return a.i;
}

/** 备选音轨 B 在第 k 段里的分片：与「只出这条音轨」那条路径（hlsSegmentParts，sel.video = false）同一套规则 ——
 *  同样的时间戳吸附、断档另起、2 秒 / 6MB 一个分片、同样的轨道号与序号，切出来的字节一模一样 */
function hlsAltMux(B, k) {
  const T0 = HLS_T0 * B.ts, strip = B.strip ? hlsUnB64(B.strip) : null;
  const laceNs = B.fs ? B.fs * 1e9 / B.ts : 0;
  const snap = (ns, fs) => { const u = Math.round(ns * B.ts / 1e9); return fs > 0 ? B.anchor + Math.round((u - B.anchor) / fs) * fs : u; };
  let run = null, bytes = 0, seq = k * 10000 + 1;
  const runs = [], out = [];
  const flush = () => {
    if (run) { runs.push(run); run = null; }
    bytes = 0;
    for (const r of runs) out.push(mp4Fragment(seq++, [{ id: 1, video: false, base: r.base + T0, samples: r.samples }]));
    runs.length = 0;
  };
  return {
    push(blk, ns) {
      blk.frames.forEach((fr, i) => {
        let pieces = fr, size = fr.reduce((a, x) => a + x.length, 0);
        if (strip) { pieces = [strip, ...pieces]; size += strip.length; }
        let fs = B.fs;
        if (!fs && B.codec === 'flac') fs = flacFrameSamples(fr.length === 1 ? fr[0] : hlsConcat(fr)) || 4096;
        const t = snap(ns + i * (laceNs || (fs * 1e9 / B.ts)), fs);
        if (run) {
          if (Math.abs(t - run.end) <= fs / 2) { /* 连续 */ }
          else if (t < run.end) return;
          else { runs.push(run); run = null; }
        }
        if (!run) run = { base: t, end: t, samples: [] };
        run.samples.push({ dur: fs, size, pieces });
        run.end += fs;
        bytes += size;
      });
      if ((run && (run.end - run.base) >= 2 * B.ts) || runs.length > 0 || bytes >= HLS_FRAG_BYTES) flush();
    },
    finish() { flush(); return out; },
  };
}

/** 后台把顺路切好的那条音轨分段写进缓存（与字幕一样：不拖住视频分段收尾），结果记在这一遍上 */
function hlsAltWrite(cx, idx, k, i, frags, pass) {
  if (pass && pass.alt) pass.alt.st = 2;
  const parts = [];
  for (const f of frags) parts.push(...f);
  const body = hlsConcat(parts);
  const p = caches.default.put(new Request(hlsAltKey(idx, i, k)), hlsOut(body, 'audio/mp4')).then(() => true, e => {
    console.error('hls alt audio:', cx.filePath, k, e && e.message);
    return false;
  }).then(ok => { if (pass && pass.alt) { pass.alt.st = ok ? 3 : -1; hlsPassDone(pass); } });
  cx.ctx?.waitUntil?.(p);
}

/** 缓存里有没有第 k 段视频（只看指针，不读数据） */
async function hlsSegHas(idx, k) {
  const ptr = await caches.default.match(new Request(hlsSegKey(idx, k))).catch(() => null);
  if (!ptr) return false;
  await ptr.body?.cancel().catch(() => {});
  return true;
}
/** 第 k 段有没有一遍正在过（在动）；alt = i 时只算顺路收着备选音轨 i 的那几遍 */
function hlsPassLive(idx, k, alt) {
  const set = HLS_PASSES.get(`${idx.idh}|${k}`);
  if (!set) return false;
  for (const p of set) {
    if (alt == null ? hlsPassAlive(p) : (p.alt && p.alt.i === alt && (p.alt.st === 2 || (p.alt.st === 1 && hlsPassAlive(p))))) return true;
  }
  return false;
}

/** 缓存里有备选音轨 i 的第 k 段就出；有一遍正顺路收它（而且在动）就轮询缓存等它；都没有 / 停住 / 超时 → null。
 *  没人在收时立刻返回，不空等 */
async function hlsAltAwait(idx, k, i, signal) {
  const ck = new Request(hlsAltKey(idx, i, k));
  const until = Date.now() + HLS_SUB_WAIT_MS;
  for (;;) {
    const live = hlsPassLive(idx, k, i);
    const h = await caches.default.match(ck).catch(() => null);
    if (h && h.body) return new Response(h.body, { headers: hlsHeaders('audio/mp4', HLS_LONG) });
    if (!live || signal?.aborted || Date.now() > until) return null;
    await hlsSleep(HLS_POLL_MS);
  }
}

/** 备选音轨第 k 段：
 *   · 记下「有人在听」，之后的视频遍（直出 / 预取）都顺路收它；
 *   · 缓存里有就直接出；有一遍正顺路收它就等它；
 *   · 视频这一段还没进缓存、也没人在过：现在就起一路预取（视频段顺带进缓存、这条音轨顺路切好），等它 ——
 *     播放器紧接着要的视频段会等这一路，不会再读一遍；
 *   · 视频这一段已经在缓存里（看过 / 换音轨之前就预取好了）或者有一遍不带它在过：不再等，
 *     自己把这段字节读一遍切出来（原路径），切好的也进缓存，拖回来再看不用再读 */
async function hlsAltSegResponse(cx, idx, k, i, request) {
  if (!(k >= 0 && k < idx.segs.length)) return hlsFail(404, 'no such segment');
  if (request.method === 'HEAD') return new Response(null, { headers: hlsHeaders('audio/mp4', HLS_LONG) });
  const A = idx.audio[i];
  if (!(hlsCacheOn(cx) && A && A.mode === 'copy' && i !== idx.muxed)) {
    return hlsSegResponse(cx, idx, k, { video: false, audio: i }, 'audio/mp4', request);
  }
  HLS_ALT.set(idx.idh, { i, at: Date.now() });
  if (HLS_ALT.size > 32) HLS_ALT.delete(HLS_ALT.keys().next().value);
  let r = await hlsAltAwait(idx, k, i, request.signal);
  if (r) return r;
  if (!hlsPassLive(idx, k) && !(await hlsSegHas(idx, k)) && hlsFlight(cx, idx, k)) {
    r = await hlsAltAwait(idx, k, i, request.signal);
    if (r) return r;
  }
  // 自己读：照旧边切边交（首字节不等整段），同时留一份，整段正常切完再写进缓存
  const ac = new AbortController();
  const fwd = () => ac.abort(request.signal.reason);
  if (request.signal?.aborted) fwd(); else request.signal?.addEventListener('abort', fwd, { once: true });
  const it = hlsSegmentParts({ ...cx, signal: ac.signal }, idx, k, { video: false, audio: i });
  const kept = [];
  let queue = [], finished = false;
  const done = () => {
    finished = true;
    cx.ctx?.waitUntil?.(caches.default.put(new Request(hlsAltKey(idx, i, k)), hlsOut(hlsConcat(kept), 'audio/mp4')).catch(() => {}));
  };
  const take = parts => { const ch = hlsChunks(parts); for (const x of ch) kept.push(x); return ch; };
  try {
    const r = await it.next();
    if (r.done) done(); else queue = take(r.value);
  } catch (e) {
    ac.abort(e);
    console.error('hls alt audio:', cx.filePath, k, e && e.message);
    return hlsFail(e?.name === 'AbortError' ? 499 : 502, 'segment unavailable');
  }
  const body = new ReadableStream({
    async pull(c) {
      try {
        while (!queue.length) {
          if (finished) { c.close(); return; }
          const r = await it.next();
          if (r.done) done(); else queue = take(r.value);
        }
        c.enqueue(queue.shift());
      } catch (e) {
        ac.abort(e);
        c.error(e);
      }
    },
    cancel(reason) {
      ac.abort(reason);
      it.return().catch(() => {});
    },
  });
  return new Response(body, { headers: hlsHeaders('audio/mp4', HLS_LONG) });
}

/**
 * 内封字幕第 k 段。有 Cues：精确读那几个字幕块（原路径）。
 * 没有 Cues：用视频那一遍顺手写好的 VTT，同一段字节只从 Dropbox 读一次 ——
 * 有一遍正在过这一段就等它；没人在过就自己起一路预取（视频段顺带进缓存）再等它；
 * 名额满了 / 预取失败才自己扫字节。都不长等：字幕分段迟迟不到，播放器会停住画面。
 */
async function hlsSubSegmentFast(cx, idx, si, k) {
  const sub = idx.subs[si];
  if (!hlsSubNeedsScan(sub) || !hlsCacheOn(cx)) return hlsSubSegment(cx, idx, si, k);
  const ck = new Request(`${HLS_SUB_CACHE}s${SUB_CLEAN_V}/${idx.idh}/${si}/${k}`);
  let t = await hlsSubAwait(idx, k, ck, cx.signal);
  if (t == null) {
    await hlsSleep(HLS_SUB_GRACE_MS);              // 字幕请求常比同一段的视频请求早到一点点
    t = await hlsSubAwait(idx, k, ck, cx.signal);
  }
  if (t == null && hlsFlight(cx, idx, k)) t = await hlsSubAwait(idx, k, ck, cx.signal);
  return t != null ? t : hlsSubSegment(cx, idx, si, k);
}

/** 转码分段：整段算完再回（体积小），并进边缘缓存 —— 拖动回看不用再转一遍 */
async function hlsTxSegResponse(cx, idx, k, ai, request) {
  if (!(k >= 0 && k < idx.segs.length)) return hlsFail(404, 'no such segment');
  if (request.method === 'HEAD') return new Response(null, { headers: hlsHeaders('audio/mp4', HLS_LONG) });
  const ck = new Request(`${HLS_SUB_CACHE}t/${idx.idh}/${ai}/${k}`);
  const hit = await caches.default.match(ck).catch(() => null);
  if (hit) return new Response(hit.body, { headers: hlsHeaders('audio/mp4', HLS_LONG) });
  try {
    const parts = [];
    for await (const p of hlsTxSegmentParts(cx, idx, k, ai)) parts.push(...p);
    const res = hlsOut(hlsConcat(parts), 'audio/mp4');
    cx.ctx?.waitUntil?.(caches.default.put(ck, res.clone()).catch(() => {}));
    return res;
  } catch (e) {
    console.error('hls tx:', cx.filePath, k, e && e.message);
    return hlsFail(e?.name === 'AbortError' ? 499 : 502, 'audio transcode unavailable');
  }
}

async function hlsVttResponse(key, ctx, make) {
  const ck = new Request(`${HLS_SUB_CACHE}${key}`);
  const hit = await caches.default.match(ck).catch(() => null);
  if (hit) return new Response(hit.body, { headers: hlsHeaders('text/vtt; charset=utf-8', HLS_LONG) });
  const text = await make();
  const res = hlsOut(text, 'text/vtt; charset=utf-8');
  ctx?.waitUntil?.(caches.default.put(ck, res.clone()).catch(() => {}));
  return res;
}

function hlsInfo(idx, xs, env, os) {
  const V = idx.video, txOn = hlsTxOn(env);
  return {
    ok: true, dur: idx.dur, segments: idx.segs.length,
    video: { codec: V.codec, codecs: V.codecs, supplemental: V.supp || null, range: V.range,
      // 配置盒从哪来：CodecPrivate 原样 / 从码流里补齐重建（annexB：帧是起始码，出分段时转成长度前缀）
      paramSets: V.psRebuilt ? 'rebuilt' : 'codec-private', annexB: !!V.annexB,
      width: V.dw, height: V.h, fps: V.fps ? +V.fps.toFixed(3) : null,
      dolbyVision: V.dv ? { profile: V.dv.profile, level: V.dv.level, fromProfile7: !!V.dvConvert } : null,
      dvStripped: !!V.dvStrip },
    audio: idx.audio.map((a, i) => ({ index: i, lang: a.lang, name: a.name,
      codec: a.tx ? a.tx.srcCodec : (a.codec || a.codecId), channels: a.ch, atmos: !!a.joc,
      playable: a.mode === 'copy' || (a.mode === 'tx' && txOn), transcoded: a.mode === 'tx' && txOn,
      muxed: i === idx.muxed })),
    subtitles: idx.subs.map(s => ({ lang: s.lang, name: s.name, format: s.fmt, forced: s.forced })),
    sidecarSubtitles: xs.length,
    // 在线字幕（已经查到的话）与它的自动对齐结果：参照是谁、整体偏移 / 速度比 / 分段、对齐前后对上的比例
    online: os && os.status === 'ok' ? { lang: os.lang, label: os.label, release: os.src && os.src.release, hashMatch: !!(os.src && os.src.hash),
      sync: os.sync ? { applied: !!os.sync.applied, why: os.sync.why, ref: os.sync.ref || null, scale: os.sync.scale, segs: os.sync.segs,
        before: os.sync.before, after: os.sync.after, chance: os.sync.chance, cv: os.sync.cv ?? null } : null } : null,
    audioUnsupportedOnly: idx.muxed < 0 && idx.audio.length > 0 && !(txOn && idx.audio.some(a => a.mode === 'tx')),
    audioTranscoder: txOn,
  };
}

async function handleHls(url, request, env, ctx) {
  const parts = url.pathname.split('/');
  const tok = hlsParseToken(parts[2]);
  if (!tok || !tok.path) return hlsFail(400, 'bad token');
  if (env.HLS_DISABLE === '1') return hlsFail(404, 'HLS disabled');
  const filePath = tok.path;
  if (!hlsEligible(filePath)) return hlsFail(415, 'only MKV is remuxed to HLS');
  let linkData;
  try { linkData = await getTempLink(filePath, env, ctx); }
  catch { return hlsFail(503, 'Dropbox link unavailable'); }
  const meta = linkData?.metadata;
  if (!linkData?.link || !meta || !Number.isFinite(meta.size)) return hlsFail(502, 'invalid metadata');
  const cx = { filePath, linkData, env, ctx, signal: request.signal, size: meta.size, host: url.hostname,
    identity: meta.content_hash || meta.rev || String(meta.size) };

  const rest = parts.slice(3);
  let dv = ['auto', 'dvh1', 'off'].includes(env.HLS_DV_MODE) ? env.HLS_DV_MODE : 'auto';
  const isRoot = rest[0] === 'master.m3u8' || rest[0] === 'info.json';
  if (isRoot) {
    const q = url.searchParams.get('dv');
    if (['auto', 'dvh1', 'off'].includes(q)) dv = q;
  } else {
    const flag = String(rest[0] || '').split('.')[1];
    if (['dvh1', 'off'].includes(flag)) dv = flag;
  }
  let idx;
  try { idx = await hlsIndexFor(cx, { dv, segSec: hlsSegTarget(env) }); }
  catch (e) {
    if (!e.status || e.status >= 500) console.error('hls index:', filePath, e && e.stack || e);
    return hlsFail(e.status || 503, e.status ? e.message : 'index unavailable');
  }

  if (isRoot) {
    const xs = await hlsSidecarSubs(filePath, env).catch(() => []);
    if (rest[0] === 'info.json') {
      // 打开详情页：没有简体中文字幕的片子，在后台去 OpenSubtitles 找一条（不等）
      if (osOn(env)) ctx?.waitUntil?.(hlsOnline(cx, idx, xs, 0).catch(() => null));
      const os = osOn(env) ? await osLoad(env, await osKeyOf(osIdentity(filePath, meta))).catch(() => null) : null;
      return new Response(JSON.stringify(hlsInfo(idx, xs, env, os)), { headers: hlsHeaders('application/json; charset=utf-8', 'no-store') });
    }
    // 起播：播放器拿到主列表后还要取二级列表与 init 才来要第 0 段 —— 这几个来回里先在后台
    // 把第 0 段取进缓存，它来了等一下就从缓存出（只是预取：不跟车、不共享流）
    if (hlsCacheOn(cx)) hlsFlight(cx, idx, 0);
    // 在线字幕：详情页打开时多半已经查好了；还在查就最多等 OS_WAIT_MS
    const os = osOn(env) ? await Promise.race([hlsOnline(cx, idx, xs, OS_WAIT_MS).catch(() => null),
      new Promise(r => setTimeout(() => r(null), OS_WAIT_MS + 800))]) : null;
    return hlsOut(hlsMaster(idx, xs, env, os), HLS_M3U8, 'no-store');
  }
  // 文件被替换 / 引擎升级 → 旧播放列表作废，让播放页重新取主列表
  if (rest[0] !== idx.idh) return hlsFail(410, 'playlist expired');

  const name = rest[1] || '', leaf = rest[2] || '';
  const seg = /^(\d+)\.(m4s|vtt)$/.exec(leaf);
  const target = hlsTarget(idx, env);
  let m;
  if (name === 'v.m3u8') return hlsOut(hlsMediaPl(idx, 'v.mp4', k => `v/${k}.m4s`, target), HLS_M3U8);
  if (name === 'v.mp4') {
    const tracks = [{ id: 1, kind: 'v', cfg: idx.video }];
    if (idx.muxed >= 0) tracks.push({ id: 2, kind: 'a', cfg: idx.audio[idx.muxed] });
    return hlsOut(mp4Init(tracks, !!idx.video.dv), 'video/mp4');
  }
  if (name === 'v' && seg && seg[2] === 'm4s') {
    return hlsSegResponse(cx, idx, +seg[1], { video: true, audio: idx.muxed }, 'video/mp4', request);
  }
  if ((m = /^a(\d+)(\.m3u8|\.mp4)?$/.exec(name))) {
    const i = +m[1], a = idx.audio[i];
    if (!a || a.mode !== 'copy') return hlsFail(404, 'no such audio track');
    if (m[2] === '.m3u8') return hlsOut(hlsMediaPl(idx, `a${i}.mp4`, k => `a${i}/${k}.m4s`, target), HLS_M3U8);
    if (m[2] === '.mp4') return hlsOut(mp4Init([{ id: 1, kind: 'a', cfg: a }], false), 'audio/mp4');
    if (seg && seg[2] === 'm4s') return hlsAltSegResponse(cx, idx, +seg[1], i, request);
  }
  if ((m = /^t(\d+)(\.m3u8|\.mp4)?$/.exec(name))) {
    const i = +m[1], a = idx.audio[i];
    if (!a || a.mode !== 'tx' || !hlsTxOn(env)) return hlsFail(404, 'no such audio track');
    if (m[2] === '.m3u8') return hlsOut(hlsMediaPl(idx, `t${i}.mp4`, k => `t${i}/${k}.m4s`, target, hlsTxDurs(idx, a)), HLS_M3U8);
    if (m[2] === '.mp4') return hlsOut(mp4Init([{ id: 1, kind: 'a', cfg: a }], false), 'audio/mp4');
    if (seg && seg[2] === 'm4s') return hlsTxSegResponse(cx, idx, +seg[1], i, request);
  }
  if ((m = /^s(\d+)(\.m3u8)?$/.exec(name))) {
    const i = +m[1];
    if (!idx.subs[i]) return hlsFail(404, 'no such subtitle');
    if (m[2]) return hlsOut(hlsMediaPl(idx, null, k => `s${i}/${k}.vtt`, target), HLS_M3U8);
    if (seg && seg[2] === 'vtt' && +seg[1] < idx.segs.length) {
      try { return await hlsVttResponse(`s${SUB_CLEAN_V}/${idx.idh}/${i}/${seg[1]}`, ctx, () => hlsSubSegmentFast(cx, idx, i, +seg[1])); }
      catch (e) { console.error('hls subs:', e && e.message); return hlsFail(502, 'subtitle unavailable'); }
    }
  }
  if ((m = /^x(\d+)(\.m3u8)?$/.exec(name))) {
    const i = +m[1];
    if (m[2]) return hlsOut(hlsMediaPl(idx, null, k => `x${i}/${k}.vtt`, target), HLS_M3U8);
    if (seg && seg[2] === 'vtt' && +seg[1] < idx.segs.length) {
      const k = +seg[1];
      try {
        const xs = await hlsSidecarSubs(filePath, env);
        const x = xs[i];
        if (!x) return hlsFail(404, 'no such subtitle');
        return await hlsVttResponse(`x${SUB_CLEAN_V}/${idx.idh}/${encodeURIComponent(x.path)}/${x.rev}/${k}`, ctx, async () => {
          const [T1, T2] = hlsSegWindow(idx, k);
          const all = await subMemo(`x|${x.path}|${x.rev}|${Math.round(idx.dur)}`, async () => subClean(await hlsSidecarCues(x, env, ctx), idx.dur));
          return hlsVtt(all.filter(c => c.s < T2 && c.e > T1), idx.dur, { cleaned: true });
        });
      } catch (e) { console.error('hls sidecar:', e && e.message); return hlsFail(502, 'subtitle unavailable'); }
    }
  }
  // OpenSubtitles 找来的那一条。记录不在（极少见：别的机房、缓存被挤掉）回空 VTT 而不是 404 ——
  // 字幕分段 404 可能让播放器停下来
  if ((m = /^o0(\.m3u8)?$/.exec(name))) {
    if (m[1]) return hlsOut(hlsMediaPl(idx, null, k => `o0/${k}.vtt`, target), HLS_M3U8);
    if (seg && seg[2] === 'vtt' && +seg[1] < idx.segs.length) {
      const k = +seg[1];
      const rec = osOn(env) ? await osLoad(env, await osKeyOf(osIdentity(filePath, meta))).catch(() => null) : null;
      if (!rec || rec.status !== 'ok') return hlsOut(hlsVtt([]), 'text/vtt; charset=utf-8', 'no-store');
      return await hlsVttResponse(`o${SUB_CLEAN_V}/${idx.idh}/${rec.src.file}/${syncId(rec.sync)}/${k}`, ctx, async () => {
        const [T1, T2] = hlsSegWindow(idx, k);
        const all = await subMemo(`o|${rec.src.file}|${syncId(rec.sync)}|${Math.round(idx.dur)}`, () => subClean(osCuesOut(rec), idx.dur));
        return hlsVtt(all.filter(c => c.s < T2 && c.e > T1), idx.dur, { cleaned: true });
      });
    }
  }
  return hlsFail(404, 'not found');
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /watch
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function handleStreamSign(url, env) {
  const filePath = url.searchParams.get('path') || '';
  if (!filePath) return jsonResponse({ error: 'Missing path' }, 400, { 'Cache-Control': 'no-store' });
  // v25：MKV 同时给出 HLS 主列表路径（与 /stream 共用同一枚签名）
  const sign = env.AUTH_SECRET ? await signStreamPath(filePath, env) : { exp: null, sig: null };
  const hls = hlsEligible(filePath) && env.HLS_DISABLE !== '1'
    ? `/hls/${hlsTokenFor(filePath, sign.sig ? sign : null)}/master.m3u8` : null;
  return jsonResponse({ ...sign, hls }, 200, { 'Cache-Control': 'no-store' });
}

async function handleWatch(url, request, env, ctx) {
  const fp = url.searchParams.get('path') || '';
  const fn = fp.split('/').pop() || 'Video';
  // 签名直链：外部播放器与浏览器 <video> 共用。浏览器本可用 Cookie，
  // 但签名 src 让「标签页放过夜、次日 seek」不再撞上 Cookie 过期的 401。
  const sign = (env.AUTH_SECRET && fp) ? await signStreamPath(fp, env) : null;

  // v19 优选入口：host 取上一轮实测的赢家（Cookie，白名单校验过），
  // 没有就退回当前 host。签名不含 host —— 换入口不必重签，旧直链照样有效。
  // v23 使用 url.host 而非 hostname，保留 2053 / 8443 等非标准端口。
  const selfHost = url.host;
  const hosts = edgeHosts(env, selfHost);
  const host = pickEdgeHost(request, env, selfHost);

  // 只在本页入口就是实际起播入口时预热。若 Cookie 选了另一入口，本 colo 的
  // 连接池无法帮助另一 colo，预热反而只会多打一条 Dropbox API 请求。
  if (fp && host === selfHost) {
    ctx?.waitUntil?.(prewarmStream(fp, env, ctx).catch(() => {}));
  }
  // 探针签名：别的入口是别的 hostname，Cookie 带不过去，只能签名过门
  const probe = env.AUTH_SECRET ? await signStreamPath(EDGE_PROBE_PATH, env) : null;

  return new Response(playerPage(fp, fn, sign, host, hosts, probe, env, url.origin), {
    // 页面内嵌时效凭证 → 不落任何缓存
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /auth — POST 登录（密钥不再以 GET query 进浏览器历史/日志）
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function handleAuthLogin(request, env) {
  if (!env.AUTH_SECRET || request.method !== 'POST') {
    return new Response(null, { status: 302, headers: { Location: '/' } });
  }

  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  const wait = authThrottled(ip);
  if (wait) {
    return new Response(loginPage('/', true, `尝试过于频繁，请 ${Math.ceil(wait / 60)} 分钟后再试`), {
      status: 429,
      headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Retry-After': String(wait), ...HTML_SEC },
    });
  }

  let key = '', to = '/';
  try {
    const form = await request.formData();
    key = String(form.get('key') || '');
    to  = String(form.get('to')  || '/');
  } catch {}
  // 防开放重定向：仅允许站内路径（拒绝 //evil.com 与 /\evil.com 变体）
  if (!/^\/(?![/\\])/.test(to)) to = '/';

  if (!timingSafeEqualStr(key, env.AUTH_SECRET)) {
    authFailed(ip);
    return new Response(loginPage(to, true), {
      status: 401,
      headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', ...HTML_SEC },
    });
  }

  _authFails.delete(ip);
  return new Response(null, {
    status: 302,
    headers: {
      Location: to,
      'Set-Cookie': sessionCookie(await mintSession(env)),
    },
  });
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  HTML
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// HTML 页面的安全头。API 走 CORS 那套，不套这个。
const HTML_SEC = Object.freeze({
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'DENY',
  'X-Robots-Tag': 'noindex, nofollow',
});

function loginPage(returnTo = '/', failed = false, msg = '') {
  const to = escHtml(returnTo);
  const err = msg ? escHtml(msg) : '密钥不正确，请重试';
  return `<!DOCTYPE html><html lang=zh-CN><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta name=robots content="noindex,nofollow"><title>访问验证</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{min-height:100dvh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;background:#000;color:#fff}.c{width:320px;text-align:center}h2{font-size:20px;font-weight:600;margin-bottom:24px}input{width:100%;padding:12px 16px;border:1px solid #333;border-radius:12px;background:#111;color:#fff;font-size:16px;outline:none;margin-bottom:16px}input:focus{border-color:#0A84FF}.e{color:#FF453A;font-size:13px;margin:-4px 0 14px}button{width:100%;padding:12px;border:none;border-radius:12px;background:#0A84FF;color:#fff;font-size:16px;font-weight:600;cursor:pointer}button:active{opacity:.8}</style>
</head><body><div class=c><h2>🔐 输入访问密钥</h2>
<form method="POST" action="/auth">
<input type="hidden" name="to" value="${to}">
<input name=key type=password placeholder="Access Key" autocomplete="current-password" autofocus>
${failed ? `<div class=e>${err}</div>` : ''}
<button type=submit>进入</button>
</form></div></body></html>`;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  v24：Safari 杜比视界 / MKV fMP4 重封装 / 字幕与伴音共用前端引擎
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

function safariMediaEngineScript() {
  // 必须用 String.raw：下面的客户端代码里的 \r \n \uFEFF \{ \\N 等是写给浏览器正则的，
  // 普通模板字符串会提前解释这些转义（\n 变真换行），把正则字面量切断，整段脚本语法错误 → 页面永远加载中。
  return String.raw`
// ── 字幕解析与挂载 ──
function parseClientSubToCues(text,ext){
  var norm=String(text||'').replace(/^\uFEFF/,'').replace(/\r\n?/g,'\n');
  var cues=[];
  function clean(s){
    return String(s||'').replace(/\{[^}]*\}/g,'').replace(/\\N/g,'\n').replace(/\\n/g,'\n').replace(/\\h/g,' ').trim();
  }
  function toSec(h,m,s,ms){return (+h)*3600+(+m)*60+(+s)+(+ms)/1000}
  if(ext==='.ass'||ext==='.ssa'||/\[Events\]/i.test(norm)){
    var lines=norm.split('\n'),inEv=false,si=1,ei=2,ti=9;
    for(var i=0;i<lines.length;i++){
      var l=lines[i].trim();
      if(/^\[Events\]/i.test(l)){inEv=true;continue}
      if(/^\[.*\]$/.test(l)){if(inEv)break;continue}
      if(!inEv)continue;
      if(/^Format\s*:/i.test(l)){
        var cs=l.slice(l.indexOf(':')+1).split(',').map(function(x){return x.trim().toLowerCase()});
        if(cs.indexOf('start')>=0)si=cs.indexOf('start');
        if(cs.indexOf('end')>=0)ei=cs.indexOf('end');
        if(cs.indexOf('text')>=0)ti=cs.indexOf('text');
        continue;
      }
      if(!/^Dialogue\s*:/i.test(l))continue;
      var b=l.slice(l.indexOf(':')+1),ps=[],cur=0;
      for(var k=0;k<ti;k++){var cm=b.indexOf(',',cur);if(cm<0)break;ps.push(b.slice(cur,cm));cur=cm+1}
      ps.push(b.slice(cur));
      var m1=/(\d+):(\d{2}):(\d{2})[.:](\d{1,3})/.exec(ps[si]||'');
      var m2=/(\d+):(\d{2}):(\d{2})[.:](\d{1,3})/.exec(ps[ei]||'');
      if(!m1||!m2)continue;
      var t0=toSec(m1[1],m1[2],m1[3],m1[4].length===2?m1[4]+'0':m1[4]);
      var t1=toSec(m2[1],m2[2],m2[3],m2[4].length===2?m2[4]+'0':m2[4]);
      var tx=clean(ps[ti]);
      if(tx&&t1>t0)cues.push({start:t0,end:t1,text:tx});
    }
    return cues;
  }
  var blocks=norm.replace(/^WEBVTT[^\n]*\n+/,'').split(/\n{2,}/);
  for(var j=0;j<blocks.length;j++){
    var ls=blocks[j].trim().split('\n');
    if(!ls.length)continue;
    var idx=(/^\d+$/.test(ls[0].trim())&&ls.length>1)?1:0;
    var tm=/(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})/.exec(ls[idx]||'');
    if(!tm)continue;
    var s0=toSec(tm[1],tm[2],tm[3],tm[4]),s1=toSec(tm[5],tm[6],tm[7],tm[8]);
    var body=clean(ls.slice(idx+1).join('\n'));
    if(body&&s1>s0)cues.push({start:s0,end:s1,text:body});
  }
  return cues;
}

function clearVideoTracks(V){
  var old=V.querySelectorAll('track');
  for(var i=0;i<old.length;i++)old[i].remove();
  if(V.textTracks){
    for(var j=0;j<V.textTracks.length;j++)V.textTracks[j].mode='disabled';
  }
}

async function mountExternalSubs(V,fp,streamOrigin,onSay){
  if(!fp)return;
  try{
    var r=await fetch('/api/subs?path='+encodeURIComponent(fp),{cache:'no-store'});
    if(!r.ok)return;
    var d=await r.json();
    var subs=d.subs||[];
    if(!subs.length)return;
    for(var i=0;i<subs.length;i++){
      var s=subs[i];
      var trEl=document.createElement('track');
      trEl.kind='subtitles';
      trEl.label=s.label||s.name;
      trEl.srclang=s.srclang||'zh';
      trEl.src=(streamOrigin||location.origin)+s.url;
      if(i===0)trEl.default=true;
      V.appendChild(trEl);
    }
    setTimeout(function(){
      if(V.textTracks&&V.textTracks.length>0){
        var hasOn=false;
        for(var j=0;j<V.textTracks.length;j++)if(V.textTracks[j].mode==='showing')hasOn=true;
        if(!hasOn)V.textTracks[0].mode='showing';
      }
    },350);
    if(onSay)onSay('已自动挂载 '+subs.length+' 条外挂字幕');
  }catch(e){}
}

// ── v25：MKV 走原生 HLS（Worker 实时重封装成 fMP4，杜比视界 / HDR 由系统播放器点亮）──
// v24 在这里的 MSE「MKV 流式重封装引擎」从未真正向 SourceBuffer 写过数据，
// 在 iPhone 上 ManagedMediaSource 也因 disableRemotePlayback=false 根本不会打开 —— 已整体移除。
// 只认 Apple 的原生播放器（macOS Safari，以及 iOS / iPadOS 上的所有浏览器 —— 它们都是 WebKit + AVFoundation）。
// 新版桌面 Chrome 的 canPlayType(m3u8) 也报 maybe，但它的 HLS 只要 CODECS 里有一个自己解不了的编码
// （例如备选音轨的 ac-3）就整条拒播（No renditions），杜比视界、AC-3 / E-AC-3 也都解不了：那边走直连。
function canNativeHls(V){
  try{
    if(!/Apple/.test(navigator.vendor||''))return false;
    return !!(V.canPlayType('application/vnd.apple.mpegurl')||V.canPlayType('application/x-mpegURL'));
  }catch(e){return false}
}
async function hlsPreflight(master){
  // info.json 与 master.m3u8 同目录：顺带把索引建好，首个分段就不必再等
  var r=await fetch(master.replace(/master\.m3u8(\?.*)?$/,'info.json'),{cache:'no-store',credentials:'omit'});
  var d=null;
  try{d=await r.json()}catch(e){}
  if(!r.ok||!d||!d.ok){var e=new Error((d&&d.error)||('HTTP '+r.status));e.status=r.status;throw e}
  return d;
}
function hlsBadgeText(d){
  var v=(d&&d.video)||{};
  if(v.dolbyVision)return 'Dolby Vision';
  if(v.range==='PQ')return 'HDR10';
  if(v.range==='HLG')return 'HLG';
  return '';
}
function hlsAudioNote(d){
  if(!d)return '';
  if(d.audioUnsupportedOnly)return '此片只有 DTS / TrueHD 等 Safari 无法解码的音轨，当前没有声音（部署 audio-tx 转码 Worker 后可实时转为杜比数字）；也可复制直链用 Infuse 播放';
  var n=0,t=0,mux=false,list=d.audio||[];
  for(var i=0;i<list.length;i++){if(!list[i].playable)n++;if(list[i].transcoded)t++;if(list[i].muxed)mux=true}
  if(t&&!mux)return 'DTS / TrueHD 音轨已实时转为 Dolby Digital 5.1 播放';
  return n?('另有 '+n+' 条 DTS / TrueHD 等音轨 Safari 无法解码，已从音轨列表隐藏'):'';
}
`;
}

function browserPage(env) {
  const rootJs = JSON.stringify(String(env.ROOT_FOLDER || '')).replace(/</g, '\u003c');
  const selfHosts = edgeHosts(env, '');
  const J = v => JSON.stringify(v).replace(/</g, '\u003c');
  return `<!DOCTYPE html><html lang=zh-CN><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name=robots content="noindex,nofollow"><title>Video Library</title>
<style>
:root{--bg:#000;--s:#111;--b:#222;--t:#f5f5f7;--t2:#86868b;--a:#0A84FF;--st:env(safe-area-inset-top,0px);--sb:env(safe-area-inset-bottom,0px)}
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html{background:var(--bg);color:var(--t);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text",sans-serif}
body{min-height:100dvh;padding:calc(var(--st)+20px) 20px calc(var(--sb)+40px);max-width:780px;margin:0 auto}
.hd{display:flex;align-items:baseline;justify-content:space-between;margin-bottom:16px}
h1{font-size:32px;font-weight:700;letter-spacing:-.02em}
.nav{font-size:13px;color:var(--a);text-decoration:none}
.i{display:flex;gap:14px;padding:14px 0;border-bottom:1px solid var(--b);text-decoration:none;color:inherit;align-items:center;cursor:pointer}
.ic{width:46px;height:46px;border-radius:12px;background:#1C1C1E;display:flex;align-items:center;justify-content:center;font-size:22px;flex-shrink:0}
.m{flex:1;min-width:0}
.n{font-size:16px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tags{display:flex;flex-wrap:wrap;gap:5px;margin-top:5px;align-items:center}
.tg{font-size:10px;font-weight:700;padding:2px 6px;border-radius:5px;background:rgba(255,255,255,.1);color:#aeaeb2;letter-spacing:.03em}
.tg.dv{background:rgba(10,132,255,.24);color:#64d2ff;border:1px solid rgba(100,210,255,.35)}
.tg.hdr{background:rgba(255,159,10,.2);color:#ffd60a}
.tg.aud{background:rgba(48,209,88,.18);color:#30d158}
.sz{font-size:11px;color:var(--t2);margin-left:2px}
.go{padding:7px 12px;border-radius:14px;background:rgba(255,255,255,.08);color:var(--t2);font-size:12px;text-decoration:none;flex-shrink:0}
.go:hover{background:rgba(255,255,255,.16);color:#fff}
.ld{text-align:center;padding:60px 20px;color:var(--t2)}
.rt{margin-top:14px;padding:9px 18px;border:0;border-radius:10px;background:var(--a);color:#fff;font-size:15px;font-weight:600;cursor:pointer}
.modal{position:fixed;inset:0;z-index:100;background:rgba(0,0,0,.96);display:none;flex-direction:column}
.modal.open{display:flex}
.mbar{padding:calc(var(--st)+12px) 18px 12px;display:flex;align-items:center;gap:10px;background:linear-gradient(rgba(0,0,0,.85),transparent);z-index:10}
.mbk{min-width:34px;height:34px;padding:0 10px;border-radius:17px;background:rgba(255,255,255,.14);color:#fff;border:0;font-size:13px;font-weight:600;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;text-decoration:none}
.mtt{flex:1;min-width:0;font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mpw{flex:1;display:flex;align-items:center;justify-content:center;min-height:0;padding:0 0 calc(var(--sb)+16px)}
.mpw video{width:100%;height:100%;max-height:100%;object-fit:contain}
.mpw video::cue{background:rgba(0,0,0,.62);color:#fff;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
.menu{position:fixed;top:calc(var(--st)+56px);right:18px;z-index:120;min-width:220px;max-width:86vw;max-height:60vh;overflow-y:auto;background:rgba(28,28,30,.95);backdrop-filter:blur(24px);-webkit-backdrop-filter:blur(24px);border:1px solid rgba(255,255,255,.14);border-radius:14px;padding:6px;display:none}
.menu.open{display:block}
.mh{font-size:11px;font-weight:700;color:#8e8e93;padding:6px 10px 4px;text-transform:uppercase}
.mi{display:flex;align-items:center;justify-content:space-between;width:100%;padding:9px 10px;border:0;background:transparent;color:#f5f5f7;font-size:13px;text-align:left;border-radius:9px;cursor:pointer}
.mi:hover,.mi.act{background:rgba(10,132,255,.24);color:#64d2ff}
.toast{position:fixed;left:0;right:0;bottom:calc(var(--sb)+14px);text-align:center;font-size:12px;color:#aeaeb2;pointer-events:none;opacity:0;transition:opacity .25s;z-index:130}
.toast.on{opacity:1}
</style>
</head><body>
<div class=hd><h1>Videos</h1><a class=nav href="/dupes">重复巡检 →</a></div>
<div id=l><div class=ld>加载中…</div></div>

<div class=modal id=modal>
  <div class=mbar>
    <button class=mbk id=mclose>✕ 关闭</button>
    <div class=mtt id=mtitle></div>
    <span class="tg dv" id=mbdg style="display:none"></span>
    <button class=mbk id=mabtn style="display:none">♫ 音轨</button>
    <button class=mbk id=msbtn>CC 字幕</button>
    <button class=mbk id=mcp title="复制外部播放器直链">⧉ 直链</button>
    <a class=mbk id=mfull href="#">↗ 独立页</a>
  </div>
  <div class=menu id=mamenu></div>
  <div class=menu id=msmenu></div>
  <input type=file id=msubfile accept=".srt,.ass,.ssa,.vtt" style="display:none">
  <div class=mpw><video id=mv controls playsinline preload=auto crossorigin=anonymous></video></div>
</div>
<div class=toast id=mtoast></div>

<script>
const R=${rootJs},CK=${J(EDGE_COOKIE)},HOSTS=${J(selfHosts)},l=document.getElementById('l');
${safariMediaEngineScript()}

function E(s){return String(s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
function fmtSz(b){b=Number(b)||0;return b>=1073741824?(b/1073741824).toFixed(2)+' GB':b>=1048576?Math.round(b/1048576)+' MB':''}

function buildBadges(name,size){
  var out=[];
  if(/(?:dolby[\s._-]?vision|dovi|\bdv\b|杜比视界)/i.test(name))out.push('<span class="tg dv">Dolby Vision</span>');
  else if(/hdr10\+|hdr10plus/i.test(name))out.push('<span class="tg hdr">HDR10+</span>');
  else if(/\bhdr\b|\bhlg\b/i.test(name))out.push('<span class="tg hdr">HDR</span>');
  if(/2160[pi]|\b4k\b|uhd/i.test(name))out.push('<span class=tg>4K</span>');
  else if(/1080[pi]/i.test(name))out.push('<span class=tg>1080P</span>');
  if(/atmos|全景声/i.test(name))out.push('<span class="tg aud">Atmos</span>');
  else if(/truehd/i.test(name))out.push('<span class="tg aud">TrueHD</span>');
  else if(/dts[\s._-]?hd|dts[\s._-]?x|\bdts\b/i.test(name))out.push('<span class="tg aud">DTS</span>');
  else if(/ddp|\beac3\b/i.test(name))out.push('<span class="tg aud">Dolby Audio</span>');
  if(/remux|原盘/i.test(name))out.push('<span class=tg>REMUX</span>');
  var ext=name.slice(name.lastIndexOf('.')+1).toUpperCase();
  if(ext)out.push('<span class=tg>'+E(ext)+'</span>');
  var s=fmtSz(size);
  if(s)out.push('<span class=sz>'+s+'</span>');
  return out.join('');
}

var modal=document.getElementById('modal'),MV=document.getElementById('mv'),
    mtitle=document.getElementById('mtitle'),mbdg=document.getElementById('mbdg'),
    mabtn=document.getElementById('mabtn'),msbtn=document.getElementById('msbtn'),
    mamenu=document.getElementById('mamenu'),msmenu=document.getElementById('msmenu'),
    msubfile=document.getElementById('msubfile'),mcp=document.getElementById('mcp'),
    mfull=document.getElementById('mfull'),mtoast=document.getElementById('mtoast');
var curStreamUrl='',curRawUrl='',curHls='',curPath='',hlsRetries=0,openSeq=0,ttTimer=0;

function toast(msg,ms){
  mtoast.textContent=msg;mtoast.classList.add('on');
  clearTimeout(ttTimer);ttTimer=setTimeout(function(){mtoast.classList.remove('on')},ms||3500);
}

function getPreferredHost(){
  var m=document.cookie.match(new RegExp('(?:^|;\\s*)'+CK+'=([^;]+)'));
  var want=m?decodeURIComponent(m[1]).trim():'';
  if(want&&HOSTS.indexOf(want)>=0)return location.protocol+'//'+want;
  return location.origin;
}

async function openInlinePlayer(path,name){
  var my=++openSeq;
  modal.classList.add('open');
  mtitle.textContent=name;
  curPath=path;curHls='';hlsRetries=0;
  mfull.href='/watch?path='+encodeURIComponent(path);
  if(/(?:dolby[\s._-]?vision|dovi|\bdv\b|杜比视界)/i.test(name)){mbdg.textContent='Dolby Vision';mbdg.style.display='inline-block'}
  else if(/\bhdr10\+?\b|\bhdr\b|\bhlg\b/i.test(name)){mbdg.textContent='HDR';mbdg.style.display='inline-block'}
  else mbdg.style.display='none';

  clearVideoTracks(MV);
  MV.pause();MV.removeAttribute('src');MV.load();

  var qs=new URLSearchParams({path:path}),sd=null;
  try{
    var sr=await fetch('/api/stream-sign?path='+encodeURIComponent(path),{cache:'no-store'});
    if(sr.ok){
      sd=await sr.json();
      if(sd.exp&&sd.sig){qs.set('exp',String(sd.exp));qs.set('sig',sd.sig)}
    }
  }catch(e){}
  if(my!==openSeq)return;

  var baseOrigin=getPreferredHost();
  curRawUrl=baseOrigin+'/stream/'+encodeURIComponent(name)+'?'+qs.toString();
  var playUrl=new URL(curRawUrl);
  if(/\.(mp4|m4v|mov)$/i.test(name))playUrl.searchParams.set('safari','1');
  curStreamUrl=playUrl.href;

  // v25：MKV 在 Safari / iOS 上走原生 HLS（Worker 实时重封装），字幕与音轨都在 HLS 里
  if(sd&&sd.hls&&canNativeHls(MV)){
    var hlsUrl=baseOrigin+sd.hls;
    try{
      var info=await hlsPreflight(hlsUrl);
      if(my!==openSeq)return;
      var bt=hlsBadgeText(info);
      if(bt){mbdg.textContent=bt;mbdg.style.display='inline-block'}
      var note=hlsAudioNote(info);
      if(note)toast(note,6000);
      curHls=hlsUrl;
      MV.src=hlsUrl;MV.load();MV.play().catch(function(){});
      return;
    }catch(e){
      if(my!==openSeq)return;
      toast('无法生成 HLS（'+e.message+'），改用直连',5000);
    }
  }
  mountExternalSubs(MV,path,baseOrigin,toast);
  MV.src=curStreamUrl;
  MV.load();
  MV.play().catch(function(){});
}

// HLS 中途出错（签名过期 / 文件被替换 / 网络抖动）：换新签名，从原位置重载，最多两次
MV.addEventListener('error',async function(){
  var code=MV.error&&MV.error.code||0;
  if(code===1||!curHls)return;
  if(hlsRetries>=2){toast('播放失败，可复制直链用 Infuse 播放',6000);return}
  hlsRetries++;
  var my=openSeq,at=MV.currentTime||0;
  try{
    var sr=await fetch('/api/stream-sign?path='+encodeURIComponent(curPath),{cache:'no-store'});
    var sd=await sr.json();
    if(my!==openSeq||!sd.hls)return;
    curHls=getPreferredHost()+sd.hls;
    MV.src=curHls;MV.load();
    if(at>0)MV.addEventListener('loadedmetadata',function(){try{MV.currentTime=at}catch(e){}},{once:true});
    MV.play().catch(function(){});
    toast('已重新连接',2500);
  }catch(e){toast('重新连接失败',4000)}
});

document.getElementById('mclose').onclick=function(){
  openSeq++;curHls='';
  modal.classList.remove('open');
  mamenu.classList.remove('open');msmenu.classList.remove('open');
  MV.pause();MV.removeAttribute('src');MV.load();
};

mcp.onclick=async function(){
  if(!curRawUrl)return;
  try{await navigator.clipboard.writeText(curRawUrl);toast('已复制外部播放器直链（Infuse / VLC）')}
  catch(e){prompt('外部播放器直链：',curRawUrl)}
};

msbtn.onclick=function(){
  mamenu.classList.remove('open');
  var tts=MV.textTracks||[],anyOn=false;
  for(var i=0;i<tts.length;i++)if(tts[i].mode==='showing')anyOn=true;
  var h='<div class=mh>字幕轨道</div>';
  h+='<button class="mi'+(!anyOn?' act':'')+'" data-s="-1"><span>关闭字幕</span><span>'+(anyOn?'':'✓')+'</span></button>';
  for(var j=0;j<tts.length;j++){
    var on=tts[j].mode==='showing';
    h+='<button class="mi'+(on?' act':'')+'" data-s="'+j+'"><span>'+E(tts[j].label||tts[j].language||('轨道 #'+(j+1)))+'</span><span>'+(on?'✓':'')+'</span></button>';
  }
  h+='<div class=mh style="margin-top:6px">本地字幕</div><button class=mi id=mpick><span>+ 挂载本地字幕 (.srt/.ass/.vtt)</span></button>';
  msmenu.innerHTML=h;
  msmenu.classList.toggle('open');
  var bs=msmenu.querySelectorAll('[data-s]');
  for(var k=0;k<bs.length;k++){
    bs[k].onclick=function(){
      var idx=parseInt(this.getAttribute('data-s'),10);
      for(var m=0;m<tts.length;m++)tts[m].mode=(m===idx)?'showing':'disabled';
      msmenu.classList.remove('open');
    };
  }
  var pk=document.getElementById('mpick');
  if(pk)pk.onclick=function(){msmenu.classList.remove('open');msubfile.click()};
};

msubfile.onchange=async function(){
  var f=msubfile.files&&msubfile.files[0];
  if(!f)return;
  var u8=new Uint8Array(await f.arrayBuffer()),txt='';
  try{txt=new TextDecoder('utf-8',{fatal:true}).decode(u8)}
  catch(e){try{txt=new TextDecoder('gb18030').decode(u8)}catch(e2){txt=new TextDecoder().decode(u8)}}
  var ext=f.name.slice(f.name.lastIndexOf('.')).toLowerCase();
  var cues=parseClientSubToCues(txt,ext);
  var tr=MV.addTextTrack('subtitles',f.name.replace(/\.[^.]+$/,''),'zh');
  var Cue=window.VTTCue||window.TextTrackCue;
  for(var i=0;i<cues.length;i++){try{tr.addCue(new Cue(cues[i].start,cues[i].end,cues[i].text))}catch(e){}}
  for(var k=0;k<MV.textTracks.length;k++)MV.textTracks[k].mode='disabled';
  tr.mode='showing';
  toast('已加载本地字幕：'+f.name);
  msubfile.value='';
};

MV.addEventListener('loadedmetadata',function(){
  var ats=MV.audioTracks||[];
  mabtn.style.display=ats.length>1?'inline-flex':'none';
});
mabtn.onclick=function(){
  msmenu.classList.remove('open');
  var ats=MV.audioTracks||[];
  var h='<div class=mh>音轨选择</div>';
  for(var i=0;i<ats.length;i++){
    var a=ats[i];
    h+='<button class="mi'+(a.enabled?' act':'')+'" data-a="'+i+'"><span>'+E(a.label||a.language||('音轨 #'+(i+1)))+'</span><span>'+(a.enabled?'✓':'')+'</span></button>';
  }
  mamenu.innerHTML=h;
  mamenu.classList.toggle('open');
  var bs=mamenu.querySelectorAll('[data-a]');
  for(var j=0;j<bs.length;j++){
    bs[j].onclick=function(){
      var idx=parseInt(this.getAttribute('data-a'),10);
      for(var m=0;m<ats.length;m++)ats[m].enabled=(m===idx);
      mamenu.classList.remove('open');
    };
  }
};

async function load(){
  l.innerHTML='<div class=ld>加载中…</div>';
  const c=new AbortController(),t=setTimeout(()=>c.abort(),15000);
  try{
    const r=await fetch('/api/list'+location.search,{signal:c.signal,cache:'no-store'});
    if(!r.ok)throw new Error('HTTP '+r.status);
    const d=await r.json();
    const items=d.items||[];
    if(!items.length){l.innerHTML='<div class=ld>这个目录是空的</div>';return}
    l.innerHTML=items.map(function(i){
      if(i.type==='folder'){
        return '<a class=i href="?path='+encodeURIComponent(i.path.replace(R,''))+'"><div class=ic>📁</div><div class=m><div class=n>'+E(i.name)+'</div></div></a>';
      }
      return '<div class=i data-p="'+E(i.path)+'" data-n="'+E(i.name)+'"><div class=ic>🎬</div><div class=m><div class=n>'+E(i.name)+'</div><div class=tags>'+buildBadges(i.name,i.size)+'</div></div><a class=go href="/watch?path='+encodeURIComponent(i.path)+'" onclick="event.stopPropagation()">独立页 ↗</a></div>';
    }).join('');
    var rows=l.querySelectorAll('.i[data-p]');
    for(var k=0;k<rows.length;k++){
      rows[k].onclick=function(){
        openInlinePlayer(this.getAttribute('data-p'),this.getAttribute('data-n'));
      };
    }
  }catch(e){
    l.innerHTML='<div class=ld>加载失败：'+E(e.name==='AbortError'?'请求超时':e.message)
      +'<br><button class=rt id=rt>重试</button></div>';
    document.getElementById('rt').onclick=load;
  }finally{clearTimeout(t)}
}
load();
</script></body></html>`;
}

function playerPage(fp, fn, sign, host, hosts, probe, env, pageOrigin = '') {
  const qs = new URLSearchParams({ path: fp });
  if (sign) { qs.set('exp', String(sign.exp)); qs.set('sig', sign.sig); }
  const src = '/stream/' + encodeURIComponent(fn) + '?' + qs.toString();
  const originUrl = new URL(pageOrigin || ('https://' + (hosts[0] || host)));
  const abs = originUrl.protocol + '//' + host + src;
  const fallbackAbs = originUrl.origin + src;
  // v25：MKV 给出原生 HLS 主列表（同一枚签名，签名写在路径里）
  const hlsPath = (fp && hlsEligible(fp) && env.HLS_DISABLE !== '1')
    ? `/hls/${hlsTokenFor(fp, sign)}/master.m3u8` : '';
  const hlsAbs = hlsPath ? originUrl.protocol + '//' + host + hlsPath : '';
  const hlsFallback = hlsPath ? originUrl.origin + hlsPath : '';
  const safe = escHtml(fn);
  const J = v => JSON.stringify(v).replace(/</g, '\u003c');
  const probeBytes = envInt(env.EDGE_PROBE_BYTES, EDGE_PING_DEF, 32 * 1024, EDGE_PING_MAX);

  return `<!DOCTYPE html><html lang=zh-CN><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>${safe}</title>
<link rel=preconnect href="${escHtml(originUrl.protocol + '//' + host)}" crossorigin>
<style>
:root{--st:env(safe-area-inset-top,0px);--sb:env(safe-area-inset-bottom,0px)}
*{margin:0;padding:0;box-sizing:border-box}
html,body{height:100%;background:#000;color:#f5f5f7;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
.bar{position:fixed;top:0;left:0;right:0;z-index:20;padding:calc(var(--st)+12px) 20px 12px;background:linear-gradient(rgba(0,0,0,.78),transparent);display:flex;align-items:center;gap:10px}
.bk{min-width:36px;height:36px;padding:0 10px;border-radius:18px;background:rgba(255,255,255,.14);display:inline-flex;align-items:center;justify-content:center;text-decoration:none;color:#fff;font-size:13px;font-weight:600;flex-shrink:0;backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);border:0;cursor:pointer}
.bk.icon{width:36px;padding:0;font-size:18px}
.tt{flex:1;min-width:0;font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.badge{font-size:11px;font-weight:700;letter-spacing:.04em;padding:3px 8px;border-radius:6px;background:rgba(255,255,255,.14);color:#e5e5ea;flex-shrink:0;display:none}
.badge.on{display:inline-block}
.badge.dv{background:rgba(10,132,255,.28);color:#64d2ff;border:1px solid rgba(100,210,255,.35)}
.pw{display:flex;align-items:center;justify-content:center;width:100%;height:100%;padding:60px 0 calc(var(--sb)+20px)}
video{width:100%;max-height:100%;object-fit:contain}
video::cue{background:rgba(0,0,0,.62);color:#fff;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;text-shadow:0 1px 3px rgba(0,0,0,.9)}
.menu{position:fixed;top:calc(var(--st)+56px);right:20px;z-index:30;min-width:220px;max-width:86vw;max-height:65vh;overflow-y:auto;background:rgba(28,28,30,.94);backdrop-filter:blur(28px);-webkit-backdrop-filter:blur(28px);border:1px solid rgba(255,255,255,.12);border-radius:14px;padding:6px;display:none;box-shadow:0 16px 40px rgba(0,0,0,.65)}
.menu.open{display:block}
.mh{font-size:11px;font-weight:700;color:#8e8e93;padding:6px 10px 4px;text-transform:uppercase;letter-spacing:.06em}
.mi{display:flex;align-items:center;justify-content:space-between;width:100%;padding:9px 10px;border:0;background:transparent;color:#f5f5f7;font-size:13px;text-align:left;border-radius:9px;cursor:pointer}
.mi:hover,.mi.act{background:rgba(10,132,255,.24);color:#64d2ff}
.eb{position:fixed;left:0;right:0;bottom:calc(var(--sb)+10px);text-align:center;font-size:12px;color:#86868b;opacity:0;transition:opacity .3s;pointer-events:none;padding:0 16px;z-index:25}
.eb.on{opacity:1}
</style>
<body>
<div class=bar>
  <a class="bk icon" href="/">‹</a>
  <div class=tt>${safe}</div>
  <span class=badge id=bdg></span>
  <button class=bk id=abtn title="切换音轨" style="display:none">♫ 音轨</button>
  <button class=bk id=sbtn title="字幕设置">CC 字幕</button>
  <button class="bk icon" id=cp title="复制外部播放器直链">⧉</button>
</div>
<div class=menu id=amenu></div>
<div class=menu id=smenu></div>
<input type=file id=subfile accept=".srt,.ass,.ssa,.vtt" style="display:none">
<div class=pw><video id=v controls autoplay playsinline preload=auto crossorigin=anonymous></video></div>
<div class=eb id=eb></div>
<script>
var cp=document.getElementById('cp'),V=document.getElementById('v'),
    abtn=document.getElementById('abtn'),sbtn=document.getElementById('sbtn'),
    amenu=document.getElementById('amenu'),smenu=document.getElementById('smenu'),
    subfile=document.getElementById('subfile'),bdg=document.getElementById('bdg'),
    eb=document.getElementById('eb');

var ABS=${J(abs)},FALLBACK=${J(fallbackAbs)},FP=${J(fp)},FN=${J(fn)},
    SIGNED=${sign ? 'true' : 'false'},
    HOSTS=${J(hosts)},PB=${J(probe)},PP=${J(EDGE_PING_PATH)},
    PZ=${probeBytes},CUR=${J(originUrl.host)},SCHEME=${J(originUrl.protocol)},
    CK=${J(EDGE_COOKIE)},TTL=${EDGE_COOKIE_TTL},
    HLS=${J(hlsAbs)},HLS_FB=${J(hlsFallback)};

${safariMediaEngineScript()}

var sayTimer=0,hlsMode=false;
function say(m,ms){
  eb.textContent=m;eb.classList.add('on');
  clearTimeout(sayTimer);
  sayTimer=setTimeout(function(){eb.classList.remove('on')},ms||4000);
}
function setBadge(txt,dv){
  if(!txt){bdg.className='badge';return}
  bdg.textContent=txt;
  bdg.className='badge on'+(dv?' dv':'');
}

cp.onclick=async function(){
  var raw=new URL(ABS);raw.searchParams.delete('safari');raw.searchParams.delete('_retry');
  try{await navigator.clipboard.writeText(raw.href);cp.textContent='✓';setTimeout(function(){cp.textContent='⧉'},1200)}
  catch(e){prompt('外部播放器直链（Infuse / VLC）',raw.href)}
};

document.addEventListener('click',function(e){
  if(!amenu.contains(e.target)&&e.target!==abtn)amenu.classList.remove('open');
  if(!smenu.contains(e.target)&&e.target!==sbtn)smenu.classList.remove('open');
});

function sameEntry(u){
  try{return new URL(u).origin===new URL(FALLBACK).origin}catch(e){return false}
}
function clearPin(){
  document.cookie=CK+'=; path=/; max-age=0; SameSite=Lax'+(location.protocol==='https:'?'; Secure':'');
}
function useOriginFallback(){
  if(sameEntry(ABS))return false;
  ABS=FALLBACK;if(HLS_FB)HLS=HLS_FB;clearPin();return true;
}
function playSrc(){return hlsMode?HLS:withSafariUrl(ABS)}
function withSafariUrl(u){
  var x=new URL(u);
  if(/\.(mp4|m4v|mov)$/i.test(FN))x.searchParams.set('safari','1');
  return x.href;
}

sbtn.onclick=function(){
  amenu.classList.remove('open');
  var tts=V.textTracks||[],anyOn=false;
  for(var i=0;i<tts.length;i++)if(tts[i].mode==='showing')anyOn=true;
  var html='<div class=mh>字幕轨道</div>';
  html+='<button class="mi'+(!anyOn?' act':'')+'" data-sub="-1"><span>关闭字幕</span><span>'+(anyOn?'':'✓')+'</span></button>';
  for(var j=0;j<tts.length;j++){
    var t=tts[j],on=t.mode==='showing';
    html+='<button class="mi'+(on?' act':'')+'" data-sub="'+j+'"><span>'+(t.label||t.language||('轨道 #'+(j+1)))+'</span><span>'+(on?'✓':'')+'</span></button>';
  }
  html+='<div class=mh style="margin-top:6px">本地文件</div><button class=mi id=picksub><span>+ 挂载本地字幕 (.srt/.ass/.vtt)</span></button>';
  smenu.innerHTML=html;
  smenu.classList.toggle('open');
  var btns=smenu.querySelectorAll('[data-sub]');
  for(var k=0;k<btns.length;k++){
    btns[k].onclick=function(){
      var idx=parseInt(this.getAttribute('data-sub'),10);
      for(var m=0;m<tts.length;m++)tts[m].mode=(m===idx)?'showing':'disabled';
      smenu.classList.remove('open');
    };
  }
  var pk=document.getElementById('picksub');
  if(pk)pk.onclick=function(){smenu.classList.remove('open');subfile.click()};
};

subfile.onchange=async function(){
  var f=subfile.files&&subfile.files[0];
  if(!f)return;
  var buf=new Uint8Array(await f.arrayBuffer()),txt='';
  try{txt=new TextDecoder('utf-8',{fatal:true}).decode(buf)}
  catch(e){try{txt=new TextDecoder('gb18030').decode(buf)}catch(e2){txt=new TextDecoder().decode(buf)}}
  var ext=f.name.slice(f.name.lastIndexOf('.')).toLowerCase();
  var cues=parseClientSubToCues(txt,ext);
  var tr=V.addTextTrack('subtitles',f.name.replace(/\.[^.]+$/,''),'zh');
  var Cue=window.VTTCue||window.TextTrackCue;
  for(var i=0;i<cues.length;i++){try{tr.addCue(new Cue(cues[i].start,cues[i].end,cues[i].text))}catch(e){}}
  for(var k=0;k<V.textTracks.length;k++)V.textTracks[k].mode='disabled';
  tr.mode='showing';
  say('已加载本地字幕：'+f.name+'（'+cues.length+' 句）');
  subfile.value='';
};

V.addEventListener('loadedmetadata',function(){
  var ats=V.audioTracks||[];
  if(ats.length>1)abtn.style.display='inline-flex';
  if(hlsMode)return;                         // HLS 模式的徽章来自码流检测，不按文件名猜
  if(/\b(dovi|dolby[\s._-]?vision|dv)\b/i.test(FN))setBadge('Dolby Vision',true);
  else if(/\b(hdr10\+?|hdr|hlg|2160p|4k)\b/i.test(FN))setBadge('HDR',false);
});

abtn.onclick=function(){
  smenu.classList.remove('open');
  var ats=V.audioTracks||[];
  var html='<div class=mh>音轨选择</div>';
  for(var k=0;k<ats.length;k++){
    var a=ats[k];
    html+='<button class="mi'+(a.enabled?' act':'')+'" data-na="'+k+'"><span>'+(a.label||a.language||('音轨 #'+(k+1)))+'</span><span>'+(a.enabled?'✓':'')+'</span></button>';
  }
  amenu.innerHTML=html;
  amenu.classList.toggle('open');
  var nb=amenu.querySelectorAll('[data-na]');
  for(var m=0;m<nb.length;m++){
    nb[m].onclick=function(){
      var idx=parseInt(this.getAttribute('data-na'),10);
      for(var n=0;n<ats.length;n++)ats[n].enabled=(n===idx);
      amenu.classList.remove('open');
    };
  }
};

async function candidateReady(u){
  if(sameEntry(u))return true;
  var c=new AbortController(),tm=setTimeout(function(){c.abort()},3500);
  try{
    var r=await fetch(u,{method:'HEAD',cache:'no-store',credentials:'omit',signal:c.signal});
    return r.ok&&(r.status===200||r.status===206);
  }catch(e){return false}finally{clearTimeout(tm)}
}
async function bootstrap(){
  // v25：MKV + Safari / iOS → 原生 HLS。先取 info.json：既是可用性探测，也顺带把索引建好
  if(HLS&&canNativeHls(V)){
    try{
      var info;
      try{info=await hlsPreflight(HLS)}
      catch(e){
        if(e.status||!HLS_FB||HLS_FB===HLS)throw e;   // 只有网络级失败才换入口
        HLS=HLS_FB;clearPin();info=await hlsPreflight(HLS);
      }
      hlsMode=true;
      var bt=hlsBadgeText(info);
      if(bt)setBadge(bt,bt==='Dolby Vision');
      var note=hlsAudioNote(info);
      if(note)say(note,7000);
      V.src=HLS;V.load();
      V.play().catch(function(){});
      return;
    }catch(e){say('无法生成 HLS（'+e.message+'），改用直连播放',5000)}
  }
  if(!(await candidateReady(ABS))){
    useOriginFallback();say('优选入口不可用，已回退当前入口');
  }
  mountExternalSubs(V,FP,new URL(ABS).origin,say);
  V.src=withSafariUrl(ABS);V.load();
  V.play().catch(function(){});
}

var recovering=false,failures=0,stallTimer=0,stableTimer=0,retryTimer=0,raceStarted=false;
function pause(ms){return new Promise(function(ok){setTimeout(ok,ms)})}
function clearStall(){if(stallTimer){clearTimeout(stallTimer);stallTimer=0}}
function markStable(){
  clearTimeout(stableTimer);
  stableTimer=setTimeout(function(){failures=0},30000);
}
async function renewLink(){
  if(!SIGNED||!FP)return;
  var r=await fetch('/api/stream-sign?path='+encodeURIComponent(FP),{cache:'no-store',credentials:'same-origin'});
  if(!r.ok)throw new Error('sign '+r.status);
  var s=await r.json();
  if(!s.sig||!s.exp)throw new Error('empty sign');
  var u=new URL(ABS);u.searchParams.set('exp',String(s.exp));u.searchParams.set('sig',s.sig);
  u.searchParams.delete('_retry');ABS=u.href;
  if(HLS&&s.hls){var h=new URL(HLS);HLS=h.protocol+'//'+h.host+s.hls}
}
function loaded(){
  return new Promise(function(resolve,reject){
    var timer=setTimeout(function(){done();reject(new Error('metadata timeout'))},15000);
    function done(){clearTimeout(timer);V.removeEventListener('loadedmetadata',ok);V.removeEventListener('error',bad)}
    function ok(){done();resolve()}
    function bad(){done();reject(new Error('media '+(V.error&&V.error.code||0)))}
    V.addEventListener('loadedmetadata',ok,{once:true});V.addEventListener('error',bad,{once:true});
  });
}
async function recover(reason){
  if(recovering||V.ended)return;
  if(failures>=4){say('视频持续加载失败，请刷新页面或使用外部播放器');return}
  var switched=useOriginFallback();
  recovering=true;clearStall();clearTimeout(retryTimer);clearTimeout(stableTimer);failures++;
  var at=Number.isFinite(V.currentTime)?V.currentTime:0,wantsPlay=V.autoplay||!V.paused;
  say((switched?'优选入口失效，已回退；':reason+'，')+'正在恢复（'+failures+'/4）');
  try{
    await pause(switched?0:([0,500,1500,4000,7000][failures]||7000));
    try{await renewLink()}catch(e){}
    var u=new URL(playSrc());u.searchParams.set('_retry',String(Date.now()));
    var ready=loaded();
    V.src=u.href;V.load();await ready;
    if(at>0&&Number.isFinite(V.duration))V.currentTime=Math.min(at,Math.max(0,V.duration-.25));
    if(wantsPlay)await V.play().catch(function(){});
  }catch(e){
    if(failures<4)retryTimer=setTimeout(function(){recover('重新连接')},Math.min(8000,failures*2000));
    else say('恢复失败，请刷新页面或使用外部播放器');
  }finally{recovering=false}
}
function armStall(reason){
  clearStall();if(V.paused||V.ended||document.hidden||recovering)return;
  var at=V.currentTime;
  stallTimer=setTimeout(function(){
    stallTimer=0;
    if(!V.paused&&!V.ended&&V.readyState<3&&Math.abs(V.currentTime-at)<.05)recover(reason);
  },20000);
}
function scheduleRace(){
  if(raceStarted)return;raceStarted=true;
  setTimeout(function(){race().catch(function(){})},2500);
}
V.addEventListener('playing',function(){clearStall();markStable();scheduleRace()});
V.addEventListener('timeupdate',clearStall);
V.addEventListener('waiting',function(){armStall('缓冲超时')});
V.addEventListener('stalled',function(){armStall('网络停滞')});
V.addEventListener('seeking',clearStall);
V.addEventListener('error',function(){
  var code=V.error&&V.error.code||0;
  if(code===1)return;
  // HLS 下的 code 4 = 本机解码器不支持这种视频（如老设备不支持 10bit HEVC），重试无用
  if(hlsMode&&code===4&&!V.currentTime){say('此设备无法解码该视频，可复制直链用 Infuse 播放',8000);return}
  recover(code===3?'视频解码失败':'视频加载失败');
});

function pin(h){
  document.cookie=CK+'='+h+'; path=/; max-age='+TTL+'; SameSite=Lax'+(location.protocol==='https:'?'; Secure':'');
}
async function probe(h){
  var u=SCHEME+'//'+h+PP+'?path=__probe__&exp='+PB.exp+'&sig='+encodeURIComponent(PB.sig)+'&b='+PZ+'&_='+Date.now()+Math.random();
  var t0=performance.now();
  var r=await fetch(u,{cache:'no-store'});
  if(!r.ok)throw new Error('HTTP '+r.status);
  var rd=r.body.getReader(),n=0,tf=0;
  for(;;){var x=await rd.read();if(x.done)break;if(!tf)tf=performance.now();n+=x.value.length}
  var t1=performance.now(),ttfb=(tf||t1)-t0,ms=Math.max(1,t1-(tf||t0));
  var mbps=n/1048576/ms*1000;
  return {h:h,ttfb:ttfb,mbps:mbps,score:ttfb+600/Math.max(0.5,mbps)};
}
async function race(){
  if(!PB||HOSTS.length<2)return;
  if(navigator.connection&&navigator.connection.saveData)return;
  if(document.hidden)return;
  var rs=await Promise.allSettled(HOSTS.map(probe));
  var ok=[];
  for(var i=0;i<rs.length;i++)if(rs[i].status==='fulfilled')ok.push(rs[i].value);
  if(!ok.length)return;
  ok.sort(function(a,b){return a.score-b.score});
  var w=ok[0];
  pin(w.h);
  var direct=new URL(ABS);direct.protocol=SCHEME;direct.host=w.h;ABS=direct.href;
  say(w.h===CUR
    ? '入口 '+w.h+' · '+Math.round(w.ttfb)+'ms · '+w.mbps.toFixed(1)+'MB/s'
    : '已选用更快入口 '+w.h+' · '+Math.round(w.ttfb)+'ms · 下次起播生效');
}

bootstrap().catch(function(){useOriginFallback();V.src=playSrc();V.load()});
</script></body></html>`;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  /dupes — 重复影片列表页
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  页面本身零数据、可缓存；数据现取 /api/dupes（带 Cookie）。
//  「执行清理」把当前列表的 gen 作为 confirm 回传 —— 你点的就是你看到的那份。
//  客户端脚本里刻意不用模板字符串：整段是 worker 的模板字符串，
//  嵌套 ${} 迟早写错，字符串拼接换来的是「一眼看得出对不对」。

function dupesPage() {
  return `<!DOCTYPE html><html lang=zh-CN><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name=robots content="noindex,nofollow"><title>重复影片</title>
<style>
:root{--bg:#000;--card:rgba(28,28,30,.72);--line:rgba(255,255,255,.08);--t:#f5f5f7;--t2:#98989d;--a:#0A84FF;--g:#30D158;--r:#FF453A;--o:#FF9F0A;
--st:env(safe-area-inset-top,0px);--sb:env(safe-area-inset-bottom,0px);--spring:cubic-bezier(.22,1.2,.36,1)}
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{min-height:100dvh;background:var(--bg);color:var(--t);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text",sans-serif;
padding:calc(var(--st) + 18px) 16px calc(var(--sb) + 90px);max-width:760px;margin:0 auto;-webkit-font-smoothing:antialiased}
.eb{font-size:12px;letter-spacing:.09em;text-transform:uppercase;color:var(--t2)}
h1{font-size:32px;font-weight:700;letter-spacing:-.02em;margin:4px 0 14px}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:18px}
.st{background:var(--card);backdrop-filter:blur(24px) saturate(180%);-webkit-backdrop-filter:blur(24px) saturate(180%);
border:1px solid var(--line);border-radius:16px;padding:12px 8px;text-align:center}
.st b{display:block;font-size:19px;font-weight:700;letter-spacing:-.01em}
.st span{font-size:11px;color:var(--t2)}
.g{background:var(--card);backdrop-filter:blur(24px) saturate(180%);-webkit-backdrop-filter:blur(24px) saturate(180%);
border:1px solid var(--line);border-radius:18px;padding:14px 16px;margin-bottom:10px}
.gt{font-size:16px;font-weight:600;letter-spacing:-.01em}
.tags{display:flex;flex-wrap:wrap;gap:6px;margin:7px 0 10px;align-items:center}
.cap{height:22px;display:inline-flex;align-items:center;padding:0 9px;border-radius:11px;font-size:11px;font-weight:500;line-height:1}
.same{background:rgba(255,255,255,.1);color:var(--t2)}
.cross{background:rgba(255,159,10,.16);color:var(--o)}
.warn{background:rgba(255,69,58,.16);color:var(--r)}
.re{font-size:11px;color:var(--t2)}
.f{display:flex;gap:10px;align-items:flex-start;padding:9px 11px;border-radius:12px;margin-top:6px}
.fk{background:rgba(48,209,88,.1);border:1px solid rgba(48,209,88,.22)}
.fd{background:rgba(255,69,58,.08);border:1px solid rgba(255,69,58,.18)}
.fh{background:rgba(255,255,255,.05);border:1px solid var(--line)}
.mk{font-size:13px;font-weight:700;flex-shrink:0;width:14px;line-height:1.45}
.fk .mk{color:var(--g)}.fd .mk{color:var(--r)}.fh .mk{color:var(--t2)}
.fn{flex:1;min-width:0;font-size:13px;line-height:1.45;word-break:break-all}
.fd .fn{text-decoration:line-through;text-decoration-color:rgba(255,69,58,.5)}
.fh .fn{text-decoration:none;color:var(--t2)}
.fm{font-size:11px;color:var(--t2);margin-top:2px}
.bar{position:fixed;left:0;right:0;bottom:0;padding:12px 16px calc(var(--sb) + 12px);display:flex;gap:10px;justify-content:center;
background:linear-gradient(transparent,rgba(0,0,0,.86) 42%);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px)}
button{height:46px;padding:0 22px;border:0;border-radius:23px;font-size:15px;font-weight:600;color:#fff;background:rgba(255,255,255,.14);
cursor:pointer;transition:transform .32s var(--spring),opacity .2s;font-family:inherit}
button:active{transform:scale(.94)}button:disabled{opacity:.42}
#go{background:var(--r)}#ml{background:var(--a)}
.msg{text-align:center;padding:64px 20px;color:var(--t2);font-size:15px}
.toast{position:fixed;left:50%;bottom:calc(var(--sb) + 76px);transform:translate(-50%,14px) scale(.96);opacity:0;
background:rgba(44,44,46,.92);backdrop-filter:blur(20px);border:1px solid var(--line);border-radius:18px;padding:11px 18px;font-size:14px;
max-width:88vw;text-align:center;transition:all .42s var(--spring);pointer-events:none;z-index:20}
.toast.on{opacity:1;transform:translate(-50%,0) scale(1)}
</style></head><body>
<div class=eb>Stream · 影库巡检</div><h1>重复影片</h1>
<div id=sum></div><div id=list><div class=msg>扫描中…</div></div>
<div class=bar><button id=ml>邮件发我</button><button id=go disabled>执行清理</button></div>
<div class=toast id=ts></div>
<script>
var D=null,L=document.getElementById('list'),S=document.getElementById('sum'),
    GO=document.getElementById('go'),ML=document.getElementById('ml'),TS=document.getElementById('ts');
function E(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
function SZ(b){b=Number(b)||0;var G=1073741824,M=1048576;
  return b>=G?(b/G).toFixed(2)+' GB':b>=M?Math.round(b/M)+' MB':Math.round(b/1024)+' KB'}
function toast(m){TS.textContent=m;TS.classList.add('on');clearTimeout(toast.t);toast.t=setTimeout(function(){TS.classList.remove('on')},2600)}

function stats(s){
  var c=[['重复组',s.groups],['可删',s.files],['可释放',SZ(s.reclaim)],['跨规格',s.cross]];
  S.innerHTML='<div class=grid>'+c.map(function(x){
    return '<div class=st><b>'+E(x[1])+'</b><span>'+x[0]+'</span></div>'}).join('')+'</div>';
}

function file(f,cls,mark,note){
  return '<div class="f '+cls+'"><div class=mk>'+mark+'</div><div class=fn>'+E(f.name)
    +'<div class=fm>'+E(f.spec)+' · '+SZ(f.size)+(note?' · '+E(note):'')+'</div></div></div>';
}

function render(d){
  D=d;stats(d.summary);
  if(!d.groups.length){L.innerHTML='<div class=msg>没有发现重复影片 ✦</div>';GO.disabled=true;return}
  GO.disabled=!d.summary.files;
  GO.textContent=d.summary.files?('清理 '+d.summary.files+' 个 · 省 '+SZ(d.summary.reclaim)):'无可清理';
  L.innerHTML=d.groups.map(function(g){
    var tags='<span class="cap '+(g.kind==='same'?'same':'cross')+'">'+(g.kind==='same'?'同规格':'跨规格')+'</span>'
      +(g.downgrade?'<span class="cap warn">⚠︎ 降规格</span>':'')
      +'<span class=re>可释放 '+SZ(g.reclaim)+'</span>';
    return '<div class=g><div class=gt>'+E(g.title)+(g.year?' ('+E(g.year)+')':'')+(g.ep?' · '+E(g.ep):'')+(g.ver?' · '+E(g.ver)+'版':'')+'</div>'
      +'<div class=tags>'+tags+'</div>'
      +file(g.keep,'fk','✓','保留')
      +g.drop.map(function(f){return f.hold?file(f,'fh','—','跳过（'+f.hold+'）'):file(f,'fd','✕','待删除')}).join('')
      +'</div>'}).join('');
}

function load(){
  L.innerHTML='<div class=msg>扫描中…</div>';
  var c=new AbortController(),t=setTimeout(function(){c.abort()},20000);
  fetch('/api/dupes',{signal:c.signal,cache:'no-store'})
    .then(function(r){if(!r.ok)throw new Error('HTTP '+r.status);return r.json()})
    .then(render)
    .catch(function(e){L.innerHTML='<div class=msg>加载失败：'+E(e.name==='AbortError'?'请求超时':e.message)+'</div>'})
    .finally(function(){clearTimeout(t)});
}

ML.onclick=function(){
  ML.disabled=true;ML.textContent='发送中…';
  fetch('/api/dupes?mail=1',{cache:'no-store'}).then(function(r){return r.json()}).then(function(j){
    toast(j.mail&&j.mail.ok?('已发送至 '+j.mail.to+'（'+j.mail.via+'）'):('发送失败：'+((j.mail&&j.mail.error)||'未知')));
  }).catch(function(e){toast('发送失败：'+e.message)})
    .finally(function(){ML.disabled=false;ML.textContent='邮件发我'});
};

GO.onclick=function(){
  if(!D)return;
  if(!confirm('将删除 '+D.summary.files+' 个重复文件，释放 '+SZ(D.summary.reclaim)
    +'。\\n每组只保留体积最大的那个。\\n文件进 Dropbox 回收站，30 天内可还原。\\n\\n继续？'))return;
  GO.disabled=true;GO.textContent='清理中…';
  fetch('/api/dupes/prune?confirm='+encodeURIComponent(D.gen),{method:'POST',cache:'no-store'})
    .then(function(r){return r.json().then(function(j){return{s:r.status,j:j}})})
    .then(function(o){
      if(o.s===409){toast('片库已变化，已刷新列表');return load()}
      if(!o.j.ok){toast('清理失败：'+(o.j.error||o.s));GO.disabled=false;GO.textContent='执行清理';return}
      var p=o.j.prune;
      toast('已删除 '+p.deleted.length+' 个 · 释放 '+SZ(p.freed)
        +(p.failed.length?(' · 失败 '+p.failed.length):'')+(p.deferred?(' · 顺延 '+p.deferred):''));
      setTimeout(load,1400);
    })
    .catch(function(e){toast('清理失败：'+e.message);GO.disabled=false;GO.textContent='执行清理'});
};

load();
</script></body></html>`;
}
