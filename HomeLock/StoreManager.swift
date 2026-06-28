//
//  StoreManager.swift
//  HomeLock
//

import SwiftUI
import StoreKit
import Combine

// Use type alias to avoid ambiguity with SwiftUI.Transaction
typealias StoreTransaction = StoreKit.Transaction

@MainActor
class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published var isPro = false
    @Published var products: [Product] = []

    private let productId = "com.jibaroenlaluna.homelock.pro"
    private var transactionListener: Task<Void, Error>?

    private init() {
        // Plain Task inherits @MainActor — no actor hop needed per update.
        transactionListener = Task {
            for await result in StoreTransaction.updates {
                await handleTransaction(result)
            }
        }

        Task {
            await checkEntitlement()
            await loadProducts()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    func loadProducts() async {
        do {
            self.products = try await Product.products(for: [productId])
            print("🛍️ [StoreKit] Products loaded: \(products.count)")
        } catch {
            print("❌ [StoreKit] Failed to load products: \(error)")
        }
    }

    func purchase() async throws {
        guard let product = products.first(where: { $0.id == productId }) else {
            print("❌ [StoreKit] Pro product not found")
            return
        }

        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            await handleTransaction(verification)
        case .userCancelled:
            print("🛍️ [StoreKit] User cancelled purchase")
        case .pending:
            print("🛍️ [StoreKit] Purchase pending")
        @unknown default:
            break
        }
    }

    // Syncs with App Store (may prompt for Apple ID if not signed in),
    // then re-reads currentEntitlements to update isPro. Does NOT initiate
    // a new purchase — AppStore.sync() only restores existing transactions.
    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            print("❌ [StoreKit] AppStore.sync() failed: \(error)")
        }
        // Always re-check entitlements, even if sync threw.
        await checkEntitlement()
    }

    // Reads Transaction.currentEntitlements and sets isPro to exactly true/false.
    // Called on init (auto-unlock on fresh install with existing purchase) and
    // after restorePurchases(). Calling finish() here covers the edge case where
    // the app was killed before finish() ran after a purchase.
    func checkEntitlement() async {
        var hasPro = false
        for await result in StoreTransaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == productId && transaction.revocationDate == nil {
                hasPro = true
            }
            await transaction.finish()
        }
        isPro = hasPro
    }

    private func handleTransaction(_ result: VerificationResult<StoreTransaction>) async {
        switch result {
        case .verified(let transaction):
            if transaction.productID == productId {
                isPro = transaction.revocationDate == nil
                print("✅ [StoreKit] isPro = \(isPro)")
            }
            await transaction.finish()
        case .unverified(let transaction, let error):
            // Do NOT touch isPro here: an unverified transaction from a different
            // product (or a tampered one) must not revoke a legitimate purchase.
            print("❌ [StoreKit] Transaction unverified: \(transaction.productID), error: \(error)")
        }
    }
}
