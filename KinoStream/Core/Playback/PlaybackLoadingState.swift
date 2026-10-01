import Foundation

enum PlaybackLoadingState: Equatable {
    case connecting
    case adding
    case receivingFiles
    case waitingForPeers
    case openingPlayer
    case buffering
    case failed(String)

    var title: String {
        switch self {
        case .connecting: "Подключаемся к серверу"
        case .adding: "Добавляем раздачу"
        case .receivingFiles: "Получаем список файлов"
        case .waitingForPeers: "Ждём подключения пиров"
        case .openingPlayer: "Открываем видео"
        case .buffering: "Буферизуем видео"
        case .failed: "Не удалось запустить видео"
        }
    }

    var message: String {
        switch self {
        case .connecting: "Проверяем доступность TorrServer."
        case .adding: "Передаём выбранную раздачу серверу."
        case .receivingFiles: "Сервер получает информацию о видеофайлах."
        case .waitingForPeers: "Пока нет активных пиров. Можно подождать или выбрать другую раздачу."
        case .openingPlayer: "Подготавливаем выбранный плеер."
        case .buffering: "Загружаем данные для воспроизведения."
        case .failed(let message): message
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
