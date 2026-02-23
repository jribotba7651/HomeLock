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

    private let productId = "com.jibaroenaluna.homelock.pro"
    private var transactionListener: Task<Void, Error>?

    private init() {
        // Start listening for transactions
        transactionListener = Task.detached {
            for await result in StoreTransaction.updates {
                await self.handleTransaction(result)
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

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await checkEntitlement()
        } catch {
            print("❌ [StoreKit] Failed to sync/restore purchases: \(error)")
        }
    }

    func checkEntitlement() async {
        for await result in StoreTransaction.currentEntitlements {
            await handleTransaction(result)
        }
    }

    private func handleTransaction(_ result: VerificationResult<StoreTransaction>) async {
        switch result {
        case .verified(let transaction):
            if transaction.productID == productId {
                isPro = transaction.revocationDate == nil
                await transaction.finish()
                print("✅ [StoreKit] User is Pro")
            }
        case .unverified(let transaction, let error):
            print("❌ [StoreKit] Transaction unverified: \(transaction.productID), error: \(error)")
            isPro = false
        }
    }
}
