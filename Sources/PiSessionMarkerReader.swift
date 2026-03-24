import Foundation

/// Reads pi session markers written by the cmux-session-marker.ts extension.
/// Markers are stored in ~/.pi/sessions/markers/<surface-id>.json
enum PiSessionMarkerReader {
    private static let markersDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/sessions/markers", isDirectory: true)
    
    struct PiSessionMarker: Codable {
        let sessionFile: String
        let sessionId: String
        let cwd: String
        let timestamp: String
        let pid: Int
        let tty: String?
        let cmuxSurfaceId: String?
        let cmuxWorkspaceId: String?
    }
    
    /// Returns a restore command (e.g., "pi --session <path>") if a valid pi marker exists
    /// for the given surface ID or TTY name. Returns nil if no marker found or invalid.
    static func restoreCommand(forSurfaceId surfaceId: String?, ttyName: String?) -> String? {
        // Try surface ID first (more precise)
        if let surfaceId = surfaceId, !surfaceId.isEmpty {
            if let marker = readMarker(forId: surfaceId) {
                return buildRestoreCommand(from: marker)
            }
        }
        
        // Fall back to TTY name
        if let ttyName = ttyName, !ttyName.isEmpty {
            let normalizedTty = ttyName.replacingOccurrences(of: "/dev/", with: "")
            if let marker = readMarker(forId: normalizedTty) {
                return buildRestoreCommand(from: marker)
            }
        }
        
        return nil
    }
    
    private static func readMarker(forId id: String) -> PiSessionMarker? {
        let markerPath = markersDir.appendingPathComponent("\(id).json")
        
        guard FileManager.default.fileExists(atPath: markerPath.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: markerPath)
            let marker = try JSONDecoder().decode(PiSessionMarker.self, from: data)
            
            // Validate that the session file still exists
            guard FileManager.default.fileExists(atPath: marker.sessionFile) else {
                // Clean up stale marker
                try? FileManager.default.removeItem(at: markerPath)
                return nil
            }
            
            // Check if the marker is stale (process no longer running)
            if !isProcessRunning(pid: marker.pid) {
                // Clean up stale marker
                try? FileManager.default.removeItem(at: markerPath)
                return nil
            }
            
            return marker
        } catch {
            return nil
        }
    }
    
    private static func buildRestoreCommand(from marker: PiSessionMarker) -> String {
        // Use shell quoting for the session file path
        let escapedPath = marker.sessionFile.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "pi --session '\(escapedPath)'"
    }
    
    private static func isProcessRunning(pid: Int) -> Bool {
        // kill(pid, 0) returns 0 if process exists, -1 with errno if not
        return kill(Int32(pid), 0) == 0
    }
}
