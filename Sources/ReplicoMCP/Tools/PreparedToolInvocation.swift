import Foundation
import MCP

/// Keeps a tool and its concrete arguments together across asynchronous execution.
struct PreparedToolInvocation<Action: Tool>: ToolInvocation {
    let action: Action
    let arguments: Action.Arguments

    func invoke(context: ToolCallContext) async throws -> CallTool.Result {
        try await action.call(arguments: arguments, context: context)
    }
}

extension Tool {
    func prepareInvocation(from parameters: KeyedDecodingContainer<MCPToolCall.ParameterKey>) throws
        -> any ToolInvocation
    {
        let arguments: Arguments
        do {
            arguments =
                try parameters.decodeIfPresent(Arguments.self, forKey: .arguments)
                ?? JSONDecoder().decode(Arguments.self, from: Data("{}".utf8))
        } catch {
            throw MCPError.invalidParams("Invalid tool arguments: \(error.localizedDescription)")
        }
        return PreparedToolInvocation(action: self, arguments: arguments)
    }
}
