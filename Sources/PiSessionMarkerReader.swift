import Foundation
import os.log

private let logger = Logger(subsystem: "io.choam.nsmux", category: "PiSessionMarker")

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
        NSLog("[PiSessionMarker] restoreCommand called: surfaceId=%@, ttyName=%@", surfaceId ?? "nil", ttyName ?? "nil")
        logger.debug("restoreCommand called: surfaceId=\(surfaceId ?? "nil"), ttyName=\(ttyName ?? "nil")")
        
        // Try surface ID first (more precise)
        if let surfaceId = surfaceId, !surfaceId.isEmpty {
            if let marker = readMarker(forId: surfaceId) {
                let cmd = buildRestoreCommand(from: marker)
                NSLog("[PiSessionMarker] Found marker for surface %@, cmd: %@", surfaceId, cmd)
                logger.info("Found pi session marker for surface \(surfaceId), restore command: \(cmd)")
                return cmd
            }
        }
        
        // Fall back to TTY name
        if let ttyName = ttyName, !ttyName.isEmpty {
            let normalizedTty = ttyName.replacingOccurrences(of: "/dev/", with: "")
            if let marker = readMarker(forId: normalizedTty) {
                let cmd = buildRestoreCommand(from: marker)
                NSLog("[PiSessionMarker] Found marker for tty %@, cmd: %@", normalizedTty, cmd)
                logger.info("Found pi session marker for tty \(normalizedTty), restore command: \(cmd)")
                return cmd
            }
        }
        
        NSLog("[PiSessionMarker] No marker found")
        logger.debug("No pi session marker found")
        return nil
    }
    
    private static func readMarker(forId id: String) -> PiSessionMarker? {
        let markerPath = markersDir.appendingPathComponent("\(id).json")
        NSLog("[PiSessionMarker] Checking marker at: %@", markerPath.path)
        logger.debug("Checking marker at: \(markerPath.path)")
        
        guard FileManager.default.fileExists(atPath: markerPath.path) else {
            NSLog("[PiSessionMarker] Marker file does not exist")
            logger.debug("Marker file does not exist")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: markerPath)
            let marker = try JSONDecoder().decode(PiSessionMarker.self, from: data)
            NSLog("[PiSessionMarker] Parsed marker: sessionFile=%@", marker.sessionFile)
            logger.debug("Parsed marker: sessionFile=\(marker.sessionFile)")
            
            // Return the marker even if the session file doesn't exist yet.
            // Pi writes markers on session_start before the jsonl file is created.
            // The file will exist by the time we need to restore.
            // Stale markers (from old sessions) are harmless -- the restore command
            // will fail gracefully if the session file is truly gone.
            
            NSLog("[PiSessionMarker] Marker valid, returning")
            logger.debug("Marker valid, session file exists=\(FileManager.default.fileExists(atPath: marker.sessionFile))")
            return marker
        } catch {
            NSLog("[PiSessionMarker] Failed to read/parse marker: %@", error.localizedDescription)
            logger.error("Failed to read/parse marker: \(error.localizedDescription)")
            return nil
        }
    }
    
    private static func buildRestoreCommand(from marker: PiSessionMarker) -> String {
        // The restore command is now typed into a normal login shell (not passed as
        // ghostty's initialCommand). The shell already has PATH set up (nvm, etc.),
        // so we just need a simple pi invocation with proper quoting.
        let escaped = marker.sessionFile.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "exec pi --session '\(escaped)'"
    }
    
    
    private static func isProcessRunning(pid: Int) -> Bool {
        // kill(pid, 0) returns 0 if process exists, -1 with errno if not
        // Note: Currently unused but kept for potential future use
        return kill(Int32(pid), 0) == 0
    }
}
