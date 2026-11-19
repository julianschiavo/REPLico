import ReplicoCore
import Foundation
import MCP

/// Decodes a registered tool and its metadata from the request's parameters.
struct MCPToolCall: DecodableWithConfiguration, Sendable {
    typealias DecodingConfiguration = [RegisteredTool]

    let metadata: [String: JSONValue]
    let invocation: any ToolInvocation

    private enum CodingKeys: String, CodingKey {
        case params
    }

    enum ParameterKey: String, CodingKey {
        case name
        case arguments
        case metadata = "_meta"
    }

    init(from decoder: any Decoder, configuration tools: [RegisteredTool]) throws {
        do {
            let envelope = try decoder.container(keyedBy: CodingKeys.self)
            let parameters = try envelope.nestedContainer(keyedBy: ParameterKey.self, forKey: .params)
            let name = try parameters.decode(String.self, forKey: .name)
            let tool = tools.first(where: { $0.definition.name == name })
            if let prepared = tool?.prepareJavaScript(from: parameters) {
                metadata = try parameters.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
                invocation = prepared
                return
            }
            let arguments = try parameters.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
            metadata = try parameters.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
            guard let tool else {
                throw MCPError.invalidParams("Unknown tool: \(name).")
            }
            invocation = try tool.prepare(arguments, from: parameters)
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.invalidParams("Invalid method parameters: \(error.localizedDescription)")
        }
    }
}
