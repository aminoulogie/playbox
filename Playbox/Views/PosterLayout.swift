import SwiftUI

/// Shared sizing for Discover rows and Library grids.
struct PosterLayout {
    let columns: Int
    let width: CGFloat
    let spacing: CGFloat
    let horizontalPadding: CGFloat

    init(availableWidth: CGFloat, columns: Int, sizingMode: String, preferredWidth: Double) {
        let requestedColumns = min(max(columns, 1), 12)
        let usesPosterSize = sizingMode == "size"
        let padding: CGFloat = !usesPosterSize && requestedColumns >= 7 ? 6 : 12
        let usableWidth = max(1, availableWidth - padding * 2)

        if usesPosterSize {
            let targetWidth = CGFloat(preferredWidth.isFinite ? min(max(preferredWidth, 60), 220) : 135)
            let gap: CGFloat = targetWidth < 100 ? 6 : 12
            let posterWidth = min(targetWidth, usableWidth)
            self.columns = max(1, Int((usableWidth + gap) / (posterWidth + gap)))
            self.width = posterWidth
            self.spacing = gap
        } else {
            let gap: CGFloat
            switch requestedColumns {
            case 1...2: gap = 14
            case 3...4: gap = 10
            case 5...6: gap = 6
            default: gap = 4
            }
            self.columns = requestedColumns
            self.width = max(1, (usableWidth - gap * CGFloat(requestedColumns - 1)) / CGFloat(requestedColumns))
            self.spacing = gap
        }
        self.horizontalPadding = padding
    }

    var height: CGFloat { width * 1.5 }
    var compact: Bool { width < 70 }
    var showsTitle: Bool { width >= 40 }

    var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(width), spacing: spacing), count: columns)
    }
}
