using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Cuven.Core;

/// <summary>登录成功拿到的东西：用户名、邮箱（可能没有）、设备令牌（d1.…，长期）、识别代码（c1.…，5 分钟）</summary>
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
    /// 账户密码登录：查账户 → 拿 salt / iter → 本机算 key → /session 核对（领设备令牌）。
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
            r = await Http.PostAsync(U("/session"), new { username, key, device = true }, TimeSpan.FromSeconds(20), ct);
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
            var device = ok?.Str("device");
            return new LoginResult(username, acct.Email ?? "", device is { } t && t.StartsWith("d1.") ? t : null, code, "password");
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
/// 过期 / 作废了自动换一团；Stop 时 /pair/cancel
/// </summary>
public sealed class PairLogin : IDisposable
{
    public sealed record Opened(uint Id, uint Secret, string Poll, string Code, int Ttl);

    public event Action<Opened>? CodeChanged;          // 换了一团码（UI 线程外）
    public event Action<string>? StatusChanged;        // "" = 不写字
    public event Action<LoginResult>? Approved;

    readonly CancellationTokenSource _cts = new();
    readonly string _device;
    Opened? _cur;
    public PairLogin(string deviceName) { _device = deviceName; }

    public void Start() => _ = Task.Run(LoopAsync);

    async Task LoopAsync()
    {
        var ct = _cts.Token;
        while (!ct.IsCancellationRequested)
        {
            StatusChanged?.Invoke("正在准备…");
            Opened? o = null;
            try
            {
                var r = await Http.PostAsync(AccountApi.Base + "/pair/open", new { device = _device }, TimeSpan.FromSeconds(15), ct);
                using var d = r.Json();
                var e = d?.RootElement;
                if (e?.Bool("ok") == true && e.Value.UInt("id") is { } id && e.Value.UInt("secret") is { } sec)
                    o = new Opened(id, sec, e.Value.Str("poll") ?? "", e.Value.Str("code") ?? "", e.Value.Int("ttl") ?? 120);
                else StatusChanged?.Invoke(e?.Str("message") ?? "暂时连不上，稍后再试");
            }
            catch (OperationCanceledException) { return; }
            catch { StatusChanged?.Invoke("暂时连不上，稍后再试"); }
            if (o is null) { await Delay(5000, ct); continue; }
            _cur = o;
            CodeChanged?.Invoke(o);
            StatusChanged?.Invoke("");
            // 长轮询：open → 接着等；approved → 登录；其他（过期 / 作废 / 取消）→ 换一团
            while (!ct.IsCancellationRequested)
            {
                JsonDocument? d = null;
                try
                {
                    var r = await Http.PostAsync(AccountApi.Base + "/pair/wait", new { id = o.Id, poll = o.Poll }, TimeSpan.FromSeconds(35), ct);
                    d = r.Json();
                }
                catch (OperationCanceledException) { return; }
                catch { await Delay(2000, ct); continue; }
                using (d)
                {
                    var e = d?.RootElement;
                    var st = e?.Str("status");
                    if (st == "approved" && e is { } ok)
                    {
                        _cur = null;
                        var code = ok.Str("code");
                        AccountApi.Remember(code);
                        var dev = ok.Str("device");
                        Approved?.Invoke(new LoginResult(ok.Str("username") ?? "", ok.Str("email") ?? "",
                            dev is { } t && t.StartsWith("d1.") ? t : null, code, "pair"));
                        return;
                    }
                    if (st == "open") continue;
                    if (d is null) { await Delay(2000, ct); continue; }
                    break;
                }
            }
        }
    }

    static async Task Delay(int ms, CancellationToken ct)
    {
        try { await Task.Delay(ms, ct); } catch (OperationCanceledException) { }
    }

    public void Stop()
    {
        if (_cts.IsCancellationRequested) return;
        _cts.Cancel();
        if (_cur is { } o)
            _ = Task.Run(async () =>
            {
                try { await Http.PostAsync(AccountApi.Base + "/pair/cancel", new { id = o.Id, poll = o.Poll }, TimeSpan.FromSeconds(10)); } catch { }
            });
    }

    public void Dispose() => Stop();
}
