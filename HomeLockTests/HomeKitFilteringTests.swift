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

    @Test func testLutronIsolationDefaultsToOnInFreshDefaults() throws {
        let suite = "HomeKitFilteringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(HomeKitService.isLutronIsolated(in: defaults) == true)
    }

    @Test func testLutronIsolationReadsPersistedValue() throws {
        let suite = "HomeKitFilteringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: HomeKitService.ignoreLutronDefaultsKey)
        #expect(HomeKitService.isLutronIsolated(in: defaults) == false)
        defaults.set(true, forKey: HomeKitService.ignoreLutronDefaultsKey)
        #expect(HomeKitService.isLutronIsolated(in: defaults) == true)
    }

    @Test func testFilterHidesLutronOnlyWhenIsolationOn() {
        #expect(HomeKitService.hidesLutron(isLutron: true, ignoreLutron: true))
        #expect(!HomeKitService.hidesLutron(isLutron: true, ignoreLutron: false))
        #expect(!HomeKitService.hidesLutron(isLutron: false, ignoreLutron: true))
        #expect(!HomeKitService.hidesLutron(isLutron: false, ignoreLutron: false))
    }
}
