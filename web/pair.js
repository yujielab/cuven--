/* Cuven 光学配对（网页端：显示粒子云的那一边）
 * ─────────────────────────────────────────────────────────────────────
 *  · 编码：配对编号 24 位 + 密钥 32 位 + CRC-8 → 卷积码（K=7，171/133）→ 交织 → 加导频 → 160 个格子的正负
 *  · 码场：D(x) = Σ b_i·G_i(扭曲后的 x)；调制 M = （1 + α·tanh(D/τ)）×（1 + β·覆盖度²·exp(−(D/w)²)）
 *    规范与 Python 参考实现（pairing/py/spec.py）、iOS（PairCodec.swift）逐项一致，常数见下面的 SPEC
 *  · 外观（WebGL，GPU）：照 Apple 配对动画复刻的粒子云 —— 3D 球壳 + 一圈光晕 + 12 缕丝，绕斜轴滚动、
 *    几层剪切把壳「折」起来，10 秒一个循环；再按录屏拟合的逐帧光学密度校正（pair-density.png，120 帧）调浓淡。
 *    所有运动都在顶点着色器里算，粒子缓冲是静态的。
 *  · 码怎么藏进去：每个粒子的光学深度乘上它在屏幕上那一点的 M（不透明度 1 − (1 − a)^(增益·M)）。
 *    3D 的云在滚、码钉在屏幕平面上（慢慢转）：眼睛看是云的浓淡有点起伏，相机几帧一平均，滚动的结构就抹平了，码显出来。
 *    码平面的 y 朝下（和相机拍屏幕的行号同一手性），单位 = 云的半径
 *  · 登录：POST check.cuven.us/pair/open → 显示云 → /pair/wait 长轮询（快过期、手机还没看过就提前换一团）→ 批准了就回调。
 *    网页不要设备令牌（不发 want_device / device:true）
 */
(function () {
  'use strict';
  var EXT = 1.6;                 // 码场的范围：[-1.6, 1.6]²（云的半径 = 1）
  var SPEC = {"version":2,"cells":[[0.25322,-0.080733,0.05049],[0.251229,0.427684,0.05049],[0.230745,0.951894,0.05049],[0.23606,1.425281,0.05049],[0.241533,1.84068,0.05049],[0.273287,2.265773,0.05049],[0.252093,2.636563,0.05049],[0.260864,3.198149,0.05049],[0.238574,3.655192,0.05049],[0.244793,4.092163,0.05049],[0.261982,4.543046,0.05049],[0.245218,4.9593,0.05049],[0.270359,5.343711,0.05049],[0.27373,5.790119,0.05049],[0.443569,0.402384,0.056549],[0.44506,0.665578,0.056549],[0.416105,0.984208,0.056549],[0.422089,1.209142,0.056549],[0.422836,1.544247,0.056549],[0.451023,1.780221,0.056549],[0.416906,2.126199,0.056549],[0.444781,2.384458,0.056549],[0.419754,2.637653,0.056549],[0.42214,2.921977,0.056549],[0.451598,3.252525,0.056549],[0.43963,3.499846,0.056549],[0.456485,3.760034,0.056549],[0.445804,4.1132,0.056549],[0.455484,4.354697,0.056549],[0.462823,4.661027,0.056549],[0.433518,4.930833,0.056549],[0.437791,5.186374,0.056549],[0.422279,5.496114,0.056549],[0.450764,5.768473,0.056549],[0.425459,6.036287,0.056549],[0.449228,6.373848,0.056549],[0.615214,0.774417,0.058434],[0.604917,0.915188,0.058434],[0.597101,1.177014,0.058434],[0.596703,1.338701,0.058434],[0.634989,1.55853,0.058434],[0.607663,1.796588,0.058434],[0.637388,1.959481,0.058434],[0.620347,2.237488,0.058434],[0.601068,2.402828,0.058434],[0.606665,2.65327,0.058434],[0.614696,2.80719,0.058434],[0.63947,3.012438,0.058434],[0.627773,3.289867,0.058434],[0.619265,3.440769,0.058434],[0.621296,3.658928,0.058434],[0.598007,3.862691,0.058434],[0.618042,4.094627,0.058434],[0.6111,4.303898,0.058434],[0.63832,4.523497,0.058434],[0.62418,4.716717,0.058434],[0.624445,4.959159,0.058434],[0.642649,5.162723,0.058434],[0.642919,5.319186,0.058434],[0.607265,5.582809,0.058434],[0.634048,5.730284,0.058434],[0.601125,5.940558,0.058434],[0.635831,6.219714,0.058434],[0.634165,6.404116,0.058434],[0.619327,6.591992,0.058434],[0.595488,6.838695,0.058434],[0.769262,1.084385,0.052509],[0.786965,1.280756,0.052509],[0.781951,1.405834,0.052509],[0.780477,1.548476,0.052509],[0.766588,1.691533,0.052509],[0.786038,1.855846,0.052509],[0.780491,1.989517,0.052509],[0.802596,2.154996,0.052509],[0.789832,2.291084,0.052509],[0.794225,2.468119,0.052509],[0.800178,2.612711,0.052509],[0.778667,2.734637,0.052509],[0.768698,2.910009,0.052509],[0.794051,3.061189,0.052509],[0.759284,3.183024,0.052509],[0.777696,3.336014,0.052509],[0.79937,3.523495,0.052509],[0.77357,3.62691,0.052509],[0.789111,3.817835,0.052509],[0.779653,3.955363,0.052509],[0.75631,4.124873,0.052509],[0.80343,4.234301,0.052509],[0.790258,4.42421,0.052509],[0.770343,4.562213,0.052509],[0.777575,4.719145,0.052509],[0.780823,4.85459,0.052509],[0.77058,4.974157,0.052509],[0.802809,5.143094,0.052509],[0.79144,5.278557,0.052509],[0.803856,5.460406,0.052509],[0.786695,5.610307,0.052509],[0.778455,5.737485,0.052509],[0.796909,5.914486,0.052509],[0.795792,6.070909,0.052509],[0.801131,6.206327,0.052509],[0.759246,6.362737,0.052509],[0.758982,6.510901,0.052509],[0.790035,6.640798,0.052509],[0.792676,6.801384,0.052509],[0.790749,6.953689,0.052509],[0.755695,7.089683,0.052509],[0.770542,7.256099,0.052509],[0.911463,1.480252,0.050024],[0.901873,1.621077,0.050024],[0.935112,1.712452,0.050024],[0.934967,1.840322,0.050024],[0.919299,1.978065,0.050024],[0.91126,2.081842,0.050024],[0.90224,2.189754,0.050024],[0.941541,2.34326,0.050024],[0.932415,2.432535,0.050024],[0.933988,2.563968,0.050024],[0.923883,2.698475,0.050024],[0.917297,2.830737,0.050024],[0.925483,2.918324,0.050024],[0.913053,3.03199,0.050024],[0.920548,3.155245,0.050024],[0.922953,3.281955,0.050024],[0.901082,3.393301,0.050024],[0.921166,3.516313,0.050024],[0.928157,3.65346,0.050024],[0.897457,3.780814,0.050024],[0.944704,3.893376,0.050024],[0.91603,3.998325,0.050024],[0.909317,4.131241,0.050024],[0.915955,4.249543,0.050024],[0.928497,4.391995,0.050024],[0.91812,4.489645,0.050024],[0.940548,4.630128,0.050024],[0.942857,4.762184,0.050024],[0.921168,4.879855,0.050024],[0.898312,4.975081,0.050024],[0.919019,5.12379,0.050024],[0.910865,5.247451,0.050024],[0.899834,5.365966,0.050024],[0.901743,5.471755,0.050024],[0.917411,5.605253,0.050024],[0.937966,5.702161,0.050024],[0.916373,5.813444,0.050024],[0.938146,5.961821,0.050024],[0.904521,6.074522,0.050024],[0.931681,6.180347,0.050024],[0.909247,6.295208,0.050024],[0.92455,6.44862,0.050024],[0.920277,6.541297,0.050024],[0.897698,6.663139,0.050024],[0.898352,6.804255,0.050024],[0.918028,6.906094,0.050024],[0.901531,7.052079,0.050024],[0.90002,7.148828,0.050024],[0.940491,7.291516,0.050024],[0.930793,7.418656,0.050024],[0.903154,7.526643,0.050024],[0.919665,7.654804,0.050024]],"sigmaR":0.07,"pilotIdx":[3,11,19,27,35,43,51,59,67,75,83,91,99,107,115,123,131,139,147,155],"pilots":[1,1,-1,1,1,1,1,-1,1,1,-1,-1,-1,1,1,-1,1,-1,-1,1],"dataIdx":[0,1,2,4,5,6,7,8,9,10,12,13,14,15,16,17,18,20,21,22,23,24,25,26,28,29,30,31,32,33,34,36,37,38,39,40,41,42,44,45,46,47,48,49,50,52,53,54,55,56,57,58,60,61,62,63,64,65,66,68,69,70,71,72,73,74,76,77,78,79,80,81,82,84,85,86,87,88,89,90,92,93,94,95,96,97,98,100,101,102,103,104,105,106,108,109,110,111,112,113,114,116,117,118,119,120,121,122,124,125,126,127,128,129,130,132,133,134,135,136,137,138,140,141,142,143,144,145,146,148,149,150,151,152,153,154,156,157,158,159],"interleave":[0,53,106,19,72,125,38,91,4,57,110,23,76,129,42,95,8,61,114,27,80,133,46,99,12,65,118,31,84,137,50,103,16,69,122,35,88,1,54,107,20,73,126,39,92,5,58,111,24,77,130,43,96,9,62,115,28,81,134,47,100,13,66,119,32,85,138,51,104,17,70,123,36,89,2,55,108,21,74,127,40,93,6,59,112,25,78,131,44,97,10,63,116,29,82,135,48,101,14,67,120,33,86,139,52,105,18,71,124,37,90,3,56,109,22,75,128,41,94,7,60,113,26,79,132,45,98,11,64,117,30,83,136,49,102,15,68,121,34,87],"warp":[[0.06,2.3,3.1,0.7],[0.045,-3.7,1.9,2.1],[0.03,5.3,-4.1,4.4]],"alpha":0.25,"tau":0.3,"beta":0.6,"w":0.1,"e0":0.55,"codeGrid":192,"codeScale":3.0,"codeSpin":0.05,"conv":{"k":7,"g1":121,"g2":91},"decode":{"cam":256,"pr":24,"pa":192,"rLo":0.1,"rHi":1.08,"th":0.06,"kRms":1.856791,"targetScale":0.35,"bgQ":0.2,"bgMargin":0.04,"rays":24,"rayN":64,"rayT0":0.2,"rayT1":1.8,"edgeK":1.014381,"lsReg":0.001,"avgFrames":16}};

  /* ── 编码 ── */
  function crc8(bytes) {
    var c = 0;
    for (var i = 0; i < bytes.length; i++) {
      c ^= bytes[i];
      for (var k = 0; k < 8; k++) c = (c & 0x80) ? ((c << 1) ^ 0x07) & 0xFF : (c << 1) & 0xFF;
    }
    return c;
  }
  function parity(x) { var n = 0; while (x) { n ^= x & 1; x >>>= 1; } return n; }
  function payloadBits(id, secret) {
    var b = [(id >>> 16) & 255, (id >>> 8) & 255, id & 255, (secret >>> 24) & 255, (secret >>> 16) & 255, (secret >>> 8) & 255, secret & 255];
    b.push(crc8(b));
    var out = [];
    for (var i = 0; i < 64; i++) out.push((b[i >> 3] >> (7 - (i & 7))) & 1);
    return out;
  }
  function convEncode(bits) {
    var st = 0, out = [], all = bits.concat([0, 0, 0, 0, 0, 0]);
    for (var i = 0; i < all.length; i++) {
      st = ((st << 1) | all[i]) & 0x7F;
      out.push(parity(st & SPEC.conv.g1), parity(st & SPEC.conv.g2));
    }
    return out;
  }
  /** 160 个格子的正负（±1） */
  function cellSigns(id, secret) {
    var coded = convEncode(payloadBits(id >>> 0, secret >>> 0));
    var b = new Float32Array(SPEC.cells.length);
    for (var i = 0; i < SPEC.pilotIdx.length; i++) b[SPEC.pilotIdx[i]] = SPEC.pilots[i];
    for (var k = 0; k < coded.length; k++) b[SPEC.dataIdx[SPEC.interleave[k]]] = coded[k] ? 1 : -1;
    return b;
  }

  /* ── 码场 ── */
  function wrap(a) { a = (a + Math.PI) % (2 * Math.PI); if (a < 0) a += 2 * Math.PI; return a - Math.PI; }
  function warp(x, y) {
    var dx = 0, dy = 0;
    for (var i = 0; i < SPEC.warp.length; i++) {
      var w = SPEC.warp[i];
      dx += w[0] * Math.sin(w[1] * x + w[2] * y + w[3]);
      dy += w[0] * Math.cos(w[2] * x - w[1] * y + w[3] * 1.3);
    }
    return [x + dx, y + dy];
  }
  function fieldAt(b, x, y) {
    var q = warp(x, y), r = Math.hypot(q[0], q[1]), th = Math.atan2(q[1], q[0]);
    var D = 0, E = 0, s2r = 2 * SPEC.sigmaR * SPEC.sigmaR;
    for (var i = 0; i < SPEC.cells.length; i++) {
      var c = SPEC.cells[i], dr = r - c[0], dt = c[0] * wrap(th - c[1]);
      var g = Math.exp(-(dr * dr) / s2r - (dt * dt) / (2 * c[2] * c[2]));
      D += b[i] * g; E += g;
    }
    return [D, E];
  }
  /** 调制 M（光学深度的倍数）：正的一侧浓一点，零线上浓一些（只在有格子的地方） */
  function modulation(D, E) {
    var gate = Math.min(1, Math.max(0, E / SPEC.e0));
    return (1 + SPEC.alpha * Math.tanh(D / SPEC.tau)) * (1 + SPEC.beta * gate * gate * Math.exp(-(D / SPEC.w) * (D / SPEC.w)));
  }
  /** G×G 的调制网格（覆盖 [-EXT, EXT]²，按像素中心取样；第 0 行是 y 最小的一行）。全量参考版：测试、对照用 */
  function modulationGrid(b, G) {
    var m = new Float32Array(G * G);
    for (var j = 0; j < G; j++) for (var i = 0; i < G; i++) {
      var de = fieldAt(b, -EXT + (i + 0.5) * 2 * EXT / G, -EXT + (j + 0.5) * 2 * EXT / G);
      m[j * G + i] = modulation(de[0], de[1]);
    }
    return m;
  }

  /* ── 码场的快速通道 ──
     码场里只有格子的正负 b 跟着码变：扭曲、每个格子落在每个像素上的高斯权重 g、覆盖度 E 都和码无关。
     所以一次算好一张稀疏表（每像素一个 E，外加一串（格子号, g），g > 1e-7 才记，平均六个左右，CSR 存），
     换码时只算 D = Σ b·g 再调制：一团码几毫秒（全量要 192² 个像素 × 160 次 exp，一百多毫秒）。
     结果和 modulationGrid 逐字节一致（四舍五入正好卡在边上的像素最多差 1/255） */
  var BASIS_EPS = 1e-7;
  var BASIS = null, basisWait = null;          // 算好的表（只算码网格那一种边长）/ 正在后台算
  function basisNew(G) { return { G: G, E: new Float64Array(G * G), start: new Int32Array(G * G + 1), idx: [], g: [] }; }
  /** 算第 j0 … j1−1 行，接在 o 后面（和 fieldAt 同一个式子、同一个求和顺序，E 一位不差） */
  function basisRows(o, j0, j1) {
    var G = o.G, s2r = 2 * SPEC.sigmaR * SPEC.sigmaR, cells = SPEC.cells, n = cells.length;
    for (var j = j0; j < j1; j++) for (var i = 0; i < G; i++) {
      var q = warp(-EXT + (i + 0.5) * 2 * EXT / G, -EXT + (j + 0.5) * 2 * EXT / G);
      var r = Math.hypot(q[0], q[1]), th = Math.atan2(q[1], q[0]), E = 0;
      for (var k = 0; k < n; k++) {
        var c = cells[k], dr = r - c[0], dt = c[0] * wrap(th - c[1]);
        var g = Math.exp(-(dr * dr) / s2r - (dt * dt) / (2 * c[2] * c[2]));
        E += g;
        if (g > BASIS_EPS) { o.idx.push(k); o.g.push(g); }
      }
      o.E[j * G + i] = E;
      o.start[j * G + i + 1] = o.idx.length;
    }
  }
  function basisPack(o) { return { G: o.G, E: o.E, start: o.start, idx: new Uint8Array(o.idx), g: new Float32Array(o.g) }; }
  function basisOk(B, G) {
    return !!B && B.G === G && B.E && B.E.length === G * G && B.start && B.start.length === G * G + 1 &&
      B.idx && B.g && B.idx.length === B.g.length && B.start[G * G] === B.g.length;
  }
  /** 当场算（测试、没有后台的环境用）；算过就直接给 */
  function basisSync(G) {
    G = G || SPEC.codeGrid;
    if (BASIS && BASIS.G === G) return BASIS;
    var o = basisNew(G);
    basisRows(o, 0, G);
    var B = basisPack(o);
    if (G === SPEC.codeGrid) BASIS = B;
    return B;
  }
  /** 后台算：Worker 里算（不占主线程），开不了 Worker 就在主线程分片算（每片 ≤ 8 毫秒，让出来给动画）。回 Promise */
  function prepare() {
    var G = SPEC.codeGrid;
    if (BASIS && BASIS.G === G) return Promise.resolve(BASIS);
    if (basisWait) return basisWait;
    basisWait = basisInWorker(G).catch(function () { return basisChunked(G); }).then(function (B) {
      if (!BASIS || BASIS.G !== G) BASIS = B;
      basisWait = null;
      return BASIS;
    }, function (e) { basisWait = null; throw e; });
    return basisWait;
  }
  function basisInWorker(G) {
    return new Promise(function (ok, bad) {
      if (typeof Worker === 'undefined' || typeof Blob === 'undefined' || typeof URL === 'undefined' || !URL.createObjectURL) { bad(new Error('no worker')); return; }
      var src = "'use strict';var SPEC=" + JSON.stringify(SPEC) + ',EXT=' + EXT + ',BASIS_EPS=' + BASIS_EPS + ';\n' +
        [wrap, warp, basisNew, basisRows, basisPack].join('\n') +
        '\nonmessage=function(e){var o=basisNew(e.data);basisRows(o,0,o.G);var B=basisPack(o);' +
        'postMessage(B,[B.E.buffer,B.start.buffer,B.idx.buffer,B.g.buffer]);};';
      var url = '', w = null, timer = 0;
      var end = function () { clearTimeout(timer); try { w && w.terminate(); } catch (_) {} try { URL.revokeObjectURL(url); } catch (_) {} };
      try {
        url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
        w = new Worker(url);
      } catch (e) { end(); bad(e); return; }
      timer = setTimeout(function () { end(); bad(new Error('timeout')); }, 10000);
      w.onmessage = function (e) { end(); if (basisOk(e.data, G)) ok(e.data); else bad(new Error('bad basis')); };
      w.onerror = function (e) { end(); if (e && e.preventDefault) e.preventDefault(); bad(new Error('worker')); };
      w.postMessage(G);
    });
  }
  function basisChunked(G) {
    return new Promise(function (ok) {
      if (typeof setTimeout === 'undefined') { ok(basisSync(G)); return; }
      var o = basisNew(G), j = 0;
      var step = function () {
        var t0 = Date.now();
        while (j < G && (j === 0 || Date.now() - t0 < 8)) { basisRows(o, j, j + 1); j++; }
        if (j < G) setTimeout(step, 0); else ok(basisPack(o));
      };
      setTimeout(step, 0);
    });
  }
  /** 快速版的调制网格（输出同 modulationGrid） */
  function modulationGridFast(b, G) {
    var B = basisSync(G), m = new Float32Array(G * G), E = B.E, st = B.start, idx = B.idx, g = B.g;
    for (var p = 0, n = G * G; p < n; p++) {
      var D = 0;
      for (var k = st[p], e = st[p + 1]; k < e; k++) D += b[idx[k]] * g[k];
      m[p] = modulation(D, E[p]);
    }
    return m;
  }
  /** 调制网格 → 8 位码纹理（存 M / codeScale） */
  function gridBytes(m) {
    var px = new Uint8Array(m.length);
    for (var i = 0; i < m.length; i++) px[i] = Math.max(0, Math.min(255, Math.round(m[i] / SPEC.codeScale * 255)));
    return px;
  }
  /** 一团码的纹理：表算好了走快速通道，没好就全量算 */
  function codeBytes(id, secret) {
    var G = SPEC.codeGrid, b = cellSigns(id, secret);
    return gridBytes(BASIS && BASIS.G === G ? modulationGridFast(b, G) : modulationGrid(b, G));
  }

  /* ── 粒子云（WebGL1）── */
  var LOOP_SECONDS = 10, TAU = Math.PI * 2;
  var BODY_POINTS = 53000, HALO_POINTS = 16500, WISPS = 12, POINTS_PER_WISP = 1500, FLOATS_PER_POINT = 8;
  var DENSITY_TILE = 112, DENSITY_COLUMNS = 12, DENSITY_FRAMES = 120, DENSITY_STRIDE = DENSITY_TILE + 2;
  var DENSITY_WIDTH = DENSITY_STRIDE * DENSITY_COLUMNS, DENSITY_HEIGHT = DENSITY_STRIDE * (DENSITY_FRAMES / DENSITY_COLUMNS);
  var CODE_SCALE = SPEC.codeScale;   // 码纹理（8 位）存 M / codeScale
  var CODE_SPIN = SPEC.codeSpin;     // 码平面每秒转多少弧度
  var CODE_GRID = SPEC.codeGrid;     // 调制网格边长

  var VS = [
    'precision highp float;',
    'attribute vec4 a_position;',
    'attribute vec4 a_detail;',
    'uniform vec2 u_scale;',
    'uniform vec2 u_center;',
    'uniform float u_spriteScale;',
    'uniform float u_phase;',
    'uniform float u_gathering;',
    'uniform vec2 u_codeRot;',
    'uniform float u_codeExt;',
    'varying mediump vec4 v_color;',
    'varying mediump vec2 v_cloudUv;',
    'varying mediump vec2 v_codeUv;',
    'mat2 turn(float angle) { float c = cos(angle), s = sin(angle); return mat2(c, s, -s, c); }',
    'vec3 rollCloud(vec3 point, float phase) {',
    '  vec3 axis = normalize(vec3(0.17, 0.98, 0.09));',
    '  float latitude = dot(point, axis);',
    '  float slip = 0.16 * latitude + (0.075 + 0.14 * latitude * latitude) * sin(phase * 2.0 + 2.5 * latitude);',
    '  float angle = phase + slip + 0.105 * sin(2.0 * phase - 0.38);',
    '  float c = cos(angle);',
    '  vec3 rolled = point * c + cross(axis, point) * sin(angle) + axis * latitude * (1.0 - c);',
    '  rolled.xy = turn(0.085 * sin(phase + 0.8) + 0.036 * sin(3.0 * phase)) * rolled.xy;',
    '  return rolled;',
    '}',
    'vec3 flow(vec3 p, float phase, float strength) {',
    '  vec3 drift = sin(phase * vec3(2.0, -1.0, 2.0) + vec3(0.4, 1.9, 4.3));',
    '  vec3 q = p + strength * 0.109 * sin(p.yzx * vec3(7.0, 6.7, 6.2) + p.zxy * vec3(3.2, 3.7, 2.8) + phase * vec3(2.0, -1.0, 2.0) + vec3(2.0, 0.5, 4.4) + drift);',
    '  q += strength * 0.054 * sin(q.zxy * vec3(11.0, 12.0, 11.5) + q.yzx * 4.2 + phase * vec3(-2.0, 3.0, -3.0) + vec3(1.0, 5.0, 2.1));',
    '  q += strength * 0.024 * sin(q.yzx * 21.0 + q.zxy * 8.0 + phase * vec3(3.0, 3.0, -3.0));',
    '  return q;',
    '}',
    'vec3 wispPosition(float phase, float variation, out float taper) {',
    '  float angle = a_position.x, elevation = a_position.y, along = a_position.z, idPhase = a_position.w;',
    '  float seed = a_detail.x, spread = a_detail.y, depthSpread = a_detail.z;',
    '  angle += 0.14 * sin(phase * 2.0 + idPhase) + 0.06 * sin(phase * 3.0 - idPhase);',
    '  elevation += 0.12 * sin(phase * 2.0 - idPhase) + 0.055 * cos(phase * 3.0 + 1.7 * idPhase);',
    '  float ce = cos(elevation);',
    '  vec3 normal = vec3(ce * cos(angle), ce * sin(angle), sin(elevation));',
    '  vec3 tangent = vec3(-sin(angle), cos(angle), 0.0);',
    '  vec3 bitangent = cross(normal, tangent);',
    '  float tilt = 0.75 * sin(idPhase * 1.7) + 0.32 * sin(phase * 2.0 + idPhase);',
    '  vec3 across = tangent * cos(tilt) + bitangent * sin(tilt);',
    '  vec3 sideways = cross(normal, across);',
    '  float len = 0.46 + 0.14 * sin(idPhase) + 0.07 * sin(phase * 3.0 + idPhase);',
    '  float arc = len * along + 0.026 * sin(along * 6.0 - phase * 2.0 + idPhase);',
    '  float curl = 0.19 * (along * along - 0.25) + 0.083 * sin(along * 3.2 + phase * 3.0 + idPhase) + 0.033 * sin(along * 8.0 - phase * 2.0 + idPhase);',
    '  float gathering = 0.5 + 0.5 * sin(phase * 3.0 + idPhase + 0.53 * along);',
    '  gathering = 0.25 + 0.75 * gathering * gathering;',
    '  float width = (0.009 + 0.022 * seed) * (0.85 + 0.47 * along * along) + (1.0 - variation * gathering) * 0.046;',
    '  taper = (1.0 - smoothstep(0.49, 1.0, abs(along))) * gathering;',
    '  float radius = 0.91 + 0.073 * sin(idPhase * 2.4 + phase * 2.0) + 0.056 * sin(along * 4.5 + idPhase);',
    '  return (radius + depthSpread * width * 0.86) * (normal * cos(arc) + across * sin(arc)) + sideways * (curl + spread * width);',
    '}',
    'void main() {',
    '  float phase = u_phase, variation = u_gathering, kind = a_detail.w, seed = a_detail.x, taper = 1.0;',
    '  vec3 point; float strength;',
    '  if (kind > 1.5) { point = wispPosition(phase, variation, taper); strength = 0.84; }',
    '  else {',
    '    point = a_position.xyz;',
    '    float wave = sin(dot(point, vec3(4.4, -3.5, 2.7)) + phase * 2.0);',
    '    float lobe = sin(dot(point, vec3(2.1, 4.6, -3.7)) - phase * 3.0);',
    '    point *= 1.0 + 0.058 * wave + 0.042 * lobe;',
    '    strength = kind < 0.5 ? 1.0 : 0.51;',
    '  }',
    '  point = flow(point, phase, strength * (0.62 + variation * 0.43));',
    '  vec3 pockets = sin(point.yzx * 7.3 + point.zxy * 5.1 + phase * vec3(1.0, -2.0, 1.0));',
    '  float shade = 0.5 + dot(pockets, vec3(0.1667));',
    '  point = rollCloud(point, phase);',
    '  point *= 1.0 + 0.018 * sin(phase * 3.0) + 0.011 * cos(phase * 5.0);',
    '  float perspective = 1.0 / (1.0 - 0.14 * point.z);',
    '  vec2 projected = point.xy * perspective;',
    '  gl_Position = vec4(projected * u_scale + u_center, 0.0, 1.0);',
    '  v_cloudUv = vec2(projected.x, -projected.y) / 2.90 + 0.5;',
    // 码平面：屏幕上的位置（y 朝下）转一个角度
    '  vec2 cp = vec2(projected.x, -projected.y);',
    '  v_codeUv = vec2(u_codeRot.x * cp.x - u_codeRot.y * cp.y, u_codeRot.y * cp.x + u_codeRot.x * cp.y) / (2.0 * u_codeExt) + 0.5;',
    '  float size = 1.87 + 1.70 * seed * seed + 0.50 * seed;',
    '  float opacity = 0.32 + 0.19 * (1.0 - seed);',
    '  float grain = kind > 1.5 ? fract(a_position.w * 0.618 + seed * 17.181) : a_detail.z;',
    '  vec3 blue = mix(vec3(0.096, 0.470, 0.722), vec3(0.124, 0.673, 0.912), grain);',
    '  opacity *= (0.57 + 0.72 * shade) * (0.91 + 0.25 * point.z);',
    '  if (kind > 1.5) {',
    '    blue = mix(vec3(0.042, 0.522, 0.828), vec3(0.108, 0.648, 0.924), grain);',
    '    opacity *= (0.22 + 2.40 * taper) * (0.21 + 0.79 * variation);',
    '    opacity *= 0.63 + 0.37 * smoothstep(-0.75, 0.36, point.z);',
    '    size *= 0.86;',
    '  } else if (kind > 0.5) {',
    '    blue = mix(vec3(0.21, 0.45, 0.59), vec3(0.29, 0.63, 0.74), grain);',
    '    float haloFade = 1.0 - smoothstep(1.14, 1.64, length(point));',
    '    opacity *= (0.40 + 0.45 * a_detail.y) * haloFade;',
    '    size *= 0.82;',
    '  } else {',
    '    opacity *= 1.16 * a_detail.y;',
    '  }',
    '  float pixelSize = size * u_spriteScale * perspective;',
    '  opacity *= min(1.0, pixelSize * pixelSize * 0.69);',
    '  gl_PointSize = max(1.20, pixelSize);',
    '  v_color = vec4(blue, min(opacity, 0.95));',
    '}'
  ].join('\n');
  var FS = [
    '#ifdef GL_FRAGMENT_PRECISION_HIGH',
    'precision highp float;',
    '#else',
    'precision mediump float;',
    '#endif',
    'uniform sampler2D u_density;',
    'uniform sampler2D u_code;',
    'uniform vec2 u_densityScale;',
    'uniform vec4 u_densityOrigins;',
    'uniform float u_densityBlend;',
    'uniform float u_codeScale;',
    'varying mediump vec4 v_color;',
    'varying mediump vec2 v_cloudUv;',
    'varying mediump vec2 v_codeUv;',
    'void main() {',
    '  vec2 uv = gl_PointCoord - 0.5;',
    '  float coverage = 1.0 - smoothstep(0.08, 0.5, length(uv));',
    '  vec2 offset = clamp(v_cloudUv, 0.0, 1.0) * u_densityScale;',
    '  float before = texture2D(u_density, u_densityOrigins.xy + offset).r;',
    '  float after = texture2D(u_density, u_densityOrigins.zw + offset).r;',
    '  float correction = (mix(before, after, u_densityBlend) * 255.0 - 128.0) / 44.0;',
    // 光学深度 × M：码就这一处
    '  float gain = exp2(0.90 * correction) * texture2D(u_code, clamp(v_codeUv, 0.0, 1.0)).r * u_codeScale;',
    '  float opacity = 1.0 - pow(1.0 - v_color.a * coverage, gain);',
    '  gl_FragColor = vec4(v_color.rgb, opacity);',
    '}'
  ].join('\n');

  function buildParticles() {
    var state = 0x7a32f9d1;
    var random = function () { state ^= state << 13; state ^= state >>> 17; state ^= state << 5; return (state >>> 0) / 4294967296; };
    var bell = function () { return (random() + random() + random() + random() - 2) * 1.73; };
    var p = new Float32Array((BODY_POINTS + HALO_POINTS + WISPS * POINTS_PER_WISP) * FLOATS_PER_POINT), o = 0, i;
    for (i = 0; i < BODY_POINTS + HALO_POINTS; i++) {
      var halo = i >= BODY_POINTS, lon = random() * TAU, z = random() * 2 - 1, eq = Math.sqrt(1 - z * z), isShell = random() < 0.82;
      var radius = halo ? 1.07 + 0.57 * Math.pow(random(), 1.85) : isShell ? 0.937 + 0.101 * bell() : 0.96 * Math.cbrt(random());
      p.set([Math.cos(lon) * eq * radius, Math.sin(lon) * eq * radius, z * radius, 0, random(), halo ? random() : 0.63 + 0.37 * random(), random(), halo ? 1 : 0], o);
      o += FLOATS_PER_POINT;
    }
    for (var s = 0; s < WISPS; s++) {
      var lon2 = s * 2.399963 + 0.55 * random();
      var elev = Math.asin((s + 0.5) / WISPS * 1.83 - 0.915) + 0.15 * bell();
      var idPhase = s * 1.954 + 0.5 * random();
      for (i = 0; i < POINTS_PER_WISP; i++) {
        var along = random() * 2 - 1, scatter = random() < 0.22 ? 2.7 : 1;
        p.set([lon2, elev, along, idPhase, random(), bell() * scatter, bell() * scatter, 2], o);
        o += FLOATS_PER_POINT;
      }
    }
    return p;
  }
  // 浓淡在一个循环里的变化（照录屏拟合）
  function gatheringCycle(ph) {
    return 0.649 + 0.031 * Math.cos(ph) - 0.125 * Math.sin(ph) + 0.036 * Math.cos(2 * ph) + 0.109 * Math.sin(2 * ph)
      - 0.222 * Math.cos(3 * ph) - 0.036 * Math.sin(3 * ph) - 0.047 * Math.cos(4 * ph) + 0.013 * Math.sin(4 * ph);
  }
  function compile(gl, type, src) {
    var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }

  /**
   * new Cloud(canvas, { radius（占短边的比例，默认 0.30）, atlas（密度校正图的地址）, preserve, pixelRatio })
   * setCode(id, secret)；clear()；start()；stop()；drawAt(秒)（自检 / 截图用）。没有 WebGL 时 ok = false（调用方改用账户密码）
   */
  function Cloud(canvas, opts) {
    opts = opts || {};
    this.canvas = canvas;
    this.opts = opts;
    this.raf = 0; this.t0 = 0; this.codeT0 = 0;
    var gl = this.gl = canvas.getContext('webgl', { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false,
      preserveDrawingBuffer: !!opts.preserve, powerPreference: 'low-power' });
    this.ok = !!gl;
    if (!this.ok) return;
    try {
      var prog = gl.createProgram();
      gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VS));
      gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FS));
      gl.linkProgram(prog);
      if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
      gl.useProgram(prog);
      this.prog = prog;
    } catch (e) { this.ok = false; if (window.console) console.error(e); return; }
    var particles = buildParticles();
    this.count = particles.length / FLOATS_PER_POINT;
    gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
    gl.bufferData(gl.ARRAY_BUFFER, particles, gl.STATIC_DRAW);
    var stride = FLOATS_PER_POINT * 4;
    [['a_position', 0], ['a_detail', 4]].forEach(function (a) {
      var loc = gl.getAttribLocation(prog, a[0]);
      gl.enableVertexAttribArray(loc);
      gl.vertexAttribPointer(loc, 4, gl.FLOAT, false, stride, a[1] * 4);
    });
    var U = this.u = {};
    ['u_scale', 'u_center', 'u_spriteScale', 'u_phase', 'u_gathering', 'u_codeRot', 'u_codeExt', 'u_density', 'u_code',
      'u_densityScale', 'u_densityOrigins', 'u_densityBlend', 'u_codeScale'].forEach(function (n) { U[n] = gl.getUniformLocation(prog, n); });
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    var tex = function (unit, w, h, data) {
      var t = gl.createTexture();
      gl.activeTexture(gl.TEXTURE0 + unit); gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, w, h, 0, gl.LUMINANCE, gl.UNSIGNED_BYTE, data);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      return t;
    };
    // 密度校正图（120 帧拼成一张）：没载入前用中性的 128（不校正）
    this.densityTex = tex(0, 1, 1, new Uint8Array([128]));
    this.atlasReady = false;
    // 码：没设之前 M = 1（85 / 255 × 3 = 1）
    this.codeTex = tex(1, 1, 1, new Uint8Array([85]));
    gl.uniform1i(U.u_density, 0);
    gl.uniform1i(U.u_code, 1);
    gl.uniform2f(U.u_densityScale, 0, 0);
    gl.uniform4f(U.u_densityOrigins, 0.5, 0.5, 0.5, 0.5);
    gl.uniform1f(U.u_densityBlend, 0);
    gl.uniform1f(U.u_codeScale, CODE_SCALE);
    gl.uniform1f(U.u_codeExt, EXT);
    gl.uniform2f(U.u_codeRot, 1, 0);
    gl.enable(gl.BLEND);
    // 画在透明画布上（预乘）：颜色按 over 混合，透明度累积 —— 浅色、深色页面上都对
    gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.clearColor(0, 0, 0, 0);
    var self = this, img = new Image();
    img.onload = function () {
      if (img.naturalWidth !== DENSITY_WIDTH || img.naturalHeight !== DENSITY_HEIGHT || gl.isContextLost()) return;
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, self.densityTex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, gl.LUMINANCE, gl.UNSIGNED_BYTE, img);
      gl.uniform2f(U.u_densityScale, DENSITY_TILE / DENSITY_WIDTH, DENSITY_TILE / DENSITY_HEIGHT);
      self.atlasReady = true;
      if (self.onAtlas) self.onAtlas();
    };
    img.src = opts.atlas || '/pair-density.png';
  }
  /** 换一团码：算调制网格（codeGrid²，稀疏表好了走快速通道）→ 码纹理 */
  Cloud.prototype.setCode = function (id, secret) {
    if (!this.ok) return;
    var G = CODE_GRID, px = codeBytes(id, secret), gl = this.gl;
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, this.codeTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, G, G, 0, gl.LUMINANCE, gl.UNSIGNED_BYTE, px);
    this.codeT0 = performance.now();
    this.coded = true;
  };
  /** 不画了（码作废、暂停）：画布立刻清空，等下一次 setCode */
  Cloud.prototype.clear = function () {
    this.coded = false;
    if (!this.ok || this.gl.isContextLost()) return;
    this.gl.clear(this.gl.COLOR_BUFFER_BIT);
  };
  /** 画 t 秒时的一帧（动画的时钟、码平面转的角度都用它） */
  Cloud.prototype.drawAt = function (t, codeT) {
    var gl = this.gl, c = this.canvas, o = this.opts;
    if (gl.isContextLost()) return;
    var cw = c.clientWidth || c.width, ch = c.clientHeight || c.height;
    var dpr = o.pixelRatio || Math.min(Math.max(window.devicePixelRatio || 1, 1.5), 2.5);
    var w = Math.max(1, Math.round(cw * dpr)), h = Math.max(1, Math.round(ch * dpr));
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
    var radius = Math.min(cw, ch) * (o.radius || 0.30), U = this.u;
    gl.viewport(0, 0, w, h);
    gl.uniform2f(U.u_scale, radius * 2 / cw, radius * 2 / ch);
    gl.uniform2f(U.u_center, 0, 0);
    gl.uniform1f(U.u_spriteScale, (radius / 186.5) * dpr);
    var progress = (t / LOOP_SECONDS) % 1, phase = progress * TAU;
    gl.uniform1f(U.u_phase, phase);
    gl.uniform1f(U.u_gathering, gatheringCycle(phase));
    if (this.atlasReady) {
      var f = progress * DENSITY_FRAMES, a = Math.floor(f) % DENSITY_FRAMES, b = (a + 1) % DENSITY_FRAMES;
      var left = function (i) { return ((i % DENSITY_COLUMNS) * DENSITY_STRIDE + 1) / DENSITY_WIDTH; };
      var top = function (i) { return (Math.floor(i / DENSITY_COLUMNS) * DENSITY_STRIDE + 1) / DENSITY_HEIGHT; };
      gl.uniform4f(U.u_densityOrigins, left(a), top(a), left(b), top(b));
      gl.uniform1f(U.u_densityBlend, f - Math.floor(f));
    }
    var ang = (codeT === undefined ? t : codeT) * CODE_SPIN;
    gl.uniform2f(U.u_codeRot, Math.cos(ang), Math.sin(ang));
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.drawArrays(gl.POINTS, 0, this.count);
  };
  Cloud.prototype.start = function () {
    if (!this.ok || this.raf) return;
    var self = this;
    if (!this.t0) this.t0 = performance.now();
    var loop = function (now) {
      self.raf = requestAnimationFrame(loop);
      if (self.coded) self.drawAt((now - self.t0) / 1000, (now - self.codeT0) / 1000);
    };
    this.raf = requestAnimationFrame(loop);
  };
  Cloud.prototype.stop = function () { if (this.raf) cancelAnimationFrame(this.raf); this.raf = 0; };

  /* ── 登录：开一团云 → 等批准（快过期就提前换一团） ── */
  var ROTATE_LEAD = 8000;               // 离过期不到 8 秒、手机还没看过（peek）：先开下一团换上，旧的关掉
  var WAIT_MS = 30000, CALL_MS = 15000;  // 客户端超时：长轮询（服务端最多压 20 秒，再加读写）/ 其他请求
  var HIDE_GRACE = 3000;                 // 标签页切到后台这么久才暂停（切走一下马上回来的不算）
  var GEN = 0;                           // 第几次 login()：只有最新的一次能登录，旧的看到自己过时了就收摊
  var noop = function () {};
  function deviceName() {
    var ua = navigator.userAgent, os = /iPhone/.test(ua) ? 'iPhone' : /iPad/.test(ua) ? 'iPad' : /Mac/.test(ua) ? 'Mac' : /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : '电脑';
    var br = /Edg\//.test(ua) ? 'Edge' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox' : /Safari\//.test(ua) ? 'Safari' : '浏览器';
    return os + ' · ' + br;
  }
  /**
   * POST 一个 JSON，回 JSON（另带 _http = 状态码、_at = 收到的时刻）。ms：超时（AbortController，没有就赛跑）；
   * keep：页面关了也要发出去（keepalive，不设超时）。content-type 用 text/plain：简单请求，不先发 OPTIONS 预检
   * （账号中心照 JSON 解析，不看 content-type）
   */
  function post(api, path, body, ms, keep) {
    var init = { method: 'POST', headers: { 'content-type': 'text/plain' }, body: JSON.stringify(body || {}) };
    var ac = !keep && ms && typeof AbortController !== 'undefined' ? new AbortController() : null, timer = 0;
    if (keep) init.keepalive = true;
    if (ac) init.signal = ac.signal;
    var req = fetch(api + path, init).then(function (r) {
      return r.json().catch(function () { return null; }).then(function (j) {
        j = j && typeof j === 'object' ? j : {};
        j._http = r.status; j._at = Date.now();
        return j;
      });
    });
    if (!ms || keep) return req;
    var cut = new Promise(function (_, bad) { timer = setTimeout(function () { if (ac) ac.abort(); bad(new Error('timeout')); }, ms); });
    return Promise.race([req, cut]).then(function (j) { clearTimeout(timer); return j; }, function (e) { clearTimeout(timer); throw e; });
  }
  /** 刚开出来的一团：记下服务端和本机的钟差（exp 是服务端的钟），之后按本机时钟算还剩多久 */
  function adopt(p) {
    var ttl = (Number(p.ttl) > 0 ? Number(p.ttl) : 120) * 1000, at = Number(p._at) || Date.now();
    if (Number(p.exp) > 0) { p.exp = Number(p.exp); p.skew = p.exp - ttl - at; }
    else { p.exp = at + ttl; p.skew = 0; }
    p.peeked = false;
    return p;
  }
  function msLeft(p) { return p.exp - p.skew - Date.now(); }
  // 一块画布一团云：再进来接着用（着色器、粒子缓冲不重建，也不漏显存），上一团码先清掉
  function cloudFor(canvas, atlas, gen) {
    var c = canvas.__cuvenCloud || (canvas.__cuvenCloud = new Cloud(canvas, { atlas: atlas }));
    c.owner = gen;
    if (c.ok) { c.stop(); c.clear(); }
    return c;
  }
  /**
   * CuvenPair.login({ api, canvas, atlas, opened, onStatus(text), onApproved(r) })
   *   opened：页面先发出去的 /pair/open（Promise，回包同 open）：给了就不再自己开第一团（pair.js 下载、建 WebGL 和它同时进行）
   *   r = { username, email, code（识别代码 c1.…，5 分钟） }；返回 { cloud, stop() }
   *   wait 回 open / approved 以外的（过期、作废、取消、用过、找不到）：旧码立刻不画，再开一团；
   *   快过期、手机还没看过：提前开下一团换上，旧的关掉（关之前那一刻刚好被批准的照样登录）。
   *   标签页在后台：关掉手上这一团、不再轮询，回到前台再开；页面关掉（pagehide）用 keepalive 关掉。
   *   画不了粒子云：不配对，只报一句说明
   */
  function login(o) {
    var api = (o.api || 'https://check.cuven.us').replace(/\/+$/, '');
    var gen = ++GEN, dead = false, paused = false, cur = null, seq = 0, note = '';
    var retryT = 0, hideT = 0, expT = 0;
    var doc = typeof document !== 'undefined' ? document : null;
    var call = function (path, body, ms, keep) { return post(api, path, body, ms, keep); };
    var cancel = function (p, keep) { return call('/pair/cancel', { id: p.id, poll: p.poll }, CALL_MS, keep).catch(noop); };
    // 开出来却用不上的一团（过时了、暂停了、画不了）：关掉
    var drop = function (pr) { Promise.resolve(pr).then(function (p) { if (p && p.ok && p.id) cancel(p); }, noop); };
    var status = function (t) { if (alive() && o.onStatus) o.onStatus(t); };

    // 网络先走：页面给的 / 自己开的第一团，和下面建 WebGL、后台算稀疏表同时进行
    var first = o.opened ? Promise.resolve(o.opened) : doc && doc.hidden ? null : call('/pair/open', { device: deviceName() }, CALL_MS);
    prepare().catch(noop);
    var cloud = o.canvas ? cloudFor(o.canvas, o.atlas, gen) : null;
    if (cloud && !cloud.ok) {
      // 画不了粒子云：开出来也没人扫得到，不配对；说明文字留着，先开的那一团关掉
      dead = true; drop(first);
      if (o.onStatus) o.onStatus('这个浏览器画不了粒子云：请使用账户密码登录');
      return { cloud: cloud, stop: noop };
    }

    function alive() {
      if (dead) return false;
      if (gen !== GEN) { stop(); return false; }          // 有更新的一次 login()：这一次作废
      return true;
    }
    function open() {
      clearTimeout(retryT);
      if (!alive() || paused) return;
      var mine = ++seq, req = first || call('/pair/open', { device: deviceName() }, CALL_MS);
      first = null;
      if (!cur) status('正在准备…');
      req.then(function (p) {
        if (!alive() || mine !== seq || paused) { drop(p); return; }
        if (!p || !p.ok || !p.id) { openFailed(p); return; }
        adopt(p);
        prepare().then(null, noop).then(function () {      // 稀疏表好了再上码（一般早就好了）
          if (!alive() || mine !== seq || paused) { drop(p); return; }
          var old = cur;
          if (cloud) { cloud.setCode(p.id, p.secret); cloud.start(); }
          cur = p;
          status(note); note = '';                         // 云出来了就不再写字（只在准备中、出错时提示）
          if (old) retire(old);
          guard();
          wait();
        });
      }, function () {
        if (alive() && mine === seq && !paused) openFailed(null);
      });
    }
    function openFailed(p) {
      if (cur) { cur.noRotate = true; wait(); return; }   // 提前换没换成：接着等手上这一团，到期了照常再开
      var http = p ? p._http : 0;
      status(p && p.message || '暂时连不上，稍后再试');
      if (http === 403 && p.error === 'origin') return;   // 这个页面来源不让开云：再试也没用
      retryT = setTimeout(open, http === 429 ? 20000 : 5000);
    }
    function wait() {
      clearTimeout(retryT);
      if (!alive() || paused || !cur) return;
      var mine = cur, hold = 20000;
      // 还可能提前换：长轮询在离过期 8 秒稍内一点回来，带着最新的 peeked
      if (!mine.peeked && !mine.noRotate) hold = Math.max(0, Math.min(20000, Math.round(msLeft(mine) - ROTATE_LEAD + 300)));
      call('/pair/wait', { id: mine.id, poll: mine.poll, wait: hold }, WAIT_MS).then(function (r) {
        if (!alive()) return;
        if (r.status === 'approved') { approved(r, mine); return; }   // 这一次开过的哪一团被批准都算（都是这台设备的）
        if (mine !== cur || paused) return;
        if (r.status === 'open') {
          if (Number(r.exp) > 0) mine.exp = Number(r.exp);          // 手机看过一眼，服务端会把期限往后延
          mine.peeked = r.peeked === true;
          guard();
          if (!mine.peeked && !mine.noRotate && msLeft(mine) < ROTATE_LEAD) open();
          else wait();
          return;
        }
        if (!r.status && (r._http === 429 || r._http >= 500)) { retryT = setTimeout(wait, 2000); return; }   // 服务端一时不行：码还有效，接着等
        // 过期 / 作废 / 取消 / 用过 / 找不到：旧码立刻不画，再开一团
        if (r.status === 'done') note = '已在 iPhone 上批准，但这台设备没收到结果，请再扫一次';
        cur = null; clearTimeout(expT);
        if (cloud) cloud.clear();
        open();
      }, function () {
        // 断网 / 超时：同一团接着等（批准了的回包丢了，服务端 30 秒内还会再给一份）
        if (alive() && mine === cur && !paused) retryT = setTimeout(wait, 2000);
      });
    }
    // 到点还没换下来（提前换的那一团开得太慢）：死码别再画；手机看过的不管（它已经拿到码，等批准就行）
    function guard() {
      clearTimeout(expT);
      if (!cur || !cloud) return;
      var p = cur;
      expT = setTimeout(function () {
        if (!alive() || p !== cur) return;
        if (p.peeked || msLeft(p) > 0) guard(); else cloud.clear();
      }, Math.max(0, msLeft(p)) + 250);
    }
    // 换下来的一团：关掉再看一眼（关之前那一刻刚好被批准的话照样登录）；页面要关了（keep）就只关
    function retire(p, keep) {
      cancel(p, keep).then(function () {
        if (keep || !alive()) return;
        return call('/pair/wait', { id: p.id, poll: p.poll, wait: 0 }, CALL_MS).then(function (r) {
          if (r.status === 'approved' && alive()) approved(r, p);
        });
      }).catch(noop);
    }
    function approved(r, p) {
      var c = cur;
      dead = true; seq++; cur = null; quiet();
      if (cloud && cloud.owner === gen) cloud.stop();
      if (c && c !== p) cancel(c);                            // 批准的是换下来的那团：现在这团也关掉
      if (o.onApproved) o.onApproved(r);
    }
    function pause(keep) {
      clearTimeout(hideT);
      if (!alive() || paused) return;
      paused = true; seq++; clearTimeout(retryT); clearTimeout(expT);
      var c = cur; cur = null;
      if (cloud) { cloud.stop(); cloud.clear(); }
      if (c) retire(c, keep);
      if (first) { drop(first); first = null; }
    }
    function resume() {
      clearTimeout(hideT);
      if (!alive() || !paused) return;
      paused = false;
      open();
    }
    function onVis() {
      clearTimeout(hideT);
      if (doc.hidden) hideT = setTimeout(function () { pause(false); }, HIDE_GRACE);
      else if (paused) resume();
    }
    function onPageHide() { pause(true); }
    function onPageShow(e) { if (e && e.persisted && !doc.hidden) resume(); }   // 从往返缓存回来
    function quiet() {
      clearTimeout(retryT); clearTimeout(hideT); clearTimeout(expT);
      if (!doc) return;
      doc.removeEventListener('visibilitychange', onVis);
      window.removeEventListener('pagehide', onPageHide);
      window.removeEventListener('pageshow', onPageShow);
    }
    function stop() {
      if (dead) return;
      dead = true; seq++; quiet();
      if (cloud && cloud.owner === gen) { cloud.stop(); cloud.clear(); }
      var c = cur; cur = null;
      if (c) cancel(c, true);
      if (first) { drop(first); first = null; }
    }

    if (doc) {
      doc.addEventListener('visibilitychange', onVis);
      window.addEventListener('pagehide', onPageHide);
      window.addEventListener('pageshow', onPageShow);
    }
    if (doc && doc.hidden) { paused = true; if (first) { drop(first); first = null; } }
    else open();
    return { cloud: cloud, stop: stop };
  }

  window.CuvenPair = {
    SPEC: SPEC, cellSigns: cellSigns, fieldAt: fieldAt, modulation: modulation, modulationGrid: modulationGrid,
    modulationGridFast: modulationGridFast, basis: basisSync, prepare: prepare, codeBytes: codeBytes,
    Cloud: Cloud, login: login,
    acceptsOpened: true            // 认 login({ opened })：页面据此判断缓存里是不是旧版
  };
})();
