import Foundation

/// A length-prefixed image event on a worker connection that enables binary images.
///
/// The ordinary JSON path decodes Base64 into `Data`. The binary path retains a slice of the
/// frame. Both pass the bytes on for the same MIME signature and execution output limit checks.
///
/// JSON with Foundation:
/// ```swift
/// let output = try JSONDecoder().decode(ImageOutput.self, from: frame)
/// validate(output.data, mimeType: output.mimeType)
/// ```
/// Binary worker output:
/// ```swift
/// if let output = WorkerImageFrame(frame) {
///     validate(output.data, mimeType: output.mimeType)
/// }
/// ```
package struct WorkerImageFrame {
    static let prefixSize = 5
    private static let headerSize = 42
    private static let mimeTypes = ["image/jpeg", "image/png", "image/webp", "image/gif"]

    /// Canonical execution ID from the frame header.
    package let executionID: String
    /// MIME type named by the frame's format tag.
    package let mimeType: String
    /// Original image bytes, excluding the framing header and delimiter.
    package let data: Data

    /// Checks the entire header, declared size and execution ID before exposing an image.
    package init?(_ frame: Data) {
        guard let count = try? Self.frameSize(in: frame), frame.count == count else {
            return nil
        }
        let header = frame.prefix(Self.headerSize)
        let id = String(decoding: header.dropFirst(Self.prefixSize).dropLast(), as: UTF8.self)
        guard let tag = header.last, Self.mimeTypes.indices.contains(Int(tag)), UUID(uuidString: id)?.uuidString == id
        else {
            return nil
        }
        executionID = id
        mimeType = Self.mimeTypes[Int(tag)]
        data = frame.dropFirst(Self.headerSize)
    }

    /// Reads the declared frame size without trusting the sender to bound its allocation.
    static func frameSize(in bytes: Data) throws(JSONLineBuffer.Failure) -> Int {
        guard bytes.count >= prefixSize, bytes.first == 0 else {
            throw .invalidFrame
        }
        let body = bytes.prefix(prefixSize).dropFirst().reduce(0) { ($0 << 8) | Int($1) }
        let count = body + prefixSize
        guard count >= headerSize else {
            throw .invalidFrame
        }
        guard count - headerSize <= 8 * 1_024 * 1_024 else {
            throw .frameTooLarge
        }
        return count
    }
}
