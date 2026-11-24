/**
 * Cuven 请求添加 Worker（tj.cuven.us）v2.7
 *
 * v2.7：稳定性 / 性能（用户要求：加强请求添加流程里每个 Worker 的稳定性、性能）。只改这个 Worker，接口和 D1 的表都兼容 2.6
 *   · 清洗（电影文件夹）：原因 = 挑中的视频挪进 /auto 以后才记下 r.d.file，读回来 / 删原文件夹那一下被掐（预算、PikPak 抖了），
 *     下一轮去原文件夹里找 →「文件夹里没有视频」→ 换规格，挪出来的视频留在 /auto 没人管；删原文件夹失败（连预算用完）也被吞掉。
 *     改成挪之前先记下 r.d.file = 视频、r.d.junk = 原文件夹，后面照单个文件那条路走（可重入）；删原文件夹、drop() 删任务 / 文件
 *     遇到预算、熔断、暂时性错误都往上抛（下一轮再删），drop() 的「放弃」日志挪到删完以后（重试不重复记）
 *   · 有人跟上一部正在推进的：原因 = 跟上的那条 UPDATE 带 rev + 1，这一轮推进完的那条（已经挪了文件、开了传输）存不进去，
 *     下一轮重做一遍（换规格、开第二个 rclone 作业）。改成跟上不动 rev（只改 users / updated），定时任务存的时候也不写 users
 *   · 一轮的租约：原因 = 租约 55 秒、从不释放，一轮可以跑到 80 秒以上（一个传输调用最长 60 秒），下一分钟的定时任务拿到租约、
 *     同一条推进两次；面板「立即跑一轮」根本不拿租约。改成租约带主人、跑完就还（120 秒兜底），面板也要拿（拿不到回 busy）；
 *     一轮有截止时刻（95 秒）：时间不够一个完整调用的有副作用的调用（开传输、改名、推送、挪 / 删文件）这一轮不发，只读的调用缩短超时
 *   · flush()：原因 = 先清空写入缓冲再写 D1，那一批写失败了，这几条的进度（已经开的作业、挪过的文件）就丢了。改成写失败放回去、
 *     收尾时再写一次（rev 挡住已经写进去的那条）
 *   · 批量传输：传输 Worker 910 回 { jobid: 0, reused, running: 1 }（这一组在跑、作业号没找到）不再当出错（以前每 70 秒重问一次、
 *     一天后退回单个传输，和还在跑的批量作业一起传）：记成「传输中（作业号未知）」，5 分钟再接一次作业号
 *   · 批量进度只往前走：重开以后 rclone 新的一组从 0 算起，成员和 /app/flow 的进度会从 60% 跳回 5%；记下最大值（pmax）
 *   · D1 读的行数：/app/requests 每次把整张 tj_req 读一遍（json_each 挡住了索引）、libNudge 每轮读全部 done 的行。
 *     加索引 tj_req_stnext(stage, next)，/app/requests 改成进行中的 + 30 天内结束的两段（都走 stage 索引），面板也不再整张表排序
 *   · /app/requests 的 ETag：原因 = 每次存都把 updated 改成现在，等着的那几条（下载中、排队、等凑批、批量成员）几分钟一变。
 *     改成 App 看得到的（阶段、百分比、片名、批次）变了才动 updated
 *   · /app/flow 的实时进度：先盖戳再问（5 秒里别的人直接用上一份），超时 8 秒（以前 60 秒，App 跟着等）
 *   · 追踪（trackHomes）：原因 = 每次都挑最新的 40 条，还在 /auto 的不写，下一次又是这 40 条，更早的从来轮不到。改成按编号往后翻（游标）
 *   · 改名：传输 Worker 910 回 done: 1（上一次已经改完）不再当作业去问，直接往下走
 *
 * v2.6：请求中心批量提交、凑满一批一起传（用户要求：请求添加先放进请求中心，最多 50 部电影 / 剧集的一季，按「确认」一次提交；
 *       至少 16 部下完、清洗好了再一起传，16 路并行传输、16 路并发核对，效率最高；电影照旧在 /auto，剧集放进 /auto/ram2）
 *   · POST /app/requests/batch：一次提交整个请求篮，一组 SQL 做完（json_each），不一条一条问影片库（版本留给 ① 去问）；
 *     每条回 created / joined / failedRecently / limit / invalid。同一次提交的记同一个 bid
 *   · 新的一步 ready（等待凑批；App 上还是 STEP 4「等待传输」）：清洗 / 改名好的先在这儿加追踪码（同一个文件夹一轮只列一次），
 *     然后停着等，不用每轮都排上。凑够 16 部（面板里调）→ 一个 rclone 作业一起传（传输 Worker 的 /api/link/batch-copy，
 *     Transfers 16 / Checkers 16，作业的 key 是批次编号：开的时候超时了，下一轮再开也不会开出两个）。一次只跑一批，多的凑下一批
 *   · 凑不满也不干等：最早的一部等了 30 分钟（老版本 App 一部一部提交的 10 分钟）、前面没有还能清洗好的了、
 *     这一次提交的都清洗好了 → 有几部传几部。VPS 熔断中不开批；单个传输还在跑也先等它传完（rclone 内存）
 *   · 一批一个作业：每轮只问一次作业进度，成员的百分比一条 SQL 一起改；传完一次核对一批（batch-verify）、
 *     一次删 8 个 PikPak（batch-purge）+ 一次删云下载任务、一次问片库；对不上的等这一批传完再一个一个补传（原来那条路）
 *   · 剧集放进 /auto/ram2（面板里可改）：推送、按名字找、加追踪码都在那个文件夹里，传输 Worker 的每个调用都带 sub，
 *     发行检查把剧集的名字放在 tv 里一起问。传输 Worker 是老版本（909，ping 里没有 sub / batch）就照旧放 /auto、一个一个传，
 *     试列时发现 rclone 不认筛选规则（409 nofilter）也退回一个一个传
 *   · GET /app/flow：凑批进度和正在传的那一批（字节、速度、剩余时间、我的是哪几部），给请求中心的动画和进度条；带 ETag，
 *     只有汇总、不带别人的片名；正在传的时候问一次实时进度（缓存 5 秒，VPS 熔断中不问）
 *   · 批量里取消一部：这一批照常跑完，传完那一部不核对、不删，日志写清楚它传到 Dropbox 的那份留在原处
 *   · 一次只跑一批，库里也挡住：在 copy 的批次单独查（收尾中的批次再多也挤不掉正在传的那一批），开批的那条 INSERT 带
 *     NOT EXISTS（面板「推进一轮」不拿租约，撞上定时任务也开不出第二批）；库里万一已经有两批在 copy，后面那批的成员一直停着，
 *     前面那批传完、下一轮才开它的作业，这期间不凑新的一批、不开单个传输
 *   · 凑批、/app/flow 按 stage 查的走新索引 tj_req_stage（tj_req 不删旧的，以前每轮把整张表读两遍）；
 *     tick:last 多一项 over = 这一轮有几个子请求被预算挡回去（面板「系统」卡里写着）
 *   · 限额改大：每个用户 50（最多 100）、全部 200（最多 1000）；PikPak 同时云下载默认 16（凑得满 16 部）
 *   · 配合传输 Worker 910（sub / batch-copy / batch-verify / batch-purge）、Stream v25.4（认 /auto/ram2）
 *
 * v2.5：追踪码优先（用户要求：优先识别 auto 的唯一 TMDB 码，快速核对、正确添加影片和剧集）
 *   · 新请求先核对片库：片库里已经有带这个 TMDB 编号（剧集再加季）追踪码的那一部（以前的请求加的，在 /auto 或已经挪进
 *     ram / ram2），就不再下载，直接就绪「片库里已有」——问一次片库（/api/auto/sync?tmdb=m550 / tv1399s2），零 PikPak、零 VPS
 *   · 问不成（片库连不上、老版本）就照常下，不耽误
 *   · 配合 Stream v25.3（按 TMDB 编号找）、索引库 v7.1（追踪码直接判「库中已有」）
 *
 * v2.4：文件抵达 /auto 自动通过最终审核（用户要求：当文件抵达 auto 自动通过最终审核，使影片可以播放）
 *   · 两端核对一致、PikPak 那份删了 = 抵达 /auto：当场通过最终审核，App 上 100%、「立即播放」、「已就绪」通知；
 *     不再进「最终发行审批」等人，也不再像 2.2 那样等片库收录了才算（最多等 15 分钟）
 *   · 通过的同时请片库马上收录（/api/auto/sync）。片库还没收录的，之后每分钟催一次（前 15 次，之后每 30 分钟，最多一天），
 *     收录了就停；App 里按「立即播放」时也会再催片库一次
 *   · 以前停在「最终发行审批」的（升级之前进来的、片库那时还是老版本的）下一轮直接通过
 *   · 片库不收录 /auto（老版本 / 关了）照样通过，日志写清楚要等工作人员挪进片库才能播放
 *   · 控制面板「设置」里可以关掉（关了就照旧等工作人员发行）
 *
 * v2.3：名字里带追踪码，传完以后也能一直追踪（用户要求：在文件和文件夹名中带上 auto-TMDB唯一码-内部代码）
 *   · 开始传 Dropbox 之前，在 PikPak 上把电影文件 / 剧集文件夹改个名，带上追踪码：
 *       电影  Fight.Club.1999.1080p.[auto-m550-r13].mkv
 *       剧集  Game.of.Thrones.S02.1080p.[Full-4]-Cuven®.[auto-tv1399s2-r14]
 *     m / tv + TMDB 编号（电影和剧集的编号会重复，所以带类型；剧集再带季），最后是 r + 这条请求的编号（面板里的 #13；
 *     带个 r 是免得 2001 这种编号被当成年份）
 *   · 片库（Stream Worker v25.2）认得追踪码：直接按 TMDB 编号认片（不靠文件名猜），App 对得准
 *   · 问片库收录了没有时连追踪码一起问：在 /auto 里、已经被挪进 ram / ram2，都认得出来
 *   · 就绪以后接着追踪（30 分钟一轮，最多 30 天）：工作人员挪去哪儿了，面板和日志里写清楚；
 *     找了 3 小时都找不到（改了名、删了）才停
 *   · App 里「继续观看」和片单也按追踪码跟着走：工作人员挪了位置，进度不丢
 *   · 控制面板「设置」里可以关掉（关了就照原名传）；改名失败（没填 PikPak、找不到、PikPak 拒绝）就照原名传，不耽误
 *
 * v2.2：传到 Dropbox 的 /auto 就立即可用（用户要求：在 auto 文件夹时就立即可用）
 *   · 两端核对一致、删掉 PikPak 那份以后，请片库（Stream Worker v25.1 起的 /api/auto/sync）马上重看一眼 /auto；
 *     片库回「收录了」就直接算就绪：App 上 100%、按钮变「立即播放」、发「已就绪」通知，不再等工作人员挪进 ram / ram2
 *   · 片库还没收录（Dropbox 的列表慢几秒）：每分钟再问，15 分钟还不行就转去「最终发行审批」照旧等；那期间片库收录了一样算就绪
 *   · 片库是老版本（没有这个接口）或关了 AUTO_FOLDER：照旧等工作人员发行，什么都不坏
 *   · 一轮里要问的一次问完（?item=…&item=…）；控制面板「设置」里可以关掉（关了就是 v2.1 的样子）
 *
 * v2.1：修「经常两端核对不一致、重新传输」
 *   · 列目录失败 = 没核对成（暂时性错误，过会儿再核对），不再当「不一致」整个重传
 *   · 传完等 45 秒再核对；第一次不一致隔 2 分钟再核对一次，还不一致才补传
 *   · 补传只传缺的 / 大小不对的；第二次起改从 PikPak 原生接口拿、只按大小判断；补传 3 次还不行才停下，写清楚缺了哪些
 *   · 配合传输 Worker 909：逐个文件核对（源头用原生 pikpak 后端，NFC + 不分大小写，系统 / 临时文件不算，Dropbox 多出来的不算）
 *
 * v2.0：核心重做——稳、省、不堵
 *   · 熔断：影片库 / VPS / PikPak / TMDB 各自记健康，连续 3 次暂时性失败就熔断 2→4→8→15 分钟，要用它的请求原地等，
 *     不算出错、不换规格；到期放一次试探，通了就恢复（面板「系统」里看得到）
 *   · 智能队列：先把开了头的做完（发行检查 > 删除 > 核对 > 传输 > 改名 / 清洗 > 云下载 > 排队），排队中的每个人的第一个先上，
 *     好几个人在等的优先；PikPak 同时云下载、VPS 同时传输各有资源位（面板里调），满了排队，不会把 rclone 压垮
 *   · 批量：一轮里要问的 rclone 作业一次问完（/api/link/jobs），发行检查列一次目录（/api/link/exists {items}）
 *   · 看门狗：传输一小时 / 改名半小时没有新字节就停掉重开（copy 跳过已传完的）；VPS 重启丢了作业就从断点重开；
 *     依赖一天都连不上才停下等人
 *   · 状态只许按流程走（FLOW），每一步可重入；一轮的写入（请求 + 日志）攒起来一个事务写进 D1
 *   · /app/requests 带 ETag，App 轮询没变化时回 304
 *   要配合传输 Worker 908（52x 自动重试、批量接口）；老版本也能跑，只是退回一个一个问。
 *
 * v1.2：App 上的五步改成 等待制片商 → 等待回应 → 等待品质管理 → 等待传输 → 最终发行审批；给 App 的进度不再带内部说明
 *       （note / 规格 / 试过几个），只有控制面板看得到。
 * v1.1：D1 的表名都带 tj_ 前缀（tj_req / tj_kv / tj_log）。库和别的 Worker 共用、里面已经有叫 kv 的表时，
 *       v1.0 报 no such column: exp。建表后再对一遍列，缺的补上。
 *
 * App 里点「请求添加」→ 这里排队 → 每分钟的定时任务一步一步往前推：
 *
 *   ① 已请求    queued    问影片库（lb.cuven.us）这部片 / 这一季按规格排好的全部版本，取没试过的第一个，
 *                         让影片库把它推进 PikPak 的 /auto（影片库用它自己配的 PikPak 账号建云下载任务）
 *   ② 待传输    download  盯 PikPak 云下载任务到 100%。出错 / 2 小时没进度 / 12 小时没下完 → 删掉任务和文件，回到 ①
 *                         推下一个规格
 *   ③ 预处理中  clean     电影：文件夹里体积最大的视频移到 /auto，原文件夹进回收站（单文件直接用）
 *               check     剧集：传输 Worker 整理文件夹（删广告垃圾）→ 核对整季是否完整（总集数取标题里写的，
 *                         没写就按 TMDB 已播出的集数）→ 不完整 → 回到 ① 降档重试
 *               rename    剧集：传输 Worker 按发行命名改文件夹名（等 rclone 的任务跑完）
 *                         （2.6 起剧集推进、整理、改名都在 /auto/ram2 里，传 Dropbox 也传到 dropbox:auto/ram2）
 *   ④ 正在传输  ready     （2.6）加上追踪码，等凑够一批（默认 16 部）一起传；关了批量传输就直接 copy
 *               copy      VPS 上的 rclone：webdav:auto/<名字> → dropbox:auto/<名字>（先 copy；2.6 起一批一个作业）
 *               verify    两端核对（文件数 + 字节数），对不上重新 copy（最多 3 次）
 *               purge     核对一致才删 PikPak 那份
 *               （v2.4）删完 = 文件抵达 /auto：自动通过最终审核 → 完成（同时请片库收录，没收录的接着催）
 *   ⑤ 等待工作人员的最终发行  release  只有面板里关了「自动通过」才到这一步：每 5 分钟看一眼 dropbox:auto/<名字> 还在不在
 *                         （人工挪去 ram / ram2 之后就不在了）
 *   完成        done      可以播放了（在 /auto 里，或者已经发行）
 *
 * App 轮询 /app/requests 显示进度（STEP X OF 5、百分比），状态一变就发本地通知。
 *
 * 绑定 / 变量（Cloudflare 面板 → Worker → 设置）：
 *   DB             D1 数据库（表自己建，不用跑迁移；表名带 tj_ 前缀，可以和别的 Worker 共用一个库）
 *   ADMIN_KEY      控制面板口令（密钥）。PikPak 密码用它派生的密钥加密后存进 D1，换口令要重新填一次 PikPak 密码
 *   LB_GATE        影片库 Worker 的 GATE 口令（密钥）
 *   LINK_KEY       传输 Worker 的 LINK_KEY（密钥）
 *   LB_BASE        默认 https://lb.cuven.us
 *   TRANSFER_BASE  默认 https://transfer.cuven.us
 *   STREAM_BASE    默认 https://stream.cuven.online（TMDB 分季集数；v2.2 起也用它的 /api/auto/sync 让片库收录 /auto）
 *   STREAM_SYNC_KEY  可选（密钥）：Stream Worker 配了 AUTO_SYNC_KEY 时填同一个
 *   ACCOUNT_BASE   默认 https://check.cuven.us（App 用户名核对：请求要带真实存在的用户名）
 *   AUTO_DIR       默认 auto
 *   定时触发器      * * * * *（每分钟）
 * PikPak 账号和密码在控制面板（https://tj.cuven.us/）里填：清洗（盯任务、移动、删文件夹）用它。
 * 它必须和影片库 Worker 配的 PIKPAK_USER 是同一个账号 —— 影片库推进哪个网盘，这里就去哪个网盘清洗。
 *
 * App 接口（不需要口令；请求类的要带 x-cuven-user: <用户名>）：
 *   GET  /app/catalog?src=movie|tv|all&q=&page=&sort=new|vote|hot|spec&own=all|hide&min=&year=
 *        索引里的全部已知影片 / 剧集（TMDB 编号），带上这部片的请求进度
 *   GET  /app/detail?src=movie|tv&id=<TMDB>&season=
 *        有没有可请求的资源（几个版本、最好的规格），这部 / 每一季的请求进度
 *   GET  /app/requests                 我的请求（进行中的 + 30 天内结束的）
 *   POST /app/requests { src, id, season }   请求添加（同一部 / 同一季已经有人在请求就跟上，不重复下）
 *   POST /app/requests/batch { items: [{ src, id, season, title?, year?, poster? }] }   （2.6）请求中心一次提交（最多 50 条）
 *   GET  /app/flow                     （2.6）凑批进度和正在传的那一批（请求中心的动画和进度条）
 *
 * 控制面板接口（x-admin-key: ADMIN_KEY）：/admin/api/state · cfg · pk · links · req · add · tick
 */

const VER = 'tj 2.7';
const MIN = 60000, HOUR = 3600000, DAY = 86400000;
const LIMIT = {
  userActive: 50,         // 一个用户同时进行中的请求（2.6：请求中心一次能提交 50 部）
  globalActive: 200,      // 全部进行中的请求
  perTick: 24,            // 一轮最多推进几条（轮询类的步骤批量问，便宜）
  tickMs: 22000,          // 一轮的时间预算（过了就不再开始推进新的一条）
  tickEnd: 95000,         // 一轮的截止时刻（2.7）：过了这个点不再发外部调用；有副作用的调用要剩得下一个完整的超时才发
  tickLease: 120000,      // 一轮的租约（2.7）：跑完就还，这个只是 Worker 被掐死、没来得及还的兜底（比截止时刻长）
  minCall: 5000,          // 只读的调用最少要剩这么久（2.7）
  fetches: 42,            // 一轮的子请求预算（免费计划 50）
  dlStall: 2 * HOUR,      // 云下载这么久没进度就换规格
  dlMax: 12 * HOUR,       // 云下载最长等多久
  busyMax: 30 * MIN,      // 剧集文件夹里一直有没下完的分段文件
  copyTries: 3,           // 传输作业失败 / 卡住最多重来几次
  recopyMax: 3,           // 核对不一致最多补传几次
  verifySettle: 45000,    // 传完等这么久再核对（两边的目录列表刷新一下）
  verifyRecheck: 2 * MIN, // 第一次核对不一致：隔这么久再核对一次，还不一致才补传
  copyStall: HOUR,        // 传输这么久没有新字节：停掉重开
  renameStall: 30 * MIN,  // 改名这么久没有进展：停掉重来
  lostMax: 5,             // rclone 作业丢了（VPS 重启）最多重开几次
  depGiveUp: DAY,         // 依赖一直连不上多久就停下等人
  stepErrors: 20,         // 同一步连续出错这么多次就停下来等人看
  releasePoll: 5 * MIN,
  autoPoll: MIN,          // 自动通过最终审核以后片库还没收录：隔多久催一次
  trackEvery: 30 * MIN,   // 就绪以后追踪追踪码：多久看一次
  trackDays: 30 * DAY,    // 最多追多久
  trackLost: 6,           // 连着这么多次哪儿都找不到（改了名 / 删了）就不追了
  refail: DAY,            // 失败后多久用户可以重新请求
  /* 批量（2.6） */
  basketMax: 50,          // 请求中心一次最多提交几条
  batchMax: 16,           // 一批最多几部（rclone 一个作业）
  readyPark: 10 * MIN,    // 等待凑批的：多久自己醒一次（平时凑批那一步一起挑，不用每轮都排上）
  memberPark: 15 * MIN,   // 批量传输里的成员：进度由批次一起改，不用每轮都排上
  stuck: 10 * MIN,        // 前面的（下载 / 清洗中）退避这么久以上 = 一时半会儿清洗不好，凑批不等它
  oldWait: 10 * MIN,      // 老版本 App 一部一部提交的（bid = 0）最多等多久凑批
  capsEvery: 30 * MIN,    // 多久重新问一次传输 Worker 会什么（ping 的 caps）
  flowLive: 5000,         // /app/flow 的实时作业进度缓存多久
  flowLiveMs: 8000,       // /app/flow 问实时进度最多等多久（2.7；以前跟着传输调用的 60 秒，App 的请求也跟着挂着）
  jobless: 5 * MIN,       // 批量作业在跑、作业号没找到（910 的 running: 1）：多久再接一次作业号（2.7）
  trackBatch: 40,         // 追踪一轮最多问几条（2.7 起按编号往后翻）
};
const ACTIVE = ['queued', 'download', 'clean', 'check', 'rename', 'ready', 'copy', 'verify', 'purge', 'release'];
const ENDED = ['done', 'failed', 'cancelled'];
/** 按 stage 查的 SQL 片段（2.7）：写成 stage IN (…)（常量，不占绑定参数）才走得上 stage 的索引；
    stage NOT IN (…) 用不上索引，整张表读一遍（tj_req 不删旧的）。CAPPED = 算进限额的（等发行的不算）。
    每轮 / App 每次轮询都跑的几条还写了 INDEXED BY：库里有了统计（有人跑过 PRAGMA optimize / ANALYZE）以后，SQLite 只知道
    stage 平均每个值几行、不知道进行中的只占一小撮，会改走 tj_req_next（next <= 现在：全部历史的 next 都是 0）或者整张表扫一遍 */
const inList = (xs) => 'stage IN (' + xs.map(s => "'" + s + "'").join(',') + ')';
const ACTIVE_SQL = inList(ACTIVE), ENDED_SQL = inList(ENDED), CAPPED_SQL = inList(ACTIVE.filter(s => s !== 'release'));
/** 还在下载 / 清洗的（凑批时「前面还有没有能清洗好的」） */
const UPSTREAM = ['queued', 'download', 'clean', 'check', 'rename'];
const STEP_OF = { queued: 1, download: 2, clean: 3, check: 3, rename: 3, ready: 4, copy: 4, verify: 4, purge: 4, release: 5, done: 5 };
/* App 上给用户看的五步（用户定的说法）。内部在做什么（推到 PikPak、清洗、传 Dropbox…）只在控制面板里看得到 */
const STEP_LABELS = ['等待制片商', '等待回应', '等待品质管理', '等待传输', '最终发行审批'];
const STAGE_TEXT = {
  queued: '排队，准备推送到 PikPak', download: 'PikPak 云下载中', clean: '清洗文件夹', check: '整理并核对整季',
  rename: '按发行命名', ready: '等待凑批传输', copy: '传输到 Dropbox', verify: '核对两端', purge: '清理 PikPak', release: '等待工作人员发行',
  done: '已发行', failed: '失败', cancelled: '已取消',
};
const VIDEO_RE = /\.(mkv|mp4|m4v|ts|m2ts|mts|avi|mov|wmv|flv|webm|rmvb|iso)$/i;
const SAMPLE_RE = /(^|[.\s_\-\[(])(sample|trailer|预告|花絮)([.\s_\-\])]|$)/i;

const base = (env, k, d) => String(env[k] || d).replace(/\/+$/, '');
const now = () => Date.now();
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const json = (o, status = 200, h = {}) => new Response(JSON.stringify(o), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...h } });
const err = (msg, extra) => Object.assign(new Error(msg), extra || {});
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

/* ══════════════════════════════════════════════════════════════════
   D1
   ══════════════════════════════════════════════════════════════════ */
/* 表名都带 tj_ 前缀：D1 库可能和别的 Worker 共用，里面已经有 kv / log / req 这种常见名字的表
   （用户实测：库里原来就有一张没有 exp 列的 kv，CREATE TABLE IF NOT EXISTS 跳过了它，查询报 no such column: exp）。
   建表之后再对一遍列：缺的列补上（以后加列也走这里），不碰别人的表。 */
const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS tj_req (
     id INTEGER PRIMARY KEY AUTOINCREMENT, src TEXT NOT NULL, tmdb INTEGER NOT NULL, season INTEGER NOT NULL DEFAULT 0,
     title TEXT, year TEXT, poster TEXT, users TEXT NOT NULL DEFAULT '[]', stage TEXT NOT NULL, pct REAL NOT NULL DEFAULT 0,
     note TEXT, data TEXT NOT NULL DEFAULT '{}', created INTEGER, updated INTEGER, since INTEGER,
     next INTEGER NOT NULL DEFAULT 0, rev INTEGER NOT NULL DEFAULT 0, bid INTEGER NOT NULL DEFAULT 0, bat INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS tj_kv (k TEXT PRIMARY KEY, v TEXT, exp INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS tj_log (id INTEGER PRIMARY KEY AUTOINCREMENT, rid INTEGER, at INTEGER, msg TEXT)`,
  /* 2.6 批量传输：一批一行。items = 成员（rid、名字、类型、sub），data = 作业号、进度、看门狗；ended > 0 = 收尾了 */
  `CREATE TABLE IF NOT EXISTS tj_batch (id INTEGER PRIMARY KEY AUTOINCREMENT, stage TEXT NOT NULL DEFAULT 'copy',
     items TEXT NOT NULL DEFAULT '[]', data TEXT NOT NULL DEFAULT '{}', created INTEGER, updated INTEGER,
     ended INTEGER NOT NULL DEFAULT 0, rev INTEGER NOT NULL DEFAULT 0)`,
];
/** 每张表应该有的列（补列用：ALTER TABLE ADD COLUMN 加不了主键，主键列只能建表时有） */
const COLUMNS = {
  tj_req: [['src', "TEXT NOT NULL DEFAULT ''"], ['tmdb', 'INTEGER NOT NULL DEFAULT 0'], ['season', 'INTEGER NOT NULL DEFAULT 0'],
           ['title', 'TEXT'], ['year', 'TEXT'], ['poster', 'TEXT'], ['users', "TEXT NOT NULL DEFAULT '[]'"],
           ['stage', "TEXT NOT NULL DEFAULT 'queued'"], ['pct', 'REAL NOT NULL DEFAULT 0'], ['note', 'TEXT'],
           ['data', "TEXT NOT NULL DEFAULT '{}'"], ['created', 'INTEGER'], ['updated', 'INTEGER'], ['since', 'INTEGER'],
           ['next', 'INTEGER NOT NULL DEFAULT 0'], ['rev', 'INTEGER NOT NULL DEFAULT 0'],
           /* 2.6：bid = 请求中心同一次提交的（0 = 老版本 App 一部一部提交的），bat = 在哪一批批量传输里 */
           ['bid', 'INTEGER NOT NULL DEFAULT 0'], ['bat', 'INTEGER NOT NULL DEFAULT 0']],
  tj_kv: [['v', 'TEXT'], ['exp', 'INTEGER NOT NULL DEFAULT 0']],
  tj_log: [['rid', 'INTEGER'], ['at', 'INTEGER'], ['msg', 'TEXT']],
  tj_batch: [['stage', "TEXT NOT NULL DEFAULT 'copy'"], ['items', "TEXT NOT NULL DEFAULT '[]'"], ['data', "TEXT NOT NULL DEFAULT '{}'"],
             ['created', 'INTEGER'], ['updated', 'INTEGER'], ['ended', 'INTEGER NOT NULL DEFAULT 0'], ['rev', 'INTEGER NOT NULL DEFAULT 0']],
};
const INDEXES = [
  `CREATE UNIQUE INDEX IF NOT EXISTS tj_req_live ON tj_req(src, tmdb, season) WHERE stage NOT IN ('done','failed','cancelled')`,
  `CREATE INDEX IF NOT EXISTS tj_req_next ON tj_req(next)`,
  `CREATE INDEX IF NOT EXISTS tj_req_tmdb ON tj_req(tmdb)`,
  `CREATE INDEX IF NOT EXISTS tj_req_bat ON tj_req(bat)`,
  `CREATE INDEX IF NOT EXISTS tj_batch_open ON tj_batch(ended)`,
  /* 2.6：凑批每轮按 stage 查（等待凑批的、前面还在下载 / 清洗的、排队的单个传输），/app/flow 每 5 秒也查；
     tj_req 不删旧的（就绪 / 失败的留着追踪、看历史），没有这个索引每次都把整张表读一遍（D1 按读了几行算） */
  `CREATE INDEX IF NOT EXISTS tj_req_stage ON tj_req(stage, since)`,
  /* 2.7：每轮挑到期的（stage IN … AND next <= ?）、libNudge（done 的 next > 0）按 stage + next 直接找到那几行；
     以前 libNudge 走 tj_req_stage，每轮把全部 done 的行读一遍 */
  `CREATE INDEX IF NOT EXISTS tj_req_stnext ON tj_req(stage, next)`,
];
let SCHEMA_OK = false;
async function db(env){
  if (!env.DB) throw err('没绑 D1：Worker 设置 → 绑定 → D1 数据库，变量名 DB', { conf: 1 });
  if (SCHEMA_OK) return env.DB;
  await env.DB.batch(SCHEMA.map(s => env.DB.prepare(s)));
  const add = [];
  for (const [table, cols] of Object.entries(COLUMNS)){
    const have = new Set(((await env.DB.prepare('PRAGMA table_info(' + table + ')').all()).results || []).map(c => c.name));
    for (const [name, type] of cols) if (!have.has(name)) add.push('ALTER TABLE ' + table + ' ADD COLUMN ' + name + ' ' + type);
  }
  if (add.length) await env.DB.batch(add.map(s => env.DB.prepare(s)));
  await env.DB.batch(INDEXES.map(s => env.DB.prepare(s)));
  SCHEMA_OK = true;
  return env.DB;
}
async function kvGet(env, k){
  const r = await (await db(env)).prepare('SELECT v, exp FROM tj_kv WHERE k = ?').bind(k).first();
  if (!r || (r.exp && r.exp < now())) return null;
  try { return JSON.parse(r.v); } catch { return null; }
}
async function kvPut(env, k, v, ttl){
  await (await db(env)).prepare('INSERT INTO tj_kv (k, v, exp) VALUES (?, ?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v, exp = excluded.exp')
    .bind(k, JSON.stringify(v), ttl ? now() + ttl : 0).run();
}
async function kvDel(env, k){ await (await db(env)).prepare('DELETE FROM tj_kv WHERE k = ?').bind(k).run(); }
/** 一轮只跑一个：定时任务和面板上的「立即跑一轮」撞上时后来的直接走。
    owner（2.7）= 这一轮的令牌：跑完用它还（unlease），别人的租约还不掉 */
async function lease(env, k, ms, owner){
  const t = now();
  const r = await (await db(env)).prepare(
    'INSERT INTO tj_kv (k, v, exp) VALUES (?, ?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v, exp = excluded.exp WHERE tj_kv.exp < ?')
    .bind(k, owner || '1', t + ms, t).run();
  return !!(r.meta && r.meta.changes);
}
/** 还租约（2.7）：exp = 0 比现在早，下一个马上拿得到；只还自己的（v = 这一轮的令牌） */
async function unlease(env, k, owner){
  await (await db(env)).prepare('UPDATE tj_kv SET exp = 0 WHERE k = ? AND v = ?').bind(k, owner).run();
}
async function logMsg(env, rid, msg){
  try { await (await db(env)).prepare('INSERT INTO tj_log (rid, at, msg) VALUES (?, ?, ?)').bind(rid || 0, now(), String(msg).slice(0, 500)).run(); } catch {}
}

function rowOf(x){
  if (!x) return null;
  let d = {}, users = [];
  try { d = JSON.parse(x.data || '{}') || {}; } catch {}
  try { users = JSON.parse(x.users || '[]') || []; } catch {}
  return { ...x, d, users };
}
async function getReq(env, id){
  return rowOf(await (await db(env)).prepare('SELECT * FROM tj_req WHERE id = ?').bind(id).first());
}
/** 存一条：rev 对得上才写（面板上刚取消 / 重试过的，这一轮推进的结果作废）。
    不写 users（2.7）：跟上的人只由跟上的那条 UPDATE 加（它不动 rev），这里写的话会拿读进来时的旧名单把刚跟上的人盖掉 */
async function saveReq(env, r){
  const t = now();
  const res = await (await db(env)).prepare(
    `UPDATE tj_req SET title = ?, year = ?, poster = ?, stage = ?, pct = ?, note = ?, data = ?, updated = ?, since = ?,
       next = ?, bat = ?, rev = rev + 1 WHERE id = ? AND rev = ?`)
    .bind(r.title || '', r.year || '', r.poster || '', r.stage, +r.pct || 0, r.note || '',
          JSON.stringify(r.d || {}), t, r.since || t, r.next || 0, r.bat || 0, r.id, r.rev).run();
  const ok = !!(res.meta && res.meta.changes);
  if (ok){ r.rev++; r.updated = t; }
  return ok;
}

/* ══════════════════════════════════════════════════════════════════
   设置（PikPak 密码加密存放）
   ══════════════════════════════════════════════════════════════════ */
const CFG_DEF = { pkUser: '', pkPass: '', tpl: 'rel', lang: 'en', grp: 'Cuven®', userCap: LIMIT.userActive,
                  globalCap: LIMIT.globalActive, paused: false,
                  pkSlots: 16,    // PikPak 同时云下载几个（2.6：16 个，凑得满一批）
                  vpsSlots: 2,    // VPS 同时传输几个（rclone 一次跑太多会把内存吃满、整个进程被杀；批量传输在跑时单个的一律等）
                  autoReady: true,    // 文件抵达 /auto 自动通过最终审核（不等工作人员发行）
                  tagNames: true,     // 名字里带追踪码 [auto-m550-r13]（传完以后也能一直追踪）
                  /* 批量（2.6） */
                  batch: true,        // 清洗好的凑够一批一起传（关了就是一部一部传）
                  batchMin: 16,       // 凑够几部开一批
                  batchMax: 16,       // 一批最多几部
                  batchWait: 30,      // 最早的一部最多等几分钟（老版本 App 一部一部提交的最多 10 分钟）
                  xfers: 16,          // 批量传输：并行传输几个文件（rclone Transfers）
                  checkers: 16,       // 批量传输：并发核对几个（rclone Checkers）
                  basketMax: 50,      // 请求中心一次最多提交几条
                  tvSub: 'ram2' };    // 剧集放在 /auto 下面哪个文件夹（PikPak 和 Dropbox 一样；空 = 直接放 /auto）
/** 剧集区的名字：一层、不带斜杠（和传输 Worker 的 AUTO_TV_DIR、Stream 的 AUTO_TV_SUB 一致） */
const subOK = (s) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$/.test(s);
const b64 = (u8) => { let s = ''; for (const c of u8) s += String.fromCharCode(c); return btoa(s); };
const unb64 = (s) => Uint8Array.from(atob(s), c => c.charCodeAt(0));
async function secretKey(env){
  if (!env.ADMIN_KEY) throw err('还没配 ADMIN_KEY', { conf: 1 });
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('cuven-tj:' + env.ADMIN_KEY));
  return crypto.subtle.importKey('raw', h, 'AES-GCM', false, ['encrypt', 'decrypt']);
}
async function seal(env, text){
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await secretKey(env), new TextEncoder().encode(text)));
  const out = new Uint8Array(12 + ct.length); out.set(iv); out.set(ct, 12);
  return b64(out);
}
async function unseal(env, s){
  if (!s) return '';
  try {
    const u = unb64(s);
    const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: u.slice(0, 12) }, await secretKey(env), u.slice(12));
    return new TextDecoder().decode(pt);
  } catch { return ''; }
}
async function loadCfg(env){
  const raw = (await kvGet(env, 'cfg')) || {};
  const cfg = { ...CFG_DEF, ...raw };
  cfg.pkPass = raw.pkPassEnc ? await unseal(env, raw.pkPassEnc) : '';
  delete cfg.pkPassEnc;
  return cfg;
}
async function saveCfg(env, patch){
  const raw = (await kvGet(env, 'cfg')) || {};
  const next = { ...raw };
  if (typeof patch.pkUser === 'string') next.pkUser = patch.pkUser.trim().slice(0, 120);
  if (typeof patch.pkPass === 'string' && patch.pkPass) next.pkPassEnc = await seal(env, patch.pkPass.slice(0, 200));
  if (patch.pkClear){ next.pkUser = ''; delete next.pkPassEnc; }
  if (['rel', 'std', 'season', 'nest', 'dot'].includes(patch.tpl)) next.tpl = patch.tpl;
  if (['en', 'cn', 'cnen'].includes(patch.lang)) next.lang = patch.lang;
  if (typeof patch.grp === 'string') next.grp = patch.grp.slice(0, 40);
  if (patch.userCap != null) next.userCap = clamp(parseInt(patch.userCap, 10) || LIMIT.userActive, 1, 100);
  if (patch.globalCap != null) next.globalCap = clamp(parseInt(patch.globalCap, 10) || LIMIT.globalActive, 1, 1000);
  if (patch.paused != null) next.paused = !!patch.paused;
  if (patch.autoReady != null) next.autoReady = !!patch.autoReady;
  if (patch.tagNames != null) next.tagNames = !!patch.tagNames;
  if (patch.pkSlots != null) next.pkSlots = clamp(parseInt(patch.pkSlots, 10) || CFG_DEF.pkSlots, 1, 20);
  if (patch.vpsSlots != null) next.vpsSlots = clamp(parseInt(patch.vpsSlots, 10) || CFG_DEF.vpsSlots, 1, 8);
  /* 批量（2.6） */
  const num = (k, lo, hi) => { if (patch[k] != null) next[k] = clamp(parseInt(patch[k], 10) || CFG_DEF[k], lo, hi); };
  if (patch.batch != null) next.batch = !!patch.batch;
  num('batchMax', 1, LIMIT.batchMax); num('batchMin', 1, LIMIT.batchMax); num('batchWait', 1, 24 * 60);
  num('xfers', 1, 16); num('checkers', 1, 16); num('basketMax', 1, LIMIT.basketMax);
  if (typeof patch.tvSub === 'string'){ const s = patch.tvSub.trim(); if (!s || subOK(s)) next.tvSub = s; }
  /* 凑批的下限不能比一批最多几部还大 */
  if ((next.batchMin ?? CFG_DEF.batchMin) > (next.batchMax ?? CFG_DEF.batchMax)) next.batchMin = next.batchMax ?? CFG_DEF.batchMax;
  if (next.pkUser !== raw.pkUser || next.pkPassEnc !== raw.pkPassEnc){ await kvDel(env, 'pk:tok'); PK_MEM = null; PK_FAIL = null; }
  await kvPut(env, 'cfg', next);
  return loadCfg(env);
}
const mask = (u) => { u = String(u || ''); const i = u.indexOf('@'); return !u ? '' : i > 0 ? u.slice(0, Math.min(2, i)) + '***' + u.slice(i) : u.slice(0, 3) + '***' + u.slice(-2); };

/* ══════════════════════════════════════════════════════════════════
   一轮的上下文：子请求预算 + 时间预算 + 这一轮里共用的缓存 + 依赖健康 + 写入缓冲
   ══════════════════════════════════════════════════════════════════ */
function context(env, cfg, budget){
  return { env, cfg, n: 0, max: budget || LIMIT.fetches, t0: now(), memo: {}, health: null, logs: null, pending: null, slots: null };
}
/** read = 只读的调用（问进度、列目录、核对）：截止时刻快到了就把超时缩短。
    有副作用的（开传输、改名、推送、挪 / 删文件）不缩短：缩短了会「那边做了、这边没收到回答」，下一轮再做一遍；
    剩的时间不够一个完整的超时就这一轮不发，下一轮再做（2.7） */
async function xfetch(c, url, init = {}, ms = 25000, read = false){
  /* over = 这一轮撞上预算几次（2.6，记进 tick:last）：c.n 到不了 42 以上，光看用了几个看不出这一轮有没有被预算掐掉 */
  if (c.n >= c.max){ c.over = (c.over || 0) + 1; throw err('这一轮的子请求用完了，下一轮接着做', { budget: 1 }); }
  /* 一轮的截止时刻（2.7）：一轮不会跑过租约，下一分钟的定时任务不会和这一轮推进同一条 */
  if (c.end){
    const left = c.end - now();
    if (left < (read ? LIMIT.minCall : ms)){ c.over = (c.over || 0) + 1; throw err('这一轮的时间快用完了，下一轮接着做', { budget: 1 }); }
    if (read) ms = Math.min(ms, left);
  }
  c.n++;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), ms);
  try { return await fetch(url, { ...init, signal: ac.signal }); }
  catch (e){ throw err((e && e.name === 'AbortError' ? '超时：' : '连不上：') + new URL(url).host, { net: 1 }); }
  finally { clearTimeout(timer); }
}
async function readJSON(r){
  const txt = await r.text().catch(() => '');
  try { return txt ? JSON.parse(txt) : {}; } catch { return { error: txt.slice(0, 160) || ('HTTP ' + r.status) }; }
}

/* ══════════════════════════════════════════════════════════════════
   依赖的健康：熔断
   四个外部依赖：影片库（lb）、传输 / VPS（vps）、PikPak（pikpak）、TMDB 分季（stream）。
   同一个依赖连续 3 次「暂时性」失败（连不上、超时、5xx、429、影片库忙）就熔断 2 分钟：这一轮和后面几轮都不再碰它，
   要用它的请求原地等——不算出错次数、不换规格、不会因为对方抖一下就把一部片判死。
   到期放一次试探（半开）：通了就恢复；又失败就再熔断，时间翻倍（2 → 4 → 8 → 15 分钟封顶）。
   逻辑错误（4xx：参数不对、文件夹不在、作业没了）不算依赖坏了。状态存在 tj_kv 的 health 里，控制面板看得到。
   ══════════════════════════════════════════════════════════════════ */
const DEPS = { lb: '影片库', vps: '传输（VPS）', pikpak: 'PikPak', stream: '片库 / TMDB' };
/** 每一步要用哪些依赖：熔断中的不去碰 */
const STAGE_DEPS = { queued: ['lb'], download: ['pikpak'], clean: ['pikpak'], check: ['vps'], rename: ['vps'], ready: [],
                     copy: ['vps'], verify: ['vps'], purge: ['vps'], release: [] };
/** logic = 对方明确回的「不行」（传输 Worker 910 的 409 nofilter / exists），不是对方坏了 */
const transientErr = (e) => !!(e && !e.budget && !e.circuit && !e.logic && (e.net || e.status >= 500 || e.status === 429 || e.status === 409));
async function loadHealth(env){
  const h = (await kvGet(env, 'health')) || {};
  for (const k of Object.keys(DEPS)) h[k] = { fails: 0, trips: 0, open: 0, err: '', ok: 0, bad: 0, ...(h[k] || {}) };
  return h;
}
function depOpenUntil(c, dep){
  const h = c.health && c.health[dep];
  return h && h.open > now() ? h.open : 0;
}
function depResult(c, dep, e){
  if (!c.health) return;
  const h = c.health[dep], t = now();
  if (!e){
    if (h.fails || h.trips || h.open){ h.fails = 0; h.trips = 0; h.open = 0; c.healthDirty = true; }
    if (t - h.ok > MIN){ h.ok = t; c.healthDirty = true; }
    return;
  }
  if (!transientErr(e)) return;
  const halfOpen = h.open && h.open <= t;
  h.err = String(e.message || e).slice(0, 160); h.bad = t; h.fails++; c.healthDirty = true;
  if (halfOpen || h.fails >= 3){ h.trips = Math.min(h.trips + 1, 4); h.open = t + Math.min(15, 2 ** h.trips) * MIN; h.fails = 0; }
}
async function depCall(c, dep, fn){
  const until = depOpenUntil(c, dep);
  if (until) throw err(DEPS[dep] + '暂时不可用，约 ' + Math.max(1, Math.ceil((until - now()) / MIN)) + ' 分钟后再试', { circuit: dep, until });
  try { const v = await fn(); depResult(c, dep, null); return v; }
  catch (e){ depResult(c, dep, e); throw e; }
}

/* ── 影片库（lb.cuven.us）── */
async function lb(c, path, init){
  if (!c.env.LB_GATE) throw err('还没配 LB_GATE（影片库的 GATE 口令）', { conf: 1 });
  const read = !(init && init.method && init.method !== 'GET');          // 推送、建文件夹是 POST
  return depCall(c, 'lb', async () => {
    const r = await xfetch(c, base(c.env, 'LB_BASE', 'https://lb.cuven.us') + path, {
      ...(init || {}), headers: { 'x-gate': c.env.LB_GATE, 'content-type': 'application/json', ...((init || {}).headers || {}) } }, 40000, read);
    const j = await readJSON(r);
    if (!r.ok) throw err('影片库：' + (j.error || 'HTTP ' + r.status), { status: r.status, net: r.status >= 500 || r.status === 409 ? 1 : 0, lb: 1 });
    return j;
  });
}
const lbVersions = (c, src, id, season) =>
  lb(c, '/api/link/versions?src=' + src + '&id=' + id + (season ? '&season=' + season : ''));

/* ── 传输（transfer.cuven.us，VPS 上的 rclone）──
   传输 Worker 908 起自己会对 52x 重试；到这里还是 5xx，说明 VPS 那头真的有问题，算进熔断。
   422 是 rclone 自己回的逻辑错（作业没了、文件夹不在），不算 VPS 坏了 */
/** 只读的传输调用（2.7：一轮快到截止时刻时可以缩短超时）；别的（copy / rename / organize / purge / stop / batch-copy / batch-purge）都有副作用 */
const TF_READ = new Set(['ping', 'job', 'jobs', 'exists', 'check', 'verify', 'batch-verify']);
async function tf(c, op, body, ms){
  if (!c.env.LINK_KEY) throw err('还没配 LINK_KEY（传输 Worker 的 LINK_KEY）', { conf: 1 });
  return depCall(c, 'vps', async () => {
    const r = await xfetch(c, base(c.env, 'TRANSFER_BASE', 'https://transfer.cuven.us') + '/api/link/' + op, {
      method: 'POST', headers: { 'x-cuven-link': c.env.LINK_KEY, 'content-type': 'application/json' }, body: JSON.stringify(body || {}) },
      ms || 60000, TF_READ.has(op));
    const j = await readJSON(r);
    if (!r.ok) throw err('传输：' + (j.error || 'HTTP ' + r.status), { status: r.status, net: r.status >= 500 ? 1 : 0, tf: 1, body: j,
                                                                    logic: r.status === 409 && (j.nofilter || j.exists) ? 1 : 0 });
    return j;
  });
}

/* ── 传输 Worker 会什么（910 起 ping 回 caps: ['sub', 'batch'] 和剧集区的名字 tv）：存 tj_kv，30 分钟问一次。
   问不到（VPS 熔断、连不上）就用上一次的；从来没问到过 = 不知道：剧集照旧放 /auto，凑批先等着。这里从不抛错 ── */
async function tfCaps(c){
  if (c.memo.caps) return c.memo.caps;
  let v = await kvGet(c.env, 'tf:caps').catch(() => null);
  if ((!v || now() - (v.at || 0) > LIMIT.capsEvery) && c.env.LINK_KEY && !depOpenUntil(c, 'vps') && c.n < c.max - 4){
    try {
      const p = await tf(c, 'ping', {});
      v = { caps: Array.isArray(p.caps) ? p.caps.map(String) : [], tv: String(p.tv || ''), core: String(p.core || ''), at: now(),
            nofilter: (v && v.nofilter) || 0 };
      await kvPut(c.env, 'tf:caps', v).catch(() => {});
    } catch {}
  }
  return (c.memo.caps = capsOf(c.cfg, v));
}
/** 剧集区的名字两边要一样（这里的 tvSub、传输 Worker 的 AUTO_TV_DIR），对不上就照旧放 /auto（不然传输 Worker 回 400） */
function capsOf(cfg, v){
  if (!v) return { known: false, batch: false, sub: '', tv: '' };
  const caps = v.caps || [], want = cfg.tvSub || '';
  const mismatch = !!(want && caps.includes('sub') && v.tv && v.tv !== want);
  return { known: true, batch: caps.includes('batch') && !(v.nofilter > now()), sub: want && caps.includes('sub') && !mismatch ? want : '',
           tv: v.tv || '', core: v.core || '', nofilter: v.nofilter > now() ? v.nofilter : 0, mismatch };
}
async function capsSet(c, patch){
  const v = { caps: [], tv: '', at: now(), ...((await kvGet(c.env, 'tf:caps').catch(() => null)) || {}), ...patch };
  await kvPut(c.env, 'tf:caps', v).catch(() => {});
  c.memo.caps = capsOf(c.cfg, v);
}
/** 剧集（在 /auto/ram2 里的）给传输 Worker 的每个调用都带上 sub；改名时 to = 改完放哪儿（同一个区） */
const withSub = (r, o, move) => r.d.sub ? { ...o, sub: r.d.sub, ...(move ? { to: r.d.sub } : {}) } : o;
/** 批量接口里的一条，和它在回包里的 key（sub/名字，电影就是名字） */
const bItem = (r) => ({ item: r.d.item, kind: r.d.kind, sub: r.d.sub || '' });
const bKey = (r) => r.d.sub ? r.d.sub + '/' + r.d.item : r.d.item;
const autoPath = (c, r) => (c.env.AUTO_DIR || 'auto') + '/' + (r.d.sub ? r.d.sub + '/' : '') + r.d.item;

/* ── TMDB：一季已经播出的集数（标题里没写总集数时用来核对整季；问不到就当不知道）── */
async function airedCount(c, id, season){
  try {
    return await depCall(c, 'stream', async () => {
      const r = await xfetch(c, base(c.env, 'STREAM_BASE', 'https://stream.cuven.online') + '/api/tmdb/season?id=' + id + '&season=' + season, {}, 20000, true);
      if (r.status >= 500) throw err('TMDB：HTTP ' + r.status, { status: r.status, net: 1 });
      if (!r.ok) return 0;
      const j = await readJSON(r);
      const today = new Date().toISOString().slice(0, 10);
      const eps = (j.episodes || []).filter(e => e && e.ep > 0);
      return { total: eps.length, aired: eps.filter(e => e.air_date && e.air_date <= today).length };
    });
  } catch (e){ if (e.budget) throw e; return 0; }
}

/* ── 片库（Stream Worker v25.1+）：马上重看一眼 Dropbox 的 /auto，回这几个名字收录了没有 ──
   电影是 /auto 里的那个文件名，剧集是 /auto 里的那个文件夹名。
   老版本没有这个接口（404）、关了 AUTO_FOLDER、口令不对（401 / 403）→ { off }：照旧等工作人员发行 */
async function streamSync(c, items, tv, codes, tmdbs){
  return depCall(c, 'stream', async () => {
    const q = new URLSearchParams();
    for (const n of items) q.append('item', n);
    for (const k of codes || []) q.append('code', k);
    for (const k of tmdbs || []) q.append('tmdb', k);
    if (tv) q.set('tv', '1');
    const headers = c.env.STREAM_SYNC_KEY ? { 'x-sync-key': c.env.STREAM_SYNC_KEY } : {};
    /* 让片库重看一眼 /auto、回收录了没有：重复问没有坏处，算只读 */
    const r = await xfetch(c, base(c.env, 'STREAM_BASE', 'https://stream.cuven.online') + '/api/auto/sync?' + q, { method: 'POST', headers }, 30000, true);
    if (r.status === 404) return { off: 1, why: '片库是老版本，没有 /api/auto/sync' };
    if (r.status === 401 || r.status === 403) return { off: 1, why: '片库要口令（STREAM_SYNC_KEY 和它的 AUTO_SYNC_KEY 对不上）' };
    if (r.status >= 500 || r.status === 429) throw err('片库：HTTP ' + r.status, { status: r.status, net: 1 });
    const j = await readJSON(r);
    if (!r.ok) throw err('片库：' + (j.error || 'HTTP ' + r.status), { status: r.status });
    if (j.off) return { off: 1, why: '片库关了 AUTO_FOLDER' };
    return { has: j.has || {}, where: j.where || null, found: j.found || null, root: j.root || '' };
  });
}

/* ══════════════════════════════════════════════════════════════════
   PikPak（清洗用；协议同影片库 Worker 的那一份，设备号另起一个，两边各是各的会话）
   ══════════════════════════════════════════════════════════════════ */
const PK = {
  cid: 'YNxT9w7GMdWvEOKa', secret: 'dbw2OtmVEeuUvIptb1Coyg', ver: '1.47.1', pkg: 'com.pikcloud.pikpak',
  salts: ['Gez0T9ijiI9WCeTsKSg3SMlx', 'zQdbalsolyb1R/', 'ftOjr52zt51JD68C3s', 'yeOBMH0JkbQdEFNNwQ0RI9T3wU/v', 'BRJrQZiTQ65WtMvwO',
          'je8fqxKPdQVJiy1DM6Bc9Nb1', 'niV', '9hFCW2R1', 'sHKHpe2i96', 'p7c5E6AcXQ/IJUuAEC9W6', '', 'aRv9hjc9P+Pbn+u3krN6',
          'BzStcgE8qVdqjEH16l4', 'SqgeZvL5j9zoHP95xWHt', 'zVof5yaJkPe3VFpadPof'],
  ua: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  signin: 'https://user.mypikpak.com/v1/auth/signin',
  user: 'https://user.mypikpak.com', api: 'https://api-drive.mypikpak.com',
};
const MD5_S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
const MD5_K = Array.from({ length: 64 }, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0);
function md5(str){
  const b = new TextEncoder().encode(String(str)), n = b.length;
  const w = new Uint32Array((((n + 8) >> 6) + 1) * 16);
  for (let i = 0; i < n; i++) w[i >> 2] |= b[i] << ((i & 3) * 8);
  w[n >> 2] |= 0x80 << ((n & 3) * 8);
  w[w.length - 2] = (n * 8) >>> 0;
  w[w.length - 1] = Math.floor(n / 0x20000000);
  let a = 0x67452301, bb = 0xefcdab89, c = 0x98badcfe, d = 0x10325476;
  for (let i = 0; i < w.length; i += 16){
    let A = a, B = bb, C = c, D = d;
    for (let j = 0; j < 64; j++){
      let f, g;
      if (j < 16){ f = (B & C) | (~B & D); g = j; }
      else if (j < 32){ f = (D & B) | (~D & C); g = (5 * j + 1) & 15; }
      else if (j < 48){ f = B ^ C ^ D; g = (3 * j + 5) & 15; }
      else { f = C ^ (B | ~D); g = (7 * j) & 15; }
      const x = (A + f + MD5_K[j] + w[i + g]) | 0, s = MD5_S[(j >> 4) * 4 + (j & 3)];
      A = D; D = C; C = B;
      B = (B + ((x << s) | (x >>> (32 - s)))) | 0;
    }
    a = (a + A) | 0; bb = (bb + B) | 0; c = (c + C) | 0; d = (d + D) | 0;
  }
  let out = '';
  for (const v of [a, bb, c, d]) for (let k = 0; k < 4; k++) out += ((v >>> (k * 8)) & 255).toString(16).padStart(2, '0');
  return out;
}
const pkDevice = (cfg) => md5('cuven-tj:' + cfg.pkUser + ':' + cfg.pkPass);
function pkSign(dev, ts){
  let s = PK.cid + PK.ver + PK.pkg + dev + ts;
  for (const salt of PK.salts) s = md5(s + salt);
  return '1.' + s;
}
const PK_MSG = [
  [/invalid_account_or_password|account_not_found|password_error/i, 'PikPak 账号或密码不对（在控制面板重新填）'],
  [/captcha_invalid|captcha_required/i, 'PikPak 的人机验证没通过'],
  [/file_space_not_enough|space_not_enough|quota_exceed/i, 'PikPak 空间不够了'],
  [/too_many_requests|frequen/i, 'PikPak 说请求太频繁'],
  [/file_not_found|not_found/i, 'PikPak 上找不到这个文件 / 任务'],
  [/permission_denied|forbidden/i, 'PikPak 拒绝了这个操作'],
];
function pkError(j, status){
  const raw = String((j && (j.error_description || j.error)) || ('HTTP ' + status));
  const key = String((j && j.error) || '') + ' ' + raw;
  const hit = PK_MSG.find(([re]) => re.test(key));
  return err(hit ? hit[1] + '：' + raw.slice(0, 80) : 'PikPak：' + raw.slice(0, 140),
    { pk: 1, code: Number(j && j.error_code) || 0, perr: String((j && j.error) || ''), status, notFound: /not_found/i.test(key) });
}
async function pkJSON(c, method, url, body, headers){
  return depCall(c, 'pikpak', async () => {
    const r = await xfetch(c, url, { method, body: body == null ? undefined : JSON.stringify(body),
      headers: { 'content-type': 'application/json; charset=utf-8', accept: 'application/json', 'user-agent': PK.ua, ...(headers || {}) } },
      25000, method === 'GET');
    const txt = await r.text().catch(() => '');
    let j = null;
    try { j = txt ? JSON.parse(txt) : {}; } catch {}
    if (j && !j.error && r.status < 400) return j;
    if (!j) throw err('PikPak 回的不是 JSON（HTTP ' + r.status + '）', { pk: 1, status: r.status, net: r.status >= 500 ? 1 : 0 });
    const e = pkError(j, r.status);
    if (r.status >= 500 || r.status === 429 || /too_many_requests|frequen/i.test(e.perr || '')) e.net = 1;   // PikPak 那头忙：算暂时性的
    throw e;
  });
}
async function pkCaptcha(c, action, meta){
  const dev = pkDevice(c.cfg);
  const j = await pkJSON(c, 'POST', PK.user + '/v1/shield/captcha/init', { client_id: PK.cid, action, device_id: dev, meta }, { 'x-device-id': dev });
  if (!j.captcha_token)
    throw err(j.url ? 'PikPak 要求人机验证（滑块），Worker 过不了：先用同一个账号在 PikPak 的 App 或网页上登录一次，过几分钟再试'
                    : 'PikPak 没给验证令牌', { pk: 1, captcha: 1 });
  return j.captcha_token;
}
const pkSignMeta = (c, sub) => { const t = String(now()); return { captcha_sign: pkSign(pkDevice(c.cfg), t), client_version: PK.ver, package_name: PK.pkg, user_id: sub || '', timestamp: t }; };
async function pkSignin(c){
  const u = String(c.cfg.pkUser).trim(), meta = {};
  if (/^[\w.+-]+@[\w-]+(\.[\w-]+)+$/.test(u)) meta.email = u;
  else if (/^\+?\d{11,18}$/.test(u)) meta.phone_number = u;
  else meta.username = u;
  const ct = await pkCaptcha(c, 'POST:' + PK.signin, meta);
  return pkJSON(c, 'POST', PK.user + '/v1/auth/signin',
    { client_id: PK.cid, client_secret: PK.secret, password: String(c.cfg.pkPass), username: u, captcha_token: ct }, { 'x-device-id': pkDevice(c.cfg) });
}
let PK_MEM = null, PK_FAIL = null;
async function pkAuth(c, force){
  if (!c.cfg.pkUser || !c.cfg.pkPass) throw err('还没在控制面板填 PikPak 账号和密码', { pk: 1, conf: 1 });
  const tag = md5('u:' + c.cfg.pkUser + ':' + c.cfg.pkPass).slice(0, 10);
  const fresh = (st) => st && st.u === tag && st.access && st.exp - 120000 > now();
  if (!force && fresh(PK_MEM)) return PK_MEM;
  let st = await kvGet(c.env, 'pk:tok');
  if (st && st.u !== tag) st = null;
  if (fresh(st) && (!force || !PK_MEM || st.access !== PK_MEM.access)) return (PK_MEM = st);
  if (PK_FAIL && PK_FAIL.tag === tag && now() < PK_FAIL.until) throw err(PK_FAIL.msg, { pk: 1, auth: 1, cool: 1 });
  let j = null;
  if (st && st.refresh){
    try { j = await pkJSON(c, 'POST', PK.user + '/v1/auth/token',
      { client_id: PK.cid, client_secret: PK.secret, grant_type: 'refresh_token', refresh_token: st.refresh }, { 'x-device-id': pkDevice(c.cfg) }); }
    catch (e){ if (e.budget || e.net) throw e; j = null; }
  }
  if (!j || !j.access_token){
    try { j = await pkSignin(c); }
    catch (e){
      if (!e.budget && !e.net){
        const bad = /invalid_account_or_password|account_not_found|password_error/i.test(e.perr || '');
        PK_FAIL = { tag, msg: e.message, until: now() + (bad ? 10 * MIN : MIN) };
      }
      e.auth = 1; throw e;
    }
  }
  if (!j.access_token) throw err('PikPak 登录没拿到令牌', { pk: 1, auth: 1 });
  PK_FAIL = null;
  st = { u: tag, access: j.access_token, refresh: j.refresh_token || (st && st.refresh) || '', sub: j.sub || (st && st.sub) || '',
         exp: now() + (Number(j.expires_in) || 7200) * 1000 };
  PK_MEM = st;
  await kvPut(c.env, 'pk:tok', st, 30 * DAY);
  return st;
}
async function pkCall(c, method, path, opt = {}){
  let st = await pkAuth(c), ct = '';
  let qs = '';
  if (opt.q){
    const sp = new URLSearchParams();
    for (const [k, v] of Object.entries(opt.q)){
      if (v == null || v === '') continue;
      if (Array.isArray(v)) v.forEach(x => sp.append(k, String(x))); else sp.append(k, String(v));
    }
    qs = '?' + sp.toString();
  }
  for (let i = 0; ; i++){
    const h = { authorization: 'Bearer ' + st.access, 'x-device-id': pkDevice(c.cfg) };
    if (ct) h['x-captcha-token'] = ct;
    try { return await pkJSON(c, method, PK.api + path + qs, opt.body, h); }
    catch (e){
      if (i >= 2 || e.budget || e.net) throw e;
      if (e.code === 16 || e.code === 4121 || e.code === 4122 || e.status === 401 || /unauthenticated|invalid_token/i.test(e.perr || '')){ st = await pkAuth(c, true); continue; }
      if (e.code === 9 || /captcha/i.test(e.perr || '')){ ct = await pkCaptcha(c, method + ':' + path, pkSignMeta(c, st.sub)); continue; }
      throw e;
    }
  }
}
/** 进行中 / 排队 / 出错的云下载任务（一轮只问一次，几条请求共用）。完成了的任务不在这里，去看文件 */
async function pkTasks(c){
  if (c.memo.tasks) return c.memo.tasks;
  const map = new Map();
  let token = '';
  for (let pg = 0; pg < 3; pg++){
    const j = await pkCall(c, 'GET', '/drive/v1/tasks', { q: { type: 'offline', thumbnail_size: 'SIZE_SMALL', limit: 200, page_token: token,
      filters: JSON.stringify({ phase: { in: 'PHASE_TYPE_RUNNING,PHASE_TYPE_PENDING,PHASE_TYPE_ERROR' } }) } });
    for (const t of (j.tasks || [])) if (t && t.id) map.set(String(t.id), t);
    token = j.next_page_token || '';
    if (!token) break;
  }
  return (c.memo.tasks = map);
}
async function pkFile(c, id){
  try { return await pkCall(c, 'GET', '/drive/v1/files/' + encodeURIComponent(id), { q: { thumbnail_size: 'SIZE_SMALL' } }); }
  catch (e){ if (e.notFound || e.status === 404) return null; throw e; }
}
/** 一个文件夹下面的东西（文件 + 文件夹，不进回收站里的） */
async function pkChildren(c, parent){
  const out = [];
  let token = '';
  for (let pg = 0; pg < 5; pg++){
    const j = await pkCall(c, 'GET', '/drive/v1/files', { q: { parent_id: parent || '', thumbnail_size: 'SIZE_SMALL', limit: 200,
      with_audit: 'false', page_token: token, filters: JSON.stringify({ trashed: { eq: false } }) } });
    for (const f of (j.files || [])) if (f && f.id) out.push(f);
    token = j.next_page_token || '';
    if (!token) break;
  }
  return out;
}
/** 往下翻几层，把文件都找出来 */
async function pkWalk(c, root, depth = 3){
  const files = [];
  let level = [root];
  for (let d = 0; d < depth && level.length; d++){
    const next = [];
    for (const id of level.slice(0, 12)){
      for (const f of await pkChildren(c, id)){
        if (f.kind === 'drive#folder') next.push(f.id);
        else files.push({ id: String(f.id), name: String(f.name || ''), size: Number(f.size) || 0, parent: String(f.parent_id || id) });
      }
    }
    level = next;
  }
  return files;
}
const pkMove = (c, ids, parent) => pkCall(c, 'POST', '/drive/v1/files:batchMove', { body: { ids, to: { parent_id: parent } } });
const pkTrash = (c, ids) => pkCall(c, 'POST', '/drive/v1/files:batchTrash', { body: { ids } });
const pkDelTasks = (c, ids, files) => pkCall(c, 'DELETE', '/drive/v1/tasks', { q: { task_ids: ids, delete_files: files ? 'true' : 'false' } });

/** /auto 的文件夹编号：问影片库（它往哪个网盘推，就以它看到的为准），没有就让它建一个 */
async function autoFolder(c, refresh){
  const name = String(c.env.AUTO_DIR || 'auto');
  if (!refresh && c.memo.auto) return c.memo.auto;
  if (!refresh){ const v = await kvGet(c.env, 'auto:id'); if (v && v.id && v.name === name) return (c.memo.auto = v.id); }
  const ls = await lb(c, '/api/pikpak?do=ls&parent=');
  let f = (ls.folders || []).find(x => x.name === name);
  if (!f) f = await lb(c, '/api/pikpak?do=mkdir', { method: 'POST', body: JSON.stringify({ parent: '', name }) });
  if (!f || !f.id) throw err('影片库没给出 /' + name + ' 的文件夹编号');
  await kvPut(c.env, 'auto:id', { id: String(f.id), name }, 7 * DAY);
  return (c.memo.auto = String(f.id));
}
/** 剧集区（/auto/ram2）的文件夹编号（2.6）：问影片库 /auto 下面有没有，没有就让它建一个；存 tj_kv，和 /auto 的一样 */
async function tvFolder(c, sub){
  if (c.memo.tv && c.memo.tv.name === sub) return c.memo.tv.id;
  const parent = await autoFolder(c);
  const v = await kvGet(c.env, 'tv:id');
  if (v && v.id && v.name === sub && v.parent === parent){ c.memo.tv = v; return v.id; }
  const ls = await lb(c, '/api/pikpak?do=ls&parent=' + encodeURIComponent(parent));
  let f = (ls.folders || []).find(x => x.name === sub);
  if (!f) f = await lb(c, '/api/pikpak?do=mkdir', { method: 'POST', body: JSON.stringify({ parent, name: sub }) });
  if (!f || !f.id) throw err('影片库没给出 /' + (c.env.AUTO_DIR || 'auto') + '/' + sub + ' 的文件夹编号');
  c.memo.tv = { id: String(f.id), name: sub, parent };
  await kvPut(c.env, 'tv:id', c.memo.tv, 7 * DAY);
  return c.memo.tv.id;
}
/** 这一条在 PikPak 上住哪个文件夹：剧集区的在 /auto/ram2，别的在 /auto */
const homeOf = (c, r) => r.d.sub ? tvFolder(c, r.d.sub) : autoFolder(c);
/** 在一个文件夹里按名字找（2.6）：一轮里同一个文件夹只列一次（16 部一起加追踪码时不用列 16 次）；
    列过但没找到（这一轮里刚挪进来的）再重新列一次，还没有就是没有 */
async function kidFind(c, parent, name){
  const m = c.memo.kids || (c.memo.kids = new Map());
  const e = m.get(parent);
  const hit = e && e.list.find(f => f.name === name);
  if (hit || (e && e.again)) return hit || null;
  const list = await pkChildren(c, parent);
  m.set(parent, { list, again: !!e });
  return list.find(f => f.name === name) || null;
}

/* ══════════════════════════════════════════════════════════════════
   状态机：每条请求一次往前走一步
   · 只许按 FLOW 走（其余跳转是程序错误，停下来等人，不会悄悄跳过一步）
   · 每一步都可以重入：中途被掐（预算、超时、VPS 重启）下一轮从同一步接着做，不重复推送 / 不重复开传输
   ══════════════════════════════════════════════════════════════════ */
const FLOW = {
  queued: ['queued', 'download'], download: ['clean', 'check', 'queued'], clean: ['ready', 'copy', 'queued'], check: ['rename', 'queued'],
  rename: ['ready', 'copy'], ready: ['copy', 'queued'], copy: ['verify', 'ready'], verify: ['purge', 'copy'], purge: ['release'], release: [],
};
function go(r, stage, note){
  if (FLOW[r.stage] && !FLOW[r.stage].includes(stage)) throw err('状态不能从 ' + r.stage + ' 跳到 ' + stage, { bug: 1 });
  r.stage = stage; r.since = now(); r.pct = 0; r.next = now();
  r.note = note || STAGE_TEXT[stage] || '';
  r.d.errs = 0; delete r.d.errSince;
}
function fail(r, why){
  r.d.lastStage = r.stage;
  r.stage = 'failed'; r.since = now(); r.next = 0; r.note = why;
}
/** 这一轮里写日志：先攒着，和请求的更新一起一次写进 D1（不在一轮里的直接写） */
function clog(c, rid, msg){
  if (c.logs){ c.logs.push([rid || 0, now(), String(msg).slice(0, 500)]); return; }
  return logMsg(c.env, rid, msg);
}
/** 删不成（2.7）：预算用完、熔断、PikPak 那头抖了、登录在冷却 → 往上抛，这一条原地不动，下一轮再走到这儿再删（drop 可以重做）；
    别的错（任务 / 文件早就没了、没填 PikPak）当删完了 */
const keepTrying = (e) => { if (e.budget || e.circuit || e.cool || transientErr(e)) throw e; };
/** 当前规格不行了：删掉 PikPak 上的任务和文件（清洗挑剩的原文件夹也删），记下试过，回到 ① 推下一个。
    2.7：以前删失败一律吞掉（预算用完也吞），任务接着在云下载、文件留在 PikPak 没人管；「放弃」的日志放在删完以后，重做时不重复记 */
async function drop(c, r, why){
  if (r.d.task) await pkDelTasks(c, [r.d.task], true).catch(keepTrying);
  if (r.d.file) await pkTrash(c, [r.d.file]).catch(keepTrying);
  if (r.d.junk) await pkTrash(c, [r.d.junk]).catch(keepTrying);
  await clog(c, r.id, '放弃 ' + ((r.d.cur && r.d.cur.t) || '这个规格') + '：' + why);
  if (r.d.cur && r.d.cur.tid != null) r.d.tried = [...new Set([...(r.d.tried || []), r.d.cur.tid])];
  forget(r);
  go(r, 'queued', why + '，换下一个规格');
}
/** 这个规格在 PikPak / 传输上的一切都忘掉（试过哪些不动）。2.6 起 ready 那一步能换规格，追踪码（tag）也得忘掉，下一个规格重新加 */
const DROP_KEYS = ['cur', 'task', 'file', 'fname', 'fkind', 'item', 'kind', 'job', 'newname', 'pmax', 'pat', 'org', 'check',
                   'busySince', 'ctries', 'rtries', 'lost', 'cb', 'cbAt', 'rb', 'rbAt', 'wait', 'vbad', 'vtries', 'fromPk', 'batch', 'sub', 'tag', 'rode',
                   'junk'];
function forget(r){ for (const k of DROP_KEYS) delete r.d[k]; r.bat = 0; }
/** 资源位：PikPak 同时云下载几个、VPS 同时传几个（面板里可调）。满了就排队等，不算出错。
    批量传输在跑（2.6）：它一个作业就占着 VPS，单个传输一律等它传完（16 路并行已经把 rclone 的内存用到头了） */
function slotFree(c, kind){
  if (kind === 'vps' && c.slots && c.slots.batch) return false;
  const s = c.slots && c.slots[kind];
  return !s || s.used < s.max;
}
/** 作业进度：这一轮批量问过（/api/link/jobs）就用那一份，没有再单独问 */
async function jobStatus(c, id){
  const m = c.memo.jobs && c.memo.jobs[id];
  if (m && !m.error) return m;
  try { return await tf(c, 'job', { jobid: id }); }
  catch (e){ if (transientErr(e) || e.budget || e.circuit) throw e; return { finished: true, success: false, error: e.message }; }
}
async function stopJob(c, id){ await tf(c, 'stop', { jobid: id }).catch(e => { if (e.budget) throw e; }); }

/** 追踪码里的 TMDB 那一截：电影 m550，剧集 tv1399s2 */
const tmdbKey = (r) => r.src === 'tv' ? 'tv' + r.tmdb + 's' + (r.season || 1) : 'm' + r.tmdb;
/** 新请求先核对片库（v2.5）：片库里已经有带这个 TMDB 编号追踪码的那一部 → 不用再下，直接就绪。问不成就照常下 */
async function libHasAlready(c, r){
  if (r.d.dup !== undefined) return false;
  r.d.dup = 0;
  if (c.cfg.tagNames === false || depOpenUntil(c, 'stream')) return false;
  const key = tmdbKey(r);
  let s;
  /* 这一轮好几条新请求（请求中心一次提交的）：prefetch 已经一次问完了 */
  const m = c.memo.found;
  if (m && m.keys.has(key)) s = m.s;
  else {
    try { s = await streamSync(c, [], false, [], [key]); }
    catch (e){ if (e.budget) throw e; return false; }
  }
  const w = s && s.found && s.found[key];
  if (!w || (r.src === 'tv' && !w.ready)) return false;
  r.d.dup = 1;
  r.d.item = String(w.path || '').split('/').pop().split('#')[0];
  r.d.kind = w.kind === 'tv' ? 'dir' : 'file';
  r.d.tag = '';                                         // 那份是别的请求的追踪码，这一条不追踪
  r.d.ready = now(); r.d.lib = now();
  if (!w.auto) r.d.home = { path: w.path, at: now() };
  await clog(c, r.id, '片库里已经有了（追踪码 r' + w.code + '，在 ' + w.path + '），不用再下 → 可以播放');
  finish(r, '片库里已有，可以播放');
  return true;
}

async function stQueued(c, r){
  const t = now();
  if (await libHasAlready(c, r)) return;
  if (!r.d.vers || !r.d.versAt || t - r.d.versAt > 6 * HOUR){
    let v;
    try { v = await lbVersions(c, r.src, r.tmdb, r.src === 'tv' ? r.season : 0); }
    catch (e){ if (e.status === 404) return fail(r, '影片库的索引里没有这部片了'); throw e; }
    r.d.vers = (v.items || []).map(x => ({ tid: x.tid, t: String(x.title || '').slice(0, 200), mb: x.mb || 0, size: x.size || '',
      res: x.res || '', labels: (x.labels || []).slice(0, 6), total: x.total || 0 }));
    r.d.versAt = t;
    if (v.title) r.title = v.title;
    if (v.year) r.year = String(v.year);
    if (v.poster) r.poster = v.poster;
  }
  const tried = new Set(r.d.tried || []);
  const v = r.d.vers.find(x => !tried.has(x.tid));
  if (!v) return fail(r, r.d.vers.length ? '所有规格都试过了，没有一个能完整下完' : (r.src === 'tv' ? '影片库里还没有这一季的整季资源' : '影片库里还没有这部片的资源'));
  if (!slotFree(c, 'pk')){
    r.d.wait = 'pk';
    r.note = '排队：PikPak 同时云下载已满（' + c.slots.pk.used + ' / ' + c.slots.pk.max + '），轮到就推送';
    r.next = t + 2 * MIN;
    return;
  }
  delete r.d.wait;
  /* 剧集推进剧集区（2.6，/auto/ram2）：传输 Worker 认得 sub 才这么放，不然照旧放 /auto（之后的调用都按推送时记下的 r.d.sub 走） */
  let sub = r.src === 'tv' ? (await tfCaps(c)).sub : '', parent = '';
  if (sub){
    try { parent = await tvFolder(c, sub); }
    catch (e){
      if (e.budget || e.circuit || transientErr(e)) throw e;
      await clog(c, r.id, '剧集区 /' + (c.env.AUTO_DIR || 'auto') + '/' + sub + ' 建不了（' + String(e.message).slice(0, 80) + '），这一季照旧放 /' + (c.env.AUTO_DIR || 'auto'));
      sub = '';
    }
  }
  if (!sub) parent = await autoFolder(c);
  let j;
  try { j = await lb(c, '/api/pikpush?src=' + r.src, { method: 'POST', body: JSON.stringify({ parent, items: [{ tid: v.tid, name: r.title || '' }] }) }); }
  catch (e){
    if (/文件夹不在了/.test(e.message)){ await kvDel(c.env, 'auto:id'); await kvDel(c.env, 'tv:id'); c.memo.auto = null; c.memo.tv = null; }
    throw e;
  }
  const it = (j.items || [])[0] || {};
  if (it.ok){
    r.d.cur = v; r.d.task = it.task || ''; r.d.file = it.file || ''; r.d.fname = it.fileName || it.name || '';
    if (sub) r.d.sub = sub; else delete r.d.sub;
    await clog(c, r.id, '已推送到 PikPak：' + v.t);
    return go(r, 'download', '已推送到 PikPak，等云下载开始');
  }
  if (j.stop || it.retry){
    r.note = (j.stop || it.err || '影片库这会儿推不了') + '，稍后再试';
    r.next = t + (j.stop ? 15 : 3) * MIN;
    return;
  }
  r.d.tried = [...tried, v.tid];
  await clog(c, r.id, '推不了 ' + v.t + '：' + (it.err || '未知原因'));
  r.note = '这个规格推不了，换下一个';
  r.next = t;
}

async function stDownload(c, r){
  const t = now();
  const tasks = await pkTasks(c);
  const task = r.d.task ? tasks.get(String(r.d.task)) : null;
  if (task){
    if (task.phase === 'PHASE_TYPE_ERROR') return drop(c, r, 'PikPak 云下载失败' + (task.message ? '（' + String(task.message).slice(0, 60) + '）' : ''));
    if (task.file_id && !r.d.file) r.d.file = String(task.file_id);
    if (task.file_name) r.d.fname = String(task.file_name);
    const p = clamp((Number(task.progress) || 0) / 100, 0, 1);
    if (r.d.pmax == null || p > r.d.pmax + 0.001){ r.d.pmax = p; r.d.pat = t; }
    r.pct = p;
    if (t - (r.d.pat || r.since) > LIMIT.dlStall) return drop(c, r, '云下载 2 小时没有进度');
    if (t - r.since > LIMIT.dlMax) return drop(c, r, '云下载 12 小时还没完成');
    r.note = 'PikPak 云下载 ' + Math.round(p * 100) + '%';
    /* 快下完的看勤一点，刚开始的慢慢看（省子请求） */
    r.next = t + (p > 0.9 ? 1 : p > 0.5 ? 2 : 3) * MIN;
    return;
  }
  /* 不在进行中的任务里：要么下完了，要么没了 —— 看文件 */
  if (!r.d.file){
    /* 推送时 PikPak 没回文件编号：按名字在 /auto（剧集在 /auto/ram2）里找 */
    const hit = await kidFind(c, await homeOf(c, r), r.d.fname);
    if (!hit){
      if (t - r.since > 30 * MIN) return drop(c, r, '找不到云下载的任务和文件');
      r.next = t + 2 * MIN; return;
    }
    r.d.file = String(hit.id);
  }
  const f = await pkFile(c, r.d.file);
  if (!f && t - r.since < 10 * MIN){ r.next = t + MIN; return; }     // 刚推送，文件还没建出来
  if (!f || f.trashed) return drop(c, r, '云下载的文件不见了');
  if (f.phase && f.phase !== 'PHASE_TYPE_COMPLETE'){
    if (f.phase === 'PHASE_TYPE_ERROR') return drop(c, r, 'PikPak 云下载失败');
    if (t - r.since > LIMIT.dlMax) return drop(c, r, '云下载 12 小时还没完成');
    r.next = t + MIN; return;
  }
  r.d.fname = String(f.name || r.d.fname || '');
  r.d.fkind = f.kind === 'drive#folder' ? 'dir' : 'file';
  r.d.bytes = Number(f.size) || 0;
  await clog(c, r.id, 'PikPak 云下载完成：' + r.d.fname);
  go(r, r.src === 'tv' ? 'check' : 'clean');
}

/** 清洗 / 改名好了去哪儿（2.6）：开着批量传输、传输 Worker 会批量（或者这会儿还不知道）→ ready 等凑批；
    关了、传输 Worker 是老版本 → 照旧直接传（copy，追踪码在那一步加） */
async function afterPrep(c){
  if (c.cfg.batch === false) return 'copy';
  const caps = await tfCaps(c);
  return caps.known && !caps.batch ? 'copy' : 'ready';
}

/** 电影：最大的视频移到 /auto，原文件夹进回收站。
    2.7：下下来的是文件夹时，挪之前先记下 r.d.file = 挑中的视频、r.d.junk = 原文件夹（这一轮后面哪一下被掐，advance 照样把它们存下），
    然后和「下下来的就是单个视频」走同一条路：不在 /auto 才挪、读回名字、删原文件夹。下一轮从这个视频接着做（已经在 /auto 就不再挪），
    不会再去原文件夹里找（以前那样找 →「文件夹里没有视频」→ 换规格，挪出来的视频留在 /auto 没人管） */
async function stClean(c, r){
  const to = await afterPrep(c);                  // 先定下去哪儿（可能问一次传输 Worker；放在挪文件之前，中途被掐下一轮也能重入）
  const parent = await autoFolder(c);
  let f = await pkFile(c, r.d.file);
  if (!f || f.trashed) return drop(c, r, '云下载的文件不见了');
  let walked = 0;
  if (f.kind === 'drive#folder'){
    const files = await pkWalk(c, String(f.id));
    const vids = files.filter(x => VIDEO_RE.test(x.name) && !SAMPLE_RE.test(x.name)).sort((a, b) => b.size - a.size);
    if (!vids.length) return drop(c, r, '文件夹里没有视频');
    const big = vids[0];
    r.d.junk = String(f.id); r.d.file = String(big.id);
    walked = files.length;
    f = { id: big.id, name: big.name, kind: 'drive#file', parent_id: big.parent, size: big.size };   // 列目录时拿到的，省一次读
  }
  if (!VIDEO_RE.test(f.name || '')) return drop(c, r, '下下来的不是视频文件');
  if (String(f.parent_id || '') !== parent){ await pkMove(c, [String(f.id)], parent); if (c.memo.kids) c.memo.kids.delete(parent); }
  const moved = (await pkFile(c, String(f.id))) || f;
  r.d.item = String(moved.name || f.name); r.d.kind = 'file'; r.d.bytes = Number(moved.size) || Number(f.size) || 0;
  if (r.d.junk){
    /* 删原文件夹：预算用完、熔断、PikPak 抖了 → 往上抛，下一轮再删（视频已经在 /auto，不会再挪）；别的错写进日志接着走 */
    await pkTrash(c, [r.d.junk]).catch(e => { keepTrying(e); return clog(c, r.id, '原文件夹没删掉：' + e.message); });
    delete r.d.junk;
  }
  await clog(c, r.id, walked ? '清洗完成：' + r.d.item + '（' + walked + ' 个文件里最大的）' : '电影文件：' + r.d.item);
  return go(r, to);
}

/** 剧集：整理（删广告垃圾）→ 核对整季 */
async function stCheck(c, r){
  const t = now();
  if (r.d.fkind !== 'dir') return drop(c, r, '下下来的是单个文件，不是整季');
  const dir = r.d.fname;
  if (!r.d.org){
    const o = await tf(c, 'organize', withSub(r, { dir }));
    r.d.org = 1;
    if ((o.deleted || []).length) await clog(c, r.id, '整理：删了 ' + o.deleted.length + ' 个垃圾文件');
  }
  let total = (r.d.cur && r.d.cur.total) || 0;
  if (!total){
    if (r.d.tmdbTotal == null){ const a = await airedCount(c, r.tmdb, r.season || 1); r.d.tmdbTotal = a ? a.aired : 0; r.d.tmdbAll = a ? a.total : 0; }
    total = r.d.tmdbTotal || 0;
  }
  const v = await tf(c, 'check', withSub(r, { dir, total }));
  r.d.check = { k: v.k, total: v.total || 0, vids: v.vids || 0, miss: (v.miss || []).slice(0, 30) };
  r.pct = 0.5;
  if (v.k === 'ok' || v.k === 'unsure'){
    await clog(c, r.id, '整季核对：' + (v.k === 'ok' ? '完整' : '文件数够（集号没全认出）') + '，' + v.vids + ' 个视频 / 共 ' + (v.total || total) + ' 集');
    return go(r, 'rename');
  }
  if (v.k === 'busy'){
    r.d.busySince = r.d.busySince || t;
    if (t - r.d.busySince > LIMIT.busyMax) return drop(c, r, '文件夹里一直有没下完的分段文件');
    r.note = '还有没下完的分段文件，稍等'; r.next = t + 2 * MIN; return;
  }
  if (v.k === 'short') return drop(c, r, '不完整：缺第 ' + (v.miss || []).slice(0, 8).join('、') + ((v.miss || []).length > 8 ? ' 等' : '') + ' 集');
  if (v.k === 'nonvid' || v.k === 'bare') return drop(c, r, '文件夹里没有认得出集号的视频');
  /* skip：标题写着还在连载，或者总集数无从得知 */
  if (v.ongoing) return drop(c, r, '标题写着还在连载，不是整季');
  if (!total && v.vids > 0){
    await clog(c, r.id, '标题和 TMDB 都给不出总集数，按 ' + v.vids + ' 个视频收下');
    return go(r, 'rename');
  }
  return drop(c, r, '核对不了整季（' + v.k + '）');
}

async function stRename(c, r){
  const t = now();
  if (!r.d.job){
    let j;
    try { j = await tf(c, 'rename', withSub(r, { dir: r.d.fname, tpl: c.cfg.tpl, lang: c.cfg.lang, grp: c.cfg.grp }, true)); }
    catch (e){
      /* 上一次改名其实做完了、只是作业记录丢了（VPS 重启）：原名不在了 */
      if (r.d.newname && !transientErr(e) && !e.circuit && !e.budget && /not found|找不到|doesn't exist/i.test(e.message)){ r.d.fname = r.d.newname; return renamed(c, r); }
      /* 910：发行名在 PikPak 上已经有一个了（以前的请求留下的）。不去合并两个文件夹，照原名传（追踪码会让名字不撞） */
      if (e.status === 409 && e.body && e.body.exists){
        await clog(c, r.id, '发行名 ' + (e.body.name || '') + ' 在 PikPak 上已经有了，照原名传');
        r.d.newname = r.d.fname; return renamed(c, r);
      }
      throw e;
    }
    if (j.same){ r.d.newname = r.d.fname; return renamed(c, r); }
    /* 910：上一次其实已经改完了（原名不在、发行名在），jobid 只是确认用的 stat（2.7：不再当作业去问、等 20 秒以上） */
    if (j.done){ r.d.newname = j.name || r.d.newname || r.d.fname; return renamed(c, r); }
    r.d.job = j.jobid; r.d.newname = j.name; r.d.rb = 0; r.d.rbAt = t;
    r.note = '改名为 ' + j.name; r.next = t + 20000;
    return;
  }
  const s = await jobStatus(c, r.d.job);
  if (s.missing){
    /* VPS 重启过，作业没了：重新发一次改名（原名已经不在 = 其实改完了，上面那个分支会接住） */
    r.d.job = 0; r.d.lost = (r.d.lost || 0) + 1;
    await clog(c, r.id, '改名作业没了（VPS 重启过？），重来');
    if (r.d.lost > LIMIT.lostMax) return fail(r, '改名作业一直丢（VPS 反复重启）');
    r.next = t; return;
  }
  if (!s.finished){
    if (s.bytes > (r.d.rb || 0)){ r.d.rb = s.bytes; r.d.rbAt = t; }
    if (t - (r.d.rbAt || r.since) > LIMIT.renameStall){
      await stopJob(c, r.d.job);
      r.d.job = 0; r.d.rtries = (r.d.rtries || 0) + 1;
      await clog(c, r.id, '改名 ' + Math.round(LIMIT.renameStall / MIN) + ' 分钟没有进展，停掉重来');
      if (r.d.rtries >= 3) return fail(r, '改名一直没有进展');
      r.next = t + MIN; return;
    }
    r.pct = s.total ? clamp(s.bytes / s.total, 0, 1) : 0.5; r.next = t + 30000; return;
  }
  r.d.job = 0;
  if (!s.success){
    r.d.rtries = (r.d.rtries || 0) + 1;
    await clog(c, r.id, '改名出错：' + (s.error || '未知'));
    if (r.d.rtries >= 3) return fail(r, '改名失败：' + String(s.error || '').slice(0, 80));
    r.note = '改名出错，重试'; r.next = t + 2 * MIN; return;
  }
  return renamed(c, r);
}
async function renamed(c, r){
  const to = await afterPrep(c);
  r.d.item = r.d.newname || r.d.fname; r.d.kind = 'dir'; r.d.job = 0;
  await clog(c, r.id, '命名：' + r.d.item);
  go(r, to);
}

/** ④ 等待凑批（2.6）：先加追踪码（同一个文件夹一轮只列一次），然后停在这儿，等凑批那一步（batchGate）一起挑走——
    不用每轮都排上。关了批量传输、传输 Worker 不会批量 → 直接去单个传输 */
async function stReady(c, r){
  if (r.d.tag === undefined) await tagItem(c, r);
  const caps = await tfCaps(c);
  if (c.cfg.batch === false || (caps.known && !caps.batch)) return go(r, 'copy');
  r.note = '等待凑批：清洗好的凑够 ' + gateNeed(c.cfg) + ' 部一起传';
  r.next = now() + LIMIT.readyPark;
}

async function stCopy(c, r){
  const t = now();
  /* 批量传输的成员（2.6）：不带自己的作业，进度由批次一起改（batchStep）；排上了也只是再停一会儿 */
  if (r.d.batch){
    const b = c.memo.batch, run = c.memo.copying;
    /* undefined = 这一轮没问成批次（batchStep 出错）：不知道传完没有，先停着，别提前去核对 */
    if (b === undefined || !run){ r.next = t + MIN; return; }
    /* 自己那一批还在 copy（不管是不是正在传的那一批：排在后面、还没开作业的也算）：接着停着 */
    if (run.has(r.d.batch)){
      if (b && b.id !== r.d.batch) r.note = '批量 #' + r.d.batch + ' 排队：等批量 #' + b.id + ' 传完再开';
      r.next = t + LIMIT.memberPark; return;
    }
    /* 那一批已经传完了，这一条没赶上一起去核对（面板刚改过它）：去核对，对不上再单个补传 */
    delete r.d.batch;
    go(r, 'verify', '批量 #' + r.bat + ' 传完了，核对两端');
    r.next = t + LIMIT.verifySettle;
    return;
  }
  if (!r.d.job){
    if (!slotFree(c, 'vps')){
      r.d.wait = 'vps';
      r.note = c.slots.batch ? '排队：批量 #' + c.slots.batch + ' 正在传，等它传完再传'
                             : '排队：VPS 同时传输已满（' + c.slots.vps.used + ' / ' + c.slots.vps.max + '）';
      r.next = t + 2 * MIN;
      return;
    }
    delete r.d.wait;
    /* 第一次传之前给名字加上追踪码（v2.3；2.6 起一般在 ready 那一步就加好了）：之后的传输、核对、删除、发行检查都用新名字 */
    if (r.d.tag === undefined) await tagItem(c, r);
    /* 补传第二次起改从 PikPak 原生接口拿、只按大小判断（WebDAV 列表里没有 / 拿不到的文件；两个后端修改时间对不上） */
    const j = await tf(c, 'copy', withSub(r, r.d.fromPk ? { item: r.d.item, kind: r.d.kind, from: 'pikpak', sizeOnly: 1 } : { item: r.d.item, kind: r.d.kind }));
    if (!j.jobid) throw err('传输没给作业号');
    r.d.job = j.jobid; r.d.cstart = t; r.d.cb = 0; r.d.cbAt = t;
    r.note = r.d.vtries ? '补传到 Dropbox' + (r.d.fromPk ? '（从 PikPak 原生接口）' : '') : '开始传输到 Dropbox'; r.next = t + 30000;
    return;
  }
  const s = await jobStatus(c, r.d.job);
  if (s.missing){
    /* VPS 重启过，作业没了：重新开（rclone copy 会跳过已经传完的文件） */
    r.d.job = 0; r.d.lost = (r.d.lost || 0) + 1;
    await clog(c, r.id, '传输作业没了（VPS 重启过？），从断点重开');
    if (r.d.lost > LIMIT.lostMax) return fail(r, '传输作业一直丢（VPS 反复重启）');
    r.next = t; return;
  }
  if (!s.finished){
    if (s.bytes > (r.d.cb || 0)){ r.d.cb = s.bytes; r.d.cbAt = t; }
    /* 看门狗：一直没有新字节 = 卡住了，停掉重开（copy 跳过已经传完的） */
    if (t - (r.d.cbAt || r.d.cstart || t) > LIMIT.copyStall){
      await stopJob(c, r.d.job);
      r.d.job = 0; r.d.ctries = (r.d.ctries || 0) + 1;
      await clog(c, r.id, '传输 ' + Math.round(LIMIT.copyStall / MIN) + ' 分钟没有进展，停掉重开（第 ' + r.d.ctries + ' 次）');
      if (r.d.ctries >= LIMIT.copyTries) return fail(r, '传输一直没有进展');
      r.next = t + MIN; return;
    }
    const p = s.total ? clamp(s.bytes / s.total, 0, 0.99) : r.pct;
    r.pct = p;
    r.note = '传输到 Dropbox ' + Math.round(p * 100) + '%' + (s.speed ? ' · ' + (s.speed / 1048576).toFixed(1) + ' MB/s' : '');
    r.next = t + MIN;
    return;
  }
  r.d.job = 0;
  if (!s.success){
    r.d.ctries = (r.d.ctries || 0) + 1;
    await clog(c, r.id, '传输出错（第 ' + r.d.ctries + ' 次）：' + (s.error || '未知'));
    if (r.d.ctries >= LIMIT.copyTries) return fail(r, '传输失败：' + String(s.error || '').slice(0, 80));
    r.note = '传输出错，重试'; r.next = t + 2 * MIN; return;
  }
  r.pct = 1;
  go(r, 'verify');
  r.next = now() + LIMIT.verifySettle;          // 两边的目录列表刷新一下再核对
}

const gb = (n) => (Math.max(0, Number(n) || 0) / 1073741824).toFixed(2) + ' GB';
/** 两端核对（用户：「经常触发两端核对不一致，重新传输」）：
    · 列目录失败（传输 Worker 回 502）= 没核对成：抛暂时性错误，过会儿再核对，不补传、不算次数
      （907 的核对把列失败也回成 ok: 0；那种回包里有 src.err / dst.err，一样当没核对成）
    · 第一次不一致：隔 2 分钟再核对一次（刚传完，两边的列表可能还没刷新），还不一致才补传
    · 补传只传缺的 / 大小不对的（rclone copy 跳过已经一样的），第二次起改从 PikPak 原生接口拿
    · Dropbox 那边多出来的不算不一致；补传 3 次还不一致才停下，失败原因写清楚缺了哪些 */
async function stVerify(c, r){
  const t = now();
  /* 批量传输的成员（2.6）：prefetch 一次核对了这一批（batch-verify），回包和单个核对一样，下面照旧逐条判断 */
  const m = r.bat > 0 ? c.memo.verify : null;
  if (m && m.later.has(r.id)){ r.next = t + MIN; return; }
  if (m && m.err.has(r.id)) throw m.err.get(r.id);
  const v = (m && m.res.get(r.id)) || await tf(c, 'verify', withSub(r, { item: r.d.item, kind: r.d.kind }));
  const sideErr = (v.src && v.src.err) || (v.dst && v.dst.err);
  if (sideErr) throw err('核对时列目录失败：' + String(sideErr).slice(0, 100), { net: 1 });
  if (v.ok){
    await clog(c, r.id, '两端核对一致：' + v.src.count + ' 个文件 / ' + gb(v.src.bytes) +
      (v.extra ? '（Dropbox 那边多 ' + v.extra + ' 个，不影响）' : '') + (r.d.vtries ? '，补传 ' + r.d.vtries + ' 次后' : ''));
    delete r.d.vbad;
    return go(r, 'purge');
  }
  const miss = v.missingCount != null ? v.missingCount : (v.missing || []).length;
  const diff = v.differCount != null ? v.differCount : (v.differ || []).length;
  const what = miss || diff
    ? [miss ? '缺 ' + miss + ' 个' : '', diff ? '大小不对 ' + diff + ' 个' : ''].filter(Boolean).join('、')
    : '文件数 ' + (v.src || {}).count + ' / ' + (v.dst || {}).count + '，大小 ' + gb((v.src || {}).bytes) + ' / ' + gb((v.dst || {}).bytes);
  const sample = (v.missing || []).slice(0, 3).concat((v.differ || []).slice(0, 2).map(x => x.path + '（' + x.src + ' → ' + x.dst + '）'));
  r.d.vbad = (r.d.vbad || 0) + 1;
  await clog(c, r.id, '两端核对不一致（' + what + '）' + (sample.length ? '：' + sample.join('，') : '') +
    (r.d.vbad === 1 ? '，2 分钟后再核对一次' : ''));
  if (r.d.vbad === 1){
    r.note = '核对不一致（' + what + '），2 分钟后再核对一次';
    r.next = t + LIMIT.verifyRecheck;
    return;
  }
  r.d.vbad = 0;
  r.d.vtries = (r.d.vtries || 0) + 1;
  if (r.d.vtries > LIMIT.recopyMax) return fail(r, '补传 ' + LIMIT.recopyMax + ' 次后两端还是对不上（' + what + '）');
  r.d.fromPk = r.d.vtries >= 2;
  /* 批量里对不上的（2.6）：离开那一批，走原来一个一个补传的路（那一批的作业已经传完了；别的批在传时排队等） */
  if (r.bat){ await clog(c, r.id, '离开批量 #' + r.bat + '，单个补传'); r.d.rode = r.bat; r.bat = 0; delete r.d.batch; }
  go(r, 'copy', '补传 ' + (miss + diff || '') + (miss + diff ? ' 个文件' : '缺的文件') + (r.d.fromPk ? '（改从 PikPak 原生接口）' : ''));
}

/* ── 追踪码（v2.3）：[auto-m550-r13] / [auto-tv1399s2-r14] ── */
const autoTagOf = (r) => '[auto-' + (r.src === 'tv' ? 'tv' + r.tmdb + 's' + (r.season || 1) : 'm' + r.tmdb) + '-r' + r.id + ']';
const TAG_ANY = /[.\s]*\[?auto-(?:m|tv)\d{1,9}(?:s\d{1,3})?-r\d{1,12}\]?/ig;
/** 名字里加上追踪码：文件加在扩展名前面；名字是空格分隔的用空格，点分隔的用点（旧的追踪码先去掉） */
function withTag(name, tag, kind){
  name = String(name || '').replace(TAG_ANY, '');
  const m = kind === 'file' ? /^(.*?)(\.[A-Za-z0-9]{1,6})$/.exec(name) : null;
  const stem = m ? m[1] : name, ext = m ? m[2] : '';
  const sep = /\s/.test(stem) && !/\./.test(stem) ? ' ' : '.';
  return stem + sep + tag + ext;
}
/** 开始传 Dropbox 之前，在 PikPak 上把这一部改个带追踪码的名字。
    改不成（关了、没填 PikPak、/auto 里找不到、PikPak 拒绝）就照原名传：r.d.tag = ''，不耽误 */
async function tagItem(c, r){
  const tag = autoTagOf(r);
  if (String(r.d.item || '').includes(tag)){ r.d.tag = tag; return; }
  const skip = async (why) => { r.d.tag = ''; await clog(c, r.id, '不加追踪码（' + why + '），照原名传'); };
  if (c.cfg.tagNames === false){ r.d.tag = ''; return; }
  if (!(c.cfg.pkUser && c.cfg.pkPass)) return skip('没填 PikPak 账号');
  /* 剧集区的在 /auto/ram2 里找；这一轮同一个文件夹只列一次（2.6：一批 16 部一起加追踪码） */
  const hit = await kidFind(c, await homeOf(c, r), r.d.item);
  if (!hit) return skip('/' + (c.env.AUTO_DIR || 'auto') + (r.d.sub ? '/' + r.d.sub : '') + ' 里没找到 ' + r.d.item);
  const name = withTag(r.d.item, tag, r.d.kind);
  try { await pkCall(c, 'PATCH', '/drive/v1/files/' + encodeURIComponent(hit.id), { body: { name } }); }
  catch (e){ if (e.budget || e.net || transientErr(e)) throw e; return skip('PikPak：' + e.message); }
  /* 改成了就先记下新名字（2.6：一轮给十几部加追踪码，读回来之前可能就用完了子请求预算；
     下一轮看到名字里已经有追踪码就不再改，不会拿旧名字去找、找不到就照旧名传） */
  r.d.item = name; hit.name = name;
  const back = await pkFile(c, String(hit.id));
  hit.name = String((back && back.name) || name);            // 这一轮列出来的那一份也跟着改名
  r.d.item = String((back && back.name) || name);
  r.d.tag = r.d.item.includes(tag) ? tag : '';
  await clog(c, r.id, r.d.tag ? '加上追踪码：' + r.d.item : '改了名但追踪码没留住：' + r.d.item);
}

/* ── 文件抵达 /auto 自动通过最终审核（v2.4；v2.2 起「片库收录了才算」，现在抵达就算）── */
const autoOn = (c, r) => c.cfg.autoReady !== false && !!r.d.item;
/** 这一轮要不要先一次问完片库：删完 PikPak 的、等审批的 */
const wantsSync = (c, r) => autoOn(c, r) && ((r.stage === 'purge' && !!r.d.purged) || r.stage === 'release');
function finish(r, note){
  r.stage = 'done'; r.since = now(); r.next = 0; r.pct = 1; r.note = note || STAGE_TEXT.done;
}
/** 片库的回答 → 'has' 收录了 · 'off' 片库不收录 /auto（老版本、关了、口令不对）· 'wait' 还没有 / 没问成。
    按名字认，也按追踪码认（名字写法对不上、已经被挪进 ram / ram2 都算；挪走了顺手记下归宿） */
function libVerdict(r, s){
  if (!s || s.err) return 'wait';
  if (s.off) return 'off';
  if (s.has && s.has[r.d.item]) return 'has';
  const w = r.d.tag && s.where && s.where[String(r.id)];
  if (w && (r.d.kind !== 'dir' || w.ready)){
    if (!w.auto && !r.d.home) r.d.home = { path: w.path, at: now() };
    return 'has';
  }
  return 'wait';
}
/** 问片库这一部（顺便让它马上重看一眼 /auto）。这一轮已经一次问过的就用那一份；问不成不算出错 */
async function libCheck(c, r){
  const m = c.memo.sync;
  let s = m && (m.off || m.err || (m.has && r.d.item in m.has)) ? m : null;
  if (!s){
    try { s = await streamSync(c, [r.d.item], r.d.kind === 'dir', r.d.tag ? [String(r.id)] : []); }
    catch (e){ if (e.budget) throw e; s = { err: String(e.message || e) }; }
  }
  return { k: libVerdict(r, s), why: s.why || s.err || '' };
}
/** 文件抵达 /auto（两端核对一致、PikPak 那份删了）：自动通过最终审核 → 可以播放。
    片库当场收录了就完事；还没收录（Dropbox 的列表慢几秒、片库连不上）照样通过，之后每分钟催片库一次（libNudge），
    App 上「立即播放」按下去时也会再催一次。片库不收录 /auto（老版本）也通过，日志写清楚要等工作人员挪进片库才能播放 */
async function autoPass(c, r){
  const { k, why } = await libCheck(c, r);
  r.d.ready = now();
  const moved = r.d.home ? '（工作人员已经挪到 ' + r.d.home.path + '）' : '';
  if (k === 'has'){
    r.d.lib = now();
    await clog(c, r.id, '文件已抵达 /auto，自动通过最终审核；片库已收录 → 可以播放了' + moved);
    return finish(r, '可以播放（自动通过最终审核）');
  }
  finish(r, '自动通过最终审核');
  if (k === 'off'){
    r.d.lib = 'off';
    await clog(c, r.id, '文件已抵达 /auto，自动通过最终审核；但片库不收录 /auto（' + why + '），要等工作人员挪进片库才能播放');
    return;
  }
  r.d.libTries = 0;
  r.next = now() + LIMIT.autoPoll;            // done 的这一条留个 next：libNudge 接着催片库
  await clog(c, r.id, '文件已抵达 /auto，自动通过最终审核；片库还没收录' + (why ? '（' + why.slice(0, 80) + '）' : '') + '，每分钟催一次');
}

/** 自动通过以后片库还没收录的（done、next > 0）：一次问完，收录了就停；前 15 次每分钟，之后每 30 分钟，一天还不行就不催了。
    只改 data / next（不动 updated：App 上的时间不跳） */
async function libNudge(env, c){
  if (depOpenUntil(c, 'stream') || c.n >= c.max - 2) return;
  const d = await db(env);
  const list = ((await d.prepare("SELECT * FROM tj_req INDEXED BY tj_req_stnext WHERE stage = 'done' AND next > 0 AND next <= ? ORDER BY next LIMIT 30")
    .bind(now()).all()).results || []).map(rowOf);
  if (!list.length) return;
  let s;
  try {
    s = await streamSync(c, [...new Set(list.map(r => r.d.item).filter(Boolean))].slice(0, 50), list.some(r => r.d.kind === 'dir'),
                         list.filter(r => r.d.tag).map(r => String(r.id)).slice(0, 50));
  } catch (e){ if (e.budget) throw e; s = { err: String(e.message || e) }; }
  const stmts = [];
  for (const r of list){
    const k = libVerdict(r, s);
    if (k === 'has'){
      r.d.lib = now(); r.next = 0;
      await clog(c, r.id, '片库已收录 → 可以播放了' + (r.d.home ? '（在 ' + r.d.home.path + '）' : ''));
    } else if (k === 'off'){
      r.d.lib = 'off'; r.next = 0;
      await clog(c, r.id, '片库不收录 /auto（' + (s.why || '') + '），要等工作人员挪进片库才能播放');
    } else {
      r.d.libTries = (r.d.libTries || 0) + 1;
      if (now() - (r.d.ready || r.since || 0) > DAY){ r.next = 0; await clog(c, r.id, '片库一天都没收录，不再催（等工作人员挪进片库）'); }
      else r.next = now() + (r.d.libTries < 15 ? LIMIT.autoPoll : 30 * MIN);
    }
    stmts.push(d.prepare('UPDATE tj_req SET data = ?, next = ?, rev = rev + 1 WHERE id = ? AND rev = ?')
      .bind(JSON.stringify(r.d), r.next || 0, r.id, r.rev));
  }
  await d.batch(stmts);
}

async function stPurge(c, r){
  if (!r.d.purged){
    /* 批量传输的成员（2.6）：prefetch 一次删了 8 个（batch-purge），这几条已经记下删了；删失败的照旧退避重来 */
    const m = r.bat > 0 ? c.memo.purge : null;
    if (m && m.later.has(r.id)){ r.next = now() + MIN; return; }
    if (m && m.err.has(r.id)) throw m.err.get(r.id);
    await tf(c, 'purge', withSub(r, { item: r.d.item, kind: r.d.kind }));
    if (r.d.task && c.cfg.pkUser) await pkDelTasks(c, [r.d.task], false).catch(e => { if (e.budget) throw e; });
    r.d.purged = now();
    await clog(c, r.id, '传输完成，PikPak 那份已删：dropbox:' + autoPath(c, r));
  }
  if (autoOn(c, r)) return autoPass(c, r);
  go(r, 'release');
  r.next = now() + LIMIT.releasePoll;
}

async function stRelease(c, r){
  /* 开着「抵达 /auto 自动通过」：等审批的（升级之前进来的、以前片库不收录时停在这儿的）也直接通过 */
  if (autoOn(c, r)) return autoPass(c, r);
  /* 剧集区的（2.6）在 dropbox:auto/ram2 里看：一次问完时放在 tv 里 */
  const batch = r.d.sub ? c.memo.existsTv : c.memo.exists;
  const exists = batch && r.d.item in batch ? batch[r.d.item] : (await tf(c, 'exists', withSub(r, { item: r.d.item }))).exists;
  if (!exists){
    await clog(c, r.id, '已发行（不在 Dropbox 的 /auto 里了）');
    return finish(r);
  }
  r.next = now() + LIMIT.releasePoll;
}

const STAGES = { queued: stQueued, download: stDownload, clean: stClean, check: stCheck, rename: stRename, ready: stReady,
                 copy: stCopy, verify: stVerify, purge: stPurge, release: stRelease };
/** 需要 PikPak 账号的步骤 */
const NEEDS_PK = new Set(['download', 'clean']);

async function advance(c, r){
  const fn = STAGES[r.stage];
  if (!fn) return;
  const before = r.stage;
  /* 要用的依赖在熔断：原地等它恢复（错开一点，免得恢复那一刻一窝蜂） */
  for (const dep of STAGE_DEPS[r.stage] || []){
    const until = depOpenUntil(c, dep);
    if (until){ r.note = DEPS[dep] + '暂时不可用，等它恢复'; r.next = until + Math.floor(Math.random() * 20000); return; }
  }
  if (NEEDS_PK.has(r.stage) && !(c.cfg.pkUser && c.cfg.pkPass)){
    r.note = '等控制面板填 PikPak 账号和密码'; r.next = now() + 5 * MIN; return;
  }
  try {
    await fn(c, r);
    if (r.stage === before && r.d.errs){ r.d.errs = 0; delete r.d.errSince; }
  } catch (e){
    if (e.budget){ r.next = now(); return; }
    if (e.circuit){ r.note = String(e.message); r.next = (e.until || now() + 2 * MIN) + Math.floor(Math.random() * 20000); return; }
    if (e.bug){ await clog(c, r.id, '内部状态出错：' + e.message); return fail(r, '内部状态出错：' + e.message); }
    const transient = transientErr(e) || !!e.cool;
    r.d.errs = (r.d.errs || 0) + 1;
    r.d.errSince = r.d.errSince || now();
    r.note = String(e.message || e).slice(0, 160);
    await clog(c, r.id, STAGE_TEXT[r.stage] + ' 出错（第 ' + r.d.errs + ' 次）：' + r.note);
    if (e.conf){ r.next = now() + 10 * MIN; return; }
    if (!transient && r.d.errs >= LIMIT.stepErrors) return fail(r, STAGE_TEXT[r.stage] + '一直出错：' + r.note);
    if (transient && now() - r.d.errSince > LIMIT.depGiveUp) return fail(r, STAGE_TEXT[r.stage] + '：依赖一天都连不上，停下等人处理（' + r.note + '）');
    /* 退避：2、4、8…30 分钟（暂时性的减半），带 ±15% 抖动 */
    const mins = Math.min(30, 2 ** Math.min(r.d.errs, 5)) / (transient ? 2 : 1);
    r.next = now() + Math.round(mins * MIN * (0.85 + Math.random() * 0.3));
  }
}

/* ══════════════════════════════════════════════════════════════════
   智能队列
   · 先把开了头的做完：发行检查 / 删 PikPak / 核对 > 传输 > 改名 / 清洗 > 云下载 > 排队中的
     （越往后的一步越早腾出 PikPak 和 VPS 的位子，整条流水线就不会堵在中间）
   · 排队中的按「这个人的第几个」打散：每个人的第一个先上，一个人连点五部不会把别人挤到后面
   · 同一档里人多的（好几个人在等）优先，再按到期时间、先来后到
   · 资源位：PikPak 同时云下载、VPS 同时传输各有上限（面板里调），满了排队等，不算出错
   · 批量：这一轮要问的 rclone 作业一次问完（/api/link/jobs），要看的发行检查列一次目录（/api/link/exists）
   ══════════════════════════════════════════════════════════════════ */
const STAGE_PRI = { purge: 9, verify: 8, release: 7, copy: 6, ready: 5, rename: 5, check: 4, clean: 4, download: 3, queued: 1 };
function schedule(rows){
  const list = rows.map(rowOf);
  const seen = new Map();
  for (const r of list.filter(r => r.stage === 'queued').sort((a, b) => (a.created || 0) - (b.created || 0))){
    const u = r.users[0] || '';
    const k = seen.get(u) || 0;
    r._fair = k; seen.set(u, k + 1);
  }
  /* 最后按编号（2.6）：请求中心一次提交的 created 都一样，以前靠 D1 按 next 索引回来的顺序（同一时刻的按编号），
     加了 stage 索引以后 D1 可能换一个索引、回来的顺序跟着变；写明白，不看 D1 挑哪个索引 */
  return list.sort((a, b) => (STAGE_PRI[b.stage] || 0) - (STAGE_PRI[a.stage] || 0)
    || (a._fair || 0) - (b._fair || 0)
    || b.users.length - a.users.length
    || (a.next || 0) - (b.next || 0)
    || (a.created || 0) - (b.created || 0)
    || a.id - b.id);
}
async function loadSlots(c){
  const rows = (await (await db(c.env)).prepare("SELECT stage, data FROM tj_req WHERE stage IN ('download', 'copy')").all()).results || [];
  let pk = 0, vps = 0;
  for (const x of rows){
    if (x.stage === 'download'){ pk++; continue; }
    try { if ((JSON.parse(x.data || '{}') || {}).job) vps++; } catch {}
  }
  /* batch = 正在传的那一批（2.6，batchStep 填）：它一个作业占着 VPS */
  c.slots = { pk: { used: pk, max: c.cfg.pkSlots || CFG_DEF.pkSlots }, vps: { used: vps, max: c.cfg.vpsSlots || CFG_DEF.vpsSlots }, batch: 0 };
  return c.slots;
}
/** 这一轮要问的东西先一次问完：批量的核对和删除（2.6）、rclone 作业（传输 / 改名）、发行检查、片库收录、新请求查重。
    老版本传输 Worker 没有批量接口就退回一个一个问。删 PikPak 放在问片库之前：这一轮刚删完的也一起问（不然 16 条各问一次） */
async function prefetch(c, list){
  if (!depOpenUntil(c, 'vps')){
    await prefetchVerify(c, list);
    await prefetchPurge(c, list);
    const ids = [...new Set(list.filter(r => (r.stage === 'copy' || r.stage === 'rename') && r.d.job).map(r => r.d.job))];
    if (ids.length > 1){
      try { c.memo.jobs = (await tf(c, 'jobs', { ids: ids.slice(0, 12) })).jobs || null; }
      catch (e){ if (e.budget) throw e; }
    }
    /* 发行检查：电影在 dropbox:auto，剧集区的（2.6）放在 tv 里，传输 Worker 910 一起列 dropbox:auto/ram2 */
    const rel = list.filter(r => r.stage === 'release' && r.d.item);
    if (rel.length > 1){
      const items = [...new Set(rel.filter(r => !r.d.sub).map(r => r.d.item))].slice(0, 200);
      const tv = [...new Set(rel.filter(r => r.d.sub).map(r => r.d.item))].slice(0, 200);
      try {
        const j = await tf(c, 'exists', tv.length ? { items, tv } : { items });
        c.memo.exists = j.exists || null;
        c.memo.existsTv = tv.length ? (j.tv || null) : null;
      } catch (e){ if (e.budget) throw e; }
    }
  }
  /* 等片库收录的：一次问完（老版本片库回 off，这几条以后都不再问） */
  const want = list.filter(r => wantsSync(c, r));
  if (want.length > 1 && !depOpenUntil(c, 'stream')){
    try { c.memo.sync = await streamSync(c, [...new Set(want.map(r => r.d.item))].slice(0, 50), want.some(r => r.d.kind === 'dir'),
                                         want.filter(r => r.d.tag).map(r => String(r.id)).slice(0, 50)); }
    catch (e){ if (e.budget) throw e; c.memo.sync = { err: String(e.message || e) }; }
  }
  /* 新请求先核对片库（v2.5）：请求中心一次提交了好几条的，一次问完 */
  const fresh = list.filter(r => r.stage === 'queued' && r.d.dup === undefined);
  if (fresh.length > 1 && c.cfg.tagNames !== false && !depOpenUntil(c, 'stream')){
    const keys = [...new Set(fresh.map(tmdbKey))].slice(0, 50);
    let s;
    try { s = await streamSync(c, [], false, [], keys); }
    catch (e){ if (e.budget) throw e; s = { err: String(e.message || e) }; }
    c.memo.found = { keys: new Set(keys), s };
  }
}
/** 批量的成员到了核对（2.6）：一批一次 batch-verify（一轮最多问两批），回包按 sub/名字 分给每一条；
    VPS 抖了 = 这几条都没核对成（照旧当暂时性错误）；老版本没有这个接口 = 退回一个一个核对 */
async function prefetchVerify(c, list){
  const groups = new Map();
  for (const r of list) if (r.stage === 'verify' && r.bat > 0 && r.d.item){
    if (!groups.has(r.bat)) groups.set(r.bat, []);
    groups.get(r.bat).push(r);
  }
  if (!groups.size) return;
  const m = c.memo.verify = { res: new Map(), err: new Map(), later: new Set() };
  let calls = 0;
  for (const rows of groups.values()){
    for (let i = 0; i < rows.length; i += LIMIT.batchMax){
      const part = rows.slice(i, i + LIMIT.batchMax);
      if (calls >= 2){ for (const r of part) m.later.add(r.id); continue; }
      calls++;
      try {
        const j = await tf(c, 'batch-verify', { items: part.map(bItem) });
        for (const r of part){ const v = j.results && j.results[bKey(r)]; if (v) m.res.set(r.id, v); }
      } catch (e){
        if (e.budget) throw e;
        if (e.circuit || transientErr(e)) for (const r of part) m.err.set(r.id, err('核对时列目录失败：' + String(e.message).slice(0, 100), { net: 1 }));
      }
    }
  }
}
/** 批量的成员到了删 PikPak（2.6）：8 个一次 batch-purge（一轮最多两次），删掉的云下载任务一次删完；
    这几条记下已删，后面的自动通过 / 问片库照旧（问片库也是一次问完） */
async function prefetchPurge(c, list){
  const rows = list.filter(r => r.stage === 'purge' && r.bat > 0 && !r.d.purged && r.d.item);
  if (!rows.length) return;
  const m = c.memo.purge = { err: new Map(), later: new Set() };
  const tasks = [];
  for (let i = 0; i < rows.length; i += 8){
    const part = rows.slice(i, i + 8);
    if (i >= 16){ for (const r of part) m.later.add(r.id); continue; }
    let j;
    try { j = await tf(c, 'batch-purge', { items: part.map(bItem) }); }
    catch (e){
      if (e.budget) throw e;
      if (e.circuit || transientErr(e)) for (const r of part) m.err.set(r.id, e);
      continue;                                       // 别的错（老版本没有这个接口）：这几条退回一个一个删
    }
    for (const r of part){
      const x = j.results && j.results[bKey(r)];
      if (!x) continue;
      if (x.error){ m.err.set(r.id, err('删 PikPak 那份失败：' + String(x.error).slice(0, 120))); continue; }
      r.d.purged = now();
      if (r.d.task) tasks.push(r.d.task);
      await clog(c, r.id, '传输完成，PikPak 那份已删' + (x.gone ? '（已经不在了）' : '') + '：dropbox:' + autoPath(c, r));
    }
  }
  if (tasks.length && c.cfg.pkUser) await pkDelTasks(c, tasks, false).catch(e => { if (e.budget) throw e; });
}
/** App 看得到的那几项（2.7）：阶段、第几步、百分比、片名、年份、海报、在哪一批。只有这些变了才动 updated——
    App 的 /app/requests 按正文算 ETag（updated 也在里面），以前每存一次都改成现在，等着的那几条（下载中每 1–3 分钟、
    排队等位子每 2 分钟、等凑批每 10 分钟、批量成员每 15 分钟）一存 ETag 就变，App 拿不到 304 */
function appSig(r){
  const v = view(r);
  return [v.stage, v.step, v.pct, v.title, v.year, v.poster, v.batch || 0].join('\u0001');
}
/** 不写 users（2.7）：一轮里从不改 users，写的话会拿这一轮开头读到的旧名单把中途跟上的人盖掉——以前靠跟上时 rev + 1 挡住，
    代价是这一轮推进完的那条（已经挪了文件、开了传输）存不进去，下一轮重做一遍。
    updated：r.touch === false（这一轮推进了、App 看到的没变）就留着库里的（CASE 用的是库里那一行，中途跟上改的也不会被盖回去） */
function saveStmt(d, r){
  return d.prepare(
    `UPDATE tj_req SET title = ?, year = ?, poster = ?, stage = ?, pct = ?, note = ?, data = ?, updated = CASE WHEN ? THEN ? ELSE updated END,
       since = ?, next = ?, bat = ?, rev = rev + 1 WHERE id = ? AND rev = ?`)
    .bind(r.title || '', r.year || '', r.poster || '', r.stage, +r.pct || 0, r.note || '',
          JSON.stringify(r.d || {}), r.touch === false ? 0 : 1, now(), r.since || now(), r.next || 0, r.bat || 0, r.id, r.rev);
}
/** 攒着的请求更新和日志一次写进 D1（一个事务）。rev 对不上的那条（面板刚改过）不写，面板赢。
    写失败（2.7）：放回缓冲里再往上抛，一轮收尾的那次 flush 再写一遍（D1 的 batch 是一个事务：失败 = 一条都没写进去；
    其实写进去了、只是回答丢了的，rev 已经变了，再写一遍什么都不改）。以前先清空缓冲，那一批写失败，这几条已经开的作业、
    挪过的文件就丢了，下一轮再做一遍 */
async function flush(c){
  if (!(c.pending && c.pending.length) && !(c.logs && c.logs.length)) return [];
  const d = await db(c.env);
  const rs = c.pending || [], logs = c.logs || [];
  c.pending = []; c.logs = [];
  const stmts = rs.map(r => saveStmt(d, r))
    .concat(logs.map(([rid, at, msg]) => d.prepare('INSERT INTO tj_log (rid, at, msg) VALUES (?, ?, ?)').bind(rid, at, msg)));
  let res;
  try { res = await d.batch(stmts); }
  catch (e){ c.pending = rs.concat(c.pending || []); c.logs = logs.concat(c.logs || []); throw e; }
  return rs.map((r, i) => { const ok = !!(res[i] && res[i].meta && res[i].meta.changes); if (ok) r.rev++; return { id: r.id, ok }; });
}

/* ══════════════════════════════════════════════════════════════════
   批量传输（2.6）：清洗好的凑够一批（默认 16 部），一个 rclone 作业一起传（16 路并行传输、16 路并发核对）
   · 一批一行 tj_batch：items = 成员，data = 作业号、字节数、看门狗。stage：copy（作业在跑）→ verify → purge → done
   · 一次只跑一批：作业在跑的时候不开下一批，单个传输（补传、老路）一律排队（rclone 的内存）；
     单个传输还在跑也不开批，等它们传完
   · 作业的 key = 批次编号：开作业时 VPS 抖了、这边超时了，下一轮同一个 key 再开，传输 Worker 认出正在跑的那个（reused）
   · 成员停在 copy，不带自己的作业号、不用每轮都排上（next 往后放）；每轮问一次作业进度，成员的百分比一条 SQL 一起改
   · 看门狗在批次上：一小时没有新字节停掉重开（rclone 跳过传完的），作业丢了从断点重开；开不了批量（老版本、
     rclone 不认筛选规则 409 nofilter）→ 这一批的成员退回一个一个传
   · 传完（成功或者出错都一样）：成员一起去核对，一条一条判断，对不上的单个补传，一致的一起删 PikPak
   ══════════════════════════════════════════════════════════════════ */
function batchOf(x){
  let items = [], d = {};
  try { items = JSON.parse(x.items || '[]') || []; } catch {}
  try { d = JSON.parse(x.data || '{}') || {}; } catch {}
  return { ...x, items, d };
}
async function saveBatch(c, b){
  b.updated = now();
  await (await db(c.env)).prepare('UPDATE tj_batch SET stage = ?, items = ?, data = ?, updated = ?, ended = ?, rev = rev + 1 WHERE id = ?')
    .bind(b.stage, JSON.stringify(b.items || []), JSON.stringify(b.d || {}), b.updated, b.ended || 0, b.id).run();
}
/** 作业进度里给面板 / App 看的那几项（910 的 job {detail:1}；老字段没有就是 0） */
const liveOf = (s) => ({ bytes: Number(s.bytes) || 0, total: Number(s.total) || 0, speed: Number(s.speed) || 0,
  eta: s.eta == null ? null : Math.max(0, Math.round(Number(s.eta) || 0)), done: Number(s.transfers) || 0, files: Number(s.totalTransfers) || 0,
  errors: Number(s.errors) || 0 });
/** 这一批传了多少：分母用开批时试列出来的总字节（rclone 的 totalBytes 一边核对一边涨，进度条会往回跳） */
function batchPct(b, live){
  const l = live || b.d.live || {};
  const total = b.d.total || l.total || 0;
  return total ? clamp((l.bytes || 0) / total, 0, 0.99) : 0;
}
/** 给成员、App、面板看的进度只往前走（2.7）：重开以后（看门狗停掉、作业丢了）rclone 新的一组从 0 算起、只算还缺的，
    按上面那样算会从 60% 跳回 5%。记下到过的最大值（b.d.pmax，batchStep 每轮更新），新的一组追上来之前进度条停着；
    字节数跟着折算（App 按 bytes / total 和速度往前推算进度条） */
function batchShown(b, live){
  const l = live || b.d.live || {};
  const total = b.d.total || l.total || 0;
  const pct = Math.max(b.d.pmax || 0, batchPct(b, l));
  return { pct, bytes: Math.max(l.bytes || 0, Math.round(pct * total)), total };
}
const gateNeed = (cfg) => clamp(cfg.batchMin || CFG_DEF.batchMin, 1, clamp(cfg.batchMax || CFG_DEF.batchMax, 1, LIMIT.batchMax));
/** 最早的一部最多等多久：请求中心提交的按面板设的（默认 30 分钟），老版本 App 一部一部提交的（bid = 0）最多 10 分钟 */
const waitOf = (cfg, bid) => { const w = (cfg.batchWait || CFG_DEF.batchWait) * MIN; return bid > 0 ? w : Math.min(w, LIMIT.oldWait); };

/** 每轮开头：问一次正在传的那一批（一个作业），传完的成员一起去核对；传完了的批次看看成员都核对、删完了没有 */
async function batchStep(c){
  const d = await db(c.env);
  /* 在 copy 的批次单独查（一般就一批）。以前和收尾中的一起取最早的 20 批：收尾中的一多（成员删 PikPak 一直出错、退避好几个小时），
     正在传的那一批（编号最大）就被挤出去了，这一轮当它不存在——又开一批、单个传输也开了、作业没人问、成员提前去核对 */
  const runs = ((await d.prepare("SELECT * FROM tj_batch WHERE ended = 0 AND stage = 'copy' ORDER BY id").all()).results || []).map(batchOf);
  const b = runs[0] || null;
  /* 排在后面、也在 copy 的（以前面板「推进一轮」和定时任务撞上时可能开出第二批）：不动，成员一直停着，
     等前面那一批传完再轮到它（batchNext） */
  c.memo.runs = runs; c.memo.copying = new Set(runs.map(x => x.id));
  c.memo.batch = b; c.slots.batch = b ? b.id : 0;
  /* 传完了的批次：看成员走到哪儿了。一条 SQL 数完每一批（几批都一样，不受一条语句 100 个参数的限制，也不会只看最早的几批） */
  const rest = (await d.prepare(`SELECT b.*, SUM(CASE WHEN r.stage IN ('copy', 'verify') THEN 1 ELSE 0 END) AS nv,
      SUM(CASE WHEN r.stage = 'purge' THEN 1 ELSE 0 END) AS np
      FROM tj_batch b LEFT JOIN tj_req r ON r.bat = b.id AND r.stage IN ('copy', 'verify', 'purge')
      WHERE b.ended = 0 AND b.stage != 'copy' GROUP BY b.id ORDER BY b.id`).all()).results || [];
  for (const x of rest){
    const st = x.nv ? 'verify' : x.np ? 'purge' : 'done';
    if (st === x.stage) continue;
    const y = batchOf(x);
    y.stage = st;
    if (st === 'done'){ y.ended = now(); await clog(c, 0, '批量 #' + y.id + ' 收尾：成员都核对、删完了（或者退回单个补传、取消了）'); }
    await saveBatch(c, y);
  }
  if (!b || depOpenUntil(c, 'vps')) return;
  /* 还没开成（上一轮 VPS 抖了）/ 停掉重开 / 作业丢了：同一个 key 再开 */
  if (!b.d.job) return batchLaunch(c, b);
  let s;
  try { s = await tf(c, 'job', { jobid: b.d.job, detail: 1 }); }
  catch (e){
    if (e.budget) throw e;
    if (e.circuit || transientErr(e)) return;          // VPS 抖了：下一轮再问
    s = { finished: true, success: false, error: e.message };
  }
  const t = now();
  if (s.missing){
    b.d.job = 0; b.d.lost = (b.d.lost || 0) + 1;
    await clog(c, 0, '批量 #' + b.id + ' 的传输作业没了（VPS 重启过？），下一轮从断点重开');
    if (b.d.lost > LIMIT.lostMax) return batchDone(c, b, { success: false, error: '传输作业一直丢（VPS 反复重启）' });
    return saveBatch(c, b);
  }
  if (!s.finished){
    const live = liveOf(s);
    if (live.bytes > (b.d.cb || 0)){ b.d.cb = live.bytes; b.d.cbAt = t; }
    /* 看门狗：一直没有新字节 = 卡住了，停掉重开（rclone copy 跳过已经传完的） */
    if (t - (b.d.cbAt || b.d.started || t) > LIMIT.copyStall){
      await stopJob(c, b.d.job);
      b.d.job = 0; b.d.ctries = (b.d.ctries || 0) + 1; b.d.cb = 0;
      await clog(c, 0, '批量 #' + b.id + ' 传输 ' + Math.round(LIMIT.copyStall / MIN) + ' 分钟没有进展，停掉重开（第 ' + b.d.ctries + ' 次）');
      if (b.d.ctries >= LIMIT.copyTries) return batchDone(c, b, { success: false, error: '传输一直没有进展' });
      return saveBatch(c, b);
    }
    b.d.live = { ...live, at: t };
    const p = b.d.pmax = Math.max(b.d.pmax || 0, batchPct(b, live));      // 只往前走（2.7，见 batchShown）
    await saveBatch(c, b);
    /* 成员的进度一条 SQL 一起改：往前走了 0.5% 以上才改（2.7：只往前，重开以后不往回跳）；
       updated 只在 App 上的百分比（第 4 步：60 + 18 × 进度，取整）变了才动，App 的 ETag 不白变 */
    await d.prepare(`UPDATE tj_req SET pct = ?, note = ?, updated = CASE WHEN ROUND(60 + 18 * pct) < ROUND(60 + 18 * ?) THEN ? ELSE updated END
        WHERE bat = ? AND stage = 'copy' AND pct + 0.005 <= ?`)
      .bind(p, '批量 #' + b.id + ' 传输到 Dropbox ' + Math.round(p * 100) + '%' + (live.speed ? ' · ' + (live.speed / 1048576).toFixed(1) + ' MB/s' : ''),
            p, t, b.id, p).run();
    return;
  }
  return batchDone(c, b, s);
}

/** 开（或者重开）这一批的作业：一次 batch-copy，key = 批次编号 */
async function batchLaunch(c, b){
  const d = await db(c.env);
  /* 这期间被取消 / 删掉 / 面板改过的成员不传了 */
  const rows = ((await d.prepare("SELECT * FROM tj_req WHERE bat = ? AND stage = 'copy'").bind(b.id).all()).results || [])
    .map(rowOf).filter(r => r.d.batch === b.id && r.d.item);
  if (!rows.length){
    b.stage = 'done'; b.ended = now();
    await clog(c, 0, '批量 #' + b.id + '：成员都取消了，不传了');
    batchNext(c, b);
    return saveBatch(c, b);
  }
  b.items = rows.map(r => ({ rid: r.id, ...bItem(r) }));
  /* 上一次开作业的调用可能还没回来：70 秒内不重开（2.7 起一轮拿着租约跑完才还、有截止时刻，两轮不会撞上；留着兜底）。
     作业在跑、作业号没找到（b.d.running）：5 分钟再接一次，不用每隔一轮就让 VPS 在传 16 路的时候再列一遍 */
  if (b.d.tryAt && now() - b.d.tryAt < (b.d.running ? LIMIT.jobless : 70000)) return;
  b.d.tryAt = now();
  await saveBatch(c, b);
  const xfers = clamp(c.cfg.xfers || CFG_DEF.xfers, 1, 16), checkers = clamp(c.cfg.checkers || CFG_DEF.checkers, 1, 16);
  let j;
  try {
    j = await tf(c, 'batch-copy', { key: String(b.id), items: rows.map(bItem), transfers: xfers, checkers });
    /* 910：这一批的那一组在跑、作业号没找到（一般是上一次开作业的回答丢了）→ { jobid: 0, reused, running: 1 }。
       不是出错（2.7）：以前当「没给作业号」，每 70 秒重问一次（VPS 在传 16 路时再列一遍），面板写着出错、App 一直 0%，
       一天后还退回一个一个传，和还在跑的批量作业一起传。现在记成在传，5 分钟后同一个 key 再问（传完了它会开下一组 / 给作业号） */
    if (!j.jobid && j.reused && j.running){
      const t = now(), first = !b.d.started;
      if (!b.d.running) await clog(c, 0, '批量 #' + b.id + '：传输 Worker 说这一批在传，但没找到作业号；先当它在传，' + Math.round(LIMIT.jobless / MIN) + ' 分钟后再接作业号');
      if (first) for (const r of rows) await clog(c, r.id, '批量 #' + b.id + ' 开始传输到 Dropbox（' + rows.length + ' 部一起，' + xfers + ' 路并行）');
      b.d.running = b.d.running || t; b.d.started = b.d.started || t; b.d.tryAt = t;
      delete b.d.err; delete b.d.errSince; b.d.tries = 0;
      return saveBatch(c, b);
    }
    if (!j.jobid) throw err('传输没给作业号', { status: 502, net: 1 });
  } catch (e){
    if (e.budget) throw e;
    const t = now();
    if (e.circuit || transientErr(e)){
      /* VPS 抖了：下一轮同一个 key 再开（正在跑的会被认出来，不会开出两个）。一天都开不了才退回一个一个传 */
      b.d.tries = (b.d.tries || 0) + 1; b.d.err = String(e.message || e).slice(0, 160); b.d.errSince = b.d.errSince || t;
      if (t - b.d.errSince > LIMIT.depGiveUp) return batchSingles(c, b, rows, 'VPS 一天都开不了批量传输');
      return saveBatch(c, b);
    }
    if (e.status === 409 && e.body && e.body.nofilter){
      /* 试列的时候列出了不在这一批里的东西 = rclone 不认筛选规则：一 sync 就会把整个 /auto 传过去。6 小时内都一个一个传 */
      await capsSet(c, { nofilter: now() + 6 * HOUR });
      return batchSingles(c, b, rows, '传输 Worker 的 rclone 不认筛选规则（409 nofilter），这一批改成一个一个传');
    }
    /* 老版本（没有 batch-copy：404 / 400「item 不对」）、这一批里有它不认的名字：退回一个一个传 */
    if (e.status === 404 || (e.status === 400 && /item/i.test(e.message))) await capsSet(c, { caps: ((await kvGet(c.env, 'tf:caps').catch(() => null)) || { caps: [] }).caps.filter(x => x !== 'batch') });
    return batchSingles(c, b, rows, '批量传输开不了（' + String(e.message || e).slice(0, 80) + '），这一批改成一个一个传');
  }
  const t = now(), first = !b.d.job && !b.d.started;
  /* 接上的是同一个作业：字节数接着算（看门狗不重新计时）；新开的作业从 0 算起 */
  if (!j.reused || !b.d.cbAt){ b.d.cb = 0; b.d.cbAt = t; }
  b.d.job = j.jobid; b.d.started = b.d.started || t; b.d.xfers = xfers; b.d.checkers = checkers;
  delete b.d.err; delete b.d.errSince; delete b.d.running;
  if (j.total != null && !(b.d.total > 0)) b.d.total = Number(j.total) || 0;
  if (j.files != null && !(b.d.files > 0)) b.d.files = Number(j.files) || 0;
  await saveBatch(c, b);
  await clog(c, 0, '批量 #' + b.id + (j.reused ? ' 接上了正在跑的传输作业 ' + j.jobid : (first ? ' 开始传输：' : ' 重开传输：') + rows.length + ' 部一起传（' +
    xfers + ' 路并行传输、' + checkers + ' 路并发核对' + (b.d.total ? '，共 ' + gb(b.d.total) : '') + '）'));
  if (first) for (const r of rows) await clog(c, r.id, '批量 #' + b.id + ' 开始传输到 Dropbox（' + rows.length + ' 部一起，' + xfers + ' 路并行）');
}

/** 这一批开不了 / 一直开不成：成员退回一个一个传（还在 copy，下一轮照单个传输排队），这一批收尾 */
async function batchSingles(c, b, rows, why){
  const t = now();
  for (const r of rows){
    delete r.d.batch; r.bat = 0; r.next = t; r.note = '退回单个传输';
    await clog(c, r.id, why);
    c.pending.push(r);
  }
  b.stage = 'done'; b.ended = t; b.d.off = why; b.d.job = 0;
  await clog(c, 0, '批量 #' + b.id + '：' + why);
  batchNext(c, b);
  await saveBatch(c, b);
}

/** 作业跑完了（成功、出错、看门狗放弃都一样）：成员一起去核对（一条一条判断，对不上的单个补传）。
    这期间取消了的：不核对、不删，日志写清楚它传到 Dropbox 的那份留在原处 */
async function batchDone(c, b, s){
  const d = await db(c.env);
  const rows = ((await d.prepare('SELECT * FROM tj_req WHERE bat = ?').bind(b.id).all()).results || []).map(rowOf);
  const t = now();
  let n = 0;
  for (const r of rows){
    if (r.stage === 'copy' && r.d.batch === b.id){
      delete r.d.batch; r.d.ctries = 0;
      go(r, 'verify', '批量 #' + b.id + ' 传完，等两边的列表刷新一下再核对');
      r.next = t + LIMIT.verifySettle;
      await clog(c, r.id, '批量 #' + b.id + (s.success ? ' 传完' : ' 的作业出错（' + String(s.error || '未知').slice(0, 80) + '），照样核对，缺的单个补传') + ' → 核对两端');
      c.pending.push(r); n++;
    } else if (r.stage === 'cancelled'){
      await clog(c, r.id, '批量 #' + b.id + ' 传完了：这一条已经取消，不核对、不删；它传到 Dropbox 的那份留在原处（dropbox:' + autoPath(c, r) + '）');
    }
  }
  b.d.job = 0; b.d.fin = t; b.d.ok = s.success ? 1 : 0;
  if (!s.success) b.d.err = String(s.error || '').slice(0, 160);
  else if (b.d.total) b.d.live = { ...(b.d.live || {}), bytes: b.d.total, at: t };
  b.stage = n ? 'verify' : 'done';
  if (!n) b.ended = t;
  await clog(c, 0, '批量 #' + b.id + (s.success ? ' 传完' : ' 传输出错（' + String(s.error || '未知').slice(0, 80) + '）') + '：' + n + ' 部去核对');
  batchNext(c, b);
  await saveBatch(c, b);
}
/** 这一批不在 copy 了（传完、退回单个传输、成员都取消了）：排在后面、也在 copy 的下一批接着占着 VPS（下一轮开它的作业），
    这一轮不凑新的一批、单个补传也接着等；一批都没有了才腾出来。以前这里直接清空，下一批还没开就又凑出一批，两个作业一起跑 */
function batchNext(c, b){
  const run = c.memo.copying;
  if (run) run.delete(b.id);
  const next = (c.memo.runs || []).find(x => x.id !== b.id && run && run.has(x.id)) || null;
  c.memo.batch = next; c.slots.batch = next ? next.id : 0;
}

/** 凑批：等着的（ready、加好了追踪码）凑够了就开一批。凑不满也不干等：
    · 最早的一部等了 batchWait（老版本 App 一部一部提交的 10 分钟）
    · 前面没有还会清洗好的了（下载 / 清洗中的都在长时间退避，或者根本没有）
    · 等着的这几次提交（bid），每一部都清洗好了或者结束了
    VPS 熔断中、有一批在传、单个传输还在跑或者在排队（批量里对不上的补传先传完，不然一批接一批开，它们一直排不上）：不开。
    关了批量 / 传输 Worker 不会批量：等着的直接去单个传输 */
async function batchGate(c){
  /* batch === undefined = 这一轮没问成在传的批次（batchStep 出错）：不知道有没有一批在传，不开 */
  if (c.memo.gated || c.memo.batch || c.memo.batch === undefined) return;
  const cfg = c.cfg, d = await db(c.env), t = now();
  const all = ((await d.prepare("SELECT * FROM tj_req WHERE stage = 'ready' ORDER BY since, id LIMIT 200").all()).results || []).map(rowOf);
  const ready = all.filter(r => r.d.tag !== undefined);
  c.memo.gateSaw = ready.length;                     // 一个加好追踪码的都没有：这一轮末尾不用再来一次（除非这一轮刚加好）
  if (!ready.length || depOpenUntil(c, 'vps')) return;
  const caps = await tfCaps(c);
  if (cfg.batch === false || (caps.known && !caps.batch)){
    const why = cfg.batch === false ? '批量传输关了' : '传输 Worker 不会批量传输（老版本，或者 rclone 不认筛选规则）';
    for (const r of ready.slice(0, LIMIT.perTick)){ go(r, 'copy'); await clog(c, r.id, why + '：直接传'); c.pending.push(r); }
    c.memo.gated = 1;
    return;
  }
  if (!caps.known || c.slots.vps.used > 0 || c.n > c.max - 3) return;
  /* 排着队的单个传输（补传、老路的；长时间退避的不算）：等它们先传完。
     +bat：别用 bat 的索引（bat = 0 差不多是整张表），走 stage 的 */
  const solo = await d.prepare("SELECT COUNT(*) AS n FROM tj_req WHERE stage = 'copy' AND +bat = 0 AND next <= ?").bind(t + LIMIT.stuck).first();
  if (solo && solo.n) return;
  const why = await gateWhy(c, all, ready);
  if (!why) return;
  const max = clamp(cfg.batchMax || CFG_DEF.batchMax, 1, LIMIT.batchMax);
  const pick = ready.slice().sort((a, b) => (a.since || 0) - (b.since || 0) || b.users.length - a.users.length || a.id - b.id).slice(0, max);
  /* 一次只跑一批，在库里也挡住：已经有一批在 copy 就不插（2.6 的面板「推进一轮」不拿租约，和定时任务撞上时两边都走到这儿；
     2.7 起面板也拿租约，这里留着兜底） */
  const res = await d.prepare(`INSERT INTO tj_batch (stage, items, data, created, updated) SELECT ?, ?, ?, ?, ?
      WHERE NOT EXISTS (SELECT 1 FROM tj_batch WHERE ended = 0 AND stage = 'copy')`)
    .bind('copy', JSON.stringify(pick.map(r => ({ rid: r.id, ...bItem(r) }))), JSON.stringify({ why }), t, t).run();
  if (!(res.meta && res.meta.changes)){
    /* 另一边刚开了一批：这一轮不开，也当它在传（单个传输接着排队，那一批的成员停着） */
    const x = await d.prepare("SELECT * FROM tj_batch WHERE ended = 0 AND stage = 'copy' ORDER BY id LIMIT 1").first();
    if (x){ const o = batchOf(x); c.memo.runs.push(o); c.memo.copying.add(o.id); c.memo.batch = o; c.slots.batch = o.id; }
    c.memo.gated = 1;
    return;
  }
  const id = res.meta.last_row_id;
  for (const r of pick){
    go(r, 'copy', '批量 #' + id + '：开始传输');
    r.bat = id; r.d.batch = id; r.next = t + LIMIT.memberPark;
    await clog(c, r.id, '凑批：进批量 #' + id + '（' + pick.length + ' 部一起传，' + why + '）');
    c.pending.push(r);
  }
  await flush(c);                                    // 先记下成员，再开作业（开了作业没记下来，下一轮同一个 key 再开也不会开出两个）
  const b = batchOf({ id, stage: 'copy', items: '[]', data: JSON.stringify({ why }), created: t, updated: t, ended: 0 });
  c.memo.runs.push(b); c.memo.copying.add(id);
  c.memo.batch = b; c.slots.batch = id; c.memo.gated = 1;
  c.memo.launch = { id, items: pick.length, why };
  await clog(c, 0, '凑批：批量 #' + id + '，' + pick.length + ' 部（' + why + '）');
  await batchLaunch(c, b);
}
async function gateWhy(c, all, ready){
  const cfg = c.cfg, t = now(), need = gateNeed(cfg);
  if (ready.length >= need) return '凑够 ' + need + ' 部';
  const late = ready.find(r => t - (r.since || t) >= waitOf(cfg, r.bid));
  if (late) return '最早的一部等了 ' + Math.round((t - late.since) / MIN) + ' 分钟';
  const up = (await (await db(c.env)).prepare(`SELECT bid, COUNT(*) AS n, SUM(CASE WHEN next > ? THEN 1 ELSE 0 END) AS stuck
      FROM tj_req WHERE stage IN (${UPSTREAM.map(() => '?').join(',')}) GROUP BY bid`).bind(t + LIMIT.stuck, ...UPSTREAM).all()).results || [];
  /* 刚进 ready、下一轮才加追踪码的也算「还会清洗好的」（不然差一部凑满的时候先开了一批小的） */
  const untagged = all.filter(r => r.d.tag === undefined);
  if (!untagged.length && !up.some(x => x.n > (x.stuck || 0))) return '前面没有还会清洗好的了';
  /* 还没清洗好的（下载 / 清洗中，或者刚进来还没加追踪码）属于哪几次提交 */
  const open = new Set(up.map(x => x.bid).concat(untagged.map(r => r.bid)));
  const bids = [...new Set(ready.map(r => r.bid).filter(x => x > 0))];
  if (bids.length && bids.every(x => !open.has(x))) return '这' + (bids.length > 1 ? '几' : '一') + '次提交的都清洗好了';
  return '';
}
/** 凑批进度（App 的 /app/flow、我的请求里 ready 那几条的 wait、面板）：等着几部、要几部、最早的什么时候进来、最晚什么时候开 */
async function gateInfo(env, cfg){
  const w = (cfg.batchWait || CFG_DEF.batchWait) * MIN;
  const g = await (await db(env)).prepare(`SELECT COUNT(*) AS n, MIN(since) AS oldest, MIN(since + CASE WHEN bid > 0 THEN ? ELSE ? END) AS lb
      FROM tj_req WHERE stage = 'ready'`).bind(w, Math.min(w, LIMIT.oldWait)).first();
  const out = { ready: (g && g.n) || 0, need: gateNeed(cfg) };
  if (out.ready){ out.oldest = g.oldest || 0; if (out.ready < out.need) out.launchBy = g.lb || 0; }
  return out;
}

/** 就绪以后接着追踪追踪码（v2.3）：工作人员把它挪去哪儿了。30 分钟一轮，一次问完（最多 40 条），最多追 30 天。
    只改 data（不动 updated：App 上「最近」的时间不跳）；哪儿都找不到连着 trackLost 次（改了名 / 删了）就不追了 */
async function trackHomes(env, c){
  if (c.cfg.tagNames === false || depOpenUntil(c, 'stream') || c.n >= c.max - 2) return;
  if (!(await lease(env, 'track', LIMIT.trackEvery - 30000))) return;
  const d = await db(env);
  /* 往后翻（2.7）：游标存在 tj_kv 的 track:cur（结束时刻 since + 编号），一次 40 条，不满 40 条就从头再来。
     以前每次挑最新的 40 条（按 updated），还在 /auto 的不写，下一次又是这 40 条，更早的（工作人员挪走的那些）从来轮不到。
     沿着 tj_req_stage(stage, since) 从游标往后读，读够 40 条就停：done 的 since 就是结束的时刻，30 天以前的一行都不读
     （按主键翻的话，每从头来一次都要把 30 天以前的历史再读一遍） */
  const cur = (await kvGet(env, 'track:cur').catch(() => null)) || {};
  const cs = Number(cur.since) || 0, ci = Number(cur.id) || 0;
  const list = ((await d.prepare(`SELECT * FROM tj_req INDEXED BY tj_req_stage WHERE stage = 'done' AND since >= ? AND NOT (since = ? AND id <= ?)
      AND json_extract(data, '$.tag') != '' AND json_extract(data, '$.home') IS NULL ORDER BY since, id LIMIT ?`)
    .bind(Math.max(cs, now() - LIMIT.trackDays), cs, ci, LIMIT.trackBatch).all()).results || []).map(rowOf);
  const last = list[list.length - 1];
  const nextCur = list.length < LIMIT.trackBatch ? { since: 0, id: 0 } : { since: last.since || 0, id: last.id };
  if (!list.length){ if (cs || ci) await kvPut(env, 'track:cur', nextCur).catch(() => {}); return; }
  let s;
  try { s = await streamSync(c, [], false, list.map(r => String(r.id))); }
  catch (e){ if (e.budget) throw e; return; }
  if (s.off || !s.where) return;
  await kvPut(env, 'track:cur', nextCur).catch(() => {});
  const stmts = [];
  for (const r of list){
    const w = s.where[String(r.id)];
    if (w && w.auto){ if (!r.d.tmiss) continue; r.d.tmiss = 0; }
    else if (w){
      r.d.home = { path: w.path, at: now() }; delete r.d.tmiss;
      await clog(c, r.id, '工作人员已归档：' + w.path + '（按追踪码 ' + r.d.tag + ' 找到的）');
    } else {
      r.d.tmiss = (r.d.tmiss || 0) + 1;
      if (r.d.tmiss < LIMIT.trackLost) { /* 片库的列表可能慢一点，下一轮再找 */ }
      else {
        r.d.home = { gone: 1, at: now() };
        await clog(c, r.id, '片库里哪儿都找不到追踪码 ' + r.d.tag + '（可能改了名或删了），不再追踪');
      }
    }
    stmts.push(d.prepare('UPDATE tj_req SET data = ?, rev = rev + 1 WHERE id = ? AND rev = ?').bind(JSON.stringify(r.d), r.id, r.rev));
  }
  if (stmts.length) await d.batch(stmts);
}

/** 一轮。2.7：租约带主人、跑完就还（以前 55 秒、从不还，一轮跑过 55 秒下一分钟的定时任务就拿到租约，两轮推进同一条：
    开两个 rclone 作业、推两次）；面板的「立即跑一轮」（force）只跳过「暂停」，租约照样要拿，拿不到回 { busy }。
    一轮有截止时刻（c.end，见 xfetch），跑不过租约 */
async function tick(env, opt = {}){
  const t = now();
  const cfg = await loadCfg(env);
  if (cfg.paused && !opt.force) return { paused: 1 };
  const owner = t.toString(36) + '.' + Math.random().toString(36).slice(2, 10);
  if (!(await lease(env, 'tick', LIMIT.tickLease, owner))) return { busy: 1 };
  try { return await tickRun(env, cfg, t); }
  finally { await unlease(env, 'tick', owner).catch(e => console.error('还租约失败：', e && e.message)); }
}
async function tickRun(env, cfg, t){
  const c = context(env, cfg);
  c.end = c.t0 + LIMIT.tickEnd;
  c.health = await loadHealth(env);
  c.logs = []; c.pending = [];
  await loadSlots(c);
  const d = await db(env);
  const out = { done: 0, steps: [], due: 0 };
  try {
    /* 批量传输（2.6）：先问一次正在传的那一批（一个作业，传完的成员一起去核对），再看要不要开下一批。
       开批 / 退回单个传输的这几条先写进去，下面挑到期的时候看到的就是新的 */
    try { await batchStep(c); await batchGate(c); }
    catch (e){ if (!e.budget) console.error('批量传输：', e && e.message); }
    await flush(c);
    const rows = (await d.prepare(`SELECT * FROM tj_req INDEXED BY tj_req_stnext WHERE stage IN (${ACTIVE.map(() => '?').join(',')}) AND next <= ? ORDER BY next ASC LIMIT 60`)
      .bind(...ACTIVE, now()).all()).results || [];
    const list = schedule(rows);
    out.due = list.length;
    await prefetch(c, list).catch(e => { if (!e.budget) throw e; });
    for (const r of list){
      if (out.done >= LIMIT.perTick || now() - c.t0 > LIMIT.tickMs || c.n >= c.max - 3) break;
      const from = r.stage;
      const held = { pk: from === 'download', vps: from === 'copy' && !!r.d.job };
      const sig = appSig(r);
      await advance(c, r);
      r.touch = appSig(r) !== sig;                     // App 看到的变了才动 updated（2.7，见 saveStmt）
      if (r.stage === 'ready' && r.d.tag !== undefined) c.memo.fresh = 1;   // 这一轮加好了追踪码（或者醒过来）的等待凑批
      c.slots.pk.used += (r.stage === 'download' ? 1 : 0) - (held.pk ? 1 : 0);
      c.slots.vps.used += (r.stage === 'copy' && r.d.job ? 1 : 0) - (held.vps ? 1 : 0);
      if (r.stage !== from) clog(c, r.id, STAGE_TEXT[from] + ' → ' + STAGE_TEXT[r.stage]);
      c.pending.push(r);
      out.steps.push({ id: r.id, from, to: r.stage, note: r.note });
      out.done++;
      if (c.pending.length >= 6) await flush(c);
    }
    /* 这一轮刚加好追踪码、凑得上的：这一轮就开批（不用等下一轮）。开头那一次一个加好追踪码的都没看到、
       这一轮也没有新加好的：不再查一遍（空转的每一轮少读一次） */
    await flush(c);
    if (!c.memo.gated && !c.memo.batch && (c.memo.gateSaw !== 0 || c.memo.fresh) && now() - c.t0 < LIMIT.tickMs){
      try { await batchGate(c); }
      catch (e){ if (!e.budget) console.error('凑批：', e && e.message); }
    }
  } finally {
    await flush(c).catch(e => console.error('写入失败：', e && e.message));
    if (c.healthDirty){ await kvPut(env, 'health', c.health).catch(() => {}); c.healthDirty = false; }
  }
  /* 就绪以后的追踪（v2.3）：放在最后，用剩下的子请求和时间 */
  if (now() - c.t0 < LIMIT.tickMs){
    try { await libNudge(env, c); await trackHomes(env, c); await flush(c); }
    catch (e){ if (!e.budget) console.error('追踪：', e && e.message); }
    if (c.healthDirty) await kvPut(env, 'health', c.health).catch(() => {});
  }
  if (Math.random() < 0.03) await d.prepare('DELETE FROM tj_log WHERE id < (SELECT MAX(id) - 4000 FROM tj_log)').run().catch(() => {});
  out.fetches = c.n; out.over = c.over || 0; out.ms = now() - c.t0; out.slots = c.slots; out.batch = c.memo.launch || null;
  await kvPut(env, 'tick:last', { at: t, done: out.done, due: out.due, fetches: c.n, over: out.over, ms: out.ms, batch: out.batch }).catch(() => {});
  return out;
}

/* ══════════════════════════════════════════════════════════════════
   给 App 看的进度
   ══════════════════════════════════════════════════════════════════ */
function stepProgress(r){
  switch (r.stage){
    case 'download': return clamp(r.pct, 0, 1);
    case 'clean': return 0.3;
    case 'check': return 0.25 + (r.d.org ? 0.15 : 0);
    case 'rename': return 0.6 + 0.4 * clamp(r.pct, 0, 1);
    case 'ready': return 0;                       // 2.6：等待凑批 = 刚进第 4 步（60%），开始传了才往前走
    case 'copy': return 0.9 * clamp(r.pct, 0, 1);
    case 'verify': return 0.94;
    case 'purge': return r.d.purged ? 0.99 : 0.98;
    default: return 0;
  }
}
/** 一条请求的进度。internal = 控制面板用：多带内部说明（note）、当前规格、试过几个。
    给 App 的不带这些——用户不该看到推到哪个网盘、哪个版本、下载出了什么错 */
function view(r, internal, gate){
  const state = r.stage === 'done' ? 'done' : r.stage === 'failed' ? 'failed' : r.stage === 'cancelled' ? 'cancelled' : 'active';
  /* 失败 / 取消停在出事的那一步 */
  const at = state === 'active' || state === 'done' ? r.stage : (r.d.lastStage || 'queued');
  const step = STEP_OF[at] || 1;
  const pct = state === 'done' ? 100 : Math.round(((step - 1) + (state === 'active' ? stepProgress(r) : 0)) / 5 * 100);
  const out = { id: r.id, src: r.src, tmdb: r.tmdb, season: r.season || 0, title: r.title || '', year: r.year || '', poster: r.poster || '',
           stage: r.stage, state, step, steps: 5, pct, label: STEP_LABELS[step - 1], created: r.created || 0, updated: r.updated || 0 };
  /* 2.6（可选字段，老版本 App 不认也没关系）：bid = 请求中心哪一次提交的；batch = 正在哪一批批量传输里；
     wait = 等待凑批的：等着几部、要几部 */
  if (r.bid > 0) out.bid = r.bid;
  if (r.bat > 0 && ['copy', 'verify', 'purge'].includes(r.stage)) out.batch = r.bat;
  if (r.stage === 'ready' && gate) out.wait = { ready: gate.ready, need: gate.need };
  if (internal){
    out.note = r.note || '';
    out.spec = r.d.cur ? { res: r.d.cur.res || '', labels: r.d.cur.labels || [], size: r.d.cur.size || '' } : null;
    out.tries = (r.d.tried || []).length;
  }
  return out;
}

async function latestFor(env, src, ids){
  ids = [...new Set(ids.map(Number).filter(n => n > 0))].slice(0, 90);     // D1 一条语句最多绑 100 个参数
  if (!ids.length) return new Map();
  const res = await (await db(env)).prepare(`SELECT * FROM tj_req WHERE src = ? AND tmdb IN (${ids.map(() => '?').join(',')}) ORDER BY id DESC`)
    .bind(src, ...ids).all();
  const m = new Map();
  for (const x of res.results || []){
    const k = x.tmdb + ':' + (x.season || 0);
    if (!m.has(k)) m.set(k, view(rowOf(x)));
  }
  return m;
}
/** 一部片 / 剧集的「最要紧」那条：进行中的优先，其次最新的 */
function pickFor(m, id){
  let best = null;
  for (const [k, v] of m){
    if (!k.startsWith(id + ':')) continue;
    if (!best || (v.state === 'active' && best.state !== 'active') || (v.state === best.state && v.id > best.id)) best = v;
  }
  return best;
}

/* ── 账户：用户名得真实存在（check.cuven.us 上查得到）── */
async function userOK(env, name){
  if (!name || name.length > 64 || /[\/\\\x00-\x1f]/.test(name)) return false;
  const k = 'u:' + name.toLowerCase();
  if (await kvGet(env, k)) return true;
  const c = context(env, CFG_DEF, 4);
  /* 和 App 登录时同一个接口：/check/<用户名> → { exists }（老账户可能没有 username_ 账户档，不能拿它判断） */
  const r = await xfetch(c, base(env, 'ACCOUNT_BASE', 'https://check.cuven.us') + '/check/' + encodeURIComponent(name), {}, 10000);
  if (r.status === 404) return false;
  if (!r.ok) throw err('暂时核对不了账户，稍后再试', { status: 503 });
  const j = await readJSON(r);
  const ok = !!(j && j.exists === true);
  if (ok) await kvPut(env, k, 1, 7 * DAY);
  return ok;
}

async function createReq(env, user, body, admin){
  const src = body.src === 'tv' ? 'tv' : body.src === 'movie' ? 'movie' : '';
  const id = parseInt(body.id, 10) || 0;
  const season = src === 'tv' ? Math.max(1, parseInt(body.season, 10) || 0) : 0;
  if (!src || !id) return json({ error: '要 src（movie / tv）和 id（TMDB 编号）' }, 400);
  if (src === 'tv' && !(parseInt(body.season, 10) > 0)) return json({ error: '剧集要说明第几季' }, 400);
  const d = await db(env);
  const cfg = await loadCfg(env);
  const t = now();
  /* 同一部 / 同一季已经在进行中：跟上 */
  const live = rowOf(await d.prepare(`SELECT * FROM tj_req WHERE src = ? AND tmdb = ? AND season = ? AND stage NOT IN ('done','failed','cancelled')`)
    .bind(src, id, season).first());
  if (live){
    if (!live.users.includes(user)){
      /* 跟上（2.7）：不动 rev（rev 只给面板的操作用；以前 rev + 1，这一轮正在推进它的那一次存不进去，挪过的文件 / 开过的作业下一轮再做一遍）。
         updated 照改（App 的 ETag 跟着变）。一条 SQL 原地加人，和请求中心一次提交的一样：两个人同时跟上不会丢一个 */
      await d.prepare(`UPDATE tj_req SET users = json_insert(users, '$[#]', ?), updated = ? WHERE id = ? AND json_array_length(users) < 50
          AND NOT EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?)`).bind(user, t, live.id, user).run();
      live.users.push(user);
    }
    return json({ request: view(live), joined: 1 });
  }
  /* 刚失败过：一天之内用户不能重开（面板上随时能重试） */
  if (!admin){
    const last = rowOf(await d.prepare(`SELECT * FROM tj_req WHERE src = ? AND tmdb = ? AND season = ? AND stage = 'failed' ORDER BY id DESC LIMIT 1`)
      .bind(src, id, season).first());
    if (last && t - (last.updated || 0) < LIMIT.refail){
      if (!last.users.includes(user))
        await d.prepare('UPDATE tj_req SET users = ? WHERE id = ?').bind(JSON.stringify([...last.users, user].slice(-50)), last.id).run();
      return json({ request: view(last), failedRecently: 1 });
    }
    const mine = await d.prepare(`SELECT COUNT(*) AS n FROM tj_req INDEXED BY tj_req_stage WHERE ${CAPPED_SQL}
      AND EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?)`).bind(user).first();
    if ((mine && mine.n) >= cfg.userCap) return json({ error: '你同时进行中的请求已经有 ' + cfg.userCap + ' 个了，等它们传完再来', cap: 'user' }, 429);
    const all = await d.prepare(`SELECT COUNT(*) AS n FROM tj_req INDEXED BY tj_req_stage WHERE ${CAPPED_SQL}`).first();
    if ((all && all.n) >= cfg.globalCap) return json({ error: '现在排队的请求太多了，稍后再来', cap: 'global' }, 429);
  }
  /* 先问一遍影片库：有资源才收下（顺便拿到片名和海报） */
  const c = context(env, cfg, 6);
  let v;
  try { v = await lbVersions(c, src, id, season); }
  catch (e){
    if (e.status === 404) return json({ error: '影片库里没有这部片', none: 1 }, 404);
    return json({ error: '暂时连不上影片库，稍后再试' }, 503);
  }
  if (!(v.items || []).length) return json({ error: src === 'tv' ? '这一季还没有可用的整季资源' : '这部片还没有可用的资源', none: 1 }, 404);
  const data = { vers: v.items.map(x => ({ tid: x.tid, t: String(x.title || '').slice(0, 200), mb: x.mb || 0, size: x.size || '',
                   res: x.res || '', labels: (x.labels || []).slice(0, 6), total: x.total || 0 })), versAt: t, tried: [] };
  try {
    const res = await d.prepare(`INSERT INTO tj_req (src, tmdb, season, title, year, poster, users, stage, pct, note, data, created, updated, since, next)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', 0, ?, ?, ?, ?, ?, ?)`)
      .bind(src, id, season, v.title || '', String(v.year || ''), v.poster || '', JSON.stringify([user]), STAGE_TEXT.queued,
            JSON.stringify(data), t, t, t, t).run();
    const r = await getReq(env, res.meta.last_row_id);
    await logMsg(env, r.id, (admin ? '面板' : user) + ' 请求添加：' + (v.title || id) + (season ? ' 第 ' + season + ' 季' : ''));
    return json({ request: view(r), created: 1 });
  } catch (e){
    /* 两个人同时点：唯一索引挡住了后来的，跟上先来的那条 */
    const again = rowOf(await d.prepare(`SELECT * FROM tj_req WHERE src = ? AND tmdb = ? AND season = ? AND stage NOT IN ('done','failed','cancelled')`)
      .bind(src, id, season).first());
    if (again) return json({ request: view(again), joined: 1 });
    throw e;
  }
}

/** 请求篮里的一条（2.6）：src / id / season 认得才收；片名、年份、海报只是占位（① 问影片库时换成索引里的） */
function basketItem(x){
  x = x && typeof x === 'object' ? x : {};
  const src = x.src === 'tv' ? 'tv' : x.src === 'movie' ? 'movie' : '';
  const id = parseInt(x.id, 10) || 0, sn = parseInt(x.season, 10) || 0;
  const out = { src: src || String(x.src || '').slice(0, 10), id, season: src === 'tv' ? sn : 0 };
  if (!src || id <= 0 || id > 1e9 || (src === 'tv' && (sn < 1 || sn > 999))) return { ...out, bad: 1 };
  const text = (v, n) => String(v == null ? '' : v).replace(/[\x00-\x1f]/g, ' ').trim().slice(0, n);
  const poster = text(x.poster, 300);
  return { ...out, key: src + ':' + id + ':' + out.season, title: text(x.title, 200), year: text(x.year, 8),
           poster: /^(\/[\w.\-]+|https:\/\/[^\s"'<>]+)$/.test(poster) ? poster : '' };
}
/** 提交组编号（bid）：一次提交一个，从 1 开始（tj_kv 里一条 SQL 原子地加一） */
async function nextBid(d){
  const r = await d.prepare(`INSERT INTO tj_kv (k, v, exp) VALUES ('bid:seq', '1', 0)
      ON CONFLICT(k) DO UPDATE SET v = CAST(CAST(tj_kv.v AS INTEGER) + 1 AS TEXT) RETURNING v`).first();
  return parseInt(r && r.v, 10) || 1;
}
const KEY_SQL = "(src || ':' || tmdb || ':' || season)";
/** 请求中心按「确认」（2.6）：一次提交整个请求篮。一组 SQL 做完，不一条一条问影片库（版本留给 ① 去问，没有资源的在那一步失败）：
    · 已经在进行中的跟上（joined）；一天之内失败过的拿回那条（failedRecently）；超了限额的（limit）；认不得的（invalid）；其余新建（created）
    · 同一次提交的记同一个 bid：凑批时「这一次提交的都清洗好了」就不用干等凑满 16 部
    · 匹配用一个 json_each 参数（D1 一条语句最多绑 100 个参数）；新建用 INSERT OR IGNORE 再查一遍：两个人同时提交同一部，
      唯一索引挡住后来的那条（D1 的 batch 是一个事务，用普通 INSERT 撞一条整个回滚），后来的跟上先来的 */
async function createBatch(env, user, body){
  const cfg = await loadCfg(env);
  const list = body && Array.isArray(body.items) ? body.items : null;
  const max = clamp(cfg.basketMax || CFG_DEF.basketMax, 1, LIMIT.basketMax);
  if (!list || !list.length) return json({ error: '正文是 { items: [{ src, id, season }] }' }, 400);
  if (list.length > max) return json({ error: '一次最多提交 ' + max + ' 部', max }, 400);
  const d = await db(env);
  const t = now();
  const items = list.map(basketItem);
  const good = [];                                   // 篮子里重复的：按第一次出现的那条算
  for (const x of items) if (!x.bad && !good.some(y => y.key === x.key)) good.push(x);
  const keyOf = (x) => x.src + ':' + x.tmdb + ':' + (x.season || 0);
  const liveQ = `SELECT * FROM tj_req WHERE stage NOT IN ('done','failed','cancelled') AND ${KEY_SQL} IN (SELECT value FROM json_each(?))`;
  const keys = JSON.stringify(good.map(x => x.key));
  const res = new Map();
  let bid = 0;
  if (good.length){
    const live = new Map(((await d.prepare(liveQ).bind(keys).all()).results || []).map(x => [keyOf(x), rowOf(x)]));
    /* 刚失败过：一天之内用户不能重开（面板上随时能重试） */
    const failed = new Map();
    for (const x of (await d.prepare(`SELECT * FROM tj_req WHERE stage = 'failed' AND updated > ? AND ${KEY_SQL} IN (SELECT value FROM json_each(?))
        ORDER BY id DESC`).bind(t - LIMIT.refail, keys).all()).results || []) if (!failed.has(keyOf(x))) failed.set(keyOf(x), rowOf(x));
    /* 限额：这个人的、全部的（等发行的不算），一条语句数完 */
    const cnt = await d.prepare(`SELECT COUNT(*) AS n, SUM(CASE WHEN EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?) THEN 1 ELSE 0 END) AS mine
        FROM tj_req INDEXED BY tj_req_stage WHERE ${CAPPED_SQL}`).bind(user).first();
    let mine = (cnt && cnt.mine) || 0, all = (cnt && cnt.n) || 0;
    const make = [], join = [], refail = [];
    for (const x of good){
      const l = live.get(x.key);
      if (l){ res.set(x.key, { result: 'joined', row: l }); join.push(x.key); continue; }
      const f = failed.get(x.key);
      if (f){ res.set(x.key, { result: 'failedRecently', row: f }); if (!f.users.includes(user)) refail.push(f.id); continue; }
      if (mine >= cfg.userCap){ res.set(x.key, { result: 'limit', cap: 'user' }); continue; }
      if (all >= cfg.globalCap){ res.set(x.key, { result: 'limit', cap: 'global' }); continue; }
      mine++; all++; make.push(x); res.set(x.key, { result: 'created' });
    }
    bid = await nextBid(d);
    const stmts = [];
    if (make.length) stmts.push(d.prepare(`INSERT OR IGNORE INTO tj_req (src, tmdb, season, title, year, poster, users, stage, pct, note, data,
        created, updated, since, next, bid)
      SELECT json_extract(value, '$.src'), json_extract(value, '$.id'), json_extract(value, '$.season'), json_extract(value, '$.title'),
             json_extract(value, '$.year'), json_extract(value, '$.poster'), ?, 'queued', 0, ?, ?, ?, ?, ?, ?, ? FROM json_each(?)`)
      .bind(JSON.stringify([user]), STAGE_TEXT.queued, JSON.stringify({ vers: [], versAt: 0, tried: [] }), t, t, t, t, bid,
            JSON.stringify(make.map(x => ({ src: x.src, id: x.id, season: x.season, title: x.title, year: x.year, poster: x.poster })))));
    /* 跟上的、和别人同时提交被唯一索引挡下来的：把这个人加进 users（已经在里面的不动） */
    const joinKeys = join.concat(make.map(x => x.key));
    /* 不动 rev（2.7）：定时任务存的时候不写 users，不会把这个人盖掉；rev + 1 反倒让这一轮正在推进它的那一次存不进去 */
    if (joinKeys.length) stmts.push(d.prepare(`UPDATE tj_req SET users = json_insert(users, '$[#]', ?), updated = ?
        WHERE stage NOT IN ('done','failed','cancelled') AND ${KEY_SQL} IN (SELECT value FROM json_each(?))
          AND json_array_length(users) < 50 AND NOT EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?)`)
      .bind(user, t, JSON.stringify(joinKeys), user));
    if (refail.length) stmts.push(d.prepare(`UPDATE tj_req SET users = json_insert(users, '$[#]', ?)
        WHERE id IN (SELECT value FROM json_each(?)) AND json_array_length(users) < 50
          AND NOT EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?)`).bind(user, JSON.stringify(refail), user));
    if (make.length) stmts.push(d.prepare(`INSERT INTO tj_log (rid, at, msg) SELECT id, ?, ? || CASE WHEN title != '' THEN title ELSE CAST(tmdb AS TEXT) END
        || CASE WHEN season > 0 THEN ' 第 ' || season || ' 季' ELSE '' END FROM tj_req WHERE bid = ? AND created = ?`)
      .bind(t, user + ' 请求添加（请求中心一次提交 ' + make.length + ' 部）：', bid, t));
    if (stmts.length) await d.batch(stmts);
    /* 再查一遍：新建的拿到编号；被别人抢先建了的算跟上 */
    const after = new Map(((await d.prepare(liveQ).bind(keys).all()).results || []).map(x => [keyOf(x), rowOf(x)]));
    for (const x of good){
      const v = res.get(x.key), row = after.get(x.key);
      if (v.result === 'created') res.set(x.key, row ? { result: row.bid === bid && row.created === t ? 'created' : 'joined', row } : { result: 'invalid' });
      else if (v.result === 'joined' && row) v.row = row;
      else if (v.result === 'failedRecently' && !v.row.users.includes(user)) v.row.users.push(user);
    }
  }
  /* 跟上的有已经在等待凑批的：一样带上 wait（等着几部、要几部） */
  const gate = [...res.values()].some(v => v.row && v.row.stage === 'ready') ? await gateInfo(env, cfg) : null;
  return json({ bid, items: items.map(x => {
    const base = { src: x.src, id: x.id, season: x.season };
    if (x.bad) return { ...base, result: 'invalid' };
    const v = res.get(x.key);
    return { ...base, result: v.result, ...(v.cap ? { cap: v.cap } : {}), ...(v.row ? { request: view(v.row, false, gate) } : {}) };
  }) });
}

/* ══════════════════════════════════════════════════════════════════
   App 接口
   ══════════════════════════════════════════════════════════════════ */
function slimItem(x, src){
  return { id: x.id, src, title: x.title || '', year: x.year || '', poster: x.poster || '', vote: x.vote || 0,
           res: x.res || '', hb: x.hb || 0, rb: x.rb || 0, own: x.own ? 1 : 0 };
}
async function appCatalog(env, Q){
  const want = ['movie', 'tv', 'all'].includes(Q.get('src')) ? Q.get('src') : 'all';
  const q = (Q.get('q') || '').trim().slice(0, 80);
  const qs = new URLSearchParams({ own: Q.get('own') === 'hide' ? 'hide' : 'all',
    sort: ['new', 'vote', 'hot', 'spec'].includes(Q.get('sort')) ? Q.get('sort') : 'new',
    page: String(clamp(parseInt(Q.get('page') || '1', 10) || 1, 1, 500)),
    min: Q.get('min') != null ? String(Number(Q.get('min')) || 0) : (q ? '0' : '6') });
  if (q) qs.set('q', q);
  /* 2.6：按年份（App「全部影片」的可申请那一边：2026 → 2020 一年一节）。影片库的 /api/catalog 本来就认 year */
  const year = (Q.get('year') || '').trim();
  if (/^(19|20)\d\d$/.test(year)) qs.set('year', year);
  const c = context(env, CFG_DEF, 6);
  const srcs = want === 'all' ? ['movie', 'tv'] : [want];
  const pages = await Promise.all(srcs.map(s => lb(c, '/api/catalog?src=' + s + '&' + qs).then(j => ({ s, j })).catch(e => ({ s, e }))));
  if (pages.every(p => p.e)) return json({ error: '暂时连不上影片库' }, 503);
  const lists = pages.map(p => (p.j && p.j.items || []).map(x => slimItem(x, p.s)));
  /* 两个源交替排：搜索结果里电影和剧集都看得到 */
  const items = [];
  for (let i = 0; i < Math.max(0, ...lists.map(l => l.length)); i++) for (const l of lists) if (l[i]) items.push(l[i]);
  for (const s of srcs){
    const m = await latestFor(env, s, items.filter(x => x.src === s).map(x => x.id));
    for (const it of items) if (it.src === s){ const v = pickFor(m, it.id); if (v) it.req = v; }
  }
  const meta = pages.filter(p => p.j).map(p => p.j);
  return json({ items, page: +qs.get('page'), pages: Math.max(0, ...meta.map(m => m.pages || 0)),
                total: meta.reduce((s, m) => s + (m.total || 0), 0) }, 200, { 'cache-control': 'private, max-age=30' });
}
async function appDetail(env, Q){
  const src = Q.get('src') === 'tv' ? 'tv' : 'movie';
  const id = parseInt(Q.get('id') || '', 10) || 0;
  if (!id) return json({ error: '要 id（TMDB 编号）' }, 400);
  const season = src === 'tv' ? parseInt(Q.get('season') || '0', 10) || 0 : 0;
  const c = context(env, CFG_DEF, 4);
  let v;
  try { v = await lbVersions(c, src, id, season); }
  catch (e){
    if (e.status === 404) return json({ id, src, known: 0, count: 0, seasons: [], season: 0, req: null, reqs: {} });
    return json({ error: '暂时连不上影片库' }, 503);
  }
  const items = v.items || [];
  const m = await latestFor(env, src, [id]);
  const reqs = {};
  for (const [k, r] of m) reqs[k.split(':')[1]] = r;
  return json({ id, src, known: 1, title: v.title || '', original: v.original || '', year: String(v.year || ''), poster: v.poster || '',
    seasons: v.seasons || [], season: v.season || 0, count: items.length,
    req: reqs[String(src === 'tv' ? (v.season || season) : 0)] || null, reqs }, 200, { 'cache-control': 'private, max-age=15' });
}
/** 我的请求。带 ETag：App 每 30 秒问一次，没变就回 304（不带正文） */
async function appRequests(env, user, request){
  const t = now();
  /* 2.7：分两段，都走 tj_req_stage(stage, since)：进行中的 + 30 天内结束的（结束的那一刻 since 就是结束的时间）。
     以前 json_each 加 OR 用不上索引，App 每 30 秒（批量传输时每 5 秒）把整张 tj_req 读一遍，历史越多越贵（D1 按读了几行算） */
  const mineQ = 'EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?)';
  const res = await (await db(env)).prepare(`SELECT * FROM tj_req INDEXED BY tj_req_stage WHERE ${ACTIVE_SQL} AND ${mineQ}
      UNION ALL SELECT * FROM tj_req INDEXED BY tj_req_stage WHERE ${ENDED_SQL} AND since > ? AND ${mineQ}
      ORDER BY id DESC LIMIT 60`).bind(user, t - 30 * DAY, user).all();
  const rows = (res.results || []).map(rowOf);
  const gate = rows.some(r => r.stage === 'ready') ? await gateInfo(env, await loadCfg(env)) : null;
  const body = JSON.stringify({ items: rows.map(r => view(r, false, gate)) });
  const tag = 'W/"' + md5(body).slice(0, 20) + '"';
  const h = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', etag: tag };
  if (request && request.headers.get('if-none-match') === tag) return new Response(null, { status: 304, headers: h });
  return new Response(body, { headers: h });
}

/** 正在传的那一批的实时进度（/app/flow 用）：tj_kv 里缓存 5 秒，好几个人同时看也只问一次；VPS 熔断中不问，用定时任务记下的。
    2.7：问之前先盖个戳（at = 现在，数还是上一份）：问的这几秒里别人来看直接用上一份，不跟着一起去问 VPS；
    最多等 8 秒（以前跟着传输调用的 60 秒，VPS 慢的时候 App 的请求也挂一分钟）；问不成用上一份 */
async function flowLive(env, cfg, b){
  const m = await kvGet(env, 'flow:live');
  const mine = m && m.id === b.id && m.job === b.d.job ? m : null;
  if (mine && now() - mine.at < LIMIT.flowLive) return mine;
  const c = context(env, cfg, 2);
  c.health = await loadHealth(env);
  if (depOpenUntil(c, 'vps') || !env.LINK_KEY) return mine;
  const last = mine || (b.d.live ? { ...b.d.live, id: b.id, job: b.d.job } : null);
  await kvPut(env, 'flow:live', { ...(last || {}), id: b.id, job: b.d.job, at: now() }, MIN).catch(() => {});
  try {
    const s = await tf(c, 'job', { jobid: b.d.job, detail: 1 }, LIMIT.flowLiveMs);
    if (s.missing || s.finished) return last;           // 传完 / 丢了：定时任务下一轮会处理
    const v = { id: b.id, job: b.d.job, at: now(), ...liveOf(s) };
    await kvPut(env, 'flow:live', v, MIN).catch(() => {});
    return v;
  } catch { return last; }
}
/** 请求中心最上面那张卡（2.6）：凑批进度和正在传的那一批，给动画和进度条。
    只有汇总：等着几部、这一批几部、字节 / 速度 / 剩余时间、我的是哪几条（请求编号），不带别人的片名。
    poll = App 多久再问：这一批在传时 5 秒，平时 20 秒。带 ETag（不算 at），没变回 304 */
async function appFlow(env, user, request){
  const d = await db(env);
  const cfg = await loadCfg(env);
  const gate = await gateInfo(env, cfg);
  const mineReady = await d.prepare(`SELECT COUNT(*) AS n FROM tj_req WHERE stage = 'ready' AND EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?)`)
    .bind(user).first();
  gate.mine = (mineReady && mineReady.n) || 0;
  /* 在 copy 的取最早的那一批（正在传的就是它，batchStep 也这么挑；排在后面的还没开作业），收尾中的取最新的 */
  const bx = await d.prepare("SELECT * FROM tj_batch WHERE ended = 0 ORDER BY (stage = 'copy') DESC, CASE WHEN stage = 'copy' THEN -id ELSE id END DESC LIMIT 1").first();
  let batch = null;
  if (bx){
    const b = batchOf(bx);
    const mine = ((await d.prepare(`SELECT id FROM tj_req WHERE bat = ? AND stage NOT IN ('cancelled', 'failed')
        AND EXISTS (SELECT 1 FROM json_each(tj_req.users) WHERE value = ?) ORDER BY id`).bind(b.id, user).all()).results || []).map(x => x.id);
    const copying = b.stage === 'copy';
    const live = (copying && b.d.job ? await flowLive(env, cfg, b) : null) || b.d.live || {};
    const shown = batchShown(b, live), total = shown.total;
    /* 2.7：字节数、百分比只往前走（重开以后不往回跳，见 batchShown）；还没有作业号（开作业的回答丢了、910 说在传但没找到作业号）
       就没有速度和剩余时间（App 按速度往前推算进度条，拿上一个作业的速度会一直往前跑） */
    const running = copying && !!b.d.job;
    batch = { id: b.id, stage: copying ? 'copy' : b.stage === 'purge' ? 'purge' : 'verify', items: b.items.length, mine,
              bytes: copying ? shown.bytes : total, total, speed: running ? live.speed || 0 : 0, eta: running ? live.eta ?? null : copying ? null : 0,
              files: { done: copying ? live.done || 0 : (b.d.files || live.files || 0), total: b.d.files || live.files || 0 },
              started: b.d.started || 0, pct: copying ? Math.round(shown.pct * 100) : 100 };
  }
  const out = { gate, batch, poll: batch && batch.stage === 'copy' ? 5 : 20 };
  const tag = 'W/"' + md5(JSON.stringify(out)).slice(0, 20) + '"';
  const h = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', etag: tag };
  if (request && request.headers.get('if-none-match') === tag) return new Response(null, { status: 304, headers: h });
  return new Response(JSON.stringify({ at: now(), ...out }), { headers: h });
}

/* ══════════════════════════════════════════════════════════════════
   控制面板接口
   ══════════════════════════════════════════════════════════════════ */
function safeEq(a, b){
  a = String(a || ''); b = String(b || '');
  if (!a || !b || a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}
async function adminState(env){
  const d = await db(env);
  const cfg = await loadCfg(env);
  /* 进行中的在前、再是最近结束的，最多 200 条。2.7：分两次取（进行中的走 stage 的索引；最近的 200 条按主键倒着读），
     以前整张表按「结束没有」排一遍序，面板开着每 15 秒读一遍整张 tj_req */
  const act = (await d.prepare(`SELECT * FROM tj_req INDEXED BY tj_req_stage WHERE ${ACTIVE_SQL} ORDER BY id DESC LIMIT 200`).all()).results || [];
  const recent = (await d.prepare('SELECT * FROM tj_req ORDER BY id DESC LIMIT 200').all()).results || [];
  const byId = new Map();
  for (const x of act.concat(recent)) byId.set(x.id, x);
  const reqs = [...byId.values()].sort((a, b) => (ENDED.includes(a.stage) - ENDED.includes(b.stage)) || b.id - a.id).slice(0, 200)
    .map(x => { const r = rowOf(x); return { ...view(r, true), users: r.users, item: r.d.item || '', cur: r.d.cur ? r.d.cur.t : '', tried: (r.d.tried || []).length,
      tag: r.d.tag || '', home: r.d.home ? (r.d.home.gone ? '找不到了（改了名或删了）' : r.d.home.path) : '', sub: r.d.sub || '', bat: r.bat || 0, bid: r.bid || 0,
      vers: (r.d.vers || []).length, next: r.next || 0, since: r.since || 0, errs: r.d.errs || 0, check: r.d.check || null }; });
  const logs = ((await d.prepare('SELECT * FROM tj_log ORDER BY id DESC LIMIT 200').all()).results || []);
  const tok = await kvGet(env, 'pk:tok');
  /* 排队位置：和定时任务同一套排序（每个人的第一个先上、人多的优先、先来后到） */
  const queued = schedule(((await d.prepare("SELECT * FROM tj_req WHERE stage = 'queued'").all()).results || []));
  const pos = new Map(queued.map((r, i) => [r.id, i + 1]));
  for (const r of reqs) if (pos.has(r.id)) r.pos = pos.get(r.id);
  const c = context(env, cfg, 1);
  const slots = await loadSlots(c);
  const health = await loadHealth(env);
  /* 批量（2.6）：凑批进度、最近一批（在传的优先）、传输 Worker 会什么 */
  const gate = await gateInfo(env, cfg);
  const bx = await d.prepare("SELECT * FROM tj_batch ORDER BY (ended = 0) DESC, (stage = 'copy') DESC, CASE WHEN stage = 'copy' THEN -id ELSE id END DESC LIMIT 1").first();
  let batch = null;
  if (bx){
    const b = batchOf(bx), live = b.d.live || {}, shown = batchShown(b), running = b.stage === 'copy' && !!b.d.job;
    /* jobless（2.7）：910 说这一批在传、作业号还没接上（面板写「传输中（作业号未知）」，不算出错） */
    batch = { id: b.id, stage: b.stage, items: b.items.length, job: b.d.job || 0, why: b.d.why || '', err: b.d.err || '', off: b.d.off || '',
              bytes: shown.bytes, total: shown.total, speed: running ? live.speed || 0 : 0,
              eta: running ? live.eta ?? null : null, started: b.d.started || 0, ended: b.ended || 0, pct: Math.round(shown.pct * 100),
              jobless: b.stage === 'copy' && !b.d.job && b.d.running ? 1 : 0 };
    if (b.stage === 'copy' && !b.ended) slots.batch = b.id;
  }
  const caps = capsOf(cfg, await kvGet(env, 'tf:caps'));
  return { ver: VER, now: now(), health, slots, tick: await kvGet(env, 'tick:last'), queued: queued.length, gate, batch, caps,
    cfg: { pkUser: mask(cfg.pkUser), pkSet: !!(cfg.pkUser && cfg.pkPass), tpl: cfg.tpl, lang: cfg.lang, grp: cfg.grp,
           userCap: cfg.userCap, globalCap: cfg.globalCap, paused: !!cfg.paused, pkToken: tok ? { exp: tok.exp } : null,
           pkSlots: cfg.pkSlots, vpsSlots: cfg.vpsSlots, autoReady: cfg.autoReady !== false, tagNames: cfg.tagNames !== false,
           batch: cfg.batch !== false, batchMin: cfg.batchMin, batchMax: cfg.batchMax, batchWait: cfg.batchWait, xfers: cfg.xfers,
           checkers: cfg.checkers, basketMax: cfg.basketMax, tvSub: cfg.tvSub || '' },
    env: { LB_GATE: !!env.LB_GATE, LINK_KEY: !!env.LINK_KEY, LB_BASE: base(env, 'LB_BASE', 'https://lb.cuven.us'),
           TRANSFER_BASE: base(env, 'TRANSFER_BASE', 'https://transfer.cuven.us'), AUTO_DIR: String(env.AUTO_DIR || 'auto'),
           STREAM_BASE: base(env, 'STREAM_BASE', 'https://stream.cuven.online') },
    reqs, logs };
}
async function adminReq(env, body){
  const r = await getReq(env, parseInt(body.id, 10) || 0);
  if (!r) return json({ error: '没有这条请求' }, 404);
  const act = String(body.act || '');
  const cfg = await loadCfg(env);
  const c = context(env, cfg, 20);
  if (act === 'delete'){
    await (await db(env)).prepare('DELETE FROM tj_req WHERE id = ?').bind(r.id).run();
    await logMsg(env, r.id, '面板：删除');
    return json({ ok: 1 });
  }
  if (act === 'cancel'){
    if (ENDED.includes(r.stage)) return json({ error: '已经结束了' }, 400);
    r.d.lastStage = r.stage;
    /* 等待凑批的（2.6）也还只在 PikPak 上：一起删 */
    if (['download', 'clean', 'check', 'ready'].includes(r.stage) && cfg.pkUser){
      if (r.d.task) await pkDelTasks(c, [r.d.task], true).catch(() => {});
      if (r.d.file) await pkTrash(c, [r.d.file]).catch(() => {});
      if (r.d.junk) await pkTrash(c, [r.d.junk]).catch(() => {});       // 清洗挑剩的原文件夹（2.7）
    }
    /* 批量传输里的（2.6）：拿不出那个作业，这一批照常跑完；传完这一条不核对、不删（batchDone 再写一句） */
    if (r.stage === 'copy' && r.d.batch)
      await logMsg(env, r.id, '面板：取消。批量 #' + r.d.batch + ' 正在传，这一批照常跑完；这一条传完不核对、不删，它传到 Dropbox 的那份会留在原处');
    /* since = 取消的时刻（2.7：/app/requests 按 since 取 30 天内结束的，和 done / failed 一样） */
    r.stage = 'cancelled'; r.next = 0; r.note = '已取消'; r.since = now();
  } else if (act === 'retry'){
    /* 失败 / 取消的：从出事的那一步重来（推送之前的就从头来，试过的规格清零） */
    let from = ENDED.includes(r.stage) ? (r.d.lastStage || 'queued') : r.stage;
    if (r.stage === 'done') return json({ error: '已经发行了' }, 400);
    const live = await (await db(env)).prepare(`SELECT id FROM tj_req WHERE src = ? AND tmdb = ? AND season = ? AND id != ? AND stage NOT IN ('done','failed','cancelled')`)
      .bind(r.src, r.tmdb, r.season, r.id).first();
    if (live) return json({ error: '同一部 / 同一季已经有一条在进行中（#' + live.id + '）' }, 409);
    /* 等待凑批时取消的（2.6）：取消时 PikPak 那份已经删了，从推送那一步重来（同一个规格可以再推） */
    if (r.stage === 'cancelled' && from === 'ready' && cfg.pkUser){ forget(r); from = 'queued'; }
    if (from === 'queued'){ r.d.tried = []; delete r.d.versAt; }
    /* 批量传输里出的事（2.6）：离开那一批；还没传完的回去等凑批（关了批量就直接单个传） */
    if (r.bat || r.d.batch){
      if (from === 'copy' && r.d.batch) from = cfg.batch === false ? 'copy' : 'ready';
      delete r.d.batch; r.bat = 0;
    }
    r.d.errs = 0; r.d.ctries = 0; r.d.rtries = 0; r.d.job = 0;
    r.stage = from; r.next = now(); r.since = now(); r.note = '面板：重试';
  } else if (act === 'skip'){
    if (!['download', 'clean', 'check', 'queued', 'ready'].includes(r.stage)) return json({ error: '只有推送 / 下载 / 清洗 / 等待凑批阶段能换规格' }, 400);
    if (!cfg.pkUser) return json({ error: '先填 PikPak 账号' }, 400);
    await drop(c, r, '面板：换下一个规格');
  } else if (act === 'now'){
    r.next = 0;
  } else return json({ error: '未知操作' }, 400);
  if (r.stage === 'failed' || r.stage === 'cancelled') r.d.lastStage = r.d.lastStage || 'queued';
  const ok = await saveReq(env, r);
  await logMsg(env, r.id, '面板：' + act);
  return json({ ok: ok ? 1 : 0, request: view(r, true) });
}
async function adminPk(env){
  const cfg = await loadCfg(env);
  const c = context(env, cfg, 16);
  const out = { set: !!(cfg.pkUser && cfg.pkPass), user: mask(cfg.pkUser) };
  try {
    const a = await pkCall(c, 'GET', '/drive/v1/about');
    const q = (a && a.quota) || {};
    out.ok = 1; out.limit = Number(q.limit) || 0; out.usage = Number(q.usage) || 0;
    try {
      const auto = await autoFolder(c, true);
      const f = await pkFile(c, auto);
      out.auto = f ? { id: auto, name: f.name, same: 1 } : { id: auto, same: 0, hint: '影片库给的 /auto 在这个账号里找不到：两边配的不是同一个 PikPak 账号' };
    } catch (e){ out.auto = { err: e.message }; }
  } catch (e){ out.ok = 0; out.err = e.message; out.captcha = e.captcha ? 1 : 0; }
  return json(out);
}
async function adminLinks(env){
  const c = context(env, CFG_DEF, 6);
  const out = {};
  try { const s = await lb(c, '/api/pikpak?do=status'); out.lb = { ok: 1, pikpak: s.on ? (s.ok ? '已登录 ' + (s.user || '') : '登录失败：' + (s.err || '')) : '没配 PikPak' }; }
  catch (e){ out.lb = { ok: 0, err: e.message }; }
  try {
    const p = await tf(c, 'ping', {});
    const caps = Array.isArray(p.caps) ? p.caps.map(String) : [];
    out.transfer = { ok: 1, rclone: p.version || '', core: p.core || '', caps, tv: p.tv || '' };
    /* 顺手记下它会什么（2.6：sub / batch），定时任务就不用再问 */
    const old = await kvGet(env, 'tf:caps').catch(() => null);
    await kvPut(env, 'tf:caps', { caps, tv: String(p.tv || ''), core: String(p.core || ''), at: now(), nofilter: (old && old.nofilter) || 0 }).catch(() => {});
  } catch (e){ out.transfer = { ok: 0, err: e.message }; }
  try { const s = await streamSync(c, [], false); out.stream = s.off ? { ok: 1, off: 1, why: s.why } : { ok: 1, root: s.root }; }
  catch (e){ out.stream = { ok: 0, err: e.message }; }
  return json(out);
}

/* ══════════════════════════════════════════════════════════════════
   路由
   ══════════════════════════════════════════════════════════════════ */
export default {
  async scheduled(event, env, ctx){
    ctx.waitUntil(tick(env).catch(e => console.error('tick 失败：', e && e.message)));
  },

  async fetch(request, env, ctx){
    const url = new URL(request.url), p = url.pathname, Q = url.searchParams;
    try {
      if (p === '/' || p === '/index.html')
        return new Response(PANEL, { headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store',
          'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer', 'x-frame-options': 'DENY' } });
      if (p === '/version') return json({ ver: VER });

      if (p.startsWith('/app/')){
        if (p === '/app/catalog' && request.method === 'GET') return await appCatalog(env, Q);
        if (p === '/app/detail' && request.method === 'GET') return await appDetail(env, Q);
        /* App 把用户名按 encodeURIComponent 编码后放进头里（头里只能放 ASCII） */
        const appUser = () => { let u = String(request.headers.get('x-cuven-user') || '').trim(); try { u = decodeURIComponent(u); } catch {} return u; };
        /* 2.6：请求中心按「确认」一次提交整个请求篮 */
        if (p === '/app/requests/batch' && request.method === 'POST'){
          const user = appUser();
          if (!user) return json({ error: '要登录' }, 401);
          if (!(await userOK(env, user))) return json({ error: '账户核对不上，重新登录再试' }, 401);
          const body = await request.json().catch(() => null);
          if (!body) return json({ error: '正文是 { items: [{ src, id, season }] }' }, 400);
          return await createBatch(env, user, body);
        }
        /* 2.6：凑批进度和正在传的那一批 */
        if (p === '/app/flow' && request.method === 'GET'){
          const user = appUser();
          if (!user) return json({ error: '要登录' }, 401);
          return await appFlow(env, user, request);
        }
        if (p === '/app/requests'){
          const user = appUser();
          if (!user) return json({ error: '要登录' }, 401);
          if (request.method === 'GET') return await appRequests(env, user, request);
          if (request.method === 'POST'){
            if (!(await userOK(env, user))) return json({ error: '账户核对不上，重新登录再试' }, 401);
            const body = await request.json().catch(() => null);
            if (!body) return json({ error: '正文是 { src, id, season }' }, 400);
            return await createReq(env, user, body, false);
          }
        }
        return json({ error: 'not found' }, 404);
      }

      if (p.startsWith('/admin/api/')){
        if (!env.ADMIN_KEY) return json({ error: '还没配 ADMIN_KEY（Worker 设置 → 变量和机密，类型选「密钥」）' }, 500);
        if (!safeEq(request.headers.get('x-admin-key'), env.ADMIN_KEY)){ await sleep(400); return json({ error: '口令不对' }, 401); }
        const body = request.method === 'POST' ? (await request.json().catch(() => ({}))) : {};
        const op = p.slice('/admin/api/'.length);
        if (op === 'state') return json(await adminState(env));
        if (op === 'cfg'){ await saveCfg(env, body || {}); return json(await adminState(env)); }
        if (op === 'pk') return await adminPk(env);
        if (op === 'links') return await adminLinks(env);
        if (op === 'req') return await adminReq(env, body || {});
        if (op === 'add') return await createReq(env, 'admin', body || {}, true);
        if (op === 'tick') return json(await tick(env, { force: true }));
        if (op === 'log'){
          const rid = parseInt(Q.get('id') || '0', 10) || 0;
          const rows = (await (await db(env)).prepare('SELECT * FROM tj_log WHERE rid = ? ORDER BY id DESC LIMIT 200').bind(rid).all()).results || [];
          return json({ items: rows });
        }
        return json({ error: 'not found' }, 404);
      }
      return new Response('Not found', { status: 404 });
    } catch (e){
      return json({ error: (e && e.message) || String(e) }, (e && e.status) || (e && e.conf ? 500 : 500));
    }
  },
};

/* ══════════════════════════════════════════════════════════════════
   控制面板
   ══════════════════════════════════════════════════════════════════ */
const PANEL = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cuven 请求添加</title>
<style>
:root{--bg:#0b0c0f;--card:#15171c;--line:#262a33;--text:#e9ebf0;--dim:#8b91a0;--accent:#30d158;--warn:#ff9f0a;--bad:#ff453a;--blue:#0a84ff}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"PingFang SC","Segoe UI",sans-serif}
header{display:flex;align-items:center;gap:12px;padding:16px 20px;border-bottom:1px solid var(--line);position:sticky;top:0;background:rgba(11,12,15,.9);backdrop-filter:blur(12px);z-index:2}
h1{font-size:17px;margin:0}h2{font-size:15px;margin:0 0 12px}.ver{color:var(--dim);font-size:12px}
main{max-width:1180px;margin:0 auto;padding:20px;display:grid;gap:16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px}
label{display:block;color:var(--dim);font-size:12px;margin:10px 0 4px}
input,select{width:100%;background:#0f1115;border:1px solid var(--line);color:var(--text);border-radius:9px;padding:8px 10px;font:inherit}
button{background:#232731;color:var(--text);border:1px solid var(--line);border-radius:9px;padding:7px 12px;font:inherit;cursor:pointer}
button:hover{border-color:#3a404c}button.pri{background:var(--accent);color:#04210d;border-color:transparent;font-weight:600}
button.small{padding:3px 8px;font-size:12px}.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.ok{color:var(--accent)}.bad{color:var(--bad)}.warn{color:var(--warn)}.dim{color:var(--dim)}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:9px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--dim);font-weight:500;font-size:12px}td .t{font-weight:600}.mono{font-family:ui-monospace,Menlo,monospace;font-size:12px}
.bar{display:flex;gap:3px;margin:4px 0 2px}.bar i{flex:1;height:6px;border-radius:3px;background:#2a2f39}.bar i.on{background:var(--accent)}
.bar i.cur{background:linear-gradient(90deg,var(--accent) var(--p),#2a2f39 var(--p))}
.pill{display:inline-block;padding:1px 8px;border-radius:99px;font-size:12px;background:#232731}
.pill.active{background:#0d3a1d;color:var(--accent)}.pill.failed{background:#3b1210;color:var(--bad)}.pill.done{background:#10263f;color:#64b5ff}
.log{max-height:360px;overflow:auto}.log div{padding:3px 0;border-bottom:1px dashed #1f232b}
#login{max-width:360px;margin:12vh auto}.hide{display:none!important}
@media (max-width:720px){td:nth-child(3),th:nth-child(3){display:none}main{padding:12px}}
</style></head><body>
<div id="login" class="card"><h2>Cuven 请求添加 · 控制面板</h2><label>口令（ADMIN_KEY）</label><input id="key" type="password" autocomplete="current-password">
<div class="row" style="margin-top:12px"><button class="pri" id="enter">进入</button><span id="lerr" class="bad"></span></div></div>
<div id="app" class="hide">
<header><h1>请求添加</h1><span class="ver" id="ver"></span><span style="flex:1"></span>
<button id="tick">立即跑一轮</button><button id="refresh">刷新</button><button id="logout">退出</button></header>
<main>
<div class="card"><h2>系统</h2><div id="sys" class="dim">—</div></div>
<div class="grid">
 <div class="card"><h2>PikPak（清洗用）</h2>
  <div id="pkline" class="dim">—</div>
  <label>账号（邮箱 / 手机号）</label><input id="pkUser" autocomplete="off" placeholder="不改就留空">
  <label>密码</label><input id="pkPass" type="password" autocomplete="new-password" placeholder="不改就留空">
  <div class="row" style="margin-top:12px"><button class="pri" id="savePk">保存</button><button id="testPk">测试登录</button><span id="pkres"></span></div>
  <p class="dim" style="font-size:12px;margin:10px 0 0">必须和影片库 Worker 的 PIKPAK_USER 是同一个账号。密码用 ADMIN_KEY 派生的密钥加密后存进 D1。</p>
 </div>
 <div class="card"><h2>连接</h2><div id="links" class="dim">—</div><div class="row" style="margin-top:12px"><button id="testLinks">测试影片库 / 传输</button></div>
  <h2 style="margin-top:18px">剧集命名</h2>
  <div class="row"><select id="tpl" style="flex:1"><option value="rel">发行名（rel）</option><option value="std">标准（std）</option><option value="season">季目录（season）</option><option value="nest">嵌套（nest）</option><option value="dot">点分（dot）</option></select>
  <select id="lang" style="flex:1"><option value="en">英文名</option><option value="cn">中文名</option><option value="cnen">中英</option></select></div>
  <label>发行组</label><input id="grp">
 </div>
 <div class="card"><h2>限额</h2>
  <label>每个用户同时进行中</label><input id="userCap" type="number" min="1" max="100">
  <label>全部同时进行中</label><input id="globalCap" type="number" min="1" max="1000">
  <label>PikPak 同时云下载</label><input id="pkSlots" type="number" min="1" max="20">
  <label>VPS 同时传输（单个传输；太多会把 rclone 内存吃满）</label><input id="vpsSlots" type="number" min="1" max="8">
  <label class="row" style="margin-top:12px;color:var(--text)"><input id="batch" type="checkbox" style="width:auto"> 批量传输：清洗好的凑够一批一起传（关了就一部一部传）</label>
  <div class="row"><div style="flex:1"><label>凑够几部开一批</label><input id="batchMin" type="number" min="1" max="16"></div>
   <div style="flex:1"><label>一批最多几部</label><input id="batchMax" type="number" min="1" max="16"></div>
   <div style="flex:1"><label>最多等（分钟）</label><input id="batchWait" type="number" min="1" max="1440"></div></div>
  <div class="row"><div style="flex:1"><label>并行传输（Transfers）</label><input id="xfers" type="number" min="1" max="16"></div>
   <div style="flex:1"><label>并发核对（Checkers）</label><input id="checkers" type="number" min="1" max="16"></div>
   <div style="flex:1"><label>请求中心一次最多</label><input id="basketMax" type="number" min="1" max="50"></div></div>
  <label>剧集放在 /auto 下面哪个文件夹（PikPak 和 Dropbox 一样，空 = 直接放 /auto；要和传输 Worker 的 AUTO_TV_DIR 一致）</label><input id="tvSub" placeholder="ram2">
  <label class="row" style="margin-top:12px;color:var(--text)"><input id="autoReady" type="checkbox" style="width:auto"> 文件抵达 /auto 自动通过最终审核（不等工作人员发行）</label>
  <label class="row" style="margin-top:8px;color:var(--text)"><input id="tagNames" type="checkbox" style="width:auto"> 名字里带追踪码 [auto-m550-r13]（挪走以后也能一直追踪）</label>
  <label class="row" style="margin-top:8px;color:var(--text)"><input id="paused" type="checkbox" style="width:auto"> 暂停定时任务</label>
  <div class="row" style="margin-top:12px"><button class="pri" id="saveCfg">保存设置</button><span id="cfgres"></span></div>
  <h2 style="margin-top:18px">手动添加</h2>
  <div class="row"><select id="addSrc" style="width:90px"><option value="movie">电影</option><option value="tv">剧集</option></select>
  <input id="addId" placeholder="TMDB 编号" style="flex:1"><input id="addSeason" placeholder="季" style="width:60px"><button id="add">添加</button></div><div id="addres" class="dim"></div>
 </div>
</div>
<div class="card"><h2>请求</h2><table><thead><tr><th>影片</th><th>进度</th><th>规格 / 名字</th><th>用户</th><th></th></tr></thead><tbody id="reqs"></tbody></table></div>
<div class="card"><h2>日志</h2><div id="log" class="log mono"></div></div>
</main></div>
<script>
var KEY='';try{KEY=localStorage.getItem('tjkey')||''}catch(e){}
var $=function(id){return document.getElementById(id)};
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
function ago(t){if(!t)return'';var s=Math.round((Date.now()-t)/1000);if(s<60)return s+' 秒前';if(s<3600)return Math.round(s/60)+' 分钟前';if(s<86400)return Math.round(s/3600)+' 小时前';return Math.round(s/86400)+' 天前'}
function api(op,body){return fetch('/admin/api/'+op,{method:body?'POST':'GET',headers:{'x-admin-key':KEY,'content-type':'application/json'},body:body?JSON.stringify(body):undefined}).then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j})})}
function show(on){$('login').classList.toggle('hide',on);$('app').classList.toggle('hide',!on)}
function gbs(n){return ((n||0)/1073741824).toFixed(1)+' GB'}
function dur(sec){if(sec==null)return'—';sec=Math.max(0,Math.round(sec));if(sec<60)return sec+' 秒';if(sec<3600)return Math.round(sec/60)+' 分钟';return (sec/3600).toFixed(1)+' 小时'}
/* 系统卡里的凑批和批量传输（2.6） */
function flowHtml(s){
 var g=s.gate||{},b=s.batch,cp=s.caps||{},c=s.cfg||{};
 var h='<div style="margin-top:6px">凑批 <b>'+(g.ready||0)+' / '+(g.need||0)+'</b>'+(c.batch?'':' <span class="warn">（批量传输关了）</span>')+
  (g.oldest?' · 最早的 '+ago(g.oldest)+'进来':'')+(g.launchBy?' · 最晚 '+new Date(g.launchBy).toLocaleTimeString()+' 开批':'')+'</div>';
 if(b){var run=b.stage==='copy'&&!b.ended;
  h+='<div>批量 #'+b.id+' · '+(run?'<span class="ok">传输中'+(b.jobless?'（作业号未知）':'')+'</span>':b.ended?'已收尾':b.stage==='purge'?'删 PikPak':'核对中')+' · '+b.items+' 部'+
   (run?' · <b>'+gbs(b.bytes)+' / '+gbs(b.total)+'</b>（'+b.pct+'%）· '+((b.speed||0)/1048576).toFixed(1)+' MB/s · 还要 '+dur(b.eta):'')+
   (b.why?' <span class="dim">（'+esc(b.why)+'）</span>':'')+(b.err?' <span class="bad">'+esc(b.err)+'</span>':'')+(b.off?' <span class="warn">'+esc(b.off)+'</span>':'')+'</div>'}
 h+='<div class="dim">传输 Worker：'+(!cp.known?'还没问到会什么':(cp.batch?'会批量传输':'不会批量（一部一部传）')+(cp.sub?' · 剧集在 /auto/'+esc(cp.sub):' · 剧集在 /auto')+
  (cp.mismatch?' <span class="bad">剧集区名字对不上（这里 '+esc(c.tvSub)+'，传输 Worker '+esc(cp.tv)+'）</span>':'')+(cp.nofilter?' <span class="warn">rclone 不认筛选规则，'+new Date(cp.nofilter).toLocaleTimeString()+' 前一部一部传</span>':''))+'</div>';
 return h}
function bar(r){var h='<div class="bar">';for(var i=1;i<=5;i++){if(i<r.step||r.state==='done')h+='<i class="on"></i>';else if(i===r.step&&r.state==='active'){var p=Math.max(0,Math.min(100,(r.pct-(i-1)*20)*5));h+='<i class="cur" style="--p:'+p+'%"></i>'}else h+='<i></i>'}return h+'</div>'}
function render(s){
 $('ver').textContent=s.ver;var c=s.cfg;
 $('pkline').innerHTML=c.pkSet?'<span class="ok">已填</span> '+esc(c.pkUser)+(c.pkToken?' · 令牌到 '+new Date(c.pkToken.exp).toLocaleTimeString():''):'<span class="warn">还没填 PikPak 账号</span>';
 $('tpl').value=c.tpl;$('lang').value=c.lang;$('grp').value=c.grp;$('userCap').value=c.userCap;$('globalCap').value=c.globalCap;$('paused').checked=c.paused;$('autoReady').checked=c.autoReady;$('tagNames').checked=c.tagNames;
 $('pkSlots').value=c.pkSlots;$('vpsSlots').value=c.vpsSlots;
 $('batch').checked=c.batch;$('batchMin').value=c.batchMin;$('batchMax').value=c.batchMax;$('batchWait').value=c.batchWait;
 $('xfers').value=c.xfers;$('checkers').value=c.checkers;$('basketMax').value=c.basketMax;$('tvSub').value=c.tvSub;
 var NAMES={lb:'影片库',vps:'传输（VPS）',pikpak:'PikPak',stream:'片库 / TMDB'};
 var hs=Object.keys(NAMES).map(function(k){var h=s.health[k]||{};var open=h.open&&h.open>s.now;
  return '<span class="pill '+(open?'failed':'active')+'">'+NAMES[k]+' '+(open?'熔断到 '+new Date(h.open).toLocaleTimeString():'正常')+'</span>'+
   (h.err&&h.bad&&s.now-h.bad<3600000?' <span class="dim">'+esc(h.err)+'（'+ago(h.bad)+'）</span>':'')}).join('<br>');
 var sl=s.slots||{pk:{},vps:{}};
 $('sys').innerHTML=hs+'<div style="margin-top:10px">PikPak 云下载 <b>'+sl.pk.used+' / '+sl.pk.max+'</b> · VPS 传输 <b>'+sl.vps.used+' / '+sl.vps.max+'</b>'+(sl.batch?' <span class="warn">（批量 #'+sl.batch+' 在传，单个的排队）</span>':'')+' · 排队 <b>'+s.queued+'</b>'+
  (s.tick?' · 上一轮 '+ago(s.tick.at)+'，推进 '+s.tick.done+' / 到期 '+s.tick.due+'，子请求 '+s.tick.fetches+(s.tick.over?'（用完了，'+s.tick.over+' 处留到下一轮）':'')+'，'+s.tick.ms+' ms':' · 定时任务还没跑过')+'</div>'+flowHtml(s);
 var e=s.env;$('links').innerHTML='影片库 '+esc(e.LB_BASE)+(e.LB_GATE?'':' <span class="bad">缺 LB_GATE</span>')+'<br>传输 '+esc(e.TRANSFER_BASE)+(e.LINK_KEY?'':' <span class="bad">缺 LINK_KEY</span>')+'<br>目录 /'+esc(e.AUTO_DIR)+'<br>片库 '+esc(e.STREAM_BASE);
 $('reqs').innerHTML=s.reqs.map(function(r){
  var acts=r.state==='active'?'<button class="small" data-a="now" data-id="'+r.id+'">现在</button> <button class="small" data-a="skip" data-id="'+r.id+'">换规格</button> <button class="small" data-a="cancel" data-id="'+r.id+'">取消</button>':
   (r.state!=='done'?'<button class="small" data-a="retry" data-id="'+r.id+'">重试</button> ':'')+'<button class="small" data-a="delete" data-id="'+r.id+'">删除</button>';
  return '<tr><td><div class="t">'+esc(r.title||r.tmdb)+(r.season?' · 第 '+r.season+' 季':'')+'</div><div class="dim">#'+r.id+' · '+(r.src==='tv'?'剧集':'电影')+' '+r.tmdb+' · '+ago(r.created)+'</div></td>'+
   '<td style="min-width:200px"><span class="pill '+r.state+'">'+esc(r.state==='active'?('STEP '+r.step+' · '+r.label):r.state==='done'?'已就绪':r.state==='failed'?'失败':'已取消')+'</span> <b>'+r.pct+'%</b>'+(r.pos?' <span class="dim">排队第 '+r.pos+' 位</span>':'')+bar(r)+'<div class="dim">'+esc(r.note)+(r.errs?' <span class="warn">（出错 '+r.errs+' 次）</span>':'')+'</div><div class="dim">'+(r.next&&r.state==='active'?'下次 '+new Date(r.next).toLocaleTimeString():'')+'</div></td>'+
   '<td class="mono" style="max-width:340px;word-break:break-all">'+esc(r.cur||'')+(r.item?'<div class="ok">'+(r.sub?'<span class="dim">'+esc(r.sub)+'/</span>':'')+esc(r.item)+'</div>':'')+(r.bat?'<div class="warn">批量 #'+r.bat+'</div>':'')+(r.bid?'<div class="dim">请求中心第 '+r.bid+' 次提交</div>':'')+(r.home?'<div class="dim">→ '+esc(r.home)+'</div>':'')+'<div class="dim">规格 '+(r.tried+(r.cur?1:0))+' / '+r.vers+'</div></td>'+
   '<td>'+esc((r.users||[]).join('、'))+'</td><td style="white-space:nowrap"><button class="small" data-a="log" data-id="'+r.id+'">日志</button> '+acts+'</td></tr>'}).join('')||'<tr><td colspan="5" class="dim">还没有请求</td></tr>';
 $('log').innerHTML=s.logs.map(function(l){return '<div><span class="dim">'+new Date(l.at).toLocaleString()+'</span> '+(l.rid?'#'+l.rid+' ':'')+esc(l.msg)+'</div>'}).join('');
}
function load(){return api('state').then(function(s){show(true);render(s)}).catch(function(e){if(/口令/.test(e.message)){show(false);$('lerr').textContent=KEY?e.message:''}else alert(e.message)})}
$('enter').onclick=function(){KEY=$('key').value.trim();try{localStorage.setItem('tjkey',KEY)}catch(e){}load()};
$('key').onkeydown=function(e){if(e.key==='Enter')$('enter').click()};
$('logout').onclick=function(){KEY='';try{localStorage.removeItem('tjkey')}catch(e){}show(false)};
$('refresh').onclick=load;
$('tick').onclick=function(){this.disabled=true;var b=this;api('tick',{}).then(function(r){b.disabled=false;load()}).catch(function(e){b.disabled=false;alert(e.message)})};
$('savePk').onclick=function(){var u=$('pkUser').value.trim(),p=$('pkPass').value;if(!u&&!p)return;var body={};if(u)body.pkUser=u;if(p)body.pkPass=p;api('cfg',body).then(function(s){$('pkUser').value='';$('pkPass').value='';$('pkres').innerHTML='<span class="ok">已保存</span>';render(s)}).catch(function(e){$('pkres').innerHTML='<span class="bad">'+esc(e.message)+'</span>'})};
$('testPk').onclick=function(){$('pkres').textContent='…';api('pk',{}).then(function(r){$('pkres').innerHTML=r.ok?'<span class="ok">登录成功</span> '+(r.limit?(r.usage/1073741824).toFixed(1)+' / '+(r.limit/1073741824).toFixed(0)+' GB':'')+(r.auto?(r.auto.same?' · /auto 对得上':' <span class="bad">'+esc(r.auto.hint||r.auto.err||'')+'</span>'):''):'<span class="bad">'+esc(r.err||'')+'</span>'}).catch(function(e){$('pkres').innerHTML='<span class="bad">'+esc(e.message)+'</span>'})};
$('testLinks').onclick=function(){$('links').textContent='…';api('links',{}).then(function(r){$('links').innerHTML='影片库：'+(r.lb.ok?'<span class="ok">通</span> · PikPak '+esc(r.lb.pikpak):'<span class="bad">'+esc(r.lb.err)+'</span>')+'<br>传输：'+(r.transfer.ok?'<span class="ok">通</span> · rclone '+esc(r.transfer.rclone)+' · '+esc(r.transfer.core):'<span class="bad">'+esc(r.transfer.err)+'</span>')+'<br>片库：'+(r.stream.ok?(r.stream.off?'<span class="warn">不收录 /auto</span> · '+esc(r.stream.why):'<span class="ok">通</span> · 收录 '+esc(r.stream.root)+'，传完就能播放'):'<span class="bad">'+esc(r.stream.err)+'</span>')}).catch(function(e){$('links').textContent=e.message})};
$('saveCfg').onclick=function(){api('cfg',{tpl:$('tpl').value,lang:$('lang').value,grp:$('grp').value,userCap:$('userCap').value,globalCap:$('globalCap').value,pkSlots:$('pkSlots').value,vpsSlots:$('vpsSlots').value,paused:$('paused').checked,autoReady:$('autoReady').checked,tagNames:$('tagNames').checked,
 batch:$('batch').checked,batchMin:$('batchMin').value,batchMax:$('batchMax').value,batchWait:$('batchWait').value,xfers:$('xfers').value,checkers:$('checkers').value,basketMax:$('basketMax').value,tvSub:$('tvSub').value}).then(function(s){$('cfgres').innerHTML='<span class="ok">已保存</span>';render(s)}).catch(function(e){$('cfgres').innerHTML='<span class="bad">'+esc(e.message)+'</span>'})};
$('add').onclick=function(){api('add',{src:$('addSrc').value,id:$('addId').value,season:$('addSeason').value}).then(function(r){$('addres').textContent=r.joined?'已经在进行中':'已添加';load()}).catch(function(e){$('addres').textContent=e.message})};
$('reqs').onclick=function(e){var b=e.target.closest('button[data-a]');if(!b)return;var a=b.dataset.a,id=+b.dataset.id;
 if(a==='log'){api('log?id='+id).then(function(r){alert(r.items.map(function(l){return new Date(l.at).toLocaleString()+'  '+l.msg}).join('\\n')||'没有日志')});return}
 if((a==='delete'||a==='cancel')&&!confirm(a==='delete'?'删除这条记录？':'取消这条请求？（PikPak 上下了一半的会删掉）'))return;
 api('req',{id:id,act:a}).then(load).catch(function(e){alert(e.message)})};
if(KEY)load();else show(false);
setInterval(function(){if(KEY&&!document.hidden&&!$('app').classList.contains('hide'))load()},15000);
</script></body></html>`;
