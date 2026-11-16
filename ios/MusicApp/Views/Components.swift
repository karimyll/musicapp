import SwiftData
import SwiftUI

struct ArtworkView: View {
    var localURL: URL?
    var remoteURL: String?
    var size: CGFloat
    var cornerRadius: CGFloat

    init(track: Track?, remoteURL: String? = nil, size: CGFloat = 48, cornerRadius: CGFloat = 6) {
        localURL = track?.artworkURL
        self.remoteURL = remoteURL
        self.size = size
        self.cornerRadius = cornerRadius
    }

    init(item: PlayItem?, size: CGFloat = 48, cornerRadius: CGFloat = 6) {
        localURL = item?.localArtwork
        remoteURL = item?.remoteArtwork
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Group {
            if let url = localURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let remoteURL, let url = URL(string: remoteURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4))
                .foregroundStyle(.secondary)
        }
    }
}

struct TrackRow: View {
    let track: Track
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(track: track)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(player.current?.id == track.videoId ? Color.accentColor : .primary)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if track.isFavorite {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            }
            Text(formatDuration(track.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Shared long-press menu for a downloaded track.
struct TrackMenu: View {
    let track: Track
    @Binding var addToPlaylist: Track?
    var removeFromPlaylist: (() -> Void)? = nil
    @Environment(PlayerEngine.self) private var player
    @Environment(\.modelContext) private var context

    var body: some View {
        Button { player.playNext(PlayItem(track: track)) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { addToPlaylist = track } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
        if let removeFromPlaylist {
            Button(role: .destructive, action: removeFromPlaylist) { Label("Remove from Playlist", systemImage: "minus.circle") }
        }
        Button(role: .destructive) { deleteTrack(track, player: player, context: context) } label: {
            Label("Delete from Phone", systemImage: "trash")
        }
    }
}
