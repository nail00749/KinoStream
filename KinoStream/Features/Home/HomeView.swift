import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var catalog: CatalogStore
    let torrents: [Torrent]
    let onSearch: (String) -> Void
    let onAdd: () -> Void
    let onOpenLibrary: () -> Void
    let onPlay: (TorrentSearchTarget) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                playbackSuggestions(isNextEpisode: false)
                playbackSuggestions(isNextEpisode: true)
                if torrents.isEmpty { firstSteps } else { recentTorrents }
                howItWorks
            }
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 35)
        }
        .scrollIndicators(.hidden)
    }

    private var hero: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 20).fill(Color(red: 0.12, green: 0.18, blue: 0.18))
            GeometryReader { proxy in
                ZStack {
                    RadialGradient(colors: [KinoPalette.accent.opacity(0.4), .clear], center: .center, startRadius: 10, endRadius: 240)
                    Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: 280, height: 280)
                    Circle().stroke(.white.opacity(0.06), lineWidth: 1).frame(width: 400, height: 400)
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 105, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.16))
                }
                .frame(width: 460, height: proxy.size.height)
                .offset(x: proxy.size.width - 450)
            }
            LinearGradient(colors: [.black.opacity(0.16), .clear, .black.opacity(0.24)], startPoint: .leading, endPoint: .trailing)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 7) {
                    Circle().fill(KinoPalette.accent).frame(width: 6, height: 6)
                    Text("ВАШЕ КИНО ПРОСТРАНСТВО")
                        .font(.system(size: 9, weight: .bold)).tracking(1.8).foregroundStyle(KinoPalette.accent)
                }
                Text("Большое кино.\nБез лишних пауз.")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .lineSpacing(1)
                    .foregroundStyle(.white)
                Text("Найдите раздачу или добавьте свою ссылку — видео пойдёт через ваш TorrServer.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: 390, alignment: .leading)
                HStack(spacing: 10) {
                    Button { onSearch("") } label: { Label("Найти раздачу", systemImage: "magnifyingglass") }
                        .buttonStyle(AccentButtonStyle())
                    Button(action: onAdd) {
                        Label("Добавить magnet", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13)
                            .frame(height: 37)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 1)
            }
            .padding(.leading, 36)
            .padding(.vertical, 30)
        }
        .frame(height: 295)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private func playbackSuggestions(isNextEpisode: Bool) -> some View {
        let suggestions = catalog.homePlaybackSuggestions.filter { $0.isNextEpisode == isNextEpisode }
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(
                    title: isNextEpisode ? "Следующая серия" : "Продолжить просмотр",
                    subtitle: isNextEpisode ? "Продолжайте сериалы с того места, где остановились" : "Сохранённые позиции фильмов и серий"
                )
                ForEach(Array(suggestions.prefix(6))) { suggestion in
                    Button { onPlay(TorrentSearchTarget(context: suggestion.context)) } label: {
                        HStack(spacing: 13) {
                            Image(systemName: isNextEpisode ? "forward.end.fill" : "play.fill")
                                .foregroundStyle(KinoPalette.accent)
                                .frame(width: 36, height: 36)
                                .background(KinoPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(suggestion.context.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                HStack(spacing: 10) {
                                    if let season = suggestion.context.season, let episode = suggestion.context.episode {
                                        Text(String(format: "Сезон %d · Серия %d", season, episode))
                                    }
                                    if let record = suggestion.record {
                                        Text("\(Int(record.position / 60)) из \(Int(record.duration / 60)) мин")
                                    }
                                }
                                .font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                                if let record = suggestion.record {
                                    ProgressView(value: record.fraction).tint(KinoPalette.accent).frame(maxWidth: 240)
                                }
                            }
                            Spacer()
                            Text(isNextEpisode ? "Смотреть" : "Продолжить")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(KinoPalette.accent)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var firstSteps: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "С чего начнём?", subtitle: "Найдите фильм через Cinemeta и Кинопоиск или раздачу через JacRed")
            HStack(spacing: 14) {
                firstStepCard(number: "01", symbol: "magnifyingglass", title: "Найти раздачу", detail: "Введите название фильма или сериала") { onSearch("") }
                firstStepCard(number: "02", symbol: "link", title: "Вставить magnet", detail: "Добавьте свою ссылку напрямую", action: onAdd)
            }
        }
    }

    private func firstStepCard(number: String, symbol: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(KinoPalette.accent)
                    .frame(width: 36, height: 36)
                    .background(KinoPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text("ШАГ \(number)").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(KinoPalette.muted)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(detail).font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(KinoPalette.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(KinoPalette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var recentTorrents: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .bottom) {
                SectionHeading(title: "Добавлено на сервер", subtitle: "Последние раздачи в вашей коллекции")
                Button(action: onOpenLibrary) {
                    HStack(spacing: 6) {
                        Text("Вся коллекция")
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KinoPalette.accent)
                    .padding(.bottom, 3)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 9) {
                ForEach(Array(torrents.prefix(4))) { torrent in
                    HStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(KinoPalette.accent)
                            .frame(width: 39, height: 42)
                            .background(KinoPalette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(torrent.displayTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            HStack(spacing: 10) {
                                Text(torrent.statString ?? "Добавлена")
                                if let size = torrent.torrentSize, size > 0 { Text(size.fileSizeLabel) }
                                Text("\(torrent.fileStats.count) файлов")
                            }
                            .font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(KinoPalette.muted)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(KinoPalette.card, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(KinoPalette.line, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 11))
                    .onTapGesture(perform: onOpenLibrary)
                }
            }
        }
    }

    private var howItWorks: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: "info.circle")
                .font(.system(size: 16))
                .foregroundStyle(KinoPalette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Нужен TorrServer")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text("Каталог объединяет Cinemeta и Кинопоиск; JacRed ищет раздачи, а TorrServer загружает выбранное видео.")
                    .font(.system(size: 11)).foregroundStyle(KinoPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
