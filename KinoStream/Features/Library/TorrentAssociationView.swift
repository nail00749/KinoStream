import SwiftUI

struct TorrentAssociationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.dismiss) private var dismiss
    let torrent: Torrent
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var selected: MediaItem?
    @State private var movieFileID = -1
    @State private var season = 1
    @State private var loading = false
    @State private var loadingDetails = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var detailID = UUID()
    private var playableFiles: [TorrentFile] { torrent.fileStats.filter(\.isPlayable) }
    private var needsSeason: Bool {
        torrent.fileStats.contains { $0.episodeCoordinates?.season == nil && $0.episodeCoordinates?.episode != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Привязать к карточке").font(.title2.bold())
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(.plain)
            }
            Text(torrent.displayTitle).font(.caption).foregroundStyle(KinoPalette.muted).lineLimit(2)
            TextField("Название фильма или сериала", text: $query).textFieldStyle(.roundedBorder)
            if loading || loadingDetails { ProgressView("Загружаем карточки…") }
            if let error { Text(error).foregroundStyle(KinoPalette.muted).font(.caption) }
            if let selected {
                HStack(spacing: 16) {
                    MediaArtwork(item: selected).frame(width: 70, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selected.title).font(.headline)
                        Text("\(selected.kind.title) · \(selected.year > 0 ? String(selected.year) : "Год не указан")").font(.caption)
                        if selected.kind == .series, needsSeason {
                            Picker("Сезон для файлов без номера сезона", selection: $season) {
                                ForEach(selected.seasons.map(\.number).sorted(), id: \.self) { Text("Сезон \($0)").tag($0) }
                            }
                            if selected.seasons.isEmpty {
                                Stepper("Сезон \(season)", value: $season, in: 0...99)
                            }
                        }
                        if selected.kind == .movie, playableFiles.count > 1 {
                            Picker("Файл фильма", selection: $movieFileID) {
                                ForEach(playableFiles) { Text($0.name).tag($0.id) }
                            }
                        }
                        Button("Выбрать другую карточку") { detailID = UUID(); self.selected = nil }
                    }
                }
                Text("Файлы с SxxEyy сохранят свои номера. Прогресс ручной раздачи перенесётся в выбранную карточку. Привязка хранится на этом Mac.")
                    .font(.caption).foregroundStyle(KinoPalette.muted)
                Button("Сохранить привязку") {
                    model.linkTorrent(torrent, to: selected, seasonHint: season, movieFileID: movieFileID, catalog: catalog)
                    model.bannerMessage = "Раздача привязана к «\(selected.title)»."
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(loadingDetails || playableFiles.isEmpty)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results) { item in
                            Button { Task { await select(item) } } label: {
                                HStack(spacing: 12) {
                                    MediaArtwork(item: item).frame(width: 40, height: 55).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.headline)
                                        Text("\(item.kind.title) · \(item.year > 0 ? String(item.year) : "Год не указан")").font(.caption).foregroundStyle(KinoPalette.muted)
                                    }
                                    Spacer()
                                }
                                .padding(10).background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).disabled(loadingDetails)
                        }
                    }
                }
                if !loading, results.isEmpty, query.count >= 2 { Text("Карточки не найдены").foregroundStyle(KinoPalette.muted) }
            }
            Spacer(minLength: 0)
        }
        .padding(24).foregroundStyle(.white).background(KinoPalette.background)
        .onAppear { query = catalog.playbackContext(forTorrentHash: torrent.hash)?.title ?? torrent.displayTitle }
        .task(id: query) {
            let token = UUID()
            requestID = token
            results = []
            error = nil
            guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { loading = false; return }
            loading = true
            defer { if requestID == token { loading = false } }
            do {
                try await Task.sleep(for: .milliseconds(350))
                let found = try await model.searchMediaForAssociation(query)
                guard !Task.isCancelled, requestID == token else { return }
                results = found
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                self.error = error.localizedDescription
            }
        }
        .onDisappear { detailID = UUID() }
    }

    private func select(_ item: MediaItem) async {
        let token = UUID()
        detailID = token
        let accountID = model.libraryAccountID
        movieFileID = playableFiles.max(by: { $0.length < $1.length })?.id ?? -1
        loadingDetails = true
        error = nil
        defer { if detailID == token { loadingDetails = false } }
        do {
            let details = try await model.mediaDetails(for: item)
            guard detailID == token, model.libraryAccountID == accountID, !Task.isCancelled else { return }
            selected = details
            season = details.seasons.first?.number ?? 1
        } catch {
            guard detailID == token, model.libraryAccountID == accountID, !Task.isCancelled else { return }
            selected = item
            self.error = "Не удалось загрузить подробности. Можно привязать найденную карточку и загрузить серии позже."
        }
    }
}
