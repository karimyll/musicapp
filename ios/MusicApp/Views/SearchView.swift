import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerEngine.self) private var player
    @Environment(\.modelContext) private var context
    @Query private var tracks: [Track]

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    private var downloaded: [String: Track] {
        Dictionary(tracks.map { ($0.videoId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { r in
                    row(r, downloaded: downloaded)
                }
            }
            .listStyle(.plain)
            .overlay {
                if !settings.isConfigured {
                    ContentUnavailableView("No Server", systemImage: "server.rack",
                                           description: Text("Add your server URL and token in Settings."))
                } else if let error {
                    ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if isLoading && results.isEmpty {
                    ProgressView()
                } else if results.isEmpty {
                    ContentUnavailableView("Search Music", systemImage: "magnifyingglass",
                                           description: Text("Type a song or artist name."))
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Songs, artists…")
            .onSubmit(of: .search) { runSearch() }
            #if DEBUG
            .task {
                // Simulator testing: `-debugSearch "<query>"` launch argument.
                if results.isEmpty, let q = UserDefaults.standard.string(forKey: "debugSearch") {
                    query = q
                    runSearch()
                }
            }
            #endif
            .onChange(of: query) { _, new in
                if new.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchTask?.cancel()
                    results = []
                    error = nil
                    isLoading = false
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ r: SearchResult, downloaded: [String: Track]) -> some View {
        let track = downloaded[r.id]
        HStack(spacing: 12) {
            ArtworkView(track: track, remoteURL: r.thumbnail)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).lineLimit(1)
                Text([r.artist, r.duration.map(formatDuration)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let err = downloads.errors[r.id] {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            trailing(r, track: track)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let track { player.play([track]) } else { startDownload(r) }
        }
    }

    @ViewBuilder
    private func trailing(_ r: SearchResult, track: Track?) -> some View {
        if track != nil {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
        } else if let p = downloads.active[r.id] {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 3)
                if p > 0 {
                    Circle().trim(from: 0, to: p)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 26, height: 26)
        } else {
            Button { startDownload(r) } label: {
                Image(systemName: "arrow.down.circle").font(.title2)
            }
            .buttonStyle(.borderless)
        }
    }

    private func startDownload(_ r: SearchResult) {
        guard let api = settings.api else { return }
        downloads.download(r, api: api, context: context)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let api = settings.api else { return }
        searchTask?.cancel()
        isLoading = true
        error = nil
        searchTask = Task {
            do {
                let found = try await api.search(q)
                guard !Task.isCancelled else { return }
                results = found
            } catch is CancellationError {
                return
            } catch let e as URLError where e.code == .cancelled {
                return
            } catch {
                self.error = error.localizedDescription
                results = []
            }
            isLoading = false
        }
    }
}
