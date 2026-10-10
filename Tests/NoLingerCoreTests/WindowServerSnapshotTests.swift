import CoreGraphics
import XCTest
@testable import NoLingerCore

final class WindowServerSnapshotTests: XCTestCase {
    func testSublimeOffscreenResourcesDoNotBlockLastWindowQuit() throws {
        // Captured geometry after Sublime's AX list became empty: four menu-bar
        // resources and one 500 x 500 resource, all with the onscreen key omitted.
        let resources = (2115...2118).map {
            entry(id: UInt32($0), frame: CGRect(x: 0, y: 0, width: 1512, height: 33))
        } + [entry(id: 2120, frame: CGRect(x: 0, y: 482, width: 500, height: 500))]
        let document = entry(id: 3000, onscreen: true)
        let open = try XCTUnwrap(WindowServerSnapshot(entries: resources + [document], pid: 5601))
        let closed = try XCTUnwrap(WindowServerSnapshot(entries: resources, pid: 5601))
        XCTAssertEqual(open.windows, [3000])
        XCTAssertTrue(closed.windows.isEmpty)
        XCTAssertEqual(closed.ignoredOffscreenCount, 5)

        var policy = QuitPolicy()
        _ = policy.observe(.present(open.windows.count), now: 0, delay: 1)
        guard case .wait(let ticket) = policy.observe(.absent, now: 1, delay: 1) else {
            return XCTFail("Expected a quit countdown after the document closes")
        }
        XCTAssertTrue(policy.confirm(ticket, windows: .absent, now: 2))
    }

    func testOnscreenWindowsVetoQuittingAndExplicitOffscreenEntriesAreIgnored() throws {
        let snapshot = try XCTUnwrap(WindowServerSnapshot(entries: [
            entry(id: 1, onscreen: true), entry(id: 2, onscreen: false)
        ], pid: 5601))
        XCTAssertEqual(snapshot.windows, [1])
        XCTAssertEqual(snapshot.ignoredOffscreenCount, 1)
    }

    func testUnrelatedProcessesAndNonzeroLayersDoNotCount() throws {
        var unrelated = entry(id: 1, onscreen: true)
        unrelated[kCGWindowOwnerPID as String] = 42
        var overlay = entry(id: 2, onscreen: true)
        overlay[kCGWindowLayer as String] = 3
        let snapshot = try XCTUnwrap(WindowServerSnapshot(entries: [unrelated, overlay], pid: 5601))
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    func testUnavailableOrMalformedMetadataCannotAuthorizeQuitting() {
        XCTAssertNil(WindowServerSnapshot(entries: nil, pid: 5601))
        for key in [kCGWindowOwnerPID, kCGWindowLayer, kCGWindowNumber, kCGWindowBounds] {
            var malformed = entry(id: 1, onscreen: true)
            malformed.removeValue(forKey: key as String)
            XCTAssertNil(WindowServerSnapshot(entries: [malformed], pid: 5601))
        }
        var malformed = entry(id: 1, onscreen: true)
        malformed[kCGWindowIsOnscreen as String] = "unknown"
        XCTAssertNil(WindowServerSnapshot(entries: [malformed], pid: 5601))
    }

    private func entry(id: UInt32, onscreen: Bool? = nil,
                       frame: CGRect = CGRect(x: 50, y: 50, width: 800, height: 600)) -> [String: Any] {
        var result: [String: Any] = [
            kCGWindowOwnerPID as String: 5601,
            kCGWindowLayer as String: 0,
            kCGWindowNumber as String: id,
            kCGWindowBounds as String: frame.dictionaryRepresentation
        ]
        if let onscreen { result[kCGWindowIsOnscreen as String] = onscreen }
        return result
    }
}
