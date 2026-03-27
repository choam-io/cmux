import AppKit
import Combine

/// Hosts a `TerminalSurface` in a floating `NSPanel`, providing tmux
/// `display-popup`-style functionality: a transient, centered terminal
/// overlay that can be summoned with a keybind, interacted with, and
/// dismissed with Escape or the same keybind.
///
/// The shell persists between show/hide cycles (Quake-style). The panel
/// is lazily created on first toggle and reused until explicitly closed
/// or the parent window is deallocated.
@MainActor
final class TerminalPopupWindowController: NSObject, NSWindowDelegate {

    // MARK: - Configuration

    struct Config {
        var widthPercent: CGFloat = 0.8
        var heightPercent: CGFloat = 0.8
        var minWidth: CGFloat = 400
        var minHeight: CGFloat = 300
        var closeOnFocusLoss: Bool = false
        var workingDirectory: String? = nil
        var initialCommand: String? = nil
    }

    // MARK: - State

    private let panel: TerminalPopupPanel
    private var terminalSurface: TerminalSurface?
    private var config: Config
    private weak var parentWindow: NSWindow?
    private var isShowing = false

    /// Track whether the terminal has been initialized (shell spawned).
    private var terminalInitialized = false

    // MARK: - Init

    init(parentWindow: NSWindow?, config: Config = Config()) {
        self.config = config
        self.parentWindow = parentWindow

        let contentRect = Self.computeContentRect(
            parentWindow: parentWindow,
            config: config
        )

        let panel = TerminalPopupPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.identifier = NSUserInterfaceItemIdentifier("cmux.terminal-popup")
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.becomesKeyOnlyIfNeeded = false
        self.panel = panel

        super.init()

        panel.delegate = self
        panel.popupController = self
    }

    // MARK: - Public API

    /// Toggle visibility. If hidden, show and focus. If visible, hide.
    func toggle() {
        if isShowing {
            hide()
        } else {
            show()
        }
    }

    /// Show the popup, creating the terminal if needed.
    func show() {
        if !terminalInitialized {
            initializeTerminal()
        }

        // Reposition to match current parent window geometry
        let contentRect = Self.computeContentRect(
            parentWindow: parentWindow,
            config: config
        )
        panel.setFrame(contentRect, display: false)
        panel.makeKeyAndOrderFront(nil)
        isShowing = true

        // Focus the terminal surface view so it receives keyboard input
        if let surface = terminalSurface {
            panel.makeFirstResponder(surface.focusableView)
        }
    }

    /// Hide the popup without destroying the terminal.
    func hide() {
        panel.orderOut(nil)
        isShowing = false

        // Return focus to parent window
        parentWindow?.makeKeyAndOrderFront(nil)
    }

    /// Close and destroy the popup terminal.
    func close() {
        hide()
        teardownTerminal()
    }

    /// Whether the popup is currently visible.
    var isVisible: Bool { isShowing }

    /// The popup's virtual workspace ID (for surface identification).
    var popupWorkspaceId: UUID? { terminalSurface?.tabId }

    /// Send text to the popup terminal.
    func sendText(_ text: String) {
        terminalSurface?.sendText(text)
    }

    // MARK: - Terminal Lifecycle

    private func initializeTerminal() {
        guard !terminalInitialized else { return }

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

        // The TerminalSurface creates its own GhosttyNSView (surfaceView)
        // and wraps it in a GhosttySurfaceScrollView (hostedView).
        // We put the hostedView into the panel.
        let hostedView = surface.hostedView

        // Create a container with rounded corners
        let container = PopupContainerView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 1.0

        hostedView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: container.topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostedView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        panel.contentView = container
        self.terminalSurface = surface
        self.terminalInitialized = true
    }

    private func teardownTerminal() {
        if let surface = terminalSurface {
            surface.hostedView.removeFromSuperview()
        }
        terminalSurface = nil
        terminalInitialized = false
        panel.contentView = nil
    }

    // MARK: - Geometry

    private static func computeContentRect(
        parentWindow: NSWindow?,
        config: Config
    ) -> NSRect {
        let screen = parentWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let width = max(config.minWidth, visibleFrame.width * config.widthPercent)
        let height = max(config.minHeight, visibleFrame.height * config.heightPercent)

        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.midY - height / 2

        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if config.closeOnFocusLoss && isShowing {
            hide()
        }
    }

    func windowWillClose(_ notification: Notification) {
        isShowing = false
    }

    // MARK: - Escape handling

    func handleEscape() {
        if isShowing {
            hide()
        }
    }
}

// MARK: - TerminalPopupPanel

/// NSPanel subclass that intercepts Escape to dismiss the popup and
/// allows the terminal surface to be the first responder for keyboard input.
private class TerminalPopupPanel: NSPanel {
    weak var popupController: TerminalPopupWindowController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            popupController?.handleEscape()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Escape: dismiss popup
        if event.keyCode == 53 {
            Task { @MainActor in
                popupController?.handleEscape()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - PopupContainerView

/// Container view with rounded corners for the popup terminal.
private class PopupContainerView: NSView {
    override var isFlipped: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
