import Foundation

struct MediaCatalogClient {
    let kinopoiskAPIKey: String

    private var cinemeta: CinemetaClient { CinemetaClient() }
    private var kinopoisk: KinopoiskClient { KinopoiskClient(apiKey: kinopoiskAPIKey) }

    func search(_ query: String, kind: MediaKind? = nil) async throws -> [MediaItem] {
        async let cinemetaResult = capture { try await cinemeta.search(query, kind: kind) }
        async let kinopoiskResult = capture {
            guard !kinopoiskAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KinopoiskError.notConfigured
            }
            return try await kinopoisk.search(query, kind: kind)
        }
        let (cinemetaItems, kinopoiskItems) = await (cinemetaResult, kinopoiskResult)

        switch (cinemetaItems, kinopoiskItems) {
        case (.success(let cinemetaItems), .success(let kinopoiskItems)):
            return Self.mergeSearchResults(cinemetaItems: cinemetaItems, kinopoiskItems: kinopoiskItems)
        case (.success(let cinemetaItems), .failure):
            return cinemetaItems
        case (.failure, .success(let kinopoiskItems)):
            return kinopoiskItems
        case (.failure(let cinemetaError), .failure(let kinopoiskError)):
            throw CatalogProvidersError(
                cinemetaMessage: cinemetaError.localizedDescription,
                kinopoiskMessage: kinopoiskError.localizedDescription
            )
        }
    }

    func discoveryItems(_ selection: CatalogDiscoverySelection) async throws -> [MediaItem] {
        if let kind = selection.kind { return try await cinemeta.discoveryItems(kind: kind, selection: selection) }
        async let movies = capture { try await cinemeta.discoveryItems(kind: .movie, selection: selection) }
        async let series = capture { try await cinemeta.discoveryItems(kind: .series, selection: selection) }
        switch await (movies, series) {
        case (.success(let movies), .success(let series)): return movies + series
        case (.success(let movies), .failure): return movies
        case (.failure, .success(let series)): return series
        case (.failure(let error), .failure): throw error
        }
    }

    func mediaDetails(for item: MediaItem) async throws -> MediaItem {
        var kinopoiskItem: MediaItem?
        var kinopoiskError: Error?
        if item.kinopoiskID != nil, !kinopoiskAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { kinopoiskItem = try await kinopoisk.mediaDetails(for: item) }
            catch { kinopoiskError = error }
        }

        let metadataItem = kinopoiskItem ?? item
        var cinemetaItem: MediaItem?
        var cinemetaError: Error?
        if metadataItem.imdbID?.nilIfBlank != nil {
            do { cinemetaItem = try await cinemeta.mediaDetails(for: metadataItem) }
            catch { cinemetaError = error }
        }

        guard kinopoiskItem != nil || cinemetaItem != nil else {
            if let kinopoiskError, let cinemetaError {
                throw CatalogProvidersError(
                    cinemetaMessage: cinemetaError.localizedDescription,
                    kinopoiskMessage: kinopoiskError.localizedDescription
                )
            }
            if let kinopoiskError { throw kinopoiskError }
            if let cinemetaError { throw cinemetaError }
            throw CatalogProvidersError(
                cinemetaMessage: CinemetaError.missingIMDbID.localizedDescription,
                kinopoiskMessage: KinopoiskError.missingKinopoiskID.localizedDescription
            )
        }

        return Self.mergeDetails(
            source: item,
            kinopoiskItem: kinopoiskItem,
            cinemetaItem: cinemetaItem
        )
    }

    func seasonEpisodes(for item: MediaItem, seasonNumber: Int) async throws -> [MediaEpisode] {
        if let episodes = item.seasons.first(where: { $0.number == seasonNumber })?.episodes, !episodes.isEmpty {
            return episodes
        }

        var kinopoiskError: Error?
        if item.kinopoiskID != nil, !kinopoiskAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { return try await kinopoisk.seasonEpisodes(for: item, seasonNumber: seasonNumber) }
            catch { kinopoiskError = error }
        }

        if item.imdbID?.nilIfBlank != nil {
            do { return try await cinemeta.seasonEpisodes(for: item, seasonNumber: seasonNumber) }
            catch {
                if let kinopoiskError {
                    throw CatalogProvidersError(
                        cinemetaMessage: error.localizedDescription,
                        kinopoiskMessage: kinopoiskError.localizedDescription
                    )
                }
                throw error
            }
        }
        if let kinopoiskError { throw kinopoiskError }
        throw CatalogProvidersError(
            cinemetaMessage: CinemetaError.missingIMDbID.localizedDescription,
            kinopoiskMessage: KinopoiskError.missingKinopoiskID.localizedDescription
        )
    }

    func checkCinemeta() async throws {
        try await cinemeta.checkConnection()
    }

    func checkKinopoisk() async throws {
        try await kinopoisk.checkConnection()
    }

    private func capture<Value>(_ operation: () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private static func mergeSearchResults(cinemetaItems: [MediaItem], kinopoiskItems: [MediaItem]) -> [MediaItem] {
        var results = cinemetaItems
        for kinopoiskItem in kinopoiskItems {
            if let index = results.firstIndex(where: { matches($0, kinopoiskItem) }) {
                results[index] = merge(source: results[index], kinopoiskItem: kinopoiskItem, cinemetaItem: results[index])
            } else {
                results.append(kinopoiskItem)
            }
        }
        return results
    }

    private static func matches(_ first: MediaItem, _ second: MediaItem) -> Bool {
        guard first.kind == second.kind else { return false }
        if let firstIMDbID = first.imdbID?.nilIfBlank,
           let secondIMDbID = second.imdbID?.nilIfBlank,
           firstIMDbID.caseInsensitiveCompare(secondIMDbID) == .orderedSame {
            return true
        }
        let yearsMatch = first.year == 0 || second.year == 0 || first.year == second.year
        guard yearsMatch else { return false }
        let firstTitles = Set([first.title, first.originalTitle].compactMap { normalizedTitle($0) })
        let secondTitles = Set([second.title, second.originalTitle].compactMap { normalizedTitle($0) })
        return !firstTitles.isDisjoint(with: secondTitles)
    }

    private static func normalizedTitle(_ title: String) -> String? {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
        let value = String(folded.lowercased().filter { $0.isLetter || $0.isNumber })
        return value.isEmpty ? nil : value
    }

    private static func merge(source: MediaItem, kinopoiskItem: MediaItem?, cinemetaItem: MediaItem?) -> MediaItem {
        let kp = kinopoiskItem
        let cm = cinemetaItem
        let kpGenres = kp?.genres ?? []
        let cmGenres = cm?.genres ?? []
        let genres = !kpGenres.isEmpty ? kpGenres : (!cmGenres.isEmpty ? cmGenres : source.genres)
        let kpSeasons = kp?.seasons ?? []
        let cmSeasons = cm?.seasons ?? []
        let seasons = !kpSeasons.isEmpty ? kpSeasons : (!cmSeasons.isEmpty ? cmSeasons : source.seasons)
        let seasonCount = max(max(kp?.seasonCount ?? 0, cm?.seasonCount ?? 0), source.seasonCount)
        return MediaItem(
            id: source.id,
            legacyTMDBID: source.legacyTMDBID,
            imdbID: kp?.imdbID?.nilIfBlank ?? cm?.imdbID?.nilIfBlank ?? source.imdbID,
            kinopoiskID: kp?.kinopoiskID ?? source.kinopoiskID,
            title: kp?.title.nilIfBlank ?? cm?.title.nilIfBlank ?? source.title,
            originalTitle: kp?.originalTitle.nilIfBlank ?? cm?.originalTitle.nilIfBlank ?? source.originalTitle,
            year: kp.map { $0.year > 0 ? $0.year : (cm?.year ?? source.year) } ?? source.year,
            kind: source.kind,
            rating: kp?.rating.nilIfBlank ?? cm?.rating.nilIfBlank ?? source.rating,
            genres: genres,
            synopsis: preferredDescription(from: kp?.synopsis) ?? preferredDescription(from: cm?.synopsis) ?? source.synopsis,
            posterStyle: source.posterStyle,
            posterSymbol: source.posterSymbol,
            posterURL: kp?.posterURL ?? cm?.posterURL ?? source.posterURL,
            duration: kp?.duration?.nilIfBlank ?? cm?.duration?.nilIfBlank ?? source.duration,
            seasons: seasons,
            seasonCount: seasonCount,
            hasCompleteEpisodeList: !kpSeasons.isEmpty ? kp?.hasCompleteEpisodeList : (!cmSeasons.isEmpty ? cm?.hasCompleteEpisodeList : source.hasCompleteEpisodeList)
        )
    }

    private static func mergeDetails(source: MediaItem, kinopoiskItem: MediaItem?, cinemetaItem: MediaItem?) -> MediaItem {
        merge(source: source, kinopoiskItem: kinopoiskItem, cinemetaItem: cinemetaItem)
    }

    private static func preferredDescription(from value: String?) -> String? {
        guard let value = value?.nilIfBlank,
              value != "Загружаем описание…",
              value != "Описание пока недоступно." else { return nil }
        return value
    }
}

private struct CatalogProvidersError: LocalizedError {
    let cinemetaMessage: String
    let kinopoiskMessage: String

    var errorDescription: String? {
        "Каталог Cinemeta и Кинопоиска недоступен. Cinemeta: \(cinemetaMessage) Кинопоиск: \(kinopoiskMessage)"
    }
}

extension Optional where Wrapped == String {
    var usableCatalogURL: String? {
        guard let value = self?.nilIfBlank,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if scheme == "http" { components.scheme = "https" }
        return components.url?.absoluteString
    }
}
