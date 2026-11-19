import Foundation
import Testing
@testable import ReplicoCore

struct ProtocolValidationTests {
    @Test
    func unavailableAuthorityPreservesItsFailure() throws {
        let configuration = REPLConfiguration(
            nodeExecutable: URL(filePath: "/node"),
            environment: [:]
        )
        for failure in [
            REPLError.invalidConfiguration("Missing launch authority."), .invalidRequest("Malformed launch authority."),
        ] {
            #expect(throws: failure) {
                try LaunchPolicy.unavailable(failure).makeWorkerLaunch(configuration: configuration)
            }
        }
    }
}
