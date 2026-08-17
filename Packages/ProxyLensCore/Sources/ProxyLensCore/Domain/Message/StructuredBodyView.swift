import Foundation

enum DerivedBodyData {
    case decoded(Data)
    case unavailable(String)

    static func unwrap(
        _ data: Data,
        contentEncoding: String?,
        maximumOutputByteCount: Int,
        exceedsLimitReason: String,
        isTruncated: Bool,
        truncatedReason: String
    ) -> DerivedBodyData {
        do {
            return .decoded(
                try HTTPContentCoding.decode(
                    data,
                    contentEncoding: contentEncoding,
                    maximumOutputByteCount: maximumOutputByteCount
                )
            )
        } catch let error as HTTPContentCoding.CodingError {
            switch error {
            case .unsupported(let encoding):
                return .unavailable(JSONBodyView.unsupportedContentEncodingReason(encoding))
            case .decodingFailed(let encoding), .encodingFailed(let encoding):
                if isTruncated {
                    return .unavailable(truncatedReason)
                }
                return .unavailable(JSONBodyView.decompressionFailedReason(encoding))
            case .exceedsLimit:
                return .unavailable(exceedsLimitReason)
            }
        } catch {
            return .unavailable(JSONBodyView.decompressionFailedReason("unknown"))
        }
    }
}

/// Pretty-prints captured XML for inspection without replacing the raw body bytes.
public enum XMLBodyView: Sendable {
    public static let maximumDecodedByteCount = 1_048_576
    public static let notXMLReason = "This body is not XML."
    public static let truncatedReason = "Capture truncated"
    public static let exceedsDisplayLimitReason = "XML exceeds the 1 MB display limit."
    public static let documentTypeReason = "XML document type declarations are not supported."

    public enum Result: Equatable, Sendable {
        case prettyPrinted(String)
        case unavailable(reason: String)
    }

    public static func invalidXMLReason(_ message: String) -> String {
        "Invalid XML: \(message)"
    }

    public static func render(
        data: Data,
        contentType: String?,
        contentEncoding: String?,
        isTruncated: Bool = false
    ) -> Result {
        let decoded: Data
        switch DerivedBodyData.unwrap(
            data,
            contentEncoding: contentEncoding,
            maximumOutputByteCount: maximumDecodedByteCount,
            exceedsLimitReason: exceedsDisplayLimitReason,
            isTruncated: isTruncated,
            truncatedReason: truncatedReason
        ) {
        case .decoded(let value):
            decoded = stripUTF8BOM(value)
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }

        let declaredXML = isXMLMediaType(contentType)
        let trimmed = String(decoding: decoded.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard declaredXML || trimmed.hasPrefix("<") else {
            return .unavailable(reason: notXMLReason)
        }
        guard !decoded.isEmpty else {
            return unavailableAfterParseFailure(
                isTruncated: isTruncated,
                declaredXML: declaredXML,
                message: "The body is empty."
            )
        }
        guard
            String(decoding: decoded, as: UTF8.self)
                .range(of: "<!DOCTYPE", options: .caseInsensitive) == nil
        else {
            return .unavailable(reason: documentTypeReason)
        }

        do {
            let document = try XMLDocument(
                data: decoded,
                options: [.nodeLoadExternalEntitiesNever]
            )
            let prettyData = document.xmlData(options: [.nodePrettyPrint])
            guard prettyData.count <= maximumDecodedByteCount else {
                return .unavailable(reason: exceedsDisplayLimitReason)
            }
            guard let pretty = String(data: prettyData, encoding: .utf8) else {
                return unavailableAfterParseFailure(
                    isTruncated: isTruncated,
                    declaredXML: declaredXML,
                    message: "The document is not UTF-8 text."
                )
            }
            return .prettyPrinted(pretty)
        } catch {
            return unavailableAfterParseFailure(
                isTruncated: isTruncated,
                declaredXML: declaredXML,
                message: error.localizedDescription
            )
        }
    }

    private static func unavailableAfterParseFailure(
        isTruncated: Bool,
        declaredXML: Bool,
        message: String
    ) -> Result {
        if isTruncated {
            return .unavailable(reason: truncatedReason)
        }
        if declaredXML {
            return .unavailable(reason: invalidXMLReason(message))
        }
        return .unavailable(reason: notXMLReason)
    }

    private static func isXMLMediaType(_ contentType: String?) -> Bool {
        guard let mediaType = normalizedMediaType(contentType) else {
            return false
        }
        return mediaType == "application/xml" || mediaType == "text/xml"
            || mediaType.hasSuffix("+xml")
    }
}

/// Decodes a captured URL-encoded form into one readable key/value pair per line.
public enum FormBodyView: Sendable {
    public static let maximumDecodedByteCount = 1_048_576
    public static let notFormReason = "This body is not form data."
    public static let truncatedReason = "Capture truncated"
    public static let exceedsDisplayLimitReason = "Form data exceeds the 1 MB display limit."
    public static let missingMultipartBoundaryReason =
        "Multipart form boundary is missing or invalid."

    public enum Result: Equatable, Sendable {
        case decoded(String)
        case unavailable(reason: String)
    }

    public static func invalidFormReason(_ message: String) -> String {
        "Invalid URL-encoded form: \(message)"
    }

    public static func invalidMultipartReason(_ message: String) -> String {
        "Invalid multipart form: \(message)"
    }

    public static func render(
        data: Data,
        contentType: String?,
        contentEncoding: String?,
        isTruncated: Bool = false
    ) -> Result {
        let mediaType = normalizedMediaType(contentType)
        guard
            mediaType == "application/x-www-form-urlencoded"
                || mediaType == "multipart/form-data"
        else {
            return .unavailable(reason: notFormReason)
        }

        let decoded: Data
        switch DerivedBodyData.unwrap(
            data,
            contentEncoding: contentEncoding,
            maximumOutputByteCount: maximumDecodedByteCount,
            exceedsLimitReason: exceedsDisplayLimitReason,
            isTruncated: isTruncated,
            truncatedReason: truncatedReason
        ) {
        case .decoded(let value):
            decoded = stripUTF8BOM(value)
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        }

        if mediaType == "multipart/form-data" {
            guard let boundary = multipartBoundary(from: contentType) else {
                return .unavailable(reason: missingMultipartBoundaryReason)
            }
            return renderMultipart(decoded, boundary: boundary, isTruncated: isTruncated)
        }

        guard let text = String(data: decoded, encoding: .utf8) else {
            return unavailableAfterParseFailure(
                isTruncated: isTruncated,
                message: "The body is not UTF-8 text."
            )
        }
        guard !text.isEmpty else {
            return unavailableAfterParseFailure(
                isTruncated: isTruncated,
                message: "The body is empty."
            )
        }

        var lines: [String] = []
        lines.reserveCapacity(text.split(separator: "&", omittingEmptySubsequences: false).count)
        for field in text.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decodeComponent(String(parts[0])) else {
                return unavailableAfterParseFailure(
                    isTruncated: isTruncated,
                    message: "A field name contains invalid percent encoding."
                )
            }
            let rawValue = parts.count == 2 ? String(parts[1]) : ""
            guard let value = decodeComponent(rawValue) else {
                return unavailableAfterParseFailure(
                    isTruncated: isTruncated,
                    message: "A field value contains invalid percent encoding."
                )
            }
            lines.append("\(escapeForDisplay(name))=\(escapeForDisplay(value))")
        }
        return .decoded(lines.joined(separator: "\n"))
    }

    private static func renderMultipart(
        _ data: Data,
        boundary: String,
        isTruncated: Bool
    ) -> Result {
        let boundaryBytes = Data("--\(boundary)".utf8)
        guard
            var delimiter = findMultipartDelimiter(
                in: data,
                boundary: boundaryBytes,
                from: data.startIndex
            )
        else {
            return multipartFailure("The opening boundary is missing.", isTruncated: isTruncated)
        }

        var lines: [String] = []
        var renderedByteCount = 0
        while true {
            let suffixStart = delimiter.upperBound
            if hasBytes([0x2D, 0x2D], in: data, at: suffixStart) {
                guard !lines.isEmpty else {
                    return multipartFailure(
                        "The body contains no form fields.",
                        isTruncated: isTruncated
                    )
                }
                return .decoded(lines.joined(separator: "\n"))
            }
            guard hasBytes([0x0D, 0x0A], in: data, at: suffixStart) else {
                return multipartFailure(
                    "A boundary is not followed by a new line.",
                    isTruncated: isTruncated
                )
            }

            let partStart = suffixStart + 2
            guard
                let nextDelimiter = findMultipartDelimiter(
                    in: data,
                    boundary: boundaryBytes,
                    from: partStart
                ),
                nextDelimiter.lowerBound >= partStart + 2,
                hasBytes([0x0D, 0x0A], in: data, at: nextDelimiter.lowerBound - 2)
            else {
                return multipartFailure(
                    "The closing boundary is missing.",
                    isTruncated: isTruncated
                )
            }

            do {
                let line = try multipartLine(
                    for: data[partStart..<(nextDelimiter.lowerBound - 2)]
                )
                renderedByteCount += line.utf8.count + (lines.isEmpty ? 0 : 1)
                guard renderedByteCount <= maximumDecodedByteCount else {
                    return .unavailable(reason: exceedsDisplayLimitReason)
                }
                lines.append(line)
            } catch MultipartFormError.exceedsLimit {
                return .unavailable(reason: exceedsDisplayLimitReason)
            } catch MultipartFormError.invalid(let message) {
                return multipartFailure(message, isTruncated: isTruncated)
            } catch {
                return multipartFailure(
                    "A form field could not be decoded.",
                    isTruncated: isTruncated
                )
            }
            delimiter = nextDelimiter
        }
    }

    private static func multipartLine(for part: Data.SubSequence) throws -> String {
        let partData = Data(part)
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let separatorRange = partData.range(of: separator) else {
            throw MultipartFormError.invalid("A form field has no header separator.")
        }
        guard
            let headerText = String(
                data: partData[..<separatorRange.lowerBound],
                encoding: .utf8
            )
        else {
            throw MultipartFormError.invalid("A form field has invalid headers.")
        }

        var disposition: String?
        var partContentType: String?
        for line in headerText.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else {
                throw MultipartFormError.invalid("A form field header is malformed.")
            }
            let name = line[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "content-disposition": disposition = value
            case "content-type": partContentType = value
            default: break
            }
        }

        guard let disposition,
            let (dispositionType, parameters) = parameterizedHeader(disposition),
            dispositionType.caseInsensitiveCompare("form-data") == .orderedSame,
            let fieldName = parameters["name"]
        else {
            throw MultipartFormError.invalid(
                "A form field has no valid Content-Disposition name."
            )
        }

        let valueData = Data(partData[separatorRange.upperBound...])
        let value: String
        if let filename = parameters["filename"] {
            let mediaType =
                partContentType?.isEmpty == false
                ? partContentType!
                : "application/octet-stream"
            value =
                "[File \"\(escapeQuotedDisplay(filename))\", "
                + "\(escapeForDisplay(mediaType)), \(valueData.count) B]"
        } else if let text = String(data: valueData, encoding: .utf8) {
            value = escapeForDisplay(text)
        } else {
            value = "[Binary value, \(valueData.count) B]"
        }
        let line = "\(escapeForDisplay(fieldName))=\(value)"
        guard line.utf8.count <= maximumDecodedByteCount else {
            throw MultipartFormError.exceedsLimit
        }
        return line
    }

    private static func findMultipartDelimiter(
        in data: Data,
        boundary: Data,
        from start: Data.Index
    ) -> Range<Data.Index>? {
        var searchStart = start
        while searchStart < data.endIndex,
            let range = data.range(of: boundary, in: searchStart..<data.endIndex)
        {
            let startsLine =
                range.lowerBound == data.startIndex
                || (range.lowerBound >= data.startIndex + 2
                    && hasBytes([0x0D, 0x0A], in: data, at: range.lowerBound - 2))
            let hasValidSuffix =
                hasBytes([0x0D, 0x0A], in: data, at: range.upperBound)
                || hasBytes([0x2D, 0x2D], in: data, at: range.upperBound)
            if startsLine && hasValidSuffix {
                return range
            }
            searchStart = range.lowerBound + 1
        }
        return nil
    }

    private static func hasBytes(
        _ bytes: [UInt8],
        in data: Data,
        at start: Data.Index
    ) -> Bool {
        guard start >= data.startIndex, start + bytes.count <= data.endIndex else {
            return false
        }
        return data[start..<(start + bytes.count)].elementsEqual(bytes)
    }

    private static func multipartBoundary(from contentType: String?) -> String? {
        guard let contentType,
            let (_, parameters) = parameterizedHeader(contentType),
            let boundary = parameters["boundary"],
            (1...70).contains(boundary.utf8.count),
            boundary.last != " ",
            boundary.utf8.allSatisfy({ (0x20...0x7E).contains($0) })
        else {
            return nil
        }
        return boundary
    }

    private static func parameterizedHeader(
        _ value: String
    ) -> (value: String, parameters: [String: String])? {
        guard let components = splitHeaderParameters(value),
            let first = components.first
        else {
            return nil
        }
        var parameters: [String: String] = [:]
        for component in components.dropFirst() {
            guard let equals = component.firstIndex(of: "=") else {
                return nil
            }
            let name = component[..<equals]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = component[component.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, parameters[name] == nil,
                let decodedValue = decodeHeaderParameter(rawValue)
            else {
                return nil
            }
            parameters[name] = decodedValue
        }
        return (
            first.trimmingCharacters(in: .whitespacesAndNewlines),
            parameters
        )
    }

    private static func splitHeaderParameters(_ value: String) -> [String]? {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var isEscaped = false
        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" && inQuotes {
                current.append(character)
                isEscaped = true
            } else if character == "\"" {
                current.append(character)
                inQuotes.toggle()
            } else if character == ";" && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        guard !inQuotes, !isEscaped else {
            return nil
        }
        result.append(current)
        return result
    }

    private static func decodeHeaderParameter(_ value: String) -> String? {
        guard value.first == "\"" else {
            return value.isEmpty ? nil : value
        }
        guard value.count >= 2, value.last == "\"" else {
            return nil
        }
        var decoded = ""
        var isEscaped = false
        for character in value.dropFirst().dropLast() {
            if isEscaped {
                decoded.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                decoded.append(character)
            }
        }
        return isEscaped ? nil : decoded
    }

    private static func escapeQuotedDisplay(_ value: String) -> String {
        escapeForDisplay(value).replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func multipartFailure(_ message: String, isTruncated: Bool) -> Result {
        if isTruncated {
            return .unavailable(reason: truncatedReason)
        }
        return .unavailable(reason: invalidMultipartReason(message))
    }

    private static func decodeComponent(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func escapeForDisplay(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func unavailableAfterParseFailure(
        isTruncated: Bool,
        message: String
    ) -> Result {
        if isTruncated {
            return .unavailable(reason: truncatedReason)
        }
        return .unavailable(reason: invalidFormReason(message))
    }

    private enum MultipartFormError: Error {
        case invalid(String)
        case exceedsLimit
    }
}

func normalizedMediaType(_ contentType: String?) -> String? {
    guard let contentType else {
        return nil
    }
    let mediaType =
        contentType
        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
    return mediaType.isEmpty ? nil : mediaType
}

func stripUTF8BOM(_ data: Data) -> Data {
    guard data.count >= 3 else {
        return data
    }
    let hasBOM =
        data[data.startIndex] == 0xEF
        && data[data.index(after: data.startIndex)] == 0xBB
        && data[data.index(data.startIndex, offsetBy: 2)] == 0xBF
    return hasBOM ? data.dropFirst(3) : data
}
