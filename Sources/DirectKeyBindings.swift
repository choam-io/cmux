import AppKit
import Bonsplit
import Darwin
import Foundation

/// Handles direct (non-prefix) key bindings that intercept events before the terminal.
///
/// Implements:
/// - Ctrl+h/j/k/l for pane navigation (vim-tmux-navigator style)
///
/// When vim-aware mode is enabled, Ctrl+hjkl are passed through to the terminal
/// if the focused surface's foreground process is vim/nvim, letting the nvim plugin
/// handle edge-case navigation back to cmux via the CLI.
@MainActor
final class DirectKeyBindings {
    static let shared = DirectKeyBindings()

    // MARK: - Configuration Keys

    private static let enabledKey = "directKeyBindings.enabled"
    private static let vimAwareKey = "directKeyBindings.vimAware"

    // MARK: - Configuration

    /// Whether direct key bindings are enabled (default: true when prefix key mode is on)
    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
                return PrefixKeyMode.shared.isEnabled
            }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
        }
    }

    /// Whether to detect vim/nvim and pass Ctrl+hjkl through to the terminal.
    /// When false (default), Ctrl+hjkl always navigate cmux panes.
    /// When true, if vim is the foreground process, keys pass through so the
    /// nvim plugin can handle edge navigation via the cmux CLI.
    var isVimAware: Bool {
        get { UserDefaults.standard.bool(forKey: Self.vimAwareKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.vimAwareKey) }
    }

    // MARK: - Event Handling

    /// Call from handleCustomShortcut. Returns true if the event was consumed.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        guard event.type == .keyDown else { return false }

        // Don't steal keys from the command palette, address bar, or other text inputs.
        if let keyWindow = NSApp.keyWindow {
            if let firstResponder = keyWindow.firstResponder {
                let frType = String(describing: type(of: firstResponder))
                if firstResponder is NSTextView ||
                   firstResponder is NSTextField ||
                   frType.contains("CommandPalette") ||
                   frType.contains("AddressBar") ||
                   frType.contains("Omnibar") ||
                   frType.contains("SearchField") {
                    return false
                }
            }
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        let keyCode = event.keyCode

        // Ctrl+h/j/k/l (control only, no cmd/opt) -> pane navigation
        if flags == [.control] {
            if let direction = Self.keyCodeToDirection[keyCode] {
                return handlePaneNavigation(direction: direction)
            }
        }

        return false
    }

    // MARK: - Ctrl+h/j/k/l Navigation

    private static let keyCodeToDirection: [UInt16: NavigationDirection] = [
        4:  .left,   // h
        38: .down,   // j
        40: .up,     // k
        37: .right,  // l
    ]

    private func handlePaneNavigation(direction: NavigationDirection) -> Bool {
        guard let tabManager = AppDelegate.shared?.tabManager else { return false }

        // If only one pane, don't consume the key
        if let workspace = tabManager.selectedWorkspace {
            let paneCount = workspace.bonsplitController.allPaneIds.count
            if paneCount <= 1 {
                return false
            }
        }

        // If vim-aware mode is on, check the foreground process
        if isVimAware {
            if isFocusedSurfaceRunningVim(tabManager: tabManager) {
                // Pass through to terminal -- nvim plugin handles edge navigation
                return false
            }
        }

        tabManager.movePaneFocus(direction: direction)

        #if DEBUG
        let dirName: String
        switch direction {
        case .left: dirName = "left"
        case .right: dirName = "right"
        case .up: dirName = "up"
        case .down: dirName = "down"
        }
        dlog("directKeys.navigate: \(dirName)")
        #endif

        return true
    }

    // MARK: - Vim Detection

    /// Cache: surface UUID -> shell PID. Rebuilt when stale.
    private var surfacePidCache: [String: pid_t] = [:]
    private var cacheTimestamp: Date = .distantPast
    private static let cacheTTL: TimeInterval = 2.0

    /// Check if the focused terminal surface's foreground process is vim/nvim.
    private func isFocusedSurfaceRunningVim(tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.selectedWorkspace,
              let focusedPaneId = workspace.bonsplitController.focusedPaneId,
              let selectedTab = workspace.bonsplitController.selectedTab(inPane: focusedPaneId) else {
            return false
        }

        guard let panel = workspace.panel(for: selectedTab.id),
              let terminalPanel = panel as? TerminalPanel else {
            return false
        }

        let surfaceIdStr = terminalPanel.surface.id.uuidString

        refreshCacheIfNeeded()
        guard let shellPid = surfacePidCache[surfaceIdStr] else {
            return false
        }

        return ForegroundProcessDetector.isVim(shellPid: shellPid)
    }

    /// Rebuild the surface ID -> shell PID cache if stale.
    private func refreshCacheIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(cacheTimestamp) >= Self.cacheTTL else { return }
        cacheTimestamp = now
        surfacePidCache = ForegroundProcessDetector.buildSurfacePidMap(parentPid: getpid())
    }

    private init() {}

    // MARK: - Debug Logging

    /// Log to /tmp/nsmux-directkeys.log when directKeyBindings.debug is enabled.
    /// Enable with: defaults write io.choam.nsmux directKeyBindings.debug -bool true
    static func debugLog(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "directKeyBindings.debug") else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [DirectKeyBindings] \(message)\n"
        if let data = line.data(using: .utf8),
           let handle = FileHandle(forWritingAtPath: "/tmp/nsmux-directkeys.log") {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: "/tmp/nsmux-directkeys.log", contents: line.data(using: .utf8))
        }
    }
}
