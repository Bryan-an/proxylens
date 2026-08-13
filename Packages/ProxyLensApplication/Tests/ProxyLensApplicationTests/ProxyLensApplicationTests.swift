import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensApplication

final class ProxyLensApplicationTests: XCTestCase {
    func testRuleEnginePublishesHostRulesToTheSharedSnapshot() async {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot)

        let blocked = await engine.blockHost("ads.example.com", reason: "tracker")
        let allowed = await engine.allowHost("api.example.com")
        let noCache = await engine.disableCaching(forHost: "cdn.example.com")

        let rules = snapshot.currentRules()
        XCTAssertEqual(rules.rules.map(\.id), [blocked.id, allowed.id] + noCache.map(\.id))
        XCTAssertEqual(
            rules.matchingRules(
                for: RuleMatchContext(
                    request: HTTPRequest(
                        method: .get,
                        url: URL(string: "https://ads.example.com/pixel")!
                    )
                ),
                phase: .requestHeaders
            ).map(\.action),
            [.block(reason: "tracker")]
        )
        XCTAssertEqual(
            rules.matchingRules(
                for: RuleMatchContext(
                    request: HTTPRequest(
                        method: .get,
                        url: URL(string: "https://api.example.com/v1")!
                    )
                ),
                phase: .requestHeaders
            ).map(\.action),
            [.allow]
        )
        XCTAssertEqual(
            rules.matchingRules(
                for: RuleMatchContext(
                    request: HTTPRequest(
                        method: .get,
                        url: URL(string: "https://cdn.example.com/app.js")!
                    )
                ),
                phase: .responseHeaders
            ).map(\.action),
            [.noCache]
        )
    }

    func testRuleEngineLoadsMapLocalFileIntoTheSharedSnapshot() async throws {
        let snapshot = MutableRuleSnapshot()
        let engine = RuleEngine(snapshot: snapshot, maximumMapLocalBytes: 1_024)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-map-local-\(UUID().uuidString).json")
        let body = Data(#"{"mapped":true}"#.utf8)
        try body.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let rule = try await engine.mapLocal(
            host: "api.example.com",
            path: "/users?unused=1",
            fileURL: fileURL,
            statusCode: 201
        )

        XCTAssertEqual(rule.name, "Map local api.example.com/users")
        XCTAssertEqual(rule.priority, 15)
        XCTAssertEqual(rule.phase, .requestHeaders)
        guard case .mapLocal(let resourceID) = rule.action else {
            return XCTFail("Expected a map local action")
        }

        let spec = try XCTUnwrap(snapshot.mappedLocal(for: resourceID))
        XCTAssertEqual(spec.statusCode, 201)
        XCTAssertEqual(spec.filePath, fileURL.path)
        XCTAssertEqual(spec.body.contentType, "application/json")
        XCTAssertEqual(spec.body.storage, .inline(body))

        let matching = snapshot.currentRules().matchingRules(
            for: RuleMatchContext(
                request: HTTPRequest(
                    method: .get,
                    url: URL(string: "https://api.example.com/users")!
                )
            ),
            phase: .requestHeaders
        )
        XCTAssertEqual(matching.map(\.id), [rule.id])

        let tooLarge = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxylens-map-local-too-large-\(UUID().uuidString).bin")
        try Data(repeating: 0x61, count: 2_048).write(to: tooLarge)
        defer { try? FileManager.default.removeItem(at: tooLarge) }

        do {
            _ = try await engine.mapLocal(
                host: "api.example.com",
                path: "/huge",
                fileURL: tooLarge
            )
            XCTFail("Expected an oversized Map Local file to be rejected")
        } catch let error as RuleEngineError {
            XCTAssertEqual(
                error,
                .mapLocalFileTooLarge(byteCount: 2_048, maximumByteCount: 1_024)
            )
        }

        await engine.remove(id: rule.id)
        XCTAssertNil(snapshot.mappedLocal(for: resourceID))
        XCTAssertTrue(snapshot.currentRules().rules.isEmpty)
    }

    func testStartUsesCreatedSessionAndStopRestoresDependenciesInOrder() async throws {
        let recorder = CallRecorder()
        let sessionID = SessionID()
        let sessionStore = RecordingSessionStore(sessionID: sessionID, recorder: recorder)
        let proxyEngine = RecordingProxyEngine(
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_080),
            recorder: recorder
        )
        let systemProxy = RecordingSystemProxyController(recorder: recorder)
        let now = Date(timeIntervalSince1970: 1_000)
        let coordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: sessionStore,
            systemProxyController: systemProxy,
            timeSource: FixedTimeSource(date: now)
        )
        let configuration = Self.captureConfiguration()

        let context = try await coordinator.start(configuration: configuration)

        XCTAssertEqual(context.sessionID, sessionID)
        XCTAssertEqual(context.startedAt, now)
        XCTAssertEqual(context.endpoint, NetworkEndpoint(host: "127.0.0.1", port: 58_080))
        let receivedSessionIDs = await proxyEngine.receivedSessionIDs()
        XCTAssertEqual(receivedSessionIDs, [sessionID])
        let createdSession = await sessionStore.loadSession(sessionID: sessionID)
        XCTAssertEqual(createdSession?.state, .recording)
        let appliedConfigurations = await systemProxy.appliedConfigurations()
        XCTAssertEqual(
            appliedConfigurations,
            [
                SystemProxyConfiguration(
                    httpEndpoint: context.endpoint,
                    httpsEndpoint: context.endpoint,
                    bypassDomains: configuration.bypassDomains
                )
            ]
        )
        let startupCalls = await recorder.snapshot()
        XCTAssertEqual(
            startupCalls,
            [
                "proxy.recover",
                "session.recover",
                "proxy.prepare",
                "session.create",
                "engine.start",
                "proxy.apply"
            ]
        )

        try await coordinator.stop()

        let stoppedSession = await sessionStore.loadSession(sessionID: sessionID)
        XCTAssertEqual(stoppedSession?.state, .stopped)
        let finalState = await coordinator.state()
        XCTAssertEqual(finalState, .stopped)
        let allCalls = await recorder.snapshot()
        XCTAssertEqual(
            allCalls,
            startupCalls + ["proxy.restore", "engine.stop", "session.stop"]
        )
    }

    func testLifecycleRejectsReentrantAndInvalidTransitions() async throws {
        let recorder = CallRecorder()
        let enteredStart = AsyncGate()
        let resumeStart = AsyncGate()
        let proxyEngine = RecordingProxyEngine(
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_081),
            recorder: recorder,
            enteredStart: enteredStart,
            resumeStart: resumeStart
        )
        let coordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: RecordingSessionStore(sessionID: SessionID(), recorder: recorder),
            systemProxyController: RecordingSystemProxyController(recorder: recorder)
        )
        let configuration = Self.captureConfiguration()

        let startTask = Task {
            try await coordinator.start(configuration: configuration)
        }
        await enteredStart.wait()

        do {
            _ = try await coordinator.start(configuration: configuration)
            XCTFail("Expected a second start to be rejected")
        } catch let error as CaptureCoordinatorError {
            guard case .invalidTransition(action: "start", state: "starting") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            try await coordinator.stop()
            XCTFail("Expected stop during startup to be rejected")
        } catch let error as CaptureCoordinatorError {
            guard case .invalidTransition(action: "stop", state: "starting") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await resumeStart.open()
        _ = try await startTask.value

        do {
            _ = try await coordinator.start(configuration: configuration)
            XCTFail("Expected start while running to be rejected")
        } catch let error as CaptureCoordinatorError {
            guard case .invalidTransition(action: "start", state: "running") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await coordinator.stop()

        do {
            try await coordinator.stop()
            XCTFail("Expected a second stop to be rejected")
        } catch let error as CaptureCoordinatorError {
            guard case .invalidTransition(action: "stop", state: "stopped") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFlowEventBusMulticastsImmutableSnapshots() async throws {
        let bus = FlowEventBus()
        let firstStream = await bus.events(bufferingPolicy: .unbounded)
        let secondStream = await bus.events(bufferingPolicy: .unbounded)
        let flow = Flow(
            sessionID: SessionID(),
            request: HTTPRequest(
                method: .get,
                url: URL(string: "http://example.test/")!
            )
        )
        let event = FlowEvent.started(flow)

        await bus.publish(event)

        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()
        let firstEvent = await firstIterator.next()
        let secondEvent = await secondIterator.next()
        XCTAssertEqual(firstEvent, event)
        XCTAssertEqual(secondEvent, event)
        let subscriptionCount = await bus.subscriptionCount()
        XCTAssertEqual(subscriptionCount, 2)

        await bus.finish()
        let finishedSubscriptionCount = await bus.subscriptionCount()
        XCTAssertEqual(finishedSubscriptionCount, 0)
    }

    func testStartupFailureRollsBackProxyEngineAndSession() async throws {
        let recorder = CallRecorder()
        let sessionID = SessionID()
        let sessionStore = RecordingSessionStore(sessionID: sessionID, recorder: recorder)
        let proxyEngine = RecordingProxyEngine(
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_082),
            recorder: recorder
        )
        let systemProxy = RecordingSystemProxyController(
            recorder: recorder,
            failsApply: true
        )
        let coordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: sessionStore,
            systemProxyController: systemProxy
        )

        do {
            _ = try await coordinator.start(configuration: Self.captureConfiguration())
            XCTFail("Expected system proxy activation to fail")
        } catch let error as CaptureCoordinatorError {
            guard
                case .startupFailed(
                    stage: .systemProxyActivation,
                    message: _,
                    rollbackFailures: []
                ) = error
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let calls = await recorder.snapshot()
        XCTAssertEqual(
            calls,
            [
                "proxy.recover",
                "session.recover",
                "proxy.prepare",
                "session.create",
                "engine.start",
                "proxy.apply",
                "proxy.restore",
                "engine.stop",
                "session.stop"
            ]
        )
        let engineIsRunning = await proxyEngine.isRunning()
        XCTAssertFalse(engineIsRunning)
        let proxyIsActive = await systemProxy.isActive()
        XCTAssertFalse(proxyIsActive)
        let session = await sessionStore.loadSession(sessionID: sessionID)
        XCTAssertEqual(session?.state, .stopped)
        let state = await coordinator.state()
        guard case .failed = state else {
            return XCTFail("Expected the coordinator to retain its startup failure")
        }
    }

    func testFailedProxyRestoreKeepsListenerAndSessionRunning() async throws {
        let recorder = CallRecorder()
        let sessionID = SessionID()
        let sessionStore = RecordingSessionStore(sessionID: sessionID, recorder: recorder)
        let proxyEngine = RecordingProxyEngine(
            endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_083),
            recorder: recorder
        )
        let systemProxy = RecordingSystemProxyController(recorder: recorder)
        let coordinator = CaptureCoordinator(
            proxyEngine: proxyEngine,
            sessionStore: sessionStore,
            systemProxyController: systemProxy
        )
        _ = try await coordinator.start(configuration: Self.captureConfiguration())
        await systemProxy.setFailsRestore(true)

        do {
            try await coordinator.stop()
            XCTFail("Expected system proxy restoration to fail")
        } catch let error as CaptureCoordinatorError {
            guard case .stopFailed(stage: .systemProxyRestoration, message: _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let engineIsRunning = await proxyEngine.isRunning()
        XCTAssertTrue(engineIsRunning)
        let session = await sessionStore.loadSession(sessionID: sessionID)
        XCTAssertEqual(session?.state, .recording)
        let state = await coordinator.state()
        guard case .running = state else {
            return XCTFail("Expected capture to remain running after restore failed")
        }

        await systemProxy.setFailsRestore(false)
        try await coordinator.stop()
        let stoppedEngine = await proxyEngine.isRunning()
        XCTAssertFalse(stoppedEngine)
    }

    func testLaunchRecoveryRestoresInterruptedProxyAndSessionBeforeCaptureStarts()
        async throws
    {
        let recorder = CallRecorder()
        let interruptedSessionID = SessionID()
        let newSessionID = SessionID()
        let sessionStore = RecordingSessionStore(sessionID: newSessionID, recorder: recorder)
        await sessionStore.seedRecordingSession(id: interruptedSessionID)
        let systemProxy = RecordingSystemProxyController(
            recorder: recorder,
            startsActive: true
        )
        let coordinator = CaptureCoordinator(
            proxyEngine: RecordingProxyEngine(
                endpoint: NetworkEndpoint(host: "127.0.0.1", port: 58_084),
                recorder: recorder
            ),
            sessionStore: sessionStore,
            systemProxyController: systemProxy
        )

        try await coordinator.recoverInterruptedCapture()

        let recoveredSession = await sessionStore.loadSession(
            sessionID: interruptedSessionID
        )
        XCTAssertEqual(recoveredSession?.state, .interrupted)
        let launchRecoveryCalls = await recorder.snapshot()
        XCTAssertEqual(launchRecoveryCalls, ["proxy.recover", "session.recover"])
        let stateAfterRecovery = await coordinator.state()
        XCTAssertEqual(stateAfterRecovery, .stopped)
        let proxyIsActive = await systemProxy.isActive()
        XCTAssertFalse(proxyIsActive)

        _ = try await coordinator.start(configuration: Self.captureConfiguration())

        let callsAfterStart = await recorder.snapshot()
        let createIndex = try XCTUnwrap(callsAfterStart.firstIndex(of: "session.create"))
        let finalRecoveryIndex = try XCTUnwrap(
            callsAfterStart.lastIndex(of: "session.recover")
        )
        XCTAssertLessThan(finalRecoveryIndex, createIndex)

        try await coordinator.stop()
    }

    private static func captureConfiguration() -> CaptureConfiguration {
        CaptureConfiguration(
            proxy: ProxyConfiguration(
                listenEndpoint: NetworkEndpoint(host: "127.0.0.1", port: 0),
                interceptHTTPS: false
            )
        )
    }
}

private enum TestFailure: LocalizedError {
    case expected

    var errorDescription: String? {
        "Expected test failure"
    }
}

private actor CallRecorder {
    private var calls: [String] = []

    func append(_ call: String) {
        calls.append(call)
    }

    func snapshot() -> [String] {
        calls
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private struct FixedTimeSource: TimeSource {
    let date: Date

    func now() -> Date {
        date
    }
}

private actor RecordingProxyEngine: ProxyEngine {
    private let endpoint: NetworkEndpoint
    private let recorder: CallRecorder
    private let enteredStart: AsyncGate?
    private let resumeStart: AsyncGate?
    private var currentState = ProxyEngineState.stopped
    private var sessionIDs: [SessionID] = []

    init(
        endpoint: NetworkEndpoint,
        recorder: CallRecorder,
        enteredStart: AsyncGate? = nil,
        resumeStart: AsyncGate? = nil
    ) {
        self.endpoint = endpoint
        self.recorder = recorder
        self.enteredStart = enteredStart
        self.resumeStart = resumeStart
    }

    func start(configuration _: ProxyConfiguration, sessionID: SessionID) async throws {
        await recorder.append("engine.start")
        currentState = .starting
        sessionIDs.append(sessionID)
        await enteredStart?.open()
        await resumeStart?.wait()
        currentState = .running(endpoint)
    }

    func stop() async {
        await recorder.append("engine.stop")
        currentState = .stopped
    }

    func state() -> ProxyEngineState {
        currentState
    }

    func receivedSessionIDs() -> [SessionID] {
        sessionIDs
    }

    func isRunning() -> Bool {
        if case .running = currentState {
            return true
        }
        return false
    }
}

private actor RecordingSystemProxyController: SystemProxyController {
    private let recorder: CallRecorder
    private let failsApply: Bool
    private var failsRestore: Bool
    private var active: Bool
    private var prepared = false
    private var configurations: [SystemProxyConfiguration] = []

    init(
        recorder: CallRecorder,
        failsApply: Bool = false,
        failsRestore: Bool = false,
        startsActive: Bool = false
    ) {
        self.recorder = recorder
        self.failsApply = failsApply
        self.failsRestore = failsRestore
        self.active = startsActive
        self.prepared = startsActive
    }

    func recoverInterruptedConfiguration() async throws {
        await recorder.append("proxy.recover")
        active = false
        prepared = false
    }

    func prepareForProxyActivation() async throws {
        await recorder.append("proxy.prepare")
        prepared = true
    }

    func apply(_ configuration: SystemProxyConfiguration) async throws {
        await recorder.append("proxy.apply")
        configurations.append(configuration)
        active = true
        if failsApply {
            throw TestFailure.expected
        }
    }

    func restorePreviousConfiguration() async throws {
        await recorder.append("proxy.restore")
        if failsRestore {
            throw TestFailure.expected
        }
        active = false
        prepared = false
    }

    func setFailsRestore(_ value: Bool) {
        failsRestore = value
    }

    func appliedConfigurations() -> [SystemProxyConfiguration] {
        configurations
    }

    func isActive() -> Bool {
        active
    }
}

private actor RecordingSessionStore: SessionStore {
    private let sessionID: SessionID
    private let recorder: CallRecorder
    private var sessions: [SessionID: Session] = [:]
    private var flows: [FlowID: Flow] = [:]

    init(sessionID: SessionID, recorder: CallRecorder) {
        self.sessionID = sessionID
        self.recorder = recorder
    }

    func prepareForCaptureStart() async throws {
        await recorder.append("session.recover")
        for (id, var session) in sessions where session.state == .recording {
            session.interrupt(at: Date(timeIntervalSince1970: 900))
            sessions[id] = session
        }
    }

    func createSession(startedAt: Date) async throws -> Session {
        await recorder.append("session.create")
        let session = Session(id: sessionID, startedAt: startedAt)
        sessions[session.id] = session
        return session
    }

    func saveSession(_ session: Session) {
        sessions[session.id] = session
    }

    func loadSession(sessionID: SessionID) -> Session? {
        sessions[sessionID]
    }

    func listSessions() -> [Session] {
        Array(sessions.values)
    }

    func stopSession(sessionID: SessionID, at date: Date) async throws {
        await recorder.append("session.stop")
        guard var session = sessions[sessionID] else {
            return
        }
        session.stop(at: date)
        sessions[sessionID] = session
    }

    func removeSession(sessionID: SessionID) {
        sessions.removeValue(forKey: sessionID)
    }

    func save(_ flow: Flow) {
        flows[flow.id] = flow
    }

    func load(flowID: FlowID) -> Flow? {
        flows[flowID]
    }

    func listSummaries(in sessionID: SessionID) -> [FlowSummary] {
        flows.values
            .filter { $0.sessionID == sessionID }
            .map(\.summary)
    }

    func remove(flowID: FlowID) {
        flows.removeValue(forKey: flowID)
    }

    func seedRecordingSession(id: SessionID) {
        sessions[id] = Session(id: id, startedAt: Date(timeIntervalSince1970: 800))
    }
}
