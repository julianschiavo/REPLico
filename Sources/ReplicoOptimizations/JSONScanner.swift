import Foundation

/// Owns JSON bytes and validates their grammar without materializing strings or numbers.
///
/// Foundation's baseline builds an object tree and applies numeric representability
/// limits. This scanner checks strict lexical syntax, including ignored fields, with
/// bounded recursion and bulk scanning of validated UTF-8.
///
/// Foundation baseline:
/// ```swift
/// _ = try JSONSerialization.jsonObject(
///     with: data,
///     options: [.fragmentsAllowed]
/// )
/// ```
/// Optimized internal path:
/// ```swift
/// var scanner = JSONScanner(
///     data
/// )
/// try scanner.validate()
/// ```
struct JSONScanner {
    private let data: Data
    private var position = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func validate(enclosingContainers: Int = 0) throws {
        guard (0...512).contains(enclosingContainers) else {
            throw failure("JSON nesting exceeds 512 containers")
        }
        let input = data
        let bytes = input.bytes
        do {
            _ = try UTF8Span(validating: Span<UInt8>(viewing: bytes))
        } catch {
            throw failure("Invalid UTF-8")
        }
        skipWhitespace(bytes)
        try value(bytes, depth: enclosingContainers)
        skipWhitespace(bytes)
        guard position == bytes.byteCount else {
            throw failure("Unexpected bytes after JSON value")
        }
    }

    private func current(in bytes: RawSpan) -> UInt8? {
        guard position < bytes.byteCount else {
            return nil
        }
        return bytes.load(fromByteOffset: position, as: UInt8.self)
    }

    private mutating func value(_ bytes: RawSpan, depth: Int) throws {
        guard let first = current(in: bytes) else {
            throw failure("Expected JSON value")
        }
        switch first {
        case 0x7B, 0x5B:
            guard depth < 512 else {
                throw failure("JSON nesting exceeds 512 containers")
            }
            position += 1
            try container(bytes, depth: depth + 1, isObject: first == 0x7B)
        case 0x22:
            try string(bytes)
        case 0x74:
            try literal("true", in: bytes)
        case 0x66:
            try literal("false", in: bytes)
        case 0x6E:
            try literal("null", in: bytes)
        case 0x2D, 0x30...0x39:
            try number(bytes)
        default:
            throw failure("Expected JSON value")
        }
    }

    private mutating func container(_ bytes: RawSpan, depth: Int, isObject: Bool) throws {
        let end: UInt8 = isObject ? 0x7D : 0x5D
        skipWhitespace(bytes)
        if consume(end, in: bytes) {
            return
        }
        while true {
            if isObject {
                guard current(in: bytes) == 0x22 else {
                    throw failure("Expected object key")
                }
                try string(bytes)
                skipWhitespace(bytes)
                guard consume(0x3A, in: bytes) else {
                    throw failure("Expected colon after object key")
                }
                skipWhitespace(bytes)
            }
            try value(bytes, depth: depth)
            skipWhitespace(bytes)
            if consume(end, in: bytes) {
                return
            }
            guard consume(0x2C, in: bytes) else {
                throw failure(isObject ? "Expected comma or object end" : "Expected comma or array end")
            }
            skipWhitespace(bytes)
        }
    }

    private mutating func string(_ bytes: RawSpan) throws {
        position += 1
        while position < bytes.byteCount {
            position = bytes.firstJSONSpecialByte(from: position, to: bytes.byteCount)
            guard let byte = current(in: bytes) else {
                break
            }
            switch byte {
            case 0x22:
                position += 1
                return
            case 0x5C:
                position += 1
                guard let escaped = current(in: bytes) else {
                    throw failure("Unterminated escape")
                }
                position += 1
                switch escaped {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    break
                case 0x75:
                    try unicodeEscape(bytes)
                default:
                    throw failure("Invalid string escape")
                }
            default:
                throw failure("Unescaped control character")
            }
        }
        throw failure("Unterminated string")
    }

    private mutating func unicodeEscape(_ bytes: RawSpan) throws {
        let first = try codeUnit(bytes)
        if (0xD800...0xDBFF).contains(first) {
            guard consume(0x5C, in: bytes), consume(0x75, in: bytes) else {
                throw failure("Missing low surrogate")
            }
            let second = try codeUnit(bytes)
            guard (0xDC00...0xDFFF).contains(second) else {
                throw failure("Invalid low surrogate")
            }
        } else if (0xDC00...0xDFFF).contains(first) {
            throw failure("Unexpected low surrogate")
        }
    }

    private mutating func codeUnit(_ bytes: RawSpan) throws -> UInt16 {
        guard bytes.byteCount - position >= 4 else {
            throw failure("Incomplete Unicode escape")
        }
        var result: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes.load(fromByteOffset: position, as: UInt8.self)
            let digit: UInt8
            switch byte {
            case 0x30...0x39:
                digit = byte - 0x30
            case 0x41...0x46:
                digit = byte - 0x41 + 10
            case 0x61...0x66:
                digit = byte - 0x61 + 10
            default:
                throw failure("Invalid Unicode escape")
            }
            result = (result << 4) | UInt16(digit)
            position += 1
        }
        return result
    }

    private mutating func number(_ bytes: RawSpan) throws {
        _ = consume(0x2D, in: bytes)
        if !consume(0x30, in: bytes) {
            guard let first = current(in: bytes), (0x31...0x39).contains(first) else {
                throw failure("Invalid integer part")
            }
            _ = digits(bytes)
        }
        if consume(0x2E, in: bytes) {
            guard digits(bytes) else {
                throw failure("Missing fraction digits")
            }
        }
        if consume(0x65, in: bytes) || consume(0x45, in: bytes) {
            if !consume(0x2B, in: bytes) {
                _ = consume(0x2D, in: bytes)
            }
            guard digits(bytes) else {
                throw failure("Missing exponent digits")
            }
        }
    }

    private mutating func digits(_ bytes: RawSpan) -> Bool {
        let start = position
        while let byte = current(in: bytes), (0x30...0x39).contains(byte) {
            position += 1
        }
        return position != start
    }

    private mutating func literal(_ expected: String, in bytes: RawSpan) throws {
        for byte in expected.utf8 {
            guard consume(byte, in: bytes) else {
                throw failure("Invalid JSON literal")
            }
        }
    }

    private mutating func consume(_ byte: UInt8, in bytes: RawSpan) -> Bool {
        guard current(in: bytes) == byte else {
            return false
        }
        position += 1
        return true
    }

    private mutating func skipWhitespace(_ bytes: RawSpan) {
        while let byte = current(in: bytes) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                position += 1
            default:
                return
            }
        }
    }

    private func failure(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "\(message) at byte \(position)."))
    }
}
