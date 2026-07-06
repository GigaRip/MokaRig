// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI
import Sparkle

@main
struct MokaRigApp: App {
    /// The shared library of virtual machines, discovered on disk.
    @State private var library = VMLibrary()

    /// The shared registry of live VM instances, so run state is visible across windows.
    @State private var runner = VMRunner()

    /// The identifier of the auxiliary window used to run and display a single VM.
    static let runnerWindowID = "vm-runner"

	/// Drives in-app auto-updates via Sparkle. Held for the app's lifetime so the updater keeps
	/// running; `startingUpdater: true` begins checking for updates at launch.
	private let updaterController = SPUStandardUpdaterController(
		startingUpdater: true,
		updaterDelegate: nil,
		userDriverDelegate: nil
	)

	var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(runner)
                .frame(minWidth: 720, minHeight: 460)
        }
		.commands {
			CommandGroup(after: .appInfo) {
				CheckForUpdatesView(updater: updaterController.updater)
			}
			// Replace the default (help-book-less) Help item with a link to file an issue on GitHub.
			CommandGroup(replacing: .help) {
				if let url = URL(string: "https://github.com/GigaRip/MokaRig/issues/new?template=bug_report.yml") {
					Link("Report a Bug…", destination: url)
				}
			}
		}
		.defaultSize(width: 820, height: 700)

        // A dedicated window per running VM, keyed by the VM bundle's URL.
        // Runner windows are transient, so don't restore them at launch — otherwise the
        // app can reopen a VM window instead of the main library window.
        WindowGroup(id: MokaRigApp.runnerWindowID, for: URL.self) { $bundleURL in
            VMRunnerWindow(bundleURL: bundleURL)
                .environment(library)
                .environment(runner)
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 1280, height: 800)
    }
}
