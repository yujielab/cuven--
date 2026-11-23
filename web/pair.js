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
 *  · 登录：POST check.cuven.us/pair/open → 显示云和 6 位数字 → /pair/wait 长轮询 → 批准了就回调
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
  /** G×G 的调制网格（覆盖 [-EXT, EXT]²，按像素中心取样；第 0 行是 y 最小的一行） */
  function modulationGrid(b, G) {
    var m = new Float32Array(G * G);
    for (var j = 0; j < G; j++) for (var i = 0; i < G; i++) {
      var de = fieldAt(b, -EXT + (i + 0.5) * 2 * EXT / G, -EXT + (j + 0.5) * 2 * EXT / G);
      m[j * G + i] = modulation(de[0], de[1]);
    }
    return m;
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
   * setCode(id, secret)；start()；stop()；drawAt(秒)（自检 / 截图用）。没有 WebGL 时 ok = false（调用方只显示 6 位数字）
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
  /** 换一团码：算调制网格（codeGrid²）→ 码纹理 */
  Cloud.prototype.setCode = function (id, secret) {
    if (!this.ok) return;
    var G = CODE_GRID, m = modulationGrid(cellSigns(id, secret), G), px = new Uint8Array(G * G);
    for (var i = 0; i < m.length; i++) px[i] = Math.max(0, Math.min(255, Math.round(m[i] / CODE_SCALE * 255)));
    var gl = this.gl;
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, this.codeTex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, G, G, 0, gl.LUMINANCE, gl.UNSIGNED_BYTE, px);
    this.codeT0 = performance.now();
    this.coded = true;
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

  /* ── 登录：开一团云 → 等批准（过期自动换一团） ── */
  function deviceName() {
    var ua = navigator.userAgent, os = /iPhone/.test(ua) ? 'iPhone' : /iPad/.test(ua) ? 'iPad' : /Mac/.test(ua) ? 'Mac' : /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : '电脑';
    var br = /Edg\//.test(ua) ? 'Edge' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox' : /Safari\//.test(ua) ? 'Safari' : '浏览器';
    return os + ' · ' + br;
  }
  /**
   * CuvenPair.login({ api, canvas, atlas, onCode(code6), onStatus(text), onApproved(r) })
   * r = { username, email, code（识别代码，5 分钟）, device（设备令牌） }；返回 { stop() }
   */
  function login(o) {
    var api = (o.api || 'https://check.cuven.us').replace(/\/+$/, '');
    var cloud = o.canvas ? new Cloud(o.canvas, { atlas: o.atlas }) : null;
    var dead = false, cur = null;
    var post = function (path, body) {
      return fetch(api + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body || {}) })
        .then(function (r) { return r.json().catch(function () { return {}; }); });
    };
    var status = function (t) { if (o.onStatus) o.onStatus(t); };
    function open() {
      if (dead) return;
      status('正在准备…');
      post('/pair/open', { device: deviceName() }).then(function (p) {
        if (dead) return;
        if (!p || !p.ok) { status(p && p.message || '暂时连不上，稍后再试'); setTimeout(open, 5000); return; }
        cur = p;
        if (cloud && cloud.ok) { cloud.setCode(p.id, p.secret); cloud.start(); }
        if (o.onCode) o.onCode(p.code);
        status('');                                                          // 云出来了就不再写字（只在准备中、出错时提示）
        wait();
      }).catch(function () { if (!dead) { status('暂时连不上，稍后再试'); setTimeout(open, 5000); } });
    }
    function wait() {
      if (dead || !cur) return;
      var mine = cur;
      post('/pair/wait', { id: mine.id, poll: mine.poll }).then(function (r) {
        if (dead || mine !== cur) return;
        if (r && r.status === 'approved') { dead = true; if (cloud) cloud.stop(); if (o.onApproved) o.onApproved(r); return; }
        if (r && r.status === 'open') { wait(); return; }
        open();                                                            // 过期 / 作废 / 取消：换一团
      }).catch(function () { if (!dead) setTimeout(wait, 2000); });
    }
    open();
    return {
      cloud: cloud,
      stop: function () {
        dead = true; if (cloud) cloud.stop();
        if (cur) post('/pair/cancel', { id: cur.id, poll: cur.poll }).catch(function () {});
      },
    };
  }

  window.CuvenPair = { SPEC: SPEC, cellSigns: cellSigns, fieldAt: fieldAt, modulation: modulation, modulationGrid: modulationGrid, Cloud: Cloud, login: login };
})();
