using Cuven.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Cuven.App.UI;

/// <summary>
/// 资料库（照网页版）：「资料库 / Cuven 为你提供严格品质的影片」，下面一部一大块往下排：整幅剧照（中间一行「年份 · 类型 · 时长」+ 字标）、
/// 简介、评分胶囊、导演 / 主演、「播放」+「影片详情」、剧照一排。ItemsRepeater 虚拟化：滚到哪一块才建哪一块、才去取全量的 TMDB
/// </summary>
public sealed partial class LibraryFeedView : View
{
    readonly ItemsRepeater _feed = new();
    readonly TextBlock _count = U.T("", 12, null, Mac.Tertiary);

    public LibraryFeedView()
    {
        Background = Mac.CanvasBrush;
        var col = new StackPanel { Padding = new Thickness(0, 0, 0, 120) };
        var head = U.V(4, U.T("资料库", 30, FontWeights.Bold), U.T("Cuven 为你提供严格品质的影片", 12, null, Mac.Tertiary), _count);
        Inset.Track(head, (h, l) => h.Margin = new Thickness(l, 22, l, 16));
        col.Children.Add(head);
        _feed.Layout = new StackLayout { Orientation = Orientation.Vertical, Spacing = 0 };
        _feed.ItemTemplate = new FeatureFactory();
        col.Children.Add(_feed);
        Children.Add(new ScrollViewer { Content = col, HorizontalScrollMode = ScrollMode.Disabled });
        LibraryStore.Shared.Changed += OnLib;
        Fill();
    }

    void OnLib() => DispatcherQueue.TryEnqueue(() => { if (_feed.ItemsSource is not List<object> l || l.Count != LibraryStore.Shared.Movies.Count) Fill(); });
    public override void Closed() => LibraryStore.Shared.Changed -= OnLib;

    void Fill()
    {
        var movies = LibraryStore.Shared.Movies;
        _count.Text = movies.Count > 0 ? $"{movies.Count} 部电影 · {LibraryStore.Shared.Series.Count} 季剧集" : (LibraryStore.Shared.Error ?? "正在载入…");
        _feed.ItemsSource = movies.Cast<object>().ToList();
    }
}

sealed partial class FeatureFactory : IElementFactory
{
    public UIElement GetElement(ElementFactoryGetArgs args) => args.Data is Movie m ? new FeatureBlock(m) : new Grid();
    public void RecycleElement(ElementFactoryRecycleArgs args) { }
}

/// <summary>资料库里的一部（一大块）</summary>
public sealed partial class FeatureBlock : StackPanel
{
    readonly Movie _m;
    readonly Grid _banner = new() { CornerRadius = new CornerRadius(0) };
    readonly StackPanel _info = new() { Spacing = 12, MaxWidth = 980, HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly StackPanel _stillsRow = new();
    readonly TextBlock _people = U.T("", 12, null, Mac.Tertiary, 2);
    readonly TextBlock _overview;
    bool _loaded;

    public FeatureBlock(Movie m)
    {
        _m = m;
        Spacing = 16;
        Padding = new Thickness(0, 0, 0, 40);
        // 整幅剧照（中间一行信息 + 字标；右上角一颗播放）
        _banner.Children.Add(U.Img(m.BackdropUrl("w1280"), 1600));
        _banner.Children.Add(new Border { Background = U.Fade(0, 1, Colors.Black), Height = 260, VerticalAlignment = VerticalAlignment.Bottom });
        var mid = new StackPanel { Spacing = 10, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(40, 0, 40, 46) };
        var meta = string.Join(" · ", new[] { m.Year, m.Meta.Genres is { Count: > 0 } g ? string.Join(" · ", g.Take(2)) : null, m.Meta.Runtime is > 0 ? $"{m.Meta.Runtime} 分钟" : null }.Where(x => !string.IsNullOrEmpty(x)));
        mid.Children.Add(U.T(meta, 14, FontWeights.SemiBold).With(t => t.HorizontalAlignment = HorizontalAlignment.Center));
        mid.Children.Add(LogoOrTitle(m.Meta.Logo, m.Title));
        _banner.Children.Add(mid);
        var play = MacButton.Round("", () => PlayRequest.Movie(m), "播放", 40, 14);
        play.HorizontalAlignment = HorizontalAlignment.Right;
        play.VerticalAlignment = VerticalAlignment.Top;
        play.Margin = new Thickness(0, 22, 26, 0);
        _banner.Children.Add(play);
        _banner.Tapped += (_, e) => { if (e.OriginalSource is not FrameworkElement fe || !IsIn(fe, play)) Nav.Open(m); };
        SizeChanged += (_, e) => _banner.Height = Math.Clamp(e.NewSize.Width * 0.5, 360, 760);
        Children.Add(_banner);

        // 简介、评分、导演 / 主演、按钮
        _overview = U.T(m.Meta.Overview ?? "", 15, null, Mac.Secondary, 4);
        _info.Children.Add(_overview);
        if (m.Meta.Rating is > 0) _info.Children.Add(Web.Chip($"评分 {m.Meta.Rating:0.0}", 11));
        _info.Children.Add(_people);
        _info.Children.Add(U.H(10, MacButton.Pill("播放", "", () => PlayRequest.Movie(m), MacButton.Style.Primary, 34),
            MacButton.Pill("影片详情", null, () => Nav.Open(m), MacButton.Style.Glass, 34)));
        var infoHost = new Grid();
        infoHost.Children.Add(_info);
        Inset.Track(infoHost, (h, l) => h.Padding = new Thickness(Math.Max(l, 0), 0, l, 0));
        _info.HorizontalAlignment = HorizontalAlignment.Center;
        _info.Width = double.NaN;
        Children.Add(infoHost);
        Children.Add(Inset.Track(U.T("剧照", 12, FontWeights.SemiBold, Mac.Tertiary), (t, l) => t.Margin = new Thickness(l, 8, l, 0)));
        Children.Add(Web.Row(_stillsRow, 16));
        Children.Add(Inset.Track(new Border { Height = 1, Background = Mac.Separator }, (b, l) => b.Margin = new Thickness(l, 10, l, 0)));
        Loaded += async (_, _) => await LoadAsync();
    }

    static bool IsIn(FrameworkElement fe, UIElement target)
    {
        for (DependencyObject? d = fe; d is not null; d = VisualTreeHelper.GetParent(d)) if (d == target) return true;
        return false;
    }

    internal static FrameworkElement LogoOrTitle(string? logo, string title, double maxH = 130, double maxW = 520) =>
        !string.IsNullOrEmpty(logo)
            ? new Image { Source = U.Bitmap(TmdbImage.Url(logo, "w500"), 520), MaxHeight = maxH, MaxWidth = maxW, HorizontalAlignment = HorizontalAlignment.Center, Stretch = Stretch.Uniform }
            : U.T(title, 40, FontWeights.Bold, null, 2).With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; });

    async Task LoadAsync()
    {
        if (_loaded) return;
        _loaded = true;
        var full = await LibraryStore.Shared.FullMetaAsync(_m) ?? _m.Meta;
        var cast = full.Cast?.Take(4).Select(c => c.Name).ToList() ?? new List<string>();
        _people.Text = string.Join("　", new[] { full.Director is { Length: > 0 } d ? "导演 " + d : null, cast.Count > 0 ? "主演 " + string.Join("、", cast) : null }.Where(x => x is not null));
        if (string.IsNullOrEmpty(_overview.Text) && full.Overview is { } ov) _overview.Text = ov;
        foreach (var s in (full.Stills ?? new List<Still>()).Take(10))
        {
            var card = U.RoundImg(TmdbImage.Url(s.Thumb ?? s.Url, "w780"), 640, 14).With(b => { b.Width = 410; b.Height = 230; });
            _stillsRow.Children.Add(card);
        }
        if (_stillsRow.Children.Count == 0 && _m.BackdropUrl("w780") is { } bd)
            _stillsRow.Children.Add(U.RoundImg(bd, 640, 14).With(b => { b.Width = 410; b.Height = 230; }));
    }
}
