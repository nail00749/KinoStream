import SwiftUI

struct AuthLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(KinoPalette.accent)
            Text("Проверяем аккаунт…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(KinoPalette.muted)
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(KinoPalette.background)
    }
}

struct SupabaseConfigurationView: View {
    var body: some View {
        VStack(spacing: 22) {
            AuthBranding()

            SurfaceCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Нужно настроить Supabase")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Добавьте параметры проекта в файл .env в корне проекта, затем соберите и запустите приложение снова.")
                        .font(.system(size: 12))
                        .foregroundStyle(KinoPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("SUPABASE_URL=https://ваш-проект.supabase.co\nSUPABASE_PUBLISHABLE_KEY=sb_publishable_…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(KinoPalette.accent)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
                    Text("Используйте публичный publishable или anon key. Ключ service_role сюда добавлять нельзя.")
                        .font(.system(size: 10))
                        .foregroundStyle(KinoPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 390)
        }
        .padding(28)
        .frame(minWidth: 480, minHeight: 560)
        .background(KinoPalette.background)
    }
}

struct SupabaseAuthView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var catalog: CatalogStore
    @State private var email = ""
    @State private var password = ""
    @State private var isCreatingAccount = false
    @State private var hasSubmitted = false
    @State private var showingRecovery = false

    private var canSubmit: Bool {
        email.trimmingCharacters(in: .whitespacesAndNewlines).contains("@") && !password.isEmpty && !model.isCloudBusy
    }

    var body: some View {
        VStack(spacing: 22) {
            AuthBranding()

            SurfaceCard {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 8) {
                        authModeButton("Войти", isSelected: !isCreatingAccount) { isCreatingAccount = false }
                        authModeButton("Регистрация", isSelected: isCreatingAccount) { isCreatingAccount = true }
                    }
                    .padding(4)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 7) {
                        Text("EMAIL")
                            .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(KinoPalette.muted)
                        TextField("name@example.com", text: $email)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 11)
                            .frame(height: 40)
                            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("ПАРОЛЬ")
                            .font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(KinoPalette.muted)
                        SecureField("Пароль", text: $password)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .textContentType(isCreatingAccount ? .newPassword : .password)
                            .padding(.horizontal, 11)
                            .frame(height: 40)
                            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07), lineWidth: 1))
                            .onSubmit(submit)
                    }

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if model.isCloudBusy { ProgressView().controlSize(.small).tint(KinoPalette.background) }
                            else { Image(systemName: isCreatingAccount ? "person.badge.plus" : "person.crop.circle") }
                            Text(model.isCloudBusy ? "Подождите…" : (isCreatingAccount ? "Создать аккаунт" : "Войти"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!canSubmit)

                    if !isCreatingAccount {
                        Button("Забыли пароль?") { showingRecovery = true }
                            .buttonStyle(.plain)
                            .foregroundStyle(KinoPalette.accent)
                            .disabled(model.isCloudBusy)
                    }

                    if hasSubmitted && model.supabaseUserEmail == nil {
                        Text(model.cloudSyncStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(statusColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 390)

            Text("Избранное, просмотренное и прогресс будут синхронизироваться между вашими устройствами.")
                .font(.system(size: 10))
                .foregroundStyle(KinoPalette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)
        }
        .padding(28)
        .frame(minWidth: 480, minHeight: 560)
        .background(KinoPalette.background)
        .sheet(isPresented: $showingRecovery) {
            PasswordRecoveryView(initialEmail: email)
        }
    }

    private var statusColor: Color {
        model.cloudSyncStatus.hasPrefix("Не удалось") ? .orange : KinoPalette.muted
    }

    private func authModeButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? .white : KinoPalette.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 31)
                .background(isSelected ? KinoPalette.card : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        guard canSubmit else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password
        hasSubmitted = true
        Task {
            if isCreatingAccount {
                await model.createSupabaseAccount(email: email, password: password, with: catalog)
            } else {
                await model.signInToSupabase(email: email, password: password, with: catalog)
            }
            if model.supabaseUserEmail != nil || model.cloudSyncStatus.contains("Проверьте почту") {
                self.password = ""
            }
        }
    }
}

private struct PasswordRecoveryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email: String
    @State private var credential = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var step = 0
    @State private var busy = false
    @State private var message: String?
    @State private var service: PasswordRecoveryService?

    init(initialEmail: String) { _email = State(initialValue: initialEmail.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Восстановление пароля").font(.title2.bold())
                Spacer()
                Button("Закрыть") { dismiss() }.disabled(busy)
            }
            if step == 0 {
                Text("Отправим письмо для восстановления доступа.").foregroundStyle(KinoPalette.muted)
                TextField("Email", text: $email).textContentType(.emailAddress).autocorrectionDisabled()
                Button("Отправить письмо") { perform {
                    let recovery = try model.makePasswordRecoveryService()
                    try await recovery.sendEmail(email.trimmingCharacters(in: .whitespacesAndNewlines))
                    service = recovery
                    email = email.trimmingCharacters(in: .whitespacesAndNewlines)
                    step = 1
                } }.buttonStyle(AccentButtonStyle()).disabled(busy || !email.contains("@"))
            } else if step == 1 {
                Text("Если аккаунт существует, письмо придёт на \(email). Проверьте также папку «Спам».")
                Text("Скопируйте ссылку восстановления из письма, не открывая её, и вставьте ниже. Если письмо содержит шестизначный код, можно ввести его.")
                    .foregroundStyle(KinoPalette.muted).fixedSize(horizontal: false, vertical: true)
                SecureField("Ссылка из письма или код", text: $credential)
                Button("Подтвердить") { perform {
                    guard let service else { throw SupabaseLibrarySyncError.invalidConfiguration }
                    try await service.verify(email: email, credential: credential)
                    credential = ""
                    step = 2
                } }.buttonStyle(AccentButtonStyle()).disabled(busy || credential.isEmpty)
                Button("Запросить новое письмо") {
                    credential = ""; service = nil; message = nil; step = 0
                }.disabled(busy)
            } else if step == 2 {
                Text("Задайте новый пароль — минимум 6 символов.").foregroundStyle(KinoPalette.muted)
                SecureField("Новый пароль", text: $password).textContentType(.newPassword)
                SecureField("Повторите пароль", text: $confirmation).textContentType(.newPassword)
                if !confirmation.isEmpty && password != confirmation {
                    Text("Пароли не совпадают").foregroundStyle(.orange)
                }
                Button("Сохранить пароль") { perform {
                    guard let service else { throw SupabaseLibrarySyncError.invalidConfiguration }
                    try await service.setPassword(password)
                    password = ""; confirmation = ""; self.service = nil; step = 3
                } }.buttonStyle(AccentButtonStyle()).disabled(busy || password.count < 6 || password != confirmation)
            } else {
                Label("Пароль изменён", systemImage: "checkmark.circle.fill").foregroundStyle(KinoPalette.accent)
                Text("Войдите с новым паролем.")
                Button("Вернуться ко входу") { dismiss() }.buttonStyle(AccentButtonStyle())
            }
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13))
        .padding(28)
        .frame(width: 510)
        .background(KinoPalette.background)
        .interactiveDismissDisabled(busy)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch { message = error.localizedDescription }
        }
    }
}

private struct AuthBranding: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.fill")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(KinoPalette.background)
                .frame(width: 54, height: 54)
                .background(KinoPalette.accent, in: RoundedRectangle(cornerRadius: 16))
            Text("KinoStream")
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Войдите, чтобы открыть приложение")
                .font(.system(size: 11))
                .foregroundStyle(KinoPalette.muted)
        }
    }
}
