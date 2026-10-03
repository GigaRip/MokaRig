// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

// Renders an app's icon, as macOS draws it, into an .iconset that iconutil turns into an .icns.
//
// Usage: swift render-app-icon.swift <path to .app> <path to .iconset to create>
//
// macOS masks an app icon's images into its rounded app icon shape and shades them wherever it shows
// an app. Nothing does that for a custom file or volume icon, which shows its images as they are.
// Asking NSWorkspace for the app's icon gets the rounded, shaded icon Finder and the Dock show, so the
// DMG's icons match the app's exactly.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
	FileHandle.standardError.write(Data("usage: swift render-app-icon.swift <app> <iconset>\n".utf8))
	exit(2)
}
let appPath = arguments[1]
let iconsetPath = arguments[2]

guard FileManager.default.fileExists(atPath: appPath) else {
	FileHandle.standardError.write(Data("error: no app at \(appPath)\n".utf8))
	exit(1)
}
let icon = NSWorkspace.shared.icon(forFile: appPath)

// Every image an .iconset holds, named the way iconutil expects.
let images: [(name: String, pixels: Int)] = [
	("icon_16x16", 16), ("icon_16x16@2x", 32),
	("icon_32x32", 32), ("icon_32x32@2x", 64),
	("icon_128x128", 128), ("icon_128x128@2x", 256),
	("icon_256x256", 256), ("icon_256x256@2x", 512),
	("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
for image in images {
	guard
		let bitmap = NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: image.pixels,
			pixelsHigh: image.pixels,
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		)
	else {
		FileHandle.standardError.write(Data("error: could not make a \(image.pixels)-pixel bitmap\n".utf8))
		exit(1)
	}

	// Drawing at each pixel size lets NSImage pick the representation macOS made for that size.
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
	icon.draw(
		in: NSRect(x: 0, y: 0, width: image.pixels, height: image.pixels),
		from: .zero,
		operation: .copy,
		fraction: 1
	)
	NSGraphicsContext.restoreGraphicsState()

	guard let png = bitmap.representation(using: .png, properties: [:]) else {
		FileHandle.standardError.write(Data("error: could not encode \(image.name).png\n".utf8))
		exit(1)
	}
	try png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(image.name).png"))
}
