// [910] 批量传输 / 核对 / 删除、剧集区 sub、改名挪进剧集区、exists { tv }、作业 detail、并发上限（模拟 rclone rc）
// 模拟的 rclone 认 _filter 的 IncludeRule（带反斜杠转义的 glob）和 IgnoreCase，和真的 rclone 一个口径：
// 名字里的 [ ] 不转义就成了字符类，这一项什么都匹配不到
// 作业号和统计组也照真的 rclone（1.62 起）来：每个 rc 调用都占一个作业号（同步的也算，回在 X-Rclone-Jobid 里），
// job/list 只回 jobids（24 小时的全在里面，没有 runningIds）；统计组按建的先后排（core/group-list），
// 列目录会建一个 job/<作业号> 的组（rclone 1.68 起的 listed 统计），core/stats 问一个不存在的组会顺手把它建出来
import { pathToFileURL, fileURLToPath } from 'node:url';
import path from 'node:path';
const worker = (await import(pathToFileURL(path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'worker.js')).href)).default;

let pass = 0, fail = 0;
const ok = (c, n, x) => { if (c) pass++; else { fail++; console.log('✗', n, x !== undefined ? JSON.stringify(x) : ''); } };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/* ── 模拟的 rclone：每个 remote 一张「路径 → 大小」表，路径相对 remote 的根 ── */
let FS = {}, DIRS = {}, JOBS = {}, STATS = {}, PLAN = {}, DOWN = {}, DENY = new Set();
let NOFILTER = false, RUNNING_IDS = false, nextJob = 100, COPIED = null;
let GROUPS = [], LIST_GROUPS = true, MOVES = false, AFTER = {}, VCLOCK = null;
/* [911] FLAP：这几个作业号的 job/status 一直回 520（边缘抖）；RCFAIL：接口 → rclone 自己回的错 [HTTP 状态, 消息]（后端出事） */
let FLAP = new Set(), RCFAIL = {};
const calls = [];
let inflight = 0, peak = 0;
const reset = () => { calls.length = 0; peak = 0; PLAN = {}; DOWN = {}; AFTER = {}; NOFILTER = false; COPIED = null; FLAP = new Set(); RCFAIL = {}; };
const addGroup = g => { if (g && !GROUPS.includes(g)) GROUPS.push(g); };
const LONG = new Set(['sync/copy', 'sync/move', 'operations/copyfile']);       // 这几个异步作业要跑一阵；别的 _async 马上跑完
/* 虚拟时钟：VCLOCK = { cost: { 接口: 毫秒 }, v }。一次调用从「上一次有调用结束的时刻」开始，花 cost 毫秒；
   真等 cost/1000 毫秒，结束的先后和虚拟时间一致，同时发的几个调用重叠 */
const wallNow = Date.now;
Date.now = () => wallNow() + (VCLOCK ? VCLOCK.v : 0);
const put = (remote, p, size) => { (FS[remote] = FS[remote] || new Map()).set(p, size); };
const remoteOf = fs => { const i = fs.indexOf(':'); return { remote: fs.slice(0, i).split(',')[0], root: fs.slice(i + 1).replace(/^\/+|\/+$/g, '') }; };
const join = (a, b) => [a, b].filter(Boolean).join('/');
const filesUnder = (remote, root) => {
  const out = [];
  (FS[remote] || new Map()).forEach((size, p) => { if (!root || p.startsWith(root + '/')) out.push([root ? p.slice(root.length + 1) : p, size]); });
  return out;
};
const dirExists = (remote, root) => !root || filesUnder(remote, root).length > 0 || (DIRS[remote] || new Set()).has(root);

/* rclone 的 glob：\ 转义下一个字符，** 跨层，* ? 不跨层，[..] 字符类，{a,b} 任选；开头的 / 锚在根上 */
function globRe(rule, ic) {
  let s = rule, anch = false;
  if (s.startsWith('/')) { anch = true; s = s.slice(1); }
  const lit = ch => ch.replace(/[.*+?^${}()|[\]\\\/]/g, '\\$&');
  let re = '', i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (ch === '\\') { re += lit(s[i + 1] || ''); i += 2; }
    else if (ch === '*') { if (s[i + 1] === '*') { re += '.*'; i += 2; } else { re += '[^/]*'; i++; } }
    else if (ch === '?') { re += '[^/]'; i++; }
    else if (ch === '[') {
      let j = i + 1, cls = '';
      while (j < s.length && s[j] !== ']') { if (s[j] === '\\') { cls += '\\' + s[j + 1]; j += 2; } else { cls += s[j] === '^' ? '\\^' : s[j]; j++; } }
      re += '[' + cls + ']'; i = j + 1;
    } else if (ch === '{' && s.indexOf('}', i) > i) {
      const j = s.indexOf('}', i);
      re += '(?:' + s.slice(i + 1, j).split(',').map(lit).join('|') + ')'; i = j + 1;
    } else { re += lit(ch); i++; }
  }
  try { return new RegExp((anch ? '^' : '(?:^|/)') + re + '$', ic ? 'i' : ''); }
  catch (e) { return /(?!)/; }                                     // 规则本身不成立：什么都不匹配
}
const keep = (filter) => {
  if (NOFILTER || !filter || !Array.isArray(filter.IncludeRule) || !filter.IncludeRule.length) return () => true;
  const rs = filter.IncludeRule.map(r => globRe(r, !!filter.IgnoreCase));
  return rel => rs.some(r => r.test(rel));
};

const okj = (o) => new Response(JSON.stringify(o), { status: 200 });
const rcErr = (msg, st = 500) => new Response(JSON.stringify({ error: msg, status: st }), { status: st });
const sleep = ms => new Promise(r => setTimeout(r, ms));
globalThis.fetch = async (url, init) => {
  const u = new URL(url), p = u.pathname.slice(1), b = JSON.parse(init.body || '{}');
  calls.push([p, b]);
  inflight++; peak = Math.max(peak, inflight);
  const v0 = VCLOCK ? VCLOCK.v : 0, cost = VCLOCK ? VCLOCK.cost[p] || 0 : 0;
  try {
    await sleep(4 + Math.round(cost / 1000));
    if (VCLOCK) VCLOCK.v = Math.max(VCLOCK.v, v0 + cost);
    const q = PLAN[p];
    if (q && q.length) {
      const st = q.shift();
      if (st === 'throw') throw new TypeError('Network connection lost');
      if (st !== 'ok') return new Response('<html>' + st + ' cloudflare</html>', { status: st });
    }
    if (b.fs && DOWN[b.fs]) return new Response('<html>' + DOWN[b.fs] + ' cloudflare</html>', { status: DOWN[b.fs] });
    if (p === 'job/status' && FLAP.has(b.jobid)) return new Response('<html>520 cloudflare</html>', { status: 520 });
    /* 请求到了 rclone：占一个作业号。同步调用当场跑完；异步的回 { jobid } */
    const id = nextJob++;
    JOBS[id] = { finished: !(b._async && LONG.has(p)), success: !(b._async && LONG.has(p)), group: b._async ? b._group || 'job/' + id : 'job/' + id };
    if (b._async) addGroup(JOBS[id].group);
    const res = RCFAIL[p] ? rcErr(RCFAIL[p][1], RCFAIL[p][0]) : await rc(p, b, id);
    const lost = AFTER[p] && AFTER[p].length ? AFTER[p].shift() : 0;             // 做完了，回包丢了
    if (lost) return new Response('<html>' + lost + ' cloudflare</html>', { status: lost });
    res.headers.set('x-rclone-jobid', String(id));
    return res;
  } finally { inflight--; }
};
async function rc(p, b, id) {
    if (b._async && !LONG.has(p)) return okj({ jobid: id, executeId: 'x' });
    switch (p) {
      case 'core/version': return okj({ version: 'v1.71.0' });
      case 'operations/list': {
        const { remote, root } = remoteOf(b.fs), at = join(root, b.remote);
        if (!dirExists(remote, at)) return rcErr('directory not found', 404);
        if (LIST_GROUPS) addGroup('job/' + id);
        if (b.opt && b.opt.recurse) {
          const k = keep(b._filter);
          return okj({ list: filesUnder(remote, at).filter(([rel]) => k(rel)).map(([rel, size]) => ({ Path: rel, Name: rel.split('/').pop(), Size: size, IsDir: false })) });
        }
        const seen = new Map();
        filesUnder(remote, at).forEach(([rel, size]) => { const h = rel.split('/')[0]; if (!seen.has(h)) seen.set(h, rel.includes('/') ? { Path: h, Name: h, IsDir: true, Size: -1 } : { Path: h, Name: h, IsDir: false, Size: size }); });
        (DIRS[remote] || new Set()).forEach(d => { if (d.startsWith(at + '/') && !d.slice(at.length + 1).includes('/')) { const h = d.slice(at.length + 1); if (!seen.has(h)) seen.set(h, { Path: h, Name: h, IsDir: true, Size: -1 }); } });
        return okj({ list: Array.from(seen.values()) });
      }
      case 'operations/stat': {
        const { remote, root } = remoteOf(b.fs), at = join(root, b.remote);
        const m = FS[remote] || new Map();
        if (m.has(at)) return okj({ item: { Path: b.remote, Name: b.remote, Size: m.get(at), IsDir: false } });
        if (b.remote && dirExists(remote, at)) return okj({ item: { Path: b.remote, Name: b.remote, Size: -1, IsDir: true } });
        return okj({ item: null });
      }
      case 'operations/mkdir': { const { remote, root } = remoteOf(b.fs); (DIRS[remote] = DIRS[remote] || new Set()).add(join(root, b.remote)); return okj({}); }
      case 'operations/purge': case 'operations/deletefile': {
        const { remote, root } = remoteOf(b.fs), at = join(root, b.remote);
        if (DENY.has(at)) return rcErr('permission denied', 403);
        const m = FS[remote] || new Map();
        if (p === 'operations/deletefile') { if (!m.has(at)) return rcErr('object not found', 404); m.delete(at); return okj({}); }
        if (!dirExists(remote, at)) return rcErr('directory not found', 404);
        Array.from(m.keys()).forEach(k => { if (k.startsWith(at + '/')) m.delete(k); });
        return okj({});
      }
      case 'sync/copy': case 'sync/move': case 'operations/copyfile': {
        if (p === 'sync/copy') {
          const { remote, root } = remoteOf(b.srcFs), k = keep(b._filter);
          COPIED = filesUnder(remote, root).map(([rel]) => rel).filter(k);
        }
        if (p === 'sync/move' && MOVES) {                                 // PikPak 的 DirMove：一下就挪完
          const s1 = remoteOf(b.srcFs), d1 = remoteOf(b.dstFs), m = FS[s1.remote] || new Map();
          /* [911] 真 rclone：_async 的调用当场回作业号，活在作业里干 —— 来源不在了是这个作业失败（directory not found），
             不是同步回 404（以前的模拟同步回 404，测出来的 422 是模拟自己的） */
          if (!dirExists(s1.remote, s1.root)) {
            if (!b._async) return rcErr('directory not found', 404);
            Object.assign(JOBS[id], { finished: true, success: false, error: 'directory not found' });
            return okj({ jobid: id, executeId: 'x' });
          }
          Array.from(m.keys()).forEach(k => { if (k.startsWith(s1.root + '/')) { m.set(d1.root + k.slice(s1.root.length), m.get(k)); m.delete(k); } });
          JOBS[id].finished = true; JOBS[id].success = true;
        }
        return okj({ jobid: id, executeId: 'x' });
      }
      case 'job/list': {
        const ids = Object.keys(JOBS).map(Number);
        return okj(RUNNING_IDS ? { jobids: ids, runningIds: ids.filter(i => !JOBS[i].finished), finishedIds: ids.filter(i => JOBS[i].finished) } : { executeId: 'x', jobids: ids });
      }
      case 'job/status': {
        const j = JOBS[b.jobid];
        if (!j) return rcErr('job not found');
        return okj({ id: b.jobid, finished: j.finished, success: j.success, error: j.error || '', group: j.group || ('job/' + b.jobid) });
      }
      case 'job/stop': {
        const j = JOBS[b.jobid];
        if (!j) return rcErr('job not found');
        if (!j.finished) Object.assign(j, { finished: true, success: false, error: 'context canceled' });
        return okj({});
      }
      case 'job/stopgroup':
        Object.values(JOBS).forEach(j => { if (j.group === b.group && !j.finished) Object.assign(j, { finished: true, success: false, error: 'context canceled' }); });
        return okj({});
      case 'core/group-list': return okj({ groups: GROUPS.slice() });
      case 'core/stats': addGroup(b.group); return okj(STATS[b.group] || { bytes: 0, totalBytes: 0, speed: 0 });
    }
    return rcErr('unknown', 404);
}

let env = { LINK_KEY: 'k', VPS_PASS: 'pw' };
const call = async (p, b, e = env) => {
  const r = await worker.fetch(new Request('https://transfer.cuven.us/api/link/' + p, { method: 'POST', headers: { 'x-cuven-link': 'k' }, body: JSON.stringify(b || {}) }), e);
  return [r.status, await r.json()];
};
const n = (p) => calls.filter(c => c[0] === p).length;
const find = (p, f = () => true) => calls.find(c => c[0] === p && f(c[1]));

/* ── 世界：电影直接在 auto，剧集在 auto/ram2 ── */
const MOVIE = 'Dune.Part.Two.2024.2160p.[auto-mv693134-r9].mkv';
const ODD = 'Odd *Name? {x}.mkv';                                       // 名字里有 * ? { }
const TV1 = 'Worst.Ex.Ever.S02.2160p.[Full-4][CN-HK-EN]-Cuven®.[auto-tv1-r2]';
const TV2 = 'Show.S01.[auto-tv2-r3]';
function world() {
  FS = {}; DIRS = {}; JOBS = {}; STATS = {}; GROUPS = [];
  for (const r of ['webdav', 'pikpak']) {
    put(r, 'auto/' + MOVIE, 1000); put(r, 'auto/' + ODD, 7);
    put(r, 'auto/ram2/' + TV1 + '/E01.mkv', 100); put(r, 'auto/ram2/' + TV1 + '/E02.mkv', 200);
    put(r, 'auto/ram2/' + TV1 + '/Subs/Café.srt', 5); put(r, 'auto/ram2/' + TV1 + '/desktop.ini', 1);
    put(r, 'auto/ram2/' + TV2 + '/S01E01.mkv', 50);
    // 别人的片、没下完的、剧集区里的别的剧：一个都不该被这一批碰到
    put(r, 'auto/Someone.Else.2023.mkv', 999); put(r, 'auto/Half.mkv.part', 3); put(r, 'auto/ram2/Other.Show.S01/E01.mkv', 77);
    put(r, 'auto/' + TV1 + '/E01.mkv', 1);                              // 同名的老位置（auto 下面一层）
  }
}
world();

/* ping：caps + 剧集区名字 */
reset();
let [s, j] = await call('ping');
ok(s === 200 && same(j.caps, ['sub', 'batch']) && j.tv === 'ram2' && /911/.test(j.core), 'ping 回 caps 和剧集区', j);

/* ══ batch-copy ══ */
const BATCH = [
  { item: MOVIE, kind: 'file' }, { item: ODD, kind: 'file' },
  { item: TV1, kind: 'dir', sub: 'ram2' }, { item: TV2.toLowerCase(), kind: 'dir', sub: 'ram2' },   // 大小写不同也认（IgnoreCase）
];
reset();
[s, j] = await call('batch-copy', { key: 'b7-1', items: BATCH });
const sc = find('sync/copy');
ok(s === 200 && j.jobid > 0 && !j.reused && n('sync/copy') === 1, '批量传输：开出一个作业', { s, j });
ok(sc && sc[1].srcFs === 'webdav:auto' && sc[1].dstFs === 'dropbox,chunk_size=16Mi,batch_mode=sync:auto' && sc[1]._async === true,
   'srcFs webdav:auto → dstFs 带 chunk_size=16Mi、batch_mode=sync 的 Dropbox 连接串', sc && sc[1]);
ok(sc && same(sc[1]._config, { Transfers: 16, Checkers: 16, BufferSize: '8Mi', CheckFirst: true }), '_config：16 并发 / 16 检查 / 8Mi 缓冲 / 先检查后传', sc && sc[1]._config);
ok(sc && sc[1]._group === 'tjb/b7-1' && j.group === 'tjb/b7-1', '统计组 tjb/<key>（幂等用）', sc && sc[1]._group);
const RULES = ['/' + MOVIE.replace(/\[/g, '\\[').replace(/\]/g, '\\]'), '/Odd \\*Name\\? \\{x\\}.mkv',
  '/ram2/Worst.Ex.Ever.S02.2160p.\\[Full-4\\]\\[CN-HK-EN\\]-Cuven®.\\[auto-tv1-r2\\]/**', '/ram2/show.s01.\\[auto-tv2-r3\\]/**'];
ok(sc && same(sc[1]._filter, { IncludeRule: RULES, IgnoreCase: true }), '过滤规则：一项一条，* ? [ ] { } 全转义，IgnoreCase', sc && sc[1]._filter);
const WANT = [MOVIE, ODD, 'ram2/' + TV1 + '/E01.mkv', 'ram2/' + TV1 + '/E02.mkv', 'ram2/' + TV1 + '/Subs/Café.srt', 'ram2/' + TV1 + '/desktop.ini', 'ram2/' + TV2 + '/S01E01.mkv'];
ok(COPIED && same(COPIED.slice().sort(), WANT.slice().sort()), '按这套规则 rclone 只搬这一批（别人的片、.part、别的剧、老位置的同名文件夹都不碰）', COPIED);
ok(!globRe('/ram2/' + TV1 + '/**', true).test('ram2/' + TV1 + '/E01.mkv'), '（对照）不转义的话 [Full-4] 成了字符类，一个文件都匹配不到');
ok(j.items[MOVIE].count === 1 && j.items[MOVIE].bytes === 1000 && j.items['ram2/' + TV1].count === 3 && j.items['ram2/' + TV1].bytes === 305
   && j.items['ram2/' + TV2.toLowerCase()].count === 1 && j.total === 1000 + 7 + 305 + 50 && j.files === 6,
   '预检给每项的文件数 / 字节数（desktop.ini 不算），key 是 sub/item', j.items);
const lsc = find('operations/list');
ok(lsc && lsc[1].fs === 'webdav:auto' && lsc[1].opt.recurse && same(lsc[1]._filter, sc[1]._filter) && calls.indexOf(lsc) < calls.indexOf(sc), '预检：先用同一套过滤列一次来源', lsc);
ok(find('operations/mkdir', b => b.fs === 'dropbox:' && b.remote === 'auto') && find('operations/mkdir', b => b.fs === 'dropbox:' && b.remote === 'auto/ram2'), '建 dropbox:auto 和 dropbox:auto/ram2');
ok(n('job/list') === 1 && n('core/group-list') === 1 && calls.findIndex(c => c[0] === 'core/group-list') < calls.indexOf(sc), '开之前 group-list / job/list 看一眼');
ok(!find('core/stats', b => b.group === 'tjb/b7-1') && GROUPS.indexOf('tjb/b7-1') === GROUPS.length - 1, '没开过的 key 不去问它的统计（问了 rclone 会把组建出来）');
ok(peak <= 4, '同时最多 4 个连接', peak);
const first = j.jobid;

/* 同一个 key 再来一次（调用方超时了）：作业还在跑 → 接上，不开第二个 */
reset();
[s, j] = await call('batch-copy', { key: 'b7-1', items: BATCH });
ok(s === 200 && j.jobid === first && j.reused === true && n('sync/copy') === 0 && j.items['ram2/' + TV1].count === 3, '同一个 key 还在跑：reused，不开第二个', { s, j });

/* 新版 rclone：job/list 直接给 runningIds */
RUNNING_IDS = true; reset();
[s, j] = await call('batch-copy', { key: 'b7-1', items: BATCH });
ok(s === 200 && j.reused && j.jobid === first && n('job/status') === 1, 'runningIds：只问还在跑的', { j, st: n('job/status') });
RUNNING_IDS = false;

/* 跑完了再来：不算重复，照常开新的；统计组换一个（审查后 ③：同名的组 rclone 会接着累加） */
JOBS[first].finished = true; JOBS[first].success = true; reset();
[s, j] = await call('batch-copy', { key: 'b7-1', items: BATCH });
ok(s === 200 && !j.reused && j.jobid !== first && n('sync/copy') === 1 && j.group === 'tjb/b7-1/2' && find('sync/copy')[1]._group === 'tjb/b7-1/2',
   '同组作业已经跑完：开新的，统计组 tjb/b7-1/2', j);

/* 从没开过的 key：group-list 里没有它的组，一个作业都不用问（jobids 里 24 小时的都在，以前问最新的 8 个） */
for (let i = 0; i < 20; i++) JOBS[nextJob++] = { finished: true, success: true, group: 'job/x' };
reset();
[s, j] = await call('batch-copy', { key: 'zz', items: BATCH.slice(0, 1) });
ok(s === 200 && n('job/status') === 0 && !find('core/stats') && n('core/group-list') === 1 && n('sync/copy') === 1 && find('sync/copy')[1]._group === 'tjb/zz',
   '没开过的 key：不问 job/status、不问统计，直接开 tjb/zz', { st: n('job/status') });

/* job/list 问不出来：宁可这一轮不开，也不冒开第二个的险 */
reset(); PLAN = { 'job/list': ['throw', 'throw', 'throw'] };
[s, j] = await call('batch-copy', { key: 'b7-2', items: BATCH });
ok(s === 502 && n('sync/copy') === 0, 'job/list 失败：502，不开', { s, j });

/* rclone 不认 _filter：探针列回来一整个 auto → 409 nofilter，不开 */
reset(); NOFILTER = true;
[s, j] = await call('batch-copy', { key: 'b7-3', items: BATCH });
ok(s === 409 && j.nofilter === 1 && j.stray > 0 && n('sync/copy') === 0, '过滤没生效：409 nofilter，不开作业', { s, j });

/* 补传那一套：从原生 pikpak 后端、只按大小；并发 / 检查数夹在 1–16 */
reset();
[s, j] = await call('batch-copy', { key: 'b7-4', items: BATCH, from: 'pikpak', sizeOnly: 1, transfers: 99, checkers: '4' });
let sc2 = find('sync/copy');
ok(s === 200 && j.from === 'pikpak' && sc2[1].srcFs === 'pikpak:auto' && find('operations/list')[1].fs === 'pikpak:auto'
   && same(sc2[1]._config, { Transfers: 16, Checkers: 4, BufferSize: '8Mi', CheckFirst: true, SizeOnly: true }), 'from pikpak + sizeOnly；transfers 99 → 16，checkers 4', sc2 && sc2[1]);
reset();
[s, j] = await call('batch-copy', { items: [{ item: MOVIE }], transfers: 0, checkers: 'x' });
sc2 = find('sync/copy');
ok(s === 200 && sc2[1]._config.Transfers === 1 && sc2[1]._config.Checkers === 16 && !('_group' in sc2[1]) && n('job/list') === 0 && j.group === 'job/' + j.jobid,
   '没给 key：不带 _group、不查 job/list；transfers 0 → 1，checkers 不是数 → 16', { j, cfg: sc2 && sc2[1] });
ok(n('operations/mkdir') === 1 && !find('operations/mkdir', b => b.remote === 'auto/ram2'), '这批没有剧集：不建剧集区');

/* 开传输遇到 520（请求可能已经到了 rclone）：不重试 */
reset(); PLAN = { 'sync/copy': [520] };
[s, j] = await call('batch-copy', { key: 'b7-5', items: BATCH });
ok(s === 502 && n('sync/copy') === 1, '开批量传输遇到 520：不重试，免得开两个', { s, j });

/* 探针列失败：没有同组作业 → 502 side src；有同组作业在跑 → 照样接上（没有分母） */
reset(); DOWN = { 'webdav:auto': 523 };
[s, j] = await call('batch-copy', { key: 'b7-6', items: BATCH });
ok(s === 502 && j.side === 'src' && n('sync/copy') === 0, '预检列不出：502，不开', { s, j });
JOBS[777] = { finished: false, group: 'tjb/b7-6' }; addGroup('tjb/b7-6');
STATS['tjb/b7-6'] = { bytes: 9, totalBytes: 99, transferring: [{ name: MOVIE, bytes: 9, size: 1000 }] };
reset(); DOWN = { 'webdav:auto': 523 };
[s, j] = await call('batch-copy', { key: 'b7-6', items: BATCH });
ok(s === 200 && j.reused && j.jobid === 777 && !j.items, '预检列不出但同组作业在跑：接上', { s, j });

/* 预检列了很久（超过 45 秒）：调用方多半已经超时、下一轮会再来 —— 这一轮不开，回 503 */
const realNow = Date.now;
let SLOW = 0;
Date.now = () => realNow() + SLOW;
reset();
const slowList = globalThis.fetch;
globalThis.fetch = async (url, init) => { const r = await slowList(url, init); if (new URL(url).pathname === '/operations/list') SLOW += 46000; return r; };
[s, j] = await call('batch-copy', { key: 'b7-7', items: BATCH });
globalThis.fetch = slowList; Date.now = realNow;
ok(s === 503 && j.retry === 1 && n('sync/copy') === 0, '预检列了 46 秒：503，不开（免得和下一轮各开一个）', { s, j });

/* 参数不对 */
reset();
const many = Array.from({ length: 17 }, (_, i) => ({ item: 'M' + i + '.mkv' }));
[s, j] = await call('batch-copy', { items: many });
ok(s === 400 && n('sync/copy') === 0, '超过 16 项：400', j);
[s, j] = await call('batch-copy', { items: [] });
ok(s === 400, '空的：400', j);
[s, j] = await call('batch-copy', { items: [{ item: MOVIE }, { item: 'RAM2', kind: 'dir' }] });
ok(s === 400 && j.index === 1, '电影区里的 ram2（剧集区本身）：400，指出第几项', j);
[s, j] = await call('batch-copy', { items: [{ item: TV1, kind: 'dir', sub: 'ram3' }] });
ok(s === 400, 'sub 不是剧集区：400', j);
[s, j] = await call('batch-copy', { items: [{ item: '../x' }] });
ok(s === 400, '名字里有 ..：400', j);
[s, j] = await call('batch-copy', { key: 'a/b', items: [{ item: MOVIE }] });
ok(s === 400 && n('sync/copy') === 0 && n('operations/list') === 0, 'key 不对：400', j);
[s, j] = await call('batch-copy', { key: 'dup', items: [{ item: MOVIE }, { item: MOVIE.toUpperCase() }] });
ok(s === 200 && find('sync/copy')[1]._filter.IncludeRule.length === 1, '同一项给两次（大小写不同）：去重', find('sync/copy'));

/* ══ batch-copy 幂等（审查后 ①③④）：真 rclone 每个调用都占作业号，job/list 只有 jobids ══ */
/* 两轮之间请求添加照常干活：ping、问几个作业（每个一次 job/status）…… n 次请求，回 rclone 一共收到几个调用 */
const between = async (n) => {
  const before = nextJob;
  for (let i = 0; i < n; i++) await (i % 3 ? call('ping') : call('jobs', { ids: [1, 2, 3] }));
  return nextJob - before;
};
const runningIn = k => Object.keys(JOBS).filter(id => !JOBS[id].finished && (JOBS[id].group === 'tjb/' + k || String(JOBS[id].group).startsWith('tjb/' + k + '/'))).map(Number);
reset();
[s, j] = await call('batch-copy', { key: 'r7', items: BATCH });
const r7 = j.jobid;
const gap = await between(12);
await call('exists', { items: ['A.mkv'] });                          // 中间有人列了一次目录
reset();
[s, j] = await call('batch-copy', { key: 'r7', items: BATCH });
ok(gap >= 7 && s === 200 && j.reused === true && j.jobid === r7 && j.group === 'tjb/r7' && n('sync/copy') === 0 && n('job/stopgroup') === 0 && same(runningIn('r7'), [r7]),
   '开了以后又有 ' + gap + ' 个 rc 调用（审查里 7 个就认不出了），同一个 key 再来：认出来接上，不开第二个', { gap, s, j });
ok(n('job/status') <= 15 && peak <= 4, '找作业号：最多问 15 个，同时最多 4 个连接（探针 + 3）', { st: n('job/status'), peak });

/* 列目录不建组的 rclone（离这一组最近的 job/<n> 组隔得很远）、开了以后又隔了 40 多次调用：作业号找不到 */
LIST_GROUPS = false;
await between(30);
reset();
[s, j] = await call('batch-copy', { key: 'r8', items: BATCH });
const r8 = j.jobid;
await between(40);
STATS['tjb/r8'] = { bytes: 5, totalBytes: 1362, transferring: [{ name: MOVIE, srcFs: 'webdav:auto', bytes: 5, size: 1000 }] };
reset();
[s, j] = await call('batch-copy', { key: 'r8', items: BATCH });
ok(s === 200 && j.reused === true && j.jobid === 0 && j.running === 1 && j.group === 'tjb/r8' && j.items && n('sync/copy') === 0 && n('job/stopgroup') === 0
   && same(runningIn('r8'), [r8]) && n('job/status') <= 15,
   '统计里有正在传的、作业号没找到：回 jobid 0 + running，不开第二个、也不停它', { s, j, st: n('job/status') });
await between(30);
reset();
[s, j] = await call('batch-copy', { key: 'r9', items: BATCH });
const r9 = j.jobid;
await between(40);
reset();
[s, j] = await call('batch-copy', { key: 'r9', items: BATCH });
const stop9 = find('job/stopgroup'), sc9 = find('sync/copy');
ok(s === 200 && !j.reused && j.group === 'tjb/r9/2' && stop9 && stop9[1].group === 'tjb/r9' && sc9 && sc9[1]._group === 'tjb/r9/2' && calls.indexOf(stop9) < calls.indexOf(sc9)
   && JOBS[r9].finished && same(runningIn('r9'), [j.jobid]),
   '什么都没在传、作业号也没找到（可能还在列目录）：先停掉 tjb/r9 再开 tjb/r9/2，同一个 key 只有一个作业在跑', { s, j, running: runningIn('r9') });
await between(30);
reset();
[s, j] = await call('batch-copy', { key: 'r10', items: BATCH });
const r10 = j.jobid;
await between(40);
reset(); PLAN = { 'job/stopgroup': ['throw', 'throw', 'throw'] };
[s, j] = await call('batch-copy', { key: 'r10', items: BATCH });
ok(s === 503 && j.retry === 1 && n('sync/copy') === 0 && same(runningIn('r10'), [r10]), '停不掉上一组：503，不开', { s, j });
LIST_GROUPS = true;
reset(); PLAN = { 'core/group-list': ['throw', 'throw', 'throw'] };
[s, j] = await call('batch-copy', { key: 'r7', items: BATCH });
ok(s === 502 && n('sync/copy') === 0 && n('job/stopgroup') === 0, 'group-list 问不出来：502，不开', { s, j });

/* 看门狗停掉以后重开：统计组换一个，新作业的字节数 / 文件数 / 错误从 0 算（以前和停掉的那个累加，进度条提前到头） */
reset();
[s, j] = await call('batch-copy', { key: 'w1', items: BATCH });
const w1a = j.jobid;
STATS['tjb/w1'] = { bytes: 500000, totalBytes: 900000, speed: 0, transfers: 2, totalTransfers: 4, errors: 1, lastError: 'stalled' };
[s] = await call('stop', { jobid: w1a });
reset();
[s, j] = await call('batch-copy', { key: 'w1', items: BATCH });
const w1b = j.jobid;
ok(s === 200 && !j.reused && w1b !== w1a && j.group === 'tjb/w1/2' && find('sync/copy')[1]._group === 'tjb/w1/2' && n('job/stopgroup') === 0,
   '停掉以后重开：统计组 tjb/w1/2（找到了停掉的那个作业，不用再停组）', j);
STATS['tjb/w1/2'] = { bytes: 1000, totalBytes: 400000, speed: 5, transfers: 0, totalTransfers: 2, errors: 0 };
[s, j] = await call('job', { jobid: w1b, detail: 1 });
ok(s === 200 && j.group === 'tjb/w1/2' && j.bytes === 1000 && j.total === 400000 && j.totalTransfers === 2 && j.errors === 0 && j.lastError === '',
   '重开的作业只报自己的字节数 / 文件数 / 错误', j);
await call('stop', { jobid: w1b });
reset();
[s, j] = await call('batch-copy', { key: 'w1', items: BATCH });
ok(s === 200 && j.group === 'tjb/w1/3' && find('sync/copy')[1]._group === 'tjb/w1/3', '再停再开：tjb/w1/3', j);
reset();
[s, j] = await call('batch-copy', { key: 'w', items: BATCH.slice(0, 1) });
ok(s === 200 && j.group === 'tjb/w' && n('job/status') === 0, 'key w 不会被 tjb/w1… 当成自己的', j);
GROUPS = []; Object.values(JOBS).forEach(x => { x.finished = true; });       // rclone 重启过：组都没了
reset();
[s, j] = await call('batch-copy', { key: 'w1', items: BATCH });
ok(s === 200 && j.group === 'tjb/w1' && !j.reused, 'rclone 重启过：又从 tjb/w1 开始', j);

/* 截止（审查后 ④）：就在发 sync/copy 之前看；探针、查作业、建目录同时走（虚拟时钟） */
let sentAt = -1;
const plain = globalThis.fetch;
globalThis.fetch = async (url, init) => { if (new URL(url).pathname === '/sync/copy') sentAt = VCLOCK ? VCLOCK.v : -2; return plain(url, init); };
reset(); VCLOCK = { v: 0, cost: { 'operations/list': 34000, 'operations/mkdir': 15000 } };
[s, j] = await call('batch-copy', { key: 'c1', items: BATCH });
VCLOCK = null;
ok(s === 200 && j.jobid > 0 && sentAt >= 34000 && sentAt <= 40000, '探针 34 秒、建目录 15 秒：两样同时走，sync/copy 在 40 秒以内发出去（以前要到 49 秒）', { s, sentAt });
LIST_GROUPS = false;
await between(30); reset(); await call('batch-copy', { key: 'c2', items: BATCH }); await between(40);
reset(); sentAt = -1; VCLOCK = { v: 0, cost: { 'operations/list': 30000, 'job/stopgroup': 12000 } };
[s, j] = await call('batch-copy', { key: 'c2', items: BATCH });
VCLOCK = null; LIST_GROUPS = true;
ok(s === 503 && j.retry === 1 && n('job/stopgroup') === 1 && n('sync/copy') === 0 && sentAt === -1, '探针 30 秒 + 停组 12 秒：过了 40 秒，停组之后再看一次，不开（503）', { s, j });
reset(); VCLOCK = { v: 0, cost: { 'operations/list': 44000, 'job/list': 500, 'operations/mkdir': 15000 } };
[s, j] = await call('batch-copy', { key: 'c3', items: BATCH });
VCLOCK = null;
globalThis.fetch = plain;
ok(s === 503 && n('sync/copy') === 0, '探针 44 秒（审查里的例子，以前 59.5 秒才发 sync/copy）：不开', { s, j });

/* ══ batch-verify ══ */
world();
FS.dropbox = new Map();
put('dropbox', 'auto/' + MOVIE, 1000);
put('dropbox', 'auto/ram2/' + TV1.toLowerCase() + '/e01.mkv', 100);                    // Dropbox 那边文件夹大小写不同
put('dropbox', 'auto/ram2/' + TV1.toLowerCase() + '/E02.mkv', 199);                    // 大小不对
put('dropbox', 'auto/ram2/' + TV1.toLowerCase() + '/Subs/Café.srt', 5);          // NFD 写法
put('dropbox', 'auto/ram2/' + TV1.toLowerCase() + '/extra.nfo', 3);
put('dropbox', 'auto/Someone.Else.2023.mkv', 999);
const VB = [{ item: MOVIE, kind: 'file' }, { item: TV1, kind: 'dir', sub: 'ram2' }, { item: TV2, kind: 'dir', sub: 'ram2' }, { item: 'Gone.S01', kind: 'dir', sub: 'ram2' }];
reset();
[s, j] = await call('batch-verify', { items: VB });
const R = j.results || {};
ok(s === 200 && n('operations/list') === 2 && find('operations/list', b => b.fs === 'pikpak:auto' && b._filter) && find('operations/list', b => b.fs === 'dropbox:auto' && b._filter),
   '批量核对：两边各列一次（同一套过滤），源头是原生 pikpak', calls.map(c => c[1].fs));
ok(R[MOVIE] && R[MOVIE].ok === 1 && R[MOVIE].src.count === 1, '电影：一致', R[MOVIE]);
const t1 = R['ram2/' + TV1];
ok(t1 && t1.ok === 0 && t1.missingCount === 0 && t1.differCount === 1 && t1.differ[0].path === 'E02.mkv' && t1.differ[0].dst === 199 && t1.extra === 1 && t1.src.count === 3,
   '剧集：文件夹大小写不同、NFD 写法都认；E02 大小不对；多一个 extra；desktop.ini 不算', t1);
ok(R['ram2/' + TV2] && R['ram2/' + TV2].ok === 0 && R['ram2/' + TV2].missingCount === 1 && !R['ram2/' + TV2].nosrc, 'Dropbox 那边还没有：全缺', R['ram2/' + TV2]);
ok(R['ram2/Gone.S01'] && R['ram2/Gone.S01'].ok === 0 && R['ram2/Gone.S01'].nosrc === 1, '来源那边一个文件都没有：nosrc', R['ram2/Gone.S01']);
reset(); NOFILTER = true;
[s, j] = await call('batch-verify', { items: VB });
ok(s === 200 && j.results[MOVIE].ok === 1 && j.results['ram2/' + TV1].differCount === 1 && j.results['ram2/' + TV1].extra === 1, '过滤没生效也核得对（按路径归回条目，别的文件不算）', j.results);
reset(); DOWN = { 'dropbox:auto': 523 };
[s, j] = await call('batch-verify', { items: VB });
ok(s === 502 && j.side === 'dst' && j.results === undefined && j.ok === undefined, 'Dropbox 那边列不出：502 { side: dst }，不算不一致', { s, j });
reset(); DOWN = { 'pikpak:auto': 524 };
[s, j] = await call('batch-verify', { items: VB });
ok(s === 502 && j.side === 'src', 'PikPak 那边列不出：502 { side: src }', { s, j });
const keepDbx = FS.dropbox; FS.dropbox = new Map(); reset();
[s, j] = await call('batch-verify', { items: VB });
ok(s === 200 && j.results[MOVIE].ok === 0 && j.results[MOVIE].missingCount === 1 && j.results['ram2/' + TV1].missingCount === 3, 'Dropbox 那边 auto 都没有：全缺', j.results);
FS.dropbox = keepDbx;
reset();
[s, j] = await call('batch-verify', { items: VB, src: 'webdav' });
ok(s === 200 && j.via === 'webdav:' && find('operations/list', b => b.fs === 'webdav:auto'), 'src: webdav 改回 WebDAV 列', j.via);
[s, j] = await call('batch-verify', { items: many });
ok(s === 400, '批量核对超过 16 项：400', j);

/* ══ batch-purge ══ */
world();
const PB = [{ item: TV1, kind: 'dir', sub: 'ram2' }, { item: TV2, kind: 'dir', sub: 'ram2' }, { item: MOVIE, kind: 'file' }, { item: ODD, kind: 'file' },
            { item: 'Someone.Else.2023.mkv', kind: 'file' }, { item: 'Other.Show.S01', kind: 'dir', sub: 'ram2' }, { item: 'Never.There.mkv', kind: 'file' }, { item: 'Locked.mkv', kind: 'file' }];
put('pikpak', 'auto/Locked.mkv', 1); DENY = new Set(['auto/Locked.mkv']);
reset();
[s, j] = await call('batch-purge', { items: PB });
const P = j.results || {};
ok(s === 200 && P['ram2/' + TV1].ok === 1 && !P['ram2/' + TV1].gone && P[MOVIE].ok === 1 && P['Never.There.mkv'].ok === 1 && P['Never.There.mkv'].gone === 1
   && P['Locked.mkv'].error && !P['Locked.mkv'].ok, '批量删：删掉 / 本来就没了（gone）/ 出错，各回各的', P);
ok(peak <= 4 && peak >= 2, '最多 4 个同时删', peak);
ok(find('operations/purge', b => b.fs === 'pikpak:auto/ram2/' + TV1 && b.remote === '') && find('operations/deletefile', b => b.fs === 'pikpak:auto' && b.remote === MOVIE)
   && !FS.pikpak.has('auto/ram2/' + TV1 + '/E01.mkv') && FS.pikpak.has('auto/' + TV1 + '/E01.mkv'),
   '剧集删 pikpak:auto/ram2/<item>，电影删 pikpak:auto 里那个文件；老位置的同名文件夹不碰', calls.filter(c => /purge|deletefile/.test(c[0])).map(c => c[1]));
DENY = new Set();
reset();
[s, j] = await call('batch-purge', { items: many.slice(0, 9) });
ok(s === 400 && n('operations/deletefile') === 0, '批量删超过 8 项：400', j);
[s, j] = await call('batch-purge', { items: [{ item: 'ram2', kind: 'dir' }] });
ok(s === 400 && n('operations/purge') === 0, '批量删剧集区本身：400，一个都不删', j);
reset(); PLAN = { 'operations/purge': ['throw', 'throw'], 'operations/deletefile': ['throw'] };
[s, j] = await call('batch-purge', { items: [{ item: TV2, kind: 'dir', sub: 'ram2' }, { item: 'Other.Show.S01', kind: 'dir', sub: 'ram2' }, { item: ODD }] });
ok(s === 502 && j.results && Object.keys(j.results).length === 3 && n('operations/purge') === 2, '全都连不上 VPS：502（熔断看得见），删除不重试', { s, j });

/* ══ 单项接口带 sub ══ */
world();
for (let i = 0; i < 10; i++) put('pikpak', 'auto/ram2/' + TV2 + '/最新地址' + i + '.txt', 1);
reset();
[s, j] = await call('organize', { dir: TV2, sub: 'ram2' });
ok(s === 200 && j.deleted.length === 10 && j.deleted[0] === '最新地址0.txt' && j.deleted[9] === '最新地址9.txt'
   && find('operations/list', b => b.fs === 'pikpak:auto/ram2/' + TV2) && calls.filter(c => c[0] === 'operations/deletefile').every(c => c[1].fs === 'pikpak:auto/ram2/' + TV2),
   '整理剧集区里的文件夹：路径带 ram2，结果按原来的顺序', j);
ok(peak <= 4 && peak >= 2, '整理：最多 4 个同时删', peak);
reset();
[s, j] = await call('check', { dir: TV2, sub: 'ram2' });
ok(s === 200 && find('operations/list', b => b.fs === 'pikpak:auto/ram2/' + TV2), '完整性：列 pikpak:auto/ram2/<dir>', calls.map(c => c[1].fs));
reset();
[s, j] = await call('copy', { item: TV1, kind: 'dir', sub: 'RAM2' });
let cp = find('sync/copy');
ok(s === 200 && cp[1].srcFs === 'webdav:auto/ram2/' + TV1 && cp[1].dstFs === 'dropbox:auto/ram2/' + TV1 && !cp[1]._config && !cp[1]._filter
   && find('operations/mkdir', b => b.remote === 'auto/ram2'), '单项复制剧集：auto/ram2/<item>（sub 不分大小写），不带 _config', cp);
reset();
[s, j] = await call('copy', { item: 'x.mkv', kind: 'file', sub: 'ram2' });
cp = find('operations/copyfile');
ok(s === 200 && cp[1].srcFs === 'webdav:auto/ram2' && cp[1].dstFs === 'dropbox:auto/ram2' && cp[1].srcRemote === 'x.mkv', '单项复制文件：fs 是 auto/ram2', cp);
FS.dropbox = new Map();
put('dropbox', 'auto/ram2/' + TV1 + '/E01.mkv', 100); put('dropbox', 'auto/ram2/' + TV1 + '/E02.mkv', 200); put('dropbox', 'auto/ram2/' + TV1 + '/Subs/Café.srt', 5);
put('pikpak', 'auto/ram2/m.mkv', 9); put('dropbox', 'auto/ram2/m.mkv', 9);
reset();
[s, j] = await call('verify', { item: TV1, kind: 'dir', sub: 'ram2' });
ok(s === 200 && j.ok === 1 && find('operations/list', b => b.fs === 'pikpak:auto/ram2/' + TV1) && find('operations/list', b => b.fs === 'dropbox:auto/ram2/' + TV1), '单项核对剧集：两边都是 auto/ram2/<item>', j);
reset();
[s, j] = await call('verify', { item: 'm.mkv', kind: 'file', sub: 'ram2' });
ok(s === 200 && j.ok === 1 && find('operations/stat', b => b.fs === 'pikpak:auto/ram2') && find('operations/stat', b => b.fs === 'dropbox:auto/ram2'), '单项核对文件：stat 的 fs 是 auto/ram2', j);
reset();
[s, j] = await call('exists', { item: TV1, sub: 'ram2' });
ok(s === 200 && j.exists === 1 && find('operations/stat', b => b.fs === 'dropbox:auto/ram2' && b.remote === TV1), '单项 exists：dropbox:auto/ram2', j);
reset();
[s, j] = await call('purge', { item: TV1, kind: 'dir', sub: 'ram2' });
ok(s === 200 && find('operations/purge', b => b.fs === 'pikpak:auto/ram2/' + TV1), '单项删：pikpak:auto/ram2/<item>', calls);
reset();
[s, j] = await call('purge', { item: 'ram2', kind: 'dir' });
ok(s === 400 && n('operations/purge') === 0, 'purge ram2（剧集区本身）：400，什么都不删', j);
[s, j] = await call('verify', { item: 'Ram2', kind: 'dir' });
ok(s === 400 && n('operations/list') === 0, 'verify Ram2：400（不分大小写）', j);
[s, j] = await call('organize', { dir: 'ram2' });
ok(s === 400, 'organize ram2：400', j);
[s, j] = await call('copy', { item: TV1, kind: 'dir', sub: 'ram3' });
ok(s === 400 && n('sync/copy') === 0, 'sub 不是剧集区：400', j);
[s, j] = await call('copy', { item: TV1, kind: 'dir', sub: '../x' });
ok(s === 400, 'sub 是路径：400', j);
reset();
[s, j] = await call('purge', { item: 'ram2', kind: 'dir', sub: 'ram2' });
ok(s !== 400 && find('operations/purge', b => b.fs === 'pikpak:auto/ram2/ram2'), '剧集区里叫 ram2 的东西（auto/ram2/ram2）不算剧集区本身', { s, j });

/* 剧集区改名（AUTO_TV_DIR） */
const envTv = { ...env, AUTO_TV_DIR: 'tv' };
reset();
[s, j] = await call('ping', {}, envTv);
ok(j.tv === 'tv', 'AUTO_TV_DIR：剧集区叫 tv', j);
[s, j] = await call('copy', { item: 'X', kind: 'dir', sub: 'tv' }, envTv);
ok(s === 200 && find('sync/copy')[1].srcFs === 'webdav:auto/tv/X', 'sub tv → auto/tv/X', find('sync/copy'));
[s, j] = await call('copy', { item: 'X', kind: 'dir', sub: 'ram2' }, envTv);
ok(s === 400, '剧集区改成 tv 以后 sub ram2：400', j);
[s, j] = await call('purge', { item: 'tv', kind: 'dir' }, envTv);
ok(s === 400, '剧集区改成 tv 以后 purge tv：400', j);

/* ══ rename 挪进剧集区 ══ */
world();
const RAW = '恐怖前任大全.第2季[全4集][简繁英字幕].Worst.Ex.Ever.S02.2160p.NF.WEB-DL-BlackTV';
const NAME = 'Worst.Ex.Ever.S02.2160p.[Full-4][CN-HK-EN]-Cuven®';
put('pikpak', 'auto/' + NAME + '/E01.mkv', 1); put('pikpak', 'auto/' + RAW + '/E01.mkv', 1); put('pikpak', 'auto/ram2/' + RAW + '/E01.mkv', 1);
reset();
[s, j] = await call('rename', { dir: NAME, to: 'ram2' });
let mv = find('sync/move');
ok(s === 200 && j.name === NAME && j.sub === 'ram2' && j.jobid > 0 && mv && mv[1].srcFs === 'pikpak:auto/' + NAME && mv[1].dstFs === 'pikpak:auto/ram2/' + NAME && mv[1]._async,
   '名字不变也挪进 auto/ram2', { j, mv });
ok(find('operations/mkdir', b => b.fs === 'pikpak:' && b.remote === 'auto/ram2') && find('operations/stat', b => b.fs === 'pikpak:auto/ram2' && b.remote === NAME)
   && calls.findIndex(c => c[0] === 'operations/mkdir') < calls.indexOf(mv), '挪之前先建 auto/ram2、看目标在不在', calls.map(c => c[0]));
reset();
[s, j] = await call('rename', { dir: RAW, sub: 'ram2' });
mv = find('sync/move');
ok(s === 200 && j.name === NAME && j.sub === 'ram2' && mv[1].srcFs === 'pikpak:auto/ram2/' + RAW && mv[1].dstFs === 'pikpak:auto/ram2/' + NAME, '剧集区里原地改名（to 没给 = 跟 sub 一样）', mv);
put('pikpak', 'auto/ram2/' + NAME + '/E01.mkv', 1);
reset();
[s, j] = await call('rename', { dir: NAME, sub: 'ram2', to: 'ram2' });
ok(s === 200 && j.same === 1 && j.sub === 'ram2' && n('sync/move') === 0, '名字和区都没变：same，不挪', j);
reset();
[s, j] = await call('rename', { dir: NAME, to: 'ram2' });
ok(s === 409 && j.exists === 1 && n('sync/move') === 0, '目标已经有了：409 exists，不让 rclone 合并两个文件夹', { s, j });
reset();
[s, j] = await call('rename', { dir: NAME, sub: 'ram2', to: '' });
ok(s === 409 && j.exists === 1, '从剧集区挪回 auto、auto 里已有同名：409', { s, j });
reset();
[s, j] = await call('rename', { dir: RAW });
mv = find('sync/move');
/* [911] 909 那条路挪之前看一眼原来的在不在（一次 stat）；原来的在就照 909 原样挪 —— 新名字已经有了也不回 409、不看目标 */
ok(s === 200 && j.name === NAME && mv[1].srcFs === 'pikpak:auto/' + RAW && mv[1].dstFs === 'pikpak:auto/' + NAME && n('operations/mkdir') === 0
   && n('operations/stat') === 1 && find('operations/stat', b => b.fs === 'pikpak:auto' && b.remote === RAW && !b._async),
   '老客户端（没有 sub / to）：不建目录、不查目标，只先看一眼原来的（在 → 909 原样挪）', calls.map(c => c[0]));
[s, j] = await call('rename', { dir: NAME, to: 'tv' });
ok(s === 400, 'to 不是剧集区：400', j);

/* 审查后 ②：sync/move 到了 rclone、PikPak 一下就挪完了，回包丢了（520，sync/move 不重试）；下一轮重来 */
const RAW2 = 'Some.Show.S01.1080p.WEB-DL';
put('pikpak', 'auto/ram2/' + RAW2 + '/E01.mkv', 1); put('pikpak', 'auto/ram2/' + RAW2 + '/E02.mkv', 2);
MOVES = true; reset(); AFTER = { 'sync/move': [520] };
[s, j] = await call('rename', { dir: RAW2, sub: 'ram2', to: 'ram2' });
const movedTo = Array.from(FS.pikpak.keys()).filter(k => k.startsWith('auto/ram2/Some.Show.S01.') && !k.startsWith('auto/ram2/' + RAW2 + '/'));
ok(s === 502 && n('sync/move') === 1 && !FS.pikpak.has('auto/ram2/' + RAW2 + '/E01.mkv') && movedTo.length === 2, '（场景）第一次：挪完了、回包丢了 → 502', { s, j, movedTo });
reset();
[s, j] = await call('rename', { dir: RAW2, sub: 'ram2', to: 'ram2' });
const NEW2 = j.name, cfm = find('operations/stat', b => b._async === true);
ok(s === 200 && j.done === 1 && !j.exists && j.sub === 'ram2' && NEW2 && NEW2 !== RAW2 && FS.pikpak.has('auto/ram2/' + NEW2 + '/E01.mkv') && j.jobid > 0 && n('sync/move') === 0
   && find('operations/stat', b => b.fs === 'pikpak:auto/ram2' && b.remote === RAW2 && !b._async) && cfm && cfm[1].fs === 'pikpak:auto/ram2' && cfm[1].remote === NEW2,
   '重来：目标在、原来的不在了 = 上一次挪完了 → 200 done + 新名字（不再挪，不回 409 exists）', { s, j });
[s, j] = await call('job', { jobid: j.jobid });
ok(s === 200 && j.finished === true && j.success === true, 'done 带的作业号已经「跑完、成功」：老的请求添加照常等作业跑完、换成新名字', j);
put('pikpak', 'auto/ram2/' + RAW2 + '/E01.mkv', 1);                     // 原来的又有了：两个都在
reset(); PLAN = { 'operations/stat': ['ok', 523, 523, 523] };
[s, j] = await call('rename', { dir: RAW2, sub: 'ram2', to: 'ram2' });
ok(s === 502 && !j.exists && !j.done && n('sync/move') === 0, '目标在、原来的那个看不了（52x）：502，不猜 exists / done', { s, j });
reset();
[s, j] = await call('rename', { dir: RAW2, sub: 'ram2', to: 'ram2' });
ok(s === 409 && j.exists === 1 && j.name === NEW2 && n('sync/move') === 0, '原来的、目标都在：还是 409 exists', { s, j });
put('pikpak', 'auto/' + RAW2 + '/E01.mkv', 1);
reset(); AFTER = { 'sync/move': [520] };
[s, j] = await call('rename', { dir: RAW2 });
reset();
[s, j] = await call('rename', { dir: RAW2 });
const NEW3 = j.name, cfm3 = find('operations/stat', b => b._async === true);
ok(s === 200 && j.done === 1 && j.sub === '' && NEW3 && NEW3 !== RAW2 && FS.pikpak.has('auto/' + NEW3 + '/E01.mkv') && j.jobid > 0 && n('sync/move') === 0
   && find('operations/stat', b => b.fs === 'pikpak:auto' && b.remote === RAW2 && !b._async) && cfm3 && cfm3[1].fs === 'pikpak:auto' && cfm3[1].remote === NEW3,
   '[911] 老客户端（没有 sub / to）同样的重来：原来的不在、新名字在 → 200 done + 新名字（以前再发 sync/move，真 rclone 回一个必失败的作业）', { s, j });
[s, j] = await call('job', { jobid: j.jobid });
ok(s === 200 && j.finished === true && j.success === true, '[911] 909 那条路的 done：作业号「跑完、成功」，老的请求添加照常换成新名字', j);
MOVES = false;

/* ══ exists { items, tv } ══ */
world();
FS.dropbox = new Map();
put('dropbox', 'auto/A.mkv', 1); put('dropbox', 'auto/ram2/Show.S01/E01.mkv', 1);
reset();
[s, j] = await call('exists', { items: ['A.mkv', 'B.mkv', 'ram2', 'a.MKV'], tv: ['Show.S01', 'show.s02', 'SHOW.S01'] });
ok(s === 200 && same(j.exists, { 'A.mkv': 1, 'B.mkv': 0, 'a.MKV': 1 }) && same(j.tv, { 'Show.S01': 1, 'show.s02': 0, 'SHOW.S01': 1 })
   && n('operations/list') === 2 && find('operations/list', b => b.fs === 'dropbox:auto') && find('operations/list', b => b.fs === 'dropbox:auto/ram2'),
   'exists { items, tv }：两层各列一次；剧集区本身不算条目；不分大小写', j);
reset();
[s, j] = await call('exists', { items: ['A.mkv'] });
ok(s === 200 && j.exists['A.mkv'] === 1 && !('tv' in j) && n('operations/list') === 1, '只有 items：列一次，不回 tv', j);
reset();
[s, j] = await call('exists', { tv: ['Show.S01'] });
ok(s === 200 && same(j.exists, {}) && j.tv['Show.S01'] === 1 && n('operations/list') === 1 && find('operations/list', b => b.fs === 'dropbox:auto/ram2'), '只有 tv：只列剧集区', j);
FS.dropbox = new Map([['auto/A.mkv', 1]]);
reset();
[s, j] = await call('exists', { items: ['A.mkv'], tv: ['Show.S01'] });
ok(s === 200 && j.exists['A.mkv'] === 1 && j.tv['Show.S01'] === 0, 'Dropbox 里还没有剧集区：tv 全是 0', j);
reset(); DOWN = { 'dropbox:auto/ram2': 523 };
[s, j] = await call('exists', { items: ['A.mkv'], tv: ['Show.S01'] });
ok(s === 502, '剧集区列不出：502（不当成「不在了」）', { s, j });

/* ══ job detail、统计组 ══ */
JOBS = { 41: { finished: false, success: false, group: 'tjb/k9' }, 42: { finished: true, success: true, group: '' } };
STATS = {
  'tjb/k9': { bytes: 600, totalBytes: 1355, speed: 2e6, eta: 120, elapsedTime: 30.5, transfers: 3, totalTransfers: 7, checks: 7, totalChecks: 7, errors: 1, lastError: 'boom',
    transferring: [
      { name: 'ram2/' + TV1 + '/Subs/Café.srt', srcFs: 'webdav:auto', bytes: 2, size: 5, percentage: 40, speed: 10 },
      { name: MOVIE, srcFs: 'webdav:auto', bytes: 500, size: 1000, percentage: 50, speed: 1e6 },
      { name: 'E02.mkv', srcFs: 'webdav:auto/ram2/' + TV1, bytes: 1, size: 200, percentage: 0, speed: 0 },
      { name: 'ram2/' + TV2 + '/S01E01.mkv', bytes: 0, size: 50 }] },
  'job/42': { bytes: 9, totalBytes: 9, speed: 0 },
};
reset();
[s, j] = await call('job', { jobid: 41 });
ok(s === 200 && j.bytes === 600 && j.total === 1355 && find('core/stats', b => b.group === 'tjb/k9') && !('transferring' in j) && n('job/status') === 1 && n('core/stats') === 1,
   '统计组从 job/status 读（tjb/<key>）；不带 detail 照旧那几个字段', j);
reset();
[s, j] = await call('job', { jobid: 41, detail: 1 });
const T = j.transferring || [];
ok(s === 200 && j.eta === 120 && j.elapsed === 30.5 && j.transfers === 3 && j.totalTransfers === 7 && j.checks === 7 && j.totalChecks === 7 && j.errors === 1 && j.lastError === 'boom' && j.group === 'tjb/k9',
   'detail：eta / 用时 / 文件数 / 检查数 / 错误', j);
ok(T.length === 4 && same(T[0], { item: TV1, sub: 'ram2', file: 'Subs/Café.srt', bytes: 2, size: 5, pct: 40, speed: 10 })
   && same(T[1], { item: MOVIE, sub: '', file: MOVIE, bytes: 500, size: 1000, pct: 50, speed: 1e6 })
   && T[2].item === TV1 && T[2].sub === 'ram2' && T[2].file === 'E02.mkv' && T[3].item === TV2 && T[3].sub === 'ram2',
   '正在传的文件归到条目（批量作业、单项作业、没有 srcFs 的老版本）', T);
JOBS[43] = { finished: false, success: false, group: '' }; STATS['job/43'] = { bytes: 3, totalBytes: 30, speed: 1 };
reset();
[s, j] = await call('jobs', { ids: [41, 42, 43] });
/* [911] 跑完的作业（42）不再问统计：调用方跑完了只看 success / error；没跑完的还是 2 次调用，统计组按作业自己的 */
ok(s === 200 && j.jobs['41'].bytes === 600 && j.jobs['43'].bytes === 3 && n('job/status') === 3 && n('core/stats') === 2 && find('core/stats', b => b.group === 'job/43')
   && !find('core/stats', b => b.group === 'job/42') && same(j.jobs['42'], { finished: true, success: true, error: '' }),
   'jobs：没跑完的每个 2 次调用（统计组按作业自己的），跑完的只问 job/status', j);
for (let i = 0; i < 12; i++) JOBS[200 + i] = { finished: false, group: '' };
reset();
[s, j] = await call('jobs', { ids: Array.from({ length: 12 }, (_, i) => 200 + i) });
ok(s === 200 && Object.keys(j.jobs).length === 12 && peak <= 4 && n('job/status') === 12, 'jobs 12 个：同时最多 4 个连接', peak);
STATS['job/42'] = { bytes: 9, totalBytes: 9, speed: 0, eta: null };
[s, j] = await call('job', { jobid: 42, detail: 1 });
ok(s === 200 && j.eta === null && same(j.transferring, []) && j.group === 'job/42', 'detail：rclone 没给 eta 回 null，没在传回 []', j);

/* ══════════════ 911 加固（每条对应一个审查结论） ══════════════ */
const vat = [];                                                           // [接口, 虚拟时刻]：每个调用什么时候发出去的
const plain911 = globalThis.fetch;
globalThis.fetch = async (url, init) => { vat.push([new URL(url).pathname.slice(1), VCLOCK ? VCLOCK.v : -1]); return plain911(url, init); };
const vreset = () => { reset(); vat.length = 0; };
let vEnd = 0;
const vcall = async (cost, p, b) => { VCLOCK = { v: 0, cost: cost }; try { return await call(p, b); } finally { vEnd = VCLOCK.v; VCLOCK = null; } };

/* transfer-1：organize 一次最多删 40 个、45 秒以后不开新的删除，回 left；免费版 50 个子请求以内 */
world();
for (let i = 0; i < 70; i++) put('pikpak', 'auto/ram2/' + TV2 + '/Ep' + i + '/最新地址' + i + '.txt', 1);
vreset();
[s, j] = await call('organize', { dir: TV2, sub: 'ram2' });
ok(s === 200 && j.deleted.length === 40 && j.failed.length === 0 && j.left === 30 && n('operations/deletefile') === 40 && calls.length === 41 && peak <= 4,
   '[911-1] 70 个广告文件：这一次删 40 个、回 left 30（以前 61 个子请求，第 50 个以后全失败，60 个以后不提）', { s, del: j.deleted.length, left: j.left, calls: calls.length });
vreset();
[s, j] = await call('organize', { dir: TV2, sub: 'ram2' });
ok(s === 200 && j.deleted.length === 30 && j.left === 0 && j.files === 31, '[911-1] 再来一次（每次都重新列）：剩下的 30 个删完，left 0', j);
for (let i = 0; i < 70; i++) put('pikpak', 'auto/ram2/' + TV2 + '/Ep' + i + '/最新地址' + i + '.txt', 1);
vreset();
[s, j] = await vcall({ 'operations/list': 30000, 'operations/deletefile': 2500 }, 'organize', { dir: TV2, sub: 'ram2' });
const lastDel = Math.max(...vat.filter(x => x[0] === 'operations/deletefile').map(x => x[1]));
ok(s === 200 && j.deleted.length >= 16 && j.deleted.length < 40 && j.failed.length === 0 && j.left === 70 - j.deleted.length && lastDel <= 45000 && vEnd <= 53000,
   '[911-1] 列目录 30 秒、每个删除 2.5 秒：45 秒以后不再开新的删除，没删的算进 left（不算 failed），55 秒以内回到调用方（以前 67.5 秒）',
   { del: j.deleted.length, left: j.left, lastDel, vEnd });
world();

/* transfer-2：单项 verify 两边同时列 / 同时看；rename 太晚了不发 sync/move */
FS.dropbox = new Map();
put('dropbox', 'auto/ram2/' + TV1 + '/E01.mkv', 100); put('dropbox', 'auto/ram2/' + TV1 + '/E02.mkv', 200); put('dropbox', 'auto/ram2/' + TV1 + '/Subs/Café.srt', 5);
put('pikpak', 'auto/m.mkv', 9); put('dropbox', 'auto/m.mkv', 9);
vreset();
[s, j] = await vcall({ 'operations/list': 40000 }, 'verify', { item: TV1, kind: 'dir', sub: 'ram2' });
ok(s === 200 && j.ok === 1 && n('operations/list') === 2 && vEnd <= 41000, '[911-2a] 核对剧集：两边各列 40 秒，一共 40 秒（以前一个接一个 80 秒）', { s, vEnd });
vreset(); DOWN = { ['dropbox:auto/ram2/' + TV1]: 523 };
[s, j] = await call('verify', { item: TV1, kind: 'dir', sub: 'ram2' });
ok(s === 502 && j.side === 'dst', '[911-2a] Dropbox 那边列不出：照旧 502 side dst', { s, j });
vreset(); DOWN = { ['dropbox:auto/ram2/' + TV1]: 523 };
[s, j] = await call('verify', { item: 'Nope.S01', kind: 'dir', sub: 'ram2' });
ok(s === 422 && j.side === 'src', '[911-2a] 两边都出错：先报 PikPak 那边（不在了 422）', { s, j });
FS.dropbox.delete('auto/ram2/' + TV1 + '/E01.mkv'); FS.dropbox.delete('auto/ram2/' + TV1 + '/E02.mkv'); FS.dropbox.delete('auto/ram2/' + TV1 + '/Subs/Café.srt');
vreset();
[s, j] = await call('verify', { item: TV1, kind: 'dir', sub: 'ram2' });
ok(s === 200 && j.ok === 0 && j.missingCount === 3, '[911-2a] Dropbox 那边还没有这个文件夹：照旧全缺', j);
vreset();
[s, j] = await vcall({ 'operations/stat': 28000 }, 'verify', { item: 'm.mkv', kind: 'file' });
ok(s === 200 && j.ok === 1 && n('operations/stat') === 2 && vEnd <= 29000, '[911-2b] 核对文件：两次 stat 同时发（以前 2 × 30 秒）', { s, j, vEnd });
vreset();
[s, j] = await call('verify', { item: 'gone.mkv', kind: 'file' });
ok(s === 422 && j.side === 'src', '[911-2b] PikPak 那边没有这个文件：照旧 422 side src', { s, j });
vreset(); DOWN = { 'dropbox:auto': 523 };
[s, j] = await call('verify', { item: 'm.mkv', kind: 'file' });
ok(s === 502 && j.side === 'dst', '[911-2b] Dropbox 那边看不了：照旧 502 side dst', { s, j });
put('pikpak', 'auto/' + RAW + '/E01.mkv', 1);
vreset();
[s, j] = await vcall({ 'operations/mkdir': 15000, 'operations/stat': 15000 }, 'rename', { dir: RAW, to: 'ram2' });
ok(s === 503 && j.retry === 1 && n('sync/move') === 0 && FS.pikpak.has('auto/' + RAW + '/E01.mkv'),
   '[911-2c] 改名：建目录 15 秒 + 看目标 15 秒，过了 28 秒不发 sync/move（再 30 秒就拖过调用方的 60 秒），回 503 retry', { s, j });
vreset();
[s, j] = await vcall({ 'operations/stat': 30000 }, 'rename', { dir: RAW });
ok(s === 503 && j.retry === 1 && n('sync/move') === 0, '[911-2c] 909 那条路一样：看原来的花了 30 秒，这一轮不挪', { s, j });
vreset();
[s, j] = await vcall({ 'operations/stat': 12000 }, 'rename', { dir: RAW, to: 'ram2' });
ok(s === 200 && j.jobid > 0 && n('sync/move') === 1 && vat.find(x => x[0] === 'sync/move')[1] <= 28000, '[911-2c] 来得及（12 秒）：照常挪', { s, j });
world();

/* transfer-3：rclone 回 500 + 后端暂时性错误 → 502（熔断看得见）；没找到、权限、文件名里的数字 → 还是 422 */
const IOT = 'couldn\'t list files: Get "https://api-drive.mypikpak.com/drive/v1/files": dial tcp 1.2.3.4:443: i/o timeout';
vreset(); RCFAIL = { 'operations/list': [500, IOT] };
[s, j] = await call('check', { dir: TV2, sub: 'ram2' });
ok(s === 502, '[911-3] check：PikPak 超时（rclone 500）→ 502（以前 422，熔断不开、一行行攒到 20 次判死）', { s, j });
[s, j] = await call('organize', { dir: TV2, sub: 'ram2' });
ok(s === 502, '[911-3] organize：同上 502', { s, j });
[s, j] = await call('exists', { items: ['A.mkv'], tv: ['B'] });
ok(s === 502, '[911-3] exists { items }：同上 502', { s, j });
vreset(); RCFAIL = { 'operations/stat': [500, 'too_many_requests/..'] };
[s, j] = await call('exists', { item: MOVIE });
ok(s === 502, '[911-3] exists { item }：Dropbox too_many_requests → 502', { s, j });
vreset(); RCFAIL = { 'sync/copy': [500, 'upload failed: too_many_write_operations'] };
[s, j] = await call('copy', { item: TV1, kind: 'dir', sub: 'ram2' });
ok(s === 502, '[911-3] copy：too_many_write_operations → 502', { s, j });
vreset(); RCFAIL = { 'operations/purge': [500, 'pikpak: HTTP error 503 Service Unavailable'] };
[s, j] = await call('purge', { item: TV1, kind: 'dir', sub: 'ram2' });
ok(s === 502, '[911-3] purge：HTTP error 503 → 502', { s, j });
[s, j] = await call('batch-purge', { items: [{ item: TV1, kind: 'dir', sub: 'ram2' }, { item: TV2, kind: 'dir', sub: 'ram2' }] });
ok(s === 502 && j.results['ram2/' + TV1].status === 502, '[911-3] batch-purge：全是后端暂时性错误也算「连不上」→ 502（以前看 rc，算成逻辑错误回 200）', { s, j });
vreset(); RCFAIL = { 'operations/purge': [500, 'can\'t purge Show.S01E429.2160p.HTTP.503: permission denied'] };
[s, j] = await call('purge', { item: TV1, kind: 'dir', sub: 'ram2' });
ok(s === 422, '[911-3] 名字里的 429 / 503 / HTTP 不算：权限不够 → 还是 422', { s, j });
[s, j] = await call('batch-purge', { items: [{ item: TV1, kind: 'dir', sub: 'ram2' }] });
ok(s === 200 && j.results['ram2/' + TV1].status === 422, '[911-3] batch-purge：逻辑错误照旧回 200 + 这一项的 error', { s, j });
vreset(); RCFAIL = { 'operations/list': [500, 'directory not found'] };
[s, j] = await call('check', { dir: TV2, sub: 'ram2' });
ok(s === 422, '[911-3] 不像暂时性的消息（rclone 500 directory not found）：还是 422', { s, j });
vreset();
[s, j] = await call('job', { jobid: 987654 });
ok(s === 200 && j.missing === 1, '[911-3] job not found（rclone 回 500）：照旧 missing', { s, j });
vreset();
[s, j] = await call('check', { dir: 'Nope.S01', sub: 'ram2' });
ok(s === 422, '[911-3] 真没找到（404）：照旧 422', { s, j });

/* transfer-4：jobs 一个都没问到、全是连不上 → 502 */
JOBS[41] = { finished: false, success: false, group: 'tjb/k9' }; JOBS[42] = { finished: true, success: true, group: '' }; JOBS[43] = { finished: false, success: false, group: '' };
vreset(); PLAN = { 'job/status': [524, 524, 524] };
[s, j] = await call('jobs', { ids: [41, 43, 42] });
ok(s === 502 && j.jobs && j.jobs['41'].status === 502 && Object.keys(j.jobs).length === 3, '[911-4] jobs：VPS 连不上（全部 5xx）→ 502（以前 200，请求添加的熔断当成 VPS 好好的）', { s, j });
vreset(); PLAN = { 'job/status': [524, 524] };
[s, j] = await call('jobs', { ids: [41, 43, 42] });
ok(s === 200 && Object.values(j.jobs).filter(x => x.status === 502).length === 2 && Object.values(j.jobs).filter(x => x.finished && !x.error).length === 1, '[911-4] 问到了一个：照旧 200', { s, j });
vreset();
[s, j] = await call('jobs', { ids: [987651, 987652] });
ok(s === 200 && j.jobs['987651'].missing === 1 && j.jobs['987652'].missing === 1, '[911-4] 全是作业没了（missing）：照旧 200', { s, j });

/* transfer-5：单项 purge 删完了、回包丢了，重来 → 200 gone */
world();
vreset(); AFTER = { 'operations/purge': [520] };
[s, j] = await call('purge', { item: TV2, kind: 'dir', sub: 'ram2' });
ok(s === 502 && !FS.pikpak.has('auto/ram2/' + TV2 + '/S01E01.mkv') && n('operations/purge') === 1, '[911-5]（场景）删完了、回包丢了（520，purge 不重试）→ 502', { s, j });
vreset();
[s, j] = await call('purge', { item: TV2, kind: 'dir', sub: 'ram2' });
ok(s === 200 && j.ok === 1 && j.gone === 1, '[911-5] 重来：directory not found → 200 { ok, gone }（以前 422，删完的一项最后判失败）', { s, j });
vreset(); AFTER = { 'operations/deletefile': [520] };
[s, j] = await call('purge', { item: ODD, kind: 'file' });
vreset();
[s, j] = await call('purge', { item: ODD, kind: 'file' });
ok(s === 200 && j.ok === 1 && j.gone === 1, '[911-5] 文件也一样：object not found → 200 gone', { s, j });
DENY.add('auto/' + MOVIE);
vreset();
[s, j] = await call('purge', { item: MOVIE, kind: 'file' });
ok(s === 422, '[911-5] 别的 rclone 错误（权限）：照旧 422', { s, j });
DENY.clear();

/* transfer-6：909 那条路（没有 sub / to）挪之前先看原来的 */
const RAW6 = 'Other.Show.S03.1080p.WEB-DL';
put('pikpak', 'auto/' + RAW6 + '/E01.mkv', 1);
MOVES = true;
vreset(); PLAN = { 'operations/stat': [523, 523, 523] };
[s, j] = await call('rename', { dir: RAW6 });
ok(s === 200 && j.jobid > 0 && !j.done && n('sync/move') === 1, '[911-6] 原来的看不了（52x）：照 909 原样挪，不猜 done、不回 409', { s, j });
const NEW6 = j.name;
vreset();
[s, j] = await call('rename', { dir: RAW6 });
ok(s === 200 && j.done === 1 && j.name === NEW6 && n('sync/move') === 0, '[911-6] 挪完了再来（回包丢了的那种）：原来的不在、新名字在 → done', { s, j });
FS.pikpak.delete('auto/' + NEW6 + '/E01.mkv');
vreset();
[s, j] = await call('rename', { dir: RAW6 });
ok(s === 200 && !j.done && j.jobid > 0 && n('sync/move') === 1 && JOBS[j.jobid].success === false, '[911-6] 原来的、新名字都不在：照 909 原样发 sync/move（不自作主张）', { s, j });
MOVES = false;

/* transfer-7：单项复制认统计组；retry 才先查，接上还在跑的，不开第二个 */
world(); RUNNING_IDS = false;
vreset();
[s, j] = await call('copy', { item: TV1, kind: 'dir', sub: 'ram2' });
const g7 = String(find('sync/copy')[1]._group || ''), base7 = 'tjc/ram2/' + TV1 + '/';
ok(s === 200 && j.jobid > 0 && g7.startsWith(base7) && /^\d{13}$/.test(g7.slice(base7.length)) && n('core/group-list') === 0 && n('job/list') === 0 && n('job/status') === 0,
   '[911-7] 单项复制带统计组 tjc/<sub/item>/<毫秒>；不带 retry 不多问一次（和 909 一样：建目录 + 开作业）', { j, g7 });
vreset();
[s, j] = await call('copy', { item: 'x.mkv', kind: 'file' });
ok(s === 200 && String(find('operations/copyfile')[1]._group || '').startsWith('tjc/x.mkv/'), '[911-7] 单个文件也带（tjc/<item>/<毫秒>）', find('operations/copyfile'));
vreset(); AFTER = { 'sync/copy': [520] };
[s, j] = await call('copy', { item: TV2, kind: 'dir', sub: 'ram2' });
const lost7 = Object.keys(JOBS).map(Number).filter(id => !JOBS[id].finished && String(JOBS[id].group).startsWith('tjc/ram2/' + TV2 + '/'));
ok(s === 502 && lost7.length === 1, '[911-7]（场景）开出去了、回包丢了（520，不重试）→ 502，rclone 那边作业在跑', { s, lost7 });
await between(6);
vreset();
[s, j] = await call('copy', { item: TV2, kind: 'dir', sub: 'ram2', retry: 1 });
const run7 = Object.keys(JOBS).map(Number).filter(id => !JOBS[id].finished && String(JOBS[id].group).startsWith('tjc/ram2/' + TV2 + '/'));
ok(s === 200 && j.reused === true && j.jobid === lost7[0] && n('sync/copy') === 0 && same(run7, lost7) && n('operations/mkdir') === 1,
   '[911-7] retry：认出上一次开的那个还在跑 → 接上（reused），不开第二个（以前两个作业一起传同一项）', { s, j, run7 });
RUNNING_IDS = true;
vreset();
[s, j] = await call('copy', { item: TV2, kind: 'dir', sub: 'ram2', retry: 1 });
ok(s === 200 && j.reused === true && j.jobid === lost7[0] && n('sync/copy') === 0, '[911-7] 新版 rclone（runningIds）：一样接上', { s, j });
RUNNING_IDS = false;
if (lost7[0]) await call('stop', { jobid: lost7[0] });
vreset();
[s, j] = await call('copy', { item: TV2, kind: 'dir', sub: 'ram2', retry: 1 });
const g7b = (find('sync/copy') || [0, {}])[1]._group || '';
ok(s === 200 && !j.reused && j.jobid > 0 && j.jobid !== lost7[0] && g7b.startsWith('tjc/ram2/' + TV2 + '/') && JOBS[lost7[0]] && g7b !== JOBS[lost7[0]].group
   && Number(g7b.split('/').pop()) > Number(String(JOBS[lost7[0]].group).split('/').pop()),
   '[911-7] retry：上一次的已经停了 / 跑完了 → 开新的，统计组换一个（不和上一次累加）', { s, j, g7b });
vreset(); PLAN = { 'core/group-list': ['throw', 'throw', 'throw'] };
[s, j] = await call('copy', { item: TV2, kind: 'dir', sub: 'ram2', retry: 1 });
ok(s === 502 && n('sync/copy') === 0, '[911-7] retry 时查不清楚（group-list 问不出来）：502，不开', { s, j });
LIST_GROUPS = false;
vreset(); AFTER = { 'sync/copy': [520] };
[s, j] = await call('copy', { item: TV1, kind: 'dir', sub: 'ram2' });
await between(40);
const lost7b = Math.max(0, ...Object.keys(JOBS).map(Number).filter(id => !JOBS[id].finished && String(JOBS[id].group).startsWith('tjc/ram2/' + TV1 + '/')));
STATS[(JOBS[lost7b] || {}).group] = { bytes: 5, totalBytes: 9, transferring: [{ name: 'E01.mkv', bytes: 5, size: 100 }] };
vreset();
[s, j] = await call('copy', { item: TV1, kind: 'dir', sub: 'ram2', retry: 1 });
LIST_GROUPS = true;
ok(s === 503 && j.retry === 1 && n('sync/copy') === 0 && n('job/stopgroup') === 0 && JOBS[lost7b] && !JOBS[lost7b].finished, '[911-7] retry：统计里在传、作业号没找到 → 503 retry，不开第二个、也不停它', { s, j });

/* transfer-8：core/stats 没问到（job/status 问到了） */
JOBS[41] = { finished: false, success: false, group: 'tjb/k9' };
vreset(); PLAN = { 'core/stats': [524] };
[s, j] = await call('job', { jobid: 41, detail: 1 });
ok(s === 503 && /统计/.test(j.error), '[911-8] detail（批量）：统计没问到 → 503（以前回 0 字节，成员一起写成 0%）', { s, j });
vreset(); PLAN = { 'core/stats': [524] };
[s, j] = await call('job', { jobid: 41 });
ok(s === 200 && j.finished === false && !('bytes' in j) && !('total' in j) && !('speed' in j) && j.stats === 0,
   '[911-8] 不带 detail：照常回 finished / success，不回 bytes / total / speed（老调用方保持上一次的进度）', { s, j });
JOBS[42] = { finished: true, success: true, group: '' };
vreset(); PLAN = { 'core/stats': [524] };
[s, j] = await call('job', { jobid: 42, detail: 1 });
ok(s === 200 && j.finished === true && j.success === true, '[911-8] 跑完了的 detail：统计没问到也回跑完（批量收尾只看 success）', { s, j });

/* transfer-9：batch-copy 找作业时 runningIds 那段也看截止；问过的不再问第二遍 */
world();
Object.values(JOBS).forEach(x => { x.finished = true; });
RUNNING_IDS = true;
const fake = Array.from({ length: 16 }, (_, i) => nextJob + 50000 + i);
fake.forEach((id, i) => { JOBS[id] = { finished: false, success: false, group: 'other/' + i }; });
vreset();
[s, j] = await vcall({ 'job/status': 9000 }, 'batch-copy', { key: 'sl1', items: BATCH });
const sent9 = (vat.find(x => x[0] === 'sync/copy') || [0, -1])[1];
ok(s === 200 && j.jobid > 0 && n('job/status') <= 12 && sent9 >= 0 && sent9 <= 40000,
   '[911-9] 16 个别人的作业在跑、每个 job/status 9 秒：到点就不问了（这个 key 从没开过，开），40 秒以内发出 sync/copy（以前问满 16 个、54 秒，回 503）',
   { s, st: n('job/status'), sent9 });
fake.forEach(id => { delete JOBS[id]; });                                    // 上面那 16 个是凭空造的大号（真 rclone 的作业号只往上走）
Object.values(JOBS).forEach(x => { x.finished = true; });                  // sl1 和别人的都跑完了
/* 列目录不建组的 rclone：这一组前后没有 job/<n> 可以定位，作业号从最新的往回挑 15 个 —— 正好是刚问过的那些在跑的 */
GROUPS = []; LIST_GROUPS = false;
reset();
[s, j] = await call('batch-copy', { key: 'sl2', items: BATCH });
const sl2 = j.jobid;
Object.assign(JOBS[sl2], { finished: true, success: true });                         // sl2 跑完了；之后又有 16 个别人的作业开起来
const fake2 = Array.from({ length: 16 }, () => nextJob++);
fake2.forEach((id, i) => { JOBS[id] = { finished: false, success: false, group: 'other2/' + i }; });
vreset(); FLAP = new Set([fake2[0]]);
[s, j] = await call('batch-copy', { key: 'sl2', items: BATCH });
const asked9 = {};
calls.filter(c => c[0] === 'job/status').forEach(c => { asked9[c[1].jobid] = (asked9[c[1].jobid] || 0) + 1; });
const twice = fake2.slice(1).filter(id => asked9[id] > 1);
LIST_GROUPS = true;
ok(s === 200 && !j.reused && j.group === 'tjb/sl2/2' && twice.length === 0 && asked9[sl2] === 1 && n('job/stopgroup') === 0,
   '[911-9] 有一个 job/status 一直 520，退到看统计找作业号：runningIds 问过的不再问第二遍、15 个名额留给没问过的（以前把刚问过的 15 个再问一遍，找不到 sl2，只好停组重开）',
   { s, j, twice, sl2, asked: asked9[sl2], stop: n('job/stopgroup') });
if (JOBS[j.jobid]) JOBS[j.jobid].finished = true;
vreset();
[s, j] = await vcall({ 'job/status': 9000 }, 'batch-copy', { key: 'sl2', items: BATCH });
ok(s === 503 && n('sync/copy') === 0 && n('job/status') <= 12 && !find('core/stats') && vEnd <= 40000,
   '[911-9] 有过这个 key、16 个在跑的问到截止还没问完：回 503，不再接着问统计 + 15 个作业号（以前问满 16 个到 54 秒，再退到统计那条路能到 117 个子请求）',
   { s, j, st: n('job/status'), vEnd });
RUNNING_IDS = false; FLAP = new Set();
globalThis.fetch = plain911;

const v = await worker.fetch(new Request('https://transfer.cuven.us/version'), env);
ok(/911/.test(await v.text()), '版本号 911');

console.log(`\n传输 Worker 910 批量 + 911 加固：${pass} 项通过，${fail} 项失败`);
process.exit(fail ? 1 : 0);
