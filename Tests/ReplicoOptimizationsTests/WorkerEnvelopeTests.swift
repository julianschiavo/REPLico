import ReplicoOptimizations
import Foundation
import Testing

struct WorkerEnvelopeTests {
    private enum NativeEvent: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String
        }

        struct Failure: Decodable {
            let message: String
        }

        case output(executionID: String, content: Content)
        case completed(executionID: String, succeeded: Bool, error: Failure?)
    }

    private static let id = "01234567-89AB-CDEF-0123-456789abcdef"
    private static let prefix = Data(#"{"output":{"executionID":""#.utf8)
    private static let middle = Data(#"","content":{"type":"text","text":""#.utf8)
    private static let suffix = Data(#""}}}"#.utf8)

    @Test(arguments: [
        "", "plain text", " / {} [] , : true false null ", "é e\u{301} 🙂 漢字", "\u{7F}\u{80}\u{2028}\u{2029}",
        "\u{FEFF}", "\u{FEFF}text", "text\u{FEFF}",
    ])
    func plainTextMatchesFoundation(_ text: String) throws {
        try Self.expectMatches(Self.frame(text: Data(text.utf8)))
    }

    @Test
    func plainTextAcrossVectorWordAndTailLengthsMatchesFoundation() throws {
        for length in 0..<160 {
            try Self.expectMatches(Self.frame(text: Data(repeating: 0x61, count: length)))
        }
        try Self.expectMatches(Self.frame(text: Data(repeating: 0x78, count: 1_048_576)))
    }

    @Test
    func everyByteClassIsCheckedAtEveryVectorLane() throws {
        for byte in UInt8.min...UInt8.max {
            for lane in 0..<32 {
                let text = Data(repeating: 0x61, count: 32 + lane) + Data([byte]) + Data(repeating: 0x61, count: 32)
                let frame = Self.frame(text: text)
                if (0x20...0x7F).contains(byte), byte != 0x22, byte != 0x5C {
                    try Self.expectMatches(frame)
                } else {
                    #expect(WorkerEnvelope(frame: frame) == nil)
                }
            }
        }
    }

    @Test
    func byteChecksCoverVectorWordAndScalarTails() throws {
        for byte in UInt8.min...UInt8.max {
            for length in 0..<32 {
                let frame = Self.frame(text: Data(repeating: 0x61, count: length) + Data([byte]))
                if (0x20...0x7F).contains(byte), byte != 0x22, byte != 0x5C {
                    try Self.expectMatches(frame)
                } else {
                    #expect(WorkerEnvelope(frame: frame) == nil)
                }
            }
        }
    }

    @Test
    func nativeUTF8ValidationAcceptsScalarBoundariesAcrossVectorLanes() throws {
        let scalars: [[UInt8]] = [
            [0xC2, 0x80], [0xDF, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF],
            [0xEE, 0x80, 0x80], [0xEF, 0xBB, 0xBF], [0xEF, 0xBF, 0xBF],
            [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF],
        ]
        for scalar in scalars {
            for lane in 0..<32 {
                let text = Data(repeating: 0x61, count: 32 + lane) + Data(scalar) + Data(repeating: 0x61, count: 32)
                try Self.expectMatches(Self.frame(text: text))
            }
        }
    }

    @Test
    func malformedUTF8AndOverlongOrSurrogateEncodingsUseFallback() {
        let invalid: [[UInt8]] = [
            [0x80], [0xC0, 0xAF], [0xC1, 0xBF], [0xC2], [0xE0, 0x9F, 0xBF], [0xE1, 0x80],
            [0xED, 0xA0, 0x80], [0xEF, 0xBF], [0xF0, 0x8F, 0xBF, 0xBF], [0xF1, 0x80, 0x80],
            [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xFF],
        ]
        for scalar in invalid {
            for lane in 0..<32 {
                let text = Data(repeating: 0x61, count: 32 + lane) + Data(scalar) + Data(repeating: 0x61, count: 32)
                #expect(WorkerEnvelope(frame: Self.frame(text: text)) == nil)
            }
        }
    }

    @Test
    func everyUUIDByteMustHaveItsCanonicalClass() throws {
        for position in 0..<36 {
            for byte in UInt8.min...UInt8.max {
                var id = Array(Self.id.utf8)
                id[position] = byte
                let frame = Self.frame(id: Data(id), text: Data("text".utf8))
                let accepted: Bool
                if [8, 13, 18, 23].contains(position) {
                    accepted = byte == 0x2D
                } else {
                    accepted =
                        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
                }
                if accepted {
                    try Self.expectMatches(frame)
                } else {
                    #expect(WorkerEnvelope(frame: frame) == nil)
                }
            }
        }
        for id in ["", String(Self.id.dropLast()), Self.id + "0", Self.id.replacingOccurrences(of: "-", with: "")] {
            #expect(WorkerEnvelope(frame: Self.frame(id: Data(id.utf8), text: Data())) == nil)
        }
    }

    @Test
    func everyFixedLayoutByteIsRequired() {
        let frame = Self.frame(text: Data("text".utf8))
        let middleStart = Self.prefix.count + 36
        let textStart = middleStart + Self.middle.count
        for offset in 0..<frame.count
        where offset < Self.prefix.count
            || (middleStart..<textStart).contains(offset)
            || offset >= frame.count - Self.suffix.count
        {
            var changed = frame
            changed[offset] ^= 1
            #expect(WorkerEnvelope(frame: changed) == nil)
        }
        for count in 0..<frame.count {
            #expect(WorkerEnvelope(frame: Data(frame.prefix(count))) == nil)
        }
    }

    @Test(arguments: [
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":"nul\u0000text"}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":"\uD83D\uDE00"}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":"\uD800"}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":"one","text":"two"}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":"x","itemID":"named"}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":"x","extra":null}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"text":"x","type":"text"}}}"#,
        #"{"output":{"content":{"type":"text","text":"x"},"executionID":"01234567-89AB-CDEF-0123-456789abcdef"}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","executionID":"second","content":{"type":"text","text":"x"}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"image","text":"x"}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":null}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text"}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":{"nested":"x"}}}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":"x"}},"completed":{"executionID":"e","succeeded":true}}"#,
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":"x"}}}{}"#,
    ])
    func unsupportedShapesAndEscapesUseFallback(_ source: String) {
        #expect(WorkerEnvelope(frame: Data(source.utf8)) == nil)
    }

    @Test
    func framingWhitespaceAndNULUseFallback() {
        let frame = Self.frame(text: Data("text".utf8))
        for prefix in [Data([0x20]), Data([0xEF, 0xBB, 0xBF])] {
            #expect(WorkerEnvelope(frame: prefix + frame) == nil)
        }
        for suffix in [Data([0x20]), Data([0x0A]), Data([0x00])] {
            #expect(WorkerEnvelope(frame: frame + suffix) == nil)
        }
        #expect(WorkerEnvelope(frame: Self.frame(text: Data([0x00]))) == nil)
        #expect(WorkerEnvelope(frame: Self.frame(text: Data(#"x"}}},"injected":true,"text":"y"#.utf8))) == nil)
    }

    @Test
    func nonzeroDataIndicesAreHandled() throws {
        for frame in [Self.frame(text: Data("é🙂 text".utf8)), Self.completion(id: Data(Self.id.utf8))] {
            let padded = Data(repeating: 0xFF, count: 7) + frame + Data(repeating: 0xFF, count: 9)
            let slice = padded[7..<(7 + frame.count)]
            #expect(slice.startIndex == 7)
            try Self.expectMatches(slice)
            var removed = Data(repeating: 0xFF, count: 3) + frame
            removed.removeFirst(3)
            #expect(removed.startIndex != 0)
            try Self.expectMatches(removed)
        }
    }

    @Test
    func generatedPlainFramesPreserveEveryAcceptedValue() throws {
        var generator: UInt64 = 0xA6E8_0231_4379_BD05
        let hex = Array("0123456789ABCDEFabcdef".utf8)
        for sample in 0..<384 {
            var id = Array(Self.id.utf8)
            for position in 0..<36 where ![8, 13, 18, 23].contains(position) {
                generator = generator &* 6_364_136_223_846_793_005 &+ 1
                id[position] = hex[Int(generator % UInt64(hex.count))]
            }
            var text: [UInt8] = []
            for _ in 0..<(sample * 13 % 1_027) {
                generator = generator &* 6_364_136_223_846_793_005 &+ 1
                let byte = UInt8(0x20 + generator % 96)
                text.append(byte == 0x22 || byte == 0x5C ? 0x2F : byte)
            }
            try Self.expectMatches(Self.frame(id: Data(id), text: Data(text)))
            try Self.expectMatches(Self.completion(id: Data(id)))
        }
    }

    @Test
    func successfulCompletionRequiresTheCanonicalUUIDAndEveryFixedByte() throws {
        let completion = Self.completion(id: Data(Self.id.utf8))
        try Self.expectMatches(completion)
        for position in 0..<36 {
            for byte in UInt8.min...UInt8.max {
                var id = Array(Self.id.utf8)
                id[position] = byte
                let frame = Self.completion(id: Data(id))
                let accepted: Bool
                if [8, 13, 18, 23].contains(position) {
                    accepted = byte == 0x2D
                } else {
                    accepted =
                        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
                }
                if accepted {
                    try Self.expectMatches(frame)
                } else {
                    #expect(WorkerEnvelope(frame: frame) == nil)
                }
            }
        }
        let prefixCount = Data(#"{"completed":{"executionID":""#.utf8).count
        for offset in 0..<completion.count where !(prefixCount..<(prefixCount + 36)).contains(offset) {
            var changed = completion
            changed[offset] ^= 1
            #expect(WorkerEnvelope(frame: changed) == nil)
        }
        for count in 0..<completion.count {
            #expect(WorkerEnvelope(frame: Data(completion.prefix(count))) == nil)
        }
    }

    @Test(arguments: [
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":false}}"#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":1}}"#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":"true"}}"#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":null}}"#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":true,"error":null}}"#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":true,"error":{"message":"failed"}}}"#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":true,"extra":1}}"#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":true,"succeeded":true}}"#,
        #"{"completed":{"succeeded":true,"executionID":"01234567-89AB-CDEF-0123-456789abcdef"}}"#,
        #"{"completed":{"executionID":"short","succeeded":true}}"#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcde\u0066","succeeded":true}}"#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":true}} "#,
        #"{"completed":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","succeeded":true}}{}"#,
    ])
    func noncanonicalCompletionsUseFoundationFallback(_ source: String) {
        #expect(WorkerEnvelope(frame: Data(source.utf8)) == nil)
    }

    private static func frame(text: Data) -> Data {
        frame(id: Data(id.utf8), text: text)
    }

    private static func frame(id: Data, text: Data) -> Data {
        prefix + id + middle + text + suffix
    }

    private static func completion(id: Data) -> Data {
        Data(#"{"completed":{"executionID":""#.utf8) + id + Data(#"","succeeded":true}}"#.utf8)
    }

    private static func expectMatches(_ frame: Data) throws {
        let recognized = try #require(WorkerEnvelope(frame: frame))
        let native = try JSONDecoder().decode(NativeEvent.self, from: frame)
        switch recognized {
        case .text(let executionID, let text):
            guard case .output(let id, let content) = native else {
                Issue.record("Expected a native output event")
                return
            }
            #expect(content.type == "text")
            #expect(Data(executionID.utf8) == Data(id.utf8))
            #expect(Data(text.utf8) == Data(content.text.utf8))
        case .image:
            Issue.record("Expected a text or completion fixture")
        case .completed(let executionID):
            guard case .completed(let id, let succeeded, let error) = native else {
                Issue.record("Expected a native completion event")
                return
            }
            #expect(Data(executionID.utf8) == Data(id.utf8))
            #expect(succeeded)
            #expect(error == nil)
        }
    }
}
