# Cuven Pass Pro：加速节点（Worker → VPS → 用户）

App 账户页里打开「Cuven Pass Pro」以后，影片不再直接从 Cloudflare 边缘拿，而是走 VPS 上的加速节点：

- **走节点的**：HLS 主列表、二级列表、分段，以及直链。
- **照旧直连 Worker 的**：资料、接口这些小请求。

**为什么快：**
- **线路**：VPS 到用户这一段可以选线路好的机房（比如 CN2 / 优化线路），跨网和晚高峰比 Cloudflare 边缘稳。
- **缓存**：节点把分段缓存在本机磁盘。看过的片子再看、拖回去重看、别人看同一部，都从节点直接出，不再回源。Worker 也少做 MKV → HLS 的现场重封装。

**为什么不用改 Worker：** Worker 的签名只盖路径、不盖主机名（v14 起的设计），同一条地址换成节点的主机名照样有效。

## 装

1. **DNS**：加一条 A 记录 `pass.cuven.us` → VPS 的 IP，必须是「仅 DNS」（Cloudflare 灰云）。橙云的话流量又绕回 Cloudflare，节点白装。
2. **在 VPS 上（root）运行：**

   ```sh
   curl -fsSL https://raw.githubusercontent.com/yujielab/cuven--/main/vps/pass-pro/install.sh | bash -s -- pass.cuven.us
   ```

   完整参数：`bash install.sh <域名> [上游，默认 https://stream.cuven.online] [缓存上限，默认 30g] [证书邮箱]`

   脚本会依次：
   1. 装 nginx、certbot（Debian / Ubuntu）
   2. 写好配置
   3. 签 Let's Encrypt 证书（80 跳 443，自动续期后 reload）
   4. 放行防火墙
   5. 最后检查一遍：
      - `https://pass.cuven.us/__pass/ping` 是节点自己。
      - `https://pass.cuven.us/api/edge/ping?b=0` 是节点 → Worker 这一条。

   可以重复跑：改了参数再跑一遍就是更新，已经签好的证书不会弄丢。
3. **App 里打开**：账户页打开「Cuven Pass Pro」，点「测速对比」看普通线路和 Pass Pro 各多快。

VPS 上原来的 rclone（8080 端口）不受影响，节点只占 80 / 443。

## 节点只做什么

| 路径 | 处理 |
| --- | --- |
| `/hls/` | 转给 Worker。缓存跟着 Worker 的缓存头走：主列表、`info.json` 是 `no-store`，不缓存；二级列表、分段是 `max-age=86400`，缓存一天 |
| `/stream/` | 直链。大文件按 4 MB 一片取、一片一片缓存，拖进度条只补那几片。缓存键只认文件路径，不认每次换的签名，同一部片谁来看都命中同一份 |
| `/api/edge/ping` | 测速、健康检查，转给 Worker，不缓存 |
| `/__pass/ping` | 节点自己活着没有 |
| 别的 | 一律 404。不是开放代理，上游是写死的 |

缓存规则：
- 缓存在 `/var/cache/cuven-pass`，上限 30 GB，7 天没人看的会清掉。
- 同一片同时有人要，只回源一次。
- 上游出错时，有旧的先用旧的。
- 响应头 `X-Cuven-Pass: HIT / MISS` 表示是不是从缓存出的。

> 现在 Worker 没开签名（`AUTH_SECRET` 为空），直链按路径缓存和直连一样是公开的。
> 以后开了签名，缓存里的直链在 7 天内不再验签；要严格就把 `install.sh` 里 `/stream/` 那一段的 `proxy_cache_key` 加上 `$arg_sig`。

## App 那一边

代码在 `ios/Cuven/Core/PassPro.swift`。

**怎么判断节点能不能用：**
- 播放前看一眼节点能不能用。问的是节点转到 Worker 的那一条（`/api/edge/ping?b=0`），节点自己活着、到 Worker 不通也算不能用。
- 5 分钟内确认过的不再问；没确认过最多等 2.5 秒。
- 不能用就走普通线路。

**播放中出错：** 节点出错（起播失败、播到一半断了）时，播放器从当前位置改走普通线路接着放。节点 10 分钟内不再用。

**账户页这一组三行：**
- 开关。
- 加速节点状态：「已连接 · 延迟 38 毫秒」/「暂时不可用，正在使用普通线路」，点一下重新检测。
- 测速对比：普通线路和 Pass Pro 各下同样大小的随机数据。

## 卸载

```sh
rm /etc/nginx/conf.d/cuven-pass.conf /etc/nginx/snippets/cuven-pass-proxy.conf
systemctl reload nginx
rm -rf /var/cache/cuven-pass
```

App 里关掉开关，或者节点不通，都自动走普通线路。
