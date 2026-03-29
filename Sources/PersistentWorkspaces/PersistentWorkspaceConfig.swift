import Foundation
import Yams

// MARK: - Config File Model

/// Root of ~/.config/cmux/workspaces.yaml
struct PersistentWorkspaceConfigFile: Codable, Sendable {
    var workspaces: [PersistentWorkspaceDefinition]

    init(workspaces: [PersistentWorkspaceDefinition] = []) {
        self.workspaces = workspaces
    }
}

/// A single persistent workspace definition.
///
/// Reuses the existing CmuxLayoutNode / CmuxSurfaceDefinition schema
/// from cmux.json for layout, extended with lifecycle and UI fields.
struct PersistentWorkspaceDefinition: Codable, Sendable, Identifiable {
    /// Stable identifier for persistence, toggling, and shortcuts.
    let id: String
    /// Display name shown in sidebar, command palette, titlebar.
    let name: String
    /// SF Symbol name for sidebar icon.
    var icon: String?
    /// Hex color for the workspace tab (e.g. "#2D5A3D").
    var color: String?

    // -- Lifecycle --

    /// Create this workspace automatically on app launch.
    var auto_launch: Bool?
    /// Pin the workspace so it can't be accidentally closed.
    var pinned: Bool?

    // -- Keyboard shortcut --

    /// Key to press after the prefix key to toggle this workspace.
    /// Single character, e.g. "S" for prefix+Shift+S, "m" for prefix+m.
    var shortcut: String?

    // -- Layout --

    /// Workspace layout using the same schema as cmux.json commands.
    /// If nil, creates a default single-terminal workspace.
    var layout: CmuxLayoutNode?
    /// Working directory for the workspace. Supports ~ expansion.
    var cwd: String?

    // -- Panel type options --

    /// Options specific to browser surfaces in this workspace.
    var browser_options: PersistentWorkspaceBrowserOptions?
}

/// Browser-specific options for persistent workspaces.
struct PersistentWorkspaceBrowserOptions: Codable, Sendable {
    /// Named notification hook to inject.
    /// Built-in hooks: "slack", "generic".
    /// nil = no notification interception.
    var notification_hook: String?
}

// MARK: - Config Store

@MainActor
final class PersistentWorkspaceConfigStore: ObservableObject {
    static let shared = PersistentWorkspaceConfigStore()

    @Published private(set) var definitions: [PersistentWorkspaceDefinition] = []
    @Published private(set) var configRevision: UInt64 = 0

    let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/workspaces.yaml")
    }()

    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let watchQueue = DispatchQueue(label: "com.cmux.persistent-workspace-config-watch")
    private static let maxReattachAttempts = 5
    private static let reattachDelay: TimeInterval = 0.5

    init() {
        load()
        startFileWatcher()
    }

    deinit {
        fileWatchSource?.cancel()
    }

    // MARK: - Loading

    func load() {
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              !data.isEmpty else {
            if !definitions.isEmpty {
                definitions = []
                Self.activeShortcutKeys = []
                configRevision &+= 1
            }
            return
        }

        do {
            let decoder = YAMLDecoder()
            let config = try decoder.decode(PersistentWorkspaceConfigFile.self, from: data)
            definitions = config.workspaces
            Self.activeShortcutKeys = Set(config.workspaces.compactMap(\.shortcut).filter { !$0.isEmpty })
            configRevision &+= 1
        } catch {
            NSLog("[PersistentWorkspaceConfig] parse error at %@: %@", configPath, String(describing: error))
        }
    }

    /// Returns the definition for a given workspace ID.
    func definition(for id: String) -> PersistentWorkspaceDefinition? {
        definitions.first(where: { $0.id == id })
    }

    /// All definitions that should auto-launch on app start.
    var autoLaunchDefinitions: [PersistentWorkspaceDefinition] {
        definitions.filter { $0.auto_launch == true }
    }

    /// All definitions that have a keyboard shortcut configured.
    var shortcutDefinitions: [(key: String, definition: PersistentWorkspaceDefinition)] {
        definitions.compactMap { def in
            guard let shortcut = def.shortcut, !shortcut.isEmpty else { return nil }
            return (key: shortcut, definition: def)
        }
    }

    /// Thread-safe set of configured shortcut keys for PrefixKeyMode to check
    /// without crossing actor boundaries. Updated on every config load.
    nonisolated(unsafe) private(set) static var activeShortcutKeys: Set<String> = []

    // MARK: - File Watching

    private func startFileWatcher() {
        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else {
            startDirectoryWatcher()
            return
        }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    self.load()
                    self.scheduleReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.load()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    private func startDirectoryWatcher() {
        let dirPath = (configPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirPath) {
            try? fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: self.configPath) else { return }
                self.stopFileWatcher()
                self.load()
                self.startFileWatcher()
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    private func scheduleReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else {
            startDirectoryWatcher()
            return
        }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: self.configPath) {
                    self.load()
                    self.startFileWatcher()
                } else {
                    self.scheduleReattach(attempt: attempt + 1)
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        fileDescriptor = -1
    }
}
