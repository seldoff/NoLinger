import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class AutoQuitMonitor: NSObject {
    private final class Record {
        let app: NSRunningApplication
        let session = UUID()
        var policy = QuitPolicy()
        var revision: UInt64 = 0
        var scanTask: Task<Void, Never>?
        var eventTask: Task<Void, Never>?
        var quitTask: Task<Void, Never>?
        var scheduledTicket: QuitPolicy.Ticket?
        var status = "Checking…"

        init(app: NSRunningApplication) { self.app = app }

        func cancel(resetHistory: Bool) {
            revision &+= 1
            scanTask?.cancel()
            scanTask = nil
            eventTask?.cancel()
            eventTask = nil
            quitTask?.cancel()
            quitTask = nil
            scheduledTicket = nil
            policy.cancel(resetHistory: resetHistory)
        }
    }

    private let model: AppModel
    private let probe = AccessibilityProbe()
    private var records: [pid_t: Record] = [:]
    private var permissionTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var isSleeping = false
    private var isSessionActive = true
    private var settleUntil: TimeInterval = 0
    private var isRunning = false
    private var isPreview = false

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var canMonitor: Bool {
        isRunning && !isPreview && model.accessibilityGranted && !model.isPaused && !isSleeping
            && isSessionActive && now >= settleUntil
    }

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func start(preview: Bool = false) {
        guard !isRunning else { return }
        isRunning = true
        isPreview = preview
        model.onLogCollectionStarted = { [weak self] in self?.logSnapshot() }
        model.diagnosticLog("Monitor started; preview=\(preview)", category: "lifecycle")
        if preview {
            // Read real permission state, without observing windows or quitting apps.
            refreshPermission()
            observePermissionChanges()
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityEvent(_:)), name: .noLingerAccessibilityEvent, object: nil)
        model.onConfigurationChange = { [weak self] in self?.configurationChanged() }
        refreshPermission()
        reconcileApps()

        observePermissionChanges()
        recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
                guard let self else { break }
                self.reconcileApps()
                guard self.canMonitor else { continue }
                for pid in self.records.keys { self.scan(pid, reason: "recovery") }
            }
        }
    }

    private func observePermissionChanges() {
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                self?.refreshPermission()
            }
        }
    }

    func stop() async {
        model.diagnosticLog("Monitor stopping; cancelling all pending work", category: "lifecycle")
        isRunning = false
        permissionTask?.cancel()
        recoveryTask?.cancel()
        settleTask?.cancel()
        model.onConfigurationChange = nil
        model.onLogCollectionStarted = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        for record in records.values { record.cancel(resetHistory: true) }
        records.removeAll()
        await probe.stop()
    }

    func refreshPermission() {
        let granted = AXIsProcessTrusted()
        guard granted != model.accessibilityGranted else { updateServiceStatus(); return }
        model.diagnosticLog("Window access changed: \(granted)", category: "permission")
        model.accessibilityGranted = granted
        cancelAll(resetHistory: true)
        if granted {
            model.diagnosticLog(isPreview ? "\(model.windowAccessPermissionName) granted."
                                : "\(model.windowAccessPermissionName) granted. Monitoring started.", category: "permission")
            reconcileApps()
            for pid in records.keys { scan(pid) }
        } else {
            model.diagnosticLog("\(model.windowAccessPermissionName) unavailable. Auto-quit is disabled.", category: "permission")
            let old = records
            records.removeAll()
            for (pid, record) in old {
                Task { await probe.remove(pid: pid, session: record.session) }
            }
        }
        publishApps()
        updateServiceStatus()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func configurationChanged() {
        model.diagnosticLog("Configuration changed; invalidating window history and pending quits")
        // Pause, delay edits, and rule changes invalidate every outstanding result.
        cancelAll(resetHistory: true)
        reconcileApps()
        if canMonitor { for pid in records.keys { scan(pid) } }
        updateServiceStatus()
    }

    @objc private func appsChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        model.diagnosticLog("\(notification.name.rawValue): \(app?.localizedName ?? "unknown") [\(app?.bundleIdentifier ?? "unknown")] pid=\(app?.processIdentifier ?? 0)", category: "workspace")
        reconcileApps()
    }

    private func reconcileApps() {
        guard isRunning, !isPreview else { return }
        var eligible: [pid_t: NSRunningApplication] = [:]
        if model.accessibilityGranted {
            for app in NSWorkspace.shared.runningApplications {
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      app.activationPolicy == .regular, !app.isTerminated,
                      let bundleID = app.bundleIdentifier, model.shouldMonitor(bundleID: bundleID) else { continue }
                eligible[app.processIdentifier] = app
            }
        }
        for pid in Array(records.keys) {
            let record = records[pid]!
            let candidate = eligible[pid]
            // A recycled PID must never inherit another process's window history.
            let wasReplaced = candidate != nil && (record.app.isTerminated || record.app.launchDate != candidate?.launchDate)
            guard candidate == nil || wasReplaced else { continue }
            if let record = records.removeValue(forKey: pid) {
                model.diagnosticLog("Stopped monitoring \(identity(record)); replaced=\(wasReplaced)")
                record.cancel(resetHistory: true)
                Task { await probe.remove(pid: pid, session: record.session) }
            }
        }
        for (pid, app) in eligible where records[pid] == nil {
            let record = Record(app: app)
            records[pid] = record
            model.diagnosticLog("Started monitoring \(identity(record))")
            if canMonitor { scan(pid) }
        }
        publishApps()
        updateServiceStatus()
    }

    @objc private func accessibilityEvent(_ notification: Notification) {
        guard let pid = notification.userInfo?["pid"] as? pid_t,
              let record = records[pid] else { return }
        let event = notification.userInfo?["notification"] as? String ?? "unknown"
        model.diagnosticLog("\(event): \(identity(record)); monitoring=\(canMonitor); pending=\(String(describing: record.policy.pending))", category: "accessibility")
        guard canMonitor else { return }
        // Every window event invalidates a queued confirmation, including a window
        // that opens and closes entirely between our ten-second recovery scans.
        record.cancel(resetHistory: false)
        let revision = record.revision
        record.eventTask = Task { [weak self, weak record] in
            // AX and WindowServer do not update atomically. Let an event burst settle,
            // then recheck once so a briefly stale catalog does not defer work 10s.
            for seconds in [0.15, 0.8] {
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                guard !Task.isCancelled, let self, let record, self.canMonitor,
                      self.records[pid] === record, record.revision == revision else { return }
                self.scan(pid, reason: "accessibility event")
            }
            record?.eventTask = nil
        }
    }

    private func scan(_ pid: pid_t, reason: String = "refresh") {
        guard canMonitor, let record = records[pid], record.scanTask == nil else { return }
        let revision = record.revision
        let session = record.session
        record.scanTask = Task { [weak self, weak record, probe] in
            let inspection = await probe.inspect(pid: pid, session: session)
            guard let self, let record else { return }
            guard !Task.isCancelled, self.records[pid] === record,
                  record.revision == revision, self.canMonitor else {
                self.model.diagnosticLog("Discarded stale \(reason) check for \(self.identity(record)); revision=\(revision)")
                return
            }
            record.scanTask = nil
            self.logInspection(inspection, record: record, phase: reason)
            let decision = record.policy.observe(inspection.windows, now: self.now, delay: self.model.delay)
            self.model.diagnosticLog("\(self.identity(record)): decision=\(decision); hasSeenWindow=\(record.policy.hasSeenWindow); quitWasRequested=\(record.policy.quitWasRequested)", category: "decision")
            self.apply(decision, pid: pid, record: record, inspection: inspection)
        }
    }

    private func apply(_ decision: QuitPolicy.Decision, pid: pid_t, record: Record, inspection: WindowInspection) {
        switch decision {
        case .idle:
            record.quitTask?.cancel()
            record.quitTask = nil
            record.scheduledTicket = nil
            record.status = record.policy.quitWasRequested ? "Kept running after quit request" : inspection.detail
        case .wait(let ticket):
            record.status = "Quitting in \(String(format: "%.1f", max(0, ticket.deadline - now)))s"
            if record.scheduledTicket != ticket { scheduleConfirmation(ticket, pid: pid, record: record) }
        case .verify(let ticket):
            if record.scheduledTicket != ticket { scheduleConfirmation(ticket, pid: pid, record: record) }
        }
        publishApps()
    }

    private func scheduleConfirmation(_ ticket: QuitPolicy.Ticket, pid: pid_t, record: Record) {
        record.quitTask?.cancel()
        record.scheduledTicket = ticket
        let session = record.session
        let revision = record.revision
        let wait = max(0, ticket.deadline - now)
        model.diagnosticLog("Scheduled confirmation for \(identity(record)); wait=\(wait)s; ticket=\(ticket); revision=\(revision)", category: "decision")
        record.quitTask = Task { [weak self, weak record, probe] in
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            guard !Task.isCancelled, let self, let record, self.canMonitor,
                  self.records[pid] === record, record.revision == revision,
                  record.policy.pending == ticket else { return }
            self.model.diagnosticLog("Verifying quit for \(self.identity(record)); ticket=\(ticket)", category: "decision")
            record.status = "Verifying…"
            self.publishApps()

            // This is a new AX + WindowServer query, never an earlier cached snapshot.
            let inspection = await probe.inspect(pid: pid, session: session)
            self.logInspection(inspection, record: record, phase: "quit confirmation")
            guard !Task.isCancelled, self.canMonitor, self.records[pid] === record,
                  record.revision == revision, record.policy.pending == ticket,
                  !record.app.isTerminated, record.app.activationPolicy == .regular,
                  let bundleID = record.app.bundleIdentifier, self.model.shouldMonitor(bundleID: bundleID),
                  AXIsProcessTrusted() else {
                self.model.diagnosticLog("Discarded stale or ineligible confirmation for \(self.identity(record)); ticket=\(ticket)", category: "decision")
                return
            }
            record.quitTask = nil
            record.scheduledTicket = nil
            if record.policy.confirm(ticket, windows: inspection.windows, now: self.now) {
                let name = record.app.localizedName ?? bundleID
                // Normal quit only. A cancelled/refused request is not retried until
                // a window is subsequently observed and closed again.
                let sent = record.app.terminate()
                self.model.diagnosticLog("Normal quit request for \(self.identity(record)); accepted=\(sent)", category: "decision")
                record.status = sent ? "Quit requested" : "Quit request declined"
                self.model.diagnosticLog(sent ? "Asked \(name) to quit after its last window closed." : "\(name) did not accept the quit request; kept running.", category: "decision")
            } else {
                self.model.diagnosticLog("Quit cancelled for \(self.identity(record)): \(inspection.detail)", category: "decision")
                record.status = inspection.detail
            }
            self.publishApps()
        }
    }

    private func cancelAll(resetHistory: Bool) {
        for record in records.values {
            model.diagnosticLog("Cancelling work for \(identity(record)); resetHistory=\(resetHistory); pending=\(String(describing: record.policy.pending))", category: "decision")
            record.cancel(resetHistory: resetHistory)
            record.status = "Waiting for a fresh window check"
        }
        publishApps()
    }

    @objc private func willSleep() {
        model.diagnosticLog("Sleep: cancelling pending quits", category: "lifecycle")
        isSleeping = true
        cancelAll(resetHistory: true)
        updateServiceStatus()
    }

    @objc private func didWake() {
        model.diagnosticLog("Wake: waiting for Desktop to settle", category: "lifecycle")
        isSleeping = false
        settle(after: 3)
    }

    @objc private func sessionInactive() {
        model.diagnosticLog("Session inactive: cancelling pending quits", category: "lifecycle")
        isSessionActive = false
        cancelAll(resetHistory: true)
        updateServiceStatus()
    }

    @objc private func sessionActive() {
        model.diagnosticLog("Session active: waiting for Desktop to settle", category: "lifecycle")
        isSessionActive = true
        settle(after: 3)
    }

    @objc private func spaceChanged() {
        model.diagnosticLog("Space changed: waiting for Desktop to settle", category: "lifecycle")
        settle(after: 3)
    }

    private func settle(after seconds: Double) {
        settleUntil = now + seconds
        cancelAll(resetHistory: true)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.reconcileApps()
            if self.canMonitor { for pid in self.records.keys { self.scan(pid) } }
            self.updateServiceStatus()
        }
        updateServiceStatus()
    }

    private func updateServiceStatus() {
        let status: String
        if isPreview { status = "Preview — monitoring disabled" }
        else if !model.accessibilityGranted { status = "Window access needed" }
        else if model.isPaused { status = "Paused" }
        else if isSleeping || !isSessionActive { status = "Waiting for your session" }
        else if now < settleUntil { status = "Waiting for Desktop to settle" }
        else { status = "Monitoring \(records.count) app\(records.count == 1 ? "" : "s")" }
        if model.serviceStatus != status {
            model.serviceStatus = status
            model.diagnosticLog("Service status: \(status)", category: "lifecycle")
        }
    }

    private func identity(_ record: Record) -> String {
        "\(record.app.localizedName ?? "unknown") [\(record.app.bundleIdentifier ?? "unknown")] pid=\(record.app.processIdentifier) session=\(record.session)"
    }

    private func logInspection(_ inspection: WindowInspection, record: Record, phase: String) {
        model.diagnosticLog("\(identity(record)): \(phase); windows=\(inspection.windows); \(inspection.detail); \(inspection.diagnostics); revision=\(record.revision)", category: "windows")
    }

    private func logSnapshot() {
        model.diagnosticLog("Running=\(isRunning); preview=\(isPreview); sleeping=\(isSleeping); sessionActive=\(isSessionActive); settlingFor=\(max(0, settleUntil - now))s; canMonitor=\(canMonitor)", category: "snapshot")
        for record in records.values {
            model.diagnosticLog("\(identity(record)): revision=\(record.revision); hasSeenWindow=\(record.policy.hasSeenWindow); quitWasRequested=\(record.policy.quitWasRequested); pending=\(String(describing: record.policy.pending))", category: "snapshot")
        }
    }

    private func publishApps() {
        let apps = records.map { pid, record in
            MonitoredApp(id: pid, name: record.app.localizedName ?? "App \(pid)",
                         bundleID: record.app.bundleIdentifier ?? "", path: record.app.bundleURL?.path,
                         status: record.status, isPending: record.policy.pending != nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if model.monitoredApps != apps { model.monitoredApps = apps }
    }
}
