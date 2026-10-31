# Publication privacy gate

The public repository contains application source, synthetic tests, reproducible build scripts, and sanitized public documentation. Personal mailbox data and local acceptance evidence stay outside the publication set.

Run `python3 scripts/check-publication.py --worktree` to preflight allowlisted source before staging. After staging, run `python3 scripts/check-publication.py --staged`; this reads the complete Git index, including staged bytes that differ from the working tree. An explicit proposed path list can be checked with `--candidate-list`.

The publication gate rejects `evidence/`, `output/`, `.hallmark/`, private runtime directories at any depth, build products, generated Xcode projects, personal OAuth configuration, mailbox databases, raw email, logs, signing material, and unreviewed images. These forbidden directories remain blocked even if an allowlist or reviewed-asset entry mentions them. A finding contains only filename, line number, and category. Token values are never printed.

Use `configuration/oauth-clients.example.json` as a local-configuration template. Each developer registers their own Google OAuth clients and Apple signing/iCloud capabilities. Actual credentials remain in the OS Keychain or an ignored local configuration file.

Raster assets are accepted only beneath `assets/`, `website/assets/`, or the native iOS icon catalog, and when their SHA256 matches an explicit `reviewed_assets` entry. Review image pixels before pinning a hash. Automated string checks cannot establish that screenshots contain no personal data. PNG textual metadata is scanned, and image EXIF metadata is rejected.

This gate is a publication check, not a substitute for reviewing the final staged diff and verifying the remote repository before pushing. Include the publication policy in the reviewed staged set; default index mode reads that staged policy as well as staged file bytes. Every pull request and push runs `.github/workflows/publication-check.yml` with read-only repository permissions and without application credentials. Do not stage the entire working directory with `git add .`.
