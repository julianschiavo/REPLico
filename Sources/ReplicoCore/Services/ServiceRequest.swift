import Foundation

/// Immutable input to a registered host service, including its original wire representation.
public struct ServiceRequest: Sendable, Equatable {
    private struct Frame<Arguments: Decodable>: Decodable {
        struct Invocation: Decodable {
            let request: Arguments
        }

        let service: Invocation
    }

    /// The originating evaluation identifier; later evaluations have different identifiers.
    public let executionID: String
    /// The JSON payload supplied by JavaScript.
    public let payload: JSONValue
    /// The originating call metadata, without changes by later evaluations.
    public let metadata: [String: JSONValue]
    private let frame: Data

    init(executionID: String, payload: JSONValue, metadata: [String: JSONValue], frame: Data) {
        self.executionID = executionID
        self.payload = payload
        self.metadata = metadata
        self.frame = frame
    }

    /// Decodes typed arguments directly from the original worker frame without re-encoding `payload`.
    public func decode<Arguments: Decodable>(_ type: Arguments.Type) throws -> Arguments {
        try JSONDecoder().decode(Frame<Arguments>.self, from: frame).service.request
    }
}
