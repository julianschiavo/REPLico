import Foundation

/// JSON bytes validated without Foundation's object-tree allocation or numeric conversion.
///
/// The Foundation baseline accepts trailing commas and rejects number tokens outside
/// its representable range. This path rejects trailing commas, malformed UTF-8, and
/// invalid escapes while preserving arbitrary number lexemes. Nesting is limited to
/// 512 containers. Typed values still require a separate Foundation decode.
///
/// Foundation baseline:
/// ```swift
/// _ = try JSONSerialization.jsonObject(
///     with: data,
///     options: [.fragmentsAllowed]
/// )
/// ```
/// Optimized validation:
/// ```swift
/// let document = try JSONDocument(
///     validating: data
/// )
/// ```
package struct JSONDocument: Sendable {
    /// The original, unchanged JSON bytes.
    package let data: Data

    /// Validates one UTF-8 JSON value, throwing `DecodingError.dataCorrupted` for invalid syntax.
    /// `enclosingContainers` accounts for containers outside this slice without expanding the depth limit.
    package init(validating data: Data, enclosingContainers: Int = 0) throws {
        var scanner = JSONScanner(data)
        try scanner.validate(enclosingContainers: enclosingContainers)
        self.data = data
    }
}
