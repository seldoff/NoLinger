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

@MainActor
final class AppModel: ObservableObject {
    private static let protectedBundleIDs: Set<String> = ["com.apple.finder"]
    private static let legacyDefaultExclusionIDs: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.ActivityMonitor",
        "com.apple.AppStore", "com.apple.DiskUtility", "com.apple.Spotlight",
        "com.apple.notificationcenterui"
    ]

    private let defaults: UserDefaults
    private let diagnosticLogFile: DiagnosticLog
    var onConfigurationChange: (() -> Void)?
    var onLogCollectionStarted: (() -> Void)?

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
    @Published private(set) var isCollectingLogs = false
    @Published private(set) var collectedLogURL: URL?
    @Published private(set) var logCollectionMessage: String?

    var canAccessCollectedLogs: Bool { isCollectingLogs && collectedLogURL != nil }

    init(defaults: UserDefaults = .standard, logDirectory: URL = DiagnosticLog.defaultDirectory) {
        self.defaults = defaults
        diagnosticLogFile = DiagnosticLog(directory: logDirectory)
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

    func setCollectLogs(_ enabled: Bool) {
        guard enabled != isCollectingLogs else { return }
        logCollectionMessage = nil
        if enabled {
            do {
                collectedLogURL = try diagnosticLogFile.start()
                isCollectingLogs = true
                diagnosticLog("Log collection started. Automatic quitting continues normally.", category: "session")
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
                diagnosticLog("No Linger \(version) (\(build)); \(ProcessInfo.processInfo.operatingSystemVersionString)", category: "session")
                logConfiguration()
                diagnosticLog("Window access=\(accessibilityGranted); service=\(serviceStatus)", category: "session")
                for app in monitoredApps {
                    diagnosticLog("\(app.name) [\(app.bundleID)] pid=\(app.id): \(app.status)", category: "snapshot")
                }
                onLogCollectionStarted?()
            } catch {
                handleLogCollectionError(error)
            }
        } else {
            do { try discardCollectedLogs() }
            catch { logCollectionMessage = "Couldn’t remove collected logs: \(error.localizedDescription)" }
        }
    }

    /// Writes only while a log collection is active.
    func diagnosticLog(_ message: @autoclosure () -> String, category: String = "monitor") {
        guard isCollectingLogs else { return }
        do { try diagnosticLogFile.append(message(), category: category) }
        catch { handleLogCollectionError(error) }
    }

    func logConfiguration() {
        diagnosticLog("Paused=\(isPaused); delay=\(delay)s; scope=\(scope.rawValue); exclusions=\(exclusions.map(\.bundleID).sorted()); inclusions=\(inclusions.map(\.bundleID).sorted())", category: "configuration")
    }

    func revealCollectedLogs() {
        guard canAccessCollectedLogs, let collectedLogURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([collectedLogURL])
    }

    func saveCollectedLogs() {
        guard canAccessCollectedLogs, let source = collectedLogURL else { return }
        let panel = NSSavePanel()
        panel.title = "Save collected logs"
        panel.allowedContentTypes = [.log]
        panel.nameFieldStringValue = source.lastPathComponent
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            do { try self?.exportCollectedLogs(to: destination) }
            catch { self?.logCollectionMessage = "Couldn’t save logs: \(error.localizedDescription)" }
        }
    }

    func exportCollectedLogs(to destination: URL) throws {
        guard canAccessCollectedLogs, let source = collectedLogURL else { return }
        try diagnosticLogFile.flush()
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        logCollectionMessage = nil
    }

    private func handleLogCollectionError(_ error: Error) {
        let message = "Log collection stopped: \(error.localizedDescription)"
        do {
            try discardCollectedLogs()
            logCollectionMessage = message
        } catch {
            logCollectionMessage = "\(message) Couldn’t remove the log file: \(error.localizedDescription)"
        }
    }

    private func discardCollectedLogs() throws {
        isCollectingLogs = false
        collectedLogURL = nil
        try diagnosticLogFile.discard()
    }

    func icon(path: String?, bundleID: String) -> NSImage {
        let url = path.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        logConfiguration()
        onConfigurationChange?()
    }

    private func persistRules() {
        defaults.set(try? JSONEncoder().encode(exclusions), forKey: "exclusions")
        defaults.set(try? JSONEncoder().encode(inclusions), forKey: "inclusions")
        logConfiguration()
        onConfigurationChange?()
    }

    private static func decodeRules(_ data: Data?) -> [AppRule]? {
        data.flatMap { try? JSONDecoder().decode([AppRule].self, from: $0) }
    }
}
