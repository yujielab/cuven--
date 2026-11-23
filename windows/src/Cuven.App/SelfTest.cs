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
    // ── 截屏（真正合成出来的画面：亚克力、阴影、SwapChainPanel 里的粒子云都在；RenderTargetBitmap 截不到这些） ──
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int w, int h);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr d, int x, int y, int w, int h, IntPtr s, int sx, int sy, uint rop);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr dc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BITMAPINFOHEADER bi, uint usage);
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct BITMAPINFOHEADER { public uint Size; public int Width, Height; public ushort Planes, BitCount; public uint Compression, SizeImage; public int XPels, YPels; public uint ClrUsed, ClrImportant; }

    static (byte[] px, int w, int h)? CaptureWindow(IntPtr hwnd)
    {
        if (DwmGetWindowAttribute(hwnd, 9, out var r, 16) != 0) return null;   // DWMWA_EXTENDED_FRAME_BOUNDS
        int w = r.R - r.L, h = r.B - r.T;
        if (w <= 0 || h <= 0) return null;
        var screen = GetDC(IntPtr.Zero);
        var mem = CreateCompatibleDC(screen);
        var bmp = CreateCompatibleBitmap(screen, w, h);
        var old = SelectObject(mem, bmp);
        BitBlt(mem, 0, 0, w, h, screen, r.L, r.T, 0x00CC0020 | 0x40000000);   // SRCCOPY | CAPTUREBLT
        SelectObject(mem, old);
        var bi = new BITMAPINFOHEADER { Size = 40, Width = w, Height = -h, Planes = 1, BitCount = 32 };
        var px = new byte[w * h * 4];
        GetDIBits(mem, bmp, 0, (uint)h, px, ref bi, 0);
        DeleteObject(bmp);
        DeleteDC(mem);
        ReleaseDC(IntPtr.Zero, screen);
        for (int i = 3; i < px.Length; i += 4) px[i] = 255;
        return (px, w, h);
    }

    static async Task SavePng(string path, byte[] bgra, int w, int h)
    {
        using var ms = new InMemoryRandomAccessStream();
        var enc = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, ms);
        enc.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)w, (uint)h, 96, 96, bgra);
        await enc.FlushAsync();
        var bytes = new byte[ms.Size];
        ms.Seek(0);
        await ms.ReadAsync(bytes.AsBuffer(), (uint)ms.Size, InputStreamOptions.None);
        await File.WriteAllBytesAsync(path, bytes);
    }

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
                SetForegroundWindow(w.Hwnd);
                await Task.Delay(300);
                var shot = CaptureWindow(w.Hwnd);
                if (shot is { } c) await SavePng(Path.Combine(dir, name + ".png"), c.px, c.w, c.h);
                if (w.Content is not UIElement root) throw new InvalidOperationException("没有内容");
                var rtb = new RenderTargetBitmap();
                await rtb.RenderAsync(root);
                var px = await rtb.GetPixelsAsync();
                await SavePng(Path.Combine(dir, name + "-xaml.png"), px.ToArray(), rtb.PixelWidth, rtb.PixelHeight);
                report.Add($"✓ {name}（截屏 {(shot is { } cc ? $"{cc.w}×{cc.h}" : "没截到")}，XAML {rtb.PixelWidth}×{rtb.PixelHeight}）");
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
            Shell.Current?.Root("library");
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
            if (LibraryStore.Shared.Movies.FirstOrDefault(m => m.Video.Name.Contains("1080p")) is { } pm)
            {
                PlayRequest.Movie(pm);
                await Shot("8-player", 14);
                w.ClosePlayer();
            }
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
