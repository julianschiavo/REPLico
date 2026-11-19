import ReplicoKit
import Foundation

struct KitTestApplication: ReplicoApplication {
    let toolGroups: [ToolGroup]

    init() {
        toolGroups = []
    }

    init(groups: [ToolGroup]) {
        toolGroups = groups
    }

    var configuration: ApplicationConfiguration {
        var repository = URL(filePath: #filePath)
        for _ in 0..<4 {
            repository.deleteLastPathComponent()
        }
        return ApplicationConfiguration(
            nodeRuntime: .external(repository.appending(path: ".runtime/ReplicoRuntime.artifactbundle/bin/node")),
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/tmp", "TMPDIR": "/tmp"]
        )
    }
}
