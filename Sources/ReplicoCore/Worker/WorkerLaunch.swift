import Foundation

struct WorkerLaunch: Sendable {
    let executable: URL
    let arguments: [String]
}
