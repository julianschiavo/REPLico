import ReplicoCore
import Foundation

struct RuntimeFixture: Sendable {
    let directory: URL
    let repository: URL
    let session: REPLSession

    init(
        services: [any REPLService] = [],
        clock: any Clock<Duration> = ContinuousClock(),
        maximumOutputBytes: Int = 16 * 1_024 * 1_024
    ) throws {
        var repository = URL(filePath: #filePath)
        for _ in 0..<4 {
            repository.deleteLastPathComponent()
        }
        self.repository = repository
        directory = FileManager.default.temporaryDirectory
            .appending(path: "replico-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            session = try REPLSession(
                configuration: REPLConfiguration(
                    nodeExecutable: repository.appending(path: ".runtime/ReplicoRuntime.artifactbundle/bin/node"),
                    workingDirectory: directory,
                    environment: [
                        "PATH": "/usr/bin:/bin",
                        "HOME": directory.path,
                        "TMPDIR": directory.path,
                    ],
                    maximumOutputBytes: maximumOutputBytes
                ),
                services: services,
                clock: clock
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func run(_ body: @Sendable (RuntimeFixture) async throws -> Void) async throws {
        do {
            try await body(self)
            await session.shutDown()
            try FileManager.default.removeItem(at: directory)
        } catch {
            await session.shutDown()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func write(_ source: String, to relativePath: String) throws {
        let file = directory.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(source.utf8).write(to: file)
    }
}
