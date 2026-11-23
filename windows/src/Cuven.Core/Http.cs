using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Cuven.Core;

/// <summary>给人看的错误：发行版不露 HTTP 状态码与服务器原话，只说怎么了、该怎么办</summary>
public sealed class CuvenException : Exception
{
    public int Status { get; }
    public string? Code { get; }
    public CuvenException(string message, int status = 0, string? code = null, Exception? inner = null) : base(message, inner)
    {
        Status = status; Code = code;
    }

    public static string Friendly(Exception e) => e switch
    {
        CuvenException c => c.Message,
        TaskCanceledException => "连接超时，请稍后再试。",
        HttpRequestException { InnerException: System.Net.Sockets.SocketException } => "无法连接服务器，请检查网络后重试。",
        HttpRequestException => "网络连接出了问题，请稍后再试。",
        _ => "请稍后再试。",
    };
}

/// <summary>所有接口共用一个 HttpClient（连接复用、HTTP/2、自动解压）</summary>
public static class Http
{
    public static readonly HttpClient Client = Create();

    /// <summary>流量统计（账户页「流量概览」）：回包字节数</summary>
    public static long BytesIn;

    private static HttpClient Create()
    {
        var h = new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            PooledConnectionIdleTimeout = TimeSpan.FromSeconds(90),
            ConnectTimeout = TimeSpan.FromSeconds(12),
            EnableMultipleHttp2Connections = true,
            MaxConnectionsPerServer = 8,
        };
        var c = new HttpClient(h) { Timeout = Timeout.InfiniteTimeSpan, DefaultRequestVersion = HttpVersion.Version20 };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("CuvenWindows/1.0");
        c.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        return c;
    }

    /// <summary>与 JS encodeURIComponent 同一套保留字符；「+」一定转成 %2B（后端按 URLSearchParams 解）</summary>
    public static string Enc(string s) => Uri.EscapeDataString(s);

    public static string Url(string baseUrl, string path, params (string k, string v)[] q)
    {
        var sb = new StringBuilder(baseUrl).Append(path);
        for (int i = 0; i < q.Length; i++)
            sb.Append(i == 0 ? '?' : '&').Append(Enc(q[i].k)).Append('=').Append(Enc(q[i].v));
        return sb.ToString();
    }

    public sealed record Reply(int Status, byte[] Body, HttpResponseHeaders? Headers)
    {
        public bool Ok => Status is >= 200 and < 300;
        public JsonDocument? Json()
        {
            if (Body.Length == 0) return null;
            try { return JsonDocument.Parse(Body); } catch (JsonException) { return null; }
        }
        public string Text => Encoding.UTF8.GetString(Body);
    }

    public static async Task<Reply> SendAsync(HttpMethod method, string url, object? json = null, TimeSpan? timeout = null,
        IEnumerable<KeyValuePair<string, string>>? headers = null, CancellationToken ct = default, bool noCache = false)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? TimeSpan.FromSeconds(25));
        using var req = new HttpRequestMessage(method, url);
        if (json is not null)
            req.Content = new StringContent(json as string ?? JsonSerializer.Serialize(json), Encoding.UTF8, "application/json");
        if (headers is not null)
            foreach (var kv in headers) req.Headers.TryAddWithoutValidation(kv.Key, kv.Value);
        if (noCache) req.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true };
        try
        {
            using var resp = await Client.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token).ConfigureAwait(false);
            var body = await resp.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
            Interlocked.Add(ref BytesIn, body.Length);
            return new Reply((int)resp.StatusCode, body, resp.Headers);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new CuvenException("连接超时，请稍后再试。");
        }
        catch (HttpRequestException e)
        {
            throw new CuvenException("无法连接服务器，请检查网络后重试。", 0, null, e);
        }
    }

    public static Task<Reply> GetAsync(string url, TimeSpan? timeout = null, CancellationToken ct = default, bool noCache = false,
        IEnumerable<KeyValuePair<string, string>>? headers = null) =>
        SendAsync(HttpMethod.Get, url, null, timeout, headers, ct, noCache);

    public static Task<Reply> PostAsync(string url, object json, TimeSpan? timeout = null, CancellationToken ct = default,
        IEnumerable<KeyValuePair<string, string>>? headers = null) =>
        SendAsync(HttpMethod.Post, url, json, timeout, headers, ct);

    /// <summary>2xx 才算数，否则抛给人看的错（服务器的 error 字段只在调试日志里）</summary>
    public static JsonDocument Expect(Reply r)
    {
        if (!r.Ok)
        {
            string? code = null;
            try { using var d = r.Json(); code = d?.RootElement.Str("error"); } catch { }
            throw new CuvenException("服务暂时不可用，请稍后再试。", r.Status, code);
        }
        return r.Json() ?? throw new CuvenException("出了点问题，请稍后再试。", r.Status);
    }
}
