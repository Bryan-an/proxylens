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
        case .failed(let reason):
            if isTruncated {
                return .unavailable(reason: truncatedReason)
            }
            return .unavailable(reason: reason)
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
        case failed(String)
    }

    private static func unwrapForInspection(
        _ data: Data,
        contentEncoding: String?
    ) -> UnwrappedBody {
        guard let encoding = encodingToken(contentEncoding) else {
            return .decoded(data)
        }

        let format: ZlibContentEncoding.Format
        switch encoding {
        case "gzip", "x-gzip":
            format = .gzip
        case "deflate":
            return inflateDeflate(data)
        default:
            return .failed(unsupportedContentEncodingReason(encoding))
        }

        do {
            let decoded = try ZlibContentEncoding.decompress(
                data,
                format: format,
                maximumOutputByteCount: maximumDecodedByteCount
            )
            return .decoded(decoded)
        } catch ZlibContentEncoding.Error.exceedsLimit {
            return .failed(exceedsDisplayLimitReason)
        } catch {
            return .failed(decompressionFailedReason(encoding))
        }
    }

    private static func inflateDeflate(_ data: Data) -> UnwrappedBody {
        do {
            let decoded = try ZlibContentEncoding.decompress(
                data,
                format: .zlib,
                maximumOutputByteCount: maximumDecodedByteCount
            )
            return .decoded(decoded)
        } catch ZlibContentEncoding.Error.exceedsLimit {
            return .failed(exceedsDisplayLimitReason)
        } catch {
            do {
                let decoded = try ZlibContentEncoding.decompress(
                    data,
                    format: .rawDeflate,
                    maximumOutputByteCount: maximumDecodedByteCount
                )
                return .decoded(decoded)
            } catch ZlibContentEncoding.Error.exceedsLimit {
                return .failed(exceedsDisplayLimitReason)
            } catch {
                return .failed(decompressionFailedReason("deflate"))
            }
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

    private static func encodingToken(_ contentEncoding: String?) -> String? {
        guard let contentEncoding else {
            return nil
        }
        let tokens = contentEncoding.split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { raw -> String? in
                let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if token.isEmpty || token == "identity" {
                    return nil
                }
                return token
            }
        guard !tokens.isEmpty else {
            return nil
        }
        if tokens.count > 1 {
            return tokens.joined(separator: ", ")
        }
        return tokens[0]
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
