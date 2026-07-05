// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// Watches a directory and calls a handler when its contents change — a bundle added, removed, or
/// renamed — so the VM library can stay in sync with changes the user makes in Finder.
///
/// Deliberately watches only the directory's own entry list (a `DispatchSource` vnode watch), not the
/// files inside its subdirectories. That catches exactly what the sidebar cares about while staying
/// quiet during normal operation: a running VM writing gigabytes to its disk image lives *inside* a
/// bundle, so it never churns the parent folder. Bursts of events (e.g. a Finder copy) are debounced
/// into a single handler call.
final class DirectoryWatcher {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.gigarip.mokarig.directory-watcher")
    private var source: (any DispatchSourceFileSystemObject)?
    private var debounce: DispatchWorkItem?

    /// - Parameters:
    ///   - url: The directory to watch. It must already exist.
    ///   - onChange: Invoked (on a background queue) after a debounced change. Hop to the main actor
    ///     inside it if you touch UI or main-actor state.
    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.async { [weak self] in self?.start() }
    }

    deinit {
        source?.cancel()
    }

    private func start() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue)
        source.setEventHandler { [weak self] in self?.handleEvent() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func handleEvent() {
        // If the watched directory itself was deleted or moved, the descriptor is stale — tear down
        // and re-establish on the (app-recreated) path shortly.
        let flags = source?.data ?? []
        if flags.contains(.delete) || flags.contains(.rename) {
            source?.cancel()
            source = nil
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
        }

        // Coalesce a burst of change events (a Finder copy fires several) into one handler call.
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
