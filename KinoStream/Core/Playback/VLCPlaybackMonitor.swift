import AppKit
import Darwin
import Foundation

@MainActor
final class VLCPlaybackMonitor {
    private struct Status {
        let position: Double
        let duration: Double
        let state: String
    }

    private var generation = UUID()
    private var pollingTask: Task<Void, Never>?
    private var session: URLSession?
    private var endpoint: URL?
    private var authorization: String?
    private var onProgress: (@MainActor (Double, Double) -> Void)?
    private var onPlaybackState: (@MainActor (String) -> Void)?
    private var onEnded: (@MainActor () -> Void)?
    private var onUnavailable: (@MainActor () -> Void)?
    private var latestStatus: Status?
    private var lastReportedStatus: Status?

    func start(
        streamURL: URL,
        applicationURL: URL,
        resumeAt: Double,
        onProgress: @escaping @MainActor (Double, Double) -> Void,
        onUnavailable: @escaping @MainActor () -> Void,
        onPlaybackState: @escaping @MainActor (String) -> Void,
        onEnded: @escaping @MainActor () -> Void
    ) async throws {
        stop()
        let requestGeneration = generation

        let port = try Self.availableLoopbackPort()
        let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard let endpoint = URL(string: "http://127.0.0.1:\(port)/requests/status.json") else {
            throw VLCPlaybackError.invalidEndpoint
        }

        var arguments = [
            "--extraintf=http",
            "--http-host=127.0.0.1",
            "--http-port=\(port)",
            "--http-password=\(password)"
        ]
        if resumeAt.isFinite, resumeAt > 0 {
            arguments.append("--start-time=\(Int(resumeAt))")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = arguments
        _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)

        guard generation == requestGeneration, !Task.isCancelled else { throw CancellationError() }
        self.endpoint = endpoint
        authorization = "Basic " + Data(":\(password)".utf8).base64EncodedString()
        self.onProgress = onProgress
        self.onUnavailable = onUnavailable
        self.onEnded = onEnded
        self.onPlaybackState = onPlaybackState

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 3
        session = URLSession(configuration: sessionConfiguration)
        pollingTask = Task { [weak self] in
            await self?.startPlaybackAndPoll(streamURL: streamURL)
        }
    }

    func stop() {
        generation = UUID()
        pollingTask?.cancel()
        pollingTask = nil
        if let latestStatus {
            onProgress?(latestStatus.position, latestStatus.duration)
        }
        session?.invalidateAndCancel()
        session = nil
        endpoint = nil
        authorization = nil
        onProgress = nil
        onUnavailable = nil
        onEnded = nil
        onPlaybackState = nil
        latestStatus = nil
        lastReportedStatus = nil
    }

    private func pollStatus() async {
        var failedAttempts = 0

        while !Task.isCancelled {
            if let status = await loadStatus() {
                failedAttempts = 0
                let previous = latestStatus
                latestStatus = status
                onPlaybackState?(status.state)
                if shouldReport(status) {
                    onProgress?(status.position, status.duration)
                    lastReportedStatus = status
                }
                if status.state == "stopped" {
                    if let previous, previous.state == "playing",
                       previous.duration > 0, previous.position >= previous.duration - 2 { onEnded?() }
                    return
                }
            } else {
                failedAttempts += 1
                if failedAttempts >= 20 {
                    if latestStatus == nil {
                        onUnavailable?()
                    }
                    return
                }
            }

            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func startPlaybackAndPoll(streamURL: URL) async {
        for _ in 0..<20 {
            if Task.isCancelled { return }
            if await sendPlaybackCommand(streamURL: streamURL) {
                await pollStatus()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if !Task.isCancelled {
            onUnavailable?()
        }
    }

    private func sendPlaybackCommand(streamURL: URL) async -> Bool {
        guard let endpoint, let authorization, let session,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return false }
        components.queryItems = [
            URLQueryItem(name: "command", value: "in_play"),
            URLQueryItem(name: "input", value: streamURL.absoluteString)
        ]
        guard let commandURL = components.url else { return false }
        var request = URLRequest(url: commandURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func shouldReport(_ status: Status) -> Bool {
        guard let previous = lastReportedStatus else { return true }
        return abs(status.position - previous.position) >= 3 || status.state != previous.state
    }

    private func loadStatus() async -> Status? {
        guard let endpoint, let authorization, let session else { return nil }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let position = (payload["time"] as? NSNumber)?.doubleValue,
                  let duration = (payload["length"] as? NSNumber)?.doubleValue,
                  position.isFinite, position >= 0,
                  duration.isFinite, duration >= 0 else {
                return nil
            }
            return Status(position: position, duration: duration, state: payload["state"] as? String ?? "")
        } catch {
            return nil
        }
    }

    private static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw VLCPlaybackError.portUnavailable }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw VLCPlaybackError.portUnavailable }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else { throw VLCPlaybackError.portUnavailable }
        return UInt16(bigEndian: boundAddress.sin_port)
    }
}

private enum VLCPlaybackError: LocalizedError {
    case invalidEndpoint
    case portUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Не удалось настроить локальный интерфейс VLC."
        case .portUnavailable: "Не удалось выбрать порт для мониторинга VLC."
        }
    }
}
