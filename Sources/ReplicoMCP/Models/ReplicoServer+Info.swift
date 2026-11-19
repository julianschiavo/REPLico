import Foundation
import MCP

extension ReplicoServer {
    /// The hosting application's identity returned to MCP clients during initialization.
    public typealias Info = MCP.Server.Info

    /// Identifies the running executable using its main bundle.
    ///
    /// The display title comes from the bundle's display name or name. The version
    /// uses the marketing version, then the build version, or "unknown" when neither is present.
    public static var hostInfo: Info {
        let bundle = Bundle.main
        return Info(
            name: bundle.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName,
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            title: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        )
    }
}
