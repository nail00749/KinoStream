import Foundation
import Combine

struct TorrentFileSelection: Identifiable {
    let torrent: Torrent
    let files: [TorrentFile]
    let context: PlaybackContext?
    var id: String { torrent.hash }
}

struct HomePlaybackSuggestion: Identifiable {
    let context: PlaybackContext
    let record: PlaybackRecord?
    let isNextEpisode: Bool
    var id: String { context.progressID }
}

enum PlaybackResolution {
    case started
    case chooseFiles(TorrentFileSelection)
    case needsSearch(TorrentSearchTarget)
    case needsReplacement(TorrentSearchTarget, String)
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var loadingState: PlaybackLoadingState?
    @Published private(set) var loadingTitle = ""
    @Published private(set) var fileRequest: TorrentFileSelection?
    @Published private(set) var searchRequest: TorrentSearchTarget?
    private enum Attempt {
        case search(TorrentSearchResult, TorrentSearchTarget, Bool)
        case file(Torrent, TorrentFile, PlaybackContext?)
        case context(PlaybackContext)
    }
    private var monitoringPlayback = false
    private var lastAttempt: Attempt?
    private weak var activeCatalog: CatalogStore?
    private var activeContext: PlaybackContext?
    private var activeHash: String?
    private var preparationID = UUID()
    private var preparationTask: Task<Torrent, Error>?
    private var stallTask: Task<Void, Never>?

    func connectionDetail(in torrents: [Torrent]) -> String? {
        guard let activeHash, let torrent = torrents.first(where: { $0.hash.lowercased() == activeHash }) else { return nil }
        var details: [String] = []
        if let peers = torrent.activePeers { details.append("Пиров: \(peers)") }
        if let speed = torrent.downloadSpeed, speed > 0 { details.append(speed.speedLabel) }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    func cancelLoading() {
        monitoringPlayback = false
        preparationID = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        stallTask?.cancel()
        stallTask = nil
        loadingState = nil
    }

    func beginFile(_ torrent: Torrent, file: TorrentFile, context: PlaybackContext?, catalog: CatalogStore?) {
        cancelLoading()
        lastAttempt = .file(torrent, file, context)
        activeCatalog = catalog
        activeContext = context
        activeHash = torrent.hash.lowercased()
        loadingTitle = context?.title ?? file.name
        monitoringPlayback = true
        reportPlayerState(.openingPlayer)
    }

    func reportPlayerState(_ state: PlaybackLoadingState?) {
        guard monitoringPlayback, loadingState != state else { return }
        if loadingState?.isFailure == true { return }
        stallTask?.cancel()
        stallTask = nil
        loadingState = state
        guard state == .buffering || state == .openingPlayer else { return }
        let token = preparationID
        stallTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.preparationID == token, self.loadingState == state else { return }
            self.model.player?.pause()
            self.loadingState = .failed("Видео не начало воспроизводиться. Возможно, не хватает пиров или формат не поддерживается выбранным плеером. Повторите запуск или выберите другую раздачу.")
        }
    }

    func retry() async {
        guard let lastAttempt, let catalog = activeCatalog else { return }
        switch lastAttempt {
        case .search(let result, let target, let chooseFilesOnly):
            do { fileRequest = try await prepare(result, target: target, catalog: catalog, chooseFilesOnly: chooseFilesOnly) }
            catch {
                // prepare preserves an actionable failure state; cancellation clears it.
            }
        case .file(let torrent, let file, let context):
            let accountID = model.libraryAccountID
            cancelLoading()
            let token = preparationID
            loadingState = .connecting
            await model.refreshTorrents()
            guard preparationID == token, model.libraryAccountID == accountID else { return }
            guard model.connected else {
                loadingState = .failed("Сервер недоступен. Проверьте соединение и повторите запуск.")
                return
            }
            guard let refreshed = model.torrents.first(where: { $0.hash == torrent.hash }),
                  let refreshedFile = refreshed.fileStats.first(where: { $0.id == file.id && $0.isPlayable }) else {
                loadingState = .failed("Файл больше не доступен на сервере. Выберите другую раздачу.")
                return
            }
            model.play(refreshed, file: refreshedFile, trackingContext: context, catalog: catalog)
        case .context(let context):
            switch await openSaved(context, catalog: catalog) {
            case .started: break
            case .chooseFiles(let files): fileRequest = files
            case .needsSearch(let target), .needsReplacement(let target, _): searchRequest = target
            }
        }
    }

    func resetSession() {
        cancelLoading()
        cancelAutoplay()
        lastAttempt = nil
        activeCatalog = nil
        activeContext = nil
        activeHash = nil
        fileRequest = nil
        searchRequest = nil
    }

    func chooseAlternative() {
        guard let context = activeContext else { return }
        cancelLoading()
        cancelAutoplay()
        model.stopVLCPlaybackMonitoring()
        model.player?.pause()
        searchRequest = TorrentSearchTarget(context: context)
    }

    func consumeFileRequest() { fileRequest = nil }
    func consumeSearchRequest() { searchRequest = nil }

    @Published private(set) var pendingNext: PlaybackContext?
    @Published private(set) var countdown = 10
    @Published private(set) var automaticRequest: PlaybackContext?
    private var countdownTask: Task<Void, Never>?

    func cancelAutoplay() {
        countdownTask?.cancel()
        countdownTask = nil
        pendingNext = nil
        automaticRequest = nil
    }

    func scheduleNext(after context: PlaybackContext, catalog: CatalogStore) {
        cancelAutoplay()
        guard UserDefaults.standard.object(forKey: "autoplayNextEpisode") as? Bool ?? true,
              let next = catalog.nextEpisode(after: context) else { return }
        let accountID = model.libraryAccountID
        pendingNext = next
        countdown = 10
        countdownTask = Task { [weak self] in
            for remaining in stride(from: 9, through: 0, by: -1) {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.model.libraryAccountID == accountID, self.pendingNext == next,
                      UserDefaults.standard.object(forKey: "autoplayNextEpisode") as? Bool ?? true else {
                    self?.cancelAutoplay()
                    return
                }
                self.countdown = remaining
            }
            self?.playNextNow()
        }
    }

    func playNextNow() {
        guard let next = pendingNext else { return }
        countdownTask?.cancel()
        countdownTask = nil
        pendingNext = nil
        automaticRequest = next
    }

    private unowned let model: AppModel

    init(model: AppModel) { self.model = model }

    func prepare(_ result: TorrentSearchResult, target: TorrentSearchTarget, catalog: CatalogStore, chooseFilesOnly: Bool = false) async throws -> TorrentFileSelection? {
        guard let link = result.torrentLink else { throw TorrServerError.invalidURL }
        cancelLoading()
        let token = preparationID
        let context = target.playbackContext
        let accountID = model.libraryAccountID
        lastAttempt = .search(result, target, chooseFilesOnly)
        activeCatalog = catalog
        activeContext = context
        activeHash = nil
        loadingTitle = result.title
        loadingState = .connecting
        let task = Task { try await model.addAndWaitForTorrent(link: link, title: result.title) { [weak self] state in
            guard let self, self.preparationID == token else { return }
            self.loadingState = state
        } }
        preparationTask = task
        do {
            let torrent = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard preparationID == token, model.libraryAccountID == accountID else { throw CancellationError() }
            preparationTask = nil
            if let context { catalog.associate(torrentHash: torrent.hash, with: context) }
            loadingState = nil
            if chooseFilesOnly {
                let files = torrent.fileStats.filter(\.isPlayable)
                guard !files.isEmpty else { throw TorrServerError.torrentNotReady }
                let matching = Self.matchingFile(in: files, context: context)
                return TorrentFileSelection(torrent: torrent, files: matching.map { [$0] } ?? files, context: context)
            }
            return selectOrPlay(torrent, context: context, catalog: catalog)
        } catch {
            guard preparationID == token else { throw CancellationError() }
            preparationTask = nil
            if error is CancellationError || Task.isCancelled { loadingState = nil; throw CancellationError() }
            let message = (error as? TorrServerError)?.localizedDescription ?? "Не удалось связаться с сервером. Проверьте соединение и повторите запуск."
            loadingState = .failed(message)
            throw error
        }
    }

    func openSaved(_ context: PlaybackContext, catalog: CatalogStore) async -> PlaybackResolution {
        let accountID = model.libraryAccountID
        cancelLoading()
        let token = preparationID
        lastAttempt = .context(context)
        activeContext = context
        activeCatalog = catalog
        loadingTitle = context.title
        activeHash = nil
        loadingState = .connecting
        await model.refreshTorrents()
        guard preparationID == token, model.libraryAccountID == accountID, !Task.isCancelled else { return .started }
        guard model.connected else {
            loadingState = .failed("Сервер недоступен. Проверьте соединение и повторите запуск.")
            return .started
        }
        loadingState = nil
        if let preferredHash = catalog.preferredSeriesSource(for: context) {
            guard let torrent = model.torrents.first(where: { $0.hash.lowercased() == preferredHash }) else {
                return .needsReplacement(TorrentSearchTarget(context: context), "Выбранной раздачи этого сезона больше нет на сервере.")
            }
            let files = torrent.fileStats.filter(\.isPlayable)
            let source = catalog.playbackSource(for: context)
            let savedFile = source?.torrentHash == preferredHash ? files.first(where: { $0.id == source?.fileID }) : nil
            if let file = savedFile ?? Self.matchingFile(in: files, context: context, allowUnparsedSingle: false) {
                model.play(torrent, file: file, trackingContext: context, catalog: catalog)
                return .started
            }
            if context.episode == nil, !files.isEmpty {
                return .chooseFiles(TorrentFileSelection(torrent: torrent, files: files, context: context))
            }
            return .needsReplacement(TorrentSearchTarget(context: context), "В выбранной раздаче сезона нет нужной серии или её номер не удалось определить. Выберите другую раздачу.")
        }
        if let source = catalog.playbackSource(for: context),
           let torrent = model.torrents.first(where: { $0.hash.lowercased() == source.torrentHash }),
           let file = torrent.fileStats.first(where: { $0.id == source.fileID && $0.isPlayable }) {
            model.play(torrent, file: file, trackingContext: context, catalog: catalog)
            return .started
        }
        let linked = model.torrents.filter { catalog.playbackContext(forTorrentHash: $0.hash)?.itemID == context.itemID }
        for torrent in linked {
            let files = torrent.fileStats.filter(\.isPlayable)
            if let file = Self.matchingFile(in: files, context: context, allowUnparsedSingle: false) {
                model.play(torrent, file: file, trackingContext: context, catalog: catalog)
                return .started
            }
            if context.episode == nil, !files.isEmpty {
                return .chooseFiles(TorrentFileSelection(torrent: torrent, files: files, context: context))
            }
        }
        return .needsSearch(TorrentSearchTarget(context: context))
    }

    private func selectOrPlay(_ torrent: Torrent, context: PlaybackContext?, catalog: CatalogStore) -> TorrentFileSelection? {
        let files = torrent.fileStats.filter(\.isPlayable)
        if let file = Self.matchingFile(in: files, context: context) {
            model.play(torrent, file: file, trackingContext: context, catalog: catalog)
            return nil
        }
        return TorrentFileSelection(torrent: torrent, files: files, context: context)
    }

    static func matchingFile(in files: [TorrentFile], context: PlaybackContext?, allowUnparsedSingle: Bool = true) -> TorrentFile? {
        if let season = context?.season, let episode = context?.episode {
            let exact = files.filter { $0.episodeCoordinates == EpisodeCoordinates(season: season, episode: episode) }
            if exact.count == 1 { return exact[0] }
            // Only an unambiguous file without season metadata may be used as a fallback.
            if exact.isEmpty {
                let unspecified = files.filter { $0.episodeCoordinates == EpisodeCoordinates(season: nil, episode: episode) }
                if unspecified.count == 1 { return unspecified[0] }
            }
            if allowUnparsedSingle, files.count == 1, files[0].episodeCoordinates == nil { return files[0] }
            return nil
        }
        return files.count == 1 ? files[0] : nil
    }

    func context(for torrent: Torrent, file: TorrentFile, catalog: CatalogStore) -> PlaybackContext {
        if let saved = catalog.playbackContext(forTorrentHash: torrent.hash, fileID: file.id) {
            return saved
        }
        if let saved = catalog.playbackContext(forTorrentHash: torrent.hash) {
            return saved.resolvingEpisode(from: file)
        }
        let coordinates = file.episodeCoordinates
        let kind: TorrentSearchKind = coordinates == nil ? .movie : .series
        // Content identity contains no torrent hash, magnet or server URL.
        let torrentTitle = torrent.title?.nilIfBlank ?? torrent.name?.nilIfBlank ?? file.name
        let title = kind == .series || torrent.fileStats.filter(\.isPlayable).count == 1
            ? torrentTitle : file.name
        return PlaybackContext(
            legacyTMDBID: 0, kind: kind, title: title, originalTitle: title, year: 0,
            season: coordinates.map { $0.season ?? 1 }, episode: coordinates?.episode,
            localIdentity: PlaybackContext.localID(for: title, kind: kind)
        )
    }
}
