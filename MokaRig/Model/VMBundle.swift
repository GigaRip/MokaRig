// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// A virtual machine package on disk: a directory containing the disk image, boot data, and metadata.
struct VMBundle: Identifiable, Hashable, Sendable {
	/// The bundle directory URL. Also serves as the stable identity of the VM.
	let url: URL

	var id: URL { url }

	static let fileExtension = "mokarig"

	var configURL: URL { url.appendingPathComponent("Config.json") }
	var diskImageURL: URL { url.appendingPathComponent("Disk.img") }
	var efiVariableStoreURL: URL { url.appendingPathComponent("NVRAM") }
	var machineIdentifierURL: URL { url.appendingPathComponent("MachineIdentifier") }
	var hardwareModelURL: URL { url.appendingPathComponent("HardwareModel") }
	var auxiliaryStorageURL: URL { url.appendingPathComponent("AuxiliaryStorage") }

	/// The bundle name without the file extension.
	var displayName: String { url.deletingPathExtension().lastPathComponent }

	/// The logical size of the main disk image in bytes, or nil if it can't be read.
	var diskImageSizeInBytes: UInt64? {
		let values = try? diskImageURL.resourceValues(forKeys: [.fileSizeKey])
		return values?.fileSize.map(UInt64.init)
	}

	/// The disk image's actual on-disk (allocated) size — near zero for a fresh sparse image, but
	/// several GB once a guest OS is installed. Used to detect that an install has happened.
	var diskImageAllocatedBytes: UInt64? {
		let values = try? diskImageURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
		return values?.totalFileAllocatedSize.map(UInt64.init)
	}

	/// Decodes the VM's persisted metadata from `Config.json`.
	func loadMetadata() throws -> VMMetadata {
		let data = try Data(contentsOf: configURL)
		return try JSONDecoder().decode(VMMetadata.self, from: data)
	}

	/// Writes the VM's metadata to `Config.json`.
	func save(_ metadata: VMMetadata) throws {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let data = try encoder.encode(metadata)
		try data.write(to: configURL, options: .atomic)
	}

	/// Creates the bundle directory on disk.
	func createDirectory() throws {
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		try hideFileExtension()
	}

	/// Marks the bundle so Finder hides its `.mokarig` extension.
	///
	/// Combined with the package type declared in Info.plist, this makes VMs read as plain
	/// names. Note: the global "Show all filename extensions" Finder setting overrides this.
	func hideFileExtension() throws {
		try FileManager.default.setAttributes([.extensionHidden: true], ofItemAtPath: url.path)
	}

	/// Creates an empty, sparse main disk image of the requested size.
	func createBlankDiskImage(sizeInBytes: UInt64) throws {
		guard FileManager.default.createFile(atPath: diskImageURL.path, contents: nil) else {
			throw VMError.diskCreationFailed
		}
		let handle = try FileHandle(forWritingTo: diskImageURL)
		defer { try? handle.close() }
		try handle.truncate(atOffset: sizeInBytes)
	}
}
