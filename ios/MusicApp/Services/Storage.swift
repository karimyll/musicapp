import Foundation

enum Storage {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let musicDir = documents.appending(path: "Music", directoryHint: .isDirectory)
    static let artworkDir = documents.appending(path: "Artwork", directoryHint: .isDirectory)

    static func ensureDirectories() {
        for dir in [musicDir, artworkDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func audioURL(_ name: String) -> URL { musicDir.appending(path: name) }
    static func artworkURL(_ name: String) -> URL { artworkDir.appending(path: name) }

    static func remove(_ track: Track) {
        try? FileManager.default.removeItem(at: track.fileURL)
        if let art = track.artworkURL { try? FileManager.default.removeItem(at: art) }
    }

    static func usedBytes() -> Int64 {
        var total: Int64 = 0
        for dir in [musicDir, artworkDir] {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for f in files {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds.rounded())
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
