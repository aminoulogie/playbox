import Foundation

actor SequentialPieceBuffer {
    struct Snapshot: Sendable {
        let completed: Int
        let total: Int
        let contiguousBytes: Int64
        let isReadyForPlayback: Bool
    }

    private let plan: PiecePlan
    private let pieceLength: Int64
    private let startupBytes: Int64
    private var verified = Set<Int>()

    init(plan: PiecePlan, pieceLength: Int64, startupBytes: Int64 = 8 * 1024 * 1024) {
        self.plan = plan
        self.pieceLength = pieceLength
        self.startupBytes = startupBytes
    }

    func nextPieces(limit: Int = 8) -> [Int] {
        Array(plan.orderedPieces.lazy.filter { !self.verified.contains($0) }.prefix(max(1, limit)))
    }

    func markVerified(_ index: Int) {
        if plan.orderedPieces.contains(index) { verified.insert(index) }
    }

    func snapshot() -> Snapshot {
        var contiguous: Int64 = 0
        for index in plan.orderedPieces {
            guard verified.contains(index) else { break }
            contiguous += pieceLength
        }
        contiguous = min(contiguous, plan.selected.file.length)
        return Snapshot(
            completed: verified.count,
            total: plan.orderedPieces.count,
            contiguousBytes: contiguous,
            isReadyForPlayback: contiguous >= min(startupBytes, plan.selected.file.length)
        )
    }
}
