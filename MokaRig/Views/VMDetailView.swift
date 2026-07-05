// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

/// Shows the configuration of the selected VM and lets the user run, edit, or delete it.
struct VMDetailView: View {
    @Environment(VMLibrary.self) private var library
    @Environment(VMRunner.self) private var runner
    @Environment(\.openWindow) private var openWindow
    let listing: VMListing
    /// The sidebar selection, so a rename can follow the VM to its new bundle identity.
    @Binding var selection: VMBundle.ID?

    @State private var isConfirmingDelete = false
    @State private var isConfirmingPermanentDelete = false
    @State private var isConfirmingEject = false
    @State private var isConfirmingForceStop = false
    @State private var isPresentingEdit = false
    @State private var isPresentingDuplicate = false
    @State private var isConfirmingIndependent = false
    @State private var isBlockedBySibling = false
    @State private var blockingSiblingName = ""

    var body: some View {
        let metadata = listing.metadata
        let isActive = runner.isActive(listing.id)
        Form {
            Section {
                detailRow("Name", value: listing.name, systemImage: "tag")
                detailRow("Guest OS", value: metadata.guestOS.displayName, systemImage: "pc")
            }
            Section("Resources") {
                detailRow("Compute", value: metadata.cpuCount == 1 ? "1 Core" : "\(metadata.cpuCount) Cores",
                          systemImage: "cpu")
                detailRow("Memory", value: memoryDescription(metadata.memorySizeInBytes), systemImage: "memorychip")
                detailRow("Storage", value: storageDescription(listing.bundle), systemImage: "internaldrive")
                detailRow("Display",
                          value: "\(metadata.displayWidthInPixels) × \(metadata.displayHeightInPixels)",
                          systemImage: "display")
                if metadata.guestOS == .linux {
                    detailRow("Resolution",
                              value: metadata.dynamicResolution ? "Matches window" : "Fixed",
                              systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            Section("Status") {
                detailRow("State", value: runStateDescription, systemImage: runStateSymbol)
            }
            // Shown only while the VM still has clone siblings: explains the shared-identity guard
            // and how to lift it. Keyed on siblings, not just the group ID, so a lone leftover group
            // (e.g. after every copy was made independent) doesn't linger in the UI. Placed above the
            // installer since it's the more actionable state (the installer manages itself).
            if !library.cloneSiblings(of: listing).isEmpty {
                Section("Shared Identity") {
                    Label {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("This virtual machine shares its guest OS identity with another virtual machine. MokaRig won't run both at once until one of them is made independent.")
                            Text("Give this virtual machine its own identity from inside the guest OS, then make it independent:")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "person.2")
                    }
                    Button {
                        isConfirmingIndependent = true
                    } label: {
                        Label("Make Independent…", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
            }
            // Installer controls for a Linux VM: eject the attached installer, or re-attach it if it
            // was ejected. Hidden once the media file is gone — there's nothing to show or reattach.
            // The installer file itself is never touched. (It also auto-ejects on power-off once the
            // disk shows a guest OS was installed.)
            if metadata.guestOS == .linux, let mediaPath = metadata.installerMediaPath,
               FileManager.default.fileExists(atPath: mediaPath) {
                Section("Installer") {
                    detailRow("Media", value: URL(fileURLWithPath: mediaPath).lastPathComponent,
                              systemImage: "opticaldisc")
                    // Attaching/ejecting is a boot-time change, so only allow it while stopped.
                    if metadata.needsInstall {
                        Button {
                            isConfirmingEject = true
                        } label: {
                            Label("Eject Installer", systemImage: "eject")
                        }
                        .disabled(isActive)
                    } else {
                        Button {
                            try? library.reattachInstaller(listing)
                        } label: {
                            Label("Reattach Installer", systemImage: "opticaldisc")
                        }
                        .disabled(isActive)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("MokaRig")
        .toolbar {
            // Run/Stop is a distinct primary action, so it stands on its own pill.
            ToolbarItemGroup(placement: .primaryAction) {
                if isActive {
                    // Graceful shutdown is only offered once the guest is fully up.
                    if runState == .running {
                        Button {
                            runner.requestStop(listing.id)
                        } label: {
                            Label("Shut Down", systemImage: "stop.fill")
                        }
                    }
                    Button(role: .destructive) {
                        isConfirmingForceStop = true
                    } label: {
                        Label("Force Stop", systemImage: "power")
                    }
                } else {
                    Button {
                        if let running = library.cloneSiblings(of: listing).first(where: { runner.isActive($0.id) }) {
                            blockingSiblingName = running.name
                            isBlockedBySibling = true
                        } else {
                            runner.start(listing)
                            openWindow(id: MokaRigApp.runnerWindowID, value: listing.bundle.url)
                        }
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                }
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            // Edit and Delete manage the VM and disable together while it runs, so they
            // share one capsule — the group renders a hairline separator between them.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isPresentingEdit = true
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .disabled(isActive)

                Button {
                    isPresentingDuplicate = true
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(isActive)

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isActive)
            }
        }
        .sheet(isPresented: $isPresentingEdit) {
            EditVMSheet(listing: listing, selection: $selection)
        }
        .confirmationDialog("Move “\(listing.name)” to the Trash?",
                            isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                do {
                    try library.moveToTrash(listing)
                } catch {
                    // The volume has no Trash — offer a permanent delete instead. Defer so the
                    // first dialog finishes dismissing before the fallback appears.
                    Task { @MainActor in isConfirmingPermanentDelete = true }
                }
            }
        } message: {
            Text("The virtual machine and its disk image move to the Trash. You can restore them until you empty it.")
        }
        .confirmationDialog("“\(listing.name)” can't be moved to the Trash.",
                            isPresented: $isConfirmingPermanentDelete, titleVisibility: .visible) {
            Button("Delete Permanently", role: .destructive) {
                library.permanentlyDelete(listing)
            }
        } message: {
            Text("This volume doesn't support the Trash. Permanently deleting the virtual machine and its disk image can't be undone.")
        }
        .confirmationDialog("Eject installer media?",
                            isPresented: $isConfirmingEject, titleVisibility: .visible) {
            Button("Eject Installer") {
                try? library.ejectInstaller(listing)
            }
        } message: {
            Text("The VM will boot from its disk from now on. Your installer file is not deleted.")
        }
        .confirmationDialog("Do you want to force “\(listing.name)” to power off?",
                            isPresented: $isConfirmingForceStop, titleVisibility: .visible) {
            Button("Force Stop", role: .destructive) {
                runner.forceStop(listing.id)
            }
        } message: {
            Text("Unsaved work in the guest may be lost — this is like pulling the plug.")
        }
        .sheet(isPresented: $isPresentingDuplicate) {
            DuplicateVMSheet(listing: listing, selection: $selection)
        }
        .confirmationDialog("Make “\(listing.name)” independent?",
                            isPresented: $isConfirmingIndependent, titleVisibility: .visible) {
            Button("Make Independent") {
                try? library.makeIndependent(listing)
            }
        } message: {
            Text("Do this only after giving the guest OS its own identity. MokaRig will then let it run at the same time as the other virtual machine.")
        }
        .cannotStartCloneAlert(isPresented: $isBlockedBySibling,
                               vmName: listing.name, runningSiblingName: blockingSiblingName)
    }

    // MARK: - Rows

    /// A form row with a leading icon, matching the New Virtual Machine sheet.
    private func detailRow(_ title: String, value: String, systemImage: String) -> some View {
        LabeledContent {
            Text(value)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    // MARK: - Run state

    private var runState: VMRunState {
        runner.liveInstance(for: listing.id)?.state ?? .stopped
    }

    private var runStateDescription: String {
        switch runState {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .failed: return "Stopped (failed to start)"
        }
    }

    private var runStateSymbol: String {
        switch runState {
        case .running: return "play.circle"
        case .starting, .stopping: return "clock"
        case .failed: return "exclamationmark.triangle"
        case .stopped: return "stop.circle"
        }
    }

    // MARK: - Formatting

    private func memoryDescription(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return String(format: "%.0f GB", gigabytes)
    }

    private func storageDescription(_ bundle: VMBundle) -> String {
        guard let bytes = bundle.diskImageSizeInBytes else { return "—" }
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1024 {
            return String(format: "%.0f TB", gigabytes / 1024)
        }
        return String(format: "%.0f GB", gigabytes)
    }
}
