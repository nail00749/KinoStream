import Foundation

struct TorrentSearchFilters: Equatable {
    var quality = "Все"
    var maximumSizeGB = 0
    var minimumSeeders = 0
    var language = "Все"
    var dubbing = "Все"
    var sort: Sort = .relevance

    enum Sort: String, CaseIterable {
        case relevance = "Исходный порядок"
        case seeders = "По сидам"
        case size = "По размеру"
    }

    static let qualities = ["Все", "2160p", "1080p", "720p", "SD"]
    static let languages = ["Все", "Русский", "Английский"]
    static let dubbings = ["Все", "Дубляж", "Многоголосая", "Одноголосая", "Субтитры"]

    func apply(to results: [TorrentSearchResult]) -> [TorrentSearchResult] {
        let filtered = results.filter { result in
            (quality == "Все" || Self.quality(of: result.title) == quality)
                && (maximumSizeGB == 0 || result.sizeBytes.map { $0 <= Int64(maximumSizeGB) * 1_073_741_824 } == true)
                && (minimumSeeders == 0 || (result.seeders ?? -1) >= minimumSeeders)
                && (language == "Все" || Self.languages(in: result.title).contains(language))
                && (dubbing == "Все" || Self.dubbings(in: result.title).contains(dubbing))
        }
        switch sort {
        case .relevance: return filtered
        case .seeders: return filtered.enumerated().sorted {
            let lhs = $0.element.seeders ?? -1, rhs = $1.element.seeders ?? -1
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.map(\.element)
        case .size: return filtered.enumerated().sorted {
            let lhs = $0.element.sizeBytes ?? Int64.max, rhs = $1.element.sizeBytes ?? Int64.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
        }
    }

    static func quality(of title: String) -> String? {
        if matches(#"\b(?:2160p?|4k|uhd)\b"#, title) { return "2160p" }
        if matches(#"\b1080[pi]?\b"#, title) { return "1080p" }
        if matches(#"\b720p?\b"#, title) { return "720p" }
        if matches(#"\b(?:480p?|576[pi]?|sd|dvdrip)\b"#, title) { return "SD" }
        return nil
    }

    static func languages(in title: String) -> Set<String> {
        var result = Set<String>()
        if matches(#"\b(?:rus|ru|russian|рус|русский)\b"#, title) { result.insert("Русский") }
        if matches(#"\b(?:eng|en|english|англ|английский)\b"#, title) { result.insert("Английский") }
        return result
    }

    static func dubbings(in title: String) -> Set<String> {
        var result = Set<String>()
        if matches(#"\b(?:d|dub|dubbed|дубляж|дублированный)\b"#, title) { result.insert("Дубляж") }
        if matches(#"\b(?:mvo|многоголос\w*)\b"#, title) { result.insert("Многоголосая") }
        if matches(#"\b(?:avo|vo|одноголос\w*)\b"#, title) { result.insert("Одноголосая") }
        if matches(#"\b(?:sub|subs|субтитры)\b"#, title) { result.insert("Субтитры") }
        return result
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
