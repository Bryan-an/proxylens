import Foundation
import zlib

/// Incrementally decodes the content coding used by a Server-Sent Event response.
/// Raw response bytes remain outside this derived decoder and are never replaced.
final class ServerSentEventStreamDecoder {
    enum DecodingError: Error, Equatable {
        case unsupportedContentEncoding(String)
        case initializationFailed(Int32)
        case decodingFailed(Int32)
        case exceedsLimit
        case truncatedStream
    }

    private enum Coding {
        case identity
        case gzip
        case deflate
    }

    private let coding: Coding
    private let maximumDecodedByteCount: Int
    private var stream = z_stream()
    private var isInitialized = false
    private var hasReachedStreamEnd = false
    private var hasFailed = false
    private var decodedByteCount = 0
    private var pendingDeflateBytes = Data()

    init(contentEncoding: String?, maximumDecodedByteCount: Int) throws {
        let tokens =
            contentEncoding?
            .split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { raw -> String? in
                let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return token.isEmpty || token == "identity" ? nil : token
            } ?? []

        switch tokens {
        case []:
            coding = .identity
        case ["gzip"], ["x-gzip"]:
            coding = .gzip
        case ["deflate"]:
            coding = .deflate
        default:
            throw DecodingError.unsupportedContentEncoding(contentEncoding ?? "")
        }
        self.maximumDecodedByteCount = max(0, maximumDecodedByteCount)

        if coding == .gzip {
            try initialize(windowBits: 16 + MAX_WBITS)
        }
    }

    deinit {
        if isInitialized {
            inflateEnd(&stream)
        }
    }

    func append(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            return Data()
        }
        guard !hasFailed, !hasReachedStreamEnd else {
            throw DecodingError.decodingFailed(Z_DATA_ERROR)
        }

        do {
            switch coding {
            case .identity:
                return try appendIdentity(data)
            case .gzip:
                return try inflate(data, flush: Z_NO_FLUSH)
            case .deflate:
                pendingDeflateBytes.append(data)
                guard pendingDeflateBytes.count >= 2 else {
                    return Data()
                }
                if !isInitialized {
                    try initialize(
                        windowBits: Self.hasZlibHeader(pendingDeflateBytes)
                            ? MAX_WBITS
                            : -MAX_WBITS
                    )
                }
                let pending = pendingDeflateBytes
                pendingDeflateBytes.removeAll(keepingCapacity: false)
                return try inflate(pending, flush: Z_NO_FLUSH)
            }
        } catch {
            hasFailed = true
            throw error
        }
    }

    func finish() throws -> Data {
        guard !hasFailed else {
            throw DecodingError.decodingFailed(Z_DATA_ERROR)
        }

        do {
            switch coding {
            case .identity:
                return Data()
            case .gzip:
                break
            case .deflate:
                if !isInitialized {
                    try initialize(
                        windowBits: Self.hasZlibHeader(pendingDeflateBytes)
                            ? MAX_WBITS
                            : -MAX_WBITS
                    )
                }
                if !pendingDeflateBytes.isEmpty {
                    let pending = pendingDeflateBytes
                    pendingDeflateBytes.removeAll(keepingCapacity: false)
                    let output = try inflate(pending, flush: Z_NO_FLUSH)
                    if hasReachedStreamEnd {
                        return output
                    }
                    return output + (try finishInflation())
                }
            }

            return try finishInflation()
        } catch {
            hasFailed = true
            throw error
        }
    }

    private func appendIdentity(_ data: Data) throws -> Data {
        guard data.count <= maximumDecodedByteCount - decodedByteCount else {
            throw DecodingError.exceedsLimit
        }
        decodedByteCount += data.count
        return data
    }

    private func finishInflation() throws -> Data {
        guard !hasReachedStreamEnd else {
            return Data()
        }
        let output = try inflate(Data(), flush: Z_FINISH)
        guard hasReachedStreamEnd else {
            throw DecodingError.truncatedStream
        }
        return output
    }

    private func initialize(windowBits: Int32) throws {
        let status = inflateInit2_(
            &stream,
            windowBits,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw DecodingError.initializationFailed(status)
        }
        isInitialized = true
    }

    private func inflate(_ data: Data, flush: Int32) throws -> Data {
        var output = Data()
        try data.withUnsafeBytes { source in
            stream.next_in = source.bindMemory(to: Bytef.self).baseAddress.map {
                UnsafeMutablePointer(mutating: $0)
            }
            stream.avail_in = uInt(source.count)

            var shouldContinue = true
            while shouldContinue {
                let remainingBudget = maximumDecodedByteCount - decodedByteCount
                let capacity = min(Self.outputChunkSize, max(1, remainingBudget))
                var chunk = [Bytef](repeating: 0, count: capacity)
                let availableInputBefore = stream.avail_in
                let status = chunk.withUnsafeMutableBufferPointer { destination in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = uInt(destination.count)
                    return zlib.inflate(&stream, flush)
                }
                let producedByteCount = capacity - Int(stream.avail_out)

                guard producedByteCount <= remainingBudget else {
                    throw DecodingError.exceedsLimit
                }
                if producedByteCount > 0 {
                    output.append(contentsOf: chunk.prefix(producedByteCount))
                    decodedByteCount += producedByteCount
                }

                switch status {
                case Z_STREAM_END:
                    hasReachedStreamEnd = true
                    guard stream.avail_in == 0 else {
                        throw DecodingError.decodingFailed(Z_DATA_ERROR)
                    }
                    shouldContinue = false
                case Z_OK:
                    let madeProgress =
                        producedByteCount > 0 || stream.avail_in < availableInputBefore
                    guard madeProgress else {
                        throw DecodingError.decodingFailed(Z_BUF_ERROR)
                    }
                    shouldContinue = stream.avail_in > 0 || stream.avail_out == 0
                case Z_BUF_ERROR:
                    guard stream.avail_in == 0 else {
                        throw DecodingError.decodingFailed(status)
                    }
                    shouldContinue = false
                default:
                    throw DecodingError.decodingFailed(status)
                }
            }
        }
        return output
    }

    private static func hasZlibHeader(_ data: Data) -> Bool {
        guard data.count >= 2 else {
            return true
        }
        let header = Int(data[data.startIndex]) << 8 | Int(data[data.index(after: data.startIndex)])
        return header & 0x0F00 == 0x0800 && header % 31 == 0
    }

    private static let outputChunkSize = 16 * 1_024
}
