import ApplicationServices
import XCTest
@testable import NoLingerCore

final class AXNotificationSubscriptionsTests: XCTestCase {
    func testLaunchTimeMessagingFailureIsRetriedUntilSubscriptionsSucceed() {
        var subscriptions = AXNotificationSubscriptions(names: ["created", "mainChanged"])
        var calls: [String] = []
        subscriptions.registerPending { name in calls.append(name); return .cannotComplete }
        XCTAssertTrue(subscriptions.needsRetry)
        XCTAssertTrue(subscriptions.diagnostics.contains("-25204"))
        subscriptions.registerPending { name in calls.append(name); return .success }
        XCTAssertFalse(subscriptions.needsRetry)
        subscriptions.registerPending { name in calls.append(name); return .success }
        XCTAssertEqual(calls, ["created", "mainChanged", "created", "mainChanged"])
    }

    func testPartialFailureOnlyRetriesTheFailedSubscription() {
        var subscriptions = AXNotificationSubscriptions(names: ["created", "mainChanged"])
        subscriptions.registerPending { $0 == "created" ? .success : .cannotComplete }
        var retried: [String] = []
        subscriptions.registerPending { name in retried.append(name); return .notificationAlreadyRegistered }
        XCTAssertEqual(retried, ["mainChanged"])
        XCTAssertFalse(subscriptions.needsRetry)
    }

    func testUnsupportedNotificationsDoNotCauseRapidRetryLoops() {
        var subscriptions = AXNotificationSubscriptions(names: ["unsupported"])
        subscriptions.registerPending { _ in .notificationUnsupported }
        XCTAssertFalse(subscriptions.needsRetry)
        subscriptions.registerPending { _ in XCTFail("Unsupported notification should not be retried"); return .success }
    }

    func testEachRelaunchedProcessGetsFreshSubscriptions() {
        for _ in 0..<3 {
            var subscriptions = AXNotificationSubscriptions()
            XCTAssertTrue(subscriptions.needsRetry)
            subscriptions.registerPending { _ in .cannotComplete }
            XCTAssertTrue(subscriptions.needsRetry)
            var count = 0
            subscriptions.registerPending { _ in count += 1; return .success }
            XCTAssertEqual(count, AXNotificationSubscriptions.applicationNotifications.count)
            XCTAssertFalse(subscriptions.needsRetry)
        }
    }
}
