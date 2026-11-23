using System.Runtime.InteropServices;

namespace Cuven.App.Native;

static class Win32
{
    public const uint MONITOR_DEFAULTTONEAREST = 2;
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern int ShowCursor(bool show);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
    public const uint ES_CONTINUOUS = 0x80000000, ES_DISPLAY_REQUIRED = 0x00000002, ES_SYSTEM_REQUIRED = 0x00000001;

    /// <summary>播放时不让屏幕熄灭 / 系统睡眠；停了恢复</summary>
    public static void KeepAwake(bool on) =>
        SetThreadExecutionState(on ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED : ES_CONTINUOUS);

    // 光标：鼠标不动三秒（播放中）就藏起来。ShowCursor 是计数的，自己记着别多藏
    static bool _hidden;
    public static void HideCursor(bool hide)
    {
        if (hide == _hidden) return;
        _hidden = hide;
        ShowCursor(!hide);
    }
}

/// <summary>Windows 的 DPAPI：设备令牌加密存在本机，只有这个 Windows 账户能解开</summary>
sealed class Dpapi : Cuven.Core.ISecretProtector
{
    [StructLayout(LayoutKind.Sequential)]
    struct Blob { public int Size; public IntPtr Data; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptProtectData(ref Blob input, string? desc, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptUnprotectData(ref Blob input, IntPtr desc, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);

    static byte[]? Run(byte[] data, bool protect)
    {
        var h = GCHandle.Alloc(data, GCHandleType.Pinned);
        try
        {
            var inp = new Blob { Size = data.Length, Data = h.AddrOfPinnedObject() };
            Blob outp;
            bool ok = protect ? CryptProtectData(ref inp, "Cuven", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out outp)
                              : CryptUnprotectData(ref inp, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out outp);
            if (!ok) return null;
            var r = new byte[outp.Size];
            Marshal.Copy(outp.Data, r, 0, outp.Size);
            LocalFree(outp.Data);
            return r;
        }
        finally { h.Free(); }
    }

    public byte[] Protect(byte[] plain) => Run(plain, true) ?? Array.Empty<byte>();
    public byte[]? Unprotect(byte[] sealedData) => Run(sealedData, false);
}
