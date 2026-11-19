import ReplicoOptimizations
import Foundation

enum WorkerEvent: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        let message: String
    }

    case ready(version: Int, nodeVersion: String)
    case output(executionID: String, content: WorkerContent)
    case service(executionID: String, requestID: String, service: String, request: JSONValue)
    case completed(executionID: String, succeeded: Bool, error: Failure?)
    case fatal(executionID: String?, error: Failure)

    init(frame: Data) throws {
        if frame.first == 0 {
            guard let image = WorkerImageFrame(frame) else {
                throw REPLError.protocolViolation("Worker returned an invalid binary image frame.")
            }
            self = .output(
                executionID: image.executionID,
                content: WorkerContent(type: .image, text: nil, data: image.data, mimeType: image.mimeType, itemID: nil)
            )
            return
        }
        switch WorkerEnvelope(frame: frame) {
        case .text(let executionID, let text):
            self = .output(
                executionID: executionID,
                content: WorkerContent(type: .text, text: text, data: nil, mimeType: nil, itemID: nil)
            )
        case .image(let executionID, let data, let mimeType):
            self = .output(
                executionID: executionID,
                content: WorkerContent(type: .image, text: nil, data: data, mimeType: mimeType, itemID: nil)
            )
        case .completed(let executionID):
            self = .completed(executionID: executionID, succeeded: true, error: nil)
        case nil:
            self = try JSONDecoder().decode(Self.self, from: frame)
        }
    }
}
