import ApplicationServices

/// Failed launch-time subscriptions must be retried without duplicating the
/// notifications that are already registered successfully.
struct AXNotificationSubscriptions {
    private let names: [String]
    private var results: [String: AXError] = [:]

    // Application-wide observation also covers windows that close before a scan
    // can install their individual destruction subscription.
    static let applicationNotifications = [
        kAXWindowCreatedNotification, kAXMainWindowChangedNotification,
        kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification,
        kAXApplicationActivatedNotification, kAXApplicationDeactivatedNotification
    ]

    init(names: [String] = Self.applicationNotifications) {
        self.names = names
    }

    var needsRetry: Bool { names.contains { shouldRetry(results[$0]) } }

    var diagnostics: String {
        "registrations=\(names.map { "\($0)=\(results[$0]?.rawValue ?? -1)" })"
    }

    mutating func registerPending(using register: (String) -> AXError) {
        for name in names where shouldRetry(results[name]) {
            results[name] = register(name)
        }
    }

    private func shouldRetry(_ result: AXError?) -> Bool {
        switch result {
        case .success, .notificationAlreadyRegistered, .notificationUnsupported, .illegalArgument, .notImplemented:
            false
        default:
            true
        }
    }
}
