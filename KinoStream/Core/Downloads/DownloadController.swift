import AppKit
import Foundation
import Combine

struct VideoDownload: Identifiable {
    enum State { case queued, downloading, completed, cancelled, failed(String) }
    let id: UUID
    let name: String
    let destination: URL
    let expectedBytes: Int64
    let sourcePath: String
    var bytesPerSecond: Double = 0
    var lastProgressAt: Date = .now
    var receivedBytes: Int64 = 0
    var state: State = .downloading
    var progress: Double { expectedBytes > 0 ? min(1, Double(receivedBytes) / Double(expectedBytes)) : 0 }
}

@MainActor
final class DownloadController: ObservableObject {
    @Published private(set) var items: [VideoDownload] = []
    private var sessions: [UUID: (URLSession, URLSessionDownloadTask)] = [:]
    private struct PendingDownload {
        let id: UUID
        let request: URLRequest
        let file: TorrentFile
        let destination: URL
    }
    private var pending: [PendingDownload] = []
    private var generation = UUID()
    var activeCount: Int { sessions.count + pending.count }

    var displayedItems: [VideoDownload] {
        items.enumerated().sorted {
            let left = Self.displayPriority($0.element.state)
            let right = Self.displayPriority($1.element.state)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    private static func displayPriority(_ state: VideoDownload.State) -> Int {
        switch state {
        case .downloading: 0
        case .queued: 1
        case .failed: 2
        case .completed, .cancelled: 3
        }
    }

    func item(torrentHash: String, fileID: Int) -> VideoDownload? {
        items.first { $0.sourcePath.hasSuffix("/play/\(torrentHash)/\(fileID)") }
    }

    func chooseDestination(request: URLRequest, file: TorrentFile) {
        let panel = NSSavePanel()
        panel.title = "Скачать видео на устройство"
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let generation = self.generation
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.start(request: request, file: file, destination: url)
            }
        }
    }

    func chooseSeasonFolder(files: [(TorrentFile, URLRequest)], folderName: String,
                            onError: @escaping @MainActor (String) -> Void) {
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите папку для скачивания сезона"
        panel.prompt = "Скачать сезон"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        let generation = self.generation
        panel.begin { [weak self] response in
            guard response == .OK, let root = panel.url else { return }
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                do {
                    let name = Self.safeName(folderName)
                    var folder = root.appendingPathComponent(name, isDirectory: true)
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: folder.path) {
                        folder = root.appendingPathComponent("\(name) (\(suffix))", isDirectory: true)
                        suffix += 1
                    }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    var names = Set<String>()
                    for (file, request) in files {
                        let original = Self.safeName(file.name)
                        var name = original
                        var number = 2
                        while !names.insert(name.lowercased()).inserted {
                            let stem = (original as NSString).deletingPathExtension
                            let ext = (original as NSString).pathExtension
                            name = "\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
                            number += 1
                        }
                        self.start(request: request, file: file, destination: folder.appendingPathComponent(name))
                    }
                } catch { onError("Не удалось создать папку сезона. Проверьте доступ к выбранной папке.") }
            }
        }
    }

    private static func safeName(_ value: String) -> String {
        let name = value.components(separatedBy: CharacterSet(charactersIn: "/:\0")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return "Видео" }
        let ext = (name as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 12 ? ".\(ext)" : ""
        var stem = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        while (stem + suffix).utf8.count > 200 { stem.removeLast() }
        return stem + suffix
    }

    private func start(request: URLRequest, file: TorrentFile, destination: URL) {
        guard !items.contains(where: { item in item.destination == destination &&
            (sessions[item.id] != nil || pending.contains(where: { $0.id == item.id })) }) else { return }
        let id = UUID()
        items.insert(VideoDownload(id: id, name: file.name, destination: destination,
                                   expectedBytes: file.length, sourcePath: request.url?.path ?? "", state: .queued), at: 0)
        pending.append(PendingDownload(id: id, request: request, file: file, destination: destination))
        startNext()
    }

    private func startNext() {
        while sessions.count < 2, !pending.isEmpty {
            let job = pending.removeFirst()
            begin(job)
        }
    }

    private func begin(_ job: PendingDownload) {
        let id = job.id
        let file = job.file
        let destination = job.destination
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = .downloading }
        let delegate = VideoDownloadDelegate(destination: destination, expectedBytes: file.length,
            onProgress: { [weak self] received, speed in
                Task { @MainActor in
                    guard let self, self.sessions[id] != nil, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                    self.items[index].receivedBytes = received
                    self.items[index].bytesPerSecond = speed
                    self.items[index].lastProgressAt = .now
                }
            }, onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.sessions.removeValue(forKey: id) != nil,
                          let index = self.items.firstIndex(where: { $0.id == id }) else { return }
                    switch result {
                    case .success: self.items[index].state = .completed; self.items[index].receivedBytes = file.length
                    case .failure(let message): self.items[index].state = .failed(message)
                    }
                    self.startNext()
                }
            })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: job.request)
        sessions[id] = (session, task)
        task.resume()
    }

    func cancel(_ id: UUID) {
        let queued = pending.contains(where: { $0.id == id })
        pending.removeAll(where: { $0.id == id })
        let running = sessions.removeValue(forKey: id)
        guard queued || running != nil else { return }
        running?.1.cancel()
        running?.0.invalidateAndCancel()
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = .cancelled }
        startNext()
    }

    func cancelAll() {
        generation = UUID()
        let ids = Array(sessions.keys) + pending.map(\.id)
        pending.removeAll()
        for id in ids {
            if let running = sessions.removeValue(forKey: id) { running.1.cancel(); running.0.invalidateAndCancel() }
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = .cancelled }
        }
    }
    func resetSession() { cancelAll(); items.removeAll() }
    func reveal(_ item: VideoDownload) { NSWorkspace.shared.activateFileViewerSelecting([item.destination]) }
}

private enum DownloadResult: Sendable { case success, failure(String) }

// One serial delegate queue per download; URLs and credentials are never logged.
private final class VideoDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let expectedBytes: Int64
    let onProgress: @Sendable (Int64, Double) -> Void
    let onFinish: @Sendable (DownloadResult) -> Void
    private var finished = false
    private var lastProgress = Date()
    private var lastBytes: Int64 = 0

    init(destination: URL, expectedBytes: Int64, onProgress: @escaping @Sendable (Int64, Double) -> Void,
         onFinish: @escaping @Sendable (DownloadResult) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let interval = now.timeIntervalSince(lastProgress)
        guard interval >= 0.25 else { return }
        let speed = Double(max(0, totalBytesWritten - lastBytes)) / interval
        lastProgress = now
        lastBytes = totalBytesWritten
        onProgress(totalBytesWritten, speed)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        finished = true
        guard downloadTask.state != .canceling else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            onFinish(.failure("TorrServer не отдал файл. Проверьте соединение и авторизацию.")); return
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".kinostream-\(UUID().uuidString).partial")
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, expectedBytes <= 0 || size == expectedBytes else {
                onFinish(.failure("Видео скачалось не полностью. Повторите загрузку.")); return
            }
            try FileManager.default.moveItem(at: location, to: staging)
            guard downloadTask.state != .canceling else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            onFinish(.success)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            onFinish(.failure("Не удалось сохранить видео. Проверьте свободное место и доступ к выбранной папке."))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !finished {
            onFinish(.failure("Загрузка прервана. Проверьте TorrServer, интернет и наличие пиров, затем повторите скачивание."))
        }
        session.finishTasksAndInvalidate()
    }
}
