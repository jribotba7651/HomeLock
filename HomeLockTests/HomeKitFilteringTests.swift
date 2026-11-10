import Testing
import Foundation
@testable import HomeLock

struct HomeKitFilteringTests {

    @Test func testLutronDetectionByManufacturer() {
        #expect(HomeKitService.isLutron(manufacturer: "Lutron", model: nil))
        // Case insensitive
        #expect(HomeKitService.isLutron(manufacturer: "LUTRON Electronics Co., Inc.", model: "PD-6WCL"))
    }

    @Test func testLutronDetectionByModelWhenManufacturerMissing() {
        #expect(HomeKitService.isLutron(manufacturer: nil, model: "Caséta Dimmer"))
        #expect(HomeKitService.isLutron(manufacturer: "", model: "caseta"))
        #expect(HomeKitService.isLutron(manufacturer: nil, model: "RA3 Switch"))
    }

    @Test func testOtherManufacturersAreNotLutron() {
        #expect(!HomeKitService.isLutron(manufacturer: "TP-Link", model: "HS103"))
        #expect(!HomeKitService.isLutron(manufacturer: "Generic", model: "Lightbulb"))
        #expect(!HomeKitService.isLutron(manufacturer: nil, model: nil))
    }

    @Test @MainActor func testLutronIsolationDefaultsToTrue() {
        let key = HomeKitService.ignoreLutronDefaultsKey
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        #expect(HomeKitService.shouldIgnoreLutron == true)
    }
}
