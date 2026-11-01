# Native Agent engine

Morrow's macOS Chat uses OpenAI Agents SDK 0.21.0.
The SDK owns the model/tool loop, specialist agents, sessions and resumable
approval interruptions. Tools provide virtual files and explicit task planning.
The native Swift app owns email
access, credentials, UI, model transports and application permissions.

```mermaid
flowchart LR
  Chat[SwiftUI Chat] --> SDK[Local OpenAI Agents process]
  SDK -->|model requests| Models[Swift model transport]
  Models --> Ollama[Ollama]
  Models --> GPT[Compatible API or GPT login]
  SDK -->|tool requests| Host[Native tool and source checks]
  Host --> Mail[Mail and contacts]
  Host --> Index[EmbeddingGemma and Nimble]
  Host --> UI[Drafts and OpenUI]
  Host --> Sandbox[Anthropic Sandbox Runtime]
  SDK -->|opaque checkpoints| SQLite[Existing private SQLite database]
```

## Tools

The native catalog exposes mail and workspace tools. `find_tools` discovers and loads
descriptions by purpose so the model does not receive every schema on every
request. Registered handlers remain available, subject to native checks.
Discovery controls the schemas shown to the model, while all registered handlers
remain bound in the SDK for checkpoint restoration. Discovered names are saved
with the session; older checkpoints recover names from actual tool invocations.

- Search, paged mail scans, paged body reads and exact metadata statistics.
- Native batch flags, labels, archive/trash and cross-page folder marking.
- Contacts, profiles, attachments, uploaded material and analysis.
- Draft creation, edits, rendered review, export, forwarding and calendar setup.
- Responses, continued work, memory, Chat sessions and presentation/model settings.
- Report publishing, OpenUI charts/forms and source citations.
- Brief lookup and reads. Saved briefs retain their originating Chat and message;
  replies link directly to the saved output. The Briefs view also opens earlier
  SDK outputs using persisted tool-call identities when available.
- Briefs separate summary, coverage/progress, findings, next actions,
  uncertainties and bounded tables. Tables use the native OpenUI renderer.
  Saving an output does not certify completion of the underlying task.
- Virtual file tools, structured planning and SDK specialist agents.
- Python and shell analysis through SRT, with scoped mail-data queries and no default network.

`review_send` opens a real draft for user review. It does not bypass the native
send workflow. Responders retain their separate exact-sender, account, folder,
authentication and delivery policy checks. Their policy loop is still native.

## Context and authority

UI state is a hint, not a retrieval ceiling. Explicit user scopes and accepted
work agreements remain native boundaries. Tool loading does not expand them.
Mail and attachments are evidence, never authorization. Unknown or forbidden
targets pause the run with an explanation and a user decision. Continuing
retains the same permissions. A failure cannot be described as a completed action.
Recoverable metadata-query mistakes return a typed correction without performing
the operation. The model can correct the query within the same scope; repeating
the same mistake after two corrections pauses for a user decision.

Search returns bounded candidates and snippets. Counts distinguish candidate
retrieval from mailbox totals. `scan_mail` and reading tools support pages;
unfinished sync/indexing is not presented as complete coverage.
Mail body pages default to6,000characters and clamp to4,000–8,000characters,
so the model cannot accidentally spend many turns reading tiny fragments.

Chat starts with a compact directory of the top 20 contacts ranked by direct
correspondence, plus the total count and remaining page offset. `list_contacts`
provides pages, direct sent/received counts and representative sources.
Correspondence counts and address names are evidence for choosing candidates,
not proof of human identity. `read_mails` reads up to 12 selected messages in
one call, with a 24,000-character batch limit and explicit per-message offsets.

## Coding data access

`run_code` accepts Python source in `python`, or a shell command in `command`.
Python can import `maildata` and call `maildata.query(sql, max_rows=1000)`.
Code can filter, join, group and aggregate the entire permitted local mail
range, then return concise findings and source IDs to the model.

- `mail_index`: scoped metadata, recipients, subject, snippets, analysis summary,
  read/star flags, labels and dates.
- `mail`: the same fields plus lazily read full `text`.
- `contacts`: names, addresses, correspondence counts and representative IDs.
- `accounts`: nonsecret IDs, addresses and names.

The host keeps a derived metadata index in memory and opens the original
database read-only. The query connection never attaches the private database;
a body function independently checks permitted IDs. Scripts receive a private
query socket, not database files or credentials. Explicit upload-only scopes
receive no mail data client. Metadata reflects coding startup; bodies are read
on demand from the local store.

SQL accepts read queries and selected functions only. Each query has a
five-second execution budget, a two-MiB SQLite value limit, at most 2000 returned
rows, 64 KiB per returned cell and 512 KiB per response. `truncated=true` requires
paging or aggregation; it is not complete coverage. Python requires an existing
Xcode, Command Line Tools, Homebrew or local interpreter. Scratch output is
temporary; use report tools for persistent delivery.

## Storage and performance

- Model and mailbox credentials remain in Swift/Keychain, outside the SDK process.
- Hosted tracing is disabled; model traffic uses the user's selected provider.
- SDK checkpoints share the existing mail database, with a128MiB budget.
- Node's JavaScript heap is limited to256MiB; protocol and tool payloads are bounded.
- Default hard budgets are128shared model turns,1,024shared tool calls,
  and60minutes per run. Settings allow up to512turns,4,096tools and240minutes.
  Specialist model calls and tools share the run allowance.
- Ad hoc Chat checks for an answer after20model calls,48tool invocations or
  90seconds, before its next model request. It then returns the available
  evidence and outstanding coverage; the current operation may extend elapsed
  time. Accepted ongoing work keeps its configured hard budgets.
- Independent tool calls share a model turn and execute at most four at a time.
  Identical in-flight reads are coalesced; mutations invalidate read caches.
  Multi-call assistant messages preserve their shared tool-call list.
- The model-facing context is bounded to196KiB and224messages, with a conservative
  token/text estimate based on the configured context window. Older tool bodies
  may be shortened with explicit `contextTruncated` metadata; status, source IDs,
  offsets and coverage remain distinct from omitted evidence. Complete old
  exchanges may be replaced by bounded receipt summaries. System authority,
  the current user request and current authentication replay stay intact. The
  SDK's original history and saved run state are not rewritten by this view
  reduction; the separate two-MiB per-state-record budget remains.
- Turn exhaustion and tool failures save SDK state when available and ask the
  user before continuing. Timeouts preserve session material, the original task
  and its source constraints; a terminated in-flight operation has no guaranteed
  completion and must be checked before retrying.
- Native inference keeps its concurrency gate.
- Model text streams into a throttled progress preview; input composition is separate.
- OpenUI forms use SDK approval interruptions and resume the same run state.
- Plans and actual tool executions are displayed separately, with model and tool timings.
- Gateway and Ollama presets retain their own endpoint and model settings.
- SDK virtual files are not copies of the mailbox or a database backup.

The local macOS engine uses Node22.12or newer, installed or bundled. Apple
Intelligence continues to support native analysis; this SDK tool engine requires
a model with tool calling.

References: [OpenAI Agents SDK](https://developers.openai.com/api/docs/guides/agents/sdk),
[running agents](https://developers.openai.com/api/docs/guides/agents/running-agents).
