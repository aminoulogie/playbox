import SwiftUI

struct SettingsView: View {
    @AppStorage("playbox.library.posterColumns") private var posterColumns = 4
    @AppStorage("playbox.player.verticalGestures") private var verticalGestures = true

    private var clampedColumns: Int {
        min(max(posterColumns, 1), 12)
    }

    var body: some View {
        Form {
            Section("Library") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Posters per row")
                        Text("Type any value from 1 to 12.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    TextField("4", value: $posterColumns, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .monospacedDigit()
                        .frame(width: 54)
                        .textFieldStyle(.roundedBorder)
                }

                Stepper(
                    "Density: \(clampedColumns) per row",
                    value: $posterColumns,
                    in: 1...12
                )

                DensityPreview(columns: clampedColumns)
                    .frame(height: 76)
                    .padding(.vertical, 4)
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
        .onChange(of: posterColumns) { _, value in
            let corrected = min(max(value, 1), 12)
            if corrected != value {
                posterColumns = corrected
            }
        }
    }
}

private struct DensityPreview: View {
    let columns: Int

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = columns >= 7 ? 3 : 5
            let totalSpacing = spacing * CGFloat(max(0, columns - 1))
            let width = max(
                CGFloat(4),
                (proxy.size.width - totalSpacing) / CGFloat(max(columns, 1))
            )

            HStack(spacing: spacing) {
                ForEach(0..<columns, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: columns >= 7 ? 2 : 4)
                        .fill(.secondary.opacity(0.24))
                        .frame(width: width)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
