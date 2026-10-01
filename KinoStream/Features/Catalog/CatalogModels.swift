import Foundation
import SwiftUI

enum MediaKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case movie
    case series

    var id: String { rawValue }
    var title: String { self == .movie ? "Фильм" : "Сериал" }
}

enum CatalogScope: Equatable {
    case all
    case favorites
    case watched
}

enum PosterStyle: Int, Hashable, Codable {
    case ocean
    case amber
    case violet
    case forest
    case rose
    case dusk
}

struct MediaEpisode: Identifiable, Hashable, Codable {
    let id: String
    let number: Int
    let title: String
    let duration: String
    let summary: String
}

struct MediaSeason: Identifiable, Hashable, Codable {
    let number: Int
    let episodeCount: Int
    var episodes: [MediaEpisode]

    var id: Int { number }

    init(number: Int, episodeCount: Int = 0, episodes: [MediaEpisode] = []) {
        self.number = number
        self.episodeCount = max(episodeCount, episodes.count)
        self.episodes = episodes
    }
}

struct MediaItem: Identifiable, Hashable, Codable {
    let id: String
    let legacyTMDBID: Int
    var imdbID: String? = nil
    var kinopoiskID: Int? = nil
    let title: String
    let originalTitle: String
    let year: Int
    let kind: MediaKind
    let rating: String
    let genres: [String]
    let synopsis: String
    let posterStyle: PosterStyle
    let posterSymbol: String
    let posterURL: String?
    let duration: String?
    var seasons: [MediaSeason]
    var seasonCount: Int
    var hasCompleteEpisodeList: Bool? = nil

    var hasMetadataID: Bool { legacyTMDBID > 0 || imdbID?.nilIfBlank != nil || kinopoiskID != nil }

    var episodeCount: Int {
        seasons.reduce(0) { $0 + $1.episodeCount }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case legacyTMDBID = "tmdbID"
        case imdbID
        case kinopoiskID
        case title
        case originalTitle
        case year
        case kind
        case rating
        case genres
        case synopsis
        case posterStyle
        case posterSymbol
        case posterURL
        case duration
        case seasons
        case seasonCount
        case hasCompleteEpisodeList
    }
}

struct PlaybackRecord: Identifiable, Hashable, Codable {
    let context: PlaybackContext
    var position: Double
    var duration: Double
    var completed: Bool
    var updatedAt: Date

    var id: String { context.progressID }
    var fraction: Double {
        guard duration > 0 else { return completed ? 1 : 0 }
        return min(1, max(0, position / duration))
    }
}

struct CatalogSyncSnapshot: Codable {
    var updatedAt: Date
    var favoriteIDs: [String]
    var watchedItemIDs: [String]
    var watchedEpisodeIDs: [String]
    var playbackRecords: [String: PlaybackRecord]
    var cachedItems: [MediaItem]

    static let empty = CatalogSyncSnapshot(
        updatedAt: .distantPast,
        favoriteIDs: [],
        watchedItemIDs: [],
        watchedEpisodeIDs: [],
        playbackRecords: [:],
        cachedItems: []
    )


}

extension CatalogSyncSnapshot {
    private enum SnapshotKeys: String, CodingKey {
        case updatedAt, favoriteIDs, watchedItemIDs, watchedEpisodeIDs, playbackRecords, cachedItems
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: SnapshotKeys.self)
        self.init(
            updatedAt: try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast,
            favoriteIDs: try values.decodeIfPresent([String].self, forKey: .favoriteIDs) ?? [],
            watchedItemIDs: try values.decodeIfPresent([String].self, forKey: .watchedItemIDs) ?? [],
            watchedEpisodeIDs: try values.decodeIfPresent([String].self, forKey: .watchedEpisodeIDs) ?? [],
            playbackRecords: try values.decodeIfPresent([String: PlaybackRecord].self, forKey: .playbackRecords) ?? [:],
            cachedItems: try values.decodeIfPresent([MediaItem].self, forKey: .cachedItems) ?? []
        )
    }
}

private extension MediaItem {
    var syncMetadataScore: Int {
        (imdbID == nil ? 0 : 1)
            + (kinopoiskID == nil ? 0 : 1)
            + (posterURL == nil ? 0 : 1)
            + (synopsis == "Описание пока недоступно." || synopsis == "Загружаем описание…" ? 0 : 1)
            + min(seasonCount, 100)
            + min(episodeCount, 100)
    }
}

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var favoriteIDs: Set<String>
    @Published private(set) var watchedItemIDs: Set<String>
    @Published private(set) var watchedEpisodeIDs: Set<String>
    @Published private(set) var catalogItems: [MediaItem]
    @Published private(set) var cachedItems: [MediaItem]
    @Published private(set) var playbackRecords: [String: PlaybackRecord]
    @Published private(set) var favoriteTorrents: [FavoriteTorrent]

    private let defaults = UserDefaults.standard
    private let cacheKey = "catalog.cachedItems"
    private let playbackKey = "catalog.playbackRecords"
    private let playbackSourcesKey = "catalog.playbackSources"
    private let torrentContextKey = "catalog.torrentContexts"
    private let savedTorrentsKey = "torrent.savedResults"
    private let cloudModifiedAtKey = "catalog.cloudModifiedAt"
    private var preferredSeriesSources: [String: String]
    private let preferredSeriesSourcesKey = "catalog.preferredSeriesSources"
    private var torrentContexts: [String: PlaybackContext]
    private var playbackSources: [String: PlaybackSource]
    private var cloudModifiedAt: Date
    private var suppressedPlaybackIDs: Set<String> = []
    private var syncEntries: [String: LibrarySyncEntry] = [:]
    private let syncEntriesKey = "catalog.syncEntries.v2"
    private var cloudSyncHandler: (@MainActor () -> Void)?
    private(set) var cloudSyncRevision: UInt64 = 0

    init() {
        preferredSeriesSources = defaults.dictionary(forKey: preferredSeriesSourcesKey) as? [String: String] ?? [:]
        cloudModifiedAt = defaults.object(forKey: cloudModifiedAtKey) as? Date ?? .distantPast
        favoriteIDs = Set(defaults.stringArray(forKey: "catalog.favoriteIDs") ?? [])
        watchedItemIDs = Set(defaults.stringArray(forKey: "catalog.watchedItemIDs") ?? [])
        watchedEpisodeIDs = Set(defaults.stringArray(forKey: "catalog.watchedEpisodeIDs") ?? [])
        if let data = defaults.data(forKey: playbackKey),
           let records = try? JSONDecoder().decode([String: PlaybackRecord].self, from: data) {
            playbackRecords = records
        } else {
            playbackRecords = [:]
        }
        if let data = defaults.data(forKey: torrentContextKey),
           let contexts = try? JSONDecoder().decode([String: PlaybackContext].self, from: data) {
            torrentContexts = contexts
        } else {
            torrentContexts = [:]
        }
        if let data = defaults.data(forKey: playbackSourcesKey),
           let sources = try? JSONDecoder().decode([String: PlaybackSource].self, from: data) {
            playbackSources = sources
        } else {
            playbackSources = [:]
        }
        if let data = defaults.data(forKey: savedTorrentsKey),
           let saved = try? JSONDecoder().decode([FavoriteTorrent].self, from: data) {
            favoriteTorrents = saved
        } else {
            favoriteTorrents = []
        }
        if let data = defaults.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([MediaItem].self, from: data) {
            catalogItems = cached.filter(\.hasMetadataID)
            cachedItems = cached
        } else {
            catalogItems = []
            cachedItems = []
        }
        if let data = defaults.data(forKey: syncEntriesKey),
           let entries = try? JSONDecoder().decode([String: LibrarySyncEntry].self, from: data) {
            syncEntries = entries
        } else {
            syncEntries = LibrarySyncEntry.entries(from: cloudSyncSnapshot())
            persistSyncEntries()
        }
    }

    func replaceCatalog(with items: [MediaItem]) {
        catalogItems = items
        for item in items { cache(item) }
        persistCatalog()
    }

    func update(_ item: MediaItem) {
        let previous = self.item(id: item.id)
        if item.hasMetadataID {
            if let index = catalogItems.firstIndex(where: { $0.id == item.id }) {
                catalogItems[index] = item
            } else {
                catalogItems.append(item)
            }
        } else if let index = catalogItems.firstIndex(where: { $0.id == item.id }) {
            catalogItems.remove(at: index)
        }
        cache(item)
        persistCatalog()
        if previous != self.item(id: item.id), syncEntries["metadata:\(item.id)"] != nil {
            markCloudSyncChanged()
        }
    }

    func item(id: String) -> MediaItem? {
        cachedItems.first { $0.id == id }
    }

    func isFavorite(_ result: TorrentSearchResult) -> Bool {
        favoriteTorrents.contains { $0.id == result.id }
    }

    func toggleFavorite(_ result: TorrentSearchResult, target: TorrentSearchTarget) {
        guard result.torrentLink != nil else { return }
        if let index = favoriteTorrents.firstIndex(where: { $0.id == result.id }) {
            favoriteTorrents.remove(at: index)
        } else {
            favoriteTorrents.insert(FavoriteTorrent(result: result, target: target), at: 0)
        }
        persistFavoriteTorrents()
    }

    func removeFavoriteTorrent(id: String) {
        guard favoriteTorrents.contains(where: { $0.id == id }) else { return }
        favoriteTorrents.removeAll { $0.id == id }
        persistFavoriteTorrents()
    }

    func setCloudSyncHandler(_ handler: (@MainActor () -> Void)?) {
        cloudSyncHandler = handler
    }

    func cloudSyncSnapshot() -> CatalogSyncSnapshot {
        let episodeItemIDs = Set(cachedItems.compactMap { item in
            watchedEpisodeIDs.contains(where: { $0.hasPrefix("\(item.id)-s") }) ? item.id : nil
        })
        let trackedIDs = favoriteIDs
            .union(watchedItemIDs)
            .union(episodeItemIDs)
            .union(playbackRecords.values.map { $0.context.itemID })
        let trackedItems = cachedItems.filter { trackedIDs.contains($0.id) }

        return CatalogSyncSnapshot(
            updatedAt: cloudModifiedAt,
            favoriteIDs: favoriteIDs.sorted(),
            watchedItemIDs: watchedItemIDs.sorted(),
            watchedEpisodeIDs: watchedEpisodeIDs.sorted(),
            playbackRecords: playbackRecords,
            cachedItems: trackedItems
        )
    }

    func applyCloudSyncSnapshot(_ snapshot: CatalogSyncSnapshot, replacingLocalLibrary: Bool) {
        favoriteIDs = Set(snapshot.favoriteIDs)
        watchedItemIDs = Set(snapshot.watchedItemIDs)
        watchedEpisodeIDs = Set(snapshot.watchedEpisodeIDs)
        playbackRecords = snapshot.playbackRecords
        // Keep discovery/search metadata while updating the user's tracked cards.
        for item in snapshot.cachedItems { cache(item) }
        cloudModifiedAt = snapshot.updatedAt
        defaults.set(cloudModifiedAt, forKey: cloudModifiedAtKey)
        defaults.set(favoriteIDs.sorted(), forKey: "catalog.favoriteIDs")
        persistCatalog()
        persistWatched()
        persistPlayback()
    }

    func cloudEntries() -> [LibrarySyncEntry] {
        syncEntries.values.sorted { $0.key < $1.key }
    }

    func mergeCloudEntries(_ incoming: [LibrarySyncEntry]) {
        for entry in incoming {
            if syncEntries[entry.key].map({ entry.isNewer(than: $0) }) ?? true {
                syncEntries[entry.key] = entry
                if entry.deleted, entry.key.hasPrefix("playback:") {
                    suppressedPlaybackIDs.insert(String(entry.key.dropFirst("playback:".count)))
                }
            }
        }
        applyCloudSyncSnapshot(LibrarySyncEntry.snapshot(from: syncEntries), replacingLocalLibrary: true)
        persistSyncEntries()
    }

    /// Switch local data before showing a newly authenticated account, even when offline.
    func activateAccount(_ userID: UUID) {
        let ownerKey = "catalog.cloudOwnerUserID"
        let nextID = userID.uuidString
        let previousID = defaults.string(forKey: ownerKey)
        guard previousID != nextID else { return }
        if let previousID {
            let archive = AccountLibrary(snapshot: cloudSyncSnapshot(), entries: syncEntries,
                favoriteTorrents: favoriteTorrents, torrentContexts: torrentContexts, playbackSources: playbackSources, preferredSeriesSources: preferredSeriesSources)
            if let data = try? JSONEncoder().encode(archive) {
                defaults.set(data, forKey: "catalog.account.\(previousID)")
            }
            suppressedPlaybackIDs = []
            cachedItems = []
            catalogItems = []
            favoriteTorrents = []
            torrentContexts = [:]
            preferredSeriesSources = [:]
            playbackSources = [:]
            syncEntries = [:]
            applyCloudSyncSnapshot(.empty, replacingLocalLibrary: true)
            if let data = defaults.data(forKey: "catalog.account.\(nextID)"),
               let archive = try? JSONDecoder().decode(AccountLibrary.self, from: data) {
                syncEntries = archive.entries
                favoriteTorrents = archive.favoriteTorrents
                torrentContexts = archive.torrentContexts
                preferredSeriesSources = archive.preferredSeriesSources ?? [:]
                playbackSources = archive.playbackSources
                applyCloudSyncSnapshot(archive.snapshot, replacingLocalLibrary: true)
            }
            persistFavoriteTorrents()
            defaults.set(preferredSeriesSources, forKey: preferredSeriesSourcesKey)
            if let data = try? JSONEncoder().encode(torrentContexts) { defaults.set(data, forKey: torrentContextKey) }
            if let data = try? JSONEncoder().encode(playbackSources) { defaults.set(data, forKey: playbackSourcesKey) }
            persistSyncEntries()
        }
        defaults.set(nextID, forKey: ownerKey)
        cloudSyncRevision &+= 1
    }

    func link(_ torrent: Torrent, to item: MediaItem, seasonHint: Int, movieFileID: Int) {
        cache(item)
        let context = PlaybackContext(
            legacyTMDBID: item.legacyTMDBID, imdbID: item.imdbID, kinopoiskID: item.kinopoiskID,
            mediaItemID: item.id, kind: item.kind == .series ? .series : .movie,
            title: item.title, originalTitle: item.originalTitle, year: item.year,
            season: item.kind == .series ? seasonHint : nil
        )
        let hash = torrent.hash.lowercased()
        let oldSources = playbackSources.filter { $0.value.torrentHash == hash }
        // Remove previous per-file contexts so they cannot override the new card.
        for key in oldSources.keys { playbackSources.removeValue(forKey: key) }
        associate(torrentHash: hash, with: context)
        preferSeriesSource(torrentHash: hash, for: context)
        for file in torrent.fileStats.filter(\.isPlayable) {
            guard item.kind == .series || file.id == movieFileID else { continue }
            let resolved = context.resolvingEpisode(from: file)
            guard resolved.kind == .movie || resolved.episodeID != nil else { continue }
            let previousIDs = oldSources.filter { $0.value.fileID == file.id }.keys
            for id in previousIDs {
                guard let previous = playbackRecords[id],
                      previous.context.imdbID == nil, previous.context.kinopoiskID == nil,
                      previous.context.legacyTMDBID == 0 else { continue }
                // Only migrate locally identified history; canonical cards retain their history.
                let migrated = PlaybackRecord(context: resolved, position: previous.position,
                    duration: previous.duration, completed: previous.completed, updatedAt: previous.updatedAt)
                if playbackRecords[resolved.progressID].map({ $0.updatedAt < previous.updatedAt }) ?? true {
                    playbackRecords[resolved.progressID] = migrated
                }
                if previous.completed || previous.context.episodeID.map(watchedEpisodeIDs.contains) == true {
                    if let episodeID = resolved.episodeID { watchedEpisodeIDs.insert(episodeID) }
                    else if resolved.kind == .movie { watchedItemIDs.insert(resolved.itemID) }
                }
                if favoriteIDs.remove(previous.context.itemID) != nil { favoriteIDs.insert(item.id) }
                if id != resolved.progressID {
                    playbackRecords.removeValue(forKey: id)
                    if let episodeID = previous.context.episodeID { watchedEpisodeIDs.remove(episodeID) }
                    if previous.context.kind == .movie { watchedItemIDs.remove(previous.context.itemID) }
                }
            }
            if resolved.kind == .movie || resolved.episodeID != nil {
                associatePlaybackSource(torrentHash: hash, fileID: file.id, with: resolved)
            }
        }
        if let data = try? JSONEncoder().encode(playbackSources) { defaults.set(data, forKey: playbackSourcesKey) }
        defaults.set(favoriteIDs.sorted(), forKey: "catalog.favoriteIDs")
        persistCatalog()
        persistPlayback()
        persistWatched()
        markCloudSyncChanged()
    }

    func preferSeriesSource(torrentHash: String, for context: PlaybackContext) {
        guard context.kind == .series, let season = context.season else { return }
        preferredSeriesSources["\(context.itemID)-s\(season)"] = torrentHash.lowercased()
        defaults.set(preferredSeriesSources, forKey: preferredSeriesSourcesKey)
    }

    func preferredSeriesSource(for context: PlaybackContext) -> String? {
        guard context.kind == .series, let season = context.season else { return nil }
        let key = "\(context.itemID)-s\(season)"
        if let preferred = preferredSeriesSources[key] { return preferred }
        // Upgrade existing libraries from the latest local source in this season.
        return playbackRecords.values.filter { $0.context.itemID == context.itemID && $0.context.season == season }
            .sorted { $0.updatedAt > $1.updatedAt }.compactMap { playbackSources[$0.id]?.torrentHash }.first
    }

    func associate(torrentHash: String, with context: PlaybackContext) {
        torrentContexts[torrentHash.lowercased()] = context.withoutEpisode
        guard let data = try? JSONEncoder().encode(torrentContexts) else { return }
        defaults.set(data, forKey: torrentContextKey)
    }

    func playbackContext(forTorrentHash hash: String) -> PlaybackContext? {
        torrentContexts[hash.lowercased()]
    }

    func playbackContext(forTorrentHash hash: String, fileID: Int) -> PlaybackContext? {
        guard let progressID = playbackSources.first(where: { $0.value.torrentHash == hash.lowercased() && $0.value.fileID == fileID })?.key else { return nil }
        if let record = playbackRecords[progressID] { return record.context }
        guard var context = torrentContexts[hash.lowercased()] else { return nil }
        if progressID == context.itemID { return context }
        guard progressID.hasPrefix(context.itemID + "-"),
              let coordinates = TorrentFile(id: fileID, path: String(progressID.dropFirst(context.itemID.count + 1)) + ".mkv", length: 0).episodeCoordinates else { return nil }
        context.season = coordinates.season
        context.episode = coordinates.episode
        return context
    }

    func associatePlaybackSource(torrentHash: String, fileID: Int, with context: PlaybackContext) {
        playbackSources[context.progressID] = PlaybackSource(torrentHash: torrentHash.lowercased(), fileID: fileID)
        guard let data = try? JSONEncoder().encode(playbackSources) else { return }
        defaults.set(data, forKey: playbackSourcesKey)
    }

    func playbackSource(for context: PlaybackContext) -> PlaybackSource? {
        playbackSources[context.progressID]
    }

    func playbackRecord(for context: PlaybackContext) -> PlaybackRecord? {
        playbackRecords[context.progressID]
    }

    func playbackRecords(for item: MediaItem) -> [PlaybackRecord] {
        playbackRecords.values
            .filter { $0.context.itemID == item.id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func resumePosition(for context: PlaybackContext) -> Double {
        if watchedItemIDs.contains(context.itemID) { return 0 }
        if let episodeID = context.episodeID, watchedEpisodeIDs.contains(episodeID) { return 0 }
        guard let record = playbackRecord(for: context), !record.completed else { return 0 }
        return record.position
    }

    func beginPlayback(_ context: PlaybackContext) {
        suppressedPlaybackIDs.remove(context.progressID)
    }

    func recordPlayback(context: PlaybackContext, position: Double, duration: Double) {
        guard position.isFinite, position >= 0, !suppressedPlaybackIDs.contains(context.progressID) else { return }
        ensureCachedItem(for: context, duration: duration)

        let isCompleted = duration > 0 && position >= duration * 0.9
        let record = PlaybackRecord(
            context: context,
            position: position,
            duration: duration.isFinite ? max(0, duration) : 0,
            completed: isCompleted,
            updatedAt: .now
        )
        playbackRecords[context.progressID] = record

        if isCompleted {
            if context.kind == .movie {
                watchedItemIDs.insert(context.itemID)
            } else if let episodeID = context.episodeID {
                watchedEpisodeIDs.insert(episodeID)
            }
        }

        persistPlayback()
        persistWatched()
        markCloudSyncChanged()
    }

    func removePlaybackRecord(for context: PlaybackContext) {
        guard playbackRecords.removeValue(forKey: context.progressID) != nil else { return }
        suppressedPlaybackIDs.insert(context.progressID)

        if context.kind == .series, let episodeID = context.episodeID {
            watchedEpisodeIDs.remove(episodeID)
        }
        watchedItemIDs.remove(context.itemID)

        persistPlayback()
        persistWatched()
        markCloudSyncChanged()
    }

    func removeWatchHistory(for item: MediaItem) {
        let hasWatchedItem = watchedItemIDs.remove(item.id) != nil
        let matchingEpisodeIDs = watchedEpisodeIDs.filter { $0.hasPrefix("\(item.id)-s") }
        for episodeID in matchingEpisodeIDs {
            watchedEpisodeIDs.remove(episodeID)
        }
        let matchingRecordIDs = playbackRecords.compactMap { id, record in
            record.context.itemID == item.id ? id : nil
        }
        for id in matchingRecordIDs {
            suppressedPlaybackIDs.insert(id)
            playbackRecords.removeValue(forKey: id)
        }

        guard hasWatchedItem || !matchingEpisodeIDs.isEmpty || !matchingRecordIDs.isEmpty else { return }
        persistPlayback()
        persistWatched()
        markCloudSyncChanged()
    }

    func isFavorite(_ item: MediaItem) -> Bool {
        favoriteIDs.contains(item.id)
    }

    func toggleFavorite(_ item: MediaItem) {
        update(item)
        if !favoriteIDs.insert(item.id).inserted { favoriteIDs.remove(item.id) }
        defaults.set(favoriteIDs.sorted(), forKey: "catalog.favoriteIDs")
        markCloudSyncChanged()
    }

    func isWatched(_ item: MediaItem) -> Bool {
        watchedItemIDs.contains(item.id)
            || watchedEpisodeIDs.contains { $0.hasPrefix("\(item.id)-s") }
            || playbackRecords.values.contains { $0.context.itemID == item.id && $0.position > 0 }
    }

    func isWatched(_ context: PlaybackContext) -> Bool {
        watchedItemIDs.contains(context.itemID)
            || context.episodeID.map(watchedEpisodeIDs.contains) == true
    }

    func isExplicitlyWatched(_ item: MediaItem) -> Bool {
        watchedItemIDs.contains(item.id)
    }

    func isFullyWatched(_ item: MediaItem) -> Bool {
        if watchedItemIDs.contains(item.id) { return true }
        guard item.hasCompleteEpisodeList == true, item.kind == .series, item.episodeCount > 0 else { return false }
        let loadedEpisodes = item.seasons.flatMap(\.episodes)
        guard loadedEpisodes.count >= item.episodeCount else { return false }
        return loadedEpisodes.allSatisfy { watchedEpisodeIDs.contains($0.id) }
    }

    func isWatched(_ episode: MediaEpisode, in item: MediaItem) -> Bool {
        watchedItemIDs.contains(item.id) || watchedEpisodeIDs.contains(episode.id)
    }

    func toggleWatched(_ item: MediaItem) {
        update(item)
        if item.kind == .series {
            if isFullyWatched(item) {
                watchedItemIDs.remove(item.id)
                watchedEpisodeIDs.subtract(item.seasons.flatMap(\.episodes).map(\.id))
                clearPlaybackRecords(for: item.id)
            } else {
                watchedItemIDs.insert(item.id)
            }
        } else if !watchedItemIDs.insert(item.id).inserted {
            watchedItemIDs.remove(item.id)
            clearPlaybackRecords(for: item.id)
        }
        persistWatched()
        markCloudSyncChanged()
    }

    func toggleWatched(_ episode: MediaEpisode, in item: MediaItem) {
        update(item)
        if watchedItemIDs.remove(item.id) != nil {
            watchedEpisodeIDs.formUnion(item.seasons.flatMap(\.episodes).map(\.id))
        }
        if !watchedEpisodeIDs.insert(episode.id).inserted {
            watchedEpisodeIDs.remove(episode.id)
            clearPlaybackRecord(for: episode.id)
        }
        persistWatched()
        markCloudSyncChanged()
    }

    func progress(for item: MediaItem) -> Double {
        if watchedItemIDs.contains(item.id) { return 1 }
        if item.kind == .movie { return playbackRecords[item.id]?.fraction ?? 0 }
        guard item.hasMetadataID, item.episodeCount > 0 else { return 0 }

        let episodes = item.seasons.flatMap(\.episodes)
        if episodes.count >= item.episodeCount {
            let total = episodes.reduce(0.0) { result, episode in
                if watchedEpisodeIDs.contains(episode.id) { return result + 1 }
                return result + (playbackRecords[episode.id]?.fraction ?? 0)
            }
            return max(playbackRecords[item.id]?.fraction ?? 0, min(1, total / Double(item.episodeCount)))
        }

        let episodeRecords = playbackRecords.values.filter { $0.context.itemID == item.id && $0.context.episodeID != nil }
        let watchedIDs = Set(watchedEpisodeIDs.filter { $0.hasPrefix("\(item.id)-s") })
        let watchedProgress = Double(watchedIDs.count)
        let partialProgress = episodeRecords
            .filter { !watchedIDs.contains($0.id) }
            .reduce(0.0) { $0 + $1.fraction }
        return max(playbackRecords[item.id]?.fraction ?? 0, min(1, (watchedProgress + partialProgress) / Double(item.episodeCount)))
    }

    func items(in scope: CatalogScope) -> [MediaItem] {
        switch scope {
        case .all:
            catalogItems.filter(\.hasMetadataID)
        case .favorites:
            cachedItems.filter { favoriteIDs.contains($0.id) }
        case .watched:
            cachedItems.filter(isWatched)
        }
    }

    private func cache(_ item: MediaItem) {
        if let index = cachedItems.firstIndex(where: { $0.id == item.id }) {
            let existing = cachedItems[index]
            var enriched = item
            if item.seasons.isEmpty || (item.hasCompleteEpisodeList != true && existing.hasCompleteEpisodeList == true) {
                enriched.seasons = existing.seasons
                enriched.seasonCount = max(item.seasonCount, existing.seasonCount)
                enriched.hasCompleteEpisodeList = existing.hasCompleteEpisodeList
            }
            cachedItems[index] = enriched
        } else {
            cachedItems.append(item)
        }
    }

    private func ensureCachedItem(for context: PlaybackContext, duration: Double) {
        let kind: MediaKind = context.kind == .movie ? .movie : .series
        var cached = item(id: context.itemID) ?? MediaItem(
            id: context.itemID,
            legacyTMDBID: context.legacyTMDBID,
            imdbID: context.imdbID,
            kinopoiskID: context.kinopoiskID,
            title: context.title,
            originalTitle: context.originalTitle,
            year: context.year,
            kind: kind,
            rating: "—",
            genres: [],
            synopsis: "Описание пока недоступно.",
            posterStyle: .dusk,
            posterSymbol: kind == .movie ? "film" : "rectangle.stack",
            posterURL: nil,
            duration: nil,
            seasons: [],
            seasonCount: 0
        )

        if context.kind == .series, let seasonNumber = context.season,
           let episodeNumber = context.episode, seasonNumber > 0, episodeNumber > 0 {
            let episodeID = context.episodeID ?? "\(context.itemID)-s\(seasonNumber)-e\(episodeNumber)"
            let episode = MediaEpisode(
                id: episodeID,
                number: episodeNumber,
                title: "Серия \(episodeNumber)",
                duration: duration > 0 ? "\(max(1, Int(duration / 60))) мин" : "—",
                summary: "Сохранённая позиция воспроизведения."
            )
            if let seasonIndex = cached.seasons.firstIndex(where: { $0.number == seasonNumber }) {
                if !cached.seasons[seasonIndex].episodes.contains(where: { $0.id == episodeID }) {
                    cached.seasons[seasonIndex].episodes.append(episode)
                }
                cached.seasons[seasonIndex] = MediaSeason(
                    number: seasonNumber,
                    episodeCount: max(cached.seasons[seasonIndex].episodeCount, episodeNumber),
                    episodes: cached.seasons[seasonIndex].episodes
                )
            } else {
                cached.seasons.append(MediaSeason(
                    number: seasonNumber,
                    episodeCount: episodeNumber,
                    episodes: [episode]
                ))
                cached.seasons.sort { $0.number < $1.number }
                cached.seasonCount = max(cached.seasonCount, seasonNumber)
            }
        }

        cache(cached)
        persistCatalog()
    }

    private func persistCatalog() {
        guard let data = try? JSONEncoder().encode(cachedItems) else { return }
        defaults.set(data, forKey: cacheKey)
    }

    private func persistWatched() {
        defaults.set(watchedItemIDs.sorted(), forKey: "catalog.watchedItemIDs")
        defaults.set(watchedEpisodeIDs.sorted(), forKey: "catalog.watchedEpisodeIDs")
    }

    private func persistPlayback() {
        guard let data = try? JSONEncoder().encode(playbackRecords) else { return }
        defaults.set(data, forKey: playbackKey)
    }

    private func persistFavoriteTorrents() {
        guard let data = try? JSONEncoder().encode(favoriteTorrents) else { return }
        defaults.set(data, forKey: savedTorrentsKey)
    }

    private func markCloudSyncChanged() {
        let current = LibrarySyncEntry.entries(from: cloudSyncSnapshot())
        let now = Date.now.timeIntervalSince1970
        for (key, var entry) in current {
            guard syncEntries[key].map({ !entry.hasSameValue(as: $0) }) ?? true else { continue }
            entry.modifiedAt = max(now, (syncEntries[key]?.modifiedAt ?? 0) + 0.000001)
            entry.changeID = UUID().uuidString
            syncEntries[key] = entry
        }
        let removedKeys = syncEntries.keys.filter { current[$0] == nil && syncEntries[$0]?.deleted == false && !$0.hasPrefix("metadata:") }
        for key in removedKeys {
            syncEntries[key] = LibrarySyncEntry(key: key,
                modifiedAt: max(now, (syncEntries[key]?.modifiedAt ?? 0) + 0.000001),
                changeID: UUID().uuidString, deleted: true)
        }
        persistSyncEntries()
        cloudSyncRevision &+= 1
        cloudModifiedAt = .now
        defaults.set(cloudModifiedAt, forKey: cloudModifiedAtKey)
        cloudSyncHandler?()
    }

    private func persistSyncEntries() {
        guard let data = try? JSONEncoder().encode(syncEntries) else { return }
        defaults.set(data, forKey: syncEntriesKey)
    }

    func nextEpisode(after context: PlaybackContext) -> PlaybackContext? {
        guard context.kind == .series, let season = context.season, let episode = context.episode,
              let item = item(id: context.itemID), item.hasCompleteEpisodeList == true else { return nil }
        let candidates = item.seasons.sorted { $0.number < $1.number }.flatMap { season in
            season.episodes.sorted { $0.number < $1.number }.map { (season.number, $0.number) }
        }
        guard let next = candidates.first(where: { $0.0 > season || ($0.0 == season && $0.1 > episode) }) else { return nil }
        var nextContext = context
        nextContext.season = next.0
        nextContext.episode = next.1
        return nextContext
    }

    var homePlaybackSuggestions: [HomePlaybackSuggestion] {
        let ordered = playbackRecords.values.sorted { $0.updatedAt > $1.updatedAt }
        var seen = Set<String>()
        return ordered.compactMap { record in
            guard record.position > 0, seen.insert(record.context.itemID).inserted else { return nil }
            if record.completed || isWatched(record.context) {
                guard let next = nextEpisode(after: record.context), !isWatched(next) else { return nil }
                return HomePlaybackSuggestion(context: next, record: playbackRecord(for: next), isNextEpisode: true)
            }
            return HomePlaybackSuggestion(context: record.context, record: record, isNextEpisode: false)
        }
    }

    private func clearPlaybackRecords(for itemID: String) {
        let matchingIDs = playbackRecords.compactMap { key, record in
            record.context.itemID == itemID ? key : nil
        }
        guard !matchingIDs.isEmpty else { return }
        for id in matchingIDs {
            suppressedPlaybackIDs.insert(id)
            playbackRecords.removeValue(forKey: id)
        }
        persistPlayback()
    }

    private func clearPlaybackRecord(for id: String) {
        guard playbackRecords.removeValue(forKey: id) != nil else { return }
        suppressedPlaybackIDs.insert(id)
        persistPlayback()
    }
}
