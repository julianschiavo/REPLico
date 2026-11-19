import Foundation
import Testing

@testable import ReplicoCore

struct ServiceBoundaryTests {
    private struct Arguments: Decodable {
        let exact: UInt64
    }

    private struct Reply: Decodable {
        struct Payload: Decodable {
            let value: UInt64
        }

        let serviceReply: Payload
    }

    private struct TrackedOutput: Encodable, Sendable {
        let encodings: AsyncStream<Bool>.Continuation

        func encode(to encoder: any Encoder) throws {
            encodings.yield(true)
            var container = encoder.singleValueContainer()
            try container.encode(UInt64.max)
        }
    }

    private struct FailingOutput: Encodable, Sendable {
        enum Failure: Error {
            case unavailable
        }

        func encode(to encoder: any Encoder) throws {
            throw Failure.unavailable
        }
    }

    private struct EncodingFailureService: REPLService {
        let name = "encoding-failure"

        func call(_ request: ServiceRequest) async throws -> ServiceResponse {
            ServiceResponse(value: FailingOutput())
        }
    }

    @Test
    func typedArgumentsRetainTheOriginalUnsignedInteger() throws {
        let frame = Data(
            #"{"service":{"executionID":"execution","requestID":"request","service":"exact","request":{"exact":18446744073709551615}}}"#
                .utf8)
        let event = try JSONDecoder().decode(WorkerEvent.self, from: frame)
        guard case .service(let executionID, _, _, let payload) = event else {
            Issue.record("Expected a service request")
            return
        }
        let request = ServiceRequest(executionID: executionID, payload: payload, metadata: [:], frame: frame)
        let arguments = try request.decode(Arguments.self)
        #expect(arguments.exact == UInt64.max)
        #expect(request.payload.objectValue?["exact"] == .unsignedInteger(UInt64.max))
    }

    @Test
    func typedResponseEncodesOnceAtTheWorkerBoundary() async throws {
        let events = AsyncStream<Bool>.makeStream()
        let response = ServiceResponse(value: TrackedOutput(encodings: events.continuation))
        let command = WorkerCommand.serviceReply(
            executionID: "execution", requestID: "request", ok: true,
            value: ServiceValue(value: response.value), error: nil
        )
        let data = try JSONEncoder().encode(command)
        events.continuation.finish()
        var encodings = 0
        for await encoded in events.stream {
            #expect(encoded)
            encodings += 1
        }
        #expect(encodings == 1)
        #expect(try JSONDecoder().decode(Reply.self, from: data).serviceReply.value == UInt64.max)
    }

    @Test
    func responseEncodingFailureRejectsRPCWithoutRetiringTheWorker() async throws {
        try await RuntimeFixture(services: [EncodingFailureService()])
            .run { fixture in
                let result = try await fixture.session.evaluate(
                    EvaluationRequest(
                        code: """
                            let retained = 42
                            let rejected = false
                            try {
                                await nodeRepl.rpc('encoding-failure', {})
                            } catch {
                                rejected = true
                            }
                            nodeRepl.write(JSON.stringify([rejected, retained]))
                            """))
                #expect(!result.didFail)
                #expect(result.text == "[true,42]")
                let retained = try await fixture.session.evaluate(EvaluationRequest(code: "nodeRepl.write(retained)"))
                #expect(!retained.didFail)
                #expect(retained.text == "42")
            }
    }
}
