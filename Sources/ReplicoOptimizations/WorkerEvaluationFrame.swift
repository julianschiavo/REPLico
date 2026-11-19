import Foundation

/// An evaluation command for a configured worker. Foundation's baseline encodes
/// the whole command. This frame streams source text into its JSON buffer and
/// preserves Foundation's coding path and depth checks for arbitrary metadata.
///
/// Foundation:
/// ```swift
/// let data = try JSONEncoder().encode(command)
/// ```
/// Optimized:
/// ```swift
/// let data = try WorkerEvaluationFrame(executionID: id, code: source,
///     metadata: metadata, moduleDirectories: directories).data
/// ```
package struct WorkerEvaluationFrame: Sendable {
    private enum MetadataCommand<Value: Encodable>: Encodable {
        case evaluate(metadata: Value)
    }

    /// UTF-8 JSON bytes, excluding the transport delimiter.
    package let data: Data

    /// Encodes the source and the options belonging to this evaluation.
    package init<Value: Encodable>(
        executionID: String, code: String, reusing slot: Int? = nil, metadata: [String: Value],
        moduleDirectories: [String]
    ) throws {
        let foundation = JSONEncoder()
        let encodedMetadata =
            metadata.isEmpty
            ? nil
            : try Self.value(
                in: MetadataCommand.evaluate(metadata: metadata),
                prefix: "{\"evaluate\":{\"metadata\":"
            )
        let encodedDirectories =
            moduleDirectories.isEmpty ? nil : try JSONDocument(validating: foundation.encode(moduleDirectories))
        var writer = JSONWriter(
            reservingCapacity: (slot == nil ? code.utf8.count : 1) + (encodedMetadata?.data.count ?? 2)
                + (encodedDirectories?.data.count ?? 2) + 256
        )
        writer.writeSyntax("{\"evaluate\":{\"executionID\":")
        writer.write(executionID)
        writer.writeSyntax(",\"code\":")
        if let slot {
            writer.write(slot)
        } else {
            writer.write(code)
        }
        writer.writeSyntax(",\"metadata\":")
        if let encodedMetadata {
            writer.write(encodedMetadata)
        } else {
            writer.writeSyntax("{}")
        }
        writer.writeSyntax(",\"moduleDirectories\":")
        if let encodedDirectories {
            writer.write(encodedDirectories)
        } else {
            writer.writeSyntax("[]")
        }
        writer.writeSyntax("}}")
        data = writer.data
    }

    private static func value<Command: Encodable>(in command: Command, prefix: StaticString) throws -> JSONDocument {
        let encoded = try JSONEncoder().encode(command)
        let prefix = Data(prefix.description.utf8)
        guard encoded.starts(with: prefix), encoded.suffix(2).elementsEqual([0x7D, 0x7D]) else {
            throw EncodingError.invalidValue(
                command,
                .init(codingPath: [], debugDescription: "Foundation changed the native command envelope shape.")
            )
        }
        return try JSONDocument(validating: encoded.dropFirst(prefix.count).dropLast(2))
    }
}
