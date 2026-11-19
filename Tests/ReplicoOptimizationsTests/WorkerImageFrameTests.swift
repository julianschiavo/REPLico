@testable import ReplicoCore
import ReplicoOptimizations
import Foundation
import Testing

struct WorkerImageFrameTests {
    private let id = "A9137D55-B93F-45E3-850A-DAA18EE53FD0"

    @Test
    func fragmentedImagesAndJSONFramesCanShareARead() throws {
        let payload = Data([255, 216, 255] + Array(UInt8.min...UInt8.max))
        let image = frame(payload)
        let line = Data(#"{"ready":{}}"#.utf8)
        let lf = Data([10])
        let wire = line + lf + image + lf + image + lf + line + lf
        for width in 1...wire.count {
            var buffer = JSONLineBuffer(maximumFrameBytes: image.count, binaryImages: true)
            var records: [Data] = []
            for i in stride(from: 0, to: wire.count, by: width) {
                records += try buffer.append(wire[i..<min(i + width, wire.count)])
            }
            #expect(records == [line, image, image, line])
            try buffer.finish()
        }
        let record = try #require(WorkerImageFrame(image))
        #expect(record.executionID == id)
        #expect(record.mimeType == "image/jpeg")
        #expect(record.data == payload)
        guard case .output(let activeID, let content) = try WorkerEvent(frame: image) else {
            Issue.record("Expected image output")
            return
        }
        #expect(activeID == id)
        #expect(try content.validatedContent() == .image(data: payload, mimeType: "image/jpeg"))
    }

    @Test
    func headerLengthAndDelimiterApplyToPartialFrames() throws {
        let image = frame(Data([255, 216, 255]))
        for invalid in [Data([0, 0, 0, 0, 36]), image + Data([0])] {
            var buffer = JSONLineBuffer(maximumFrameBytes: 64, binaryImages: true)
            #expect(throws: JSONLineBuffer.Failure.invalidFrame) { try buffer.append(invalid) }
        }
        var small = JSONLineBuffer(maximumFrameBytes: 2, binaryImages: true)
        #expect(try small.append(Data([0, 0])).isEmpty)
        #expect(throws: JSONLineBuffer.Failure.frameTooLarge) { try small.append(Data([0])) }
        var oversized = JSONLineBuffer(maximumFrameBytes: 64 * 1_024 * 1_024, binaryImages: true)
        #expect(throws: JSONLineBuffer.Failure.frameTooLarge) {
            try oversized.append(Data([0, 1, 0, 0, 0]))
        }
        for cut in 1...image.count {
            var partial = JSONLineBuffer(maximumFrameBytes: 64, binaryImages: true)
            #expect(try partial.append(image.prefix(cut)).isEmpty)
            #expect(throws: JSONLineBuffer.Failure.unterminatedFrame) { try partial.finish() }
        }
    }

    @Test
    func rawPayloadsStillRequireAValidExecutionAndImageSignature() throws {
        let image = frame(Data([255, 216, 255]))
        for index in [1, 5, 41] {
            var invalid = image
            invalid[index] = 255
            #expect(WorkerImageFrame(invalid) == nil)
            #expect(throws: REPLError.self) { try WorkerEvent(frame: invalid) }
        }
        let invalid = frame(Data([1, 2, 3]))
        guard case .output(_, let content) = try WorkerEvent(frame: invalid) else {
            Issue.record("Expected an image to validate")
            return
        }
        #expect(throws: REPLError.self) { try content.validatedContent() }
        var textOnly = JSONLineBuffer(maximumFrameBytes: 1024)
        #expect(throws: JSONLineBuffer.Failure.invalidFrame) {
            try textOnly.append(image + Data([10]))
        }
    }

    private func frame(_ bytes: Data) -> Data {
        let body = bytes.count + 37
        var frame = Data([0, 0, 0, UInt8(body >> 8), UInt8(truncatingIfNeeded: body)])
        frame.append(contentsOf: id.utf8)
        frame.append(0)
        frame.append(bytes)
        return frame
    }
}
