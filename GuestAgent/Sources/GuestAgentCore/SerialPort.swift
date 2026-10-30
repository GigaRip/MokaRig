// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Darwin
import Dispatch
import Foundation

/// Nonblocking, raw-mode access to the virtio console port. All use must be on the main actor.
@MainActor
public final class SerialPort {
	/// A failure to open the port.
	public struct OpenError: Error {
		/// The `errno` from the failed call.
		public let code: Int32
	}

	private let path: String
	private let onData: (Data) -> Void
	private let onClose: () -> Void

	private var descriptor: Int32 = -1
	private var readSource: (any DispatchSourceRead)?
	private var writeSource: (any DispatchSourceWrite)?
	private var outbox = Data()
	private var outboxOffset = 0

	/// Creates a closed port.
	/// - Parameters:
	///   - path: The device path.
	///   - onData: Receives each batch of bytes read.
	///   - onClose: Called when the other end goes away. Not called for `close()`.
	public init(path: String, onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
		self.path = path
		self.onData = onData
		self.onClose = onClose
	}

	/// Whether the port is open.
	public var isOpen: Bool {
		descriptor >= 0
	}

	/// Opens the port for exclusive use.
	/// - Throws: `OpenError` if the device is missing or busy.
	public func open() throws {
		guard !isOpen else { return }
		// O_NONBLOCK keeps a /dev/tty.* open from waiting for a carrier signal that a virtio port
		// never raises.
		let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
		guard fd >= 0 else { throw OpenError(code: errno) }
		// A second user's agent gets EBUSY here rather than sharing the stream and corrupting framing.
		guard ioctl(fd, TIOCEXCL) == 0 else {
			let code = errno
			Darwin.close(fd)
			throw OpenError(code: code)
		}
		configureRawMode(fd)
		descriptor = fd

		let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
		source.setEventHandler { [weak self] in
			MainActor.assumeIsolated { self?.readAvailable() }
		}
		source.setCancelHandler {
			Darwin.close(fd)
		}
		source.resume()
		readSource = source
	}

	/// Queues bytes for the port. Bytes queued while closed are dropped.
	public func write(_ bytes: Data) {
		guard isOpen else { return }
		outbox.append(bytes)
		flush()
	}

	/// Closes the port, dropping unwritten bytes.
	public func close() {
		guard isOpen else { return }
		// Without the flush, closing a tty waits for output to drain, and the host may not be reading.
		tcflush(descriptor, TCIOFLUSH)
		writeSource?.cancel()
		writeSource = nil
		readSource?.cancel()
		readSource = nil
		descriptor = -1
		outbox = Data()
		outboxOffset = 0
	}

	/// The port is a tty on macOS. Canonical mode would buffer until a newline and rewrite control
	/// bytes, either of which corrupts a binary protocol. A failure is tolerated because the port's
	/// default mode may already be raw, and framing errors would surface a bad one.
	private func configureRawMode(_ fd: Int32) {
		var attributes = termios()
		guard tcgetattr(fd, &attributes) == 0 else { return }
		cfmakeraw(&attributes)
		attributes.c_cflag |= tcflag_t(CLOCAL | CREAD)
		tcsetattr(fd, TCSANOW, &attributes)
		tcflush(fd, TCIOFLUSH)
	}

	private func readAvailable() {
		var buffer = [UInt8](repeating: 0, count: 64 * 1024)
		while isOpen {
			let count = Darwin.read(descriptor, &buffer, buffer.count)
			if count > 0 {
				onData(Data(buffer[..<count]))
			} else if count < 0 && errno == EINTR {
				continue
			} else if count < 0 && errno == EAGAIN {
				return
			} else {
				close()
				onClose()
				return
			}
		}
	}

	private func flush() {
		while outboxOffset < outbox.count {
			let count = outbox.withUnsafeBytes { bytes in
				Darwin.write(descriptor, bytes.baseAddress! + outboxOffset, bytes.count - outboxOffset)
			}
			if count > 0 {
				outboxOffset += count
			} else if errno == EINTR {
				continue
			} else if errno == EAGAIN {
				waitForWritable()
				return
			} else {
				close()
				onClose()
				return
			}
		}
		outbox = Data()
		outboxOffset = 0
		writeSource?.cancel()
		writeSource = nil
	}

	private func waitForWritable() {
		guard writeSource == nil else { return }
		let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
		source.setEventHandler { [weak self] in
			MainActor.assumeIsolated { self?.flush() }
		}
		source.resume()
		writeSource = source
	}
}
