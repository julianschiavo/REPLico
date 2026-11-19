import Foundation

/// Buffers bounded, nonempty UTF-8 frames separated by LF bytes. Worker streams can also opt
/// into length-prefixed image frames, whose raw payload can contain any byte including LF.
///
/// A manual Foundation buffer can repeatedly search an incomplete prefix and copy
/// a complete frame when removing its shared prefix. This buffer searches only
/// newly appended bytes, retains completed slices, and copies only an incomplete
/// tail. An empty tail releases the buffer without a copy-on-write mutation.
/// Native `UTF8Span` validation avoids materializing the temporary string required
/// by `String(data: frame, encoding: .utf8)`. JSON syntax is left to the caller's decoder.
///
/// Foundation baseline:
/// ```swift
/// var pending = Data()
/// pending.append(chunk)
/// var frames: [Data] = []
/// while let newline = pending.firstIndex(of: 10) {
///     frames.append(Data(pending[..<newline]))
///     pending.removeSubrange(...newline)
/// }
/// ```
///
/// Optimized buffering, including byte limits and UTF-8 validation:
/// ```swift
/// var buffer = JSONLineBuffer(maximumFrameBytes: 64 * 1_024 * 1_024)
/// let frames = try buffer.append(chunk)
/// // At input EOF:
/// try buffer.finish()
/// ```
package struct JSONLineBuffer: Sendable {
    /// A frame violates the byte limit, encoding, or EOF boundary.
    package enum Failure: Error, Sendable, Equatable {
        /// A complete or incomplete frame exceeds its configured byte limit.
        case frameTooLarge
        /// A delimited frame is empty or contains invalid UTF-8.
        case invalidFrame
        /// Input ends with bytes that have no terminating LF.
        case unterminatedFrame
    }

    private var buffered = Data()
    private let maximumFrameBytes: Int
    private let binaryImages: Bool

    /// Creates a buffer with a per-frame byte limit that excludes its LF delimiter.
    package init(maximumFrameBytes: Int, binaryImages: Bool = false) {
        self.binaryImages = binaryImages
        self.maximumFrameBytes = maximumFrameBytes
    }

    /// Appends bytes and returns complete frames, preserving an incomplete tail.
    package mutating func append(_ bytes: Data) throws(Failure) -> [Data] {
        var frames: [Data] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            if binaryImages && (buffered.first ?? bytes[start]) == 0 {
                if let frame = try appendImage(from: bytes, start: &start) {
                    frames.append(frame)
                }
                continue
            }
            guard let offset = bytes.bytes.firstLineFeed(from: start - bytes.startIndex) else {
                break
            }
            let delimiter = bytes.startIndex + offset
            let fragment = bytes[start..<delimiter]
            guard fragment.count <= maximumFrameBytes - buffered.count else {
                throw .frameTooLarge
            }
            let frame = complete(with: fragment)
            guard !frame.isEmpty else {
                throw .invalidFrame
            }
            do {
                _ = try UTF8Span(validating: Span<UInt8>(viewing: frame.bytes))
            } catch {
                throw .invalidFrame
            }
            frames.append(frame)
            start = bytes.index(after: delimiter)
        }
        let tail = bytes[start...]
        guard tail.count <= maximumFrameBytes - buffered.count else {
            throw .frameTooLarge
        }
        buffered.append(tail)
        return frames
    }

    private mutating func appendImage(from bytes: Data, start: inout Int) throws(Failure) -> Data? {
        if buffered.count < WorkerImageFrame.prefixSize {
            let end = min(bytes.endIndex, start + WorkerImageFrame.prefixSize - buffered.count)
            guard end - start <= maximumFrameBytes - buffered.count else {
                throw .frameTooLarge
            }
            buffered.append(bytes[start..<end])
            start = end
        }
        guard buffered.count >= WorkerImageFrame.prefixSize else {
            return nil
        }
        let size = try WorkerImageFrame.frameSize(in: buffered)
        guard size <= maximumFrameBytes else {
            throw .frameTooLarge
        }
        if buffered.count == WorkerImageFrame.prefixSize {
            buffered.reserveCapacity(size + 1)
        }
        let end = min(bytes.endIndex, start + size + 1 - buffered.count)
        buffered.append(bytes[start..<end])
        start = end
        guard buffered.count == size + 1 else {
            return nil
        }
        guard buffered.last == 10 else {
            throw .invalidFrame
        }
        defer { buffered = Data() }
        return buffered.dropLast()
    }

    private mutating func complete(with fragment: Data) -> Data {
        guard !buffered.isEmpty else {
            return fragment
        }
        buffered.append(fragment)
        defer { buffered = Data() }
        return buffered
    }

    /// Verifies that EOF occurs between frames rather than inside an incomplete frame.
    package func finish() throws(Failure) {
        guard buffered.isEmpty else {
            throw .unterminatedFrame
        }
    }
}
