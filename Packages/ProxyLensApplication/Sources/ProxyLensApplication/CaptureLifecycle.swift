import Foundation
import ProxyLensCore

public struct CaptureConfiguration: Equatable, Sendable {
    public let proxy: ProxyConfiguration
    public let configuresSystemProxy: Bool
    public let bypassDomains: [String]

    public init(
        proxy: ProxyConfiguration,
        configuresSystemProxy: Bool = true,
        bypassDomains: [String] = ["localhost", "127.0.0.1", "::1"]
    ) {
        self.proxy = proxy
        self.configuresSystemProxy = configuresSystemProxy
        self.bypassDomains = bypassDomains
    }
}

public struct CaptureContext: Equatable, Sendable {
    public let sessionID: SessionID
    public let endpoint: NetworkEndpoint
    public let startedAt: Date
    public let configuration: CaptureConfiguration

    public init(
        sessionID: SessionID,
        endpoint: NetworkEndpoint,
        startedAt: Date,
        configuration: CaptureConfiguration
    ) {
        self.sessionID = sessionID
        self.endpoint = endpoint
        self.startedAt = startedAt
        self.configuration = configuration
    }
}

public enum CaptureCoordinatorState: Equatable, Sendable {
    case stopped
    case recovering
    case starting
    case running(CaptureContext)
    case stopping(CaptureContext)
    case failed(String)
}

public enum CaptureStartupStage: String, Equatable, Sendable {
    case systemProxyRecovery
    case persistenceRecovery
    case systemProxySnapshot
    case sessionCreation
    case engineStart
    case systemProxyActivation
}

public enum CaptureStopStage: String, Equatable, Sendable {
    case systemProxyRestoration
    case sessionClosure
}

public enum CaptureCoordinatorError: LocalizedError, Equatable, Sendable {
    case invalidTransition(action: String, state: String)
    case recoveryFailed(stage: CaptureStartupStage, message: String)
    case startupFailed(stage: CaptureStartupStage, message: String, rollbackFailures: [String])
    case stopFailed(stage: CaptureStopStage, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let action, let state):
            "Cannot \(action) capture while the coordinator is \(state)."
        case .recoveryFailed(let stage, let message):
            "Capture recovery failed during \(stage.rawValue): \(message)"
        case .startupFailed(let stage, let message, let rollbackFailures):
            if rollbackFailures.isEmpty {
                "Capture startup failed during \(stage.rawValue): \(message)"
            } else {
                "Capture startup failed during \(stage.rawValue): \(message). Rollback failures: \(rollbackFailures.joined(separator: "; "))"
            }
        case .stopFailed(let stage, let message):
            "Capture shutdown failed during \(stage.rawValue): \(message)"
        }
    }
}

extension CaptureCoordinatorState {
    var label: String {
        switch self {
        case .stopped:
            "stopped"
        case .recovering:
            "recovering"
        case .starting:
            "starting"
        case .running:
            "running"
        case .stopping:
            "stopping"
        case .failed:
            "failed"
        }
    }
}
