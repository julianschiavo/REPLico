import ReplicoKit

struct MultiplyTool: Tool {
    let name = "mult"
    let description = "Multiply two numbers."

    func call(arguments: Operands, context: ToolContext) async throws -> ToolResponse<Double> {
        ToolResponse(value: arguments.a * arguments.b)
    }
}
