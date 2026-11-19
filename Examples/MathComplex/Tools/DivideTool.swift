import ReplicoKit

struct DivideTool: Tool {
    let name = "div"
    let description = "Divide the first number by the second; a zero divisor throws an error."
    let calculator: Calculator

    func call(arguments: Operands, context: ToolContext) async throws -> ToolResponse<Double> {
        try ToolResponse(value: calculator.divide(arguments.a, arguments.b))
    }
}
