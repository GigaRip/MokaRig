<p align="center">
  <img src="MokaRig/Pictures/MokaRig-icon-rounded-512.png" alt="MokaRig" width="160" height="160">
</p>

# MokaRig

A macOS virtual machine manager built on Apple's Virtualization framework. It can
create and run Linux virtual machines — such as Ubuntu Desktop and Ubuntu
Server — as well as macOS virtual machines.

## Why MokaRig?

There are plenty of virtualization apps for the Mac. MokaRig was built around a
few deliberate principles:

- **Simplicity is the driving goal.** MokaRig doesn't try to do everything. There
  is no built-in image downloader — you download and manage your own guest OS
  images, your way. That keeps the app small, predictable, and out of your way.
- **Your files, in plain sight.** Virtual machines live in a single visible
  folder, `~/MokaRigVMs` — not buried under `~/Library` or scattered across the
  system. They're easy to find, back up, move, or delete.
- **Minimal footprint.** MokaRig doesn't write its own hidden configuration or
  data files. Aside from a small standard macOS preferences file used by the
  auto-updater, it keeps to itself. To uninstall, drag MokaRig to the Trash; to
  remove your virtual machines, delete the `~/MokaRigVMs` folder.
- **Thoughtful design and implementation.** MokaRig sweats the details so you
  don't have to. For example, duplicating a virtual machine is a single click —
  but two machines that share the same guest identity on the same network would
  collide. MokaRig recognizes copies (even ones you make in Finder) and won't run
  a clone alongside its original until you give it its own identity.

## Features

- Create and run **Linux** virtual machines, such as Ubuntu Desktop and Ubuntu
  Server.
- Create and run **macOS** virtual machines (see the note above regarding macOS
  26.5.x hosts).
- Manage a library of virtual machines, each with its own configuration
  (CPU, memory, and display resolution).
- Run each virtual machine in its own window.
- Automatic updates via [Sparkle](https://sparkle-project.org).

## Screenshots

<p align="center">
  <img src="https://pictures.mokarig.com/screenshot-app.png" alt="MokaRig virtual machine library">
  <br>
  <em>Every virtual machine in one place — Linux and macOS side by side.</em>
</p>

<p align="center">
  <img src="https://pictures.mokarig.com/screenshot-vm.png" alt="MokaRig running a virtual machine">
  <br>
  <em>Run a full Linux desktop, right on your Mac.</em>
</p>

## Requirements

- A Mac with **Apple Silicon**.
- **macOS 26.5.2 or later**.

## Installation

Download the latest release from [mokarig.com](https://mokarig.com). MokaRig
keeps itself up to date automatically after installation.

To build from source instead, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Getting started

1. Launch MokaRig and choose to create a new virtual machine.
2. Pick a guest type — Linux or macOS.
3. For a Linux guest, provide an installer image. On Apple Silicon this **must**
   be an `arm64` image; `x86_64`/`amd64` images will not boot. For a graphical
   desktop, use a desktop image rather than a live-server image.
4. Follow the guest's installer, then run the virtual machine from your library.

## Author

Created and maintained by [Brian Lambert](https://github.com/softwarenerd).
Copyright is held by GigaRip LLC.

## License

Licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or
  <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or
  <http://opensource.org/licenses/MIT>)

at your option.

### Contributing to MokaRig

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for how to get
started.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.

## Acknowledgements

- Apple's [Virtualization](https://developer.apple.com/documentation/virtualization)
  framework, which powers the virtual machines.
- [Sparkle](https://sparkle-project.org), which provides in-app automatic updates.
- [Claude Code](https://www.anthropic.com/claude-code), which wrote much of the
  implementation. MokaRig's design, layout, and product direction are the
  author's own.
