import ReplicoCore

extension EvaluationResult {
    var text: String {
        content.compactMap { item in
            guard case .text(let text) = item else {
                return nil
            }
            return text
        }
        .joined()
    }
}
