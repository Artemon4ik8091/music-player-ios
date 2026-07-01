//
//  ContentView.swift
//  music playerWatch Watch App
//
//  Created by aswer on 30.06.2026.
//

import SwiftUI

// MARK: - Главный экран часов
// Замени этим содержимым ContentView.swift, который Xcode сгенерировал
// в таргете часов (структура должна остаться по имени ContentView,
// чтобы App.swift на часах продолжил работать без изменений).
struct ContentView: View {
    @StateObject private var connectivity = WatchConnectivityManager.shared

    var body: some View {
        NavigationView {
            List {
                if !connectivity.currentTitle.isEmpty {
                    NavigationLink(destination: NowPlayingView()) {
                        HStack {
                            Image(systemName: connectivity.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading) {
                                Text(connectivity.currentTitle)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(connectivity.currentArtist)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                if connectivity.tracks.isEmpty {
                    Text("Открой приложение на iPhone, чтобы список треков появился здесь")
                        .font(.caption2)
                        .foregroundColor(.gray)
                } else {
                    ForEach(connectivity.tracks) { track in
                        Button(action: { connectivity.playTrack(id: track.id) }) {
                            VStack(alignment: .leading) {
                                Text(track.title)
                                    .font(.body)
                                    .foregroundColor(track.id == connectivity.currentId ? .green : .primary)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Музыка")
        }
    }
}
