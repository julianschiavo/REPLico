@testable import ReplicoCore
import ReplicoOptimizations
import Foundation
import Testing

struct WorkerEvaluationFrameTests {
    @Test
    func evaluationFramesPreserveSourceMetadataAndModuleDirectories() throws {
        for code in ["", "void 0", "\"\\/\n\r\t\u{0000}🙂漢", String(repeating: "x", count: 1_048_576)] {
            for directories in [[], ["/tmp/one/node_modules", "/tmp/🙂/node_modules"]] {
                let metadata: [String: JSONValue] = [
                    "largest": .unsignedInteger(UInt64.max), "smallest": .integer(Int64.min),
                    "nested": .array([.null, .bool(false), .number(1.25), .string("🙂\n\u{0000}")]),
                ]
                for values in [[:], metadata] {
                    let id = UUID().uuidString
                    let baseline = BaselineWorkerCommand.evaluate(
                        executionID: id, code: code,
                        metadata: values, moduleDirectories: directories
                    )
                    let actual = try WorkerEvaluationFrame(
                        executionID: id, code: code, metadata: values, moduleDirectories: directories
                    )
                    let expected = try JSONEncoder().encode(baseline)
                    #expect(
                        try JSONDecoder().decode(JSONValue.self, from: actual.data)
                            == JSONDecoder().decode(JSONValue.self, from: expected)
                    )
                }
            }
        }
    }

    @Test
    func nonfiniteMetadataKeepsFoundationFailureBehavior() throws {
        for value in [Double.nan, .infinity, -.infinity] {
            let metadata = ["value": JSONValue.number(value)]
            #expect(throws: EncodingError.self) {
                try WorkerEvaluationFrame(executionID: "fixture", code: "0", metadata: metadata, moduleDirectories: [])
            }
        }
    }

    @Test
    func metadataErrorsRetainTheCompleteCommandCodingPath() throws {
        let metadata: [String: JSONValue] = ["outer": .object(["inner": .array([.number(.nan)])])]
        let baseline = BaselineWorkerCommand.evaluate(
            executionID: "path", code: "0",
            metadata: metadata, moduleDirectories: []
        )
        var expected: EncodingError.Context?
        do {
            _ = try JSONEncoder().encode(baseline)
            Issue.record("Expected native encoding to reject nonfinite metadata.")
        } catch let error as EncodingError {
            expected = try Self.invalidValueContext(error)
        }
        let native = try #require(expected)
        #expect(!native.codingPath.isEmpty)
        do {
            _ = try WorkerEvaluationFrame(executionID: "path", code: "0", metadata: metadata, moduleDirectories: [])
            Issue.record("Expected captured encoding to reject nonfinite metadata.")
        } catch let error as EncodingError {
            let actual = try Self.invalidValueContext(error)
            #expect(actual.codingPath.map(\.stringValue) == native.codingPath.map(\.stringValue))
            #expect(actual.codingPath.map(\.intValue) == native.codingPath.map(\.intValue))
            #expect(actual.debugDescription == native.debugDescription)
        }
    }

    @Test
    func metadataDepthBoundariesMatchTheCompleteNativeCommand() throws {
        var accepted = 0
        var rejected = 0
        for depth in [0, 1, 506, 507, 508, 509, 510, 511, 512, 513] {
            let metadata = ["nested": NestedArrays(depth: depth)]
            let baseline = BaselineWorkerCommand.evaluate(
                executionID: "depth", code: "0",
                metadata: metadata, moduleDirectories: []
            )
            var expected: EncodingError.Context?
            do {
                _ = try JSONEncoder().encode(baseline)
            } catch let error as EncodingError {
                expected = try Self.invalidValueContext(error)
            }
            if let expected {
                rejected += 1
                do {
                    _ = try WorkerEvaluationFrame(
                        executionID: "depth", code: "0", metadata: metadata, moduleDirectories: [])
                    Issue.record("Expected native metadata nesting rejection at depth \(depth).")
                } catch let error as EncodingError {
                    let actual = try Self.invalidValueContext(error)
                    #expect(actual.codingPath.map(\.stringValue) == expected.codingPath.map(\.stringValue))
                    #expect(actual.debugDescription == expected.debugDescription)
                }
            } else {
                accepted += 1
                _ = try WorkerEvaluationFrame(
                    executionID: "depth", code: "0", metadata: metadata, moduleDirectories: [])
            }
        }
        #expect(accepted > 0)
        #expect(rejected > 0)
    }

    private struct NestedArrays: Encodable {
        let depth: Int

        func encode(to encoder: any Encoder) throws {
            guard depth > 0 else {
                var container = encoder.singleValueContainer()
                try container.encode("leaf")
                return
            }
            var container = encoder.unkeyedContainer()
            for _ in 1..<depth {
                container = container.nestedUnkeyedContainer()
            }
            try container.encode("leaf")
        }
    }

    private static func invalidValueContext(_ error: EncodingError) throws -> EncodingError.Context {
        switch error {
        case .invalidValue(_, let context):
            return context
        @unknown default:
            throw error
        }
    }
}
