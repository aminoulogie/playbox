import Foundation
import CryptoKit

struct TorrentFile: Identifiable, Hashable, Sendable {
    let path: String
    let length: Int64
    var id: String { path }
    var isVideo: Bool { ["mp4","m4v","mov"].contains(URL(fileURLWithPath:path).pathExtension.lowercased()) }
}

struct TorrentMetainfo: Sendable {
    let name: String
    let pieceLength: Int64
    let pieceHashes: [Data]
    let files: [TorrentFile]
    let trackers: [URL]

    var preferredVideo: TorrentFile? { files.filter(\.isVideo).max { $0.length < $1.length } }

    init(data: Data) throws {
        guard case .dictionary(let root) = try BencodeDecoder().decode(data),
              case .dictionary(let info)? = root["info"],
              case .bytes(let nameData)? = info["name"],
              case .integer(let pieceLength)? = info["piece length"],
              case .bytes(let pieces)? = info["pieces"],
              let name = String(data:nameData, encoding:.utf8),
              pieceLength > 0, pieces.count % 20 == 0 else { throw BencodeError.malformed }
        self.name = name; self.pieceLength = pieceLength
        self.pieceHashes = stride(from:0, to:pieces.count, by:20).map { pieces.subdata(in:$0..<($0+20)) }
        var parsed:[TorrentFile] = []
        if case .list(let list)? = info["files"] {
            for entry in list {
                guard case .dictionary(let d) = entry, case .integer(let len)? = d["length"], case .list(let parts)? = d["path"] else { continue }
                let path = parts.compactMap { if case .bytes(let x) = $0 { return String(data:x,encoding:.utf8) }; return nil }.joined(separator:"/")
                if !path.isEmpty { parsed.append(.init(path:path,length:len)) }
            }
        } else if case .integer(let len)? = info["length"] { parsed = [.init(path:name,length:len)] }
        files = parsed
        var urls:[URL] = []
        if case .bytes(let announce)? = root["announce"], let s=String(data:announce,encoding:.utf8), let u=URL(string:s) { urls.append(u) }
        trackers = urls
    }
}

struct PieceVerifier {
    static func verify(piece: Data, expectedSHA1: Data) -> Bool {
        Data(Insecure.SHA1.hash(data: piece)) == expectedSHA1
    }
}
