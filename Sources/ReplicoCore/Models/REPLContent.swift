import Foundation

/// One ordered text or image item emitted by an evaluation or host service.
public enum REPLContent: Sendable, Equatable {
    /// Text content, with adjacent unnamed writes accumulated together.
    case text(String)
    /// Image bytes and their MIME type; worker images are signature-checked before delivery.
    case image(data: Data, mimeType: String)

    var isText: Bool {
        if case .text = self {
            return true
        }
        return false
    }
}
