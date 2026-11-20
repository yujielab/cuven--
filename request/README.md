# Cuven 请求添加 Worker（tj.cuven.us）

App 里点「请求添加」，这个 Worker 就接管整条链：

1. 让影片库把片子推进 PikPak 的 `/auto`。
2. 盯着云下载到 100%。
3. 清洗下载的内容。
4. 让 VPS 上的 rclone 把它传到 Dropbox 的 `/auto`。
5. 等工作人员把它挪到 ram / ram2 发行。

App 上显示成五步进度。代码见 [`worker.js`](worker.js)，测试见 [`tests/run.mjs`](tests/run.mjs)。

它连接另外两个 Worker：
- 影片库：[index/](../index/README.md)，lb.cuven.us，用 v7.0 的 `/api/link/versions` 和 `/api/pikpush`。
- 传输：transfer.cuven.us，用 907 版的 `/api/link/*`。传输 Worker 的代码不在仓库里。

## 五个步骤

| App 上 | 内部阶段 | 做什么 | 出问题时 |
| --- | --- | --- | --- |
| ① 已请求 | `queued` | 问影片库这部片或这一季按规格排好的全部版本，取第一个没试过的，让影片库推进 PikPak 的 `/auto`（影片库用它自己配的 PikPak 账号建云下载任务）。 | 影片库这会儿推不了，就过几分钟再推；这个版本推不了，就换下一个。 |
| ② 待传输 | `download` | 盯 PikPak 的云下载任务，进度直接显示在 App 上。 | 任务出错、2 小时没有进度、12 小时还没下完：删掉任务和文件，回到 ① 推下一个规格。 |
| ③ 预处理中 | `clean`（电影） | 文件夹里体积最大的视频（不算 sample / 预告）移到 `/auto`，原文件夹进回收站。下来的是单个视频就直接用。 | 没有视频：换规格。 |
| | `check`（剧集） | 传输 Worker 整理文件夹（删广告垃圾），再核对整季：总集数取标题里写的，标题没写就用 TMDB 上这一季已经播出的集数。 | 缺集、标题写着还在连载、没有认得出集号的视频：换规格（降档重试）。 |
| | `rename`（剧集） | 传输 Worker 按发行命名改文件夹名（默认 `rel` / 英文名 / `Cuven®`，面板里可改），等 rclone 的任务跑完。 | 失败重试 3 次，还不行就停下来等人。 |
| ④ 正在传输 | `copy` → `verify` → `purge` | rclone `webdav:auto/<名字>` → `dropbox:auto/<名字>`（先 copy）。两端核对文件数和字节数，一致了才删 PikPak 那份。 | 传输出错或两端对不上，就重新 copy，最多 3 次。 |
| ⑤ 等待工作人员的最终发行 | `release` | 每 5 分钟看一眼 `dropbox:auto/<名字>` 还在不在。 | — |
| 完成 | `done` | 工作人员把它挪去 ram / ram2 之后，它就不在 `/auto` 里了，算作已发行。 | — |

百分比 =（第几步 − 1 + 这一步的进度）÷ 5。例如刚进第 3 步是 40%，等发行是 80%，发行了是 100%。

其他规则：
- **跟上**：同一部片（剧集是同一季）已经有人在请求，后来的人就跟上那一条，不重复下载。
- **限额**：每个用户同时进行中最多 5 个，全部加起来最多 30 个（面板里可改）。等发行的不算。
- **失败后**：一天之内用户再点，拿回的还是那条失败的；面板里随时能重试。
- **出错退避**：同一步出错会按 2、4、8…30 分钟往后退；连续 20 次就停下来等人看。网络这类暂时的问题不算在这 20 次里。

## App 接口

不需要口令。请求类的接口要带 `x-cuven-user`，值是 `encodeURIComponent(用户名)`。这个用户名要在 check.cuven.us 上查得到（`/check/<用户名>` 回 `exists: true`，和 App 登录时同一个接口），核对过的缓存 7 天。

| 接口 | 回包 |
| --- | --- |
| `GET /app/catalog?src=movie\|tv\|all&q=&page=&sort=new\|vote\|hot\|spec&own=all\|hide&min=` | 索引里的全部已知影片和剧集（`id` 是 TMDB 编号）。`src=all` 时电影、剧集交替排。每条带 `req`（这部片的请求进度）。 |
| `GET /app/detail?src=&id=&season=` | `known`（索引里有没有）、`count`（几个可请求的版本）、`best`（最好的规格）、`seasons`、`season`、`req`（这一部或这一季的进度）、`reqs`（每一季的进度）。 |
| `GET /app/requests` | 我的请求：进行中的，加上 30 天内结束的。 |
| `POST /app/requests { src, id, season }` | 请求添加。回 `created`（新建）、`joined`（跟上已有的）或 `failedRecently`（刚失败过）。 |

一条请求的进度（`req` / `request` / `items[]`）：

```json
{ "id": 12, "src": "tv", "tmdb": 1399, "season": 2, "title": "权力的游戏", "poster": "/x.jpg",
  "stage": "copy", "state": "active", "step": 4, "steps": 5, "pct": 69,
  "label": "正在传输", "note": "传输到 Dropbox 50% · 2.0 MB/s",
  "spec": { "res": "1080p", "labels": ["1080p"], "size": "8 GB" }, "tries": 1, "updated": 1763520000000 }
```

`state` 是 `active` / `done` / `failed` / `cancelled`。失败和取消的 `step` 停在出事的那一步。

## 控制面板

打开 https://tj.cuven.us/ 输入 ADMIN_KEY，可以：

- **PikPak 账号**：填账号和密码，测试登录。测试时也会核对影片库给的 `/auto` 在这个账号里存在，也就是两边是同一个账号。
- **连接**：测试影片库和传输 Worker 能不能连上。
- **剧集命名**：改模板、语言、发行组。
- **限额**：改两个上限，也可以暂停定时任务。
- **手动添加**：按 TMDB 编号直接添加一条请求。
- **请求列表**：现在推进、换规格、取消、重试、删除，以及看每一条的日志。

PikPak 密码用 ADMIN_KEY 派生的密钥（AES-GCM）加密后存进 D1。换了 ADMIN_KEY 要重新填一次密码。

## 部署

### Cloudflare 面板

1. **建 D1**：存储和数据库 → D1 → 创建，名字叫 `cuven-request`。表不用手动建，Worker 第一次运行时会自己建。
   表名都带 `tj_` 前缀（`tj_req` / `tj_kv` / `tj_log`），和别的 Worker 共用一个库也不会撞名（1.0 用的是 `req` / `kv` / `log`，库里原来就有一张 `kv` 时会报 `no such column: exp`，1.1 修了）。
2. **建 Worker**：Workers 和 Pages → 创建 → Hello World，名字叫 `cuven-request`。把 `worker.js` 的全部内容粘进去，然后部署。
3. **设置 → 绑定**：添加 D1 数据库，变量名填 `DB`，选第 1 步建的库。
4. **设置 → 变量和机密**，三个都选「密钥」：
   - `ADMIN_KEY`：自己定一个长口令，用来登录控制面板。
   - `LB_GATE`：和影片库 Worker 的 `GATE` 一样。
   - `LINK_KEY`：和传输 Worker 的 `LINK_KEY` 一样。
5. **设置 → 触发事件**：添加 Cron 触发器 `* * * * *`（每分钟一次）。
6. **设置 → 域和路由**：添加自定义域 `tj.cuven.us`。
7. 打开 https://tj.cuven.us/，填 PikPak 账号和密码。点「测试登录」和「测试影片库 / 传输」，都应该是绿的。

可选变量（下面是默认值，一般不用改）：
- `LB_BASE` = https://lb.cuven.us
- `TRANSFER_BASE` = https://transfer.cuven.us
- `STREAM_BASE` = https://stream.cuven.online
- `ACCOUNT_BASE` = https://check.cuven.us
- `AUTO_DIR` = auto

### wrangler

```sh
cd request
wrangler d1 create cuven-request          # 把打印出来的 database_id 填进 wrangler.toml
wrangler secret put ADMIN_KEY
wrangler secret put LB_GATE
wrangler secret put LINK_KEY
wrangler deploy
```

### 另外两个 Worker 要做的

- **影片库**：部署 v7.0 的 `index/worker.js`。`PIKPAK_USER` 必须和这里面板里填的是同一个 PikPak 账号。
- **传输**（907 版，代码不在仓库里）：设置下面这些变量。
  - `LINK_KEY`（密钥）：和这里的一样。
  - `VPS_PASS`（密钥）：rclone rcd 的密码。
  - 以下有默认值，一般不用改：
    - `VPS_HOST` = vps2.cuven.us
    - `VPS_PORT` = 8080
    - `VPS_USER` = admin
    - `RC_WEBDAV` = webdav:
    - `RC_PIKPAK` = pikpak:
    - `RC_DROPBOX` = dropbox:
    - `AUTO_DIR` = auto
- **VPS 上的 rclone**：要有三个 remote：
  - `webdav:`：PikPak 的 WebDAV，用来读。
  - `pikpak:`：原生 PikPak 后端，用来改名和删除。
  - `dropbox:`

## 免费计划的用量

- 每分钟跑一轮，一轮最多推进 8 条请求。
- 子请求一轮不超过 42 个（免费计划的上限是 50）。
- 云下载的进度一轮只问 PikPak 一次，所有条目共用。
- 传输中的条目每分钟问一次 rclone 的任务状态；等发行的每 5 分钟看一次。

## 测试

```sh
node request/tests/run.mjs
```

测试不需要网络：
- D1 用 node:sqlite 的内存库代替。
- 影片库、传输、PikPak、TMDB 分季、账户核对都在测试里模拟，时钟是假的，可以手动拨。
- 覆盖了电影全流程（推送、出错换规格、清洗、传输、核对、删除、等发行、已发行）。
- 覆盖了剧集全流程（缺集降档、按 TMDB 核对集数、改名、两端对不上重传）。
- 还覆盖了目录和详情带进度、限额、刚失败过、面板的取消和重试、没配 PikPak 时的等待。

## 没有验证到的

- 没有连真的 PikPak 和 rclone 跑过。PikPak 云下载任务和文件的字段（`phase`、`progress`、`file_id`）按公开客户端的用法写的。`files:batchMove`、`files:batchTrash`、`DELETE /drive/v1/tasks` 也一样。
- 电影移到 `/auto` 时如果撞名，PikPak 怎么处理不确定。移完会重新读一次文件名，传输用读回来的名字。
