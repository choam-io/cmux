import AppKit
import Bonsplit
import Foundation

// MARK: - Prefix Key Mode Integration

extension AppDelegate {
    
    /// Call this at the start of handleCustomShortcut to intercept prefix key events.
    /// Returns true if the event was handled by prefix key mode.
    func handlePrefixKeyMode(event: NSEvent) -> Bool {
        return PrefixKeyMode.shared.handleKeyEvent(event)
    }
    
    /// Install the prefix key action observer. Call this from applicationDidFinishLaunching.
    func installPrefixKeyModeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePrefixKeyAction(_:)),
            name: PrefixKeyMode.performActionNotification,
            object: nil
        )
    }
    
    @objc private func handlePrefixKeyAction(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        
        // Handle action dispatch
        if let rawValue = userInfo["actionRawValue"] as? String,
           let action = KeyboardShortcutSettings.Action(rawValue: rawValue) {
            performPrefixAction(action)
        }
        
        // Handle workspace selection by number
        if let number = userInfo["selectWorkspace"] as? Int {
            tabManager?.selectTab(at: number - 1) // 0-indexed
        }
    }
    
    private func performPrefixAction(_ action: KeyboardShortcutSettings.Action) {
        let preferredWindow = NSApp.keyWindow ?? NSApp.mainWindow
        
        switch action {
        // Pane focus
        case .focusLeft:
            tabManager?.movePaneFocus(direction: .left)
        case .focusRight:
            tabManager?.movePaneFocus(direction: .right)
        case .focusUp:
            tabManager?.movePaneFocus(direction: .up)
        case .focusDown:
            tabManager?.movePaneFocus(direction: .down)
            
        // Splits
        case .splitRight:
            _ = performSplitShortcut(direction: .right, preferredWindow: preferredWindow)
        case .splitDown:
            _ = performSplitShortcut(direction: .down, preferredWindow: preferredWindow)
        case .splitBrowserRight:
            _ = performBrowserSplitShortcut(direction: .right)
        case .splitBrowserDown:
            _ = performBrowserSplitShortcut(direction: .down)
            
        // Zoom
        case .toggleSplitZoom:
            _ = tabManager?.toggleFocusedSplitZoom()
            
        // Workspaces
        case .newTab:
            tabManager?.addWorkspace()
        case .closeWorkspace:
            tabManager?.closeCurrentWorkspaceWithConfirmation()
        case .nextSidebarTab:
            tabManager?.selectNextTab()
        case .prevSidebarTab:
            tabManager?.selectPreviousTab()
        case .renameWorkspace:
            requestCommandPaletteRenameWorkspace(preferredWindow: preferredWindow, source: "prefix.renameWorkspace")
            
        // Surfaces
        case .newSurface:
            _ = tabManager?.createSplit(direction: .right)
        case .nextSurface:
            tabManager?.selectNextSurface()
        case .prevSurface:
            tabManager?.selectPreviousSurface()
        case .renameTab:
            requestCommandPaletteRenameTab(preferredWindow: preferredWindow, source: "prefix.renameTab")
            
        // Copy mode
        case .toggleTerminalCopyMode:
            _ = tabManager?.toggleFocusedTerminalCopyMode()
            
        // Sidebar
        case .toggleSidebar:
            // Toggle sidebar - this is handled by SidebarState
            NotificationCenter.default.post(name: .init("cmux.toggleSidebar"), object: nil)
            
        // Browser
        case .openBrowser:
            _ = tabManager?.createBrowserSplit(direction: .right)
            
        // Flash
        case .triggerFlash:
            tabManager?.triggerFocusFlash()
            
        default:
            #if DEBUG
            dlog("prefix.action.unhandled: \(action.rawValue)")
            #endif
            break
        }
    }
}
