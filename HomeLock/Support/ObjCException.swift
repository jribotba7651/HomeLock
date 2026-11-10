//
//  ObjCException.swift
//  HomeLock
//

import Foundation

/// Swift entry point for HLObjC: runs a block and turns an Objective-C
/// exception into a thrown NSError instead of crashing the app.
enum ObjCException {
    nonisolated static func catching(_ block: () -> Void) throws {
        try HLObjC.`try`(block)
    }
}
