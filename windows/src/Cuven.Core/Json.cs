using System.Text.Json;

namespace Cuven.Core;

/// <summary>
/// 宽松地读后端的 JSON（和 iOS 的 Models.swift 一个规矩）：后端多一个字段、某个字段换了类型（数字 ↔ 字符串），
/// 都不该让整份片库解不出来。读不到就是 null。
/// </summary>
public static class J
{
    public static JsonElement? Get(this JsonElement e, string key)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        return e.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null && v.ValueKind != JsonValueKind.Undefined ? v : null;
    }

    public static string? Str(this JsonElement e, string key)
    {
        var v = e.Get(key);
        if (v is null) return null;
        return v.Value.ValueKind switch
        {
            JsonValueKind.String => v.Value.GetString(),
            JsonValueKind.Number => v.Value.GetRawText(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => null,
        };
    }

    public static int? Int(this JsonElement e, string key)
    {
        var v = e.Get(key);
        if (v is null) return null;
        var x = v.Value;
        if (x.ValueKind == JsonValueKind.Number)
        {
            if (x.TryGetInt32(out var i)) return i;
            if (x.TryGetDouble(out var d) && double.IsFinite(d) && Math.Abs(d) < int.MaxValue) return (int)d;
            return null;
        }
        if (x.ValueKind == JsonValueKind.String && int.TryParse(x.GetString(), out var s)) return s;
        return null;
    }

    public static long? Long(this JsonElement e, string key)
    {
        var v = e.Get(key);
        if (v is null) return null;
        var x = v.Value;
        if (x.ValueKind == JsonValueKind.Number)
        {
            if (x.TryGetInt64(out var i)) return i;
            if (x.TryGetDouble(out var d) && double.IsFinite(d)) return (long)d;
            return null;
        }
        if (x.ValueKind == JsonValueKind.String && long.TryParse(x.GetString(), out var s)) return s;
        return null;
    }

    public static uint? UInt(this JsonElement e, string key)
    {
        var l = e.Long(key);
        return l is >= 0 and <= uint.MaxValue ? (uint)l.Value : null;
    }

    public static double? Dbl(this JsonElement e, string key)
    {
        var v = e.Get(key);
        if (v is null) return null;
        var x = v.Value;
        if (x.ValueKind == JsonValueKind.Number && x.TryGetDouble(out var d)) return d;
        if (x.ValueKind == JsonValueKind.String && double.TryParse(x.GetString(), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var s)) return s;
        return null;
    }

    public static bool? Bool(this JsonElement e, string key)
    {
        var v = e.Get(key);
        if (v is null) return null;
        return v.Value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.Number => v.Value.TryGetDouble(out var d) && d != 0,
            JsonValueKind.String => v.Value.GetString() is "1" or "true",
            _ => null,
        };
    }

    public static IEnumerable<JsonElement> Arr(this JsonElement e, string key)
    {
        var v = e.Get(key);
        if (v is null || v.Value.ValueKind != JsonValueKind.Array) yield break;
        foreach (var x in v.Value.EnumerateArray()) yield return x;
    }

    public static List<string>? Strings(this JsonElement e, string key)
    {
        var v = e.Get(key);
        if (v is null || v.Value.ValueKind != JsonValueKind.Array) return null;
        var list = new List<string>();
        foreach (var x in v.Value.EnumerateArray())
            if (x.ValueKind == JsonValueKind.String && x.GetString() is { } s) list.Add(s);
        return list;
    }

    /// <summary>JSON 的字符串转义（写本机缓存用）</summary>
    public static string Quote(string s) => JsonSerializer.Serialize(s);
}
