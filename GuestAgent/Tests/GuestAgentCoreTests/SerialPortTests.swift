// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Darwin
import Foundation
import Testing
@testable import GuestAgentCore

/// The far end of a pseudo-terminal, standing in for the host side of the virtio port.
private final class PseudoTerminal {
	let controller: Int32
	let subordinate: Int32
	let path: String

	init() throws {
		var controller: Int32 = -1
		var subordinate: Int32 = -1
		try #require(openpty(&controller, &subordinate, nil, nil, nil) == 0)
		self.controller = controller
		self.subordinate = subordinate
		path = String(cString: ptsname(controller))
		_ = fcntl(controller, F_SETFL, O_NONBLOCK)
	}

	deinit {
		close(subordinate)
		close(controller)
	}

	func send(_ bytes: [UInt8]) {
		_ = bytes.withUnsafeBytes { write(controller, $0.baseAddress, $0.count) }
	}

	/// Reads whatever is waiting, without blocking.
	func receive() -> [UInt8] {
		var buffer = [UInt8](repeating: 0, count: 64 * 1024)
		let count = read(controller, &buffer, buffer.count)
		return count > 0 ? Array(buffer[..<count]) : []
	}
}

@MainActor
private func wait(until condition: @MainActor () -> Bool) async {
	for _ in 0..<500 where !condition() {
		try? await Task.sleep(for: .milliseconds(10))
	}
}

/// Every byte value, which is what canonical mode or output processing would disturb.
private let allBytes = (0...255).map(UInt8.init) + [0x0a, 0x0d, 0x03, 0x04, 0x11, 0x13, 0x7f]

@MainActor
@Suite(.serialized) struct SerialPortTests {
	@Test func failsToOpenAMissingDevice() {
		let port = SerialPort(path: "/dev/tty.mokarig-does-not-exist", onData: { _ in }, onClose: {})
		#expect(throws: SerialPort.OpenError.self) { try port.open() }
		#expect(!port.isOpen)
	}

	@Test func receivesBinaryBytesUnchanged() async throws {
		let terminal = try PseudoTerminal()
		var received = Data()
		let port = SerialPort(path: terminal.path, onData: { received.append($0) }, onClose: {})
		try port.open()
		defer { port.close() }
		terminal.send(allBytes)
		await wait { received.count >= allBytes.count }
		#expect([UInt8](received) == allBytes)
	}

	@Test func sendsBinaryBytesUnchanged() async throws {
		let terminal = try PseudoTerminal()
		let port = SerialPort(path: terminal.path, onData: { _ in }, onClose: {})
		try port.open()
		defer { port.close() }
		port.write(Data(allBytes))
		var received: [UInt8] = []
		await wait {
			received += terminal.receive()
			return received.count >= allBytes.count
		}
		#expect(received == allBytes)
	}

	@Test func deliversALargeWriteThroughBackpressure() async throws {
		let terminal = try PseudoTerminal()
		let port = SerialPort(path: terminal.path, onData: { _ in }, onClose: {})
		try port.open()
		defer { port.close() }
		let payload = (0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
		port.write(Data(payload))
		var received: [UInt8] = []
		for _ in 0..<5000 where received.count < payload.count {
			received += terminal.receive()
			try? await Task.sleep(for: .milliseconds(1))
		}
		#expect(received == payload)
	}

	@Test func canReopenAfterClosing() async throws {
		let terminal = try PseudoTerminal()
		let first = SerialPort(path: terminal.path, onData: { _ in }, onClose: {})
		try first.open()
		first.close()
		try await Task.sleep(for: .milliseconds(50))
		let second = SerialPort(path: terminal.path, onData: { _ in }, onClose: {})
		try second.open()
		second.close()
	}

	@Test func dropsWritesWhileClosed() async throws {
		let terminal = try PseudoTerminal()
		let port = SerialPort(path: terminal.path, onData: { _ in }, onClose: {})
		port.write(Data([1, 2, 3]))
		#expect(terminal.receive().isEmpty)
	}
}
