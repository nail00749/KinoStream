import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: CatalogStore
    @Binding var searchText: String
    @Binding var searchTarget: TorrentSearchTarget

    @State private var filters = TorrentSearchFilters()
    private var filteredResults: [TorrentSearchResult] { filters.apply(to: results) }

    @State private var results: [TorrentSearchResult] = []
    @State private var resultsTarget = TorrentSearchTarget.text("")
    @State private var requestID = UUID()
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var startingID: String?
    @State private var activeSheet: SearchSheet?

    private var searchIdentity: String {
        let metadataID = searchTarget.imdbID ?? searchTarget.kinopoiskID.map { String($0) } ?? searchTarget.legacyTMDBID.map { String($0) } ?? searchTarget.mediaItemID ?? ""
        return "\(searchText)|\(searchTarget.kind?.rawValue ?? "text")|\(metadataID)|\(searchTarget.season ?? 0)|\(searchTarget.episode ?? 0)"
    }

    private var currentSearchTarget: TorrentSearchTarget {
        searchTarget.query == searchText ? searchTarget : .text(searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .bottom) {
                SectionHeading(title: "Поиск раздач", subtitle: "Поиск через JacRed")
                Spacer()
                Button { activeSheet = .episodes } label: {
                    Label("Выбрать серию", systemImage: "rectangle.stack.play")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(KinoPalette.accent)
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(KinoPalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Найти сериал, выбрать сезон и серию")
            }

            if !results.isEmpty, resultsTarget == currentSearchTarget, !isSearching {
                TorrentFiltersView(filters: $filters, shown: filteredResults.count, total: results.count)
            }

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "Что будем смотреть?", message: "Введите название. Для сериала выберите сезон и серию — поиск предложит раздачи именно для неё.")
            } else if isSearching || resultsTarget != currentSearchTarget {
                EmptyState(symbol: "waveform", title: "Ищем раздачи", message: "Запрашиваем каталог JacRed…")
            } else if let errorMessage {
                EmptyState(symbol: "exclamationmark.triangle", title: "Не удалось выполнить поиск", message: errorMessage, actionTitle: "Повторить") {
                    Task { await search() }
                }
            } else if results.isEmpty {
                EmptyState(symbol: "sparkle.magnifyingglass", title: "Ничего не найдено", message: "Попробуйте изменить название или год выпуска.")
            } else if filteredResults.isEmpty {
                EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "Нет раздач с такими фильтрами", message: "Ослабьте условия или сбросьте фильтры.", actionTitle: "Сбросить фильтры") {
                    filters = TorrentSearchFilters()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredResults) { result in resultRow(result) }
                    }
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(30)
        .task(id: searchIdentity) {
            guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                results = []
                errorMessage = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .episodes:
                EpisodePickerView(initialQuery: searchText) { item, seasonNumber, episode in
                    catalog.update(item)
                    let query = String(format: "%@ S%02dE%02d", item.originalTitle, seasonNumber, episode.number)
                    searchTarget = TorrentSearchTarget(
                        query: query,
                        kind: .series,
                        legacyTMDBID: item.legacyTMDBID,
                        imdbID: item.imdbID,
                        kinopoiskID: item.kinopoiskID,
                        mediaItemID: item.id,
                        title: item.title,
                        originalTitle: item.originalTitle,
                        year: item.year > 0 ? item.year : nil,
                        season: seasonNumber,
                        episode: episode.number
                    )
                    searchText = query
                }
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 560)
            case .files(let selection):
                PlaybackFilePickerView(torrent: selection.torrent, files: selection.files) { file in
                    model.play(selection.torrent, file: file, trackingContext: selection.context, catalog: catalog)
                }
                .frame(minWidth: 540, minHeight: 420)
            }
        }
    }

    private func search() async {
        let requestedTarget = currentSearchTarget
        let token = UUID()
        requestID = token
        isSearching = true
        errorMessage = nil
        defer { if requestID == token { isSearching = false } }
        do {
            let found = try await model.search(requestedTarget)
            guard !Task.isCancelled, requestID == token, currentSearchTarget == requestedTarget else { return }
            results = found
            resultsTarget = requestedTarget
        } catch {
            guard !Task.isCancelled, requestID == token, currentSearchTarget == requestedTarget else { return }
            resultsTarget = requestedTarget
            errorMessage = error.localizedDescription
        }
    }

    private func resultRow(_ result: TorrentSearchResult) -> some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [KinoPalette.accent.opacity(0.22), Color(red: 0.14, green: 0.18, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "film")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(KinoPalette.accent.opacity(0.85))
            }
            .frame(width: 48, height: 62)
            VStack(alignment: .leading, spacing: 6) {
                Text(result.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                HStack(spacing: 12) {
                    Text(result.source)
                    if let size = result.size { Label(size, systemImage: "externaldrive") }
                    if let seeders = result.seeders { Label("\(seeders) сидов", systemImage: "arrow.up") }
                    if let leechers = result.leechers, leechers > 0 { Label("\(leechers) пиров", systemImage: "arrow.down") }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(KinoPalette.muted)
            }
            Spacer(minLength: 12)
            Button {
                catalog.toggleFavorite(result, target: resultsTarget)
            } label: {
                Image(systemName: catalog.isFavorite(result) ? "heart.fill" : "heart")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(catalog.isFavorite(result) ? Color(red: 1, green: 0.46, blue: 0.52) : KinoPalette.muted)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help(catalog.isFavorite(result) ? "Убрать из избранного" : "В избранное")
            .accessibilityLabel(catalog.isFavorite(result) ? "Убрать раздачу из избранного" : "Добавить раздачу в избранное")
            .disabled(result.torrentLink == nil)
            Button {
                Task { await startPlayback(result) }
            } label: {
                if startingID == result.id { ProgressView().controlSize(.small) }
                else { Label("Смотреть", systemImage: "play.fill") }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(result.torrentLink == nil || startingID != nil)
        }
        .padding(13)
        .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(KinoPalette.line, lineWidth: 1))
    }

    @MainActor
    private func startPlayback(_ result: TorrentSearchResult) async {
        guard result.torrentLink != nil else {
            model.bannerMessage = "Для этой раздачи нет magnet или ссылки на файл."
            return
        }
        let requestedTarget = resultsTarget
        startingID = result.id
        defer { startingID = nil }
        do {
            if let selection = try await model.playbackController.prepare(result, target: requestedTarget, catalog: catalog) {
                activeSheet = .files(selection)
            }
        } catch is CancellationError {
        } catch {
            if model.playbackController.loadingState?.isFailure != true {
                model.bannerMessage = "Не удалось подготовить видео. Попробуйте другую раздачу."
            }
        }
    }

}

private enum SearchSheet: Identifiable {
    case episodes
    case files(TorrentFileSelection)

    var id: String {
        switch self {
        case .episodes: "episodes"
        case .files(let selection): "files-\(selection.torrent.hash)"
        }
    }
}

struct PlaybackFilePickerView: View {
    let torrent: Torrent
    let files: [TorrentFile]
    let onSelect: (TorrentFile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Выберите видеофайл").font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(torrent.displayTitle).font(.system(size: 11)).foregroundStyle(KinoPalette.muted).lineLimit(2)
                }
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(.plain).foregroundStyle(KinoPalette.muted)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(files) { file in
                        Button {
                            onSelect(file)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill").foregroundStyle(KinoPalette.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                                    Text(file.length.fileSizeLabel).font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                                }
                                Spacer()
                                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(KinoPalette.muted)
                            }
                            .padding(12)
                            .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(22)
        .background(KinoPalette.background)
    }
}

struct FavoriteTorrentsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: CatalogStore

    let query: String
    let onSearch: (TorrentSearchTarget) -> Void

    @State private var startingID: String?
    @State private var pendingFiles: TorrentFileSelection?

    private var favoriteTorrents: [FavoriteTorrent] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return catalog.favoriteTorrents }
        return catalog.favoriteTorrents.filter {
            $0.result.title.localizedCaseInsensitiveContains(trimmed)
                || $0.target.query.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            SectionHeading(title: "Раздачи", subtitle: "Раздачи, отмеченные сердцем в поиске JacRed")

            if catalog.favoriteTorrents.isEmpty {
                EmptyState(
                    symbol: "heart",
                    title: "Здесь пока пусто",
                    message: "Нажмите на сердечко у результата поиска JacRed — раздача появится здесь.",
                    actionTitle: "Открыть поиск"
                ) {
                    onSearch(.text(""))
                }
            } else if favoriteTorrents.isEmpty {
                EmptyState(
                    symbol: "magnifyingglass",
                    title: "Ничего не найдено",
                    message: "Попробуйте изменить запрос или очистить строку поиска."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(favoriteTorrents) { favorite in
                            favoriteRow(favorite)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(30)
        .sheet(item: $pendingFiles) { selection in
            PlaybackFilePickerView(torrent: selection.torrent, files: selection.files) { file in
                model.play(selection.torrent, file: file, trackingContext: selection.context, catalog: catalog)
            }
            .frame(minWidth: 540, minHeight: 420)
        }
    }

    private func favoriteRow(_ saved: FavoriteTorrent) -> some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [KinoPalette.accent.opacity(0.22), Color(red: 0.14, green: 0.18, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "heart.fill")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Color(red: 1, green: 0.46, blue: 0.52))
            }
            .frame(width: 48, height: 62)

            VStack(alignment: .leading, spacing: 6) {
                Text(saved.result.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Text(saved.result.source)
                    if let size = saved.result.size { Label(size, systemImage: "externaldrive") }
                    if let seeders = saved.result.seeders { Label("\(seeders) сидов", systemImage: "arrow.up") }
                    if let season = saved.target.season, let episode = saved.target.episode {
                        Text(String(format: "S%02dE%02d", season, episode))
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(KinoPalette.muted)
            }
            Spacer(minLength: 10)

            Button {
                Task { await startPlayback(saved) }
            } label: {
                if startingID == saved.id { ProgressView().controlSize(.small) }
                else { Label("Смотреть", systemImage: "play.fill") }
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(saved.result.torrentLink == nil || startingID != nil)

            Button {
                catalog.removeFavoriteTorrent(id: saved.id)
            } label: {
                Image(systemName: "heart.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KinoPalette.muted)
                    .frame(width: 31, height: 31)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("Убрать из избранного")
        }
        .padding(13)
        .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(KinoPalette.line, lineWidth: 1))
    }

    @MainActor
    private func startPlayback(_ saved: FavoriteTorrent) async {
        guard saved.result.torrentLink != nil else {
            model.bannerMessage = "Для этой раздачи нет magnet или ссылки на файл."
            return
        }
        startingID = saved.id
        defer { startingID = nil }
        do {
            pendingFiles = try await model.playbackController.prepare(saved.result, target: saved.target, catalog: catalog)
        } catch is CancellationError {
        } catch {
            if model.playbackController.loadingState?.isFailure != true {
                model.bannerMessage = "Не удалось подготовить видео. Попробуйте другую раздачу."
            }
        }
    }

}
