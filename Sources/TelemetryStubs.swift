// Telemetry removed. These stubs avoid editing dozens of call sites.

@inline(__always)
func sentryBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {}

@inline(__always)
func sentryCaptureWarning(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {}

@inline(__always)
func sentryCaptureError(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {}
