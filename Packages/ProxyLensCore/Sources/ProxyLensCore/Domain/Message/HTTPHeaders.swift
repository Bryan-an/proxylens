import Foundation

public struct HTTPHeader: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) throws {
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(Self.isTokenCharacter) else {
            throw ProxyLensError.invalidHeaderName(name)
        }

        guard !value.contains("\r"), !value.contains("\n") else {
            throw ProxyLensError.invalidHeaderValue(value)
        }

        self.name = name
        self.value = value
    }

    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value

        if (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) {
            return true
        }

        switch value {
        case 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
            return true
        default:
            return false
        }
    }
}

/// An ordered, duplicate-preserving collection of HTTP header fields.
public struct HTTPHeaders: Codable, Equatable, Hashable, Sendable, RandomAccessCollection {
    public typealias Index = Int

    public private(set) var fields: [HTTPHeader]

    public init(_ fields: [HTTPHeader] = []) {
        self.fields = fields
    }

    public var allFields: [HTTPHeader] {
        fields
    }

    public var startIndex: Int {
        fields.startIndex
    }

    public var endIndex: Int {
        fields.endIndex
    }

    public subscript(position: Int) -> HTTPHeader {
        fields[position]
    }

    public func values(for name: String) -> [String] {
        fields
            .filter { Self.normalizedName($0.name) == Self.normalizedName(name) }
            .map(\.value)
    }

    public func firstValue(for name: String) -> String? {
        values(for: name).first
    }

    public func contains(name: String) -> Bool {
        firstValue(for: name) != nil
    }

    public func appending(name: String, value: String) throws -> HTTPHeaders {
        var copy = self
        try copy.append(name: name, value: value)
        return copy
    }

    public mutating func append(name: String, value: String) throws {
        fields.append(try HTTPHeader(name: name, value: value))
    }

    public func replacing(name: String, with value: String) throws -> HTTPHeaders {
        let normalizedName = Self.normalizedName(name)
        let replacement = try HTTPHeader(name: name, value: value)
        var result = fields.filter { Self.normalizedName($0.name) != normalizedName }
        result.append(replacement)
        return HTTPHeaders(result)
    }

    public func removing(name: String) -> HTTPHeaders {
        let normalizedName = Self.normalizedName(name)
        return HTTPHeaders(fields.filter { Self.normalizedName($0.name) != normalizedName })
    }

    private static func normalizedName(_ name: String) -> String {
        name.lowercased()
    }
}
