using System.Numerics;
using Cuven.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Cuven.App.UI;

/// <summary>一页（不用 Frame / Page：那要 XAML 的类型信息）</summary>
public abstract partial class View : Grid
{
    public virtual string Header => "";
    /// <summary>显示出来（第一次、或者从后面的页返回）</summary>
    public virtual void Shown() { }
    /// <summary>从导航栈里拿掉了</summary>
    public virtual void Closed() { }
    /// <summary>回到这一页时要不要重画（播放完回来）</summary>
    public virtual void Refresh() { }
}

/// <summary>页面左右的留白（和网页版一样：1440 宽时 72 像素，窄了收一点）</summary>
static class Inset
{
    public static double Left => Shell.Current?.ContentLeft ?? 64;
    public const double Top = 72;
    public static double Right => Left;
    public static event Action? Changed;
    public static void Raise() => Changed?.Invoke();

    public static T Track<T>(T e, Action<T, double> apply) where T : FrameworkElement
    {
        void on() => apply(e, Left);
        apply(e, Left);
        e.Loaded += (_, _) => { Changed -= on; Changed += on; on(); };
        e.Unloaded += (_, _) => Changed -= on;
        return e;
    }
}

/// <summary>
/// 主界面（照网页版 tv.cuven.us）：纯黑的底，内容铺满窗口；底下正中浮着一条磨砂玻璃的导航（头像 · 主页 · 资料库 · 请求 · 下载），
/// 右边单独一颗搜索圆钮；进了详情页左上角一颗磨砂圆钮返回。红黄绿留在左上角（窗口按钮）
/// </summary>
public sealed partial class Shell : Grid, IDisposable
{
    public static Shell? Current { get; private set; }
    readonly ContentPresenter _host = new();
    readonly Dock _dock;
    readonly MacButton _back;
    readonly Stack<View> _stack = new();
    readonly Stack<View> _forward = new();
    readonly DispatcherQueueTimerWrapper _libTimer;
    double _swipe;
    long _swipeAt;
    double _left = 64;

    public double ContentLeft => _left;

    public Shell()
    {
        Current = this;
        Background = Mac.CanvasBrush;
        Children.Add(_host);

        _dock = new Dock(tag => { if (tag == "search") Go(new SearchView("")); else Root(tag); });
        Children.Add(_dock);

        // 左上角（红黄绿右边）：返回
        _back = MacButton.Round("", () => Back(), "返回（Esc）", 40, 15);
        _back.HorizontalAlignment = HorizontalAlignment.Left;
        _back.VerticalAlignment = VerticalAlignment.Top;
        _back.Margin = new Thickness(92, 12, 0, 0);
        _back.Visibility = Visibility.Collapsed;
        Children.Add(_back);

        // ── 键盘、触控板两指滑动后退、鼠标侧键 ──
        AddKey(VirtualKey.F, VirtualKeyModifiers.Control, () => Go(new SearchView("")));
        AddKey((VirtualKey)219, VirtualKeyModifiers.Control, () => Back());
        AddKey((VirtualKey)221, VirtualKeyModifiers.Control, () => Forward());
        AddKey(VirtualKey.Left, VirtualKeyModifiers.Menu, () => Back());
        AddKey(VirtualKey.Right, VirtualKeyModifiers.Menu, () => Forward());
        AddKey((VirtualKey)188, VirtualKeyModifiers.Control, () => Root("account"));
        var tags = new[] { "home", "library", "requests", "downloads" };
        for (int i = 0; i < tags.Length; i++) { var t = tags[i]; AddKey(VirtualKey.Number1 + i, VirtualKeyModifiers.Control, () => Root(t)); }
        PointerPressed += (_, e) =>
        {
            var p = e.GetCurrentPoint(this).Properties;
            if (p.IsXButton1Pressed) e.Handled = Back();
            else if (p.IsXButton2Pressed) e.Handled = Forward();
        };
        AddHandler(PointerWheelChangedEvent, new PointerEventHandler(OnWheel), false);
        SizeChanged += (_, e) =>
        {
            // 留白：1440 宽 72，窄窗口按比例收，最少 28
            var l = Math.Clamp(e.NewSize.Width * 0.05, 28, 72);
            if (Math.Abs(l - _left) > 0.5) { _left = l; Inset.Raise(); }
            MainWindow.Current.UpdateDragRegions();
        };

        Root("home");
        var user = Settings.Shared.Username;
        if (user is not null && user != "selftest") RequestCenter.Shared.Start(user);
        RequestCenter.Shared.Changed += () => DispatcherQueue.TryEnqueue(() => _dock.Badge("requests", RequestCenter.Shared.ActiveCount));
        RequestCenter.Shared.Milestone += (r, s) => Notifications.Show(r.Title, s);
        DownloadManager.Shared.ResumeAll();
        _ = LibraryStore.Shared.RefreshAsync();
        _libTimer = new DispatcherQueueTimerWrapper(DispatcherQueue, TimeSpan.FromMinutes(20), () => _ = LibraryStore.Shared.RefreshAsync());
    }

    void AddKey(VirtualKey k, VirtualKeyModifiers m, Action a)
    {
        var acc = new KeyboardAccelerator { Key = k, Modifiers = m };
        acc.Invoked += (_, e) => { e.Handled = true; a(); };
        KeyboardAccelerators.Add(acc);
    }

    // 触控板两指横滑（系统当成横向滚轮）：没被横着滚的货架吃掉的，往右滑够一段就后退
    void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(this).Properties;
        if (!p.IsHorizontalMouseWheel) return;
        var now = Environment.TickCount64;
        if (now - _swipeAt > 400) _swipe = 0;
        _swipeAt = now;
        _swipe += p.MouseWheelDelta;
        if (_swipe < -360) { _swipe = 0; Back(); e.Handled = true; }
        else if (_swipe > 360) { _swipe = 0; Forward(); e.Handled = true; }
    }

    /// <summary>标题栏那一条里能点的东西（不能当拖动区）</summary>
    public IEnumerable<FrameworkElement> TitleControls()
    {
        if (_back.Visibility == Visibility.Visible) yield return _back;
    }

    View Make(string tag) => tag switch
    {
        "library" => new LibraryFeedView(),
        "requests" => new RequestsView(),
        "downloads" => new DownloadsView(),
        "account" => new AccountView(),
        _ => new HomeView(),
    };

    /// <summary>换到某个顶层页（清掉返回栈）</summary>
    public void Root(string tag)
    {
        while (_stack.Count > 0) _stack.Pop().Closed();
        ClearForward();
        _dock.Select(tag);
        Show(Make(tag));
    }

    public void Go(View v)
    {
        ClearForward();
        Show(v);
    }

    void ClearForward() { while (_forward.Count > 0) _forward.Pop().Closed(); }

    void Show(View v)
    {
        _stack.Push(v);
        _host.Content = v;
        Mac.Enter(v);
        UpdateNav();
        v.Shown();
    }

    void UpdateNav()
    {
        _back.Visibility = _stack.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        MainWindow.Current.UpdateDragRegions();
    }

    public bool Back()
    {
        if (_stack.Count <= 1) return false;
        _forward.Push(_stack.Pop());
        var v = _stack.Peek();
        _host.Content = v;
        Mac.Enter(v);
        UpdateNav();
        v.Shown();
        return true;
    }

    public bool Forward()
    {
        if (_forward.Count == 0) return false;
        var v = _forward.Pop();
        _stack.Push(v);
        _host.Content = v;
        Mac.Enter(v);
        UpdateNav();
        v.Shown();
        return true;
    }

    public void Refresh() { if (_stack.Count > 0) _stack.Peek().Refresh(); }

    public void Dispose()
    {
        _libTimer.Stop();
        while (_stack.Count > 0) _stack.Pop().Closed();
        ClearForward();
        if (Current == this) Current = null;
    }
}

/// <summary>
/// 底部导航（网页版的 dock）：一条磨砂玻璃胶囊（左边头像，然后 主页 / 资料库 / 请求 / 下载：图标在上、字在下，选中的变蓝、
/// 底下垫一块玻璃，切换时那块玻璃弹簧滑过去），右边隔开一颗磨砂的搜索圆钮
/// </summary>
public sealed partial class Dock : StackPanel
{
    readonly Glass _bar = new(32, GlassKind.Regular) { Height = 64 };
    readonly Grid _tabs = new() { Margin = new Thickness(4, 0, 4, 0) };
    readonly Glass _pill = new(26, GlassKind.Selection) { Height = 52, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left, IsHitTestVisible = false };
    readonly Dictionary<string, (Grid cell, FontIcon icon, TextBlock text, Border badge)> _cells = new();
    readonly PersonPicture _avatar = new() { Width = 40, Height = 40 };
    readonly Action<string> _go;
    const double TabWidth = 112;

    public Dock(Action<string> go)
    {
        _go = go;
        Orientation = Orientation.Horizontal;
        Spacing = 12;
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Bottom;
        Margin = new Thickness(0, 0, 0, 22);

        var inner = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 6, 0) };
        // 头像（账户与设置）
        var av = new Grid { Width = 44, Height = 44, CornerRadius = new CornerRadius(22), Background = Mac.Clear, VerticalAlignment = VerticalAlignment.Center };
        _avatar.DisplayName = Settings.Shared.Username ?? "";
        av.Children.Add(_avatar);
        av.Tapped += (_, _) => { _go("account"); Select("account"); };
        ToolTipService.SetToolTip(av, "账户与设置（Ctrl+,）");
        Mac.Pressable(av, 1.06f, 0.94f);
        inner.Children.Add(av);
        _tabs.Children.Add(_pill);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (tag, text, glyph) in new[] { ("home", "主页", ""), ("library", "资料库", ""), ("requests", "请求", ""), ("downloads", "下载", "") })
            row.Children.Add(Cell(tag, text, glyph));
        _tabs.Children.Add(row);
        inner.Children.Add(_tabs);
        _bar.Content = inner;
        Children.Add(_bar);

        var search = new Glass(32, GlassKind.Regular) { Width = 64, Height = 64, Content = U.Icon("", 19).With(i => { i.Foreground = Mac.Label; i.HorizontalAlignment = HorizontalAlignment.Center; i.VerticalAlignment = VerticalAlignment.Center; }) };
        search.Tapped += (_, _) => _go("search");
        ToolTipService.SetToolTip(search, "搜索（Ctrl+F）");
        Mac.Pressable(search, 1.06f, 0.94f);
        Children.Add(search);
        _ = LoadAvatarAsync();
        Select("home", false);
    }

    UIElement Cell(string tag, string text, string glyph)
    {
        var icon = U.Icon(glyph, 19);
        icon.Foreground = Mac.Label;
        var label = Mac.Text(text, 11, FontWeights.SemiBold);
        label.HorizontalAlignment = HorizontalAlignment.Center;
        var badge = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(5, 0, 5, 1), Background = Mac.BlueBrush, Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 22, 0) };
        var stack = U.V(3, icon, label);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        var cell = new Grid { Width = TabWidth, Height = 56, Background = Mac.Clear, IsTabStop = true, UseSystemFocusVisuals = true };
        cell.Children.Add(stack);
        cell.Children.Add(badge);
        cell.Tapped += (_, _) => { Select(tag); _go(tag); };
        cell.KeyDown += (_, e) => { if (e.Key is VirtualKey.Enter or VirtualKey.Space) { Select(tag); _go(tag); } };
        cell.PointerPressed += (_, _) => Mac.SpringScale(stack, 0.92f, 0.7f, 30);
        cell.PointerReleased += (_, _) => Mac.SpringScale(stack, 1, 0.45f, 45);
        cell.PointerCaptureLost += (_, _) => Mac.SpringScale(stack, 1);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cell, text);
        _cells[tag] = (cell, icon, label, badge);
        return cell;
    }

    public void Select(string tag, bool animate = true)
    {
        int i = 0, idx = -1;
        foreach (var (t, c) in _cells)
        {
            bool on = t == tag;
            c.icon.Foreground = on ? Mac.BlueBrush : Mac.Label;
            c.text.Foreground = on ? Mac.BlueBrush : Mac.Label;
            if (on) idx = i;
            i++;
        }
        _pill.Width = TabWidth - 4;
        _pill.Opacity = idx >= 0 ? 1 : 0;
        if (idx < 0) return;
        var x = (float)(idx * TabWidth + 2);
        if (animate)
        {
            Mac.SpringMove(_pill, new Vector3(x, 0, 0), 0.7f, 50);
            Mac.SpringScaleXY(_pill, new Vector3(1.12f, 0.94f, 1), Vector3.One, 0.5f, 55);
        }
        else Mac.SpringMove(_pill, new Vector3(x, 0, 0), 1, 1);
    }

    public void Badge(string tag, int n)
    {
        if (!_cells.TryGetValue(tag, out var c)) return;
        c.badge.Visibility = n > 0 ? Visibility.Visible : Visibility.Collapsed;
        c.badge.Child = n > 0 ? Mac.Text(n.ToString(), 10, FontWeights.Bold) : null;
    }

    async Task LoadAvatarAsync()
    {
        var u = Settings.Shared.Username;
        if (u is null || u == "selftest") return;
        var url = await AccountApi.AvatarAsync(u);
        if (url is not null && U.Bitmap(url, 80) is { } b) _avatar.ProfilePicture = b;
    }
}

/// <summary>DispatcherQueue 上的定时器（停得掉）</summary>
sealed class DispatcherQueueTimerWrapper
{
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _t;
    public DispatcherQueueTimerWrapper(Microsoft.UI.Dispatching.DispatcherQueue q, TimeSpan every, Action tick)
    {
        _t = q.CreateTimer();
        _t.Interval = every;
        _t.IsRepeating = true;
        _t.Tick += (_, _) => tick();
        _t.Start();
    }
    public void Stop() => _t.Stop();
}
