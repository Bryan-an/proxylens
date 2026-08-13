import Foundation

public enum BodyDigestAlgorithm: String, Codable, Hashable, Sendable {
    case sha256
}

public struct BodyDigest: Codable, Equatable, Hashable, Sendable {
    public let algorithm: BodyDigestAlgorithm
    public let value: String

    public init(algorithm: BodyDigestAlgorithm, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

public struct BodyMetadata: Codable, Equatable, Hashable, Sendable {
    public let contentType: String?
    public let contentEncoding: String?
    public let digest: BodyDigest?
    public let isTruncated: Bool

    public init(
        contentType: String? = nil,
        contentEncoding: String? = nil,
        digest: BodyDigest? = nil,
        isTruncated: Bool = false
    ) {
        self.contentType = contentType
        self.contentEncoding = contentEncoding
        self.digest = digest
        self.isTruncated = isTruncated
    }
}

/// Describes where raw body bytes live without making the core depend on a filesystem.
public enum BodyStorage: Codable, Equatable, Hashable, Sendable {
    case inline(Data)
    case external(BodyID)
}

public struct BodyReference: Codable, Equatable, Hashable, Sendable {
    public let id: BodyID
    public let byteCount: Int64
    public let contentType: String?
    public let contentEncoding: String?
    public let digest: BodyDigest?
    public let isTruncated: Bool
    public let storage: BodyStorage

    public init(
        id: BodyID = BodyID(),
        byteCount: Int64,
        contentType: String? = nil,
        contentEncoding: String? = nil,
        digest: BodyDigest? = nil,
        isTruncated: Bool = false,
        storage: BodyStorage
    ) throws {
        guard byteCount >= 0 else {
            throw ProxyLensError.invalidBodySize(byteCount)
        }

        if case .inline(let data) = storage, Int64(data.count) != byteCount {
            throw ProxyLensError.invalidBodySize(byteCount)
        }

        self.id = id
        self.byteCount = byteCount
        self.contentType = contentType
        self.contentEncoding = contentEncoding
        self.digest = digest
        self.isTruncated = isTruncated
        self.storage = storage
    }

    public init(inline data: Data, metadata: BodyMetadata = BodyMetadata()) {
        self.id = BodyID()
        self.byteCount = Int64(data.count)
        self.contentType = metadata.contentType
        self.contentEncoding = metadata.contentEncoding
        self.digest = metadata.digest
        self.isTruncated = metadata.isTruncated
        self.storage = .inline(data)
    }

    public init(externalID: BodyID, byteCount: Int64, metadata: BodyMetadata = BodyMetadata())
        throws
    {
        try self.init(
            id: externalID,
            byteCount: byteCount,
            contentType: metadata.contentType,
            contentEncoding: metadata.contentEncoding,
            digest: metadata.digest,
            isTruncated: metadata.isTruncated,
            storage: .external(externalID)
        )
    }

    public var isInline: Bool {
        if case .inline = storage {
            true
        } else {
            false
        }
    }

    public var inlineData: Data? {
        if case .inline(let data) = storage {
            return data
        }
        return nil
    }
}
