using System.Text.Json;

namespace Cuven.Core;

// 后端（Stream Worker，https://stream.cuven.online）回包的形状，和 iOS 的 Models.swift 一一对应。
// 每个类型都有 From(JsonElement)（宽松解）和 Write(Utf8JsonWriter)（写本机缓存）。

public sealed record Video(string Name, string Path, long? Size, string? Modified, string? Added)
{
    public string AddedKey => Added ?? Modified ?? "";

    public static Video? From(JsonElement e)
    {
        var path = e.Str("path") ?? "";
        if (path.Length == 0) return null;
        return new Video(e.Str("name") ?? System.IO.Path.GetFileName(path), path, e.Long("size"), e.Str("modified"), e.Str("added"));
    }

    public void Write(Utf8JsonWriter w)
    {
        w.WriteStartObject();
        w.WriteString("name", Name); w.WriteString("path", Path);
        if (Size is { } s) w.WriteNumber("size", s);
        if (Modified is { } m) w.WriteString("modified", m);
        if (Added is { } a) w.WriteString("added", a);
        w.WriteEndObject();
    }
}

public sealed record LibraryFolder(string Name, string Path)
{
    public static LibraryFolder? From(JsonElement e)
    {
        var path = e.Str("path") ?? "";
        return path.Length == 0 ? null : new LibraryFolder(e.Str("name") ?? System.IO.Path.GetFileName(path.TrimEnd('/')), path);
    }
}

public sealed class LibraryPayload
{
    public string? Root { get; init; }
    public List<Video> Videos { get; init; } = new();
    public List<LibraryFolder> Folders { get; init; } = new();

    public static LibraryPayload From(JsonElement e) => new()
    {
        Root = e.Str("root"),
        Videos = e.Arr("videos").Select(Video.From).OfType<Video>().ToList(),
        Folders = e.Arr("folders").Select(LibraryFolder.From).OfType<LibraryFolder>().ToList(),
    };
}

public sealed record CastMember(int? Id, string Name, string? Character, string? ProfilePath)
{
    public string? ProfileUrl => string.IsNullOrEmpty(ProfilePath) ? null
        : ProfilePath.StartsWith("http") ? ProfilePath : "https://image.tmdb.org/t/p/w185" + ProfilePath;

    public static CastMember From(JsonElement e) => new(e.Int("id"), e.Str("name") ?? "", e.Str("character"), e.Str("profile_path"));
}

public sealed record Still(string? Url, string? Thumb)
{
    public static Still From(JsonElement e) => new(e.Str("url"), e.Str("thumb"));
}

/// <summary>TMDB 元数据（/api/tmdb、/api/tmdb-batch）。原样留着那段 JSON，写缓存时照抄</summary>
public sealed class Meta
{
    public int? Id { get; init; }
    public string? Title { get; init; }
    public string? En { get; init; }
    public string? OriginalTitle { get; init; }
    public string? Year { get; init; }
    public string? ReleaseDate { get; init; }
    public string? Poster { get; init; }
    public string? PosterClean { get; init; }
    public string? Backdrop { get; init; }
    public string? BackdropClean { get; init; }
    public string? Logo { get; init; }
    public string? Overview { get; init; }
    public double? Rating { get; init; }
    public string? Type { get; init; }
    public int? Runtime { get; init; }
    public List<string>? Genres { get; init; }
    public List<CastMember>? Cast { get; init; }
    public string? Director { get; init; }
    public List<Still>? Stills { get; init; }
    public string? OriginalLanguage { get; init; }
    public string Raw { get; init; } = "{}";

    public bool HasArt => !string.IsNullOrEmpty(Poster) || !string.IsNullOrEmpty(PosterClean);

    public static Meta From(JsonElement e) => new()
    {
        Id = e.Int("id"),
        Title = e.Str("title"),
        En = e.Str("en"),
        OriginalTitle = e.Str("original_title"),
        Year = e.Str("year"),
        ReleaseDate = e.Str("release_date"),
        Poster = e.Str("poster"),
        PosterClean = e.Str("posterClean"),
        Backdrop = e.Str("backdrop"),
        BackdropClean = e.Str("backdropClean"),
        Logo = e.Str("logo"),
        Overview = e.Str("overview"),
        Rating = e.Dbl("rating"),
        Type = e.Str("type"),
        Runtime = e.Int("runtime"),
        Genres = e.Strings("genres"),
        Cast = e.Get("cast") is { ValueKind: JsonValueKind.Array } ? e.Arr("cast").Select(CastMember.From).Where(c => c.Name.Length > 0).ToList() : null,
        Director = e.Str("director"),
        Stills = e.Get("stills") is { ValueKind: JsonValueKind.Array } ? e.Arr("stills").Select(Still.From).ToList() : null,
        OriginalLanguage = e.Str("original_language"),
        Raw = e.GetRawText(),
    };
}

/// <summary>剧集的一季（/api/tv 的 series 里一项）</summary>
public sealed class Series
{
    public string Id { get; init; } = "";
    public string Path { get; init; } = "";
    public string? Folder { get; init; }
    public string? Title { get; init; }
    public string? Zh { get; init; }
    public string? En { get; init; }
    public int? Season { get; init; }
    public string? SeasonLabel { get; init; }
    public string? Year { get; init; }
    public string? Res { get; init; }
    public string? Hdr { get; init; }
    public List<string>? Tags { get; init; }
    public string? Audio { get; init; }
    public bool? Full { get; init; }
    public int? TmdbId { get; init; }
    public bool? TmdbMiss { get; init; }
    public int? Episodes { get; init; }
    public int? Total { get; init; }
    public long? Size { get; init; }
    public string? Added { get; init; }
    public string Raw { get; init; } = "{}";

    public string Name => Title ?? Zh ?? En ?? Folder ?? "剧集";

    public static Series? From(JsonElement e)
    {
        var path = e.Str("path") ?? "";
        if (path.Length == 0) return null;
        return new Series
        {
            Path = path,
            Id = e.Str("id") ?? path,
            Folder = e.Str("folder"),
            Title = e.Str("title"),
            Zh = e.Str("zh"),
            En = e.Str("en"),
            Season = e.Int("season"),
            SeasonLabel = e.Str("seasonLabel"),
            Year = e.Str("year"),
            Res = e.Str("res"),
            Hdr = e.Str("hdr"),
            Tags = e.Strings("tags"),
            Audio = e.Str("audio"),
            Full = e.Bool("full"),
            TmdbId = e.Int("tmdbId"),
            TmdbMiss = e.Bool("tmdbMiss"),
            Episodes = e.Int("episodes"),
            Total = e.Int("total"),
            Size = e.Long("size"),
            Added = e.Str("added"),
            Raw = e.GetRawText(),
        };
    }
}

public sealed record EpisodeFile(int? Ep, string Path, string Name, long? Size)
{
    public static EpisodeFile? From(JsonElement e)
    {
        var path = e.Str("path") ?? "";
        return path.Length == 0 ? null : new EpisodeFile(e.Int("ep"), path, e.Str("name") ?? System.IO.Path.GetFileName(path), e.Long("size"));
    }
}

public sealed record SeasonEpisode(int? Ep, string? Name, string? Overview, string? Still, int? Runtime, string? AirDate)
{
    public static SeasonEpisode From(JsonElement e) =>
        new(e.Int("ep"), e.Str("name"), e.Str("overview"), e.Str("still"), e.Int("runtime"), e.Str("air_date"));
}

/// <summary>首页大图（/api/atv/hero）</summary>
public sealed record Hero(string Path, string? Name, string? Title, string? Type, int? Year, string? Background, string? Poster, string? Logo)
{
    public static Hero? From(JsonElement e)
    {
        var path = e.Str("path") ?? "";
        return path.Length == 0 ? null : new Hero(path, e.Str("name"), e.Str("title"), e.Str("type"), e.Int("year"),
            e.Str("background"), e.Str("poster"), e.Str("logo"));
    }
}

/// <summary>/api/stream-sign：生产环境没开签名时 exp / sig 是 null</summary>
public sealed record StreamSign(string? Exp, string? Sig, string? Hls)
{
    public static StreamSign From(JsonElement e) => new(e.Str("exp"), e.Str("sig"), e.Str("hls"));
}

/// <summary>/api/subs 的一条外挂 / 在线字幕（url 是 /api/subs/vtt?…，回 WebVTT）</summary>
public sealed record SubTrack(string Name, string Label, string? Lang, string Url, bool Online)
{
    public static SubTrack? From(JsonElement e)
    {
        var url = e.Str("url") ?? "";
        if (url.Length == 0) return null;
        var label = e.Str("label") ?? e.Str("name") ?? "字幕";
        return new SubTrack(e.Str("name") ?? label, label, e.Str("srclang"), url, e.Bool("online") == true);
    }
}
