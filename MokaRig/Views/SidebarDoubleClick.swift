// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI
import AppKit

/// Hooks the sidebar List's underlying `NSTableView` native double-click action so double-clicking a
/// row is instant and never interferes with single-click selection — unlike SwiftUI tap gestures,
/// which either delay the single click or fight the List's own selection handling.
struct SidebarDoubleClick: NSViewRepresentable {
    /// Called with the index of the double-clicked row.
    let onOpen: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.attach(from: nsView)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onOpen: (Int) -> Void
        private weak var tableView: NSTableView?
        private weak var swiftUITarget: AnyObject?
        private var swiftUIAction: Selector?

        init(onOpen: @escaping (Int) -> Void) { self.onOpen = onOpen }

        /// Finds the sidebar's table view, takes over its target to add a double-click action, and
        /// forwards the single-click action back to List. Retries next runloop if no window yet.
        func attach(from view: NSView) {
            guard let contentView = view.window?.contentView else {
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.attach(from: view)
                }
                return
            }

            var tables: [NSTableView] = []
            Self.collectTableViews(in: contentView, into: &tables)
            // Prefer the leading-most table (the sidebar) over any table in the detail pane.
            guard let sidebar = tables.min(by: {
                $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
            }) else { return }
            tableView = sidebar

            // The table shares one target between its single-click `action` (List's private
            // `onAction:`, which drives selection) and `doubleAction`. Take the target over, but
            // remember List's action/target so single clicks forward back and selection keeps
            // working. The guard skips re-taking-over ours, and re-captures if List reset the target.
            guard sidebar.target !== self else { return }
            swiftUITarget = sidebar.target
            swiftUIAction = sidebar.action
            sidebar.target = self
            sidebar.doubleAction = #selector(handleDoubleClick)
        }

        @objc private func handleDoubleClick() {
            guard let row = tableView?.clickedRow, row >= 0 else { return }
            onOpen(row)
        }

        // Forward List's single-click action to its original handler so selection still updates;
        // we only handle the double-click ourselves.
        override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == swiftUIAction { return swiftUITarget?.responds(to: aSelector) ?? false }
            return super.responds(to: aSelector)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if aSelector == swiftUIAction { return swiftUITarget }
            return super.forwardingTarget(for: aSelector)
        }

        private static func collectTableViews(in view: NSView, into tables: inout [NSTableView]) {
            if let table = view as? NSTableView { tables.append(table) }
            for subview in view.subviews {
                collectTableViews(in: subview, into: &tables)
            }
        }
    }
}
