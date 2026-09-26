<p align="center">
  <img src="BrandAssets/NoctweaveClientAppIcon.svg" alt="Noctweave Messaging Client icon" width="112">
</p>

<a id="noctweave-messaging-client"></a>

<h1 align="center">Noctweave Messaging Client</h1>

<p align="center"><strong>Private conversations, with keys and control on your device.</strong></p>

<p align="center">
  <a href="#overview">Overview</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#features">Features</a> ·
  <a href="#security-and-privacy">Security</a> ·
  <a href="#documentation">Documentation</a>
</p>

## Overview

The native Noctweave app brings encrypted direct messages, experimental
groups, and private attachments to Mac, iPhone, and iPad. Local personas help
organize conversations; every relationship has its own cryptographic authority.

| Detail | At a glance |
| --- | --- |
| Platform | macOS · iPhone · iPad |
| Built with | SwiftUI · NoctweaveCore |
| License | [AGPL-3.0-or-later](LICENSE) |

<a id="requirements"></a>

<a id="build"></a>

## Quick start

Run commands from this repository. The Xcode project expects the public
Noctweave packages in the parent checkout.

- Xcode 26 or later
- macOS 26 / iOS 26 SDKs
- `NoctweaveCore` checked out as a sibling directory at `../NoctweaveCore`
- `NoctweaveSecurityKeys` from the same parent checkout at `../NoctweaveSecurityKeys` (includes pinned YubiKit source)

Open `Noctweave Messaging Client.xcodeproj` in Xcode, or build from the command line:

```sh
xcodebuild \
  -project "Noctweave Messaging Client.xcodeproj" \
  -scheme Noctweave \
  -destination 'platform=macOS' \
  build
```

For an unsigned iOS build:

```sh
xcodebuild \
  -project "Noctweave Messaging Client.xcodeproj" \
  -scheme Noctweave \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

<a id="what-it-includes"></a>

## Features

- Local personas and relationship-scoped identities
- Fast one-use relay pairing, offline pairing, and encrypted direct messaging
- Experimental encrypted group conversations
- Encrypted image, document, audio, and voice-message attachments
- QR-based exchange flows, relay selection, and route prefetching
- Local PIN, biometric, and physical security-key app locking
- A companion iOS sync activity widget

## Pairing and group exchange

Use **Add Contact > Fast via Relay** for the normal path. The inviter creates a
one-use invitation and shares its QR code, protected file, or remote link. The
recipient enters the name they want the other person to see, then scans, opens,
or chooses **Join > Link > Paste and Pair**. Keep both clients open until the verified
relationship appears; there is no separate final approval step.

When the selected relay advertises its operator-enabled pairing lobby, choose
**Be Visible** on one device and **Find People** on the other. Compare the
two-word/six-digit badge in full, send the request, and approve it on the visible
device. The app transfers the one-use link inside a fresh PQ-encrypted route
and continues the same rendezvous automatically. Visibility expires within two
minutes and publishes no persona name. QR, AirDrop/share, protected file, and
paste remain available when the relay has the lobby disabled.

The five-stage offline flow remains available for environments without a relay.
It deliberately stays explicit because every stage must cross the offline
channel without silently mixing either participant's private state.

Group access requests and welcome packages use bounded `.noctgroup` files by
default. Exchange them over an authenticated private channel and delete them
after the member joins. Raw paste remains an advanced fallback for debugging or
channels that cannot transfer files.

## Security and privacy

Noctweave has no protocol accounts, global public identity, hosted inbox, recovery authority, or managed relay service. Relays route and retain ciphertext; they cannot decrypt message or attachment contents. Relay operators and network observers can still infer transport metadata such as IP addresses, timing, availability, destination relay, and traffic volume.

### Hardware security keys

Open **You → Settings → App Security → Choose App Unlock Method**. Choose a FIDO2 security key alone, with an app PIN, with biometrics, or with both. The existing biometrics, PIN, and biometrics + PIN choices remain available.

Every selected factor is required; the lock screen verifies the key, then biometrics, then the app PIN when applicable. The key's own FIDO2 PIN is separate from the six-digit app PIN.

Register the key, enter its existing hardware PIN in the app, and touch it when prompted. Enrollment performs registration and a separate verification, so two touches may be needed. Click **Save Protection** after verification. Add a spare key before enabling continuous presence. Changing existing protection requires all currently selected factors again.

On macOS, **Keep key connected** locks the app when the verified USB key is removed. Reconnecting it never resumes access automatically: all selected unlock checks must succeed again. Each registered spare can start a fresh session, but inserting a different key cannot preserve an existing session. Key modes have no PIN-only or biometric-only recovery bypass, so keep a registered key accessible.

macOS uses generic FIDO2 USB HID. New iOS registrations use the same local WebAuthn flow as Gallery: one branded, ephemeral sheet performs Register → Verify, using Apple's external-key transport while Noctweave generates challenges and verifies signatures locally. There is no hosted authentication service, associated website, or internet requirement. Enter the hardware key's PIN only in the system sheet. Earlier native registrations keep their original scope and direct USB/NFC path; they are never silently reinterpreted as new credentials. If both kinds exist, **Use earlier registration** selects the older path explicitly. Older keys without FIDO over CCID can be enrolled through the new flow after authorizing the existing protection. They cannot use the direct smart-card USB path. iOS and NFC do not offer continuous presence. U2F-only keys and PIV/OTP credentials are not implemented. Native app locking controls application access while existing OS-backed storage encryption remains in place; it is not hardware-derived vault encryption or tamper-resistant DRM.

Local browser credentials use RP `localhost` and the exact origin of a short-lived loopback listener. Localhost is a shared browser namespace, not an app-exclusive domain. Noctweave and Gallery keep independent private credential stores and require a fresh signed proof for their own stored key. Continuous key presence is unavailable through this browser flow.

YubiKit Swift 1.3.0 is Apache-2.0 licensed. Its license is included in the app resources and the sibling security-key package documents the sole read-only USB presence patch.

### Lock-screen privacy

In **You → Settings → App Security → Choose App Unlock Method**, use **Lock-screen privacy** to hide biometric and security-key hints independently. The waiting screen shows a PIN field that accepts duress passwords before any other check. When a key is detected or authentication starts, that waiting field disappears and its contents are cleared. The real PIN step appears only after its configured key and biometric checks pass. Cancelling the key flow returns to the waiting screen. Older hidden-PIN preferences no longer conceal an available PIN step. Hiding a method changes presentation only; every configured factor and the optional USB-presence policy remain enforced.

There is no hidden-method menu, required-check summary, or method-specific error on the waiting screen. On iOS, holding the existing lock emblem for two seconds starts the key flow without displaying a new hint; this also works when automatic USB discovery cannot see a connected key. While the app is active and locked, connecting a USB key starts its authentication flow. Biometric authentication starts when its preceding key check is complete, or immediately if no key is required. Unconfigured checks are skipped. Rejected or cancelled automatic checks do not loop; reconnect the key or begin a new lock attempt to retry. OS authentication prompts still appear during the actual ceremony. Earlier iPhone NFC registrations must be started explicitly. USB discovery depends on the interface iOS exposes and never counts as authentication. Apple's system sheet may offer NFC; the app does not control that system UI. A custom lock message can reveal information, so avoid naming concealed methods there.

### Duress passwords

After authorizing App Security settings, configure up to four distinct passwords and explicitly save protection. Each password selects one action:

- **Wipe local data:** remove this installation's encrypted state, managed attachments, and local decryption keys.
- **Make stored data unreadable:** destroy local decryption keys while retaining encrypted files. This uses cryptographic erasure instead of random file corruption.
- **Show chats and destroy local keys:** retain a temporary, read-only text view of the active persona's direct and group chats, destroy local decryption keys, and stop real messaging. The view disappears when the process closes.
- **Open a decoy:** show an empty, separate local view while the real session stays locked. Restart the app to authenticate normally.

Duress passwords are accepted through the ordinary PIN field before security-key or biometric checks. They never satisfy normal authentication or grant access to the real client. Five rejected inputs cause a 30-second lockout that survives app restarts. Destructive actions require an explicit acknowledgement during configuration; existing legacy action plans remain inactive until recreated. Passwords use salted, domain-separated PBKDF2 verifiers and are stored inside the encrypted app settings.

Attachment files are migrated to an installation-scoped key before a destructive plan can be saved. Erasure retires the state and attachment stores so queued writes cannot recreate their keys.

The operation affects managed local copies only: recipient copies, exports, backups, and copies already taken from process memory remain outside its reach. The temporary chat view deliberately retains plaintext text in memory. A partial erasure failure keeps the real session locked and shows the same neutral unlock error.

## Development

For UI tests, use the root-level `../scripts/run-native-app-tests.sh client`
command. It signs only with Xcode's local ad-hoc identity and reuses an existing
iPhone simulator, keeping its disposable container and Keychain separate from
the Mac login Keychain. It does not create or reset a simulator and does not
read, delete, or replace production client/widget Keychain records. Set
`NOCTWEAVE_IOS_TEST_DEVICE_ID` to select a different existing iPhone.

## Documentation

| Read | For |
| --- | --- |
| [Protocol architecture](https://github.com/luizwidmer/Noctweave/blob/main/NoctweaveDocumentation/noctweave_architecture_revision_v2.md) | Relationship authority and encrypted transport |
| [Pairing lobby](https://github.com/luizwidmer/Noctweave/blob/main/NoctweaveDocumentation/pairing_lobby_v1.md) | Optional same-relay discovery |
| [Security-key package](https://github.com/luizwidmer/Noctweave/blob/main/NoctweaveSecurityKeys/README.md) | Hardware transports and device limits |
| [Application audit](https://github.com/luizwidmer/Noctweave/blob/main/NoctweaveDocumentation/app_security_audit_2026-09-21.md) | Scoped findings, verification, and limits |

## License

This project is free software licensed under the GNU Affero General Public License, version 3 or, at your option, any later version (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).
