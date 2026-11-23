using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;
using Windows.UI.Text;

namespace Cuven.App.UI;

/// <summary>整个 App 的界面都用 C# 搭（不用 XAML 编译器）：这些是搭界面的小工具</summary>
static class U
{
    public static readonly Color Accent = Color.FromArgb(255, 10, 132, 255);
    public static readonly Color AccentDim = Color.FromArgb(255, 0, 100, 210);
    public static Brush AccentBrush { get; } = new SolidColorBrush(Accent);
    public static Brush White { get; } = new SolidColorBrush(Colors.White);
    public static Brush Dim { get; } = new SolidColorBrush(Color.FromArgb(178, 255, 255, 255));
    public static Brush Faint { get; } = new SolidColorBrush(Color.FromArgb(110, 255, 255, 255));
    public static Brush CardBrush { get; } = new SolidColorBrush(Color.FromArgb(22, 255, 255, 255));
    public static Brush CardHover { get; } = new SolidColorBrush(Color.FromArgb(40, 255, 255, 255));
    public static Brush Transparent { get; } = new SolidColorBrush(Colors.Transparent);
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Microsoft YaHei UI, Segoe UI");
    public static readonly FontFamily Display = new("Segoe UI Variable Display, Microsoft YaHei UI, Segoe UI");

    public static Brush Res(string key, Brush fallback) =>
        Application.Current.Resources.TryGetValue(key, out var v) && v is Brush b ? b : fallback;

    public static T With<T>(this T e, Action<T> f) { f(e); return e; }

    public static TextBlock T(string text, double size = 14, FontWeight? weight = null, Brush? fg = null, int lines = 1, bool wrap = false)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = size,
            FontFamily = size >= 24 ? Display : Font,
            FontWeight = weight ?? FontWeights.Normal,
            Foreground = fg ?? White,
            TextWrapping = wrap || lines > 1 ? TextWrapping.WrapWholeWords : TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxLines = lines,
        };
    }

    public static TextBlock Title(string text, double size = 28) => T(text, size, FontWeights.SemiBold);

    public static StackPanel V(double spacing, params UIElement?[] kids)
    {
        var s = new StackPanel { Orientation = Orientation.Vertical, Spacing = spacing };
        foreach (var k in kids) if (k is not null) s.Children.Add(k);
        return s;
    }

    public static StackPanel H(double spacing, params UIElement?[] kids)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var k in kids) if (k is not null) s.Children.Add(k);
        return s;
    }

    public static FontIcon Icon(string glyph, double size = 16) => new() { Glyph = glyph, FontSize = size, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets") };

    public static Button Btn(string text, string? glyph, RoutedEventHandler click, bool accent = false, double height = 40)
    {
        var content = glyph is null ? (UIElement)T(text, 14, FontWeights.SemiBold) : H(8, Icon(glyph, 15), T(text, 14, FontWeights.SemiBold));
        var b = new Button
        {
            Content = content,
            Height = height,
            Padding = new Thickness(18, 0, 18, 0),
            CornerRadius = new CornerRadius(height / 2),
        };
        if (accent)
        {
            b.Background = AccentBrush;
            b.Foreground = White;
            if (Application.Current.Resources.TryGetValue("AccentButtonStyle", out var st) && st is Style s) b.Style = s;
        }
        b.Click += click;
        return b;
    }

    public static Button IconBtn(string glyph, RoutedEventHandler click, string tip, double size = 40, double glyphSize = 18)
    {
        var b = new Button
        {
            Content = Icon(glyph, glyphSize),
            Width = size,
            Height = size,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(size / 2),
            Background = Transparent,
            BorderThickness = new Thickness(0),
        };
        ToolTipService.SetToolTip(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
        b.Click += click;
        return b;
    }

    public static BitmapImage? Bitmap(string? url, int decodeWidth)
    {
        if (string.IsNullOrEmpty(url) || !Uri.TryCreate(url, UriKind.Absolute, out var u)) return null;
        return new BitmapImage(u) { DecodePixelWidth = decodeWidth, DecodePixelType = DecodePixelType.Logical };
    }

    public static Image Img(string? url, int decodeWidth, Stretch stretch = Stretch.UniformToFill)
    {
        var i = new Image { Stretch = stretch };
        if (Bitmap(url, decodeWidth) is { } b) i.Source = b;
        return i;
    }

    /// <summary>圆角图（ImageBrush 跟着 CornerRadius 裁）</summary>
    public static Border RoundImg(string? url, int decodeWidth, double radius, Stretch stretch = Stretch.UniformToFill)
    {
        var b = new Border { CornerRadius = new CornerRadius(radius), Background = CardBrush };
        if (Bitmap(url, decodeWidth) is { } bmp)
            b.Background = new ImageBrush { ImageSource = bmp, Stretch = stretch };
        return b;
    }

    public static Grid Rows(params string[] defs)
    {
        var g = new Grid();
        foreach (var d in defs) g.RowDefinitions.Add(new RowDefinition { Height = Len(d) });
        return g;
    }

    public static Grid Cols(params string[] defs)
    {
        var g = new Grid();
        foreach (var d in defs) g.ColumnDefinitions.Add(new ColumnDefinition { Width = Len(d) });
        return g;
    }

    static GridLength Len(string d) =>
        d == "auto" ? GridLength.Auto : d.EndsWith('*') ? new GridLength(d.Length == 1 ? 1 : double.Parse(d[..^1]), GridUnitType.Star) : new GridLength(double.Parse(d));

    public static T At<T>(this T e, int row = 0, int col = 0, int rowSpan = 1, int colSpan = 1) where T : FrameworkElement
    {
        Grid.SetRow(e, row); Grid.SetColumn(e, col);
        if (rowSpan > 1) Grid.SetRowSpan(e, rowSpan);
        if (colSpan > 1) Grid.SetColumnSpan(e, colSpan);
        return e;
    }

    public static Grid Add(this Grid g, params UIElement?[] kids)
    {
        foreach (var k in kids) if (k is not null) g.Children.Add(k);
        return g;
    }

    /// <summary>从下往上变黑的渐变（大图上叠字用）</summary>
    public static Brush Fade(double topAlpha = 0, double bottomAlpha = 0.92, Color? c = null, bool horizontal = false)
    {
        var col = c ?? Color.FromArgb(255, 12, 12, 14);
        var g = new LinearGradientBrush
        {
            StartPoint = horizontal ? new Windows.Foundation.Point(0, 0) : new Windows.Foundation.Point(0, 0),
            EndPoint = horizontal ? new Windows.Foundation.Point(1, 0) : new Windows.Foundation.Point(0, 1),
        };
        g.GradientStops.Add(new GradientStop { Color = Color.FromArgb((byte)(topAlpha * 255), col.R, col.G, col.B), Offset = 0 });
        g.GradientStops.Add(new GradientStop { Color = Color.FromArgb((byte)(bottomAlpha * 255), col.R, col.G, col.B), Offset = 1 });
        return g;
    }

    public static Border Pill(string text, Brush? bg = null)
    {
        return new Border
        {
            Background = bg ?? CardHover,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8, 3, 8, 3),
            Child = T(text, 12, FontWeights.SemiBold),
        };
    }

    /// <summary>横着滑的一排（首页的货架）</summary>
    public static ScrollViewer Shelf(StackPanel row)
    {
        row.Orientation = Orientation.Horizontal;
        Inset.Track(row, (r, l) => r.Padding = new Thickness(l, 4, Inset.Right, 14));
        return new ScrollViewer
        {
            Content = row,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Disabled,
        };
    }

    /// <summary>鼠标移上去轻轻放大（隐式动画）</summary>
    public static void HoverGrow(UIElement e, float scale = 1.04f)
    {
        e.ScaleTransition = new Vector3Transition { Duration = TimeSpan.FromMilliseconds(160) };
        e.PointerEntered += (_, _) =>
        {
            if (e is FrameworkElement fe) e.CenterPoint = new System.Numerics.Vector3((float)fe.ActualWidth / 2, (float)fe.ActualHeight / 2, 0);
            e.Scale = new System.Numerics.Vector3(scale, scale, 1);
        };
        e.PointerExited += (_, _) => e.Scale = System.Numerics.Vector3.One;
        e.PointerCanceled += (_, _) => e.Scale = System.Numerics.Vector3.One;
    }

    public static void Toast(XamlRoot? root, string title, string message)
    {
        if (root is null) return;
        var d = new ContentDialog { Title = title, Content = message, CloseButtonText = "好", XamlRoot = root, RequestedTheme = ElementTheme.Dark };
        _ = d.ShowAsync();
    }
}
