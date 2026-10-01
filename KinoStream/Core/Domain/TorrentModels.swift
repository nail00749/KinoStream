import Foundation

struct TorrentFile: Identifiable, Hashable {
    let id: Int
    let path: String
    let length: Int64

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var isPlayable: Bool {
        ["mkv", "mp4", "m4v", "mov", "avi", "webm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    var episodeCoordinates: EpisodeCoordinates? {
        let value = path
        let pairedPatterns = [
            #"(?i)s\s*0*(\d{1,2})\s*[._ -]*e\s*0*(\d{1,3})"#,
            #"(?i)\b(\d{1,2})\s*x\s*(\d{1,3})\b"#,
            #"(?i)season\s*0*(\d{1,2}).{0,30}?(?:episode|ep)\s*0*(\d{1,3})"#,
            #"(?i)0*(\d{1,2})\s*сезон.{0,30}?0*(\d{1,3})\s*сер"#,
            #"(?i)сезон\s*0*(\d{1,2}).{0,30}?(?:серия|эпизод)\s*0*(\d{1,3})"#
        ]
        for pattern in pairedPatterns {
            if let values = Self.capture(pattern, in: value), values.count >= 2 {
                return EpisodeCoordinates(season: values[0], episode: values[1])
            }
        }

        let seasonPatterns = [
            #"(?i)(?:season|сезон)\s*0*(\d{1,2})"#,
            #"(?i)(?:^|[/ ._-])s0*(\d{1,2})(?=$|[/ ._-])"#
        ]
        let season = seasonPatterns.lazy.compactMap { Self.capture($0, in: value)?.first }.first
        let episodePatterns = [
            #"(?i)(?:episode|ep)\s*0*(\d{1,3})"#,
            #"(?i)(?:серия|сер)\s*0*(\d{1,3})"#
        ]
        var episode = episodePatterns.lazy.compactMap { Self.capture($0, in: name)?.first }.first
        if episode == nil, season != nil {
            episode = Self.capture(#"^0*(\d{1,3})(?:[ ._-]|$)"#, in: name)?.first
        }
        guard let episode else { return nil }
        return EpisodeCoordinates(season: season, episode: episode)
    }

    private static func capture(_ pattern: String, in text: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
    }
}

struct CollectionQuery {
    private let words: [String]
    private let season: Int?
    private let episode: Int?
    let isEmpty: Bool

    init(_ query: String) {
        var remaining = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        isEmpty = remaining.isEmpty
        func extract(_ pattern: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)),
                  let numberRange = Range(match.range(at: 1), in: remaining),
                  let fullRange = Range(match.range, in: remaining) else { return nil }
            let number = Int(remaining[numberRange])
            remaining.replaceSubrange(fullRange, with: " ")
            return number
        }
        season = extract(#"(?:сезон\s*|season\s*|\bs)0*(\d{1,2})"#)
        episode = extract(#"(?:серия\s*|эпизод\s*|episode\s*|\bep\s*|\be)0*(\d{1,3})"#)
        words = remaining.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    func matches(title: String, file: TorrentFile? = nil, seasonHint: Int? = nil) -> Bool {
        let coordinates = file?.episodeCoordinates
        if let season, (coordinates?.season ?? seasonHint) != season { return false }
        if let episode, coordinates?.episode != episode { return false }
        let text = title + " " + (file?.path ?? "")
        return words.allSatisfy { text.localizedStandardContains($0) }
    }
}

struct EpisodeCoordinates: Hashable, Codable {
    let season: Int?
    let episode: Int
}

struct Torrent: Identifiable, Hashable {
    let hash: String
    let title: String?
    let name: String?
    let poster: String?
    let statString: String?
    let torrentSize: Int64?
    let loadedSize: Int64?
    let downloadSpeed: Double?
    let activePeers: Int?
    let fileStats: [TorrentFile]

    var id: String { hash }
    var displayTitle: String { title?.nilIfBlank ?? name?.nilIfBlank ?? hash.prefix(12).description }
    var progress: Double {
        guard let torrentSize, torrentSize > 0, let loadedSize else { return 0 }
        return min(1, Double(loadedSize) / Double(torrentSize))
    }
}

struct PlaybackSource: Hashable, Codable {
    let torrentHash: String
    let fileID: Int
}

struct TorrentSearchResult: Identifiable, Hashable, Codable {
    let title: String
    let link: String?
    let size: String?
    let seeders: Int?
    let source: String
    let leechers: Int?
    var sizeBytes: Int64? = nil

    init(title: String, link: String?, size: String?, seeders: Int?, source: String = "JacRed", leechers: Int? = nil, sizeBytes: Int64? = nil) {
        self.title = title
        self.link = link
        self.size = size
        self.seeders = seeders
        self.source = source
        self.leechers = leechers
        self.sizeBytes = sizeBytes
    }

    var id: String { link ?? title }
    var torrentLink: String? { link }
}

struct FavoriteTorrent: Identifiable, Hashable, Codable {
    let result: TorrentSearchResult
    let target: TorrentSearchTarget
    let savedAt: Date

    var id: String { result.id }

    init(result: TorrentSearchResult, target: TorrentSearchTarget, savedAt: Date = .now) {
        self.result = result
        self.target = target
        self.savedAt = savedAt
    }
}

enum PlaybackPlayer: String, CaseIterable, Hashable, Identifiable {
    case builtIn
    case vlc

    var id: String { rawValue }
    var title: String { self == .builtIn ? "Встроенный" : "VLC" }
}

enum TorrentSearchKind: String, Hashable, Codable {
    case movie
    case series
}

struct PlaybackContext: Hashable, Codable {
    let legacyTMDBID: Int
    var imdbID: String? = nil
    var kinopoiskID: Int? = nil
    var mediaItemID: String? = nil
    var kind: TorrentSearchKind
    let title: String
    let originalTitle: String
    let year: Int
    var season: Int? = nil
    var episode: Int? = nil
    var localIdentity: String? = nil

    var itemID: String {
        mediaItemID ?? localIdentity ?? imdbID.map { "\(kind.rawValue)-\($0)" } ?? kinopoiskID.map { "\(kind.rawValue)-kp-\($0)" } ?? "\(kind.rawValue)-\(legacyTMDBID)"
    }
    var progressID: String {
        guard let season, let episode else { return itemID }
        return "\(itemID)-s\(season)-e\(episode)"
    }

    var episodeID: String? {
        guard kind == .series, let season, let episode else { return nil }
        return "\(itemID)-s\(season)-e\(episode)"
    }

    var withoutEpisode: PlaybackContext {
        var updated = self
        if kind == .series {
            updated.episode = nil
        }
        return updated
    }

    func resolvingEpisode(from file: TorrentFile) -> PlaybackContext {
        guard let coordinates = file.episodeCoordinates else { return self }
        var updated = self
        if localIdentity != nil, imdbID == nil, kinopoiskID == nil, legacyTMDBID == 0, coordinates.season != nil {
            updated.kind = .series
            updated.localIdentity = Self.localID(for: title, kind: .series)
        }
        guard updated.kind == .series,
              updated.season != coordinates.season || updated.episode != coordinates.episode else { return updated }
        updated.season = coordinates.season ?? season
        updated.episode = coordinates.episode
        return updated
    }

    private enum CodingKeys: String, CodingKey {
        case legacyTMDBID = "tmdbID"
        case imdbID
        case kinopoiskID
        case mediaItemID
        case kind
        case title
        case originalTitle
        case year
        case season
        case episode
        case localIdentity
    }

    static func localID(for title: String, kind: TorrentSearchKind) -> String {
        let normalized = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = normalized.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return "local-\(kind.rawValue)-\(String(hash, radix: 16))"
    }
}

struct TorrentSearchTarget: Hashable, Codable {
    let query: String
    let kind: TorrentSearchKind?
    let legacyTMDBID: Int?
    let imdbID: String?
    let kinopoiskID: Int?
    let mediaItemID: String?
    let title: String?
    let originalTitle: String?
    let year: Int?
    let season: Int?
    let episode: Int?

    init(context: PlaybackContext) {
        let originalTitle = context.originalTitle.nilIfBlank ?? context.title
        let query: String
        if let season = context.season, let episode = context.episode {
            query = String(format: "%@ S%02dE%02d", originalTitle, season, episode)
        } else if context.year > 0 {
            query = "\(originalTitle) \(context.year)"
        } else {
            query = originalTitle
        }
        self.init(
            query: query,
            kind: context.kind,
            legacyTMDBID: context.legacyTMDBID > 0 ? context.legacyTMDBID : nil,
            imdbID: context.imdbID,
            kinopoiskID: context.kinopoiskID,
            mediaItemID: context.itemID,
            title: context.title,
            originalTitle: originalTitle,
            year: context.year > 0 ? context.year : nil,
            season: context.season,
            episode: context.episode
        )
    }

    init(query: String, kind: TorrentSearchKind? = nil, legacyTMDBID: Int? = nil, imdbID: String? = nil, kinopoiskID: Int? = nil, mediaItemID: String? = nil, title: String? = nil, originalTitle: String? = nil, year: Int? = nil, season: Int? = nil, episode: Int? = nil) {
        self.query = query
        self.kind = kind
        self.legacyTMDBID = legacyTMDBID
        self.imdbID = imdbID
        self.kinopoiskID = kinopoiskID
        self.mediaItemID = mediaItemID
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.season = season
        self.episode = episode
    }

    static func text(_ query: String) -> TorrentSearchTarget {
        TorrentSearchTarget(query: query)
    }

    var playbackContext: PlaybackContext? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if (imdbID?.nilIfBlank != nil || kinopoiskID != nil || (legacyTMDBID ?? 0) > 0 || mediaItemID != nil), let kind, let title {
            return PlaybackContext(
                legacyTMDBID: legacyTMDBID ?? 0,
                imdbID: imdbID,
                kinopoiskID: kinopoiskID,
                mediaItemID: mediaItemID,
                kind: kind,
                title: title,
                originalTitle: originalTitle ?? title,
                year: year ?? 0,
                season: season,
                episode: episode
            )
        }

        let parsedEpisode = TorrentFile(id: -1, path: "\(query).mkv", length: 0).episodeCoordinates
        let resolvedKind = kind ?? (parsedEpisode != nil || season != nil || episode != nil ? .series : .movie)
        let displayTitle = cleanedSearchTitle(title ?? originalTitle ?? query)
        let contextTitle = displayTitle.nilIfBlank ?? query
        return PlaybackContext(
            legacyTMDBID: 0,
            kind: resolvedKind,
            title: contextTitle,
            originalTitle: originalTitle ?? contextTitle,
            year: year ?? 0,
            season: season ?? parsedEpisode?.season,
            episode: episode ?? parsedEpisode?.episode,
            localIdentity: PlaybackContext.localID(for: contextTitle, kind: resolvedKind)
        )
    }

    private func cleanedSearchTitle(_ value: String) -> String {
        let patterns = [
            #"(?i)\bs\s*0*\d{1,2}\s*[._ -]*e\s*0*\d{1,3}\b"#,
            #"(?i)\b\d{1,2}\s*x\s*\d{1,3}\b"#,
            #"(?i)\bseason\s*0*\d{1,2}.{0,30}?(?:episode|ep)\s*0*\d{1,3}\b"#,
            #"(?i)0*\d{1,2}\s*сезон.{0,30}?0*\d{1,3}\s*сер(?:ия|ии)?\b"#,
            #"(?i)сезон\s*0*\d{1,2}.{0,30}?(?:серия|эпизод)\s*0*\d{1,3}\b"#
        ]
        return patterns.reduce(value) { result, pattern in
            result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        .replacingOccurrences(of: #"[._-]{2,}"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "._-")))
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

extension Int64 {
    var fileSizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

extension Double {
    var speedLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(self)) + "/с"
    }
}
