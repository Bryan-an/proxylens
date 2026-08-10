import Foundation

public struct DatabaseConfiguration: Equatable, Hashable, Sendable {
    public let databaseURL: URL
    public let bodyDirectoryURL: URL
    public let inlineBodyThreshold: Int64
    public let maximumCapturedBodyBytes: Int64
    public let busyTimeout: TimeInterval

    public init(
        databaseURL: URL,
        bodyDirectoryURL: URL,
        inlineBodyThreshold: Int64 = 16 * 1_024,
        maximumCapturedBodyBytes: Int64 = 50 * 1_024 * 1_024,
        busyTimeout: TimeInterval = 5
    ) {
        self.databaseURL = databaseURL
        self.bodyDirectoryURL = bodyDirectoryURL
        self.inlineBodyThreshold = max(0, inlineBodyThreshold)
        self.maximumCapturedBodyBytes = max(0, maximumCapturedBodyBytes)
        self.busyTimeout = max(0, busyTimeout)
    }
}
