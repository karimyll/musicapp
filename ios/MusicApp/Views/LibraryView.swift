import SwiftData
import SwiftUI

struct LibraryView: View {
    enum Filter: String, CaseIterable { case all = "All", favorites = "Favorites" }

    @Environment(PlayerEngine.self) private var player
    @Environment(\.modelContext) private var context
    @Query(sort: \Track.addedAt, order: .reverse) private var tracks: [Track]

    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var addToPlaylist: Track?

    private var filtered: [Track] {
        var list = filter == .favorites ? tracks.filter(\.isFavorite) : tracks
        let f = search.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(f) || $0.artist.localizedCaseInsensitiveContains(f) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            let list = filtered
            List {
                if !tracks.isEmpty {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    PlayShuffleButtons(tracks: list)
                }
                ForEach(Array(list.enumerated()), id: \.element.videoId) { i, track in
                    TrackRow(track: track)
                        .onTapGesture { player.play(list, startAt: i) }
                        .contextMenu { TrackMenu(track: track, addToPlaylist: $addToPlaylist) }
                        .swipeActions {
                            Button(role: .destructive) { deleteTrack(track, player: player, context: context) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { addToPlaylist = track } label: {
                                Label("Playlist", systemImage: "text.badge.plus")
                            }
                            .tint(.indigo)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                track.isFavorite.toggle()
                                try? context.save()
                            } label: {
                                Label("Favorite", systemImage: track.isFavorite ? "star.slash" : "star.fill")
                            }
                            .tint(.yellow)
                        }
                }
            }
            .listStyle(.plain)
            .overlay {
                if tracks.isEmpty {
                    ContentUnavailableView("No Music Yet", systemImage: "music.note",
                                           description: Text("Search and download songs — they stay here offline."))
                } else if list.isEmpty && filter == .favorites && search.isEmpty {
                    ContentUnavailableView("No Favorites", systemImage: "star",
                                           description: Text("Tap the star in the player to add favorites."))
                }
            }
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Search your library")
            .sheet(item: $addToPlaylist) { track in
                AddToPlaylistSheet(track: track)
            }
        }
    }
}

struct PlayShuffleButtons: View {
    let tracks: [Track]
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            // Icon and text laid out explicitly: .glassProminent hides a Label's icon.
            Button { player.play(tracks) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Play")
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            Button { player.play(tracks, shuffled: true) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
        .disabled(tracks.isEmpty)
        .listRowSeparator(.hidden)
    }
}
