// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Darwin
import Foundation
import Observation
import Virtualization

/// A discovered virtual machine: its bundle plus decoded metadata.
struct VMListing: Identifiable, Hashable, Sendable {
	let bundle: VMBundle
	let metadata: VMMetadata

	var id: VMBundle.ID { bundle.id }

	/// The VM's name — its bundle's folder name, the single source of truth.
	var name: String { bundle.displayName }

	// Include metadata so edits are detected — comparing only the bundle would let SwiftUI
	// treat an edited VM as unchanged and skip refreshing the detail view.
	static func == (lhs: VMListing, rhs: VMListing) -> Bool {
		lhs.bundle == rhs.bundle && lhs.metadata == rhs.metadata
	}
	func hash(into hasher: inout Hasher) { hasher.combine(bundle) }
}

/// An in-memory view model over the collection of virtual machine bundles on disk.
@MainActor
@Observable
final class VMLibrary {
	/// The directory that holds all VM bundles.
	let rootDirectory: URL

	/// The virtual machines discovered on disk, sorted by name.
	private(set) var machines: [VMListing] = []

	/// Keeps the library in sync with changes the user makes to the VMs folder in Finder.
	private var watcher: DirectoryWatcher?

	init(rootDirectory: URL? = nil) {
		self.rootDirectory = rootDirectory ?? FileManager.default
			.homeDirectoryForCurrentUser
			.appendingPathComponent("MokaRigVMs", isDirectory: true)
		try? FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
		reload()
		watcher = DirectoryWatcher(url: self.rootDirectory) { [weak self] in
			guard let self else { return }
			Task { @MainActor in self.reload() }
		}
	}

	/// Rescans the root directory for VM bundles.
	func reload() {
		let contents = (try? FileManager.default.contentsOfDirectory(
			at: rootDirectory,
			includingPropertiesForKeys: nil)) ?? []

		machines = contents
			.filter { $0.pathExtension == VMBundle.fileExtension }
			.compactMap { url in
				let bundle = VMBundle(url: url)
				guard let metadata = try? bundle.loadMetadata() else { return nil }
				return VMListing(bundle: bundle, metadata: metadata)
			}
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}

	/// Returns the loaded listing for the given bundle identity, or nil if none is present.
	func listing(for id: VMBundle.ID) -> VMListing? {
		machines.first { $0.bundle.id == id }
	}

	/// Returns a unique bundle URL for a new VM with the given name, sanitized for use as a folder
	/// name and de-duplicated against existing bundles with a numeric suffix.
	func availableBundleURL(forName name: String) -> URL {
		let trimmed = VMMetadata.sanitizedInput(name).trimmingCharacters(in: .whitespacesAndNewlines)
		let safeName = trimmed.isEmpty ? "Virtual Machine" : trimmed
		var candidate = rootDirectory
			.appendingPathComponent(safeName)
			.appendingPathExtension(VMBundle.fileExtension)
		var index = 2
		while FileManager.default.fileExists(atPath: candidate.path) {
			candidate = rootDirectory
				.appendingPathComponent("\(safeName) \(index)")
				.appendingPathExtension(VMBundle.fileExtension)
			index += 1
		}
		return candidate
	}

	/// Creates a new Linux VM bundle that boots the given installer ISO on first launch.
	@discardableResult
	func createLinuxVM(name: String, cpuCount: Int, memoryBytes: UInt64,
					   diskBytes: UInt64, displayWidth: Int, displayHeight: Int,
					   displayPixelsPerInch: Int, dynamicResolution: Bool,
					   installerISO: URL) throws -> VMListing {
		let bundle = VMBundle(url: availableBundleURL(forName: name))
		try bundle.createDirectory()
		try bundle.createBlankDiskImage(sizeInBytes: diskBytes)

		var metadata = VMMetadata.defaultLinux
		metadata.cpuCount = cpuCount
		metadata.memorySizeInBytes = memoryBytes
		metadata.displayWidthInPixels = displayWidth
		metadata.displayHeightInPixels = displayHeight
		metadata.pixelsPerInch = displayPixelsPerInch
		metadata.dynamicResolution = dynamicResolution
		metadata.needsInstall = true
		metadata.installerMediaPath = installerISO.path
		metadata.cloneGroup = UUID()
		try bundle.save(metadata)

		reload()
		// Return the reloaded listing so its identity matches the entries in `machines` — a freshly
		// constructed URL normalizes differently (directory flag, trailing slash) than the ones the
		// file system hands back, which would break sidebar selection.
		let targetPath = bundle.url.standardizedFileURL.path
		return machines.first { $0.bundle.url.standardizedFileURL.path == targetPath }
			?? VMListing(bundle: bundle, metadata: metadata)
	}

	/// Writes updated metadata for an existing VM and rescans. The VM's name lives in its folder name,
	/// not in metadata, so this never renames the bundle — use `rename(_:to:)` for that.
	@discardableResult
	func update(_ listing: VMListing, metadata: VMMetadata) throws -> VMListing {
		try listing.bundle.save(metadata)
		reload()
		return machines.first { $0.id == listing.id }
			?? VMListing(bundle: listing.bundle, metadata: metadata)
	}

	/// Renames a VM by moving its bundle folder, and rescans. Returns the renamed listing so callers
	/// can follow the identity change, since a VM is identified by its bundle URL.
	///
	/// Like Finder, a rename to a name already in use is rejected rather than silently de-duplicated:
	/// the user chose that name, so the collision is surfaced as `VMError.nameInUse`. A no-op rename
	/// (same name after sanitizing) returns the current listing unchanged.
	/// - Throws: `VMError.nameInUse` if another bundle already has the target name.
	@discardableResult
	func rename(_ listing: VMListing, to newName: String) throws -> VMListing {
		let sanitized = VMMetadata.sanitizedInput(newName).trimmingCharacters(in: .whitespacesAndNewlines)
		let targetName = sanitized.isEmpty ? "Virtual Machine" : sanitized
		if targetName == listing.name { return listing }

		let newURL = rootDirectory
			.appendingPathComponent(targetName)
			.appendingPathExtension(VMBundle.fileExtension)
		guard !FileManager.default.fileExists(atPath: newURL.path) else {
			throw VMError.nameInUse(targetName)
		}

		try FileManager.default.moveItem(at: listing.bundle.url, to: newURL)
		let bundle = VMBundle(url: newURL)
		try bundle.hideFileExtension()
		reload()
		// Match against the reloaded entries so the returned identity is the file-system URL, which
		// can normalize differently (e.g. trailing slash) than a freshly constructed one — a mismatch
		// there would break sidebar selection.
		let targetPath = newURL.standardizedFileURL.path
		return machines.first { $0.bundle.url.standardizedFileURL.path == targetPath }
			?? VMListing(bundle: bundle, metadata: listing.metadata)
	}

	/// Duplicates a VM into a new, independent bundle and returns its listing.
	///
	/// The bundle is cloned with APFS copy-on-write, so the copy is near-instant and uses no extra
	/// disk until the two VMs diverge; on a non-APFS or cross-volume location it falls back to a full
	/// copy. The duplicate is then given a fresh machine identifier so it isn't the same machine as
	/// the original to the network and the guest OS. The MAC address needs no attention — it isn't
	/// persisted; Virtualization assigns a new random one each time a VM is configured.
	///
	/// The source VM must be stopped so its disk image is copied in a consistent state.
	@discardableResult
	func duplicate(_ listing: VMListing, newName: String) throws -> VMListing {
		let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
		let resolvedName = trimmed.isEmpty ? "\(listing.name) copy" : trimmed
		let source = listing.bundle.url
		let destination = availableBundleURL(forName: resolvedName)
		// The duplicate shares the source's lineage ID — the same way a Finder copy of the bundle
		// would inherit it — so MokaRig keeps them from running at once until one is made independent.
		let group = listing.metadata.cloneGroup

		// COPYFILE_CLONE makes an APFS copy-on-write clone when possible and transparently falls back
		// to a byte copy otherwise. It requires the destination not to exist, which availableBundleURL
		// guarantees.
		let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
		guard copyfile(source.path, destination.path, nil, flags) == 0 else {
			throw VMError.duplicateFailed(String(cString: strerror(errno)))
		}

		let newBundle = VMBundle(url: destination)
		try? newBundle.hideFileExtension()
		try regenerateMachineIdentity(for: newBundle, guestOS: listing.metadata.guestOS)

		var metadata = listing.metadata
		metadata.cloneGroup = group
		try newBundle.save(metadata)

		reload()
		let targetPath = destination.standardizedFileURL.path
		return machines.first { $0.bundle.url.standardizedFileURL.path == targetPath }
			?? VMListing(bundle: newBundle, metadata: metadata)
	}

	/// Declares that a VM now has its own guest identity, so MokaRig will run it alongside the VMs it
	/// was copied with. It's the user's attestation that they gave the guest a unique hostname,
	/// machine-id, and SSH host keys. Assigns a fresh lineage ID (keeping the "every VM has one"
	/// invariant) and regenerates the machine identifier — the latter matters for a Finder copy, which
	/// shares the original's identifier, and is harmless for a Duplicate, which already has a fresh one.
	func makeIndependent(_ listing: VMListing) throws {
		var metadata = listing.metadata
		metadata.cloneGroup = UUID()
		try listing.bundle.save(metadata)
		try? regenerateMachineIdentity(for: listing.bundle, guestOS: metadata.guestOS)
		reload()
	}

	/// The other VMs that are copies of this one — they share its lineage ID. Empty when this VM has
	/// no copies (the common case), so nothing about it is guarded.
	func cloneSiblings(of listing: VMListing) -> [VMListing] {
		let group = listing.metadata.cloneGroup
		return machines.filter { $0.id != listing.id && $0.metadata.cloneGroup == group }
	}

	/// Replaces a bundle's machine identifier so a copy has its own hardware identity rather than
	/// sharing the original's.
	private func regenerateMachineIdentity(for bundle: VMBundle, guestOS: GuestOS) throws {
		switch guestOS {
		case .linux:
			// A Linux guest lazily creates its VZGenericMachineIdentifier on first boot, so removing
			// the copied file is enough — the next launch writes a fresh one.
			try? FileManager.default.removeItem(at: bundle.machineIdentifierURL)
		case .macOS:
			// A macOS guest requires the identifier to be present to build its platform, so write a
			// new one now.
			let identifier = VZMacMachineIdentifier()
			try identifier.dataRepresentation.write(to: bundle.machineIdentifierURL, options: .atomic)
		}
	}

	/// Stops attaching the installer media on future boots (the VM boots from its disk instead).
	/// Only updates metadata — the installer file on disk is never touched.
	func ejectInstaller(_ listing: VMListing) throws {
		var metadata = listing.metadata
		metadata.needsInstall = false
		try listing.bundle.save(metadata)
		reload()
	}

	/// The disk-usage threshold above which we assume a guest OS has been installed: a fresh sparse
	/// disk allocates almost nothing, while any real install writes gigabytes.
	static let installedDiskThreshold: UInt64 = 2 * 1024 * 1024 * 1024

	/// Silently ejects the installer if the VM still boots it but its disk has clearly been written
	/// to (a guest OS was installed). Returns the current (possibly updated) listing.
	@discardableResult
	func ejectInstallerIfInstalled(_ listing: VMListing) -> VMListing {
		guard listing.metadata.guestOS == .linux, listing.metadata.needsInstall,
			  let allocated = listing.bundle.diskImageAllocatedBytes,
			  allocated >= Self.installedDiskThreshold else { return listing }
		try? ejectInstaller(listing)
		return machines.first { $0.id == listing.id } ?? listing
	}

	/// Re-inserts the installer media so the VM boots it again, if the media file still exists.
	func reattachInstaller(_ listing: VMListing) throws {
		guard let path = listing.metadata.installerMediaPath,
			  FileManager.default.fileExists(atPath: path) else {
			throw VMError.installerMediaMissing
		}
		var metadata = listing.metadata
		metadata.needsInstall = true
		try listing.bundle.save(metadata)
		reload()
	}

	/// Moves the VM (and its large disk image) to the Trash so it can be recovered until the user
	/// empties it. Throws if the volume has no Trash, so callers can offer a permanent delete.
	func moveToTrash(_ listing: VMListing) throws {
		try FileManager.default.trashItem(at: listing.bundle.url, resultingItemURL: nil)
		reload()
	}

	/// Permanently deletes the VM bundle. Used as a fallback when the Trash isn't available.
	func permanentlyDelete(_ listing: VMListing) {
		try? FileManager.default.removeItem(at: listing.bundle.url)
		reload()
	}
}
