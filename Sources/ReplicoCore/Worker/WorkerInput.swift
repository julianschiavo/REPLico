import Foundation
import NIOCore
import NIOPosix
import SystemPackage
#if canImport(Darwin)
import Darwin
#endif

/// Owns the write channel and lends its read end to the subprocess through spawn.
struct WorkerInput: Sendable {
    let channel: any Channel
    let childInput: FileHandle

    init(on eventLoop: any EventLoop) async throws {
        let commands = try Self.makePipe()
        childInput = FileHandle(fileDescriptor: commands.readEnd.rawValue, closeOnDealloc: true)
        do {
            channel = try await NIOPipeBootstrap(group: eventLoop)
                .takingOwnershipOfDescriptor(output: commands.writeEnd.rawValue).get()
        } catch {
            try? commands.writeEnd.close()
            throw error
        }
    }

    private static func makePipe() throws -> (
        readEnd: SystemPackage.FileDescriptor, writeEnd: SystemPackage.FileDescriptor
    ) {
        if #available(macOS 27, *) {
            return try SystemPackage.FileDescriptor.pipe(options: .closeOnExec)
        }
        #if canImport(Darwin)
        let pipe = try SystemPackage.FileDescriptor.pipe()
        guard fcntl(pipe.readEnd.rawValue, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(pipe.writeEnd.rawValue, F_SETFD, FD_CLOEXEC) == 0
        else {
            let error = Errno(rawValue: errno)
            try? pipe.readEnd.close()
            try? pipe.writeEnd.close()
            throw error
        }
        return pipe
        #endif
    }
}
