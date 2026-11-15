import AVFoundation
import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class DownloadManager {
    /// videoId -> progress 0...1 (0 while the server is still fetching from YouTube).
    private(set) var active: [String: Double] = [:]
    /// videoId -> last error message.
    var errors: [String: String] = [:]

    func isDownloading(_ id: String) -> Bool { active[id] != nil }

    func download(_ result: SearchResult, api: APIClient, context: ModelContext) {
        guard active[result.id] == nil else { return }
        active[result.id] = 0
        errors[result.id] = nil

        // DownloadManager lives for the whole app, so strong captures are fine here.
        Task {
            do {
                let delegate = ProgressDelegate { fraction in
                    Task { @MainActor in
                        if self.active[result.id] != nil { self.active[result.id] = fraction }
                    }
                }
                let (tmp, resp) = try await URLSession.shared.download(for: api.audioRequest(id: result.id), delegate: delegate)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    let body = try? Data(contentsOf: tmp)
                    try APIClient.check(resp, data: body)
                    throw APIError(message: "Download failed")
                }

                let fileName = "\(result.id).m4a"
                let dest = Storage.audioURL(fileName)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)

                let artworkName = await Self.saveArtwork(result)
                // YouTube Music's duration is exact; the file header can be off for unfixed DASH m4a.
                var duration = result.duration ?? 0
                if duration <= 0 { duration = await Self.realDuration(dest) ?? 0 }

                let id = result.id
                let existing = try context.fetch(FetchDescriptor<Track>(predicate: #Predicate { $0.videoId == id }))
                if let track = existing.first {
                    track.fileName = fileName
                    track.artworkFileName = artworkName
                } else {
                    context.insert(Track(
                        videoId: result.id,
                        title: result.title,
                        artist: result.artist,
                        album: result.album,
                        duration: duration,
                        fileName: fileName,
                        artworkFileName: artworkName
                    ))
                }
                try context.save()
                active[result.id] = nil
            } catch {
                active[result.id] = nil
                errors[result.id] = error.localizedDescription
            }
        }
    }

    private static func saveArtwork(_ result: SearchResult) async -> String? {
        guard let s = result.thumbnail, let url = URL(string: s),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let name = "\(result.id).jpg"
        do {
            try data.write(to: Storage.artworkURL(name))
            return name
        } catch {
            return nil
        }
    }

    private static func realDuration(_ url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let s = d.seconds
        return s.isFinite && s > 0 ? s : nil
    }
}

/// Reports task progress through KVO on `URLSessionTask.progress`.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] progress, _ in
            onProgress(progress.fractionCompleted)
        }
    }
}
