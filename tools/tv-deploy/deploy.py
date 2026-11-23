"""把前端发布到 tv.cuven.us（Worker cuven-tv）：index.html、pair.js、pair-density.png 作为模块打进一个小 Worker（worker.js）。

    CLOUDFLARE_API_TOKEN=… python3 tools/tv-deploy/deploy.py

要的令牌权限：Workers Scripts – Edit。为什么不用 `wrangler deploy` 的静态资源：两种都行（`cd web && npx wrangler deploy`
走 web/wrangler.jsonc，静态资源 + 单页回退）；这个脚本只走普通的脚本上传接口，在资源上传被代理挡住的环境里也能用。
千万别再把 index.html 包成一个字符串贴进控制台：那样 /pair.js 和 /pair-density.png 都会回首页，网页的光学配对加载失败。
"""
import json, os, ssl, sys, uuid, urllib.request

ACCOUNT = os.environ.get('CLOUDFLARE_ACCOUNT_ID', '1a7818b1554ecbeefec7301f1c1bf8d9')
SCRIPT = os.environ.get('CUVEN_TV_SCRIPT', 'cuven-tv')
TOKEN = os.environ.get('CLOUDFLARE_API_TOKEN', 'proxy-injected')     # 云端会话里代理会换成保存好的令牌
here = os.path.dirname(os.path.abspath(__file__))
web = os.path.join(here, '..', '..', 'web')

parts = [
    ('metadata', 'metadata.json', 'application/json', json.dumps({'main_module': 'worker.js', 'compatibility_date': '2026-11-10'}).encode()),
    ('worker.js', 'worker.js', 'application/javascript+module', open(os.path.join(here, 'worker.js'), 'rb').read()),
    ('index.html', 'index.html', 'text/plain', open(os.path.join(web, 'index.html'), 'rb').read()),
    ('pair.txt', 'pair.txt', 'text/plain', open(os.path.join(web, 'pair.js'), 'rb').read()),
    ('pair-density.png', 'pair-density.png', 'application/octet-stream', open(os.path.join(web, 'pair-density.png'), 'rb').read()),
]
b = uuid.uuid4().hex
body = b''.join(f'--{b}\r\nContent-Disposition: form-data; name="{n}"; filename="{f}"\r\nContent-Type: {ct}\r\n\r\n'.encode() + d + b'\r\n'
                for n, f, ct, d in parts) + f'--{b}--\r\n'.encode()
req = urllib.request.Request(f'https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}/workers/scripts/{SCRIPT}', data=body, method='PUT',
                             headers={'Content-Type': f'multipart/form-data; boundary={b}', 'Authorization': f'Bearer {TOKEN}'})
cafile = os.environ.get('SSL_CERT_FILE') or ('/root/.ccr/ca-bundle.crt' if os.path.exists('/root/.ccr/ca-bundle.crt') else None)
ctx = ssl.create_default_context(cafile=cafile)
try:
    j = json.load(urllib.request.urlopen(req, context=ctx, timeout=120))
except urllib.error.HTTPError as e:
    j = json.load(e)
print('发布', '成功' if j.get('success') else '失败', j.get('errors') or '', f'（{len(body) // 1024} KB）')
sys.exit(0 if j.get('success') else 1)
