# -----------------------------------------------------------------------------
# Copyright © 2026 GigaRip LLC.
#
# Licensed under the MIT License or the Apache License, Version 2.0, at your
# option. See LICENSE-MIT and LICENSE-APACHE in the repository root.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
# -----------------------------------------------------------------------------
"""Plays the SPICE host against the real agent binary over a pty.

Written from vd_agent.h, independent of the Swift codec, so a shared misreading of the format
can't pass unnoticed. Uses a named pasteboard, so the real clipboard is untouched.

Usage: fake-host.py <path to mokarig-guest-agent>
"""
import os, pty, select, struct, subprocess, sys, termios, time, tty, uuid

BIN = sys.argv[1]
CLIPBOARD, ANNOUNCE, GRAB, REQUEST, RELEASE = 4, 6, 7, 8, 9
UTF8, PNG, TIFF, NONE = 1, 2, 4, 0
BY_DEMAND, SELECTION = 1 << 5, 1 << 6

def frame(mtype, body=b""):
	message = struct.pack("<IIQI", 1, mtype, 0, len(body)) + body
	return struct.pack("<II", 1, len(message)) + message

class Host:
	def __init__(self, fd):
		self.fd, self.buf, self.queue = fd, b"", []

	def send(self, mtype, body=b""):
		data = frame(mtype, body)
		while data:
			_, w, _ = select.select([], [self.fd], [], 5)
			assert w, "port not writable"
			n = os.write(self.fd, data[:4096])
			data = data[n:]

	def pump(self, timeout):
		r, _, _ = select.select([self.fd], [], [], timeout)
		if r:
			self.buf += os.read(self.fd, 1 << 20)
		while len(self.buf) >= 8:
			port, size = struct.unpack("<II", self.buf[:8])
			assert port == 1, f"bad chunk port {port}"
			if len(self.buf) < 8 + size:
				break
			chunk, self.buf = self.buf[8:8 + size], self.buf[8 + size:]
			version, mtype, _, dsize = struct.unpack("<IIQI", chunk[:20])
			assert version == 1 and dsize == size - 20, (version, dsize, size)
			self.queue.append((mtype, chunk[20:]))

	def expect(self, mtype, timeout=5):
		end = time.time() + timeout
		while time.time() < end:
			if self.queue:
				got, body = self.queue.pop(0)
				assert got == mtype, f"expected {mtype}, got {got}: {body[:32]!r}"
				return body
			self.pump(0.05)
		raise AssertionError(f"timed out waiting for message {mtype}")

	def silent(self, seconds):
		end = time.time() + seconds
		while time.time() < end:
			self.pump(0.05)
		assert not self.queue, f"unexpected messages: {[m for m, _ in self.queue]}"

def pb_script(name, code):
	swift = f'''
import AppKit
let pb = NSPasteboard(name: NSPasteboard.Name("{name}"))
{code}
'''
	return subprocess.run(["swift", "-e", swift], capture_output=True, text=True, timeout=120).stdout

controller, subordinate = pty.openpty()
tty.setraw(controller)
path = os.ttyname(subordinate)
name = "com.gigarip.mokarig.e2e." + uuid.uuid4().hex
agent = subprocess.Popen([BIN, "-port", path, "-pasteboard", name], stderr=subprocess.PIPE)
host = Host(controller)
checks = []
def ok(label):
	checks.append(label)
	print("ok  ", label)

try:
	body = host.expect(ANNOUNCE)
	request, caps = struct.unpack("<II", body[:8])
	assert request == 1 and caps & BY_DEMAND and caps & SELECTION, (request, hex(caps))
	ok(f"agent announces first, request=1, caps={caps:#x}")

	host.send(ANNOUNCE, struct.pack("<II", 1, BY_DEMAND | SELECTION))
	body = host.expect(ANNOUNCE)
	assert struct.unpack("<I", body[:4])[0] == 0
	ok("agent replies to capability request with request=0")

	prefix = b"\0\0\0\0"
	text = "héllo from the host\n🙂 " + "x" * 5000
	host.send(GRAB, prefix + struct.pack("<II", 5, UTF8))
	body = host.expect(REQUEST)
	assert body == prefix + struct.pack("<I", UTF8), body
	ok("host grab triggers a request for text")

	host.send(CLIPBOARD, prefix + struct.pack("<I", UTF8) + text.encode())
	deadline = time.time() + 30
	got = None
	while time.time() < deadline:
		got = pb_script(name, 'print(pb.string(forType: .string) ?? "<nil>", terminator: "")')
		if got == text:
			break
		time.sleep(0.2)
	assert got == text, repr(got)[:120]
	ok(f"host text reaches the guest pasteboard intact ({len(text.encode())} bytes)")

	host.silent(1.0)
	ok("host data is not echoed back as a grab")

	guest_text = "copied in the guest " + "y" * 200000
	pb_script(name, 'pb.clearContents(); pb.setString("copied in the guest " + String(repeating: "y", count: 200000), forType: .string)')
	body = host.expect(GRAB)
	assert body == prefix + struct.pack("<I", UTF8), body
	ok("guest copy produces one grab listing text")

	host.send(REQUEST, prefix + struct.pack("<I", UTF8))
	body = host.expect(CLIPBOARD, timeout=20)
	assert body[:8] == prefix + struct.pack("<I", UTF8)
	assert body[8:] == guest_text.encode(), len(body)
	ok(f"guest text reaches the host intact ({len(body) - 8} bytes)")

	host.send(REQUEST, prefix + struct.pack("<I", PNG))
	body = host.expect(CLIPBOARD)
	assert body == prefix + struct.pack("<I", NONE), body
	ok("request for an absent type gets NONE")

	pb_script(name, '''
let image = NSImage(size: NSSize(width: 8, height: 8))
image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
pb.clearContents(); pb.setData(image.tiffRepresentation!, forType: .tiff)
''')
	body = host.expect(GRAB)
	assert body == prefix + struct.pack("<II", PNG, TIFF), body
	host.send(REQUEST, prefix + struct.pack("<I", PNG))
	body = host.expect(CLIPBOARD)
	assert body[8:12] == b"\x89PNG", body[:16]
	ok("guest TIFF image is offered and delivered as PNG")

	pb_script(name, '''
pb.clearContents(); pb.setString("hunter2", forType: .string)
pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
''')
	body = host.expect(RELEASE)
	assert body == prefix, body
	ok("concealed copy releases ownership instead of offering data")

	assert agent.poll() is None
	ok("agent still running")

	os.write(controller, b"\xff" * 64)
	time.sleep(0.5)
	assert agent.poll() is None
	ok("agent survives a corrupt stream")

	host.buf, host.queue = b"", []
	body = host.expect(ANNOUNCE, timeout=8)
	assert struct.unpack("<I", body[:4])[0] == 1
	ok("agent reconnects and restarts the handshake after a corrupt stream")

	host.send(ANNOUNCE, struct.pack("<II", 0, BY_DEMAND))
	host.send(GRAB, struct.pack("<I", UTF8))
	body = host.expect(REQUEST)
	assert body == struct.pack("<I", UTF8), body
	ok("reconnected session drops the selection prefix for a host without it")
finally:
	agent.terminate()
	agent.wait(timeout=5)
	err = agent.stderr.read().decode()
	if err.strip():
		print("stderr:", err[:400])

print(f"\nall {len(checks)} checks passed")
