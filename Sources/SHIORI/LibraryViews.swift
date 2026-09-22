import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let reset: () -> Void
    var body: some View {
        Form {
            Picker("Screen edge", selection: $settings.edge) { Text("Left").tag("left"); Text("Right").tag("right") }
            HStack {
                Text("Open delay")
                Slider(value: $settings.openDelay, in: 0...0.8, step: 0.05)
                Text("\(Int(settings.openDelay * 1000)) ms").monospacedDigit().frame(width: 60)
            }
            HStack {
                Text("Close delay")
                Slider(value: $settings.closeDelay, in: 0.1...1, step: 0.05)
                Text("\(Int(settings.closeDelay * 1000)) ms").monospacedDigit().frame(width: 60)
            }
            Toggle("Show across Spaces", isOn: $settings.acrossSpaces)
            Toggle("Show over full-screen applications", isOn: $settings.fullscreen)
            Button("Reset Dock and Window Positions", action: reset)
        }.formStyle(.grouped).padding(8).frame(minWidth: 380, minHeight: 290)
    }
}
