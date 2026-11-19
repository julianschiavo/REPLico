import Foundation
import PackagePlugin

@main
struct ReplicoResources: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: any Target) async throws -> [Command] {
        let node = try context.tool(named: "node").url
        let output = context.pluginWorkDirectoryURL.appending(path: "GeneratedResources")
        return [
            .prebuildCommand(
                displayName: "Stage Node runtime",
                executable: node,
                arguments: [
                    context.package.directoryURL.appending(path: "Plugins/ReplicoResources/StageResources.mjs").path,
                    output.path,
                ],
                outputFilesDirectory: output
            )
        ]
    }
}
