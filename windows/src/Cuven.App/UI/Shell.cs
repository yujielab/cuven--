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

/// <summary>
/// 内容的左边距跟着侧边栏走（侧边栏浮在内容上：大图、海报从它下面过去，字和第一张卡从它右边开始）。
/// Inset.Track(元素, 左边距 → 设置) 登记一下，侧边栏收起 / 展开时自动改
/// </summary>
static class Inset
{
    public static double Left => Shell.Current?.ContentLeft ?? 32;
    public const double Top = 64;
    public const double Right = 36;
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
/// 主界面（Mac 风格）：内容铺满整个窗口；左边一块浮着的液态玻璃侧边栏（红黄绿三个按钮、搜索、分组、选中的那块玻璃会滑、底下是账户）；
/// 顶上一枚玻璃胶囊（后退 / 前进）。两指在触控板上往右滑 = 后退
/// </summary>
public sealed partial class Shell : Grid, IDisposable
{
    public static Shell? Current { get; private set; }
    const double SideWidth = 232, SideMargin = 10;
    readonly ContentPresenter _host = new();
    readonly Glass _side = new(18, GlassKind.Regular) { Width = SideWidth, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(SideMargin) };
    readonly Grid _list = new();
    readonly StackPanel _items = new() { Spacing = 2 };
    readonly Glass _pill = new(9, GlassKind.Selection) { Height = 34, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false };
    readonly Dictionary<string, SidebarItem> _byTag = new();
    readonly TextBox _search = new() { PlaceholderText = "搜索", BorderThickness = new Thickness(0), Background = Mac.Clear, FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(4, 5, 4, 5) };
    readonly StackPanel _toolbar = new() { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0) };
    readonly MacButton _back, _fwd, _toggleOpen, _toggleClose;
    readonly Stack<View> _stack = new();
    readonly Stack<View> _forward = new();
    readonly DispatcherQueueTimerWrapper _libTimer;
    readonly TextBlock _userName = Mac.Text("", 13, FontWeights.SemiBold);
    readonly PersonPicture _avatar = new() { Width = 30, Height = 30 };
    string _selected = "home";
    bool _sideVisible = true, _userHid;
    double _swipe;
    long _swipeAt;

    public double ContentLeft => _sideVisible ? SideMargin + SideWidth + 26 : 32;
    public bool SidebarVisible => _sideVisible;

    public Shell()
    {
        Current = this;
        Background = Mac.Clear;   // 每一页自己定底色：大图页实色，列表页半透明（透出窗口后面的磨砂）
        Children.Add(_host);

        // ── 侧边栏 ──
        var col = U.Rows("52", "auto", "*", "auto");
        _toggleClose = MacButton.Round("", () => SetSidebar(false, true), "隐藏边栏（Ctrl+Alt+S）", 28, 13, MacButton.Style.Plain);
        _toggleClose.HorizontalAlignment = HorizontalAlignment.Right;
        _toggleClose.VerticalAlignment = VerticalAlignment.Center;
        _toggleClose.Margin = new Thickness(0, 0, 10, 0);
        col.Children.Add(_toggleClose.At(0));
        // 搜索：一枚凹进去的小胶囊
        var searchBox = new Border
        {
            CornerRadius = new CornerRadius(9), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(22, 255, 255, 255)),
            Margin = new Thickness(12, 0, 12, 10), Height = 32,
        };
        foreach (var k in new[] { "TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused", "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused" })
            _search.Resources[k] = Mac.Clear;
        var sg = U.Cols("28", "*");
        sg.Children.Add(U.Icon("", 13).With(i => { i.Foreground = Mac.Secondary; i.HorizontalAlignment = HorizontalAlignment.Center; }).At(0, 0));
        sg.Children.Add(_search.At(0, 1));
        searchBox.Child = sg;
        _search.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter && _search.Text.Trim().Length > 0) { e.Handled = true; Go(new SearchView(_search.Text.Trim())); }
            if (e.Key == VirtualKey.Escape) { _search.Text = ""; Focus(FocusState.Programmatic); }
        };
        col.Children.Add(searchBox.At(1));

        Section("Cuven");
        Item("home", "首页", "");
        Item("movies", "电影", "");
        Item("series", "剧集", "");
        Section("我的");
        Item("requests", "请求", "");
        Item("downloads", "下载", "");
        _list.Children.Add(_pill);
        _list.Children.Add(_items);
        _list.Margin = new Thickness(10, 0, 10, 0);
        col.Children.Add(new ScrollViewer { Content = _list, HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden }.At(2));

        // 底下：账户
        var acct = U.Cols("auto", "*", "auto");
        acct.ColumnSpacing = 10;
        acct.Padding = new Thickness(10, 8, 10, 8);
        acct.CornerRadius = new CornerRadius(10);
        acct.Background = Mac.Clear;
        _avatar.DisplayName = Settings.Shared.Username ?? "";
        _userName.Text = Settings.Shared.Username ?? "";
        acct.Children.Add(_avatar.At(0, 0));
        acct.Children.Add(U.V(0, _userName, Mac.Text("账户与设置", 11, null, Mac.Tertiary)).With(v => v.VerticalAlignment = VerticalAlignment.Center).At(0, 1));
        acct.Children.Add(U.Icon("", 11).With(i => { i.Foreground = Mac.Tertiary; i.VerticalAlignment = VerticalAlignment.Center; }).At(0, 2));
        acct.PointerEntered += (_, _) => acct.Background = Mac.Hover;
        acct.PointerExited += (_, _) => acct.Background = Mac.Clear;
        acct.Tapped += (_, _) => Root("account");
        var footer = new Border { BorderBrush = Mac.Separator, BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(6, 6, 6, 8), Child = acct };
        col.Children.Add(footer.At(3));
        _side.Content = col;
        Children.Add(_side);
        Mac.Shadow(_side, _host, 28);
        _side.TranslationTransition = new Vector3Transition { Duration = TimeSpan.FromMilliseconds(320) };
        _side.OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(220) };

        // ── 顶上的玻璃胶囊：后退 / 前进；边栏藏起来时多一个「显示边栏」 ──
        _toggleOpen = MacButton.Round("", () => SetSidebar(true, true), "显示边栏（Ctrl+Alt+S）", 34, 14);
        _toggleOpen.Visibility = Visibility.Collapsed;
        _back = new MacButton(MacButton.Style.Plain, U.Icon("", 13).With(i => i.Foreground = Mac.Label), 30, "后退（Ctrl+[）");
        _fwd = new MacButton(MacButton.Style.Plain, U.Icon("", 13).With(i => i.Foreground = Mac.Label), 30, "前进（Ctrl+]）");
        _back.Width = _fwd.Width = 34;
        _back.Click += () => Back();
        _fwd.Click += () => Forward();
        var navCap = new Glass(17, GlassKind.Clear) { Height = 34, Content = U.H(0, _back, _fwd).With(s => s.Margin = new Thickness(2, 2, 2, 2)) };
        _toolbar.Children.Add(_toggleOpen);
        _toolbar.Children.Add(navCap);
        Children.Add(_toolbar);
        PlaceToolbar();

        // ── 键盘（Mac 的 ⌘ 换成 Ctrl）、触控板两指滑动后退、鼠标侧键 ──
        AddKey(VirtualKey.F, VirtualKeyModifiers.Control, () => { if (!_sideVisible) SetSidebar(true, true); _search.Focus(FocusState.Keyboard); _search.SelectAll(); });
        AddKey((VirtualKey)219, VirtualKeyModifiers.Control, () => Back());
        AddKey((VirtualKey)221, VirtualKeyModifiers.Control, () => Forward());
        AddKey(VirtualKey.Left, VirtualKeyModifiers.Menu, () => Back());
        AddKey(VirtualKey.Right, VirtualKeyModifiers.Menu, () => Forward());
        AddKey(VirtualKey.S, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, () => SetSidebar(!_sideVisible, true));
        AddKey((VirtualKey)188, VirtualKeyModifiers.Control, () => Root("account"));
        var tags = new[] { "home", "movies", "series", "requests", "downloads" };
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
            // 窗口窄了自动收起边栏（用户自己收起 / 展开过就听用户的）
            if (!_userHid) SetSidebar(e.NewSize.Width >= 860, false);
            MainWindow.Current.UpdateDragRegions();
        };

        Root("home");
        _ = LoadAvatarAsync();
        var user = Settings.Shared.Username;
        if (user is not null && user != "selftest") RequestCenter.Shared.Start(user);
        RequestCenter.Shared.Changed += () => DispatcherQueue.TryEnqueue(UpdateBadge);
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

    // 触控板两指横滑：系统把它当成横向滚轮。没有被横着滚的货架吃掉的，往右滑够一段就后退
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

    async Task LoadAvatarAsync()
    {
        var u = Settings.Shared.Username;
        if (u is null || u == "selftest") return;
        var url = await AccountApi.AvatarAsync(u);
        if (url is not null && U.Bitmap(url, 60) is { } b) _avatar.ProfilePicture = b;
    }

    void Section(string title) =>
        _items.Children.Add(Mac.Text(title, 11, FontWeights.SemiBold, Mac.Tertiary).With(t => t.Margin = new Thickness(10, _items.Children.Count == 0 ? 2 : 14, 0, 4)));

    void Item(string tag, string text, string glyph)
    {
        var it = new SidebarItem(text, glyph);
        it.Tapped += (_, _) => Root(tag);
        it.KeyDown += (_, e) => { if (e.Key is VirtualKey.Enter or VirtualKey.Space) Root(tag); };
        _byTag[tag] = it;
        _items.Children.Add(it);
    }

    /// <summary>选中的那块玻璃滑到这一格：路上竖着拉长一点再收回（液态的感觉）</summary>
    void Select(string tag, bool animate = true)
    {
        _selected = tag;
        foreach (var (t, it) in _byTag) it.Selected = t == tag;
        if (!_byTag.TryGetValue(tag, out var target))
        {
            _pill.Opacity = 0;
            return;
        }
        void move()
        {
            var y = (float)target.TransformToVisual(_items).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
            _pill.Opacity = 1;
            if (animate)
            {
                Mac.SpringMove(_pill, new Vector3(0, y, 0), 0.68f, 50);
                Mac.SpringScaleXY(_pill, new Vector3(0.97f, 1.22f, 1), Vector3.One, 0.45f, 60);
            }
            else Mac.SpringMove(_pill, new Vector3(0, y, 0), 1f, 1);
        }
        if (target.ActualHeight > 0) move();
        else target.Loaded += (_, _) => move();
    }

    void UpdateBadge()
    {
        var n = RequestCenter.Shared.ActiveCount;
        if (_byTag.TryGetValue("requests", out var it)) it.Badge = n > 0 ? n.ToString() : null;
    }

    void SetSidebar(bool visible, bool user)
    {
        if (user) _userHid = !visible;
        if (visible == _sideVisible) return;
        _sideVisible = visible;
        // 边栏滑出去 / 滑回来，内容的左边距跟着变（用 XAML 的 Translation：投影跟着走）
        _side.Translation = new Vector3(visible ? 0 : -(float)(SideWidth + SideMargin + 20), 0, 28);
        _side.Opacity = visible ? 1 : 0;
        _side.IsHitTestVisible = visible;
        _toggleOpen.Visibility = visible ? Visibility.Collapsed : Visibility.Visible;
        PlaceToolbar();
        Inset.Raise();
        MainWindow.Current.UpdateDragRegions();
    }

    void PlaceToolbar() => _toolbar.Margin = new Thickness(_sideVisible ? SideMargin + SideWidth + 14 : 96, 12, 0, 0);

    /// <summary>标题栏那一条里能点的东西（不能当拖动区）</summary>
    public IEnumerable<FrameworkElement> TitleControls()
    {
        if (_sideVisible) yield return _toggleClose;
        yield return _toolbar;
    }

    View Make(string tag) => tag switch
    {
        "movies" => new BrowseView(BrowseKind.Movies),
        "series" => new BrowseView(BrowseKind.Series),
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
        Select(tag);
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
        _back.Opacity = _stack.Count > 1 ? 1 : 0.35;
        _fwd.Opacity = _forward.Count > 0 ? 1 : 0.35;
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

/// <summary>侧边栏的一格：图标 + 名字 + 角标。选中时图标变蓝（底下那块玻璃由 Shell 滑过来）</summary>
public sealed partial class SidebarItem : Grid
{
    readonly FontIcon _icon;
    readonly TextBlock _text;
    readonly Border _badge = new() { CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 1, 6, 1), Background = Mac.BlueBrush, Visibility = Visibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
    bool _selected;

    public SidebarItem(string text, string glyph)
    {
        Height = 34;
        CornerRadius = new CornerRadius(9);
        Padding = new Thickness(10, 0, 10, 0);
        Background = Mac.Clear;
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _icon = U.Icon(glyph, 15);
        _icon.Foreground = Mac.Secondary;
        _icon.HorizontalAlignment = HorizontalAlignment.Left;
        _text = Mac.Text(text, 13.5, FontWeights.Medium);
        _text.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(_icon.At(0, 0));
        Children.Add(_text.At(0, 1));
        Children.Add(_badge.At(0, 2));
        PointerEntered += (_, _) => { if (!_selected) Background = Mac.Hover; };
        PointerExited += (_, _) => Background = Mac.Clear;
        PointerPressed += (_, _) => Mac.SpringScale(this, 0.97f, 0.7f, 30);
        PointerReleased += (_, _) => Mac.SpringScale(this, 1, 0.45f, 45);
        PointerCaptureLost += (_, _) => Mac.SpringScale(this, 1);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, text);
    }

    public bool Selected
    {
        get => _selected;
        set
        {
            _selected = value;
            _icon.Foreground = value ? Mac.BlueBrush : Mac.Secondary;
            _text.FontWeight = value ? FontWeights.SemiBold : FontWeights.Medium;
            Background = Mac.Clear;
        }
    }

    public string? Badge
    {
        set
        {
            _badge.Visibility = value is null ? Visibility.Collapsed : Visibility.Visible;
            _badge.Child = value is null ? null : Mac.Text(value, 11, FontWeights.SemiBold);
        }
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
