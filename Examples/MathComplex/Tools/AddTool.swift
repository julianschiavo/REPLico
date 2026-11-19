import ReplicoKit

struct AddTool: Tool {
    let name = "add"
    let description = "Add two numbers."
    let calculator: Calculator

    func call(arguments: Operands, context: ToolContext) async throws -> ToolResponse<Double> {
        ToolResponse(value: calculator.add(arguments.a, arguments.b))
    }
}
