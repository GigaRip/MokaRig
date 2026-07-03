// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import Observation

/// A shared registry of live VM instances so the detail view and the runner window
/// observe the same run state for a given virtual machine.
@MainActor
@Observable
final class VMRunner {
    private(set) var instances: [VMBundle.ID: VMInstance] = [:]

    /// The live instance for a VM, if one has been created.
    func liveInstance(for id: VMBundle.ID) -> VMInstance? {
        instances[id]
    }

    /// Returns the instance for a listing, creating (but not starting) one if needed.
    /// Call from actions or lifecycle callbacks, not during view body evaluation.
    @discardableResult
    func makeInstance(for listing: VMListing) -> VMInstance {
        if let existing = instances[listing.id] { return existing }
        let instance = VMInstance(listing: listing)
        instances[listing.id] = instance
        return instance
    }

    /// Creates the instance if needed and starts the VM.
    func start(_ listing: VMListing) {
        makeInstance(for: listing).start()
    }

    /// Asks the guest to shut down gracefully, if it has a live instance.
    func requestStop(_ id: VMBundle.ID) {
        instances[id]?.requestStop()
    }

    /// Forces the VM to power off, if it has a live instance.
    func forceStop(_ id: VMBundle.ID) {
        instances[id]?.forceStop()
    }

    /// Drops the instance for a VM, e.g. after its bundle is renamed to a new identity.
    func forget(_ id: VMBundle.ID) {
        instances[id] = nil
    }

    /// Whether the VM is doing anything other than sitting stopped or failed.
    func isActive(_ id: VMBundle.ID) -> Bool {
        switch instances[id]?.state {
        case .none, .stopped, .failed: return false
        default: return true
        }
    }
}
