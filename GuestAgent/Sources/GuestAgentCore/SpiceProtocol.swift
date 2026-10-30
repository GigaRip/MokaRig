// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// The SPICE agent protocol version carried in every message.
public let spiceProtocolVersion: UInt32 = 1

/// The largest chunk or message the decoder accepts, which bounds memory use on a corrupt stream.
public let maximumMessageSize = 512 * 1024 * 1024

/// Addressing values carried in a chunk header.
public enum AgentPort {
	/// The SPICE client, which is the host when running under Virtualization.framework.
	public static let client: UInt32 = 1
	/// The SPICE server.
	public static let server: UInt32 = 2
}

/// The agent message types this agent handles. Other types are ignored.
public enum MessageType: UInt32 {
	/// Clipboard contents, in either direction.
	case clipboard = 4
	/// A capability announcement, in either direction.
	case announceCapabilities = 6
	/// A claim of clipboard ownership listing the types on offer.
	case clipboardGrab = 7
	/// A request for clipboard contents of one type.
	case clipboardRequest = 8
	/// A release of clipboard ownership.
	case clipboardRelease = 9
	/// Notice that the SPICE client went away.
	case clientDisconnected = 13
	/// The largest clipboard payload the client accepts.
	case maxClipboard = 14
}

/// The clipboard formats defined by the protocol.
public enum ClipboardType: UInt32, Sendable, CaseIterable {
	/// No data, used to answer a request that can't be satisfied.
	case none = 0
	/// UTF-8 text.
	case utf8Text = 1
	/// A PNG image.
	case png = 2
	/// A BMP image.
	case bmp = 3
	/// A TIFF image.
	case tiff = 4
	/// A JPEG image.
	case jpg = 5
}

/// The capability bits this agent uses. Bit positions come from `VD_AGENT_CAP_*` in `vd_agent.h`.
public struct Capabilities: OptionSet, Sendable {
	/// The raw value of the first capability word.
	public let rawValue: UInt32

	/// Creates a set from the first capability word.
	public init(rawValue: UInt32) {
		self.rawValue = rawValue
	}

	/// Clipboard data moves only after a request, following a grab.
	public static let clipboardByDemand = Capabilities(rawValue: 1 << 5)
	/// Clipboard messages carry a selection prefix.
	public static let clipboardSelection = Capabilities(rawValue: 1 << 6)
	/// Guest text uses LF line endings.
	public static let guestLineEndLF = Capabilities(rawValue: 1 << 8)
	/// The client may limit clipboard payload size.
	public static let maxClipboard = Capabilities(rawValue: 1 << 10)
}

/// One decoded or outgoing agent message.
public struct AgentMessage: Equatable, Sendable {
	/// The raw message type.
	public var type: UInt32
	/// An opaque value the protocol passes through unchanged.
	public var opaque: UInt64
	/// The message body.
	public var data: Data

	/// Creates a message with a known type.
	public init(type: MessageType, opaque: UInt64 = 0, data: Data = Data()) {
		self.init(rawType: type.rawValue, opaque: opaque, data: data)
	}

	/// Creates a message with a raw type value.
	public init(rawType: UInt32, opaque: UInt64 = 0, data: Data = Data()) {
		self.type = rawType
		self.opaque = opaque
		self.data = data
	}

	/// The port framing for this message: one chunk addressed to the client.
	///
	/// A whole message goes in a single chunk, however large, which is how `tart-guest-agent` writes
	/// to this same host.
	public func encoded() -> Data {
		var out = Data(capacity: MessageFraming.chunkHeaderSize + MessageFraming.messageHeaderSize + data.count)
		out.appendLittleEndian(AgentPort.client)
		out.appendLittleEndian(UInt32(MessageFraming.messageHeaderSize + data.count))
		out.appendLittleEndian(spiceProtocolVersion)
		out.appendLittleEndian(type)
		out.appendLittleEndian(opaque)
		out.appendLittleEndian(UInt32(data.count))
		out.append(data)
		return out
	}
}

/// Fixed sizes of the wire headers.
enum MessageFraming {
	static let chunkHeaderSize = 8
	static let messageHeaderSize = 20
}

/// A failure that leaves the byte stream unusable.
public enum FramingError: Error, Equatable {
	/// A chunk header named a port the protocol doesn't define.
	case invalidPort(UInt32)
	/// A chunk or message declared a size above `maximumMessageSize`.
	case oversized(Int)
	/// A message header carried an unknown protocol version.
	case invalidProtocol(UInt32)
}

/// Reassembles agent messages from the port's byte stream.
///
/// The stream is a sequence of chunks, and a message may span several of them. Chunks addressed to
/// different ports may interleave, so each port gets its own reassembly buffer.
public struct FrameDecoder {
	private var stream: [UInt8] = []
	private var assemblies: [UInt32: [UInt8]] = [:]

	/// Creates an empty decoder.
	public init() {}

	/// Consumes bytes from the port and returns every message they complete.
	/// - Throws: `FramingError` when the stream is corrupt. The decoder can't resynchronize after that.
	public mutating func feed(_ bytes: Data) throws -> [AgentMessage] {
		stream.append(contentsOf: bytes)
		var messages: [AgentMessage] = []
		var consumed = 0
		defer { stream.removeFirst(consumed) }

		while stream.count - consumed >= MessageFraming.chunkHeaderSize {
			let port = stream.littleEndianUInt32(at: consumed)
			let size = Int(stream.littleEndianUInt32(at: consumed + 4))
			guard port == AgentPort.client || port == AgentPort.server else {
				throw FramingError.invalidPort(port)
			}
			guard size <= maximumMessageSize else { throw FramingError.oversized(size) }

			let start = consumed + MessageFraming.chunkHeaderSize
			guard stream.count - start >= size else { break }
			assemblies[port, default: []].append(contentsOf: stream[start..<(start + size)])
			consumed = start + size
			messages += try drainMessages(port: port)
		}
		return messages
	}

	private mutating func drainMessages(port: UInt32) throws -> [AgentMessage] {
		guard var assembly = assemblies[port] else { return [] }
		var messages: [AgentMessage] = []
		var consumed = 0

		while assembly.count - consumed >= MessageFraming.messageHeaderSize {
			let version = assembly.littleEndianUInt32(at: consumed)
			guard version == spiceProtocolVersion else { throw FramingError.invalidProtocol(version) }
			let size = Int(assembly.littleEndianUInt32(at: consumed + 16))
			guard size <= maximumMessageSize else { throw FramingError.oversized(size) }

			let start = consumed + MessageFraming.messageHeaderSize
			guard assembly.count - start >= size else { break }
			let low = UInt64(assembly.littleEndianUInt32(at: consumed + 8))
			let high = UInt64(assembly.littleEndianUInt32(at: consumed + 12))
			messages.append(AgentMessage(rawType: assembly.littleEndianUInt32(at: consumed + 4),
										 opaque: high << 32 | low,
										 data: Data(assembly[start..<(start + size)])))
			consumed = start + size
		}

		assembly.removeFirst(consumed)
		assemblies[port] = assembly
		return messages
	}
}

extension Data {
	mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
		Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
	}

	/// The little-endian `UInt32` at an offset from the start, or nil past the end.
	func littleEndianUInt32(atOffset offset: Int) -> UInt32? {
		guard offset >= 0, count - offset >= 4 else { return nil }
		let bytes = dropFirst(offset).prefix(4)
		return bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
	}
}

extension [UInt8] {
	func littleEndianUInt32(at offset: Int) -> UInt32 {
		UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
			| UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
	}
}
