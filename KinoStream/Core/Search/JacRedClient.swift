import Foundation

struct JacRedClient {
    let endpoint: String

    func checkConnection() async throws {
        _ = try await search(.text("KinoStream"))
    }

    func search(_ target: TorrentSearchTarget) async throws -> [TorrentSearchResult] {
        let data = try await request(target)
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) }
        catch { throw JacRedError.invalidResponse }

        let rows: [[String: Any]]
        if let object = json as? [String: Any],
           let results = object["Results"] as? [[String: Any]] ?? object["results"] as? [[String: Any]] {
            rows = results
        } else if let array = json as? [[String: Any]] {
            rows = array
        } else {
            throw JacRedError.invalidResponse
        }

        var seen = Set<String>()
        return rows.compactMap { row in
            let values = Dictionary(row.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            let title = values.string("title", "name")?.nilIfBlank
            let magnet = values.string("magneturi", "magneturl", "magnet")?.nilIfBlank
            let downloadURL = values.string("download", "downloadurl", "link", "torrenturl")?.nilIfBlank
            let link = magnet ?? downloadURL
            guard let title, let link else { return nil }
            let identity = link.lowercased()
            guard seen.insert(identity).inserted else { return nil }
            return TorrentSearchResult(
                title: title,
                link: link,
                size: values.string("sizename") ?? values.number("size").flatMap(Self.byteCountLabel) ?? values.string("size"),
                seeders: values.integer("seeders", "sid"),
                source: values.string("tracker", "trackername")?.nilIfBlank ?? "JacRed",
                leechers: values.integer("peers", "pir", "leechers"),
                sizeBytes: values.number("size")
            )
        }
    }

    private func request(_ target: TorrentSearchTarget) async throws -> Data {
        let cleanEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: cleanEndpoint),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else { throw JacRedError.invalidEndpoint }

        let apiPath = "/api/v2.0/indexers/all/results"
        if !components.path.contains("/api/v2.0/indexers/") {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + apiPath
            if !components.path.hasPrefix("/") { components.path = "/" + components.path }
        }

        var items = components.queryItems ?? []
        items.removeAll { ["query", "q", "title", "title_original", "year", "is_serial"].contains($0.name.lowercased()) }
        items.append(URLQueryItem(name: "query", value: target.query))
        if let title = target.title?.nilIfBlank { items.append(URLQueryItem(name: "title", value: title)) }
        if let originalTitle = target.originalTitle?.nilIfBlank { items.append(URLQueryItem(name: "title_original", value: originalTitle)) }
        if let year = target.year, year > 0 { items.append(URLQueryItem(name: "year", value: String(year))) }
        if let kind = target.kind { items.append(URLQueryItem(name: "is_serial", value: kind == .series ? "1" : "0")) }
        components.queryItems = items
        guard let url = components.url else { throw JacRedError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw JacRedError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw JacRedError.http(response.statusCode) }
            return data
        } catch let error as JacRedError {
            throw error
        } catch {
            throw JacRedError.unavailable
        }
    }

    private static func byteCountLabel(_ value: Int64) -> String? {
        guard value > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ keys: String...) -> String? {
        for key in keys {
            guard let value = self[key] else { continue }
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
        }
        return nil
    }

    func number(_ keys: String...) -> Int64? {
        for key in keys {
            guard let value = self[key] else { continue }
            if let number = value as? NSNumber { return number.int64Value }
            if let string = value as? String, let number = Int64(string) { return number }
        }
        return nil
    }

    func integer(_ keys: String...) -> Int? {
        for key in keys {
            guard let value = self[key] else { continue }
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String, let number = Int(string) { return number }
        }
        return nil
    }
}

enum JacRedError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case unavailable
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Проверьте адрес JacRed в настройках."
        case .invalidResponse: "JacRed вернул неожиданный ответ. Проверьте адрес парсера."
        case .unavailable: "Не удалось подключиться к JacRed. Проверьте интернет-соединение и адрес сервиса."
        case .http(let status): "JacRed временно недоступен (HTTP \(status))."
        }
    }
}
