import AppKit
import SwiftUI

@MainActor
final class DeleteUndoCoordinator {
    private var panel: NSPanel?
    private var generation = UUID()
    private var expiry: Task<Void, Never>?
    func show(on screen: NSScreen?, behavior: NSWindow.CollectionBehavior, undo: @escaping () async throws -> Void, reportError: @escaping (Error) -> Void) {
        dismiss()
        let token = generation
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let panel = ToastPanel(contentRect: NSRect(x: frame.midX - 125, y: frame.minY + 32, width: 250, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.hasShadow = true
        panel.collectionBehavior = behavior
        panel.contentView = NSHostingView(rootView: DeleteToastView { [weak self] in
            guard let self, self.generation == token else { return }
            self.expiry?.cancel()
            do { try await undo(); if self.generation == token { self.dismiss() } }
            catch { reportError(error) }
        })
        self.panel = panel
        panel.orderFrontRegardless()
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.dismiss()
        }
    }
    func dismiss() { generation = UUID(); expiry?.cancel(); expiry = nil; panel?.close(); panel?.contentView = nil; panel = nil }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private struct DeleteToastView: View {
    let undo: () async -> Void
    @State private var busy = false
    var body: some View {
        HStack {
            Text("Note deleted")
            Spacer()
            Button("Undo") { busy = true; Task { await undo(); busy = false } }.disabled(busy)
        }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
