using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Cuven.Core;

/// <summary>一条字幕：起止秒数 + 文字（多行用 \n）</summary>
public readonly record struct Cue(double Start, double End, string Text);

/// <summary>WebVTT / SRT 文本 → 字幕条（在线字幕走 /api/subs/vtt，回的是 WebVTT）</summary>
public static partial class SubtitleParser
{
    [GeneratedRegex(@"^\s*(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})")]
    private static partial Regex TimingRx();

    [GeneratedRegex(@"<[^>]*>|\{\\[^}]*\}")]
    private static partial Regex TagRx();

    static double T(Match m, int g)
    {
        double h = m.Groups[g].Success && m.Groups[g].Value.Length > 0 ? double.Parse(m.Groups[g].Value, CultureInfo.InvariantCulture) : 0;
        double mi = double.Parse(m.Groups[g + 1].Value, CultureInfo.InvariantCulture);
        double s = double.Parse(m.Groups[g + 2].Value, CultureInfo.InvariantCulture);
        var frac = m.Groups[g + 3].Value;
        double ms = double.Parse(frac, CultureInfo.InvariantCulture) / Math.Pow(10, frac.Length);
        return h * 3600 + mi * 60 + s + ms;
    }

    public static List<Cue> Parse(string text)
    {
        var cues = new List<Cue>();
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var m = TimingRx().Match(lines[i]);
            if (!m.Success) continue;
            double a = T(m, 1), b = T(m, 5);
            var sb = new StringBuilder();
            int j = i + 1;
            for (; j < lines.Length && lines[j].Trim().Length > 0; j++)
            {
                if (TimingRx().IsMatch(lines[j])) break;
                if (sb.Length > 0) sb.Append('\n');
                sb.Append(Clean(lines[j]));
            }
            i = j - 1;
            var t = sb.ToString().Trim();
            if (t.Length > 0 && b > a) cues.Add(new Cue(a, b, t));
        }
        cues.Sort((x, y) => x.Start.CompareTo(y.Start));
        return cues;
    }

    /// <summary>去掉 VTT / ASS 的样式标签，HTML 实体还原</summary>
    public static string Clean(string s)
    {
        s = TagRx().Replace(s, "");
        return s.Replace("&amp;", "&").Replace("&lt;", "<").Replace("&gt;", ">").Replace("&nbsp;", " ").Replace("\\N", "\n").Replace("\\n", "\n").Trim();
    }
}
