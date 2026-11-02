# Morrow 0.17.0 UI and runtime acceptance

November 2, 2026. Local macOS build 170 uses the same Developer ID identity as the previous installation. Original application bundles remain available for rollback. This record does not announce a public download release.

## Delivery

- Shared light/dark colors, system typography, compact controls and page hierarchy across the native workbench, mail, chat, contacts, materials, briefs, memory, rules and settings.
- Adaptive small-window mail navigation and reader, preserved conversation input, explicit task continuation and bound questions.
- Correct readonly sent-message records, Sent/Outbox navigation and source links that leave Settings, Drafts and Outbox.
- Original image/PDF previews in the attachment area, expanded previews, PDF paging and whole-page fitting. A real native window displayed both distinct fixture pages and working zoom/fit controls.
- Ordinary new Inbox notifications are independent of AI analysis. IMAP and POP arrival intents survive failed downloads and restarts; history/reset and canonical-copy suppression remain intact.
- The user confirmed seeing a native desktop notification. The temporary system sharing preference was restored. Notification click routing passed navigation regressions; clicking the operating system banner was not observed by automation.
- Automatic mail analysis remains separate local Ollama processing, using the first 1,000 body characters and attachment names. Synchronization, previews and notifications do not call a model API.

## Evidence

| Check | Observed result |
| --- | --- |
| Broad regression suite | 511 tests, 34 environment-dependent skips, zero failures |
| Real readonly keyword query, 50 permitted IDs | 8 attempts; median 2.256 ms, maximum 4.772 ms |
| Synthetic input isolation | 20,000 contacts, 500 sessions, 400 edits in 2.252 ms; zero shared AppModel publications |
| Native mail selection | 5 events; median 0.049 ms, maximum 0.064 ms |
| Local body retrieval | 5 events; median 64.295 ms, maximum 172.511 ms |
| Native document preparation | 4 events; median 23.632 ms, maximum 79.823 ms |
| Runtime at about 78,000 folder rows | 60 seconds without UI actions; CPU mean 6.66%, maximum 40.3%, with background sync enabled |
| Memory | RSS 2,006.53–2,006.62 MB; physical footprint about 1.4 GiB, peak 1.7 GiB; resident embedding model about 517 MiB |
| Main-thread sample | 384 of 390 points in the application event loop; no sustained main-thread stall observed |

The 50-ID query result does not represent full-mailbox search latency. WebKit navigation completion includes external-image loading and cancellation during selection changes. Short runtime samples do not prove long-term absence of leaks.

## Visual and interaction coverage

The main native gallery covers the major surfaces in Chinese at small and normal sizes with light/dark appearances. A supplemental gallery adds wide windows, English small/normal, readonly composition, structured briefs, complete source, attachment failures and question/video/failed/empty chat states. Actual window interaction confirmed small-window HTML display, attachment controls, two-page PDF navigation and fit, and separate multiline Chinese inputs across conversations.

Offscreen `NSView.cacheDisplay` omits some WebKit/PDF compositor pixels. Empty embedded regions in gallery exports are excluded from display acceptance; real window observations are the evidence for these surfaces. Physical Chinese IME interaction was not driven by automation; marked-text and late composition ownership are covered by tests.

Private mail, captures, profiling output and installation receipts remain in ignored private evidence. This quality run initiated no real test email sending or paid media/model generation. Skipped live-environment gates are not reported as passed.
