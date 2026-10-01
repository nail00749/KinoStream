import Foundation

struct TorrServerTorrentDTO: Decodable {
    let hash: String
    let title: String?
    let name: String?
    let poster: String?
    let statString: String?
    let torrentSize: Int64?
    let loadedSize: Int64?
    let downloadSpeed: Double?
    let activePeers: Int?
    let fileStats: [TorrServerFileDTO]?

    var domainModel: Torrent {
        Torrent(
            hash: hash,
            title: title,
            name: name,
            poster: poster,
            statString: statString,
            torrentSize: torrentSize,
            loadedSize: loadedSize,
            downloadSpeed: downloadSpeed,
            activePeers: activePeers,
            fileStats: (fileStats ?? []).map(\.domainModel)
        )
    }
}

struct TorrServerFileDTO: Decodable {
    let id: Int
    let path: String
    let length: Int64

    var domainModel: TorrentFile {
        TorrentFile(id: id, path: path, length: length)
    }
}

struct AddTorrentRequestDTO: Encodable {
    let action = "add"
    let link: String
    let saveToDB = true

    enum CodingKeys: String, CodingKey {
        case action, link
        case saveToDB = "save_to_db"
    }
}

struct ListTorrentRequestDTO: Encodable {
    let action = "list"
}

struct RemoveTorrentRequestDTO: Encodable {
    let action: String
    let hash: String
}
