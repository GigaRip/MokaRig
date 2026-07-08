// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI
import Virtualization

/// The window that runs a single virtual machine and displays its screen.
struct VMRunnerWindow: View {
	@Environment(VMLibrary.self) private var library
	@Environment(VMRunner.self) private var runner
	let bundleURL: URL?

	var body: some View {
		Group {
			if let bundleURL, let listing = resolvedListing(for: bundleURL) {
				VMRunnerContent(listing: listing)
			} else {
				ContentUnavailableView(
					"Virtual Machine Unavailable",
					systemImage: "exclamationmark.triangle",
					description: Text("This virtual machine could no longer be found."))
					.frame(minWidth: 640, minHeight: 400)
			}
		}
	}

	/// Prefers the library's current listing, but falls back to a still-running instance's captured
	/// listing — so a VM whose files were removed while it runs (e.g. deleted in Finder) keeps its
	/// window and Stop controls instead of becoming unstoppable.
	private func resolvedListing(for url: URL) -> VMListing? {
		library.listing(for: url) ?? runner.liveInstance(for: url)?.listing
	}
}

/// Hosts the running VM and its start/stop controls, sharing run state via `VMRunner`.
private struct VMRunnerContent: View {
	@Environment(VMRunner.self) private var runner
	@Environment(VMLibrary.self) private var library
	@Environment(\.dismiss) private var dismiss
	let listing: VMListing

	/// The current width of the VM display area, used to hide the centered spec chips when the
	/// window is too narrow for them (the VM name always lives in the window title).
	@State private var contentWidth: CGFloat = 0
	@State private var isConfirmingForceStop = false
	@State private var isConfirmingClose = false
	@State private var closeConfirmed = false
	/// Whether the guest currently holds keyboard focus (clicked into) versus the host (title bar).
	@State private var keyboardCaptured = false
	private static let compactTitleWidth: CGFloat = 1000

	/// True when the window is too narrow for the centered spec chips.
	private var isCompact: Bool {
		contentWidth > 0 && contentWidth < Self.compactTitleWidth
	}

	/// The window's title drives the Window menu, so it's always the VM name to keep each runner
	/// window distinct from the others and from the main window.
	private var windowTitle: String {
		listing.name
	}

	/// Tooltip for the keyboard-capture indicator, explaining which way input is currently routed.
	private var keyboardHelp: String {
		keyboardCaptured
			? "Keyboard input is going to the virtual machine. Click the title bar to return control to the host."
			: "Click inside the window to send keyboard input to the virtual machine."
	}

	var body: some View {
		let instance = runner.liveInstance(for: listing.id)
		let state = instance?.state ?? .stopped
		VirtualMachineHostView(
			virtualMachine: instance?.virtualMachine,
			aspectRatio: CGSize(width: listing.metadata.displayWidthInPixels,
								height: listing.metadata.displayHeightInPixels),
			reconfiguresDisplayOnResize: listing.metadata.dynamicResolution,
			shouldClose: {
				// Closing a running VM powers it off, so veto the close and confirm first, like
				// the power button. The close proceeds once confirmed, or if the VM isn't running.
				if closeConfirmed || !runner.isActive(listing.id) { return true }
				isConfirmingClose = true
				return false
			},
			keyboardCaptured: $keyboardCaptured,
			guestIsRunning: state == .running)
			.background(.black)
			.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
			.navigationTitle(windowTitle)
			.toolbar {
				// One principal item holding an explicit HStack of spec chips, so the gaps between
				// chips and the end margins are controlled here rather than by the toolbar.
				ToolbarItem(placement: .principal) {
					// Hiding the chips while the window is narrow keeps the toolbar from pushing
					// them (and the Stop button) into an overflow » menu.
					if !isCompact {
						HStack(spacing: 9) {
							specChip(listing.metadata.guestOS.displayName,
									 systemImage: listing.metadata.guestOS.symbolName)
							specChip(listing.metadata.cpuCount == 1 ? "1 Core" : "\(listing.metadata.cpuCount) Cores",
									 systemImage: "cpu")
							specChip(memoryDescription(listing.metadata.memorySizeInBytes), systemImage: "memorychip")
							specChip(storageDescription(listing.bundle), systemImage: "internaldrive")
							specChip("\(listing.metadata.displayWidthInPixels) × \(listing.metadata.displayHeightInPixels)",
									 systemImage: "display")
							if listing.metadata.guestOS == .linux {
								specChip(listing.metadata.dynamicResolution ? "Matches window" : "Fixed",
										 systemImage: "arrow.up.left.and.arrow.down.right")
							}
							Image(systemName: keyboardCaptured ? "keyboard.fill" : "keyboard")
								.foregroundStyle(keyboardCaptured ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
								.help(keyboardHelp)
						}
						.padding(.horizontal, 16)
					}
				}
				ToolbarItemGroup(placement: .primaryAction) {
					switch state {
					case .stopped, .failed:
						Button {
							runner.start(listing)
						} label: {
							Label("Start", systemImage: "play.fill")
						}
					default:
						// Graceful shutdown is only offered once the guest is fully up.
						if state == .running {
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
					}
				}
			}
			.overlay { statusOverlay(for: state) }
			.onAppear {
				let instance = runner.makeInstance(for: listing)
				if instance.state == .stopped { instance.start() }
			}
			.onChange(of: state) { _, newState in
				// When the guest powers off, detect a completed install (the disk has grown) and
				// auto-eject the installer so future boots come from the disk.
				if newState == .stopped {
					library.ejectInstallerIfInstalled(listing)
					// Close only when the user powered off by closing the window (red X). A guest-
					// initiated shutdown or a toolbar Stop leaves the window open on the Powered Off
					// overlay so it can be restarted in place.
					if closeConfirmed { dismiss() }
				}
			}
			.confirmationDialog("Do you want to force “\(listing.name)” to power off?",
								isPresented: $isConfirmingForceStop, titleVisibility: .visible) {
				Button("Force Stop", role: .destructive) {
					runner.forceStop(listing.id)
				}
			} message: {
				Text("Unsaved work in the guest may be lost — this is like pulling the plug.")
			}
			.confirmationDialog("Do you want to force “\(listing.name)” to power off?",
								isPresented: $isConfirmingClose, titleVisibility: .visible) {
				Button("Force Stop", role: .destructive) {
					closeConfirmed = true
					runner.forceStop(listing.id)
					dismiss()
				}
			} message: {
				Text("Closing this window powers off the VM. Unsaved work in the guest may be lost.")
			}
	}

	/// A titlebar spec chip: an SF Symbol snug against its value.
	private func specChip(_ value: String, systemImage: String) -> some View {
		HStack(spacing: 4) {
			Image(systemName: systemImage)
			Text(value)
		}
		.foregroundStyle(.secondary)
	}

	private func memoryDescription(_ bytes: UInt64) -> String {
		String(format: "%.0f GB", Double(bytes) / 1_073_741_824)
	}

	private func storageDescription(_ bundle: VMBundle) -> String {
		guard let bytes = bundle.diskImageSizeInBytes else { return "—" }
		let gigabytes = Double(bytes) / 1_073_741_824
		if gigabytes >= 1024 {
			return String(format: "%.0f TB", gigabytes / 1024)
		}
		return String(format: "%.0f GB", gigabytes)
	}

	@ViewBuilder private func statusOverlay(for state: VMRunState) -> some View {
		switch state {
		case .stopped:
			// The builder form plus fixedSize overrides ContentUnavailableView's narrow description
			// column, which would otherwise wrap this short sentence. fixedSize is applied to the whole
			// view (not just the Text) so its frame — and the material background — grows to fit the
			// one-line description instead of letting the text spill outside the card.
			ContentUnavailableView {
				Label("Powered Off", systemImage: "power")
			} description: {
				Text("This virtual machine isn’t running.\n\nPress Start \(Image(systemName: "play.circle")) in the toolbar to boot it.")
			}
			.fixedSize()
			.padding(.horizontal, 24)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
		case .starting:
			ProgressView("Starting…")
				.padding()
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
		case .failed(let message):
			ContentUnavailableView(
				"Virtual Machine Stopped",
				systemImage: "exclamationmark.triangle",
				description: Text(message))
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
		default:
			EmptyView()
		}
	}
}
