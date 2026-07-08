// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// Errors surfaced by MokaRig's virtual machine management.
enum VMError: LocalizedError {
	case diskCreationFailed
	case missingBundleFile(String)
	case installerMediaMissing
	case unsupportedHardwareModel
	case configurationInvalid(String)
	case duplicateFailed(String)
	case nameInUse(String)

	var errorDescription: String? {
		switch self {
		case .diskCreationFailed:
			return "Failed to create the virtual machine's disk image."
		case .missingBundleFile(let name):
			return "The virtual machine is missing a required file: \(name)."
		case .installerMediaMissing:
			return "The installer media could not be found."
		case .unsupportedHardwareModel:
			return "This Mac can't run the selected macOS configuration."
		case .configurationInvalid(let reason):
			return "The virtual machine configuration is invalid: \(reason)"
		case .duplicateFailed(let reason):
			return "The virtual machine couldn't be duplicated: \(reason)"
		case .nameInUse(let name):
			return "A virtual machine named “\(name)” already exists."
		}
	}
}
