import AppKit
import ProxyLensCore

@MainActor
final class ReverseProxyManagerViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onClose: (() -> Void)?

    private let viewModel: TrafficConsoleViewModel
    private let tableView = NSTableView()
    private let emptyState = NSTextField(labelWithString: "No reverse proxy routes yet")
    private let lockMessage = NSTextField(
        labelWithString: "Stop capture to change reverse proxy listeners."
    )
    private let addButton = NSButton(title: "New Route…", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let socks5EnabledButton = NSButton(
        checkboxWithTitle: "Enable SOCKS5 proxy", target: nil, action: nil
    )
    private let socks5HostPopUp = NSPopUpButton()
    private let socks5PortField = NSTextField()
    private let socks5SaveButton = NSButton(title: "Apply", target: nil, action: nil)
    private let socks5ValidationField = NSTextField(labelWithString: "")
    private let externalProxyEnabledButton = NSButton(
        checkboxWithTitle: "Enable external HTTP proxy", target: nil, action: nil
    )
    private let externalProxyHostField = NSTextField()
    private let externalProxyPortField = NSTextField()
    private let externalProxyUsernameField = NSTextField()
    private let externalProxyPasswordField = NSSecureTextField()
    private let externalProxyBypassField = NSTextField()
    private let externalProxyApplyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let externalProxyClearButton = NSButton(
        title: "Clear Credentials", target: nil, action: nil
    )
    private let externalProxyValidationField = NSTextField(labelWithString: "")
    private var rows: [ReverseProxyRoute] = []

    var numberOfRoutes: Int { rows.count }

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 920, height: 780)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("reverseProxyManager")

        let title = NSTextField(labelWithString: "Listeners")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Configure local SOCKS5 and reverse proxy entry points. Changes apply the next time capture starts."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.textColor = .secondaryLabelColor

        lockMessage.translatesAutoresizingMaskIntoConstraints = false
        lockMessage.textColor = .systemOrange
        lockMessage.setAccessibilityIdentifier("reverseProxyManager.lockMessage")

        let socks5Section = makeSOCKS5Section()
        let externalProxySection = makeExternalHTTPProxySection()

        configureTable()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.font = .systemFont(ofSize: 14, weight: .medium)
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.setAccessibilityIdentifier("reverseProxyManager.empty")

        configureButton(
            addButton,
            action: #selector(addRoute),
            identifier: "reverseProxyManager.add"
        )
        configureButton(
            editButton,
            action: #selector(editSelectedRoute),
            identifier: "reverseProxyManager.edit"
        )
        configureButton(
            removeButton,
            action: #selector(removeSelectedRoute),
            identifier: "reverseProxyManager.remove"
        )

        let closeButton = NSButton(title: "Close", target: self, action: #selector(close))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.setAccessibilityIdentifier("reverseProxyManager.close")

        for subview in [
            title, subtitle, lockMessage, socks5Section, externalProxySection, scrollView,
            emptyState,
            addButton, editButton, removeButton, closeButton
        ] {
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            lockMessage.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            lockMessage.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            lockMessage.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 6),
            socks5Section.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            socks5Section.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            socks5Section.topAnchor.constraint(equalTo: lockMessage.bottomAnchor, constant: 10),
            socks5Section.heightAnchor.constraint(equalToConstant: 112),
            externalProxySection.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            externalProxySection.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            externalProxySection.topAnchor.constraint(
                equalTo: socks5Section.bottomAnchor, constant: 12),
            externalProxySection.heightAnchor.constraint(equalToConstant: 190),
            scrollView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scrollView.topAnchor.constraint(
                equalTo: externalProxySection.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -14),
            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            addButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            editButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            editButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor)
        ])

        view = container
        reloadRoutes()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadRoutes()
    }

    func reloadRoutes() {
        reloadSOCKS5Configuration()
        reloadExternalHTTPProxyConfiguration()
        let selectedID = selectedRoute?.id
        rows = viewModel.currentReverseProxyRoutes()
        tableView.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        renderState()
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let route = rows[row]
        if tableColumn.identifier.rawValue == "enabled" {
            let button = NSButton(
                checkboxWithTitle: "", target: self, action: #selector(toggleRoute))
            button.state = route.isEnabled ? .on : .off
            button.tag = row
            button.isEnabled = viewModel.canEditReverseProxyRoutes
            button.setAccessibilityLabel("Enable \(route.name)")
            return button
        }

        let value: String
        switch tableColumn.identifier.rawValue {
        case "name": value = route.name
        case "listener": value = "\(route.listenEndpoint.host):\(route.listenEndpoint.port)"
        case "upstream": value = route.upstreamURL.absoluteString
        default: value = ""
        }
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = value
        return field
    }

    func tableViewSelectionDidChange(_: Notification) {
        renderState()
    }

    private var selectedRoute: ReverseProxyRoute? {
        let row = tableView.selectedRow
        return rows.indices.contains(row) ? rows[row] : nil
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(editSelectedRoute)
        tableView.setAccessibilityIdentifier("reverseProxyManager.table")
        tableView.setAccessibilityLabel("Reverse proxy routes")

        let enabled = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        enabled.title = "On"
        enabled.width = 44
        enabled.minWidth = 44
        enabled.maxWidth = 44
        tableView.addTableColumn(enabled)

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Name"
        name.width = 170
        name.minWidth = 100
        tableView.addTableColumn(name)

        let listener = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("listener"))
        listener.title = "Local Listener"
        listener.width = 170
        listener.minWidth = 140
        tableView.addTableColumn(listener)

        let upstream = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("upstream"))
        upstream.title = "Upstream"
        upstream.width = 430
        upstream.minWidth = 220
        tableView.addTableColumn(upstream)
    }

    private func makeSOCKS5Section() -> NSBox {
        let box = NSBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.title = "SOCKS5 Proxy"
        box.titlePosition = .atTop
        box.boxType = .primary

        let content = box.contentView ?? NSView()
        let description = NSTextField(
            labelWithString:
                "Accept no-auth CONNECT clients on this Mac, then inspect HTTP and HTTPS traffic through the normal capture pipeline."
        )
        description.translatesAutoresizingMaskIntoConstraints = false
        description.textColor = .secondaryLabelColor
        description.lineBreakMode = .byTruncatingTail

        socks5EnabledButton.translatesAutoresizingMaskIntoConstraints = false
        socks5EnabledButton.target = self
        socks5EnabledButton.action = #selector(saveSOCKS5Configuration)
        socks5EnabledButton.setAccessibilityIdentifier("listenerManager.socks5.enabled")

        socks5HostPopUp.translatesAutoresizingMaskIntoConstraints = false
        socks5HostPopUp.addItems(withTitles: ["127.0.0.1", "::1"])
        socks5HostPopUp.setAccessibilityIdentifier("listenerManager.socks5.host")
        socks5HostPopUp.setAccessibilityLabel("SOCKS5 local host")

        socks5PortField.translatesAutoresizingMaskIntoConstraints = false
        socks5PortField.placeholderString = "1080"
        socks5PortField.setAccessibilityIdentifier("listenerManager.socks5.port")
        socks5PortField.setAccessibilityLabel("SOCKS5 local port")

        socks5SaveButton.translatesAutoresizingMaskIntoConstraints = false
        socks5SaveButton.bezelStyle = .rounded
        socks5SaveButton.target = self
        socks5SaveButton.action = #selector(saveSOCKS5Configuration)
        socks5SaveButton.setAccessibilityIdentifier("listenerManager.socks5.save")

        socks5ValidationField.translatesAutoresizingMaskIntoConstraints = false
        socks5ValidationField.textColor = .systemRed
        socks5ValidationField.lineBreakMode = .byTruncatingTail
        socks5ValidationField.setAccessibilityIdentifier("listenerManager.socks5.error")

        let hostLabel = NSTextField(labelWithString: "Host")
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        let portLabel = NSTextField(labelWithString: "Port")
        portLabel.translatesAutoresizingMaskIntoConstraints = false

        for subview in [
            description, socks5EnabledButton, hostLabel, socks5HostPopUp,
            portLabel, socks5PortField, socks5SaveButton, socks5ValidationField
        ] {
            content.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            description.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            description.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            description.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            socks5EnabledButton.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            socks5EnabledButton.topAnchor.constraint(
                equalTo: description.bottomAnchor, constant: 8),
            hostLabel.leadingAnchor.constraint(
                equalTo: socks5EnabledButton.trailingAnchor, constant: 24),
            hostLabel.centerYAnchor.constraint(equalTo: socks5EnabledButton.centerYAnchor),
            socks5HostPopUp.leadingAnchor.constraint(
                equalTo: hostLabel.trailingAnchor, constant: 6),
            socks5HostPopUp.centerYAnchor.constraint(equalTo: socks5EnabledButton.centerYAnchor),
            socks5HostPopUp.widthAnchor.constraint(equalToConstant: 112),
            portLabel.leadingAnchor.constraint(
                equalTo: socks5HostPopUp.trailingAnchor, constant: 16),
            portLabel.centerYAnchor.constraint(equalTo: socks5EnabledButton.centerYAnchor),
            socks5PortField.leadingAnchor.constraint(
                equalTo: portLabel.trailingAnchor, constant: 6),
            socks5PortField.centerYAnchor.constraint(equalTo: socks5EnabledButton.centerYAnchor),
            socks5PortField.widthAnchor.constraint(equalToConstant: 84),
            socks5SaveButton.leadingAnchor.constraint(
                equalTo: socks5PortField.trailingAnchor, constant: 10),
            socks5SaveButton.centerYAnchor.constraint(equalTo: socks5EnabledButton.centerYAnchor),
            socks5ValidationField.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            socks5ValidationField.trailingAnchor.constraint(equalTo: description.trailingAnchor),
            socks5ValidationField.topAnchor.constraint(
                equalTo: socks5EnabledButton.bottomAnchor, constant: 5)
        ])
        return box
    }

    private func reloadSOCKS5Configuration() {
        let configuration = viewModel.currentSOCKS5ListenerConfiguration()
        socks5EnabledButton.state = configuration.isEnabled ? .on : .off
        socks5HostPopUp.selectItem(withTitle: configuration.listenEndpoint.host)
        socks5PortField.stringValue = String(configuration.listenEndpoint.port)
        socks5ValidationField.stringValue = ""
    }

    private func makeExternalHTTPProxySection() -> NSBox {
        let box = NSBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.title = "External HTTP Proxy"
        box.titlePosition = .atTop
        box.boxType = .primary

        let content = box.contentView ?? NSView()
        let description = NSTextField(
            labelWithString:
                "Route outbound HTTP and HTTPS through an upstream proxy. Passwords are stored in Keychain."
        )
        description.translatesAutoresizingMaskIntoConstraints = false
        description.textColor = .secondaryLabelColor
        description.lineBreakMode = .byTruncatingTail

        configureExternalProxyControl(
            externalProxyEnabledButton,
            identifier: "listenerManager.external.enabled",
            label: "Enable external HTTP proxy"
        )
        configureExternalProxyControl(
            externalProxyHostField,
            identifier: "listenerManager.external.host",
            label: "External proxy host"
        )
        externalProxyHostField.placeholderString = "proxy.example.com"
        configureExternalProxyControl(
            externalProxyPortField,
            identifier: "listenerManager.external.port",
            label: "External proxy port"
        )
        externalProxyPortField.placeholderString = "8080"
        configureExternalProxyControl(
            externalProxyUsernameField,
            identifier: "listenerManager.external.username",
            label: "External proxy username"
        )
        externalProxyUsernameField.placeholderString = "Optional"
        configureExternalProxyControl(
            externalProxyPasswordField,
            identifier: "listenerManager.external.password",
            label: "External proxy password"
        )
        externalProxyPasswordField.placeholderString = "Leave empty to preserve"
        configureExternalProxyControl(
            externalProxyBypassField,
            identifier: "listenerManager.external.bypass",
            label: "External proxy bypass hosts"
        )
        externalProxyBypassField.placeholderString = "localhost, *.example.test"

        configureButton(
            externalProxyApplyButton,
            action: #selector(saveExternalHTTPProxyConfiguration),
            identifier: "listenerManager.external.save"
        )
        configureButton(
            externalProxyClearButton,
            action: #selector(clearExternalHTTPProxyCredentials),
            identifier: "listenerManager.external.clearCredentials"
        )
        externalProxyValidationField.translatesAutoresizingMaskIntoConstraints = false
        externalProxyValidationField.textColor = .systemRed
        externalProxyValidationField.lineBreakMode = .byTruncatingTail
        externalProxyValidationField.setAccessibilityIdentifier(
            "listenerManager.external.error"
        )

        let hostLabel = NSTextField(labelWithString: "Host")
        let portLabel = NSTextField(labelWithString: "Port")
        let usernameLabel = NSTextField(labelWithString: "Username")
        let passwordLabel = NSTextField(labelWithString: "Password")
        let bypassLabel = NSTextField(labelWithString: "Bypass")
        for label in [hostLabel, portLabel, usernameLabel, passwordLabel, bypassLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        for subview in [
            description, externalProxyEnabledButton, hostLabel, externalProxyHostField,
            portLabel, externalProxyPortField, usernameLabel, externalProxyUsernameField,
            passwordLabel, externalProxyPasswordField, bypassLabel, externalProxyBypassField,
            externalProxyApplyButton, externalProxyClearButton, externalProxyValidationField
        ] {
            content.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            description.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            description.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            description.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            externalProxyEnabledButton.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            externalProxyEnabledButton.topAnchor.constraint(
                equalTo: description.bottomAnchor, constant: 8),
            hostLabel.leadingAnchor.constraint(
                equalTo: externalProxyEnabledButton.trailingAnchor, constant: 18),
            hostLabel.centerYAnchor.constraint(equalTo: externalProxyEnabledButton.centerYAnchor),
            externalProxyHostField.leadingAnchor.constraint(
                equalTo: hostLabel.trailingAnchor, constant: 6),
            externalProxyHostField.centerYAnchor.constraint(
                equalTo: externalProxyEnabledButton.centerYAnchor),
            externalProxyHostField.widthAnchor.constraint(equalToConstant: 210),
            portLabel.leadingAnchor.constraint(
                equalTo: externalProxyHostField.trailingAnchor, constant: 12),
            portLabel.centerYAnchor.constraint(equalTo: externalProxyEnabledButton.centerYAnchor),
            externalProxyPortField.leadingAnchor.constraint(
                equalTo: portLabel.trailingAnchor, constant: 6),
            externalProxyPortField.centerYAnchor.constraint(
                equalTo: externalProxyEnabledButton.centerYAnchor),
            externalProxyPortField.widthAnchor.constraint(equalToConstant: 76),
            usernameLabel.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            usernameLabel.topAnchor.constraint(
                equalTo: externalProxyEnabledButton.bottomAnchor, constant: 12),
            externalProxyUsernameField.leadingAnchor.constraint(
                equalTo: usernameLabel.trailingAnchor, constant: 6),
            externalProxyUsernameField.centerYAnchor.constraint(
                equalTo: usernameLabel.centerYAnchor),
            externalProxyUsernameField.widthAnchor.constraint(equalToConstant: 180),
            passwordLabel.leadingAnchor.constraint(
                equalTo: externalProxyUsernameField.trailingAnchor, constant: 12),
            passwordLabel.centerYAnchor.constraint(equalTo: usernameLabel.centerYAnchor),
            externalProxyPasswordField.leadingAnchor.constraint(
                equalTo: passwordLabel.trailingAnchor, constant: 6),
            externalProxyPasswordField.centerYAnchor.constraint(
                equalTo: usernameLabel.centerYAnchor),
            externalProxyPasswordField.trailingAnchor.constraint(
                equalTo: description.trailingAnchor),
            bypassLabel.leadingAnchor.constraint(equalTo: description.leadingAnchor),
            bypassLabel.topAnchor.constraint(equalTo: usernameLabel.bottomAnchor, constant: 12),
            externalProxyBypassField.leadingAnchor.constraint(
                equalTo: bypassLabel.trailingAnchor, constant: 6),
            externalProxyBypassField.centerYAnchor.constraint(equalTo: bypassLabel.centerYAnchor),
            externalProxyBypassField.trailingAnchor.constraint(
                equalTo: externalProxyClearButton.leadingAnchor, constant: -10),
            externalProxyClearButton.trailingAnchor.constraint(
                equalTo: externalProxyApplyButton.leadingAnchor, constant: -8),
            externalProxyClearButton.centerYAnchor.constraint(equalTo: bypassLabel.centerYAnchor),
            externalProxyApplyButton.trailingAnchor.constraint(equalTo: description.trailingAnchor),
            externalProxyApplyButton.centerYAnchor.constraint(equalTo: bypassLabel.centerYAnchor),
            externalProxyValidationField.leadingAnchor.constraint(
                equalTo: description.leadingAnchor),
            externalProxyValidationField.trailingAnchor.constraint(
                equalTo: description.trailingAnchor),
            externalProxyValidationField.topAnchor.constraint(
                equalTo: bypassLabel.bottomAnchor, constant: 7)
        ])
        return box
    }

    private func configureExternalProxyControl(
        _ control: NSControl,
        identifier: String,
        label: String
    ) {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityIdentifier(identifier)
        control.setAccessibilityLabel(label)
    }

    private func reloadExternalHTTPProxyConfiguration() {
        let draft = TrafficExternalHTTPProxyDraft(
            configuration: viewModel.currentExternalHTTPProxyConfiguration()
        )
        externalProxyEnabledButton.state = draft.isEnabled ? .on : .off
        externalProxyHostField.stringValue = draft.host
        externalProxyPortField.stringValue = draft.port
        externalProxyUsernameField.stringValue = draft.username
        externalProxyPasswordField.stringValue = ""
        externalProxyBypassField.stringValue = draft.bypassHosts
        externalProxyValidationField.stringValue = ""
    }

    private func configureButton(_ button: NSButton, action: Selector, identifier: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
    }

    private func renderState() {
        let canEdit = viewModel.canEditListenerConfiguration
        let hasSelection = selectedRoute != nil
        addButton.isEnabled = canEdit
        editButton.isEnabled = canEdit && hasSelection
        removeButton.isEnabled = canEdit && hasSelection
        lockMessage.isHidden = canEdit
        emptyState.isHidden = !rows.isEmpty
        socks5EnabledButton.isEnabled = canEdit
        socks5HostPopUp.isEnabled = canEdit
        socks5PortField.isEnabled = canEdit
        socks5SaveButton.isEnabled = canEdit
        externalProxyEnabledButton.isEnabled = canEdit
        externalProxyHostField.isEnabled = canEdit
        externalProxyPortField.isEnabled = canEdit
        externalProxyUsernameField.isEnabled = canEdit
        externalProxyPasswordField.isEnabled = canEdit
        externalProxyBypassField.isEnabled = canEdit
        externalProxyApplyButton.isEnabled = canEdit
        externalProxyClearButton.isEnabled = canEdit
    }

    @objc private func saveSOCKS5Configuration() {
        guard viewModel.canEditListenerConfiguration else { return }
        do {
            let configuration = try TrafficSOCKS5ListenerDraft(
                listenHost: socks5HostPopUp.titleOfSelectedItem ?? "127.0.0.1",
                listenPort: socks5PortField.stringValue,
                isEnabled: socks5EnabledButton.state == .on
            ).makeConfiguration()
            try viewModel.saveSOCKS5ListenerConfiguration(configuration)
            reloadSOCKS5Configuration()
            renderState()
        } catch {
            let message = error.localizedDescription
            reloadSOCKS5Configuration()
            socks5ValidationField.stringValue = message
        }
    }

    @objc private func saveExternalHTTPProxyConfiguration() {
        guard viewModel.canEditListenerConfiguration else { return }
        let draft = TrafficExternalHTTPProxyDraft(
            host: externalProxyHostField.stringValue,
            port: externalProxyPortField.stringValue,
            username: externalProxyUsernameField.stringValue,
            password: externalProxyPasswordField.stringValue,
            bypassHosts: externalProxyBypassField.stringValue,
            isEnabled: externalProxyEnabledButton.state == .on
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = try draft.makeConfiguration()
                try await viewModel.saveExternalHTTPProxyConfiguration(
                    configuration,
                    password: draft.password
                )
                reloadExternalHTTPProxyConfiguration()
                renderState()
            } catch {
                externalProxyValidationField.stringValue = error.localizedDescription
                NSAccessibility.post(
                    element: externalProxyValidationField,
                    notification: .valueChanged
                )
            }
        }
    }

    @objc private func clearExternalHTTPProxyCredentials() {
        guard viewModel.canEditListenerConfiguration else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await viewModel.clearExternalHTTPProxyCredentials()
                reloadExternalHTTPProxyConfiguration()
                renderState()
            } catch {
                externalProxyValidationField.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func addRoute() {
        presentEditor(draft: TrafficReverseProxyRouteDraft())
    }

    @objc private func editSelectedRoute() {
        guard let route = selectedRoute, viewModel.canEditReverseProxyRoutes else { return }
        presentEditor(draft: TrafficReverseProxyRouteDraft(route: route))
    }

    @objc private func removeSelectedRoute() {
        guard let route = selectedRoute, viewModel.canEditReverseProxyRoutes else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \"\(route.name)\"?"
        alert.informativeText = "The listener will no longer start with the next capture."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try viewModel.removeReverseProxyRoute(id: route.id)
            reloadRoutes()
        } catch {
            presentRouteError(error)
        }
    }

    @objc private func toggleRoute(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        do {
            try viewModel.setReverseProxyRouteEnabled(
                id: rows[sender.tag].id,
                isEnabled: sender.state == .on
            )
            reloadRoutes()
        } catch {
            sender.state = sender.state == .on ? .off : .on
            presentRouteError(error)
        }
    }

    private func presentEditor(draft: TrafficReverseProxyRouteDraft) {
        guard viewModel.canEditReverseProxyRoutes else { return }
        let controller = ReverseProxyRouteEditorViewController(draft: draft)
        controller.onCancel = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.dismiss(controller)
        }
        controller.onSave = { [weak self, weak controller] route in
            guard let self, let controller else { return }
            do {
                try self.viewModel.saveReverseProxyRoute(route)
                self.dismiss(controller)
                self.reloadRoutes()
            } catch {
                controller.showValidationError(error.localizedDescription)
            }
        }
        presentAsSheet(controller)
    }

    private func presentRouteError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    @objc private func close() {
        onClose?()
    }
}

@MainActor
private final class ReverseProxyRouteEditorViewController: NSViewController {
    var onSave: ((ReverseProxyRoute) -> Void)?
    var onCancel: (() -> Void)?

    private let originalID: UUID?
    private let nameField = NSTextField()
    private let hostPopUp = NSPopUpButton()
    private let portField = NSTextField()
    private let upstreamField = NSTextField()
    private let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let validationField = NSTextField(labelWithString: "")

    init(draft: TrafficReverseProxyRouteDraft) {
        originalID = draft.id
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 560, height: 300)
        nameField.stringValue = draft.name
        portField.stringValue = draft.listenPort
        upstreamField.stringValue = draft.upstreamURL
        enabledButton.state = draft.isEnabled ? .on : .off
        hostPopUp.addItems(withTitles: ["127.0.0.1", "::1"])
        hostPopUp.selectItem(withTitle: draft.listenHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("reverseProxyEditor")

        let title = NSTextField(labelWithString: originalID == nil ? "New Route" : "Edit Route")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        configureField(nameField, identifier: "reverseProxyEditor.name", label: "Route name")
        configureField(portField, identifier: "reverseProxyEditor.port", label: "Local port")
        configureField(
            upstreamField,
            identifier: "reverseProxyEditor.upstreamURL",
            label: "Upstream URL"
        )
        hostPopUp.setAccessibilityIdentifier("reverseProxyEditor.host")
        hostPopUp.setAccessibilityLabel("Local host")
        enabledButton.setAccessibilityIdentifier("reverseProxyEditor.enabled")

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Local host"), hostPopUp],
            [NSTextField(labelWithString: "Local port"), portField],
            [NSTextField(labelWithString: "Upstream URL"), upstreamField]
        ])
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 10
        form.columnSpacing = 12
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 390

        enabledButton.translatesAutoresizingMaskIntoConstraints = false
        validationField.translatesAutoresizingMaskIntoConstraints = false
        validationField.textColor = .systemRed
        validationField.lineBreakMode = .byWordWrapping
        validationField.maximumNumberOfLines = 2
        validationField.setAccessibilityIdentifier("reverseProxyEditor.validation")

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("reverseProxyEditor.save")

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("reverseProxyEditor.cancel")

        for subview in [
            title, form, enabledButton, validationField, saveButton, cancelButton
        ] {
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            form.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            form.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            enabledButton.leadingAnchor.constraint(equalTo: form.leadingAnchor, constant: 104),
            enabledButton.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 12),
            validationField.leadingAnchor.constraint(equalTo: enabledButton.leadingAnchor),
            validationField.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            validationField.topAnchor.constraint(equalTo: enabledButton.bottomAnchor, constant: 8),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor)
        ])

        view = container
    }

    func showValidationError(_ message: String) {
        validationField.stringValue = message
        NSAccessibility.post(element: validationField, notification: .valueChanged)
    }

    private func configureField(_ field: NSTextField, identifier: String, label: String) {
        field.setAccessibilityIdentifier(identifier)
        field.setAccessibilityLabel(label)
        field.lineBreakMode = .byTruncatingMiddle
    }

    @objc private func save() {
        do {
            let route = try TrafficReverseProxyRouteDraft(
                id: originalID,
                name: nameField.stringValue,
                listenHost: hostPopUp.titleOfSelectedItem ?? "127.0.0.1",
                listenPort: portField.stringValue,
                upstreamURL: upstreamField.stringValue,
                isEnabled: enabledButton.state == .on
            ).makeRoute()
            validationField.stringValue = ""
            onSave?(route)
        } catch {
            showValidationError(error.localizedDescription)
        }
    }

    @objc private func cancel() {
        onCancel?()
    }
}
