import Foundation
import WatchConnectivity
import Combine

// MARK: - Лёгкая модель трека для передачи на часы
struct WatchTrackInfo: Codable {
    let id: String      // используем имя файла как стабильный идентификатор
    let title: String
    let artist: String
}

// MARK: - Связь iPhone <-> Apple Watch
// Добавь этот файл в таргет "music player" (основное приложение).
class PhoneConnectivityManager: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = PhoneConnectivityManager()

    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        activateSession()
        // Откладываем обращение к MusicManager.shared на следующий "тик" —
        // иначе при первом запуске получится циклическая инициализация
        // двух синглтонов друг через друга и приложение упадёт.
        DispatchQueue.main.async { [weak self] in
            self?.observeMusicManager()
        }
    }

    private func activateSession() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Отправка состояния плеера на часы

    private func observeMusicManager() {
        let manager = MusicManager.shared
        Publishers.CombineLatest4(
            manager.$tracks,
            manager.$currentTrackIndex,
            manager.$isPlaying,
            manager.$currentTitle
        )
        .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.pushStateToWatch()
        }
        .store(in: &cancellables)
    }

    func pushStateToWatch() {
        guard WCSession.default.activationState == .activated else { return }
        let manager = MusicManager.shared

        let trackInfos = manager.tracks.map {
            WatchTrackInfo(id: $0.url.lastPathComponent, title: $0.title, artist: $0.artist)
        }
        guard let tracksData = try? JSONEncoder().encode(trackInfos) else { return }

        let context: [String: Any] = [
            "tracks": tracksData,
            "isPlaying": manager.isPlaying,
            "currentTitle": manager.currentTitle,
            "currentArtist": manager.currentArtist,
            "currentId": manager.currentTrack?.url.lastPathComponent ?? ""
        ]

        try? WCSession.default.updateApplicationContext(context)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.pushStateToWatch() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    // Команды, пришедшие пока приложение на телефоне активно
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleCommand(message)
    }

    // Команды, пришедшие "в очереди" (если телефон был недоступен)
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handleCommand(userInfo)
    }

    // MARK: - Обработка команд с часов

    private func handleCommand(_ command: [String: Any]) {
        guard let action = command["action"] as? String else { return }
        DispatchQueue.main.async {
            let manager = MusicManager.shared
            switch action {
            case "playPause":
                manager.playPause()
            case "next":
                manager.nextTrack()
            case "previous":
                manager.prevTrack()
            case "playTrack":
                if let id = command["id"] as? String,
                   let index = manager.currentList.firstIndex(where: { $0.url.lastPathComponent == id }) {
                    manager.playTrack(at: index)
                }
            default:
                break
            }
            self.pushStateToWatch()
        }
    }
}
