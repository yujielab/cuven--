using System.Reflection;
using System.Text.Json;

namespace Cuven.Core;

/// <summary>
/// 光学配对的码（显示粒子云的这一边）：配对编号 24 位 + 密钥 32 位 + CRC-8 → 卷积码（K=7，171/133）→ 交织 → 加导频 → 160 个格子的正负；
/// 码场 D(x) = Σ b_i·G_i(扭曲后的 x)，调制 M =（1 + α·tanh(D/τ)）×（1 + β·覆盖度²·exp(−(D/w)²)）。
/// 和 pairing/py/spec.py、web/pair.js、iOS 的 PairCodec.swift 逐项一致；常数来自 pairing/model/cpc1-spec.json
/// </summary>
public sealed class PairSpec
{
    public const double Ext = 1.6;   // 码场的范围：[-1.6, 1.6]²（云的半径 = 1）

    public required double[][] Cells { get; init; }    // [r, θ, σθ]
    public required double SigmaR { get; init; }
    public required int[] PilotIdx { get; init; }
    public required int[] Pilots { get; init; }
    public required int[] DataIdx { get; init; }
    public required int[] Interleave { get; init; }
    public required double[][] Warp { get; init; }     // [a, kx, ky, φ]
    public required double Alpha { get; init; }
    public required double Tau { get; init; }
    public required double Beta { get; init; }
    public required double W { get; init; }
    public required double E0 { get; init; }
    public required int CodeGrid { get; init; }
    public required double CodeScale { get; init; }
    public required double CodeSpin { get; init; }
    public required int G1 { get; init; }
    public required int G2 { get; init; }
    public int Version { get; init; }

    // 线程安全地只读一次（码纹理的稀疏基底在线程池上算，UI 线程也会同时要它）
    static readonly Lazy<PairSpec> _shared = new(Load);
    public static PairSpec Shared => _shared.Value;

    static PairSpec Load()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("cpc1-spec.json")
            ?? throw new InvalidOperationException("cpc1-spec.json 没有打进程序集");
        return Parse(JsonDocument.Parse(s).RootElement);
    }

    public static PairSpec Parse(JsonElement e)
    {
        static double[][] M(JsonElement a) => a.EnumerateArray().Select(r => r.EnumerateArray().Select(x => x.GetDouble()).ToArray()).ToArray();
        static int[] I(JsonElement a) => a.EnumerateArray().Select(x => x.GetInt32()).ToArray();
        var conv = e.GetProperty("conv");
        return new PairSpec
        {
            Version = e.Int("version") ?? 0,
            Cells = M(e.GetProperty("cells")),
            SigmaR = e.GetProperty("sigmaR").GetDouble(),
            PilotIdx = I(e.GetProperty("pilotIdx")),
            Pilots = I(e.GetProperty("pilots")),
            DataIdx = I(e.GetProperty("dataIdx")),
            Interleave = I(e.GetProperty("interleave")),
            Warp = M(e.GetProperty("warp")),
            Alpha = e.GetProperty("alpha").GetDouble(),
            Tau = e.GetProperty("tau").GetDouble(),
            Beta = e.GetProperty("beta").GetDouble(),
            W = e.GetProperty("w").GetDouble(),
            E0 = e.GetProperty("e0").GetDouble(),
            CodeGrid = e.Int("codeGrid") ?? 192,
            CodeScale = e.Dbl("codeScale") ?? 3.0,
            CodeSpin = e.Dbl("codeSpin") ?? 0.05,
            G1 = conv.GetProperty("g1").GetInt32(),
            G2 = conv.GetProperty("g2").GetInt32(),
        };
    }
}

public static class PairCodec
{
    public static byte Crc8(ReadOnlySpan<byte> bytes)
    {
        int c = 0;
        foreach (var b in bytes)
        {
            c ^= b;
            for (int k = 0; k < 8; k++) c = (c & 0x80) != 0 ? ((c << 1) ^ 0x07) & 0xFF : (c << 1) & 0xFF;
        }
        return (byte)c;
    }

    static int Parity(int x) { int n = 0; while (x != 0) { n ^= x & 1; x >>= 1; } return n; }

    public static int[] PayloadBits(uint id, uint secret)
    {
        Span<byte> b = stackalloc byte[8];
        b[0] = (byte)(id >> 16); b[1] = (byte)(id >> 8); b[2] = (byte)id;
        b[3] = (byte)(secret >> 24); b[4] = (byte)(secret >> 16); b[5] = (byte)(secret >> 8); b[6] = (byte)secret;
        b[7] = Crc8(b[..7]);
        var o = new int[64];
        for (int i = 0; i < 64; i++) o[i] = (b[i >> 3] >> (7 - (i & 7))) & 1;
        return o;
    }

    public static int[] ConvEncode(int[] bits, PairSpec s)
    {
        var all = bits.Concat(new int[6]).ToArray();
        var o = new int[all.Length * 2];
        int st = 0;
        for (int i = 0; i < all.Length; i++)
        {
            st = ((st << 1) | all[i]) & 0x7F;
            o[2 * i] = Parity(st & s.G1);
            o[2 * i + 1] = Parity(st & s.G2);
        }
        return o;
    }

    /// <summary>160 个格子的正负（±1）</summary>
    public static float[] CellSigns(uint id, uint secret, PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        var coded = ConvEncode(PayloadBits(id, secret), s);
        var b = new float[s.Cells.Length];
        for (int i = 0; i < s.PilotIdx.Length; i++) b[s.PilotIdx[i]] = s.Pilots[i];
        for (int k = 0; k < coded.Length; k++) b[s.DataIdx[s.Interleave[k]]] = coded[k] != 0 ? 1 : -1;
        return b;
    }

    static double Wrap(double a)
    {
        a = (a + Math.PI) % (2 * Math.PI);
        if (a < 0) a += 2 * Math.PI;
        return a - Math.PI;
    }

    static (double, double) Warp(double x, double y, PairSpec s)
    {
        double dx = 0, dy = 0;
        foreach (var w in s.Warp)
        {
            dx += w[0] * Math.Sin(w[1] * x + w[2] * y + w[3]);
            dy += w[0] * Math.Cos(w[2] * x - w[1] * y + w[3] * 1.3);
        }
        return (x + dx, y + dy);
    }

    /// <summary>第 i 个格子在（扭曲前的）x 处的高斯权重 G_i；码场和稀疏基底都用这一个，数一模一样</summary>
    static void Gaussians(double x, double y, PairSpec s, Span<double> g)
    {
        var (qx, qy) = Warp(x, y, s);
        double r = Math.Sqrt(qx * qx + qy * qy), th = Math.Atan2(qy, qx);
        double s2r = 2 * s.SigmaR * s.SigmaR;
        for (int i = 0; i < s.Cells.Length; i++)
        {
            var c = s.Cells[i];
            double dr = r - c[0], dt = c[0] * Wrap(th - c[1]);
            g[i] = Math.Exp(-(dr * dr) / s2r - dt * dt / (2 * c[2] * c[2]));
        }
    }

    /// <summary>码场 (D, E)：D = Σ b·G，E = Σ G（覆盖度）。参考实现（测试、自检用；显示走 <see cref="CodeTexture"/> 的稀疏快路）</summary>
    public static (double D, double E) FieldAt(float[] b, double x, double y, PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        Span<double> g = s.Cells.Length <= 512 ? stackalloc double[s.Cells.Length] : new double[s.Cells.Length];
        Gaussians(x, y, s, g);
        double D = 0, E = 0;
        for (int i = 0; i < g.Length; i++) { D += b[i] * g[i]; E += g[i]; }
        return (D, E);
    }

    /// <summary>调制 M（光学深度的倍数）</summary>
    public static double Modulation(double D, double E, PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        var gate = Math.Clamp(E / s.E0, 0, 1);
        var z = D / s.W;
        return (1 + s.Alpha * Math.Tanh(D / s.Tau)) * (1 + s.Beta * gate * gate * Math.Exp(-z * z));
    }

    /// <summary>G×G 的调制网格（覆盖 [-Ext, Ext]²，像素中心取样；第 0 行是 y 最小的一行）。参考实现：每个像素把 160 个高斯全算一遍</summary>
    public static float[] ModulationGrid(float[] b, int g, PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        var m = new float[g * g];
        double ext = PairSpec.Ext;
        Parallel.For(0, g, j =>
        {
            double y = -ext + (j + 0.5) * 2 * ext / g;
            for (int i = 0; i < g; i++)
            {
                double x = -ext + (i + 0.5) * 2 * ext / g;
                var (D, E) = FieldAt(b, x, y, s);
                m[j * g + i] = (float)Modulation(D, E, s);
            }
        });
        return m;
    }

    // 稀疏基底只和规范有关、和码无关：进程里算一次（第一次要用时，或者 Prepare 提前在线程池上算好）
    static readonly Lazy<PairBasis> _basis = new(() => BuildBasis(PairSpec.Shared, PairSpec.Shared.CodeGrid));

    /// <summary>提前算好稀疏基底（和 /pair/open 的往返叠在一起，第一团码不用再等它）</summary>
    public static void Prepare() => _ = _basis.Value;

    /// <summary>默认规范、默认网格的稀疏基底</summary>
    public static PairBasis Basis => _basis.Value;

    /// <summary>快路：D = Σ b[格子]·G（只走每个像素够得着的那几个格子），E 预先算好；和 <see cref="ModulationGrid"/> 一致（差在 1e-5 以内）</summary>
    public static float[] ModulationGridFast(float[] b, PairBasis? basis = null, PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        var B = basis ?? _basis.Value;
        int n = B.G * B.G;
        var m = new float[n];
        var start = B.Start; var idx = B.Cell; var wt = B.Weight; var E = B.E;
        for (int p = 0; p < n; p++)
        {
            double D = 0;
            for (int k = start[p], end = start[p + 1]; k < end; k++) D += b[idx[k]] * (double)wt[k];
            m[p] = (float)Modulation(D, E[p], s);
        }
        return m;
    }

    /// <summary>M → 8 位（存 M / codeScale）</summary>
    static byte[] Quantize(float[] m, PairSpec s)
    {
        var px = new byte[m.Length];
        for (int i = 0; i < m.Length; i++) px[i] = (byte)Math.Clamp(Math.Round(m[i] / s.CodeScale * 255), 0, 255);
        return px;
    }

    /// <summary>码纹理（8 位，存 M / codeScale）：GPU 上画云时每个粒子的光学深度乘上它。默认规范走稀疏快路（几毫秒），别的规范走参考实现</summary>
    public static byte[] CodeTexture(uint id, uint secret, PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        if (!ReferenceEquals(s, PairSpec.Shared) || s.Cells.Length > 256) return CodeTextureDense(id, secret, s);
        return Quantize(ModulationGridFast(CellSigns(id, secret, s), _basis.Value, s), s);
    }

    /// <summary>码纹理的参考实现（逐像素算满 160 个高斯）：测试拿它对照快路</summary>
    public static byte[] CodeTextureDense(uint id, uint secret, PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        return Quantize(ModulationGrid(CellSigns(id, secret, s), s.CodeGrid, s), s);
    }

    /// <summary>不带码的纹理（M 处处 = 1）：码作废了、新的还没到时换上它，云照常画、但扫不出东西</summary>
    public static byte[] NeutralTexture(PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        var px = new byte[s.CodeGrid * s.CodeGrid];
        Array.Fill(px, (byte)Math.Clamp(Math.Round(255 / s.CodeScale), 0, 255));
        return px;
    }

    /// <summary>算稀疏基底（和逐像素算满一样的数：同一个 Gaussians）。约等于算一次参考网格的工夫，进程里只算一次</summary>
    public static PairBasis BuildBasis(PairSpec s, int g)
    {
        int nc = s.Cells.Length;
        if (nc > 256) throw new InvalidOperationException("格子超过 256 个，稀疏基底存不下格子号");
        double ext = PairSpec.Ext;
        var E = new double[g * g];
        var rowCell = new byte[g][];
        var rowW = new float[g][];
        var rowCount = new int[g][];
        Parallel.For(0, g, j =>
        {
            double y = -ext + (j + 0.5) * 2 * ext / g;
            Span<double> w = nc <= 512 ? stackalloc double[nc] : new double[nc];
            var cells = new List<byte>(g * 8);
            var ws = new List<float>(g * 8);
            var counts = new int[g];
            for (int i = 0; i < g; i++)
            {
                double x = -ext + (i + 0.5) * 2 * ext / g;
                Gaussians(x, y, s, w);
                double e = 0;
                int before = cells.Count;
                for (int c = 0; c < nc; c++)
                {
                    e += w[c];
                    if (w[c] > PairBasis.Cutoff) { cells.Add((byte)c); ws.Add((float)w[c]); }
                }
                E[j * g + i] = e;
                counts[i] = cells.Count - before;
            }
            rowCell[j] = cells.ToArray(); rowW[j] = ws.ToArray(); rowCount[j] = counts;
        });
        int nnz = 0;
        for (int j = 0; j < g; j++) nnz += rowCell[j].Length;
        var start = new int[g * g + 1];
        var cell = new byte[nnz];
        var weight = new float[nnz];
        int at = 0;
        for (int j = 0; j < g; j++)
        {
            Array.Copy(rowCell[j], 0, cell, at, rowCell[j].Length);
            Array.Copy(rowW[j], 0, weight, at, rowW[j].Length);
            for (int i = 0; i < g; i++) { start[j * g + i] = at; at += rowCount[j][i]; }
        }
        start[g * g] = at;
        return new PairBasis { G = g, E = E, Start = start, Cell = cell, Weight = weight };
    }
}

/// <summary>稀疏基底：每个像素的覆盖度 E，加上 CSR 存的（格子号, 高斯权重 G）——只留 G &gt; 1e-7 的（平均每个像素六七个）</summary>
public sealed class PairBasis
{
    public const double Cutoff = 1e-7;
    public required int G { get; init; }
    public required double[] E { get; init; }      // G×G：Σ 全部格子的 G（不截断）
    public required int[] Start { get; init; }     // G×G + 1：第 p 个像素的条目是 [Start[p], Start[p+1])
    public required byte[] Cell { get; init; }     // 格子号（< 256）
    public required float[] Weight { get; init; }  // 高斯权重 G
    public int NonZeros => Cell.Length;
}
