import AppKit
import ApplicationServices
import CoreGraphics

extension Notification.Name {
    static let noLingerAccessibilityEvent = Notification.Name("NoLinger.AccessibilityEvent")
}

struct WindowInspection: Sendable {
    let windows: QuitPolicy.Windows
    let detail: String
    let diagnostics: String

    init(windows: QuitPolicy.Windows, detail: String, diagnostics: String = "") {
        self.windows = windows
        self.detail = detail
        self.diagnostics = diagnostics
    }
}

/// Owns every Accessibility reference on one actor; no AX messaging blocks the UI.
actor AccessibilityProbe {
    private final class Watch {
        let session: UUID
        let element: AXUIElement
        let observer: AXObserver?
        let observerDetail: String
        var windows: [AXUIElement] = []

        init(pid: pid_t, session: UUID) {
            self.session = session
            element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            var created: AXObserver?
            let result = AXObserverCreate(pid, { _, element, notification, _ in
                var owner: pid_t = 0
                guard AXUIElementGetPid(element, &owner) == .success else { return }
                // No unmanaged refcon: queued callbacks cannot refer to freed Swift objects.
                NotificationCenter.default.post(
                    name: .noLingerAccessibilityEvent,
                    object: nil,
                    userInfo: ["pid": owner, "notification": notification as String]
                )
            }, &created)
            observer = result == .success ? created : nil
            var registrations: [String] = []
            if let observer {
                for name in [kAXWindowCreatedNotification, kAXMainWindowChangedNotification] {
                    let error = AXObserverAddNotification(observer, element, name as CFString, nil)
                    registrations.append("\(name)=\(error.rawValue)")
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            observerDetail = "creation=\(result.rawValue); registrations=\(registrations)"
        }

        func stop() {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            windows.removeAll()
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

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(watch.element, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let listed = value as? [AXUIElement] else {
            return .init(windows: .unknown, detail: "Window check unavailable (AX \(result.rawValue))",
                         diagnostics: "AX windows=\(result.rawValue); validArray=\(value is [AXUIElement]); observer: \(watch.observerDetail)")
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
            if !watch.windows.contains(where: { CFEqual($0, window) }), let observer = watch.observer {
                let error = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, nil)
                if error != .success { notificationErrors.append(error.rawValue) }
            }
        }
        watch.windows = alive

        // WindowServer information is a second source. Only required, non-sensitive
        // metadata is read: no titles, images, private APIs, or capture permission.
        let catalog = Self.windowServerWindows(for: pid)
        let diagnostics = "AX listed=\(listed.count), retained=\(candidates.count - listed.count), alive=\(alive.count), invalid=\(invalidCount), roleErrors=\(roleErrors); WindowServer=\(catalog.map { String($0.count) } ?? "unavailable"); observer: \(watch.observerDetail); windowNotificationErrors=\(notificationErrors)"
        guard let catalog else {
            return .init(windows: .unknown, detail: "WindowServer check unavailable", diagnostics: diagnostics)
        }
        if !catalog.isEmpty {
            return .init(windows: .present(max(alive.count, catalog.count)), detail: "\(max(alive.count, catalog.count)) window(s)", diagnostics: diagnostics)
        }
        if uncertain {
            return .init(windows: .unknown, detail: "A known window could not be verified", diagnostics: diagnostics)
        }
        if !alive.isEmpty {
            return .init(windows: .present(alive.count), detail: "\(alive.count) window(s)", diagnostics: diagnostics)
        }
        return .init(windows: .absent, detail: "No windows", diagnostics: diagnostics)
    }

    func remove(pid: pid_t, session: UUID) {
        guard watches[pid]?.session == session else { return }
        watches.removeValue(forKey: pid)?.stop()
    }

    func stop() {
        for watch in watches.values { watch.stop() }
        watches.removeAll()
    }

    private static func windowServerWindows(for pid: pid_t) -> Set<CGWindowID>? {
        guard let entries = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        var windows: Set<CGWindowID> = []
        for entry in entries {
            // These are required keys. Missing data makes the whole decision uncertain.
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber else { return nil }
            guard owner.int32Value == pid, layer.intValue == 0 else { continue }
            guard let id = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            if frame.width > 1, frame.height > 1 { windows.insert(id.uint32Value) }
        }
        return windows
    }
}
