import Foundation
import XCTest
@testable import NoLingerCore

final class LogCollectionTests: XCTestCase {
    @MainActor
    func testCollectionIsOptInAndDoesNotChangeQuitSettings() async throws {
        let (model, defaults, suite, directory) = makeModel()
        defer { cleanUp(defaults: defaults, suite: suite, directory: directory) }
        model.isPaused = true
        model.delay = 4
        model.scope = .onlyIncluded
        var configurationChanges = 0
        model.onConfigurationChange = { configurationChanges += 1 }
        model.diagnosticLog("Before collection")
        XCTAssertFalse(model.isCollectingLogs)
        XCTAssertFalse(model.canAccessCollectedLogs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        model.setCollectLogs(true)
        XCTAssertTrue(model.isCollectingLogs)
        XCTAssertTrue(model.canAccessCollectedLogs)
        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.delay, 4)
        XCTAssertEqual(model.scope, .onlyIncluded)
        XCTAssertFalse(AppModel(defaults: defaults, logDirectory: directory).isCollectingLogs)
        let contents = try String(contentsOf: XCTUnwrap(model.collectedLogURL), encoding: .utf8)
        XCTAssertTrue(contents.contains("Log collection started"))
        XCTAssertTrue(contents.contains("Paused=true; delay=4.0s; scope=onlyIncluded"))
        XCTAssertFalse(contents.contains("Before collection"))
        model.setCollectLogs(false)
        XCTAssertEqual(configurationChanges, 0)
        XCTAssertFalse(model.canAccessCollectedLogs)
        XCTAssertNil(model.collectedLogURL)
    }

    @MainActor
    func testDisablingDeletesCurrentLogDisablesAccessAndPreservesExportedCopy() async throws {
        let (model, defaults, suite, directory) = makeModel()
        defer { cleanUp(defaults: defaults, suite: suite, directory: directory) }
        model.setCollectLogs(true)
        let source = try XCTUnwrap(model.collectedLogURL)
        for index in 0..<100 { model.diagnosticLog("Event message \(index).", category: "event") }
        model.diagnosticLog("AX=0; WindowServer=0", category: "windows")
        let exported = directory.appendingPathComponent("export.log")
        try model.exportCollectedLogs(to: exported)
        XCTAssertTrue(model.isCollectingLogs)
        let contents = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(contents.contains("[event] Event message 0."))
        XCTAssertTrue(contents.contains("[event] Event message 99."))
        XCTAssertTrue(contents.contains("[windows] AX=0; WindowServer=0"))
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: exported))

        let saved = try Data(contentsOf: exported)
        model.setCollectLogs(false)
        XCTAssertFalse(model.isCollectingLogs)
        XCTAssertFalse(model.canAccessCollectedLogs)
        XCTAssertNil(model.collectedLogURL)
        XCTAssertNil(model.logCollectionMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        model.diagnosticLog("After stopping")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        try model.exportCollectedLogs(to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), saved)
        try model.exportCollectedLogs(to: source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        model.setCollectLogs(false)
        XCTAssertNil(model.logCollectionMessage)
    }

    @MainActor
    func testReenablingStartsANewFileAndCallsSnapshotOncePerCollection() async throws {
        let (model, defaults, suite, directory) = makeModel()
        defer { cleanUp(defaults: defaults, suite: suite, directory: directory) }
        var snapshots = 0
        model.onLogCollectionStarted = {
            snapshots += 1
            model.diagnosticLog("Monitor snapshot")
        }
        model.setCollectLogs(true)
        model.setCollectLogs(true)
        let first = try XCTUnwrap(model.collectedLogURL)
        model.setCollectLogs(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        model.setCollectLogs(true)
        let second = try XCTUnwrap(model.collectedLogURL)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(snapshots, 2)
        XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains("Monitor snapshot"))
        model.setCollectLogs(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor
    func testCreationFailureIsVisibleAndLeavesAutomaticQuittingUnchanged() async throws {
        let (model, defaults, suite, directory) = makeModel()
        defer { cleanUp(defaults: defaults, suite: suite, directory: directory) }
        try Data("Not a directory".utf8).write(to: directory)
        model.setCollectLogs(true)
        XCTAssertFalse(model.isCollectingLogs)
        XCTAssertTrue(model.logCollectionMessage?.hasPrefix("Log collection stopped:") == true)
        XCTAssertNil(model.collectedLogURL)
        XCTAssertFalse(model.canAccessCollectedLogs)
        XCTAssertFalse(model.isPaused)
    }

    @MainActor
    func testCollectorBoundsFileSizeAndEscapesMultilineMessages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collector = DiagnosticLog(directory: directory, maximumBytes: 256)
        let source = try collector.start()
        try collector.append("First\nSecond\rThird", category: "event")
        XCTAssertThrowsError(try collector.append(String(repeating: "x", count: 256), category: "windows"))
        try collector.stop()
        let contents = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(contents.contains("First\\nSecond\\rThird"))
        XCTAssertEqual(contents.split(separator: "\n").count, 1)
        XCTAssertLessThanOrEqual(try Data(contentsOf: source).count, 256)
    }

    @MainActor
    func testSizeLimitStopsCollectionRemovesLogAndAllowsRestart() async throws {
        let (model, defaults, suite, directory) = makeModel()
        defer { cleanUp(defaults: defaults, suite: suite, directory: directory) }
        model.setCollectLogs(true)
        model.diagnosticLog("Before the limit")
        let first = try XCTUnwrap(model.collectedLogURL)
        model.diagnosticLog(String(repeating: "x", count: 10 * 1024 * 1024))
        XCTAssertFalse(model.isCollectingLogs)
        XCTAssertTrue(model.logCollectionMessage?.contains("10 MB limit") == true)
        XCTAssertFalse(model.isPaused)
        XCTAssertFalse(model.canAccessCollectedLogs)
        XCTAssertNil(model.collectedLogURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        model.setCollectLogs(true)
        XCTAssertTrue(model.isCollectingLogs)
        XCTAssertTrue(model.canAccessCollectedLogs)
        XCTAssertNil(model.logCollectionMessage)
        XCTAssertNotEqual(model.collectedLogURL, first)
        model.setCollectLogs(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    @MainActor
    private func makeModel() -> (AppModel, UserDefaults, String, URL) {
        let suite = "NoLinger.LogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (AppModel(defaults: defaults, logDirectory: directory), defaults, suite, directory)
    }

    private func cleanUp(defaults: UserDefaults, suite: String, directory: URL) {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
