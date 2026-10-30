// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit
import GuestAgentCore

/// The agent's entry point. It takes no arguments in normal use.
///
/// - `--port <path>` uses another device node.
/// - `--pasteboard <name>` uses a named pasteboard instead of the general one, so end-to-end tests
///   leave the real clipboard alone.
@main
struct Entry {
	@MainActor
	static func main() {
		let arguments = UserDefaults.standard
		let portPath = arguments.string(forKey: "port") ?? GuestAgent.defaultPortPath
		let pasteboard = arguments.string(forKey: "pasteboard")
			.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general

		let agent = GuestAgent(portPath: portPath, backend: SystemPasteboard(pasteboard: pasteboard))
		agent.run()
		// The agent is reached through dispatch sources and notifications for the life of the process.
		withExtendedLifetime(agent) {
			RunLoop.main.run()
		}
	}
}
