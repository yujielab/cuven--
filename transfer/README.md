# Cuven Transfer Worker（transfer.cuven.us，909）

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

面板自己连 VPS 用的端口、用户、密码写在 `worker.js` 里（`const FIX`）。改了 rclone 的密码，要同时改这里和 `VPS_PASS`。

## `/api/link/*`

都是 POST JSON，口令放在 `x-cuven-link` 请求头里。所有名字都只能是 `auto` 下面的一层：不许有斜杠，不许有 `..`。

| 接口 | 做什么 |
| --- | --- |
| `ping` | 能不能连上 VPS（回 rclone 版本） |
| `organize { dir }` | 删剧集文件夹里的广告文件（进 PikPak 回收站） |
| `check { dir, total? }` | 整季完整性：ok / short / unsure / busy / skip / nonvid / bare |
| `rename { dir, tpl?, lang?, grp? }` | 按发行命名改文件夹名（`sync/move`，异步），回 `{ name, jobid }` |
| `job { jobid }` / `jobs { ids }` | 作业进度。作业不见了（rclone 重启过）回 `missing` |
| `stop { jobid }` | 停一个作业 |
| `copy { item, kind, from?, sizeOnly? }` | `webdav:auto/<item>` → `dropbox:auto/<item>`。补传时可以用 `from: 'pikpak'` 改从原生后端拿，`sizeOnly` 只按大小判断 |
| `verify { item, kind }` | 两端逐个文件核对（见下面），回 `ok`，以及缺了哪些（`missing`）、哪些大小不对（`differ`）、Dropbox 那边多了几个（`extra`） |
| `purge { item, kind }` | 删 PikPak 那份 |
| `exists { item }` / `exists { items }` | `dropbox:auto` 里还在不在（不在了 = 已经人工发行） |

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

## 测试

```sh
node transfer/tests/run.mjs
```

rclone rc 全部模拟，不需要网络和 VPS。共三组：
- `link.mjs`：接口的基本功能。
- `retry.mjs`：52x 重试、备用入口、批量接口。
- `verify.mjs`：逐个文件核对、补传换来源。
