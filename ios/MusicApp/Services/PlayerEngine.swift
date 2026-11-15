import AVFoundation
import MediaPlayer
import Observation
import UIKit

@Observable
@MainActor
final class PlayerEngine {
    enum RepeatMode { case off, all, one }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    var repeatMode: RepeatMode = .off
    var currentTime: Double = 0
    var isScrubbing = false

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    /// Tracks after the current one.
    var upNext: [Track] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    func jumpToUpNext(_ offset: Int) {
        let target = index + 1 + offset
        guard queue.indices.contains(target) else { return }
        index = target
        load(autoplay: true)
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        var rest = upNext
        rest.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + rest
    }

    func removeUpNext(_ offset: Int) {
        let target = index + 1 + offset
        guard queue.indices.contains(target) else { return }
        queue.remove(at: target)
    }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        setupRemoteCommands()
        observeSystem()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    // MARK: - Public controls

    func play(_ tracks: [Track], startAt start: Int = 0, shuffled: Bool = false) {
        let playable = tracks.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        guard !playable.isEmpty else { return }
        let startTrack = tracks.indices.contains(start) ? tracks[start] : playable[0]
        originalQueue = playable
        shuffle = shuffled
        if shuffled {
            queue = playable.shuffled()
            index = 0
        } else {
            queue = playable
            index = playable.firstIndex { $0.videoId == startTrack.videoId } ?? 0
        }
        load(autoplay: true)
    }

    func playNext(_ track: Track) {
        guard current != nil else { return play([track]) }
        queue.removeAll { $0.videoId == track.videoId && $0.videoId != current?.videoId }
        queue.insert(track, at: min(index + 1, queue.count))
        if !originalQueue.contains(where: { $0.videoId == track.videoId }) { originalQueue.append(track) }
    }

    func togglePlayPause() {
        guard current != nil else { return }
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            return
        }
        load(autoplay: true)
    }

    func previous() {
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load(autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func toggleShuffle() {
        guard let cur = current else { shuffle.toggle(); return }
        shuffle.toggle()
        if shuffle {
            var rest = queue
            rest.remove(at: index)
            queue = [cur] + rest.shuffled()
            index = 0
        } else {
            queue = originalQueue
            index = queue.firstIndex { $0.videoId == cur.videoId } ?? 0
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Must be called before a Track is deleted from SwiftData.
    func remove(_ track: Track) {
        let wasCurrent = current?.videoId == track.videoId
        originalQueue.removeAll { $0.videoId == track.videoId }
        if let i = queue.firstIndex(where: { $0.videoId == track.videoId }) {
            queue.remove(at: i)
            if i < index { index -= 1 }
        }
        guard wasCurrent else { return }
        if queue.isEmpty {
            stop()
        } else {
            index = min(index, queue.count - 1)
            load(autoplay: isPlaying)
        }
    }

    func stop() {
        player.replaceCurrentItem(with: nil)
        queue = []
        originalQueue = []
        index = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Internals

    private func load(autoplay: Bool) {
        guard let track = current else { return }
        let item = AVPlayerItem(url: track.fileURL)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = track.duration
        guard track.duration <= 0 else {
            if autoplay { resume() } else { updateNowPlaying() }
            return
        }
        Task { [weak self] in
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
                self?.duration = d.seconds
                self?.updateNowPlaying()
            }
        }
        if autoplay { resume() } else { updateNowPlaying() }
    }

    private func trackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else if index + 1 < queue.count || repeatMode == .all {
            next()
        } else {
            pause()
            seek(to: 0)
        }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.trackEnded()
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.isPlaying = false
                    self.updateNowPlaying()
                case .ended:
                    let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
                    if opts.contains(.shouldResume) { self.resume() }
                @unknown default: break
                }
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // Headphones unplugged -> pause, like every music app.
                guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                self?.pause()
            }
        })
    }

    private func setupRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        rc.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        rc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        rc.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        rc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let url = track.artworkURL, let image = UIImage(contentsOfFile: url.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
