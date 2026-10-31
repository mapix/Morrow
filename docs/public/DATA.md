# Workspace data and migration

Morrow keeps SQLite mail metadata, source mail, attachments, chat assets, and local vectors in its application workspace. The actual path is shown in settings. Credentials remain in Keychain.

To move an existing workspace, stop the application and run `scripts/migrate-workspace.py --from SOURCE --to DESTINATION` for a dry run. Add `--apply` only after reviewing the destination. It requires the same filesystem and moves the directory rather than copying a second mailbox. It verifies mail, chat and vector preservation, updates owned file references, and retains the existing Keychain namespace.

The initial Morrow rename retains compatibility bundle, cloud-zone and credential identifiers so existing accounts do not become unrelated identities. These are internal migration details and not branding in the interface.

Do not use a development evidence directory as a permanent workspace. Never publish the active directory or include it in release artifacts. Updates do not automatically retain database or old application backups.
