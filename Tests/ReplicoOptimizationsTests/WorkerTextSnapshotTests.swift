import ReplicoOptimizations
import Foundation
import Testing

struct WorkerTextSnapshotTests {
    private typealias Update = WorkerTextSnapshot.Update
    private static let key = "11111111-1111-1111-1111-111111111111"
    private static let nextKey = "22222222-2222-2222-2222-222222222222"

    @Test
    func byteEditsPreserveScalarsAndAnInitialByteOrderMark() throws {
        let original = "\u{FEFF}é" + String(repeating: "a", count: 65_536)
        let seed = try Update.seed(key: Self.key).applied(to: nil, text: original, remainingBytes: .max)
        // Keep the first byte of é, replacing its second byte to produce ê.
        let update = Update.change(key: Self.nextKey, base: Self.key, prefix: 4, suffix: 65_536, insert: Data([0xAA]))
        let next = try update.applied(to: seed, text: nil, remainingBytes: original.utf8.count)
        #expect(Array(next.value.utf8) == Array(("\u{FEFF}ê" + String(repeating: "a", count: 65_536)).utf8))
        #expect(throws: WorkerTextSnapshot.Failure.invalidUpdate) {
            try update.applied(to: next, text: nil, remainingBytes: .max)
        }
        #expect(throws: WorkerTextSnapshot.Failure.outputLimit) {
            try update.applied(to: seed, text: nil, remainingBytes: original.utf8.count - 1)
        }
    }

    @Test
    func malformedUpdatesCannotExtendOrCorruptTheBase() throws {
        let text = "é" + String(repeating: "x", count: 65_535)
        let seed = try Update.seed(key: Self.key).applied(to: nil, text: text, remainingBytes: .max)
        let length = text.utf8.count
        for update in [
            Update.change(key: Self.nextKey, base: Self.key, prefix: -1, suffix: 0, insert: Data()),
            .change(key: Self.nextKey, base: Self.key, prefix: .max, suffix: .max, insert: Data()),
            .change(key: Self.nextKey, base: Self.key, prefix: length, suffix: 1, insert: Data()),
            .change(key: Self.nextKey, base: Self.key, prefix: 1, suffix: length - 2, insert: Data()),
            .change(
                key: Self.nextKey, base: Self.key, prefix: length, suffix: 0, insert: Data(repeating: 0, count: 2 << 20)
            ),
            .change(key: Self.nextKey, base: Self.nextKey, prefix: length, suffix: 0, insert: Data()),
        ] {
            #expect(throws: WorkerTextSnapshot.Failure.invalidUpdate) {
                try update.applied(to: seed, text: nil, remainingBytes: .max)
            }
        }
        let repeatValue = Update.change(key: Self.nextKey, base: Self.key, prefix: length, suffix: 0, insert: Data())
        #expect(throws: WorkerTextSnapshot.Failure.invalidUpdate) {
            try repeatValue.applied(to: nil, text: nil, remainingBytes: .max)
        }
        #expect(try repeatValue.applied(to: seed, text: nil, remainingBytes: length).value == text)
    }
}
