import Foundation

/// Pretty-prints captured JSON for inspection without replacing the raw body bytes.
public enum JSONBodyView: Sendable {
    public static let maximumDecodedByteCount = 1_048_576
    public static let notJSONReason = "This body is not JSON."
    public static let truncatedReason = "Capture truncated"
    public static let exceedsDisplayLimitReason = "JSON exceeds the 1 MB display limit."

    public enum Result: Equatable, Sendable {
        case prettyPrinted(String)
        case unavailable(reason: String)
    }

    public static func unsupportedContentEncodingReason(_ encoding: String) -> String {
        "Unsupported content-encoding: \(encoding)"
    }

    public static func decompressionFailedReason(_ encoding: String) -> String {
        "Could not decompress \(encoding) body."
    }

    public static func invalidJSONReason(_ message: String) -> String {
        "Invalid JSON: \(message)"
    }

    public static func render(
        data: Data,
        contentType: String?,
        contentEncoding: String?,
        isTruncated: Bool = false
    ) -> Result {
        switch unwrapForInspection(data, contentEncoding: contentEncoding) {
        case .failed(let failure):
            if isTruncated, failure.isCausedByIncompleteData {
                return .unavailable(reason: truncatedReason)
            }
            return .unavailable(reason: failure.reason)
        case .decoded(let decoded):
            return prettyPrint(
                decoded,
                contentType: contentType,
                isTruncated: isTruncated
            )
        }
    }

    private enum UnwrappedBody {
        case decoded(Data)
        case failed(UnwrapFailure)
    }

    private enum UnwrapFailure {
        case unsupportedEncoding(String)
        case decompressionFailed(String)
        case exceedsLimit

        var isCausedByIncompleteData: Bool {
            switch self {
            case .decompressionFailed:
                true
            case .unsupportedEncoding, .exceedsLimit:
                false
            }
        }

        var reason: String {
            switch self {
            case .unsupportedEncoding(let encoding):
                JSONBodyView.unsupportedContentEncodingReason(encoding)
            case .decompressionFailed(let encoding):
                JSONBodyView.decompressionFailedReason(encoding)
            case .exceedsLimit:
                JSONBodyView.exceedsDisplayLimitReason
            }
        }
    }

    private static func unwrapForInspection(
        _ data: Data,
        contentEncoding: String?
    ) -> UnwrappedBody {
        do {
            let decoded = try HTTPContentCoding.decode(
                data,
                contentEncoding: contentEncoding,
                maximumOutputByteCount: maximumDecodedByteCount
            )
            return .decoded(decoded)
        } catch let error as HTTPContentCoding.CodingError {
            switch error {
            case .unsupported(let encoding):
                return .failed(.unsupportedEncoding(encoding))
            case .decodingFailed(let encoding), .encodingFailed(let encoding):
                return .failed(.decompressionFailed(encoding))
            case .exceedsLimit:
                return .failed(.exceedsLimit)
            }
        } catch {
            return .failed(.decompressionFailed("unknown"))
        }
    }

    private static func prettyPrint(
        _ data: Data,
        contentType: String?,
        isTruncated: Bool
    ) -> Result {
        let payload = strippingUTF8BOM(data)
        let declaredJSON = isJSONMediaType(contentType)
        if payload.count > maximumDecodedByteCount {
            return .unavailable(reason: exceedsDisplayLimitReason)
        }
        if payload.isEmpty {
            return unavailableAfterParseFailure(
                isTruncated: isTruncated,
                declaredJSON: declaredJSON
            )
        }

        let options: JSONSerialization.ReadingOptions = declaredJSON ? [.fragmentsAllowed] : []
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: payload, options: options)
        } catch {
            if declaredJSON {
                if isTruncated {
                    return .unavailable(reason: truncatedReason)
                }
                return .unavailable(reason: invalidJSONReason(error.localizedDescription))
            }
            return unavailableAfterParseFailure(isTruncated: isTruncated, declaredJSON: false)
        }

        if !declaredJSON, !(object is NSDictionary || object is NSArray) {
            return .unavailable(reason: notJSONReason)
        }

        let writingOptions: JSONSerialization.WritingOptions = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
            .fragmentsAllowed
        ]
        do {
            let pretty = try JSONSerialization.data(withJSONObject: object, options: writingOptions)
            return .prettyPrinted(String(decoding: pretty, as: UTF8.self))
        } catch {
            if isTruncated {
                return .unavailable(reason: truncatedReason)
            }
            return .unavailable(reason: invalidJSONReason(error.localizedDescription))
        }
    }

    private static func unavailableAfterParseFailure(
        isTruncated: Bool,
        declaredJSON: Bool
    ) -> Result {
        if isTruncated {
            return .unavailable(reason: truncatedReason)
        }
        if declaredJSON {
            return .unavailable(reason: invalidJSONReason("The body is empty."))
        }
        return .unavailable(reason: notJSONReason)
    }

    private static func isJSONMediaType(_ contentType: String?) -> Bool {
        guard let contentType else {
            return false
        }
        let media =
            contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if media.isEmpty {
            return false
        }
        if media == "application/json" || media == "text/json" {
            return true
        }
        guard let slash = media.firstIndex(of: "/") else {
            return false
        }
        return media[media.index(after: slash)...].hasSuffix("+json")
    }

    private static func strippingUTF8BOM(_ data: Data) -> Data {
        guard data.count >= 3 else {
            return data
        }
        let hasBOM =
            data[data.startIndex] == 0xEF
            && data[data.index(after: data.startIndex)] == 0xBB
            && data[data.index(data.startIndex, offsetBy: 2)] == 0xBF
        return hasBOM ? data.dropFirst(3) : data
    }
}
