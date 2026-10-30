// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit
import Testing
@testable import GuestAgentCore

@Suite struct SystemPasteboardTests {
	private static func makePasteboard() -> NSPasteboard {
		NSPasteboard(name: NSPasteboard.Name("com.gigarip.mokarig.tests.\(UUID().uuidString)"))
	}

	private static func tiffImage() throws -> Data {
		let image = NSImage(size: NSSize(width: 4, height: 4))
		image.lockFocus()
		NSColor.red.setFill()
		NSRect(x: 0, y: 0, width: 4, height: 4).fill()
		image.unlockFocus()
		return try #require(image.tiffRepresentation)
	}

	@Test func roundTripsText() {
		let pasteboard = Self.makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let backend = SystemPasteboard(pasteboard: pasteboard)
		let text = "Héllo\r\nwörld\t🙂"
		backend.write([.utf8Text: Data(text.utf8)])
		#expect(backend.availableTypes() == [.utf8Text])
		#expect(backend.data(for: .utf8Text) == Data(text.utf8))
		#expect(pasteboard.string(forType: .string) == text)
	}

	@Test func writeChangesTheChangeCount() {
		let pasteboard = Self.makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let backend = SystemPasteboard(pasteboard: pasteboard)
		let before = backend.changeCount
		backend.write([.utf8Text: Data("x".utf8)])
		#expect(backend.changeCount != before)
	}

	@Test func writesEveryRepresentationToOneItem() {
		let pasteboard = Self.makePasteboard()
		defer { pasteboard.releaseGlobally() }
		SystemPasteboard(pasteboard: pasteboard).write([.utf8Text: Data("t".utf8), .png: Data([1, 2, 3])])
		#expect(pasteboard.pasteboardItems?.count == 1)
		#expect(pasteboard.data(forType: .png) == Data([1, 2, 3]))
		#expect(pasteboard.string(forType: .string) == "t")
	}

	@Test func offersAndConvertsPNGForTIFFContent() throws {
		let pasteboard = Self.makePasteboard()
		defer { pasteboard.releaseGlobally() }
		let tiff = try Self.tiffImage()
		pasteboard.clearContents()
		pasteboard.setData(tiff, forType: .tiff)
		let backend = SystemPasteboard(pasteboard: pasteboard)
		#expect(backend.availableTypes() == [.png, .tiff])
		let png = try #require(backend.data(for: .png))
		#expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4e, 0x47])
		#expect(backend.data(for: .tiff) == tiff)
	}

	@Test func withholdsConcealedContent() {
		let pasteboard = Self.makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("hunter2", forType: .string)
		pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
		#expect(SystemPasteboard(pasteboard: pasteboard).availableTypes().isEmpty)
	}

	@Test func withholdsTransientContent() {
		let pasteboard = Self.makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		pasteboard.setString("temp", forType: .string)
		pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
		#expect(SystemPasteboard(pasteboard: pasteboard).availableTypes().isEmpty)
	}

	@Test func offersNothingForAnEmptyPasteboard() {
		let pasteboard = Self.makePasteboard()
		defer { pasteboard.releaseGlobally() }
		pasteboard.clearContents()
		#expect(SystemPasteboard(pasteboard: pasteboard).availableTypes().isEmpty)
	}
}
