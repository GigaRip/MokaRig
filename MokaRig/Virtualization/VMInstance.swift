// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import Virtualization
import Observation

/// The run state of a virtual machine instance.
enum VMRunState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

/// A running (or runnable) virtual machine, wrapping `VZVirtualMachine` for a single bundle.
@MainActor
@Observable
final class VMInstance {
    let listing: VMListing
    private(set) var state: VMRunState = .stopped
    private(set) var virtualMachine: VZVirtualMachine?

    private var delegate: Delegate?

    init(listing: VMListing) {
        self.listing = listing
    }

    /// Builds the configuration, creates the VM, and starts it.
    func start() {
        guard canStart else { return }
        state = .starting
        do {
            let configuration = try makeConfiguration()
            let machine = VZVirtualMachine(configuration: configuration)
            let delegate = Delegate(owner: self)
            machine.delegate = delegate
            self.delegate = delegate
            self.virtualMachine = machine

            machine.start { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.state = .running
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Asks the guest OS to shut down gracefully (like pressing the power button). The guest may
    /// ignore it; when it does stop, the `guestDidStop` delegate callback moves us to `.stopped`.
    func requestStop() {
        guard let virtualMachine, virtualMachine.state == .running else { return }
        state = .stopping
        do {
            try virtualMachine.requestStop()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Forces a power-off of the virtualized hardware (like pulling the plug).
    func forceStop() {
        guard let virtualMachine,
              virtualMachine.state == .running || virtualMachine.state == .paused else { return }
        state = .stopping
        virtualMachine.stop { [weak self] error in
            guard let self else { return }
            // A forced stop reports completion here; the guest-initiated `guestDidStop` delegate
            // callback does NOT fire for it, so move to `.stopped` on success ourselves.
            if let error {
                self.state = .failed(error.localizedDescription)
            } else {
                self.state = .stopped
            }
        }
    }

    private var canStart: Bool {
        switch state {
        case .stopped, .failed: return true
        default: return false
        }
    }

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        switch listing.metadata.guestOS {
        case .linux:
            return try LinuxVirtualMachineBuilder.makeConfiguration(bundle: listing.bundle, metadata: listing.metadata)
        case .macOS:
            return try MacVirtualMachineBuilder.makeConfiguration(bundle: listing.bundle, metadata: listing.metadata)
        }
    }

    fileprivate func handleGuestStopped(error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
        } else {
            state = .stopped
        }
    }

    /// Bridges `VZVirtualMachineDelegate` callbacks back to the instance on the main actor.
    private final class Delegate: NSObject, VZVirtualMachineDelegate {
        weak var owner: VMInstance?
        init(owner: VMInstance) { self.owner = owner }

        nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
            MainActor.assumeIsolated { owner?.handleGuestStopped(error: nil) }
        }

        nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
            MainActor.assumeIsolated { owner?.handleGuestStopped(error: error) }
        }
    }
}
