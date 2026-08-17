import Foundation
import ProxyLensCore

public struct StartupRecoveryReport: Equatable, Sendable {
    public let interruptedSessionCount: Int
    public let removedOrphanedBodyCount: Int

    public init(interruptedSessionCount: Int, removedOrphanedBodyCount: Int) {
        self.interruptedSessionCount = interruptedSessionCount
        self.removedOrphanedBodyCount = removedOrphanedBodyCount
    }
}

public actor GRDBSessionStore: ServerSentEventStore, SessionStore, WebSocketFrameStore {
    private let database: DatabaseController
    private let bodyStore: (any BodyStore)?

    public init(database: DatabaseController, bodyStore: (any BodyStore)? = nil) {
        self.database = database
        self.bodyStore = bodyStore
    }

    @discardableResult
    public func createSession(startedAt: Date = Date()) async throws -> Session {
        let session = Session(startedAt: startedAt)
        try await saveSession(session)
        return session
    }

    public func saveSession(_ session: Session) async throws {
        try await database.pool.write { database in
            try SessionRepository.save(session, in: database)
        }
    }

    public func loadSession(sessionID: SessionID) async throws -> Session? {
        try await database.pool.read { database in
            try SessionRepository.fetch(sessionID, from: database)
        }
    }

    public func listSessions() async throws -> [Session] {
        try await database.pool.read { database in
            try SessionRepository.fetchAll(from: database)
        }
    }

    public func stopSession(sessionID: SessionID, at date: Date = Date()) async throws {
        try await database.pool.write { database in
            guard var session = try SessionRepository.fetch(sessionID, from: database) else {
                return
            }
            session.stop(at: date)
            try SessionRepository.save(session, in: database)
        }
    }

    public func save(_ flow: Flow) async throws {
        try await database.pool.write { database in
            let flowIsNew = try !FlowRepository.exists(flow.id, in: database)
            var session =
                try SessionRepository.fetch(flow.sessionID, from: database)
                ?? Session(id: flow.sessionID, startedAt: flow.createdAt)

            if flowIsNew {
                session.registerFlow()
                try SessionRepository.save(session, in: database)
            }

            try FlowRepository.save(flow, in: database)
        }
    }

    public func load(flowID: FlowID) async throws -> Flow? {
        try await database.pool.read { database in
            try FlowRepository.fetch(flowID, from: database)
        }
    }

    public func listFlows(in sessionID: SessionID) async throws -> [Flow] {
        try await database.pool.read { database in
            try FlowRepository.fetchAll(in: sessionID, from: database)
        }
    }

    public func listAllFlows() async throws -> [Flow] {
        try await database.pool.read { database in
            try FlowRepository.fetchAll(from: database)
        }
    }

    public func listSummaries(in sessionID: SessionID) async throws -> [FlowSummary] {
        try await listFlows(in: sessionID).map(\.summary)
    }

    public func updateAnnotation(_ annotation: FlowAnnotation?, for flowID: FlowID) async throws
        -> Flow?
    {
        try await database.pool.write { database in
            try FlowRepository.updateAnnotation(annotation, for: flowID, in: database)
        }
    }

    public func saveWebSocketFrame(_ frame: CapturedWebSocketFrame) async throws {
        try await database.pool.write { database in
            try WebSocketFrameRepository.save(frame, in: database)
        }
    }

    public func listWebSocketFrames(for flowID: FlowID) async throws
        -> [CapturedWebSocketFrame]
    {
        try await database.pool.read { database in
            try WebSocketFrameRepository.fetchAll(for: flowID, from: database)
        }
    }

    public func removeWebSocketFrames(for flowID: FlowID) async throws {
        let references = try await database.pool.write { database in
            let frames = try WebSocketFrameRepository.fetchAll(for: flowID, from: database)
            try WebSocketFrameRepository.deleteAll(for: flowID, from: database)
            return frames.map(\.payload)
        }
        try await removeBodies(references)
    }

    public func saveServerSentEvent(_ event: CapturedServerSentEvent) async throws {
        try await database.pool.write { database in
            try ServerSentEventRepository.save(event, in: database)
        }
    }

    public func listServerSentEvents(for flowID: FlowID) async throws
        -> [CapturedServerSentEvent]
    {
        try await database.pool.read { database in
            try ServerSentEventRepository.fetchAll(for: flowID, from: database)
        }
    }

    public func removeServerSentEvents(for flowID: FlowID) async throws {
        let references = try await database.pool.write { database in
            let events = try ServerSentEventRepository.fetchAll(for: flowID, from: database)
            try ServerSentEventRepository.deleteAll(for: flowID, from: database)
            return events.map(\.data)
        }
        try await removeBodies(references)
    }

    public func remove(flowID: FlowID) async throws {
        let bodyReferences = try await database.pool.write { database in
            guard let flow = try FlowRepository.fetch(flowID, from: database) else {
                return [BodyReference]()
            }

            let frameBodies = try WebSocketFrameRepository.fetchAll(
                for: flowID,
                from: database
            ).map(\.payload)
            let eventBodies = try ServerSentEventRepository.fetchAll(
                for: flowID,
                from: database
            ).map(\.data)

            try FlowRepository.delete(flowID, from: database)
            if var session = try SessionRepository.fetch(flow.sessionID, from: database) {
                session.unregisterFlow()
                try SessionRepository.save(session, in: database)
            }
            return Self.bodyReferences(in: flow) + frameBodies + eventBodies
        }

        try await removeBodies(bodyReferences)
    }

    public func removeSession(sessionID: SessionID) async throws {
        let bodyReferences = try await database.pool.write { database in
            let flows = try FlowRepository.fetchAll(in: sessionID, from: database)
            let frameBodies = try flows.flatMap { flow in
                try WebSocketFrameRepository.fetchAll(for: flow.id, from: database).map(\.payload)
            }
            let eventBodies = try flows.flatMap { flow in
                try ServerSentEventRepository.fetchAll(for: flow.id, from: database).map(\.data)
            }
            try SessionRepository.delete(sessionID, from: database)
            return flows.flatMap(Self.bodyReferences(in:)) + frameBodies + eventBodies
        }

        try await removeBodies(bodyReferences)
    }

    /// Performs every persistence repair required before a new capture session starts.
    public func performStartupRecovery(at date: Date = Date()) async throws
        -> StartupRecoveryReport
    {
        let interruptedSessionCount = try await recoverInterruptedSessions(at: date)
        let removedOrphanedBodyCount =
            if let fileBodyStore = bodyStore as? FileBodyStore {
                try await fileBodyStore.cleanupOrphanedBodies()
            } else {
                0
            }
        return StartupRecoveryReport(
            interruptedSessionCount: interruptedSessionCount,
            removedOrphanedBodyCount: removedOrphanedBodyCount
        )
    }

    /// Marks sessions and flows left active by a prior process as interrupted.
    @discardableResult
    public func recoverInterruptedSessions(at date: Date = Date()) async throws -> Int {
        try await database.pool.write { database in
            let sessions = try SessionRepository.fetchAll(from: database, state: .recording)
            for var session in sessions {
                let flows = try FlowRepository.fetchNonTerminal(in: session.id, from: database)
                for var flow in flows {
                    try flow.transition(
                        to: .failed(.persistenceError("Capture ended before the flow completed."))
                    )
                    flow.markCompleted(at: date)
                    try FlowRepository.save(flow, in: database)
                }

                session.interrupt(at: date)
                try SessionRepository.save(session, in: database)
            }
            return sessions.count
        }
    }

    private func removeBodies(_ references: [BodyReference]) async throws {
        guard let bodyStore else {
            return
        }

        var removed = Set<BodyID>()
        for reference in references where removed.insert(reference.id).inserted {
            try await bodyStore.remove(reference)
        }
    }

    private static func bodyReferences(in flow: Flow) -> [BodyReference] {
        [flow.request.body, flow.response?.body].compactMap { $0 }
    }
}

extension GRDBSessionStore {
    public func prepareForCaptureStart() async throws {
        _ = try await performStartupRecovery()
    }
}
