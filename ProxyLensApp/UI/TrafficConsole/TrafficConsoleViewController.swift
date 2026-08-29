import AppKit
import Combine
import ProxyLensApplication
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TrafficConsoleViewController: NSViewController {
    private let viewModel: TrafficConsoleViewModel
    private let sourceListVisibilityStore: any TrafficSourceListVisibilityStoring
    private let composerStore: any TrafficRequestComposerStoring
    private let sourceController: SourceListViewController
    private let flowController: FlowTableViewController
    private let inspectorController: InspectorViewController
    private let splitViewController = NSSplitViewController()
    private let detailSplitViewController = NSSplitViewController()
    private let captureButton = NSButton()
    private let clearSessionButton = NSButton()
    private let composeButton = NSButton()
    private let importButton = NSButton()
    private let reverseProxyButton = NSButton()
    private let sslProxyingButton = NSButton()
    private let remoteDevicesButton = NSButton()
    private let rulesButton = NSButton()
    private let certificateButton = NSButton()
    private let sourceToggleButton = NSButton()
    private let statusImage = NSImageView()
    private let statusField = NSTextField(labelWithString: "Preparing capture…")
    private lazy var filterBar = TrafficFilterBar(viewModel: viewModel)
    private lazy var approvalBar = RemoteDeviceApprovalBar(viewModel: viewModel)
    private lazy var approvalBarHeight = approvalBar.heightAnchor.constraint(equalToConstant: 0)
    private lazy var inspectorSplitViewItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: inspectorController)
        item.minimumThickness = 240
        item.preferredThicknessFraction = 0.64
        item.canCollapse = true
        return item
    }()
    private lazy var sourceSplitViewItem: NSSplitViewItem = {
        let item = NSSplitViewItem(sidebarWithViewController: sourceController)
        item.minimumThickness = 250
        item.maximumThickness = 400
        item.preferredThicknessFraction = 0.22
        item.canCollapse = true
        item.isCollapsed = !sourceListVisibilityStore.isVisible
        return item
    }()
    private var snapshotCancellable: AnyCancellable?
    private var didSetInitialSourcePosition = false
    private var didSetInitialDetailPosition = false
    private var didScheduleInitialSplitPositions = false
    private var rememberedInspectorHeight: CGFloat?
    private weak var configuredWindow: NSWindow?

    init(
        viewModel: TrafficConsoleViewModel,
        sourceListVisibilityStore: any TrafficSourceListVisibilityStoring =
            InMemoryTrafficSourceListVisibilityStore(),
        composerStore: any TrafficRequestComposerStoring =
            UserDefaultsTrafficRequestComposerStore()
    ) {
        self.viewModel = viewModel
        self.sourceListVisibilityStore = sourceListVisibilityStore
        self.composerStore = composerStore
        self.sourceController = SourceListViewController(viewModel: viewModel)
        self.flowController = FlowTableViewController(
            viewModel: viewModel,
            networkConditionProfileStore: UserDefaultsTrafficNetworkConditionProfileStore()
        )
        self.inspectorController = InspectorViewController(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()
        container.setAccessibilityIdentifier("traffic.console")

        let appTitle = NSTextField(labelWithString: "ProxyLens")
        appTitle.translatesAutoresizingMaskIntoConstraints = false
        appTitle.font = .systemFont(ofSize: 15, weight: .semibold)

        sourceToggleButton.translatesAutoresizingMaskIntoConstraints = false
        sourceToggleButton.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: "Hide Source List"
        )
        sourceToggleButton.imagePosition = .imageOnly
        sourceToggleButton.bezelStyle = .texturedRounded
        sourceToggleButton.isBordered = false
        sourceToggleButton.target = self
        sourceToggleButton.action = #selector(toggleSourceList)
        sourceToggleButton.keyEquivalent = "s"
        sourceToggleButton.keyEquivalentModifierMask = [.control, .command]
        sourceToggleButton.setAccessibilityIdentifier("sourceList.toggle")
        updateSourceTogglePresentation()

        statusImage.translatesAutoresizingMaskIntoConstraints = false
        statusImage.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 10, weight: .semibold)

        statusField.translatesAutoresizingMaskIntoConstraints = false
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingMiddle
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.title = "Start Capture"
        captureButton.bezelStyle = .rounded
        captureButton.target = self
        captureButton.action = #selector(toggleCapture)
        captureButton.keyEquivalent = "r"
        captureButton.keyEquivalentModifierMask = [.command]
        captureButton.setAccessibilityIdentifier("capture.toggle")

        clearSessionButton.translatesAutoresizingMaskIntoConstraints = false
        clearSessionButton.title = "Clear Session"
        clearSessionButton.bezelStyle = .rounded
        clearSessionButton.target = self
        clearSessionButton.action = #selector(clearSession)
        clearSessionButton.setAccessibilityIdentifier("session.clear")

        composeButton.translatesAutoresizingMaskIntoConstraints = false
        composeButton.title = "Compose Request…"
        composeButton.bezelStyle = .rounded
        composeButton.target = self
        composeButton.action = #selector(composeRequest(_:))
        composeButton.keyEquivalent = "n"
        composeButton.keyEquivalentModifierMask = [.command]
        composeButton.setAccessibilityIdentifier("request.compose")

        importButton.translatesAutoresizingMaskIntoConstraints = false
        importButton.title = "Import…"
        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importSession(_:))
        importButton.keyEquivalent = "o"
        importButton.keyEquivalentModifierMask = [.command]
        importButton.setAccessibilityIdentifier("session.import")
        importButton.setAccessibilityLabel("Import ProxyLens session or HAR file")

        reverseProxyButton.translatesAutoresizingMaskIntoConstraints = false
        reverseProxyButton.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Reverse Proxy"
        )
        reverseProxyButton.imagePosition = .imageOnly
        reverseProxyButton.bezelStyle = .texturedRounded
        reverseProxyButton.isBordered = false
        reverseProxyButton.target = self
        reverseProxyButton.action = #selector(showReverseProxy)
        reverseProxyButton.toolTip = "Manage Listeners"
        reverseProxyButton.setAccessibilityIdentifier("reverseProxy.manage")
        reverseProxyButton.setAccessibilityLabel("Manage Proxy Listeners")

        sslProxyingButton.translatesAutoresizingMaskIntoConstraints = false
        sslProxyingButton.image = NSImage(
            systemSymbolName: "lock.open",
            accessibilityDescription: "SSL Proxying List"
        )
        sslProxyingButton.imagePosition = .imageOnly
        sslProxyingButton.bezelStyle = .texturedRounded
        sslProxyingButton.isBordered = false
        sslProxyingButton.target = self
        sslProxyingButton.action = #selector(showSSLProxying)
        sslProxyingButton.toolTip = "SSL Proxying List"
        sslProxyingButton.setAccessibilityIdentifier("sslProxying.manage")
        sslProxyingButton.setAccessibilityLabel("Manage SSL Proxying List")

        remoteDevicesButton.translatesAutoresizingMaskIntoConstraints = false
        remoteDevicesButton.image = NSImage(
            systemSymbolName: "iphone.gen3.radiowaves.left.and.right",
            accessibilityDescription: "Remote Devices"
        )
        remoteDevicesButton.imagePosition = .imageOnly
        remoteDevicesButton.bezelStyle = .texturedRounded
        remoteDevicesButton.isBordered = false
        remoteDevicesButton.target = self
        remoteDevicesButton.action = #selector(showRemoteDevices)
        remoteDevicesButton.toolTip = "Remote Devices"
        remoteDevicesButton.setAccessibilityIdentifier("remoteDevices.manage")
        remoteDevicesButton.setAccessibilityLabel("Set up devices on this network")

        rulesButton.translatesAutoresizingMaskIntoConstraints = false
        rulesButton.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Rules"
        )
        rulesButton.imagePosition = .imageOnly
        rulesButton.bezelStyle = .texturedRounded
        rulesButton.isBordered = false
        rulesButton.target = self
        rulesButton.action = #selector(showRules)
        rulesButton.toolTip = "Rules"
        rulesButton.setAccessibilityIdentifier("rules.manage")
        rulesButton.setAccessibilityLabel("Manage Rules")

        certificateButton.translatesAutoresizingMaskIntoConstraints = false
        certificateButton.title = "Trust HTTPS Certificate…"
        certificateButton.bezelStyle = .rounded
        certificateButton.target = self
        certificateButton.action = #selector(showCertificateTrust)
        certificateButton.setAccessibilityIdentifier("certificate.trust")

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(sourceToggleButton)
        header.addSubview(appTitle)
        header.addSubview(statusImage)
        header.addSubview(statusField)
        header.addSubview(reverseProxyButton)
        header.addSubview(sslProxyingButton)
        header.addSubview(remoteDevicesButton)
        header.addSubview(rulesButton)
        header.addSubview(importButton)
        header.addSubview(composeButton)
        header.addSubview(certificateButton)
        header.addSubview(clearSessionButton)
        header.addSubview(captureButton)
        NSLayoutConstraint.activate([
            sourceToggleButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            sourceToggleButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sourceToggleButton.widthAnchor.constraint(equalToConstant: 28),
            sourceToggleButton.heightAnchor.constraint(equalToConstant: 28),
            appTitle.leadingAnchor.constraint(
                equalTo: sourceToggleButton.trailingAnchor, constant: 6),
            appTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusImage.leadingAnchor.constraint(equalTo: appTitle.trailingAnchor, constant: 16),
            statusImage.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 12),
            statusImage.heightAnchor.constraint(equalToConstant: 12),
            statusField.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 5),
            statusField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusField.trailingAnchor.constraint(
                lessThanOrEqualTo: reverseProxyButton.leadingAnchor, constant: -12),
            reverseProxyButton.trailingAnchor.constraint(
                equalTo: sslProxyingButton.leadingAnchor, constant: -8),
            reverseProxyButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            reverseProxyButton.widthAnchor.constraint(equalToConstant: 28),
            reverseProxyButton.heightAnchor.constraint(equalToConstant: 28),
            sslProxyingButton.trailingAnchor.constraint(
                equalTo: remoteDevicesButton.leadingAnchor, constant: -8),
            sslProxyingButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sslProxyingButton.widthAnchor.constraint(equalToConstant: 28),
            sslProxyingButton.heightAnchor.constraint(equalToConstant: 28),
            remoteDevicesButton.trailingAnchor.constraint(
                equalTo: rulesButton.leadingAnchor, constant: -8),
            remoteDevicesButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            remoteDevicesButton.widthAnchor.constraint(equalToConstant: 28),
            remoteDevicesButton.heightAnchor.constraint(equalToConstant: 28),
            rulesButton.trailingAnchor.constraint(
                equalTo: importButton.leadingAnchor, constant: -8),
            rulesButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            rulesButton.widthAnchor.constraint(equalToConstant: 28),
            rulesButton.heightAnchor.constraint(equalToConstant: 28),
            importButton.trailingAnchor.constraint(
                equalTo: composeButton.leadingAnchor, constant: -8),
            importButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            composeButton.trailingAnchor.constraint(
                equalTo: certificateButton.leadingAnchor, constant: -8),
            composeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            certificateButton.trailingAnchor.constraint(
                equalTo: clearSessionButton.leadingAnchor, constant: -8),
            certificateButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearSessionButton.trailingAnchor.constraint(
                equalTo: captureButton.leadingAnchor, constant: -8),
            clearSessionButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            captureButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            captureButton.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        let headerSeparator = NSBox()
        headerSeparator.translatesAutoresizingMaskIntoConstraints = false
        headerSeparator.boxType = .separator

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        configureSplitView()
        addChild(splitViewController)
        let splitView = splitViewController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(headerSeparator)
        container.addSubview(filterBar)
        container.addSubview(approvalBar)
        container.addSubview(separator)
        container.addSubview(splitView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            headerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerSeparator.topAnchor.constraint(equalTo: header.bottomAnchor),
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: 40),
            approvalBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            approvalBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            approvalBar.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            // A hidden view still occupies its constrained height, so the row is collapsed
            // to zero while no device is waiting.
            approvalBarHeight,
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: approvalBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container

        snapshotCancellable = viewModel.$snapshot.sink { [weak self] snapshot in
            self?.render(snapshot)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        hideWindowTitle()
        scheduleInitialSplitPositions()
    }

    private func scheduleInitialSplitPositions() {
        guard !didScheduleInitialSplitPositions else {
            return
        }
        didScheduleInitialSplitPositions = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else {
                return
            }
            view.layoutSubtreeIfNeeded()
            setInitialSourcePositionIfNeeded()
            setInitialDetailPositionIfNeeded()
            view.layoutSubtreeIfNeeded()
        }
    }

    private func setInitialSourcePositionIfNeeded() {
        let splitView = splitViewController.splitView
        guard !didSetInitialSourcePosition,
            view.window != nil,
            !sourceSplitViewItem.isCollapsed,
            splitViewController.splitViewItems.count == 2,
            splitView.bounds.width > 0
        else {
            return
        }

        didSetInitialSourcePosition = true
        let preferredWidth = splitView.bounds.width * sourceSplitViewItem.preferredThicknessFraction
        let sourceWidth = min(
            max(preferredWidth, sourceSplitViewItem.minimumThickness),
            sourceSplitViewItem.maximumThickness
        )
        splitView.setPosition(sourceWidth, ofDividerAt: 0)
    }

    private func setInitialDetailPositionIfNeeded() {
        let detailSplitView = detailSplitViewController.splitView
        guard !didSetInitialDetailPosition,
            view.window != nil,
            !inspectorSplitViewItem.isCollapsed,
            detailSplitViewController.splitViewItems.count == 2,
            detailSplitView.bounds.height > 0
        else {
            return
        }

        didSetInitialDetailPosition = true
        detailSplitView.setPosition(detailSplitView.bounds.height * 0.36, ofDividerAt: 0)
    }

    private func rememberInspectorHeight() {
        let inspectorView = inspectorController.view
        guard view.window != nil,
            !inspectorView.visibleRect.isEmpty,
            inspectorView.frame.height > 0
        else {
            return
        }

        rememberedInspectorHeight = inspectorView.frame.height
    }

    private func restoreInspectorHeightIfPossible() {
        guard let rememberedInspectorHeight,
            view.window != nil,
            detailSplitViewController.splitViewItems.count == 2
        else {
            return
        }

        view.layoutSubtreeIfNeeded()
        let detailSplitView = detailSplitViewController.splitView
        let availableHeight = detailSplitView.bounds.height - detailSplitView.dividerThickness
        let flowMinimumHeight = detailSplitViewController.splitViewItems[0].minimumThickness
        let maximumInspectorHeight = max(0, availableHeight - flowMinimumHeight)
        let minimumInspectorHeight = min(
            inspectorSplitViewItem.minimumThickness,
            maximumInspectorHeight
        )
        let inspectorHeight = min(
            max(rememberedInspectorHeight, minimumInspectorHeight),
            maximumInspectorHeight
        )
        detailSplitView.setPosition(availableHeight - inspectorHeight, ofDividerAt: 0)
    }

    private func hideWindowTitle() {
        guard let window = view.window, configuredWindow !== window else {
            return
        }

        window.titleVisibility = .hidden
        window.toolbar = nil
        configuredWindow = window
    }

    private func configureSplitView() {
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.setAccessibilityIdentifier("traffic.split.root")

        detailSplitViewController.splitView.isVertical = false
        detailSplitViewController.splitView.dividerStyle = .thin
        detailSplitViewController.splitView.setAccessibilityIdentifier("traffic.split.detail")
        sourceController.view.setAccessibilityIdentifier("traffic.pane.sources")
        flowController.view.setAccessibilityIdentifier("traffic.pane.flows")
        inspectorController.view.setAccessibilityIdentifier("traffic.pane.inspector")

        let workspace = NSSplitViewItem(viewController: detailSplitViewController)
        workspace.minimumThickness = 640
        workspace.preferredThicknessFraction = 0.78

        let flows = NSSplitViewItem(viewController: flowController)
        flows.minimumThickness = 180
        flows.preferredThicknessFraction = 0.36
        flows.holdingPriority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultLow.rawValue + 1
        )

        detailSplitViewController.addSplitViewItem(flows)
        detailSplitViewController.addSplitViewItem(inspectorSplitViewItem)
        splitViewController.addSplitViewItem(sourceSplitViewItem)
        splitViewController.addSplitViewItem(workspace)
    }

    @objc private func toggleSourceList() {
        sourceSplitViewItem.isCollapsed.toggle()
        sourceListVisibilityStore.save(isVisible: !sourceSplitViewItem.isCollapsed)
        updateSourceTogglePresentation()
    }

    private func updateSourceTogglePresentation() {
        let title = sourceSplitViewItem.isCollapsed ? "Show Source List" : "Hide Source List"
        sourceToggleButton.setAccessibilityLabel(title)
        sourceToggleButton.toolTip = "\(title) (⌃⌘S)"
    }

    private func render(_ snapshot: TrafficConsoleSnapshot) {
        sourceController.render(snapshot)
        flowController.render(snapshot)
        inspectorController.render(snapshot)

        let shouldCollapseInspector = snapshot.selectedFlowID == nil
        if inspectorSplitViewItem.isCollapsed != shouldCollapseInspector {
            if shouldCollapseInspector {
                rememberInspectorHeight()
                inspectorSplitViewItem.isCollapsed = true
            } else {
                inspectorSplitViewItem.isCollapsed = false
                restoreInspectorHeightIfPossible()
            }
        }
        if !shouldCollapseInspector,
            !didSetInitialDetailPosition,
            view.window != nil
        {
            view.layoutSubtreeIfNeeded()
            setInitialDetailPositionIfNeeded()
        }

        let presentation = CaptureControlPresentation(snapshot.capture)
        statusImage.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: presentation.status
        )
        filterBar.render(snapshot)
        approvalBar.render(snapshot)
        approvalBarHeight.constant = snapshot.remoteAccess.pendingApproval == nil ? 0 : 32
        captureButton.title = presentation.buttonTitle
        captureButton.isEnabled = presentation.buttonEnabled
        if case .failed = snapshot.capture {
            statusField.stringValue = presentation.status
            statusField.toolTip = presentation.status
            statusImage.contentTintColor = presentation.color
        } else if let warning = snapshot.workspaceWarning {
            statusField.stringValue = warning
            statusField.toolTip = warning
            statusImage.contentTintColor = .systemOrange
        } else {
            statusField.stringValue = presentation.status
            statusField.toolTip = presentation.status
            statusImage.contentTintColor = presentation.color
        }
        let canClear: Bool
        switch snapshot.capture {
        case .stopped, .failed, .running:
            canClear = snapshot.allFlowCount > 0
        case .recovering, .starting, .stopping:
            canClear = false
        }
        clearSessionButton.isEnabled = canClear
        switch snapshot.certificateTrust {
        case .trusted:
            certificateButton.title = "HTTPS Certificate Trusted"
        case .notGenerated, .untrusted, nil:
            certificateButton.title = "Trust HTTPS Certificate…"
        }
    }

    @objc private func showCertificateTrust() {
        let sheet = NSHostingController(
            rootView: CertificateTrustView(viewModel: viewModel) { [weak self] in
                self?.dismissCertificateTrustSheet()
            }
        )
        sheet.title = "HTTPS Certificate"
        presentAsSheet(sheet)
    }

    @objc private func showRules() {
        let controller = RuleManagerViewController(viewModel: viewModel)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }
            self.dismiss(controller)
        }
        presentAsSheet(controller)
    }

    @objc private func showReverseProxy() {
        let controller = ReverseProxyManagerViewController(viewModel: viewModel)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }
            self.dismiss(controller)
        }
        presentAsSheet(controller)
    }

    @objc private func showRemoteDevices() {
        let controller = RemoteDeviceManagerViewController(viewModel: viewModel)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }
            self.dismiss(controller)
        }
        presentAsSheet(controller)
    }

    @objc private func showSSLProxying() {
        let controller = SSLProxyingManagerViewController(viewModel: viewModel)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else {
                return
            }
            self.dismiss(controller)
        }
        presentAsSheet(controller)
    }

    private func dismissCertificateTrustSheet() {
        guard let presented = presentedViewControllers?.last else {
            return
        }
        dismiss(presented)
    }

    @objc private func toggleCapture() {
        viewModel.toggleCapture()
    }

    @objc private func composeRequest(_: NSButton) {
        Task { @MainActor in
            await presentRequestComposer()
        }
    }

    @objc private func importSession(_: NSButton) {
        Task { @MainActor in
            await presentSessionImporter()
        }
    }

    private func presentSessionImporter() async {
        let panel = NSOpenPanel()
        panel.title = "Import Session"
        panel.message = "Choose a ProxyLens session package or HAR 1.2 file."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .package,
            UTType(filenameExtension: "har"),
            .json
        ].compactMap { $0 }

        let response: NSApplication.ModalResponse
        if let window = view.window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let fileURL = panel.url else {
            return
        }

        importButton.isEnabled = false
        importButton.title = "Importing…"
        defer {
            importButton.title = "Import…"
            importButton.isEnabled = true
        }
        do {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if fileURL.pathExtension.lowercased() == PortableSessionService.fileExtension
                || values?.isDirectory == true
            {
                try await viewModel.importPortableSession(from: fileURL)
            } else {
                try await viewModel.importHAR(from: fileURL)
            }
        } catch {
            let alert = NSAlert(error: error)
            if let window = view.window {
                await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    private func presentRequestComposer() async {
        let editor = RequestEditorViewController(
            draft: TrafficRequestEditDraft(
                headersText: """
                    GET https://example.com/ HTTP/1.1
                    Accept: application/json
                    """,
                bodyText: "",
                canEditBody: true,
                bodyMessage: nil
            ),
            allowsCURLImport: true,
            composerStore: composerStore
        )
        addChild(editor)
        defer { editor.removeFromParent() }

        let alert = NSAlert()
        alert.messageText = "Compose Request"
        alert.informativeText =
            "Enter an absolute HTTP or HTTPS URL, or import a cURL command from the clipboard."
        alert.addButton(withTitle: "Send Request")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        alert.accessoryView = editor.view
        alert.window.initialFirstResponder = editor.initialFirstResponder

        let response: NSApplication.ModalResponse
        if let window = view.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else {
            return
        }

        let bodyText = editor.bodyText
        do {
            try await viewModel.composeRequest(
                headersText: editor.headersText,
                bodyText: bodyText.isEmpty ? nil : bodyText
            )
            _ = composerStore.recordHistory(
                headersText: editor.headersText,
                bodyText: bodyText
            )
        } catch {
            let errorAlert = NSAlert(error: error)
            if let window = view.window {
                await errorAlert.beginSheetModal(for: window)
            } else {
                errorAlert.runModal()
            }
        }
    }

    @objc private func clearSession() {
        Task { @MainActor in
            do {
                try await viewModel.clearSession()
            } catch {
                let alert = NSAlert(error: error)
                if let window = view.window {
                    await alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }
}

private struct CaptureControlPresentation {
    let status: String
    let color: NSColor
    let buttonTitle: String
    let buttonEnabled: Bool

    @MainActor
    init(_ capture: TrafficCapturePresentation) {
        switch capture {
        case .recovering:
            status = "Restoring previous capture state…"
            color = .systemOrange
            buttonTitle = "Start Capture"
            buttonEnabled = false
        case .stopped:
            status = "Capture stopped"
            color = .secondaryLabelColor
            buttonTitle = "Start Capture"
            buttonEnabled = true
        case .starting:
            status = "Starting capture…"
            color = .systemOrange
            buttonTitle = "Starting…"
            buttonEnabled = false
        case .running(let context, let warning):
            status = warning ?? "Capturing on \(context.endpoint.host):\(context.endpoint.port)"
            color = warning == nil ? .systemRed : .systemOrange
            buttonTitle = warning == nil ? "Stop Capture" : "Retry Stop"
            buttonEnabled = true
        case .stopping:
            status = "Stopping capture…"
            color = .systemOrange
            buttonTitle = "Stopping…"
            buttonEnabled = false
        case .failed(let message):
            status = message
            color = .systemRed
            buttonTitle = "Retry Capture"
            buttonEnabled = true
        }
    }
}
