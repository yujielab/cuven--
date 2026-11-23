namespace Cuven.Core;

/// <summary>
/// 我的请求：轮询 tj.cuven.us/app/requests（带 ETag，没变回 304），状态一变通知 App（App 发 Windows 通知）。
/// 有进行中的 20 秒一次，否则 2 分钟一次；连着失败按 2 的倍数放慢，最慢 10 分钟
/// </summary>
public sealed class RequestCenter
{
    public static RequestCenter Shared { get; } = new();

    public event Action? Changed;
    /// <summary>（请求, 新状态的说法）：只在进入最终发行审批、已就绪、没能添加时</summary>
    public event Action<RequestStatus, string>? Milestone;

    readonly object _lock = new();
    List<RequestStatus> _mine = new();
    readonly Dictionary<string, RequestStatus> _known = new();
    Dictionary<int, string> _seen = new();
    string? _etag, _user;
    int _failures;
    CancellationTokenSource? _loop;

    RequestCenter()
    {
        if (Storage.ReadJson("requests-seen.json") is System.Text.Json.Nodes.JsonObject o)
            foreach (var (k, v) in o) if (int.TryParse(k, out var id) && (string?)v is { } s) _seen[id] = s;
    }

    public IReadOnlyList<RequestStatus> Mine { get { lock (_lock) return _mine; } }
    public int ActiveCount { get { lock (_lock) return _mine.Count(m => m.State == RequestState.Active); } }

    public RequestStatus? Status(string src, int id, int season)
    {
        lock (_lock)
        {
            var key = $"{src}-{id}-{season}";
            var all = _mine.Where(m => m.Key == key).Concat(_known.Values.Where(m => m.Key == key)).ToList();
            return all.FirstOrDefault(m => m.State == RequestState.Active) ?? all.OrderByDescending(m => m.Id).FirstOrDefault();
        }
    }

    public void Note(RequestStatus? r)
    {
        if (r is null) return;
        lock (_lock) _known[r.Key + "#" + r.Id] = r;
    }

    public void Start(string user)
    {
        Stop();
        _user = user; _etag = null;
        var cts = _loop = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                await RefreshAsync(cts.Token);
                var active = ActiveCount > 0;
                var wait = TimeSpan.FromSeconds(active ? 20 : 120) * Math.Pow(2, Math.Min(_failures, 5));
                if (wait > TimeSpan.FromMinutes(10)) wait = TimeSpan.FromMinutes(10);
                try { await Task.Delay(wait, cts.Token); } catch (OperationCanceledException) { return; }
            }
        });
    }

    public void Stop() { _loop?.Cancel(); _loop = null; lock (_lock) _mine = new(); }

    public async Task RefreshAsync(CancellationToken ct = default)
    {
        if (_user is null) return;
        try
        {
            var (items, tag) = await RequestApi.MineAsync(_user, _etag, ct);
            _failures = 0;
            if (items is null) return;
            _etag = tag;
            Apply(items);
        }
        catch (OperationCanceledException) { }
        catch { _failures++; }
    }

    void Apply(List<RequestStatus> items)
    {
        var events = new List<(RequestStatus, string)>();
        lock (_lock)
        {
            _mine = items.OrderByDescending(i => i.Id).ToList();
            foreach (var r in items)
            {
                var sig = r.Stage + "|" + r.State;
                if (_seen.TryGetValue(r.Id, out var old) && old != sig)
                {
                    if (r.State == RequestState.Done) events.Add((r, "已就绪，现在就能播放"));
                    else if (r.State == RequestState.Failed) events.Add((r, "没能添加"));
                    else if (r.Stage == "release" && !old.StartsWith("release")) events.Add((r, "进入最终发行审批"));
                }
                _seen[r.Id] = sig;
            }
            var o = new System.Text.Json.Nodes.JsonObject();
            foreach (var (k, v) in _seen) o[k.ToString()] = v;
            Storage.WriteJson("requests-seen.json", o);
        }
        Changed?.Invoke();
        foreach (var (r, s) in events)
        {
            Milestone?.Invoke(r, s);
            if (r.State == RequestState.Done) _ = Task.Run(async () => { await StreamApi.AutoSyncAsync(); await LibraryStore.Shared.RefreshAsync(); });
        }
    }

    public async Task<RequestStatus> CreateAsync(CatalogTitle t, int season)
    {
        if (_user is null) throw new CuvenException("请先登录");
        var r = await RequestApi.CreateAsync(_user, t, season);
        lock (_lock)
        {
            _mine = new[] { r }.Concat(_mine.Where(m => m.Id != r.Id)).ToList();
            _seen[r.Id] = r.Stage + "|" + r.State;
        }
        Changed?.Invoke();
        return r;
    }
}
