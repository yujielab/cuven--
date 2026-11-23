using System.Text.Json;

namespace Cuven.Core;

// 请求添加（tj.cuven.us，代码在仓库的 request/）：片库里没有的那部，详情页的「播放」换成「请求添加」。
// 按下去请求添加 Worker 就接管整条链；App 这边只发请求、轮询进度（五步）。

public enum CatalogKind { Movie, Tv }

/// <summary>索引里的一部片 / 一部剧（还没在片库里）</summary>
public sealed record CatalogTitle(CatalogKind Kind, int Id, string Title, string Year, string? Poster)
{
    public string Src => Kind == CatalogKind.Tv ? "tv" : "movie";
}

public sealed record RequestSpec(string? Res, List<string>? Labels, string? Size)
{
    public static RequestSpec? From(JsonElement? e) =>
        e is { ValueKind: JsonValueKind.Object } x ? new RequestSpec(x.Str("res"), x.Strings("labels"), x.Str("size")) : null;
}

public enum RequestState { Active, Done, Failed, Cancelled }

/// <summary>进度里的一条（服务器的 view()）</summary>
public sealed class RequestStatus
{
    public static readonly string[] Labels = { "等待制片商", "等待回应", "等待品质管理", "等待传输", "最终发行审批" };

    public int Id { get; init; }
    public string Src { get; init; } = "movie";
    public int Tmdb { get; init; }
    public int Season { get; init; }
    public string Title { get; init; } = "";
    public string Year { get; init; } = "";
    public string? Poster { get; init; }
    public string Stage { get; init; } = "queued";
    public RequestState State { get; init; }
    public int Step { get; init; } = 1;
    public int Steps { get; init; } = 5;
    public int Pct { get; init; }
    public string Label { get; init; } = "";
    public string Note { get; init; } = "";
    public RequestSpec? Spec { get; init; }
    public double Updated { get; init; }

    public string Key => $"{Src}-{Tmdb}-{Season}";
    public CatalogTitle CatalogTitle => new(Src == "tv" ? CatalogKind.Tv : CatalogKind.Movie, Tmdb, Title, Year, Poster);

    public static RequestStatus? From(JsonElement? je)
    {
        if (je is not { ValueKind: JsonValueKind.Object } e || e.Int("id") is not { } id) return null;
        return new RequestStatus
        {
            Id = id,
            Src = e.Str("src") ?? "movie",
            Tmdb = e.Int("tmdb") ?? 0,
            Season = e.Int("season") ?? 0,
            Title = e.Str("title") ?? "",
            Year = e.Str("year") ?? "",
            Poster = e.Str("poster"),
            Stage = e.Str("stage") ?? "queued",
            State = (e.Str("state") ?? "active") switch { "done" => RequestState.Done, "failed" => RequestState.Failed, "cancelled" => RequestState.Cancelled, _ => RequestState.Active },
            Step = e.Int("step") ?? 1,
            Steps = e.Int("steps") ?? 5,
            Pct = e.Int("pct") ?? 0,
            Label = e.Str("label") ?? "",
            Note = e.Str("note") ?? "",
            Spec = RequestSpec.From(e.Get("spec")),
            Updated = e.Dbl("updated") ?? 0,
        };
    }

    /// <summary>给人看的一句状态</summary>
    public string Headline => State switch
    {
        RequestState.Done => "已就绪",
        RequestState.Failed => "没能添加",
        RequestState.Cancelled => "已取消",
        _ => Label.Length > 0 ? Label : Labels[Math.Clamp(Step - 1, 0, 4)],
    };
}

/// <summary>/app/catalog 的一条</summary>
public sealed record CatalogItem(int Id, string Src, string Title, string Year, string? Poster, double? Vote, string? Res, RequestStatus? Req)
{
    public CatalogTitle CatalogTitle => new(Src == "tv" ? CatalogKind.Tv : CatalogKind.Movie, Id, Title, Year, Poster);

    public static CatalogItem? From(JsonElement e) => e.Int("id") is not { } id ? null :
        new CatalogItem(id, e.Str("src") ?? "movie", e.Str("title") ?? "", e.Str("year") ?? "", e.Str("poster"), e.Dbl("vote"), e.Str("res"),
            RequestStatus.From(e.Get("req")));
}

/// <summary>/app/detail：有没有可请求的资源、每一季的进度</summary>
public sealed class CatalogDetail
{
    public int Id { get; init; }
    public string Src { get; init; } = "movie";
    public int Known { get; init; }
    public string? Title { get; init; }
    public string Year { get; init; } = "";
    public string? Poster { get; init; }
    public List<int> Seasons { get; init; } = new();
    public int Season { get; init; }
    public int Count { get; init; }
    public RequestSpec? Best { get; init; }
    public RequestStatus? Req { get; init; }
    public Dictionary<string, RequestStatus> Reqs { get; init; } = new();

    public static CatalogDetail From(JsonElement e)
    {
        var reqs = new Dictionary<string, RequestStatus>();
        if (e.Get("reqs") is { ValueKind: JsonValueKind.Object } ro)
            foreach (var p in ro.EnumerateObject()) if (RequestStatus.From(p.Value) is { } r) reqs[p.Name] = r;
        return new CatalogDetail
        {
            Id = e.Int("id") ?? 0,
            Src = e.Str("src") ?? "movie",
            Known = e.Int("known") ?? 0,
            Title = e.Str("title"),
            Year = e.Str("year") ?? "",
            Poster = e.Str("poster"),
            Seasons = e.Arr("seasons").Where(x => x.ValueKind == JsonValueKind.Number).Select(x => x.GetInt32()).ToList(),
            Season = e.Int("season") ?? 0,
            Count = e.Int("count") ?? 0,
            Best = RequestSpec.From(e.Get("best")),
            Req = RequestStatus.From(e.Get("req")),
            Reqs = reqs,
        };
    }
}

/// <summary>tj.cuven.us 的 App 接口</summary>
public static class RequestApi
{
    public const string Base = "https://tj.cuven.us";

    static IEnumerable<KeyValuePair<string, string>> User(string user) =>
        new[] { new KeyValuePair<string, string>("x-cuven-user", Http.Enc(user)) };

    static JsonDocument Check(Http.Reply r)
    {
        if (!r.Ok)
        {
            string? msg = null;
            try { using var d = r.Json(); msg = d?.RootElement.Str("error"); } catch { }
            throw new CuvenException(msg ?? "服务暂时不可用，请稍后再试。", r.Status);
        }
        return r.Json() ?? throw new CuvenException("出了点问题，请稍后再试。", r.Status);
    }

    public static async Task<List<CatalogItem>> CatalogAsync(string src = "all", string query = "", string sort = "new", string own = "all",
        int page = 1, CancellationToken ct = default)
    {
        var q = new List<(string, string)> { ("src", src), ("sort", sort), ("own", own), ("page", page.ToString()) };
        if (query.Length > 0) q.Add(("q", query));
        using var d = Check(await Http.GetAsync(Http.Url(Base, "/app/catalog", q.ToArray()), TimeSpan.FromSeconds(20), ct));
        return d.RootElement.Arr("items").Select(CatalogItem.From).OfType<CatalogItem>().ToList();
    }

    public static async Task<CatalogDetail> DetailAsync(CatalogTitle t, int? season, CancellationToken ct = default)
    {
        var q = new List<(string, string)> { ("src", t.Src), ("id", t.Id.ToString()) };
        if (season is > 0) q.Add(("season", season.Value.ToString()));
        using var d = Check(await Http.GetAsync(Http.Url(Base, "/app/detail", q.ToArray()), TimeSpan.FromSeconds(20), ct));
        return CatalogDetail.From(d.RootElement);
    }

    /// <summary>我的请求。带上次的 ETag：没变服务器回 304，这里回 items = null</summary>
    public static async Task<(List<RequestStatus>? items, string? etag)> MineAsync(string user, string? etag, CancellationToken ct = default)
    {
        var h = User(user).ToList();
        if (etag is not null) h.Add(new("If-None-Match", etag));
        var r = await Http.GetAsync(Http.Url(Base, "/app/requests"), TimeSpan.FromSeconds(20), ct, headers: h);
        if (r.Status == 304) return (null, etag);
        using var d = Check(r);
        var tag = r.Headers?.ETag?.ToString();
        return (d.RootElement.Arr("items").Select(x => RequestStatus.From(x)).OfType<RequestStatus>().ToList(), tag);
    }

    public static async Task<RequestStatus> CreateAsync(string user, CatalogTitle title, int season, CancellationToken ct = default)
    {
        object body = title.Kind == CatalogKind.Tv ? new { src = title.Src, id = title.Id, season } : new { src = title.Src, id = title.Id };
        using var d = Check(await Http.PostAsync(Http.Url(Base, "/app/requests"), body, TimeSpan.FromSeconds(20), ct, User(user)));
        return RequestStatus.From(d.RootElement.Get("request")) ?? throw new CuvenException("出了点问题，请稍后再试。");
    }
}
