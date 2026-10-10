import XCTest
@testable import NoLingerCore

final class QuitPolicyTests: XCTestCase {
    func testNeverQuitsAnAppWithoutAnObservedWindow() {
        var policy = QuitPolicy()
        XCTAssertEqual(policy.observe(.absent, now: 0, delay: 2), .idle)
        XCTAssertEqual(policy.observe(.absent, now: 100, delay: 2), .idle)
        XCTAssertNil(policy.pending)
    }

    func testWaitsFullDelayAndRequiresFreshConfirmation() {
        var policy = armedPolicy()
        guard case .wait(let ticket) = policy.observe(.absent, now: 10, delay: 2) else {
            return XCTFail("Expected a delay")
        }
        XCTAssertEqual(ticket.deadline, 12)
        XCTAssertFalse(policy.confirm(ticket, windows: .absent, now: 11.9))
        XCTAssertEqual(policy.observe(.absent, now: 12, delay: 2), .verify(ticket))
        XCTAssertTrue(policy.confirm(ticket, windows: .absent, now: 12))
        XCTAssertFalse(policy.confirm(ticket, windows: .absent, now: 12))
    }

    func testReopeningAWindowCancelsOldTimerAndStartsAFreshDelay() {
        var policy = armedPolicy()
        let old = waitingTicket(&policy, at: 0)
        _ = policy.observe(.present(1), now: 1, delay: 2)
        let fresh = waitingTicket(&policy, at: 1.8)
        XCTAssertEqual(fresh.deadline, 3.8)
        XCTAssertFalse(policy.confirm(old, windows: .absent, now: 2))
        XCTAssertFalse(policy.confirm(fresh, windows: .absent, now: 2))
        XCTAssertTrue(policy.confirm(fresh, windows: .absent, now: 3.8))
    }

    func testUnknownCheckCancelsCountdownInsteadOfCountingAsZero() {
        var policy = armedPolicy()
        let old = waitingTicket(&policy, at: 0)
        _ = policy.observe(.unknown, now: 1, delay: 2)
        XCTAssertNil(policy.pending)
        XCTAssertFalse(policy.confirm(old, windows: .absent, now: 10))
        let fresh = waitingTicket(&policy, at: 10)
        XCTAssertEqual(fresh.deadline, 12)
    }

    func testFailedFinalVerificationDoesNotQuit() {
        for state in [QuitPolicy.Windows.unknown, .present(1)] {
            var policy = armedPolicy()
            let ticket = waitingTicket(&policy, at: 0)
            XCTAssertFalse(policy.confirm(ticket, windows: state, now: 2))
            XCTAssertNil(policy.pending)
        }
    }

    func testDoesNotRepeatedlyAskAnAppThatDeclinedToQuit() {
        var policy = armedPolicy()
        let ticket = waitingTicket(&policy, at: 0)
        XCTAssertTrue(policy.confirm(ticket, windows: .absent, now: 2))
        XCTAssertEqual(policy.observe(.absent, now: 100, delay: 2), .idle)
        XCTAssertTrue(policy.quitWasRequested)
        _ = policy.observe(.present(1), now: 101, delay: 2)
        let next = waitingTicket(&policy, at: 102)
        XCTAssertTrue(policy.confirm(next, windows: .absent, now: 104))
    }

    func testPauseSpaceSleepAndRuleChangesInvalidateHistoryAndTickets() {
        var policy = armedPolicy()
        let old = waitingTicket(&policy, at: 0)
        policy.cancel(resetHistory: true)
        XCTAssertFalse(policy.confirm(old, windows: .absent, now: 10))
        XCTAssertEqual(policy.observe(.absent, now: 10, delay: 2), .idle)
        _ = policy.observe(.present(1), now: 11, delay: 2)
        XCTAssertNotNil(waitingTicket(&policy, at: 12))
    }

    func testWindowEventsInvalidateAnInFlightConfirmation() {
        var policy = armedPolicy()
        let old = waitingTicket(&policy, at: 0)
        // Even if the new window closes before a scan completes, this old result
        // must never be allowed to redeem its former ticket.
        policy.cancel()
        XCTAssertFalse(policy.confirm(old, windows: .absent, now: 2))
        let fresh = waitingTicket(&policy, at: 2)
        XCTAssertEqual(fresh.deadline, 4)
    }

    func testRecoveredMissingEventStillWaitsBeforeQuitting() {
        var policy = armedPolicy()
        // The recovery scan notices zero, rather than a destruction callback.
        let ticket = waitingTicket(&policy, at: 10)
        XCTAssertFalse(policy.confirm(ticket, windows: .absent, now: 10))
        XCTAssertTrue(policy.confirm(ticket, windows: .absent, now: 12))
    }

    func testPositiveWindowEvidenceVetoesAQuit() {
        var policy = armedPolicy()
        let ticket = waitingTicket(&policy, at: 0)
        // The probe maps a positive result from EITHER window source to .present.
        XCTAssertFalse(policy.confirm(ticket, windows: .present(1), now: 2))
        XCTAssertFalse(policy.quitWasRequested)
    }

    private func armedPolicy() -> QuitPolicy {
        var policy = QuitPolicy()
        _ = policy.observe(.present(1), now: 0, delay: 2)
        return policy
    }

    private func waitingTicket(_ policy: inout QuitPolicy, at time: Double) -> QuitPolicy.Ticket {
        guard case .wait(let ticket) = policy.observe(.absent, now: time, delay: 2) else {
            XCTFail("Expected a pending quit")
            return .init(generation: 0, deadline: -1)
        }
        return ticket
    }
}
