# Cuven Transfer Worker（transfer.cuven.us，911）

PikPak → Dropbox 的传输面板，加上给[请求添加 Worker](../request/README.md) 用的服务端接口。代码见 [`worker.js`](worker.js)。

- 单文件、零绑定：Cloudflare 面板 → Workers → 创建 → 粘贴 `worker.js` → 部署。不需要 wrangler.toml、Durable Object 迁移或 D1。
- 面板（`GET /`）在浏览器里通过 Worker 调 VPS 上的 rclone rc（`POST /api/rc`），负责部署、传输、配置。
- 请求添加用 `/api/link/*`，在服务端自己调 rclone，没人开着面板也能把一部片走完。
- 每个版本改了什么，写在 `worker.js` 开头的注释里。

## 变量

| 变量 | 类型 | 默认 | 用途 |
| --- | --- | --- | --- |
| `LINK_KEY` | 密钥 | — | `/api/link/*` 的口令（请求头 `x-cuven-link`），和请求添加 Worker 填同一串。不配，这组接口就整组关着 |
| `VPS_PASS` | 密钥 | — | VPS 上 rclone rcd 的密码（`/api/link/*` 用） |
| `VPS_HOST` | 文本 | `vps2.cuven.us` | VPS 地址 |
| `VPS_PORT` | 文本 | `8080` | 必须是 Worker 允许出站的 HTTP 端口：80 / 8080 / 8880 / 2052 / 2082 / 2086 / 2095 |
| `VPS_USER` | 文本 | `admin` | rclone rcd 用户名 |
| `VPS_ALT` | 文本 | 空 | 同一台 VPS 的备用入口：不走 Cloudflare 代理的灰云子域名，或者 IP。主入口回 52x 时，重试轮流走它 |
| `RC_WEBDAV` | 文本 | `webdav:` | 传输的来源（PikPak 的 WebDAV） |
| `RC_PIKPAK` | 文本 | `pikpak:` | rclone 原生 PikPak 后端：整理、改名、删除、核对 |
| `RC_DROPBOX` | 文本 | `dropbox:` | 传输的目标 |
| `AUTO_DIR` | 文本 | `auto` | 两边都用这个文件夹 |
| `AUTO_TV_DIR` | 文本 | `ram2` | 剧集区：`auto` 下面放剧集的那一层（PikPak、Dropbox 两边一样）。只能是一层名字 |

面板自己连 VPS 用的端口、用户、密码写在 `worker.js` 里（`const FIX`）。改了 rclone 的密码，要同时改这里和 `VPS_PASS`。

## `/api/link/*`

都是 POST JSON，口令放在 `x-cuven-link` 请求头里。所有名字都只能是一层：不许有斜杠，不许有 `..`。

条目 / 目录接口都可以带 `sub`（910）：
- 不带或空：名字在 `auto` 下面，和 909 一模一样。
- 剧集区的名字（`AUTO_TV_DIR`，默认 `ram2`，不分大小写）：名字在 `auto/ram2` 下面。
- 别的值回 400。

不带 `sub` 时，名字不能就是剧集区本身（不分大小写），否则回 400。这样 `purge` / `verify` 一个叫 `ram2` 的条目，碰不到整个剧集区。

| 接口 | 做什么 |
| --- | --- |
| `ping` | 能不能连上 VPS（回 rclone 版本）。910 起多回 `caps: ['sub', 'batch']` 和 `tv`（剧集区的名字） |
| `organize { dir }` | 删剧集文件夹里的广告文件（进 PikPak 回收站）。911 起一次最多删 40 个，多回 `left`（还剩几个没删），见「911 加固」 |
| `check { dir, total? }` | 整季完整性：ok / short / unsure / busy / skip / nonvid / bare |
| `rename { dir, sub?, to?, tpl?, lang?, grp? }` | 按发行命名改文件夹名（`sync/move`，异步），回 `{ name, jobid, sub }`。`to` 是改完放在哪个区（不给 = 和 `sub` 一样）。上一次其实已经挪完的，回 `{ name, jobid, sub, done: 1 }`，见下面 |
| `job { jobid, detail? }` / `jobs { ids }` | 作业进度。作业不见了（rclone 重启过）回 `missing`。`detail: 1` 多回 ETA、文件数、正在传的文件（见下面） |
| `stop { jobid }` | 停一个作业 |
| `copy { item, kind, from?, sizeOnly?, retry? }` | `webdav:auto/<item>` → `dropbox:auto/<item>`。补传时可以用 `from: 'pikpak'` 改从原生后端拿，`sizeOnly` 只按大小判断。`retry: 1`（911）：上一次没拿到回答，先看那个作业是不是还在跑，在跑就接上（`reused: true`） |
| `verify { item, kind }` | 两端逐个文件核对（见下面），回 `ok`，以及缺了哪些（`missing`）、哪些大小不对（`differ`）、Dropbox 那边多了几个（`extra`） |
| `purge { item, kind }` | 删 PikPak 那份。本来就没了回 `{ ok: 1, gone: 1 }`（911） |
| `exists { item, sub? }` / `exists { items, tv? }` | `dropbox:auto` 里还在不在（不在了 = 已经人工发行）。`tv` 里是剧集区下面的名字，回 `{ exists, tv }` |
| `batch-copy { key, items, from?, sizeOnly?, transfers?, checkers? }` | 一批（最多 16 项）一个传输作业，见「批量传输」。同一个 key 的作业已经在跑，回 `{ jobid, reused: true }`（作业号没找到时 `jobid` 是 0，另带 `running: 1`） |
| `batch-verify { items, src? }` | 一批一起核对，回 `{ results: { key: 同 verify } }` |
| `batch-purge { items }` | 一批（最多 8 项）删 PikPak 那份，回 `{ results: { key: { ok } / { ok, gone } / { error } } }` |

### 连 VPS 的重试（908）

域名走橙云时，Worker → Cloudflare 边缘 → VPS 这一段偶尔会断。这时边缘回一张 52x 错误页，rclone 根本没收到请求。现在按「请求有没有可能已经送到」分情况处理：

| 情况 | 处理 |
| --- | --- |
| 521 / 522 / 523 / 525 / 526 / 530 | 请求没送到，任何接口都重试 |
| 502 / 503 / 520、连接中途断掉 | 请求可能已经送到，只重试查询类接口。开传输、删文件、改名不重试，免得开两次 |
| 524 / 超时 | 不重试 |

最多试 3 次，间隔约 0.4 秒、1.2 秒（带一点随机），总时长不超过这次调用原来的超时。面板的 `/api/rc` 也走同一套重试。

还是经常 523，就检查 `vps2.cuven.us` 的 AAAA 记录：VPS 没在 IPv6 上监听的话，Cloudflare 走 IPv6 就连不上。或者配上 `VPS_ALT`。

### 两端核对（909）

逐个文件比路径和大小：
- 源头用原生 pikpak 后端列目录。WebDAV 的列表会缓存，所以不用它。
- 路径按 Unicode NFC、不分大小写比（Dropbox 不分大小写）。

这些不算不一致：
- Dropbox 存不了的系统文件（desktop.ini、thumbs.db、.DS_Store 等）
- 没下完的临时文件（.part、.!qB、.aria2 等）
- Dropbox 那边多出来的文件

列目录失败时回 502（这次没核对成），不会回「不一致」。

### 批量传输（910）

请求中心一次能加几十部。以前每部单独开一个 rclone 作业，用 rclone 的默认值（4 并发、8 检查），一部接一部地传。现在一批（最多 16 项）只开一个作业，16 并发、16 检查。

`items` 里每项是 `{ item, kind, sub }`：`kind` 是 `file`（电影，直接在 `auto` 里）或 `dir`（剧集，一般在 `auto/ram2` 里）。结果按 key 回：带 `sub` 的是 `ram2/<item>`，不带的是 `<item>`。有一项不对，整批回 400，并在 `index` 里标出是第几项。同一项给两次的，只算一次。

`batch-copy` 一次调用做四步。前三步同时进行（以前一步接一步，`sync/copy` 可能拖到 59 秒才发出去，这时调用方已经因为 60 秒超时放弃了）：

1. **预检**：用这一批的过滤规则，递归列一次来源（`webdav:auto`；带 `from: 'pikpak'` 时列 `pikpak:auto`）。
   - 列回来有这批以外的文件，说明这台 rclone 不认过滤。这时回 409 `{ nofilter: 1 }`，不开作业，请求添加退回逐个传。不然一个作业会把整个 `auto` 都搬走。
   - 这次列表顺带给出每项的文件数和字节数（`items`、`total`、`files`），当进度条的分母。Dropbox 存不了的系统文件不计入。
2. **幂等**：同一个 key 的作业按 rclone 的统计组来认。调用方超时后重来，不会开出第二个作业。
   - 统计组每开一次换一个名字：第一次是 `tjb/<key>`，重开后是 `tjb/<key>/2`、`tjb/<key>/3`……rclone 不会删掉跑完的统计组，同名的新作业会接着上一次的字节数、文件数和错误往上加，所以重开不沿用旧名字。rclone 重启后统计组都清空了，又从 `tjb/<key>` 开始。
   - 不按「最新几个作业号」来认：真的 rclone（1.62 起）每个 rc 调用都占一个作业号，连同步调用也算，`job/list` 也只回 `jobids`，里面是 24 小时内的全部作业。
   - `core/group-list` 里没有这个 key 的组，说明 rclone 这次启动以来没开过，直接开。
   - 有这个 key 的组时：`job/list` 给了 `runningIds`，就挨个问还在跑的作业。没给的话，就看最新那一组的统计：
     - 有正在传或正在核对的文件，说明作业在跑，回 `{ jobid, reused: true }`。作业号在 `group-list` 里这一组前后的那段作业号里找，最多问 15 个；找不到时回 `{ jobid: 0, reused: true, running: 1 }`，这一轮不开。
     - 什么都没在传，可能是作业已经跑完、被停掉，也可能还在列目录（`CheckFirst` 会先列完两边）。找到了作业，就看它跑完没有；找不到，就先用 `job/stopgroup` 停掉这一组，再开下一组。这样同一个 key 不会有两个作业同时在跑。
   - `group-list`、`job/list`、统计、停组，有一样没问出来，这一轮就不开（502 / 503）。
3. 建好 `dropbox:auto`；这批里有剧集时，再建 `dropbox:auto/ram2`。超时 5 秒，不看结果（`sync/copy` 自己也会建）。
4. 开一个异步 `sync/copy`（超时 15 秒）。已经过了 40 秒就不开了，回 503，调用方下一轮再来。这个检查就放在发 `sync/copy` 之前（停组之后会再看一次），保证 55 秒以内回到调用方。`sync/copy` 的参数：
   - 来源：`webdav:auto`（或 `pikpak:auto`）。
   - 目标：`dropbox,chunk_size=16Mi,batch_mode=sync:auto`，从 `RC_DROPBOX` 推出来，只对这次调用生效。不开 batch_mode 的话，16 路同时上传会撞上 Dropbox 的 429。
   - `_config`：`Transfers` / `Checkers` 默认都是 16（可在 1–16 之间调），`BufferSize` 8Mi，`CheckFirst`（先检查完再传，进度条的分母不会往回跳），以及可选的 `SizeOnly`。
   - `_filter`：每项一条 `IncludeRule`，加上 `IgnoreCase`。文件是 `/[ram2/]<名字>`，文件夹是 `/[ram2/]<名字>/**`。名字里的 `* ? [ ] { } \` 全部转义：发行名里有 `[Full-4][CN-HK-EN]`，追踪码是 `[auto-tv…]`，不转义就成了字符类，那一项什么都匹配不到，作业却照样「成功」。

内存：16 × (16Mi 分块 + 8Mi 缓冲) + 100 ≈ 480 MB。默认的 48Mi + 16Mi 要 1.1 GB 左右，2G 的 VPS 会被 OOM 杀掉。

`batch-verify` 两边各列一次（用同一套过滤，同时发），按条目分开，每项走 909 的逐个文件核对。
- 哪边列失败，回 502 `{ side }`，不会回「不一致」。
- Dropbox 那边连 `auto` 都没有，算全缺。
- 来源那边一个文件都没有的条目，多回 `nosrc: 1`。补传也没用，调用方别一直重传。

`batch-purge` 最多 8 项，最多 4 个同时删。删的时候本来就没了，算删掉了（`{ ok: 1, gone: 1 }`），所以重试是安全的。全部都连不上 VPS 时回 502。不用按过滤规则批量删：过滤一旦没生效，删掉的就是整个 `auto`。

`job { jobid, detail: 1 }`：
- 统计组从 `job/status` 读，批量作业的统计组不是 `job/<id>`。
- 多回 `eta`、`elapsed`、`transfers` / `totalTransfers`、`checks` / `totalChecks`、`errors`、`lastError`，以及正在传的文件 `transferring: [{ item, sub, file, bytes, size, pct, speed }]`（按路径归到条目）。
- `jobs` 还是每个作业 2 次调用。

### 剧集区和改名（910）

- 剧集在 PikPak 和 Dropbox 上都放在 `auto/ram2` 下面，电影还是直接放在 `auto` 里。
- `rename { dir, sub, to }` 把 `auto/[sub/]dir` 挪到 `auto/[to/]<新名字>`。名字没变也照样挪（比如从 `auto` 挪进 `auto/ram2`）。名字和区都没变，才回 `{ same: 1 }`。
- 用到剧集区（`sub` 或 `to` 不为空）时，先建好目标的上一层，再看目标在不在：
  - 目标在、原来的也在，回 409 `{ exists: 1 }`。rclone 碰上已有的目标，会把两个文件夹逐个文件合并到一起。
  - 目标在、原来的不在了，说明上一次改名其实已经挪完了，只是回包丢了（PikPak 一下就挪完；`sync/move` 遇到 520 不重试）。这时回 200 `{ name, sub, jobid, done: 1 }`，不回 `exists`，免得调用方照原名往下走。`jobid` 是一个确认用的异步 `stat`（看新名字的那个文件夹），马上就会跑完、成功，所以老的调用方照常等作业跑完，再换成新名字。
- `sub`、`to` 都不带时和 909 一样。
- `exists { items, tv }`：只有给了 `tv` 才列 `dropbox:auto/ram2`，两次列表同时发。剧集区那个文件夹本身不算一个条目。名字不分大小写。

### 并发

Worker 每次调用最多同时开 6 个连接，多出来的要排队。`vpsFetch` 的计时在 fetch 之前就开始了，排队的时间也算进超时。所以 `jobs`（最多 12 个作业）、`organize`（删广告文件）和 `batch-purge` 都限制最多 4 个同时进行，结果还按原来的顺序回。

### 911 加固

这一版只动 `/api/link/*`，接口形状都向下兼容（老的请求添加照旧能用）。每条的根因写在 `worker.js` 开头的 911 注释里。

**子请求和总时长。** 免费版一次调用最多 50 个子请求，调用方（请求添加）60 秒超时。
- `organize` 一次最多删 40 个（1 次列目录，最多重试 2 次，再留点余量），45 秒以后不再开新的删除。没删的（超过 40 个的、没来得及删的、删失败的）都算进 `left`。每次都重新列，所以 `left > 0` 时再叫一次是安全的。以前一次最多 61 个子请求，第 50 个以后全失败，60 个以后的连提都不提。
- 单项 `verify` 两边同时列 / 同时 `stat`，和 `batch-verify` 一样（以前一个接一个，大的季两边各列 40 秒就是 80 秒）。回的错照旧：先看 PikPak 那边，再看 Dropbox 那边。
- `rename`：建目录 5 秒、不看结果；发 `sync/move` 之前已经过了 28 秒，就回 503 `{ retry: 1 }`，下一轮再来（重来安全，见下面）。
- `job` / `jobs` 的 `job/status`、`core/stats` 各 8 秒：`jobs` 12 个、4 个一轮，最多 48 秒。`batch-purge` 的 purge 25 秒，两轮最多 50 秒。
- `batch-copy` 找作业：`runningIds` 一次问 3 个，每次之前看截止（以前 16 个一个不落地问完，能到 54 秒）。问到的记下来，退到看统计时不再问第二遍，15 个名额留给没问过的。这个 key 开过、又问到截止还没问完，回 503，不再往下问。

**rclone 自己回的错。** rclone 的 rc 只有「没找到」回 404、参数不对回 400，后端出的事（PikPak / Dropbox 超时、限流、5xx、token 刷不下来）都是 HTTP 500 + JSON `error`。以前一律回 422，请求添加当成逻辑错误：熔断不开，每一行按满退避攒错，20 次后判死。现在：
- rclone 回 5xx、消息又像暂时性的（`timeout`、`connection reset`、`too_many_requests`、`too_many_write_operations`、`rate limit`、`service unavailable`、`HTTP 503` 这类），回 502。只认整词和带前缀的状态码，文件名、路径里的数字不算。
- 别的照旧 422（没找到、权限、参数）。`rc: true` 不变，「作业没了」「已经删掉了」的判断不受影响。
- `batch-purge` 算「全都连不上」改看 5xx，rclone 回的暂时性错误也算。

**让熔断看得见。** `jobs` 一个都没问到、而且全是 5xx（作业没了的不算），回 502，和 `batch-purge` 一样。以前回 200，请求添加的熔断把它当成「VPS 好好的」清零。

**回包丢了以后的重来。**
- 单项 `purge`：删完了、回包丢了，重来时本来就没了，回 `{ ok: 1, gone: 1 }`（以前 422，传完、核对完、删完的一项最后判失败）。
- `rename` 不带 `sub` / `to`（909 那条路）：挪之前先 `stat` 原来的。确实不在了才看新名字，新名字在 = 上一次已经挪完了，回 `{ name, jobid, sub, done: 1 }`（和剧集区那条路一样，`jobid` 是确认用的异步 `stat`）。别的情况（原来的在、看不了、新名字也不在）照 909 原样发 `sync/move`，不回 409。多一次 `stat`。真的 rclone 对 `_async` 调用当场回作业号，原来的不在了是那个作业失败，所以「重来时报错」的办法认不出这种情况，只能挪之前看。
- 单项 `copy` 都带统计组 `tjc/<[sub/]item>/<毫秒>`：每次一个新组，补传不和上一次的统计累加；平常不多问一次。带 `retry: 1` 时先查（同批量的 `linkBatchSlot`）：
  - 这一项最近开的那个作业还在跑：回 `{ jobid, reused: true }`，不开第二个。
  - 统计里在传、作业号没找到：503 `{ retry: 1 }`。
  - 查不清楚（`group-list` / `job/list` / 统计没问出来）：502。都不开。
  - 跑完了、停掉了：开新的（换一个组）。

**进度不往回掉。** `core/stats` 没问到、`job/status` 问到了：`job { detail: 1 }` 回 503（请求添加下一轮再问），不带 `detail` 的不回 `bytes` / `total` / `speed`（多回 `stats: 0`），老调用方保持上一次的进度。以前当成 0 字节，批量的进度一下掉回 0%。`jobs` 里跑完的作业不再问统计，每个省一次调用；单个 `job` 照旧回。

**要请求添加配合才生效的两处**（不配合也不会更糟）：整理回 `left > 0` 时，下一轮再叫一次 `organize`（最多几次）；`copy` 上一次暂时性失败、没拿到作业号时，带 `retry: 1`。

## 测试

```sh
node transfer/tests/run.mjs
```

rclone rc 全部模拟，不需要网络和 VPS。共四组：
- `link.mjs`：接口的基本功能。
- `retry.mjs`：52x 重试、备用入口、批量接口。
- `verify.mjs`：逐个文件核对、补传换来源。
- `batch.mjs`（910、911）：批量传输 / 核对 / 删除、剧集区 `sub`、改名挪进剧集区、`exists { tv }`、作业 detail、并发上限。模拟的 rclone 按 `_filter` 的 IncludeRule 匹配，认反斜杠转义和 IgnoreCase。作业号和统计组也照真的 rclone 来：每个调用都占一个作业号（放在 `X-Rclone-Jobid` 里），`job/list` 只回 `jobids`，`core/group-list` 按建组的先后排。另外还测了：两轮之间隔了很多调用的重来、重开换统计组、改名「挪完了但回包丢了」，以及用虚拟时钟测的 40 秒截止。911 一节每条加固各有回归测试（虚拟时钟测总时长，子请求数，rclone 500 的分类，回包丢了以后的重来）。模拟的 rclone 也改得和真的一样：`_async` 的 `sync/move` 来源不在了，是当场回作业号、作业失败，不是同步回 404。
