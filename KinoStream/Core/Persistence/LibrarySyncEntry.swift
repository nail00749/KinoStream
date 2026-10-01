import Foundation

/// A deletion is retained as a versioned entry so an offline device cannot restore it.
struct LibrarySyncEntry: Codable, Equatable {
    let key: String
    var modifiedAt: Double
    var changeID: String
    var deleted: Bool = false
    var item: MediaItem?
    var record: PlaybackRecord?

    func isNewer(than other: LibrarySyncEntry) -> Bool {
        modifiedAt > other.modifiedAt || (modifiedAt == other.modifiedAt && changeID > other.changeID)
    }

    func hasSameValue(as other: LibrarySyncEntry) -> Bool {
        deleted == other.deleted && item == other.item && record == other.record
    }

    static func entries(from snapshot: CatalogSyncSnapshot) -> [String: LibrarySyncEntry] {
        var entries: [String: LibrarySyncEntry] = [:]
        let time = max(0, snapshot.updatedAt.timeIntervalSince1970)
        func add(_ key: String, item: MediaItem? = nil, record: PlaybackRecord? = nil) {
            entries[key] = LibrarySyncEntry(
                key: key, modifiedAt: record?.updatedAt.timeIntervalSince1970 ?? time,
                changeID: "legacy-\(key)", item: item, record: record
            )
        }
        snapshot.favoriteIDs.forEach { add("favorite:\($0)") }
        snapshot.watchedItemIDs.forEach { add("watchedItem:\($0)") }
        snapshot.watchedEpisodeIDs.forEach { add("watchedEpisode:\($0)") }
        snapshot.cachedItems.forEach { add("metadata:\($0.id)", item: $0) }
        snapshot.playbackRecords.forEach { add("playback:\($0.key)", record: $0.value) }
        return entries
    }

    static func snapshot(from entries: [String: LibrarySyncEntry]) -> CatalogSyncSnapshot {
        let active = entries.values.filter { !$0.deleted }
        func ids(_ prefix: String) -> [String] {
            active.filter { $0.key.hasPrefix(prefix) }.map { String($0.key.dropFirst(prefix.count)) }.sorted()
        }
        let records = active.compactMap { $0.key.hasPrefix("playback:") ? $0.record : nil }
        return CatalogSyncSnapshot(
            updatedAt: Date(timeIntervalSince1970: entries.values.map(\.modifiedAt).max() ?? 0),
            favoriteIDs: ids("favorite:"), watchedItemIDs: ids("watchedItem:"),
            watchedEpisodeIDs: ids("watchedEpisode:"),
            playbackRecords: Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            cachedItems: active.compactMap { $0.key.hasPrefix("metadata:") ? $0.item : nil }.sorted { $0.id < $1.id }
        )
    }
}

struct AccountLibrary: Codable {
    let snapshot: CatalogSyncSnapshot
    let entries: [String: LibrarySyncEntry]
    let favoriteTorrents: [FavoriteTorrent]
    let torrentContexts: [String: PlaybackContext]
    let playbackSources: [String: PlaybackSource]
    var preferredSeriesSources: [String: String]? = nil
}
