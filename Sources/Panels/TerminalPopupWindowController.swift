import AppKit
import Combine

/// In-window terminal popup overlay, rendered as an NSPanel child window
/// so it appears above Ghostty's Metal terminal layers.
///
/// Behavior:
/// - Centered within the parent cmux window, not floating on desktop
/// - Moves and resizes with the parent window
/// - Shell persists between show/hide (Quake-style)
/// - Toggle keybind (prefix+i) shows/hides -- ESC passes through to terminal
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

    // MARK: - State

    private var panel: NSPanel?
    private var terminalSurface: TerminalSurface?
    private var config: Config
    private weak var parentWindow: NSWindow?
    private var isShowing = false
    private var terminalInitialized = false
    private var shellExited = false
    private var parentFrameObservation: NSObjectProtocol?
    private var parentMoveObservation: NSObjectProtocol?
    private var childExitObservation: NSObjectProtocol?
    private var containerView: PopupContainerView?

    // MARK: - Init

    init(parentWindow: NSWindow?, config: Config = Config()) {
        self.config = config
        self.parentWindow = parentWindow
        super.init()
    }

    deinit {
        if let obs = parentFrameObservation {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = parentMoveObservation {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = childExitObservation {
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

        // If the terminal's shell has exited (e.g. workmux dashboard quit),
        // tear down and reinitialise so the user gets a fresh command.
        if terminalInitialized && shellExited {
            teardownTerminal()
        }

        if !terminalInitialized {
            initializeTerminal()
        }

        guard let panel else { return }

        // Position within parent window
        let popupFrame = computePopupFrame(in: parentWindow)
        panel.setFrame(popupFrame, display: false)

        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }

        // Animate in
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        isShowing = true

        // Focus the terminal surface view so it receives keyboard input.
        // This must happen AFTER makeKeyAndOrderFront.
        if let surface = terminalSurface {
            panel.makeFirstResponder(surface.focusableView)
        }

        // Track parent window moves/resizes
        startTrackingParentFrame()

        // NOTE: No escape monitor. Popup is dismissed only via the
        // prefix-key toggle (prefix+i). Escape is passed through to
        // the terminal so TUI apps (workmux dashboard, etc.) can use it.
    }

    func hide() {
        guard let panel, isShowing else { return }

        stopTrackingParentFrame()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            // Return focus to parent
            self?.parentWindow?.makeKeyAndOrderFront(nil)
        })

        isShowing = false
    }

    func close() {
        hide()
        teardownTerminal()
    }

    var isVisible: Bool { isShowing }

    // MARK: - Terminal Lifecycle

    private func initializeTerminal() {
        guard !terminalInitialized, let parentWindow else { return }

        // Create the child panel -- use TerminalPopupPanel subclass so
        // canBecomeKey returns true (borderless NSPanel defaults to false).
        // Do NOT use .nonactivatingPanel -- we need keyboard focus.
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
        self.panel = newPanel

        // Create terminal surface
        let popupWorkspaceId = UUID()
        let surface = TerminalSurface(
            tabId: popupWorkspaceId,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: nil,
            workingDirectory: config.workingDirectory,
            initialCommand: config.initialCommand,
            initialEnvironmentOverrides: [:],
            additionalEnvironment: ["CMUX_POPUP": "1"]
        )
        self.terminalSurface = surface

        // Build the visual container: rounded rect with border + shadow
        let container = PopupContainerView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        self.containerView = container

        // Add the terminal's hosted view into the container
        let hostedView = surface.hostedView
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostedView)

        // Add the container to the panel
        container.translatesAutoresizingMaskIntoConstraints = false
        let panelContentView = newPanel.contentView!
        panelContentView.wantsLayer = true
        panelContentView.addSubview(container)

        NSLayoutConstraint.activate([
            // Container has margin for the shadow to render
            container.topAnchor.constraint(equalTo: panelContentView.topAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor, constant: 8),
            container.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor, constant: -8),
            container.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor, constant: -8),

            // Terminal fills the container
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Add a subtle shadow layer behind the container
        let shadowLayer = CALayer()
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.4
        shadowLayer.shadowOffset = CGSize(width: 0, height: -2)
        shadowLayer.shadowRadius = 12
        panelContentView.layer?.insertSublayer(shadowLayer, at: 0)

        self.terminalInitialized = true

        // Listen for child exit so we know to reinit on next show()
        let surfaceId = surface.id
        self.childExitObservation = NotificationCenter.default.addObserver(
            forName: .cmuxChildExited,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let exitedId = notification.userInfo?["surfaceId"] as? UUID,
                  exitedId == surfaceId else { return }
            self.shellExited = true
            // If currently showing, hide immediately -- the shell is dead
            if self.isShowing {
                self.hide()
            }
        }
    }

    private func teardownTerminal() {
        stopTrackingParentFrame()
        if let obs = childExitObservation {
            NotificationCenter.default.removeObserver(obs)
            childExitObservation = nil
        }
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        containerView?.removeFromSuperview()
        containerView = nil
        terminalSurface = nil
        panel = nil
        terminalInitialized = false
        shellExited = false
        isShowing = false
    }

    // MARK: - Geometry

    private func computePopupFrame(in parentWindow: NSWindow) -> NSRect {
        let parentFrame = parentWindow.frame
        let parentContent = parentWindow.contentRect(forFrameRect: parentFrame)

        let width = max(config.minWidth, parentContent.width * config.widthPercent)
        let height = max(config.minHeight, parentContent.height * config.heightPercent)

        // Center within the parent window's content area
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
        // Don't auto-hide on focus loss -- the user might be clicking on
        // the parent window or another app. Only the prefix-key toggle dismisses.
    }

}

// MARK: - PopupContainerView

/// Container view with rounded corners. updateLayer keeps border in sync with appearance.
private class PopupContainerView: NSView {
    override var isFlipped: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

// MARK: - TerminalPopupPanel

/// NSPanel subclass that can become key window (borderless panels can't by default).
/// Escape is NOT intercepted -- it passes through to the terminal.
/// The popup is dismissed only via the prefix-key toggle.
private class TerminalPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Swallow ESC so it passes through to the terminal (ratatui TUIs, etc.)
        // instead of triggering NSWindow's default performClose:.
        // The popup is dismissed only via the prefix-key toggle (prefix+i).
    }
}
