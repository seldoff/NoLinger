import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers

enum MonitorScope: String, CaseIterable, Codable, Sendable {
    case allExceptExcluded
    case onlyIncluded

    var title: String {
        switch self {
        case .allExceptExcluded: "All apps except exclusions"
        case .onlyIncluded: "Only selected apps"
        }
    }
}

struct AppRule: Codable, Identifiable, Equatable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let path: String?
}

struct MonitoredApp: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
    let bundleID: String
    let path: String?
    let status: String
    let isPending: Bool
}

struct ActivityEntry: Identifiable, Sendable {
    let id = UUID()
    let date = Date()
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    static let defaultExclusions: [AppRule] = [
        .init(bundleID: "com.apple.finder", name: "Finder", path: nil),
        .init(bundleID: "com.apple.systempreferences", name: "System Settings", path: nil),
        .init(bundleID: "com.apple.ActivityMonitor", name: "Activity Monitor", path: nil),
        .init(bundleID: "com.apple.AppStore", name: "App Store", path: nil),
        .init(bundleID: "com.apple.DiskUtility", name: "Disk Utility", path: nil),
        .init(bundleID: "com.apple.Spotlight", name: "Spotlight", path: nil),
        .init(bundleID: "com.apple.notificationcenterui", name: "Notification Center", path: nil)
    ]
    static let importantApps = Set(defaultExclusions.map(\.bundleID))

    private let defaults: UserDefaults
    var onConfigurationChange: (() -> Void)?

    @Published var isPaused: Bool { didSet { save("paused", isPaused) } }
    @Published var delay: Double { didSet { save("delay", delay) } }
    @Published var scope: MonitorScope { didSet { save("scope", scope.rawValue) } }
    @Published var hideMenuBarIcon: Bool { didSet { defaults.set(hideMenuBarIcon, forKey: "hideMenuBarIcon") } }
    @Published private(set) var exclusions: [AppRule]
    @Published private(set) var inclusions: [AppRule]
    @Published var accessibilityGranted = false
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var permissionMessage: String?
    @Published var serviceStatus = "Starting…"
    @Published var monitoredApps: [MonitoredApp] = []
    @Published var activity: [ActivityEntry] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isPaused = defaults.bool(forKey: "paused")
        let storedDelay = defaults.object(forKey: "delay") as? Double ?? 2.0
        delay = storedDelay.isFinite ? min(10, max(0.2, storedDelay)) : 2
        scope = MonitorScope(rawValue: defaults.string(forKey: "scope") ?? "") ?? .allExceptExcluded
        hideMenuBarIcon = defaults.bool(forKey: "hideMenuBarIcon")
        exclusions = Self.decodeRules(defaults.data(forKey: "exclusions")) ?? Self.defaultExclusions
        inclusions = Self.decodeRules(defaults.data(forKey: "inclusions")) ?? []
        refreshLoginStatus()
    }

    var windowAccessPermissionName: String {
        if #available(macOS 27.0, *) { return "Device Control and Data Access" }
        return "Accessibility"
    }

    var activeRules: [AppRule] { scope == .allExceptExcluded ? exclusions : inclusions }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func shouldMonitor(bundleID: String) -> Bool {
        guard bundleID != Bundle.main.bundleIdentifier else { return false }
        switch scope {
        case .allExceptExcluded: return !exclusions.contains { $0.bundleID == bundleID }
        case .onlyIncluded: return inclusions.contains { $0.bundleID == bundleID }
        }
    }

    func addApplication() {
        let panel = NSOpenPanel()
        panel.title = scope == .allExceptExcluded ? "Exclude an app" : "Include an app"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier else { continue }
            if scope == .onlyIncluded, Self.importantApps.contains(id), !confirmImportantApp(id) { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            let rule = AppRule(bundleID: id, name: name, path: url.path)
            if !activeRules.contains(where: { $0.bundleID == id }) {
                if scope == .allExceptExcluded { exclusions.append(rule) } else { inclusions.append(rule) }
            }
        }
        persistRules()
    }

    func exclude(_ app: MonitoredApp) {
        let rule = AppRule(bundleID: app.bundleID, name: app.name, path: app.path)
        if !exclusions.contains(where: { $0.bundleID == app.bundleID }) { exclusions.append(rule) }
        inclusions.removeAll { $0.bundleID == app.bundleID }
        persistRules()
    }

    func removeRule(_ rule: AppRule) {
        if scope == .allExceptExcluded, Self.importantApps.contains(rule.bundleID),
           !confirmImportantApp(rule.bundleID) { return }
        if scope == .allExceptExcluded { exclusions.removeAll { $0.id == rule.id } }
        else { inclusions.removeAll { $0.id == rule.id } }
        persistRules()
    }

    func restoreExclusions() {
        for rule in Self.defaultExclusions where !exclusions.contains(where: { $0.id == rule.id }) {
            exclusions.append(rule)
        }
        persistRules()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            permissionMessage = nil
        } catch {
            permissionMessage = "Couldn’t change launch at login: \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNeedsApproval = status == .requiresApproval
    }

    func log(_ message: String) {
        activity.insert(ActivityEntry(message: message), at: 0)
        if activity.count > 60 { activity.removeLast(activity.count - 60) }
    }

    func icon(path: String?, bundleID: String) -> NSImage {
        let url = path.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        onConfigurationChange?()
    }

    private func persistRules() {
        defaults.set(try? JSONEncoder().encode(exclusions), forKey: "exclusions")
        defaults.set(try? JSONEncoder().encode(inclusions), forKey: "inclusions")
        onConfigurationChange?()
    }

    private static func decodeRules(_ data: Data?) -> [AppRule]? {
        data.flatMap { try? JSONDecoder().decode([AppRule].self, from: $0) }
    }

    private func confirmImportantApp(_ bundleID: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow No Linger to quit this system app?"
        alert.informativeText = "\(bundleID) is normally excluded. It may be needed even when it has no windows."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow Auto-Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
