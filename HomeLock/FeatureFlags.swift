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
}
