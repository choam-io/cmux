import Foundation

/// Defines a web app that can be pinned as a sidebar shortcut.
/// The system ships with built-in definitions (Slack, etc.) and
/// users can add custom ones via defaults or future settings UI.
struct WebAppDefinition: Codable, Identifiable, Equatable, Sendable {
    /// Stable identifier used for persistence and shortcut lookup.
    let id: String
    /// Human-readable name shown in tooltips and settings.
    let displayName: String
    /// SF Symbol name for sidebar icon.
    let iconSystemName: String
    /// Base URL loaded in the browser panel.
    let url: URL
    /// JavaScript injected at document start to intercept
    /// web Notification API calls and route them through nsmux.
    let notificationHookScript: String?
    /// Whether this webapp definition is built-in (not user-deletable).
    let isBuiltIn: Bool

    static func == (lhs: WebAppDefinition, rhs: WebAppDefinition) -> Bool {
        lhs.id == rhs.id &&
        lhs.displayName == rhs.displayName &&
        lhs.iconSystemName == rhs.iconSystemName &&
        lhs.url == rhs.url &&
        lhs.isBuiltIn == rhs.isBuiltIn
    }
}

// MARK: - Built-in Web Apps

extension WebAppDefinition {
    /// Slack webapp. Uses app.slack.com which supports SSO/Okta redirects natively.
    static let slack = WebAppDefinition(
        id: "slack",
        displayName: "Slack",
        iconSystemName: "number.square.fill",
        url: URL(string: "https://app.slack.com")!,
        notificationHookScript: WebAppNotificationHook.slackHookScript,
        isBuiltIn: true
    )

    /// All built-in web app definitions.
    static let builtInApps: [WebAppDefinition] = [
        .slack,
    ]
}
