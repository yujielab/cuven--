using Cuven.App.Native;
using Cuven.Core;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Graphics;

namespace Cuven.App.UI;

/// <summary>主窗口：Mica 背景、自己画的标题栏；内容是登录页或主界面，播放器盖在最上层</summary>
public sealed partial class MainWindow : Window
{
    public static new MainWindow Current { get; private set; } = null!;
    public IntPtr Hwnd { get; }
    readonly Grid _root = new();
    readonly Grid _titleBar = new() { Height = 44, VerticalAlignment = VerticalAlignment.Top };
    readonly TextBlock _titleText;
    readonly ContentPresenter _content = new();
    readonly Grid _overlay = new() { Visibility = Visibility.Collapsed };
    public Shell? Shell { get; private set; }
    public PlayerView? Player { get; private set; }
    public XamlRoot? Root => _root.XamlRoot;

    public MainWindow()
    {
        Current = this;
        Title = "Cuven";
        Hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        ExtendsContentIntoTitleBar = true;
        SystemBackdrop = new MicaBackdrop { Kind = Microsoft.UI.Composition.SystemBackdrops.MicaKind.BaseAlt };
        try { AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "cuven.ico")); } catch { }
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        var scale = Win32.GetDpiForWindow(Hwnd) / 96.0;
        if (scale <= 0) scale = 1;
        AppWindow.Resize(new SizeInt32((int)(1360 * scale), (int)(860 * scale)));
        if (AppWindow.Presenter is OverlappedPresenter op) { op.PreferredMinimumWidth = (int)(960 * scale); op.PreferredMinimumHeight = (int)(620 * scale); }

        _titleText = U.T("Cuven", 12, null, U.Dim);
        _titleBar.Children.Add(U.H(10,
            new Image { Width = 18, Height = 18, Source = U.Bitmap(Path.Combine(AppContext.BaseDirectory, "Assets", "cuven-256.png"), 36) },
            _titleText).With(s => { s.Margin = new Thickness(16, 0, 0, 0); s.VerticalAlignment = VerticalAlignment.Center; }));
        _content.ContentTransitions = new TransitionCollection { new ContentThemeTransition() };
        _root.Children.Add(_content);
        _root.Children.Add(_titleBar);
        _root.Children.Add(_overlay);
        Content = _root;
        SetTitleBar(_titleBar);

        Activated += (_, e) =>
        {
            var deactivated = e.WindowActivationState == WindowActivationState.Deactivated;
            _titleText.Foreground = deactivated ? U.Faint : U.Dim;
        };
        AppWindow.Changed += (_, e) => { if (e.DidPositionChange || e.DidSizeChange) Player?.DisplayMaybeChanged(); };
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

    void SetTheme(ElementTheme t)
    {
        _root.RequestedTheme = t;
        var tb = AppWindow.TitleBar;
        var fg = t == ElementTheme.Light ? Colors.Black : Colors.White;
        tb.ButtonForegroundColor = fg;
        tb.ButtonHoverForegroundColor = fg;
        tb.ButtonBackgroundColor = Colors.Transparent;
        tb.ButtonInactiveBackgroundColor = Colors.Transparent;
        tb.ButtonHoverBackgroundColor = t == ElementTheme.Light ? Windows.UI.Color.FromArgb(24, 0, 0, 0) : Windows.UI.Color.FromArgb(30, 255, 255, 255);
        _titleText.Foreground = t == ElementTheme.Light ? new SolidColorBrush(Windows.UI.Color.FromArgb(160, 0, 0, 0)) : U.Dim;
    }

    public void ShowLogin()
    {
        Shell?.Dispose();
        Shell = null;
        SetTheme(ElementTheme.Light);
        _content.Content = new LoginPage();
    }

    public void ShowShell()
    {
        if (_content.Content is LoginPage lp) lp.Dispose();
        SetTheme(ElementTheme.Dark);
        Shell = new Shell();
        _content.Content = Shell;
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
        _titleBar.Visibility = Visibility.Collapsed;
        SetTitleBar(null);
        Player.Focus(FocusState.Programmatic);
    }

    public void ClosePlayer()
    {
        if (Player is null) return;
        Player.Close();
        Player = null;
        _overlay.Children.Clear();
        _overlay.Visibility = Visibility.Collapsed;
        _titleBar.Visibility = Visibility.Visible;
        SetTitleBar(_titleBar);
        SetFullScreen(false);
        Shell?.Refresh();
    }

    public bool IsFullScreen => AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;

    public void SetFullScreen(bool on)
    {
        if (on == IsFullScreen) return;
        AppWindow.SetPresenter(on ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Overlapped);
    }

    public IntPtr Monitor => Win32.MonitorFromWindow(Hwnd, Win32.MONITOR_DEFAULTTONEAREST);
}
