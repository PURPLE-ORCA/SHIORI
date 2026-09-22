import XCTest
import AppKit
@testable import SHIORI

final class GeometryTests: XCTestCase {
    func testClampsDisconnectedAndNegativeDisplays() {
        let screens = [NSRect(x: -1440, y: -100, width: 1440, height: 900), NSRect(x: 0, y: 0, width: 1920, height: 1080)]
        let left = WindowGeometry.clamp(NSRect(x: -1500, y: -200, width: 360, height: 400), to: screens)
        XCTAssertEqual(left.origin, NSPoint(x: -1440, y: -100))
        let recovered = WindowGeometry.clamp(NSRect(x: 5000, y: 3000, width: 3000, height: 2000), to: [screens[1]])
        XCTAssertEqual(recovered, screens[1])
    }
    @MainActor func testPreferencesAreIsolatedAndGeometryRoundTrips() {
        let name = "app.shiori.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.acrossSpaces)
        XCTAssertFalse(settings.fullscreen)
        let frame = NSRect(x: -400, y: 300, width: 360, height: 400)
        settings.saveFrame(frame, id: "note", display: "42")
        XCTAssertEqual(settings.frame(id: "note"), frame)
        settings.edge = "left"
        XCTAssertEqual(SettingsStore(defaults: defaults).edge, "left")
        settings.resetPositions()
        XCTAssertNil(settings.frame(id: "note"))
    }
}
