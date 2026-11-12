/**
 * Cuven ᴿ 索引库 · v6.8 —— 打包：解压出来一个根文件夹，里面每 20 部一个子文件夹
 * ══════════════════════════════════════════════════════════════════
 *   Cuven索引库-日期/ _清单.txt · 001-020/ · 021-040/ …（磁力跟着进它那一段的子文件夹）。见页面里的 packLayout。
 * ══════════════════════════════════════════════════════════════════
 * v6.7 —— 导入清单：剧集只要整季包；索引里没有的自动去论坛搜
 * ══════════════════════════════════════════════════════════════════
 *   · 剧集只认「全 N 集 / 全集 / 完结」，挑画质最好的一版并锁定；只有单集 / 一段的标「未完结」，给按钮手动加；
 *   · 索引里没有的（剧集版块只收已完结、电影只收近几年）：POST /api/fsearch 去论坛搜索页按片名搜，
 *     片名年份核对过才用；论坛限频时把秒数交回，浏览器倒计时等够了再搜；同一个词 30 分钟内不重搜。
 * ══════════════════════════════════════════════════════════════════
 * v6.6 —— 导入清单：库里没有的自动查好版本、放进片单，确认后再下
 * ══════════════════════════════════════════════════════════════════
 * 片单页「导入清单」：贴一张表（JSON / CSV / 每行「tmdb_id:…/title:…」/ 每行一个片名），POST /api/import 逐条查：
 *   · 库里已有的跳过；论坛有的按 res / hdr / max_gb / prefer / season 挑好版本，放进片单（电影、剧集各进各的）；
 *   · 只有 title 时先在索引里按片名 + 年份找，找不到再问 TMDB（别名 / 港台译名 / 只有英文名），同名几部交给人挑；
 *   · 只读，不写 R2；放进片单之后要人点「开始下载」才下。
 * ══════════════════════════════════════════════════════════════════
 * v6.5 —— 新进库的片几分钟内自己认出来 · 片名以字母开头的不再丢
 * ══════════════════════════════════════════════════════════════════
 * 「F1：狂飙飞车明明有，缺片里还在」：片库里的文件是「F1 The Movie 2025 …」，只有英文名、还多一截，
 * 按片名比不上，只能等 TMDB 认定 —— 而认定只在每天的定时任务或点「认定」时跑；各 isolate 的片库缓存
 * 又要三十分钟才刷新。现在：
 *   · 翻目录时的后台刷新也顺手认一批新文件（自带 24 个子请求的小配额，不碰这次调用的 50）；
 *   · 实时清单模式下片库成品五分钟回一次 R2（别的 isolate 写进去的认定结果也跟着读回来）；
 *     成品没变就沿用内存里那份，判定表不重算；页面里的目录缓存三分钟作废；
 *   · 详情页写明「片库里对上的是哪个文件、怎么对上的」（id 相同 / 片名键 / 片名认领 / 两边 id 不同）。
 * 顺手修掉：parseTitle 拿「第一个字母」当中文名的终点，「F1：狂飙飞车」「X战警」「K星异客」这类
 * 中文名切成空的，又凑不出三个字母的英文名，整帖被跳过、游标照走 —— 永远进不了索引。现在字母后面
 * 紧接着汉字就算中文名的一部分；切不出片名的帖子也连同帖子行进留底，不再悄悄丢掉。规则版本升到 v4。
 * ══════════════════════════════════════════════════════════════════
 * Cuven ᴿ 索引库 · v6.4 —— 未匹配处理管线升级 · 剧集乱码修复
 * ══════════════════════════════════════════════════════════════════
 * 一、剧集版块是 UTF-8，以前一律按 GBK 解码：「余生有你」存成「浣欑敓鏈夊姩」，五千多组全进了「未匹配」。
 *   · decodeHTML：响应头 / <meta> 声明 UTF-8 就按 UTF-8；否则能按 UTF-8 严格解开的按 UTF-8，其余按 GBK；
 *   · mojibake()：把乱码按 GBK 编回字节、再按 UTF-8 解，能还原成像样的中文就是乱码 —— 留底队列抽查，
 *     体检与「未匹配」给「重建本源索引」（先自动备份；另一个源不动；之后用极限模式重抓）。
 * 二、认定管线（matchBatch）从两轮改成最多五轮，每轮只给还没认下的组再搜一次：
 *   中文名 + 年份 → 原名 / 中文名原样 / 不锁年份 → 英文（外语片在 TMDB 上常常没有中文译名，
 *   中文结果里只剩意大利语 / 西班牙语原名）→ 拆开「A/B」两个译名、去掉副标题 → 英文去副标题。
 *   宽的几轮认出来的要求年份对得上；英文认下来的片名用论坛的中文名；配额不够或断过网的不下「认不出」的结论。
 *   规则版本升到 v3：以前「认不出」的结论作废、重试次数归零。
 * 三、「重试匹配」改成整批排队交给认定工并行认（极限模式），认不出的记一次重试。
 * ══════════════════════════════════════════════════════════════════
 * Cuven ᴿ 索引库 · v6.3 —— 缺片检测以 Stream v25 的实时清单为准
 * ══════════════════════════════════════════════════════════════════
 * 「库里有的片还显示成缺片」：总账 Received.json 是 Stream v22 写的，v25 不再写它 ——
 * 这边一直拿一份停在 v22 的快照比，之后进库的片全被判成缺片。
 * 现在以 v25 自己维护的实时清单为准（同一个 R2 桶，见「实时片库清单」一节）：
 *   · file-list-v2.json（电影文件）/ tv/list-v1.json（剧集表，带 tmdbId）/ lib-ptr.json（指纹，没变不下正文）；
 *   · 电影的 TMDB id 依次来自：总账里同一个文件的可信 id → 这边按文件名认定（英文名的外语片用英文再搜一次，
 *     年份差一年以上不认）；认出来之前，文件名与论坛发布名同一个片名键（要求同年）直接判为已有，
 *     其余按片名 + 年份认领；
 *   · 桶没挂公开域名时走 STREAM_BASE + STREAM_KEY（= Stream 的 AUTH_SECRET）；都拿不到才退回总账，
 *     片库面板与体检都会写明「总账停在哪天，之后进库的片会显示成缺片」；
 *   · 清单突然少了一大半（Dropbox 列到一半）不用它；文件名只在第一次见到时切一次，一次最多新切 800 个。
 * ══════════════════════════════════════════════════════════════════
 * Cuven ᴿ 索引库 · v6.2 —— 极限模式（默认开）
 * ══════════════════════════════════════════════════════════════════
 * 普通模式一轮的天花板是「一次调用 50 个子请求」：3 页列表 + 最多 20 组 TMDB 认定，
 * 认不完就把游标往回拨、下一轮重抓同几页。极限模式把一轮拆成三个角色（见「极限模式」一节）：
 *   · 扫描轮 /api/build?turbo=1（持锁）：只抓列表，一轮 12 页、同时 4 条（请求起点由限速治理器
 *     错开，下限 120ms，挨打照旧翻倍）；认识的片直接挂上，不认识的连同帖子行进留底队列（wait），
 *     游标一口气推到底；顺手把浏览器交回来的认定结果写进分片；
 *   · 认定工 /api/tm（不持锁、不写 R2）：浏览器同时开 3–6 路（AIMD），每路是一次独立调用、
 *     自带一整份子请求配额，只做 TMDB 认定；
 *   · 浏览器调度（页面里的 turboRun，测试跑的就是这一份）：排队、并发、退避、背压、停止时收尾。
 * 不变量：帖子行任何时候都只在「已提交的分片」或「留底队列」两处之一，掐在哪一步都不丢；
 * 已写进分片的留底条目不当场删，记进 state.pdone 跟着提交，下一次写队列时才删（pendSync）。
 * 浏览器交回来的结果逐字段核对，形状不对的拒收；冷却期只挡论坛，结果照写；排队太长先停抓、
 * 扫描轮自己认；留底队列快满就退回当场认。env.TURBO=0 一个变量退回普通模式。
 * 顺手修掉（普通模式同样受益）：
 *   · 第二轮（原名）搜索断网被判成「认不出」，帖子行只留 12 条 → 现在按网络失败、下轮再认；
 *   · 普通模式会丢片：一轮认不完的组只把游标往回拨 ceil(n/28) 页，一页不到 28 组时前面页里没认完的
 *     就再也抓不回来（测速样本里 v6.1 漏了 300 部里的 56 部）→ 现在没认完的连同帖子行进队列；
 *     已经漏掉的，升级后点一次「重扫未匹配」补回；
 *   · 同名同原名的两部片（重拍）共用一个键，留底条目把两年的帖子并在一起、重试时全写进一年，
 *     另一年的增量再挂一遍就重复了 → 每行带上自己的年份；
 *   · 锁只核对、锁龄超过 8 秒才续写（每轮少写一次 state.json，R2 10058 少撞）；
 *     冷启动并发抓页只登录一次；限速治理器先占位再睡，并发请求不会同一刻冲出去。
 * ══════════════════════════════════════════════════════════════════
 * Cuven ᴿ 索引库 · v6 —— 缺片检测重做 · 原子提交 · 多重兜底
 * ══════════════════════════════════════════════════════════════════
 * 一、缺片检测（libOwn，见「缺片检测」一节；标准答案与压测在 tests/）
 *   v5.4 在随机生成的六千部片海上：误藏（缺片被当成已有藏掉）七百部，精确率 66%。
 *   原因是三条规则太宽：认下来的条目也照样按「片名 + 年份 ±1」把同名的另一部片藏掉；
 *   没年份的条目只按片名一撞就藏，一个「Dune.mkv」能藏掉两部《沙丘》；Stream 认错的 id
 *   照单全收。片名比对只做小写去符号，繁体、全角、重音、罗马数字、冠词、第二部全对不上。
 *   v6：可信 id 精确比；没有可信 id 的条目「认领」索引里的一部片（名字先、年份后，
 *   并列就谁都不认）；名字互相矛盾的不认（港台译名例外：长英文名 + 同年照认）；
 *   id 的年份或中英文名与文件名全对不上就判为认错；剧集允许季目录年份晚于首播。
 *   同一份压测：电影精确率 99.2–99.7%、召回率 99.6–99.8%，剧集 99.3% / 99.2%。
 *   判定整张表按（索引版本, 片库成品）算一次，查目录每部片只剩一次数组读取（27ms → 9ms）。
 * 二、存储（见「原子提交」一节）
 *   · 读失败不再当成「不存在」（v5 会用空表覆盖整个索引）；内容损坏拒绝覆盖；
 *   · 分片与 tid 表 copy-on-write，写 state.json 才算提交，平台随时掐进程都不留半截；
 *   · 锁带身份、条件写抢锁、提交前核对并续期；影片表只增不减的检查；
 *   · 每天自动备份 movies / state / 留底队列，体检里一键恢复；孤儿对象自动清理。
 * 四、界面（v6.1）：设计语言对齐 Cuven Transfer
 *   · 纸面：径向纸 + 18px 点阵（中心干净、边缘有颗粒）；色彩改 oklch，白云蓝以 L C H 三元组为源；
 *   · 交互重点色改黑（主行动、选中年份、片单勾选），白云蓝只留给数据（进度、实时流、链接、聚焦环）；
 *   · 圆角阶梯 30 / 13 / 16 / 11，同心；卡片 1px 描边 + 极浅投影；控件白底发丝描边；
 *   · 导航：一块玻璃 + 一块白 thumb 在项间平移改宽；手机上落成底部 354×68 的玻璃坞（图标 + 字）；
 *   · 片单动作坞改成浮着的玻璃胶囊（手机上坐在坞的正上方），退场走加速曲线；
 *   · 顺手修掉：手机顶栏左右没有留白（商标和搜索框贴着屏幕边）、外观钮的 ◐ 被钉在角上裁掉一半、
 *     「DOLBY VISION」角标在窄海报上压住版本数、详情页顶栏换成三行盖住片名。
 * 三、其它兜底：源闸门卡死自动放行；所有出站请求带超时；种子按 bencode 逐层解析
 *   （v5 会在文件名里含「4:info」时算错 btih、遇到截断的种子死循环）；海报代理不再因
 *   上游断网抛异常；取件遇到限速 / 断网自动重试（每部最多 4 次）而不是直接记为失败。
 * ══════════════════════════════════════════════════════════════════
 * Cuven ᴿ 索引库 · v5.4 —— 片库对照改吃总账
 * ══════════════════════════════════════════════════════════════════
 * v5.4 只动片库对照这一块，索引管线与界面一行未改。
 *
 * 起因：Stream v22 把「库里有什么 + 每条对应哪个 TMDB 编号」在它那边
 * 算好了，落成 R2 上的 Received.json。这里那套「扫描 → 送 TMDB 认定 →
 * 记 id」于是整段变成多余的 —— 而它恰好是这个 Worker 最大的一笔开销：
 * 一个上千部的片库要上千次 TMDB 搜索，只能靠 todo 队列一批批磨，
 * 磨完要好几轮 cron，期间每一轮都在跟建索引抢子请求预算。
 *
 *   1) 新增总账直读。配了 RECV_BASE（或 Stream 那边放行 /api/received）
 *      就走这条路：取回总账、按源分拣、抄 id。零 TMDB 请求，一次调用
 *      做完，todo 永远是空的。「认定」那个按钮在这个模式下不再出现。
 *
 *   2) 顺带修掉一个一直存在的错配。老管线不分源，两个源都去拉 /api/all
 *      —— 那是电影目录。剧集源于是拿电影文件名去 TMDB 搜剧，认出来的
 *      id 属于另一套编号，比对结果基本是噪声。总账里电影和剧集在同一份
 *      里、各自带 type，按 type 分拣之后剧集源才第一次真的比到了剧集库。
 *
 *   3) gen 没变就不下正文，也不写 R2。先问 120 字节的指针；相同就收工。
 *      片库一天不动，这条链路一天只花两个子请求。
 *
 *   4) 老管线原样保留。后端还没升到 v22（404）、总账还在建（空）、
 *      或者两个地址都没配 —— 全部自动落回 v5.3 的行为，一个分支都没删。
 *
 *   新增变量  RECV_BASE  公开 R2 自定义域，如 https://data.cuven.online
 *            首选它 —— 绕开 Stream 的 AUTH_SECRET，不必配任何口令。
 * ══════════════════════════════════════════════════════════════════
 * v5.3 —— HIERARCHY / STABILITY / EFFICIENCY
 * ══════════════════════════════════════════════════════════════════
 * v5.3 不动索引管线的算法，只做三件事：层级、稳定、效率。
 *
 * 【稳定】
 *   1) 子请求预算的并发隔离（服务端最要紧的一处）。预算是「按调用」算的，
 *      计数器却是 isolate 全局的：以前每个请求进门都 subReset —— 正在跑
 *      的建索引会被任何一个并发请求（哪怕一张海报）把计数清零，接着越过
 *      平台 50 次硬线被掐，锁留在 R2 里。现在只有重活登记预算，轻请求与
 *      海报代理只计数不清零；重活之间接着现有计数（宁可算多提前收工）。
 *   2) 前端 api() 带超时与可中止：目录请求换筛选就掐掉上一个，不再有
 *      「S.busy 永远为真、无限滚动死掉」的挂起；分页失败给出重试。
 *   3) 详情与目录各用各的请求戳，开详情不再作废正在加载的目录。
 *   4) 详情开着切标签时改用 replaceState，历史不再错位；关详情回到它
 *      真正盖着的那一页（片单里点开的，关掉回片单）。
 *   5) IndexedDB 打开失败不再钉死；后台线程崩溃会把挂着的活全部报错并
 *      重建；本地计算的超时计时器用完即清。
 *   6) 页面响应加 Referrer-Policy: no-referrer —— 带口令的地址不再随
 *      IMDb / 论坛外链泄露；海报 404 不再被浏览器缓存三十天。
 *
 * 【效率】
 *   1) 页面按 ETag 协商，没变就 304，不再每次重传整页。
 *   2) 片库页的壳（标题 / 筛选台 / 汇总）只搭一次，换筛选只换网格，
 *      筛选台原地改选中态 —— 年份条不再跳回开头、不再整页重排。
 *   3) 海报卡片改事件委托：整页一套监听，不再每张卡挂六个。
 *   4) 下载进行中只原地改数字、进度与行状态，不再每批整页重画（海报
 *      不再重闪、滚动位置不丢）；系统页进度也是原地补丁。
 *   5) 帧率监控只在交互后的 2.5 秒窗口与动画进行中运行，空闲时不再
 *      常驻 rAF 烧电。
 *
 * 【层级】
 *   1) 配色按全局约定：白底，第一重点色白云蓝（主行动 / 选中 / 聚焦 /
 *      进度 / 实时数据），第二重点色黑（商标、性价比之选、提示）。
 *      白底之后卡片改靠 1px 描边 + 轻阴影分层，令牌集中在 :root 顶部。
 *   2) 标签改成 片库 / 片单 / 系统。片库筛选台分两层：排序 + 年份常驻，
 *      评分 / 动态范围 / 画质 / 已有 收进「筛选」，有非默认项时亮起并计数。
 *   3) 系统页只留：四个数字、一句状态、一个主动作；管线 / 年份进度 /
 *      未匹配 / 片库对照 / 日志 / 维护 全部收进可展开区，展开状态跨
 *      刷新保留。片库汇总行不再显示性能调度信息（挪到管线区）。
 * ══════════════════════════════════════════════════════════════════
 * v5.2 只修一件事：剧集源「新帖 150 · 入库 0 · 新片 0」。
 *
 * 病灶在 parseTitle。它靠"第一个拉丁字母 / 第一个年份"来划片名的边界
 * —— 电影标题里几乎总带年份，这条线一直是准的；剧集不写年份，只写
 * S01 / 全12集，于是整串规格被算进了片名：
 *
 *   恐怖角[全10集].Cape.Fear.S01.2160p.Apple.TV/.WEB-DL…
 *     v5.1 → latin = "Cape Fear 2160p Apple TV/"
 *     TMDB 的 name 是 "Cape Fear"：从「完全相同 5 分」掉成「包含 2 分」。
 *     剧集没有年份加分（电影锁年份 +4），门槛却是 5 分，
 *     2 + 海报 1 + 热度 1.5 = 4.5 —— 差半分，整版块全灭。
 *
 *   魔法姐妹露露与莉莉[全12集].1080p.CATCHPLAY…
 *     v5.1 → cn = "魔法姐妹露露与莉莉 .1080"（"1080p" 的 p 是第一个
 *     拉丁字母），拿它去 TMDB 搜，一条都搜不中。
 *
 * 五处改动：
 *   1) parseTitle 认规格词表（分辨率 / 片源 / 编码 / 音轨 / 平台），
 *      把它当作第三条切割线，cn 与 latin 都到此为止。
 *      MAX / STAN / IT / CAM 这类"正经片名里的词"故意没收进表里。
 *   2) pickTMDB 加词集重合度：译名差一两个虚词（Ace of the Diamond act
 *      对 Ace of Diamond Act II）也认得出来。
 *   3) movies.u（认不出→永久跳过）盖解析器版本戳：解析器一改就整表作废，
 *      留底队列重试次数归零，下一轮自动重认，不用人工点「重扫未匹配」；
 *      跳过标记另加七天保质期，TMDB 补了条目能自己捡回来。
 *   4) 「重试匹配」拿原始标题用新解析器重切，不再照抄留底里的旧 cn/latin。
 *   5) 一轮摘要把认定 / 认不出 / 网络失败 / 待认一起报出来；TMDB 请求
 *      失败原样记进「匹配」频道；整批失败就收工，不再空烧预算。
 *      体检加「片名认定抽查」，真的走一遍认定，这类故障一眼可见。
 * ══════════════════════════════════════════════════════════════════
 * v4.2 能跑，但有四件事一直别扭：下载要分好几个 zip、日志和进度混成
 * 一锅、片库比对靠字符串猜、以及每一轮任务都在贴着平台配额跳舞。
 * v5 把这四件事分别收口。
 *
 * 1) 下载：Worker 不再打包，改由浏览器攒
 *    /api/pack（服务端拼 zip）整个删掉 —— 它是 CPU 和内存的头号消耗者，
 *    也是"一次下载分出好几个 zip"的根因。现在：
 *      · /api/fetch 一次取 8 部（每部 2 个子请求），只回种子字节
 *      · 浏览器把每一部写进 IndexedDB，刷新 / 断网 / 关标签页都不丢
 *      · 全部取齐之后，在本地一次性压成「一个」zip 交给用户
 *      · 断点续传：任务按片单指纹认领，回来直接从缺的那几部接着取
 *
 * 2) 索引：日志分频道，管线看得见
 *    以前所有事都往一个 TRACE 里倒。现在分成 管线 / 网络 / 匹配 /
 *    片库 / 系统 五个频道，各自独立翻阅；重要事件另写进 state.events，
 *    isolate 重启也还在。管线面板画成一条真的流水线：拉取 → 解析 →
 *    匹配 → 编码 → 落盘 → 比对，每一节点带吞吐、错误与耗时。
 *
 * 3) 片库比对：先认 TMDB，再比 id
 *    v4 拿文件名归一化成「片名|年份」去猜，遇到译名、副标题、发布组
 *    命名就露馅。v5 改成：拉片库 → 每个候选送 TMDB 认一次 → 把认下来的
 *    「TMDB id + 片名 + 年份」抄进 A/list.json。索引本身就是以 TMDB id
 *    为主键的，于是热路径退化成一次整数 Set 查询：既准（id 相等，没有
 *    误伤）又快（不再做四次字符串归一化）。认不出来的留在 weak/loose
 *    里当兜底，界面上区分「库中已有」和「疑似已有」。
 *    解析结果进 KV 缓存 30 天，第二次同步几乎不花子请求。
 *
 * 4) 配额：每条管线都知道自己还剩多少
 *    Workers Free 的硬线是「单次调用 50 个子请求 / 10ms CPU / 128MB」，
 *    超了平台直接掐进程（1102），代码里 catch 不到。v5 给每一次调用配
 *    一个子请求预算（默认 42），所有出站请求都从这个预算里扣；跑到边界
 *    就收工、把游标写回 R2，下一次调用接着跑。编码侧同步瘦身：单片
 *    3200 → 1400 行，码本采样 6000 → 1600 条，服务端 zip 彻底移除。
 *
 * 5) 界面：Cuven 极简 + 丝柔缓动
 *    统一的 Silk 缓动令牌（时长 × 曲线 × 尺度）；一套本地性能调度器
 *    按设备能力把 CRC32、zip 组装、大列表筛选分派给 WebGPU / Web Worker /
 *    主线程，掉帧时自动降级动效尺度。新增「动态范围」（杜比视界 / HDR）
 *    与「画质」（4K+ / 1080p 低质量）两组筛选。
 *
 * 6) 两个源：电影版块 + 剧集版块
 *    同一个论坛下的 fid=44（电影）与 fid=2（电视剧）。除了年份筛选参数、
 *    TMDB 查 movie 还是 tv、以及各自的 R2 命名空间，整条链路是同一套。
 *      · 电影的键与 v5.0 逐字节一致 —— 老索引不迁移，升上来接着读
 *      · 剧集另占 idx/tv/ 与 A/list.tv.json，两边互不覆盖
 *      · 剧集认定前先削掉"第二季 / S02 / 全36集"，季号另记；年份不锁死
 *        （版块年份是这一季播出的年，TMDB 记的是首播年）
 *      · 一个 isolate 同一时刻只允许一个源在跑，见 srcEnter / srcLeave
 *
 * Secrets: SITE_USER / SITE_PASS / TMDB_KEY / GATE
 * 变量:    TMDB_BASE（TMDB 走自己的反代时填，可选，默认 https://api.themoviedb.org/3）
 * 变量:    RECV_BASE（片库总账 Received.json 的公开 R2 域名，首选）
 *          STREAM_BASE（片库对照的回退路径，可选）  PLAN=paid（放宽配额，可选）
 *          TURBO=0（关掉极限模式、退回普通模式，可选；默认开）
 *          STREAM_KEY（= Stream 的 AUTH_SECRET；R2 桶没挂公开域名时，用它登录 Stream 取实时片库清单，可选）
 *          TV_BASE（剧集版块若不在同一域名，单独指过去，可选）
 *          TV_FILTER（剧集版块的附加筛选，默认 tv_zhuangtai_3=2&ortid=1；
 *                     置空 = 连载中的一起收）  MOVIE_FILTER（同理，默认空）
 * 绑定:    KV（会话 / 种子 / TMDB 解析缓存）  R2（索引 + A/list*.json）
 * Cron:    每日 04:00 两个源轮流跑：增量 + 片库解析一批
 * ══════════════════════════════════════════════════════════════════
 */

const DEFAULT_BASE = 'https://10001.baidubaidu.win/';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15';
/* ══════════════════════════════════════════════════════════════════
   两个源 —— 电影版块 / 剧集版块
   ──────────────────────────────────────────────────────────────────
   同一个论坛下的两个版块。除了 fid、年份筛选参数、以及 TMDB 该查
   movie 还是 tv，整条链路（抓列表 → 切片名 → 认定 → 编码 → 落盘 →
   下载）完全是同一套，所以这里只把"不一样的那几样"列出来，其余代码
   一行不改：
     · 电影  fid=44  movie_nianfen=NN
     · 剧集  fid=2   tv_shangyingshijian_3=NN（另带一个"状态"筛选）
   两套索引各占一个 R2 命名空间，互不覆盖。电影这一套的键与 v5.0
   逐字节一致 —— 老索引不用迁移，升上来接着读。
   ══════════════════════════════════════════════════════════════════ */
const TTL = { session: 1500, thread: 3600, magnet: 86400, tmdbMeta: 604800, tmdbFind: 2592000 };

const idxKeys = (ns, v3) => ({
  movies: ns + 'movies.json',
  state:  ns + 'state.json',
  /* 分片链：电影的 p0 沿用 v4.0 的旧路径，老索引零迁移就能继续读 */
  part:   (y, i, g) => ns + 'y' + y + (i ? '.p' + i : '') + (g ? '.g' + g : '') + '.json',
  tids:   (y, g) => ns + 'y' + y + '.t' + (g ? '.g' + g : '') + '.json',
  v3,
});
/* ── 片库对照（Stream / Dropbox）──
   v4 是「文件名 → 归一化字符串 → 猜」，遇到译名和发布组命名就露馅。
   v5 是「文件名 → TMDB 认一次 → 记 id」：索引本来就以 TMDB id 为主键，
   认下来之后热路径就是一次整数 Set 查询，既准又快。认下来的片名 + 年份
   抄进成品表，它就是这套东西唯一的产出；认不出来的退回模糊键兜底。
   只需要一个变量 STREAM_BASE，不配则整套自动关闭。两个源各存一份成品，
   因为 TMDB 的 movie id 和 tv id 是两套编号，混在一起会互相误判。 */
const LIB_BASE = {
  ttl:   30 * 60_000,       // 30 分钟内直接用，过期后台刷新（SWR，不挡浏览）
  retry: 60_000,            // 拉失败后的静默期
  cap:   60000,             // 键上限
  batch: 20,                // 单次调用最多解析多少个候选（还会被子请求预算再压一次）
};
const PEND_BASE = { cap:6000, rows:12, batch:10, tries:3 };

const SRC_MOVIE = {
  id:'movie', name:'电影', unit:'部', kind:'movie',
  fid:44, ykey:'movie_nianfen', extra:'', yparam:'primary_release_year',
  baseVar:'SITE_BASE', filterVar:'MOVIE_FILTER', metaPre:'tm:',
  /* 论坛分类映射（实测抓取，年份 ID 非等差，必须硬编码） */
  years: {
    2026: 33, 2025: 32, 2024: 31, 2023: 30, 2022: 29, 2021: 28, 2020: 26,
    2019: 25, 2018: 16, 2017: 15, 2016: 13, 2015: 1, 2014: 2, 2013: 3,
    2012: 4, 2011: 5, 2010: 6, 2009: 7, 2008: 8, 2007: 9, 2006: 10,
  },
  order: [2026, 2025, 2024, 2023, 2022, 2021, 2020],
  idx: idxKeys('idx/v4/', { movies:'idx/movies.json', state:'idx/state.json',
                            rels:(y)=>'idx/rels/'+y+'.json' }),
  lib:  { ...LIB_BASE, legacy:'idx/lib.json', list:'A/list.json' },
  pend: { ...PEND_BASE, key:'idx/v5/pending.json' },
};
const SRC_TV = {
  id:'tv', name:'剧集', unit:'部', kind:'tv',
  fid:2, ykey:'tv_shangyingshijian_3',
  /* 版块自带的"状态"筛选。想连载中的一起收就把 TV_FILTER 设成空 */
  extra:'&tv_zhuangtai_3=2&ortid=1', yparam:'first_air_date_year',
  baseVar:'TV_BASE', filterVar:'TV_FILTER', metaPre:'tmtv:',
  years: { 2026:23, 2025:22, 2024:21, 2023:20, 2022:19, 2021:18, 2020:17 },
  order: [2026, 2025, 2024, 2023, 2022, 2021, 2020],
  /* v3 这一栏剧集没有历史包袱，指向永远不存在的键即可 —— 迁移那条路
     照样能跑，只是每次都会诚实地回答"没有可迁移的旧数据" */
  idx: idxKeys('idx/tv/', { movies:'idx/tv/v3.movies.json', state:'idx/tv/v3.state.json',
                            rels:(y)=>'idx/tv/v3.rels.'+y+'.json' }),
  lib:  { ...LIB_BASE, legacy:'idx/tv/lib.json', list:'A/list.tv.json' },
  pend: { ...PEND_BASE, key:'idx/tv/pending.json' },
};
const SOURCES = { movie: SRC_MOVIE, tv: SRC_TV };
const srcOf = (v) => (SOURCES[String(v||'').toLowerCase()] ? String(v).toLowerCase() : 'movie');

/* 下面这五个绑定是全局的：换源只重新绑定，从不改动对象本身 ——
   于是任何"进函数时抓了一份引用"的地方，读到的都还是同一套键。 */
let SRC = SRC_MOVIE;
let FID = SRC.fid, YEARS = SRC.years, BUILD_ORDER = SRC.order;
let IDX = SRC.idx, LIB = SRC.lib, PEND = SRC.pend;
const isTV = () => SRC.kind === 'tv';

function useSrc(id){
  const s = SOURCES[id] || SRC_MOVIE;
  if (s === SRC) return SRC;
  SRC = s; FID = s.fid; YEARS = s.years; BUILD_ORDER = s.order;
  IDX = s.idx; LIB = s.lib; PEND = s.pend;
  /* isolate 上挂着的成品缓存一律作废：它们都不带源标识，留着就是串味 */
  idxCache = null; partCache.clear();
  catCache = { ver:-1, rows:null, ord:null };
  libMem = null; libFail = 0;
  return SRC;
}

/* ══════════════════════════════════════════════════════════════════
   源闸门
   ──────────────────────────────────────────────────────────────────
   一个 isolate 会同时处理好几个请求，而"当前源"是全局的。如果一边正在
   建剧集索引、另一边来了个电影请求把源翻过去，剧集的数据就会写进电影的
   键里 —— 这是整套改动里唯一真正危险的地方。
   所以同一时刻只让一个源在跑：同源的请求随便并发，异源的排队等前一批
   走完。等太久就回 409，让前端自己重试，而不是硬闯。
   后台任务（ctx.waitUntil）也算在这一批里，否则它会跨到下一批去写键。
   ══════════════════════════════════════════════════════════════════ */
let GSRC = null, GN = 0, GWAIT = null, GDONE = null, GLAST = 0;
/* [v6] 闸门卡死的兜底：一批请求里只要有一个后台任务永远不结束（平台在 30 秒后掐掉 waitUntil，
   但那个 Promise 永远不会 settle），GN 就永远减不到 0 —— 这个 isolate 从此对另一个源一律回 409。
   现在闸门记着最后一次进出的时刻，超过 GATE_STALE 没有任何进出就当作卡死，强制放行并记一笔 */
const GATE_STALE = 120000;
async function srcEnter(id, waitMs = 25000){
  const t0 = Date.now();
  while (GN > 0 && GSRC !== id){
    if (Date.now() - GLAST > GATE_STALE){
      trace('sys', '源闸门 ' + Math.round((Date.now() - GLAST) / 1000) + ' 秒没有进出，判为卡死，强制放行（' + (SOURCES[GSRC] || {}).name + ' → ' + (SOURCES[id] || {}).name + '）', { lvl:'warn' });
      const d = GDONE; GN = 0; GDONE = null; GWAIT = null; if (d) d();
      break;
    }
    if (Date.now() - t0 > waitMs){
      const e = new Error('另一个源（' + (SOURCES[GSRC] || {}).name + '）正在运行，稍后再试');
      e.busy = 1; e.wait = 5; throw e;
    }
    await Promise.race([GWAIT, sleep(900)]).catch(()=>{});
  }
  if (GN === 0){ GSRC = id; GWAIT = new Promise(r => { GDONE = r; }); }
  GN++; GLAST = Date.now();
  useSrc(id);
  return SRC;
}
function srcLeave(){
  GLAST = Date.now();
  if (--GN > 0) return;
  GN = 0;
  const d = GDONE; GDONE = null; GWAIT = null;
  if (d) d();
}

const BUDGET_MS = 15000;    // 单轮时间预算，到点提前落盘
const LOCK_MS   = 40000;
const LOCK_RENEW = 8000;     // 锁龄超过这个才续写（只核对不写可以省掉一次 state.json 写入）
const CART_MAX  = 200;      // 打包上限（现在压在浏览器里，可以放宽）
const GRAB_MAX  = 8;        // 单次 /api/fetch 取几部：每部 2 个子请求
const ROWS_PER_MOVIE = 120;
const MIN_BODY  = 900;      // 小于这个字节数的列表页一律视为被限速/拦截

/* ── 资源上限相关 ──
   Worker 的硬线是子请求数 / CPU 时间 / 128MB 内存，超了平台直接掐进程，
   返回 503 "Worker exceeded resource limits"，代码里 catch 不到。
   所以每一轮任务的编解码工作量必须与"年份总量"解耦，只与一片有关；
   而出站请求数必须与"这一次调用"解耦，由下面的 SUB 预算统一管。
   v5 把三个编码常数按 Free 计划重新标定：单片行数减一半以上，码本采样
   减到 1600 条，服务端 zip 整个移除。 */
const PART_ROWS  = 1400;    // 单片行数上限，写满就封片，新行进下一片
const PART_CACHE = 3;       // 常驻内存的分片数上限（LRU）
const SPLIT_MAX  = 60000;   // 拆分单片时能接受的最大行数
const TRAIN_MAX  = 1600;    // 码本训练最多看多少条标题
const HEAVY_ROWS = 1400;    // 超过这个行数就不做"两种编码取小"的对照

/* ══════════════════════════════════════════════════════════════════
   Free 计划配额治理
   ──────────────────────────────────────────────────────────────────
   Workers Free 每次调用最多 50 个出站子请求。以前 buildInner 一轮要打
   8 个列表页 + 180 次 TMDB —— 一百八十几个子请求，远远越线；平台掐进程
   的时候锁还留在 R2 里，于是"跑一会儿就停、要人工点继续"。
   v5 的做法是：所有出站请求统一从一份预算里扣，管线自己随时能问
   "还剩几个"，剩得不够就当场收工、把游标写回去 —— 边界由代码守，
   不交给平台。PLAN=paid 时预算放开到 900。
   ══════════════════════════════════════════════════════════════════ */
const PLAN_FREE = { sub: 42, hard: 50, tmdb: 20, pages: 3, lib: 20, name: 'free' };
const PLAN_PAID = { sub: 900, hard: 10000, tmdb: 180, pages: 8, lib: 60, name: 'paid' };  // 2026-02 起 Paid 默认 10000/次；sub 仍保守，R2 写入频率才是真瓶颈
let PLAN = PLAN_FREE;
const planOf = (env) => (String(env && env.PLAN || '').toLowerCase() === 'paid' ? PLAN_PAID : PLAN_FREE);

/* ══════════════════════════════════════════════════════════════════
   [v6.2] 极限模式
   ──────────────────────────────────────────────────────────────────
   普通模式一轮的天花板是「一次调用 50 个子请求」：3 页列表 + 最多 20 组
   TMDB 认定。一页二三十个帖子、一轮只认得完 20 组，剩下的只好把游标
   往回拨、下一轮把同几页再抓一遍 —— 片越多，越是在原地打转。
   极限模式把一轮拆成三个角色，各用各的那份配额：
     · 扫描轮（/api/build?turbo=1，持锁）：只抓列表、只挂已认识的片，
       不认识的连同帖子行进留底队列（标 wait），游标一口气推到底，不回拨；
       顺手把浏览器交回来的认定结果写进分片；
     · 认定工（/api/tm，不持锁、不写 R2）：浏览器同时开几路，每路是一次
       独立调用、自带一整份子请求配额，只做 TMDB 认定、把结果交回浏览器；
     · 浏览器：排队、并发、退避（AIMD），把结果攒着交给下一轮扫描。
   帖子行任何时候都只在两处之一：已提交的分片，或留底队列 —— 掐在哪一步
   都不丢。已写进分片的留底条目不当场删，记进 state.pdone 跟着提交走，
   下一次写留底队列时才真正删掉（见 pendSync）。
   env.TURBO=0 是总开关：一个变量就能退回普通模式，不用改代码。 */
const TURBO_FREE = { pages: 12, conc: 4, group: 20, high: 360, need: 240, hits: 240, years: 3, sub: 46 };
const TURBO_PAID = { pages: 30, conc: 5, group: 60, high: 1200, need: 600, hits: 600, years: 4, sub: 400 };
const turboOn = (env) => String((env && env.TURBO) == null ? '' : env.TURBO).trim() !== '0';
const turboCfg = () => (PLAN.name === 'paid' ? TURBO_PAID : TURBO_FREE);
const TURBO_GAP = 120;           // 极限模式下论坛请求间隔的下限（普通模式 240）
const TURBO_GAP_START = 160;     // 没挨过打的 isolate 从这个间隔起步

const SUB = { n: 0, max: PLAN_FREE.sub, peak: 0 };
/* [v5.3] 预算是「按调用」算的，计数器却是 isolate 全局的 —— 以前每个请求进门
   都 subReset，于是正在跑的建索引会被任何一个并发请求（哪怕是一张海报）
   把计数清零，接着越过平台硬线被掐，锁留在 R2 里：这是「跑一会儿就停、
   要人工点继续」的病灶之一。
   现在只有「重活」（建索引 / 增量 / 取件 / 认定 / 修复 / cron）参与预算：
     · 第一个重活进门时清零；有别的重活在跑就接着现有计数 —— 宁可算多
       提前收工，也不能算少被平台掐；
     · 轻请求（目录 / 详情 / 帖子 / 磁力 / 状态）只计数不清零；没有重活在
       跑时它们各自是独立调用，撞不到硬线，subTake 也就不设上限；
     · 海报代理不进预算（见路由）。
   重活被平台掐掉时 finally 不会执行，所以登记带时间戳，太久的自动作废。 */
const HEAVY_RE = /^\/api\/(build|incremental|fetch|repair|diagnose|unlock|migrate|optimize|split|reset)$/;
const HEAVY = new Map();           // token → 进门时刻
const HEAVY_STALE = 150000;        // 超过这个时长还没离场的重活视为已被平台掐掉
let HEAVY_SEQ = 0;
function heavyLive(){
  const now = Date.now();
  for (const [k, t] of HEAVY) if (now - t > HEAVY_STALE) HEAVY.delete(k);
  return HEAVY.size;
}
/** 进门登记。重活返回 token，离场时交回；轻活返回 0。 */
function subEnter(env, heavy){
  PLAN = planOf(env); SUB.max = PLAN.sub;
  const live = heavyLive();
  if (!heavy){
    if (!live){ SUB.n = 0; SUB.peak = 0; }   // 没有重活时旧计数没有意义，顺手归零
    return 0;
  }
  if (!live){ SUB.n = 0; SUB.peak = 0; }
  const tok = ++HEAVY_SEQ;
  HEAVY.set(tok, Date.now());
  return tok;
}
function subLeave(tok){
  if (tok) HEAVY.delete(tok);
  if (!heavyLive()){ SUB.n = 0; SUB.peak = 0; }
}
/* 旧名字留给内部调用方：语义等于「一个重活进门」 */
function subReset(env){ return subEnter(env, true); }
const subLeft = () => Math.max(0, SUB.max - SUB.n);
/** 领子请求配额。领不到就抛 budget 错 —— 它不可重试，调用方应当收工。 */
function subTake(n){
  n = n || 1;
  /* 只有重活在跑时才有硬线可撞；纯轻请求各自是独立调用，撞不到 50 */
  if (heavyLive() && SUB.n + n > SUB.max){
    const e = new Error('子请求预算已用尽（' + PLAN.name + ' 计划单次调用 ' +
      SUB.max + '/' + PLAN.hard + '），本轮到此为止，进度已保存');
    e.budget = 1; e.sub = SUB.n;
    throw e;
  }
  SUB.n += n;
  if (SUB.n > SUB.peak) SUB.peak = SUB.n;
}
/** 唯一的出站入口：所有 fetch 都必须从这儿走，预算才算得准。
    [v6] 默认带超时（20 秒）：没有超时的 fetch 一旦挂起，整轮任务就挂到平台掐进程为止 */
const FETCH_MS = 20000;
/** [v6.2] 自带配额的调用（认定工）：计数记在调用自己身上，不碰 isolate 全局的 SUB ——
    同一个 isolate 里同时在跑的扫描轮与认定工是两次调用，各有各的 50 */
function subTakeLocal(lb){
  if (lb.n + 1 > lb.max){
    const e = new Error('本次认定的子请求预算已用完（' + lb.n + '/' + lb.max + '）');
    e.budget = 1; e.sub = lb.n;
    throw e;
  }
  lb.n++;
}
async function sfetch(u, init){
  if (init && init.sub) subTakeLocal(init.sub); else subTake(1);
  const o = init ? { ...init } : {};
  delete o.sub;
  if (!o.signal && typeof AbortSignal !== 'undefined' && AbortSignal.timeout) o.signal = AbortSignal.timeout(o.timeoutMs || FETCH_MS);
  delete o.timeoutMs;
  try { return await fetch(u, o); }
  catch (e){
    if (e && (e.name === 'TimeoutError' || e.name === 'AbortError')) throw new Error('请求超时（' + Math.round((init && init.timeoutMs || FETCH_MS) / 1000) + ' 秒没有响应）：' + String(u).replace(/api_key=[^&]+/, 'api_key=…').slice(0, 80));
    throw e;
  }
}

/* ══════════════════════════════════════════════════════════════════
   管线计数
   六个节点，每个节点记 进 / 出 / 错 / 耗时。一轮跑完连同子请求峰值一起
   写进 state.pipe，前端就能把它画成一条真的流水线，而不是一串日志。
   ══════════════════════════════════════════════════════════════════ */
const PIPE_STAGES = ['list', 'parse', 'match', 'encode', 'store', 'lib'];
const PIPE_NAME = { list:'拉取', parse:'解析', match:'匹配', encode:'编码', store:'落盘', lib:'比对' };
const PIPE = {};
function pipeReset(){ for (const k of PIPE_STAGES) PIPE[k] = { i:0, o:0, e:0, ms:0 }; }
pipeReset();
function pipe(stage, field, n){
  const s = PIPE[stage];
  if (s) s[field] = (s[field] || 0) + (n == null ? 1 : n);
}
function pipeSnap(kind, ms){
  const st = {};
  for (const k of PIPE_STAGES) st[k] = { ...PIPE[k] };
  return { at: Date.now(), kind: kind || 'build', ms: ms || 0,
           sub: SUB.peak, subMax: SUB.max, stages: st };
}
/** 把这一轮的管线快照写进 state，并留 12 轮历史给前端画趋势 */
function pipeSave(state, kind, ms){
  const snap = pipeSnap(kind, ms);
  state.pipe = snap;
  state.pipes = [{ at: snap.at, kind: snap.kind, ms: snap.ms, sub: snap.sub,
                   o: PIPE.store.o, m: PIPE.match.o, e: PIPE.list.e + PIPE.match.e }]
    .concat(state.pipes || []).slice(0, 12);
  return snap;
}

/* ══════════════════════════════════════════════════════════════════
   MFX-1 编解码
   ══════════════════════════════════════════════════════════════════ */

const A64 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_';
const I64 = (() => { const m = Object.create(null); for (let i=0;i<64;i++) m[A64[i]] = i; return m; })();
const ESC = 63;

/** 码本下标 → 变长字符串。前 63 个词元只花一个字符，所以码本必须按频次排。 */
function mfxCode(n){
  if (n < ESC) return A64[n];
  n -= ESC;
  if (n < 4096) return A64[ESC] + A64[(n>>6)&63] + A64[n&63];
  n -= 4096;
  return A64[ESC] + A64[ESC] + A64[(n>>12)&63] + A64[(n>>6)&63] + A64[n&63];
}
function mfxDecode(s, dict){
  let out = '', i = 0;
  const L = s.length;
  while (i < L){
    const c = I64[s[i++]];
    if (c === undefined) break;
    if (c !== ESC){ out += dict[c] || ''; continue; }
    if (I64[s[i]] === ESC){
      i++;
      out += dict[ESC + 4096 + ((I64[s[i]]<<12)|(I64[s[i+1]]<<6)|I64[s[i+2]])] || '';
      i += 3;
    } else {
      out += dict[ESC + ((I64[s[i]]<<6)|I64[s[i+1]])] || '';
      i += 2;
    }
  }
  return out;
}

/* 汉字/假名串、拉丁串、数字串、其余（分隔符）串 —— 拼回去必须逐字节等于原文 */
const MFX_TOK = /[\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\uff00-\uffef]+|[A-Za-z]+|\d+|[^\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\uff00-\uffefA-Za-z0-9]+/g;
const mfxTokens = (s) => String(s == null ? '' : s).match(MFX_TOK) || [];

/**
 * 码本训练：词元级 BPE。
 * 发布名里 ".2160p" "UHD.BluRay.REMUX" "DTS-HD.MA" 这类组合出现上万次，
 * 合成一个词元后，一条 80 字的标题能压到 20 出头。
 * 合并只改码本内容，解码器完全不用动 —— 合成词元就是一条更长的字典项。
 */
function trainCodebook(titles, opt = {}){
  const { rounds = 5, perRound = 200, minFreq = 8, budgetMs = 1500 } = opt;
  const t0 = Date.now();
  /* 训练只是为了找高频组合，全量和采样的结果几乎一样，而 CPU 差一个数量级。
     v4.0 这里给了 6 秒纯 CPU 预算，是 1102 的主要贡献者之一。 */
  const src = titles.length > TRAIN_MAX
    ? titles.filter((_, i) => i % Math.ceil(titles.length / TRAIN_MAX) === 0)
    : titles;
  let seqs = src.map(mfxTokens);
  for (let r = 0; r < rounds; r++){
    if (Date.now() - t0 > budgetMs) break;
    const pair = new Map();
    for (const s of seqs)
      for (let i = 0; i + 1 < s.length; i++){
        const k = s[i] + '\u0000' + s[i+1];
        pair.set(k, (pair.get(k)||0) + 1);
      }
    const top = [];
    for (const e of pair) if (e[1] >= minFreq) top.push(e);
    if (!top.length) break;
    top.sort((a,b)=>b[1]-a[1]);
    const merge = new Set(top.slice(0, perRound).map(e=>e[0]));
    if (!merge.size) break;
    seqs = seqs.map(s => {
      const o = []; let i = 0;
      while (i < s.length){
        if (i+1 < s.length && merge.has(s[i]+'\u0000'+s[i+1])){ o.push(s[i]+s[i+1]); i += 2; }
        else o.push(s[i++]);
      }
      return o;
    });
  }
  const freq = new Map();
  for (const s of seqs) for (const k of s) freq.set(k, (freq.get(k)||0) + 1);
  return [...freq.entries()]
    .sort((a,b) => b[1]-a[1] || a[0].length-b[0].length || (a[0] < b[0] ? -1 : 1))
    .map(e => e[0]);
}

/** 可增量生长的码本：新词元直接追加到尾部（拿长码，但不用重训） */
function codebook(dict){
  const pos = new Map(), span = new Map();
  const add = (k, i) => {
    pos.set(k, i);
    const t = mfxTokens(k);
    if (t.length > 1){ const f = t[0]; if ((span.get(f)||1) < t.length) span.set(f, t.length); }
  };
  dict = dict || [];
  for (let i = 0; i < dict.length; i++) add(dict[i], i);
  return {
    dict, pos, span, grown: 0,
    encode(title){
      const s = mfxTokens(title);
      let out = '', i = 0;
      while (i < s.length){
        const wide = Math.min(this.span.get(s[i]) || 1, s.length - i);
        let hit = -1, len = 1;
        for (let n = wide; n >= 1; n--){
          const cand = n === 1 ? s[i] : s.slice(i, i+n).join('');
          const p = this.pos.get(cand);
          if (p != null){ hit = p; len = n; break; }
        }
        if (hit < 0){ hit = this.dict.length; this.dict.push(s[i]); add(s[i], hit); this.grown++; }
        out += mfxCode(hit); i += len;
      }
      return out;
    },
    decode(codeStr){ return mfxDecode(codeStr, this.dict); },
  };
}

/* ── 规格位域 ── */
const SPEC = {
  res:   ['','480p','720p','1080i','1080p','2160p','4320p'],
  src:   ['','HDTV','BDRip','WEBRip','WEB','WEB-DL','BluRay','REMUX'],
  hdr:   ['','SDR','HLG','HDR','HDR10','HDRVivid','HDR10+','杜比视界'],
  aud:   ['','AAC','AC3','DDP','DTS','FLAC','DTS-HD','TrueHD','Atmos'],
  cdc:   ['','H.264','H.265','AV1','VC-1'],
};
const L_GUO = 1<<19, L_YUE = 1<<20, L_SUB = 1<<21, L_FX = 1<<22, L_MULTI = 1<<23;

function packSpec(pr){
  const lb = pr.tags.map(t=>t.label).join(' ');
  const g = (k, re) => pr.tags.some(t => t.kind===k && re.test(t.label));
  let res = 0;
  if (g('res',/4320|8K/i)) res = 6; else if (g('res',/2160|4K/i)) res = 5;
  else if (g('res',/1080p/i)) res = 4; else if (g('res',/1080i/i)) res = 3;
  else if (g('res',/720/i)) res = 2;
  let src = 0;
  if (g('src',/REMUX/i)) src = 7; else if (g('src',/BluRay|Blu-ray|UHD/i)) src = 6;
  else if (g('src',/WEB-DL/i)) src = 5; else if (g('src',/^WEB$/i)) src = 4;
  else if (g('src',/WEBRip/i)) src = 3; else if (g('src',/BDRip/i)) src = 2;
  else if (g('src',/HDTV|HDRip|DVDRip/i)) src = 1;
  let hdr = 0;
  if (g('hdr',/杜比视界|DoVi|Dolby|^DV$/i)) hdr = 7; else if (g('hdr',/HDR10\+/i)) hdr = 6;
  else if (g('hdr',/HDRVivid/i)) hdr = 5; else if (g('hdr',/HDR10/i)) hdr = 4;
  else if (g('hdr',/\bHDR\b/i)) hdr = 3; else if (g('hdr',/HLG/i)) hdr = 2;
  else if (g('hdr',/SDR/i)) hdr = 1;
  let aud = 0;
  if (g('audio',/Atmos/i)) aud = 8; else if (g('audio',/TrueHD/i)) aud = 7;
  else if (g('audio',/DTS-HD|DTS-?X/i)) aud = 6; else if (g('audio',/FLAC|LPCM/i)) aud = 5;
  else if (g('audio',/DTS/i)) aud = 4; else if (g('audio',/DDP|DD\+|E-?AC-?3/i)) aud = 3;
  else if (g('audio',/AC3/i)) aud = 2; else if (g('audio',/AAC/i)) aud = 1;
  let cdc = 0;
  if (g('codec',/AV1/i)) cdc = 3; else if (g('codec',/x265|HEVC|H\.?265/i)) cdc = 2;
  else if (g('codec',/x264|AVC|H\.?264/i)) cdc = 1; else if (g('codec',/VC-1/i)) cdc = 4;
  let v = res | (src<<4) | (hdr<<8) | (aud<<12) | (cdc<<16);
  if (/国语|国英|国粤/.test(lb)) v |= L_GUO;
  if (/粤语|国粤/.test(lb)) v |= L_YUE;
  if (/中文字幕|中英|简英|内封|外挂|特效/.test(lb)) v |= L_SUB;
  if (/特效/.test(lb)) v |= L_FX;
  if (/多音轨|双语/.test(lb)) v |= L_MULTI;
  return v;
}
const specRes = (v) => SPEC.res[v & 15] || null;
function specLabels(v){
  const o = [];
  if (SPEC.res[v & 15]) o.push(SPEC.res[v & 15]);
  if (SPEC.src[(v>>4) & 15]) o.push(SPEC.src[(v>>4) & 15]);
  if (SPEC.hdr[(v>>8) & 15]) o.push(SPEC.hdr[(v>>8) & 15]);
  if (SPEC.aud[(v>>12) & 15]) o.push(SPEC.aud[(v>>12) & 15]);
  if (SPEC.cdc[(v>>16) & 7]) o.push(SPEC.cdc[(v>>16) & 7]);
  if (v & L_GUO) o.push('国语');
  else if (v & L_YUE) o.push('粤语');
  if (v & L_FX) o.push('特效字幕'); else if (v & L_SUB) o.push('中字');
  return o;
}
/** 位域直接算分，不用再碰标题 */
function specScore(v, mb){
  const res=v&15, src=(v>>4)&15, hdr=(v>>8)&15, aud=(v>>12)&15, cdc=(v>>16)&7;
  let s = [0,4,8,18,22,40,50][res] || 0;
  s += [0,2,7,7,12,12,16,22][src] || 0;
  s += [0,0,4,7,7,8,10,14][hdr] || 0;
  s += [0,1,2,2,4,4,7,8,12][aud] || 0;
  s += [0,0,3,3,1][cdc] || 0;
  if (v & L_GUO) s += 8;
  if (v & L_FX) s += 4; else if (v & L_SUB) s += 3;
  if (mb){ const gb = mb/1024;
    if (gb>=50) s+=6; else if (gb>=20) s+=5; else if (gb>=8) s+=3; else if (gb<2) s-=6; }
  return s;
}

const b36 = (n) => Math.max(0, Math.round(n)).toString(36);
const un36 = (s) => parseInt(s, 36) || 0;
/** 详情页短地址：全站唯一、稳定，/t/<sid> 可直达 */
const sidOf = (tid) => Number(tid).toString(36);
const tidOf = (sid) => { const v = parseInt(String(sid||''), 36); return Number.isFinite(v) && v > 0 ? v : 0; };
const sizeText = (mb) => !mb ? null : (mb >= 1024 ? (mb/1024).toFixed(1)+' GB' : mb+' MB');

/**
 * 分片：列式 + 码本。groups 形如 { tmdbId: [ {tid,title,spec,mb,score}, ... ] }
 * 存量码本传进来可复用（增量写不重训），传 null 则重训。
 */
function encodeShard(year, groups, dictIn){
  const ids = Object.keys(groups).map(Number)
    .filter(id => groups[id] && groups[id].length).sort((a,b)=>a-b);
  const flat = [];
  for (const id of ids) for (const r of groups[id]) flat.push(r);
  if (!flat.length) return { v:4, y:year, b:0, d:[], i:[], c:[], t:'', n:[], s:[], z:[], q:[], rows:0 };

  let dict = dictIn;
  if (!dict) dict = trainCodebook(flat.map(r=>r.title));
  const cb = codebook(dict.slice());

  let bmin = Infinity;
  for (const r of flat){ const t = Number(r.tid); if (t < bmin) bmin = t; }

  const tids = [], names = [], specs = [], mbs = [], scs = [];
  for (const r of flat){
    tids.push(b36(Number(r.tid) - bmin));
    names.push(cb.encode(r.title));
    specs.push(r.spec|0);
    mbs.push(r.mb|0);
    scs.push(r.score|0);
  }
  return {
    v: 4, y: year, b: bmin, d: cb.dict,
    i: ids, c: ids.map(id => groups[id].length),
    t: tids.join('.'), n: names, s: specs, z: mbs, q: scs, rows: flat.length,
  };
}
/**
 * 重训码本不一定更小 —— BPE 合出来的长词元要占 d 数组，行数少的时候
 * 反而可能亏。所以两种都编一遍取小的，保证"优化"永远是单调的。
 * 行数太多时跳过对照（省 CPU），直接按重训走。
 */
function encodeBest(year, groups, oldDict, rowCap = HEAVY_ROWS){
  const rows = Object.values(groups).reduce((a,x)=>a+x.length, 0);
  const fresh = encodeShard(year, groups, null);
  if (!oldDict || oldDict.length < 32 || rows > rowCap) return { sh: fresh, retrain: true };
  const kept = encodeShard(year, groups, oldDict.slice());
  return JSON.stringify(kept).length <= JSON.stringify(fresh).length
    ? { sh: kept, retrain: false } : { sh: fresh, retrain: true };
}

function decodeShard(sh){
  const out = {};
  if (!sh || !sh.i || !sh.i.length) return out;
  const dict = sh.d || [];
  const tids = sh.t ? sh.t.split('.') : [];
  let p = 0;
  for (let k = 0; k < sh.i.length; k++){
    const id = sh.i[k], n = sh.c[k], rows = [];
    for (let j = 0; j < n; j++, p++){
      rows.push({
        tid: sh.b + un36(tids[p]),
        title: mfxDecode(sh.n[p] || '', dict),
        spec: sh.s[p]|0, mb: sh.z[p]|0, score: sh.q[p]|0,
      });
    }
    out[id] = rows;
  }
  return out;
}
/** 两份分片内容是否逐行相同（压实 / 拆分之后核对用） */
function sameGroups(a, b){
  const ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (const id of ka){
    const x = a[id], y = b[id];
    if (!y || x.length !== y.length) return false;
    for (let i = 0; i < x.length; i++){
      const p = x[i], q = y[i];
      if (p.tid !== q.tid || p.title !== q.title || p.spec !== q.spec || p.mb !== q.mb || p.score !== q.score) return false;
    }
  }
  return true;
}
/** 只解一部片，避免为看一部片解开整个分片 */
function shardRows(sh, id){
  if (!sh || !sh.i) return [];
  const k = sh.i.indexOf(Number(id));
  if (k < 0) return [];
  let off = 0;
  for (let j = 0; j < k; j++) off += sh.c[j];
  const dict = sh.d || [], tids = sh.t ? sh.t.split('.') : [], rows = [];
  for (let j = 0; j < sh.c[k]; j++){
    const p = off + j;
    rows.push({
      tid: sh.b + un36(tids[p]),
      title: mfxDecode(sh.n[p] || '', dict),
      spec: sh.s[p]|0, mb: sh.z[p]|0, score: sh.q[p]|0,
    });
  }
  return rows;
}

/* 影片记录压成数组，省掉一整份键名 */
/* HB / RB 是 v5 加的两个聚合位：全部片源里出现过的最高动态范围与最高
   分辨率。以前只有"最佳片源"的分辨率字符串，于是"这部片有没有杜比视界版"
   这种问题必须解开分片才答得出 —— 筛选就没法做。放两个小整数在影片记录
   上，筛选退化成一次整数比较。老索引读出来是 undefined，按 0 处理，
   跑一次「重算汇总」就补齐。 */
/* K（v6）：[CANON_V, canon(中文名), canon(原名)] —— 缺片检测的比对键，建索引时算好存下，
   冷启动的 isolate 不必为三万部片重算一遍；规则版本对不上（或老记录没有）就现场算 */
const F = { N:0, O:1, Y:2, P:3, T:4, C:5, G:6, YS:7, R:8, B:9, Q:10, Z:11, BT:12,
             SP:13, BM:14, HB:15, RB:16, K:17 };
const newMovie = (hit, y) => {
  const t = hit.title || '', o = hit.original_title || '';
  return [
    t, o, (hit.release_date||'').slice(0,4),
    hit.poster_path || '', hit.vote_average ? +hit.vote_average.toFixed(1) : 0,
    hit.vote_count || 0, hit.genre_ids || [], [y], 0, 0, null, null, null,
    null, 0, 0, 0, [CANON_V, canon(t), canon(o)],
  ];
};
/** 老记录补上比对键（建索引 / 增量 / 重算这几条重活顺手做，请求路径上不做） */
function movieKeysFill(movies, cap){
  let n = 0;
  for (const id in movies.m){
    const mv = movies.m[id];
    const k = mv[F.K];
    if (Array.isArray(k) && k[0] === CANON_V) continue;
    mv[F.K] = [CANON_V, canon(mv[F.N]), canon(mv[F.O])];
    if (++n >= (cap || 1e9)) break;
  }
  return n;
}
const newYear = () => ({ page:1, last:0, done:false, bad:[] });

/** SP：{ 年份: [分片号...] } —— 详情只读真正装着这部片的那几片 */
function markPart(mv, y, pi){
  const sp = mv[F.SP] && typeof mv[F.SP] === 'object' ? mv[F.SP] : (mv[F.SP] = {});
  const a = sp[y] || (sp[y] = []);
  if (!a.includes(pi)) a.push(pi);
}
/** 动态范围 / 分辨率取全片源最大值 —— 与"最佳片源"是两回事：
    一部片可能最佳是 REMUX SDR，另有一个体积小的杜比视界版，两个都要认。 */
function bumpSpec(mv, r){
  const res = r.spec & 15, hdr = (r.spec >> 8) & 15;
  if (res > (mv[F.RB] || 0)) mv[F.RB] = res;
  if (hdr > (mv[F.HB] || 0)) mv[F.HB] = hdr;
}
/** 最佳片源增量维护：分数优先，同分取体积大的（不再重排整部片的片源） */
function bumpBest(mv, r){
  const bs = mv[F.B] || 0, bm = mv[F.BM] || 0;
  if (r.score > bs || (r.score === bs && (r.mb||0) > bm)){
    mv[F.B] = r.score; mv[F.BM] = r.mb || 0; mv[F.Q] = specRes(r.spec);
    mv[F.BT] = sidOf(r.tid); mv[F.Z] = sizeText(r.mb);
  }
}

/* ══════════════════════════════════════════════════════════════════
   基础设施
   ══════════════════════════════════════════════════════════════════ */

const memCache = new Map();
const MEM_MAX = 300;        // 未绑定 KV 时的兜底缓存上限：无界会 OOM
const mem = {
  async get(k){ const v = memCache.get(k); if(!v||v.exp<Date.now()){memCache.delete(k);return null;} return v.val; },
  async put(k,v,o){
    if (memCache.size >= MEM_MAX){
      const now = Date.now();
      for (const [key, val] of memCache) if (val.exp < now) memCache.delete(key);
      while (memCache.size >= MEM_MAX) memCache.delete(memCache.keys().next().value);
    }
    memCache.set(k,{val:v,exp:Date.now()+((o?.expirationTtl||600)*1000)});
  },
  async delete(k){ memCache.delete(k); },
};
const kv = (env) => env.KV || mem;
/* 站点地址按源取：剧集若不在同一域名，配 TV_BASE 单独指过去；
   不配就跟电影同站（两个版块本来就在一个论坛里）。 */
const base = (env) => String(env[SRC.baseVar] || env.SITE_BASE || DEFAULT_BASE).replace(/\/?$/, '/');
const hostOf = (u) => { try { return new URL(u).host; } catch { return ''; } };
/* 会话 / 种子 / 磁力这三样是"跟着站点走"的缓存：同站沿用旧键（升级不用
   重登），换了站才另起一份，免得两个站的 tid 撞在同一个键上。 */
const kkey = (env, k) => {
  const h = hostOf(base(env));
  return (!h || h === hostOf(String(env.SITE_BASE || DEFAULT_BASE))) ? k : h.split('.')[0] + '/' + k;
};
const jget = async (env,k) => { const v = await kv(env).get(k); try { return v?JSON.parse(v):null; } catch { return null; } };
const jput = (env,k,v,t) => kv(env).put(k, JSON.stringify(v), { expirationTtl: t });
const json = (o,st=200) => new Response(JSON.stringify(o), { status: st,
  headers: { 'content-type':'application/json; charset=utf-8', 'cache-control':'no-store' } });
const sleep = (ms) => new Promise(r=>setTimeout(r,ms));

/* ══════════════════════════════════════════════════════════════════
   日志 —— 分频道
   ──────────────────────────────────────────────────────────────────
   v4 把限速、解析失败、片库同步、锁竞争全倒进同一个环形数组，出事的时候
   得在里面拿眼睛筛。v5 分五个频道各自成列，前端可以只看一列；
   err/warn 另外抄一份进 state.events，写 R2 时一起落盘，isolate 重启
   之后仍然查得到"上次到底是怎么断的"。
   ══════════════════════════════════════════════════════════════════ */
const LOG_CH = { pipe:'管线', net:'网络', match:'匹配', lib:'片库', sys:'系统' };
const CH_OF = {
  net:'net', server:'net', rate:'net', client:'net', auth:'net', timeout:'net', budget:'net',
  parse:'pipe', index:'pipe', build:'pipe', cron:'pipe', encode:'pipe',
  tmdb:'match', match:'match',
  lib:'lib',
};
const LVL_OF = {
  rate:'warn', budget:'warn', auth:'warn',
  net:'err', server:'err', client:'err', parse:'err', timeout:'err',
};
const TRACE = [];
const TRACE_MAX = 240;
function trace(kind, msg, extra){
  const e = extra || {};
  TRACE.unshift({
    at: Date.now(), kind,
    ch: e.ch || CH_OF[kind] || 'sys',
    lvl: e.lvl || LVL_OF[kind] || 'info',
    msg: String(msg == null ? '' : msg).slice(0, 220),
    ...e,
  });
  if (TRACE.length > TRACE_MAX) TRACE.length = TRACE_MAX;
}
/** 只读频道视图，/api/logs 用 */
function traceView(ch, n){
  const list = ch && ch !== 'all' ? TRACE.filter(x => x.ch === ch) : TRACE;
  return list.slice(0, Math.max(1, Math.min(200, n || 60)));
}
/** 重要事件抄进 state：跟着 R2 一起落盘，重启不丢 */
function eventsFlush(state, extra){
  const keep = TRACE.filter(x => x.lvl !== 'info')
    .slice(0, 12)
    .map(x => ({ at:x.at, ch:x.ch, lvl:x.lvl, msg:x.msg }));
  const add = (extra || []).concat(keep);
  if (!add.length) return;
  const seen = new Set();
  state.events = add.concat(state.events || [])
    .filter(x => { const k = x.at + '|' + x.msg; if (seen.has(k)) return false; seen.add(k); return true; })
    .slice(0, 80);
}

/** 错误分级 —— 决定"重试 / 换会话 / 放弃" */
function classify(e){
  if (e && e.budget) return 'budget';
  const m = String(e && e.message || e);
  /* 'rate' 是关键的一类：论坛被打太急时不返回 429，而是回一个几百字节的
     空壳页 —— v3 把它当成"没有帖子"或"登录墙"，于是年份被标完成、
     或者反复重登把状况搞得更糟。 */
  if (/子请求预算/.test(m)) return 'budget';
  if (/限速|空响应|响应过短|拦截|冷却中|HTTP 429|HTTP 503|HTTP 403|Too Many/i.test(m)) return 'rate';
  if (/登录墙|登录态|需要登录|验证码|账号或密码/i.test(m)) return 'auth';
  if (/HTTP 5\d\d/.test(m)) return 'server';
  if (/HTTP 4\d\d/.test(m)) return 'client';
  if (/GBK|解析失败|bencode/i.test(m)) return 'parse';
  return 'net';
}
/* budget 不在里面：预算用尽再重试只会更快撞平台的硬线 */
const RETRYABLE = new Set(['net','server','rate']);

/**
 * 自动重试：指数退避 + 抖动，尊重 Retry-After，按错误类型决定要不要再来一次。
 * 每次失败都进 TRACE，自诊断面板能看到到底卡在哪一层。
 */
async function autoRetry(label, fn, opt = {}){
  const { tries = 4, gap = 500, cap = 8000, onRetry = null, left = null } = opt;
  let last;
  for (let i = 0; i < tries; i++){
    try { return await fn(i, last ? classify(last) : null); }
    catch (e){
      last = e;
      const cls = classify(e);
      if (cls === 'budget') throw e;                       // 预算用尽：立刻收工
      trace(cls, label + ': ' + (e.message||e), { try: i+1 });
      if (i === tries - 1 || !RETRYABLE.has(cls)) break;
      /* 重试也要花子请求：剩不下就不必再等了 */
      if ((left ? left() : subLeft()) < 1) break;
      let wait = Math.min(cap, gap * Math.pow(2, i)) * (0.7 + Math.random()*0.6);
      if (e.retryAfter) wait = Math.max(wait, e.retryAfter * 1000);
      if (cls === 'rate') wait = Math.max(wait, 1500 * (i+1));
      if (onRetry) { try { await onRetry(cls, i); } catch {} }
      await sleep(wait);
    }
  }
  throw last;
}

/* ══════════════════════════════════════════════════════════════════
   自适应限速治理器
   论坛限速是这套东西最常见的故障源。策略：成功就慢慢加速，被限速就
   指数减速；连续挨打就打开断路器冷却，冷却状态写进 R2，让其它 isolate
   和 cron 一起忍着，别接着打。
   ══════════════════════════════════════════════════════════════════ */
const GOV = { gap: 260, last: 0, strikes: 0, wins: 0, until: 0, why: '' };
/* [v6.2] 间隔下限随模式变：极限模式 120ms、普通模式 240ms。加速只在「连续 3 次干净」之后，
   挨一次打照旧翻倍（≥ 600ms）—— 下限放低，退避一点没放松 */
let GOV_FLOOR = 240;
function govMode(turbo){
  GOV_FLOOR = turbo ? TURBO_GAP : 240;
  if (turbo && !GOV.strikes && GOV.gap > TURBO_GAP_START) GOV.gap = TURBO_GAP_START;
}

function govPenalize(why){
  GOV.strikes++; GOV.wins = 0;
  GOV.gap = Math.min(9000, Math.max(600, GOV.gap * 2));
  if (GOV.strikes >= 4){
    GOV.until = Date.now() + Math.min(15*60000, 60000 * Math.pow(2, GOV.strikes - 4));
    GOV.why = why || '连续被限速';
    trace('rate', '断路器打开，冷却 ' + Math.round((GOV.until-Date.now())/1000) + 's（' + GOV.why + '）');
  }
}
function govReward(){
  GOV.wins++;
  if (GOV.wins >= 3){                       // 连续 3 次干净的响应才算真的缓过来了
    GOV.gap = Math.max(GOV_FLOOR, Math.round(GOV.gap * 0.75));
    if (GOV.strikes) GOV.strikes--;
    GOV.wins = 0;
  }
}
const govCoolLeft = () => Math.max(0, GOV.until - Date.now());
async function govGate(){
  const left = govCoolLeft();
  if (left > 0){
    const e = new Error('论坛限速冷却中，还需 ' + Math.ceil(left/1000) + ' 秒');
    e.cooling = Math.ceil(left/1000);
    throw e;
  }
  /* [v6.2] 先占位再睡：几个请求同时进门时各自排到前一个之后 gap 毫秒，
     而不是算出同一个等待时长、睡醒一起冲出去 */
  const now = Date.now();
  const at = Math.max(now, GOV.last + GOV.gap);
  GOV.last = at;
  if (at > now) await sleep(at - now);
}
/** 冷却状态跨 isolate 共享 */
function govLoad(state){
  const c = state && state.cool;
  if (c && c.until > Date.now() && c.until > GOV.until){
    GOV.until = c.until; GOV.why = c.why || '';
    GOV.strikes = Math.max(GOV.strikes, c.strikes || 4);
    GOV.gap = Math.max(GOV.gap, c.gap || GOV.gap);
  }
}
function govSave(state){
  if (govCoolLeft() > 0) state.cool = { until: GOV.until, why: GOV.why, strikes: GOV.strikes, gap: GOV.gap };
  else if (state.cool) delete state.cool;
}

/* ══════════ GBK ══════════ */
let dec = null;
function decodeGBK(b){
  if(!dec){ try{ dec = new TextDecoder('gbk'); }catch{ throw new Error('运行时不支持 GBK，请把 compatibility_date 提到 2023-08-01 之后'); } }
  return dec.decode(b);
}
let gtab = null;
/** GBK 编码表：字 → [前导字节, 尾字节]。第一次用到时用 TextDecoder 反查出来（约两万字，几毫秒） */
function gbkTable(){
  if (gtab) return gtab;
  const d = new TextDecoder('gbk'); gtab = new Map();
  for (let l=0x81;l<=0xfe;l++){
    const by=[],pr=[];
    for (let t=0x40;t<=0xfe;t++){ if(t===0x7f) continue; by.push(l,t); pr.push([l,t]); }
    const cs = Array.from(d.decode(new Uint8Array(by)));
    if (cs.length !== pr.length) continue;
    for (let i=0;i<cs.length;i++) if (cs[i]!=='\uFFFD' && !gtab.has(cs[i])) gtab.set(cs[i], pr[i]);
  }
  return gtab;
}
function gbkEncode(s){
  let out = '', tab = null;
  for (const ch of s){
    const c = ch.codePointAt(0);
    if (c < 0x80){ out += /[A-Za-z0-9\-_.~]/.test(ch) ? ch : '%'+c.toString(16).toUpperCase().padStart(2,'0'); continue; }
    if (!tab) tab = gbkTable();
    const p = tab.get(ch);
    out += p ? '%'+p[0].toString(16).toUpperCase()+'%'+p[1].toString(16).toUpperCase() : encodeURIComponent(ch);
  }
  return out;
}

/* ══════════════════════════════════════════════════════════════════
   [v6.4] 页面编码自适应 + 乱码识别
   ──────────────────────────────────────────────────────────────────
   以前一律按 GBK 解码。剧集版块回的是 UTF-8 —— 于是「余生有你」存成了「浣欑敓鏈夊姩」，
   片名切不出来、TMDB 认不出，5000 多组全进了「未匹配」；认上的也只靠英文那一截，可能认错。
   现在：响应头 / <meta> 声明了 UTF-8 就按 UTF-8；没声明或声明 GBK 时，能按 UTF-8 严格解开、
   又确实有非 ASCII 字符的也按 UTF-8（GBK 的汉字几乎不可能凑成合法的 UTF-8：B0–BF 开头的字节
   在 UTF-8 里只能当后续字节），其余按 GBK。
   已经存进去的乱码靠 mojibake() 认出来：把它按 GBK 编回字节、再按 UTF-8 解 —— 乱码能还原成
   像样的中文（替换符很少），真中文会解出一堆替换符。认出来之后在体检和「未匹配」里给「重建本源索引」。
   ══════════════════════════════════════════════════════════════════ */
const ENC_SEEN = { utf8: 0, gbk: 0 };
let u8fatal = null, u8loose = null;
function declaredCharset(b, r){
  const ct = r && r.headers ? String(r.headers.get('content-type') || '') : '';
  let m = /charset\s*=\s*["']?([\w-]+)/i.exec(ct);
  if (!m){
    let head = '';
    const n = Math.min(b.length, 2048);
    for (let i = 0; i < n; i++) head += String.fromCharCode(b[i]);
    m = /<meta[^>]+charset\s*=\s*["']?([\w-]+)/i.exec(head);
  }
  return m ? m[1].toLowerCase() : '';
}
function decodeHTML(buf, r){
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let hi = false;
  for (let i = 0; i < b.length; i++) if (b[i] >= 0x80){ hi = true; break; }
  if (!hi) return decodeGBK(b);                                     // 纯 ASCII：怎么解都一样
  const cs = declaredCharset(b, r);
  if (cs === 'utf-8' || cs === 'utf8'){
    if (!u8loose) u8loose = new TextDecoder('utf-8');
    ENC_SEEN.utf8++;
    return u8loose.decode(b);
  }
  if (!u8fatal) u8fatal = new TextDecoder('utf-8', { fatal: true });
  try { const t = u8fatal.decode(b); ENC_SEEN.utf8++; return t; } catch {}
  ENC_SEEN.gbk++;
  return decodeGBK(b);
}
/** 一段文字的 GBK 字节（编不出来的字跳过） */
function gbkBytes(s){
  const tab = gbkTable(), out = [];
  for (const ch of String(s || '')){
    const c = ch.codePointAt(0);
    if (c < 0x80){ out.push(c); continue; }
    const p = tab.get(ch);
    if (p) out.push(p[0], p[1]);
  }
  return new Uint8Array(out);
}
/** 是不是「UTF-8 当成 GBK 解出来」的乱码 */
function mojibake(s){
  s = String(s || '');
  let hi = 0;
  for (const ch of s) if (ch.charCodeAt(0) > 0x7f && ch !== '\uFFFD') hi++;
  if (hi < 3) return false;
  if (!u8loose) u8loose = new TextDecoder('utf-8');
  const u = u8loose.decode(gbkBytes(s));
  let bad = 0, cjk = 0;
  for (const ch of u){ if (ch === '\uFFFD') bad++; else if (/[\u3400-\u9fff]/.test(ch)) cjk++; }
  return cjk >= 2 && bad * 3 <= cjk;
}

/* ══════════ 会话 ══════════ */
function setCookies(r){
  const jar = {};
  const list = typeof r.headers.getSetCookie === 'function' ? r.headers.getSetCookie()
    : (r.headers.get('set-cookie') ? [r.headers.get('set-cookie')] : []);
  for (const line of list){ const kvp = line.split(';')[0], i = kvp.indexOf('=');
    if (i>0) jar[kvp.slice(0,i).trim()] = kvp.slice(i+1).trim(); }
  return jar;
}
const jarStr = (j) => Object.entries(j).map(([k,v])=>k+'='+v).join('; ');

/** 单次请求，走限速闸门；HTTP 异常抬成带分类的错误 */
async function rawReq(env, path, o = {}){
  const url = /^https?:/.test(path) ? path : base(env)+path.replace(/^\//,'');
  const h = { 'User-Agent':UA, 'Accept':'text/html,*/*;q=0.8', 'Accept-Language':'zh-CN,zh;q=0.9' };
  if (o.cookie) h.Cookie = o.cookie;
  if (o.referer) h.Referer = o.referer;
  if (o.body != null) h['Content-Type'] = 'application/x-www-form-urlencoded';
  if (!o.noGate) await govGate();
  let r;
  try { r = await sfetch(url, { method:o.method||'GET', headers:h, body:o.body||null, redirect:'manual' }); }
  catch (e){
    if (e.budget) throw e;
    govPenalize('连接失败'); throw new Error('连接论坛失败：' + (e.message||e));
  }
  if (r.status === 429 || r.status === 403 || r.status === 503){
    govPenalize('HTTP ' + r.status);
    const e = new Error('HTTP ' + r.status + '（被限速或拦截）');
    e.retryAfter = Number(r.headers.get('retry-after')) || 0;
    throw e;
  }
  if (r.status >= 500){ govPenalize('HTTP ' + r.status); throw new Error('HTTP ' + r.status); }
  return r;
}
const req = (env, path, o = {}) => autoRetry('fetch '+String(path).slice(0,60), () => rawReq(env, path, o));

/**
 * 取正文，并把"空/过短"识别成限速 —— 这正是线上看到
 * 「论坛可达 1199ms · 响应为空或过短」之后一路崩下去的起点。
 */
async function reqHTML(env, path, o = {}){
  const r = await rawReq(env, path, o);
  const buf = await r.arrayBuffer();
  const html = decodeHTML(buf, r);
  if (buf.byteLength < MIN_BODY){
    govPenalize('响应过短');
    const e = new Error('论坛返回空响应（HTTP ' + r.status + '，仅 ' + buf.byteLength +
      ' 字节）—— 基本可以确定被限速或 WAF 拦截');
    e.preview = strip(html).slice(0, 90);
    throw e;
  }
  govReward();
  return { r, html, bytes: buf.byteLength };
}

/* [v6.2] 登录合流：极限模式一轮里几页同时抓，冷启动的 isolate 没有会话时，
   不能让每一页各登录一次（白花子请求，也最像机器人） */
let SESS_JOB = null;
async function session(env, force){
  if (!force){ const hit = await jget(env, kkey(env,'sess')); if (hit?.cookie) return hit; }
  if (SESS_JOB) return SESS_JOB;
  SESS_JOB = login(env);
  try { return await SESS_JOB; }
  finally { SESS_JOB = null; }
}
async function login(env){
  if (!env.SITE_USER || !env.SITE_PASS) throw new Error('缺少 SITE_USER / SITE_PASS');
  const B = base(env);
  const first = await reqHTML(env, 'member.php?mod=logging&action=login');
  const jar0 = setCookies(first.r), page = first.html;
  const fh = page.match(/name="formhash" value="(\w+)"/)?.[1];
  const lh = page.match(/loginhash=(\w+)"/)?.[1];
  if (!fh || !lh) throw new Error('登录表单解析失败（论坛改版或被挡）');
  if (/seccodeverify|seccode_/i.test(page)) throw new Error('登录页出现验证码，请先在浏览器手动登录一次');

  const r = await req(env,'member.php?mod=logging&action=login&loginsubmit=yes&loginhash='+lh+'&inajax=1', {
    method:'POST', cookie: jarStr(jar0), referer: B+'member.php?mod=logging&action=login',
    body: 'formhash='+fh+'&referer='+encodeURIComponent(B)+'&loginfield=username'
        + '&username='+gbkEncode(env.SITE_USER)
        + '&password='+encodeURIComponent(env.SITE_PASS)
        + '&questionid=0&answer=&cookietime=2592000&loginsubmit=true',
  });
  const jar = { ...jar0, ...setCookies(r) };
  const reply = decodeHTML(await r.arrayBuffer(), r);
  if (!/欢迎您回来|succeedhandle_/.test(reply)){
    const why = (reply.match(/<!\[CDATA\[([\s\S]{0,220})/)?.[1]||'').replace(/<[^>]+>/g,'').trim();
    throw new Error('论坛登录失败：'+(why||'账号或密码不正确'));
  }
  const cookie = jarStr(jar);
  if (!cookie)
    throw new Error('登录成功但没拿到 Cookie —— 缓存不了会话，每个请求都会重登并很快被限速');
  const s = { cookie, at: Date.now() };
  await jput(env, kkey(env,'sess'), s, TTL.session);
  return s;
}
async function dropSession(env){
  const k = kkey(env,'sess');
  memCache.delete(k);
  await kv(env).delete(k).catch(()=>{});
}

async function authed(env, path, o = {}, again = true){
  const s = await session(env);
  const r = await req(env, path, { ...o, cookie: s.cookie });
  if (r.status>=300 && r.status<400 && /action=login/.test(r.headers.get('location')||'')){
    if (!again) throw new Error('登录态失效');
    await dropSession(env);
    return authed(env, path, o, false);
  }
  return r;
}

/* ══════════ 解析 ══════════ */
const ents = (s) => String(s).replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>')
  .replace(/&quot;/g,'"').replace(/&#0?39;|&apos;/g,"'").replace(/&nbsp;|\u3000/g,' ')
  .replace(/&#(\d+);/g,(m,d)=>String.fromCodePoint(+d));
const strip = (s) => ents(String(s||'').replace(/<[^>]+>/g,'')).replace(/\s+/g,' ').trim();

/** [修复 2] 只判"登录/权限"；长度问题已经在 reqHTML 里按限速处理了 */
function loginWall(html){
  if (!html) return true;
  if (/action=login/.test(html) && /(需要先登录|请先登录|登录后才能|您需要登录|提示信息)/.test(html)) return true;
  if (/您没有权限|无权访问|抱歉，本版块|本主题需要/.test(html)) return true;
  return false;
}

/** 版块列表页 → [{tid,title}]；两套选择器互为兜底 */
function parseBoard(html){
  const seen = new Set(), out = [];
  const push = (tid, rawTitle) => {
    if (seen.has(tid)) return;
    const title = ents(rawTitle).trim();
    if (!title) return;
    const rel = parseRelease(title);
    /* 无体积、无分辨率 = 公告贴。但剧集那边有一批帖只写"全 36 集"不写规格，
       所以再给一条出路：认得出季或集的照收。 */
    if (!rel.size && !rel.tags.some(t=>t.kind==='res') && !(isTV() && EP_RE.test(title))) return;
    seen.add(tid); out.push({ tid, title });
  };
  let m;
  const a = /<a href="(\d+)_\d+\.html" title="([^"]+)"/g;
  while ((m = a.exec(html))) push(m[1], m[2]);
  const b = /<a href="[^"]*?mod=viewthread(?:&amp;|&)tid=(\d+)[^"]*"[^>]*\sclass="s xst"[^>]*>([\s\S]{2,300}?)<\/a>/g;
  while ((m = b.exec(html))) push(m[1], m[2].replace(/<[^>]+>/g,''));
  return out;
}
/** 页面是不是长得像正常列表页 —— 用来区分"真的没帖"和"页面不对" */
const looksLikeBoard = (html) => /forumdisplay|list_\d+_\d+\.html|class="th"|threadlist/i.test(html);
const lastPage = (html) => Number(html.match(new RegExp('list_' + FID + '_(\\d+)\\.html" class="last"'))?.[1]
  || html.match(/class="last"[^>]*>[^<]*?(\d+)/)?.[1]
  || html.match(/>\.{2,}\s*(\d+)</)?.[1] || 0);

/* ══════════════════════════════════════════════════════════════════
   剧集标题
   ──────────────────────────────────────────────────────────────────
   「庆余年 第二季 Joy of Life S02 2024 全36集 2160p ...」这样的标题里，
   季与集是噪声：TMDB 的条目是"一部剧"，不是"某一季"，带着"第二季"去搜
   基本搜不中。所以认定之前先把季 / 集削掉，季号单独记下来，展示的时候
   再挂回去 —— 于是同一部剧的每一季都落到同一个 TMDB 条目上，详情页里
   按季分开列。
   ══════════════════════════════════════════════════════════════════ */
const SEASON_CN = { 一:1, 二:2, 三:3, 四:4, 五:5, 六:6, 七:7, 八:8, 九:9, 十:10, 两:2, 零:0 };
const EP_RE = /(第\s*[一二三四五六七八九十百零两\d]+\s*季|\bS\d{1,2}\b|全\s?\d+\s?集|\d+\s?集全|更新?至)/i;
const TV_TRIM = /(第\s*[一二三四五六七八九十百零两\d]+\s*季|最終?[终終]?季|最終?[终終]?章|完结季|\bS(?:eason)?\s?\d{1,2}(?:\s?[-–]\s?S?\d{1,2})?(?:E\d{1,3})?\b|全\s?\d+\s?集|\d+\s?集全|更新?至\s?\d+\s?集?|第\s?\d+\s?[-–]\s?\d+\s?集|完结篇?|大结局|抢先版|连载中|連載中)/ig;
const trimTV = (s) => String(s||'').replace(TV_TRIM, ' ').replace(/\s+/g, ' ').trim();
/** 标题里的季号；认不出来按 0（当作"整部剧"或第一季） */
function seasonOf(raw){
  const t = String(raw || '');
  const m = t.match(/第\s*([一二三四五六七八九十百零两\d]+)\s*季/);
  if (m){
    const v = m[1];
    if (/^\d+$/.test(v)) return +v;
    if (v.length === 1) return SEASON_CN[v] || 0;
    if (v[0] === '十') return 10 + (SEASON_CN[v[1]] || 0);
    if (v[1] === '十') return (SEASON_CN[v[0]] || 0) * 10 + (SEASON_CN[v[2]] || 0);
    return SEASON_CN[v[0]] || 0;
  }
  const m2 = t.match(/\bS(?:eason)?\s?(\d{1,2})\b/i);
  return m2 ? +m2[1] : 0;
}

const SEPY = /(^|[.\s(（\-])((?:19|20)\d{2})(?=[.\s)）\-]|$)/;

/* ══════════════════════════════════════════════════════════════════
   [v5.2 修复 1] 规格 / 平台 / 编码词表 —— 片名到这儿为止
   ──────────────────────────────────────────────────────────────────
   电影标题里几乎总带年份，年份天然就是「片名到此结束」的那条线，所以
   v5.1 只认年份和第一个拉丁字母。剧集这边不写年份，只写 S01 / 全12集，
   于是整串规格被当成了片名的一部分，两种走法都塌了：

     · 有英文名：Cape.Fear.S01.2160p.Apple.TV/.WEB-DL…
         latin = "Cape Fear 2160p Apple TV/"
         TMDB 的 name 是 "Cape Fear" —— 从「完全相同 5 分」掉成
         「互相包含 2 分」。剧集没有年份加分（电影有 +4），门槛又是 5，
         2 + 海报 1 + 热度 1.5 = 4.5，差半分，全军覆没。
         这就是「新帖 150 · 入库 0 · 新片 0」的根因。
     · 没英文名：魔法姐妹露露与莉莉[全12集][中文字幕].1080p.CATCHPLAY…
         "1080p" 的 p 成了第一个拉丁字母，中文名被切成
         「魔法姐妹露露与莉莉 .1080」—— 拿它去搜，一条都搜不中。

   把这些词认出来当第三条切割线，两种走法就都恢复了。
   ══════════════════════════════════════════════════════════════════ */
const TECH_WORDS = [
  /* 分辨率 / 画质 */
  '\\d{3,4}[ip]', '4320p', '2160p', '1080[ip]', '720p', '576p', '480p', '[248]K', 'UHD', 'FHD',
  /* 动态范围 */
  'HDR10\\+?', 'HDRVivid', 'HDR', 'DoVi', 'Dolby\\.?Vision', 'DV', 'HLG', 'SDR', 'HFR', 'IMAX',
  /* 片源 */
  'WEB-?DL', 'WEB-?Rip', 'WEBDL', 'WEB', 'BluRay', 'Blu-?ray', 'REMUX', 'BDRip', 'BDRemux',
  'DVDRip', 'DVDScr', 'DVD', 'HDRip', 'HDTV', 'TVRip', 'HDTC',
  /* 编码 */
  'x26[45]', 'H\\.?26[45]', 'HEVC', 'AVC', 'AV1', 'VC-1', 'MPEG-?\\d?', 'XviD', 'DivX',
  /* 音轨 */
  'DDP?\\+?[\\d.]*', 'DD\\+', 'TrueHD[\\d.]*', 'Atmos', 'DTS-?HD(?:\\.?MA)?[\\d.]*', 'DTS-?X',
  'DTS[\\d.]*', 'E-?AC-?3', 'AC-?3', 'FLAC[\\d.]*', 'LPCM', 'PCM', 'AAC[\\d.]*', 'OPUS',
  /* 平台 —— 剧集这边最常见的一档噪声 */
  /* 只收不会跟真片名撞的：MAX / STAN / IT / CAM 都是正经片名里的词，
     放进来会把「Mad.Max.Fury.Road」切成「Mad」，得不偿失 */
  'AMZN', 'NF', 'Netflix', 'DSNP', 'HMAX', 'ATVP', 'AppleTVPlus', 'Apple\\.?TV\\+?',
  'CATCHPLAY', 'NowPlayer', 'MyTVSuper', 'ViuTV', 'Viu', 'KKTV', 'LineTV', 'FriDay',
  'Bahamut', 'Baha', 'B-?Global', 'Bilibili', 'iQIYI', 'Youku', 'MGTV', 'HULU', 'PCOK',
  'CRAV', 'iTunes', 'ColorWEB',
];
/* 前后都得靠着分隔符，免得吃掉真片名里的词（DVDRip 不会被当成 DVD） */
const TECH_RE = new RegExp('(?:^|[\\s.\\[(（|/·_-])(?:' + TECH_WORDS.join('|') +
  ')(?=$|[\\s.\\[)）|/·_-])', 'i');
/** 第一个规格词的下标（不含前导分隔符）；没有就 -1 */
function techAt(s){
  const m = TECH_RE.exec(String(s || ''));
  if (!m) return -1;
  return m.index + (/^[\s.\[(（|/·_-]/.test(m[0]) ? 1 : 0);
}

function parseTitle(raw){
  let t = String(raw).trim().replace(/\s*\d+(?:\.\d+)?\s*(?:TB|GB|MB)\s*$/i,'');
  if (isTV()) t = trimTV(t);
  const years = [...new Set(t.match(/(?:19|20)\d{2}/g)||[])];
  const s = t.replace(/\[[^\]]*\]/g,' ').replace(/【[^】]*】/g,' ').replace(/\s+/g,' ').trim();
  let iLat = s.search(/[A-Za-z]/);
  /* [v6.5] 中文名以字母开头（「F1：狂飙飞车」「X战警」「K星异客」「V字仇杀队」）：字母后面紧接着就是汉字，
     这几个字母是中文名的一部分 —— 以前拿「第一个字母」当中文名的终点，中文名切成空的，
     又凑不出三个字母的英文名，整帖被跳过、永远进不了索引。英文名从汉字之后的第一个字母算起 */
  const iCJK = s.search(/[\u3400-\u9fff]/);
  if (iLat >= 0 && iCJK > iLat && iCJK - iLat <= 8 && !/\s/.test(s.slice(iLat, iCJK))){
    const r2 = s.slice(iCJK).search(/[A-Za-z]/);
    iLat = r2 >= 0 ? iCJK + r2 : -1;
  }
  const my = s.match(SEPY);
  const iYr = my ? my.index + my[1].length : -1;
  const iTech = techAt(s);
  const cuts = [iLat, iYr, iTech].filter(i => i >= 0);
  const cut = cuts.length ? Math.min(...cuts) : -1;
  let cn = cut>0 ? s.slice(0,cut) : (cut===0 ? '' : s);
  cn = cn.split(/[\/｜|]/)[0].replace(/[\s.·:：\-—]+$/,'').replace(/^[\s.]+/,'').trim();
  let latin = null;
  /* 拉丁名只有排在规格词前面才算数：排在后面的那串是发布组的规格，不是片名 */
  if (iLat >= 0 && (iTech < 0 || iLat < iTech)){
    const tail = s.slice(iLat);
    const m2 = tail.match(SEPY), t2 = techAt(tail);
    const ends = [m2 ? m2.index : -1, t2].filter(i => i >= 0);
    let seg = (ends.length ? tail.slice(0, Math.min(...ends)) : tail)
      .replace(/\./g,' ').replace(/\s+/g,' ').trim()
      .replace(/\b(BluRay|WEB|REMUX|UHD|HDTV|Trilogy|Collection|CC|Extended|Repack|V2|USA|FRENCH|Hybrid|BDRip)\b.*$/i,'')
      .replace(/[\s.·:：\-—/|]+$/,'').trim();
    if (seg.length>=3 && /[A-Za-z]{3}/.test(seg)) latin = seg;
  }
  if (!cn && latin) cn = latin;
  return { cn, latin, years };
}
const norm = (s) => String(s||'').toLowerCase().replace(/[^a-z0-9\u4e00-\u9fa5]/g,'');

/* ══════════════════════════════════════════════════════════════════
   片名比对键 canon（v6）
   ──────────────────────────────────────────────────────────────────
   norm 只做「小写 + 去掉非字母数字」，于是同一部片换个写法就对不上：
     復仇者聯盟（繁体） ↔ 复仇者联盟      ＩＮＴＥＲＳＴＥＬＬＡＲ（全角） ↔ Interstellar
     Amélie（重音） ↔ Amelie             Rocky II ↔ Rocky 2      The Batman ↔ Batman
     沙丘：第二部 ↔ 沙丘2                Dune: Part Two ↔ Dune Part 2
   canon 把这些都折到同一个键上。它只用来「比」：索引的归并键（groupKey）
   仍然用 norm —— 换掉它会让 movies.k 里认过的键全部失效、整库重认一遍。
   繁转简的字表与 Stream 那边（字幕繁转简）是同一张。
   ══════════════════════════════════════════════════════════════════ */
const ZH_T = `㑮㑯㑳㑶㒓㓄㓨㔋㖮㗲㗿㘉㘓㘔㘚㛝㜄㜏㜐㜗㜢㜷㞞㟺㠏㠣㢗㢝㥮㦎㦛㦞㨻㩋㩜㩳㩵㪎㯤㰙㵗㵾㶆㷍㷿㸇㹽㺏㺜㻶㿖㿗㿧䀉䀹䁪䁻䂎䃮䅐䅳䆉䉑䉙䉬䉲䉶䊭䊷䊺䋃䋔䋙䋚䋦䋹䋻䋼䋿䌈䌋䌖䌝䌟䌥䌰䍤䍦䍽䎙䎱䓣䕤䕳䖅䗅䗿䙔䙡䙱䚩䛄䛳䜀䜖䝭䝻䝼䞈䞋䞓䟃䟆䟐䠆䠱䡐䡩䡵䢨䤤䥄䥇䥑䥕䥗䥩䥯䥱䦘䦛䦟䦯䦳䧢䪊䪏䪗䪘䪴䪾䫀䫂䫟䫴䫶䫻䫾䬓䬘䬝䬞䬧䭀䭃䭑䭔䭿䮄䮝䮞䮠䮫䮰䮳䮾䯀䯤䰾䱀䱁䱙䱧䱬䱰䱷䱸䱽䲁䲅䲖䲘䲰䳜䳢䳤䳧䳫䴉䴋䴬䴱䴴䴽䵳䵴䶕䶲丟並乾亂亙亞佇佈佔併來侖侶侷俁係俓俔俠俥俬倀倆倈倉個們倖倫倲偉偑側偵偽傌傑傖傘備傢傭傯傳傴債傷傾僂僅僉僑僕僞僤僥僨僱價儀儁儂億儈儉儎儐儔儕儘償儣優儭儲儷儸儺儻儼兇兌兒兗內兩冊冑冪凈凍凙凜凱別刪剄則剋剎剗剛剝剮剴創剷剾劃劇劉劊劌劍劏劑劚勁勑動務勛勝勞勢勣勩勱勳勵勸勻匭匯匱區協卹卻卽厙厠厤厭厲厴參叄叢吒吳吶呂咼員哯唄唓唸問啓啞啟啢喎喚喪喫喬單喲嗆嗇嗊嗎嗚嗩嗰嗶嗹嘆嘍嘓嘔嘖嘗嘜嘩嘪嘮嘯嘰嘳嘵嘸嘺嘽噁噅噓噚噝噞噠噥噦噯噲噴噸噹嚀嚇嚌嚐嚕嚙嚛嚥嚦嚧嚨嚮嚲嚳嚴嚶嚽囀囁囂囃囅囈囉囌囑囒囪圇國圍園圓圖團圞垻埡埨埬埰執堅堊堖堚堝堯報場塊塋塏塒塗塚塢塤塵塸塹塿墊墜墠墮墰墲墳墶墻墾壇壈壋壎壓壗壘壙壚壜壞壟壠壢壣壩壪壯壺壼壽夠夢夥夾奐奧奩奪奬奮奼妝姍姦娙娛婁婡婦婭媈媧媯媰媼媽嫋嫗嫵嫺嫻嫿嬀嬃嬇嬈嬋嬌嬙嬡嬣嬤嬦嬪嬰嬸嬻孃孄孆孇孋孌孎孫學孻孾孿宮寀寠寢實寧審寫寬寵寶將專尋對導尷屆屍屓屜屢層屨屩屬岡峯峴島峽崍崑崗崙崢崬嵐嵗嵼嵽嵾嶁嶄嶇嶈嶔嶗嶘嶠嶢嶧嶨嶮嶸嶹嶺嶼嶽巊巋巒巔巖巗巘巰巹帥師帳帶幀幃幓幗幘幝幟幣幩幫幬幹幾庫廁廂廄廈廎廕廚廝廞廟廠廡廢廣廧廩廬廳弒弔弳張強彃彄彆彈彌彎彔彙彠彥彫彲彿後徑從徠復徵徹徿恆恥悅悞悵悶悽惡惱惲惻愛愜愨愴愷愻愾慄態慍慘慚慟慣慤慪慫慮慳慶慺慼慾憂憊憐憑憒憖憚憢憤憫憮憲憶憸憹懀懇應懌懍懎懞懟懣懤懨懲懶懷懸懺懼懾戀戇戔戧戩戰戱戲戶拋挩挱挾捨捫捱捲掃掄掆掗掙掚掛採揀揚換揮揯損搖搗搵搶摋摐摑摜摟摯摳摶摺摻撈撊撏撐撓撝撟撣撥撧撫撲撳撻撾撿擁擄擇擊擋擓擔據擟擠擣擫擬擯擰擱擲擴擷擺擻擼擽擾攄攆攋攏攔攖攙攛攜攝攢攣攤攪攬敎敓敗敘敵數斂斃斅斆斕斬斷斸於旂旣昇時晉晛晝暈暉暐暘暢暫曄曆曇曉曊曏曖曠曥曨曬書會朥朧朮東枴柵柺査桱桿梔梖梘梜條梟梲棄棊棖棗棟棡棧棲棶椏椲楇楊楓楨業極榘榦榪榮榲榿構槍槓槤槧槨槫槮槳槶槼樁樂樅樑樓標樞樠樢樣樤樧樫樳樸樹樺樿橈橋機橢橫橯檁檉檔檜檟檢檣檭檮檯檳檵檸檻櫃櫅櫍櫓櫚櫛櫝櫞櫟櫠櫥櫧櫨櫪櫫櫬櫱櫳櫸櫻欄欅欇權欍欏欐欑欒欓欖欘欞欽歎歐歟歡歲歷歸歿殘殞殢殤殨殫殭殮殯殰殲殺殻殼毀毆毊毿氂氈氌氣氫氬氭氳氾汎汙決沒沖況泝洩洶浹浿涇涗涼淒淚淥淨淩淪淵淶淺渙減渢渦測渾湊湋湞湧湯溈準溝溡溫溮溳溼滄滅滌滎滙滬滯滲滷滸滻滾滿漁漊漍漚漢漣漬漲漵漸漿潁潑潔潕潙潚潛潣潤潯潰潷潿澀澅澆澇澐澗澠澤澦澩澫澬澮澱澾濁濃濄濆濕濘濚濛濜濟濤濧濫濰濱濺濼濾濿瀂瀃瀅瀆瀇瀉瀋瀏瀕瀘瀝瀟瀠瀦瀧瀨瀰瀲瀾灃灄灍灑灒灕灘灙灝灡灣灤灧灩災為烏烴無煇煉煒煙煢煥煩煬煱熂熅熉熌熒熓熗熚熡熰熱熲熾燀燁燈燉燒燖燙燜營燦燬燭燴燶燻燼燾爃爄爇爍爐爖爛爥爧爭爲爺爾牀牆牘牽犖犛犞犢犧狀狹狽猌猙猶猻獁獃獄獅獊獎獨獩獪獫獮獰獱獲獵獷獸獺獻獼玀玁珼現琱琺琿瑋瑒瑣瑤瑩瑪瑲瑻瑽璉璊璕璗璝璡璣璦璫璯環璵璸璼璽璾璿瓄瓅瓊瓏瓔瓕瓚瓛甌甕產産甦甯畝畢畫異畵當畼疇疊痙痠痮痾瘂瘋瘍瘓瘞瘡瘧瘮瘱瘲瘺瘻療癆癇癉癐癒癘癟癡癢癤癥癧癩癬癭癮癰癱癲發皁皚皟皰皸皺盃盜盞盡監盤盧盨盪眝眞眥眾睍睏睜睞瞘瞜瞞瞤瞶瞼矇矉矑矓矚矯硃硜硤硨硯碕碙碩碭碸確碼碽磑磚磠磣磧磯磽磾礄礆礎礐礒礙礦礪礫礬礮礱祕祿禍禎禕禡禦禪禮禰禱禿秈稅稈稏稜稟種稱穀穇穌積穎穠穡穢穩穫穭窩窪窮窯窵窶窺竄竅竇竈竊竚竪竱競筆筍筧筴箇箋箏節範築篋篔篘篠篢篤篩篳篸簀簂簍簑簞簡簢簣簫簹簽簾籃籅籋籌籔籙籛籜籟籠籤籩籪籬籮籲粵糉糝糞糧糰糲糴糶糹糺糾紀紂紃約紅紆紇紈紉紋納紐紓純紕紖紗紘紙級紛紜紝紞紟紡紬紮細紱紲紳紵紹紺紼紿絀絁終絃組絅絆絍絎結絕絙絛絝絞絡絢絥給絧絨絪絰統絲絳絶絹絺綀綁綃綄綆綇綈綉綋綌綎綏綐綑經綖綜綝綞綟綠綡綢綣綧綪綫綬維綯綰綱網綳綴綵綸綹綺綻綽綾綿緄緇緊緋緍緑緒緓緔緗緘緙線緝緞緟締緡緣緤緦編緩緬緮緯緰緱緲練緶緷緸緹緻緼縈縉縊縋縍縎縐縑縕縗縛縝縞縟縣縧縫縬縭縮縯縰縱縲縳縴縵縶縷縸縹縺總績繂繃繅繆繈繏繐繒繓織繕繚繞繟繡繢繨繩繪繫繬繭繮繯繰繳繶繷繸繹繻繼繽繾繿纁纆纇纈纊續纍纏纓纔纕纖纗纘纚纜缽罃罈罌罎罰罵罷羅羆羈羋羣羥羨義羵羶習翫翬翹翽耬耮聖聞聯聰聲聳聵聶職聹聻聽聾肅脅脈脛脣脥脩脫脹腎腖腡腦腪腫腳腸膃膕膚膞膠膢膩膹膽膾膿臉臍臏臗臘臚臟臠臢臥臨臺與興舉舊舘艙艣艤艦艫艱艷芻苧茲荊莊莖莢莧菕華菴菸萇萊萬萴萵葉葒葝葤葦葯葷蒍蒐蒓蒔蒕蒞蒭蒼蓀蓆蓋蓧蓮蓯蓴蓽蔄蔔蔘蔞蔣蔥蔦蔭蔯蔿蕁蕆蕎蕒蕓蕕蕘蕝蕢蕩蕪蕭蕳蕷蕽薀薆薈薊薌薑薔薘薟薦薩薳薴薵薹薺藍藎藝藥藪藭藴藶藷藹藺蘀蘄蘆蘇蘊蘋蘚蘞蘟蘢蘭蘺蘿虆虉處虛虜號虧虯蛺蛻蜆蝀蝕蝟蝦蝨蝸螄螞螢螮螻螿蟂蟄蟈蟎蟘蟜蟣蟬蟯蟲蟳蟶蟻蠀蠁蠅蠆蠍蠐蠑蠔蠙蠟蠣蠦蠨蠱蠶蠻蠾衆衊術衕衚衛衝袞裊裏補裝裡製複褌褘褲褳褸褻襀襇襉襏襓襖襗襘襝襠襤襪襬襯襰襲襴襵覈見覎規覓視覘覛覡覥覦親覬覯覲覷覹覺覼覽覿觀觴觶觸訁訂訃計訊訌討訏訐訑訒訓訕訖託記訛訜訝訞訟訢訣訥訨訩訪設許訴訶診註証詀詁詆詊詎詐詑詒詓詔評詖詗詘詛詝詞詠詡詢詣試詩詪詫詬詭詮詰話該詳詵詷詼詿誂誄誅誆誇誋誌認誑誒誕誘誚語誠誡誣誤誥誦誨說誫説誰課誳誴誶誷誹誺誼誾調諂諄談諉請諍諏諑諒諓論諗諛諜諝諞諟諡諢諣諤諥諦諧諫諭諮諯諰諱諲諳諴諶諷諸諺諼諾謀謁謂謄謅謆謉謊謎謏謐謔謖謗謙謚講謝謠謡謨謫謬謭謯謱謳謸謹謾譁譂譅譆證譊譎譏譑譓譖識譙譚譜譞譟譨譫譭譯議譴護譸譽譾讀讅變讋讌讎讒讓讕讖讚讜讞豈豎豐豔豬豵豶貓貗貙貝貞貟負財貢貧貨販貪貫責貯貰貲貳貴貶買貸貺費貼貽貿賀賁賂賃賄賅資賈賊賑賒賓賕賙賚賜賝賞賟賠賡賢賣賤賦賧質賫賬賭賰賴賵賺賻購賽賾贃贄贅贇贈贉贊贋贍贏贐贑贓贔贖贗贚贛贜赬趕趙趨趲跡踐踰踴蹌蹔蹕蹟蹠蹣蹤蹳蹺蹻躂躉躊躋躍躎躑躒躓躕躘躚躝躡躥躦躪軀軉車軋軌軍軏軑軒軔軕軗軛軜軝軟軤軨軫軬軲軷軸軹軺軻軼軾軿較輄輅輇輈載輊輋輒輓輔輕輖輗輛輜輝輞輟輢輥輦輨輩輪輬輮輯輳輶輷輸輻輼輾輿轀轂轄轅轆轇轉轊轍轎轐轔轗轟轠轡轢轣轤辦辭辮辯農迴逕這連週進遊運過達違遙遜遞遠遡適遱遲遷選遺遼邁還邇邊邏邐郟郵鄆鄉鄒鄔鄖鄟鄧鄩鄭鄰鄲鄳鄴鄶鄺酇酈醃醖醜醞醟醣醫醬醱醲醶釀釁釃釅釋釐釒釓釔釕釗釘釙釚針釟釣釤釦釧釨釩釲釳釴釵釷釹釺釾釿鈀鈁鈃鈄鈅鈆鈇鈈鈉鈋鈍鈎鈐鈑鈒鈔鈕鈖鈗鈛鈞鈠鈡鈣鈥鈦鈧鈮鈯鈰鈲鈳鈴鈷鈸鈹鈺鈽鈾鈿鉀鉁鉅鉆鉈鉉鉊鉋鉍鉑鉔鉕鉗鉚鉛鉝鉞鉠鉢鉤鉥鉦鉧鉬鉭鉮鉳鉶鉷鉸鉺鉻鉽鉾鉿銀銁銂銃銅銈銊銍銏銑銓銖銘銚銛銜銠銣銥銦銨銩銪銫銬銱銳銶銷銹銻銼鋁鋂鋃鋅鋇鋉鋌鋏鋐鋒鋗鋙鋝鋟鋠鋣鋤鋥鋦鋨鋩鋪鋭鋮鋯鋰鋱鋶鋸鋹鋼錀錁錂錄錆錇錈錏錐錒錕錘錙錚錛錜錝錞錟錠錡錢錤錥錦錨錩錫錮錯録錳錶錸錼錽鍀鍁鍃鍄鍅鍆鍇鍈鍉鍊鍋鍍鍒鍔鍘鍚鍛鍠鍤鍥鍩鍬鍭鍮鍰鍵鍶鍺鍼鍾鎂鎄鎇鎈鎊鎌鎍鎓鎔鎖鎘鎙鎚鎛鎝鎞鎡鎢鎣鎦鎧鎩鎪鎬鎭鎮鎯鎰鎲鎳鎵鎶鎷鎸鎿鏃鏆鏇鏈鏉鏌鏍鏏鏐鏑鏗鏘鏚鏜鏝鏞鏟鏡鏢鏤鏥鏦鏨鏰鏵鏷鏹鏺鏻鏽鏾鐃鐄鐇鐈鐋鐍鐎鐏鐐鐒鐓鐔鐘鐙鐝鐠鐥鐦鐧鐨鐩鐪鐫鐮鐯鐲鐳鐵鐶鐸鐺鐼鐽鐿鑀鑄鑉鑊鑌鑑鑒鑔鑕鑞鑠鑣鑥鑪鑭鑰鑱鑲鑴鑷鑹鑼鑽鑾鑿钁钂長門閂閃閆閈閉開閌閍閎閏閐閑閒間閔閗閘閝閞閡閣閤閥閨閩閫閬閭閱閲閵閶閹閻閼閽閾閿闃闆闇闈闉闊闋闌闍闐闑闒闓闔闕闖關闞闠闡闢闤闥陘陝陞陣陰陳陸陽隉隊階隑隕際隤隨險隮隯隱隴隸隻雋雖雙雛雜雞離難雲電霑霢霣霧霼霽靂靄靆靈靉靚靜靝靦靧靨鞏鞝鞦鞽鞾韁韃韆韉韋韌韍韓韙韚韛韜韝韞韠韻響頁頂頃項順頇須頊頌頍頎頏預頑頒頓頔頗領頜頠頡頤頦頫頭頮頰頲頴頵頷頸頹頻頽顂顃顅顆題額顎顏顒顓顔顗願顙顛類顢顣顥顧顫顬顯顰顱顳顴風颭颮颯颰颱颳颶颷颸颺颻颼颾飀飄飆飈飋飛飠飢飣飥飦飩飪飫飭飯飱飲飴飵飶飼飽飾飿餃餄餅餈餉養餌餎餏餑餒餓餔餕餖餗餘餚餛餜餞餡餦餧館餪餫餬餭餱餳餵餶餷餸餺餼餾餿饁饃饅饈饉饊饋饌饑饒饗饘饜饞饟饠饢馬馭馮馯馱馳馴馹馼駁駃駉駊駎駐駑駒駓駔駕駘駙駚駛駝駞駟駡駢駤駧駩駪駫駭駰駱駶駸駻駼駿騁騂騃騄騅騉騊騌騍騎騏騑騔騖騙騚騜騝騞騟騠騤騧騪騫騭騮騰騱騴騵騶騷騸騻騼騾驀驁驂驃驄驅驊驋驌驍驎驏驓驕驗驙驚驛驟驢驤驥驦驨驪驫骯髏髒體髕髖髮鬆鬍鬖鬚鬠鬢鬥鬧鬨鬩鬮鬱鬹魎魘魚魛魟魢魥魦魨魯魴魵魷魺魽鮀鮁鮃鮄鮅鮆鮈鮊鮋鮍鮎鮐鮑鮒鮓鮚鮜鮝鮞鮟鮠鮡鮣鮤鮦鮪鮫鮭鮮鮯鮰鮳鮵鮶鮸鮺鮿鯀鯁鯄鯆鯇鯉鯊鯒鯔鯕鯖鯗鯛鯝鯞鯡鯢鯤鯧鯨鯪鯫鯬鯰鯱鯴鯶鯷鯻鯽鯾鯿鰁鰂鰃鰆鰈鰉鰊鰋鰌鰍鰏鰐鰑鰒鰓鰕鰛鰜鰟鰠鰣鰤鰥鰦鰧鰨鰩鰫鰭鰮鰱鰲鰳鰵鰶鰷鰹鰺鰻鰼鰽鰾鱀鱂鱄鱅鱆鱇鱈鱉鱊鱒鱔鱖鱗鱘鱚鱝鱟鱠鱢鱣鱤鱧鱨鱭鱮鱯鱲鱷鱸鱺鳥鳧鳩鳬鳲鳳鳴鳶鳷鳼鳽鳾鴀鴃鴅鴆鴇鴉鴐鴒鴔鴕鴗鴛鴜鴝鴞鴟鴣鴥鴦鴨鴮鴯鴰鴲鴳鴴鴷鴻鴽鴿鵁鵂鵃鵊鵏鵐鵑鵒鵓鵚鵜鵝鵟鵠鵡鵧鵩鵪鵫鵬鵮鵯鵰鵲鵷鵾鶄鶇鶉鶊鶌鶒鶓鶖鶗鶘鶚鶠鶡鶥鶦鶩鶪鶬鶭鶯鶰鶱鶲鶴鶹鶺鶻鶼鶿鷀鷁鷂鷄鷅鷉鷊鷐鷓鷔鷖鷗鷙鷚鷟鷣鷤鷥鷦鷨鷩鷫鷭鷯鷲鷳鷴鷷鷸鷹鷺鷽鷿鸂鸇鸊鸋鸌鸏鸑鸕鸗鸘鸚鸛鸝鸞鹵鹹鹺鹼鹽麗麥麨麩麪麫麬麯麲麳麴麵麷麼麽黃黌點黨黲黴黶黷黽黿鼂鼉鼕鼴齊齋齎齏齒齔齕齗齘齙齜齟齠齡齣齦齧齩齪齬齭齮齯齰齲齴齶齷齼齾龍龎龐龑龓龔龕龜龭龯鿁鿓𠁞𠌥𠏢𠐊𠗣𠞆𠠎𠬙𠽃𠿕𡂡𡃄𡃕𡃤𡄔𡄣𡅏𡅯𡑍𡑭𡓁𡓾𡔖𡞵𡟫𡠹𡢃𡮉𡮣𡳳𡸗𡹬𡻕𡽗𡾱𡿖𢍰𢠼𢣐𢣚𢣭𢤩𢤱𢤿𢯷𢶒𢶫𢷮𢹿𢺳𣈶𣋋𣍐𣙎𣜬𣝕𣞻𣠩𣠲𣯩𣯴𣯶𣽏𣾷𣿉𤁣𤄷𤅶𤑳𤑹𤒎𤒻𤓌𤓎𤓩𤘀𤛮𤛱𤜆𤠮𤢟𤢻𤩂𤪺𤫩𤬅𤳷𤳸𤷃𤸫𤺔𥊝𥌃𥏝𥕥𥖅𥖲𥗇𥗽𥜐𥜰𥞵𥢢𥢶𥢷𥨐𥪂𥯤𥴨𥴼𥵃𥵊𥶽𥸠𥻦𥼽𥽖𥾯𥿊𦀖𦂅𦃄𦃩𦅇𦅈𦆲𦒀𦔖𦘧𦟼𦠅𦡝𦢈𦣎𦧺𦪙𦪽𦱌𦾟𧎈𧒯𧔥𧕟𧜗𧜵𧝞𧞫𧟀𧡴𧢄𧦝𧦧𧩕𧩙𧩼𧫝𧬤𧭈𧭹𧳟𧵳𧶔𧶧𧷎𧸘𧹈𧽯𨂐𨄣𨅍𨆪𨇁𨇞𨇤𨇰𨇽𨈊𨈌𨊰𨊸𨊻𨋢𨌈𨍰𨎌𨎮𨏠𨏥𨞺𨟊𨢿𨣈𨣞𨣧𨤻𨥛𨥟𨦫𨧀𨧜𨧰𨧱𨨏𨨛𨨢𨩰𨪕𨫒𨬖𨭆𨭎𨭖𨭸𨮂𨮳𨯅𨯟𨰃𨰋𨰥𨰲𨲳𨳑𨳕𨴗𨴹𨵩𨵸𨶀𨶏𨶮𨶲𨷲𨼳𨽏𩀨𩅙𩎖𩎢𩏂𩏠𩏪𩏷𩑔𩒎𩓣𩓥𩔑𩔳𩖰𩗀𩗓𩗴𩘀𩘝𩘹𩘺𩙈𩚛𩚥𩚩𩚵𩛆𩛌𩛡𩛩𩜇𩜦𩜵𩝔𩝽𩞄𩞦𩞯𩟐𩟗𩠴𩡣𩡺𩢡𩢴𩢸𩢾𩣏𩣑𩣫𩣵𩣺𩤊𩤙𩤲𩤸𩥄𩥇𩥉𩥑𩦠𩧆𩭙𩯁𩯳𩰀𩰹𩳤𩴵𩵦𩵩𩵹𩶁𩶘𩶰𩶱𩷰𩸃𩸄𩸡𩸦𩻗𩻬𩻮𩼶𩽇𩿅𩿤𩿪𪀖𪀦𪀾𪁈𪁖𪂆𪃍𪃏𪃒𪃧𪄆𪄕𪅂𪆷𪇳𪈼𪉸𪋿𪌭𪍠𪓰𪔵𪘀𪘯𪙏𪟖𪷓𫒡𫜦`;
const ZH_S = `𫝈㑔㑇㐹𠉂𪠟刾𪟎𪠵𠵾𪡛𠰱𪢌𫬐㘎𫝦㚯㛣𫝧𡞋𡞱𡝠𪨊𪩇㟆𫵷𪪑𢋈㤘𢛯𢗓𪫷𪮃𪮋㨫㧐擜𪯋𣘐𣗙𣳆𪷍𫞛𤆢𤈷𤎺𫞣𤠋𪺻𪼋𪽮𤻊𤽯𥁢𥅴𥇢䀥𥎝鿎𫀨𫀬𫁂𫁲𥬀𫂈𥮜𫁷𥺅䌶𫄚𫄜𫄞䌺䌻𫄩䌿䌾𫄮𦈓𦈖𦈘𦈜𦈟𦈞𦈠𦈙𫅅䍠𦍠𫅭䎬𬜯𫟕𦰴𫟑𫊪𧉞𫋲䙌𧜭𫌯𫍠𫍫䜧𫟢𫎧𧹕䞍𧹑𫎪𫎭𫎺𫎳𫎱𫏃𨅛𫟤𫟥𫟦𨑹𫟺𫠀䦂鿏𬭯𫔋𨱖𫔆䥾𨸄䦶䦷𫔵𨷿𨸟𫖅𩏼𩐀𩏿𫖫𫖬𫖱𫖰𫖲𩖗𫖺𫗇𫠈𫗊𩙮𩙯𩙧𫗟𩠇𩠈𫗱𫗰𩧭𫠊𩧰𩨁𩧿𩨇𫘮𩨏𩧪䯅𩩈鲃𫚐𫚏𩾈𫚠𩾊𩾋䲣𫠑䲝鳚𫚜𩾂鳤𪉂𫛬𫛰𫛮𫛺𫛼鹮𫜅𪎈𫜒𪎋𫜔𪑅𫜙𫜨𫜳丢并干乱亘亚伫布占并来仑侣局俣系𠇹伣侠伡私伥俩俫仓个们幸伦㑈伟㐽侧侦伪㐷杰伧伞备家佣偬传伛债伤倾偻仅佥侨仆伪𫢸侥偾雇价仪俊侬亿侩俭傤傧俦侪尽偿𠆲优𠋆储俪㑩傩傥俨凶兑儿兖内两册胄幂净冻𪞝凛凯别删刭则克刹刬刚剥剐剀创铲𠛅划剧刘刽刿剑㓥剂㔉劲𠡠动务勋胜劳势𪟝勚劢勋励劝匀匦汇匮区协恤却即厍厕历厌厉厣参叁丛咤吴呐吕呙员𠯟呗𪠳念问启哑启唡㖞唤丧吃乔单哟呛啬唝吗呜唢𠮶哔𪡏叹喽啯呕啧尝唛哗𪡃唠啸叽𪡞哓呒𪡀啴恶𠯠嘘㖊咝𪡋哒哝哕嗳哙喷吨当咛吓哜尝噜啮𪠸咽呖𠰷咙向亸喾严嘤𪢕啭嗫嚣𠱞冁呓啰苏嘱𪢠囱囵国围园圆图团𪢮坝垭𫭢𪣆采执坚垩垴𪣒埚尧报场块茔垲埘涂冢坞埙尘𫭟堑𪣻垫坠𫮃堕坛𪢸坟垯墙垦坛𡒄垱埙压𡋤垒圹垆坛坏垄垅坜𪤚坝塆壮壶壸寿够梦伙夹奂奥奁夺奖奋姹妆姗奸𫰛娱娄𫝫妇娅𫝨娲妫㛀媪妈袅妪妩娴娴婳妫媭𫝬娆婵娇嫱嫒𪥰嬷𫝩嫔婴婶𪥿娘𫝮𫝭𪥫㛤娈𡠟孙学𡥧𪧀孪宫采𪧘寝实宁审写宽宠宝将专寻对导尴届尸屃屉屡层屦𪨗属冈峰岘岛峡崃昆岗仑峥岽岚岁𡶴𫶇㟥嵝崭岖𡺃嵚崂𡺄峤峣峄峃崄嵘𫝵岭屿岳𪩎岿峦巅岩𪨷𪩘巯卺帅师帐带帧帏㡎帼帻𪩷帜币𪩸帮帱干几库厕厢厩厦庼荫厨厮𫷷庙厂庑废广𪪞廪庐厅弑吊弪张强𪪼𫸩别弹弥弯录汇彟彦雕彨佛后径从徕复征彻𪫌恒耻悦悮怅闷凄恶恼恽恻爱惬悫怆恺𢙏忾栗态愠惨惭恸惯悫怄怂虑悭庆㥪戚欲忧惫怜凭愦慭惮𢙒愤悯怃宪忆𪫺𢙐𢙓恳应怿懔𢠁蒙怼懑㤽恹惩懒怀悬忏惧慑恋戆戋戗戬战戯戏户抛捝挲挟舍扪挨卷扫抡㧏挜挣𪭵挂采拣扬换挥搄损摇捣揾抢𢫬𪭢掴掼搂挚抠抟折掺捞𪭾挦撑挠㧑挢掸拨𪮖抚扑揿挞挝捡拥掳择击挡㧟担据𪭧挤捣𢬍拟摈拧搁掷扩撷摆擞撸㧰扰摅撵𪮶拢拦撄搀撺携摄攒挛摊搅揽教敚败叙敌数敛毙𢽾敩斓斩断𣃁于旗既升时晋𬀪昼晕晖𬀩旸畅暂晔历昙晓𪰶向暧旷𣆐昽晒书会𦛨胧术东拐栅拐查𣐕杆栀𪱷枧𬂩条枭棁弃棋枨枣栋㭎栈栖梾桠㭏𣒌杨枫桢业极矩干杩荣榅桤构枪杠梿椠椁𣏢椮桨椢椝桩乐枞梁楼标枢𣗊㭤样𣔌榝㭴桪朴树桦椫桡桥机椭横𣓿檩柽档桧槚检樯𣘴梼台槟𪲛柠槛柜𪲎𬃊橹榈栉椟橼栎𪲮橱槠栌枥橥榇蘖栊榉樱栏榉𪳍权𣐤椤𪲔𪴙栾𣗋榄𣚚棂钦叹欧欤欢岁历归殁残殒𣨼殇㱮殚僵殓殡㱩歼杀壳壳毁殴𪵑毵牦毡氇气氢氩𣱝氲泛泛污决没冲况溯泄汹浃𬇙泾涚凉凄泪渌净凌沦渊涞浅涣减沨涡测浑凑𣲗浈涌汤沩准沟𪶄温浉涢湿沧灭涤荥汇沪滞渗卤浒浐滚满渔溇𬇹沤汉涟渍涨溆渐浆颍泼洁𣲘沩㴋潜𫞗润浔溃滗涠涩𣶩浇涝沄涧渑泽滪泶𬇕𫞚浍淀㳠浊浓㳡𣸣湿泞溁蒙浕济涛㳔滥潍滨溅泺滤𪵱澛𣽷滢渎㲿泻沈浏濒泸沥潇潆潴泷濑弥潋澜沣滠𫞝洒𪷽漓滩𣺼灏㳕湾滦滟滟灾为乌烃无𪸩炼炜烟茕焕烦炀㶽𪸕煴𤈶𤇄荧𤆡炝𤇹𤋏𬉼热颎炽𬊤烨灯炖烧𬊈烫焖营灿毁烛烩㶶熏烬焘𫞡𤇃𦶟烁炉𤇭烂𪹳𫞠争为爷尔床墙牍牵荦牦𪺭犊牺状狭狈𪺽狰犹狲犸呆狱狮𪺷奖独𤞃狯猃狝狞㺍获猎犷兽獭献猕猡𤞤𫞥现雕珐珲玮玚琐瑶莹玛玱𪻲𪻐琏𫞩𬍤𬍡𪻺琎玑瑷珰㻅环玙瑸𫞨玺𫞦璇𪻨𬍛琼珑璎𤦀瓒𤩽瓯瓮产产苏宁亩毕画异画当𪽈畴叠痉酸𪽪疴痖疯疡痪瘗疮疟瘆𪽷疭瘘瘘疗痨痫瘅𤶊愈疠瘪痴痒疖症疬癞癣瘿瘾痈瘫癫发皂皑𤾀疱皲皱杯盗盏尽监盘卢𪾔荡𪾣真眦众𪾢困睁睐眍䁖瞒𥆧瞆睑蒙𪾸𪾦眬瞩矫朱硁硖砗砚埼𥐻硕砀砜确码䂵硙砖硵碜碛矶硗䃅硚硷础𬒈𥐟碍矿砺砾矾𪿫砻秘禄祸祯祎祃御禅礼祢祷秃籼税秆䅉棱禀种称谷䅟稣积颖秾穑秽稳获穞窝洼穷窑窎窭窥窜窍窦灶窃𥩟竖𫁟竞笔笋笕䇲个笺筝节范筑箧筼𥬠筿𬕂笃筛筚𥮾箦𫂆篓蓑箪简𫂃篑箫筜签帘篮𥫣𥬞筹䉤箓篯箨籁笼签笾簖篱箩吁粤粽糁粪粮团粝籴粜纟𫄙纠纪纣𬘓约红纡纥纨纫纹纳纽纾纯纰纼纱纮纸级纷纭纴𬘘𫄛纺䌷扎细绂绁绅纻绍绀绋绐绌𫄟终弦组䌹绊𫟃绗结绝𫄠绦绔绞络绚𫄢给𫄡绒𬘡绖统丝绛绝绢𫄨𦈌绑绡𬘫绠𦈋绨绣𫟄绤𬘩绥䌼捆经𫄧综𬘭缍𫄫绿𫟅绸绻𬘯𬘬线绶维绹绾纲网绷缀彩纶绺绮绽绰绫绵绲缁紧绯𦈏绿绪绬绱缃缄缂线缉缎𫟆缔缗缘𫄬缌编缓缅𫄭纬𦈕缑缈练缏𦈉𦈑缇致缊萦缙缢缒𫄰𦈔绉缣缊缞缚缜缟缛县绦缝𦈚缡缩𬙂𫄳纵缧䌸纤缦絷缕𫄲缥𦈐总绩𫄴绷缫缪𫄶𦈝𰬸缯𦈛织缮缭绕𦈎绣缋𫄤绳绘系𫄱茧缰缳缲缴𫄷𫄣䍁绎𦈡继缤缱䍀𫄸𬙊颣缬纩续累缠缨才𬙋纤𫄹缵𫄥缆钵䓨坛罂坛罚骂罢罗罴羁芈群羟羡义𫅗膻习玩翚翘翙耧耢圣闻联聪声耸聩聂职聍𫆏听聋肃胁脉胫唇𣍰修脱胀肾胨脶脑𣍯肿脚肠腽腘肤䏝胶𦝼腻𪱥胆脍脓脸脐膑𣎑腊胪脏脔臜卧临台与兴举旧馆舱𫇛舣舰舻艰艳刍苎兹荆庄茎荚苋𰰨华庵烟苌莱万荝莴叶荭𫈎荮苇药荤𫇭搜莼莳蒀莅𫇴苍荪席盖𦰏莲苁莼荜𬜬卜参蒌蒋葱茑荫𫈟𫇭荨蒇荞荬芸莸荛𫈵蒉荡芜萧𫈉蓣𫇽蕰𫉁荟蓟芗姜蔷荙莶荐萨䓕苧䓓苔荠蓝荩艺药薮䓖蕴苈𫉄蔼蔺萚蕲芦苏蕴苹藓蔹𦻕茏兰蓠萝蔂𬟁处虚虏号亏虬蛱蜕蚬𬟽蚀猬虾虱蜗蛳蚂萤䗖蝼螀𫋇蛰蝈螨𫋌𫊸虮蝉蛲虫𫊻蛏蚁𧏗蚃蝇虿蝎蛴蝾蚝𧏖蜡蛎𫊮蟏蛊蚕蛮𧑏众蔑术同胡卫冲衮袅里补装里制复裈袆裤裢褛亵𫌀裥裥袯𫋹袄𫋷𫋻裣裆褴袜摆衬𧝝袭襕𫌇核见觃规觅视觇𫌪觋觍觎亲觊觏觐觑𫌭觉𫌨览觌观觞觯触讠订讣计讯讧讨𬣙讦𫍙讱训讪讫托记讹𫍛讶𫍚讼䜣诀讷𫟞讻访设许诉诃诊注证𧮪诂诋𫟟讵诈𫍡诒𫍜诏评诐诇诎诅𬣞词咏诩询诣试诗𬣳诧诟诡诠诘话该详诜𫍣诙诖𫍥诔诛诓夸𫍪志认诳诶诞诱诮语诚诫诬误诰诵诲说𫍨说谁课𫍮𫟡谇𫍬诽𫍧谊訚调谄谆谈诿请诤诹诼谅𬣡论谂谀谍谞谝𬤊谥诨𫍩谔𫍳谛谐谏谕咨𫍱𫍰讳𬤇谙𫍯谌讽诸谚谖诺谋谒谓誊诌𫍸𫍷谎谜𫍲谧谑谡谤谦谥讲谢谣谣谟谪谬谫𫍹𫍴讴𫍵谨谩哗𫟠𰶎𫍻证𫍢谲讥𫍤𬤝谮识谯谭谱𫍽噪𫍦谵毁译议谴护诪誉谫读谉变詟䜩雠谗让谰谶赞谠谳岂竖丰艳猪𫎆豮猫𫎌䝙贝贞贠负财贡贫货贩贪贯责贮贳赀贰贵贬买贷贶费贴贻贸贺贲赂赁贿赅资贾贼赈赊宾赇赒赉赐𫎩赏𧹖赔赓贤卖贱赋赕质赍账赌䞐赖赗赚赙购赛赜𧹗贽赘赟赠𫎫赞赝赡赢赆𫎬赃赑赎赝𫎦赣赃赪赶赵趋趱迹践逾踊跄𫏐跸迹跖蹒踪𫏆跷𫏋跶趸踌跻跃䟢踯跞踬蹰𨀁跹𨅬蹑蹿躜躏躯𨉗车轧轨军𫐄轪轩轫𫐅𨐅轭𫐇𬨂软轷𫐉轸𫐊轱𫐈轴轵轺轲轶轼𫐌较𨐈辂辁辀载轾𪨶辄挽辅轻𫐏𫐐辆辎辉辋辍𫐎辊辇𫐑辈轮辌𫐓辑辏𬨎𫐒输辐辒辗舆辒毂辖辕辘𫐖转𫐕辙轿𫐗辚𫐘轰𫐙辔轹𫐆轳办辞辫辩农回迳这连周进游运过达违遥逊递远溯适𫐷迟迁选遗辽迈还迩边逻逦郏邮郓乡邹邬郧𫑘邓𬩽郑邻郸𫑡邺郐邝酂郦腌酝丑酝蒏糖医酱酦𬪩𫑷酿衅酾酽释厘钅钆钇钌钊钉钋𫟲针𫓥钓钐扣钏𫓦钒𫟳𨰿𬬩钗钍钕钎䥺𬬱钯钫钘钭钥𫓪𫓧钚钠𨱂钝钩钤钣钑钞钮𫟴𫟵𫓨钧𨱁钟钙钬钛钪铌𨱄铈𨱃钶铃钴钹铍钰钸铀钿钾𨱅巨钻铊铉𬬿铇铋铂𫓬钷钳铆铅𫟷钺𫓭钵钩𬬸钲𬭁钼钽𬬹锫铏𫟹铰铒铬𫟸𫓴铪银𫓲𫟻铳铜𫓯𫓰铚𫟶铣铨铢铭铫铦衔铑铷铱铟铵铥铕铯铐铞锐𨱇销锈锑锉铝𰾄锒锌钡𨱈铤铗𬭎锋𫓶铻锊锓𫓵铘锄锃锔锇铓铺锐铖锆锂铽锍锯𬬮钢𬬭锞𨱋录锖锫锩铔锥锕锟锤锱铮锛𫓻𫓽𬭚锬锭锜钱𫓹𫓾锦锚锠锡锢错录锰表铼镎𫓸锝锨锪𨱉钫钔锴锳𫔂炼锅镀𫔄锷铡钖锻锽锸锲锘锹𬭤𨱎锾键锶锗针钟镁锿镅𫟿镑镰𫔅𬭩镕锁镉𫔈锤镈𨱏𫔇镃钨蓥镏铠铩锼镐镇镇𨱍镒镋镍镓鿔𨰾镌镎镞𨱌旋链𨱒镆镙𬭬镠镝铿锵𬭭镗镘镛铲镜镖镂𫔊𫓩錾镚铧镤镪䥽𬭸锈𫔌铙𨱑𫔍𫓱铴𫔎𨱓𨱔镣铹镦镡钟镫镢镨䦅锎锏镄𬭼𫓺镌镰䦃镯镭铁镮铎铛𫔁𫟼镱𰾭铸𫠁镬镔鉴鉴镲锧镴铄镳镥𬬻镧钥镵镶𫔔镊镩锣钻銮凿镢镋长门闩闪闫闬闭开闶𨸂闳闰𨸃闲闲间闵𫔯闸𫠂𫔰阂阁合阀闺闽阃阆闾阅阅𫔴阊阉阎阏阍阈阌阒板暗闱𬮱阔阕阑阇阗𫔶阘闿阖阙闯关阚阓阐辟阛闼陉陕升阵阴陈陆阳陧队阶𬮿陨际𬯎随险𬯀陦隐陇隶只隽虽双雏杂鸡离难云电沾霡𫕥雾𪵣霁雳霭叇灵叆靓静靔腼𫖃靥巩绱秋鞒𫖇缰鞑千鞯韦韧韨韩韪𫠅𫖔韬鞲韫𫖒韵响页顶顷项顺顸须顼颂𫠆颀颃预顽颁顿𬱖颇领颌𬱟颉颐颏𫖯头颒颊颋颕𫖳颔颈颓频颓𩓋𩖖𫖶颗题额颚颜颙颛颜𫖮愿颡颠类颟𫖹颢顾颤颥显颦颅颞颧风飐飑飒𩙥台刮飓𩙪飔飏飖飕𩙫飗飘飙飚𫗋飞饣饥饤饦𫗞饨饪饫饬饭飧饮饴𫗢𫗣饲饱饰饳饺饸饼糍饷养饵饹饻饽馁饿𫗦馂饾𫗧余肴馄馃饯馅𫗠𫗪馆𫗬𫗥糊𫗮糇饧喂馉馇𩠌馎饩馏馊馌馍馒馐馑馓馈馔饥饶飨𫗴餍馋𫗵𫗩馕马驭冯𫘛驮驰驯驲𫘜驳𫘝𬳶𫘟𩧨驻驽驹𬳵驵驾骀驸𩧫驶驼𫘞驷骂骈𫘠𩧲𩧴𬳽𫘡骇骃骆𩧺骎𫘣𬳿骏骋骍𫘤𫘧骓𫘥𫘦骔骒骑骐𬴂𩨀骛骗𩨊𫘩𩨃𬴃𩨈𫘨骙䯄𩨄骞骘骝腾𫘬𫘫𫘪驺骚骟𫘭𫠋骡蓦骜骖骠骢驱骅𩧯骕骁𬴊骣𫘯骄验𫘰惊驿骤驴骧骥骦𫘱骊骉肮髅脏体髌髋发松胡𩭹须𫘽鬓斗闹哄阋阄郁鬶魉魇鱼鱽𫚉鱾𩽹𫚌鲀鲁鲂𫚍鱿鲄𫠐𬶍鲅鲆𫚒𫚑𫚖𬶋鲌鲉鲏鲇鲐鲍鲋鲊鲒鲘鲞鲕𩽾𬶏𬶐䲟𫚓鲖鲔鲛鲑鲜𫚗𫚔鲓𫚛鲪𩾃鲝𫚚鲧鲠𩾁𫚙鲩鲤鲨鲬鲻鲯鲭鲞鲷鲴𫚡鲱鲵鲲鲳鲸鲮鲰𫚞鲶𩾇鲺𩽼鳀𬶟鲫𫚣鳊鳈鲗鳂䲠鲽鳇𬶠𫚢䲡鳅鲾鳄𫚊鳆鳃𫚥鳁鳒鳑鳋鲥𫚕鳏𫚤䲢鳎鳐𫚦鳍鳁鲢鳌鳓鳘𬶭鲦鲣鲹鳗鳛𫚧鳔𬶨鳉𫚋鳙𫠒𩾌鳕鳖𫚪鳟鳝鳜鳞鲟𬶮鲼鲎鲙𫚫鳣鳡鳢鲿鲚𫚈鳠𫚭鳄鲈鲡鸟凫鸠凫鸤凤鸣鸢𫛛𪉃𫛚䴓𫛜𫛞𫛝鸩鸨鸦𫛤鸰𫛡鸵𫁡鸳𪉈鸲鸮鸱鸪𫛣鸯鸭𫛦鸸鸹𪉆𫛩鸻䴕鸿𫛪鸽䴔鸺鸼𫛥𬷕鹀鹃鹆鹁𪉍鹈鹅𫛭鹄鹉𫛨𫛳鹌𫛱鹏鹐鹎雕鹊鹓鹍䴖鸫鹑鹒𫛵𫛶鹋鹙𫛸鹕鹗𬸘鹖鹛𫛷鹜䴗鸧𫛯莺𫛫𬸣鹟鹤鹠鹡鹘鹣鹚鹚鹢鹞鸡𫛽䴘鹝𫜀鹧𪉑鹥鸥鸷鹨𬸦𫜃𫛴鸶鹪𪉊𫜁鹔𬸪鹩鹫鹇鹇𫜄鹬鹰鹭鸴𬸯㶉鹯䴙𫛢鹱鹲𬸚鸬𫛟鹴鹦鹳鹂鸾卤咸鹾碱盐丽麦𪎊麸面面𤿲曲𪎉𪎌曲面𫜑么么黄黉点党黪霉黡黩黾鼋鼌鼍冬鼹齐斋赍齑齿龀龁龂𬹼龅龇龃龆龄出龈啮𫜪龊龉𫜭𬺈𫠜𫜬龋𫜮腭龌𬺓𫜰龙厐庞䶮𫜲龚龛龟𩨎𨱆䜤鿒𠀾𠆿𠉗𫝋㓆𠛆𠚳𪠡𪠺𪜎𪢒𪡺𠴛𪢐𠴢𠵸𠲥𪢖𫭼𡋗𪤄𡋀𡍣㛟𫝪㛿㛠𡭜𡭬𡳃𪨩𪨹岁𡸃㟜𪩛𪪴𢙑𪬚𢘝𢘞𪫡𢘙𪬯𪭝𪭯𢫞𢫊𢬦𪮳暅𣈣𫧃㭣𪳗𣘷𣘓𣞎𣑶𣯣𣭤毶𪶮㳢𣶫𣺽𪶒𣷷𤎻𪹀𤊀𪹹𪹠𤎺𤊰𪺣𤙯𫞢𪺪𪺸𤝢𢢐𫞧㻘㻏𪼴𪽝𤳄𪽭𤶧𪽴𥅿𥅘𪿊𥐰𥐯𪿞𪿵𬒗𫀓𫀌𥞦䅪𫞷𫀮𥧂𥩺𫁳𫂖𫁺𥱔𥭉𫁱𥮋𫂿𥹥𥺇𫄝𦈈𫄦𦈒𦈗𫄯𫄪𫄵𫟇𫅥𫅼𡳒𫆝𫞅𫆫𣍨𦟗𫇘䑽𦨩𫇪𦶻𧌥𫊹𧒭𧉐䘞䙊䘛𫌋𧝧𫌫𫌬𫍞𫍟𫍭䜥𫍶𫍺𫍼𫍾𫍐𧳕䞌𧹓䞎𪠀𫎨𪥠𫎸𫏌𨀱𨁴𫏕𧿈𨅫𫏨𫏞𫏑𨂺𨄄䢀䢁𨐆䢂𫐍𫐔𫐋𨐉𨐇𨐊𫟫𫟬𨡙𨡺𨟳𨠨𨤰𨱀𫓫䦀𬭊䦁𫟽𨱊𬭛𫓼𫓿𫟾𫓮𨱐𫔏𬭶𬭳𫔑𫔐𨱕𫔒䥿𫔓𫔉𫓳𫔕𫔃𫔖𨸁𨸀𨸅𫔲𨸆𨸇𨸉𨸊𨸌𨸋𨸎𫔽𨸘𫕚𫕨𫖑𩏾𫖓𫖖𩏽𫃗𫖪𫖭𩖕𫖵𫖷𫖴𫠇𩙦𫗈𫗉𩙩𩙭𩙨𩙬𩙰𩟿𩠀𫗡𩠁𩠂𫗤𫗨𩠃𩠉𩠆𩠊𩠋𫗳𩠎𩠏䭪𩠅𫗚𩠠𩡖𩧦𩧬𩧵𩧳𩧮𩧶䯃𩧸𩧻𩧼𩧩𩨆𩨉𩨅𩨋𩨍𩧱𩨌𫠌𩨐𩬣𫙂𩯒𩬤𩰰𩲒𩴌𫠏𩽺𩽻𫚎䲞𩽿𩽽𩾄𩾅𫚝𫚟𩾆𫚨𫚩𫚘𫚬𩾎𫠖𫛠𪉄𫛧𪉅𪉋𪉉𪉌𪉎𪉐𪉏𫛻𫛹𪉔𪉒𫜂𫛾𪉕𱊜𫜊𫧮𫜓𫜕𫜟𪔭𪚏𪚐𫜯𠛾𣶭𫓷𫜫`;
let T2S = null, T2S_RE = null;
function t2s(s){
  if (!T2S){
    T2S = new Map();
    const t = [...ZH_T], z = [...ZH_S];
    for (let i = 0; i < t.length && i < z.length; i++) if (t[i] !== z[i]) T2S.set(t[i], z[i]);
    T2S_RE = new RegExp('[' + [...T2S.keys()].join('').replace(/[\]\\^-]/g, '\\$&') + ']', 'gu');
  }
  return s.replace(T2S_RE, (c) => T2S.get(c) || c);
}
const LAT_X = { 'ß':'ss', 'æ':'ae', 'œ':'oe', 'ø':'o', 'đ':'d', 'ł':'l', 'þ':'th', 'ð':'d', 'ı':'i' };
const NUM_W = { one:1, two:2, three:3, four:4, five:5, six:6, seven:7, eight:8, nine:9, ten:10 };
/* 单独的 i / v / x 不换：X 战警、V 字仇杀队、I, Robot 里它们是字母不是数字 */
const ROM_N = { ii:2, iii:3, iv:4, vi:6, vii:7, viii:8, ix:9 };
const CN_D = { 一:1, 二:2, 三:3, 四:4, 五:5, 六:6, 七:7, 八:8, 九:9, 十:10, 两:2 };
const CANON_V = 1;                 // 比对规则的版本：进目录缓存键，规则一改旧的判定不会被端上来
function canon(raw){
  let s = raw == null ? '' : String(raw);
  if (!s) return '';
  if (s.length > 200) s = s.slice(0, 200);
  if (/[^\x00-\x7f]/.test(s)){
    s = s.normalize('NFKC');                                  // 全角、兼容字、Ⅱ → II
    s = s.replace(/[À-ɏḀ-ỿ]/g,
      (c) => LAT_X[c.toLowerCase()] || c.normalize('NFD').replace(/[̀-ͯ]/g, ''));
    if (/[㐀-鿿豈-﫿]|[\ud840-\ud87f]/.test(s)) s = t2s(s);
    /* 电影续集的中文写法：第二部 / 第2部 / 第二集 → 2 */
    s = s.replace(/第\s*([一二三四五六七八九十两]|\d{1,2})\s*[部集章]/g, (m, d) => ' ' + (CN_D[d] || d) + ' ');
  }
  s = s.toLowerCase().replace(/&/g, ' and ');
  s = s.replace(/^\s*(?:the|a|an)\s+(?=\S)/, '');
  s = s.replace(/\b(part|chapter|vol|volume|episode)\s*[.:]?\s*(one|two|three|four|five|six|seven|eight|nine|ten)\b/g,
    (m, w, n) => w + ' ' + NUM_W[n]);
  s = s.replace(/\b(?:ii|iii|iv|vi|vii|viii|ix)\b/g, (m) => ROM_N[m]);
  return s.replace(/[^a-z0-9぀-ヿ㐀-鿿가-힯]/g, '');
}
/** 比对键的「分量」：一个汉字 / 假名 / 谚文按 2 算，字母数字按 1 算。
    没有年份时只认分量 ≥ 6 的片名（三个汉字或六个字母）—— 「英雄」「Dune」这种太常见 */
function keyWeight(k){
  let w = 0;
  for (let i = 0; i < k.length; i++) w += k.charCodeAt(i) > 0x2fff ? 2 : 1;
  return w;
}
/** 一组名字 → 去重后的比对键（太短、太泛的扔掉） */
function canonKeys(names){
  const out = [];
  for (const n of names){
    const k = canon(n);
    if (!k || LIB_GENERIC.has(k) || keyWeight(k) < 2) continue;
    if (!out.includes(k)) out.push(k);
  }
  return out;
}
const yearOf = (v) => { const n = parseInt(String(v == null ? '' : v).slice(0, 4), 10); return n >= 1880 && n <= 2100 ? n : 0; };
/* 剧集按"剧"归组：第一季和第二季必须落到同一个 TMDB 条目上，所以键里
   不带年份 —— 版块年份在剧集这边是"这一季播出的年"，不是这部剧的年。 */
const groupKey = (pt) => isTV()
  ? norm(pt.cn) + '|' + norm(pt.latin)
  : norm(pt.cn) + '|' + (norm(pt.latin) || pt.years[0] || '');

const RULES = [
  ['res', /\b(4320p|2160p|1080p|1080i|720p|8K|4K)\b/ig],
  ['src', /\b(REMUX|BluRay|Blu-ray|UHD|WEB-DL|WEBRip|WEB|HDTV|BDRip|DVDRip|HDRip)\b/ig],
  /* \bDV\b 是发布组最常用的杜比视界写法（Dune.2024.2160p.DV.HDR.REMUX）。
     v4 的表里没有它，于是"杜比视界"这一档几乎永远是空的。\b 保证不会
     误吃 DVDRip / DVD。DoVi.P8 / DV.P7 这类后缀也一并认掉。 */
  ['hdr', /(杜比视界|DoVi|Dolby ?Vision|\bDV\b|HDR10\+|HDR10|HDRVivid|HLG|\bHDR\b|\bSDR\b)/ig],
  ['audio', /(Atmos|TrueHD ?\d\.\d|TrueHD|DTS-HD ?MA|DTS-?X|DTS|E-?AC-?3|DDP\d?\.?\d?|DD\+|AC3|FLAC|LPCM|AAC)/ig],
  ['codec', /\b(x265|x264|H\.?265|H\.?264|HEVC|AVC|AV1|VC-1)\b/ig],
  ['lang', /(国英多音轨|国粤英|国粤|国语|粤语|多音轨|双语|特效中文字幕|特效字幕|中文字幕|简英|中英|内封|外挂)/g],
];
function parseRelease(title){
  const tags = [], seen = new Set();
  for (const [kind,re] of RULES){
    re.lastIndex = 0; let m;
    while ((m = re.exec(title))){
      const label = m[1].replace(/\s+/g,''), k = kind+'|'+label.toLowerCase();
      if (seen.has(k)) continue;
      seen.add(k); tags.push({ kind, label });
    }
  }
  if (tags.some(t=>/^HDR10/i.test(t.label)))
    for (let i=tags.length-1;i>=0;i--) if (/^HDR$/i.test(tags[i].label)) tags.splice(i,1);
  const sm = title.match(/(\d+(?:\.\d+)?)\s*(TB|GB|MB)\b/i);
  const gb = sm ? parseFloat(sm[1])*({TB:1024,GB:1,MB:1/1024}[sm[2].toUpperCase()]) : null;
  return {
    tags, size: sm ? sm[1]+' '+sm[2].toUpperCase() : null, gb,
    mb: gb==null ? 0 : Math.round(gb*1024),
    group: title.match(/-([A-Za-z0-9@._]{2,20})(?:\s|$|\s*\d+(?:\.\d+)?\s*(?:TB|GB|MB))/i)?.[1] || null,
  };
}
/** 一条帖 → 索引行（规格与分数在建索引时算实，运行时不再解析） */
function toRow(tid, title){
  const pr = parseRelease(title);
  const spec = packSpec(pr);
  return { tid: Number(tid), title, spec, mb: pr.mb, score: specScore(spec, pr.mb) };
}
/** [修复 4] 最好的片源：分数优先，同分按体积大的优先 */
const betterRow = (a,b) => (b.score - a.score) || ((b.mb||0) - (a.mb||0)) || (b.tid - a.tid);
const pickBest = (rows) => rows && rows.length ? rows.slice().sort(betterRow)[0] : null;

const WR_MIN = 200, WR_MEAN = 6.4;
function weighted(m){
  const v = m[F.C]||0, R = m[F.T]||0;
  if (!v) return 0;
  return (v/(v+WR_MIN))*R + (WR_MIN/(v+WR_MIN))*WR_MEAN;
}

/* ══════════ TMDB ══════════ */
async function tmdb(env, path, params = {}){
  if (!env.TMDB_KEY) throw new Error('缺少 TMDB_KEY');
  /* TMDB_BASE：可选，走自己的反代时用（默认官方地址） */
  const u = new URL(String(env.TMDB_BASE || 'https://api.themoviedb.org/3').replace(/\/+$/, '') + path);
  u.searchParams.set('api_key', env.TMDB_KEY);
  u.searchParams.set('language','zh-CN');
  for (const [k,v] of Object.entries(params)) u.searchParams.set(k,v);
  /* [v6.2] 认定工的调用自带配额（env.__sub）：重试也从这份里扣，429 记个数交给浏览器做退避 */
  const lb = env.__sub || null;
  const r = await autoRetry('tmdb '+path, async () => {
    const x = await sfetch(u.toString(), { headers:{Accept:'application/json'}, cf:{ cacheEverything:true, cacheTtl:21600 }, timeoutMs: 12000, sub: lb });
    if (x.status === 429){ if (lb) env.__r429 = (env.__r429 || 0) + 1; const e=new Error('HTTP 429'); e.retryAfter=Number(x.headers.get('retry-after'))||3; throw e; }
    if (x.status >= 500) throw new Error('HTTP '+x.status);
    if (!x.ok) throw new Error('HTTP '+x.status+'（检查 TMDB_KEY）');
    return x;
  }, { tries: 3, gap: 500, left: lb ? () => lb.max - lb.n : null });
  return r.json();
}
/* ══════════════════════════════════════════════════════════════════
   TMDB 认定
   ──────────────────────────────────────────────────────────────────
   v4 的做法是：拿中文名搜一次，搜不到就记进 movies.u 永久跳过，
   顺手把这一组的帖子行直接扔掉。于是「868 个片名匹配不上」有三重问题：
     ① 只用中文名搜，不带年份，也从不试原名 —— TMDB 的中文索引本来就
        比原名弱得多，一次搜不中的概率很高；
     ② 版本后缀（加长版 / 4K修复 / 剧场版）原样进搜索串，必然搜不中；
     ③ 认不出来 = 数据丢失。重试只是清掉标记，行早就没了，
        非得把列表页重爬一遍不可。
   v5 分三件事收口：认定改成多策略、非电影内容先认出来别浪费请求、
   认不出的连同帖子行一起留底（见 PEND），重试时不用重爬。
   ══════════════════════════════════════════════════════════════════ */

/* 版本 / 发行后缀：留在搜索串里就是噪声 */
const CN_NOISE = /(加长版|导演剪辑版?|导演版|未删减版?|完整版|重制版|重製版|修复版|修復版|重映版|纪念版|终极版|特别版|国际版|数字修复|4K修复|蓝光原盘|收藏版|典藏版|双语|国语|粤语|中字|高清|超清|杜比视界|双碟|三碟)/g;
/* 一帖多片：TMDB 没有对应条目，认不出来是正常的 */
const PACK_RE = /(合集|全集|系列|三部曲|四部曲|五部曲|套装|合辑|\d\s*[-–~]\s*\d\s*部)/;
/* 根本不是电影：剧集 / 综艺 / 演唱会 / 纪录短片，别浪费子请求去搜 */
const TV_RE = /(第[一二三四五六七八九十百\d]+季|\bS\d{1,2}(?:E\d{1,3})?\b|全\d+集|连续剧|電視劇|电视剧|剧集|劇集|综艺|綜藝|真人秀|演唱会|演唱會|\bMV\b|\bLive\b|纪录片|紀錄片|访谈|訪談)/i;

const cleanCN = (cn) => String(cn||'')
  .replace(/[（(][^)）]{0,20}[)）]/g, ' ')
  .replace(CN_NOISE, ' ')
  .replace(/\s+/g, ' ').trim();

/**
 * 从标题里挑出真正的发行年份。
 * 「银翼杀手2049」「流浪地球2」这类片名自带数字，parseTitle 会把 2049
 * 也当成年份 —— 拿它去锁 primary_release_year 就是白花一个子请求。
 * 版块本身是按年份筛的，所以 hint（当前在建的年份）是很强的先验：
 * 取候选里离 hint 最近、且落在合理区间内的那个；都不合理就直接用 hint。
 */
function pickYear(years, hint){
  const now = new Date().getFullYear() + 1;
  const ok = (years||[]).map(Number).filter(y => y >= 1900 && y <= now);
  /* 标题里的年份最可信；hint 只用来在多个候选之间挑一个，
     以及在标题压根没写年份时兜底。反过来让 hint 压过标题会更糟：
     版块年份筛的是"收录年份"，重映 / 补档的片子对不上。 */
  if (!ok.length) return hint ? String(hint) : '';
  if (ok.length === 1 || !hint) return String(ok[0]);
  ok.sort((a, b) => Math.abs(a - hint) - Math.abs(b - hint));
  return String(ok[0]);
}

/* 剧集源里 TMDB 没有条目的：演唱会 / 写真 / 片花这一类 */
const NOT_TV_RE = /(演唱会|演唱會|写真|寫真|片花|预告片|預告|花絮|直播回放|MV合集)/i;
/** 这一组值不值得送去认。返回 null = 送，否则给出跳过的原因。
    注意剧集源里"全 36 集""第二季"正是常态，那套排除法在这边整个关掉，
    否则一条都留不下来。 */
function notMovie(title){
  const t = String(title || '');
  if (isTV()) return NOT_TV_RE.test(t) ? 'other' : null;
  if (TV_RE.test(t)) return 'tv';
  if (PACK_RE.test(t)) return 'pack';
  return null;
}

/**
 * 候选评分。
 * 关键约束：片名毫无重叠的候选一律不要 —— 这是把门槛放低之后仍然不会
 * 乱认的根据。yearLocked 表示这次搜索已经用年份锁过，TMDB 那边先筛了
 * 一道，所以片名只要沾边就足够可信，门槛可以降下来。
 */
/* TMDB 的 tv 条目用 name / original_name / first_air_date，movie 用
   title / original_title / release_date。在这里统一成一种形状，后面建
   索引、抄片库、写详情就都不必再关心手上这条是哪一种。 */
const asItem = (r) => (!r || r.title != null || r.release_date != null) ? r
  : { ...r, title: r.name || '', original_title: r.original_name || '',
      release_date: r.first_air_date || '' };

/* [v5.2 修复 2] 词集重合度。
   剧集的译名常常差一两个虚词：「Ace of the Diamond act」对
   「Ace of Diamond Act II」，includes 判不出来（0 分），词集重合度
   判得出来（1.0）。剧集没有年份可加分，全靠片名扛，所以这一档必须有。 */
const tokSet = (s) => new Set(String(s||'').toLowerCase().match(/[a-z0-9\u4e00-\u9fa5]+/g) || []);
function simTok(a, b){
  const A = tokSet(a), B = tokSet(b);
  if (!A.size || !B.size) return 0;
  let n = 0; for (const x of A) if (B.has(x)) n++;
  return n / Math.min(A.size, B.size);
}

function pickTMDB(results, cn, latin, years, opt = {}){
  let best = null, top = 0;
  const tv = !!opt.tv;
  const ccn = cleanCN(cn);
  /* [v6] 比对用 canon：繁体 / 全角 / 重音 / 罗马数字 / 冠词都折到同一个键上。
     「互相包含」要求短的那个至少两个字符 —— 一个字的片名包含在任何片名里都不算数 */
  const nc = canon(cn), nl = canon(latin), nc2 = canon(ccn);
  const hit = (a, b) => (!a || !b) ? 0 : (a === b ? 5
    : (Math.min(a.length, b.length) >= 2 && (a.includes(b) || b.includes(a))) ? 2 : 0);
  for (const raw of (results||[]).slice(0, 10)){
    const r = asItem(raw);
    if (!r || r.adult) continue;
    const ry = (r.release_date||'').slice(0,4);
    const nt = canon(r.title), no = canon(r.original_title);
    const ts = Math.max(hit(nt,nc), hit(no,nc), hit(nt,nc2), hit(no,nc2))
             + Math.max(hit(no,nl), hit(nt,nl));
    const ss = Math.max(simTok(r.title, latin), simTok(r.original_title, latin),
                        simTok(r.title, ccn), simTok(r.original_title, ccn));
    if (!ts && ss < 0.7) continue;                      // 片名对不上就不是它
    let s = ts + (ss >= 0.95 ? 2.5 : ss >= 0.7 ? 1.5 : 0);
    if (ry && years.includes(ry)) s += tv ? 3 : 4;
    /* 引进版和原产地常差一年，差一年给一半的分 */
    else if (ry && years.length && years.some(y => Math.abs(+y - +ry) === 1)) s += 2;
    /* 剧集：版块年份是"这一季播出的年"，TMDB 记的是首播年 —— 第二季对不上
       首播年是常态，所以只要这部剧开播不晚于这一季，就给一点分 */
    else if (tv && ry && years.length && years.every(y => +y >= +ry)) s += 1.5;
    if (r.poster_path) s += 1;
    s += Math.min(1.5, (r.popularity||0)/60);
    if (s > top){ top = s; best = r; }
  }
  /* 剧集这边年份帮不上忙，门槛靠片名扛，所以定在"片名沾边 + 一点旁证" */
  return top >= (tv ? 5 : (opt.yearLocked ? 4.5 : 6)) ? best : null;
}

/* [v6.4] 一个标题里的别名：「没人知道我在这/歌手的秘密」拆开；「主标题：副标题」只留主标题 */
const mainTitle = (s) => String(s || '').split(/\s*(?:[:：]|\s[-–—]\s|——)\s*/)[0].trim();
function altNames(cn){
  const raw = String(cn || '').trim();
  if (!raw) return [];
  const out = [];
  const push = (x) => { x = cleanCN(String(x || '').trim()); if (x && x.length >= 2 && x !== raw && !out.includes(x)) out.push(x); };
  for (const part of raw.split(/\s*(?:[\/／|｜]|又名)\s*/)) push(part);
  push(mainTitle(raw));
  return out;
}

/**
 * [v6.4] 一批片名一起认：最多五轮，每轮只给还没认下来的那几组再搜一次（并发），
 * 候选按语言分池累积，每轮连同之前的候选再评一次：
 *   ① 洗过的中文名 + 年份（剧集不锁年份：版块年份是这一季的，TMDB 记的是首播年）
 *   ② 换说法：原名 / 洗之前的中文名 / 去掉年份
 *   ③ 英文：原名 + 年份，language=en-US —— 外语片在 TMDB 上常常没有中文译名，中文结果里只剩
 *      意大利语 / 西班牙语原名，论坛给的英文名一个都对不上；英文结果里才有英文片名
 *   ④ 别名：「A/B」两个译名拆开、「主标题：副标题」只留主标题，各搜一次
 *   ⑤ 英文名去掉副标题（「Alex Fernandez: The Best Comedian in the World」→「Alex Fernandez」）
 * ③–⑤ 认出来的要求年份对得上（差一年以内）：这几轮的说法更宽，不能拿同名的另一部顶上。
 * 后几轮按剩余配额开：配额不够、或者有一轮是网络失败的，不下「认不出」的结论（按没下结论交回，下次再认）。
 * 返回 Map：{hit, via} 认下来了 / {miss, why} 认不出 / null 这次没下结论。
 */
async function matchBatch(env, groups, opt = {}){
  const out = new Map(), rest = [];
  for (const g of groups){
    const nm = notMovie(g.title || g.cn);
    if (nm){ out.set(g.key, { miss:1, why:nm }); continue; }   // 一个子请求都不花
    rest.push(g);
  }
  if (!rest.length) return out;
  const tv = isTV();
  const left = () => env.__sub ? env.__sub.max - env.__sub.n : subLeft();

  const ask = (g, P) => {
    const p = { query: P.q, include_adult:'false' };
    if (P.y) p[SRC.yparam] = P.y;
    if (P.lang) p.language = P.lang;
    return tmdb(env, '/search/' + SRC.kind, p)
      .then(j => ({ g, P, j }))
      .catch(e => {
        /* soft（认定工）：配额用完的那几组按「没下结论」交回去，已经认下的照样带回，不整批作废 */
        if (e.budget && !opt.soft) throw e;
        if (!e.budget)
          /* [v5.2 修复 5] 出网失败和「认不出」在界面上长得一模一样 —— 原样记进「匹配」频道，带上查询串 */
          trace('tmdb', 'TMDB 搜索失败（' + SRC.kind + '「' + String(P.q).slice(0, 24) + '」）：' +
            (e.message || e), { lvl: 'err', ch: 'match' });
        return { g, P, j: null };
      });
  };

  /* 第一轮就用洗过的中文名：版本后缀留在搜索串里几乎必然搜不中。评分仍然拿原始片名去比 */
  const q1 = (g) => { const c = cleanCN(g.cn); return (c && c.length >= 2) ? c : g.cn; };
  const plansOf = (g) => {
    const y = tv ? '' : pickYear(g.years, g.hint);
    const P = [], seen = new Set();
    const add = (q, yy, lang, via, wide, alt) => {
      q = String(q || '').trim();
      if (q.length < 2) return;
      const k = q.toLowerCase() + '|' + yy + '|' + lang;
      if (seen.has(k)) return;
      seen.add(k); P.push({ q, y: yy, lang, via, wide: !!wide, alt: alt || '' });
    };
    add(q1(g), y, '', y ? '中文名+年份' : '中文名');
    if (g.latin && norm(g.latin) !== norm(g.cn)) add(g.latin, '', '', '原名');
    else if (norm(q1(g)) !== norm(g.cn)) add(g.cn, '', '', '中文名原样');
    else if ((g.years || []).length) add(g.cn, '', '', '不锁年份');
    const lat = g.latin && !/[㐀-鿿]/.test(g.latin) ? g.latin : '';
    if (lat) add(lat, y, 'en-US', '英文名', 1);
    for (const a of altNames(g.cn).slice(0, 2)) add(a, y, '', '别名「' + a.slice(0, 12) + '」', 1, a);
    if (lat){ const m = mainTitle(lat); if (m && m.length >= 4 && m !== lat) add(m, y, 'en-US', '英文主标题', 1); }
    return P;
  };

  const S = new Map();                      // key → { g, plans, pz（中文候选）, pe（英文候选）, alts, failed }
  for (const g of rest) S.set(g.key, { g, plans: plansOf(g), pz: [], pe: [], alts: [], failed: false });
  const yearOk = (g, h) => {
    if (tv || !(g.years || []).length) return true;
    const hy = Number(String(h.release_date || '').slice(0, 4));
    return !hy || g.years.some(y => Math.abs(Number(y) - hy) <= 1);
  };
  let open = rest.slice();
  for (let r = 0; r < 5 && open.length; r++){
    const todo = open.filter(g => S.get(g.key).plans[r]);
    if (!todo.length) break;
    /* 第一轮之后按剩余配额开：不够这一轮的，留着下次认（不下结论） */
    if (r > 0 && left() < todo.length + 3) break;
    const res = await Promise.all(todo.map(g => ask(g, S.get(g.key).plans[r])));
    for (const { g, P, j } of res){
      const s = S.get(g.key);
      s.next = r + 1;                         // 第 r 条计划问过了
      if (!j){
        s.failed = true;
        if (r === 0){ out.set(g.key, null); open = open.filter(x => x.key !== g.key); }   // 第一轮就断网：这一组先不认了
        continue;
      }
      const list = (j.results || []).slice(0, 8);
      if (P.lang) s.pe = s.pe.concat(list); else s.pz = s.pz.concat(list);
      if (P.alt) s.alts.push(P.alt);
      /* 这一轮自己的候选（锁了年份时门槛放低），再看合起来的候选 */
      let h = pickTMDB(list, P.alt || g.cn, g.latin, g.years || [], { yearLocked: !!P.y, tv });
      if (!h && r > 0) h = pickTMDB(P.lang ? s.pe : s.pz, g.cn, g.latin, g.years || [], { tv });
      if (!h && r > 0 && !P.lang) for (const a of s.alts){ h = pickTMDB(s.pz, a, g.latin, g.years || [], { tv }); if (h) break; }
      if (h && P.wide && !yearOk(g, h)) h = null;
      /* 英文那几轮认下来的：TMDB 上多半没有中文译名（中文结果里的标题是原名）—— 片名用论坛给的中文名 */
      if (h && P.lang && /[\u3400-\u9fff]/.test(g.cn || '') && !/[\u3400-\u9fff]/.test(h.title || '')){
        const zh = cleanCN(g.cn.split(/\s*[\/／|｜]\s*/)[0]) || g.cn;
        h = { ...h, title: zh };
      }
      if (h){ out.set(g.key, { hit: h, via: P.via }); open = open.filter(x => x.key !== g.key); }
    }
  }
  for (const g of open){
    if (out.has(g.key)) continue;
    const s = S.get(g.key);
    /* 最后用中文候选宽松评一次（同 v5：只搜过一轮的，第一轮的候选可能就够） */
    let h = pickTMDB(s.pz, g.cn, g.latin, g.years || [], { tv });
    if (h && (s.next || 0) > 2 && !yearOk(g, h)) h = null;     // 候选里混着别名那几轮的结果：同样要求年份对得上
    if (h){ out.set(g.key, { hit: h, via: '候选复评' }); continue; }
    /* 计划没走完（配额不够）或者中途断过网：不下「认不出」的结论，下次再认 */
    const exhausted = (s.next || 0) >= s.plans.length;
    out.set(g.key, (s.failed || !exhausted) ? null : { miss: 1, why: 'nohit' });
  }
  return out;
}
async function tmdbMeta(env, id, ctx){
  /* 电影和剧集是两套 id，缓存键必须分开，否则 tv/1399 会读到 movie/1399 */
  const k = SRC.metaPre + id;
  const hit = await jget(env, k);
  if (hit) return hit;
  const d = await tmdb(env,'/'+SRC.kind+'/'+id,{append_to_response:'external_ids'}).catch(()=>null);
  if (!d) return null;
  const out = { overview: d.overview||'',
    runtime: d.runtime || (Array.isArray(d.episode_run_time) ? d.episode_run_time[0] : 0) || null,
    seasons: d.number_of_seasons || 0, eps: d.number_of_episodes || 0,
    genres: (d.genres||[]).map(g=>g.name), imdb: d.imdb_id||d.external_ids?.imdb_id||null };
  const w = jput(env, k, out, TTL.tmdbMeta).catch(()=>{});
  ctx ? ctx.waitUntil(w) : await w;
  return out;
}

/* ══════════ R2 ══════════ */
/* [v6] 读：「对象不存在」和「读失败」必须分开。
   v5 的 r2get 把两者都当成「不存在」—— R2 偶发的读中断（body 读到一半断了、JSON 解析失败）
   会让 movies.json 被当成空表读进来，这一轮跑完再写回去，整个索引就只剩这一轮新认的几部。
   现在：不存在 → 返回默认值；读失败 → 重试两次后抛错（这一轮不写任何东西）；
   内容不是合法 JSON → 抛 corrupt 错（不会拿空表覆盖它，体检里给「从备份恢复」）。 */
async function r2getE(env, key){
  if (!env.R2) throw new Error('未绑定 R2，无法读写索引');
  let last;
  for (let i = 0; i < 3; i++){
    let o, txt;
    try { o = await env.R2.get(key); }
    catch (e){ last = e; await sleep(120 * (i + 1) * (i + 1)); continue; }
    if (!o) return { val: undefined, etag: null };
    try { txt = await o.text(); }
    catch (e){ last = e; await sleep(120 * (i + 1) * (i + 1)); continue; }
    try { return { val: JSON.parse(txt), etag: o.etag || o.httpEtag || null }; }
    catch {
      const err = new Error('R2 对象 ' + key + ' 不是合法的 JSON（' + txt.length + ' 字节）—— 不会拿空数据覆盖它，去体检里「从备份恢复」');
      err.corrupt = 1; err.key = key;
      throw err;
    }
  }
  const err = new Error('读取 R2 ' + key + ' 失败（重试 3 次）：' + (last && last.message || last) + ' —— 本轮不写任何东西');
  err.r2read = 1; err.key = key;
  throw err;
}
async function r2get(env, key, dflt){
  const r = await r2getE(env, key);
  return r.val === undefined ? dflt : r.val;
}
/** 带前提的写：etag 对得上才写（null = 对象此刻必须不存在才写）。返回 false = 有人抢先写过了 */
async function r2putIf(env, key, val, etag){
  const body = JSON.stringify(val);
  for (let i = 0; i < 5; i++){
    try {
      const r = await env.R2.put(key, body, { httpMetadata:{ contentType:'application/json' },
        ...(etag ? { onlyIf: { etagMatches: etag } } : {}) });
      return r !== null;
    } catch (e){
      if (!isRate10058(e) || i === 4) throw e;
      await sleep([250, 600, 1200, 2200][i] * (0.7 + Math.random() * 0.6));
    }
  }
  return false;
}
/* ══════════════════════════════════════════════════════════════════
   R2 写入
   ──────────────────────────────────────────────────────────────────
   R2 对「同一个对象」的写入频率有硬限制，太密会回
   "Reduce your concurrent request rate for the same object. (10058)"。
   索引这类工作天然是一轮一写、轮次又挨得很近，撞上是迟早的事。
   这里做两件事：
     · 同一个 isolate 内按 key 串行化，自己不跟自己抢；
     · 撞上限流就退避重试 —— 它是暂时的，不该让整轮任务失败。
   ══════════════════════════════════════════════════════════════════ */
const R2LOCK = new Map();
const isRate10058 = (e) => /10058|concurrent request rate|reduce your|too many requests|429/i
  .test(String(e && e.message || e));
async function r2put(env, key, val, opt){
  const body = JSON.stringify(val);
  const run = async () => {
    let last;
    for (let i = 0; i < 5; i++){
      try {
        return await env.R2.put(key, body, { httpMetadata:{ contentType:'application/json' } });
      } catch (e){
        last = e;
        if (!isRate10058(e)) throw e;
        if (i === 4) break;
        /* 300 / 700 / 1500 / 3000 ms，带抖动，避开多个 isolate 同步重试 */
        const wait = [250, 600, 1200, 2200][i] * (0.7 + Math.random() * 0.6);
        trace('sys', 'R2 同对象写入限流，' + Math.round(wait) + 'ms 后重试 ' + key,
          { lvl:'warn', ch:'sys' });
        await sleep(wait);
      }
    }
    throw new Error('写入 ' + key + ' 反复被 R2 限流（同一对象写得太密）：' +
      (last && last.message || last));
  };
  /* 按 key 排队：同一次调用里两处同时写同一个对象也不会互相踩。
     前一个是成是败都不影响后一个，所以两个分支都接 run。 */
  const prev = R2LOCK.get(key) || Promise.resolve();
  const job = prev.then(run, run);
  const tail = job.catch(() => {});
  R2LOCK.set(key, tail);
  tail.then(() => { if (R2LOCK.get(key) === tail) R2LOCK.delete(key); });
  return job;
}
const blankState = () => ({ v:4, years:{}, at:0, ver:0, deaths:0 });
const blankMovies = () => ({ v:4, m:{}, k:{}, u:{}, pv:0 });

/* ══════════════════════════════════════════════════════════════════
   [v5.2 修复 3] 解析器版本戳
   ──────────────────────────────────────────────────────────────────
   movies.u 是「认不出，永久跳过」表。解析器一改，那张表里的每一条结论
   都作废了 —— 可它不会自己失效，于是新解析器一辈子也碰不到那些帖子：
   界面上永远是「新帖 150 · 入库 0」，点多少次「继续建立索引」都一样。
   所以给索引盖一个解析器版本戳：对不上就清跳过表、把留底队列的重试
   次数归零，下一轮自动重认一遍，不用人工去点「重扫未匹配」。
   另外给跳过标记加了保质期：七天之后自然再试一次，认不出的片子等
   TMDB 补了条目就能自己捡回来。
   ══════════════════════════════════════════════════════════════════ */
/* v3（v6.4）：认定加了英文、别名、英文主标题三轮 —— 以前「认不出」的结论全部作废、重新排队可重试
   v4（v6.5）：中文名以字母开头的（F1：狂飙飞车 / X战警）不再切成空的 */
const PARSER_V = 4;
const U_TTL = 7 * 86400_000;

function parserMigrate(movies, pend){
  if ((movies.pv|0) === PARSER_V) return 0;
  const n = Object.keys(movies.u || {}).length;
  movies.u = {}; movies.pv = PARSER_V;
  const q = (pend && pend.q) || {};
  for (const k of Object.keys(q)) q[k].n = 0;
  trace('match', '解析器升级到 v' + PARSER_V + '：清掉 ' + n + ' 条跳过标记，'
    + '留底队列 ' + Object.keys(q).length + ' 条全部恢复可重试', { lvl:'info' });
  return 1;
}
/** 跳过标记还作数吗 —— 过了保质期就再给一次机会 */
function uSkip(movies, key){
  const at = movies.u[key];
  if (!at) return false;
  if (Date.now() - at < U_TTL) return true;
  delete movies.u[key];
  return false;
}

/* ══════════════════════════════════════════════════════════════════
   [v6] 存储：原子提交（copy-on-write）
   ──────────────────────────────────────────────────────────────────
   v5 一轮的写盘顺序是：分片（原地覆盖）→ tid 表（原地覆盖）→ movies.json → state.json。
   平台随时可能掐掉进程（1102），掐在中间就留下互相对不上的几份：
     · 分片写了、state 没写：分片里多出这一轮的行，tid 表也记了，可影片表没有这些片 ——
       这些帖子从此被 tid 表挡在门外，永远进不了索引；
     · 两个任务重叠（锁过期被接管、原任务其实还在跑）：同一片被两边各写一遍，后写的盖掉先写的。
   v6 的做法是数据库里最老的那一招：
     · 分片和 tid 表每次都写成「新名字」（键里带一段代号 g），从不覆盖已提交的那份；
     · state.json 里记着每一片、每张 tid 表当前用的是哪个代号 —— 写 state 就是提交，
       在它之前掐掉，一切照旧（多出来的新对象没人引用，日后清掉）；
     · 被替换下来的旧对象记进 state.grave，十分钟以后才删（别的 isolate 手里那份 45 秒内的
       state 可能还指着它）；删之前再核对一遍现在的 state 没有引用它；
     · movies.json 与 state.json 带同一个提交号 cid：两者对不上 = 掐在两次写之间，
       影片表比 state 新 —— 记 heal，体检和定时任务会跑一遍「重算汇总」把计数对齐；
     · 锁带身份（id），抢锁用 R2 的条件写（etag），提交前再核对一遍锁还是自己的并续期：
       锁被别人接管了就放弃这一轮，绝不两边同时提交。
   ══════════════════════════════════════════════════════════════════ */
const GRAVE_MS = 10 * 60_000;
const newGen = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
const ystOf = (state, y) => state.years[y] || (state.years[y] = newYear());
const pgOf = (state, y, i) => { const a = state && state.years && state.years[y] && state.years[y].pg; return (Array.isArray(a) && a[i]) || ''; };
const partKey = (state, y, i) => IDX.part(y, i, pgOf(state, y, i));
const tidsKey = (state, y) => IDX.tids(y, (state && state.years && state.years[y] && state.years[y].tg) || '');
function graveAdd(state, key){ if (key) (state.grave = state.grave || []).push([key, Date.now()]); }
/** state 现在引用着的全部对象键（分片 + tid 表） */
function liveKeys(state){
  const out = new Set();
  for (const y of Object.keys((state && state.years) || {})){
    const n = partCount(state, y);
    for (let i = 0; i < n; i++) out.add(partKey(state, y, i));
    out.add(tidsKey(state, y));
  }
  return out;
}
/** 删掉十分钟前就被替换下来、而且现在的 state 确实不再引用的旧对象 */
async function graveSweep(env, state){
  const g = state.grave || [];
  if (!g.length) return 0;
  const live = liveKeys(state), now = Date.now(), keep = [], del = [];
  for (const e of g){
    if (!Array.isArray(e) || !e[0]) continue;
    if (live.has(e[0])) continue;                           // 被回滚的 state 又引用了它：不删，也不再记
    (now - (e[1] || 0) > GRAVE_MS ? del : keep).push(e);
  }
  if (del.length){
    try { await env.R2.delete(del.map(e => e[0])); }
    catch (e){ trace('sys', '清理旧分片失败（下次再清）：' + (e.message || e), { lvl:'warn' }); return 0; }
  }
  state.grave = keep.slice(-400);
  return del.length;
}

let idxCache = null;
async function loadIndex(env, force){
  if (!force && idxCache && idxCache.exp > Date.now()) return idxCache.v;
  const [movies, state] = await Promise.all([
    r2get(env, IDX.movies, blankMovies()),
    r2get(env, IDX.state, blankState()),
  ]);
  movies.m = movies.m||{}; movies.k = movies.k||{}; movies.u = movies.u||{};
  const v = { movies, state };
  idxCache = { v, exp: Date.now()+45000 };
  return v;
}
/**
 * 重活读索引：不存在才给空表。另外两种「空」都不对劲，直接拒绝往下跑：
 *   · state 记着有片、movies.json 却不见了；
 *   · movies.json 里有片、state.json 却不见了（片表指针全丢，接着跑会从头写分片）。
 * 返回时附带 m0（读进来时的影片数）—— 提交时拿它做「只增不减」的检查。
 */
async function loadForWrite(env){
  const [mr, sr] = await Promise.all([ r2getE(env, IDX.movies), r2getE(env, IDX.state) ]);
  const movies = mr.val === undefined ? blankMovies() : mr.val;
  const state = sr.val === undefined ? blankState() : sr.val;
  if (!movies || typeof movies !== 'object' || !state || typeof state !== 'object' || !state.years)
    throw Object.assign(new Error('索引文件形状不对（movies / state）—— 不敢接着写，去体检里「从备份恢复」'), { corrupt: 1 });
  movies.m = movies.m||{}; movies.k = movies.k||{}; movies.u = movies.u||{};
  const m0 = Object.keys(movies.m).length;
  if (mr.val === undefined && (state.movies || 0) > 0)
    throw Object.assign(new Error('movies.json 不见了（state 记着 ' + state.movies + ' 部）—— 不会用空表覆盖，去体检里「从备份恢复」'), { corrupt: 1 });
  if (sr.val === undefined && m0 > 0)
    throw Object.assign(new Error('state.json 不见了（movies.json 里有 ' + m0 + ' 部）—— 不会从头重写分片，去体检里「从备份恢复」'), { corrupt: 1 });
  /* 提交号对不上：上一轮掐在 movies.json 与 state.json 两次写之间 —— 影片表的计数比分片多算了一截 */
  if (movies.cid && state.cid && movies.cid !== state.cid && !state.heal){
    state.heal = Date.now();
    trace('sys', '上一轮掐在两次提交之间：影片表与片表对不上，稍后自动「重算汇总」对齐计数', { lvl:'warn' });
  }
  return { movies, state, m0 };
}
/**
 * 提交：先核对锁还是自己的（并续期），再写 movies.json，最后写 state.json —— 写 state 才算数。
 * shrink：允许影片变少（只有重置年份 / 清理孤儿这两种显式操作）。其余操作里影片表只增不减，
 * 少了就是哪里出了错，宁可这一轮作废也不写回去。
 */
async function commitIndex(env, lk, movies, state, opt = {}){
  if (movies){
    const n = Object.keys(movies.m || {}).length;
    if (!opt.shrink && opt.m0 != null && n < opt.m0)
      throw Object.assign(new Error('影片表要从 ' + opt.m0 + ' 部变成 ' + n + ' 部 —— 这一轮不该删片，已放弃提交'), { corrupt: 1 });
    if (opt.shrink && opt.m0 >= 50 && n < opt.m0 * 0.5 && !opt.force)
      throw Object.assign(new Error('影片表要从 ' + opt.m0 + ' 部骤减到 ' + n + ' 部 —— 太反常，已放弃提交'), { corrupt: 1 });
  }
  if (lk) await lk.check();
  const cid = newGen();
  state.cid = cid;
  delete state.lock;
  state.at = Date.now();
  state.ver = (state.ver || 0) + 1;
  if (movies){ movies.cid = cid; await r2put(env, IDX.movies, movies); }
  await r2put(env, IDX.state, state);
  dropCaches();
  return cid;
}

const lockAt = (l) => !l ? 0 : (typeof l === 'number' ? l : (l.at||0));
const lockErr = (msg) => Object.assign(new Error(msg), { busy: 1, wait: 5, stale: false });

/**
 * 带"死亡计数"的锁。
 * 任务被平台掐掉时 finally 不会执行，锁就留在 R2 里。接管一个残留锁时 deaths 自增，
 * 任务按 deaths 把批量、时间预算、分片大小逐级减半，跑完一整轮就清零。
 * [v6] 锁带 id，抢锁用条件写（两个 isolate 同时抢只有一个写得进去）；fn 拿到一个 lk：
 * lk.check() 核对锁还是自己的并续期 —— 提交前必调（commitIndex 会调）。
 */
async function withIndexLock(env, fn){
  const got = await r2getE(env, IDX.state);
  const st = got.val === undefined ? blankState() : got.val;
  govLoad(st);
  const now = Date.now();
  const at = lockAt(st.lock);
  if (at && now - at < LOCK_MS){
    const wait = Math.ceil((LOCK_MS - (now - at))/1000);
    throw lockErr('另一个索引任务正在运行，约 '+wait+' 秒后释放');
  }
  let deaths = st.deaths || 0;
  if (at){                                  // 接管残留锁 = 上一轮没善终
    deaths = Math.min(6, deaths + 1);
    st.deaths = deaths;
    trace('kill', '接管残留锁（'+Math.round((now-at)/1000)+'s 前留下），降级等级 '+deaths);
  }
  const id = newGen();
  st.lock = { at: now, deaths, id };
  if (!await r2putIf(env, IDX.state, st, got.etag)) throw lockErr('另一个索引任务刚刚抢到了锁，稍后再试');
  const lk = {
    id,
    /** 锁还是自己的吗？是就续期（把 at 推到现在），不是就抛 busy —— 这一轮作废，不提交 */
    async check(){
      const cur = await r2getE(env, IDX.state);
      const l = cur.val && cur.val.lock;
      if (!l || l.id !== id) throw lockErr('索引锁已被接管（这一轮跑得太久），本轮作废、不提交');
      /* [v6.2] 锁还新（LOCK_RENEW 内拿到 / 续过）就只核对、不续写：离别人能接管还有半分钟以上，
         省下的这一次 state.json 写入正是 R2「同一对象写得太密」的来源 */
      if (Date.now() - (l.at || 0) < LOCK_RENEW) return cur.val;
      l.at = Date.now();
      if (!await r2putIf(env, IDX.state, cur.val, cur.etag)) throw lockErr('索引锁续期时被别的任务抢先，本轮作废、不提交');
      return cur.val;
    },
  };
  try { return await fn(deaths, lk); }
  finally {
    try {
      const cur = await r2getE(env, IDX.state);
      if (cur.val && cur.val.lock && cur.val.lock.id === id){
        delete cur.val.lock;
        await r2putIf(env, IDX.state, cur.val, cur.etag);
      }
    } catch {}
  }
}
/** 不拿锁也要改 state 的那几个小动作（解锁 / 清冷却 / 重置降级）：条件写，撞上并发就重读再改，
    不会把别人刚提交的片表指针盖回旧值 */
async function stateMutate(env, fn){
  for (let i = 0; i < 4; i++){
    const cur = await r2getE(env, IDX.state);
    const st = cur.val === undefined ? blankState() : cur.val;
    const r = fn(st);
    if (r === false) return st;
    if (await r2putIf(env, IDX.state, st, cur.etag)) return st;
    await sleep(150 * (i + 1));
  }
  throw lockErr('state.json 正被频繁写入，稍后再试');
}

/* ══════════════════════════════════════════════════════════════════
   分片链（v4.1）

   v4.0 一个年份 = 一个大分片。每一轮任务都要把整年解开、改几行、
   再整年编回去 —— CPU 与内存成本正比于该年份的总行数。年份越满，
   每轮越贵，最终必然撞上 Worker 的资源上限。
   v4.1 改成只追加的分片链：一片写满 PART_ROWS 行就封片，新行只
   进最后那一片。每轮的解码/编码工作量被钉死在一片的大小上，与
   年份总量无关 —— 索引再大，单轮成本也是常数。
     · p0 沿用旧路径，老索引不用迁移，直接当作"已封的第一片"
     · 去重靠单独的 tid 表（只存 base36 增量，解析成本近似于零）
     · 影片记 SP={年:[片号]}，详情只读装着它的那几片
   v6 起分片与 tid 表都是 copy-on-write（见上面「原子提交」）。
   ══════════════════════════════════════════════════════════════════ */

/** 分片 LRU：键就是对象名（带代号），代号一换自然不会读到旧的 */
const partCache = new Map();
async function loadPart(env, state, year, pi){
  const key = partKey(state, year, pi);
  const hit = partCache.get(key);
  if (hit && hit.exp > Date.now()){ partCache.delete(key); partCache.set(key, hit); return hit.v; }
  let v;
  try { v = await r2get(env, key, null); }
  catch (e){ if (e.corrupt){ trace('sys', '分片 ' + key + ' 内容损坏，跳过', { lvl:'err' }); v = null; } else throw e; }
  while (partCache.size >= PART_CACHE) partCache.delete(partCache.keys().next().value);
  partCache.set(key, { v, exp: Date.now()+45000 });
  return v;
}
const dropCaches = () => { idxCache = null; partCache.clear(); };

/** 该年份每片的行数表。老索引（单个大分片）自动视作 [总行数] */
function partRows(state, y){
  const pn = state?.years?.[y]?.pn;
  if (Array.isArray(pn) && pn.length) return pn;
  const legacy = (state?.relsByYear||{})[y] || 0;
  return legacy ? [legacy] : [];
}
const partCount = (state, y) => partRows(state, y).length;
const yearRows  = (state, y) => partRows(state, y).reduce((a,x)=>a+(x||0), 0);

/** tid 表：只存 base36 增量，40000 条约 100KB，解析 ~10ms。rows = 这张表对应的片表行数 */
function tidsBlob(set, rows){
  const arr = [...set].sort((a,b)=>a-b);
  const b = arr.length ? arr[0] : 0;
  let prev = b; const out = [];
  for (const t of arr){ out.push(b36(t - prev)); prev = t; }
  return { v:4, b, n: arr.length, rows: rows == null ? arr.length : rows, t: out.join('.') };
}
function tidsParse(o){
  const s = new Set();
  if (!o || typeof o.t !== 'string') return s;
  let cur = Number(o.b) || 0;
  if (o.t) for (const d of o.t.split('.')){ cur += un36(d); s.add(cur); }
  return s;
}
/**
 * 该年份已收录的 tid。tid 表缺了、坏了、或者比片表记的行数少（v5 被掐在两次写之间留下的）
 * 就从已提交的分片现场重建 —— 只读各片的 t 字段，不解标题。返回 { set, rebuilt }
 */
async function loadTids(env, y, state){
  const want = yearRows(state, y);
  let o = null;
  try { o = await r2get(env, tidsKey(state, y), null); }
  catch (e){ if (!e.corrupt) throw e; }
  if (o && typeof o.t === 'string' && Number(o.rows != null ? o.rows : o.n) >= want) return { set: tidsParse(o), rebuilt: false };
  const s = new Set();
  const n = partCount(state, y);
  for (let i = 0; i < n; i++){
    let sh = null;
    try { sh = await r2get(env, partKey(state, y, i), null); } catch (e){ if (!e.corrupt) throw e; }
    if (!sh || typeof sh.t !== 'string' || !sh.t) continue;
    const b = Number(sh.b) || 0;
    for (const d of sh.t.split('.')) s.add(b + un36(d));
  }
  if (want) trace('sys', y + ' 年 tid 表' + (o ? '落后于片表' : '缺失') + '，已从 ' + n + ' 片重建（' + s.size + ' 条）', { lvl: 'warn' });
  return { set: s, rebuilt: true };
}

/**
 * 分片工作集：一次任务里只会碰"每个年份的最后一片"。
 * cap 由调用方按降级等级压低 —— 上一轮被平台掐过，下一轮就用更小的片。
 * 写盘全部是新代号的对象；flush() 只把新代号记进 state（内存里），由调用方 commitIndex 提交。
 */
function partSet(env, state, opt = {}){
  const cap = Math.max(300, opt.cap || PART_ROWS);
  const Y = new Map();

  async function open(y){
    if (Y.has(y)) return Y.get(y);
    const st = ystOf(state, y);
    const pn = partRows(state, y).slice();
    const pg = pn.map((_, i) => pgOf(state, y, i));
    let pi = Math.max(0, pn.length - 1);
    let groups = {}, dict = null, rows = 0, sealedBad = false;
    const tl = await loadTids(env, y, state);
    if (pn.length){
      if (pn[pi] < cap){
        let sh = null;
        try { sh = await r2get(env, partKey(state, y, pi), null); }
        catch (e){ if (!e.corrupt) throw e; sealedBad = true; }
        if (sh){
          groups = decodeShard(sh); dict = sh.d || null; rows = Object.values(groups).reduce((a,x)=>a+x.length, 0);
          for (const id in groups) for (const r of groups[id]) tl.set.add(Number(r.tid));   // 与已提交分片对齐
        } else if (sealedBad || pn[pi] > 0){
          /* 最后一片读不出来（损坏 / 不见了）：不往它上面覆盖，从新的一片接着写 */
          trace('sys', y + ' 年第 ' + pi + ' 片读不出来，新行改写到下一片（体检里「重算汇总」）', { lvl:'err' });
          pi = pn.length;
        }
      } else {
        pi = pn.length;                       // 最后一片已满 → 直接开新片，不解码
      }
    }
    void st;
    const e = { y, pi, pn, pg, groups, dict, rows, dictLen: 0, retrain: false,
                tids: tl.set, tidsDirty: tl.rebuilt, dirty: false, wrote: [] };
    Y.set(y, e);
    return e;
  }

  async function flushOne(e){
    const rows = Object.values(e.groups).reduce((a,x)=>a+x.length, 0);
    if (!rows){ e.dirty = false; return; }
    const old = e.dict;
    let sh, retrain = false;
    if (rows <= HEAVY_ROWS){ const b = encodeBest(e.y, e.groups, old); sh = b.sh; retrain = b.retrain; }
    else sh = old && old.length >= 32 ? encodeShard(e.y, e.groups, old.slice())
                                      : encodeShard(e.y, e.groups, null);
    const g = newGen();
    await r2put(env, IDX.part(e.y, e.pi, g), sh);
    if (e.pn[e.pi] != null) graveAdd(state, IDX.part(e.y, e.pi, e.pg[e.pi] || ''));   // 被替换下来的旧版本
    e.pn[e.pi] = rows; e.pg[e.pi] = g; e.dict = sh.d; e.dictLen = sh.d.length;
    e.retrain = e.retrain || retrain;
    e.wrote.push(e.pi); e.dirty = false;
  }

  /** 封片换新：本片写盘后，后续行进下一片 */
  async function rotate(e){
    await flushOne(e);
    e.pi = e.pn.length > e.pi ? e.pn.length : e.pi + 1;
    e.groups = {}; e.dict = null; e.rows = 0; e.dirty = false;
  }

  return {
    open,
    /** 该年份已收录的 tid 集合（去重用） */
    async seen(y){ return (await open(y)).tids; },
    /** 当前开着的那片还能装多少行 */
    async room(y){ const e = await open(y); return Math.max(0, cap - e.rows); },
    /**
     * 把一批帖挂到影片上。只写当前片，成本正比于新增行数。
     * 单片上限、最佳片源、SP 都在这里增量维护，不再回头重排整部片。
     */
    async push(y, movies, id, rowsIn){
      let e = await open(y);
      if (e.rows >= cap){ await rotate(e); }
      const mv = movies.m[id];
      let added = 0;
      for (const row of rowsIn){
        const tid = Number(row.tid);
        if (!(tid > 0) || e.tids.has(tid)) continue;
        if (mv && (mv[F.R]||0) >= ROWS_PER_MOVIE) break;
        e.tids.add(tid);
        const r = toRow(tid, row.title);
        (e.groups[id] || (e.groups[id] = [])).push(r);
        e.rows++; added++; e.dirty = true; e.tidsDirty = true;
        if (mv){ mv[F.R] = (mv[F.R]||0) + 1; bumpBest(mv, r); bumpSpec(mv, r); }
      }
      if (mv && added){
        const ys = mv[F.YS] || (mv[F.YS] = []);
        if (!ys.includes(y)) ys.push(y);
        markPart(mv, y, e.pi);
      }
      return added;
    },
    /** 落盘：写当前片 + tid 表（都是新对象），并把片表 / 代号写回 state（内存里，等 commitIndex 提交） */
    async flush(){
      const out = [];
      for (const e of Y.values()){
        if (e.dirty) await flushOne(e);
        const st = ystOf(state, e.y);
        const rows = e.pn.reduce((a,x)=>a+(x||0), 0);
        if (e.tidsDirty || !st.tg){
          const g = newGen();
          await r2put(env, IDX.tids(e.y, g), tidsBlob(e.tids, rows));
          if (st.tg || yearRows(state, e.y) > 0) graveAdd(state, tidsKey(state, e.y));   // 新年份没有旧表可替换
          st.tg = g; e.tidsDirty = false;
        }
        st.pn = e.pn; st.pg = e.pg;
        (state.relsByYear = state.relsByYear || {})[e.y] = rows;
        (state.dictByYear = state.dictByYear || {})[e.y] = e.dictLen || (state.dictByYear||{})[e.y] || 0;
        out.push({ year: e.y, rows, parts: e.pn.length, part: e.pi,
                   dict: e.dictLen, retrain: e.retrain, wrote: e.wrote.slice() });
      }
      state.rels = Object.values(state.relsByYear||{}).reduce((a,x)=>a+x, 0);
      return out;
    },
  };
}

/* ══════════════════════════════════════════════════════════════════
   [v6] 日常维护：备份 / 恢复 / 清理孤儿对象
   ──────────────────────────────────────────────────────────────────
   · 备份：movies.json、state.json、留底队列每天各备一份到 bak/<源>/<日期>/，留最近 BAK_KEEP 天。
     分片不备：它们是不可变对象，state 里记着名字。
   · 恢复（体检里「从备份恢复」）：影片表取备份那一份；state.json 现在这份还能读就留着
     （它指着最新的分片），读不出来才一起取备份。恢复后自动「重算汇总」按分片对齐计数。
   · 孤儿对象：被掐掉的那一轮写了新代号的分片 / tid 表却没来得及提交，没人引用它们 ——
     每天列一遍本源的键，既不被 state 引用、也不在 grave 里、而且已经放了六小时以上的，删掉。
   ══════════════════════════════════════════════════════════════════ */
const BAK_KEEP = 7;
const bakPre = () => 'bak/' + SRC.id + '/';
const idxNs = () => IDX.movies.slice(0, IDX.movies.lastIndexOf('/') + 1);
async function r2list(env, prefix, max){
  const out = [];
  if (!env.R2 || typeof env.R2.list !== 'function') return out;
  let cursor;
  for (let i = 0; i < 20 && out.length < (max || 5000); i++){
    const r = await env.R2.list({ prefix, cursor, limit: 1000 });
    for (const o of (r && r.objects) || []) out.push(o);
    if (!r || !r.truncated) break;
    cursor = r.cursor;
  }
  return out;
}
async function backupNow(env, force){
  const st = await r2get(env, IDX.state, null);
  if (!st) return { ok:true, skipped:'还没有索引，不用备份' };
  if (!force && st.bakAt && Date.now() - st.bakAt < 20 * 3600e3) return { ok:true, skipped:'今天已经备份过' };
  const day = new Date().toISOString().slice(0, 10).replace(/-/g, '');
  const pre = bakPre() + day + '/';
  let n = 0;
  for (const k of [IDX.movies, IDX.state, PEND.key]){
    const o = await env.R2.get(k);
    if (!o) continue;
    const txt = await o.text();
    JSON.parse(txt);                                    // 坏的不备（备份一份坏的毫无意义）
    await env.R2.put(pre + k.slice(k.lastIndexOf('/') + 1), txt, { httpMetadata:{ contentType:'application/json' } });
    n++;
  }
  /* 只留最近 BAK_KEEP 天 */
  const days = [...new Set((await r2list(env, bakPre())).map(o => o.key.slice(bakPre().length).split('/')[0]))].sort();
  const drop = days.slice(0, Math.max(0, days.length - BAK_KEEP));
  if (drop.length){
    const keys = (await r2list(env, bakPre())).map(o => o.key).filter(k => drop.some(d => k.startsWith(bakPre() + d + '/')));
    if (keys.length) await env.R2.delete(keys).catch(() => {});
  }
  await stateMutate(env, (x) => { x.bakAt = Date.now(); x.bakDay = day; });
  trace('sys', '已备份 ' + SRC.name + ' 索引（' + n + ' 份）到 ' + pre + '，保留最近 ' + BAK_KEEP + ' 天', { lvl:'info' });
  return { ok:true, day, files: n, kept: Math.min(days.length, BAK_KEEP), msg: '已备份到 ' + pre };
}
async function restoreBackup(env, lk, day){
  const days = [...new Set((await r2list(env, bakPre())).map(o => o.key.slice(bakPre().length).split('/')[0]))].sort();
  if (!days.length) throw new Error('没有备份可以恢复（每天由定时任务自动备份；也可以在体检里手动「立即备份」）');
  const d = day && days.includes(String(day)) ? String(day) : days[days.length - 1];
  const pre = bakPre() + d + '/';
  const bm = await r2get(env, pre + 'movies.json', null);
  if (!bm || !bm.m) throw new Error('备份 ' + d + ' 里没有可用的影片表');
  let st = null, kept = true;
  try { st = await r2get(env, IDX.state, null); } catch { st = null; }
  if (!st || !st.years){ st = await r2get(env, pre + 'state.json', null); kept = false; }
  if (!st || !st.years) throw new Error('现在的 state.json 读不出来，备份 ' + d + ' 里也没有可用的 state');
  bm.m = bm.m || {}; bm.k = bm.k || {}; bm.u = bm.u || {};
  st.heal = Date.now();                                 // 恢复后按分片重算一遍计数
  delete st.resync;
  await commitIndex(env, lk, bm, st, { shrink: true, force: true });
  const bp = await r2get(env, pre + 'pending.json', null).catch(() => null);
  if (bp && bp.q) await r2put(env, PEND.key, bp).catch(() => {});
  trace('sys', '已从备份 ' + d + ' 恢复影片表（' + Object.keys(bm.m).length + ' 部）' + (kept ? '，片表沿用现在的 state' : '，state 也取自备份'), { lvl:'warn' });
  return { ok:true, day: d, movies: Object.keys(bm.m).length, stateFrom: kept ? 'current' : 'backup',
           msg: '已从 ' + d + ' 的备份恢复 ' + Object.keys(bm.m).length + ' 部影片，稍后自动重算汇总' };
}
/** 孤儿对象：没被提交的新代号分片 / tid 表（被掐掉的那一轮留下的） */
async function orphanSweep(env, state){
  const live = liveKeys(state);
  for (const e of state.grave || []) if (e && e[0]) live.add(e[0]);
  const keep = new Set([IDX.movies, IDX.state, PEND.key, LIB.list, LIB.legacy]);
  const objs = await r2list(env, idxNs());
  const cut = Date.now() - 6 * 3600e3;
  const del = objs.filter(o => /\.(?:p\d+\.)?g[0-9a-z]+\.json$|\.t\.g[0-9a-z]+\.json$/.test(o.key) && !live.has(o.key) && !keep.has(o.key)
    && (o.uploaded ? new Date(o.uploaded).getTime() < cut : false)).map(o => o.key);
  if (del.length) await env.R2.delete(del.slice(0, 1000)).catch(() => {});
  return del.length;
}
/** 定时任务里顺手做：一天一次备份 + 清孤儿；上一轮掐在两次提交之间（heal）就接着重算汇总 */
async function maintain(env){
  const st = await r2get(env, IDX.state, null).catch(() => null);
  if (!st) return;
  if (st.heal || st.resync){
    const r = await repair(env, st.resync ? st.resync.act : 'resync').catch(e => ({ err: e.message || String(e) }));
    trace('sys', '自动重算汇总：' + (r.err || r.msg || ''), { lvl: r.err ? 'warn' : 'info' });
  }
  if (!st.bakAt || Date.now() - st.bakAt > 20 * 3600e3){
    await withIndexLock(env, async () => {
      const b = await backupNow(env, false);
      const cur = await r2get(env, IDX.state, null);
      const n = cur ? await orphanSweep(env, cur) : 0;
      if (n) trace('sys', '清掉 ' + n + ' 个没被提交的孤儿对象（被掐掉的轮次留下的）', { lvl:'info' });
      return b;
    }).catch(e => trace('sys', '日常备份没做成（下次再做）：' + (e.message || e), { lvl:'warn' }));
  }
}

/* 版块自带的附加筛选（剧集那边的"状态"）。想改成"不限"就把 TV_FILTER
   设成空字符串；想另外加条件也从这里进，不用动代码。 */
const srcFilter = (env) => {
  const v = env[SRC.filterVar];
  const t = String(v == null ? SRC.extra : v).trim();
  return !t ? '' : (t[0] === '&' ? t : '&' + t);
};
const listURL = (env, year, pg) => base(env)+'forum.php?mod=forumdisplay&fid='+FID
  + '&filter=sortid&sortid=1&searchsort=1&' + SRC.ykey + '=' + YEARS[year]
  + srcFilter(env) + (pg>1?'&page='+pg:'');

/** 拉一页列表：限速 / 跳转 / 登录墙 分开处理，只有 auth 才重登 */
async function fetchList(env, year, pg){
  return autoRetry('list '+year+'p'+pg, async (i, prevCls) => {
    const s = await session(env, prevCls === 'auth');
    const { r, html, bytes } = await reqHTML(env, listURL(env, year, pg), { cookie:s.cookie, referer: base(env) });
    if (r.status >= 300 && r.status < 400) throw new Error('列表页被跳转（登录墙）');
    if (loginWall(html)) throw new Error('列表页需要登录（登录墙）');
    return { html, bytes, rows: parseBoard(html), last: lastPage(html), board: looksLikeBoard(html) };
  }, { tries: 3, gap: 800, onRetry: async (cls) => { if (cls === 'auth') await dropSession(env); } });
}

/* ══════════════════════════════════════════════════════════════════
   [v6.2] 极限模式：认定结果的进出口
   ──────────────────────────────────────────────────────────────────
   认定工把结果交回浏览器，浏览器再交给扫描轮 —— 中间过一道浏览器，
   所以写进索引之前逐字段核对形状：不合格的整条不要，当成没认过，下次重认。
   ══════════════════════════════════════════════════════════════════ */
const keyOk = (k) => typeof k === 'string' && k.length > 0 && k.length <= 200;
const strCap = (v, n) => typeof v === 'string' ? v.slice(0, n) : '';
/** 认下来的那一条 → 交给浏览器：只带建影片记录要用的那几样 */
const hitOut = (h) => [h.id, h.title || '', h.original_title || '', h.release_date || '', h.poster_path || '',
  h.vote_average || 0, h.vote_count || 0, Array.isArray(h.genre_ids) ? h.genre_ids.slice(0, 12) : []];
function hitIn(a){
  if (!Array.isArray(a) || a.length < 8) return null;
  const id = Number(a[0]);
  if (!Number.isInteger(id) || id <= 0 || id > 2e9) return null;
  const title = strCap(a[1], 200), orig = strCap(a[2], 200);
  if (!title && !orig) return null;
  const date = strCap(a[3], 10);
  if (date && !/^\d{4}(-\d{2}(-\d{2})?)?$/.test(date)) return null;
  const poster = strCap(a[4], 120);
  const va = Number(a[5]), vc = Number(a[6]);
  return { id, title, original_title: orig, release_date: date,
    poster_path: /^\/[\w.-]{1,100}\.(jpe?g|png|webp)$/i.test(poster) ? poster : '',
    vote_average: Number.isFinite(va) && va >= 0 && va <= 10 ? va : 0,
    vote_count: Number.isInteger(vc) && vc >= 0 ? Math.min(vc, 1e8) : 0,
    genre_ids: Array.isArray(a[7]) ? a[7].filter(x => Number.isInteger(x) && x > 0 && x < 1e7).slice(0, 12) : [] };
}
/** 浏览器交回来的一条结果 → { miss } | { hit, nk } | null（形状不对） */
function resIn(v){
  if (!v || typeof v !== 'object') return null;
  if (typeof v.m === 'string') return { miss: PEND_WHY.has(v.m) ? v.m : 'nohit' };
  const hit = hitIn(v.h);
  if (!hit) return null;
  return { hit, nk: keyOk(v.nk) ? v.nk : '' };
}
/** 交给认定工的一组：只带认定要用的字段（不带帖子行 —— 帖子行一直留在 R2 的留底队列里） */
const needOut = (k, e) => ({ k, cn: e.cn || '', la: e.la || '', ys: (e.ys || []).slice(0, 4), y: e.y, t: e.t || '' });
function needIn(x){
  if (!x || typeof x !== 'object' || !keyOk(x.k)) return null;
  const y = Number(x.y);
  return { k: x.k, cn: strCap(x.cn, 120), la: strCap(x.la, 160),
    ys: Array.isArray(x.ys) ? x.ys.map(String).filter(v => /^\d{4}$/.test(v)).slice(0, 4) : [],
    y: Number.isInteger(y) && y > 1900 && y < 2200 ? y : 0, t: strCap(x.t, 200) };
}
/** 排队等认定的条目，按「当前在建的年份优先、再按年份从新到旧」排 */
function waitKeys(pend, doneNow, skip, target){
  const q = pend.q, ks = [];
  for (const k in q){
    const e = q[k];
    if (e.w !== 'wait' || doneNow.has(k) || (skip && skip.has(k))) continue;
    ks.push(k);
  }
  const rank = (k) => (q[k].y === target ? 0 : 1);
  return ks.sort((a, b) => (rank(a) - rank(b)) || ((Number(q[b].y) || 0) - (Number(q[a].y) || 0)));
}

/**
 * 一条认定结果落进索引（浏览器交回来的、扫描轮自己认的，都走这一个口子）。
 * X：{ movies, pend, ps, doneNow, years:Set, maxYears, dirty() }
 * 返回：'gone'（队列里已经没有这条，或这一轮已经写过）· 'defer'（这一轮开的年份够多了，下轮再写）·
 *       'miss' · 写进分片的行数（number，0 = 这些帖子早就在分片里了）
 * 写进分片的条目不从队列里删，只记进 doneNow —— 提交时变成 state.pdone（见 pendSync）。
 */
async function pendApply(X, k, r){
  const e = X.pend.q[k];
  if (!e || X.doneNow.has(k)) return 'gone';
  if (r.miss){
    if (e.w !== 'wait') return 'gone';             // 已经有结论的不覆盖（重试次数、跳过原因都留着）
    if (e.rq){ e.n = (e.n || 0) + 1; delete e.rq; }  // 「重试匹配」排进来的：认不出算一次重试
    e.w = r.miss;
    if (e.r.length > PEND.rows) e.r = e.r.slice(0, PEND.rows);
    X.movies.u[k] = Date.now();
    X.dirty();
    return 'miss';
  }
  const by = pendRowsByYear(e);
  if (!by.size) return 'gone';                     // 年份都不属于这个源（不该出现）：不往乱七八糟的键上写
  const fresh = [...by.keys()].filter(y => !X.years.has(y));
  if (X.years.size + fresh.length > X.maxYears && X.years.size) return 'defer';
  for (const y of fresh) X.years.add(y);
  const id = r.hit.id;
  X.movies.k[k] = id;
  if (r.nk && r.nk !== k) X.movies.k[r.nk] = id;
  if (!X.movies.m[id]) X.movies.m[id] = newMovie(r.hit, Number(e.y) || [...by.keys()][0]);
  let n = 0;
  for (const [y, rows] of by) n += await X.ps.push(y, X.movies, id, rows);
  X.doneNow.add(k);
  delete X.movies.u[k];
  if (r.nk) delete X.movies.u[r.nk];
  return n;
}

/**
 * 持锁的任务自己认一批排队的条目。
 *   · 极限模式：这一轮不抓列表（冷却 / 排队太长 / 全部年份已完成），或者浏览器那边没有认定工可用；
 *   · 普通模式：用这一轮剩下的 TMDB 额度 —— 上次极限模式没认完就关了页面，排队的由普通模式和定时任务接着认。
 * skip：浏览器那边正在认、或刚交回来的键，别重复花子请求。
 */
async function drainWait(env, X, { max, over, skip, target }){
  const q = X.pend.q;
  const all = waitKeys(X.pend, X.doneNow, skip, target);
  if (!all.length || max < 1) return null;
  /* 只认这一轮已经开着的年份，最多再开到 maxYears 个：写分片的编码量跟开了几个年份成正比 */
  const ys = new Set(X.years), pick = [];
  for (const k of all){
    const fresh = [...pendRowsByYear(q[k]).keys()].filter(y => !ys.has(y));
    if (ys.size + fresh.length > X.maxYears && ys.size) continue;
    for (const y of fresh) ys.add(y);
    pick.push(k);
    if (pick.length >= max) break;
  }
  let fixed = 0, still = 0, net = 0, rows = 0, calls = 0, budgetHit = 0;
  for (let i = 0; i < pick.length && calls < max && !over(); ){
    const room = Math.min(5, max - calls, Math.floor((subLeft() - 8) / 2));
    if (room < 1){ budgetHit = 1; break; }
    const groups = pick.slice(i, i + room).map(k => pendGroup(k, q[k]));
    i += groups.length;
    pipe('match', 'i', groups.length);
    let res;
    try { res = await matchBatch(env, groups); }
    catch (e){ if (e.budget){ budgetHit = 1; break; } throw e; }
    let dead = 0;
    for (const g of groups){
      const r = res.get(g.key);
      if (r == null){ net++; dead++; pipe('match', 'e'); continue; }
      calls++;
      const v = await pendApply(X, g.key, r.miss ? { miss: r.why || 'nohit' } : { hit: r.hit, nk: g.nkey });
      if (v === 'miss'){ still++; pipe('match', 'e'); }
      else if (typeof v === 'number'){ fixed++; rows += v; pipe('match', 'o'); pipe('store', 'o', v); }
    }
    if (dead === groups.length) break;              // 整批没回来：TMDB 那头不通，别把预算白烧掉
  }
  return { fixed, still, net, rows, calls, budgetHit };
}

/**
 * 认定工（/api/tm）：认一批、把结果交回浏览器。不持锁、不读写 R2。
 * 自带一整份子请求配额（这是一次独立调用），配额用完的那几组按「网络失败」交回 —— 已认下的照样带回。
 */
async function turboMatch(env, list){
  const t0 = Date.now(), TC = turboCfg();
  const out = {}, groups = [];
  for (const x of (Array.isArray(list) ? list.slice(0, TC.group) : [])){
    const e = needIn(x);
    if (!e || out[e.k] !== undefined) continue;
    out[e.k] = 0;                                    // 0 = 这一次没下结论（网络失败 / 配额用完），浏览器稍后重认
    const g = pendGroup(e.k, e);
    if (g.cn || g.latin) groups.push(g);
  }
  const envT = Object.assign(Object.create(env), { __sub: { n: 0, max: TC.sub }, __r429: 0 });
  let res = new Map();
  if (groups.length){
    try { res = await matchBatch(envT, groups, { soft: true }); }
    catch (e){ trace('tmdb', '认定工这一批没认成：' + (e.message || e), { lvl: 'err', ch: 'match' }); }
  }
  let hit = 0, miss = 0;
  for (const g of groups){
    const r = res.get(g.key);
    if (r == null) continue;
    if (r.miss){ out[g.key] = { m: r.why || 'nohit' }; miss++; continue; }
    out[g.key] = g.nkey !== g.key ? { h: hitOut(r.hit), v: r.via || '', nk: g.nkey } : { h: hitOut(r.hit), v: r.via || '' };
    hit++;
  }
  return { r: out, n: groups.length, hit, miss, n429: envT.__r429 || 0, sub: envT.__sub.n, g: TC.group, ms: Date.now() - t0 };
}

async function buildChunk(env, opt = {}){ return withIndexLock(env, (d, lk) => buildInner(env, opt, d, lk)); }

async function buildInner(env, opt = {}, deaths = 0, lk = null){
  const t0 = Date.now();
  pipeReset();
  let { pages = 0, tmdbMax = 0, year = null } = opt;
  const turbo = !!opt.turbo;
  const TC = turbo ? turboCfg() : null;
  govMode(turbo);
  /* 一轮的规模由计划决定，不再写死：Free 计划一次调用只有 50 个子请求，
     v4 默认 8 页 + 180 次 TMDB ≈ 188 个，必然越线。
     极限模式：TMDB 交给认定工，这一轮的子请求几乎全给列表页。 */
  if (turbo){ pages = TC.pages; tmdbMax = PLAN.tmdb; }
  else {
    pages   = Math.min(pages || PLAN.pages, PLAN.pages * 2);
    tmdbMax = Math.min(tmdbMax || PLAN.tmdb, PLAN.tmdb * 2);
  }
  /* 上一轮被掐过就自动降级，直到能跑完一轮为止 */
  const shift = Math.min(4, deaths);
  pages   = Math.max(1, pages >> shift);
  tmdbMax = Math.max(6, tmdbMax >> shift);
  let budgetHit = 0;
  /* 落盘（编码 + 写 R2）要预留时间，否则抓到最后一刻才开始编码，
     很容易在编码中途被平台掐掉 —— 那正是 v4.0 留下残留锁的场景。 */
  const budget = Math.max(7000, BUDGET_MS - deaths * 3000) - 2500;
  const over = () => Date.now() - t0 > budget;

  const [{ movies, state, m0 }, pend] = await Promise.all([ loadForWrite(env), pendLoad(env) ]);
  let pendDirty = parserMigrate(movies, pend);
  if (pendSync(pend, state)) pendDirty = 1;      // 上几轮已经写进分片的留底条目，这次真正从队列里删掉
  const doneNow = new Set();                      // 这一轮写进分片的留底条目：提交时记进 state.pdone
  govLoad(state);
  await graveSweep(env, state);
  movieKeysFill(movies);

  /* 冷却期：普通模式直接返回 —— 不碰网络，也不白占着锁；顺手把冷却写进 R2 让其它 isolate 一起忍。
     极限模式照样往下走：冷却只挡论坛，认定结果的写入与 TMDB 认定不受影响 */
  const cool0 = govCoolLeft();
  if (cool0 > 0 && !turbo){
    govSave(state);
    await commitIndex(env, lk, null, state).catch(()=>{});
    return { cooling: Math.ceil(cool0/1000), why: GOV.why, degraded: deaths,
      msg: '论坛限速冷却中，'+Math.ceil(cool0/1000)+' 秒后自动继续（'+(GOV.why||'限速')+'）',
      movies: state.movies||0, rels: state.rels||0 };
  }

  const order = year ? [Number(year)] : BUILD_ORDER;
  let target = null;
  for (const y of order){
    const st = state.years[y] || (state.years[y] = newYear());
    if (!st.done || year){ target = y; break; }
  }
  const waitLeft = () => { let n = 0; for (const k in pend.q) if (pend.q[k].w === 'wait' && !doneNow.has(k)) n++; return n; };
  const hitsIn = turbo && Array.isArray(opt.hits) ? opt.hits.slice(0, TC.hits) : [];
  if (!target && !hitsIn.length && !waitLeft())
    return { done:true, msg:'全部年份已完成', movies: state.movies||0, rels: state.rels||0, waitN: 0,
             turbo: turbo ? 1 : 0, ack: [], rej: [], defer: [], need: [] };

  const st = target ? state.years[target] : null;
  if (st){ st.bad = st.bad || []; if (year) st.done = false; }

  /* 降级等级直接压小分片：被掐一次，下一轮的编码量减半，能真正收敛 */
  const ps = partSet(env, state, { cap: Math.max(300, PART_ROWS >> Math.min(3, deaths)) });
  const X = { movies, pend, ps, doneNow, years: new Set(target ? [target] : []),
              maxYears: turbo ? TC.years : 2, dirty(){ pendDirty = 1; } };

  /* ── 极限模式 ①：浏览器交回来的认定结果先写进去（不碰网络） ── */
  const ack = [], rej = [], defer = [], reqKeys = new Set();
  let applied = 0, appliedRows = 0, appliedMiss = 0;
  for (const it of hitsIn){
    if (!Array.isArray(it) || !keyOk(it[0]) || reqKeys.has(it[0])) continue;
    const k = it[0];
    reqKeys.add(k);
    const r = resIn(it[1]);
    if (!r){ rej.push(k); continue; }
    const v = await pendApply(X, k, r);
    if (v === 'defer'){ defer.push(k); continue; }
    ack.push(k);
    if (v === 'miss'){ appliedMiss++; pipe('match', 'e'); }
    else if (typeof v === 'number'){ applied++; appliedRows += v; pipe('match', 'o'); pipe('store', 'o', v); }
  }

  /* ── 这一轮抓几页 ──
     极限模式：冷却中 / 停止前的收尾轮不抓；排队的条目太多（认定工跟不上）先停抓、让认定追上来；
     留底队列快满了就退回普通模式那套（当场认），免得帖子进不了队列 */
  let pagesPlan = target ? pages : 0, backlog = 0, full = 0;
  if (turbo && target){
    if (opt.flush || govCoolLeft()) pagesPlan = 0;
    else if (Object.keys(pend.q).length >= PEND.cap - 400){ full = 1; pagesPlan = Math.max(1, PLAN.pages >> shift); }
    else if (waitLeft() >= TC.high){ pagesPlan = 0; backlog = 1; }
  }
  const queueMode = turbo && !full;               // 不认识的片：进队列（极限）还是当场认（普通）

  /* ── 拉列表：先重试上轮失败的页，再往前推进 ── */
  const fresh = [];
  let advanced = 0, failed = 0, emptyRun = 0, rateHit = 0;
  if (st && pagesPlan > 0){
    const seen = await ps.seen(target);          // 该年份已收录的 tid（全年，跨片）
    const queued = new Set();                    // 本轮已排队的，避免同轮重复
    const queue = st.bad.slice(0, 3);
    /* [修复 7] queue.length 在循环里边读边涨 —— 结果 pg 恒等于 st.page，
       每一轮把同一页抓 pages 遍、只推进一页。基准长度必须先固定下来。 */
    const retryN = queue.length;
    for (let i = retryN; i < pagesPlan; i++){
      const pg = st.page + (i - retryN);
      if (st.last && pg > st.last) break;
      queue.push(pg);
    }
    const stillBad = new Set(st.bad);
    const conc = queueMode ? TC.conc : 1;
    /* [v6.2] 抓页是一条连续的并发池：极限模式同时开 conc 条（请求的起点仍由限速治理器按间隔错开），
       谁先回来谁让出位置，不再「一批等齐了才发下一批」；结果按页码顺序处理（游标、空页收尾都依赖顺序），
       处理到收尾那一页就不再派新的。还不知道总页数时只开一条探路。普通模式 conc=1，与以前逐页抓完全一样 */
    const nextPg = () => {
      while (qi < queue.length){
        const pg = queue[qi++];
        if (st.last && pg > st.last && !stillBad.has(pg)) continue;   // 已知总页数：最后一页之后的不抓（失败重试的页除外）
        return pg;
      }
      return null;
    };
    const handle = (pg, x) => {
      if (x.e){
        const e = x.e, cls = classify(e);
        pipe('list', 'e');
        if (cls === 'budget'){ budgetHit = 1; stillBad.add(pg); stop = true; return; }
        failed++; stillBad.add(pg);
        trace(cls, '第 '+pg+' 页拉取失败: '+e.message, { year: target, page: pg });
        if (cls === 'rate'){ rateHit++; stop = true; }   // [修复 5] 被限速就收工，别把状况搞更糟
        else if (cls === 'auth') stop = true;           // 登录不通也别硬刷
        return;
      }
      const res = x.res;
      stillBad.delete(pg); pipe('list', 'o');
      if (!st.last && res.last) st.last = res.last;
      if (!res.rows.length){
        /* [修复 2] 页面正常但没帖 —— 只有确认过总页数、或连续两页空，才敢收尾 */
        if (!res.board){
          failed++; stillBad.add(pg);
          trace('parse', '第 '+pg+' 页不像版块页，跳过', { year: target });
          return;
        }
        emptyRun++;
        if (st.last && pg >= st.last) st.done = true;
        else if (emptyRun >= 2 && pg > 1) st.done = true;
      } else {
        emptyRun = 0;
        for (const row of res.rows){
          const tid = Number(row.tid);
          if (seen.has(tid) || queued.has(tid)) continue;
          queued.add(tid); fresh.push(row);
        }
      }
      if (pg >= st.page) advanced = Math.max(advanced, pg - st.page + 1);
    };
    let qi = 0, stop = false;
    await new Promise((resolve, reject) => {
      const sent = [], got = new Map();
      let pi = 0, active = 0, finished = false;
      const pump = () => { try { step(); } catch (e){ finished = true; reject(e); } };
      const step = () => {
        if (finished) return;
        /* 按派出的顺序处理已经回来的那一段；收尾页之后回来的结果不要 */
        while (pi < sent.length && got.has(sent[pi])){
          const pg = sent[pi++];
          if (!st.done) handle(pg, got.get(pg));
        }
        if (st.done) stop = true;
        while (!stop && active < (st.last ? conc : 1)){
          if (over() || govCoolLeft()){ if (govCoolLeft()) rateHit++; stop = true; break; }
          /* 留够收尾用的子请求：在路上的每一页最多还要重试两次；普通模式另要给 TMDB 那一段留着 */
          if (subLeft() < (queueMode ? 6 : 10) + active * 2){ budgetHit = 1; stop = true; break; }
          const pg = nextPg();
          if (pg == null) break;
          sent.push(pg); active++;
          pipe('list', 'i');
          fetchList(env, target, pg).then(res => ({ res }), e => ({ e }))
            .then(x => { got.set(pg, x); active--; pump(); });
        }
        if (!active){ finished = true; resolve(); }
      };
      pump();
    });
    st.bad = [...stillBad].slice(0, 24);
  }

  /* ── 按片名归并，压缩 TMDB 调用 ── */
  const byName = new Map();
  for (const row of fresh){
    pipe('parse', 'i');
    const pt = parseTitle(row.title);
    if (!pt.cn){
      pipe('parse', 'e');
      /* [v6.5] 切不出片名的帖子不再丢：连同帖子行进留底（算认不出），解析器升级后「重试匹配」会用新解析器重切 */
      if (pendAdd(pend, { key: 'np|' + norm(row.title).slice(0, 60), cn: '', latin: '', years: pt.years || [], rows: [row] }, target, 'nohit')) pendDirty = 1;
      continue;
    }
    const key = groupKey(pt);
    if (!byName.has(key)) byName.set(key, { key, ...pt, rows: [] });
    byName.get(key).rows.push(row);
    pipe('parse', 'o');
  }

  let attached = 0, matchedNew = 0, cached = 0, skipped = 0, calls = 0, queuedN = 0;
  const todo = [];
  for (const g of byName.values()){
    const known = movies.k[g.key];
    if (known != null && movies.m[known]){
      const n = await ps.push(target, movies, known, g.rows);
      attached += n; pipe('store', 'o', n);
      cached++; continue;
    }
    if (known != null) delete movies.k[g.key];
    if (uSkip(movies, g.key)){ skipped++; continue; }
    todo.push(g);
  }

  let processed = 0, netFail = 0;
  if (queueMode){
    /* ── 极限模式 ②：不认识的连同帖子行进留底队列（wait），交给认定工；明摆着不是电影的当场判掉 ── */
    for (const g of todo){
      const nm = notMovie(g.rows?.[0]?.title || g.cn);
      if (nm){
        if (pendAdd(pend, g, target, nm)){ movies.u[g.key] = Date.now(); processed++; skipped++; pendDirty = 1; }
        continue;
      }
      if (pendAdd(pend, g, target, 'wait')){ processed++; queuedN++; pendDirty = 1; }
    }
    if (queuedN) pipe('match', 'i', queuedN);
  } else {
    const handled = new Set();
    for (let i = 0; i < todo.length && calls < tmdbMax && !over(); ){
      /* matchBatch 每组最多两个子请求，所以一批的大小按剩余预算的一半算，
         另外留 8 个给落盘与收尾 */
      const room = Math.min(5, tmdbMax - calls, Math.floor((subLeft() - 8) / 2));
      if (room < 1){ budgetHit = 1; break; }
      const batch = todo.slice(i, i + room);
      if (!batch.length) break;
      i += batch.length;
      pipe('match', 'i', batch.length);
      let res;
      try { res = await matchBatch(env, batch.map(g =>
        ({ ...g, hint: target, title: g.rows?.[0]?.title || g.cn }))); }
      catch (e){ if (e.budget){ budgetHit = 1; break; } throw e; }
      let dead = 0;
      for (const g of batch){
        const r = res.get(g.key);
        if (r == null){ netFail++; dead++; pipe('match', 'e'); continue; } // 网络失败不算"认不出"，留待下轮
        calls++; processed++; handled.add(g.key);
        if (r.miss){
          /* v4 在这里直接丢掉 g.rows。v5 连行一起留底，重试就不用重爬列表页 */
          movies.u[g.key] = Date.now();
          pendAdd(pend, g, target, r.why || 'nohit');
          pendDirty = 1; skipped++; pipe('match', 'e');
          continue;
        }
        const hit = r.hit;
        movies.k[g.key] = hit.id;
        if (!movies.m[hit.id]) movies.m[hit.id] = newMovie(hit, target);
        const n = await ps.push(target, movies, hit.id, g.rows);
        attached += n; pipe('store', 'o', n);
        matchedNew++; pipe('match', 'o');
      }
      /* 整批都没回来 = TMDB 那头不通（key 失效 / 被限流 / 出网被挡）。
         接着往下认只是把剩下的子请求预算白烧掉，不如把预算留给拉列表，
         并且把话说明白。 */
      if (dead === batch.length && batch.length){
        trace('tmdb', '整批 ' + batch.length + ' 组 TMDB 请求全部失败，本轮不再认定 —— '
          + '先查 TMDB_KEY 是否有效、以及 Worker 出网是否被挡', { lvl:'err', ch:'match' });
        break;
      }
      if (budgetHit) break;
    }
    /* [v6.2] 这一轮没认完的（预算 / 时间用完、网络失败）连同帖子行进留底队列（wait），下一轮先认它们。
       以前只把游标往回拨 ceil(待认/28) 页：网络失败的那一组只要不在最后那几页，帖子就再也抓不回来了 */
    for (const g of todo){
      if (handled.has(g.key)) continue;
      if (pendAdd(pend, g, target, 'wait')){ processed++; queuedN++; pendDirty = 1; }
    }
  }

  /* ── 认排队的条目 ──
     极限模式：这一轮没抓列表（冷却 / 排队太长 / 全部年份已完成），或者浏览器没有认定工可用（solo），
     这一轮的子请求就闲着 —— 拿来认一批；浏览器那边正在认的跳过。普通模式：用剩下的 TMDB 额度。 */
  const fly = new Set(reqKeys);
  if (turbo && Array.isArray(opt.fly)) for (const k of opt.fly.slice(0, 3000)) if (keyOk(k)) fly.add(k);
  let drained = null;
  if (queueMode){
    if (!opt.flush && (opt.solo || pagesPlan === 0))
      drained = await drainWait(env, X, { max: TC.group, over, skip: fly, target });
  } else if (!budgetHit && !over() && calls < tmdbMax){
    drained = await drainWait(env, X, { max: tmdbMax - calls, over, skip: turbo ? fly : null, target });
  }
  if (drained && drained.budgetHit) budgetHit = 1;

  /* ── 游标：只为真正没进队列的那几组往回拨（极限模式下只有队列满了才会发生） ── */
  const pending = todo.length - processed;
  if (st){
    if ((pending > 0 || (rateHit && !queueMode)) && advanced > 0){
      const back = (rateHit && !queueMode) ? advanced : Math.min(advanced, Math.max(1, Math.ceil(pending / 28)));
      st.page = Math.max(1, st.page + advanced - back);
      st.done = false;
    } else {
      st.page = Math.max(1, st.page + advanced);
    }
    if (st.last && st.page > st.last) st.done = true;
  }

  /* ── 落盘：只写各年份的当前那一片 + tid 表，成本与年份总量无关 ── */
  const rowsIn = attached + appliedRows + (drained ? drained.rows : 0);
  pipe('encode', 'i', rowsIn);
  const flushed = await ps.flush();
  pipe('encode', 'o', rowsIn);
  state.movies = Object.keys(movies.m).length;
  state.deaths = 0;                        // 跑完整一轮 → 降级归零
  pipeSave(state, turbo ? 'turbo' : 'build', Date.now() - t0);
  const waitN = waitLeft();
  const fixedAll = matchedNew + applied + (drained ? drained.fixed : 0);
  const missAll = skipped + appliedMiss + (drained ? drained.still : 0);
  /* [v5.2 修复 5] 摘要自己把「入库 0」解释掉：新帖 / 入库 / 新片 / 认定 / 缓存 / 认不出 / 网络失败一起摆出来 */
  const sum = (target ? target + ' 年 · 第 ' + st.page + ' 页 · ' : '排队认定 · ') + '新帖 ' + fresh.length + ' · 入库 ' + rowsIn +
    ' · 新片 ' + fixedAll + (turbo ? ' · 极限（认回 ' + applied + ' · 排队 ' + waitN + '）' : ' · 认定 ' + calls + '/' + (todo.length + cached + skipped) + ' 组') +
    (cached ? ' · 缓存 ' + cached : '') + (missAll ? ' · 认不出 ' + missAll : '') +
    (netFail ? ' · 网络失败 ' + netFail : '') + (pending > 0 ? ' · 待认 ' + pending : '') +
    (backlog ? ' · 排队太长，先停抓' : '') + (full ? ' · 留底队列快满，改为当场认' : '') +
    ' · 子请求 ' + SUB.n + '/' + SUB.max +
    ' · ' + ((Date.now() - t0) / 1000).toFixed(1) + 's';
  trace('index', sum, { lvl: rateHit || budgetHit || (fresh.length && !rowsIn && !queuedN) ? 'warn' : 'info' });
  if (calls || netFail || (drained && drained.calls))
    trace('match', 'TMDB 认定 ' + (calls + (drained ? drained.calls : 0)) + ' 组 · 认下 ' + (matchedNew + (drained ? drained.fixed : 0)) +
      ' 部 · 认不出 ' + (skipped + (drained ? drained.still : 0)) + ' 组（已留底，可重试）· 命中缓存 ' + cached +
      (netFail ? ' · 网络失败 ' + netFail + ' 组（已排队，下轮再认）' : ''),
      { lvl: skipped > matchedNew || netFail ? 'warn' : 'info' });
  /* 留底队列：新进来的条目必须先于提交写（掐在提交前，帖子行还在队列里，不丢）；
     本轮写进分片的条目不在这里删（doneNow → state.pdone，下一轮才删）。
     写之前先核对锁：锁已经被接管的一轮不能拿自己那份旧队列盖掉别人刚写的 */
  if (pendDirty){ if (lk) await lk.check(); await pendSave(env, pend, state, doneNow); }
  else state.pend = pendStat(pend, doneNow);
  pdoneSet(state, doneNow, !!pendDirty);
  eventsFlush(state, [{ at: Date.now(), ch: 'pipe', lvl: 'info', msg: sum }]);
  govSave(state);
  await commitIndex(env, lk, movies, state, { m0 });

  const yearsDone = year ? !!(st && st.done) : BUILD_ORDER.every(y => state.years[y]?.done);
  const out = {
    /* 普通模式：排队的条目也认完才算完；极限模式由浏览器看 waitN 自己判断 */
    done: turbo ? yearsDone : (yearsDone && !waitN),
    year: target, page: st ? st.page : 0, last: st ? st.last : 0, advanced,
    fresh: fresh.length, attached: rowsIn, matchedNew: fixedAll, cached, skipped: missAll, pending,
    tmdbCalls: calls + (drained ? drained.calls : 0), failed, rateHit, bad: st ? st.bad.length : 0,
    sub: SUB.n, subMax: SUB.max, budgetHit, plan: PLAN.name,
    degraded: deaths, gap: GOV.gap, cooling: Math.ceil(govCoolLeft()/1000),
    ms: Date.now()-t0, movies: state.movies, rels: state.rels,
    parts: (flushed[0]||{}).parts || 0, part: (flushed[0]||{}).part || 0,
    retrained: flushed.filter(f=>f.retrain).map(f=>f.year),
    turbo: turbo ? 1 : 0, waitN, queued: queuedN, drained: drained ? drained.fixed : 0,
  };
  if (turbo){
    out.ack = ack; out.rej = rej; out.defer = defer;
    out.applied = applied; out.appliedMiss = appliedMiss;
    out.need = waitKeys(pend, doneNow, fly, target).slice(0, TC.need).map(k => needOut(k, pend.q[k]));
    out.pages = pagesPlan; out.backlog = backlog; out.full = full;
    out.g = TC.group; out.h = TC.hits;
    /* R2 对同一个对象的写入频率有硬限制：两轮的提交至少隔开一秒 */
    out.wait = Math.max(0, 1000 - (Date.now() - t0));
  }
  return out;
}

/** 每日增量：只扫近三年前几页 */
async function incremental(env, headPages = 0){
  return withIndexLock(env, async (deaths, lk) => {
    const t0 = Date.now();
    pipeReset();
    const budget = Math.max(7000, BUDGET_MS - deaths*3000);
    headPages = Math.min(headPages || PLAN.pages, PLAN.pages * 2);
    headPages = Math.max(1, headPages >> Math.min(3, deaths));
    let budgetHit = 0;
    const [{ movies, state, m0 }, pend] = await Promise.all([ loadForWrite(env), pendLoad(env) ]);
    let pendDirty = parserMigrate(movies, pend);
    govLoad(state);
    await graveSweep(env, state);
    movieKeysFill(movies);
    const cool0 = govCoolLeft();
    if (cool0 > 0){
      govSave(state);
      await commitIndex(env, lk, null, state).catch(()=>{});
      return { cooling: Math.ceil(cool0/1000), added:0, calls:0,
        msg: '论坛限速冷却中，'+Math.ceil(cool0/1000)+' 秒后再试' };
    }

    const ps = partSet(env, state, { cap: Math.max(300, PART_ROWS >> Math.min(3, deaths)) });
    let added = 0, calls = 0, failed = 0;

    for (const y of BUILD_ORDER.slice(0,3)){
      if (Date.now()-t0 > budget || govCoolLeft()) break;
      const seen = await ps.seen(y);

      for (let pg = 1; pg <= headPages; pg++){
        if (Date.now()-t0 > budget) break;
        if (subLeft() < 10){ budgetHit = 1; break; }
        let res;
        pipe('list', 'i');
        try { res = await fetchList(env, y, pg); pipe('list', 'o'); }
        catch (e){
          pipe('list', 'e');
          if (e.budget){ budgetHit = 1; break; }
          failed++; trace(classify(e), '增量 '+y+' 第 '+pg+' 页: '+e.message); break;
        }
        const rows = res.rows.filter(x => !seen.has(Number(x.tid)));
        if (!rows.length) break;                     // 这页全旧 → 后面更旧

        const byName = new Map();
        const dedupe = new Set();
        for (const row of rows){
          const tid = Number(row.tid);
          if (dedupe.has(tid)) continue;
          dedupe.add(tid);
          pipe('parse', 'i');
          const pt = parseTitle(row.title);
          if (!pt.cn){
            pipe('parse', 'e');
            if (pendAdd(pend, { key: 'np|' + norm(row.title).slice(0, 60), cn: '', latin: '', years: pt.years || [], rows: [row] }, y, 'nohit')) pendDirty = 1;
            continue;
          }
          const key = groupKey(pt);
          if (!byName.has(key)) byName.set(key, { key, ...pt, rows: [] });
          byName.get(key).rows.push(row);
          pipe('parse', 'o');
        }
        /* 已经认过的先入库，认不出来的攒到一起走 matchBatch */
        const need = [];
        for (const g of byName.values()){
          const id = movies.k[g.key];
          if (id != null && movies.m[id]){
            const n = await ps.push(y, movies, id, g.rows);
            added += n; pipe('store', 'o', n);
          } else if (!uSkip(movies, g.key)) need.push(g);
        }
        for (let i = 0; i < need.length && calls < PLAN.tmdb; ){
          const room = Math.min(5, Math.floor((subLeft() - 8) / 2));
          if (room < 1){ budgetHit = 1; break; }
          const batch = need.slice(i, i + room); i += batch.length;
          pipe('match', 'i', batch.length);
          let res;
          try { res = await matchBatch(env, batch.map(g =>
            ({ ...g, hint: y, title: g.rows?.[0]?.title || g.cn }))); }
          catch (e){ if (e.budget){ budgetHit = 1; break; } throw e; }
          for (const g of batch){
            const r = res.get(g.key);
            if (r == null){ pipe('match', 'e'); continue; }
            calls++;
            if (r.miss){
              movies.u[g.key] = Date.now();
              pendAdd(pend, g, y, r.why || 'nohit');
              pendDirty = 1; pipe('match', 'e'); continue;
            }
            const id2 = movies.k[g.key] = r.hit.id;
            if (!movies.m[id2]) movies.m[id2] = newMovie(r.hit, y);
            pipe('match', 'o');
            const n = await ps.push(y, movies, id2, g.rows);
            added += n; pipe('store', 'o', n);
          }
          if (budgetHit) break;
        }
        if (budgetHit) break;
      }
    }

    pipe('encode', 'i', added); await ps.flush(); pipe('encode', 'o', added);
    state.movies = Object.keys(movies.m).length;
    state.deaths = 0;
    pipeSave(state, 'incremental', Date.now() - t0);
    if (pendDirty){ await lk.check(); await pendSave(env, pend, state); }
    const isum = '增量扫描：新增片源 ' + added + ' · TMDB ' + calls + ' · 子请求 ' +
      SUB.n + '/' + SUB.max + ' · ' + ((Date.now() - t0) / 1000).toFixed(1) + 's';
    trace('index', isum, { lvl: budgetHit ? 'warn' : 'info' });
    if (added) eventsFlush(state, [{ at: Date.now(), ch:'pipe', lvl:'info', msg: isum }]);
    govSave(state);
    state.lastIncremental = { at: Date.now(), added, calls, failed, ms: Date.now()-t0 };
    await commitIndex(env, lk, movies, state, { m0 });
    return { added, calls, failed, degraded: deaths, movies: state.movies, rels: state.rels,
             sub: SUB.n, subMax: SUB.max, budgetHit, plan: PLAN.name, ms: Date.now()-t0 };
  });
}

/** 单独重建某一年：清掉该年分片 + 从所有影片的 ys 里摘掉这一年 */
async function resetYear(env, year){
  return withIndexLock(env, async (deaths, lk) => {
    year = Number(year);
    if (!YEARS[year]) throw new Error('未知年份 '+year);
    const { movies, state, m0 } = await loadForWrite(env);
    let touched = 0, dropped = 0;
    for (const id of Object.keys(movies.m)){
      const mv = movies.m[id], ys = mv[F.YS]||[];
      if (mv[F.SP] && mv[F.SP][year]) delete mv[F.SP][year];
      if (!ys.includes(year)) continue;
      mv[F.YS] = ys.filter(y => y !== year); touched++;
      if (!mv[F.YS].length){ delete movies.m[id]; dropped++; }
    }
    for (const k of Object.keys(movies.k)) if (!movies.m[movies.k[k]]) delete movies.k[k];
    movies.u = {};
    /* 旧分片不当场删：记进 grave，提交之后十分钟再删（提交前被掐，一切照旧） */
    const np = partCount(state, year);
    for (let i = 0; i < np; i++) graveAdd(state, partKey(state, year, i));
    if (state.years[year]) graveAdd(state, tidsKey(state, year));
    state.years[year] = newYear();
    state.years[year].pn = [];
    (state.relsByYear = state.relsByYear||{})[year] = 0;
    state.rels = Object.values(state.relsByYear).reduce((a,x)=>a+x,0);
    state.movies = Object.keys(movies.m).length;
    state.deaths = 0;
    await commitIndex(env, lk, movies, state, { m0, shrink: true, force: true });
    return { year, touched, dropped, movies: state.movies };
  });
}

/**
 * v3 → v4 迁移：一次搬一年，可重复调用。
 * v4.1 起按分片链写入，并且单次只搬 MIG_ROWS 行，剩下的记游标下次接着搬 ——
 * 老库里一个年份可能有几万行，一次搬完必然超资源上限。
 */
const MIG_ROWS = 9000;
async function migrateYear(env, year){
  return withIndexLock(env, async (deaths, lk) => {
    const old = await r2get(env, IDX.v3.movies, null);
    if (!old) throw new Error('没有找到 v3 索引（idx/movies.json）');
    const oldState = await r2get(env, IDX.v3.state, { years:{} });
    const { movies, state, m0 } = await loadForWrite(env);
    state.migrated = state.migrated || {};
    state.migAt = state.migAt || {};

    const pending = BUILD_ORDER.filter(y => !state.migrated[y]);
    const y = year ? Number(year) : pending[0];
    if (!y) return { done:true, msg:'迁移已完成', movies: state.movies||0 };

    const rels = await r2get(env, IDX.v3.rels(y), {});
    const ids = Object.keys(rels).sort((a,b)=>Number(a)-Number(b));
    let cursor = state.migAt[y] || 0;
    if (cursor >= ids.length){ cursor = 0; }

    /* 先按游标切出这一批，训练一套码本给这一批的所有分片复用 */
    const batch = [];
    let rows = 0, i = cursor;
    for (; i < ids.length && rows < MIG_ROWS; i++){
      const id = ids[i];
      const om = old.m?.[id];
      if (!om) continue;
      let list = (rels[id]||[]).map(([tid,title]) => toRow(tid, title));
      if (list.length > ROWS_PER_MOVIE){ list.sort(betterRow); list.length = ROWS_PER_MOVIE; }
      if (!list.length) continue;
      if (!movies.m[id]) movies.m[id] = [ om.n||'', om.o||'', om.y||'', om.p||'', om.t||0,
        om.c||0, om.g||[], [], 0, 0, null, null, null, null, 0 ];
      const mv = movies.m[id];
      if (!(mv[F.YS]||[]).includes(y)) (mv[F.YS] = mv[F.YS]||[]).push(y);
      batch.push([id, list]);
      rows += list.length;
    }
    const done = i >= ids.length;

    const pn = partRows(state, y).slice();
    const pg = pn.map((_, i) => pgOf(state, y, i));
    let pi = pn.length ? pn.length - 1 : 0;
    let acc = {}, accRows = pn.length ? pn[pi] : 0;
    if (accRows >= PART_ROWS){ pi = pn.length; accRows = 0; }
    else if (pn.length){                       // 续写未满的那一片
      const sh = await r2get(env, partKey(state, y, pi), null);
      if (sh) acc = decodeShard(sh);
    }
    const dict = trainCodebook(batch.flatMap(([,l]) => l.map(r=>r.title)));
    const writePart = async () => {
      if (!accRows) return;
      const sh = encodeShard(y, acc, dict.slice());
      const g = newGen();
      await r2put(env, IDX.part(y, pi, g), sh);
      if (pn[pi] != null) graveAdd(state, IDX.part(y, pi, pg[pi] || ''));
      pn[pi] = Object.values(acc).reduce((a,x)=>a+x.length,0); pg[pi] = g;
      (state.dictByYear = state.dictByYear||{})[y] = sh.d.length;
      acc = {}; accRows = 0; pi = pn.length > pi ? pn.length : pi + 1;
    };
    const tids = (await loadTids(env, y, state)).set;
    for (const [id, list] of batch){
      const mv = movies.m[id];
      const keep = list.filter(r => !tids.has(Number(r.tid)));
      if (!keep.length) continue;
      for (const r of keep){ tids.add(Number(r.tid)); bumpBest(mv, r); }
      mv[F.R] = (mv[F.R]||0) + keep.length;
      (acc[id] || (acc[id] = [])).push(...keep);
      markPart(mv, y, pi);
      accRows += keep.length;
      if (accRows >= PART_ROWS) await writePart();
    }
    await writePart();
    const tg = newGen();
    await r2put(env, IDX.tids(y, tg), tidsBlob(tids, pn.reduce((a,x)=>a+(x||0),0)));
    if (state.years[y]) graveAdd(state, tidsKey(state, y));

    for (const k of Object.keys(old.k||{})) if (movies.m[old.k[k]]) movies.k[k] = old.k[k];

    const st = state.years[y] = { ...newYear(), ...(oldState.years?.[y] || {}), bad: [] };
    st.pn = pn; st.pg = pg; st.tg = tg;
    state.migAt[y] = done ? 0 : i;
    if (done) state.migrated[y] = true;
    const total = pn.reduce((a,x)=>a+x,0);
    (state.relsByYear = state.relsByYear||{})[y] = total;
    state.rels = Object.values(state.relsByYear).reduce((a,x)=>a+x,0);
    state.movies = Object.keys(movies.m).length;
    state.deaths = 0;
    movieKeysFill(movies);
    await commitIndex(env, lk, movies, state, { m0 });
    const left = BUILD_ORDER.filter(x => !state.migrated[x]);
    return { year:y, rows, parts: pn.length, total, movies: state.movies,
      yearDone: done, left: left.length, done: !left.length,
      msg: done ? y+' 年迁移完成' : y+' 年还剩 '+(ids.length-i)+' 部，继续调用即可' };
  });
}

/**
 * 码本重训：一次只压一片。整年重编在大年份上必然超资源上限，
 * 所以改成按片来，前端顺着 parts 依次调用即可。
 */
async function optimizeYear(env, year, part){
  return withIndexLock(env, async (deaths, lk) => {
    year = Number(year);
    const { state } = await loadForWrite(env);
    const pn = partRows(state, year);
    if (!pn.length) return { year, skipped:true, parts:0, msg:'该年份没有分片' };
    const pi = part == null || part === '' ? pn.length - 1 : Number(part);
    if (!(pi >= 0 && pi < pn.length)) return { year, skipped:true, parts:pn.length, msg:'没有第 '+pi+' 片' };
    const raw = await r2get(env, partKey(state, year, pi), null);
    if (!raw || !raw.i?.length) return { year, part:pi, parts:pn.length, skipped:true, msg:'第 '+pi+' 片是空的' };
    const rows = raw.rows || raw.n?.length || 0;
    if (rows > SPLIT_MAX) return { year, part:pi, parts:pn.length, skipped:true, rows,
      msg:'第 '+pi+' 片有 '+rows+' 行，先用「拆分大片」再压实' };
    const before = JSON.stringify(raw).length;
    const groups = decodeShard(raw);
    const { sh, retrain } = encodeBest(year, groups, raw.d);
    const after = JSON.stringify(sh).length;
    /* 压实前后逐行核对：解出来必须和原来一模一样，否则不写 */
    if (after < before && !sameGroups(groups, decodeShard(sh)))
      throw new Error(year + ' 年第 ' + pi + ' 片压实后核对不一致，已放弃写入');
    if (after < before){
      const g = newGen();
      await r2put(env, IDX.part(year, pi, g), sh);
      const st = ystOf(state, year);
      st.pn = pn.slice(); st.pg = pn.map((_, i) => pgOf(state, year, i));
      graveAdd(state, partKey(state, year, pi));
      st.pg[pi] = g;
      (state.dictByYear = state.dictByYear||{})[year] = sh.d.length;
    }
    await commitIndex(env, lk, null, state);
    return { year, part:pi, parts:pn.length, before, after: Math.min(before, after),
      saved: Math.max(0, before-after),
      ratio: +(before/Math.max(1,Math.min(before,after))).toFixed(2),
      retrained: retrain && after < before, dict: sh.d.length, rows,
      next: pi > 0 ? pi-1 : null,
      msg: after < before ? year+' 年第 '+pi+' 片已压实' : year+' 年第 '+pi+' 片已经是更优编码' };
  });
}

/**
 * 拆分大片：把 v4.0 留下的整年大分片切成 PART_ROWS 一片。
 * 分片之间没有顺序含义，所以切出来的新片直接追加到链尾，
 * 只需要把受影响影片的 SP 改掉。一次切一片，返回 left 让前端接着调。
 */
async function splitYear(env, year){
  return withIndexLock(env, async (deaths, lk) => {
    year = Number(year);
    const { movies, state, m0 } = await loadForWrite(env);
    const pn = partRows(state, year).slice();
    const pg = pn.map((_, i) => pgOf(state, year, i));
    const big = pn.findIndex(n => n > PART_ROWS * 1.5);
    if (big < 0) return { year, parts: pn.length, left: 0, msg:'没有需要拆分的大片' };
    if (pn[big] > SPLIT_MAX) throw new Error(year+' 年第 '+big+' 片有 '+pn[big]+' 行，超出可拆上限，请对该年份「重建」');

    const raw = await r2get(env, partKey(state, year, big), null);
    if (!raw){ pn[big] = 0; ystOf(state, year).pn = pn; ystOf(state, year).pg = pg; await commitIndex(env, lk, null, state);
      return { year, parts: pn.length, left: 0, msg:'第 '+big+' 片不存在，已修正片表' }; }
    const groups = decodeShard(raw);
    const ids = Object.keys(groups);
    const dict = raw.d && raw.d.length >= 32 ? raw.d : trainCodebook(ids.flatMap(id => groups[id].map(r=>r.title)));

    /* 第一刀留在原位，其余追加到链尾 */
    const slices = [];
    let cur = {}, curRows = 0;
    for (const id of ids){
      if (curRows && curRows + groups[id].length > PART_ROWS){ slices.push(cur); cur = {}; curRows = 0; }
      cur[id] = groups[id]; curRows += groups[id].length;
    }
    if (curRows) slices.push(cur);

    const targets = [big];
    for (let k = 1; k < slices.length; k++) targets.push(pn.length + k - 1);
    graveAdd(state, partKey(state, year, big));
    for (let k = 0; k < slices.length; k++){
      const sh = encodeShard(year, slices[k], dict.slice());
      const g = newGen();
      await r2put(env, IDX.part(year, targets[k], g), sh);
      pn[targets[k]] = Object.values(slices[k]).reduce((a,x)=>a+x.length,0);
      pg[targets[k]] = g;
      for (const id of Object.keys(slices[k])){
        const mv = movies.m[id];
        if (!mv) continue;
        const sp = mv[F.SP] && typeof mv[F.SP] === 'object' ? mv[F.SP] : (mv[F.SP] = {});
        sp[year] = (sp[year] || []).filter(x => x !== big);
        markPart(mv, year, targets[k]);
      }
    }
    for (let k = 0; k < pn.length; k++){ if (pn[k] == null) pn[k] = 0; if (pg[k] == null) pg[k] = ''; }
    const yst = ystOf(state, year);
    yst.pn = pn; yst.pg = pg;
    (state.relsByYear = state.relsByYear||{})[year] = pn.reduce((a,x)=>a+x,0);
    state.rels = Object.values(state.relsByYear).reduce((a,x)=>a+x,0);
    await commitIndex(env, lk, movies, state, { m0 });
    const left = pn.filter(n => n > PART_ROWS * 1.5).length;
    return { year, from: big, into: targets, parts: pn.length, left,
      msg: year+' 年第 '+big+' 片已拆成 '+slices.length+' 片' + (left ? '，还剩 '+left+' 片要拆' : '') };
  });
}

/* ══════════════════════════════════════════════════════════════════
   自诊断
   ══════════════════════════════════════════════════════════════════ */
async function diagnose(env){
  const checks = [];
  const add = (id, name, level, detail, fix, arg) =>
    checks.push({ id, name, level, detail, fix: fix||null, arg: arg==null?null:String(arg) });
  const timed = async (id, name, fn, fix) => {
    const t = Date.now();
    try { const d = await fn(); add(id, name, d?.level||'ok', (d?.detail||'正常') + ' · ' + (Date.now()-t) + 'ms', d?.fix||fix); }
    catch (e){
      /* 被限速不是"故障"，是"现在别打" —— 分开报，给的修复动作也不同 */
      const cls = classify(e);
      add(id, name, cls === 'rate' ? 'warn' : 'fail',
        e.message + (e.preview ? ' · 预览：'+e.preview : '') + ' · ' + (Date.now()-t) + 'ms',
        cls === 'rate' ? 'cooldown' : (cls === 'auth' ? 'relogin' : fix));
    }
  };

  /* 1. 环境 */
  add('bind.r2','R2 绑定', env.R2 ? 'ok':'fail', env.R2 ? '已绑定':'未绑定，索引无法读写');
  add('bind.kv','KV 绑定', env.KV ? 'ok':'warn', env.KV ? '已绑定':'未绑定，会话与种子缓存退化为单实例内存');
  add('sec.site','论坛账号', (env.SITE_USER&&env.SITE_PASS)?'ok':'fail', (env.SITE_USER&&env.SITE_PASS)?'已配置':'缺少 SITE_USER / SITE_PASS');
  add('sec.tmdb','TMDB_KEY', env.TMDB_KEY?'ok':'fail', env.TMDB_KEY?'已配置':'缺少 TMDB_KEY，无法匹配影片');
  add('sec.gate','访问口令', env.GATE?'ok':'warn', env.GATE?'已开启':'未设置 GATE，接口对外公开');
  add('lib.cfg','片库对照', recvBase(env)?'ok':'warn',
    (() => {
      const u = recvBase(env);
      if (!u) return '未配置 RECV_BASE / STREAM_BASE，不会过滤库中已有';
      return String(u.host).replace(/^https?:\/\//,'') +
        (u.via === 'r2' ? ' · 总账直读（公开 R2）' : ' · 经 Stream 取总账，取不到则回落文件名认定');
    })());

  /* 2. 限速状态 —— 放在网络检查前面，先说清楚现在能不能打 */
  const cool = govCoolLeft();
  add('net.rate','限速状态', cool ? 'warn' : (GOV.gap > 1200 ? 'warn' : 'ok'),
    cool ? '断路器已打开，还需冷却 '+Math.ceil(cool/1000)+' 秒（'+(GOV.why||'限速')+'）'
         : '请求间隔 '+GOV.gap+'ms · 累计惩罚 '+GOV.strikes,
    cool ? 'cooldown' : null);

  /* 3. 外部依赖。带上现有会话去探活：匿名请求更容易被 WAF 挡下来，
        以前那句"响应为空或过短"多半就是这么来的。 */
  let sess = null;
  await timed('net.forum','论坛可达', async () => {
    sess = await jget(env, kkey(env,'sess')).catch(()=>null);
    const { r, html, bytes } = await reqHTML(env, 'forum.php?mod=forumdisplay&fid='+FID,
      { cookie: sess?.cookie, noGate: true });
    if (!/[\u4e00-\u9fa5]/.test(html)) return { level:'warn', detail:'GBK 解码可能不正确' };
    return { detail:'HTTP '+r.status+' · '+(bytes/1024|0)+'KB' };
  });
  await timed('net.login','论坛登录', async () => {
    /* 有会话就别重登 —— 每点一次体检都强制登录，本身就是在触发限速 */
    if (sess?.cookie){
      const age = sess.at ? Math.round((Date.now()-sess.at)/1000) : null;
      return { detail:'已有有效会话' + (age!=null ? '（'+age+'s 前建立）' : '') + '，未重新登录以免触发限速' };
    }
    const s2 = await session(env, true);
    return { detail:'重新登录成功，Cookie ' + (s2.cookie||'').split(';').length + ' 项' };
  }, 'relogin');
  /* [v5.2] 把切出来的片名亮出来。v5.1 只报一个"解析率 100%"，可
     「魔法姐妹露露与莉莉 .1080」也算解析成功 —— 数字好看，实际搜不中。 */
  let boardRows = [];
  await timed('net.board','列表解析', async () => {
    const res = await fetchList(env, BUILD_ORDER[0], 1);
    boardRows = res.rows || [];
    if (!res.rows.length) return { level: res.board ? 'warn':'fail',
      detail: res.board ? '页面正常但没解析出帖子（可能这一页真的空）'
                        : '页面不像版块页，选择器可能已失效' };
    const named = res.rows.filter(r => parseTitle(r.title).cn).length;
    const rate = Math.round(named/res.rows.length*100);
    const sample = res.rows.slice(0, 3).map(r => {
      const p = parseTitle(r.title);
      return (p.cn || '?') + (p.latin ? ' / ' + p.latin : '');
    }).join('、');
    return { level: rate < 85 ? 'warn':'ok',
      detail: res.rows.length+' 条 · 片名解析率 '+rate+'% · 共 '+(res.last||'?')+' 页 · 切出来是：'+sample };
  });
  await timed('net.tmdb','TMDB 接口', async () => {
    const j = await tmdb(env,'/search/'+SRC.kind,{query: isTV() ? '权力的游戏' : '沙丘'});
    return { detail:'返回 '+(j.results?.length||0)+' 条' };
  });
  /* [v5.2] 端到端抽查：拿刚才那一页的前几条真的走一遍认定。
     「新帖 150 · 入库 0」这类故障，前面每一项都会显示正常 —— 论坛能连、
     TMDB 能连、解析率 100% —— 只有真的认一次才看得出来。 */
  await timed('idx.match','片名认定抽查', async () => {
    if (!env.TMDB_KEY) return { level:'warn', detail:'缺少 TMDB_KEY，跳过' };
    if (subLeft() < 10) return { level:'warn', detail:'本次调用子请求预算不足，跳过' };
    const gs = [];
    for (const row of boardRows){
      const pt = parseTitle(row.title);
      if (!pt.cn) continue;
      const key = groupKey(pt);
      if (gs.some(g => g.key === key)) continue;
      gs.push({ key, ...pt, hint: BUILD_ORDER[0], title: row.title, rows: [row] });
      if (gs.length >= 3) break;
    }
    if (!gs.length) return { level:'warn', detail:'这一页没有可抽查的帖子' };
    const r = await matchBatch(env, gs);
    const ok = [], bad = [];
    for (const g of gs){
      const v = r.get(g.key), nm = g.cn || g.latin || g.key;
      if (v && v.hit) ok.push(nm + ' → ' + (v.hit.title || v.hit.id) + '（' + (v.via||'') + '）');
      else bad.push(nm + '（' + (v ? (v.why || '认不出') : '请求失败') + '）');
    }
    return { level: ok.length ? (bad.length ? 'warn' : 'ok') : 'fail',
      detail: '抽查 ' + gs.length + ' 组 · 认下 ' + ok.length +
        (ok.length ? ' · ' + ok.join('、') : '') +
        (bad.length ? ' · 没认下：' + bad.join('、') : ''),
      fix: ok.length ? null : 'retryUnmatched' };
  });
  if (recvBase(env) || liveOn(env)) await timed('net.lib','片库可达', async () => {
    /* [v6.3] 先探 Stream v25 的实时清单（库快照指纹几十字节）—— 它才是现在的主路径 */
    if (liveOn(env)){
      const ptr = isTV() ? null : await liveGet(env, 'lib-ptr.json', 6000).catch(() => null);
      const tvl = isTV() ? await liveGet(env, 'tv/list-v1.json', 15000).catch(() => null) : null;
      if (ptr && ptr.g) return { level: 'ok', detail: '实时清单（Stream v25，公开 R2）· 库快照指纹 ' + ptr.g };
      if (tvl && Array.isArray(tvl.series)) return { level: 'ok', detail: '实时剧集表（Stream v25，公开 R2）· ' + tvl.series.length + ' 部' };
      if (streamRoot(env) && env.STREAM_KEY){
        const g = await streamApi(env, isTV() ? '/api/tv' : '/api/gen').catch(e => ({ err: e.message || String(e) }));
        if (g && !g.err && (g.gen || Array.isArray(g.series)))
          return { level: 'ok', detail: '实时清单（Stream v25 接口，STREAM_KEY 登录）' + (g.gen ? ' · 指纹 ' + g.gen + ' · ' + (g.count || 0) + ' 个文件' : ' · ' + g.series.length + ' 部') };
        if (g && g.err) return { level: 'warn', detail: 'Stream 接口登录不上：' + g.err };
      }
    }
    /* 实时清单拿不到：看总账（Stream v22 的快照，v25 不再更新） */
    const m = await recvGet(env, 'meta', 6000).catch(e => ({ err: e.message || String(e) }));
    if (m && m.gen)
      return { level: 'warn',
        detail: '实时清单拿不到，正在用总账（Stream v22 的快照，v25 不再更新：之后进库的片会显示成缺片）。'
          + '把 Stream 的 R2 桶挂在 RECV_BASE 这个域名上，或者配 STREAM_BASE + STREAM_KEY。 · 总账 gen=' + m.gen + ' · ' + (m.count||0) + ' 部（电影 ' + (m.movies||0) +
          ' · 剧集 ' + (m.series||0) + '）' +
          (m.pending ? ' · Stream 那边还有 ' + m.pending + ' 部待匹配 TMDB' : '') +
          (m.unmatched ? ' · TMDB 查无 ' + m.unmatched : '') };
    if (m && m.err) return { level:'warn', detail:'总账取不到（' + m.err + '），本次走文件名认定' };
    if (!env.STREAM_BASE) return { level:'warn', detail:'总账还没有（Stream 未升到 v22 或尚未建账），且未配 STREAM_BASE 回退' };
    const s = libScan(await libFetch(env, 1));
    return { level: s.files ? 'ok' : 'warn',
      detail: '（总账不可用，回落文件名认定）' + (s.files ? s.files+' 个文件 · '+s.cands+' 个候选片名'
                      : '连上了，但一个视频文件都没有（ROOT_FOLDER 对吗）') };
  });
  await timed('lib.list','片库对照成品 A/list.json', async () => {
    if (!recvBase(env) && !liveOn(env)) return { level:'warn', detail:'未配置 RECV_BASE / STREAM_BASE，未启用' };
    const d = await r2get(env, LIB.list, null);
    if (d && d.v === 8){
      const left = (d.todo || []).length + (d.part || 0);
      return { level: left ? 'warn' : 'ok',
        detail: '实时清单（' + (d.via === 'r2' ? '公开 R2' : 'Stream 接口') + '）· 片库 ' + (d.files || 0) + ' 个文件 → ' + (d.mine || 0) + ' 部 · '
          + (d.ids || []).length + ' 部带 TMDB id（总账 ' + (d.viaLedger || 0) + ' · 这边认定 ' + (d.viaTmdb || 0) + '）'
          + (left ? ' · 还有 ' + left + ' 个待认定（片库面板点「认定」，或等定时任务）' : '')
          + ' · 清单更新于 ' + (d.liveTs ? new Date(d.liveTs).toISOString().slice(0, 16).replace('T', ' ') : '—') };
    }
    if (d && d.v === 7){
      const days = d.recvTs ? Math.floor((Date.now() - d.recvTs) / 86400e3) : null;
      return { level: days != null && days > 3 ? 'warn' : 'ok',
        detail: '总账直读 · gen=' + (d.gen || '?') + ' · 本源 ' + (d.mine || 0) + ' 部，其中 ' + (d.ids || []).length + ' 部带 TMDB id'
          + (days != null ? ' · 总账是 ' + days + ' 天前写的' + (days > 3 ? '（Stream v25 不再更新它，之后进库的片会显示成缺片）' : '') : '') };
    }
    if (d && d.v === 6){
      return { level: d.ids && d.ids.length ? 'ok' : 'warn',
        detail: '总账直读 · gen=' + (d.gen||'?') + ' · 本源 ' + (d.mine||0) + ' 部，其中 ' +
          (d.ids||[]).length + ' 部带 TMDB id（精确比对）' +
          (d.missed ? ' · ' + d.missed + ' 部总账里也没认出来，退模糊兜底' : '') +
          ' · 片库共 ' + (d.files||0) + ' 个文件' };
    }
    if (!d || d.v !== 5) return { level:'warn', detail:'还没有成品，去片库面板点「重新同步」生成' };
    const left = (d.todo||[]).length;
    return { level: left ? 'warn' : 'ok',
      detail: (d.ids||[]).length+' 部已认定 TMDB · 认过但 TMDB 没有 '+((d.miss||[]).length||0)+
        ' · 模糊兜底键 '+(((d.weak||[]).length)+((d.loose||[]).length))+
        (left ? ' · 还有 '+left+' 个待认定（继续点「认定」即可）'
              : (d.scan ? ' · 已全部认定' : ' · 还没被 v5 扫描过，去片库面板点「重新扫描片库」')) };
  });
  add('plan.quota','平台配额', 'ok',
    planOf(env).name+' 计划 · 单次调用子请求预算 '+planOf(env).sub+'/'+planOf(env).hard+
    ' · 单轮 '+planOf(env).pages+' 页 / '+planOf(env).tmdb+' 次 TMDB · 单片 '+PART_ROWS+' 行');

  /* 3. 索引本身 */
  let movies = null, state = null;
  try {
    movies = await r2get(env, IDX.movies, null);
    state  = await r2get(env, IDX.state, null);
  } catch (e){ add('idx.read','索引可读','fail', e.message, e.corrupt ? 'restore' : null); }
  if (state){
    add('idx.commit','提交一致', state.heal || state.resync ? 'warn' : 'ok',
      state.heal ? '上一轮掐在两次提交之间，影片表计数待按分片重算（定时任务会自动做）'
        : state.resync ? '重算汇总进行到一半（定时任务会接着做）' : 'movies.json 与 state.json 是同一次提交',
      state.heal || state.resync ? 'resync' : null);
    const bak = state.bakAt ? Math.round((Date.now() - state.bakAt) / 3600e3) : null;
    add('idx.backup','每日备份', bak == null ? 'warn' : (bak > 48 ? 'warn' : 'ok'),
      bak == null ? '还没有备份（定时任务每天自动备份一次）' : '最近一次 ' + (state.bakDay || '') + '（' + bak + ' 小时前），保留 ' + BAK_KEEP + ' 天',
      bak == null || bak > 48 ? 'backup' : null);
  }

  if (!movies || !state){
    add('idx.exist','索引存在','warn','还没有 v4 索引',
      (await r2get(env, IDX.v3.movies, null).catch(()=>null)) ? 'migrate' : 'build');
  } else {
    const ids = Object.keys(movies.m||{});
    add('idx.exist','索引存在', ids.length?'ok':'warn', ids.length+' 部影片 · '+(state.rels||0)+' 个片源');

    const orphan = Object.keys(movies.k||{}).filter(k => !movies.m[movies.k[k]]).length;
    add('idx.orphan','归并键完整', orphan?'warn':'ok',
      orphan ? orphan+' 个片名键指向不存在的影片' : '无悬挂键', orphan?'prune':null);

    const zero = ids.filter(id => !(movies.m[id][F.R]>0)).length;
    add('idx.zero','影片有片源', zero?'warn':'ok',
      zero ? zero+' 部影片片源数为 0' : '全部影片都有片源', zero?'prune':null);

    const missShard = [];
    const refYears = new Set();
    for (const id of ids) for (const y of (movies.m[id][F.YS]||[])) refYears.add(y);
    for (const y of refYears){
      const n = partCount(state, y);
      if (!n){ missShard.push(y); continue; }
      /* 只问元数据（head），不下载、不解析分片 —— 一个年份可能有几十片 */
      for (let i = 0; i < n; i++){
        const h = typeof env.R2.head === 'function' ? await env.R2.head(partKey(state, y, i)).catch(() => null) : await loadPart(env, state, y, i);
        if (!h){ missShard.push(y + '#' + i); break; }
      }
    }
    add('idx.shard','分片齐全', missShard.length?'fail':'ok',
      missShard.length ? '缺少分片：'+missShard.join(', ')
        : refYears.size+' 个年份 · '+BUILD_ORDER.reduce((a,y)=>a+partCount(state,y),0)+' 片在位',
      missShard.length?'resync':null);

    /* 超大分片 = 每轮任务都要整片解编，撞资源上限的直接原因 */
    const big = [];
    for (const y of BUILD_ORDER)
      for (const [i, n] of partRows(state, y).entries())
        if (n > PART_ROWS * 1.5) big.push(y+'#'+i+'('+n+' 行)');
    const bigYear = big.length ? big[0].split('#')[0] : null;
    add('idx.part','分片粒度', big.length?'warn':'ok',
      big.length ? '偏大的分片：'+big.slice(0,6).join(' ')
        +'　每轮任务都要整片解编，容易触发 Worker 资源上限，建议拆分'
        : '单片行数都在 '+PART_ROWS+' 以内，单轮开销恒定',
      big.length?'split':null, bigYear);

    const drift = Math.abs((state.movies||0) - ids.length);
    add('idx.count','计数一致', drift?'warn':'ok',
      drift ? 'state 记 '+(state.movies||0)+'，实际 '+ids.length : '一致', drift?'resync':null);

    const at = lockAt(state.lock), age = at ? Date.now()-at : 0;
    add('idx.lock','任务锁', !at ? 'ok' : (age>LOCK_MS?'warn':'ok'),
      !at ? '空闲' : (age>LOCK_MS ? '残留锁（'+Math.round(age/1000)+'s 前留下，下次任务会自动接管）' : '有任务在跑'),
      (at && age>LOCK_MS) ? 'unlock' : null);

    add('idx.deaths','任务中断计数', !(state.deaths||0) ? 'ok' : (state.deaths>=3?'warn':'ok'),
      !(state.deaths||0) ? '上一轮正常收尾'
        : '连续中断 '+state.deaths+' 次，已自动把每轮批量降到 1/'
          +Math.pow(2, Math.min(4,state.deaths))+'；跑完一轮会自动归零',
      (state.deaths>=3) ? 'resetTask' : null);

    const stuck = BUILD_ORDER.filter(y => (state.years?.[y]?.bad||[]).length);
    add('idx.pages','失败页队列', stuck.length?'warn':'ok',
      stuck.length ? stuck.map(y=>y+'('+state.years[y].bad.length+' 页)').join(' ')+'，下次任务优先重试'
                   : '没有待重试的页');

    /* 「N 个片名匹配不上」本身没有信息量 —— 得说清楚里面有多少根本不是电影、
       多少已经留底可以直接重试、多少是 v4 留下的、没有行的老账。 */
    const un = Object.keys(movies.u||{}).length;
    const pd = await pendLoad(env).catch(() => blankPend());
    const ps2 = pendStat(pd, new Set(Array.isArray(state.pdone) ? state.pdone : []));
    const legacy = Math.max(0, un - (ps2.n - ps2.wait));
    const bits = [];
    if (ps2.wait) bits.push('极限模式排队待认 '+ps2.wait+' 组（帖子行已留底，下次建索引或定时任务会认完）');
    if (ps2.retry) bits.push('可直接重试 '+ps2.retry+' 组（帖子行已留底，不用重爬）');
    if (ps2.tv || ps2.pack) bits.push('剧集 / 合集等非电影 '+(ps2.tv+ps2.pack)+' 组（跳过是对的）');
    if (ps2.dead) bits.push('试满 '+PEND.tries+' 次仍认不出 '+ps2.dead+' 组');
    if (legacy) bits.push('v4 老账 '+legacy+' 条（没留行，需重扫）');
    add('idx.unmatched','未匹配片名', ps2.retry ? 'warn' : (un ? 'ok' : 'ok'),
      (un || ps2.n) ? (un + ' 个片名没认出 TMDB · ' + (bits.join(' · ') || '暂无细分')
        + (ps2.sample.length ? ' · 例如：' + ps2.sample.slice(0,3).join(' / ') : ''))
        : '全部片名都已认下',
      ps2.retry ? 'retryUnmatched' : null);
    if (ps2.gchk >= 3 && ps2.garbled * 2 >= ps2.gchk)
      add('idx.garbled','片名乱码', 'fail',
        '留底队列里抽查 ' + ps2.gchk + ' 条，' + ps2.garbled + ' 条是乱码（版块页面是 UTF-8，旧版按 GBK 解了）。'
        + '新抓的页面已经按真实编码解码；存进去的乱码只能重建' + SRC.name + '索引（先自动备份）',
        'rebuildSource');
    if (legacy > 20)
      add('idx.unmatched.legacy','v4 老账未匹配', 'warn',
        legacy + ' 条是 v4 时期跳过的，当时没留下帖子行。倒回年份游标重走一遍列表页即可捡回来 —— '
        + '已入库的帖子会被 tid 表跳过，不会重复抓',
        'rescanUnmatched');

    /* 码本健康度：编码后平均长度掉到 30 以下才算健康 */
    const y0 = BUILD_ORDER.find(y => (state.relsByYear||{})[y]);
    if (y0){
      const sh = await loadPart(env, state, y0, Math.max(0, partCount(state, y0)-1));
      if (sh?.n?.length){
        const avg = sh.n.reduce((a,x)=>a+x.length,0)/sh.n.length;
        add('idx.codec','码本效率', avg>34?'warn':'ok',
          y0+' 年末片：'+sh.n.length+' 行 · 码本 '+sh.d.length+' 词元 · 平均 '+avg.toFixed(1)+' 字符/条',
          avg>34?'optimize':null, y0);
      }
    }
    const notMig = BUILD_ORDER.filter(y => !(state.migrated||{})[y] && !(state.relsByYear||{})[y]);
    if (notMig.length && await r2get(env, IDX.v3.movies, null).catch(()=>null))
      add('idx.migrate','v3 遗留数据','warn','还有 '+notMig.length+' 年没从 v3 迁过来','migrate');
  }

  const fails = checks.filter(c=>c.level==='fail').length;
  const warns = checks.filter(c=>c.level==='warn').length;
  return {
    at: Date.now(), fails, warns, ok: checks.length-fails-warns,
    verdict: fails ? '有故障，先修 fail 项' : warns ? '能跑，但有 '+warns+' 项建议处理' : '一切正常',
    gap: GOV.gap, cooling: Math.ceil(cool/1000),
    checks, recent: TRACE.slice(0, 20),
  };
}

async function repair(env, action, arg){
  if (action === 'unlock'){
    let had = false;
    await stateMutate(env, (st) => { had = !!lockAt(st.lock); if (!had) return false; delete st.lock; });
    dropCaches();
    return { ok:true, had };
  }
  /* 解锁 + 清降级计数：以前得人工点「强制解锁」再点「继续建立索引」，
     现在前端在卡死时会自己调这个。 */
  if (action === 'resetTask'){
    let was = 0;
    await stateMutate(env, (st) => { was = st.deaths || 0; if (!st.lock && !was) return false; delete st.lock; st.deaths = 0; });
    dropCaches();
    return { ok:true, deaths: was };
  }
  if (action === 'cooldown'){
    GOV.until = 0; GOV.strikes = 0; GOV.wins = 0; GOV.gap = 260; GOV.why = '';
    await stateMutate(env, (st) => { if (!st.cool) return false; delete st.cool; });
    dropCaches();
    return { ok:true, msg:'已清除限速冷却，请求间隔重置为 260ms' };
  }
  if (action === 'relogin'){ await dropSession(env); await session(env, true); return { ok:true }; }
  /**
   * [v6.4] 重建本源索引 —— 给「片名存成了乱码」用的（v6.3 及更早把 UTF-8 的版块当 GBK 解）。
   * 乱码已经写进了分片和留底队列，tid 表又会挡住重抓，只能整源清掉重来：
   * 先备份一份（体检里能「从备份恢复」），分片 / tid 表记进 grave（十分钟后删），影片表、留底队列清空，
   * 游标全部回到第 1 页。之后点「继续建立索引」（极限模式几分钟走完）。另一个源一点不动。
   */
  if (action === 'rebuildSource'){
    return withIndexLock(env, async (deaths, lk) => {
      const bk = await backupNow(env, true).catch(e => ({ err: e.message || String(e) }));
      if (bk && bk.err) throw new Error('重建前的备份没做成，先不动索引：' + bk.err);
      const { movies, state } = await loadForWrite(env);
      const n0 = Object.keys(movies.m).length, r0 = state.rels || 0;
      for (const k of liveKeys(state)) graveAdd(state, k);
      const st2 = { ...blankState(), grave: (state.grave || []).slice(-2000), bakAt: state.bakAt, bakDay: state.bakDay,
                    ver: state.ver || 0, migrated: state.migrated || {}, cool: state.cool };
      if (!st2.cool) delete st2.cool;
      const mv2 = blankMovies(); mv2.pv = PARSER_V;
      await commitIndex(env, lk, mv2, st2, { shrink: true, force: true });
      /* 留底队列在提交之后清：掐在两次写之间，旧队列还在，重建时会被新抓的覆盖掉 */
      await r2put(env, PEND.key, blankPend()).catch(e => trace('sys', '清留底队列失败（重建时会覆盖）：' + (e.message || e), { lvl: 'warn' }));
      dropCaches();
      trace('sys', '已重建 ' + SRC.name + ' 索引：清掉 ' + n0 + ' 部 / ' + r0 + ' 个片源（重建前已备份到 ' + (bk && bk.day || '') + '），游标回到第 1 页', { lvl: 'warn' });
      return { ok: true, dropped: n0, rels: r0, backup: bk && bk.day,
               msg: '已清空' + SRC.name + '索引（' + n0 + ' 部，重建前已备份），现在点「继续建立索引」重新抓 —— 这次按页面真实编码解码' };
    });
  }
  /* 备份 / 恢复：movies.json + state.json 每天备一份（cron 自动做），留最近 BAK_KEEP 份。
     恢复只恢复这两份 —— 它们引用的分片都是不可变对象，备份时在用的那一批十分钟内不会被删，
     更早的备份所引用的分片若已被清理，恢复后跑一遍「重算汇总」即可对齐。 */
  if (action === 'backup') return withIndexLock(env, async () => backupNow(env, true));
  if (action === 'restore') return withIndexLock(env, async (deaths, lk) => restoreBackup(env, lk, arg));
  /**
   * 重试匹配。
   * v4 只是把 movies.u 清空 —— 可那时候认不出来的帖子行早就丢了，
   * 清完标记也得把列表页重爬一遍才可能捡回来，所以 868 永远是 868。
   * v5 从留底队列里取，行就在手边：认下来直接写进当年的分片，不碰论坛。
   * 分批做，一批的大小按剩余子请求预算算，返回 left>0 就再调一次。
   */
  /**
   * [v6.4] 重试匹配（极限模式）：可重试的留底条目整批改成「排队待认」，交给浏览器的认定工并行认 ——
   * 以前一次调用认 10 组、一组一组磨，五千组要几百次调用。认不出的算一次重试（e.rq），满 PEND.tries 次进「反复认不出」。
   * 标题是乱码的不排（认了也白认，先「重建本源索引」）。
   */
  if (action === 'requeueUnmatched'){
    return withIndexLock(env, async (deaths, lk) => {
      const { state } = await loadForWrite(env);
      const pend = await pendLoad(env);
      pendSync(pend, state);
      let n = 0, garbled = 0;
      for (const k of Object.keys(pend.q)){
        const e = pend.q[k];
        if (PEND_SKIP.has(e.w) || e.w === 'wait' || (e.n || 0) >= PEND.tries) continue;
        if (mojibake(e.t)){ garbled++; continue; }
        e.w = 'wait'; e.rq = 1; n++;
      }
      await pendSave(env, pend, state);
      pdoneSet(state, new Set(), true);
      await commitIndex(env, lk, null, state);
      trace('match', '重试匹配：' + n + ' 组排进队列，交给认定工' + (garbled ? '（' + garbled + ' 组标题是乱码，没排）' : ''), { lvl: 'info' });
      return { ok: true, queued: n, garbled, msg: n + ' 组排进队列' + (garbled ? '，' + garbled + ' 组标题是乱码没排（先重建本源索引）' : '') };
    });
  }
  if (action === 'retryUnmatched'){
    return withIndexLock(env, async (deaths, lk) => {
      const t0 = Date.now();
      const [{ movies, state, m0 }, pend] = await Promise.all([ loadForWrite(env), pendLoad(env) ]);
      parserMigrate(movies, pend);          // 解析器变了就把重试次数归零，别把老账判死
      pendSync(pend, state);                // 已经写进分片、只是还没从队列里删的，不再认一遍（state.pdone 留着，下一轮建索引会清）
      const live = Object.keys(pend.q).filter(k =>
        !PEND_SKIP.has(pend.q[k].w) && (pend.q[k].n||0) < PEND.tries);

      if (!live.length){
        const legacy = Object.keys(movies.u).length;
        const st = pendStat(pend); state.pend = st;
        await commitIndex(env, lk, null, state);
        return { ok:true, done:true, left:0, fixed:0, legacy, ...st,
          msg: legacy
            ? '留底队列里没有可重试的了。另有 ' + legacy + ' 条是 v4 时期的老账 —— '
              + '那会儿认不出来的帖子行没有留底，只能用「重扫未匹配」把年份游标倒回去，'
              + '重走一遍列表页才捡得回来。'
            : '没有需要重试的条目' };
      }

      /* 同一年的排在一起：一次调用只解一年的分片，编码量才是常数 */
      live.sort((a, b) => (pend.q[b].y||0) - (pend.q[a].y||0));
      const room = Math.max(1, Math.min(PEND.batch, Math.floor((subLeft() - 12) / 2)));
      const y0 = pend.q[live[0]].y;
      const take = live.filter(k => pend.q[k].y === y0).slice(0, room);
      /* [v5.2 修复 4] 留底里的 cn / latin 是当初那个解析器切出来的 ——
         照抄一遍等于把同样的错再犯一次。拿原始标题用新解析器重切，
         切不出来才退回旧值；顺手把新键也记下来，认回来之后一并写进
         movies.k，下一轮建索引就能直接命中缓存，不用再认一次。 */
      const groups = take.map(k => pendGroup(k, pend.q[k]));

      let res;
      try { res = await matchBatch(env, groups); }
      catch (e){
        if (!e.budget) throw e;
        const st = pendStat(pend); state.pend = st;
        await commitIndex(env, lk, null, state);
        return { ok:true, left: st.retry, fixed:0, budget:1, ...st,
          msg:'本轮子请求预算用尽，进度已保存，继续调用即可' };
      }

      await graveSweep(env, state);
      const ps = partSet(env, state);
      let fixed = 0, rows = 0, still = 0, net = 0;
      const won = [];
      for (const g of groups){
        const e = pend.q[g.key], r = res.get(g.key);
        if (r == null){ net++; continue; }                    // 网络失败：原样留着
        if (r.miss){ e.n = (e.n||0) + 1; e.w = r.why || 'nohit'; if (e.r.length > PEND.rows) e.r = e.r.slice(0, PEND.rows); still++; continue; }
        const id = r.hit.id;
        movies.k[g.key] = id;
        if (g.nkey && g.nkey !== g.key) movies.k[g.nkey] = id;
        if (!movies.m[id]) movies.m[id] = newMovie(r.hit, e.y);
        for (const [yy, rr] of pendRowsByYear(e)) rows += await ps.push(yy, movies, id, rr);
        delete pend.q[g.key]; delete movies.u[g.key];
        if (g.nkey) delete movies.u[g.nkey];
        if (won.length < 5) won.push((r.hit.title || e.t || '').slice(0, 26) + '←' + (r.via||''));
        fixed++;
      }
      await ps.flush();
      state.movies = Object.keys(movies.m).length;
      state.deaths = 0;
      const st = pendStat(pend); state.pend = st;
      await commitIndex(env, lk, movies, state, { m0 });
      /* 留底队列里删掉的是「已经认回来、写进分片」的条目 —— 必须在提交之后再写，
         否则掐在中间，这些帖子既不在队列里、也不在索引里 */
      await pendSave(env, pend, null).catch(e => trace('sys', '留底队列写回失败（下次重试会再认一遍，不丢）：' + (e.message || e), { lvl:'warn' }));
      trace('match', '重试匹配：认回 ' + fixed + ' 部 / ' + rows + ' 个片源，仍认不出 ' + still +
        '，还剩 ' + st.retry, { lvl: 'info' });
      const spent2 = Date.now() - t0;
      return { ok:true, year:y0, tried: groups.length, fixed, rows, still, net,
        left: st.retry, ...st, sub: SUB.n, ms: spent2,
        wait: Math.max(0, 1200 - spent2),
        msg: y0 + ' 年 · 认回 ' + fixed + ' 部（' + rows + ' 个片源）· 仍认不出 ' + still +
             (net ? ' · 网络失败 ' + net : '') + ' · 还剩 ' + st.retry +
             (won.length ? ' · 例如 ' + won.join('、') : '') };
    });
  }
  /**
   * 重扫未匹配 —— 专门收拾 v4 留下的老账。
   * 那时候认不出来的帖子行没有留底，只能把年份游标倒回第 1 页重走一遍。
   * 重走不贵：已经入库的 tid 会被 tid 表原地跳过，只有当初被跳过的那些
   * 才会真的去认一次，而且这次用的是 v5 的多策略认定。
   */
  if (action === 'rescanUnmatched'){
    return withIndexLock(env, async (deaths, lk) => {
      const { movies, state, m0 } = await loadForWrite(env);
      const n = Object.keys(movies.u||{}).length;
      movies.u = {};
      let ys = 0;
      for (const y of BUILD_ORDER){
        const st = state.years?.[y];
        if (!st) continue;
        if (st.done || (st.page||1) > 1){ st.page = 1; st.done = false; ys++; }
      }
      await commitIndex(env, lk, movies, state, { m0 });
      return { ok:true, cleared:n, years:ys,
        msg: '已清掉 ' + n + ' 条跳过标记，并把 ' + ys + ' 个年份的游标倒回第 1 页。'
           + '现在点「继续建立索引」会重走一遍列表页 —— 已入库的帖子由 tid 表直接跳过，'
           + '只补当初认不出来的那些，这次用的是新的多策略认定。' };
    });
  }
  /**
   * 重算汇总 / 清理孤儿。
   * v4.0 是"遍历所有影片 × 解开所有年份分片"，索引一大就必然超资源上限
   * —— 修复动作自己变成故障源。v4.1 改成按分片分批：一次只解几片，
   * 游标存在 state 里，返回 left>0 就再调一次。
   */
  if (action === 'prune' || action === 'resync'){
    return withIndexLock(env, async (deaths, lk) => {
      const { movies, state, m0 } = await loadForWrite(env);

      const list = [];
      for (const y of BUILD_ORDER)
        for (let i = 0; i < partCount(state, y); i++) list.push([y, i]);

      const cur = state.resync && state.resync.act === action ? state.resync : null;
      let at = cur ? cur.at : 0;
      const pnBy = cur ? cur.pn : {};
      if (!at){                                  // 第一批：先清零，再从头扫
        for (const id of Object.keys(movies.m)){
          const mv = movies.m[id];
          mv[F.R] = 0; mv[F.B] = 0; mv[F.BM] = 0;
          mv[F.Q] = null; mv[F.BT] = null; mv[F.Z] = null;
          mv[F.SP] = {}; mv[F.YS] = [];
          mv[F.HB] = 0; mv[F.RB] = 0;
        }
      }

      const t0 = Date.now();
      let scanned = 0;
      while (at < list.length && Date.now() - t0 < 8000){
        const [y, pi] = list[at];
        let sh = null;
        try { sh = await r2get(env, partKey(state, y, pi), null); }
        catch (e){ if (!e.corrupt) throw e; trace('sys', y + ' 年第 ' + pi + ' 片损坏，重算时跳过', { lvl:'err' }); }
        const g = sh ? decodeShard(sh) : {};
        let rows = 0;
        for (const id of Object.keys(g)){
          rows += g[id].length;
          const mv = movies.m[id];
          if (!mv) continue;
          markPart(mv, y, pi);
          const ys = mv[F.YS] || (mv[F.YS] = []);
          if (!ys.includes(y)) ys.push(y);
          mv[F.R] = (mv[F.R]||0) + g[id].length;
          for (const r of g[id]){ bumpBest(mv, r); bumpSpec(mv, r); }
        }
        (pnBy[y] = pnBy[y] || [])[pi] = rows;
        at++; scanned++;
      }

      const done = at >= list.length;
      let dropped = 0, keys = 0;
      if (done){
        for (const y of Object.keys(pnBy)){
          const pn = pnBy[y].map(n => n||0);
          const yst = ystOf(state, y);
          yst.pg = pn.map((_, i) => pgOf(state, y, i));
          yst.pn = pn;
          (state.relsByYear = state.relsByYear||{})[y] = pn.reduce((a,x)=>a+x,0);
        }
        for (const y of BUILD_ORDER) if (!pnBy[y]) (state.relsByYear = state.relsByYear||{})[y] = 0;
        if (action === 'prune'){
          for (const id of Object.keys(movies.m))
            if (!(movies.m[id][F.R] > 0)){ delete movies.m[id]; dropped++; }
        }
        for (const k of Object.keys(movies.k)) if (!movies.m[movies.k[k]]){ delete movies.k[k]; keys++; }
        state.rels = Object.values(state.relsByYear||{}).reduce((a,x)=>a+x,0);
        delete state.resync;
        delete state.heal;                       // 计数已经按分片重算过，对齐了
      } else {
        state.resync = { act: action, at, pn: pnBy };
      }
      state.movies = Object.keys(movies.m).length;
      state.deaths = 0;
      movieKeysFill(movies);
      await commitIndex(env, lk, movies, state, { m0, shrink: action === 'prune' });
      return { ok:true, done, scanned, left: Math.max(0, list.length - at),
        dropped, keys, movies: state.movies, rels: state.rels,
        msg: done ? '已重算 '+list.length+' 片' : '已扫 '+at+'/'+list.length+' 片，继续调用即可' };
    });
  }
  if (action === 'split'){
    if (!arg) throw new Error('缺少 year');
    return splitYear(env, arg);
  }
  if (action === 'optimize') return optimizeYear(env, arg || BUILD_ORDER[0], null);
  if (action === 'migrate')  return migrateYear(env, arg || null);
  if (action === 'resetYear'){
    if (!arg) throw new Error('缺少 year');
    return resetYear(env, arg);
  }
  throw new Error('未知修复动作：'+action);
}

/* ══════════════════════════════════════════════════════════════════
   片库对照 v5 —— 先认 TMDB，再比 id
   ──────────────────────────────────────────────────────────────────
   速查是用来"找还没有的片"的，库里已经躺着的应该直接消失。
   v4 的做法是把文件名归一化成「片名|年份」，再拿索引里的中文名 / 原名
   去撞。碰上译名不同、带副标题、发布组把片名写成 "Dune.Part.Two" 这类，
   要么漏、要么误伤。
   v5 换成两段式：
     ① 扫描 —— 拉一次 /api/all，把文件名 / 带年份的目录名切成候选，去重。
     ② 认定 —— 每个候选送 TMDB 认一次，把认下来的「TMDB id + 片名 + 年份」
        抄进 A/list.json。索引本身就是以 TMDB id 为主键的，于是比对退化成
        一次整数 Set 查询：既准（id 相等，没有误伤）又快（不做字符串归一）。
   认不出来的落进 weak（有年份）/ loose（没年份）当兜底，界面上区分
   「库中已有」与「疑似已有」。每个候选的认定结果进 KV 缓存 30 天，
   第二次同步几乎不花子请求。
   认定是分批的：一批用掉多少子请求由预算决定，剩下的写回 todo，
   下一次调用接着认 —— 所以片库再大也不会撞平台的硬线。
   ══════════════════════════════════════════════════════════════════ */

/* 文件名里的集数 / 分盘噪声：先削掉，parseTitle 才能干净地切出片名 */
const LIB_NOISE = /\b(?:S\d{1,2}E\d{1,3}|Season\s?\d{1,2}|CD\d|Disc\s?\d|Part\s?\d(?=\s*$))\b/ig;
const LIB_EXT   = /\.(?:mp4|mkv|webm|mov|avi|m4v|ts|m2ts|iso|rmvb|wmv|flv|mpe?g)$/i;
/* 一片一目录时文件常叫 movie.mkv / 正片.mkv —— 这种名字不能拿去认，
   更不能进"只按片名认"的宽键集合，否则会误伤一大票同名影片 */
const LIB_GENERIC = new Set(['movie','video','film','main','index','output','untitled',
  'sample','disc','bdmv','playlist','fullmovie','影片','视频','正片','未命名','电影']);

/** 一个文件名 / 目录名 → 一个候选 { k, cn, latin, ys } */
function libCand(raw){
  const n = String(raw || '').replace(LIB_EXT, '').replace(LIB_NOISE, ' ')
    .replace(/[_]+/g, ' ').replace(/\s+/g, ' ').trim();
  if (!n) return null;
  const pt = parseTitle(n);
  const cn = pt.cn || '', latin = pt.latin || '';
  const nk = norm(cn) || norm(latin);
  if (!nk || nk.length < 2 || LIB_GENERIC.has(nk)) return null;
  const ys = (pt.years || []).filter(y => +y >= 1900 && +y <= 2100).map(String);
  return { k: nk + '|' + (ys[0] || ''), cn, latin, ys, nk, nk2: candAlt(nk, latin) };
}
/* 原名要单独留一条键。索引那边比对时中文名和原名都会拿来撞，片库这边
   只留一个（有中文名就把原名扔了），于是「沙丘2」对不上「沙丘：第二部」
   的时候，明明两边的 Dune Part Two 一模一样，也照样判成缺片。 */
function candAlt(nk, latin){
  const a = norm(latin);
  return (a && a !== nk && a.length >= 2 && !LIB_GENERIC.has(a)) ? a : '';
}
/* 一个候选贡献的全部模糊键。有年份的进 weak（片名 + 年份，安全），
   没年份的才进 loose（只按片名，宽） */
function candKeys(c, weak, loose){
  for (const k of [c.nk, c.nk2]){
    if (!k) continue;
    if (c.ys.length) for (const y of c.ys) weak.add(k + '|' + y);
    else loose.add(k);
  }
}
/* 候选在 R2 里压成定长数组，省掉一整份键名 */
const candPack = (c) => [c.k, c.cn, c.latin, c.ys.join(',')];
const candOpen = (a) => { const nk = String(a[0]).split('|')[0];
  return { k:a[0], cn:a[1], latin:a[2],
    ys: a[3] ? String(a[3]).split(',').filter(Boolean) : [], nk, nk2: candAlt(nk, a[2]) }; };

/** /api/all 响应 → 去重后的候选表 */
function libScan(payload){
  const map = new Map();
  const vids = Array.isArray(payload.videos) ? payload.videos : [];
  const rootLen = String(payload.root || '').length;
  for (const v of vids){
    /* 一片一目录、且目录名带年份时，目录名比文件名可靠得多（文件名往往是
       发布组的整串规格）—— 优先用目录名，认不出来再退回文件名 */
    const seg = String(v.path || '').slice(rootLen).split('/').filter(Boolean);
    seg.pop();
    const dir = seg[seg.length - 1];
    const dated = !!(dir && /(?:19|20)\d{2}/.test(dir));
    const cd = dated ? libCand(dir) : null;
    const cf = libCand(v.name);
    /* 目录名更干净（文件名往往是发布组的整串规格），但原名通常只写在
       文件名里。两个都要：目录名定片名，文件名补原名和年份。 */
    let c = cd || cf;
    if (cd && cf){
      if (!cd.latin && cf.latin){
        c = { ...cd, latin: cf.latin, nk2: candAlt(cd.nk, cf.latin) };
      }
      if (!c.ys.length && cf.ys.length) c = { ...c, ys: cf.ys, k: c.nk + '|' + cf.ys[0] };
    }
    if (!c) continue;
    if (!map.has(c.k)) map.set(c.k, c);
    if (map.size >= LIB.cap) break;
  }
  return { files: vids.length, cands: [...map.values()] };
}

async function libFetch(env, tries){
  const b = String(env.STREAM_BASE || '').replace(/\/+$/, '');
  if (!b) throw new Error('未配置 STREAM_BASE，片库对照未开启');
  const r = await autoRetry('lib ' + b, async () => {
    const x = await sfetch(b + '/api/all?depth=5', {
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(8000),
    });
    if (x.status === 401 || x.status === 403)
      throw new Error('片库拒绝访问 HTTP ' + x.status + '：Stream 设了 AUTH_SECRET —— 给索引库配 STREAM_KEY（同一个口令），或配 RECV_BASE（Stream 的 R2 桶的公开域名）');
    if (!x.ok) throw new Error('HTTP ' + x.status);
    return x;
  }, { tries: tries || 2, gap: 700 });
  const j = await r.json().catch(() => null);
  if (!j || !Array.isArray(j.videos)) throw new Error('片库响应不是预期的 JSON（/api/all）');
  return j;
}

/* ══════════════════════════════════════════════════════════════════
   总账直读 —— Received.json（Stream v22 起）        【v5.4】
   ──────────────────────────────────────────────────────────────────
   上面那套「扫描 → 认定」是在 Stream 只提供 /api/all（一串文件名）的
   前提下写的：文件名切片名、片名送 TMDB、认下来记 id。整条链路真正
   花钱的是中间那一步 —— 一个上千部的片库要上千次 TMDB 搜索，只能靠
   todo 队列一批批磨，磨完要好几轮 cron。

   Stream v22 之后这一步在它那边已经做完了：Received.json 里每一条
   自带 tmdb 编号。于是这里退化成「取回来、按源分拣、抄 id」——
   零 TMDB 请求，一次调用做完，todo 队列直接空着。

   ★ 顺带修掉一个一直存在的错配
     老管线不分源，两个源都去拉 /api/all —— 那是电影目录。剧集源于是
     拿电影文件名去 TMDB 搜剧，认出来的 id 属于另一套编号，比对结果
     基本是噪声。总账里电影和剧集在同一份里、各自带 type，按 type 分拣
     之后剧集源才第一次真的比到了剧集库。

   ★ 认不出来的仍然走模糊兜底
     总账里 state=9（TMDB 确实没有）的那些，这里照旧按片名 + 年份建
     weak / loose 键 —— libHas 先比 id，比不中才看这里，行为一字未改。

   ★ gen 没变就不下正文
     先问 120 字节的指针；gen 与上一份成品相同就什么都不做。
     片库一天不动，这条链路一天只花两个子请求。

   变量
     RECV_BASE   公开 R2 自定义域（如 https://data.cuven.online）。
                 首选 —— 它绕开 Stream 的 AUTH_SECRET，不必配任何口令。
     不配就退回 STREAM_BASE + /api/received（需要 Stream 那边放行）；
     两条都拿不到（后端还没升到 v22 → 404）就自动落回老管线，行为如旧。
   ══════════════════════════════════════════════════════════════════ */

function recvBase(env){
  const r = String(env.RECV_BASE || '').replace(/\/+$/, '');
  if (r) return { doc: r + '/Received.json', meta: r + '/Received.meta.json', via: 'r2', host: r };
  const b = String(env.STREAM_BASE || '').replace(/\/+$/, '');
  if (b) return { doc: b + '/api/received', meta: b + '/api/received/meta', via: 'worker', host: b };
  return null;
}

/** 取总账的一份。404 = 后端还没升到 v22 → 回 null，调用方落回老管线 */
async function recvGet(env, which, timeout){
  const u = recvBase(env);
  if (!u) return null;
  const x = await sfetch(u[which], {
    headers: { accept: 'application/json' },
    signal: AbortSignal.timeout(timeout || 10000),
  });
  if (x.status === 404 || x.status === 503){ try { await x.body?.cancel(); } catch {} return null; }
  if (x.status === 401 || x.status === 403)
    throw new Error('总账拒绝访问 HTTP ' + x.status +
      '（把 RECV_BASE 指到公开 R2 域名，或让 Stream 放行 /api/received）');
  if (!x.ok) throw new Error('HTTP ' + x.status);
  return x.json().catch(() => null);
}

/**
 * 总账 → 本源的成品（v7）。一次 TMDB 请求都不发 —— Stream 那边已经认过了。
 *
 * v6 在这里犯了两个让「缺片」判不准的错：
 *   · 认下来的条目也照样建模糊键（片名 + 年份 ±1、没年份的只按片名）——
 *     库里有「惊变 2023」（id 对得上），索引里另一部「惊变 2024」就被当成已有藏掉了；
 *     一个没年份的「Dune.mkv」能把 1984 和 2021 两部《沙丘》一起藏掉。
 *   · Stream 偶尔会把文件认错成年份差几十年的另一部片，v6 照单全收：
 *     认错的那个 id 被当成「确定已有」，真正那部反而显示缺片。
 * v7 把库里的条目分成三类，比对时各走各的（见 libOwn）：
 *   ids  —— 可信的 TMDB id（类型对、TMDB 年份和文件名年份对得上），精确比对；
 *   idn  —— 同一批条目的片名 + 年份，只在「索引里根本没有这个 id」时才拿来查
 *           是不是两边把同一部片认成了不同的 id；
 *   fz   —— 没有可信 id 的条目（没认出来、或者 id 被判为认错）：按文件名猜出来的
 *           片名 + 年份，一个条目最多认领索引里的一部片。
 */
/**
 * 总账里的一条 → 分类（v6.3 拆出来：实时清单模式也要拿总账当提示表）。
 * 返回 null（不是这个源的）或
 *   { id, title, y, idn: [id, names, year, keys] | null }        可信 id
 *   { fz: [names, year, season, keys], distrust: 0 | 1 }          没有可信 id
 */
function recvClassify(it, kind){
  if (!it || typeof it !== 'object') return null;
  const str = (v) => (typeof v === 'string' || typeof v === 'number') ? String(v).trim().slice(0, 160) : '';
  const uniq = (arr) => { const o = []; for (const v of arr){ const t = str(v); if (t && !o.includes(t)) o.push(t); } return o; };
  const tm = Number(it.tmdb) > 0 ? Math.floor(Number(it.tmdb)) : 0;
  /* TMDB 的 movie id 与 tv id 是两套编号：认下来的按 type 分拣，没认下来的按目录形态猜 */
  const ty = (tm && (it.type === 'tv' || it.type === 'movie')) ? it.type
           : (it.kind === 'series' ? 'tv' : 'movie');
  if (ty !== kind) return null;
  const ty0 = yearOf(it.year), gy = yearOf(it.guessYear);
  /* 可信度（与前端 trusted() 同一口径）：TMDB 年份与文件名年份差得离谱 → id 多半认错了。
     剧集的目录年份是「这一季」的，可以晚于首播，不能早于首播一年以上 */
  let trust = !!tm;
  if (tm && ty0 && gy){
    if (kind === 'movie' && Math.abs(ty0 - gy) > 1) trust = false;
    if (kind === 'tv' && gy < ty0 - 1) trust = false;
  }
  /* 名字全对不上也不可信：文件名里的中文名、英文名，和那个 id 的中文名、原名两两都不沾边。
     只差一边（港台译名、文件名里只有英文名）不算 —— Stream 的认定大多数是对的，不能因为译名不同就推翻 */
  if (trust && tm && (it.guessZh || it.guessEn)){
    const gk = keySplit(canonKeys([it.guess, it.guessZh, it.guessEn])), tk = keySplit(canonKeys([it.title, it.orig]));
    if (gk.cjk.length && tk.cjk.length && gk.lat.length && tk.lat.length && nameClash(gk, tk)
        && !gk.keys.some(k => tk.keys.includes(k))) trust = false;
  }
  if (trust){
    const nm = uniq([it.title, it.orig]);
    const kk = canonKeys(nm);
    return { id: tm, title: str(it.title || it.guess), y: String(ty0 || gy || ''), idn: kk.length ? [tm, nm, ty0 || 0, kk] : null };
  }
  /* 认错的条目：title / orig / year 都是那个错 id 的，只能信文件名猜出来的那几样 */
  const nm = tm ? uniq([it.guess, it.guessZh, it.guessEn]) : uniq([it.title, it.orig, it.guess, it.guessZh, it.guessEn]);
  return { fz: [nm, tm ? gy : (gy || ty0), Number(it.season) || 0, canonKeys(nm)], distrust: tm ? 1 : 0 };
}
function recvBuild(doc){
  const kind = SRC.kind;                        // movie / tv
  const items = Array.isArray(doc.items) ? doc.items : [];
  const ids = [], dedup = new Set(), idn = [], idnSeen = new Set(), fz = [];
  let files = 0, mine = 0, missed = 0, distrust = 0;
  for (const it of items){
    if (!it || typeof it !== 'object') continue;
    /* 「文件数」按剧集展开：一部 12 集的剧在片库里就是 12 个文件 */
    files += (it.kind === 'series') ? (Math.max(1, Number(it.episodes) || 1)) : 1;
    const c = recvClassify(it, kind);
    if (!c) continue;
    mine++;
    if (c.id){
      if (!dedup.has(c.id)){ dedup.add(c.id); ids.push([c.id, c.title, c.y, '']); }
      if (c.idn && !idnSeen.has(c.id)){ idnSeen.add(c.id); idn.push(c.idn); }
      continue;
    }
    if (c.distrust) distrust++;
    missed++;
    if (c.fz[3].length) fz.push(c.fz);
  }
  return { ids, idn, fz, files, mine, missed, distrust };
}

/**
 * 同步一次总账。
 * force=false 且 gen 与上一份成品相同 → 什么都不做（两个子请求，不写 R2）。
 * 后端没有总账（404）或总账还是空的（正在建）→ 回 null，调用方落回老管线。
 */
async function libSyncRecv(env, force){
  const meta = await recvGet(env, 'meta', 6000);
  if (!meta || !meta.gen) return null;

  const cur = await libDoc(env);
  if (!force && cur.v === 7 && cur.cv === CANON_V && cur.gen === meta.gen){
    /* 未变更不写 R2 —— 一份成品十几万字节，为一个时间戳重写不划算。
       新鲜度由调用方在内存里补（见 libRefresh）。 */
    return { mode:'received', unchanged:1, gen: meta.gen, files: cur.files || 0,
             cands: cur.mine || 0, ids: (cur.ids || []).length,
             missed: cur.missed || 0, left: 0, done: true };
  }

  const doc = await recvGet(env, 'doc', 25000);
  if (!doc || !Array.isArray(doc.items)) throw new Error('总账响应不是预期的 JSON（Received.json）');
  /* 总账刚建、还没有任何条目：不能拿它去盖掉一份能用的老成品 */
  if (!doc.items.length) return null;

  const b = recvBuild(doc);
  const out = {
    v: 7, cv: CANON_V, src: 'received', gen: meta.gen, via: recvBase(env).via,
    recvTs: doc.ts || 0, recvCount: doc.count || doc.items.length,
    pending: doc.pending || 0, unmatched: doc.unmatched || 0,
    scan: Date.now(), at: Date.now(),
    files: b.files, mine: b.mine, missed: b.missed, distrust: b.distrust,
    ids: b.ids, idn: b.idn, fz: b.fz,
    weak: [], loose: [], miss: [], seen: [], todo: [],   // 认定队列在这条路上永远是空的
  };
  await r2put(env, LIB.list, out);
  libMem = null;
  trace('lib', '总账同步：片库 ' + b.files + ' 个文件 → 本源 ' + b.mine + ' 部（' +
    b.ids.length + ' 部带可信 TMDB id' +
    (b.missed ? '，' + b.missed + ' 部没有可信 id（按片名 + 年份比）' : '') +
    (b.distrust ? '，其中 ' + b.distrust + ' 部的 id 与文件名年份对不上、判为认错' : '') + '）· gen=' + meta.gen,
    { lvl: 'info' });
  return { mode:'received', gen: meta.gen, files: b.files, cands: b.mine,
           ids: b.ids.length, missed: b.missed, left: 0, done: true };
}

/* ══════════════════════════════════════════════════════════════════
   [v6.3] 实时片库清单（Stream v25）
   ──────────────────────────────────────────────────────────────────
   Received.json 是 Stream v22 写的；v25 不再写它（v25 的前端也写着「后端没有总账」）。
   R2 里那份是停在 v22 的快照，之后进库的片都不在里面 —— 于是一直被判成缺片。
   v25 自己在同一个 R2 桶里维护着实时清单：
     · lib-ptr.json        库快照指纹 g（几十字节）：没变就不下正文
     · file-list-v2.json   电影目录下的全部视频文件（Dropbox 增量同步，十分钟级新鲜）
     · tv/list-v1.json     剧集表，每部带 v25 匹配管线认好的 tmdbId
   现在以实时清单为准（哪些文件在库里），总账只当「文件 → TMDB id」的提示表：
     电影：① 总账里同一个文件的可信 id；② 索引自己的片名键（文件名多半就是论坛的发布名，
          与建索引同一套切片，查目录时直接查 movies.k，零 TMDB 请求，要求年份对得上）；
          ③ 以前认过的结果；④ 都没有就排队用 TMDB 认（libResolveStep），认出来之前先按片名 + 年份认领；
     剧集：v25 剧集表自带的 tmdbId；没有的按片名 + 季 + 年份认领。
   清单拿不到（桶没挂公开域名）时，STREAM_BASE + STREAM_KEY（= Stream 的 AUTH_SECRET）走 /api/all、/api/tv；
   都拿不到才退回总账，片库面板上会写明总账停在哪天。
   CPU：切片名一个文件 ~15µs —— 每个文件只在第一次见到时切（结果存在成品里），
   一次同步最多新切 LIVE_PARSE_MAX 个，剩下的下次接着切（part > 0）。
   ══════════════════════════════════════════════════════════════════ */
let LIVE_PARSE_MAX = 800;      // let：测试里会临时调小
const LIVE_TTL = 5 * 60_000;    // 实时清单模式下片库成品的新鲜期（各 isolate 各自五分钟回一次 R2 / Stream）
const liveRoot = (env) => String(env.RECV_BASE || '').replace(/\/+$/, '');
const streamRoot = (env) => String(env.STREAM_BASE || '').replace(/\/+$/, '');
const liveOn = (env) => !!(liveRoot(env) || streamRoot(env));
const h32 = (s) => { let h = 2166136261; for (let i = 0; i < s.length; i++){ h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(36); };

/** 公开 R2 桶里 Stream v25 写的一个 JSON。404 / 拒绝访问 = 没有这个对象或桶没挂公开域名 → null */
async function liveGet(env, path, timeout){
  const b = liveRoot(env);
  if (!b) return null;
  const x = await sfetch(b + '/' + path, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(timeout || 15000) });
  if (!x.ok){
    try { await x.body?.cancel(); } catch {}
    if (x.status === 404 || x.status === 401 || x.status === 403) return null;
    throw new Error(path + ' HTTP ' + x.status);
  }
  return x.json().catch(() => null);
}

/* Stream 的接口在登录门后面（AUTH_SECRET）：STREAM_KEY 填同一个口令，POST /auth 换会话 cookie。
   cookie 在 isolate 里留一小时、KV 里留六小时；被拒就重登一次 */
let STREAM_CK = null;
async function streamCookie(env, fresh){
  const b = streamRoot(env);
  if (!b || !env.STREAM_KEY) return '';
  if (!fresh && STREAM_CK && STREAM_CK.exp > Date.now()) return STREAM_CK.v;
  if (!fresh){
    const hit = await jget(env, 'stream-ck').catch(() => null);
    if (hit && hit.v){ STREAM_CK = { v: hit.v, exp: Date.now() + 3600e3 }; return hit.v; }
  }
  const r = await sfetch(b + '/auth', { method: 'POST', redirect: 'manual',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: 'key=' + encodeURIComponent(String(env.STREAM_KEY)) + '&to=%2F', signal: AbortSignal.timeout(10000) });
  try { await r.body?.cancel(); } catch {}
  const jar = setCookies(r);
  if (!jar.auth) throw new Error('Stream 登录失败（HTTP ' + r.status + '）—— STREAM_KEY 要填 Stream 的 AUTH_SECRET');
  const v = 'auth=' + jar.auth;
  STREAM_CK = { v, exp: Date.now() + 3600e3 };
  await jput(env, 'stream-ck', { v }, 6 * 3600).catch(() => {});
  return v;
}
/** Stream 的一个接口。没配 STREAM_BASE、或者拒绝访问（没配 STREAM_KEY / 口令不对）→ null */
async function streamApi(env, path){
  const b = streamRoot(env);
  if (!b) return null;
  for (let i = 0; i < 2; i++){
    const ck = await streamCookie(env, i > 0);
    const x = await sfetch(b + path, { redirect: 'manual', signal: AbortSignal.timeout(20000),
      headers: { accept: 'application/json', ...(ck ? { cookie: ck } : {}) } });
    if (x.status === 401 || x.status === 403 || (x.status >= 300 && x.status < 400)){
      try { await x.body?.cancel(); } catch {}
      if (!env.STREAM_KEY) return null;
      STREAM_CK = null;
      continue;
    }
    if (!x.ok){ try { await x.body?.cancel(); } catch {} throw new Error('Stream ' + path + ' HTTP ' + x.status); }
    return x.json().catch(() => null);
  }
  return null;
}

/** 电影的实时清单。返回 { gen, videos, root, ts, via } / { unchanged } / null（两条路都拿不到） */
async function liveMovies(env, prev){
  const keep = prev && prev.gen && !prev.part;
  if (liveRoot(env)){
    const ptr = await liveGet(env, 'lib-ptr.json', 6000).catch(() => null);
    if (ptr && ptr.g && keep && prev.gen === String(ptr.g)) return { gen: String(ptr.g), unchanged: 1, via: 'r2' };
    const d = await liveGet(env, 'file-list-v2.json', 25000)
      .catch(e => { trace('lib', '实时清单 file-list-v2.json 取不到：' + (e.message || e), { lvl: 'warn' }); return null; });
    if (d && Array.isArray(d.videos) && d.videos.length)
      return { gen: String(d._gen || (ptr && ptr.g) || ('t' + (d._ts || 0))), videos: d.videos, root: String(d.root || ''), ts: d._ts || 0, via: 'r2' };
  }
  if (!streamRoot(env)) return null;
  const g = await streamApi(env, '/api/gen').catch(() => null);
  if (g && g.gen && keep && prev.gen === String(g.gen)) return { gen: String(g.gen), unchanged: 1, via: 'stream' };
  const j = await streamApi(env, '/api/all?depth=5')
    .catch(e => { trace('lib', 'Stream /api/all 取不到：' + (e.message || e), { lvl: 'warn' }); return null; });
  if (j && Array.isArray(j.videos) && j.videos.length)
    return { gen: String((g && g.gen) || ('a' + h32(j.videos.map(v => v && v.path).join('\n')))),
             videos: j.videos, root: String(j.root || ''), ts: (g && g.ts) || Date.now(), via: 'stream' };
  return null;
}
/** 剧集的实时清单（剧集表不大，也没有单独的指纹，按 at + 部数判断变没变） */
async function liveTv(env, prev){
  let d = null, via = 'r2';
  if (liveRoot(env)) d = await liveGet(env, 'tv/list-v1.json', 20000).catch(() => null);
  if (!d || !Array.isArray(d.series) || !d.series.length){ d = await streamApi(env, '/api/tv').catch(() => null); via = 'stream'; }
  if (!d || !Array.isArray(d.series) || !d.series.length) return null;
  const gen = 'tv' + (d.at || 0) + '.' + d.series.length;
  if (prev && prev.gen === gen && !prev.part) return { gen, unchanged: 1, via };
  return { gen, series: d.series, ts: d.at || 0, via };
}

/** 一个视频文件 → 候选（片名 / 原名 / 年份 / 比对键 / 索引片名键）。同 libScan：目录名带年份时目录名定片名、文件名补原名 */
function liveCand(v, rootLen){
  const seg = String(v.path || '').slice(rootLen).split('/').filter(Boolean);
  seg.pop();
  const dir = seg[seg.length - 1];
  const dated = !!(dir && /(?:19|20)\d{2}/.test(dir));
  const cd = dated ? libCand(dir) : null;
  const cf = libCand(v.name);
  let c = cd || cf;
  if (cd && cf){
    if (!cd.latin && cf.latin) c = { ...cd, latin: cf.latin, nk2: candAlt(cd.nk, cf.latin) };
    if (!c.ys.length && cf.ys.length) c = { ...c, ys: cf.ys, k: c.nk + '|' + cf.ys[0] };
  }
  if (!c) return null;
  /* 索引片名键：与建索引时 groupKey 同一套切法。文件名多半就是论坛的发布名，切出来的键能直接在 movies.k 里查到 */
  const gks = [];
  for (const s0 of [v.name, dated ? dir : null]){
    if (!s0) continue;
    const pt = parseTitle(String(s0).replace(/\.(mkv|mp4|avi|ts|m2ts|mov|wmv|iso|rmvb|flv|webm)$/i, ''));
    if (pt.cn){ const g = groupKey(pt); if (!gks.includes(g)) gks.push(g); }
  }
  const nm = []; for (const x of [c.cn, c.latin]) if (x && !nm.includes(x)) nm.push(x);
  return { k: c.k, p: [c.cn || '', c.latin || '', c.ys.join(','), gks, canonKeys(nm), String(v.name || '').slice(0, 200)] };
}
/** 候选的压缩形 → 认定用的形状（libResolveOne 吃这个） */
const livePackOpen = (p) => ({ cn: p[0] || '', latin: p[1] || '', ys: p[2] ? String(p[2]).split(',').filter(Boolean) : [] });

/** 总账（Stream v22 的快照）→「路径 / 文件名 → 可信 id」提示表。总账不再更新：只在它的 gen 变了时重下一次 */
async function ledgerHints(env, prev){
  const meta = await recvGet(env, 'meta', 6000).catch(() => null);
  if (!meta || !meta.gen) return { gen: '', ts: 0, map: null, none: 1 };
  if (prev && prev.lgen === meta.gen) return { gen: meta.gen, ts: prev.lts || 0, map: null, same: 1 };
  const doc = await recvGet(env, 'doc', 25000).catch(() => null);
  if (!doc || !Array.isArray(doc.items)) return { gen: '', ts: 0, map: null, none: 1 };
  const map = new Map();
  for (const it of doc.items){
    if (!it || it.kind === 'series') continue;
    const c = recvClassify(it, 'movie');
    if (!c || !c.id) continue;
    const e = [c.id, c.title, c.y, c.idn ? c.idn[1] : [], c.idn ? c.idn[3] : []];
    if (it.path) map.set('p:' + String(it.path).toLowerCase(), e);
    if (it.name) map.set('n:' + String(it.name), e);
  }
  return { gen: meta.gen, ts: doc.ts || 0, map };
}

/**
 * 成品（v8）里的原料 → 比对用的 ids / idn / fz / todo。
 *   lids  路径 → 总账给的可信 id     cands  候选键 → 压缩候选     res  候选键 → TMDB 认定结果（0 = 认不出）
 * 认出 id 的只按 id 比（不再按片名去认领别的片）；没认出的按片名 + 年份认领，并带上索引片名键。
 */
function liveCompose(doc){
  const ids = [], dedup = new Set(), idn = [], idnSeen = new Set(), fz = [], todo = [];
  let viaLedger = 0, viaTmdb = 0;
  /* [v6.5] 每条都带上片库里对应的文件名：详情页上能写明「库里对上的是哪个文件」 */
  const addId = (id, t, y, k, f) => { if (!dedup.has(id)){ dedup.add(id); ids.push([id, t || '', String(y || ''), k || '', f || '']); } };
  for (const pk in doc.lids || {}){
    const e = doc.lids[pk];
    if (!Array.isArray(e) || !(e[0] > 0)) continue;
    addId(e[0], e[1], e[2], '', e[5] || pk.slice(pk.lastIndexOf('/') + 1)); viaLedger++;
    if (Array.isArray(e[4]) && e[4].length && !idnSeen.has(e[0])){ idnSeen.add(e[0]); idn.push([e[0], e[3] || [], yearOf(e[2]) || 0, e[4]]); }
  }
  const res = doc.res || {};
  for (const ck in doc.cands || {}){
    const p = doc.cands[ck];
    const r = res[ck];
    if (Array.isArray(r) && r[0] > 0){
      addId(r[0], r[1], r[2], ck, p[5]); viaTmdb++;
      /* [v6.5] 这边认下的 id 也给「两边 id 不同」的推断用：TMDB 偶尔有同一部片的两个条目 */
      if (!idnSeen.has(r[0])){
        const nm2 = []; for (const x of [r[1], p[0], p[1]]) if (x && !nm2.includes(x)) nm2.push(x);
        const kk = canonKeys(nm2);
        if (kk.length){ idnSeen.add(r[0]); idn.push([r[0], nm2, yearOf(r[2]) || 0, kk]); }
      }
      continue;
    }
    if (r === undefined) todo.push(ck);
    const nm = []; for (const x of [p[0], p[1]]) if (x && !nm.includes(x)) nm.push(x);
    if ((p[4] && p[4].length) || (p[3] && p[3].length)) fz.push([nm, yearOf(String(p[2] || '').split(',')[0]) || '', 0, p[4] || [], p[3] || [], p[5] || '']);
  }
  for (const s of doc.tvs || []){                  // 剧集：v25 剧集表认好的 id 直接用，没有的按片名 + 季 + 年份认领
    if (s[0] > 0){
      addId(s[0], s[1][0] || '', s[2], '', s[5] || ''); viaLedger++;
      if (s[4].length && !idnSeen.has(s[0])){ idnSeen.add(s[0]); idn.push([s[0], s[1], yearOf(s[2]) || 0, s[4]]); }
    } else if (s[4].length) fz.push([s[1], yearOf(s[2]) || '', s[3] || 0, s[4], [], s[5] || '']);
  }
  doc.ids = ids; doc.idn = idn; doc.fz = fz; doc.todo = todo;
  doc.viaLedger = viaLedger; doc.viaTmdb = viaTmdb;
  doc.missed = fz.length;
  return doc;
}

/**
 * 同步一次实时清单 → A/list.json（v8）。返回 null = 实时清单拿不到（调用方退回总账 / 老管线）。
 * force：清单没变也重算（规则或总账变了时）。
 */
async function libSyncLive(env, force){
  if (!liveOn(env)) return null;
  const cur = await libDoc(env);
  const same = cur.v === 8 && cur.cv === CANON_V && cur.src === 'live';
  const prev = same && !force ? cur : null;
  const tv = isTV();
  const live = tv ? await liveTv(env, prev) : await liveMovies(env, prev);
  if (!live) return null;
  if (live.unchanged)
    return { mode: 'live', unchanged: 1, gen: live.gen, files: cur.files || 0, cands: cur.mine || 0,
             ids: (cur.ids || []).length, left: (cur.todo || []).length, part: 0, done: !(cur.todo || []).length };
  const out = { v: 8, cv: CANON_V, src: 'live', gen: live.gen, via: live.via, liveTs: live.ts,
    scan: Date.now(), at: Date.now(), weak: [], loose: [], miss: [], seen: [],
    lids: {}, cands: {}, fc: {}, res: {}, tvs: [], files: 0, mine: 0, part: 0, distrust: 0,
    lgen: same ? (cur.lgen || '') : '', lts: same ? (cur.lts || 0) : 0 };
  if (tv){
    for (const s of live.series){
      if (!s || typeof s !== 'object') continue;
      out.files += Math.max(1, Number(s.episodes || s.total) || 1);
      const nm = []; for (const x of [s.zh, s.en, s.title]) if (x && typeof x === 'string' && !nm.includes(x.trim())) nm.push(x.trim().slice(0, 160));
      const id = Number(s.tmdbId) > 0 ? Math.floor(Number(s.tmdbId)) : 0;
      out.tvs.push([id, nm, String(yearOf(s.year) || ''), Number(s.season) || 0, canonKeys(nm), String(s.folder || s.path || '').slice(0, 200)]);
    }
    out.mine = out.tvs.length;
  } else {
    /* 片库清单突然少了一大半：多半是 Dropbox 那头列到一半出错。不拿它盖掉一份能用的成品 */
    const n0 = same ? (cur.files || 0) : 0;
    if (n0 >= 20 && live.videos.length < n0 * 0.5){
      trace('lib', '实时清单只有 ' + live.videos.length + ' 个文件（上次 ' + n0 + ' 个），像是列到一半出错，这次不用它', { lvl: 'warn' });
      return { mode: 'live', unchanged: 1, suspicious: 1, gen: cur.gen, files: n0, cands: cur.mine || 0,
               ids: (cur.ids || []).length, left: (cur.todo || []).length, part: 0, done: true };
    }
    const hints = await ledgerHints(env, same ? cur : null);
    if (hints.gen){ out.lgen = hints.gen; out.lts = hints.ts; }
    const prevFc = same ? (cur.fc || {}) : {}, prevC = same ? (cur.cands || {}) : {};
    const prevL = same ? (cur.lids || {}) : {}, prevR = same ? (cur.res || {}) : {};
    const rootLen = live.root.length;
    let parsed = 0;
    for (const v of live.videos){
      if (!v || !v.path || !v.name) continue;
      out.files++;
      const pk = String(v.path).toLowerCase();
      /* ① 总账提示：这个文件在 v22 那份快照里、而且 id 可信 */
      const lh = hints.map ? (hints.map.get('p:' + pk) || hints.map.get('n:' + String(v.name))) : prevL[pk];
      if (lh){ out.lids[pk] = lh.length > 5 ? lh : lh.slice(0, 5).concat([String(v.name).slice(0, 200)]); continue; }
      /* ② 切片名：只切第一次见到的文件 */
      let ck = prevFc[pk];
      if (ck === undefined || (ck && !prevC[ck] && !out.cands[ck])){
        if (parsed >= LIVE_PARSE_MAX){ out.part++; continue; }
        parsed++;
        const c = liveCand(v, rootLen);
        ck = c ? c.k : '';
        if (c && !out.cands[ck]) out.cands[ck] = c.p;
      } else if (ck && !out.cands[ck]) out.cands[ck] = prevC[ck];
      out.fc[pk] = ck;
      if (ck && prevR[ck] !== undefined) out.res[ck] = prevR[ck];
    }
    out.mine = Object.keys(out.lids).length + Object.keys(out.cands).length;
  }
  liveCompose(out);
  await r2put(env, LIB.list, out);
  libMem = null;
  trace('lib', '实时清单（' + (live.via === 'r2' ? '公开 R2' : 'Stream 接口') + '）：片库 ' + out.files + ' 个文件 → ' + out.mine + ' 部 · '
    + out.ids.length + ' 部带 TMDB id（总账 ' + out.viaLedger + ' · 这边认定 ' + out.viaTmdb + '）'
    + (out.todo.length ? ' · 待认定 ' + out.todo.length : '') + (out.part ? ' · 还有 ' + out.part + ' 个文件下次接着切' : '')
    + ' · gen=' + out.gen, { lvl: 'info' });
  return { mode: 'live', gen: out.gen, files: out.files, cands: out.mine, ids: out.ids.length,
           left: out.todo.length, part: out.part, done: !out.todo.length && !out.part };
}
/** 片库同步的总入口：实时清单 → 总账 → 老管线（文件名扫描），哪条先拿到用哪条 */
async function libSyncAny(env, force){
  const lv = await libSyncLive(env, force).catch(e => { trace('lib', '实时清单：' + (e.message || e), { lvl: 'warn' }); return null; });
  if (lv) return lv;
  if (recvBase(env)) return await libSyncRecv(env, force).catch(e => { trace('lib', e.message || String(e)); return null; });
  return null;
}

/* miss 是「v5 送去 TMDB 认过、确实认不出来」的候选键。
   它和 weak / loose 是两回事：后者只是比对时的模糊兜底，里面还混着
   v4 遗留下来的整库键 —— 拿它们当"已处理"就等于一上来全跳过。 */
const blankLib = () => ({ v:5, scan:0, at:0, files:0, ids:[], weak:[], loose:[], miss:[], seen:[], todo:[] });

/* ══════════════════════════════════════════════════════════════════
   待认队列 idx/v5/pending.json
   TMDB 认不出来的那一组，连同它的帖子行一起留在这里。于是「重试匹配」
   是真的能把片源找回来的 —— 不用把列表页重爬一遍。
   v4 在这里直接 continue，行就永远丢了。
   ══════════════════════════════════════════════════════════════════ */
/* PEND 的键按源取，见文件头部的 SRC_MOVIE / SRC_TV */
const PEND_SKIP = new Set(['tv','pack','other']);  // 本来就不是这个源的东西，不该反复重试
const blankPend = () => ({ v:5, at:0, q:{} });
/* [v6] 读失败不能当成「队列是空的」：那样这一轮写回去，留底的帖子行就全没了。
   读失败 → 抛错（这一轮不写）；内容损坏 → 当空队列（备份里有，体检里「从备份恢复」） */
const pendLoad = async (env) => {
  let d = null;
  try { d = await r2get(env, PEND.key, null); }
  catch (e){ if (!e.corrupt) throw e; trace('sys', '留底队列损坏，按空队列处理', { lvl:'err' }); }
  return (d && d.q && typeof d.q === 'object') ? d : blankPend();
};
/**
 * 进留底队列。返回 false = 队列已满、没放进去（调用方要知道：极限模式靠它决定游标能不能往前推）。
 * [v6.2] why='wait' 是极限模式「还没认、等认定工」的条目：帖子行要全留（上限与一部片的行数上限相同），
 * 认下来要整组写进分片；认不出的条目照旧只留 PEND.rows 行。
 */
function pendAdd(doc, g, y, why){
  let e = doc.q[g.key];
  if (!e){
    if (Object.keys(doc.q).length >= PEND.cap) return false;
    e = doc.q[g.key] = { cn:g.cn, la:g.latin||'', ys:g.years||[], y, t:'', r:[], n:0, w:why };
  }
  e.w = why; e.y = y;
  if (!e.t) e.t = String((g.rows && g.rows[0] && g.rows[0].title) || g.cn || '').slice(0, 90);
  const cap = why === 'wait' ? ROWS_PER_MOVIE : PEND.rows;
  const have = new Set(e.r.map(x => x[0]));
  for (const row of (g.rows || [])){
    const tid = Number(row.tid);
    if (!tid || have.has(tid) || e.r.length >= cap) continue;
    /* [v6.2] 每行带上自己的年份：同名同原名的两部片（重拍）共用一个键，两年的帖子会并进同一条，
       写回分片时必须各回各的年份 —— 否则另一年的增量扫描看不到它、再挂一遍，就重复了 */
    e.r.push([tid, String(row.title||'').slice(0, 160), y]);
    have.add(tid);
  }
  return true;
}
/** 留底条目的帖子行按年份分组（老条目没有逐行年份，算在条目的年份上）。年份不属于这个源的丢掉 */
function pendRowsByYear(e){
  const out = new Map();
  for (const x of e.r || []){
    const y = Number(x[2] || e.y);
    if (!YEARS[y]) continue;
    if (!out.has(y)) out.set(y, []);
    out.get(y).push({ tid: x[0], title: x[1] });
  }
  return out;
}
/** 队列摘要写进 state，前端和体检就不用每次再读一遍 R2。skip：这一轮已经写进分片、只是还没删的键 */
function pendStat(doc, skip){
  const ks = Object.keys(doc.q);
  let tv = 0, pack = 0, dead = 0, retry = 0, wait = 0, n = 0, garbled = 0, gchk = 0;
  const sample = [];
  for (const k of ks){
    if (skip && skip.has(k)) continue;
    n++;
    const e = doc.q[k];
    /* [v6.4] 抽查前 80 条的标题是不是乱码（UTF-8 当 GBK 解的）：多数是 → 界面上给「重建本源索引」 */
    if (gchk < 80 && e.t){ gchk++; if (mojibake(e.t)) garbled++; }
    if (e.w === 'wait') wait++;                   // 极限模式排队等认定，不算「认不出」
    else if (e.w === 'tv' || e.w === 'other') tv++;    // 本来就不属于这个源
    else if (e.w === 'pack') pack++;
    else if ((e.n||0) >= PEND.tries) dead++;
    else { retry++; if (sample.length < 8 && e.t) sample.push(e.t); }
  }
  return { n, tv, pack, dead, retry, wait, sample, garbled, gchk, at: Date.now() };
}
async function pendSave(env, doc, state, skip){
  doc.at = Date.now();
  const st = pendStat(doc, skip);
  if (state) state.pend = st;
  await r2put(env, PEND.key, doc);
  return st;
}
/**
 * [v6.2] 留底条目的「延迟删除」。
 * 认下来的条目写进分片之后不能当场从队列里删：队列先于提交写，掐在两次写之间，
 * 这些帖子就既不在队列里、也不在索引里。所以只记进 state.pdone，跟着 state.json 一起提交；
 * 下一个读到这份 state 的持锁任务把它们从队列里删掉 —— 那次写队列成功之后 pdone 才清空。
 * 返回 true = 删掉了东西（调用方要把队列写回去）。
 */
function pendSync(pend, state){
  const d = state && Array.isArray(state.pdone) ? state.pdone : null;
  if (!d || !d.length) return false;
  let n = 0;
  for (const k of d) if (pend.q[k]){ delete pend.q[k]; n++; }
  return n > 0 || d.length > 0;
}
/** 提交前定 state.pdone：这一轮写过队列（已经不含旧的 pdone）就只留本轮的；没写过就并起来 */
function pdoneSet(state, doneNow, pendWritten){
  const cur = pendWritten ? [] : (Array.isArray(state.pdone) ? state.pdone : []);
  const all = [...new Set(cur.concat([...doneNow]))];
  if (all.length) state.pdone = all; else delete state.pdone;
}
/* 认不出的原因只认这几种（浏览器交回来的结果要过这道） */
const PEND_WHY = new Set(['nohit', 'tv', 'pack', 'other']);
/**
 * 留底条目 → 认定用的一组。留底里的 cn / latin 是当初那个解析器切出来的 ——
 * 拿原始标题用新解析器重切，切不出来才退回旧值；nkey 是新解析器下的键，认回来之后一并记进 movies.k。
 */
function pendGroup(k, e){
  const pt = e.t ? parseTitle(e.t) : null;
  return { key: k,
    cn: (pt && pt.cn) || e.cn,
    latin: (pt && pt.latin) || e.la || '',
    years: (pt && pt.years && pt.years.length) ? pt.years : (e.ys || []),
    hint: e.y, title: e.t,
    nkey: (pt && pt.cn) ? groupKey(pt) : k };
}

/** 读成品；A/list.json 还没有时，用 v4 的模糊键表垫一下，不至于突然不过滤 */
async function libDoc(env){
  const d = await r2get(env, LIB.list, null).catch(() => null);
  if (d && (d.v === 8 || d.v === 7 || d.v === 6 || d.v === 5)) return d;   /* v7 / v6 = 总账直读；v5 = 老管线的成品 */
  const old = await r2get(env, LIB.legacy, null).catch(() => null);
  const b = blankLib();
  if (old){
    /* v4 的模糊键搬过来只当兜底用，scan 保持 0 —— 表示"还没被 v5 认过一遍"。
       这些键一个都不能算作已处理，否则扫描时会把整库候选全判成 known，
       待认定永远是 0，TMDB 认定这一步就永远启动不了。 */
    b.files = old.files || 0; b.at = old.at || 0;
    b.weak = (old.ty || []).slice(0, LIB.cap);
    b.loose = (old.t || []).slice(0, LIB.cap);
  }
  return b;
}

/**
 * ① 扫描：拉一次片库，重算候选，并让成品跟着片库增删走。
 *
 * v5.2 这里有两处让「已有」判不出来的毛病：
 *   · 「处理过」是从 doc.ids 的候选键推出来的，而 ids 按 TMDB id 去过重 ——
 *     同一部片在库里有两份不同命名的拷贝（4K + 1080p、国配 + 原版），
 *     两个候选键认到同一个 id，去重只留一个，另一个键就此消失。下次扫描
 *     它又是「没认过」，又排队、又认、又被去掉……永远循环。cron 每轮那点
 *     预算全喂给了这些早就认过的片，排在后面真正的新片一直轮不到，看着
 *     就是「有些没识别到」。现在单独记一份 seen（认过的候选键，命中与否
 *     都记），跟 ids 的去重彻底脱钩。
 *   · 成品只增不减：片库里删掉的片，id 还赖在 ids 里，一直显示「库中已有」。
 *     现在拿这一次扫描到的候选键当权威，不在库里的键连同它的 id 一起清掉。
 * 另外，模糊兜底键改成每次扫描按当前候选重算 —— 不再是「只有 TMDB 认不
 * 出来的才留一条」。新加进片库的片在扫描之后立刻就能标「疑似已有」，不用
 * 等 cron 把它认下来；删掉的片也不会留下一条永远命中的旧键。
 */
async function libScanStep(env, opt){
  /* 总账在位就走那条路：一次取回、按源分拣、抄 id，没有待认定队列。
     拿不到（后端没升级 / 总账还在建）才落回下面这套文件名认定。
     skipRecv：调用方刚试过总账且失败了，别再白问一次指针。 */
  if (!(opt && opt.skipRecv) && liveOn(env)){
    const lv = await libSyncLive(env, true).catch(e => { trace('lib', '实时清单：' + (e.message || e), { lvl: 'warn' }); return null; });
    if (lv) return { files: lv.files, cands: lv.cands, skipped: 0, dropped: 0, left: lv.left, part: lv.part,
                     ok: lv.ids, tried: 0, mode: 'live', gen: lv.gen };
  }
  if (!(opt && opt.skipRecv) && recvBase(env)){
    const r = await libSyncRecv(env, true).catch(e => { trace('lib', e.message || String(e)); return null; });
    if (r) return { files: r.files, cands: r.cands, skipped: 0, dropped: 0,
                    left: 0, ok: r.ids, tried: r.missed, mode: 'received', gen: r.gen };
  }
  const doc = await libDoc(env);
  const { files, cands } = libScan(await libFetch(env, 2));
  const live = new Set(cands.map(c => c.k));

  /* 认过的候选键。seen 是权威；ids/miss 只在 seen 还没建起来时兜底（老文档） */
  const known = new Set(Array.isArray(doc.seen) ? doc.seen : []);
  for (const it of doc.ids || []) if (it[3]) known.add(it[3]);
  for (const k of doc.miss || []) known.add(k);

  /* 片库里已经没有的，成品里也不该留着 */
  const ids0 = doc.ids || [], miss0 = Array.isArray(doc.miss) ? doc.miss : [];
  doc.ids  = ids0.filter(it => !it[3] || live.has(it[3]));       // 老条目没有键，留着
  doc.miss = miss0.filter(k => live.has(k));
  doc.seen = [...known].filter(k => live.has(k));
  const dropped = (ids0.length - doc.ids.length) + (miss0.length - doc.miss.length);
  const gone = new Set(doc.seen);

  /* 模糊兜底键按当前候选重算：片名 + 年份进 weak，没年份的进 loose */
  const weak = new Set(), loose = new Set();
  const todo = [];
  for (const c of cands){
    candKeys(c, weak, loose);
    if (!gone.has(c.k)) todo.push(candPack(c));
  }
  doc.weak = [...weak].slice(0, LIB.cap);
  doc.loose = [...loose].slice(0, LIB.cap);
  doc.files = files; doc.scan = Date.now(); doc.at = Date.now();
  doc.todo = todo;
  await r2put(env, LIB.list, doc);
  libMem = null;
  const skipped = Math.max(0, files - cands.length);
  trace('lib', '片库扫描：' + files + ' 个文件 → ' + cands.length + ' 部片，待认定 ' + todo.length +
    '（已认下 ' + doc.ids.length + '，认过但没有 ' + doc.miss.length +
    (dropped ? '，清掉已不在库里的 ' + dropped : '') + '）', { lvl:'info' });
  return { files, cands: cands.length, skipped, dropped, left: todo.length,
           ok: doc.ids.length, tried: doc.miss.length };
}

/** 单个候选送 TMDB 认一次；结果进 KV 缓存 30 天，重复同步几乎不花子请求 */
async function libResolveOne(env, c){
  /* v5.0 在这里往 KV 写了一份 30 天缓存 —— 一个上千部的片库第一遍就是
     上千次 KV 写入，而 Free 计划一天只有 1000 次写。写爆之后连会话 cookie
     都存不下，整站开始反复登录。而且这份缓存本来就是多余的：认定结果
     已经落在 A/list.json 的 ids / miss 里，扫描时会跳过，不会重复认。 */
  /* v5.2 这里的口径比建索引那边弱一大截，于是同一部片索引认得出、片库认
     不出，最后落到只按片名撞的模糊兜底上 —— 译名差一个字就判成缺片。
     现在跟 matchBatch 用同一套：洗过的中文名先搜、年份锁住时门槛放低、
     第二轮换原名、两轮候选合起来再评一次。 */
  const raw = c.cn || c.latin;
  if (!raw) return { miss: 1 };
  const left = () => env.__sub ? env.__sub.max - env.__sub.n : subLeft();
  const q1 = (() => { const x = cleanCN(c.cn); return (x && x.length >= 2) ? x : raw; })();
  /* 剧集不锁年份：版块年份是这一季的，TMDB 记的是首播年 */
  const yr = (!isTV() && c.ys.length === 1) ? c.ys[0] : '';
  const ask = async (q, y, lang) => {
    const p = { query: q, include_adult: 'false' };
    if (y) p[SRC.yparam] = y;
    if (lang) p.language = lang;
    const j = await tmdb(env, '/search/' + SRC.kind, p)
      .catch(e => { if (e.budget) throw e; return null; });
    return j ? (j.results || []).slice(0, 8) : null;
  };
  let pool = await ask(q1, yr);
  if (pool === null) return null;                        // 网络失败：这次不下结论，留待下轮
  /* 年份锁住就等于 TMDB 先替我们筛了一道，片名沾边即可 —— 和索引侧同一个门槛 */
  let m = pickTMDB(pool, c.cn, c.latin, c.ys, { tv: isTV(), yearLocked: !!yr });
  if (!m && left() > 3){
    /* 换个说法再试：原名最管用，其次是洗之前的原始片名，最后是去掉年份 */
    const alt = (c.latin && norm(c.latin) !== norm(c.cn)) ? { q: c.latin, y: '' }
              : (norm(q1) !== norm(raw) ? { q: raw, y: '' }
              : (yr ? { q: q1, y: '' } : null));
    if (alt){
      const more = await ask(alt.q, alt.y);
      if (more) pool = pool.concat(more);
    }
    if (pool.length) m = pickTMDB(pool, c.cn, c.latin, c.ys, { tv: isTV() });
  }
  /* [v6.3] 文件名只有英文名（外语片常见：Parasite.2019…）：中文结果里只有中文名和原名（기생충），
     英文名对不上任何一个就判成认不出 —— 用英文再搜一次，拿英文片名比 */
  /* （切片名时没有中文名的标题，cn 里放的就是英文名 —— 按「有没有汉字」判断） */
  if (!m && c.latin && !/[\u3400-\u9fff]/.test(c.cn || '') && left() > 3){
    const en = await ask(c.latin, yr, 'en-US');
    if (en && en.length) m = pickTMDB(en, '', c.latin, c.ys, { tv: isTV(), yearLocked: !!yr });
  }
  /* [v6.3] 文件名写着年份、认出来的那部差一年以上：多半是同名的另一部（重拍、老片），不认。
     不锁年份的第二轮只看片名，片名一模一样的 2025 年新片能把 1999 年的老片顶掉 */
  if (m && !isTV() && c.ys.length && m.release_date){
    const my = Number(String(m.release_date).slice(0, 4));
    if (my && !c.ys.some(y => Math.abs(Number(y) - my) <= 1)) m = null;
  }
  return m
    ? { id: m.id, t: m.title || m.original_title || c.cn, y: (m.release_date || '').slice(0, 4) }
    : { miss: 1 };
}

/** ② 认定：跑一批，剩下的写回 todo。返回 left>0 就再调一次。 */
async function libResolveStep(env, opt = {}){
  const t0 = Date.now();
  /* local：轻请求里后台认的时候用自带的一小份配额（同认定工），不碰这次调用的全局计数 */
  const envR = opt.local ? Object.assign(Object.create(env), { __sub: { n: 0, max: opt.local } }) : env;
  const budgetLeft = () => envR.__sub ? envR.__sub.max - envR.__sub.n : subLeft();
  const doc = await libDoc(env);
  /* [v6.3] 实时清单：认的是「总账里没有、索引片名键也没对上」的新文件，结果记进 res（按候选键），
     认出来的从「按片名认领」挪到「按 id 比」 */
  if (doc.v === 8){
    const todo = isTV() ? [] : (doc.todo || []);
    if (!todo.length) return { left: 0, done: true, mode: 'live', ok: (doc.ids || []).length, added: 0, missed: 0, ms: 0 };
    const res = doc.res || (doc.res = {});
    const deadline = t0 + 8000;
    let added = 0, missed = 0, retry = 0, n = 0;
    for (; n < todo.length && n < LIB.batch; n++){
      if (budgetLeft() < 6 || Date.now() > deadline) break;
      const ck = todo[n], p = (doc.cands || {})[ck];
      if (!p){ continue; }
      pipe('lib', 'i');
      let r;
      try { r = await libResolveOne(envR, livePackOpen(p)); }
      catch (e){ if (e.budget) break; pipe('lib', 'e'); r = null; }
      if (r === null){ retry++; continue; }            // 网络失败：不下结论，留在队里
      pipe('lib', 'o');
      if (r.miss){ res[ck] = 0; missed++; continue; }
      res[ck] = [r.id, r.t || '', r.y || ''];
      added++;
    }
    liveCompose(doc);
    doc.at = Date.now();
    await r2put(env, LIB.list, doc);
    libMem = null;
    const left = doc.todo.length;
    trace('lib', '片库认定 ' + n + ' 个：认下 ' + added + ' · 认不出 ' + missed + (retry ? ' · 待重试 ' + retry : '') + ' · 还剩 ' + left, { lvl: 'info' });
    const spent = Date.now() - t0;
    return { left, done: left === 0, mode: 'live', ok: doc.ids.length, ids: doc.ids.length, added, missed, retry,
             wait: Math.max(0, 1200 - spent), ms: spent, sub: SUB.n };
  }
  /* 总账模式下没有「待认定」这回事 —— id 是 Stream 那边给的 */
  if (doc.src === 'received')
    return { left: 0, done: true, mode: 'received', ok: (doc.ids || []).length,
             added: 0, missed: 0, ms: 0 };
  const todo = doc.todo || [];
  if (!todo.length) return { left: 0, done: true, ok: (doc.ids||[]).length, added: 0, ms: 0 };
  /* 一轮做多少，由三个条件里最先到的那个决定：条数上限、子请求预算、
     时间预算。一轮做得越多，写 A/list.json 的次数就越少 —— R2 对同一个
     对象的写入频率有硬限制，写得密了会直接被拒（10058）。 */
  const cap = Math.min(LIB.batch, todo.length);
  const deadline = t0 + 8000;
  const ids = doc.ids || (doc.ids = []);
  const miss = new Set(Array.isArray(doc.miss) ? doc.miss : []);
  /* 认过的候选键单独记一份。ids 会按 TMDB id 去重（同一部片在库里有几份
     拷贝就有几个候选键），拿它反推「认过没有」必然漏，漏掉的下轮又排队。 */
  const seen = new Set(Array.isArray(doc.seen) ? doc.seen : []);
  let added = 0, missed = 0, retry = 0, n = 0;

  const again = [];                                     // 网络原因没认成的，挪到队尾下轮再认
  for (; n < todo.length && n < cap; n++){
    if (subLeft() < 6 || Date.now() > deadline) break;
    const c = candOpen(todo[n]);
    pipe('lib', 'i');
    let r;
    try { r = await libResolveOne(env, c); }
    catch (e){
      if (e.budget) break;
      pipe('lib', 'e'); r = null;
    }
    if (r === null){ retry++; again.push(todo[n]); continue; }
    seen.add(c.k);                                      // 认过了，下次扫描别再排队
    if (r.miss){
      missed++; pipe('lib', 'o');
      miss.add(c.k);
      continue;                                         // 模糊键在扫描时按现状统一算
    }
    /* 「抄送」：认下来的片名 + 年份 + id 一起存，A/list.json 就是成品 */
    ids.push([r.id, r.t, r.y || (c.ys[0] || ''), c.k]);
    added++; pipe('lib', 'o');
  }

  /* 认失败（网络）的挪到队尾，别把队头堵死；没轮到的原样保留 */
  doc.todo = todo.slice(n).concat(again);
  /* 满了要切掉的是最旧的那批，不是刚认出来的这批 */
  doc.miss = [...miss].slice(-LIB.cap);
  doc.seen = [...seen].slice(-LIB.cap);
  doc.at = Date.now();
  /* id 去重：同一部片可能有多个文件。注意这里丢掉的是候选键，所以
     「认过没有」只能问 doc.seen，不能反过来从 doc.ids 推。 */
  const dedup = new Set(); const uniq = [];
  for (const it of ids){ if (dedup.has(it[0])) continue; dedup.add(it[0]); uniq.push(it); }
  doc.ids = uniq;
  await r2put(env, LIB.list, doc);
  libMem = null;
  const left = doc.todo.length;
  trace('lib', '认定 ' + n + ' 个：命中 ' + added + ' · 认不出 ' + missed +
    (retry ? ' · 待重试 ' + retry : '') + ' · 还剩 ' + left, { lvl: 'info' });
  /* 告诉前端下一轮该等多久：R2 同对象大约每秒只受得住一次写入，
     这一轮本身花掉的时间可以抵扣掉一部分。 */
  const spent = Date.now() - t0;
  return { left, done: left === 0, ok: uniq.length, added, missed, retry,
           wait: Math.max(0, 1200 - spent), ms: spent, sub: SUB.n };
}

let libMem = null;   // 热路径用的成品（Set 化）
let libJob = null;   // 并发合流：同一 isolate 只回源一次
let libFail = 0;     // 上次失败时刻 —— 静默期内不再重试
let libErr = '';     // [v6.3] 上次失败的原因：片库面板拿它告诉人该配什么

/* 海报 / 列表的缓存版本号。总账模式下 gen 本身就是内容指纹 —— 比
   「分钟 + 条数」精确得多：条数不变而内容变了的那一类改动也能翻转。
   比对规则的版本也带上：规则一改，边缘缓存里按旧规则判的结果自然作废。 */
const libVer = (l) => !l ? '0'
  : (l.src === 'live' ? 'l' + h32(l.gen + '.' + l.ids.size + '.' + l.fz.length + '.' + l.todo + '.' + l.part)
     : (l.gen ? 'r' + l.gen : Math.floor(l.at / 60000) + '.' + l.ids.size + '.' + l.fz.length)) + '.c' + CANON_V;

/**
 * 成品 → 热路径用的形状。比对键在这里算好（每份成品每个 isolate 算一次），
 * 请求路径上不再做任何字符串归一化。
 *   v7（总账）：ids / idn / fz 原样展开
 *   v6（老总账成品）：只有 ids 与模糊键 —— 下一次同步就会升到 v7，这里先按 v7 的口径凑合：
 *       模糊键当作「没有可信 id 的条目」，但认下来的那些片名不再进模糊集合
 *   v5（文件名认定）：ids = 认下来的；没认下来的候选（待认定 + 认过但 TMDB 没有）进 fz
 */
function libHydrate(doc){
  if (!doc) return null;
  const ids = new Set(), names = [], fz = [], idn = [], files = new Map();
  for (const it of doc.ids || []){
    const id = Number(it && it[0]);
    if (id > 0){ ids.add(id); if (names.length < 4 && it[1]) names.push(it[1]); if (it[4] && !files.has(id)) files.set(id, String(it[4])); }
  }
  const pushFz = (nm, y, sn, kk, gk, file) => { const keys = kk || canonKeys(nm);
    if (keys.length || (gk && gk.length)) fz.push({ ...keySplit(keys), y: yearOf(y), sn: sn || 0, gk: Array.isArray(gk) && gk.length ? gk : null, file: file || '' }); };
  /* 同步时已经把比对键算好存在成品里（cv = 规则版本）；版本对不上就现场重算 */
  const stored = doc.cv === CANON_V;
  if (doc.v === 7 || doc.v === 8){
    for (const e of doc.fz || []) if (Array.isArray(e)) pushFz(e[0] || [], e[1], e[2], stored && Array.isArray(e[3]) ? e[3] : null, e[4], e[5]);
    for (const e of doc.idn || []){
      if (!Array.isArray(e) || !(Number(e[0]) > 0)) continue;
      const keys = stored && Array.isArray(e[3]) ? e[3] : canonKeys(e[1] || []);
      if (keys.length) idn.push({ id: Number(e[0]), ...keySplit(keys), y: yearOf(e[2]) });
    }
  } else {
    /* 老成品：认下来的候选键（「片名|年份」）对应的片名，不能再拿去模糊认领别的片 */
    const known = new Set();
    for (const it of doc.ids || []) if (it && it[3]) known.add(String(it[3]).split('|')[0]);
    const seenK = new Set();
    const addKey = (k, y) => {
      const nk = String(k || '');
      if (!nk || known.has(nk) || seenK.has(nk + '|' + (y || ''))) return;
      seenK.add(nk + '|' + (y || ''));
      pushFz([nk], y, 0);
    };
    for (const a of doc.todo || []){ if (Array.isArray(a)){ const c = candOpen(a); pushFz([c.cn, c.latin], c.ys[0], 0); } }
    for (const k of Array.isArray(doc.miss) ? doc.miss : []){ const [nk, y] = String(k).split('|'); addKey(nk, y); }
    for (const k of doc.weak || []){ const i = String(k).lastIndexOf('|'); if (i > 0) addKey(String(k).slice(0, i), String(k).slice(i + 1)); }
    for (const k of doc.loose || []) addKey(k, '');
  }
  return { at: doc.at || 0, docAt: doc.at || 0, scan: doc.scan || 0, files: doc.files || 0,
           ids, fz, idn, fuzzy: fz.length, fileOf: files,
           tried: (Array.isArray(doc.miss) ? doc.miss : []).length,
           todo: (doc.todo || []).length, sample: names, n: ids.size + fz.length,
           /* 总账直读专有：模式、内容指纹、本源部数、没有可信 id 的部数 */
           src: doc.src || 'scan', gen: doc.gen || '', via: doc.via || '',
           mine: doc.mine || 0, missed: doc.missed || 0, distrust: doc.distrust || 0, pending: doc.pending || 0,
           /* [v6.3] 实时清单：清单时间、总账（只当提示）停在哪天、两种来源各认了多少、还有多少文件没切 */
           recvTs: doc.recvTs || 0, liveTs: doc.liveTs || 0, lts: doc.lts || 0, part: doc.part || 0,
           viaLedger: doc.viaLedger || 0, viaTmdb: doc.viaTmdb || 0 };
}

async function libRefresh(env, alsoResolve){
  if (libJob) return libJob;
  libJob = (async () => {
    let via = await libSyncAny(env, false);
    /* 实时清单里有新文件要认：当场认一批。[v6.5] 翻目录时的后台刷新（轻请求）也认 —— 用自带的一小份配额
       （不碰这次调用的 50 个子请求），新进库的片几分钟内就从「缺片」里消失，不用等每天的定时任务 */
    if (via && via.mode === 'live' && via.left){
      if (alsoResolve !== false){ if (subLeft() > 10) await libResolveStep(env).catch(() => {}); }
      else await libResolveStep(env, { local: 24 }).catch(() => {});
    }
    if (!via){
      /* 走到这里只有两种情况：没配总账地址，或刚刚试过、总账不可用。
         两种都不该让 libScanStep 再问一次指针。 */
      await libScanStep(env, { skipRecv: true });
      if (alsoResolve !== false) await libResolveStep(env).catch(() => {});
    }
    /* 成品没变（同一次写入）就沿用内存里那份：判定表按成品对象缓存，换了对象就得重算 */
    const doc = await libDoc(env);
    if (libMem && doc && doc.at && doc.at === libMem.docAt && (doc.gen || '') === (libMem.gen || '')) libMem.at = Date.now();
    else libMem = libHydrate(doc);
    /* gen 未变那一支不写 R2（省一次十几万字节的重写），所以成品里的 at
       还是旧的 —— 这一轮确实对过账了，在内存里把新鲜度补上，否则
       SWR 窗口永远是过期的，每个请求都要再问一次指针。 */
    if (libMem && via && via.unchanged) libMem.at = Date.now();
    libFail = 0; libErr = libMem ? '' : libErr;
    return libMem;
  })().catch(e => { libFail = Date.now(); libErr = String(e && e.message || e).slice(0, 200); throw e; })
     .finally(() => { libJob = null; });
  return libJob;
}

/** 热路径：吃内存 / R2 成品，过期了后台刷新，永远不因为片库拿不到而挡住浏览 */
async function libLoad(env, ctx){
  if (!recvBase(env)) return null;          /* RECV_BASE 或 STREAM_BASE，有一个就够 */
  if (!libMem){
    const doc = await r2get(env, LIB.list, null).catch(() => null);
    if (doc) libMem = libHydrate(doc);
    else {
      const old = await r2get(env, LIB.legacy, null).catch(() => null);
      if (old) libMem = libHydrate({ at: old.at, files: old.files, ids: [], weak: old.ty, loose: old.t, todo: [] });
    }
  }
  if (!libMem){
    if (Date.now() - libFail < LIB.retry) return null;
    /* 冷启动这一次不等：后台去扫，本次请求先不过滤，别让片库故障挡住浏览 */
    const job = libRefresh(env, false).catch(e => trace('lib', e.message || String(e)));
    if (ctx && ctx.waitUntil) ctx.waitUntil(job); else libFail = Date.now();
    return null;
  }
  /* scan===0 说明这份成品是从 v4 的模糊键表搬过来的，还没被 v5 认过一遍 —— 
     后台补一次扫描，用户不用知道要去点哪个按钮。 */
  /* [v6.5] 实时清单五分钟问一次（只问几十字节的指纹）；顺带把别的 isolate 写进 R2 的认定结果也读回来 */
  const due = !libMem.scan || Date.now() - libMem.at > (libMem.src === 'live' ? LIVE_TTL : LIB.ttl);
  if (due && Date.now() - libFail > LIB.retry && ctx && ctx.waitUntil)
    ctx.waitUntil(libRefresh(env, false).catch(e => trace('lib', e.message || String(e))));
  return libMem;
}

/* ══════════════════════════════════════════════════════════════════
   缺片检测 libOwn（v6）
   ──────────────────────────────────────────────────────────────────
   回答「索引里这部片，我库里是不是已经有了」。每部片一个判定：
     2 = 确定已有：库里有一份可信的 TMDB id 与它相同
     1 = 很可能已有：库里有一份没有可信 id 的，片名 + 年份对得上，而且只对得上它一部；
         或者两边 id 不同、但片名年份全同而索引里根本没有库里那个 id（多半是某一边认错了）
     0 = 缺片
   与 v5 的区别（每一条都对应一类线上误判，见 tests/match-cases.mjs）：
     · 认下来的条目只按 id 比，不再顺手按「片名 + 年份 ±1」把同名的另一部片也藏掉；
     · 没有可信 id 的条目「认领」索引里的一部片：同名多部时挑年份最贴近的那部，
       两部一样贴近就谁都不认（宁可显示出来让人看一眼，也不悄悄藏掉一部缺片）；
     · 没有年份的条目只认独一无二、够长的片名（「无间道」认，「英雄」「Dune」不认）；
     · 片名比对用 canon：繁体、全角、重音、罗马数字、冠词、第二部 / Part Two 都对得上；
     · 剧集的目录年份是这一季的：允许晚于首播（第三季 2016 ↔ 首播 2011），不许早于首播一年以上。
   全部判定在每个（索引版本, 片库成品）上算一次，结果是一张与 catRows 对齐的 Int8Array：
   查目录时每部片只剩一次数组读取，不再做字符串归一化 —— 这正是热路径该有的样子。
   ══════════════════════════════════════════════════════════════════ */
const KEYC = new Map();          // 影片 id → { n, o, keys }：跨索引版本复用，片名没变就不重算
/** 一组比对键 → { keys, cjk, lat }：按文种分好，比对时不再逐个跑正则 */
function keySplit(keys){
  const cjk = [], lat = [];
  for (const k of keys) (keyKind(k) === 'cjk' ? cjk : lat).push(k);
  return { keys, cjk, lat };
}
function rowKeys(r){
  const m = r.m, n = m[F.N] || '', o = m[F.O] || '';
  let e = KEYC.get(r.id);
  if (!e || e.n !== n || e.o !== o){
    const mk = m[F.K];
    const stored = Array.isArray(mk) && mk[0] === CANON_V;
    const cn = stored ? String(mk[1] || '') : canon(n), co = stored ? String(mk[2] || '') : canon(o);
    const keys = [];
    for (const k of [cn, co]) if (k && !LIB_GENERIC.has(k) && keyWeight(k) >= 2 && !keys.includes(k)) keys.push(k);
    e = { n, o, cn, co, ...keySplit(keys) };
    KEYC.set(r.id, e);
    if (KEYC.size > 200000) KEYC.clear();
  }
  return e;
}
/** 年份契合度：-1 = 对不上；3 = 同年；2 = 差一年（剧集：晚于首播）；1 = 有一边不知道 */
function yearFit(ly, iy, tv, strict){
  if (!ly || !iy) return strict ? -1 : 1;
  const d = ly - iy;
  if (d === 0) return 3;
  if (strict) return -1;
  if (tv) return d === -1 ? 2 : (d >= 1 ? 2.5 - Math.min(d, 40) / 100 : -1);
  return Math.abs(d) === 1 ? 2 : -1;
}
/* 名字的「文种」：汉字 / 假名 / 谚文算 cjk，其余算 lat */
const keyKind = (k) => /[぀-ヿ㐀-鿿가-힯]/.test(k) ? 'cjk' : 'lat';
/**
 * 名字有没有互相矛盾：两边都有同一文种（中文 / 英文）的名字、却一个都对不上。
 * 返回 0 = 不矛盾；否则返回「对上的那个名字」的分量 —— 调用方据此决定还认不认：
 *   · 「City」「Fear」这种短英文名撞上、中文名却完全不同 → 多半是两部不同的片，不认；
 *   · 「Interstellar」对上、中文名一个「星际穿越」一个「星際效應」（港台译名）→ 同一部片，
 *     所以对上的名字够长（英文 ≥ 8 个字母 / 中文 ≥ 3 个字）、年份又全对时照认。
 * 英文名允许「一个包含另一个」的出入（文件名常把副标题截掉），但长度得相差不到两成。
 */
function nameClash(a, b){
  let clash = false, matchW = 0;
  for (let t = 0; t < 2; t++){
    const x = t ? a.lat : a.cjk, y = t ? b.lat : b.cjk;
    if (!x.length || !y.length) continue;
    let ok = false;
    for (let i = 0; i < x.length && !ok; i++){
      const p = x[i];
      for (let j = 0; j < y.length; j++){
        const q = y[j];
        if (p === q){ ok = true; matchW = Math.max(matchW, keyWeight(p)); break; }
        const sh = p.length < q.length ? p : q, lo = p.length < q.length ? q : p;
        if (sh.length >= 4 && sh.length >= lo.length * 0.8 && lo.includes(sh)){ ok = true; break; }
      }
    }
    if (!ok) clash = true;
  }
  return clash ? Math.max(1, matchW) : 0;
}
let ownCache = { ver: -1, lib: null, src: '', res: null };
function libOwn(movies, ver, lib){
  if (!lib) return null;
  if (ownCache.ver === ver && ownCache.lib === lib && ownCache.src === SRC.id && ownCache.res) return ownCache.res;
  const rows = catRows(movies, ver);
  const own = new Int8Array(rows.length);
  /* [v6.5] 每部判为已有的片记下「怎么对上的」：1 id 相同 · 2 片名键 · 3 片名认领 · 4 两边 id 不同的推断；
     who = 认领它的那条片库条目（fz 的下标），详情页拿它说出文件名 */
  const how = new Int8Array(rows.length), who = new Int32Array(rows.length).fill(-1);
  const pos = catPos(movies, ver);
  const tv = isTV();
  const stat = { exact: 0, key: 0, name: 0, conflict: 0, amb: 0, ambSample: [], conflictSample: [], ms: 0 };
  const t0 = Date.now();
  for (const id of lib.ids){ const i = pos.get(id); if (i != null && !own[i]){ own[i] = 2; how[i] = 1; stat.exact++; } }

  if (lib.fz.length || lib.idn.length){
    /* 索引这边的片名表：比对键 → 行号。只在片库里还有要按片名比的条目时才建。
       行的比对键、年份各存一份平铺数组，候选计数用「代号 + 定长数组」而不是每次新建 Map ——
       一个常见英文名（City、Home）能对上几百部片，这里是整段最热的循环 */
    const n = rows.length;
    const RK = new Array(n), RY = new Int16Array(n);
    const byKey = new Map();
    for (let i = 0; i < n; i++){
      const e = RK[i] = rowKeys(rows[i]);
      RY[i] = rows[i].y || 0;
      for (const k of e.keys){
        const a = byKey.get(k);
        if (a){ if (a[a.length - 1] !== i) a.push(i); } else byKey.set(k, [i]);
      }
    }
    /* 同名的行按年份排好：有年份的电影只取前后一年那一小段（二分），不必把同名的几百部都翻一遍 */
    for (const a of byKey.values()) if (a.length > 6) a.sort((p, q) => RY[p] - RY[q] || p - q);
    const lowYear = (a, y) => { let lo = 0, hi = a.length; while (lo < hi){ const m = (lo + hi) >> 1; if (RY[a[m]] < y) lo = m + 1; else hi = m; } return lo; };
    const cnt = new Uint8Array(n), mark = new Int32Array(n), touched = [];
    let gen = 0;
    let CS = new Float64Array(64), CI = new Int32Array(64);      // 候选的分数 / 行号（复用，不每次分配）
    /** 一个库里条目 → 它认领的那一行；null = 没对上；-1 = 对上了不止一部、说不准。
        打分先看「几个名字对上了」，再看年份贴不贴近：中文名、原名都对上的差一年，
        胜过只有一个名字对上的同年。名字互相矛盾的候选出局（见 nameClash）。 */
    const pick = (L, strict) => {
      const keys = L.keys, ly = L.y;
      gen++; touched.length = 0;
      const touchRange = (a, from, to) => {
        for (let j = from; j < to; j++){
          const i = a[j];
          if (mark[i] !== gen){ mark[i] = gen; cnt[i] = 0; touched.push(i); }
          cnt[i]++;
        }
      };
      /* 有年份的电影（以及要求同年的推断）只可能对上前后一年里的片；剧集与没年份的整列取 */
      const narrow = ly && (strict || !tv);
      for (const k of keys){
        const a = byKey.get(k);
        if (!a) continue;
        if (!narrow || a.length <= 6){ touchRange(a, 0, a.length); continue; }
        const y0 = strict ? ly : ly - 1, y1 = strict ? ly : ly + 1;
        if (!strict) touchRange(a, 0, lowYear(a, 1));               // 年份不知道的行（排在最前）
        touchRange(a, lowYear(a, y0), lowYear(a, y1 + 1));
      }
      if (!touched.length) return null;
      if (CS.length < touched.length){ CS = new Float64Array(touched.length * 2); CI = new Int32Array(touched.length * 2); }
      let m2 = 0;
      for (let j = 0; j < touched.length; j++){
        const i = touched[j];
        const yf = yearFit(ly, RY[i], tv, strict);
        if (yf < 0) continue;
        CS[m2] = cnt[i] * 10 + yf; CI[m2] = i; m2++;
      }
      if (!m2) return null;
      /* 分数从高到低：候选通常只有几个，插入排序；同名几百部（没年份的常见英文名）才走整排 */
      if (m2 <= 24){
        for (let a = 1; a < m2; a++){
          const sc = CS[a], ii = CI[a];
          let q = a;
          while (q > 0 && CS[q - 1] < sc){ CS[q] = CS[q - 1]; CI[q] = CI[q - 1]; q--; }
          CS[q] = sc; CI[q] = ii;
        }
      } else {
        const ord = Array.from({ length: m2 }, (_, q) => q).sort((p, q) => CS[q] - CS[p] || CI[p] - CI[q]);
        const s2 = ord.map(q => CS[q]), i2 = ord.map(q => CI[q]);
        for (let q = 0; q < m2; q++){ CS[q] = s2[q]; CI[q] = i2[q]; }
      }
      /* 没有年份、最好的候选也只对上一个名字、而候选又不止一个：怎么比都是「说不准」，不必细比 */
      if (!ly && touched.length > 1 && cnt[CI[0]] < 2) return -1;
      /* 从高到低逐个过名字矛盾的检查，第一、第二名定了就停 */
      let best = -1, bs = -1, second = -1, bestNk = 0, nkSecond = 0;
      for (let r = 0; r < m2; r++){
        const mv = CS[r];
        if (best >= 0 && second >= 0 && mv < second) break;
        /* 第一名已定：两边年份都有时，分数更低的不可能并列；没有年份时，对上的名字更少的不改变结论 */
        if (best >= 0 && mv < bs && ly && RY[best]) break;
        if (best >= 0 && (!ly || !RY[best]) && cnt[CI[r]] < bestNk) break;
        const i = CI[r], nk = cnt[i], yf = mv - nk * 10;
        const rk = RK[i];
        if (strict && nk < Math.min(keys.length, rk.keys.length)) continue;   // 认错 id 的推断：能比的名字必须全对上
        const cw = nameClash(L, rk);
        if (cw && !(cw >= 8 && yf >= 3)) continue;                            // 名字矛盾：只有「长名字 + 同年」才照认
        if (best < 0){ best = i; bs = mv; bestNk = nk; }
        else if (second < 0){ second = mv; nkSecond = nk; }
        if (best >= 0 && second >= 0 && second < bs) break;
      }
      if (best < 0) return null;
      if (second === bs) return -1;
      if (!ly || !RY[best]){
        /* 没有年份可比：要么中文名和原名都对上、别的候选对上的名字更少；
           要么那个名字够长、整个索引里只有这一部叫它 */
        if (bestNk >= 2 && nkSecond < bestNk) return best;
        let strong = false;
        for (const k of keys){ const a = byKey.get(k); if (a && a.length === 1 && a[0] === best && keyWeight(k) >= 6) strong = true; }
        if (!strong || touched.length > 1) return -1;
      }
      return best;
    };
    for (let fi = 0; fi < lib.fz.length; fi++){
      const L = lib.fz[fi];
      /* [v6.3] 索引片名键：文件名切出来的键与建索引时论坛发布名的键相同 —— 直接查 movies.k。
         同名同原名的两部片（重拍、或前后两年的同名片）共用一个键，所以要求同年；差一年的交给下面的片名认领
         （那边会看有没有同名的另一部） */
      if (L.gk && L.y){
        let hit = -1;
        for (const g of L.gk){
          const id = movies.k[g];
          const i = id != null ? pos.get(Number(id)) : undefined;
          if (i != null && yearFit(L.y, RY[i], tv, true) === 3){ hit = i; break; }
        }
        if (hit >= 0){ if (!own[hit]){ own[hit] = 2; how[hit] = 2; who[hit] = fi; stat.key++; } continue; }
      }
      const i = pick(L, false);
      if (i === -1){ stat.amb++; if (stat.ambSample.length < 6) stat.ambSample.push(L.keys[0] + (L.y ? ' ' + L.y : '')); continue; }
      if (i == null || own[i]) continue;
      own[i] = 1; how[i] = 3; who[i] = fi; stat.name++;
    }
    for (const L of lib.idn){
      if (pos.has(L.id)) continue;                 // 库里那个 id 索引里有：两边说的是两部不同的片
      const i = pick(L, true);
      if (i == null || i === -1 || own[i]) continue;
      own[i] = 1; how[i] = 4; stat.conflict++;
      if (stat.conflictSample.length < 6) stat.conflictSample.push((rows[i].m[F.N] || rows[i].id) + ' ' + rows[i].y + '：库里 id ' + L.id + '，索引 id ' + rows[i].id);
    }
  }
  stat.ms = Date.now() - t0;
  const res = { own, how, who, stat };
  ownCache = { ver, lib, src: SRC.id, res };
  return res;
}
/** [v6.5] 详情页：这部片在片库里对上的是哪个文件、怎么对上的 */
function libWhy(movies, ver, lib, id){
  if (!lib) return null;
  const r = libOwn(movies, ver, lib);
  const i = catPos(movies, ver).get(Number(id));
  if (i == null) return null;
  const how = ['', 'id', 'key', 'name', 'conflict'][r.how[i]] || '';
  const L = r.who[i] >= 0 ? lib.fz[r.who[i]] : null;
  const file = how === 'id' ? ((lib.fileOf && lib.fileOf.get(Number(id))) || '') : (L ? L.file || '' : '');
  return { own: r.own[i], how, file };
}
/** 只有一部片在手时（详情 / 片单）：同一张判定表里查 */
function libHasId(movies, ver, lib, id){
  if (!lib) return 0;
  const r = libOwn(movies, ver, lib);
  const i = catPos(movies, ver).get(Number(id));
  return i == null ? (lib.ids.has(Number(id)) ? 2 : 0) : r.own[i];
}

const libStat = (env, l, os) => ({
  on: l ? 1 : 0,
  /* 总账模式报总账的来源地址，否则报 Stream —— 界面上「连的是谁」不能含糊 */
  host: (() => {
    const u = recvBase(env);
    const h = (l && l.src === 'received' && u) ? u.host : (env.STREAM_BASE || (u && u.host) || '');
    return String(h).replace(/^https?:\/\//, '').replace(/\/+$/, '');
  })(),
  src: l ? (l.src || 'scan') : (recvBase(env) ? 'received' : 'scan'),
  gen: l ? (l.gen || '') : '',
  via: l ? (l.via || '') : '',
  mine: l ? (l.mine || 0) : 0,
  missed: l ? (l.missed || 0) : 0,
  distrust: l ? (l.distrust || 0) : 0,
  pending: l ? (l.pending || 0) : 0,
  recvTs: l ? (l.recvTs || 0) : 0, liveTs: l ? (l.liveTs || 0) : 0, lts: l ? (l.lts || 0) : 0,
  part: l ? (l.part || 0) : 0, viaLedger: l ? (l.viaLedger || 0) : 0, viaTmdb: l ? (l.viaTmdb || 0) : 0,
  liveOn: liveOn(env) ? 1 : 0, streamKey: env.STREAM_KEY ? 1 : 0, err: l ? '' : libErr,
  files: l ? l.files : 0,
  ids: l ? l.ids.size : 0,
  fuzzy: l ? l.fuzzy : 0,
  tried: l ? l.tried : 0,
  todo: l ? l.todo : 0,
  /* scan=0 = 还没被 v5 认过一遍（多半是从 v4 搬过来的），界面要提示去扫一次 */
  fresh: l ? (l.scan ? 0 : 1) : 1,
  at: l ? l.at : 0, scan: l ? l.scan : 0,
  sample: l ? l.sample : [],
  /* 缺片检测这一轮的判定：id 确定 / 片名认领 / id 冲突认领 / 说不准 */
  match: os ? { exact: os.exact, key: os.key || 0, name: os.name, conflict: os.conflict, amb: os.amb,
                ambSample: os.ambSample, conflictSample: os.conflictSample, ms: os.ms } : null,
  hint: (env.RECV_BASE || env.STREAM_BASE) ? ''
        : '未配置 RECV_BASE / STREAM_BASE，不过滤库中已有',
});

/* ══════════════════════════════════════════════════════════════════
   查询
   ══════════════════════════════════════════════════════════════════ */
const RES_LV = { '480p':1, '720p':2, '1080i':3, '1080p':4, '2160p':5, '4320p':6 };
const resLevel = (q) => RES_LV[q] || 0;
const newest = (m) => { let x = 0; for (const y of (m[F.YS]||[])) if (y > x) x = y; return x || Number(m[F.Y]) || 0; };

/* ══════════════════════════════════════════════════════════════════
   预备表：每个索引版本只算一次
   ──────────────────────────────────────────────────────────────────
   v4 每来一个请求就把整张影片表遍历一遍，顺手对每部片做两次 norm()、
   一次加权评分，再对结果整排一次。三万部片的时候这就是纯 CPU 的大头，
   而 Free 计划给一次调用的 CPU 只有 10ms。
   v5 把"和查询无关的部分"提前算好挂在 isolate 上：归一化片名、加权分、
   最新年份、动态范围与分辨率等级各存一个数；四种排序各存一份下标数组。
   索引版本一变就整体作废，不会读到旧数据。此后每个请求只剩一次线性扫描
   加一次切片，不再排序。
   ══════════════════════════════════════════════════════════════════ */
let catCache = { ver: -1, rows: null, ord: null };
function catRows(movies, ver){
  if (catCache.ver === ver && catCache.rows) return catCache.rows;
  const rows = [];
  for (const id of Object.keys(movies.m || {})){
    const m = movies.m[id];
    rows.push({
      id: +id, m,
      n: null, o: null,                                 // 归一化按需算，见 rowNorm
      w: weighted(m), nw: newest(m),
      c: m[F.C] || 0, b: m[F.B] || 0,
      hb: m[F.HB] || 0,
      rb: m[F.RB] || resLevel(m[F.Q]),
      ys: m[F.YS] || [], y: Number(m[F.Y]) || 0,
      g: m[F.G] || [],
    });
  }
  catCache = { ver, rows, ord: {}, pos: null };
  return rows;
}
/** 影片 id → 行号（详情 / 片单 / 缺片判定共用），每个索引版本建一次 */
function catPos(movies, ver){
  catRows(movies, ver);
  if (catCache.pos) return catCache.pos;
  const pos = new Map();
  const rows = catCache.rows;
  for (let i = 0; i < rows.length; i++) pos.set(rows[i].id, i);
  catCache.pos = pos;
  return pos;
}
/* 片名归一化只在真正要用的时候做：搜索，或者片库里还有认不出来的条目。
   三万部片做六万次正则替换是纯 CPU，而 Free 计划一次调用只有 10ms —
   浏览路径上一次都不该发生。算过的挂在行上，同一个索引版本内复用。 */
function rowNorm(r){
  if (r.n === null){ const e = rowKeys(r); r.n = e.cn; r.o = e.co; }
  return r;
}
const CAT_CMP = {
  new:  (a,b) => b.nw - a.nw || b.id - a.id,
  vote: (a,b) => b.w - a.w || b.c - a.c,
  spec: (a,b) => b.b - a.b || b.w - a.w,
  hot:  (a,b) => b.c - a.c || b.w - a.w,
};
function catOrder(movies, ver, sort){
  const rows = catRows(movies, ver);
  const ord = catCache.ord || (catCache.ord = {});
  if (ord[sort]) return ord[sort];
  const cmp = CAT_CMP[sort] || CAT_CMP.new;
  const ix = rows.map((_, i) => i);
  ix.sort((a, b) => cmp(rows[a], rows[b]));
  ord[sort] = ix;
  return ix;
}
function relevance(r, nt){
  if (!nt) return 0;
  if (r.n === nt || r.o === nt) return 100;
  if (r.n.startsWith(nt)) return 82;
  if (r.o.startsWith(nt)) return 74;
  if (r.n.includes(nt)) return 58;
  if (r.o.includes(nt)) return 46;
  return 0;
}

/**
 * 目录查询。
 * dr  动态范围： '' 全部 / dv 杜比视界 / hdr HDR 及以上 / sdr 仅 SDR
 * qual 画质：    '' 全部 / uhd 4K 及以上 / hd 1080p 及以下（低质量）
 */
function queryCatalog(movies, q){
  const { text='', year='', genre='', min=6, sort='new', page=1, size=42,
          lib=null, own='hide', dr='', qual='' } = q;
  const nt = canon(text);
  const rows = catRows(movies, q.ver);
  /* 缺片判定整张表算好：每部片只剩一次数组读取 */
  const ownT = lib ? libOwn(movies, q.ver, lib).own : null;
  const ix = nt ? rows.map((_, i) => i) : catOrder(movies, q.ver, sort);
  const yr = year ? Number(year) : 0;
  const gn = genre ? Number(genre) : 0;

  const keep = [];
  let hidden = 0, dvN = 0, hdrN = 0, lowN = 0;
  for (let k = 0; k < ix.length; k++){
    const r = rows[ix[k]];
    if (min > 0 && (r.c < 50 || r.w < min)) continue;
    if (yr && !r.ys.includes(yr) && r.y !== yr) continue;
    if (gn && !r.g.includes(gn)) continue;
    /* 统计三个角标用的总数在筛选之前算 —— 界面上的数字才不会随筛选跳动 */
    if (r.hb === 7) dvN++;
    if (r.hb >= 3) hdrN++;                              // 与筛选口径一致：HDR 档含杜比视界
    if (r.rb && r.rb <= 4) lowN++;
    if (dr === 'dv'  && r.hb !== 7) continue;
    if (dr === 'hdr' && r.hb < 3) continue;
    if (dr === 'sdr' && r.hb >= 3) continue;
    if (qual === 'uhd' && r.rb < 5) continue;
    if (qual === 'hd'  && !(r.rb && r.rb <= 4)) continue;
    let rel = 0;
    if (nt){ rel = relevance(rowNorm(r), nt); if (!rel) continue; }
    /* 片库过滤放在最后一道：hidden 才等于"因为已经有了而被藏起来的数量"，
       前端拿它显示「已隐藏 N 部」，不至于让人以为索引丢片。 */
    const has = ownT ? ownT[ix[k]] : 0;
    if (has && own === 'hide'){ hidden++; continue; }
    if (!has && own === 'only') continue;
    keep.push(rel ? [ix[k], rel, has] : [ix[k], 0, has]);
  }
  if (nt) keep.sort((a,b) => b[1]-a[1] || rows[b[0]].w - rows[a[0]].w);

  const total = keep.length, off = (page-1)*size;
  return {
    total, hidden, page, pages: Math.ceil(total/size),
    counts: { dv: dvN, hdr: hdrN, low: lowN },
    items: keep.slice(off, off+size).map(([i,,has]) => {
      const r = rows[i], m = r.m;
      return { id:r.id, title:m[F.N], year:m[F.Y], poster:m[F.P],
        vote:m[F.T], votes:m[F.C], rels:m[F.R], res:m[F.Q], size:m[F.Z], sid:m[F.BT],
        hb:r.hb, rb:r.rb, own: has };
    }),
  };
}
/** 折叠近重复片源 */
function collapse(list){
  const out = [], byKey = new Map();
  for (const r of list){
    /* 剧集把季号也算进签名：不同季的规格常常一模一样，不带季号就会被
       折叠成一条，第一季直接从详情页消失 */
    const sig = (r.sn||0) + '|' + (r.group||'?') + '|' + r.spec + '|' + (r.mb ? Math.round(r.mb/512) : '?');
    const prev = byKey.get(sig);
    if (prev){ prev.dupes = (prev.dupes||1) + 1; continue; }
    byKey.set(sig, r); out.push(r);
  }
  return out;
}
function valuePick(items){
  const best = items[0];
  if (!best || !best.mb) return null;
  /* 剧集只在同一季里比：季与季的集数不同，体积本来就差一截，跨季比出来的
     "省 60%" 是假的 */
  const cand = items.filter(r => r !== best && r.mb && (best.sn||0) === (r.sn||0)
    && r.mb <= best.mb*0.5 && r.score >= best.score-24);
  if (!cand.length) return null;
  const v = cand.sort((a,b)=> b.score-a.score || a.mb-b.mb)[0];
  return { tid:v.tid, sid:v.sid, title:v.title, size:v.size, tags:v.tags,
    saved: Math.round((1 - v.mb/best.mb)*100) };
}
/** 读一部片的全部片源：只读 SP 记着的那几片，没记就退化为扫全年 */
async function movieRows(env, movies, id, ver, state){
  const mv = movies.m[id];
  if (!mv) return [];
  const all = [];
  for (const y of (mv[F.YS]||[])){
    const sp = mv[F.SP] && mv[F.SP][y];
    const list = Array.isArray(sp) && sp.length
      ? sp.slice(0, 16)
      : partRows(state, y).map((_, i) => i).slice(0, 16);
    for (const pi of list){
      const sh = await loadPart(env, state, y, pi);
      for (const r of shardRows(sh, id)) all.push(r);
    }
  }
  const seen = new Set(), uniq = [];
  for (const r of all){ if (seen.has(r.tid)) continue; seen.add(r.tid); uniq.push(r); }
  return uniq.sort(betterRow);
}
/** 补上展示层需要的原始标签（只对一部片解析，很便宜） */
function decorate(r){
  const pr = parseRelease(r.title);
  const out = { tid:r.tid, sid:sidOf(r.tid), title:r.title, score:r.score, spec:r.spec, mb:r.mb,
    size:pr.size, group:pr.group, tags:pr.tags, labels:specLabels(r.spec) };
  if (isTV()){ const sn = seasonOf(r.title); if (sn) out.sn = sn; }
  return out;
}

/* ══════════════════════════════════════════════════════════════════
   [v6.6] 导入清单 —— 一张表进来，库里没有的自动查好、挑好版本、放进片单
   ──────────────────────────────────────────────────────────────────
   一条（JSON 对象，或 CSV / TSV 的一行，表头同名）：
     tmdb_id   TMDB 编号（首选；电影 / 剧集各一套，见 type）
     title     片名（没有 tmdb_id 时按片名 + 年份在索引里找，找不到再问 TMDB）
     year      年份（同名消歧）            type     movie / tv（默认 movie）
     season    剧集：只要某一季            res      想要的分辨率：2160p / 1080p / 720p
     hdr       dv / hdr / sdr（默认不挑）  max_gb   体积上限（GB）
     prefer    remux / bluray / web        note     备注（原样带回）
   每条的结果：add（库里没有、论坛有 → 放进片单，等确认后下载）· owned（库里已有，跳过）·
   notfound（论坛还没有）· ambiguous（片名对上不止一部，给出候选让人挑）· invalid · dup。
   只读索引、不写 R2；TMDB 只在「片名在索引里找不到」时问，用自带的小配额。
   ══════════════════════════════════════════════════════════════════ */
const IMPORT_MAX = 30;            // 一次调用最多处理几条（前端按 12 条一批发）
const RES_WANT = { '4320p': 6, '8k': 6, '2160p': 5, '4k': 5, 'uhd': 5, '1080p': 4, '1080': 4, '1080i': 3, '720p': 2, '720': 2, '480p': 1 };
const SRC_WANT = { remux: 7, bluray: 6, 'blu-ray': 6, web: 5, 'web-dl': 5, webrip: 3 };
/** 表头 / 键名宽松：大小写、「tmdb_id(1)」这种带序号的、tmbd 这种手误都认 */
function importKeys(x){
  const o = {};
  for (const k0 of Object.keys(x)){
    const k = String(k0).trim().toLowerCase().replace(/\s*[(（]\s*\d+\s*[)）]\s*$/, '').replace(/^tmbd/, 'tmdb').replace(/[\s-]+/g, '_');
    if (!(k in o)) o[k] = x[k0];
  }
  return o;
}
function importIn(x0, i){
  if (!x0 || typeof x0 !== 'object' || Array.isArray(x0)) return { i, bad: '这一条不是「键: 值」的对象' };
  const x = importKeys(x0);
  const pick = (...ks) => { for (const k of ks){ const v = x[k]; if (v != null && typeof v !== 'object' && String(v).trim() !== '') return v; } return null; };
  const idRaw = pick('tmdb_id', 'tmdb', 'tmdbid', 'id');
  const idS = idRaw == null ? '' : String(idRaw).trim().replace(/^(?:movie|tv)\//i, '');
  const id = /^\d{1,9}$/.test(idS) ? Number(idS) : 0;
  if (idS && !id) return { i, bad: 'tmdb_id「' + idS.slice(0, 20) + '」不是数字' };
  const en = String(pick('en', 'original_title', 'original', 'orig', 'english', '英文名', '原名') || '').trim().slice(0, 160);
  const title = String(pick('title', 'name', '片名', '中文名', 'cn') || en).trim().slice(0, 160);
  const ty = String(pick('type', 'kind', '类型') || '').trim();
  /* 没写 type 就跟着这次调用的源走；写了才拿来核对 */
  const type = !ty ? '' : /^(tv|series|show|剧集|电视剧|剧)$/i.test(ty) ? 'tv' : 'movie';
  const sn = Number(pick('season', '季'));
  const res = RES_WANT[String(pick('res', 'resolution', 'quality', '分辨率') || '').trim().toLowerCase()] || 0;
  const hdrS = String(pick('hdr', 'dr', '动态范围') || '').trim().toLowerCase();
  const hdr = /^(dv|dovi|dolby\s*vision|杜比视界)$/.test(hdrS) ? 'dv' : /^hdr/.test(hdrS) ? 'hdr' : hdrS === 'sdr' ? 'sdr' : '';
  const mg = Number(pick('max_gb', 'maxgb', 'max_size', 'size_gb', '体积上限'));
  const prefer = SRC_WANT[String(pick('prefer', 'source', 'src', '来源') || '').trim().toLowerCase()] || 0;
  const note = String(pick('note', 'notes', '备注') || '').slice(0, 200);
  if (!id && !title) return { i, bad: '缺 tmdb_id 和 title（至少要有一个）' };
  return { i, id, title, en: en !== title ? en : '', year: yearOf(pick('year', '年份', 'release_year')) || 0, type,
           season: sn > 0 && sn < 100 ? Math.floor(sn) : 0, res, hdr, maxMb: mg > 0 ? mg * 1024 : 0, prefer, note };
}
/** 按偏好挑版本。rows 已按「最好」排好；全都不满足时退而求其次（并说明） */
function importPick(rows, q){
  let cand = rows.filter(r => !q.season || (r.sn || 0) === q.season);
  if (!cand.length) return { r: null, why: q.season ? '没有第 ' + q.season + ' 季的片源' : '没有片源' };
  const fit = cand.filter(r => !q.maxMb || !r.mb || r.mb <= q.maxMb);
  let why = '';
  if (!fit.length){ why = '没有 ' + Math.round(q.maxMb / 1024) + 'GB 以内的，取最小的'; cand = cand.slice().sort((a, b) => (a.mb || 9e9) - (b.mb || 9e9)).slice(0, 1); }
  else cand = fit;
  const sc = (r) => {
    const res = r.spec & 15, src = (r.spec >> 4) & 15, hdr = (r.spec >> 8) & 15;
    let s = r.score || 0;
    if (q.res) s += res === q.res ? 60 : (res > q.res ? 10 - (res - q.res) * 8 : -30 * (q.res - res));
    if (q.hdr === 'dv') s += hdr === 7 ? 40 : (hdr >= 3 ? 10 : -10);
    else if (q.hdr === 'hdr') s += hdr >= 3 ? 30 : -10;
    else if (q.hdr === 'sdr') s += hdr < 3 ? 30 : -20;
    if (q.prefer) s += src === q.prefer ? 25 : (Math.abs(src - q.prefer) <= 1 ? 8 : 0);
    return s;
  };
  const best = cand.slice().sort((a, b) => sc(b) - sc(a) || betterRow(a, b))[0];
  if (q.res && (best.spec & 15) !== q.res && !why) why = '没有 ' + SPEC.res[q.res] + '，取最接近的';
  else if (q.hdr === 'dv' && ((best.spec >> 8) & 15) !== 7 && !why) why = '没有杜比视界版';
  return { r: best, why };
}
let IMPORT_IDX = { ver: -1, src: '', map: null };
/** 索引里按片名找：canon 键全等 + 年份契合。唯一最好 → 这部；并列 → 说不准（交给人挑） */
function importByTitle(rows, q, tv){
  const keys = canonKeys([q.title, q.en].filter(Boolean));
  const cnt = new Map();
  for (const k of keys) for (const i of IMPORT_IDX.map.get(k) || []) cnt.set(i, (cnt.get(i) || 0) + 1);
  const c = [];
  for (const [i, n] of cnt){
    const yf = yearFit(q.year, rows[i].y, tv, false);
    if (q.year && yf < 2) continue;                   // 写了年份就得对得上（差一年以内）
    /* 没写年份时，太短太泛的片名（「英雄」）不单独认 —— 交给 TMDB 去挑 */
    if (!q.year && !keys.some(k => keyWeight(k) >= 6)) continue;
    c.push({ i, s: n * 10 + Math.max(0, yf) });
  }
  if (!c.length) return null;
  c.sort((a, b) => b.s - a.s || (rows[b.i].c || 0) - (rows[a.i].c || 0));
  const top = c.filter(x => x.s === c[0].s);
  if (top.length > 1) return { amb: top.slice(0, 5).map(x => rows[x.i]) };
  return { row: rows[c[0].i] };
}
async function importItems(env, list, ctx){
  const t0 = Date.now();
  const { movies, state } = await loadIndex(env);
  const ver = state.ver || 0;
  const lib = await libLoad(env, ctx).catch(() => null);
  const rows = catRows(movies, ver), tv = isTV(), kind = tv ? 'tv' : 'movie';
  if (IMPORT_IDX.ver !== ver || IMPORT_IDX.src !== SRC.id || !IMPORT_IDX.map){
    const map = new Map();
    for (let i = 0; i < rows.length; i++) for (const k of rowKeys(rows[i]).keys){ const a = map.get(k); if (a) a.push(i); else map.set(k, [i]); }
    IMPORT_IDX = { ver, src: SRC.id, map };
  }
  const arr = Array.isArray(list) ? list : [];
  const items = arr.slice(0, IMPORT_MAX).map((x, i) => importIn(x, i));
  const out = [], seen = new Set(), ask = [];
  const C = { env, movies, ver, state, lib, seen, t0 };
  for (const q of items){
    if (q.bad){ out.push({ k: q.i, status: 'invalid', reason: q.bad }); continue; }
    if (q.type && q.type !== kind){ out.push({ k: q.i, status: 'invalid', title: q.title, reason: '这条是' + (q.type === 'tv' ? '剧集' : '电影') + '，要在「' + (q.type === 'tv' ? '剧集' : '电影') + '」那边导入' }); continue; }
    let id = q.id && movies.m[q.id] ? q.id : 0;
    if (!id && q.title){
      const r = importByTitle(rows, q, tv);
      /* 片名对上好几部 → 交给人挑。给了 tmdb_id 却不在索引里、片名倒对上一部：
         编号是人给的、更可信，可能是论坛还没有这部（同名的另一部）、也可能是索引认错了 —— 也交给人确认，不自动加 */
      const amb = r && (r.amb || (q.id ? [r.row] : null));
      if (amb){
        out.push({ k: q.i, status: 'ambiguous', title: q.title, year: q.year || '', note: q.note,
          reason: r.amb ? '片名对上 ' + amb.length + ' 部，挑一部' : '索引里没有 TMDB ' + q.id + '，但片名对上了这部 —— 是同一部就点它',
          cands: amb.map(x => ({ id: x.id, title: x.m[F.N], year: x.m[F.Y], poster: x.m[F.P], own: lib ? libHasId(movies, ver, lib, x.id) : 0 })) });
        continue;
      }
      if (r) id = r.row.id;
    }
    if (!id){
      if (q.title && !q.id){ ask.push(q); continue; }     // 索引里按名字找不到：问 TMDB 拿编号再查一次
      out.push({ k: q.i, status: 'notfound', fs: 1, title: q.title, year: q.year || '', note: q.note, tmdb: q.id, reason: '索引里没有 TMDB ' + q.id + '（' + (tv ? '剧集版块只收已完结的' : '电影只收近几年') + '），去论坛搜索' });
      continue;
    }
    out.push(await importOne(C, q, id));
  }
  let tmdbN = 0;
  if (ask.length){
    const envT = Object.assign(Object.create(env), { __sub: { n: 0, max: 30 }, __r429: 0 });
    const lat = (q) => q.en || (/[\u3400-\u9fff]/.test(q.title) ? '' : q.title);
    const groups = ask.map(q => ({ key: 'imp' + q.i, cn: q.title, latin: lat(q), years: q.year ? [String(q.year)] : [], hint: q.year || 0, title: q.title }));
    let res = new Map();
    try { res = await matchBatch(envT, groups, { soft: true }); }
    catch (e){ trace('tmdb', '导入清单：TMDB 没查成（' + (e.message || e) + '）', { lvl: 'err', ch: 'match' }); }
    for (const q of ask){
      let r = res.get('imp' + q.i);
      /* 认定规则要求「片名对得上」—— 清单里写的却常是别名 / 港台译名（TMDB 按别名搜得到，返回的标题却是另一个）。
         人已经明说了要哪部：直接拿搜索结果里「论坛有的」那几部来对，只有一部就是它，好几部就交给人挑 */
      if (r && r.miss && envT.__sub.max - envT.__sub.n > 0){
        const p = { query: q.title, include_adult: 'false' };
        if (q.year && !tv) p[SRC.yparam] = q.year;
        const j = await tmdb(envT, '/search/' + SRC.kind, p).catch(() => null);
        const got = ((j && j.results) || []).filter(h => movies.m[h.id] && (!q.year || yearFit(q.year, yearOf(h.release_date || h.first_air_date), tv, false) >= 2));
        if (got.length === 1) r = { hit: got[0], via: 'TMDB 按别名搜到' };
        else if (got.length > 1){
          out.push({ k: q.i, status: 'ambiguous', title: q.title, year: q.year || '', note: q.note, reason: 'TMDB 按这个名字搜到 ' + got.length + ' 部论坛有的，挑一部',
            cands: got.slice(0, 5).map(h => { const m = movies.m[h.id]; return { id: h.id, title: m[F.N], year: m[F.Y], poster: m[F.P], own: lib ? libHasId(movies, ver, lib, h.id) : 0 }; }) });
          continue;
        }
      }
      const id = r && r.hit ? r.hit.id : 0;
      if (id && movies.m[id]){ out.push(await importOne(C, q, id, r.via)); continue; }
      out.push({ k: q.i, status: 'notfound', fs: 1, title: q.title, year: q.year || '', note: q.note, tmdb: id || 0,
        retry: !id && r == null ? 1 : 0,
        reason: id ? '论坛还没有这部（TMDB 认出来是 ' + id + (r.hit.title || r.hit.name ? '「' + (r.hit.title || r.hit.name) + '」' : '') + '）'
                   : (r == null ? 'TMDB 这次没查成，稍后再导一次' : '索引和 TMDB 里都没找到这个片名') });
    }
    tmdbN = envT.__sub.n;
  }
  out.sort((a, b) => a.k - b.k);
  return { items: out, src: SRC.id, n: items.length, more: Math.max(0, arr.length - items.length), max: IMPORT_MAX,
           lib: lib ? 1 : 0, tmdb: tmdbN, ms: Date.now() - t0 };
}
/* ══════════ [v6.7] 剧集只要整季：全 N 集 / 全集 / 完结，不要单集、不要「第 123-127 集」 ══════════ */
const PACK_FULL = /全\s*[0-9一二三四五六七八九十百零两]+\s*[集话話期回]|全集|全季|完结|完結|\bCOMPLETE\b/i;
const PACK_PART = /第\s*\d+\s*[-~～至到]\s*\d+\s*[集话話期回]|第\s*\d+\s*[集话話期回]|第\s*\d{6,}|S\d{1,2}E\d{1,3}|\bEP?\d{1,3}\b/i;
/** 一条剧集帖：full = 整季（全 N 集 / 全集 / 完结）· part = 单集 / 一段 / 连载中 · unk = 标题里没写 */
function packOf(t){
  t = String(t || '');
  if (/更新至|更至|连载中|未完结|未完結/.test(t)) return 'part';
  if (PACK_FULL.test(t)) return 'full';
  if (PACK_PART.test(t)) return 'part';
  return /共\s*\d+\s*[集话話]/.test(t) ? 'full' : 'unk';
}
const packLabel = (t) => ((String(t).match(/全\s*[0-9一二三四五六七八九十百]+\s*[集话話期回]|全集|完结/) || [])[0] || '').replace(/\s+/g, '');
/** 单集 / 一段的集数范围（「第 123-127 集」→ 123..127，「更新至第 12 集」→ 12..12） */
function epRange(t){
  t = String(t || '');
  let m = t.match(/第\s*(\d+)\s*[-~～至到]\s*(\d+)\s*[集话話期回]/);
  if (m) return { a: +m[1], b: +m[2] };
  m = t.match(/S\d{1,2}E(\d{1,3})(?:\s*-\s*E?(\d{1,3}))?/i);
  if (m) return { a: +m[1], b: +(m[2] || m[1]) };
  m = t.match(/第\s*(\d{1,4})\s*[集话話期回]/);
  if (m) return { a: +m[1], b: +m[1] };
  return { a: 0, b: 0 };
}
/**
 * 剧集挑版本：只在同一季里挑；整季包（全 N 集）优先，其次标题没写集数的；只剩单集 / 一段时不加，交回「未完结」
 * 没指定季就挑论坛上最新的那一季。rows 是 decorate 过的行（带 title / sn / spec / mb / labels）
 */
function tvPick(rows, q){
  const R = rows.map(r => ({ r, pk: packOf(r.title), sn: r.sn || 1 }));
  if (!R.length) return { st: 'none', why: '没有片源' };
  const seasons = [...new Set(R.map(x => x.sn))].sort((a, b) => b - a);
  const want = q.season || seasons[0];
  const inS = R.filter(x => x.sn === want);
  const sTag = (seasons.length > 1 || want > 1) ? '第 ' + want + ' 季' : '';
  if (!inS.length) return { st: 'none', why: '没有第 ' + want + ' 季的片源' };
  const best = (lst) => importPick(lst.map(x => x.r).sort(betterRow), { ...q, season: 0 });
  const full = inS.filter(x => x.pk === 'full'), unk = inS.filter(x => x.pk === 'unk');
  if (full.length || unk.length){
    const p = best(full.length ? full : unk);
    return { st: 'add', r: p.r, season: want, pack: packLabel(p.r.title) || '整季',
             why: [sTag, p.why, full.length ? '' : '标题没写「全集」，按整季包算'].filter(Boolean).join('；') };
  }
  const part = inS.map(x => ({ ...x, e: epRange(x.r.title) }))
    .sort((a, b) => (b.e.b - a.e.b) || ((b.e.b - b.e.a) - (a.e.b - a.e.a)) || betterRow(a.r, b.r));
  const top = part[0].e;
  const latest = best(part.filter(x => x.e.b === top.b && x.e.a === top.a)).r;
  const olderS = seasons.find(n => n < want && R.some(x => x.sn === n && x.pk === 'full'));
  const older = olderS ? { season: olderS, r: best(R.filter(x => x.sn === olderS && x.pk === 'full')).r } : null;
  return { st: 'incomplete', season: want, latest, older, ep: top,
           why: (sTag ? sTag : '') + '论坛还没有全集，最新到' + (top.b ? '第 ' + (top.a && top.a !== top.b ? top.a + '-' : '') + top.b + ' 集' : '单集') };
}
/** 挑中的一行 → 片单记录（锁定这个版本） */
function recOf(r, extra){
  const pk = isTV() ? packLabel(r.title) : '';
  return { sid: r.sid, res: specRes(r.spec), size: r.size, hb: (r.spec >> 8) & 15, rb: r.spec & 15,
           label: r.labels.slice(0, 4).concat(pk ? [pk] : []).join(' · '), ...extra };
}
/** 剧集「未完结」时给人挑的两个按钮：最新的那一段 / 上一季的全集 */
function partCands(p, base){
  const c = [];
  if (p.latest) c.push({ label: '仍然加入最新的（' + (p.ep && p.ep.b ? '第 ' + (p.ep.a && p.ep.a !== p.ep.b ? p.ep.a + '-' : '') + p.ep.b + ' 集' : '单集') + '）', rec: { ...base, ...recOf(p.latest) } });
  if (p.older) c.push({ label: '加入第 ' + p.older.season + ' 季全集', rec: { ...base, ...recOf(p.older.r) } });
  return c;
}
async function importOne(C, q, id, via){
  const m = C.movies.m[id];
  const base = { k: q.i, id, title: m[F.N], year: m[F.Y], poster: m[F.P], note: q.note };
  if (via) base.via = via;
  if (C.seen.has(id)) return { ...base, status: 'dup', reason: '清单里前面已经有这部' };
  C.seen.add(id);
  if (C.lib){
    const w = libWhy(C.movies, C.ver, C.lib, id);
    if (w && w.own) return { ...base, status: 'owned', own: w.own, file: w.file || '', reason: w.own === 2 ? '库中已有' : '库里很可能已有（片名年份对上）' };
  }
  /* 剧集：不管有没有写偏好，都要在全部片源里挑整季包（默认最佳片源可能是单集） */
  if (isTV()){
    if (Date.now() - C.t0 > 20000) return { ...base, status: 'notfound', retry: 1, reason: '这一批太大，没来得及挑版本，重试一次' };
    const p = tvPick((await movieRows(C.env, C.movies, id, C.ver, C.state)).map(decorate), q);
    if (p.st === 'none') return { ...base, status: 'notfound', reason: p.why };
    const card = { id, title: m[F.N], year: m[F.Y], poster: m[F.P] };
    if (p.st === 'incomplete') return { ...base, status: 'incomplete', reason: p.why, cands: partCands(p, card) };
    return { ...base, status: 'add', ...recOf(p.r), reason: p.why };
  }
  let sid = m[F.BT], res = m[F.Q], size = m[F.Z], hb = m[F.HB] || 0, rb = m[F.RB] || resLevel(m[F.Q]), label = '', why = '';
  if (q.res || q.hdr || q.maxMb || q.prefer){
    if (Date.now() - C.t0 > 15000) why = '这一批太大，没来得及按偏好挑，先放默认版本';
    else {
      const p = importPick((await movieRows(C.env, C.movies, id, C.ver, C.state)).map(decorate), q);
      if (!p.r) return { ...base, status: 'notfound', reason: p.why };
      const r = p.r;
      sid = r.sid; res = specRes(r.spec); size = r.size; hb = (r.spec >> 8) & 15; rb = r.spec & 15;
      label = r.labels.slice(0, 4).join(' · '); why = p.why;
    }
  }
  if (!sid) return { ...base, status: 'notfound', reason: '这部片没有可用的片源' };
  return { ...base, status: 'add', sid, res, size, hb, rb, label, reason: why };
}

/* ══════════════════════════════════════════════════════════════════
   [v6.7] 论坛搜索：索引里没有的（剧集版块只收「已完结」、电影只收近几年），直接去论坛的搜索页按片名搜
   ──────────────────────────────────────────────────────────────────
   search.php?mod=forum&srchtxt=<GBK>&searchsubmit=yes → 302 到 searchid=… 的结果页。空格在 Discuz 里是 AND，
   所以片名里的标点一律换成空格（「降世神通：七净土」→「降世神通 七净土」，论坛写成全角半角都搜得到）。
   论坛限制搜索频率（「您在 N 秒内只能进行一次搜索」）：认出来就把秒数交回，浏览器等够了再搜下一条。
   搜到的帖子：片名（中文名 / 原名 / TMDB 译名）要对得上、年份不能早于首播，剧集只要整季包。
   同一个关键词 30 分钟内不重搜（Cache API）。
   ══════════════════════════════════════════════════════════════════ */
const FS_TTL = 1800, FS_PAGES = 3;
function fsKw(name){
  return String(name || '').replace(/[：:·・,，.。!！?？\-—–_/\\()（）\[\]【】「」『』"'“”‘’~～;；]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 40);
}
/** 论坛的「搜太快了」：返回要等的秒数，没有就 0 */
function fsWait(html){
  const m = html.match(/(\d+)\s*秒内只能进行一次搜索/);
  if (m) return Math.min(180, Math.max(1, +m[1]));
  if (/最多响应搜索请求/.test(html)) return 30;
  return 0;
}
/** 搜索结果页 → [{ tid, title, fid }]（Discuz 的 li.pbw；结构对不上时退回扫所有帖子链接） */
function parseSearch(html){
  const out = [], seen = new Set();
  const push = (tid, raw, fid) => {
    tid = Number(tid);
    if (!tid || seen.has(tid)) return;
    const title = strip(raw);
    if (title.length < 2) return;
    seen.add(tid); out.push({ tid, title, fid: Number(fid) || 0 });
  };
  for (const b0 of html.split(/<li[^>]*class="pbw"/i).slice(1)){
    const b = b0.split(/<\/li>/i)[0];
    const a = b.match(/<h3[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/i);
    if (!a) continue;
    const tid = (a[1].match(/tid=(\d+)/) || a[1].match(/thread-(\d+)-/) || b0.match(/^[^>]*id="(\d+)"/) || [])[1];
    const fid = (b.match(/forumdisplay&(?:amp;)?fid=(\d+)/) || b.match(/forum-(\d+)-\d+\.html/) || [])[1];
    push(tid, a[2], fid);
  }
  if (!out.length && /searchid=|相关内容/.test(html)){
    const re = /<a[^>]+href="[^"]*(?:viewthread&(?:amp;)?tid=|thread-)(\d+)[^"]*"[^>]*>([\s\S]*?)<\/a>/gi;
    let m;
    while ((m = re.exec(html))) push(m[1], m[2], 0);
  }
  return out;
}
const fsPath = (env, loc) => /^https?:/i.test(loc) ? loc : String(loc).replace(/^\/+/, '');
async function forumSearch(env, kw){
  const ck = 'https://fsearch.cuven/' + SRC.id + '/' + encodeURIComponent(kw);
  try { const hit = await caches.default.match(ck); if (hit) return { ...(await hit.json()), cached: 1 }; } catch {}
  let r = await authed(env, 'search.php?mod=forum&srchtxt=' + gbkEncode(kw) + '&searchsubmit=yes');
  for (let hop = 0; r.status >= 300 && r.status < 400 && hop < 3; hop++){
    const loc = r.headers.get('location') || '';
    if (!loc || /action=login/.test(loc)) break;
    r = await authed(env, fsPath(env, loc));
  }
  const html = decodeHTML(await r.arrayBuffer(), r);
  const wait = fsWait(html);
  if (wait){ const e = new Error('论坛限制搜索频率：' + wait + ' 秒一次'); e.wait = wait; throw e; }
  if (loginWall(html) && !/searchid=|相关内容/.test(html)) throw new Error('论坛搜索要登录或没有权限');
  if (/搜索(功能)?已关闭|未开启搜索/.test(html)) throw new Error('论坛关闭了搜索');
  const list = parseSearch(html);
  const total = Number((html.match(/相关内容\s*(\d+)\s*个/) || [])[1]) || list.length;
  const sidm = html.match(/searchid=(\d+)/);
  /* 翻页看的是同一次搜索的缓存结果，不算新的搜索、不受频率限制 */
  for (let pg = 2; pg <= FS_PAGES && sidm && list.length < total; pg++){
    const r2 = await authed(env, 'search.php?mod=forum&searchid=' + sidm[1] + '&orderby=lastpost&ascdesc=desc&searchsubmit=yes&page=' + pg);
    const more = parseSearch(decodeHTML(await r2.arrayBuffer(), r2));
    let add = 0;
    for (const x of more) if (!list.some(y => y.tid === x.tid)){ list.push(x); add++; }
    if (!add) break;
  }
  const out = { kw, total, list };
  try { await caches.default.put(ck, new Response(JSON.stringify(out), { headers: { 'content-type': 'application/json', 'cache-control': 'max-age=' + FS_TTL } })); } catch {}
  return out;
}
/** 搜到的帖子里挑「就是这部」的：片名键全等，或够长的一个几乎包含另一个；年份不能早于首播（电影差一年以内） */
function fsMatch(list, names, year){
  const tv = isTV(), other = tv ? SRC_MOVIE.fid : SRC_TV.fid;
  const want = canonKeys(names.filter(Boolean));
  const out = [];
  for (const x of list){
    if (x.fid && x.fid === other) continue;
    const pt = parseTitle(x.title);
    const ks = canonKeys([pt.cn, pt.latin].filter(Boolean));
    let ok = false;
    for (const a of ks) for (const b of want){
      if (a === b){ ok = true; continue; }
      /* 一个包含另一个：短的够长（三个汉字 / 六个字母），长的最多多出两个汉字（「篇」「剧场版」）或三个字母 ——
         「夜曲」≠「夜曲之歌」，「Nocturne」≠「Nocturne Song」 */
      const sh = a.length < b.length ? a : b, lo = a.length < b.length ? b : a;
      if (keyWeight(sh) >= 6 && lo.includes(sh) && lo.length - sh.length <= (keyKind(sh) === 'cjk' ? 2 : 3)) ok = true;
    }
    if (!ok) continue;
    const ys = (pt.years || []).map(Number).filter(Boolean);
    if (year && ys.length && !(tv ? ys.some(y => y >= year - 1) : ys.some(y => Math.abs(y - year) <= 1))) continue;
    out.push(x);
  }
  return out;
}
async function fsearchItem(env, item, kwOver, ctx){
  const q = importIn(item, 0);
  if (q.bad) return { status: 'invalid', reason: q.bad };
  const lib = await libLoad(env, ctx).catch(() => null);
  if (q.id && lib && lib.ids && lib.ids.has(q.id)) return { status: 'owned', id: q.id, title: q.title, own: 2, reason: '库中已有（TMDB 编号相同）' };
  /* TMDB 拿译名、原名、首播年、海报：片名对不上时多一个名字可比，年份用来排除同名的老片 */
  let d = null;
  if (q.id){
    const envT = Object.assign(Object.create(env), { __sub: { n: 0, max: 6 }, __r429: 0 });
    d = await tmdb(envT, '/' + SRC.kind + '/' + q.id, {}).catch(() => null);
  }
  const zh = d ? (d.name || d.title || '') : '', orig = d ? (d.original_name || d.original_title || '') : '';
  const year = yearOf(d && (d.first_air_date || d.release_date)) || q.year || 0;
  const cjk = (x) => /[㐀-鿿]/.test(x || '');
  const names = [q.title, zh, orig, q.en].filter(Boolean);
  const kws = [...new Set([q.title, zh].filter(cjk).concat([q.title, zh, q.en, orig].filter(Boolean)).map(fsKw).filter(k => k.length >= 2))];
  const kw = kwOver && kws.includes(kwOver) ? kwOver : kws[0];
  if (!kw) return { status: 'notfound', reason: '没有能拿去搜的片名' };
  const card = { id: q.id || 0, title: zh && cjk(zh) ? zh : (q.title || zh), year: year || '', poster: d ? (d.poster_path || '') : '', note: q.note };
  const S = await forumSearch(env, kw);
  const hit = fsMatch(S.list, names, year);
  const next = kws[kws.indexOf(kw) + 1];
  if (!hit.length){
    if (next) return { status: 'again', again: next, searched: S.cached ? 0 : 1, reason: '「' + kw + '」没搜到对得上的，换「' + next + '」再搜' };
    return { ...card, status: 'notfound', searched: S.cached ? 0 : 1,
      reason: S.list.length ? '论坛搜「' + kw + '」有 ' + S.total + ' 条，片名年份都对不上' : '论坛搜「' + kw + '」没有结果' };
  }
  const rows = hit.map(x => decorate(toRow(x.tid, x.title))).sort(betterRow);
  const ext = { ext: 1, via: '论坛搜索「' + kw + '」' };
  const cid = q.id || -rows[0].tid;              // 没有 TMDB 编号：拿帖子号当片单里的编号（负数，不会撞上 TMDB 编号）
  if (isTV()){
    const p = tvPick(rows, q);
    if (p.st === 'incomplete') return { ...card, id: cid, ...ext, status: 'incomplete', searched: S.cached ? 0 : 1, reason: p.why, cands: partCands(p, { ...card, id: cid, ext: 1 }) };
    if (p.st !== 'add') return { ...card, status: 'notfound', searched: S.cached ? 0 : 1, reason: p.why };
    return { ...card, id: cid, ...ext, status: 'add', searched: S.cached ? 0 : 1, ...recOf(p.r), reason: p.why };
  }
  const p = importPick(rows, q);
  if (!p.r) return { ...card, status: 'notfound', searched: S.cached ? 0 : 1, reason: p.why };
  return { ...card, id: cid, ...ext, status: 'add', searched: S.cached ? 0 : 1, ...recOf(p.r), reason: p.why };
}

/* ══════════ 主题 / 种子 ══════════ */
async function threadDetail(env, tid, ctx){
  const k = kkey(env,'t:'+tid);
  const hit = await jget(env,k);
  if (hit) return hit;
  const r = await authed(env,'forum.php?mod=viewthread&tid='+encodeURIComponent(tid));
  const buf = await r.arrayBuffer();
  if (buf.byteLength < 600){ govPenalize('帖子页空响应'); throw new Error('帖子页返回空响应（可能被限速）'); }
  const html = decodeHTML(buf, r);
  if (loginWall(html)) throw new Error('帖子需要登录或权限不足（登录墙）');
  govReward();
  const attachments = [];
  const re = /<a href="forum\.php\?mod=attachment&amp;aid=([^"]+)"[^>]*>([\s\S]*?)<\/a>/g;
  let m;
  while ((m = re.exec(html))){
    const raw = strip(m[2]);
    attachments.push({ aid:m[1],
      filename: raw.replace(/\s*\([\d.]+\s*[KMG]B\)\s*$/i,'').trim(),
      filesize: raw.match(/\(([\d.]+\s*[KMG]B)\)\s*$/i)?.[1]||null,
      isTorrent: /\.torrent\b/i.test(raw) });
  }
  const text = ents(html.replace(/<br\s*\/?>/gi,'\n').replace(/<[^>]+>/g,' '));
  const pick = (rx)=>text.match(rx)?.[1]?.trim()||null;
  const out = { tid: Number(tid), sid: sidOf(tid),
    imdb: pick(/imdb\.com\/title\/(tt\d{6,})/i),
    doubanScore: pick(/豆瓣评分\s*([\d.]+\/10)/),
    fileSize: pick(/◎文件大小\s*([^\n]{2,40})/),
    attachments,
    magnets: [...new Set(text.match(/magnet:\?xt=urn:btih:[0-9a-zA-Z]{32,40}/g)||[])].slice(0,10) };
  const w = jput(env,k,out,TTL.thread).catch(()=>{});
  ctx ? ctx.waitUntil(w) : await w;
  return out;
}

/* [v6] 种子（bencode）解析。
   v5 是「在字节里找第一个 4:info / 4:name」：文件名、注释里出现这几个字就会认错位置，
   算出来的 btih 是错的（磁力链接打不开）；遇到被截断的种子，整数那一支会一直往后读、死循环，
   直到平台按 CPU 超限掐掉进程。这里换成真正的逐层解析：每一步都检查边界、层数有上限，
   只在顶层字典里找 info，info 字典里找 name（优先 name.utf-8）。 */
function bdecode(b){
  const N = b.length;
  let p = 0, depth = 0;
  const fail = (why) => { const e = new Error('bencode 解析失败：' + why + '（第 ' + p + ' 字节）'); throw e; };
  const str = () => {
    let n = 0, k = 0;
    while (p < N && b[p] >= 0x30 && b[p] <= 0x39){ n = n * 10 + (b[p] - 0x30); p++; if (++k > 10) fail('字符串长度太长'); }
    if (k === 0 || p >= N || b[p] !== 0x3a) fail('字符串格式不对');
    p++;
    if (p + n > N) fail('字符串越界（种子被截断）');
    const s0 = p; p += n;
    return [s0, p];
  };
  const val = () => {
    if (p >= N) fail('意外结束（种子被截断）');
    const c = b[p];
    if (c === 0x69){                                   // i…e
      p++;
      const s0 = p;
      while (p < N && b[p] !== 0x65){ if (p - s0 > 24) fail('整数太长'); p++; }
      if (p >= N) fail('整数没有结尾（种子被截断）');
      p++;
      return { t: 'i', s: s0 - 1, e: p };
    }
    if (c === 0x6c || c === 0x64){                     // l…e / d…e
      if (++depth > 64) fail('嵌套太深');
      const s0 = p; p++;
      const kids = [];
      while (true){
        if (p >= N) fail('列表 / 字典没有结尾（种子被截断）');
        if (b[p] === 0x65){ p++; break; }
        if (c === 0x64){ const k = str(); kids.push(k, val()); }
        else kids.push(val());
      }
      depth--;
      return { t: c === 0x64 ? 'd' : 'l', s: s0, e: p, kids };
    }
    if (c >= 0x30 && c <= 0x39){ const [s0, e] = str(); return { t: 's', s: s0, e }; }
    return fail('未知类型 0x' + c.toString(16));
  };
  const root = val();
  if (root.t !== 'd') fail('顶层不是字典');
  return root;
}
const bkey = (b, k) => new TextDecoder().decode(b.subarray(k[0], k[1]));
function bget(b, dict, name){
  if (!dict || dict.t !== 'd') return null;
  for (let i = 0; i < dict.kids.length; i += 2) if (bkey(b, dict.kids[i]) === name) return dict.kids[i + 1];
  return null;
}
const bstrOf = (b, node) => node && node.t === 's' ? new TextDecoder('utf-8', { fatal: false }).decode(b.subarray(node.s, node.e)) : null;
/** 种子 → { info:[起, 止], name, trackers } */
function torrentMeta(b){
  const root = bdecode(b);
  const info = bget(b, root, 'info');
  if (!info || info.t !== 'd') throw new Error('种子中未找到 info 字典');
  const name = bstrOf(b, bget(b, info, 'name.utf-8')) || bstrOf(b, bget(b, info, 'name'));
  const tr = [];
  const ann = bstrOf(b, bget(b, root, 'announce'));
  if (ann) tr.push(ann);
  const al = bget(b, root, 'announce-list');
  if (al && al.t === 'l') for (const tier of al.kids) if (tier.t === 'l') for (const u of tier.kids){ const x = bstrOf(b, u); if (x) tr.push(x); }
  return { info: [info.s, info.e], name, trackers: [...new Set(tr.filter(u => /^(?:https?|udp|wss?):\/\//i.test(u)))].slice(0, 8) };
}
/* 老接口留着（内部只剩 magnetOf 用过）：语义改由 torrentMeta 提供 */
function infoBounds(b){ return torrentMeta(b).info; }
async function torrentBytes(env, aid){
  const r = await authed(env,'forum.php?mod=attachment&aid='+encodeURIComponent(aid));
  if (r.status>=300 && r.status<400) throw new Error('附件不可直接下载');
  const buf = new Uint8Array(await r.arrayBuffer());
  if (buf[0]!==0x64){
    const head = strip(decodeHTML(buf.slice(0,300), r)).slice(0,60);
    /* 空壳页 = 被限速（会过去）；有内容的提示页 = 积分 / 权限（不会过去） */
    if (buf.length < MIN_BODY){ govPenalize('附件空响应'); throw new Error('附件返回空响应（被限速）'); }
    throw Object.assign(new Error('返回的不是种子（可能需要积分或权限）：'+head), { hard: 1 });
  }
  /* 下载回来就验一遍：被截断 / 不完整的种子在这里就报出来，不进压缩包 */
  try { torrentMeta(buf); }
  catch (e){ const x = new Error('种子文件不完整：' + e.message); x.parse = 1; throw x; }
  return buf;
}
async function magnetOf(env, aid, ctx){
  const k = kkey(env,'m:'+aid);
  const hit = await jget(env,k);
  if (hit) return hit;
  const buf = await torrentBytes(env, aid);
  const meta = torrentMeta(buf);
  const [s,e] = meta.info;
  const d = await crypto.subtle.digest('SHA-1', buf.slice(s,e));
  const btih = [...new Uint8Array(d)].map(x=>x.toString(16).padStart(2,'0')).join('');
  const name = meta.name;
  const trackers = meta.trackers;
  let magnet = 'magnet:?xt=urn:btih:'+btih;
  if (name) magnet += '&dn='+encodeURIComponent(name);
  for (const t of trackers) magnet += '&tr='+encodeURIComponent(t);
  const out = { btih, name, trackers, magnet };
  const w = jput(env,k,out,TTL.magnet).catch(()=>{});
  ctx ? ctx.waitUntil(w) : await w;
  return out;
}

/* ══════════════════════════════════════════════════════════════════
   分片直取 —— Worker 不再打包
   ──────────────────────────────────────────────────────────────────
   v4 是 /api/pack：服务端把一批种子拼成 zip 再吐出来。三个后果：
     · CRC32 + 拼包全是纯 CPU，Free 计划一次调用只有 10ms，撞线就 1102；
     · 整个 zip 要同时留在内存里，128MB 那条线也在旁边看着；
     · 因为一次装不下，前端只好分批发 —— 于是用户拿到好几个 zip。
   v5 把打包整个搬到浏览器：这里只负责「按 tid 取种子字节」，一次 8 部
   （每部 2 个子请求）。浏览器攒齐了自己压成一个包，断了从缺口接着取。
   服务端因此变得非常轻：没有 CPU 峰值，没有内存峰值，也没有分包。
   ══════════════════════════════════════════════════════════════════ */

const safeName = (s) => String(s||'未命名').replace(/[\\/:*?"<>|\x00-\x1f]/g,'_').replace(/\s+/g,' ').trim().slice(0,110);

/** 并发跑一批，单个失败不影响其它 */
async function pool(items, n, fn){
  const out = new Array(items.length);
  let i = 0;
  const workers = new Array(Math.min(n, items.length)).fill(0).map(async () => {
    for (;;){
      const k = i++;
      if (k >= items.length) return;
      try { out[k] = { ok:true, value: await fn(items[k], k) }; }
      catch (e){ out[k] = { ok:false, error: e.message||String(e), budget: !!e.budget, cls: classify(e), hard: !!(e.hard || e.parse) }; }
    }
  });
  await Promise.all(workers);
  return out;
}

/** Uint8Array → base64。分块转换，避免 apply 的参数个数上限 */
function b64of(u8){
  let s = '';
  const N = 0x8000;
  for (let i = 0; i < u8.length; i += N) s += String.fromCharCode.apply(null, u8.subarray(i, i + N));
  return btoa(s);
}

/**
 * 取一批片源。入参 [{tid, name}]，出参每部一条：
 *   { tid, ok, kind:'torrent'|'magnet', b64|magnet, bytes, err }
 * 预算不够就把剩下的标成 retry，浏览器下一轮再来 —— 不报错、不丢进度。
 */
async function grabItems(env, items){
  const t0 = Date.now();
  const res = await pool(items, 3, async (it) => {
    if (subLeft() < 4){ const e = new Error('本轮子请求预算已尽'); e.budget = 1; throw e; }
    const d = await threadDetail(env, it.tid);
    const att = (d.attachments || []).filter(a => a.isTorrent);
    if (att.length){
      const buf = await torrentBytes(env, att[0].aid);
      return { kind:'torrent', b64: b64of(buf), bytes: buf.length, src: att[0].filename };
    }
    if ((d.magnets || []).length) return { kind:'magnet', magnet: d.magnets[0] };
    throw Object.assign(new Error('该帖没有种子附件，也没有磁力链接'), { hard: 1 });
  });

  const out = [];
  let ok = 0, retry = 0;
  for (let i = 0; i < items.length; i++){
    const it = items[i], r = res[i];
    if (r && r.ok){
      ok++;
      out.push({ tid: it.tid, ok: 1, name: safeName(it.name || ('影片-' + it.tid)), ...r.value });
    } else if (r && r.budget){
      retry++;
      out.push({ tid: it.tid, ok: 0, retry: 1, err: '预算已尽，稍后自动重取' });
    } else if (r && RETRYABLE.has(r.cls) && !r.hard){
      /* [v6] 限速 / 网络 / 论坛 5xx / 超时：是「这会儿取不到」，不是「这部取不到」——
         让浏览器过一会儿再要（它自己数次数，连着几次都这样才记为失败） */
      retry++;
      out.push({ tid: it.tid, ok: 0, retry: 1, soft: 1, err: (r.error || '暂时取不到').slice(0, 80) });
    } else {
      out.push({ tid: it.tid, ok: 0, name: safeName(it.name || ('影片-' + it.tid)),
                 err: (r && r.error) || '未知错误' });
    }
  }
  return { items: out, ok, retry, ms: Date.now() - t0, sub: SUB.n, subMax: SUB.max };
}

/* ══════════════════════════════════════════════════════════════════
   路由
   子请求预算是「按调用」算的，但计数器是 isolate 全局的：v5.3 起只有
   重活进门才登记预算（subEnter），轻请求与海报代理不再把它清零 ——
   否则正在跑的建索引会越过平台硬线被掐（见「Free 计划配额治理」）。
   ══════════════════════════════════════════════════════════════════ */
/** 一个源的日常：增量 → 补建 → 顺手认一批片库 */
async function cronOne(env){
  const st = await r2get(env, IDX.state, blankState());
  govLoad(st);
  if (govCoolLeft()){ trace('rate','cron 跳过：仍在限速冷却'); await maintain(env).catch(() => {}); return; }
  const allDone = BUILD_ORDER.every(y => st.years?.[y]?.done);
  /* 一步失败不连累后面：增量 / 补建出错（锁忙、限速）照样做片库对照与日常维护 */
  try {
    if (allDone){
      await incremental(env);
      /* [v6.2] 极限模式没认完就关了页面：排队的条目由定时任务接着认（普通模式那一轮会先认它们） */
      if ((st.pend && st.pend.wait) && subLeft() > 16) await buildChunk(env);
    }
    else { await incremental(env, 2); await buildChunk(env); }
  } catch (e){ trace('cron', SRC.name + ' 增量 / 补建：' + (e.message || e), { lvl: e.busy ? 'info' : 'warn' }); }
  /* 片库对照放在最后，用剩下的预算。总账模式下这一步是两个子请求
     （指针 + 变了才下正文）；老管线则是「有待认定就认一批」。 */
  let viaRecv = null;
  /* [v6.3] 实时清单优先（总账是 Stream v22 的快照，v25 不再更新）；拿不到才看总账 */
  if ((liveOn(env) || recvBase(env)) && subLeft() > 4)
    viaRecv = await libSyncAny(env, false);
  if (viaRecv && viaRecv.mode === 'live' && subLeft() > 10){
    const d = await libDoc(env).catch(() => null);
    if (d && d.v === 8 && (d.todo || []).length) await libResolveStep(env).catch(() => {});
  }
  if (!viaRecv && env.STREAM_BASE && subLeft() > 8){       // 两条路都走不通，才跑老管线
    const d = await libDoc(env).catch(() => null);
    if (d && (d.todo || []).length) await libResolveStep(env).catch(() => {});
    else if (!d || Date.now() - (d.scan || 0) > 6 * 3600_000)
      await libScanStep(env, { skipRecv: true }).catch(e => trace('lib', e.message || String(e)));
  }
  await maintain(env).catch(e => trace('sys', '日常维护失败：' + (e.message || e), { lvl:'warn' }));
}

export default {
  async scheduled(event, env, ctx){
    const tok = subEnter(env, true);
    ctx.waitUntil((async () => {
      /* 两个源轮流来，共用同一份子请求预算：先跑的先吃，剩得不够就收工，
         下一次 cron 从另一头接着跑（顺序每次都一样，但增量本来就是幂等的）。 */
      for (const id of Object.keys(SOURCES)){
        if (subLeft() < 10){ trace('cron', '子请求预算见底，'+id+' 留到下一次'); break; }
        await srcEnter(id, 60000);
        try { await cronOne(env); }
        catch (e){ trace('cron', SRC.name + '：' + (e.message || e)); }
        finally { srcLeave(); }
      }
    })().catch(e => { trace('cron', e.message); console.error('cron 失败:', e.message); })
      .then(() => subLeave(tok), () => subLeave(tok)));
  },

  async fetch(request, env, ctx){
    const url = new URL(request.url), p = url.pathname;
    if (p==='/'||p==='/index.html'){
      /* [v5.3] 页面按 ETag 协商：没变就回 304，不再每次重传整页。
         Referrer-Policy 把带口令的页面地址挡在外链（IMDb / 论坛原帖）之外。 */
      const h = { 'content-type':'text/html; charset=utf-8', 'etag': PAGE_TAG,
                  'cache-control':'private, max-age=0, must-revalidate',
                  'x-content-type-options':'nosniff', 'referrer-policy':'no-referrer' };
      if (request.headers.get('if-none-match') === PAGE_TAG)
        return new Response(null, { status:304, headers:h });
      return new Response(PAGE, { headers:h });
    }

    const sid = srcOf(url.searchParams.get('src'));

    /* 详情页短地址：/t/<base36>[?src=tv]
       只要算一次站点地址，不碰索引，所以不必进闸门。 */
    if (p.startsWith('/t/')){
      const tid = tidOf(p.slice(3));
      if (!tid) return new Response('bad short link', { status:400 });
      const S0 = SOURCES[sid];
      const b = String(env[S0.baseVar] || env.SITE_BASE || DEFAULT_BASE).replace(/\/?$/, '/');
      try { return Response.redirect(b+'forum.php?mod=viewthread&tid='+tid, 302); }
      catch { return new Response('bad SITE_BASE', { status:500 }); }
    }

    if (p==='/img'){
      const f = url.searchParams.get('p')||'';
      if (!/^\/[\w./-]+\.(jpg|png|webp)$/i.test(f)) return new Response('bad',{status:400});
      const size = { s:'w185', m:'w342', l:'w500' }[url.searchParams.get('s')] || 'w342';
      /* 海报代理各自是独立调用、每次只发一个子请求，不进共享预算 ——
         一屏几十张海报同时进来，不该把正在跑的建索引算成「预算用尽」。
         非 200 不许缓存：一次 404 不能在浏览器里钉三十天。 */
      let r;
      try {
        r = await fetch('https://image.tmdb.org/t/p/'+size+f, { cf:{cacheEverything:true,cacheTtl:604800},
          signal: (typeof AbortSignal !== 'undefined' && AbortSignal.timeout) ? AbortSignal.timeout(15000) : undefined });
      } catch (e){
        return new Response('poster upstream error', { status:502, headers:{ 'cache-control':'no-store' } });
      }
      return new Response(r.body, { status:r.status, headers:{
        'content-type': r.headers.get('content-type')||'image/jpeg',
        'cache-control': r.ok ? 'public, max-age=2592000, immutable' : 'no-store' } });
    }

    if (!p.startsWith('/api/')) return new Response('Not found',{status:404});
    if (env.GATE && (url.searchParams.get('gate')||request.headers.get('x-gate'))!==env.GATE)
      return json({ error:'口令不正确' },401);

    const Q = url.searchParams;
    /* [v5.3] 重活 / 轻活分流：只有重活参与子请求预算（见 subEnter）。 */
    const heavy = HEAVY_RE.test(p) || (p==='/api/lib' && !!(Q.get('scan')||Q.get('resolve')||Q.get('refresh')));
    const tok = subEnter(env, heavy);

    /* 换源就是换一整套 R2 键，所以先过闸门：同源随便并发，异源排队等。
       ctx 也包一层 —— 后台任务必须算进这一批，否则它会跨到下一批里去写
       另一个源的键。 */
    try { await srcEnter(sid); }
    catch (e){ subLeave(tok); return json({ error: e.message, kind:'busy', busy:1, wait: e.wait||5 }, 409); }
    const bg = [];
    const cx = {
      /* 闸门只等后台任务 60 秒：永远不结束的 Promise 不能把闸门一直攥在手里 */
      waitUntil(pr){ bg.push(Promise.race([Promise.resolve(pr).catch(()=>{}), sleep(60000)])); return ctx.waitUntil(pr); },
      passThroughOnException(){ return ctx.passThroughOnException && ctx.passThroughOnException(); },
    };
    const leave = () => { srcLeave(); subLeave(tok); };

    try {
      /* ── 分片直取（POST）──
         浏览器一次要 8 部，取到就往 IndexedDB 里塞；服务端不再有 zip。 */
      if (p==='/api/fetch'){
        if (request.method !== 'POST') return json({ error:'请用 POST' },405);
        const body = await request.json().catch(()=>null);
        const raw = (body && body.items) || [];
        if (!raw.length) return json({ error:'没有要取的片源' },400);
        const items = raw.slice(0, GRAB_MAX).map(x => ({
          tid: /^\d+$/.test(String(x.tid)) ? Number(x.tid) : tidOf(x.sid||''),
          name: String(x.name||'').slice(0,120),
        })).filter(x => x.tid > 0);
        if (!items.length) return json({ error:'没有有效的片源' },400);
        const r = await grabItems(env, items);
        return json({ ...r, max: GRAB_MAX });
      }
      /* v4 的服务端打包已移除：它是 CPU / 内存峰值的来源，也是"一次下载
         分出好几个 zip"的根因。老前端如果还在打这个地址，明确告诉它。 */
      if (p==='/api/pack')
        return json({ error:'服务端打包已下线，请刷新页面使用新的分片下载' },410);

      if (p==='/api/catalog' || p==='/api/detail' || p==='/api/cart'){
        const { movies, state } = await loadIndex(env);
        const ver = state.ver||0;
        const lib = await libLoad(env, cx).catch(()=>null);
        /* 边缘缓存键带索引版本号 + 片库版本号：片库一变（下了新片），
           旧的"已过滤"结果自然作废，不用手动清缓存。
           构造失败就跳过缓存，绝不因此让请求失败 */
        let cache = null, ck = null;
        try {
          ck = new Request(new URL(url.pathname + '?' + [...Q.entries()]
            .filter(([k])=>k!=='gate').map(([k,v])=>k+'='+encodeURIComponent(v)).sort().join('&')
            + '&v=' + ver + '&l=' + libVer(lib), url.origin).toString());
          cache = caches.default;
          const hitc = await cache.match(ck);
          if (hitc) return hitc;
        } catch { cache = null; ck = null; }

        let body;
        if (p==='/api/catalog'){
          /* own: hide（默认，藏掉库里已有的）/ all（都显示，只打标）/ only（只看已有） */
          const own = ({ hide:'hide', all:'all', only:'only' })[Q.get('own')] || 'hide';
          const r = queryCatalog(movies, {
            ver,
            text: (Q.get('q')||'').trim(), year: Q.get('year')||'', genre: Q.get('genre')||'',
            min: Q.get('min')==null ? 6 : (Number.isFinite(Number(Q.get('min'))) ? Number(Q.get('min')) : 6),
            sort: Q.get('sort')||'new', page: Math.min(10000, Math.max(1, parseInt(Q.get('page')||'1', 10) || 1)),
            dr: Q.get('dr')||'', qual: Q.get('qual')||'',
            lib, own,
          });
          body = { ...r, src: SRC.id, indexed: state.movies||0, at: state.at||0,
            building: !BUILD_ORDER.every(y=>state.years?.[y]?.done),
            lib: { on: lib?1:0, files: lib?lib.files:0, ids: lib?lib.ids.size:0,
                   todo: lib?lib.todo:0, at: lib?lib.at:0, own,
                   match: lib ? (() => { const st = libOwn(movies, ver, lib).stat;
                     return { exact: st.exact, key: st.key || 0, name: st.name, conflict: st.conflict, amb: st.amb }; })() : null } };
        } else if (p==='/api/cart'){
          /* 购物车批量取默认片源：只读影片表，不解分片 */
          const ids = (Q.get('ids')||'').split(',').map(Number).filter(Boolean).slice(0, CART_MAX);
          body = { items: ids.map(id => {
            const m = movies.m[id];
            if (!m) return { id, missing:true };
            return { id, title:m[F.N], year:m[F.Y], poster:m[F.P], res:m[F.Q],
                     size:m[F.Z], sid:m[F.BT], rels:m[F.R], score:m[F.B],
                     hb:m[F.HB]||0, rb:m[F.RB]||resLevel(m[F.Q]),
                     own: libHasId(movies, ver, lib, id) };
          }) };
        } else {
          const id = Q.get('id');
          const m = movies.m?.[id];
          if (!m) return json({ error:'索引里没有这部影片' },404);
          const items = collapse((await movieRows(env, movies, id, ver, state)).map(decorate));
          const meta = await tmdbMeta(env, id, cx).catch(()=>null);
          body = {
            movie: { id:+id, title:m[F.N], original:m[F.O], year:m[F.Y], poster:m[F.P],
              own: libHasId(movies, ver, lib, id),
              lib: lib ? (libWhy(movies, ver, lib, id) || { own: 0, how: '', file: '' }) : null,
              vote:m[F.T], votes:m[F.C], wr:+weighted(m).toFixed(1), res:m[F.Q], size:m[F.Z], sid:m[F.BT],
              hb:m[F.HB]||0, rb:m[F.RB]||resLevel(m[F.Q]),
              overview: meta?.overview||'', runtime: meta?.runtime||null,
              genres: meta?.genres||[], imdb: meta?.imdb||null },
            items, value: valuePick(items),
          };
        }
        const res = json(body);
        res.headers.set('cache-control','public, max-age=60, s-maxage=600');
        if (cache && ck) cx.waitUntil(cache.put(ck, res.clone()));
        return res;
      }

      if (p==='/api/thread'){
        const tid = Q.get('tid') || tidOf(Q.get('sid'));
        if (!tid) return json({error:'缺少 tid'},400);
        return json(await threadDetail(env, tid, cx));
      }
      if (p==='/api/magnet'){
        const aid = Q.get('aid');
        if (!aid) return json({error:'缺少 aid'},400);
        return json(await magnetOf(env, aid, cx));
      }
      if (p==='/api/torrent'){
        const aid = Q.get('aid');
        if (!aid) return json({error:'缺少 aid'},400);
        const name = safeName(Q.get('name')||'download').replace(/"/g,'');
        const buf = await torrentBytes(env, aid);
        return new Response(buf, { headers:{
          'content-type':'application/x-bittorrent',
          'content-disposition':'attachment; filename="'+name+'.torrent"' } });
      }

      /* ── 片库对照：扫描 / 认定 / 状态 ── */
      if (p==='/api/lib'){
        if (!recvBase(env)) return json({ ...libStat(env, null), source: SRC.id });
        if (Q.get('scan')){
          const r = await libScanStep(env);
          return json({ ...r, ...libStat(env, libHydrate(await libDoc(env))) });
        }
        if (Q.get('resolve')){
          const r = await libResolveStep(env);
          return json({ ...r, ...libStat(env, libHydrate(await libDoc(env))) });
        }
        if (Q.get('refresh')){
          libMem = null; libFail = 0;
          await libRefresh(env, true);
          return json(libStat(env, libMem));
        }
        const l0 = await libLoad(env, cx);
        let os = null;
        if (l0){ try { const { movies, state } = await loadIndex(env); os = libOwn(movies, state.ver || 0, l0).stat; } catch {} }
        return json(libStat(env, l0, os));
      }

      /* ── 日志：按频道取 ── */
      if (p==='/api/logs'){
        const st = Q.get('saved') ? await r2get(env, IDX.state, blankState()) : null;
        return json({
          ch: Object.entries(LOG_CH).map(([k,v]) => ({ k, name:v,
            n: TRACE.filter(x=>x.ch===k).length })),
          live: traceView(Q.get('ch')||'all', Number(Q.get('n')||60)),
          saved: st ? (st.events||[]) : undefined,
        });
      }

      if (p==='/api/state'){
        let st = await r2get(env, IDX.state, blankState());
        /* [v6.4] 旧版写的留底摘要没有乱码抽查：当场算一次、写回 state（只做这一次），界面才能及时提示重建 */
        if (st.pend && st.pend.n && st.pend.gchk == null){
          const pd = await pendLoad(env).catch(() => null);
          if (pd){
            const fresh = pendStat(pd, new Set(Array.isArray(st.pdone) ? st.pdone : []));
            st = await stateMutate(env, (x) => { if (x.pend && x.pend.gchk != null) return false; x.pend = fresh; }).catch(() => ({ ...st, pend: fresh }));
          }
        }
        govLoad(st);
        const at = lockAt(st.lock), age = at ? Date.now()-at : 0;
        const busy = age > 0 && age < LOCK_MS;
        const pl = planOf(env);
        return json({
          v: 5, at: st.at||0, ver: st.ver||0,
          src: SRC.id, srcName: SRC.name,
          sources: Object.values(SOURCES).map(x => ({ id:x.id, name:x.name, years:x.order })),
          site: hostOf(base(env)), fid: FID,
          movies: st.movies||0, rels: st.rels||0,
          relsByYear: st.relsByYear||{}, dictByYear: st.dictByYear||{},
          lastIncremental: st.lastIncremental||null,
          migrated: st.migrated||{},
          deaths: st.deaths||0,
          gap: GOV.gap, cooling: Math.ceil(govCoolLeft()/1000), coolWhy: GOV.why||'',
          staleLock: age >= LOCK_MS,
          resync: st.resync ? st.resync.at : 0,
          partSize: PART_ROWS,
          plan: { name: pl.name, sub: pl.sub, hard: pl.hard, pages: pl.pages, tmdb: pl.tmdb },
          turbo: (() => { const tc = pl.name === 'paid' ? TURBO_PAID : TURBO_FREE;
            return { on: turboOn(env), pages: tc.pages, conc: tc.conc, group: tc.group }; })(),
          pend: st.pend || null,
          pipe: st.pipe || null, pipes: st.pipes || [],
          stageNames: PIPE_NAME,
          events: (st.events||[]).slice(0, 30),
          grabMax: GRAB_MAX, cartMax: CART_MAX,
          years: BUILD_ORDER.map(y => {
            const v = st.years?.[y] || {};
            const pn = partRows(st, y);
            return { year:y, page:v.page||1, last:v.last||0, done:!!v.done,
                     bad:(v.bad||[]).length, rels:(st.relsByYear||{})[y]||0,
                     parts: pn.length, big: pn.filter(n => n > PART_ROWS*1.5).length };
          }),
          done: BUILD_ORDER.every(y=>st.years?.[y]?.done),
          busy, lockLeft: busy ? Math.ceil((LOCK_MS-age)/1000) : 0,
        });
      }
      if (p==='/api/build'){
        /* [v6.2] 极限模式：POST 带上浏览器攒下的认定结果（hits）、正在认的键（fly）。
           服务端 TURBO=0 时照普通模式跑一轮，回 turbo:0，前端据此退回普通模式 */
        const turbo = Q.get('turbo') === '1' && turboOn(env);
        let body = null;
        if (turbo && request.method === 'POST') body = await request.json().catch(() => null);
        return json(await buildChunk(env, {
          pages: Number(Q.get('pages')||0) || 0,
          tmdbMax: Number(Q.get('tmdb')||0) || 0,
          year: Q.get('year')||null,
          turbo,
          hits: body && Array.isArray(body.hits) ? body.hits : null,
          fly: body && Array.isArray(body.fly) ? body.fly : null,
          solo: !!(body && body.solo),
          flush: turbo && Q.get('pages') === '0',
        }));
      }
      /* [v6.6] 导入清单：只读，不写 R2；库里没有的查好版本交回，浏览器放进片单、等人确认再下 */
      if (p==='/api/import'){
        if (request.method !== 'POST') return json({ error:'请用 POST，正文是 { items: [...] }' }, 405);
        const body = await request.json().catch(() => null);
        const list = Array.isArray(body) ? body : (body && Array.isArray(body.items) ? body.items : null);
        if (!list) return json({ error:'正文要是 JSON 数组，或 { items: [...] }' }, 400);
        return json(await importItems(env, list, cx));
      }
      /* [v6.7] 导入清单里索引没有的：去论坛搜索页搜一条。论坛限频时回 { wait: 秒 }，浏览器等够了再来 */
      if (p==='/api/fsearch'){
        if (request.method !== 'POST') return json({ error:'请用 POST，正文是 { item: {...} }' }, 405);
        const body = await request.json().catch(() => null);
        if (!body || !body.item || typeof body.item !== 'object') return json({ error:'正文要是 { item: {...} }' }, 400);
        try { return json(await fsearchItem(env, body.item, body.kw ? String(body.kw) : '', cx)); }
        catch (e){ if (e.wait) return json({ status:'wait', wait: e.wait, reason: e.message }); throw e; }
      }
      /* [v6.2] 认定工：不持锁、不写 R2，自带一整份子请求配额 */
      if (p==='/api/tm'){
        if (!turboOn(env)) return json({ error:'极限模式已在服务端关闭（TURBO=0）', off:1 }, 403);
        if (request.method !== 'POST') return json({ error:'请用 POST' }, 405);
        const body = await request.json().catch(() => null);
        if (!body || !Array.isArray(body.g)) return json({ error:'没有要认定的条目' }, 400);
        return json(await turboMatch(env, body.g));
      }
      if (p==='/api/incremental') return json(await incremental(env, Number(Q.get('pages')||0)));
      if (p==='/api/diagnose')    return json(await diagnose(env));
      if (p==='/api/repair')      return json(await repair(env, Q.get('do')||'', Q.get('year')||null));
      if (p==='/api/unlock')      return json(await repair(env, 'unlock'));
      if (p==='/api/migrate')     return json(await migrateYear(env, Q.get('year')||null));
      if (p==='/api/optimize')    return json(await optimizeYear(env, Q.get('year')||BUILD_ORDER[0], Q.get('part')));
      if (p==='/api/split')       return json(await splitYear(env, Q.get('year')));
      if (p==='/api/reset')       return json(await resetYear(env, Q.get('year')));

      return json({ error:'未知接口' },404);
    } catch (e) {
      const cls = classify(e);
      trace(cls, (p||'') + ': ' + (e.message||e));
      /* busy / cooling / budget 都带结构化字段，前端才能精确等待而不是瞎猜 */
      return json({
        error: e.message||String(e), kind: cls,
        busy: e.busy?1:0, wait: e.wait||0, stale: !!e.stale,
        budget: e.budget?1:0, sub: SUB.n, subMax: SUB.max,
        cooling: e.cooling || Math.ceil(govCoolLeft()/1000) || 0,
      }, e.busy ? 409 : (cls === 'rate' ? 429 : (cls === 'budget' ? 503 : 500)));
    } finally {
      /* 后台任务还在花子请求，预算和源闸门都要等它们跑完再放 */
      if (bg.length) ctx.waitUntil(Promise.all(bg).then(leave, leave));
      else leave();
    }
  },
};

/* ═══════════════════════════════════════════════════════════════════
   前端 —— 白底，白云蓝为第一重点色、黑为第二；海报仍是唯一的大面积颜色
   ═══════════════════════════════════════════════════════════════════ */
const PAGE = String.raw`<!DOCTYPE html>
<html lang="zh-CN" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,maximum-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="theme-color" content="#FFFFFF" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0B0B0C" media="(prefers-color-scheme: dark)">
<title>Cuven ᴿ 索引库</title>
<script>
/* 在第一次绘制之前把主题读出来。放在样式表前面、同步执行 ——
   晚一步就会先闪一帧浅色再切深色。noanim 让首帧的一切过渡与动画噤声，
   等两帧之后再摘掉，于是"刷新回来"看到的是结果，不是补动画。 */
(function(){
  var t = 'auto';
  try { t = (JSON.parse(localStorage.getItem('cvr') || '{}').theme) || 'auto'; } catch(e){}
  var d = document.documentElement;
  d.setAttribute('data-theme', t);
  d.className = 'noanim';
})();
</script>
<style>
/* ══════════════════════════════════════════════════════════════════
   令牌 —— 所有动效、字号、字重、字距、层级、命中区都只从这里取值
   ──────────────────────────────────────────────────────────────────
   把这些收进变量不是为了好看，是为了「快慢」「轻重」「疏密」各自
   是一个可调的整体，而不是三十处各写各的。
   --silk 由性能调度器实时改写：掉帧就整体收紧，省下的帧还给滚动。
   ══════════════════════════════════════════════════════════════════ */
:root{
  --silk:1;
  --e-std:cubic-bezier(.32,.72,0,1);     /* 位移 / 展开：起步快、收尾长 */
  --e-soft:cubic-bezier(.4,0,.2,1);      /* 渐显 / 变色 */
  --e-out:cubic-bezier(.22,1,.36,1);     /* 进入 */
  --e-pop:cubic-bezier(.34,1.26,.64,1);  /* 极轻回弹，只留给「确认」这一个时刻 */
  /* 时长按用途分档，UI 一律压在 300ms 以内 —— 超过这个数，界面就开始
     "等动画"而不是"响应操作"。抽屉类单独一档，它允许慢一点。 */
  --t-xs:calc(.1s*var(--silk));      /* 颜色 / 文字色 */
  --t-s:calc(.16s*var(--silk));      /* hover、背景 */
  --t-m:calc(.24s*var(--silk));      /* 下拉、卡片、图片淡入 */
  --t-l:calc(.3s*var(--silk));       /* 最大的普通 UI，卡在预算上沿 */
  --t-fast:calc(.14s*var(--silk));   /* 高频重放的入场，越短越好 */
  --t-sheet:calc(.44s*var(--silk));  /* 底部动作坞这类抽屉 */
  /* 按压反馈不参与 --silk 缩放：它是"直接性"的地基，任何时候都必须即时。 */
  --t-press:80ms;                    /* 按下 80ms 内到位；松手沿 --e-morph 回弹（同 Transfer） */
  --e-morph:cubic-bezier(.32,.72,0,1);
  --ease-exit:cubic-bezier(.4,0,1,1);  /* 离场加速：弹层、胶囊退场都用它，进出不再同一支曲线 */

  /* ── 字重 ──
     只在这里定义。任何状态（选中 / hover / 焦点）都不准改字重 ——
     改一次字重就要重排一次文字，一排药丸按钮会跟着抖一下。
     状态一律用颜色和底色去说。 */
  --fw-r:400;   /* 正文 */
  --fw-m:510;   /* 控件、标签、片名 */
  --fw-s:580;   /* 强调、卡片标题 */
  --fw-b:660;   /* 大标题、KPI 数字 */
  --fw-x:700;   /* 商标 */

  /* ── 字距随字号走 ──
     字号一大，字与字看起来就散，要收；小字要略放才认得清。
     一个固定的 letter-spacing 必然在某个字号上是错的。 */
  --tr-xs:.014em;    /* ≤ 11px */
  --tr-s:.004em;     /* 12 – 13px */
  --tr-b:-.011em;    /* 14 – 16px 正文 */
  --tr-l:-.02em;     /* 19 – 22px */
  --tr-xl:-.028em;   /* 24 – 28px */
  --tr-2xl:-.034em;  /* 30px 以上 */
  /* ── 行高与字号反向：大字收紧，小字放开 ── */
  --lh-t:1.14; --lh-h:1.3; --lh-b:1.5; --lh-r:1.62;

  /* ── 层级刻度 ──
     没有 9999。只有下面这七个台阶，新东西必须落在其中一阶上。
     顺序是有含义的：推入层压在顶栏「下面」（顶栏是材质，内容从它下面
     滑过去，返回键始终可点），边缘手势条又必须在顶栏之上。 */
  --z-sticky:100;   /* 筛选台 */
  --z-scrim:200;    /* 推入层的压暗 */
  --z-push:210;     /* 推入层 */
  --z-header:300;   /* 顶栏 */
  --z-edge:310;     /* 左边缘手势条 */
  --z-dock:400;     /* 底部动作坞 */
  --z-toast:500;    /* 提示 */

  /* ── 命中区 ──
     触屏 44，精细指针 40。视觉尺寸可以比这小，靠伪元素把可点范围撑开。 */
  --hit:44px; --hit-d:40px;

  /* 圆角阶梯（同 Cuven Transfer）：卡片 30，卡内件 = 30 − 17（内容到卡边的内缩）= 13，同心；
     小浮层 16 / 其内 11。坞与胶囊是整颗 stadium。 */
  --r-s:11px; --r-m:13px; --r-l:30px; --r-xl:30px;
  --r-card:30px; --r-in:13px; --r-pop:16px; --r-pop-in:11px;
  --nav-h:68px;                       /* 底部坞（手机）与动作胶囊共用的高度 */
  --hairw:1px;
  --pad:max(20px,env(safe-area-inset-left));
  --padr:max(20px,env(safe-area-inset-right));
  --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,monospace;
  --sans:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC","Microsoft YaHei",sans-serif;

  /* ── 色彩 ──
     全局约定：白底；第一重点色白云蓝 —— 主行动 / 选中 / 聚焦环 / 进度 /
     实时数据；第二重点色黑 —— 商标、性价比之选、提示。海报仍是页面上唯一
     的大面积颜色。白底之后卡片不能再靠"白压灰"分层，改靠 1px 描边 +
     轻阴影（--sh 里带着那一圈描边）。要换主题色只改下面这六个。 */
  /* v6 起与 Cuven Transfer 同一套规矩：交互重点色 = 黑（主行动、选中态、片单勾选）；
     白云蓝只留给「数据」—— 进度、实时流、链接、聚焦环。语义色不跟着走。
     白云蓝以 L C H 三元组为源，透明度派生全从它出：换主题只动这一行（P3 屏只抬 C）。 */
  --sky-lch:0.646 0.142 253.9;
  --ac:oklch(var(--sky-lch)); --acf:#FFF;      /* 白云蓝：数据 / 聚焦 */
  --act:oklch(0.545 0.135 254.2);              /* 白云蓝的正文档：白底跑文字 ≥ 4.5:1 */
  --acb:oklch(var(--sky-lch) / .12);           /* 白云蓝的薄染 */
  --ink:oklch(0.179 0.006 285.8); --inkf:#FFF; /* 黑：交互重点色 */
  --ink-d:oklch(0.28 0.006 285.8);             /* 黑按下 */

  --bg:#FFF; --sf:#FFF;
  --sf2:oklch(0.971 0.003 286.4); --sf3:oklch(0.958 0.003 286.3); --sf4:oklch(0.932 0.003 286.3);
  --line:oklch(0.932 0.003 286.3); --line2:oklch(0.884 0.006 286.2); --hair:oklch(0.953 0.003 286.3);
  --t1:oklch(0.206 0.006 285.9); --t2:oklch(0.562 0.012 286); --t3:oklch(0.708 0.012 286.1);
  --ok:oklch(0.627 0.17 149.2); --okb:oklch(0.627 0.17 149.2 / .12);
  --warn:oklch(0.555 0.146 49); --warnb:oklch(0.555 0.146 49 / .11);
  --bad:oklch(0.577 0.215 27.3); --badb:oklch(0.577 0.215 27.3 / .09);
  --glass:rgba(255,255,255,.72);
  --glass-rgb:232,232,237; --glass-a:.72;      /* 坞 / 胶囊的玻璃（Transfer 同款 aap 玻璃） */
  --sel:oklch(var(--sky-lch) / .22);           /* 选区：一层薄染，不是反白 */
  --sbar:rgba(0,0,0,.2);                       /* 局部滚动条，只用在小容器里 */
  /* 白底之上层级靠 1px 描边 + 极浅投影（同 Transfer 的卡片），不再靠大片柔影 */
  --sh:0 0 0 1px var(--line),0 1px 2px rgba(20,20,30,.045);
  --sh-s:0 0 0 1px var(--line),0 1px 2px rgba(20,20,30,.05);
  --sh-l:0 0 0 1px var(--line),0 2px 6px rgba(20,20,30,.05),0 24px 60px -20px rgba(20,20,30,.18);
  --sh-float:0 8px 26px rgba(18,18,28,.10),0 1px 3px rgba(18,18,28,.06),inset 0 0 0 1px rgba(20,20,30,.05);
  --thumb:rgba(255,255,255,.92);                /* 分段控件 / 坞的白 thumb */
  --sh-thumb:0 1px 2px rgba(18,18,28,.10),0 6px 16px rgba(18,18,28,.055),inset 0 0 0 .5px rgba(255,255,255,.92);
  --poster:oklch(0.932 0.003 286.3);
  /* 纸面（Transfer 的底）：中心白、往外压暗的径向纸 + 18px 点阵，点阵从中心往外抹掉 */
  --paper:#f1f1f5;
  --paper-grad:radial-gradient(120% 86% at 50% 38%,#ffffff 0%,#f8f8fa 58%,#ececf1 100%);
  --paper-dot:rgba(11,11,18,.18);
}
@media (color-gamut:p3){ html:not([data-theme="dark"]){ --sky-lch:0.646 0.165 253.9 } }
@media (-webkit-min-device-pixel-ratio:2),(min-resolution:192dpi){ :root{ --hairw:.5px } }
/* 深色只写一份：跟随系统且系统是深色、或手动指定深色，都吃它。
   蓝色提亮一档，其上的文字改成墨色，对比度才够。 */
@media (prefers-color-scheme:dark){
  html:not([data-theme="light"]){
    --ac:#67AAED; --acf:#0A0A0B; --act:#85BCF5; --acb:rgba(103,170,237,.17);
    --ink:#F5F5F7; --inkf:#0A0A0B;
    --bg:#0A0A0B; --sf:#161618; --sf2:#1C1C1F; --sf3:#26262A; --sf4:#33333A;
    --line:rgba(255,255,255,.09); --line2:rgba(255,255,255,.15);
    --t1:#F5F5F7; --t2:rgba(235,235,245,.58); --t3:rgba(235,235,245,.3);
    --ok:#32D74B; --okb:rgba(50,215,75,.14);
    --warn:#FFD426; --warnb:rgba(255,212,38,.13);
    --bad:#FF6B5E; --badb:rgba(255,107,94,.13);
    --glass:rgba(18,18,20,.74);
    --glass-rgb:30,30,34; --glass-a:.74;
    --ink-d:#D8D8DD; --hair:rgba(255,255,255,.06);
    --sel:rgba(103,170,237,.3);
    --sbar:rgba(255,255,255,.22);
    --sh:0 0 0 1px var(--line),0 1px 2px rgba(0,0,0,.4);
    --sh-s:0 0 0 1px var(--line),0 1px 2px rgba(0,0,0,.35);
    --sh-l:0 0 0 1px var(--line),0 2px 8px rgba(0,0,0,.45),0 28px 70px -24px rgba(0,0,0,.9);
    --sh-float:0 10px 30px rgba(0,0,0,.55),0 1px 3px rgba(0,0,0,.4),inset 0 0 0 1px rgba(255,255,255,.08);
    --thumb:rgba(255,255,255,.16);
    --sh-thumb:0 1px 2px rgba(0,0,0,.5),inset 0 0 0 .5px rgba(255,255,255,.14);
    --poster:#222226;
    --paper:#0a0a0b;
    --paper-grad:radial-gradient(120% 86% at 50% 38%,#161618 0%,#0e0e10 60%,#0a0a0b 100%);
    --paper-dot:rgba(255,255,255,.07);
  }
}
html[data-theme="dark"]{
  --ac:#67AAED; --acf:#0A0A0B; --act:#85BCF5; --acb:rgba(103,170,237,.17);
  --ink:#F5F5F7; --inkf:#0A0A0B;
  --bg:#0A0A0B; --sf:#161618; --sf2:#1C1C1F; --sf3:#26262A; --sf4:#33333A;
  --line:rgba(255,255,255,.09); --line2:rgba(255,255,255,.15);
  --t1:#F5F5F7; --t2:rgba(235,235,245,.58); --t3:rgba(235,235,245,.3);
  --ok:#32D74B; --okb:rgba(50,215,75,.14);
  --warn:#FFD426; --warnb:rgba(255,212,38,.13);
  --bad:#FF6B5E; --badb:rgba(255,107,94,.13);
  --glass:rgba(18,18,20,.74);
  --glass-rgb:30,30,34; --glass-a:.74;
  --ink-d:#D8D8DD; --hair:rgba(255,255,255,.06);
  --sel:rgba(103,170,237,.3);
  --sbar:rgba(255,255,255,.22);
  --sh:0 0 0 1px var(--line),0 1px 2px rgba(0,0,0,.4);
  --sh-s:0 0 0 1px var(--line),0 1px 2px rgba(0,0,0,.35);
  --sh-l:0 0 0 1px var(--line),0 2px 8px rgba(0,0,0,.45),0 28px 70px -24px rgba(0,0,0,.9);
  --sh-float:0 10px 30px rgba(0,0,0,.55),0 1px 3px rgba(0,0,0,.4),inset 0 0 0 1px rgba(255,255,255,.08);
  --thumb:rgba(255,255,255,.16);
  --sh-thumb:0 1px 2px rgba(0,0,0,.5),inset 0 0 0 .5px rgba(255,255,255,.14);
  --poster:#222226;
  --paper:#0a0a0b;
  --paper-grad:radial-gradient(120% 86% at 50% 38%,#161618 0%,#0e0e10 60%,#0a0a0b 100%);
  --paper-dot:rgba(255,255,255,.07);
}
html[data-theme="light"]{color-scheme:light}
html[data-theme="dark"]{color-scheme:dark}

/* 首帧不许动。刷新回来时主题、动作坞、片单数量都要"本来就是那样"，
   而不是先画一个默认态再动画着改过去 —— 那一下闪烁比动画本身显眼得多。 */
html.noanim *,html.noanim *::before,html.noanim *::after{
  transition:none!important;animation:none!important}
*{box-sizing:border-box;margin:0;padding:0;-webkit-tap-highlight-color:transparent}
html{-webkit-text-size-adjust:100%}
/* 系统字体自带光学字号、字距表和易读性调校，不再外挂字体文件 ——
   于是"字体子集化"这一项天然满足：一个字节都没有多下发。 */
/* ── 纸面（搬 Cuven Transfer 的底）──
   两层：一层从中心往外压暗的径向纸，一层 18px 点阵，再用一支从中心衰减的径向遮罩
   把点往边上抹掉 —— 视线中心是干净的白，越往外越有颗粒，页面不再是一块死白。
   挂在 html 的固定伪层上：铺满视口、不跟着滚；body 透明。 */
html{background:var(--paper)}
html::before,html::after{content:'';position:fixed;inset:0;z-index:-1;pointer-events:none}
html::before{background:var(--paper-grad)}
html::after{
  background-image:radial-gradient(circle,var(--paper-dot) 0 .75px,transparent .8px);
  background-size:18px 18px;background-position:9px 5px;
  -webkit-mask-image:radial-gradient(78% 62% at 50% 38%,#000 0%,rgba(0,0,0,.55) 55%,transparent 100%);
  mask-image:radial-gradient(78% 62% at 50% 38%,#000 0%,rgba(0,0,0,.55) 55%,transparent 100%)}
@media (prefers-contrast:more){ html::after{display:none} }
body{background:transparent;color:var(--t1);font-family:var(--sans);font-size:1rem;
  line-height:var(--lh-b);letter-spacing:var(--tr-b);
  -webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;
  overflow-x:hidden;padding-bottom:calc(104px + env(safe-area-inset-bottom))}
/* 底部 scroll edge：内容滑进坞 / 胶囊下方之前先被洗掉，不撞硬边（同 Transfer 的 body::after）。
   只在底部真有浮层时出现：手机上坞常驻，桌面上片单胶囊升起时才有 */
/* 层：压在内容与推入层之上、顶栏（坞就在顶栏的层里）之下 —— 不然坞自己也被洗掉 */
body::after{content:'';position:fixed;left:0;right:0;bottom:0;z-index:calc(var(--z-header) - 10);pointer-events:none;
  height:calc(env(safe-area-inset-bottom) + 104px);opacity:0;transition:opacity var(--t-m) var(--e-soft);
  -webkit-backdrop-filter:blur(7px);backdrop-filter:blur(7px);
  -webkit-mask-image:linear-gradient(to top,#000 30%,rgba(0,0,0,.72) 52%,rgba(0,0,0,.32) 74%,transparent 100%);
  mask-image:linear-gradient(to top,#000 30%,rgba(0,0,0,.72) 52%,rgba(0,0,0,.32) 74%,transparent 100%);
  background:linear-gradient(to top,rgba(255,255,255,.62) 16%,rgba(255,255,255,.38) 48%,rgba(255,255,255,.14) 76%,rgba(255,255,255,0) 96%)}
body:has(#dock.up)::after{opacity:1}
body:has(#dock.up){padding-bottom:calc(120px + env(safe-area-inset-bottom))}
button,input,select{font:inherit;color:inherit;letter-spacing:inherit}
.wrap{max-width:1180px;margin:0 auto;padding-left:var(--pad);padding-right:var(--padr)}
/* 焦点环保持中性色，且只画环 —— 不改元素自身的圆角，否则一聚焦形状就变了 */
:focus-visible{outline:2px solid var(--ac);outline-offset:3px}
::selection{background:var(--sel)}
b,strong{font-weight:var(--fw-s)}
/* 会变的数字一律等宽，否则每刷新一次就抖一下 */
.num,.kpi,.dl-head,.dl-meta,.fsum,.quota,.dbar,.spec,.hash,.node .nv,.node .ns,
.seg button em,.chips button,.pills button i,.yr,.qs,.pill,.dg .dt{
  font-variant-numeric:tabular-nums;font-feature-settings:"tnum"}
/* 纯装饰的东西不许挡住真控件，也不许被选中 */
.badge,.tick,.dot,.spark,.spark i,.link2,.link2 i,.bar2,.bar2 i,.shimmer,.skn,.mark{
  pointer-events:none;-webkit-user-select:none;user-select:none}
/* 锚点滚动要给悬浮顶栏留出位置 */
[id]{scroll-margin-top:calc(var(--hh,56px) + 12px)}

/* 局部滚动条：只在小容器里定制，页面主滚动条永远是系统原生的 */
.qlist::-webkit-scrollbar,.logs::-webkit-scrollbar{width:8px;height:8px}
.qlist::-webkit-scrollbar-thumb,.logs::-webkit-scrollbar-thumb{
  background:var(--sbar);border-radius:4px}
.qlist::-webkit-scrollbar-track,.logs::-webkit-scrollbar-track{background:transparent}
.qlist,.logs{scrollbar-width:thin;scrollbar-color:var(--sbar) transparent}

/* 掉帧时性能调度器打上这个类：毛玻璃与大阴影先让路 */
html.lite header::before,html.lite #dock,html.lite #nav,html.lite .filters,html.lite body::after{
  backdrop-filter:none!important;-webkit-backdrop-filter:none!important}
html.lite header::before,html.lite #dock,html.lite #nav{background:var(--sf)!important}
html.lite .filters{background:var(--sf)!important}
html.lite .card,html.lite .art{box-shadow:var(--sh-s)!important}
html.lite .shimmer{animation:none!important}

/* ── 顶栏 ───────────────────────────────────────────────────────── */
/* 材质挂在 ::before 上，不挂在 header 本体：backdrop-filter 会给后代建一个「固定定位的
   参照系」，手机上导航要以 position:fixed 浮到屏幕底部当坞，header 本体就不能带它 */
header{position:sticky;top:0;z-index:var(--z-header);isolation:isolate}
header::before{content:'';position:absolute;inset:0;z-index:-1;pointer-events:none;
  background:linear-gradient(to bottom,rgba(255,255,255,.80),rgba(255,255,255,.62));
  backdrop-filter:saturate(180%) blur(20px);-webkit-backdrop-filter:saturate(180%) blur(20px)}
@media (prefers-color-scheme:dark){ html:not([data-theme="light"]) header::before{background:rgba(14,14,16,.72)} }
html[data-theme="dark"] header::before{background:rgba(14,14,16,.72)}
/* 悬浮层压住内容的地方用一小段渐隐收口，而不是画一条 1px 的硬线 ——
   材质是"内容从下面滑过去"，硬线会把它变回一个占位的横条。 */
header::after{content:'';position:absolute;left:0;right:0;top:100%;height:18px;pointer-events:none;
  background:linear-gradient(var(--bg),transparent);opacity:0;
  transition:opacity var(--t-m) var(--e-soft)}
header.stuck::after{opacity:.9}
/* 白底之上"内容从下面滑过去"的渐隐看不出来了，吸住时补一道 1px 描边 */
header.stuck{box-shadow:0 var(--hairw) 0 var(--line)}
.bar{display:flex;align-items:center;gap:12px;height:56px}
.brand{display:flex;align-items:center;gap:9px;flex:none;background:none;border:0;cursor:pointer;
  padding:0;position:relative}
.brand::before{content:'';position:absolute;inset:-9px -4px}   /* 26 + 9x2 = 44 高；两侧各 4px，与返回键的 4px 正好填满 8px 间距 */
.mark{width:26px;height:26px;border-radius:9px;background:var(--ink);color:var(--inkf);flex:none;
  display:grid;place-items:center;font-size:.8125rem;font-weight:var(--fw-x);
  letter-spacing:-.04em;line-height:1;
  transition:transform var(--t-press) ease-out}
.brand:active .mark{transform:scale(.96)}
.bname{font-size:1.125rem;font-weight:var(--fw-x);letter-spacing:.012em;white-space:nowrap}
.bname em{font-style:normal;color:var(--t3);font-weight:500}       /* 「Cuven Transfer」那种两级：商标墨色、产品名第三层级 */
.bar .sp{flex:1;min-width:0}
.bname sup{font-size:.5625rem;font-weight:var(--fw-m);vertical-align:super;opacity:.5;margin-left:1px}
/* ── 导航（同 Transfer 的坞）──
   一块玻璃，三项共用一块白 thumb：切页时 thumb 在项与项之间平移 + 改宽（JS 量位置），
   不是各自的背景各自亮。选中态两个信号：thumb 位移 + 墨色字重 650，不只靠颜色。
   三项等宽（flex:1 1 0），字重变化不会让邻居挪位。 */
nav.pills{position:relative;display:flex;gap:0;margin:0;padding:4px;border-radius:999px;
  background:rgba(var(--glass-rgb),var(--glass-a));
  -webkit-backdrop-filter:blur(20px) saturate(180%);backdrop-filter:blur(20px) saturate(180%);
  box-shadow:inset 0 0 0 1px rgba(20,20,30,.05)}
nav.pills .hl{position:absolute;left:0;top:4px;bottom:4px;width:0;border-radius:999px;pointer-events:none;
  background:var(--thumb);box-shadow:var(--sh-thumb);opacity:0;
  transition:transform calc(.42s*var(--silk)) var(--e-morph),width calc(.42s*var(--silk)) var(--e-morph),opacity .2s ease}
nav.pills .hl.on{opacity:1}
nav.pills button{position:relative;z-index:1;flex:1 1 0;min-width:78px;border:0;background:none;color:var(--t3);
  font-size:.8125rem;font-weight:500;min-height:32px;padding:0 14px;border-radius:999px;cursor:pointer;
  white-space:nowrap;display:flex;align-items:center;justify-content:center;gap:4px;
  transition:color .3s ease,font-weight .3s ease}
nav.pills button::before{content:'';position:absolute;inset:-6px 0}   /* 32 + 6 + 6 = 44 */
nav.pills button.on{color:var(--ink);font-weight:650}
nav.pills .ic{display:none;place-items:center;height:20px;transition:transform calc(.3s*var(--silk)) var(--e-morph)}
nav.pills .ic svg{display:block}
nav.pills button:active .ic{transform:scale(.88);transition-duration:var(--t-press)}
/* 徽标的宽度是常驻的：数字从无到有、从 9 到 10，导航都不会跟着挪 */
nav.pills button i{font-style:normal;font-size:.6875rem;opacity:.5;margin-left:5px;
  display:inline-block;min-width:1.9em;text-align:right}
nav.pills button i:empty{min-width:0;margin-left:0}
/* 源开关（电影 / 剧集）：与主导航同一套药丸，尺寸收一档，坐在工具区最左。
   它换的是"看哪一个库"，和换标签页不是一回事，所以不跟 nav 混在一起。 */
.pills.mini{display:flex;gap:2px;background:var(--sf3);border-radius:999px;padding:3px;flex:none;
  box-shadow:inset 0 0 0 1px rgba(20,20,30,.04)}
.pills.mini button{border:0;background:none;color:var(--t2);font-size:.78125rem;height:30px;
  padding:0 11px;border-radius:999px;cursor:pointer;position:relative;white-space:nowrap;
  font-weight:var(--fw-m);letter-spacing:var(--tr-xs);
  transition:background var(--t-s) var(--e-soft),color var(--t-s) var(--e-soft),
             transform var(--t-press) ease-out}
.pills.mini button::before{content:'';position:absolute;inset:-7px 0}  /* 30 + 7x2 = 44 */
.pills.mini button.on{background:var(--thumb);color:var(--ink);box-shadow:var(--sh-thumb)}
.pills.mini button:active{transform:scale(.97)}
.tools{display:flex;align-items:center;gap:8px;flex:none}
/* 宽度不参与动画：它是布局属性，而且 / 快捷键也会触发聚焦 ——
   键盘发起的动作不该有动画。聚焦的状态指示交给底色和阴影。 */
.field{display:flex;align-items:center;gap:7px;background:var(--sf);border-radius:999px;
  padding:0 13px;width:240px;min-height:36px;box-shadow:inset 0 0 0 1px var(--line);
  transition:box-shadow .16s ease}
.field:focus-within{box-shadow:inset 0 0 0 1px var(--ac),0 0 0 3px var(--acb)}
.field svg{flex:none;color:var(--t3)}
#q{flex:1;min-width:0;background:none;border:0;font-size:.875rem;align-self:stretch}
#q:focus-visible{outline:0}
.field:has(#q:focus-visible){outline:0}   /* 聚焦信号交给上面的描边 + 淡环 */
/* 没有 :has() 的老浏览器：把环还给输入框本身，宁可位置将就，也不能没有 */
@supports not (selector(:has(*))){ #q:focus-visible{outline:2px solid var(--ac);outline-offset:-1px} }
#q::placeholder{color:var(--t3)}
/* 清空键用 visibility 收起，不用 display —— 后者会让输入框在打字的第一个
   字符处宽度一跳。位置常驻，出现与否不影响布局。 */
#clr{border:0;background:var(--sf4);color:var(--t2);width:20px;height:20px;
  border-radius:50%;font-size:.6875rem;line-height:1;cursor:pointer;flex:none;
  display:grid;place-items:center;position:relative;visibility:hidden;
  transition:opacity var(--t-s) var(--e-soft);opacity:0}
/* 左边紧挨着输入框，只能撑到 7px（正好是那道间距），再多就抢输入框的点击；
   右边一直撑到搜索框内壁。这是不与邻居打架的前提下能给到的最大命中区。 */
#clr::before{content:'';position:absolute;inset:-12px -13px -12px -7px}
#clr.on{visibility:visible;opacity:1}
.icb{border:0;background:var(--sf);box-shadow:inset 0 0 0 1px var(--line);color:var(--t1);width:36px;height:36px;border-radius:50%;
  display:grid;place-items:center;cursor:pointer;flex:none;position:relative;
  transition:background var(--t-s) var(--e-soft),transform var(--t-press) ease-out}
.icb::before{content:'';position:absolute;inset:-4px -5px}  /* 46×44；左右各 5px 都落在与邻居之间的空隙里 */
.icb:active{transform:scale(.96)}
/* 左向人字是偏心的：视觉重量在右、尖角在左，往尖角方向挪 1px 才看着居中 */
#back svg{transform:translateX(-1px)}
#back{display:none}
#back.on{display:grid}
/* 外观键的字形由 CSS 出，于是首帧就是对的，不用等脚本跑完再补一次 */
/* 外观图标画在 ::after 上：原来的 ◐ 写在 ::before —— 那是 .icb 撑命中区用的绝对定位伪元素，
   字形于是被钉在圆的左上角、裁掉一半。图标也改成画的，不再赌字体回退字形的大小与基线。
   跟随系统 = 半实心圆；浅色 = 空心圆；深色 = 实心圆 */
#theme::after{content:'';width:15px;height:15px;border-radius:50%;box-sizing:border-box;
  border:1.6px solid currentColor;background:linear-gradient(90deg,currentColor 50%,transparent 50%)}
html[data-theme="light"] #theme::after{background:none}
html[data-theme="dark"] #theme::after{background:currentColor}
@media(max-width:900px){
  .bname{display:none}
  .field{width:170px}
  nav.pills button{min-width:64px;padding:0 10px;font-size:.78125rem}
}
/* ── 手机 / 竖屏平板：导航落成底部玻璃坞（Transfer 同款）──
   354×68 的 stadium，图标 + 字；thumb 是同一块白在三项之间平移。
   顶栏只剩商标、源开关、外观，一行放得下；搜索另起一行占满。 */
@media(max-width:720px){
  .bname{display:inline}
  nav.pills#nav{position:fixed;left:50%;bottom:calc(env(safe-area-inset-bottom) + 14px);z-index:var(--z-dock);
    transform:translateX(-50%);width:min(390px,calc(100vw - 36px));height:var(--nav-h);padding:5px;margin:0;
    box-shadow:var(--sh-float);transition:box-shadow .34s var(--e-out)}
  nav.pills#nav .hl{top:5px;bottom:5px}
  nav.pills#nav button{flex-direction:column;gap:4px;min-height:0;min-width:0;padding:9px 0 8px;
    font-size:.71875rem;letter-spacing:.012em}
  nav.pills#nav button::before{inset:0}
  nav.pills#nav .ic{display:grid}
  /* 片单数量：挂在图标右上角的小墨点，不占字的位置 */
  nav.pills#nav button i{position:absolute;top:6px;left:calc(50% + 7px);margin:0;min-width:17px;height:17px;
    padding:0 5px;border-radius:999px;background:var(--ink);color:var(--inkf);opacity:1;
    font-size:.625rem;font-weight:650;line-height:17px;text-align:center}
  nav.pills#nav button i:empty{display:none}
  body{padding-bottom:calc(env(safe-area-inset-bottom) + 104px)}
  body::after{opacity:1}
  body:has(#dock.up){padding-bottom:calc(env(safe-area-inset-bottom) + 178px)}
  #push{padding-bottom:calc(env(safe-area-inset-bottom) + 112px)}
}
@media(max-width:600px){
  /* 详情页多出返回键：商标收成只剩 C，一行仍放得下（否则外观钮会掉到第二行、顶栏变三行盖住标题） */
  #back.on ~ .brand .bname{display:none}
  .bar{gap:10px;flex-wrap:wrap;height:auto;padding-top:8px;padding-bottom:8px}   /* 只动上下：左右留白是 .wrap 的，原来 padding:8px 0 把它清零了，商标和搜索框贴着屏幕边 */
  .tools{display:contents}
  #srcNav{order:2}
  #theme{order:3}
  .field{order:4;flex:1 1 100%;width:auto;min-width:200px}
  .pills.mini button{padding:0 9px}
}

/* ── 通用件 ─────────────────────────────────────────────────────── */
/* 大标题让浏览器去平衡断行，避免最后一行只剩两个字 */
/* 字距按 Transfer 实测的 U 形曲线：31px 一档是 +.004em，不是正文那档的负字距 */
h1{font-size:1.9375rem;font-weight:var(--fw-x);letter-spacing:.004em;
  margin:26px 0 4px;line-height:var(--lh-t);text-wrap:balance}
.lede{color:var(--t2);font-size:.9375rem;margin-bottom:2px;letter-spacing:-.006em}
h2.sec{font-size:1.0625rem;font-weight:650;letter-spacing:-.022em;margin:0;
  line-height:var(--lh-h);text-wrap:balance}
h3{font-size:1rem;font-weight:var(--fw-s);letter-spacing:var(--tr-b);line-height:var(--lh-h);
  text-wrap:balance}
.card{background:var(--sf);border-radius:var(--r-card);box-shadow:var(--sh);padding:20px;
  margin:16px 0;isolation:isolate;transition:box-shadow var(--t-m) var(--e-soft)}
.card.tight{padding:16px}
.hd{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px}
.hd .sub{font-size:.75rem;color:var(--t3);font-family:var(--mono)}
/* 主按钮直接给足真实高度（精细指针 40，触屏 44），不靠伪元素撑 ——
   它周围有 9px 的行间距，撑出去反而会和邻居打架。 */
/* 次级动作：白底发丝描边；主行动：墨色实心（同 Transfer 的 .btn.pri）。
   按压反馈拆两段：按下 80ms 即时到位，松手沿 --e-morph 回弹 */
.btn{background:var(--sf);color:var(--t1);border:0;box-shadow:inset 0 0 0 1px var(--line);border-radius:var(--r-in);
  padding:0 16px;min-height:var(--hit-d);display:inline-flex;align-items:center;
  justify-content:center;font-size:.84375rem;font-weight:550;cursor:pointer;
  text-decoration:none;letter-spacing:-.012em;
  transition:transform calc(.3s*var(--silk)) var(--e-morph),background .16s ease,box-shadow .16s ease,opacity .16s}
.btn:active{transform:scale(.97);background:var(--sf2);transition-duration:var(--t-press),.16s,.16s,.16s}
.btn.on,.btn.ink{background:var(--ink);color:var(--inkf);box-shadow:0 1px 2px rgba(17,17,20,.18)}
.btn.on:active,.btn.ink:active{background:var(--ink-d)}
.btn[disabled]{opacity:.42;cursor:default;transform:none}
/* 文案会在忙碌时换成"处理中…"，宽度先占住，行内的兄弟按钮就不会左右滑 */
.btn.fixed{min-width:8.5em}
.btn.sm.fixed{min-width:6.5em}
.btn.sm{padding:0 12px;font-size:.78125rem;border-radius:var(--r-s);min-height:32px;position:relative}
.btn.sm::before{content:'';position:absolute;inset:-6px 0}   /* 32 + 6×2 = 44 */
.link{background:none;border:0;color:var(--act);font-size:.78125rem;cursor:pointer;padding:0;
  text-decoration:underline;text-decoration-color:oklch(var(--sky-lch) / .4);text-underline-offset:4px;position:relative;
  transition:color var(--t-xs) var(--e-soft)}
.link::before{content:'';position:absolute;inset:-11px -7px}
@media(pointer:coarse){ .btn{min-height:var(--hit)} }
/* 触屏上点一下会留下"假 hover"，一直粘到点别处为止 —— 按钮看起来像还选中着。
   所以 hover 只在真有精细指针的设备上生效；:active 不受此限，触屏必须有按压反馈。 */
@media (hover:hover) and (pointer:fine){
  .icb:hover{background:var(--sf2)}
  .btn:hover{background:var(--sf2)}
  .btn.on:hover,.btn.ink:hover{background:var(--ink-d)}
  .link:hover{color:var(--t1)}
  .citem .cx:hover{color:var(--bad)}
  .art:hover{transform:translateY(-3px);box-shadow:var(--sh-l)}
}
/* 换行时的行距给到 12px：小按钮的命中区上下各撑 6px，正好接上不重叠 */
.row{display:flex;column-gap:9px;row-gap:12px;flex-wrap:wrap;align-items:center}
.grow{flex:1}
.pill{display:inline-flex;align-items:center;gap:5px;font-size:.6875rem;
  font-weight:var(--fw-s);padding:3px 9px;border-radius:999px;background:var(--sf3);
  color:var(--t2);letter-spacing:var(--tr-xs)}
.pill.ok{background:var(--okb);color:var(--ok)}
.pill.warn{background:var(--warnb);color:var(--warn)}
.pill.bad{background:var(--badb);color:var(--bad)}
.dot{width:7px;height:7px;border-radius:50%;background:var(--t3);flex:none}
.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}.dot.bad{background:var(--bad)}
.dot.live{background:var(--ok);animation:pulse 1.9s var(--e-soft) infinite}
@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.35;transform:scale(.75)}}
.err{color:var(--bad);font-size:.875rem;background:var(--badb);border-radius:var(--r-m);padding:13px 16px;margin:16px 0}
.warnbox{color:var(--warn);font-size:.8125rem;background:var(--warnb);border-radius:var(--r-m);
  padding:12px 15px;margin:12px 0;line-height:var(--lh-r)}
/* ── 空状态 ──
   空列表是这一屏的第一次见面，不是出错。所以它要说清三件事：
   这里本来该有什么、为什么现在没有、按哪儿能让它有。
   高度按"装满时"的尺寸预留，填上内容不会把下面的东西顶走。 */
.empty{display:flex;flex-direction:column;align-items:center;justify-content:center;
  text-align:center;gap:7px;min-height:var(--empty-h,220px);padding:32px 20px}
.empty h3{color:var(--t1)}
.empty p{color:var(--t3);font-size:.8125rem;line-height:var(--lh-r);max-width:34em;
  letter-spacing:var(--tr-s)}
.empty .row{justify-content:center;margin-top:7px}
.bar2{height:4px;background:var(--sf3);border-radius:999px;overflow:hidden}
/* 进度用 scaleX 而不是 width：width 每变一次都要重排，而下载页一次会变几十次 */
.bar2 i{display:block;height:100%;width:100%;background:var(--ac);border-radius:999px;
  transform:scaleX(0);transform-origin:left center;
  transition:transform var(--t-l) var(--e-std)}
.bar2 i.ok{background:var(--ok)}
.bar2 i.bad{background:var(--bad)}

/* ── 筛选台 ─────────────────────────────────────────────────────── */
/* 吸顶高度跟着实测的顶栏走，顶栏在手机上换行也不会错位 */
.filters{position:sticky;top:var(--hh,56px);z-index:var(--z-sticky);background:transparent;
  padding:10px var(--padr) 6px var(--pad);transition:box-shadow var(--t-m) var(--e-soft);
  margin-left:calc(var(--pad)*-1);margin-right:calc(var(--padr)*-1)}
/* 吸住的时候补一道描边：白底上没有它，就看不出下面还有内容在滑 */
/* 没吸住时筛选台就是纸面上的一组控件；吸住了才换上与顶栏同一层玻璃 */
.filters.stuck{box-shadow:0 var(--hairw) 0 var(--line);
  background:linear-gradient(to bottom,rgba(255,255,255,.80),rgba(255,255,255,.66));
  -webkit-backdrop-filter:saturate(180%) blur(20px);backdrop-filter:saturate(180%) blur(20px)}
@media (prefers-color-scheme:dark){ html:not([data-theme="light"]) .filters.stuck{background:rgba(14,14,16,.72)} }
html[data-theme="dark"] .filters.stuck{background:rgba(14,14,16,.72)}
@media(max-width:600px){ .filters{background:none;-webkit-backdrop-filter:none;backdrop-filter:none} }
@media(max-width:600px){.filters{top:0;position:relative}}
/* 行距 14px：上下两行的命中区各撑 6px，正好不重叠 */
.fgroup{display:flex;align-items:center;gap:8px;margin-bottom:14px;flex-wrap:wrap}
.fgroup>span.lb{font-size:.71875rem;color:var(--t3);font-weight:var(--fw-s);
  letter-spacing:var(--tr-xs);width:52px;flex:none}
.seg{display:inline-flex;background:var(--sf3);border-radius:999px;padding:3px;gap:2px;box-shadow:inset 0 0 0 1px rgba(20,20,30,.04)}
.seg button{border:0;background:none;color:var(--t2);font-size:.78125rem;
  font-weight:var(--fw-m);min-height:30px;padding:0 13px;border-radius:999px;cursor:pointer;
  white-space:nowrap;position:relative;
  transition:color var(--t-s) var(--e-soft),background var(--t-s) var(--e-soft),transform var(--t-press) ease-out}
/* 只往上下撑：左右紧挨着邻居，横向撑出去会互相抢点击 */
.seg button::before{content:'';position:absolute;inset:-7px 0}
.seg button.on{background:var(--thumb);color:var(--ink);box-shadow:var(--sh-thumb)}
.seg button:active{transform:scale(.96)}
.seg button em{font-style:normal;opacity:.45;font-size:.65625rem;margin-left:4px}
.chips{display:flex;gap:6px;overflow-x:auto;overscroll-behavior-x:contain;flex:1;min-width:0;
  padding:6px 0 8px;scrollbar-width:none;-webkit-overflow-scrolling:touch;scroll-snap-type:x proximity}
.chips::-webkit-scrollbar{display:none}
.chips button{flex:none;border:0;background:var(--sf);box-shadow:inset 0 0 0 1px var(--line);color:var(--t2);font-size:.78125rem;
  font-weight:var(--fw-m);min-height:32px;padding:0 13px;border-radius:999px;cursor:pointer;
  scroll-snap-align:center;position:relative;
  transition:color var(--t-s) var(--e-soft),background var(--t-s) var(--e-soft),transform var(--t-press) ease-out}
/* 伸到容器的内边距边缘为止 —— 再往外就会被滚动容器裁掉，白撑 */
.chips button::before{content:'';position:absolute;inset:-6px 0}
.chips button.on{background:var(--ink);color:var(--inkf);box-shadow:none}
.chips button:active{transform:scale(.96)}
.fsum{display:flex;align-items:center;gap:10px;font-size:.75rem;color:var(--t3);
  padding:2px 0 8px;flex-wrap:wrap}
.fsum .sp{opacity:.4}

/* ── 海报网格 ───────────────────────────────────────────────────── */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(132px,1fr));gap:26px 16px;margin:6px 0 8px}
@media(max-width:600px){.grid{grid-template-columns:repeat(3,1fr);gap:20px 11px}}
@media(max-width:380px){.grid{grid-template-columns:repeat(2,1fr)}}
/* 网格每换一次筛选就整体重建，属于"一天几十次"那一档：位移是噪声，
   只留一次极轻的淡入，把内容替换的硬跳圆掉即可。 */
.tile{position:relative;isolation:isolate;animation:rise var(--t-fast) var(--e-out) backwards}
@keyframes rise{from{opacity:0}to{opacity:1}}
.art{position:relative;aspect-ratio:2/3;border-radius:var(--r-m);overflow:hidden;
  background:var(--poster);box-shadow:var(--sh);border:0;padding:0;width:100%;
  cursor:pointer;display:block;
  transition:transform var(--t-press) ease-out,box-shadow var(--t-m) var(--e-soft)}
/* 按下的那一刻就给反馈，不等抬手 */
.art:active{transform:scale(.96)}
.art.cancel:active{transform:none}
.art img{width:100%;height:100%;object-fit:cover;display:block;opacity:0;
  transition:opacity var(--t-l) var(--e-soft),filter var(--t-m) var(--e-soft)}
.art img.in{opacity:1}
.art img.err{display:none}
.badge{position:absolute;font-size:.625rem;font-weight:var(--fw-s);line-height:1.55;
  border-radius:6px;padding:2px 6px;letter-spacing:var(--tr-xs);white-space:nowrap;
  backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px)}
.b-vote{left:6px;bottom:6px;background:rgba(0,0,0,.62);color:#fff;font-family:var(--mono)}
.b-n{top:6px;right:6px;background:rgba(0,0,0,.62);color:rgba(255,255,255,.8);font-family:var(--mono)}
/* 左上的规格角标与右上的版本数共用一行：给版本数留出位置，窄海报上也不压在一起 */
.b-dv,.b-hdr{max-width:calc(100% - 42px);overflow:hidden;text-overflow:ellipsis}
.b-dv{left:6px;top:6px;background:linear-gradient(100deg,#1B1B1F,#3A3A44);color:#fff;letter-spacing:.04em}
.b-hdr{left:6px;top:6px;background:rgba(0,0,0,.62);color:#FFD98A;letter-spacing:.04em}
.b-own{right:6px;bottom:6px;background:rgba(255,255,255,.94);color:#000;box-shadow:0 1px 6px rgba(0,0,0,.3)}
.b-own.weak{background:rgba(255,255,255,.72);color:rgba(0,0,0,.66)}
.tick{position:absolute;inset:0;background:rgba(0,0,0,.42);opacity:0;
  transition:opacity var(--t-m) var(--e-soft);display:flex;align-items:flex-start;justify-content:flex-end;padding:7px}
.tick span{width:23px;height:23px;border-radius:50%;background:#fff;color:#000;font-size:.875rem;
  display:grid;place-items:center;line-height:1;font-weight:var(--fw-x);
  transform:scale(.86);opacity:0;
  transition:transform var(--t-m) var(--e-pop),opacity var(--t-s) var(--e-soft)}
.tile.in .tick{opacity:1}
.tile.in .tick span{transform:scale(1);opacity:1}
.tile.in .art{box-shadow:0 0 0 2.5px var(--ink),var(--sh)}      /* 选中是交互态：墨色，不是数据蓝 */
.tile.own .art img.in{opacity:.34;filter:grayscale(.55)}
.tile.own .tname b{color:var(--t2)}
.tname{display:block;width:100%;text-align:left;background:none;border:0;padding:9px 2px 0;cursor:pointer}
/* 标题固定占两行的高度：片名长短不一时整行卡片不会参差，骨架屏换成
   真内容那一下也不会把下面的整片网格顶下去。 */
.tname b{display:-webkit-box;font-size:.8125rem;font-weight:var(--fw-m);line-height:1.34;
  -webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;
  min-height:calc(.8125rem * 1.34 * 2)}
.tname em{font-style:normal;font-size:.71875rem;color:var(--t3);display:block;margin-top:2px;
  min-height:calc(.71875rem * 1.5);letter-spacing:var(--tr-s)}
/* 骨架屏与真卡片逐像素同高：海报是 2:3，标题两行，副标题一行 */
.skn{padding:9px 2px 0}
.skn span{display:block;height:calc(.8125rem * 1.34 * 2);border-radius:6px}
.skn span+span{height:calc(.71875rem * 1.5);width:56%;margin-top:2px;border-radius:5px}
.shimmer{background:linear-gradient(100deg,var(--sf3) 28%,var(--sf2) 48%,var(--sf3) 68%);
  background-size:220% 100%;animation:sh 1.4s linear infinite;border-radius:var(--r-m)}
@keyframes sh{to{background-position:-120% 0}}
#sent{height:1px}
.tail{display:flex;justify-content:center;align-items:center;height:68px;color:var(--t3);font-size:.8125rem}
.tail.hide{display:none}
.spin{width:18px;height:18px;border:2px solid var(--sf4);border-top-color:var(--t2);
  border-radius:50%;animation:sp .7s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}

/* ── 详情 ───────────────────────────────────────────────────────── */
.hero{display:flex;gap:22px;padding:20px 0 4px;align-items:flex-start}
.hero .art{width:132px;flex:none;cursor:default}
.hero .art:hover{transform:none;box-shadow:var(--sh)}
.hero h2{font-size:1.625rem;font-weight:var(--fw-b);letter-spacing:var(--tr-xl);
  line-height:var(--lh-t);text-wrap:balance}
.hero .fine{color:var(--t2);font-size:.8125rem;margin:8px 0 10px;
  font-variant-numeric:tabular-nums;letter-spacing:var(--tr-s)}
.hero p{color:var(--t2);font-size:.875rem;line-height:1.6;
  display:-webkit-box;-webkit-line-clamp:5;-webkit-box-orient:vertical;overflow:hidden}
@media(max-width:600px){.hero{gap:16px}.hero .art{width:98px}.hero h2{font-size:1.3125rem;letter-spacing:var(--tr-l)}.hero p{-webkit-line-clamp:3}}
.pick{background:var(--ink);color:var(--inkf);border-radius:var(--r-card);padding:20px;margin:16px 0 12px}
.pick .k{font-size:.65625rem;font-weight:var(--fw-x);letter-spacing:.09em;text-transform:uppercase;opacity:.5}
.pick h4{font-size:.96875rem;font-weight:var(--fw-s);line-height:1.45;margin:7px 0 10px;
  letter-spacing:var(--tr-b);
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.pick .why{font-family:var(--mono);font-size:.71875rem;opacity:.62;margin-bottom:14px;line-height:1.55}
.pick .acts{display:flex;gap:8px}
.pick .acts button{flex:1;background:var(--inkf);color:var(--ink);border:0;border-radius:var(--r-s);
  min-height:var(--hit-d);font-size:.875rem;font-weight:var(--fw-m);cursor:pointer;
  transition:transform var(--t-press) ease-out}
.pick .acts .ghost{background:rgba(127,127,127,.22);color:var(--inkf)}
.pick .acts button:active{transform:scale(.96)}
@media(pointer:coarse){.pick .acts button{min-height:var(--hit)}}
.rel{border-bottom:1px solid var(--line);padding:14px 2px;cursor:pointer;transition:opacity var(--t-s)}
.rel:last-child{border-bottom:0}
.rel:active{opacity:.55}
.rel .t{font-size:.875rem;font-weight:var(--fw-m);line-height:1.45;
  display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.spec{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;font-family:var(--mono);font-size:.6875rem;
  color:var(--t3);align-items:center}
.spec i{font-style:normal}
.spec i.hi{color:var(--t1);font-weight:var(--fw-s)}
.spec i.sep{opacity:.35}
.att{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:9px 0;border-bottom:1px solid var(--line)}
.att:last-child{border-bottom:0}
.att .fn{flex:1;min-width:170px;font-family:var(--mono);font-size:.71875rem;color:var(--t2);word-break:break-all}
.hash{margin-top:9px;font-family:var(--mono);font-size:.6875rem;color:var(--t3);word-break:break-all;line-height:1.65}
.slot:empty{display:none}
.panel{margin:12px 0 4px;background:var(--sf2);border-radius:var(--r-m);padding:14px 16px;border:1px solid var(--line)}
</style>
<style>
/* ── 下载台 ─────────────────────────────────────────────────────── */
.kpi{display:flex;gap:28px;flex-wrap:wrap}
.kpi div b{display:block;font-size:1.9375rem;font-weight:var(--fw-x);letter-spacing:.004em;
  line-height:1.1}
.kpi div em{font-style:normal;font-size:.71875rem;color:var(--t3);letter-spacing:var(--tr-xs)}
.dl-head{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:12px}
.dl-head b{font-size:2.125rem;font-weight:var(--fw-b);letter-spacing:var(--tr-2xl);
  line-height:var(--lh-t)}
.dl-head span{font-size:.8125rem;color:var(--t2)}
.dl-meta{display:flex;gap:16px;flex-wrap:wrap;font-size:.75rem;color:var(--t3);margin-top:11px}
.dl-meta i{font-style:normal;color:var(--t2);font-weight:var(--fw-m)}
.qlist{margin-top:14px;max-height:340px;overflow:auto;border-radius:var(--r-m);background:var(--sf2);border:1px solid var(--line)}
.qrow{display:flex;align-items:center;gap:10px;padding:9px 13px;border-bottom:1px solid var(--line);
  font-size:.78125rem;min-height:38px;transition:background var(--t-s) var(--e-soft)}
.qrow:last-child{border-bottom:0}
.qrow .qn{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--t2)}
.qrow.done .qn{color:var(--t1)}
/* 状态字的宽度先占住：一行从"等待"变成"已取"时，片名不会跟着左右滑 */
.qrow .qs{flex:none;font-family:var(--mono);font-size:.65625rem;color:var(--t3);
  min-width:4.4em;text-align:right}
.qrow.done .qs{color:var(--ok)}
.qrow.fail .qs{color:var(--bad)}
.citem{display:flex;gap:13px;align-items:center;padding:12px 2px;border-bottom:1px solid var(--line)}
.citem:last-of-type{border-bottom:0}
.citem .cth{width:44px;flex:none;aspect-ratio:2/3;border-radius:7px;overflow:hidden;background:var(--poster)}
.citem .cth img{width:100%;height:100%;object-fit:cover;display:block}
.citem .cb{flex:1;min-width:0}
.citem .cb b{display:block;font-size:.875rem;font-weight:var(--fw-m);line-height:1.4;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.citem .cb em{font-style:normal;font-family:var(--mono);font-size:.6875rem;color:var(--t3);
  display:block;margin-top:3px}
.citem .cx{flex:none;background:none;border:0;color:var(--t3);font-size:1.125rem;cursor:pointer;
  width:22px;height:22px;display:grid;place-items:center;line-height:1;position:relative;
  transition:color var(--t-s) var(--e-soft)}
.citem .cx::before{content:'';position:absolute;inset:-11px}   /* 22 + 11×2 = 44 */
/* [v6.6] 导入清单 */
.imp textarea{display:block;width:100%;min-height:150px;resize:vertical;background:var(--sf2);color:var(--t1);border:0;
  box-shadow:inset 0 0 0 1px var(--line);border-radius:var(--r-m);padding:12px 14px;font-family:var(--mono);
  font-size:.75rem;line-height:1.6;transition:box-shadow .16s ease}
.imp textarea:focus-visible{outline:0;box-shadow:inset 0 0 0 1px var(--ac),0 0 0 3px var(--acb)}
.imp textarea[disabled]{opacity:.6}
.imp p.fine{margin:10px 2px 14px}
.imp label.btn[aria-disabled]{opacity:.42;pointer-events:none}
.imp-sum{display:flex;flex-wrap:wrap;gap:6px;margin:16px 0 10px}
.ilist{max-height:440px;overflow:auto;margin-top:8px;border-top:1px solid var(--line)}
.irow{display:flex;gap:11px;align-items:flex-start;padding:11px 2px;border-bottom:1px solid var(--line);font-size:.8125rem}
.irow:last-child{border-bottom:0}
.irow > .dot{margin-top:6px}
.irow .ib{flex:1;min-width:0}
.irow .ib b{font-weight:var(--fw-m)}
.irow .ib .num{color:var(--t3);font-size:.75rem}
.irow .ib em{display:block;font-style:normal;color:var(--t3);font-size:.71875rem;margin-top:3px;line-height:1.5;overflow-wrap:anywhere}
.irow > .pill{flex:none}
.irow .cands{display:flex;flex-wrap:wrap;gap:8px;margin-top:9px}
.imp-prog{margin-top:10px;font-size:.75rem;color:var(--t3);justify-content:space-between}
.imp-prog span{flex:1;min-width:0;line-height:1.5}

/* ── 索引管线可视化 ─────────────────────────────────────────────── */
.flow{display:flex;align-items:stretch;gap:0;overflow-x:auto;padding:4px 0 10px;
  scrollbar-width:none;-webkit-overflow-scrolling:touch}
.flow::-webkit-scrollbar{display:none}
.node{flex:1;min-width:104px;background:var(--sf2);border-radius:var(--r-m);padding:12px 13px;border:1px solid var(--line);
  position:relative;transition:background var(--t-m) var(--e-soft),transform var(--t-m) var(--e-std)}
.node.act{background:var(--sf3)}
.node.err{background:var(--badb)}
.node .nn{font-size:.71875rem;color:var(--t3);font-weight:var(--fw-s);letter-spacing:var(--tr-xs);
  display:flex;align-items:center;gap:5px}
.node .nv{font-size:1.375rem;font-weight:var(--fw-b);letter-spacing:var(--tr-l);margin-top:5px;
  line-height:1.1}
.node .ns{font-size:.65625rem;color:var(--t3);font-family:var(--mono);margin-top:3px;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.node .ns b{color:var(--bad);font-weight:var(--fw-s)}
.link2{flex:none;width:22px;position:relative;align-self:center;height:2px;background:var(--line2);
  border-radius:2px;overflow:hidden}
.link2 i{position:absolute;top:0;left:-40%;width:40%;height:100%;background:var(--ac);border-radius:2px;opacity:0}
/* 序号由模板写进 --i。原来用 nth-of-type 是错的：节点和连接线都是 div、
   又是交错排列，nth-of-type 数的是元素类型，五条里只命中得了两条。 */
.flow.run .link2 i{opacity:.85;
  animation:flowdot 1.5s var(--e-soft) infinite;
  animation-delay:calc(var(--i, 0) * 70ms)}
@keyframes flowdot{0%{left:-40%}70%,100%{left:110%}}
@media(max-width:700px){.node{min-width:92px;padding:10px}.node .nv{font-size:1.125rem}.link2{width:12px}}

.spark{display:flex;align-items:flex-end;gap:3px;height:34px;margin-top:12px}
.spark i{flex:1;max-width:22px;height:100%;background:var(--sf4);border-radius:2px;
  transform:scaleY(.06);transform-origin:bottom center;
  transition:transform var(--t-l) var(--e-std),background var(--t-m) var(--e-soft)}
.spark i.hot{background:var(--ac)}
.quota{display:flex;align-items:center;gap:10px;margin-top:12px}
.quota .bar2{flex:1}
.quota span{font-size:.6875rem;color:var(--t3);font-family:var(--mono);flex:none}

.yr{display:flex;align-items:center;gap:12px;padding:0 2px;min-height:var(--hit-d);
  border-bottom:1px solid var(--line);cursor:pointer;transition:opacity var(--t-s)}
.yr:last-of-type{border-bottom:0}
.yr:active{opacity:.5}
.yr b{font-family:var(--mono);font-size:.78125rem;font-weight:var(--fw-m);width:42px;flex:none}
.yr .bar2{flex:1}
.yr em{font-style:normal;font-family:var(--mono);font-size:.65625rem;color:var(--t3);
  width:126px;text-align:right;flex:none}
@media(pointer:coarse){.yr{min-height:var(--hit)}}
@media(max-width:600px){.yr em{width:96px}}

/* ── 日志（分频道）─────────────────────────────────────────────── */
.logtabs{display:flex;gap:2px;background:var(--sf3);border-radius:999px;padding:7px 3px;
  overflow-x:auto;scrollbar-width:none}
.logtabs::-webkit-scrollbar{display:none}
.logtabs button{flex:none;border:0;background:none;color:var(--t2);font-size:.75rem;
  font-weight:var(--fw-m);min-height:30px;padding:0 13px;border-radius:999px;cursor:pointer;
  white-space:nowrap;position:relative;
  transition:background var(--t-s) var(--e-soft),color var(--t-s) var(--e-soft)}
/* 同上：这一条也在横向滚动容器里，靠容器的 7px 内边距把 44 让出来 */
.logtabs button::before{content:'';position:absolute;inset:-7px 0}
.logtabs button.on{background:var(--thumb);color:var(--ink);box-shadow:var(--sh-thumb)}
.logtabs button i{font-style:normal;font-size:.625rem;opacity:.5;margin-left:4px;
  font-variant-numeric:tabular-nums}
.logs{margin-top:12px;max-height:300px;overflow:auto;font-family:var(--mono);font-size:.6875rem;line-height:1.6}
.lrow{display:flex;gap:9px;padding:5px 2px;border-bottom:1px solid var(--line);align-items:flex-start}
.lrow:last-child{border-bottom:0}
.lrow .lt{color:var(--t3);flex:none;width:52px;font-variant-numeric:tabular-nums}
.lrow .lm{flex:1;min-width:0;word-break:break-word;color:var(--t2)}
.lrow.warn .lm{color:var(--warn)}
.lrow.err .lm{color:var(--bad)}
.lrow .lc{flex:none;font-size:.59375rem;color:var(--t3);background:var(--sf3);border-radius:4px;padding:1px 5px}

.dg{display:flex;gap:11px;align-items:flex-start;padding:11px 2px;border-bottom:1px solid var(--line)}
.dg:last-child{border-bottom:0}
.dg .dot{margin-top:7px}
.dot.fail{background:var(--bad)}
.grid.preview{opacity:.55;pointer-events:none}
.dg .nm{font-size:.875rem;font-weight:var(--fw-m)}
.dg .dt{font-family:var(--mono);font-size:.6875rem;color:var(--t3);margin-top:3px;line-height:1.55;word-break:break-word}
.dg .fx{flex:none;align-self:center}

/* ── 筛选台的两层 ──
   第一层：排序 + 年份，常驻。第二层：评分 / 已有 / 动态范围 / 画质，
   收在「筛选」里；有非默认项时按钮染成白云蓝并计数 —— 收起来也知道
   列表正被什么过滤着。 */
.fgroup.prime{margin-bottom:10px}
.lb.auto{width:auto;margin-left:6px}
.ftog{border:0;background:var(--sf);box-shadow:inset 0 0 0 1px var(--line);color:var(--t2);min-height:32px;padding:0 11px 0 13px;border-radius:999px;
  font-size:.78125rem;font-weight:var(--fw-m);cursor:pointer;display:inline-flex;align-items:center;gap:6px;
  flex:none;position:relative;letter-spacing:var(--tr-s);
  transition:background var(--t-s) var(--e-soft),color var(--t-s) var(--e-soft),transform var(--t-press) ease-out}
.ftog::before{content:'';position:absolute;inset:-6px 0}
.ftog::after{content:'';width:6px;height:6px;border-right:1.5px solid currentColor;border-bottom:1.5px solid currentColor;
  transform:translateY(-1px) rotate(45deg);transition:transform var(--t-s) var(--e-soft);margin-left:1px;opacity:.7}
.ftog.open::after{transform:translateY(2px) rotate(-135deg)}
.ftog:active{transform:scale(.96)}
.ftog i{font-style:normal;font-size:.65625rem;font-family:var(--mono);min-width:1.45em;height:1.45em;
  border-radius:999px;display:none;place-items:center;background:var(--ink);color:var(--inkf);padding:0 4px;line-height:1}
.ftog.has{color:var(--ink);box-shadow:inset 0 0 0 1px var(--line2)}
.ftog.has i{display:grid}
.ftog.open{box-shadow:inset 0 0 0 1px var(--ac),0 0 0 3px var(--acb);background:var(--sf);color:var(--t1)}
.ftog.open.has{color:var(--ink)}
.fadv{padding-top:2px}
.fadv[hidden]{display:none}
[hidden]{display:none!important}
@media (hover:hover) and (pointer:fine){ .ftog:hover{background:var(--sf2)} }

/* ── 可展开区（系统页）──
   一张卡就是一个区：标题行是开关，其余折在里面。展开状态跨重画、跨刷新
   都保留。不用 9999 的箭头，只有一个跟着转的人字。 */
details.dx{padding:0}
details.dx>summary{list-style:none;display:flex;align-items:center;gap:10px;padding:15px 20px;cursor:pointer;
  min-height:62px;font-size:1.0625rem;font-weight:650;letter-spacing:-.022em;line-height:var(--lh-h);
  -webkit-user-select:none;user-select:none;border-radius:var(--r-card);position:relative;
  transition:background var(--t-s) var(--e-soft)}
details.dx>summary::-webkit-details-marker{display:none}
details.dx>summary::marker{content:''}
details.dx>summary::after{content:'';width:7px;height:7px;border-right:1.6px solid var(--t3);border-bottom:1.6px solid var(--t3);
  transform:translateY(-2px) rotate(45deg);flex:none;margin-left:4px;
  transition:transform var(--t-s) var(--e-soft)}
details.dx[open]>summary::after{transform:translateY(2px) rotate(-135deg)}
details.dx>summary .dxr{margin-left:auto;display:flex;align-items:center;gap:8px;min-width:0}
details.dx>summary .sub{font-size:.75rem;color:var(--t3);font-family:var(--mono);font-weight:var(--fw-r);letter-spacing:0;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
details.dx>summary:focus-visible{outline-offset:-3px}
details.dx>.dxb{padding:0 20px 18px}
details.dx>.dxb>.tail{height:52px}
@media (hover:hover) and (pointer:fine){ details.dx>summary:hover{background:var(--sf2)} }
details.dx[open]>summary{border-bottom-left-radius:0;border-bottom-right-radius:0}
@media(pointer:coarse){ details.dx>summary{min-height:var(--hit)} }
@media(max-width:600px){ details.dx>summary{padding:14px 16px} details.dx>.dxb{padding:0 16px 16px} }

/* ── 系统页的一句状态 ── */
.sysline{display:flex;align-items:center;gap:8px;margin-top:14px;font-size:.84375rem;color:var(--t2);
  letter-spacing:var(--tr-b);line-height:var(--lh-h)}
.sysline b{color:var(--t1);font-weight:var(--fw-m)}
/* 说明性的小字：一律这一档，别再各处自写 style */
p.fine{color:var(--t3);font-size:.78125rem;letter-spacing:var(--tr-s);line-height:var(--lh-r);margin:0}
p.fine.libwhy{margin:-4px 0 10px;overflow-wrap:anywhere}
/* 分页失败：转圈让位给一个重试 */
.tail.err .spin{display:none}
.tail #tailrt{font-size:.8125rem;color:var(--bad)}
.tail #tailrt[hidden]{display:none!important}


/* ── 底部动作坞 ─────────────────────────────────────────────────── */
/* ── 片单胶囊（Transfer 的动作胶囊）──
   原来是贴底的一整条；改成浮在底部的一颗 stadium，玻璃与坞同款。手机上坐在坞的正上方、
   与坞同宽；桌面上居中浮着。退场走加速曲线、比进场快（离场加速），化成一层霜再消失。 */
#dock{position:fixed;left:50%;bottom:calc(env(safe-area-inset-bottom) + 14px);z-index:var(--z-dock);
  width:min(560px,calc(100vw - 36px));padding:8px 8px 8px 22px;border-radius:999px;
  background:rgba(var(--glass-rgb),var(--glass-a));
  -webkit-backdrop-filter:blur(20px) saturate(180%);backdrop-filter:blur(20px) saturate(180%);
  box-shadow:var(--sh-float);
  transform:translate(-50%,calc(100% + 34px)) scale(.965);opacity:0;filter:blur(6px);pointer-events:none;
  transition:transform calc(.26s*var(--silk)) var(--ease-exit),opacity calc(.18s*var(--silk)) var(--ease-exit),
    filter calc(.18s*var(--silk)) var(--ease-exit)}
#dock.up{transform:translate(-50%,0);opacity:1;filter:none;pointer-events:auto;
  transition:transform var(--t-sheet) var(--e-std),opacity calc(.24s*var(--silk)) var(--e-out),filter calc(.24s*var(--silk)) var(--e-out)}
@media(max-width:720px){
  #dock{width:min(390px,calc(100vw - 36px));bottom:calc(env(safe-area-inset-bottom) + 24px + var(--nav-h));padding-left:18px}
}
.dbar{display:flex;align-items:center;gap:8px}
.dbar .dn small:empty{display:none}   /* 胶囊高度由钮定，副行出现与否不会让胶囊跳 */
/* 胶囊里的钮是整颗 stadium（与胶囊同心），高 44 —— 满足命中区 */
#dock .btn{min-height:44px;border-radius:999px;padding:0 16px;background:rgba(255,255,255,.7)}
#dock .btn.on{background:var(--ink);padding:0 20px}
@media (prefers-color-scheme:dark){ html:not([data-theme="light"]) #dock .btn:not(.on){background:rgba(255,255,255,.08)} }
html[data-theme="dark"] #dock .btn:not(.on){background:rgba(255,255,255,.08)}
.dbar .dn{flex:1;font-size:.84375rem;color:var(--t2);min-width:0}
.dbar .dn b{color:var(--t1);font-weight:var(--fw-b)}
/* 副标题行常驻高度：下载开始/结束时动作坞自己不会长高或缩短 */
.dbar .dn small{display:block;font-size:.6875rem;color:var(--t3);margin-top:1px;
  min-height:1.05em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
/* ══════════════════════════════════════════════════════════════════
   推入层 —— 详情页
   详情不再顶掉目录，而是盖在它上面。于是「进」和「出」走同一条路径，
   底下那一层还活着（滚动位置、已加载的分页全在），可以随时被拖回来。
   ══════════════════════════════════════════════════════════════════ */
/* 层级：推入层压在顶栏「下面」。顶栏是半透明材质，内容从它下面滑过去 ——
   既保住了返回键始终可点，也正是这层材质该有的样子。 */
#push{position:fixed;inset:0;z-index:var(--z-push);background:var(--paper-grad) fixed,var(--paper);overflow-y:auto;
  overscroll-behavior-y:contain;-webkit-overflow-scrolling:touch;visibility:hidden;
  transform:translate3d(100%,0,0);box-shadow:-14px 0 40px -18px rgba(0,0,0,.4);
  padding:calc(var(--hh,56px) + 6px) var(--padr) calc(40px + env(safe-area-inset-bottom)) var(--pad)}
#push.on{visibility:visible}
#pushIn{max-width:1180px;margin:0 auto}
/* 底下那一层跟着让开一点：iOS 式的视差，让"上面还有一层"这件事看得见 */
#stack{transition:none}
#scrim{position:fixed;inset:0;z-index:var(--z-scrim);background:#000;opacity:0;
  pointer-events:none;visibility:hidden}
#scrim.on{visibility:visible}
/* 从左边缘往右拖就能把它推回去。边缘条从顶栏下方才开始 ——
   否则它会盖住左上角的返回键。 */
#edge{position:fixed;left:0;top:var(--hh,56px);bottom:0;width:26px;z-index:var(--z-edge);
  display:none;touch-action:pan-y}
#push.on ~ #edge{display:block}
#toast{position:fixed;left:50%;bottom:calc(96px + env(safe-area-inset-bottom));border-radius:var(--r-pop)!important;
  transform:translate(-50%,14px) scale(.96);opacity:0;background:var(--ink);color:var(--inkf);
  border-radius:var(--r-m);padding:11px 20px;font-size:.84375rem;pointer-events:none;
  z-index:var(--z-toast);
  transition:opacity var(--t-m) var(--e-soft),transform var(--t-m) var(--e-std);max-width:86vw;text-align:center;
  box-shadow:var(--sh-l)}
#toast.on{opacity:1;transform:translate(-50%,0) scale(1)}
body:has(#dock.up) #toast{bottom:calc(env(safe-area-inset-bottom) + 92px)}
@media(max-width:720px){
  #toast{bottom:calc(env(safe-area-inset-bottom) + 96px)}
  body:has(#dock.up) #toast{bottom:calc(env(safe-area-inset-bottom) + 170px)}
}
/* 降低透明度：毛玻璃面全部落成实心，模糊一并摘掉；坞的白 thumb 换浅灰 + 内描边，选中态仍看得见 */
@media (prefers-reduced-transparency:reduce){
  header::before,#nav,#dock,.filters{background:var(--sf)!important;-webkit-backdrop-filter:none!important;backdrop-filter:none!important}
  body::after{-webkit-backdrop-filter:none;backdrop-filter:none}
  nav.pills .hl{background:var(--sf3);box-shadow:inset 0 0 0 1px rgba(20,20,30,.07)}
}
/* 高对比：浮面的发丝内描边加深，边界不再只靠投影 */
@media (prefers-contrast:more){
  #nav,#dock{box-shadow:0 8px 26px rgba(18,18,28,.10),inset 0 0 0 1px rgba(20,20,30,.4)}
  .card,.chips button,.btn,.field,.icb,.ftog{--line:oklch(0.822 0.008 286.2)}
}
/* ── 极限模式开关：Transfer 的 Liquid Glass 开关（几何全由 --tw / --th 推导，只改这两个值） ──
   thumb 在过渡中液化成透镜：膨胀 → 背景模糊上来、白色填充退去 → 折射环与高光浮现，落定后固化回实心。
   开态的轨道从左侧生长成墨色（交互重点色），边界始终藏在透镜下面。深色模式下墨色是近白，
   thumb 跟着反成深色（与 .btn.on 的反相一致）。 */
.trow{display:flex;align-items:center;gap:14px;margin-top:16px;padding:12px 14px 12px 16px;
  border-radius:var(--r-in);background:var(--sf2)}
.trow .tl{flex:1;min-width:0}
.trow .tl b{display:block;font-size:.9375rem;font-weight:var(--fw-s);letter-spacing:var(--tr-b);color:var(--t1)}
.trow .tl em{display:block;font-style:normal;font-size:.78125rem;letter-spacing:var(--tr-s);color:var(--t2);
  margin-top:3px;line-height:var(--lh-h)}
.trow .tl em.live{color:var(--act);font-variant-numeric:tabular-nums}
.lg{--tw:58px;--th:32px;
  --inset:calc(var(--th) * .094);--thw:calc(var(--tw) * .536);--thh:calc(var(--th) - var(--inset) * 2);
  --gp:0px;--b:0px;--a:1;--sh:0;
  --gray:oklch(0.945 0.002 286.3);--g-vivid:var(--ink);--g-soft:oklch(0.62 0.006 286.1);--knob:255,255,255;
  position:relative;flex:none;width:var(--tw);height:var(--th);border:0;padding:0;background:none;cursor:pointer;
  border-radius:999px;-webkit-tap-highlight-color:transparent;touch-action:manipulation}
.lg::before{content:'';position:absolute;inset:-6px -4px}           /* 命中区撑到 44 */
.lg .track{position:absolute;inset:0;border-radius:999px;box-shadow:inset 0 0 0 1px rgba(20,20,30,.075);
  background:linear-gradient(90deg,var(--g-vivid) 0px,var(--g-vivid) calc(var(--gp) - 15px),
    var(--g-soft) calc(var(--gp) - 3px),var(--gray) calc(var(--gp) + 9px),var(--gray) 100%)}
.lg .lens{position:absolute;left:0;top:0;z-index:1;width:var(--thw);height:var(--thh);border-radius:999px;
  background:rgba(var(--knob),var(--a));
  -webkit-backdrop-filter:blur(var(--b)) saturate(calc(1 + .55 * var(--sh))) brightness(calc(1 + .04 * var(--sh)));
  backdrop-filter:blur(var(--b)) saturate(calc(1 + .55 * var(--sh))) brightness(calc(1 + .04 * var(--sh)));
  box-shadow:0 calc(1px + 11px * var(--sh)) calc(3px + 26px * var(--sh)) rgba(20,20,26,calc(.09 + .17 * var(--sh))),
    inset 0 0 0 1px rgba(0,0,0,calc(.075 - .055 * var(--sh)))}
.lg .lens::before{content:'';position:absolute;inset:0;border-radius:inherit;opacity:var(--sh);
  background:linear-gradient(180deg,rgba(255,255,255,.80) 0%,rgba(255,255,255,.16) 26%,
    rgba(255,255,255,0) 52%,rgba(255,255,255,.10) 82%,rgba(255,255,255,.42) 100%)}
.lg .lens::after{content:'';position:absolute;inset:0;border-radius:inherit;opacity:var(--sh);
  box-shadow:inset 0 0 0 1.5px rgba(255,255,255,.78),inset 0 0 0 2.5px rgba(150,170,200,.16),
    inset 0 0 calc(7px + 13px * var(--sh)) rgba(255,255,255,.40)}
.lg:disabled{cursor:default;opacity:.42}
.lg:focus-visible{outline:2px solid var(--ac);outline-offset:3px}
@media (prefers-color-scheme:dark){ html:not([data-theme="light"]) .lg{--gray:rgba(255,255,255,.16);--g-soft:rgba(255,255,255,.55);--knob:28,28,31} }
html[data-theme="dark"] .lg{--gray:rgba(255,255,255,.16);--g-soft:rgba(255,255,255,.55);--knob:28,28,31}
@media (prefers-reduced-transparency:reduce){ .lg .lens{-webkit-backdrop-filter:none;backdrop-filter:none} }
@media (prefers-contrast:more){ .lg .track{box-shadow:inset 0 0 0 1px rgba(20,20,30,.4)} }
.fade{animation:fi var(--t-l) var(--e-out) both}
@keyframes fi{from{opacity:0;transform:translateY(9px)}to{opacity:1;transform:none}}
/* ── 无障碍：三个彼此独立的信号，分别处理 ──
   减少动效不等于没有反馈，而是换成不引发前庭反应的等价物：
   位移/弹簧/视差换成短促的透明度交叉淡入，去掉回弹，保留有助于理解的
   颜色与透明度变化。 */
@media (prefers-reduced-motion:reduce){
  .tile,.fade{animation:none}
  .art,.btn,.seg button,.chips button,nav.pills button,.pills.mini button,.icb{transition:opacity var(--t-s) linear,background var(--t-s) linear}
  .art:active,.btn:active,.icb:active{transform:none;opacity:.62}
  .art:hover{transform:none}
  .tick span{transition:opacity var(--t-s) linear;transform:none}
  #dock{transition:opacity var(--t-s) linear}
  #dock:not(.up){opacity:0}
  #push{transition:opacity var(--t-s) linear}
  .spin{animation-duration:1.6s}
  .dot.live,.shimmer,.flow.run .link2 i{animation:none}
}
/* 半透明会影响可读性时，把材质做实：提高底色不透明度，去掉模糊 */
@media (prefers-reduced-transparency:reduce){
  header,#dock{backdrop-filter:none!important;-webkit-backdrop-filter:none!important;
    background:var(--sf)!important}
  header{border-bottom:1px solid var(--line)}
  header::after{display:none}
  .badge{backdrop-filter:none;-webkit-backdrop-filter:none}
}
/* 高对比：接近实色的底 + 明确的描边 */
@media (prefers-contrast:more){
  :root{--line:rgba(0,0,0,.32);--line2:rgba(0,0,0,.5);--t2:rgba(28,28,30,.9);--t3:rgba(28,28,30,.7);
    --sel:rgba(17,18,20,.24)}
  .card{border:1px solid var(--line)}
  .seg button.on,nav.pills button.on,.pills.mini button.on{outline:1.5px solid var(--t1);outline-offset:-1.5px}
  header,#dock,#toast{background:var(--sf)!important;backdrop-filter:none!important}
}
</style>
</head>
<body>
<header>
  <div class="wrap bar">
    <button id="back" class="icb" aria-label="返回"><svg width="10" height="16" viewBox="0 0 11 18" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9.5 1.5 2 9l7.5 7.5"/></svg></button>
    <button class="brand" id="home" aria-label="Cuven 索引库">
      <span class="mark">C</span>
      <span class="bname">Cuven<sup>ᴿ</sup> <em>索引库</em></span>
    </button>
    <span class="sp"></span>
    <nav class="pills" id="nav" aria-label="主导航">
      <span class="hl" aria-hidden="true"></span>
      <button data-v="lib"><span class="ic" aria-hidden="true"><svg width="20" height="20" viewBox="0 0 20 20" fill="currentColor"><rect x="1.5" y="1.5" width="7.6" height="10.4" rx="2.1"/><rect x="10.9" y="1.5" width="7.6" height="10.4" rx="2.1"/><rect x="1.5" y="13.6" width="17" height="4.9" rx="2.1" opacity=".42"/></svg></span><span class="lbl">片库</span></button>
      <button data-v="dl"><span class="ic" aria-hidden="true"><svg width="20" height="20" viewBox="0 0 20 20" fill="currentColor"><path d="M4.2 1.6h11.6a2.2 2.2 0 0 1 2.2 2.2v12.4a2.2 2.2 0 0 1-2.2 2.2H4.2A2.2 2.2 0 0 1 2 16.2V3.8a2.2 2.2 0 0 1 2.2-2.2Zm1.6 4.3a.9.9 0 0 0 0 1.8h8.4a.9.9 0 0 0 0-1.8Zm0 3.6a.9.9 0 0 0 0 1.8h8.4a.9.9 0 0 0 0-1.8Zm0 3.6a.9.9 0 0 0 0 1.8h5.2a.9.9 0 0 0 0-1.8Z" fill-rule="evenodd"/></svg></span><span class="lbl">片单</span><i id="ncart"></i></button>
      <button data-v="idx"><span class="ic" aria-hidden="true"><svg width="20" height="20" viewBox="0 0 20 20" fill="currentColor"><path d="M4 1.8h12A2.2 2.2 0 0 1 18.2 4v3.1A2.2 2.2 0 0 1 16 9.3H4A2.2 2.2 0 0 1 1.8 7.1V4A2.2 2.2 0 0 1 4 1.8Zm0 8.9h12a2.2 2.2 0 0 1 2.2 2.2V16a2.2 2.2 0 0 1-2.2 2.2H4A2.2 2.2 0 0 1 1.8 16v-3.1A2.2 2.2 0 0 1 4 10.7Zm1.5-5.2a1 1 0 1 0 0 .01Zm0 8.9a1 1 0 1 0 0 .01Z" fill-rule="evenodd"/></svg></span><span class="lbl">系统</span></button>
    </nav>
    <span class="sp"></span>
    <div class="tools">
      <div class="pills mini" id="srcNav" role="group" aria-label="内容源">
        <button data-s="movie">电影</button><button data-s="tv">剧集</button>
      </div>
      <div class="field">
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9"><circle cx="7" cy="7" r="4.6"/><path d="M10.6 10.6 14 14" stroke-linecap="round"/></svg>
        <input id="q" placeholder="搜索" autocomplete="off" autocapitalize="off" enterkeyhint="search">
        <button id="clr" aria-label="清空">✕</button>
      </div>
      <button class="icb" id="theme" aria-label="切换主题" title="切换外观"></button>
    </div>
  </div>
</header>
<div id="stack"><main id="out" class="wrap"></main></div>
<div id="scrim"></div>
<div id="push"><div id="pushIn"></div></div>
<div id="edge"></div>
<div id="dock"><div class="dbar">
  <span class="dn"><b id="dnum">0</b> 部已选<small id="dsub"></small></span>
  <button class="btn sm" id="dclr">清空</button>
  <button class="btn sm" id="dopen">查看</button>
  <button class="btn on" id="dgo">下载</button>
</div></div>
<div id="toast" role="status" aria-live="polite"></div>
<!-- ══════════════════════════════════════════════════════════════════
     本地 CPU 管线 —— 独立线程
     打包（CRC32 + zip 组装）、base64 解码、大列表筛选都在这里跑。
     主线程只负责画界面，所以下载一百多部片的时候滚动依然是满帧的。
     用 type="text/plain" 装源码，避免第二次转义。
     ══════════════════════════════════════════════════════════════ -->
<script id="wsrc" type="text/plain">
var T = (function(){
  var t = new Uint32Array(256), c, n, k;
  for (n = 0; n < 256; n++){
    c = n;
    for (k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(u8){
  var c = 0xFFFFFFFF, i;
  for (i = 0; i < u8.length; i++) c = (c >>> 8) ^ T[(c ^ u8[i]) & 255];
  return (c ^ 0xFFFFFFFF) >>> 0;
}
var ENC = new TextEncoder();
function w2(a, o, v){ a[o] = v & 255; a[o+1] = (v >>> 8) & 255; }
function w4(a, o, v){ a[o] = v & 255; a[o+1] = (v >>> 8) & 255; a[o+2] = (v >>> 16) & 255; a[o+3] = (v >>> 24) & 255; }

/* ZIP —— STORE。种子和文本都不值得再压一遍，省下的 CPU 留给界面。
   0x0800 标志位声明文件名是 UTF-8，中文片名在 Finder / 资源管理器里才不乱码。 */
function zip(files){
  var i, n = files.length, names = [], total = 0, cd = 0;
  for (i = 0; i < n; i++){
    names.push(ENC.encode(files[i].name));
    total += 30 + names[i].length + files[i].data.length;
    cd += 46 + names[i].length;
  }
  var out = new Uint8Array(total + cd + 22), p = 0, offs = [], crcs = [];
  var d = new Date(), dt = ((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)) >>> 0;
  var dd = (((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) >>> 0;
  for (i = 0; i < n; i++){
    var f = files[i], nm = names[i];
    var crc = f.crc != null ? f.crc : crc32(f.data);
    crcs.push(crc); offs.push(p);
    w4(out, p, 0x04034b50); w2(out, p+4, 20); w2(out, p+6, 0x0800); w2(out, p+8, 0);
    w2(out, p+10, dt); w2(out, p+12, dd);
    w4(out, p+14, crc); w4(out, p+18, f.data.length); w4(out, p+22, f.data.length);
    w2(out, p+26, nm.length); w2(out, p+28, 0);
    out.set(nm, p+30); p += 30 + nm.length;
    out.set(f.data, p); p += f.data.length;
  }
  var cdStart = p;
  for (i = 0; i < n; i++){
    var f2 = files[i], nm2 = names[i];
    w4(out, p, 0x02014b50); w2(out, p+4, 20); w2(out, p+6, 20); w2(out, p+8, 0x0800);
    w2(out, p+10, 0); w2(out, p+12, dt); w2(out, p+14, dd);
    w4(out, p+16, crcs[i]); w4(out, p+20, f2.data.length); w4(out, p+24, f2.data.length);
    w2(out, p+28, nm2.length); w2(out, p+30, 0); w2(out, p+32, 0);
    /* 外部属性：以「/」结尾的是目录条目，标上 MS-DOS 目录位（0x10），解压工具一律建成文件夹 */
    w2(out, p+34, 0); w2(out, p+36, 0); w4(out, p+38, /\/$/.test(f2.name) ? 0x10 : 0); w4(out, p+42, offs[i]);
    out.set(nm2, p+46); p += 46 + nm2.length;
  }
  w4(out, p, 0x06054b50); w2(out, p+4, 0); w2(out, p+6, 0);
  w2(out, p+8, n); w2(out, p+10, n);
  w4(out, p+12, p - cdStart); w4(out, p+16, cdStart); w2(out, p+20, 0);
  return out;
}

var B64 = (function(){
  var s = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var m = new Uint8Array(256), i;
  for (i = 0; i < 64; i++) m[s.charCodeAt(i)] = i;
  return m;
})();
function unb64(str){
  var len = str.length, pad = 0;
  while (len > 0 && str.charCodeAt(len-1) === 61){ len--; pad++; }
  var n = (len * 3) >> 2, out = new Uint8Array(n), o = 0, i = 0, a, b, c, dd2;
  for (; i + 3 < len; i += 4){
    a = B64[str.charCodeAt(i)]; b = B64[str.charCodeAt(i+1)];
    c = B64[str.charCodeAt(i+2)]; dd2 = B64[str.charCodeAt(i+3)];
    out[o++] = (a << 2) | (b >> 4);
    out[o++] = ((b & 15) << 4) | (c >> 2);
    out[o++] = ((c & 3) << 6) | dd2;
  }
  if (i < len){
    a = B64[str.charCodeAt(i)]; b = B64[str.charCodeAt(i+1)];
    out[o++] = (a << 2) | (b >> 4);
    if (i + 2 < len){ c = B64[str.charCodeAt(i+2)]; out[o++] = ((b & 15) << 4) | (c >> 2); }
  }
  return out.subarray(0, o);
}

/* 大列表本地筛选：影片一多，主线程做这个就会掉帧 */
function sift(items, f){
  var out = [], i, m;
  for (i = 0; i < items.length; i++){
    m = items[i];
    if (f.dr === 'dv' && m.hb !== 7) continue;
    if (f.dr === 'hdr' && (m.hb || 0) < 3) continue;
    if (f.dr === 'sdr' && (m.hb || 0) >= 3) continue;
    if (f.qual === 'uhd' && (m.rb || 0) < 5) continue;
    if (f.qual === 'hd' && !(m.rb && m.rb <= 4)) continue;
    if (f.own === 'hide' && m.own) continue;
    if (f.own === 'only' && !m.own) continue;
    out.push(m);
  }
  return out;
}

onmessage = function(ev){
  var d = ev.data, id = d.id, r, tr = [];
  try {
    if (d.op === 'zip'){
      r = zip(d.files);
      tr.push(r.buffer);
      postMessage({ id: id, ok: 1, buf: r.buffer, size: r.length }, tr);
      return;
    }
    if (d.op === 'unb64'){
      var arr = d.list.map(function(s){ return unb64(s); });
      var bufs = arr.map(function(u){ return u.buffer; });
      postMessage({ id: id, ok: 1, list: arr }, bufs);
      return;
    }
    if (d.op === 'crc'){
      var cs = new Uint32Array(d.segs.length);
      for (var i = 0; i < d.segs.length; i++)
        cs[i] = crc32(new Uint8Array(d.buf, d.segs[i][0], d.segs[i][1]));
      postMessage({ id: id, ok: 1, crcs: cs, buf: d.buf }, [cs.buffer, d.buf]);
      return;
    }
    if (d.op === 'sift'){
      postMessage({ id: id, ok: 1, items: sift(d.items, d.f) });
      return;
    }
    postMessage({ id: id, ok: 0, err: 'unknown op' });
  } catch (e){
    postMessage({ id: id, ok: 0, err: String(e && e.message || e) });
  }
};
</script>
<script>
var GATE = new URLSearchParams(location.search).get('gate') || '';
var out = document.getElementById('out'),
    qEl = document.getElementById('q'),
    clrEl = document.getElementById('clr'),
    backEl = document.getElementById('back'),
    navEl = document.getElementById('nav'),
    hdr = document.querySelector('header'),
    dock = document.getElementById('dock');

var PREF = (function(){ try { return JSON.parse(localStorage.getItem('cvr') || '{}'); } catch(e){ return {}; } })();
function savePref(){
  try { localStorage.setItem('cvr', JSON.stringify({
    sort:S.sort, min:S.min, year:S.year, own:S.own, dr:S.dr, qual:S.qual,
    theme:S.theme, src:S.src })); } catch(e){}
}
/* ══════════════════════════════════════════════════════════════════
   两个源
   ──────────────────────────────────────────────────────────────────
   电影和剧集是两套互不相干的索引：各自的年份、片单、片库比对结果。
   前端这边只做一件事 —— 每个请求都带上 src，然后在切换的时候把所有
   本地缓存清干净。年份表按源分开，因为剧集版块只有 2020 往后。
   ══════════════════════════════════════════════════════════════════ */
var SRCS = {
  movie: { id:'movie', name:'电影', head:'电影库', unit:'部',
           lede:'点海报加入片单，点片名看片源',
           years:[2026,2025,2024,2023,2022,2021,2020,2019,2018,2017,2016,2015,2014,2013,2012,2011,2010] },
  tv:    { id:'tv', name:'剧集', head:'剧集库', unit:'部',
           lede:'点海报加入片单，点片名按季看片源',
           years:[2026,2025,2024,2023,2022,2021,2020] }
};
var SRC0 = SRCS[PREF.src] ? PREF.src : 'movie';
var S = {
  src: SRC0,
  view:'lib', q:'', year:PREF.year||'', genre:'',
  min: PREF.min == null ? 6 : PREF.min,
  sort: PREF.sort || 'new', own: PREF.own || 'hide',
  dr: PREF.dr || '', qual: PREF.qual || '',
  theme: PREF.theme || 'auto',
  lib:null, hidden:0, counts:{}, indexed:0, building:false,
  page:1, pages:1, items:[], busy:false, scroll:0,
  movie:null, st:null, libst:null, logch:'pipe', logs:null,
  under:'lib', fopen:false, hdKey:null, libStamp:0, mvStamp:0
};

/* ══════════════════════════════════════════════════════════════════
   PERF —— 统一状态与性能调度
   ──────────────────────────────────────────────────────────────────
   一个地方回答三个问题：这台设备有多少力气、现在掉帧了没有、这件活该
   交给谁做。三档（high / balanced / low）同时决定两件事：
     · 动效尺度 --silk —— 掉帧就整体收紧，省下的帧还给滚动；
     · 重活的去处 —— GPU（WebGPU 并行算 CRC32）/ 独立线程（打包、
       解码、大列表筛选）/ 主线程（量小的时候，省掉一次线程往返）。
   GPU 路径上线前先跑一次自检：拿一段随机数据在 GPU 和 CPU 各算一遍，
   不完全相等就永久禁用 —— 宁可慢一点，也不能给出一个坏掉的压缩包。
   ══════════════════════════════════════════════════════════════════ */
var PERF = {
  tier:'high', fps:60, cores:4, mem:4, gpu:null, gpuOK:false, worker:null,
  jobs:{}, seq:0, lowSince:0, silk:1,

  init:function(){
    this.cores = navigator.hardwareConcurrency || 4;
    this.mem = navigator.deviceMemory || 4;
    var c = navigator.connection || {};
    this.save = !!c.saveData;
    this.reduce = !!(window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches);
    this.tier = (this.cores >= 8 && this.mem >= 6) ? 'high'
              : (this.cores >= 4 && this.mem >= 3) ? 'balanced' : 'low';
    if (this.save) this.tier = 'low';
    this.apply();
    this.watch();
    if (navigator.gpu) this.bootGPU();
  },
  apply:function(){
    var s = this.reduce ? 0.001 : (this.tier === 'high' ? 1 : this.tier === 'balanced' ? 0.78 : 0.5);
    if (Math.abs(s - this.silk) > 0.01){
      this.silk = s;
      document.documentElement.style.setProperty('--silk', String(s));
    }
    document.documentElement.classList.toggle('lite', this.tier === 'low');
  },
  /* 帧率监控：连续两秒低于 46 帧就降一档，稳定回到 56 帧以上再升回来。
     用滑动平均，避免一次滚动抖动就把整站的动效改掉。
     只在有事发生时看：交互后 2.5 秒的窗口、以及弹簧还在动的时候。
     页面静着的时候不常驻 rAF —— 常驻一条 60Hz 的空循环在手机上就是烧电。 */
  watch:function(){
    var self = this, last = 0, acc = 0, n = 0, until = 0, running = false;
    function tick(t){
      if (!running) return;
      if (last){
        var dt = t - last;
        if (dt > 0 && dt < 400){ acc += 1000 / dt; n++; }
      }
      last = t;
      if (n >= 30){
        self.fps = self.fps * 0.5 + (acc / n) * 0.5;
        acc = 0; n = 0;
        if (self.fps < 46){
          if (!self.lowSince) self.lowSince = t;
          else if (t - self.lowSince > 1800 && self.tier !== 'low'){
            self.tier = self.tier === 'high' ? 'balanced' : 'low';
            self.lowSince = 0; self.apply();
          }
        } else {
          self.lowSince = 0;
          if (self.fps > 56 && self.tier === 'balanced' && self.cores >= 8){
            self.tier = 'high'; self.apply();
          }
        }
      }
      if (t < until || (typeof Silk !== 'undefined' && Silk.on)) requestAnimationFrame(tick);
      else { running = false; last = 0; acc = 0; n = 0; }
    }
    function poke(){
      until = performance.now() + 2500;
      if (!running && !document.hidden){ running = true; last = 0; requestAnimationFrame(tick); }
    }
    self.poke = poke;
    ['scroll','pointerdown','pointermove','wheel','keydown','touchmove'].forEach(function(ev){
      addEventListener(ev, poke, { passive:true });
    });
    document.addEventListener('visibilitychange', function(){ if (!document.hidden) poke(); });
    poke();
  },

  /* ── 独立线程 ── */
  wk:function(){
    if (this.worker) return this.worker;
    try {
      var src = document.getElementById('wsrc').textContent;
      var url = URL.createObjectURL(new Blob([src], { type:'text/javascript' }));
      var w = new Worker(url);
      var self = this;
      w.onmessage = function(ev){
        var j = self.jobs[ev.data.id];
        if (!j) return;
        delete self.jobs[ev.data.id];
        ev.data.ok ? j.res(ev.data) : j.rej(new Error(ev.data.err || '本地计算失败'));
      };
      /* 线程崩了：挂着的活全部报错（不是干等 120 秒超时），线程丢掉，
         下一次调用重建一条 */
      w.onerror = function(ev){
        var jobs = self.jobs; self.jobs = {};
        if (self.worker === w) self.worker = null;
        try { w.terminate(); } catch(e){}
        Object.keys(jobs).forEach(function(k){
          jobs[k].rej(new Error('后台线程出错' + (ev && ev.message ? '：' + ev.message : '')));
        });
      };
      this.worker = w;
    } catch(e){ this.worker = null; }
    return this.worker;
  },
  call:function(msg, transfer){
    var w = this.wk();
    if (!w) return Promise.reject(new Error('本机不支持后台线程'));
    var id = ++this.seq, self = this;
    msg.id = id;
    return new Promise(function(res, rej){
      /* 超时计时器用完即清，别让每次调用都留一个 120 秒的定时器在那儿 */
      var tm = setTimeout(function(){
        if (self.jobs[id]){ delete self.jobs[id]; rej(new Error('本地计算超时')); }
      }, 120000);
      self.jobs[id] = { res:function(v){ clearTimeout(tm); res(v); },
                        rej:function(e){ clearTimeout(tm); rej(e); } };
      try { w.postMessage(msg, transfer || []); }
      catch(e){ clearTimeout(tm); delete self.jobs[id]; rej(e); }
    });
  },

  /* ── WebGPU：一个线程算一部片的 CRC32 ──
     zip 每个条目都要一份 CRC。条目之间彼此独立，正好一片一线程；
     二百部片就是二百条并行，GPU 上一次派发的事，CPU 要串着算二百遍。 */
  bootGPU:async function(){
    try {
      var ad = await navigator.gpu.requestAdapter();
      if (!ad) return;
      var dev = await ad.requestDevice();
      dev.lost.then(function(){ PERF.gpu = null; PERF.gpuOK = false; });
      var mod = dev.createShaderModule({ code: [
        'struct N { c: u32, p1: u32, p2: u32, p3: u32 };',
        '@group(0) @binding(0) var<storage, read> data: array<u32>;',
        '@group(0) @binding(1) var<storage, read> seg: array<u32>;',
        '@group(0) @binding(2) var<storage, read_write> res: array<u32>;',
        '@group(0) @binding(3) var<uniform> n: N;',
        '@compute @workgroup_size(64)',
        'fn main(@builtin(global_invocation_id) g: vec3<u32>) {',
        '  let i = g.x;',
        '  if (i >= n.c) { return; }',
        '  let off = seg[i * 2u];',
        '  let len = seg[i * 2u + 1u];',
        '  var c: u32 = 0xFFFFFFFFu;',
        '  var k: u32 = 0u;',
        '  loop {',
        '    if (k >= len) { break; }',
        '    let p = off + k;',
        '    let w = data[p >> 2u];',
        '    let b = (w >> ((p & 3u) * 8u)) & 0xFFu;',
        '    var x = (c ^ b) & 0xFFu;',
        '    var j: u32 = 0u;',
        '    loop {',
        '      if (j >= 8u) { break; }',
        '      if ((x & 1u) != 0u) { x = (x >> 1u) ^ 0xEDB88320u; } else { x = x >> 1u; }',
        '      j = j + 1u;',
        '    }',
        '    c = x ^ (c >> 8u);',
        '    k = k + 1u;',
        '  }',
        '  res[i] = c ^ 0xFFFFFFFFu;',
        '}'
      ].join('\n') });
      this.pipe = dev.createComputePipeline({ layout:'auto', compute:{ module:mod, entryPoint:'main' } });
      this.gpu = dev;
      this.gpuOK = await this.verify();
      if (!this.gpuOK) this.gpu = null;
    } catch(e){ this.gpu = null; this.gpuOK = false; }
  },
  /* 自检：随机数据 + 长短不一的分段，GPU 与 CPU 必须逐位相同 */
  verify:async function(){
    try {
      var n = 40000, buf = new Uint8Array(n), i;
      for (i = 0; i < n; i++) buf[i] = (i * 131 + (i >> 3) * 17 + 7) & 255;
      var segs = [[0, 9999], [9999, 1], [10000, 20003], [30003, n - 30003]];
      var g = await this.crcGPU(buf, segs);
      var cpu = await this.call({ op:'crc', buf: buf.buffer.slice(0), segs: segs });
      var c2 = new Uint32Array(cpu.crcs);
      for (i = 0; i < segs.length; i++) if (g[i] !== c2[i]) return false;
      return true;
    } catch(e){ return false; }
  },
  crcGPU:async function(u8, segs){
    var dev = this.gpu, i;
    /* writeBuffer 的长度必须是 4 的倍数，尾部不齐就补一段零 */
    var pad = (u8.length + 3) & ~3;
    var src = u8;
    if (pad !== u8.length || u8.byteOffset % 4){ src = new Uint8Array(pad); src.set(u8); }
    var db = dev.createBuffer({ size: Math.max(4, pad), usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    dev.queue.writeBuffer(db, 0, src.buffer, src.byteOffset, pad);
    var sa = new Uint32Array(segs.length * 2);
    for (i = 0; i < segs.length; i++){ sa[i*2] = segs[i][0]; sa[i*2+1] = segs[i][1]; }
    var sb = dev.createBuffer({ size: Math.max(4, sa.byteLength), usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    dev.queue.writeBuffer(sb, 0, sa);
    var rb = dev.createBuffer({ size: Math.max(4, segs.length * 4),
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC });
    var ub = dev.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    dev.queue.writeBuffer(ub, 0, new Uint32Array([segs.length, 0, 0, 0]));
    var bg = dev.createBindGroup({ layout: this.pipe.getBindGroupLayout(0), entries:[
      { binding:0, resource:{ buffer:db } }, { binding:1, resource:{ buffer:sb } },
      { binding:2, resource:{ buffer:rb } }, { binding:3, resource:{ buffer:ub } } ] });
    var out2 = dev.createBuffer({ size: Math.max(4, segs.length * 4),
      usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
    var enc = dev.createCommandEncoder();
    var pass = enc.beginComputePass();
    pass.setPipeline(this.pipe); pass.setBindGroup(0, bg);
    pass.dispatchWorkgroups(Math.ceil(segs.length / 64));
    pass.end();
    enc.copyBufferToBuffer(rb, 0, out2, 0, Math.max(4, segs.length * 4));
    dev.queue.submit([enc.finish()]);
    await out2.mapAsync(GPUMapMode.READ);
    var res = new Uint32Array(out2.getMappedRange().slice(0, segs.length * 4));
    out2.unmap();
    db.destroy(); sb.destroy(); rb.destroy(); ub.destroy(); out2.destroy();
    return res;
  },

  /* 调度决策：量小就别过线程，量大就上 GPU */
  /* 组装始终在独立线程（要出一段可转移的内存）；这里只决定 CRC 走不走 GPU。
     条目少或数据小的时候派发一次 GPU 的开销比省下的还多，就别折腾。 */
  route:function(bytes, n){
    return (this.gpuOK && n >= 20 && bytes >= (1 << 21)) ? 'gpu' : 'worker';
  },
  label:function(){
    return (this.tier === 'high' ? '高性能' : this.tier === 'balanced' ? '均衡' : '节能')
      + ' · ' + this.cores + ' 核' + (this.gpuOK ? ' · GPU 就绪' : '')
      + ' · ' + Math.round(this.fps) + ' fps';
  }
};

/* ══════════════════════════════════════════════════════════════════
   IndexedDB —— 下载的落脚点
   取回来的种子先写这里，再谈压包。于是刷新、断网、误关标签页都不丢，
   回来只补缺的那几部。
   ══════════════════════════════════════════════════════════════════ */
var DBP = null;
/* 打开失败不能把失败钉死：以前 DBP 一旦拒绝就永远拒绝，下载直到刷新都不能用。
   现在失败就把 DBP 清掉，下一次调用重新打开；被别的标签页升级顶掉也一样。 */
function db(){
  if (DBP) return DBP;
  DBP = new Promise(function(res, rej){
    var r;
    try { r = indexedDB.open('cuven-r', 1); }
    catch(e){ rej(e); return; }
    r.onupgradeneeded = function(){
      var d = r.result;
      if (!d.objectStoreNames.contains('parts')) d.createObjectStore('parts');
      if (!d.objectStoreNames.contains('job')) d.createObjectStore('job');
    };
    r.onsuccess = function(){
      var d = r.result;
      d.onversionchange = function(){ try { d.close(); } catch(e){} DBP = null; };
      d.onclose = function(){ DBP = null; };
      res(d);
    };
    r.onerror = function(){ rej(r.error || new Error('本机数据库打不开')); };
    r.onblocked = function(){ rej(new Error('本机数据库被别的标签页占用，关掉它再试')); };
  });
  DBP.catch(function(){ DBP = null; });
  return DBP;
}
function tx(store, mode, fn){
  return db().then(function(d){
    return new Promise(function(res, rej){
      var t = d.transaction(store, mode), s = t.objectStore(store), rq = fn(s);
      t.oncomplete = function(){ res(rq ? rq.result : null); };
      t.onerror = function(){ rej(t.error); };
    });
  });
}
var kPut = function(st,k,v){ return tx(st,'readwrite',function(s){ return s.put(v,k); }); };
var kGet = function(st,k){ return tx(st,'readonly',function(s){ return s.get(k); }); };
var kDel = function(st,k){ return tx(st,'readwrite',function(s){ return s.delete(k); }); };
var kKeys = function(st){ return tx(st,'readonly',function(s){ return s.getAllKeys(); }); };
var kAll = function(st){ return tx(st,'readonly',function(s){ return s.getAll(); }); };

/* ══════════════════════════════════════════════════════════════════
   下载管理器
   ──────────────────────────────────────────────────────────────────
   v4 是「前端切 25 部一批 → 服务端拼 zip → 浏览器存盘」，于是 99 部片
   会掉下来四个压缩包，中途断了还得从头再来。
   v5 只做两件事：
     ① 分片取：每次向服务端要 8 部的种子字节，落进 IndexedDB；
        服务端说预算到了（503 budget）就歇一下再要，不算失败。
     ② 全部齐了，本地压成「一个」包 —— CRC 与组装交给 GPU / 独立线程。
   任务按片单指纹认领：同一份片单回来还是同一个任务，接着取缺的那几部。
   ══════════════════════════════════════════════════════════════════ */
/*<pack>*/
/* [v6.8] 压缩包的目录：
     Cuven索引库-日期/            ← 根文件夹：不管用什么工具、解压到哪儿，先得到的都是这一个文件夹
       _清单.txt                  ← 每一部在哪个子文件夹（失败的也列出来）
       001-020/                   ← 每 20 部一个子文件夹，按片单顺序
         xxx.torrent …
         _磁力链接.txt             ← 这一段里只有磁力的几部（没有就不放）
       021-040/ …
   「部」只算取到了的（种子或磁力）；失败的不占位置，所以每个子文件夹都是满的 20 部，只有最后一个可能不满。 */
var PACK_PER = 20;
function packLayout(items, byTid, fail, root, per, now){
  per = per > 0 ? per : PACK_PER;
  var E = new TextEncoder(), files = [], used = {}, where = {}, mags = {}, order = [], last = '';
  var got = items.filter(function(it){ var p = byTid[it.tid]; return p && ((p.kind === 'torrent' && p.data) || p.magnet); });
  var w = Math.max(3, String(got.length).length);
  var pad = function(n){ n = String(n); while (n.length < w) n = '0' + n; return n; };
  var dirOf = function(i){ var a = Math.floor(i / per) * per + 1; return pad(a) + '-' + pad(Math.min(got.length, a + per - 1)); };
  files.push({ name: root + '/', data: new Uint8Array(0), crc: 0 });
  got.forEach(function(it, i){
    var p = byTid[it.tid], sub = dirOf(i), d = root + '/' + sub + '/';
    if (sub !== last){ last = sub; order.push(d); files.push({ name: d, data: new Uint8Array(0), crc: 0 }); }
    where[it.tid] = sub;
    if (p.kind === 'torrent' && p.data){
      var nm = d + p.name + '.torrent', c = 2;
      while (used[nm]) nm = d + p.name + ' (' + (c++) + ').torrent';
      used[nm] = 1;
      files.push({ name: nm, data: new Uint8Array(p.data) });
    } else (mags[d] = mags[d] || []).push('# ' + p.name + '\n' + p.magnet);
    /* 这个子文件夹的最后一部：把它的磁力清单也放进去 */
    if ((i + 1) % per === 0 || i === got.length - 1)
      if (mags[d]) files.push({ name: d + '_磁力链接.txt', data: E.encode(mags[d].join('\n\n') + '\n') });
  });
  var fails = items.filter(function(it){ return !where[it.tid]; });
  var head = 'Cuven ᴿ 索引库 · 打包清单\n生成时间 ' + (now || new Date()).toLocaleString('zh-CN') +
    '\n共 ' + items.length + ' 项，成功 ' + got.length + '，失败 ' + fails.length +
    '\n每 ' + per + ' 部一个子文件夹（共 ' + order.length + ' 个），按片单顺序\n\n';
  var body = items.map(function(it){
    var f = where[it.tid];
    return it.name + '  ·  #' + it.tid + '  ·  ' + (f ? f + '/' : '失败：' + ((fail && fail[it.tid]) || '没取到'));
  }).join('\n');
  files.splice(1, 0, { name: root + '/_清单.txt', data: E.encode(head + body + '\n') });
  return { files: files, ok: got.length, dirs: order.length };
}
/*</pack>*/
var DL = {
  job:null, run:false, stop:false, phase:'', got:0, bytes:0, t0:0, err:'', tick:null,

  sig:function(items){
    var s = items.map(function(x){ return x.tid; }).sort().join(',') + '|' + items.length;
    var h = 5381, i;
    for (i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
    return 'j' + h.toString(36) + items.length.toString(36);
  },
  load:function(){
    var self = this;
    return kGet('job','cur').then(function(j){
      if (!j) return null;
      self.job = j;
      return tx('parts','readonly',function(s){ return s.count(self.range()); }).then(function(n){
        self.got = n || 0;
        return j;
      });
    }).catch(function(){ return null; });
  },
  begin:function(items){
    var self = this, id = this.sig(items);
    if (this.job && this.job.id === id) return this.resume();
    this.stop = false;
    var job = { id:id, at:Date.now(), items:items, fail:{}, total:items.length };
    return kGet('job','cur').then(function(old){
      if (old && old.id !== id) return self.purge(old.id);
    }).then(function(){
      self.job = job; self.got = 0; self.bytes = 0; self.doneSet = {}; self.err = '';
      return kPut('job','cur',job);
    }).then(function(){ return self.resume(); });
  },
  purge:function(id){
    var r = this.range(id);
    return tx('parts','readwrite',function(s){ return s.delete(r); }).catch(function(){});
  },
  clear:function(){
    var self = this, id = this.job && this.job.id;
    this.job = null; this.got = 0; this.run = false; this.phase = ''; this.doneSet = {}; this.err = '';
    return Promise.all([ kDel('job','cur'), id ? this.purge(id) : null ]);
  },
  range:function(id){ var p = (id || this.job.id) + ':'; return IDBKeyRange.bound(p, p + '\uffff'); },
  pending:function(){
    var self = this;
    return tx('parts','readonly',function(s){ return s.getAllKeys(self.range()); }).then(function(ks){
      var have = {}, cut = self.job.id.length + 1;
      ks.forEach(function(k){ have[String(k).slice(cut)] = 1; });
      self.got = ks.length;
      return self.job.items.filter(function(it){ return !have[String(it.tid)]; });
    });
  },
  resume:async function(){
    if (this.run) return;
    this.run = true; this.stop = false; this.err = ''; this.t0 = Date.now();
    this.phase = 'fetch';
    var soft = 0;
    try {
      for (;;){
        if (this.stop){ this.phase = 'paused'; break; }
        var left = await this.pending();
        if (!left.length) break;
        var take = left.filter(function(x){ return !DL.job.fail[x.tid]; }).slice(0, GRAB);
        if (!take.length) break;                                  // 剩下的都是硬失败
        this.paint();
        var r;
        try { r = await api('/api/fetch', { method:'POST', body: JSON.stringify({ items: take }) }); }
        catch (e){
          var dt = e.data || {};
          if (dt.budget || e.status === 503 || e.status === 429){
            soft++; this.phase = 'wait'; this.paint();
            await sleep(Math.min(6000, 900 * soft));
            this.phase = 'fetch'; continue;
          }
          if (e.status === 409){ await sleep(2500); continue; }
          if (++soft > 6){ this.err = e.message; break; }
          await sleep(1200 * soft); continue;
        }
        soft = 0;
        var wr = [], softN = 0;
        if (!this.job.tries) this.job.tries = {};
        for (var i = 0; i < r.items.length; i++){
          var it = r.items[i];
          if (it.retry){
            /* 服务端预算到了（不算次数），或者论坛这会儿不通（算次数：连着 4 次才记为失败） */
            if (it.soft){
              softN++;
              var tn = (this.job.tries[it.tid] || 0) + 1;
              this.job.tries[it.tid] = tn;
              if (tn >= 4) this.job.fail[it.tid] = it.err || '多次重试仍取不到';
            }
            continue;
          }
          if (!it.ok){ this.job.fail[it.tid] = it.err || '取不到'; continue; }
          wr.push(it);
        }
        /* 这一批一部都没取到、全是「这会儿不通」：退避一下再要，别对着论坛连珠炮 */
        if (!wr.length && softN){ this.phase = 'wait'; this.paint(); await sleep(Math.min(15000, 2000 * softN)); this.phase = 'fetch'; }
        if (wr.length){
          var dec = await PERF.call({ op:'unb64', list: wr.map(function(x){ return x.kind === 'torrent' ? x.b64 : ''; }) })
            .catch(function(){ return null; });
          for (var j = 0; j < wr.length; j++){
            var w = wr[j];
            var bytes = (dec && w.kind === 'torrent') ? dec.list[j] : null;
            if (w.kind === 'torrent' && !bytes) bytes = b64main(w.b64);
            await kPut('parts', this.job.id + ':' + w.tid,
              { tid:w.tid, name:w.name, kind:w.kind, data:bytes || null, magnet:w.magnet || '' });
            if (!this.doneSet) this.doneSet = {};
            this.doneSet[w.tid] = 1;
            if (bytes) this.bytes += bytes.length;
          }
        }
        await kPut('job','cur',this.job);
        this.paint();
      }
      if (!this.stop && !this.err) await this.pack();
    } catch (e){ this.err = e.message || String(e); }
    this.run = false;
    if (!this.err && this.phase !== 'paused' && this.phase !== 'done') this.phase = 'idle';
    this.paint();
  },
  /* 全部到齐 → 压成一个包。CRC 与组装按设备能力分派。 */
  pack:async function(){
    this.phase = 'pack'; this.paint();
    var r0 = this.range();
    var mine = await tx('parts','readonly',function(s){ return s.getAll(r0); });
    /* 按片单原顺序出包：用户看到的顺序和压缩包里的顺序是一致的 */
    var byTid = {};
    mine.forEach(function(p){ if (p) byTid[p.tid] = p; });
    mine = this.job.items.map(function(it){ return byTid[it.tid]; }).filter(Boolean);

    /* [v6.8] 解压出来是一个根文件夹，里面每 20 部一个子文件夹（见 packLayout） */
    var stamp = new Date().toISOString().slice(0,10).replace(/-/g,'');
    var root = 'Cuven索引库-' + stamp;
    var L = packLayout(this.job.items, byTid, this.job.fail, root, PACK_PER);
    var files = L.files, ok = L.ok;

    var total = files.reduce(function(a, f){ return a + f.data.length; }, 0);
    var how = PERF.route(total, files.length);
    /* GPU 路径：所有条目拼成一段连续内存，一片一线程并行算 CRC（目录条目是空的，CRC 本来就是 0，不送进去） */
    if (how === 'gpu'){
      try {
        var cat = new Uint8Array(total), segs = [], idx = [], o = 0;
        for (var z = 0; z < files.length; z++){
          if (!files[z].data.length) continue;
          cat.set(files[z].data, o); segs.push([o, files[z].data.length]); idx.push(z); o += files[z].data.length;
        }
        var crcs = await PERF.crcGPU(cat, segs);
        for (var y = 0; y < idx.length; y++) files[idx[y]].crc = crcs[y];
      } catch(e){ how = 'worker'; for (var q2 = 0; q2 < files.length; q2++) if (files[q2].data.length) delete files[q2].crc; }
    }
    this.how = how;
    var zbuf;
    try {
      var res = await PERF.call({ op:'zip', files: files },
        files.map(function(f){ return f.data.buffer; }));
      zbuf = res.buf;
    } catch(e){ this.err = '本地打包失败：' + (e.message || e); this.paint(); return; }

    var blob = new Blob([zbuf], { type:'application/zip' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = root + '.zip';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function(){ URL.revokeObjectURL(a.href); }, 90000);
    this.phase = 'done'; this.okCount = ok; this.zipSize = blob.size;
    this.paint();
    haptic('done');
    toast('已打包 ' + ok + ' 部（' + L.dirs + ' 个文件夹，每个 ' + PACK_PER + ' 部）· ' + fmtSize(blob.size));
  },
  /* 进行中每一批都会来一次：阶段没变就只打补丁（数字 / 进度 / 行状态），
     阶段变了（取件 → 打包 → 完成）按钮组要换，才整页重画 */
  paint:function(){
    if (S.view === 'dl' && !(this._pp === this.phase && patchDL())) renderDL();
    paintDock();
  }
};

function b64main(s){
  var bin = atob(s), n = bin.length, u = new Uint8Array(n), i;
  for (i = 0; i < n; i++) u[i] = bin.charCodeAt(i);
  return u;
}
var GRAB = 8;
function sleep(ms){ return new Promise(function(r){ setTimeout(r, ms); }); }
</script>
<script>
/* ══════════════════════════════════════════════════════════════════
   Silk · 弹簧
   ──────────────────────────────────────────────────────────────────
   缓动曲线有个绕不过去的毛病：它的时长是写死的，中途来了新输入就没法
   接。手势驱动的东西必须能在任意一帧被抓住、被反向，所以这里改用弹簧 ——
   它天然从"当前值"起算，也天然带着速度。
   参数用 Apple 那两个：
     damping  阻尼比。1.0 = 临界阻尼，不过冲；<1 会回弹，越小越弹。
     response 响应时间（秒）。不是"时长" —— 弹簧没有固定时长，
              停下来的时刻是从参数里长出来的。
   默认一律 damping 1.0。只有当这一下动作本身带着动量（甩、抛、拖完松手）
   才给回弹 —— 一个只是淡入的菜单要是也过冲，就很怪。
   所有弹簧共用一条 rAF，帧预算才好控制。
   ══════════════════════════════════════════════════════════════════ */
var Silk = {
  live: [], on: false, last: -1,

  /* Apple 出厂值：移动/复位 1.0/0.4，旋转 0.8/0.4，抽屉 0.8/0.3 */
  MOVE:  { damping:1.0, response:0.40 },
  SHEET: { damping:0.8, response:0.30 },
  SNAP:  { damping:1.0, response:0.28 },

  spring: function(o){
    var s = {
      x: o.from || 0, v: o.velocity || 0, to: o.to || 0,
      damping: o.damping == null ? 1 : o.damping,
      response: o.response || 0.4,
      onFrame: o.onFrame, onRest: o.onRest, eps: o.eps || 0.4,
      dead: false,
      /* 重新指定目标时不清零速度 —— 反向的那一下如果把速度砍掉，
         手感上就是一堵墙。带着速度过去，才是连续的。 */
      retarget: function(to, opt){
        this.to = to;
        if (opt && opt.damping != null) this.damping = opt.damping;
        if (opt && opt.response) this.response = opt.response;
        if (opt && opt.velocity != null) this.v = opt.velocity;
        Silk.wake(this);
        return this;
      },
      stop: function(){ this.dead = true; return this; },
    };
    /* 减少动效：直接落到终点，但保留"到位"回调，交互逻辑不受影响 */
    if (PERF.reduce){
      s.x = s.to; if (s.onFrame) s.onFrame(s.x, 0); if (s.onRest) s.onRest();
      s.dead = true; return s;
    }
    this.wake(s);
    return s;
  },
  wake: function(s){
    if (this.live.indexOf(s) < 0) this.live.push(s);
    if (this.on) return;
    this.on = true;
    /* 起始时刻交给第一帧的时间戳去定，不在这里采样 performance.now()：
       rAF 回调拿到的是"这一帧开始"的时间，它可能早于你刚刚采到的
       performance.now()。差出来的负 dt 会让积分倒着跑 —— 弹簧不是慢下来，
       是直接发散，一帧就飞到几万像素外。 */
    this.last = -1;
    requestAnimationFrame(this.tick);
  },
  tick: function(t){
    var dt = (t - Silk.last) / 1000;
    /* 首帧、时钟倒挂：按一帧算。切后台回来、掉帧：封顶，
       否则一次就要积分掉好几百毫秒，同样会跳。 */
    if (!(dt > 0)) dt = 1 / 60;
    else if (dt > 0.064) dt = 0.064;
    Silk.last = t;
    for (var i = Silk.live.length - 1; i >= 0; i--){
      var s = Silk.live[i];
      if (s.dead){ Silk.live.splice(i, 1); continue; }
      /* 半隐式欧拉 + 定步长子步：dt 再大也不会发散 */
      var w = 6.283185307179586 / s.response, z = s.damping;
      var n = Math.max(1, Math.ceil(dt / 0.004)), h = dt / n, k;
      for (k = 0; k < n; k++){
        var a = -w * w * (s.x - s.to) - 2 * z * w * s.v;
        s.v += a * h;
        s.x += s.v * h;
      }
      if (Math.abs(s.x - s.to) < s.eps && Math.abs(s.v) < s.eps * 6){
        s.x = s.to; s.v = 0; s.dead = true;
        if (s.onFrame) s.onFrame(s.x, 0);
        Silk.live.splice(i, 1);
        if (s.onRest) s.onRest();
        continue;
      }
      if (s.onFrame) s.onFrame(s.x, s.v);
    }
    if (Silk.live.length) requestAnimationFrame(Silk.tick);
    else { Silk.on = false; Silk.last = -1; }
  },

  /* 动量投射：不是从松手那一点找最近的落点，而是先算"这一甩会飘到哪"，
     再拿那个落点去选目标。小输入换大输出，甩出去才像真的被抛出去了。
     用的是 Apple 示例代码里的指数衰减式，不是课本上的 v²/2a。 */
  project: function(v, rate){
    rate = rate == null ? 0.998 : rate;
    return (v / 1000) * rate / (1 - rate);
  },
  /* 橡皮筋：越过边界之后越拖越跟不动。硬停是"卡住了"，
     渐进阻力才是"还在响应，只是没有更多了"。 */
  rubber: function(over, dim, c){
    c = c || 0.55;
    return (over * dim * c) / (dim + c * Math.abs(over));
  },
};

/* ── 触感：只在"确实发生了一件事"的时刻给，且和视觉同帧 ──
   到处都震，人就会学会忽略所有震动。 */
function haptic(kind){
  if (!navigator.vibrate || PERF.reduce) return;
  try { navigator.vibrate({ tap:8, commit:[0,10], done:[0,14,60,22], warn:[0,26] }[kind] || 8); } catch(e){}
}

/* ══════════════════════════════════════════════════════════════════
   推入层 —— 详情页可以被拖回去
   ──────────────────────────────────────────────────────────────────
   之前详情是"把目录整段换掉"，返回要重新渲染一遍，滚动位置只能靠猜；
   进和出也不同路。现在详情盖在目录上面，进出走同一条路径，底下那一层
   原样活着。左边缘往右拖就能 1:1 把它推回去，松手按速度决定是回去还是
   弹回来 —— 中途随时能反向，因为驱动它的是弹簧不是 transition。
   ══════════════════════════════════════════════════════════════════ */
var PUSH = {
  el:null, inner:null, scrim:null, stack:null, edge:null,
  open:false, x:100, sp:null, drag:null, onClose:null,

  init:function(){
    this.el = document.getElementById('push');
    this.inner = document.getElementById('pushIn');
    this.scrim = document.getElementById('scrim');
    this.stack = document.getElementById('stack');
    this.edge = document.getElementById('edge');
    this.paint(100);
    this.bind();
    /* 顶栏在手机上会换行，高度不是常数 —— 量出来给推入层和边缘条用 */
    var hd = document.querySelector('header');
    var sync = function(){
      document.documentElement.style.setProperty('--hh', (hd.offsetHeight || 56) + 'px');
    };
    sync();
    addEventListener('resize', sync);
    addEventListener('orientationchange', function(){ setTimeout(sync, 260); });
    /* 返回键出现 / 消失、字体换好之后顶栏高度也会变：直接盯着顶栏本身，不只等 resize */
    if (typeof ResizeObserver !== 'undefined') new ResizeObserver(sync).observe(hd);
  },
  /* x = 0 完全推入，100 完全退出。所有位置变化都只经过这里，
     于是"当前呈现值"永远是可信的 —— 中断时从它起算就不会跳。 */
  paint:function(x){
    this.x = x;
    var p = 1 - x / 100;
    this.el.style.transform = 'translate3d(' + x + '%,0,0)';
    /* 底下那层往左让 22%，并压暗一点：上面还压着一层，这件事要看得见 */
    this.stack.style.transform = 'translate3d(' + (-22 * p) + '%,0,0)';
    this.scrim.style.opacity = String(0.18 * p);
    var on = x < 99.9;
    this.el.classList.toggle('on', on);
    this.scrim.classList.toggle('on', on);
  },
  show:function(html, onClose){
    this.onClose = onClose || null;
    this.inner.innerHTML = html;
    this.el.scrollTop = 0;
    this.open = true;
    this.el.classList.add('on'); this.scrim.classList.add('on');
    document.body.style.overflow = 'hidden';
    this.el.style.willChange = 'transform';
    this.stack.style.willChange = 'transform';
    this.to(0);
  },
  hide:function(vel){
    if (!this.open) return;
    this.open = false;
    this.to(100, vel, function(){
      PUSH.inner.innerHTML = '';
      PUSH.el.classList.remove('on'); PUSH.scrim.classList.remove('on');
      document.body.style.overflow = '';
      PUSH.el.style.willChange = ''; PUSH.stack.style.willChange = '';
      if (PUSH.onClose){ var f = PUSH.onClose; PUSH.onClose = null; f(); }
    });
  },
  /* 弹到目标。已经在动就直接改目标、速度接着用，不重开一条动画。 */
  to:function(target, vel, done){
    var self = this;
    var o = { damping:1.0, response: target === 0 ? 0.42 : 0.34 };
    if (this.sp && !this.sp.dead){
      this.sp.onRest = done || null;
      this.sp.retarget(target, { velocity: vel == null ? this.sp.v : vel,
                                 damping:o.damping, response:o.response });
      return;
    }
    this.sp = Silk.spring({
      from:this.x, to:target, velocity: vel || 0,
      damping:o.damping, response:o.response, eps:0.12,
      onFrame:function(x){ self.paint(x); },
      onRest: done || null,
    });
  },

  bind:function(){
    var self = this;
    var start = null;
    var W = function(){ return Math.max(1, innerWidth); };

    function down(e){
      if (!self.open || e.button > 0) return;
      /* 只认从左边缘起手的这一下。中途随时可以抓住正在动的层， */
      /* 所以这里不管弹簧在不在跑，直接接管。 */
      var t = e.currentTarget;
      /* 指针捕获让手指移出元素边界之后仍然跟得住。个别浏览器/指针类型会抛，
         抛了也不该把整个手势废掉 —— 退化成普通事件照样能用。 */
      try { t.setPointerCapture(e.pointerId); } catch (err){}
      if (self.sp) self.sp.stop();
      start = { id:e.pointerId, x0:e.clientX, y0:e.clientY,
                base:self.x, moved:false, hist:[{ x:e.clientX, t:performance.now() }] };
      self.el.style.willChange = 'transform';
    }
    function move(e){
      if (!start || e.pointerId !== start.id) return;
      var dx = e.clientX - start.x0, dy = e.clientY - start.y0;
      if (!start.moved){
        /* 先看意图：横向明显压过纵向才认成"推回去"，否则让给滚动 */
        if (Math.abs(dx) < 10 && Math.abs(dy) < 10) return;
        if (Math.abs(dy) > Math.abs(dx)){ start = null; return; }
        start.moved = true;
      }
      start.hist.push({ x:e.clientX, t:performance.now() });
      if (start.hist.length > 8) start.hist.shift();
      var pct = start.base + dx / W() * 100;
      /* 往回推过头了就上橡皮筋，而不是硬顶在 0 */
      if (pct < 0) pct = -Silk.rubber(-pct, 100, 0.55);
      if (pct > 100) pct = 100;
      self.paint(pct);
      e.preventDefault();
    }
    function up(e){
      if (!start || e.pointerId !== start.id) return;
      var moved = start.moved, hist = start.hist;
      start = null;
      if (!moved) return;
      /* 速度取最近一小段的平均，不是只看最后两个点 —— 单帧噪声会把它带飞。
         几个 pointermove 被合并在同一帧时，时间跨度可能是 0：这种情况下
         算不出可信的速度，就当它是静止的，别凭空造一个几千 px/s 出来。 */
      var b = hist[hist.length - 1], vpx = 0, i;
      for (i = hist.length - 2; i >= 0; i--){
        var span = b.t - hist[i].t;
        if (span >= 30){ vpx = (b.x - hist[i].x) / span * 1000; break; }
      }
      if (i < 0){
        var d0 = b.t - hist[0].t;
        vpx = d0 >= 12 ? (b.x - hist[0].x) / d0 * 1000 : 0;
      }
      var vpct = vpx / W() * 100;                      // %/s
      /* 先把这一甩会飘到哪算出来，再拿落点去选目标 —— 而不是从松手点找最近的 */
      var land = self.x + Silk.project(vpct, 0.995);
      var close = land > 50;
      /* 速度足够明确时，方向说了算，不看位置 */
      if (vpct > 45) close = true;
      else if (vpct < -45) close = false;
      if (close){ haptic('tap'); self.hide(vpct); }
      else self.to(0, vpct);
    }

    [this.edge, this.el].forEach(function(t, i){
      /* 边缘条随时可拖；层本身只在指针落在最左 26px 时才接管，
         其余区域留给正常的滚动和点击 */
      t.addEventListener('pointerdown', function(e){
        if (i === 1 && e.clientX > 26) return;
        down.call(this, e);
      });
      t.addEventListener('pointermove', move);
      t.addEventListener('pointerup', up);
      t.addEventListener('pointercancel', up);
    });
  },
};
</script>
<script>
/* ══════════════════════════════════════════════════════════════════
   基础件
   ══════════════════════════════════════════════════════════════════ */
/* ── api：带超时、可中止 ──
   没有超时的 fetch 一旦挂起，S.busy 就永远是真，无限滚动跟着死掉。
   目录 / 详情这类轻接口 40s；建索引 / 取件 / 认定这类重活服务端自己按
   预算收工，通常 15s 内回来，给 110s 是留给网关。 */
var API_T = { light:40000, heavy:110000 };
var HEAVY_API = /^\/api\/(build|incremental|fetch|repair|diagnose|unlock|migrate|optimize|split|reset)(\?|$)|^\/api\/lib\?(scan|resolve|refresh)/;
function api(u, opt){
  opt = opt || {};
  var h = { 'x-gate': GATE };
  if (opt.body) h['content-type'] = 'application/json';
  var url = u + (u.indexOf('?') < 0 ? '?' : '&') + 'gate=' + encodeURIComponent(GATE)
          + '&src=' + encodeURIComponent(opt.src || S.src);
  var ac = (typeof AbortController !== 'undefined') ? new AbortController() : null;
  var ms = opt.timeout || (HEAVY_API.test(u) ? API_T.heavy : API_T.light);
  var timer = ac ? setTimeout(function(){ ac.abort(); }, ms) : null;
  if (ac && opt.signal){
    if (opt.signal.aborted) ac.abort();
    else opt.signal.addEventListener('abort', function(){ ac.abort(); }, { once:true });
  }
  return fetch(url, { method: opt.method || 'GET', headers: h, body: opt.body || null,
                      signal: ac ? ac.signal : undefined })
    .then(function(r){
      /* 网关超时会回 HTML，直接 r.json() 在 Safari 上只会得到一句
         "The string did not match the expected pattern" —— 先读文本再解析，
         报错里带上状态码和响应开头，出事时至少知道是哪一层。 */
      return r.text().then(function(t){
        var j = null;
        try { j = JSON.parse(t); } catch(e){}
        if (!r.ok){
          var e2 = new Error((j && j.error) ||
            ('HTTP ' + r.status + (t ? '：' + t.slice(0, 110) : '（响应为空，可能网关超时）')));
          e2.status = r.status; e2.data = j || {};
          throw e2;
        }
        if (!j) throw new Error('响应不是 JSON（HTTP ' + r.status + '）');
        return j;
      });
    }, function(e){
      /* 主动取消与超时分开报：取消的调用方自己知道，不该当成错误画到页面上 */
      var e3;
      if (e && e.name === 'AbortError'){
        var canceled = !!(opt.signal && opt.signal.aborted);
        e3 = new Error(canceled ? '已取消' : '请求超时（' + Math.round(ms / 1000) + 's 没有响应）');
        e3.aborted = canceled; e3.timeout = !canceled;
      } else e3 = new Error('网络不可用：' + (e && e.message || e));
      e3.status = 0; e3.data = {};
      throw e3;
    })
    .finally(function(){ if (timer) clearTimeout(timer); });
}
function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, function(c){
  return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]; }); }
function img(p, s){ return p ? '/img?p=' + encodeURIComponent(p) + '&s=' + (s || 's') : ''; }
function toast(m){
  var t = document.getElementById('toast');
  t.textContent = m; t.classList.add('on');
  clearTimeout(t._t); t._t = setTimeout(function(){ t.classList.remove('on'); }, 2200);
}
function copy(x){
  var d = function(){ toast('已复制磁力链接'); };
  if (navigator.clipboard) navigator.clipboard.writeText(x).then(d, fb); else fb();
  function fb(){ var a = document.createElement('textarea'); a.value = x;
    a.style.position = 'fixed'; a.style.opacity = 0; document.body.appendChild(a);
    a.select(); document.execCommand('copy'); a.remove(); d(); }
}
function since(ts){
  if (!ts) return '—';
  var s = Math.max(0, (Date.now() - ts) / 1000);
  if (s < 60) return '刚刚';
  if (s < 3600) return Math.floor(s/60) + ' 分钟前';
  if (s < 86400) return Math.floor(s/3600) + ' 小时前';
  if (s < 2592000) return Math.floor(s/86400) + ' 天前';
  return new Date(ts).toLocaleDateString('zh-CN');
}
function fmtSize(b){
  if (!b) return '0 B';
  if (b < 1024) return b + ' B';
  if (b < 1048576) return (b/1024).toFixed(0) + ' KB';
  if (b < 1073741824) return (b/1048576).toFixed(1) + ' MB';
  return (b/1073741824).toFixed(2) + ' GB';
}
/* 只淡入换掉的那一块，不动壳子（片库页的标题和筛选台是常驻的） */
function paint(el){ el = el || out; el.classList.remove('fade'); void el.offsetWidth; el.classList.add('fade'); }
function lazyImgs(root){
  [].forEach.call((root || out).querySelectorAll('.art img:not(.in):not(.err)'), function(m){
    if (m.complete && m.naturalWidth) m.classList.add('in');
    else {
      m.onload = function(){ m.classList.add('in'); };
      /* 取不到的海报别留一个破图标：藏掉，底下的灰底就是占位 */
      m.onerror = function(){ m.classList.add('err'); };
    }
  });
}
var io = null, pre = {}, pageCache = {};
/* 预取失败不能把结果钉死在缓存里，否则这部片直到刷新都点不开 */
function detailOf(id){
  if (pre[id]) return pre[id];
  var p = api('/api/detail?id=' + id);
  p.catch(function(){ if (pre[id] === p) delete pre[id]; });
  return (pre[id] = p);
}
function prefetch(id){ if (id && !pre[id]) detailOf(id).catch(function(){}); }
function watchTail(fn){
  if (io){ io.disconnect(); io = null; }
  var s = document.getElementById('sent');
  if (!s || typeof IntersectionObserver === 'undefined') return;
  io = new IntersectionObserver(function(e){ if (e[0].isIntersecting && !S.busy) fn(); }, { rootMargin:'800px 0px' });
  io.observe(s);
}
/* 尾巴：转圈 + 一个只在失败时露面的重试。失败之后哨兵还停在视口里，
   IntersectionObserver 不会再触发 —— 没有这个按钮，无限滚动就此死掉。 */
function tailHTML(more){
  return '<div class="tail' + (more ? '' : ' hide') + '" id="tail"><div class="spin"></div>'
    + '<button class="link" id="tailrt" hidden>加载失败 · 重试</button></div><div id="sent"></div>';
}
function tailShow(on){ var t = document.getElementById('tail'); if (t) t.classList.toggle('hide', !on); }
function tailErr(on, msg){
  var t = document.getElementById('tail'); if (!t) return;
  t.classList.toggle('err', !!on);
  var b = t.querySelector('#tailrt');
  if (b){ b.hidden = !on; if (on){ b.title = msg || ''; } }
}

/* ── 外观 ── */
var THEMES = ['auto','light','dark'];
/* 图标由 CSS 按 data-theme 出，脚本只管改属性 —— 于是首帧就是对的，
   不存在"先画一个默认图标、脚本跑完再换掉"的那一下跳变。 */
function applyTheme(){
  document.documentElement.setAttribute('data-theme', S.theme);
}
document.getElementById('theme').onclick = function(){
  S.theme = THEMES[(THEMES.indexOf(S.theme) + 1) % 3];
  applyTheme(); savePref();
  toast('外观：' + ({ auto:'跟随系统', light:'浅色', dark:'深色' })[S.theme]);
};

/* ══════════════════════════════════════════════════════════════════
   片单（购物车）
   ══════════════════════════════════════════════════════════════════ */
var MAX = 200;
/* 片单按源分开：两个源的 id 是两套编号，混在一个片单里取不出片源。
   电影沿用旧键，升级上来原来的片单还在。 */
function cartKey(){ return S.src === 'movie' ? 'cvcart' : 'cvcart:' + S.src; }
function loadCart(){
  try { var c = JSON.parse(localStorage.getItem(cartKey()) || 'null'); return (c && c.ord) ? c : { ord:[], o:{} }; }
  catch(e){ return { ord:[], o:{} }; }
}
var CART = loadCart();
function cartSave(){ try { localStorage.setItem(cartKey(), JSON.stringify(CART)); } catch(e){} }
function inCart(id){ return !!CART.o[id]; }
function cartCount(){ return CART.ord.length; }
function cartAdd(m){
  if (CART.o[m.id]) return false;
  if (CART.ord.length >= MAX){ toast('片单最多 ' + MAX + ' 部'); return false; }
  CART.ord.push(m.id);
  CART.o[m.id] = { id:m.id, title:m.title, year:m.year, poster:m.poster, res:m.res,
                   size:m.size, sid:m.sid, own:m.own, hb:m.hb, rb:m.rb };
  if (m.ext) CART.o[m.id].ext = 1;          // [v6.7] 论坛搜索搜来的：索引里没有这部，没有详情页可换版本
  cartSave(); paintDock(); markTile(m.id, true); return true;
}
function cartDel(id){
  if (!CART.o[id]) return;
  delete CART.o[id];
  CART.ord = CART.ord.filter(function(x){ return x !== id; });
  cartSave(); paintDock(); markTile(id, false);
  if (S.view === 'dl') renderDL();
}
function cartToggle(m){ if (inCart(m.id)){ cartDel(m.id); return false; } return cartAdd(m); }
function cartSetRel(id, sid, label){
  var m = CART.o[id]; if (!m) return;
  m.sid = sid; m.pickLabel = label; cartSave();
  if (S.view === 'dl') renderDL();
}
function clearCart(){
  if (!cartCount()) return;
  CART = { ord:[], o:{} }; cartSave(); paintDock(); markTiles();
  if (S.view === 'dl') renderDL();
  toast('片单已清空');
}
function relName(m){
  var bits = [m.title]; if (m.year) bits.push('(' + m.year + ')');
  if (m.res) bits.push(m.res);
  if (m.hb === 7) bits.push('DV'); else if (m.hb >= 3) bits.push('HDR');
  return bits.join(' ');
}
function markTiles(){
  [].forEach.call(out.querySelectorAll('.tile'), function(t){
    t.classList.toggle('in', inCart(+t.dataset.id));
  });
  document.getElementById('ncart').textContent = cartCount() || '';
}
/* 只改动到的那一张：加一部片不必扫整片网格 */
function markTile(id, on){
  var t = out.querySelector('.tile[data-id="' + id + '"]');
  if (t) t.classList.toggle('in', !!on);
  document.getElementById('ncart').textContent = cartCount() || '';
}
function paintDock(){
  var n = cartCount();
  document.getElementById('dnum').textContent = n;
  document.getElementById('ncart').textContent = n || '';
  var sub = '';
  if (DL.job && DL.run) sub = dlPhase() + ' ' + DL.got + '/' + DL.job.total;
  else if (DL.job && DL.got < DL.job.total) sub = '有未完成的下载 · 已取 ' + DL.got + '/' + DL.job.total;
  document.getElementById('dsub').textContent = sub;
  dock.classList.toggle('up', n > 0 || !!(DL.job && DL.got < DL.job.total));
}
function dlPhase(){
  return { fetch:'取件中', wait:'等配额', pack:'打包中', done:'已完成', paused:'已暂停' }[DL.phase] || '';
}
document.getElementById('dclr').onclick = clearCart;
document.getElementById('dopen').onclick = function(){ view('dl'); };
document.getElementById('dgo').onclick = function(){ view('dl'); setTimeout(startDL, 120); };

/* ══════════════════════════════════════════════════════════════════
   片库
   ══════════════════════════════════════════════════════════════════ */
function yearList(){ return SRCS[S.src].years; }
var SORTS = [['new','最新'],['vote','评分'],['spec','规格'],['hot','热门']];
var MINS  = [[6,'6分+'],[7,'7分+'],[8,'8分+'],[0,'不限']];
var OWNS  = [['all','全部'],['hide','缺片'],['only','已有']];
/* 动态范围：把杜比视界与 HDR 从一锅片源里分出来 */
var DRS   = [['','全部'],['dv','杜比视界'],['hdr','HDR'],['sdr','SDR']];
/* 画质：1080p 及以下单列成「低质量」 */
var QUALS = [['','全部'],['uhd','4K 及以上'],['hd','1080p 低质量']];

function segHTML(list, cur, attr, counts){
  return '<div class="seg" data-seg="' + attr + '">' + list.map(function(x){
    var c = counts && counts[x[0]] != null ? '<em>' + counts[x[0]] + '</em>' : '<em></em>';
    return '<button data-' + attr + '="' + x[0] + '"' +
      (String(x[0]) === String(cur) ? ' class="on"' : '') + '>' + x[1] + c + '</button>';
  }).join('') + '</div>';
}
/* ── 筛选台分两层 ──
   排序和年份是天天用的，常驻；评分 / 动态范围 / 画质 / 已有 是偶尔调一次
   的，收进「筛选」。有非默认项时那个按钮亮起并计数 —— 收起来了也知道
   列表正被什么过滤着。 */
function advCount(){
  var n = 0;
  if (S.min !== 6) n++;
  if (S.dr) n++;
  if (S.qual) n++;
  if (S.lib && S.lib.on && S.own !== 'hide') n++;
  return n;
}
function yearChips(){
  return '<button data-y=""' + (S.year === '' ? ' class="on"' : '') + '>全部</button>'
    + yearList().map(function(y){ return '<button data-y="' + y + '"' +
        (String(S.year) === String(y) ? ' class="on"' : '') + '>' + y + '</button>'; }).join('');
}
function ctlHTML(){
  var cc = S.counts || {}, adv = advCount();
  return '<div class="filters" id="filters">'
    + '<div class="fgroup prime">' + segHTML(SORTS, S.sort, 's')
      + '<span class="grow"></span>'
      + '<button class="ftog' + (adv ? ' has' : '') + (S.fopen ? ' open' : '') + '" id="ftog"'
      + ' aria-expanded="' + (S.fopen ? 'true' : 'false') + '" aria-controls="fadv">筛选<i>' + (adv || '') + '</i></button></div>'
    + '<div class="fgroup"><div class="chips" id="years">' + yearChips() + '</div></div>'
    + '<div class="fadv" id="fadv"' + (S.fopen ? '' : ' hidden') + '>'
      + '<div class="fgroup"><span class="lb">评分</span>' + segHTML(MINS, S.min, 'm')
      + '<span class="lb auto" id="ownlb"' + ((S.lib && S.lib.on) ? '' : ' hidden') + '>已有</span>'
      + '<span id="ownseg"' + ((S.lib && S.lib.on) ? '' : ' hidden') + '>' + segHTML(OWNS, S.own, 'o') + '</span></div>'
      + '<div class="fgroup"><span class="lb">动态范围</span>' + segHTML(DRS, S.dr, 'r', { dv: cc.dv, hdr: cc.hdr })
      + '<span class="lb auto">画质</span>' + segHTML(QUALS, S.qual, 'u', { hd: cc.low })
      + '<span class="grow"></span><button class="link" id="freset"' + (adv ? '' : ' hidden') + '>恢复默认</button></div>'
    + '</div></div>';
}
function titleHTML(){
  var K = SRCS[S.src];
  var t = S.q ? '“' + esc(S.q) + '”'
        : (S.qual === 'hd' ? '低质量片单' : S.dr === 'dv' ? '杜比视界' : S.dr === 'hdr' ? 'HDR 片单' : K.head);
  var l = S.q ? '搜索结果 · ' + K.name : (S.qual === 'hd' ? '1080p 及以下，单独列出来方便挑要不要换 4K'
        : S.dr === 'dv' ? '带杜比视界的版本' : S.dr === 'hdr' ? 'HDR10 / HLG / HDR10+ 及杜比视界'
        : K.lede);
  return '<h1>' + t + '</h1><p class="lede">' + l + '</p>';
}
/* 壳子已经在了，只把选中态和计数改到位 —— 不重画，年份条就不会跳回开头 */
function syncCtl(){
  var hd = document.getElementById('libhd'); if (!hd) return;
  var tt = document.getElementById('libtitle'); if (tt) tt.innerHTML = titleHTML();
  var cur = { s:S.sort, m:S.min, o:S.own, r:S.dr, u:S.qual, y:S.year };
  [].forEach.call(hd.querySelectorAll('[data-s],[data-m],[data-o],[data-r],[data-u],[data-y]'), function(b){
    var k = ['s','m','o','r','u','y'].filter(function(a){ return b.dataset[a] != null; })[0];
    b.classList.toggle('on', String(b.dataset[k]) === String(cur[k]));
  });
  var cc = S.counts || {}, cnt = { r: { dv: cc.dv, hdr: cc.hdr }, u: { hd: cc.low } };
  ['r','u'].forEach(function(a){
    [].forEach.call(hd.querySelectorAll('[data-' + a + ']'), function(b){
      var em = b.querySelector('em'), v = cnt[a][b.dataset[a]];
      if (em) em.textContent = v != null ? v : '';
    });
  });
  var on = !!(S.lib && S.lib.on);
  var ol = document.getElementById('ownlb'), os = document.getElementById('ownseg');
  if (ol) ol.hidden = !on; if (os) os.hidden = !on;
  var adv = advCount(), ft = document.getElementById('ftog');
  if (ft){
    ft.classList.toggle('has', adv > 0); ft.classList.toggle('open', !!S.fopen);
    ft.setAttribute('aria-expanded', S.fopen ? 'true' : 'false');
    ft.querySelector('i').textContent = adv || '';
  }
  var fa = document.getElementById('fadv'); if (fa) fa.hidden = !S.fopen;
  var fr = document.getElementById('freset'); if (fr) fr.hidden = !adv;
}
function tileHTML(m, i){
  var dr = m.hb === 7 ? '<span class="badge b-dv">杜比视界</span>'
         : (m.hb >= 3 ? '<span class="badge b-hdr">HDR</span>' : '');
  var own = m.own === 2 ? '<span class="badge b-own">库中已有</span>'
          : (m.own === 1 ? '<span class="badge b-own weak">疑似已有</span>' : '');
  return '<div class="tile' + (inCart(m.id) ? ' in' : '') + (m.own ? ' own' : '') + '"'
    + ' data-i="' + i + '" data-id="' + m.id + '">'
    + '<button class="art" aria-label="' + (m.own ? '库中已有：' : '加入片单：') + esc(m.title) + '">'
    + (m.poster ? '<img loading="lazy" decoding="async" src="' + img(m.poster) + '" alt="">' : '')
    + (m.vote ? '<span class="badge b-vote">★ ' + m.vote + '</span>' : '')
    + (m.rels > 1 ? '<span class="badge b-n">' + m.rels + '</span>' : '')
    + dr + own
    + '<span class="tick"><span>✓</span></span></button>'
    + '<button class="tname"><b>' + esc(m.title) + '</b><em>'
    + esc([m.year, m.res].filter(Boolean).join(' · ')) + '</em></button></div>';
}
function tiles(items, off){
  /* 序号是全局的：卡片事件靠它回到 S.items 里取这张卡片对应的影片 */
  return '<div class="grid">' + items.map(function(m, i){ return tileHTML(m, (off||0) + i); }).join('') + '</div>';
}
/* 骨架屏必须和装好内容之后一模一样高：海报是 2:3，片名两行，副标题一行。
   少画一行，真数据回来的那一刻整片网格就会往下顿一下。 */
function skeleton(n){
  var h = '<div class="grid">';
  for (var i = 0; i < (n||12); i++)
    h += '<div class="tile"><div class="art shimmer"></div>'
       + '<div class="skn"><span class="shimmer"></span><span class="shimmer"></span></div></div>';
  return h + '</div>';
}
function qs(page){
  return '/api/catalog?page=' + page + '&sort=' + S.sort + '&min=' + S.min + '&own=' + S.own
    + '&dr=' + S.dr + '&qual=' + S.qual
    + '&year=' + encodeURIComponent(S.year) + '&q=' + encodeURIComponent(S.q);
}
/* ── 片库页的壳 ──
   标题、筛选台、网格容器、汇总行只搭一次。之后换筛选只换网格：筛选台原地
   改选中态，年份条的横向滚动位置、按钮的焦点都原样留着。
   壳上的点击全走一个委托监听 —— 按钮是重画的也不用重新绑。 */
function libShell(){
  var sh = document.getElementById('libshell');
  if (sh) return sh;
  out.innerHTML = '<div id="libshell"><div id="libhd"><div id="libtitle"></div></div>'
    + '<div id="libbody"></div><div id="libsum"></div></div>';
  sh = document.getElementById('libshell');
  sh.addEventListener('click', libClick);
  S.hdKey = null;
  return sh;
}
function hdKey(){ return S.src; }
function libHead(){
  var hd = document.getElementById('libhd');
  if (S.hdKey !== hdKey()){
    hd.innerHTML = '<div id="libtitle">' + titleHTML() + '</div>' + ctlHTML();
    S.hdKey = hdKey();
  } else syncCtl();
}
/* 换源 = 换一整套索引：本地缓存、片单、面板状态全部重来一遍。
   年份也要清 —— 剧集版块没有 2010，留着旧值会直接筛出个空页。 */
function setSrc(id, initial){
  if (!SRCS[id]) return;
  if (!initial && id === S.src) return;
  S.src = id; savePref();
  [].forEach.call(document.querySelectorAll('#srcNav button'), function(b){
    b.classList.toggle('on', b.dataset.s === id);
  });
  try { document.title = 'Cuven ᴿ ' + SRCS[id].head; } catch(e){}
  if (initial) return;
  if (LIBX){ LIBX.abort(); LIBX = null; }
  pageCache = {}; pre = {};
  CART = loadCart();
  S.items = []; S.page = 1; S.pages = 1; S.scroll = 0; S.hdKey = null;
  S.counts = {}; S.lib = null; S.hidden = 0;
  S.st = null; S.libst = null; S.logs = null;
  if (yearList().indexOf(+S.year) < 0) S.year = '';
  RUN.on = false; RUN.stop = true;
  paintDock(); markTiles();
  haptic('tap');
  if (S.view === 'idx') openIndex();
  else if (S.view === 'dl') renderDL();
  else { S.view = ''; view('lib', false); }
}
function sumHTML(j){
  var bits = [];
  if (j && j.total != null) bits.push('<span class="num">' + j.total + '</span> 部');
  if (j && j.at) bits.push('更新于 ' + since(j.at));
  if (j && j.building) bits.push('索引仍在扩充，已收录 ' + j.indexed);
  var h = '<div class="fsum">' + bits.join('<span class="sp">·</span>');
  if (S.hidden) h += '<span class="sp">·</span>已隐藏 ' + S.hidden +
    ' 部库中已有 <button class="link" id="sown">显示</button>';
  return h + '</div>';
}
var LIBX = null;   // 正在飞的目录请求：新的来了就把它掐掉，不白等也不乱序
function lib(reset){
  S.view = 'lib'; backEl.classList.remove('on'); setNav('lib');
  if (reset !== false){ S.page = 1; S.items = []; }
  libShell(); libHead();
  var body = document.getElementById('libbody'), sum = document.getElementById('libsum');
  var ck = qs(1), cached = pageCache[ck];
  /* [v6.5] 本页缓存三分钟就作废：片库那边刚进库的片，回到目录要能看到它从「缺片」里消失 */
  if (cached && Date.now() - (cached.t || 0) > 180000){ delete pageCache[ck]; cached = null; }
  var stamp = S.libStamp = (S.libStamp || 0) + 1;
  if (LIBX){ LIBX.abort(); LIBX = null; }
  if (cached){
    S.busy = false;
    S.items = cached.items; S.pages = cached.pages; S.page = cached.page;
    S.lib = cached.lib || S.lib; S.hidden = cached.hidden || 0; S.counts = cached.counts || {};
    body.innerHTML = tiles(S.items) + tailHTML(S.pages > 1);
    sum.innerHTML = sumHTML(cached);
    syncCtl(); lazyImgs(); markTiles();
    if (S.pages > 1) watchTail(moreLib);
    scrollTo({ top: S.q ? 0 : (S.scroll || 0) });
    return;
  }
  /* 已经加载过的那一批先本地筛一遍顶上去 —— 点筛选按钮的瞬间就有反馈，
     服务端的权威结果回来再替换。大列表交给独立线程筛，主线程不掉帧。 */
  var prev = S.items.slice();
  body.innerHTML = prev.length ? tiles(prev) : skeleton(12);
  sum.innerHTML = '';
  if (prev.length > 60){
    PERF.call({ op:'sift', items: prev, f:{ dr:S.dr, qual:S.qual, own:S.own } })
      .then(function(r){
        /* 只在权威结果还没回来时顶一下；晚到了就丢掉，别盖掉真结果 */
        if (S.libStamp !== stamp || !S.busy) return;
        var g = body.querySelector('.grid');
        /* 只是给个即时反馈，别让人点到还没对齐下标的卡片 */
        if (g && r.items.length){
          g.classList.add('preview');
          g.innerHTML = r.items.map(function(m,i){ return tileHTML(m,i); }).join('');
        }
      }).catch(function(){});
  }
  S.busy = true;
  var ac = (typeof AbortController !== 'undefined') ? new AbortController() : null;
  LIBX = ac;
  /* 两个参数的 then：渲染阶段自己抛的错不会掉进"网络失败"分支。 */
  api(ck, { signal: ac ? ac.signal : null }).then(function(j){
    if (S.libStamp !== stamp) return;
    if (LIBX === ac) LIBX = null;
    pageCache[ck] = { t: Date.now(), items:j.items, page:1, pages:j.pages, at:j.at, lib:j.lib,
                      hidden:j.hidden, counts:j.counts, total:j.total,
                      building:j.building, indexed:j.indexed };
    S.busy = false; S.items = j.items; S.pages = j.pages; S.page = 1;
    S.indexed = j.indexed; S.building = j.building;
    S.lib = j.lib || null; S.hidden = j.hidden || 0; S.counts = j.counts || {};
    if (!j.indexed && !S.q){ body.innerHTML = setupHTML(); sum.innerHTML = ''; syncCtl(); return; }
    body.innerHTML = j.items.length ? tiles(j.items) + tailHTML(j.pages > 1) : emptyHTML(j);
    sum.innerHTML = sumHTML(j);
    syncCtl(); lazyImgs(); markTiles(); paint(body);
    if (j.pages > 1) watchTail(moreLib);
    if (!S.q) scrollTo({ top: S.scroll || 0 });
  }, function(e){
    if (S.libStamp !== stamp || e.aborted) return;
    S.busy = false; if (LIBX === ac) LIBX = null;
    body.innerHTML = '<div class="err">' + esc(e.message) + '</div>'
      + '<div class="row" style="margin-top:14px"><button class="btn on" id="rt2">重试</button>'
      + '<button class="btn" id="mgr2">去系统页</button></div>';
    sum.innerHTML = '';
    syncCtl();
  });
}
/* 空列表要说清三件事：这里本来该有什么、为什么现在没有、按哪儿能让它有。
   高度按"装满时"预留，所以点完那个按钮，页面不会整个往下抖一次。 */
function emptyHTML(j){
  var head, body, act;
  if (S.own === 'hide' && j.hidden){
    head = '这一档全在库里了';
    body = '符合条件的 ' + j.hidden + ' 部影片都已经下载过，默认不再显示。';
    act  = '<button class="btn on" id="sown2">连已有的一起看</button>';
  } else if (S.dr || S.qual){
    head = '这一档还没有影片';
    body = '动态范围与画质是从片源规格里汇总出来的。v4 时期建的索引没有这两位，'
         + '要在「系统 → 维护 → 体检 → 重算汇总」里跑一次才会补齐。';
    act  = '<button class="btn on" id="clrf">清除动态范围与画质</button>'
         + '<button class="btn" id="toidx">去系统页</button>';
  } else if (S.q){
    head = '没有找到「' + esc(S.q) + '」';
    body = '搜索只查本地索引，认的是片名与原名。换个说法，或者清空搜索回片库看看。';
    act  = '<button class="btn on" id="clrq2">清空搜索</button>';
  } else {
    head = '没有匹配的影片';
    body = S.min > 0 ? '当前评分门槛是 ' + S.min + ' 分。把它调到「不限」通常就有了。'
                     : '换一个年份或者排序方式再看看。';
    act  = S.min > 0 ? '<button class="btn on" id="nomin">评分不限</button>' : '';
  }
  return '<div class="empty" style="--empty-h:360px"><h3>' + head + '</h3>'
    + '<p>' + body + '</p>' + (act ? '<div class="row">' + act + '</div>' : '') + '</div>';
}
function moreLib(){
  if (S.busy || S.page >= S.pages) return;
  S.busy = true; tailShow(true); tailErr(false);
  var stamp = S.libStamp;
  api(qs(S.page + 1)).then(function(j){
    S.busy = false;
    if (S.libStamp !== stamp) return;
    var off = S.items.length;
    S.items = S.items.concat(j.items); S.page = j.page; S.pages = j.pages;
    var g = out.querySelector('#libbody .grid');
    if (g) g.insertAdjacentHTML('beforeend', j.items.map(function(m,i){ return tileHTML(m, off+i); }).join(''));
    lazyImgs(); markTiles(); tailShow(S.page < S.pages);
    if (S.page >= S.pages && io) io.disconnect();
  }).catch(function(e){
    S.busy = false;
    if (S.libStamp !== stamp || e.aborted) return;
    tailShow(true); tailErr(true, e.message);
  });
}
/* 片库页上所有按钮的去处：一个监听管全部（壳子常驻，网格和空态随便换） */
function libClick(e){
  var t = e.target.closest ? e.target.closest('button') : null;
  if (!t) return;
  var d = t.dataset, go = function(fn){ fn(); S.scroll = 0; savePref(); lib(); };
  if (d.s != null){ go(function(){ S.sort = d.s; }); return; }
  if (d.m != null){ go(function(){ S.min = +d.m; }); return; }
  if (d.o != null){ go(function(){ S.own = d.o; }); return; }
  if (d.r != null){ go(function(){ S.dr = d.r; }); return; }
  if (d.u != null){ go(function(){ S.qual = d.u; }); return; }
  if (d.y != null){
    go(function(){ S.year = d.y; });
    t.scrollIntoView({ behavior: PERF.reduce ? 'auto' : 'smooth', block:'nearest', inline:'center' });
    return;
  }
  switch (t.id){
    case 'ftog': S.fopen = !S.fopen; syncCtl(); return;
    case 'freset': go(function(){ S.min = 6; S.dr = ''; S.qual = ''; S.own = 'hide'; }); return;
    case 'sown': case 'sown2': go(function(){ S.own = 'all'; }); return;
    case 'clrf': go(function(){ S.dr = ''; S.qual = ''; }); return;
    case 'nomin': go(function(){ S.min = 0; }); return;
    case 'clrq2': qEl.value = ''; S.q = ''; clrEl.classList.remove('on'); lib(); return;
    case 'toidx': case 'mgr2': view('idx'); return;
    case 'rt2': lib(); return;
    case 'tailrt': moreLib(); return;
    case 'go1': view('idx'); setTimeout(function(){ runBuild(null); }, 200); return;
    case 'go2': view('idx'); return;
  }
}
function setupHTML(){
  return '<div class="card"><h2 class="sec">索引还是空的</h2>'
    + '<p class="lede" style="margin:8px 0 14px">先把论坛片单抄一份到 R2，之后搜索和浏览都只读这份副本，'
    + '不会再打论坛。第一次大概要跑一阵，中途可以关掉页面，进度存在服务端。</p>'
    + '<div class="row"><button class="btn on" id="go1">开始建立索引</button>'
    + '<button class="btn" id="go2">先去系统页</button></div></div>';
}

/* ══════════════════════════════════════════════════════════════════
   影片详情
   ══════════════════════════════════════════════════════════════════ */
/* 详情盖在目录上面推进来，而不是把目录换掉：进出同一条路径，
   底下那层的滚动位置和已加载的分页原样留着，随时能被拖回来。 */
function openMovie(m, push){
  /* 记住底下是哪一页：片单里点开的，关掉要回片单，不是回片库 */
  if (S.view !== 'movie' && S.view) S.under = S.view;
  S.view = 'movie'; S.card = m;
  backEl.classList.add('on'); setNav('');
  if (push !== false) history.pushState({ v:'m', id:m.id, under:S.under }, '');
  /* 骨架屏同步写。交给 startViewTransition 去写会晚一帧 —— 预取命中时
     详情已经渲染完了，回调再把骨架屏盖回去，Chromium 上就永远停在转圈。 */
  PUSH.show(heroHTML(m, null) + '<div class="card"><div class="tail"><div class="spin"></div></div></div>',
    function(){ if (S.view === 'movie'){ S.view = S.under || 'lib'; backEl.classList.remove('on'); setNav(S.view); } });
  lazyImgs(PUSH.inner);
  /* 详情有自己的请求戳，和目录的分开：开详情不再作废正在加载的目录 */
  var stamp = S.mvStamp = (S.mvStamp || 0) + 1;
  detailOf(m.id).then(function(j){
    if (S.view !== 'movie' || S.mvStamp !== stamp) return;
    if (!j) throw new Error('拿不到详情');
    S.movie = j; renderMovie(j);
  }, function(e){
    if (S.view !== 'movie' || S.mvStamp !== stamp) return;
    PUSH.inner.innerHTML = heroHTML(m, null) + '<div class="err">' + esc(e.message) + '</div>'
      + '<div class="row" style="margin-top:12px"><button class="btn" id="mrt">重试</button></div>';
    var r = PUSH.inner.querySelector('#mrt');
    if (r) r.onclick = function(){ delete pre[m.id]; openMovie(m, false); };
  });
}
/* 关掉详情。手势关的时候历史也要跟着退一格，否则前进/后退就对不上了。 */
function closeDetail(vel){
  if (!PUSH.open) return;
  PUSH.skipPop = 1;
  PUSH.hide(vel);
  history.back();
}
function heroHTML(m, d){
  var mv = d ? d.movie : m;
  var line = [mv.year, mv.runtime ? mv.runtime + ' 分钟' : '',
    (mv.genres || []).slice(0,3).join(' / '),
    mv.vote ? '★ ' + mv.vote + (mv.votes ? '（' + mv.votes + '）' : '') : ''].filter(Boolean).join('  ·  ');
  var tags = '';
  if (mv.hb === 7) tags += '<span class="pill">杜比视界</span>';
  else if (mv.hb >= 3) tags += '<span class="pill">HDR</span>';
  if (mv.rb >= 5) tags += '<span class="pill">4K</span>';
  else if (mv.rb && mv.rb <= 4) tags += '<span class="pill">1080p 及以下</span>';
  if (mv.own === 2) tags += '<span class="pill ok">库中已有</span>';
  else if (mv.own === 1) tags += '<span class="pill warn">疑似已有</span>';
  /* [v6.5] 库里对上的是哪个文件、怎么对上的 —— 判错了一眼看得出是哪一步 */
  var L = mv.lib, libLine = '';
  if (L && L.own){
    var hw = { id: 'TMDB 编号相同', key: '文件名与论坛发布名是同一个片名', name: '按片名 + 年份认领', conflict: '片名年份全同（两边 TMDB 编号不同）' }[L.how] || '';
    libLine = '<p class="fine libwhy">片库里：' + (L.file ? esc(L.file) : '（没记下文件名）') + (hw ? ' · ' + hw : '') + '</p>';
  }
  return '<div class="hero"><div class="art">'
    + (mv.poster ? '<img src="' + img(mv.poster,'m') + '" alt="">' : '') + '</div>'
    + '<div style="flex:1;min-width:0"><h2>' + esc(mv.title) + '</h2>'
    + (mv.original && mv.original !== mv.title ? '<p class="lede" style="margin-top:3px">' + esc(mv.original) + '</p>' : '')
    + '<div class="fine">' + esc(line) + '</div>'
    + (tags ? '<div class="row" style="margin-bottom:10px">' + tags + '</div>' : '')
    + libLine
    + (d && d.movie.overview ? '<p>' + esc(d.movie.overview) + '</p>' : '')
    + '</div></div>';
}
function renderMovie(d){
  var mv = d.movie, items = d.items || [];
  var h = heroHTML(null, d);
  h += '<div class="row" style="margin:16px 0 4px">'
    + '<button class="btn' + (inCart(mv.id) ? '' : ' on') + '" id="addc">'
    + (inCart(mv.id) ? '已在片单中 · 移除' : '加入片单') + '</button>'
    + (mv.imdb ? '<a class="btn" target="_blank" rel="noopener noreferrer" href="https://www.imdb.com/title/' + mv.imdb + '/">IMDb</a>' : '')
    + (mv.sid ? '<a class="btn" target="_blank" rel="noopener noreferrer" href="/t/' + mv.sid
        + '?src=' + S.src + '">论坛原帖</a>' : '')
    + '</div>';
  if (d.value)
    h += '<div class="pick"><div class="k">性价比之选</div><h4>' + esc(d.value.title) + '</h4>'
      + '<div class="why">体积只有最佳片源的 ' + (100 - d.value.saved) + '%，规格几乎不差 · ' + esc(d.value.size || '') + '</div>'
      + '<div class="acts"><button data-sid="' + d.value.sid + '" class="usev">用这一版</button>'
      + '<button class="ghost" data-jump="' + d.value.tid + '">看附件</button></div></div>';
  h += '<div class="card"><div class="hd"><h2 class="sec">全部片源</h2><span class="sub">' + items.length + ' 条</span></div>'
    + (items.length ? items.map(relHTML).join('')
        : '<div class="empty" style="--empty-h:150px"><h3>还没有收录片源</h3>'
          + '<p>索引里有这部影片，但论坛上还没抓到对应的帖子。抓取新片之后会补上。</p></div>')
    + '</div>';
  var mv2 = PUSH.inner;
  mv2.innerHTML = h;
  lazyImgs(mv2);
  var ad = mv2.querySelector('#addc');
  if (ad) ad.onclick = function(){
    var mm = { id:mv.id, title:mv.title, year:mv.year, poster:mv.poster, res:mv.res,
               size:mv.size, sid:mv.sid, own:mv.own, hb:mv.hb, rb:mv.rb };
    if (cartToggle(mm)){ haptic('commit'); toast('已加入片单'); } else toast('已从片单移除');
    ad.textContent = inCart(mv.id) ? '已在片单中 · 移除' : '加入片单';
    ad.classList.toggle('on', !inCart(mv.id));
  };
  [].forEach.call(mv2.querySelectorAll('.usev'), function(b){
    b.onclick = function(){
      if (!inCart(mv.id)) cartAdd({ id:mv.id, title:mv.title, year:mv.year, poster:mv.poster,
        res:mv.res, size:mv.size, sid:b.dataset.sid, own:mv.own, hb:mv.hb, rb:mv.rb });
      cartSetRel(mv.id, b.dataset.sid, '性价比之选');
      toast('片单里这部片已换成性价比之选');
    };
  });
  [].forEach.call(mv2.querySelectorAll('.rel'), function(r){
    r.onclick = function(){ openThread(r, r.dataset.tid); };
  });
  [].forEach.call(mv2.querySelectorAll('[data-jump]'), function(b){
    b.onclick = function(){
      var t = mv2.querySelector('.rel[data-tid="' + b.dataset.jump + '"]');
      if (!t) return;
      t.scrollIntoView({ behavior:'smooth', block:'center' });
      openThread(t, b.dataset.jump);
    };
  });
  [].forEach.call(mv2.querySelectorAll('[data-use]'), function(b){
    b.onclick = function(ev){
      ev.stopPropagation();
      if (!inCart(mv.id)) cartAdd({ id:mv.id, title:mv.title, year:mv.year, poster:mv.poster,
        res:mv.res, size:mv.size, sid:b.dataset.use, own:mv.own, hb:mv.hb, rb:mv.rb });
      cartSetRel(mv.id, b.dataset.use, b.dataset.lb || '');
      toast('片单里这部片已换版本');
    };
  });
}
function relHTML(r){
  var labs = (r.labels || []).map(function(x, i){
    return (i ? '<i class="sep">·</i>' : '') + '<i class="' + (i < 2 ? 'hi' : '') + '">' + esc(x) + '</i>';
  }).join('');
  return '<div class="rel" data-tid="' + r.tid + '"><div class="t">' + esc(r.title) + '</div>'
    + '<div class="spec">'
    + (r.sn ? '<i class="hi">第 ' + r.sn + ' 季</i><i class="sep">·</i>' : '') + labs
    + (r.size ? '<i class="sep">·</i><i>' + esc(r.size) + '</i>' : '')
    + (r.group ? '<i class="sep">·</i><i>' + esc(r.group) + '</i>' : '')
    + (r.dupes ? '<i class="sep">·</i><i>同规格 ' + r.dupes + ' 版</i>' : '') + '</div>'
    + '<div class="row" style="margin-top:10px">'
    + '<button class="btn sm" data-use="' + r.sid + '" data-lb="' + esc((r.labels||[]).slice(0,2).join(' ')) + '">用这一版</button>'
    + '<span class="grow"></span><span class="pill">点开看附件</span></div>'
    + '<div class="slot"></div></div>';
}
function openThread(el, tid){
  var slot = el.querySelector('.slot');
  if (!slot) return;
  if (slot.innerHTML){ slot.innerHTML = ''; return; }
  slot.innerHTML = '<div class="panel"><div class="tail"><div class="spin"></div></div></div>';
  api('/api/thread?tid=' + tid).then(function(j){
    var h = '<div class="panel">';
    (j.attachments || []).forEach(function(a){
      h += '<div class="att"><span class="fn">' + esc(a.filename) + '</span>'
        + (a.isTorrent ? '<button class="btn sm fixed mg" data-aid="' + a.aid + '">磁力</button>' : '')
        + '<a class="btn sm" href="/api/torrent?aid=' + a.aid + '&name=' + encodeURIComponent(a.filename)
        + '&gate=' + encodeURIComponent(GATE) + '&src=' + S.src + '">下载种子</a></div>';
    });
    (j.magnets || []).forEach(function(m){
      h += '<div class="att"><span class="fn">' + esc(m.slice(0, 78)) + '…</span>'
        + '<button class="btn sm cp" data-m="' + esc(m) + '">复制</button></div>';
    });
    if (!(j.attachments || []).length && !(j.magnets || []).length)
      h += '<p class="lede">这一帖没有种子附件，也没有磁力链接。</p>';
    slot.innerHTML = h + '</div>';
    [].forEach.call(slot.querySelectorAll('.cp'), function(b){
      b.onclick = function(ev){ ev.stopPropagation(); copy(b.dataset.m); };
    });
    [].forEach.call(slot.querySelectorAll('.mg'), function(b){
      b.onclick = function(ev){
        ev.stopPropagation(); b.textContent = '取中…'; b.disabled = true;
        api('/api/magnet?aid=' + b.dataset.aid).then(function(m){
          b.outerHTML = '<button class="btn sm fixed cp2">复制磁力</button>';
          var nb = slot.querySelector('.cp2');
          nb.onclick = function(ev2){ ev2.stopPropagation(); copy(m.magnet); };
          nb.parentNode.insertAdjacentHTML('beforeend', '<div class="hash">' + esc(m.btih) + '</div>');
        }).catch(function(e){ b.textContent = '重试磁力'; b.disabled = false; toast(e.message); });
      };
    });
  }).catch(function(e){
    slot.innerHTML = '<div class="panel"><div class="err" style="margin:0">' + esc(e.message) + '</div></div>';
  });
}
</script>
<script>
/* ══════════════════════════════════════════════════════════════════
   片单 / 下载台
   ══════════════════════════════════════════════════════════════════ */
function startDL(){
  if (DL.run) return;
  if (DL.job && DL.got < DL.job.total && sameJob()) { DL.resume(); return; }
  var items = CART.ord.map(function(id){
    var m = CART.o[id];
    return (m && m.sid) ? { tid: parseInt(m.sid, 36), name: relName(m) } : null;
  }).filter(function(x){ return x && x.tid > 0; });
  if (!items.length){ toast('片单里的影片都还没有可用片源'); return; }
  DL.begin(items);
}
function sameJob(){
  if (!DL.job) return false;
  var items = CART.ord.map(function(id){
    var m = CART.o[id];
    return (m && m.sid) ? { tid: parseInt(m.sid, 36) } : null;
  }).filter(function(x){ return x && x.tid > 0; });
  return items.length ? DL.sig(items) === DL.job.id : true;
}
function dlStatusText(j){
  var done = DL.phase === 'done';
  return done ? '已打成一个包 · ' + fmtSize(DL.zipSize || 0)
       : DL.run ? dlPhase() + ' · 已取 ' + DL.got + '/' + j.total
       : DL.got >= j.total ? '取件完成，等待打包' : '已暂停 · 已取 ' + DL.got + '/' + j.total;
}
function qrowHTML(it, j){
  var f = (j.fail || {})[it.tid];
  var okd = !f && DL.doneSet && DL.doneSet[it.tid];
  return '<div class="qrow' + (f ? ' fail' : okd ? ' done' : '') + '" data-tid="' + it.tid + '">'
    + '<span class="dot ' + (f ? 'bad' : okd ? 'ok' : '') + '"></span>'
    + '<span class="qn">' + esc(it.name) + '</span>'
    + '<span class="qs">' + (f ? esc(String(f).slice(0, 22)) : okd ? '已取' : '等待') + '</span></div>';
}
/* ── 片单页 ──
   顺序按"接下来要做什么"排：正在进行的任务（有才显示）→ 片单 → 开始下载。
   任务进行中每一批都会来一次 paint：只原地改数字、进度条与行状态
   （patchDL），不整页重画 —— 海报不重闪，列表滚动位置也不丢。 */
/* ══════════ [v6.6] 导入清单 ══════════
   一张表 → 服务端逐条查：库里已有的跳过，论坛有的按偏好挑好版本放进片单（电影、剧集各进各的片单）。
   只是放进片单 —— 真正下载要等人在片单里看过、点「开始下载」。
   认得的格式：JSON 数组 / {"items":[…]} / 每行一个 JSON 对象；CSV、TSV（第一行是表头）；
   每行「tmdb_id:123/title:沙丘/year:2024」；每行一个片名（末尾的年份拆出来）或一个 TMDB 编号。 */
var IMP = { open:false, text:'', busy:false, done:0, total:0, rows:null, jobs:null, added:[], failed:[], note:'', nolib:0,
            sq:[], sdone:0, stotal:0, swait:0, gap:0, stop:false, phase:'' };
var IMP_BATCH = 12, IMP_CAP = 1000;
var IMP_KEYS = /^(tmdb_id|tmdb|tmdbid|id|title|name|片名|中文名|cn|en|original_title|original|orig|english|英文名|原名|year|年份|release_year|type|kind|类型|season|季|res|resolution|quality|分辨率|hdr|dr|动态范围|max_gb|maxgb|max_size|size_gb|体积上限|prefer|source|src|来源|note|notes|备注)$/;
var IMP_SAMPLE = '[\n  {"tmdb_id": 911430, "title": "F1：狂飙飞车", "year": 2025},\n'
  + '  {"title": "沙丘2", "year": 2024, "res": "2160p", "hdr": "dv"},\n'
  + '  {"title": "奥本海默", "year": 2023, "res": "1080p", "max_gb": 20, "note": "给爸妈"},\n'
  + '  {"tmdb_id": 94997, "type": "tv", "title": "龙之家族", "season": 2}\n]';
var IMP_ST = { add:['ok', '加入片单'], incart:['ok', '片单里已有'], owned:['', '库中已有'], dup:['', '清单里重复'],
  notfound:['warn', '论坛暂无'], ambiguous:['warn', '要你挑'], incomplete:['warn', '未完结'], queued:['', '排队搜索'], searching:['', '搜索中'],
  invalid:['bad', '格式不对'], full:['bad', '片单满了'], error:['bad', '没查成'] };
function impKey(k){ return String(k).trim().toLowerCase().replace(/\s*[(（]\s*\d+\s*[)）]\s*$/, '').replace(/^tmbd/, 'tmdb').replace(/[\s-]+/g, '_'); }
function impCSV(l, sep){
  var out = [], cur = '', q = false;
  for (var i = 0; i < l.length; i++){
    var c = l.charAt(i);
    if (q){ if (c === '"'){ if (l.charAt(i + 1) === '"'){ cur += '"'; i++; } else q = false; } else cur += c; }
    else if (c === '"' && !cur.trim()) q = true;
    else if (c === sep){ out.push(cur.trim()); cur = ''; }
    else cur += c;
  }
  out.push(cur.trim());
  return out;
}
/** 一行「键:值/键:值」；没有认得的键就整行当片名（末尾的年份拆出来），纯数字当 TMDB 编号 */
function impLine(l){
  l = l.trim();
  var re = /(^|[\/|;，；\t]\s*)([A-Za-z_一-龥]+(?:\s*[(（]\s*\d+\s*[)）])?)\s*[:：=]\s*/g, m, marks = [];
  while ((m = re.exec(l))){ var k = impKey(m[2]); if (IMP_KEYS.test(k)) marks.push({ k: k, at: m.index, end: re.lastIndex }); }
  var o = {};
  if (marks.length){
    var pre = l.slice(0, marks[0].at).trim();
    if (pre) o.title = pre;
    marks.forEach(function(mk, i){
      var v = l.slice(mk.end, i + 1 < marks.length ? marks[i + 1].at : l.length).trim();
      if (v && !(mk.k in o)) o[mk.k] = v;
    });
    return o;
  }
  l = l.replace(/^(?:[-*•·]|\d{1,4}[.)、])\s+/, '');
  if (/^\d{1,9}$/.test(l)) return { tmdb_id: l };
  var y = /^(.*?)[\s(（\[【]+((?:18|19|20)\d{2})[)）\]】]*$/.exec(l);
  return y && y[1].trim() ? { title: y[1].trim(), year: y[2] } : { title: l };
}
function impParse(t){
  t = String(t || '').replace(/^﻿/, '').trim();
  if (!t) return { items: [], err: '先贴一份清单，或选一个文件' };
  if (/^[\[{]/.test(t)){
    var j = null, e1 = null;
    try { j = JSON.parse(t); } catch(e){ e1 = e; }
    if (j == null && t.charAt(0) === '{'){
      try { j = t.split(/\r?\n/).filter(function(l){ return l.trim(); }).map(function(l){ return JSON.parse(l.trim().replace(/,$/, '')); }); }
      catch(e){ j = null; }
    }
    if (j == null) return { items: [], err: 'JSON 解析不了：' + (e1 && e1.message || '格式不对') };
    if (Array.isArray(j)) return { items: j };
    if (j && typeof j === 'object'){
      var inner = j.items || j.list || j.movies || j.films || j.data;
      if (Array.isArray(inner)) return { items: inner };
      var vals = Object.keys(j).map(function(k){ return j[k]; });
      if (vals.length > 1 && vals.every(function(v){ return v && typeof v === 'object' && !Array.isArray(v); })) return { items: vals };
      return { items: [j] };
    }
    return { items: [], err: 'JSON 里没有清单（要数组，或 {"items": [...]}）' };
  }
  var lines = t.split(/\r?\n/).filter(function(l){ return l.trim(); });
  var head = lines[0], sep = head.indexOf('\t') >= 0 ? '\t' : (head.indexOf(',') >= 0 ? ',' : '');
  if (sep && !/[:：=]/.test(head)){
    var hs = impCSV(head, sep).map(impKey);
    if (hs.filter(function(h){ return IMP_KEYS.test(h); }).length * 2 >= hs.length){
      return { items: lines.slice(1).map(function(l){
        var c = impCSV(l, sep), o = {};
        hs.forEach(function(h, i){ if (h && c[i] != null && c[i] !== '' && !(h in o)) o[h] = c[i]; });
        return o;
      }) };
    }
  }
  return { items: lines.map(impLine) };
}
function impType(x){
  if (!x || typeof x !== 'object') return 'movie';
  var o = {};
  Object.keys(x).forEach(function(k){ var kk = impKey(k); if (!(kk in o)) o[kk] = x[k]; });
  return /^(tv|series|show|剧集|电视剧|剧)$/i.test(String(o.type || o.kind || o['类型'] || '').trim()) ? 'tv' : 'movie';
}
function cartKeyOf(src){ return src === 'movie' ? 'cvcart' : 'cvcart:' + src; }
/** 加进某个源的片单（不一定是当前源）：1 = 加了，0 = 本来就有，-1 = 满了 */
function cartAddTo(src, m, label){
  var rec = { id:m.id, title:m.title, year:m.year, poster:m.poster, res:m.res, size:m.size, sid:m.sid, own:m.own || 0, hb:m.hb, rb:m.rb };
  if (label) rec.pickLabel = label;
  if (m.ext) rec.ext = 1;
  if (src === S.src){
    if (CART.o[m.id]) return 0;
    if (CART.ord.length >= MAX) return -1;
    if (!cartAdd(m)) return -1;
    if (label){ CART.o[m.id].pickLabel = label; cartSave(); }
    return 1;
  }
  var c = null;
  try { c = JSON.parse(localStorage.getItem(cartKeyOf(src)) || 'null'); } catch(e){}
  if (!c || !c.ord) c = { ord: [], o: {} };
  if (c.o[m.id]) return 0;
  if (c.ord.length >= MAX) return -1;
  c.ord.push(m.id); c.o[m.id] = rec;
  try { localStorage.setItem(cartKeyOf(src), JSON.stringify(c)); } catch(e){ return -1; }
  return 1;
}
function cartDropFrom(src, ids){
  if (src === S.src){
    ids.forEach(function(id){ if (CART.o[id]){ delete CART.o[id]; markTile(id, false); } });
    CART.ord = CART.ord.filter(function(x){ return CART.o[x]; });
    cartSave(); paintDock(); return;
  }
  try {
    var c = JSON.parse(localStorage.getItem(cartKeyOf(src)) || 'null');
    if (!c || !c.ord) return;
    ids.forEach(function(id){ delete c.o[id]; });
    c.ord = c.ord.filter(function(x){ return c.o[x]; });
    localStorage.setItem(cartKeyOf(src), JSON.stringify(c));
  } catch(e){}
}
function impTake(j, it, src){
  var row = { src: src, it: it, st: it.status, x: j.x };
  if (it.status === 'add'){
    var r = cartAddTo(src, it, it.label || '');
    row.st = r === 1 ? 'add' : r === 0 ? 'incart' : 'full';
    if (r === 1) IMP.added.push({ src: src, id: it.id });
  }
  /* [v6.7] 索引里没有的：排队去论坛搜索页搜（TMDB 认出来的编号一起带上，搜的时候能多一个译名可比） */
  if (it.status === 'notfound' && it.fs){
    row.st = 'queued'; j.src = src; j.kw = ''; j.waits = 0;
    if (it.tmdb) j.tmdb = it.tmdb;
    IMP.sq.push(j);
  } else if (it.status === 'notfound' && it.retry) IMP.failed.push(j);     // TMDB 这次没查成：可以重试
  IMP.rows[j.i] = row;
}
function impStart(){
  if (IMP.busy) return;
  var ta = document.getElementById('imptx');
  if (ta) IMP.text = ta.value;
  var P = impParse(IMP.text);
  IMP.note = P.err || (!P.items.length ? '清单是空的' : '');
  if (IMP.note){ renderDL(); return; }
  if (P.items.length > IMP_CAP) IMP.note = '清单有 ' + P.items.length + ' 条，这次先查前 ' + IMP_CAP + ' 条';
  IMP.rows = []; IMP.added = []; IMP.nolib = 0; IMP.gap = 0;
  IMP.jobs = P.items.slice(0, IMP_CAP).map(function(x, i){ return { i: i, x: x, t: impType(x) }; });
  impRun(IMP.jobs);
}
function impRun(jobs){
  IMP.busy = true; IMP.done = 0; IMP.total = jobs.length; IMP.failed = []; IMP.sq = []; IMP.stop = false; IMP.phase = 'index';
  var batches = [];
  ['movie', 'tv'].forEach(function(t){
    var g = jobs.filter(function(j){ return j.t === t; });
    for (var k = 0; k < g.length; k += IMP_BATCH) batches.push({ t: t, jobs: g.slice(k, k + IMP_BATCH) });
  });
  renderDL();
  var step = function(bi){
    if (bi >= batches.length) return IMP.sq.length && !IMP.stop ? impSearch() : impFinish();
    var b = batches[bi];
    api('/api/import', { method: 'POST', body: JSON.stringify({ items: b.jobs.map(function(j){ return j.x; }) }), src: b.t, timeout: 45000 })
      .then(function(r){
        (r.items || []).forEach(function(it){ var j = b.jobs[it.k]; if (j) impTake(j, it, b.t); });
        var n = Math.min(r.n || 0, b.jobs.length);
        if (n < b.jobs.length) batches.splice(bi + 1, 0, { t: b.t, jobs: b.jobs.slice(n) });   // 服务端一次收不下：剩下的下一批再发
        if (!r.lib) IMP.nolib = 1;
        IMP.done += n;
      }, function(e){
        b.jobs.forEach(function(j){ IMP.failed.push(j); IMP.rows[j.i] = { src: b.t, x: j.x, st: 'error', it: { status: 'error', reason: e.message || String(e) } }; });
        IMP.done += b.jobs.length;
      })
      .then(function(){ if (S.view === 'dl') renderDL(); step(bi + 1); });
  };
  step(0);
}
/* [v6.7] 论坛搜索：一条一条搜。论坛限频（N 秒一次）时等够了再搜，等的秒数记下来，之后每条搜完都先等这么久 */
function impSearch(){
  IMP.busy = true; IMP.phase = 'search'; IMP.stop = false; IMP.sdone = 0; IMP.stotal = IMP.sq.length;
  IMP.sq.forEach(function(j){ var r = IMP.rows[j.i]; if (r) r.st = 'queued'; });
  if (S.view === 'dl') renderDL();
  var next = function(){
    if (IMP.stop || !IMP.sq.length) return impFinish();
    var j = IMP.sq[0], row = IMP.rows[j.i] || (IMP.rows[j.i] = { src: j.src, x: j.x, st: 'queued', it: {} });
    var go = function(){
      if (IMP.stop) return impFinish();
      row.st = 'searching'; impPaint();
      var item = (j.x && typeof j.x === 'object' && !Array.isArray(j.x)) ? Object.assign({}, j.x) : {};
      if (j.tmdb && item.tmdb_id == null && item.tmdb == null && item.id == null) item.tmdb_id = j.tmdb;
      api('/api/fsearch', { method: 'POST', body: JSON.stringify(j.kw ? { item: item, kw: j.kw } : { item: item }), src: j.src, timeout: 45000 })
        .then(function(r){
          if (r.status === 'wait'){
            IMP.gap = Math.max(IMP.gap, r.wait || 10);
            row.st = 'queued';
            if (++j.waits > 6){
              IMP.sq.shift(); IMP.sdone++; IMP.failed.push(j);
              row.st = 'error'; row.it = Object.assign({}, row.it, { status: 'error', reason: '论坛一直限频，这条没搜成' });
              return impWait(IMP.gap, next);
            }
            return impWait((r.wait || 10) + 1, go);
          }
          if (r.status === 'again'){
            j.kw = r.again; row.st = 'queued'; row.it = Object.assign({}, row.it, { reason: r.reason });
            return impWait(r.searched ? IMP.gap : 0, go);
          }
          IMP.sq.shift(); IMP.sdone++;
          if (!r.note && row.it && row.it.note) r.note = row.it.note;
          impTake(j, r, j.src);
          impWait(r.searched ? IMP.gap : 0, next);
        }, function(e){
          IMP.sq.shift(); IMP.sdone++; IMP.failed.push(j);
          row.st = 'error'; row.it = Object.assign({}, row.it, { status: 'error', reason: '论坛搜索失败：' + (e.message || e) });
          impWait(IMP.gap, next);
        });
    };
    go();
  };
  next();
}
function impWait(sec, fn){
  if (S.view === 'dl') renderDL();
  if (!(sec > 0)) return fn();
  IMP.swait = Math.ceil(sec); impPaint();
  var t = setInterval(function(){
    IMP.swait--;
    if (IMP.stop || IMP.swait <= 0){ clearInterval(t); IMP.swait = 0; fn(); return; }
    impPaint();
  }, 1000);
}
function impBusyText(){
  return IMP.phase === 'search' ? '论坛搜索 ' + IMP.sdone + ' / ' + IMP.stotal : '查询中 ' + IMP.done + ' / ' + IMP.total;
}
function impProgHTML(){
  if (IMP.phase !== 'search') return '';
  var left = IMP.stotal - IMP.sdone, per = Math.max(IMP.gap, 2), min = Math.ceil(left * per / 60);
  return '<span>索引里没有的 ' + IMP.stotal + ' 部，正在论坛搜索页一条条搜'
    + (IMP.swait ? ' · 论坛限制搜索频率，' + IMP.swait + ' 秒后搜下一条' : '')
    + (left > 1 && IMP.gap ? ' · 大约还要 ' + min + ' 分钟' : '') + '</span>'
    + '<button class="btn sm" id="impstop">' + (IMP.stop ? '正在停…' : '停止搜索') + '</button>';
}
/** 搜索进行中：只改进度、按钮字和状态变了的那几行，不整页重画（列表不跳、输入框不丢焦点） */
function impPaint(){
  if (S.view !== 'dl') return;
  var b = document.getElementById('impgo'); if (b && IMP.busy) b.textContent = impBusyText();
  var p = document.getElementById('impprog'); if (p) p.innerHTML = impProgHTML();
  var bar = document.querySelector('#impcard .bar2 i');
  if (bar){
    var f = IMP.phase === 'search' ? (IMP.stotal ? IMP.sdone / IMP.stotal : 0) : (IMP.total ? IMP.done / IMP.total : 0);
    bar.style.transform = 'scaleX(' + Math.max(.02, f) + ')';
  }
  (IMP.rows || []).forEach(function(r, i){
    var e = document.getElementById('ir' + i);
    if (e && r && e.getAttribute('data-st') !== r.st) e.outerHTML = impRowHTML(r, i);
  });
  impBindRows();
}
function impFinish(){
  IMP.busy = false; IMP.phase = ''; IMP.swait = 0;
  /* 停下了：还没搜的留着，「继续论坛搜索」接着搜 */
  IMP.sq.forEach(function(j){ var r = IMP.rows[j.i]; if (r){ r.st = 'notfound'; r.it = Object.assign({}, r.it, { reason: '还没去论坛搜（停下了）' }); } });
  var n = IMP.added.length, tv = IMP.added.filter(function(a){ return a.src !== S.src; }).length;
  var inc = (IMP.rows || []).filter(function(r){ return r && r.st === 'incomplete'; }).length;
  if (S.view === 'dl') renderDL();
  toast((n ? '加进片单 ' + n + ' 部' + (tv ? '（' + tv + ' 部在另一边的片单）' : '') : '没有新加进片单的')
    + (inc ? '，' + inc + ' 部还没完结' : '') + (n ? '，看过再点「开始下载」' : ''));
}
function impUndo(){
  var by = {};
  IMP.added.forEach(function(a){ (by[a.src] = by[a.src] || []).push(a.id); });
  Object.keys(by).forEach(function(src){ cartDropFrom(src, by[src]); });
  (IMP.rows || []).forEach(function(r){ if (r && r.st === 'add') r.st = 'undone'; });
  toast('撤回了这次加进片单的 ' + IMP.added.length + ' 部');
  IMP.added = [];
  renderDL();
}
/** 「未完结」那行的按钮：服务端已经把版本挑好（rec），直接放进片单 */
function impPickRec(i, k){
  var row = IMP.rows && IMP.rows[i];
  var c = row && row.it && row.it.cands && row.it.cands[k];
  if (!c || !c.rec) return;
  var rec = c.rec, rr = cartAddTo(row.src, rec, rec.label || '');
  row.it = Object.assign({}, rec, { status: 'add', note: row.it.note, reason: '你挑的：' + c.label.replace(/^(仍然)?加入/, '') });
  row.st = rr === 1 ? 'add' : rr === 0 ? 'incart' : 'full';
  if (rr === 1) IMP.added.push({ src: row.src, id: rec.id });
  renderDL();
}
function impPick(i, id){
  var row = IMP.rows && IMP.rows[i];
  if (!row || IMP.phase === 'index') return;
  api('/api/cart?ids=' + id, { src: row.src }).then(function(r){
    var m = r.items && r.items[0];
    if (!m || m.missing) throw new Error('索引里没有这部了');
    var rr = cartAddTo(row.src, m, '');
    row.it = { status: 'add', id: m.id, title: m.title, year: m.year, poster: m.poster, res: m.res, size: m.size, hb: m.hb, note: row.it.note, reason: '你挑的' };
    row.st = rr === 1 ? 'add' : rr === 0 ? 'incart' : 'full';
    if (rr === 1) IMP.added.push({ src: row.src, id: m.id });
    if (m.own) row.it.reason = '你挑的 · 注意：库里' + (m.own === 2 ? '已有' : '可能已有');
    renderDL();
  }).catch(function(e){ toast(e.message || String(e)); });
}
function impRowHTML(row, i){
  if (!row) return '';
  var it = row.it || {}, st = IMP_ST[row.st] || ['', row.st === 'undone' ? '已撤回' : row.st];
  var name = it.title || (row.x && typeof row.x === 'object' ? (row.x.title || row.x.name || '') : '') || ('第 ' + (i + 1) + ' 条');
  var bits = [];
  if (row.st === 'add' || row.st === 'incart'){
    /* 锁定了版本的（label 里已经有分辨率、HDR）就不再重复写 */
    bits.push(it.label ? '' : it.res, it.size, it.label ? '' : (it.hb === 7 ? '杜比视界' : it.hb >= 3 ? 'HDR' : ''), it.label, it.reason, it.via ? '经' + it.via : '');
  } else if (row.st === 'owned') bits.push(it.reason, it.file);
  else if (row.st === 'invalid' && row.x != null && !it.title) bits.push(it.reason, String(typeof row.x === 'object' ? JSON.stringify(row.x) : row.x).slice(0, 80));
  else bits.push(it.reason);
  if (it.note) bits.push('备注：' + it.note);
  var h = '<div class="irow" id="ir' + i + '" data-st="' + esc(row.st) + '"><span class="dot ' + st[0] + (row.st === 'searching' ? ' live' : '') + '"></span><div class="ib"><b>' + esc(name) + '</b>'
    + (it.year ? ' <span class="num">' + esc(it.year) + '</span>' : '')
    + (row.src !== S.src ? ' <span class="pill">' + (row.src === 'tv' ? '剧集' : '电影') + '</span>' : '')
    + '<em>' + esc(bits.filter(Boolean).join('  ·  ') || '—') + '</em>';
  if (row.st === 'owned' && it.id)
    h += '<div class="cands"><button class="btn sm" data-icand="' + i + ':' + it.id + '">仍然加入（换个版本）</button></div>';
  if (row.st === 'incomplete' && it.cands && it.cands.length)
    h += '<div class="cands">' + it.cands.map(function(c, k){
      return '<button class="btn sm" data-irec="' + i + ':' + k + '">' + esc(c.label) + '</button>';
    }).join('') + '</div>';
  if (row.st === 'ambiguous' && it.cands)
    h += '<div class="cands">' + it.cands.map(function(c){
      return '<button class="btn sm" data-icand="' + i + ':' + c.id + '">' + esc(c.title + (c.year ? ' (' + c.year + ')' : '')) + (c.own ? ' · 库' + (c.own === 2 ? '中已有' : '里可能有') : '') + '</button>';
    }).join('') + '</div>';
  return h + '</div><span class="pill ' + st[0] + '">' + esc(st[1]) + '</span></div>';
}
function impHTML(){
  if (!IMP.open) return '';
  var h = '<div class="card imp" id="impcard"><div class="hd"><h2 class="sec">导入清单</h2><span class="sub">JSON · CSV · 每行一条</span></div>'
    + '<textarea id="imptx" spellcheck="false" autocomplete="off" aria-label="清单" placeholder="' + esc(IMP_SAMPLE) + '"' + (IMP.busy ? ' disabled' : '') + '>' + esc(IMP.text) + '</textarea>'
    + '<p class="fine">每条至少有 <b>tmdb_id</b> 或 <b>title</b>；还可以写 year、type（movie / tv）、season、res（2160p / 1080p / 720p）、hdr（dv / hdr / sdr）、max_gb、prefer（remux / bluray / web）、note。'
    + '库里已有的自动跳过；论坛有的按偏好挑好版本放进片单，剧集只要整季包（全 N 集），单集和没完结的不加；索引里没有的自动去论坛搜索页搜。'
    + '只是放进片单，点「开始下载」之前什么都不会下。</p>'
    + '<div class="row"><button class="btn on fixed" id="impgo"' + (IMP.busy ? ' disabled' : '') + '>' + (IMP.busy ? impBusyText() : '查询并加入片单') + '</button>'
    + '<label class="btn" for="impfile"' + (IMP.busy ? ' aria-disabled="true"' : '') + '>选文件</label>'
    + '<input type="file" id="impfile" accept=".json,.csv,.tsv,.txt,application/json,text/csv,text/plain" hidden>'
    + '<button class="btn" id="impeg"' + (IMP.busy ? ' disabled' : '') + '>填入示例</button>'
    + '<span class="grow"></span><button class="btn sm" id="impx"' + (IMP.busy ? ' disabled' : '') + '>收起</button></div>';
  if (IMP.busy){
    var frac = IMP.phase === 'search' ? (IMP.stotal ? IMP.sdone / IMP.stotal : 0) : (IMP.total ? IMP.done / IMP.total : 0);
    h += '<div class="bar2" style="margin-top:14px"><i style="transform:scaleX(' + Math.max(.02, frac) + ')"></i></div>'
      + '<div class="row imp-prog" id="impprog">' + impProgHTML() + '</div>';
  }
  if (IMP.note) h += '<div class="warnbox">' + esc(IMP.note) + '</div>';
  if (IMP.rows && IMP.rows.length){
    var cnt = {}, rows = IMP.rows;
    rows.forEach(function(r){ if (r) cnt[r.st] = (cnt[r.st] || 0) + 1; });
    h += '<div class="imp-sum">' + Object.keys(IMP_ST).concat(['undone']).filter(function(k){ return cnt[k]; }).map(function(k){
      return '<span class="pill ' + (IMP_ST[k] ? IMP_ST[k][0] : '') + '">' + (IMP_ST[k] ? IMP_ST[k][1] : '已撤回') + ' <b class="num">' + cnt[k] + '</b></span>';
    }).join('') + '</div>';
    if (!IMP.busy){
      var other = IMP.added.filter(function(a){ return a.src !== S.src; }).length;
      h += '<p class="fine">' + (IMP.added.length ? '这次加进片单 ' + IMP.added.length + ' 部' + (other ? '（其中 ' + other + ' 部在' + (S.src === 'tv' ? '电影' : '剧集') + '的片单里，切过去就能看到）' : '') + '。看一眼下面的片单，没问题再点「开始下载」。' : '这次没有新加进片单的。')
        + (IMP.nolib ? ' 片库这次没连上，没法排除库里已有的 —— 下载前留意一下。' : '') + '</p>';
      h += '<div class="row" style="margin-bottom:6px">'
        + (IMP.added.length ? '<button class="btn sm" id="impundo">撤回这次加入的 ' + IMP.added.length + ' 部</button>' : '')
        + (IMP.sq.length ? '<button class="btn sm" id="impmore">继续论坛搜索（剩 ' + IMP.sq.length + ' 条）</button>' : '')
        + (IMP.failed.length ? '<button class="btn sm" id="impretry">重试没查成的 ' + IMP.failed.length + ' 条</button>' : '')
        + '<button class="btn sm" id="impclr">清掉结果</button></div>';
    }
    h += '<div class="ilist">' + rows.map(impRowHTML).join('') + '</div>';
  }
  return h + '</div>';
}
function impBind(){
  var g = function(id){ return document.getElementById(id); };
  var on = function(id, fn){ var e = g(id); if (e) e.onclick = fn; };
  var ta = g('imptx');
  if (ta) ta.oninput = function(){ IMP.text = ta.value; };
  on('impopen', function(){ IMP.open = true; renderDL(); var t = g('imptx'); if (t) t.focus(); });
  on('impopen2', function(){ IMP.open = true; renderDL(); var t = g('imptx'); if (t) t.focus(); });
  on('impx', function(){ if (!IMP.busy){ IMP.open = false; renderDL(); } });
  on('impgo', impStart);
  on('impeg', function(){ IMP.text = IMP_SAMPLE; IMP.note = ''; renderDL(); });
  on('impundo', impUndo);
  on('impretry', function(){ var f = IMP.failed.slice(); if (f.length && !IMP.busy){ IMP.note = ''; impRun(f); } });
  on('impclr', function(){ IMP.rows = null; IMP.added = []; IMP.failed = []; IMP.sq = []; IMP.note = ''; renderDL(); });
  on('impmore', function(){ if (!IMP.busy && IMP.sq.length) impSearch(); });
  impBindRows();
  var f = g('impfile');
  if (f) f.onchange = function(){
    var file = f.files && f.files[0];
    if (!file) return;
    if (file.size > 2 * 1024 * 1024){ toast('文件太大（超过 2MB）'); return; }
    var rd = new FileReader();
    rd.onload = function(){ IMP.text = String(rd.result || ''); IMP.note = '读进来了：' + file.name + '（' + impParse(IMP.text).items.length + ' 条），点「查询并加入片单」'; renderDL(); };
    rd.onerror = function(){ toast('文件读不出来'); };
    rd.readAsText(file);
  };
}
function impBindRows(){
  var st = document.getElementById('impstop');
  if (st) st.onclick = function(){ IMP.stop = true; st.textContent = '正在停…'; };
  [].forEach.call(document.querySelectorAll('[data-icand]'), function(b){
    b.onclick = function(){ var p = b.dataset.icand.split(':'); impPick(+p[0], +p[1]); };
  });
  [].forEach.call(document.querySelectorAll('[data-irec]'), function(b){
    b.onclick = function(){ var p = b.dataset.irec.split(':'); impPickRec(+p[0], +p[1]); };
  });
}
function renderDL(){
  S.view = 'dl'; backEl.classList.remove('on'); setNav('dl');
  if (io) io.disconnect();
  var n = cartCount(), j = DL.job;
  var h = '<h1>片单</h1><p class="lede">点海报加进来，或导入一张清单；一次最多 ' + MAX + ' 部，取齐之后在本机压成一个包</p>';

  if (j){
    var pct = j.total ? Math.round(DL.got / j.total * 100) : 0;
    var fails = Object.keys(j.fail || {}).length;
    var done = DL.phase === 'done';
    h += '<div class="card" id="dlprog"><div class="dl-head">'
      + '<b class="num" id="dlpct">' + (done ? '100' : pct) + '%</b>'
      + '<span id="dltxt">' + dlStatusText(j) + '</span>'
      + '<span class="grow"></span><span id="dlpill">'
      + (DL.run ? '<span class="pill ok"><span class="dot live"></span>进行中</span>'
                : done ? '<span class="pill ok">完成</span>' : '<span class="pill">待续</span>')
      + '</span></div>'
      + '<div class="bar2" id="dlbar"><i class="' + (done ? 'ok' : '')
      + '" style="transform:scaleX(' + (Math.max(2, pct) / 100) + ')"></i></div>'
      + '<div class="dl-meta">'
      + '<span>已落盘 <i class="num" id="dlbytes">' + fmtSize(DL.bytes) + '</i></span>'
      + '<span>失败 <i class="num" id="dlfail">' + fails + '</i></span>'
      + '<span>每批 <i class="num">' + GRAB + '</i> 部</span>'
      + '<span>打包 <i>' + (DL.how === 'gpu' ? 'GPU 并行' : '独立线程') + '</i></span></div>';
    h += '<div id="dlerr">' + (DL.err ? '<div class="err" style="margin:14px 0 0">' + esc(DL.err) + '</div>' : '') + '</div>';
    h += '<div class="row" style="margin-top:15px">'
      + (DL.run ? '<button class="btn" id="dpause">暂停</button>'
                : (DL.got >= j.total ? '<button class="btn on" id="drepack">' + (done ? '再存一份' : '现在打包') + '</button>'
                                     : '<button class="btn on" id="dgo2">继续取件</button>'))
      + '<button class="btn" id="ddrop">清除任务</button></div>';
    h += '<div class="qlist">' + j.items.map(function(it){ return qrowHTML(it, j); }).join('') + '</div></div>';
  }

  h += impHTML();
  h += '<div class="card"><div class="hd"><h2 class="sec">片单</h2>'
    + '<div class="row" style="column-gap:12px"><span class="sub">' + n + ' / ' + MAX + '</span>'
    + (IMP.open ? '' : '<button class="btn sm" id="impopen">导入清单</button>') + '</div></div>';
  if (!n) h += '<div class="empty" style="--empty-h:190px"><h3>片单是空的</h3>'
    + '<p>在片库点海报就能加进来。全部取齐之后会在本机压成一个包。</p>'
    + '<div class="row"><button class="btn on" id="tolib">去片库挑片</button>'
    + (IMP.open ? '' : '<button class="btn" id="impopen2">导入清单</button>') + '</div></div>';
  else {
    h += CART.ord.map(function(id){
      var m = CART.o[id]; if (!m) return '';
      var line = [m.own === 2 ? '库中已有' : m.own === 1 ? '疑似已有' : '', m.res, m.size,
        m.hb === 7 ? '杜比视界' : m.hb >= 3 ? 'HDR' : '',
        m.pickLabel ? '已指定：' + m.pickLabel : '', m.ext ? '论坛搜索' : ''].filter(Boolean).join('  ·  ') || '默认最佳片源';
      return '<div class="citem" data-id="' + id + '"><div class="cth">'
        + (m.poster ? '<img loading="lazy" decoding="async" src="' + img(m.poster) + '" alt="">' : '') + '</div>'
        + '<div class="cb"><b>' + esc(m.title) + '</b><em>'
        + esc([m.year, line].filter(Boolean).join('  ·  ')) + '</em></div>'
        + (m.ext ? '' : '<button class="btn sm" data-open="' + id + '">换版本</button>')
        + '<button class="cx" data-del="' + id + '" aria-label="移除">✕</button></div>';
    }).join('');
    h += '<div class="row" style="margin-top:16px">'
      + '<button class="btn on" id="dstart">' + (j && !sameJob() ? '按当前片单重新下载' : '开始下载 ' + n + ' 部') + '</button>'
      + '<button class="btn" id="dclr2">清空片单</button></div>';
  }
  h += '</div>';
  h += '<p class="fine" style="margin:4px 2px 0">取件按批落进本机数据库，刷新、断网、关页都不丢，回来只补缺的那几部。'
    + '压缩包解压出来是一个文件夹，里面每 ' + PACK_PER + ' 部一个子文件夹（001-020、021-040…），按片单顺序，附一份清单。</p>';

  var oldQ = out.querySelector('.qlist'), oldI = out.querySelector('.ilist');
  var keep = oldQ ? oldQ.scrollTop : 0, keepI = oldI ? oldI.scrollTop : 0;
  out.innerHTML = h;
  DL._pp = DL.phase;
  var newQ = out.querySelector('.qlist');
  if (newQ && keep) newQ.scrollTop = keep;
  var newI = out.querySelector('.ilist');
  if (newI && keepI) newI.scrollTop = keepI;
  if (!DL.run) paint();
  var bind = function(id, fn){ var e = document.getElementById(id); if (e) e.onclick = fn; };
  bind('dstart', function(){
    if (DL.job && !sameJob()) DL.clear().then(startDL); else startDL();
  });
  bind('dgo2', function(){ DL.resume(); });
  bind('dpause', function(){ DL.stop = true; toast('取件将在本批结束后暂停'); });
  bind('drepack', function(){ DL.pack(); });
  bind('ddrop', function(){ DL.clear().then(function(){ renderDL(); toast('任务已清除'); }); });
  bind('dclr2', clearCart);
  bind('tolib', function(){ view('lib'); });
  impBind();
  [].forEach.call(out.querySelectorAll('[data-del]'), function(b){
    b.onclick = function(){ cartDel(+b.dataset.del); };
  });
  [].forEach.call(out.querySelectorAll('[data-open]'), function(b){
    b.onclick = function(){ var m = CART.o[+b.dataset.open]; if (m) openMovie(m); };
  });
  refreshDone();
}
/* 进行中的原地补丁：数字、进度条、状态字、行状态。结构没变就不重画。 */
function patchDL(){
  var j = DL.job, box = document.getElementById('dlprog');
  if (!j || !box) return false;
  var pct = j.total ? Math.round(DL.got / j.total * 100) : 0;
  var done = DL.phase === 'done';
  var set = function(id, v){ var e = document.getElementById(id); if (e && e.textContent !== v) e.textContent = v; };
  set('dlpct', (done ? 100 : pct) + '%');
  set('dltxt', dlStatusText(j));
  set('dlbytes', fmtSize(DL.bytes));
  set('dlfail', String(Object.keys(j.fail || {}).length));
  var bar = box.querySelector('#dlbar i');
  if (bar){ bar.style.transform = 'scaleX(' + (Math.max(2, pct) / 100) + ')'; bar.classList.toggle('ok', done); }
  var er = document.getElementById('dlerr');
  if (er){
    var want = DL.err ? '<div class="err" style="margin:14px 0 0">' + esc(DL.err) + '</div>' : '';
    if (er.innerHTML !== want) er.innerHTML = want;
  }
  var ds = DL.doneSet || {}, fl = j.fail || {};
  [].forEach.call(box.querySelectorAll('.qrow'), function(r){
    var tid = r.dataset.tid, f = fl[tid];
    var cls = f ? 'fail' : ds[tid] ? 'done' : '';
    if ((r.dataset.st || '') === cls) return;
    r.dataset.st = cls;
    r.classList.toggle('fail', cls === 'fail'); r.classList.toggle('done', cls === 'done');
    var dot = r.querySelector('.dot');
    dot.className = 'dot' + (cls === 'fail' ? ' bad' : cls === 'done' ? ' ok' : '');
    r.querySelector('.qs').textContent = f ? String(f).slice(0, 22) : cls === 'done' ? '已取' : '等待';
  });
  return true;
}
/* 队列里哪几部已经落盘：只查键，不读数据 */
function refreshDone(){
  if (!DL.job) return;
  tx('parts','readonly',function(s){ return s.getAllKeys(DL.range()); }).then(function(ks){
    var cut = DL.job.id.length + 1, map = {};
    ks.forEach(function(k){ map[String(k).slice(cut)] = 1; });
    DL.doneSet = map;
    if (S.view === 'dl') patchDL();
  }).catch(function(){});
}

/* ══════════════════════════════════════════════════════════════════
   系统 —— 状态 / 管线 / 年份 / 未匹配 / 片库对照 / 日志 / 维护
   外面只留四个数字、一句状态、一个主动作；其余收进可展开区。
   ══════════════════════════════════════════════════════════════════ */
var RUN = { on:false, stop:false, mode:null, log:[] };
var STAGES = ['list','parse','match','encode','store','lib'];
var STAGE_HINT = { list:'论坛列表页', parse:'标题切片名', match:'TMDB 认定', encode:'MFX 编码', store:'写入 R2', lib:'片库认定' };
/* 可展开区的开合状态：跨重画保留，跨刷新也保留（存 localStorage）。
   系统页外面只留四个数字、一句状态和一个主动作；其余都在这些区里。 */
var DX = (function(){ try { return JSON.parse(localStorage.getItem('cvdx') || '{}') || {}; } catch(e){ return {}; } })();
function dxSave(){ try { localStorage.setItem('cvdx', JSON.stringify(DX)); } catch(e){} }
function dxHTML(key, title, sub, body, cls){
  return '<details class="dx card' + (cls ? ' ' + cls : '') + '" data-x="' + key + '"' + (DX[key] ? ' open' : '') + '>'
    + '<summary><span class="dxt">' + title + '</span><span class="dxr">' + (sub || '') + '</span></summary>'
    + '<div class="dxb">' + body + '</div></details>';
}
/* toggle 不冒泡，用捕获在根上收一次就够了 */
out.addEventListener('toggle', function(e){
  var d = e.target;
  if (d && d.tagName === 'DETAILS' && d.dataset.x){ DX[d.dataset.x] = d.open; dxSave(); }
}, true);

function openIndex(){
  S.view = 'idx'; backEl.classList.remove('on'); setNav('idx');
  if (io) io.disconnect();
  out.innerHTML = '<h1>系统 · ' + SRCS[S.src].name + '</h1>'
    + '<p class="lede">论坛' + SRCS[S.src].name + '版块的本地副本，搜索和浏览都只读它；顶栏可以换源。</p>'
    + '<div id="ip"><div class="card"><div class="tail"><div class="spin"></div></div></div></div>'
    + '<div id="lg"></div>'
    + dxHTML('tools', '维护', '<span class="sub">体检 · 重置</span>',
        '<div class="row" id="toolrow"></div>'
        + '<p class="fine" style="margin-top:10px">体检会逐项检查会话、索引、R2 与 TMDB，能修的给出一键修复。'
        + '「重置任务」清掉残留的任务锁与降级计数，任务卡住不动时用。</p>'
        + '<div id="dgbox"></div>');
  bindTools();
  paint(); loadState(); loadLogs();
}
function bindTools(){
  var row = document.getElementById('toolrow'); if (!row) return;
  row.innerHTML = '<button class="btn fixed" id="dg">体检</button>'
    + '<button class="btn fixed" id="unlock">重置任务</button>';
  var bind = function(id, fn){ var e = document.getElementById(id); if (e) e.onclick = fn; };
  bind('dg', function(){ runDiagnose(document.getElementById('dg')); });
  bind('unlock', function(){
    var u = document.getElementById('unlock'); u.textContent = '重置中…'; u.disabled = true;
    api('/api/repair?do=resetTask').then(function(r){
      say('已解锁并清零降级计数（原 deaths=' + r.deaths + '）'); loadState();
    }).catch(function(e){ say(e.message, 1); })
      .finally(function(){ u.textContent = '重置任务'; u.disabled = false; });
  });
}
function loadState(){
  api('/api/lib').then(function(l){ S.libst = l; if (S.view === 'idx' && S.st) renderIndex(); }, function(){});
  api('/api/state').then(function(st){
    if (S.view !== 'idx') return;
    S.st = st; GRAB = st.grabMax || GRAB; MAX = st.cartMax || MAX;
    renderIndex();
  }).catch(function(e){
    var ip = document.getElementById('ip');
    if (ip) ip.innerHTML = '<div class="err">' + esc(e.message) + '</div>';
  });
}
function flowHTML(st){
  var p = st.pipe, sg = (p && p.stages) || {};
  var h = '<div class="flow' + (RUN.on ? ' run' : '') + '">';
  STAGES.forEach(function(k, i){
    var s = sg[k] || { i:0, o:0, e:0 };
    if (i) h += '<div class="link2" style="--i:' + (i - 1) + '"><i></i></div>';
    h += '<div class="node' + (s.e ? ' err' : (RUN.on && s.i ? ' act' : '')) + '" title="' + esc(STAGE_HINT[k] || '') + '">'
      + '<div class="nn">' + (st.stageNames ? st.stageNames[k] : k) + '</div>'
      + '<div class="nv num">' + (s.o || 0) + '</div>'
      + '<div class="ns">' + (s.i || 0) + ' 进'
      + (s.e ? ' · <b>' + s.e + ' 错</b>' : '') + '</div></div>';
  });
  return h + '</div>';
}
function sparkHTML(st){
  var arr = (st.pipes || []).slice().reverse();
  if (!arr.length) return '';
  var max = Math.max.apply(null, arr.map(function(x){ return x.o || 0; })) || 1;
  return '<div class="spark">' + arr.map(function(x){
    var hgt = Math.max(0.06, (x.o || 0) / max);
    return '<i class="' + (x.e ? '' : 'hot') + '" style="transform:scaleY(' + hgt.toFixed(3) + ')" title="'
      + esc((x.kind || '') + ' · 入库 ' + (x.o||0) + ' · 子请求 ' + (x.sub||0)) + '"></i>';
  }).join('') + '</div>';
}
/* 一句话状态：正在跑 / 冷却 / 待建 / 已建完 */
function sysLine(st){
  if (RUN.on) return '<span class="dot live"></span><b>' + (RUN.mode === 'inc' ? '正在抓取新片' : '正在建立索引') + '</b>'
    + (RUN.mode === 'turbo' ? ' · 极限模式' : '');
  if (st.cooling) return '<span class="dot warn"></span><b>论坛限速冷却中</b>，还需 ' + st.cooling + ' 秒';
  if (st.busy) return '<span class="dot warn"></span><b>后台任务运行中</b>，约 ' + st.lockLeft + ' 秒后空闲';
  var wn = (st.pend && st.pend.wait) || 0;
  if (st.done && wn) return '<span class="dot"></span><b>列表已抓完</b>，还有 ' + wn + ' 组在排队认定，点「继续建立索引」认完';
  if (st.done) return '<span class="dot ok"></span><b>索引已建完</b>' + (st.at ? '，更新于 ' + since(st.at) : '');
  var left = st.years.filter(function(y){ return !y.done; }).length;
  return '<span class="dot"></span><b>还有 ' + left + ' 个年份没建完</b>，任务会分轮进行，可以随时停';
}
function yearRow(y){
  var pct = y.last ? Math.min(100, Math.round(y.page / y.last * 100)) : (y.done ? 100 : 0);
  return '<div class="yr" data-y="' + y.year + '"><b>' + y.year + '</b>'
    + '<div class="bar2"><i class="' + (y.done ? 'ok' : '')
    + '" style="transform:scaleX(' + (pct / 100) + ')"></i></div>'
    + '<em>' + yearText(y) + '</em></div>';
}
function yearText(y){
  return (y.done ? '完成 · ' + y.rels : (y.last ? y.page + '/' + y.last + ' 页' : '未开始'))
    + (y.parts ? ' · ' + y.parts + ' 片' : '')
    + (y.bad ? ' · 补 ' + y.bad : '');
}
function renderIndex(){
  var st = S.st, ip = document.getElementById('ip');
  if (!ip || !st) return;
  var p = st.pipe || {};
  var subPct = p.subMax ? Math.round((p.sub || 0) / p.subMax * 100) : 0;
  var yd = st.years.filter(function(y){ return y.done; }).length;

  /* ① 主卡：四个数字、一句状态、一个主动作 */
  var h = '<div class="card" id="sysmain"><div class="kpi">'
    + '<div><b class="num" id="k-movies">' + (st.movies || 0).toLocaleString() + '</b><em>'
      + (S.src === 'tv' ? '剧集' : '影片') + '</em></div>'
    + '<div><b class="num" id="k-rels">' + (st.rels || 0).toLocaleString() + '</b><em>片源</em></div>'
    + '<div><b id="k-at">' + (st.at ? since(st.at) : '—') + '</b><em>最后更新</em></div>'
    + '<div><b class="num" id="k-years">' + yd + '/' + st.years.length + '</b><em>年份完成</em></div></div>'
    + '<div class="sysline" id="sysline">' + sysLine(st) + '</div>';
  if (st.cooling)
    h += '<div class="warnbox" id="warncool">论坛限速冷却中，还需 ' + st.cooling + ' 秒'
      + (st.coolWhy ? '（' + esc(st.coolWhy) + '）' : '') + '。任务会自己等，也可以'
      + '<button class="link" id="cool">立即清除冷却</button>。</div>';
  if (st.deaths)
    h += '<div class="warnbox" id="warndeath">上一轮任务被中断 ' + st.deaths + ' 次，已自动把每轮批量降到 1/'
      + Math.pow(2, Math.min(4, st.deaths)) + '。跑完一轮会自动恢复。</div>';
  /* 极限模式开关：默认开；跑任务时锁住（一次任务只用一种模式），服务端 TURBO=0 时灰掉 */
  var tOn = turboWanted(), tSrv = turboServerOn();
  h += '<div class="trow"><div class="tl"><b>极限模式</b><em id="tdesc"' + (RUN.on && TURBO_LIVE ? ' class="live"' : '') + '>'
    + esc(RUN.on && TURBO_LIVE ? turboLiveText(TURBO_LIVE) : turboDesc()) + '</em></div>'
    + '<button class="lg" type="button" id="turbo" role="switch" aria-checked="' + (tOn ? 'true' : 'false') + '" aria-label="极限模式"'
    + (RUN.on || !tSrv ? ' disabled' : '') + '><span class="track"></span><span class="lens"></span></button></div>';
  var allDone = st.done && !((st.pend && st.pend.wait) || 0);
  h += '<div class="row" style="margin-top:16px">'
    + (RUN.on ? '<button class="btn fixed" id="stop">停止</button>'
      : (allDone
          ? '<button class="btn on" id="inc">抓取新片</button>'
          : '<button class="btn on" id="cont">继续建立索引</button><button class="btn" id="inc">抓取新片</button>'))
    + '</div>';
  if (st.lastIncremental)
    h += '<p class="fine" style="margin-top:12px">上次抓新片：' + since(st.lastIncremental.at)
      + ' · 新增 ' + st.lastIncremental.added + ' 个片源</p>';
  h += '</div>';

  /* ② 管线 */
  h += dxHTML('pipe', '管线',
    '<span class="sub">' + (p.at ? (p.kind === 'incremental' ? '增量' : (p.kind === 'turbo' ? '极限' : '建索引')) + ' · ' + since(p.at)
        + ' · ' + ((p.ms || 0) / 1000).toFixed(1) + 's' : '还没跑过') + '</span>',
    flowHTML(st)
    + '<div class="quota"><span>子请求</span><div class="bar2" id="q-bar"><i class="'
      + (subPct > 88 ? 'bad' : '') + '" style="transform:scaleX('
      + (Math.max(2, subPct) / 100) + ')"></i></div>'
      + '<span class="num" id="q-num">' + (p.sub || 0) + ' / ' + (p.subMax || st.plan.sub) + '</span></div>'
    + sparkHTML(st)
    + '<div class="dl-meta" style="margin-top:12px">'
      + '<span>计划 <i>' + esc(st.plan.name) + '</i></span>'
      + '<span id="k-plan">' + planMetaHTML(st) + '</span>'
      + '<span>单片 <i class="num">' + st.partSize + '</i> 行</span>'
      + '<span>请求间隔 <i class="num" id="k-gap">' + (st.gap || 0) + '</i> ms</span>'
      + '<span>本机 <i>' + esc(PERF.label()) + '</i></span></div>');

  /* ③ 年份进度 */
  h += dxHTML('years', '年份进度', '<span class="sub">' + yd + ' / ' + st.years.length + ' 完成</span>',
    '<div id="yrs">' + st.years.map(yearRow).join('') + '</div>'
    + '<p class="fine" style="margin-top:10px">点一个年份可以单独从它开始建；有任务在跑时先停止。</p>');

  h += unmatchedHTML(st);
  h += libPanelHTML();
  ip.innerHTML = h;
  var tg = document.getElementById('turbo');
  if (tg) makeToggle(tg, function(on){
    TURBO_ON = on;
    try { localStorage.setItem('cvturbo', on ? '1' : '0'); } catch(e){}
    turboTick(null);
    var km = document.getElementById('k-plan');
    if (km) km.innerHTML = planMetaHTML(S.st);     // 只改这一处文字：整卡重画会把正在走的开关动画打断
  }).set(tOn, true);

  [].forEach.call(ip.querySelectorAll('.yr'), function(d){
    d.onclick = function(){ if (RUN.on){ toast('有任务在跑，先停止'); return; } runBuild(+d.dataset.y); };
  });
  var bind = function(id, fn){ var e = document.getElementById(id); if (e) e.onclick = fn; };
  bind('cont', function(){ runBuild(null); });
  bind('inc', runIncremental);
  bind('stop', function(){ RUN.stop = true; var s = document.getElementById('stop');
    s.textContent = '停止中…'; s.disabled = true; });
  bind('cool', function(){ api('/api/repair?do=cooldown')
    .then(function(){ toast('已清除冷却'); loadState(); }).catch(function(e){ toast(e.message); }); });
  bind('lscan', libScanRun);
  bind('lres', libResolveRun);
  bind('urebuild', function(){
    var b = document.getElementById('urebuild');
    if (b.dataset.sure !== '1'){
      b.dataset.sure = '1'; b.textContent = '会清空本源索引再重抓，确定？再点一次';
      setTimeout(function(){ if (b){ b.dataset.sure = ''; b.textContent = '重建' + (S.src === 'tv' ? '剧集' : '电影') + '索引'; } }, 6000);
      return;
    }
    rebuildSource(b);
  });
  bind('uretry', function(){
    var b = document.getElementById('uretry');
    if (RUN.on){ toast('有任务在跑，先停止'); return; }
    b.disabled = true; b.textContent = '重试中…';
    S.logch = 'run'; renderLogs();
    /* [v6.4] 极限模式：整批排进队列，交给认定工并行认（几分钟认完几千组）；关着就照旧一批一批认 */
    if (turboWanted()){
      api('/api/repair?do=requeueUnmatched').then(function(r){
        say('重试匹配：' + r.msg);
        if (!r.queued){ b.disabled = false; b.textContent = '重试匹配'; loadState(); return; }
        runTurbo(null);
      }).catch(function(e){ b.disabled = false; b.textContent = '重试匹配'; say('重试中断：' + e.message, 1); });
      return;
    }
    runFix('retryUnmatched', null, function(r, n){
      if (r.msg) say(r.msg);
      b.textContent = '重试中 ' + n + (r.left ? '（剩 ' + r.left + '）' : '');
    }, function(err, r){
      if (err){ b.disabled = false; b.textContent = '重试匹配'; say('重试中断：' + err.message, 1); return; }
      say('重试完成' + (r.msg ? ' · ' + r.msg : ''));
      toast('重试完成');
      pageCache = {}; pre = {};
      loadState();
    });
  });
  bind('urescan', function(){
    var b = document.getElementById('urescan');
    if (b.dataset.sure !== '1'){
      b.dataset.sure = '1';
      b.textContent = '确定要倒回游标？再点一次';
      b.classList.add('on');
      setTimeout(function(){ if (b){ b.dataset.sure = ''; b.textContent = '重扫未匹配'; b.classList.remove('on'); } }, 6000);
      return;
    }
    b.disabled = true; b.textContent = '处理中…';
    api('/api/repair?do=rescanUnmatched').then(function(r){
      S.logch = 'run'; say(r.msg); renderLogs();
      toast('已倒回游标，去点「继续建立索引」');
      loadState();
    }).catch(function(e){ b.disabled = false; b.textContent = '重扫未匹配'; say(e.message, 1); });
  });
}
/* 进度补丁：每轮任务回来只改数字、年份行、配额与状态句。
   结构变了（冷却出现 / 消失、按钮该换了）就退回整体重画。 */
function patchIndex(){
  var st = S.st, ip = document.getElementById('ip');
  if (!st || !ip || !document.getElementById('sysmain')) return false;
  if (!!st.cooling !== !!document.getElementById('warncool')) return false;
  if (!!st.deaths !== !!document.getElementById('warndeath')) return false;
  var set = function(id, v){ var e = document.getElementById(id); if (e && e.textContent !== v) e.textContent = v; };
  set('k-movies', (st.movies || 0).toLocaleString());
  set('k-rels', (st.rels || 0).toLocaleString());
  set('k-at', st.at ? since(st.at) : '—');
  var yd = st.years.filter(function(y){ return y.done; }).length;
  set('k-years', yd + '/' + st.years.length);
  set('k-gap', String(st.gap || 0));
  var sl = document.getElementById('sysline'); if (sl) sl.innerHTML = sysLine(st);
  var wc = document.getElementById('warncool');
  if (wc && st.cooling){
    var want = '论坛限速冷却中，还需 ' + st.cooling + ' 秒' + (st.coolWhy ? '（' + st.coolWhy + '）' : '') + '。任务会自己等，也可以';
    var tn = wc.firstChild; if (tn && tn.nodeType === 3 && tn.textContent !== want) tn.textContent = want;
  }
  var p = st.pipe || {}, subPct = p.subMax ? Math.round((p.sub || 0) / p.subMax * 100) : 0;
  var qb = document.querySelector('#q-bar i');
  if (qb){ qb.style.transform = 'scaleX(' + (Math.max(2, subPct) / 100) + ')'; qb.classList.toggle('bad', subPct > 88); }
  set('q-num', (p.sub || 0) + ' / ' + (p.subMax || st.plan.sub));
  st.years.forEach(function(y){
    var r = ip.querySelector('.yr[data-y="' + y.year + '"]'); if (!r) return;
    var pct = y.last ? Math.min(100, Math.round(y.page / y.last * 100)) : (y.done ? 100 : 0);
    var bar = r.querySelector('.bar2 i');
    bar.style.transform = 'scaleX(' + (pct / 100) + ')'; bar.classList.toggle('ok', !!y.done);
    var em = r.querySelector('em'), tx2 = yearText(y);
    if (em.textContent !== tx2) em.textContent = tx2;
  });
  var ysub = ip.querySelector('details[data-x="years"] summary .sub');
  if (ysub) ysub.textContent = yd + ' / ' + st.years.length + ' 完成';
  return true;
}
function planMetaHTML(st){
  return turboWanted() && st.turbo
    ? '极限 <i class="num">' + st.turbo.pages + '</i> 页 / 轮 · 认定工 <i class="num">' + st.turbo.group + '</i> 组 / 路'
    : '单轮 <i class="num">' + st.plan.pages + '</i> 页 / <i class="num">' + st.plan.tmdb + '</i> 次 TMDB';
}
/* 未匹配片名：把一个数字拆成"能修的 / 不用修的 / 修不了的" */
function unmatchedHTML(st){
  var p = st.pend;
  if (!p || !p.n) return '';
  var wn = p.wait || 0;
  var body = '<div class="kpi">'
    + '<div><b class="num">' + p.retry + '</b><em>可重试</em></div>'
    + '<div><b class="num">' + (p.tv + p.pack) + '</b><em>非电影</em></div>'
    + '<div><b class="num">' + p.dead + '</b><em>反复认不出</em></div>'
    + '<div><b class="num">' + (wn ? wn : p.n) + '</b><em>' + (wn ? '排队待认' : '留底总数') + '</em></div></div>'
    + (wn ? '<p class="fine" style="margin-top:12px">排队待认的 ' + wn + ' 组是极限模式抓下来、还没轮到认定的，'
        + '帖子行都在留底里；接着建索引（或每天的定时任务）会认完，不算认不出。</p>' : '')
    + '<p class="fine" style="margin-top:12px">'
    + '认不出来的那一组，帖子行也一起留着了 —— 重试是直接从留底里认，不用把列表页重爬一遍。'
    + '剧集 / 合集本来就不在 TMDB 电影库里，跳过是对的。'
    + '认定会依次试：中文名 + 年份、原名、英文（外语片常常没有中文译名）、拆开的别名、去掉副标题。</p>';
  /* [v6.4] 片名是乱码（UTF-8 的版块被旧版当 GBK 解了）：重试只会白花 TMDB 请求，先重建本源索引 */
  var garbled = p.gchk >= 3 && p.garbled * 2 >= p.gchk;
  if (garbled)
    body = '<div class="warnbox">抽查 ' + p.gchk + ' 条，' + p.garbled + ' 条片名是乱码：' + (S.src === 'tv' ? '剧集' : '电影')
      + '版块的页面是 UTF-8，旧版一律按 GBK 解码，「余生有你」存成了「浣欑敓鏈夊姩」，所以认不出来。'
      + '新抓的页面已经按真实编码解码；已经存进去的乱码要重建' + (S.src === 'tv' ? '剧集' : '电影') + '索引才能清掉'
      + '（会先自动备份一份；另一个源一点不动；重建完自动开始重新抓）。'
      + '<div class="row" style="margin-top:12px"><button class="btn fixed on" id="urebuild">重建' + (S.src === 'tv' ? '剧集' : '电影') + '索引</button></div></div>'
      + body;
  if (p.sample && p.sample.length)
    body += '<div class="qlist" style="max-height:160px">' + p.sample.map(function(t){
      return '<div class="qrow"><span class="dot warn"></span><span class="qn">' + esc(t) + '</span></div>';
    }).join('') + '</div>';
  body += '<div class="row" style="margin-top:14px">'
    + '<button class="btn fixed' + (p.retry && !garbled ? ' on' : '') + '" id="uretry"' + (p.retry ? '' : ' disabled') + '>'
    + '重试匹配' + (p.retry ? ' ' + p.retry + ' 组' : '') + '</button>'
    + '<button class="btn fixed" id="urescan">重扫未匹配</button></div>'
    + '<p class="fine" style="margin-top:8px">'
    + '「重扫未匹配」把年份游标倒回第 1 页重走一遍，已入库的帖子会被跳过、不会重复抓，只补漏掉的：'
    + 'v4 时期认不出来、没留底的老账，以及 v6.1 及更早版本一轮认不完时漏掉的帖子。'
    + '升级到 v6.2 之后建议跑一次（极限模式下几分钟就走完）。</p>';
  return dxHTML('pend', '未匹配片名',
    (garbled ? '<span class="pill warn">片名乱码</span>'
      : p.retry ? '<span class="pill warn">' + p.retry + ' 组可重试</span>' : '<span class="sub">' + p.n + ' 条留底</span>'),
    body);
}
function libPanelHTML(){
  var L = S.libst;
  if (!L) return dxHTML('lib', '片库对照', '<span class="sub">A/list.json</span>', '<div class="tail"><div class="spin"></div></div>');
  if (!L.host) return dxHTML('lib', '片库对照', '<span class="sub">未配置</span>', '<p class="lede">' + esc(L.hint || '未配置 RECV_BASE / STREAM_BASE') + '</p>');
  if (!L.on && L.err)
    return dxHTML('lib', '片库对照', '<span class="pill warn">拿不到片库</span>',
      '<div class="warnbox">片库拿不到，所以现在不藏任何片（库里有的也显示成缺片）：' + esc(L.err) + '</div>'
      + '<div class="row" style="margin-top:14px"><button class="btn fixed" id="lscan">重新同步片库</button></div>');
  if (L.src === 'live') return libLivePanelHTML(L);
  if (L.src === 'received') return libRecvPanelHTML(L);
  var done = (L.ids || 0) + (L.tried || 0);
  var total = done + (L.todo || 0);
  var pct = total ? Math.round(done / total * 100) : (L.ids ? 100 : 0);
  var body = '<div class="kpi">'
    + '<div><b class="num">' + (L.files || 0).toLocaleString() + '</b><em>片库文件</em></div>'
    + '<div><b class="num">' + (L.ids || 0).toLocaleString() + '</b><em>已认定 TMDB</em></div>'
    + '<div><b class="num">' + (L.tried || 0).toLocaleString() + '</b><em>认过但没有</em></div>'
    + '<div><b class="num">' + (L.todo || 0).toLocaleString() + '</b><em>待认定</em></div></div>'
    + '<div class="bar2" style="margin-top:14px"><i class="' + (L.todo ? '' : 'ok')
    + '" style="transform:scaleX(' + (Math.max(2, pct) / 100) + ')"></i></div>';
  /* 从 v4 搬过来的库：模糊键表还在，但一次 TMDB 都没认过 —— 得说清楚 */
  if (L.fresh)
    body += '<div class="warnbox">这份片库还没被 v5 认过一遍。现在只有 '
      + (L.fuzzy || 0).toLocaleString() + ' 条模糊键（按片名 + 年份猜），'
      + '所以海报上只会标「疑似已有」。点下面的<b>重新扫描片库</b>，'
      + '再跑一遍认定，就会升级成按 TMDB id 精确比对。</div>';
  body += '<p class="fine" style="margin-top:10px">'
    + esc(L.host) + ' · 扫描于 ' + (L.scan ? since(L.scan) : '从未') + ' · 认定于 ' + since(L.at) + '。'
    + '认定过的用 TMDB id 精确比对（标「库中已有」）；还没认到 id 的退回片名 + 年份'
    + '（中文名和原名都算），标「疑似已有」。'
    + (L.fuzzy ? '当前模糊兜底键 ' + (L.fuzzy || 0).toLocaleString() + ' 条，每次扫描按片库现状重算。' : '') + '</p>'
    + (L.sample && L.sample.length
        ? '<p class="fine">例如：' + esc(L.sample.join('、')) + '…</p>' : '')
    + '<div class="row" style="margin-top:14px">'
    + '<button class="btn fixed' + (L.fresh || !L.scan ? ' on' : '') + '" id="lscan">重新扫描片库</button>'
    + '<button class="btn fixed' + (L.todo ? ' on' : '') + '" id="lres"'
      + (L.todo ? '' : ' disabled') + '>'
      + (L.todo ? '认定待处理 ' + L.todo + ' 个' : (L.scan ? '已全部认定' : '先扫描一次')) + '</button></div>';
  return dxHTML('lib', '片库对照',
    (L.todo ? '<span class="pill warn">待认定 ' + L.todo + '</span>'
            : '<span class="sub">' + (L.ids || 0).toLocaleString() + ' 已认定</span>'), body);
}
/* 总账直读模式的面板。没有「待认定」这一栏 —— id 是 Stream 那边给的，
   这边一次 TMDB 都不发，所以那个按钮和那根进度条都不该出现。 */
/* [v6.3] 缺片判定的明细：id 相同 / 索引片名键 / 片名认领 / 推断两边认错 / 说不准 */
function libMatchHTML(L){
  var M = L.match;
  if (!M) return '';
  return '<p class="fine" style="margin-top:8px">索引里判为已有：id 相同 <b>' + (M.exact || 0).toLocaleString() + '</b> 部'
    + (M.key ? ' · 文件名与论坛发布名同一个片名键 <b>' + M.key.toLocaleString() + '</b> 部' : '')
    + ' · 片名 + 年份认领 <b>' + (M.name || 0).toLocaleString() + '</b> 部'
    + (M.conflict ? ' · 两边 id 不同但片名年份全同 <b>' + M.conflict + '</b> 部' : '')
    + (M.amb ? ' · <b>' + M.amb + '</b> 条库里条目对上了不止一部同名片，说不准是哪部，都不藏' : '')
    + '</p>'
    + (M.ambSample && M.ambSample.length ? '<p class="fine">说不准的例如：' + esc(M.ambSample.join('、')) + '</p>' : '');
}
/* 实时清单（Stream v25）：哪些文件在库里以它为准；总账只当「文件 → id」提示 */
function libLivePanelHTML(L){
  var ids = L.ids || 0, todo = L.todo || 0, part = L.part || 0;
  var body = '<div class="kpi">'
    + '<div><b class="num">' + (L.files || 0).toLocaleString() + '</b><em>片库文件</em></div>'
    + '<div><b class="num">' + (L.mine || 0).toLocaleString() + '</b><em>' + (S.src === 'tv' ? '剧集' : '作品') + '</em></div>'
    + '<div><b class="num">' + ids.toLocaleString() + '</b><em>带 TMDB id</em></div>'
    + '<div><b class="num">' + (todo + part).toLocaleString() + '</b><em>待认定</em></div></div>';
  body += libMatchHTML(L);
  if (todo || part)
    body += '<div class="warnbox">还有 ' + (todo + part).toLocaleString() + ' 个文件没认出 TMDB id'
      + (part ? '（其中 ' + part + ' 个还没切片名，下次同步接着切）' : '')
      + '。认出来之前先按片名 + 年份认领（标「疑似已有」）；点「认定」或等每天的定时任务把它们认完。</div>';
  body += '<p class="fine" style="margin-top:10px">'
    + '片库以 Stream v25 的实时清单为准（' + esc(L.host) + (L.via === 'r2' ? '，公开 R2 直读' : '，经 Stream 接口') + '），'
    + '清单更新于 ' + (L.liveTs ? since(L.liveTs) : '—') + '，同步于 ' + since(L.at) + '。'
    + (S.src === 'tv'
        ? '剧集的 TMDB 编号用 v25 剧集表认好的。'
        : 'TMDB 编号依次来自：总账里同一个文件的可信 id（' + (L.viaLedger || 0).toLocaleString() + ' 部'
          + (L.lts ? '，总账停在 ' + new Date(L.lts).toLocaleDateString() : '') + '）、'
          + '这边按文件名认定（' + (L.viaTmdb || 0).toLocaleString() + ' 部）；'
          + '文件名和论坛发布名一样的，查目录时直接按索引的片名键对上。')
    + '</p>'
    + '<div class="row" style="margin-top:14px">'
    + '<button class="btn fixed" id="lscan">重新同步片库</button>'
    + (todo && S.src !== 'tv' ? '<button class="btn fixed on" id="lres">认定 ' + todo + ' 个</button>' : '') + '</div>';
  return dxHTML('lib', '片库对照',
    (todo + part) ? '<span class="pill warn">' + (todo + part) + ' 个待认定</span>'
                  : '<span class="sub">' + ids.toLocaleString() + ' 部精确比对</span>', body);
}
function libRecvPanelHTML(L){
  var exact = L.ids || 0, mine = L.mine || exact, fuzzy = L.missed || 0;
  var body = '<div class="kpi">'
    + '<div><b class="num">' + (L.files || 0).toLocaleString() + '</b><em>片库文件</em></div>'
    + '<div><b class="num">' + mine.toLocaleString() + '</b><em>本源作品</em></div>'
    + '<div><b class="num">' + exact.toLocaleString() + '</b><em>带可信 TMDB id</em></div>'
    + '<div><b class="num">' + fuzzy.toLocaleString() + '</b><em>按片名 + 年份比</em></div></div>';
  /* v6 缺片检测这一轮的判定：确定 / 片名认领 / 推断两边认错 / 说不准（不藏） */
  body += libMatchHTML(L)
    + (L.distrust ? '<p class="fine"><b>' + L.distrust + '</b> 条 Stream 给的 id 与文件名的年份 / 名字对不上，判为认错，按片名比</p>' : '');
  /* [v6.3] 总账是 Stream v22 写的，v25 不再更新：停了几天以上就明说，之后进库的片会显示成缺片 */
  if (L.recvTs && Date.now() - L.recvTs > 3 * 86400e3)
    body += '<div class="warnbox">总账停在 ' + new Date(L.recvTs).toLocaleDateString() + '（' + since(L.recvTs) + '）。'
      + 'Stream v25 不再更新它，之后进库的片都会显示成缺片。'
      + (L.liveOn ? '实时清单这次没拿到：把 Stream 的 R2 桶（FILE_CACHE）挂在 RECV_BASE 这个域名上，或者给索引库配 STREAM_KEY（= Stream 的 AUTH_SECRET）。'
                  : '配 RECV_BASE（Stream 的 R2 桶的公开域名）或 STREAM_BASE + STREAM_KEY，改用实时清单。')
      + '</div>';
  if (L.pending)
    body += '<div class="warnbox">Stream 那边还有 ' + L.pending.toLocaleString()
      + ' 部没轮到匹配 TMDB。它们这会儿只能按片名 + 年份猜（标「疑似已有」），'
      + '等那边跑完，这里下次同步自动升级成精确比对 —— 这边不用做任何事。</div>';
  body += '<p class="fine" style="margin-top:10px">'
    + esc(L.host) + (L.via === 'r2' ? '（公开 R2 直读）' : '（经 Stream）')
    + ' · 同步于 ' + since(L.at) + ' · 内容指纹 <code>' + esc(L.gen || '—') + '</code>。'
    + 'TMDB 编号由 Stream 在写入时算好，这边取回来直接比 id —— 一次 TMDB 请求都不发。'
    + '没有可信 id 的那些按片名 + 年份认领索引里的一部片（繁简、全角、罗马数字都对得上；同名多部时取年份最贴近的那部，并列就不认），标「疑似已有」。</p>'
    + (L.sample && L.sample.length
        ? '<p class="fine">例如：' + esc(L.sample.join('、')) + '…</p>' : '')
    + '<div class="row" style="margin-top:14px">'
    + '<button class="btn fixed" id="lscan">重新同步总账</button></div>';
  return dxHTML('lib', '片库对照',
    '<span class="sub">' + exact.toLocaleString() + ' 部精确比对</span>', body);
}
function libScanRun(){
  var b = document.getElementById('lscan');
  var recv = S.libst && S.libst.src === 'received';
  if (b){ b.disabled = true; b.textContent = recv ? '同步中…' : '扫描中…'; }
  api('/api/lib?scan=1').then(function(r){
    S.libst = r; pageCache = {};
    if (r.mode === 'live'){
      say('片库同步：' + r.files + ' 个文件 → ' + r.cands + ' 部 · ' + (r.ok || 0) + ' 部带 TMDB id'
        + (r.part ? ' · 还有 ' + r.part + ' 个文件没切片名，接着同步' : '') + (r.left ? ' · 待认定 ' + r.left : ''));
      renderIndex();
      if (r.part){ setTimeout(libScanRun, 1300); return; }
      if (r.left){ libResolveRun(); return; }
      toast('片库对照已同步');
      return;
    }
    if (r.mode === 'received'){
      say('总账同步：片库 ' + r.files + ' 个文件 → 本源 ' + r.cands + ' 部 · '
        + (r.ok || 0) + ' 部带 TMDB id' + (r.tried ? ' · ' + r.tried + ' 部只能模糊比' : ''));
      renderIndex();
      toast('片库对照已同步');
      return;                                  /* 没有认定这一步 */
    }
    say('片库扫描：' + r.files + ' 个文件 → ' + r.cands + ' 部片'
      + (r.dropped ? ' · 清掉已不在库里的 ' + r.dropped : '') + ' · 待认定 ' + r.left);
    renderIndex();
    if (r.left) libResolveRun();
  }).catch(function(e){ say((recv ? '总账同步失败：' : '片库扫描失败：') + e.message, 1); renderIndex(); });
}
/* 认定是分批的：一批用掉多少子请求由服务端预算决定，left>0 就接着调 */
function libResolveRun(){
  var b = document.getElementById('lres');
  if (b){ b.disabled = true; b.textContent = '认定中…'; }
  var rounds = 0;
  (function step(){
    api('/api/lib?resolve=1').then(function(r){
      rounds++;
      S.libst = r;
      say('认定第 ' + rounds + ' 批 · 命中 ' + (r.added || 0)
        + (r.missed ? ' · 认不出 ' + r.missed : '') + ' · 还剩 ' + r.left);
      renderIndex();
      /* R2 对同一个对象的写入频率有硬限制，催太急会直接被拒。
         每一轮服务端会给出建议间隔，照做即可。 */
      if (r.left > 0 && rounds < 400){ setTimeout(step, Math.max(400, r.wait || 900)); return; }
      pageCache = {};
      say('片库认定完成：' + (r.ids || 0) + ' 部已用 TMDB id 精确比对');
      toast('片库认定完成');
    }).catch(function(e){
      var m = e.message || String(e);
      if (/10058|concurrent request rate|限流/i.test(m)){
        /* 写得太密被 R2 挡了一下。不是错误，等一等接着认就是了。 */
        say('R2 提示写入太密，等 3 秒接着认…');
        setTimeout(step, 3000); return;
      }
      say('认定中断：' + m, 1); renderIndex();
    });
  })();
}

/* ── 日志（分频道） ── */
var LOGCH = [['run','运行'],['pipe','管线'],['net','网络'],['match','匹配'],['lib','片库'],['sys','系统']];
function loadLogs(){
  api('/api/logs?ch=all&n=140&saved=1').then(function(j){
    S.logs = j; if (S.view === 'idx') renderLogs();
  }).catch(function(){ if (S.view === 'idx') renderLogs(); });
}
function runRowHTML(x){
  return '<div class="lrow' + (x.bad ? ' err' : '') + '"><span class="lt">'
    + new Date(x.at).toTimeString().slice(0,8) + '</span>'
    + '<span class="lm">' + esc(x.m) + '</span></div>';
}
function renderLogs(){
  var box = document.getElementById('lg'); if (!box) return;
  var j = S.logs || { live:[], ch:[] };
  var cnt = {}; (j.ch || []).forEach(function(c){ cnt[c.k] = c.n; });
  cnt.run = RUN.log.length;
  var rows;
  if (S.logch === 'run'){
    rows = RUN.log.map(runRowHTML);
  } else {
    var live = (j.live || []).filter(function(x){ return x.ch === S.logch; });
    rows = live.map(function(x){
      return '<div class="lrow ' + esc(x.lvl) + '"><span class="lt">'
        + new Date(x.at).toTimeString().slice(0,8) + '</span>'
        + '<span class="lm">' + esc(x.msg) + '</span>'
        + '<span class="lc">' + esc(x.kind) + '</span></div>';
    });
  }
  var body = '<div class="logtabs">' + LOGCH.map(function(c){
        return '<button data-c="' + c[0] + '"' + (S.logch === c[0] ? ' class="on"' : '') + '>'
          + c[1] + '<i>' + (cnt[c[0]] || '') + '</i></button>';
      }).join('') + '</div>'
    + '<div class="logs" id="logrows">' + (rows.length ? rows.join('')
        : '<p class="lede" style="padding:22px 0;text-align:center">这一频道暂时没有记录</p>') + '</div>';
  if (S.logch !== 'run' && j.saved && j.saved.length)
    body += '<div class="hd" style="margin:18px 0 8px"><h2 class="sec" style="font-size:15px">留档事件</h2>'
      + '<span class="sub">重启也还在</span></div><div class="logs" style="max-height:180px">'
      + j.saved.map(function(x){
          return '<div class="lrow ' + esc(x.lvl) + '"><span class="lt">'
            + new Date(x.at).toTimeString().slice(0,8) + '</span>'
            + '<span class="lm">' + esc(x.msg) + '</span></div>';
        }).join('') + '</div>';
  /* 展开状态跟着 details 走；正在跑任务时自动展开，别让人找 */
  if (RUN.on && !DX.logs){ DX.logs = true; dxSave(); }
  box.innerHTML = dxHTML('logs', '日志',
    '<button class="link" id="lgr">刷新</button>' + (S.logch === 'run' && RUN.on ? '<span class="pill ok"><span class="dot live"></span>运行中</span>' : ''), body);
  [].forEach.call(box.querySelectorAll('[data-c]'), function(b){
    b.onclick = function(){ S.logch = b.dataset.c; renderLogs(); };
  });
  var r = document.getElementById('lgr');
  if (r) r.onclick = function(ev){ ev.preventDefault(); ev.stopPropagation(); r.textContent = '刷新中…'; loadLogs(); };
}
/* 运行频道的日志逐条前插，不整段重画：一轮一条，几百轮也不卡 */
function say(msg, bad){
  var x = { m:msg, bad:bad, at:Date.now() };
  RUN.log.unshift(x);
  if (RUN.log.length > 120) RUN.log.length = 120;
  if (S.view !== 'idx' || S.logch !== 'run') return;
  var rows = document.getElementById('logrows');
  if (!rows || !document.querySelector('#lg [data-c="run"]')){ renderLogs(); return; }
  var ph = rows.querySelector('p'); if (ph) ph.remove();
  rows.insertAdjacentHTML('afterbegin', runRowHTML(x));
  while (rows.children.length > 120) rows.lastElementChild.remove();
  var tab = document.querySelector('#lg [data-c="run"] i'); if (tab) tab.textContent = RUN.log.length;
}
function applyProgress(r){
  if (!S.st) return;
  var y = S.st.years.filter(function(x){ return x.year === r.year; })[0];
  if (y){ y.page = r.page; y.last = r.last || y.last; y.done = !!r.done; y.bad = r.bad || 0; }
  if (r.movies != null) S.st.movies = r.movies;
  if (r.rels != null) S.st.rels = r.rels;
  if (r.gap != null) S.st.gap = r.gap;
  if (r.cooling != null) S.st.cooling = r.cooling;
  if (r.degraded != null) S.st.deaths = r.degraded;
  if (r.sub != null){
    if (!S.st.pipe) S.st.pipe = {};
    S.st.pipe.sub = r.sub; S.st.pipe.subMax = r.subMax;
  }
  S.st.at = Date.now();
  if (!patchIndex()) renderIndex();
}
/*<turbo>*/
/* ══════════════════════════════════════════════════════════════════
   极限模式调度（浏览器这一侧）
   ──────────────────────────────────────────────────────────────────
   一条扫描线（/api/build?turbo=1：持锁、一轮接一轮、只抓列表）+ 几路认定工
   （/api/tm：并发、不持锁、各自一整份子请求配额）。认定工的结果先攒在这里，
   随下一轮扫描交上去写进分片。
     · 并发 AIMD：连着两批顺利就 +1（上限 6 路）；挨了 429、或一批里三成以上没回来，
       就减半并歇 2.5 秒；
     · 没回来的键 15 秒内不再派（服务端下一轮还会把它列进 need，不会漏）；
     · 列表抓完（或排队太长先停抓）之后，扫描线等认定结果攒够了才发下一轮 ——
       没东西可写的轮次只是白写一遍 R2；
     · 停止：不再派新活，等手上的认定工回来（最多 8 秒），把攒着的结果交上去
       （pages=0 的收尾轮）再停。没交上去的也不丢：条目一直在服务端的留底队列里。
   这一段不碰 DOM，依赖全部从 o 传进来 —— 测试里拿真 Worker 跑的就是这一份代码。
   ══════════════════════════════════════════════════════════════════ */
function turboRun(o){
  var T = { K: 3, KMAX: 6, G: 20, H: 240, act: 0, q: [], inQ: {}, fly: {}, nfly: 0, hits: {}, nhits: 0,
            later: {}, pause: 0, okRun: 0, rounds: 0, idle: 0, off: false, ended: false, stopping: false,
            stopAt: 0, flushN: 0, matched: 0, missed: 0, waitN: 0, roundOn: false, waitHits: false, since: 0,
            busyN: 0, errN: 0, autoReset: 0 };
  var now = o.now || function(){ return Date.now(); };
  var say = o.say || function(){};
  function stat(){
    return { K: T.K, act: T.act, fly: T.nfly, queue: T.q.length, hits: T.nhits, matched: T.matched,
             missed: T.missed, rounds: T.rounds, waitN: T.waitN, off: T.off };
  }
  function tick(){ if (o.tick) o.tick(stat()); }
  function end(msg, bad){ if (T.ended) return; T.ended = true; T.waitHits = false; o.done(msg, bad, stat()); }
  function stopped(){ return !!(o.stopped && o.stopped()); }

  function enqueue(list){
    if (T.off) return;                   // 没有认定工可用：键不在这边扣着，服务端的扫描轮自己认
    var t = now();
    for (var i = 0; i < (list || []).length; i++){
      var g = list[i];
      if (!g || typeof g.k !== 'string') continue;
      var k = g.k;
      if (T.inQ[k] || T.fly[k] || T.hits[k] || (T.later[k] && T.later[k] > t)) continue;
      T.inQ[k] = 1; T.q.push(g);
    }
  }
  function pump(){
    if (T.off || T.stopping || T.ended || stopped()) return;
    var t = now();
    if (t < T.pause){ o.later(pump, T.pause - t + 5); return; }
    while (T.act < T.K && T.q.length) fire(T.q.splice(0, T.G));
  }
  function fire(batch){
    for (var i = 0; i < batch.length; i++){ delete T.inQ[batch[i].k]; T.fly[batch[i].k] = 1; T.nfly++; }
    T.act++;
    o.api('/api/tm', { method: 'POST', body: JSON.stringify({ g: batch }) }).then(function(r){
      var t = now(), nul = 0;
      for (var i = 0; i < batch.length; i++){
        var k = batch[i].k, v = r && r.r ? r.r[k] : null;
        if (T.fly[k]){ delete T.fly[k]; T.nfly--; }
        if (v && (v.h || typeof v.m === 'string')){
          if (!T.hits[k]){ T.hits[k] = v; T.nhits++; }
          if (v.h) T.matched++; else T.missed++;
        } else { nul++; T.later[k] = t + 15000; }
      }
      if (r && r.g) T.G = r.g;
      if ((r && r.n429) || nul * 3 > batch.length){ T.K = Math.max(1, T.K >> 1); T.pause = t + 2500; T.okRun = 0; }
      else if (++T.okRun >= 2){ T.K = Math.min(T.KMAX, T.K + 1); T.okRun = 0; }
    }, function(e){
      var t = now();
      for (var i = 0; i < batch.length; i++){
        var k = batch[i].k;
        if (T.fly[k]){ delete T.fly[k]; T.nfly--; }
        T.later[k] = t + 10000;
      }
      if (e && e.status === 403 && e.data && e.data.off){
        if (!T.off) say('服务端关掉了认定工（TURBO=0），改由扫描轮自己认');
        T.off = true;
        for (var j = 0; j < T.q.length; j++) delete T.inQ[T.q[j].k];
        T.q.length = 0;
      } else { T.K = Math.max(1, T.K >> 1); T.pause = t + 3000; T.okRun = 0; }
    }).then(fin, fin);
    function fin(){ T.act--; tick(); kick(); pump(); }
  }

  /* 扫描线的节拍：needHits = 这一轮没抓列表，下一轮等认定结果攒够（40 条）、或手上没活了、或 4 秒到了再发 */
  function ready(){
    return stopped() || T.nhits >= Math.min(T.H, 40) || (!T.nfly && !T.q.length && !T.act) || now() - T.since > 4000;
  }
  function next(ms, needHits){
    if (T.ended) return;
    if (!needHits){ o.later(round, ms || 0); return; }
    T.waitHits = true; T.since = now();
    o.later(poll, Math.max(250, ms || 0));
  }
  function poll(){
    if (!T.waitHits || T.ended) return;
    if (ready()){ T.waitHits = false; round(); } else o.later(poll, 250);
  }
  function kick(){ if (T.waitHits && !T.ended && ready()){ T.waitHits = false; round(); } }

  function round(){
    if (T.ended || T.roundOn) return;
    if (stopped() && !T.stopping){ T.stopping = true; T.stopAt = now(); }
    if (T.stopping){
      if (T.nfly && now() - T.stopAt < 8000){ o.later(round, 300); return; }
      if (!T.nhits) return end('已停止，进度已保存');
    }
    T.roundOn = true;
    var hk = Object.keys(T.hits).slice(0, T.H), hits = [];
    for (var i = 0; i < hk.length; i++) hits.push([hk[i], T.hits[hk[i]]]);
    var fly = Object.keys(T.fly).concat(Object.keys(T.inQ));
    if (fly.length > 3000) fly.length = 3000;
    var url = '/api/build?turbo=1' + (o.year ? '&year=' + o.year : '') + (T.stopping ? '&pages=0' : '');
    o.api(url, { method: 'POST', body: JSON.stringify({ hits: hits, fly: fly, solo: T.off ? 1 : 0 }) }).then(function(r){
      T.roundOn = false;
      try { onRound(r); } catch (x){ end('调度出错：' + (x && x.message || x), 1); }
    }, function(e){ T.roundOn = false; onErr(e); });
  }
  function onRound(r){
      T.rounds++; T.busyN = 0; T.errN = 0;
      if (r.turbo === 0){ T.ended = true; if (o.fallback) o.fallback(r); else o.done('服务端关闭了极限模式', 1, stat()); return; }
      var gone = (r.ack || []).concat(r.rej || []);
      for (var i = 0; i < gone.length; i++) if (T.hits[gone[i]]){ delete T.hits[gone[i]]; T.nhits--; }
      for (i = 0; i < (r.rej || []).length; i++) T.later[r.rej[i]] = now() + 15000;
      if (r.g) T.G = r.g;
      if (r.h) T.H = r.h;
      T.waitN = r.waitN || 0;
      enqueue(r.need);
      pump();
      if (o.progress) o.progress(r, stat());
      if (T.stopping){
        if (T.nhits && ++T.flushN < 3) return next(r.wait || 600, false);
        return end('已停止，进度已保存');
      }
      var moved = (r.attached || 0) + (r.applied || 0) + (r.appliedMiss || 0) + (r.queued || 0) + (r.advanced || 0) + (r.drained || 0);
      if (moved || T.nfly || T.nhits || T.q.length || T.act || r.cooling || r.rateHit || r.budgetHit) T.idle = 0;
      else if (++T.idle >= 4) return end('连续 4 轮没有进展，先停下' + (T.waitN ? '（还有 ' + T.waitN + ' 组在排队，下次会接着认）' : ''), T.waitN > 0);
      if (r.done && !T.waitN && !T.nhits && !T.nfly && !T.q.length && !T.act) return end('完成');
      if (r.cooling && !T.nhits && !T.nfly && !T.q.length && !T.act)
        return next(Math.max(r.wait || 0, r.cooling * 1000 + 800), false);
      next(r.wait || 0, !!(r.done || r.backlog || !r.pages));
  }

  /* 出错的那一轮交上去的结果没被确认，留在手上下一轮再交（服务端写入是幂等的） */
  function onErr(e){
    var d = (e && e.data) || {};
    if (d.busy){
      if (++T.busyN > 20){ say('等待超时，自动重置任务锁后再试', 1); return resetGo(); }
      say('后台任务运行中，' + (d.wait || 3) + ' 秒后重试（第 ' + T.busyN + ' 次）');
      return next((d.wait || 3) * 1000 + 700, false);
    }
    if (d.budget){ say('本轮子请求配额用尽，已保存进度，继续下一轮'); return next(600, false); }
    if (d.cooling || e.status === 429){
      var sec = d.cooling || 10;
      say('被论坛限速，冷却 ' + sec + ' 秒'); return next(sec * 1000 + 800, false);
    }
    if (e.timeout || e.status === 524 || e.status === 504 || e.status === 503){
      if (++T.errN > 6) return end('连续超时 6 次，先停下。稍后再点「继续建立索引」。', 1);
      say('本轮超时（第 ' + T.errN + ' 次），服务端会自动降批量后重试');
      return next(3000, false);
    }
    if (e.status === 0){
      if (++T.errN > 6) return end('网络持续不可用，先停下。', 1);
      say('网络不可用，5 秒后重试（第 ' + T.errN + ' 次）'); return next(5000, false);
    }
    if (!T.autoReset && /空响应|限速|拦截|不是 JSON/.test(e.message || '')){ T.autoReset = 1; return resetGo(); }
    end(e.message || String(e), 1);
  }
  function resetGo(){
    o.api('/api/repair?do=resetTask').then(function(){
      say('已自动重置任务锁与降级计数，10 秒后继续'); T.busyN = 0; next(10000, false);
    }, function(err){ end('自动重置失败：' + (err && err.message || err), 1); });
  }

  round();
  return { stat: stat };
}
/*</turbo>*/

/* ── 极限模式开关：Transfer 的 Liquid Glass 开关 ──
   位置走几何弹簧（k=150 c=17.5 m=.85 → ζ≈0.78，过冲约 2%），材质走独立的 520ms 时钟。
   弹簧定步长子迭代：60fps 直接积分时 ω0·dt≈0.22，欧拉法的数值阻尼会把这 2% 吃干净。 */
function makeToggle(el, onchange){
  var lens = el.querySelector('.lens');
  function clamp(v, a, b){ return Math.max(a, Math.min(b, v)); }
  function smooth(x){ x = clamp(x, 0, 1); return x * x * (3 - 2 * x); }
  function smoothstep(a, b, x){ return smooth((x - a) / (b - a)); }
  function easeOut(x){ return 1 - Math.pow(1 - clamp(x, 0, 1), 3); }
  var PEAK = .26, K = 150, C = 17.5, M = .85, H = 1 / 240, DUR = 520;
  /* 膨胀脉冲：起手极快涨满，中段撑住，末段才塌回去 */
  function bulge(t){ return t < PEAK ? smooth(t / PEAK) : smooth(1 - Math.pow((t - PEAK) / (1 - PEAK), 1.7)); }
  var s0 = 0, v = 0, target = 0, t0 = 0, raf = 0, last = 0, acc = 0, settled = true;
  var TW = 0, TH, INSET, THW, THH, MAXW, cOff, cOn;
  function measure(){
    var cs = getComputedStyle(el);
    TW = parseFloat(cs.width); TH = parseFloat(cs.height);
    if (!TW) return false;
    INSET = TH * .094; THW = TW * .536; THH = TH - INSET * 2;
    MAXW = TW * .93; cOff = INSET + THW / 2; cOn = TW - INSET - THW / 2;
    return true;
  }
  function render(){
    if (!TW && !measure()) return;
    var prog = easeOut(clamp((performance.now() - t0) / DUR, 0, 1));
    var b = settled ? 0 : bulge(prog);
    var cx = cOff + s0 * (cOn - cOff), lw = THW + b * (MAXW - THW), lh = THH * (1 + .36 * b);
    lens.style.width = lw.toFixed(2) + 'px';
    lens.style.height = lh.toFixed(2) + 'px';
    lens.style.transform = 'translate3d(' + (cx - lw / 2).toFixed(2) + 'px,' + (INSET - (lh - THH) / 2).toFixed(2) + 'px,0)';
    el.style.setProperty('--b', (b * 13).toFixed(2) + 'px');
    el.style.setProperty('--a', (1 - b * .74).toFixed(3));
    el.style.setProperty('--sh', b.toFixed(3));
    el.style.setProperty('--gp', (-16 + smoothstep(.02, .62, s0) * (TW + 32)).toFixed(2) + 'px');
  }
  function frame(t){
    acc += Math.min(.032, (t - last) / 1000); last = t;
    while (acc >= H){ v += (-K * (s0 - target) - C * v) / M * H; s0 += v * H; acc -= H; }
    render();
    if (Math.abs(s0 - target) < .0015 && Math.abs(v) < .02 && t - t0 >= DUR){
      s0 = target; v = 0; raf = 0; settled = true; render(); return;
    }
    raf = requestAnimationFrame(frame);
  }
  function apply(on, quiet){
    target = on ? 1 : 0;
    el.setAttribute('aria-checked', on ? 'true' : 'false');
    if (quiet || PERF.reduce){                         // 初值 / 减少动效：直接落位，不跑弹簧
      if (raf){ cancelAnimationFrame(raf); raf = 0; }
      s0 = target; v = 0; settled = true; render(); return;
    }
    t0 = performance.now(); settled = false;
    if (!raf){ last = performance.now(); acc = 0; raf = requestAnimationFrame(frame); }
  }
  el.addEventListener('click', function(){
    if (el.disabled) return;
    apply(target !== 1);
    if (onchange) onchange(target === 1);
  });
  measure(); render();
  return { set: function(on, quiet){ apply(on, quiet); } };
}

/* ── 极限模式：开关状态（本机记住）与运行时的那一行 ── */
var TURBO_ON = (function(){ try { return localStorage.getItem('cvturbo') !== '0'; } catch(e){ return true; } })();
var TURBO_LIVE = null;
function turboServerOn(){ return !(S.st && S.st.turbo && S.st.turbo.on === false); }
function turboWanted(){ return TURBO_ON && turboServerOn(); }
function turboDesc(){
  if (!turboServerOn()) return '服务端已关闭（TURBO=0），用普通模式';
  var t = S.st && S.st.turbo;
  return TURBO_ON
    ? '单轮 ' + (t ? t.pages : 12) + ' 页并发抓 · 认定工最多 6 路并行 · 轮间不歇；被限速自动放慢'
    : '已关闭：每轮 3 页、当场认定，轮间歇 0.26 秒';
}
function turboLiveText(t){
  return '认定工 ' + t.K + ' 路 · 在认 ' + t.fly + ' · 待派 ' + t.queue + ' · 待写入 ' + t.hits
    + ' · 已认下 ' + t.matched.toLocaleString() + ' 部' + (t.waitN ? ' · 服务端排队 ' + t.waitN : '');
}
function turboTick(t){
  TURBO_LIVE = t;
  var e = document.getElementById('tdesc');
  if (!e) return;
  var txt = t ? turboLiveText(t) : turboDesc();
  if (e.textContent !== txt) e.textContent = txt;
  e.classList.toggle('live', !!t);
}
function turboLine(r, t){
  return (r.year ? r.year + ' 年 · 第 ' + r.page + '/' + (r.last || '?') + ' 页' : '认排队的条目')
    + ' · 新帖 ' + (r.fresh || 0) + ' · 入库 ' + (r.attached || 0) + ' · 新片 ' + (r.matchedNew || 0)
    + (r.applied ? ' · 认回 ' + r.applied : '')
    + ' · 排队 ' + (r.waitN || 0)
    + (r.backlog ? ' · 排队太长，先停抓' : '') + (r.full ? ' · 留底队列快满，改为当场认' : '')
    + (r.cooling ? ' · 论坛冷却 ' + r.cooling + 's' : '')
    + (r.rateHit ? ' · 被限速' : '') + (r.failed ? ' · 失败 ' + r.failed : '')
    + ' · 认定工 ' + t.K + ' 路'
    + ' · 子请求 ' + r.sub + '/' + r.subMax
    + ' · ' + ((r.ms || 0) / 1000).toFixed(1) + 's';
}
function runTurbo(year){
  RUN.on = true; RUN.stop = false; RUN.mode = 'turbo'; RUN.log = [];
  S.logch = 'run'; DX.pipe = true; dxSave();
  say((year ? '开始建立 ' + year + ' 年' : '开始继续建立索引') + '（极限模式）…');
  renderIndex(); renderLogs();
  var src0 = S.src;
  turboRun({
    year: year,
    api: function(u, opt){ opt = opt || {}; opt.src = src0; return api(u, opt); },   // 钉住源：中途换源也不会把结果写进另一套索引
    later: function(fn, ms){ return setTimeout(fn, ms); },
    stopped: function(){ return RUN.stop || S.src !== src0; },
    say: say,
    tick: turboTick,
    progress: function(r, t){ say(turboLine(r, t)); applyProgress(r); turboTick(t); },
    fallback: function(){
      say('服务端关闭了极限模式（TURBO=0），改用普通模式接着建');
      if (S.st && S.st.turbo) S.st.turbo.on = false;
      RUN.on = false; runBuild(year);
    },
    done: function(msg, bad){ say(msg, bad); TURBO_LIVE = null; finish(); },
  });
}

function finish(){
  RUN.on = false; RUN.stop = false; RUN.mode = null;
  pageCache = {}; pre = {};
  loadState(); loadLogs();
}
/**
 * 建索引循环。会卡住要人工干预的地方全在这儿收口：
 *   · 409 忙   → 按服务端给的 lockLeft 精确等
 *   · 残留锁   → 自动 resetTask
 *   · 429 冷却 → 按 cooling 秒数睡，睡醒接着跑
 *   · 503 预算 → 这一轮的子请求配额用完了，属于正常收工，立刻起下一轮
 *   · 超时     → 服务端会自动降批量，前端隔几秒再来；连着六次才停
 */
function runBuild(year){
  if (RUN.on) return;
  if (turboWanted()) return runTurbo(year);
  RUN.on = true; RUN.stop = false; RUN.mode = 'build'; RUN.log = [];
  S.logch = 'run'; DX.pipe = true; dxSave();
  say(year ? ('开始建立 ' + year + ' 年…') : '开始继续建立索引…');
  renderIndex(); renderLogs();
  var idle = 0, waits = 0, timeouts = 0, autoReset = 0, src0 = S.src;

  function resetAndGo(loop){
    api('/api/repair?do=resetTask').then(function(){
      say('已自动重置任务锁与降级计数，10 秒后继续');
      waits = 0; loop(10000);
    }).catch(function(err){ say('自动重置失败：' + err.message, 1); finish(); });
  }

  (function loop(delay){
    if (RUN.stop || S.src !== src0){ say('已停止，进度已保存'); finish(); return; }
    setTimeout(function(){
      if (RUN.stop || S.src !== src0){ say('已停止，进度已保存'); finish(); return; }
      api('/api/build' + (year ? '?year=' + year : '')).then(function(r){
        waits = 0; timeouts = 0;
        if (r.cooling){
          say('论坛限速冷却，等 ' + r.cooling + ' 秒后继续');
          applyProgress(r); loop(r.cooling * 1000 + 800); return;
        }
        if (r.msg && !r.year){ say(r.msg); finish(); return; }
        say((r.year ? r.year + ' 年 · 第 ' + r.page + '/' + (r.last || '?') + ' 页' : '认排队的条目（还剩 ' + (r.waitN || 0) + ' 组）')
          + ' · 新帖 ' + r.fresh + ' · 入库 ' + r.attached + ' · 新片 ' + r.matchedNew + ' · 命中 ' + r.cached
          + (r.pending ? ' · 待重试 ' + r.pending : '')
          + (r.budgetHit ? ' · 配额收工' : '')
          + (r.rateHit ? ' · 被限速' : '')
          + (r.failed ? ' · 失败 ' + r.failed : '')
          + ' · 子请求 ' + r.sub + '/' + r.subMax
          + ' · ' + (r.ms / 1000).toFixed(1) + 's');
        applyProgress(r);
        if (r.fresh === 0 && r.attached === 0 && !r.rateHit && !r.budgetHit){
          if (++idle >= 3){ say('连续 3 轮无新增，停止'); finish(); return; }
        } else idle = 0;
        if (r.done){ say('完成'); finish(); return; }
        loop(r.rateHit ? 4000 : 260);
      }).catch(function(e){
        var d = e.data || {};
        if (d.busy){
          if (++waits > 20){ say('等待超时，自动重置任务锁后再试', 1); resetAndGo(loop); return; }
          say('后台任务运行中，' + (d.wait || 3) + ' 秒后重试（第 ' + waits + ' 次）');
          loop((d.wait || 3) * 1000 + 700); return;
        }
        if (d.budget){ say('本轮子请求配额用尽，已保存进度，继续下一轮'); loop(600); return; }
        if (d.cooling || e.status === 429){
          var sec = d.cooling || 10;
          say('被论坛限速，冷却 ' + sec + ' 秒'); loop(sec * 1000 + 800); return;
        }
        if (e.timeout || e.status === 524 || e.status === 504 || e.status === 503){
          if (++timeouts > 6){ say('连续超时 6 次，先停下。稍后再点「继续建立索引」。', 1); finish(); return; }
          say('本轮超时（第 ' + timeouts + ' 次），服务端会自动降批量后重试');
          loop(3000); return;
        }
        if (e.status === 0){
          /* 网络断了：等一等再试，不算失败 */
          if (++timeouts > 6){ say('网络持续不可用，先停下。', 1); finish(); return; }
          say('网络不可用，5 秒后重试（第 ' + timeouts + ' 次）'); loop(5000); return;
        }
        say(e.message, 1);
        if (!autoReset && /空响应|限速|拦截|不是 JSON/.test(e.message)){
          autoReset = 1; resetAndGo(loop); return;
        }
        finish();
      });
    }, delay || 0);
  })(0);
}
function runIncremental(){
  if (RUN.on) return;
  RUN.on = true; RUN.stop = false; RUN.mode = 'inc'; RUN.log = []; S.logch = 'run';
  say('正在扫描近三年新帖…');
  renderIndex(); renderLogs();
  api('/api/incremental').then(function(r){
    if (r.cooling){ say('论坛限速冷却中，' + r.cooling + ' 秒后再试', 1); finish(); return; }
    say('完成 · 新增片源 ' + r.added + ' · TMDB 调用 ' + r.calls
      + (r.failed ? ' · 失败 ' + r.failed : '')
      + (r.budgetHit ? ' · 配额收工（再点一次可继续）' : '')
      + ' · 子请求 ' + r.sub + '/' + r.subMax
      + ' · 累计 ' + r.movies + ' 部 · ' + (r.ms / 1000).toFixed(1) + 's');
    if (!r.added) say('没有发现新帖');
    finish();
  }).catch(function(e){
    var d = e.data || {};
    say(d.busy ? ('后台任务运行中，' + (d.wait || 3) + ' 秒后再试') : e.message, 1);
    finish();
  });
}

/* ── 体检 ── */
var FIXNAME = { unlock:'强制解锁', resetTask:'重置任务', cooldown:'清除冷却', relogin:'重新登录',
  prune:'清理孤儿', resync:'重算汇总', retryUnmatched:'重试匹配', rescanUnmatched:'重扫未匹配',
  optimize:'重训码本', migrate:'从 v3 迁移', build:'去建索引', split:'拆分大片', libscan:'重新扫描片库',
  restore:'从备份恢复', backup:'立即备份', rebuildSource:'重建本源索引' };
/* [v6.4] 重建本源索引：服务端先备份、再清空，然后用当前模式（默认极限）从第 1 页重抓 */
function rebuildSource(btn){
  if (RUN.on){ toast('有任务在跑，先停止'); return; }
  if (btn){ btn.disabled = true; btn.textContent = '重建中…'; }
  S.logch = 'run';
  api('/api/repair?do=rebuildSource').then(function(r){
    say(r.msg || '已清空，开始重抓');
    pageCache = {}; pre = {};
    runBuild(null);
  }).catch(function(e){
    if (btn){ btn.disabled = false; btn.textContent = '重建失败'; }
    say('重建没做成：' + e.message, 1); toast(e.message);
  });
}
function runFix(act, arg, onStep, done){
  var url = '/api/repair?do=' + encodeURIComponent(act) + (arg ? '&year=' + encodeURIComponent(arg) : '');
  var n = 0;
  (function step(){
    api(url).then(function(r){
      n++; if (onStep) onStep(r, n);
      var more = (r.left > 0) || (r.done === false && r.left !== 0);
      if (more && n < 200){ setTimeout(step, Math.max(300, r.wait || 600)); return; }
      done(null, r, n);
    }).catch(function(e){ done(e); });
  })();
}
function runDiagnose(btn){
  var box = document.getElementById('dgbox');
  if (btn){ btn.disabled = true; btn.textContent = '体检中…'; }
  if (box) box.innerHTML = '<div class="tail"><div class="spin"></div></div>';
  api('/api/diagnose').then(function(d){
    if (btn){ btn.disabled = false; btn.textContent = '体检'; }
    if (!box) return;
    var h = '<div class="hd" style="margin:16px 0 6px"><h2 class="sec" style="font-size:15px">体检结果</h2><span class="sub">'
      + d.checks.length + ' 项 · ' + since(d.at) + '</span></div>';
    h += d.checks.map(function(c){
      return '<div class="dg"><span class="dot ' + esc(c.level) + '"></span>'
        + '<div style="flex:1;min-width:0"><div class="nm">' + esc(c.name) + '</div>'
        + '<div class="dt">' + esc(c.detail || '') + '</div></div>'
        + (c.fix ? '<button class="btn sm fixed fx" data-fix="' + esc(c.fix) + '"'
            + (c.arg ? ' data-arg="' + esc(c.arg) + '"' : '') + '>'
            + esc(FIXNAME[c.fix] || c.fix) + '</button>' : '') + '</div>';
    }).join('');
    box.innerHTML = h;
    [].forEach.call(box.querySelectorAll('.fx'), function(b){
      b.onclick = function(){
        var act = b.dataset.fix;
        if (act === 'build'){ runBuild(null); return; }
        if (act === 'libscan'){ libScanRun(); return; }
        if (act === 'rebuildSource'){
          if (b.dataset.sure !== '1'){ b.dataset.sure = '1'; b.textContent = '会清空本源索引再重抓，再点一次'; return; }
          rebuildSource(b); return;
        }
        if (act === 'retryUnmatched' && turboWanted()){
          b.disabled = true; b.textContent = '排队中…';
          api('/api/repair?do=requeueUnmatched').then(function(r){ say('重试匹配：' + r.msg); b.textContent = '已排队'; if (r.queued) runTurbo(null); })
            .catch(function(e){ b.disabled = false; b.textContent = '失败'; toast(e.message); });
          return;
        }
        b.disabled = true; b.textContent = '处理中…';
        runFix(act, b.dataset.arg, function(r, n){
          if (r.left) b.textContent = '处理中 ' + n + '（剩 ' + r.left + '）';
        }, function(err, r){
          if (err){ b.textContent = '失败'; b.disabled = false; toast(err.message); return; }
          b.textContent = '已完成';
          say((FIXNAME[act] || act) + '：' + (r.msg || '完成'));
          if (act === 'retryUnmatched' || act === 'resync' || act === 'restore'){ pageCache = {}; pre = {}; }
          loadState();
        });
      };
    });
  }).catch(function(e){
    if (btn){ btn.disabled = false; btn.textContent = '体检'; }
    if (box) box.innerHTML = '<div class="err">' + esc(e.message) + '</div>';
  });
}

/* ══════════════════════════════════════════════════════════════════
   路由与启动
   ══════════════════════════════════════════════════════════════════ */
function setNav(v){
  [].forEach.call(navEl.querySelectorAll('button'), function(b){
    b.classList.toggle('on', b.dataset.v === v);
  });
  navThumb();
}
/* 坞的白 thumb：量选中项的位置与宽度，平移 + 改宽（CSS 过渡，同 Transfer 的 layout 弹簧曲线）。
   字重换成 650 之后宽度才定，所以在下一帧量；尺寸变化（转屏、坞在顶栏与底部之间切换）重量一次 */
function navThumb(){
  var hl = navEl.querySelector('.hl');
  if (!hl) return;
  requestAnimationFrame(function(){
    var b = navEl.querySelector('button.on');
    if (!b || !b.offsetWidth){ hl.classList.remove('on'); return; }
    hl.style.width = b.offsetWidth + 'px';
    hl.style.transform = 'translateX(' + b.offsetLeft + 'px)';
    hl.classList.add('on');
  });
}
(function(){
  var t = 0;
  addEventListener('resize', function(){ clearTimeout(t); t = setTimeout(navThumb, 120); }, { passive:true });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(navThumb);
})();
function view(v, push){
  /* 详情开着的时候切标签：先把它推回去；这一条历史直接「换」成新标签页，
     不再 back()+push —— 那样当前历史项会停在详情上，前进 / 后退就错位。 */
  if (PUSH.open){
    PUSH.hide();
    if (push !== false){ history.replaceState({ v:v }, ''); push = false; }
    S.view = '';
  }
  if (v === S.view && v !== 'lib') return;
  if (push !== false) history.pushState({ v:v }, '');
  if (v === 'lib') lib();
  else if (v === 'dl') renderDL();
  else if (v === 'idx') openIndex();
}
[].forEach.call(navEl.querySelectorAll('button'), function(b){
  b.onclick = function(){ view(b.dataset.v); };
});
document.getElementById('home').onclick = function(){ S.q = ''; qEl.value = ''; clrEl.classList.remove('on'); view('lib'); };
backEl.onclick = function(){ if (PUSH.open) closeDetail(); else history.back(); };
addEventListener('popstate', function(e){
  /* 手势关详情时我们自己调过 history.back()，那一次 popstate 不用再处理 */
  if (PUSH.skipPop){ PUSH.skipPop = 0; return; }
  var st = e.state || {};
  var v = st.v || 'lib';
  if (PUSH.open && v !== 'm'){ PUSH.hide(); return; }   // 返回：推回去，底下那层不动
  if (v === 'm'){
    var m = CART.o[st.id] || S.items.filter(function(x){ return x.id === st.id; })[0];
    if (m){ S.under = st.under || S.under || 'lib'; S.view = ''; openMovie(m, false); return; }
    v = 'lib';
  }
  S.view = ''; view(v, false);
});
addEventListener('scroll', function(){
  hdr.classList.toggle('stuck', scrollY > 4);
  if (S.view === 'lib') S.scroll = scrollY;
}, { passive:true });

/* ── 海报卡片：整页只挂一套监听（事件委托） ──
   一千张卡也只有这几个函数，网格随便重画都不用重新绑。
   按住 480ms 开详情；移开 10px 撤销这一次按压（多半是在滚动）。 */
(function(){
  var cur = null, hold = null, held = false, away = false, px = 0, py = 0;
  function artOf(e){
    var t = e.target && e.target.closest ? e.target.closest('.art') : null;
    if (!t || !t.closest('.tile') || t.closest('.grid.preview') || t.closest('.hero')) return null;
    return t;
  }
  function movieOf(a){ var t = a.closest('.tile'); return t ? S.items[+t.dataset.i] : null; }
  function drop(){ clearTimeout(hold); hold = null; if (cur) cur.classList.remove('cancel'); cur = null; }
  out.addEventListener('pointerover', function(e){
    var a = artOf(e); if (!a) return;
    var x = movieOf(a); if (x) prefetch(x.id);
  });
  out.addEventListener('pointerdown', function(e){
    var a = artOf(e); if (!a || e.button > 0) return;
    var x = movieOf(a); if (x) prefetch(x.id);
    cur = a; held = false; away = false; px = e.clientX; py = e.clientY;
    a.classList.remove('cancel'); clearTimeout(hold);
    hold = setTimeout(function(){ held = true; haptic('tap'); if (x) openMovie(x); }, 480);
  });
  out.addEventListener('pointermove', function(e){
    if (!cur) return;
    var far = Math.abs(e.clientX - px) > 10 || Math.abs(e.clientY - py) > 10;
    if (far !== away){
      away = far; cur.classList.toggle('cancel', far);
      if (far) clearTimeout(hold);
    }
  });
  out.addEventListener('pointerout', function(e){
    if (cur && !(e.relatedTarget && cur.contains(e.relatedTarget))) clearTimeout(hold);
  });
  out.addEventListener('pointerup', drop);
  out.addEventListener('pointercancel', drop);
  out.addEventListener('click', function(e){
    var a = artOf(e);
    if (a){
      if (held){ held = false; return; }
      if (away){ away = false; return; }
      var x = movieOf(a); if (!x) return;
      if (cartToggle(x)){ haptic('commit'); toast('已加入 · ' + relName(x)); }
      return;
    }
    var nm = e.target && e.target.closest ? e.target.closest('.tname') : null;
    if (nm && nm.closest('.tile') && !nm.closest('.grid.preview')){
      var m = movieOf(nm); if (m) openMovie(m);
    }
  });
})();

var qT = null;
qEl.addEventListener('input', function(){
  clrEl.classList.toggle('on', !!qEl.value);
  clearTimeout(qT);
  qT = setTimeout(function(){
    var q = qEl.value.trim();
    if (q === S.q && S.view === 'lib') return;
    S.q = q; S.page = 1; S.scroll = 0;
    if (S.view !== 'lib'){ S.view = 'lib'; }
    lib();
  }, 260);
});
qEl.addEventListener('keydown', function(e){ if (e.key === 'Enter'){ qEl.blur(); } });
clrEl.onclick = function(){ qEl.value = ''; if (S.q === '' && S.view === 'lib'){ clrEl.classList.remove('on'); return; } S.q = ''; clrEl.classList.remove('on'); lib(); };
addEventListener('keydown', function(e){
  if (e.key === '/' && document.activeElement !== qEl){ e.preventDefault(); qEl.focus(); }
  if (e.key === 'Escape' && document.activeElement === qEl) qEl.blur();
});

applyTheme();
setSrc(S.src, true);
[].forEach.call(document.querySelectorAll('#srcNav button'), function(b){
  b.onclick = function(){ setSrc(b.dataset.s); };
});
PERF.init();
PUSH.init();
history.replaceState({ v:'lib' }, '');
/* 片单是同步从 localStorage 读出来的，所以动作坞的最终状态现在就知道 ——
   先同步画一次，别等 IndexedDB 那个异步回来之后再让它从屏幕外滑上来。 */
paintDock();
DL.load().then(paintDock, paintDock);
lib();
/* 两帧之后解除首帧禁令：第一帧落定初始状态，第二帧确保它已经上屏。 */
var unfreeze = function(){ document.documentElement.classList.remove('noanim'); };
requestAnimationFrame(function(){ requestAnimationFrame(unfreeze); });
setTimeout(unfreeze, 400);   /* 后台标签页里 rAF 不跑，兜一手 */
</script>
</body>
</html>
`;
/* 页面指纹：模块加载时算一次（FNV-1a），/ 用它做 ETag 协商 */
const PAGE_TAG = (() => {
  let h = 0x811c9dc5;
  for (let i = 0; i < PAGE.length; i++){ h ^= PAGE.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return '"' + h.toString(16) + '-' + PAGE.length.toString(36) + '"';
})();
