# MokaRig Guest Agent

Runs inside a macOS guest and shares its clipboard with the host. It is the guest half of the
Share Clipboard setting, which attaches a SPICE agent port to the VM. The agent speaks the SPICE
agent protocol over that port, so it does what `spice-vdagent` and `spice-vdagentd` do on Linux.

## Design

- **One process, no root daemon.** Serial device nodes are world-accessible on macOS, so a per-user
	LaunchAgent can open the port directly.
- **Only the console user is connected.** One agent runs per logged-in user, and each holds the port
	only while its session is active. A background user's clipboard never reaches the host.
- **Guest contents are read only on request.** A copy in the guest sends the host a list of formats,
	taken from pasteboard type names. Contents are read when the host pastes.
- **Host contents are fetched on copy.** The agent requests the data as soon as the host offers it,
	so everything copied on the host enters the guest even if it's never pasted. A lazy pasteboard
	provider would avoid that, but it runs on the main thread and would have to block it on the port.
- **Private items stay in the guest.** Pasteboard items marked with the nspasteboard.org concealed or
	transient types are never offered.

Text, PNG, and TIFF are supported in both directions. TIFF-only guest content is also offered as PNG.
Files are not supported.

The protocol constants come from `vd_agent.h` in spice-protocol. No code is taken from the GPL
`vd_agent` or from `tart-guest-agent`.

## Build and test

```bash
swift test
```

```bash
Packaging/build-pkg.sh 0.1.0
```

The second command writes `.build/pkg/MokaRigGuestAgent-0.1.0.pkg`. Without signing identities the
package is ad-hoc signed, which is enough for testing. `build-pkg.sh` documents the signing variables.

`Packaging/build-guest-tools.sh` wraps that package in `GuestTools.img`, a raw HFS+ disk image. The
MokaRig app target runs it through a build phase and ships the image in its resources.

`Tests/EndToEnd/fake-host.py` plays the host against a built binary over a pseudo-terminal, using a
named pasteboard. It is written independently of the Swift code, so it also checks the wire format:

```bash
python3 Tests/EndToEnd/fake-host.py "$(swift build -c release --show-bin-path)/mokarig-guest-agent"
```

Pseudo-terminals ignore `TIOCEXCL`, so exclusive port access can't be covered by these tests. It needs
a real serial node or a guest.

## Install in a guest

Requires macOS 15 or later in the guest, with Share Clipboard turned on for the VM. MokaRig attaches
the MokaRig Guest Tools disk to the VM at startup. In the guest, open that disk in Finder and
double-click Install MokaRig Guest Agent. From a terminal, the same install is:

```bash
sudo installer -pkg "/Volumes/MokaRig Guest Tools/Install MokaRig Guest Agent.pkg" -target /
```

The agent starts immediately. macOS may report a new background item, and it may ask for permission
the first time the host pastes guest contents.

Once the agent is installed, turn off Attach Guest Tools in the VM's configuration to remove the disk.
Every VM attaches the same read-only image, so running VMs can't affect each other through it.

## Troubleshooting

Watch the agent's log in the guest:

```bash
log stream --level info --predicate 'subsystem == "com.gigarip.mokarig.guest-agent"'
```

"Can't open /dev/tty.com.redhat.spice.0" means the port isn't there, so check that Share Clipboard is
on and the VM has restarted since it was turned on. The agent retries every five seconds.

## Uninstall

Run these in the guest:

```bash
launchctl bootout "gui/$(id -u)/com.gigarip.mokarig.guest-agent"
```

```bash
sudo rm "/Library/LaunchAgents/com.gigarip.mokarig.guest-agent.plist"
```

```bash
sudo rm -rf "/Library/Application Support/MokaRig/MokaRig Guest Agent.app"
```

```bash
sudo pkgutil --forget com.gigarip.mokarig.guest-agent
```

## Known limits

- **Suspend and resume.** Virtualization.framework reportedly doesn't restore the port's open state
	when a saved VM resumes. MokaRig doesn't save VM state today. A future suspend feature needs the
	agent to reopen the port on resume.
