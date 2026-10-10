import SwiftUI

@main
struct PlayboxApp: App {
    @StateObject private var store = AddonStore()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
    }
}
