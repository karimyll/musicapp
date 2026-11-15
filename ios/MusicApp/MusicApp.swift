import SwiftData
import SwiftUI

@main
struct MusicApp: App {
    @State private var settings = AppSettings()
    @State private var player = PlayerEngine()
    @State private var downloads = DownloadManager()

    init() {
        Storage.ensureDirectories()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(player)
                .environment(downloads)
                .tint(.pink)
        }
        .modelContainer(for: [Track.self, Playlist.self, PlaylistItem.self])
    }
}
