import Foundation

/// Anything the player can play: a downloaded Track (local file) or a search / album / radio
/// result that is streamed from the server. Downloaded files are always "<videoId>.m4a", so an
/// item becomes local as soon as its download finishes — even while it sits in the queue.
struct PlayItem: Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double
    var remoteArtwork: String?
    /// Added by Autoplay (similar songs), not chosen by the user.
    var fromRadio = false

    init(track: Track) {
        id = track.videoId
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration
    }

    init(result: SearchResult, fromRadio: Bool = false) {
        id = result.id
        title = result.title
        artist = result.artist
        album = result.album
        duration = result.duration ?? 0
        remoteArtwork = result.thumbnail
        self.fromRadio = fromRadio
    }

    var localFile: URL? {
        let url = Storage.audioURL("\(id).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var localArtwork: URL? {
        let url = Storage.artworkURL("\(id).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var isDownloaded: Bool { localFile != nil }

    var searchResult: SearchResult {
        SearchResult(id: id, title: title, artist: artist, album: album,
                     duration: duration > 0 ? duration : nil, thumbnail: remoteArtwork)
    }
}
