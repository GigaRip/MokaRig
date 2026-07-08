// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// The persisted description of a virtual machine, stored as `Config.json` inside the VM bundle.
///
/// A VM's name is deliberately *not* stored here: it is the bundle's folder name (`VMBundle.displayName`),
/// the single source of truth. That makes names filesystem-unique for free and keeps them in sync with
/// Finder — no cached copy to drift.
struct VMMetadata: Codable, Equatable, Sendable {
	var guestOS: GuestOS
	var cpuCount: Int
	var memorySizeInBytes: UInt64
	var displayWidthInPixels: Int
	var displayHeightInPixels: Int
	/// The display pixel density. Only meaningful for macOS guests.
	var pixelsPerInch: Int
	/// Whether the VM still needs its OS installed. A Linux guest boots its installer ISO while true.
	var needsInstall: Bool
	/// The path to installer media (a Linux ISO) to attach while installing. Nil once removed.
	var installerMediaPath: String?
	/// Whether the guest display resizes to match the runner window (dynamic resolution).
	/// When off, the guest keeps a fixed resolution and the window scales its framebuffer —
	/// which preserves a HiDPI scale set inside the guest that a resize would otherwise reset.
	var dynamicResolution: Bool

	/// A lineage ID identifying VMs that are byte-for-byte copies of one another. Every VM gets a
	/// unique one at creation; a copy — whether made through Duplicate or by copying the bundle in
	/// Finder (which inherits this value) — shares it. VMs that share an ID also share a guest identity
	/// (hostname, machine-id, SSH host keys), so MokaRig won't run two of them at once until one is
	/// made independent (assigned a fresh ID).
	var cloneGroup: UUID

	/// The maximum VM name length, to keep the sidebar, window titles, and spec chips from overflowing.
	static let maxNameLength = 40

	/// The display density for a macOS guest with Retina (HiDPI) rendering enabled.
	static let retinaPixelsPerInch = 218
	/// The display density for a macOS guest with Retina rendering disabled.
	static let standardPixelsPerInch = 110

	/// Whether a stored macOS display density corresponds to Retina (HiDPI) rendering, deciding it by
	/// which of the two densities the value sits closer to so legacy densities still map sensibly.
	static func isRetina(pixelsPerInch ppi: Int) -> Bool {
		ppi >= (standardPixelsPerInch + retinaPixelsPerInch) / 2
	}

	/// Makes a raw name string safe to use as a bundle folder name: strips characters that can't
	/// appear in a filename (`/`, `:`, control characters), removes any leading dot (which would make
	/// a bundle Finder hides by default), and clamps to the length limit. Used to sanitize the name
	/// field as the user types. Does not substitute a default for an empty result — that's resolved
	/// when the bundle is actually created or renamed.
	static func sanitizedInput(_ raw: String) -> String {
		let illegal = CharacterSet(charactersIn: "/:").union(.controlCharacters)
		var cleaned = raw.components(separatedBy: illegal).joined()
		// Drop leading dots even behind leading whitespace, so a name like " .hidden" can't slip a
		// dot past the caller's later whitespace trim. Interior and trailing dots are untouched.
		while case let stripped = cleaned.drop(while: { $0 == " " }), stripped.first == "." {
			cleaned = String(stripped.drop(while: { $0 == "." }))
		}
		return String(cleaned.prefix(maxNameLength))
	}

	/// Sensible defaults for a new Linux guest.
	static let defaultLinux = VMMetadata(
		guestOS: .linux,
		cpuCount: 4,
		memorySizeInBytes: 4 * 1024 * 1024 * 1024,
		displayWidthInPixels: 1920,
		displayHeightInPixels: 1080,
		pixelsPerInch: 80,
		needsInstall: true,
		installerMediaPath: nil,
		dynamicResolution: false,
		cloneGroup: UUID())

	/// Sensible defaults for a new macOS guest.
	static let defaultMac = VMMetadata(
		guestOS: .macOS,
		cpuCount: 4,
		memorySizeInBytes: 8 * 1024 * 1024 * 1024,
		displayWidthInPixels: 2560,
		displayHeightInPixels: 1440,
		pixelsPerInch: retinaPixelsPerInch,
		needsInstall: true,
		installerMediaPath: nil,
		dynamicResolution: false,
		cloneGroup: UUID())
}
