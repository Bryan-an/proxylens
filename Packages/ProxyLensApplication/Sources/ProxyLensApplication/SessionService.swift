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
}
