import Foundation

public enum DNSSpoofSpecError: Error, Equatable, LocalizedError, Sendable {
    case emptyAddress
    case addressTooLong(maximum: Int)
    case invalidAddress(String)

    public var errorDescription: String? {
        switch self {
        case .emptyAddress:
            "Enter an IPv4 or IPv6 address."
        case .addressTooLong(let maximum):
            "The DNS spoof address must be at most \(maximum) characters."
        case .invalidAddress(let address):
            "DNS spoof destinations must be numeric IPv4 or IPv6 addresses: \(address)"
        }
    }
}

public struct DNSSpoofSpec: Codable, Equatable, Hashable, Sendable {
    public static let maximumAddressLength = 45

    public let address: String

    public init(address: String) throws {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw DNSSpoofSpecError.emptyAddress
        }
        guard normalized.count <= Self.maximumAddressLength else {
            throw DNSSpoofSpecError.addressTooLong(maximum: Self.maximumAddressLength)
        }
        guard Self.isIPv4Literal(normalized) || Self.isIPv6Literal(normalized) else {
            throw DNSSpoofSpecError.invalidAddress(normalized)
        }
        self.address = normalized.contains(":") ? normalized.lowercased() : normalized
    }

    private enum CodingKeys: String, CodingKey {
        case address
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(address: container.decode(String.self, forKey: .address))
    }

    private static func isIPv4Literal(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty,
                octet.allSatisfy(\.isASCIIWholeNumber),
                octet.count == 1 || octet.first != "0",
                let number = UInt8(octet)
            else {
                return false
            }
            return String(number) == octet
        }
    }

    private static func isIPv6Literal(_ value: String) -> Bool {
        guard value.contains(":"),
            !value.contains("%"),
            !value.contains("["),
            !value.contains("]")
        else {
            return false
        }

        let compressedParts = value.components(separatedBy: "::")
        guard compressedParts.count <= 2 else {
            return false
        }
        let isCompressed = compressedParts.count == 2
        let left = groups(in: compressedParts[0])
        let right = groups(in: isCompressed ? compressedParts[1] : "")
        guard let left, let right else {
            return false
        }
        let allGroups = left + right
        guard !allGroups.isEmpty || isCompressed else {
            return false
        }

        var unitCount = 0
        for (index, group) in allGroups.enumerated() {
            if group.contains(".") {
                guard index == allGroups.index(before: allGroups.endIndex),
                    isIPv4Literal(group)
                else {
                    return false
                }
                unitCount += 2
            } else {
                guard (1...4).contains(group.count),
                    group.allSatisfy(\.isASCIIHexDigit)
                else {
                    return false
                }
                unitCount += 1
            }
        }

        return isCompressed ? unitCount < 8 : unitCount == 8
    }

    private static func groups(in value: String) -> [String]? {
        guard !value.isEmpty else {
            return []
        }
        let groups = value.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return groups.map(String.init)
    }
}

extension Character {
    fileprivate var isASCIIWholeNumber: Bool {
        isASCII && isWholeNumber
    }

    fileprivate var isASCIIHexDigit: Bool {
        guard isASCII, let scalar = unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }
}
