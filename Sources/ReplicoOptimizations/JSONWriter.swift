import Foundation
import NIOCore
import NIOFoundationCompat

/// Builds JSON bytes by scanning up to 32 UTF-8 bytes at a time and copying unescaped runs.
/// Four UInt64 lane masks are combined as integers instead of a generic SIMD mask reduction.
/// Short escapes use one big-endian UInt16 write instead of two UInt8 buffer writes.
///
/// Foundation's `JSONEncoder` handles arbitrary `Encodable` values and container structure.
/// This writer handles strings, Booleans and integers. Its callers supply matched structural
/// syntax, making it suitable for fixed wire formats. Unsupported models should use Foundation.
/// Both paths preserve controls, embedded NULs and Unicode. This writer leaves `/` unescaped.
///
/// Foundation:
/// ```swift
/// let data = try JSONEncoder().encode("Hello")
/// ```
///
/// Optimized:
/// ```swift
/// var writer = JSONWriter()
/// writer.write("Hello")
/// let data = writer.data
/// ```
package struct JSONWriter {
    private var bytes: ByteBuffer

    /// Creates a writer with optional capacity reserved for the complete document.
    package init(reservingCapacity capacity: Int = 0) {
        bytes = ByteBufferAllocator().buffer(capacity: capacity)
    }

    /// The bytes written so far. Reading this value does not finish the document.
    package var data: Data {
        Data(buffer: bytes)
    }

    /// Appends trusted, compile-time JSON syntax.
    package mutating func writeSyntax(_ syntax: StaticString) {
        bytes.writeString(syntax.description)
    }

    /// Appends a JSON Boolean.
    package mutating func write(_ value: Bool) {
        writeSyntax(value ? "true" : "false")
    }

    /// Appends an integer without narrowing its representation.
    package mutating func write<Integer: BinaryInteger>(_ value: Integer) {
        bytes.writeString(String(value))
    }

    /// Appends one validated JSON value without decoding or re-encoding it.
    package mutating func write(_ document: JSONDocument) {
        bytes.writeBytes(document.data)
    }

    /// Appends a quoted JSON string, preserving every Unicode scalar and NUL.
    package mutating func write(_ text: String) {
        var text = text
        text.makeContiguousUTF8()
        let codeUnits = text.utf8Span.span
        let rawBytes = codeUnits.bytes
        bytes.reserveCapacity(bytes.writerIndex + codeUnits.count + 2)
        bytes.writeInteger(UInt8(34))
        var position = 0
        var segmentStart = 0
        while position + 8 <= codeUnits.count {
            let count = rawBytes.plainJSONBlockLength(at: position, endingAt: codeUnits.count)
            if count > 0 {
                position += count
                continue
            }
            // Borrow between lanes can flag extra bytes. Scalar checks decide each escape.
            let end = position + 8
            while position < end {
                let byte = codeUnits[position]
                if byte < 32 || byte == 34 || byte == 92 {
                    append(rawBytes, range: segmentStart..<position)
                    escape(byte)
                    segmentStart = position + 1
                }
                position += 1
            }
        }
        while position < codeUnits.count {
            let byte = codeUnits[position]
            if byte < 32 || byte == 34 || byte == 92 {
                append(rawBytes, range: segmentStart..<position)
                escape(byte)
                segmentStart = position + 1
            }
            position += 1
        }
        append(rawBytes, range: segmentStart..<codeUnits.count)
        bytes.writeInteger(UInt8(34))
    }

    private mutating func append(_ source: RawSpan, range: Range<Int>) {
        bytes.writeBytes(source.extracting(range))
    }

    private mutating func escape(_ byte: UInt8) {
        let escaped: UInt8
        switch byte {
        case 34, 92:
            escaped = byte
        case 8:
            escaped = 98
        case 9:
            escaped = 116
        case 10:
            escaped = 110
        case 12:
            escaped = 102
        case 13:
            escaped = 114
        default:
            bytes.writeInteger(UInt32(0x5C75_3030), endianness: .big)
            let high: UInt8 = byte >> 4 == 0 ? 48 : 49
            let digit = byte & 15
            let low: UInt8 = digit < 10 ? digit + 48 : digit + 87
            bytes.writeInteger(UInt16(high) << 8 | UInt16(low), endianness: .big)
            return
        }
        bytes.writeInteger(UInt16(0x5C00) | UInt16(escaped), endianness: .big)
    }
}
