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
        }
    }
}
