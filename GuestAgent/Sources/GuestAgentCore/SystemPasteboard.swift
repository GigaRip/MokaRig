// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit

/// A `ClipboardBackend` over an `NSPasteboard`.
///
/// `availableTypes()` inspects only pasteboard type names, so a copy in the guest reads no contents.
/// Contents are read in `data(for:)`, when the host pastes.
public final class SystemPasteboard: ClipboardBackend {
	/// Markers set by password managers and similar apps, from the nspasteboard.org convention.
	private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
		NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
		NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
	]

	private let pasteboard: NSPasteboard

	/// Creates a backend over a pasteboard, which is the general pasteboard unless a test names another.
	public init(pasteboard: NSPasteboard = .general) {
		self.pasteboard = pasteboard
	}

	/// The current pasteboard change count.
	public var changeCount: Int {
		pasteboard.changeCount
	}

	/// The formats on the pasteboard. Empty when the contents are marked private.
	public func availableTypes() -> [ClipboardType] {
		guard let types = pasteboard.types, Self.privateTypes.isDisjoint(with: types) else { return [] }

		var available: [ClipboardType] = []
		if types.contains(.string) {
			available.append(.utf8Text)
		}
		// PNG is offered for TIFF-only content, which is what many Mac apps copy, because PNG is the
		// one image format the protocol requires a client to accept.
		if types.contains(.png) || types.contains(.tiff) {
			available.append(.png)
		}
		if types.contains(.tiff) {
			available.append(.tiff)
		}
		return available
	}

	/// The pasteboard contents in one format, converted from TIFF for PNG requests if necessary.
	public func data(for type: ClipboardType) -> Data? {
		switch type {
		case .utf8Text:
			return pasteboard.string(forType: .string)?.data(using: .utf8)
		case .png:
			return pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(Self.pngData)
		case .tiff:
			return pasteboard.data(forType: .tiff)
		case .none, .bmp, .jpg:
			return nil
		}
	}

	/// Replaces the pasteboard contents.
	public func write(_ items: [ClipboardType: Data]) {
		pasteboard.clearContents()
		for (type, contents) in items {
			guard let pasteboardType = Self.pasteboardType(for: type) else { continue }
			pasteboard.setData(contents, forType: pasteboardType)
		}
	}

	private static func pasteboardType(for type: ClipboardType) -> NSPasteboard.PasteboardType? {
		switch type {
		case .utf8Text: return .string
		case .png: return .png
		case .tiff: return .tiff
		case .none, .bmp, .jpg: return nil
		}
	}

	private static func pngData(fromTIFF tiff: Data) -> Data? {
		NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
	}
}
