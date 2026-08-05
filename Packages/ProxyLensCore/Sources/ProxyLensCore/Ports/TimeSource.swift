import Foundation

public protocol TimeSource: Sendable {
    func now() -> Date
}
