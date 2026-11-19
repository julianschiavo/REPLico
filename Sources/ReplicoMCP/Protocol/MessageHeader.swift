import ReplicoCore

/// Decodes routing fields while leaving method parameters for their concrete wire types.
struct MessageHeader: Decodable {
    let version: String?
    let requestID: JSONValue?
    let method: String?

    private enum CodingKeys: String, CodingKey {
        case version = "jsonrpc"
        case requestID = "id"
        case method
    }

    init(toolCallID: UInt64) {
        version = "2.0"
        requestID = toolCallID <= UInt64(Int64.max) ? .integer(Int64(toolCallID)) : .unsignedInteger(toolCallID)
        method = RequestMethod.callTool.rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The complete document has already passed syntax and Unicode validation.
        version = try? container.decode(String.self, forKey: .version)
        // decodeIfPresent would conflate a notification's absent ID with an invalid null ID.
        requestID = container.contains(.requestID) ? try container.decode(JSONValue.self, forKey: .requestID) : nil
        method = try? container.decode(String.self, forKey: .method)
    }
}
