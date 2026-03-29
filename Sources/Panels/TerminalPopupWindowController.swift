import AppKit
import Bonsplit
import Combine
import WebKit

/// In-window popup overlay with tabbed panels. Panels can be terminals,
/// browsers, or any view. Rendered as an NSPanel child window so it
/// appears above Ghostty's Metal terminal layers.
///
/// Behavior:
/// - Centered within the parent cmux window, not floating on desktop
/// - Moves and resizes with the parent window
/// - Panels persist between show/hide (Quake-style)
/// - Toggle keybind (prefix+i) shows/hides
/// - Ctrl+Tab / Ctrl+Shift+Tab cycles tabs
/// - Cmd+W closes current tab (hides popup if last tab)
@MainActor
final class TerminalPopupWindowController: NSObject, NSWindowDelegate {

    // MARK: - Configuration

    struct Config {
        var widthPercent: CGFloat = 0.8
        var heightPercent: CGFloat = 0.8
        var minWidth: CGFloat = 400
        var minHeight: CGFloat = 300
        var workingDirectory: String? = nil
        var initialCommand: String? = nil
    }

    // MARK: - Popup Tab

    enum PopupTabContent {
        case terminal(surface: TerminalSurface)
        case browser(webView: WKWebView, url: URL?)
    }

    final class PopupTab {
        let id = UUID()
        var title: String
        var iconSystemName: String
        let content: PopupTabContent

        /// The NSView to display for this tab.
        var contentView: NSView {
            switch content {
            case .terminal(let surface):
                return surface.hostedView
            case .browser(let webView, _):
                return webView
            }
        }

        /// The view to make first responder for keyboard input.
        var focusableView: NSView? {
            switch content {
            case .terminal(let surface):
                return surface.focusableView
            case .browser(let webView, _):
                return webView
            }
        }

        init(title: String, iconSystemName: String, content: PopupTabContent) {
            self.title = title
            self.iconSystemName = iconSystemName
            self.content = content
        }
    }

    // MARK: - State

    private var panel: NSPanel?
    private(set) var tabs: [PopupTab] = []
    private(set) var selectedTabIndex: Int = 0
    private var config: Config
    private weak var parentWindow: NSWindow?
    private var isShowing = false
    private var panelInitialized = false
    private var parentFrameObservation: NSObjectProtocol?
    private var parentMoveObservation: NSObjectProtocol?
    private var childExitObservations: [UUID: NSObjectProtocol] = [:]
    private var containerView: PopupContainerView?
    private var tabBarView: PopupTabBarView?
    private var contentArea: NSView?
    private var browserTitleObservers: [UUID: NSKeyValueObservation] = [:]

    var selectedTab: PopupTab? {
        guard selectedTabIndex >= 0, selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    // MARK: - Init

    init(parentWindow: NSWindow?, config: Config = Config()) {
        self.config = config
        self.parentWindow = parentWindow
        super.init()
    }

    deinit {
        for obs in childExitObservations.values {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = parentFrameObservation {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = parentMoveObservation {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Public API

    func toggle() {
        if isShowing {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let parentWindow else { return }

        if !panelInitialized {
            initializePanel()
        }

        // Ensure at least one tab exists (default terminal)
        if tabs.isEmpty {
            addTerminalTab(
                command: config.initialCommand,
                cwd: config.workingDirectory,
                select: true
            )
        }

        guard let panel else { return }

        let popupFrame = computePopupFrame(in: parentWindow)
        panel.setFrame(popupFrame, display: false)

        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        isShowing = true
        focusSelectedTab()
        startTrackingParentFrame()
    }

    func hide() {
        guard let panel, isShowing else { return }

        stopTrackingParentFrame()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.parentWindow?.makeKeyAndOrderFront(nil)
        })

        isShowing = false
    }

    func close() {
        hide()
        teardownAll()
    }

    var isVisible: Bool { isShowing }

    // MARK: - Tab Management

    @discardableResult
    func addTerminalTab(
        command: String? = nil,
        cwd: String? = nil,
        title: String? = nil,
        select: Bool = true
    ) -> PopupTab {
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: nil,
            workingDirectory: cwd,
            initialCommand: command,
            initialEnvironmentOverrides: [:],
            additionalEnvironment: ["CMUX_POPUP": "1"]
        )

        let tabTitle = title ?? command?.components(separatedBy: "/").last?.components(separatedBy: " ").first ?? "Terminal"
        let tab = PopupTab(
            title: tabTitle,
            iconSystemName: "terminal",
            content: .terminal(surface: surface)
        )

        // Watch for shell exit
        let surfaceId = surface.id
        let tabId = tab.id
        let obs = NotificationCenter.default.addObserver(
            forName: .cmuxChildExited,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let exitedId = notification.userInfo?["surfaceId"] as? UUID,
                  exitedId == surfaceId else { return }
            self.handleTabShellExit(tabId: tabId)
        }
        childExitObservations[tabId] = obs

        insertTab(tab, select: select)
        return tab
    }

    @discardableResult
    func addBrowserTab(
        url: URL,
        title: String? = nil,
        select: Bool = true
    ) -> PopupTab {
        let webView = WKWebView(frame: .zero)
        webView.load(URLRequest(url: url))

        let tabTitle = title ?? url.host ?? "Browser"
        let tab = PopupTab(
            title: tabTitle,
            iconSystemName: "globe",
            content: .browser(webView: webView, url: url)
        )

        // Observe title changes from the web page
        let tabId = tab.id
        let observer = webView.observe(\.title, options: [.new]) { [weak self, weak tab] _, change in
            guard let self, let tab else { return }
            if let newTitle = change.newValue ?? nil, !newTitle.isEmpty {
                tab.title = newTitle
                Task { @MainActor in
                    self.tabBarView?.refresh(tabs: self.tabs, selectedIndex: self.selectedTabIndex)
                }
            }
        }
        browserTitleObservers[tabId] = observer

        insertTab(tab, select: select)
        return tab
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs[index]

        // Clean up observers
        if let obs = childExitObservations.removeValue(forKey: tab.id) {
            NotificationCenter.default.removeObserver(obs)
        }
        browserTitleObservers.removeValue(forKey: tab.id)

        // Remove content view
        tab.contentView.removeFromSuperview()

        tabs.remove(at: index)

        if tabs.isEmpty {
            hide()
            return
        }

        // Adjust selection
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = tabs.count - 1
        }
        showTab(at: selectedTabIndex)
    }

    func closeSelectedTab() {
        closeTab(at: selectedTabIndex)
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count, index != selectedTabIndex else { return }
        selectedTabIndex = index
        showTab(at: index)
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (selectedTabIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (selectedTabIndex - 1 + tabs.count) % tabs.count)
    }

    // MARK: - Panel Setup

    private func initializePanel() {
        guard !panelInitialized, let parentWindow else { return }

        let popupFrame = computePopupFrame(in: parentWindow)
        let newPanel = TerminalPopupPanel(
            contentRect: popupFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.identifier = NSUserInterfaceItemIdentifier("cmux.terminal-popup")
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.backgroundColor = .clear
        newPanel.level = parentWindow.level
        newPanel.collectionBehavior = [.fullScreenAuxiliary]
        newPanel.hidesOnDeactivate = false
        newPanel.delegate = self
        newPanel.popupController = self
        self.panel = newPanel

        // Build visual container
        let container = PopupContainerView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        self.containerView = container

        // Tab bar at top
        let tabBar = PopupTabBarView(controller: self)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabBar)
        self.tabBarView = tabBar

        // Content area below tab bar
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        container.addSubview(content)
        self.contentArea = content

        // Layout container in panel
        container.translatesAutoresizingMaskIntoConstraints = false
        let panelContentView = newPanel.contentView!
        panelContentView.wantsLayer = true
        panelContentView.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: panelContentView.topAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor, constant: 8),
            container.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor, constant: -8),
            container.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor, constant: -8),

            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 32),

            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Shadow
        let shadowLayer = CALayer()
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.4
        shadowLayer.shadowOffset = CGSize(width: 0, height: -2)
        shadowLayer.shadowRadius = 12
        panelContentView.layer?.insertSublayer(shadowLayer, at: 0)

        panelInitialized = true
    }

    // MARK: - Tab Display

    private func insertTab(_ tab: PopupTab, select: Bool) {
        tabs.append(tab)
        if select {
            selectedTabIndex = tabs.count - 1
            showTab(at: selectedTabIndex)
        }
        tabBarView?.refresh(tabs: tabs, selectedIndex: selectedTabIndex)
    }

    private func showTab(at index: Int) {
        guard let contentArea, index >= 0, index < tabs.count else { return }

        // Hide all tab content views
        for tab in tabs {
            tab.contentView.removeFromSuperview()
        }

        // Show selected tab
        let tab = tabs[index]
        let view = tab.contentView
        view.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentArea.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])

        tabBarView?.refresh(tabs: tabs, selectedIndex: index)
        focusSelectedTab()
    }

    private func focusSelectedTab() {
        guard let panel, isShowing, let tab = selectedTab else { return }
        if let focusable = tab.focusableView {
            panel.makeFirstResponder(focusable)
        }
    }

    // MARK: - Shell Exit

    private func handleTabShellExit(tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        // If it's the only tab, hide the popup
        if tabs.count == 1 {
            hide()
            // Reset so next show() creates a fresh tab
            tabs.removeAll()
            if let obs = childExitObservations.removeValue(forKey: tabId) {
                NotificationCenter.default.removeObserver(obs)
            }
        } else {
            closeTab(at: index)
        }
    }

    // MARK: - Teardown

    private func teardownAll() {
        stopTrackingParentFrame()
        for obs in childExitObservations.values {
            NotificationCenter.default.removeObserver(obs)
        }
        childExitObservations.removeAll()
        browserTitleObservers.removeAll()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        for tab in tabs {
            tab.contentView.removeFromSuperview()
        }
        tabs.removeAll()
        containerView?.removeFromSuperview()
        containerView = nil
        tabBarView = nil
        contentArea = nil
        panel = nil
        panelInitialized = false
        isShowing = false
    }

    // MARK: - Geometry

    private func computePopupFrame(in parentWindow: NSWindow) -> NSRect {
        let parentFrame = parentWindow.frame
        let parentContent = parentWindow.contentRect(forFrameRect: parentFrame)

        let width = max(config.minWidth, parentContent.width * config.widthPercent)
        let height = max(config.minHeight, parentContent.height * config.heightPercent)

        let x = parentContent.midX - width / 2
        let y = parentContent.midY - height / 2

        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Parent Frame Tracking

    private func startTrackingParentFrame() {
        stopTrackingParentFrame()
        guard let parentWindow else { return }

        parentFrameObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            self?.repositionToParent()
        }

        parentMoveObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: parentWindow,
            queue: .main
        ) { [weak self] _ in
            self?.repositionToParent()
        }
    }

    private func stopTrackingParentFrame() {
        if let obs = parentFrameObservation {
            NotificationCenter.default.removeObserver(obs)
            parentFrameObservation = nil
        }
        if let obs = parentMoveObservation {
            NotificationCenter.default.removeObserver(obs)
            parentMoveObservation = nil
        }
    }

    private func repositionToParent() {
        guard let parentWindow, let panel, isShowing else { return }
        let popupFrame = computePopupFrame(in: parentWindow)
        panel.setFrame(popupFrame, display: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Don't auto-hide on focus loss
    }
}

// MARK: - Tab Bar View

/// Minimal tab bar for the popup: horizontal row of pill-shaped tab buttons.
@MainActor
final class PopupTabBarView: NSView {
    private weak var controller: TerminalPopupWindowController?
    private var tabButtons: [NSButton] = []
    private let separator = NSView()

    init(controller: TerminalPopupWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Bottom separator line
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    func refresh(tabs: [TerminalPopupWindowController.PopupTab], selectedIndex: Int) {
        // Remove old buttons
        for button in tabButtons {
            button.removeFromSuperview()
        }
        tabButtons.removeAll()

        // Hide tab bar when only one tab
        isHidden = tabs.count <= 1

        guard tabs.count > 1 else { return }

        var previousTrailing: NSLayoutXAxisAnchor = leadingAnchor

        for (index, tab) in tabs.enumerated() {
            let button = NSButton(frame: .zero)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.bezelStyle = .inline
            button.title = ""
            button.tag = index
            button.target = self
            button.action = #selector(tabButtonClicked(_:))

            // Build attributed title with icon + name
            let isSelected = index == selectedIndex
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular),
                .foregroundColor: isSelected ? NSColor.white : NSColor.secondaryLabelColor
            ]
            let icon = NSImage(systemSymbolName: tab.iconSystemName, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "square", accessibilityDescription: nil)!
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: isSelected ? .semibold : .regular)
            let tinted = icon.withSymbolConfiguration(config)!

            button.image = tinted
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " \(tab.title)", attributes: attrs)
            button.contentTintColor = isSelected ? .white : .secondaryLabelColor

            button.wantsLayer = true
            if isSelected {
                button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
                button.layer?.cornerRadius = 6
            }

            addSubview(button)
            tabButtons.append(button)

            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: previousTrailing, constant: index == 0 ? 8 : 2),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.heightAnchor.constraint(equalToConstant: 24),
            ])
            previousTrailing = button.trailingAnchor
        }
    }

    @objc private func tabButtonClicked(_ sender: NSButton) {
        controller?.selectTab(at: sender.tag)
    }
}

// MARK: - PopupContainerView

/// Container view with rounded corners.
private class PopupContainerView: NSView {
    override var isFlipped: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - TerminalPopupPanel

/// NSPanel subclass that intercepts tab-cycling shortcuts.
private class TerminalPopupPanel: NSPanel {
    weak var popupController: TerminalPopupWindowController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Swallow ESC -- popup is dismissed only via prefix+i
    }

    override func keyDown(with event: NSEvent) {
        // Ctrl+Tab / Ctrl+Shift+Tab to cycle popup tabs
        if event.modifierFlags.contains(.control) && event.keyCode == 48 /* Tab */ {
            if event.modifierFlags.contains(.shift) {
                popupController?.selectPreviousTab()
            } else {
                popupController?.selectNextTab()
            }
            return
        }

        // Cmd+W to close current tab
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
            popupController?.closeSelectedTab()
            return
        }

        // Cmd+T to add a new terminal tab
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "t" {
            popupController?.addTerminalTab()
            return
        }

        super.keyDown(with: event)
    }
}
