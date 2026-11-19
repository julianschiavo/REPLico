import SwiftSyntax
import SwiftSyntaxMacros

struct ArgumentMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let owner = context.lexicalContext.compactMap { $0.as(StructDeclSyntax.self) }.first
        guard declaration.is(VariableDeclSyntax.self),
            owner?.attributes
                .contains(where: {
                    $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "ToolArguments"
                }) == true
        else {
            throw MacroExpansionErrorMessage(
                "@Argument must annotate a stored property inside an @ToolArguments struct.")
        }
        return []
    }
}
