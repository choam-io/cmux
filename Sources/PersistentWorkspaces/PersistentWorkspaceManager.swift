import AppKit
import Bonsplit
import Combine
import Foundation
import WebKit

/// Manages persistent workspaces defined in ~/.config/cmux/workspaces.yaml.
///
/// Replaces and generalizes the former WebAppManager. Each configured
/// workspace gets a dedicated Workspace that can be auto-launched,
/// pinned, toggled via keyboard shortcut, and shown with an icon
/// in the sidebar footer.
@MainActor
final class PersistentWorkspaceManager: ObservableObject {
    static let shared = PersistentWorkspaceManager()

    // MARK: - Configuration

    private let configStore = PersistentWorkspaceConfigStore.shared

    // MARK: - Published State

    /// Per-workspace unread counts for badge display. Key = workspace definition ID.
    @Published private(set) var unreadCounts: [String: Int] = [:]

    /// IDs of persistent workspaces that have been activated (workspace created).
    @Published private(set) var activeIds: Set<String> = []

    // MARK: - Internal State

    /// Maps definition ID to the Workspace (tab) UUID.
    private(set) var workspaceIds: [String: UUID] = [:]

    /// Maps definition ID to the primary panel UUID.
    private var panelIds: [String: UUID] = [:]

    /// Tracks which workspace was active before switching to a persistent one.
    private var previousWorkspaceId: UUID?

    /// Script message handler instances, kept alive per workspace.
    private var messageHandlers: [String: PersistentWorkspaceScriptMessageHandler] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var configObserver: AnyCancellable?

    // MARK: - Initialization

    private init() {
        // React to config changes
        configObserver = configStore.$configRevision
            .dropFirst() // Skip initial value
            .sink { [weak self] _ in
                self?.handleConfigChange()
            }
    }

    // MARK: - Config Access

    /// Current workspace definitions from the config file.
    var definitions: [PersistentWorkspaceDefinition] {
        configStore.definitions
    }

    /// Definitions that have sidebar icons configured.
    var sidebarDefinitions: [PersistentWorkspaceDefinition] {
        definitions.filter { $0.icon != nil }
    }

    /// Lookup a definition by its shortcut key (for prefix key dispatch).
    func definition(forShortcut key: String) -> PersistentWorkspaceDefinition? {
        configStore.shortcutDefinitions.first(where: { $0.key == key })?.definition
    }

    // MARK: - Workspace Lifecycle

    /// Auto-launch all workspaces marked with auto_launch: true.
    /// Called once during app startup after the TabManager is ready.
    func autoLaunch(tabManager: TabManager) {
        for definition in configStore.autoLaunchDefinitions {
            guard workspaceIds[definition.id] == nil else { continue }
            createWorkspace(definition: definition, tabManager: tabManager, switchTo: false)
        }
    }

    /// Toggle a persistent workspace. If not on it, switch to it.
    /// If already on it, switch back to the previous workspace.
    func toggle(_ definitionId: String, tabManager: TabManager) {
        guard let definition = configStore.definition(for: definitionId) else { return }

        if let workspaceId = workspaceIds[definitionId] {
            if tabManager.selectedTabId == workspaceId {
                switchToPreviousWorkspace(tabManager: tabManager)
            } else {
                previousWorkspaceId = tabManager.selectedTabId
                tabManager.selectedTabId = workspaceId
            }
        } else {
            previousWorkspaceId = tabManager.selectedTabId
            createWorkspace(definition: definition, tabManager: tabManager, switchTo: true)
        }
    }

    /// Toggle by shortcut key (called from prefix key handler).
    func toggleByShortcut(_ key: String, tabManager: TabManager) -> Bool {
        guard let definition = definition(forShortcut: key) else { return false }
        toggle(definition.id, tabManager: tabManager)
        return true
    }

    /// Check if a workspace UUID belongs to a persistent workspace.
    func isPersistentWorkspace(_ workspaceId: UUID) -> Bool {
        workspaceIds.values.contains(workspaceId)
    }

    /// Get the definition for a workspace, if it's a persistent workspace.
    func definition(forWorkspace workspaceId: UUID) -> PersistentWorkspaceDefinition? {
        guard let defId = workspaceIds.first(where: { $0.value == workspaceId })?.key else {
            return nil
        }
        return configStore.definition(for: defId)
    }

    /// Called during session restore to reconnect a persistent workspace.
    func reconnect(definitionId: String, workspaceId: UUID) {
        workspaceIds[definitionId] = workspaceId
        activeIds.insert(definitionId)
    }

    // MARK: - Notifications

    /// Update unread count for a workspace (called from JS message handler).
    func updateUnreadCount(definitionId: String, count: Int) {
        let previous = unreadCounts[definitionId] ?? 0
        unreadCounts[definitionId] = max(0, count)

        if count > previous, count > 0 {
            deliverUnreadNotificationIfNeeded(definitionId: definitionId, count: count)
        }
    }

    /// Deliver a web notification from a persistent workspace browser.
    func deliverWebNotification(definitionId: String, title: String, body: String) {
        guard let workspaceId = workspaceIds[definitionId],
              let panelId = panelIds[definitionId] else { return }

        TerminalNotificationStore.shared.addNotification(
            tabId: workspaceId,
            surfaceId: panelId,
            title: title,
            subtitle: "",
            body: body
        )
    }

    // MARK: - Workspace Creation

    private func createWorkspace(
        definition: PersistentWorkspaceDefinition,
        tabManager: TabManager,
        switchTo: Bool
    ) {
        let resolvedCwd: String?
        if let cwd = definition.cwd {
            resolvedCwd = CmuxConfigStore.resolveCwd(cwd, relativeTo: FileManager.default.homeDirectoryForCurrentUser.path)
        } else {
            resolvedCwd = nil
        }

        let workspace = tabManager.addWorkspace(
            title: definition.name,
            workingDirectory: resolvedCwd,
            select: switchTo,
            autoWelcomeIfNeeded: false
        )

        if let color = definition.color {
            workspace.setCustomColor(color)
        }

        let workspaceId = workspace.id
        workspaceIds[definition.id] = workspaceId
        activeIds.insert(definition.id)

        // Apply layout if provided
        if let layout = definition.layout {
            let baseCwd = resolvedCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            workspace.applyCustomLayout(layout, baseCwd: baseCwd)

            // Install notification hooks on any browser panels
            installNotificationHooksIfNeeded(definition: definition, workspace: workspace)
        } else {
            // No layout -- this is a single-surface workspace.
            // Check if it should be a browser.
            if let firstBrowserUrl = findFirstBrowserUrl(definition) {
                // Replace default terminal with a browser
                guard let paneId = workspace.bonsplitController.focusedPaneId
                        ?? workspace.bonsplitController.allPaneIds.first else { return }

                guard let browserPanel = workspace.newBrowserSurface(
                    inPane: paneId,
                    url: firstBrowserUrl,
                    focus: true,
                    insertAtEnd: false
                ) else { return }

                panelIds[definition.id] = browserPanel.id

                // Install notification hook
                if let hookName = definition.browser_options?.notification_hook {
                    installNotificationHook(
                        definitionId: definition.id,
                        browserPanel: browserPanel,
                        hookName: hookName
                    )
                }

                // Close the default terminal
                let terminalPanelIds = workspace.panels.compactMap { (id, panel) -> UUID? in
                    guard panel is TerminalPanel, id != browserPanel.id else { return nil }
                    return id
                }
                for terminalPanelId in terminalPanelIds {
                    workspace.closePanel(terminalPanelId)
                }
            }
        }

        // Pin if configured
        // Persistent workspaces are always pinned -- they live in the sidebar
        // footer and shouldn't be accidentally closeable.
        tabManager.setPinned(workspace, pinned: true)

        #if DEBUG
        dlog("persistent.create.ok id=\(definition.id) workspace=\(workspaceId.uuidString.prefix(5))")
        #endif
    }

    /// Walk the layout tree to find browser surfaces and install hooks.
    private func installNotificationHooksIfNeeded(
        definition: PersistentWorkspaceDefinition,
        workspace: Workspace
    ) {
        guard let hookName = definition.browser_options?.notification_hook else { return }

        // Find browser panels in the workspace
        for (panelId, panel) in workspace.panels {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            panelIds[definition.id] = panelId
            installNotificationHook(
                definitionId: definition.id,
                browserPanel: browserPanel,
                hookName: hookName
            )
            break // Hook the first browser panel
        }
    }

    private func installNotificationHook(
        definitionId: String,
        browserPanel: BrowserPanel,
        hookName: String
    ) {
        guard let script = Self.notificationHookScript(named: hookName) else {
            #if DEBUG
            dlog("persistent.hook.unknown id=\(definitionId) hook=\(hookName)")
            #endif
            return
        }

        let handler = PersistentWorkspaceScriptMessageHandler(definitionId: definitionId, manager: self)
        messageHandlers[definitionId] = handler
        browserPanel.installWebAppNotificationHandler(handler: handler, script: script)
    }

    /// Look up a built-in notification hook script by name.
    private static func notificationHookScript(named name: String) -> String? {
        switch name {
        case "slack":
            return WebAppNotificationHook.slackHookScript
        case "generic":
            return WebAppNotificationHook.genericHookScript
        default:
            return nil
        }
    }

    /// If the definition has no layout but browser_options or a browser-like
    /// URL pattern, find the URL to load.
    private func findFirstBrowserUrl(_ definition: PersistentWorkspaceDefinition) -> URL? {
        // Walk the layout to find a browser surface URL
        if let layout = definition.layout {
            return findBrowserUrlInLayout(layout)
        }
        return nil
    }

    private func findBrowserUrlInLayout(_ node: CmuxLayoutNode) -> URL? {
        switch node {
        case .pane(let pane):
            for surface in pane.surfaces {
                if surface.type == .browser, let urlString = surface.url, let url = URL(string: urlString) {
                    return url
                }
            }
            return nil
        case .split(let split):
            for child in split.children {
                if let url = findBrowserUrlInLayout(child) {
                    return url
                }
            }
            return nil
        }
    }

    // MARK: - Navigation

    private func switchToPreviousWorkspace(tabManager: TabManager) {
        if let previousId = previousWorkspaceId,
           tabManager.tabs.contains(where: { $0.id == previousId }) {
            tabManager.selectedTabId = previousId
        } else {
            if let firstNonPersistent = tabManager.tabs.first(where: { !isPersistentWorkspace($0.id) }) {
                tabManager.selectedTabId = firstNonPersistent.id
            }
        }
        previousWorkspaceId = nil
    }

    // MARK: - Notifications (Internal)

    private func deliverUnreadNotificationIfNeeded(definitionId: String, count: Int) {
        guard let workspaceId = workspaceIds[definitionId] else { return }
        guard let appDelegate = AppDelegate.shared,
              appDelegate.tabManager?.selectedTabId != workspaceId else { return }
        guard let panelId = panelIds[definitionId] else { return }

        let definition = configStore.definition(for: definitionId)
        let name = definition?.name ?? definitionId

        TerminalNotificationStore.shared.addNotification(
            tabId: workspaceId,
            surfaceId: panelId,
            title: name,
            subtitle: "",
            body: count == -1
                ? String(localized: "persistent.notification.unread", defaultValue: "New messages")
                : String(
                    format: String(localized: "persistent.notification.unreadCount", defaultValue: "%d unread messages"),
                    count
                )
        )
    }

    // MARK: - Config Changes

    private func handleConfigChange() {
        let currentDefIds = Set(configStore.definitions.map(\.id))
        // Find active persistent workspaces whose definitions were removed
        let removedIds = activeIds.filter { !currentDefIds.contains($0) }

        #if DEBUG
        dlog("persistent.configChanged definitions=\(configStore.definitions.count) removed=\(removedIds.count)")
        #endif

        for removedId in removedIds {
            guard let workspaceId = workspaceIds[removedId] else { continue }
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) else { continue }
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { continue }

            let name = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.isEmpty ? "Workspace" : name

            let alert = NSAlert()
            alert.messageText = String(
                format: String(localized: "persistent.removed.title", defaultValue: "\"%@\" removed from config"),
                displayName
            )
            alert.informativeText = String(
                localized: "persistent.removed.message",
                defaultValue: "This workspace was removed from workspaces.yaml. Close it, or keep it as a regular workspace?"
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(
                localized: "persistent.removed.close",
                defaultValue: "Close"
            ))
            alert.addButton(withTitle: String(
                localized: "persistent.removed.keep",
                defaultValue: "Keep"
            ))

            let response = alert.runModal()

            // Unregister from persistent tracking either way
            workspaceIds.removeValue(forKey: removedId)
            panelIds.removeValue(forKey: removedId)
            activeIds.remove(removedId)
            unreadCounts.removeValue(forKey: removedId)
            messageHandlers.removeValue(forKey: removedId)

            if response == .alertFirstButtonReturn {
                // Close
                tabManager.closeWorkspace(workspace)
            }
            // else: Keep -- workspace stays as a regular (already pinned) workspace
        }
    }
}

// MARK: - Session Persistence

extension PersistentWorkspaceManager {
    /// Workspace title prefix used to identify persistent workspaces during restore.
    static let workspaceTitlePrefix = "__persistent_"

    /// Extract definition ID from a workspace title, if it matches.
    static func definitionId(fromWorkspaceTitle title: String) -> String? {
        guard title.hasPrefix(workspaceTitlePrefix) else { return nil }
        return String(title.dropFirst(workspaceTitlePrefix.count))
    }
}

// MARK: - Script Message Handler

/// Handles messages from injected notification hook JavaScript in persistent workspace browsers.
final class PersistentWorkspaceScriptMessageHandler: NSObject, WKScriptMessageHandler {
    let definitionId: String
    private weak var manager: PersistentWorkspaceManager?

    init(definitionId: String, manager: PersistentWorkspaceManager) {
        self.definitionId = definitionId
        self.manager = manager
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Extract body synchronously before entering the MainActor task
        // to avoid main-actor isolation warnings on WKScriptMessage.body.
        let messageBody = message.body
        guard let body = messageBody as? [String: Any],
              let type = body["type"] as? String else { return }

        Task { @MainActor [weak self] in
            guard let self, let manager = self.manager else { return }

            switch type {
            case "notification":
                let title = body["title"] as? String ?? ""
                let notifBody = body["body"] as? String ?? ""
                manager.deliverWebNotification(definitionId: self.definitionId, title: title, body: notifBody)

            case "unreadCount":
                let count = body["count"] as? Int ?? 0
                manager.updateUnreadCount(definitionId: self.definitionId, count: count)

            case "titleChange", "faviconChange":
                break

            default:
                #if DEBUG
                dlog("persistent.message.unknown id=\(self.definitionId) type=\(type)")
                #endif
                break
            }
        }
    }
}
