import Foundation
import Supabase

struct SupabaseEnvironment {
    let projectURL: String
    let publishableKey: String

    var hasCredentials: Bool {
        !projectURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publishableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func loadFromBundle() -> SupabaseEnvironment? {
        guard let url = Bundle.main.url(forResource: ".env", withExtension: nil),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            values[name] = value
        }

        guard let projectURL = values["SUPABASE_URL"],
              let publishableKey = values["SUPABASE_PUBLISHABLE_KEY"] else {
            return SupabaseEnvironment(projectURL: "", publishableKey: "")
        }
        return SupabaseEnvironment(projectURL: projectURL, publishableKey: publishableKey)
    }
}

struct SupabaseLibrarySyncService {
    private let client: SupabaseClient
    private let projectURL: URL
    private let publishableKey: String

    init(projectURL: String, publishableKey: String) throws {
        let rawURL = projectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              !key.isEmpty,
              !Self.isServiceRoleKey(key) else {
            throw SupabaseLibrarySyncError.invalidConfiguration
        }

        self.projectURL = url
        self.publishableKey = key
        client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: .init(auth: .init(storage: KeychainLocalStorage(service: "ru.nailultyev.kinostream.supabase")))
        )
    }

    private static func isServiceRoleKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_secret_") || key.localizedCaseInsensitiveContains("service_role") {
            return true
        }
        let components = key.split(separator: ".")
        guard components.count == 3 else { return false }
        var payload = String(components[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        let role = claims["role"] as? String
        return role == "service_role" || role == "supabase_admin"
    }

    func makePasswordRecoveryService() -> PasswordRecoveryService {
        PasswordRecoveryService(projectURL: projectURL, publishableKey: publishableKey)
    }

    func signIn(email: String, password: String) async throws -> Session {
        do {
            return try await client.auth.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
        } catch {
            throw SupabaseLibrarySyncError.signInFailed
        }
    }

    func signUp(email: String, password: String) async throws -> AuthResponse {
        do {
            return try await client.auth.signUp(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                redirectTo: SupabaseAuthCallback.signupURL
            )
        } catch {
            throw SupabaseLibrarySyncError.signUpFailed
        }
    }

    func confirmSignup(from url: URL) async throws -> Session {
        guard SupabaseAuthCallback.kind(for: url) == .signup else { throw SupabaseLibrarySyncError.authCallbackFailed }
        do { return try await client.auth.session(from: url) }
        catch { throw SupabaseLibrarySyncError.authCallbackFailed }
    }

    func resendSignupConfirmation(email: String) async throws {
        do {
            try await client.auth.resend(email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                type: .signup, emailRedirectTo: SupabaseAuthCallback.signupURL)
        } catch { throw SupabaseLibrarySyncError.confirmationEmailFailed }
    }

    func restoreSession() async throws -> Session {
        do {
            return try await client.auth.session
        } catch {
            throw SupabaseLibrarySyncError.sessionUnavailable
        }
    }

    func signOut() async throws {
        do {
            try await client.auth.signOut()
        } catch {
            throw SupabaseLibrarySyncError.signOutFailed
        }
    }

    func fetchLibrary(for userID: UUID) async throws -> CatalogSyncSnapshot? {
        do {
            let records: [LibraryRecord] = try await client
                .from("kinostream_library")
                .select("user_id,snapshot")
                .eq("user_id", value: userID.uuidString)
                .limit(1)
                .execute()
                .value
            return records.first?.snapshot
        } catch {
            throw SupabaseLibrarySyncError.syncFailed
        }
    }

    func fetchEntries(for userID: UUID) async throws -> [LibrarySyncEntry] {
        do {
            var entries: [LibrarySyncEntry] = []
            let pageSize = 200
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page: [LibraryEntryRow] = try await client.from("kinostream_library_entries")
                    .select("entry").eq("user_id", value: userID.uuidString)
                    .order("entry_key", ascending: true)
                    .range(from: offset, to: offset + pageSize - 1).execute().value
                entries.append(contentsOf: page.map(\.entry))
                if page.count < pageSize { break }
                offset += pageSize
            }
            if !entries.isEmpty { return entries }
            // Import the previous format only when this account has no versioned entries.
            if let legacy = try await fetchLibrary(for: userID) {
                return Array(LibrarySyncEntry.entries(from: legacy).values)
            }
            return []
        } catch let error as PostgrestError where error.code == "PGRST205" || error.code == "42P01" {
            throw SupabaseLibrarySyncError.migrationRequired
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SupabaseLibrarySyncError.syncFailed
        }
    }

    func mergeEntries(_ entries: [LibrarySyncEntry], for userID: UUID) async throws -> [LibrarySyncEntry] {
        do {
            try await client
                .rpc("merge_kinostream_library_entries", params: LibraryMergeParameters(entries: entries))
                .execute()
            return try await fetchEntries(for: userID)
        } catch let error as PostgrestError where error.code == "PGRST202" || error.code == "42883" {
            throw SupabaseLibrarySyncError.migrationRequired
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SupabaseLibrarySyncError.syncFailed
        }
    }

}

enum SupabaseLibrarySyncError: LocalizedError {
    case invalidConfiguration
    case signInFailed
    case signUpFailed
    case sessionUnavailable
    case signOutFailed
    case syncFailed
    case migrationRequired
    case recoveryEmailFailed
    case recoveryTokenFailed
    case passwordUpdateFailed
    case authCallbackFailed
    case confirmationEmailFailed

    var errorDescription: String? {
        switch self {
        case .confirmationEmailFailed:
            "Не удалось отправить подтверждение. Проверьте email и соединение, затем попробуйте позже."
        case .authCallbackFailed:
            "Не удалось открыть ссылку входа. Если email уже подтверждён, войдите с паролем. Для восстановления запросите новое письмо на этом Mac."
        case .recoveryEmailFailed:
            "Не удалось отправить письмо. Проверьте email и соединение, затем попробуйте позже."
        case .recoveryTokenFailed:
            "Не удалось подтвердить восстановление. Ссылка или код должны быть из последнего письма для этого email. Запросите новое письмо, если срок действия истёк."
        case .passwordUpdateFailed:
            "Не удалось изменить пароль. Проверьте соединение и требования к паролю в Supabase, затем повторите попытку."
        case .invalidConfiguration:
            "Введите корректный URL и публичный anon/publishable key Supabase. Ключ service_role использовать нельзя."
        case .signInFailed:
            "Не удалось войти. Проверьте email, пароль и настройки Supabase."
        case .signUpFailed:
            "Не удалось создать аккаунт. Проверьте email и требования к паролю в Supabase."
        case .sessionUnavailable:
            "Сохранённая сессия Supabase недоступна. Войдите снова."
        case .signOutFailed:
            "Не удалось завершить сеанс. Попробуйте ещё раз."
        case .migrationRequired:
            "Обновите схему Supabase: примените миграцию 20261001000000_kinostream_library_entries.sql. Локальные изменения сохранены."
        case .syncFailed:
            "Не удалось синхронизировать библиотеку. Проверьте SQL-миграцию и соединение."
        }
    }
}

/// Recovery sessions never replace the signed-in account or persist to disk.
final class PasswordRecoveryService {
    private let client: SupabaseClient
    private let projectURL: URL
    private(set) var verifiedEmail: String?

    init(projectURL: URL, publishableKey: String) {
        self.projectURL = projectURL
        client = SupabaseClient(supabaseURL: projectURL, supabaseKey: publishableKey,
            options: .init(auth: .init(storage: RecoveryMemoryStorage(),
                storageKey: "kinostream-password-recovery", flowType: .pkce)))
    }

    func sendEmail(_ email: String) async throws {
        verifiedEmail = nil
        do { try await client.auth.resetPasswordForEmail(email, redirectTo: SupabaseAuthCallback.recoveryURL) }
        catch { throw SupabaseLibrarySyncError.recoveryEmailFailed }
    }

    func acceptCallback(_ url: URL) async throws {
        guard SupabaseAuthCallback.kind(for: url) == .recovery else { throw SupabaseLibrarySyncError.authCallbackFailed }
        do {
            let session = try await client.auth.session(from: url)
            guard let email = session.user.email, !email.isEmpty else { throw SupabaseLibrarySyncError.recoveryTokenFailed }
            verifiedEmail = email
        } catch { throw SupabaseLibrarySyncError.recoveryTokenFailed }
    }

    func verify(email: String, credential: String) async throws {
        do {
            let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            let response: AuthResponse
            if value.count == 6, value.allSatisfy(\.isNumber) {
                response = try await client.auth.verifyOTP(email: email, token: value, type: .recovery)
            } else {
                guard let components = URLComponents(string: value),
                      components.scheme == projectURL.scheme, components.host == projectURL.host,
                      components.port == projectURL.port, components.user == nil, components.password == nil,
                      components.path == "/auth/v1/verify",
                      components.queryItems?.first(where: { $0.name == "type" })?.value == "recovery",
                      let token = components.queryItems?.first(where: { $0.name == "token" || $0.name == "token_hash" })?.value,
                      !token.isEmpty else { throw SupabaseLibrarySyncError.recoveryTokenFailed }
                response = try await client.auth.verifyOTP(tokenHash: token, type: .recovery)
            }
            guard response.session != nil, response.user.email?.lowercased() == email.lowercased() else {
                try? await client.auth.signOut(scope: .local)
                throw SupabaseLibrarySyncError.recoveryTokenFailed
            }
            verifiedEmail = response.user.email
        } catch { throw SupabaseLibrarySyncError.recoveryTokenFailed }
    }

    func setPassword(_ password: String) async throws {
        guard verifiedEmail != nil else { throw SupabaseLibrarySyncError.recoveryTokenFailed }
        do { _ = try await client.auth.update(user: UserAttributes(password: password)) }
        catch { throw SupabaseLibrarySyncError.passwordUpdateFailed }
        try? await client.auth.signOut(scope: .local)
        verifiedEmail = nil
    }
}

private final class RecoveryMemoryStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private let verifierStorage = KeychainLocalStorage(service: "ru.nailultyev.kinostream.recovery-verifier")
    func store(key: String, value: Data) throws {
        if key.hasSuffix("-code-verifier") { try verifierStorage.store(key: key, value: value); return }
        lock.lock(); defer { lock.unlock() }; values[key] = value
    }
    func retrieve(key: String) throws -> Data? {
        if key.hasSuffix("-code-verifier") { return try verifierStorage.retrieve(key: key) }
        lock.lock(); defer { lock.unlock() }; return values[key]
    }
    func remove(key: String) throws {
        if key.hasSuffix("-code-verifier") { try verifierStorage.remove(key: key); return }
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: key)
    }
}

private struct LibraryRecord: Codable {
    let userID: UUID
    let snapshot: CatalogSyncSnapshot

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case snapshot
    }
}

private struct LibraryEntryRow: Decodable {
    let entry: LibrarySyncEntry
}

private struct LibraryMergeParameters: Encodable {
    let entries: [LibrarySyncEntry]
    enum CodingKeys: String, CodingKey { case entries = "p_entries" }
}
