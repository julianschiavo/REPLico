import Foundation
import MCP
import Testing

@testable import ReplicoOptimizations

@Suite
struct MCPResponseEncoderTests {
    private struct Envelope<Identifier: Codable, Payload: Codable>: Codable, JSONRPCEnvelope {
        let jsonrpc: String
        let id: Identifier
        let result: Payload?
        let error: MCPError?

        init(id: Identifier, result: Payload?, error: MCPError? = nil, version: String = "2.0") {
            jsonrpc = version
            self.id = id
            self.result = result
            self.error = error
        }
    }

    @Test
    func segmentedFramesReuseOnlyExactStorageAndPreserveEveryWireByte() throws {
        let decomposed = String(repeating: "e\u{301}\"\\\n", count: 15_000)
        let otherStorage = String(decoding: Array(decomposed.utf8), as: UTF8.self)
        let composed = String(repeating: "é\"\\\n", count: 15_000)
        var encoder = MCPResponseEncoder()
        func encode(_ text: String, id: String, flag: Bool?) throws -> MCPResponseEncoder.Frame? {
            let item = Tool.Content.text(text: text, annotations: nil, _meta: nil)
            let response = Envelope(id: id, result: CallTool.Result(content: [item], isError: flag))
            let outcome = try encoder.frame(for: response)
            let regular = try MCPResponseEncoder().encode(response) + Data([10])
            switch outcome {
            case .segments(let header, let body):
                #expect(Data(header.readableBytesView) + Data(body.readableBytesView) == regular)
            case .contiguous(let bytes):
                #expect(Data(bytes.readableBytesView) == regular)
            case nil:
                break
            }
            return outcome
        }
        let first = try encode(decomposed, id: "first", flag: false)
        #expect(first == nil)
        let second = try encode(decomposed, id: "second\u{0}😀", flag: false)
        let third = try encode(decomposed, id: "third", flag: false)
        let fourth = try encode(decomposed, id: "fourth", flag: false)
        guard case .contiguous(let seed) = second, case .segments(_, let body) = third,
            case .segments(_, let next) = fourth
        else {
            Issue.record("Expected a contiguous seed frame followed by two shared body segments.")
            return
        }
        let seedBody = try #require(
            seed.getSlice(at: seed.readableBytes - body.readableBytes, length: body.readableBytes))
        let firstReuse = body.readableBytesSpan.isTriviallyIdentical(to: seedBody.readableBytesSpan)
        let secondReuse = body.readableBytesSpan.isTriviallyIdentical(to: next.readableBytesSpan)
        #expect(firstReuse)
        #expect(secondReuse)
        let independent = try encode(otherStorage, id: "independent", flag: false)
        let normalized = try encode(composed, id: "normalized", flag: false)
        let failed = try encode(composed, id: "failed", flag: true)
        let unspecified = try encode(composed, id: "unspecified", flag: nil)
        #expect(independent == nil)
        #expect(normalized == nil)
        #expect(failed == nil)
        #expect(unspecified == nil)
        _ = try encode(decomposed, id: "before-large-id", flag: false)
        _ = try encode(decomposed, id: String(repeating: "\"\n", count: 1_048_576), flag: false)
        let afterLargeID = try encode(decomposed, id: "after-large-id", flag: false)
        #expect(afterLargeID == nil)
        let annotation = Resource.Annotations(audience: [.assistant], priority: 0.5)
        let annotations = Envelope(
            id: 7, result: CallTool.Result(content: [.text(text: decomposed, annotations: annotation, _meta: nil)]))
        #expect(try encoder.frame(for: annotations) == nil)
        let meta = Metadata(additionalFields: ["name": .string("fixture")])
        let metadata = Envelope(
            id: 8,
            result: CallTool.Result(content: [.text(text: decomposed, annotations: nil, _meta: nil)], _meta: meta))
        #expect(try encoder.frame(for: metadata) == nil)
        _ = try encode(decomposed, id: "before-clear", flag: false)
        _ = try encode(decomposed, id: "seed-before-clear", flag: false)
        let short = try encode("small", id: "short", flag: false)
        let afterShort = try encode(decomposed, id: "after-short", flag: false)
        #expect(short == nil)
        #expect(afterShort == nil)
    }

    @Test
    func sharesTheIdentifierEncodedForTheOriginalFrame() throws {
        final class ChangingIdentifier: Codable {
            private(set) var encodes = 0

            init() {
            }

            init(from decoder: any Decoder) throws {
                encodes = try decoder.singleValueContainer().decode(Int.self)
            }

            func encode(to encoder: any Encoder) throws {
                encodes += 1
                var container = encoder.singleValueContainer()
                try container.encode(encodes == 1 ? 1 : 199)
            }
        }
        let id = ChangingIdentifier()
        let text = String(repeating: "z", count: 70_000)
        let response = Envelope(
            id: id, result: CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)]))
        var encoder = MCPResponseEncoder()
        _ = try encoder.frame(for: response)
        let seed = try encoder.frame(for: response)
        #expect(id.encodes == 1)
        let repeatFrame = try encoder.frame(for: response)
        #expect(id.encodes == 2)
        guard case .contiguous(let bytes) = seed, case .segments(let header, let body) = repeatFrame else {
            Issue.record("Expected one seed and one shared body.")
            return
        }
        let original = try JSONDecoder()
            .decode(Envelope<Int, CallTool.Result>.self, from: Data(bytes.readableBytesView))
        let repeated = try JSONDecoder()
            .decode(
                Envelope<Int, CallTool.Result>.self, from: Data(header.readableBytesView) + Data(body.readableBytesView)
            )
        #expect(original.id == 1)
        #expect(repeated.id == 199)
        #expect(original.result == response.result)
        #expect(repeated.result == response.result)
    }

    @Test
    func plainContentPreservesStringsImagesAndOptionalErrorFlags() throws {
        let content: [Tool.Content] = [
            .text(text: "\u{0}\"\\\t\n😀界", annotations: nil, _meta: nil),
            .image(data: "AQIDBA==", mimeType: "image/png", annotations: nil, _meta: nil),
            .text(text: String(repeating: "x", count: 1_048_576), annotations: nil, _meta: nil),
        ]
        let flags: [Bool?] = [nil, false, true]
        for flag in flags {
            try verify(id: "request\u{0}\"😀", result: CallTool.Result(content: content, isError: flag))
            try verify(id: Int64.min, result: CallTool.Result(content: [], isError: flag))
            try verify(id: UInt64.max, result: CallTool.Result(content: content, isError: flag))
        }
    }

    @Test
    func annotationsMetadataAndOtherContentKeepFoundationBehavior() throws {
        let metadata = Metadata(additionalFields: ["tag": .string("present")])
        let annotations = Resource.Annotations(audience: [.assistant], priority: 0.5)
        let cases: [CallTool.Result] = [
            .init(content: [.text(text: "annotated", annotations: annotations, _meta: nil)]),
            .init(content: [.image(data: "AQ==", mimeType: "image/png", annotations: nil, _meta: metadata)]),
            .init(content: [.audio(data: "AQ==", mimeType: "audio/wav", annotations: nil, _meta: nil)]),
            .init(content: [.resourceLink(uri: "file:///example", name: "Example")]),
            .init(content: [.text(text: "result", annotations: nil, _meta: nil)], _meta: metadata),
            .init(content: [], structuredContent: Optional<Value>.some(.null)),
        ]
        for result in cases {
            try verify(id: 42, result: result)
        }
    }

    @Test
    func protocolErrorsAndOtherPayloadsUseTheirOriginalEnvelope() throws {
        let response = Envelope<Value, MCP.Empty>(id: .null, result: nil, error: .invalidRequest("bad request"))
        let data = try MCPResponseEncoder().encode(response)
        let decoded = try JSONDecoder().decode(Envelope<Value, MCP.Empty>.self, from: data)
        #expect(decoded.id == .null)
        #expect(decoded.result == nil)
        #expect(decoded.error?.localizedDescription == response.error?.localizedDescription)

        let ping = Envelope(id: 7, result: MCP.Empty())
        let pingData = try MCPResponseEncoder().encode(ping)
        let pingResult = try JSONDecoder().decode(Envelope<Int, MCP.Empty>.self, from: pingData)
        #expect(pingResult.id == 7)
        #expect(pingResult.result != nil)
    }

    @Test
    func nonfiniteMetadataStillThrows() {
        let metadata = Metadata(additionalFields: ["invalid": .double(.infinity)])
        let response = Envelope(id: 1, result: CallTool.Result(content: [], _meta: metadata))
        #expect(throws: EncodingError.self) {
            try MCPResponseEncoder().encode(response)
        }
    }

    private func verify<Identifier: Codable & Equatable>(id: Identifier, result: CallTool.Result) throws {
        let response = Envelope(id: id, result: result)
        let baselineData = try JSONEncoder().encode(response)
        let optimizedData = try MCPResponseEncoder().encode(response)
        let baseline = try JSONDecoder()
            .decode(
                Envelope<Identifier, CallTool.Result>.self, from: baselineData)
        let optimized = try JSONDecoder()
            .decode(
                Envelope<Identifier, CallTool.Result>.self, from: optimizedData)
        #expect(optimized.jsonrpc == baseline.jsonrpc)
        #expect(optimized.id == baseline.id)
        #expect(optimized.result == baseline.result)
        #expect(optimized.error == nil)
    }
}
