import SwiftUI

struct EpisodePickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let initialQuery: String
    let onSelect: (MediaItem, Int, MediaEpisode) -> Void

    @State private var query: String
    @State private var matches: [MediaItem] = []
    @State private var selectedSeries: MediaItem?
    @State private var selectedSeasonNumber = 1
    @State private var episodes: [MediaEpisode] = []
    @State private var isSearching = false
    @State private var isLoadingSeries = false
    @State private var isLoadingEpisodes = false
    @State private var seriesRequestID = UUID()
    @State private var seasonRequestID = UUID()
    @State private var errorMessage: String?

    init(initialQuery: String, onSelect: @escaping (MediaItem, Int, MediaEpisode) -> Void) {
        self.initialQuery = initialQuery
        self.onSelect = onSelect
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedSeries == nil ? "Выберите сериал" : "Выберите сезон и серию")
                        .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(selectedSeries?.title ?? "После выбора серии найдём раздачу для неё")
                        .font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
                }
                Spacer()
                if selectedSeries != nil {
                    Button { seriesRequestID = UUID(); seasonRequestID = UUID(); selectedSeries = nil; episodes = []; errorMessage = nil } label: {
                        Label("К сериалам", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(KinoPalette.accent)
                }
                Button("Закрыть") { dismiss() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
            }

            if let selectedSeries {
                seriesContent(selectedSeries)
            } else {
                seriesSearch
            }
        }
        .padding(24)
        .background(KinoPalette.background)
        .task { await searchSeries() }
    }

    private var seriesSearch: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(KinoPalette.muted)
                TextField("Название сериала", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await searchSeries() } }
                Button("Найти") { Task { await searchSeries() } }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            .padding(10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

            if isSearching {
                ProgressView("Ищем сериалы…").font(.system(size: 11)).tint(KinoPalette.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                EmptyState(symbol: "exclamationmark.triangle", title: "Не удалось найти сериал", message: errorMessage, actionTitle: "Повторить") {
                    Task { await searchSeries() }
                }
            } else if matches.isEmpty {
                EmptyState(symbol: "rectangle.stack", title: "Сериал не найден", message: "Проверьте название или попробуйте поискать на русском и в оригинале.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(matches) { item in
                            Button { Task { await chooseSeries(item) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "tv")
                                        .font(.system(size: 17, weight: .light))
                                        .foregroundStyle(KinoPalette.accent)
                                        .frame(width: 48, height: 62)
                                        .background(KinoPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                                        Text([item.year > 0 ? String(item.year) : nil, item.originalTitle.nilIfBlank, item.seasonCount > 0 ? "\(item.seasonCount) сез." : nil].compactMap { $0 }.joined(separator: " · "))
                                            .font(.system(size: 10)).foregroundStyle(KinoPalette.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    if isLoadingSeries && selectedSeries?.id == item.id { ProgressView().controlSize(.small) }
                                    else { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(KinoPalette.muted) }
                                }
                                .padding(10)
                                .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingSeries)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func seriesContent(_ item: MediaItem) -> some View {
        if isLoadingSeries {
            ProgressView("Загружаем сезоны…").font(.system(size: 11)).tint(KinoPalette.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            EmptyState(symbol: "exclamationmark.triangle", title: "Не удалось открыть сериал", message: errorMessage, actionTitle: "Повторить") {
                Task { await chooseSeries(item) }
            }
        } else if item.seasons.isEmpty {
            EmptyState(symbol: "rectangle.stack", title: "Нет сезонов", message: "Поставщики каталога не вернули список сезонов для этого сериала.")
        } else {
            VStack(alignment: .leading, spacing: 13) {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(item.seasons) { season in
                            let selected = season.number == selectedSeasonNumber
                            Button { Task { await chooseSeason(season.number, for: item) } } label: {
                                Text(season.number == 0 ? "Спецвыпуски" : "Сезон \(season.number)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(selected ? KinoPalette.background : KinoPalette.muted)
                                    .padding(.horizontal, 11).frame(height: 30)
                                    .background(selected ? KinoPalette.accent : Color.white.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                if isLoadingEpisodes {
                    ProgressView("Загружаем серии…").font(.system(size: 11)).tint(KinoPalette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if episodes.isEmpty {
                EmptyState(symbol: "rectangle.stack", title: "Серий нет", message: "Для выбранного сезона не удалось получить список серий.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(episodes) { episode in
                                Button {
                                    onSelect(item, selectedSeasonNumber, episode)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(String(format: "%02d", episode.number))
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundStyle(KinoPalette.accent).frame(width: 24)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(episode.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                            Text(episode.summary).font(.system(size: 9)).foregroundStyle(KinoPalette.muted).lineLimit(1)
                                        }
                                        Spacer()
                                        Text(episode.duration).font(.system(size: 9)).foregroundStyle(KinoPalette.muted)
                                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(KinoPalette.background)
                                            .frame(width: 25, height: 25).background(KinoPalette.accent, in: Circle())
                                    }
                                    .padding(.horizontal, 11).padding(.vertical, 9)
                                    .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    @MainActor
    private func searchSeries() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { matches = []; return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do { matches = try await model.searchCatalogItems(text) }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func chooseSeries(_ item: MediaItem) async {
        let token = UUID()
        seriesRequestID = token
        isLoadingSeries = true
        selectedSeries = item
        errorMessage = nil
        defer { if seriesRequestID == token { isLoadingSeries = false } }
        do {
            let details = try await model.mediaDetails(for: item)
            guard !Task.isCancelled, seriesRequestID == token else { return }
            selectedSeries = details
            selectedSeasonNumber = details.seasons.first?.number ?? 1
            if let season = details.seasons.first { await chooseSeason(season.number, for: details) }
        } catch {
            guard !Task.isCancelled, seriesRequestID == token else { return }
            selectedSeries = item
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func chooseSeason(_ seasonNumber: Int, for item: MediaItem) async {
        let token = UUID()
        seasonRequestID = token
        selectedSeasonNumber = seasonNumber
        episodes = []
        isLoadingEpisodes = true
        errorMessage = nil
        defer { if seasonRequestID == token { isLoadingEpisodes = false } }
        do {
            let loaded = try await model.seasonEpisodes(for: item, seasonNumber: seasonNumber)
            guard !Task.isCancelled, seasonRequestID == token, selectedSeries?.id == item.id else { return }
            episodes = loaded
        } catch {
            guard !Task.isCancelled, seasonRequestID == token else { return }
            errorMessage = error.localizedDescription
        }
    }
}
