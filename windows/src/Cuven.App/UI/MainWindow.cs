using Cuven.App.Native;
using Cuven.Core;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace Cuven.App.UI;

/// <summary>
/// 主窗口（Mac 风格）：不要 Windows 的标题栏和右上角三个按钮，左上角是红黄绿（关闭 / 最小化 / 全屏）；
/// 顶上那一条空白处能拖动窗口、双击最大化（InputNonClientPointerSource 的标题栏区域，按钮所在的地方让出来）。
/// 内容是登录页或主界面，播放器盖在最上层
/// </summary>
public sealed partial class MainWindow : Window
{
    public static new MainWindow Current { get; private set; } = null!;
    public IntPtr Hwnd { get; }
    const double CaptionHeight = 52;
    readonly Grid _root = new();
    readonly ContentPresenter _content = new();
    readonly Grid _overlay = new() { Visibility = Visibility.Collapsed };
    readonly TrafficLights _lights;
    readonly InputNonClientPointerSource? _nc;
    public Shell? Shell { get; private set; }
    public PlayerView? Player { get; private set; }
    public XamlRoot? Root => _root.XamlRoot;
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _dragTimer;

    public MainWindow()
    {
        Current = this;
        Title = "Cuven";
        Hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        ExtendsContentIntoTitleBar = true;
        // 窗口本身是磨砂玻璃：桌面在窗口后面被模糊（窗口不在前台时系统自动换成实色，省电）
        SystemBackdrop = new DesktopAcrylicBackdrop();
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Collapsed;   // 系统的最小化 / 最大化 / 关闭不要了
        try { AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "cuven.ico")); } catch { }
        var scale = Win32.GetDpiForWindow(Hwnd) / 96.0;
        if (scale <= 0) scale = 1;
        // 第一次打开：1360×860，屏幕小就按工作区的九成，居中（Mac 上新窗口也是在屏幕中间偏上）
        try
        {
            var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            int ww = Math.Min((int)(1360 * scale), (int)(work.Width * 0.92)), wh = Math.Min((int)(860 * scale), (int)(work.Height * 0.92));
            AppWindow.MoveAndResize(new RectInt32(work.X + (work.Width - ww) / 2, work.Y + Math.Max(0, (work.Height - wh) / 3), ww, wh));
        }
        catch { AppWindow.Resize(new SizeInt32((int)(1360 * scale), (int)(860 * scale))); }
        if (AppWindow.Presenter is OverlappedPresenter op) { op.PreferredMinimumWidth = (int)(900 * scale); op.PreferredMinimumHeight = (int)(600 * scale); }
        try { _nc = InputNonClientPointerSource.GetForWindowId(AppWindow.Id); } catch { }

        _lights = new TrafficLights(() => Close(), Minimize, () => SetFullScreen(!IsFullScreen))
        {
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(22, 22, 0, 0),
        };
        _root.Children.Add(_content);
        _root.Children.Add(_overlay);
        _root.Children.Add(_lights);
        Content = _root;
        _root.SizeChanged += (_, _) => UpdateDragRegions();

        Activated += (_, e) => _lights.SetActive(e.WindowActivationState != WindowActivationState.Deactivated);
        AppWindow.Changed += (_, e) =>
        {
            if (e.DidPositionChange || e.DidSizeChange) Player?.DisplayMaybeChanged();
            if (e.DidPresenterChange) UpdateDragRegions();
        };
        // 最小化、又没在播：整个进程进 EcoQoS（Win11 效率模式），回来恢复
        VisibilityChanged += (_, e) =>
        {
            if (!Native.Native.Ready) return;
            Native.Native.cv_process_eco(!e.Visible && Player is null && Settings.Shared.Efficiency ? 1 : 0);
        };
        Closed += (_, _) =>
        {
            Player?.Close();
            PlaybackHistory.Shared.Save();
        };

        if (Settings.Shared.SignedIn) ShowShell();
        else ShowLogin();
    }

    void Minimize()
    {
        if (AppWindow.Presenter is OverlappedPresenter op) op.Minimize();
        else { SetFullScreen(false); if (AppWindow.Presenter is OverlappedPresenter o2) o2.Minimize(); }
    }

    /// <summary>标题栏那一条：空白处拖动窗口，按钮让出来（按物理像素算）</summary>
    public void UpdateDragRegions()
    {
        if (_nc is null) return;
        _dragTimer ??= DispatcherQueue.CreateTimer().With(t =>
        {
            t.Interval = TimeSpan.FromMilliseconds(60);
            t.IsRepeating = false;
            t.Tick += (_, _) => ApplyDragRegions();
        });
        _dragTimer.Stop();
        _dragTimer.Start();
    }

    void ApplyDragRegions()
    {
        if (_nc is null || _root.XamlRoot is null) return;
        var s = _root.XamlRoot.RasterizationScale;
        var w = _root.ActualWidth;
        var controls = new List<FrameworkElement> { _lights };
        if (Player is not null) controls.AddRange(Player.TitleControls());
        else if (Shell is not null) controls.AddRange(Shell.TitleControls());
        var pass = new List<RectInt32>();
        foreach (var c in controls)
        {
            if (c.Visibility != Visibility.Visible || c.ActualWidth <= 0 || c.XamlRoot is null) continue;
            var r = c.TransformToVisual(_root).TransformBounds(new Windows.Foundation.Rect(0, 0, c.ActualWidth, c.ActualHeight));
            pass.Add(new RectInt32((int)(r.X * s), (int)(r.Y * s), (int)Math.Ceiling(r.Width * s), (int)Math.Ceiling(r.Height * s)));
        }
        try
        {
            _nc.SetRegionRects(NonClientRegionKind.Caption, new[] { new RectInt32(0, 0, (int)(w * s), (int)(CaptionHeight * s)) });
            _nc.SetRegionRects(NonClientRegionKind.Passthrough, pass.ToArray());
        }
        catch (Exception e) { App.Log("拖动区域：" + e.Message); }
    }

    public void ShowLogin()
    {
        Shell?.Dispose();
        Shell = null;
        _lights.SetLight(true);
        _content.Content = new LoginPage();
        Mac.Enter((UIElement)_content.Content);
        UpdateDragRegions();
    }

    public void ShowShell()
    {
        if (_content.Content is LoginPage lp) lp.Dispose();
        _lights.SetLight(false);
        Shell = new Shell();
        _content.Content = Shell;
        Mac.Enter(Shell);
        UpdateDragRegions();
    }

    public void SignedIn(LoginResult r)
    {
        Settings.Shared.SignIn(r);
        if (r.Method == "password") AccountApi.Notify("login_alert", r.Username, "password");
        ShowShell();
    }

    public void SignOut()
    {
        RequestCenter.Shared.Stop();
        Settings.Shared.SignOut();
        ShowLogin();
    }

    // ── 播放器（盖在最上层） ──
    public void Play(PlayRequest req)
    {
        Player?.Close();
        Player = new PlayerView(req);
        _overlay.Children.Clear();
        _overlay.Children.Add(Player);
        _overlay.Visibility = Visibility.Visible;
        Mac.Enter(Player);
        Player.Focus(FocusState.Programmatic);
        UpdateDragRegions();
    }

    public void ClosePlayer()
    {
        if (Player is null) return;
        Player.Close();
        Player = null;
        _overlay.Children.Clear();
        _overlay.Visibility = Visibility.Collapsed;
        _lights.Opacity = 1;
        SetFullScreen(false);
        Shell?.Refresh();
        UpdateDragRegions();
    }

    /// <summary>播放器控制条藏起来时红黄绿也一起淡掉</summary>
    public void ShowChrome(bool on)
    {
        _lights.OpacityTransition ??= new ScalarTransition { Duration = TimeSpan.FromMilliseconds(200) };
        _lights.Opacity = on ? 1 : 0;
    }

    public bool IsFullScreen => AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;

    public void SetFullScreen(bool on)
    {
        if (on == IsFullScreen) return;
        AppWindow.SetPresenter(on ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Overlapped);
        if (!on) AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Collapsed;
    }

    public IntPtr Monitor => Win32.MonitorFromWindow(Hwnd, Win32.MONITOR_DEFAULTTONEAREST);
}
