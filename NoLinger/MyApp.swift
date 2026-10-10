import AppKit
import SwiftUI
import Combine

@main
@MainActor
enum NoLingerApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private lazy var monitor = AutoQuitMonitor(model: model)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var modelSubscription: AnyCancellable?
    private var isQuitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
        modelSubscription = model.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.updateStatusItem() }
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            // Visual QA without observing or quitting any other applications.
            monitor.start(preview: true)
            updateStatusItem()
            openSettings()
            return
        }
        #endif

        monitor.start()
        updateStatusItem()
        if !model.accessibilityGranted || ProcessInfo.processInfo.arguments.contains("--settings") {
            openSettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshLoginStatus()
        monitor.refreshPermission()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateNow }
        isQuitting = true
        Task {
            await monitor.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelSubscription?.cancel()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    @objc func openSettings() {
        monitor.refreshPermission()
        if settingsWindow == nil {
            let view = ContentView(model: model, onGrantAccess: { [weak self] in self?.monitor.openAccessibilitySettings() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "No Linger"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 710, height: 640))
            window.minSize = NSSize(width: 660, height: 590)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("NoLingerSettings")
            window.center()
            settingsWindow = window
        }
        guard let settingsWindow else { return }
        NSApp.setActivationPolicy(.regular)
        if settingsWindow.isMiniaturized { settingsWindow.deminiaturize(nil) }
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow, !isQuitting else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func togglePause() { model.isPaused.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func updateStatusItem() {
        // Keep a way into settings when Accessibility has not yet been granted.
        if model.hideMenuBarIcon && model.accessibilityGranted {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let symbol = NSImage(systemSymbolName: "door.left.hand.open", accessibilityDescription: "No Linger")
            statusItem?.button?.image = symbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            )
        }
        statusItem?.button?.appearsDisabled = model.isPaused
        let menu = NSMenu()
        menu.addItem(item(model.isPaused ? "Resume" : "Pause", action: #selector(togglePause)))
        menu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit No Linger", action: #selector(quit), key: "q"))
        statusItem?.menu = menu
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "No Linger")
        appMenu.addItem(item("Settings…", action: #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit No Linger", action: #selector(quit), key: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
