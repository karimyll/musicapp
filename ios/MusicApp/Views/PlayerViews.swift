import AVKit
import MediaPlayer
import SwiftData
import SwiftUI

// MARK: - Mini player (tab bar bottom accessory)

/// Lives in the tab bar's bottom accessory, so the system draws the Liquid Glass capsule around it.
struct MiniPlayerView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(item: player.current, size: 32, cornerRadius: 8)
                .id(player.current?.id)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let artist = player.current?.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
            }
            .disabled(player.current == nil)
            // When the tab bar is minimized the accessory shrinks inline: keep only play/pause.
            if placement != .inline {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .disabled(player.current == nil)
            }
        }
        .tint(.primary)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { if player.current != nil { onOpen() } }
    }
}

// MARK: - Now Playing (Apple Music style)

struct NowPlayingView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var tracks: [Track]
    @Namespace private var ns
    @State private var showQueue = false
    @State private var addToPlaylist: Track?

    /// The downloaded Track for the current song, if it's on the phone.
    private func downloaded(_ item: PlayItem) -> Track? { tracks.first { $0.videoId == item.id } }

    var body: some View {
        ZStack {
            NowPlayingBackground(item: player.current)
            if let item = player.current {
                VStack(spacing: 0) {
                    if showQueue {
                        compactHeader(item)
                            .padding(.top, 28)
                        QueueSection()
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        Spacer(minLength: 20)
                        ArtworkView(item: item, size: 330, cornerRadius: 14)
                            .id(item.id)
                            .matchedGeometryEffect(id: "art", in: ns)
                            .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
                            .scaleEffect(player.isPlaying ? 1 : 0.84)
                            .animation(.spring(duration: 0.5, bounce: 0.3), value: player.isPlaying)
                        Spacer(minLength: 20)
                        titleRow(item)
                    }
                    Scrubber()
                        .padding(.top, 18)
                    TransportControls()
                        .padding(.vertical, 22)
                    VolumeRow()
                    bottomBar
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 28)
                .foregroundStyle(.white)
                .tint(.white)
            }
        }
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .sheet(item: $addToPlaylist) { AddToPlaylistSheet(track: $0) }
        .onChange(of: player.current == nil) { _, isEmpty in if isEmpty { dismiss() } }
    }

    private func titleRow(_ item: PlayItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
            keepButton(item)
            moreMenu(item)
        }
    }

    private func compactHeader(_ item: PlayItem) -> some View {
        HStack(spacing: 14) {
            ArtworkView(item: item, size: 64, cornerRadius: 8)
                .id(item.id)
                .matchedGeometryEffect(id: "art", in: ns)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.artist).font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            keepButton(item)
            moreMenu(item)
        }
    }

    /// Star for downloaded songs; for streamed songs a download button (with progress).
    @ViewBuilder
    private func keepButton(_ item: PlayItem) -> some View {
        if let track = downloaded(item) {
            Button {
                track.isFavorite.toggle()
                try? context.save()
            } label: {
                Image(systemName: track.isFavorite ? "star.fill" : "star")
                    .font(.body.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .sensoryFeedback(.selection, trigger: track.isFavorite)
        } else if let p = downloads.active[item.id] {
            ZStack {
                Circle().fill(.white.opacity(0.14))
                if p > 0 {
                    Circle().trim(from: 0, to: p)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(6)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .frame(width: 34, height: 34)
        } else {
            Button { download(item) } label: {
                Image(systemName: "arrow.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())
            }
        }
    }

    private func download(_ item: PlayItem) {
        guard let api = settings.api else { return }
        downloads.download(item.searchResult, api: api, context: context)
    }

    private func moreMenu(_ item: PlayItem) -> some View {
        Menu {
            if let track = downloaded(item) {
                Button { addToPlaylist = track } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
                Button(role: .destructive) {
                    deleteTrack(track, player: player, context: context)
                } label: { Label("Delete from Phone", systemImage: "trash") }
            } else {
                Button { download(item) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .disabled(downloads.isDownloading(item.id))
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.14), in: Circle())
        }
    }

    private var bottomBar: some View {
        HStack {
            Color.clear.frame(width: 44, height: 44)
            Spacer()
            AirPlayButton()
                .frame(width: 44, height: 44)
            Spacer()
            Button {
                withAnimation(.spring(duration: 0.45, bounce: 0.15)) { showQueue.toggle() }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(showQueue ? Color.black.opacity(0.75) : .white.opacity(0.75))
                    .frame(width: 44, height: 44)
                    .background(showQueue ? Color.white.opacity(0.85) : .clear, in: Circle())
            }
        }
    }
}

/// Blurred, saturated cover as a colorful gradient, like Apple Music.
private struct NowPlayingBackground: View {
    let item: PlayItem?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                ArtworkView(item: item, size: max(geo.size.width, geo.size.height), cornerRadius: 0)
                    .id(item?.id)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 90)
                    .saturation(1.7)
                    .scaleEffect(1.5)
                    .opacity(0.95)
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.35), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: item?.id)
    }
}

// MARK: - Queue

private struct QueueSection: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PillToggle(systemImage: "shuffle", isOn: player.shuffle) { player.toggleShuffle() }
                PillToggle(systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                           isOn: player.repeatMode != .off) { player.cycleRepeat() }
                // Autoplay: keep going with similar songs when the queue ends.
                PillToggle(systemImage: "infinity", isOn: player.autoplay) { player.autoplay.toggle() }
            }
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 0) {
                Text("Playing Next").font(.headline)
                Text("\(player.upNext.count) songs").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 6)

            let upNext = player.upNext
            List {
                ForEach(Array(upNext.enumerated()), id: \.offset) { i, track in
                    HStack(spacing: 12) {
                        ArtworkView(item: track, size: 44, cornerRadius: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title).font(.subheadline).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { player.jumpToUpNext(i) }
                    .contextMenu {
                        Button(role: .destructive) { player.removeUpNext(i) } label: {
                            Label("Remove from Queue", systemImage: "minus.circle")
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
                }
                .onMove { player.moveUpNext(from: $0, to: $1) }
                .deleteDisabled(true)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .overlay {
                if upNext.isEmpty {
                    Text("Nothing up next").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct PillToggle: View {
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(isOn ? Color.black.opacity(0.75) : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(isOn ? Color.white.opacity(0.85) : .white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

// MARK: - Controls

private struct Scrubber: View {
    @Environment(PlayerEngine.self) private var player
    @State private var dragValue: Double?

    var body: some View {
        let duration = max(player.duration, 1)
        let value = dragValue ?? player.currentTime
        VStack(spacing: 8) {
            GeometryReader { geo in
                let fraction = min(max(value / duration, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule()
                        .fill(.white.opacity(dragValue == nil ? 0.7 : 1))
                        .frame(width: geo.size.width * fraction)
                }
                .frame(height: dragValue == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            player.isScrubbing = true
                            dragValue = min(max(g.location.x / geo.size.width, 0), 1) * duration
                        }
                        .onEnded { _ in
                            if let v = dragValue { player.seek(to: v) }
                            player.isScrubbing = false
                            dragValue = nil
                        }
                )
                .animation(.spring(duration: 0.25), value: dragValue == nil)
            }
            .frame(height: 16)

            HStack {
                Text(formatDuration(value))
                Spacer()
                Text("-" + formatDuration(max(duration - value, 0)))
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

private struct TransportControls: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack {
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 34))
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Group {
                    if player.isPlaying && player.isBuffering {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 50))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 80, height: 70)
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 34))
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
    }
}

/// Device volume, drawn like the scrubber. Reads AVAudioSession.outputVolume (follows the hardware buttons)
/// and writes through a hidden MPVolumeView, which also suppresses the system volume HUD.
@Observable
@MainActor
final class VolumeModel {
    var level: Float = AVAudioSession.sharedInstance().outputVolume
    @ObservationIgnored let volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
            let v = session.outputVolume
            Task { @MainActor in self?.level = v }
        }
    }

    func set(_ value: Float) {
        level = value
        let slider = volumeView.subviews.compactMap { $0 as? UISlider }.first
        slider?.setValue(value, animated: false)
        slider?.sendActions(for: .valueChanged)
    }
}

private struct VolumeRow: View {
    @State private var volume = VolumeModel()
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.caption)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule()
                        .fill(.white.opacity(dragging ? 1 : 0.7))
                        .frame(width: geo.size.width * CGFloat(min(max(volume.level, 0), 1)))
                }
                .frame(height: dragging ? 12 : 7)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            volume.set(Float(min(max(g.location.x / geo.size.width, 0), 1)))
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(.spring(duration: 0.25), value: dragging)
            }
            .frame(height: 24)
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
        .foregroundStyle(.white.opacity(0.5))
        // Hidden system view: needed to change device volume and hide the volume HUD.
        .background(HiddenVolumeView(view: volume.volumeView))
    }
}

private struct HiddenVolumeView: UIViewRepresentable {
    let view: MPVolumeView

    func makeUIView(context: Context) -> MPVolumeView {
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.75)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
