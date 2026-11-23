using Cuven.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Cuven.App.UI;

public enum BrowseKind { Movies, Series, Year }

/// <summary>电影 / 剧集的全部：海报网格（ItemsRepeater 虚拟化 + 卡片回收），排序、按类型筛</summary>
public sealed partial class BrowseView : View
{
    readonly BrowseKind _kind;
    readonly string? _year;
    readonly ItemsRepeater _grid = new();
    readonly ComboBox _sort = new() { Width = 140 };
    readonly ComboBox _genre = new() { Width = 140 };
    readonly TextBlock _count = U.T("", 13, null, U.Faint);
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _debounce;

    public BrowseView(BrowseKind kind, string? year = null)
    {
        _year = year;
        Background = Mac.FrostCanvas;
        _kind = kind;
        var header = U.Cols("auto", "*", "auto", "auto");
        header.ColumnSpacing = 12;
        Inset.Track(header, (h, l) => h.Margin = new Thickness(l, Inset.Top, Inset.Right, 14));
        header.Children.Add(U.V(2, Mac.LargeTitle(kind == BrowseKind.Year ? $"{year} 年" : kind == BrowseKind.Movies ? "电影" : "剧集"), _count).At(0, 0));
        foreach (var s in new[] { "最新添加", "评分最高", "年份", "片名" }) _sort.Items.Add(s);
        _sort.SelectedIndex = 0;
        _sort.SelectionChanged += (_, _) => Fill();
        header.Children.Add(_sort.With(c => c.VerticalAlignment = VerticalAlignment.Center).At(0, 2));
        if (kind == BrowseKind.Movies)
        {
            _genre.Items.Add("全部类型");
            foreach (var g in LibraryStore.Shared.Genres()) _genre.Items.Add(g);
            _genre.SelectedIndex = 0;
            _genre.SelectionChanged += (_, _) => Fill();
            header.Children.Add(_genre.With(c => c.VerticalAlignment = VerticalAlignment.Center).At(0, 3));
        }
        _grid.Layout = new UniformGridLayout
        {
            // 卡片尺寸固定（160 × 240 的海报 + 两行字），多出来的宽度分到间距里（Mac 的 TV App 那样）
            MinItemWidth = 160,
            MinItemHeight = 292,
            MinRowSpacing = 24,
            MinColumnSpacing = 20,
            ItemsStretch = UniformGridLayoutItemsStretch.None,
            ItemsJustification = UniformGridLayoutItemsJustification.SpaceBetween,
        };
        _grid.ItemTemplate = new PosterFactory(160);
        var scroll = new ScrollViewer { Content = Inset.Track(_grid, (g, l) => g.Margin = new Thickness(l, 0, Inset.Right, 40)), HorizontalScrollMode = ScrollMode.Disabled };
        var root = U.Rows("auto", "*");
        root.Children.Add(header.At(0));
        root.Children.Add(scroll.At(1));
        Children.Add(root);
        LibraryStore.Shared.Changed += OnLib;
        Fill();
    }

    void OnLib() => DispatcherQueue.TryEnqueue(() =>
    {
        _debounce ??= DispatcherQueue.CreateTimer().With(t => { t.Interval = TimeSpan.FromMilliseconds(500); t.IsRepeating = false; t.Tick += (_, _) => Fill(); });
        _debounce.Stop();
        _debounce.Start();
    });

    public override void Closed() => LibraryStore.Shared.Changed -= OnLib;

    void Fill()
    {
        var lib = LibraryStore.Shared;
        List<object> items;
        if (_kind == BrowseKind.Year)
        {
            // 这一年的剧集和电影（「查看电影和剧集 ›」）
            items = lib.Series.Where(s => s.Year == _year).Cast<object>().Concat(lib.Movies.Where(m => m.Year == _year).Cast<object>()).ToList();
        }
        else if (_kind == BrowseKind.Movies)
        {
            IEnumerable<Movie> mv = lib.Movies;
            if (_genre.SelectedIndex > 0 && _genre.SelectedItem is string g) mv = mv.Where(m => m.Meta.Genres?.Contains(g) == true);
            mv = _sort.SelectedIndex switch
            {
                1 => mv.OrderByDescending(m => m.Meta.Rating ?? 0),
                2 => mv.OrderByDescending(m => m.Year ?? ""),
                3 => mv.OrderBy(m => m.Title, StringComparer.CurrentCulture),
                _ => mv,
            };
            items = mv.Cast<object>().ToList();
        }
        else
        {
            IEnumerable<Series> se = lib.Series;
            se = _sort.SelectedIndex switch
            {
                1 => se.OrderByDescending(s => lib.SeriesMeta(s)?.Rating ?? 0),
                2 => se.OrderByDescending(s => s.Year ?? ""),
                3 => se.OrderBy(s => lib.SeriesMeta(s)?.Title ?? s.Name, StringComparer.CurrentCulture),
                _ => se,
            };
            items = se.Cast<object>().ToList();
        }
        _count.Text = items.Count == 0 ? (lib.Error ?? "正在载入…") : $"{items.Count} 部";
        _grid.ItemsSource = items;
    }
}

/// <summary>
/// 搜索（照网页版）：底下的导航变成搜索框（Dock），这一页只放结果。没输字时是「最近搜索」胶囊和「最近添加」；
/// 输了字：「“片名” · N 个结果」，剧集（竖大卡）在上、电影（海报网格）在下，再下面是片库里没有、可以请求添加的
/// </summary>
public sealed partial class SearchView : View
{
    public string Query { get; private set; } = "";
    readonly StackPanel _body = new() { Padding = new Thickness(0, 0, 0, 150) };
    int _gen;
    bool _hadHits;

    public SearchView(string q = "")
    {
        Background = Mac.CanvasBrush;
        Children.Add(new ScrollViewer { Content = _body, HorizontalScrollMode = ScrollMode.Disabled });
        Run(q);
    }

    public override void Closed() => Commit();

    /// <summary>离开搜索时：这次搜到过东西就记进「最近搜索」</summary>
    public void Commit()
    {
        if (Query.Length > 0 && _hadHits) SearchHistory.Add(Query);
    }

    public void Run(string q)
    {
        q = q.Trim();
        if (q == Query && _body.Children.Count > 0) return;
        Query = q;
        int gen = ++_gen;
        _body.Children.Clear();
        _hadHits = false;
        if (q.Length == 0) { Initial(); return; }
        var (mv, se) = LibraryStore.Shared.Search(q);
        _hadHits = mv.Count + se.Count > 0;
        if (!_hadHits)
        {
            var empty = U.V(8, U.T($"未找到「{q}」相关结果", 22, FontWeights.Bold), U.T("试试不同的关键词，或检查拼写", 14, null, Mac.Secondary));
            empty.HorizontalAlignment = HorizontalAlignment.Center;
            foreach (var t in empty.Children.OfType<TextBlock>()) t.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Margin = new Thickness(40, 160, 40, 0);
            _body.Children.Add(empty);
        }
        else
        {
            var count = new TextBlock { FontSize = 15, Foreground = Mac.Secondary };
            count.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $"“{q}”", FontWeight = FontWeights.Bold, Foreground = Mac.Label });
            count.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = $" · {mv.Count + se.Count} 个结果" });
            _body.Children.Add(Inset.Track(count, (t, l) => t.Margin = new Thickness(l, Inset.Top, l, 6)));
            if (se.Count > 0)
            {
                Sub($"剧集 · {se.Count}");
                var row = new StackPanel();
                foreach (var s in se) row.Children.Add(Web.SeriesTall(s, 260, 360));
                _body.Children.Add(Web.Row(row, 16));
            }
            if (mv.Count > 0)
            {
                if (se.Count > 0) Sub($"电影 · {mv.Count}");
                _body.Children.Add(Grid(mv.Cast<object>()));
            }
        }
        _ = CatalogAsync(q, gen);
    }

    void Initial()
    {
        var hist = SearchHistory.Items;
        if (hist.Count > 0)
        {
            Sub("最近搜索", Inset.Top);
            var wrap = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            foreach (var h in hist)
            {
                var hh = h;
                var chip = new Glass(18, GlassKind.Regular) { Height = 36 };
                var x = MacButton.Round("\uE711", () => { SearchHistory.Remove(hh); _body.Children.Clear(); Initial(); }, $"删除「{hh}」", 24, 9, MacButton.Style.Plain);
                var inner = U.H(8, U.Icon("\uE81C", 13).With(i => { i.Foreground = Mac.Secondary; i.VerticalAlignment = VerticalAlignment.Center; }),
                    U.T(hh, 14, FontWeights.SemiBold).With(t => t.VerticalAlignment = VerticalAlignment.Center), x);
                inner.Margin = new Thickness(14, 0, 6, 0);
                inner.VerticalAlignment = VerticalAlignment.Center;
                chip.Content = inner;
                chip.Tapped += (_, e) => { if (e.OriginalSource is DependencyObject d && IsInside(d, x)) return; Shell.Current?.SearchFor(hh); };
                Mac.Pressable(chip, 1.04f, 0.96f);
                wrap.Children.Add(chip);
            }
            var clear = MacButton.Pill("清除全部", "\uE74D", () => { SearchHistory.Clear(); _body.Children.Clear(); Initial(); }, MacButton.Style.Glass, 36);
            wrap.Children.Add(clear);
            _body.Children.Add(Web.Row(wrap, 10));
        }
        var recent = LibraryStore.Shared.Movies.Take(12).Cast<object>().ToList();
        if (recent.Count > 0)
        {
            Sub("最近添加", hist.Count > 0 ? 18 : Inset.Top);
            _body.Children.Add(Grid(recent));
        }
        else
        {
            var empty = U.V(8, U.T("搜索电影、剧集", 22, FontWeights.Bold), U.T("输入片名开始，结果会即时出现", 14, null, Mac.Secondary));
            empty.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Margin = new Thickness(40, 160, 40, 0);
            _body.Children.Add(empty);
        }
    }

    static bool IsInside(DependencyObject d, UIElement target)
    {
        for (DependencyObject? p = d; p is not null; p = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(p)) if (p == target) return true;
        return false;
    }

    void Sub(string text, double top = 22) =>
        _body.Children.Add(Inset.Track(U.T(text, 15, FontWeights.Bold, Mac.Secondary), (t, l) => t.Margin = new Thickness(l, top, l, 12)));

    static FrameworkElement Grid(IEnumerable<object> items)
    {
        var g = new ItemsRepeater
        {
            Layout = new UniformGridLayout
            {
                MinItemWidth = 160, MinItemHeight = 292, MinRowSpacing = 24, MinColumnSpacing = 20,
                ItemsStretch = UniformGridLayoutItemsStretch.None, ItemsJustification = UniformGridLayoutItemsJustification.Start,
            },
            ItemTemplate = new PosterFactory(160),
            ItemsSource = items.ToList(),
        };
        return Inset.Track(g, (e, l) => e.Margin = new Thickness(l, 0, l, 0));
    }

    async Task CatalogAsync(string q, int gen)
    {
        try
        {
            var items = await RequestApi.CatalogAsync(query: q);
            if (gen != _gen) return;
            var lib = LibraryStore.Shared;
            var missing = items.Where(i => i.Src == "tv" ? lib.SeriesByTmdb(i.Id) is null : lib.MovieByTmdb(i.Id) is null).ToList();
            if (missing.Count == 0) return;
            Sub("可以请求添加", 30);
            var row = new StackPanel();
            foreach (var it in missing) row.Children.Add(PosterCard.For(it, 160));
            _body.Children.Add(Web.Row(row, 18));
        }
        catch { }
    }
}

/// <summary>最近搜索（本机，最多 8 条，新的在前）</summary>
static class SearchHistory
{
    const string File = "search-history.json";
    static List<string>? _items;

    public static IReadOnlyList<string> Items => _items ??= Load();

    static List<string> Load()
    {
        try
        {
            if (Storage.ReadJson(File) is System.Text.Json.Nodes.JsonArray a)
                return a.Select(n => (string?)n).Where(s => !string.IsNullOrWhiteSpace(s)).Select(s => s!).Take(8).ToList();
        }
        catch { }
        return new List<string>();
    }

    static void Save()
    {
        var a = new System.Text.Json.Nodes.JsonArray();
        foreach (var s in Items) a.Add(s);
        try { Storage.WriteJson(File, a); } catch { }
    }

    public static void Add(string q)
    {
        var l = (List<string>)Items;
        l.RemoveAll(x => string.Equals(x, q, StringComparison.OrdinalIgnoreCase));
        l.Insert(0, q);
        if (l.Count > 8) l.RemoveRange(8, l.Count - 8);
        Save();
    }

    public static void Remove(string q) { ((List<string>)Items).Remove(q); Save(); }
    public static void Clear() { ((List<string>)Items).Clear(); Save(); }
}
