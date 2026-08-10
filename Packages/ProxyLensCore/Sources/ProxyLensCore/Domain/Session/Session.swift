import Foundation

public enum SessionState: String, Codable, Equatable, Hashable, Sendable {
    case recording
    case stopped
    case interrupted
}

public struct Session: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: SessionID
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var state: SessionState
    public private(set) var flowCount: Int

    public init(id: SessionID = SessionID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.state = .recording
        self.flowCount = 0
    }

    public mutating func registerFlow() {
        flowCount += 1
    }

    public mutating func unregisterFlow() {
        flowCount = max(0, flowCount - 1)
    }

    public mutating func stop(at date: Date = Date()) {
        guard state == .recording else {
            return
        }

        state = .stopped
        endedAt = date
    }

    public mutating func interrupt(at date: Date = Date()) {
        guard state == .recording else {
            return
        }

        state = .interrupted
        endedAt = date
    }
}
