import ReplicoOptimizations
import Foundation
import NIOCore
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct AtomicPipeWriterTests {
    @Test
    func oversizedFramesLeaveTheEntirePipeAvailableForTheNextWrite() throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        try #require(flags >= 0)
        try #require(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
        let writer = try #require(AtomicPipeWriter(pipe.fileHandleForWriting))
        let limit = fpathconf(fd, CInt(_PC_PIPE_BUF))
        try #require(limit > 0)
        let large = ByteBuffer(bytes: Array(repeating: UInt8(65), count: limit + 1))
        #expect(try !writer.writeIfPossible(large))
        #expect(try writer.writeIfPossible(ByteBuffer(string: "complete\n")))
        #expect(try pipe.fileHandleForReading.read(upToCount: 9) == Data("complete\n".utf8))
    }

    @Test
    func blockingPipesUseTheAsynchronousTransport() {
        let pipe = Pipe()
        #expect(AtomicPipeWriter(pipe.fileHandleForWriting) == nil)
    }
}
