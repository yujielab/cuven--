using Cuven.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Cuven.App.UI;

/// <summary>打开一项（电影 / 剧集 / 片库里没有的 / 继续观看）</summary>
static class Nav
{
    public static void Open(object? item)
    {
        var shell = Shell.Current;
        if (shell is null || item is null) return;
        switch (item)
        {
            case Movie m: shell.Go(DetailView.ForMovie(m)); break;
            case Series s: shell.Go(DetailView.ForSeries(s)); break;
            case CatalogItem c: Open(c.CatalogTitle); break;
            case CatalogTitle t:
                // 片库里其实有：直接开片库的详情
                if (t.Kind == CatalogKind.Movie && LibraryStore.Shared.MovieByTmdb(t.Id) is { } mv) shell.Go(DetailView.ForMovie(mv));
                else if (t.Kind == CatalogKind.Tv && LibraryStore.Shared.SeriesByTmdb(t.Id) is { } se) shell.Go(DetailView.ForSeries(se));
                else shell.Go(DetailView.ForCatalog(t));
                break;
            case PlaybackHistory.Entry e: PlayRequest.Resume(e); break;
        }
    }
}

/// <summary>海报卡：2:3 的圆角海报 + 片名 + 一行小字。可以换绑数据（虚拟化列表回收复用）</summary>
public sealed partial class PosterCard : Grid
{
    readonly Border _art = new() { CornerRadius = new CornerRadius(10), Background = U.CardBrush };
    readonly TextBlock _title = U.T("", 14, FontWeights.SemiBold);
    readonly TextBlock _sub = U.T("", 12, null, U.Faint);
    readonly Border _badge = new() { CornerRadius = new CornerRadius(6), Padding = new Thickness(7, 2, 7, 2), Margin = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed };
    readonly ProgressBar _progress = new() { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(10, 0, 10, 10), Visibility = Visibility.Collapsed, Maximum = 1 };
    string? _url;
    public object? Item { get; private set; }

    public PosterCard(double width = 160)
    {
        Width = width;
        RowSpacing = 6;
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(width * 1.5) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var art = new Grid().Add(_art, _badge, _progress);
        Children.Add(art.At(0));
        Children.Add(_title.At(1));
        Children.Add(_sub.At(2));
        U.HoverGrow(art);
        Background = U.Transparent;
        Tapped += (_, _) => Nav.Open(Item);
        IsTabStop = true;
        KeyDown += (_, e) => { if (e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) Nav.Open(Item); };
    }

    public void Bind(object item, string? poster, string title, string sub, string? badge = null, double progress = -1)
    {
        Item = item;
        _title.Text = title;
        _sub.Text = sub;
        if (poster != _url)
        {
            _url = poster;
            _art.Background = U.Bitmap(poster, (int)(Width * 1.5)) is { } b ? new ImageBrush { ImageSource = b, Stretch = Stretch.UniformToFill } : U.CardBrush;
        }
        _badge.Visibility = badge is null ? Visibility.Collapsed : Visibility.Visible;
        if (badge is not null) { _badge.Child = U.T(badge, 11, FontWeights.SemiBold); _badge.Background = U.AccentBrush; }
        _progress.Visibility = progress >= 0 ? Visibility.Visible : Visibility.Collapsed;
        if (progress >= 0) _progress.Value = progress;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, title);
    }

    public static PosterCard For(object item, double width = 160)
    {
        var c = new PosterCard(width);
        Bind(c, item);
        return c;
    }

    public static void Bind(PosterCard c, object item)
    {
        switch (item)
        {
            case Movie m:
                c.Bind(m, m.PosterUrl("w342"), m.Title, string.Join(" · ", new[] { m.Year, m.Meta.Genres?.FirstOrDefault() }.Where(x => !string.IsNullOrEmpty(x))));
                break;
            case Series s:
                var meta = LibraryStore.Shared.SeriesMeta(s);
                c.Bind(s, TmdbImage.Url(meta?.Poster ?? meta?.PosterClean, "w342"), meta?.Title ?? s.Name,
                    string.Join(" · ", new[] { s.SeasonLabel ?? (s.Season is { } n ? $"第 {n} 季" : null), s.Year }.Where(x => !string.IsNullOrEmpty(x))),
                    s.Full == false ? "更新中" : null);
                break;
            case CatalogItem ci:
                var req = RequestCenter.Shared.Status(ci.Src, ci.Id, 0) ?? ci.Req;
                c.Bind(ci, TmdbImage.Url(ci.Poster, "w342"), ci.Title, string.Join(" · ", new[] { ci.Year, ci.Src == "tv" ? "剧集" : "电影" }.Where(x => !string.IsNullOrEmpty(x))),
                    req is { State: RequestState.Active } ? "请求中" : "可请求");
                break;
            case PlaybackHistory.Entry e:
                var mv = LibraryStore.Shared.MovieByPath(e.Path);
                c.Bind(e, mv?.PosterUrl("w342"), e.Title, $"看到 {Format.Clock(e.Position)}", null, e.Duration > 0 ? e.Position / e.Duration : 0);
                break;
        }
    }
}

/// <summary>ItemsRepeater 的元素工厂：海报卡回收复用（几千部也不卡）</summary>
public sealed partial class PosterFactory : IElementFactory
{
    readonly Stack<PosterCard> _pool = new();
    readonly double _width;
    public PosterFactory(double width = 160) { _width = width; }

    public UIElement GetElement(ElementFactoryGetArgs args)
    {
        var c = _pool.Count > 0 ? _pool.Pop() : new PosterCard(_width);
        PosterCard.Bind(c, args.Data);
        return c;
    }

    public void RecycleElement(ElementFactoryRecycleArgs args)
    {
        if (args.Element is PosterCard c) _pool.Push(c);
    }
}
