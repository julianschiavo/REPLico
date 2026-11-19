import ReplicoCore
import Foundation
import MCP

/// Evaluates JavaScript in the server's persistent Node session.
public struct JavaScriptTool: Tool {
    /// Source code and optional presentation and deadline settings.
    public struct Arguments: Decodable, Sendable, Equatable {
        /// Nonempty JavaScript source with support for top-level await.
        public let code: String
        /// An optional short description of the operation.
        public let title: String?
        /// The execution deadline in milliseconds; nil selects 30,000.
        public let timeoutMilliseconds: Int?

        private enum CodingKeys: String, CodingKey {
            case code
            case title
            case timeoutMilliseconds = "timeout_ms"
        }

        /// Creates arguments; a supplied timeout must be positive when invoked.
        public init(code: String, title: String? = nil, timeoutMilliseconds: Int? = nil) {
            self.code = code
            self.title = title
            self.timeoutMilliseconds = timeoutMilliseconds
        }
    }

    private let session: REPLSession

    /// The js tool's advertised schema and operational hints.
    public let definition: MCP.Tool

    /// Binds the tool to a session and optionally advertises host JavaScript APIs.
    public init(session: REPLSession, additionalInstructions: String? = nil) {
        self.session = session
        var description =
            "Execute JavaScript in a persistent Node REPL with top-level await. "
            + "Bindings persist between calls and can be redeclared. Use nodeRepl.write(value) for output."
        if let additionalInstructions, !additionalInstructions.isEmpty {
            description += "\n\n" + additionalInstructions
        }
        definition = MCP.Tool(
            name: "js",
            description: description,
            inputSchema: [
                "type": "object",
                "properties": [
                    "code": ["type": "string", "description": "JavaScript code to execute."],
                    "title": ["type": "string", "description": "A short description of the operation."],
                    "timeout_ms": [
                        "type": "integer", "minimum": 1, "default": 30_000,
                        "description": "Execution timeout in milliseconds.",
                    ],
                ],
                "required": ["code"],
                "additionalProperties": false,
            ],
            annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
        )
    }

    /// Evaluates source while preserving the invocation's metadata and authority.
    /// Empty or whitespace source returns a failed MCP result without starting Node.
    public func call(arguments: Arguments, context: ToolCallContext) async throws -> CallTool.Result {
        guard arguments.code.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) })
        else {
            return CallTool.Result(
                content: [
                    .text(
                        text: "js expects non-empty JavaScript source", annotations: nil, _meta: nil
                    )
                ], isError: true)
        }
        let timeout = arguments.timeoutMilliseconds ?? 30_000
        guard timeout > 0 else {
            throw MCPError.invalidParams("timeout_ms must be a positive integer.")
        }
        let result = try await session.evaluate(
            EvaluationRequest(
                code: arguments.code,
                title: arguments.title,
                timeout: .milliseconds(timeout),
                metadata: context.metadata,
                launchPolicy: context.launchPolicy
            ))
        return result.makeMCPResult()
    }
}
