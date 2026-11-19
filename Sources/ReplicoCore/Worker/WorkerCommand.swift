enum WorkerCommand: Encodable, Sendable {
    case evaluate(
        executionID: String, code: String, metadata: [String: JSONValue], moduleDirectories: [String],
        startup: WorkerStartup?
    )
    case serviceReply(executionID: String, requestID: String, ok: Bool, value: ServiceValue, error: String?)
}
