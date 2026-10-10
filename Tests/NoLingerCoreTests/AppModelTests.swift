import Foundation
import XCTest
@testable import NoLingerCore

final class AppModelTests: XCTestCase {
    private let formerDefaultBundleIDs = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.ActivityMonitor",
        "com.apple.AppStore", "com.apple.DiskUtility", "com.apple.Spotlight",
        "com.apple.notificationcenterui"
    ]

    @MainActor
    func testNewSettingsHaveNoExclusionsAndAllowOtherSystemApps() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)

        XCTAssertTrue(model.exclusions.isEmpty)
        XCTAssertTrue(model.inclusions.isEmpty)
        for bundleID in formerDefaultBundleIDs where bundleID != "com.apple.finder" {
            XCTAssertTrue(model.shouldMonitor(bundleID: bundleID), bundleID)
        }
    }

    @MainActor
    func testFinderStaysProtectedInBothScopesIncludingSavedRules() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let finder = AppRule(bundleID: "com.apple.finder", name: "Finder",
                             path: "/System/Library/CoreServices/Finder.app")
        let selected = AppRule(bundleID: "com.example.selected", name: "Selected", path: nil)
        defaults.set(try JSONEncoder().encode([finder]), forKey: "exclusions")
        defaults.set(try JSONEncoder().encode([finder, selected]), forKey: "inclusions")
        let model = AppModel(defaults: defaults)

        XCTAssertFalse(model.shouldMonitor(bundleID: finder.bundleID))
        XCTAssertTrue(model.exclusions.isEmpty)
        model.scope = .onlyIncluded
        XCTAssertFalse(model.shouldMonitor(bundleID: finder.bundleID))
        XCTAssertTrue(model.shouldMonitor(bundleID: selected.bundleID))
        XCTAssertFalse(model.shouldMonitor(bundleID: "com.example.unselected"))
        XCTAssertEqual(model.inclusions, [selected])
        let saved = try JSONDecoder().decode([AppRule].self, from: XCTUnwrap(defaults.data(forKey: "inclusions")))
        XCTAssertEqual(saved, [selected])
    }

    @MainActor
    func testMigratesBuiltInExclusionsAndPreservesUserRulesAcrossReloads() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let builtIns = formerDefaultBundleIDs.map { AppRule(bundleID: $0, name: $0, path: nil) }
        let custom = AppRule(bundleID: "com.example.background", name: "Background", path: nil)
        let userSelectedSystemApp = AppRule(bundleID: "com.apple.DiskUtility", name: "Disk Utility",
                                           path: "/System/Applications/Utilities/Disk Utility.app")
        let userRules = [custom, userSelectedSystemApp]
        defaults.set(try JSONEncoder().encode(builtIns + userRules), forKey: "exclusions")
        let model = AppModel(defaults: defaults)

        XCTAssertEqual(model.exclusions, userRules)
        XCTAssertFalse(model.shouldMonitor(bundleID: custom.bundleID))
        XCTAssertFalse(model.shouldMonitor(bundleID: userSelectedSystemApp.bundleID))
        XCTAssertTrue(model.shouldMonitor(bundleID: "com.apple.systempreferences"))
        let saved = try JSONDecoder().decode([AppRule].self, from: XCTUnwrap(defaults.data(forKey: "exclusions")))
        XCTAssertEqual(saved, userRules)
        XCTAssertEqual(AppModel(defaults: defaults).exclusions, userRules)
    }

    @MainActor
    func testSystemAppExclusionsAddedAfterMigrationSurviveReloads() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        // A running app may have no bundle path. Its explicit rule must still persist.
        model.exclude(MonitoredApp(id: 1, name: "Disk Utility", bundleID: "com.apple.DiskUtility",
                                   path: nil, status: "", isPending: false))

        let reloaded = AppModel(defaults: defaults)
        XCTAssertEqual(reloaded.exclusions, model.exclusions)
        XCTAssertFalse(reloaded.shouldMonitor(bundleID: "com.apple.DiskUtility"))
    }

    @MainActor
    func testFinderCannotBeAddedToUserExclusions() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        model.exclude(MonitoredApp(id: 1, name: "Finder", bundleID: "com.apple.finder",
                                   path: nil, status: "", isPending: false))

        XCTAssertTrue(model.exclusions.isEmpty)
        XCTAssertFalse(model.shouldMonitor(bundleID: "com.apple.finder"))
    }

    @MainActor
    func testApplicationChoicesHideProtectedDuplicateAndAlreadySelectedApps() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let excluded = AppRule(bundleID: "com.example.excluded", name: "Excluded", path: nil)
        let included = AppRule(bundleID: "com.example.included", name: "Included", path: nil)
        let newApp = AppRule(bundleID: "com.example.new", name: "New", path: nil)
        let finder = AppRule(bundleID: "com.apple.finder", name: "Finder", path: nil)
        defaults.set(try JSONEncoder().encode([excluded]), forKey: "exclusions")
        defaults.set(try JSONEncoder().encode([included]), forKey: "inclusions")
        let model = AppModel(defaults: defaults)
        var candidates = [newApp, finder, excluded, included, newApp]
        if let ownBundleID = Bundle.main.bundleIdentifier {
            candidates.append(AppRule(bundleID: ownBundleID, name: "No Linger", path: nil))
        }

        XCTAssertEqual(model.applicationChoices(from: candidates), [included, newApp])
        model.scope = .onlyIncluded
        XCTAssertEqual(model.applicationChoices(from: candidates), [excluded, newApp])
    }

    @MainActor
    func testAddingAnAppRemovesItFromChoicesAndPersistsInTheSelectedScope() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        let app = AppRule(bundleID: "com.example.running", name: "Running", path: "/Applications/Running.app")
        var configurationChanges = 0
        model.onConfigurationChange = { configurationChanges += 1 }

        model.addApplication(app)
        model.addApplication(app)
        XCTAssertEqual(model.exclusions, [app])
        XCTAssertTrue(model.applicationChoices(from: [app]).isEmpty)
        XCTAssertEqual(configurationChanges, 1)
        XCTAssertEqual(AppModel(defaults: defaults).exclusions, [app])

        model.scope = .onlyIncluded
        XCTAssertEqual(model.applicationChoices(from: [app]), [app])
        model.addApplication(app)
        model.addApplication(app)
        XCTAssertEqual(model.inclusions, [app])
        XCTAssertEqual(model.exclusions, [app])
        XCTAssertTrue(model.applicationChoices(from: [app]).isEmpty)
        XCTAssertEqual(AppModel(defaults: defaults).inclusions, [app])
    }

    @MainActor
    func testAddingFinderIsRejectedInBothScopes() async {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(defaults: defaults)
        let finder = AppRule(bundleID: "com.apple.finder", name: "Finder", path: nil)

        model.addApplication(finder)
        model.scope = .onlyIncluded
        model.addApplication(finder)
        XCTAssertTrue(model.exclusions.isEmpty)
        XCTAssertTrue(model.inclusions.isEmpty)
    }

    @MainActor
    func testFinderSelectionAddsInstalledAppsInBothScopesWithoutDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = try makeAppBundle(in: directory, fileName: "First", bundleID: "com.example.installed",
                                        displayName: "Installed App")
        let duplicateURL = try makeAppBundle(in: directory, fileName: "Duplicate", bundleID: "com.example.installed")
        let secondURL = try makeAppBundle(in: directory, fileName: "Second", bundleID: "com.example.second")
        let finderURL = try makeAppBundle(in: directory, fileName: "Finder", bundleID: "com.apple.finder")
        let invalidURL = directory.appendingPathComponent("Missing.app")
        let expected = [
            AppRule(bundleID: "com.example.installed", name: "Installed App", path: firstURL.path),
            AppRule(bundleID: "com.example.second", name: "Second", path: secondURL.path)
        ]

        for scope in MonitorScope.allCases {
            let (defaults, suiteName) = isolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let model = AppModel(defaults: defaults)
            model.scope = scope
            model.addApplications(at: [firstURL, duplicateURL, secondURL, finderURL, invalidURL])
            model.addApplications(at: [firstURL])

            XCTAssertEqual(model.activeRules, expected)
            let reloaded = AppModel(defaults: defaults)
            XCTAssertEqual(reloaded.activeRules, expected)
            XCTAssertTrue(scope == .allExceptExcluded ? model.inclusions.isEmpty : model.exclusions.isEmpty)
        }
    }

    @MainActor
    func testRemovingAUserExclusionPersistsAnEmptyList() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let rule = AppRule(bundleID: "com.example.excluded", name: "Excluded", path: nil)
        defaults.set(try JSONEncoder().encode([rule]), forKey: "exclusions")
        let model = AppModel(defaults: defaults)
        model.removeRule(rule)

        XCTAssertTrue(model.shouldMonitor(bundleID: rule.bundleID))
        XCTAssertTrue(AppModel(defaults: defaults).exclusions.isEmpty)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "NoLinger.Tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func makeAppBundle(in directory: URL, fileName: String, bundleID: String,
                               displayName: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent("\(fileName).app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = ["CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL"]
        if let displayName { info["CFBundleDisplayName"] = displayName }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
