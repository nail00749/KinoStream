import SwiftUI

struct TorrentsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: CatalogStore
    @State private var linkingTorrent: Torrent?
    @State private var removingTorrentIDs: Set<String> = []
    @State private var expandedSections: Set<String> = []
    let query: String
    let onAdd: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .bottom) {
                SectionHeading(title: "Моя коллекция", subtitle: "Раздачи, добавленные в ваш TorrServer")
                Button { Task { await model.refreshTorrents() } } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(KinoPalette.muted).padding(9)
                }
                .buttonStyle(.plain)
            }

            if !model.connected {
                EmptyState(symbol: "antenna.radiowaves.left.and.right.slash", title: "Нет соединения с сервером", message: "Проверьте адрес и параметры авторизации TorrServer.", actionTitle: "Открыть настройки", action: onSettings)
            } else if model.torrents.isEmpty {
                EmptyState(symbol: "square.stack.3d.up", title: "Коллекция пока пуста", message: "Добавьте magnet-ссылку или найдите раздачу по названию.", actionTitle: "Добавить magnet") { onAdd() }
            } else if visibleTorrents.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "Ничего не найдено", message: "Попробуйте название, имя файла или «сезон 2 серия 5».")
            } else {
                ScrollView {
                    LazyVStack(spacing: 11) {
                        ForEach(visibleTorrents) { torrent in
                            torrentCard(torrent)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(30)
        .sheet(item: $linkingTorrent) { torrent in
            TorrentAssociationView(torrent: torrent).frame(minWidth: 640, minHeight: 520)
        }
        .task { await model.refreshTorrents() }
    }

    private var collectionQuery: CollectionQuery { CollectionQuery(query) }

    private func searchTitle(_ torrent: Torrent) -> String {
        let context = catalog.playbackContext(forTorrentHash: torrent.hash)
        let original = context.flatMap { catalog.item(id: $0.itemID)?.originalTitle } ?? ""
        return "\(context?.title ?? "") \(original) \(torrent.displayTitle)"
    }

    private func matchingFiles(_ torrent: Torrent) -> [TorrentFile] {
        let matcher = collectionQuery
        let title = searchTitle(torrent)
        let hint = catalog.playbackContext(forTorrentHash: torrent.hash)?.season
        return torrent.fileStats.filter { $0.isPlayable && matcher.matches(title: title, file: $0, seasonHint: hint) }
    }

    private var visibleTorrents: [Torrent] {
        let matcher = collectionQuery
        return model.torrents.filter { matcher.isEmpty || matcher.matches(title: searchTitle($0)) || !matchingFiles($0).isEmpty }
    }

    private func torrentCard(_ torrent: Torrent) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(LinearGradient(colors: [Color(red: 0.17, green: 0.29, blue: 0.27), Color(red: 0.12, green: 0.15, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let context = catalog.playbackContext(forTorrentHash: torrent.hash), let item = catalog.item(id: context.itemID) {
                        MediaArtwork(item: item).clipShape(RoundedRectangle(cornerRadius: 11))
                    } else {
                        Image(systemName: "film.stack")
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(KinoPalette.accent)
                    }
                }
                .frame(width: 48, height: 54)
                VStack(alignment: .leading, spacing: 7) {
                    Text(catalog.playbackContext(forTorrentHash: torrent.hash)?.title ?? torrent.displayTitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    HStack(spacing: 12) {
                        Text(torrent.statString ?? "Добавлена")
                        if let size = torrent.torrentSize, size > 0 { Text(size.fileSizeLabel) }
                        if let peers = torrent.activePeers { Label("\(peers)", systemImage: "person.2") }
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(KinoPalette.muted)
                }
                Spacer(minLength: 5)
                Button { linkingTorrent = torrent } label: {
                    Image(systemName: "link").foregroundStyle(KinoPalette.accent)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain).help("Привязать к карточке фильма или сериала")
                Button { Task { await remove(torrent) } } label: {
                    Group {
                        if removingTorrentIDs.contains(torrent.hash) {
                            ProgressView().controlSize(.small).tint(KinoPalette.accent)
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(KinoPalette.muted)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Удалить с сервера")
                .disabled(removingTorrentIDs.contains(torrent.hash))
            }

            if torrent.progress > 0 {
                let progress = torrent.progress
                VStack(spacing: 5) {
                    ProgressView(value: progress).tint(KinoPalette.accent)
                    HStack {
                        Text("Загружено \(Int(progress * 100))%")
                        Spacer()
                        if let speed = torrent.downloadSpeed, speed > 0 { Text(speed.speedLabel) }
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(KinoPalette.muted)
                }
            }

            if !torrent.fileStats.isEmpty {
                let files = matchingFiles(torrent)
                let grouping = groupEpisodes(files, seasonHint: catalog.playbackContext(forTorrentHash: torrent.hash)?.season)
                if grouping.seasons.isEmpty {
                    fileList(files.map { EpisodeFile(file: $0, season: -1, episode: nil) }, torrent: torrent)
                } else {
                    VStack(spacing: 7) {
                        ForEach(grouping.seasons) { season in
                            let sectionID = "\(torrent.hash)-season-\(season.number)"
                            let isExpanded = !collectionQuery.isEmpty || expandedSections.contains(sectionID)
                            VStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    Button {
                                        toggleSection(sectionID)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "rectangle.stack.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(KinoPalette.accent)
                                            Text(seasonTitle(season.number))
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.white)
                                            Text("\(season.episodes.count) сер.")
                                                .font(.system(size: 10))
                                                .foregroundStyle(KinoPalette.muted)
                                            Spacer()
                                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(KinoPalette.accent)
                                        }
                                        .padding(.horizontal, 11)
                                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Button {
                                        let hint = catalog.playbackContext(forTorrentHash: torrent.hash)?.season
                                        let allSeasons = groupEpisodes(torrent.fileStats.filter(\.isPlayable), seasonHint: hint).seasons
                                        let files = allSeasons.first(where: { $0.number == season.number })?.episodes.map(\.file) ?? []
                                        let title = catalog.playbackContext(forTorrentHash: torrent.hash)?.title ?? torrent.displayTitle
                                        model.downloadSeason(torrent, files: files, title: title, season: season.number)
                                    } label: {
                                        Label(season.number < 0 ? "Скачать серии" : "Скачать сезон", systemImage: "arrow.down.circle")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(KinoPalette.accent)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Скачать все серии этого сезона из раздачи, включая скрытые поиском")
                                    .padding(.trailing, 11)
                                }

                                if isExpanded {
                                    fileList(season.episodes, torrent: torrent)
                                        .padding(.horizontal, 10)
                                        .padding(.bottom, 9)
                                }
                            }
                            .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                        }

                        if !grouping.otherFiles.isEmpty {
                            let sectionID = "\(torrent.hash)-other"
                            let isExpanded = !collectionQuery.isEmpty || expandedSections.contains(sectionID)
                            VStack(spacing: 0) {
                                Button {
                                    toggleSection(sectionID)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text("Другие видео")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Text("\(grouping.otherFiles.count)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(KinoPalette.muted)
                                        Spacer()
                                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(KinoPalette.accent)
                                    }
                                    .padding(.horizontal, 11)
                                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if isExpanded {
                                    fileList(grouping.otherFiles.map { EpisodeFile(file: $0, season: -1, episode: nil) }, torrent: torrent)
                                        .padding(.horizontal, 10)
                                        .padding(.bottom, 9)
                                }
                            }
                            .background(Color.black.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini).tint(KinoPalette.accent)
                    Text("Получаем информацию о файлах…").font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                }
            }
        }
        .padding(15)
        .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(KinoPalette.line, lineWidth: 1))
    }

    private func fileList(_ episodes: [EpisodeFile], torrent: Torrent) -> some View {
        VStack(spacing: 0) {
            ForEach(episodes) { episode in
                let context = Optional(model.playbackController.context(for: torrent, file: episode.file, catalog: catalog))
                let record = context.flatMap { catalog.playbackRecord(for: $0) }
                let watched = context.map { catalog.isWatched($0) } ?? false
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill").foregroundStyle(KinoPalette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.episode.map { "Серия \($0)" } ?? episode.file.name)
                            .font(.system(size: 11, weight: .medium))
                        FileDownloadStatusView(controller: model.downloads, torrentHash: torrent.hash, fileID: episode.file.id)
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                        if let record {
                            Label(
                                watched || record.completed ? "Просмотрена" : "Продолжить с \(timecode(record.position))",
                                systemImage: watched || record.completed ? "checkmark.circle.fill" : "clock"
                            )
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(KinoPalette.accent)
                        } else if watched {
                            Label("Просмотрена", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(KinoPalette.accent)
                        }
                    }
                    Spacer()
                    Text(episode.file.length.fileSizeLabel).font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                    Button { model.download(torrent, file: episode.file) } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(KinoPalette.accent)
                    .help("Скачать на устройство")
                    Button("Смотреть") {
                        model.play(torrent, file: episode.file, trackingContext: context, catalog: catalog)
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(KinoPalette.accent)
                        .padding(.leading, 8)
                }
                .padding(.vertical, 9)
                Rectangle().fill(KinoPalette.line).frame(height: 1)
            }
        }
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
    }

    private func timecode(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds / 60) % 60
        let remainder = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func groupEpisodes(_ files: [TorrentFile], seasonHint: Int?) -> EpisodeGrouping {
        let parsed = files.map { file -> EpisodeFile in
            let coordinates = file.episodeCoordinates
            return EpisodeFile(file: file, season: coordinates?.season ?? seasonHint ?? -1, episode: coordinates?.episode)
        }
        let episodeFiles = parsed.filter { $0.episode != nil }
        let otherFiles = parsed.filter { $0.episode == nil }.map(\.file)
        let groups = Dictionary(grouping: episodeFiles, by: \.season)
        let seasons = groups.keys.sorted().map { number in
            EpisodeSeason(number: number, episodes: (groups[number] ?? []).sorted {
                if $0.episode != $1.episode { return ($0.episode ?? 0) < ($1.episode ?? 0) }
                return $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending
            })
        }
        return EpisodeGrouping(seasons: seasons, otherFiles: otherFiles)
    }

    private func seasonTitle(_ number: Int) -> String {
        switch number {
        case -1: "Сезон не указан"
        case 0: "Спецвыпуски"
        default: "Сезон \(number)"
        }
    }

    private func toggleSection(_ id: String) {
        if !expandedSections.insert(id).inserted {
            expandedSections.remove(id)
        }
    }

    @MainActor
    private func remove(_ torrent: Torrent) async {
        guard !removingTorrentIDs.contains(torrent.hash) else { return }
        removingTorrentIDs.insert(torrent.hash)
        defer { removingTorrentIDs.remove(torrent.hash) }
        await model.removeTorrent(torrent)
    }
}

private struct EpisodeFile: Identifiable {
    let file: TorrentFile
    let season: Int
    let episode: Int?
    var id: Int { file.id }
}

private struct EpisodeSeason: Identifiable {
    let number: Int
    let episodes: [EpisodeFile]
    var id: Int { number }
}

private struct EpisodeGrouping {
    let seasons: [EpisodeSeason]
    let otherFiles: [TorrentFile]
}
