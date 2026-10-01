import SwiftUI

struct MediaDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.dismiss) private var dismiss

    let item: MediaItem
    let onSearch: (TorrentSearchTarget) -> Void
    let onPlay: (TorrentSearchTarget) -> Void

    @State private var hydratedItem: MediaItem?
    @State private var selectedSeasonNumber = 1
    @State private var loadedEpisodes: [Int: [MediaEpisode]] = [:]
    @State private var isLoadingDetails = false
    @State private var isLoadingEpisodes = false
    @State private var detailError: String?

    private var currentItem: MediaItem { hydratedItem ?? item }
    private var selectedSeason: MediaSeason? {
        currentItem.seasons.first(where: { $0.number == selectedSeasonNumber }) ?? currentItem.seasons.first
    }
    private var episodes: [MediaEpisode] {
        loadedEpisodes[selectedSeasonNumber]
            ?? currentItem.seasons.first(where: { $0.number == selectedSeasonNumber })?.episodes
            ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .top, spacing: 22) {
                    MediaArtwork(item: currentItem)
                        .frame(width: 176, height: 238)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 13) {
                        HStack(spacing: 7) {
                            Text(currentItem.kind.title.uppercased())
                            Circle().fill(KinoPalette.muted).frame(width: 3, height: 3)
                            Text(currentItem.year > 0 ? String(currentItem.year) : "Год не указан")
                        }
                        .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(KinoPalette.accent)

                        Text(currentItem.title)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(currentItem.originalTitle)
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(KinoPalette.muted)

                        HStack(spacing: 6) {
                            Image(systemName: "star.fill").foregroundStyle(Color(red: 1, green: 0.78, blue: 0.4))
                            Text("IMDb \(currentItem.rating)").foregroundStyle(.white)
                            Text("·").foregroundStyle(KinoPalette.muted)
                            Text(currentItem.kind == .series ? "\(currentItem.seasonCount) сезонов · \(currentItem.episodeCount) серий" : (currentItem.duration ?? "Фильм"))
                                .foregroundStyle(KinoPalette.muted)
                        }
                        .font(.system(size: 11, weight: .semibold))

                        if let imdbID = currentItem.imdbID,
                           let imdbURL = URL(string: "https://www.imdb.com/title/\(imdbID)/") {
                            Link(destination: imdbURL) {
                                Label("IMDb · \(imdbID)", systemImage: "arrow.up.right.square")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(KinoPalette.accent)
                            }
                        }

                        HStack(spacing: 7) {
                            ForEach(currentItem.genres, id: \.self) { genre in
                                Text(genre)
                                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                            }
                        }

                        HStack(spacing: 9) {
                            Button {
                                onSearch(searchTarget(for: currentItem))
                                dismiss()
                            } label: {
                                Label(currentItem.kind == .series ? "Найти сериал" : "Найти раздачу", systemImage: "magnifyingglass")
                            }
                            .buttonStyle(AccentButtonStyle())

                            Button { catalog.toggleFavorite(currentItem) } label: {
                                Image(systemName: catalog.isFavorite(currentItem) ? "heart.fill" : "heart")
                                    .foregroundStyle(catalog.isFavorite(currentItem) ? Color(red: 1, green: 0.46, blue: 0.52) : .white)
                                    .frame(width: 37, height: 37)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .help(catalog.isFavorite(currentItem) ? "Убрать из избранного" : "В избранное")
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(KinoPalette.muted)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Text(currentItem.synopsis)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)

                if currentItem.kind == .movie {
                    movieActions
                } else {
                    seriesEpisodes
                }
            }
            .padding(26)
        }
        .background(KinoPalette.background)
        .scrollIndicators(.hidden)
        .task(id: item.id) { await loadDetails() }
        .task(id: selectedSeasonNumber) {
            guard currentItem.kind == .series, selectedSeason != nil else { return }
            await loadEpisodes(for: selectedSeasonNumber)
        }
    }

    private var movieActions: some View {
        let watched = catalog.isExplicitlyWatched(currentItem)
        let context = PlaybackContext(
            legacyTMDBID: currentItem.legacyTMDBID,
            imdbID: currentItem.imdbID,
            kinopoiskID: currentItem.kinopoiskID,
            mediaItemID: currentItem.hasMetadataID ? currentItem.id : nil,
            kind: .movie,
            title: currentItem.title,
            originalTitle: currentItem.originalTitle,
            year: currentItem.year
        )
        let record = catalog.playbackRecord(for: context)
        return HStack {
            Label(
                watched ? "Просмотрено" : (record.map { "Продолжить с \(timeLabel($0.position))" } ?? "Не просмотрено"),
                systemImage: watched ? "checkmark.circle.fill" : (record == nil ? "circle" : "play.circle.fill")
            )
            .font(.system(size: 11, weight: .medium)).foregroundStyle(watched || record != nil ? KinoPalette.accent : KinoPalette.muted)
            Spacer()
            Button(watched ? "Снять отметку" : "Отметить просмотренным") {
                catalog.toggleWatched(currentItem)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(KinoPalette.accent)
        }
        .padding(15)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
    }

    private var seriesEpisodes: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("СЕЗОНЫ И СЕРИИ").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(KinoPalette.accent)
                    Text("Отмечайте серии по мере просмотра")
                        .font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                }
                Spacer()
                Button(catalog.isFullyWatched(currentItem) ? "Снять отметку со всего сериала" : "Отметить сериал просмотренным") {
                    catalog.toggleWatched(currentItem)
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(KinoPalette.accent)
            }

            if isLoadingDetails || isLoadingEpisodes {
                ProgressView("Загружаем сезоны и серии…").font(.system(size: 11)).tint(KinoPalette.accent)
            } else if let detailError {
                Text(detailError).font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
            } else if let season = selectedSeason {
                HStack(spacing: 7) {
                    ForEach(currentItem.seasons) { itemSeason in
                        let isSelected = itemSeason.number == season.number
                        Button { selectedSeasonNumber = itemSeason.number } label: {
                            Text("Сезон \(itemSeason.number)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isSelected ? KinoPalette.background : KinoPalette.muted)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(isSelected ? KinoPalette.accent : Color.white.opacity(0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                let seasonTarget = searchTarget(for: currentItem, season: selectedSeasonNumber)
                if let context = seasonTarget.playbackContext, let hash = catalog.preferredSeriesSource(for: context) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Раздача для этого сезона").font(.system(size: 10, weight: .semibold))
                            Text(model.torrents.first(where: { $0.hash.lowercased() == hash })?.displayTitle ?? "Выбранная раздача сейчас недоступна")
                                .font(.system(size: 10)).foregroundStyle(KinoPalette.muted).lineLimit(2)
                        }
                        Spacer()
                        Button("Сменить раздачу") { onSearch(seasonTarget); dismiss() }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(KinoPalette.accent)
                    }
                    .padding(12).background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(spacing: 8) {
                    ForEach(episodes) { episode in episodeRow(episode) }
                }
            } else {
                Text(!currentItem.hasMetadataID ? "История серий появится после начала воспроизведения." : "Поставщик метаданных не вернул список сезонов для этого сериала.")
                    .font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
            }
        }
    }

    private func episodeRow(_ episode: MediaEpisode) -> some View {
        let watched = catalog.isWatched(episode, in: currentItem)
        let playbackContext = PlaybackContext(
            legacyTMDBID: currentItem.legacyTMDBID,
            imdbID: currentItem.imdbID,
            kinopoiskID: currentItem.kinopoiskID,
            mediaItemID: currentItem.hasMetadataID ? currentItem.id : nil,
            kind: .series,
            title: currentItem.title,
            originalTitle: currentItem.originalTitle,
            year: currentItem.year,
            season: selectedSeasonNumber,
            episode: episode.number
        )
        let playbackRecord = catalog.playbackRecord(for: playbackContext)
        return HStack(spacing: 12) {
            Button { catalog.toggleWatched(episode, in: currentItem) } label: {
                Image(systemName: watched ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(watched ? KinoPalette.accent : KinoPalette.muted)
            }
            .buttonStyle(.plain)
            .help(watched ? "Снять отметку" : "Отметить просмотренной")

            Text(String(format: "%02d", episode.number))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(KinoPalette.muted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                Text(episode.summary).font(.system(size: 9)).foregroundStyle(KinoPalette.muted).lineLimit(2)
                if let playbackRecord, playbackRecord.position > 0 {
                    HStack(spacing: 6) {
                        ProgressView(value: playbackRecord.fraction)
                            .tint(KinoPalette.accent)
                            .frame(maxWidth: 90)
                        Text(watched || playbackRecord.completed ? "Просмотрена" : "Продолжить с \(timeLabel(playbackRecord.position))")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(KinoPalette.accent)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Text(episode.duration).font(.system(size: 9, weight: .medium)).foregroundStyle(KinoPalette.muted)
            Button {
                onPlay(searchTarget(for: currentItem, season: selectedSeasonNumber, episode: episode.number))
                dismiss()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(KinoPalette.background)
                    .frame(width: 27, height: 27)
                    .background(KinoPalette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Воспроизвести из «Моей коллекции» или найти раздачу серии")
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(KinoPalette.line, lineWidth: 1))
    }

    private func timeLabel(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func searchTarget(for item: MediaItem, season: Int? = nil, episode: Int? = nil) -> TorrentSearchTarget {
        let query: String
        if let season, let episode {
            query = String(format: "%@ S%02dE%02d", item.originalTitle, season, episode)
        } else if let season {
            query = String(format: "%@ S%02d", item.originalTitle, season)
        } else if item.year > 0 {
            query = "\(item.originalTitle) \(item.year)"
        } else {
            query = item.originalTitle
        }
        return TorrentSearchTarget(
            query: query,
            kind: item.kind == .movie ? .movie : .series,
            legacyTMDBID: item.legacyTMDBID,
            imdbID: item.imdbID,
            kinopoiskID: item.kinopoiskID,
            mediaItemID: item.hasMetadataID ? item.id : nil,
            title: item.title,
            originalTitle: item.originalTitle,
            year: item.year > 0 ? item.year : nil,
            season: season,
            episode: episode
        )
    }

    @MainActor
    private func loadDetails() async {
        guard item.hasMetadataID else {
            hydratedItem = item
            selectedSeasonNumber = item.seasons.first?.number ?? 1
            detailError = nil
            return
        }
        isLoadingDetails = true
        defer { isLoadingDetails = false }
        do {
            let details = try await model.mediaDetails(for: item)
            hydratedItem = details
            catalog.update(details)
            selectedSeasonNumber = details.seasons.first?.number ?? 1
            detailError = nil
            if let firstSeason = details.seasons.first {
                await loadEpisodes(for: firstSeason.number)
            }
        } catch {
            detailError = error.localizedDescription
        }
    }

    @MainActor
    private func loadEpisodes(for seasonNumber: Int) async {
        if !currentItem.hasMetadataID {
            loadedEpisodes[seasonNumber] = currentItem.seasons.first(where: { $0.number == seasonNumber })?.episodes ?? []
            return
        }
        guard loadedEpisodes[seasonNumber] == nil, !isLoadingEpisodes,
              let season = currentItem.seasons.first(where: { $0.number == seasonNumber }), season.episodeCount > 0 else { return }
        isLoadingEpisodes = true
        defer { isLoadingEpisodes = false }
        do {
            let episodes = try await model.seasonEpisodes(for: currentItem, seasonNumber: seasonNumber)
            loadedEpisodes[seasonNumber] = episodes
            var updated = currentItem
            if let index = updated.seasons.firstIndex(where: { $0.number == seasonNumber }) {
                updated.seasons[index].episodes = episodes
            }
            hydratedItem = updated
            catalog.update(updated)
        } catch {
            detailError = error.localizedDescription
        }
    }
}
