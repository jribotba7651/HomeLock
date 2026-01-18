//
//  StoreManager.swift
//  HomeLock
//
//  Created by Juan C. Ribot on 1/18/26.
//

import StoreKit
import SwiftUI

/// Manages StoreKit 2 purchases and entitlements for HomeLock Pro
@MainActor
class StoreManager: ObservableObject {

    static let shared = StoreManager()

    // MARK: - Published Properties

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPro: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Constants

    static let productID = "com.jibaroenlaluna.homelock.pro"
    static let freeDeviceLimit = 2

    // MARK: - Private Properties

    private var updateListenerTask: Task<Void, Error>?

    // MARK: - Initialization

    private init() {
        print("[StoreManager] Initializing singleton instance")
        updateListenerTask = listenForTransactions()

        Task {
            await loadProducts()
            await updatePurchasedStatus()
        }
    }

    deinit {
        updateListenerTask?.cancel()
        print("[StoreManager] Deallocated")
    }

    // MARK: - Load Products

    /// Fetches available products from the App Store
    func loadProducts() async {
        guard products.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            products = try await Product.products(for: [Self.productID])
            print("[StoreManager] Loaded \(products.count) products")

            if products.isEmpty {
                print("[StoreManager] Warning: No products found for ID: \(Self.productID)")
            }
        } catch {
            print("[StoreManager] Error loading products: \(error)")
            errorMessage = String(localized: "Error loading products: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase

    /// Initiates a purchase for HomeLock Pro
    @discardableResult
    func purchase() async throws -> Bool {
        guard let product = products.first else {
            throw StoreError.productNotFound
        }

        isLoading = true
        defer { isLoading = false }

        print("[StoreManager] Starting purchase for: \(product.displayName)")

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await updatePurchasedStatus()
            print("[StoreManager] Purchase successful!")
            return true

        case .userCancelled:
            print("[StoreManager] User cancelled purchase")
            return false

        case .pending:
            print("[StoreManager] Purchase pending approval")
            errorMessage = String(localized: "Purchase is pending approval")
            return false

        @unknown default:
            print("[StoreManager] Unknown purchase result")
            return false
        }
    }

    // MARK: - Restore Purchases

    /// Restores previous purchases from the App Store
    func restore() async {
        isLoading = true
        defer { isLoading = false }

        print("[StoreManager] Starting restore...")

        do {
            try await AppStore.sync()
            await updatePurchasedStatus()

            if isPro {
                print("[StoreManager] Restore successful - Pro unlocked!")
            } else {
                print("[StoreManager] Restore completed - No previous purchases found")
                errorMessage = String(localized: "No previous purchases found")
            }
        } catch {
            print("[StoreManager] Restore failed: \(error)")
            errorMessage = String(localized: "Restore failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Check Entitlements

    /// Updates the isPro status by checking current entitlements
    func updatePurchasedStatus() async {
        print("[StoreManager] Checking entitlements...")

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.productID == Self.productID {
                    isPro = true
                    print("[StoreManager] Pro entitlement found!")
                    return
                }
            }
        }

        isPro = false
        print("[StoreManager] No Pro entitlement found")
    }

    // MARK: - Device Limit Check

    /// Checks if the user can lock more devices based on their plan
    /// - Parameter currentLockCount: The number of devices currently locked
    /// - Returns: True if the user can lock another device
    func canLockMoreDevices(currentLockCount: Int) -> Bool {
        if isPro {
            return true
        }
        return currentLockCount < Self.freeDeviceLimit
    }

    /// Returns the number of remaining free device slots
    /// - Parameter currentLockCount: The number of devices currently locked
    /// - Returns: Number of remaining slots (0 if Pro user - unlimited)
    func remainingFreeSlots(currentLockCount: Int) -> Int? {
        if isPro {
            return nil // Unlimited
        }
        return max(0, Self.freeDeviceLimit - currentLockCount)
    }

    // MARK: - Transaction Listener

    /// Listens for transaction updates from the App Store
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                print("[StoreManager] Transaction update received")

                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.updatePurchasedStatus()
                }
            }
        }
    }

    // MARK: - Helpers

    /// Verifies a StoreKit transaction result
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            print("[StoreManager] Verification failed: \(error)")
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }
}

// MARK: - Store Errors

enum StoreError: LocalizedError {
    case productNotFound
    case verificationFailed
    case purchaseFailed

    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return String(localized: "Product not found. Please try again later.")
        case .verificationFailed:
            return String(localized: "Transaction verification failed. Please contact support.")
        case .purchaseFailed:
            return String(localized: "Purchase failed. Please try again.")
        }
    }
}
