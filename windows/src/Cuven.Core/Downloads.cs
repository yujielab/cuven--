using System.Net;
using System.Text.Json.Nodes;

namespace Cuven.Core;

public enum DownloadPhase { Queued, Downloading, Paused, Done, Failed, NoSpace }

/// <summary>一部下载：原文件整个存到本机（MKV 原样，所有音轨字幕都在），离线也能放</summary>
public sealed class DownloadItem
{
    public required string Path { get; init; }          // 片库路径
    public required string Name { get; init; }          // 文件名
    public required string Title { get; init; }
    public string? Poster { get; init; }
    public long Size { get; set; }
    public long Received { get; set; }
    public DownloadPhase Phase { get; set; }
    public string? Error { get; set; }
    public double Speed { get; set; }
    public required string LocalFile { get; init; }
    public DateTime Added { get; init; } = DateTime.UtcNow;
    /// <summary>用户自己按了暂停（重开 App 不自动接着下）</summary>
    public bool UserPaused { get; set; }
    public double Progress => Size > 0 ? Math.Clamp((double)Received / Size, 0, 1) : 0;
    internal CancellationTokenSource? Cts;
}

/// <summary>
/// 下载队列：最多两部同时下，HTTP Range 断点续传（.part 文件），掉线自动重试。
/// 每部在自己的线程上同步读写——App 在 WorkerThreadInit 里把这些线程设成 Win11 的 EcoQoS（排到能效核、不抢播放）
/// </summary>
public sealed class DownloadManager
{
    public static DownloadManager Shared { get; } = new();
    public static Action? WorkerThreadInit { get; set; }
    public const int MaxParallel = 2;

    public event Action<DownloadItem>? Updated;     // 任意线程
    public event Action? ListChanged;

    readonly object _lock = new();
    readonly List<DownloadItem> _items = new();

    DownloadManager() { Load(); }

    public IReadOnlyList<DownloadItem> Items { get { lock (_lock) return _items.ToList(); } }
    public DownloadItem? Find(string path) { lock (_lock) return _items.FirstOrDefault(i => i.Path == path); }

    /// <summary>已经整部下好的本机文件（播放时优先用）</summary>
    public string? LocalFileFor(string path)
    {
        var it = Find(path);
        return it is { Phase: DownloadPhase.Done } && File.Exists(it.LocalFile) ? it.LocalFile : null;
    }

    static string Safe(string name)
    {
        foreach (var c in System.IO.Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
        return name.Length > 180 ? name[..180] : name;
    }

    public DownloadItem Enqueue(string path, string name, string title, string? poster, long? size)
    {
        DownloadItem it;
        lock (_lock)
        {
            if (_items.FirstOrDefault(i => i.Path == path) is { } have)
            {
                if (have.Phase is DownloadPhase.Paused or DownloadPhase.Failed or DownloadPhase.NoSpace) have.Phase = DownloadPhase.Queued;
                it = have;
            }
            else
            {
                var local = System.IO.Path.Combine(Settings.Shared.DownloadFolder, Safe(name));
                it = new DownloadItem { Path = path, Name = name, Title = title, Poster = poster, Size = size ?? 0, LocalFile = local, Phase = DownloadPhase.Queued };
                _items.Insert(0, it);
            }
        }
        Save(); ListChanged?.Invoke(); Pump();
        return it;
    }

    public void Pause(string path)
    {
        var it = Find(path);
        if (it is null) return;
        it.UserPaused = true;
        it.Cts?.Cancel();
        if (it.Phase is DownloadPhase.Queued or DownloadPhase.Downloading) it.Phase = DownloadPhase.Paused;
        Save(); Updated?.Invoke(it); Pump();
    }

    public void Resume(string path)
    {
        var it = Find(path);
        if (it is null || it.Phase == DownloadPhase.Done) return;
        it.Phase = DownloadPhase.Queued; it.Error = null; it.UserPaused = false;
        Save(); Updated?.Invoke(it); Pump();
    }

    public void Delete(string path)
    {
        DownloadItem? it;
        lock (_lock) { it = _items.FirstOrDefault(i => i.Path == path); if (it is not null) _items.Remove(it); }
        if (it is null) return;
        it.Cts?.Cancel();
        _ = Task.Run(async () =>
        {
            await Task.Delay(500);
            foreach (var f in new[] { it.LocalFile, it.LocalFile + ".part" })
                try { if (File.Exists(f)) File.Delete(f); } catch { }
        });
        Save(); ListChanged?.Invoke(); Pump();
    }

    void Pump()
    {
        lock (_lock)
        {
            var running = _items.Count(i => i.Phase == DownloadPhase.Downloading);
            foreach (var it in _items.Where(i => i.Phase == DownloadPhase.Queued).Reverse().ToList())
            {
                if (running >= MaxParallel) break;
                it.Phase = DownloadPhase.Downloading;
                it.Cts = new CancellationTokenSource();
                running++;
                var t = new Thread(() => Run(it, it.Cts.Token)) { IsBackground = true, Name = "Cuven download", Priority = ThreadPriority.BelowNormal };
                t.Start();
            }
        }
    }

    void Run(DownloadItem it, CancellationToken ct)
    {
        WorkerThreadInit?.Invoke();
        int failures = 0;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                Transfer(it, ct);
                if (ct.IsCancellationRequested) break;
                it.Phase = DownloadPhase.Done; it.Speed = 0;
                break;
            }
            catch (OperationCanceledException) { break; }
            catch (IOException e) when (e.HResult == unchecked((int)0x80070070) || e.Message.Contains("space", StringComparison.OrdinalIgnoreCase))
            {
                it.Phase = DownloadPhase.NoSpace; it.Error = "储存空间不足"; break;
            }
            catch (NoSpaceException)
            {
                it.Phase = DownloadPhase.NoSpace; it.Error = "储存空间不足"; break;
            }
            catch (Exception e)
            {
                failures++;
                if (failures >= 6) { it.Phase = DownloadPhase.Failed; it.Error = CuvenException.Friendly(e); break; }
                try { Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 2 << failures)), ct).Wait(ct); } catch { break; }
            }
        }
        if (ct.IsCancellationRequested && it.Phase == DownloadPhase.Downloading) it.Phase = DownloadPhase.Paused;
        it.Speed = 0;
        Save(); Updated?.Invoke(it); Pump();
    }

    sealed class NoSpaceException : Exception { }

    void Transfer(DownloadItem it, CancellationToken ct)
    {
        var part = it.LocalFile + ".part";
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(part)!);
        long have = File.Exists(part) ? new FileInfo(part).Length : 0;
        var sign = StreamApi.StreamSignAsync(it.Path, ct).GetAwaiter().GetResult();
        var url = StreamApi.StreamUrl(it.Path, it.Name, sign);
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        if (have > 0) req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(have, null);
        req.Headers.Accept.Clear();
        req.Headers.TryAddWithoutValidation("Accept", "*/*");
        using var resp = Http.Client.Send(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (resp.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable && have > 0 && it.Size > 0 && have >= it.Size)
        {
            File.Move(part, it.LocalFile, true); it.Received = it.Size; return;
        }
        if (!resp.IsSuccessStatusCode) throw new CuvenException("下载服务暂时不可用", (int)resp.StatusCode);
        bool partial = resp.StatusCode == HttpStatusCode.PartialContent;
        if (!partial) have = 0;   // 服务器没按 Range 回（缓存刚填）：从头来
        var total = resp.Content.Headers.ContentRange?.Length ?? (resp.Content.Headers.ContentLength is { } cl ? cl + have : it.Size);
        if (total > 0) it.Size = total;

        // 空间不够就别开始（留 1 GB 余量）
        try
        {
            var root = System.IO.Path.GetPathRoot(System.IO.Path.GetFullPath(part));
            if (root is not null && it.Size > 0 && new DriveInfo(root).AvailableFreeSpace < it.Size - have + (1L << 30)) throw new NoSpaceException();
        }
        catch (NoSpaceException) { throw; }
        catch { }

        using var src = resp.Content.ReadAsStream(ct);
        using var dst = new FileStream(part, partial ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read, 1 << 20);
        var buf = new byte[1 << 20];
        it.Received = have;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        long lastBytes = have; var lastTick = 0L; var lastSave = 0L;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            int n = src.Read(buf, 0, buf.Length);
            if (n <= 0) break;
            dst.Write(buf, 0, n);
            it.Received += n;
            var now = sw.ElapsedMilliseconds;
            if (now - lastTick >= 250)
            {
                it.Speed = (it.Received - lastBytes) * 1000.0 / Math.Max(1, now - lastTick);
                lastBytes = it.Received; lastTick = now;
                Updated?.Invoke(it);
            }
            if (now - lastSave >= 5000) { lastSave = now; Save(); }
        }
        dst.Flush();
        dst.Close();
        if (it.Size > 0 && it.Received < it.Size) throw new IOException("连接断了");
        File.Move(part, it.LocalFile, true);
    }

    void Load()
    {
        if (Storage.ReadJson("downloads.json") is not JsonArray a) return;
        foreach (var n in a)
        {
            if (n is not JsonObject o || (string?)o["path"] is not { } p || (string?)o["file"] is not { } f) continue;
            var it = new DownloadItem
            {
                Path = p, Name = (string?)o["name"] ?? System.IO.Path.GetFileName(f), Title = (string?)o["title"] ?? "", Poster = (string?)o["poster"],
                Size = (long?)o["size"] ?? 0, LocalFile = f,
                Added = DateTime.TryParse((string?)o["added"], null, System.Globalization.DateTimeStyles.RoundtripKind, out var t) ? t : DateTime.UtcNow,
            };
            var done = (bool?)o["done"] == true && File.Exists(f);
            it.Phase = done ? DownloadPhase.Done : DownloadPhase.Paused;
            it.UserPaused = (bool?)o["paused"] == true;
            it.Received = done ? it.Size : File.Exists(f + ".part") ? new FileInfo(f + ".part").Length : 0;
            _items.Add(it);
        }
    }

    void Save()
    {
        JsonArray a;
        lock (_lock)
            a = new JsonArray(_items.Select(i => (JsonNode)new JsonObject
            {
                ["path"] = i.Path, ["name"] = i.Name, ["title"] = i.Title, ["poster"] = i.Poster, ["size"] = i.Size,
                ["file"] = i.LocalFile, ["done"] = i.Phase == DownloadPhase.Done, ["paused"] = i.UserPaused, ["added"] = i.Added.ToString("o"),
            }).ToArray());
        Storage.WriteJson("downloads.json", a);
    }

    /// <summary>App 启动时：上次没下完的接着下</summary>
    public void ResumeAll()
    {
        lock (_lock) foreach (var i in _items.Where(i => i.Phase == DownloadPhase.Paused && !i.UserPaused)) i.Phase = DownloadPhase.Queued;
        Pump();
    }
}
