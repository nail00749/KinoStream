import AppKit

enum PasswordManagerSupport {
    @MainActor
    static func openManager() {
        let workspace = NSWorkspace.shared
        let identifier = workspace.urlForApplication(withBundleIdentifier: "com.apple.Passwords") != nil
            ? "com.apple.Passwords" : "com.apple.systempreferences"
        guard let url = workspace.urlForApplication(withBundleIdentifier: identifier) else { return }
        workspace.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}
