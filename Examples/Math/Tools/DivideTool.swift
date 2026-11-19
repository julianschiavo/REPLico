import ReplicoKit

struct DivideTool: Tool {
    let name = "div"
    let description = "Divide the first number by the second; a zero divisor throws an error."

    func call(arguments: Operands, context: ToolContext) async throws -> ToolResponse<Double> {
        guard arguments.b != 0 else {
            throw MathError.divisionByZero
        }
        return ToolResponse(value: arguments.a / arguments.b)
    }
}
