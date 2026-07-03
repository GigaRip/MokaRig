// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

/// The main window: a sidebar listing the VM library and a detail pane for the selected VM.
struct ContentView: View {
    @Environment(VMLibrary.self) private var library
    @Environment(VMRunner.self) private var runner
    @Environment(\.openWindow) private var openWindow
    @State private var selection: VMBundle.ID?
    @State private var isPresentingNewVM = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.machines) { listing in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(listing.metadata.name)
                            Text(listing.metadata.guestOS.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: listing.metadata.guestOS.symbolName)
                    }
                    .padding(.vertical, 6)
                    .tag(listing.id)
                }
            }
            .navigationTitle("Virtual Machines")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            // SwiftUI has no double-click-row API, so this hooks the underlying NSTableView's
            // native double-click to launch or focus a row's window without disturbing selection.
            .background(SidebarDoubleClick { openRow($0) })
            .overlay {
                if library.machines.isEmpty {
                    ContentUnavailableView(
                        "No Virtual Machines",
                        systemImage: "desktopcomputer",
                        description: Text("Create a VM to get started."))
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        isPresentingNewVM = true
                    } label: {
                        Label("New Virtual Machine", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let selection, let listing = library.listing(for: selection) {
                VMDetailView(listing: listing, selection: $selection)
                    .id(listing.id)
            } else {
                ContentUnavailableView(
                    "Select a Virtual Machine",
                    systemImage: "sidebar.left",
                    description: Text("Choose a VM from the list, or create a new one."))
                .navigationTitle("MokaRig")
            }
        }
        .sheet(isPresented: $isPresentingNewVM) {
            NewVMSheet()
        }
    }

    /// Opens (or focuses) the window for the VM at the given sidebar row, starting it if it isn't
    /// already active. `openWindow` reuses the existing window for a VM, so this launches or switches.
    private func openRow(_ index: Int) {
        guard library.machines.indices.contains(index) else { return }
        let listing = library.machines[index]
        if !runner.isActive(listing.id) {
            runner.start(listing)
        }
        openWindow(id: MokaRigApp.runnerWindowID, value: listing.bundle.url)
    }
}

#Preview {
    ContentView()
        .environment(VMLibrary())
}
