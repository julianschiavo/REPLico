import MCP

/// A Foundation-decoded model and the number of distinct keys in its JSON object.
/// This lets a caller with a known schema prove it consumed every field without
/// decoding string values into a second dictionary.
///
/// Foundation's general schema path decodes the values as well as the model:
/// ```swift
/// let values = try parameters.decode([String: JSONValue].self, forKey: .arguments)
/// let arguments = try parameters.decode(Arguments.self, forKey: .arguments)
/// ```
/// For a model whose populated properties each require one distinct key:
/// ```swift
/// let object = try parameters.decode(DecodedJSONObject<Arguments>.self, forKey: .arguments)
/// if object.fieldCount == expectedFieldCount { use(object.value) }
/// ```
package struct DecodedJSONObject<Value: Decodable>: Decodable {
    /// The model decoded with the original coding path and decoder settings.
    package let value: Value
    /// Includes unrecognized keys and keys whose values are null.
    package let fieldCount: Int

    /// Reads both views from the same Foundation decoder.
    package init(from decoder: any Decoder) throws {
        value = try Value(from: decoder)
        fieldCount = try [String: MCP.Empty](from: decoder).count
    }
}
