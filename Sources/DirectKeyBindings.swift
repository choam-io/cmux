import AppKit
import Bonsplit
import Foundation

/// Handles direct (non-prefix) key bindings that intercept events before the terminal.
///
/// Currently implements:
/// - Ctrl+h/j/k/l for pane navigation (vim-tmux-navigator style)
///
/// Future: vim-aware mode will detect vim/nvim as the foreground process and
/// pass Ctrl+hjkl through to the terminal, letting the nvim plugin handle
/// edge-case navigation back to cmux via the CLI.
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
        // These UI elements use Ctrl+J/K for their own navigation.
        if let keyWindow = NSApp.keyWindow {
            if let firstResponder = keyWindow.firstResponder {
                let frType = String(describing: type(of: firstResponder))
                // Skip if a text field, search field, or command palette input has focus
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
            if let direction = ctrlNavigationDirection(keyCode: keyCode) {
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

    private func ctrlNavigationDirection(keyCode: UInt16) -> NavigationDirection? {
        return Self.keyCodeToDirection[keyCode]
    }

    private func handlePaneNavigation(direction: NavigationDirection) -> Bool {
        guard let tabManager = AppDelegate.shared?.tabManager else { return false }

        // Check if there are multiple panes in the current workspace.
        // If only one pane, don't consume the key -- let the terminal handle it.
        if let workspace = tabManager.selectedWorkspace {
            let paneCount = workspace.bonsplitController.allPaneIds.count
            if paneCount <= 1 {
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

    private init() {}
}
