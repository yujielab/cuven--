// 前端回归：web/index.html 的站内播放器（Playwright + Chromium）
//   node tests/web.mjs            （需要 playwright；PLAYWRIGHT_PATH 可指定其 index.js）
// 静态服务托管 web/index.html，https://stream.cuven.online 的请求转给本地运行的真实 Worker。
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as H from './harness.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
let pw;
try { pw = await import(process.env.PLAYWRIGHT_PATH || 'playwright'); } catch { console.log('跳过：没有 playwright'); process.exit(0); }
const { chromium } = pw.default || pw;
H.env.AUTH_SECRET = '';                       // 与前端现状一致：Worker 未开签名
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ✓', m); } else { fail++; console.log('  ✗', m); } };

const html = fs.readFileSync(path.join(HERE, '..', 'web', 'index.html'));
const srv = http.createServer((q, r) => {
  if (new URL(q.url, 'http://x').pathname !== '/') { r.writeHead(404); r.end(); return; }
  r.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); r.end(html);
});
await new Promise(r => srv.listen(18301, '127.0.0.1', r));
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
await ctx.addInitScript(() => {
  localStorage.setItem('cuven_login', '1');
  localStorage.setItem('cuven_login_ts', String(Date.now()));
  localStorage.setItem('cuven_privacy_consent_v1', JSON.stringify({ v: '2026-07-18', ts: Date.now() }));
  if (location.search.includes('hls=1')) {          /* 冒充 Safari：Apple 的 vendor + 原生 HLS */
    Object.defineProperty(Navigator.prototype, 'vendor', { get: () => 'Apple Computer, Inc.' });
    const orig = HTMLMediaElement.prototype.canPlayType;
    HTMLMediaElement.prototype.canPlayType = function (t) { return /mpegurl/i.test(t) ? 'maybe' : orig.call(this, t); };
  }
});
const hits = [];
await ctx.route('**/*', async route => {
  const u = route.request().url();
  if (u.startsWith('http://127.0.0.1:18301/')) return route.continue();
  if (!u.startsWith('https://stream.cuven.online/')) return route.abort();
  hits.push(new URL(u).pathname);
  const req = route.request();
  const res = await H.worker.fetch(new Request(u, { method: req.method(), headers: req.headers() }), H.env, H.ctx);
  const body = Buffer.from(await res.arrayBuffer());
  await route.fulfill({ status: res.status, headers: Object.fromEntries(res.headers), body });
});

const page = await ctx.newPage();
const errors = [];
page.on('pageerror', e => errors.push(e.message));
/* 已登录用户进站先看到欢迎页（全屏，盖在一切之上），点「确认并继续」才进入应用 */
async function enter(pg, url) {
  await pg.goto(url);
  await pg.waitForFunction(() => typeof playVideo === 'function' && typeof Player === 'object', null, { timeout: 15000 });
  if (await pg.$('#wc-cta')) { await pg.click('#wc-cta'); await pg.waitForSelector('#wc-root', { state: 'detached', timeout: 5000 }); }
}
await enter(page, 'http://127.0.0.1:18301/');
ok(true, '页面脚本全部加载（playVideo / Player 已定义），欢迎页已关闭');
ok(await page.evaluate(() => typeof openInfuseDirect === 'undefined' && typeof _cuvenInfuseName === 'undefined'), '旧的 Infuse 入口函数已移除');
ok(!/['"`]infuse:\/\//i.test(html.toString()), '代码里不再拼 infuse:// 链接');
const st = () => page.evaluate(() => {
  const v = document.getElementById('playerVideo');
  return { open: Player.isOpen(), hash: location.hash, view: history.state && history.state.view, src: v.getAttribute('src') || '', net: v.networkState,
    t: v.currentTime, paused: v.paused, err: v.error && v.error.code, msg: document.getElementById('pvMsg').textContent,
    badge: document.getElementById('pvBadge').hidden ? '' : document.getElementById('pvBadge').textContent,
    next: !document.getElementById('pvNext').hidden, nextT: document.getElementById('pvNextT').textContent,
    prog: JSON.parse(localStorage.getItem('play_progress_v1') || '{}'), cw: JSON.parse(localStorage.getItem('continue_watching_v2') || '{}') };
});

console.log('\n■ MP4 直链播放、续播、返回关闭');
await page.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await page.waitForFunction(() => document.getElementById('playerVideo').currentTime > 0.5, null, { timeout: 20000 });
let s = await st();
ok(s.open && s.hash === '#play' && s.view === 'player', `播放器打开，历史栈 #play（${s.hash} / ${s.view}）`);
ok(/\/stream\/Cuven%20.*\?path=%2FMovies%2Flong\.mp4&safari=1$/.test(s.src) && !s.paused, `直链 + safari=1，正在播放（t=${s.t.toFixed(1)}s）`);
await page.evaluate(() => { const v = document.getElementById('playerVideo'); v.currentTime = 95; });
await page.waitForFunction(() => document.getElementById('playerVideo').currentTime > 95.5, null, { timeout: 15000 });
await page.evaluate(() => document.getElementById('playerVideo').pause());
s = await st();
ok(s.prog['/Movies/long.mp4'] && Math.abs(s.prog['/Movies/long.mp4'].pos - 96) <= 2, `暂停即记进度（pos=${s.prog['/Movies/long.mp4'] && s.prog['/Movies/long.mp4'].pos}s / dur=${s.prog['/Movies/long.mp4'] && s.prog['/Movies/long.mp4'].dur}s）`);
await page.goBack();
await page.waitForTimeout(400);
s = await st();
ok(!s.open && !s.src && s.net === 0, `返回键关闭播放器并释放 <video>（open=${s.open}，networkState=${s.net}）`);
ok(s.hash !== '#play' && s.view !== 'player', `历史栈退回原页面（${s.hash || '(无 hash)'}）`);
ok(!!s.cw['/Movies/long.mp4'], '已写入「继续观看」');
await page.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await page.waitForFunction(() => document.getElementById('playerVideo').currentTime > 90, null, { timeout: 20000 });
s = await st();
ok(s.t > 90, `再次打开从上次位置续播（t=${s.t.toFixed(1)}s）`);
await page.keyboard.press('Escape');
await page.waitForTimeout(300);
ok(!(await st()).open, 'Esc 关闭播放器');

console.log('\n■ 剧集：播完自动接下一集');
await page.evaluate(() => {
  const eps = [{ ep: 1, path: '/Movies/long.mp4', name: 'Show.S01E01.mp4', epTitle: '第一集' }, { ep: 2, path: '/Movies/long_ep2.mp4', name: 'Show.S01E02.mp4', epTitle: '第二集' }];
  tvPlayEp('series-x', eps[0], eps);
});
await page.waitForFunction(() => document.getElementById('playerVideo').currentTime > 0.5, null, { timeout: 20000 });
await page.evaluate(() => { const v = document.getElementById('playerVideo'); v.currentTime = v.duration - 1; });
await page.waitForFunction(() => !document.getElementById('pvNext').hidden, null, { timeout: 15000 });
s = await st();
ok(s.next && /第 2 集/.test(s.nextT), `片尾出现「下一集」倒计时（${s.nextT}）`);
await page.click('#pvNextGo');
await page.waitForFunction(() => /long_ep2/.test(document.getElementById('playerVideo').currentSrc) && document.getElementById('playerVideo').currentTime > 0.3, null, { timeout: 15000 });
ok(true, '点「立即播放」切到第 2 集');
ok(!(await st()).prog['/Movies/long.mp4'], '看完的第 1 集清掉了续播位置');
await page.goBack(); await page.waitForTimeout(300);

console.log('\n■ Chrome：MKV 走直连（它的原生 HLS 遇到解不了的 CODECS 会整条拒播）');
await page.evaluate(() => playVideo('/Movies/avc_zsub.mkv', 'Some.Movie.2021.1080p.mkv'));
await page.waitForFunction(() => { const v = document.getElementById('playerVideo'); return v.currentTime > 0.5 || !document.getElementById('pvState').hidden && document.getElementById('pvState').classList.contains('err'); }, null, { timeout: 20000 });
s = await st();
ok(/\/stream\/Cuven%20.*\?path=%2FMovies%2Favc_zsub\.mkv$/.test(s.src), 'MKV 交给 /stream 直连（不带 safari=1）');
ok(s.t > 0.5 || /浏览器解不了/.test(s.msg), s.t > 0.5 ? `Chromium 直接播放 MKV（t=${s.t.toFixed(1)}s）` : `给出格式说明：${s.msg}`);
await page.keyboard.press('Escape'); await page.waitForTimeout(300);

console.log('\n■ MKV → 原生 HLS（模拟 Safari：Apple vendor + canPlayType）');
const p2 = await ctx.newPage();
p2.on('pageerror', e => errors.push(e.message));
await enter(p2, 'http://127.0.0.1:18301/?hls=1');
hits.length = 0;
await p2.evaluate(() => playVideo('/Movies/dv81.mkv', 'Movie.2024.2160p.DV.mkv'));
await p2.waitForFunction(() => /master\.m3u8/.test(document.getElementById('playerVideo').src), null, { timeout: 20000 });
const s2 = await p2.evaluate(() => ({ src: document.getElementById('playerVideo').src, badge: document.getElementById('pvBadge').textContent }));
ok(/\/hls\/0\.0\.[A-Za-z0-9_-]+\/master\.m3u8$/.test(s2.src), 'MKV 交给 /hls/…/master.m3u8');
ok(s2.badge === 'Dolby Vision', `徽章按码流实测：${s2.badge}`);
ok(hits.includes('/api/stream-sign') && hits.some(h => h.endsWith('/info.json')), '先取签名与 info.json（顺带建索引）');

console.log('\n■ 文件弹层');
await page.evaluate(() => openSheetForFile('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
const sheet = await page.evaluate(() => document.getElementById('sheetBody').textContent);
ok(/播放/.test(sheet) && /复制直链/.test(sheet) && !/Infuse/.test(sheet), `弹层：${sheet.replace(/\s+/g, ' ').trim().slice(0, 60)}`);

console.log('\n■ Worker 自带的 /watch 页');
for (const [label, q] of [['Chrome', ''], ['Safari（模拟）', '&hls=1']]) {
  const pg = await ctx.newPage();
  pg.on('pageerror', e => errors.push('watch: ' + e.message));
  await pg.goto('https://stream.cuven.online/watch?path=' + encodeURIComponent('/Movies/avc_zsub.mkv') + q);
  const src = await pg.waitForFunction(() => { const v = document.querySelector('video'); return v && v.src ? v.src : false; }, null, { timeout: 20000 }).then(h => h.jsonValue()).catch(() => '');
  ok(label === 'Chrome' ? /\/stream\//.test(src) : /\/hls\/.*master\.m3u8/.test(src), `${label} → ${src.replace(/^https:\/\/[^/]+/, '').replace(/\?.*$/, '').slice(0, 60)}`);
  await pg.close();
}

ok(!errors.length, `页面无脚本错误${errors.length ? '：' + errors.slice(0, 3).join(' | ') : ''}`);
await browser.close(); srv.close();
console.log(`\n${fail ? '✗' : '✓'} ${pass} 通过，${fail} 失败`);
process.exit(fail ? 1 : 0);
