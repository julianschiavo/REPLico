import ReplicoCore
import Foundation
import Testing

struct JSONValueTests {
    @Test
    func preservesOpaquePolicyValues() throws {
        let data = Data("{\"unknown\":[18446744073709551615,true,null,\"🦊\"],\"profile\":{\"enabled\":false}}".utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["unknown"]?.arrayValue?.first == .unsignedInteger(UInt64.max))
        #expect(value["profile"]?["enabled"] == .bool(false))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(
            String(decoding: try encoder.encode(value), as: UTF8.self)
                == "{\"profile\":{\"enabled\":false},\"unknown\":[18446744073709551615,true,null,\"🦊\"]}")
    }

    @Test
    func nonfiniteNumbersAreRejectedEvenWithAPermissiveEncoder() throws {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        for value in [Double.infinity, -Double.infinity, .nan] {
            #expect(throws: EncodingError.self) {
                try encoder.encode(JSONValue.number(value))
            }
        }
    }

}
