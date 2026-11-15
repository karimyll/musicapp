import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerEngine.self) private var player
    @Environment(\.modelContext) private var context
    @Query private var tracks: [Track]

    @State private var status: String?
    @State private var checking = false
    @State private var usedBytes: Int64 = 0
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $settings.serverURL, prompt: Text(verbatim: "https://music.example.com"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API token", text: $settings.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await check() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if checking { ProgressView() }
                        }
                    }
                    .disabled(!settings.isConfigured || checking)
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Your server address and the API_TOKEN from its .env file.")
                }

                Section("Storage") {
                    LabeledContent("Songs", value: "\(tracks.count)")
                    LabeledContent("Used", value: ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file))
                    Button("Delete All Songs", role: .destructive) { confirmDeleteAll = true }
                        .disabled(tracks.isEmpty)
                }
            }
            .navigationTitle("Settings")
            .onAppear { usedBytes = Storage.usedBytes() }
            .onChange(of: tracks.count) { usedBytes = Storage.usedBytes() }
            .confirmationDialog("Delete all downloaded songs from this phone?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    player.stop()
                    for t in tracks { deleteTrack(t, player: player, context: context) }
                    usedBytes = Storage.usedBytes()
                }
            }
        }
    }

    private func check() async {
        guard let api = settings.api else { return }
        checking = true
        defer { checking = false }
        do {
            let version = try await api.health()
            _ = try await api.search("test")
            status = "✅ Connected (yt-dlp \(version))"
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }
}
