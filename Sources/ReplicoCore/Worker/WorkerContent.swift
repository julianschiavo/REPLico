import ReplicoOptimizations
import Foundation

struct WorkerContent: Decodable, Sendable {
    enum Kind: String, Decodable {
        case text
        case image
    }

    let type: Kind
    let text: String?
    let data: Data?
    let mimeType: String?
    let itemID: String?

    var update: WorkerTextSnapshot.Update? = nil

    func validatedContent(snapshot: inout WorkerTextSnapshot?, remainingBytes: Int) throws -> REPLContent {
        guard let update else {
            return try validatedContent()
        }
        guard type == .text, itemID == nil else {
            throw REPLError.protocolViolation("Only unnamed text can update the worker text base.")
        }
        do {
            let next = try update.applied(to: snapshot, text: text, remainingBytes: remainingBytes)
            snapshot = next
            return .text(next.value)
        } catch .outputLimit {
            throw REPLError.protocolViolation("Execution output exceeds the configured byte limit.")
        } catch {
            throw REPLError.protocolViolation("Worker text update has an invalid base, range or encoding.")
        }
    }

    func validatedContent() throws -> REPLContent {
        switch type {
        case .text:
            guard let text else {
                throw REPLError.protocolViolation("Worker text content is missing text.")
            }
            return .text(text)
        case .image:
            guard let bytes = data, bytes.count <= 8 * 1_024 * 1_024, let mimeType else {
                throw REPLError.protocolViolation("Worker returned invalid or oversized image content.")
            }
            let signature = Array(bytes.prefix(12))
            let valid: Bool
            switch mimeType {
            case "image/png":
                valid = signature.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            case "image/jpeg":
                valid = signature.starts(with: [255, 216, 255])
            case "image/webp":
                valid =
                    signature.count >= 12 && Array(signature[0..<4]) == Array("RIFF".utf8)
                    && Array(signature[8..<12]) == Array("WEBP".utf8)
            case "image/gif":
                valid = signature.starts(with: Array("GIF87a".utf8)) || signature.starts(with: Array("GIF89a".utf8))
            default:
                valid = false
            }
            guard valid else {
                throw REPLError.protocolViolation("Image bytes do not match a supported MIME type.")
            }
            return .image(data: bytes, mimeType: mimeType)
        }
    }
}
