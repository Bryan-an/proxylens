import Foundation
import zlib

/// Compresses and inflates gzip/zlib/raw-deflate payloads for derived inspection.
enum ZlibContentEncoding {
    enum Format {
        case gzip
        case zlib
        case rawDeflate

        var windowBits: Int32 {
            switch self {
            case .gzip:
                16 + MAX_WBITS
            case .zlib:
                MAX_WBITS
            case .rawDeflate:
                -MAX_WBITS
            }
        }
    }

    enum Error: Swift.Error, Equatable {
        case initializeFailed(Int32)
        case inflateFailed(Int32)
        case deflateFailed(Int32)
        case exceedsLimit
    }

    static func compress(_ data: Data, format: Format) throws -> Data {
        try finish(data: data, format: format)
    }

    static func decompress(
        _ data: Data,
        format: Format,
        maximumOutputByteCount: Int
    ) throws -> Data {
        guard maximumOutputByteCount >= 0 else {
            throw Error.exceedsLimit
        }
        if data.isEmpty {
            return Data()
        }

        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            format.windowBits,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw Error.initializeFailed(initStatus)
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        output.reserveCapacity(min(maximumOutputByteCount, max(data.count * 2, 64)))
        let chunkSize = 16 * 1_024
        let status = data.withUnsafeBytes { src -> Int32 in
            guard let base = src.bindMemory(to: Bytef.self).baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(src.count)

            var inflateStatus: Int32 = Z_OK
            while inflateStatus == Z_OK {
                if output.count >= maximumOutputByteCount {
                    return Z_BUF_ERROR
                }
                let thisChunk = min(chunkSize, maximumOutputByteCount - output.count)
                var chunk = [Bytef](repeating: 0, count: thisChunk)
                inflateStatus = chunk.withUnsafeMutableBufferPointer { dest in
                    stream.next_out = dest.baseAddress
                    stream.avail_out = uInt(dest.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = thisChunk - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }
            }
            return inflateStatus
        }

        if status == Z_BUF_ERROR, output.count >= maximumOutputByteCount {
            throw Error.exceedsLimit
        }
        guard status == Z_STREAM_END else {
            throw Error.inflateFailed(status)
        }
        return output
    }

    private static func finish(data: Data, format: Format) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            format.windowBits,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw Error.initializeFailed(initStatus)
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 16 * 1_024
        let status = data.withUnsafeBytes { src -> Int32 in
            if let base = src.bindMemory(to: Bytef.self).baseAddress {
                stream.next_in = UnsafeMutablePointer(mutating: base)
                stream.avail_in = uInt(src.count)
            } else {
                stream.next_in = nil
                stream.avail_in = 0
            }

            var deflateStatus: Int32 = Z_OK
            while deflateStatus == Z_OK {
                var chunk = [Bytef](repeating: 0, count: chunkSize)
                deflateStatus = chunk.withUnsafeMutableBufferPointer { dest in
                    stream.next_out = dest.baseAddress
                    stream.avail_out = uInt(dest.count)
                    return deflate(&stream, Z_FINISH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }
            }
            return deflateStatus
        }

        guard status == Z_STREAM_END else {
            throw Error.deflateFailed(status)
        }
        return output
    }
}
