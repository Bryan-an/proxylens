import Foundation
import ProxyLensCore

/// Loads and clears the persisted capture workspace for offline inspection.
public struct SessionService: Sendable {
    private let sessionStore: any SessionStore

    public init(sessionStore: any SessionStore) {
        self.sessionStore = sessionStore
    }

    public func loadWorkspace() async throws -> [Flow] {
        try await sessionStore.listAllFlows().sorted { lhs, rhs in
            lhs.createdAt < rhs.createdAt
        }
    }

    public func clearWorkspace() async throws {
        let sessions = try await sessionStore.listSessions()
        for session in sessions {
            try await sessionStore.removeSession(sessionID: session.id)
        }
    }

    /// Returns the most recent workspace session, creating a stopped session when the
    /// workspace is empty so a standalone request has a durable local owner.
    public func sessionIDForNewFlow() async throws -> SessionID {
        let sessions = try await sessionStore.listSessions()
        if let newest = sessions.max(by: { $0.startedAt < $1.startedAt }) {
            return newest.id
        }

        let session = try await sessionStore.createSession()
        try await sessionStore.stopSession(sessionID: session.id)
        return session.id
    }
}
