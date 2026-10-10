# No Linger

A native macOS menu bar app that requests a normal quit when an app's last window closes. Requires an Apple Silicon Mac running macOS 14 or later. It has no third-party dependencies.

## Run

1. Open `NoLinger.xcodeproj` in Xcode, choose the NoLinger scheme, and run.
2. In No Linger’s **General → Permission and privacy**, click **Grant Access** and enable No Linger in **System Settings → Privacy & Security → Device Control and Data Access** on macOS 27 or later, or **Accessibility** on older macOS versions. No Linger notices the change without requiring a restart.
3. By default, all regular desktop apps are monitored except the system exclusions. Add apps that should keep running under **Apps**. An optional include-only mode has its own separate list.
4. Close an eligible app's last window. No Linger waits two seconds by default and requests a normal quit after another window check. Opening another window cancels the wait.

No Linger appears in the Dock while its settings window is open, including when minimized. Closing the window removes its Dock icon and leaves the menu bar app running. If you hide its menu bar icon, open No Linger again from Applications or Spotlight to bring Settings back. Quit No Linger from its menu or settings window.

Launch at login uses Apple's `SMAppService`. Enable it after placing a signed build in a stable location such as `/Applications`; macOS may require approval in Login Items.

## If access is enabled but No Linger still asks for permission

macOS authorizes a signed app identity. An enabled No Linger entry can belong to another copy or an earlier build with a different signature. In **Permission and privacy**, choose **Show This Copy in Finder**, remove the stale No Linger entry in System Settings, and add the revealed app. Enable access, return to No Linger, and choose **Check Again** if needed. Permission is also checked every three seconds and immediately when Settings opens or the app becomes active.

Use the same Apple Development certificate for local builds. The project uses your existing team and this certificate type; avoid overriding it with ad hoc signing (`CODE_SIGN_IDENTITY=-`), which can invalidate grants when the app changes. Public distribution should use Developer ID signing and notarization.

## Detection and safeguards

The underlying Accessibility APIs provide window access on all supported versions. The permission pane is called Device Control and Data Access on macOS 27 and later.

- Accessibility notifications trigger checks after a short settling period and one follow-up check; a ten-second reconciliation recovers missed notifications and discovers apps whose activation policy changed.
- AX messaging runs on an actor, with bounded per-element timeouts, rather than on the main UI thread.
- Known Accessibility window references are retained across scans. A window missing from the current list is still counted until its reference becomes explicitly invalid. Minimized and hidden windows remain windows.
- A fresh public WindowServer catalog (`CGWindowListCopyWindowInfo` with `optionAll`) supplies an independent veto for ordinary offscreen windows. Any positive window evidence keeps the app running.
- Only a successful empty Accessibility check AND a successful empty WindowServer check permit a quit. A failed or ambiguous check cancels the countdown.
- Every window event, pause, rule edit, sleep, session change, and Space transition invalidates pending work. Wake and Space transitions allow three seconds to settle before establishing a fresh baseline.
- Each process must first have an observed window. Apps already running without windows at startup are left alone.
- A confirmation ticket is tied to the current countdown generation and process session. An old timer or background result cannot authorize a new quit.
- No force quitting. If a quit request is declined or the app stays running without windows, No Linger leaves it alone until it observes another window lifecycle.

No Linger reads only local window metadata and Accessibility roles. It does not read window titles, capture images, record the screen, or make network requests. Screen Recording permission is not required for the metadata used here. App rules match bundle IDs, so moving an app does not change its rule.

App Sandbox is disabled intentionally: Apple's `NSRunningApplication.terminate()` cannot quit other apps from a sandboxed app. Hardened Runtime remains enabled. The project keeps your existing signing team.

## Build and test

```sh
xcodebuild -project NoLinger.xcodeproj -scheme NoLinger \
  -configuration Debug -derivedDataPath build build
swift test
```

The Swift package tests the independent `QuitPolicy` state machine. Tests cover the full delay, fresh confirmation, reopened windows, stale tickets, failed checks, lifecycle resets, missed-event recovery, and suppression of repeated quit requests.

Debug builds accept `--preview` to display Settings and check real permission status without observing windows or quitting apps. Both configurations accept `--settings` to show Settings on launch.

## Manual validation with window access enabled

Use a disposable document in an app such as TextEdit. Never use unsaved work for a smoke test.

1. Close one of two windows: the app remains running. Close the last: one normal quit request follows the delay.
2. Open another window during the delay, then close it: a new full delay begins.
3. Minimize a window, hide the app, or place a window on another Desktop: the app stays running.
4. Enter or leave full-screen mode, switch Spaces, sleep/wake, and pause/resume: stale pending quits are cancelled.
5. Exclude an app during its countdown: it stays running. Include-only mode monitors only the selected apps.
6. Cancel a target app's quit prompt: No Linger does not repeatedly request quitting while that app remains windowless.
7. Revoke window access (Device Control and Data Access on macOS 27+, Accessibility on older versions) while a quit is pending: no subsequent quit is authorized.

External monitoring cannot make the check and another app's window creation atomic. Unusual applications can expose incomplete Accessibility data or persistent helper windows. No Linger deliberately favors leaving an app running when evidence is uncertain; runtime validation across the apps and macOS versions you use is still necessary.
