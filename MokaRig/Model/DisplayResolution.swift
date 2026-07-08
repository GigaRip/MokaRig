// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// A selectable display resolution preset for a virtual machine's screen.
struct DisplayResolution: Identifiable, Hashable, Sendable {
	let widthInPixels: Int
	let heightInPixels: Int
	/// The pixel density. Drives HiDPI/Retina scaling for macOS guests; ignored by Linux (Virtio) guests.
	let pixelsPerInch: Int
	let label: String

	var id: String { "\(widthInPixels)x\(heightInPixels)" }

	/// A menu-friendly title, e.g. "1920 × 1080 — Full HD (1080p)".
	var menuTitle: String {
		"\(widthInPixels) × \(heightInPixels) — \(label)"
	}

	/// Standard (non-Retina) density, matching Apple's macOS VM sample; a macOS guest renders 1:1.
	private static let standardPPI = 80
	/// Retina density (~2×), matching Apple's 5K displays; a macOS guest renders HiDPI.
	private static let retinaPPI = 218

	/// The common 16:9 presets offered when creating a VM.
	static let presets: [DisplayResolution] = [
		DisplayResolution(widthInPixels: 1280, heightInPixels: 720, pixelsPerInch: standardPPI, label: "HD (720p)"),
		DisplayResolution(widthInPixels: 1366, heightInPixels: 768, pixelsPerInch: standardPPI, label: "WXGA"),
		DisplayResolution(widthInPixels: 1600, heightInPixels: 900, pixelsPerInch: standardPPI, label: "HD+"),
		DisplayResolution(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: standardPPI, label: "Full HD (1080p)"),
		DisplayResolution(widthInPixels: 2560, heightInPixels: 1440, pixelsPerInch: standardPPI, label: "QHD (1440p)"),
		DisplayResolution(widthInPixels: 3840, heightInPixels: 2160, pixelsPerInch: standardPPI, label: "4K UHD"),
		DisplayResolution(widthInPixels: 5120, heightInPixels: 2880, pixelsPerInch: retinaPPI, label: "5K Retina")
	]

	/// The default selection for a new VM (Full HD).
	static let defaultPreset = presets[3]
}
