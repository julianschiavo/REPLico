import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import Testing
@testable import ReplicoKitMacros

struct ArgumentDiagnosticsTests {
    @Test(arguments: ["Date", "[String: Int]", "Set<String>", "(Int, Int)", "() -> String"])
    func unsupportedTypesAreDiagnosed(_ type: String) throws {
        try expectDiagnostic(for: "var value: \(type)", containing: "Unsupported argument type '\(type)'")
    }

    @Test(arguments: ["var value = 1", "var value: Int = 1", "var value: Int {\n    1\n}"])
    func ambiguousStorageIsDiagnosed(_ property: String) throws {
        try expectDiagnostic(for: property, containing: "one explicitly typed stored property")
    }

    @Test(arguments: [
        "enum CodingKeys: String, CodingKey {\n    case value = \"renamed\"\n}",
        "init(from decoder: any Decoder) throws {\n    value = 0\n}",
    ])
    func decodingOverridesAreDiagnosed(_ override: String) throws {
        try expectDiagnostic(for: "var value: Int\n\(override)", containing: "decoding matches the generated schema")
    }

    private func expectDiagnostic(for member: String, containing expected: String) throws {
        let source = """
            @ToolArguments
            struct Arguments {
                @Argument(description: "A value.")
                \(member)
            }
            """
        let parsed = Parser.parse(source: source)
        let declaration = try #require(parsed.statements.first?.item.as(StructDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
        do {
            _ = try ToolArgumentsMacro.expansion(
                of: attribute, providingMembersOf: declaration, conformingTo: [], in: BasicMacroExpansionContext())
            Issue.record("Expected a diagnostic for \(member)")
        } catch let diagnostic as SwiftSyntaxMacros.MacroExpansionErrorMessage {
            #expect(diagnostic.message.contains(expected))
        }
    }
}
