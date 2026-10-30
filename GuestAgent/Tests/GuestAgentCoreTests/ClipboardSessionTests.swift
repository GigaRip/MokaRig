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

private final class FakeClipboard: ClipboardBackend {
	var changeCount = 0
	var types: [ClipboardType] = []
	var contents: [ClipboardType: Data] = [:]
	var readCount = 0
	var writes: [[ClipboardType: Data]] = []

	func availableTypes() -> [ClipboardType] {
		types
	}

	func data(for type: ClipboardType) -> Data? {
		readCount += 1
		return contents[type]
	}

	func write(_ items: [ClipboardType: Data]) {
		writes.append(items)
		changeCount += 1
	}

	func copy(_ text: String) {
		types = [.utf8Text]
		contents = [.utf8Text: Data(text.utf8)]
		changeCount += 1
	}
}

/// A scripted host: decodes what the session sends, and builds what a host would send back.
private final class FakeHost {
	var decoder = FrameDecoder()
	var sent: [AgentMessage] = []
	let usesSelection: Bool

	init(usesSelection: Bool = true) {
		self.usesSelection = usesSelection
	}

	func take(_ bytes: Data) {
		sent += (try? decoder.feed(bytes)) ?? []
	}

	func drain() -> [AgentMessage] {
		defer { sent = [] }
		return sent
	}

	func capabilities(request: Bool, _ capabilities: Capabilities? = nil) -> AgentMessage {
		var own = capabilities ?? [.clipboardByDemand]
		if usesSelection { own.insert(.clipboardSelection) }
		var body = Data()
		body.appendLittleEndian(UInt32(request ? 1 : 0))
		body.appendLittleEndian(own.rawValue)
		return AgentMessage(type: .announceCapabilities, data: body)
	}

	func prefix(selection: UInt8 = 0) -> Data {
		usesSelection ? Data([selection, 0, 0, 0]) : Data()
	}

	func grab(_ types: [ClipboardType], selection: UInt8 = 0) -> AgentMessage {
		var body = prefix(selection: selection)
		types.forEach { body.appendLittleEndian($0.rawValue) }
		return AgentMessage(type: .clipboardGrab, data: body)
	}

	func request(_ type: ClipboardType) -> AgentMessage {
		var body = prefix()
		body.appendLittleEndian(type.rawValue)
		return AgentMessage(type: .clipboardRequest, data: body)
	}

	func clipboard(_ type: ClipboardType, _ contents: Data = Data()) -> AgentMessage {
		var body = prefix()
		body.appendLittleEndian(type.rawValue)
		body.append(contents)
		return AgentMessage(type: .clipboard, data: body)
	}
}

/// The type field of a clipboard message, after the selection prefix.
private func field(_ message: AgentMessage, at offset: Int) -> UInt32? {
	message.data.littleEndianUInt32(atOffset: offset)
}

private func makeSession(usesSelection: Bool = true, handshake: Bool = true)
	-> (ClipboardSession, FakeClipboard, FakeHost) {
	let clipboard = FakeClipboard()
	let host = FakeHost(usesSelection: usesSelection)
	let session = ClipboardSession(backend: clipboard) { host.take($0) }
	if handshake {
		session.start()
		session.receive(host.capabilities(request: false))
		_ = host.drain()
	}
	return (session, clipboard, host)
}

@Suite struct ClipboardSessionTests {
	@Test func opensByAnnouncingAndRequestingCapabilities() throws {
		let (session, _, host) = makeSession(handshake: false)
		session.start()
		let message = try #require(host.drain().first)
		#expect(message.type == MessageType.announceCapabilities.rawValue)
		#expect(field(message, at: 0) == 1)
		let announced = Capabilities(rawValue: try #require(field(message, at: 4)))
		#expect(announced.contains([.clipboardByDemand, .clipboardSelection, .guestLineEndLF, .maxClipboard]))
	}

	@Test func answersACapabilityRequestWithoutAskingBack() throws {
		let (session, _, host) = makeSession(handshake: false)
		session.receive(host.capabilities(request: true))
		let message = try #require(host.drain().first)
		#expect(message.type == MessageType.announceCapabilities.rawValue)
		#expect(field(message, at: 0) == 0)
	}

	@Test func sendsNoClipboardMessagesBeforeTheHandshake() {
		let (session, clipboard, host) = makeSession(handshake: false)
		clipboard.copy("early")
		session.pollPasteboard()
		#expect(host.drain().isEmpty)
	}

	@Test func offersACopyMadeDuringTheHandshakeOnceItFinishes() {
		let (session, clipboard, host) = makeSession(handshake: false)
		clipboard.copy("early")
		session.pollPasteboard()
		session.receive(host.capabilities(request: false))
		session.pollPasteboard()
		#expect(host.drain().map(\.type) == [MessageType.clipboardGrab.rawValue])
	}

	@Test func doesNotOfferWhatWasOnTheClipboardBeforeConnecting() {
		let clipboard = FakeClipboard()
		clipboard.copy("old")
		let host = FakeHost()
		let session = ClipboardSession(backend: clipboard) { host.take($0) }
		session.receive(host.capabilities(request: false))
		session.pollPasteboard()
		#expect(host.drain().isEmpty)
	}

	@Test func refusesToActWithAHostThatLacksByDemand() {
		let (session, clipboard, host) = makeSession(handshake: false)
		session.receive(host.capabilities(request: false, []))
		clipboard.copy("text")
		session.pollPasteboard()
		session.receive(host.grab([.utf8Text]))
		#expect(host.drain().isEmpty)
	}

	@Test func grabsOnAGuestCopyWithoutReadingContents() throws {
		let (session, clipboard, host) = makeSession()
		clipboard.copy("hello")
		session.pollPasteboard()
		let message = try #require(host.drain().first)
		#expect(message.type == MessageType.clipboardGrab.rawValue)
		#expect(message.data == Data([0, 0, 0, 0, 1, 0, 0, 0]))
		#expect(clipboard.readCount == 0)
	}

	@Test func grabsOnlyOncePerChange() {
		let (session, clipboard, host) = makeSession()
		clipboard.copy("hello")
		session.pollPasteboard()
		session.pollPasteboard()
		#expect(host.drain().count == 1)
	}

	@Test func answersARequestWithTheContents() throws {
		let (session, clipboard, host) = makeSession()
		clipboard.copy("hello")
		session.pollPasteboard()
		_ = host.drain()
		session.receive(host.request(.utf8Text))
		let message = try #require(host.drain().first)
		#expect(message.type == MessageType.clipboard.rawValue)
		#expect(field(message, at: 4) == ClipboardType.utf8Text.rawValue)
		#expect(message.data.dropFirst(8) == Data("hello".utf8))
	}

	@Test func answersAnUnavailableTypeWithNone() throws {
		let (session, clipboard, host) = makeSession()
		clipboard.copy("hello")
		session.pollPasteboard()
		_ = host.drain()
		session.receive(host.request(.png))
		let message = try #require(host.drain().first)
		#expect(field(message, at: 4) == ClipboardType.none.rawValue)
		#expect(message.data.count == 8)
	}

	@Test func answersARequestAfterLosingOwnershipWithNone() throws {
		let (session, clipboard, host) = makeSession()
		clipboard.copy("secret")
		session.pollPasteboard()
		session.receive(host.grab([]))
		_ = host.drain()
		session.receive(host.request(.utf8Text))
		let message = try #require(host.drain().first)
		#expect(field(message, at: 4) == ClipboardType.none.rawValue)
		#expect(clipboard.readCount == 0)
	}

	@Test func honorsTheHostClipboardLimit() throws {
		let (session, clipboard, host) = makeSession()
		var limit = Data()
		limit.appendLittleEndian(Int32(3))
		session.receive(AgentMessage(type: .maxClipboard, data: limit))
		clipboard.copy("too long")
		session.pollPasteboard()
		_ = host.drain()
		session.receive(host.request(.utf8Text))
		let message = try #require(host.drain().first)
		#expect(field(message, at: 4) == ClipboardType.none.rawValue)
	}

	@Test func treatsANegativeLimitAsUnlimited() throws {
		let (session, clipboard, host) = makeSession()
		var limit = Data()
		limit.appendLittleEndian(Int32(-1))
		session.receive(AgentMessage(type: .maxClipboard, data: limit))
		clipboard.copy("any size")
		session.pollPasteboard()
		_ = host.drain()
		session.receive(host.request(.utf8Text))
		let message = try #require(host.drain().first)
		#expect(field(message, at: 4) == ClipboardType.utf8Text.rawValue)
	}

	@Test func releasesWhenTheClipboardStopsBeingShareable() {
		let (session, clipboard, host) = makeSession()
		clipboard.copy("hello")
		session.pollPasteboard()
		_ = host.drain()
		clipboard.types = []
		clipboard.changeCount += 1
		session.pollPasteboard()
		#expect(host.drain().map(\.type) == [MessageType.clipboardRelease.rawValue])
	}

	@Test func requestsEveryUsableHostTypeThenWritesThemTogether() {
		let (session, clipboard, host) = makeSession()
		session.receive(host.grab([.jpg, .png, .utf8Text]))
		#expect(host.drain().compactMap { field($0, at: 4) } == [ClipboardType.utf8Text.rawValue])
		session.receive(host.clipboard(.utf8Text, Data("text".utf8)))
		#expect(clipboard.writes.isEmpty)
		#expect(host.drain().compactMap { field($0, at: 4) } == [ClipboardType.png.rawValue])
		session.receive(host.clipboard(.png, Data([1, 2])))
		#expect(clipboard.writes == [[.utf8Text: Data("text".utf8), .png: Data([1, 2])]])
	}

	@Test func skipsAHostTypeAnsweredWithNone() {
		let (session, clipboard, host) = makeSession()
		session.receive(host.grab([.utf8Text, .png]))
		session.receive(host.clipboard(.none))
		session.receive(host.clipboard(.png, Data([9])))
		#expect(clipboard.writes == [[.png: Data([9])]])
	}

	@Test func doesNotEchoHostDataBackToTheHost() {
		let (session, _, host) = makeSession()
		session.receive(host.grab([.utf8Text]))
		session.receive(host.clipboard(.utf8Text, Data("from host".utf8)))
		_ = host.drain()
		session.pollPasteboard()
		#expect(host.drain().isEmpty)
	}

	@Test func aNewHostGrabReplacesATransferInProgress() {
		let (session, clipboard, host) = makeSession()
		session.receive(host.grab([.utf8Text, .png]))
		session.receive(host.clipboard(.utf8Text, Data("stale".utf8)))
		session.receive(host.grab([.utf8Text]))
		session.receive(host.clipboard(.utf8Text, Data("fresh".utf8)))
		#expect(clipboard.writes == [[.utf8Text: Data("fresh".utf8)]])
	}

	@Test func aGuestCopyWinsOverAHostTransferInProgress() {
		let (session, clipboard, host) = makeSession()
		session.receive(host.grab([.utf8Text]))
		clipboard.copy("guest")
		session.pollPasteboard()
		session.receive(host.clipboard(.utf8Text, Data("late".utf8)))
		#expect(clipboard.writes.isEmpty)
	}

	@Test func ignoresDataThatWasNeverRequested() {
		let (session, clipboard, host) = makeSession()
		session.receive(host.clipboard(.utf8Text, Data("unsolicited".utf8)))
		#expect(clipboard.writes.isEmpty)
	}

	@Test func ignoresOtherSelections() {
		let (session, _, host) = makeSession()
		session.receive(host.grab([.utf8Text], selection: 1))
		#expect(host.drain().isEmpty)
	}

	@Test func omitsTheSelectionPrefixWhenTheHostDoesNotUseIt() throws {
		let (session, clipboard, host) = makeSession(usesSelection: false)
		session.receive(host.grab([.utf8Text]))
		let request = try #require(host.drain().first)
		#expect(request.data == Data([1, 0, 0, 0]))
		session.receive(host.clipboard(.utf8Text, Data("plain".utf8)))
		#expect(clipboard.writes == [[.utf8Text: Data("plain".utf8)]])
		clipboard.copy("guest")
		session.pollPasteboard()
		#expect(host.drain().first?.data == Data([1, 0, 0, 0]))
	}

	@Test func stopsUntilCapabilitiesReturnAfterAClientDisconnect() {
		let (session, clipboard, host) = makeSession()
		session.receive(AgentMessage(type: .clientDisconnected))
		clipboard.copy("hello")
		session.pollPasteboard()
		#expect(host.drain().isEmpty)
		session.receive(host.capabilities(request: false))
		session.pollPasteboard()
		#expect(host.drain().map(\.type) == [MessageType.clipboardGrab.rawValue])
	}

	@Test func ignoresMalformedAndUnknownMessages() {
		let (session, clipboard, host) = makeSession()
		session.receive(AgentMessage(rawType: 999))
		session.receive(AgentMessage(type: .clipboardRequest, data: Data([0])))
		session.receive(AgentMessage(type: .clipboard, data: Data([0, 0])))
		session.receive(AgentMessage(type: .announceCapabilities, data: Data([1])))
		#expect(host.drain().isEmpty)
		#expect(clipboard.writes.isEmpty)
	}
}
