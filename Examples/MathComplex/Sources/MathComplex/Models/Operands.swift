import ReplicoKit

@ToolArguments
struct Operands {
    @Argument(description: "The first operand.")
    let a: Double

    @Argument(description: "The second operand; division uses this as the divisor.")
    let b: Double
}
