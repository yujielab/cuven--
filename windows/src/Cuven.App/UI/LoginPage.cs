using Cuven.App.Native;
using Cuven.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Cuven.App.UI;

/// <summary>
/// 登录：先显示配对粒子云（已登录 Cuven 的 iPhone「账户 → 扫描登录其他设备」对准它，面容 ID 批准），
/// 下面一个「使用账户密码登录」。云画在浅色底上（相机按蓝色程度读码，和网页版、iOS 一样）
/// </summary>
public sealed partial class LoginPage : Grid, IDisposable
{
    static readonly Brush Ink = new SolidColorBrush(Color.FromArgb(255, 29, 29, 31));
    static readonly Brush Sub = new SolidColorBrush(Color.FromArgb(255, 110, 110, 115));
    static readonly Brush Bad = new SolidColorBrush(Color.FromArgb(255, 215, 0, 21));

    readonly Grid _pairPane = new();
    readonly StackPanel _pwPane;
    readonly Glass _pwCard;
    readonly TextBlock _status = U.T("", 13, null, Sub, 2);
    readonly TextBox _user = new() { PlaceholderText = "用户名", Width = 320, Height = 40 };
    readonly PasswordBox _pass = new() { PlaceholderText = "密码", Width = 320, Height = 40 };
    readonly TextBlock _pwStatus = U.T("", 13, null, Sub, 3);
    readonly MacButton _signIn;
    NativeSurface? _surface;
    IntPtr _cloud;
    PairLogin? _pair;
    bool _disposed;

    public LoginPage()
    {
        RequestedTheme = ElementTheme.Light;
        Background = new SolidColorBrush(Color.FromArgb(255, 245, 245, 247));   // macOS 浅色窗口的底色

        // ── 扫码 ──
        var title = U.T("用 iPhone 扫描登录", 30, FontWeights.SemiBold, Ink);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        var copy = U.T("Cuven 光学安全保护措施是迄今为止最安全的加密保护措施，Cuven 的安全团队日夜保护您的账户。", 14, null, Sub, 3);
        copy.TextAlignment = TextAlignment.Center;
        copy.MaxWidth = 440;
        copy.HorizontalAlignment = HorizontalAlignment.Center;
        _status.HorizontalAlignment = HorizontalAlignment.Center;
        _status.TextAlignment = TextAlignment.Center;
        var cloudHost = new Grid { Width = 360, Height = 360, HorizontalAlignment = HorizontalAlignment.Center };
        if (Native.Native.Ready)
        {
            _surface = new NativeSurface(Native.Native.SurfaceTransparent);
            _surface.Ready += StartCloud;
            cloudHost.Children.Add(_surface.Panel);
        }
        else
        {
            cloudHost.Children.Add(U.T(Native.Native.InitError ?? "这台电脑画不了粒子云", 14, null, Sub, 3).With(t => { t.VerticalAlignment = VerticalAlignment.Center; t.HorizontalAlignment = HorizontalAlignment.Center; }));
        }
        var toPassword = new HyperlinkButton { Content = "使用账户密码登录", HorizontalAlignment = HorizontalAlignment.Center, FontSize = 15 };
        toPassword.Click += (_, _) => ShowPassword(true);
        var col = U.V(14, title, cloudHost, copy, _status, toPassword);
        col.HorizontalAlignment = HorizontalAlignment.Center;
        col.VerticalAlignment = VerticalAlignment.Center;
        _pairPane.Children.Add(col);

        // ── 账户密码 ──
        _signIn = MacButton.Pill("登录", null, () => _ = SignInAsync(), MacButton.Style.Accent, 38);
        _signIn.Width = 300;
        _pass.KeyDown += async (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; await SignInAsync(); } };
        _user.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; _pass.Focus(FocusState.Keyboard); } };
        var back = new HyperlinkButton { Content = "用 iPhone 扫描登录", HorizontalAlignment = HorizontalAlignment.Center };
        back.Click += (_, _) => ShowPassword(false);
        var logo = new Image { Width = 72, Height = 72, Source = U.Bitmap(Path.Combine(AppContext.BaseDirectory, "Assets", "cuven-256.png"), 144), HorizontalAlignment = HorizontalAlignment.Center };
        var pwTitle = U.T("登录 Cuven", 28, FontWeights.SemiBold, Ink);
        pwTitle.HorizontalAlignment = HorizontalAlignment.Center;
        _pwStatus.MaxWidth = 320;
        _pwStatus.HorizontalAlignment = HorizontalAlignment.Center;
        _pwStatus.TextAlignment = TextAlignment.Center;
        _user.Width = _pass.Width = 300;
        _pwPane = U.V(14, logo, pwTitle, _user, _pass, _signIn, _pwStatus, back);
        _pwPane.Margin = new Thickness(30, 28, 30, 24);
        // 账户密码：一张浅色的磨砂玻璃卡（Mac 的登录窗口那样）
        _pwCard = new Glass(20, GlassKind.Light) { Content = _pwPane, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };

        var backdrop = new Grid { Background = Background };
        Children.Add(backdrop);
        Children.Add(_pairPane);
        Children.Add(_pwCard);
        Mac.Shadow(_pwCard, backdrop, 40);
        if (!Native.Native.Ready) ShowPassword(true);
        else StartPairing();
        Unloaded += (_, _) => Dispose();
    }

    void ShowPassword(bool on)
    {
        _pairPane.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        _pwCard.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        Mac.Enter(on ? _pwCard : _pairPane);
        if (_cloud != IntPtr.Zero) Native.Native.cv_cloud_run(_cloud, on ? 0 : 1);
        if (on) DispatcherQueue.TryEnqueue(() => _user.Focus(FocusState.Programmatic));
    }

    unsafe void StartCloud()
    {
        if (_surface is null || _cloud != IntPtr.Zero) return;
        var (px, w, h) = Native.Native.LoadGray(Path.Combine(AppContext.BaseDirectory, "Assets", "pair-density.png"));
        fixed (byte* p = px)
            _cloud = Native.Native.cv_cloud_create(_surface.Handle, p, w, h);
        if (_cloud == IntPtr.Zero) { _status.Text = "这台电脑画不了粒子云：请使用账户密码登录"; return; }
        Native.Native.cv_cloud_run(_cloud, 1);
        if (_pendingCode is { } c) ApplyCode(c);
    }

    byte[]? _pendingCode;

    unsafe void ApplyCode(byte[] grid)
    {
        if (_cloud == IntPtr.Zero) { _pendingCode = grid; return; }
        var spec = PairSpec.Shared;
        fixed (byte* p = grid)
            Native.Native.cv_cloud_set_code(_cloud, p, spec.CodeGrid, (float)spec.CodeScale, (float)spec.CodeSpin);
    }

    void StartPairing()
    {
        _pair = new PairLogin("Windows · " + Environment.MachineName);
        _pair.StatusChanged += s => DispatcherQueue.TryEnqueue(() => _status.Text = s);
        _pair.CodeChanged += o =>
        {
            var grid = PairCodec.CodeTexture(o.Id, o.Secret);
            DispatcherQueue.TryEnqueue(() => ApplyCode(grid));
        };
        _pair.Approved += r => DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed) return;
            MainWindow.Current.SignedIn(r);
        });
        _pair.Start();
    }

    async Task SignInAsync()
    {
        var name = _user.Text.Trim();
        if (name.Length == 0) { _user.Focus(FocusState.Keyboard); return; }
        if (_pass.Password.Length == 0) { _pass.Focus(FocusState.Keyboard); return; }
        _signIn.Enabled = false;
        _pwStatus.Foreground = Sub;
        _pwStatus.Text = "正在验证…";
        try
        {
            var r = await AccountApi.PasswordLoginAsync(name, _pass.Password);
            _pwStatus.Text = "";
            MainWindow.Current.SignedIn(r);
        }
        catch (LoginFailure f)
        {
            _pwStatus.Foreground = Bad;
            _pwStatus.Text = f.Message;
            if (f.Kind == LoginError.Wrong) { _pass.Focus(FocusState.Keyboard); _pass.SelectAll(); }
        }
        catch (Exception e)
        {
            _pwStatus.Foreground = Bad;
            _pwStatus.Text = CuvenException.Friendly(e);
        }
        finally { _signIn.Enabled = true; }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _pair?.Stop();
        if (_cloud != IntPtr.Zero) Native.Native.cv_cloud_destroy(_cloud);
        _cloud = IntPtr.Zero;
        _surface?.Dispose();
    }
}
