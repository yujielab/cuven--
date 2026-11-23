using Cuven.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace Cuven.App.UI;

/// <summary>
/// 主页（照网页版）：整屏大图（中间：年份胶囊、字标、「Cuven TV 严选影片」、白色「播放」+ 磨砂圆钮；下面：暂停钮 + 翻页点），
/// 然后：今日推荐（排名大数字）、最新加入（16:9）、剧集（竖的大卡）、继续观看、按年份的几段（年份栏 + 海报）、可请求添加
/// </summary>
public sealed partial class HomeView : View
{
    readonly ScrollViewer _scroll = new() { HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly StackPanel _col = new() { Spacing = 6, Padding = new Thickness(0, 0, 0, 120) };
    readonly Grid _hero = new();
    readonly ContentPresenter _heroContent = new();
    readonly StackPanel _sections = new() { Spacing = 4 };
    readonly TextBlock _empty = U.T("", 15, null, Mac.Secondary, 3);
    List<(Movie movie, Hero? hero)> _heroes = new();
    int _heroIndex;
    bool _autoplay = true;
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _timer, _debounce;
    List<CatalogItem> _catalog = new();
    bool _catalogAsked;

    public HomeView()
    {
        Background = Mac.CanvasBrush;
        _heroContent.ContentTransitions = new TransitionCollection { new ContentThemeTransition() };
        _hero.Children.Add(_heroContent);
        SizeChanged += (_, e) => _hero.Height = Math.Max(560, e.NewSize.Height * 0.92);
        _col.Children.Add(_hero);
        Inset.Track(_empty, (t, l) => t.Margin = new Thickness(l, Inset.Top, l, 0));
        _col.Children.Add(_empty);
        _col.Children.Add(_sections);
        _scroll.Content = _col;
        Children.Add(_scroll);
        LibraryStore.Shared.Changed += OnLibrary;
        Rebuild();
    }

    void OnLibrary() => DispatcherQueue.TryEnqueue(() =>
    {
        _debounce ??= DispatcherQueue.CreateTimer().With(t => { t.Interval = TimeSpan.FromMilliseconds(500); t.IsRepeating = false; t.Tick += (_, _) => Rebuild(); });
        _debounce.Stop();
        _debounce.Start();
    });

    public override void Shown()
    {
        _timer ??= DispatcherQueue.CreateTimer().With(t => { t.Interval = TimeSpan.FromSeconds(9); t.Tick += (_, _) => { if (_autoplay) NextHero(); }; });
        _timer.Start();
        if (!_catalogAsked) { _catalogAsked = true; _ = LoadCatalogAsync(); }
    }

    public override void Refresh() => Rebuild();

    public override void Closed()
    {
        _timer?.Stop();
        LibraryStore.Shared.Changed -= OnLibrary;
    }

    async Task LoadCatalogAsync()
    {
        try
        {
            _catalog = (await RequestApi.CatalogAsync(own: "no")).Take(30).ToList();
            Rebuild();
        }
        catch { }
    }

    void Rebuild()
    {
        var lib = LibraryStore.Shared;
        var movies = lib.Movies;
        _empty.Text = movies.Count == 0 ? (lib.Error ?? "正在载入片库…") : "";
        _empty.Visibility = movies.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        // 大图：Apple TV 的头图优先（片库里有的），没有就用最新入库、有剧照的
        var heroes = new List<(Movie, Hero?)>();
        foreach (var h in lib.Heroes)
            if (lib.MovieByPath(h.Path) is { } m && !string.IsNullOrEmpty(h.Background)) heroes.Add((m, h));
        if (heroes.Count < 3)
            foreach (var m in movies.Where(m => !string.IsNullOrEmpty(m.Meta.Backdrop)).Take(6 - heroes.Count)) heroes.Add((m, null));
        bool heroChanged = heroes.Count != _heroes.Count || heroes.Zip(_heroes).Any(p => p.First.Item1 != p.Second.movie);
        _heroes = heroes;
        if (heroChanged) { _heroIndex = 0; ShowHero(); }
        _hero.Visibility = heroes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        _sections.Children.Clear();
        // 今日推荐：评分 7 以上的，按今天的日期洗一下牌，取 10 部（每天换一批）
        var rng = new Random(DateTime.Now.DayOfYear + DateTime.Now.Year * 1000);
        var picks = movies.Where(m => m.Meta.Rating >= 7).Take(120).OrderBy(_ => rng.Next()).Take(10).ToList();
        if (picks.Count < 10) picks.AddRange(movies.Except(picks).Take(10 - picks.Count));
        if (picks.Count > 0)
        {
            Section("今日推荐");
            var row = new StackPanel();
            for (int i = 0; i < picks.Count; i++)
            {
                var m = picks[i];
                var cell = new Grid { Width = 300, Height = 290 };
                var num = Web.OutlineNumber((i + 1).ToString(), 210);
                num.HorizontalAlignment = HorizontalAlignment.Left;
                num.VerticalAlignment = VerticalAlignment.Bottom;
                num.Margin = new Thickness(-6, 0, 0, -22);
                cell.Children.Add(num);
                var poster = U.RoundImg(m.PosterUrl("w342"), 280, 10).With(p => { p.Width = 186; p.Height = 279; p.HorizontalAlignment = HorizontalAlignment.Right; p.VerticalAlignment = VerticalAlignment.Top; });
                Mac.Pressable(poster, 1.04f, 0.97f);
                poster.Tapped += (_, _) => Nav.Open(m);
                cell.Children.Add(poster);
                row.Children.Add(cell);
            }
            _sections.Children.Add(Web.Row(row, 6));
        }
        // 最新加入：16:9，下面一行「N 天前」
        if (movies.Count > 0)
        {
            Section("最新加入");
            var row = new StackPanel();
            foreach (var m in movies.Take(20))
                row.Children.Add(Web.Landscape(m, m.BackdropUrl("w780") ?? m.PosterUrl("w342"), m.Title, Format.Relative(m.Video.AddedKey)));
            _sections.Children.Add(Web.Row(row, 16));
        }
        // 剧集：竖的大卡（剧照裁成竖的，左下角字标 / 名字 +「查看剧集 ›」）
        if (lib.Series.Count > 0)
        {
            Section("剧集");
            var row = new StackPanel();
            foreach (var s in lib.Series.Take(14))
            {
                row.Children.Add(Web.SeriesTall(s));
            }
            _sections.Children.Add(Web.Row(row, 18));
        }
        var cont = PlaybackHistory.Shared.ContinueWatching();
        if (cont.Count > 0)
        {
            Section("继续观看");
            var row = new StackPanel();
            foreach (var e in cont) row.Children.Add(PosterCard.For(e, 170));
            _sections.Children.Add(Web.Row(row, 18));
        }
        // 按年份：年份栏（「查看电影和剧集 ›」）+ 那一年的海报
        var years = movies.Select(m => m.Year).Concat(lib.Series.Select(s => s.Year)).Where(y => !string.IsNullOrEmpty(y))
            .Distinct().OrderByDescending(y => y).Take(6).ToList();
        foreach (var y in years)
        {
            var yy = y!;
            var items = lib.Series.Where(s => s.Year == yy).Cast<object>().Take(8)
                .Concat(movies.Where(m => m.Year == yy).Cast<object>().Take(24)).ToList();
            if (items.Count == 0) continue;
            _sections.Children.Add(Web.YearBar(yy, () => Shell.Current?.Go(new BrowseView(BrowseKind.Year, yy))));
            var row = new StackPanel();
            foreach (var it in items) row.Children.Add(PosterCard.For(it, 170));
            _sections.Children.Add(Web.Row(row, 18));
        }
        if (_catalog.Count > 0)
        {
            Section("可请求添加");
            var row = new StackPanel();
            foreach (var c in _catalog) row.Children.Add(PosterCard.For(c, 170));
            _sections.Children.Add(Web.Row(row, 18));
        }
    }

    void Section(string title)
    {
        var pill = Web.SectionPill(title);
        Inset.Track(pill, (p, l) => p.Margin = new Thickness(l, 34, l, 8));
        _sections.Children.Add(pill);
    }

    void NextHero()
    {
        if (_heroes.Count < 2) return;
        _heroIndex = (_heroIndex + 1) % _heroes.Count;
        ShowHero();
    }

    void ShowHero()
    {
        if (_heroes.Count == 0) { _heroContent.Content = null; return; }
        var (m, h) = _heroes[_heroIndex % _heroes.Count];
        var g = new Grid();
        var bg = h?.Background is { } hb ? AppleImage.Sized(hb, 1920, "jpg") : m.BackdropUrl("original");
        g.Children.Add(U.Img(bg, 1920));
        g.Children.Add(new Border { Background = U.Fade(0, 1.0, Colors.Black), Height = 420, VerticalAlignment = VerticalAlignment.Bottom });

        // 中间偏下：年份胶囊、字标、「Cuven TV 严选影片」、播放
        var info = new StackPanel { Spacing = 16, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(40, 0, 40, 170), MaxWidth = 720 };
        var kind = m.Meta.Type == "tv" ? "剧集" : "电影";
        info.Children.Add(Web.Chip(string.Join(" · ", new[] { m.Year, kind }.Where(x => !string.IsNullOrEmpty(x)))).With(c => c.HorizontalAlignment = HorizontalAlignment.Center));
        var logo = h?.Logo ?? m.Meta.Logo;
        if (!string.IsNullOrEmpty(logo))
            info.Children.Add(new Image { Source = U.Bitmap(logo.Contains("mzstatic") ? AppleImage.Sized(logo, 800, "png") : TmdbImage.Url(logo, "w500"), 500), MaxHeight = 120, MaxWidth = 480, HorizontalAlignment = HorizontalAlignment.Center, Stretch = Stretch.Uniform });
        else
            info.Children.Add(U.T(m.Title, 42, FontWeights.Bold, null, 2).With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; }));
        info.Children.Add(U.H(7, U.Icon("", 14), U.T("Cuven TV 严选影片", 14, FontWeights.SemiBold)).With(s => s.HorizontalAlignment = HorizontalAlignment.Center));
        var buttons = U.H(16, MacButton.Pill("播放", "", () => PlayRequest.Movie(m), MacButton.Style.Primary, 50).With(b => b.MinWidth = 136),
            MacButton.Round("", () => Nav.Open(m), "详情", 50, 18));
        buttons.HorizontalAlignment = HorizontalAlignment.Center;
        info.Children.Add(buttons);
        g.Children.Add(info);

        // 底下：暂停 / 继续轮播 + 翻页点（一枚磨砂胶囊，当前那一点拉长、里面一条白的走着）
        if (_heroes.Count > 1)
        {
            var dots = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(20, 0, 20, 0), VerticalAlignment = VerticalAlignment.Center };
            for (int i = 0; i < _heroes.Count; i++)
            {
                int k = i;
                FrameworkElement d;
                if (i == _heroIndex)
                {
                    var track = new Grid { Width = 48, Height = 8, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(90, 255, 255, 255)) };
                    var fill = new Border { Background = U.White, CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Stretch };
                    track.Children.Add(fill);
                    track.Loaded += (_, _) =>
                    {
                        var v = Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.GetElementVisual(fill);
                        v.CenterPoint = new System.Numerics.Vector3(0, 4, 0);
                        var a = v.Compositor.CreateVector3KeyFrameAnimation();
                        a.InsertKeyFrame(0, new System.Numerics.Vector3(0, 1, 1));
                        a.InsertKeyFrame(1, new System.Numerics.Vector3(1, 1, 1), v.Compositor.CreateLinearEasingFunction());
                        a.Duration = _autoplay ? TimeSpan.FromSeconds(9) : TimeSpan.FromMilliseconds(1);
                        v.StartAnimation("Scale", a);
                    };
                    d = track;
                }
                else d = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(150, 255, 255, 255)) };
                d.Tapped += (_, _) => { _heroIndex = k; ShowHero(); _timer?.Stop(); _timer?.Start(); };
                dots.Children.Add(d);
            }
            var pause = MacButton.Round(_autoplay ? "" : "", () => { _autoplay = !_autoplay; ShowHero(); }, _autoplay ? "暂停轮播" : "继续轮播", 56, 18);
            var cap = new Glass(28, GlassKind.Regular) { Height = 56, Content = dots };
            var ctl = U.H(14, pause, cap);
            ctl.HorizontalAlignment = HorizontalAlignment.Center;
            ctl.VerticalAlignment = VerticalAlignment.Bottom;
            ctl.Margin = new Thickness(0, 0, 0, 80);
            g.Children.Add(ctl);
        }
        _heroContent.Content = g;
    }
}
