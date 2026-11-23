using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Cuven.App.Native;

/// <summary>
/// 一块 SwapChainPanel + 原生核心的交换链（cv_surface）：面板一加载就建、跟着面板改大小和缩放。
/// 视频、配对粒子云都画在这上面（原生线程直接 Present，不经过 XAML 的渲染线程）
/// </summary>
public sealed partial class NativeSurface : IDisposable
{
    public SwapChainPanel Panel { get; } = new();
    public IntPtr Handle { get; private set; }
    public event Action? Ready;
    readonly int _flags;
    bool _disposed;

    public NativeSurface(int flags)
    {
        _flags = flags;
        Panel.Loaded += (_, _) => Create();
        Panel.SizeChanged += (_, _) => Resize();
        Panel.CompositionScaleChanged += (_, _) => Resize();
    }

    (int w, int h) PixelSize()
    {
        var sx = Panel.CompositionScaleX > 0 ? Panel.CompositionScaleX : 1;
        var sy = Panel.CompositionScaleY > 0 ? Panel.CompositionScaleY : 1;
        return (Math.Max(1, (int)Math.Ceiling(Panel.ActualWidth * sx)), Math.Max(1, (int)Math.Ceiling(Panel.ActualHeight * sy)));
    }

    void Create()
    {
        if (Handle != IntPtr.Zero || _disposed || !Native.Ready) return;
        var (w, h) = PixelSize();
        Handle = Native.cv_surface_create(w, h, _flags);
        if (Handle == IntPtr.Zero) return;
        IntPtr unk = WinRT.MarshalInspectable<object>.FromManaged(Panel);
        try { Native.cv_surface_attach(Handle, unk); }
        finally { Marshal.Release(unk); }
        Resize();
        Ready?.Invoke();
    }

    void Resize()
    {
        if (Handle == IntPtr.Zero) return;
        var (w, h) = PixelSize();
        Native.cv_surface_resize(Handle, w, h, Panel.CompositionScaleX, Panel.CompositionScaleY);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (Handle != IntPtr.Zero) Native.cv_surface_destroy(Handle);
        Handle = IntPtr.Zero;
    }
}
