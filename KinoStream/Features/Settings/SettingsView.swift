import SwiftUI

struct SettingsView: View {
    @AppStorage("autoplayNextEpisode") private var autoplayNextEpisode = true
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: CatalogStore
    @EnvironmentObject private var torrServerController: TorrServerProcessController
    @State private var jacredStatus: String?
    @State private var isCheckingJacRed = false
    @State private var cinemetaStatus: String?
    @State private var isCheckingCinemeta = false
    @State private var kinopoiskStatus: String?
    @State private var isCheckingKinopoisk = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionHeading(title: "Настройки", subtitle: "Каталог, поиск раздач и воспроизведение")

                supabaseSection

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        serviceHeading(symbol: "film.stack", title: "Каталог фильмов и сериалов", subtitle: "Объединённый поиск Cinemeta и Кинопоиска")
                        Text("Cinemeta работает без ключа. Ключ Кинопоиска добавляет русские карточки, рейтинги и списки серий; если ключ не задан, каталог продолжит работать через Cinemeta.")
                            .font(.system(size: 11)).foregroundStyle(KinoPalette.muted).fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    isCheckingCinemeta = true
                                    defer { isCheckingCinemeta = false }
                                    do { try await model.checkCinemeta(); cinemetaStatus = "Подключено" }
                                    catch { cinemetaStatus = error.localizedDescription }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if isCheckingCinemeta { ProgressView().controlSize(.small).tint(KinoPalette.background) }
                                    else { Image(systemName: "bolt.horizontal.fill") }
                                    Text(isCheckingCinemeta ? "Проверяем…" : "Проверить Cinemeta")
                                }
                            }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(isCheckingCinemeta)
                            if let cinemetaStatus {
                                Text(cinemetaStatus).font(.system(size: 10)).foregroundStyle(cinemetaStatus == "Подключено" ? KinoPalette.accent : .orange)
                            }
                        }

                        field(title: "Ключ API Кинопоиска", hint: "Хранится в Связке ключей macOS") {
                            SecureField("Вставьте API-ключ Кинопоиска", text: $model.kinopoiskAPIKey)
                                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        }
                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    isCheckingKinopoisk = true
                                    defer { isCheckingKinopoisk = false }
                                    do { try await model.checkKinopoisk(); kinopoiskStatus = "Подключено" }
                                    catch { kinopoiskStatus = error.localizedDescription }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if isCheckingKinopoisk { ProgressView().controlSize(.small).tint(KinoPalette.background) }
                                    else { Image(systemName: "bolt.horizontal.fill") }
                                    Text(isCheckingKinopoisk ? "Проверяем…" : "Проверить Кинопоиск")
                                }
                            }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(isCheckingKinopoisk || model.kinopoiskAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Link("Получить API-ключ", destination: URL(string: "https://kinopoiskapiunofficial.tech/signup")!)
                                .font(.system(size: 10, weight: .semibold)).tint(KinoPalette.accent)
                            if let kinopoiskStatus {
                                Text(kinopoiskStatus).font(.system(size: 10)).foregroundStyle(kinopoiskStatus == "Подключено" ? KinoPalette.accent : .orange)
                            }
                        }
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 17) {
                        serviceHeading(symbol: "magnifyingglass", title: "JacRed", subtitle: "Поиск раздач по названию, году и типу")
                        field(title: "Адрес JacRed", hint: "Ключ API не требуется") {
                            TextField("https://jac.red", text: $model.jacredEndpoint)
                                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        }
                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    isCheckingJacRed = true
                                    defer { isCheckingJacRed = false }
                                    do { try await model.checkJacRed(); jacredStatus = "Подключено" }
                                    catch { jacredStatus = error.localizedDescription }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if isCheckingJacRed { ProgressView().controlSize(.small).tint(KinoPalette.background) }
                                    else { Image(systemName: "bolt.horizontal.fill") }
                                    Text(isCheckingJacRed ? "Проверяем…" : "Проверить JacRed")
                                }
                            }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(isCheckingJacRed)
                            if let jacredStatus { Text(jacredStatus).font(.system(size: 10)).foregroundStyle(jacredStatus == "Подключено" ? KinoPalette.accent : .orange) }
                        }
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 19) {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(KinoPalette.accent)
                                .frame(width: 32, height: 32)
                                .background(KinoPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("TorrServer").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                Text(model.torrServerMode == .bundled ? "Локальный сервер KinoStream" : "Подключение к вашему серверу")
                                    .font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
                            }
                            Spacer()
                            connectionStatus
                        }

                        Picker("Режим TorrServer", selection: $model.torrServerMode) {
                            ForEach(TorrServerMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)

                        if model.torrServerMode == .bundled {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Встроенный TorrServer запускается вместе с приложением и принимает подключения только с этого Mac. Данные сервера и кэш торрентов хранятся в папке Application Support.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(KinoPalette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                field(title: "Локальный адрес", hint: "Доступен только этому Mac") {
                                    Text(model.activeServerURL)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.82))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        } else {
                            field(title: "Адрес внешнего сервера", hint: "Например, http://192.168.1.10:8090") {
                                TextField("http://127.0.0.1:8090", text: $model.serverURL)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .monospaced))
                            }

                            HStack(spacing: 14) {
                                field(title: "Логин", hint: "Необязательно") {
                                    TextField("Необязательно", text: $model.username)
                                        .textFieldStyle(.plain).font(.system(size: 12))
                                }
                                field(title: "Пароль", hint: "Хранится в Связке ключей") {
                                    SecureField("Необязательно", text: $model.password)
                                        .textFieldStyle(.plain).font(.system(size: 12))
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                Task { await model.checkConnection() }
                            } label: {
                                HStack(spacing: 8) {
                                    if model.isCheckingConnection { ProgressView().controlSize(.small).tint(KinoPalette.background) }
                                    else { Image(systemName: "bolt.horizontal.fill") }
                                    Text(model.isCheckingConnection ? "Проверяем…" : "Проверить соединение")
                                }
                            }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(model.isCheckingConnection)
                            Text("JacRed находит раздачи, TorrServer принимает выбранный magnet или торрент-файл.")
                                .font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                        }
                    }
                }

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "play.rectangle.fill")
                                .foregroundStyle(KinoPalette.accent)
                                .frame(width: 32, height: 32)
                                .background(KinoPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Воспроизведение").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                Text("Выберите, где открывать видео из поиска и коллекции.")
                                    .font(.system(size: 11)).foregroundStyle(KinoPalette.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Picker("Плеер", selection: $model.playbackPlayer) {
                            ForEach(PlaybackPlayer.allCases) { player in
                                Text(player.title).tag(player)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)

                        Toggle("Автоматически включать следующую серию", isOn: $autoplayNextEpisode)
                            .onChange(of: autoplayNextEpisode) { _, enabled in
                                if !enabled { model.playbackController.cancelAutoplay() }
                            }

                        if model.playbackPlayer == .vlc {
                            Text(!model.activeServerRequiresAuthentication
                                 ? "Ссылки TorrServer будут открываться во VLC. VLC должен быть установлен на этом Mac."
                                 : "Для TorrServer с логином и паролем используйте встроенный плеер: VLC не получает данные авторизации.")
                                .font(.system(size: 10))
                                .foregroundStyle(model.activeServerRequiresAuthentication ? .orange : KinoPalette.muted)
                            Text("Сохранение позиции и автоматическая отметка просмотра доступны во встроенном плеере.")
                                .font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                        } else {
                            Text("Видео воспроизводится во встроенном плеере приложения.")
                                .font(.system(size: 10)).foregroundStyle(KinoPalette.muted)
                        }
                    }
                }

                SurfaceCard {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(KinoPalette.accent)
                            .frame(width: 32, height: 32)
                            .background(KinoPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Link("Cinemeta", destination: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!)
                                Link("Документация API Кинопоиска", destination: URL(string: "https://kinopoiskapiunofficial.tech/documentation/api/")!)
                            }
                            .font(.system(size: 12, weight: .semibold)).tint(.white)
                            Text("Каталог объединяет результаты Cinemeta и Кинопоиска по IMDb ID, когда он доступен. Ключ Кинопоиска и пароль TorrServer хранятся в Связке ключей macOS.")
                                .font(.system(size: 10)).foregroundStyle(KinoPalette.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(KinoPalette.accent)
                    Text("API-ключ Кинопоиска и пароль TorrServer хранятся в Связке ключей macOS.")
                        .foregroundStyle(KinoPalette.muted)
                }
                .font(.system(size: 10))
            }
            .padding(30)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onChange(of: model.torrServerMode) { _, _ in
            Task { await model.changeTorrServerMode() }
        }
    }

    private func field<Content: View>(title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(KinoPalette.muted)
            content()
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07), lineWidth: 1))
            if !hint.isEmpty { Text(hint).font(.system(size: 9)).foregroundStyle(KinoPalette.muted.opacity(0.8)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var supabaseSection: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 16) {
                serviceHeading(
                    symbol: "icloud.and.arrow.up",
                    title: "Supabase",
                    subtitle: "Аккаунт и синхронизация между устройствами"
                )

                Text("Синхронизируются избранные фильмы и сериалы, просмотренное и позиции просмотра. Избранные раздачи и ссылки TorrServer остаются только на этом Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(KinoPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Состояние синхронизации и подключения аккаунта показано ниже.")
                    .font(.system(size: 10))
                    .foregroundStyle(KinoPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if let email = model.supabaseUserEmail {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(KinoPalette.accent)
                        Text(email).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Spacer()
                        Button("Выйти") {
                            Task { await model.signOutFromSupabase() }
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isCloudBusy)
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await model.syncSupabaseLibrary(with: catalog) }
                        } label: {
                            HStack(spacing: 8) {
                                if model.isCloudBusy { ProgressView().controlSize(.small).tint(KinoPalette.background) }
                                else { Image(systemName: "arrow.triangle.2.circlepath") }
                                Text(model.isCloudBusy ? "Синхронизируем…" : "Синхронизировать")
                            }
                        }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(model.isCloudBusy)
                    }
                }

                Text(model.cloudSyncStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(cloudStatusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cloudStatusColor: Color {
        if model.cloudSyncStatus.contains("синхронизирована") || model.cloudSyncStatus.contains("подключён") {
            return KinoPalette.accent
        }
        if model.cloudSyncStatus.contains("Не удалось") || model.cloudSyncStatus.contains("Введите") {
            return .orange
        }
        return KinoPalette.muted
    }

    private func serviceHeading(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(KinoPalette.accent)
                .frame(width: 32, height: 32)
                .background(KinoPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(KinoPalette.muted)
            }
        }
    }

    private var connectionStatus: some View {
        let statusTitle: String = {
            guard model.torrServerMode == .bundled else { return model.connected ? "Подключено" : "Отключено" }
            return torrServerController.status.title
        }()
        let isReady = model.torrServerMode == .bundled
            ? torrServerController.status == .running
            : model.connected
        return HStack(spacing: 6) {
            Circle().fill(isReady ? KinoPalette.accent : Color.orange).frame(width: 6, height: 6)
            Text(statusTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isReady ? KinoPalette.accent : KinoPalette.muted)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.black.opacity(0.18), in: Capsule())
    }
}
