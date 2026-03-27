import AppKit
import Combine
import Foundation
import WebKit

/// Manages persistent web app workspaces that live in the background.
/// Each enabled web app gets a dedicated workspace with a browser panel
/// that stays loaded (active but hidden) until toggled into view.
@MainActor
final class WebAppManager: ObservableObject {
    static let shared = WebAppManager()

    // MARK: - Configuration Keys

    private static let enabledAppsKey = "webAppShortcuts.enabledApps"
    private static let webAppWorkspacePrefix = "__webapp_"

    // MARK: - Published State

    /// Per-app unread counts for badge display. Key = app ID.
    @Published private(set) var unreadCounts: [String: Int] = [:]

    /// Per-app active state. Key = app ID.
    @Published private(set) var activeAppIds: Set<String> = []

    // MARK: - Internal State

    /// Maps app ID to the workspace (tab) ID hosting it.
    private(set) var appWorkspaceIds: [String: UUID] = [:]

    /// Maps app ID to the browser panel ID within the workspace.
    private var appPanelIds: [String: UUID] = [:]

    /// Tracks which workspace was active before switching to a web app,
    /// so we can toggle back.
    private var previousWorkspaceId: UUID?

    /// Script message handler instances, kept alive per app.
    private var messageHandlers: [String: WebAppScriptMessageHandler] = [:]

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Definitions

    /// All available web app definitions (built-in + custom).
    var availableApps: [WebAppDefinition] {
        WebAppDefinition.builtInApps
    }

    /// IDs of web apps the user has enabled.
    var enabledAppIds: Set<String> {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: Self.enabledAppsKey)
            // Default: all built-in apps enabled
            return Set(stored ?? WebAppDefinition.builtInApps.map(\.id))
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.enabledAppsKey)
        }
    }

    /// Returns definitions for enabled apps, in stable order.
    var enabledApps: [WebAppDefinition] {
        let enabled = enabledAppIds
        return availableApps.filter { enabled.contains($0.id) }
    }

    // MARK: - Workspace Lifecycle

    /// Toggle a web app's visibility. If we're not on it, switch to it.
    /// If we're already on it, switch back to the previous workspace.
    func toggleWebApp(_ appId: String, tabManager: TabManager) {
        guard let app = availableApps.first(where: { $0.id == appId }) else { return }

        if let workspaceId = appWorkspaceIds[appId] {
            // Workspace exists -- toggle to/from it
            if tabManager.selectedTabId == workspaceId {
                // We're on it -- switch back
                switchToPreviousWorkspace(tabManager: tabManager)
            } else {
                // Switch to it
                previousWorkspaceId = tabManager.selectedTabId
                tabManager.selectedTabId = workspaceId
            }
        } else {
            // First activation -- create the workspace
            previousWorkspaceId = tabManager.selectedTabId
            createWebAppWorkspace(app: app, tabManager: tabManager)
        }
    }

    /// Toggle the first enabled web app (for single-key prefix shortcut).
    func toggleFirstWebApp(tabManager: TabManager) {
        guard let firstApp = enabledApps.first else { return }
        toggleWebApp(firstApp.id, tabManager: tabManager)
    }

    /// Check if a workspace ID belongs to a web app.
    func isWebAppWorkspace(_ workspaceId: UUID) -> Bool {
        appWorkspaceIds.values.contains(workspaceId)
    }

    /// Get the app definition for a workspace, if it's a web app workspace.
    func appForWorkspace(_ workspaceId: UUID) -> WebAppDefinition? {
        guard let appId = appWorkspaceIds.first(where: { $0.value == workspaceId })?.key else {
            return nil
        }
        return availableApps.first(where: { $0.id == appId })
    }

    /// Called during session restore to reconnect a web app workspace.
    func reconnectWebAppWorkspace(appId: String, workspaceId: UUID) {
        appWorkspaceIds[appId] = workspaceId
        activeAppIds.insert(appId)
    }

    /// Update unread count for an app (called from JS message handler).
    func updateUnreadCount(appId: String, count: Int) {
        let previous = unreadCounts[appId] ?? 0
        unreadCounts[appId] = max(0, count)

        // If count increased and the app workspace is not focused, deliver
        // a notification through the nsmux notification system.
        if count > previous, count > 0 {
            deliverUnreadNotificationIfNeeded(appId: appId, count: count)
        }
    }

    /// Deliver a web notification from a web app (called from JS message handler).
    func deliverWebNotification(appId: String, title: String, body: String) {
        guard let workspaceId = appWorkspaceIds[appId],
              let panelId = appPanelIds[appId] else { return }

        TerminalNotificationStore.shared.addNotification(
            tabId: workspaceId,
            surfaceId: panelId,
            title: title,
            subtitle: "",
            body: body
        )
    }

    // MARK: - Private

    private func createWebAppWorkspace(app: WebAppDefinition, tabManager: TabManager) {
        // Create a new workspace
        guard let workspace = tabManager.addWorkspace(
            title: Self.webAppWorkspacePrefix + app.id,
            suppressFocus: false
        ) else {
            #if DEBUG
            dlog("webapp.create.failed app=\(app.id)")
            #endif
            return
        }

        // Set the title to the app name
        workspace.customTitle = app.displayName

        let workspaceId = workspace.id
        appWorkspaceIds[app.id] = workspaceId
        activeAppIds.insert(app.id)

        // Create browser panel with the app URL
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            #if DEBUG
            dlog("webapp.create.noPanes app=\(app.id)")
            #endif
            return
        }

        guard let browserPanel = workspace.newBrowserSurface(
            inPane: paneId,
            url: app.url,
            focus: true,
            insertAtEnd: false
        ) else {
            #if DEBUG
            dlog("webapp.create.browserFailed app=\(app.id)")
            #endif
            return
        }

        appPanelIds[app.id] = browserPanel.id

        // Inject notification hook script
        if let hookScript = app.notificationHookScript {
            installNotificationHook(
                appId: app.id,
                browserPanel: browserPanel,
                script: hookScript
            )
        }

        // Close the default terminal panel that workspace creation adds
        // (webapp workspaces are browser-only)
        let terminalPanelIds = workspace.panels.compactMap { (id, panel) -> UUID? in
            guard panel is TerminalPanel, id != browserPanel.id else { return nil }
            return id
        }
        for terminalPanelId in terminalPanelIds {
            workspace.closePanel(terminalPanelId)
        }

        // Pin the workspace so it stays at top
        tabManager.setPinned(workspace, pinned: true)

        #if DEBUG
        dlog("webapp.create.ok app=\(app.id) workspace=\(workspaceId.uuidString.prefix(5)) panel=\(browserPanel.id.uuidString.prefix(5))")
        #endif
    }

    private func installNotificationHook(
        appId: String,
        browserPanel: BrowserPanel,
        script: String
    ) {
        let handler = WebAppScriptMessageHandler(appId: appId, manager: self)
        messageHandlers[appId] = handler

        // Register the message handler on the browser panel's web view configuration
        browserPanel.installWebAppNotificationHandler(handler: handler, script: script)
    }

    private func switchToPreviousWorkspace(tabManager: TabManager) {
        if let previousId = previousWorkspaceId,
           tabManager.tabs.contains(where: { $0.id == previousId }) {
            tabManager.selectedTabId = previousId
        } else {
            // Fall back to first non-webapp workspace
            if let firstNonWebApp = tabManager.tabs.first(where: { !isWebAppWorkspace($0.id) }) {
                tabManager.selectedTabId = firstNonWebApp.id
            }
        }
        previousWorkspaceId = nil
    }

    private func deliverUnreadNotificationIfNeeded(appId: String, count: Int) {
        guard let workspaceId = appWorkspaceIds[appId] else { return }

        // Only deliver if the webapp workspace is not currently focused
        guard let appDelegate = AppDelegate.shared,
              appDelegate.tabManager?.selectedTabId != workspaceId else { return }

        guard let panelId = appPanelIds[appId] else { return }
        let app = availableApps.first(where: { $0.id == appId })
        let appName = app?.displayName ?? appId

        TerminalNotificationStore.shared.addNotification(
            tabId: workspaceId,
            surfaceId: panelId,
            title: appName,
            subtitle: "",
            body: count == -1
                ? String(localized: "webapp.notification.unread", defaultValue: "New messages")
                : String(
                    format: String(localized: "webapp.notification.unreadCount", defaultValue: "%d unread messages"),
                    count
                )
        )
    }
}

// MARK: - WKScriptMessageHandler

/// Handles messages from the injected notification hook JavaScript.
final class WebAppScriptMessageHandler: NSObject, WKScriptMessageHandler {
    let appId: String
    private weak var manager: WebAppManager?

    init(appId: String, manager: WebAppManager) {
        self.appId = appId
        self.manager = manager
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }

            switch type {
            case "notification":
                let title = body["title"] as? String ?? ""
                let notifBody = body["body"] as? String ?? ""
                manager.deliverWebNotification(appId: self.appId, title: title, body: notifBody)

            case "unreadCount":
                let count = body["count"] as? Int ?? 0
                manager.updateUnreadCount(appId: self.appId, count: count)

            case "titleChange":
                // Title changes are handled by the Slack-specific observer
                // in the JS hook, which posts unreadCount messages directly.
                break

            case "faviconChange":
                // Could be used for additional badge detection in the future.
                break

            default:
                #if DEBUG
                dlog("webapp.message.unknown app=\(self.appId) type=\(type)")
                #endif
                break
            }
        }
    }
}

// MARK: - Session Persistence

extension WebAppManager {
    /// Workspace title prefix used to identify web app workspaces during restore.
    static var workspaceTitlePrefix: String { webAppWorkspacePrefix }

    /// Check if a workspace title matches a web app.
    static func appId(fromWorkspaceTitle title: String) -> String? {
        guard title.hasPrefix(webAppWorkspacePrefix) else { return nil }
        return String(title.dropFirst(webAppWorkspacePrefix.count))
    }
}
