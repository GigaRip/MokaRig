// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import SwiftUI
import Virtualization

/// A SwiftUI wrapper around AppKit's `VZVirtualMachineView`, which renders and forwards input to a VM.
struct VirtualMachineHostView: NSViewRepresentable {
	let virtualMachine: VZVirtualMachine?
	/// The guest display size. Used to pin the window's *content* aspect ratio so the framebuffer
	/// always fills the window (no letterboxing) and resizing stays proportional to the guest.
	var aspectRatio: CGSize?
	/// When true, the guest resolution follows the window; when false, it stays fixed and the
	/// framebuffer scales to the window (the pinned aspect ratio keeps that fill bar-free).
	var reconfiguresDisplayOnResize = false
	/// Called when the user tries to close the window (red X). Return true to allow the close,
	/// false to veto it (e.g. to first show a confirmation).
	var shouldClose: (() -> Bool)?
	/// Reflects whether the guest currently holds keyboard focus: captured on a click inside the VM,
	/// released by clicking the title bar or another window. Drives the runner window's input indicator.
	@Binding var keyboardCaptured: Bool
	/// Whether the guest is running. When it isn't, any capture is released so focus returns to the host
	/// and the indicator resets — a powered-off guest can't receive input.
	var guestIsRunning: Bool

	/// The smallest content width the runner window may shrink to.
	private static let minimumContentWidth: CGFloat = 560

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> CapturingVMView {
		let view = CapturingVMView()
		// Don't capture macOS system shortcuts (Command-Tab, Command-Space, etc.) — let them
		// switch apps as usual instead of being swallowed by the guest.
		view.capturesSystemKeys = false
		return view
	}

	func updateNSView(_ nsView: CapturingVMView, context: Context) {
		context.coordinator.vmView = nsView
		context.coordinator.shouldClose = shouldClose
		nsView.onCaptureChange = { keyboardCaptured = $0 }
		nsView.virtualMachine = virtualMachine
		// Per-VM setting: either follow the window (dynamic) or keep a fixed guest resolution.
		nsView.automaticallyReconfiguresDisplay = reconfiguresDisplayOnResize

		// Drop any capture once the guest stops. Deferred so the resulting binding update doesn't
		// mutate SwiftUI state from within this update pass.
		if !guestIsRunning {
			DispatchQueue.main.async { [weak nsView] in nsView?.release() }
		}

		guard let aspectRatio else { return }
		// The window isn't attached during the first update, so defer to the next runloop. Re-run
		// on every update (cheap/idempotent) so SwiftUI can't quietly undo the window styling.
		DispatchQueue.main.async { [weak nsView] in
			guard let window = nsView?.window else { return }
			context.coordinator.configure(window: window, aspectRatio: aspectRatio,
										  minimumContentWidth: Self.minimumContentWidth)
		}
	}

	/// Owns the runner window's sizing: pins the content aspect ratio, enforces a minimum size, and
	/// gives it an initial size. `contentAspectRatio` alone ignores `contentMinSize`, so the minimum
	/// is enforced in `windowWillResize`. Non-resize delegate calls forward to SwiftUI's delegate.
	@MainActor
	final class Coordinator: NSObject, NSWindowDelegate {
		private var didSetInitialSize = false
		private var aspectRatio = CGSize(width: 16, height: 9)
		private var minimumContentWidth: CGFloat = 800
		private weak var forwardingDelegate: NSWindowDelegate?
		/// The hosted VM view, so full-screen transitions can toggle system-key capture on it.
		weak var vmView: CapturingVMView?
		/// Vetoes/permits the window close; supplied by the representable.
		var shouldClose: (() -> Bool)?
		private var didObserveFullScreen = false
		private var fullScreenObservers: [NSObjectProtocol] = []

		func configure(window: NSWindow, aspectRatio: CGSize, minimumContentWidth: CGFloat) {
			guard aspectRatio.width > 0, aspectRatio.height > 0 else { return }
			self.aspectRatio = aspectRatio
			self.minimumContentWidth = minimumContentWidth

			// SwiftUI hosts windows with a full-size content view (content spans behind the
			// titlebar), which makes contentAspectRatio track the frame and letterbox the guest.
			// A standard titlebar + content layout pins the real content area instead.
			window.styleMask.remove(.fullSizeContentView)
			window.titlebarAppearsTransparent = false
			window.titleVisibility = .visible
			window.contentAspectRatio = NSSize(width: aspectRatio.width, height: aspectRatio.height)

			// Take over as delegate to enforce the minimum size, forwarding everything else.
			if window.delegate !== self {
				if let existing = window.delegate, !(existing is Coordinator) {
					forwardingDelegate = existing
				}
				window.delegate = self
			}

			observeFullScreen(of: window)

			if !didSetInitialSize {
				didSetInitialSize = true
				window.setContentSize(initialContentSize())
				window.center()
			}
		}

		// MARK: - Size enforcement

		func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
			// Convert the proposed frame to content, clamp to the minimum, snap to the guest ratio,
			// then convert back to a frame — so both the floor and the ratio hold on the content.
			let proposedContent = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
			let width = max(proposedContent.width, minimumContentWidth)
			return sender.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize(forWidth: width))).size
		}

		func windowShouldClose(_ sender: NSWindow) -> Bool {
			shouldClose?() ?? true
		}

		// MARK: - Full-screen system-key capture

		/// Capture macOS system shortcuts (⌘-Tab, ⌘-Space, etc.) only in full screen: windowed
		/// mode stays out of the user's way, full screen hands everything to the guest. Full screen
		/// also grabs keyboard focus outright — there's no title bar to click, so the click-to-capture
		/// model would otherwise leave the guest unreachable.
		private func observeFullScreen(of window: NSWindow) {
			guard !didObserveFullScreen else { return }
			didObserveFullScreen = true
			let center = NotificationCenter.default
			fullScreenObservers.append(
				center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
								   object: window, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated {
						self?.vmView?.capturesSystemKeys = true
						self?.vmView?.capture()
					}
				})
			fullScreenObservers.append(
				center.addObserver(forName: NSWindow.didExitFullScreenNotification,
								   object: window, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated {
						self?.vmView?.capturesSystemKeys = false
						self?.vmView?.release()
					}
				})
		}

		deinit {
			fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
		}

		// MARK: - Delegate forwarding

		override func responds(to aSelector: Selector!) -> Bool {
			super.responds(to: aSelector) || (forwardingDelegate?.responds(to: aSelector) ?? false)
		}

		override func forwardingTarget(for aSelector: Selector!) -> Any? {
			if forwardingDelegate?.responds(to: aSelector) == true { return forwardingDelegate }
			return super.forwardingTarget(for: aSelector)
		}

		// MARK: - Sizing helpers

		private func contentSize(forWidth width: CGFloat) -> NSSize {
			NSSize(width: width.rounded(), height: (width * aspectRatio.height / aspectRatio.width).rounded())
		}

		/// The guest ratio aspect-fit within 80% of the screen.
		private func initialContentSize() -> NSSize {
			let ratio = aspectRatio.width / aspectRatio.height
			let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1920, height: 1080)
			let fraction: CGFloat = 0.8
			var width = available.width * fraction
			var height = width / ratio
			if height > available.height * fraction {
				height = available.height * fraction
				width = height * ratio
			}
			return NSSize(width: max(width, minimumContentWidth).rounded(), height: height.rounded())
		}
	}
}

/// A `VZVirtualMachineView` that grabs keyboard focus for the guest only after the user clicks inside
/// it. Activating the window any other way — ⌘`, the Window menu, another app — leaves focus with the
/// host so host shortcuts keep working; clicking the title bar (or another window) hands control back.
/// The gate is first-responder status: `acceptsFirstResponder` is false until a click asks for capture,
/// so AppKit won't route keys (⌘` included) to the guest on plain window activation.
final class CapturingVMView: VZVirtualMachineView {
	/// Reports capture transitions so the UI can show whether the keyboard is going to the guest.
	var onCaptureChange: ((Bool) -> Void)?

	private var wantsCapture = false
	private var releaseClickMonitor: Any?

	override var acceptsFirstResponder: Bool { wantsCapture }

	override func mouseDown(with event: NSEvent) {
		capture()
		super.mouseDown(with: event)
	}

	/// Gives the guest keyboard focus.
	func capture() {
		wantsCapture = true
		if window?.firstResponder !== self { window?.makeFirstResponder(self) }
	}

	/// Returns keyboard focus to the host.
	func release() {
		wantsCapture = false
		if window?.firstResponder === self { window?.makeFirstResponder(window) }
	}

	override func becomeFirstResponder() -> Bool {
		let didBecome = super.becomeFirstResponder()
		if didBecome { onCaptureChange?(true) }
		return didBecome
	}

	override func resignFirstResponder() -> Bool {
		let didResign = super.resignFirstResponder()
		if didResign {
			wantsCapture = false
			onCaptureChange?(false)
		}
		return didResign
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard releaseClickMonitor == nil else { return }
		// A click anywhere in this window outside the VM view (title bar, toolbar) returns control to
		// the host. Clicks inside the view capture via `mouseDown`. The event is passed through, so the
		// title bar still drags and toolbar buttons still work.
		releaseClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
			guard let self, self.wantsCapture, event.window === self.window else { return event }
			if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.release() }
			return event
		}
	}

	deinit {
		if let releaseClickMonitor { NSEvent.removeMonitor(releaseClickMonitor) }
	}
}
