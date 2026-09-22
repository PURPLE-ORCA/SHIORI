import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var shortcuts: GlobalShortcutCoordinator?
    @StateObject private var login = LaunchAtLoginService()
    let reset: () -> Void
    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch SHIORI at Login", isOn: Binding(get: { login.status == .enabled || login.status == .requiresApproval }, set: { enabled in Task { await login.setEnabled(enabled) } }))
                    .disabled(login.busy)
                if login.status == .requiresApproval {
                    Text("Allow SHIORI in System Settings → General → Login Items.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = login.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Edge") {
                Picker("Screen edge", selection: $settings.edge) { Text("Left").tag("left"); Text("Right").tag("right") }
                Button("Reset Edge and Window Positions", action: reset)
            }
            Section("Interaction") {
                HStack {
                    Text("Preview delay")
                    Slider(value: $settings.openDelay, in: 0...0.8, step: 0.05)
                    Text("\(Int(settings.openDelay * 1000)) ms").monospacedDigit().frame(width: 60)
                }
                HStack {
                    Text("Close delay")
                    Slider(value: $settings.closeDelay, in: 0.1...1, step: 0.05)
                    Text("\(Int(settings.closeDelay * 1000)) ms").monospacedDigit().frame(width: 60)
                }
            }
            if let shortcuts { ShortcutSettingsView(shortcuts: shortcuts) }
            Section("Spaces / Windows") {
                Toggle("Show across Spaces", isOn: $settings.acrossSpaces)
                Toggle("Show over full-screen applications", isOn: $settings.fullscreen)
            }
        }.formStyle(.grouped).padding(8).frame(minWidth: 440, minHeight: 560)
            .onAppear { login.refresh(); shortcuts?.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh(); shortcuts?.refresh() }
    }
}
