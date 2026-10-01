import SwiftUI

private enum FavoritesTab: String, Hashable {
    case media
    case torrents
}

struct FavoritesView: View {
    let onSearch: (TorrentSearchTarget) -> Void
    let onPlay: (TorrentSearchTarget) -> Void
    @Binding var query: String

    @State private var selectedTab: FavoritesTab = .media

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Избранное", selection: $selectedTab) {
                    Text("Фильмы и сериалы").tag(FavoritesTab.media)
                    Text("Раздачи").tag(FavoritesTab.torrents)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340, height: 32)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 30)
            .frame(height: 54, alignment: .bottomLeading)
            .fixedSize(horizontal: false, vertical: true)

            Group {
                switch selectedTab {
                case .media:
                    CatalogView(scope: .favorites, onSearch: onSearch, onPlay: onPlay, query: $query)
                case .torrents:
                    FavoriteTorrentsView(query: query, onSearch: onSearch)
                }
            }
            .id(selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CatalogView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: CatalogStore

    let scope: CatalogScope
    let onSearch: (TorrentSearchTarget) -> Void
    let onPlay: (TorrentSearchTarget) -> Void

    @Binding var query: String
    @State private var collection: CatalogCollection = .popular
    @State private var genre: CatalogGenre = .all
    private var discoverySelection: CatalogDiscoverySelection {
        CatalogDiscoverySelection(collection: collection, genre: genre, kind: kindFilter)
    }

    @State private var kindFilter: MediaKind?
    @State private var selectedItem: MediaItem?
    @State private var displayLimit = 6

    private let resultsPageSize = 6

    private var title: String {
        switch scope {
        case .all: "Каталог"
        case .favorites: "Избранное"
        case .watched: "Просмотренное"
        }
    }

    private var subtitle: String {
        switch scope {
        case .all: "Фильмы и сериалы — выберите, что посмотреть"
        case .favorites: "Фильмы и сериалы, отмеченные сердцем"
        case .watched: "Прогресс, таймкоды и время последнего просмотра"
        }
    }

    private var isShowingDiscovery: Bool {
        scope == .all && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var discoveryKinds: [MediaKind] {
        MediaKind.allCases.filter { kindFilter == nil || kindFilter == $0 }
    }

    private var filteredItems: [MediaItem] {
        catalog.items(in: scope).filter { item in
            let matchesKind = kindFilter == nil || item.kind == kindFilter
            let matchesQuery = query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.originalTitle.localizedCaseInsensitiveContains(query)
            return matchesKind && matchesQuery
        }
    }

    private var visibleItems: [MediaItem] {
        Array(filteredItems.prefix(displayLimit))
    }

    private var recentlyWatchedItems: [MediaItem] {
        filteredItems.sorted { first, second in
            let firstDate = catalog.playbackRecords(for: first).first?.updatedAt ?? .distantPast
            let secondDate = catalog.playbackRecords(for: second).first?.updatedAt ?? .distantPast
            return firstDate > secondDate
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    Text(title).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
                Text(isShowingDiscovery ? "Подборки фильмов и сериалов" : subtitle)
                    .font(.system(size: 12)).foregroundStyle(KinoPalette.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    filterButton("Все", kind: nil)
                    filterButton("Фильмы", kind: .movie)
                    filterButton("Сериалы", kind: .series)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isShowingDiscovery {
                HStack(spacing: 32) {
                    HStack(spacing: 0) {
                        ForEach(CatalogCollection.allCases) { item in
                            Button { collection = item } label: {
                                Text(item.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 32)
                                    .foregroundStyle(collection == item ? KinoPalette.accent : KinoPalette.muted)
                                    .background(collection == item ? KinoPalette.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(collection == item ? .isSelected : [])
                        }
                    }
                    .padding(2)
                    .frame(width: 400, height: 36)
                    .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 9))
                    HStack(spacing: 12) {
                        Text("Жанр")
                            .font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
                            .fixedSize()
                        Picker("Жанр", selection: $genre) {
                            ForEach(CatalogGenre.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transaction { $0.animation = nil }
            }

            Group {
            if isShowingDiscovery && model.catalogIsLoading {
                discoveryPlaceholder
            } else if isShowingDiscovery && model.catalogError != nil {
                EmptyState(
                    symbol: "film.stack",
                    title: "Подборки недоступны",
                    message: model.catalogError ?? "Проверьте подключение к Cinemeta.",
                    actionTitle: "Повторить",
                    action: { Task { await model.searchCatalog(query, scope: scope, into: catalog, discovery: discoverySelection) } }
                )
            } else if isShowingDiscovery && !catalog.catalogItems.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 25) {
                        ForEach(discoveryKinds) { kind in
                            discoveryRow(for: kind)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            } else if isShowingDiscovery {
                EmptyState(
                    symbol: "sparkles.tv",
                    title: "Подборки появятся здесь",
                    message: "В этой подборке пока нет карточек. Попробуйте другой жанр.",
                    actionTitle: "Загрузить снова",
                    action: { Task { await model.searchCatalog(query, scope: scope, into: catalog, discovery: discoverySelection) } }
                )
            } else if visibleItems.isEmpty {
                EmptyState(
                    symbol: scope == .favorites ? "heart" : "checkmark.circle",
                    title: scope == .all ? "Ничего не найдено" : "Здесь пока пусто",
                    message: scope == .all
                        ? (query.count < 2 ? "Введите хотя бы два символа для поиска." : "По этому запросу ничего не найдено.")
                        : (scope == .favorites ? "Добавляйте фильмы и сериалы в избранное с помощью значка сердца." : "Отмечайте просмотренные фильмы и серии — они появятся здесь.")
                )
            } else if scope == .watched {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(recentlyWatchedItems) { item in
                            watchedRow(item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            } else {
                VStack(spacing: 16) {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 154, maximum: 220), spacing: 17)], alignment: .leading, spacing: 22) {
                            ForEach(visibleItems) { item in
                                MediaCatalogCard(
                                    item: item,
                                    isFavorite: catalog.isFavorite(item),
                                    progress: catalog.progress(for: item),
                                    onSelect: { selectedItem = item },
                                    onToggleFavorite: { catalog.toggleFavorite(item) }
                                )
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if filteredItems.count > visibleItems.count {
                        Button {
                            displayLimit = min(displayLimit + resultsPageSize, filteredItems.count)
                        } label: {
                            HStack(spacing: 7) {
                                Text("Показать ещё")
                                Text("·")
                                Text("\(filteredItems.count - visibleItems.count)")
                                    .monospacedDigit()
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(KinoPalette.accent)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(KinoPalette.accent.opacity(0.09), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: query + (scope == .all ? discoverySelection.identity : "")) {
            guard scope == .all else { return }
            displayLimit = resultsPageSize
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await model.searchCatalog(query, scope: scope, into: catalog, discovery: discoverySelection)
        }
        .onChange(of: kindFilter) { _, _ in
            displayLimit = resultsPageSize
        }
        .sheet(item: $selectedItem) { item in
            MediaDetailView(item: item, onSearch: onSearch, onPlay: onPlay)
                .environmentObject(model)
                .environmentObject(catalog)
                .frame(minWidth: 730, minHeight: 650)
        }
    }

    private var discoveryPlaceholder: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 25) {
                ForEach(discoveryKinds) { kind in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("\(collection.rawValue) · \(kind == .movie ? "Фильмы" : "Сериалы")")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                        .frame(height: 20)
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 15) {
                                ForEach(0..<6, id: \.self) { _ in
                                    VStack(alignment: .leading, spacing: 9) {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(KinoPalette.card).frame(height: 220)
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.white.opacity(0.07)).frame(width: 130, height: 14)
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.white.opacity(0.04)).frame(width: 90, height: 11)
                                    }
                                    .frame(width: 160)
                                }
                            }
                            .frame(height: 278, alignment: .top)
                            .padding(.bottom, 4)
                        }
                        .frame(height: 282)
                        .scrollIndicators(.hidden)
                        .allowsHitTesting(false)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Загружаем выбранную подборку")
    }

    private func filterButton(_ label: String, kind: MediaKind?) -> some View {
        let selected = kindFilter == kind
        return Button { kindFilter = kind } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? KinoPalette.background : KinoPalette.muted)
                .padding(.horizontal, 11).frame(height: 31)
                .background(selected ? KinoPalette.accent : Color.white.opacity(0.055), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func watchedRow(_ item: MediaItem) -> some View {
        let records = catalog.playbackRecords(for: item)

        return HStack(alignment: .top, spacing: 15) {
            Button { selectedItem = item } label: {
                MediaArtwork(item: item)
                    .frame(width: 82, height: 116)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Button { selectedItem = item } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text("\(item.kind.title) · \(item.year)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(KinoPalette.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { catalog.toggleFavorite(item) } label: {
                        Image(systemName: catalog.isFavorite(item) ? "heart.fill" : "heart")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(catalog.isFavorite(item) ? Color(red: 1, green: 0.46, blue: 0.52) : KinoPalette.muted)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(catalog.isFavorite(item) ? "Убрать из избранного" : "В избранное")
                }

                if records.isEmpty {
                    HStack {
                        Label("Отмечено как просмотренное", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(KinoPalette.accent)
                        Spacer()
                        Button { catalog.removeWatchHistory(for: item) } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(KinoPalette.muted)
                                .frame(width: 25, height: 25)
                        }
                        .buttonStyle(.plain)
                        .help("Убрать из просмотренного")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(records) { record in
                            playbackHistoryRow(record, for: item)
                        }
                    }
                }

                ProgressView(value: catalog.progress(for: item))
                    .tint(KinoPalette.accent)
                Text("Общий прогресс · \(Int(catalog.progress(for: item) * 100))%")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(KinoPalette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(13)
        .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(KinoPalette.line, lineWidth: 1))
    }

    private func playbackHistoryRow(_ record: PlaybackRecord, for item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: record.completed ? "checkmark.circle.fill" : "play.circle.fill")
                    .foregroundStyle(record.completed ? KinoPalette.accent : .white.opacity(0.7))
                Text(playbackTitle(record, for: item))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(record.updatedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .foregroundStyle(KinoPalette.muted)
                    .lineLimit(1)
                Button { onPlay(TorrentSearchTarget(context: record.context)) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(KinoPalette.background)
                        .frame(width: 24, height: 24)
                        .background(KinoPalette.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Открыть из «Моей коллекции» или найти раздачу")
                Button { catalog.removePlaybackRecord(for: record.context) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(KinoPalette.muted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Удалить эту запись из истории")
            }
            HStack(spacing: 8) {
                ProgressView(value: record.fraction)
                    .tint(record.completed ? KinoPalette.accent : Color.white.opacity(0.65))
                Text("\(timecode(record.position)) / \(timecode(record.duration))")
                    .monospacedDigit()
                    .foregroundStyle(KinoPalette.muted)
                    .fixedSize()
            }
        }
        .font(.system(size: 9, weight: .medium))
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }

    private func playbackTitle(_ record: PlaybackRecord, for item: MediaItem) -> String {
        guard let season = record.context.season, let episodeNumber = record.context.episode else {
            return record.completed ? "Фильм просмотрен" : "Продолжить фильм"
        }
        let episodeTitle = item.seasons.first(where: { $0.number == season })?.episodes
            .first(where: { $0.number == episodeNumber })?.title ?? "Серия \(episodeNumber)"
        return String(format: "Сезон %d · Серия %d — %@", season, episodeNumber, episodeTitle)
    }

    private func timecode(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds / 60) % 60
        let remainder = totalSeconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }

    @ViewBuilder
    private func discoveryRow(for kind: MediaKind) -> some View {
        let items = catalog.items(in: .all).filter { $0.kind == kind }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(collection.rawValue) · \(kind == .movie ? "Фильмы" : "Сериалы")")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("CINEMETA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(KinoPalette.muted)
                }
                .frame(height: 20)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(items) { item in
                            MediaCatalogCard(
                                item: item,
                                isFavorite: catalog.isFavorite(item),
                                progress: catalog.progress(for: item),
                                onSelect: { selectedItem = item },
                                onToggleFavorite: { catalog.toggleFavorite(item) }
                            )
                            .frame(width: 160)
                        }
                    }
                    .frame(height: 278, alignment: .top)
                    .padding(.bottom, 4)
                }
                .frame(height: 282)
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct MediaCatalogCard: View {
    let item: MediaItem
    let isFavorite: Bool
    let progress: Double
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                Button(action: onSelect) {
                    MediaArtwork(item: item)
                        .frame(height: 220)
                }
                .buttonStyle(.plain)
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isFavorite ? Color(red: 1, green: 0.46, blue: 0.52) : .white)
                        .frame(width: 31, height: 31)
                        .background(.black.opacity(0.42), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(9)
                .help(isFavorite ? "Убрать из избранного" : "В избранное")
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 0)
                Text(String(item.year)).font(.system(size: 10, weight: .medium)).foregroundStyle(KinoPalette.muted)
            }
            HStack(spacing: 7) {
                Text(item.kind.title)
                Circle().fill(KinoPalette.muted.opacity(0.65)).frame(width: 2, height: 2)
                if item.rating != "—" {
                    Label(item.rating, systemImage: "star.fill").labelStyle(.titleAndIcon)
                        .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.4))
                }
                Spacer(minLength: 0)
                if item.kind == .series { Text("\(item.seasonCount) сез.") }
            }
            .font(.system(size: 9, weight: .medium)).foregroundStyle(KinoPalette.muted)

            if progress > 0 {
                ProgressView(value: progress).tint(KinoPalette.accent)
                    .scaleEffect(x: 1, y: 0.7, anchor: .center)
            }
        }
        .contentShape(Rectangle())
    }
}

struct MediaArtwork: View {
    let item: MediaItem

    private var colors: [Color] {
        switch item.posterStyle {
        case .ocean: [Color(red: 0.1, green: 0.42, blue: 0.53), Color(red: 0.06, green: 0.12, blue: 0.23)]
        case .amber: [Color(red: 0.83, green: 0.47, blue: 0.19), Color(red: 0.24, green: 0.13, blue: 0.2)]
        case .violet: [Color(red: 0.48, green: 0.38, blue: 0.65), Color(red: 0.12, green: 0.13, blue: 0.24)]
        case .forest: [Color(red: 0.18, green: 0.49, blue: 0.37), Color(red: 0.06, green: 0.16, blue: 0.16)]
        case .rose: [Color(red: 0.66, green: 0.27, blue: 0.37), Color(red: 0.17, green: 0.1, blue: 0.19)]
        case .dusk: [Color(red: 0.36, green: 0.49, blue: 0.51), Color(red: 0.12, green: 0.16, blue: 0.22)]
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                if let path = item.posterURL, let url = URL(string: path) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                Circle().fill(.white.opacity(0.1))
                    .frame(width: proxy.size.width * 0.85)
                    .offset(x: proxy.size.width * 0.45, y: -proxy.size.height * 0.36)
                if item.posterURL == nil {
                    Image(systemName: item.posterSymbol)
                        .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.4, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: item.kind == .series ? "rectangle.stack" : "film")
                        Text(item.kind.title.uppercased())
                    }
                    .font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.75))
                    Text(item.title)
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.82)
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
