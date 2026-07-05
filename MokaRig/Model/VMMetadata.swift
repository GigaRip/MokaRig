// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// The persisted description of a virtual machine, stored as `Config.json` inside the VM bundle.
struct VMMetadata: Codable, Equatable, Sendable {
    var name: String
    var guestOS: GuestOS
    var cpuCount: Int
    var memorySizeInBytes: UInt64
    var displayWidthInPixels: Int
    var displayHeightInPixels: Int
    /// The display pixel density. Only meaningful for macOS guests.
    var pixelsPerInch: Int
    /// Whether the VM still needs its OS installed. A Linux guest boots its installer ISO while true.
    var needsInstall: Bool
    /// The path to installer media (a Linux ISO) to attach while installing. Nil once removed.
    var installerMediaPath: String?
    /// Whether the guest display resizes to match the runner window (dynamic resolution).
    /// When off, the guest keeps a fixed resolution and the window scales its framebuffer —
    /// which preserves a HiDPI scale set inside the guest that a resize would otherwise reset.
    var dynamicResolution: Bool

    /// A lineage ID identifying VMs that are byte-for-byte copies of one another. Every VM gets a
    /// unique one at creation; a copy — whether made through Duplicate or by copying the bundle in
    /// Finder (which inherits this value) — shares it. VMs that share an ID also share a guest identity
    /// (hostname, machine-id, SSH host keys), so MokaRig won't run two of them at once until one is
    /// made independent (assigned a fresh ID). Optional only so bundles written before this field
    /// decode as nil and get a fresh ID backfilled on load.
    var cloneGroup: UUID? = nil

    /// The maximum VM name length, to keep the sidebar, window titles, and spec chips from overflowing.
    static let maxNameLength = 40

    /// Sensible defaults for a new Linux guest.
    static let defaultLinux = VMMetadata(
        name: "Linux VM",
        guestOS: .linux,
        cpuCount: 4,
        memorySizeInBytes: 4 * 1024 * 1024 * 1024,
        displayWidthInPixels: 1920,
        displayHeightInPixels: 1080,
        pixelsPerInch: 80,
        needsInstall: true,
        installerMediaPath: nil,
        dynamicResolution: false)

    /// Sensible defaults for a new macOS guest.
    static let defaultMac = VMMetadata(
        name: "macOS VM",
        guestOS: .macOS,
        cpuCount: 4,
        memorySizeInBytes: 8 * 1024 * 1024 * 1024,
        displayWidthInPixels: 2560,
        displayHeightInPixels: 1440,
        pixelsPerInch: 144,
        needsInstall: true,
        installerMediaPath: nil,
        dynamicResolution: false)
}
