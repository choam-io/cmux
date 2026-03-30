import AppKit
import Bonsplit
import Carbon.HIToolbox
import Combine
import WebKit

// MARK: - Carbon Global Hot Key Callback

/// C-compatible callback for the Carbon RegisterEventHotKey system.
/// Fires on the main thread regardless of which app is focused.
private func popupCarbonHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }

    DispatchQueue.main.async {
        TerminalController.shared.togglePopup(parentWindow: nil)
    }

    return noErr
}

/// Guake-style global dropdown terminal with tabbed panels.
/// Drops down from the top of the screen, toggled via a global hotkey.
/// Panels can be terminals, browsers, or any view.
///
/// Behavior:
/// - Full-width dropdown from the top of the active screen
/// - Global hotkey (Cmd+') works from any app
/// - Panels persist between show/hide
/// - Float above all windows
/// - Slight transparency + slide animation
/// - Ctrl+Tab / Ctrl+Shift+Tab cycles tabs
/// - Cmd+T new terminal, Cmd+Shift+T new browser, Cmd+W close tab
/// - prefix+0..9 selects tab by index
@MainActor
final class TerminalPopupWindowController: NSObject, NSWindowDelegate {

    // MARK: - Configuration

    struct Config {
        /// Height as percentage of screen height (0.0 - 1.0)
        var heightPercent: CGFloat = 1.0
        var minHeight: CGFloat = 300
        var workingDirectory: String? = nil
        var initialCommand: String? = nil
        /// Background transparency (0.0 = fully transparent, 1.0 = opaque)
        var backgroundOpacity: CGFloat = 1.0
    }

    // MARK: - Popup Tab

    enum PopupTabContent {
        case terminal(surface: TerminalSurface)
        case browser(container: PopupBrowserContainer)
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
            case .browser(let container):
                return container
            }
        }

        /// The view to make first responder for keyboard input.
        var focusableView: NSView? {
            switch content {
            case .terminal(let surface):
                return surface.focusableView
            case .browser(let container):
                return container.addressField
            }
        }

        init(title: String, iconSystemName: String, content: PopupTabContent, pinned: Bool = false) {
            self.title = title
            self.iconSystemName = iconSystemName
            self.content = content
            self.pinned = pinned
        }

        /// Pinned tabs can't be closed with Cmd+W.
        var pinned: Bool
    }

    // MARK: - State

    private var panel: NSPanel?
    private(set) var tabs: [PopupTab] = []
    private(set) var selectedTabIndex: Int = 0
    private var config: Config
    private var isShowing = false
    private var panelInitialized = false
    private var childExitObservations: [UUID: NSObjectProtocol] = [:]
    private var containerView: PopupContainerView?
    private var tabBarView: PopupTabBarView?
    private var contentArea: NSView?
    private var browserTitleObservers: [UUID: NSKeyValueObservation] = [:]
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandlerRef: EventHandlerRef?

    var selectedTab: PopupTab? {
        guard selectedTabIndex >= 0, selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    // MARK: - Init

    init(config: Config = Config()) {
        self.config = config
        super.init()
        installCarbonHotKey()
    }

    deinit {
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = carbonEventHandlerRef {
            RemoveEventHandler(ref)
        }
        for obs in childExitObservations.values {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Global Hotkey (Cmd+') via Carbon RegisterEventHotKey

    /// Registers a system-wide hot key using Carbon's RegisterEventHotKey.
    /// Unlike NSEvent.addGlobalMonitorForEvents, this works reliably from
    /// any application without requiring accessibility permissions.
    private func installCarbonHotKey() {
        // Install a Carbon event handler for kEventHotKeyPressed
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            popupCarbonHotKeyHandler,
            1,
            &eventType,
            nil,  // userData not needed -- callback uses TerminalController.shared
            &carbonEventHandlerRef
        )

        guard handlerStatus == noErr else {
            #if DEBUG
            dlog("popup.hotkey: failed to install Carbon event handler: \(handlerStatus)")
            #endif
            return
        }

        // Register Cmd+' (virtual key code 39 = apostrophe, cmdKey modifier)
        // Signature "CMUX" as OSType
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x434D5558),  // "CMUX"
            id: 1
        )

        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_Quote),  // key code 39
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )

        #if DEBUG
        if registerStatus == noErr {
            dlog("popup.hotkey: registered Carbon hot key Cmd+' (kVK_ANSI_Quote)")
        } else {
            dlog("popup.hotkey: failed to register Carbon hot key: \(registerStatus)")
        }
        #endif
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
        if !panelInitialized {
            initializePanel()
        }

        // Ensure at least one tab exists (default terminal, pinned)
        if tabs.isEmpty {
            addTerminalTab(
                command: config.initialCommand,
                cwd: config.workingDirectory,
                pinned: true,
                select: true
            )
        }

        guard let panel else { return }

        // Position at top of screen
        let frame = computeDropdownFrame()
        // Start off-screen (above top) for slide animation
        let startFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y + frame.height,
            width: frame.width,
            height: frame.height
        )
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 1
        // Use orderFrontRegardless + makeKey so the popup appears and accepts
        // keyboard input without activating the app (which would cause Aerospace
        // to switch to the nsmux workspace).
        panel.orderFrontRegardless()
        panel.makeKey()

        // Slide down animation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }

        isShowing = true
        focusSelectedTab()
    }

    func hide() {
        guard let panel, isShowing else { return }

        let frame = panel.frame
        let offscreenFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y + frame.height,
            width: frame.width,
            height: frame.height
        )

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(offscreenFrame, display: true)
        }, completionHandler: {
            panel.orderOut(nil)
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
        pinned: Bool = false,
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
            content: .terminal(surface: surface),
            pinned: pinned
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
        let container = PopupBrowserContainer(url: url)

        let tabTitle = title ?? (url.absoluteString == "about:blank" ? "New tab" : url.host ?? "Browser")
        let tab = PopupTab(
            title: tabTitle,
            iconSystemName: "globe",
            content: .browser(container: container)
        )

        // Observe title changes from the web page
        let tabId = tab.id
        let observer = container.webView.observe(\.title, options: [.new]) { [weak self, weak tab] _, change in
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

        // Focus address bar for blank tabs
        if url.absoluteString == "about:blank", select {
            DispatchQueue.main.async { [weak self] in
                self?.panel?.makeFirstResponder(container.addressField)
                container.addressField.selectText(nil)
            }
        }

        return tab
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let tab = tabs[index]

        // Pinned tabs can't be closed
        guard !tab.pinned else { return }

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
        guard !panelInitialized else { return }

        let frame = computeDropdownFrame()
        let newPanel = TerminalPopupPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.identifier = NSUserInterfaceItemIdentifier("cmux.terminal-popup")
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.backgroundColor = .clear
        newPanel.level = .init(NSWindow.Level.mainMenu.rawValue + 1)
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.hidesOnDeactivate = false
        newPanel.delegate = self
        newPanel.popupController = self
        // Allow the panel to become key even though it's nonactivating
        newPanel.becomesKeyOnlyIfNeeded = false
        self.panel = newPanel

        // Build visual container
        let container = PopupContainerView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 0
        container.layer?.cornerCurve = .continuous
        // Round only bottom corners
        container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                          .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
            // No margin -- full bleed to panel edges
            container.topAnchor.constraint(equalTo: panelContentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor),

            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 32),

            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Bottom edge shadow
        let shadowLayer = CALayer()
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.5
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4)
        shadowLayer.shadowRadius = 16
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
            panel.makeKey()
            panel.makeFirstResponder(focusable)
        }
    }

    // MARK: - Shell Exit

    private func handleTabShellExit(tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]

        // Clean up the old exit observer
        if let obs = childExitObservations.removeValue(forKey: tabId) {
            NotificationCenter.default.removeObserver(obs)
        }

        // Pinned tabs restart automatically
        if tab.pinned {
            restartPinnedTab(at: index)
            return
        }

        // Unpinned: close or hide
        if tabs.count == 1 {
            hide()
            tabs.removeAll()
        } else {
            closeTab(at: index)
        }
    }

    private func restartPinnedTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        let oldTab = tabs[index]
        guard case .terminal = oldTab.content else { return }

        // Remove old content view
        oldTab.contentView.removeFromSuperview()

        // Create fresh surface with the same command
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: nil,
            workingDirectory: config.workingDirectory,
            initialCommand: config.initialCommand,
            initialEnvironmentOverrides: [:],
            additionalEnvironment: ["CMUX_POPUP": "1"]
        )

        let newTab = PopupTab(
            title: oldTab.title,
            iconSystemName: oldTab.iconSystemName,
            content: .terminal(surface: surface),
            pinned: true
        )

        // Watch for exit on the new surface
        let surfaceId = surface.id
        let newTabId = newTab.id
        let obs = NotificationCenter.default.addObserver(
            forName: .cmuxChildExited,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let exitedId = notification.userInfo?["surfaceId"] as? UUID,
                  exitedId == surfaceId else { return }
            self.handleTabShellExit(tabId: newTabId)
        }
        childExitObservations[newTabId] = obs

        // Swap in place
        tabs[index] = newTab

        // If this tab is selected, show it
        if selectedTabIndex == index {
            showTab(at: index)
        }

        tabBarView?.refresh(tabs: tabs, selectedIndex: selectedTabIndex)
    }

    // MARK: - Teardown

    private func teardownAll() {
        for obs in childExitObservations.values {
            NotificationCenter.default.removeObserver(obs)
        }
        childExitObservations.removeAll()
        browserTitleObservers.removeAll()
        if let panel {
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

    private func computeDropdownFrame() -> NSRect {
        // Use the screen with the mouse cursor (or main screen)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!

        let screenFrame = screen.frame

        // Fullscreen: cover the entire screen including menu bar area
        let height = max(config.minHeight, screenFrame.height * config.heightPercent)
        let width = screenFrame.width
        let x = screenFrame.minX
        let y = screenFrame.maxY - height

        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Don't auto-hide on focus loss -- user must toggle with hotkey
    }
}

// MARK: - Tab Bar View

/// Minimal tab bar: horizontal row of pill-shaped tab buttons with index numbers.
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

        // Always show the tab bar so the user knows tabs exist
        isHidden = false

        guard !tabs.isEmpty else { return }

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
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: isSelected ? .semibold : .regular)
            let tinted = icon.withSymbolConfiguration(symbolConfig)!

            button.image = tinted
            button.imagePosition = .imageLeading
            // Show index number + title: "0 dashboard", "1 Terminal"
            let indexLabel = "\(index) "
            let indexAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: isSelected ? NSColor.white.withAlphaComponent(0.6) : NSColor.tertiaryLabelColor
            ]
            let labelStr = NSMutableAttributedString(string: indexLabel, attributes: indexAttrs)
            labelStr.append(NSAttributedString(string: tab.title, attributes: attrs))
            button.attributedTitle = labelStr
            button.contentTintColor = isSelected ? .white : .secondaryLabelColor

            button.wantsLayer = true
            if isSelected {
                button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
                button.layer?.cornerRadius = 6
            }

            addSubview(button)
            tabButtons.append(button)

            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: previousTrailing, constant: index == 0 ? 8 : 6),
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

// MARK: - PopupBrowserContainer

/// Browser view with address bar + back/forward/reload + WKWebView.
@MainActor
final class PopupBrowserContainer: NSView, NSTextFieldDelegate {
    let webView: WKWebView
    let addressField: NSTextField
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let reloadButton: NSButton
    private let toolbar: NSView
    private var urlObserver: NSKeyValueObservation?

    init(url: URL) {
        let wv = WKWebView(frame: .zero)
        self.webView = wv

        // Address bar
        let field = NSTextField(frame: .zero)
        field.placeholderString = "Search or enter URL"
        field.font = .systemFont(ofSize: 12)
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.cell?.sendsActionOnEndEditing = false
        field.stringValue = url.absoluteString == "about:blank" ? "" : url.absoluteString
        self.addressField = field

        // Nav buttons
        let back = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!, target: nil, action: nil)
        back.isBordered = false
        back.bezelStyle = .inline
        back.imageScaling = .scaleProportionallyDown
        back.setButtonType(.momentaryPushIn)
        self.backButton = back

        let forward = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!, target: nil, action: nil)
        forward.isBordered = false
        forward.bezelStyle = .inline
        forward.imageScaling = .scaleProportionallyDown
        forward.setButtonType(.momentaryPushIn)
        self.forwardButton = forward

        let reload = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")!, target: nil, action: nil)
        reload.isBordered = false
        reload.bezelStyle = .inline
        reload.imageScaling = .scaleProportionallyDown
        reload.setButtonType(.momentaryPushIn)
        self.reloadButton = reload

        // Toolbar container
        let bar = NSView(frame: .zero)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        self.toolbar = bar

        super.init(frame: .zero)
        wantsLayer = true

        // Wire targets
        field.delegate = self
        field.target = self
        field.action = #selector(addressFieldSubmitted)
        back.target = self
        back.action = #selector(goBack)
        forward.target = self
        forward.action = #selector(goForward)
        reload.target = self
        reload.action = #selector(doReload)

        // Layout
        for v in [bar, wv] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in [back, forward, reload, field] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }

        let toolbarHeight: CGFloat = 36
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: toolbarHeight),

            back.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            back.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 24),
            back.heightAnchor.constraint(equalToConstant: 24),

            forward.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
            forward.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            forward.widthAnchor.constraint(equalToConstant: 24),
            forward.heightAnchor.constraint(equalToConstant: 24),

            reload.leadingAnchor.constraint(equalTo: forward.trailingAnchor, constant: 4),
            reload.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reload.widthAnchor.constraint(equalToConstant: 24),
            reload.heightAnchor.constraint(equalToConstant: 24),

            field.leadingAnchor.constraint(equalTo: reload.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 24),

            wv.topAnchor.constraint(equalTo: bar.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Observe URL changes to update address bar
        urlObserver = wv.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            if let newURL = change.newValue ?? nil {
                DispatchQueue.main.async {
                    self.addressField.stringValue = newURL.absoluteString
                }
            }
        }

        // Load initial URL
        if url.absoluteString != "about:blank" {
            wv.load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    @objc private func addressFieldSubmitted() {
        var text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") {
            // If it looks like a URL, add https://. Otherwise treat as search.
            if text.contains(".") && !text.contains(" ") {
                text = "https://" + text
            } else {
                text = "https://www.google.com/search?q=" + (text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text)
            }
        }
        guard let url = URL(string: text) else { return }
        webView.load(URLRequest(url: url))
        // Return focus to webview after navigation
        window?.makeFirstResponder(webView)
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func doReload() { webView.reload() }

    override func updateLayer() {
        super.updateLayer()
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

// MARK: - PopupContainerView

/// Container view for the dropdown.
private class PopupContainerView: NSView {
    override var isFlipped: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

// MARK: - TerminalPopupPanel

/// NSPanel subclass for the dropdown. Intercepts tab-cycling shortcuts via sendEvent.
private class TerminalPopupPanel: NSPanel {
    weak var popupController: TerminalPopupWindowController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Swallow ESC -- popup is dismissed only via hotkey
    }

    override func sendEvent(_ event: NSEvent) {
        // Intercept key equivalents before they reach the terminal view
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCmd = flags.contains(.command)
            let hasCtrl = flags.contains(.control)
            let hasShift = flags.contains(.shift)
            let hasOpt = flags.contains(.option)

            // Ctrl+Tab / Ctrl+Shift+Tab to cycle popup tabs
            if hasCtrl && event.keyCode == 48 /* Tab */ {
                if hasShift {
                    popupController?.selectPreviousTab()
                } else {
                    popupController?.selectNextTab()
                }
                return
            }

            // Cmd+W to close current tab (no other modifiers)
            if hasCmd && !hasCtrl && !hasOpt && event.charactersIgnoringModifiers == "w" {
                popupController?.closeSelectedTab()
                return
            }

            // Cmd+T to add a new terminal tab (no other modifiers)
            if hasCmd && !hasCtrl && !hasOpt && event.charactersIgnoringModifiers?.lowercased() == "t" {
                if hasShift {
                    TerminalController.shared.popupPromptBrowserTab()
                } else {
                    popupController?.addTerminalTab()
                }
                return
            }
        }

        super.sendEvent(event)
    }
}
