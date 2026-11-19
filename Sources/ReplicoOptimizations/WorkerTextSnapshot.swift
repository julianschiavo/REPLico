import Foundation

/// Reconstructs related worker text from one bounded UTF-8 snapshot per kernel.
/// Foundation normally decodes the full text from every JSON frame:
/// ```swift
/// let item = try JSONDecoder().decode(Content.self, from: frame)
/// display(item.text)
/// ```
/// A worker can send a changed byte range after emitting a full snapshot:
/// ```swift
/// let next = try update.applied(to: snapshot, text: item.text, remainingBytes: budget)
/// display(next.value)
/// ```
package struct WorkerTextSnapshot: Sendable {
    private let key: String
    /// The complete validated output, including bytes reused from the previous item.
    package let value: String

    /// Why the update cannot be admitted to the active evaluation.
    package enum Failure: Error, Equatable {
        /// The base, byte ranges or reconstructed UTF-8 are invalid.
        case invalidUpdate
        /// The full reconstructed value exceeds the remaining evaluation budget.
        case outputLimit
    }

    /// The two wire representations understood by a host that advertises text deltas.
    package enum Update: Decodable, Sendable {
        /// Installs a full text item as the base for a later change.
        case seed(key: String)
        /// Reuses disjoint prefix and suffix byte ranges around the inserted bytes.
        case change(key: String, base: String, prefix: Int, suffix: Int, insert: Data)

        /// Returns the new snapshot after validating its identity, size and UTF-8.
        package func applied(to previous: WorkerTextSnapshot?, text: String?, remainingBytes: Int)
            throws(Failure) -> WorkerTextSnapshot
        {
            let sizes = (64 * 1_024)...(2 * 1_024 * 1_024)
            switch self {
            case .seed(let key):
                guard key.utf8.count == 36, let text, sizes.contains(text.utf8.count) else {
                    throw .invalidUpdate
                }
                guard text.utf8.count <= remainingBytes else {
                    throw .outputLimit
                }
                return WorkerTextSnapshot(key: key, value: text)
            case .change(let key, let base, let prefix, let suffix, let insert):
                guard key.utf8.count == 36, let previous, previous.key == base, prefix >= 0, suffix >= 0 else {
                    throw .invalidUpdate
                }
                let length = previous.value.utf8.count
                guard prefix <= length, suffix <= length - prefix, insert.count <= sizes.upperBound - (prefix + suffix),
                    sizes.contains(prefix + suffix + insert.count)
                else {
                    throw .invalidUpdate
                }
                guard prefix + suffix + insert.count <= remainingBytes else {
                    throw .outputLimit
                }
                if prefix == length && insert.isEmpty {
                    return WorkerTextSnapshot(key: key, value: previous.value)
                }
                var bytes = Data(previous.value.utf8)
                bytes.replaceSubrange(prefix..<(length - suffix), with: insert)
                guard let value = String(validating: bytes, as: UTF8.self) else {
                    throw .invalidUpdate
                }
                return WorkerTextSnapshot(key: key, value: value)
            }
        }
    }
}
