# Morrow UI and performance quality plan

## Scope and baseline

The November 2, 2026 quality goal covers the entire native Morrow product: layout, typography, color, controls, interaction states and performance. It is not complete after a theme change or a narrow test run.

Commit `00a118f` preserves the preceding delivery, media, incremental sync, attachment preview and historical design work. The current design replaces the old warm-paper/Coral presentation. Historical documentation is not the current acceptance record.

## Design direction

Morrow is a desktop correspondence workbench for people managing mail and ongoing work. Recognition comes from accurate mail headers, recipients, delivery state, source evidence and continuous task context.

- Surfaces: neutral cool canvas `#F4F5F7`, white content, subdued sidebar `#ECEFF3`.
- Type: macOS system sans; 22pt page titles, 15pt section titles, 13pt controls, 15pt reading text, 11–12pt metadata. Code alone uses monospace.
- Color: dark ink `#212A35`, secondary `#4F5A68`, muted `#667180`, one action blue `#2B61AF`; semantic success and failure are separate.
- Structure: workspace navigation, mail folders and conversations are distinct groups. Each screen has one page header, a functional toolbar and a clear primary object.
- Controls: native desktop heights of 28–32pt, immediate focus, distinct hover/selection/disabled states. No ornamental shadows, nested cards or persistent technical explanations.
- Dark mode uses matching semantic roles. Previous Coral/Forest selections migrate to the new light appearance without changing data or input.

Self critique: a neutral palette alone would preserve the current problems. The work therefore includes hierarchy and density, state-correct sent/queued/uncertain targets, explicit task resumption, compact source references and settings save semantics.

## Required surface coverage

| Surface | Required evidence |
| --- | --- |
| Window/navigation/account/session switching | Native screenshots at small/normal/wide sizes; keyboard and preserved input |
| Work home and current work document | Empty/populated, waiting/active/completed, source navigation and saved output |
| Inbox, Sent, Outbox, Drafts and search | Density, long subject/sender, pagination, per-account scope, delivery state |
| Reader and attachment section | Original HTML/plain text, sent recipients, image/PDF, loading/error/remote-only |
| Composer and preview | To/CC/BCC, attachments, schedule, live readonly transition, saved edits |
| Chat, forms, execution and media | Streaming/paused/failed/completed, new request vs task continuation, bound forms |
| Contacts and knowledge | Large index, profile, source mail, empty/loading/error |
| Attachments and materials | List/grid, original preview, filters, selection and source navigation |
| Briefs, history and library | Read/edit/version/source context with consistent hierarchy |
| Memory | Scope, validity, proposed/active/paused/expired/history and actions |
| Responders and delegation | Accurate authority, source rules, preview, pause, delivery receipts |
| Settings/account/login/budget/calendar | All categories, save/failed states, expanded forms, shorter windows |
| Native OpenUI and charts | Same controls, tables, forms, categorical colors and source-backed values |
| Desktop notifications | New Inbox arrivals notify promptly with granted permission; no history backfill or duplicate-copy spam; independent of slow AI analysis |
| App identity and public product material | Small icon readability and consistency; no private data in public captures |

## Performance requirements and measurement

Use both bounded synthetic fixtures and the current mailbox scale. Separate network/model latency from local interaction latency, and active background work from idle.

- Cached navigation and page changes should respond immediately; measure p50/p95 and main-thread stalls.
- Typing must not republish the mailbox or contact corpus. Verify IME and session switches under background work.
- Cached body and preview must load asynchronously and reject obsolete results. Record memory and cancellation.
- Search with a small allowed-ID set must operate on that set, be cancellable and not monopolize the write actor.
- Protocol sync must use saved cursors and bounded work. Long agent jobs must not delay scheduled sending or catch-up sync.
- Contact analysis, indexing and delivery reconciliation must avoid repeated whole-corpus work and large main-thread encoding.
- Track resident memory, idle CPU, background CPU, task/process lifetime and completion/cancellation cleanup.

Preserve account/UIDVALIDITY identity, canonical references, original evidence, delivery immutability, no automatic SMTP retry, local-only automatic analysis and session workspace isolation.

## Closure

Completion requires a source/commit audit, broad regression coverage, native rendered surface review, interaction checks and measured performance. Static renders are not proof of keyboard behavior; tests are not proof of visual finish. Unverified or tool-blocked checks remain open.

Private production captures and mailbox measurements stay under `evidence/private/`. Public examples use synthetic mail. Paid inference or real test sending is not part of this quality run.
