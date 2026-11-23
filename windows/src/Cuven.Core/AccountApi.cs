using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Cuven.Core;

/// <summary>登录成功拿到的东西：用户名、邮箱（可能没有）、设备令牌（d1.…；这台电脑不要，恒为 null）、识别代码（c1.…，5 分钟）</summary>
public sealed record LoginResult(string Username, string Email, string? Device, string? Code, string Method);

public enum LoginError { None, Wrong, NoAccount, NoPassword, Throttled, Offline, Server }

public sealed class LoginFailure : Exception
{
    public LoginError Kind { get; }
    public LoginFailure(LoginError kind, string message) : base(message) { Kind = kind; }
}

/// <summary>口令 v3：本机算 PBKDF2-SHA256，只把 key 交给账号中心核对，密码不离开这台电脑</summary>
public static class PasswordKey
{
    public const int DefaultIterations = 310_000;

    public static string B64u(ReadOnlySpan<byte> b) => Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static byte[] FromB64u(string s)
    {
        var t = s.Replace('-', '+').Replace('_', '/');
        t += (t.Length % 4) switch { 2 => "==", 3 => "=", _ => "" };
        return Convert.FromBase64String(t);
    }

    /// <summary>key = base64url(PBKDF2-SHA256(密码, base64url 解出来的 salt, iter, 32 字节))，和网页版 keyOf 一致</summary>
    public static string Derive(string password, string saltB64u, int iterations)
    {
        var bits = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), FromB64u(saltB64u),
            iterations > 0 ? iterations : DefaultIterations, HashAlgorithmName.SHA256, 32);
        return B64u(bits);
    }
}

/// <summary>账号中心（https://check.cuven.us）</summary>
public static class AccountApi
{
    public const string Base = "https://check.cuven.us";
    static string U(string path) => Base + path;

    // 识别代码（c1.…，5 分钟）：写账户档时带上（账号中心开了 STRICT_AUTH 以后必需）
    static (string code, DateTime until)? _identity;
    public static void Remember(string? code)
    {
        if (code is not null && code.StartsWith("c1.")) _identity = (code, DateTime.UtcNow.AddSeconds(280));
    }
    static IEnumerable<KeyValuePair<string, string>>? AuthHeaders() =>
        _identity is { } i && i.until > DateTime.UtcNow ? new[] { new KeyValuePair<string, string>("Authorization", "Bearer " + i.code) } : null;

    public sealed record PassParams(string Salt, int Iter, string? LegacyHash);
    public sealed record Account(bool Exists, string? Email, PassParams? Pass);

    /// <summary>账户在不在；在的话带上邮箱和口令参数（离线 → 抛 LoginFailure(Offline)）</summary>
    public static async Task<Account> CheckAsync(string name, CancellationToken ct = default)
    {
        Http.Reply r;
        try { r = await Http.GetAsync(U("/check/" + Http.Enc(name)), TimeSpan.FromSeconds(15), ct, noCache: true); }
        catch (CuvenException) { throw new LoginFailure(LoginError.Offline, "连不上账号中心，请检查网络后重试"); }
        if (r.Status == 0 || r.Status >= 500) throw new LoginFailure(LoginError.Offline, "账号中心暂时不可用，请稍后再试");
        using var d = r.Json();
        if (d is null || d.RootElement.Bool("exists") != true) return new Account(false, null, null);
        var data = d.RootElement.Get("data");
        if (data is null)
        {
            var f = await Http.GetAsync(U("/file/" + Http.Enc($"username_{name}.json")), TimeSpan.FromSeconds(15), ct, noCache: true);
            using var fd = f.Ok ? f.Json() : null;
            if (fd is not null) return new Account(true, fd.RootElement.Str("email"), Pass(fd.RootElement));
            return new Account(true, null, null);
        }
        return new Account(true, data.Value.Str("email"), Pass(data.Value));
    }

    static PassParams? Pass(JsonElement rec)
    {
        var p = rec.Get("pass");
        if (p is null || p.Value.ValueKind != JsonValueKind.Object) return null;
        var salt = p.Value.Str("salt") ?? p.Value.Str("s") ?? "";
        var iter = p.Value.Int("iter") ?? p.Value.Int("iterations") ?? p.Value.Int("n") ?? PasswordKey.DefaultIterations;
        return salt.Length == 0 ? null : new PassParams(salt, iter, p.Value.Str("hash"));
    }

    /// <summary>口令参数：新版账号中心有 /auth/params（不认识的用户名也给一份稳定的假参数），旧版从账户档读</summary>
    public static async Task<PassParams?> ParamsAsync(string name, CancellationToken ct = default)
    {
        try
        {
            var r = await Http.GetAsync(U("/auth/params/" + Http.Enc(name)), TimeSpan.FromSeconds(15), ct, noCache: true);
            using var d = r.Ok ? r.Json() : null;
            if (d is not null && d.RootElement.Str("salt") is { Length: > 0 } salt)
                return new PassParams(salt, d.RootElement.Int("iter") ?? PasswordKey.DefaultIterations, null);
        }
        catch (CuvenException) { }
        return null;
    }

    /// <summary>
    /// 账户密码登录：查账户 → 拿 salt / iter → 本机算 key → /session 核对（拿识别代码）。
    /// 不领设备令牌：它能批准别的设备登录，电脑上用不着、也不该留着。
    /// 旧版账号中心不认 key 时退回账户档里的摘要比对（和网页版、iOS 一致）
    /// </summary>
    public static async Task<LoginResult> PasswordLoginAsync(string username, string password, CancellationToken ct = default)
    {
        username = username.Trim();
        var acct = await CheckAsync(username, ct);
        if (!acct.Exists) throw new LoginFailure(LoginError.NoAccount, "没有这个账户");
        var pass = await ParamsAsync(username, ct) ?? acct.Pass;
        if (pass is null) throw new LoginFailure(LoginError.NoPassword, "这个账户还没有设置密码，请在 iPhone 上扫码登录");

        var key = await Task.Run(() => PasswordKey.Derive(password, pass.Salt, pass.Iter), ct);
        Http.Reply r;
        try
        {
            r = await Http.PostAsync(U("/session"), new { username, key }, TimeSpan.FromSeconds(20), ct);
        }
        catch (CuvenException)
        {
            if (acct.Pass?.LegacyHash is { Length: > 0 } h0 && h0 == key) return Done(null);
            throw new LoginFailure(LoginError.Offline, "连不上账号中心，请检查网络后重试");
        }
        using var d = r.Json();
        var root = d?.RootElement;
        if (root?.Bool("ok") == true) return Done(root.Value);
        var err = root?.Str("error");
        if (err == "bad_credentials") throw new LoginFailure(LoginError.Wrong, "密码不正确，请重试");
        if (err == "rate_limited") throw new LoginFailure(LoginError.Throttled, root?.Str("message") ?? "尝试太多次了，15 分钟后再试");
        // 旧版账号中心：本机比对账户档里的摘要
        if (acct.Pass?.LegacyHash is { Length: > 0 } h && h == key) return Done(null);
        if (acct.Pass?.LegacyHash is { Length: > 0 }) throw new LoginFailure(LoginError.Wrong, "密码不正确，请重试");
        throw new LoginFailure(LoginError.Server, "账号中心暂时不可用，请稍后再试");

        LoginResult Done(JsonElement? ok)
        {
            var code = ok?.Str("code");
            Remember(code);
            return new LoginResult(username, acct.Email ?? "", null, code, "password");
        }
    }

    /// <summary>账户通知（登录提醒邮件等）：收件人 / IP / 设备 / 时间由服务端解析；失败不影响任何流程</summary>
    public static void Notify(string type, string username, string? method = null)
    {
        _ = Task.Run(async () =>
        {
            try { await Http.SendAsync(HttpMethod.Post, U("/notify"), new { type, username, method }, TimeSpan.FromSeconds(15), AuthHeaders()); }
            catch { }
        });
    }

    /// <summary>头像地址：账户设置里选的默认头像或自己上传的</summary>
    public static async Task<string?> AvatarAsync(string username, CancellationToken ct = default)
    {
        try
        {
            var r = await Http.GetAsync(U("/settings/" + Http.Enc(username)), TimeSpan.FromSeconds(10), ct);
            using var d = r.Ok ? r.Json() : null;
            var av = d?.RootElement.Get("settings")?.Get("avatar");
            if (av is null) return null;
            if (av.Value.Str("type") == "custom") return U("/user/" + Http.Enc(username) + "?v=" + DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 3600);
            return av.Value.Str("id") is { Length: > 0 } id ? U("/default/" + Http.Enc(id)) : null;
        }
        catch { return null; }
    }
}

/// <summary>
/// 光学配对（要登录的这台电脑这一边）：/pair/open → 显示粒子云 → /pair/wait 长轮询 → iPhone 扫到、面容 ID 批准 → 拿到账户。
/// 快到期还没人扫：先开好下一团换上，再关掉旧的；wait 回 open / approved 以外的（过期 / 取消 / 用过 / 不认识）→ 马上不画旧码，再开一团。
/// 这台电脑不要设备令牌（open 不带 want_device、wait 不带 device）。Stop 时 /pair/cancel
/// </summary>
public sealed class PairLogin : IDisposable
{
    public sealed record Opened(uint Id, uint Secret, string Poll, string Code, int Ttl);

    public event Action<Opened>? CodeChanged;          // 换了一团码（UI 线程外）
    public event Action? CodeCleared;                  // 旧码作废了、新的还没到：别再画它（UI 线程外）
    public event Action<string>? StatusChanged;        // "" = 不写字
    public event Action<LoginResult>? Approved;

    const int MaxWaitMs = 20_000;      // 服务端一次最多挂 20 秒
    const int RotateMs = 8_000;        // 离到期不到 8 秒、还没人扫：换下一团
    // wait 的客户端超时 = 挂的时间 + 这么多（服务端读写、网络往返）。20 + 6 秒再隔半秒重试：
    // 回包悄悄丢了（NAT 掐了连接）的那次批准，重试落在服务端 30 秒的重发窗口里
    const int SlackMs = 6_000;
    const int RedeliverMs = 35_000;    // 过期以后一直连不上：再试这么久（批准了的回包丢了，服务端 30 秒内照样再给），之后另开一团

    readonly CancellationTokenSource _cts = new();
    readonly string _device;
    readonly string _base;
    Opened? _cur;                      // 正显示的那一团（Stop 时要关掉它）；Interlocked 读写
    /// <param name="baseUrl">只给测试用（本机假的账号中心）；默认 check.cuven.us</param>
    public PairLogin(string deviceName, string? baseUrl = null) { _device = deviceName; _base = baseUrl ?? AccountApi.Base; }

    public void Start()
    {
        _ = Task.Run(PairCodec.Prepare);   // 码纹理的稀疏基底和 /pair/open 的往返一起算
        _ = Task.Run(LoopAsync);
    }

    static long Now => Environment.TickCount64;

    /// <summary>开出来的一团 + 本机（单调时钟）上的到期时刻：服务端的 exp 按开出来那一刻的时差换算，不怕电脑的钟不准</summary>
    sealed class Live
    {
        public required Opened O { get; init; }
        public long ExpAt;          // Environment.TickCount64
        public long? Offset;        // 服务端毫秒 → 本机；旧版不回 exp 时为 null（只按 ttl 算）
        public bool Peeked;         // 上一次 wait 说有人扫到了（服务端已经延了期，别换掉它）
        public bool RotateTried;    // 提前换过一次（没开出来就等它过期）
        public void Update(long? serverExp) { if (Offset is { } off && serverExp is > 0 and { } e) ExpAt = e + off; }
    }

    async Task LoopAsync()
    {
        var ct = _cts.Token;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                StatusChanged?.Invoke("正在准备…");
                var l = await OpenAsync(false, ct);
                if (l is null) { await Delay(5000, ct); continue; }
                if (!Show(l)) return;
                if (await WatchAsync(l, ct)) return;
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>开一团；quiet = 提前换的那次，失败不写字</summary>
    async Task<Live?> OpenAsync(bool quiet, CancellationToken ct)
    {
        try
        {
            var r = await Http.PostAsync(_base + "/pair/open", new { device = _device }, TimeSpan.FromSeconds(15), ct);
            var at = Now;
            using var d = r.Json();
            var e = d?.RootElement;
            if (e?.Bool("ok") == true && e.Value.UInt("id") is { } id && e.Value.UInt("secret") is { } sec && e.Value.Str("poll") is { Length: > 0 } poll)
            {
                var ttl = Math.Clamp(e.Value.Int("ttl") ?? 120, 10, 600);
                var l = new Live { O = new Opened(id, sec, poll, e.Value.Str("code") ?? "", ttl), ExpAt = at + ttl * 1000L };
                if (e.Value.Long("exp") is > 0 and { } exp) l.Offset = l.ExpAt - exp;
                return l;
            }
            if (!quiet) StatusChanged?.Invoke(e?.Str("message") ?? "暂时连不上，稍后再试");
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { if (!quiet) StatusChanged?.Invoke("暂时连不上，稍后再试"); }
        return null;
    }

    /// <summary>换上这一团；已经停了就顺手关掉它 → false</summary>
    bool Show(Live l)
    {
        Interlocked.Exchange(ref _cur, l.O);
        if (_cts.IsCancellationRequested)
        {
            if (Interlocked.Exchange(ref _cur, null) is { } o) Cancel(o);
            return false;
        }
        CodeChanged?.Invoke(l.O);
        StatusChanged?.Invoke("");
        return true;
    }

    /// <summary>盯着一团：登录了 / 停了 → true；作废了 → false（外面再开一团）</summary>
    async Task<bool> WatchAsync(Live l, CancellationToken ct)
    {
        bool cleared = false;
        while (!ct.IsCancellationRequested)
        {
            var left = l.ExpAt - Now;
            // 快到期、还没人扫：先开好下一团换上，再关掉旧的（只试一次；开不出来就等旧的过期）
            if (!l.Peeked && !l.RotateTried && left < RotateMs)
            {
                l.RotateTried = true;
                var n = await OpenAsync(true, ct);
                if (n is not null)
                {
                    var old = l.O;
                    if (!Show(n)) { Cancel(old); return true; }
                    Cancel(old);
                    l = n;
                    cleared = false;
                    continue;
                }
                left = l.ExpAt - Now;
            }
            // 还没人扫：只挂到该换的时候；扫过了（或者换不成）：挂满，让服务端说什么时候过期
            int waitMs = l.Peeked || l.RotateTried ? MaxWaitMs : (int)Math.Clamp(left - RotateMs, 0, MaxWaitMs);
            Http.Reply r;
            try
            {
                r = await Http.PostAsync(_base + "/pair/wait", new { id = l.O.Id, poll = l.O.Poll, wait = waitMs },
                    TimeSpan.FromMilliseconds(waitMs + SlackMs), ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return true; }
            catch
            {
                if (await Retry()) continue;
                return false;
            }
            using var d = r.Json();
            var e = d?.RootElement;
            var st = e?.Str("status");
            if (st == "approved" && e is { } ok && ok.Str("username") is { Length: > 0 } user)
            {
                Interlocked.CompareExchange(ref _cur, null, l.O);
                if (ct.IsCancellationRequested) return true;     // 已经停了（切到密码页 / 关掉了）：不登录
                var code = ok.Str("code");
                AccountApi.Remember(code);
                // 设备令牌不收：没要，服务端也不会给
                Approved?.Invoke(new LoginResult(user, ok.Str("email") ?? "", null, code, "pair"));
                return true;
            }
            if (st == "open" && e is { } op)
            {
                l.Update(op.Long("exp"));
                l.Peeked = op.Bool("peeked") == true;
                continue;
            }
            // 没有 status 的 5xx / 429 / 不是 JSON：算网络问题，同一团接着问
            if (st is null && (d is null || r.Status == 429 || r.Status >= 500))
            {
                if (await Retry()) continue;
                return false;
            }
            // 过期 / 取消 / 用过 / 作废 / 不认识（404）：马上不画旧码，外面再开一团
            Interlocked.CompareExchange(ref _cur, null, l.O);
            CodeCleared?.Invoke();
            return false;
        }
        return true;

        // 连不上 / 超时：同一团接着问（批准了的回包丢了，服务端 30 秒内照样再给）。
        // 过了期就先别画它；过期太久还连不上 → false（另开一团）
        async Task<bool> Retry()
        {
            var now = Now;
            if (now > l.ExpAt + RedeliverMs)
            {
                Interlocked.CompareExchange(ref _cur, null, l.O);
                if (!cleared) CodeCleared?.Invoke();
                return false;
            }
            if (now > l.ExpAt && !cleared) { cleared = true; CodeCleared?.Invoke(); }
            await Delay(500, ct);
            return true;
        }
    }

    void Cancel(Opened o) => _ = Task.Run(async () =>
    {
        try { await Http.PostAsync(_base + "/pair/cancel", new { id = o.Id, poll = o.Poll }, TimeSpan.FromSeconds(10)); } catch { }
    });

    static async Task Delay(int ms, CancellationToken ct)
    {
        try { await Task.Delay(ms, ct); } catch (OperationCanceledException) { }
    }

    public void Stop()
    {
        if (_cts.IsCancellationRequested) return;
        _cts.Cancel();
        if (Interlocked.Exchange(ref _cur, null) is { } o) Cancel(o);
    }

    public void Dispose() => Stop();
}
