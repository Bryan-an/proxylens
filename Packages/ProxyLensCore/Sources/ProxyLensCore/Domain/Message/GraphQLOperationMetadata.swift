import Foundation

/// Small, persisted discovery metadata derived from a GraphQL request body.
/// Raw request bytes remain authoritative and are never replaced by this value.
public struct GraphQLOperationMetadata: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
        case query
        case mutation
        case subscription
    }

    public let kind: Kind
    public let name: String?

    public init(kind: Kind, name: String?) {
        self.kind = kind
        self.name = name
    }

    public var displayName: String {
        name ?? "Anonymous \(kind.rawValue)"
    }
}
