import AppKit
import ProxyLensApplication

/// Asks whether a device on the local network may use this proxy.
///
/// A row in the console's chrome rather than a modal: the decision is driven entirely by the
/// published snapshot, so it renders through the same path as everything else and never
/// takes over the app while a device waits.
@MainActor
final class RemoteDeviceApprovalBar: NSStackView {
    private let viewModel: TrafficConsoleViewModel
    private let addressLabel = NSTextField(labelWithString: "")
    private let allowOnceButton = NSButton(title: "Allow Once", target: nil, action: nil)
    private let allowAlwaysButton = NSButton(title: "Always Allow", target: nil, action: nil)
    private let denyButton = NSButton(title: "Deny", target: nil, action: nil)
    private var pendingAddress: String?

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ snapshot: TrafficConsoleSnapshot) {
        guard let approval = snapshot.remoteAccess.pendingApproval else {
            pendingAddress = nil
            isHidden = true
            return
        }
        pendingAddress = approval.address
        addressLabel.stringValue = "Allow \(approval.address) to use this proxy?"
        isHidden = false
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        isHidden = true
        setAccessibilityIdentifier("traffic.remoteApproval.bar")
        setAccessibilityLabel("Remote device approval")

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "iphone.gen3.radiowaves.left.and.right",
            accessibilityDescription: nil
        )
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        addressLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        addressLabel.lineBreakMode = .byTruncatingMiddle
        addressLabel.setAccessibilityIdentifier("traffic.remoteApproval.address")
        addressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (button, identifier) in [
            (allowOnceButton, "traffic.remoteApproval.allowOnce"),
            (allowAlwaysButton, "traffic.remoteApproval.allowAlways"),
            (denyButton, "traffic.remoteApproval.deny")
        ] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.setAccessibilityIdentifier(identifier)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        allowOnceButton.action = #selector(allowOnce)
        allowAlwaysButton.action = #selector(allowAlways)
        denyButton.action = #selector(deny)
        denyButton.keyEquivalent = "\u{1b}"

        addArrangedSubview(icon)
        addArrangedSubview(addressLabel)
        addArrangedSubview(NSView())
        addArrangedSubview(denyButton)
        addArrangedSubview(allowOnceButton)
        addArrangedSubview(allowAlwaysButton)
    }

    @objc private func allowOnce() {
        resolve(with: .allowOnce)
    }

    @objc private func allowAlways() {
        resolve(with: .allowAlways)
    }

    @objc private func deny() {
        resolve(with: .deny)
    }

    private func resolve(with approval: RemoteDeviceApproval) {
        guard let pendingAddress else {
            return
        }
        viewModel.resolveRemoteDeviceApproval(address: pendingAddress, approval: approval)
    }
}
