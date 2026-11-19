import Foundation

/// An immutable set of tools exposed inside one JavaScript namespace.
///
/// Tool names, descriptions, and argument schemas are captured once at initialization.
/// Application session creation validates the captured registrations before launching Node.
public struct ToolGroup: Sendable {
    struct Prepared {
        let startupSource: String
        let documentation: String
    }

    /// The JavaScript namespace, such as `text` in `await text.uppercase({value: "hello"})`.
    public let name: String
    /// Optional discovery text describing the group's purpose.
    public let description: String?
    /// The frozen tool definitions in registration order.
    public var tools: [ToolDefinition] {
        registrations.map(\.definition)
    }

    let registrations: [RegisteredTool]

    /// Captures a namespace and its tool implementations without launching a worker.
    /// Names must be ASCII JavaScript identifiers; namespace names must not shadow globals.
    public init(name: String, description: String? = nil, tools: [any Tool]) {
        self.name = name
        self.description = description
        registrations = tools.map { tool in
            RegisteredTool(tool, namespace: name)
        }
    }

    func prepare() throws -> Prepared {
        guard Self.isIdentifier(name), !Self.reservedWords.contains(name) else {
            throw ToolRegistrationError.invalidGroupName(name)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var names: Set<String> = []
        var methods: [String] = []
        var documentation = [description.map { "\(name): \($0)" } ?? name]
        for registration in registrations {
            let tool = registration.definition
            guard Self.isIdentifier(tool.name) else {
                throw ToolRegistrationError.invalidToolName(group: name, name: tool.name)
            }
            guard names.insert(tool.name).inserted else {
                throw ToolRegistrationError.duplicateToolName(group: name, name: tool.name)
            }
            guard tool.argumentsSchema["type"] == .string("object"),
                tool.argumentsSchema["additionalProperties"] != .bool(false)
                    || tool.argumentsSchema["properties"]?.objectValue != nil,
                let schema = try? encoder.encode(tool.argumentsSchema)
            else {
                throw ToolRegistrationError.invalidArgumentsSchema(group: name, name: tool.name)
            }
            documentation.append(
                "await \(name).\(tool.name)(arguments): \(tool.description)\nArguments: \(String(decoding: schema, as: UTF8.self))"
            )
            methods.append(
                """
                ["\(tool.name)"]: async function (arguments_ = {}) {
                    return await nodeRepl.rpc("\(registration.name)", arguments_)
                }
                """)
        }
        let source = """
            if ("\(name)" in globalThis) {
                throw new Error("Tool namespace conflicts with an existing JavaScript global: \(name)")
            }
            Object.defineProperty(globalThis, "\(name)", {
                value: Object.freeze(Object.assign(Object.create(null), {
                    \(methods.joined(separator: ",\n"))
                })),
                writable: false,
                configurable: false
            })
            """
        return Prepared(startupSource: source, documentation: documentation.joined(separator: "\n"))
    }

    private static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.utf8.first, !(48...57).contains(first) else {
            return false
        }
        return name.utf8.allSatisfy { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 95, 36: true
            default: false
            }
        }
    }

    private static let reservedWords: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else",
        "enum", "export", "extends", "false", "finally", "for", "function", "if", "implements", "import", "in",
        "instanceof",
        "interface", "let", "new", "null", "package", "private", "protected", "public", "return", "static", "super",
        "switch",
        "this", "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield",
    ]
}
