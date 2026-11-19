import ReplicoKit

struct SubtractTool: Tool {
    let name = "sub"
    let description = "Subtract the second number from the first."

    func call(arguments: Operands, context: ToolContext) async throws -> ToolResponse<Double> {
        ToolResponse(value: arguments.a - arguments.b)
    }
}
