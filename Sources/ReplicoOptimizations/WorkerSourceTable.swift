import Foundation

/// Retains the eight most recently transmitted source strings for one worker.
/// Swift string equality normalizes Unicode. JavaScript observes the original
/// code units, so a reusable slot requires an exact UTF-8 match. Foundation's
/// `Data` compares contiguous bytes in bulk.
///
/// A standalone frame sends the complete source each time:
/// ```swift
/// try WorkerEvaluationFrame(executionID: id, code: code, metadata: metadata, moduleDirectories: roots)
/// ```
/// Frames sharing a worker can refer to its previous input:
/// ```swift
/// try WorkerEvaluationFrame(executionID: id, code: code, reusing: sources.slot(for: code),
///     metadata: metadata, moduleDirectories: roots)
/// ```
package struct WorkerSourceTable: Sendable {
    private var sources: [Data] = []

    /// Creates an empty table for a newly launched worker.
    package init() {
    }

    /// Returns a previous slot, or records the next source to be sent in full.
    package mutating func slot(for code: String) -> Int? {
        let bytes = Data(code.utf8)
        if let slot = sources.firstIndex(of: bytes) {
            return slot
        }
        if sources.count == 8 {
            sources.removeFirst()
        }
        sources.append(bytes)
        return nil
    }
}
