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
	/// The selected VM's bundle URL, persisted so the sidebar restores to it on the next launch.
	@SceneStorage("selectedVMBundleURL") private var persistedSelection = ""
	@State private var isPresentingNewVM = false
	@State private var isBlockedBySibling = false
	@State private var blockedVMName = ""
	@State private var blockingSiblingName = ""

	/// The green tint on a running VM's icon: a deeper green in light mode so it reads against white,
	/// a brighter one in dark mode. A single fixed green washes out on one background or the other.
	private static let runningTint = Color(nsColor: NSColor(name: nil) { appearance in
		let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
		return isDark
			? NSColor(red: 0x4A / 255, green: 0xEF / 255, blue: 0x67 / 255, alpha: 1)
			: NSColor(red: 0x1E / 255, green: 0x9E / 255, blue: 0x3E / 255, alpha: 1)
	})

	var body: some View {
		NavigationSplitView {
			List(selection: $selection) {
				ForEach(library.machines) { listing in
					Label {
						VStack(alignment: .leading, spacing: 2) {
							Text(listing.name)
							Text("\(listing.metadata.guestOS.displayName) • \(stateDescription(listing.id))")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					} icon: {
						Image(systemName: listing.metadata.guestOS.symbolName)
							.foregroundStyle(runner.isActive(listing.id)
											 ? AnyShapeStyle(Self.runningTint)
											 : AnyShapeStyle(.primary))
					}
					.padding(.vertical, 6)
					.tag(listing.id)
					.listRowSeparator(.visible)
				}
			}
			.navigationTitle("Virtual Machines")
			.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
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
			NewVMSheet(selection: $selection)
		}
		.cannotStartCloneAlert(isPresented: $isBlockedBySibling,
							   vmName: blockedVMName, runningSiblingName: blockingSiblingName)
		.onAppear(perform: restoreSelection)
		.onChange(of: selection) { _, newValue in
			if let newValue { persistedSelection = newValue.absoluteString }
		}
	}

	/// A short run-state word for the sidebar subtitle, mirroring the detail view's wording.
	private func stateDescription(_ id: VMBundle.ID) -> String {
		switch runner.liveInstance(for: id)?.state ?? .stopped {
		case .stopped: return "Stopped"
		case .starting: return "Starting…"
		case .running: return "Running"
		case .stopping: return "Stopping…"
		case .failed: return "Failed"
		}
	}

	/// Picks the initial sidebar selection on launch: the persisted VM if it still exists, otherwise
	/// the sole VM when there's exactly one, otherwise nothing (the placeholder). Never overrides a
	/// selection the user has already made this session.
	private func restoreSelection() {
		guard selection == nil else { return }
		if let saved = URL(string: persistedSelection), library.listing(for: saved) != nil {
			selection = saved
		} else if library.machines.count == 1 {
			selection = library.machines.first?.id
		}
	}

	/// Opens (or focuses) the window for the VM at the given sidebar row, starting it if it isn't
	/// already active. `openWindow` reuses the existing window for a VM, so this launches or switches.
	private func openRow(_ index: Int) {
		guard library.machines.indices.contains(index) else { return }
		let listing = library.machines[index]
		if !runner.isActive(listing.id) {
			// Don't start a clone while a VM it shares an identity with is already running.
			if let running = library.cloneSiblings(of: listing).first(where: { runner.isActive($0.id) }) {
				blockedVMName = listing.name
				blockingSiblingName = running.name
				isBlockedBySibling = true
				return
			}
			runner.start(listing)
		}
		openWindow(id: MokaRigApp.runnerWindowID, value: listing.bundle.url)
	}
}

#Preview {
	ContentView()
		.environment(VMLibrary())
}
