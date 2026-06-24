import SwiftUI
import AVFoundation
import MediaPlayer
import Combine
import UniformTypeIdentifiers
import AVKit

// MARK: - Модель трека
struct Track: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let title: String
    let artist: String
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

// MARK: - Модель строки текста
struct LyricLine: Identifiable, Codable {
    var id = UUID()
    var time: TimeInterval   // < 0 = без временной метки
    var text: String
}

// MARK: - Модель ответа от LRCLIB
struct LRCLibSearchResult: Codable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let syncedLyrics: String?
    let plainLyrics: String?
}

// MARK: - Перечисления
enum RepeatMode: Int, CaseIterable {
    case none = 0
    case all = 1
    case one = 2
    
    var iconName: String {
        switch self {
        case .none: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

enum AppTheme: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var title: String {
        switch self {
        case .system: return "Системная"
        case .light: return "Светлая"
        case .dark: return "Темная"
        }
    }
}

// MARK: - Гибридный плеер с эквалайзером и автоматическим фолбеком
class AVAudioPlayerWithEQ: NSObject, AVAudioPlayerDelegate {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eqNode: AVAudioUnitEQ?
    private var audioFile: AVAudioFile?
    
    // Резервный плеер на случай сбоев или неподдерживаемых форматов
    private var fallbackPlayer: AVAudioPlayer?
    private var useFallback: Bool = false
    
    var url: URL?
    var onFinishPlaying: (() -> Void)?
    
    private var seekTime: TimeInterval = 0
    private var totalDuration: TimeInterval = 0
    private var sampleRate: Double = 44100
    private var totalFrames: AVAudioFramePosition = 0
    private var isSeeking = false
    
    var volume: Float = 1.0 {
        didSet {
            if useFallback {
                fallbackPlayer?.volume = volume
            } else {
                playerNode?.volume = volume
            }
        }
    }
    
    var isPlaying: Bool {
        if useFallback {
            return fallbackPlayer?.isPlaying ?? false
        } else {
            return playerNode?.isPlaying ?? false
        }
    }
    
    var currentTime: TimeInterval {
        get {
            if useFallback {
                return fallbackPlayer?.currentTime ?? 0
            } else {
                guard let playerNode = playerNode else { return seekTime }
                if let nodeTime = playerNode.lastRenderTime,
                   let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                    let currentSecs = Double(playerTime.sampleTime) / playerTime.sampleRate
                    return min(seekTime + currentSecs, totalDuration)
                }
                return seekTime
            }
        }
        set {
            seek(to: newValue)
        }
    }
    
    var duration: TimeInterval {
        if useFallback {
            return fallbackPlayer?.duration ?? 0
        } else {
            return totalDuration
        }
    }
    
    init(contentsOf url: URL) throws {
        self.url = url
        super.init()
        
        do {
            self.engine = AVAudioEngine()
            self.playerNode = AVAudioPlayerNode()
            self.eqNode = AVAudioUnitEQ(numberOfBands: 10)
            
            let file = try AVAudioFile(forReading: url)
            self.audioFile = file
            self.totalDuration = Double(file.length) / file.fileFormat.sampleRate
            self.sampleRate = file.fileFormat.sampleRate
            self.totalFrames = file.length
            
            guard let engine = engine, let playerNode = playerNode, let eqNode = eqNode else {
                throw NSError(domain: "AVAudioPlayerWithEQ", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create nodes"])
            }
            
            engine.attach(playerNode)
            engine.attach(eqNode)
            
            // Настройка частот для 10-полосного параметрического эквалайзера (ISO-стандарт)
            let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
            let isEqEnabled = UserDefaults.standard.bool(forKey: "eq_enabled")
            
            for i in 0..<10 {
                let band = eqNode.bands[i]
                band.frequency = frequencies[i]
                band.filterType = .parametric
                band.bypass = !isEqEnabled
                let savedGain = Float(UserDefaults.standard.double(forKey: "eq_band_\(i)"))
                band.gain = savedGain
            }
            
            let format = file.processingFormat
            engine.connect(playerNode, to: eqNode, format: format)
            engine.connect(eqNode, to: engine.mainMixerNode, format: format)
            
            try engine.start()
            self.useFallback = false
            scheduleFile()
        } catch {
            print("AVAudioEngine setup failed, falling back to AVAudioPlayer: \(error)")
            self.useFallback = true
            self.fallbackPlayer = try AVAudioPlayer(contentsOf: url)
            self.fallbackPlayer?.delegate = self
            self.fallbackPlayer?.prepareToPlay()
        }
    }
    
    func play() {
        if useFallback {
            fallbackPlayer?.play()
        } else {
            if let engine = engine, !engine.isRunning {
                try? engine.start()
            }
            playerNode?.play()
        }
    }
    
    func pause() {
        if useFallback {
            fallbackPlayer?.pause()
        } else {
            playerNode?.pause()
        }
    }
    
    func stop() {
        if useFallback {
            fallbackPlayer?.stop()
        } else {
            playerNode?.stop()
            engine?.stop()
        }
    }
    
    func seek(to time: TimeInterval) {
        if useFallback {
            fallbackPlayer?.currentTime = time
        } else {
            guard let playerNode = playerNode, let file = audioFile else { return }
            let wasPlaying = playerNode.isPlaying
            isSeeking = true
            playerNode.stop()
            
            seekTime = max(0, min(time, totalDuration))
            let startFrame = AVAudioFramePosition(seekTime * sampleRate)
            let framesToPlay = AVAudioFrameCount(totalFrames - startFrame)
            
            if framesToPlay > 100 {
                // ИСПРАВЛЕНО: переименован аргумент 'atTime' в 'at' в соответствии с требованиями нового SDK Swift/iOS
                playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: framesToPlay, at: nil) { [weak self] in
                    guard let self = self else { return }
                    if !self.isSeeking {
                        let current = self.currentTime
                        if current >= self.totalDuration - 0.5 {
                            DispatchQueue.main.async {
                                self.onFinishPlaying?()
                            }
                        }
                    }
                }
            }
            
            isSeeking = false
            if wasPlaying {
                playerNode.play()
            }
        }
    }
    
    private func scheduleFile() {
        guard let playerNode = playerNode, let file = audioFile else { return }
        playerNode.scheduleFile(file, at: nil) { [weak self] in
            guard let self = self else { return }
            if !self.isSeeking {
                let current = self.currentTime
                if current >= self.totalDuration - 0.5 {
                    DispatchQueue.main.async {
                        self.onFinishPlaying?()
                    }
                }
            }
        }
    }
    
    func updateEQSettings() {
        guard !useFallback, let eqNode = eqNode else { return }
        let isEqEnabled = UserDefaults.standard.bool(forKey: "eq_enabled")
        for i in 0..<10 {
            let band = eqNode.bands[i]
            band.bypass = !isEqEnabled
            let savedGain = Float(UserDefaults.standard.double(forKey: "eq_band_\(i)"))
            band.gain = savedGain
        }
    }
    
    // Делегат на случай фолбек-плеера
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            self.onFinishPlaying?()
        }
    }
}

// MARK: - Модель пресета эквалайзера
struct EQPreset: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let gains: [Double] // 10 значений для каждой полосы (-12dB ... +12dB)
}

// Предустановленные популярные пресеты
let eqPresets: [EQPreset] = [
    EQPreset(name: "Обычный (Flat)", gains: [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
    EQPreset(name: "Усиление баса", gains: [8.0, 6.5, 5.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]),
    EQPreset(name: "Усиление вокала", gains: [-3.0, -2.0, -1.0, 1.0, 3.0, 4.5, 4.0, 3.0, 1.5, -1.0]),
    EQPreset(name: "Акустика", gains: [3.5, 3.0, 1.5, 2.0, 1.0, 1.5, 2.5, 2.0, 1.5, 1.0]),
    EQPreset(name: "Классика", gains: [5.0, 4.0, 3.0, 2.0, -1.0, -1.0, 0.0, 2.0, 3.5, 4.5]),
    EQPreset(name: "Электроника", gains: [5.0, 4.0, 2.0, 0.0, -2.0, 2.5, 1.5, 2.0, 4.0, 5.5]),
    EQPreset(name: "Джаз", gains: [4.0, 3.0, 1.5, 2.0, -1.5, -1.5, 0.0, 1.5, 3.0, 4.0]),
    EQPreset(name: "Поп", gains: [-2.0, -1.5, 0.0, 2.5, 4.5, 4.0, 2.5, 0.0, -1.5, -2.0]),
    EQPreset(name: "Рок", gains: [5.0, 4.0, -2.0, -4.0, -1.5, 1.5, 3.5, 4.5, 5.0, 5.0])
]

// MARK: - Менеджер текстов песен
class LyricsManager: ObservableObject {
    static let shared = LyricsManager()
    private let storageKey = "trackLyrics_v1"
    @Published private var store: [String: [LyricLine]] = [:]

    init() { load() }

    func lyrics(for url: URL) -> [LyricLine] { store[url.lastPathComponent] ?? [] }
    func hasLyrics(for url: URL) -> Bool { !(store[url.lastPathComponent]?.isEmpty ?? true) }

    func setLyrics(_ lines: [LyricLine], for url: URL) {
        store[url.lastPathComponent] = lines
        save()
        objectWillChange.send()
    }

    func deleteLyrics(for url: URL) {
        store.removeValue(forKey: url.lastPathComponent)
        save()
    }

    // MARK: LRC Parser
    func parseLRC(_ content: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let timeRx = try! NSRegularExpression(pattern: #"\[(\d{2}):(\d{2})[\.:](\d{2,3})\]"#)
        let metaRx  = try! NSRegularExpression(pattern: #"^\[[a-zA-Z]+:.*\]$"#)

        for raw in content.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            let nsT = t as NSString
            let r = NSRange(t.startIndex..., in: t)
            if metaRx.firstMatch(in: t, range: r) != nil { continue }
            let matches = timeRx.matches(in: t, range: r)
            if matches.isEmpty {
                if !t.hasPrefix("[") { lines.append(LyricLine(time: -1, text: t)) }
                continue
            }
            let lastEnd = matches.last!.range.location + matches.last!.range.length
            let text = nsT.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for m in matches {
                let mm = Double(nsT.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(nsT.substring(with: m.range(at: 2))) ?? 0
                let ms = Double(nsT.substring(with: m.range(at: 3))) ?? 0
                let div = nsT.substring(with: m.range(at: 3)).count == 3 ? 1000.0 : 100.0
                lines.append(LyricLine(time: mm * 60 + ss + ms / div, text: text))
            }
        }
        return lines.sorted {
            let a = $0.time < 0 ? Double.infinity : $0.time
            let b = $1.time < 0 ? Double.infinity : $1.time
            return a < b
        }
    }

    // MARK: Export LRC text
    func lrcText(for lines: [LyricLine]) -> String {
        lines.map { l in
            guard l.time >= 0 else { return l.text }
            let m = Int(l.time) / 60
            let s = Int(l.time) % 60
            let ms = Int((l.time - Double(Int(l.time))) * 100)
            return String(format: "[%02d:%02d.%02d]%@", m, s, ms, l.text)
        }.joined(separator: "\n")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func load() {
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let dict = try? JSONDecoder().decode([String: [LyricLine]].self, from: d)
        else { return }
        store = dict
    }
    
    // MARK: Fetch Lyrics from Online Service (LRCLIB)
    func fetchLyricsFromLRCLib(title: String, artist: String) async -> String? {
        var cleanTitle = title
        for ext in [".mp3", ".m4a", ".wav", ".flac", ".aac"] {
            cleanTitle = cleanTitle.replacingOccurrences(of: ext, with: "", options: .caseInsensitive)
        }
        let cleanArtist = artist == "Локальный файл" ? "" : artist
        
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: cleanTitle),
            URLQueryItem(name: "artist_name", value: cleanArtist)
        ].filter { !($0.value?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("SwiftUIMusicPlayer/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let results = try JSONDecoder().decode([LRCLibSearchResult].self, from: data)
            
            if let bestMatch = results.first {
                return bestMatch.syncedLyrics ?? bestMatch.plainLyrics
            }
        } catch {
            print("LRCLib Network Error: \(error)")
        }
        return nil
    }
}

// MARK: - Менеджер времени воспроизведения
class PlaybackTime: ObservableObject {
    static let shared = PlaybackTime()
    @Published var currentTime: TimeInterval = 0
}

// MARK: - Менеджер музыки
class MusicManager: NSObject, ObservableObject {
    static let shared = MusicManager()
    
    @Published var audioPlayer: AVAudioPlayerWithEQ?
    
    @Published var tracks: [Track] = []
    private var shuffledTracks: [Track] = []
    
    @Published var isPlaying = false
    @Published var currentTrackIndex = 0
    
    @Published var volume: Float = 0.7 {
        didSet { applyVolumeChange() }
    }
    
    @Published var shuffleOn = false { didSet { updateShuffledList() } }
    @Published var repeatMode: RepeatMode = .none
    
    @Published var currentArtwork: UIImage?
    @Published var trackDuration: TimeInterval = 0
    
    var currentTime: TimeInterval {
        get { PlaybackTime.shared.currentTime }
        set { PlaybackTime.shared.currentTime = newValue }
    }
    
    @Published var currentTitle: String = ""
    @Published var currentArtist: String = ""
    
    private var timer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    private let systemVolumeView = MPVolumeView(frame: .zero)

    var currentList: [Track] {
        return shuffleOn ? shuffledTracks : tracks
    }

    var currentTrack: Track? {
        guard !currentList.isEmpty && currentTrackIndex < currentList.count else { return nil }
        return currentList[currentTrackIndex]
    }

    override init() {
        super.init()
        setupSession()
        setupRemoteCommands()
        loadTracksFromDisk()
        setupVolumeObservation()
        
        DispatchQueue.main.async {
            self.syncVolumeWithCurrentMode()
        }
    }
    
    func setupSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("Session error: \(error)") }
    }

    func loadTracksFromDisk() {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        do {
            let content = try fileManager.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)
            let audioFiles = content.filter { ["mp3", "m4a", "wav"].contains($0.pathExtension.lowercased()) }
            
            var loadedTracks: [Track] = []
            
            for url in audioFiles {
                let asset = AVAsset(url: url)
                var title = url.lastPathComponent
                var artist = "Локальный файл"
                
                for item in asset.metadata {
                    guard let key = item.commonKey else { continue }
                    if key == .commonKeyTitle { title = item.stringValue ?? title }
                    if key == .commonKeyArtist { artist = item.stringValue ?? artist }
                }
                loadedTracks.append(Track(url: url, title: title, artist: artist))
            }
            
            DispatchQueue.main.async {
                self.tracks = loadedTracks.sorted(by: { $0.title < $1.title })
                self.updateShuffledList()
            }
        } catch { print("Disk error: \(error)") }
    }
    
    func importTracks(from urls: [URL]) {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        var lrcURLs: [URL] = []
        var audioURLs: [URL] = []

        for url in urls {
            if url.pathExtension.lowercased() == "lrc" { lrcURLs.append(url) }
            else { audioURLs.append(url) }
        }

        for url in audioURLs {
            let accessing = url.startAccessingSecurityScopedResource()
            let dest = docs.appendingPathComponent(url.lastPathComponent)
            try? fileManager.copyItem(at: url, to: dest)
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        for lrcURL in lrcURLs {
            let accessing = lrcURL.startAccessingSecurityScopedResource()
            defer { if accessing { lrcURL.stopAccessingSecurityScopedResource() } }
            guard let content = try? String(contentsOf: lrcURL, encoding: .utf8) else { continue }
            let baseName = lrcURL.deletingPathExtension().lastPathComponent
            if let matchURL = findAudioURL(for: baseName, in: docs) {
                let lines = LyricsManager.shared.parseLRC(content)
                LyricsManager.shared.setLyrics(lines, for: matchURL)
            }
        }

        loadTracksFromDisk()
    }

    private func findAudioURL(for baseName: String, in directory: URL) -> URL? {
        for ext in ["mp3", "m4a", "wav", "flac", "aac"] {
            let url = directory.appendingPathComponent(baseName + "." + ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func deleteTrack(at offsets: IndexSet) {
        offsets.forEach { try? FileManager.default.removeItem(at: tracks[$0].url) }
        loadTracksFromDisk()
    }

    func deleteTrack(track: Track) {
        try? FileManager.default.removeItem(at: track.url)
        loadTracksFromDisk()
    }

    func deleteAllTracks() {
        audioPlayer?.stop()
        isPlaying = false
        
        for track in tracks {
            try? FileManager.default.removeItem(at: track.url)
        }
        
        DispatchQueue.main.async {
            self.tracks.removeAll()
            self.shuffledTracks.removeAll()
            self.currentArtwork = nil
            self.currentTitle = ""
            self.currentArtist = ""
            self.currentTime = 0
            self.trackDuration = 0
            self.updateNowPlaying()
        }
    }

    private func updateShuffledList() {
        shuffledTracks = tracks.shuffled()
        if let playingURL = audioPlayer?.url, let newIndex = shuffledTracks.firstIndex(where: { $0.url == playingURL }) {
            currentTrackIndex = newIndex
        }
    }

    func playTrack(at index: Int, in list: [Track]? = nil) {
        let activeList = list ?? currentList
        guard !activeList.isEmpty else { return }
        let safeIndex = (index < 0) ? 0 : (index >= activeList.count ? 0 : index)
        currentTrackIndex = safeIndex
        
        let track = activeList[currentTrackIndex]
        do {
            audioPlayer = try AVAudioPlayerWithEQ(contentsOf: track.url)
            
            audioPlayer?.onFinishPlaying = { [weak self] in
                guard let self = self else { return }
                if self.repeatMode == .one { self.playTrack(at: self.currentTrackIndex) }
                else if self.repeatMode == .all || self.currentTrackIndex < self.currentList.count - 1 { self.nextTrack() }
                else { self.isPlaying = false; self.updateNowPlaying() }
            }
            
            if !UserDefaults.standard.bool(forKey: "controlSystemVolume") {
                audioPlayer?.volume = volume
            } else {
                audioPlayer?.volume = 1.0
            }
            
            audioPlayer?.play()
            isPlaying = true
            trackDuration = audioPlayer?.duration ?? 0
            
            self.currentTitle = track.title
            self.currentArtist = track.artist
            fetchArtwork(for: track.url)
            
            startTimer()
            updateNowPlaying()
        } catch { print("Play error: \(error)") }
    }

    func playPause() {
        if audioPlayer?.isPlaying == true {
            audioPlayer?.pause()
            isPlaying = false
        } else {
            audioPlayer?.play()
            isPlaying = true
            startTimer()
        }
        updateNowPlaying()
    }

    func nextTrack() {
        if currentList.isEmpty { return }
        playTrack(at: (currentTrackIndex + 1) % currentList.count)
    }

    func prevTrack() {
        if currentList.isEmpty { return }
        if (audioPlayer?.currentTime ?? 0) > 3.0 { seek(to: 0); return }
        playTrack(at: (currentTrackIndex - 1 + currentList.count) % currentList.count)
    }

    func seek(to time: TimeInterval) {
        audioPlayer?.seek(to: time)
        currentTime = time
        updateNowPlaying()
    }

    func toggleShuffle() { shuffleOn.toggle() }
    func toggleRepeat() { repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % RepeatMode.allCases.count) ?? .none }

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            PlaybackTime.shared.currentTime = self?.audioPlayer?.currentTime ?? 0
        }
    }

    private func fetchArtwork(for url: URL) {
        let asset = AVAsset(url: url)
        self.currentArtwork = nil
        for item in asset.metadata where item.commonKey == .commonKeyArtwork {
            if let data = item.dataValue { self.currentArtwork = UIImage(data: data) }
        }
    }

    func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: currentArtist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: audioPlayer?.currentTime ?? 0,
            MPMediaItemPropertyPlaybackDuration: trackDuration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        
        if let image = currentArtwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in
                return image
            }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in self.playPause(); return .success }
        center.pauseCommand.addTarget { _ in self.playPause(); return .success }
        center.nextTrackCommand.addTarget { _ in self.nextTrack(); return .success }
        center.previousTrackCommand.addTarget { _ in self.prevTrack(); return .success }
    }
    
    private func applyVolumeChange() {
        let controlSystem = UserDefaults.standard.bool(forKey: "controlSystemVolume")
        if controlSystem {
            setSystemVolume(volume)
        } else {
            audioPlayer?.volume = volume
        }
    }
    
    func syncVolumeWithCurrentMode() {
        let controlSystem = UserDefaults.standard.bool(forKey: "controlSystemVolume")
        if controlSystem {
            self.volume = AVAudioSession.sharedInstance().outputVolume
            audioPlayer?.volume = 1.0
        } else {
            if let player = audioPlayer {
                self.volume = player.volume
            }
        }
    }
    
    private func setSystemVolume(_ value: Float) {
        let slider = systemVolumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
        DispatchQueue.main.async {
            slider?.value = value
        }
    }
    
    private func setupVolumeObservation() {
        NotificationCenter.default.publisher(for: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"))
            .sink { [weak self] notification in
                guard let self = self else { return }
                if UserDefaults.standard.bool(forKey: "controlSystemVolume") {
                    if let volumeValue = notification.userInfo?["AVSystemController_AudioVolumeNotificationParameter"] as? Float {
                        DispatchQueue.main.async {
                            self.volume = volumeValue
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    // Обновляет коэффициенты усиления эквалайзера в реальном времени
    func applyEQChanges() {
        audioPlayer?.updateEQSettings()
    }
}

// MARK: - Вертикальный ползунок эквалайзера в стиле аудио-консоли
struct VerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -12...12
    let label: String
    
    var body: some View {
        VStack(spacing: 8) {
            Text(String(format: "%+.1f", value))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 48)
            
            GeometryReader { geo in
                let height = geo.size.height
                let pct = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 6)
                    
                    Capsule()
                        .fill(Color.red)
                        .frame(width: 6, height: max(0, min(height, height * pct)))
                    
                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: Color.black.opacity(0.25), radius: 2)
                        .offset(y: -height * pct + 9)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .padding(.vertical, 9)
                .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.75), value: value)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let touchY = gesture.location.y
                            let percent = 1 - min(max(touchY / height, 0), 1)
                            value = Double(percent) * (range.upperBound - range.lowerBound) + range.lowerBound
                        }
                )
            }
            .frame(height: 140)
            
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
        }
        .frame(width: 44)
    }
}

// MARK: - Экран настройки эквалайзера
struct EqualizerSettingsView: View {
    @AppStorage("eq_enabled") private var isEqEnabled: Bool = false
    @AppStorage("selected_eq_preset") private var selectedPresetName: String = "Обычный (Flat)"
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    
    // Используем AppStorage типа Double
    @AppStorage("eq_band_0") private var band0: Double = 0.0
    @AppStorage("eq_band_1") private var band1: Double = 0.0
    @AppStorage("eq_band_2") private var band2: Double = 0.0
    @AppStorage("eq_band_3") private var band3: Double = 0.0
    @AppStorage("eq_band_4") private var band4: Double = 0.0
    @AppStorage("eq_band_5") private var band5: Double = 0.0
    @AppStorage("eq_band_6") private var band6: Double = 0.0
    @AppStorage("eq_band_7") private var band7: Double = 0.0
    @AppStorage("eq_band_8") private var band8: Double = 0.0
    @AppStorage("eq_band_9") private var band9: Double = 0.0
    
    private let frequencies = ["32Гц", "64Гц", "125Гц", "250Гц", "500Гц", "1кГц", "2кГц", "4кГц", "8кГц", "16кГц"]
    
    // Универсальное реактивное связывание для каждого ползунка
    private func bandBinding(for index: Int) -> Binding<Double> {
        Binding(
            get: {
                switch index {
                case 0: return band0
                case 1: return band1
                case 2: return band2
                case 3: return band3
                case 4: return band4
                case 5: return band5
                case 6: return band6
                case 7: return band7
                case 8: return band8
                case 9: return band9
                default: return 0.0
                }
            },
            set: { newValue in
                switch index {
                case 0: band0 = newValue
                case 1: band1 = newValue
                case 2: band2 = newValue
                case 3: band3 = newValue
                case 4: band4 = newValue
                case 5: band5 = newValue
                case 6: band6 = newValue
                case 7: band7 = newValue
                case 8: band8 = newValue
                case 9: band9 = newValue
                default: break
                }
                selectedPresetName = "Вручную"
                MusicManager.shared.applyEQChanges()
            }
        )
    }
    
    var body: some View {
        Form {
            Section {
                Toggle("Включить эквалайзер", isOn: $isEqEnabled)
                    .onChange(of: isEqEnabled) { _ in
                        MusicManager.shared.applyEQChanges()
                    }
            }
            
            if isEqEnabled {
                Section(header: Text("Параметрические полосы")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(0..<10, id: \.self) { index in
                                VerticalSlider(value: bandBinding(for: index), label: frequencies[index])
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
                
                Section(header: Text("Популярные пресеты")) {
                    List {
                        ForEach(eqPresets) { preset in
                            HStack {
                                Text(preset.name)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedPresetName == preset.name {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.red)
                                        .font(.subheadline.bold())
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                applyPreset(preset)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Эквалайзер")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(appTheme.colorScheme)
    }
    
    private func applyPreset(_ preset: EQPreset) {
        withAnimation {
            selectedPresetName = preset.name
            band0 = preset.gains[0]
            band1 = preset.gains[1]
            band2 = preset.gains[2]
            band3 = preset.gains[3]
            band4 = preset.gains[4]
            band5 = preset.gains[5]
            band6 = preset.gains[6]
            band7 = preset.gains[7]
            band8 = preset.gains[8]
            band9 = preset.gains[9]
        }
        MusicManager.shared.applyEQChanges()
    }
}

// MARK: - Синхронизированный просмотр текста
struct LyricsView: View {
    let lyrics: [LyricLine]
    let currentTime: TimeInterval
    var isImmersive: Bool = false
    var onSeek: ((TimeInterval) -> Void)? = nil
    var onScroll: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    @AppStorage("lyricsFontSize") private var lyricsFontSize: Double = 34.0
    @AppStorage("karaokeModeEnabled") private var karaokeModeEnabled: Bool = true
    
    @State private var isUserScrolling = false
    @State private var resetTask: DispatchWorkItem? = nil

    private var activeIndex: Int? {
        guard lyrics.contains(where: { $0.time >= 0 }) else { return nil }
        var result: Int? = nil
        for (i, line) in lyrics.enumerated() where line.time >= 0 && line.time <= currentTime {
            result = i
        }
        return result
    }

    private var displayIndex: Int? { isUserScrolling ? nil : activeIndex }

    private func opacity(for i: Int) -> Double {
        guard let cur = displayIndex else { return 0.75 }
        switch abs(i - cur) {
        case 0: return 1.0
        case 1: return 0.5
        case 2: return 0.3
        default: return 0.15
        }
    }

    private func blurRadius(for i: Int) -> CGFloat {
        guard let cur = displayIndex else { return 0 }
        switch abs(i - cur) {
        case 0: return 0
        case 1: return 0.8
        case 2: return 1.5
        default: return 2.2
        }
    }

    private func scale(for i: Int) -> CGFloat {
        guard let cur = displayIndex else { return 1 }
        switch abs(i - cur) {
        case 0: return 1.08
        default: return 1.0
        }
    }

    private func progress(for index: Int) -> Double {
        let currentLineTime = lyrics[index].time
        let nextLineTime: Double
        
        if index + 1 < lyrics.count, lyrics[index + 1].time >= 0 {
            nextLineTime = lyrics[index + 1].time
        } else {
            nextLineTime = currentLineTime + 8.0
        }
        
        let duration = min(nextLineTime - currentLineTime, 8.0)
        guard duration > 0 else { return 1.0 }
        
        let p = (currentTime - currentLineTime) / duration
        return max(0, p)
    }

    private func karaokeText(for line: String, progress: Double, isActiveLine: Bool) -> Text {
        guard isActiveLine && karaokeModeEnabled else {
            return Text(line).foregroundColor(.primary)
        }
        
        let chars = Array(line)
        let total = Double(max(1, chars.count))
        
        var result = Text("")
        
        for (index, char) in chars.enumerated() {
            let start = Double(index) / total
            let end = Double(index + 1) / total
            
            let opacity: Double
            if progress <= start {
                opacity = 0.35
            } else if progress >= end {
                opacity = 1.0
            } else {
                let fillRatio = (progress - start) / (end - start)
                opacity = 0.35 + (0.65 * fillRatio)
            }
            
            result = result + Text(String(char)).foregroundColor(Color.primary.opacity(opacity))
        }
        
        return result
    }
    
    private func karaokeGlowText(for line: String, progress: Double) -> Text {
        let chars = Array(line)
        let total = Double(max(1, chars.count))
        
        var result = Text("")
        
        for (index, char) in chars.enumerated() {
            let start = Double(index) / total
            let end = Double(index + 1) / total
            let center = (start + end) / 2.0
            
            let glowSpread = max(0.15, 2.5 / total)
            
            let distance = abs(progress - center)
            let opacity: Double
            
            if distance < glowSpread {
                opacity = 1.0 - (distance / glowSpread)
            } else {
                opacity = 0.0
            }
            
            result = result + Text(String(char)).foregroundColor(Color.primary.opacity(opacity))
        }
        
        return result
    }

    private func scheduleReset() {
        resetTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.4)) { isUserScrolling = false }
        }
        resetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: task)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    ForEach(Array(lyrics.enumerated()), id: \.element.id) { i, line in
                        let isActive = displayIndex == i
                        let currentProgress = progress(for: i)
                        
                        ZStack {
                            karaokeText(for: line.text, progress: currentProgress, isActiveLine: isActive)
                            
                            if isActive && karaokeModeEnabled {
                                karaokeGlowText(for: line.text, progress: currentProgress)
                                    .blur(radius: 7)
                                    .opacity(0.85)
                                    .scaleEffect(1.02)
                            }
                        }
                        .font(.system(size: CGFloat(lyricsFontSize), weight: isActive ? .bold : .regular))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .opacity(opacity(for: i))
                        .blur(radius: blurRadius(for: i))
                        .scaleEffect(scale(for: i))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .id(line.id)
                        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: displayIndex)
                        .onTapGesture {
                                guard line.time >= 0 else {
                                    onTap?()
                                    return
                                }
                                onSeek?(line.time)
                                onTap?()
                                resetTask?.cancel()
                                withAnimation(.easeInOut(duration: 0.3)) { isUserScrolling = false }
                            }
                    }
                }
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height)
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { onTap?() })
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        onScroll?()
                        resetTask?.cancel()
                        if !isUserScrolling {
                            withAnimation(.easeInOut(duration: 0.25)) { isUserScrolling = true }
                        }
                    }
                    .onEnded { _ in
                        onScroll?()
                        scheduleReset()
                    }
            )
            .onChange(of: activeIndex) { newIndex in
                guard !isUserScrolling, let idx = newIndex, lyrics.indices.contains(idx) else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    proxy.scrollTo(lyrics[idx].id, anchor: .center)
                }
            }
            .onChange(of: isUserScrolling) { scrolling in
                guard !scrolling, let idx = activeIndex, lyrics.indices.contains(idx) else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    proxy.scrollTo(lyrics[idx].id, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Редактор текста
struct LyricsEditorView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @ObservedObject var lyricsManager = LyricsManager.shared

    let trackURL: URL
    let trackTitle: String
    let trackArtist: String

    @State private var editorText: String = ""
    @State private var showLRCPicker = false
    @State private var showDeleteAlert = false
    @State private var importBanner: String? = nil
    @State private var isFetchingOnline = false

    init(trackURL: URL, trackTitle: String, trackArtist: String) {
        self.trackURL = trackURL
        self.trackTitle = trackTitle
        self.trackArtist = trackArtist
        UITextView.appearance().backgroundColor = .clear
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button(action: fetchOnline) {
                            if isFetchingOnline {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .frame(width: 20, height: 20)
                            } else {
                                Label("Найти в сети", systemImage: "network")
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.blue)
                        .cornerRadius(10)
                        .disabled(isFetchingOnline)
                        
                        Button(action: { showLRCPicker = true }) {
                            Label("Импорт LRC", systemImage: "doc.badge.plus")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Color.red)
                                .cornerRadius(10)
                        }
                        
                        if !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(action: { showDeleteAlert = true }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.white)
                                    .padding(9)
                                    .background(Color.gray.opacity(0.5))
                                    .cornerRadius(10)
                            }
                        }
                        Spacer()
                        if editorText.contains("[") && editorText.contains(":") {
                            Label("LRC", systemImage: "timer")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 12)

                if let banner = importBanner {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill").foregroundColor(.blue)
                        Text(banner).font(.caption).foregroundColor(.blue)
                        Spacer()
                    }
                    .padding(.horizontal).padding(.bottom, 8)
                    .transition(.opacity)
                }

                Divider()

                ZStack(alignment: .topLeading) {
                    if editorText.isEmpty {
                        Text("Введите текст песни вручную, или вставьте LRC-содержимое с временными метками вида [01:23.45]…")
                            .foregroundColor(.gray.opacity(0.6))
                            .font(.body)
                            .padding(.horizontal, 18).padding(.top, 14)
                    }
                    TextEditor(text: $editorText)
                        .font(.body)
                        .padding(.horizontal, 12).padding(.top, 6)
                        .background(Color.clear)
                }
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle(trackTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: saveAndDismiss) {
                        Text("Сохранить").fontWeight(.bold)
                    }
                }
            }
            .alert("Очистить текст?", isPresented: $showDeleteAlert) {
                Button("Отмена", role: .cancel) {}
                Button("Очистить", role: .destructive) {
                    editorText = ""
                    lyricsManager.deleteLyrics(for: trackURL)
                }
            }
            .fileImporter(
                isPresented: $showLRCPicker,
                allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText],
                allowsMultipleSelection: false
            ) { result in
                importLRCFile(result: result)
            }
        }
        .onAppear {
            let lines = lyricsManager.lyrics(for: trackURL)
            editorText = lines.isEmpty ? "" : lyricsManager.lrcText(for: lines)
        }
        .preferredColorScheme(appTheme.colorScheme)
    }

    private func saveAndDismiss() {
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lyricsManager.deleteLyrics(for: trackURL)
        } else if trimmed.contains("[") {
            let parsed = lyricsManager.parseLRC(trimmed)
            if parsed.contains(where: { $0.time >= 0 }) {
                lyricsManager.setLyrics(parsed, for: trackURL)
            } else {
                savePlainText(trimmed)
            }
        } else {
            savePlainText(trimmed)
        }
        dismiss()
    }

    private func savePlainText(_ text: String) {
        let lines = text.components(separatedBy: "\n")
            .map { LyricLine(time: -1, text: $0) }
        lyricsManager.setLyrics(lines, for: trackURL)
    }

    private func importLRCFile(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = lyricsManager.parseLRC(content)
        lyricsManager.setLyrics(lines, for: trackURL)
        editorText = lyricsManager.lrcText(for: lines)
        withAnimation { importBanner = "Импортирован: \(url.lastPathComponent)" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { importBanner = nil }
        }
    }
    
    private func fetchOnline() {
        isFetchingOnline = true
        Task {
            let foundLyrics = await lyricsManager.fetchLyricsFromLRCLib(title: trackTitle, artist: trackArtist)
            
            await MainActor.run {
                isFetchingOnline = false
                if let newText = foundLyrics, !newText.isEmpty {
                    editorText = newText
                    withAnimation { importBanner = "Текст успешно загружен!" }
                } else {
                    withAnimation { importBanner = "К сожалению, ничего не найдено 😔" }
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    withAnimation { importBanner = nil }
                }
            }
        }
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    @State private var artwork: UIImage?
    @ObservedObject private var lyricsManager = LyricsManager.shared

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1))
                if let image = artwork { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "music.note").foregroundColor(.gray).font(.system(size: 14)) }
                if lyricsManager.hasLyrics(for: track.url) {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(3)
                                .background(Color.red.opacity(0.8))
                                .clipShape(Circle())
                        }
                        Spacer()
                    }
                    .padding(3)
                }
            }
            .frame(width: 45, height: 45).cornerRadius(6).clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).foregroundColor(isCurrent ? .red : .primary).lineLimit(1)
                Text(track.artist).font(.caption).foregroundColor(.gray).lineLimit(1)
            }
            Spacer()
            if isCurrent && isPlaying { Image(systemName: "waveform").foregroundColor(.red) }
        }
        .onAppear {
            DispatchQueue.global(qos: .userInteractive).async {
                let asset = AVAsset(url: track.url)
                for item in asset.metadata where item.commonKey == .commonKeyArtwork {
                    if let data = item.dataValue, let img = UIImage(data: data) {
                        DispatchQueue.main.async { self.artwork = img }
                    }
                }
            }
        }
    }
}

struct MiniPlayer: View {
    @ObservedObject var manager = MusicManager.shared
    @Binding var showFullPlayer: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider().background(Color.primary.opacity(0.1))
            HStack(spacing: 12) {
                ZStack {
                    if let image = manager.currentArtwork { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill) }
                    else { Color.primary.opacity(0.1); Image(systemName: "music.note").foregroundColor(.gray) }
                }
                .frame(width: 48, height: 48).cornerRadius(4).clipped()

                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.currentTitle).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(manager.currentArtist).font(.system(size: 13)).foregroundColor(.gray).lineLimit(1)
                }
                Spacer()
                HStack(spacing: 20) {
                    Button(action: manager.playPause) { Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill").font(.title2) }
                    Button(action: manager.nextTrack) { Image(systemName: "forward.fill").font(.title2) }
                }.foregroundColor(.primary)
            }
            .padding(.horizontal, 20).frame(height: 72)
        }
        .background(BlurView(style: .systemChromeMaterial).ignoresSafeArea(edges: .bottom))
        .onTapGesture { showFullPlayer = true }
    }
}

struct ImmersiveBottomBar: View {
    @ObservedObject var manager: MusicManager
    
    var body: some View {
        HStack(spacing: 14) {
            if let image = manager.currentArtwork {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48).cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: "music.note").foregroundColor(.white.opacity(0.5)))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(manager.currentTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(manager.currentArtist)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
            
            Spacer()
            
            Button(action: manager.playPause) {
                Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.4).edgesIgnoringSafeArea(.bottom))
        .background(BlurView(style: .systemMaterialDark).edgesIgnoringSafeArea(.bottom))
    }
}

// MARK: - Главный экран
struct ContentView: View {
    @StateObject var manager = MusicManager.shared
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    
    @State private var showFilePicker = false
    @State private var showFullPlayer = false
    @State private var showSettings = false
    @State private var searchText = ""
    
    @State private var shareURL: URL?
    
    @State private var isFetchingMassLyrics = false
    @State private var processedTracksCount = 0
    @State private var totalTracksToFetch = 0
    @State private var foundLyricsCount = 0
    @State private var showMassFetchResult = false

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationView {
                ZStack {
                    Color(UIColor.systemBackground).ignoresSafeArea()
                    
                    if manager.tracks.isEmpty {
                        VStack {
                            Image(systemName: "music.note.list").font(.system(size: 60)).foregroundColor(.gray)
                            Text("Медиатека пуста").foregroundColor(.gray).padding()
                        }
                    } else {
                        List {
                            ForEach(manager.tracks.filter { track in
                                if searchText.isEmpty { return true }
                                let matchTitle = track.title.localizedCaseInsensitiveContains(searchText)
                                let matchArtist = track.artist.localizedCaseInsensitiveContains(searchText)
                                return matchTitle || matchArtist
                            }, id: \.self) { track in
                                TrackRow(track: track, isCurrent: manager.audioPlayer?.url == track.url, isPlaying: manager.isPlaying)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        manager.shuffleOn = false
                                        if let i = manager.tracks.firstIndex(of: track) { manager.playTrack(at: i, in: manager.tracks) }
                                    }
                                    .contextMenu {
                                        Button(action: { shareURL = track.url }) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                                        Button(role: .destructive, action: { manager.deleteTrack(track: track) }) { Label("Удалить", systemImage: "trash") }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) { manager.deleteTrack(track: track) } label: { Label("Удалить", systemImage: "trash") }
                                        Button { shareURL = track.url } label: { Label("Поделиться", systemImage: "square.and.arrow.up") }.tint(.blue)
                                    }
                                    .listRowBackground(Color.clear)
                            }
                            .onDelete(perform: manager.deleteTrack)
                            
                            Color.clear
                                .frame(height: 85)
                                .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                        .disabled(isFetchingMassLyrics)
                    }
                    
                    if isFetchingMassLyrics {
                        ZStack {
                            Color.black.opacity(0.4).ignoresSafeArea()
                            BlurView(style: .systemThinMaterialDark).ignoresSafeArea()
                            
                            VStack(spacing: 24) {
                                ProgressView()
                                    .scaleEffect(1.8)
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                
                                VStack(spacing: 8) {
                                    Text("Ищем тексты...")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    
                                    Text("\(processedTracksCount) из \(totalTracksToFetch)")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            .padding(40)
                            .background(Color(UIColor.secondarySystemBackground).opacity(0.15))
                            .cornerRadius(24)
                        }
                        .zIndex(100)
                    }
                }
                .navigationTitle("Музыка")
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 12) {
                            Button(action: { showFilePicker = true }) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.title3)
                            }
                            
                            Menu {
                                Button(action: fetchLyricsForAll) {
                                    Label("Найти тексты для всех", systemImage: "text.magnifyingglass")
                                }
                                Button(action: { showSettings = true }) {
                                    Label("Настройки", systemImage: "gearshape")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.title3)
                            }
                        }
                    }
                }
                .alert("Результаты поиска", isPresented: $showMassFetchResult) {
                    Button("Завершить поиск.", role: .cancel) { }
                } message: {
                    if totalTracksToFetch == 0 {
                        Text("Для всех твоих треков тексты уже есть.")
                    } else {
                        Text("Обработано треков: \(totalTracksToFetch)\nУспешно найдено: \(foundLyricsCount)\nНе найдено : \(totalTracksToFetch - foundLyricsCount)")
                    }
                }
            }
            .navigationViewStyle(StackNavigationViewStyle())

            if !manager.tracks.isEmpty { MiniPlayer(showFullPlayer: $showFullPlayer) }
        }
        .preferredColorScheme(appTheme.colorScheme)
        .fullScreenCover(isPresented: $showFullPlayer) { FullPlayerView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $shareURL) { url in
            ActivityViewController(activityItems: [url])
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio, UTType(filenameExtension: "lrc") ?? .plainText],
            allowsMultipleSelection: true
        ) { res in
            if case .success(let urls) = res { manager.importTracks(from: urls) }
        }
    }
    
    private func fetchLyricsForAll() {
        let tracksToProcess = manager.tracks.filter { !LyricsManager.shared.hasLyrics(for: $0.url) }
        
        guard !tracksToProcess.isEmpty else {
            totalTracksToFetch = 0
            foundLyricsCount = 0
            showMassFetchResult = true
            return
        }
        
        isFetchingMassLyrics = true
        totalTracksToFetch = tracksToProcess.count
        processedTracksCount = 0
        foundLyricsCount = 0
        
        Task {
            for track in tracksToProcess {
                let foundLyrics = await LyricsManager.shared.fetchLyricsFromLRCLib(title: track.title, artist: track.artist)
                
                if let newText = foundLyrics, !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if trimmed.contains("[") {
                        let parsed = LyricsManager.shared.parseLRC(trimmed)
                        if parsed.contains(where: { $0.time >= 0 }) {
                            LyricsManager.shared.setLyrics(parsed, for: track.url)
                        } else {
                            let lines = trimmed.components(separatedBy: "\n").map { LyricLine(time: -1, text: $0) }
                            LyricsManager.shared.setLyrics(lines, for: track.url)
                        }
                    } else {
                        let lines = trimmed.components(separatedBy: "\n").map { LyricLine(time: -1, text: $0) }
                        LyricsManager.shared.setLyrics(lines, for: track.url)
                    }
                    
                    await MainActor.run { foundLyricsCount += 1 }
                }
                
                await MainActor.run { processedTracksCount += 1 }
            }
            
            await MainActor.run {
                isFetchingMassLyrics = false
                showMassFetchResult = true
            }
        }
    }
}

extension URL: Identifiable {
    public var id: String { self.absoluteString }
}

// MARK: - Окно настроек
struct SettingsView: View {
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("controlSystemVolume") private var controlSystemVolume: Bool = false
    
    @AppStorage("eq_enabled") private var isEqEnabled: Bool = false
    @AppStorage("selected_eq_preset") private var selectedPresetName: String = "Обычный (Flat)"
    
    @AppStorage("karaokeModeEnabled") private var karaokeModeEnabled: Bool = true
    @AppStorage("autoImmersiveLyricsEnabled") private var autoImmersiveLyricsEnabled: Bool = true
    @AppStorage("autoImmersiveLyricsTimeout") private var autoImmersiveLyricsTimeout: Double = 3.0
    @AppStorage("lyricsFontSize") private var lyricsFontSize: Double = 34.0
    
    @Environment(\.dismiss) var dismiss
    @State private var showingClearAlert = false
    @ObservedObject var manager = MusicManager.shared

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Внешний вид")) {
                    Picker("Тема оформления", selection: $appTheme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                }
                
                Section(header: Text("Звуковые эффекты")) {
                    NavigationLink(destination: EqualizerSettingsView()) {
                        HStack {
                            Label("Эквалайзер", systemImage: "slider.horizontal.3")
                                .foregroundColor(.red)
                            Spacer()
                            Text(isEqEnabled ? selectedPresetName : "Выкл.")
                                .foregroundColor(.gray)
                        }
                    }
                }
                
                Section(header: Text("Текст песни")) {
                    Toggle("Караоке-режим", isOn: $karaokeModeEnabled)
                    Toggle("Иммерсивный режим", isOn: $autoImmersiveLyricsEnabled)
                    if autoImmersiveLyricsEnabled {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Задержка включения: \(Int(autoImmersiveLyricsTimeout)) сек.")
                                .font(.body)
                            Slider(value: $autoImmersiveLyricsTimeout, in: 1...15, step: 1)
                                .accentColor(.red)
                            Text("Через какое время бездействия скрывать плеер и оставлять только текст")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Размер шрифта: \(Int(lyricsFontSize)) пт")
                            .font(.body)
                        Slider(value: $lyricsFontSize, in: 18...48, step: 2)
                            .accentColor(.red)
                        Text("Настройте размер отображаемого текста на экране воспроизведения")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("Громкость")) {
                    Toggle(isOn: $controlSystemVolume) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Системная громкость iPhone")
                            Text("Управлять общей громкостью устройства вместо громкости внутри плеера")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .onChange(of: controlSystemVolume) { _ in
                        manager.syncVolumeWithCurrentMode()
                    }
                }
                
                Section(header: Text("Управление")) {
                    Button(role: .destructive, action: {
                        showingClearAlert = true
                    }) {
                        Text("Очистить медиатеку")
                    }
                }
                
                Section(header: Text("О приложении")) {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text("3.1.0").foregroundColor(.gray)
                    }
                    HStack {
                        Text("Разработчик")
                        Spacer()
                        Text("aswer").foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .alert("Очистить медиатеку?", isPresented: $showingClearAlert) {
                Button("Отмена", role: .cancel) { }
                Button("Удалить", role: .destructive) {
                    manager.deleteAllTracks()
                    dismiss()
                }
            } message: {
                Text("Вы точно хотите удалить все треки? Это действие нельзя отменить.")
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
    }
}

// MARK: - Полноэкранный плеер
struct ThinSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    
    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = 4
            let pct = CGFloat((value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.001))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.2))
                    .frame(height: trackHeight)
                
                Capsule()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: max(0, min(geo.size.width, geo.size.width * pct)), height: trackHeight)
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let percent = min(max(v.location.x / geo.size.width, 0), 1)
                        value = Double(percent) * (range.upperBound - range.lowerBound) + range.lowerBound
                    }
            )
        }
        .frame(height: 24)
    }
}

struct FullPlayerView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    
    @AppStorage("autoImmersiveLyricsEnabled") private var autoImmersiveLyricsEnabled: Bool = true
    @AppStorage("autoImmersiveLyricsTimeout") private var autoImmersiveLyricsTimeout: Double = 3.0
    
    @ObservedObject var manager = MusicManager.shared
    @ObservedObject var lyricsManager = LyricsManager.shared
    @ObservedObject var playbackTime = PlaybackTime.shared
    
    @State private var showFileInfo = false
    @State private var showShareSheet = false
    @State private var showLyrics = false
    @State private var showLyricsEditor = false
    
    @State private var isImmersiveLyrics = false
    @State private var idleTask: DispatchWorkItem? = nil

    private func resetIdleTimer() {
        idleTask?.cancel()
        guard showLyrics else {
            if isImmersiveLyrics { withAnimation { isImmersiveLyrics = false } }
            return
        }
        
        guard autoImmersiveLyricsEnabled else { return }
        
        let task = DispatchWorkItem {
            if self.showLyrics {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    self.isImmersiveLyrics = true
                }
            }
        }
        idleTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + autoImmersiveLyricsTimeout, execute: task)
    }

    private func handleTap() {
        if isImmersiveLyrics {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                isImmersiveLyrics = false
            }
        }
        resetIdleTimer()
    }
    
    private func handleScroll() {
        if showLyrics && !isImmersiveLyrics && autoImmersiveLyricsEnabled {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                isImmersiveLyrics = true
            }
        }
        resetIdleTimer()
    }

    var body: some View {
        GeometryReader { geo in
            let isSmall = geo.size.height < 670
            
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()
                if let image = manager.currentArtwork {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 40).opacity(0.45).ignoresSafeArea()
                }
                BlurView(style: .systemThinMaterial).opacity(0.8).ignoresSafeArea()
                
                VStack(spacing: 0) {
                    if !isImmersiveLyrics {
                        Capsule().fill(Color.gray.opacity(0.5)).frame(width: 40, height: 5).padding(.top, 10)
                        Spacer(minLength: isSmall ? 10 : 30)
                    }
                    
                    let trackURL = manager.currentTrack?.url
                    let lyrics = trackURL.map { lyricsManager.lyrics(for: $0) } ?? []

                    ZStack {
                        if showLyrics {
                            Group {
                                if lyrics.isEmpty {
                                    VStack(spacing: 16) {
                                        Image(systemName: "text.alignleft")
                                            .font(.system(size: 46))
                                            .foregroundColor(.gray.opacity(0.35))
                                        Text("Текст отсутствует")
                                            .foregroundColor(.gray)
                                        Button(action: { showLyricsEditor = true }) {
                                            Label("Добавить текст", systemImage: "plus")
                                                .font(.subheadline.weight(.medium))
                                                .foregroundColor(.red)
                                                .padding(.horizontal, 18).padding(.vertical, 9)
                                                .background(Color.red.opacity(0.1))
                                                .cornerRadius(10)
                                        }
                                    }
                                } else {
                                    LyricsView(
                                        lyrics: lyrics,
                                        currentTime: playbackTime.currentTime,
                                        isImmersive: isImmersiveLyrics,
                                        onSeek: { manager.seek(to: $0) },
                                        onScroll: { handleScroll() },
                                        onTap: { handleTap() }
                                    )
                                }
                            }
                            .transition(.opacity)
                        } else {
                            Group {
                                RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.1))
                                if let image = manager.currentArtwork {
                                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: isSmall ? 40 : 80))
                                        .foregroundColor(.red)
                                }
                            }
                            .scaleEffect(manager.isPlaying ? 1.0 : 0.9)
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: manager.isPlaying)
                            .transition(.opacity)
                        }
                    }
                    .frame(
                        maxWidth: isImmersiveLyrics ? .infinity : (isSmall ? geo.size.width * 0.75 : geo.size.width * 0.88),
                        maxHeight: isImmersiveLyrics ? .infinity : (isSmall ? geo.size.width * 0.75 : geo.size.width * 0.88)
                    )
                    .animation(.spring(response: 0.55, dampingFraction: 0.82), value: isImmersiveLyrics)
                    .cornerRadius(isImmersiveLyrics ? 0 : 20)
                    .shadow(color: isImmersiveLyrics ? .clear : Color(UIColor.label).opacity(0.2), radius: isImmersiveLyrics ? 0 : 20)
                    .gesture(
                        DragGesture().onEnded { value in
                            guard !showLyrics else { return }
                            if value.translation.width < -50 { withAnimation { manager.nextTrack() } }
                            else if value.translation.width > 50 { withAnimation { manager.prevTrack() } }
                        }
                    )
                    .overlay(alignment: .topTrailing) {
                        if !isImmersiveLyrics {
                            HStack(spacing: 4) {
                                if showLyrics {
                                    Button(action: { showLyricsEditor = true }) {
                                        Image(systemName: "square.and.pencil")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.primary.opacity(0.85))
                                            .padding(7)
                                            .background(.ultraThinMaterial)
                                            .cornerRadius(8)
                                    }
                                }
                                Button(action: { withAnimation(.easeInOut(duration: 0.35)) { showLyrics.toggle() } }) {
                                    Image(systemName: showLyrics ? "music.note" : "text.alignleft")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(showLyrics ? .red : .primary.opacity(0.85))
                                        .padding(7)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(8)
                                }
                            }
                            .padding(10)
                        } else {
                            Button(action: handleTap) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white.opacity(0.65))
                                    .padding(20)
                            }
                            .transition(.opacity)
                        }
                    }

                    if isImmersiveLyrics {
                        ImmersiveBottomBar(manager: manager)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        VStack(spacing: 0) {
                            Spacer(minLength: isSmall ? 8 : 15)
                            
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(manager.currentTitle)
                                        .font(isSmall ? .headline : .title2).bold()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                        .foregroundColor(.primary)
                                    Text(manager.currentArtist)
                                        .font(isSmall ? .subheadline : .title3)
                                        .foregroundColor(.primary.opacity(0.7))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 30)
                            .contentShape(Rectangle())
                            .onTapGesture { showFileInfo = true }

                            Spacer(minLength: isSmall ? 10 : 20)
                            
                            VStack(spacing: 4) {
                                ThinSlider(
                                    value: Binding(
                                        get: { playbackTime.currentTime },
                                        set: { playbackTime.currentTime = $0; manager.seek(to: $0) }
                                    ),
                                    range: 0...max(manager.trackDuration, 1)
                                )
                                
                                HStack {
                                    Text(formatTime(playbackTime.currentTime))
                                    Spacer()
                                    Text(formatTime(manager.trackDuration))
                                }.font(.caption2.bold()).foregroundColor(.gray)
                            }.padding(.horizontal, 30)

                            Spacer(minLength: isSmall ? 15 : 25)
                            
                            HStack(spacing: isSmall ? 40 : 60) {
                                Button(action: manager.prevTrack) { Image(systemName: "backward.fill").font(.title) }
                                Button(action: manager.playPause) {
                                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: isSmall ? 40 : 50))
                                }
                                Button(action: manager.nextTrack) { Image(systemName: "forward.fill").font(.title) }
                            }.foregroundColor(.primary)

                            Spacer(minLength: isSmall ? 15 : 25)
                            
                            HStack(spacing: 12) {
                                Image(systemName: "speaker.fill").font(.caption).foregroundColor(.gray)
                                ThinSlider(
                                    value: Binding(
                                        get: { Double(manager.volume) },
                                        set: { manager.volume = Float($0) }
                                    ),
                                    range: 0...1
                                )
                                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundColor(.gray)
                            }.padding(.horizontal, 35)
                            
                            Spacer(minLength: isSmall ? 10 : 20)
                            
                            HStack {
                                Button(action: manager.toggleShuffle) {
                                    Image(systemName: "shuffle").font(.system(size: 18, weight: .medium))
                                        .foregroundColor(manager.shuffleOn ? .red : .primary.opacity(0.6))
                                        .padding(10).background(manager.shuffleOn ? Color.red.opacity(0.1) : Color.clear).cornerRadius(10)
                                }
                                Spacer(minLength: 10)
                                
                                Button(action: {
                                    if manager.currentTrack != nil {
                                        showShareSheet = true
                                    }
                                }) {
                                    Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.primary.opacity(0.8))
                                        .padding(10)
                                        .background(Color.clear)
                                        .cornerRadius(10)
                                }
                                .disabled(manager.currentTrack == nil)
                                
                                Spacer(minLength: 10)
                                AirPlayView().frame(width: 35, height: 35)
                                Spacer(minLength: 10)
                                
                                Button(action: manager.toggleRepeat) {
                                    Image(systemName: manager.repeatMode.iconName).font(.system(size: 18, weight: .medium))
                                        .foregroundColor(manager.repeatMode == .none ? .primary.opacity(0.6) : .red)
                                        .padding(10).background(manager.repeatMode == .none ? Color.clear : Color.red.opacity(0.1)).cornerRadius(10)
                                }
                            }.padding(.horizontal, 30)
                            
                            Spacer(minLength: 5)
                            Text("by aswer.").font(.caption2.monospaced()).opacity(0.2).padding(.bottom, 5)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(width: geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .gesture(DragGesture().onEnded { if $0.translation.height > 80 { dismiss() } })
        .sheet(isPresented: $showFileInfo) {
            if let currentUrl = manager.audioPlayer?.url {
                FileInfoView(url: currentUrl, duration: manager.trackDuration)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let currentTrack = manager.currentTrack {
                ActivityViewController(activityItems: [currentTrack.url])
            }
        }
        .sheet(isPresented: $showLyricsEditor) {
            if let track = manager.currentTrack {
                LyricsEditorView(trackURL: track.url, trackTitle: track.title, trackArtist: track.artist)
            }
        }
        .onChange(of: manager.currentTrackIndex) { _ in
            withAnimation {
                showLyrics = false
                isImmersiveLyrics = false
            }
        }
        .onChange(of: autoImmersiveLyricsEnabled) { isEnabled in
            if !isEnabled {
                idleTask?.cancel()
                withAnimation {
                    isImmersiveLyrics = false
                }
            } else {
                resetIdleTimer()
            }
        }
        .onChange(of: showLyrics) { _ in
            resetIdleTimer()
        }
        .onAppear {
            manager.syncVolumeWithCurrentMode()
            resetIdleTimer()
        }
        .preferredColorScheme(appTheme.colorScheme)
    }
    
    func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite && !t.isNaN else { return "00:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Экран информации о файле
struct FileInfoView: View {
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    let url: URL
    let duration: TimeInterval
    @Environment(\.dismiss) var dismiss
    @State private var fileSize: String = "Вычисляется..."
    @State private var showShareSheet = false
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Основная информация")) {
                    InfoRow(title: "Имя файла", value: url.lastPathComponent)
                    InfoRow(title: "Формат", value: url.pathExtension.uppercased())
                    InfoRow(title: "Размер", value: fileSize)
                    InfoRow(title: "Длительность", value: formatTime(duration))
                }
                
                Section(header: Text("Расположение файла")) {
                    Text(url.path).font(.caption2).foregroundColor(.gray)
                }
                
                Section {
                    Button(action: { showShareSheet = true }) {
                        HStack {
                            Spacer()
                            Label("Поделиться файлом", systemImage: "square.and.arrow.up")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Свойства трека")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear(perform: calculateFileSize)
            .sheet(isPresented: $showShareSheet) {
                ActivityViewController(activityItems: [url])
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
    }
    
    private func calculateFileSize() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useKB]
            formatter.countStyle = .file
            fileSize = formatter.string(fromByteCount: size)
        } else { fileSize = "Неизвестно" }
    }
    
    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite && !t.isNaN else { return "00:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(title).foregroundColor(.gray)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Системные обертки
struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: UIBlurEffect(style: style)) }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

struct AirPlayView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let p = AVRoutePickerView()
        p.activeTintColor = .systemRed
        p.tintColor = UIColor.label.withAlphaComponent(0.6)
        p.backgroundColor = .clear
        return p
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct ActivityViewController: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: UIViewControllerRepresentableContext<ActivityViewController>) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ActivityViewController>) {}
}
