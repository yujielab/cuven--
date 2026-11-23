using System.Text.Json;

namespace Cuven.Core;

/// <summary>直连 Stream Worker（https://stream.cuven.online）的接口，和 iOS 的 APIClient 一一对应</summary>
public static class StreamApi
{
    public const string Base = "https://stream.cuven.online";

    static string U(string path, params (string, string)[] q) => Http.Url(Base, path, q);

    public static async Task<LibraryPayload> LibraryAsync(CancellationToken ct = default)
    {
        using var d = Http.Expect(await Http.GetAsync(U("/api/all"), TimeSpan.FromSeconds(30), ct, noCache: true));
        return LibraryPayload.From(d.RootElement);
    }

    /// <summary>一个文件夹里的子文件夹与视频</summary>
    public static async Task<(List<LibraryFolder> folders, List<Video> videos)> ListAsync(string path, CancellationToken ct = default)
    {
        using var d = Http.Expect(await Http.GetAsync(U("/api/list", ("path", path)), TimeSpan.FromSeconds(15), ct));
        var folders = new List<LibraryFolder>(); var videos = new List<Video>();
        foreach (var it in d.RootElement.Arr("items"))
        {
            if (it.Str("type") == "folder") { if (LibraryFolder.From(it) is { } f) folders.Add(f); }
            else if (Video.From(it) is { } v && FileName.IsVideo(v.Name)) videos.Add(v);
        }
        return (folders, videos);
    }

    /// <summary>
    /// 一批文件名 → TMDB。回包里值为 null = 后端确定认不出（不显示）；没有这个键 = 这次没问成（过会儿再问）。
    /// 返回的字典里：Meta = 认出来了；null = 认不出
    /// </summary>
    public static async Task<Dictionary<string, Meta?>> MetaBatchAsync(IReadOnlyList<string> names, bool full = false, CancellationToken ct = default)
    {
        var queries = names.Select(n => full ? (object)new { name = n, logo = true } : new { name = n }).ToArray();
        using var d = Http.Expect(await Http.PostAsync(U("/api/tmdb-batch"), new { queries }, TimeSpan.FromSeconds(40), ct));
        var o = new Dictionary<string, Meta?>();
        if (d.RootElement.ValueKind != JsonValueKind.Object) return o;
        foreach (var p in d.RootElement.EnumerateObject())
        {
            if (p.Name.StartsWith("__")) continue;
            if (p.Value.ValueKind == JsonValueKind.Null) o[p.Name] = null;
            else if (p.Value.ValueKind == JsonValueKind.Object) o[p.Name] = Meta.From(p.Value);
        }
        return o;
    }

    /// <summary>单条 TMDB（剧集按剧集表认好的编号取，详情页要字标 / 纯净海报 / 剧照）</summary>
    public static async Task<Meta?> TmdbAsync(string query, string? year, string? type, int? id, bool full, CancellationToken ct = default)
    {
        var q = new List<(string, string)> { ("query", query), ("language", "zh-CN") };
        if (full) { q.Add(("logo", "1")); q.Add(("include_image_language", "zh,en,null")); }
        if (!string.IsNullOrEmpty(year)) q.Add(("year", year));
        if (type is not null) q.Add(("type", type));
        if (id is { } i) q.Add(("id", i.ToString()));
        var r = await Http.GetAsync(U("/api/tmdb", q.ToArray()), TimeSpan.FromSeconds(20), ct);
        using var d = Http.Expect(r);
        return d.RootElement.ValueKind == JsonValueKind.Object ? Meta.From(d.RootElement) : null;
    }

    /// <summary>剧集表（不用本机缓存：请求添加刚就绪的那一季要马上能播）</summary>
    public static async Task<List<Series>> TvListAsync(CancellationToken ct = default)
    {
        using var d = Http.Expect(await Http.GetAsync(U("/api/tv"), TimeSpan.FromSeconds(30), ct, noCache: true));
        return d.RootElement.Arr("series").Select(Series.From).OfType<Series>().ToList();
    }

    public static async Task<List<EpisodeFile>> EpisodesAsync(string seriesPath, CancellationToken ct = default)
    {
        using var d = Http.Expect(await Http.GetAsync(U("/api/tv/episodes", ("path", seriesPath)), TimeSpan.FromSeconds(25), ct));
        return d.RootElement.Arr("episodes").Select(EpisodeFile.From).OfType<EpisodeFile>().ToList();
    }

    public static async Task<List<SeasonEpisode>> SeasonAsync(int tmdbId, int season, CancellationToken ct = default)
    {
        using var d = Http.Expect(await Http.GetAsync(U("/api/tmdb/season", ("id", tmdbId.ToString()), ("season", season.ToString())),
            TimeSpan.FromSeconds(20), ct));
        return d.RootElement.Arr("episodes").Select(SeasonEpisode.From).ToList();
    }

    public static async Task<List<Hero>> HeroesAsync(CancellationToken ct = default)
    {
        using var d = Http.Expect(await Http.GetAsync(U("/api/atv/hero"), TimeSpan.FromSeconds(20), ct));
        return d.RootElement.Arr("heroes").Select(Hero.From).OfType<Hero>().ToList();
    }

    /// <summary>请片库马上重看一眼 /auto（请求添加刚就绪、片库清单里还没有这一部时）。出错不管</summary>
    public static async Task AutoSyncAsync()
    {
        try { await Http.SendAsync(HttpMethod.Post, U("/api/auto/sync", ("tv", "1")), "{}", TimeSpan.FromSeconds(20)); } catch { }
    }

    public static async Task<StreamSign> StreamSignAsync(string path, CancellationToken ct = default)
    {
        using var d = Http.Expect(await Http.GetAsync(U("/api/stream-sign", ("path", path)), TimeSpan.FromSeconds(12), ct, noCache: true));
        return StreamSign.From(d.RootElement);
    }

    /// <summary>
    /// 原文件直链（Windows 版自己解 MKV / HEVC / TrueHD，不走 HLS 重封装）：文件名只是装饰，后端只认 ?path=。
    /// 签名只盖路径，换主机名照样有效
    /// </summary>
    public static string StreamUrl(string path, string name, StreamSign? sign, string? baseUrl = null)
    {
        var ext = FileName.Ext(name);
        var q = new List<(string, string)> { ("path", path) };
        if (!string.IsNullOrEmpty(sign?.Exp) && !string.IsNullOrEmpty(sign?.Sig)) { q.Add(("exp", sign.Exp)); q.Add(("sig", sign.Sig)); }
        return Http.Url(baseUrl ?? Base, "/stream/Cuven." + (ext.Length == 0 ? "mkv" : ext), q.ToArray());
    }

    /// <summary>外挂字幕 + 在线字幕（OpenSubtitles 找来的那一条）。warm：让后台先去找，立刻回</summary>
    public static async Task<List<SubTrack>> SubsAsync(string path, bool warm = false, CancellationToken ct = default)
    {
        var q = warm ? new[] { ("path", path), ("warm", "1") } : new[] { ("path", path) };
        try
        {
            using var d = Http.Expect(await Http.GetAsync(U("/api/subs", q), TimeSpan.FromSeconds(warm ? 15 : 30), ct, noCache: true));
            return d.RootElement.Arr("subs").Select(SubTrack.From).OfType<SubTrack>().ToList();
        }
        catch (CuvenException) { return new(); }
    }

    /// <summary>一条字幕（WebVTT 文本）</summary>
    public static async Task<string?> SubTextAsync(SubTrack t, CancellationToken ct = default)
    {
        var url = t.Url.StartsWith("http") ? t.Url : Base + t.Url;
        var r = await Http.GetAsync(url, TimeSpan.FromSeconds(30), ct);
        return r.Ok ? r.Text : null;
    }
}
