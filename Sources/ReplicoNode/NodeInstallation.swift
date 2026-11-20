import ReplicoCore
import ReplicoRuntimeArtifact
import Foundation
import SystemPackage

/// Installs the linked Node binary and its upstream notices as one immutable cache entry.
struct NodeInstallation {
    let cache: RuntimeResourceCache

    func executable() throws -> URL {
        let files = FileManager.default
        let directory = cache.directory
        if try !cache.isInstalled {
            let staging = try cache.makeStagingDirectory()
            defer { try? files.removeItem(at: staging) }
            try File.node.write(to: staging)
            try File.license.write(to: staging)
            try cache.publish(staging)
        }
        let executable = directory.appending(path: File.node.rawValue)
        let node = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let license = try directory.appending(path: File.license.rawValue)
            .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard node.isRegularFile == true, node.isSymbolicLink == false, node.fileSize == Int(REPLICO_NODE_SIZE),
            files.isExecutableFile(atPath: executable.path),
            license.isRegularFile == true, license.isSymbolicLink == false, (license.fileSize ?? 0) > 0
        else {
            throw REPLError.invalidConfiguration("The cached Node installation at \(directory.path) is incomplete.")
        }
        return executable
    }

    private enum File: String {
        case node
        case license = "LICENSE"

        func write(to directory: URL) throws {
            let descriptor = try FileDescriptor.open(
                FilePath(directory.appending(path: rawValue).path), .writeOnly,
                options: [.create, .exclusiveCreate, .noFollow, .closeOnExec],
                permissions: self == .node ? .ownerReadExecute : .ownerRead)
            try descriptor.closeAfter {
                let error: Int32
                switch self {
                case .node:
                    error = replico_write_node_executable(descriptor.rawValue)
                case .license:
                    error = replico_write_node_license(descriptor.rawValue)
                }
                guard error == 0 else {
                    throw Errno(rawValue: error)
                }
            }
        }
    }
}
