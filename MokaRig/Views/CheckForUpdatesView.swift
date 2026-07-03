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

/// Tracks whether the Sparkle updater can currently start a check, so the menu item can disable
/// itself while one is already running. Observed via KVO rather than Combine, to match the app.
@MainActor
@Observable
final class UpdaterViewModel {
    private(set) var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor [weak self] in self?.canCheckForUpdates = canCheck }
        }
    }
}

/// A "Check for Updates…" menu command backed by Sparkle, disabled while a check can't run.
struct CheckForUpdatesView: View {
    private let updater: SPUUpdater
    @State private var model: UpdaterViewModel

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = State(initialValue: UpdaterViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!model.canCheckForUpdates)
    }
}
