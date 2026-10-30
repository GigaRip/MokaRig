// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import AppKit
import CoreGraphics
import os

/// Keeps a `ClipboardSession` connected to the port for as long as this user is on the console.
///
/// One agent runs in each logged-in user's GUI session and the port can only have one reader, so an
/// agent holds the port only while its session is active. That is also what keeps a background
/// user's clipboard off the host. This is the job `spice-vdagentd` does on Linux, without the root
/// daemon: serial device nodes are world-accessible on macOS.
@MainActor
public final class GuestAgent {
	/// The device node for the port named `VZSpiceAgentPortAttachment.spiceAgentPortName`.
	public static let defaultPortPath = "/dev/tty.com.redhat.spice.0"

	private static let reconnectDelay = Duration.seconds(5)
	private static let pollInterval = Duration.milliseconds(250)

	private let logger = Logger(subsystem: "com.gigarip.mokarig.guest-agent", category: "agent")
	private let backend: any ClipboardBackend
	private let portPath: String

	private var port: SerialPort?
	private var session: ClipboardSession?
	private var decoder = FrameDecoder()
	private var pollTask: Task<Void, Never>?
	private var reconnectTask: Task<Void, Never>?
	private var lastOpenError: Int32?
	private var observers: [any NSObjectProtocol] = []

	/// Creates an agent.
	/// - Parameters:
	///   - portPath: The device node to use.
	///   - backend: The guest clipboard.
	public init(portPath: String = GuestAgent.defaultPortPath, backend: any ClipboardBackend) {
		self.portPath = portPath
		self.backend = backend
	}

	/// Starts watching the session state and connects if this session is on the console.
	public func run() {
		let center = NSWorkspace.shared.notificationCenter
		observers = [
			center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.connect() }
			},
			center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.disconnect() }
			},
		]
		if Self.isSessionOnConsole {
			connect()
		}
	}

	private static var isSessionOnConsole: Bool {
		guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
		return session[kCGSessionOnConsoleKey] as? Bool ?? true
	}

	private func connect() {
		guard port == nil else { return }
		reconnectTask?.cancel()
		reconnectTask = nil

		let port = SerialPort(
			path: portPath,
			onData: { [weak self] bytes in self?.received(bytes) },
			onClose: { [weak self] in
				self?.logger.notice("The port closed.")
				self?.disconnect()
				self?.scheduleReconnect()
			})
		do {
			try port.open()
		} catch {
			logOpenFailure(error)
			scheduleReconnect()
			return
		}

		logger.notice("Connected to the port.")
		lastOpenError = nil
		self.port = port
		decoder = FrameDecoder()
		let session = ClipboardSession(backend: backend) { [weak port] bytes in port?.write(bytes) }
		self.session = session
		session.start()
		pollTask = Task { [weak self] in
			while !Task.isCancelled {
				self?.session?.pollPasteboard()
				try? await Task.sleep(for: Self.pollInterval)
			}
		}
	}

	private func disconnect() {
		reconnectTask?.cancel()
		reconnectTask = nil
		pollTask?.cancel()
		pollTask = nil
		port?.close()
		port = nil
		session = nil
	}

	private func received(_ bytes: Data) {
		do {
			for message in try decoder.feed(bytes) {
				session?.receive(message)
			}
		} catch {
			logger.error("Dropping the connection after a framing error: \(String(describing: error), privacy: .public)")
			disconnect()
			scheduleReconnect()
		}
	}

	private func scheduleReconnect() {
		reconnectTask = Task { [weak self] in
			try? await Task.sleep(for: Self.reconnectDelay)
			guard !Task.isCancelled else { return }
			self?.reconnectTask = nil
			self?.connect()
		}
	}

	/// Logged once per distinct error, because a VM without the port retries indefinitely.
	private func logOpenFailure(_ error: any Error) {
		let code = (error as? SerialPort.OpenError)?.code ?? -1
		guard code != lastOpenError else { return }
		lastOpenError = code
		logger.notice("Can't open \(self.portPath, privacy: .public): \(String(cString: strerror(code)), privacy: .public)")
	}
}
