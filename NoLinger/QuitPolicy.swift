import Foundation

/// Independent of macOS so the rules governing a quit can be tested deterministically.
struct QuitPolicy: Sendable {
    enum Windows: Equatable, Sendable {
        case present(Int)
        case absent
        case unknown
    }

    struct Ticket: Equatable, Sendable {
        let generation: UInt64
        let deadline: TimeInterval
    }

    enum Decision: Equatable, Sendable {
        case idle
        case wait(Ticket)
        case verify(Ticket)
    }

    private(set) var hasSeenWindow = false
    private(set) var pending: Ticket?
    private(set) var quitWasRequested = false
    private var generation: UInt64 = 0

    mutating func cancel(resetHistory: Bool = false) {
        generation &+= 1
        pending = nil
        if resetHistory {
            hasSeenWindow = false
            quitWasRequested = false
        }
    }

    mutating func observe(_ windows: Windows, now: TimeInterval, delay: TimeInterval) -> Decision {
        switch windows {
        case .present:
            hasSeenWindow = true
            quitWasRequested = false
            cancel()
            return .idle
        case .unknown:
            // A failed check is not proof that a window closed.
            cancel()
            return .idle
        case .absent:
            guard hasSeenWindow, !quitWasRequested else { return .idle }
            let ticket = pending ?? Ticket(generation: generation, deadline: now + max(0, delay))
            pending = ticket
            return now >= ticket.deadline ? .verify(ticket) : .wait(ticket)
        }
    }

    /// Only a fresh, successful check can redeem the current ticket once.
    mutating func confirm(_ ticket: Ticket, windows: Windows, now: TimeInterval) -> Bool {
        guard pending == ticket, ticket.generation == generation,
              now >= ticket.deadline, !quitWasRequested else { return false }
        switch windows {
        case .absent:
            quitWasRequested = true
            cancel()
            return true
        case .present:
            _ = observe(windows, now: now, delay: 0)
        case .unknown:
            cancel()
        }
        return false
    }
}
