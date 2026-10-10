import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    struct Entry: Codable, Identifiable, Hashable {
        let id: String
        let type: String
        let name: String
        let poster: String?
        var progress: Double
        var updatedAt: Date
        var position: Double?
        var duration: Double?

        var item: MetaPreview {
            MetaPreview(id: id, type: type, name: name, poster: poster, description: nil,
                        imdbRating: nil, releaseInfo: nil, genres: nil, runtime: nil,
                        background: nil, videos: nil)
        }
    }

    @Published private(set) var saved: [Entry] = []
    @Published private(set) var recent: [Entry] = []
    private let savedKey = "playbox.library.saved"
    private let recentKey = "playbox.library.recent"

    init() { load() }

    func contains(_ item: MetaPreview) -> Bool { saved.contains { $0.id == item.id } }

    func toggle(_ item: MetaPreview) {
        if let i = saved.firstIndex(where: { $0.id == item.id }) { saved.remove(at: i) }
        else { saved.insert(entry(item, progress: 0), at: 0) }
        persist()
    }

    func markStarted(_ item: MetaPreview) {
        recent.removeAll { $0.id == item.id }
        recent.insert(entry(item, progress: 0), at: 0)
        if recent.count > 20 { recent = Array(recent.prefix(20)) }
        persist()
    }

    func position(for item: MetaPreview) -> Double {
        recent.first(where: { $0.id == item.id })?.position ?? 0
    }

    func updatePlayback(_ item: MetaPreview, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, duration > 0, position >= 0 else { return }
        let fraction = min(1, max(0, position / duration))
        recent.removeAll { $0.id == item.id }
        if fraction < 0.95 {
            var value = entry(item, progress: fraction)
            value.position = position
            value.duration = duration
            recent.insert(value, at: 0)
        }
        if recent.count > 20 { recent = Array(recent.prefix(20)) }
        persist()
    }

    func removeSaved(at offsets: IndexSet) { saved.remove(atOffsets: offsets); persist() }

    private func entry(_ item: MetaPreview, progress: Double) -> Entry {
        Entry(id: item.id, type: item.type, name: item.name, poster: item.poster,
              progress: progress, updatedAt: Date(), position: nil, duration: nil)
    }

    private func load() {
        let d = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: savedKey) { saved = (try? d.decode([Entry].self, from: data)) ?? [] }
        if let data = UserDefaults.standard.data(forKey: recentKey) { recent = (try? d.decode([Entry].self, from: data)) ?? [] }
    }

    private func persist() {
        let e = JSONEncoder()
        UserDefaults.standard.set(try? e.encode(saved), forKey: savedKey)
        UserDefaults.standard.set(try? e.encode(recent), forKey: recentKey)
    }
}
