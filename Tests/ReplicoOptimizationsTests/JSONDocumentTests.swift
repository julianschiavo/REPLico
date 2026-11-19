import ReplicoOptimizations
import Foundation
import Testing

struct JSONDocumentTests {
    @Test(arguments: [
        "null", "true", "false", "0", "-0", "123", "-123", "1.25", "1e400", "-1E-400", "0.01e+003",
        #""text""#, #""🙂 café 漢字""#, #""\"\\\/\b\f\n\r\t\u0000\u0041\uD83D\uDE00""#,
        "[]", "{}", #"[null,true,2.0,"text",{}]"#, #"{"nested":[{"x":1}],"huge":1e400}"#,
        #"{"x":1,"x":2}"#, " \n\r\t {\"x\":0}\t",
    ])
    func validSyntaxRetainsItsOriginalBytes(_ source: String) throws {
        let data = Data(source.utf8)
        let document = try JSONDocument(validating: data)
        #expect(document.data == data)
    }

    @Test(arguments: [
        "", " ", "tru", "falsex", "NULL", "NaN", "Infinity", "+1", "01", "-01", ".1", "1.", "1e", "1e+", "1e-", "-",
        "[,]", "[1,]", "[1 2]", #"{"a":1,}"#, #"{"a" 1}"#, #"{a:1}"#, #"{"a":}"#, "{} {}", "1 2",
        #""unterminated"#, #""\q""#, #""\uD800""#, #""\uDC00""#, #""\uD800\u0041""#,
        #""\uD800 \uDC00""#, #""\uD800\\uDC00""#, #""\u""#, #""\u123""#, #""\uZZZZ""#, #""\U1234""#,
        #"{"\q":1}"#, "\"line\nbreak\"", #"/* comment */ {}"#,
    ])
    func invalidSyntaxThrowsADecodingError(_ source: String) {
        #expect(throws: DecodingError.self) {
            try JSONDocument(validating: Data(source.utf8))
        }
    }

    @Test(
        arguments: [
            [0x7F], [0xC2, 0x80], [0xDF, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF],
            [0xEE, 0x80, 0x80], [0xEF, 0xBF, 0xBF], [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF],
        ] as [[UInt8]])
    func rawUTF8ScalarBoundariesAreAccepted(_ scalar: [UInt8]) throws {
        let data = Data([0x22] + scalar + [0x22])
        #expect(try JSONDocument(validating: data).data == data)
    }

    @Test(
        arguments: [
            [0x00], [0x1F], [0x80], [0xC0, 0xAF], [0xC1, 0xBF], [0xC2], [0xE0, 0x9F, 0xBF],
            [0xE1, 0x80], [0xED, 0xA0, 0x80], [0xEF, 0xBF], [0xF0, 0x8F, 0xBF, 0xBF],
            [0xF1, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xFF],
        ] as [[UInt8]])
    func malformedUTF8AndRawControlsAreRejected(_ scalar: [UInt8]) {
        #expect(throws: DecodingError.self) {
            try JSONDocument(validating: Data([0x22] + scalar + [0x22]))
        }
    }

    @Test
    func stringsAndEscapesCrossWordBoundaries() throws {
        for count in 0..<96 {
            let prefix = String(repeating: "a", count: count)
            let valid = Data(("\"" + prefix + "\\uD83D\\uDE00" + prefix + "\"").utf8)
            #expect(try JSONDocument(validating: valid).data == valid)
            let truncated = Data(("\"" + prefix + "\\uD83D\"").utf8)
            #expect(throws: DecodingError.self) {
                try JSONDocument(validating: truncated)
            }
            let badControl = Data([0x22] + Array(prefix.utf8) + [0x01] + Array(prefix.utf8) + [0x22])
            #expect(throws: DecodingError.self) {
                try JSONDocument(validating: badControl)
            }
        }
    }

    @Test
    func everyByteIsValidatedWithinLongASCIIStrings() throws {
        for byte in UInt8.min...UInt8.max {
            for offset in 0..<8 {
                let data = Data(
                    [0x22] + Array(repeating: 0x61, count: 32 + offset)
                        + [byte] + Array(repeating: 0x61, count: 32) + [0x22]
                )
                if (0x20...0x7F).contains(byte), byte != 0x22, byte != 0x5C {
                    #expect(try JSONDocument(validating: data).data == data)
                } else {
                    #expect(throws: DecodingError.self) {
                        try JSONDocument(validating: data)
                    }
                }
            }
        }
    }

    @Test
    func nestingIsBoundedWithoutRestrictingNumberRange() throws {
        let valid = Data((String(repeating: "[", count: 512) + "1e400" + String(repeating: "]", count: 512)).utf8)
        #expect(try JSONDocument(validating: valid).data == valid)
        let excessive = Data((String(repeating: "[", count: 513) + "0" + String(repeating: "]", count: 513)).utf8)
        #expect(throws: DecodingError.self) {
            try JSONDocument(validating: excessive)
        }
    }

    @Test
    func validationDoesNotNormalizeOrBorrowMutableData() throws {
        var data = Data(#"{"key":"\u0041"}"#.utf8)
        let original = data
        let document = try JSONDocument(validating: data)
        data[0] = 0
        #expect(document.data == original)
    }

    @Test
    func largePlainAndUnicodeStringsRetainTheirBytes() throws {
        for body in [String(repeating: "x", count: 1_048_576), String(repeating: "🙂漢", count: 4096)] {
            let data = Data(("\"" + body + "\"").utf8)
            #expect(try JSONDocument(validating: data).data == data)
        }
    }
}
