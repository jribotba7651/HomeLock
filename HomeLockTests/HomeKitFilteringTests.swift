import Testing
import HomeKit
@testable import HomeLock

struct HomeKitFilteringTests {

    @Test func testLutronFiltering() async throws {
        // Lutron device -> Should NOT filter (now implementing proper cleanup instead)
        let shouldFilterLutron = HomeKitService.shouldFilter(
            manufacturer: "Lutron",
            services: [HMServiceTypeOutlet]
        )
        #expect(shouldFilterLutron == false)
        
        // Lutron (case insensitive) -> Should NOT filter
        let shouldFilterLutronCaps = HomeKitService.shouldFilter(
            manufacturer: "LUTRON Electronics",
            services: [HMServiceTypeOutlet]
        )
        #expect(shouldFilterLutronCaps == false)
    }

    @Test func testOtherManufacturersFiltering() async throws {
        // Kasa device with outlet -> Should NOT filter
        let shouldFilterKasa = HomeKitService.shouldFilter(
            manufacturer: "TP-Link",
            services: [HMServiceTypeOutlet]
        )
        #expect(shouldFilterKasa == false)
        
        // Unknown manufacturer with light -> Should NOT filter
        let shouldFilterUnknown = HomeKitService.shouldFilter(
            manufacturer: "Generic",
            services: [HMServiceTypeLightbulb]
        )
        #expect(shouldFilterUnknown == false)
    }

    @Test func testUnsupportedDeviceFiltering() async throws {
        // Device with no supported services -> Should filter
        let shouldFilterUnsupported = HomeKitService.shouldFilter(
            manufacturer: "Other",
            services: [HMServiceTypeBattery] // Generic unsupported service
        )
        #expect(shouldFilterUnsupported == true)
    }
}
