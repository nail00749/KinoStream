import Foundation

enum CatalogCollection: String, CaseIterable, Identifiable {
    case popular = "Популярное"
    case new = "Новинки"
    case rated = "Высокий рейтинг"
    var id: String { rawValue }
    var catalogID: String {
        switch self { case .popular: "top"; case .new: "year"; case .rated: "imdbRating" }
    }
}

enum CatalogGenre: String, CaseIterable, Identifiable {
    case all = "Все жанры"
    case action = "Боевик"
    case adventure = "Приключения"
    case animation = "Анимация"
    case comedy = "Комедия"
    case crime = "Криминал"
    case documentary = "Документальное"
    case drama = "Драма"
    case family = "Семейное"
    case fantasy = "Фэнтези"
    case horror = "Ужасы"
    case mystery = "Детектив"
    case romance = "Мелодрама"
    case scienceFiction = "Фантастика"
    case thriller = "Триллер"
    var id: String { rawValue }
    var providerValue: String? {
        switch self {
        case .all: nil
        case .action: "Action"
        case .adventure: "Adventure"
        case .animation: "Animation"
        case .comedy: "Comedy"
        case .crime: "Crime"
        case .documentary: "Documentary"
        case .drama: "Drama"
        case .family: "Family"
        case .fantasy: "Fantasy"
        case .horror: "Horror"
        case .mystery: "Mystery"
        case .romance: "Romance"
        case .scienceFiction: "Sci-Fi"
        case .thriller: "Thriller"
        }
    }
}

struct CatalogDiscoverySelection: Equatable {
    var collection: CatalogCollection = .popular
    var genre: CatalogGenre = .all
    var kind: MediaKind? = nil
    var identity: String { "\(collection.id)|\(genre.id)|\(kind?.rawValue ?? "all")" }
}
