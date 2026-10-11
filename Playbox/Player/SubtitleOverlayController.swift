import Foundation

@MainActor
final class SubtitleOverlayController: ObservableObject {
    struct Cue: Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    @Published private(set) var cues: [Cue] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var loadTask: Task<Void, Never>?

    func select(_ subtitle: AddonSubtitle?) {
        loadTask?.cancel()
        loadTask = nil
        cues = []
        selectedID = subtitle?.stableID
        errorMessage = nil

        guard let subtitle else {
            isLoading = false
            return
        }

        guard let url = URL(string: subtitle.url) else {
            isLoading = false
            errorMessage = "Invalid subtitle URL"
            return
        }

        isLoading = true
        loadTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }

                let raw = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                let parsed = Self.parse(raw)

                guard !Task.isCancelled else { return }
                self?.cues = parsed
                self?.isLoading = false
                if parsed.isEmpty {
                    self?.errorMessage = "No readable subtitle cues"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoading = false
                self?.errorMessage = "Subtitle failed to load"
            }
        }
    }

    func text(at seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0, !cues.isEmpty else { return nil }

        var low = 0
        var high = cues.count - 1
        var candidate: Cue?

        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]
            if cue.start <= seconds {
                candidate = cue
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let candidate, seconds <= candidate.end else { return nil }
        return candidate.text
    }

    private static func parse(_ input: String) -> [Cue] {
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var output: [Cue] = []

        for block in blocks {
            let lines = block
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2 else { continue }

            let left = timing[0].trimmingCharacters(in: .whitespaces)
            let right = timing[1]
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: .whitespaces)
                .first ?? ""

            guard let start = parseTime(left),
                  let end = parseTime(right),
                  end >= start else { continue }

            let textLines = lines.dropFirst(timingIndex + 1)
            let text = cleanText(textLines.joined(separator: "\n"))
            guard !text.isEmpty else { continue }

            output.append(Cue(start: start, end: end, text: text))
        }

        return output.sorted { $0.start < $1.start }
    }

    private static func parseTime(_ value: String) -> Double? {
        let cleaned = value
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = cleaned.split(separator: ":")

        guard pieces.count == 2 || pieces.count == 3 else { return nil }

        if pieces.count == 3 {
            guard let hours = Double(pieces[0]),
                  let minutes = Double(pieces[1]),
                  let seconds = Double(pieces[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        }

        guard let minutes = Double(pieces[0]),
              let seconds = Double(pieces[1]) else { return nil }
        return minutes * 60 + seconds
    }

    private static func cleanText(_ value: String) -> String {
        let withoutTags = value.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
