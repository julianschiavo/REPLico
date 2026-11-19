import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

struct ToolArgumentsMacro: MemberMacro, ExtensionMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structure = declaration.as(StructDeclSyntax.self), structure.genericParameterClause == nil else {
            throw MacroExpansionErrorMessage("@ToolArguments requires a non-generic struct.")
        }
        var properties: [String] = []
        var required: [String] = []
        for member in structure.memberBlock.members {
            if member.decl.is(InitializerDeclSyntax.self)
                || member.decl.as(EnumDeclSyntax.self)?.name.text == "CodingKeys"
                || member.decl.as(TypeAliasDeclSyntax.self)?.name.text == "CodingKeys"
            {
                throw MacroExpansionErrorMessage(
                    "@ToolArguments synthesizes decoding. Remove custom initializers and CodingKeys so decoding matches the generated schema."
                )
            }
            guard let variable = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }
            guard !variable.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) else {
                continue
            }
            guard variable.bindings.count == 1, let binding = variable.bindings.first,
                let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                let type = binding.typeAnnotation?.type, binding.accessorBlock == nil,
                binding.initializer == nil
            else {
                throw MacroExpansionErrorMessage(
                    "Use one explicitly typed stored property per @Argument, without a default. Use an optional argument for an omitted value."
                )
            }
            let attributes = variable.attributes.compactMap { $0.as(AttributeSyntax.self) }
            guard attributes.count == 1, let argument = attributes.first,
                argument.attributeName.trimmedDescription == "Argument",
                case .argumentList(let arguments) = argument.arguments,
                arguments.count == 1, let description = arguments.first,
                description.label?.text == "description",
                description.expression.is(StringLiteralExprSyntax.self)
            else {
                throw MacroExpansionErrorMessage("Describe each argument with @Argument(description: \"...\").")
            }
            let schema = try schema(for: type)
            properties.append(
                "\(literal(name)): .object([\"description\": .string(\(description.expression.trimmedDescription)), \(schema)])"
            )
            if !type.is(OptionalTypeSyntax.self) {
                required.append(".string(\(literal(name)))")
            }
        }
        let propertyEntries = properties.isEmpty ? ":" : properties.joined(separator: ",\n")
        return [
            DeclSyntax(
                stringLiteral: """
                    /// Describes the supported arguments for API discovery.
                    public static var schema: ReplicoKit.JSONValue {
                        .object([
                            "type": .string("object"),
                            "properties": .object([\(propertyEntries)]),
                            "required": .array([\(required.joined(separator: ", "))]),
                            "additionalProperties": .bool(false)
                        ])
                    }
                    """)
        ]
    }

    static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structure = declaration.as(StructDeclSyntax.self) else {
            return []
        }
        if structure.inheritanceClause?.inheritedTypes
            .contains(where: {
                $0.type.trimmedDescription.split(separator: ".").last == "ToolArgumentsProtocol"
            }) == true
        {
            return []
        }
        if structure.modifiers.contains(where: { $0.name.text == "private" }), type.is(MemberTypeSyntax.self) {
            throw MacroExpansionErrorMessage(
                "A nested private arguments type must explicitly conform to ToolArgumentsProtocol, or use fileprivate so its generated extension can access it."
            )
        }
        return [
            try ExtensionDeclSyntax(
                """
                extension \(type.trimmed): ReplicoKit.ToolArgumentsProtocol {
                }
                """)
        ]
    }

    private static func schema(for type: TypeSyntax) throws -> String {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return
                "\"anyOf\": .array([.object([\(try schema(for: optional.wrappedType))]), .object([\"type\": .string(\"null\")])])"
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            return "\"type\": .string(\"array\"), \"items\": .object([\(try schema(for: array.element))])"
        }
        guard let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil else {
            throw unsupportedType(type)
        }
        let kind: String
        switch identifier.name.text {
        case "String":
            kind = "string"
        case "Bool":
            kind = "boolean"
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            kind = "integer"
        case "Double", "Float":
            kind = "number"
        default:
            throw unsupportedType(type)
        }
        return "\"type\": .string(\(literal(kind)))"
    }

    private static func unsupportedType(_ type: TypeSyntax) -> MacroExpansionErrorMessage {
        MacroExpansionErrorMessage(
            "Unsupported argument type '\(type.trimmedDescription)'. Use String, Bool, an integer, Double, Float, arrays, or optionals of those types."
        )
    }

    private static func literal(_ value: String) -> String {
        StringLiteralExprSyntax(content: value).description
    }
}
