using Cuven.App.Native;
using Cuven.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Cuven.App.UI;

/// <summary>请求：我的请求（五步进度）+ 可以请求添加的（索引里、片库还没有的）</summary>
public sealed partial class RequestsView : View
{
    readonly StackPanel _mine = new() { Spacing = 10 };
    readonly ItemsRepeater _catalog = new();
    readonly AutoSuggestBox _search = new() { PlaceholderText = "搜索想看的电影、剧集", Width = 320, QueryIcon = new SymbolIcon(Symbol.Find) };
    readonly ComboBox _src = new() { Width = 110 };
    readonly TextBlock _catStatus = U.T("", 13, null, Mac.Tertiary);

    public RequestsView()
    {
        var col = new StackPanel { Spacing = 10, Padding = new Thickness(0, Inset.Top - 8, 0, 48) };
        Inset.Track(_mine, (e, l) => e.Margin = new Thickness(l, 0, Inset.Right, 0));
        col.Children.Add(Inset.Track(Mac.LargeTitle("请求"), (e, l) => e.Margin = new Thickness(l, 0, Inset.Right, 0)));
        col.Children.Add(Inset.Track(U.T("片库里没有的，按「请求添加」：找片源、下载、整理、上架一条龙，就绪后会通知你。", 14, null, Mac.Secondary, 2), (e, l) => e.Margin = new Thickness(l, 0, Inset.Right, 8)));
        col.Children.Add(Inset.Track(U.T("我的请求", 19, FontWeights.Bold), (e, l) => e.Margin = new Thickness(l, 10, Inset.Right, 0)));
        col.Children.Add(_mine);
        var head = U.H(12, U.T("可以请求添加", 19, FontWeights.Bold).With(t => t.VerticalAlignment = VerticalAlignment.Center), _src, _search);
        Inset.Track(head, (e, l) => e.Margin = new Thickness(l, 24, Inset.Right, 4));
        col.Children.Add(head);
        col.Children.Add(Inset.Track(_catStatus, (e, l) => e.Margin = new Thickness(l, 0, Inset.Right, 0)));
        _catalog.Layout = new UniformGridLayout { MinItemWidth = 150, MinItemHeight = 278, MinRowSpacing = 22, MinColumnSpacing = 18, ItemsStretch = UniformGridLayoutItemsStretch.None, ItemsJustification = UniformGridLayoutItemsJustification.SpaceBetween };
        _catalog.ItemTemplate = new PosterFactory(150);
        Inset.Track(_catalog, (e, l) => e.Margin = new Thickness(l, 8, Inset.Right, 0));
        col.Children.Add(_catalog);
        Children.Add(new ScrollViewer { Content = col, HorizontalScrollMode = ScrollMode.Disabled });
        foreach (var s in new[] { "全部", "电影", "剧集" }) _src.Items.Add(s);
        _src.SelectedIndex = 0;
        _src.SelectionChanged += (_, _) => _ = LoadCatalogAsync();
        _search.QuerySubmitted += (_, _) => _ = LoadCatalogAsync();
        RequestCenter.Shared.Changed += OnChanged;
        Fill();
        _ = RequestCenter.Shared.RefreshAsync();
        _ = LoadCatalogAsync();
    }

    void OnChanged() => DispatcherQueue.TryEnqueue(Fill);
    public override void Closed() => RequestCenter.Shared.Changed -= OnChanged;

    void Fill()
    {
        _mine.Children.Clear();
        var list = RequestCenter.Shared.Mine.Take(20).ToList();
        if (list.Count == 0) { _mine.Children.Add(U.T("还没有请求", 14, null, Mac.Tertiary)); return; }
        foreach (var r in list) _mine.Children.Add(Row(r));
    }

    static UIElement Row(RequestStatus r)
    {
        var g = U.Cols("64", "*", "auto");
        g.ColumnSpacing = 16;
        g.Padding = new Thickness(12);
        g.CornerRadius = new CornerRadius(14);
        g.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(16, 255, 255, 255));
        g.BorderBrush = Mac.Separator;
        g.BorderThickness = new Thickness(0.5);
        g.Children.Add(U.RoundImg(TmdbImage.Url(r.Poster, "w185"), 128, 6).With(b => b.Height = 96).At(0, 0));
        var title = r.Title + (r.Src == "tv" && r.Season > 0 ? $" · 第 {r.Season} 季" : "") + (r.Year.Length > 0 ? $"（{r.Year}）" : "");
        var bar = new ProgressBar { Value = r.State == RequestState.Done ? 100 : r.Pct, Maximum = 100, Margin = new Thickness(0, 6, 0, 0) };
        if (r.State == RequestState.Failed) bar.ShowError = true;
        var text = U.V(4, U.T(title, 16, FontWeights.SemiBold), U.T(r.Headline + (r.State == RequestState.Active ? $" · 第 {r.Step} / {r.Steps} 步" : ""), 13, null, Mac.Secondary), bar,
            r.Note.Length > 0 ? U.T(r.Note, 12, null, Mac.Tertiary, 2) : null);
        text.VerticalAlignment = VerticalAlignment.Center;
        g.Children.Add(text.At(0, 1));
        if (r.State == RequestState.Done && r.Src != "tv" && LibraryStore.Shared.MovieByTmdb(r.Tmdb) is { } m)
            g.Children.Add(MacButton.Pill("播放", "\uE768", () => PlayRequest.Movie(m), MacButton.Style.Primary).With(b => b.VerticalAlignment = VerticalAlignment.Center).At(0, 2));
        g.Tapped += (_, _) => Nav.Open(r.CatalogTitle);
        return g;
    }

    async Task LoadCatalogAsync()
    {
        _catStatus.Text = "正在载入…";
        try
        {
            var src = _src.SelectedIndex switch { 1 => "movie", 2 => "tv", _ => "all" };
            var items = await RequestApi.CatalogAsync(src: src, query: _search.Text.Trim(), own: "no");
            _catalog.ItemsSource = items.Cast<object>().ToList();
            _catStatus.Text = items.Count == 0 ? "没有找到" : "";
        }
        catch (Exception e) { _catStatus.Text = CuvenException.Friendly(e); }
    }
}

/// <summary>下载：整部存到本机（原文件，所有音轨字幕都在），离线也能放</summary>
public sealed partial class DownloadsView : View
{
    readonly StackPanel _list = new() { Spacing = 10 };
    readonly Dictionary<string, (ProgressBar bar, TextBlock status, StackPanel buttons)> _rows = new();
    readonly TextBlock _where = U.T("", 12, null, Mac.Tertiary, 2);

    public DownloadsView()
    {
        var col = new StackPanel { Spacing = 10, Padding = new Thickness(0, Inset.Top - 8, 0, 48) };
        Inset.Track(_list, (e, l) => e.Margin = new Thickness(l, 0, Inset.Right, 0));
        col.Children.Add(Inset.Track(Mac.LargeTitle("下载"), (e, l) => e.Margin = new Thickness(l, 0, Inset.Right, 0)));
        _where.Text = "存在：" + Settings.Shared.DownloadFolder;
        Inset.Track(_where, (e, l) => e.Margin = new Thickness(l, 0, Inset.Right, 8));
        col.Children.Add(_where);
        col.Children.Add(_list);
        Children.Add(new ScrollViewer { Content = col, HorizontalScrollMode = ScrollMode.Disabled });
        DownloadManager.Shared.Updated += OnUpdated;
        DownloadManager.Shared.ListChanged += OnList;
        Fill();
    }

    void OnUpdated(DownloadItem it) => DispatcherQueue.TryEnqueue(() => Update(it));
    void OnList() => DispatcherQueue.TryEnqueue(Fill);

    public override void Closed()
    {
        DownloadManager.Shared.Updated -= OnUpdated;
        DownloadManager.Shared.ListChanged -= OnList;
    }

    void Fill()
    {
        _list.Children.Clear();
        _rows.Clear();
        var items = DownloadManager.Shared.Items;
        if (items.Count == 0) { _list.Children.Add(U.T("还没有下载。在电影的详情页按「下载」，整部存到这台电脑，没有网也能看。", 14, null, Mac.Tertiary, 3)); return; }
        foreach (var it in items) _list.Children.Add(Row(it));
    }

    UIElement Row(DownloadItem it)
    {
        var g = U.Cols("64", "*", "auto");
        g.ColumnSpacing = 16;
        g.Padding = new Thickness(12);
        g.CornerRadius = new CornerRadius(14);
        g.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(16, 255, 255, 255));
        g.BorderBrush = Mac.Separator;
        g.BorderThickness = new Thickness(0.5);
        g.Children.Add(U.RoundImg(it.Poster, 128, 6).With(b => b.Height = 96).At(0, 0));
        var bar = new ProgressBar { Maximum = 1, Margin = new Thickness(0, 6, 0, 0) };
        var status = U.T("", 13, null, Mac.Secondary);
        var text = U.V(4, U.T(it.Title, 16, FontWeights.SemiBold), U.T(it.Name, 12, null, Mac.Tertiary), bar, status);
        text.VerticalAlignment = VerticalAlignment.Center;
        g.Children.Add(text.At(0, 1));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        g.Children.Add(buttons.At(0, 2));
        _rows[it.Path] = (bar, status, buttons);
        Update(it);
        return g;
    }

    void Update(DownloadItem it)
    {
        if (!_rows.TryGetValue(it.Path, out var r)) return;
        r.bar.Value = it.Progress;
        r.bar.ShowPaused = it.Phase == DownloadPhase.Paused;
        r.bar.ShowError = it.Phase is DownloadPhase.Failed or DownloadPhase.NoSpace;
        var size = it.Size > 0 ? $"{Format.Size(it.Received)} / {Format.Size(it.Size)}" : Format.Size(it.Received);
        r.status.Text = it.Phase switch
        {
            DownloadPhase.Done => "已下载 · " + Format.Size(it.Size),
            DownloadPhase.Downloading => $"{it.Progress:P0} · {size} · {Format.Speed(it.Speed)}",
            DownloadPhase.Queued => "排队中 · " + size,
            DownloadPhase.NoSpace => "储存空间不足",
            DownloadPhase.Failed => (it.Error ?? "下载失败") + " · " + size,
            _ => "已暂停 · " + size,
        };
        r.buttons.Children.Clear();
        var path = it.Path;
        if (it.Phase == DownloadPhase.Done)
            r.buttons.Children.Add(MacButton.Pill("播放", "\uE768", () =>
            {
                var m = LibraryStore.Shared.MovieByPath(path);
                MainWindow.Current.Play(new PlayRequest { Path = path, Name = it.Name, Title = it.Title, Start = PlaybackHistory.Shared.ResumeAt(path) });
            }, MacButton.Style.Primary));
        else if (it.Phase is DownloadPhase.Downloading or DownloadPhase.Queued)
            r.buttons.Children.Add(MacButton.Round("\uE769", () => DownloadManager.Shared.Pause(path), "暂停"));
        else
            r.buttons.Children.Add(MacButton.Round("\uE768", () => DownloadManager.Shared.Resume(path), "继续"));
        r.buttons.Children.Add(MacButton.Round("\uE74D", () => DownloadManager.Shared.Delete(path), it.Phase == DownloadPhase.Done ? "删除下载" : "取消下载"));
    }
}

/// <summary>账户与设置：头像、用户名；播放（HDR、硬解、首选音轨、字幕）、Win11 能效；这台电脑的显卡 / 屏幕；退出登录</summary>
public sealed partial class AccountView : View
{
    public AccountView()
    {
        var s = Settings.Shared;
        var col = new StackPanel { Spacing = 12, MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Left };
        Inset.Track(col, (e, l) => e.Padding = new Thickness(l, Inset.Top - 8, Inset.Right, 48));
        col.Children.Add(Mac.LargeTitle("账户"));
        var pic = new PersonPicture { Width = 72, Height = 72, DisplayName = s.Username ?? "" };
        _ = LoadAvatarAsync(pic);
        col.Children.Add(Card(U.H(16, pic, U.V(4, U.T(s.Username ?? "", 20, FontWeights.SemiBold), U.T(string.IsNullOrEmpty(s.Email) ? "Cuven 账户" : s.Email!, 13, null, Mac.Secondary),
            U.T(s.Method == "pair" ? "用 iPhone 扫码登录" : "账户密码登录", 12, null, Mac.Tertiary)).With(v => v.VerticalAlignment = VerticalAlignment.Center))));

        col.Children.Add(U.T("播放", 17, FontWeights.Bold).With(t => t.Margin = new Thickness(0, 10, 0, 0)));
        var hdr = new ComboBox { Width = 220 };
        hdr.Items.Add("自动（屏幕开了 HDR 就用）");
        hdr.Items.Add("一律 SDR（色调映射）");
        hdr.SelectedIndex = s.HdrMode == "sdr" ? 1 : 0;
        hdr.SelectionChanged += (_, _) => { s.HdrMode = hdr.SelectedIndex == 1 ? "sdr" : "auto"; s.Save(); };
        col.Children.Add(Setting("HDR 输出", "HDR10、HLG、杜比视界在 HDR 屏上原样输出；在 SDR 屏上用 BT.2390 映射", hdr));
        var hw = new ToggleSwitch { IsOn = s.HardwareDecode, OnContent = "", OffContent = "", MinWidth = 0 };
        hw.Toggled += (_, _) => { s.HardwareDecode = hw.IsOn; s.Save(); };
        col.Children.Add(Setting("硬件解码", "用显卡解码（D3D11VA）：省电、4K 也流畅。遇到花屏可以关掉试试", hw));
        var audio = new ComboBox { Width = 220 };
        audio.Items.Add("原声（片子默认的）");
        audio.Items.Add("国语 / 粤语优先");
        audio.SelectedIndex = s.AudioPref == "zh" ? 1 : 0;
        audio.SelectionChanged += (_, _) => { s.AudioPref = audio.SelectedIndex == 1 ? "zh" : "natural"; s.Save(); };
        col.Children.Add(Setting("首选音轨", null, audio));
        var subs = new ToggleSwitch { IsOn = s.SubtitlesOn, OnContent = "", OffContent = "", MinWidth = 0 };
        subs.Toggled += (_, _) => { s.SubtitlesOn = subs.IsOn; s.Save(); };
        col.Children.Add(Setting("中文字幕", "优先用片子自带的中文字幕，没有就自动加载在线字幕", subs));

        col.Children.Add(U.T("这台电脑", 17, FontWeights.Bold).With(t => t.Margin = new Thickness(0, 10, 0, 0)));
        var eco = new ToggleSwitch { IsOn = s.Efficiency, OnContent = "", OffContent = "", MinWidth = 0 };
        eco.Toggled += (_, _) => { s.Efficiency = eco.IsOn; s.Save(); };
        col.Children.Add(Setting("能效模式（Win11）", "下载、图片解码放到能效核（EcoQoS）；最小化又没在播时整个程序进效率模式。播放线程始终高优先级（MMCSS）", eco));
        var d = Native.Native.QueryDisplay(MainWindow.Current.Monitor);
        var gpu = Native.Native.Ready ? $"{Native.Native.GpuName}\n{Native.Native.Version}" : Native.Native.InitError ?? "";
        col.Children.Add(Setting("显卡", gpu, null));
        col.Children.Add(Setting("屏幕", d.Hdr != 0 ? $"HDR 已开 · 峰值 {d.MaxNits:0} 尼特 · SDR 内容 {d.SdrWhiteNits:0} 尼特 · {d.Bits} 位" : $"SDR · {d.Bits} 位", null));
        var open = MacButton.Pill("打开下载文件夹", "\uE838", () =>
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo { FileName = Settings.Shared.DownloadFolder, UseShellExecute = true }); } catch { }
        }, MacButton.Style.Glass, 32);
        col.Children.Add(Setting("下载位置", Settings.Shared.DownloadFolder, open));

        var signOut = MacButton.Pill("退出登录", "\uF3B1", async () =>
        {
            var dlg = new ContentDialog
            {
                Title = "退出登录？", Content = "下载的影片会留在这台电脑上。", PrimaryButtonText = "退出登录", CloseButtonText = "取消",
                XamlRoot = XamlRoot, RequestedTheme = ElementTheme.Dark, DefaultButton = ContentDialogButton.Close,
            };
            if (await dlg.ShowAsync() == ContentDialogResult.Primary) MainWindow.Current.SignOut();
        }, MacButton.Style.Glass);
        col.Children.Add(signOut.With(b => b.Margin = new Thickness(0, 16, 0, 0)));
        col.Children.Add(U.T($"Cuven for Windows {typeof(App).Assembly.GetName().Version}", 12, null, Mac.Tertiary).With(t => t.Margin = new Thickness(0, 12, 0, 0)));
        Children.Add(new ScrollViewer { Content = col, HorizontalScrollMode = ScrollMode.Disabled });
    }

    static Border Card(UIElement child) => new()
    {
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(16, 255, 255, 255)), BorderBrush = Mac.Separator, BorderThickness = new Thickness(0.5),
        CornerRadius = new CornerRadius(12), Padding = new Thickness(16, 12, 16, 12), Child = child,
    };

    static Border Setting(string title, string? desc, UIElement? control)
    {
        var g = U.Cols("*", "auto");
        g.ColumnSpacing = 24;
        g.Children.Add(U.V(3, U.T(title, 15, FontWeights.SemiBold), desc is null ? null : U.T(desc, 12, null, Mac.Tertiary, 3)).With(v => v.VerticalAlignment = VerticalAlignment.Center).At(0, 0));
        if (control is FrameworkElement fe) g.Children.Add(fe.With(c => c.VerticalAlignment = VerticalAlignment.Center).At(0, 1));
        return Card(g);
    }

    static async Task LoadAvatarAsync(PersonPicture pic)
    {
        var u = Settings.Shared.Username;
        if (u is null) return;
        var url = await AccountApi.AvatarAsync(u);
        if (url is not null && U.Bitmap(url, 144) is { } b) pic.ProfilePicture = b;
    }
}
