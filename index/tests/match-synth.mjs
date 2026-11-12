// 缺片检测的大样本压测：随机生成一个片海（含重拍片、同名不同片、续集），从中抽索引与片库，
// 片库条目按线上比例加噪声（繁体、全角、罗马数字、冠词、标点、缺年份、年份差一、Stream 认错 id），
// 然后看判定：误藏率（缺片被藏）与漏判率（有的片显示缺片）。
import fs from 'node:fs';
import * as H from './harness.mjs';
import { seedIndex } from './match-score.mjs';

/* 可复现的随机数 */
export function rng(seed) { let x = seed >>> 0 || 1; return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; }; }

const CN = '天地人山水风云雨雪花月星光影夜梦心爱恋情城门海河江湖龙虎凤鹰狼狐猫犬马鱼鸟春夏秋冬东南西北金银铁石火土木林森远近古今新旧黑白红蓝绿紫黄青长短大小高低明暗生死战杀谜盗侠剑刀枪弹机甲神魔鬼怪仙妖王后帝将军兵士警探医师少年少女父母兄弟姐妹朋友家国英雄传说故事纪元之子行者猎人信使守望';
const EN = ['night', 'river', 'storm', 'shadow', 'king', 'queen', 'wolf', 'city', 'dream', 'fire', 'iron', 'stone', 'ghost', 'blade', 'star', 'moon', 'sun', 'heart', 'war', 'last', 'dark', 'lost', 'red', 'blue', 'silent', 'golden', 'secret', 'empire', 'hunter', 'legend', 'house', 'road', 'sea', 'sky', 'winter', 'summer', 'black', 'white', 'wild', 'broken'];
/* 繁体：拿 worker 里同一张字表反过来用 */
let S2T = null;
function trad(s) {
  if (!S2T) {
    const src = fs.readFileSync(H.SRC_FILE, 'utf8');
    const t = [...(/const ZH_T = `(.*?)`;/s.exec(src) || [, ''])[1]], z = [...(/const ZH_S = `(.*?)`;/s.exec(src) || [, ''])[1]];
    S2T = new Map(); for (let i = 0; i < t.length; i++) if (!S2T.has(z[i])) S2T.set(z[i], t[i]);
  }
  return [...s].map(c => S2T.get(c) || c).join('');
}
const full = s => s.replace(/[!-~]/g, c => String.fromCharCode(c.charCodeAt(0) + 0xFEE0));
const ROMAN = ['', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX'];

export function makeWorld(seed, n = 6000, kind = 'movie') {
  const R = rng(seed);
  const pick = a => a[Math.floor(R() * a.length)];
  const films = [];
  let id = 1000;
  const used = new Set();
  while (films.length < n) {
    const len = 2 + Math.floor(R() * 4);
    let cn = ''; for (let i = 0; i < len; i++) cn += CN[Math.floor(R() * CN.length)];
    const ew = 1 + Math.floor(R() * 3);
    let en = []; for (let i = 0; i < ew; i++) en.push(pick(EN));
    en = en.join(' '); en = en[0].toUpperCase() + en.slice(1);
    if (R() < 0.15) en = 'The ' + en;
    const y = 1960 + Math.floor(R() * 66);
    if (used.has(cn + en)) continue;
    used.add(cn + en);
    films.push({ id: id++, cn, en, y });
    const r = R();
    if (r < 0.05) films.push({ id: id++, cn, en, y: Math.min(2025, y + 5 + Math.floor(R() * 30)) });            // 重拍：同名，隔几年到几十年
    else if (r < 0.07) films.push({ id: id++, cn, en: en + ' Story', y: y + (R() < 0.5 ? 1 : 0) });              // 同中文名、同年或差一年的另一部
    else if (r < 0.12) { const k = 2 + Math.floor(R() * 3); films.push({ id: id++, cn: cn + k, en: en + ' ' + (R() < 0.5 ? ROMAN[k] : k), y: y + 2 + Math.floor(R() * 4) }); }  // 续集
  }
  /* 索引：片海里抽 70%；片库：片海里抽 35%（两者有交集，也各有独有的） */
  const index = films.filter(() => R() < 0.7);
  const lib = films.filter(() => R() < 0.35);
  const items = [];
  const libIds = new Set();
  for (const f of lib) {
    libIds.add(f.id);
    const r = R();
    let zh = f.cn, en = f.en, gy = String(f.y);
    if (R() < 0.15) zh = trad(zh);
    if (R() < 0.05) en = full(en);
    if (R() < 0.1) en = en.replace(/^The /, '');
    if (R() < 0.1) en = en.replace(/ (II|III|IV|V|VI|VII|VIII|IX)$/, (m, x) => ' ' + ROMAN.indexOf(x)).replace(/ ([2-9])$/, (m, d) => ' ' + ROMAN[d]);
    if (R() < 0.1) zh = zh + '：' + pick(['导演剪辑版', '加长版']).slice(0, 0);
    if (kind === 'movie' && R() < 0.06) gy = String(f.y + (R() < 0.5 ? 1 : -1));
    if (kind === 'tv' && R() < 0.5) gy = String(f.y + Math.floor(R() * 8));                  // 剧集：季目录年份晚于首播
    const base = { key: 'k' + f.id + '_' + items.length, kind: kind === 'tv' ? 'series' : 'movie', name: zh + '.' + gy };
    if (r < 0.62) items.push({ ...base, tmdb: f.id, type: kind, title: f.cn, orig: f.en, year: String(f.y), guessYear: gy });
    else if (r < 0.86) items.push({ ...base, guess: zh, guessZh: zh, guessEn: en, guessYear: gy });
    else if (r < 0.94) items.push({ ...base, guess: zh, guessZh: zh, guessEn: en });         // 文件名里没有年份
    else {
      /* Stream 认错：挂上另一部年份差得远的片的 id */
      const wrong = films[Math.floor(R() * films.length)];
      if (Math.abs(wrong.y - f.y) <= 1 || wrong.id === f.id) { items.push({ ...base, guess: zh, guessZh: zh, guessEn: en, guessYear: gy }); continue; }
      items.push({ ...base, tmdb: wrong.id, type: kind, title: wrong.cn, orig: wrong.en, year: String(wrong.y), guess: zh, guessZh: zh, guessEn: en, guessYear: gy });
    }
  }
  return { films, index, items, libIds };
}

export async function evaluate(seed, n, kind = 'movie', file) {
  const w = makeWorld(seed, n, kind);
  if (file) H.useSource?.(file);
  const { env, r2, W } = H.makeEnv({ RECV_BASE: 'https://recv.test' });
  seedIndex(r2, kind === 'tv' ? 'idx/tv/' : 'idx/v4/', w.index.map(f => [f.id, f.cn, f.en, f.y]));
  W.recv.meta = { gen: 'g' + seed };
  W.recv.doc = { gen: 'g' + seed, ts: 1, count: w.items.length, items: w.items };
  const I = H.isolate(env, W, file ? { file } : {});
  const src = kind === 'tv' ? 'tv' : 'movie';
  await (await I.call('/api/lib?refresh=1&src=' + src)).json();
  const got = new Map();
  const t0 = performance.now();
  for (let pg = 1; ; pg++) {
    const r = await (await I.call(`/api/catalog?min=0&own=all&page=${pg}&src=${src}`)).json();
    for (const it of r.items || []) got.set(it.id, it.own || 0);
    if (!r.items || pg >= r.pages) break;
  }
  const ms = performance.now() - t0;
  let tp = 0, fp = 0, fn = 0, tn = 0;
  for (const f of w.index) {
    const own = w.libIds.has(f.id), g = got.get(f.id) > 0;
    if (own && g) tp++; else if (!own && g) fp++; else if (own && !g) fn++; else tn++;
  }
  return { tp, fp, fn, tn, index: w.index.length, lib: w.items.length, ms,
    precision: tp / Math.max(1, tp + fp), recall: tp / Math.max(1, tp + fn) };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const file = process.argv[2] || null;
  for (const [seed, n, kind] of [[1, 6000, 'movie'], [2, 6000, 'movie'], [3, 3000, 'tv']]) {
    const r = await evaluate(seed, n, kind, file);
    console.log(`${kind} seed=${seed} 索引 ${r.index} 部 · 片库 ${r.lib} 条 · 误藏 ${r.fp} · 漏判 ${r.fn} · 判对的已有 ${r.tp} · 精确率 ${(r.precision * 100).toFixed(2)}% · 召回率 ${(r.recall * 100).toFixed(2)}% · 翻完目录 ${r.ms.toFixed(0)}ms`);
  }
}
