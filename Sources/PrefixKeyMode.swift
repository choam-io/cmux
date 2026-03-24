import AppKit
import Bonsplit
import Foundation

/// Manages tmux-style prefix key mode for keyboard shortcuts.
/// When enabled, users press a prefix key (default: Ctrl+A) followed by an action key.
final class PrefixKeyMode {
    static let shared = PrefixKeyMode()
    
    /// Notification posted when prefix mode state changes (for UI indicators)
    static let stateDidChangeNotification = Notification.Name("cmux.prefixKeyMode.stateDidChange")
    
    /// Notification posted when a prefix action should be performed
    static let performActionNotification = Notification.Name("cmux.prefixKeyMode.performAction")
    
    // MARK: - Configuration Keys
    
    private static let enabledKey = "prefixKeyMode.enabled"
    private static let prefixKeyKey = "prefixKeyMode.prefixKey"
    private static let timeoutKey = "prefixKeyMode.timeout"
    
    // MARK: - State
    
    private(set) var isPrefixPending = false
    private var timeoutTimer: Timer?
    
    // MARK: - Configuration
    
    /// Whether prefix key mode is enabled
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { 
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue {
                cancelPrefixMode()
            }
        }
    }
    
    /// The prefix key (default: Ctrl+A, like tmux)
    var prefixKey: StoredShortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.prefixKeyKey),
                  let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
                // Default: Ctrl+A (tmux default)
                return StoredShortcut(key: "a", command: false, shift: false, option: false, control: true)
            }
            return shortcut
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.prefixKeyKey)
            }
        }
    }
    
    /// Timeout in seconds before prefix mode cancels (default: 1.0)
    var timeout: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: Self.timeoutKey)
            return value > 0 ? value : 2.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.timeoutKey)
        }
    }
    
    // MARK: - Prefix Key Bindings
    
    /// Maps single keys (after prefix) to actions
    /// These are tmux-inspired defaults that match common muscle memory
    static let defaultBindings: [String: KeyboardShortcutSettings.Action] = [
        // Splits (tmux-style)
        "v": .splitRight,      // prefix+v = split vertical (right)
        "s": .splitDown,       // prefix+s = split horizontal (down) - vim style
        "-": .splitDown,       // prefix+- = split horizontal (down)
        "%": .splitRight,      // prefix+% = split vertical (tmux style)
        "\"": .splitDown,      // prefix+" = split horizontal (tmux style)
        
        // Pane navigation - vim-style hjkl
        "h": .focusLeft,
        "j": .focusDown,
        "k": .focusUp,
        "l": .focusRight,
        
        // Arrow keys also work
        "←": .focusLeft,
        "→": .focusRight,
        "↑": .focusUp,
        "↓": .focusDown,
        
        // Pane management
        "x": .closeWorkspace,  // prefix+x = close pane (tmux: kill-pane)
        "z": .toggleSplitZoom, // prefix+z = zoom pane
        
        // Copy mode
        "[": .toggleTerminalCopyMode,  // prefix+[ = copy mode (tmux style)
        
        // Workspace/window navigation
        "n": .nextSidebarTab,  // prefix+n = next workspace
        "p": .prevSidebarTab,  // prefix+p = previous workspace
        "c": .newTab,          // prefix+c = new workspace (tmux: new-window)
        
        // Surface/tab navigation
        "o": .nextSurface,     // prefix+o = next pane (tmux style)
        
        // Rename
        ",": .renameWorkspace, // prefix+, = rename (tmux style)
        
        // Sidebar
        "b": .toggleSidebar,   // prefix+b = toggle sidebar
        
        // Misc
        "t": .newSurface,      // prefix+t = new tab/surface
        "?": .triggerFlash,    // prefix+? = flash to find cursor
    ]
    
    // MARK: - Event Handling
    
    /// Call this from the key event handler. Returns true if the event was consumed.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        
        // Check if this is the prefix key
        if isPrefixKeyPress(event) {
            if isPrefixPending {
                // Double-press prefix = send prefix key to terminal
                cancelPrefixMode()
                return false // Let it through
            } else {
                enterPrefixMode()
                return true // Consume the prefix key
            }
        }
        
        // If we're in prefix mode, handle the action key
        if isPrefixPending {
            return handleActionKey(event)
        }
        
        return false
    }
    
    private func isPrefixKeyPress(_ event: NSEvent) -> Bool {
        guard let eventShortcut = StoredShortcut.from(event: event) else { return false }
        let prefix = prefixKey
        
        return eventShortcut.key.lowercased() == prefix.key.lowercased() &&
               eventShortcut.command == prefix.command &&
               eventShortcut.shift == prefix.shift &&
               eventShortcut.option == prefix.option &&
               eventShortcut.control == prefix.control
    }
    
    private func handleActionKey(_ event: NSEvent) -> Bool {
        defer { cancelPrefixMode() }
        
        // Escape cancels prefix mode
        if event.keyCode == 53 {
            return true
        }
        
        // Get the key character
        guard let key = actionKey(from: event) else {
            return false
        }
        
        // Handle number keys for workspace selection (1-9)
        if let digit = Int(key), (1...9).contains(digit) {
            postWorkspaceSelection(digit)
            return true
        }
        
        // Look up the action
        if let action = Self.defaultBindings[key] ?? Self.defaultBindings[key.lowercased()] {
            postAction(action)
            return true
        }
        
        return false
    }
    
    private func actionKey(from event: NSEvent) -> String? {
        // Handle special keys by keyCode
        switch event.keyCode {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 33: return "["
        case 30: return "]"
        case 27: return "-"
        case 43: return ","
        case 47: return "."
        case 44: return "/"
        case 42: return "\\"
        default: break
        }
        
        // Handle shifted characters for % and "
        if let chars = event.characters, !chars.isEmpty {
            return chars
        }
        
        // Fall back to unmodified characters
        return event.charactersIgnoringModifiers
    }
    
    private func postAction(_ action: KeyboardShortcutSettings.Action) {
        NotificationCenter.default.post(
            name: Self.performActionNotification,
            object: nil,
            userInfo: ["actionRawValue": action.rawValue]
        )
        #if DEBUG
        dlog("prefix.action: \(action.rawValue)")
        #endif
    }
    
    private func postWorkspaceSelection(_ number: Int) {
        NotificationCenter.default.post(
            name: Self.performActionNotification,
            object: nil,
            userInfo: ["selectWorkspace": number]
        )
        #if DEBUG
        dlog("prefix.selectWorkspace: \(number)")
        #endif
    }
    
    // MARK: - Prefix Mode State
    
    private func enterPrefixMode() {
        isPrefixPending = true
        
        // Start timeout timer
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.cancelPrefixMode()
        }
        
        postStateChange()
        
        #if DEBUG
        dlog("prefix.enter: awaiting action key (timeout=\(timeout)s)")
        #endif
    }
    
    func cancelPrefixMode() {
        guard isPrefixPending else { return }
        
        isPrefixPending = false
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        
        postStateChange()
        
        #if DEBUG
        dlog("prefix.cancel: mode ended")
        #endif
    }
    
    private func postStateChange() {
        NotificationCenter.default.post(
            name: Self.stateDidChangeNotification,
            object: nil,
            userInfo: ["isPrefixPending": isPrefixPending]
        )
    }
    
    private init() {}
}
