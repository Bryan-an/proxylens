import Foundation

public struct ThrottleProfile: Codable, Equatable, Hashable, Sendable {
    public let latency: TimeInterval
    public let downloadBytesPerSecond: Int64?
    public let uploadBytesPerSecond: Int64?
    public let packetLossPercentage: Double

    public init(
        latency: TimeInterval = 0,
        downloadBytesPerSecond: Int64? = nil,
        uploadBytesPerSecond: Int64? = nil,
        packetLossPercentage: Double = 0
    ) {
        self.latency = max(0, latency)
        self.downloadBytesPerSecond = downloadBytesPerSecond.map { max(0, $0) }
        self.uploadBytesPerSecond = uploadBytesPerSecond.map { max(0, $0) }
        self.packetLossPercentage = packetLossPercentage
    }

    public func dropsRequest(flowID: FlowID) -> Bool {
        guard packetLossPercentage.isFinite, packetLossPercentage > 0 else {
            return false
        }
        guard packetLossPercentage < 100 else {
            return true
        }

        let bytes = withUnsafeBytes(of: flowID.rawValue.uuid) { Array($0) }
        let sample = UInt16(bytes[14]) << 8 | UInt16(bytes[15])
        let threshold = packetLossPercentage / 100 * 65_536
        return Double(sample) < threshold
    }

    private enum CodingKeys: String, CodingKey {
        case latency
        case downloadBytesPerSecond
        case uploadBytesPerSecond
        case packetLossPercentage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            latency: try container.decodeIfPresent(TimeInterval.self, forKey: .latency) ?? 0,
            downloadBytesPerSecond: try container.decodeIfPresent(
                Int64.self,
                forKey: .downloadBytesPerSecond
            ),
            uploadBytesPerSecond: try container.decodeIfPresent(
                Int64.self,
                forKey: .uploadBytesPerSecond
            ),
            packetLossPercentage: try container.decodeIfPresent(
                Double.self,
                forKey: .packetLossPercentage
            ) ?? 0
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(latency, forKey: .latency)
        try container.encodeIfPresent(downloadBytesPerSecond, forKey: .downloadBytesPerSecond)
        try container.encodeIfPresent(uploadBytesPerSecond, forKey: .uploadBytesPerSecond)
        try container.encode(packetLossPercentage, forKey: .packetLossPercentage)
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
