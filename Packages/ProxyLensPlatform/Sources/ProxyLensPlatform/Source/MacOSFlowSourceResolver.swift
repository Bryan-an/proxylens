import AppKit
import Darwin
import Foundation
import ProxyLensCore

protocol ProcessSocketLocating: Sendable {
    func processIdentifier(clientPort: UInt16, proxyPort: UInt16) -> pid_t?
}

protocol ProcessApplicationInspecting: Sendable {
    func application(processIdentifier: pid_t) -> FlowApplication?
}

public final class MacOSFlowSourceResolver: FlowSourceResolver, @unchecked Sendable {
    private let socketLocator: any ProcessSocketLocating
    private let applicationInspector: any ProcessApplicationInspecting
    private let queue: DispatchQueue

    public convenience init() {
        self.init(
            socketLocator: LibprocProcessSocketLocator(),
            applicationInspector: MacOSProcessApplicationInspector()
        )
    }

    init(
        socketLocator: any ProcessSocketLocating,
        applicationInspector: any ProcessApplicationInspecting,
        queue: DispatchQueue = DispatchQueue(
            label: "com.proxylens.flow-source-attribution",
            qos: .utility
        )
    ) {
        self.socketLocator = socketLocator
        self.applicationInspector = applicationInspector
        self.queue = queue
    }

    public func resolveSource(
        clientEndpoint: NetworkEndpoint,
        proxyEndpoint: NetworkEndpoint
    ) async -> FlowSource {
        await withCheckedContinuation { continuation in
            queue.async { [socketLocator, applicationInspector] in
                let clientAddress = Self.address(clientEndpoint)
                guard
                    let processIdentifier = socketLocator.processIdentifier(
                        clientPort: clientEndpoint.port,
                        proxyPort: proxyEndpoint.port
                    ),
                    let application = applicationInspector.application(
                        processIdentifier: processIdentifier
                    )
                else {
                    continuation.resume(
                        returning: FlowSource(
                            kind: .desktopProxy,
                            label: "Desktop proxy",
                            clientAddress: clientAddress
                        )
                    )
                    return
                }

                continuation.resume(
                    returning: FlowSource(
                        kind: .desktopProxy,
                        label: application.name,
                        clientAddress: clientAddress,
                        application: application
                    )
                )
            }
        }
    }

    private static func address(_ endpoint: NetworkEndpoint) -> String {
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        return "\(host):\(endpoint.port)"
    }
}

struct LibprocProcessSocketLocator: ProcessSocketLocating {
    private static let maximumDescriptorBufferBytes = 1_048_576

    func processIdentifier(clientPort: UInt16, proxyPort: UInt16) -> pid_t? {
        let estimatedProcessCount = proc_listallpids(nil, 0)
        guard estimatedProcessCount > 0 else {
            return nil
        }

        var processIdentifiers = [pid_t](
            repeating: 0,
            count: Int(estimatedProcessCount) + 128
        )
        let processCount = processIdentifiers.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard processCount > 0 else {
            return nil
        }

        for processIdentifier in processIdentifiers.prefix(Int(processCount))
        where processIdentifier > 0 {
            if processOwnsSocket(
                processIdentifier,
                clientPort: clientPort,
                proxyPort: proxyPort
            ) {
                return processIdentifier
            }
        }
        return nil
    }

    private func processOwnsSocket(
        _ processIdentifier: pid_t,
        clientPort: UInt16,
        proxyPort: UInt16
    ) -> Bool {
        let requiredBytes = proc_pidinfo(
            processIdentifier,
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        guard requiredBytes > 0 else {
            return false
        }

        let descriptorStride = MemoryLayout<proc_fdinfo>.stride
        let bufferBytes = min(
            Int(requiredBytes) + (32 * descriptorStride),
            Self.maximumDescriptorBufferBytes
        )
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: max(1, bufferBytes / descriptorStride)
        )
        let returnedBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDLISTFDS,
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard returnedBytes > 0 else {
            return false
        }

        let descriptorCount = min(
            descriptors.count,
            Int(returnedBytes) / descriptorStride
        )
        for descriptor in descriptors.prefix(descriptorCount)
        where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socketInformation = socket_fdinfo()
            let socketInformationBytes = withUnsafeMutablePointer(to: &socketInformation) {
                proc_pidfdinfo(
                    processIdentifier,
                    descriptor.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    $0,
                    Int32(MemoryLayout<socket_fdinfo>.size)
                )
            }
            guard socketInformationBytes == MemoryLayout<socket_fdinfo>.size else {
                continue
            }
            let socket = socketInformation.psi
            guard
                socket.soi_family == AF_INET || socket.soi_family == AF_INET6,
                socket.soi_protocol == IPPROTO_TCP,
                socket.soi_kind == SOCKINFO_TCP
            else {
                continue
            }

            let internetSocket = socket.soi_proto.pri_tcp.tcpsi_ini
            let localPort = UInt16(
                bigEndian: UInt16(truncatingIfNeeded: internetSocket.insi_lport)
            )
            let foreignPort = UInt16(
                bigEndian: UInt16(truncatingIfNeeded: internetSocket.insi_fport)
            )
            if localPort == clientPort, foreignPort == proxyPort {
                return true
            }
        }
        return false
    }
}

private struct MacOSProcessApplicationInspector: ProcessApplicationInspecting {
    func application(processIdentifier: pid_t) -> FlowApplication? {
        let runningApplication = NSRunningApplication(processIdentifier: processIdentifier)
        let executablePath =
            executablePath(processIdentifier: processIdentifier)
            ?? runningApplication?.executableURL?.path
        let bundlePath =
            outermostApplicationBundlePath(in: executablePath)
            ?? runningApplication?.bundleURL?.path
        let bundle = bundlePath.flatMap(Bundle.init(path:))
        let name =
            displayName(bundle: bundle)
            ?? runningApplication?.localizedName
            ?? executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? processName(processIdentifier: processIdentifier)
        guard let name, !name.isEmpty else {
            return nil
        }

        return FlowApplication(
            name: name,
            bundleIdentifier: bundle?.bundleIdentifier ?? runningApplication?.bundleIdentifier,
            bundlePath: bundlePath,
            executablePath: executablePath,
            processIdentifier: processIdentifier
        )
    }

    private func executablePath(processIdentifier: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBytes { buffer in
            proc_pidpath(processIdentifier, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else {
            return nil
        }
        return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private func processName(processIdentifier: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 1_024)
        let length = name.withUnsafeMutableBytes { buffer in
            proc_name(processIdentifier, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else {
            return nil
        }
        return name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private func outermostApplicationBundlePath(in executablePath: String?) -> String? {
        guard let executablePath else {
            return nil
        }
        let components = NSString(string: executablePath).pathComponents
        guard
            let applicationIndex = components.firstIndex(where: {
                $0.lowercased().hasSuffix(".app")
            })
        else {
            return nil
        }
        return NSString.path(withComponents: Array(components[...applicationIndex]))
    }

    private func displayName(bundle: Bundle?) -> String? {
        guard let bundle else {
            return nil
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
    }
}
