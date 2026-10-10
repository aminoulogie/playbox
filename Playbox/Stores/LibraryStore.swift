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
        recent.insert(entry(item, progress: 0.03), at: 0)
        if recent.count > 20 { recent = Array(recent.prefix(20)) }
        persist()
    }

    func removeSaved(at offsets: IndexSet) { saved.remove(atOffsets: offsets); persist() }

    private func entry(_ item: MetaPreview, progress: Double) -> Entry {
        Entry(id: item.id, type: item.type, name: item.name, poster: item.poster,
              progress: progress, updatedAt: Date())
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
