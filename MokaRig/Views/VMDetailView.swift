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

    var body: some View {
        let metadata = listing.metadata
        let isActive = runner.isActive(listing.id)
        Form {
            Section {
                detailRow("Name", value: metadata.name, systemImage: "tag")
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
            // Installer controls for a Linux VM: eject the attached installer, or re-attach it if it
            // was ejected but its media file is still around. The installer file itself is untouched.
            // (The installer auto-ejects on power-off once the disk shows a guest OS was installed.)
            if metadata.guestOS == .linux, let mediaPath = metadata.installerMediaPath {
                let mediaExists = FileManager.default.fileExists(atPath: mediaPath)
                if metadata.needsInstall || mediaExists {
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
                        runner.start(listing)
                        openWindow(id: MokaRigApp.runnerWindowID, value: listing.bundle.url)
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
        .confirmationDialog("Move “\(metadata.name)” to the Trash?",
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
        .confirmationDialog("“\(metadata.name)” can't be moved to the Trash.",
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
        .confirmationDialog("Do you want to force “\(metadata.name)” to power off?",
                            isPresented: $isConfirmingForceStop, titleVisibility: .visible) {
            Button("Force Stop", role: .destructive) {
                runner.forceStop(listing.id)
            }
        } message: {
            Text("Unsaved work in the guest may be lost — this is like pulling the plug.")
        }
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
