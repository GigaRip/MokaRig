// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Virtualization

extension VZVirtioConsoleDeviceConfiguration {
	/// A console device carrying the SPICE agent, which enables copy/paste in the guest and, for Linux
	/// guests, dynamic resolution. Both require a SPICE guest agent running in the guest.
	static func spiceAgent() -> VZVirtioConsoleDeviceConfiguration {
		let console = VZVirtioConsoleDeviceConfiguration()
		let port = VZVirtioConsolePortConfiguration()
		port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
		let attachment = VZSpiceAgentPortAttachment()
		attachment.sharesClipboard = true
		port.attachment = attachment
		console.ports[0] = port
		return console
	}
}
