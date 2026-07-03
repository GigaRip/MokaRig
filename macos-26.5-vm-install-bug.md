# Why macOS guest installation fails on macOS 26.5.x hosts

> **Status:** Known Apple platform bug, unresolved as of macOS 26.5.2 (July 2026).
> MokaRig detects this failure and explains it rather than letting the install
> die with an opaque error. This document is the long-form explanation.

## The symptom

Creating a **new** macOS virtual machine with Apple's Virtualization.framework
on a macOS Tahoe 26.5.x host fails deterministically near the end of
installation (roughly 75–90% progress) with:

```
Error Domain=VZErrorDomain Code=10007 "Installation failed."
  NSUnderlyingError: Domain=com.apple.MobileDevice.MobileRestore Code=-1
  "AMRestorePerformRestoreModeRestoreWithError failed with error: 11"
```

The failure is independent of which app performs the install. It reproduces
identically in [Tart, VirtualBuddy](https://developer.apple.com/forums/tags/virtualization)
(reported as FB23038153), [UTM](https://github.com/utmapp/UTM),
[VirtualBuddy](https://github.com/insidegui/VirtualBuddy/discussions/591), and
Apple's own
[macOSVirtualMachineSampleApp](https://developer.apple.com/documentation/Virtualization/running-macos-in-a-virtual-machine-on-apple-silicon)
sample code — which is strong evidence that the bug is in the platform, not in
any third-party application.

It is also largely independent of the guest version being installed:

| Guest IPSW | Host | Result |
|---|---|---|
| Sequoia 15.6.1 / 15.4.1 | Tahoe 26.5.1 | Fails (error 11) |
| Tahoe 26.5.2 (matching host build) | Tahoe 26.5.2 | Fails (error 11) |
| macOS 27 beta | Tahoe 26.6 | Fails at ~77% |
| macOS 27 beta | macOS 27 host | Works |
| Any (already-restored VM bundle, copied in) | Tahoe 26.5.x | **Works** |

The last row is the key observation: **the bug is install-time only.** A VM
restored on an older host runs perfectly when its bundle is copied to a
26.5.x machine
([VirtualBuddy discussion #591](https://github.com/insidegui/VirtualBuddy/discussions/591)).

## What is actually failing

Installing a macOS guest is not a file copy. Virtualization.framework performs
a full device-style restore, driven by the host-side
`com.apple.Virtualization.Installation` XPC service: the guest is booted
through DFU → Recovery → RestoreOS states, the install is personalized against
Apple's TSS signing service, the OS images are streamed into the guest, and
finally a host-side "bootability bundle" is assembled so the VM can boot.

Capturing the service's logs during a failing install on a 26.5.2 host
(`log stream --predicate 'process CONTAINS "Virtualization"' --info`) shows
that everything succeeds — the TSS request returns HTTP 200, every boot object
is sent — until the very last host-side step:

```
copying .../IpswExtract.*/BootabilityBundle/ -> .../bootability-bundle-*/
renaming .../bootability-bundle-*/Restore/Bootability/BootabilityBrain.framework
      -> .../bootability-bundle-*/BootabilityBrain.framework
rename() failed: 1
unlinking staging directory ...
<Restore Device>: Restore failed (result = 11)
AMRestorePerformRestoreModeRestoreWithError failed with error: 11
```

`rename() failed: 1` is **EPERM (Operation not permitted)** — on a plain
directory rename, within the same parent directory, inside the installer's own
temporary folder in `/var/folders`, performed by Apple's own root-owned
service. On a machine with:

- zero third-party system extensions (`systemextensionsctl list` → 0),
- no file flags on the staged files (`ls -lO@` shows clean permissions),
- ample disk space, internal-SSD storage, and unfiltered network access,

there is no user-side explanation for that EPERM. The failure signature is
consistent with the OS itself denying the operation (for example, a sandbox
profile regression in the 26.5.x MobileDevice/Virtualization restore path) —
though only Apple can confirm the root cause. What can be said with
confidence: it is deterministic, app-independent, IPSW-independent, new in the
26.5.x host timeframe, and it fails on the *host* side after the guest restore
has effectively succeeded.

## Not this bug: two look-alikes to rule out first

Other, unrelated problems produce the same `VZErrorDomain 10007` code:

1. **VM storage on an external drive.** At least one report shows error 10007
   installing a 26.0.1 guest on a 26.0.1 host with VM storage on an external
   SSD, resolved by moving storage to the internal disk
   ([VirtualBuddy #591](https://github.com/insidegui/VirtualBuddy/discussions/591)).
2. **Filtered network access.** The restore personalizes against Apple's
   signing servers; blocking hosts such as `fcs-keys-pub-prod.cdn-apple.com`
   (strict firewalls, DNS filtering) breaks installation
   ([Anka documentation](https://docs.veertu.com/anka/)).

MokaRig's triage checks these first. If neither applies and the host is on an
affected macOS build, the failure above is the remaining explanation.

## Workarounds

1. **Restore the VM on a host running an older macOS, then copy the bundle.**
   VM bundles are plain directories; a bundle restored on (for example) a
   Sequoia host boots normally on a 26.5.x host.
2. **Wait for a fixed host update.** Apple engineers have acknowledged
   host/IPSW installation incompatibilities in this area on the
   [Developer Forums](https://developer.apple.com/forums/tags/virtualization),
   and comparable Tahoe VM bugs have been fixed in point releases (e.g. the
   26.1 VM Apple Account sign-in bug, r.163294564, fixed in 26.2).

Reinstalling `MobileDevice.pkg` from Xcode (a commonly suggested fix) does
**not** resolve this variant — multiple reporters tried packages from both
Xcode 26.5.0 and Xcode 27 betas without success.

## References

- Apple Developer Forums — Virtualization tag (FB23038153 and related
  reports): <https://developer.apple.com/forums/tags/virtualization>
- VirtualBuddy discussion #591 — community thread covering the error across
  hosts and guests, the external-SSD confounder, and the
  restore-elsewhere-and-copy workaround:
  <https://github.com/insidegui/VirtualBuddy/discussions/591>
- Apple sample code that reproduces the failure on affected hosts:
  <https://developer.apple.com/documentation/Virtualization/running-macos-in-a-virtual-machine-on-apple-silicon>

---

*This analysis was performed on macOS 26.5.2 (host), reproducing the failure
with Apple's sample app, UTM, and MokaRig itself, using both the 26.5.2 and
26.5 IPSWs. Log excerpts are from `com.apple.Virtualization.Installation` on
the affected machine. If you have additional data points (other host/guest
combinations, or a confirmed fix in a newer macOS build), please open an
issue.*
