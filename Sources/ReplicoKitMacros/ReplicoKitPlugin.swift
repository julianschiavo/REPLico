import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ReplicoKitPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [ToolArgumentsMacro.self, ArgumentMacro.self]
}
