using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.Text;

namespace Cuven.App.UI;

// ─────────────────────────────────────────────────────────────────────────────
//  Mac 风格的设计系统（用户要求「尽可能和 Mac 原生软件靠近：磨砂玻璃、液态玻璃、MacBook 那样的交互和动效」）
//
//  · 液态玻璃（Glass）：程序内亚克力（模糊下面的内容）+ 一层从上往下淡掉的光泽 + 一圈高光描边
//    （左上亮、右下弱，像玻璃边缘的折射）+ 投影。侧边栏浮在内容上，海报、大图从它下面滑过去
//  · 控件：胶囊按钮（主按钮白底黑字，和 Apple TV App 一样）、玻璃圆钮、红黄绿三个窗口按钮
//  · 动效：都用弹簧（Composition 的 NaturalMotion）：悬停放大、按下回弹、选中的那块玻璃滑过去时拉长再收回
// ─────────────────────────────────────────────────────────────────────────────

public enum GlassKind
{
    /// <summary>侧边栏、播放控制条：清透，模糊强</summary>
    Regular,
    /// <summary>浮在大图上的小按钮：更透</summary>
    Clear,
    /// <summary>选中的那一格</summary>
    Selection,
    /// <summary>浅色（登录页）</summary>
    Light,
}

static class Mac
{
    public static readonly Color Blue = Color.FromArgb(255, 10, 132, 255);
    public static readonly Color Canvas = Color.FromArgb(255, 18, 18, 20);
    public static Brush CanvasBrush { get; } = new SolidColorBrush(Canvas);
    public static Brush Label { get; } = new SolidColorBrush(Colors.White);
    public static Brush Secondary { get; } = new SolidColorBrush(Color.FromArgb(158, 235, 235, 245));
    public static Brush Tertiary { get; } = new SolidColorBrush(Color.FromArgb(92, 235, 235, 245));
    public static Brush Separator { get; } = new SolidColorBrush(Color.FromArgb(26, 255, 255, 255));
    public static Brush Hover { get; } = new SolidColorBrush(Color.FromArgb(18, 255, 255, 255));
    public static Brush Press { get; } = new SolidColorBrush(Color.FromArgb(34, 255, 255, 255));
    public static Brush BlueBrush { get; } = new SolidColorBrush(Blue);
    public static Brush Clear { get; } = new SolidColorBrush(Colors.Transparent);

    public static Brush Acrylic(GlassKind k) => k switch
    {
        GlassKind.Light => new AcrylicBrush { TintColor = Color.FromArgb(255, 250, 250, 252), TintOpacity = 0.55, TintLuminosityOpacity = 0.85, FallbackColor = Color.FromArgb(240, 246, 246, 248) },
        GlassKind.Clear => new AcrylicBrush { TintColor = Color.FromArgb(255, 30, 30, 34), TintOpacity = 0.10, TintLuminosityOpacity = 0.28, FallbackColor = Color.FromArgb(150, 40, 40, 44) },
        GlassKind.Selection => new SolidColorBrush(Color.FromArgb(36, 255, 255, 255)),
        _ => new AcrylicBrush { TintColor = Color.FromArgb(255, 28, 28, 32), TintOpacity = 0.32, TintLuminosityOpacity = 0.62, FallbackColor = Color.FromArgb(235, 36, 36, 40) },
    };

    /// <summary>玻璃上面那层光泽：顶上一抹亮，往下淡掉</summary>
    public static Brush Sheen(double strength = 1)
    {
        var g = new LinearGradientBrush { StartPoint = new Windows.Foundation.Point(0.5, 0), EndPoint = new Windows.Foundation.Point(0.5, 1) };
        g.GradientStops.Add(new GradientStop { Color = Color.FromArgb((byte)(30 * strength), 255, 255, 255), Offset = 0 });
        g.GradientStops.Add(new GradientStop { Color = Color.FromArgb((byte)(8 * strength), 255, 255, 255), Offset = 0.38 });
        g.GradientStops.Add(new GradientStop { Color = Color.FromArgb(0, 255, 255, 255), Offset = 0.62 });
        g.GradientStops.Add(new GradientStop { Color = Color.FromArgb((byte)(10 * strength), 255, 255, 255), Offset = 1 });
        return g;
    }

    /// <summary>玻璃边缘的高光：左上亮、中间弱、右下再亮一点（像光从左上打过来、在边上折了一下）</summary>
    public static Brush Rim(bool light = false)
    {
        var g = new LinearGradientBrush { StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(1, 1) };
        byte a0 = light ? (byte)200 : (byte)120, a1 = light ? (byte)60 : (byte)26, a2 = light ? (byte)120 : (byte)64;
        g.GradientStops.Add(new GradientStop { Color = Color.FromArgb(a0, 255, 255, 255), Offset = 0 });
        g.GradientStops.Add(new GradientStop { Color = Color.FromArgb(a1, 255, 255, 255), Offset = 0.45 });
        g.GradientStops.Add(new GradientStop { Color = Color.FromArgb(a2, 255, 255, 255), Offset = 1 });
        return g;
    }

    public static TextBlock Text(string s, double size = 13, FontWeight? w = null, Brush? fg = null, int lines = 1) => U.T(s, size, w, fg ?? Label, lines);
    public static TextBlock LargeTitle(string s) => U.T(s, 30, FontWeights.Bold, Label);

    // ── 弹簧动效 ──────────────────────────────────────────────

    static Visual V(UIElement e) => ElementCompositionPreview.GetElementVisual(e);

    public static void SpringScale(UIElement e, float s, float damping = 0.62f, double periodMs = 42)
    {
        var v = V(e);
        if (e is FrameworkElement fe) v.CenterPoint = new Vector3((float)fe.ActualWidth / 2, (float)fe.ActualHeight / 2, 0);
        var a = v.Compositor.CreateSpringVector3Animation();
        a.FinalValue = new Vector3(s, s, 1);
        a.DampingRatio = damping;
        a.Period = TimeSpan.FromMilliseconds(periodMs);
        v.StartAnimation("Scale", a);
    }

    /// <summary>只拉一个方向（选中那块玻璃滑动时竖着拉长，像一滴水）</summary>
    public static void SpringScaleXY(UIElement e, Vector3 from, Vector3 to, float damping = 0.5f, double periodMs = 55)
    {
        var v = V(e);
        if (e is FrameworkElement fe) v.CenterPoint = new Vector3((float)fe.ActualWidth / 2, (float)fe.ActualHeight / 2, 0);
        var a = v.Compositor.CreateSpringVector3Animation();
        a.InitialValue = from;
        a.FinalValue = to;
        a.DampingRatio = damping;
        a.Period = TimeSpan.FromMilliseconds(periodMs);
        v.StartAnimation("Scale", a);
    }

    public static void SpringMove(UIElement e, Vector3 to, float damping = 0.72f, double periodMs = 48)
    {
        ElementCompositionPreview.SetIsTranslationEnabled(e, true);
        var v = V(e);
        var a = v.Compositor.CreateSpringVector3Animation();
        a.FinalValue = to;
        a.DampingRatio = damping;
        a.Period = TimeSpan.FromMilliseconds(periodMs);
        v.StartAnimation("Translation", a);
    }

    public static void Fade(UIElement e, float from, float to, double ms = 220)
    {
        var v = V(e);
        var a = v.Compositor.CreateScalarKeyFrameAnimation();
        a.InsertKeyFrame(0, from);
        a.InsertKeyFrame(1, to, v.Compositor.CreateCubicBezierEasingFunction(new Vector2(0.2f, 0), new Vector2(0, 1)));
        a.Duration = TimeSpan.FromMilliseconds(ms);
        v.StartAnimation("Opacity", a);
    }

    /// <summary>新页出现：淡入 + 从下面 10 像素弹上来（macOS 的推进动画收敛版）</summary>
    public static void Enter(UIElement e)
    {
        Fade(e, 0, 1, 240);
        ElementCompositionPreview.SetIsTranslationEnabled(e, true);
        var v = V(e);
        var a = v.Compositor.CreateSpringVector3Animation();
        a.InitialValue = new Vector3(0, 10, 0);
        a.FinalValue = Vector3.Zero;
        a.DampingRatio = 0.82f;
        a.Period = TimeSpan.FromMilliseconds(55);
        v.StartAnimation("Translation", a);
    }

    /// <summary>悬停放大、按下缩一下、松开弹回（所有能点的卡片和按钮）</summary>
    public static void Pressable(UIElement e, float hover = 1.035f, float press = 0.965f)
    {
        bool over = false;
        e.PointerEntered += (_, _) => { over = true; SpringScale(e, hover); };
        e.PointerExited += (_, _) => { over = false; SpringScale(e, 1); };
        e.PointerCanceled += (_, _) => { over = false; SpringScale(e, 1); };
        e.PointerPressed += (_, _) => SpringScale(e, press, 0.7f, 30);
        e.PointerReleased += (_, _) => SpringScale(e, over ? hover : 1, 0.45f, 45);
        e.PointerCaptureLost += (_, _) => SpringScale(e, over ? hover : 1);
    }

    /// <summary>投影（落在 receiver 上）</summary>
    public static void Shadow(UIElement e, UIElement receiver, float depth = 32)
    {
        var s = new ThemeShadow();
        s.Receivers.Add(receiver);
        e.Shadow = s;
        e.Translation = new Vector3(0, 0, depth);
    }
}

/// <summary>
/// 液态玻璃：亚克力 + 光泽 + 高光描边（按圆角裁）。内容放在 Content 里（在光泽之上、描边之下）
/// </summary>
public sealed partial class Glass : Grid
{
    readonly Border _sheen = new() { IsHitTestVisible = false };
    readonly Border _rim = new() { IsHitTestVisible = false, BorderThickness = new Thickness(1) };
    UIElement? _content;
    public GlassKind Kind { get; }

    public Glass(double radius, GlassKind kind = GlassKind.Regular)
    {
        Kind = kind;
        var cr = new CornerRadius(radius);
        CornerRadius = cr;
        Background = Mac.Acrylic(kind);
        _sheen.CornerRadius = cr;
        _sheen.Background = Mac.Sheen(kind == GlassKind.Light ? 2.2 : kind == GlassKind.Selection ? 1.6 : 1);
        _rim.CornerRadius = cr;
        _rim.BorderBrush = Mac.Rim(kind == GlassKind.Light);
        Children.Add(_sheen);
        Children.Add(_rim);
    }

    public UIElement? Content
    {
        get => _content;
        set
        {
            if (_content is not null) Children.Remove(_content);
            _content = value;
            if (value is not null) Children.Insert(1, value);
        }
    }

    /// <summary>悬停时光泽亮一点</summary>
    public double Shine { set => _sheen.Opacity = value; }
}

/// <summary>
/// 按钮（不是系统的 Button：自己管样式和弹簧）。种类：主按钮（白底黑字胶囊）、玻璃胶囊、玻璃圆钮、透明（悬停才显底）
/// </summary>
public sealed partial class MacButton : Grid
{
    public enum Style { Primary, Glass, Circle, Plain, Accent }
    public event Action? Click;
    readonly Glass? _glass;
    readonly Border? _solid;
    readonly ContentPresenter _content = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly Style _style;
    public MenuFlyout? Menu { get; set; }

    public MacButton(Style style, UIElement content, double height = 36, string? tip = null)
    {
        _style = style;
        Height = height;
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        var radius = height / 2;
        if (style == Style.Circle) Width = height;
        if (style is Style.Glass or Style.Circle)
        {
            _glass = new Glass(radius, GlassKind.Clear) { Content = _content };
            Children.Add(_glass);
        }
        else
        {
            _solid = new Border
            {
                CornerRadius = new CornerRadius(style == Style.Plain ? 8 : radius),
                Background = style switch { Style.Primary => new SolidColorBrush(Colors.White), Style.Accent => Mac.BlueBrush, _ => Mac.Clear },
                Child = _content,
            };
            Children.Add(_solid);
        }
        _content.Content = content;
        _content.Margin = style == Style.Circle ? new Thickness(0) : new Thickness(style == Style.Plain ? 8 : 18, 0, style == Style.Plain ? 8 : 18, 0);
        if (style == Style.Primary) _content.Foreground = new SolidColorBrush(Color.FromArgb(255, 18, 18, 20));
        if (style == Style.Accent) _content.Foreground = new SolidColorBrush(Colors.White);
        if (tip is not null)
        {
            ToolTipService.SetToolTip(this, tip);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, tip);
        }
        Mac.Pressable(this, style == Style.Plain ? 1.0f : 1.05f, 0.95f);
        PointerEntered += (_, _) => Hover(true);
        PointerExited += (_, _) => Hover(false);
        Tapped += (_, e) => { e.Handled = true; Invoke(); };
        KeyDown += (_, e) =>
        {
            if (e.Key is Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space) { e.Handled = true; Invoke(); }
        };
    }

    void Invoke()
    {
        if (Menu is not null) Menu.ShowAt(this, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedLeft });
        Click?.Invoke();
    }

    void Hover(bool on)
    {
        if (_glass is not null) _glass.Shine = on ? 2.0 : 1.0;
        if (_solid is not null && _style == Style.Plain) _solid.Background = on ? Mac.Hover : Mac.Clear;
        if (_solid is not null && _style == Style.Primary) _solid.Background = new SolidColorBrush(on ? Color.FromArgb(255, 232, 232, 236) : Colors.White);
        if (_solid is not null && _style == Style.Accent) _solid.Background = new SolidColorBrush(on ? Color.FromArgb(255, 40, 148, 255) : Mac.Blue);
    }

    public void SetContent(UIElement c) => _content.Content = c;

    public bool Enabled
    {
        get => IsHitTestVisible;
        set { IsHitTestVisible = value; Opacity = value ? 1 : 0.5; }
    }

    public static MacButton Pill(string text, string? glyph, Action click, Style style = Style.Glass, double height = 36)
    {
        var fg = style == Style.Primary ? new SolidColorBrush(Color.FromArgb(255, 18, 18, 20)) : style == Style.Accent ? new SolidColorBrush(Colors.White) : Mac.Label;
        UIElement c = glyph is null
            ? U.T(text, 14, FontWeights.SemiBold, fg)
            : U.H(7, U.Icon(glyph, 14).With(i => i.Foreground = fg), U.T(text, 14, FontWeights.SemiBold, fg));
        var b = new MacButton(style, c, height);
        b.Click += click;
        return b;
    }

    public static MacButton Round(string glyph, Action click, string tip, double size = 36, double glyphSize = 15, Style style = Style.Circle)
    {
        var b = new MacButton(style, U.Icon(glyph, glyphSize).With(i => i.Foreground = Mac.Label), size, tip);
        b.Click += click;
        return b;
    }
}

/// <summary>红黄绿三个窗口按钮（关闭 / 最小化 / 全屏）：鼠标移到这一组上才显出 × − ⤢；窗口不在前台时变灰</summary>
public sealed partial class TrafficLights : StackPanel
{
    static readonly Color Red = Color.FromArgb(255, 255, 95, 87), Yellow = Color.FromArgb(255, 254, 188, 46), Green = Color.FromArgb(255, 40, 200, 64);
    static readonly Color Idle = Color.FromArgb(255, 90, 90, 94), IdleLight = Color.FromArgb(255, 205, 205, 208);
    readonly (Grid dot, Microsoft.UI.Xaml.Shapes.Ellipse fill, FontIcon glyph, Color color)[] _dots;
    bool _active = true, _light;

    public TrafficLights(Action close, Action minimize, Action zoom)
    {
        Orientation = Orientation.Horizontal;
        Spacing = 8;
        Padding = new Thickness(2);
        _dots = new[] { Dot(Red, "", close, "关闭"), Dot(Yellow, "", minimize, "最小化"), Dot(Green, "", zoom, "全屏") };
        foreach (var d in _dots) Children.Add(d.dot);
        PointerEntered += (_, _) => { foreach (var d in _dots) { d.glyph.Opacity = 1; d.fill.Fill = new SolidColorBrush(d.color); } };
        PointerExited += (_, _) => Refresh();
    }

    (Grid, Microsoft.UI.Xaml.Shapes.Ellipse, FontIcon, Color) Dot(Color c, string glyph, Action act, string tip)
    {
        var fill = new Microsoft.UI.Xaml.Shapes.Ellipse
        {
            Width = 12, Height = 12, Fill = new SolidColorBrush(c),
            Stroke = new SolidColorBrush(Color.FromArgb(46, 0, 0, 0)), StrokeThickness = 0.5,
        };
        var g = U.Icon(glyph, 7);
        g.Foreground = new SolidColorBrush(Color.FromArgb(170, 0, 0, 0));
        g.Opacity = 0;
        g.FontWeight = FontWeights.Bold;
        var dot = new Grid { Width = 12, Height = 12, Background = Mac.Clear };
        dot.Children.Add(fill);
        dot.Children.Add(g);
        ToolTipService.SetToolTip(dot, tip);
        dot.Tapped += (_, e) => { e.Handled = true; act(); };
        dot.PointerPressed += (_, _) => fill.Opacity = 0.75;
        dot.PointerReleased += (_, _) => fill.Opacity = 1;
        dot.PointerExited += (_, _) => fill.Opacity = 1;
        return (dot, fill, g, c);
    }

    public void SetActive(bool active) { _active = active; Refresh(); }
    public void SetLight(bool light) { _light = light; Refresh(); }

    void Refresh()
    {
        foreach (var d in _dots)
        {
            d.glyph.Opacity = 0;
            d.fill.Fill = new SolidColorBrush(_active ? d.color : _light ? IdleLight : Idle);
        }
    }
}
