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

    /// Process names recognized as vim (matches vim-tmux-navigator's regex)
    private static let vimProcessNames: Set<String> = [
        "vim", "nvim", "vimdiff", "nvimdiff",
        "view", "nview",
        "gvim", "gview",
        "lvim", "vimx",
    ]

    /// Cache: surface UUID -> shell PID. Rebuilt when stale.
    private var surfacePidCache: [String: pid_t] = [:]
    private var cacheTimestamp: Date = .distantPast
    private static let cacheTTL: TimeInterval = 2.0 // Rebuild every 2s max

    /// Check if the focused terminal surface's foreground process is vim/nvim.
    private func isFocusedSurfaceRunningVim(tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.selectedWorkspace,
              let focusedPaneId = workspace.bonsplitController.focusedPaneId,
              let selectedTab = workspace.bonsplitController.selectedTab(inPane: focusedPaneId) else {
            return false
        }

        // Get the terminal panel for the focused surface
        guard let panel = workspace.panel(for: selectedTab.id),
              let terminalPanel = panel as? TerminalPanel else {
            return false // Not a terminal (e.g. browser panel)
        }

        let surfaceIdStr = terminalPanel.surface.id.uuidString

        // Look up the shell PID for this surface
        refreshCacheIfNeeded()
        guard let shellPid = surfacePidCache[surfaceIdStr] else {
            return false
        }

        // Walk from shell to leaf process and check if it's vim
        let leafPid = Self.findLeafProcess(parentPid: shellPid)
        guard let processPath = Self.processPath(for: leafPid) else { return false }
        let baseName = (processPath as NSString).lastPathComponent.lowercased()

        return Self.vimProcessNames.contains(baseName)
    }

    /// Rebuild the surface ID -> shell PID cache if stale.
    private func refreshCacheIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(cacheTimestamp) >= Self.cacheTTL else { return }
        cacheTimestamp = now

        let myPid = getpid()
        var childPids = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(myPid, &childPids, Int32(childPids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else {
            surfacePidCache.removeAll()
            return
        }

        var newCache: [String: pid_t] = [:]
        let childCount = min(Int(count), childPids.count)
        for i in 0..<childCount {
            let pid = childPids[i]
            guard pid > 0 else { continue }
            if let env = Self.readProcessEnvironment(pid: pid),
               let surfaceId = env["CMUX_SURFACE_ID"] {
                newCache[surfaceId] = pid
            }
        }
        surfacePidCache = newCache
    }

    // MARK: - Process Utilities

    /// Walk child processes to find the leaf (foreground) process.
    private static func findLeafProcess(parentPid: pid_t) -> pid_t {
        var current = parentPid
        for _ in 0..<20 {
            var childPids = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(current, &childPids, Int32(childPids.count * MemoryLayout<pid_t>.size))
            if count <= 0 {
                return current
            }
            let childCount = min(Int(count), childPids.count)
            if childCount == 0 {
                return current
            }
            current = childPids[0]
        }
        return current
    }

    /// Get the executable path for a PID.
    private static func processPath(for pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE = 4*MAXPATHLEN = 4096
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Read environment variables of a process via KERN_PROCARGS2.
    /// Works for child processes of the current process.
    private static func readProcessEnvironment(pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let data = Data(bytes: buffer, count: size)
        guard data.count >= 4 else { return nil }

        // First 4 bytes: argc
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }

        // Skip past executable path
        var offset = 4
        while offset < data.count && data[offset] != 0 { offset += 1 }
        // Skip null padding between exec path and first arg
        while offset < data.count && data[offset] == 0 { offset += 1 }
        // Skip argc args
        var argsSkipped: Int32 = 0
        while argsSkipped < argc && offset < data.count {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
            argsSkipped += 1
        }

        // Parse environment variables (null-separated KEY=VALUE pairs)
        var env: [String: String] = [:]
        while offset < data.count {
            var end = offset
            while end < data.count && data[end] != 0 { end += 1 }
            if end == offset { break }
            if let str = String(data: data[offset..<end], encoding: .utf8),
               let eqIdx = str.firstIndex(of: "=") {
                let key = String(str[str.startIndex..<eqIdx])
                let val = String(str[str.index(after: eqIdx)...])
                env[key] = val
            }
            offset = end + 1
        }
        return env
    }

    private init() {}
}
