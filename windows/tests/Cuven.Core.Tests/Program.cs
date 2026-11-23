using System.Text.Json;
using Cuven.Core;

// Cuven.Core 的测试：dotnet run（CUVEN_LIVE=1 时另外打一遍线上接口）
int pass = 0, fail = 0;
void Check(bool ok, string what)
{
    if (ok) { pass++; Console.WriteLine("  ✓ " + what); }
    else { fail++; Console.WriteLine("  ✗ " + what); }
}
string Fx(string name) => Path.Combine(AppContext.BaseDirectory, "fixtures", name);
Storage.Root = Path.Combine(Path.GetTempPath(), "cuven-test-" + Environment.ProcessId);

Console.WriteLine("光学配对：码与测试向量（pairing/model/cpc1-vectors.json）");
var spec = PairSpec.Shared;
Check(spec.Version == 2 && spec.Cells.Length == 160 && spec.CodeGrid == 192, $"规范 v{spec.Version}，{spec.Cells.Length} 格，网格 {spec.CodeGrid}");
var vecs = JsonDocument.Parse(File.ReadAllText(Fx("cpc1-vectors.json"))).RootElement;
foreach (var v in vecs.EnumerateArray())
{
    uint id = v.GetProperty("id").GetUInt32(), sec = v.GetProperty("secret").GetUInt32();
    var b = PairCodec.CellSigns(id, sec);
    var want = v.GetProperty("signs").EnumerateArray().Select(x => x.GetSingle()).ToArray();
    Check(b.SequenceEqual(want), $"格子正负 {id}/{sec}");
    var pts = v.GetProperty("pts").EnumerateArray().ToArray();
    var D = v.GetProperty("D").EnumerateArray().Select(x => x.GetDouble()).ToArray();
    var M = v.GetProperty("m").EnumerateArray().Select(x => x.GetDouble()).ToArray();
    double worstD = 0, worstM = 0;
    for (int i = 0; i < pts.Length; i++)
    {
        var (d, e) = PairCodec.FieldAt(b, pts[i][0].GetDouble(), pts[i][1].GetDouble());
        worstD = Math.Max(worstD, Math.Abs(d - D[i]));
        worstM = Math.Max(worstM, Math.Abs(PairCodec.Modulation(d, e) - M[i]));
    }
    // 测试向量是 float32 算的、存 6 位小数：差 1e-4 以内算一致（码纹理另外和网页版逐字节比）
    Check(worstD < 1e-4 && worstM < 1e-4, $"码场 / 调制（最大误差 D {worstD:E1}，M {worstM:E1}）");
}
{
    var v0 = vecs[0];
    var tex = PairCodec.CodeTexture(v0.GetProperty("id").GetUInt32(), v0.GetProperty("secret").GetUInt32());
    var web = File.ReadAllBytes(Fx("grid0.bin"));
    int diff = 0, maxd = 0;
    for (int i = 0; i < tex.Length; i++) { var d = Math.Abs(tex[i] - web[i]); if (d > 0) diff++; maxd = Math.Max(maxd, d); }
    Check(tex.Length == web.Length && maxd <= 1 && diff < 20, $"码纹理和网页版 pair.js 一致（{diff} 个像素差 1）");
}

Console.WriteLine("码纹理快路（稀疏基底）和参考实现一致");
{
    int g = spec.CodeGrid;
    var sw = System.Diagnostics.Stopwatch.StartNew();
    var fresh = PairCodec.BuildBasis(spec, g);   // 上面的码纹理已经用过缓存的那份：另算一份量时间、对一下
    var buildMs = sw.Elapsed.TotalMilliseconds;
    var basis = PairCodec.Basis;
    Check(fresh.NonZeros == basis.NonZeros && fresh.Start.SequenceEqual(basis.Start) && fresh.Weight.SequenceEqual(basis.Weight) && fresh.E.SequenceEqual(basis.E),
        "重算一遍的基底和缓存的逐项相同");
    bool shape = basis.G == g && basis.E.Length == g * g && basis.Start.Length == g * g + 1 && basis.Start[^1] == basis.NonZeros
        && basis.Weight.All(w => w > PairBasis.Cutoff) && basis.Cell.All(c => c < spec.Cells.Length);
    Check(shape && basis.NonZeros > g * g && basis.NonZeros < g * g * 20,
        $"基底 {basis.NonZeros} 个非零（每像素 {basis.NonZeros / (double)(g * g):F1} 个），算了 {buildMs:F0} ms");
    Check(ReferenceEquals(basis, PairCodec.Basis), "基底只算一次");
    var rng = new Random(7);
    var codes = vecs.EnumerateArray().Select(v => (v.GetProperty("id").GetUInt32(), v.GetProperty("secret").GetUInt32())).Take(2)
        .Concat(Enumerable.Range(0, 3).Select(_ => ((uint)rng.Next(1, 0xFFFFFF), (uint)rng.NextInt64(0, 1L << 32))))
        .Append((0xFFFFFFu, 0xFFFFFFFFu)).ToArray();
    double fastMs = 0;
    foreach (var (id, sec) in codes)
    {
        var b = PairCodec.CellSigns(id, sec);
        var dense = PairCodec.ModulationGrid(b, g);
        sw.Restart();
        var fast = PairCodec.ModulationGridFast(b);
        var texFast = PairCodec.CodeTexture(id, sec);
        fastMs = Math.Max(fastMs, sw.Elapsed.TotalMilliseconds);
        var texDense = PairCodec.CodeTextureDense(id, sec);
        double worst = 0;
        for (int i = 0; i < dense.Length; i++) worst = Math.Max(worst, Math.Abs(dense[i] - fast[i]));
        int diff = 0, maxd = 0;
        for (int i = 0; i < texFast.Length; i++) { var d = Math.Abs(texFast[i] - texDense[i]); if (d > 0) diff++; maxd = Math.Max(maxd, d); }
        Check(worst < 1e-4 && maxd <= 1 && diff <= 3, $"码 {id}/{sec}：M 最大差 {worst:E1}，8 位纹理 {diff} 个像素差 1");
    }
    Check(fastMs < 200, $"快路一团码 {fastMs:F1} ms（最慢的一次）");
    var neutral = PairCodec.NeutralTexture();
    Check(neutral.Length == g * g && neutral.All(x => x == neutral[0]) && Math.Abs(neutral[0] / 255.0 * spec.CodeScale - 1) < 1e-9,
        $"不带码的纹理：处处 M = 1（{neutral[0]}）");
}

Console.WriteLine("设备令牌：这台电脑不存");
DeviceTokenChecks();

[System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
void DeviceTokenChecks()
{
    // 旧版留下的 device.bin：一启动（第一次用 Settings）就删掉
    var bin = Path.Combine(Storage.Root, "device.bin");
    File.WriteAllText(bin, "d1.old");
    var st = Settings.Shared;
    Check(!File.Exists(bin) && st.DeviceToken is null, "启动时删掉旧的 device.bin");
    File.WriteAllText(bin, "d1.other-account");
    st.SignIn(new LoginResult("u1", "", "d1.new", "c1.x", "pair"));
    Check(!File.Exists(bin) && st.DeviceToken is null && st.Username == "u1", "登录不存设备令牌、也不留上一个账户的");
    st.SignOut();
}

Console.WriteLine("配对显示端（本机假账号中心）：提前换码、作废就不画、批准登录、不要设备令牌");
await PairLoopChecks();

async Task PairLoopChecks()
{
    int port;
    { var tl = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0); tl.Start(); port = ((System.Net.IPEndPoint)tl.LocalEndpoint).Port; tl.Stop(); }
    var baseUrl = $"http://127.0.0.1:{port}";
    using var hl = new System.Net.HttpListener();
    hl.Prefixes.Add(baseUrl + "/");
    hl.Start();
    var log = new System.Collections.Concurrent.ConcurrentQueue<(string path, JsonElement body)>();
    long serverNow() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 3_600_000;   // 服务端的钟比本机快一小时：只认 ttl / 时差
    var exps = new System.Collections.Concurrent.ConcurrentDictionary<uint, long>();
    uint nextId = 0;
    using var stop = new CancellationTokenSource();
    var server = Task.Run(async () =>
    {
        while (!stop.IsCancellationRequested)
        {
            System.Net.HttpListenerContext cx;
            try { cx = await hl.GetContextAsync(); } catch { return; }
            _ = Task.Run(async () =>
            {
                using var sr = new StreamReader(cx.Request.InputStream);
                var body = JsonDocument.Parse(await sr.ReadToEndAsync()).RootElement.Clone();
                var path = cx.Request.Url!.AbsolutePath;
                log.Enqueue((path, body));
                object reply;
                if (path == "/pair/open")
                {
                    var id = Interlocked.Increment(ref nextId);
                    var exp = serverNow() + 10_000;
                    exps[id] = exp;
                    reply = new { ok = true, id, secret = 1000 + id, poll = "p" + id, code = "", ttl = 10, exp };
                }
                else if (path == "/pair/wait")
                {
                    var id = body.GetProperty("id").GetUInt32();
                    if (id == 1)
                    {
                        // 第一团：按 wait 挂着，一直没人扫（客户端该在到期前 8 秒自己换掉）
                        var w = Math.Clamp(body.GetProperty("wait").GetInt32(), 0, 20_000);
                        await Task.Delay(Math.Min(w, 3000));
                        reply = new { ok = true, status = "open", exp = exps[1], peeked = false };
                    }
                    else if (id == 2) reply = new { ok = true, status = "expired" };
                    else if (id >= 4) { await Task.Delay(800); reply = new { ok = true, status = "approved", username = "late", code = "c1.late" }; }
                    else reply = new { ok = true, status = "approved", username = "u3", email = "u3@example.com", code = "c1.test", device = "d1.should-not-keep" };
                }
                else reply = new { ok = true };
                var bytes = JsonSerializer.SerializeToUtf8Bytes(reply);
                cx.Response.ContentType = "application/json";
                cx.Response.ContentLength64 = bytes.Length;
                await cx.Response.OutputStream.WriteAsync(bytes);
                cx.Response.Close();
            });
        }
    });

    var events = new System.Collections.Concurrent.ConcurrentQueue<string>();
    var done = new TaskCompletionSource<LoginResult>(TaskCreationOptions.RunContinuationsAsynchronously);
    var pl = new PairLogin("Windows · TEST", baseUrl);
    pl.CodeChanged += o => events.Enqueue("code " + o.Id);
    pl.CodeCleared += () => events.Enqueue("clear");
    pl.Approved += r => { events.Enqueue("approved " + r.Username); done.TrySetResult(r); };
    var sw = System.Diagnostics.Stopwatch.StartNew();
    pl.Start();
    var finished = await Task.WhenAny(done.Task, Task.Delay(15_000)) == done.Task;
    var took = sw.Elapsed.TotalSeconds;
    await Task.Delay(300);   // 等 cancel 发完
    pl.Stop();
    var ev = string.Join(", ", events);
    Check(finished && ev == "code 1, code 2, clear, code 3, approved u3", $"事件顺序：{ev}（{took:F1} 秒）");
    var cancels = log.Where(x => x.path == "/pair/cancel").Select(x => x.body.GetProperty("id").GetUInt32()).ToArray();
    Check(cancels.SequenceEqual(new[] { 1u }), $"换下来的第一团发了 /pair/cancel（{string.Join(",", cancels)}）");
    // 第一团 ttl 10 秒：大约 2 秒时（到期前 8 秒）换掉，而不是等它过期
    var firstWaits = log.Where(x => x.path == "/pair/wait" && x.body.GetProperty("id").GetUInt32() == 1).Select(x => x.body.GetProperty("wait").GetInt32()).ToArray();
    Check(firstWaits.Length >= 1 && firstWaits[0] is > 1000 and <= 2100 && took < 6, $"到期前 8 秒换码（第一次 wait 挂 {string.Join("/", firstWaits)} ms）");
    var opens = log.Where(x => x.path == "/pair/open").Select(x => x.body).ToArray();
    var waits = log.Where(x => x.path == "/pair/wait").Select(x => x.body).ToArray();
    Check(opens.Length == 3 && opens.All(b => !b.TryGetProperty("want_device", out _)) && waits.All(b => !b.TryGetProperty("device", out _)),
        "open 不带 want_device、wait 不带 device");
    Check(waits.All(b => b.GetProperty("wait").GetInt32() is >= 0 and <= 20_000), "wait 都在 0–20000 ms 之间");
    Check(finished && done.Task.Result is { Device: null, Code: "c1.test", Method: "pair", Email: "u3@example.com" }, "批准：拿到识别代码，设备令牌不收");

    // wait 挂着的时候 Stop（切到密码页）：那一团发 /pair/cancel，之后回来的批准不算
    var late = new PairLogin("Windows · TEST", baseUrl);
    bool lateApproved = false;
    var shown = new TaskCompletionSource<uint>(TaskCreationOptions.RunContinuationsAsynchronously);
    late.CodeChanged += o => shown.TrySetResult(o.Id);
    late.Approved += _ => lateApproved = true;
    late.Start();
    var lateId = await Task.WhenAny(shown.Task, Task.Delay(5000)) == shown.Task ? shown.Task.Result : 0u;
    await Task.Delay(200);
    late.Stop();
    await Task.Delay(1500);
    var lateCancels = log.Where(x => x.path == "/pair/cancel").Select(x => x.body.GetProperty("id").GetUInt32()).ToArray();
    Check(lateId == 4 && !lateApproved && lateCancels.Contains(4u), "Stop 时关掉正显示的那一团，之后回来的批准不登录");

    stop.Cancel();
    hl.Stop();
    try { await server; } catch { }
}

Console.WriteLine("口令 v3（PBKDF2-SHA256，和网页版 keyOf 一致）");
{
    var k = PasswordKey.Derive("password", PasswordKey.B64u("salt"u8), 1);
    Check(Convert.ToHexString(PasswordKey.FromB64u(k)).ToLowerInvariant() == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", "RFC 7914 测试向量");
    var f = JsonDocument.Parse(File.ReadAllText(Fx("pbkdf2.json"))).RootElement;
    var key = PasswordKey.Derive(f.GetProperty("password").GetString()!, f.GetProperty("salt").GetString()!, f.GetProperty("iter").GetInt32());
    Check(key == f.GetProperty("key").GetString(), "31 万轮、中文密码，与 Node 的结果相同");
}

Console.WriteLine("字幕（WebVTT / SRT）");
{
    var cues = SubtitleParser.Parse("WEBVTT\n\n1\n00:00:01.500 --> 00:00:03.000\n<i>你好</i>\n第二行\n\n00:01:02.250 --> 00:01:04.000 align:start\n{\\an8}Hello &amp; bye\n");
    Check(cues.Count == 2 && cues[0].Text == "你好\n第二行" && Math.Abs(cues[0].Start - 1.5) < 1e-9, "VTT 两条、去掉标签、多行");
    Check(Math.Abs(cues[1].Start - 62.25) < 1e-9 && cues[1].Text == "Hello & bye", "分钟、ASS 标签、实体");
    var srt = SubtitleParser.Parse("1\r\n00:00:05,000 --> 00:00:06,500\r\nSRT 行\r\n");
    Check(srt.Count == 1 && Math.Abs(srt[0].End - 6.5) < 1e-9, "SRT 逗号毫秒");
}

Console.WriteLine("文件名");
{
    Check(FileName.Title("SING.2.2021.2160p.HDR.UHD.BluRay.TrueHD.7.1.Atmos.x265-10bit-ENTHD.mkv") == "SING 2", "片名");
    Check(FileName.Year("Blade.Runner.2049.2017.1080p.mkv") == 2017, "年份取最后一个");
    Check(FileName.Specs("Horizon.2024.2160p.UHD.BluRay.x265.10bit.DV.TrueHD.7.1.Atmos.mkv").SequenceEqual(new[] { "4K", "杜比视界", "杜比全景声" }), "规格徽标");
    Check(FileName.Stem("Movie.2020.[auto-m550-r13].mkv") == "Movie.2020", "去掉追踪码");
    Check(TmdbImage.Url("https://image.tmdb.org/t/p/w342/abc.jpg", "w780") == "https://image.tmdb.org/t/p/w780/abc.jpg", "TMDB 换尺寸");
    Check(StreamApi.StreamUrl("/ram/a b+c.mkv", "a b+c.mkv", null) == "https://stream.cuven.online/stream/Cuven.mkv?path=%2Fram%2Fa%20b%2Bc.mkv", "直链（+ 转 %2B）");
}

Console.WriteLine("后端回包的宽松解码");
{
    var lib = LibraryPayload.From(JsonDocument.Parse("""{"root":"/ram","videos":[{"name":"A.2020.mkv","path":"/ram/A.2020.mkv","size":"123"},{"path":""}],"folders":[]}""").RootElement);
    Check(lib.Videos.Count == 1 && lib.Videos[0].Size == 123, "大小是字符串也认，空路径丢掉");
    var r = RequestStatus.From(JsonDocument.Parse("""{"id":7,"src":"tv","tmdb":"42","season":2,"year":2024,"stage":"release","state":"active","step":5,"pct":90}""").RootElement);
    Check(r is { Tmdb: 42, Year: "2024", Step: 5 } && r.Key == "tv-42-2", "请求进度");
}

if (Environment.GetEnvironmentVariable("CUVEN_LIVE") == "1")
{
    Console.WriteLine("线上接口（CUVEN_LIVE=1）");
    var lib = await StreamApi.LibraryAsync();
    Check(lib.Videos.Count > 100, $"片库 {lib.Videos.Count} 个文件");
    var name = lib.Videos[0].Name;
    var metas = await StreamApi.MetaBatchAsync(new[] { name });
    Check(metas.ContainsKey(name), "TMDB 批量");
    var sign = await StreamApi.StreamSignAsync(lib.Videos[0].Path);
    Check(sign.Hls is not null, "播放签名");
    var tv = await StreamApi.TvListAsync();
    Check(tv.Count > 0, $"剧集 {tv.Count} 季");
    var cat = await RequestApi.CatalogAsync();
    Check(cat.Count > 0, $"请求添加目录 {cat.Count} 部");
    var p = await AccountApi.ParamsAsync("cuven-test-" + Guid.NewGuid().ToString("N")[..8]);
    Check(p is not null && p.Salt.Length > 0, "口令参数（不认识的用户名也有稳定的假参数）");
}

try { Directory.Delete(Storage.Root, true); } catch { }
Console.WriteLine($"\n{pass} 项通过，{fail} 项失败");
return fail == 0 ? 0 : 1;
