import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ProxyLensApplication
import ProxyLensCore

/// Sets up a phone, tablet, or any other device on this network: the switch that widens the
/// listener, where to point the device, the certificate page to open, and the devices that
/// have been admitted so far.
///
/// Widening the listener is a listener change, so the switch follows the same
/// stopped-capture rule as the reverse-proxy and SOCKS5 settings.
@MainActor
final class RemoteDeviceManagerViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onClose: (() -> Void)?

    private let viewModel: TrafficConsoleViewModel
    private let enableToggle = NSButton(
        checkboxWithTitle: "Allow devices on this network",
        target: nil,
        action: nil
    )
    private let lockLabel = NSTextField(labelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private let qrImageView = NSImageView()
    private let instructionsLabel = NSTextField(wrappingLabelWithString: "")
    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let renameButton = NSButton()
    private let revokeButton = NSButton()
    private let emptyState = NSTextField(labelWithString: "No devices have connected yet.")
    private let validationLabel = NSTextField(labelWithString: "")
    private var devices: [TrafficRemoteDeviceSummary] = []
    private var renderedSetupURL: String?

    var numberOfDevices: Int { devices.count }

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 620, height: 620)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("remoteDevicesManager")

        let title = NSTextField(labelWithString: "Remote Devices")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "While this is on, the proxy also listens on this network and every device "
                + "that connects has to be allowed by you first. It stays off until you turn "
                + "it on, and turning it off puts the proxy back on this Mac only."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.textColor = .secondaryLabelColor

        enableToggle.translatesAutoresizingMaskIntoConstraints = false
        enableToggle.target = self
        enableToggle.action = #selector(toggleRemoteAccess)
        enableToggle.setAccessibilityIdentifier("remoteDevices.enableToggle")
        enableToggle.setAccessibilityLabel("Allow devices on this network")

        lockLabel.translatesAutoresizingMaskIntoConstraints = false
        lockLabel.textColor = .secondaryLabelColor
        lockLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lockLabel.setAccessibilityIdentifier("remoteDevices.lock")

        addressLabel.translatesAutoresizingMaskIntoConstraints = false
        addressLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        addressLabel.setAccessibilityIdentifier("remoteDevices.address")
        addressLabel.setAccessibilityLabel("Proxy address for devices")

        qrImageView.translatesAutoresizingMaskIntoConstraints = false
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.setAccessibilityIdentifier("remoteDevices.qr")
        qrImageView.setAccessibilityLabel("Certificate setup QR code")

        instructionsLabel.translatesAutoresizingMaskIntoConstraints = false
        instructionsLabel.textColor = .secondaryLabelColor
        instructionsLabel.setAccessibilityIdentifier("remoteDevices.instructions")

        validationLabel.translatesAutoresizingMaskIntoConstraints = false
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.maximumNumberOfLines = 2
        validationLabel.setAccessibilityIdentifier("remoteDevices.validation")

        configureTable()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.setAccessibilityIdentifier("remoteDevices.empty")

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "Name the selected device"
        nameField.setAccessibilityIdentifier("remoteDevices.name")
        nameField.setAccessibilityLabel("Device name")

        configureButton(
            renameButton,
            title: "Rename",
            action: #selector(renameSelectedDevice),
            identifier: "remoteDevices.rename"
        )
        configureButton(
            revokeButton,
            title: "Revoke",
            action: #selector(revokeSelectedDevice),
            identifier: "remoteDevices.revoke"
        )

        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityIdentifier("remoteDevices.close")

        // Only the device table may grow. Every chrome row pins its vertical size so the
        // solver never takes the table's slack — the layout bug this repo has hit twice.
        for chromeRow in [
            title, subtitle, enableToggle, lockLabel, addressLabel, instructionsLabel,
            validationLabel, nameField, renameButton, revokeButton, closeButton
        ] as [NSView] {
            chromeRow.setContentHuggingPriority(.required, for: .vertical)
            chromeRow.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        for subview in [
            title, subtitle, enableToggle, lockLabel, addressLabel, qrImageView,
            instructionsLabel, validationLabel, scrollView, emptyState, nameField,
            renameButton, revokeButton, closeButton
        ] as [NSView] {
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            enableToggle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            enableToggle.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            lockLabel.leadingAnchor.constraint(
                equalTo: enableToggle.trailingAnchor, constant: 8),
            lockLabel.trailingAnchor.constraint(lessThanOrEqualTo: title.trailingAnchor),
            lockLabel.centerYAnchor.constraint(equalTo: enableToggle.centerYAnchor),
            addressLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            addressLabel.topAnchor.constraint(equalTo: enableToggle.bottomAnchor, constant: 12),
            addressLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: qrImageView.leadingAnchor, constant: -12),
            instructionsLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            instructionsLabel.topAnchor.constraint(
                equalTo: addressLabel.bottomAnchor, constant: 6),
            instructionsLabel.trailingAnchor.constraint(
                equalTo: qrImageView.leadingAnchor, constant: -12),
            qrImageView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            qrImageView.topAnchor.constraint(equalTo: addressLabel.topAnchor),
            qrImageView.widthAnchor.constraint(equalToConstant: 132),
            qrImageView.heightAnchor.constraint(equalToConstant: 132),
            validationLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            validationLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            validationLabel.topAnchor.constraint(
                greaterThanOrEqualTo: instructionsLabel.bottomAnchor, constant: 8),
            validationLabel.topAnchor.constraint(
                greaterThanOrEqualTo: qrImageView.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scrollView.topAnchor.constraint(
                equalTo: validationLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: nameField.topAnchor, constant: -12),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            nameField.trailingAnchor.constraint(
                equalTo: renameButton.leadingAnchor, constant: -8),
            nameField.bottomAnchor.constraint(equalTo: revokeButton.topAnchor, constant: -12),
            renameButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            renameButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            revokeButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            revokeButton.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -16),
            closeButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: revokeButton.centerYAnchor)
        ])

        view = container
    }

    func render(_ snapshot: TrafficConsoleSnapshot) {
        let remoteAccess = snapshot.remoteAccess
        let canEdit = Self.canEditListeners(snapshot.capture)

        enableToggle.state = remoteAccess.isEnabled ? .on : .off
        enableToggle.isEnabled = canEdit
        lockLabel.stringValue = canEdit ? "" : "Stop capture to change this."
        lockLabel.isHidden = canEdit

        if let address = remoteAccess.addresses.first, remoteAccess.listenPort > 0 {
            addressLabel.stringValue = "\(address):\(remoteAccess.listenPort)"
        } else {
            addressLabel.stringValue = "No network address available"
        }

        instructionsLabel.stringValue = Self.instructions(for: remoteAccess)
        renderQRCode(for: remoteAccess.setupURL)

        devices = remoteAccess.devices
        tableView.reloadData()
        emptyState.isHidden = !devices.isEmpty
        updateSelectionDependentControls()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render(viewModel.snapshot)
    }

    // MARK: - Table

    func numberOfRows(in _: NSTableView) -> Int { devices.count }

    func tableView(
        _: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard devices.indices.contains(row), let tableColumn else {
            return nil
        }
        let device = devices[row]
        let value: String =
            switch tableColumn.identifier.rawValue {
            case "device": device.displayName
            case "address": device.id
            case "trusted": device.isTrusted ? "Always allowed" : "Asks every session"
            default: "\(device.flowCount)"
            }
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateSelectionDependentControls()
    }

    // MARK: - Actions

    @objc private func toggleRemoteAccess() {
        let isEnabled = enableToggle.state == .on
        do {
            try viewModel.saveRemoteAccessConfiguration(
                RemoteAccessConfiguration(isEnabled: isEnabled)
            )
            validationLabel.stringValue = ""
            validationLabel.isHidden = true
        } catch {
            validationLabel.stringValue = error.localizedDescription
            validationLabel.isHidden = false
            NSAccessibility.post(element: validationLabel, notification: .valueChanged)
        }
        render(viewModel.snapshot)
    }

    @objc private func renameSelectedDevice() {
        guard let device = selectedDevice() else {
            return
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.renameRemoteDevice(address: device.id, to: name.isEmpty ? nil : name)
    }

    @objc private func revokeSelectedDevice() {
        guard let device = selectedDevice() else {
            return
        }
        viewModel.revokeRemoteDevice(address: device.id)
    }

    @objc private func close() {
        onClose?()
    }

    // MARK: - Helpers

    private func selectedDevice() -> TrafficRemoteDeviceSummary? {
        let selection = tableView.selectedRow
        guard devices.indices.contains(selection) else {
            return nil
        }
        return devices[selection]
    }

    private func updateSelectionDependentControls() {
        let device = selectedDevice()
        renameButton.isEnabled = device != nil
        revokeButton.isEnabled = device?.isTrusted ?? false
        if let device, nameField.currentEditor() == nil {
            nameField.stringValue = device.name ?? ""
        }
    }

    private func renderQRCode(for setupURL: String?) {
        guard let setupURL else {
            qrImageView.image = nil
            qrImageView.isHidden = true
            renderedSetupURL = nil
            return
        }
        qrImageView.isHidden = false
        guard renderedSetupURL != setupURL else {
            return
        }
        renderedSetupURL = setupURL
        qrImageView.image = Self.qrCode(for: setupURL)
        qrImageView.setAccessibilityLabel("QR code for \(setupURL)")
    }

    private static func qrCode(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            return nil
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 132, height: 132))
    }

    private static func instructions(for remoteAccess: TrafficRemoteAccessSnapshot) -> String {
        guard let setupURL = remoteAccess.setupURL else {
            return
                "Connect this Mac to a network to get an address a device can be pointed at."
        }
        return """
            1. On the device, set the Wi-Fi HTTP proxy to the address above.
            2. Open \(setupURL) on the device and install the certificate.
            3. iOS: turn on full trust in Settings › General › About › Certificate Trust \
            Settings. Android: install it as a CA certificate.
            """
    }

    private static func canEditListeners(_ capture: TrafficCapturePresentation) -> Bool {
        switch capture {
        case .stopped, .failed:
            true
        case .recovering, .starting, .running, .stopping:
            false
        }
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 24
        tableView.delegate = self
        tableView.dataSource = self
        tableView.setAccessibilityIdentifier("remoteDevices.table")
        tableView.setAccessibilityLabel("Devices on this network")

        for (identifier, title, width) in [
            ("device", "Device", 200.0),
            ("address", "Address", 150.0),
            ("trusted", "Access", 150.0),
            ("flows", "Flows", 60.0)
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 50
            tableView.addTableColumn(column)
        }
    }

    private func configureButton(
        _ button: NSButton,
        title: String,
        action: Selector,
        identifier: String
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
    }
}
