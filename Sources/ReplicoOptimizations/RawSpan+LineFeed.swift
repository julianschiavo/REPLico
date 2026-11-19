extension RawSpan {
    /// Finds the first LF at or after a byte offset, returning an offset in this span.
    ///
    /// Foundation can search with `data.range(of: Data([10]))`. For NIO, the
    /// equivalent is `buffer.readableBytesView.dropFirst(scanned).firstIndex(of: 10)`.
    /// Both readers can instead use `bytes.firstLineFeed(from: scanned)`.
    /// Checking 32 bytes at a time avoids a collection index operation per byte.
    package func firstLineFeed(from start: Int = 0) -> Int? {
        var offset = start
        while byteCount - offset >= 32 {
            // XOR turns LF into a zero byte. A high bit flags a block for the exact search below.
            let delta = load(fromByteOffset: offset, as: SIMD4<UInt64>.self) ^ SIMD4(repeating: 0x0A0A_0A0A_0A0A_0A0A)
            let flags =
                (delta &- SIMD4(repeating: 0x0101_0101_0101_0101)) & ~delta & SIMD4(repeating: 0x8080_8080_8080_8080)
            if flags[0] | flags[1] | flags[2] | flags[3] != 0 {
                break
            }
            offset += 32
        }
        while offset < byteCount {
            if load(fromByteOffset: offset, as: UInt8.self) == 10 {
                return offset
            }
            offset += 1
        }
        return nil
    }
}
