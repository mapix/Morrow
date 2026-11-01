# Chat hints and mail download processing

## Chat

Automatic left-pane context carries `scopeMode: hint`. It supplies stable referents and bounded selected evidence, not a search ceiling. The user's task determines the query: selecting a mail in one account does not prevent searching another account or an archive. Bodies from the entire mailbox are never preloaded as context.

Only an intentional restriction uses `scopeMode: scope`. The UI identifies that restriction and lets the user return to UI hints. Explicit file-only requests, accepted work agreements and responder source allowlists retain their own authority. Existing pinned contexts remain explicit unless they were marked as hints by the app.

## Downloads and processing

The IMAP downloader saves raw mail at its final private cache path and adds a durable processing receipt. A separate utility task parses MIME, stores the lightweight projection, then queues indexes and AI analysis. Downloading does not await vector indexing or AI analysis. No duplicate raw-mail spool or database copy is created.

History fetches request up to64UIDs, with size preflight and a16MiB raw batch budget. The overall response and single-mail safety limits remain64MiB. Oversized or incompatible messages use the existing protected single-message path. Original read flags are preserved with BODY.PEEK.

The persistent processing queue accepts at most32messages/128MiB. A full queue backpressures downloads; processing errors stop further expansion and can be retried. Stopping synchronization cancels networking while already saved jobs remain available for processing or restart. MIME jobs and final message rows share one completion transaction; attachment cache IDs remain stable across retries.

The sync popover reports server size-query time, body-download time, last batch count/bytes, MIME parsing, database writes and pending processing. Network progress is distinct from processing progress; indexed/AI-completed counts remain separate.
