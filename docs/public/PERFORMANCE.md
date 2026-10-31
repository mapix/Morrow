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
| iCloud | Separate environment state and private record payloads | Synthetic cross-device receive/update/tombstone/restart checks |

Synthetic benchmarks measure storage and scheduling, not model-quality equivalence. Native verification uses the installed binary. Real-mail tests must keep the requested scope: reading/navigation are separate from authorized flag changes; test messages are never sent to real recipients.

The macOS C/libcurl path retains its request timeout: cancellation stops follow-up work but cannot immediately interrupt a C function already executing. Background sync on iOS depends on foreground/runtime availability. These platform limits are not a claim that every possible mailbox, provider or hardware configuration has been tested.

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

## 0.11.1 cache repair

Header previews are bounded to 300 Swift graphemes both before and after line-ending normalization. CRLF is normalized as a unit. Invalid projections are repaired in bounded batches, releasing the first scan before full-message reads. A request performs at most one repair pass and one verification scan; a persistent failure is reported without recursion. Regression tests cover CRLF, Unicode boundaries, a legacy overlong preview, and a cache that remains invalid after rewriting.
