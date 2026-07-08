// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// The kind of guest operating system a virtual machine runs.
enum GuestOS: String, Codable, CaseIterable, Identifiable, Sendable {
	case linux
	case macOS

	var id: String { rawValue }

	/// A human-readable name for display in the UI.
	var displayName: String {
		switch self {
		case .linux: return "Linux"
		case .macOS: return "macOS"
		}
	}

	/// The SF Symbol used to represent this guest in lists.
	var symbolName: String {
		switch self {
		case .linux: return "pc"
		case .macOS: return "apple.logo"
		}
	}
}
