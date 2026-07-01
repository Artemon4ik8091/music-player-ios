import SwiftUI

// MARK: - Экран "Сейчас играет" на часах
struct NowPlayingView: View {
    @StateObject private var connectivity = WatchConnectivityManager.shared

    var body: some View {
        VStack(spacing: 10) {
            Text(connectivity.currentTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(connectivity.currentArtist)
                .font(.subheadline)
                .foregroundColor(.gray)
                .lineLimit(1)

            HStack(spacing: 22) {
                Button(action: connectivity.previous) {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }

                Button(action: connectivity.playPause) {
                    Image(systemName: connectivity.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }

                Button(action: connectivity.next) {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding()
        .navigationTitle("Сейчас играет")
    }
}
