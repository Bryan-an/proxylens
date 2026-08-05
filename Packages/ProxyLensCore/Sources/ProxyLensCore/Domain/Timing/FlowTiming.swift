import Foundation

public struct FlowTiming: Codable, Equatable, Hashable, Sendable {
    public let startedAt: Date
    public private(set) var requestHeadersReceivedAt: Date?
    public private(set) var requestBodyCompletedAt: Date?
    public private(set) var upstreamConnectedAt: Date?
    public private(set) var tlsHandshakeCompletedAt: Date?
    public private(set) var responseHeadersReceivedAt: Date?
    public private(set) var responseBodyCompletedAt: Date?
    public private(set) var completedAt: Date?

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    public mutating func markRequestHeadersReceived(at date: Date) {
        requestHeadersReceivedAt = date
    }

    public mutating func markRequestBodyCompleted(at date: Date) {
        requestBodyCompletedAt = date
    }

    public mutating func markUpstreamConnected(at date: Date) {
        upstreamConnectedAt = date
    }

    public mutating func markTLSHandshakeCompleted(at date: Date) {
        tlsHandshakeCompletedAt = date
    }

    public mutating func markResponseHeadersReceived(at date: Date) {
        responseHeadersReceivedAt = date
    }

    public mutating func markResponseBodyCompleted(at date: Date) {
        responseBodyCompletedAt = date
    }

    public mutating func markCompleted(at date: Date) {
        completedAt = date
    }

    public var totalDuration: TimeInterval? {
        duration(from: startedAt, to: completedAt)
    }

    public var timeToFirstByte: TimeInterval? {
        duration(from: startedAt, to: responseHeadersReceivedAt)
    }

    public var requestDuration: TimeInterval? {
        duration(from: startedAt, to: requestBodyCompletedAt)
    }

    public var responseDuration: TimeInterval? {
        duration(from: responseHeadersReceivedAt, to: responseBodyCompletedAt)
    }

    private func duration(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end else {
            return nil
        }

        return max(0, end.timeIntervalSince(start))
    }
}
