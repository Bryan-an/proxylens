import Foundation

/// Renders a bounded hexadecimal view of authoritative captured body bytes.
public enum HexBodyView: Sendable {
    public static let maximumDisplayedByteCount = 65_536
    public static let noBodyReason = "No body was captured."

    private static let hexDigits = Array("0123456789abcdef".utf8)

    public static func render(_ data: Data) -> String {
        guard !data.isEmpty else {
            return "[Empty body]"
        }

        let shown = data.prefix(maximumDisplayedByteCount)
        var result = hexDump(shown)
        if data.count > shown.count {
            result +=
                "\n\n[Displaying the first \(formattedByteCount(shown.count)) of \(formattedByteCount(data.count)).]"
        }
        return result
    }

    private static func hexDump(_ data: Data.SubSequence) -> String {
        let bytes = Array(data)
        var output = [UInt8]()
        output.reserveCapacity(((bytes.count + 15) / 16) * 79)

        for lineStart in stride(from: 0, to: bytes.count, by: 16) {
            appendHex(UInt64(lineStart), width: 8, to: &output)
            output.append(contentsOf: [32, 32])

            let lineEnd = min(lineStart + 16, bytes.count)
            for column in 0..<16 {
                if column == 8 {
                    output.append(32)
                }
                let index = lineStart + column
                if index < lineEnd {
                    let byte = bytes[index]
                    output.append(hexDigits[Int(byte >> 4)])
                    output.append(hexDigits[Int(byte & 0x0F)])
                } else {
                    output.append(contentsOf: [32, 32])
                }
                if column < 15 {
                    output.append(32)
                }
            }

            output.append(contentsOf: [32, 32, 124])
            for index in lineStart..<lineEnd {
                let byte = bytes[index]
                output.append((32...126).contains(byte) ? byte : 46)
            }
            output.append(contentsOf: repeatElement(32, count: 16 - (lineEnd - lineStart)))
            output.append(124)
            if lineEnd < bytes.count {
                output.append(10)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func appendHex(_ value: UInt64, width: Int, to output: inout [UInt8]) {
        for offset in (0..<width).reversed() {
            let nibble = Int((value >> UInt64(offset * 4)) & 0x0F)
            output.append(hexDigits[nibble])
        }
    }

    private static func formattedByteCount(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var unitIndex = 0
        while value >= 1_000, unitIndex < units.count - 1 {
            value /= 1_000
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(count) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
