import ReplicoKit

@main
struct MathApplication: ReplicoApplication {
    var configuration: ApplicationConfiguration {
        ApplicationConfiguration(serverInfo: .init(name: "math", version: "1.0.0", title: "Math"))
    }

    var toolGroups: [ToolGroup] {
        [
            ToolGroup(
                name: "math",
                description: "Arithmetic with two numeric operands.",
                tools: [AddTool(), SubtractTool(), MultiplyTool(), DivideTool()]
            )
        ]
    }
}
