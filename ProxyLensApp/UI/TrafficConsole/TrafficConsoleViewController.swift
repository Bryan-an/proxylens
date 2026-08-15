import AppKit
import Combine
import SwiftUI

@MainActor
final class TrafficConsoleViewController: NSViewController {
    private let viewModel: TrafficConsoleViewModel
    private let sourceController: SourceListViewController
    private let flowController: FlowTableViewController
    private let inspectorController: InspectorViewController
    private let splitViewController = NSSplitViewController()
    private let detailSplitViewController = NSSplitViewController()
    private let captureButton = NSButton()
    private let clearSessionButton = NSButton()
    private let certificateButton = NSButton()
    private let statusImage = NSImageView()
    private let statusField = NSTextField(labelWithString: "Preparing capture…")
    private lazy var filterBar = TrafficFilterBar(viewModel: viewModel)
    private lazy var inspectorSplitViewItem: NSSplitViewItem = {
        let item = NSSplitViewItem(viewController: inspectorController)
        item.minimumThickness = 240
        item.preferredThicknessFraction = 0.64
        item.canCollapse = true
        return item
    }()
    private var snapshotCancellable: AnyCancellable?
    private var didSetInitialSourcePosition = false
    private var didSetInitialDetailPosition = false
    private var rememberedInspectorHeight: CGFloat?
    private weak var configuredWindow: NSWindow?

    init(viewModel: TrafficConsoleViewModel) {
        self.viewModel = viewModel
        self.sourceController = SourceListViewController(viewModel: viewModel)
        self.flowController = FlowTableViewController(viewModel: viewModel)
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

        certificateButton.translatesAutoresizingMaskIntoConstraints = false
        certificateButton.title = "Trust HTTPS Certificate…"
        certificateButton.bezelStyle = .rounded
        certificateButton.target = self
        certificateButton.action = #selector(showCertificateTrust)
        certificateButton.setAccessibilityIdentifier("certificate.trust")

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(appTitle)
        header.addSubview(statusImage)
        header.addSubview(statusField)
        header.addSubview(certificateButton)
        header.addSubview(clearSessionButton)
        header.addSubview(captureButton)
        NSLayoutConstraint.activate([
            appTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            appTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusImage.leadingAnchor.constraint(equalTo: appTitle.trailingAnchor, constant: 16),
            statusImage.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 12),
            statusImage.heightAnchor.constraint(equalToConstant: 12),
            statusField.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 5),
            statusField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusField.trailingAnchor.constraint(
                lessThanOrEqualTo: certificateButton.leadingAnchor, constant: -12),
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
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
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
        setInitialSourcePositionIfNeeded()
        setInitialDetailPositionIfNeeded()
    }

    private func setInitialSourcePositionIfNeeded() {
        let splitView = splitViewController.splitView
        guard !didSetInitialSourcePosition,
            view.window != nil,
            splitViewController.splitViewItems.count == 2,
            splitView.bounds.width > 0
        else {
            return
        }

        didSetInitialSourcePosition = true
        let sourceItem = splitViewController.splitViewItems[0]
        let preferredWidth = splitView.bounds.width * sourceItem.preferredThicknessFraction
        let sourceWidth = min(
            max(preferredWidth, sourceItem.minimumThickness),
            sourceItem.maximumThickness
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

        let sources = NSSplitViewItem(sidebarWithViewController: sourceController)
        sources.minimumThickness = 170
        sources.maximumThickness = 400
        sources.preferredThicknessFraction = 0.22
        sources.canCollapse = true

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
        splitViewController.addSplitViewItem(sources)
        splitViewController.addSplitViewItem(workspace)
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

    private func dismissCertificateTrustSheet() {
        guard let presented = presentedViewControllers?.last else {
            return
        }
        dismiss(presented)
    }

    @objc private func toggleCapture() {
        viewModel.toggleCapture()
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
