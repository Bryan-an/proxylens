import Foundation

/// A preloaded Map Local response. File bytes are loaded in the application layer
/// before this value is published to the rule snapshot for event-loop reads.
public struct MapLocalSpec: Codable, Equatable, Hashable, Sendable {
    public let resourceID: String
    public let filePath: String?
    public let statusCode: Int
    public let reasonPhrase: String?
    public let headers: HTTPHeaders
    public let body: BodyReference

    public init(
        resourceID: String,
        filePath: String? = nil,
        statusCode: Int = 200,
        reasonPhrase: String? = "OK",
        headers: HTTPHeaders = HTTPHeaders(),
        body: BodyReference
    ) {
        self.resourceID = resourceID
        self.filePath = filePath
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }
}
