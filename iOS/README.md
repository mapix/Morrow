# Smail for iPhone and iPad

Native SwiftUI target, shared SmailCore SQLite/MIME/IMAP/POP3/Agent/OpenUI/embedding protocols. The app has contextual Chat, separate Sessions, contacts, attachments, read state, drafts, manual mailbox setup, voice, language/theme choices, managed memories and foreground draft responders.

## Build

Xcode 26, XcodeGen and asc are required. Run from the repository:

```sh
scripts/build-mobile.sh simulator
scripts/build-mobile.sh device
```

The second command validates the hardware SDK without signing. It does **not** produce an installable IPA. For a registered iPhone and an authenticated Xcode developer account:

```sh
MORROW_DEVELOPMENT_TEAM=YOUR_TEAM scripts/build-mobile.sh signed-device
```

Open `iOS/SmailMobile.xcodeproj` to select your team/device, then Run. No App Store upload is performed by these scripts.

## Model

The app bundles the exact BF16 EmbeddingGemma 2 language tensors, without audio/vision towers. `scripts/pack-mobile-embedding.py` preserves retained tensor bytes and records source/packed checksums. The packed model is 542,056,448 bytes, plus tokenizer/config files. The pack is verified using real macOS Metal; iPhone RAM/Metal performance requires a physical device.

MLX 0.33 fatally assumes Metal architecture information and shared heaps unavailable in the iOS simulator. The simulator explicitly rejects semantic-model loading and offers keyword search. It never manufactures vectors or labels keyword results as semantic. Hardware builds retain the actual model path.

## Current acceptance boundaries

- Native SMTP performs certificate-checked implicit TLS or STARTTLS, with no plaintext credential fallback. A read-only Gmail TLS/EHLO probe passed and a wrong-host certificate was rejected. This does not prove a real account's SMTP authentication or delivery.
- The phone syncs/works while foregrounded. Responders create drafts; desktop automatic-send permissions are not transferred to the phone.
- Gmail/ChatGPT browser login needs a mobile callback/client contract. The current desktop client IDs/tokens are not copied to iPhone. Manual IMAP/POP app-password accounts and model services have their own native settings.
- iCloud defaults off and creates no CloudKit container/engine until explicitly enabled. A signed CloudKit container and two-device acceptance are still required; unsigned simulator builds leave the toggle unavailable.
- Real device installation is blocked until Xcode has an authenticated developer account and a profile for `app.smail.mobile`. Existing signing certificates alone did not supply those.

## QA

`MobileAcceptanceTests` checks actual native navigation/read flags, unsaved draft updates through Chat, tool-result synthesis across two model rounds, and large Session filtering/input isolation. `scripts/mobile-agent-fixture.py` is a local protocol fixture, not a live model. It never sends mail. Test flags (`--ui-qa`, `--agent-qa`, `--session-scale`, `--semantic-qa`) are for an isolated simulator only.
