import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationStack { CatalogView() }
                .tabItem { Label("Discover", systemImage: "play.rectangle") }

            NavigationStack { AddonsView() }
                .tabItem { Label("Add-ons", systemImage: "puzzlepiece.extension") }
        }
    }
}
