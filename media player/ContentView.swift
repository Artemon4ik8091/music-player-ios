import SwiftUI
import AVFoundation
import MediaPlayer
import Combine
import UniformTypeIdentifiers

// MARK: - 1. Music Manager (Логика)
class MusicManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = MusicManager()
    var audioPlayer: AVAudioPlayer?
    
    @Published var isPlaying = false
    @Published var currentTrackIndex = 0
    @Published var tracks: [URL] = []
    
    @Published var currentArtwork: UIImage?
    @Published var trackDuration: TimeInterval = 0
    @Published var currentTime: TimeInterval = 0
    
    @Published var currentTitle: String = ""
    @Published var currentArtist: String = ""
    @Published var currentAlbum: String = ""
    
    private var timer: AnyCancellable?

    override init() {
        super.init()
        setupSession()
        setupRemoteCommands()
        loadTracksFromDisk()
    }
    
    func importTracks(from urls: [URL]) {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            
            let destinationURL = documentsURL.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            
            do {
                try fileManager.copyItem(at: url, to: destinationURL)
            } catch {
                print("Ошибка копирования: \(error)")
            }
        }
        loadTracksFromDisk()
    }
    
    func loadTracksFromDisk() {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        do {
            let content = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            let audioFiles = content.filter { ["mp3", "m4a", "wav"].contains($0.pathExtension.lowercased()) }
            
            DispatchQueue.main.async {
                self.tracks = audioFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            }
        } catch {
            print("Ошибка чтения: \(error)")
        }
    }
    
    func deleteTrack(at offsets: IndexSet) {
        let fileManager = FileManager.default
        offsets.forEach { index in
            let url = tracks[index]
            try? fileManager.removeItem(at: url)
        }
        loadTracksFromDisk()
    }

    func setupSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print(error) }
    }
    
    func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { _ in self.playPause(); return .success }
        commandCenter.pauseCommand.addTarget { _ in self.playPause(); return .success }
        commandCenter.nextTrackCommand.addTarget { _ in self.nextTrack(); return .success }
        commandCenter.previousTrackCommand.addTarget { _ in self.prevTrack(); return .success }
    }
    
    func playTrack(at index: Int) {
        guard index >= 0 && index < tracks.count else { return }
        audioPlayer?.stop()
        currentTrackIndex = index
        let url = tracks[index]
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            isPlaying = true
            trackDuration = audioPlayer?.duration ?? 0
            startTimer()
            fetchArtwork(for: url)
            updateNowPlaying()
        } catch { print(error) }
    }
    
    func playPause() {
        guard let player = audioPlayer else {
            if !tracks.isEmpty { playTrack(at: currentTrackIndex) }
            return
        }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
        updateNowPlaying()
    }
    
    func nextTrack() {
        if !tracks.isEmpty {
            let nextIndex = (currentTrackIndex + 1) % tracks.count
            playTrack(at: nextIndex)
        }
    }
    
    func prevTrack() {
        if !tracks.isEmpty {
            let prevIndex = (currentTrackIndex - 1 + tracks.count) % tracks.count
            playTrack(at: prevIndex)
        }
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
        updateNowPlaying()
    }
    
    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let player = self.audioPlayer, player.isPlaying else { return }
                self.currentTime = player.currentTime
            }
    }
    
    private func fetchArtwork(for url: URL) {
        let asset = AVAsset(url: url)
        let metadata = asset.metadata
        
        // Сбрасываем старые значения
        DispatchQueue.main.async {
            self.currentTitle = url.lastPathComponent // По умолчанию имя файла
            self.currentArtist = "Неизвестный исполнитель"
            self.currentAlbum = ""
            self.currentArtwork = nil
        }

        for item in metadata {
            guard let key = item.commonKey else { continue }
            
            switch key {
            case .commonKeyTitle:
                if let value = item.stringValue { DispatchQueue.main.async { self.currentTitle = value } }
            case .commonKeyArtist:
                if let value = item.stringValue { DispatchQueue.main.async { self.currentArtist = value } }
            case .commonKeyAlbumName:
                if let value = item.stringValue { DispatchQueue.main.async { self.currentAlbum = value } }
            case .commonKeyArtwork:
                if let data = item.dataValue, let image = UIImage(data: data) {
                    DispatchQueue.main.async { self.currentArtwork = image }
                }
            default: break
            }
        }
    }
    
    func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: tracks.isEmpty ? "" : tracks[currentTrackIndex].lastPathComponent,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: audioPlayer?.currentTime ?? 0,
            MPMediaItemPropertyPlaybackDuration: audioPlayer?.duration ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let image = currentArtwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { nextTrack() }
    }
}

// MARK: - 2. UI Вспомогательные элементы
extension TimeInterval {
    func formatTime() -> String {
        let min = Int(self) / 60
        let sec = Int(self) % 60
        return String(format: "%02d:%02d", min, sec)
    }
}

struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: UIBlurEffect(style: style)) }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

// MARK: - 3. Главный экран (Медиатека)
struct ContentView: View {
    @StateObject var manager = MusicManager.shared
    @State private var showFilePicker = false
    @State private var showFullPlayer = false

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationView {
                ZStack {
                    Color.black.ignoresSafeArea()
                    
                    if manager.tracks.isEmpty {
                        VStack {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("Ваша медиатека пуста")
                                .foregroundColor(.gray)
                                .padding()
                        }
                    } else {
                        List {
                            ForEach(manager.tracks.indices, id: \.self) { i in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(manager.tracks[i].lastPathComponent)
                                            .foregroundColor(i == manager.currentTrackIndex ? .red : .white)
                                            .lineLimit(1)
                                        Text("Локальный файл").font(.caption).foregroundColor(.gray)
                                    }
                                    Spacer()
                                    if i == manager.currentTrackIndex && manager.isPlaying {
                                        Image(systemName: "waveform").foregroundColor(.red)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { manager.playTrack(at: i) }
                                .listRowBackground(Color.clear)
                            }
                            .onDelete(perform: manager.deleteTrack)
                        }
                        .listStyle(.plain)
                    }
                }
                .navigationTitle("Музыка")
                .toolbar {
                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "plus.circle.fill").foregroundColor(.red)
                    }
                }
            }
            .preferredColorScheme(.dark)

            // Мини-плеер
            if !manager.tracks.isEmpty {
                MiniPlayer(showFullPlayer: $showFullPlayer)
                    .padding(.bottom, 10)
            }
        }
        .fullScreenCover(isPresented: $showFullPlayer) {
            FullPlayerView()
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { res in
            if case .success(let urls) = res {
                manager.importTracks(from: urls)
            }
        }
    }
}

// MARK: - 4. Мини-плеер
struct MiniPlayer: View {
    @ObservedObject var manager = MusicManager.shared
    @Binding var showFullPlayer: Bool

    var body: some View {
        HStack(spacing: 15) {
            Group {
                if let image = manager.currentArtwork {
                    Image(uiImage: image).resizable()
                } else {
                    Image(systemName: "music.note").foregroundColor(.gray)
                        .background(Color.white.opacity(0.1))
                }
            }
            .frame(width: 45, height: 45)
            .cornerRadius(8)

            Text(manager.tracks.isEmpty ? "" : manager.tracks[manager.currentTrackIndex].lastPathComponent)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            Button(action: manager.playPause) {
                Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            Button(action: manager.nextTrack) {
                Image(systemName: "forward.fill").font(.title2)
            }
        }
        .padding(.horizontal)
        .frame(height: 65)
        .background(BlurView(style: .systemThinMaterialDark))
        .cornerRadius(15)
        .padding(.horizontal, 10)
        .onTapGesture { showFullPlayer = true }
    }
}

// MARK: - 5. Полноэкранный плеер
struct FullPlayerView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject var manager = MusicManager.shared

    var body: some View {
        VStack(spacing: 30) {
            // Индикатор для закрытия (Handle)
            Capsule()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 40, height: 5)
                .padding(.top, 20)
            
            Spacer()

            // MARK: - Обложка трека
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.1))
                    .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                
                if let image = manager.currentArtwork {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 100))
                        .foregroundColor(.red)
                }
            }
            .frame(width: 300, height: 300)
            .cornerRadius(20)
            // Анимация: обложка чуть уменьшается, когда плеер на паузе
            .scaleEffect(manager.isPlaying ? 1.0 : 0.92)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: manager.isPlaying)

            // MARK: - Инфо-блок (Метаданные)
            VStack(spacing: 8) {
                Text(manager.currentTitle)
                    .font(.title2).bold()
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                
                Text(manager.currentArtist)
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                
                if !manager.currentAlbum.isEmpty {
                    Text(manager.currentAlbum)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 40)

            // MARK: - Слайдер времени
            VStack(spacing: 5) {
                Slider(value: Binding(
                    get: { manager.currentTime },
                    set: { manager.seek(to: $0) }
                ), in: 0...max(manager.trackDuration, 1))
                .accentColor(.white)
                
                HStack {
                    Text(manager.currentTime.formatTime())
                    Spacer()
                    Text(manager.trackDuration.formatTime())
                }
                .font(.caption.monospaced())
                .foregroundColor(.gray)
            }
            .padding(.horizontal, 30)

            // MARK: - Кнопки управления
            HStack(spacing: 60) {
                Button(action: manager.prevTrack) {
                    Image(systemName: "backward.fill")
                        .font(.title)
                }
                
                Button(action: manager.playPause) {
                    Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 80))
                }
                
                Button(action: manager.nextTrack) {
                    Image(systemName: "forward.fill")
                        .font(.title)
                }
            }
            .foregroundColor(.white)

            // MARK: - Подпись автора
            Text("by aswer")
                .font(.system(size: 12, weight: .light, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .padding(.top, 10)

            Spacer()
        }
        .padding(.bottom, 20)
        .background(
            // Динамический фон с размытием обложки
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = manager.currentArtwork {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 50)
                        .opacity(0.4)
                        .ignoresSafeArea()
                }
            }
        )
        // Свайп вниз для закрытия
        .gesture(
            DragGesture().onEnded { value in
                if value.translation.height > 100 {
                    dismiss()
                }
            }
        )
    }
}
