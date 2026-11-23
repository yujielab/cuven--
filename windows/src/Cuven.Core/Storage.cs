using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cuven.Core;

/// <summary>本机目录：%LOCALAPPDATA%\Cuven（缓存、设置、下载）。未打包的桌面程序没有 ApplicationData，用普通文件夹</summary>
public static class Storage
{
    static string? _root;
    public static string Root
    {
        get
        {
            if (_root is null)
            {
                var b = Environment.GetEnvironmentVariable("CUVEN_HOME");
                if (string.IsNullOrEmpty(b))
                    b = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cuven");
                Directory.CreateDirectory(b);
                _root = b;
            }
            return _root;
        }
        set { _root = value; Directory.CreateDirectory(value); }
    }

    public static string Dir(string name)
    {
        var d = Path.Combine(Root, name);
        Directory.CreateDirectory(d);
        return d;
    }

    /// <summary>原子写：先写 .tmp 再换名（断电不会留半个文件）</summary>
    public static void WriteAtomic(string path, ReadOnlySpan<byte> data)
    {
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, data.ToArray());
        File.Move(tmp, path, true);
    }

    public static JsonNode? ReadJson(string name)
    {
        try
        {
            var p = Path.Combine(Root, name);
            return File.Exists(p) ? JsonNode.Parse(File.ReadAllBytes(p)) : null;
        }
        catch { return null; }
    }

    public static void WriteJson(string name, JsonNode node)
    {
        try { WriteAtomic(Path.Combine(Root, name), JsonSerializer.SerializeToUtf8Bytes(node)); } catch { }
    }
}

/// <summary>机密怎么加密存：Windows 上用 DPAPI（App 里接上），测试里原样。设备令牌已经不存了（开机删掉旧的 device.bin）</summary>
public interface ISecretProtector
{
    byte[] Protect(byte[] plain);
    byte[]? Unprotect(byte[] sealedData);
}

sealed class PlainProtector : ISecretProtector
{
    public byte[] Protect(byte[] plain) => plain;
    public byte[]? Unprotect(byte[] s) => s;
}

/// <summary>登录状态 + 偏好（settings.json）。设备令牌不再存（以前的版本加密存在 device.bin，启动时删掉）</summary>
public sealed class Settings
{
    public static Settings Shared { get; } = Load();
    public static ISecretProtector Protector { get; set; } = new PlainProtector();

    public string? Username { get; set; }
    public string? Email { get; set; }
    public string? Method { get; set; }
    public DateTime? SignedInAt { get; set; }
    /// <summary>auto：显示器开了 HDR 就输出 HDR；sdr：一律映射成 SDR</summary>
    public string HdrMode { get; set; } = "auto";
    public bool HardwareDecode { get; set; } = true;
    /// <summary>首选音轨：natural = 原声；zh = 国语 / 粤语优先</summary>
    public string AudioPref { get; set; } = "natural";
    public bool SubtitlesOn { get; set; } = true;
    public double Volume { get; set; } = 1.0;
    /// <summary>节能（Win11 EcoQoS）：下载、预取、图片解码放到能效核上</summary>
    public bool Efficiency { get; set; } = true;
    public string? DownloadDir { get; set; }

    public bool SignedIn => !string.IsNullOrEmpty(Username);
    public string DownloadFolder => string.IsNullOrEmpty(DownloadDir) ? Storage.Dir("Downloads") : DownloadDir!;

    static Settings Load()
    {
        var s = new Settings();
        if (Storage.ReadJson("settings.json") is JsonObject o)
        {
            s.Username = (string?)o["username"];
            s.Email = (string?)o["email"];
            s.Method = (string?)o["method"];
            if (DateTime.TryParse((string?)o["at"], null, System.Globalization.DateTimeStyles.RoundtripKind, out var at)) s.SignedInAt = at;
            s.HdrMode = (string?)o["hdr"] ?? "auto";
            s.HardwareDecode = (bool?)o["hwdec"] ?? true;
            s.AudioPref = (string?)o["audio"] ?? "natural";
            s.SubtitlesOn = (bool?)o["subs"] ?? true;
            s.Volume = (double?)o["volume"] ?? 1.0;
            s.Efficiency = (bool?)o["eco"] ?? true;
            s.DownloadDir = (string?)o["downloads"];
        }
        s.DeviceToken = null;   // 这台电脑不再存设备令牌：以前存下的 device.bin 启动时删掉
        return s;
    }

    public void Save()
    {
        var o = new JsonObject
        {
            ["username"] = Username, ["email"] = Email, ["method"] = Method, ["at"] = SignedInAt?.ToString("o"),
            ["hdr"] = HdrMode, ["hwdec"] = HardwareDecode, ["audio"] = AudioPref, ["subs"] = SubtitlesOn,
            ["volume"] = Volume, ["eco"] = Efficiency, ["downloads"] = DownloadDir,
        };
        Storage.WriteJson("settings.json", o);
    }

    /// <summary>设备令牌（能批准别的设备登录）：电脑上用不着，只剩删掉旧文件这一个用处；读出来的只有旧版留下的</summary>
    public string? DeviceToken
    {
        get
        {
            try
            {
                var p = Path.Combine(Storage.Root, "device.bin");
                if (!File.Exists(p)) return null;
                var b = Protector.Unprotect(File.ReadAllBytes(p));
                var t = b is null ? null : System.Text.Encoding.UTF8.GetString(b);
                return t is not null && t.StartsWith("d1.") ? t : null;
            }
            catch { return null; }
        }
        set
        {
            var p = Path.Combine(Storage.Root, "device.bin");
            try
            {
                if (string.IsNullOrEmpty(value)) { if (File.Exists(p)) File.Delete(p); return; }
                Storage.WriteAtomic(p, Protector.Protect(System.Text.Encoding.UTF8.GetBytes(value)));
            }
            catch { }
        }
    }

    public void SignIn(LoginResult r)
    {
        Username = r.Username; Email = r.Email; Method = r.Method; SignedInAt = DateTime.UtcNow;
        DeviceToken = null;     // 不留设备令牌（也就不会有上一个账户的令牌留到这个账户）
        Save();
    }

    public void SignOut()
    {
        Username = null; Email = null; Method = null; SignedInAt = null; DeviceToken = null;
        Save();
    }
}

/// <summary>播放进度（「继续观看」那一排、再打开从上次的地方接着放）</summary>
public sealed class PlaybackHistory
{
    public static PlaybackHistory Shared { get; } = new();
    public sealed record Entry(string Path, string Name, string Title, double Position, double Duration, DateTime Updated, string? SeriesPath);

    readonly Dictionary<string, Entry> _map = new();
    readonly object _lock = new();

    PlaybackHistory()
    {
        if (Storage.ReadJson("history.json") is JsonArray a)
            foreach (var n in a)
            {
                if (n is not JsonObject o || (string?)o["path"] is not { } p) continue;
                _map[p] = new Entry(p, (string?)o["name"] ?? "", (string?)o["title"] ?? "", (double?)o["pos"] ?? 0, (double?)o["dur"] ?? 0,
                    DateTime.TryParse((string?)o["t"], null, System.Globalization.DateTimeStyles.RoundtripKind, out var t) ? t : DateTime.MinValue,
                    (string?)o["series"]);
            }
    }

    public Entry? Get(string path) { lock (_lock) return _map.GetValueOrDefault(path); }

    /// <summary>接着放的位置：看了 30 秒以上、没看到 95%</summary>
    public double ResumeAt(string path)
    {
        var e = Get(path);
        return e is not null && e.Position > 30 && (e.Duration <= 0 || e.Position / e.Duration < 0.95) ? e.Position : 0;
    }

    public void Record(string path, string name, string title, double pos, double dur, string? seriesPath = null)
    {
        lock (_lock) _map[path] = new Entry(path, name, title, pos, dur, DateTime.UtcNow, seriesPath);
    }

    public List<Entry> ContinueWatching(int max = 20)
    {
        lock (_lock)
            return _map.Values.Where(e => e.Position > 30 && (e.Duration <= 0 || e.Position / e.Duration < 0.95))
                .OrderByDescending(e => e.Updated).Take(max).ToList();
    }

    public void Save()
    {
        JsonArray a;
        lock (_lock)
            a = new JsonArray(_map.Values.OrderByDescending(e => e.Updated).Take(500).Select(e => (JsonNode)new JsonObject
            {
                ["path"] = e.Path, ["name"] = e.Name, ["title"] = e.Title, ["pos"] = e.Position, ["dur"] = e.Duration,
                ["t"] = e.Updated.ToString("o"), ["series"] = e.SeriesPath,
            }).ToArray());
        Storage.WriteJson("history.json", a);
    }
}
