# Noctweave Messaging Client

Noctweave Messaging Client is the native SwiftUI client for the Noctweave private messaging protocol. It runs on macOS, iPhone, and iPad and uses the sibling `NoctweaveCore` Swift package for protocol models, cryptographic flows, message transport, and relay interoperability.

## What it includes

- Local personas and relationship-scoped identities
- Fast one-use relay pairing, offline pairing, and encrypted direct messaging
- Experimental encrypted group conversations
- Encrypted image, document, audio, and voice-message attachments
- QR-based exchange flows, relay selection, and route prefetching
- Local PIN and biometric app locking
- A companion iOS sync activity widget

Noctweave has no protocol accounts, global public identity, hosted inbox, recovery authority, or managed relay service. Relays route and retain ciphertext; they cannot decrypt message or attachment contents. Relay operators and network observers can still infer transport metadata such as IP addresses, timing, availability, destination relay, and traffic volume.

## Pairing and group exchange

Use **Add Contact > Fast via Relay** for the normal path. The inviter creates a
one-use invitation and shares its QR code, protected file, or remote link. The
recipient enters the name they want the other person to see, then scans, opens,
or chooses **Paste and Pair**. Keep both clients open until the verified
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

## Requirements

- Xcode 26 or later
- macOS 26 / iOS 26 SDKs
- `NoctweaveCore` checked out as a sibling directory at `../NoctweaveCore`

## Build

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

For UI tests, use the root-level `scripts/run-native-app-tests.sh client`
command. It signs only with Xcode's local ad-hoc identity and reuses an existing
iPhone simulator, keeping its disposable container and Keychain separate from
the Mac login Keychain. It does not create or reset a simulator and does not
read, delete, or replace production client/widget Keychain records. Set
`NOCTWEAVE_IOS_TEST_DEVICE_ID` to select a different existing iPhone.

## License

This project is free software licensed under the GNU Affero General Public License, version 3 or, at your option, any later version (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).
