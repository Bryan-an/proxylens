import Foundation
import ProxyLensCore
@preconcurrency import SystemConfiguration

public enum SystemProxyControllerError: LocalizedError, Equatable, Sendable {
    case preferencesUnavailable(String)
    case preferencesLockFailed(String)
    case noEligibleNetworkServices
    case snapshotAlreadyExists
    case snapshotMissing
    case invalidSnapshot
    case serviceUpdateFailed(String)
    case commitFailed(String)
    case applyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .preferencesUnavailable(let message):
            "Unable to open macOS network preferences: \(message)"
        case .preferencesLockFailed(let message):
            "Unable to lock macOS network preferences: \(message)"
        case .noEligibleNetworkServices:
            "No enabled macOS network services expose proxy settings."
        case .snapshotAlreadyExists:
            "A system proxy recovery snapshot already exists."
        case .snapshotMissing:
            "The system proxy recovery snapshot is missing."
        case .invalidSnapshot:
            "The system proxy recovery snapshot is invalid."
        case .serviceUpdateFailed(let serviceID):
            "Unable to update proxy settings for network service \(serviceID)."
        case .commitFailed(let message):
            "Unable to save macOS proxy settings: \(message)"
        case .applyFailed(let message):
            "Unable to apply macOS proxy settings: \(message)"
        }
    }
}

public actor MacOSSystemProxyController: SystemProxyController {
    private struct Snapshot: Codable {
        static let currentVersion = 1

        let version: Int
        let services: [ServiceSnapshot]
    }

    private struct ServiceSnapshot: Codable {
        let serviceID: String
        let configuration: Data?
    }

    private let snapshotURL: URL
    private let fileManager: FileManager

    public init(snapshotURL: URL, fileManager: FileManager = .default) {
        self.snapshotURL = snapshotURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func recoverInterruptedConfiguration() async throws {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return
        }
        try restoreSnapshot(requireExisting: false)
    }

    public func prepareForProxyActivation() async throws {
        guard !fileManager.fileExists(atPath: snapshotURL.path) else {
            throw SystemProxyControllerError.snapshotAlreadyExists
        }

        let preferences = try makePreferences()
        try lock(preferences)
        defer { SCPreferencesUnlock(preferences) }

        let snapshots = try enabledProxyProtocols(in: preferences).map { serviceID, protocolRef in
            ServiceSnapshot(
                serviceID: serviceID,
                configuration: try Self.encodeConfiguration(
                    SCNetworkProtocolGetConfiguration(protocolRef)
                )
            )
        }
        guard !snapshots.isEmpty else {
            throw SystemProxyControllerError.noEligibleNetworkServices
        }

        let snapshot = Snapshot(version: Snapshot.currentVersion, services: snapshots)
        let data = try PropertyListEncoder().encode(snapshot)
        try fileManager.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: snapshotURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: snapshotURL.path
        )
    }

    public func apply(_ configuration: SystemProxyConfiguration) async throws {
        let snapshot = try loadSnapshot(requireExisting: true)
        let preferences = try makePreferences()
        try lock(preferences)
        defer { SCPreferencesUnlock(preferences) }

        let protocols = proxyProtocolsByServiceID(in: preferences)
        for service in snapshot.services {
            guard let protocolRef = protocols[service.serviceID] else {
                continue
            }

            var proxySettings = try Self.decodeConfiguration(service.configuration)
            Self.configure(
                endpoint: configuration.httpEndpoint,
                enableKey: kSCPropNetProxiesHTTPEnable as String,
                hostKey: kSCPropNetProxiesHTTPProxy as String,
                portKey: kSCPropNetProxiesHTTPPort as String,
                in: &proxySettings
            )
            Self.configure(
                endpoint: configuration.httpsEndpoint,
                enableKey: kSCPropNetProxiesHTTPSEnable as String,
                hostKey: kSCPropNetProxiesHTTPSProxy as String,
                portKey: kSCPropNetProxiesHTTPSPort as String,
                in: &proxySettings
            )
            proxySettings[kSCPropNetProxiesExceptionsList as String] = configuration.bypassDomains
            proxySettings[kSCPropNetProxiesExcludeSimpleHostnames as String] = 1
            proxySettings[kSCPropNetProxiesProxyAutoConfigEnable as String] = 0
            proxySettings[kSCPropNetProxiesProxyAutoDiscoveryEnable as String] = 0

            guard SCNetworkProtocolSetConfiguration(protocolRef, proxySettings as CFDictionary)
            else {
                throw SystemProxyControllerError.serviceUpdateFailed(service.serviceID)
            }
        }

        try commitAndApply(preferences)
    }

    public func restorePreviousConfiguration() async throws {
        try restoreSnapshot(requireExisting: true)
    }

    private func restoreSnapshot(requireExisting: Bool) throws {
        let snapshot = try loadSnapshot(requireExisting: requireExisting)
        let preferences = try makePreferences()
        try lock(preferences)
        defer { SCPreferencesUnlock(preferences) }

        let protocols = proxyProtocolsByServiceID(in: preferences)
        for service in snapshot.services {
            guard let protocolRef = protocols[service.serviceID] else {
                continue
            }
            let configuration = try Self.decodeConfiguration(service.configuration)
            let storedConfiguration: CFDictionary? =
                service.configuration == nil ? nil : configuration as CFDictionary
            guard SCNetworkProtocolSetConfiguration(protocolRef, storedConfiguration) else {
                throw SystemProxyControllerError.serviceUpdateFailed(service.serviceID)
            }
        }

        try commitAndApply(preferences)
        try fileManager.removeItem(at: snapshotURL)
    }

    private func loadSnapshot(requireExisting: Bool) throws -> Snapshot {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            if requireExisting {
                throw SystemProxyControllerError.snapshotMissing
            }
            return Snapshot(version: Snapshot.currentVersion, services: [])
        }

        do {
            let data = try Data(contentsOf: snapshotURL, options: .mappedIfSafe)
            let snapshot = try PropertyListDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == Snapshot.currentVersion, !snapshot.services.isEmpty else {
                throw SystemProxyControllerError.invalidSnapshot
            }
            return snapshot
        } catch let error as SystemProxyControllerError {
            throw error
        } catch {
            throw SystemProxyControllerError.invalidSnapshot
        }
    }

    private func makePreferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(nil, "ProxyLens" as CFString, nil) else {
            throw SystemProxyControllerError.preferencesUnavailable(Self.lastSCError())
        }
        return preferences
    }

    private func lock(_ preferences: SCPreferences) throws {
        guard SCPreferencesLock(preferences, true) else {
            throw SystemProxyControllerError.preferencesLockFailed(Self.lastSCError())
        }
    }

    private func commitAndApply(_ preferences: SCPreferences) throws {
        guard SCPreferencesCommitChanges(preferences) else {
            throw SystemProxyControllerError.commitFailed(Self.lastSCError())
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw SystemProxyControllerError.applyFailed(Self.lastSCError())
        }
    }

    private func enabledProxyProtocols(
        in preferences: SCPreferences
    ) throws -> [(String, SCNetworkProtocol)] {
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return []
        }
        return services.compactMap { service in
            guard SCNetworkServiceGetEnabled(service),
                let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                let protocolRef = SCNetworkServiceCopyProtocol(
                    service,
                    kSCNetworkProtocolTypeProxies
                )
            else {
                return nil
            }
            return (serviceID, protocolRef)
        }
    }

    private func proxyProtocolsByServiceID(
        in preferences: SCPreferences
    ) -> [String: SCNetworkProtocol] {
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: services.compactMap { service in
                guard let serviceID = SCNetworkServiceGetServiceID(service) as String?,
                    let protocolRef = SCNetworkServiceCopyProtocol(
                        service,
                        kSCNetworkProtocolTypeProxies
                    )
                else {
                    return nil
                }
                return (serviceID, protocolRef)
            }
        )
    }

    private static func encodeConfiguration(_ configuration: CFDictionary?) throws -> Data? {
        guard let configuration else {
            return nil
        }
        return try PropertyListSerialization.data(
            fromPropertyList: configuration,
            format: .binary,
            options: 0
        )
    }

    private static func decodeConfiguration(_ data: Data?) throws -> [String: Any] {
        guard let data else {
            return [:]
        }
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let configuration = propertyList as? [String: Any] else {
            throw SystemProxyControllerError.invalidSnapshot
        }
        return configuration
    }

    private static func configure(
        endpoint: NetworkEndpoint?,
        enableKey: String,
        hostKey: String,
        portKey: String,
        in settings: inout [String: Any]
    ) {
        guard let endpoint else {
            settings[enableKey] = 0
            settings.removeValue(forKey: hostKey)
            settings.removeValue(forKey: portKey)
            return
        }

        settings[enableKey] = 1
        settings[hostKey] = endpoint.host
        settings[portKey] = Int(endpoint.port)
    }

    private static func lastSCError() -> String {
        String(cString: SCErrorString(SCError()))
    }
}
