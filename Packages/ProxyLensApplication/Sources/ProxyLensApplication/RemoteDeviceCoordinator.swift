import Foundation
import ProxyLensCore

/// A device waiting for the user to admit it.
public struct RemoteAccessRequest: Equatable, Hashable, Sendable {
    public let address: String
    public let requestedAt: Date

    public init(address: String, requestedAt: Date) {
        self.address = address
        self.requestedAt = requestedAt
    }
}

/// What the user chose for a device asking to be admitted.
public enum RemoteDeviceApproval: Equatable, Hashable, Sendable {
    /// Admit it until capture stops.
    case allowOnce
    /// Admit it now and after a relaunch, until it is revoked.
    case allowAlways
    /// Refuse it for the rest of this session.
    case deny
}

/// Decides which devices on the local network may be proxied.
///
/// This is where remote-access policy lives; the listener only applies the answer. Loopback
/// is admitted here rather than in the listener so the refusal path stays exercisable in
/// tests, and so every admission decision is stated in one place.
public actor RemoteDeviceCoordinator: RemoteAccessGate {
    public typealias BufferingPolicy = AsyncStream<RemoteAccessRequest>.Continuation
        .BufferingPolicy

    private let store: any RemoteDeviceStore
    private let approvalTimeout: Duration
    private let now: @Sendable () -> Date

    private var devicesByAddress: [String: RemoteDevice] = [:]
    private var sessionDecisions: [String: RemoteAccessDecision] = [:]
    private var pending: [String: PendingApproval] = [:]
    private var subscriptions: [UUID: AsyncStream<RemoteAccessRequest>.Continuation] = [:]
    private var isRemoteAccessEnabled = false
    private var didLoadStoredDevices = false

    public init(
        store: any RemoteDeviceStore = InMemoryRemoteDeviceStore(),
        approvalTimeout: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.approvalTimeout = approvalTimeout
        self.now = now
    }

    // MARK: - Gate

    public func authorize(_ client: RemoteAccessClient) async -> RemoteAccessDecision {
        guard !client.isLoopback else {
            return .allow
        }

        await loadStoredDevicesIfNeeded()

        guard isRemoteAccessEnabled else {
            return .deny
        }

        let address = client.address
        recordSighting(of: address)

        if let decision = sessionDecisions[address] {
            return decision
        }
        if devicesByAddress[address]?.isTrusted == true {
            return .allow
        }

        return await withCheckedContinuation { continuation in
            enqueue(continuation, for: address)
        }
    }

    // MARK: - Lifecycle and configuration

    public func setRemoteAccessEnabled(_ isEnabled: Bool) {
        isRemoteAccessEnabled = isEnabled
        guard !isEnabled else {
            return
        }
        endSession()
    }

    /// Refuses everything still waiting and forgets decisions that were only for this
    /// session. Called when capture stops.
    public func endSession() {
        for address in pending.keys {
            resumePending(address, with: .deny)
        }
        sessionDecisions.removeAll()
    }

    // MARK: - User decisions

    public func resolve(address: String, approval: RemoteDeviceApproval) async {
        await loadStoredDevicesIfNeeded()
        let address = NetworkAddress.normalizedHost(address)
        recordSighting(of: address)

        switch approval {
        case .allowOnce:
            sessionDecisions[address] = .allow
        case .allowAlways:
            sessionDecisions[address] = .allow
            setTrusted(true, for: address)
            await persistTrustedDevices()
        case .deny:
            sessionDecisions[address] = .deny
        }

        resumePending(address, with: approval == .deny ? .deny : .allow)
    }

    public func revoke(address: String) async {
        await loadStoredDevicesIfNeeded()
        let address = NetworkAddress.normalizedHost(address)
        sessionDecisions.removeValue(forKey: address)
        setTrusted(false, for: address)
        await persistTrustedDevices()
    }

    public func rename(address: String, to name: String?) async {
        await loadStoredDevicesIfNeeded()
        let address = NetworkAddress.normalizedHost(address)
        guard var device = devicesByAddress[address] else {
            return
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        device.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        devicesByAddress[address] = device
        await persistTrustedDevices()
    }

    // MARK: - Observation

    public func devices() async -> [RemoteDevice] {
        await loadStoredDevicesIfNeeded()
        return devicesByAddress.values.sorted { $0.address < $1.address }
    }

    public func requests(
        bufferingPolicy: BufferingPolicy = .bufferingNewest(32)
    ) -> AsyncStream<RemoteAccessRequest> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: RemoteAccessRequest.self,
            bufferingPolicy: bufferingPolicy
        )
        subscriptions[subscriptionID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscription(subscriptionID)
            }
        }

        // A device that connected before the console subscribed is still waiting.
        for address in pending.keys.sorted() {
            continuation.yield(RemoteAccessRequest(address: address, requestedAt: now()))
        }

        return stream
    }

    /// The devices still waiting for a decision, for a console that has just subscribed.
    public func pendingAddresses() -> [String] {
        pending.keys.sorted()
    }

    // MARK: - Pending approvals

    private func enqueue(
        _ continuation: CheckedContinuation<RemoteAccessDecision, Never>,
        for address: String
    ) {
        if var existing = pending[address] {
            // Phones open several connections at once. They join one prompt.
            existing.continuations.append(continuation)
            pending[address] = existing
            return
        }

        let timeout = Task { [approvalTimeout, weak self] in
            do {
                try await Task.sleep(for: approvalTimeout)
            } catch {
                return
            }
            await self?.timeOut(address: address)
        }
        pending[address] = PendingApproval(continuations: [continuation], timeout: timeout)
        publish(RemoteAccessRequest(address: address, requestedAt: now()))
    }

    /// An unanswered request is refused, but the silence is not recorded as a decision: the
    /// device prompts again on its next connection.
    private func timeOut(address: String) {
        resumePending(address, with: .deny)
    }

    private func resumePending(_ address: String, with decision: RemoteAccessDecision) {
        guard let approval = pending.removeValue(forKey: address) else {
            return
        }
        approval.timeout?.cancel()
        for continuation in approval.continuations {
            continuation.resume(returning: decision)
        }
    }

    private func publish(_ request: RemoteAccessRequest) {
        for continuation in subscriptions.values {
            continuation.yield(request)
        }
    }

    private func removeSubscription(_ id: UUID) {
        subscriptions.removeValue(forKey: id)
    }

    // MARK: - Device records

    private func recordSighting(of address: String) {
        let timestamp = now()
        if var device = devicesByAddress[address] {
            device.lastSeenAt = timestamp
            devicesByAddress[address] = device
        } else {
            devicesByAddress[address] = RemoteDevice(address: address, firstSeenAt: timestamp)
        }
    }

    private func setTrusted(_ isTrusted: Bool, for address: String) {
        if var device = devicesByAddress[address] {
            device.isTrusted = isTrusted
            devicesByAddress[address] = device
        } else if isTrusted {
            devicesByAddress[address] = RemoteDevice(
                address: address,
                isTrusted: true,
                firstSeenAt: now()
            )
        }
    }

    private func loadStoredDevicesIfNeeded() async {
        guard !didLoadStoredDevices else {
            return
        }
        didLoadStoredDevices = true
        for device in await store.loadDevices() {
            devicesByAddress[device.address] = device
        }
    }

    /// Only trusted devices are durable. Anything else is session history.
    private func persistTrustedDevices() async {
        let trusted = devicesByAddress.values
            .filter(\.isTrusted)
            .sorted { $0.address < $1.address }
        await store.save(trusted)
    }

    private struct PendingApproval {
        var continuations: [CheckedContinuation<RemoteAccessDecision, Never>]
        var timeout: Task<Void, Never>?
    }
}
