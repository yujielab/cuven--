/**
 * Dropbox Video Proxy — Cloudflare Worker (v24 · 2026-11-08)
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

      // /stream 鉴权短路：HMAC 签名直链（?exp=&sig=）内联校验放行。
      // 外部播放器（Infuse/VLC）不处理 Set-Cookie，必须在本次请求内完成校验；
      // v14 的 ?key= 内联放行会把主密钥留在播放器历史、分享链接与各级访问
      // 日志里 —— 已由「可分享、会过期、不含主密钥」的签名取代。
      const authed =
        (cookie.auth && await verifySession(cookie.auth, env)) ||
        ((isStream || isProbe || isSubVtt) && await verifyStreamSig(url, env));

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

  return jsonResponse({ subs }, 200, { 'Cache-Control': 'public, max-age=60' });
}

async function handleSubVtt(url, env, ctx) {
  const filePath = url.searchParams.get('path') || '';
  if (!filePath) return new Response('Missing path', { status: 400 });
  const ext = getExt(filePath);
  if (!SUB_EXTS.has(ext)) return new Response('Unsupported subtitle format', { status: 400 });

  const { g } = await ptrGet(env);
  const ck = new Request(`${SUB_CACHE}?p=${encodeURIComponent(filePath)}&g=${g}`);
  const cache = caches.default;
  const hit = await cache.match(ck);
  if (hit) return new Response(hit.body, { headers: hit.headers });

  const linkData = await getTempLink(filePath, env, ctx);
  const res = await fetchRetry(linkData.link, {}, { retries: 1, timeout: 10_000 });
  if (!res.ok) return new Response('Upstream subtitle error', { status: 502 });

  const u8 = new Uint8Array(await res.arrayBuffer());
  const rawText = decodeSubtitleBytes(u8);
  const vtt = convertToWebVtt(rawText, ext);

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
//  v24：Safari MP4/MOV FourCC 零拷贝流式热修补
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

    if (isDvhe) {
      buf[i] = 0x64; buf[i + 1] = 0x76; buf[i + 2] = 0x68; buf[i + 3] = 0x31; // dvh1
      continue;
    }
    if (isHev1 || isHvc1) {
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
  try {
    // CF Workers 非标扩展；等长前提下不会 throw
    return crypto.subtle.timingSafeEqual(ea, eb);
  } catch {
    // 兜底：非 CF 运行环境（本地单测等）无此扩展 → 手写恒时比较
    let diff = 0;
    for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
    return diff === 0;
  }
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
  };

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
    c.account = `${acctP.value.name?.display_name} (${acctP.value.email})`;
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

  return healthHTML(c, c.account ? 200 : 503);
}

function healthHTML(c, status) {
  const ok = status === 200;
  return new Response(`<!DOCTYPE html><html lang=zh-CN><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Health</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{min-height:100dvh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;background:#000;color:#f5f5f7}
.c{width:400px;max-width:90vw;background:#111;border-radius:20px;padding:28px;border:1px solid #222}.r{display:flex;justify-content:space-between;padding:10px 0;border-bottom:1px solid #1a1a1a;font-size:14px}.r:last-child{border:none}.l{color:#86868b}.s{margin-top:16px;padding:12px;border-radius:12px;text-align:center;font-weight:600;font-size:15px}
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
      const { title, year } = parseFilename(video.name);
      const key = `${title || video.name}|${year || ''}`;
      let releaseDate = null;
      let releaseYear = year ? parseInt(year, 10) : 0;

      const cached = memoIn[key];
      if (cached) {
        releaseDate = cached.d || null;
        releaseYear = cached.y || releaseYear;
      } else if (title) {
        try {
          const p = await fetchMetadata(title, year, false, env);
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

async function fetchITunesArtwork(title, year, mediaType) {
  try {
    // 并发 cn + us，Promise.any 取首个成功
    const result = await Promise.any([
      _itunesSearch(title, year, mediaType, 'cn'),
      _itunesSearch(title, year, mediaType, 'us'),
    ]);
    return result;
  } catch { return null; }
}

async function _itunesSearch(title, year, mediaType, country) {
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

  let best = results[0];
  if (year) {
    const match = results.find(r => (r.releaseDate || '').startsWith(year));
    if (match) best = match;
  }

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

const TMDB_CACHE = 'https://cache.internal/tmdb-v7/';   // v7：payload 新增 imdb —— 不换命名空间的话，旧缓存要压 7 天才吐出新字段

function tmdbCacheKey(title, year, full) {
  const p = new URLSearchParams({ q: title.toLowerCase() });
  if (year) p.set('y', year);
  if (full) p.set('f', '1');
  return new Request(`${TMDB_CACHE}?${p}`);
}

async function handleTmdb(url, env, ctx) {
  if (!env.TMDB_API_KEY) return jsonResponse({ error: 'TMDB_API_KEY not set' }, 503);
  const query = url.searchParams.get('query') || '';
  const year = url.searchParams.get('year') || '';
  const full = url.searchParams.get('logo') === '1';
  if (!query) return jsonResponse({ error: 'Missing query' }, 400);

  const ck = tmdbCacheKey(query, year, full);
  const cache = caches.default;
  const hit = await cache.match(ck);
  if (hit) return new Response(hit.body, { headers: hit.headers });

  const payload = await fetchMetadata(query, year, full, env);
  const body = payload ? JSON.stringify(payload) : 'null';
  const resp = new Response(body, {
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=86400, s-maxage=604800, stale-while-revalidate=2592000',
    },
  });
  ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
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

  await parallel(
    queries.filter(q => q?.name).map(q => async () => {
      const { title, year } = parseFilename(q.name);
      if (!title) { result[q.name] = null; return; }
      const full = !!q.logo;
      const ck = tmdbCacheKey(title, year, full);

      const hit = await cache.match(ck);
      if (hit) {
        try { result[q.name] = JSON.parse(await hit.text()); } catch { result[q.name] = null; }
        return;
      }

      // 修复：fetchMetadata 抛错会让该 key 直接从结果里消失（前端拿不到任何信号）
      // → 抛错置 null；且瞬时失败不写缓存，避免把一次网络抖动负缓存一周
      let data = null;
      let failed = false;
      try { data = await fetchMetadata(title, year, full, env); }
      catch { failed = true; }
      result[q.name] = data;
      if (failed) return;
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
const IMDB_CACHE = 'https://cache.internal/imdb-v1/';
const IMDB_TTL   = 21600;        // 6h —— 必须 < 签名的 24h
const IMDB_MISS_TTL = 3600;      // 查无此片：缓存 1h，别每次都去打 IMDb

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
  }, { retries: 1, timeout: 8000 });
  if (!res?.ok) throw new Error('imdb ' + (res?.status || 'fail'));
  const j = await res.json();
  return j?.data?.title || null;
}

/* 前端还没有 imdb 字段时的兜底：TMDB 现查一次拿编号 */
async function resolveImdbId(query, year, env) {
  if (!env.TMDB_API_KEY) return null;
  try {
    const hit = await tmdbSearch('movie', query, year, env) || await tmdbSearch('tv', query, year, env);
    if (!hit) return null;
    const type = hit.title ? 'movie' : 'tv';
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
  const nStills = Math.min(24, Math.max(0, Number(url.searchParams.get('stills') ?? 10) || 0));

  if (!/^tt\d+$/.test(id)) {
    if (!query) return jsonResponse({ error: 'Missing id or query' }, 400);
    id = await resolveImdbId(query, year, env);
    if (!id) {
      return jsonResponse({ id: null, video: null, stills: [] }, 200, {
        'Cache-Control': `public, max-age=${IMDB_MISS_TTL}`,
      });
    }
  }

  const ck = new Request(`${IMDB_CACHE}${id}?n=${nStills}`);
  const cache = caches.default;
  const hit = await cache.match(ck);
  if (hit) return new Response(hit.body, { headers: hit.headers });

  let payload;
  try {
    const t = await imdbGraphQL(id, nStills);
    if (!t) throw new Error('no title');

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

    payload = {
      id: t.id || id,
      title: t.titleText?.text || null,
      year: t.releaseYear?.year || null,
      plot: t.plot?.plotText?.plainText || null,
      video,
      stills,
    };
  } catch {
    /* IMDb 抽风不该把整屏拖垮：回一个空壳，短缓存，下次再试 */
    return jsonResponse({ id, video: null, stills: [] }, 200, {
      'Cache-Control': 'public, max-age=300',
    });
  }

  const resp = new Response(JSON.stringify(payload), {
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      /* stale-while-revalidate 故意不给：过期的签名地址不能再端上来 */
      'Cache-Control': `public, max-age=${payload.video ? IMDB_TTL : IMDB_MISS_TTL}`,
    },
  });
  ctx?.waitUntil?.(cache.put(ck, resp.clone()));
  return resp;
}

// ── 核心：融合 TMDB + iTunes ──

async function fetchMetadata(title, year, full, env) {
  // TMDB 搜索（movie 优先，fallback tv）
  let hit = await tmdbSearch('movie', title, year, env);
  let type = 'movie';
  if (!hit) { hit = await tmdbSearch('tv', title, year, env); type = 'tv'; }
  if (!hit) return null;

  const out = {
    id: hit.id,
    title: hit.title || hit.name,
    year: (hit.release_date || hit.first_air_date || '').slice(0, 4),
    release_date: hit.release_date || hit.first_air_date || null,
    poster: hit.poster_path ? `https://image.tmdb.org/t/p/w342${hit.poster_path}` : null,
    backdrop: hit.backdrop_path ? `https://image.tmdb.org/t/p/w1280${hit.backdrop_path}` : null,
    overview: hit.overview || '',
    rating: hit.vote_average || 0,
    type,
    logo: null, logoAspect: null,
    imdb: null,
    runtime: null, genres: [],
    cast: [], director: null, creators: [],
    artworkSource: 'tmdb',
  };

  if (!full) return out;

  // ── 全量模式：并发 iTunes + TMDB images/detail/credits ──
  const key = env.TMDB_API_KEY;
  const id = hit.id;

  const [itunes, imgRes, detailRes, creditsRes] = await Promise.allSettled([
    fetchITunesArtwork(title, year, type),
    fetchRetry(`https://api.themoviedb.org/3/${type}/${id}/images?api_key=${key}&include_image_language=zh,en,null`, {}, { retries: 1, timeout: 6000 }),
    fetchRetry(`https://api.themoviedb.org/3/${type}/${id}?api_key=${key}&language=zh-CN&append_to_response=external_ids`, {}, { retries: 1, timeout: 6000 }),
    fetchRetry(`https://api.themoviedb.org/3/${type}/${id}/credits?api_key=${key}&language=zh-CN`, {}, { retries: 1, timeout: 6000 }),
  ]);

  // iTunes 优先：海报 & 背景
  if (itunes.status === 'fulfilled' && itunes.value) {
    out.poster = itunes.value.poster;
    out.backdrop = itunes.value.backdrop;
    out.artworkSource = 'itunes';
  }

  // TMDB Logo + Stills（剧照画廊用）
  if (imgRes.status === 'fulfilled' && imgRes.value?.ok) {
    try {
      const imgData = await imgRes.value.json();
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
      const heroBdPath = hit.backdrop_path;
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

async function tmdbSearch(type, query, year, env) {
  const p = new URLSearchParams({ api_key: env.TMDB_API_KEY, query, language: 'zh-CN', page: '1' });
  if (year) p.set(type === 'movie' ? 'year' : 'first_air_date_year', year);
  const res = await fetchRetry(
    `https://api.themoviedb.org/3/search/${type}?${p}`,
    {},
    { retries: 1, timeout: 6000 },
  );
  if (!res.ok) return null;
  return (await res.json()).results?.[0] || null;
}

function parseFilename(fn) {
  let n = fn.replace(/\.[^.]+$/, '');
  const ym = n.match(/[\.\s\-_\(]((?:19|20)\d{2})[\.\s\-_\)]/);
  const year = ym ? ym[1] : '';
  let title = n;
  if (ym) title = n.slice(0, n.indexOf(ym[0]));
  else title = n.split(/[\.\s_\-](?:2160p|1080p|720p|4K|UHD|BluRay|BDRip|WEB[\-.]?DL|WEB[\-.]?Rip|x264|x265|HEVC|H\.?26[45]|AAC|DTS|FLAC|REMUX|DoVi|DV|HDR|Atmos|10bit)/i)[0];
  title = title.replace(/[\._]/g, ' ').replace(/\[.*?\]|\{.*?\}/g, '').replace(/\s+/g, ' ').trim();
  return { title, year };
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
//  /watch
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async function handleStreamSign(url, env) {
  const filePath = url.searchParams.get('path') || '';
  if (!filePath) return jsonResponse({ error: 'Missing path' }, 400, { 'Cache-Control': 'no-store' });
  if (!env.AUTH_SECRET) {
    return jsonResponse({ exp: null, sig: null }, 200, { 'Cache-Control': 'no-store' });
  }
  const sign = await signStreamPath(filePath, env);
  return jsonResponse(sign, 200, { 'Cache-Control': 'no-store' });
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

// ── ISO-BMFF (fMP4) 构造器（支持 dvh1 杜比视界 / hvc1 HDR10 / avc1 / ec-3 / ac-3 / mp4a）──
function u32(v){return[(v>>>24)&255,(v>>>16)&255,(v>>>8)&255,v&255]}
function u16(v){return[(v>>>8)&255,v&255]}
function strBytes(s){var a=[];for(var i=0;i<s.length;i++)a.push(s.charCodeAt(i)&255);return a}
function box(type){
  var parts=[],total=8;
  for(var i=1;i<arguments.length;i++){
    var p=arguments[i];
    if(!p)continue;
    var u=p instanceof Uint8Array?p:new Uint8Array(p);
    parts.push(u);total+=u.length;
  }
  var out=new Uint8Array(total);
  out[0]=(total>>>24)&255;out[1]=(total>>>16)&255;out[2]=(total>>>8)&255;out[3]=total&255;
  for(var j=0;j<4;j++)out[4+j]=type.charCodeAt(j)&255;
  var off=8;
  for(var k=0;k<parts.length;k++){out.set(parts[k],off);off+=parts[k].length}
  return out;
}
function fullBox(type,ver,flags){
  var hdr=new Uint8Array([ver,(flags>>>16)&255,(flags>>>8)&255,flags&255]);
  var args=[type,hdr];
  for(var i=3;i<arguments.length;i++)args.push(arguments[i]);
  return box.apply(null,args);
}

function buildVideoInitMp4(vt,durationSec){
  var isHevc=vt.codecId==='V_MPEGH/ISO/HEVC';
  var fourcc=isHevc?(vt.doviConfig?'dvh1':'hvc1'):'avc1';
  var cfgBox=isHevc?box('hvcC',vt.codecPrivate||new Uint8Array(0)):box('avcC',vt.codecPrivate||new Uint8Array(0));
  var doviBox=vt.doviConfig?box((vt.doviConfig[2]>>>1)>7?'dvvC':'dvcC',vt.doviConfig):null;
  var colrBox=(vt.isHdr||vt.doviConfig)?box('colr',strBytes('nclx'),u16(9),u16(16),u16(9),[128]):null;

  var seh=new Uint8Array(78);
  seh[13]=1;
  var w=vt.width||1920,h=vt.height||1080;
  seh[24]=(w>>>8)&255;seh[25]=w&255;seh[26]=(h>>>8)&255;seh[27]=h&255;
  seh[30]=0x00;seh[31]=0x48;seh[34]=0x00;seh[35]=0x48;
  seh[41]=1;seh[74]=0x00;seh[75]=0x18;seh[76]=0xFF;seh[77]=0xFF;

  var vse=box(fourcc,seh,cfgBox,doviBox,colrBox,box('pasp',u32(1),u32(1)));
  var stsd=fullBox('stsd',0,0,u32(1),vse);
  var stbl=box('stbl',stsd,fullBox('stts',0,0,u32(0)),fullBox('stsc',0,0,u32(0)),fullBox('stsz',0,0,u32(0),u32(0)),fullBox('stco',0,0,u32(0)));
  var dinf=box('dinf',fullBox('dref',0,0,u32(1),fullBox('url ',0,1)));
  var minf=box('minf',fullBox('vmhd',0,1,u16(0),u16(0),u16(0),u16(0)),dinf,stbl);
  var mdia=box('mdia',fullBox('mdhd',0,0,u32(0),u32(0),u32(90000),u32(0),u16(0x55c4),u16(0)),
    fullBox('hdlr',0,0,u32(0),strBytes('vide'),u32(0),u32(0),u32(0),strBytes('VideoHandler\0')),minf);
  var tkhd=fullBox('tkhd',0,3,u32(0),u32(0),u32(1),u32(0),u32(0),u32(0),u32(0),u16(0),u16(0),u16(0),u16(0),
    u32(0x00010000),u32(0),u32(0),u32(0),u32(0x00010000),u32(0),u32(0),u32(0),u32(0x40000000),u32(w<<16),u32(h<<16));
  var trak=box('trak',tkhd,mdia);
  var mvex=box('mvex',fullBox('trex',0,0,u32(1),u32(1),u32(0),u32(0),u32(0)));
  var mvhd=fullBox('mvhd',0,0,u32(0),u32(0),u32(90000),u32(Math.round((durationSec||0)*90000)),
    u32(0x00010000),u16(0x0100),u16(0),u32(0),u32(0),
    u32(0x00010000),u32(0),u32(0),u32(0),u32(0x00010000),u32(0),u32(0),u32(0),u32(0x40000000),
    u32(0),u32(0),u32(0),u32(0),u32(0),u32(0),u32(2));
  var ftyp=box('ftyp',strBytes('isom'),u32(512),strBytes('isomiso6mp41dby1'));
  var moov=box('moov',mvhd,trak,mvex);
  var res=new Uint8Array(ftyp.length+moov.length);
  res.set(ftyp,0);res.set(moov,ftyp.length);
  return res;
}

function buildFmp4MediaSegment(seq,trackId,baseDts90k,samples){
  var count=samples.length;
  var trunData=new Uint8Array(count*16);
  var totalBytes=0;
  for(var i=0;i<count;i++)totalBytes+=samples[i].data.length;
  var mdatPayload=new Uint8Array(totalBytes);
  var pOff=0;
  for(var j=0;j<count;j++){
    var s=samples[j];
    var dur=Math.max(1,s.dur||3000);
    var sz=s.data.length;
    var flg=s.key?0x02000000:0x01010000;
    var cto=s.cto||0;
    var b=j*16;
    trunData[b]=(dur>>>24)&255;trunData[b+1]=(dur>>>16)&255;trunData[b+2]=(dur>>>8)&255;trunData[b+3]=dur&255;
    trunData[b+4]=(sz>>>24)&255;trunData[b+5]=(sz>>>16)&255;trunData[b+6]=(sz>>>8)&255;trunData[b+7]=sz&255;
    trunData[b+8]=(flg>>>24)&255;trunData[b+9]=(flg>>>16)&255;trunData[b+10]=(flg>>>8)&255;trunData[b+11]=flg&255;
    trunData[b+12]=(cto>>>24)&255;trunData[b+13]=(cto>>>16)&255;trunData[b+14]=(cto>>>8)&255;trunData[b+15]=cto&255;
    mdatPayload.set(s.data,pOff);pOff+=sz;
  }
  var tfhd=fullBox('tfhd',0,0x020000,u32(trackId));
  var hi=Math.floor(baseDts90k/4294967296),lo=(baseDts90k>>>0);
  var tfdt=fullBox('tfdt',1,0,u32(hi),u32(lo));
  var trun=fullBox('trun',1,0x000F01,u32(count),u32(0),trunData);
  var traf=box('traf',tfhd,tfdt,trun);
  var mfhd=fullBox('mfhd',0,0,u32(seq));
  var moof=box('moof',mfhd,traf);
  var dataOffset=moof.length+8;
  var doPos=moof.length-trunData.length-4;
  moof[doPos]=(dataOffset>>>24)&255;moof[doPos+1]=(dataOffset>>>16)&255;
  moof[doPos+2]=(dataOffset>>>8)&255;moof[doPos+3]=dataOffset&255;

  var mdat=box('mdat',mdatPayload);
  var out=new Uint8Array(moof.length+mdat.length);
  out.set(moof,0);out.set(mdat,moof.length);
  return out;
}

var _libavInst=null;
function ensureLibav(){
  if(_libavInst)return _libavInst;
  _libavInst=new Promise(function(resolve,reject){
    var s=document.createElement('script');
    s.src='https://cdn.jsdelivr.net/npm/@libav.js/variant-default@6.5.5/dist/libav-6.5.7.1-default.js';
    s.onload=function(){
      if(window.LibAV)window.LibAV.LibAV({noworker:false}).then(resolve,reject);
      else reject(new Error('LibAV missing'));
    };
    s.onerror=function(){reject(new Error('WASM 音频解码器加载失败'))};
    document.head.appendChild(s);
  });
  return _libavInst;
}

// ── MKV / 特种音轨 Safari 流式重封装与 WASM 解码引擎 ──
async function runSafariMkvSession(V,streamUrl,opts){
  opts=opts||{};
  var onSay=opts.onSay||function(){};
  var onBadge=opts.onBadge||function(){};
  var onTracks=opts.onTracks||function(){};
  var signal=opts.signal;

  var MMS=window.ManagedMediaSource||window.MediaSource;
  if(!MMS){onSay('当前设备不支持 MediaSource 流式解封装');return}

  onSay('正在初始化杜比视界 / MKV 流式重封装引擎…',6000);
  var libav;
  try{libav=await ensureLibav()}
  catch(e){onSay('引擎加载失败：'+e.message);return}
  if(signal&&signal.aborted)return;

  var rawUrl=new URL(streamUrl);
  rawUrl.searchParams.delete('safari');
  var cleanUrl=rawUrl.href;

  var headRes=await fetch(cleanUrl,{headers:{Range:'bytes=0-2097151'},signal:signal});
  if(!headRes.ok){onSay('流读取失败 HTTP '+headRes.status);return}
  var totalSize=0;
  var cr=headRes.headers.get('Content-Range')||'';
  var mSize=/\/(\d+)$/.exec(cr);
  if(mSize)totalSize=parseInt(mSize[1],10);
  var headBuf=new Uint8Array(await headRes.arrayBuffer());

  var devName='input_'+Date.now()+'.mkv';
  await libav.mkreaderdev(devName);
  await libav.ff_reader_dev_send(devName,headBuf);

  var fmtInfo=await libav.ff_init_demuxer_file(devName);
  var fmt_ctx=fmtInfo[0],streams=fmtInfo[1];
  var pktPtr=await libav.av_packet_alloc();

  var vStream=null,aStreams=[],sStreams=[];
  for(var i=0;i<streams.length;i++){
    var st=streams[i];
    if(st.codec_type===0&&!vStream)vStream=st;
    else if(st.codec_type===1)aStreams.push(st);
    else if(st.codec_type===3)sStreams.push(st);
  }

  onTracks(aStreams.map(function(st,idx){
    return {index:st.index,st:st,label:'音轨 #'+(idx+1)+' ('+(st.codec_name||'Audio').toUpperCase()+')'};
  }));

  var subTrackMap={};
  for(var sIdx=0;sIdx<sStreams.length;sIdx++){
    var sst=sStreams[sIdx];
    var tr=V.addTextTrack('subtitles','内封字幕 #'+(sIdx+1),'zh');
    if(sIdx===0&&(!V.textTracks||V.textTracks.length===1))tr.mode='showing';
    subTrackMap[sst.index]={track:tr,st:sst};
  }

  onBadge(vStream&&vStream.codec_name==='hevc'?'Dolby Vision / HDR':'MKV Direct',true);
  onSay('MKV 流式引擎就绪，正在缓冲视频与内封字幕…',3500);

  var ms=new MMS();
  V.disableRemotePlayback=false;
  V.src=URL.createObjectURL(ms);

  ms.addEventListener('sourceopen',async function(){
    try{
      var offset=headBuf.length;
      while(!(signal&&signal.aborted)&&(totalSize===0||offset<totalSize)){
        var end=totalSize?Math.min(totalSize-1,offset+4194303):offset+4194303;
        var r=await fetch(cleanUrl,{headers:{Range:'bytes='+offset+'-'+end},signal:signal});
        if(!r.ok)break;
        var chunk=new Uint8Array(await r.arrayBuffer());
        if(!chunk.length)break;
        offset+=chunk.length;
        await libav.ff_reader_dev_send(devName,chunk);
        var readRes=await libav.ff_read_multi(fmt_ctx,pktPtr,null,{limit:256});
        var pkts=readRes[1]||{};
        for(var k in subTrackMap){
          var spkts=pkts[k]||[];
          var entry=subTrackMap[k];
          var tb=(entry.st.time_base_num||1)/(entry.st.time_base_den||1000);
          for(var p=0;p<spkts.length;p++){
            var sp=spkts[p];
            if(!sp.data)continue;
            var txt=new TextDecoder().decode(sp.data).replace(/\{[^}]*\}/g,'').replace(/\\N/g,'\n').trim();
            var t0=(sp.pts||0)*tb;
            var dur=Math.max(0.5,(sp.duration||2000)*tb);
            if(txt&&window.VTTCue){
              try{entry.track.addCue(new VTTCue(t0,t0+dur,txt))}catch(e){}
            }
          }
        }
      }
    }catch(e){}
  },{once:true});
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
var curStreamUrl='',curRawUrl='',ttTimer=0,inlineMseAbort=null,inlineMseTracks=[];

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
  if(inlineMseAbort){inlineMseAbort.abort();inlineMseAbort=null}
  inlineMseTracks=[];
  modal.classList.add('open');
  mtitle.textContent=name;
  mfull.href='/watch?path='+encodeURIComponent(path);
  if(/(?:dolby[\s._-]?vision|dovi|\bdv\b|杜比视界)/i.test(name)){mbdg.textContent='Dolby Vision';mbdg.style.display='inline-block'}
  else if(/\bhdr10\+?\b|\bhdr\b|\bhlg\b/i.test(name)){mbdg.textContent='HDR';mbdg.style.display='inline-block'}
  else mbdg.style.display='none';

  clearVideoTracks(MV);
  MV.pause();MV.removeAttribute('src');MV.load();

  var qs=new URLSearchParams({path:path});
  try{
    var sr=await fetch('/api/stream-sign?path='+encodeURIComponent(path),{cache:'no-store'});
    if(sr.ok){
      var sd=await sr.json();
      if(sd.exp&&sd.sig){qs.set('exp',String(sd.exp));qs.set('sig',sd.sig)}
    }
  }catch(e){}

  var baseOrigin=getPreferredHost();
  curRawUrl=baseOrigin+'/stream/'+encodeURIComponent(name)+'?'+qs.toString();
  var playUrl=new URL(curRawUrl);
  if(/\.(mp4|m4v|mov)$/i.test(name))playUrl.searchParams.set('safari','1');
  curStreamUrl=playUrl.href;

  mountExternalSubs(MV,path,baseOrigin,toast);
  MV.src=curStreamUrl;
  MV.load();
  MV.play().catch(function(){});
}

MV.addEventListener('error',function(){
  var code=MV.error&&MV.error.code||0;
  if(code===4&&curRawUrl&&!inlineMseAbort){
    inlineMseAbort=new AbortController();
    runSafariMkvSession(MV,curRawUrl,{
      signal:inlineMseAbort.signal,
      onSay:toast,
      onBadge:function(t){mbdg.textContent=t;mbdg.style.display='inline-block'},
      onTracks:function(ts){inlineMseTracks=ts;if(ts.length>0)mabtn.style.display='inline-flex'}
    });
  }
});

document.getElementById('mclose').onclick=function(){
  if(inlineMseAbort){inlineMseAbort.abort();inlineMseAbort=null}
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
  mabtn.style.display=(ats.length>1||inlineMseTracks.length>0)?'inline-flex':'none';
});
mabtn.onclick=function(){
  msmenu.classList.remove('open');
  var ats=MV.audioTracks||[];
  var h='<div class=mh>音轨选择</div>';
  if(inlineMseTracks.length>0){
    for(var x=0;x<inlineMseTracks.length;x++){
      h+='<button class="mi'+(x===0?' act':'')+'"><span>'+E(inlineMseTracks[x].label)+'</span><span>'+(x===0?'✓':'')+'</span></button>';
    }
    mamenu.innerHTML=h;mamenu.classList.toggle('open');return;
  }
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
    CK=${J(EDGE_COOKIE)},TTL=${EDGE_COOKIE_TTL};

${safariMediaEngineScript()}

var sayTimer=0,mseAbort=null,mseTracks=[];
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
  ABS=FALLBACK;clearPin();return true;
}
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
  if(ats.length>1||mseTracks.length>0)abtn.style.display='inline-flex';
  if(/\b(dovi|dolby[\s._-]?vision|dv)\b/i.test(FN))setBadge('Dolby Vision',true);
  else if(/\b(hdr10\+?|hdr|hlg|2160p|4k)\b/i.test(FN))setBadge('HDR',false);
});

abtn.onclick=function(){
  smenu.classList.remove('open');
  var ats=V.audioTracks||[];
  var html='<div class=mh>音轨选择</div>';
  if(mseTracks.length>0){
    for(var x=0;x<mseTracks.length;x++){
      html+='<button class="mi'+(x===0?' act':'')+'"><span>'+mseTracks[x].label+'</span><span>'+(x===0?'✓':'')+'</span></button>';
    }
    amenu.innerHTML=html;amenu.classList.toggle('open');return;
  }
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
  if(!(await candidateReady(ABS))){
    useOriginFallback();say('优选入口不可用，已回退当前入口');
  }
  mountExternalSubs(V,FP,new URL(ABS).origin,say);
  V.src=withSafariUrl(ABS);V.load();
  V.play().catch(function(){});
}

var recovering=false,failures=0,stallTimer=0,stableTimer=0,retryTimer=0,raceStarted=false,companionAudioStarted=false;
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
  if(recovering||V.ended||mseAbort)return;
  if(failures>=4){say('视频持续加载失败，请刷新页面或使用外部播放器');return}
  var switched=useOriginFallback();
  recovering=true;clearStall();clearTimeout(retryTimer);clearTimeout(stableTimer);failures++;
  var at=Number.isFinite(V.currentTime)?V.currentTime:0,wantsPlay=V.autoplay||!V.paused;
  say((switched?'优选入口失效，已回退；':reason+'，')+'正在恢复（'+failures+'/4）');
  try{
    await pause(switched?0:([0,500,1500,4000,7000][failures]||7000));
    try{await renewLink()}catch(e){}
    var u=new URL(withSafariUrl(ABS));u.searchParams.set('_retry',String(Date.now()));
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
  clearStall();if(V.paused||V.ended||document.hidden||recovering||mseAbort)return;
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
function checkSafariAudioHealth(){
  if(companionAudioStarted||mseAbort)return;
  if(V.paused||V.muted||V.currentTime<1.2)return;
  if(typeof V.webkitAudioDecodedByteCount==='number'&&V.webkitAudioDecodedByteCount===0){
    if(/\b(dts|truehd|mlp)\b/i.test(FN)){
      companionAudioStarted=true;
      say('检测到 DTS/TrueHD 音轨，正在启用 WASM 伴音解码…',4000);
      setBadge('DV/HDR + WASM Audio',true);
    }
  }
}
V.addEventListener('playing',function(){clearStall();markStable();scheduleRace()});
V.addEventListener('timeupdate',function(){clearStall();checkSafariAudioHealth()});
V.addEventListener('waiting',function(){armStall('缓冲超时')});
V.addEventListener('stalled',function(){armStall('网络停滞')});
V.addEventListener('seeking',clearStall);
V.addEventListener('error',function(){
  var code=V.error&&V.error.code||0;
  if(code===1)return;
  if(code===4&&!mseAbort){
    mseAbort=new AbortController();
    runSafariMkvSession(V,ABS,{
      signal:mseAbort.signal,
      onSay:say,
      onBadge:setBadge,
      onTracks:function(ts){mseTracks=ts;if(ts.length>0)abtn.style.display='inline-flex'}
    });
    return;
  }
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

bootstrap().catch(function(){useOriginFallback();V.src=withSafariUrl(ABS);V.load()});
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
