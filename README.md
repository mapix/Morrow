# Morrow

<img src="website/assets/morrow-icon.png" width="96" alt="Morrow app icon">

An open-source native AI mail partner for macOS. Morrow reads incoming mail, organizes people and files, brings important work forward, and prepares the next action with you.

[Homepage](https://morrow.novarock.io) / [Download](https://github.com/mapix/Morrow/releases) / [中文](docs/public/README.zh-Hans.md)

## What it does

- Connect multiple IMAP/SMTP mailboxes, Gmail through OAuth, or POP3 accounts.
- Build a local 768-dimensional EmbeddingGemma 2 index for semantic search.
- Organize mail by contact and manage attachments in one place.
- Delegate work through persistent chat sessions, files, images and voice.
- Let Chat write Python/SQL to analyze scoped mail and contact data in a read-only sandbox.
- Prepare replies, reports and structured OpenUI interactions.
- Keep editable memories and configure scoped automatic responders.
- Use local models, compatible HTTPS model APIs, or native ChatGPT sign-in.
- Connect external MCP clients through an optional HTTP server with generated, resettable authentication tokens. [Setup and tools](docs/public/MCP-SERVER.md).
- Switch languages, themes and layout density. Optional iCloud workspace sync starts off.

Morrow requires Apple Silicon and macOS 26 or later. Mail credentials remain in Keychain. Optional iCloud sync covers chat, memories, contacts and artifacts across your Macs; each Mac obtains mail from its provider.

## Build

Install Xcode 26, its Metal toolchain, and Python.

```sh
swift package resolve
cp configuration/oauth-clients.example.json configuration/oauth-clients.json
python3 scripts/download-embedding.py
python3 scripts/build-metal.py
zsh scripts/test.sh
zsh scripts/package-app.sh
```

OAuth client configuration is intentionally local and ignored by Git. Configure your own provider application where required; passwords and tokens never belong in this file. Embedding model weights are downloaded separately and are not stored in Git.

See [configuration](docs/public/CONFIGURATION.md), [data and migration](docs/public/DATA.md), and [development](CONTRIBUTING.md). Production signing uses your own prepared Apple credentials and provisioning configuration. Signing credentials and account data are never part of the repository.

## Website

The landing page is static and multilingual. Its downloads come from a release manifest with file size and SHA256. Build it using `website/` as the Docker context. [Website deployment](website/README.md).

## Privacy and security

Mail and chat data stay on this Mac by default. Configured remote models and optional iCloud can receive that data. Enabling MCP lets clients with your token read local mail, contacts and briefs. External mail images load by default and can be disabled in settings or per message; scripts stay blocked. Review the scope and delivery behavior of any automatic responder before enabling it.

[Security policy](SECURITY.md) · [Publication privacy checks](docs/public/PUBLICATION-PRIVACY.md)

Before publishing, preflight the strict public source list, stage only reviewed paths, and check the complete Git index:

```sh
python3 scripts/check-publication.py --worktree
# Stage only the reviewed files; do not use git add .
python3 scripts/check-publication.py --staged
```

The staged check reads staged file bytes and the staged allowlist, including previously tracked files. Every pull request and push runs the same privacy gate. Local mailbox data, evidence, personal OAuth configuration, signing material and unreviewed images must stay outside Git.

## License

Apache License 2.0. Dependency and model licenses remain their own. This is an evolving client; release notes describe tested behavior and remaining limits.
