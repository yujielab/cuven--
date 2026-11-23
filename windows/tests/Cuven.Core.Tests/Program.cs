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
