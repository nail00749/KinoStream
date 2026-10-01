import AVKit
import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var torrServerMode: TorrServerMode = TorrServerMode(
        rawValue: UserDefaults.standard.string(forKey: "torrServerMode") ?? "bundled"
    ) ?? .bundled {
        didSet { UserDefaults.standard.set(torrServerMode.rawValue, forKey: "torrServerMode") }
    }
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "http://127.0.0.1:8090" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    @Published var username: String = UserDefaults.standard.string(forKey: "serverUsername") ?? "" {
        didSet { UserDefaults.standard.set(username, forKey: "serverUsername") }
    }
    @Published var password: String = KeychainStore.readPassword() {
        didSet { KeychainStore.savePassword(password) }
    }
    @Published var kinopoiskAPIKey: String = KeychainStore.readSecret(for: "kinopoisk-api-key") {
        didSet { KeychainStore.saveSecret(kinopoiskAPIKey, for: "kinopoisk-api-key") }
    }
    @Published var jacredEndpoint: String = UserDefaults.standard.string(forKey: "jacredEndpoint") ?? "https://jac.red" {
        didSet { UserDefaults.standard.set(jacredEndpoint, forKey: "jacredEndpoint") }
    }
    @Published var playbackPlayer: PlaybackPlayer = PlaybackPlayer(rawValue: UserDefaults.standard.string(forKey: "playbackPlayer") ?? "builtIn") ?? .builtIn {
        didSet { UserDefaults.standard.set(playbackPlayer.rawValue, forKey: "playbackPlayer") }
    }
    @Published private(set) var supabaseUserEmail: String?
    @Published private(set) var isSupabaseSessionRestored = false
    @Published private(set) var cloudSyncStatus = "Supabase не настроен"
    @Published private(set) var isCloudBusy = false
    @Published var isPasswordRecoveryPresented = false
    @Published var passwordRecoveryEmail = ""
    @Published var authCallbackMessage: String?
    @Published private(set) var recoveryCallbackRevision = 0
    @Published private(set) var catalogIsLoading = false
    @Published var catalogError: String?
    @Published private(set) var connected = false
    @Published private(set) var isCheckingConnection = false
    @Published private(set) var torrents: [Torrent] = []
    @Published var bannerMessage: String?
    @Published var player: AVPlayer?
    @Published var isPlayerPresented = false
    @Published private(set) var currentPlaybackContext: PlaybackContext?
    @Published var pendingPlaybackChoice: PlaybackChoice?
    @Published private(set) var playbackStartPosition: Double = 0

    let torrServerController = TorrServerProcessController()
    lazy var playbackController = PlaybackController(model: self)

    private var client: TorrServerClient? {
        try? TorrServerClient(url: activeServerURL, username: activeServerUsername, password: activeServerPassword)
    }

    var activeServerURL: String {
        if torrServerMode == .bundled {
            return torrServerController.serverURL ?? "http://127.0.0.1:8090"
        }
        return serverURL
    }

    var activeServerRequiresAuthentication: Bool {
        torrServerMode == .external && !username.isEmpty
    }

    private var activeServerUsername: String { torrServerMode == .external ? username : "" }
    private var activeServerPassword: String { torrServerMode == .external ? password : "" }

    private var catalogClient: MediaCatalogClient {
        MediaCatalogClient(kinopoiskAPIKey: kinopoiskAPIKey)
    }

    private var supabaseUserID: UUID?
    var libraryAccountID: UUID? { supabaseUserID }
    private weak var attachedCatalog: CatalogStore?
    private var cachedSupabaseService: SupabaseLibrarySyncService?
    private var passwordRecoveryService: PasswordRecoveryService?
    private var queuedAuthCallback: URL?
    private var isHandlingAuthCallback = false
    private var restoringSession = false
    private var cloudSyncRetryCount = 0
    private let supabaseEnvironment = SupabaseEnvironment.loadFromBundle()
    private var catalogRequestID = UUID()
    private var cloudSyncTask: Task<Void, Never>?
    private var cloudSyncInProgress = false
    private var cloudSyncQueued = false
    private var lastCloudSyncAttemptAt: Date?
    private var vlcPlaybackMonitor: VLCPlaybackMonitor?

    init() {
        UserDefaults.standard.removeObject(forKey: "supabaseProjectURL")
        UserDefaults.standard.removeObject(forKey: "supabasePublishableKey")
        UserDefaults.standard.removeObject(forKey: "supabaseEmail")
        startBundledTorrServerIfNeeded()
    }

    var isSupabaseConfigured: Bool {
        supabaseEnvironment?.hasCredentials == true
    }

    func startBundledTorrServerIfNeeded() {
        guard torrServerMode == .bundled else { return }
        do {
            try torrServerController.startIfNeeded()
        } catch {
            torrServerController.markFailed(error.localizedDescription)
            bannerMessage = error.localizedDescription
        }
    }

    func checkConnection() async {
        isCheckingConnection = true
        defer { isCheckingConnection = false }

        if torrServerMode == .bundled {
            do {
                try torrServerController.startIfNeeded()
                guard let serverURL = torrServerController.serverURL else {
                    throw TorrServerError.invalidResponse
                }
                let localClient = try TorrServerClient(url: serverURL, username: "", password: "")
                var lastError: Error = TorrServerError.invalidResponse
                for _ in 0..<20 {
                    do {
                        try await localClient.ping(timeout: 1)
                        torrServerController.markReady()
                        connected = true
                        bannerMessage = nil
                        await refreshTorrents()
                        return
                    } catch {
                        lastError = error
                    }
                    guard torrServerController.isRunning else {
                        throw TorrServerStartupError.processExited
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                throw lastError
            } catch {
                torrServerController.markFailed(error.localizedDescription)
                connected = false
                bannerMessage = error.localizedDescription
                return
            }
        }

        torrServerController.stop()
        guard let client else {
            connected = false
            bannerMessage = TorrServerError.invalidURL.localizedDescription
            return
        }
        do {
            try await client.ping()
            connected = true
            bannerMessage = nil
            await refreshTorrents()
        } catch {
            connected = false
            bannerMessage = error.localizedDescription
        }
    }

    func changeTorrServerMode() async {
        connected = false
        torrents = []
        if torrServerMode == .external {
            torrServerController.stop()
        }
        await checkConnection()
    }

    func stopBundledTorrServer() {
        torrServerController.stop()
    }

    func stopVLCPlaybackMonitoring() {
        playbackController.cancelAutoplay()
        vlcPlaybackMonitor?.stop()
        vlcPlaybackMonitor = nil
    }

    func refreshTorrents() async {
        if torrServerMode == .bundled && !torrServerController.isRunning {
            await checkConnection()
            return
        }
        guard let client else { return }
        do {
            torrents = try await client.listTorrents()
            connected = true
            bannerMessage = nil
        } catch {
            if torrents.isEmpty { connected = false }
            bannerMessage = error.localizedDescription
        }
    }

    func searchCatalog(_ query: String, scope: CatalogScope, into store: CatalogStore, discovery: CatalogDiscoverySelection = CatalogDiscoverySelection()) async {
        guard scope == .all else { return }
        let token = UUID()
        catalogRequestID = token
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        catalogError = nil
        guard trimmed.isEmpty || trimmed.count >= 2 else {
            store.replaceCatalog(with: [])
            catalogIsLoading = false
            return
        }
        catalogIsLoading = true
        defer { if catalogRequestID == token { catalogIsLoading = false } }
        do {
            let items: [MediaItem]
            if trimmed.isEmpty { items = try await catalogClient.discoveryItems(discovery) }
            else { items = try await catalogClient.search(trimmed) }
            guard !Task.isCancelled, catalogRequestID == token else { return }
            store.replaceCatalog(with: items)
        } catch {
            guard !Task.isCancelled, catalogRequestID == token else { return }
            catalogError = error.localizedDescription
        }
    }

    func mediaDetails(for item: MediaItem) async throws -> MediaItem {
        try await catalogClient.mediaDetails(for: item)
    }

    func seasonEpisodes(for item: MediaItem, seasonNumber: Int) async throws -> [MediaEpisode] {
        try await catalogClient.seasonEpisodes(for: item, seasonNumber: seasonNumber)
    }

    func checkCinemeta() async throws {
        try await catalogClient.checkCinemeta()
    }

    func checkKinopoisk() async throws {
        try await catalogClient.checkKinopoisk()
    }

    func attachCloudSync(to store: CatalogStore) {
        attachedCatalog = store
        store.setCloudSyncHandler { [weak self, weak store] in
            guard let self, let store else { return }
            self.scheduleCloudSync(with: store)
        }
    }

    func restoreSupabaseSession(with store: CatalogStore) async {
        guard !isSupabaseSessionRestored, !restoringSession else { return }
        restoringSession = true
        defer { restoringSession = false }
        attachCloudSync(to: store)
        guard let service = makeSupabaseService() else {
            cloudSyncStatus = "Заполните SUPABASE_URL и SUPABASE_PUBLISHABLE_KEY в локальном .env и пересоберите приложение."
            isSupabaseSessionRestored = true
            return
        }
        do {
            let session = try await service.restoreSession()
            prepareAuthenticatedLibrary(userID: session.user.id, email: session.user.email, store: store)
            cloudSyncStatus = "Аккаунт подключён"
            await synchronizeLibrary(with: store, userID: session.user.id, service: service)
        } catch {
            supabaseUserEmail = nil
            cloudSyncStatus = "Войдите в аккаунт, чтобы синхронизировать библиотеку"
        }
        isSupabaseSessionRestored = true
        await processAuthCallback(with: store)
    }

    func receiveAuthCallback(_ url: URL, with store: CatalogStore) async {
        guard SupabaseAuthCallback.kind(for: url) != nil else { return }
        queuedAuthCallback = url
        await processAuthCallback(with: store)
    }

    func resumeAuthCallback(with store: CatalogStore) async {
        await processAuthCallback(with: store)
    }

    private func processAuthCallback(with store: CatalogStore) async {
        guard isSupabaseSessionRestored, !isHandlingAuthCallback, !isCloudBusy,
              let url = queuedAuthCallback, let kind = SupabaseAuthCallback.kind(for: url) else { return }
        queuedAuthCallback = nil
        isHandlingAuthCallback = true
        isCloudBusy = true
        defer { isHandlingAuthCallback = false; isCloudBusy = false }
        do {
            switch kind {
            case .signup:
                let service = try configuredSupabaseService()
                let session = try await service.confirmSignup(from: url)
                prepareAuthenticatedLibrary(userID: session.user.id, email: session.user.email, store: store)
                cloudSyncStatus = "Email подтверждён"
                isCloudBusy = false
                await synchronizeLibrary(with: store, userID: session.user.id, service: service)
            case .recovery:
                let service = try makePasswordRecoveryService()
                try await service.acceptCallback(url)
                passwordRecoveryEmail = service.verifiedEmail ?? ""
                recoveryCallbackRevision += 1
                isPasswordRecoveryPresented = true
            }
        } catch { authCallbackMessage = error.localizedDescription }
        if queuedAuthCallback != nil {
            isHandlingAuthCallback = false
            isCloudBusy = false
            await processAuthCallback(with: store)
        }
    }

    func signInToSupabase(email: String, password: String, with store: CatalogStore) async {
        guard !isCloudBusy else { return }
        defer { Task { await processAuthCallback(with: store) } }
        attachCloudSync(to: store)
        isCloudBusy = true
        cloudSyncStatus = "Выполняется вход…"
        do {
            let service = try configuredSupabaseService()
            let session = try await service.signIn(email: email, password: password)
            prepareAuthenticatedLibrary(userID: session.user.id, email: session.user.email, store: store)
            isCloudBusy = false
            cloudSyncStatus = "Аккаунт подключён"
            await synchronizeLibrary(with: store, userID: session.user.id, service: service)
        } catch {
            isCloudBusy = false
            cloudSyncStatus = error.localizedDescription
        }
    }

    func createSupabaseAccount(email: String, password: String, with store: CatalogStore) async {
        guard !isCloudBusy else { return }
        defer { Task { await processAuthCallback(with: store) } }
        attachCloudSync(to: store)
        isCloudBusy = true
        cloudSyncStatus = "Создаётся аккаунт…"
        do {
            let service = try configuredSupabaseService()
            let response = try await service.signUp(email: email, password: password)
            guard let session = response.session else {
                isCloudBusy = false
                cloudSyncStatus = "Проверьте почту и подтвердите адрес, затем войдите."
                return
            }
            prepareAuthenticatedLibrary(userID: session.user.id, email: session.user.email, store: store)
            isCloudBusy = false
            cloudSyncStatus = "Аккаунт подключён"
            await synchronizeLibrary(with: store, userID: session.user.id, service: service)
        } catch {
            isCloudBusy = false
            cloudSyncStatus = error.localizedDescription
        }
    }

    func resendSignupConfirmation(email: String) async {
        guard !isCloudBusy else { return }
        isCloudBusy = true
        defer { isCloudBusy = false }
        do {
            try await configuredSupabaseService().resendSignupConfirmation(email: email)
            cloudSyncStatus = "Проверьте почту: отправлено новое письмо подтверждения."
        } catch { cloudSyncStatus = error.localizedDescription }
    }

    func flushBuiltInPlayback(to catalog: CatalogStore) {
        guard let player, let context = currentPlaybackContext,
              let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
        catalog.recordPlayback(context: context, position: player.currentTime().seconds, duration: duration)
    }

    private func prepareAuthenticatedLibrary(userID: UUID, email: String?, store: CatalogStore) {
        if supabaseUserID != userID {
            cloudSyncTask?.cancel()
            cloudSyncTask = nil
            pendingPlaybackChoice = nil
            playbackController.resetSession()
            stopVLCPlaybackMonitoring()
            flushBuiltInPlayback(to: store)
            player?.pause()
            player = nil
            isPlayerPresented = false
            cloudSyncTask?.cancel()
            cloudSyncTask = nil
            cloudSyncRetryCount = 0
            store.activateAccount(userID)
        }
        supabaseUserID = userID
        supabaseUserEmail = email
    }

    func signOutFromSupabase() async {
        guard !isCloudBusy else { return }
        isCloudBusy = true
        cloudSyncTask?.cancel()
        do {
            let service = try configuredSupabaseService()
            try await service.signOut()
            pendingPlaybackChoice = nil
            playbackController.resetSession()
            stopVLCPlaybackMonitoring()
            if let attachedCatalog { flushBuiltInPlayback(to: attachedCatalog) }
            player?.pause()
            isPlayerPresented = false
            supabaseUserID = nil
            supabaseUserEmail = nil
            cloudSyncStatus = "Вы вышли. Локальная библиотека сохранена на этом Mac."
        } catch {
            cloudSyncStatus = error.localizedDescription
        }
        isCloudBusy = false
    }

    func syncSupabaseLibrary(with store: CatalogStore) async {
        if isCloudBusy {
            if cloudSyncInProgress { cloudSyncQueued = true }
            return
        }
        guard supabaseUserEmail != nil else {
            cloudSyncStatus = "Войдите в аккаунт, чтобы синхронизировать библиотеку"
            return
        }
        do {
            let service = try configuredSupabaseService()
            let session = try await service.restoreSession()
            guard session.user.id == supabaseUserID else { return }
            await synchronizeLibrary(with: store, userID: session.user.id, service: service)
        } catch {
            cloudSyncStatus = error.localizedDescription
        }
    }

    func checkJacRed() async throws {
        try await JacRedClient(endpoint: jacredEndpoint).checkConnection()
    }

    func search(_ target: TorrentSearchTarget) async throws -> [TorrentSearchResult] {
        try await JacRedClient(endpoint: jacredEndpoint).search(target)
    }

    func searchMediaForAssociation(_ query: String) async throws -> [MediaItem] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return [] }
        return try await catalogClient.search(query)
    }

    func searchCatalogItems(_ query: String) async throws -> [MediaItem] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return [] }
        let matches = try await catalogClient.search(query, kind: .series)
        return matches.filter { $0.kind == .series }
    }

    func addAndWaitForTorrent(link: String, title: String, onStatus: (PlaybackLoadingState) -> Void = { _ in }) async throws -> Torrent {
        guard let client else { throw TorrServerError.invalidURL }
        onStatus(.connecting)
        let before = try await client.listTorrents()
        try Task.checkCancellation()
        let previousHashes = Set(before.map { $0.hash.lowercased() })
        onStatus(.adding)
        try await client.addTorrent(link: link)
        onStatus(.receivingFiles)

        let expectedHash = infoHash(from: link)
        for _ in 0..<40 {
            try Task.checkCancellation()
            let current = try await client.listTorrents()
            torrents = current
            connected = true

            let torrent: Torrent?
            if let expectedHash {
                torrent = current.first { $0.hash.lowercased() == expectedHash }
            } else {
                let matches = current.filter {
                    $0.displayTitle.localizedCaseInsensitiveContains(title) || title.localizedCaseInsensitiveContains($0.displayTitle)
                }
                let added = current.filter { !previousHashes.contains($0.hash.lowercased()) }
                torrent = matches.count == 1 ? matches.first : (added.count == 1 ? added.first : nil)
            }

            if let torrent, torrent.fileStats.contains(where: isPlayable) {
                bannerMessage = nil
                return torrent
            }
            onStatus(torrent?.activePeers == 0 ? .waitingForPeers : .receivingFiles)
            try await Task.sleep(for: .seconds(1))
        }
        throw TorrServerError.torrentNotReady
    }

    func addTorrent(link: String) async throws {
        guard let client else { throw TorrServerError.invalidURL }
        try await client.addTorrent(link: link)
        await refreshTorrents()
        bannerMessage = "Раздача добавлена в TorrServer."
    }

    func linkTorrent(_ torrent: Torrent, to item: MediaItem, seasonHint: Int, movieFileID: Int, catalog: CatalogStore) {
        if let context = currentPlaybackContext,
           catalog.playbackSource(for: context)?.torrentHash == torrent.hash.lowercased() {
            stopVLCPlaybackMonitoring()
            flushBuiltInPlayback(to: catalog)
            player?.pause()
            player = nil
            isPlayerPresented = false
            currentPlaybackContext = nil
        }
        catalog.link(torrent, to: item, seasonHint: seasonHint, movieFileID: movieFileID)
    }

    func removeTorrent(_ torrent: Torrent) async {
        guard let client else { return }
        do {
            try await client.removeTorrent(hash: torrent.hash)
            await refreshTorrents()
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func play(
        _ torrent: Torrent,
        file: TorrentFile,
        trackingContext: PlaybackContext? = nil,
        catalog: CatalogStore? = nil,
        startPosition: Double? = nil
    ) {
        guard let client, let url = client.playbackURL(hash: torrent.hash, fileID: file.id) else {
            bannerMessage = "Не удалось создать ссылку на видео."
            return
        }
        let resolvedContext = trackingContext?.resolvingEpisode(from: file)
            ?? catalog.map { playbackController.context(for: torrent, file: file, catalog: $0) }
        if let catalog { flushBuiltInPlayback(to: catalog) }
        let savedPosition = resolvedContext.flatMap { catalog?.resumePosition(for: $0) } ?? 0
        if startPosition == nil, savedPosition >= 10 {
            playbackController.cancelAutoplay()
            pendingPlaybackChoice = PlaybackChoice(torrent: torrent, file: file, context: resolvedContext, position: savedPosition, accountID: libraryAccountID)
            return
        }
        pendingPlaybackChoice = nil
        playbackStartPosition = startPosition ?? savedPosition
        playbackController.cancelAutoplay()
        currentPlaybackContext = resolvedContext
        if let resolvedContext, let catalog {
            catalog.beginPlayback(resolvedContext)
            catalog.preferSeriesSource(torrentHash: torrent.hash, for: resolvedContext)
            if resolvedContext.imdbID != nil || resolvedContext.kinopoiskID != nil || resolvedContext.legacyTMDBID > 0 || resolvedContext.kind == .series || torrent.fileStats.filter(\.isPlayable).count == 1 {
                catalog.associate(torrentHash: torrent.hash, with: resolvedContext)
            }
            catalog.associatePlaybackSource(torrentHash: torrent.hash, fileID: file.id, with: resolvedContext)
        }
        stopVLCPlaybackMonitoring()
        playbackController.beginFile(torrent, file: file, context: resolvedContext, catalog: catalog)
        if playbackPlayer == .vlc {
            guard !activeServerRequiresAuthentication else {
                playbackController.reportPlayerState(.failed("Для TorrServer с авторизацией выберите встроенный плеер в настройках."))
                return
            }
            guard let vlcURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") else {
                playbackController.reportPlayerState(.failed("VLC не найден. Установите VLC или выберите встроенный плеер в настройках."))
                return
            }

            guard let resolvedContext, let catalog else {
                openInVLC(url, applicationURL: vlcURL)
                return
            }

            let monitor = VLCPlaybackMonitor()
            vlcPlaybackMonitor = monitor
            bannerMessage = "Запускаем VLC…"
            let resumeAt = playbackStartPosition
            let accountID = libraryAccountID
            let recordProgress: @MainActor (Double, Double) -> Void = { [weak self, weak catalog, weak monitor] position, duration in
                guard let self, let monitor, self.libraryAccountID == accountID, self.vlcPlaybackMonitor === monitor else { return }
                catalog?.recordPlayback(context: resolvedContext, position: position, duration: duration)
            }
            let reportMonitorUnavailable: @MainActor () -> Void = { [weak self, weak monitor] in
                guard let self, let monitor, self.vlcPlaybackMonitor === monitor else { return }
                self.playbackController.reportPlayerState(.failed("VLC не подтвердил воспроизведение. Проверьте окно VLC, повторите запуск или выберите другую раздачу."))
            }

            Task { [weak self, catalog, monitor] in
                do {
                    try await monitor.start(
                        streamURL: url,
                        applicationURL: vlcURL,
                        resumeAt: resumeAt,
                        onProgress: recordProgress,
                        onUnavailable: reportMonitorUnavailable,
                        onPlaybackState: { [weak self, weak monitor] state in
                            guard let self, let monitor, self.vlcPlaybackMonitor === monitor, self.libraryAccountID == accountID else { return }
                            if state == "playing" || state == "paused" { self.playbackController.reportPlayerState(nil) }
                        },
                        onEnded: { [weak self, weak catalog, weak monitor] in
                            guard let self, let catalog, self.libraryAccountID == accountID, self.vlcPlaybackMonitor === monitor else { return }
                            self.playbackController.scheduleNext(after: resolvedContext, catalog: catalog)
                            if self.playbackController.pendingNext != nil { NSApp.activate(ignoringOtherApps: true) }
                        }
                    )
                    guard let self, self.vlcPlaybackMonitor === monitor else { return }
                    self.bannerMessage = nil
                } catch {
                    guard let self, self.vlcPlaybackMonitor === monitor else { return }
                    self.vlcPlaybackMonitor = nil
                    self.playbackController.reportPlayerState(.failed("Не удалось открыть VLC. Попробуйте встроенный плеер в настройках."))
                }
            }
            return
        }
        let player = client.player(for: url)
        self.player = player
        isPlayerPresented = true
    }

    private func openInVLC(_ url: URL, applicationURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        Task {
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: applicationURL, configuration: configuration)
                bannerMessage = nil
            } catch {
                bannerMessage = "Не удалось открыть VLC: \(error.localizedDescription)"
            }
        }
    }

    private func isPlayable(_ file: TorrentFile) -> Bool {
        ["mkv", "mp4", "m4v", "mov", "avi", "webm"].contains(URL(fileURLWithPath: file.path).pathExtension.lowercased())
    }

    func makePasswordRecoveryService() throws -> PasswordRecoveryService {
        if let passwordRecoveryService { return passwordRecoveryService }
        let service = try configuredSupabaseService().makePasswordRecoveryService()
        passwordRecoveryService = service
        return service
    }

    func finishPasswordRecovery() { passwordRecoveryService = nil }

    private func makeSupabaseService() -> SupabaseLibrarySyncService? {
        try? configuredSupabaseService()
    }

    private func configuredSupabaseService() throws -> SupabaseLibrarySyncService {
        guard let supabaseEnvironment, supabaseEnvironment.hasCredentials else {
            throw SupabaseLibrarySyncError.invalidConfiguration
        }
        if let cachedSupabaseService { return cachedSupabaseService }
        let service = try SupabaseLibrarySyncService(
            projectURL: supabaseEnvironment.projectURL,
            publishableKey: supabaseEnvironment.publishableKey
        )
        cachedSupabaseService = service
        return service
    }

    private func scheduleCloudSync(with store: CatalogStore) {
        guard supabaseUserID != nil else { return }
        if cloudSyncInProgress {
            cloudSyncQueued = true
            return
        }
        cloudSyncTask?.cancel()
        let delay: Duration
        if let lastCloudSyncAttemptAt {
            let remainingSeconds = max(1, 20 - Date.now.timeIntervalSince(lastCloudSyncAttemptAt))
            delay = .milliseconds(Int(remainingSeconds * 1000))
        } else {
            delay = .milliseconds(1400)
        }
        cloudSyncTask = Task { [weak self, weak store] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let store else { return }
            self.cloudSyncTask = nil
            await self.syncSupabaseLibrary(with: store)
        }
    }

    private func synchronizeLibrary(
        with store: CatalogStore,
        userID: UUID,
        service: SupabaseLibrarySyncService
    ) async {
        guard !cloudSyncInProgress else {
            cloudSyncQueued = true
            return
        }

        cloudSyncInProgress = true
        isCloudBusy = true
        lastCloudSyncAttemptAt = .now
        cloudSyncStatus = "Синхронизация библиотеки…"
        defer {
            cloudSyncInProgress = false
            isCloudBusy = false
            if cloudSyncQueued {
                cloudSyncQueued = false
                scheduleCloudSync(with: store)
            }
        }

        do {
            let remote = try await service.fetchEntries(for: userID)
            guard supabaseUserID == userID, !Task.isCancelled else { return }
            store.mergeCloudEntries(remote)
            let revision = store.cloudSyncRevision
            let merged = try await service.mergeEntries(store.cloudEntries(), for: userID)
            guard supabaseUserID == userID, !Task.isCancelled else { return }
            store.mergeCloudEntries(merged)
            if revision != store.cloudSyncRevision { cloudSyncQueued = true }
            cloudSyncRetryCount = 0
            cloudSyncStatus = "Библиотека синхронизирована"
        } catch is CancellationError {
            return
        } catch {
            cloudSyncStatus = error.localizedDescription
            if let syncError = error as? SupabaseLibrarySyncError, case .migrationRequired = syncError { return }
            cloudSyncRetryCount += 1
            if cloudSyncRetryCount <= 3 { cloudSyncQueued = true }
        }
    }

    private func infoHash(from link: String) -> String? {
        guard let components = URLComponents(string: link),
              let xt = components.queryItems?.first(where: { $0.name.lowercased() == "xt" })?.value?.lowercased(),
              let marker = xt.range(of: "urn:btih:") else { return nil }
        let hash = String(xt[marker.upperBound...])
        return hash.count == 40 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }
}

struct PlaybackChoice {
    let torrent: Torrent
    let file: TorrentFile
    let context: PlaybackContext?
    let position: Double
    let accountID: UUID?
}

private enum TorrServerStartupError: LocalizedError {
    case processExited

    var errorDescription: String? {
        "Встроенный TorrServer завершился во время запуска. Перезапустите приложение."
    }
}
