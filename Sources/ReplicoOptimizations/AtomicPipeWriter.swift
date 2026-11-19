import Foundation
import NIOCore
import SystemPackage
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Writes a complete frame directly when a nonblocking pipe can accept it atomically.
/// NIO's `channel.writeAndFlush(bytes)` schedules a write on its event loop. A
/// serialized producer can first try `try writer.writeIfPossible(bytes)` when
/// that channel has no queued writes. A false result leaves all bytes for NIO.
package struct AtomicPipeWriter: Sendable {
    private let file: FileHandle
    private let limit: Int

    /// Duplicates an already configured FIFO, retaining ownership until the connection closes.
    package init?(_ output: FileHandle) {
        let fd = fcntl(output.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else {
            return nil
        }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, flags & O_NONBLOCK != 0,
            (try? SystemPackage.FileDescriptor(rawValue: fd).stat().type) == .fifo
        else {
            return nil
        }
        #if canImport(Darwin)
        guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            return nil
        }
        #endif
        limit = fpathconf(fd, CInt(_PC_PIPE_BUF))
    }

    /// Returns false when the kernel would block or cannot guarantee an atomic write.
    package func writeIfPossible(_ bytes: ByteBuffer) throws -> Bool {
        guard bytes.readableBytes <= limit else {
            return false
        }
        do {
            try SystemPackage.FileDescriptor(rawValue: file.fileDescriptor).writeAll(bytes.readableBytesView)
            return true
        } catch let error as Errno where error == .wouldBlock || error == .resourceTemporarilyUnavailable {
            return false
        }
    }
}
