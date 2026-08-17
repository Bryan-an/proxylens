import Foundation

public enum FlowHighlightColor: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case red
    case yellow
    case green
    case blue
    case purple
    case gray
}

public struct FlowAnnotation: Codable, Equatable, Hashable, Sendable {
    public static let maximumCommentLength = 10_000

    public let comment: String?
    public let highlight: FlowHighlightColor?
    public let isStruckThrough: Bool

    public init(
        comment: String? = nil,
        highlight: FlowHighlightColor? = nil,
        isStruckThrough: Bool = false
    ) throws {
        let normalizedComment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedComment, normalizedComment.count > Self.maximumCommentLength {
            throw ProxyLensError.annotationCommentTooLong(maximum: Self.maximumCommentLength)
        }

        self.comment = normalizedComment.flatMap { $0.isEmpty ? nil : $0 }
        self.highlight = highlight
        self.isStruckThrough = isStruckThrough
    }

    public var isEmpty: Bool {
        comment == nil && highlight == nil && !isStruckThrough
    }

    private enum CodingKeys: String, CodingKey {
        case comment
        case highlight
        case isStruckThrough
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            comment: container.decodeIfPresent(String.self, forKey: .comment),
            highlight: container.decodeIfPresent(FlowHighlightColor.self, forKey: .highlight),
            isStruckThrough: container.decodeIfPresent(Bool.self, forKey: .isStruckThrough)
                ?? false
        )
    }
}
