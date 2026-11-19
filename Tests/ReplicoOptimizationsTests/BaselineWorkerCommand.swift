enum BaselineWorkerCommand<Value: Encodable>: Encodable {
    case evaluate(executionID: String, code: String, metadata: [String: Value], moduleDirectories: [String])
}
