import SwiftData
import SwiftUI

struct PlaylistsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]

    @State private var showCreate = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(playlists) { playlist in
                    NavigationLink(value: playlist) {
                        PlaylistRow(playlist: playlist)
                    }
                    .contextMenu {
                        Button { renameText = playlist.name; renaming = playlist } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) { delete(playlist) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { offsets in offsets.map { playlists[$0] }.forEach(delete) }
            }
            .overlay {
                if playlists.isEmpty {
                    ContentUnavailableView("No Playlists", systemImage: "rectangle.stack",
                                           description: Text("Tap + to create a playlist."))
                }
            }
            .navigationTitle("Playlists")
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .toolbar {
                Button { newName = ""; showCreate = true } label: { Image(systemName: "plus") }
            }
            .alert("New Playlist", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
            } message: {
                Text("Enter a name for this playlist.")
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { renaming?.name = name; try? context.save() }
                    renaming = nil
                }
            }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        context.insert(Playlist(name: name))
        try? context.save()
    }

    private func delete(_ playlist: Playlist) {
        context.delete(playlist)
        try? context.save()
    }
}

struct PlaylistRow: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            PlaylistCover(playlist: playlist, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).lineLimit(1)
                Text("\(playlist.tracks.count) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 2x2 mosaic of the first covers, like the big apps.
struct PlaylistCover: View {
    let playlist: Playlist
    var size: CGFloat

    var body: some View {
        let tracks = Array(playlist.tracks.prefix(4))
        Group {
            if tracks.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(track: tracks[0], size: half, cornerRadius: 0)
                        ArtworkView(track: tracks[1], size: half, cornerRadius: 0)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(track: tracks[2], size: half, cornerRadius: 0)
                        ArtworkView(track: tracks[3], size: half, cornerRadius: 0)
                    }
                }
            } else {
                ArtworkView(track: tracks.first, size: size, cornerRadius: 0)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
    }
}

struct PlaylistDetailView: View {
    @Bindable var playlist: Playlist
    @Environment(PlayerEngine.self) private var player
    @Environment(\.modelContext) private var context
    @State private var showAdd = false
    @State private var addToPlaylist: Track?

    var body: some View {
        let items = playlist.orderedItems
        let tracks = items.compactMap(\.track)
        List {
            VStack(spacing: 12) {
                PlaylistCover(playlist: playlist, size: 200)
                Text(playlist.name).font(.title2.bold())
                Text("\(tracks.count) songs · \(formatDuration(tracks.reduce(0) { $0 + $1.duration }))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)

            PlayShuffleButtons(tracks: tracks)

            ForEach(Array(items.enumerated()), id: \.element.persistentModelID) { i, item in
                if let track = item.track {
                    TrackRow(track: track)
                        .onTapGesture { player.play(tracks, startAt: i) }
                        .contextMenu {
                            TrackMenu(track: track, addToPlaylist: $addToPlaylist) { remove(item) }
                        }
                }
            }
            .onMove { from, to in move(items, from: from, to: to) }
            .onDelete { offsets in offsets.map { items[$0] }.forEach(remove) }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                EditButton()
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) { PickTracksSheet(playlist: playlist) }
        .sheet(item: $addToPlaylist) { AddToPlaylistSheet(track: $0) }
    }

    private func move(_ items: [PlaylistItem], from: IndexSet, to: Int) {
        var reordered = items
        reordered.move(fromOffsets: from, toOffset: to)
        for (i, item) in reordered.enumerated() { item.order = i }
        try? context.save()
    }

    private func remove(_ item: PlaylistItem) {
        playlist.items.removeAll { $0.persistentModelID == item.persistentModelID }
        context.delete(item)
        try? context.save()
    }
}

/// Multi-select library tracks to add into a playlist.
struct PickTracksSheet: View {
    let playlist: Playlist
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Track.addedAt, order: .reverse) private var tracks: [Track]
    @State private var selected = Set<String>()
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            let available = tracks.filter { !playlist.contains($0) }
                .filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.artist.localizedCaseInsensitiveContains(filter) }
            List(available, id: \.videoId) { track in
                HStack {
                    TrackRow(track: track)
                    Image(systemName: selected.contains(track.videoId) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(track.videoId) ? Color.accentColor : .secondary)
                        .font(.title3)
                }
                .onTapGesture {
                    if selected.contains(track.videoId) { selected.remove(track.videoId) } else { selected.insert(track.videoId) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if available.isEmpty && filter.isEmpty {
                    ContentUnavailableView("No songs to add", systemImage: "music.note")
                }
            }
            .searchable(text: $filter)
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selected.count))") {
                        // Keep library order (newest first) for the added batch.
                        for track in tracks where selected.contains(track.videoId) { playlist.append(track) }
                        try? context.save()
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }
}

/// Choose (or create) a playlist for one track.
struct AddToPlaylistSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New playlist name", text: $newName)
                        Button("Create") {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            let p = Playlist(name: name)
                            context.insert(p)
                            p.append(track)
                            try? context.save()
                            dismiss()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Your Playlists") {
                    ForEach(playlists) { p in
                        Button {
                            if !p.contains(track) { p.append(track); try? context.save() }
                            dismiss()
                        } label: {
                            HStack {
                                PlaylistRow(playlist: p)
                                Spacer()
                                if p.contains(track) { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
