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
let trailerYt = false;                        // 预告片回包：false = IMDb 直链 MP4，true = 只有 YouTube 官方预告
let apiDown = false;                          // 模拟弱网 / 断网：发往 Worker 的请求一律连不上

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
    if (apiDown) return route.abort('internetdisconnected');
    if (url.pathname === '/api/imdb/video') {
      return route.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' },
        body: JSON.stringify(trailerYt
          ? { id: 'tt1', video: null, stills: [], yt: { key: 'Way9Dexny3w', name: 'Official Trailer', kind: 'Trailer', official: true } }
          : { id: 'tt1', video: { best: TRAILER, mp4: { '720p': TRAILER, '1080p': TRAILER }, thumb: null }, stills: [] }) });
    }
    if (url.pathname === '/api/edge/ping' && url.host === 'stream.cuven.online' && pingDelay) await new Promise(r => setTimeout(r, pingDelay));
    if (url.pathname.startsWith('/stream/') && streamDelay) await new Promise(r => setTimeout(r, streamDelay));
    const req = route.request();
    /* POST 要把正文一起交给 Worker（/api/tmdb-batch）—— 原来漏了，批接口在测试里一直回 Invalid JSON，
       页面全走单条兜底，批接口这条真实路径根本没被测到 */
    const res = await H.worker.fetch(new Request(u, { method: req.method(), headers: req.headers(), body: req.method() === 'POST' ? req.postData() : undefined }), H.env, H.ctx);
    await route.fulfill({ status: res.status, headers: Object.fromEntries(res.headers), body: Buffer.from(await res.arrayBuffer()) });
  });
  return ctx;
}
/* 已登录用户进站先看到欢迎页（全屏，盖在一切之上），点「确认并继续」才进入应用 */
/* wait：欢迎页退场的时限。XDR 这种 6016×3140 物理像素的视口上，无头环境用软件渲染画 WebGL 极光，
   退场动画要慢得多 —— 真机上没有这回事。默认 15 秒：机器忙的时候（软件渲染的 GPU 进程吃满几个核），
   1280×800 上退场那 0.5 秒的计时器也会被拖过 5 秒；这只是进站的准备步骤，不是要测的东西 */
async function enter(ctx, q = '', wait = 15000) {
  const pg = await ctx.newPage();
  pg.on('pageerror', e => errors.push(e.message));
  await pg.goto(ORIGIN + q);
  await pg.waitForFunction(() => typeof playVideo === 'function' && typeof Player === 'object', null, { timeout: 15000 });
  if (await pg.$('#wc-cta')) { await pg.click('#wc-cta'); await pg.waitForSelector('#wc-root', { state: 'detached', timeout: wait }); }
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
/* Esc 之后等播放器真的关掉再往下走：元素全屏要等退出全屏落定（fullscreenchange）才关，机器一忙这一下能拖过半秒，
   固定睡 400ms 的话下一节会撞上还没关完的上一部（同一个文件被当成「回到同一部」接着放、或晚到的关闭把新开的那部关掉） */
const closed = pg => until(pg, () => !document.querySelector('#nativePlayer.on'), null, 10000).catch(() => {});
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
await closed(page);
s = await st(page);
ok(!s.on && s.detail, 'Esc：退出全屏并关掉播放器，详情页还在');
await page.click('#detailPlay');
await until(page, s => document.querySelector(s).currentTime > 0.3, vid);
await page.goBack();
await page.waitForTimeout(600);
s = await st(page);
ok(!s.on && !s.src && s.detail, '返回键：关掉播放器，详情页还在');
/* 点「播放」后马上按返回：全屏请求晚到（关的时候还不在全屏里，没得退），或退出请求被浏览器吞了 —— 原来整页会留在
   藏起来的播放层的全屏里：黑底，点哪都没反应（命中的是 <html>），只能按 Esc。两种都人为做出来，不靠撞时机 */
const strayAt = () => page.evaluate(() => { const b = document.getElementById('detailPlay').getBoundingClientRect();
  const e = document.elementFromPoint(b.left + b.width / 2, b.top + b.height / 2);
  return { fs: !!document.fullscreenElement, on: !!document.querySelector('#nativePlayer.on'), hit: !!(e && e.closest('#detailPlay')) }; });
await page.evaluate(() => { const rq = window.__rfs0 = Element.prototype.requestFullscreen;
  Element.prototype.requestFullscreen = function () { return new Promise(r => setTimeout(r, 400)).then(() => rq.call(this)); }; });
await page.click('#detailPlay');
await page.evaluate(() => history.back());
await page.waitForTimeout(2000);
const strayA = await strayAt();
/* 卡住了（修之前）就先手动退掉，别把后面几节一起拖下水 */
const unstick = () => page.evaluate(() => document.fullscreenElement && document.exitFullscreen().catch(() => {})).then(() => page.waitForTimeout(600));
await page.evaluate(() => { Element.prototype.requestFullscreen = window.__rfs0; });
await unstick();
await page.evaluate(() => { const ex = window.__xfs0 = Document.prototype.exitFullscreen; let n = 0;
  Document.prototype.exitFullscreen = function () { return n++ ? ex.call(this) : new Promise(() => {}); }; });
await page.click('#detailPlay');
await until(page, () => !!document.fullscreenElement, null, 8000).catch(() => {});
await page.evaluate(() => history.back());
await page.waitForTimeout(2500);
const strayB = await strayAt();
await page.evaluate(() => { Document.prototype.exitFullscreen = window.__xfs0; });
await unstick();
ok(!strayA.fs && !strayA.on && strayA.hit && !strayB.fs && !strayB.on && strayB.hit,
  `点「播放」马上返回：全屏请求晚到、退出请求被吞，都会退干净，详情页的按钮点得到（${JSON.stringify({ 晚到: strayA, 被吞: strayB })}）`);

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
await closed(page);
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
await closed(page);

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
await closed(page);

console.log('\n■ Chrome：MKV 走直连（它的原生 HLS 遇到解不了的 CODECS 会整条拒播）');
await page.evaluate(() => playVideo('/Movies/avc_zsub.mkv', 'Some.Movie.2021.1080p.mkv'));
await until(page, s => { const v = document.querySelector(s); return v.currentTime > 0.5 || document.querySelector('#nativePlayer .np-state.err:not([hidden])'); }, vid);
s = await st(page);
ok(/\/stream\/Cuven%20.*\?path=%2FMovies%2Favc_zsub\.mkv$/.test(s.src) || s.err, 'MKV 交给 /stream 直连（不带 safari=1）');
ok(s.t > 0.5 || /浏览器解不了/.test(s.msg), s.t > 0.5 ? `Chromium 直接播放 MKV（t=${s.t.toFixed(1)}s）` : `给出格式说明：${s.msg}`);
await page.keyboard.press('Escape');
await closed(page);

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
const facts = await page.evaluate(() => [...document.querySelectorAll('.sc-chapter .sc-fact')].map(f => f.textContent));
ok(facts.every(f => !/4K|1080p|杜比视界|HDR|8K|DV/.test(f)), `展厅介绍下面那排小胶囊没有规格小标签（${facts.join(' / ') || '无'}）`);
/* 从第 10 秒进（跳过片头厂标），一律静音：没有开声音的钮，谁把它打开了就立刻关回去 */
const t10 = await page.evaluate(() => { const v = document.querySelector('.sc-chapter video'); const t = v.currentTime; v.muted = false; return { t, btn: !!document.querySelector('.sc-chapter .sc-mutectl') }; });
await page.waitForTimeout(150);
t10.muted = await page.evaluate(() => document.querySelector('.sc-chapter video').muted);
ok(t10.t >= 10 && t10.muted && !t10.btn, `预告片从第 10 秒进（t=${t10.t.toFixed(1)}s），一律静音：没有开声音的钮，被打开也立刻关回去`);
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

console.log('\n■ 展厅预告片 · YouTube 官方预告（IMDb 不给直链时）');
{
  trailerYt = true;
  const yc = await context({ viewport: { width: 1280, height: 800 } });
  /* YouTube 播放器的替身：与 IFrame API 同名同参的方法，状态按真播放器的顺序回调（缓冲 3 → 播放 1 → 暂停 2） */
  await yc.addInitScript(() => {
    window.YT = { Player: class {
      constructor(el, o) {
        this.o = o; this.muted = true; this.t = o.playerVars.start || 0; this.state = -1;
        const f = document.createElement('iframe'); f.dataset.fakeYt = o.videoId; el.replaceWith(f); this.f = f;
        window.__yt = this; window.__ytOpts = o;
        setTimeout(() => o.events.onReady({ target: this }), 30);
      }
      emit(s) { this.state = s; this.o.events.onStateChange({ data: s, target: this }); }
      getIframe() { return this.f; }
      playVideo() { if (this.state === 1 || this.state === 3) return; this.emit(3); setTimeout(() => this.state === 3 && this.emit(1), 80); }
      pauseVideo() {
        /* 停下那一刻画面还露着，就会看到 YouTube 的暂停层（More videos、标志）：记下来 */
        window.__ytPauseShown = !!(this.f.parentElement && this.f.parentElement.classList.contains('clean'));
        if (this.state === 1 || this.state === 3) this.emit(2);
      }
      unloadModule(m) { (window.__ytUnload = window.__ytUnload || []).push(m); }
      mute() { this.muted = true; } unMute() { this.muted = false; window.__ytUnmuted = (window.__ytUnmuted || 0) + 1; } isMuted() { return this.muted; }
      seekTo(t) { this.t = t; }
      getCurrentTime() { if (this.state === 1) this.t += 0.25; return this.t; }
      getDuration() { return 150; }
      destroy() { this.f.remove(); window.__ytGone = (window.__ytGone || 0) + 1; }
    } };
  });
  const yp = await enter(yc);
  await yp.evaluate(() => navTo('library'));
  const up = await until(yp, () => {
    const m = document.querySelector('.sc-chapter .sc-media');
    return !!(m && m.classList.contains('is-yt') && m.classList.contains('is-playing') && m.querySelector('.sc-yt iframe[data-fake-yt]') && window.__yt.state === 1);
  }, null, 40000).then(() => true).catch(() => false);
  const o = await yp.evaluate(() => ({ v: window.__ytOpts && window.__ytOpts.playerVars, host: window.__ytOpts && window.__ytOpts.host,
    vsrc: document.querySelector('.sc-chapter video').getAttribute('src'), muted: window.__yt && window.__yt.muted }));
  ok(up && o.muted && !o.vsrc && o.v && o.v.mute === 1 && o.v.controls === 0 && o.v.playsinline === 1 && o.v.start === 10 && /nocookie/.test(o.host),
    'IMDb 没给直链：第一章挂上 YouTube 官方预告并静音自动开播（无控件、内联、从第 10 秒进，原生 <video> 让位）');
  /* YouTube 自己的界面一样都不露：开播那几秒（片名条、上一个 / 暂停 / 下一个）画面不露，底下是剧照 */
  const c0 = await yp.evaluate(() => { const b = document.querySelector('.sc-chapter .sc-yt'); return { clean: b.classList.contains('clean'), op: getComputedStyle(b).opacity }; });
  const c1 = await until(yp, () => { const b = document.querySelector('.sc-chapter .sc-yt'); return !!b && b.classList.contains('clean') && getComputedStyle(b).opacity === '1'; }, null, 7000)
    .then(() => true).catch(() => false);
  const cc = await yp.evaluate(() => (window.__ytUnload || []).includes('captions'));
  ok(!c0.clean && c0.op === '0' && c1 && cc, 'YouTube 的控件层不露：开播先不露（底下是剧照），连续播满 3 秒、控件自己退掉后才淡入；字幕模块卸掉');
  const ring = await until(yp, () => parseFloat(document.querySelector('.sc-chapter .sc-ring-value').style.strokeDashoffset) < 106.8, null, 5000)
    .then(() => true).catch(() => false);
  ok(ring, '进度环跟着 YouTube 播放器走');
  /* 片尾画面（订阅、推荐视频）出来之前：先隐去，回卷到第 10 秒，播稳了再露 */
  await yp.evaluate(() => { window.__yt.t = 140; });
  const looped = await until(yp, () => window.__yt.t >= 10 && window.__yt.t < 20 && !document.querySelector('.sc-chapter .sc-yt.clean'), null, 3000).then(() => true).catch(() => false);
  const again = await until(yp, () => !!document.querySelector('.sc-chapter .sc-yt.clean'), null, 6000).then(() => true).catch(() => false);
  ok(looped && again, '片尾画面出来之前先隐去、回卷到第 10 秒，播稳了再露出来');
  const un = await yp.evaluate(() => ({ btn: !!document.querySelector('.sc-chapter .sc-mutectl'), yt: window.__yt.muted, unmuted: window.__ytUnmuted || 0 }));
  ok(!un.btn && un.yt === true && un.unmuted === 0, `预告片一律静音：没有开声音的钮，YouTube 播放器从没被 unMute（${JSON.stringify(un)}）`);
  await yp.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
  await until(yp, s => document.querySelector(s).currentTime > 0.3, vid);
  await yp.waitForTimeout(300);
  ok(await yp.evaluate(() => window.__yt.state === 2 && window.__ytPauseShown === false && !document.querySelector('.sc-chapter .sc-yt.clean')),
    '正片开播：YouTube 预告也让路（暂停）—— 先隐去画面再停，暂停层（More videos、标志）露不出来');
  await yp.keyboard.press('Escape');
  const back = await until(yp, () => window.__yt && window.__yt.state === 1, null, 8000).then(() => true).catch(() => false);
  ok(back, '关掉播放器：YouTube 预告接着放');
  await yp.evaluate(() => navTo('home'));
  const gone = await until(yp, () => (window.__ytGone || 0) >= 1 || window.__yt.state === 2, null, 5000).then(() => true).catch(() => false);
  const how = await yp.evaluate(() => ((window.__ytGone || 0) >= 1 ? '已销毁' : '已暂停'));
  ok(gone, `离开资料库：YouTube 预告不再播放（${how}，与原生 <video> 同一套规矩）`);
  await yc.close();
  trailerYt = false;
}

console.log('\n■ 片名一律中文（卡片、搜索、播放器 / 正在播放）');
{
  H.env.TMDB_API_KEY = 'tmdb-test';
  caches.default.m.clear();         /* Worker 的 TMDB 结果缓存跨节共享：上一节那份片单的「认不出」不能带进来 */
  H.tmdb.movies = [{ id: 9001, query: 'long', title: '漫长的测试', date: '2024-05-01' }];
  const zc = await context({ viewport: { width: 1280, height: 800 } });
  await zc.route('https://image.tmdb.org/**', r => r.fulfill({ status: 200, contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>' }));
  const zp = await enter(zc);
  await zp.evaluate(() => { openSearch && openSearch(); });
  await zp.fill('#searchInput', 'long');
  await zp.evaluate(() => runSearch('long'));
  const up = await until(zp, () => { const t = document.querySelector('#searchBody .card[data-name="long.mp4"] .card-title'); return !!(t && t.textContent === '漫长的测试'); }, null, 15000)
    .then(() => true).catch(() => false);
  ok(up, '搜索结果的卡片显示 TMDB 的中文名「漫长的测试」（文件名是 long.mp4）');
  const sw = await zp.evaluate(() => {
    const box = document.createElement('div');
    box.innerHTML = videoCardHTML({ name: 'Some.Film.2020.1080p.mkv', path: '/Movies/x.mkv' });
    document.body.appendChild(box);
    const card = box.firstElementChild, before = card.querySelector('.card-title').textContent;
    upgradeCardTitle(card.querySelector('.card-poster'), { title: '某部电影', year: '2020' });
    const r = { before, after: card.querySelector('.card-title').textContent, aria: card.getAttribute('aria-label') };
    box.remove();
    return r;
  });
  ok(sw.before === 'Some Film' && sw.after === '某部电影' && sw.aria.startsWith('某部电影'), `还没有中文名的卡先按原名排（${sw.before}），中文名一到原位换字（${sw.after}），读屏标签跟着换`);
  /* 卡片上不出规格小标签：文件名里写满了 2160p / DV / HDR，竖版、横版卡都只写年份；首页、搜索结果里的卡也一枚都没有 */
  const nb = await zp.evaluate(() => {
    const f = { name: 'Big.Film.2021.2160p.UHD.DV.HDR10.Atmos.mkv', path: '/Movies/big.mkv' };
    const box = document.createElement('div');
    box.innerHTML = videoCardHTML(f) + videoCardHTML(f, { landscape: true });
    const meta = [...box.querySelectorAll('.card-meta')].map(m => m.textContent).join(' | ');
    /* 剧集卡：底部只留名字，那行小字（第 1 季 · 4K · 杜比视界）不出 */
    box.innerHTML = tvCardHTML({ title: '幕府将军', en: 'Shogun', zh: '幕府将军', folder: 'Shogun.S01.2160p.DV', path: '/ram2/x', id: 'x', seasonLabel: '第 1 季', res: '4K', hdr: 'DV', episodes: 3 });
    const foot = box.querySelector('.tv-foot').textContent;
    return { html: box.querySelectorAll('.tag-border').length > 0 || /8K|高动态|DV|HDR|4K/.test(meta), meta, dom: document.querySelectorAll('.card .tag-border').length,
      tvFoot: !box.querySelector('.tv-foot-s') && !/4K|杜比视界|第 1 季/.test(foot) && /Shogun/.test(foot) };
  });
  ok(!nb.html && nb.dom === 0 && nb.tvFoot, `卡片上不出 DV / 8K+ / 高动态这类规格小标签（文件名写满规格的卡，底下只写「${nb.meta}」；首页与搜索结果里的卡：${nb.dom} 枚）；剧集卡底部只留名字`);
  /* 年份那行字不被卡的圆角裁到：卡自己带圆角又挂着 contain: paint，原来卡框下沿就是年份的下沿，左下角的圆弧切掉「2026」的 2 一角。
     现在卡框往下多出一个圆角半径（再用等量负外边距收回，版面不动） */
  const corner = await zp.evaluate(() => {
    /* 一张卡一行：同一行里矮的那张会被拉高到和高的一样（flex 默认 stretch），量不出它自己的下沿 */
    return [videoCardHTML({ name: 'Gatta.Kusthi.2.2026.mkv', path: '/Movies/g.mkv' }), videoCardHTML({ name: 'Wide.Film.2026.mkv', path: '/Movies/w.mkv' }, { landscape: true })].map(html => {
      const row = document.createElement('div'); row.className = 'scroll-row'; row.style.cssText = 'position:fixed;left:0;top:0;';
      row.innerHTML = html;
      document.body.appendChild(row);
      const c = row.querySelector('.card'), m = c.querySelector('.card-meta').getBoundingClientRect(), r = c.getBoundingClientRect(), cs = getComputedStyle(c);
      const res = { gap: Math.round((r.bottom - m.bottom) * 10) / 10, radius: parseFloat(cs.borderBottomLeftRadius), flush: Math.abs(r.bottom + parseFloat(cs.marginBottom) - m.bottom) <= .5 };
      row.remove();
      return res;
    });
  });
  ok(corner.length === 2 && corner.every(c => c.gap >= c.radius - .5 && c.flush),
    `卡片底下那行年份不被卡的圆角裁到：字下面留出 ${corner.map(c => c.gap).join(' / ')}px（≥ 圆角半径），版面不动`);
  const again = await zp.evaluate(() => videoCardHTML({ name: 'long.mp4', path: '/Movies/long.mp4' }).includes('漫长的测试'));
  ok(again, '记进中文名索引：之后新排的卡一出来就是中文');
  const hit = await zp.evaluate(() => { runSearch('漫长'); return !!document.querySelector('#searchBody .card[data-name="long.mp4"]'); });
  ok(hit, '用中文名搜得到');
  await zp.evaluate(() => playVideo('/Movies/long.mp4', 'long.mp4'));
  await until(zp, s => document.querySelector(s).currentTime > 0.3, vid);
  const ms = await zp.evaluate(() => navigator.mediaSession && navigator.mediaSession.metadata ? navigator.mediaSession.metadata.title : '');
  ok(ms === '漫长的测试', `播放器 / 锁屏的「正在播放」也是中文名（${ms}）`);
  await zp.keyboard.press('Escape');
  await zc.close();
  delete H.env.TMDB_API_KEY; H.tmdb.movies = [];
}

console.log('\n■ 弱网 / 断网');
{
  const nc = await context({ viewport: { width: 1280, height: 800 } });
  const np = await enter(nc);
  await until(np, () => document.querySelectorAll('#view-home .card[data-path]').length > 0, null, 20000);
  const absent = await np.evaluate(() => Number(localStorage.getItem('received_absent_until') || 0) > Date.now());
  ok(absent, '后端没有总账：记下来（12 小时内开张不再先撞那几个 404）');
  await np.waitForTimeout(600);                                    /* 本地副本是异步写的 */
  await np.close();

  hits.length = 0;
  const np2 = await enter(nc);
  await until(np2, () => document.querySelectorAll('#view-home .card[data-path]').length > 0, null, 20000);
  ok(!hits.some(h => /\/api\/received/.test(h)), '再次打开：不再请求总账');
  await np2.close();

  apiDown = true;
  const t0 = Date.now();
  const np3 = await enter(nc);
  const opened = await until(np3, () => document.querySelectorAll('#view-home .card[data-path]').length > 0, null, 20000).then(() => true).catch(() => false);
  const failed = await np3.evaluate(() => [...document.querySelectorAll('.empty-title')].some(e => /加载失败/.test(e.textContent)));
  ok(opened && !failed, `连不上 Worker：用本地副本照常开张（${Date.now() - t0}ms，不显示「加载失败」）`);
  await nc.setOffline(true);
  await np3.evaluate(() => window.dispatchEvent(new Event('offline')));
  const off = await until(np3, () => { const b = document.getElementById('netBanner'); return !!(b && b.classList.contains('show') && /网络已断开/.test(b.textContent)); }, null, 3000).then(() => true).catch(() => false);
  ok(off, '断网：顶部胶囊「网络已断开 · 正在显示离线内容」');
  apiDown = false;
  await nc.setOffline(false);
  await np3.evaluate(() => window.dispatchEvent(new Event('online')));
  const back = await until(np3, () => { const b = document.getElementById('netBanner'); return !!(b && /网络已恢复/.test(b.textContent)); }, null, 3000).then(() => true).catch(() => false);
  ok(back, '恢复：「网络已恢复」，没加载出来的重新排队');
  await nc.close();

  /* 省流量模式（Chrome / Android 的 navigator.connection）：图片降一档、预告片不挂 */
  const sc = await context({ viewport: { width: 1280, height: 800 } });
  await sc.addInitScript(() => { Object.defineProperty(Navigator.prototype, 'connection', { configurable: true, get: () => ({ saveData: true, effectiveType: '4g', addEventListener() {} }) }); });
  const sp = await enter(sc);
  const r = await sp.evaluate(() => ({ slow: NetQ.slow, p: downsizeForCard('https://image.tmdb.org/t/p/original/a.jpg', false), l: downsizeForCard('https://image.tmdb.org/t/p/original/a.jpg', true) }));
  ok(r.slow && /\/w342\//.test(r.p) && /\/w500\//.test(r.l), `省流量 / 弱网：海报 w342、剧照 w500（${r.p.split('/t/p/')[1]}，${r.l.split('/t/p/')[1]}）`);
  await sp.evaluate(() => navTo('library'));
  await sp.waitForTimeout(4000);
  ok(await sp.evaluate(() => { const v = document.querySelector('.sc-chapter video'); return !!v && !v.getAttribute('src') && !document.querySelector('.sc-yt'); }), '省流量：资料库的预告片不自动挂，只放剧照');
  await sc.close();
}

console.log('\n■ 悬浮返回钮 · 返回手势 · 正在播放');
{
  const bc = await context({ ...devices['iPhone 15 Pro'] });
  const bp = await enter(bc);
  await bp.waitForTimeout(800);
  const pb = () => bp.evaluate(() => {
    const b = document.getElementById('pageBack'), r = b && b.getBoundingClientRect();
    return { on: !!(b && b.classList.contains('on')), top: r ? Math.round(r.top) : null, label: b ? b.getAttribute('aria-label') : '', view: history.state && history.state.view,
      slot: !!document.querySelector('.page-back-slot') };
  });
  await bp.evaluate(() => openYearLibrary(2024));
  await until(bp, () => !!document.querySelector('.view-section.active .page-back-slot'), null, 8000);
  await bp.waitForTimeout(400);
  const y0 = await pb();
  await bp.evaluate(() => { document.body.style.minHeight = '4000px'; window.scrollTo(0, 900); });
  await bp.waitForTimeout(300);
  const y1 = await pb();
  ok(y0.on && y0.slot && y0.view === 'sub' && /返回/.test(y0.label) && y1.on && y1.top === y0.top,
    `年份页：返回钮悬浮在左上角（往下翻 900px 仍在 ${y1.top}px 处），页头留着原位，记了一格历史`);
  await bp.evaluate(() => { document.body.style.minHeight = ''; history.back(); });
  const gone = await until(bp, () => !document.querySelector('.view-section.active .page-back-slot') && !document.getElementById('pageBack').classList.contains('on') &&
    !(history.state && history.state.view === 'sub'), null, 6000).then(() => true).catch(() => false);
  ok(gone, '边缘右滑 / 浏览器后退：回到上一页（原来在二级页面上什么都不发生）');
  await bp.evaluate(() => enterFolder('/Movies/dovi', 'dovi'));
  await until(bp, () => !!document.querySelector('.view-section.active .page-back-slot') && document.getElementById('pageBack').classList.contains('on'), null, 8000);
  await bp.click('#pageBack');
  const f = await until(bp, () => !document.querySelector('.view-section.active .page-back-slot'), null, 6000).then(() => true).catch(() => false);
  const st2 = await pb();
  ok(f && !st2.on && st2.view !== 'sub', '文件夹页：点悬浮返回钮回到上一页，那一格历史一并退掉');
  await bp.waitForTimeout(1000);                                   /* 切页动画走完（navTo 在动画中途不接新的切换） */
  await bp.evaluate(() => openYearLibrary(2024));
  await until(bp, () => document.getElementById('pageBack').classList.contains('on'), null, 8000);
  await bp.keyboard.press('Escape');
  ok(await until(bp, () => !document.getElementById('pageBack').classList.contains('on'), null, 4000).then(() => true).catch(() => false), 'Esc 也能返回');
  await bc.close();

  const mc = await context({ viewport: { width: 1280, height: 800 } });
  const mp = await enter(mc);
  await mp.evaluate(() => playVideo('/Movies/long.mp4', 'Long.Test.2024.1080p.mp4'));
  await until(mp, s => document.querySelector(s).currentTime > 0.3, vid);
  const m1 = await mp.evaluate(() => ({ st: navigator.mediaSession.playbackState, t: navigator.mediaSession.metadata && navigator.mediaSession.metadata.title,
    album: navigator.mediaSession.metadata && navigator.mediaSession.metadata.album }));
  ok(m1.st === 'playing' && m1.t && m1.album === 'Cuven', `「正在播放」：${m1.t}，状态 playing（锁屏 / 灵动岛 / 控制中心都读这一份）`);
  await mp.evaluate(() => document.querySelector('#nativePlayer video').pause());
  await mp.waitForTimeout(200);
  ok(await mp.evaluate(() => navigator.mediaSession.playbackState === 'paused'), '暂停：状态跟着变成 paused');
  await mp.keyboard.press('Escape');
  await closed(mp);
  const m3 = await mp.evaluate(() => ({ meta: navigator.mediaSession.metadata, st: navigator.mediaSession.playbackState }));
  ok(m3.meta === null && m3.st === 'none', '关掉播放器：「正在播放」整块撤掉');
  await mc.close();
}

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
  /* 第一句是在加载画面出现的同一帧记下的，那时进度可能还是 0；之后每一句都得在涨、且不走满 */
  ok(ps.every((p, i) => (i ? p > 0 : p >= 0) && p < 0.95 && (!i || p >= ps[i - 1])) && ps[ps.length - 1] > 0, `开播前进度只增不减、不走满：${ps.map(p => Math.round(p * 100) + '%').join(' → ')}`);
  ok(!A3.shown, '开播后加载画面收起');
  streamDelay = 0;
  await ip2.close();
}

console.log('\n■ iPhone Duo（Safari 27.1 实测视口：折起 382×580 / 594×368，展开 669×825 / 951×543；主屏幕 App 折起 466×678）');
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
/* 折起竖拿（Safari 382 宽 / 主屏幕 App 466 宽）：贴右缘浮着的竖向导航；展开、横拿：贴左缘、内容让位的导航条；
   普通 iPhone（393 宽）照旧底部胶囊 */
const DESC = { float: '右缘浮动的全新导航栏（一枚收窄的竖向玻璃胶囊，挂在屏幕中线偏下一点：主页 / 资料库 / 搜索 / 头像在底，只有图标，内容不让位）', rail: '侧边导航条（竖排）', bottom: '底部导航胶囊' };
/* 实机上折起的外屏右侧有一整列安全区（状态栏竖着排在右上角，safe-area-inset-right ≈ 84px）：用 CDP 模拟同样的安全区 */
const duoCdp = await duo.newCDPSession(pd);
const NO_SAI = { top: 0, right: 0, bottom: 0, left: 0 };
for (const [w, h, label, mode, sai] of [[382, 580, '折起竖拿', 'float'], [466, 678, '折起竖拿 · 主屏幕 App', 'float'],
  [466, 678, '折起竖拿 · 主屏幕 App · 右侧 84px 安全区（实机）', 'float', { top: 0, right: 84, bottom: 20, left: 0 }], [594, 368, '折起横拿', 'rail'],
  [669, 825, '展开竖拿', 'rail'], [951, 543, '展开横拿', 'rail'], [382, 580, '再合上竖拿', 'float']]) {
  await duoCdp.send('Emulation.setSafeAreaInsetsOverride', { insets: sai || NO_SAI });
  await pd.setViewportSize({ width: w, height: h });
  await pd.waitForTimeout(800);
  const g = await pd.evaluate(() => {
    const card = document.querySelector('.hcard.is-center') || document.querySelector('.hcard');
    const r = e => e && e.getBoundingClientRect();
    const cls = document.documentElement.classList, rail = cls.contains('rail'), float = cls.contains('rail-float');
    /* Duo 折起竖拿的新导航：整枚胶囊就是 #dock（.nav-container 摊平了）；别的形态照旧量 .nav-container */
    const nav = r(document.getElementById(float ? 'dock' : 'navContainer')), pill = r(document.getElementById('navPill')), act = r(document.querySelector('#navContainer .nav-item.active'));
    const srch = r(document.getElementById('navSearch'));
    const play = r(card && card.querySelector('.btn-play')), circ = r(card && card.querySelector('.btn-circle')), dots = r(document.querySelector('.aap-host .all-access-pass'));
    const apart = (a, b) => !a || !b || a.right <= b.left || b.right <= a.left || a.bottom <= b.top || b.bottom <= a.top;
    const shift = parseFloat(getComputedStyle(document.getElementById('appStage')).paddingLeft) || 0;
    /* 浮动导航下大图专门排过：标签 / 片名 / 按钮 / 暂停钮与轮播点同一条中线（居中到导航左边那块） */
    const midX = b => b ? (b.left + b.right) / 2 : NaN;
    const btns = r(card && card.querySelector('.hero-buttons')), ttl = r(card && (card.querySelector('.hero-logo-img') || card.querySelector('.hero-logo-text')));
    const aligned = Math.abs(midX(btns) - midX(dots)) <= 4 && (!ttl || Math.abs(midX(ttl) - midX(dots)) <= 4);
    /* 沉浸：大图铺满一整屏，暂停钮与轮播点在 Home 指示条之上 */
    const deck = r(document.querySelector('.hero-deck'));
    const immersive = !!deck && Math.abs(deck.top) <= 1 && Math.abs(deck.height - innerHeight) <= 1 && dots.bottom <= innerHeight - 14;
    /* 文案三行：片名 → 年份胶囊 → 按钮；片名下那行（类型 · 片长 / 严选标）不出 */
    const st = r(card && card.querySelector('.hero-status')), tg = card && card.querySelector('.hero-tags');
    const order3 = !!(st && ttl && btns) && ttl.bottom <= st.top + 1 && st.bottom <= btns.top + 1 && (!tg || getComputedStyle(tg).display === 'none');
    /* 新导航：四项自上而下（主页、资料库、搜索、头像）都在胶囊里；只有图标（文字只留给读屏）；选中项有柔光圆底；滑动指示器不出 */
    const items = ['navHome', 'navLib', 'navSearch', 'headerAvatar'].map(id => r(document.getElementById(id)));
    const inside = !!nav && items.every(b => b && b.width > 20 && b.left >= nav.left - 1 && b.right <= nav.right + 1 && b.top >= nav.top - 1 && b.bottom <= nav.bottom + 1);
    const ordered = items.every((b, i) => i === 0 || (b && items[i - 1] && items[i - 1].bottom <= b.top + 1));
    const actEl = document.querySelector('#navContainer .nav-item.active'), actBg = actEl ? getComputedStyle(actEl).backgroundColor : '';
    const iconOnly = [...document.querySelectorAll('#dock .nav-text')].every(t => t.getBoundingClientRect().width <= 1);
    const newNav = inside && ordered && !!actBg && actBg !== 'rgba(0, 0, 0, 0)' && iconOnly && getComputedStyle(document.getElementById('navPill')).display === 'none';
    const clear = !!(nav && play && dots) && play.top >= 0 && (float
      ? apart(play, nav) && apart(circ, nav) && apart(dots, nav) && nav.left > innerWidth / 2 && nav.right >= innerWidth - 24
        && nav.width <= 56 && Math.abs((nav.top + nav.bottom) / 2 - innerHeight * 0.55) <= 6
        && newNav && shift === 0 && aligned && immersive && order3
      : rail ? apart(play, nav) && apart(dots, nav) && play.left >= nav.right
      : play.bottom <= nav.top && dots.bottom <= nav.top);
    const pillOk = float ? newNav : !!(pill && act) && Math.abs(pill.left - act.left) <= 2 && Math.abs(pill.top - act.top) <= 2 && Math.abs(pill.width - act.width) <= 2 && Math.abs(pill.height - act.height) <= 2;
    return { mode: float ? 'float' : rail ? 'rail' : 'bottom', vertical: nav ? nav.height > nav.width : false, clear, pillOk, sw: document.documentElement.scrollWidth, vw: innerWidth };
  });
  ok(g.mode === mode && g.vertical === (mode !== 'bottom') && g.clear && g.pillOk && g.sw === g.vw,
    `${label} ${w}×${h}：${DESC[mode]}，${mode === 'float' ? '选中项有柔光圆底' : '选中指示器对齐'}，主视觉的按钮与轮播点不被导航挡住${mode === 'float' ? '、居中到导航左边那块，大图铺满整屏，文案是片名 → 年份胶囊 → 按钮' : ''}，没有横向溢出${g.mode === mode ? '' : `（实际：${g.mode}）`}`);
}
/* 往下一滚、大图收成卡片：卡落在导航左边那块，不钻到导航底下（实机的右侧安全区）。卡下不是与卡同宽的进度条，
   而是 iOS 页码控件那样的圆点胶囊：紧凑、居中在卡下，一张一颗点，当前那颗纯白、略大，其余半透明 */
await duoCdp.send('Emulation.setSafeAreaInsetsOverride', { insets: { top: 0, right: 84, bottom: 20, left: 0 } });
await pd.setViewportSize({ width: 466, height: 678 });
await pd.waitForTimeout(600);
await pd.evaluate(() => scrollTo(0, 300));
await pd.waitForTimeout(900);
const dotsOf = () => pd.evaluate(() => {
  const r = e => e.getBoundingClientRect(), ul = document.getElementById('heroDots');
  const c = r(document.querySelector('.hcard.is-center')), q = r(ul), n = r(document.getElementById('dock'));
  const dots = [...ul.querySelectorAll('.dotnav-item')].filter(li => getComputedStyle(li).display !== 'none').map(li => {
    const a = li.querySelector('.dotnav-link'), b = r(a);
    return { w: Math.round(b.width * 10) / 10, bg: getComputedStyle(a).backgroundColor, cur: a.classList.contains('current') };
  });
  return { morphed: document.querySelector('.hero-deck').classList.contains('morphed'), card: [Math.round(c.left), Math.round(c.right), Math.round(c.bottom)],
    cap: [Math.round(q.left), Math.round(q.right), Math.round(q.top), Math.round(q.height)], nav: Math.round(n.left),
    bar: getComputedStyle(ul, '::after').content, dots, n: state.heroVideos.length, idx: state.heroIdx, playing: AAP.playing };
});
const mo = await dotsOf();
const cur0 = mo.dots.find(d => d.cur), rest0 = mo.dots.filter(d => !d.cur);
ok(mo.morphed && mo.card[1] <= mo.nav - 8 && Math.abs((mo.cap[0] + mo.cap[1]) / 2 - (mo.card[0] + mo.card[1]) / 2) <= 2
  && mo.cap[1] - mo.cap[0] < (mo.card[1] - mo.card[0]) * 0.6 && mo.cap[3] >= 28 && mo.cap[3] <= 32 && mo.cap[2] >= mo.card[2] + 8
  && mo.bar === 'none' && mo.n > 1 && mo.dots.length === mo.n && !!cur0 && cur0.bg === 'rgb(255, 255, 255)'
  && rest0.every(d => d.bg === 'rgba(255, 255, 255, 0.5)' && cur0.w > d.w * 1.1),
  `折起竖拿 · 大图收成卡片：卡 ${mo.card[0]}–${mo.card[1]} 停在导航（${mo.nav}）左边；卡下是居中的圆点胶囊（${mo.cap[0]}–${mo.cap[1]}，${mo.cap[3]} 高），` +
  `${mo.dots.length} 张 ${mo.dots.length} 颗点，当前那颗纯白、略大（${cur0 && cur0.w} / ${rest0[0] && rest0[0].w}），不再是进度条`);
/* 点最后一颗：跳到那一张；卡片态照旧不自动轮播（原来直接走 _jumpAap 会把轮播开起来） */
await pd.click(`#heroDots .dotnav-item:nth-child(${mo.n}) .dotnav-link`);
await pd.waitForTimeout(900);
const mo2 = await dotsOf();
ok(mo2.idx === mo.n - 1 && !!mo2.dots[mo.n - 1] && mo2.dots[mo.n - 1].cur && !mo2.playing,
  `折起竖拿 · 卡片态点圆点就跳到那一张（第 ${mo2.idx + 1} / ${mo.n} 张），不开始自动轮播`);
/* 片单超过 8 张（注入 11 张）：只排 8 颗、跟着当前那张挪，还有更多的那一端最外两颗渐小，当前那颗不缩 */
const many = {};
for (const k of [2, 5, 10]) {
  await pd.evaluate(k => {
    window.__hv = window.__hv || state.heroVideos.slice();
    state.heroVideos = Array.from({ length: 11 }, (_, i) => window.__hv[i % window.__hv.length]);
    renderDots(); AAP.setCurrent(k);
  }, k);
  await pd.waitForTimeout(450);
  many[k] = (await dotsOf()).dots;
}
await pd.evaluate(() => { state.heroVideos = window.__hv; renderDots(); });
const small = d => d.w < 6, full = d => d.w >= 6.8;
const pat = (ds, l, r) => ds.length === 8 && (l ? small(ds[0]) && small(ds[1]) && ds[0].w < ds[1].w : full(ds[0]) && full(ds[1]))
  && (r ? small(ds[7]) && small(ds[6]) && ds[7].w < ds[6].w : full(ds[7]) && full(ds[6])) && ds.filter(d => d.cur).length === 1 && full(ds.find(d => d.cur));
ok(pat(many[2], false, true) && many[2][2].cur && pat(many[5], true, true) && many[5][4].cur && pat(many[10], true, false) && many[10][7].cur,
  `折起竖拿 · 片单超过 8 张：只排 8 颗，第 3 张时右端两颗渐小（${many[2].map(d => d.w).join(' ')}），` +
  `居中时两端渐小（${many[5].map(d => d.w).join(' ')}），到末尾左端渐小（${many[10].map(d => d.w).join(' ')}）`);
await pd.evaluate(() => scrollTo(0, 0));
await pd.waitForTimeout(500);
/* 资料库展映：背景视频、片名都收在右侧那一列（状态栏 + 导航）以左，那一列底下是黑的；
   画面右上角的播放钮不出，进资料库时顶替「资料库」那一格并进导航胶囊，离开就换回；预告片一律静音，没有声音钮 */
const navBox = () => pd.evaluate(() => { const r = e => e.getBoundingClientRect(), d = r(document.getElementById('dock')), m = r(document.getElementById('navMedia'));
  return { on: document.documentElement.classList.contains('sc-nav'), top: Math.round(d.top), h: Math.round(d.height), at55: Math.abs((d.top + d.bottom) / 2 - innerHeight * .55) <= 6, grp: Math.round(m.height), op: +getComputedStyle(document.getElementById('navMedia')).opacity,
    selOp: +getComputedStyle(document.querySelector('#dock .nav-sel')).opacity, homeGlass: getComputedStyle(document.getElementById('navHome')).backgroundColor !== 'rgba(0, 0, 0, 0)',
    libBack: (() => { const lb = document.getElementById('navLib'), c = getComputedStyle(lb); return Math.abs(lb.getBoundingClientRect().height - 44) <= 1 && +c.opacity === 1 && c.visibility === 'visible'; })() }; });
const home0 = await navBox();
const libRes = {};
for (const [w, h, sai, col, tag] of [[466, 678, { top: 0, right: 84, bottom: 20, left: 0 }, 84, '主屏幕 App（右侧 84px 那一列）'], [382, 580, NO_SAI, 72, 'Safari（导航自己那一条 72px）']]) {
  await duoCdp.send('Emulation.setSafeAreaInsetsOverride', { insets: sai });
  await pd.setViewportSize({ width: w, height: h });
  await pd.waitForTimeout(500);
  await pd.evaluate(() => navTo('library'));
  await until(pd, () => { const m = document.querySelector('.sc-chapter .sc-media'); return !!(m && m.classList.contains('is-playing')); }, null, 40000).catch(() => {});
  await pd.waitForTimeout(900);
  libRes[tag] = await pd.evaluate(col => {
    const r = e => e && e.getBoundingClientRect(), edge = innerWidth - col;
    const view = r(document.getElementById('view-library')), st = r(document.querySelector('.sc-chapter .sc-sticky')), cp = r(document.querySelector('.sc-chapter .sc-copy'));
    const d = r(document.getElementById('dock')), m = r(document.getElementById('navMedia')), lib = r(document.getElementById('navLib')), srch = r(document.getElementById('navSearch'));
    const play = document.getElementById('navScPlay');
    return { edge, view: Math.round(view.right), sticky: Math.round(st.right), copyMid: Math.round((cp.left + cp.right) / 2),
      fenced: Math.round(view.right) <= edge && Math.round(st.right) <= edge && Math.abs((cp.left + cp.right) / 2 - edge / 2) <= 3 && document.documentElement.scrollWidth === innerWidth,
      merged: document.documentElement.classList.contains('sc-nav') && m.height >= 40 && m.height <= 48 && m.top >= lib.bottom - 1 && m.bottom <= srch.top + 1 && m.left >= d.left && m.right <= d.right
        && Math.abs((d.top + d.bottom) / 2 - innerHeight * .55) <= 6 && !play.disabled && play.dataset.state === 'playing' && !document.getElementById('navScMute')
        && [...document.querySelectorAll('.sc-chapter .sc-mediactl, .sc-chapter .sc-mutectl')].every(b => getComputedStyle(b).display === 'none'),
      /* 标题那一条：画面从屏幕最上沿铺起，标题浮在上面；底下四层渐进模糊（模糊一层比一层重、遮罩一层比一层往上收）+ 由暗到透明 */
      under: (() => { const hd = r(document.querySelector('#view-library > .library-header')), layers = [...document.querySelectorAll('.library-veil > i')].map(i => getComputedStyle(i));
        const px = layers.map(c => parseFloat(((c.backdropFilter || c.webkitBackdropFilter || '').match(/blur\(([\d.]+)px\)/) || [])[1] || 0));
        return Math.abs(st.top) <= 1 && hd.top <= 1 && hd.bottom >= 100 && cp.top > hd.bottom && layers.length === 4 && px.every((v, i) => v > 0 && (!i || v > px[i - 1]))
          && layers.every(c => /gradient/.test(c.maskImage || c.webkitMaskImage || '')); })(),
      capH: Math.round(d.height),
      /* 「资料库」那一格让位（收成 0 高、看不见），播放钮顶上它的位置；选中项的玻璃包住播放钮 */
      sel: (() => { const pill = document.querySelector('#dock .nav-sel'), pr = r(pill), lbEl = document.getElementById('navLib'), lb = r(lbEl), pl = r(play);
        return +getComputedStyle(pill).opacity === 1 && Math.abs(pr.top - pl.top) <= 2 && Math.abs(pr.bottom - pl.bottom) <= 2 && Math.abs(pr.left - pl.left) <= 2 && Math.abs(pr.right - pl.right) <= 2
          && lb.height <= 1 && getComputedStyle(lbEl).visibility === 'hidden' && pl.top >= r(document.getElementById('navHome')).bottom; })(),
      round: (() => { const av = document.getElementById('headerAvatar'), w = av.getBoundingClientRect().width, rad = getComputedStyle(av).borderTopLeftRadius;
        return rad === '50%' || Math.abs(parseFloat(rad) - w / 2) <= 1; })() };
  }, col);
  if (tag.startsWith('主屏幕')) {
    /* 点胶囊里那一格：转给眼前那一章自己的钮 —— 暂停 / 接着放；预告片始终静音 */
    const vstate = () => pd.evaluate(() => { const v = document.querySelector('.sc-chapter .sc-media video');
      return { paused: v.paused, muted: v.muted, nav: document.getElementById('navScPlay').dataset.state }; });
    await pd.click('#navScPlay'); await pd.waitForTimeout(400); const a = await vstate();
    await pd.click('#navScPlay'); await pd.waitForTimeout(600); const b = await vstate();
    libRes.ctl = { a, b, ok: a.paused && a.nav === 'paused' && !b.paused && b.nav === 'playing' && a.muted && b.muted };
  }
  await pd.evaluate(() => navTo('home'));
  await pd.waitForTimeout(1000);
}
const home1 = await navBox();
const [la, ls] = [libRes['主屏幕 App（右侧 84px 那一列）'], libRes['Safari（导航自己那一条 72px）']];
ok(la.fenced && ls.fenced,
  `折起竖拿 · 资料库：背景视频与片名收在右侧那一列以左（主屏幕 App：视图 / 画面到 ${la.view} / ${la.sticky}，列缘 ${la.edge}，片名居中 ${la.copyMid}；` +
  `Safari：到 ${ls.view} / ${ls.sticky}，列缘 ${ls.edge}），没有横向溢出`);
ok(la.under && ls.under,
  '折起竖拿 · 资料库：标题那一条不是黑底硬边 —— 画面从屏幕最上沿铺起，标题浮在上面，底下四层渐进模糊（越往上越糊）+ 由暗到透明');
ok(la.sel && ls.sel && la.round && ls.round,
  '折起竖拿 · 资料库：「资料库」那一格让位（图标收掉），播放钮顶上它的位置，选中项的玻璃包住它；底部头像是圆形');
ok(la.merged && ls.merged && libRes.ctl.ok && la.capH === home0.h && ls.capH === home0.h,
  `折起竖拿 · 资料库：播放 / 暂停并进导航胶囊（顶替「资料库」那一格，胶囊不长不缩（${la.capH}），中心仍在 55% 高处，画面上不再有那个钮，没有声音钮）；` +
  `点它转给眼前这一章：暂停 / 接着放，预告片始终静音（${JSON.stringify(libRes.ctl)}）`);
ok(!home0.on && home0.grp === 0 && !home1.on && home1.grp === 0 && home1.op === 0 && Math.abs(home1.h - home0.h) <= 1 && home0.at55 && home1.at55 && home1.selOp === 0 && home1.homeGlass && home1.libBack,
  `折起竖拿 · 离开资料库：播放钮和包住它的玻璃一起收回，「资料库」图标长回来，胶囊仍是原来的高（${home0.h} → ${home1.h}），选中的圆底回到「主页」`);
await pd.evaluate(() => scrollTo(0, 0));
await pd.waitForTimeout(300);
await duoCdp.send('Emulation.setSafeAreaInsetsOverride', { insets: NO_SAI });
/* 实机上翻开 / 合上时，视口与屏幕尺寸不一定同一刻更新：合上那一下视口先变、screen 晚一拍还是内屏的尺寸，
   当场认不出外屏。屏幕尺寸跟上来之后（视口不再变、没有媒体查询事件），补查要把导航换回 Duo 的那种 */
const metrics = (w, h, sw, sh) => duoCdp.send('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: true, screenWidth: sw, screenHeight: sh });
await metrics(669, 825, 669, 880);
await pd.waitForTimeout(700);
const fold0 = await pd.evaluate(() => document.documentElement.className);
await metrics(466, 678, 669, 880);              /* 视口已是外屏，screen 还是内屏 */
await pd.waitForTimeout(400);
const stale = await pd.evaluate(() => document.documentElement.classList.contains('rail-float'));
await metrics(466, 678, 466, 678);              /* screen 跟上来（视口不变，没有媒体查询事件） */
await pd.waitForTimeout(1300);
const fold1 = await pd.evaluate(() => { const c = document.documentElement.classList, d = document.getElementById('dock').getBoundingClientRect();
  return { float: c.contains('rail') && c.contains('rail-float') && !c.contains('rail-switching'), atRight: d.right >= innerWidth - 24 && d.height > d.width * 2.5 }; });
ok(/\brail\b/.test(fold0) && !/rail-float/.test(fold0) && !stale && fold1.float && fold1.atRight,
  '翻开再合上、屏幕尺寸晚一拍才更新：补查把导航换回右缘那枚胶囊（不卡在展开时的形态）');
/* 展开的 Duo：不论横竖、视口多高，导航都在侧边。只看视口的话，主屏幕 App 横拿（669 高）、Safari 横拿滚动后工具栏收起
   （视口长过 600）都会跳到底部胶囊 */
const openRes = [];
for (const [w, h, sw, sh, label] of [[960, 669, 960, 669, '主屏幕 App 横拿 960×669'], [951, 620, 960, 669, 'Safari 横拿、工具栏收起 951×620'],
  [669, 960, 669, 960, '主屏幕 App 竖拿 669×960'], [951, 543, 960, 669, 'Safari 横拿 951×543']]) {
  await metrics(w, h, sw, sh);
  await pd.waitForTimeout(1300);
  openRes.push(await pd.evaluate(label => {
    const c = document.documentElement.classList, n = document.getElementById('navContainer').getBoundingClientRect();
    return { label, ok: c.contains('rail') && !c.contains('rail-float') && n.left < 120 && n.height > n.width && document.documentElement.scrollWidth === innerWidth };
  }, label));
}
ok(openRes.every(r => r.ok), `展开的 Duo 导航一律在侧边（不随视口高度跳到底部）：${openRes.map(r => r.label + (r.ok ? ' ✓' : ' ✗')).join('、')}`);
await metrics(466, 678, 466, 678);
await pd.waitForTimeout(900);
await pd.setViewportSize({ width: 466, height: 678 });
await pd.waitForTimeout(500);
/* 浮动侧边导航下搜索：搜索场到顶部、几乎通栏；胶囊收成头像圆钮，留在胶囊最底下那一格（头像原来的位置） */
await pd.setViewportSize({ width: 466, height: 678 });
await pd.waitForTimeout(600);
const cap0 = await pd.evaluate(() => { const d = document.getElementById('dock').getBoundingClientRect(); return { bottom: d.bottom, right: d.right }; });
await pd.evaluate(() => openSearch());
await pd.waitForTimeout(800);
const fs0 = await pd.evaluate(() => { const b = document.getElementById('navSearch').getBoundingClientRect(), a = document.getElementById('navContainer').getBoundingClientRect();
  return { top: b.top, left: b.left, w: b.width, ax: a.right, ay: a.bottom, vw: innerWidth, vh: innerHeight }; });
ok(fs0.top < 80 && fs0.left <= 24 && fs0.w >= fs0.vw - 48 && fs0.ax >= fs0.vw - 24 && Math.abs(fs0.ay - cap0.bottom) <= 6 && Math.abs(fs0.ax - cap0.right) <= 2,
  `折起竖拿 · 搜索：搜索场在顶部通栏展开（${Math.round(fs0.w)} 宽），头像圆钮留在胶囊最底下那一格`);
await pd.evaluate(() => closeSearch());
await pd.waitForTimeout(600);
const back = await pd.evaluate(() => { const d = document.getElementById('dock').getBoundingClientRect(), s = document.getElementById('navSearch').getBoundingClientRect();
  return { cap: d.height > d.width * 2.5, inside: s.top >= d.top && s.bottom <= d.bottom && s.left >= d.left && s.right <= d.right }; });
ok(back.cap && back.inside, '折起竖拿 · 收起搜索：搜索回到胶囊里，胶囊照旧是一整枚');
/* 别的手机照旧底部胶囊：普通 iPhone；Safari 放大到 115% 的 Pro Max（视口只剩 383 宽，但屏幕还是 430）；同样 382 宽的安卓机 */
for (const [label, opts] of [['普通 iPhone（393 宽）', devices['iPhone 15 Pro']],
  ['Safari 页面放大 115% 的 iPhone Pro Max（视口 383 宽）', { ...devices['iPhone 15 Pro Max'], viewport: { width: 383, height: 700 } }],
  ['382 宽的安卓机', { isMobile: true, hasTouch: true, viewport: { width: 382, height: 580 }, screen: { width: 382, height: 820 },
    userAgent: 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36' }]]) {
  const ac = await context(opts);
  const pa = await enter(ac);
  await pa.waitForTimeout(800);
  const b = await pa.evaluate(() => { const n = document.getElementById('navContainer').getBoundingClientRect(), c = document.documentElement.classList;
    const d = document.querySelector('.hero-deck').getBoundingClientRect();
    const card = document.querySelector('.hcard.is-center') || document.querySelector('.hcard');
    const st = card.querySelector('.hero-status').getBoundingClientRect(), lg = card.querySelector('.hero-logo-wrap').getBoundingClientRect();
    const tags = getComputedStyle(card.querySelector('.hero-tags')).display !== 'none';
    return { off: !c.contains('rail') && !c.contains('rail-float'), bottom: n.bottom >= innerHeight - 90 && n.width > n.height, deck: Math.round(d.height), vh: innerHeight,
      same: tags && st.bottom <= lg.top + 1 }; });
  /* 收成卡片后卡下照旧是那条与卡同宽的浏览进度条（圆点胶囊只给 Duo 折起）。等它真的收成卡（机器忙时滚动后的那一帧会晚到），
     再等合并那 .4 秒的宽度过渡走完 */
  await pa.evaluate(() => scrollTo(0, 400));
  await until(pa, () => document.querySelector('.hero-deck').classList.contains('morphed'), null, 8000).catch(() => {});
  await pa.waitForTimeout(700);
  const bar = await pa.evaluate(() => {
    const ul = document.getElementById('heroDots'), li = ul.querySelector('.dotnav-item'), af = getComputedStyle(ul, '::after');
    const c = document.querySelector('.hcard.is-center').getBoundingClientRect(), q = document.querySelector('.aap-host .all-access-pass').getBoundingClientRect();
    return { ok: document.querySelector('.hero-deck').classList.contains('morphed') && af.content !== 'none' && parseFloat(af.width) > 0
      && (!li || getComputedStyle(li).display === 'none') && Math.abs(q.left - c.left) <= 2 && Math.abs(q.right - c.right) <= 2,
      card: [Math.round(c.left), Math.round(c.right)], bar: [Math.round(q.left), Math.round(q.right)], fill: af.width };
  });
  ok(b.off && b.bottom && b.deck < b.vh - 40 && b.same && bar.ok,
    `${label}：不当成 iPhone Duo，照旧底部胶囊；大图照旧不铺满（${b.deck} / ${b.vh}），文案照旧（年份胶囊在片名上面，类型那行还在），` +
    `收成卡片后卡下照旧是与卡同宽的进度条（卡 ${bar.card.join('–')}，进度条 ${bar.bar.join('–')}）${b.off && b.bottom && b.same ? '' : JSON.stringify(b)}`);
  if (label.startsWith('普通 iPhone')) {
    /* 资料库照旧：展映铺满整宽，播放钮还在画面右上角（没有声音钮），导航里没有多出那一格 */
    await pa.evaluate(() => navTo('library'));
    await until(pa, () => { const c = document.querySelector('.sc-chapter .sc-mediactl'); return !!(c && !c.hidden); }, null, 40000).catch(() => {});
    await pa.waitForTimeout(600);
    const lb = await pa.evaluate(() => ({ full: Math.round(document.getElementById('view-library').getBoundingClientRect().width) === innerWidth,
      ctl: getComputedStyle(document.querySelector('.sc-chapter .sc-mediactl')).display !== 'none' && !document.querySelector('.sc-chapter .sc-mutectl'),
      nav: getComputedStyle(document.getElementById('navMedia')).display === 'none' }));
    ok(lb.full && lb.ctl && lb.nav, `${label} · 资料库：展映照旧铺满整宽，播放钮照旧在画面右上角（没有声音钮），导航里不多出一格（${JSON.stringify(lb)}）`);
  }
  await ac.close();
}
await pd.setViewportSize({ width: 951, height: 543 });
await pd.waitForTimeout(600);
await pd.evaluate(() => navTo('library'));
await pd.waitForTimeout(1200);
const lr = await pd.evaluate(() => {
  const r = e => e && e.getBoundingClientRect();
  const nav = r(document.getElementById('navContainer')), head = r(document.querySelector('#view-library .library-sub'));
  const pill = r(document.getElementById('navPill')), lib = r(document.getElementById('navLib'));
  return { sw: document.documentElement.scrollWidth, vw: innerWidth, headOk: !!head && head.left >= nav.right, pillOk: !!(pill && lib) && Math.abs(pill.top - lib.top) <= 2 };
});
ok(lr.sw === lr.vw && lr.headOk && lr.pillOk, '展开横拿 · 资料库：内容从导航条右边开始，指示器竖着滑到「资料库」，没有横向溢出');
await pd.evaluate(() => openSearch());
await pd.waitForTimeout(800);
const sr = await pd.evaluate(() => { const b = document.getElementById('navSearch').getBoundingClientRect(); return { top: b.top, w: b.width, left: b.left, rail: document.getElementById('navContainer').getBoundingClientRect().right }; });
ok(sr.top < 80 && sr.w > 400 && sr.left >= sr.rail, `侧边导航下搜索：搜索场在顶部横向展开（${Math.round(sr.w)} 宽），不压导航条`);
await pd.evaluate(() => closeSearch());
await pd.waitForTimeout(600);
await pd.evaluate(() => navTo('home'));
await pd.waitForTimeout(600);
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

console.log('\n■ Mac 大屏（14" / 16" MacBook Pro、Studio Display、Pro Display XDR）与 iPhone / iPad 不变');
{
  H.env.TMDB_API_KEY = 'tmdb-test';
  caches.default.m.clear();         /* Worker 的 TMDB 结果缓存跨节共享：上一节那份片单的「认不出」不能带进来 */
  /* 其余样片也给上 TMDB 条目：评分到齐后「今日推荐」会重排（见下面那条吸附跟随的回归） */
  /* 搜索词按后端的解析规则来：av1_hdr 解析出的片名是「av1」（hdr 是规格词），long_ep2 是「long」第 2 集 */
  const extra = fs.readdirSync(path.join(HERE, 'samples')).filter(f => /\.(mkv|mp4)$/.test(f) && !/^long/.test(f))
    .map((f, i) => ({ id: 9100 + i, query: f.replace(/\.[^.]+$/, '').replace(/[._]/g, ' ').toLowerCase().replace(/ hdr$/, ''), title: '样片' + i, date: '2020-05-01' }));
  H.tmdb.movies = [{ id: 9001, query: 'long', title: '漫长的测试', date: '2024-05-01', backdrop: '/b9001.jpg' }, ...extra];
  /* Apple Silicon 上的 Safari：不给 deviceMemory，核数按 4 报（防指纹时最坏的情况） */
  const macSafari = () => {
    Object.defineProperty(Navigator.prototype, 'deviceMemory', { configurable: true, get: () => undefined });
    Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', { configurable: true, get: () => 4 });
  };
  const img = r => r.fulfill({ status: 200, contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>' });
  const lay = pg => pg.evaluate(() => {
    const deck = document.querySelector('#view-home .hero-deck').getBoundingClientRect();
    const h = document.querySelector('#view-home .section-header');
    return { p: Math.round(ImgFit.cardW(false)), l: Math.round(ImgFit.cardW(true)), deckH: Math.round(deck.height),
      hdr: h ? parseFloat(getComputedStyle(h).fontSize) : 0, sw: document.documentElement.scrollWidth, vw: innerWidth,
      roomy: ImgFit.roomy, slow: NetQ.slow, banner: (document.getElementById('netBanner') || {}).textContent || '' };
  });
  const pick = pg => pg.evaluate(() => ({
    hero: heroBgUrl('https://image.tmdb.org/t/p/w1280/b1.jpg').split('/t/p/')[1],
    atv: heroBgUrl('https://is1-ssl.mzstatic.com/image/thumb/x/1600x900sr.jpg').split('/').pop(),
    itunes: heroBgUrl('https://is1-ssl.mzstatic.com/image/thumb/x/2000x3000bb.jpg').split('/').pop(),
    detail: detailBgUrl('https://image.tmdb.org/t/p/w1280/b1.jpg').split('/t/p/')[1],
    logo: logoUrl('https://image.tmdb.org/t/p/w500/l1.png').split('/t/p/')[1],
    poster: downsizeForCard('https://image.tmdb.org/t/p/w780/p1.jpg', false).split('/t/p/')[1],
    land: downsizeForCard('https://image.tmdb.org/t/p/w1280/b1.jpg', true).split('/t/p/')[1],
  }));
  const homeReady = pg => until(pg, () => document.querySelectorAll('#view-home .card[data-path]').length > 0, null, 20000);

  /* 14" MacBook Pro：Safari 窗口 1512×860，Retina */
  const m14 = await context({ viewport: { width: 1512, height: 860 }, deviceScaleFactor: 2 });
  await m14.addInitScript(macSafari);
  await m14.route('https://image.tmdb.org/**', img);
  let itunesHits = 0;
  await m14.route('https://itunes.apple.com/**', r => { itunesHits++; return r.abort(); });   /* 被拦截器 / 地区网络挡掉的第三方 */
  const p14 = await enter(m14, '', 60000);
  await homeReady(p14);
  await p14.waitForTimeout(2500);
  let L = await lay(p14), P = await pick(p14);
  ok(L.p === 216 && L.l === 400 && L.deckH === Math.round(860 * 0.85), `14" MacBook Pro（1512×860）：卡 ${L.p} / ${L.l}、大图 ${L.deckH}px（85vh）—— 与原来一致`);
  ok(L.roomy && /^original\//.test(P.hero) && /^original\//.test(P.detail) && /^original\//.test(P.logo),
    `Retina：首页大图 / 详情剧照 / logo 取原图（${P.hero.split('/')[0]} / ${P.detail.split('/')[0]} / ${P.logo.split('/')[0]}）—— Safari 报 4 核也认得出是 Mac`);
  ok(P.atv === '3040x1710sr.jpg' && P.itunes === '3040x3040bb.jpg', `Apple 图床按屏幕要的像素取：Apple TV 大图 1600 → ${P.atv}，iTunes ${P.itunes}`);
  ok(/^w500\//.test(P.poster) && /^w780\//.test(P.land), `卡片仍是 w500 / w780（216 / 400px × 2 用不着更大）`);
  const lay2 = await p14.evaluate(() => ({ bg: bgLayers(heroBgUrl('https://image.tmdb.org/t/p/w1280/b1.jpg')),
    sr: bgLayers(heroBgUrl('https://is1-ssl.mzstatic.com/image/thumb/x/1600x900sr.jpg')), plain: bgLayers('https://image.tmdb.org/t/p/w1280/b1.jpg') }));
  ok(/original\/b1\.jpg"\), url\(".*\/w1280\/b1\.jpg"\)$/.test(lay2.bg) && /3040x1710sr\.jpg"\), url\(".*\/1600x900sr\.jpg"\)$/.test(lay2.sr) && !/,/.test(lay2.plain),
    '取了大图的背景下面垫着原来那档：先看得见，原图到了盖上去（没升档的不垫）');
  ok(itunesHits > 0 && !L.slow && !/网络较慢/.test(L.banner), `第三方（iTunes 搜索）失败 ${itunesHits} 次：不算网慢，不进省流模式`);
  const recSl = await p14.evaluate(() => { const r = document.getElementById('todayRecsRow'); return r ? r.scrollLeft : -1; });
  ok(recSl === 0, `「今日推荐」评分到齐、重排之后仍停在第一名（scrollLeft ${recSl}；原来会被 scroll-snap 的吸附跟随带到末尾）`);

  /* 行的左右翻页：找一排放不下的 */
  const has = await p14.evaluate(() => {
    const rows = [...document.querySelectorAll('#view-home .section > .scroll-row')].filter(r => r.scrollWidth > r.clientWidth + 200);
    const r = rows[0]; if (!r) return false;
    r.style.scrollBehavior = 'auto'; r.scrollLeft = 0; r.style.scrollBehavior = '';
    r.parentElement.id = 'rnTest';
    r.scrollIntoView({ block: 'center' });            /* 首页的行都在首屏大图下面 */
    return true;
  });
  await p14.waitForTimeout(250);                      /* 卡还在播入场动画时就把指针放上去：钮按布局落位，不跟着动画偏 */
  const row = has ? await p14.evaluate(() => { const b = document.querySelector('#rnTest .card-poster').getBoundingClientRect(); return { x: b.left + b.width / 2, y: b.top + b.height / 2 }; }) : null;
  ok(!!row, '首页有一排卡放不下（翻页钮有活干）');
  if (row) {
    await p14.mouse.move(row.x, row.y);
    await p14.waitForTimeout(400);
    /* 卡的入场动画 / 悬停放大都停了再比对（负载高时入场动画会晚开） */
    await p14.waitForFunction(() => { const c = document.querySelector('#rnTest .card'); return !!c && c.getAnimations({ subtree: true }).every(a => a.playState !== 'running'); },
      null, { timeout: 8000, polling: 100 }).catch(() => {});
    const rn = await p14.evaluate(() => { const h = document.getElementById('rnTest'); const n = h.querySelector('.row-nav.next'), pv = h.querySelector('.row-nav.prev');
      const pr = h.querySelector('.card-poster').getBoundingClientRect(), nr = n && n.getBoundingClientRect();
      return n ? { hover: h.classList.contains('rn-hover'), prev: pv.classList.contains('can'), next: n.classList.contains('can'), op: +getComputedStyle(n).opacity,
        mid: Math.abs((nr.top + nr.height / 2) - (pr.top + pr.height / 2)), right: Math.round(innerWidth - nr.right) } : null; });
    ok(rn && rn.hover && rn.next && !rn.prev, '指针放到一排上：右侧浮出翻页钮；在最左端时不出左钮');
    ok(rn && rn.mid < 2, `翻页钮落在海报的竖直中线上（差 ${rn && rn.mid.toFixed(1)}px），离屏幕右缘 ${rn && rn.right}px`);
    /* 等平滑滚动停稳（负载高时一屏要滚一秒多）：每 200ms 看一次，两次一样才算停 */
    const settled = pred => p14.waitForFunction(pred, null, { timeout: 8000, polling: 200 }).then(() => true).catch(() => false);
    await p14.click('#rnTest .row-nav.next');
    /* 三次读数（400ms）一样才算停：负载高时平滑滚动两帧之间能隔 200ms 以上，两次一样还可能是半路 */
    await settled(() => { const v = document.querySelector('#rnTest > .scroll-row').scrollLeft; window.__rnSame = v > 0 && window.__rnLast === v ? (window.__rnSame || 0) + 1 : 0; window.__rnLast = v; return window.__rnSame >= 2; });
    const af = await p14.evaluate(() => { const h = document.getElementById('rnTest'), r = h.querySelector(':scope > .scroll-row'), cs = r.querySelectorAll(':scope > .card');
      const pitch = cs[1].getBoundingClientRect().left - cs[0].getBoundingClientRect().left;
      return { sl: r.scrollLeft, pitch, fit: Math.floor(r.clientWidth / pitch), prev: h.querySelector('.row-nav.prev').classList.contains('can') }; });
    const n = af.sl / af.pitch;
    ok(af.sl > 0 && Math.abs(n - Math.round(n)) < 0.05 && Math.round(n) === af.fit && af.prev,
      `点右钮翻一屏：正好 ${Math.round(n)} 张卡（屏上能完整看到的张数），左钮出现`);
    await p14.click('#rnTest .row-nav.prev');
    ok(await settled(() => document.querySelector('#rnTest > .scroll-row').scrollLeft < 2), '点左钮翻回最左');
    await p14.mouse.move(4, 4);
    await p14.waitForTimeout(300);
    ok(await p14.evaluate(() => !document.getElementById('rnTest').classList.contains('rn-hover')), '指针离开：翻页钮收起');
  }

  /* 键盘：/ 与 ⌘K */
  await p14.keyboard.press('/');
  const s1 = await until(p14, () => document.getElementById('searchView').classList.contains('on'), null, 3000).then(() => true).catch(() => false);
  await p14.keyboard.type('a/b');
  const typed = await p14.evaluate(() => document.getElementById('searchInput').value);
  ok(s1 && typed === 'a/b', `「/」打开搜索；搜索框里的「/」照常打字（${typed}）`);
  await p14.keyboard.press('Escape');
  await until(p14, () => !document.getElementById('searchView').classList.contains('on'), null, 3000).catch(() => {});
  await p14.keyboard.press('Meta+k');
  const s2 = await until(p14, () => document.getElementById('searchView').classList.contains('on'), null, 3000).then(() => true).catch(() => false);
  ok(s2, '⌘K 打开搜索');
  await p14.keyboard.press('Escape');
  await until(p14, () => !document.getElementById('searchView').classList.contains('on'), null, 3000).catch(() => {});
  await detail(p14, '/Movies/long.mp4', 'long.mp4');
  await p14.keyboard.press('Meta+k');
  await p14.waitForTimeout(400);
  ok(await p14.evaluate(() => !document.getElementById('searchView').classList.contains('on') && document.getElementById('detailView').classList.contains('on')),
    '详情页开着时 ⌘K 不抢（从详情直接跳搜索会把后退搞乱）');
  await m14.close();

  /* Pro Display XDR：3008×1570（looks like 3008×1692 去掉菜单栏和 Safari 工具栏） */
  const xdr = await context({ viewport: { width: 3008, height: 1570 }, deviceScaleFactor: 2 });
  await xdr.addInitScript(macSafari);
  await xdr.route('https://image.tmdb.org/**', img);
  await xdr.route('https://itunes.apple.com/**', r => r.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' },
    body: JSON.stringify({ results: [{ trackName: 'Long', releaseDate: '2024-05-01T00:00:00Z', artworkUrl100: 'https://is1-ssl.mzstatic.com/image/thumb/Video/x/100x100bb.jpg' }] }) }));
  const px = await enter(xdr, '', 60000);
  await homeReady(px);
  L = await lay(px); P = await pick(px);
  ok(L.p >= 306 && L.p <= 318 && L.l >= 570 && L.l <= 590, `Pro Display XDR（3008）：卡随宽度长到 ${L.p} / ${L.l}（原来 1680 起就封顶 236 / 440）`);
  ok(Math.abs(L.deckH - 1570 * 0.85) < 1.5, `首页大图 ${L.deckH}px = 85vh，不再 860 封顶、下面不再露一截黑`);
  ok(L.hdr >= 27 && L.hdr <= 29 && L.sw === L.vw, `分区标题 ${L.hdr}px；没有横向溢出`);
  ok(/^w780\//.test(P.poster) && /^w1280\//.test(P.land) && P.atv === '3840x2160sr.jpg',
    `大卡取大图：海报 ${P.poster.split('/')[0]}、横卡 ${P.land.split('/')[0]}；Apple TV 大图 ${P.atv}（封顶 3840）`);
  const heroArt = await px.evaluate(() => fetchHeroArtwork({ name: 'long.mp4', path: '/Movies/long.mp4' }).then(a => a.bgUrl));
  ok(/image\.tmdb\.org\/.*\/b9001\.jpg$/.test(heroArt), `横屏大图先用 TMDB 的 16:9 剧照，不拿 2:3 的 iTunes 海报去裁（${heroArt.split('/').slice(-2).join('/')}）`);
  await detail(px, '/Movies/long.mp4', 'long.mp4');
  const dw = await px.evaluate(() => { const b = document.querySelector('.detail-body'), cs = getComputedStyle(b);
    return { w: Math.round(b.getBoundingClientRect().width - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)),
      fs: parseFloat(getComputedStyle(document.querySelector('.detail-row .value, .detail-info-value') || b).fontSize) }; });
  ok(dw.w >= 985 && dw.w <= 1015, `详情页正文宽 ${dw.w}px（原来 600），字 ${dw.fs}px`);
  const bdl = await px.evaluate(() => { const b = document.getElementById('detailBackdrop'); return { bg: b.style.backgroundImage, ready: b.classList.contains('ready') }; });
  ok(bdl.ready && /original\/b9001\.jpg"\), url\(".*\/w1280\/b9001\.jpg"\)/.test(bdl.bg), '详情剧照：揭幕只等 w1280，原图叠在上面');
  await xdr.close();

  /* iPhone / iPad：取图与布局逐项不变 */
  const iph = await context({ ...devices['iPhone 15 Pro'] });
  await iph.route('https://image.tmdb.org/**', img);
  await iph.route('https://itunes.apple.com/**', r => r.fulfill({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': '*' },
    body: JSON.stringify({ results: [{ trackName: 'Long', releaseDate: '2024-05-01T00:00:00Z', artworkUrl100: 'https://is1-ssl.mzstatic.com/image/thumb/Video/x/100x100bb.jpg' }] }) }));
  const pi = await enter(iph, '', 60000);
  await homeReady(pi);
  P = await pick(pi);
  ok(P.hero === 'w1280/b1.jpg' && P.detail === 'w1280/b1.jpg' && P.logo === 'w500/l1.png' && P.poster === 'w500/p1.jpg' && P.land === 'w780/b1.jpg'
    && P.atv === '1600x900sr.jpg' && P.itunes === '1280x1280bb.jpg', 'iPhone：每一处取图都与原来一致（w1280 / w500 / w780，Apple 图床 1280）');
  const iArt = await pi.evaluate(() => fetchHeroArtwork({ name: 'long.mp4', path: '/Movies/long.mp4' }).then(a => a.bgUrl));
  ok(/mzstatic\.com/.test(iArt), '竖屏手机的大图仍先用 iTunes 竖版海报');
  ok(await pi.evaluate(() => !matchMedia('(hover: hover) and (pointer: fine)').matches && !document.querySelector('.row-nav')), '触屏上没有翻页钮');
  await iph.close();
  for (const [label, dev, cw] of [['iPad Pro 11" 横拿', devices['iPad Pro 11 landscape'], [196, 360]], ['iPad 竖拿 820×1180', { ...devices['iPad Pro 11'], viewport: { width: 820, height: 1180 } }, [196, 360]]]) {
    const ic = await context(dev);
    await ic.route('https://image.tmdb.org/**', img);
    const pg = await enter(ic, '', 60000);
    await homeReady(pg);
    const l = await lay(pg), pk = await pick(pg);
    const vh = dev.viewport.height;
    ok(l.p === cw[0] && l.l === cw[1] && l.deckH === Math.round(Math.min(vh * 0.85, 860)) && pk.hero === 'w1280/b1.jpg' && pk.poster === 'w500/p1.jpg',
      `${label}：卡 ${l.p} / ${l.l}、大图 ${l.deckH}px、取图 ${pk.hero.split('/')[0]} / ${pk.poster.split('/')[0]} —— 与原来一致`);
    await ic.close();
  }
  delete H.env.TMDB_API_KEY; H.tmdb.movies = [];
}

console.log('\n■ 没有封面的影片不显示（确定的答案才算，网络出错不算）');
{
  H.env.TMDB_API_KEY = 'tmdb-test';
  caches.default.m.clear();         /* Worker 的 TMDB 结果缓存跨节共享：上一节那份片单的「认不出」不能带进来 */
  const q = f => f.replace(/\.[^.]+$/, '').replace(/[._]/g, ' ').toLowerCase().replace(/ hdr$/, '');
  const files = fs.readdirSync(path.join(HERE, 'samples')).filter(f => /\.(mkv|mp4)$/.test(f) && !/^long/.test(f));
  H.tmdb.movies = [{ id: 9001, query: 'long', title: '漫长的测试', date: '2024-05-01' },
    ...files.filter(f => !/^(dv81|hdr10_multi)\./.test(f)).map((f, i) => ({ id: 9200 + i, query: q(f), title: '样片' + i, date: '2020-05-01' })),
    { id: 9300, query: 'dv81', title: '没有海报', date: '2021-01-01', poster: null }];     // 认得出，但 TMDB 上没有海报
  // hdr10_multi：TMDB 里根本没有；avc_zsub：这一次 TMDB 出错（不能当成没有）
  H.tmdb.fail = (p, qq) => (qq.query || '') === 'avc zsub';
  const img = r => r.fulfill({ status: 200, contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>' });
  const nc = await context({ viewport: { width: 1280, height: 800 } });
  await nc.route('https://image.tmdb.org/**', img);
  const np = await enter(nc);
  await until(np, () => document.querySelectorAll('#view-home .card[data-path]').length > 0, null, 20000);
  /* 首页的行都在大图下面：滚一遍，让每一排的海报都去取 */
  await np.evaluate(async () => { for (let y = 0; y < document.body.scrollHeight; y += 500) { scrollTo(0, y); await new Promise(r => setTimeout(r, 120)); } scrollTo(0, 0); });
  const gone = await until(np, () => !document.querySelector('.card[data-name="dv81.mkv"]') && !document.querySelector('.card[data-name="hdr10_multi.mkv"]'), null, 20000)
    .then(() => true).catch(() => false);
  await np.waitForTimeout(6000);                     /* 后台补中文名那一轮（kick 5s）也把整库问了一遍 */
  /* 首页排哪些片子跟片单有关（样片多一个就换一批），只看「排出来的都是有海报的、而且不少」 */
  const kept = await np.evaluate(() => ({ cards: [...new Set([...document.querySelectorAll('#view-home .card[data-name]')].map(c => c.dataset.name))],
    none: JSON.parse(localStorage.getItem('art_none_v1') || '{}') }));
  ok(gone && 'dv81.mkv' in kept.none && 'hdr10_multi.mkv' in kept.none, '认得出但没有海报的（dv81）、TMDB 里没有的（hdr10_multi）：屏上的卡收起来，并记下');
  await np.evaluate(async () => { await openSearch(); runSearch('avc'); });   /* openSearch 末尾会铺初始页，等它完再搜 */
  await np.waitForTimeout(500);
  const zsub = await np.evaluate(() => !!document.querySelector('#searchBody .card[data-name="avc_zsub.mkv"]'));
  ok(zsub && !('avc_zsub.mkv' in kept.none) && kept.cards.length >= 8,
    `TMDB 这次出错的（avc_zsub）照常显示（搜得到）、不记账；有海报的照常（首页 ${kept.cards.length} 部）`);
  await np.evaluate(() => closeSearch());
  const ranks = await np.evaluate(() => [...document.querySelectorAll('#todayRecsRow .card .card-rank')].map(b => +b.textContent));
  ok(ranks.length > 0 && ranks.every((r, i) => r === i + 1), `「今日推荐」的名次连续（${ranks.join(',')}）`);
  await np.close();
  /* 再进一次：已知没有封面的，一开始就不排（不是先出来再收） */
  H.tmdb.fail = null;
  const np2 = await nc.newPage();
  await np2.addInitScript(() => {
    window.__seen = new Set();
    new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => { if (n.querySelectorAll) n.querySelectorAll('.card[data-name]').forEach(c => window.__seen.add(c.dataset.name)); }))).observe(document, { childList: true, subtree: true });
  });
  await np2.goto(ORIGIN);
  await np2.waitForFunction(() => typeof playVideo === 'function', null, { timeout: 15000 });
  if (await np2.$('#wc-cta')) { await np2.click('#wc-cta'); await np2.waitForSelector('#wc-root', { state: 'detached', timeout: 15000 }); }
  await until(np2, () => document.querySelectorAll('#view-home .card[data-path]').length > 0, null, 20000);
  await np2.waitForTimeout(1500);
  const seen = await np2.evaluate(() => [...window.__seen]);
  ok(!seen.includes('dv81.mkv') && !seen.includes('hdr10_multi.mkv') && seen.length >= 8, `再次打开：没有封面的从头到尾没被排出来过（排出来 ${seen.length} 部）`);
  await np2.evaluate(() => { openSearch(); });
  await np2.fill('#searchInput', 'dv81');
  await np2.evaluate(() => runSearch('dv81'));
  await np2.waitForTimeout(400);
  ok(await np2.evaluate(() => !document.querySelector('#searchBody .card[data-name="dv81.mkv"]')), '搜索里也不出现');
  await nc.close();
  delete H.env.TMDB_API_KEY; H.tmdb.movies = [];
}

console.log('\n■ 年份页：一行一部的列表（竖版小海报 + 中文片名 + 类型 + 「…」，行间发丝线）');
{
  /* 样片的文件名里没有年份：临时挂几个带 2024 的硬链接当这一年的片子，跑完删掉 */
  const SM = f => path.join(HERE, 'samples', f);
  const YL = [['Dune.Part.Two.2024.2160p.DV.mkv', 'dv81.mkv', 'dune part two', '沙丘2', [878, 12]],
    ['Inside.Out.2.2024.1080p.mkv', 'avc_zsub.mkv', 'inside out 2', '头脑特工队2', [16, 10751]],
    ['Civil.War.2024.1080p.mkv', 'nocues.mkv', 'civil war', '美国内战', [10752, 28]]];
  for (const [n, src] of YL) { try { fs.unlinkSync(SM(n)); } catch {} fs.linkSync(SM(src), SM(n)); }
  const tv0 = H.tv.entries, shows0 = H.tmdb.shows;
  try {
    H.env.TMDB_API_KEY = 'tmdb-test';
    caches.default.m.clear();
    H.tmdb.movies = YL.map(([, , q, zh, g], i) => ({ id: 9500 + i, query: q, title: zh, date: '2024-03-01', genres: g }));
    H.tv.entries = [1, 2, 3].map(i => ({ path_display: `/ram2/Shogun.S01.2160p.DV/Shogun.S01E0${i}.mkv`, size: 5000, server_modified: '2026-03-01T00:00:00Z' }));
    H.tmdb.shows = [{ id: 126308, name: '幕府将军', original: 'Shogun', first: '2024-02-27', seasons: [{ n: 1, air: '2024-02-27', count: 10 }] }];
    /* 剧集表在 Worker 进程里留 10 分钟：前面几节已经扫过一张空表，这里强制重扫一次 */
    const tvRefresh = async () => { await H.worker.fetch(new Request('https://stream.cuven.online/api/tv?refresh=1'), H.env, H.ctx); while (H.pending.length) await Promise.all(H.pending.splice(0)); };
    await tvRefresh();
    const img = r => r.fulfill({ status: 200, contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>' });
    const yc = await context({ ...devices['iPhone 15 Pro'] });
    await yc.route('https://image.tmdb.org/**', img);
    const yp = await enter(yc);
    await yp.waitForTimeout(800);
    await yp.evaluate(() => openYearLibrary(2024));
    await until(yp, () => document.querySelectorAll('#yearList .yl-row').length >= 3 && !!document.querySelector('.yl-tv-section:not([hidden]) .yl-row'), null, 12000);
    await until(yp, () => [...document.querySelectorAll('#yearList .yl-genre')].every(g => g.textContent !== '电影'), null, 8000).catch(() => {});
    await until(yp, () => [...document.querySelectorAll('#yearList .yl-row')].every(r => r.querySelector('img.main-img')), null, 8000).catch(() => {});
    const L = await yp.evaluate(() => {
      const rows = [...document.querySelectorAll('.yl-row')];
      return rows.map(r => {
        const t = r.querySelector('.yl-thumb').getBoundingClientRect(), b = r.getBoundingClientRect(), m = r.querySelector('.yl-more').getBoundingClientRect();
        const sep = getComputedStyle(r, '::before');
        return { title: r.querySelector('.card-title').textContent, sub: r.querySelector('.yl-genre').textContent, tags: r.querySelectorAll('.tag-border').length,
          ratio: +(t.height / t.width).toFixed(2), thumbLeft: Math.round(t.left - b.left), sepLeft: parseFloat(sep.left), textLeft: Math.round(r.querySelector('.yl-copy').getBoundingClientRect().left - b.left),
          moreRight: Math.round(b.right - m.right), img: (r.querySelector('img.main-img, img.tv-art-img') || {}).src || '', tv: !!r.dataset.tvPath };
      });
    });
    const mv = L.filter(x => !x.tv), tvr = L.filter(x => x.tv);
    ok(mv.length === 3 && mv.every(x => /[\u4e00-\u9fff]/.test(x.title) && Math.abs(x.ratio - 1.5) < 0.05 && x.thumbLeft === 0 && x.moreRight <= 2),
      `电影一行一部：竖版小海报在最左（2:3）、中文片名、「…」在行尾（${mv.map(x => x.title).join(' / ')}）`);
    /* 模拟的 TMDB 详情一律回「剧情」：被首页大图先取过详情的那部会是「剧情」，其余是搜索结果里那两个类型 */
    const viaSearch = mv.filter(x => /^(科幻 · 冒险|动画 · 家庭|战争 · 动作)$/.test(x.sub));
    ok(mv.every(x => x.sub && x.sub !== '电影' && x.tags === 0) && tvr.every(x => x.tags === 0) && viaSearch.length >= 1,
      `副标题只有类型（${mv.map(x => x.sub).join(' / ')}），没有 DV / 8K+ / 高动态这类规格小标签；类型来自 TMDB 搜索结果自带的类型编号，不多花请求`);
    ok(L.every(x => Math.abs(x.sepLeft - x.textLeft) <= 1), '行间发丝线从文字那一列起头，海报底下不画');
    ok(mv.every(x => /\/w185\//.test(x.img)), `小海报取 w185（${(mv[0] && mv[0].img.split('/t/p/')[1]) || ''}），不拉卡片那种大图`);
    ok(tvr.length === 1 && tvr[0].title === '幕府将军' && /集/.test(tvr[0].sub) && Math.abs(tvr[0].ratio - 1.5) < 0.05,
      `剧集一组排在电影下面：${tvr[0] && tvr[0].title}（${tvr[0] && tvr[0].sub}）`);
    /* 「…」：电影是文件弹层（播放 / 复制直链），不会顺带点开详情 */
    await yp.click('#yearList .yl-row:first-child .yl-more');
    await yp.waitForTimeout(500);
    const sh1 = await yp.evaluate(() => ({ on: document.getElementById('sheetMenu').classList.contains('on'), text: document.getElementById('sheetBody').textContent,
      detail: document.getElementById('detailView').classList.contains('on') }));
    ok(sh1.on && /播放/.test(sh1.text) && /复制直链/.test(sh1.text) && !sh1.detail, '电影的「…」：弹出「播放 / 复制直链」，不点开详情');
    await yp.evaluate(() => closeSheet());
    await yp.waitForTimeout(400);
    /* 剧集的「…」：「从第 1 集看起 / 查看分集」，查看分集进剧集详情 */
    await yp.click('.yl-tv-section .yl-row .yl-more');
    await yp.waitForTimeout(500);
    const sh2 = await yp.evaluate(() => document.getElementById('sheetBody').textContent);
    ok(/从第 1 集看起/.test(sh2) && /查看分集/.test(sh2), '剧集的「…」：弹出「从第 1 集看起 / 查看分集」');
    await yp.click('#sheetBody [data-yl-act="detail"]');
    const d1 = await until(yp, () => document.getElementById('detailView').classList.contains('on'), null, 8000).then(() => true).catch(() => false);
    ok(d1, '「查看分集」进剧集详情');
    await yp.evaluate(() => closeDetail());
    await yp.waitForTimeout(700);
    /* 点整行：进这部片的详情 */
    await yp.click('#yearList .yl-row:first-child .card-title');
    const d2 = await until(yp, () => document.getElementById('detailView').classList.contains('on'), null, 8000).then(() => true).catch(() => false);
    ok(d2, '点整行进详情（与卡片一样）');
    await yp.evaluate(() => closeDetail());
    await yp.waitForTimeout(900);
    ok(await yp.evaluate(() => state.currentTab === 'library' && state.libraryYear === 2024 && document.getElementById('pageBack').classList.contains('on') && history.state && history.state.view === 'sub'),
      '在年份页上开详情再关掉：还停在年份页（原来详情页自己退的那一格历史会被当成「后退」，把年份页也退掉）');
    await yc.close();

    /* 宽屏：排成几列，每一列各自是一条列表；第一排没有顶线 */
    const wc2 = await context({ viewport: { width: 1280, height: 800 } });
    await wc2.route('https://image.tmdb.org/**', img);
    const wp = await enter(wc2);
    await wp.waitForTimeout(800);
    await wp.evaluate(() => openYearLibrary(2024));
    await until(wp, () => document.querySelectorAll('#yearList .yl-row').length >= 3, null, 12000);
    const W = await wp.evaluate(() => {
      const rows = [...document.querySelectorAll('#yearList .yl-row')].map(r => r.getBoundingClientRect());
      const cols = new Set(rows.map(r => Math.round(r.left))).size, firstTop = Math.round(rows[0].top);
      return { cols, sameRow: rows.filter(r => Math.round(r.top) === firstTop).length, clip: getComputedStyle(document.querySelector('#yearList .yl-list')).clipPath };
    });
    ok(W.cols >= 2 && W.sameRow >= 2 && /inset\(1px/.test(W.clip), `宽屏排成 ${W.cols} 列，第一排的顶线裁掉（clip-path ${W.clip}）`);
    await wc2.close();

    /* iPhone Duo 折起竖拿：列表右端让出右缘那一列浮动导航 */
    const dc = await context({ isMobile: true, hasTouch: true, screen: { width: 466, height: 678 }, viewport: { width: 466, height: 678 },
      userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 27_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Mobile/15E148 Safari/604.1' });
    await dc.route('https://image.tmdb.org/**', img);
    const dp = await enter(dc);
    await (await dc.newCDPSession(dp)).send('Emulation.setSafeAreaInsetsOverride', { insets: { top: 0, right: 84, bottom: 20, left: 0 } });
    await dp.waitForTimeout(800);
    await dp.evaluate(() => openYearLibrary(2024));
    await until(dp, () => document.querySelectorAll('#yearList .yl-row').length >= 3, null, 12000);
    const F = await dp.evaluate(() => ({ more: Math.max(...[...document.querySelectorAll('.yl-more')].map(b => b.getBoundingClientRect().right)),
      nav: document.getElementById('dock').getBoundingClientRect().left, float: document.documentElement.classList.contains('rail-float') }));
    ok(F.float && F.more <= F.nav - 8 && F.nav >= 466 - 84, `折起竖拿（实机的右侧安全区）：导航在右缘那一列里（${Math.round(F.nav)}），「…」停在它左边（${Math.round(F.more)}），不钻到导航底下`);
    await dc.close();
  } finally {
    for (const [n] of YL) { try { fs.unlinkSync(SM(n)); } catch {} }
    H.tv.entries = tv0; H.tmdb.shows = shows0;
    /* 剧集表也还原：后面几节看到的还是原来那张 */
    try { await H.worker.fetch(new Request('https://stream.cuven.online/api/tv?refresh=1'), H.env, H.ctx); while (H.pending.length) await Promise.all(H.pending.splice(0)); } catch (_) {}
    delete H.env.TMDB_API_KEY; H.tmdb.movies = [];
    caches.default.m.clear();
  }
}

console.log('\n■ 今日推荐：大号描边名次 + 海报压在数字右缘 + 「最近添加」');
{
  H.env.TMDB_API_KEY = 'tmdb-test';
  caches.default.m.clear();
  const q = f => f.replace(/\.[^.]+$/, '').replace(/[._]/g, ' ').toLowerCase().replace(/ hdr$/, '');
  const files = fs.readdirSync(path.join(HERE, 'samples')).filter(f => /\.(mkv|mp4)$/.test(f) && !/^long/.test(f));
  H.tmdb.movies = [{ id: 9001, query: 'long', title: '漫长的测试', date: '2024-05-01' }, ...files.map((f, i) => ({ id: 9200 + i, query: q(f), title: '样片' + i, date: '2020-05-01' }))];
  const img = r => r.fulfill({ status: 200, contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>' });
  const rc = await context({ ...devices['iPhone 15 Pro'] });
  await rc.route('https://image.tmdb.org/**', img);
  const rp = await enter(rc);
  await until(rp, () => document.querySelectorAll('#todayRecsRow .card.rank-card').length >= 10, null, 20000);
  await rp.evaluate(() => document.getElementById('todayRecsSection').scrollIntoView({ block: 'center' }));
  await rp.waitForTimeout(1500);
  const R = await rp.evaluate(() => {
    const cards = [...document.querySelectorAll('#todayRecsRow .card.rank-card')];
    return cards.map((c, i) => {
      const k = c.querySelector(':scope > .card-rank'), q = c.querySelector('.card-poster'), kr = k && k.getBoundingClientRect(), qr = q.getBoundingClientRect(), cs = k && getComputedStyle(k);
      const info = c.querySelector('.card-info');
      return { n: k ? +k.textContent : 0, outside: !!k && !q.contains(k), stroke: cs ? parseFloat(cs.webkitTextStrokeWidth) || 0 : 0, fill: cs ? cs.color : '',
        left: kr ? Math.round(kr.left) : 0, right: kr ? Math.round(kr.right) : 0, pl: Math.round(qr.left), pb: Math.round(qr.bottom), kb: kr ? Math.round(kr.bottom) : 0,
        big: kr ? kr.height > qr.height * 0.55 : false, rk2: c.classList.contains('rk2'), title: info ? info.getBoundingClientRect().width <= 1 : true, label: c.getAttribute('aria-label') || '' };
    });
  });
  ok(R.length >= 10 && R.every((x, i) => x.n === i + 1 && x.outside && x.big && x.stroke >= 2 && /rgba\(0, 0, 0, 0\)|transparent/.test(x.fill)),
    `名次是海报左边的大号描边数字（只描边不填色，${R.length} 张，1 → ${R.length} 连续）`);
  ok(R.every(x => x.left < x.pl && x.right > x.pl && Math.abs(x.kb - x.pb) <= 30), '数字在海报左边、右缘被海报盖住，底边与海报底边对齐');
  ok(R.every((x, i) => x.rk2 === (i + 1 >= 10)) && R.every(x => x.title) && R.every((x, i) => x.label.startsWith('第 ' + (i + 1) + ' 名，')),
    '两位数（10 起）那一格放宽；海报下不再写片名（读屏照读「第 N 名，片名」）');
  /* 「最近添加」：两周内入库的才挂 */
  const NB = await rp.evaluate(() => {
    const mk = days => videoCardHTML({ name: 'Probe.2024.1080p.mkv', path: '/Movies/probe.mkv', added: new Date(Date.now() - days * 86400000).toISOString() }, { rank: 3 });
    const plain = videoCardHTML({ name: 'Probe.2024.1080p.mkv', path: '/Movies/probe.mkv', added: new Date().toISOString() }, {});
    return { fresh: /card-new[^>]*>最近添加/.test(mk(3)), old: /card-new/.test(mk(40)), plain: /card-new/.test(plain) };
  });
  ok(NB.fresh && !NB.old && !NB.plain, '「最近添加」只挂在两周内入库的名次卡上（40 天前的不挂，别的排也不挂）');
  await rc.close();
  delete H.env.TMDB_API_KEY; H.tmdb.movies = [];
  caches.default.m.clear();
}

console.log('\n■ 登录页：品牌区（流体底图 + Cuven max 字标 + 蓝色脉冲）+ 白色面板');
{
  for (const [label, opt] of [['iPhone', { ...devices['iPhone 15 Pro'], deviceScaleFactor: 2 }], ['Mac', { viewport: { width: 1440, height: 900 } }]]) {
    const lc = await browser.newContext(opt);
    await lc.addInitScript(() => { localStorage.setItem('cuven_privacy_consent_v1', JSON.stringify({ v: '2026-07-18', ts: Date.now() })); });
    await lc.route('**/*', r => r.request().url().startsWith(ORIGIN) ? r.continue() : r.abort());
    const lp = await lc.newPage();
    lp.on('pageerror', e => errors.push('login: ' + e.message));
    await lp.goto(ORIGIN);
    await lp.waitForFunction(() => window.CuvenLogin && document.getElementById('tvAuthLayer'), null, { timeout: 15000 });
    if (await lp.$('#wc-cta')) { try { await lp.click('#wc-cta', { timeout: 3000 }); } catch (_) {} }
    await lp.waitForTimeout(400);
    if (!(await lp.evaluate(() => document.getElementById('tvAuthLayer').classList.contains('is-open')))) await lp.evaluate(() => enforceTVLoginGate());
    await lp.waitForTimeout(1600);
    const L = await lp.evaluate(() => {
      const r = s => document.querySelector(s).getBoundingClientRect();
      const sheet = r('#cvlSheet'), word = r('#cvlHost .cvl-word'), title = r('#cvlSiTitle'), input = r('#cvlUser'), cta = r('#cvlSiBtn'), foot = r('#cvlFoot');
      const cs = s => getComputedStyle(document.querySelector(s));
      const w = document.querySelector('#cvlHost .cvl-word');
      return { wordText: [...w.children].map(e => e.textContent).join(' ') + '|' + w.getAttribute('aria-label'), wordAbove: word.bottom <= sheet.top + 1,
        bgUnder: document.getElementById('cvlViz').getBoundingClientRect().top <= 0, sheetBg: cs('#cvlSheet').backgroundColor,
        order: sheet.top < title.top && title.bottom < input.top && input.bottom < cta.top && cta.bottom < foot.top,
        titleLeft: cs('#cvlSiTitle').textAlign, ctaBg: cs('#cvlSiBtn').backgroundColor, inputBg: cs('#cvlUser').backgroundColor,
        pulse: document.getAnimations().some(a => a.effect && a.effect.target && /cvlGlow|cvlRing1/.test(a.effect.target.id || '')),
        wide: sheet.width < innerWidth - 40, radius: cs('#cvlSheet').borderTopLeftRadius };
    });
    ok(L.wordText === 'Cuven max|Cuven max' && L.wordAbove && L.bgUnder, `${label}：Cuven max 字标在品牌区（白色面板上沿之上），底下是流体底图`);
    ok(L.sheetBg === 'rgb(255, 255, 255)' && parseFloat(L.radius) >= 30 && L.order && L.titleLeft === 'left',
      `${label}：白色圆角面板，从上到下「Cuven 账户」→ 大标题（左对齐）→ 输入框 → 主按钮 → 账户说明`);
    ok(/rgb\(23[0-9], 23[0-9], 24[0-9]\)/.test(L.inputBg) && L.pulse, `${label}：浅灰填充的输入框；打开时蓝色脉冲从字标扩出去一次`);
    if (label === 'Mac') ok(L.wide, 'Mac：面板收成居中的一张卡，四周露出流体');
    await lp.fill('#cvlUser', 'someone');
    await lp.waitForTimeout(200);
    ok(await lp.evaluate(() => getComputedStyle(document.getElementById('cvlSiBtn')).backgroundColor !== ''), `${label}：输入后主按钮照常可交互`);
    await lc.close();
  }
}

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
