// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation
import Testing
@testable import GuestAgentCore

/// A hand-built frame, written byte by byte so these tests pin the wire format independently of the
/// encoder.
private func frame(port: UInt32 = 1, type: UInt32, opaque: UInt64 = 0, body: [UInt8] = []) -> [UInt8] {
	func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) } }
	func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8((value >> ($0 * 8)) & 0xff) } }
	let message = le32(1) + le32(type) + le64(opaque) + le32(UInt32(body.count)) + body
	return le32(port) + le32(UInt32(message.count)) + message
}

@Suite struct FramingTests {
	@Test func encodesTheWireLayout() {
		let message = AgentMessage(rawType: 7, opaque: 0x1122334455667788, data: Data([0xaa, 0xbb]))
		#expect([UInt8](message.encoded()) == frame(type: 7, opaque: 0x1122334455667788, body: [0xaa, 0xbb]))
	}

	@Test func decodesWhatItEncodes() throws {
		let message = AgentMessage(type: .clipboard, opaque: 9, data: Data(repeating: 0x5a, count: 5000))
		var decoder = FrameDecoder()
		#expect(try decoder.feed(message.encoded()) == [message])
	}

	@Test func decodesOneByteAtATime() throws {
		var decoder = FrameDecoder()
		var messages: [AgentMessage] = []
		for byte in frame(type: 6, body: [1, 2, 3]) + frame(type: 9) {
			messages += try decoder.feed(Data([byte]))
		}
		#expect(messages.map(\.type) == [6, 9])
		#expect(messages[0].data == Data([1, 2, 3]))
	}

	@Test func reassemblesAMessageSpanningChunks() throws {
		let whole = Array(frame(type: 4, body: [UInt8](repeating: 7, count: 3000)).dropFirst(8))
		func chunk(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
			var header = Data()
			header.appendLittleEndian(UInt32(1))
			header.appendLittleEndian(UInt32(bytes.count))
			return [UInt8](header) + bytes
		}
		var decoder = FrameDecoder()
		#expect(try decoder.feed(Data(chunk(whole[0..<2048]))).isEmpty)
		let messages = try decoder.feed(Data(chunk(whole[2048...])))
		#expect(messages.count == 1)
		#expect(messages[0].data.count == 3000)
	}

	@Test func keepsPortsApartWhenChunksInterleave() throws {
		let client = Array(frame(port: 1, type: 4, body: [1, 1, 1, 1]).dropFirst(8))
		func chunk(port: UInt32, _ bytes: ArraySlice<UInt8>) -> [UInt8] {
			var header = Data()
			header.appendLittleEndian(port)
			header.appendLittleEndian(UInt32(bytes.count))
			return [UInt8](header) + bytes
		}
		var decoder = FrameDecoder()
		let bytes = chunk(port: 1, client[0..<10]) + frame(port: 2, type: 9) + chunk(port: 1, client[10...])
		#expect(try decoder.feed(Data(bytes)).map(\.type) == [9, 4])
	}

	@Test func rejectsAnInvalidPort() {
		var decoder = FrameDecoder()
		#expect(throws: FramingError.invalidPort(3)) { try decoder.feed(Data(frame(port: 3, type: 6))) }
	}

	@Test func rejectsAnUnknownProtocolVersion() {
		var bytes = frame(type: 6)
		bytes[8] = 2
		var decoder = FrameDecoder()
		#expect(throws: FramingError.invalidProtocol(2)) { try decoder.feed(Data(bytes)) }
	}

	@Test func rejectsAnOversizedChunk() {
		var bytes = frame(type: 6)
		bytes.replaceSubrange(4..<8, with: [0xff, 0xff, 0xff, 0x7f])
		var decoder = FrameDecoder()
		#expect(throws: FramingError.oversized(0x7fff_ffff)) { try decoder.feed(Data(bytes)) }
	}

	@Test func capabilityBitsMatchTheHeader() {
		#expect(Capabilities.clipboardByDemand.rawValue == 0x20)
		#expect(Capabilities.clipboardSelection.rawValue == 0x40)
		#expect(Capabilities.guestLineEndLF.rawValue == 0x100)
		#expect(Capabilities.maxClipboard.rawValue == 0x400)
	}
}
