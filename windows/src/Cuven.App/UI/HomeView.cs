using Cuven.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace Cuven.App.UI;

/// <summary>首页：大图轮播（Apple TV 最新发行里库里有的）+ 几排货架（继续观看、最新添加、剧集、按类型、可请求添加）</summary>
public sealed partial class HomeView : View
{
    readonly ScrollViewer _scroll = new() { HorizontalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly StackPanel _col = new() { Spacing = 8, Padding = new Thickness(0, 0, 0, 40) };
    readonly Grid _hero = new() { Height = 620 };
    readonly ContentPresenter _heroContent = new();
    readonly StackPanel _shelves = new() { Spacing = 6 };
    readonly TextBlock _empty = U.T("", 15, null, U.Dim, 3);
    List<(Movie movie, Hero? hero)> _heroes = new();
    int _heroIndex;
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _timer, _debounce;
    List<CatalogItem> _catalog = new();
    bool _catalogAsked;

    public HomeView()
    {
        Background = Mac.CanvasBrush;
        _heroContent.ContentTransitions = new TransitionCollection { new ContentThemeTransition() };
        _hero.Children.Add(_heroContent);
        _col.Children.Add(_hero);
        Inset.Track(_empty, (t, l) => t.Margin = new Thickness(l, Inset.Top, Inset.Right, 0));
        _col.Children.Add(_empty);
        _col.Children.Add(_shelves);
        _scroll.Content = _col;
        Children.Add(_scroll);
        LibraryStore.Shared.Changed += OnLibrary;
        Rebuild();
    }

    void OnLibrary() => DispatcherQueue.TryEnqueue(() =>
    {
        // 片库一批批到：0.4 秒内的合成一次重画
        _debounce ??= DispatcherQueue.CreateTimer().With(t => { t.Interval = TimeSpan.FromMilliseconds(400); t.IsRepeating = false; t.Tick += (_, _) => Rebuild(); });
        _debounce.Stop();
        _debounce.Start();
    });

    public override void Shown()
    {
        _timer ??= DispatcherQueue.CreateTimer().With(t => { t.Interval = TimeSpan.FromSeconds(9); t.Tick += (_, _) => NextHero(); });
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
            foreach (var m in movies.Where(m => !string.IsNullOrEmpty(m.Meta.Backdrop)).Take(8 - heroes.Count)) heroes.Add((m, null));
        bool heroChanged = heroes.Count != _heroes.Count || heroes.Zip(_heroes).Any(p => p.First.Item1 != p.Second.movie);
        _heroes = heroes;
        if (heroChanged) { _heroIndex = 0; ShowHero(); }
        _hero.Visibility = heroes.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        _shelves.Children.Clear();
        var cont = PlaybackHistory.Shared.ContinueWatching();
        if (cont.Count > 0) AddShelf("继续观看", cont.Cast<object>());
        if (movies.Count > 0) AddShelf("最新添加", movies.Take(30).Cast<object>(), () => Shell.Current?.Root("movies"));
        if (lib.Series.Count > 0) AddShelf("剧集", lib.Series.Take(30).Cast<object>(), () => Shell.Current?.Root("series"));
        foreach (var g in lib.Genres().Take(4))
            AddShelf(g, lib.MoviesInGenre(g).Take(30).Cast<object>());
        if (_catalog.Count > 0) AddShelf("可请求添加", _catalog.Cast<object>(), () => Shell.Current?.Root("requests"));
    }

    void AddShelf(string title, IEnumerable<object> items, Action? more = null)
    {
        var head = U.Cols("*", "auto");
        Inset.Track(head, (h, l) => h.Margin = new Thickness(l, 22, Inset.Right, 6));
        head.Children.Add(U.T(title, 19, FontWeights.Bold).At(0, 0));
        if (more is not null)
        {
            var b = MacButton.Pill("全部", "\uE76C", more, MacButton.Style.Plain, 28);
            head.Children.Add(b.At(0, 1));
        }
        var row = new StackPanel { Spacing = 18 };
        foreach (var it in items) row.Children.Add(PosterCard.For(it, 156));
        if (row.Children.Count == 0) return;
        _shelves.Children.Add(head);
        _shelves.Children.Add(U.Shelf(row));
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
        // 大图铺满（连侧边栏下面也是：玻璃把它模糊了，就是 Mac 上那种浮着的边栏）
        var g = new Grid();
        var bg = h?.Background is { } hb ? AppleImage.Sized(hb, 1920, "jpg") : m.BackdropUrl("original");
        g.Children.Add(U.Img(bg, 1920));
        g.Children.Add(new Border { Background = U.Fade(0, 1.0, Mac.Canvas) });
        g.Children.Add(new Border { Background = U.Fade(0.55, 0, Mac.Canvas, true), Width = 900, HorizontalAlignment = HorizontalAlignment.Left });
        var info = new StackPanel { Spacing = 14, VerticalAlignment = VerticalAlignment.Bottom, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
        Inset.Track(info, (i, l) => i.Margin = new Thickness(l + 8, 0, 48, 56));
        var logo = h?.Logo ?? m.Meta.Logo;
        if (!string.IsNullOrEmpty(logo))
            info.Children.Add(new Image { Source = U.Bitmap(logo.Contains("mzstatic") ? AppleImage.Sized(logo, 800, "png") : TmdbImage.Url(logo, "w500"), 500), MaxHeight = 130, MaxWidth = 480, HorizontalAlignment = HorizontalAlignment.Left, Stretch = Stretch.Uniform });
        else
            info.Children.Add(U.T(m.Title, 40, FontWeights.Bold, null, 2));
        var meta = string.Join(" · ", new[] { m.Year, Format.Runtime(m.Meta.Runtime), m.Meta.Genres is { Count: > 0 } gs ? string.Join(" / ", gs.Take(2)) : null }.Where(x => !string.IsNullOrEmpty(x)));
        info.Children.Add(U.T(meta, 14, FontWeights.Medium, Mac.Secondary));
        if (!string.IsNullOrEmpty(m.Meta.Overview)) info.Children.Add(U.T(m.Meta.Overview!, 14, null, Mac.Secondary, 3));
        info.Children.Add(U.H(12,
            MacButton.Pill("播放", "\uE768", () => PlayRequest.Movie(m), MacButton.Style.Primary, 40),
            MacButton.Pill("详情", "\uE946", () => Nav.Open(m), MacButton.Style.Glass, 40)));
        g.Children.Add(info);
        if (_heroes.Count > 1)
        {
            // 翻页点：一枚玻璃胶囊里，当前那一个拉长
            var dots = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(12, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
            for (int i = 0; i < _heroes.Count; i++)
            {
                int k = i;
                var d = new Border { Width = i == _heroIndex ? 20 : 7, Height = 7, CornerRadius = new CornerRadius(3.5), Background = i == _heroIndex ? U.White : U.Faint };
                d.Tapped += (_, _) => { _heroIndex = k; ShowHero(); _timer?.Stop(); _timer?.Start(); };
                dots.Children.Add(d);
            }
            var cap = new Glass(13, GlassKind.Clear) { Height = 26, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 48, 62), Content = dots };
            g.Children.Add(cap);
        }
        _heroContent.Content = g;
    }
}
