using Cuven.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

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

/// <summary>主界面：左边 NavigationView（首页 / 电影 / 剧集 / 请求 / 下载 / 账户），右边是页，自己管返回栈</summary>
public sealed partial class Shell : Grid, IDisposable
{
    public static Shell? Current { get; private set; }
    readonly NavigationView _nav = new();
    readonly ContentPresenter _host = new();
    readonly Stack<View> _stack = new();
    readonly Dictionary<string, NavigationViewItem> _items = new();
    readonly InfoBadge _reqBadge = new() { Visibility = Visibility.Collapsed };
    readonly DispatcherQueueTimerWrapper _libTimer;

    public Shell()
    {
        Current = this;
        _nav.PaneDisplayMode = NavigationViewPaneDisplayMode.Left;
        _nav.IsSettingsVisible = false;
        _nav.IsBackButtonVisible = NavigationViewBackButtonVisible.Visible;
        _nav.IsPaneToggleButtonVisible = true;
        _nav.OpenPaneLength = 220;
        _nav.CompactModeThresholdWidth = 900;
        _nav.ExpandedModeThresholdWidth = 1200;
        _nav.Margin = new Thickness(0, 44, 0, 0);
        _nav.IsTitleBarAutoPaddingEnabled = false;
        Item("home", "首页", "");
        Item("movies", "电影", "");
        Item("series", "剧集", "");
        Item("requests", "请求", "").InfoBadge = _reqBadge;
        Item("downloads", "下载", "");
        var acct = new NavigationViewItem { Content = "账户", Icon = U.Icon(""), Tag = "account" };
        _items["account"] = acct;
        _nav.FooterMenuItems.Add(acct);
        var search = new AutoSuggestBox { PlaceholderText = "搜索电影、剧集", QueryIcon = new SymbolIcon(Symbol.Find), Width = 200 };
        search.QuerySubmitted += (_, e) => { if (!string.IsNullOrWhiteSpace(e.QueryText)) Go(new SearchView(e.QueryText.Trim())); };
        search.TextChanged += (s, e) =>
        {
            if (e.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
            var (mv, se) = LibraryStore.Shared.Search(s.Text);
            s.ItemsSource = mv.Select(m => m.Title).Concat(se.Select(x => x.Name)).Distinct().Take(8).ToList();
        };
        search.SuggestionChosen += (s, e) => s.Text = e.SelectedItem as string ?? s.Text;
        _nav.AutoSuggestBox = search;
        _host.ContentTransitions = new TransitionCollection { new EntranceThemeTransition { FromVerticalOffset = 24 } };
        _nav.Content = _host;
        _nav.SelectionChanged += (_, e) =>
        {
            if (e.SelectedItem is NavigationViewItem it && it.Tag is string tag && !_switching) Root(tag);
        };
        _nav.BackRequested += (_, _) => Back();
        Children.Add(_nav);

        // 键盘 / 鼠标的「后退」
        KeyboardAccelerators.Add(new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.Back, Modifiers = Windows.System.VirtualKeyModifiers.Menu }
            .With(k => k.Invoked += (_, a) => { a.Handled = Back(); }));
        PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(this).Properties.IsXButton1Pressed) e.Handled = Back();
        };

        Select("home");
        Root("home");
        var user = Settings.Shared.Username;
        if (user is not null) RequestCenter.Shared.Start(user);
        RequestCenter.Shared.Changed += () => DispatcherQueue.TryEnqueue(UpdateBadge);
        RequestCenter.Shared.Milestone += (r, s) => Notifications.Show(r.Title, s);
        DownloadManager.Shared.ResumeAll();
        _ = LibraryStore.Shared.RefreshAsync();
        // 每 20 分钟刷新一次片库（新入库的片子）；后台不刷
        _libTimer = new DispatcherQueueTimerWrapper(DispatcherQueue, TimeSpan.FromMinutes(20), () => _ = LibraryStore.Shared.RefreshAsync());
    }

    NavigationViewItem Item(string tag, string text, string glyph)
    {
        var it = new NavigationViewItem { Content = text, Icon = U.Icon(glyph), Tag = tag };
        _items[tag] = it;
        _nav.MenuItems.Add(it);
        return it;
    }

    bool _switching;
    void Select(string tag)
    {
        if (!_items.TryGetValue(tag, out var it)) return;
        _switching = true;
        _nav.SelectedItem = it;
        _switching = false;
    }

    void UpdateBadge()
    {
        var n = RequestCenter.Shared.ActiveCount;
        _reqBadge.Value = n;
        _reqBadge.Visibility = n > 0 ? Visibility.Visible : Visibility.Collapsed;
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
        Select(tag);
        Show(Make(tag));
    }

    public void Go(View v) => Show(v);

    void Show(View v)
    {
        _stack.Push(v);
        _host.Content = v;
        _nav.IsBackEnabled = _stack.Count > 1;
        v.Shown();
    }

    public bool Back()
    {
        if (_stack.Count <= 1) return false;
        _stack.Pop().Closed();
        var v = _stack.Peek();
        _host.Content = v;
        _nav.IsBackEnabled = _stack.Count > 1;
        v.Shown();
        return true;
    }

    public void Refresh() { if (_stack.Count > 0) _stack.Peek().Refresh(); }

    public void Dispose()
    {
        _libTimer.Stop();
        while (_stack.Count > 0) _stack.Pop().Closed();
        if (Current == this) Current = null;
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
