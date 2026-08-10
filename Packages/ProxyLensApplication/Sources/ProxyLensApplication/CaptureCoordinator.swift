import Foundation
import ProxyLensCore

public actor CaptureCoordinator {
    private let proxyEngine: any ProxyEngine
    private let sessionStore: any SessionStore
    private let systemProxyController: any SystemProxyController
    private let timeSource: any TimeSource

    private var currentState: CaptureCoordinatorState = .stopped

    public init(
        proxyEngine: any ProxyEngine,
        sessionStore: any SessionStore,
        systemProxyController: any SystemProxyController,
        timeSource: any TimeSource = SystemTimeSource()
    ) {
        self.proxyEngine = proxyEngine
        self.sessionStore = sessionStore
        self.systemProxyController = systemProxyController
        self.timeSource = timeSource
    }

    public func state() -> CaptureCoordinatorState {
        currentState
    }

    /// Restores durable system and session state left by an interrupted process.
    public func recoverInterruptedCapture() async throws {
        switch currentState {
        case .stopped, .failed:
            break
        case .recovering, .starting, .running, .stopping:
            throw CaptureCoordinatorError.invalidTransition(
                action: "recover",
                state: currentState.label
            )
        }

        currentState = .recovering
        var stage = CaptureStartupStage.systemProxyRecovery
        do {
            try await systemProxyController.recoverInterruptedConfiguration()
            stage = .persistenceRecovery
            try await sessionStore.prepareForCaptureStart()
            currentState = .stopped
        } catch {
            let coordinatorError = CaptureCoordinatorError.recoveryFailed(
                stage: stage,
                message: error.localizedDescription
            )
            currentState = .failed(coordinatorError.localizedDescription)
            throw coordinatorError
        }
    }

    @discardableResult
    public func start(configuration: CaptureConfiguration) async throws -> CaptureContext {
        switch currentState {
        case .stopped, .failed:
            break
        case .recovering, .starting, .running, .stopping:
            throw CaptureCoordinatorError.invalidTransition(
                action: "start",
                state: currentState.label
            )
        }

        currentState = .starting

        var stage = CaptureStartupStage.systemProxyRecovery
        var preparedSystemProxy = false
        var createdSession: Session?
        var attemptedEngineStart = false

        do {
            try await systemProxyController.recoverInterruptedConfiguration()

            stage = .persistenceRecovery
            try await sessionStore.prepareForCaptureStart()

            if configuration.configuresSystemProxy {
                stage = .systemProxySnapshot
                try await systemProxyController.prepareForProxyActivation()
                preparedSystemProxy = true
            }

            stage = .sessionCreation
            let startedAt = timeSource.now()
            let session = try await sessionStore.createSession(startedAt: startedAt)
            createdSession = session

            stage = .engineStart
            attemptedEngineStart = true
            try await proxyEngine.start(
                configuration: configuration.proxy,
                sessionID: session.id
            )

            guard case .running(let endpoint) = await proxyEngine.state() else {
                throw ProxyLensError.unsupportedOperation(
                    "The proxy engine did not report a running endpoint"
                )
            }

            if configuration.configuresSystemProxy {
                stage = .systemProxyActivation
                try await systemProxyController.apply(
                    SystemProxyConfiguration(
                        httpEndpoint: endpoint,
                        httpsEndpoint: endpoint,
                        bypassDomains: configuration.bypassDomains
                    )
                )
            }

            let context = CaptureContext(
                sessionID: session.id,
                endpoint: endpoint,
                startedAt: startedAt,
                configuration: configuration
            )
            currentState = .running(context)
            return context
        } catch {
            let primaryMessage = error.localizedDescription
            var rollbackFailures: [String] = []

            if preparedSystemProxy {
                do {
                    try await systemProxyController.restorePreviousConfiguration()
                } catch {
                    rollbackFailures.append(
                        "system proxy restoration: \(error.localizedDescription)"
                    )
                }
            }

            if attemptedEngineStart {
                await proxyEngine.stop()
            }

            if let createdSession {
                do {
                    try await sessionStore.stopSession(
                        sessionID: createdSession.id,
                        at: timeSource.now()
                    )
                } catch {
                    rollbackFailures.append("session closure: \(error.localizedDescription)")
                }
            }

            let coordinatorError = CaptureCoordinatorError.startupFailed(
                stage: stage,
                message: primaryMessage,
                rollbackFailures: rollbackFailures
            )
            currentState = .failed(coordinatorError.localizedDescription)
            throw coordinatorError
        }
    }

    public func stop() async throws {
        guard case .running(let context) = currentState else {
            throw CaptureCoordinatorError.invalidTransition(
                action: "stop",
                state: currentState.label
            )
        }

        currentState = .stopping(context)

        if context.configuration.configuresSystemProxy {
            do {
                try await systemProxyController.restorePreviousConfiguration()
            } catch {
                let coordinatorError = CaptureCoordinatorError.stopFailed(
                    stage: .systemProxyRestoration,
                    message: error.localizedDescription
                )
                currentState = .running(context)
                throw coordinatorError
            }
        }

        await proxyEngine.stop()

        do {
            try await sessionStore.stopSession(
                sessionID: context.sessionID,
                at: timeSource.now()
            )
        } catch {
            let coordinatorError = CaptureCoordinatorError.stopFailed(
                stage: .sessionClosure,
                message: error.localizedDescription
            )
            currentState = .failed(coordinatorError.localizedDescription)
            throw coordinatorError
        }

        currentState = .stopped
    }
}
