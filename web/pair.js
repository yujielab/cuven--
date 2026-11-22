/* Cuven 光学配对（网页端：显示粒子云的那一边）
 * ─────────────────────────────────────────────────────────────────────
 *  · 编码：配对编号 24 位 + 密钥 32 位 + CRC-8 → 卷积码（K=7，171/133）→ 交织 → 加导频 → 160 个格子的正负
 *  · 场：D(x) = Σ b_i·G_i(扭曲后的 x)，密度 ρ = 球壳亮边 ×（1 + α·tanh(D/τ)）×（1 + β·覆盖度²·exp(−(D/w)²)）
 *    规范与 Python 参考实现（pairing/py/spec.py）、iOS（PairCodec.swift）逐项一致，常数见下面的 SPEC
 *  · 渲染（WebGL2，GPU）：粒子状态全在显存里（变换反馈来回倒），每帧做一步朗之万：
 *      x += ε·∇log ρ + √(2ε)·噪声 + κ·ε·(∇log ρ)⊥
 *    前两项让粒子的分布始终是 ρ（相机读得出码）；最后一项沿等密度线流动，不改分布 —— 丝在「流」
 *  · 登录：POST check.cuven.us/pair/open → 显示云和 6 位数字 → /pair/wait 长轮询 → 批准了就回调
 */
(function () {
  'use strict';
  var SPEC = {"version":1,"cells":[[0.25322,-0.080733,0.05049],[0.251229,0.427684,0.05049],[0.230745,0.951894,0.05049],[0.23606,1.425281,0.05049],[0.241533,1.84068,0.05049],[0.273287,2.265773,0.05049],[0.252093,2.636563,0.05049],[0.260864,3.198149,0.05049],[0.238574,3.655192,0.05049],[0.244793,4.092163,0.05049],[0.261982,4.543046,0.05049],[0.245218,4.9593,0.05049],[0.270359,5.343711,0.05049],[0.27373,5.790119,0.05049],[0.443569,0.402384,0.056549],[0.44506,0.665578,0.056549],[0.416105,0.984208,0.056549],[0.422089,1.209142,0.056549],[0.422836,1.544247,0.056549],[0.451023,1.780221,0.056549],[0.416906,2.126199,0.056549],[0.444781,2.384458,0.056549],[0.419754,2.637653,0.056549],[0.42214,2.921977,0.056549],[0.451598,3.252525,0.056549],[0.43963,3.499846,0.056549],[0.456485,3.760034,0.056549],[0.445804,4.1132,0.056549],[0.455484,4.354697,0.056549],[0.462823,4.661027,0.056549],[0.433518,4.930833,0.056549],[0.437791,5.186374,0.056549],[0.422279,5.496114,0.056549],[0.450764,5.768473,0.056549],[0.425459,6.036287,0.056549],[0.449228,6.373848,0.056549],[0.615214,0.774417,0.058434],[0.604917,0.915188,0.058434],[0.597101,1.177014,0.058434],[0.596703,1.338701,0.058434],[0.634989,1.55853,0.058434],[0.607663,1.796588,0.058434],[0.637388,1.959481,0.058434],[0.620347,2.237488,0.058434],[0.601068,2.402828,0.058434],[0.606665,2.65327,0.058434],[0.614696,2.80719,0.058434],[0.63947,3.012438,0.058434],[0.627773,3.289867,0.058434],[0.619265,3.440769,0.058434],[0.621296,3.658928,0.058434],[0.598007,3.862691,0.058434],[0.618042,4.094627,0.058434],[0.6111,4.303898,0.058434],[0.63832,4.523497,0.058434],[0.62418,4.716717,0.058434],[0.624445,4.959159,0.058434],[0.642649,5.162723,0.058434],[0.642919,5.319186,0.058434],[0.607265,5.582809,0.058434],[0.634048,5.730284,0.058434],[0.601125,5.940558,0.058434],[0.635831,6.219714,0.058434],[0.634165,6.404116,0.058434],[0.619327,6.591992,0.058434],[0.595488,6.838695,0.058434],[0.769262,1.084385,0.052509],[0.786965,1.280756,0.052509],[0.781951,1.405834,0.052509],[0.780477,1.548476,0.052509],[0.766588,1.691533,0.052509],[0.786038,1.855846,0.052509],[0.780491,1.989517,0.052509],[0.802596,2.154996,0.052509],[0.789832,2.291084,0.052509],[0.794225,2.468119,0.052509],[0.800178,2.612711,0.052509],[0.778667,2.734637,0.052509],[0.768698,2.910009,0.052509],[0.794051,3.061189,0.052509],[0.759284,3.183024,0.052509],[0.777696,3.336014,0.052509],[0.79937,3.523495,0.052509],[0.77357,3.62691,0.052509],[0.789111,3.817835,0.052509],[0.779653,3.955363,0.052509],[0.75631,4.124873,0.052509],[0.80343,4.234301,0.052509],[0.790258,4.42421,0.052509],[0.770343,4.562213,0.052509],[0.777575,4.719145,0.052509],[0.780823,4.85459,0.052509],[0.77058,4.974157,0.052509],[0.802809,5.143094,0.052509],[0.79144,5.278557,0.052509],[0.803856,5.460406,0.052509],[0.786695,5.610307,0.052509],[0.778455,5.737485,0.052509],[0.796909,5.914486,0.052509],[0.795792,6.070909,0.052509],[0.801131,6.206327,0.052509],[0.759246,6.362737,0.052509],[0.758982,6.510901,0.052509],[0.790035,6.640798,0.052509],[0.792676,6.801384,0.052509],[0.790749,6.953689,0.052509],[0.755695,7.089683,0.052509],[0.770542,7.256099,0.052509],[0.911463,1.480252,0.050024],[0.901873,1.621077,0.050024],[0.935112,1.712452,0.050024],[0.934967,1.840322,0.050024],[0.919299,1.978065,0.050024],[0.91126,2.081842,0.050024],[0.90224,2.189754,0.050024],[0.941541,2.34326,0.050024],[0.932415,2.432535,0.050024],[0.933988,2.563968,0.050024],[0.923883,2.698475,0.050024],[0.917297,2.830737,0.050024],[0.925483,2.918324,0.050024],[0.913053,3.03199,0.050024],[0.920548,3.155245,0.050024],[0.922953,3.281955,0.050024],[0.901082,3.393301,0.050024],[0.921166,3.516313,0.050024],[0.928157,3.65346,0.050024],[0.897457,3.780814,0.050024],[0.944704,3.893376,0.050024],[0.91603,3.998325,0.050024],[0.909317,4.131241,0.050024],[0.915955,4.249543,0.050024],[0.928497,4.391995,0.050024],[0.91812,4.489645,0.050024],[0.940548,4.630128,0.050024],[0.942857,4.762184,0.050024],[0.921168,4.879855,0.050024],[0.898312,4.975081,0.050024],[0.919019,5.12379,0.050024],[0.910865,5.247451,0.050024],[0.899834,5.365966,0.050024],[0.901743,5.471755,0.050024],[0.917411,5.605253,0.050024],[0.937966,5.702161,0.050024],[0.916373,5.813444,0.050024],[0.938146,5.961821,0.050024],[0.904521,6.074522,0.050024],[0.931681,6.180347,0.050024],[0.909247,6.295208,0.050024],[0.92455,6.44862,0.050024],[0.920277,6.541297,0.050024],[0.897698,6.663139,0.050024],[0.898352,6.804255,0.050024],[0.918028,6.906094,0.050024],[0.901531,7.052079,0.050024],[0.90002,7.148828,0.050024],[0.940491,7.291516,0.050024],[0.930793,7.418656,0.050024],[0.903154,7.526643,0.050024],[0.919665,7.654804,0.050024]],"sigmaR":0.07,"pilotIdx":[3,11,19,27,35,43,51,59,67,75,83,91,99,107,115,123,131,139,147,155],"pilots":[1,1,-1,1,1,1,1,-1,1,1,-1,-1,-1,1,1,-1,1,-1,-1,1],"dataIdx":[0,1,2,4,5,6,7,8,9,10,12,13,14,15,16,17,18,20,21,22,23,24,25,26,28,29,30,31,32,33,34,36,37,38,39,40,41,42,44,45,46,47,48,49,50,52,53,54,55,56,57,58,60,61,62,63,64,65,66,68,69,70,71,72,73,74,76,77,78,79,80,81,82,84,85,86,87,88,89,90,92,93,94,95,96,97,98,100,101,102,103,104,105,106,108,109,110,111,112,113,114,116,117,118,119,120,121,122,124,125,126,127,128,129,130,132,133,134,135,136,137,138,140,141,142,143,144,145,146,148,149,150,151,152,153,154,156,157,158,159],"interleave":[0,53,106,19,72,125,38,91,4,57,110,23,76,129,42,95,8,61,114,27,80,133,46,99,12,65,118,31,84,137,50,103,16,69,122,35,88,1,54,107,20,73,126,39,92,5,58,111,24,77,130,43,96,9,62,115,28,81,134,47,100,13,66,119,32,85,138,51,104,17,70,123,36,89,2,55,108,21,74,127,40,93,6,59,112,25,78,131,44,97,10,63,116,29,82,135,48,101,14,67,120,33,86,139,52,105,18,71,124,37,90,3,56,109,22,75,128,41,94,7,60,113,26,79,132,45,98,11,64,117,30,83,136,49,102,15,68,121,34,87],"warp":[[0.06,2.3,3.1,0.7],[0.045,-3.7,1.9,2.1],[0.03,5.3,-4.1,4.4]],"alpha":0.22,"tau":0.3,"beta":2.4,"w":0.07,"e0":0.55,"conv":{"k":7,"g1":121,"g2":91},"decode":{"cam":256,"pr":24,"pa":192,"rLo":0.1,"rHi":1.08,"th":0.06,"kRms":1.605687,"targetScale":0.35}};
  var EXT = 1.6;                 // 场的范围：[-1.6, 1.6]²（云的半径 = 1）

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

  /* ── 场与密度 ── */
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
  function shell(r) { return r <= 1 ? 1 + 0.9 * r * r * r : 1.9 * Math.exp(-Math.pow(Math.max(r - 1, 0), 1.5) / Math.pow(0.17, 1.5)); }
  function density(D, E, r) {
    var gate = Math.min(1, Math.max(0, E / SPEC.e0));
    return shell(r) * (1 + SPEC.alpha * Math.tanh(D / SPEC.tau)) * (1 + SPEC.beta * gate * gate * Math.exp(-(D / SPEC.w) * (D / SPEC.w)));
  }
  /** G×G 的密度网格（覆盖 [-EXT, EXT]²，按像素中心取样） */
  function densityGrid(b, G) {
    var rho = new Float32Array(G * G);
    for (var j = 0; j < G; j++) for (var i = 0; i < G; i++) {
      var x = -EXT + (i + 0.5) * 2 * EXT / G, y = -EXT + (j + 0.5) * 2 * EXT / G;
      var de = fieldAt(b, x, y);
      rho[j * G + i] = density(de[0], de[1], Math.hypot(x, y));
    }
    return rho;
  }

  /* ── WebGL2 粒子云 ── */
  var VS_STEP = '#version 300 es\n' +
    'precision highp float;\n' +
    'in vec2 aPos;\n' +
    'uniform sampler2D uField;\n' +             // r: ρ/ρmax，g、b: ∇log ρ
    'uniform float uEps, uSwirl, uFrame, uExt;\n' +
    'out vec2 vPos;\n' +
    'float h(float n){ return fract(sin(n) * 43758.5453123); }\n' +
    'void main(){\n' +
    '  vec2 p = aPos;\n' +
    '  vec4 f = texture(uField, p / (2.0 * uExt) + 0.5);\n' +
    '  vec2 g = f.gb;\n' +
    '  float id = float(gl_VertexID);\n' +
    '  float u1 = max(h(id * 0.1031 + uFrame * 1.7), 1e-6), u2 = h(id * 0.3713 + uFrame * 2.9 + 7.0);\n' +
    '  vec2 n = sqrt(-2.0 * log(u1)) * vec2(cos(6.2831853 * u2), sin(6.2831853 * u2));\n' +
    '  p += uEps * g + sqrt(2.0 * uEps) * n + uSwirl * uEps * vec2(-g.y, g.x);\n' +
    '  float r = length(p);\n' +
    '  if (r > uExt * 0.97) p *= (uExt * 0.97) / r;\n' +
    '  vPos = p;\n' +
    '}\n';
  var FS_NULL = '#version 300 es\nprecision mediump float;\nout vec4 o;\nvoid main(){ o = vec4(0.0); }\n';
  var VS_DRAW = '#version 300 es\n' +
    'precision highp float;\n' +
    'in vec2 aPos;\n' +
    'uniform sampler2D uField;\n' +
    'uniform float uRot, uScale, uSize, uExt, uBreath;\n' +
    'uniform vec2 uAspect;\n' +
    'out float vDense; out float vA;\n' +
    'float h(float n){ return fract(sin(n) * 43758.5453123); }\n' +
    'void main(){\n' +
    '  float c = cos(uRot), s = sin(uRot);\n' +
    '  vec2 q = vec2(c * aPos.x - s * aPos.y, s * aPos.x + c * aPos.y);\n' +
    '  gl_Position = vec4(q.x * uScale * uAspect.x, -q.y * uScale * uAspect.y, 0.0, 1.0);\n' +   // y 朝下画：和相机拍屏幕（行号往下）同一手性，否则是镜像，旋转找不回来

    '  float depth = h(float(gl_VertexID) * 0.7311);\n' +           // 假的远近：大小、深浅有点区别
    '  gl_PointSize = uSize * (0.7 + 0.6 * depth);\n' +
    '  vDense = texture(uField, aPos / (2.0 * uExt) + 0.5).r;\n' +
    '  vA = (0.45 + 0.35 * depth) * uBreath;\n' +
    '}\n';
  var FS_DRAW = '#version 300 es\n' +
    'precision mediump float;\n' +
    'in float vDense; in float vA;\n' +
    'uniform vec3 uLight, uDeep;\n' +
    'out vec4 o;\n' +
    'void main(){\n' +
    '  vec2 d = gl_PointCoord - 0.5;\n' +
    '  float m = smoothstep(0.5, 0.2, length(d));\n' +
    '  vec3 col = mix(uLight, uDeep, clamp(vDense * 1.6 - 0.2, 0.0, 1.0));\n' +
    '  float a = vA * m;\n' +
    '  o = vec4(col * a, a);\n' +                                    // 预乘透明度
    '}\n';

  function compile(gl, type, src) {
    var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  function program(gl, vs, fs, tf) {
    var p = gl.createProgram();
    gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, vs));
    gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, fs));
    if (tf) gl.transformFeedbackVaryings(p, tf, gl.SEPARATE_ATTRIBS);
    gl.bindAttribLocation(p, 0, 'aPos');
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    return p;
  }

  /**
   * new Cloud(canvas, { particles, dark }) ；setCode(id, secret)；start()；stop()
   * 没有 WebGL2 时 ok = false（调用方只显示 6 位数字）
   */
  function Cloud(canvas, opts) {
    opts = opts || {};
    this.canvas = canvas;
    this.dark = !!opts.dark;
    this.n = opts.particles || (/(iPhone|iPad|Android)/.test(navigator.userAgent) ? 36000 : 60000);
    this.G = 192;
    this.gl = canvas.getContext('webgl2', { premultipliedAlpha: true, antialias: false, alpha: true, preserveDrawingBuffer: !!opts.preserve });
    this.ok = !!this.gl;
    this.frame = 0; this.raf = 0; this.t0 = 0;
    if (!this.ok) return;
    var gl = this.gl;
    this.pStep = program(gl, VS_STEP, FS_NULL, ['vPos']);
    this.pDraw = program(gl, VS_DRAW, FS_DRAW, null);
    this.tex = gl.createTexture();
    this.bufs = [gl.createBuffer(), gl.createBuffer()];
    this.vaos = [gl.createVertexArray(), gl.createVertexArray()];
    for (var i = 0; i < 2; i++) {
      gl.bindVertexArray(this.vaos[i]);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.bufs[i]);
      gl.bufferData(gl.ARRAY_BUFFER, this.n * 8, gl.DYNAMIC_COPY);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    }
    gl.bindVertexArray(null);
    this.tf = gl.createTransformFeedback();
    this.cur = 0;
  }
  Cloud.prototype.setCode = function (id, secret) {
    if (!this.ok) return;
    var gl = this.gl, G = this.G;
    var b = cellSigns(id, secret);
    var rho = densityGrid(b, G);
    var max = 0, i, j;
    for (i = 0; i < rho.length; i++) if (rho[i] > max) max = rho[i];
    // 纹理：r = ρ/ρmax，g、b = ∇log ρ（单位：每「云半径」），a 不用
    var tex = new Float32Array(G * G * 4), cell = 2 * EXT / G;
    for (j = 0; j < G; j++) for (i = 0; i < G; i++) {
      var k = j * G + i;
      var l = Math.log(Math.max(rho[k], 1e-6));
      var lx = Math.log(Math.max(rho[j * G + Math.min(G - 1, i + 1)], 1e-6)) - Math.log(Math.max(rho[j * G + Math.max(0, i - 1)], 1e-6));
      var ly = Math.log(Math.max(rho[Math.min(G - 1, j + 1) * G + i], 1e-6)) - Math.log(Math.max(rho[Math.max(0, j - 1) * G + i], 1e-6));
      tex[k * 4] = rho[k] / max; tex[k * 4 + 1] = lx / (2 * cell); tex[k * 4 + 2] = ly / (2 * cell); tex[k * 4 + 3] = l;
    }
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, G, G, 0, gl.RGBA, gl.FLOAT, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    // 粒子一开始就按 ρ 撒好（逆累积分布），不用等它「流」到位
    var cdf = new Float64Array(rho.length), acc = 0;
    for (i = 0; i < rho.length; i++) { acc += rho[i]; cdf[i] = acc; }
    var pos = new Float32Array(this.n * 2);
    for (i = 0; i < this.n; i++) {
      var u = Math.random() * acc, lo = 0, hi = rho.length - 1;
      while (lo < hi) { var mid = (lo + hi) >> 1; if (cdf[mid] < u) lo = mid + 1; else hi = mid; }
      pos[i * 2] = -EXT + ((lo % G) + Math.random()) * cell;
      pos[i * 2 + 1] = -EXT + (((lo / G) | 0) + Math.random()) * cell;
    }
    for (i = 0; i < 2; i++) { gl.bindBuffer(gl.ARRAY_BUFFER, this.bufs[i]); gl.bufferSubData(gl.ARRAY_BUFFER, 0, pos); }
    this.coded = true;
  };
  Cloud.prototype.draw = function (now) {
    var gl = this.gl, c = this.canvas;
    var dpr = Math.min(window.devicePixelRatio || 1, 2.5);
    var w = Math.round(c.clientWidth * dpr) || c.width, h = Math.round(c.clientHeight * dpr) || c.height;
    if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
    var t = (now - this.t0) / 1000;
    var breath = 0.5 + 0.5 * Math.cos(t * 2 * Math.PI / 8);                // 8 秒一次：丝聚拢、散开
    // 一步朗之万（变换反馈）
    gl.useProgram(this.pStep);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.uniform1i(gl.getUniformLocation(this.pStep, 'uField'), 0);
    gl.uniform1f(gl.getUniformLocation(this.pStep, 'uEps'), 1.6e-5);
    gl.uniform1f(gl.getUniformLocation(this.pStep, 'uSwirl'), 18 + 22 * breath);
    gl.uniform1f(gl.getUniformLocation(this.pStep, 'uFrame'), (this.frame++ % 100000) * 0.618);
    gl.uniform1f(gl.getUniformLocation(this.pStep, 'uExt'), EXT);
    gl.bindVertexArray(this.vaos[this.cur]);
    gl.bindTransformFeedback(gl.TRANSFORM_FEEDBACK, this.tf);
    gl.bindBufferBase(gl.TRANSFORM_FEEDBACK_BUFFER, 0, this.bufs[1 - this.cur]);
    gl.enable(gl.RASTERIZER_DISCARD);
    gl.beginTransformFeedback(gl.POINTS);
    gl.drawArrays(gl.POINTS, 0, this.n);
    gl.endTransformFeedback();
    gl.disable(gl.RASTERIZER_DISCARD);
    gl.bindBufferBase(gl.TRANSFORM_FEEDBACK_BUFFER, 0, null);
    gl.bindTransformFeedback(gl.TRANSFORM_FEEDBACK, null);
    this.cur = 1 - this.cur;
    // 画
    gl.viewport(0, 0, w, h);
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
    gl.enable(gl.BLEND);
    if (this.dark) gl.blendFunc(gl.ONE, gl.ONE); else gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.useProgram(this.pDraw);
    gl.uniform1i(gl.getUniformLocation(this.pDraw, 'uField'), 0);
    gl.uniform1f(gl.getUniformLocation(this.pDraw, 'uRot'), t * 0.06);       // 慢慢转（相机那头按极坐标找旋转）
    gl.uniform1f(gl.getUniformLocation(this.pDraw, 'uScale'), 0.60);
    gl.uniform2f(gl.getUniformLocation(this.pDraw, 'uAspect'), Math.min(1, h / w), Math.min(1, w / h));
    gl.uniform1f(gl.getUniformLocation(this.pDraw, 'uSize'), Math.max(1.4, 1.3 * dpr) * (Math.min(w, h) / 600 + 0.6));
    gl.uniform1f(gl.getUniformLocation(this.pDraw, 'uExt'), EXT);
    gl.uniform1f(gl.getUniformLocation(this.pDraw, 'uBreath'), 0.85 + 0.15 * breath);
    var light = this.dark ? [0.16, 0.42, 0.85] : [0.47, 0.75, 0.96], deep = this.dark ? [0.35, 0.65, 1.0] : [0.12, 0.43, 0.90];
    gl.uniform3fv(gl.getUniformLocation(this.pDraw, 'uLight'), light);
    gl.uniform3fv(gl.getUniformLocation(this.pDraw, 'uDeep'), deep);
    gl.bindVertexArray(this.vaos[this.cur]);
    gl.drawArrays(gl.POINTS, 0, this.n);
    gl.bindVertexArray(null);
  };
  Cloud.prototype.start = function () {
    if (!this.ok || this.raf) return;
    var self = this;
    this.t0 = performance.now();
    var loop = function (now) { self.raf = requestAnimationFrame(loop); if (self.coded) self.draw(now); };
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
   * CuvenPair.login({ api, canvas, dark, onCode(code6), onStatus(text), onApproved(r) })
   * r = { username, email, code（识别代码，5 分钟）, device（设备令牌） }；返回 { stop() }
   */
  function login(o) {
    var api = (o.api || 'https://check.cuven.us').replace(/\/+$/, '');
    var cloud = o.canvas ? new Cloud(o.canvas, { dark: o.dark }) : null;
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
        status('用已登录 Cuven 的 iPhone 扫描这团粒子云');
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

  window.CuvenPair = { SPEC: SPEC, cellSigns: cellSigns, fieldAt: fieldAt, density: density, densityGrid: densityGrid, Cloud: Cloud, login: login };
})();
