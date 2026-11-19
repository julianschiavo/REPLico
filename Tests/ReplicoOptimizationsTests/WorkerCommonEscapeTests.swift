@testable import ReplicoCore
import ReplicoOptimizations
import Foundation
import Testing

struct WorkerCommonEscapeTests {
    private static let id = "01234567-89AB-CDEF-0123-456789abcdef"
    private static let prefix = Data(
        #"{"output":{"executionID":"01234567-89AB-CDEF-0123-456789abcdef","content":{"type":"text","text":""#.utf8)
    private static let suffix = Data(#""}}}"#.utf8)
    private static let escapes = [#"\""#, #"\\"#, #"\/"#, #"\b"#, #"\f"#, #"\n"#, #"\r"#, #"\t"#]

    @Test
    func everyASCIIPairRetainsNativeAcceptanceAndValues() throws {
        for first in UInt8(0)..<128 {
            for second in UInt8(0)..<128 {
                try Self.expectNativeParity(Self.frame(Data([first, second])))
            }
        }
        for first in Self.escapes {
            for second in Self.escapes {
                try Self.expectNativeParity(Self.frame(Data((first + second).utf8)), required: true)
            }
        }
    }

    @Test
    func shortEscapesAcrossVectorWordsAndTailsPreserveUnicodeAndBOM() throws {
        for offset in 0...65 {
            for escape in Self.escapes {
                for ending in ["", "x", "café", "漢字", "🙂", "e\u{301}", "\u{FEFF}"] {
                    let body = Data(("\u{FEFF}" + String(repeating: "x", count: offset) + escape + ending).utf8)
                    let original = Self.frame(body)
                    try Self.expectNativeParity(original, required: true)
                    let padded = Data(repeating: 0xFF, count: 7) + original + Data([0xFF])
                    let slice = padded[7..<(7 + original.count)]
                    #expect(slice.startIndex == 7)
                    try Self.expectNativeParity(slice, required: true)
                }
            }
        }
    }

    @Test
    func unicodeEscapesAndMalformedBodiesKeepWholeEventFallback() throws {
        let unsupported = [
            #"\u0000"#, #"\u001f"#, #"\u007f"#, #"\u0080"#, #"\uFEFF"#,
            #"\uD83D\uDE00"#, #"\uD800"#, #"\uDC00"#, #"\uD800\u0041"#,
            #"\q"#, #"\x00"#, #"\U0000"#, "\\", #"line\n\u0041"#,
            #"x","itemID":"named"#, #"x","text":"other"#, #"x" "other"#,
            #"x",null,"other"#, #"x"//comment"#, #"x"}}},"injected":true,"text":"y"#,
        ]
        for body in unsupported {
            #expect(WorkerEnvelope(frame: Self.frame(Data(body.utf8))) == nil)
        }
        let malformed: [[UInt8]] = [
            [0x00], [0x1F], [0x22], [0x80], [0xC0, 0xAF], [0xC2], [0xED, 0xA0, 0x80],
            [0xF0, 0x8F, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80], [0xFF],
        ]
        for offset in 0...65 {
            for invalid in malformed {
                let body = Data((String(repeating: "x", count: offset) + #"\n"#).utf8) + Data(invalid)
                #expect(WorkerEnvelope(frame: Self.frame(body)) == nil)
            }
        }
    }

    @Test
    func nativeEncodedStringsKeepCompleteDecodedBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for text in [
            "line\nnext\t\"quoted\"\\path\r\n", "\u{FEFF}leading\u{FEFF}\ntrailing",
            "café\n漢字\t🙂 e\u{301}", String(repeating: "branch \"entry\"\n  leaf\\path\t42\n", count: 2_048),
        ] {
            let quoted = try encoder.encode(text)
            try Self.expectNativeParity(Self.frame(Data(quoted.dropFirst().dropLast())), required: true)
        }
    }

    private static func frame(_ body: Data) -> Data {
        prefix + body + suffix
    }

    private static func expectNativeParity(_ frame: Data, required: Bool = false) throws {
        let recognized = WorkerEnvelope(frame: frame)
        if required {
            _ = try #require(recognized)
        }
        guard let recognized else {
            return
        }
        guard case .text(let executionID, let text) = recognized else {
            Issue.record("Expected a canonical text event")
            return
        }
        let native = try JSONDecoder().decode(WorkerEvent.self, from: frame)
        guard case .output(let id, let content) = native, let expected = content.text else {
            Issue.record("Recognized text must also be a native text event")
            return
        }
        #expect(executionID == id)
        #expect(executionID == Self.id)
        #expect(content.type == .text)
        #expect(Data(text.utf8) == Data(expected.utf8))
    }
}
