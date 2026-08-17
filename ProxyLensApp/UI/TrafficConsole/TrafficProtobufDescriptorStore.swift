import Foundation
import ProxyLensCore

struct TrafficStoredProtobufDescriptor: Codable, Equatable, Sendable {
    let data: Data
    let sourceName: String
    let requestMessageType: String?
    let responseMessageType: String?
}

protocol TrafficProtobufDescriptorStoring: Sendable {
    func load() async throws -> TrafficStoredProtobufDescriptor?
    func saveDescriptor(data: Data, sourceName: String) async throws
    func saveSelections(requestMessageType: String?, responseMessageType: String?) async throws
}

actor InMemoryTrafficProtobufDescriptorStore: TrafficProtobufDescriptorStoring {
    private var stored: TrafficStoredProtobufDescriptor?

    init(stored: TrafficStoredProtobufDescriptor? = nil) {
        self.stored = stored
    }

    func load() -> TrafficStoredProtobufDescriptor? {
        stored
    }

    func saveDescriptor(data: Data, sourceName: String) {
        stored = TrafficStoredProtobufDescriptor(
            data: data,
            sourceName: sourceName,
            requestMessageType: nil,
            responseMessageType: nil
        )
    }

    func saveSelections(requestMessageType: String?, responseMessageType: String?) {
        guard let stored else {
            return
        }
        self.stored = TrafficStoredProtobufDescriptor(
            data: stored.data,
            sourceName: stored.sourceName,
            requestMessageType: requestMessageType,
            responseMessageType: responseMessageType
        )
    }
}

actor FileTrafficProtobufDescriptorStore: TrafficProtobufDescriptorStoring {
    private let directoryURL: URL
    private let archiveURL: URL
    private let maximumArchiveByteCount = ProtobufDescriptorSetParser.maximumByteCount + 65_536

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        archiveURL = directoryURL.appendingPathComponent(
            "CurrentDescriptor.plist", isDirectory: false)
    }

    func load() throws -> TrafficStoredProtobufDescriptor? {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            return nil
        }
        let data = try Self.readBounded(
            from: archiveURL,
            maximumByteCount: maximumArchiveByteCount
        )
        return try PropertyListDecoder().decode(TrafficStoredProtobufDescriptor.self, from: data)
    }

    func saveDescriptor(data: Data, sourceName: String) throws {
        guard data.count <= ProtobufDescriptorSetParser.maximumByteCount else {
            throw ProtobufDescriptorSetError.exceedsByteLimit(
                maximum: ProtobufDescriptorSetParser.maximumByteCount
            )
        }
        try save(
            TrafficStoredProtobufDescriptor(
                data: data,
                sourceName: sourceName,
                requestMessageType: nil,
                responseMessageType: nil
            )
        )
    }

    func saveSelections(
        requestMessageType: String?,
        responseMessageType: String?
    ) throws {
        guard let stored = try load() else {
            return
        }
        try save(
            TrafficStoredProtobufDescriptor(
                data: stored.data,
                sourceName: stored.sourceName,
                requestMessageType: requestMessageType,
                responseMessageType: responseMessageType
            )
        )
    }

    private func save(_ stored: TrafficStoredProtobufDescriptor) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(stored).write(to: archiveURL, options: [.atomic])
    }

    private static func readBounded(from url: URL, maximumByteCount: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumByteCount + 1) ?? Data()
        guard data.count <= maximumByteCount else {
            throw ProtobufDescriptorSetError.exceedsByteLimit(maximum: maximumByteCount)
        }
        return data
    }
}
