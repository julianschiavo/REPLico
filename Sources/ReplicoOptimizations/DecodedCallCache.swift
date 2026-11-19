import Foundation

/// Holds immutable arguments already decoded on a single connection. Equality
/// compares the complete parameter bytes, including spelling and field order.
///
/// Foundation's baseline is `try decoder.decode(Call.self, from: frame)` for
/// every call. A consumer can instead look up `cache[header.parameters]`, decoding
/// and calling `cache.remember(call, for: header)` on a miss. Callers must
/// restrict entries to models whose decoding is pure and invoke every request.
package struct DecodedCallCache<Value: Sendable>: Sendable {
    private struct Entry: Sendable {
        let header: CanonicalToolCallHeader
        let value: Value
    }

    private var entries: [Entry] = []
    private var byteCount = 0

    /// Starts an empty connection cache.
    package init() {
    }

    /// The most recently admitted header, whose validated parameter bytes can be reused.
    package var latestHeader: CanonicalToolCallHeader? {
        entries.last?.header
    }

    /// Finds an exact match in the eight most recent admissions.
    package subscript(parameters: Data) -> Value? {
        entries.last(where: { $0.header.parameters == parameters })?.value
    }

    /// Retains at most two MiB of wire parameters, evicting oldest entries first.
    package mutating func remember(_ value: Value, for header: CanonicalToolCallHeader) {
        let limit = 2 * 1024 * 1024
        let parameters = header.parameters
        guard parameters.count <= limit else {
            return
        }
        while entries.count >= 8 || byteCount + parameters.count > limit {
            byteCount -= entries.removeFirst().header.parameters.count
        }
        entries.append(Entry(header: header, value: value))
        byteCount += parameters.count
    }
}
