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

    static PairSpec? _shared;
    public static PairSpec Shared => _shared ??= Load();

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

    /// <summary>码场 (D, E)：D = Σ b·G，E = Σ G（覆盖度）</summary>
    public static (double D, double E) FieldAt(float[] b, double x, double y, PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        var (qx, qy) = Warp(x, y, s);
        double r = Math.Sqrt(qx * qx + qy * qy), th = Math.Atan2(qy, qx);
        double D = 0, E = 0, s2r = 2 * s.SigmaR * s.SigmaR;
        for (int i = 0; i < s.Cells.Length; i++)
        {
            var c = s.Cells[i];
            double dr = r - c[0], dt = c[0] * Wrap(th - c[1]);
            double g = Math.Exp(-(dr * dr) / s2r - dt * dt / (2 * c[2] * c[2]));
            D += b[i] * g; E += g;
        }
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

    /// <summary>G×G 的调制网格（覆盖 [-Ext, Ext]²，像素中心取样；第 0 行是 y 最小的一行）</summary>
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

    /// <summary>码纹理（8 位，存 M / codeScale）：GPU 上画云时每个粒子的光学深度乘上它</summary>
    public static byte[] CodeTexture(uint id, uint secret, PairSpec? spec = null)
    {
        var s = spec ?? PairSpec.Shared;
        var m = ModulationGrid(CellSigns(id, secret, s), s.CodeGrid, s);
        var px = new byte[m.Length];
        for (int i = 0; i < m.Length; i++) px[i] = (byte)Math.Clamp(Math.Round(m[i] / s.CodeScale * 255), 0, 255);
        return px;
    }
}
