import SwiftData
import SwiftUI

enum AppTab: Hashable {
    case library, playlists, settings, search
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var player
    @State private var tab: AppTab = .library
    @State private var showNowPlaying = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("Library", systemImage: "music.note.list", value: .library) {
                LibraryView()
            }
            Tab("Playlists", systemImage: "rectangle.stack", value: .playlists) {
                PlaylistsView()
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView()
            }
            // Liquid Glass: the search tab sits apart on the right of the tab bar.
            Tab(value: .search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            MiniPlayerView { showNowPlaying = true }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
        .onAppear {
            tab = settings.isConfigured ? .search : .settings
            player.api = settings.api
        }
        // The player needs the server to stream songs that aren't downloaded.
        .onChange(of: settings.serverURL) { player.api = settings.api }
        .onChange(of: settings.token) { player.api = settings.api }
        .overlay(alignment: .top) {
            if let message = player.lastError {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation { player.lastError = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.4), value: player.lastError)
    }
}

/// Deletes a track everywhere: player queue, files, database.
@MainActor
func deleteTrack(_ track: Track, player: PlayerEngine, context: ModelContext) {
    player.remove(track.videoId)
    Storage.remove(track)
    context.delete(track)
    try? context.save()
}
