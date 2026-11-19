import ReplicoKit
import Foundation
import Testing

struct ToolArgumentsTests {
    @ToolArguments
    private struct PrivateArguments: ToolArgumentsProtocol {
        @Argument(description: "An optional flag.")
        let enabled: Bool?
    }

    @ToolArguments
    struct Arguments {
        @Argument(description: "The text supplied by JavaScript.")
        let text: String
        @Argument(description: "Optional repetition counts.")
        let counts: [Int]?
    }

    @Test
    func generatedArgumentsDecodeWireInputAndAdvertiseOptionalFields() throws {
        let arguments = try JSONDecoder().decode(Arguments.self, from: Data(#"{"text":"hello"}"#.utf8))
        #expect(arguments.text == "hello")
        #expect(arguments.counts == nil)
        #expect(Arguments.schema["required"] == .array([.string("text")]))
        #expect(Arguments.schema["properties"]?["text"]?["description"] == .string("The text supplied by JavaScript."))
        let supplied = try JSONDecoder().decode(Arguments.self, from: Data(#"{"text":"hello","counts":[1,2]}"#.utf8))
        #expect(supplied.counts == [1, 2])
        let null = try JSONDecoder().decode(Arguments.self, from: Data(#"{"text":"hello","counts":null}"#.utf8))
        #expect(null.counts == nil)
    }

    @Test
    func privateArgumentsSynthesizeWithinTheirSupportedScopes() throws {
        let value = try JSONDecoder().decode(PrivateArguments.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(value.enabled == true)
        #expect(PrivateArguments.schema["required"] == .array([]))
        let topLevel = try JSONDecoder().decode(TopLevelPrivateArguments.self, from: Data(#"{"value":7}"#.utf8))
        #expect(topLevel.value == 7)
    }

    @Test
    func publicArgumentsPreserveUnsignedIntegersAndRejectWrongWireTypes() throws {
        let value = try JSONDecoder().decode(PublicArguments.self, from: Data(#"{"value":18446744073709551615}"#.utf8))
        #expect(value.value == UInt64.max)
        for request in [#"{"value":1.5}"#, #"{"value":-1}"#, #"{"value":"1"}"#, #"{}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(PublicArguments.self, from: Data(request.utf8))
            }
        }
    }
}

@ToolArguments
private struct TopLevelPrivateArguments {
    @Argument(description: "A top level private argument.")
    let value: Int
}
