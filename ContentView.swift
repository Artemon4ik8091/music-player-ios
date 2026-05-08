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

// MARK: - 1. Менеджер музыки
class MusicManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = MusicManager()
    var audioPlayer: AVAudioPlayer?
    
    @Published var tracks: [Track] = [] // Теперь храним объекты Track
    private var shuffledTracks: [Track] = []
    
    @Published var isPlaying = false
    @Published var currentTrackIndex = 0
    @Published var volume: Float = 0.7 { didSet { audioPlayer?.volume = volume } }
    
    @Published var shuffleOn = false { didSet { updateShuffledList() } }
    @Published var repeatMode: RepeatMode = .none
    
    @Published var currentArtwork: UIImage?
    @Published var trackDuration: TimeInterval = 0
    @Published var currentTime: TimeInterval = 0
    @Published var currentTitle: String = ""
    @Published var currentArtist: String = ""
    
    private var timer: AnyCancellable?

    var currentList: [Track] {
        return shuffleOn ? shuffledTracks : tracks
    }

    override init() {
        super.init()
        setupSession()
        setupRemoteCommands()
        loadTracksFromDisk()
    }
    
    func setupSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("Session error: \(error)") }
    }

    // Загрузка и парсинг метаданных при сканировании диска
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
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            let dest = docs.appendingPathComponent(url.lastPathComponent)
            try? fileManager.copyItem(at: url, to: dest)
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        loadTracksFromDisk()
    }

    func deleteTrack(at offsets: IndexSet) {
        offsets.forEach { try? FileManager.default.removeItem(at: tracks[$0].url) }
        loadTracksFromDisk()
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
            audioPlayer = try AVAudioPlayer(contentsOf: track.url)
            audioPlayer?.delegate = self
            audioPlayer?.volume = volume
            audioPlayer?.play()
            isPlaying = true
            trackDuration = audioPlayer?.duration ?? 0
            
            // Обновляем текущую информацию из уже готового объекта Track
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
        audioPlayer?.currentTime = time
        currentTime = time
        updateNowPlaying()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if !flag { return }
        if repeatMode == .one { playTrack(at: currentTrackIndex) }
        else if repeatMode == .all || currentTrackIndex < currentList.count - 1 { nextTrack() }
        else { isPlaying = false; updateNowPlaying() }
    }

    func toggleShuffle() { shuffleOn.toggle() }
    func toggleRepeat() { repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % RepeatMode.allCases.count) ?? .none }

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.currentTime = self?.audioPlayer?.currentTime ?? 0
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
            MPMediaItemPropertyArtist: currentArtist, // Теперь система увидит автора
            MPNowPlayingInfoPropertyElapsedPlaybackTime: audioPlayer?.currentTime ?? 0,
            MPMediaItemPropertyPlaybackDuration: trackDuration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        
        // Добавляем обложку в системный плеер
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
}

// MARK: - 2. UI Элементы (Списки и Плееры)
struct TrackRow: View {
    let track: Track // Передаем объект целиком
    let isCurrent: Bool
    let isPlaying: Bool
    @State private var artwork: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1))
                if let image = artwork { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "music.note").foregroundColor(.gray).font(.system(size: 14)) }
            }
            .frame(width: 45, height: 45).cornerRadius(6).clipped()

            VStack(alignment: .leading, spacing: 2) {
                // Отображаем название из метаданных
                Text(track.title).font(.body).foregroundColor(isCurrent ? .red : .white).lineLimit(1)
                // Отображаем исполнителя
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
            Divider().background(Color.white.opacity(0.1))
            HStack(spacing: 12) {
                ZStack {
                    if let image = manager.currentArtwork { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill) }
                    else { Color.white.opacity(0.1); Image(systemName: "music.note").foregroundColor(.gray) }
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
                }.foregroundColor(.white)
            }
            .padding(.horizontal, 20).frame(height: 72).background(BlurView(style: .systemChromeMaterialDark))
            .onTapGesture { showFullPlayer = true }
        }
    }
}

// MARK: - 3. Главный экран
struct ContentView: View {
    @StateObject var manager = MusicManager.shared
    @State private var showFilePicker = false
    @State private var showFullPlayer = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            NavigationView {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if manager.tracks.isEmpty {
                        VStack {
                            Image(systemName: "music.note.list").font(.system(size: 60)).foregroundColor(.gray)
                            Text("Медиатека пуста").foregroundColor(.gray).padding()
                        }
                    } else {
                        List {
                            // Расширенный фильтр для поиска по названию и исполнителю
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
                                    .listRowBackground(Color.clear)
                            }
                            .onDelete(perform: manager.deleteTrack)
                        }
                        .listStyle(.plain)
                    }
                }
                .navigationTitle("Музыка")
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
                .toolbar { Button(action: { showFilePicker = true }) { Image(systemName: "plus.circle.fill").foregroundColor(.red) } }
            }
            .navigationViewStyle(StackNavigationViewStyle())

            if !manager.tracks.isEmpty { MiniPlayer(showFullPlayer: $showFullPlayer) }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showFullPlayer) { FullPlayerView() }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { res in
            if case .success(let urls) = res { manager.importTracks(from: urls) }
        }
    }
}

// MARK: - 4. Полноэкранный плеер
struct FullPlayerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var manager = MusicManager.shared
    @State private var showFileInfo = false

    var body: some View {
        GeometryReader { geo in
            let isSmall = geo.size.height < 670
            VStack(spacing: 0) {
                Capsule().fill(Color.gray.opacity(0.5)).frame(width: 40, height: 5).padding(.top, 10)
                Spacer(minLength: isSmall ? 10 : 30)
                
                // --- ОБЛАСТЬ ОБЛОЖКИ С ЖЕСТАМИ ---
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.1))
                    if let image = manager.currentArtwork {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    }
                    else {
                        Image(systemName: "music.note").font(.system(size: isSmall ? 40 : 80)).foregroundColor(.red)
                    }
                }
                .frame(width: isSmall ? 220 : 300, height: isSmall ? 220 : 300)
                .cornerRadius(20).shadow(color: .black.opacity(0.5), radius: 20)
                .scaleEffect(manager.isPlaying ? 1.0 : 0.9)
                .animation(.spring(), value: manager.isPlaying)
                // Добавляем жест свайпа влево/вправо
                .gesture(
                    DragGesture()
                        .onEnded { value in
                            // Если свайпнули влево (палец пошел влево -> translation отрицательный)
                            if value.translation.width < -50 {
                                withAnimation { manager.nextTrack() }
                            }
                            // Если свайпнули вправо
                            else if value.translation.width > 50 {
                                withAnimation { manager.prevTrack() }
                            }
                        }
                )

                Spacer(minLength: 20)
                
                VStack(spacing: 4) {
                    Text(manager.currentTitle).font(isSmall ? .headline : .title3).bold().lineLimit(1).foregroundColor(.white)
                    Text(manager.currentArtist).font(.subheadline).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                }
                .padding(.horizontal, 30)
                .contentShape(Rectangle())
                .onTapGesture { showFileInfo = true }

                Spacer(minLength: 20)
                
                // Оставшаяся часть интерфейса (Slider, Кнопки управления и т.д.) без изменений
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { manager.currentTime }, set: { manager.seek(to: $0) }), in: 0...max(manager.trackDuration, 1)).accentColor(.white)
                    HStack {
                        Text(formatTime(manager.currentTime))
                        Spacer()
                        Text(formatTime(manager.trackDuration))
                    }.font(.caption.monospaced()).foregroundColor(.gray)
                }.padding(.horizontal, 35)

                Spacer(minLength: 20)
                HStack(spacing: isSmall ? 40 : 60) {
                    Button(action: manager.prevTrack) { Image(systemName: "backward.fill").font(.title2) }
                    Button(action: manager.playPause) { Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: isSmall ? 65 : 85)) }
                    Button(action: manager.nextTrack) { Image(systemName: "forward.fill").font(.title2) }
                }.foregroundColor(.white)

                Spacer(minLength: 25)
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundColor(.gray)
                    Slider(value: $manager.volume, in: 0...1).accentColor(.white)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundColor(.gray)
                }.padding(.horizontal, 40)
                
                Spacer(minLength: 25)
                HStack {
                    Button(action: manager.toggleShuffle) {
                        Image(systemName: "shuffle").foregroundColor(manager.shuffleOn ? .red : .white.opacity(0.6))
                            .padding(10).background(manager.shuffleOn ? Color.red.opacity(0.1) : Color.clear).cornerRadius(10)
                    }
                    Spacer()
                    AirPlayView().frame(width: 35, height: 35)
                    Spacer()
                    Button(action: manager.toggleRepeat) {
                        Image(systemName: manager.repeatMode.iconName).foregroundColor(manager.repeatMode == .none ? .white.opacity(0.6) : .red)
                            .padding(10).background(manager.repeatMode == .none ? Color.clear : Color.red.opacity(0.1)).cornerRadius(10)
                    }
                }.padding(.horizontal, 60)
                
                Spacer(minLength: 10)
                Text("by aswer.").font(.caption2.monospaced()).opacity(0.2).padding(.bottom, 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let image = manager.currentArtwork {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 40).opacity(0.45).ignoresSafeArea()
                    }
                    BlurView(style: .systemThinMaterialDark).opacity(0.8).ignoresSafeArea()
                }
            )
        }
        // Оставляем свайп вниз для закрытия плеера на всем экране
        .gesture(DragGesture().onEnded { if $0.translation.height > 80 { dismiss() } })
        .sheet(isPresented: $showFileInfo) {
            if let currentUrl = manager.audioPlayer?.url {
                FileInfoView(url: currentUrl, duration: manager.trackDuration)
            }
        }
    }
    
    func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
// MARK: - 5. Экран информации о файле
struct FileInfoView: View {
    let url: URL
    let duration: TimeInterval
    @Environment(\.dismiss) var dismiss
    @State private var fileSize: String = "Вычисляется..."
    
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
            }
            .navigationTitle("Свойства трека")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
            .onAppear(perform: calculateFileSize)
        }
        .preferredColorScheme(.dark)
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
        p.tintColor = UIColor.white.withAlphaComponent(0.6)
        p.backgroundColor = .clear
        return p
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
