# Security

Report vulnerabilities privately using this repository's GitHub security advisory workflow. Do not post mailbox contents, tokens, secrets, or reproducible credential-bearing URLs in a public issue.

Morrow stores credentials in the system Keychain, rejects executable mail scripts, and constrains mail agent operations to captured workspace scopes. A compatible remote model receives the content you send to it; choose providers accordingly. iCloud synchronization is optional. The local database is not encrypted by the app; use operating-system disk encryption where appropriate.

Do not publish signing files or personal OAuth applications. Public releases must pass the publication allowlist and secret scan. These checks complement review and do not establish that every third-party input is safe.
