import SwiftUI

struct TrackedPlayerView: View {
    let url: URL
    let item: MetaPreview

    var body: some View {
        if url.isFileURL {
            VLCLocalPlayerView(url: url, item: item)
        } else {
            AVTrackedPlayerView(url: url, item: item)
        }
    }
}
