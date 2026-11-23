using Cuven.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Cuven.App.UI;

/// <summary>
/// 详情页：大图 + 字标 / 片名 + 一行信息 + 规格徽标 + 按钮（播放 / 继续播放 / 下载 / 版本）+ 简介 + 演职人员 + 剧照；
/// 剧集多一块「分集」；片库里没有的是「请求添加」和五步进度
/// </summary>
public sealed partial class DetailView : View
{
    readonly ScrollViewer _scroll = new() { HorizontalScrollMode = ScrollMode.Disabled };
    readonly StackPanel _col = new() { Spacing = 10, Padding = new Thickness(0, 0, 0, 48) };
    readonly Grid _hero = new() { MinHeight = 520 };
    readonly StackPanel _info = new() { Spacing = 14, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(48, 120, 48, 28), MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
    readonly StackPanel _actions = new() { Orientation = Orientation.Horizontal, Spacing = 12 };
    readonly StackPanel _extra = new() { Spacing = 10 };
    Movie? _movie;
    Series? _series;
    CatalogTitle? _catalog;
    Meta? _meta;
    Button? _dlBtn;
    Action? _unsub;

    DetailView()
    {
        _hero.Children.Add(_info);
        _col.Children.Add(_hero);
        _col.Children.Add(_extra);
        _scroll.Content = _col;
        Children.Add(_scroll);
    }

    public override void Closed() => _unsub?.Invoke();
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
        // 大图
        while (_hero.Children.Count > 1) _hero.Children.RemoveAt(0);
        var bg = TmdbImage.Url(m?.Backdrop ?? m?.BackdropClean ?? _movie?.Meta.Backdrop, "original");
        _hero.Children.Insert(0, new Border { Background = U.Fade(0.15, 1.0) });
        _hero.Children.Insert(0, new Border { Background = U.Fade(0.9, 0, null, true), Width = 900, HorizontalAlignment = HorizontalAlignment.Left });
        _hero.Children.Insert(0, U.Img(bg, 1920).With(i => i.VerticalAlignment = VerticalAlignment.Top));

        _info.Children.Clear();
        if (!string.IsNullOrEmpty(m?.Logo))
            _info.Children.Add(new Image { Source = U.Bitmap(TmdbImage.Url(m.Logo, "w500"), 500), MaxHeight = 130, MaxWidth = 480, HorizontalAlignment = HorizontalAlignment.Left, Stretch = Stretch.Uniform });
        else
            _info.Children.Add(U.T(TitleText, 40, FontWeights.Bold, null, 2));
        var bits = new List<string?>();
        if (_series is not null) bits.Add(_series.SeasonLabel ?? (_series.Season is { } sn ? $"第 {sn} 季" : null));
        bits.Add(m?.Year ?? _movie?.Year ?? _series?.Year ?? _catalog?.Year);
        bits.Add(Format.Runtime(m?.Runtime));
        if (m?.Rating is > 0) bits.Add($"评分 {m.Rating:0.0}");
        if (m?.Genres is { Count: > 0 } gs) bits.Add(string.Join(" / ", gs.Take(3)));
        _info.Children.Add(U.T(string.Join(" · ", bits.Where(b => !string.IsNullOrEmpty(b))), 14, null, U.Dim));
        var specs = _movie is not null ? FileName.Specs(_movie.Video.Name) : _series is not null ? (_series.Tags ?? new List<string>()) : new List<string>();
        if (specs.Count > 0)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            foreach (var s in specs.Take(6)) row.Children.Add(U.Pill(s));
            _info.Children.Add(row);
        }
        _info.Children.Add(_actions);
        if (!string.IsNullOrEmpty(m?.Overview))
        {
            var ov = U.T(m.Overview!, 15, null, U.Dim, 4);
            ov.Tapped += (_, _) => ov.MaxLines = ov.MaxLines == 0 ? 4 : 0;
            _info.Children.Add(ov);
        }
        if (!string.IsNullOrEmpty(m?.Director)) _info.Children.Add(U.T("导演　" + m.Director, 13, null, U.Faint));
        RebuildActions();
        RenderExtra();
    }

    void RebuildActions()
    {
        _actions.Children.Clear();
        if (_movie is not null)
        {
            var path = _movie.Versions.FirstOrDefault()?.Path ?? _movie.Video.Path;
            var resume = PlaybackHistory.Shared.ResumeAt(path);
            _actions.Children.Add(U.Btn(resume > 0 ? $"继续播放 {Format.Clock(resume)}" : "播放", "", (_, _) => PlayRequest.Movie(_movie), accent: true));
            if (resume > 0)
                _actions.Children.Add(U.Btn("从头播放", "", (_, _) =>
                {
                    PlaybackHistory.Shared.Record(path, _movie.Video.Name, _movie.Title, 0, 0);
                    PlayRequest.Movie(_movie);
                }));
            _dlBtn = U.Btn("下载", "", (_, _) => DownloadClicked());
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
                var vb = U.Btn($"{_movie.Versions.Count} 个版本", "", (_, _) => { });
                vb.Flyout = menu;
                _actions.Children.Add(vb);
            }
        }
        else if (_series is not null)
        {
            if (_episodes.Count > 0)
            {
                var (idx, label) = NextUp();
                _actions.Children.Add(U.Btn(label, "", (_, _) => PlayRequest.Episode(_series, TitleText, _episodes, idx, EpName(idx)), accent: true));
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
                _actions.Children.Add(U.Btn("选季", "", (_, _) => { }).With(b => b.Flyout = menu));
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
        if (it is null) { text = "下载" + (v.Size is > 0 ? "（" + Format.Size(v.Size) + "）" : ""); glyph = ""; }
        else switch (it.Phase)
        {
            case DownloadPhase.Done: text = "已下载"; glyph = ""; break;
            case DownloadPhase.Downloading: text = $"下载中 {it.Progress:P0}"; glyph = ""; break;
            case DownloadPhase.Queued: text = "排队中"; glyph = ""; break;
            case DownloadPhase.NoSpace: text = "空间不足"; glyph = ""; break;
            case DownloadPhase.Failed: text = "重试下载"; glyph = ""; break;
            default: text = $"继续下载 {it.Progress:P0}"; glyph = ""; break;
        }
        _dlBtn.Content = U.H(8, U.Icon(glyph, 15), U.T(text, 14, FontWeights.SemiBold));
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
            _actions.Children.Add(U.T("暂时没有可以请求的资源", 14, null, U.Dim).With(t => t.VerticalAlignment = VerticalAlignment.Center));
            return;
        }
        var btn = U.Btn(req is { State: RequestState.Failed } ? "重新请求添加" : "请求添加", "", async (s, _) =>
        {
            if (s is Button b) b.IsEnabled = false;
            try
            {
                var r = await RequestCenter.Shared.CreateAsync(_catalog, season);
                RequestCenter.Shared.Note(r);
                RebuildActions();
            }
            catch (Exception e)
            {
                U.Toast(XamlRoot, "没能请求添加", CuvenException.Friendly(e));
                if (s is Button b2) b2.IsEnabled = true;
            }
        }, accent: true);
        _actions.Children.Add(btn);
        if (d?.Best is { } best)
        {
            var spec = string.Join(" · ", new[] { best.Res }.Concat(best.Labels ?? new List<string>()).Append(best.Size).Where(x => !string.IsNullOrEmpty(x)));
            if (spec.Length > 0) _actions.Children.Add(U.T(spec, 13, null, U.Faint).With(t => t.VerticalAlignment = VerticalAlignment.Center));
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
        foreach (var l in RequestStatus.Labels) labels.Children.Add(U.T(l, 11, null, U.Faint).With(t => { t.Width = 76; t.TextAlignment = TextAlignment.Center; }));
        col.Children.Add(labels);
        if (r.Note.Length > 0) col.Children.Add(U.T(r.Note, 12, null, U.Dim, 2));
        return new Border { Background = U.CardBrush, CornerRadius = new CornerRadius(12), Padding = new Thickness(16, 12, 16, 12), Child = col };
    }

    // ── 下面：分集、演职人员、剧照、文件 ──
    void RenderExtra()
    {
        _extra.Children.Clear();
        if (_series is not null) RenderEpisodes();
        var cast = _meta?.Cast;
        if (cast is { Count: > 0 })
        {
            Section("演职人员");
            var row = new StackPanel { Spacing = 18 };
            foreach (var c in cast.Take(20))
            {
                var pic = new PersonPicture { Width = 88, Height = 88, DisplayName = c.Name };
                if (U.Bitmap(c.ProfileUrl, 176) is { } b) pic.ProfilePicture = b;
                row.Children.Add(U.V(4, pic, U.T(c.Name, 13, FontWeights.SemiBold).With(t => { t.MaxWidth = 100; t.TextAlignment = TextAlignment.Center; }),
                    U.T(c.Character ?? "", 12, null, U.Faint).With(t => { t.MaxWidth = 100; t.TextAlignment = TextAlignment.Center; })).With(s => s.Width = 100));
            }
            _extra.Children.Add(U.Shelf(row));
        }
        var stills = _meta?.Stills;
        if (stills is { Count: > 0 })
        {
            Section("剧照");
            var row = new StackPanel { Spacing = 14 };
            foreach (var s in stills.Take(12))
                row.Children.Add(U.RoundImg(TmdbImage.Url(s.Thumb ?? s.Url, "w780"), 640, 10).With(b => { b.Width = 320; b.Height = 180; }));
            _extra.Children.Add(U.Shelf(row));
        }
        if (_movie is not null)
        {
            Section("文件");
            foreach (var v in _movie.Versions)
                _extra.Children.Add(U.T($"{v.Name}　{Format.Size(v.Size)}", 13, null, U.Faint, 2).With(t => t.Margin = new Thickness(48, 0, 48, 0)));
        }
    }

    void Section(string title) =>
        _extra.Children.Add(U.T(title, 20, FontWeights.SemiBold).With(t => t.Margin = new Thickness(48, 20, 48, 4)));

    void RenderEpisodes()
    {
        if (_series is null) return;
        Section($"分集（{_episodes.Count}" + (_series.Total is { } tot && tot > _episodes.Count ? $" / {tot}" : "") + "）");
        if (_episodes.Count == 0) { _extra.Children.Add(new ProgressRing { IsActive = true, Margin = new Thickness(48, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left }); return; }
        var list = new StackPanel { Spacing = 10, Margin = new Thickness(48, 0, 48, 0) };
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
                U.T(string.Join(" · ", new[] { Format.Runtime(info?.Runtime), info?.AirDate, Format.Size(e.Size) }.Where(x => !string.IsNullOrEmpty(x))), 12, null, U.Faint),
                string.IsNullOrEmpty(info?.Overview) ? null : U.T(info!.Overview!, 13, null, U.Dim, 3));
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
