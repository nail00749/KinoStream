import Foundation

struct CinemetaClient {
    private let host = "https://v3-cinemeta.strem.io"

    func search(_ query: String, kind: MediaKind? = nil) async throws -> [MediaItem] {
        if let kind { return try await searchType(query, kind: kind) }

        async let movieResult = captureSearch(query, kind: .movie)
        async let seriesResult = captureSearch(query, kind: .series)
        let (movies, series) = await (movieResult, seriesResult)

        switch (movies, series) {
        case (.success(let movieItems), .success(let seriesItems)):
            return movieItems + seriesItems
        case (.success(let movieItems), .failure):
            return movieItems
        case (.failure, .success(let seriesItems)):
            return seriesItems
        case (.failure(let movieError), .failure(let seriesError)):
            throw CinemetaError.searchFailed("\(movieError.localizedDescription) \(seriesError.localizedDescription)")
        }
    }

    func discoveryItems(kind: MediaKind, selection: CatalogDiscoverySelection) async throws -> [MediaItem] {
        var extra: [String] = []
        if selection.collection == .new {
            extra.append("genre=\(Calendar(identifier: .gregorian).component(.year, from: Date()))")
        } else if let genre = selection.genre.providerValue {
            extra.append("genre=\(genre.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? genre)")
        }
        let suffix = extra.isEmpty ? "" : "/" + extra.joined(separator: "&")
        let response: CinemetaCatalogResponse = try await request(path: "/catalog/\(kind.rawValue)/\(selection.collection.catalogID)\(suffix).json")
        let items = (response.metas ?? []).compactMap { $0.mediaItem(kind: kind) }
        // The year catalog uses its genre parameter for the release year.
        guard selection.collection == .new, let genre = selection.genre.providerValue else { return items }
        return items.filter { $0.genres.contains { $0.caseInsensitiveCompare(genre) == .orderedSame } }
    }

    func mediaDetails(for item: MediaItem) async throws -> MediaItem {
        guard let imdbID = item.imdbID?.nilIfBlank else { throw CinemetaError.missingIMDbID }
        let response: CinemetaMetaResponse = try await request(path: "/meta/\(item.kind.rawValue)/\(imdbID).json")
        guard let meta = response.meta else { throw CinemetaError.itemNotFound }
        return meta.mediaItem(basedOn: item)
    }

    func seasonEpisodes(for item: MediaItem, seasonNumber: Int) async throws -> [MediaEpisode] {
        if let cached = item.seasons.first(where: { $0.number == seasonNumber })?.episodes, !cached.isEmpty {
            return cached
        }
        let detailed = try await mediaDetails(for: item)
        guard let season = detailed.seasons.first(where: { $0.number == seasonNumber }) else { return [] }
        return season.episodes
    }

    func checkConnection() async throws {
        _ = try await searchType("The Matrix", kind: .movie)
    }

    private func captureSearch(_ query: String, kind: MediaKind) async -> Result<[MediaItem], Error> {
        do { return .success(try await searchType(query, kind: kind)) }
        catch { return .failure(error) }
    }

    private func searchType(_ query: String, kind: MediaKind) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(CharacterSet(charactersIn: "-._~"))
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) ?? trimmed
        let path = "/catalog/\(kind.rawValue)/top/search=\(encodedQuery).json"
        let response: CinemetaCatalogResponse = try await request(path: path)
        return (response.metas ?? []).compactMap { $0.mediaItem(kind: kind) }
    }

    private func request<Response: Decodable>(path: String) async throws -> Response {
        guard let url = URL(string: host + path) else { throw CinemetaError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw CinemetaError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw CinemetaError.http(response.statusCode) }
            do { return try JSONDecoder().decode(Response.self, from: data) }
            catch { throw CinemetaError.invalidResponse }
        } catch let error as CinemetaError {
            throw error
        } catch {
            throw CinemetaError.unavailable
        }
    }
}

private struct CinemetaCatalogResponse: Decodable {
    let metas: [CinemetaMeta]?
}

private struct CinemetaMetaResponse: Decodable {
    let meta: CinemetaMeta?
}

private struct CinemetaMeta: Decodable {
    let id: String?
    let type: String?
    let name: String?
    let releaseInfo: String?
    let poster: String?
    let description: String?
    let imdbRating: String?
    let genres: [String]?
    let runtime: String?
    let videos: [CinemetaVideo]?

    func mediaItem(basedOn item: MediaItem) -> MediaItem {
        let episodesBySeason = Dictionary(grouping: (videos ?? []).compactMap { video -> (Int, MediaEpisode)? in
            guard let season = video.season, let number = video.episode else { return nil }
            let released = video.released?.nilIfBlank
            let episode = MediaEpisode(
                id: "\(item.id)-s\(season)-e\(number)",
                number: number,
                title: video.title?.nilIfBlank ?? "Серия \(number)",
                duration: video.runtime?.nilIfBlank ?? "—",
                summary: video.overview?.nilIfBlank ?? released ?? "Описание серии пока недоступно."
            )
            return (season, episode)
        }, by: { $0.0 })

        let seasons = episodesBySeason.keys.sorted().map { number in
            MediaSeason(number: number, episodes: (episodesBySeason[number] ?? []).map { $0.1 }.sorted { $0.number < $1.number })
        }
        let parsedYear = Int((releaseInfo ?? "").prefix(4)) ?? item.year
        return MediaItem(
            id: item.id,
            legacyTMDBID: item.legacyTMDBID,
            imdbID: id?.nilIfBlank ?? item.imdbID,
            kinopoiskID: item.kinopoiskID,
            title: item.title,
            originalTitle: item.originalTitle,
            year: parsedYear,
            kind: item.kind,
            rating: imdbRating?.nilIfBlank ?? item.rating,
            genres: genres?.isEmpty == false ? (genres ?? []) : item.genres,
            synopsis: description?.nilIfBlank ?? item.synopsis,
            posterStyle: item.posterStyle,
            posterSymbol: item.posterSymbol,
            posterURL: poster.usableCatalogURL ?? item.posterURL,
            duration: runtime?.nilIfBlank ?? item.duration,
            seasons: seasons.isEmpty ? item.seasons : seasons,
            seasonCount: max(seasons.count, item.seasonCount),
            hasCompleteEpisodeList: videos == nil ? item.hasCompleteEpisodeList : true
        )
    }
}

private struct CinemetaVideo: Decodable {
    let title: String?
    let released: String?
    let season: Int?
    let episode: Int?
    let overview: String?
    let runtime: String?
}

extension CinemetaMeta {
    func mediaItem(kind: MediaKind) -> MediaItem? {
        guard let id = id?.nilIfBlank, id.hasPrefix("tt"), let title = name?.nilIfBlank else { return nil }
        let parsedYear = Int((releaseInfo ?? "").prefix(4)) ?? 0
        let styleIndex = id.utf8.reduce(0) { ($0 + Int($1)) % 6 }
        return MediaItem(
            id: "\(kind.rawValue)-\(id)",
            legacyTMDBID: 0,
            imdbID: id,
            title: title,
            originalTitle: title,
            year: parsedYear,
            kind: kind,
            rating: imdbRating?.nilIfBlank ?? "—",
            genres: genres ?? [],
            synopsis: description?.nilIfBlank ?? "Загружаем описание…",
            posterStyle: PosterStyle(rawValue: styleIndex) ?? .ocean,
            posterSymbol: kind == .movie ? "film" : "rectangle.stack",
            posterURL: poster.usableCatalogURL,
            duration: runtime?.nilIfBlank,
            seasons: [],
            seasonCount: 0
        )
    }
}

enum CinemetaError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unavailable
    case http(Int)
    case itemNotFound
    case missingIMDbID
    case searchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL, .invalidResponse: "Cinemeta вернул неожиданный ответ."
        case .unavailable: "Не удалось подключиться к каталогу Cinemeta. Проверьте интернет-соединение."
        case .http(let status): "Cinemeta временно недоступен (HTTP \(status))."
        case .itemNotFound: "Cinemeta не нашёл сведения об этом названии."
        case .missingIMDbID: "Для этого названия нет IMDb ID, необходимого Cinemeta."
        case .searchFailed(let details): "Поиск Cinemeta не сработал: \(details)"
        }
    }
}
