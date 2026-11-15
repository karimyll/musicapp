import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var videoId: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double
    /// File names relative to the Music / Artwork folders (the app container path can change between installs).
    var fileName: String
    var artworkFileName: String?
    var addedAt: Date
    var isFavorite: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \PlaylistItem.track)
    var playlistItems: [PlaylistItem] = []

    init(videoId: String, title: String, artist: String, album: String?, duration: Double, fileName: String, artworkFileName: String?) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.fileName = fileName
        self.artworkFileName = artworkFileName
        self.addedAt = .now
    }

    var fileURL: URL { Storage.audioURL(fileName) }
    var artworkURL: URL? { artworkFileName.map(Storage.artworkURL) }
}

@Model
final class Playlist {
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \PlaylistItem.playlist)
    var items: [PlaylistItem] = []

    init(name: String) {
        self.name = name
        self.createdAt = .now
    }

    var orderedItems: [PlaylistItem] {
        items.filter { $0.track != nil }.sorted { $0.order < $1.order }
    }

    var tracks: [Track] { orderedItems.compactMap(\.track) }

    func append(_ track: Track) {
        let next = (items.map(\.order).max() ?? -1) + 1
        let item = PlaylistItem(order: next)
        item.track = track
        items.append(item)
    }

    func contains(_ track: Track) -> Bool {
        items.contains { $0.track?.videoId == track.videoId }
    }
}

@Model
final class PlaylistItem {
    var order: Int
    var track: Track?
    var playlist: Playlist?

    init(order: Int) {
        self.order = order
    }
}
