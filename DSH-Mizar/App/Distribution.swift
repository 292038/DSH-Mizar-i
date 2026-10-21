//
//  Distribution.swift
//  DSH-Mizar
//
//  Which channel this build came from.
//
//  The subscription is not sellable from a TestFlight build: the products are
//  not live for testers and the sandbox sheet is a confusing thing to show
//  somebody who was invited to try the app. The test is Apple's own: a TestFlight
//  (and simulator/development) install carries `sandboxReceipt`, an App Store
//  install carries `receipt`.
//

import Foundation

enum Distribution {
    /// Whether this build runs from TestFlight (or a sandbox receipt).
    ///
    /// `-mizarMockTestFlight` is the debug seam: no simulator install has a
    /// receipt, so a UI test cannot reach this state any other way.
    static var isTestFlight: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-mizarMockTestFlight") { return true }
        #endif
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }
}
