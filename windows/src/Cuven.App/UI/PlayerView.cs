using System.Runtime.InteropServices;
using Cuven.App.Native;
using Cuven.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Cuven.App.UI;

/// <summary>要放什么：片库路径 + 给人看的名字；剧集带上整季的分集（放完自动下一集）</summary>
public sealed class PlayRequest
{
    public required string Path { get; init; }
    public required string Name { get; init; }
    public required string Title { get; init; }
    public string? Subtitle { get; init; }
    public double Start { get; set; }
    public string? SeriesPath { get; init; }
    public List<EpisodeFile>? Episodes { get; init; }
    public int EpisodeIndex { get; init; }
    public string? SeriesTitle { get; init; }

    public static void Movie(Movie m, Video? version = null)
    {
        var v = version ?? m.Versions.FirstOrDefault() ?? m.Video;
        Go(new PlayRequest { Path = v.Path, Name = v.Name, Title = m.Title, Subtitle = m.Year, Start = PlaybackHistory.Shared.ResumeAt(v.Path) });
    }

    public static void Episode(Series s, string seriesTitle, List<EpisodeFile> eps, int index, string? epName = null)
    {
        if (index < 0 || index >= eps.Count) return;
        var e = eps[index];
        var label = $"第 {s.Season ?? 1} 季 · 第 {e.Ep ?? index + 1} 集" + (string.IsNullOrEmpty(epName) ? "" : " · " + epName);
        Go(new PlayRequest
        {
            Path = e.Path, Name = e.Name, Title = seriesTitle, Subtitle = label, SeriesPath = s.Path, Episodes = eps, EpisodeIndex = index,
            SeriesTitle = seriesTitle, Start = PlaybackHistory.Shared.ResumeAt(e.Path),
        });
    }

    public static void Resume(PlaybackHistory.Entry e) =>
        Go(new PlayRequest { Path = e.Path, Name = e.Name, Title = e.Title, Start = e.Position, SeriesPath = e.SeriesPath });

    static void Go(PlayRequest r) => MainWindow.Current.Play(r);
}

/// <summary>秒 → 0:00（滑块上的提示）</summary>
sealed partial class TimeConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) => Format.Clock(value is double d ? d : 0);
    public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
}

/// <summary>
/// 播放器：整窗的 SwapChainPanel（原生核心直接上屏）+ 上下两条控制栏（三秒不动就藏，光标一起藏）。
/// 键盘：空格 / K 播放暂停，← → 退进 10 秒，↑ ↓ 音量，F / 双击全屏，Esc 退出全屏 / 关掉，M 静音，C 字幕，I 播放信息，N 下一集
/// </summary>
public sealed partial class PlayerView : Grid
{
    static readonly CvEventCallback s_cb = OnNativeEvent;   // 原生回调：一直留着，不让 GC 收

    readonly PlayRequest _req;
    readonly NativeSurface _surface = new(Native.Native.SurfaceVideo);
    IntPtr _player;
    GCHandle _self;
    readonly Grid _chrome = new();
    readonly Slider _seek = new() { Minimum = 0, Maximum = 1, StepFrequency = 0.1, IsThumbToolTipEnabled = true, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _pos = U.T("0:00", 13, null, U.Dim), _dur = U.T("0:00", 13, null, U.Dim);
    readonly Button _playBtn;
    readonly FontIcon _playIcon = U.Icon("", 22);
    readonly ProgressRing _ring = new() { IsActive = true, Width = 56, Height = 56, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _error = U.T("", 16, null, U.White, 4);
    readonly TextBlock _info = U.T("", 12, null, U.Dim, 12);
    readonly Border _infoBox;
    readonly Button _audioBtn, _subBtn, _nextBtn;
    readonly Slider _volume = new() { Minimum = 0, Maximum = 100, Width = 110, VerticalAlignment = VerticalAlignment.Center };
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _tick, _idle;
    bool _updating, _dragging, _closed, _opened, _chromeShown = true, _endedHandled;
    double _lastRecord;
    CvState _st;
    List<SubTrack> _online = new();
    string? _onlineLoaded;
    float _volBeforeMute = 1;

    public PlayerView(PlayRequest req)
    {
        _req = req;
        Background = new SolidColorBrush(Colors.Black);
        IsTabStop = true;
        TabFocusNavigation = KeyboardNavigationMode.Cycle;
        RequestedTheme = ElementTheme.Dark;
        Children.Add(_surface.Panel);
        _surface.Ready += Start;

        // ── 上：返回 + 片名 ──
        var top = U.Cols("auto", "*");
        top.VerticalAlignment = VerticalAlignment.Top;
        top.Padding = new Thickness(20, 16, 24, 36);
        top.Background = U.Fade(0.75, 0, Colors.Black);
        top.Children.Add(U.IconBtn("", (_, _) => Exit(), "返回（Esc）", 44, 18).At(0, 0));
        top.Children.Add(U.V(0, U.T(req.Title, 20, FontWeights.SemiBold), req.Subtitle is { Length: > 0 } s ? U.T(s, 13, null, U.Dim) : null)
            .With(v => { v.Margin = new Thickness(12, 0, 0, 0); v.VerticalAlignment = VerticalAlignment.Center; }).At(0, 1));

        // ── 下：进度 + 按钮 ──
        _seek.ThumbToolTipValueConverter = new TimeConverter();
        _seek.ValueChanged += (_, e) =>
        {
            if (_updating) return;
            _pos.Text = Format.Clock(e.NewValue);
            if (!_dragging) Seek(e.NewValue);
        };
        _seek.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => _dragging = true), true);
        _seek.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => { if (_dragging) { _dragging = false; Seek(_seek.Value); } }), true);
        _seek.AddHandler(PointerCaptureLostEvent, new PointerEventHandler((_, _) => { if (_dragging) { _dragging = false; Seek(_seek.Value); } }), true);
        var bar = U.Cols("auto", "*", "auto");
        bar.ColumnSpacing = 14;
        bar.Children.Add(_pos.With(t => t.VerticalAlignment = VerticalAlignment.Center).At(0, 0));
        bar.Children.Add(_seek.At(0, 1));
        bar.Children.Add(_dur.With(t => t.VerticalAlignment = VerticalAlignment.Center).At(0, 2));

        _playBtn = new Button { Content = _playIcon, Width = 52, Height = 52, CornerRadius = new CornerRadius(26), Padding = new Thickness(0), Background = U.CardHover, BorderThickness = new Thickness(0) };
        _playBtn.Click += (_, _) => TogglePlay();
        ToolTipService.SetToolTip(_playBtn, "播放 / 暂停（空格）");
        _audioBtn = U.IconBtn("", (_, _) => { }, "音轨");
        _subBtn = U.IconBtn("", (_, _) => { }, "字幕（C）");
        _nextBtn = U.IconBtn("", (_, _) => NextEpisode(), "下一集（N）");
        _nextBtn.Visibility = req.Episodes is { } eps && req.EpisodeIndex + 1 < eps.Count ? Visibility.Visible : Visibility.Collapsed;
        _volume.Value = Settings.Shared.Volume * 100;
        _volume.ValueChanged += (_, e) => SetVolume((float)(e.NewValue / 100));
        var left = U.H(8, U.IconBtn("", (_, _) => Skip(-10), "后退 10 秒（←）"), _playBtn, U.IconBtn("", (_, _) => Skip(10), "前进 10 秒（→）"), _nextBtn);
        left.VerticalAlignment = VerticalAlignment.Center;
        var right = U.H(4, U.Icon("", 16).With(i => i.Margin = new Thickness(0, 0, 4, 0)), _volume, _audioBtn, _subBtn,
            U.IconBtn("", (_, _) => ToggleInfo(), "播放信息（I）"), U.IconBtn("", (_, _) => ToggleFullScreen(), "全屏（F）"));
        right.VerticalAlignment = VerticalAlignment.Center;
        var buttons = U.Cols("*", "auto");
        buttons.Children.Add(left.At(0, 0));
        buttons.Children.Add(right.At(0, 1));
        var bottom = U.V(8, bar, buttons);
        bottom.VerticalAlignment = VerticalAlignment.Bottom;
        bottom.Padding = new Thickness(32, 48, 32, 22);
        bottom.Background = U.Fade(0, 0.82, Colors.Black);

        _infoBox = new Border
        {
            Child = _info, Background = new SolidColorBrush(Windows.UI.Color.FromArgb(170, 0, 0, 0)), CornerRadius = new CornerRadius(10),
            Padding = new Thickness(14), Margin = new Thickness(24, 90, 0, 0), HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed,
        };
        _chrome.Children.Add(top);
        _chrome.Children.Add(bottom);
        _chrome.ChildrenTransitions = null;
        _chrome.OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(200) };
        _error.HorizontalAlignment = HorizontalAlignment.Center;
        _error.VerticalAlignment = VerticalAlignment.Center;
        _error.TextAlignment = TextAlignment.Center;
        _error.MaxWidth = 560;
        Children.Add(_ring);
        Children.Add(_error);
        Children.Add(_infoBox);
        Children.Add(_chrome);

        PointerMoved += (_, _) => Poke();
        PointerPressed += (_, _) => Poke();
        DoubleTapped += (_, e) => { if (e.OriginalSource is not FrameworkElement fe || !IsInChrome(fe)) ToggleFullScreen(); };
        Tapped += (_, e) => { if (e.OriginalSource is FrameworkElement fe && !IsInChrome(fe) && _chromeShown) TogglePlay(); };
        KeyDown += OnKey;
        _tick = DispatcherQueue.CreateTimer();
        _tick.Interval = TimeSpan.FromMilliseconds(250);
        _tick.Tick += (_, _) => Update();
        _tick.Start();
        _idle = DispatcherQueue.CreateTimer();
        _idle.Interval = TimeSpan.FromSeconds(3);
        _idle.IsRepeating = false;
        _idle.Tick += (_, _) => { if (_opened && _st.Paused == 0 && _st.Ended == 0) ShowChrome(false); };
        Win32.KeepAwake(true);
        Loaded += (_, _) => Focus(FocusState.Programmatic);
        if (!Native.Native.Ready) ShowError(Native.Native.InitError ?? "播放器核心没能启动");
    }

    bool IsInChrome(FrameworkElement fe)
    {
        for (DependencyObject? d = fe; d is not null; d = VisualTreeHelper.GetParent(d))
            if (d is Button || d is Slider || d == _infoBox) return true;
        return false;
    }

    // ── 打开 ──
    async void Start()
    {
        if (_player != IntPtr.Zero || _closed) return;
        _self = GCHandle.Alloc(this);
        _player = Native.Native.cv_player_create(_surface.Handle, s_cb, GCHandle.ToIntPtr(_self));
        if (_player == IntPtr.Zero) { ShowError("播放器创建失败"); return; }
        Native.Native.cv_player_set_volume(_player, (float)Settings.Shared.Volume);
        ApplyDisplay();
        string url;
        var local = DownloadManager.Shared.LocalFileFor(_req.Path);
        if (local is not null) url = local;
        else
        {
            try
            {
                var sign = await StreamApi.StreamSignAsync(_req.Path);
                url = StreamApi.StreamUrl(_req.Path, _req.Name, sign);
            }
            catch (Exception e) { ShowError(CuvenException.Friendly(e)); return; }
        }
        if (_closed) return;
        var audio = Settings.Shared.AudioPref == "zh" ? "zh" : "";
        var sub = Settings.Shared.SubtitlesOn ? "zh" : "";
        Native.Native.cv_player_open(_player, url, _req.Start, Settings.Shared.HardwareDecode ? 0 : 1, audio, sub);
        _ = LoadOnlineSubsAsync();
    }

    static void OnNativeEvent(IntPtr user, int ev, int arg, IntPtr text)
    {
        var msg = Native.Native.FromUtf8(text);
        if (GCHandle.FromIntPtr(user).Target is not PlayerView v) return;
        v.DispatcherQueue.TryEnqueue(() => v.OnEvent(ev, arg, msg));
    }

    void OnEvent(int ev, int arg, string? text)
    {
        if (_closed) return;
        switch (ev)
        {
            case Native.Native.EvOpened:
                _opened = true;
                App.Log("打开：" + text);
                ApplyDisplay();
                break;
            case Native.Native.EvTracks:
                BuildMenus();
                break;
            case Native.Native.EvVideo:
                ApplyDisplay();
                break;
            case Native.Native.EvError:
                ShowError(text ?? "播放出错了");
                break;
            case Native.Native.EvEnded:
                Ended();
                break;
        }
        Update();
    }

    void ShowError(string s)
    {
        _ring.IsActive = false;
        _ring.Visibility = Visibility.Collapsed;
        _error.Text = s;
        ShowChrome(true);
    }

    public void DisplayMaybeChanged() => ApplyDisplay();

    void ApplyDisplay()
    {
        if (_player == IntPtr.Zero) return;
        var d = Native.Native.QueryDisplay(MainWindow.Current.Monitor);
        Native.Native.cv_player_set_output(_player, ref d, Settings.Shared.HdrMode == "sdr" ? 1 : 0);
    }

    // ── 状态 ──
    void Update()
    {
        if (_player == IntPtr.Zero || _closed) return;
        Native.Native.cv_player_get_state(_player, out _st);
        var dur = _st.Duration > 0 ? _st.Duration : Math.Max(_st.Position, 1);
        _updating = true;
        if (Math.Abs(_seek.Maximum - dur) > 0.5) _seek.Maximum = dur;
        if (!_dragging)
        {
            _seek.Value = Math.Clamp(_st.Position, 0, dur);
            _pos.Text = Format.Clock(_st.Position);
        }
        _updating = false;
        _dur.Text = Format.Clock(_st.Duration);
        _playIcon.Glyph = _st.Paused != 0 || _st.Ended != 0 ? "" : "";
        var busy = (_st.Buffering != 0 || _st.Seeking != 0 || !_opened) && _error.Text.Length == 0;
        _ring.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        _ring.IsActive = busy;
        if (_infoBox.Visibility == Visibility.Visible) _info.Text = InfoText();
        var now = Environment.TickCount64 / 1000.0;
        if (_opened && now - _lastRecord > 5 && _st.Position > 0) { _lastRecord = now; Record(); }
    }

    string InfoText()
    {
        string hdr = _st.HdrKind switch { Native.Native.HdrPq => "HDR10（PQ）", Native.Native.HdrHlg => "HLG", Native.Native.HdrDovi => $"杜比视界 {_st.DoviProfile}", _ => "SDR" };
        var d = Native.Native.QueryDisplay(MainWindow.Current.Monitor);
        return string.Join("\n", new[]
        {
            $"视频　{_st.Video.ToUpperInvariant()} {_st.Width}×{_st.Height} @ {_st.Fps:0.###}　{(_st.HwDecode != 0 ? "硬件解码（D3D11VA）" : "软件解码")}",
            $"动态范围　{hdr} → {(_st.OutputHdr != 0 ? $"HDR 输出（屏幕 {d.MaxNits:0} 尼特）" : "SDR（BT.2390 色调映射）")}",
            $"音频　{_st.Audio.ToUpperInvariant()}",
            $"缓冲　{Math.Max(0, _st.Buffered - _st.Position):0} 秒　网络 {_st.NetMbps:0.0} Mbps",
            $"丢帧　{_st.DroppedFrames}",
            $"显卡　{Native.Native.GpuName}",
        });
    }

    void Record()
    {
        if (_st.Position <= 0) return;
        PlaybackHistory.Shared.Record(_req.Path, _req.Name, _req.Title, _st.Position, _st.Duration, _req.SeriesPath);
    }

    // ── 操作 ──
    void TogglePlay()
    {
        if (_player == IntPtr.Zero) return;
        Native.Native.cv_player_get_state(_player, out _st);
        if (_st.Paused != 0 || _st.Ended != 0) Native.Native.cv_player_play(_player);
        else Native.Native.cv_player_pause(_player);
        Poke();
        Update();
    }

    void Seek(double pos)
    {
        if (_player == IntPtr.Zero) return;
        Native.Native.cv_player_seek(_player, Math.Max(0, pos), 1);
        _endedHandled = false;
        Poke();
    }

    void Skip(double d)
    {
        if (_player == IntPtr.Zero) return;
        Native.Native.cv_player_get_state(_player, out _st);
        Seek(_st.Position + d);
    }

    void SetVolume(float v)
    {
        v = Math.Clamp(v, 0, 1);
        if (_player != IntPtr.Zero) Native.Native.cv_player_set_volume(_player, v);
        Settings.Shared.Volume = v;
        _updating = true;
        _volume.Value = v * 100;
        _updating = false;
    }

    void ToggleFullScreen() => MainWindow.Current.SetFullScreen(!MainWindow.Current.IsFullScreen);

    void ToggleInfo()
    {
        _infoBox.Visibility = _infoBox.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        _info.Text = InfoText();
    }

    void Poke()
    {
        ShowChrome(true);
        _idle.Stop();
        _idle.Start();
    }

    void ShowChrome(bool on)
    {
        if (on == _chromeShown) return;
        _chromeShown = on;
        _chrome.Opacity = on ? 1 : 0;
        _chrome.IsHitTestVisible = on;
        Win32.HideCursor(!on);
    }

    void OnKey(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Space:
            case VirtualKey.K: TogglePlay(); break;
            case VirtualKey.Left: Skip(-10); break;
            case VirtualKey.Right: Skip(10); break;
            case VirtualKey.Up: SetVolume((float)Settings.Shared.Volume + 0.05f); Poke(); break;
            case VirtualKey.Down: SetVolume((float)Settings.Shared.Volume - 0.05f); Poke(); break;
            case VirtualKey.F: ToggleFullScreen(); break;
            case VirtualKey.M:
                if (Settings.Shared.Volume > 0) { _volBeforeMute = (float)Settings.Shared.Volume; SetVolume(0); } else SetVolume(_volBeforeMute);
                Poke();
                break;
            case VirtualKey.I: ToggleInfo(); break;
            case VirtualKey.N: NextEpisode(); break;
            case VirtualKey.C: CycleSubtitle(); break;
            case VirtualKey.Escape:
                if (MainWindow.Current.IsFullScreen) MainWindow.Current.SetFullScreen(false);
                else Exit();
                break;
            default: return;
        }
        e.Handled = true;
    }

    void Ended()
    {
        if (_endedHandled) return;
        _endedHandled = true;
        PlaybackHistory.Shared.Record(_req.Path, _req.Name, _req.Title, _st.Duration, _st.Duration, _req.SeriesPath);
        if (_req.Episodes is { } eps && _req.EpisodeIndex + 1 < eps.Count) NextEpisode();
        else ShowChrome(true);
    }

    void NextEpisode()
    {
        if (_req.Episodes is not { } eps || _req.EpisodeIndex + 1 >= eps.Count) return;
        var s = LibraryStore.Shared.Series.FirstOrDefault(x => x.Path == _req.SeriesPath);
        if (s is null) return;
        Record();
        PlayRequest.Episode(s, _req.SeriesTitle ?? _req.Title, eps, _req.EpisodeIndex + 1);
    }

    // ── 音轨 / 字幕 ──
    unsafe List<CvTrack> Tracks()
    {
        var list = new List<CvTrack>();
        if (_player == IntPtr.Zero) return list;
        var buf = stackalloc CvTrack[64];
        int n = Native.Native.cv_player_tracks(_player, buf, 64);
        for (int i = 0; i < Math.Min(n, 64); i++) list.Add(buf[i]);
        return list;
    }

    static string Lang(string code) => code.ToLowerInvariant() switch
    {
        "chi" or "zho" or "zh" or "chn" or "cmn" => "中文",
        "yue" => "粤语",
        "eng" or "en" => "英语",
        "jpn" or "ja" => "日语",
        "kor" or "ko" => "韩语",
        "fre" or "fra" or "fr" => "法语",
        "ger" or "deu" or "de" => "德语",
        "spa" or "es" => "西班牙语",
        "ita" or "it" => "意大利语",
        "rus" or "ru" => "俄语",
        "tha" or "th" => "泰语",
        "" or "und" => "",
        var x => x,
    };

    static string TrackName(CvTrack t)
    {
        var parts = new List<string>();
        var l = Lang(t.LangStr);
        if (l.Length > 0) parts.Add(l);
        if (t.TitleStr.Length > 0) parts.Add(t.TitleStr);
        var codec = t.CodecStr.ToUpperInvariant() switch { "HDMV_PGS_SUBTITLE" => "PGS", "SUBRIP" => "SRT", "TRUEHD" => "TrueHD", "EAC3" => "E-AC-3", var c => c };
        if (t.Type == Native.Native.TrackAudio && t.Channels > 0) codec += t.Channels switch { 8 => " 7.1", 6 => " 5.1", 2 => " 立体声", 1 => " 单声道", var n => $" {n} 声道" };
        parts.Add(codec);
        return string.Join(" · ", parts);
    }

    void BuildMenus()
    {
        var tracks = Tracks();
        var audio = new MenuFlyout();
        foreach (var t in tracks.Where(t => t.Type == Native.Native.TrackAudio))
        {
            var id = t.Id;
            var it = new ToggleMenuFlyoutItem { Text = TrackName(t), IsChecked = t.Selected != 0 };
            it.Click += (_, _) => Native.Native.cv_player_select(_player, Native.Native.TrackAudio, id);
            audio.Items.Add(it);
        }
        if (audio.Items.Count == 0) audio.Items.Add(new MenuFlyoutItem { Text = "没有音轨", IsEnabled = false });
        _audioBtn.Flyout = audio;

        var subs = new MenuFlyout();
        var off = new ToggleMenuFlyoutItem { Text = "关闭字幕", IsChecked = !tracks.Any(t => t.Type == Native.Native.TrackSub && t.Selected != 0) };
        off.Click += (_, _) => Native.Native.cv_player_select(_player, Native.Native.TrackSub, -1);
        subs.Items.Add(off);
        subs.Items.Add(new MenuFlyoutSeparator());
        foreach (var t in tracks.Where(t => t.Type == Native.Native.TrackSub && t.Id >= 0))
        {
            var id = t.Id;
            var it = new ToggleMenuFlyoutItem { Text = TrackName(t), IsChecked = t.Selected != 0 };
            it.Click += (_, _) => Native.Native.cv_player_select(_player, Native.Native.TrackSub, id);
            subs.Items.Add(it);
        }
        var extSelected = tracks.Any(t => t.Id == -2 && t.Selected != 0);
        foreach (var o in _online)
        {
            var sub = o;
            var it = new ToggleMenuFlyoutItem { Text = (o.Online ? "在线 · " : "外挂 · ") + o.Label, IsChecked = extSelected && _onlineLoaded == o.Url };
            it.Click += async (_, _) => await UseExternalAsync(sub);
            subs.Items.Add(it);
        }
        _subBtn.Flyout = subs;
    }

    async Task LoadOnlineSubsAsync()
    {
        _online = await StreamApi.SubsAsync(_req.Path);
        if (_closed) return;
        BuildMenus();
        // 开着字幕、片子里又没有中文字幕：自动用在线 / 外挂的中文
        if (!Settings.Shared.SubtitlesOn) return;
        await Task.Delay(1500);
        if (_closed) return;
        var tracks = Tracks();
        bool zhEmbedded = tracks.Any(t => t.Type == Native.Native.TrackSub && t.Selected != 0);
        if (zhEmbedded) return;
        var pick = _online.FirstOrDefault(o => o.Lang?.StartsWith("zh") == true) ?? _online.FirstOrDefault();
        if (pick is not null) await UseExternalAsync(pick);
    }

    async Task UseExternalAsync(SubTrack t)
    {
        var text = await StreamApi.SubTextAsync(t);
        if (_closed || text is null || _player == IntPtr.Zero) return;
        var cues = SubtitleParser.Parse(text);
        SetExternal(cues, t.Label);
        _onlineLoaded = t.Url;
        BuildMenus();
    }

    unsafe void SetExternal(List<Cue> cues, string label)
    {
        int n = cues.Count;
        var starts = new double[n];
        var ends = new double[n];
        var texts = new IntPtr[n];
        try
        {
            for (int i = 0; i < n; i++)
            {
                starts[i] = cues[i].Start;
                ends[i] = cues[i].End;
                texts[i] = Marshal.StringToCoTaskMemUTF8(cues[i].Text);
            }
            fixed (double* s = starts)
            fixed (double* e = ends)
            fixed (IntPtr* t = texts)
                Native.Native.cv_player_set_ext_subs(_player, s, e, t, n, label);
            Native.Native.cv_player_select(_player, Native.Native.TrackSub, -2);
        }
        finally
        {
            foreach (var p in texts) if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p);
        }
    }

    void CycleSubtitle()
    {
        var subs = Tracks().Where(t => t.Type == Native.Native.TrackSub).ToList();
        if (subs.Count == 0) return;
        var cur = subs.FindIndex(t => t.Selected != 0);
        var next = cur + 1 >= subs.Count ? -1 : subs[cur + 1].Id;
        Native.Native.cv_player_select(_player, Native.Native.TrackSub, next);
        Poke();
    }

    void Exit() => MainWindow.Current.ClosePlayer();

    public void Close()
    {
        if (_closed) return;
        _closed = true;
        _tick.Stop();
        _idle.Stop();
        Win32.HideCursor(false);
        Win32.KeepAwake(false);
        if (_player != IntPtr.Zero)
        {
            Native.Native.cv_player_get_state(_player, out _st);
            Record();
            PlaybackHistory.Shared.Save();
            Native.Native.cv_player_destroy(_player);
            _player = IntPtr.Zero;
        }
        if (_self.IsAllocated) _self.Free();
        _surface.Dispose();
        Settings.Shared.Save();
    }
}
