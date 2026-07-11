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
	/// Reports the guest's live backing-pixel resolution as the window resizes, but only in Fit to Window
	/// mode (where the guest actually re-resolutions). Lets the UI show the current size and remember it.
	var onGuestPixelSizeChange: ((CGSize) -> Void)?

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
		context.coordinator.onGuestPixelSizeChange = onGuestPixelSizeChange
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
		/// Reports the guest's live pixel size on resize (Fit to Window only).
		var onGuestPixelSizeChange: ((CGSize) -> Void)?
		private var didObserveFullScreen = false
		private var fullScreenObservers: [NSObjectProtocol] = []
		private var resizeObserver: NSObjectProtocol?
		private var lastReportedPixelSize: CGSize = .zero

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
			observeResize(of: window)

			if !didSetInitialSize {
				didSetInitialSize = true
				window.setContentSize(initialContentSize(backingScale: window.backingScaleFactor))
				window.center()
			}
			// Report the starting size so a freshly opened Fit to Window VM shows its size immediately.
			DispatchQueue.main.async { [weak self] in self?.reportGuestPixelSize() }
		}

		// MARK: - Live size reporting

		private func observeResize(of window: NSWindow) {
			guard resizeObserver == nil else { return }
			resizeObserver = NotificationCenter.default.addObserver(
				forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.reportGuestPixelSize() }
			}
		}

		/// Reports the guest's current backing-pixel resolution, but only in Fit to Window mode — a fixed
		/// framebuffer never changes size, so there's nothing to report. Deduplicated so an idempotent
		/// re-layout doesn't spam the callback.
		private func reportGuestPixelSize() {
			guard let vmView, vmView.automaticallyReconfiguresDisplay else { return }
			let pixels = vmView.convertToBacking(vmView.bounds).size
			guard pixels.width >= 1, pixels.height >= 1, pixels != lastReportedPixelSize else { return }
			lastReportedPixelSize = pixels
			onGuestPixelSizeChange?(pixels)
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
			if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
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

		/// The window's starting content size. Fit to Window reopens at its remembered size (the stored
		/// pixel dimensions converted to points), so a restart comes back where the user left it; Fixed
		/// size just aspect-fits the guest ratio within the screen (a low-res guest still fills a large
		/// window rather than opening tiny). Both are clamped to 80% of the screen.
		private func initialContentSize(backingScale: CGFloat) -> NSSize {
			let ratio = aspectRatio.width / aspectRatio.height
			let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1920, height: 1080)

			var width: CGFloat
			var height: CGFloat
			var maxWidth: CGFloat
			var maxHeight: CGFloat
			if vmView?.automaticallyReconfiguresDisplay == true, backingScale > 0 {
				// Fit to Window reopens at the exact remembered size (stored pixels → points), clamped
				// only so it can't exceed the usable screen — e.g. if the VM last ran on a larger display.
				width = aspectRatio.width / backingScale
				height = aspectRatio.height / backingScale
				maxWidth = available.width
				maxHeight = available.height
			} else {
				// Fixed size aspect-fits the guest ratio within 80% of the screen.
				maxWidth = available.width * 0.8
				maxHeight = available.height * 0.8
				width = maxWidth
				height = width / ratio
			}
			if width > maxWidth { width = maxWidth; height = width / ratio }
			if height > maxHeight { height = maxHeight; width = height * ratio }
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
