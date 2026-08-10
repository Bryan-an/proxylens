public protocol CaptureStartupRecovery: Sendable {
    /// Repairs persisted state before a new capture session is created.
    func prepareForCaptureStart() async throws
}
