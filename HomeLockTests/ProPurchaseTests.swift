//
//  ProPurchaseTests.swift
//  HomeLockTests
//
//  Runs the real StoreManager purchase / restore paths against the local
//  StoreKit configuration (HomeLock/Configuration.storekit) via SKTestSession.
//

import Testing
import Foundation
import StoreKitTest
@testable import HomeLock

@MainActor
@Suite(.serialized)
struct ProPurchaseTests {

    private static let configURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // HomeLockTests/
        .deletingLastPathComponent()      // repo root
        .appendingPathComponent("HomeLock/Configuration.storekit")

    @Test func purchaseThenRestoreUnlocksPro() async throws {
        let session = try SKTestSession(contentsOf: Self.configURL)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }

        let store = StoreManager.shared

        // Fresh state: not Pro.
        await store.checkEntitlement()
        #expect(store.isPro == false)

        // Price comes from StoreKit.
        await store.loadProducts()
        let product = try #require(store.products.first)
        #expect(product.id == "com.jibaroenlaluna.homelock.pro")
        #expect(product.displayPrice == "$9.99")

        // Purchase unlocks Pro; Pro-gated lock limit is lifted.
        try await store.purchase()
        #expect(store.isPro == true)
        #expect(LockManager.shared.canAddLock == true)

        // Simulate a relaunch / reinstall that lost in-memory state, then restore.
        store.debug_setProOverride(false)
        #expect(store.isPro == false)
        await store.restorePurchases()
        #expect(store.isPro == true)

        // Without any transaction, the entitlement check reports not Pro again.
        session.clearTransactions()
        await store.checkEntitlement()
        #expect(store.isPro == false)
    }
}
