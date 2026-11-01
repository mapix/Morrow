# Performance verification

Morrow keeps a rebuildable header projection alongside original mail. A projection is not complete evidence and is rejected by full-message writes. Mail, attachment and model credentials remain in their existing local storage.

## Verification matrix

| Operation | Resource strategy | Verification |
| --- | --- | --- |
| Inbox / filters / page selection | Small header records; 25/50/100 rows per page | Pagination, header/full-body consistency and bounded 20,000-message fixtures |
| Read / unread / star / labels | Exact UID groups and transactional metadata updates | Loopback protocol transcript, partial acknowledgements, undo and projection consistency |
| Open mail / rapid navigation | One active body; content revision; cancelled old loads | Full-source contract and lifecycle tests; native window checks |
| Reply / forward / editing | Original mail fetched by ID; versioned HTML export | Original-body preservation, concurrent edit and IME checks |
| Attachments / images | Bounded extraction; background image downsampling | File-size limits, thumbnail bounds, WebKit lifecycle and extraction failures |
| Sync / protocol I/O | Lightweight UID inventories, streaming replies, cancellation | Loopback IMAP/POP/HTTP tests; no body fetch for flag updates |
| Semantic query | Bounded Top-K; detached read-only SQLite ranking | Normalized-vector retrieval plus 20,000 × 768-dimensional storage benchmarks |
| Contacts | Metadata inventory signature; versioned incremental batches | Full-text source, stable flags-only signature and preserved claims |
| Chat / model services | Limited evidence, response bytes, queue and catalogue singleflight | Captured prompt, cancellation, HTTP/SSE limits and complete ID coverage |
| Chat coding | Scoped metadata index and lazy, read-only body queries | Python/SRT execution, SQL aggregation, original-file isolation, scope and truncation checks |
| iCloud | Separate environment state and private record payloads | Synthetic cross-device receive/update/tombstone/restart checks |

Synthetic benchmarks measure storage and scheduling, not model-quality equivalence. Native verification uses the installed binary. Real-mail tests must keep the requested scope: reading/navigation are separate from authorized flag changes; test messages are never sent to real recipients.

The macOS C/libcurl path retains its request timeout: cancellation stops follow-up work but cannot immediately interrupt a C function already executing. These platform limits are not a claim that every possible mailbox, provider or hardware configuration has been tested.

## Synthetic storage results

A bounded 20,000-message fixture produced these measurements on the development Mac. The vector test used finite normalized **768-dimensional synthetic vectors**, not language-model inference. Fixtures were at most 96 MiB and removed after each test.

| Measurement | Observed duration |
| --- | ---: |
| Warm header inventory | 204 ms |
| Page of 40 header records | 3.6 ms |
| Inventory fingerprint | 31 ms |
| 20,000 star changes | 367 ms |
| 20,000 label additions | 481 ms |
| 20,000 × 768 exact vector scan | 1.39 s |
| Vector scan restricted to 50 IDs | 4.6 ms |
| Concurrent single-message lookup during vector scan | 0.2 ms |
| Cancellation of vector scan | 3.0 ms |

These measurements verify the storage path and resource strategy. They do not certify a particular provider's network latency or model quality. Cold projection backfill is a one-time migration cost; original mail remains untouched.

## Read-state feedback and ordering

Opening an unread message and explicit read/unread actions publish their visible
state before waiting for the server. Changes for canonical copies stay within
the same account. Requests for one message run in order; only the latest
pending request controls its displayed state. Reloads retain this pending
choice while accepting fresh unrelated metadata.

Storage is committed after server confirmation. Failed operations restore
confirmed stored flags and preserve notes, stars and body revisions. Batches
keep immediate feedback while retaining UID groups, partial acknowledgements
and undo receipts; unacknowledged rows return to their confirmed state. An
inventory captured before an acknowledgement cannot restore its older flags.

Tests cover delayed acknowledgements, rapid read/unread changes, older and
latest failures, reloads, canonical aliases, unread counts, retry, partial
batches, whole-folder marking and undo. Loopback IMAP tests separately verify
flag commands and partial server receipts. These checks do not replace a real
mail provider acceptance test.

## Desktop interaction and Gmail reuse

Chat input has its own observable state. Typing and debounced draft saves no
longer publish mailbox/contact/conversation updates on the shared AppModel.
Session metadata remains separate from cached draft fields; switching sessions
and normal application exit flush the last edit. A 20,000-contact / 500-session
fixture verifies zero shared-workspace notifications for 400 edits, including
the settled save. Its measured 2.2 ms is draft-state logic, not end-to-end
keyboard or network latency.

Archive and Trash remove pending rows and clear the old reader immediately.
Confirmed COPYUID location changes reuse the complete local message and
independent raw/attachment file links in a transaction; vectors, receipts and
current source references follow the verified new location. Gmail moves that
omit COPYUID use a cached or pre-move global identity and a unique targeted UID
search. These paths do not scan the whole destination or download its body.
Unverified locations remain explicitly pending sync and do not offer a guessed
undo. Failed server operations restore current stored metadata.

Same-folder synchronization excludes saved and durably queued UIDs; a missing
queued raw cache regains download eligibility. Gmail cross-folder reuse requires
matching X-GM-MSGID, RFC822.SIZE, account configuration and UIDVALIDITY. Message-ID
only selects candidates. File paths must belong to the current store, and
separate hard links keep deleting one alias from deleting another's bytes.
Read/star edits newer than the inventory are retained. Progress distinguishes
local reuse, this sync's remaining work and actual new downloads.

## 0.11.1 cache repair

Header previews are bounded to 300 Swift graphemes both before and after line-ending normalization. CRLF is normalized as a unit. Invalid projections are repaired in bounded batches, releasing the first scan before full-message reads. A request performs at most one repair pass and one verification scan; a persistent failure is reported without recursion. Regression tests cover CRLF, Unicode boundaries, a legacy overlong preview, and a cache that remains invalid after rewriting.

## Selection and layout updates

Mail selection now keeps one WebKit reader instead of recreating it per message. Body retrieval uses a short-lived read-only WAL connection with cancellation and a bounded permit queue, separate from background indexing and metadata passes. Current-page selection avoids publishing an unchanged page index. Mail rows compare their displayed inputs and selection state; unrelated agent progress does not invalidate their bodies. Inbox projections do not expire on the snooze clock.

Long chat replies use a bounded eagerly laid-out message window; earlier messages can be opened explicitly. Scroll operations wait until the current layout transaction has finished, preventing the observed SwiftUI lazy-stack layout loop.

Mailbox filtering captures observable scope values once before scanning or sorting. Server flag synchronization reads header summaries and commits only changed flags in bounded batches. Each transaction checks the inventory timestamp, so a newer local edit wins; it preserves body revisions, original MIME, FTS and vectors.

Index verification receipts represent the body revision, sender, subject, date, notes, labels, attachment revisions, model and extraction configuration. Subsequent passes compare these small inputs before opening bodies. A receipt is accepted only while its vector hash/model still match, and is never saved for a concurrent content change. Existing indexes undergo one verification pass; legacy attachments without a reliable revision continue through the full verification path.

Single-message flag, note and analysis changes update ID lookups, primary representatives and attachment source records incrementally. They preserve thread normalization and ordering. Full snapshot validation and projection construction run on a detached utility worker; edits made while that worker runs are applied before publishing. Structural conflicts keep the current snapshot and request a fresh reload.

The mailbox header shares its actual toolbar row with the chat corner control, instead of reserving an empty 56-point strip. Background synchronization has a separate status line with inventory progress, download count and cancellation. Its toolbar control uses a static sync glyph; indeterminate loading inside the search field or reader belongs only to those operations. A stopped sync retains downloaded mail and does not update the successful-sync timestamp.

Contact refresh uses cached header membership and persisted body revisions; only affected contact groups are rebuilt and saved. Full text remains available to bounded AI evidence reads, without loading the entire body corpus into the contact builder. Completed claims are preserved only when their recorded body versions and contact metadata still match. Historical sync coalesces contact updates, merges incoming header batches into the cache and reads only changed flag records. Indexing consumes an ID queue after one startup verification, with receipt reads restricted to that queue. Bulk sync does not repeatedly rerun a visible semantic query; Return refreshes its results on demand.

Default inbox projection filters the already ordered canonical header cache, without another main-thread sort. Explicit archive/custom folder scopes keep their own alias lookup. Index count aggregation is limited to one read per 15 seconds during historical sync, with a final exact read when background work completes.

The obsolete `mail_fts` cache is removed during store initialization. It was never read by the current keyword search, but its unindexed message ID made every save scan the entire virtual table. Keyword evidence remains in `messages.search`; semantic vectors and original mail are preserved. Migration tests verify both search sources and the complete source message after the cache is removed.

Historical IMAP bodies are fetched in batches of at most eight UIDs with `BODY.PEEK[]`. Literal response bytes remain bounded by the transport limit. Bodies are matched to the UID in their enclosing FETCH response, including reordered replies and UID-after-literal servers; ambiguous responses are rejected. Providers that reject the batch use the existing single-message path for the rest of that folder. These batches change request overhead, not server read flags.
