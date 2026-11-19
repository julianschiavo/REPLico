extension RawSpan {
    /// Finds a quote, backslash, or control in a bounded JSON string without
    /// decoding its scalars. UTF-8 validation belongs to the reader of the span.
    func firstJSONSpecialByte(from start: Int, to end: Int) -> Int {
        var position = start
        while end - position >= 8 {
            let count = plainJSONBlockLength(at: position, endingAt: end)
            if count > 0 {
                position += count
                continue
            }
            let blockEnd = position + 8
            while position < blockEnd {
                let byte = load(fromByteOffset: position, as: UInt8.self)
                if byte < 0x20 || byte == 0x22 || byte == 0x5C {
                    return position
                }
                position += 1
            }
        }
        while position < end {
            let byte = load(fromByteOffset: position, as: UInt8.self)
            if byte < 0x20 || byte == 0x22 || byte == 0x5C {
                return position
            }
            position += 1
        }
        return end
    }

    /// Returns the length of a block with no JSON escapes. The caller has at least eight bytes.
    func plainJSONBlockLength(at position: Int, endingAt end: Int) -> Int {
        if end - position >= 32 {
            let block = load(fromByteOffset: position, as: SIMD4<UInt64>.self)
            let controls = (block &- SIMD4(repeating: 0x2020_2020_2020_2020)) & ~block
            let quotes = block ^ SIMD4(repeating: 0x2222_2222_2222_2222)
            let slashes = block ^ SIMD4(repeating: 0x5C5C_5C5C_5C5C_5C5C)
            let quoteZeros = (quotes &- SIMD4(repeating: 0x0101_0101_0101_0101)) & ~quotes
            let slashZeros = (slashes &- SIMD4(repeating: 0x0101_0101_0101_0101)) & ~slashes
            let candidates = (controls | quoteZeros | slashZeros) & SIMD4(repeating: 0x8080_8080_8080_8080)
            if candidates[0] | candidates[1] | candidates[2] | candidates[3] == 0 {
                return 32
            }
        }
        let block = load(fromByteOffset: position, as: UInt64.self)
        let controls = (block &- 0x2020_2020_2020_2020) & ~block
        let quotes = block ^ 0x2222_2222_2222_2222
        let slashes = block ^ 0x5C5C_5C5C_5C5C_5C5C
        let quoteZeros = (quotes &- 0x0101_0101_0101_0101) & ~quotes
        let slashZeros = (slashes &- 0x0101_0101_0101_0101) & ~slashes
        if (controls | quoteZeros | slashZeros) & 0x8080_8080_8080_8080 == 0 {
            return 8
        }
        return 0
    }
}
