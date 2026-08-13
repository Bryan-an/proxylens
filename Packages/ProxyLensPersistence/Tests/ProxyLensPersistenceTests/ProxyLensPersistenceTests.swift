import Foundation
import ProxyLensCore
import XCTest

@testable import ProxyLensPersistence

final class ProxyLensPersistenceTests: XCTestCase {
    func testFreshDatabaseEnablesWALAndForeignKeys() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }

        let journalMode = try await fixture.database.journalMode()
        let foreignKeysEnabled = try await fixture.database.foreignKeysEnabled()
        XCTAssertEqual(journalMode, "wal")
        XCTAssertTrue(foreignKeysEnabled)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.configuration.databaseURL.path))
    }

    func testBodyStoreStreamsInlineExternalAndTruncatedBodies() async throws {
        let fixture = try PersistenceFixture(inlineBodyThreshold: 8, maximumBodyBytes: 5)
        defer { fixture.remove() }

        let writer = try await fixture.bodyStore.beginWrite(
            metadata: BodyMetadata(contentType: "text/plain"),
            maximumByteCount: 5
        )
        try await writer.append(Data("abc".utf8))
        try await writer.append(Data("def".utf8))
        let truncated = try await writer.finalize()

        XCTAssertTrue(truncated.isInline)
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(truncated.byteCount, 5)
        XCTAssertEqual(truncated.contentType, "text/plain")
        let truncatedBytes = try await fixture.bodyStore.read(truncated)
        XCTAssertEqual(truncatedBytes, Data("abcde".utf8))
        XCTAssertEqual(truncated.digest?.algorithm, .sha256)
        XCTAssertEqual(truncated.digest?.value.count, 64)

        let externalBytes = Data(repeating: 0xA5, count: 32)
        let external = try await fixture.bodyStore.put(
            externalBytes,
            metadata: BodyMetadata(contentType: "application/octet-stream")
        )
        XCTAssertFalse(external.isInline)
        let restoredExternalBytes = try await fixture.bodyStore.read(external)
        XCTAssertEqual(restoredExternalBytes, externalBytes)

        try await fixture.bodyStore.remove(external)
        await assertThrowsErrorAsync(try await fixture.bodyStore.read(external)) { error in
            XCTAssertEqual(error as? PersistenceError, .bodyNotFound(external.id))
        }
    }

    func testOrphanCleanupPreservesReferencedBodies() async throws {
        let fixture = try PersistenceFixture(inlineBodyThreshold: 1)
        defer { fixture.remove() }

        let trackedBody = try await fixture.bodyStore.put(
            Data("tracked body".utf8),
            metadata: BodyMetadata()
        )
        let sessionID = SessionID()
        let trackedFlow = Flow(
            sessionID: sessionID,
            request: HTTPRequest(
                method: .post,
                url: URL(string: "https://example.test/tracked")!,
                body: trackedBody
            )
        )
        try await fixture.sessionStore.save(trackedFlow)
        let unreferencedBody = try await fixture.bodyStore.put(
            Data("unreferenced body".utf8),
            metadata: BodyMetadata()
        )
        let strayURL = fixture.configuration.bodyDirectoryURL.appendingPathComponent("stray.body")
        try Data("stray".utf8).write(to: strayURL)

        let removedCount = try await fixture.bodyStore.cleanupOrphanedBodies()
        let trackedBytes = try await fixture.bodyStore.read(trackedBody)
        XCTAssertEqual(removedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayURL.path))
        XCTAssertEqual(trackedBytes, Data("tracked body".utf8))
        await assertThrowsErrorAsync(
            try await fixture.bodyStore.read(unreferencedBody)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .bodyNotFound(unreferencedBody.id))
        }
    }

    func testFlowSessionAndBodiesRoundTripAfterRestart() async throws {
        let fixture = try PersistenceFixture(inlineBodyThreshold: 4)
        defer { fixture.remove() }

        let session = Session(startedAt: Date(timeIntervalSince1970: 1_000))
        try await fixture.sessionStore.saveSession(session)
        let requestBody = try await fixture.bodyStore.put(
            Data("request bytes".utf8),
            metadata: BodyMetadata(contentType: "application/json")
        )
        let responseBody = try await fixture.bodyStore.put(
            Data("response bytes".utf8),
            metadata: BodyMetadata(contentType: "application/json")
        )
        let flow = try Self.makeCompletedFlow(
            sessionID: session.id,
            index: 1,
            requestBody: requestBody,
            responseBody: responseBody
        )
        try await fixture.sessionStore.save(flow)

        let reopenedDatabase = try DatabaseController(configuration: fixture.configuration)
        let reopenedBodyStore = FileBodyStore(database: reopenedDatabase)
        let reopenedSessionStore = GRDBSessionStore(
            database: reopenedDatabase,
            bodyStore: reopenedBodyStore
        )

        let restoredFlow = try await reopenedSessionStore.load(flowID: flow.id)
        let restoredSummaries = try await reopenedSessionStore.listSummaries(in: session.id)
        let restoredRequestBytes = try await reopenedBodyStore.read(requestBody)
        let restoredResponseBytes = try await reopenedBodyStore.read(responseBody)
        let loadedSession = try await reopenedSessionStore.loadSession(sessionID: session.id)
        let restoredSession = try XCTUnwrap(loadedSession)
        XCTAssertEqual(restoredFlow, flow)
        XCTAssertEqual(restoredSummaries, [flow.summary])
        XCTAssertEqual(restoredRequestBytes, Data("request bytes".utf8))
        XCTAssertEqual(restoredResponseBytes, Data("response bytes".utf8))
        XCTAssertEqual(restoredSession.flowCount, 1)
        XCTAssertEqual(restoredSession.state, .recording)
    }

    func testListSessionsAndAllFlowsReturnPersistedWorkspaceInStableOrder() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }

        let olderSession = Session(startedAt: Date(timeIntervalSince1970: 1_000))
        let newerSession = Session(startedAt: Date(timeIntervalSince1970: 2_000))
        try await fixture.sessionStore.saveSession(newerSession)
        try await fixture.sessionStore.saveSession(olderSession)

        let newerFlow = try Self.makeCompletedFlow(sessionID: newerSession.id, index: 2)
        let olderFlow = try Self.makeCompletedFlow(sessionID: olderSession.id, index: 1)
        try await fixture.sessionStore.save(newerFlow)
        try await fixture.sessionStore.save(olderFlow)

        let sessions = try await fixture.sessionStore.listSessions()
        let allFlows = try await fixture.sessionStore.listAllFlows()
        let olderSessionFlows = try await fixture.sessionStore.listFlows(in: olderSession.id)
        XCTAssertEqual(sessions.map(\.id), [newerSession.id, olderSession.id])
        XCTAssertEqual(allFlows.map(\.id), [olderFlow.id, newerFlow.id])
        XCTAssertEqual(olderSessionFlows.map(\.id), [olderFlow.id])
    }

    func testRemoveSessionDeletesMetadataAndBodyFilesAcrossReopen() async throws {
        let fixture = try PersistenceFixture(inlineBodyThreshold: 4)
        defer { fixture.remove() }

        let session = Session(startedAt: Date(timeIntervalSince1970: 4_000))
        try await fixture.sessionStore.saveSession(session)
        let requestBody = try await fixture.bodyStore.put(
            Data("request bytes to delete".utf8),
            metadata: BodyMetadata(contentType: "text/plain")
        )
        let responseBody = try await fixture.bodyStore.put(
            Data("response bytes to delete".utf8),
            metadata: BodyMetadata(contentType: "text/plain")
        )
        let flow = try Self.makeCompletedFlow(
            sessionID: session.id,
            index: 1,
            requestBody: requestBody,
            responseBody: responseBody
        )
        try await fixture.sessionStore.save(flow)
        XCTAssertFalse(requestBody.isInline)
        XCTAssertFalse(responseBody.isInline)

        try await fixture.sessionStore.removeSession(sessionID: session.id)

        let removedSession = try await fixture.sessionStore.loadSession(sessionID: session.id)
        let removedFlow = try await fixture.sessionStore.load(flowID: flow.id)
        let remainingFlows = try await fixture.sessionStore.listAllFlows()
        XCTAssertNil(removedSession)
        XCTAssertNil(removedFlow)
        XCTAssertTrue(remainingFlows.isEmpty)
        await assertThrowsErrorAsync(try await fixture.bodyStore.read(requestBody)) { error in
            XCTAssertEqual(error as? PersistenceError, .bodyNotFound(requestBody.id))
        }
        await assertThrowsErrorAsync(try await fixture.bodyStore.read(responseBody)) { error in
            XCTAssertEqual(error as? PersistenceError, .bodyNotFound(responseBody.id))
        }

        let reopenedDatabase = try DatabaseController(configuration: fixture.configuration)
        let reopenedBodyStore = FileBodyStore(database: reopenedDatabase)
        let reopenedSessionStore = GRDBSessionStore(
            database: reopenedDatabase,
            bodyStore: reopenedBodyStore
        )
        let reopenedSession = try await reopenedSessionStore.loadSession(sessionID: session.id)
        let reopenedFlow = try await reopenedSessionStore.load(flowID: flow.id)
        let reopenedSessions = try await reopenedSessionStore.listSessions()
        let reopenedFlows = try await reopenedSessionStore.listAllFlows()
        XCTAssertNil(reopenedSession)
        XCTAssertNil(reopenedFlow)
        XCTAssertTrue(reopenedSessions.isEmpty)
        XCTAssertTrue(reopenedFlows.isEmpty)
        await assertThrowsErrorAsync(try await reopenedBodyStore.read(requestBody)) { error in
            XCTAssertEqual(error as? PersistenceError, .bodyNotFound(requestBody.id))
        }
    }

    func testConcurrentWritesAndInspectionReadsPreserveEveryFlow() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }

        let session = Session(startedAt: Date(timeIntervalSince1970: 2_000))
        try await fixture.sessionStore.saveSession(session)
        let readerStore = GRDBSessionStore(database: fixture.database)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let flow = try Self.makeCompletedFlow(sessionID: session.id, index: index)
                    try await fixture.sessionStore.save(flow)
                }
            }
            group.addTask {
                for _ in 0..<20 {
                    _ = try await readerStore.listSummaries(in: session.id)
                }
            }
            try await group.waitForAll()
        }

        let summaries = try await fixture.sessionStore.listSummaries(in: session.id)
        let restoredSession = try await fixture.sessionStore.loadSession(sessionID: session.id)
        XCTAssertEqual(summaries.count, 20)
        XCTAssertEqual(restoredSession?.flowCount, 20)
    }

    func testStartupRecoveryAfterReopenInterruptsFlowsAndRemovesOrphanedBodies() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }

        let session = Session(startedAt: Date(timeIntervalSince1970: 3_000))
        try await fixture.sessionStore.saveSession(session)
        var flow = Flow(
            sessionID: session.id,
            request: HTTPRequest(
                method: .post,
                url: URL(string: "https://example.test/incomplete")!
            ),
            startedAt: session.startedAt
        )
        try flow.transition(to: .receivingRequest)
        try await fixture.sessionStore.save(flow)
        let orphanedBody = try await fixture.bodyStore.put(
            Data(repeating: 0xA5, count: 32),
            metadata: BodyMetadata()
        )

        let reopenedDatabase = try DatabaseController(configuration: fixture.configuration)
        let reopenedBodyStore = FileBodyStore(database: reopenedDatabase)
        let reopenedSessionStore = GRDBSessionStore(
            database: reopenedDatabase,
            bodyStore: reopenedBodyStore
        )
        let recoveryDate = Date(timeIntervalSince1970: 3_100)
        let report = try await reopenedSessionStore.performStartupRecovery(at: recoveryDate)
        let loadedSession = try await reopenedSessionStore.loadSession(sessionID: session.id)
        let recoveredSession = try XCTUnwrap(loadedSession)
        XCTAssertEqual(
            report,
            StartupRecoveryReport(
                interruptedSessionCount: 1,
                removedOrphanedBodyCount: 1
            )
        )
        XCTAssertEqual(recoveredSession.state, .interrupted)
        XCTAssertEqual(recoveredSession.endedAt, recoveryDate)

        let loadedFlow = try await reopenedSessionStore.load(flowID: flow.id)
        let recoveredFlow = try XCTUnwrap(loadedFlow)
        guard case .failed(.persistenceError(let message)) = recoveredFlow.state else {
            return XCTFail("Expected an interrupted flow to become a persistence failure")
        }
        XCTAssertEqual(message, "Capture ended before the flow completed.")
        XCTAssertEqual(recoveredFlow.timing.completedAt, recoveryDate)
        await assertThrowsErrorAsync(
            try await reopenedBodyStore.read(orphanedBody)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .bodyNotFound(orphanedBody.id))
        }
    }

    func testPersistingEventSinkUpsertsSnapshots() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.remove() }

        var flow = Flow(
            sessionID: SessionID(),
            request: HTTPRequest(method: .get, url: URL(string: "http://example.test/")!)
        )
        try flow.transition(to: .receivingRequest)
        let sink = PersistingFlowEventSink(flowStore: fixture.sessionStore)

        await sink.publish(.started(flow))

        let persistedFlow = try await fixture.sessionStore.load(flowID: flow.id)
        let failures = await sink.failures()
        XCTAssertEqual(persistedFlow, flow)
        XCTAssertTrue(failures.isEmpty)
    }

    func testPersistingEventSinkForwardsOnlyAfterSuccessfulSave() async throws {
        let flow = Flow(
            sessionID: SessionID(),
            request: HTTPRequest(method: .get, url: URL(string: "http://example.test/")!)
        )
        let event = FlowEvent.started(flow)

        let successRecorder = SinkCallRecorder()
        let successStore = OrderedFlowStore(recorder: successRecorder)
        let successDownstream = OrderedFlowEventSink(recorder: successRecorder)
        let successSink = PersistingFlowEventSink(
            flowStore: successStore,
            downstream: successDownstream
        )
        await successSink.publish(event)

        let successCalls = await successRecorder.snapshot()
        XCTAssertEqual(successCalls, ["save", "publish"])
        let forwardedEvents = await successDownstream.events()
        XCTAssertEqual(forwardedEvents, [event])
        let successFailures = await successSink.failures()
        XCTAssertTrue(successFailures.isEmpty)

        let failureRecorder = SinkCallRecorder()
        let failureStore = OrderedFlowStore(
            recorder: failureRecorder,
            failsSave: true
        )
        let failureDownstream = OrderedFlowEventSink(recorder: failureRecorder)
        let failureSink = PersistingFlowEventSink(
            flowStore: failureStore,
            downstream: failureDownstream
        )
        await failureSink.publish(event)

        let failureCalls = await failureRecorder.snapshot()
        XCTAssertEqual(failureCalls, ["save"])
        let eventsAfterFailure = await failureDownstream.events()
        XCTAssertTrue(eventsAfterFailure.isEmpty)
        let retainedFailures = await failureSink.failures()
        XCTAssertEqual(retainedFailures.map(\.flowID), [flow.id])
    }

    private static func makeCompletedFlow(
        sessionID: SessionID,
        index: Int,
        requestBody: BodyReference? = nil,
        responseBody: BodyReference? = nil
    ) throws -> Flow {
        let startedAt = Date(timeIntervalSince1970: 10_000 + Double(index))
        var flow = Flow(
            sessionID: sessionID,
            request: HTTPRequest(
                method: .post,
                url: URL(string: "https://example.test/items/\(index)")!,
                headers: HTTPHeaders([
                    try HTTPHeader(name: "Content-Type", value: "application/json")
                ]),
                body: requestBody
            ),
            connection: ConnectionInfo(
                protocolKind: .https,
                upstreamHost: "example.test",
                upstreamPort: 443,
                tlsIntercepted: true
            ),
            startedAt: startedAt
        )
        try flow.transition(to: .receivingRequest)
        flow.markRequestHeadersReceived(at: startedAt)
        flow.markRequestBodyCompleted(at: startedAt.addingTimeInterval(0.1))
        try flow.transition(to: .connectingUpstream)
        flow.markUpstreamConnected(at: startedAt.addingTimeInterval(0.2))
        flow.attachResponse(
            try HTTPResponse(
                statusCode: 200 + index % 3,
                headers: HTTPHeaders([
                    try HTTPHeader(name: "Content-Type", value: "application/json")
                ]),
                body: responseBody
            )
        )
        try flow.transition(to: .receivingResponse)
        flow.markResponseHeadersReceived(at: startedAt.addingTimeInterval(0.3))
        flow.markResponseBodyCompleted(at: startedAt.addingTimeInterval(0.4))
        try flow.transition(to: .completed)
        flow.markCompleted(at: startedAt.addingTimeInterval(0.5))
        return flow
    }
}

private final class PersistenceFixture: @unchecked Sendable {
    let rootURL: URL
    let configuration: DatabaseConfiguration
    let database: DatabaseController
    let bodyStore: FileBodyStore
    let sessionStore: GRDBSessionStore

    init(inlineBodyThreshold: Int64 = 8, maximumBodyBytes: Int64 = 1_024) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyLensPersistenceTests-\(UUID().uuidString)")
        configuration = DatabaseConfiguration(
            databaseURL: rootURL.appendingPathComponent("capture.sqlite"),
            bodyDirectoryURL: rootURL.appendingPathComponent("Bodies"),
            inlineBodyThreshold: inlineBodyThreshold,
            maximumCapturedBodyBytes: maximumBodyBytes
        )
        database = try DatabaseController(configuration: configuration)
        bodyStore = FileBodyStore(database: database)
        sessionStore = GRDBSessionStore(database: database, bodyStore: bodyStore)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private enum SinkTestFailure: Error {
    case expected
}

private actor SinkCallRecorder {
    private var calls: [String] = []

    func append(_ call: String) {
        calls.append(call)
    }

    func snapshot() -> [String] {
        calls
    }
}

private actor OrderedFlowStore: FlowStore {
    private let recorder: SinkCallRecorder
    private let failsSave: Bool

    init(recorder: SinkCallRecorder, failsSave: Bool = false) {
        self.recorder = recorder
        self.failsSave = failsSave
    }

    func save(_: Flow) async throws {
        await recorder.append("save")
        if failsSave {
            throw SinkTestFailure.expected
        }
    }

    func load(flowID _: FlowID) -> Flow? {
        nil
    }

    func listFlows(in _: SessionID) -> [Flow] {
        []
    }

    func listSummaries(in _: SessionID) -> [FlowSummary] {
        []
    }

    func remove(flowID _: FlowID) {}
}

private actor OrderedFlowEventSink: FlowEventSink {
    private let recorder: SinkCallRecorder
    private var recordedEvents: [FlowEvent] = []

    init(recorder: SinkCallRecorder) {
        self.recorder = recorder
    }

    func publish(_ event: FlowEvent) async {
        await recorder.append("publish")
        recordedEvents.append(event)
    }

    func events() -> [FlowEvent] {
        recordedEvents
    }
}

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
