// 前端回归：web/index.html 的播放（加载画面 → 系统全屏）、续播、字幕、剧集、预告片、优选入口（Playwright + Chromium）
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
/* SwiftShader：无头 Chromium 也有 WebGL2，加载画面的极光背景走真实路径 */
const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
const ORIGIN = 'http://127.0.0.1:18301/';
const TRAILER = 'https://stream.cuven.online/stream/t.mp4?path=' + encodeURIComponent('/Movies/long.mp4') + '&safari=1';
const hits = [];
const errors = [];
let pingDelay = 0;
let streamDelay = 0;                          // 放慢 /stream：开播前看清加载画面

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
    if (a) {
      /* 系统播放器的替身：webkitEnterFullscreen 进（没有元数据时照 WebKit 抛 InvalidStateError），
         webkitExitFullscreen 出，各发 webkitbeginfullscreen / webkitendfullscreen；画中画同理 */
      const P = HTMLVideoElement.prototype;
      P.webkitEnterFullscreen = function () {
        if (this.readyState < 1) throw new DOMException('no metadata', 'InvalidStateError');
        if (this.__fs) return;
        this.__fs = true;
        window.__fsIn = (window.__fsIn || 0) + 1;
        window.__fsWhen = { playing: !this.paused && this.readyState >= 3, loader: !!document.querySelector('#nativePlayer .np-load:not([hidden])') };
        this.dispatchEvent(new Event('webkitbeginfullscreen'));
      };
      P.webkitExitFullscreen = function () { if (!this.__fs) return; this.__fs = false; this.dispatchEvent(new Event('webkitendfullscreen')); };
      Object.defineProperty(P, 'webkitDisplayingFullscreen', { configurable: true, get() { return !!this.__fs; } });
      Object.defineProperty(P, 'webkitPresentationMode', { configurable: true, get() { return this.__pm || (this.__fs ? 'fullscreen' : 'inline'); } });
      P.webkitSetPresentationMode = function (m) { this.__pm = m === 'picture-in-picture' ? m : ''; this.dispatchEvent(new Event('webkitpresentationmodechanged')); };
      if (a === 'iphone') {                                   /* iPhone：没有元素全屏，只有视频全屏 */
        Object.defineProperty(Document.prototype, 'fullscreenEnabled', { configurable: true, get: () => false });
        Object.defineProperty(Document.prototype, 'webkitFullscreenEnabled', { configurable: true, get: () => false });
      }
    }
    /* 记下播放器每一次 play() / load()：调用时片源是什么、是不是还在用户手势里 */
    const rec = (k, el) => { if (el.closest && el.closest('#nativePlayer')) (window[k] = window[k] || []).push({ src: el.getAttribute('src') || '', gesture: !!(navigator.userActivation && navigator.userActivation.isActive) }); };
    const play0 = HTMLMediaElement.prototype.play, load0 = HTMLMediaElement.prototype.load;
    HTMLMediaElement.prototype.play = function () { rec('__plays', this); return play0.call(this); };
    HTMLMediaElement.prototype.load = function () { rec('__loads', this); return load0.call(this); };
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
    if (url.pathname.startsWith('/stream/') && streamDelay) await new Promise(r => setTimeout(r, streamDelay));
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
  const r = document.getElementById('nativePlayer'), v = r && r.querySelector('video');
  return {
    on: !!(r && r.classList.contains('on')), hash: location.hash, view: history.state && history.state.view,
    fs: !!(r && (document.fullscreenElement === r || (v && v.__fs))), fsIn: window.__fsIn || 0,
    src: v ? (v.getAttribute('src') || '') : '', net: v ? v.networkState : -1, t: v ? v.currentTime : 0, paused: v ? v.paused : true,
    controls: !!(v && v.controls), inline: !!(v && v.hasAttribute('playsinline')),
    msg: r ? r.querySelector('.np-msg').textContent : '', err: !!(r && !r.querySelector('.np-state').hidden && r.querySelector('.np-state').classList.contains('err')),
    tracks: v ? Array.from(v.textTracks).map(t => t.label + ':' + t.mode) : [],
    detail: document.getElementById('detailView').classList.contains('on'),
    plays: window.__plays || [], loads: window.__loads || [],
    prog: JSON.parse(localStorage.getItem('play_progress_v1') || '{}'), cw: JSON.parse(localStorage.getItem('continue_watching_v2') || '{}'),
  };
});
const vid = '#nativePlayer video';
/* 加载画面的状态：在不在、字样、当前文案、进度、背景是不是 WebGL 画的 */
const loader = pg => pg.evaluate(() => {
  const l = document.querySelector('#nativePlayer .np-load'), bar = l && l.querySelector('.np-bar'), c = l && l.querySelector('canvas');
  return { shown: !!l && !l.hidden && !l.classList.contains('out'), brand: l ? l.querySelector('.np-brand').getAttribute('aria-label') : '',
    text: l ? l.querySelector('.np-brand').textContent : '', tip: l ? l.querySelector('.np-tip').textContent : '',
    p: bar ? parseFloat(bar.style.getPropertyValue('--p') || '0') : -1, now: bar ? +bar.getAttribute('aria-valuenow') : -1,
    webgl: !!c && c.width > 0 && c.height > 0, when: window.__fsWhen || null };
});
const until = (pg, fn, arg, ms = 20000) => pg.waitForFunction(fn, arg, { timeout: ms });
const reset = pg => pg.evaluate(() => { window.__plays = []; window.__loads = []; window.__fsIn = 0; window.__fsWhen = null; });
/* 盯着加载画面的文案：每换一句记下时刻、文字与当时的进度（截图很慢，不能靠 sleep 卡时间） */
const watchTips = pg => pg.evaluate(() => {
  const t0 = performance.now(), log = window.__tips = [];
  const tip = document.querySelector('#nativePlayer .np-tip'), bar = document.querySelector('#nativePlayer .np-bar');
  const v = document.querySelector('#nativePlayer video');
  const rec = () => log.push({ t: Math.round(performance.now() - t0), text: tip.textContent, p: parseFloat(bar.style.getPropertyValue('--p') || '0'), playing: v.currentTime > 0 });
  rec();
  new MutationObserver(rec).observe(tip, { childList: true, characterData: true, subtree: true });
});
/* 打开详情页并等预热（签名 / info.json）回来 */
const detail = async (pg, path, name) => {
  await pg.evaluate(([p, n]) => openDetail(p, n), [path, name]);
  await pg.waitForSelector('#detailPlay', { state: 'visible', timeout: 10000 });
  await pg.waitForTimeout(900);
};

const desk = await context({ viewport: { width: 1280, height: 800 } });
const page = await enter(desk);
ok(true, '页面脚本全部加载（playVideo / Player 已定义），欢迎页已关闭');
ok(await page.evaluate(() => typeof openInfuseDirect === 'undefined' && typeof _cuvenInfuseName === 'undefined'), '旧的 Infuse 入口函数已移除');
ok(!/['"`]infuse:\/\//i.test(html.toString()), '代码里不再拼 infuse:// 链接');
ok(!/playerSheet|class="ps[ -]|dp-box/.test(html.toString()), 'sheet 播放页与自绘控件已整个移除');

console.log('\n■ 点「播放」直接进全屏 · 桌面 Chromium（整块全屏）· MP4 直连');
await detail(page, '/Movies/long.mp4', 'Long.Test.2024.1080p.mp4');
await reset(page);
await page.click('#detailPlay');
await until(page, s => document.querySelector(s) && document.querySelector(s).currentTime > 0.5, vid);
let s = await st(page);
ok(s.on && s.fs && s.hash === '#play' && s.view === 'player', `一点就是全屏播放（全屏 ${s.fs}，历史栈 ${s.hash}）`);
ok(s.plays.length && s.plays[0].gesture && /\/stream\//.test(s.plays[0].src), 'play() 在点击的手势里发起，片源当场就有（打开详情页时已预热）');
ok(/\/stream\/Cuven%20.*\?path=%2FMovies%2Flong\.mp4&safari=1$/.test(s.src) && !s.paused, `直链 + safari=1，正在播放（t=${s.t.toFixed(1)}s）`);
ok(s.controls && s.inline, '用浏览器 / 系统的原生控件（<video controls playsinline>：先在播放层里起播，开播再进系统全屏）');
await page.evaluate(s => { document.querySelector(s).currentTime = 95; }, vid);
await until(page, s => document.querySelector(s).currentTime > 95.5, vid, 15000);
await page.evaluate(s => document.querySelector(s).pause(), vid);
s = await st(page);
ok(s.prog['/Movies/long.mp4'] && Math.abs(s.prog['/Movies/long.mp4'].pos - 96) <= 2, `暂停即记进度（pos=${s.prog['/Movies/long.mp4'] && s.prog['/Movies/long.mp4'].pos}s）`);
await page.evaluate(() => document.exitFullscreen());
await page.waitForTimeout(600);
s = await st(page);
ok(!s.on && !s.src && s.net === 0, `退出全屏就是关掉播放器，<video> 释放（networkState=${s.net}）`);
ok(s.detail && s.hash === '#detail', `底下的详情页原样还在（${s.hash}）—— 播放器自己退的那格历史没有误关详情页`);
ok(!!s.cw['/Movies/long.mp4'], '已写入「继续观看」');
await page.click('#detailPlay');
await until(page, s => document.querySelector(s).currentTime > 90, vid);
s = await st(page);
ok(s.t > 90 && s.fs, `再次播放从上次的位置接着放（t=${s.t.toFixed(1)}s）`);
await page.keyboard.press('Escape');
await page.waitForTimeout(600);
s = await st(page);
ok(!s.on && s.detail, 'Esc：退出全屏并关掉播放器，详情页还在');
await page.click('#detailPlay');
await until(page, s => document.querySelector(s).currentTime > 0.3, vid);
await page.goBack();
await page.waitForTimeout(600);
s = await st(page);
ok(!s.on && !s.src && s.detail, '返回键：关掉播放器，详情页还在');

console.log('\n■ 加载画面 · 桌面（点下去就整块全屏，加载画面在全屏里）');
await detail(page, '/Movies/long_ep2.mp4', 'Other.Movie.2023.1080p.mp4');
streamDelay = 2500;
await reset(page);
await page.click('#detailPlay');
await page.waitForTimeout(500);
let L = await loader(page);
s = await st(page);
ok(L.shown && s.fs && s.t === 0, `点下去：全屏的播放层里先是加载画面，视频还没开播（全屏 ${s.fs}，t=${s.t}）`);
await until(page, s => document.querySelector(s).currentTime > 0.3, vid, 20000);
await page.waitForTimeout(900);
L = await loader(page);
ok(!L.shown && !(await st(page)).paused, '开播后加载画面淡出，视频在全屏里播放');
streamDelay = 0;
await page.keyboard.press('Escape');
await page.waitForTimeout(500);
await page.evaluate(() => closeDetail());
await page.waitForTimeout(400);

console.log('\n■ 全屏被拒（权限 / 环境不允许）：黑底层本身就是播放器');
await page.evaluate(() => {
  window.__rfs = Element.prototype.requestFullscreen;
  Element.prototype.requestFullscreen = () => Promise.reject(new TypeError('denied'));
  playProgress.remove('/Movies/long.mp4');
  playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4');
});
await until(page, s => document.querySelector(s).currentTime > 0.5, vid);
s = await st(page);
ok(s.on && !s.fs && !s.paused && s.controls, '进不了全屏：在黑底层里用原生控件照样播');
const box = await page.evaluate(() => { const r = document.getElementById('nativePlayer').getBoundingClientRect(); return [r.width, r.height]; });
ok(box[0] === 1280 && box[1] === 800, `黑底层盖满视口（${box.join('×')}）`);
await page.click('#nativePlayer .np-x');
await page.waitForTimeout(500);
ok(!(await st(page)).on, '关闭键关掉播放器');
await page.evaluate(() => { Element.prototype.requestFullscreen = window.__rfs; });

console.log('\n■ 字幕：直连挂同目录外挂字幕，中文默认打开（显示交给原生播放器）');
await page.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(page, s => document.querySelector(s).textTracks.length >= 2, vid);
s = await st(page);
ok(s.tracks.includes('中文:showing') && s.tracks.includes('English:disabled'), `外挂字幕：${s.tracks.join(' / ')}`);
await page.keyboard.press('Escape');
await page.waitForTimeout(400);

console.log('\n■ 剧集：播完直接接下一集');
await page.evaluate(() => {
  const eps = [{ ep: 1, path: '/Movies/long.mp4', name: 'Show.S01E01.mp4', epTitle: '第一集' }, { ep: 2, path: '/Movies/long_ep2.mp4', name: 'Show.S01E02.mp4', epTitle: '第二集' }];
  tvPlayEp('series-x', eps[0], eps);
});
await until(page, s => document.querySelector(s).currentTime > 0.5, vid);
await page.evaluate(s => { const v = document.querySelector(s); v.currentTime = v.duration - 1; }, vid);
await until(page, s => /long_ep2/.test(document.querySelector(s).getAttribute('src') || '') && document.querySelector(s).currentTime > 0.3, vid, 20000);
s = await st(page);
ok(s.on && /long_ep2/.test(s.src), '片尾就地切到第 2 集接着放，不回详情页');
ok(!s.prog['/Movies/long.mp4'], '看完的第 1 集清掉了续播位置');
await page.keyboard.press('Escape');
await page.waitForTimeout(400);

console.log('\n■ Chrome：MKV 走直连（它的原生 HLS 遇到解不了的 CODECS 会整条拒播）');
await page.evaluate(() => playVideo('/Movies/avc_zsub.mkv', 'Some.Movie.2021.1080p.mkv'));
await until(page, s => { const v = document.querySelector(s); return v.currentTime > 0.5 || document.querySelector('#nativePlayer .np-state.err:not([hidden])'); }, vid);
s = await st(page);
ok(/\/stream\/Cuven%20.*\?path=%2FMovies%2Favc_zsub\.mkv$/.test(s.src) || s.err, 'MKV 交给 /stream 直连（不带 safari=1）');
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
ok(!(await trailerPlaying()), '播放时预告片让路');
await page.keyboard.press('Escape');
const back1 = await until(page, () => { const v = document.querySelector('.sc-chapter video'); return !!(v && v.getAttribute('src') && !v.paused); }, null, 8000).then(() => true).catch(() => false);
ok(back1, '关掉播放器：预告片接着放');
await page.evaluate(() => { const ch = document.querySelector('.sc-chapter'); openDetail('/Movies/' + ch.dataset.name, ch.dataset.name); });
await page.waitForTimeout(2200);
await page.evaluate(() => closeDetail());
const back2 = await until(page, () => { const v = document.querySelector('.sc-chapter video'); return !!(v && v.getAttribute('src') && !v.paused); }, null, 8000).then(() => true).catch(() => false);
ok(back2, '详情页开过 2 秒（视频被卸下）再关掉：预告片重新挂上开播');
await page.evaluate(() => navTo('home'));
await desk.close();

console.log('\n■ iPhone（系统播放器的替身：webkitEnterFullscreen / webkitendfullscreen）');
const ip = await context({ ...devices['iPhone 15 Pro'] }, 'iphone');
const pi = await enter(ip);
await detail(pi, '/Movies/long.mp4', 'Long.Test.2024.1080p.mp4');
await reset(pi);
await pi.tap('#detailPlay');
await until(pi, s => document.querySelector(s) && document.querySelector(s).currentTime > 0.5, vid);
s = await st(pi);
ok(s.plays.length && s.plays[0].gesture && /\/stream\//.test(s.plays[0].src), '点按的手势里就带着片源 play()（iOS 允许出声播放、之后进全屏不必再要手势）');
const w0 = (await loader(pi)).when;
ok(s.inline && s.fs && s.fsIn === 1 && w0 && w0.playing, `先在加载画面后面起播，开播那一刻才进系统全屏（webkitEnterFullscreen ${s.fsIn} 次，调用时已在播放：${w0 && w0.playing}）`);
await pi.evaluate(s => document.querySelector(s).webkitExitFullscreen(), vid);
await pi.waitForTimeout(500);
s = await st(pi);
ok(!s.on && !s.src && s.detail && s.hash === '#detail', '关掉系统播放器：回到详情页，视频释放');
/* 预热没赶上（从文件弹层直接点播放）：手势里先 load() 把元素解锁，片源回来再播、再进全屏 */
await pi.evaluate(() => closeDetail());
await pi.waitForTimeout(400);
await pi.evaluate(() => openSheetForFile('/Movies/long_ep2.mp4', 'Other.Movie.2023.mp4'));
await pi.waitForTimeout(400);
await reset(pi);
await pi.tap('#sheetBody .sheet-btn');
await until(pi, s => document.querySelector(s).currentTime > 0.5, vid);
s = await st(pi);
ok(s.loads.length && s.loads[0].gesture && s.fs, '预热没赶上：手势里先 load() 解锁，片源回来后照样开播并进系统全屏');
/* 画中画：从系统播放器进画中画 → 接着放、黑底撤掉；画中画里叉掉 → 停下 */
await pi.evaluate(s => { const v = document.querySelector(s); v.webkitSetPresentationMode('picture-in-picture'); v.webkitExitFullscreen(); }, vid);
await pi.waitForTimeout(400);
s = await st(pi);
ok(!s.on && s.src && !s.paused, '进画中画：接着放，黑底层撤掉');
ok(await pi.evaluate(() => !document.documentElement.classList.contains('player-open') && location.hash !== '#play'), '画中画播放时页面可以照常滚动、历史栈已退回');
await pi.evaluate(s => { const v = document.querySelector(s); v.pause(); v.webkitSetPresentationMode('inline'); }, vid);
await pi.waitForTimeout(400);
s = await st(pi);
ok(!s.src && !s.on, '画中画里叉掉：停下并释放');
await ip.close();

console.log('\n■ 加载画面 · iPhone（极光背景 + Cuven max + 胶囊进度条 + 模糊轮播文案）');
{
  const ip2 = await context({ ...devices['iPhone 15 Pro'] }, 'iphone');
  const p2 = await enter(ip2);
  await detail(p2, '/Movies/long.mp4', 'Long.Test.2024.1080p.mp4');
  streamDelay = 8000;
  await reset(p2);
  await p2.tap('#detailPlay');
  await watchTips(p2);
  await p2.waitForTimeout(300);
  const A = await loader(p2), s0 = await st(p2);
  ok(A.shown && !s0.fs && s0.t === 0, '点下去先是加载画面，系统播放器还没打开');
  ok(A.brand === 'Cuven max' && /^Cuven\s*max$/.test(A.text), `画面中央叠着「${A.text.replace(/max$/, ' max')}」`);
  ok(A.webgl, '背景是 WebGL2 画的极光（Aurora Flow 复刻）');
  const clip = { x: 0, y: 0, width: 120, height: 120 };
  const f1 = await p2.screenshot({ clip, scale: 'css' });
  await p2.waitForTimeout(400);
  const f2 = await p2.screenshot({ clip, scale: 'css' });
  ok(!f1.equals(f2), '背景在动');
  await until(p2, s => document.querySelector(s).currentTime > 0.3, vid, 40000);
  const A2 = await loader(p2), s2 = await st(p2);
  ok(A2.when && A2.when.playing && A2.when.loader && s2.fs, '开播那一刻进系统全屏（加载画面一直盖到这时）');
  await p2.waitForTimeout(900);
  const A3 = await loader(p2);
  const tips = await p2.evaluate(() => window.__tips);
  const before = tips.filter(x => !x.playing);
  const want = ['请保持屏幕亮起', '正在渲染绚烂颜色', '正在预热画面质量', '正在添加全景声系统', '正在为您的设备优化'];
  const order = before.map(x => x.text);
  const gaps = before.slice(1).map((x, i) => x.t - before[i].t);
  ok(order.length >= 3 && order.every((t, i) => t === want[i]) && gaps.every(g => g > 2100 && g < 2900),
    `文案按顺序一句句换：${order.join(' → ')}（间隔 ${gaps.join(' / ')} ms）`);
  const ps = before.map(x => x.p);
  ok(ps.every((p, i) => p > 0 && p < 0.95 && (!i || p >= ps[i - 1])), `开播前进度只增不减、不走满：${ps.map(p => Math.round(p * 100) + '%').join(' → ')}`);
  ok(!A3.shown, '开播后加载画面收起');
  streamDelay = 0;
  await ip2.close();
}

console.log('\n■ iPhone Duo（Safari 27.1 实测视口：折起 382×580 / 594×368，展开 669×825 / 951×543）');
const DUO = { isMobile: true, hasTouch: true, screen: { width: 466, height: 678 },
  userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 27_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Mobile/15E148 Safari/604.1' };
{
  const wc = await context({ ...DUO, viewport: { width: 594, height: 368 } });
  const pw0 = await wc.newPage();
  await pw0.goto(ORIGIN);
  await pw0.waitForSelector('#wc-cta');
  const clear = await pw0.evaluate(() => document.getElementById('wc-avatar').getBoundingClientRect().bottom <= document.getElementById('wc-cta').getBoundingClientRect().top);
  ok(clear, '折起横拿：欢迎页的头像与「确认并继续」不再叠在一起');
  await wc.close();
}
const duo = await context({ ...DUO, viewport: { width: 382, height: 580 } });
const pd = await enter(duo);
await pd.waitForTimeout(1500);
for (const [w, h, label] of [[382, 580, '折起竖拿'], [594, 368, '折起横拿'], [669, 825, '展开竖拿'], [951, 543, '展开横拿']]) {
  await pd.setViewportSize({ width: w, height: h });
  await pd.waitForTimeout(800);
  const g = await pd.evaluate(() => {
    const card = document.querySelector('.hcard.is-center') || document.querySelector('.hcard');
    const r = e => e && e.getBoundingClientRect();
    const dock = r(document.querySelector('.dock')), play = r(card && card.querySelector('.btn-play')), dots = r(document.querySelector('.aap-host .all-access-pass'));
    return { ok: !!(dock && play && dots) && play.bottom <= dock.top && dots.bottom <= dock.top && play.top >= 0,
      sw: document.documentElement.scrollWidth, vw: innerWidth };
  });
  ok(g.ok && g.sw === g.vw, `${label} ${w}×${h}：主视觉的按钮与轮播点都在导航条之上，没有横向溢出`);
}
await pd.setViewportSize({ width: 594, height: 368 });
await pd.evaluate(() => openDetail('/Movies/dv81.mkv', 'Dune.Part.Two.2024.2160p.DV.mkv'));
await pd.waitForTimeout(1800);
ok(await pd.evaluate(() => { const b = document.getElementById('detailPlay'); const r = b && b.getBoundingClientRect(); return !!r && r.top >= 0 && r.bottom <= innerHeight; }),
  '折起横拿：详情页的「播放」在第一屏（原来最小高度 540 把它挤到屏幕外）');
await pd.evaluate(() => closeDetail());
await pd.waitForTimeout(500);
await pd.setViewportSize({ width: 951, height: 543 });
await pd.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(pd, s => document.querySelector(s).currentTime > 0.5, vid);
const nb = await pd.evaluate(() => { const r = document.getElementById('nativePlayer').getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)]; });
ok(nb[0] === 951 && nb[1] === 543, `展开横拿：播放层盖满视口（${nb.join('×')}）`);
await pd.keyboard.press('Escape');
await duo.close();

console.log('\n■ Mac / iPad 上的 Safari（模拟：Apple vendor + canPlayType + 系统全屏替身）');
const ap = await context({ viewport: { width: 1280, height: 800 } }, 'mac');
const pa = await enter(ap, '?hls=1');
await detail(pa, '/Movies/long.mp4', 'Long.Test.2024.1080p.mp4');
await reset(pa);
await pa.click('#detailPlay');
await until(pa, s => document.querySelector(s) && document.querySelector(s).currentTime > 0.5, vid);
s = await st(pa);
ok(s.plays[0] && s.plays[0].gesture && s.fs && s.fsIn === 1, '手势里 play()；开播那一刻进系统全屏（只进一次）');
await pa.evaluate(s => document.querySelector(s).webkitExitFullscreen(), vid);
await pa.waitForTimeout(500);
s = await st(pa);
ok(!s.on && !s.src && s.detail, '退出系统全屏：关掉播放器，回到详情页');
await pa.evaluate(() => closeDetail());
await pa.waitForTimeout(400);
hits.length = 0;
await pa.evaluate(() => openDetail('/Movies/dv81.mkv', 'Movie.2024.2160p.DV.mkv'));
const pre = await (async () => { for (let i = 0; i < 40; i++) { if (hits.some(h => h.endsWith('/info.json'))) return true; await new Promise(r => setTimeout(r, 150)); } return false; })();
ok(pre, '打开详情页就预取了签名与 info.json（顺带建好索引）');
await pa.waitForTimeout(600);
const nInfo = hits.filter(h => h.endsWith('/info.json')).length;
await reset(pa);
await pa.click('#detailPlay');
await pa.waitForTimeout(300);
s = await st(pa);
ok(s.plays.length && s.plays[0].gesture && /\/hls\/0\.0\.[A-Za-z0-9_-]+\/master\.m3u8$/.test(s.plays[0].src), 'MKV：点击的手势里就把 /hls/…/master.m3u8 交给播放器');
ok(hits.filter(h => h.endsWith('/info.json')).length === nInfo, '点播放时不再等 info.json（预热结果直接用上）');
ok(!s.plays[0] || !/crossorigin/.test(await pa.evaluate(s => document.querySelector(s).outerHTML, vid)), 'HLS 不带 crossorigin（字幕在主列表里，不需要 CORS 模式）');
await pa.keyboard.press('Escape');

console.log('\n■ 优选入口（EDGE_HOSTS）');
H.env.EDGE_HOSTS = 's2.test';
pingDelay = 500;
const ep = await context({ viewport: { width: 1280, height: 800 } }, false, true);
const pe = await enter(ep);
const picked = await pe.waitForFunction(() => { const d = JSON.parse(localStorage.getItem('cuven_edge_v1') || 'null'); return d && d.host; }, null, { timeout: 20000 }).then(h => h.jsonValue()).catch(() => '');
ok(picked === 's2.test', `实测后选中更快的入口：${picked}`);
await pe.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
await until(pe, s => document.querySelector(s) && document.querySelector(s).currentTime > 0.5, vid);
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
