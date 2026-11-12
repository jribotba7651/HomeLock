//
//  FeatureFlags.swift
//  HomeLock
//

import Foundation

/// Compile-time feature switches.
nonisolated enum FeatureFlags {
    /// Family Sharing / multi-user sync is not part of v1. Its code is kept but
    /// every UI entry point is hidden while this is false.
    static let familySharingEnabled = false

    /// Lutron locking is not part of v1: on device, Lutron locks release on
    /// their own before the lock time ends. While this is false, Lutron devices
    /// are always excluded (same detection as "Ignore Lutron devices"), the
    /// "Ignore Lutron devices" toggle is hidden, and leftover HomeLock Lutron
    /// automations are removed on launch. The Lutron lock path (gatekeeper,
    /// verified power write) stays in the repo and is compiled in only when the
    /// `HOMELOCK_LUTRON` Swift compilation condition is defined.
    /// TODO(1.1): fix early Lutron release and re-enable Lutron locking.
    #if HOMELOCK_LUTRON
    static let lutronLockingEnabled = true
    #else
    static let lutronLockingEnabled = false
    #endif
}
