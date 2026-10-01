import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Главная"
    case catalog = "Каталог"
    case favorites = "Избранное"
    case watched = "Просмотренное"
    case search = "Поиск раздач"
    case torrents = "Моя коллекция"
    case settings = "Настройки"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: "sparkles.tv"
        case .catalog: "square.grid.2x2"
        case .favorites: "heart"
        case .watched: "checkmark.circle"
        case .search: "magnifyingglass"
        case .torrents: "square.stack.3d.up"
        case .settings: "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppSection = .home
    @State private var searchText = ""
    @State private var catalogSearchText = ""
    @State private var collectionSearchText = ""
    @State private var searchTarget = TorrentSearchTarget.text("")
    @State private var showingAddTorrent = false
    @State private var addTorrentPrefill = ""
    @State private var replacementTarget: TorrentSearchTarget?
    @State private var replacementMessage = ""
    @State private var showingReplacement = false
    @State private var queuedReplacement = false
    @State private var queuedPlaybackFiles: TorrentFileSelection?
    @State private var pendingPlaybackFiles: TorrentFileSelection?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 250)
        } detail: {
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                GeometryReader { viewport in
                    page
                        .id(selection)
                        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                        .clipped()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                if let message = model.bannerMessage {
                    banner(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(KinoPalette.background)
        }
        .onReceive(model.playbackController.$fileRequest) { files in
            guard let files else { return }
            Task { @MainActor in
                guard model.playbackController.fileRequest?.id == files.id else { return }
                model.playbackController.consumeFileRequest()
                if model.isPlayerPresented {
                    queuedPlaybackFiles = files
                    model.isPlayerPresented = false
                } else { pendingPlaybackFiles = files }
            }
        }
        .onReceive(model.$pendingPlaybackChoice) { choice in
            guard choice != nil else { return }
            Task { @MainActor in
                guard model.pendingPlaybackChoice != nil, model.isPlayerPresented else { return }
                model.player?.pause()
                model.isPlayerPresented = false
            }
        }
        .alert("Продолжить просмотр?", isPresented: Binding(
            get: { model.pendingPlaybackChoice != nil },
            set: { if !$0 { model.pendingPlaybackChoice = nil } }
        ), presenting: model.pendingPlaybackChoice) { choice in
            Button("Продолжить") { play(choice, position: choice.position) }
            Button("Начать сначала") { play(choice, position: 0) }
            Button("Отмена", role: .cancel) { model.pendingPlaybackChoice = nil }
        } message: { choice in
            Text("\(choice.context?.title ?? choice.file.name)\nОстановились на \(Int(choice.position) / 60):\(String(format: "%02d", Int(choice.position) % 60))")
        }
        .onReceive(model.playbackController.$searchRequest) { target in
            guard let target else { return }
            Task { @MainActor in
                guard model.playbackController.searchRequest == target else { return }
                model.playbackController.consumeSearchRequest()
                model.isPlayerPresented = false
                beginSearch(target)
            }
        }
        .onReceive(model.playbackController.$automaticRequest) { context in
            guard let context else { return }
            Task { @MainActor in
                guard model.playbackController.automaticRequest == context else { return }
                model.playbackController.cancelAutoplay()
                openForPlayback(TorrentSearchTarget(context: context))
            }
        }
        .overlay(alignment: .bottom) {
            if !model.isPlayerPresented {
                VStack(spacing: 12) {
                    PlaybackLoadingView(controller: model.playbackController)
                    NextEpisodeCountdownView(controller: model.playbackController)
                }.padding(24)
            }
        }
        .alert("Выбрать другую раздачу?", isPresented: $showingReplacement) {
            Button("Выбрать раздачу") {
                if let replacementTarget { beginSearch(replacementTarget) }
                replacementTarget = nil
            }
            Button("Отмена", role: .cancel) { replacementTarget = nil }
        } message: { Text(replacementMessage) }
        .navigationSplitViewStyle(.balanced)
        .background(KinoPalette.background)
        .task {
            await model.checkConnection()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                await model.refreshTorrents()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, model.supabaseUserEmail != nil else { return }
            Task { await model.syncSupabaseLibrary(with: catalog) }
        }
        .sheet(item: $pendingPlaybackFiles) { selection in
            PlaybackFilePickerView(torrent: selection.torrent, files: selection.files) { file in
                model.play(selection.torrent, file: file, trackingContext: selection.context, catalog: catalog)
            }
            .frame(minWidth: 540, minHeight: 420)
        }
        .sheet(isPresented: $showingAddTorrent, onDismiss: { addTorrentPrefill = "" }) {
            AddTorrentView(initialLink: addTorrentPrefill)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isPlayerPresented, onDismiss: {
            model.playbackController.cancelAutoplay()
            model.playbackController.cancelLoading()
            model.player?.pause()
            model.player = nil
            if queuedReplacement {
                queuedReplacement = false
                showingReplacement = true
            }
            if let queuedPlaybackFiles {
                pendingPlaybackFiles = queuedPlaybackFiles
                self.queuedPlaybackFiles = nil
            }
        }) {
            if let player = model.player {
                let playbackContext = model.currentPlaybackContext
                let playbackAccountID = model.libraryAccountID
                PlayerView(
                    player: player,
                    resumeAt: model.playbackStartPosition,
                    nextEpisode: playbackContext.flatMap { context in
                        catalog.playbackRecord(for: context)?.completed == true ? catalog.nextEpisode(after: context) : nil
                    },
                    onNextEpisode: { context in openForPlayback(TorrentSearchTarget(context: context)) },
                    onLoadingState: { state in
                        guard model.player === player, model.libraryAccountID == playbackAccountID else { return }
                        model.playbackController.reportPlayerState(state)
                    },
                    onEnded: {
                        guard let playbackContext, model.libraryAccountID == playbackAccountID,
                              model.currentPlaybackContext == playbackContext else { return }
                        model.playbackController.scheduleNext(after: playbackContext, catalog: catalog)
                    },
                    onProgress: { position, duration in
                        guard let playbackContext, model.libraryAccountID == playbackAccountID,
                              model.currentPlaybackContext == playbackContext else { return }
                        catalog.recordPlayback(context: playbackContext, position: position, duration: duration)
                    }
                )
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 12) {
                            PlaybackLoadingView(controller: model.playbackController)
                            NextEpisodeCountdownView(controller: model.playbackController)
                        }.padding(24)
                    }
                    .id(ObjectIdentifier(player))
                    .frame(minWidth: 900, minHeight: 560)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(KinoPalette.accent)
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(KinoPalette.background)
                        .offset(x: 1)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("KINO")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(.white)
                    Text("STREAM")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(2.8)
                        .foregroundStyle(KinoPalette.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 27)
            .padding(.bottom, 34)

            Text("МЕНЮ")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(KinoPalette.muted.opacity(0.8))
                .padding(.horizontal, 22)
                .padding(.bottom, 10)

            VStack(spacing: 4) {
                ForEach(AppSection.allCases) { item in
                    Button {
                        selection = item
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 19)
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: selection == item ? .semibold : .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                            if item == .torrents && !model.torrents.isEmpty {
                                Text("\(model.torrents.count)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(KinoPalette.accent)
                            }
                            if item == .favorites && catalog.favoriteIDs.count + catalog.favoriteTorrents.count > 0 {
                                countBadge(catalog.favoriteIDs.count + catalog.favoriteTorrents.count)
                            }
                            if item == .watched && !catalog.items(in: .watched).isEmpty {
                                countBadge(catalog.items(in: .watched).count)
                            }
                        }
                        .foregroundStyle(selection == item ? .white : KinoPalette.muted)
                        .padding(.horizontal, 13)
                        .frame(height: 42)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(Color.white.opacity(0.085))
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(KinoPalette.accent)
                                            .frame(width: 3, height: 20)
                                            .offset(x: -1)
                                    }
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)

            Spacer()

            connectionCard
                .padding(.horizontal, 13)
                .padding(.bottom, 17)
        }
        .background(KinoPalette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.055)).frame(width: 1) }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.connected ? KinoPalette.accent : Color.orange.opacity(0.9))
                    .frame(width: 7, height: 7)
                    .shadow(color: model.connected ? KinoPalette.accent.opacity(0.6) : .clear, radius: 5)
                Text(model.connected ? "СЕРВЕР ПОДКЛЮЧЁН" : "НЕТ ПОДКЛЮЧЕНИЯ")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(model.connected ? KinoPalette.accent : KinoPalette.muted)
            }
            Text(model.activeServerURL.replacingOccurrences(of: "http://", with: ""))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                selection = .settings
            } label: {
                HStack(spacing: 6) {
                    Text("Параметры сервера")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(KinoPalette.muted)
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(KinoPalette.muted)
                TextField(topSearchPlaceholder, text: activeSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { if !isCatalogSection && selection != .torrents { submitSearch() } }
                if !activeSearchText.wrappedValue.isEmpty {
                    Button { activeSearchText.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(KinoPalette.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 39)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.065), lineWidth: 1))
            .frame(maxWidth: 480)

            Spacer()

            Button { showingAddTorrent = true } label: {
                Label("Добавить раздачу", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 13)
                    .frame(height: 37)
                    .foregroundStyle(KinoPalette.background)
                    .background(KinoPalette.accent, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)

            Button {
                Task { await model.checkConnection() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(KinoPalette.muted)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help("Обновить соединение")
        }
        .padding(.horizontal, 28)
        .frame(height: 70)
        .background(KinoPalette.background)
    }

    @ViewBuilder private var page: some View {
        switch selection {
        case .home:
            HomeView(
                torrents: model.torrents,
                onSearch: { query in searchText = query; searchTarget = .text(query); selection = .search },
                onAdd: { showingAddTorrent = true },
                onOpenLibrary: { selection = .torrents },
                onPlay: openForPlayback
            )
        case .catalog: CatalogView(scope: .all, onSearch: beginSearch, onPlay: openForPlayback, query: $catalogSearchText)
        case .favorites: FavoritesView(onSearch: beginSearch, onPlay: openForPlayback, query: $catalogSearchText)
        case .watched: CatalogView(scope: .watched, onSearch: beginSearch, onPlay: openForPlayback, query: $catalogSearchText)
        case .search: SearchView(searchText: $searchText, searchTarget: $searchTarget)
        case .torrents: TorrentsView(query: collectionSearchText, onAdd: { showingAddTorrent = true }, onSettings: { selection = .settings })
        case .settings: SettingsView()
        }
    }

    private func submitSearch() {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("magnet:") {
            addTorrentPrefill = searchText
            showingAddTorrent = true
        } else {
            searchTarget = .text(searchText)
            selection = .search
        }
    }

    private func beginSearch(_ target: TorrentSearchTarget) {
        searchText = target.query
        searchTarget = target
        selection = .search
    }

    private func openForPlayback(_ target: TorrentSearchTarget) {
        model.playbackController.cancelAutoplay()
        guard let context = target.playbackContext else { beginSearch(target); return }
        Task {
            switch await model.playbackController.openSaved(context, catalog: catalog) {
            case .started: break
            case .chooseFiles(let files):
                if model.isPlayerPresented {
                    queuedPlaybackFiles = files
                    model.player?.pause()
                    model.isPlayerPresented = false
                } else {
                    pendingPlaybackFiles = files
                }
            case .needsReplacement(let target, let message):
                replacementTarget = target
                replacementMessage = message
                model.player?.pause()
                if model.isPlayerPresented {
                    queuedReplacement = true
                    model.isPlayerPresented = false
                } else { showingReplacement = true }
            case .needsSearch(let target):
                model.isPlayerPresented = false
                model.player?.pause()
                beginSearch(target)
            }
        }
    }

    private var isCatalogSection: Bool {
        selection == .catalog || selection == .favorites || selection == .watched
    }

    private var activeSearchText: Binding<String> {
        selection == .torrents ? $collectionSearchText : (isCatalogSection ? $catalogSearchText : $searchText)
    }

    private var topSearchPlaceholder: String {
        switch selection {
        case .catalog: "Найти фильм или сериал"
        case .favorites: "Найти в избранном"
        case .watched: "Найти в просмотренном"
        case .torrents: "Название, файл или сезон 2 серия 5"
        default: "Название фильма, сериала или magnet-ссылка"
        }
    }

    private func play(_ choice: PlaybackChoice, position: Double) {
        guard choice.accountID == model.libraryAccountID else { model.pendingPlaybackChoice = nil; return }
        model.play(choice.torrent, file: choice.file, trackingContext: choice.context, catalog: catalog, startPosition: position)
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(KinoPalette.accent)
    }

    private func banner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.connected ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(model.connected ? KinoPalette.accent : .orange)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
            Spacer()
            Button { model.bannerMessage = nil } label: { Image(systemName: "xmark").foregroundStyle(KinoPalette.muted) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.07))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
