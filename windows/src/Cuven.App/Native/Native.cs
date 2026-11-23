using System.Runtime.InteropServices;
using System.Text;

namespace Cuven.App.Native;

// CuvenCore.dll 的 C 接口（windows/native/include/cuven_core.h）
[StructLayout(LayoutKind.Sequential)]
public struct CvDisplay
{
    public int Hdr;
    public int Bits;
    public float MaxNits;
    public float MinNits;
    public float MaxFullFrameNits;
    public float SdrWhiteNits;
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct CvState
{
    public double Position;
    public double Duration;
    public double Buffered;
    public int Paused, Buffering, Ended, Seeking;
    public int Width, Height;
    public double Fps;
    public int HdrKind;
    public int DoviProfile;
    public int OutputHdr;
    public int HwDecode;
    public int DroppedFrames;
    public float Volume;
    public double NetMbps;
    public fixed byte VideoCodec[32];
    public fixed byte AudioCodec[32];

    public string Video { get { fixed (byte* p = VideoCodec) return Native.Str(p, 32); } }
    public string Audio { get { fixed (byte* p = AudioCodec) return Native.Str(p, 32); } }
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct CvTrack
{
    public int Id;
    public int Type;
    public int Selected;
    public int IsDefault;
    public int IsBitmap;
    public int Channels;
    public fixed byte Lang[16];
    public fixed byte Title[128];
    public fixed byte Codec[32];

    public string LangStr { get { fixed (byte* p = Lang) return Native.Str(p, 16); } }
    public string TitleStr { get { fixed (byte* p = Title) return Native.Str(p, 128); } }
    public string CodecStr { get { fixed (byte* p = Codec) return Native.Str(p, 32); } }
}

[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void CvEventCallback(IntPtr user, int ev, int arg, IntPtr text);

public static unsafe class Native
{
    const string Dll = "CuvenCore.dll";

    public const int SurfaceTransparent = 1, SurfaceVideo = 2;
    public const int EvOpened = 1, EvState = 2, EvEnded = 3, EvError = 4, EvTracks = 5, EvBuffering = 6, EvVideo = 7;
    public const int TrackAudio = 1, TrackSub = 2;
    public const int QosDefault = 0, QosEco = 1, QosHigh = 2;
    public const int HdrSdr = 0, HdrPq = 1, HdrHlg = 2, HdrDovi = 3;

    internal static string Str(byte* p, int max)
    {
        int n = 0;
        while (n < max && p[n] != 0) n++;
        return Encoding.UTF8.GetString(p, n);
    }

    public static string? FromUtf8(IntPtr p) => p == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(p);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern int cv_init(int flags);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr cv_version();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr cv_gpu_name();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_set_log_dir([MarshalAs(UnmanagedType.LPUTF8Str)] string dir);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern int cv_display_query(IntPtr hmonitor, out CvDisplay d);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr cv_surface_create(int w, int h, int flags);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern int cv_surface_attach(IntPtr s, IntPtr panel);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_surface_resize(IntPtr s, int w, int h, float sx, float sy);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_surface_destroy(IntPtr s);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr cv_cloud_create(IntPtr s, byte* atlas, int w, int h);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_cloud_set_code(IntPtr c, byte* grid, int g, float scale, float spin);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_cloud_run(IntPtr c, int running);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_cloud_set_background(IntPtr c, float r, float g, float b, float a);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_cloud_destroy(IntPtr c);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern IntPtr cv_player_create(IntPtr s, CvEventCallback cb, IntPtr user);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int cv_player_open(IntPtr p, [MarshalAs(UnmanagedType.LPUTF8Str)] string url, double start, int flags,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string audioLang, [MarshalAs(UnmanagedType.LPUTF8Str)] string subLang);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_player_play(IntPtr p);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_player_pause(IntPtr p);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_player_seek(IntPtr p, double pos, int exact);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_player_set_volume(IntPtr p, float v);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_player_get_state(IntPtr p, out CvState st);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern int cv_player_tracks(IntPtr p, CvTrack* tracks, int max);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_player_select(IntPtr p, int type, int id);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void cv_player_set_ext_subs(IntPtr p, double* starts, double* ends, IntPtr* texts, int n, [MarshalAs(UnmanagedType.LPUTF8Str)] string label);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_player_set_output(IntPtr p, ref CvDisplay d, int hdrMode);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_player_set_sub_style(IntPtr p, float scale, float bottom);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_player_destroy(IntPtr p);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_thread_qos(int mode);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] public static extern void cv_process_eco(int on);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int cv_load_gray([MarshalAs(UnmanagedType.LPUTF8Str)] string path, byte* outBuf, int max, out int w, out int h);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int cv_selftest([MarshalAs(UnmanagedType.LPUTF8Str)] string media, [MarshalAs(UnmanagedType.LPUTF8Str)] string outDir, byte* report, int len);

    public static bool Ready { get; private set; }
    public static string? InitError { get; private set; }

    public static bool Init()
    {
        if (Ready) return true;
        try
        {
            cv_set_log_dir(Path.Combine(Cuven.Core.Storage.Root, "logs"));
            Ready = cv_init(0) == 0;
            if (!Ready) InitError = "显卡初始化失败";
        }
        catch (DllNotFoundException) { InitError = "缺少 CuvenCore.dll（安装包不完整）"; }
        catch (BadImageFormatException) { InitError = "CuvenCore.dll 和这台电脑的架构不符"; }
        catch (EntryPointNotFoundException) { InitError = "CuvenCore.dll 版本不对"; }
        return Ready;
    }

    public static string Version => Ready ? FromUtf8(cv_version()) ?? "" : "";
    public static string GpuName => Ready ? FromUtf8(cv_gpu_name()) ?? "" : "";

    /// <summary>配对云的密度校正图（pair-density.png，8 位灰度）</summary>
    public static (byte[]? px, int w, int h) LoadGray(string path)
    {
        if (!Ready || !File.Exists(path)) return (null, 0, 0);
        if (cv_load_gray(path, null, 0, out var w, out var h) != 0 || w <= 0 || h <= 0) return (null, 0, 0);
        var buf = new byte[w * h];
        fixed (byte* p = buf)
            if (cv_load_gray(path, p, buf.Length, out w, out h) != 0) return (null, 0, 0);
        return (buf, w, h);
    }

    public static CvDisplay QueryDisplay(IntPtr hmonitor)
    {
        if (!Ready || cv_display_query(hmonitor, out var d) != 0)
            return new CvDisplay { Bits = 8, MaxNits = 270, SdrWhiteNits = 80, MaxFullFrameNits = 270 };
        return d;
    }
}
