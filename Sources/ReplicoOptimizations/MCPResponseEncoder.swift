import Foundation
import MCP
import NIOCore

/// Encodes plain text/image tool responses with bulk UTF-8 copying.
///
/// Foundation's `JSONEncoder` supports every SDK content shape and metadata field.
/// This encoder writes the fixed plain text/image shape directly. Annotations, metadata,
/// structured content, other payloads and protocol errors use Foundation unchanged.
/// Request identifiers are always encoded by Foundation, preserving their concrete type.
///
/// Foundation:
/// ```swift
/// let data = try JSONEncoder().encode(response)
/// ```
///
/// Optimized, using a `JSONRPCEnvelope`:
/// ```swift
/// let encoder = MCPResponseEncoder()
/// let data = try encoder.encode(response)
/// ```
package struct MCPResponseEncoder {
    private static let headerStart: StaticString = "{\"jsonrpc\":\"2.0\",\"id\":"
    private let foundation = JSONEncoder()

    /// Creates an encoder with Foundation's default coding behavior as its fallback.
    package init() {
    }

    /// Encodes the complete envelope, selecting the optimized path only for supported shapes.
    package func encode<Response: JSONRPCEnvelope>(_ response: Response) throws -> Data {
        try encode(response, using: nil)
    }

    private func encode<Response: JSONRPCEnvelope>(_ response: Response, using identifier: JSONDocument?) throws -> Data
    {
        guard response.jsonrpc == "2.0", response.error == nil,
            let result = response.result as? CallTool.Result,
            result.structuredContent == nil, result._meta == nil,
            let size = plainContentSize(result.content)
        else {
            return try foundation.encode(response)
        }
        let identifier = try identifier ?? JSONDocument(validating: foundation.encode(response.id))
        var writer = JSONWriter(reservingCapacity: size + identifier.data.count + 128)
        writer.writeSyntax(Self.headerStart)
        writer.write(identifier)
        writer.writeSyntax(",\"result\":{\"content\":[")
        for index in result.content.indices {
            if index > 0 {
                writer.writeSyntax(",")
            }
            switch result.content[index] {
            case .text(let text, nil, nil):
                writer.writeSyntax("{\"type\":\"text\",\"text\":")
                writer.write(text)
            case .image(let data, let mimeType, nil, nil):
                writer.writeSyntax("{\"type\":\"image\",\"data\":")
                writer.write(data)
                writer.writeSyntax(",\"mimeType\":")
                writer.write(mimeType)
            default:
                // The eligibility check above makes this unreachable.
                return try foundation.encode(response)
            }
            writer.writeSyntax("}")
        }
        writer.writeSyntax("]")
        if let isError = result.isError {
            writer.writeSyntax(",\"isError\":")
            writer.write(isError)
        }
        writer.writeSyntax("}}")
        return writer.data
    }

    /// The complete bytes of one standard I/O response, including its final newline.
    package enum Frame {
        /// A newly encoded response in one buffer.
        case contiguous(ByteBuffer)
        /// A new request ID followed by a previously encoded result and newline.
        case segments(header: ByteBuffer, body: ByteBuffer)
    }

    private struct Entry {
        enum State {
            case observed
            case encoded(ByteBuffer)
        }

        let text: String
        let isError: Bool?
        let state: State
    }

    private var entry: Entry?

    /// Shares the encoded body of a recurring large text reply across standard I/O writes.
    ///
    /// A caller using Foundation typically sends `try JSONEncoder().encode(response)`
    /// on each call. A pipe writer can use `try encoder.frame(for: response)` to send
    /// the returned buffers in order, or use `try encoder.encode(response)` on a miss.
    /// Two observations of identical string storage and error status establish a reusable
    /// body. Each reply encodes its own ID. A different reply invalidates the entry.
    package mutating func frame<Response: JSONRPCEnvelope>(for response: Response) throws -> Frame? {
        guard response.jsonrpc == "2.0", response.error == nil, let result = response.result as? CallTool.Result,
            result.structuredContent == nil, result._meta == nil, result.content.count == 1,
            case .text(let text, nil, nil) = result.content[0], (65_536...2_097_152).contains(text.utf8.count)
        else {
            entry = nil
            return nil
        }
        guard let previous = entry, previous.isError == result.isError,
            text.utf8Span.isTriviallyIdentical(to: previous.text.utf8Span)
        else {
            entry = Entry(text: text, isError: result.isError, state: .observed)
            return nil
        }
        let identifier = try JSONDocument(validating: foundation.encode(response.id))
        var header = ByteBuffer(string: Self.headerStart.description)
        header.writeBytes(identifier.data)
        switch previous.state {
        case .encoded(let body):
            return .segments(header: header, body: body)
        case .observed:
            let encoded = try encode(response, using: identifier)
            var frame = ByteBufferAllocator().buffer(capacity: encoded.count + 1)
            frame.writeBytes(encoded)
            frame.writeInteger(UInt8(10))
            let length = frame.readableBytes - header.readableBytes
            if length <= 2_097_280, frame.capacity <= 4_194_304,
                let slice = frame.getSlice(at: header.readableBytes, length: length)
            {
                entry = Entry(text: text, isError: result.isError, state: .encoded(slice))
            } else {
                entry = nil
            }
            return .contiguous(frame)
        }
    }

    private func plainContentSize(_ content: [Tool.Content]) -> Int? {
        var size = 0
        for item in content {
            switch item {
            case .text(let text, nil, nil):
                size += text.utf8.count + 32
            case .image(let data, let mimeType, nil, nil):
                size += data.utf8.count + mimeType.utf8.count + 48
            default:
                return nil
            }
        }
        return size
    }
}
