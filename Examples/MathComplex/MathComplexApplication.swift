import ReplicoKit
import ArgumentParser

@main
struct MathComplexApplication: AsyncParsableCommand, ReplicoApplication {
    static let configuration = CommandConfiguration(
        commandName: "math-complex",
        abstract: "Calculate with two numbers, or expose the same calculator through MCP."
    )

    @ArgumentParser.Flag(help: "Serve the calculator as a standard IO MCP application.")
    var mcp = false

    @ArgumentParser.Argument(help: "The arithmetic operation.")
    var operation: Operation?

    @ArgumentParser.Argument(help: "The first finite number.")
    var first: Double?

    @ArgumentParser.Argument(help: "The second finite number.")
    var second: Double?

    let calculator = Calculator()

    private enum CodingKeys: String, CodingKey {
        case mcp
        case operation
        case first
        case second
    }

    var toolGroups: [ToolGroup] {
        [
            ToolGroup(
                name: "math",
                description: "Arithmetic with two numeric operands.",
                tools: [
                    AddTool(calculator: calculator), SubtractTool(calculator: calculator),
                    MultiplyTool(calculator: calculator), DivideTool(calculator: calculator),
                ]
            )
        ]
    }

    static func main() async {
        await main(nil)
    }

    mutating func run() async throws {
        if mcp {
            guard operation == nil, first == nil, second == nil else {
                throw ValidationError("Use --mcp without an operation or operands.")
            }
            try await serve()
            return
        }
        guard let operation, let first, let second, first.isFinite, second.isFinite else {
            throw ValidationError("Provide an operation and two finite operands, or use --mcp.")
        }
        let value: Double
        switch operation {
        case .add:
            value = calculator.add(first, second)
        case .sub:
            value = calculator.subtract(first, second)
        case .mult:
            value = calculator.multiply(first, second)
        case .div:
            value = try calculator.divide(first, second)
        }
        let text = String(value)
        print(text.hasSuffix(".0") ? String(text.dropLast(2)) : text)
    }
}
