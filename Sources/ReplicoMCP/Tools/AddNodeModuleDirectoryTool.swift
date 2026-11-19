import ReplicoCore
import Foundation
import MCP

/// Registers a node_modules directory for subsequent package imports.
public struct AddNodeModuleDirectoryTool: Tool {
    /// The directory to register with the session.
    public struct Arguments: Decodable, Sendable, Equatable {
        /// An absolute path whose final component is node_modules.
        public let path: String

        /// Creates directory arguments; the session validates the path on use.
        public init(path: String) {
            self.path = path
        }
    }

    private let session: REPLSession

    /// Binds the tool to the session whose import paths it updates.
    public init(session: REPLSession) {
        self.session = session
    }

    /// The js_add_node_module_dir tool's advertised schema and operational hints.
    public let definition = MCP.Tool(
        name: "js_add_node_module_dir",
        description: "Add an absolute node_modules directory for package imports. "
            + "The directory remains available after js_reset.",
        inputSchema: [
            "type": "object",
            "properties": ["path": ["type": "string", "description": "An absolute node_modules directory."]],
            "required": ["path"],
            "additionalProperties": false,
        ],
        annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    /// Adds the directory without launching Node; registration survives reset.
    public func call(arguments: Arguments, context: ToolCallContext) async throws -> CallTool.Result {
        guard arguments.path.hasPrefix("/") else {
            throw REPLError.invalidRequest("A Node module directory must be an absolute file path.")
        }
        try await session.addNodeModuleDirectory(at: URL(filePath: arguments.path, directoryHint: .isDirectory))
        return EvaluationResult(content: [.text("Node module directory added.")]).makeMCPResult()
    }
}
