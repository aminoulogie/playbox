import SwiftUI

struct SettingsView: View {
    @AppStorage("playbox.library.posterColumns") private var posterColumns = 4
    @AppStorage("playbox.library.posterSizingMode") private var posterSizingMode = "columns"
    @AppStorage("playbox.library.posterWidth") private var posterWidth = 135.0
    @AppStorage("playbox.player.verticalGestures") private var verticalGestures = true

    private var clampedColumns: Int {
        min(max(posterColumns, 1), 12)
    }

    var body: some View {
        Form {
            Section {
                Picker("Poster sizing", selection: $posterSizingMode) {
                    Text("Per row").tag("columns")
                    Text("Poster size").tag("size")
                }
                .pickerStyle(.segmented)

                if posterSizingMode == "size" {
                    HStack {
                        Label("Smaller", systemImage: "rectangle.grid.3x2")
                            .font(.caption)
                        Slider(value: $posterWidth, in: 60...220, step: 5)
                            .accessibilityLabel("Poster size")
                        Label("Larger", systemImage: "rectangle")
                            .font(.caption)
                    }

                    Text("Fits as many posters as the screen allows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Stepper(
                        "Posters per row: \(clampedColumns)",
                        value: $posterColumns,
                        in: 1...12
                    )

                    Text("Show exactly \(clampedColumns) posters across the screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                PosterPreview(
                    columns: clampedColumns,
                    sizingMode: posterSizingMode,
                    preferredWidth: posterWidth
                )
                .frame(height: 92)
                .padding(.vertical, 4)
            } header: {
                Text("Posters")
            } footer: {
                Text("Applies immediately to Discover and Library.")
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
        .onAppear {
            posterColumns = clampedColumns
            posterWidth = posterWidth.isFinite ? min(max(posterWidth, 60), 220) : 135
            if posterSizingMode != "columns" && posterSizingMode != "size" {
                posterSizingMode = "columns"
            }
        }
        .onChange(of: posterColumns) { _, value in
            let corrected = min(max(value, 1), 12)
            if corrected != value {
                posterColumns = corrected
            }
        }
    }
}

private struct PosterPreview: View {
    let columns: Int
    let sizingMode: String
    let preferredWidth: Double

    var body: some View {
        GeometryReader { proxy in
            let layout = PosterLayout(
                availableWidth: proxy.size.width,
                columns: columns,
                sizingMode: sizingMode,
                preferredWidth: preferredWidth
            )
            let previewHeight = min(92, layout.height)
            HStack(spacing: layout.spacing) {
                ForEach(0..<layout.columns, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: layout.compact ? 4 : 8)
                        .fill(.secondary.opacity(0.24))
                        .overlay {
                            Image(systemName: "film")
                                .font(layout.compact ? .caption2 : .body)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: layout.width, height: previewHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
