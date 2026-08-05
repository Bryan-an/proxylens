import Foundation

public struct ThrottleProfile: Codable, Equatable, Hashable, Sendable {
    public let latency: TimeInterval
    public let downloadBytesPerSecond: Int64?
    public let uploadBytesPerSecond: Int64?

    public init(
        latency: TimeInterval = 0,
        downloadBytesPerSecond: Int64? = nil,
        uploadBytesPerSecond: Int64? = nil
    ) {
        self.latency = max(0, latency)
        self.downloadBytesPerSecond = downloadBytesPerSecond.map { max(0, $0) }
        self.uploadBytesPerSecond = uploadBytesPerSecond.map { max(0, $0) }
    }
}

public enum RuleAction: Codable, Equatable, Hashable, Sendable {
    case mapLocal(resourceID: String)
    case mapRemote(url: URL)
    case breakpoint
    case block(reason: String?)
    case allow
    case replaceBody(body: BodyReference)
    case throttle(ThrottleProfile)
    case redirect(url: URL)
    case annotate(message: String)
    case noCache
}
