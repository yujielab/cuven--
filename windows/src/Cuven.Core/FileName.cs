using System.Text.RegularExpressions;

namespace Cuven.Core;

/// <summary>从文件名里读年份、片名与规格（和 iOS 的 FileName.swift 同一套规则）。片名优先用 TMDB 的中文名，这里只是兜底</summary>
public static partial class FileName
{
    [GeneratedRegex(@"(?<![0-9A-Za-z])(19[2-9][0-9]|20[0-4][0-9])(?![0-9])")]
    private static partial Regex YearRx();

    [GeneratedRegex(@"(?i)[ ._\-\[(](2160p|1080p|720p|480p|4k|8k|uhd|bluray|blu-ray|web-?dl|webrip|hdtv|remux|hdr|dv|x26[45]|h\.?26[45]|hevc|s[0-9]{1,2}e[0-9]{1,3}|s[0-9]{1,2}(?![0-9a-z]))")]
    private static partial Regex CutRx();

    [GeneratedRegex(@"(?i)[. ]*\[?auto-(?:m|tv)[0-9]{1,9}(?:s[0-9]{1,3})?-r[0-9]{1,12}\]?")]
    private static partial Regex AutoTagRx();

    public static readonly HashSet<string> PlayableExtensions = new(StringComparer.OrdinalIgnoreCase)
        { "mkv", "mp4", "m4v", "mov", "ts", "m2ts", "avi", "webm" };

    public static string Ext(string name)
    {
        var e = Path.GetExtension(name);
        return e.Length > 1 ? e[1..].ToLowerInvariant() : "";
    }

    public static bool IsVideo(string name) => PlayableExtensions.Contains(Ext(name));

    /// <summary>去掉扩展名和追踪码（[auto-m550-r13]）以后的名字</summary>
    public static string Stem(string name)
    {
        var s = Path.GetFileNameWithoutExtension(name);
        return AutoTagRx().Replace(s, "");
    }

    /// <summary>年份取「最后一个」像年份的数：1917.2019 取 2019</summary>
    public static int? Year(string name)
    {
        var ms = YearRx().Matches(Stem(name));
        return ms.Count == 0 ? null : int.Parse(ms[^1].Groups[1].Value);
    }

    /// <summary>片名：年份（或第一个规格词）之前那一截，点与下划线换成空格</summary>
    public static string Title(string name)
    {
        var s = Stem(name);
        var end = s.Length;
        var ms = YearRx().Matches(s);
        if (ms.Count > 0 && ms[^1].Index > 0) end = Math.Min(end, ms[^1].Index);
        var c = CutRx().Match(s);
        if (c.Success && c.Index > 0) end = Math.Min(end, c.Index);
        var t = s[..end].Replace('.', ' ').Replace('_', ' ').Trim(' ', '-', '(', '[', '\t');
        return t.Length == 0 ? s : t;
    }

    /// <summary>详情页的规格徽标</summary>
    public static List<string> Specs(string name)
    {
        var n = name.ToLowerInvariant();
        bool Has(string p) => Regex.IsMatch(n, p);
        var o = new List<string>();
        if (Has("(^|[^0-9])(4320p|8k)([^0-9a-z]|$)")) o.Add("8K");
        else if (Has("(^|[^0-9])(2160p|4k|uhd)([^0-9a-z]|$)")) o.Add("4K");
        else if (Has("1080p")) o.Add("1080p");
        if (Has("(^|[^a-z])(dv|dovi|dolby[ ._]?vision)([^a-z]|$)")) o.Add("杜比视界");
        if (Has(@"hdr10\+|hdr10plus")) o.Add("HDR10+");
        else if (Has("(^|[^a-z])hdr(10)?([^a-z]|$)")) o.Add("HDR");
        if (Has("atmos")) o.Add("杜比全景声");
        else if (Has("truehd")) o.Add("TrueHD");
        else if (Has("dts[ ._-]?(hd|x)")) o.Add("DTS-HD");
        if (Has("remux")) o.Add("REMUX");
        if (Has("imax")) o.Add("IMAX");
        return o;
    }
}

/// <summary>TMDB 图片换尺寸：后端给的是 w342 / w780 / w1280 / w500，按要显示的像素换一档</summary>
public static partial class TmdbImage
{
    [GeneratedRegex(@"/t/p/(original|w[0-9]+|h[0-9]+)/")]
    private static partial Regex SizeRx();

    public static string? Url(string? raw, string size)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        if (raw.Contains("image.tmdb.org") && !raw.EndsWith(".svg", StringComparison.OrdinalIgnoreCase))
            return SizeRx().Replace(raw, $"/t/p/{size}/", 1);
        if (raw.StartsWith('/')) return $"https://image.tmdb.org/t/p/{size}{raw}";
        return raw.StartsWith("http") ? raw : null;
    }
}

/// <summary>Apple 图床（mzstatic）按宽度要图：末尾「宽x高[裁切码].格式」换一个宽度</summary>
public static partial class AppleImage
{
    [GeneratedRegex(@"/([0-9]+)x([0-9]+)([A-Za-z]*)\.([A-Za-z0-9]+)$")]
    private static partial Regex TailRx();

    /// <summary>ext：换格式（图床现做；背景要 jpg —— WebP 要系统装了解码器才显示得出来）</summary>
    public static string? Sized(string? raw, int width, string? ext = null)
    {
        if (string.IsNullOrEmpty(raw) || width <= 0 || !raw.Contains("mzstatic.com")) return raw;
        var m = TailRx().Match(raw);
        if (!m.Success || !int.TryParse(m.Groups[1].Value, out var w) || !int.TryParse(m.Groups[2].Value, out var h) || w <= 0 || h <= 0) return raw;
        var nh = (int)Math.Round((double)width * h / w);
        return raw[..m.Index] + $"/{width}x{nh}{m.Groups[3].Value}.{ext ?? m.Groups[4].Value}";
    }
}

public static class Format
{
    public static string Size(long? bytes)
    {
        if (bytes is not { } b || b <= 0) return "";
        return b >= 1L << 30 ? $"{b / (double)(1L << 30):0.0} GB" : $"{b / (double)(1L << 20):0} MB";
    }

    public static string Runtime(int? minutes)
    {
        if (minutes is not { } m || m <= 0) return "";
        int h = m / 60, r = m % 60;
        if (h > 0 && r > 0) return $"{h} 小时 {r} 分钟";
        return h > 0 ? $"{h} 小时" : $"{r} 分钟";
    }

    public static string Clock(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds <= 0) return "0:00";
        var s = (long)Math.Round(seconds);
        long h = s / 3600, m = s % 3600 / 60, sec = s % 60;
        return h > 0 ? $"{h}:{m:00}:{sec:00}" : $"{m}:{sec:00}";
    }

    public static string Speed(double bytesPerSecond) =>
        bytesPerSecond >= 1 << 20 ? $"{bytesPerSecond / (1 << 20):0.0} MB/s" : $"{bytesPerSecond / 1024:0} KB/s";
}
