import AVFoundation
import MediaPlayer
import Observation
import UIKit

@Observable
@MainActor
final class PlayerEngine {
    enum RepeatMode { case off, all, one }
    enum SleepTimer: Equatable { case off, at(Date), endOfTrack }

    private(set) var queue: [PlayItem] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    private(set) var sleepTimer: SleepTimer = .off
    var repeatMode: RepeatMode = .off
    var currentTime: Double = 0
    var isScrubbing = false
    /// Short message for the UI ("Couldn't play …"); cleared by the UI.
    var lastError: String?

    /// Play similar songs when the queue runs out (YouTube Music radio).
    var autoplay: Bool = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoplay, forKey: "autoplay")
            if autoplay { extendWithRadioIfNeeded() }
        }
    }

    /// Crossfade between songs in seconds; 0 = off.
    var crossfade: Double = UserDefaults.standard.double(forKey: "crossfade") {
        didSet { UserDefaults.standard.set(crossfade, forKey: "crossfade") }
    }

    /// Set by the app from Settings; needed to stream songs that aren't downloaded.
    @ObservationIgnored var api: APIClient?

    var current: PlayItem? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [PlayItem] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    // Two players so one song can fade out while the next fades in.
    @ObservationIgnored private let players = [AVPlayer(), AVPlayer()]
    @ObservationIgnored private var active = 0
    private var player: AVPlayer { players[active] }
    private var standby: AVPlayer { players[1 - active] }

    @ObservationIgnored private var originalQueue: [PlayItem] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var kvo: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemStatusKVO: NSKeyValueObservation?
    @ObservationIgnored private var fadeTimer: Timer?
    @ObservationIgnored private var fadeStep = 0
    @ObservationIgnored private var fading = false
    @ObservationIgnored private var radioLoading = false
    @ObservationIgnored private var waitingForRadio = false
    @ObservationIgnored private var radioSeeds: Set<String> = []
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var artworkCache: [String: UIImage] = [:]

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        setupRemoteCommands()
        observeSystem()
        for p in players {
            p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self, weak p] time in
                MainActor.assumeIsolated {
                    guard let self, let p, p === self.player, !self.isScrubbing else { return }
                    self.currentTime = time.seconds.isFinite ? time.seconds : 0
                    self.checkCrossfade()
                }
            }
            kvo.append(p.observe(\.timeControlStatus) { [weak self] p, _ in
                let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                Task { @MainActor in
                    guard let self, p === self.player else { return }
                    self.isBuffering = waiting
                }
            })
        }
    }

    // MARK: - Starting playback

    func play(_ items: [PlayItem], startAt start: Int = 0, shuffled: Bool = false) {
        guard !items.isEmpty else { return }
        let startItem = items.indices.contains(start) ? items[start] : items[0]
        originalQueue = items
        shuffle = shuffled
        radioSeeds = []
        if shuffled {
            queue = items.shuffled()
            index = 0
        } else {
            queue = items
            index = items.firstIndex { $0.id == startItem.id } ?? 0
        }
        load(autoplay: true)
    }

    func play(_ tracks: [Track], startAt start: Int = 0, shuffled: Bool = false) {
        play(tracks.map(PlayItem.init(track:)), startAt: start, shuffled: shuffled)
    }

    func playNext(_ item: PlayItem) {
        guard current != nil else { return play([item]) }
        if let i = queue.firstIndex(where: { $0.id == item.id }), i > index {
            queue.remove(at: i)
        }
        guard current?.id != item.id else { return }
        var item = item
        item.fromRadio = false
        queue.insert(item, at: min(index + 1, queue.count))
        if !originalQueue.contains(where: { $0.id == item.id }) { originalQueue.append(item) }
    }

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

    // MARK: - Controls

    func togglePlayPause() {
        guard current != nil else { return }
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if player.currentItem == nil { load(autoplay: true); return }
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        finishFadeNow()
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        guard let n = nextIndex(userInitiated: true) else { return }
        index = n
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
        finishFadeNow()
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func toggleShuffle() {
        guard let cur = current else { shuffle.toggle(); return }
        shuffle.toggle()
        let radio = queue.filter(\.fromRadio)
        if shuffle {
            var rest = queue.filter { !$0.fromRadio }
            rest.removeAll { $0.id == cur.id }
            queue = [cur] + rest.shuffled() + radio.filter { $0.id != cur.id }
            index = 0
        } else {
            let base = originalQueue.filter { !$0.fromRadio }
            queue = base + radio.filter { r in !base.contains { $0.id == r.id } }
            index = queue.firstIndex { $0.id == cur.id } ?? 0
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Call before a downloaded Track is deleted.
    func remove(_ id: String) {
        let wasCurrent = current?.id == id
        originalQueue.removeAll { $0.id == id }
        guard !wasCurrent else { return }  // keeps playing (streams if the file is gone)
        if let i = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: i)
            if i < index { index -= 1 }
        }
    }

    func stop() {
        finishFadeNow()
        players.forEach { $0.pause(); $0.replaceCurrentItem(with: nil) }
        queue = []
        originalQueue = []
        index = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        setSleepTimer(.off)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Sleep timer

    func setSleepTimer(_ timer: SleepTimer) {
        sleepTask?.cancel()
        sleepTimer = timer
        guard case let .at(date) = timer else { return }
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.fadeOutAndPause()
        }
    }

    func sleep(minutes: Int) { setSleepTimer(.at(.now.addingTimeInterval(Double(minutes) * 60))) }

    private func fadeOutAndPause() async {
        sleepTimer = .off
        let p = player
        for step in 0..<30 {
            p.volume = 1 - Float(step) / 30
            try? await Task.sleep(for: .milliseconds(100))
        }
        pause()
        p.volume = 1
    }

    // MARK: - Loading

    private func makeItem(_ item: PlayItem) -> AVPlayerItem? {
        if let file = item.localFile { return AVPlayerItem(url: file) }
        guard let api else {
            lastError = "Set your server in Settings to stream songs."
            return nil
        }
        let asset = AVURLAsset(url: api.audioURL(id: item.id), options: ["AVURLAssetHTTPHeaderFieldsKey": api.authHeaders])
        return AVPlayerItem(asset: asset)
    }

    private func load(autoplay: Bool) {
        finishFadeNow()
        guard let item = current else { return }
        guard let avItem = makeItem(item) else { pause(); return }
        standby.replaceCurrentItem(with: nil)
        player.volume = 1
        player.replaceCurrentItem(with: avItem)
        watch(avItem, for: item)
        currentTime = 0
        duration = item.duration
        if autoplay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
        }
        updateNowPlaying()
        extendWithRadioIfNeeded()
    }

    /// Duration from the file when we don't know it, and skip songs that fail to load.
    private func watch(_ avItem: AVPlayerItem, for item: PlayItem) {
        itemStatusKVO = avItem.observe(\.status) { [weak self] avItem, _ in
            let failed = avItem.status == .failed
            let message = (avItem.error as NSError?)?.localizedDescription
            Task { @MainActor in
                guard let self, failed, self.current?.id == item.id else { return }
                self.lastError = "Couldn't play “\(item.title)”" + (message.map { ": \($0)" } ?? "")
                if self.nextIndex(userInitiated: false) != nil { self.next() } else { self.pause() }
            }
        }
        guard item.duration <= 0 else { return }
        Task { [weak self] in
            if let d = try? await avItem.asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
                guard let self, self.current?.id == item.id else { return }
                self.duration = d.seconds
                self.updateNowPlaying()
            }
        }
    }

    private func nextIndex(userInitiated: Bool) -> Int? {
        guard !queue.isEmpty else { return nil }
        if index + 1 < queue.count { return index + 1 }
        if repeatMode == .all || (userInitiated && repeatMode == .one) { return 0 }
        return nil
    }

    private func trackEnded() {
        if sleepTimer == .endOfTrack {
            setSleepTimer(.off)
            if let n = nextIndex(userInitiated: false) {
                index = n
                load(autoplay: false)
            }
            pause()
            return
        }
        if repeatMode == .one {
            seek(to: 0)
            resume()
        } else if let n = nextIndex(userInitiated: false) {
            index = n
            load(autoplay: true)
        } else if autoplay && radioLoading {
            waitingForRadio = true
        } else {
            pause()
            seek(to: 0)
        }
    }

    // MARK: - Autoplay (radio)

    private func extendWithRadioIfNeeded() {
        guard autoplay, repeatMode == .off, let api, let seed = current,
              index >= queue.count - 2, !radioLoading, !radioSeeds.contains(seed.id) else { return }
        radioLoading = true
        radioSeeds.insert(seed.id)
        Task { [weak self] in
            let results = try? await api.radio(seed.id)
            guard let self else { return }
            self.radioLoading = false
            guard let results, !results.isEmpty else { self.waitingForRadio = false; return }
            let existing = Set(self.queue.map(\.id))
            let more = results.filter { !existing.contains($0.id) }.map { PlayItem(result: $0, fromRadio: true) }
            self.queue.append(contentsOf: more)
            self.originalQueue.append(contentsOf: more)
            // The last song ended while radio was still loading: carry on.
            if self.waitingForRadio, self.index + 1 < self.queue.count {
                self.waitingForRadio = false
                self.index += 1
                self.load(autoplay: true)
            }
        }
    }

    // MARK: - Crossfade

    private func checkCrossfade() {
        guard crossfade > 0, !fading, isPlaying, repeatMode != .one, sleepTimer != .endOfTrack,
              duration > crossfade * 2, currentTime >= duration - crossfade,
              let n = nextIndex(userInitiated: false), let avItem = makeItem(queue[n]) else { return }
        fading = true
        let outgoing = player
        let incoming = standby
        incoming.replaceCurrentItem(with: avItem)
        incoming.volume = 0
        incoming.play()
        active = 1 - active
        index = n
        currentTime = 0
        duration = queue[n].duration
        watch(avItem, for: queue[n])
        updateNowPlaying()
        extendWithRadioIfNeeded()

        let steps = max(1, Int(crossfade * 20))
        fadeStep = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fadeStep += 1
                let f = min(1, Float(self.fadeStep) / Float(steps))
                incoming.volume = f
                outgoing.volume = 1 - f
                if self.fadeStep >= steps { self.finishFadeNow() }
            }
        }
    }

    /// Ends a running crossfade immediately: the new song keeps playing at full volume.
    private func finishFadeNow() {
        guard fading else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        fading = false
        standby.pause()
        standby.replaceCurrentItem(with: nil)
        standby.volume = 1
        player.volume = 1
    }

    // MARK: - System integration

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
        guard let item = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let image = artwork(for: item) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Cover for the lock screen: local file, or downloaded once from the web and cached.
    private func artwork(for item: PlayItem) -> UIImage? {
        if let cached = artworkCache[item.id] { return cached }
        if let url = item.localArtwork, let image = UIImage(contentsOfFile: url.path) {
            artworkCache[item.id] = image
            return image
        }
        if let s = item.remoteArtwork, let url = URL(string: s) {
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
                self?.artworkCache[item.id] = image
                if self?.current?.id == item.id { self?.updateNowPlaying() }
            }
        }
        return nil
    }
}
