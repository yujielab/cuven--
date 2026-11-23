using System.Numerics;
using Cuven.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Cuven.App.UI;

// 照网页版（web/index.html）的几样部件：磨砂胶囊的栏目标题、带左右箭头的横排、排名数字、16:9 卡、年份栏

static class Web
{
    /// <summary>栏目标题：一枚磨砂胶囊里的字（「今日推荐」「最新加入」）</summary>
    public static Glass SectionPill(string text) => new(20, GlassKind.Regular)
    {
        Height = 40,
        HorizontalAlignment = HorizontalAlignment.Left,
        Content = U.T(text, 18, FontWeights.Bold).With(t => { t.Margin = new Thickness(18, 0, 18, 0); t.VerticalAlignment = VerticalAlignment.Center; }),
    };

    /// <summary>小胶囊（「2026 · 电影」「评分 7.3」「Cuven 品质保证」）</summary>
    public static Glass Chip(string text, double size = 12) => new(12, GlassKind.Clear)
    {
        HorizontalAlignment = HorizontalAlignment.Left,
        Content = U.T(text, size, FontWeights.SemiBold).With(t => t.Margin = new Thickness(12, 4, 12, 5)),
    };

    /// <summary>横着滑的一排，左右各一颗磨砂圆钮翻一页（鼠标移上去才显出来）</summary>
    public static Grid Row(StackPanel items, double spacing = 18)
    {
        items.Orientation = Orientation.Horizontal;
        items.Spacing = spacing;
        Inset.Track(items, (r, l) => r.Padding = new Thickness(l, 6, l, 18));
        var sv = new ScrollViewer
        {
            Content = items,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Disabled,
        };
        var g = new Grid();
        g.Children.Add(sv);
        MacButton Arrow(string glyph, int dir) => MacButton.Round(glyph, () =>
            sv.ChangeView(Math.Max(0, sv.HorizontalOffset + dir * sv.ViewportWidth * 0.8), null, null, false), dir > 0 ? "下一页" : "上一页", 44, 15);
        var prev = Arrow("", -1);
        var next = Arrow("", 1);
        prev.HorizontalAlignment = HorizontalAlignment.Left;
        next.HorizontalAlignment = HorizontalAlignment.Right;
        foreach (var a in new[] { prev, next })
        {
            a.VerticalAlignment = VerticalAlignment.Center;
            a.Margin = new Thickness(14, 0, 14, 12);
            a.Opacity = 0;
            a.OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(180) };
            g.Children.Add(a);
        }
        void show(bool on)
        {
            prev.Opacity = on && sv.HorizontalOffset > 4 ? 1 : 0;
            next.Opacity = on && sv.HorizontalOffset < sv.ScrollableWidth - 4 ? 1 : 0;
        }
        g.PointerEntered += (_, _) => show(true);
        g.PointerExited += (_, _) => show(false);
        sv.ViewChanged += (_, _) => show(true);
        return g;
    }

    /// <summary>空心的大数字（排名）：八个方向的白描边，中间填黑（网页版 -webkit-text-stroke 的效果）</summary>
    public static Grid OutlineNumber(string n, double size)
    {
        var g = new Grid { IsHitTestVisible = false };
        double o = Math.Max(1.5, size / 110);
        foreach (var (dx, dy) in new[] { (1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7), (-0.7, -0.7) })
            g.Children.Add(Num(n, size, U.White).With(t => t.RenderTransform = new TranslateTransform { X = dx * o, Y = dy * o }));
        g.Children.Add(Num(n, size, new SolidColorBrush(Colors.Black)));
        return g;
    }

    static TextBlock Num(string n, double size, Brush fg) => new()
    {
        Text = n, FontSize = size, FontWeight = FontWeights.SemiBold, Foreground = fg,
        FontFamily = new FontFamily("Segoe UI Variable Display, Segoe UI"), LineHeight = size * 0.9, LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
    };

    /// <summary>16:9 的卡（「最新加入」）：剧照，左下角压着片名，下面一行小字</summary>
    public static FrameworkElement Landscape(object item, string? image, string title, string sub, double width = 400)
    {
        var h = Math.Round(width * 9 / 16);
        var art = new Grid { Width = width, Height = h, CornerRadius = new CornerRadius(14), Background = U.CardBrush };
        if (U.Bitmap(image, (int)(width * 1.5)) is { } b) art.Background = new ImageBrush { ImageSource = b, Stretch = Stretch.UniformToFill };
        art.Children.Add(new Border { Background = U.Fade(0, 0.75, Colors.Black), Height = h * 0.45, VerticalAlignment = VerticalAlignment.Bottom, CornerRadius = new CornerRadius(0, 0, 14, 14) });
        art.Children.Add(U.T(title, 17, FontWeights.Bold).With(t => { t.Margin = new Thickness(16, 0, 16, 14); t.VerticalAlignment = VerticalAlignment.Bottom; }));
        var col = U.V(8, art, U.T(sub, 12, null, Mac.Tertiary));
        col.Width = width;
        Mac.Pressable(art, 1.03f, 0.97f);
        art.Tapped += (_, _) => Nav.Open(item);
        return col;
    }

    /// <summary>剧集的竖大卡：剧照裁成竖的，左下角字标 / 名字 +「查看剧集 ›」</summary>
    public static FrameworkElement SeriesTall(Series s, double width = 320, double height = 440)
    {
        var lib = LibraryStore.Shared;
        var meta = lib.SeriesMeta(s);
        var card = new Grid { Width = width, Height = height, CornerRadius = new CornerRadius(22), Background = U.CardBrush };
        var img = TmdbImage.Url(meta?.Backdrop ?? meta?.Poster, "w780");
        if (U.Bitmap(img, (int)(width * 2)) is { } bmp) card.Background = new ImageBrush { ImageSource = bmp, Stretch = Stretch.UniformToFill };
        card.Children.Add(new Border { Background = U.Fade(0, 0.85, Colors.Black), Height = height * 0.55, VerticalAlignment = VerticalAlignment.Bottom, CornerRadius = new CornerRadius(0, 0, 22, 22) });
        var info = new StackPanel { Spacing = 8, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(22, 0, 22, 22) };
        if (!string.IsNullOrEmpty(meta?.Logo))
            info.Children.Add(new Image { Source = U.Bitmap(TmdbImage.Url(meta.Logo, "w500"), 400), MaxHeight = 80, MaxWidth = width - 60, HorizontalAlignment = HorizontalAlignment.Left, Stretch = Stretch.Uniform });
        else info.Children.Add(U.T(meta?.Title ?? s.Name, 26, FontWeights.Bold, null, 2));
        info.Children.Add(U.H(4, U.T("查看剧集", 13, FontWeights.SemiBold, Mac.Secondary), U.Icon("\uE76C", 10).With(i => { i.Foreground = Mac.Secondary; i.VerticalAlignment = VerticalAlignment.Center; })));
        card.Children.Add(info);
        Mac.Pressable(card, 1.03f, 0.97f);
        card.Tapped += (_, _) => Nav.Open(s);
        return card;
    }

    /// <summary>年份栏：一条磨砂玻璃（左边年份，右边蓝色胶囊「查看电影和剧集 ›」）</summary>
    public static FrameworkElement YearBar(string year, Action more)
    {
        var bar = new Glass(23, GlassKind.Regular) { Height = 46 };
        var g = U.Cols("*", "auto");
        g.Children.Add(U.T(year, 15, FontWeights.Bold).With(t => { t.Margin = new Thickness(20, 0, 0, 0); t.VerticalAlignment = VerticalAlignment.Center; }).At(0, 0));
        var pill = MacButton.Pill("查看电影和剧集", "", more, MacButton.Style.Accent, 30);
        pill.Margin = new Thickness(0, 0, 8, 0);
        g.Children.Add(pill.At(0, 1));
        bar.Content = g;
        return Inset.Track(bar, (e, l) => e.Margin = new Thickness(l, 26, l, 10));
    }
}
