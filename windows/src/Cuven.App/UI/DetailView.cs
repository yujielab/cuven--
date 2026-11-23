using Cuven.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Cuven.App.UI;

/// <summary>
/// 详情页（照网页版）：整幅剧照铺满一屏，正中间字标、「导演 · 主演」、8 分以上一枚「Cuven 品质保证」、白色「立即播放」+ 磨砂圆钮、简介；
/// 下面演员阵容（圆头像）、剧照（竖的大卡「第 N 幕」）、剧集的分集；影片信息（类型 / 格式 / 评分）、尖端色彩和画面质量技术、语言、版权一行。
/// 片库里没有的是「请求添加」和五步进度
/// </summary>
public sealed partial class DetailView : View
{
    readonly ScrollViewer _scroll = new() { HorizontalScrollMode = ScrollMode.Disabled };
    readonly StackPanel _col = new() { Spacing = 0, Padding = new Thickness(0, 0, 0, 120) };
    readonly Grid _hero = new();
    readonly StackPanel _info = new() { Spacing = 16, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 760, Margin = new Thickness(40, 0, 40, 118) };
    readonly StackPanel _actions = new() { Orientation = Orientation.Horizontal, Spacing = 14, HorizontalAlignment = HorizontalAlignment.Center };
    readonly StackPanel _extra = new() { Spacing = 0 };
    Movie? _movie;
    Series? _series;
    CatalogTitle? _catalog;
    Meta? _meta;
    MacButton? _dlBtn;
    Action? _unsub;

    DetailView()
    {
        Background = Mac.CanvasBrush;
        _hero.Children.Add(_info);
        _col.Children.Add(_hero);
        _col.Children.Add(_extra);
        _scroll.Content = _col;
        Children.Add(_scroll);
        SizeChanged += (_, e) => _hero.Height = Math.Max(560, e.NewSize.Height * 0.92);
    }

    public override void Closed() => _unsub?.Invoke();

    /// <summary>滚到大图下面（自检截图用）</summary>
    public void ScrollToInfo() => _scroll.ChangeView(null, Math.Max(0, _hero.ActualHeight - 120), null, true);
    public override void Refresh() => RebuildActions();

    // ── 电影 ──
    public static DetailView ForMovie(Movie m)
    {
        var v = new DetailView { _movie = m, _meta = m.Meta };
        v.Render();
        _ = v.LoadMovieAsync();
        void onDl(DownloadItem it) { if (m.Versions.Any(x => x.Path == it.Path)) v.DispatcherQueue.TryEnqueue(v.UpdateDownload); }
        DownloadManager.Shared.Updated += onDl;
        v._unsub = () => DownloadManager.Shared.Updated -= onDl;
        return v;
    }

    async Task LoadMovieAsync()
    {
        if (_movie is null) return;
        _ = StreamApi.SubsAsync(_movie.Video.Path, warm: true);
        var full = await LibraryStore.Shared.FullMetaAsync(_movie);
        if (full is not null) { _meta = full; Render(); }
    }

    // ── 剧集 ──
    public static DetailView ForSeries(Series s)
    {
        var v = new DetailView { _series = s, _meta = LibraryStore.Shared.SeriesMeta(s) };
        v.Render();
        _ = v.LoadSeriesAsync();
        return v;
    }

    List<EpisodeFile> _episodes = new();
    List<SeasonEpisode> _seasonInfo = new();

    async Task LoadSeriesAsync()
    {
        if (_series is null) return;
        _meta ??= await LibraryStore.Shared.EnsureSeriesMetaAsync(_series);
        Render();
        try { _episodes = await StreamApi.EpisodesAsync(_series.Path); } catch { _episodes = new(); }
        var id = _series.TmdbId ?? _meta?.Id;
        if (id is { } tid && _series.Season is { } sn)
            try { _seasonInfo = await StreamApi.SeasonAsync(tid, sn); } catch { }
        Render();
    }

    // ── 片库里没有的 ──
    public static DetailView ForCatalog(CatalogTitle t)
    {
        var v = new DetailView { _catalog = t };
        v.Render();
        _ = v.LoadCatalogAsync();
        void onReq() => v.DispatcherQueue.TryEnqueue(v.RebuildActions);
        RequestCenter.Shared.Changed += onReq;
        v._unsub = () => RequestCenter.Shared.Changed -= onReq;
        return v;
    }

    CatalogDetail? _detail;
    int _season;

    async Task LoadCatalogAsync()
    {
        if (_catalog is null) return;
        try
        {
            _meta = await StreamApi.TmdbAsync(_catalog.Title, _catalog.Year, _catalog.Kind == CatalogKind.Tv ? "tv" : "movie", _catalog.Id, full: true);
        }
        catch { }
        Render();
        try
        {
            _detail = await RequestApi.DetailAsync(_catalog, null);
            _season = _detail.Season > 0 ? _detail.Season : _detail.Seasons.LastOrDefault();
            RequestCenter.Shared.Note(_detail.Req);
            foreach (var r in _detail.Reqs.Values) RequestCenter.Shared.Note(r);
        }
        catch { }
        RebuildActions();
    }

    // ── 画 ──
    string TitleText => _meta?.Title ?? _movie?.Title ?? _series?.Name ?? _catalog?.Title ?? "";

    void Render()
    {
        var m = _meta;
        // 整幅剧照，下面渐黑接到页面
        while (_hero.Children.Count > 1) _hero.Children.RemoveAt(0);
        var bg = TmdbImage.Url(m?.Backdrop ?? m?.BackdropClean ?? _movie?.Meta.Backdrop, "original");
        _hero.Children.Insert(0, new Border { Background = U.Fade(0, 1.0, Mac.Canvas), Height = 460, VerticalAlignment = VerticalAlignment.Bottom });
        _hero.Children.Insert(0, U.Img(bg, 1920));

        _info.Children.Clear();
        var w = ActualWidth > 0 ? ActualWidth : 1280;
        _info.Children.Add(FeatureBlock.LogoOrTitle(m?.Logo, TitleText, Math.Clamp(w * 0.1, 80, 140), Math.Clamp(w * 0.34, 280, 520)));
        if (_series is not null)
        {
            var bits = new[] { _series.SeasonLabel ?? (_series.Season is { } sn ? $"第 {sn} 季" : null), m?.Year ?? _series.Year }.Where(b => !string.IsNullOrEmpty(b));
            _info.Children.Add(Center(U.T(string.Join(" · ", bits), 14, FontWeights.SemiBold, Mac.Secondary)));
        }
        // 导演 / 主创 · 主演（前三位）
        var credits = new List<string>();
        if (!string.IsNullOrEmpty(m?.Director)) credits.Add("导演 " + m.Director);
        if (m?.Cast is { Count: > 0 } cs) credits.Add("主演 " + string.Join(" · ", cs.Take(3).Select(c => c.Name)));
        if (credits.Count > 0) _info.Children.Add(Center(U.T(string.Join("　·　", credits), 13, null, Mac.Tertiary)));
        if (m?.Rating >= 8.0) _info.Children.Add(Web.Chip("Cuven 品质保证", 12).With(c => c.HorizontalAlignment = HorizontalAlignment.Center));
        _info.Children.Add(_actions);
        if (!string.IsNullOrEmpty(m?.Overview))
        {
            var ov = U.T(m.Overview!, 15, null, Mac.Secondary, 3);
            ov.TextAlignment = TextAlignment.Center;
            ov.HorizontalAlignment = HorizontalAlignment.Center;
            ov.Tapped += (_, _) => ov.MaxLines = ov.MaxLines == 0 ? 3 : 0;
            _info.Children.Add(ov);
        }
        RebuildActions();
        RenderExtra();
    }

    static FrameworkElement Center(TextBlock t) { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; return t; }

    void RebuildActions()
    {
        _actions.Children.Clear();
        if (_movie is not null)
        {
            var path = _movie.Versions.FirstOrDefault()?.Path ?? _movie.Video.Path;
            var resume = PlaybackHistory.Shared.ResumeAt(path);
            _actions.Children.Add(MacButton.Pill(resume > 0 ? $"继续播放 {Format.Clock(resume)}" : "立即播放", "\uE768", () => PlayRequest.Movie(_movie), MacButton.Style.Primary, 50).With(b => b.MinWidth = 184));
            if (resume > 0)
                _actions.Children.Add(MacButton.Round("\uE72C", () =>
                {
                    PlaybackHistory.Shared.Record(path, _movie.Video.Name, _movie.Title, 0, 0);
                    PlayRequest.Movie(_movie);
                }, "从头播放", 50, 17));
            _dlBtn = MacButton.Round("\uE896", DownloadClicked, "下载", 50, 17);
            _actions.Children.Add(_dlBtn);
            UpdateDownload();
            if (_movie.Versions.Count > 1)
            {
                var menu = new MenuFlyout();
                foreach (var ver in _movie.Versions)
                {
                    var vv = ver;
                    var label = string.Join(" · ", FileName.Specs(ver.Name).DefaultIfEmpty("版本")) + "　" + Format.Size(ver.Size);
                    var it = new MenuFlyoutItem { Text = label };
                    it.Click += (_, _) => PlayRequest.Movie(_movie, vv);
                    menu.Items.Add(it);
                }
                var vb = MacButton.Round("\uE8FD", () => { }, $"{_movie.Versions.Count} 个版本", 50, 17);
                vb.Menu = menu;
                _actions.Children.Add(vb);
            }
        }
        else if (_series is not null)
        {
            if (_episodes.Count > 0)
            {
                var (idx, label) = NextUp();
                _actions.Children.Add(MacButton.Pill(label, "\uE768", () => PlayRequest.Episode(_series, TitleText, _episodes, idx, EpName(idx)), MacButton.Style.Primary, 50).With(b => b.MinWidth = 184));
            }
            else _actions.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24 });
            // 同一部剧的其他季
            var others = LibraryStore.Shared.Series.Where(s => s != _series && (s.TmdbId is not null && s.TmdbId == _series.TmdbId)).OrderBy(s => s.Season).ToList();
            if (others.Count > 0)
            {
                var menu = new MenuFlyout();
                foreach (var o in others.Prepend(_series).OrderBy(s => s.Season))
                {
                    var oo = o;
                    var it = new ToggleMenuFlyoutItem { Text = o.SeasonLabel ?? $"第 {o.Season} 季", IsChecked = o == _series };
                    it.Click += (_, _) => { if (oo != _series) Shell.Current?.Go(ForSeries(oo)); };
                    menu.Items.Add(it);
                }
                _actions.Children.Add(MacButton.Round("\uE8FD", () => { }, "选季", 50, 17).With(b => b.Menu = menu));
            }
        }
        else if (_catalog is not null)
        {
            BuildRequestActions();
        }
    }

    (int, string) NextUp()
    {
        // 接着看：最近看过的那一集（没看完就接着，看完了下一集）
        int best = 0;
        DateTime t = DateTime.MinValue;
        for (int i = 0; i < _episodes.Count; i++)
        {
            var e = PlaybackHistory.Shared.Get(_episodes[i].Path);
            if (e is null || e.Updated <= t) continue;
            t = e.Updated;
            best = e.Duration > 0 && e.Position / e.Duration > 0.95 ? Math.Min(i + 1, _episodes.Count - 1) : i;
        }
        var ep = _episodes[best].Ep ?? best + 1;
        var resume = PlaybackHistory.Shared.ResumeAt(_episodes[best].Path);
        return (best, t == DateTime.MinValue ? "播放第 1 集" : resume > 0 ? $"继续第 {ep} 集" : $"播放第 {ep} 集");
    }

    string? EpName(int i)
    {
        if (i < 0 || i >= _episodes.Count) return null;
        var ep = _episodes[i].Ep;
        return _seasonInfo.FirstOrDefault(s => s.Ep == ep)?.Name;
    }

    // ── 下载 ──
    void DownloadClicked()
    {
        if (_movie is null) return;
        var v = _movie.Versions.FirstOrDefault() ?? _movie.Video;
        var it = DownloadManager.Shared.Find(v.Path);
        if (it is null) DownloadManager.Shared.Enqueue(v.Path, v.Name, _movie.Title, _movie.PosterUrl("w342"), v.Size);
        else if (it.Phase is DownloadPhase.Downloading or DownloadPhase.Queued) DownloadManager.Shared.Pause(v.Path);
        else if (it.Phase == DownloadPhase.Done) Shell.Current?.Root("downloads");
        else DownloadManager.Shared.Resume(v.Path);
        UpdateDownload();
    }

    void UpdateDownload()
    {
        if (_movie is null || _dlBtn is null) return;
        var v = _movie.Versions.FirstOrDefault() ?? _movie.Video;
        var it = DownloadManager.Shared.Find(v.Path);
        string text, glyph;
        if (it is null) { text = "下载" + (v.Size is > 0 ? "（" + Format.Size(v.Size) + "）" : ""); glyph = "\uE896"; }
        else switch (it.Phase)
        {
            case DownloadPhase.Done: text = "已下载"; glyph = "\uE73E"; break;
            case DownloadPhase.Downloading: text = $"下载中 {it.Progress:P0}（点一下暂停）"; glyph = "\uE769"; break;
            case DownloadPhase.Queued: text = "排队中"; glyph = "\uE769"; break;
            case DownloadPhase.NoSpace: text = "空间不足"; glyph = "\uE7BA"; break;
            case DownloadPhase.Failed: text = "重试下载"; glyph = "\uE72C"; break;
            default: text = $"继续下载 {it.Progress:P0}"; glyph = "\uE896"; break;
        }
        _dlBtn.SetContent(U.Icon(glyph, 17).With(i => { i.HorizontalAlignment = HorizontalAlignment.Center; i.VerticalAlignment = VerticalAlignment.Center; }));
        ToolTipService.SetToolTip(_dlBtn, text);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_dlBtn, text);
    }

    // ── 请求添加 ──
    void BuildRequestActions()
    {
        if (_catalog is null) return;
        var d = _detail;
        int season = _catalog.Kind == CatalogKind.Tv ? _season : 0;
        var req = RequestCenter.Shared.Status(_catalog.Src, _catalog.Id, season) ?? (d?.Reqs.GetValueOrDefault(season.ToString())) ?? d?.Req;
        if (_catalog.Kind == CatalogKind.Tv && d is { Seasons.Count: > 1 })
        {
            var cb = new ComboBox { MinWidth = 120 };
            foreach (var s in d.Seasons) cb.Items.Add($"第 {s} 季");
            cb.SelectedIndex = Math.Max(0, d.Seasons.IndexOf(_season));
            cb.SelectionChanged += (_, _) => { if (cb.SelectedIndex >= 0) { _season = d.Seasons[cb.SelectedIndex]; RebuildActions(); } };
            _actions.Children.Add(cb);
        }
        if (req is { State: RequestState.Active } || req is { State: RequestState.Done })
        {
            _actions.Children.Add(StepsCard(req));
            return;
        }
        if (d is not null && d.Known == 0 && d.Count == 0)
        {
            _actions.Children.Add(U.T("暂时没有可以请求的资源", 14, null, Mac.Secondary).With(t => t.VerticalAlignment = VerticalAlignment.Center));
            return;
        }
        MacButton? btn = null;
        btn = MacButton.Pill(req is { State: RequestState.Failed } ? "重新请求添加" : "请求添加", "\uE710", async () =>
        {
            if (btn is not null) { btn.IsHitTestVisible = false; btn.Opacity = 0.6; }
            try
            {
                var r = await RequestCenter.Shared.CreateAsync(_catalog, season);
                RequestCenter.Shared.Note(r);
                RebuildActions();
            }
            catch (Exception e)
            {
                U.Toast(XamlRoot, "没能请求添加", CuvenException.Friendly(e));
                if (btn is not null) { btn.IsHitTestVisible = true; btn.Opacity = 1; }
            }
        }, MacButton.Style.Primary, 50);
        btn.MinWidth = 184;
        _actions.Children.Add(btn);
        if (d?.Best is { } best)
        {
            var spec = string.Join(" · ", new[] { best.Res }.Concat(best.Labels ?? new List<string>()).Append(best.Size).Where(x => !string.IsNullOrEmpty(x)));
            if (spec.Length > 0) _actions.Children.Add(U.T(spec, 13, null, Mac.Tertiary).With(t => t.VerticalAlignment = VerticalAlignment.Center));
        }
    }

    static UIElement StepsCard(RequestStatus r)
    {
        var col = new StackPanel { Spacing = 8, MinWidth = 420 };
        col.Children.Add(U.T(r.State == RequestState.Done ? "已就绪，片库刷新后就能播放" : r.Headline, 15, FontWeights.SemiBold));
        var steps = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        for (int i = 1; i <= 5; i++)
        {
            bool done = r.State == RequestState.Done || i < r.Step, cur = r.State == RequestState.Active && i == r.Step;
            steps.Children.Add(new Border
            {
                Width = 76, Height = 6, CornerRadius = new CornerRadius(3),
                Background = done ? U.AccentBrush : cur ? new SolidColorBrush(U.AccentDim) : U.CardHover,
            });
        }
        col.Children.Add(steps);
        var labels = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var l in RequestStatus.Labels) labels.Children.Add(U.T(l, 11, null, Mac.Tertiary).With(t => { t.Width = 76; t.TextAlignment = TextAlignment.Center; }));
        col.Children.Add(labels);
        if (r.Note.Length > 0) col.Children.Add(U.T(r.Note, 12, null, Mac.Secondary, 2));
        return new Glass(14, GlassKind.Regular) { Content = new Border { Padding = new Thickness(16, 12, 16, 12), Child = col } };
    }

    // ── 下面（照网页版）：分集、演员阵容、剧照、影片信息、技术、语言 ──
    const double Column = 756;

    void RenderExtra()
    {
        _extra.Children.Clear();
        var m = _meta;
        if (_series is not null) RenderEpisodes();
        // 演员阵容：标题在中间那一栏，圆头像一排从页边起
        if (m?.Cast is { Count: > 0 } cast)
        {
            var head = U.Cols("*", "auto");
            head.Children.Add(U.T("演员阵容", 21, FontWeights.Bold).At(0, 0));
            var more = U.H(4, cast.Count > 12 ? U.T($"共 {cast.Count} 位", 13, null, Mac.Tertiary) : null,
                U.T("查看全部", 13, FontWeights.SemiBold, Mac.Secondary), U.Icon("\uE76C", 10).With(i => { i.Foreground = Mac.Secondary; i.VerticalAlignment = VerticalAlignment.Center; }));
            more.VerticalAlignment = VerticalAlignment.Center;
            head.Children.Add(more.At(0, 1));
            _extra.Children.Add(Columned(head, 30, 14));
            var row = new StackPanel();
            foreach (var c in cast.Take(more is null ? 12 : 30))
            {
                var pic = new PersonPicture { Width = 118, Height = 118, DisplayName = c.Name };
                if (U.Bitmap(c.ProfileUrl, 236) is { } b) pic.ProfilePicture = b;
                row.Children.Add(U.V(6, pic, U.T(c.Name, 14, FontWeights.SemiBold).With(t => t.MaxWidth = 124), U.T(c.Character ?? "", 13, null, Mac.Tertiary).With(t => t.MaxWidth = 124)).With(st => st.Width = 124));
            }
            _extra.Children.Add(Web.Row(row, 12));
            _extra.Children.Add(new Border { Height = 1, Background = Mac.Separator, Margin = new Thickness(0, 16, 0, 0) });
        }
        // 剧照：竖的大卡，下面「第 N 幕」
        if (_series is null && m?.Stills is { Count: >= 2 } stills)
        {
            _extra.Children.Add(Inset.Track(U.T("剧照", 19, FontWeights.Bold), (t, l) => t.Margin = new Thickness(l, 30, l, 14)));
            var row = new StackPanel();
            int n = 0;
            foreach (var st in stills.Take(12))
            {
                n++;
                var card = U.RoundImg(TmdbImage.Url(st.Url ?? st.Thumb, "w780"), 760, 20).With(b => { b.Width = 370; b.Height = 458; });
                row.Children.Add(U.V(14, card, U.T($"第 {n} 幕", 15, FontWeights.SemiBold).With(t => t.Margin = new Thickness(4, 0, 0, 0))));
            }
            _extra.Children.Add(Web.Row(row, 22));
        }
        // 影片信息
        var info = new StackPanel { Spacing = 0 };
        info.Children.Add(new Border { Height = 1, Background = Mac.Separator, Margin = new Thickness(0, 0, 0, 26) });
        info.Children.Add(U.T("影片信息", 21, FontWeights.Bold).With(t => t.Margin = new Thickness(0, 0, 0, 12)));
        var type = (m?.Type == "tv" || _series is not null) ? "TV Series" : "Feature Film";
        info.Children.Add(InfoRow("类型", type + " · " + (m?.Genres is { Count: > 0 } g ? string.Join(" · ", g) : "未知类型")));
        if (_series is not null) info.Children.Add(InfoRow("剧集", string.Join(" · ", new[] { _series.SeasonLabel, _series.Total is { } tot ? $"共 {tot} 集" : null }.Where(x => !string.IsNullOrEmpty(x)))));
        var name = _movie?.Video.Name ?? _episodes.FirstOrDefault()?.Name ?? "";
        var specs = _movie is not null ? FileName.Specs(name) : _series?.Tags ?? new List<string>();
        var ext = System.IO.Path.GetExtension(name).TrimStart('.').ToUpperInvariant();
        var fmt = string.Join(" · ", new[] { ext.Length > 0 ? ext : null,
            specs.Contains("4K") || specs.Contains("8K") ? "8K+ UHD" : null,
            specs.Contains("杜比视界") ? "DV" : specs.Any(x => x.StartsWith("HDR")) ? "HDR" : null }.Where(x => x is not null));
        if (fmt.Length > 0) info.Children.Add(InfoRow("格式", fmt));
        if (m?.Rating is > 0 && m.Rating is { } r)
        {
            var val = U.H(8, U.T($"★ {r:0.0}", 14, FontWeights.SemiBold), r >= 8.0 ? Web.Chip("品质保证", 11) : null);
            info.Children.Add(InfoRow("评分", null, val));
        }
        // 尖端色彩和画面质量技术
        info.Children.Add(U.T("尖端色彩和画面质量技术", 14, FontWeights.SemiBold, Mac.Secondary).With(t => t.Margin = new Thickness(0, 34, 0, 12)));
        info.Children.Add(Box(
            Tech("HDR ULTIMATE", "高动态技术 (HDR Ultimate) 绚丽生动的色彩、更锐利的对比度和更丰富的细节，为你呈现精致鲜活的迷人画质。"),
            Tech("DOLBY ATMOS", "声音以前所未有的层次感、清晰度和细节，让你尽享全方位萦绕的声音体验。")));
        // 语言
        info.Children.Add(U.T("语言", 14, FontWeights.SemiBold, Mac.Secondary).With(t => t.Margin = new Thickness(0, 30, 0, 12)));
        var audio = _series?.Langs is { Count: > 0 } langs
            ? string.Join("、", langs) + (_series.Audio is { } au ? "（" + (au == "Atmos" ? "Dolby Atmos" : au) + "）" : "")
            : "English (Dolby Atmos、Dolby Digital 7.1、Dolby 5.1、AAC、AD)";
        info.Children.Add(Box(
            Lang("原始音频", Language(m?.OriginalLanguage) ?? "English"),
            Lang("音频", audio),
            Lang("字幕", "Arabic、Bulgarian、Croatian、Czech、Danish、Dutch、English (SDH)、Estonian、Finnish、Greek、Hebrew、Hungarian、Icelandic、Latvian、Lithuanian、Norwegian、Polish、Portuguese、Slovak、Slovenian、Swedish、Turkish、Ukrainian")));
        info.Children.Add(U.T("有关法律责任和信息 CUVEN 均不受理 适用法务归属为卢森堡地区", 12, null, Mac.Tertiary).With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 40, 0, 0); }));
        _extra.Children.Add(Columned(info, 34, 0));
    }

    /// <summary>中间那一栏（网页版 756 宽，窄了留页边）</summary>
    static FrameworkElement Columned(FrameworkElement e, double top, double bottom)
    {
        e.MaxWidth = Column;
        return Inset.Track(new Grid { Children = { e } }, (g, l) => g.Padding = new Thickness(l, top, l, bottom));
    }

    static FrameworkElement InfoRow(string label, string? value, FrameworkElement? custom = null)
    {
        var g = U.Cols("auto", "*");
        g.Padding = new Thickness(0, 13, 0, 13);
        g.BorderBrush = Mac.Separator;
        g.BorderThickness = new Thickness(0, 0, 0, 1);
        g.Children.Add(U.T(label, 14, null, Mac.Tertiary).At(0, 0));
        var v = custom ?? U.T(value ?? "", 14, FontWeights.SemiBold, null, 2).With(t => t.TextAlignment = TextAlignment.Right);
        v.HorizontalAlignment = HorizontalAlignment.Right;
        v.Margin = new Thickness(24, 0, 0, 0);
        g.Children.Add(v.At(0, 1));
        return g;
    }

    static FrameworkElement Box(params FrameworkElement[] items)
    {
        var col = new StackPanel { Spacing = 0 };
        for (int i = 0; i < items.Length; i++)
        {
            if (i > 0) col.Children.Add(new Border { Height = 1, Background = Mac.Separator, Margin = new Thickness(0, 4, 0, 4) });
            col.Children.Add(items[i]);
        }
        return new Border
        {
            Child = col, Padding = new Thickness(20, 12, 20, 12), CornerRadius = new CornerRadius(22),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 12, 12, 12)),
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(36, 255, 255, 255)), BorderThickness = new Thickness(1),
        };
    }

    static FrameworkElement Tech(string badge, string text) => U.V(10,
        new Border
        {
            HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(5), Padding = new Thickness(8, 3, 8, 3),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(26, 255, 255, 255)),
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(70, 255, 255, 255)), BorderThickness = new Thickness(1),
            Child = U.T(badge, 11, FontWeights.Bold).With(t => t.CharacterSpacing = 60),
        },
        U.T(text, 14, null, Mac.Secondary, 3)).With(st => st.Margin = new Thickness(0, 10, 0, 10));

    static FrameworkElement Lang(string label, string value) =>
        U.V(6, U.T(label, 15, null, Mac.Tertiary), U.T(value, 15, null, null, 4)).With(st => st.Margin = new Thickness(0, 10, 0, 10));

    static string? Language(string? code) => code switch
    {
        null or "" => null,
        "en" => "English", "zh" => "中文", "cn" => "粤语", "ja" => "日本語", "ko" => "한국어", "fr" => "Français", "de" => "Deutsch",
        "es" => "Español", "it" => "Italiano", "ru" => "Русский", "hi" => "हिन्दी", "th" => "ไทย", "pt" => "Português",
        _ => code,
    };

    void Section(string title) =>
        _extra.Children.Add(Inset.Track(U.T(title, 19, FontWeights.Bold), (t, l) => t.Margin = new Thickness(l, 30, l, 12)));

    void RenderEpisodes()
    {
        if (_series is null) return;
        Section($"分集（{_episodes.Count}" + (_series.Total is { } tot && tot > _episodes.Count ? $" / {tot}" : "") + "）");
        if (_episodes.Count == 0) { _extra.Children.Add(Inset.Track(new ProgressRing { IsActive = true, HorizontalAlignment = HorizontalAlignment.Left }, (r, l) => r.Margin = new Thickness(l, 8, 0, 0))); return; }
        var list = Inset.Track(new StackPanel { Spacing = 6 }, (st, l) => st.Margin = new Thickness(l - 10, 0, 48, 0));
        for (int i = 0; i < _episodes.Count; i++)
        {
            int idx = i;
            var e = _episodes[i];
            var info = _seasonInfo.FirstOrDefault(s => s.Ep == e.Ep);
            var h = PlaybackHistory.Shared.Get(e.Path);
            var row = U.Cols("240", "*");
            row.ColumnSpacing = 18;
            row.Padding = new Thickness(10);
            row.CornerRadius = new CornerRadius(12);
            row.Background = U.Transparent;
            var thumb = new Grid { Height = 135 };
            thumb.Children.Add(U.RoundImg(TmdbImage.Url(info?.Still, "w500"), 480, 8));
            if (h is { Duration: > 0 })
                thumb.Children.Add(new ProgressBar { Value = h.Position / h.Duration, Maximum = 1, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(8) });
            row.Children.Add(thumb.At(0, 0));
            var text = U.V(6,
                U.T($"{e.Ep ?? i + 1}. {info?.Name ?? FileName.Title(e.Name)}", 16, FontWeights.SemiBold),
                U.T(string.Join(" · ", new[] { Format.Runtime(info?.Runtime), info?.AirDate, Format.Size(e.Size) }.Where(x => !string.IsNullOrEmpty(x))), 12, null, Mac.Tertiary),
                string.IsNullOrEmpty(info?.Overview) ? null : U.T(info!.Overview!, 13, null, Mac.Secondary, 3));
            text.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(text.At(0, 1));
            row.PointerEntered += (_, _) => row.Background = U.CardBrush;
            row.PointerExited += (_, _) => row.Background = U.Transparent;
            row.Tapped += (_, _) => PlayRequest.Episode(_series, TitleText, _episodes, idx, info?.Name);
            list.Children.Add(row);
        }
        _extra.Children.Add(list);
    }
}
