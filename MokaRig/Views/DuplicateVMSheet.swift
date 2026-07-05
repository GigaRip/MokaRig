// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

/// A sheet for duplicating a virtual machine. Warns that a duplicate shares the original's internal
/// guest identity, then prompts for the new name. Offered only while the VM is stopped.
struct DuplicateVMSheet: View {
    @Environment(VMLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let listing: VMListing
    /// The sidebar selection, moved to the duplicate once it's created.
    @Binding var selection: VMBundle.ID?

    @State private var name: String
    @State private var errorMessage: String?

    init(listing: VMListing, selection: Binding<VMBundle.ID?>) {
        self.listing = listing
        self._selection = selection
        _name = State(initialValue: String("\(listing.metadata.name) copy".prefix(VMMetadata.maxNameLength)))
    }

    var body: some View {
        NavigationStack {
            // A plain VStack (not a Form) so the sheet can size itself to its content: Form/List are
            // scroll containers with no intrinsic height, which .presentationSizing(.fitted) can't
            // measure, but a VStack of GroupBoxes has a definite height that it fits exactly.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.square.on.square")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text("Duplicate Virtual Machine")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Duplicating a virtual machine makes an exact copy of it. This is useful for creating templates, or for making a checkpoint before a risky change to this guest OS.")
                                .fontWeight(.medium)
                            Text("The copy and the original are effectively the same computer, so anything meant to be unique to it will conflict — things like:")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                bullet("The computer's name")
                                bullet("Its host name on the network")
                                bullet("A unique machine identifier")
                            }
                            .foregroundStyle(.secondary)
                            Text("So MokaRig won't let you run the copy and the original at the same time until you make the copy independent.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    } label: {
                        Label("Before You Duplicate", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .padding(.bottom, 4)
                    }

                    GroupBox {
                        HStack(spacing: 12) {
                            Label("Name", systemImage: "tag")
                            TextField("\(listing.metadata.name) copy", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: name) { _, newValue in
                                    if newValue.count > VMMetadata.maxNameLength {
                                        name = String(newValue.prefix(VMMetadata.maxNameLength))
                                    }
                                }
                        }
                        .padding(10)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Duplicate") { duplicate() }
                }
            }
        }
        .frame(width: 540)
        .presentationSizing(.fitted)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text)
        }
    }

    private func duplicate() {
        do {
            let copy = try library.duplicate(listing, newName: name)
            selection = copy.id
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
