using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cuven.Core;

/// <summary>片库里的一部电影（同一部的几个版本——4K / 1080p——合成一项）</summary>
public sealed class Movie
{
    public required Video Video { get; init; }
    public required Meta Meta { get; init; }
    public List<Video> Versions { get; init; } = new();
    public string Title => Meta.Title ?? FileName.Title(Video.Name);
    public string? Year => Meta.Year ?? FileName.Year(Video.Name)?.ToString();
    public string? PosterUrl(string size = "w342") => TmdbImage.Url(Meta.Poster ?? Meta.PosterClean, size);
    public string? BackdropUrl(string size = "w1280") => TmdbImage.Url(Meta.Backdrop ?? Meta.BackdropClean, size);
}

/// <summary>
/// 片库：/api/all（电影文件）+ /api/tmdb-batch（每个文件名问一次 TMDB）+ /api/tv（剧集）+ /api/atv/hero（首页大图）。
/// 上次的结果存在本机，开 App 先画缓存，后台再刷新（和 iOS 的 LibraryStore 一样）
/// </summary>
public sealed class LibraryStore
{
    public static LibraryStore Shared { get; } = new();

    public event Action? Changed;

    readonly object _lock = new();
    List<Video> _videos = new();
    Dictionary<string, Meta> _metas = new();
    HashSet<string> _hidden = new();
    List<Series> _series = new();
    Dictionary<string, Meta> _seriesMetas = new();
    List<Hero> _heroes = new();
    List<Movie> _movies = new();
    Task? _refresh;

    public bool Loaded { get; private set; }
    public string? Error { get; private set; }

    public IReadOnlyList<Movie> Movies { get { lock (_lock) return _movies; } }
    public IReadOnlyList<Series> Series { get { lock (_lock) return _series; } }
    public IReadOnlyList<Hero> Heroes { get { lock (_lock) return _heroes; } }
    public Meta? SeriesMeta(Series s) { lock (_lock) return _seriesMetas.GetValueOrDefault(s.Path); }
    public Meta? MetaFor(string name) { lock (_lock) return _metas.GetValueOrDefault(name); }
    public Movie? MovieByPath(string path) { lock (_lock) return _movies.FirstOrDefault(m => m.Versions.Any(v => v.Path == path)); }
    public Movie? MovieByTmdb(int id) { lock (_lock) return _movies.FirstOrDefault(m => m.Meta.Id == id); }
    public Series? SeriesByTmdb(int id, int season = 0)
    {
        lock (_lock) return _series.FirstOrDefault(s => (s.TmdbId ?? _seriesMetas.GetValueOrDefault(s.Path)?.Id) == id && (season == 0 || s.Season == season));
    }

    LibraryStore() { LoadCache(); }

    void LoadCache()
    {
        try
        {
            if (Storage.ReadJson("cache/library.json") is JsonObject lib)
            {
                var doc = JsonDocument.Parse(lib.ToJsonString());
                _videos = LibraryPayload.From(doc.RootElement).Videos;
            }
            if (Storage.ReadJson("cache/metas.json") is JsonObject metas)
                foreach (var (k, v) in metas)
                    if (v is not null) _metas[k] = Meta.From(JsonDocument.Parse(v.ToJsonString()).RootElement);
            if (Storage.ReadJson("cache/hidden.json") is JsonArray hid)
                foreach (var h in hid) if ((string?)h is { } s) _hidden.Add(s);
            if (Storage.ReadJson("cache/series.json") is JsonArray ser)
                _series = ser.Select(n => n is null ? null : Core.Series.From(JsonDocument.Parse(n.ToJsonString()).RootElement)).OfType<Series>().ToList();
            if (Storage.ReadJson("cache/series-metas.json") is JsonObject sm)
                foreach (var (k, v) in sm)
                    if (v is not null) _seriesMetas[k] = Meta.From(JsonDocument.Parse(v.ToJsonString()).RootElement);
            if (Storage.ReadJson("cache/heroes.json") is JsonArray he)
                _heroes = he.Select(n => n is null ? null : Hero.From(JsonDocument.Parse(n.ToJsonString()).RootElement)).OfType<Hero>().ToList();
            Rebuild();
            Loaded = _videos.Count > 0;
        }
        catch { }
    }

    void SaveCache()
    {
        try
        {
            Storage.Dir("cache");
            List<Video> vids; Dictionary<string, Meta> metas; HashSet<string> hidden; List<Series> series; Dictionary<string, Meta> sm;
            lock (_lock) { vids = _videos; metas = new(_metas); hidden = new(_hidden); series = _series; sm = new(_seriesMetas); }
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartObject(); w.WriteStartArray("videos");
                    foreach (var v in vids) v.Write(w);
                    w.WriteEndArray(); w.WriteEndObject();
                }
                Storage.WriteAtomic(Path.Combine(Storage.Root, "cache/library.json"), ms.ToArray());
            }
            var mo = new JsonObject();
            foreach (var (k, m) in metas) mo[k] = JsonNode.Parse(m.Raw);
            Storage.WriteJson("cache/metas.json", mo);
            Storage.WriteJson("cache/hidden.json", new JsonArray(hidden.Select(h => (JsonNode)JsonValue.Create(h)!).ToArray()));
            Storage.WriteJson("cache/series.json", new JsonArray(series.Select(s => JsonNode.Parse(s.Raw)).ToArray()));
            var so = new JsonObject();
            foreach (var (k, m) in sm) so[k] = JsonNode.Parse(m.Raw);
            Storage.WriteJson("cache/series-metas.json", so);
        }
        catch { }
    }

    /// <summary>电影列表：有 TMDB、有海报的；同一部（TMDB 编号相同）的几个文件合成一项，最新入库的那个当代表</summary>
    void Rebuild()
    {
        var groups = new Dictionary<string, Movie>();
        var order = new List<Movie>();
        foreach (var v in _videos)
        {
            if (!_metas.TryGetValue(v.Name, out var m) || !m.HasArt) continue;
            var key = m.Id is { } id ? "id:" + id : "name:" + v.Name;
            if (groups.TryGetValue(key, out var g)) { g.Versions.Add(v); continue; }
            var mv = new Movie { Video = v, Meta = m, Versions = new List<Video> { v } };
            groups[key] = mv; order.Add(mv);
        }
        foreach (var mv in order)
            mv.Versions.Sort((a, b) => (b.Size ?? 0).CompareTo(a.Size ?? 0));   // 版本：大的（规格高的）在前
        _movies = order;
    }

    public Task RefreshAsync() { lock (_lock) return _refresh is { IsCompleted: false } ? _refresh : _refresh = Task.Run(DoRefresh); }

    async Task DoRefresh()
    {
        try
        {
            var lib = await StreamApi.LibraryAsync();
            var vids = lib.Videos.Where(v => FileName.IsVideo(v.Name)).OrderByDescending(v => v.AddedKey, StringComparer.Ordinal).ToList();
            lock (_lock) { _videos = vids; Rebuild(); }
            Loaded = true; Error = null;
            Changed?.Invoke();
        }
        catch (Exception e)
        {
            Error = CuvenException.Friendly(e);
            Changed?.Invoke();
            if (!Loaded) return;
        }
        await Task.WhenAll(LoadMetasAsync(), RefreshSeriesAsync(), RefreshHeroesAsync());
        SaveCache();
    }

    /// <summary>每个文件名问一次 TMDB（一次 80 个，两路并发）。没回答的过一会儿再问，最多三轮</summary>
    async Task LoadMetasAsync()
    {
        for (int round = 0; round < 3; round++)
        {
            List<string> need;
            lock (_lock) need = _videos.Select(v => v.Name).Where(n => !_metas.ContainsKey(n) && !_hidden.Contains(n)).Distinct().ToList();
            if (need.Count == 0) return;
            var chunks = need.Chunk(80).ToList();
            for (int i = 0; i < chunks.Count; i += 2)
            {
                var group = chunks.Skip(i).Take(2).Select(async c =>
                {
                    try { return await StreamApi.MetaBatchAsync(c); } catch { return new Dictionary<string, Meta?>(); }
                }).ToList();
                var results = await Task.WhenAll(group);
                lock (_lock)
                {
                    foreach (var r in results)
                        foreach (var (name, meta) in r)
                        {
                            if (meta is { HasArt: true }) { _metas[name] = meta; _hidden.Remove(name); }
                            else _hidden.Add(name);
                        }
                    Rebuild();
                }
                Changed?.Invoke();
            }
            await Task.Delay(8000);
        }
    }

    async Task RefreshSeriesAsync()
    {
        try
        {
            var list = await StreamApi.TvListAsync();
            var ser = list.Where(s => s.TmdbMiss != true && (s.Episodes ?? 0) > 0).OrderByDescending(s => s.Added ?? "", StringComparer.Ordinal).ToList();
            lock (_lock) _series = ser;
            Changed?.Invoke();
            // 先取最新的 48 部（首页那排要海报），其余慢慢补
            var sem = new SemaphoreSlim(4);
            var tasks = ser.Select(async s =>
            {
                await sem.WaitAsync();
                try { await EnsureSeriesMetaAsync(s); } finally { sem.Release(); }
            }).ToList();
            await Task.WhenAll(tasks);
            Changed?.Invoke();
        }
        catch { }
    }

    public async Task<Meta?> EnsureSeriesMetaAsync(Series s, bool force = false)
    {
        lock (_lock) if (!force && _seriesMetas.TryGetValue(s.Path, out var have)) return have;
        var q = s.En ?? s.Zh ?? s.Title ?? s.Folder ?? "";
        try
        {
            var m = await StreamApi.TmdbAsync(q, s.Year, "tv", s.TmdbId, full: true);
            if (m is not null) lock (_lock) _seriesMetas[s.Path] = m;
            return m;
        }
        catch { return null; }
    }

    async Task RefreshHeroesAsync()
    {
        try
        {
            var list = await StreamApi.HeroesAsync();
            if (list.Count == 0) return;
            lock (_lock) _heroes = list;
            Storage.Dir("cache");
            Storage.WriteJson("cache/heroes.json", new JsonArray(list.Select(h => JsonSerializer.SerializeToNode(new
            {
                path = h.Path, name = h.Name, title = h.Title, type = h.Type, year = h.Year, background = h.Background, poster = h.Poster, logo = h.Logo,
            })).ToArray()));
            Changed?.Invoke();
        }
        catch { }
    }

    /// <summary>详情页要的全量 TMDB（字标、演员、剧照）</summary>
    public async Task<Meta?> FullMetaAsync(Movie m)
    {
        try
        {
            var r = await StreamApi.MetaBatchAsync(new[] { m.Video.Name }, full: true);
            return r.GetValueOrDefault(m.Video.Name) ?? m.Meta;
        }
        catch { return m.Meta; }
    }

    /// <summary>搜索：中文名、英文名、原名、文件名</summary>
    public (List<Movie> movies, List<Series> series) Search(string q)
    {
        q = q.Trim();
        if (q.Length == 0) return (new(), new());
        bool Hit(string? s) => s is not null && s.Contains(q, StringComparison.OrdinalIgnoreCase);
        lock (_lock)
        {
            var mv = _movies.Where(m => Hit(m.Meta.Title) || Hit(m.Meta.En) || Hit(m.Meta.OriginalTitle) || Hit(m.Video.Name)).Take(60).ToList();
            var se = _series.Where(s => Hit(s.Title) || Hit(s.Zh) || Hit(s.En) || Hit(s.Folder) || Hit(_seriesMetas.GetValueOrDefault(s.Path)?.Title)).Take(40).ToList();
            return (mv, se);
        }
    }

    public List<string> Genres()
    {
        lock (_lock)
            return _movies.SelectMany(m => m.Meta.Genres ?? new List<string>()).GroupBy(g => g).OrderByDescending(g => g.Count())
                .Select(g => g.Key).Take(12).ToList();
    }

    public List<Movie> MoviesInGenre(string g) { lock (_lock) return _movies.Where(m => m.Meta.Genres?.Contains(g) == true).ToList(); }
}
