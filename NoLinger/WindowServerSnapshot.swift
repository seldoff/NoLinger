import Foundation
import CoreGraphics

/// WindowServer keeps offscreen resources even after an app's last window closes.
/// Only onscreen entries independently veto quitting; retained AX references cover
/// minimized, hidden, and other-Space windows.
struct WindowServerSnapshot: Sendable {
    let windows: Set<CGWindowID>
    let ignoredOffscreenCount: Int

    init?(entries: [[String: Any]]?, pid: Int32) {
        guard let entries else { return nil }
        var windows: Set<CGWindowID> = []
        var ignoredOffscreenCount = 0
        for entry in entries {
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
            guard owner.int32Value == pid else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? NSNumber else { return nil }
            guard layer.intValue == 0 else { continue }
            guard let id = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            guard frame.width > 1, frame.height > 1 else { continue }

            // Offscreen entries commonly omit this optional key altogether.
            let onscreen: Bool
            if let value = entry[kCGWindowIsOnscreen as String] {
                guard let visibility = value as? Bool else { return nil }
                onscreen = visibility
            } else {
                onscreen = false
            }
            if onscreen { windows.insert(id.uint32Value) }
            else { ignoredOffscreenCount += 1 }
        }
        self.windows = windows
        self.ignoredOffscreenCount = ignoredOffscreenCount
    }
}
