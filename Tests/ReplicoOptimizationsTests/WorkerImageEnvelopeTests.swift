@testable import ReplicoCore
import ReplicoOptimizations
import Foundation
import Testing

struct WorkerImageEnvelopeTests {
    private static let id = "01234567-89AB-CDEF-0123-456789abcdef"
    private static let prefix = Data(#"{"output":{"executionID":""#.utf8)
    private static let middle = Data(#"","content":{"type":"image","data":""#.utf8)
    private static let mimeTypes = ["image/png", "image/jpeg", "image/webp", "image/gif"]

    @Test
    func allBytePayloadsAndPaddingLengthsMatchFoundationForEveryMIME() throws {
        for mimeType in Self.mimeTypes {
            for length in 0..<260 {
                let bytes = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
                try Self.expectNativeParity(
                    Self.frame(encoded: bytes.base64EncodedData(), mimeType: mimeType), required: true)
            }
            for byte in UInt8.min...UInt8.max {
                for length in 1...4 {
                    let bytes = Data(repeating: byte, count: length)
                    try Self.expectNativeParity(
                        Self.frame(encoded: bytes.base64EncodedData(), mimeType: mimeType), required: true)
                }
            }
        }
    }

    @Test
    func everyRawByteAndTwoByteCombinationCannotBypassNativeJSONDecoding() throws {
        for byte in UInt8.min...UInt8.max {
            for position in 0..<8 {
                var encoded = Data("AAAAAAAA".utf8)
                encoded[position] = byte
                try Self.expectNativeParity(Self.frame(encoded: encoded))
            }
        }
        for first in UInt8.min...UInt8.max {
            for second in UInt8.min...UInt8.max {
                try Self.expectNativeParity(Self.frame(encoded: Data([first, second, 0x41, 0x41])))
            }
        }
    }

    @Test
    func paddingMalformedBase64AndUTF8UseNativeAcceptanceRules() throws {
        for encoded in [
            "", "A", "AA", "AAA", "AAAA", "=", "==", "===", "====", "A=", "AA=", "AAA=", "AA==", "AB==", "AAA==",
            "AAAA=", "AA=A", "=AAA", "A===", "AAAA====",
        ] {
            try Self.expectNativeParity(Self.frame(encoded: Data(encoded.utf8)))
        }
        let invalid: [[UInt8]] = [
            [0x22], [0x5C], [0x00], [0x09], [0x0A], [0x0D], [0x80], [0xC0, 0xAF],
            [0xC2, 0x85], [0xE0, 0x9F, 0xBF], [0xED, 0xA0, 0x80], [0xEF, 0xBB, 0xBF],
            [0xF0, 0x8F, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80], [0xFF],
        ]
        for bytes in invalid {
            let frame = Self.frame(encoded: Data("AAAA".utf8) + Data(bytes) + Data("AAAA".utf8))
            #expect(WorkerEnvelope(frame: frame) == nil)
            #expect(WorkerEnvelope(frame: Self.frame(encoded: Data("AA==".utf8) + Data(bytes))) == nil)
        }
        for value in ["π", "🙂", "é", "\u{2028}", "\u{2029}", "\u{FEFF}"] {
            #expect(WorkerEnvelope(frame: Self.frame(encoded: Data(value.utf8))) == nil)
        }
    }

    @Test
    func everyUUIDByteAndFixedHeaderByteIsValidated() throws {
        let frame = Self.frame(encoded: Data("/9j/".utf8))
        let payloadStart = Self.prefix.count + 36 + Self.middle.count
        for position in 0..<frame.count where !(payloadStart..<(payloadStart + 4)).contains(position) {
            for byte in UInt8.min...UInt8.max {
                var changed = frame
                changed[position] = byte
                try Self.expectNativeParity(changed)
            }
        }
        for count in 0..<frame.count {
            #expect(WorkerEnvelope(frame: Data(frame.prefix(count))) == nil)
        }
    }

    @Test
    func unsupportedLayoutsAlwaysUseTheOriginalDecoder() throws {
        let bodies = [
            #"{"type":"image","mimeType":"image/jpeg","data":"/9j/"}"#,
            #"{"data":"/9j/","type":"image","mimeType":"image/jpeg"}"#,
            #"{"type":"image","data":"\/9j/","mimeType":"image/jpeg"}"#,
            #"{"type":"image","data":"\u002f9j/","mimeType":"image/jpeg"}"#,
            #"{"type":"image","data":"/9j/","mimeType":"image\u002fjpeg"}"#,
            #"{"type":"image","data":"/9j/","mimeType":"image/jpeg","itemID":"named"}"#,
            #"{"type":"image","data":"/9j/","mimeType":"image/jpeg","extra":null}"#,
            #"{"type":"image","data":"/9j/","data":"AAAA","mimeType":"image/jpeg"}"#,
            #"{"type":"image","data":"/9j/","mimeType":"image/avif"}"#,
        ]
        for body in bodies {
            let source = "{\"output\":{\"executionID\":\"\(Self.id)\",\"content\":\(body)}}"
            let frame = Data(source.utf8)
            #expect(WorkerEnvelope(frame: frame) == nil)
            try Self.expectEventParity(frame)
        }
        let valid = Self.frame(encoded: Data("/9j/".utf8))
        let noncanonical: [Data] = [
            Data([0x20]) + valid,
            Data([0xEF, 0xBB, 0xBF]) + valid,
            valid + Data([0x20]),
            valid + Data([0x0A]),
            valid + Data([0x00]),
            valid + valid,
        ]
        for frame in noncanonical {
            #expect(WorkerEnvelope(frame: frame) == nil)
        }
    }

    @Test
    func nonzeroDataIndicesAndLargePayloadsKeepCoreValidation() throws {
        let signatures = [
            "image/png": Data([137, 80, 78, 71, 13, 10, 26, 10]),
            "image/jpeg": Data([255, 216, 255]),
            "image/gif": Data("GIF89a".utf8),
            "image/webp": Data("RIFF0000WEBP".utf8),
        ]
        for mimeType in Self.mimeTypes {
            let bytes = try #require(signatures[mimeType])
            let frame = Self.frame(encoded: bytes.base64EncodedData(), mimeType: mimeType)
            let padded = Data(repeating: 0xFF, count: 7) + frame + Data(repeating: 0xFF, count: 9)
            let slice = padded[7..<(7 + frame.count)]
            #expect(slice.startIndex == 7)
            try Self.expectNativeParity(slice, required: true)
            var removed = Data(repeating: 0xFF, count: 3) + frame
            removed.removeFirst(3)
            try Self.expectNativeParity(removed, required: true)
            let content = try Self.output(WorkerEvent(frame: slice))
            #expect(try content.validatedContent() == .image(data: bytes, mimeType: mimeType))
        }
        var maximum = Data(repeating: 0xA5, count: 8 * 1_024 * 1_024)
        maximum.replaceSubrange(0..<3, with: [255, 216, 255])
        let largest = Self.frame(encoded: maximum.base64EncodedData())
        try Self.expectNativeParity(largest, required: true)
        #expect(
            try Self.output(WorkerEvent(frame: largest)).validatedContent()
                == .image(data: maximum, mimeType: "image/jpeg"))
        maximum.append(0)
        let oversized = try Self.output(WorkerEvent(frame: Self.frame(encoded: maximum.base64EncodedData())))
        do {
            _ = try oversized.validatedContent()
            Issue.record("Expected existing Core image-size validation")
        } catch {
            #expect(error as? REPLError == .protocolViolation("Worker returned invalid or oversized image content."))
        }
        let mismatched = try Self.output(
            WorkerEvent(frame: Self.frame(encoded: Data([255, 216, 255]).base64EncodedData(), mimeType: "image/png")))
        do {
            _ = try mismatched.validatedContent()
            Issue.record("Expected existing Core MIME validation")
        } catch {
            #expect(error as? REPLError == .protocolViolation("Image bytes do not match a supported MIME type."))
        }
    }

    private static func frame(encoded: Data, mimeType: String = "image/jpeg") -> Data {
        prefix + Data(id.utf8) + middle + encoded + Data("\",\"mimeType\":\"\(mimeType)\"}}}".utf8)
    }

    private static func output(_ event: WorkerEvent) throws -> WorkerContent {
        guard case .output(_, let content) = event else {
            throw REPLError.protocolViolation("Expected output fixture")
        }
        return content
    }

    private static func expectNativeParity(_ frame: Data, required: Bool = false) throws {
        let recognized = WorkerEnvelope(frame: frame)
        if required {
            _ = try #require(recognized)
        }
        guard let recognized else {
            return
        }
        guard case .image(let executionID, let bytes, let mimeType) = recognized else {
            Issue.record("Expected image fixture")
            return
        }
        let native = try JSONDecoder().decode(WorkerEvent.self, from: frame)
        guard case .output(let id, let content) = native else {
            Issue.record("Fast image accepted a non-output JSON frame")
            return
        }
        #expect(executionID == id)
        #expect(content.type == .image)
        #expect(content.data == bytes)
        #expect(content.mimeType == mimeType)
        #expect(content.text == nil)
        #expect(content.itemID == nil)
        try Self.expectEventParity(frame)
    }

    private static func expectEventParity(_ frame: Data) throws {
        let native = try Self.output(JSONDecoder().decode(WorkerEvent.self, from: frame))
        let optimized = try Self.output(WorkerEvent(frame: frame))
        #expect(native.type == optimized.type)
        #expect(native.data == optimized.data)
        #expect(native.mimeType == optimized.mimeType)
        #expect(native.text == optimized.text)
        #expect(native.itemID == optimized.itemID)
    }
}
