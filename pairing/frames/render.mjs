// 用浏览器渲染粒子云（web/pair.js 原样）：node render.mjs <输出目录> '<json>'
//   json：{ times: [秒…], code: [编号, 密钥] | 不给（码关掉，M = 1）, codeT: 码平面的时钟（默认 0）, size: 画布边长（默认 400） }
// 训练用的 360 帧：node render.mjs frames '{"times":[0, 0.02778, …]}'，再 python3 convert.py frames → look-frames.npz
// 需要：Playwright + Chromium（软件 WebGL：swiftshader）。pair.js、pair-density.png 从 web/ 拷过来
import { createRequire } from 'node:module'; const { chromium } = createRequire(import.meta.url)('/opt/node22/lib/node_modules/playwright');
import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path';
const dir = process.cwd(), out = process.argv[2], job = JSON.parse(process.argv[3]), size = job.size || 400;
fs.mkdirSync(out, { recursive: true });
const web = path.join(dir, '..', '..', 'web');
const srv = http.createServer((q, r) => { const u = decodeURIComponent(q.url.split('?')[0]); const f = /pair(\.js|-density\.png)$/.test(u) ? path.join(web, path.basename(u)) : path.join(dir, u); fs.readFile(f, (e, d) => { r.writeHead(e ? 404 : 200, { 'content-type': f.endsWith('.js') ? 'text/javascript' : f.endsWith('.png') ? 'image/png' : 'text/html' }); r.end(d); }); }).listen(8767);
const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const p = await b.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
p.on('pageerror', e => console.log('pageerror', e.message));
await p.goto(`http://localhost:8767/harness.html?size=${size}`);
if (!(await p.evaluate('cloud.ok'))) { console.log('NO WEBGL'); process.exit(1); }
await p.evaluate('atlas');
if (job.code) await p.evaluate(c => cloud.setCode(c[0], c[1]), job.code);
let k = 0;
for (const t of job.times) {
  await p.evaluate(([t, ct]) => cloud.drawAt(t, ct), [t, job.codeT ?? 0]);
  await p.screenshot({ path: path.join(out, String(k++).padStart(4, '0') + '.png'), clip: { x: 0, y: 0, width: size, height: size } });
}
console.log('rendered', k);
await b.close(); srv.close();
