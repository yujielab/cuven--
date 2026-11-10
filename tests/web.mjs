// 前端回归：web/index.html 的播放页（iOS sheet）、字幕、剧集、预告片、优选入口（Playwright + Chromium）
//   node tests/web.mjs            （需要 playwright；PLAYWRIGHT_PATH 可指定其 index.js）
// 静态服务托管 web/index.html，发往 stream.cuven.online（以及测试用的第二入口 s2.test）的请求交给本地运行的真实 Worker。
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as H from './harness.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
let pw;
try { pw = await import(process.env.PLAYWRIGHT_PATH || 'playwright'); } catch { console.log('跳过：没有 playwright'); process.exit(0); }
const { chromium, devices } = pw.default || pw;
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
const ORIGIN = 'http://127.0.0.1:18301/';
const TRAILER = 'https://stream.cuven.online/stream/t.mp4?path=' + encodeURIComponent('/Movies/long.mp4') + '&safari=1';
const hits = [];
const errors = [];
let pingDelay = 0;

async function context(opts = {}, apple = false, probe = false) {
  const ctx = await browser.newContext(opts);
  await ctx.addInitScript(([a, probe]) => {
    localStorage.setItem('cuven_login', '1');
    localStorage.setItem('cuven_login_ts', String(Date.now()));
    localStorage.setItem('cuven_privacy_consent_v1', JSON.stringify({ v: '2026-07-18', ts: Date.now() }));
    /* 默认不测速（只有一个入口）；测优选入口那一节从空白开始 */
    if (probe) { if (!sessionStorage.getItem('probe')) { sessionStorage.setItem('probe', '1'); localStorage.removeItem('cuven_edge_v1'); } }
    else if (!localStorage.getItem('cuven_edge_v1')) localStorage.setItem('cuven_edge_v1', JSON.stringify({ host: 'stream.cuven.online', ts: Date.now() }));
    if (a || location.search.includes('hls=1')) {          /* 冒充 Safari：Apple 的 vendor + 原生 HLS */
      Object.defineProperty(Navigator.prototype, 'vendor', { get: () => 'Apple Computer, Inc.' });
      const orig = HTMLMediaElement.prototype.canPlayType;
      HTMLMediaElement.prototype.canPlayType = function (t) { return /mpegurl/i.test(t) ? 'maybe' : orig.call(this, t); };
    }
  }, [apple, probe]);
  await ctx.route('**/*', async route => {
    const u = route.request().url();
    if (u.startsWith(ORIGIN)) return route.continue();
    const url = new URL(u);
    if (url.host !== 'stream.cuven.online' && url.host !== 's2.test') return route.abort();
    hits.push(url.host + url.pathname);
    if (url.pathname === '/api/imdb/video') {
      return route.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' },
        body: JSON.stringify({ id: 'tt1', video: { best: TRAILER, mp4: { '720p': TRAILER, '1080p': TRAILER }, thumb: null }, stills: [] }) });
    }
    if (url.pathname === '/api/edge/ping' && url.host === 'stream.cuven.online' && pingDelay) await new Promise(r => setTimeout(r, pingDelay));
    const req = route.request();
    const res = await H.worker.fetch(new Request(u, { method: req.method(), headers: req.headers() }), H.env, H.ctx);
    await route.fulfill({ status: res.status, headers: Object.fromEntries(res.headers), body: Buffer.from(await res.arrayBuffer()) });
  });
  return ctx;
}
/* 已登录用户进站先看到欢迎页（全屏，盖在一切之上），点「确认并继续」才进入应用 */
async function enter(ctx, q = '') {
  const pg = await ctx.newPage();
  pg.on('pageerror', e => errors.push(e.message));
  await pg.goto(ORIGIN + q);
  await pg.waitForFunction(() => typeof playVideo === 'function' && typeof Player === 'object', null, { timeout: 15000 });
  if (await pg.$('#wc-cta')) { await pg.click('#wc-cta'); await pg.waitForSelector('#wc-root', { state: 'detached', timeout: 5000 }); }
  return pg;
}
const st = pg => pg.evaluate(() => {
  const s = document.getElementById('playerSheet'), v = s && s.querySelector('video');
  return {
    on: !!(s && s.classList.contains('on')), hash: location.hash, view: history.state && history.state.view,
    src: v ? (v.getAttribute('src') || '') : '', net: v ? v.networkState : -1, t: v ? v.currentTime : 0, paused: v ? v.paused : true,
    idle: !!(s && s.querySelector('.dp-box.idle')), cues: s ? s.querySelector('.dp-cues').innerText.trim() : '',
    ncue: s ? s.querySelectorAll('.dp-cue').length : 0, subsRow: s ? s.querySelector('[data-v="subs"]').textContent : '',
    tags: s ? s.querySelector('.ps-tags').innerText : '', chip: s ? (s.querySelector('.dp-chip').hidden ? '' : s.querySelector('.dp-chip').innerText) : '',
    next: !!(s && !s.querySelector('.dp-next').hidden), nextT: s ? s.querySelector('.dp-next-t').textContent : '',
    eps: s ? Array.from(s.querySelectorAll('.ps-ep')).map(x => x.textContent.trim()) : [],
    msg: s ? s.querySelector('.dp-msg').textContent : '',
    prog: JSON.parse(localStorage.getItem('play_progress_v1') || '{}'), cw: JSON.parse(localStorage.getItem('continue_watching_v2') || '{}'),
    pref: localStorage.getItem('cuven_sub_pref_v1'),
  };
});
const vid = '#playerSheet video';
const until = (pg, fn, arg, ms = 20000) => pg.waitForFunction(fn, arg, { timeout: ms });
const pickMenu = async (pg, re) => {
  await pg.click('[data-k="row-subs"]');
  await pg.waitForTimeout(150);
  await pg.evaluate(src => { const r = new RegExp(src); const b = Array.from(document.querySelectorAll('.ps-pick .ps-row')).find(x => r.test(x.textContent)); b && b.click(); }, re);
  await pg.waitForTimeout(200);
};

const desk = await context({ viewport: { width: 1280, height: 800 } });
const page = await enter(desk);
ok(true, '页面脚本全部加载（playVideo / Player 已定义），欢迎页已关闭');
ok(await page.evaluate(() => typeof openInfuseDirect === 'undefined' && typeof _cuvenInfuseName === 'undefined'), '旧的 Infuse 入口函数已移除');
ok(!/['"`]infuse:\/\//i.test(html.toString()), '代码里不再拼 infuse:// 链接');

console.log('\n■ 播放页（iOS sheet）· MP4 直连');
await page.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(page, s => document.querySelector(s) && document.querySelector(s).currentTime > 0.5, vid);
let s = await st(page);
ok(s.on && s.hash === '#play' && s.view === 'player', `sheet 升起，历史栈 #play（${s.hash} / ${s.view}）`);
ok(/\/stream\/Cuven%20.*\?path=%2FMovies%2Flong\.mp4&safari=1$/.test(s.src) && !s.paused, `直链 + safari=1，正在播放（t=${s.t.toFixed(1)}s）`);
ok(await page.evaluate(() => !document.getElementById('detailView').classList.contains('on')), '没有去动详情页（不打开、不嵌入）');
await page.mouse.move(640, 300);
await page.waitForTimeout(3600);
ok((await st(page)).idle, '播放中 3 秒不动，控件自动收起');
const t0 = (await st(page)).t;
await page.mouse.move(640, 320);
await page.click('[data-k="fwd"]');
await page.waitForTimeout(300);
ok((await st(page)).t - t0 > 9, '「前进 10 秒」');
const bar = await (await page.$('.dp-bar')).boundingBox();
await page.mouse.move(bar.x + bar.width * 0.5, bar.y + bar.height / 2);
await page.mouse.down(); await page.mouse.up();
await until(page, s => Math.abs(document.querySelector(s).currentTime - 90) < 3, vid, 10000).catch(() => {});
ok(Math.abs((await st(page)).t - 90) < 3, `拖进度条到一半 → ${(await st(page)).t.toFixed(1)}s`);
await page.evaluate(s => { document.querySelector(s).currentTime = 95; }, vid);
await until(page, s => document.querySelector(s).currentTime > 95.5, vid, 15000);
await page.evaluate(s => document.querySelector(s).pause(), vid);
s = await st(page);
ok(s.prog['/Movies/long.mp4'] && Math.abs(s.prog['/Movies/long.mp4'].pos - 96) <= 2, `暂停即记进度（pos=${s.prog['/Movies/long.mp4'] && s.prog['/Movies/long.mp4'].pos}s）`);
await page.goBack();
await page.waitForTimeout(500);
s = await st(page);
ok(!s.on && !s.src && s.net === 0 && s.hash !== '#play', `返回键收起 sheet 并释放 <video>（networkState=${s.net}）`);
ok(!!s.cw['/Movies/long.mp4'], '已写入「继续观看」');
await page.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(page, s => document.querySelector(s).currentTime > 90, vid);
s = await st(page);
ok(s.t > 90 && /继续播放/.test(s.chip), `再次打开从上次位置续播（t=${s.t.toFixed(1)}s），提示「${s.chip.replace(/\s+/g, ' ')}」`);
await page.keyboard.press('Escape');
await page.waitForTimeout(500);
ok(!(await st(page)).on, 'Esc 收起播放页');

console.log('\n■ 字幕（外挂 .srt → 自己画）');
await page.evaluate(() => { localStorage.removeItem('cuven_sub_pref_v1'); playProgress.remove('/Movies/long.mp4'); playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'); });
await until(page, s => document.querySelector(s).currentTime > 1.8, vid);
s = await st(page);
ok(s.cues === '第一句中文字幕' && s.ncue === 1, `自动选中中文并画出来；重复的 cue 只画一行（${s.ncue} 行：${s.cues}）`);
ok(s.subsRow === '中文', `信息区「字幕」一行显示当前选择：${s.subsRow}`);
await pickMenu(page, 'English');
await page.evaluate(s => { document.querySelector(s).currentTime = 5.5; }, vid);
await until(page, s => document.querySelector(s).currentTime > 5.8, vid, 10000);
await page.waitForTimeout(250);
s = await st(page);
ok(s.cues === 'Second English line' && /"en"/.test(s.pref || ''), `选项面板切到 English，偏好记住（${s.pref}）`);
await pickMenu(page, '关闭');
s = await st(page);
ok(!s.cues && s.subsRow === '关闭' && /off/.test(s.pref || ''), '关闭字幕：画面上清空，偏好记成关闭');
await page.keyboard.press('Escape');
await page.waitForTimeout(400);
await page.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(page, s => document.querySelector(s).currentTime > 1.8, vid);
s = await st(page);
ok(!s.cues && s.subsRow === '关闭', '下次播放沿用「关闭」');
await page.evaluate(() => localStorage.removeItem('cuven_sub_pref_v1'));
await page.keyboard.press('Escape');
await page.waitForTimeout(400);

console.log('\n■ 剧集：接下来 / 片尾接下一集');
await page.evaluate(() => {
  const eps = [{ ep: 1, path: '/Movies/long.mp4', name: 'Show.S01E01.mp4', epTitle: '第一集' }, { ep: 2, path: '/Movies/long_ep2.mp4', name: 'Show.S01E02.mp4', epTitle: '第二集' },
    { ep: 3, path: '/Movies/long_ep2.mp4', name: 'Show.S01E03.mp4', epTitle: '第三集' }];
  tvPlayEp('series-x', eps[0], eps);
});
await until(page, s => document.querySelector(s).currentTime > 0.5, vid);
s = await st(page);
ok(s.eps.length === 2 && /第 2 集/.test(s.eps[0]), `「接下来」列出后面两集（${s.eps.join(' / ')}）`);
await page.evaluate(s => { const v = document.querySelector(s); v.currentTime = v.duration - 1; }, vid);
await until(page, () => !document.querySelector('.dp-next').hidden, null, 15000);
s = await st(page);
ok(s.next && /第 2 集/.test(s.nextT), `片尾出现「下一集」倒计时（${s.nextT}）`);
await page.click('[data-k="next-go"]');
await until(page, s => /long_ep2/.test(document.querySelector(s).currentSrc) && document.querySelector(s).currentTime > 0.3, vid, 15000);
s = await st(page);
ok(s.on && s.eps.length === 1, '「立即播放」就地切到第 2 集，「接下来」只剩第 3 集');
ok(!s.prog['/Movies/long.mp4'], '看完的第 1 集清掉了续播位置');
await page.keyboard.press('Escape');
await page.waitForTimeout(400);

console.log('\n■ Chrome：MKV 走直连（它的原生 HLS 遇到解不了的 CODECS 会整条拒播）');
await page.evaluate(() => playVideo('/Movies/avc_zsub.mkv', 'Some.Movie.2021.1080p.mkv'));
await until(page, s => { const v = document.querySelector(s); return v.currentTime > 0.5 || !document.querySelector('.dp-state').hidden && document.querySelector('.dp-state').classList.contains('err'); }, vid);
s = await st(page);
ok(/\/stream\/Cuven%20.*\?path=%2FMovies%2Favc_zsub\.mkv$/.test(s.src), 'MKV 交给 /stream 直连（不带 safari=1）');
ok(s.t > 0.5 || /浏览器解不了/.test(s.msg), s.t > 0.5 ? `Chromium 直接播放 MKV（t=${s.t.toFixed(1)}s）` : `给出格式说明：${s.msg}`);
await page.keyboard.press('Escape');
await page.waitForTimeout(400);

console.log('\n■ 文件弹层');
await page.evaluate(() => openSheetForFile('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
const sheet = await page.evaluate(() => document.getElementById('sheetBody').textContent);
ok(/播放/.test(sheet) && /复制直链/.test(sheet) && !/Infuse 中打开/.test(sheet), `弹层：${sheet.replace(/\s+/g, ' ').trim().slice(0, 50)}`);
await page.evaluate(() => closeSheet());

console.log('\n■ 展厅预告片');
await page.evaluate(() => navTo('library'));
const tv = await until(page, () => {
  const ch = document.querySelector('.sc-chapter'); const v = ch && ch.querySelector('video');
  return v && v.getAttribute('src') && v.currentTime > 0.3 ? true : false;
}, null, 40000).then(() => true).catch(() => false);
ok(tv, '第一章的预告片地址晚到也会自己挂上开播（不用先滚走再滚回来）');
const trailerPlaying = () => page.evaluate(() => { const v = document.querySelector('.sc-chapter video'); return !!(v && v.getAttribute('src') && !v.paused); });
await page.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(page, s => document.querySelector(s).currentTime > 0.3, vid);
await page.waitForTimeout(300);
ok(!(await trailerPlaying()), '播放页升起：预告片让路');
await page.keyboard.press('Escape');
const back1 = await until(page, () => { const v = document.querySelector('.sc-chapter video'); return !!(v && v.getAttribute('src') && !v.paused); }, null, 8000).then(() => true).catch(() => false);
ok(back1, '播放页收起：预告片接着放');
await page.evaluate(() => { const ch = document.querySelector('.sc-chapter'); openDetail('/Movies/' + ch.dataset.name, ch.dataset.name); });
await page.waitForTimeout(2200);
await page.evaluate(() => closeDetail());
const back2 = await until(page, () => { const v = document.querySelector('.sc-chapter video'); return !!(v && v.getAttribute('src') && !v.paused); }, null, 8000).then(() => true).catch(() => false);
ok(back2, '详情页开过 2 秒（视频被卸下）再关掉：预告片重新挂上开播');
await page.evaluate(() => navTo('home'));
await desk.close();

console.log('\n■ iPhone：下拉收起');
const ip = await context({ ...devices['iPhone 15 Pro'] });
const pi = await enter(ip);
await pi.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(pi, s => document.querySelector(s).currentTime > 0.5, vid);
const hb = await (await pi.$('.ps-head')).boundingBox();
await pi.mouse.move(hb.x + hb.width / 2, hb.y + 24);
await pi.mouse.down();
for (let i = 1; i <= 12; i++) { await pi.mouse.move(hb.x + hb.width / 2, hb.y + 24 + i * 30); await pi.waitForTimeout(16); }
await pi.mouse.up();
await pi.waitForTimeout(700);
s = await st(pi);
ok(!s.on && s.hash !== '#play' && !s.src, '按住头部往下一拉：sheet 收起、历史栈退回、视频释放');
await pi.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(pi, s => document.querySelector(s).currentTime > 0.5, vid);
await pi.mouse.move(hb.x + hb.width / 2, hb.y + 24);
await pi.mouse.down();
for (let i = 1; i <= 3; i++) { await pi.mouse.move(hb.x + hb.width / 2, hb.y + 24 + i * 15); await pi.waitForTimeout(120); }
await pi.waitForTimeout(150);
await pi.mouse.up();
await pi.waitForTimeout(800);
ok((await st(pi)).on, '轻轻拉一下（没过界、松手前停住）：弹回去，不收起');
await ip.close();

console.log('\n■ MKV → 原生 HLS（模拟 Safari：Apple vendor + canPlayType）');
const ap = await context({ viewport: { width: 1280, height: 800 } }, true);
const pa = await enter(ap, '?hls=1');
hits.length = 0;
await pa.evaluate(() => openDetail('/Movies/dv81.mkv', 'Movie.2024.2160p.DV.mkv'));
await until(pa, () => true, null, 1000);
const pre = await pa.waitForFunction(() => true).then(async () => { for (let i = 0; i < 40; i++) { if (hits.some(h => h.endsWith('/info.json'))) return true; await new Promise(r => setTimeout(r, 150)); } return false; });
ok(pre, '打开详情页就预取了签名与 info.json（顺带建好索引）');
const nInfo = hits.filter(h => h.endsWith('/info.json')).length;
await pa.evaluate(() => playVideo('/Movies/dv81.mkv', 'Movie.2024.2160p.DV.mkv'));
await until(pa, s => /master\.m3u8/.test(document.querySelector(s).getAttribute('src') || ''), vid);
s = await st(pa);
ok(/\/hls\/0\.0\.[A-Za-z0-9_-]+\/master\.m3u8$/.test(s.src), 'MKV 交给 /hls/…/master.m3u8');
ok(hits.filter(h => h.endsWith('/info.json')).length === nInfo, '点播放时不再等 info.json（预热结果直接用上）');
ok(/Dolby Vision/.test(s.tags), `播放页标签按码流实测：${s.tags.replace(/\s+/g, ' ')}`);
await pa.keyboard.press('Escape');

console.log('\n■ 优选入口（EDGE_HOSTS）');
H.env.EDGE_HOSTS = 's2.test';
pingDelay = 500;
const ep = await context({ viewport: { width: 1280, height: 800 } }, false, true);
const pe = await enter(ep);
const picked = await pe.waitForFunction(() => { const d = JSON.parse(localStorage.getItem('cuven_edge_v1') || 'null'); return d && d.host; }, null, { timeout: 20000 }).then(h => h.jsonValue()).catch(() => '');
ok(picked === 's2.test', `实测后选中更快的入口：${picked}`);
await pe.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(pe, s => document.querySelector(s).currentTime > 0.5, vid);
s = await st(pe);
ok(s.src.startsWith('https://s2.test/stream/'), `放片走选中的入口：${s.src.slice(0, 40)}…`);
await ep.close();
delete H.env.EDGE_HOSTS;
pingDelay = 0;

console.log('\n■ Worker 自带的 /watch 页');
await ap.close();
const wc = await context({ viewport: { width: 1280, height: 800 } });
for (const [label, q] of [['Chrome', ''], ['Safari（模拟）', '&hls=1']]) {
  const pg = await wc.newPage();
  pg.on('pageerror', e => errors.push('watch: ' + e.message));
  await pg.goto('https://stream.cuven.online/watch?path=' + encodeURIComponent('/Movies/avc_zsub.mkv') + q);
  const src = await pg.waitForFunction(() => { const v = document.querySelector('video'); return v && v.src ? v.src : false; }, null, { timeout: 20000 }).then(h => h.jsonValue()).catch(() => '');
  const want = label === 'Chrome' ? /\/stream\// : /\/hls\/.*master\.m3u8/;
  ok(want.test(src), `${label} → ${src.replace(/^https:\/\/[^/]+/, '').replace(/\?.*$/, '').slice(0, 60)}`);
  await pg.close();
}
await wc.close();

ok(!errors.length, `页面无脚本错误${errors.length ? '：' + errors.slice(0, 3).join(' | ') : ''}`);
await browser.close(); srv.close();
console.log(`\n${fail ? '✗' : '✓'} ${pass} 通过，${fail} 失败`);
process.exit(fail ? 1 : 0);
