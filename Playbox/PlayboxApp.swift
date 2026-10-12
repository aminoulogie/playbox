import SwiftUI

@main
struct PlayboxApp: App {
    @StateObject private var store = AddonStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var downloads = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(library)
                .environmentObject(downloads)
                // Bootstrap the DHT while the user browses, so the first
                // Play does not start from a cold torrent session.
                .task { TorrentPrewarmer.warmUpSession() }
        }
    }
}
