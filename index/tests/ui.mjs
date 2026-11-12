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
/* Stream v25 的实时清单：两部在库里（一部总账也认得，一部只有文件名） */
const fn = (i, y) => `${NAMES[i][0]}.${NAMES[i][1].replace(/ /g, '.')}.${y}.2160p.WEB-DL.x265.mkv`;
W.recv.files = { root: '/ram', _gen: 'u1', _ts: Date.now() - 120000, videos: [{ name: 'x.mkv', path: '/ram/x.mkv' }, { name: fn(2, 2024), path: '/ram/' + fn(2, 2024) }] };
W.recv.ptr = { g: 'u1' };
W.recv.doc.items[0].path = '/ram/x.mkv';
/* [v6.7] 只在论坛搜索里有的剧（剧集索引是空的）：一部有全集，一部只有单集 */
W.tmdb.tv.push({ id: 520001, name: '夫妻的博弈', original_name: 'Mrs Revenge', first_air_date: '2026-03-01', poster_path: '/s1.jpg', popularity: 9, vote_average: 7, vote_count: 50 });
W.tmdb.tv.push({ id: 520002, name: '风，带有香气', original_name: 'Kaze Kaoru', first_air_date: '2026-03-01', poster_path: '/s2.jpg', popularity: 9, vote_average: 7, vote_count: 50 });
W.forum.searchOnly = [
  { tid: 90001, fid: 2, title: '夫妻的博弈[高码版][全25集][国粤多音轨/中文字幕].Mrs.Revenge.S01.2026.2160p.HQ.WEB-DL.H265.AAC.2Audio-BlackTV 123.42GB' },
  { tid: 90002, fid: 2, title: '夫妻的博弈[第25集][中文字幕].Mrs.Revenge.S01E25.2026.2160p.WEB-DL.H265.DV-BlackTV 5.1GB' },
  { tid: 90003, fid: 2, title: '风，带有香气[第123集][中文字幕].Kaze.Kaoru.S01.1080p.LINETV.WEB-DL.AAC2.0.H.264-BlackTV 0.34GB' },
];
/* 每个帖子一个种子附件：「开始下载」→ 取件 → 本机打包这条链路能走通 */
for (let t = 40000; t < tid; t++) W.forum.threads[t] = { attach: [{ aid: 'A' + t, name: 't' + t + '.torrent', bytes: H.torrent({ name: 'f' + t + '.mkv', length: 9, 'piece length': 16384, pieces: Buffer.alloc(20) }).bytes }] };
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
  const libp = await p.evaluate(() => { const d = document.querySelector('details[data-x="lib"]'); return d ? d.textContent : ''; });
  ok(/实时清单/.test(libp) && /重新同步片库/.test(libp), '片库对照面板：以 Stream v25 的实时清单为准（来源、清单时间、同步按钮）');
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

/* [v6.6] 导入清单：贴一张表 → 库里没有的进片单，库里有的跳过；什么都不会自己开始下载 */
for (const [label, opt] of [['导入清单 · 手机', { ...devices['iPhone 14'] }], ['导入清单 · 桌面', { viewport: { width: 1280, height: 860 } }]]) {
  console.log('\n■ ' + label);
  const { p, ctx, errs } = await page(opt);
  await p.click('#nav button[data-v="dl"]');
  await settle(p);
  await p.click('#impopen2');
  await p.waitForSelector('#imptx');
  /* 几种格式都认 */
  const parsed = await p.evaluate(() => ({
    json: impParse('[{"tmdb_id":1,"title":"a"}]').items.length,
    wrap: impParse('{"items":[{"title":"a"},{"title":"b"}]}').items.length,
    jsonl: impParse('{"title":"a"}\n{"title":"b"}\n{"title":"c"}').items.length,
    csv: impParse('tmdb_id,title,year\n911430,"F1：狂飙飞车",2025\n,沙丘2,2024').items,
    line: impParse('tmbd_id(1):911430/title:F1：狂飙飞车/year:2025\ntmdb_id(2):693134/title:沙丘2/res:2160p').items,
    plain: impParse('奥本海默 2023\n2. 芭比\n94997').items,
  }));
  ok(parsed.json === 1 && parsed.wrap === 2 && parsed.jsonl === 3, '认得 JSON 数组、{"items":[…]}、每行一个 JSON 对象');
  ok(parsed.csv.length === 2 && parsed.csv[0].title === 'F1：狂飙飞车' && parsed.csv[0].tmdb_id === '911430' && parsed.csv[1].title === '沙丘2' && !parsed.csv[1].tmdb_id, 'CSV（带表头、引号里的全角冒号不乱切）');
  ok(parsed.line.length === 2 && parsed.line[0]['tmdb_id'] === '911430' && parsed.line[0].title === 'F1：狂飙飞车' && parsed.line[0].year === '2025' && parsed.line[1].res === '2160p',
    '「tmbd_id(1):xxxx/title:xxx/year:…」一行一条（拼错的 tmbd、带序号的键、片名里的全角冒号都没问题）');
  ok(parsed.plain[0].title === '奥本海默' && parsed.plain[0].year === '2023' && parsed.plain[1].title === '芭比' && parsed.plain[2].tmdb_id === '94997', '每行一个片名（末尾年份拆出来、去掉「2.」序号）或一个 TMDB 编号');
  const list = [
    { tmdb_id: 700001, title: '奥本海默' },
    { title: '芭比', year: 2024 },
    { title: '满江红', year: 2024, res: '1080p', note: '周末看' },
    { title: '孤注一掷', year: 2025 },
    { tmdb_id: 700001 },
    { title: '根本没有这部片', year: 2025 },
    { tmdb_id: 94997, type: 'tv', title: '某部剧' },
    { year: 2024 },
  ];
  await p.fill('#imptx', JSON.stringify(list, null, 2));
  await p.click('#impgo');
  await p.waitForFunction(() => !IMP.busy && IMP.rows && IMP.rows.length, null, { timeout: 15000 });
  await settle(p);
  const r = await p.evaluate(() => ({
    st: IMP.rows.map(x => x && x.st),
    cart: CART.ord.slice(), pick: CART.o[700004] && CART.o[700004].pickLabel, res: CART.o[700004] && CART.o[700004].res,
    job: !!document.getElementById('dlprog'), start: (document.getElementById('dstart') || {}).textContent || '',
    pills: [].map.call(document.querySelectorAll('.imp-sum .pill'), e => e.textContent.replace(/\s+/g, ' ')).join(' / '),
    tvRow: (document.querySelectorAll('.irow')[6] || {}).textContent || '',
    over: document.documentElement.scrollWidth - innerWidth,
    cnt: document.getElementById('ncart').textContent,
  }));
  ok(r.st.join(' ') === 'add owned add add dup notfound notfound invalid', '每条的结果：' + r.st.join(' '));
  ok(r.cart.length === 3 && r.cart.includes(700001) && r.cart.includes(700004) && r.cart.includes(700007) && r.cnt === '3', '库里没有的 3 部进了片单（坞上的数字 ' + r.cnt + '），库里已有的「芭比」没进');
  ok(r.res === '1080p' && /1080p/.test(r.pick || ''), '写了 res: 1080p 的那条挑的是 1080p 版（片单里标「已指定：' + r.pick + '」）');
  ok(!r.job && /开始下载 3 部/.test(r.start), '只是放进片单：没有开始任何下载，等人点「' + r.start + '」');
  ok(/加入片单 3/.test(r.pills) && /库中已有 1/.test(r.pills) && /论坛暂无 2/.test(r.pills), '结果汇总：' + r.pills);
  ok(/剧集/.test(r.tvRow), '剧集那条走剧集源去查、标着「剧集」');
  ok(r.over <= 0, '结果列表不撑出横向滚动（多出 ' + r.over + 'px）');
  await p.click('#impundo');
  await settle(p);
  const u = await p.evaluate(() => ({ n: CART.ord.length, st: IMP.rows.filter(x => x && x.st === 'undone').length }));
  ok(u.n === 0 && u.st === 3, '「撤回这次加入的」：3 部从片单里拿掉');
  await p.click('.irow[data-st="owned"] [data-icand]');
  await settle(p);
  const fo = await p.evaluate(() => ({ cart: CART.ord.slice(), st: IMP.rows[1] && IMP.rows[1].st, why: IMP.rows[1] && IMP.rows[1].it.reason }));
  ok(fo.cart.length === 1 && fo.cart[0] === 700002 && fo.st === 'add' && /库里已有/.test(fo.why || ''), '库中已有的那条点「仍然加入」：照样加进片单，并提醒「' + fo.why + '」');
  if (!label.includes('手机')) {
    /* [v6.8] 打包：解压出来一个根文件夹，里面每 20 部一个子文件夹 */
    await p.evaluate(() => { IMP.rows = null; CART = { ord: [], o: {} }; cartSave(); paintDock(); });
    await p.click('#nav button[data-v="lib"]'); await settle(p);
    for (const k of [0, 1, 2]) { await p.locator('.grid .art').nth(k).click(); await p.waitForTimeout(150); }
    await p.click('#nav button[data-v="dl"]'); await settle(p);
    const dlp = p.waitForEvent('download', { timeout: 30000 });
    await p.click('#dstart');
    const dl = await dlp;
    const zp = '/tmp/idx-test/ui-pack.zip';
    await dl.saveAs(zp);
    const { execFileSync } = await import('node:child_process');
    const pz = JSON.parse(execFileSync('python3', ['-c', `
import zipfile,json
z=zipfile.ZipFile('${zp}')
print(json.dumps({'bad':z.testzip(),'names':z.namelist()}, ensure_ascii=False))`]).toString());
    const root = (pz.names[0] || '').replace(/\/$/, '');
    const tor = pz.names.filter(n => n.endsWith('.torrent'));
    ok(pz.bad === null && /^Cuven索引库-\d{8}$/.test(root) && pz.names.every(n => n.startsWith(root + '/')) && pz.names.includes(root + '/001-003/') && pz.names.includes(root + '/_清单.txt') && tor.length === 3 && tor.every(n => n.startsWith(root + '/001-003/')),
      '点「开始下载」：取件、本机打包，下载的包解开是一个根文件夹「' + root + '」，3 部种子在「001-003」子文件夹里，清单在根文件夹');
    await p.evaluate(() => DL.clear());
    /* 剧集：索引里没有 → 自动去论坛搜索页搜；论坛限频时倒计时等；只要全集，单集的标「未完结」可手动加 */
    await p.evaluate(() => { IMP.rows = null; IMP.added = []; IMP.sq = []; CART = { ord: [], o: {} }; cartSave(); try { localStorage.removeItem('cvcart:tv'); } catch (e) {} renderDL(); });
    W.forum.searchGap = 2; W.forum.lastSearch = 0; W.forum.searchLog = [];
    await p.fill('#imptx', 'tmdb_id(1):520001/title:夫妻的博弈/type:tv\ntmdb_id(2):520002/title:风，带有香气/type:tv');
    await p.click('#impgo');
    await p.waitForFunction(() => IMP.phase === 'search', null, { timeout: 15000 });
    let sawWait = '';
    for (let i = 0; i < 80; i++) {
      const t = await p.evaluate(() => ({ busy: IMP.busy, prog: (document.getElementById('impprog') || {}).textContent || '' }));
      if (/秒后搜下一条/.test(t.prog)) sawWait = t.prog;
      if (!t.busy) break;
      await p.waitForTimeout(250);
    }
    await settle(p);
    const tvr = await p.evaluate(() => {
      let tvc = null; try { tvc = JSON.parse(localStorage.getItem('cvcart:tv') || 'null'); } catch (e) {}
      return { st: IMP.rows.map(x => x && x.st), tv: tvc, irec: !!document.querySelector('[data-irec]'), blocked: 0 };
    });
    const blocked = W.forum.searchLog.filter(x => x.blocked).length;
    ok(tvr.st.join(' ') === 'add incomplete', '剧集两条：索引里没有，自动去论坛搜 —— 有全集的加入、只有单集的标「未完结」（' + tvr.st.join(' ') + '）');
    const rec = tvr.tv && tvr.tv.o && tvr.tv.o[520001];
    ok(rec && rec.ext === 1 && rec.res === '2160p' && /全25集/.test(rec.pickLabel || ''), '加进剧集片单的是全 25 集的 2160p，版本锁定（「已指定：' + (rec && rec.pickLabel) + '」）');
    ok(/秒后搜下一条/.test(sawWait) && W.forum.searchLog.filter(x => !x.blocked).length >= 2, '论坛限频（2 秒一次）：进度里倒计时「' + sawWait.replace(/停止搜索|正在停…/, '').slice(0, 40) + '…」，等够了接着搜（被挡 ' + blocked + ' 次）');
    await p.click('[data-irec]');
    await settle(p);
    const after = await p.evaluate(() => { let c = null; try { c = JSON.parse(localStorage.getItem('cvcart:tv') || 'null'); } catch (e) {} return { st: IMP.rows[1].st, n: c ? c.ord.length : 0 }; });
    ok(after.st === 'add' && after.n === 2, '「未完结」那条点「仍然加入最新的」：照样加进片单（剧集片单 ' + after.n + ' 部）');
    await p.click('#srcNav button[data-s="tv"]');
    await settle(p);
    await p.click('#nav button[data-v="dl"]');
    await settle(p);
    const ext = await p.evaluate(() => { const it = document.querySelector('.citem[data-id="520001"]'); return it ? { open: !!it.querySelector('[data-open]'), txt: it.textContent } : null; });
    ok(ext && !ext.open && /论坛搜索/.test(ext.txt), '片单里论坛搜来的那部：标着「论坛搜索」，没有「换版本」（索引里没有它的详情页）');
  }
  ok(!errs.length, '页面零报错' + (errs.length ? '：' + errs.slice(0, 3).join(' | ') : ''));
  await ctx.close();
}
await b.close();
srv.close();
console.log(`\n${fail ? '✗' : '✓'} ${pass} 通过，${fail} 失败`);
process.exit(fail ? 1 : 0);
