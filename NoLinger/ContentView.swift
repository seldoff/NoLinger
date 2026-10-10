import SwiftUI
import ServiceManagement

struct ContentView: View {
    @ObservedObject var model: AppModel
    var onGrantAccess: () -> Void
    @State private var tab = 0
    @State private var showingRunningApps = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "door.left.hand.open")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.indigo)
                    .frame(width: 52, height: 52)
                    .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Linger").font(.title2.bold())
                    Text("Close the last window. Let the app go.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            if !model.accessibilityGranted {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Allow No Linger to check app windows").fontWeight(.medium)
                        Text("Enable No Linger in \(model.windowAccessPermissionName).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Grant Access", action: onGrantAccess).buttonStyle(.borderedProminent)
                }
                .padding(14)
                .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 22).padding(.bottom, 16)
            }

            Picker("Settings section", selection: $tab) {
                Text("General").tag(0)
                Text("Apps").tag(1)
                Text("Logs").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 22).padding(.bottom, 16)

            Divider()
            Group {
                switch tab {
                case 1: appsTab
                case 2: logsTab
                default: generalTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.caption).foregroundStyle(.tertiary)
                Button("Quit No Linger") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 22).padding(.vertical, 13)
        }
        .frame(minWidth: 660, minHeight: 560)
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Pause automatic quitting", isOn: $model.isPaused)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Wait before quitting")
                        Spacer()
                        Text(model.delay, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit().foregroundStyle(.secondary)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                    Slider(value: $model.delay, in: 0.2...10, step: 0.1)
                    Text("Opening another window cancels the wait. An uncertain window check keeps the app running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            } header: { Text("Automatic quitting") }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }
                ))
                if model.loginNeedsApproval {
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle("Hide menu bar icon", isOn: $model.hideMenuBarIcon)
                if model.hideMenuBarIcon {
                    Text("Open No Linger again from Applications or Spotlight to return to Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.permissionMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Startup and appearance") }
        }
        .formStyle(.grouped)
    }

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("Monitor", selection: $model.scope) {
                ForEach(MonitorScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
            }
            Text(model.scope == .allExceptExcluded
                 ? "Excluded apps keep running when their last window closes."
                 : "Only apps on this list can be quit automatically.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                if model.activeRules.isEmpty {
                    Text(model.scope == .allExceptExcluded ? "No exclusions" : "Add apps to begin monitoring.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.activeRules) { rule in
                    HStack(spacing: 10) {
                        Image(nsImage: model.icon(path: rule.path, bundleID: rule.bundleID))
                            .resizable().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name)
                            Text(rule.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.removeRule(rule) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove \(rule.name) from this list")
                    }
                    .padding(.vertical, 3)
                }
            }
            .frame(minHeight: 110, idealHeight: 175)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Add App…", systemImage: "plus") { showingRunningApps = true }
                    .popover(isPresented: $showingRunningApps, arrowEdge: .bottom) {
                        RunningAppsPicker(model: model)
                    }
                Spacer()
            }
        }
        .padding(22)
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Collect logs", isOn: Binding(
                    get: { model.isCollectingLogs }, set: { model.setCollectLogs($0) }
                ))
                Spacer()
                Button("Show in Finder", action: model.revealCollectedLogs)
                    .disabled(!model.canAccessCollectedLogs)
                Button("Save Logs…", action: model.saveCollectedLogs)
                    .disabled(!model.canAccessCollectedLogs)
            }
            if let message = model.logCollectionMessage {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
    }
}

private struct RunningAppsPicker: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var applications: [AppRule] = []
    @State private var search = ""

    private var matchingApplications: [AppRule] {
        applications.filter {
            search.isEmpty || $0.name.localizedStandardContains(search)
                || $0.bundleID.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.scope == .allExceptExcluded ? "Exclude an app" : "Include an app")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            TextField("Search running apps", text: $search)
                .textFieldStyle(.roundedBorder)

            if matchingApplications.isEmpty {
                VStack(spacing: 6) {
                    Text(applications.isEmpty ? "No apps to add" : "No matching apps")
                        .fontWeight(.medium)
                    Text(applications.isEmpty
                         ? "Open an app or choose one from Finder."
                         : "Try a different name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(matchingApplications) { app in
                            Button {
                                model.addApplication(app)
                                refreshApplications()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: model.icon(path: app.path, bundleID: app.bundleID))
                                        .resizable().frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name).lineLimit(1)
                                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(app.name)")
                        }
                    }
                }
            }
            Divider()
            Button("Choose from Finder…", systemImage: "folder") {
                dismiss()
                model.chooseApplicationsFromFinder()
            }
        }
        .padding(16)
        .frame(width: 370, height: 360)
        .onAppear { refreshApplications() }
        .onChange(of: model.activeRules) { refreshApplications() }
        .onChange(of: model.scope) { refreshApplications() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshApplications()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            refreshApplications()
        }
    }

    private func refreshApplications() {
        applications = model.runningApplicationChoices()
    }
}

#Preview {
    ContentView(model: AppModel(defaults: UserDefaults(suiteName: "NoLinger.Preview")!),
                onGrantAccess: {})
}
