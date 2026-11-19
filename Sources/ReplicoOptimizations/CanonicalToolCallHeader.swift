import Foundation

/// Validated routing for the exact compact tools/call envelope with unsigned decimal ID and final object params.
///
/// Every byte belongs to the fixed header, lossless ID, complete params object, or final root brace.
/// Unsupported layouts return nil for the original full-frame validation and Foundation decoding.
///
/// Foundation baseline:
/// ```swift
/// _ = try JSONDocument(validating: data)
/// let header = try JSONDecoder().decode(MessageHeader.self, from: data)
/// ```
/// Optimized call site with the same fallback:
/// ```swift
/// if let canonical = CanonicalToolCallHeader(frame: data) {
///     let header = MessageHeader(toolCallID: canonical.id)
///     route(header)
/// } else {
///     _ = try JSONDocument(validating: data)
///     route(try JSONDecoder().decode(MessageHeader.self, from: data))
/// }
/// ```
package struct CanonicalToolCallHeader: Equatable, Sendable {
    /// The original unsigned decimal request ID, without numeric conversion loss.
    package let id: UInt64
    /// The complete validated parameter object in the input frame.
    package let parameters: Data

    private static let prefix = Array(#"{"jsonrpc":"2.0","id":"#.utf8)
    private static let middle = Array(#","method":"tools/call","params":"#.utf8)

    /// Recognizes one complete envelope, reusing a previous validation only for byte-identical parameters.
    package init?(frame: Data, reusing previous: Self? = nil) {
        guard frame.count >= Self.prefix.count + Self.middle.count + 4 else {
            return nil
        }
        let bytes = frame.bytes
        guard Self.matches(Self.prefix, at: 0, in: bytes) else {
            return nil
        }
        var position = Self.prefix.count
        let first = bytes.load(fromByteOffset: position, as: UInt8.self)
        var value: UInt64 = 0
        while position < bytes.byteCount {
            let byte = bytes.load(fromByteOffset: position, as: UInt8.self)
            guard (0x30...0x39).contains(byte) else {
                break
            }
            let digit = UInt64(byte - 0x30)
            guard value <= (UInt64.max - digit) / 10 else {
                return nil
            }
            value = value * 10 + digit
            position += 1
        }
        guard position > Self.prefix.count,
            first != 0x30 || position == Self.prefix.count + 1,
            Self.matches(Self.middle, at: position, in: bytes)
        else {
            return nil
        }
        position += Self.middle.count
        guard position < bytes.byteCount - 1,
            bytes.load(fromByteOffset: position, as: UInt8.self) == 0x7B,
            bytes.load(fromByteOffset: bytes.byteCount - 1, as: UInt8.self) == 0x7D
        else {
            return nil
        }
        let start = frame.index(frame.startIndex, offsetBy: position)
        let end = frame.index(before: frame.endIndex)
        let parameters = frame[start..<end]
        if let previous, previous.parameters == parameters {
            self.parameters = previous.parameters
        } else if (try? JSONDocument(validating: parameters, enclosingContainers: 1)) != nil {
            self.parameters = parameters
        } else {
            return nil
        }
        id = value
    }

    private static func matches(_ expected: [UInt8], at offset: Int, in bytes: RawSpan) -> Bool {
        guard expected.count <= bytes.byteCount - offset else {
            return false
        }
        for index in expected.indices {
            guard bytes.load(fromByteOffset: offset + index, as: UInt8.self) == expected[index] else {
                return false
            }
        }
        return true
    }
}
