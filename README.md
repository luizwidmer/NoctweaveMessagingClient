# Noctweave Messaging Client

Noctweave Messaging Client is the native SwiftUI client for the Noctweave private messaging protocol. It runs on macOS, iPhone, and iPad and uses the sibling `NoctweaveCore` Swift package for protocol models, cryptographic flows, message transport, and relay interoperability.

## What it includes

- Local personas and relationship-scoped identities
- Post-quantum pairing and encrypted direct messaging
- Experimental encrypted group conversations
- Encrypted image, document, audio, and voice-message attachments
- QR-based exchange flows, relay selection, and route prefetching
- Local PIN and biometric app locking
- A companion iOS sync activity widget

Noctweave has no protocol accounts, global public identity, hosted inbox, recovery authority, or managed relay service. Relays route and retain ciphertext; they cannot decrypt message or attachment contents. Relay operators and network observers can still infer transport metadata such as IP addresses, timing, availability, destination relay, and traffic volume.

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

## License

This project is free software licensed under the GNU Affero General Public License, version 3 or, at your option, any later version (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).
