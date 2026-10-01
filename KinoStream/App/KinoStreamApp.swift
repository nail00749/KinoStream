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
