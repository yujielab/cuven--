import SwiftUI

// MARK: - 电影详情

struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    let video: Video
    @State private var full: Meta?
    @State private var selected: Video?

    var body: some View {
        let meta = full ?? model.meta(video)
        let versions = model.versions(of: video)
        let file = selected ?? video
        let resume = model.playback.resumePosition(file.path)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(backdrop: meta?.backdrop ?? meta?.posterClean ?? meta?.poster,
                             logo: meta?.logo, title: model.title(video))

                VStack(alignment: .leading, spacing: 18) {
                    Text(infoLine(meta))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    VStack(spacing: 10) {
                        Button { play(file, meta: meta) } label: {
                            Label(resume.map { "继续播放 · \(Format.clock($0))" } ?? "播放", systemImage: "play.fill")
                                .font(.system(size: 17, weight: .bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        if resume != nil {
                            Button {
                                model.playback.finish(file.path)
                                play(file, meta: meta)
                            } label: {
                                Label("从头播放", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                        }
                    }

                    let specs = FileName.specs(file.name)
                    if !specs.isEmpty {
                        HStack(spacing: 6) { ForEach(specs, id: \.self) { SpecBadge(text: $0) } }
                    }

                    if let o = meta?.overview, !o.isEmpty {
                        Text(o)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.86))
                            .lineSpacing(4)
                    }

                    if versions.count > 1 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("版本").font(.system(size: 18, weight: .bold))
                            ForEach(versions) { v in
                                Button { selected = v; Haptics.selection() } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: v.path == file.path ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(v.path == file.path ? Theme.accent : Theme.tertiary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(FileName.specs(v.name).joined(separator: " · ").isEmpty ? FileName.stem(v.name) : FileName.specs(v.name).joined(separator: " · "))
                                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                            Text(Format.size(v.size)).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                                        }
                                        Spacer()
                                    }
                                    .padding(12)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let cast = meta?.cast, !cast.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("演员").font(.system(size: 18, weight: .bold))
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(Array(cast.prefix(20).enumerated()), id: \.offset) { _, c in
                                        VStack(spacing: 6) {
                                            RemoteImage(url: c.profileURL, maxPixel: 240)
                                                .frame(width: 72, height: 72)
                                                .clipShape(Circle())
                                            Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                            if let ch = c.character, !ch.isEmpty {
                                                Text(ch).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                                            }
                                        }
                                        .frame(width: 84)
                                    }
                                }
                            }
                            .scrollClipDisabled()
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("文件").font(.system(size: 18, weight: .bold))
                        Text(file.name).font(.system(size: 12)).foregroundStyle(Theme.tertiary).textSelection(.enabled)
                        if !Format.size(file.size).isEmpty {
                            Text(Format.size(file.size)).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { full = await model.fullMeta(for: video) }
    }

    private func infoLine(_ m: Meta?) -> String {
        var parts: [String] = []
        if let y = model.year(video) { parts.append(String(y)) }
        if let g = m?.genres, !g.isEmpty { parts.append(g.prefix(3).joined(separator: " · ")) }
        let rt = Format.runtime(m?.runtime)
        if !rt.isEmpty { parts.append(rt) }
        if let r = m?.rating, r > 0 { parts.append(String(format: "★ %.1f", r)) }
        return parts.joined(separator: "  ·  ")
    }

    private func play(_ v: Video, meta: Meta?) {
        PlayerCoordinator.shared.play(PlayRequest(path: v.path, name: v.name, title: model.title(video),
                                                  subtitle: model.year(video).map { String($0) },
                                                  artwork: meta?.backdrop ?? meta?.poster), model: model)
    }
}

/// 详情页顶上：剧照铺满、往下压暗，字标压在底部（深色字标自动反白）
struct DetailHeader: View {
    let backdrop: String?
    let logo: String?
    let title: String

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: TMDBImage.url(backdrop, "w1280"), maxPixel: 1800)
                .frame(height: 460)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(stops: [
                .init(color: .black.opacity(0.45), location: 0),
                .init(color: .clear, location: 0.22),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.75), location: 0.8),
                .init(color: .black, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            LogoImage(url: TMDBImage.url(logo, "w500"), height: 80, fallback: title)
                .frame(maxWidth: 320)
                .padding(.horizontal, 30)
                .padding(.bottom, 18)
        }
        .frame(height: 460)
    }
}

// MARK: - 剧集详情

struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    let series: Series
    @State private var files: [EpisodeFile] = []
    @State private var info: [Int: SeasonEpisode] = [:]
    @State private var loading = true
    @State private var failed: String?

    var body: some View {
        let meta = model.seriesMetas[series.path]
        let last = model.playback.lastEpisode(of: series.path)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(backdrop: meta?.backdrop ?? meta?.posterClean ?? meta?.poster, logo: meta?.logo, title: meta?.title ?? series.name)

                VStack(alignment: .leading, spacing: 18) {
                    Text([series.year, series.seasonLabel, series.countLabel, meta?.genres?.prefix(2).joined(separator: " · ")]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    if !files.isEmpty {
                        Button { playFirstOrResume(last) } label: {
                            Label(resumeLabel(last), systemImage: "play.fill")
                                .font(.system(size: 17, weight: .bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }

                    let specs = (series.tags ?? []).filter { !$0.isEmpty }
                    if !specs.isEmpty {
                        HStack(spacing: 6) { ForEach(specs, id: \.self) { SpecBadge(text: $0) } }
                    }

                    if let o = meta?.overview, !o.isEmpty {
                        Text(o).font(.system(size: 15)).foregroundStyle(.white.opacity(0.86)).lineSpacing(4)
                    }

                    Text(series.seasonLabel ?? "剧集").font(.system(size: 20, weight: .bold)).padding(.top, 6)

                    if loading && files.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else if let failed, files.isEmpty {
                        Text(failed).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    }

                    LazyVStack(spacing: 14) {
                        ForEach(Array(files.enumerated()), id: \.element.id) { i, f in
                            Button { play(index: i) } label: {
                                EpisodeRow(file: f, info: f.ep.flatMap { info[$0] }, fallbackArt: meta?.backdrop,
                                           progress: model.playback.entry(f.path)?.fraction)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        loading = true
        await model.ensureSeriesMeta(series)
        do {
            let list = try await APIClient.shared.episodes(seriesPath: series.path)
            files = list.sorted { ($0.ep ?? Int.max, $0.name) < ($1.ep ?? Int.max, $1.name) }
        } catch {
            failed = "分集清单没取到：\(error.localizedDescription)"
        }
        loading = false
        if let id = series.tmdbId ?? model.seriesMetas[series.path]?.id, let s = series.season {
            if let eps = try? await APIClient.shared.season(tmdbId: id, season: s) {
                var d: [Int: SeasonEpisode] = [:]
                for e in eps { if let n = e.ep { d[n] = e } }
                info = d
            }
        }
    }

    private func resumeLabel(_ last: WatchEntry?) -> String {
        if let last, let ep = last.episode { return "继续观看 · 第 \(ep) 集" }
        return "播放第 1 集"
    }

    private func playFirstOrResume(_ last: WatchEntry?) {
        if let last, let i = files.firstIndex(where: { $0.path == last.path }) { play(index: i) } else { play(index: 0) }
    }

    private func request(_ f: EpisodeFile) -> PlayRequest {
        let meta = model.seriesMetas[series.path]
        let name = f.ep.flatMap { info[$0]?.name }
        let sub = [f.ep.map { "第 \($0) 集" }, name].compactMap { $0 }.joined(separator: " · ")
        return PlayRequest(path: f.path, name: f.name, title: meta?.title ?? series.name, subtitle: sub,
                           artwork: f.ep.flatMap { info[$0]?.still } ?? meta?.backdrop,
                           seriesPath: series.path, episode: f.ep)
    }

    private func play(index: Int) {
        guard files.indices.contains(index) else { return }
        var req = request(files[index])
        req.queue = files[(index + 1)...].map { request($0) }
        PlayerCoordinator.shared.play(req, model: model)
    }
}

struct EpisodeRow: View {
    let file: EpisodeFile
    let info: SeasonEpisode?
    let fallbackArt: String?
    let progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: TMDBImage.url(info?.still ?? fallbackArt, "w300"), maxPixel: 480)
                    .frame(width: 148, height: 83)
                    .clipped()
                if let p = progress, p > 0.01 { ProgressCapsule(fraction: p).padding(.horizontal, 6).padding(.bottom, 5) }
            }
            .frame(width: 148, height: 83)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                let rt = Format.runtime(info?.runtime)
                if !rt.isEmpty { Text(rt).font(.system(size: 12)).foregroundStyle(Theme.tertiary) }
                if let o = info?.overview, !o.isEmpty {
                    Text(o).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        let n = file.ep.map { "第 \($0) 集" } ?? FileName.stem(file.name)
        if let name = info?.name, !name.isEmpty { return "\(n) · \(name)" }
        return n
    }
}

// MARK: - 某一年：电影与剧集

struct YearView: View {
    @Environment(AppModel.self) private var model
    let year: Int

    var body: some View {
        let movies = model.movies(inYear: year)
        let series = model.seriesInYear(year)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !series.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "剧集", count: series.count)
                        PosterGrid {
                            ForEach(series) { s in
                                NavigationLink(value: Route.series(s)) { SeriesPosterTile(series: s) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "电影", count: movies.count)
                    PosterGrid {
                        ForEach(movies) { v in
                            NavigationLink(value: Route.movie(v)) { MoviePosterTile(video: v) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.bg)
        .navigationTitle(String(year))
        .navigationBarTitleDisplayMode(.large)
    }
}
