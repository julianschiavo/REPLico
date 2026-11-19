import ReplicoKit

struct AddTool: Tool {
    let name = "add"
    let description = "Add two numbers."

    func call(arguments: Operands, context: ToolContext) async throws -> ToolResponse<Double> {
        ToolResponse(value: arguments.a + arguments.b)
    }
}
