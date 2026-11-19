import Foundation
import NIOCore

/// Common worker events recognized directly from the producer's plain JSON layouts.
///
/// Recognizes canonical UUID execution IDs, unnamed UTF-8 text with the eight short
/// JSON escapes, canonical image data, and successful completions without an error
/// field. Unicode escapes (`\u`) and unknown escapes retain whole-event Foundation
/// decoding. Foundation decodes image bytes directly from their Base64 slice. Its
/// default decoder rejects quotes, backslashes and control bytes, so a successful
/// decode also validates the raw JSON string between the delimiters. Every other layout or
/// byte sequence also returns `nil` for the existing Foundation decoder. Text scanning checks
/// four UInt64 lanes per safe 32-byte load, combining integer flags instead of a
/// generic SIMD mask reduction, then retains native UTF-8 validation.
///
/// Foundation baseline:
/// ```swift
/// let event = try JSONDecoder().decode(WorkerEvent.self, from: frame)
/// ```
/// Optimized recognition with the same fallback:
/// ```swift
/// if let envelope = WorkerEnvelope(frame: frame) {
///     switch envelope {
///     case .text(let executionID, let text):
///         receiveText(executionID, text)
///     case .image(let executionID, let data, let mimeType):
///         receiveImage(executionID, data, mimeType)
///     case .completed(let executionID):
///         complete(executionID)
///     }
/// } else {
///     receive(try JSONDecoder().decode(WorkerEvent.self, from: frame))
/// }
/// ```
package enum WorkerEnvelope: Equatable, Sendable {
    /// An unnamed plain-text output item with its execution identifier.
    case text(executionID: String, text: String)
    /// Image bytes decoded natively from an unescaped canonical producer layout.
    case image(executionID: String, data: Data, mimeType: String)
    /// A successful completion with no error payload.
    case completed(executionID: String)

    private static let outputPrefix = Array(#"{"output":{"executionID":""#.utf8)
    private static let outputMiddle = Array(#"","content":{"type":"text","text":""#.utf8)
    private static let outputSuffix = Array(#""}}}"#.utf8)
    private static let completionPrefix = Array(#"{"completed":{"executionID":""#.utf8)
    private static let completionSuffix = Array(#"","succeeded":true}}"#.utf8)
    private static let imageMiddle = Array(#"","content":{"type":"image","data":""#.utf8)
    private static let imageSuffixes = [
        "image/png": Array(#"","mimeType":"image/png"}}}"#.utf8),
        "image/jpeg": Array(#"","mimeType":"image/jpeg"}}}"#.utf8),
        "image/webp": Array(#"","mimeType":"image/webp"}}}"#.utf8),
        "image/gif": Array(#"","mimeType":"image/gif"}}}"#.utf8),
    ]

    /// Recognizes a complete canonical frame or returns nil for Foundation decoding.
    package init?(frame: Data) {
        if frame.count == Self.completionPrefix.count + 36 + Self.completionSuffix.count {
            let bytes = frame.bytes
            let idOffset = Self.completionPrefix.count
            guard Self.matches(Self.completionPrefix, at: 0, in: bytes),
                Self.matches(Self.completionSuffix, at: idOffset + 36, in: bytes),
                let id = Self.validatedID(in: bytes, frame: frame, startingAt: idOffset)
            else {
                return nil
            }
            self = .completed(executionID: id)
            return
        }
        let idOffset = Self.outputPrefix.count
        let middleOffset = idOffset + 36
        let textOffset = middleOffset + Self.outputMiddle.count
        guard frame.count >= textOffset + Self.outputSuffix.count else {
            return nil
        }
        let textEnd = frame.count - Self.outputSuffix.count
        let bytes = frame.bytes
        guard Self.matches(Self.outputPrefix, at: 0, in: bytes),
            let id = Self.validatedID(in: bytes, frame: frame, startingAt: idOffset)
        else {
            return nil
        }
        if Self.matches(Self.imageMiddle, at: middleOffset, in: bytes) {
            guard let image = Self.image(in: frame, executionID: id, from: middleOffset + Self.imageMiddle.count) else {
                return nil
            }
            self = image
            return
        }
        guard Self.matches(Self.outputMiddle, at: middleOffset, in: bytes),
            Self.matches(Self.outputSuffix, at: textEnd, in: bytes)
        else {
            return nil
        }
        let special = bytes.firstJSONSpecialByte(from: textOffset, to: textEnd)
        let text: String?
        if special == textEnd {
            let start = frame.startIndex + textOffset
            text = String(validating: frame[start..<(frame.startIndex + textEnd)], as: UTF8.self)
        } else {
            text = Self.commonEscapedText(in: bytes, from: textOffset, firstEscape: special, to: textEnd)
        }
        guard let text else {
            return nil
        }
        self = .text(executionID: id, text: text)
    }

    private static func image(in frame: Data, executionID: String, from dataOffset: Int) -> Self? {
        let bytes = frame.bytes
        for (mimeType, suffix) in Self.imageSuffixes {
            let dataEnd = frame.count - suffix.count
            guard dataEnd >= dataOffset, Self.matches(suffix, at: dataEnd, in: bytes) else {
                continue
            }
            let start = frame.index(frame.startIndex, offsetBy: dataOffset)
            let end = frame.index(frame.startIndex, offsetBy: dataEnd)
            guard let data = Data(base64Encoded: frame[start..<end]) else {
                return nil
            }
            return .image(executionID: executionID, data: data, mimeType: mimeType)
        }
        return nil
    }

    private static func matches(_ expected: [UInt8], at offset: Int, in bytes: RawSpan) -> Bool {
        for index in expected.indices {
            guard bytes.load(fromByteOffset: offset + index, as: UInt8.self) == expected[index] else {
                return false
            }
        }
        return true
    }

    private static func validatedID(in bytes: RawSpan, frame: Data, startingAt offset: Int) -> String? {
        for index in 0..<36 {
            let byte = bytes.load(fromByteOffset: offset + index, as: UInt8.self)
            switch index {
            case 8, 13, 18, 23:
                guard byte == 0x2D else {
                    return nil
                }
            default:
                switch byte {
                case 0x30...0x39, 0x41...0x46, 0x61...0x66:
                    break
                default:
                    return nil
                }
            }
        }
        let startIndex = frame.index(frame.startIndex, offsetBy: offset)
        let endIndex = frame.index(startIndex, offsetBy: 36)
        return String(validating: frame[startIndex..<endIndex], as: UTF8.self)
    }

    private static func commonEscapedText(in bytes: RawSpan, from start: Int, firstEscape: Int, to end: Int) -> String?
    {
        var output = ByteBufferAllocator().buffer(capacity: end - start)
        var position = start
        var special = firstEscape
        while position < end {
            output.writeBytes(bytes.extracting(position..<special))
            guard special < end else {
                break
            }
            guard bytes.load(fromByteOffset: special, as: UInt8.self) == 0x5C, special + 1 < end else {
                return nil
            }
            let decoded: UInt8
            switch bytes.load(fromByteOffset: special + 1, as: UInt8.self) {
            case 0x22:
                decoded = 0x22
            case 0x5C:
                decoded = 0x5C
            case 0x2F:
                decoded = 0x2F
            case 0x62:
                decoded = 0x08
            case 0x66:
                decoded = 0x0C
            case 0x6E:
                decoded = 0x0A
            case 0x72:
                decoded = 0x0D
            case 0x74:
                decoded = 0x09
            default:
                return nil
            }
            output.writeInteger(decoded)
            position = special + 2
            special = bytes.firstJSONSpecialByte(from: position, to: end)
        }
        return String(validating: output.readableBytesView, as: UTF8.self)
    }
}
