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
        // `isPro` arranca en `false` y solo se activa tras verificar una
        // transacción firmada por Apple en `handleTransaction`. NO hardcodear
        // `true` aquí — eso regala Pro a todo el mundo.
        //
        // Al arrancar la app hay una ventana breve (~100ms) en la que
        // `isPro == false` mientras `checkEntitlement()` itera las
        // `currentEntitlements`. Las vistas que leen `isPro` deben estar
        // preparadas para ese flicker (ya lo están: muestran paywall y
        // desaparece cuando el entitlement llega).

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

#if DEBUG
    /// DEBUG-only: fuerza `isPro` para testing en device personal sin comprar
    /// ni configurar sandbox. Envuelto en `#if DEBUG` para que el código NO
    /// se compile en builds de Release — no puede shippear a App Store.
    func debug_setProOverride(_ enabled: Bool) {
        isPro = enabled
        print("🧪 [StoreKit DEBUG] isPro override = \(enabled)")
    }
#endif
}
