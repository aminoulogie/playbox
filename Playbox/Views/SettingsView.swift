import SwiftUI

struct SettingsView: View {
    @AppStorage("playbox.library.posterColumns") private var posterColumns = 4
    @AppStorage("playbox.player.verticalGestures") private var verticalGestures = true

    var body: some View {
        Form {
            Section("Library") {
                Picker("Poster density", selection: $posterColumns) {
                    Text("4 per row").tag(4)
                    Text("6 per row").tag(6)
                }
                .pickerStyle(.segmented)

                Text(posterColumns == 4
                     ? "Larger posters with more spacing."
                     : "Smaller posters so more of your library fits on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Player") {
                Toggle("Brightness / volume swipe", isOn: $verticalGestures)

                VStack(alignment: .leading, spacing: 6) {
                    Label("Left side", systemImage: "sun.max")
                    Text("Swipe up or down to change screen brightness.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("Right side", systemImage: "speaker.wave.2")
                    Text("Swipe up or down to change system volume.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Label("CC is available in the player when an add-on returns subtitles.", systemImage: "captions.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
