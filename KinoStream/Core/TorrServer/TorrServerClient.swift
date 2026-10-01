import AVKit
import Foundation

struct TorrServerClient {
    let baseURL: URL
    let username: String
    let password: String

    init(url: String, username: String, password: String) throws {
        let normalized = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: normalized), let scheme = baseURL.scheme, ["http", "https"].contains(scheme), baseURL.host != nil else {
            throw TorrServerError.invalidURL
        }
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    func ping(timeout: TimeInterval = 30) async throws {
        var request = request(path: "echo")
        request.timeoutInterval = timeout
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func listTorrents() async throws -> [Torrent] {
        var request = request(path: "torrents")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ListTorrentRequestDTO())
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([TorrServerTorrentDTO].self, from: data).map(\.domainModel)
    }

    func addTorrent(link: String) async throws {
        var request = request(path: "torrents")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AddTorrentRequestDTO(link: link))
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func removeTorrent(hash: String) async throws {
        var request = request(path: "torrents")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RemoveTorrentRequestDTO(action: "rem", hash: hash))
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func playbackURL(hash: String, fileID: Int) -> URL? {
        baseURL.appendingPathComponent("play").appendingPathComponent(hash).appendingPathComponent(String(fileID))
    }

    func player(for url: URL) -> AVPlayer {
        var options: [String: Any] = [:]
        if let authorization = authorizationHeader {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": authorization]
        }
        return AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: options)))
    }

    private var authorizationHeader: String? {
        guard !username.isEmpty else { return nil }
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(credentials)"
    }

    private func request(path: String) -> URLRequest {
        request(url: baseURL.appendingPathComponent(path))
    }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw TorrServerError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw TorrServerError.http(response.statusCode) }
    }
}

enum TorrServerError: LocalizedError {
    case invalidURL
    case invalidResponse
    case http(Int)
    case torrentNotReady

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Проверьте адрес TorrServer. Пример: http://127.0.0.1:8090"
        case .invalidResponse: "TorrServer вернул неожиданный ответ."
        case .http(401): "Не удалось войти. Проверьте логин и пароль TorrServer."
        case .http(404): "Сервер не нашёл этот файл. Возможно, раздача ещё загружается."
        case .torrentNotReady: "TorrServer пока не подготовил видеофайл. Попробуйте ещё раз через несколько секунд."
        case .http(let status): "Ошибка TorrServer: HTTP \(status)."
        }
    }
}
