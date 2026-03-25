import Darwin
import Foundation

/// Utilities for detecting foreground processes in terminal surfaces.
/// Used by DirectKeyBindings (vim-aware navigation) and session persistence (restore commands).
enum ForegroundProcessDetector {

    /// Process names recognized as vim/nvim.
    static let vimProcessNames: Set<String> = [
        "vim", "nvim", "vimdiff", "nvimdiff",
        "view", "nview",
        "gvim", "gview",
        "lvim", "vimx",
    ]

    /// Process names that should be restored on session resume.
    /// Maps process base name -> restore command template.
    /// The template receives the working directory as context.
    static let restorableProcesses: [String: String] = [
        "nvim": "nvim",
        "vim": "vim",
    ]

    /// Detect the foreground process for a shell PID and return a restore command if applicable.
    /// Returns nil if the foreground process is just a shell or an unrecognized process.
    static func restoreCommand(forShellPid shellPid: pid_t) -> String? {
        let leafPid = findLeafProcess(parentPid: shellPid)
        guard let path = processPath(for: leafPid) else { return nil }
        let baseName = (path as NSString).lastPathComponent.lowercased()

        return restorableProcesses[baseName]
    }

    /// Check if the foreground process is vim/nvim.
    static func isVim(shellPid: pid_t) -> Bool {
        let leafPid = findLeafProcess(parentPid: shellPid)
        guard let path = processPath(for: leafPid) else { return false }
        let baseName = (path as NSString).lastPathComponent.lowercased()
        return vimProcessNames.contains(baseName)
    }

    // MARK: - Surface ID -> Shell PID mapping

    /// Find all shell processes with CMUX_SURFACE_ID set, searching up to maxDepth levels
    /// below the given parent PID. Returns a map of surface UUID string -> shell PID.
    static func buildSurfacePidMap(parentPid: pid_t, maxDepth: Int = 3) -> [String: pid_t] {
        var cache: [String: pid_t] = [:]
        findSurfaceShells(parentPid: parentPid, depth: 0, maxDepth: maxDepth, cache: &cache)
        return cache
    }

    // MARK: - Process tree utilities

    /// Walk child processes to find the leaf (foreground) process.
    static func findLeafProcess(parentPid: pid_t) -> pid_t {
        var current = parentPid
        for _ in 0..<20 {
            var childPids = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(current, &childPids, Int32(childPids.count * MemoryLayout<pid_t>.size))
            if count <= 0 { return current }
            let childCount = min(Int(count), childPids.count)
            if childCount == 0 { return current }
            current = childPids[0]
        }
        return current
    }

    /// Get the executable path for a PID.
    static func processPath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Read environment variables of a process via KERN_PROCARGS2.
    static func readProcessEnvironment(pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let data = Data(bytes: buffer, count: size)
        guard data.count >= 4 else { return nil }

        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }

        var offset = 4
        while offset < data.count && data[offset] != 0 { offset += 1 }
        while offset < data.count && data[offset] == 0 { offset += 1 }
        var argsSkipped: Int32 = 0
        while argsSkipped < argc && offset < data.count {
            while offset < data.count && data[offset] != 0 { offset += 1 }
            offset += 1
            argsSkipped += 1
        }

        var env: [String: String] = [:]
        while offset < data.count {
            var end = offset
            while end < data.count && data[end] != 0 { end += 1 }
            if end == offset { break }
            if let str = String(data: data[offset..<end], encoding: .utf8),
               let eqIdx = str.firstIndex(of: "=") {
                env[String(str[str.startIndex..<eqIdx])] = String(str[str.index(after: eqIdx)...])
            }
            offset = end + 1
        }
        return env
    }

    /// Recursively find child processes that have CMUX_SURFACE_ID set.
    private static func findSurfaceShells(parentPid: pid_t, depth: Int, maxDepth: Int, cache: inout [String: pid_t]) {
        guard depth < maxDepth else { return }

        var childPids = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(parentPid, &childPids, Int32(childPids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return }

        let childCount = min(Int(count), childPids.count)
        for i in 0..<childCount {
            let pid = childPids[i]
            guard pid > 0 else { continue }

            if let env = readProcessEnvironment(pid: pid),
               let surfaceId = env["CMUX_SURFACE_ID"] {
                cache[surfaceId] = pid
            } else {
                findSurfaceShells(parentPid: pid, depth: depth + 1, maxDepth: maxDepth, cache: &cache)
            }
        }
    }
}
