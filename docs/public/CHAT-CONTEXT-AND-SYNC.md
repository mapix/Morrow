# Chat hints and mail download processing

## Chat

Automatic left-pane context carries `scopeMode: hint`. It supplies stable referents and bounded selected evidence, not a search ceiling. The user's task determines the query: selecting a mail in one account does not prevent searching another account or an archive. Bodies from the entire mailbox are never preloaded as context.

Only an intentional restriction uses `scopeMode: scope`. The UI identifies that restriction and lets the user return to UI hints. Explicit file-only requests, accepted work agreements and responder source allowlists retain their own authority. Existing pinned contexts remain explicit unless they were marked as hints by the app.

## Downloads and processing

The IMAP downloader saves raw mail at its final private cache path and adds a durable processing receipt. A separate utility task parses MIME, stores the lightweight projection, then queues indexes and AI analysis. Downloading does not await vector indexing or AI analysis. No duplicate raw-mail spool or database copy is created.

History fetches request up to64UIDs, with size preflight and a16MiB raw batch budget. The overall response and single-mail safety limits remain64MiB. Oversized or incompatible messages use the existing protected single-message path. Original read flags are preserved with BODY.PEEK.

The persistent processing queue accepts at most32messages/128MiB. A full queue backpressures downloads; processing errors stop further expansion and can be retried. Stopping synchronization cancels networking while already saved jobs remain available for processing or restart. MIME jobs and final message rows share one completion transaction; attachment cache IDs remain stable across retries.

The sync popover reports server size-query time, body-download time, last batch count/bytes, MIME parsing, database writes and pending processing. Network progress is distinct from processing progress; indexed/AI-completed counts remain separate.

## Incremental IMAP and incoming-mail notifications

Both clients retain a per-account, per-folder server cursor: UIDVALIDITY,
HIGHESTMODSEQ, UIDNEXT and the known UID set. The first sync establishes a
complete inventory; existing local messages and durable download jobs are reused.
Later syncs negotiate the authenticated server's standard IMAP capabilities:

- QRESYNC reconciles changed flags and VANISHED UIDs when ENABLE QRESYNC succeeds.
- CONDSTORE fetches only flags changed since the previous mod-sequence. Without
  QRESYNC, UID SEARCH ALL reconciles additions and deletions when SELECT reports
  changes. An unchanged folder requires only SELECT, without a full UID or flag
  query. Servers without modification tracking retain full flag reconciliation.
- A changed UIDVALIDITY, a reset modification sequence or NOMODSEQ requires a
  fresh inventory. Already downloaded bodies are reused while their UIDs remain
  valid. No cursor is advanced on failed inventory or metadata writes.

Remote flag changes, deletion metadata, queued-job flags and the cursor commit
in one database transaction. History bodies download separately. Missing UIDs
are calculated from the persisted inventory and local messages/jobs, so stopping
and restarting does not reset downloaded history. Only these missing messages
count toward download progress. Concurrent local flag edits remain protected.

IDLE uses separate TLS connections for INBOX and an archive (including Gmail's All Mail) when
present. Notifications are coalesced and trigger sync for the affected account;
periodic sync remains as recovery and coverage for other folders or servers
without IDLE. Listening renews every 25 minutes, reconnects with bounded backoff,
and triggers catch-up after reconnecting. History downloads yield between raw
batches when incoming-mail notifications need attention.

macOS listens while the app runs. iOS listens while the app is in the foreground
and catches up on returning to it; background push requires separate platform
support and is not supplied by an IMAP IDLE connection. POP3 remains polled.

Protocol checks use synthetic loopback peers. They cover an unchanged 85,433-UID
folder with no FETCH/SEARCH, CONDSTORE deltas, QRESYNC deletions, UIDVALIDITY
resets, legacy fallback, IDLE/DONE renewal and cancellation, persistent history
receipts, local-edit races and transaction rollback. These checks do not certify
latency or extension support for a particular live provider.
