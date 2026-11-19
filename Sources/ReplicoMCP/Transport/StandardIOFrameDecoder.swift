import ReplicoOptimizations
import MCP
import NIOCore

/// Scans each incoming byte once and preserves LF as the sole frame delimiter.
struct StandardIOFrameDecoder: NIOSingleStepByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    private let maximumMessageBytes: Int
    private var scannedBytes = 0

    init(maximumMessageBytes: Int) {
        self.maximumMessageBytes = maximumMessageBytes
    }

    mutating func decode(buffer: inout ByteBuffer) throws -> ByteBuffer? {
        while let length = buffer.readableBytesUInt8Span.bytes.firstLineFeed(from: scannedBytes) {
            guard length <= maximumMessageBytes else {
                throw MCPError.invalidRequest("MCP message exceeds the input byte limit.")
            }
            let frame = buffer.readSlice(length: length)!
            buffer.moveReaderIndex(forwardBy: 1)
            scannedBytes = 0
            if length != 0 {
                return frame
            }
        }
        guard buffer.readableBytes <= maximumMessageBytes else {
            throw MCPError.invalidRequest("MCP message exceeds the input byte limit.")
        }
        scannedBytes = buffer.readableBytes
        return nil
    }

    mutating func decodeLast(buffer: inout ByteBuffer, seenEOF: Bool) throws -> ByteBuffer? {
        if let frame = try decode(buffer: &buffer) {
            return frame
        }
        // Match the SDK transport: EOF discards an unterminated final message.
        buffer.moveReaderIndex(to: buffer.writerIndex)
        return nil
    }
}
