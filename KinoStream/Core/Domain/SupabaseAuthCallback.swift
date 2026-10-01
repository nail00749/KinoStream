import Foundation

enum SupabaseAuthCallback {
    enum Kind { case signup, recovery }
    static let scheme = "ru.nailultyev.kinostream"
    static let signupURL = URL(string: "ru.nailultyev.kinostream://auth-callback/signup")!
    static let recoveryURL = URL(string: "ru.nailultyev.kinostream://auth-callback/recovery")!

    static func kind(for url: URL) -> Kind? {
        guard url.scheme?.lowercased() == scheme, url.host == "auth-callback",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        switch url.path {
        case "/signup": return .signup
        case "/recovery": return .recovery
        default: return nil
        }
    }
}
