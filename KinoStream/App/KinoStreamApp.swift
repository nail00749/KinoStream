import AppKit
import SwiftUI

@main
struct KinoStreamApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var catalog = CatalogStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if !model.isSupabaseSessionRestored {
                    AuthLoadingView()
                } else if !model.isSupabaseConfigured {
                    SupabaseConfigurationView()
                } else if model.supabaseUserEmail == nil {
                    SupabaseAuthView()
                } else {
                    RootView()
                        .frame(minWidth: 1040, minHeight: 700)
                }
            }
            .environmentObject(model)
            .environmentObject(catalog)
            .environmentObject(model.torrServerController)
            .preferredColorScheme(.dark)
            .task {
                await model.restoreSupabaseSession(with: catalog)
            }
            .onOpenURL { url in
                Task { await model.receiveAuthCallback(url, with: catalog) }
            }
            .onChange(of: model.isCloudBusy) { _, busy in
                if !busy { Task { await model.resumeAuthCallback(with: catalog) } }
            }
            .sheet(isPresented: $model.isPasswordRecoveryPresented, onDismiss: {
                model.finishPasswordRecovery()
            }) {
                PasswordRecoveryView(initialEmail: model.passwordRecoveryEmail)
            }
            .alert("Ссылка из письма", isPresented: Binding(
                get: { model.authCallbackMessage != nil },
                set: { if !$0 { model.authCallbackMessage = nil } }
            )) {
                Button("Понятно", role: .cancel) { model.authCallbackMessage = nil }
            } message: { Text(model.authCallbackMessage ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.stopVLCPlaybackMonitoring()
                model.stopBundledTorrServer()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
