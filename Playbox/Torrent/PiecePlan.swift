import Foundation

struct TorrentFileSpan: Hashable, Sendable {
    let file: TorrentFile
    let startOffset: Int64
    let endOffset: Int64

    func pieceRange(pieceLength: Int64) -> ClosedRange<Int>? {
        guard file.length > 0, pieceLength > 0 else { return nil }
        let first = Int(startOffset / pieceLength)
        let last = Int((endOffset - 1) / pieceLength)
        return first...last
    }
}

struct PiecePlan: Sendable {
    let spans: [TorrentFileSpan]
    let selected: TorrentFileSpan
    let orderedPieces: [Int]

    init(metainfo: TorrentMetainfo, selectedFile: TorrentFile? = nil) throws {
        var cursor: Int64 = 0
        var built: [TorrentFileSpan] = []
        for file in metainfo.files {
            let span = TorrentFileSpan(file: file, startOffset: cursor, endOffset: cursor + file.length)
            built.append(span)
            cursor += file.length
        }
        guard let wanted = selectedFile ?? metainfo.preferredVideo,
              let span = built.first(where: { $0.file.id == wanted.id }),
              let range = span.pieceRange(pieceLength: metainfo.pieceLength) else {
            throw PiecePlanError.noPlayableFile
        }
        spans = built
        selected = span
        orderedPieces = Array(range)
    }
}

enum PiecePlanError: LocalizedError {
    case noPlayableFile
    var errorDescription: String? { "No supported video file was found in this authorized torrent." }
}
