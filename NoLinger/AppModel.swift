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
    private static let protectedBundleIDs: Set<String> = ["com.apple.finder"]
    private static let legacyDefaultExclusionIDs: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.ActivityMonitor",
        "com.apple.AppStore", "com.apple.DiskUtility", "com.apple.Spotlight",
        "com.apple.notificationcenterui"
    ]

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
        let storedExclusions = Self.decodeRules(defaults.data(forKey: "exclusions"))
        let storedInclusions = Self.decodeRules(defaults.data(forKey: "inclusions"))
        let needsExclusionMigration = !defaults.bool(forKey: "systemExclusionsMigrationCompleted")
        // Built-in exclusions had no path; user-selected apps retain their rules.
        exclusions = (storedExclusions ?? []).filter {
            !Self.protectedBundleIDs.contains($0.bundleID)
                && !(needsExclusionMigration && $0.path == nil
                     && Self.legacyDefaultExclusionIDs.contains($0.bundleID))
        }
        inclusions = (storedInclusions ?? []).filter { !Self.protectedBundleIDs.contains($0.bundleID) }
        if let storedExclusions, exclusions != storedExclusions {
            defaults.set(try? JSONEncoder().encode(exclusions), forKey: "exclusions")
        }
        if let storedInclusions, inclusions != storedInclusions {
            defaults.set(try? JSONEncoder().encode(inclusions), forKey: "inclusions")
        }
        if needsExclusionMigration {
            defaults.set(true, forKey: "systemExclusionsMigrationCompleted")
        }
        refreshLoginStatus()
    }

    var windowAccessPermissionName: String {
        if #available(macOS 27.0, *) { return "Device Control and Data Access" }
        return "Accessibility"
    }

    var activeRules: [AppRule] { scope == .allExceptExcluded ? exclusions : inclusions }

    func shouldMonitor(bundleID: String) -> Bool {
        guard bundleID != Bundle.main.bundleIdentifier,
              !Self.protectedBundleIDs.contains(bundleID) else { return false }
        switch scope {
        case .allExceptExcluded: return !exclusions.contains { $0.bundleID == bundleID }
        case .onlyIncluded: return inclusions.contains { $0.bundleID == bundleID }
        }
    }

    func runningApplicationChoices() -> [AppRule] {
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> AppRule? in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundleID = app.bundleIdentifier else { return nil }
            return AppRule(bundleID: bundleID, name: app.localizedName ?? bundleID,
                           path: app.bundleURL?.path)
        }
        return applicationChoices(from: candidates)
    }

    func applicationChoices(from candidates: [AppRule]) -> [AppRule] {
        var unavailableIDs = Set(activeRules.map(\.bundleID)).union(Self.protectedBundleIDs)
        if let ownBundleID = Bundle.main.bundleIdentifier { unavailableIDs.insert(ownBundleID) }
        return candidates.filter { unavailableIDs.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func addApplication(_ rule: AppRule) {
        guard rule.bundleID != Bundle.main.bundleIdentifier,
              !Self.protectedBundleIDs.contains(rule.bundleID),
              !activeRules.contains(where: { $0.bundleID == rule.bundleID }) else { return }
        if scope == .allExceptExcluded { exclusions.append(rule) } else { inclusions.append(rule) }
        persistRules()
    }

    func chooseApplicationsFromFinder() {
        let panel = NSOpenPanel()
        panel.title = scope == .allExceptExcluded ? "Exclude an app" : "Include an app"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addApplications(at: panel.urls)
        }
    }

    func addApplications(at urls: [URL]) {
        for url in urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            addApplication(AppRule(bundleID: bundleID, name: name, path: url.path))
        }
    }

    func exclude(_ app: MonitoredApp) {
        guard app.bundleID != Bundle.main.bundleIdentifier,
              !Self.protectedBundleIDs.contains(app.bundleID) else { return }
        let rule = AppRule(bundleID: app.bundleID, name: app.name, path: app.path)
        if !exclusions.contains(where: { $0.bundleID == app.bundleID }) { exclusions.append(rule) }
        inclusions.removeAll { $0.bundleID == app.bundleID }
        persistRules()
    }

    func removeRule(_ rule: AppRule) {
        if scope == .allExceptExcluded { exclusions.removeAll { $0.id == rule.id } }
        else { inclusions.removeAll { $0.id == rule.id } }
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
}
