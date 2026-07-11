// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI
import UniformTypeIdentifiers
import Virtualization

/// A sheet for creating a new virtual machine. Linux installs from an ISO; macOS restores from an IPSW.
struct NewVMSheet: View {
	@Environment(VMLibrary.self) private var library
	@Environment(\.dismiss) private var dismiss
	/// The sidebar selection, moved to the VM once it's created.
	@Binding var selection: VMBundle.ID?

	/// The sensible CPU-count ceiling: the host's core count (never more than the framework allows).
	/// `maximumAllowedCPUCount` is an absolute API limit (64), not the hardware — assigning more
	/// vCPUs than physical cores only hurts performance, so cap at the actual core count.
	static let maxCPUCount = min(VZVirtualMachineConfiguration.maximumAllowedCPUCount,
								 ProcessInfo.processInfo.activeProcessorCount)

	/// Offered processor counts: a single core, then even counts up to the host maximum.
	static let cpuOptions: [Int] = {
		var options = [1]
		var value = 2
		while value <= maxCPUCount {
			options.append(value)
			value += 2
		}
		return options
	}()

	/// Offered memory sizes (GB). Capped by the Virtualization framework's ceiling and, more importantly,
	/// at ~75% of physical RAM — handing a guest the host's full memory starves macOS and MokaRig and
	/// invites heavy swapping, so always leave the host roughly a quarter.
	static let memoryOptionsGB: [Int] = {
		let hostReserveCeiling = UInt64(Double(ProcessInfo.processInfo.physicalMemory) * 0.75)
		let ceiling = min(VZVirtualMachineConfiguration.maximumAllowedMemorySize, hostReserveCeiling)
		return [1, 2, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256]
			.filter { UInt64($0) * 1_073_741_824 <= ceiling }
	}()

	/// Offered storage sizes (GB). Disk images are sparse, so a large size doesn't consume space up front.
	static let storageOptionsGB = [32, 64, 128, 256, 512, 1024]

	/// The smallest disk offered for a macOS guest — the OS and its updates need more room than Linux.
	static let minMacStorageGB = 128

	/// The smallest memory offered for a macOS guest — 1–4 GB can't run a modern macOS sensibly.
	static let minMacMemoryGB = 8

	/// Default memory for a new VM: 16 GB (prudent for Ubuntu Desktop), clamped to what the host offers.
	static let defaultMemoryGB = min(16, memoryOptionsGB.last ?? 16)

	@State private var guestOS: GuestOS = .linux
	@State private var name = ""
	@State private var cpuCount = min(4, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
	@State private var memoryGB = NewVMSheet.defaultMemoryGB
	@State private var diskGB = 64
	@State private var resolution: DisplayResolution = .defaultPreset
	@State private var dynamicResolution = false
	@State private var retina = true
	@State private var attachMouse = false
	@State private var mediaURL: URL?
	@State private var isImportingMedia = false

	@State private var installer = MacInstaller()
	@State private var errorMessage: String?

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Picker(selection: $guestOS) {
						ForEach(GuestOS.allCases) { os in
							Text(os.displayName).tag(os)
						}
					} label: {
						Label("Guest OS", systemImage: "pc")
					}
					.disabled(isBusy)

					LabeledContent {
						TextField(text: $name, prompt: Text(defaultName)) {
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
						ForEach(Self.cpuOptions, id: \.self) { count in
							Text(count == 1 ? "1 Core" : "\(count) Cores").tag(count)
						}
					} label: {
						Label("Compute", systemImage: "cpu")
					}
					.disabled(isBusy)
					Picker(selection: $memoryGB) {
						ForEach(memoryOptions, id: \.self) { gb in
							Text("\(gb) GB").tag(gb)
						}
					} label: {
						Label("Memory", systemImage: "memorychip")
					}
					.disabled(isBusy)
					Picker(selection: $diskGB) {
						ForEach(storageOptions, id: \.self) { gb in
							Text(gb >= 1024 ? "\(gb / 1024) TB" : "\(gb) GB").tag(gb)
						}
					} label: {
						Label("Storage", systemImage: "internaldrive")
					}
					.disabled(isBusy)
					// The trackpad is always attached; the mouse is the opt-in pointer.
					if guestOS == .macOS {
						Toggle(isOn: $attachMouse) {
							VStack(alignment: .leading, spacing: 2) {
								Label("Attach Mouse", systemImage: "computermouse")
								Text("A trackpad is always attached; add a mouse for a plain pointer and a Mouse settings pane.")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						.disabled(isBusy)
					}
				}

				Section("Display") {
					// One control instead of a resolution picker plus a toggle that silently overrides it:
					// Fixed Size keeps the chosen resolution; Fit to Window lets the guest track the window.
					Picker(selection: $dynamicResolution) {
						Text("Fixed Size").tag(false)
						Text("Fit to Window").tag(true)
					} label: {
						VStack(alignment: .leading, spacing: 2) {
							Label("Mode", systemImage: "arrow.up.left.and.arrow.down.right")
							if dynamicResolution {
								Text(resolutionCaption)
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
					}
					.disabled(isBusy)
					if !dynamicResolution {
						Picker(selection: $resolution) {
							ForEach(DisplayResolution.presets) { preset in
								Text(preset.menuTitle).tag(preset)
							}
						} label: {
							Label("Screen Size", systemImage: "display")
						}
						.disabled(isBusy)
					}
					// Pixel density (Retina vs standard) only affects macOS guests; Linux ignores it.
					if guestOS == .macOS {
						Toggle(isOn: $retina) {
							VStack(alignment: .leading, spacing: 2) {
								Label("Retina", systemImage: "sparkles")
								Text("Renders the display at HiDPI for sharp text.")
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
						.disabled(isBusy)
					}
				}

				Section(mediaSectionTitle) {
					HStack {
						Text(mediaURL?.lastPathComponent ?? "None selected")
							.foregroundStyle(mediaURL == nil ? .secondary : .primary)
							.lineLimit(1)
							.truncationMode(.middle)
						Spacer()
						Button("Choose…") { isImportingMedia = true }
							.disabled(isBusy)
					}
				}

				if case .installing(let fraction) = installer.phase {
					Section {
						ProgressView(value: fraction) {
							Text("Installing macOS…")
						} currentValueLabel: {
							Text(fraction.formatted(.percent.precision(.fractionLength(0))))
						}
					}
				} else if case .preparing = installer.phase {
					Section { ProgressView("Preparing…") }
				}

				if let errorMessage {
					Section {
						Label(errorMessage, systemImage: "exclamationmark.triangle")
							.foregroundStyle(.red)
					}
				}
			}
			.formStyle(.grouped)
			// A macOS guest needs more disk and memory than Linux, so raise the selections when switching.
			.onChange(of: guestOS) { _, newValue in
				if newValue == .macOS {
					diskGB = max(diskGB, Self.minMacStorageGB)
					memoryGB = max(memoryGB, Self.minMacMemoryGB)
				}
			}
			// A custom, leading-aligned header so the title lines up with the form content
			// instead of using the more-indented default navigation title.
			.safeAreaInset(edge: .top, spacing: 0) {
				HStack(spacing: 10) {
					Image(systemName: "desktopcomputer")
						.font(.title2)
						.foregroundStyle(.tint)
					Text("New Virtual Machine")
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
						.disabled(isBusy)
				}
				ToolbarItem(placement: .confirmationAction) {
					Button("Create") { create() }
						.disabled(mediaURL == nil || isBusy)
				}
			}
			.fileImporter(isPresented: $isImportingMedia,
						  allowedContentTypes: mediaContentTypes) { result in
				if case .success(let url) = result {
					_ = url.startAccessingSecurityScopedResource()
					mediaURL = url
				}
			}
		}
		.frame(width: 540, height: 575)
	}

	// MARK: - Derived state

	/// Storage sizes offered for the selected guest — macOS starts at a higher floor than Linux.
	private var storageOptions: [Int] {
		guestOS == .macOS ? Self.storageOptionsGB.filter { $0 >= Self.minMacStorageGB } : Self.storageOptionsGB
	}

	/// Memory sizes offered for the selected guest — macOS starts at a higher floor than Linux.
	private var memoryOptions: [Int] {
		guestOS == .macOS ? Self.memoryOptionsGB.filter { $0 >= Self.minMacMemoryGB } : Self.memoryOptionsGB
	}

	/// Caption shown when Fit to Window is selected: macOS resizes natively, Linux needs a guest agent.
	private var resolutionCaption: String {
		guestOS == .linux
			? "The guest display resizes to match the window. Requires a guest agent (e.g. spice-vdagent)."
			: "The guest display resizes to match the window."
	}

	/// The display density to store: the Retina toggle drives it for macOS; Linux keeps the preset's
	/// value, which it ignores.
	private var displayPixelsPerInch: Int {
		guestOS == .macOS
			? (retina ? VMMetadata.retinaPixelsPerInch : VMMetadata.standardPixelsPerInch)
			: resolution.pixelsPerInch
	}

	private var isBusy: Bool {
		switch installer.phase {
		case .preparing, .installing: return true
		default: return false
		}
	}

	private var defaultName: String {
		guestOS == .linux ? "Linux VM" : "macOS VM"
	}

	private var resolvedName: String {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? defaultName : trimmed
	}

	private var mediaSectionTitle: String {
		guestOS == .linux ? "Installer ISO" : "Restore Image (IPSW)"
	}

	private var mediaContentTypes: [UTType] {
		switch guestOS {
		case .linux:
			return [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage, .data]
		case .macOS:
			return [UTType(filenameExtension: "ipsw") ?? .data, .data]
		}
	}

	// MARK: - Actions

	private func create() {
		guard let mediaURL else { return }
		errorMessage = nil
		let memoryBytes = UInt64(memoryGB) * 1_073_741_824
		let diskBytes = UInt64(diskGB) * 1_073_741_824

		switch guestOS {
		case .linux:
			do {
				let created = try library.createLinuxVM(name: resolvedName, cpuCount: cpuCount,
										  memoryBytes: memoryBytes, diskBytes: diskBytes,
										  displayWidth: resolution.widthInPixels,
										  displayHeight: resolution.heightInPixels,
										  displayPixelsPerInch: displayPixelsPerInch,
										  dynamicResolution: dynamicResolution,
										  installerISO: mediaURL)
				selection = created.id
				dismiss()
			} catch {
				errorMessage = error.localizedDescription
			}
		case .macOS:
			Task {
				let createdID = await installer.install(name: resolvedName, cpuCount: cpuCount,
										memoryBytes: memoryBytes, diskBytes: diskBytes,
										displayWidth: resolution.widthInPixels,
										displayHeight: resolution.heightInPixels,
										displayPixelsPerInch: displayPixelsPerInch,
										dynamicResolution: dynamicResolution,
										attachMouse: attachMouse,
										ipswURL: mediaURL, into: library)
				switch installer.phase {
				case .finished:
					selection = createdID
					dismiss()
				case .failed(let message):
					errorMessage = message
				default:
					break
				}
			}
		}
	}
}
