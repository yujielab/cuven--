# Cuven Transfer Worker（transfer.cuven.us，910）

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
| `organize { dir }` | 删剧集文件夹里的广告文件（进 PikPak 回收站） |
| `check { dir, total? }` | 整季完整性：ok / short / unsure / busy / skip / nonvid / bare |
| `rename { dir, sub?, to?, tpl?, lang?, grp? }` | 按发行命名改文件夹名（`sync/move`，异步），回 `{ name, jobid, sub }`。`to` 是改完放在哪个区（不给 = 和 `sub` 一样），见下面 |
| `job { jobid, detail? }` / `jobs { ids }` | 作业进度。作业不见了（rclone 重启过）回 `missing`。`detail: 1` 多回 ETA、文件数、正在传的文件（见下面） |
| `stop { jobid }` | 停一个作业 |
| `copy { item, kind, from?, sizeOnly? }` | `webdav:auto/<item>` → `dropbox:auto/<item>`。补传时可以用 `from: 'pikpak'` 改从原生后端拿，`sizeOnly` 只按大小判断 |
| `verify { item, kind }` | 两端逐个文件核对（见下面），回 `ok`，以及缺了哪些（`missing`）、哪些大小不对（`differ`）、Dropbox 那边多了几个（`extra`） |
| `purge { item, kind }` | 删 PikPak 那份 |
| `exists { item, sub? }` / `exists { items, tv? }` | `dropbox:auto` 里还在不在（不在了 = 已经人工发行）。`tv` 里是剧集区下面的名字，回 `{ exists, tv }` |
| `batch-copy { key, items, from?, sizeOnly?, transfers?, checkers? }` | 一批（最多 16 项）一个传输作业，见「批量传输」 |
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

`batch-copy` 一次调用做四步：

1. **预检**：用这一批的过滤规则，递归列一次来源（`webdav:auto`；带 `from: 'pikpak'` 时列 `pikpak:auto`）。
   - 列回来有这批以外的文件，说明这台 rclone 不认过滤。这时回 409 `{ nofilter: 1 }`，不开作业，请求添加退回逐个传。不然一个作业会把整个 `auto` 都搬走。
   - 这次列表顺带给出每项的文件数和字节数（`items`、`total`、`files`），当进度条的分母。Dropbox 存不了的系统文件不计入。
2. **幂等**：作业的统计组叫 `tjb/<key>`。开之前先用 `job/list` 和 `job/status` 看一眼，同组的作业还在跑，就回 `{ jobid, reused: true }`，不开第二个。这样调用方超时后重来，也不会重复开。
   - 新版 rclone 只问还在跑的作业，老版 rclone 问最新的 8 个。
   - 有作业的状态没问出来，就回 502，这一轮不开。
   - 预检列得太久（超过 45 秒）也不开，回 503。调用方多半已经超时，下一轮会再来。
3. 建好 `dropbox:auto`；这批里有剧集时，再建 `dropbox:auto/ram2`。
4. 开一个异步 `sync/copy`：
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
- 用到剧集区（`sub` 或 `to` 不为空）时，先建好目标的上一层。目标已经在了，回 409 `{ exists: 1 }`：rclone 碰上已有的目标，会把两个文件夹逐个文件合并到一起。`sub`、`to` 都不带时和 909 一样。
- `exists { items, tv }`：只有给了 `tv` 才列 `dropbox:auto/ram2`，两次列表同时发。剧集区那个文件夹本身不算一个条目。名字不分大小写。

### 并发

Worker 每次调用最多同时开 6 个连接，多出来的要排队。`vpsFetch` 的计时在 fetch 之前就开始了，排队的时间也算进超时。所以 `jobs`（最多 12 个作业）、`organize`（删广告文件）和 `batch-purge` 都限制最多 4 个同时进行，结果还按原来的顺序回。

## 测试

```sh
node transfer/tests/run.mjs
```

rclone rc 全部模拟，不需要网络和 VPS。共四组：
- `link.mjs`：接口的基本功能。
- `retry.mjs`：52x 重试、备用入口、批量接口。
- `verify.mjs`：逐个文件核对、补传换来源。
- `batch.mjs`（910）：批量传输 / 核对 / 删除、剧集区 `sub`、改名挪进剧集区、`exists { tv }`、作业 detail、并发上限。模拟的 rclone 按 `_filter` 的 IncludeRule 匹配，认反斜杠转义和 IgnoreCase。
