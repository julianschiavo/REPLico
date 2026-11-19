import ReplicoKit

struct SubtractTool: Tool {
    let name = "sub"
    let description = "Subtract the second number from the first."
    let calculator: Calculator

    func call(arguments: Operands, context: ToolContext) async throws -> ToolResponse<Double> {
        ToolResponse(value: calculator.subtract(arguments.a, arguments.b))
    }
}
