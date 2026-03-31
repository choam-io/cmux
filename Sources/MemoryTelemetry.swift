import Foundation
import Darwin

// MARK: - Helpers for object counting

extension Workspace {
    /// Number of browser panels in this workspace.
    var browserPanelCount: Int {
        panels.values.filter { $0 is BrowserPanel }.count
    }
}

/// Lightweight memory telemetry that logs process memory usage periodically.
/// Writes to ~/Library/Logs/nsmux/memory-telemetry.log.
///
/// Log format (one JSON object per line):
///   {"ts":"2026-03-30T12:00:00Z","rss_mb":250,"virt_mb":1200,"delta_mb":5,"surfaces":12,"browsers":8,"uptime_min":30}
///
/// On significant growth (>50MB since last sample), logs a breakdown of live objects.
@MainActor
final class MemoryTelemetry {
    static let shared = MemoryTelemetry()

    private var timer: DispatchSourceTimer?
    private var logFileHandle: FileHandle?
    private var lastRSSBytes: UInt64 = 0
    private var baselineRSSBytes: UInt64 = 0
    private var startTime = Date()
    private var sampleCount: UInt64 = 0

    /// Growth threshold (bytes) that triggers a detailed breakdown log.
    private let growthAlertThreshold: UInt64 = 50 * 1024 * 1024  // 50 MB

    /// Interval between samples.
    private let sampleInterval: TimeInterval = 30.0

    private init() {}

    func start() {
        guard timer == nil else { return }
        startTime = Date()

        openLogFile()
        logHeader()

        let baseline = currentRSSBytes()
        baselineRSSBytes = baseline
        lastRSSBytes = baseline

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + sampleInterval,
            repeating: sampleInterval,
            leeway: .seconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        self.timer = timer
        timer.resume()

        // Log initial sample
        sample()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        logFileHandle?.closeFile()
        logFileHandle = nil
    }

    // MARK: - Sampling

    private func sample() {
        sampleCount += 1
        let rss = currentRSSBytes()
        let virt = currentVirtualBytes()
        let delta = Int64(rss) - Int64(lastRSSBytes)
        let totalGrowth = Int64(rss) - Int64(baselineRSSBytes)
        let uptimeMin = Int(Date().timeIntervalSince(startTime) / 60.0)

        let surfaceCount = countLiveSurfaces()
        let browserCount = countLiveBrowsers()
        let popupTabCount = countPopupTabs()

        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "rss_mb": rss / (1024 * 1024),
            "virt_mb": virt / (1024 * 1024),
            "delta_mb": delta / (1024 * 1024),
            "total_growth_mb": totalGrowth / (1024 * 1024),
            "surfaces": surfaceCount,
            "browsers": browserCount,
            "popup_tabs": popupTabCount,
            "uptime_min": uptimeMin,
            "sample": sampleCount,
        ]

        // On significant growth, add detailed breakdown
        let absDelta = UInt64(abs(delta))
        if absDelta > growthAlertThreshold {
            entry["alert"] = "significant_growth"
            entry["detail"] = detailedBreakdown()
        }

        // On every 10th sample (~5 min), add a mini breakdown
        if sampleCount % 10 == 0 {
            entry["detail"] = detailedBreakdown()
        }

        writeLine(entry)
        lastRSSBytes = rss
    }

    // MARK: - Memory Queries

    private func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private func currentVirtualBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.virtual_size) : 0
    }

    // MARK: - Object Counts

    private func countLiveSurfaces() -> Int {
        // Access the surface registry to count live surfaces
        TerminalSurfaceRegistry.shared.count
    }

    private func countLiveBrowsers() -> Int {
        guard let app = AppDelegate.shared else { return 0 }
        var count = 0
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }
            for tab in manager.tabs {
                count += tab.browserPanelCount
            }
        }
        return count
    }

    private func countPopupTabs() -> Int {
        TerminalController.shared.popupTabCount
    }

    // MARK: - Detailed Breakdown

    private func detailedBreakdown() -> [String: Any] {
        var breakdown: [String: Any] = [:]

        // Malloc zones summary
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        breakdown["malloc_in_use_mb"] = stats.size_in_use / (1024 * 1024)
        breakdown["malloc_allocated_mb"] = stats.size_allocated / (1024 * 1024)
        breakdown["malloc_blocks"] = stats.blocks_in_use

        // VM region summary (compressed + purgeable)
        breakdown["vm"] = vmRegionSummary()

        return breakdown
    }

    private func vmRegionSummary() -> [String: Any] {
        var address: mach_vm_address_t = 0
        var size: mach_vm_size_t = 0
        var totalDirty: UInt64 = 0
        var totalSwapped: UInt64 = 0
        var regionCount: Int = 0
        var nesting: natural_t = 0

        while true {
            var info = vm_region_submap_info_64()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_region_submap_info_64>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region_recurse(
                        mach_task_self_,
                        &address,
                        &size,
                        &nesting,
                        $0,
                        &count
                    )
                }
            }
            if result != KERN_SUCCESS { break }

            if info.is_submap != 0 {
                nesting += 1
                continue
            }

            totalDirty += UInt64(info.pages_dirtied) * UInt64(vm_page_size)
            totalSwapped += UInt64(info.pages_swapped_out) * UInt64(vm_page_size)
            regionCount += 1
            address += size
        }

        return [
            "dirty_mb": totalDirty / (1024 * 1024),
            "swapped_mb": totalSwapped / (1024 * 1024),
            "regions": regionCount,
        ]
    }

    // MARK: - Log File

    private func openLogFile() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/nsmux")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logPath = logDir.appendingPathComponent("memory-telemetry.log")

        // Rotate if over 10MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath.path),
           let fileSize = attrs[.size] as? UInt64,
           fileSize > 10 * 1024 * 1024 {
            let rotated = logDir.appendingPathComponent("memory-telemetry.prev.log")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: logPath, to: rotated)
        }

        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: logPath.path)
        logFileHandle?.seekToEndOfFile()
    }

    private func logHeader() {
        let header: [String: Any] = [
            "event": "start",
            "ts": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
        ]
        writeLine(header)
    }

    private func writeLine(_ dict: [String: Any]) {
        guard let handle = logFileHandle,
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        handle.write(line.data(using: .utf8) ?? Data())
    }
}
