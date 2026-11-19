import ReplicoOptimizations
import Foundation
import NIOCore
import Subprocess

extension REPLSession {
    static let maximumFrameBytes = 64 * 1_024 * 1_024

    /// Reads until EOF or direct child exit, even when a descendant inherits stdout.
    func readWorkerOutput(_ output: SubprocessOutputSequence, from generation: UUID, on input: any Channel) async throws
    {
        var framer = JSONLineBuffer(maximumFrameBytes: Self.maximumFrameBytes, binaryImages: true)
        do {
            for try await buffer in output {
                for frame in try framer.append(Data(buffer: buffer)) {
                    let event = try WorkerEvent(frame: frame)
                    handle(event, frame: frame, from: generation, on: input)
                }
            }
            try framer.finish()
        } catch let failure as JSONLineBuffer.Failure {
            switch failure {
            case .frameTooLarge:
                throw REPLError.protocolViolation("Worker frame exceeds the configured byte limit.")
            case .invalidFrame:
                throw REPLError.protocolViolation("Worker returned an empty or invalid UTF-8 frame.")
            case .unterminatedFrame:
                throw REPLError.protocolViolation("Worker exited with an unterminated protocol frame.")
            }
        } catch let error as DecodingError {
            throw REPLError.protocolViolation("Cannot decode worker event: \(error.localizedDescription)")
        }
        throw REPLError.workerExited("Node worker closed its output.")
    }
}
