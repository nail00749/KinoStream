import Foundation

struct KinopoiskClient {
    let apiKey: String

    private let host = "https://kinopoiskapiunofficial.tech"

    func search(_ query: String, kind: MediaKind? = nil) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            let response: KinopoiskSearchResponse = try await request(
                path: "/api/v2.1/films/search-by-keyword",
                queryItems: [
                    URLQueryItem(name: "keyword", value: trimmed),
                    URLQueryItem(name: "page", value: "1")
                ]
            )
            return (response.films ?? []).compactMap { $0.mediaItem }.filter { kind == nil || $0.kind == kind }
        } catch KinopoiskError.http(404) {
            return []
        }
    }

    func mediaDetails(for item: MediaItem) async throws -> MediaItem {
        guard let kinopoiskID = item.kinopoiskID else { throw KinopoiskError.missingKinopoiskID }
        let response: KinopoiskFilm = try await request(path: "/api/v2.2/films/\(kinopoiskID)")
        let details = response.mediaItem(basedOn: item)
        guard details.kind == .series else { return details }

        guard let seasons = try? await seasonList(for: details), !seasons.isEmpty else { return details }
        return details.with(seasons: seasons)
    }

    func seasonEpisodes(for item: MediaItem, seasonNumber: Int) async throws -> [MediaEpisode] {
        if let cached = item.seasons.first(where: { $0.number == seasonNumber })?.episodes, !cached.isEmpty {
            return cached
        }
        guard item.kinopoiskID != nil else { throw KinopoiskError.missingKinopoiskID }
        let seasons = try await seasonList(for: item)
        return seasons.first(where: { $0.number == seasonNumber })?.episodes ?? []
    }

    func checkConnection() async throws {
        _ = try await search("Матрица", kind: .movie)
    }

    private func seasonList(for item: MediaItem) async throws -> [MediaSeason] {
        guard let kinopoiskID = item.kinopoiskID else { throw KinopoiskError.missingKinopoiskID }
        let response: KinopoiskSeasonResponse = try await request(path: "/api/v2.2/films/\(kinopoiskID)/seasons")
        return (response.items ?? []).map { season in
            let episodes = (season.episodes ?? []).compactMap { episode -> MediaEpisode? in
                guard let number = episode.episodeNumber, number > 0 else { return nil }
                let details = [episode.releaseDate?.nilIfBlank, episode.synopsis?.nilIfBlank]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return MediaEpisode(
                    id: "\(item.id)-s\(season.number)-e\(number)",
                    number: number,
                    title: episode.nameRu?.nilIfBlank ?? episode.nameEn?.nilIfBlank ?? "Серия \(number)",
                    duration: "—",
                    summary: details.isEmpty ? "Описание серии пока недоступно." : details
                )
            }.sorted { $0.number < $1.number }
            return MediaSeason(number: season.number, episodes: episodes)
        }.sorted { $0.number < $1.number }
    }

    private func request<Response: Decodable>(path: String, queryItems: [URLQueryItem] = []) async throws -> Response {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw KinopoiskError.notConfigured }
        guard var components = URLComponents(string: host + path) else { throw KinopoiskError.invalidURL }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw KinopoiskError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-API-KEY")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw KinopoiskError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw KinopoiskError.http(response.statusCode) }
            do { return try JSONDecoder().decode(Response.self, from: data) }
            catch { throw KinopoiskError.invalidResponse }
        } catch let error as KinopoiskError {
            throw error
        } catch {
            throw KinopoiskError.unavailable
        }
    }
}

private struct KinopoiskSearchResponse: Decodable {
    let films: [KinopoiskSearchFilm]?
}

private struct KinopoiskSearchFilm: Decodable {
    let filmId: Int?
    let nameRu: String?
    let nameEn: String?
    let type: String?
    let year: String?
    let description: String?
    let filmLength: String?
    let rating: String?
    let posterUrl: String?
    let posterUrlPreview: String?

    var mediaItem: MediaItem? {
        guard let filmId, filmId > 0,
              let kind = MediaKind(kinopoiskType: type),
              let title = nameRu?.nilIfBlank ?? nameEn?.nilIfBlank else { return nil }
        let styleIndex = String(filmId).utf8.reduce(0) { ($0 + Int($1)) % 6 }
        return MediaItem(
            id: "\(kind.rawValue)-kp-\(filmId)",
            legacyTMDBID: 0,
            kinopoiskID: filmId,
            title: title,
            originalTitle: nameEn?.nilIfBlank ?? title,
            year: Int((year ?? "").prefix(4)) ?? 0,
            kind: kind,
            rating: rating?.validRating ?? "—",
            genres: [],
            synopsis: description?.nilIfBlank ?? "Загружаем описание…",
            posterStyle: PosterStyle(rawValue: styleIndex) ?? .ocean,
            posterSymbol: kind == .movie ? "film" : "rectangle.stack",
            posterURL: (posterUrlPreview ?? posterUrl).usableCatalogURL,
            duration: filmLength?.nilIfBlank,
            seasons: [],
            seasonCount: 0
        )
    }
}

private struct KinopoiskFilm: Decodable {
    let kinopoiskId: Int?
    let imdbId: String?
    let nameRu: String?
    let nameEn: String?
    let nameOriginal: String?
    let ratingKinopoisk: Double?
    let ratingImdb: Double?
    let year: Int?
    let filmLength: Int?
    let description: String?
    let shortDescription: String?
    let type: String?
    let posterUrl: String?
    let posterUrlPreview: String?
    let genres: [KinopoiskGenre]?

    func mediaItem(basedOn item: MediaItem) -> MediaItem {
        let id = kinopoiskId ?? item.kinopoiskID
        let parsedIMDbID = imdbId?.nilIfBlank ?? item.imdbID
        let title = nameRu?.nilIfBlank ?? nameEn?.nilIfBlank ?? item.title
        let originalTitle = nameOriginal?.nilIfBlank ?? nameEn?.nilIfBlank ?? item.originalTitle
        let styleSource = parsedIMDbID ?? (id.map { String($0) } ?? item.id)
        let styleIndex = styleSource.utf8.reduce(0) { ($0 + Int($1)) % 6 }
        return MediaItem(
            id: item.id,
            legacyTMDBID: item.legacyTMDBID,
            imdbID: parsedIMDbID,
            kinopoiskID: id,
            title: title,
            originalTitle: originalTitle,
            year: year ?? item.year,
            kind: MediaKind(kinopoiskType: type) ?? item.kind,
            rating: ratingKinopoisk.map { String(format: "%.1f", $0) } ?? ratingImdb.map { String(format: "IMDb %.1f", $0) } ?? item.rating,
            genres: (genres ?? []).compactMap { $0.genre?.nilIfBlank }.isEmpty ? item.genres : (genres ?? []).compactMap { $0.genre?.nilIfBlank },
            synopsis: description?.nilIfBlank ?? shortDescription?.nilIfBlank ?? item.synopsis,
            posterStyle: PosterStyle(rawValue: styleIndex) ?? item.posterStyle,
            posterSymbol: item.posterSymbol,
            posterURL: (posterUrl ?? posterUrlPreview).usableCatalogURL ?? item.posterURL,
            duration: filmLength.map { "\($0) мин" } ?? item.duration,
            seasons: item.seasons,
            seasonCount: item.seasonCount
        )
    }
}

private struct KinopoiskGenre: Decodable {
    let genre: String?
}

private struct KinopoiskSeasonResponse: Decodable {
    let items: [KinopoiskSeason]?
}

private struct KinopoiskSeason: Decodable {
    let number: Int
    let episodes: [KinopoiskEpisode]?
}

private struct KinopoiskEpisode: Decodable {
    let episodeNumber: Int?
    let nameRu: String?
    let nameEn: String?
    let synopsis: String?
    let releaseDate: String?
}

extension MediaItem {
    func with(seasons: [MediaSeason]) -> MediaItem {
        MediaItem(
            id: id,
            legacyTMDBID: legacyTMDBID,
            imdbID: imdbID,
            kinopoiskID: kinopoiskID,
            title: title,
            originalTitle: originalTitle,
            year: year,
            kind: kind,
            rating: rating,
            genres: genres,
            synopsis: synopsis,
            posterStyle: posterStyle,
            posterSymbol: posterSymbol,
            posterURL: posterURL,
            duration: duration,
            seasons: seasons,
            seasonCount: seasons.count,
            hasCompleteEpisodeList: true
        )
    }
}

private extension String {
    var validRating: String? {
        guard let value = nilIfBlank, Double(value.replacingOccurrences(of: ",", with: ".")) != nil else { return nil }
        return value
    }
}

enum KinopoiskError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case unavailable
    case http(Int)
    case missingKinopoiskID

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Добавьте API-ключ Кинопоиска в настройках."
        case .invalidURL, .invalidResponse: "Кинопоиск API вернул неожиданный ответ."
        case .unavailable: "Не удалось подключиться к Кинопоиск API. Проверьте интернет-соединение."
        case .http(401), .http(403): "Кинопоиск API отклонил ключ. Проверьте его в настройках."
        case .http(402): "Исчерпан лимит запросов Кинопоиск API."
        case .http(429): "Слишком много запросов к Кинопоиск API. Повторите позже."
        case .http(404): "Кинопоиск API не нашёл это название."
        case .http(let status): "Кинопоиск API временно недоступен (HTTP \(status))."
        case .missingKinopoiskID: "Для этого названия нет ID Кинопоиска."
        }
    }
}

private extension MediaKind {
    init?(kinopoiskType: String?) {
        switch kinopoiskType?.uppercased() {
        case "FILM", "VIDEO": self = .movie
        case "TV_SERIES", "MINI_SERIES", "TV_SHOW": self = .series
        default: return nil
        }
    }
}
