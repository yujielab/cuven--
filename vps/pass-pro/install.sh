#!/usr/bin/env bash
# Cuven Pass Pro —— 在 VPS 上装一个只转发影片的加速节点（Worker → VPS → 用户）
#
# 用法（在 VPS 上，root）：
#   curl -fsSL https://raw.githubusercontent.com/yujielab/cuven--/main/vps/pass-pro/install.sh | bash -s -- pass.cuven.us
#   bash install.sh <域名> [上游，默认 https://stream.cuven.online] [缓存上限，默认 30g] [证书邮箱，可不填]
#
# 做的事（可以重复跑：改了参数再跑一遍就是更新）：
#   1. 装 nginx + certbot（Debian / Ubuntu）
#   2. 写 /etc/nginx/conf.d/cuven-pass.conf：
#      · 只转发影片：/hls/（主列表、二级列表、分段）、/stream/（直链）、/api/edge/ping（测速 / 健康检查）；别的一律 404
#        —— 不是开放代理，上游写死
#      · HLS：照 Worker 给的缓存头（主列表、info.json 不缓存；二级列表、分段缓存一天）
#      · 直链：大文件按 4 MB 一片取、一片一片缓存（拖进度条只补那几片）
#      · 同一片同时有人要，只回源一次（cache lock）；上游出错时有旧的先用旧的
#   3. certbot 签 HTTPS 证书（App 只走 HTTPS），80 跳 443
#   4. 防火墙开着的话放行 80 / 443
#
# 前提：域名的 A 记录指向这台 VPS，而且是「仅 DNS」（Cloudflare 灰云）—— 橙云的话流量又绕回 Cloudflare，加速节点白装。
set -euo pipefail

DOMAIN="${1:-}"
UPSTREAM="${2:-https://stream.cuven.online}"
CACHE_MAX="${3:-30g}"
EMAIL="${4:-}"
VER="1.0"

say() { printf '\033[1;32m[Pass Pro]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[Pass Pro]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$DOMAIN" ] || die "用法：bash install.sh <域名> [上游] [缓存上限] [证书邮箱]，例如 bash install.sh pass.cuven.us"
[ "$(id -u)" = 0 ] || die "请用 root 运行（sudo bash install.sh …）"
echo "$DOMAIN" | grep -Eq '^[A-Za-z0-9.-]+$' || die "域名不对：$DOMAIN"
UP_HOST="$(printf '%s' "$UPSTREAM" | sed -E 's#^https?://##; s#/.*$##')"
echo "$UP_HOST" | grep -Eq '^[A-Za-z0-9.-]+(:[0-9]+)?$' || die "上游不对：$UPSTREAM"
echo "$CACHE_MAX" | grep -Eq '^[0-9]+[kmgKMG]$' || die "缓存上限要写成 30g / 500m 这样：$CACHE_MAX"
command -v apt-get >/dev/null || die "只支持 Debian / Ubuntu（apt-get）"

say "安装 nginx、certbot"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y nginx certbot python3-certbot-nginx curl >/dev/null

NGINX_USER="$(ps -o user= -C nginx 2>/dev/null | grep -v root | head -1 || true)"
[ -n "$NGINX_USER" ] || NGINX_USER="www-data"
CACHE_DIR=/var/cache/cuven-pass
mkdir -p "$CACHE_DIR"
chown -R "$NGINX_USER":"$NGINX_USER" "$CACHE_DIR" 2>/dev/null || true

# 直链的分片缓存要 nginx 带 slice 模块（Debian / Ubuntu 的包都带）；没有就只转发、不缓存直链
if nginx -V 2>&1 | grep -q http_slice_module; then SLICE=1; else SLICE=0; say "这个 nginx 没有 slice 模块：直链只转发、不缓存（HLS 照常缓存）"; fi

mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/cuven-pass-proxy.conf <<EOF
# Cuven Pass Pro：回源到 Worker 的公共设置（install.sh 生成；每个 location 都要 include —— 一旦 location 里写了
# proxy_set_header，外层的就不再继承）
proxy_http_version 1.1;
proxy_set_header Host $UP_HOST;
proxy_set_header Connection "";
proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
proxy_set_header X-Cuven-Pass $VER;
proxy_ssl_server_name on;
proxy_ssl_name $UP_HOST;
proxy_ssl_protocols TLSv1.2 TLSv1.3;
proxy_connect_timeout 10s;
proxy_send_timeout 60s;
proxy_read_timeout 120s;
EOF

if [ "$SLICE" = 1 ]; then
STREAM_BLOCK=$(cat <<EOF
    location /stream/ {
        slice 4m;
        include /etc/nginx/snippets/cuven-pass-proxy.conf;
        proxy_set_header Range \$slice_range;
        proxy_cache cuven_pass;
        # 键只认文件路径（和 safari 热修补），不认每次换的签名：同一部片谁来看都命中同一份
        proxy_cache_key "stream|\$arg_path|\$arg_safari|\$slice_range";
        proxy_cache_valid 200 206 7d;
        proxy_ignore_headers Cache-Control Expires Set-Cookie Vary;
        proxy_cache_lock on;
        proxy_cache_lock_timeout 30s;
        proxy_cache_lock_age 30s;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_pass \$cuven_up;
    }
EOF
)
else
STREAM_BLOCK=$(cat <<EOF
    location /stream/ {
        include /etc/nginx/snippets/cuven-pass-proxy.conf;
        proxy_set_header Range \$http_range;
        proxy_buffering off;
        proxy_pass \$cuven_up;
    }
EOF
)
fi

CONF=/etc/nginx/conf.d/cuven-pass.conf
mkdir -p /var/www/html/.well-known/acme-challenge
# 这台机器没有 IPv6 的话不写 [::] 那几行（不然 nginx 起不来）
if [ -f /proc/net/if_inet6 ]; then V6=1; else V6=0; fi

# 写 nginx 配置：有证书就是 443（80 跳 443），没有就先只开 80（给 Let's Encrypt 验证用）
write_conf() {
  local have_cert=0 listen80 listen443
  [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && have_cert=1
  listen80="    listen 80;"
  [ "$V6" = 1 ] && listen80="$listen80
    listen [::]:80;"
  listen443="    listen 443 ssl http2;"
  [ "$V6" = 1 ] && listen443="$listen443
    listen [::]:443 ssl http2;"

  {
    echo "# Cuven Pass Pro $VER —— 只转发影片的加速节点（install.sh 生成；改参数重跑 install.sh）"
    echo "# 上游：$UPSTREAM    缓存：$CACHE_DIR（上限 $CACHE_MAX，7 天没人看的清掉）"
    echo "proxy_cache_path $CACHE_DIR levels=1:2 keys_zone=cuven_pass:100m max_size=$CACHE_MAX inactive=7d use_temp_path=off;"
    echo
    if [ "$have_cert" = 1 ]; then
      cat <<EOF
server {
$listen80
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
$listen443
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:cuvenpass:10m;
    ssl_session_timeout 1d;
EOF
    else
      cat <<EOF
server {
$listen80
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
EOF
    fi
    cat <<EOF

    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;
    set \$cuven_up "https://$UP_HOST";

    add_header X-Cuven-Pass \$upstream_cache_status always;
    client_max_body_size 1m;

    # 节点自己活着没有（不回源）
    location = /__pass/ping {
        default_type application/json;
        add_header Cache-Control "no-store" always;
        return 200 '{"ok":1,"pass":"cuven","ver":"$VER"}';
    }

    # 测速 / 健康检查：转给 Worker，不缓存（App 用它判断「节点 → Worker」这一条通不通、测速对比）
    location = /api/edge/ping {
        include /etc/nginx/snippets/cuven-pass-proxy.conf;
        proxy_cache off;
        proxy_buffering off;
        proxy_pass \$cuven_up;
    }

    # HLS：照 Worker 的缓存头（主列表、info.json no-store 不缓存；二级列表、分段 max-age=86400）
    location /hls/ {
        include /etc/nginx/snippets/cuven-pass-proxy.conf;
        proxy_cache cuven_pass;
        proxy_cache_lock on;
        proxy_cache_lock_timeout 20s;
        proxy_cache_lock_age 30s;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_pass \$cuven_up;
    }

$STREAM_BLOCK

    # 别的一律不转（不是开放代理）
    location / { return 404; }
}
EOF
  } > "$CONF"

  nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx 配置检查没过（见上面）"; }
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
}

write_conf

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  say "防火墙：放行 80 / 443"
  ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null
fi

# 域名是不是指着这台机器（不对也接着装，只是提醒：证书会签不下来）
MYIP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
DNSIP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
if [ -n "$MYIP" ] && [ -n "$DNSIP" ] && [ "$MYIP" != "$DNSIP" ]; then
  say "注意：$DOMAIN 解析到 $DNSIP，这台机器是 $MYIP —— 要么 A 记录没指过来，要么开着 Cloudflare 橙云（要改成仅 DNS）"
fi

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  say "签 HTTPS 证书（Let's Encrypt）"
  if [ -n "$EMAIL" ]; then MAIL=(-m "$EMAIL"); else MAIL=(--register-unsafely-without-email); fi
  certbot certonly --webroot -w /var/www/html -d "$DOMAIN" --non-interactive --agree-tos "${MAIL[@]}" \
      --deploy-hook "systemctl reload nginx" \
    || die "证书没签下来：确认 $DOMAIN 的 A 记录指向这台 VPS、是仅 DNS（灰云）、80 端口能从外面访问，再跑一遍"
  write_conf          # 签好了：换成带 HTTPS 的那一版
fi

say "检查"
PING="$(curl -fsS --max-time 8 "https://$DOMAIN/__pass/ping" 2>/dev/null || true)"
EDGE="$(curl -fsS --max-time 15 -o /dev/null -w '%{http_code}' "https://$DOMAIN/api/edge/ping?b=0" 2>/dev/null || true)"
echo "  节点：${PING:-不通}"
echo "  节点 → Worker：HTTP ${EDGE:-不通}"
if [ "$EDGE" = "200" ]; then
  say "装好了：https://$DOMAIN 。在 App 的账户页打开「Cuven Pass Pro」，再点「测速对比」看看快多少。"
else
  say "节点起来了，但转到 Worker 那一条不通：检查这台 VPS 能不能访问 $UPSTREAM（curl -I $UPSTREAM）"
fi
