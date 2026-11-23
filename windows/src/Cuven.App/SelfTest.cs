using Cuven.App.UI;
using Cuven.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;

namespace Cuven.App;

/// <summary>
/// CI 自检：Cuven.exe --selftest &lt;目录&gt; —— 依次打开登录页、首页、电影、详情、请求、账户，各截一张图（RenderTargetBitmap，SwapChainPanel 里的内容截不到），
/// 写 report.txt，然后退出（退出码 0 = 都打开了）
/// </summary>
static class SelfTest
{
    public static async Task RunAsync(MainWindow w, string dir)
    {
        Directory.CreateDirectory(dir);
        var report = new List<string> { $"Cuven for Windows 自检 · {DateTime.Now:yyyy-MM-dd HH:mm:ss}", $"原生核心：{(Native.Native.Ready ? Native.Native.Version + " · " + Native.Native.GpuName : Native.Native.InitError)}" };
        int failed = 0;
        async Task Shot(string name, double wait)
        {
            await Task.Delay(TimeSpan.FromSeconds(wait));
            try
            {
                if (w.Content is not UIElement root) throw new InvalidOperationException("没有内容");
                var rtb = new RenderTargetBitmap();
                await rtb.RenderAsync(root);
                var px = await rtb.GetPixelsAsync();
                using var ms = new InMemoryRandomAccessStream();
                var enc = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, ms);
                enc.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)rtb.PixelWidth, (uint)rtb.PixelHeight, 96, 96, px.ToArray());
                await enc.FlushAsync();
                var bytes = new byte[ms.Size];
                ms.Seek(0);
                await ms.ReadAsync(bytes.AsBuffer(), (uint)ms.Size, InputStreamOptions.None);
                await File.WriteAllBytesAsync(Path.Combine(dir, name + ".png"), bytes);
                report.Add($"✓ {name}（{rtb.PixelWidth}×{rtb.PixelHeight}）");
            }
            catch (Exception e)
            {
                failed++;
                report.Add($"✗ {name}：{e.Message}");
            }
        }
        try
        {
            if (Settings.Shared.SignedIn) w.SignOut();
            await Shot("1-login", 4);
            // 不登录账户，直接看主界面（自检用的假用户，不发任何账户请求）
            Settings.Shared.Username = "selftest";
            w.ShowShell();
            for (int i = 0; i < 40 && LibraryStore.Shared.Movies.Count == 0; i++) await Task.Delay(500);
            report.Add($"片库：{LibraryStore.Shared.Movies.Count} 部电影，{LibraryStore.Shared.Series.Count} 季剧集");
            await Shot("2-home", 6);
            Shell.Current?.Root("movies");
            await Shot("3-movies", 4);
            if (LibraryStore.Shared.Movies.FirstOrDefault(m => !string.IsNullOrEmpty(m.Meta.Backdrop)) is { } mv)
            {
                Nav.Open(mv);
                await Shot("4-detail", 6);
            }
            if (LibraryStore.Shared.Series.FirstOrDefault() is { } se)
            {
                Nav.Open(se);
                await Shot("5-series", 6);
            }
            Shell.Current?.Root("requests");
            await Shot("6-requests", 5);
            Shell.Current?.Root("account");
            await Shot("7-account", 2);
        }
        catch (Exception e)
        {
            failed++;
            report.Add("✗ 异常：" + e);
        }
        Settings.Shared.Username = null;
        report.Add(failed == 0 ? "自检通过" : $"自检没过：{failed} 项");
        await File.WriteAllLinesAsync(Path.Combine(dir, "report.txt"), report);
        App.ExitCode = failed == 0 ? 0 : 1;
        Application.Current.Exit();
    }
}
