import ReplicoOptimizations
import Foundation
import Testing

struct CanonicalToolCallHeaderTests {
    @Test
    func reusingAValidatedHeaderChecksTheNewIDAndEveryParameterByte() throws {
        let parameters = #"{"text":"\u0000","ignored":true}"#
        let previous = try #require(CanonicalToolCallHeader(frame: frame("1", params: parameters)))
        let repeatCall = CanonicalToolCallHeader(frame: frame("2", params: parameters), reusing: previous)
        #expect(repeatCall?.id == 2)
        #expect(repeatCall?.parameters == previous.parameters)
        #expect(CanonicalToolCallHeader(frame: frame("02", params: parameters), reusing: previous) == nil)

        let changed = #"{"text":"\u0001","ignored":true}"#
        let next = CanonicalToolCallHeader(frame: frame("3", params: changed), reusing: previous)
        #expect(next?.parameters == Data(changed.utf8))
        let malformed = #"{"text":"\u000G","ignored":true}"#
        #expect(CanonicalToolCallHeader(frame: frame("4", params: malformed), reusing: previous) == nil)
    }

    @Test(arguments: [
        UInt64(0), 1, 9, 10, UInt64(Int64.max) - 1, UInt64(Int64.max), UInt64(Int64.max) + 1,
        UInt64.max - 1, UInt64.max,
    ])
    func unsignedDecimalBoundariesRemainLossless(_ id: UInt64) {
        #expect(CanonicalToolCallHeader(frame: frame(String(id)))?.id == id)
    }

    @Test(arguments: [
        "-1", "-0", "-9223372036854775808", "+1", "01", "00", "1.0", "1e0", "1E+2", "",
        #""1""#, "null", "true", "18446744073709551616", "99999999999999999999999999999999999",
    ])
    func noncanonicalOrUnrepresentableIDsUseTheOriginalPath(_ id: String) {
        #expect(CanonicalToolCallHeader(frame: frame(id)) == nil)
    }

    @Test(arguments: [
        #" {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#,
        #"{"jsonrpc":"2.0","id": 1,"method":"tools/call","params":{}}"#,
        #"{"id":1,"jsonrpc":"2.0","method":"tools/call","params":{}}"#,
        #"{"jsonrpc":"1.0","id":1,"method":"tools/call","params":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/\u0063all","params":{}}"#,
        #"{"jsonrpc":"2.0","\u0069d":1,"method":"tools/call","params":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[]}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":null}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}} "#,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{},"id":2}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{},"extra":true}"#,
        #"{"jsonrpc":"2.0","id":1,"id":2,"method":"tools/call","params":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","extra":{},"params":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}},{}"#,
    ])
    func extraDuplicateOrUnsupportedRootLayoutsNeverQualify(_ source: String) {
        #expect(CanonicalToolCallHeader(frame: Data(source.utf8)) == nil)
    }

    @Test(arguments: [
        "{}", #"{"id":2,"id":3,"method":"ping"}"#,
        #"{"text":"},\"id\":2,\"params\":{","nested":{"id":9},"array":["}","{"]}"#,
        #"{"text":"🙂 café 漢字","escaped":"\u0000\uD83D\uDE00","ignored":1e400}"#,
        #"{ "ignored" : [ true, null, {"huge":-1E-9999999} ] }"#,
    ])
    func completeParamsObjectsRetainStringsAndIgnoredNumberLexemes(_ params: String) throws {
        let data = frame("7", params: params)
        #expect(CanonicalToolCallHeader(frame: data)?.id == 7)
        #expect(try JSONDocument(validating: data).data == data)
    }

    @Test(arguments: [
        #"{"ignored":"\q"}"#, #"{"ignored":"\uD800"}"#, #"{"ignored":"\uDC00"}"#,
        #"{"ignored":[1,]}"#, #"{"ignored":1e}"#, #"{"ignored":01}"#, #"{"ignored":NaN}"#,
        #"{},"id":2"#, #"{} {}"#, #"{"incomplete":{}"#,
    ])
    func malformedParamsNeverBypassFullFrameValidation(_ params: String) {
        #expect(CanonicalToolCallHeader(frame: frame("1", params: params)) == nil)
    }

    @Test
    func enclosingDepthCountsTheRootContainerExactly() throws {
        for totalDepth in [511, 512, 513] {
            let count = totalDepth - 2
            let params =
                "{\"ignored\":" + String(repeating: "[", count: count) + "1e400"
                + String(repeating: "]", count: count) + "}"
            let data = frame("1", params: params)
            #expect((CanonicalToolCallHeader(frame: data) != nil) == (totalDepth <= 512))
            if totalDepth <= 512 {
                #expect(try JSONDocument(validating: data).data == data)
            } else {
                #expect(throws: DecodingError.self) {
                    try JSONDocument(validating: data)
                }
            }
        }
        for depth in [-1, 513] {
            #expect(throws: DecodingError.self) {
                try JSONDocument(validating: Data("0".utf8), enclosingContainers: depth)
            }
        }
        #expect(try JSONDocument(validating: Data("0".utf8), enclosingContainers: 512).data == Data("0".utf8))
    }

    @Test
    func malformedUTF8AndRawControlsRemainRejectedInsideTheParamsSlice() {
        for scalar in [[0x00], [0x1F], [0x80], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]] {
            var data = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"bad":""#.utf8)
            data.append(contentsOf: scalar.map(UInt8.init))
            data.append(contentsOf: #""}}"#.utf8)
            #expect(CanonicalToolCallHeader(frame: data) == nil)
        }
    }

    @Test
    func nonzeroDataIndicesAndOwnedIDsArePreserved() {
        let original = frame(String(UInt64.max), params: #"{"text":"🙂\uD83D\uDE00"}"#)
        for offset in 1...17 {
            var storage = Data(repeating: 0, count: offset)
            storage.append(original)
            storage.append(0xFF)
            let slice = storage[offset..<(storage.count - 1)]
            #expect(CanonicalToolCallHeader(frame: slice)?.id == UInt64.max)
        }
        var mutable = original
        let header = CanonicalToolCallHeader(frame: mutable)
        mutable[0] = 0
        #expect(header?.id == UInt64.max)
    }

    private func frame(_ id: String, params: String = "{}") -> Data {
        Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":\#(params)}"#.utf8)
    }
}
