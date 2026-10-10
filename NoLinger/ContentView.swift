import SwiftUI
import ServiceManagement

struct ContentView: View {
    @ObservedObject var model: AppModel
    var onGrantAccess: () -> Void
    var onOpenAccess: () -> Void
    var onCheckAccess: () -> Void = {}
    @State private var tab = 0

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
                Text("Activity").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 22).padding(.bottom, 16)

            Divider()
            Group {
                switch tab {
                case 1: appsTab
                case 2: activityTab
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

            Section {
                HStack {
                    Label("\(model.windowAccessPermissionName) \(model.accessibilityGranted ? "enabled" : "required")",
                          systemImage: model.accessibilityGranted ? "checkmark.shield" : "exclamationmark.shield")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("System Settings…", action: onOpenAccess)
                }
                Text("System Settings → Privacy & Security → \(model.windowAccessPermissionName)")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.accessibilityGranted {
                    HStack {
                        Button("Grant Access", action: onGrantAccess)
                        Button("Show This Copy in Finder") { model.revealApplication() }
                            .help(Bundle.main.bundleURL.path)
                        Button("Check Again", action: onCheckAccess)
                    }
                    Text("If No Linger isn’t listed, use Show This Copy in Finder and add that app with the + button in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("No screen recording permission is needed. No Linger reads window metadata, never screenshots or window titles.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Permission and privacy") }
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
                        if AppModel.importantApps.contains(rule.bundleID) {
                            Image(systemName: "shield").foregroundStyle(.secondary)
                                .help("System app: changing protection requires confirmation")
                        }
                        Button { model.removeRule(rule) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove \(rule.name) from this list")
                    }
                    .padding(.vertical, 3)
                }
            }
            .frame(minHeight: 110, idealHeight: 175)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Add App…", systemImage: "plus") { model.addApplication() }
                Spacer()
                if model.scope == .allExceptExcluded {
                    Button("Restore System Exclusions") { model.restoreExclusions() }
                }
            }
            Divider().padding(.vertical, 2)
            HStack {
                Text("Currently monitored").font(.headline)
                Spacer()
                Text("\(model.monitoredApps.count) apps").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if model.monitoredApps.isEmpty {
                        Text(model.accessibilityGranted ? "No eligible apps are running." : "Grant \(model.windowAccessPermissionName) to see running apps.")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(model.monitoredApps) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Text(app.status).font(.caption)
                                .foregroundStyle(app.isPending ? Color.orange : Color.secondary)
                            Button("Exclude") { model.exclude(app) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .frame(minHeight: 65, idealHeight: 100)
        }
        .padding(22)
    }

    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent activity").font(.headline)
                Spacer()
                Button("Clear") { model.activity.removeAll() }.disabled(model.activity.isEmpty)
            }
            Text("Quit requests and permission changes from this session. This history is not saved to disk.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                if model.activity.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Nothing to report yet").fontWeight(.medium)
                        Text("Activity will appear when No Linger requests a quit.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 14)
                }
                ForEach(model.activity) { entry in
                    HStack(alignment: .top, spacing: 14) {
                        Text(entry.date, style: .time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(entry.message).textSelection(.enabled)
                    }
                    .padding(.vertical, 5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(22)
    }
}

#Preview {
    ContentView(model: AppModel(defaults: UserDefaults(suiteName: "NoLinger.Preview")!),
                onGrantAccess: {}, onOpenAccess: {})
}
