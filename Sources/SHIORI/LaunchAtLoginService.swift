import AppKit
import ServiceManagement

@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () async throws -> Void
    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () async throws -> Void = { try await SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus; self.register = register; self.unregister = unregister
    }
    func refresh() { status = readStatus() }
    func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false; refresh() }
        error = nil
        do {
            if enabled { try register() } else { try await unregister() }
        } catch { self.error = error.localizedDescription }
    }
}
