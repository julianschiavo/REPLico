import ReplicoKit

struct MultiplyTool: Tool {
    let name = "mult"
    let description = "Multiply two numbers."
    let calculator: Calculator

    func call(arguments: Operands, context: ToolContext) async throws -> ToolResponse<Double> {
        ToolResponse(value: calculator.multiply(arguments.a, arguments.b))
    }
}
