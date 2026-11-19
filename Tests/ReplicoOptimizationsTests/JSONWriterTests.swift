import Foundation
import Testing

@testable import ReplicoOptimizations

@Suite
struct JSONWriterTests {
    @Test
    func stringsPreserveControlsAndUnicodeAcrossVectorBoundaries() throws {
        let special = "\u{0}\u{1}\u{8}\t\n\u{b}\u{c}\r\u{1f}\"\\/😀界é\u{2028}\u{2029}"
        for padding in 0..<97 {
            let text = String(repeating: "x", count: padding) + special + String(repeating: "界", count: padding)
            var writer = JSONWriter()
            writer.write(text)
            #expect(try JSONDecoder().decode(String.self, from: writer.data) == text)
        }
    }

    @Test
    func allUnicodeScalarsRoundTrip() throws {
        var text = ""
        for value in UInt32(0)...0x10FFFF {
            if let scalar = Unicode.Scalar(value) {
                text.unicodeScalars.append(scalar)
            }
        }
        var writer = JSONWriter()
        writer.write(text)
        #expect(try JSONDecoder().decode(String.self, from: writer.data) == text)
    }

    @Test
    func emptyAndEscapeDenseStringsRemainValidJSON() throws {
        for text in ["", "\"\\\n", String(repeating: "\u{0}\"\\", count: 512)] {
            var writer = JSONWriter()
            writer.write(text)
            #expect(try JSONDecoder().decode(String.self, from: writer.data) == text)
        }
    }

    @Test
    func primitiveValuesKeepTheirFullRepresentation() throws {
        struct Payload: Decodable {
            let lower: Int64
            let upper: UInt64
            let enabled: Bool
            let disabled: Bool
        }

        var writer = JSONWriter()
        writer.writeSyntax("{\"lower\":")
        writer.write(Int64.min)
        writer.writeSyntax(",\"upper\":")
        writer.write(UInt64.max)
        writer.writeSyntax(",\"enabled\":")
        writer.write(true)
        writer.writeSyntax(",\"disabled\":")
        writer.write(false)
        writer.writeSyntax("}")
        let decoded = try JSONDecoder().decode(Payload.self, from: writer.data)
        #expect(decoded.lower == Int64.min)
        #expect(decoded.upper == UInt64.max)
        #expect(decoded.enabled)
        #expect(!decoded.disabled)
    }

    @Test
    func everyASCIIByteAcrossTwoVectorBlocksMatchesFoundationBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for byte in UInt8.min...127 {
            for lane in 0..<64 {
                let text =
                    String(repeating: "x", count: lane) + String(Unicode.Scalar(byte))
                    + String(repeating: "x", count: 96 - lane)
                var writer = JSONWriter()
                writer.write(text)
                let expected = try encoder.encode(text)
                #expect(writer.data == expected)
            }
        }
    }

    @Test
    func mixedUnicodeAndEscapesRetainExactBytesAcrossBlockTails() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for size in 0..<160 {
            for special in ["\u{FEFF}", "é", "🙂", "漢", "\u{2028}", "\u{0}\"\\\n", "\u{7F}"] {
                let text = String(repeating: "x", count: size) + special + String(repeating: "界", count: size)
                var writer = JSONWriter()
                writer.write(text)
                #expect(writer.data == (try encoder.encode(text)))
            }
        }
    }

    @Test
    func everyEscapeRetainsFoundationBytesAcrossEveryTail() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let controls = String((UInt8(0)...31).map { Character(Unicode.Scalar($0)) }) + "\"\\"
        for padding in 0..<97 {
            let text = String(repeating: "界", count: padding) + controls + String(repeating: "x", count: padding)
            var candidate = JSONWriter()
            candidate.write(text)
            #expect(candidate.data == (try encoder.encode(text)))
        }
    }

    @Test
    func denseEscapesRetainEveryByteIncludingNulAndBOM() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for text in [
            String(repeating: "\u{0}\"\\", count: 512),
            String(repeating: "\t\n", count: 4096),
            "\u{FEFF}\u{0}\u{1F}🙂\r\n",
        ] {
            var writer = JSONWriter()
            writer.write(text)
            #expect(writer.data == (try encoder.encode(text)))
            #expect(try JSONDecoder().decode(String.self, from: writer.data) == text)
        }
    }
}
