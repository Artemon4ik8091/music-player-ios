import Foundation
import WatchConnectivity
import Combine

// MARK: - Та же лёгкая модель трека, что и на телефоне
struct WatchTrackInfo: Codable, Identifiable {
    let id: String
    let title: String
    let artist: String
}

// MARK: - Связь Apple Watch <-> iPhone
// Добавь этот файл в таргет часов (например "music playerWatch").
class WatchConnectivityManager: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var tracks: [WatchTrackInfo] = []
    @Published var isPlaying: Bool = false
    @Published var currentTitle: String = ""
    @Published var currentArtist: String = ""
    @Published var currentId: String = ""

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.apply(applicationContext)
        }
    }

    private func apply(_ context: [String: Any]) {
        if let data = context["tracks"] as? Data,
           let decoded = try? JSONDecoder().decode([WatchTrackInfo].self, from: data) {
            self.tracks = decoded
        }
        self.isPlaying = context["isPlaying"] as? Bool ?? false
        self.currentTitle = context["currentTitle"] as? String ?? ""
        self.currentArtist = context["currentArtist"] as? String ?? ""
        self.currentId = context["currentId"] as? String ?? ""
    }

    // MARK: - Отправка команд на телефон

    private func send(action: String, extra: [String: Any] = [:]) {
        guard WCSession.isSupported() else { return }
        var payload = extra
        payload["action"] = action

        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    func playPause() { send(action: "playPause") }
    func next() { send(action: "next") }
    func previous() { send(action: "previous") }
    func playTrack(id: String) { send(action: "playTrack", extra: ["id": id]) }
}
