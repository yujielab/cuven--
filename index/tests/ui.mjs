// 索引库页面的界面回归（Playwright + 本地模拟数据）：node index/tests/ui.mjs
// 验证 v6 设计改版里容易回退的几件事：坞的白 thumb 跟着选中项走、片单胶囊升降、
// 手机上顶栏一行放得下（含返回键）、没有横向滚动、页面脚本零报错、深色模式也一样。
import http from 'node:http';
import { createRequire } from 'node:module';
import * as H from './harness.mjs';

const { chromium, devices } = createRequire(import.meta.url)('playwright');
let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log('  ✓', m); } else { fail++; console.log('  ✗', m); } };

/* 一个有内容的小索引：两年、十几部片、每部几个版本，片库总账里有几部 */
const { env, W } = H.makeEnv({ RECV_BASE: 'https://recv.test' });
const NAMES = [['沙丘：第二部', 'Dune Part Two'], ['奥本海默', 'Oppenheimer'], ['芭比', 'Barbie'], ['流浪地球2', 'The Wandering Earth II'],
  ['满江红', 'Full River Red'], ['封神第一部', 'Creation of the Gods'], ['长安三万里', 'Chang An'], ['孤注一掷', 'No More Bets'],
  ['消失的她', 'Lost in the Stars'], ['热辣滚烫', 'YOLO'], ['飞驰人生2', 'Pegasus 2'], ['第二十条', 'Article 20'], ['坚如磐石', 'Under the Light'], ['巨齿鲨2', 'Meg 2']];
let tid = 40000;
const boards = { 2025: [], 2024: [] };
NAMES.forEach(([cn, en], i) => {
  const y = i % 2 ? 2025 : 2024, id = 700000 + i;
  W.tmdb.movie.push({ id, title: cn, original_title: en, release_date: y + '-03-01', poster_path: '/p' + i + '.jpg', popularity: 30, vote_average: 7 + (i % 3) * .4, vote_count: 900 });
  for (let v = 0; v < 1 + (i % 3); v++) boards[y].push({ tid: tid++, title: `${cn} ${en.replace(/ /g, '.')}.${y}.${['2160p.WEB-DL.DV.HEVC', '1080p.BluRay.x264', '720p.WEB-DL.x264'][v]} ${12 - v * 4}.5GB` });
});
W.forum.boards['44'] = { 'movie_nianfen=32': boards[2025], 'movie_nianfen=31': boards[2024] };
W.recv.meta = { gen: 'u1' };
W.recv.doc = { gen: 'u1', items: [{ key: 'a', kind: 'movie', name: 'x.mkv', tmdb: 700000, type: 'movie', title: NAMES[0][0], orig: NAMES[0][1], year: '2024' }] };
const I = H.isolate(env, W);
for (let i = 0; i < 30; i++) { const r = await (await I.call('/api/build')).json(); if (r.done || r.error) break; }
await I.call('/api/lib?refresh=1'); await I.settle();

const srv = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/img') { res.writeHead(200, { 'content-type': 'image/svg+xml' }); res.end('<svg xmlns="http://www.w3.org/2000/svg" width="20" height="30"><rect width="20" height="30" fill="#456"/></svg>'); return; }
  const chunks = []; for await (const c of req) chunks.push(c);
  const r = await I.call(url.pathname + url.search, { method: req.method, headers: req.headers, ...(chunks.length ? { body: Buffer.concat(chunks) } : {}) });
  const h = {}; r.headers.forEach((v, k) => { h[k] = v; });
  res.writeHead(r.status, h); res.end(Buffer.from(await r.arrayBuffer()));
});
await new Promise(r => srv.listen(0, '127.0.0.1', r));
const base = 'http://127.0.0.1:' + srv.address().port + '/';

const b = await chromium.launch();
async function page(opt) {
  const ctx = await b.newContext(opt);
  const p = await ctx.newPage();
  const errs = [];
  p.on('pageerror', e => errs.push(e.message));
  p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.goto(base, { waitUntil: 'networkidle' });
  await p.waitForTimeout(500);
  return { p, ctx, errs };
}
const thumb = (p) => p.evaluate(() => {
  const hl = document.querySelector('#nav .hl'), on = document.querySelector('#nav button.on');
  if (!hl || !on) return null;
  const a = hl.getBoundingClientRect(), c = on.getBoundingClientRect();
  return { dx: Math.abs(a.left - c.left), dw: Math.abs(a.width - c.width), shown: getComputedStyle(hl).opacity !== '0' };
});
const settle = (p) => p.waitForTimeout(650);

for (const [label, opt] of [['手机', { ...devices['iPhone 14'] }], ['手机 · 深色', { ...devices['iPhone 14'], colorScheme: 'dark' }], ['桌面', { viewport: { width: 1280, height: 860 } }], ['平板竖屏', { viewport: { width: 820, height: 1180 } }]]) {
  console.log('\n■ ' + label);
  const { p, ctx, errs } = await page(opt);
  const phone = (opt.viewport ? opt.viewport.width : 390) <= 720;
  const nav = await p.evaluate(() => { const r = document.getElementById('nav').getBoundingClientRect(); return { top: r.top, bottom: innerHeight - r.bottom, pos: getComputedStyle(document.getElementById('nav')).position }; });
  ok(phone ? (nav.pos === 'fixed' && nav.bottom >= 10 && nav.bottom < 60) : (nav.pos !== 'fixed' && nav.top < 30), phone ? '导航落成底部的玻璃坞' : '导航在顶栏里');
  const overflow = await p.evaluate(() => document.documentElement.scrollWidth - innerWidth);
  ok(overflow <= 0, '没有横向滚动（多出 ' + overflow + 'px）');
  let t = await thumb(p);
  ok(t && t.shown && t.dx < 1.5 && t.dw < 1.5, '坞的白 thumb 对准选中项「片库」');
  for (const v of ['dl', 'idx', 'lib']) {
    await p.click('#nav button[data-v="' + v + '"]');
    await settle(p);
    t = await thumb(p);
    if (!(t && t.dx < 1.5 && t.dw < 1.5)) break;
  }
  ok(t && t.dx < 1.5 && t.dw < 1.5, '切到片单 / 系统 / 片库，thumb 每次都平移到选中项上');
  const cap0 = await p.evaluate(() => document.getElementById('dock').classList.contains('up'));
  await p.locator('.grid .art').nth(1).click();
  await settle(p);
  const cap = await p.evaluate(() => {
    const d = document.getElementById('dock'), r = d.getBoundingClientRect(), n = document.getElementById('nav').getBoundingClientRect();
    return { up: d.classList.contains('up'), above: r.bottom <= n.top + 1 || n.top < 100, cnt: document.getElementById('ncart').textContent, radius: getComputedStyle(d).borderRadius };
  });
  ok(!cap0 && cap.up && cap.above && cap.cnt === '1', '点海报加入片单：胶囊升起' + (phone ? '、坐在坞的上方' : '') + '，坞上的片单数是 1');
  await p.click('#dclr');
  await settle(p);
  ok(!(await p.evaluate(() => document.getElementById('dock').classList.contains('up'))), '清空片单：胶囊收回');
  await p.locator('.tname').nth(2).click();
  await settle(p);
  const hd = await p.evaluate(() => {
    const h = document.querySelector('header').getBoundingClientRect();
    const t = document.querySelector('#pushIn h2');
    const tr = t ? t.getBoundingClientRect() : null;
    const els = ['#back', '.brand', '#srcNav', '#theme'].map(s => document.querySelector(s).getBoundingClientRect().top);
    return { oneRow: Math.max(...els) - Math.min(...els) < 12, titleBelow: tr ? tr.top >= h.bottom - 1 : false };
  });
  ok(hd.oneRow && hd.titleBelow, '详情页：返回键、商标、源开关、外观钮在同一行，片名不被顶栏盖住');
  /* 极限模式开关：默认开、点一下关并记在本机、再点回来；描述跟着变 */
  await p.click('#back').catch(() => {});
  await p.click('#nav button[data-v="idx"]');
  await p.waitForSelector('#turbo', { timeout: 5000 }).catch(() => {});
  await settle(p);
  const sw0 = await p.evaluate(() => { const b = document.getElementById('turbo'); if (!b) return null; const r = b.getBoundingClientRect(); return { on: b.getAttribute('aria-checked'), w: r.width, h: r.height, d: document.getElementById('tdesc').textContent, dis: b.disabled }; });
  await p.click('#turbo'); await p.waitForTimeout(700);
  const sw1 = await p.evaluate(() => ({ on: document.getElementById('turbo').getAttribute('aria-checked'), ls: localStorage.getItem('cvturbo'), d: document.getElementById('tdesc').textContent, plan: document.getElementById('k-plan') ? document.getElementById('k-plan').textContent : '' }));
  await p.click('#turbo'); await p.waitForTimeout(700);
  const sw2 = await p.evaluate(() => ({ on: document.getElementById('turbo').getAttribute('aria-checked'), ls: localStorage.getItem('cvturbo'), lens: getComputedStyle(document.querySelector('#turbo .lens')).transform }));
  ok(sw0 && sw0.on === 'true' && !sw0.dis && sw0.w >= 50 && sw1.on === 'false' && sw1.ls === '0' && sw1.d !== sw0.d && /3 页/.test(sw1.plan) && sw2.on === 'true' && sw2.ls === '1',
    '极限模式开关：默认开；点一下关掉并记在本机、描述与管线里的单轮配置跟着变；再点回来');
  if (!phone && opt.viewport && opt.viewport.width >= 1000) {
    /* 点一个年份：用极限模式把这一年重走一遍（帖子都已入库，几轮就收尾），跑的时候开关锁住、描述变成实时状态 */
    await p.evaluate(() => { const d = document.querySelector('details[data-x="years"]'); if (d) d.open = true; });
    await p.waitForTimeout(200);
    /* 跑得很快（帖子都已入库），所以在页面里每帧记一次运行中的样子 */
    await p.evaluate(() => { window.__run = { dis: false, line: '' }; window.__iv = setInterval(() => {
      if (!document.getElementById('stop')) return;
      const t = document.getElementById('turbo'), l = document.getElementById('sysline');
      if (t && t.disabled) window.__run.dis = true;
      if (l && /极限模式/.test(l.textContent)) window.__run.line = l.textContent;
    }, 10); });
    await p.click('.yr[data-y="2025"]');
    let doneTxt = '';
    for (let i = 0; i < 60; i++) {
      await p.waitForTimeout(250);
      doneTxt = await p.evaluate(() => document.getElementById('stop') ? '' : [].map.call(document.querySelectorAll('#logrows .lm'), e => e.textContent).join(' | '));
      if (doneTxt) break;
    }
    const running = await p.evaluate(() => { clearInterval(window.__iv); return window.__run; });
    ok(running.dis && /极限模式/.test(running.line) && /完成/.test(doneTxt), '极限模式跑一年：跑的时候开关锁住、状态句写着「极限模式」，几轮就收尾（' + (doneTxt.split(' | ')[0] || '没收尾') + '）');
  }
  await p.click('#theme');
  await p.waitForTimeout(200);
  const th = await p.evaluate(() => document.documentElement.getAttribute('data-theme'));
  ok(['light', 'dark', 'auto'].includes(th), '外观钮能切换（' + th + '）');
  ok(!errs.length, '页面零报错' + (errs.length ? '：' + errs.slice(0, 3).join(' | ') : ''));
  await ctx.close();
}
await b.close();
srv.close();
console.log(`\n${fail ? '✗' : '✓'} ${pass} 通过，${fail} 失败`);
process.exit(fail ? 1 : 0);
