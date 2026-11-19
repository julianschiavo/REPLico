import ReplicoCore
import MCP

extension EvaluationResult {
    func makeMCPResult() -> CallTool.Result {
        let items = content.isEmpty && !didFail ? [.text("")] : content
        return CallTool.Result(
            content: items.map { item in
                switch item {
                case .text(let text):
                    return .text(text: text, annotations: nil, _meta: nil)
                case .image(let data, let mimeType):
                    return .image(data: data.base64EncodedString(), mimeType: mimeType, annotations: nil, _meta: nil)
                }
            }, isError: didFail)
    }
}
