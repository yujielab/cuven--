// 拿 match-cases 的标准答案给缺片检测打分：把那几十部片直接写成索引，总账挂上，查目录（own=all）看每部片的判定。
import * as H from './harness.mjs';
import * as C from './match-cases.mjs';

const F = { N: 0, O: 1, Y: 2, P: 3, T: 4, C: 5, G: 6, YS: 7, R: 8, B: 9, Q: 10, Z: 11, BT: 12, SP: 13, BM: 14, HB: 15, RB: 16 };
export function seedIndex(r2, ns, list) {
  const m = {};
  for (const [id, n, o, y] of list) {
    const a = new Array(17).fill(null);
    a[F.N] = n; a[F.O] = o; a[F.Y] = String(y); a[F.P] = '/p.jpg'; a[F.T] = 7.5; a[F.C] = 1000; a[F.G] = [];
    a[F.YS] = [y]; a[F.R] = 1; a[F.B] = 50; a[F.BM] = 1000; a[F.HB] = 0; a[F.RB] = 4; a[F.SP] = {};
    m[id] = a;
  }
  const put = (k, v) => { r2.m.set(k, { body: JSON.stringify(v), etag: String(Math.random()) }); };
  put(ns + 'movies.json', { v: 4, m, k: {}, u: {}, pv: 2 });
  const years = {};
  for (const y of [2026, 2025, 2024, 2023, 2022, 2021, 2020]) years[y] = { page: 2, last: 1, done: true, bad: [], pn: [] };
  put(ns + 'state.json', { v: 4, years, at: 1, ver: 7, deaths: 0, movies: list.length, rels: list.length });
}

export async function score(opt = {}) {
  const { env, r2, W } = H.makeEnv({ RECV_BASE: 'https://recv.test' });
  seedIndex(r2, 'idx/v4/', C.movies);
  seedIndex(r2, 'idx/tv/', C.shows);
  W.recv.meta = { gen: 'g1', count: C.items.length };
  W.recv.doc = { gen: 'g1', ts: 1, count: C.items.length, items: C.items };
  const I = H.isolate(env, W, opt.file ? { file: opt.file } : {});
  const out = {};
  for (const [src, list, exp] of [['movie', C.movies, C.expectMovie], ['tv', C.shows, C.expectTV]]) {
    await (await I.call('/api/lib?refresh=1&src=' + src)).json();
    const t0 = performance.now();
    const cat = await (await I.call('/api/catalog?min=0&own=all&src=' + src)).json();
    const ms = performance.now() - t0;
    const got = {};
    for (const it of cat.items || []) got[it.id] = it.own || 0;
    const rows = [];
    let ok = 0, n = 0, fp = 0, fn = 0;
    for (const [id, n0, o, y] of list) {
      const e = exp[id];
      const g = got[id] ?? 0;
      if (e === null || e === undefined) { rows.push([id, n0, y, e, g, '·']); continue; }
      n++;
      const good = (e > 0) === (g > 0);
      if (good) ok++; else if (g > 0) fp++; else fn++;
      rows.push([id, n0, y, e, g, good ? '✓' : (g > 0 ? '误藏' : '漏判')]);
    }
    out[src] = { ok, n, fp, fn, rows, ms, total: cat.total };
  }
  return out;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const r = await score({ file: process.argv[2] || null });
  for (const src of Object.keys(r)) {
    const x = r[src];
    console.log(`\n${src}: ${x.ok}/${x.n} 判对 · 误藏（其实缺片却被当成已有）${x.fp} · 漏判（其实有却显示缺片）${x.fn}`);
    for (const row of x.rows) if (row[5] !== '✓') console.log('  ', row[5], row[1], row[2], '期望', row[3], '实际', row[4]);
  }
}
