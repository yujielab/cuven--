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

/// <summary>搜索：片库里的电影、剧集 + 索引里能请求添加的</summary>
public sealed partial class SearchView : View
{
    readonly string _q;
    readonly StackPanel _col = new() { Spacing = 8, Padding = new Thickness(0, 20, 0, 40) };

    public SearchView(string q)
    {
        Background = Mac.FrostCanvas;
        _q = q;
        _col.Children.Add(Inset.Track(Mac.LargeTitle($"“{q}”"), (t, l) => t.Margin = new Thickness(l, Inset.Top - 20, Inset.Right, 8)));
        Children.Add(new ScrollViewer { Content = _col, HorizontalScrollMode = ScrollMode.Disabled });
        var (mv, se) = LibraryStore.Shared.Search(q);
        if (mv.Count > 0) Section("电影", mv.Cast<object>());
        if (se.Count > 0) Section("剧集", se.Cast<object>());
        if (mv.Count == 0 && se.Count == 0)
            _col.Children.Add(Inset.Track(U.T("片库里没有找到", 15, null, Mac.Secondary), (t, l) => t.Margin = new Thickness(l, 0, Inset.Right, 0)));
        _ = CatalogAsync();
    }

    void Section(string title, IEnumerable<object> items)
    {
        _col.Children.Add(Inset.Track(U.T(title, 19, FontWeights.Bold), (t, l) => t.Margin = new Thickness(l, 16, Inset.Right, 6)));
        var row = new StackPanel { Spacing = 18 };
        foreach (var it in items) row.Children.Add(PosterCard.For(it, 150));
        _col.Children.Add(U.Shelf(row));
    }

    async Task CatalogAsync()
    {
        try
        {
            var items = await RequestApi.CatalogAsync(query: _q);
            var lib = LibraryStore.Shared;
            var missing = items.Where(i => i.Src == "tv" ? lib.SeriesByTmdb(i.Id) is null : lib.MovieByTmdb(i.Id) is null).ToList();
            if (missing.Count > 0) Section("可以请求添加", missing.Cast<object>());
        }
        catch { }
    }
}
