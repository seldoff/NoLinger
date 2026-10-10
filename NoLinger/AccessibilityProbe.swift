import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

extension Notification.Name {
    static let noLingerAccessibilityEvent = Notification.Name("NoLinger.AccessibilityEvent")
}

struct WindowInspection: Sendable {
    let windows: QuitPolicy.Windows
    let detail: String
    let diagnostics: String
    let needsRetrySoon: Bool

    init(windows: QuitPolicy.Windows, detail: String, diagnostics: String = "", needsRetrySoon: Bool = false) {
        self.windows = windows
        self.detail = detail
        self.diagnostics = diagnostics
        self.needsRetrySoon = needsRetrySoon
    }
}

/// Owns every Accessibility reference on one actor; no AX messaging blocks the UI.
actor AccessibilityProbe {
    private final class Watch {
        let session: UUID
        let pid: pid_t
        let element: AXUIElement
        var observer: AXObserver?
        var observerCreationResult = AXError.failure
        var subscriptions = AXNotificationSubscriptions()
        var windows: [AXUIElement] = []
        var destructionSubscriptions: [AXUIElement] = []

        // A PID is a value, not a pointer to an object that queued callbacks could
        // outlive. Destroyed elements no longer reliably answer AXUIElementGetPid.
        var refcon: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: Int(pid)) }
        var observerDetail: String {
            let sourceDetail: String
            if let observer {
                let source = AXObserverGetRunLoopSource(observer)
                sourceDetail = "sourceValid=\(CFRunLoopSourceIsValid(source)); scheduledDefault=\(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode)); scheduledCommon=\(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes)); observerID=\(CFHash(observer))"
            } else { sourceDetail = "source unavailable" }
            return "creation=\(observerCreationResult.rawValue); \(sourceDetail); \(subscriptions.diagnostics); trackedDestructionSubscriptions=\(destructionSubscriptions.count)"
        }
        var needsRetrySoon: Bool { observer == nil || subscriptions.needsRetry }

        init(pid: pid_t, session: UUID) {
            self.pid = pid
            self.session = session
            element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
        }

        func ensureObservation() {
            if observer == nil {
                var created: AXObserver?
                observerCreationResult = AXObserverCreate(pid, { observer, element, notification, refcon in
                    let owner = refcon.map { pid_t(Int(bitPattern: $0)) } ?? 0
                    let event = notification as String
                    let observerID = CFHash(observer)
                    let elementID = CFHash(element)
                    let onMainThread = Thread.isMainThread
                    let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()).map { $0.rawValue as String } ?? "none"
                    // Log at the C callback boundary as well as in the collection.
                    // Never query a destroyed element: only use its local identity.
                    Logger(subsystem: "com.nolinger.app", category: "AXCallback").info(
                        "Received \(event, privacy: .public) pid=\(owner) observer=\(observerID) element=\(elementID) refconPresent=\(refcon != nil) mainThread=\(onMainThread) mode=\(mode, privacy: .public)"
                    )
                    // Events only invalidate pending work and trigger fresh checks.
                    NotificationCenter.default.post(
                        name: .noLingerAccessibilityEvent,
                        object: nil,
                        userInfo: ["pid": owner, "notification": event,
                                   "observerID": observerID, "elementID": elementID,
                                   "refconPresent": refcon != nil, "mainThread": onMainThread,
                                   "runLoopMode": mode]
                    )
                }, &created)
                if observerCreationResult == .success, let created {
                    observer = created
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
                }
            }
            if let observer {
                subscriptions.registerPending { name in
                    AXObserverAddNotification(observer, element, name as CFString, refcon)
                }
            }
        }

        func stop() {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            windows.removeAll()
            destructionSubscriptions.removeAll()
        }
    }

    private var watches: [pid_t: Watch] = [:]

    func inspect(pid: pid_t, session: UUID) -> WindowInspection {
        guard !Task.isCancelled else { return .init(windows: .unknown, detail: "Check cancelled") }
        let watch: Watch
        if let existing = watches[pid], existing.session == session {
            watch = existing
        } else {
            watches.removeValue(forKey: pid)?.stop()
            watch = Watch(pid: pid, session: session)
            watches[pid] = watch
        }
        watch.ensureObservation()

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(watch.element, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let listed = value as? [AXUIElement] else {
            return .init(windows: .unknown, detail: "Window check unavailable (AX \(result.rawValue))",
                         diagnostics: "AX windows=\(result.rawValue); validArray=\(value is [AXUIElement]); observer: \(watch.observerDetail)",
                         needsRetrySoon: watch.needsRetrySoon || result == .cannotComplete)
        }

        // Do not replace our model with a Space-limited list. A missing known window
        // remains alive until its AX reference is explicitly invalid, or is reported again.
        var candidates = listed
        for old in watch.windows where !candidates.contains(where: { CFEqual($0, old) }) {
            candidates.append(old)
        }

        var alive: [AXUIElement] = []
        var uncertain = false
        var invalidCount = 0
        var roleErrors: [Int32] = []
        var notificationErrors: [Int32] = []
        for window in candidates {
            guard !Task.isCancelled else { return .init(windows: .unknown, detail: "Check cancelled") }
            AXUIElementSetMessagingTimeout(window, 0.25)
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
            if error == .invalidUIElement {
                invalidCount += 1
                continue
            }
            guard error == .success, let roleName = role as? String else {
                roleErrors.append(error.rawValue)
                uncertain = true
                alive.append(window)
                continue
            }
            guard roleName == kAXWindowRole as String else { continue }
            if !alive.contains(where: { CFEqual($0, window) }) { alive.append(window) }
            if !watch.destructionSubscriptions.contains(where: { CFEqual($0, window) }), let observer = watch.observer {
                let error = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, watch.refcon)
                if error == .success || error == .notificationAlreadyRegistered {
                    watch.destructionSubscriptions.append(window)
                } else { notificationErrors.append(error.rawValue) }
            }
        }
        watch.windows = alive
        watch.destructionSubscriptions.removeAll { subscribed in !alive.contains { CFEqual($0, subscribed) } }

        // WindowServer information is a second source. Only required, non-sensitive
        // metadata is read: no titles, images, private APIs, or capture permission.
        let catalog = Self.windowServerWindows(for: pid)
        let needsRetrySoon = watch.needsRetrySoon || notificationErrors.contains(AXError.cannotComplete.rawValue)
        let diagnostics = "AX listed=\(listed.count), retained=\(candidates.count - listed.count), alive=\(alive.count), invalid=\(invalidCount), roleErrors=\(roleErrors); WindowServer onscreen=\(catalog.map { String($0.windows.count) } ?? "unavailable"), ignoredOffscreen=\(catalog.map { String($0.ignoredOffscreenCount) } ?? "unavailable"); observer: \(watch.observerDetail); windowNotificationErrors=\(notificationErrors)"
        guard let catalog else {
            return .init(windows: .unknown, detail: "WindowServer check unavailable", diagnostics: diagnostics, needsRetrySoon: needsRetrySoon)
        }
        if !catalog.windows.isEmpty {
            return .init(windows: .present(max(alive.count, catalog.windows.count)), detail: "\(max(alive.count, catalog.windows.count)) window(s)", diagnostics: diagnostics, needsRetrySoon: needsRetrySoon)
        }
        if uncertain {
            return .init(windows: .unknown, detail: "A known window could not be verified", diagnostics: diagnostics, needsRetrySoon: needsRetrySoon)
        }
        if !alive.isEmpty {
            return .init(windows: .present(alive.count), detail: "\(alive.count) window(s)", diagnostics: diagnostics, needsRetrySoon: needsRetrySoon)
        }
        return .init(windows: .absent, detail: "No windows", diagnostics: diagnostics, needsRetrySoon: needsRetrySoon)
    }

    func remove(pid: pid_t, session: UUID) {
        guard watches[pid]?.session == session else { return }
        watches.removeValue(forKey: pid)?.stop()
    }

    func stop() {
        for watch in watches.values { watch.stop() }
        watches.removeAll()
    }

    private static func windowServerWindows(for pid: pid_t) -> WindowServerSnapshot? {
        let entries = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        return WindowServerSnapshot(entries: entries, pid: pid)
    }
}
