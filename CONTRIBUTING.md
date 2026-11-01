# Contributing

Use synthetic mail and reserved example domains for development. Never include a real mailbox, credentials, private screenshots, provisioning profiles, logs, or model weights in a commit.

Run `zsh scripts/test.sh` for the local mail protocol fixtures and core tests. Live Metal tests are opt-in; they use synthetic workspaces. For UI work, verify macOS window resizing, keyboard navigation, Chinese/Japanese input composition, and reduced motion.

Before committing, run `python3 scripts/check-publication.py --staged`. The checker reads actual Git index bytes and validates every staged file, including reviewed raster asset hashes. Keep configuration secrets in ignored local files or Keychain.

Submit a focused pull request with the behavior changed and relevant verification. Discuss changes to public protocols, cloud sync formats, or data migrations before merging them.
