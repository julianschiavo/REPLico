@testable import ReplicoOptimizations
import Foundation
import Testing

struct JSONLineBufferTests {
    @Test
    func lineSearchPreservesTheFirstDelimiterAcrossBlocksAndPartialReads() {
        let otherBytes = (UInt8.min...UInt8.max).filter { $0 != 10 }
        for offset in 0..<96 {
            var bytes = otherBytes
            bytes.insert(10, at: offset)
            bytes.append(10)
            let data = Data(bytes)
            for start in [0, offset, offset + 1, bytes.count - 1, bytes.count] {
                let found = data.bytes.firstLineFeed(from: start)
                #expect(found == bytes[start...].firstIndex(of: 10))
            }
        }
    }

    @Test
    func splitUTF8FramesReassembleBeforeDecoding() throws {
        let bytes = Data("{\"value\":\"😀\"}\n{\"next\":1}\n".utf8)
        var framer = JSONLineBuffer(maximumFrameBytes: 100)
        let split = 12
        #expect(try framer.append(Data(bytes.prefix(split))).isEmpty)
        let frames = try framer.append(Data(bytes.dropFirst(split)))
        #expect(frames.count == 2)
        #expect(String(data: frames[0], encoding: .utf8) == #"{"value":"😀"}"#)
        try framer.finish()
    }

    @Test
    func oversizedAndTruncatedFramesAreRejected() throws {
        var oversized = JSONLineBuffer(maximumFrameBytes: 3)
        #expect(throws: JSONLineBuffer.Failure.frameTooLarge) {
            try oversized.append(Data("1234".utf8))
        }
        var truncated = JSONLineBuffer(maximumFrameBytes: 100)
        _ = try truncated.append(Data("{\"x\":1}".utf8))
        #expect(throws: JSONLineBuffer.Failure.unterminatedFrame) {
            try truncated.finish()
        }
    }

    @Test
    func retainedFramesAndNonzeroInputSlicesSurviveFurtherAppends() throws {
        let source = Data("prefix{\"first\":true}\n{\"next\":".utf8)
        var buffer = JSONLineBuffer(maximumFrameBytes: 100)
        let first = try buffer.append(source.dropFirst(6))
        #expect(first == [Data(#"{"first":true}"#.utf8)])
        let second = try buffer.append(Data("2}\n{\"last\":3}\n".utf8))
        #expect(second == [Data(#"{"next":2}"#.utf8), Data(#"{"last":3}"#.utf8)])
        #expect(first == [Data(#"{"first":true}"#.utf8)])
        try buffer.finish()
    }

    @Test
    func fragmentedLargeFramePreservesItsBytesAndFollowingFrames() throws {
        let first = Data(("{\"text\":\"" + String(repeating: "x", count: 1_024 * 1_024) + "\"}").utf8)
        let second = Data(#"{"next":1}"#.utf8)
        let tail = Data(#"{"tail":true}"#.utf8)
        let wire = first + Data([10]) + second + Data([10]) + Data(#"{"tail":"#.utf8)
        var framer = JSONLineBuffer(maximumFrameBytes: 2 * 1_024 * 1_024)
        var frames: [Data] = []
        for offset in stride(from: 0, to: wire.count, by: 16 * 1_024) {
            frames.append(contentsOf: try framer.append(Data(wire[offset..<min(offset + 16 * 1_024, wire.count)])))
        }
        #expect(frames == [first, second])
        #expect(throws: JSONLineBuffer.Failure.unterminatedFrame) {
            try framer.finish()
        }
        #expect(try framer.append(Data("true}\n".utf8)) == [tail])
        try framer.finish()
    }

    @Test
    func splitUnicodeSurvivesCursorResetsBetweenFrames() throws {
        var framer = JSONLineBuffer(maximumFrameBytes: 100)
        let prefix = Data(#"{"emoji":""#.utf8) + Data([0xF0, 0x9F])
        #expect(try framer.append(prefix).isEmpty)
        let middle = Data([0xA6, 0x8A]) + Data("\"}\n{\"next\":\"".utf8) + Data([0xC3])
        #expect(try framer.append(middle) == [Data(#"{"emoji":"🦊"}"#.utf8)])
        #expect(try framer.append(Data([0x9F]) + Data("\"}\n".utf8)) == [Data(#"{"next":"ß"}"#.utf8)])
        try framer.finish()
    }

    @Test(arguments: [[], [0xFF], [0xC0, 0x80], [0xF0, 0x9F]] as [[UInt8]])
    func emptyOrInvalidUTF8FrameIsRejectedAtTheDelimiter(_ bytes: [UInt8]) throws {
        var framer = JSONLineBuffer(maximumFrameBytes: 100)
        #expect(try framer.append(Data(bytes)).isEmpty)
        #expect(throws: JSONLineBuffer.Failure.invalidFrame) {
            try framer.append(Data([10]))
        }
    }

    @Test
    func byteLimitsIncludePreviouslyScannedFragmentsAndAllowTheExactBoundary() throws {
        var exact = JSONLineBuffer(maximumFrameBytes: 4)
        #expect(try exact.append(Data("ab".utf8)).isEmpty)
        #expect(try exact.append(Data("cd\n".utf8)) == [Data("abcd".utf8)])
        try exact.finish()

        var oversized = JSONLineBuffer(maximumFrameBytes: 4)
        #expect(try oversized.append(Data("abcd".utf8)).isEmpty)
        #expect(throws: JSONLineBuffer.Failure.frameTooLarge) {
            try oversized.append(Data("e\n".utf8))
        }
    }

    @Test
    func everyUnicodeScalarPreservesItsUTF8Bytes() throws {
        var scalars = String.UnicodeScalarView()
        for value in UInt32.min...0x10FFFF {
            if let scalar = Unicode.Scalar(value) {
                scalars.append(scalar)
            }
        }
        let bytes = Data(String(scalars).utf8)
        let delimiter = try #require(bytes.firstIndex(of: 10))
        var buffer = JSONLineBuffer(maximumFrameBytes: bytes.count)
        let frames = try buffer.append(bytes + Data([10]))
        #expect(frames == [bytes[..<delimiter], bytes[bytes.index(after: delimiter)...]])
        try buffer.finish()
    }

    @Test(
        arguments: [
            [0xEF, 0xBB, 0xBF], [0], [0xEF, 0xBB, 0xBF, 0], [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF],
        ] as [[UInt8]])
    func validBOMAndNULBytesArePreservedInSlices(_ bytes: [UInt8]) throws {
        let padding = Data(repeating: 0xFF, count: 3)
        let data = Data(bytes)
        let padded = padding + data + Data([10])
        var buffer = JSONLineBuffer(maximumFrameBytes: data.count)
        #expect(try buffer.append(padded.dropFirst(padding.count)) == [data])
        try buffer.finish()
    }

    @Test
    func malformedScalarBoundariesAreRejectedAcrossWordLanes() throws {
        let malformed: [[UInt8]] = [
            [0x80], [0xBF], [0xC0, 0x80], [0xC1, 0xBF], [0xC2], [0xE0, 0x9F, 0xBF],
            [0xE1, 0x80], [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xEF, 0xBF],
            [0xF0, 0x8F, 0xBF, 0xBF], [0xF1, 0x80, 0x80], [0xF4, 0x90, 0x80, 0x80],
            [0xF5, 0x80, 0x80, 0x80], [0xFE, 0xFF], [0xFF, 0xFE],
        ]
        for bytes in malformed {
            for prefixLength in 0..<8 {
                let prefix = Data(repeating: 0x61, count: prefixLength)
                let padding = Data(repeating: 0xFF, count: 3)
                let data = prefix + Data(bytes)
                let padded = padding + data
                var buffer = JSONLineBuffer(maximumFrameBytes: data.count)
                #expect(try buffer.append(padded.dropFirst(padding.count)).isEmpty)
                #expect(throws: JSONLineBuffer.Failure.invalidFrame) {
                    try buffer.append(Data([10]))
                }
            }
        }
    }
}
