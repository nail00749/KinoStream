import Combine
import Darwin
import Foundation

enum TorrServerMode: String, CaseIterable, Identifiable {
    case bundled
    case external

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundled: "Встроенный"
        case .external: "Внешний"
        }
    }
}

enum LocalTorrServerStatus: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Остановлен"
        case .starting: "Запускается…"
        case .running: "Запущен"
        case .failed(let message): message
        }
    }
}

@MainActor
final class TorrServerProcessController: ObservableObject {
    @Published private(set) var status: LocalTorrServerStatus = .stopped
    @Published private(set) var serverURL: String?

    private var process: Process?
    private let portRange: ClosedRange<UInt16> = 8090...8100

    static var isSupportedArchitecture: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func startIfNeeded() throws {
        guard Self.isSupportedArchitecture else {
            throw TorrServerProcessError.unsupportedArchitecture
        }
        if isRunning { return }

        let executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TorrServer")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw TorrServerProcessError.binaryMissing
        }

        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KinoStream/TorrServer", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try prepareSettings(in: supportDirectory)

        let port = try availablePort()
        let serverProcess = Process()
        serverProcess.executableURL = executableURL
        serverProcess.arguments = [
            "--ip", "127.0.0.1",
            "--port", String(port),
            "--path", supportDirectory.path
        ]
        serverProcess.currentDirectoryURL = supportDirectory
        serverProcess.standardOutput = FileHandle.nullDevice
        serverProcess.standardError = FileHandle.nullDevice
        serverProcess.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self, self.process === terminatedProcess else { return }
                self.process = nil
                self.serverURL = nil
                self.status = .failed("TorrServer завершился")
            }
        }

        status = .starting
        do {
            try serverProcess.run()
            process = serverProcess
            serverURL = "http://127.0.0.1:\(port)"
        } catch {
            status = .failed("Не удалось запустить встроенный TorrServer")
            throw TorrServerProcessError.launchFailed
        }
    }

    func markReady() {
        guard isRunning else { return }
        status = .running
    }

    func markFailed(_ message: String) {
        status = .failed(message)
    }

    func stop() {
        guard let process else {
            serverURL = nil
            status = .stopped
            return
        }

        if process.isRunning { process.terminate() }
        self.process = nil
        serverURL = nil
        status = .stopped
    }

    private func availablePort() throws -> UInt16 {
        guard let port = portRange.first(where: isPortAvailable) else {
            throw TorrServerProcessError.noAvailablePort
        }
        return port
    }

    private func prepareSettings(in supportDirectory: URL) throws {
        guard let defaultsURL = Bundle.main.url(forResource: "default-settings", withExtension: "json"),
              let defaultsData = try? Data(contentsOf: defaultsURL),
              let defaults = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
              let defaultTorrentSettings = defaults["BitTorr"] as? [String: Any] else {
            throw TorrServerProcessError.defaultSettingsMissing
        }

        let settingsURL = supportDirectory.appendingPathComponent("settings.json")
        var root: [String: Any]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TorrServerProcessError.invalidSettings
            }
            root = existing
        } else {
            root = defaults
        }

        var torrentSettings = root["BitTorr"] as? [String: Any] ?? defaultTorrentSettings
        torrentSettings["EnableBonjour"] = false
        torrentSettings["EnableDLNA"] = false
        torrentSettings["EnableLPD"] = false
        torrentSettings["DisableUPNP"] = true
        root["BitTorr"] = torrentSettings

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func isPortAvailable(_ port: UInt16) -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

private enum TorrServerProcessError: LocalizedError {
    case unsupportedArchitecture
    case binaryMissing
    case noAvailablePort
    case launchFailed
    case defaultSettingsMissing
    case invalidSettings

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            "Встроенный TorrServer доступен только на Apple Silicon."
        case .binaryMissing:
            "В этой сборке не найден TorrServer. Пересоберите приложение."
        case .noAvailablePort:
            "Не удалось найти свободный локальный порт для TorrServer."
        case .launchFailed:
            "Не удалось запустить встроенный TorrServer."
        case .defaultSettingsMissing:
            "В приложении не найдены настройки встроенного TorrServer. Пересоберите приложение."
        case .invalidSettings:
            "Не удалось прочитать файл настроек TorrServer. Сохранённые настройки не изменены."
        }
    }
}
