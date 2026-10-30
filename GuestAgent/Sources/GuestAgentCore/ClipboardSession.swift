// -----------------------------------------------------------------------------
// Copyright © 2026 GigaRip LLC.
//
// Licensed under the MIT License or the Apache License, Version 2.0, at your
// option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
// -----------------------------------------------------------------------------

import Foundation

/// The guest clipboard, as seen by `ClipboardSession`.
public protocol ClipboardBackend: AnyObject {
	/// A counter that changes whenever the clipboard's contents change.
	var changeCount: Int { get }
	/// The formats currently available, without reading the contents. Empty when nothing may be shared.
	func availableTypes() -> [ClipboardType]
	/// The clipboard contents in one format, or nil if that format isn't available.
	func data(for type: ClipboardType) -> Data?
	/// Replaces the clipboard with the given representations of a single item.
	func write(_ items: [ClipboardType: Data])
}

/// The SPICE clipboard protocol state machine for one connection to the host.
///
/// Host data is requested as soon as the host grabs the clipboard. Waiting for a paste would need a
/// lazy pasteboard provider, which runs on the main thread and would have to block it on the port
/// that same thread services. Guest data is read only when the host requests it, which keeps
/// background pasteboard reads to the moments the user actually pastes on the host.
public final class ClipboardSession {
	/// The formats requested from the host, most useful first. Each has a pasteboard equivalent.
	private static let inboundTypes: [ClipboardType] = [.utf8Text, .png, .tiff]

	private static let ownCapabilities: Capabilities = [
		.clipboardByDemand, .clipboardSelection, .guestLineEndLF, .maxClipboard,
	]

	private let backend: any ClipboardBackend
	private let send: (Data) -> Void

	private var hostCapabilities: Capabilities?
	private var maximumClipboardSize: Int?
	private var lastChangeCount: Int
	private var guestOwnsClipboard = false
	private var pendingTypes: [ClipboardType] = []
	private var receivedItems: [ClipboardType: Data] = [:]

	/// Creates a session. Clipboard contents from before this moment are not offered to the host, so a
	/// guest booting doesn't replace the host's clipboard.
	/// - Parameters:
	///   - backend: The guest clipboard.
	///   - send: Writes encoded bytes to the port.
	public init(backend: any ClipboardBackend, send: @escaping (Data) -> Void) {
		self.backend = backend
		self.send = send
		lastChangeCount = backend.changeCount
	}

	/// Announces this agent's capabilities and asks for the host's.
	public func start() {
		sendCapabilities(request: true)
	}

	/// Handles one message from the host. Unknown and malformed messages are ignored.
	public func receive(_ message: AgentMessage) {
		guard let type = MessageType(rawValue: message.type) else { return }
		switch type {
		case .announceCapabilities: handleCapabilities(message.data)
		case .clipboardGrab: handleGrab(message.data)
		case .clipboardRequest: handleRequest(message.data)
		case .clipboard: handleClipboard(message.data)
		case .clipboardRelease: cancelInboundTransfer()
		case .maxClipboard: maximumClipboardSize = handleMaxClipboard(message.data)
		case .clientDisconnected:
			cancelInboundTransfer()
			hostCapabilities = nil
			guestOwnsClipboard = false
		}
	}

	/// Checks for a guest clipboard change and tells the host about it.
	public func pollPasteboard() {
		// Sending a grab before the host's capabilities arrive is forbidden. The count is left
		// unconsumed so a change made during the handshake is offered once it finishes.
		guard canUseClipboard, backend.changeCount != lastChangeCount else { return }
		lastChangeCount = backend.changeCount
		cancelInboundTransfer()

		let types = backend.availableTypes()
		if !types.isEmpty {
			guestOwnsClipboard = true
			var body = selectionPrefix
			types.forEach { body.appendLittleEndian($0.rawValue) }
			send(AgentMessage(type: .clipboardGrab, data: body).encoded())
		} else if guestOwnsClipboard {
			guestOwnsClipboard = false
			send(AgentMessage(type: .clipboardRelease, data: selectionPrefix).encoded())
		}
	}

	private var canUseClipboard: Bool {
		hostCapabilities?.contains(.clipboardByDemand) == true
	}

	private var usesSelection: Bool {
		hostCapabilities?.contains(.clipboardSelection) == true
	}

	/// The selection field, present only when both sides announced support for it.
	private var selectionPrefix: Data {
		usesSelection ? Data(count: 4) : Data()
	}

	private func sendCapabilities(request: Bool) {
		var body = Data()
		body.appendLittleEndian(UInt32(request ? 1 : 0))
		body.appendLittleEndian(Self.ownCapabilities.rawValue)
		send(AgentMessage(type: .announceCapabilities, data: body).encoded())
	}

	private func handleCapabilities(_ body: Data) {
		guard let request = body.littleEndianUInt32(atOffset: 0),
			  let capabilities = body.littleEndianUInt32(atOffset: 4) else { return }
		hostCapabilities = Capabilities(rawValue: capabilities)
		if request != 0 {
			sendCapabilities(request: false)
		}
	}

	/// The offset of the fields after the selection prefix, or nil for another selection. macOS has only
	/// the general pasteboard, so PRIMARY and SECONDARY have nothing to map to.
	private func clipboardFieldsOffset(_ body: Data) -> Int? {
		guard usesSelection else { return 0 }
		return body.first == 0 ? 4 : nil
	}

	private func handleGrab(_ body: Data) {
		guard canUseClipboard, let offset = clipboardFieldsOffset(body) else { return }
		let offered = stride(from: offset, to: body.count, by: 4)
			.compactMap { body.littleEndianUInt32(atOffset: $0) }
			.compactMap(ClipboardType.init(rawValue:))
		guestOwnsClipboard = false
		cancelInboundTransfer()
		pendingTypes = Self.inboundTypes.filter(offered.contains)
		requestNextType()
	}

	private func requestNextType() {
		guard let type = pendingTypes.first else {
			finishInboundTransfer()
			return
		}
		var body = selectionPrefix
		body.appendLittleEndian(type.rawValue)
		send(AgentMessage(type: .clipboardRequest, data: body).encoded())
	}

	private func finishInboundTransfer() {
		guard !receivedItems.isEmpty else { return }
		backend.write(receivedItems)
		receivedItems = [:]
		// The write isn't a guest copy, and offering it back would bounce the data to the host.
		lastChangeCount = backend.changeCount
	}

	private func cancelInboundTransfer() {
		pendingTypes = []
		receivedItems = [:]
	}

	private func handleClipboard(_ body: Data) {
		guard let offset = clipboardFieldsOffset(body),
			  let rawType = body.littleEndianUInt32(atOffset: offset),
			  let type = ClipboardType(rawValue: rawType),
			  let expected = pendingTypes.first,
			  type == expected || type == .none else { return }
		pendingTypes.removeFirst()
		if type != .none {
			receivedItems[type] = Data(body.dropFirst(offset + 4))
		}
		requestNextType()
	}

	private func handleRequest(_ body: Data) {
		guard canUseClipboard, let offset = clipboardFieldsOffset(body),
			  let rawType = body.littleEndianUInt32(atOffset: offset),
			  let type = ClipboardType(rawValue: rawType) else { return }

		var response = selectionPrefix
		if guestOwnsClipboard, let contents = backend.data(for: type), fitsClipboardLimit(contents) {
			response.appendLittleEndian(type.rawValue)
			response.append(contents)
		} else {
			response.appendLittleEndian(ClipboardType.none.rawValue)
		}
		send(AgentMessage(type: .clipboard, data: response).encoded())
	}

	private func fitsClipboardLimit(_ contents: Data) -> Bool {
		guard let maximumClipboardSize else { return true }
		return contents.count <= maximumClipboardSize
	}

	/// The announced limit, or nil when the host set none. Negative means unlimited in the protocol.
	private func handleMaxClipboard(_ body: Data) -> Int? {
		guard let raw = body.littleEndianUInt32(atOffset: 0) else { return nil }
		let limit = Int32(bitPattern: raw)
		return limit < 0 ? nil : Int(limit)
	}
}
