// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI

/// A sheet for editing an existing virtual machine's configuration. Offered only while the VM is stopped.
struct EditVMSheet: View {
	@Environment(VMLibrary.self) private var library
	@Environment(VMRunner.self) private var runner
	@Environment(\.dismiss) private var dismiss
	let listing: VMListing
	/// The sidebar selection, updated when a rename gives the VM a new bundle identity.
	@Binding var selection: VMBundle.ID?

	@State private var name: String
	@State private var cpuCount: Int
	@State private var memoryGB: Int
	@State private var resolution: DisplayResolution
	@State private var dynamicResolution: Bool
	@State private var retina: Bool
	@State private var attachMouse: Bool
	@State private var errorMessage: String?

	init(listing: VMListing, selection: Binding<VMBundle.ID?>) {
		self.listing = listing
		self._selection = selection
		let metadata = listing.metadata
		_name = State(initialValue: listing.name)
		_cpuCount = State(initialValue: metadata.cpuCount)
		_memoryGB = State(initialValue: max(1, Int(metadata.memorySizeInBytes / 1_073_741_824)))
		// Match the stored resolution to a preset, or synthesize a one-off entry so the picker
		// always has a selection that reflects the VM's current display size.
		let preset = DisplayResolution.presets.first {
			$0.widthInPixels == metadata.displayWidthInPixels && $0.heightInPixels == metadata.displayHeightInPixels
		}
		_resolution = State(initialValue: preset ?? DisplayResolution(
			widthInPixels: metadata.displayWidthInPixels,
			heightInPixels: metadata.displayHeightInPixels,
			pixelsPerInch: metadata.pixelsPerInch,
			label: "Custom"))
		_dynamicResolution = State(initialValue: metadata.dynamicResolution)
		_retina = State(initialValue: VMMetadata.isRetina(pixelsPerInch: metadata.pixelsPerInch))
		_attachMouse = State(initialValue: metadata.attachMouse)
	}

	/// Processor counts offered, always including the VM's current value.
	private var cpuOptions: [Int] {
		Array(Set(NewVMSheet.cpuOptions + [cpuCount])).sorted()
	}

	/// Memory sizes (GB) offered, always including the VM's current value.
	private var memoryOptions: [Int] {
		Array(Set(NewVMSheet.memoryOptionsGB + [memoryGB])).sorted()
	}

	/// Display presets offered, always including the VM's current resolution.
	private var resolutionOptions: [DisplayResolution] {
		var options = DisplayResolution.presets
		if !options.contains(resolution) { options.append(resolution) }
		return options
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					LabeledContent {
						Text(listing.metadata.guestOS.displayName)
							.foregroundStyle(.secondary)
					} label: {
						Label("Guest OS", systemImage: "pc")
					}

					LabeledContent {
						TextField(text: $name, prompt: Text(listing.name)) {
							Text("Name")
						}
						.labelsHidden()
						.onChange(of: name) { _, newValue in
							let sanitized = VMMetadata.sanitizedInput(newValue)
							if sanitized != newValue { name = sanitized }
						}
					} label: {
						Label("Name", systemImage: "tag")
					}
				}

				Section("Resources") {
					Picker(selection: $cpuCount) {
						ForEach(cpuOptions, id: \.self) { count in
							Text(count == 1 ? "1 Core" : "\(count) Cores").tag(count)
						}
					} label: {
						Label("Compute", systemImage: "cpu")
					}
					Picker(selection: $memoryGB) {
						ForEach(memoryOptions, id: \.self) { gb in
							Text("\(gb) GB").tag(gb)
						}
					} label: {
						Label("Memory", systemImage: "memorychip")
					}
					LabeledContent {
						Text(storageDescription)
							.foregroundStyle(.secondary)
					} label: {
						Label("Storage", systemImage: "internaldrive")
					}
					Picker(selection: $resolution) {
						ForEach(resolutionOptions) { preset in
							Text(preset.menuTitle).tag(preset)
						}
					} label: {
						Label("Display", systemImage: "display")
					}
					// Dynamic resolution is driven by a Linux guest agent; macOS guests don't use it.
					if listing.metadata.guestOS == .linux {
						Toggle(isOn: $dynamicResolution) {
							VStack(alignment: .leading, spacing: 2) {
								Label("Match Resolution to Window", systemImage: "arrow.up.left.and.arrow.down.right")
								Text("Requires a guest agent in the VM (e.g. spice-vdagent).")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
					}
					// Pixel density (Retina vs standard) only affects macOS guests; Linux ignores it.
					if listing.metadata.guestOS == .macOS {
						Toggle(isOn: $retina) {
							VStack(alignment: .leading, spacing: 2) {
								Label("Retina", systemImage: "sparkles")
								Text("Renders the display at HiDPI for sharp text.")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						Toggle(isOn: $attachMouse) {
							VStack(alignment: .leading, spacing: 2) {
								Label("Attach Mouse", systemImage: "computermouse")
								Text("A trackpad is always attached; add a mouse for a plain pointer and a Mouse settings pane.")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
					}
				}

				if let errorMessage {
					Section {
						Label(errorMessage, systemImage: "exclamationmark.triangle")
							.foregroundStyle(.red)
					}
				}
			}
			.formStyle(.grouped)
			// A custom, leading-aligned header matching the New Virtual Machine sheet.
			.safeAreaInset(edge: .top, spacing: 0) {
				HStack(spacing: 10) {
					Image(systemName: "square.and.pencil")
						.font(.title2)
						.foregroundStyle(.tint)
					Text("Edit Virtual Machine")
						.font(.title3.weight(.semibold))
					Spacer()
				}
				.padding(.leading, 18)
				.padding(.trailing, 20)
				.padding(.top, 20)
				.padding(.bottom, 12)
			}
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Save") { save() }
				}
			}
		}
		.frame(minWidth: 460)
		.presentationSizing(.fitted)
	}

	// MARK: - Derived state

	private var storageDescription: String {
		guard let bytes = listing.bundle.diskImageSizeInBytes else { return "—" }
		let gigabytes = Double(bytes) / 1_073_741_824
		if gigabytes >= 1024 {
			return String(format: "%.0f TB", gigabytes / 1024)
		}
		return String(format: "%.0f GB", gigabytes)
	}

	private var resolvedName: String {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? listing.name : trimmed
	}

	/// The display density to store: the Retina toggle drives it for macOS; Linux keeps the preset's
	/// value, which it ignores.
	private var displayPixelsPerInch: Int {
		listing.metadata.guestOS == .macOS
			? (retina ? VMMetadata.retinaPixelsPerInch : VMMetadata.standardPixelsPerInch)
			: resolution.pixelsPerInch
	}

	// MARK: - Actions

	private func save() {
		var metadata = listing.metadata
		metadata.cpuCount = cpuCount
		metadata.memorySizeInBytes = UInt64(memoryGB) * 1_073_741_824
		metadata.displayWidthInPixels = resolution.widthInPixels
		metadata.displayHeightInPixels = resolution.heightInPixels
		metadata.pixelsPerInch = displayPixelsPerInch
		metadata.dynamicResolution = dynamicResolution
		metadata.attachMouse = attachMouse
		do {
			// Rename first: it's the only step that can fail on a name collision, and doing it before
			// writing config leaves nothing to unwind if it throws. A no-op rename returns `listing`.
			let renamed = try library.rename(listing, to: resolvedName)
			try library.update(renamed, metadata: metadata)
			// Drop any cached instance so the next launch rebuilds from the edited config (e.g.
			// adding/removing the pointing device). Safe because editing only happens while stopped.
			runner.forget(listing.id)
			// A rename changes the bundle URL — the VM's identity — so follow it in the sidebar.
			if renamed.id != listing.id {
				selection = renamed.id
			}
			dismiss()
		} catch {
			errorMessage = error.localizedDescription
		}
	}
}
