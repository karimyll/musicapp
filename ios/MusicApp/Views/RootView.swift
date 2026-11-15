import SwiftData
import SwiftUI

enum AppTab: Hashable {
    case library, playlists, settings, search
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
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
        }
    }
}

/// Deletes a track everywhere: player queue, files, database.
@MainActor
func deleteTrack(_ track: Track, player: PlayerEngine, context: ModelContext) {
    player.remove(track)
    Storage.remove(track)
    context.delete(track)
    try? context.save()
}
