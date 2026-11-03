# Morrow native Agent SDK bridge

Pinned OpenAI Agents SDK 0.21.0 runs the model/tool loop, specialist agents,
approval interruptions and persistent sessions. Native tools expose the mail
workspace, sandbox and managed memory. Explicit planning and execution events
are streamed to the SwiftUI progress view.

The Swift host owns model transports, Keychain credentials, email operations,
source checks, sandbox policy and UI updates. This process receives no API keys
or mailbox credentials. Tracing to hosted services is disabled. Filesystem tools
use a private virtual workspace persisted with the session; shell work goes through Anthropic Sandbox
Runtime via a native tool.

Additional native tools are discovered and loaded with `find_tools`, while
registered handlers remain available to the SDK. Loading a tool never expands
its native permissions. Tool failures are observations, not completed actions.

Sessions and resumable SDK state are stored in the existing private mail SQLite database. There is no
second database or mail backup. Runtime state has a 128 MiB storage budget, the
Node heap is limited to 256 MiB, and each run has model/tool/time budgets.

Install with `npm ci --ignore-scripts --no-audit --no-fund`, then run
`node bridge.mjs --self-test`. The local macOS process requires Node 22.12 or newer;
it uses a bundled executable if present, otherwise an installed Node runtime.

Desktop Chat initially receives a compact contact directory and directly sees
`list_contacts`, `read_mails`, and `run_code`. Contact pages include direct
correspondence counts and representative metadata sources; these signals do
not establish that an address belongs to a human. Coding can query the entire
permitted local mail range through the native sandbox data client.

Independent tool calls share a model turn and run with a concurrency limit of
four. Identical in-flight reads are coalesced; mutations invalidate read
caches. Multi-call assistant messages preserve their shared tool-call list.

Ad hoc Chat has an answer checkpoint after 20 model calls, 48 tool invocations,
or 90 seconds, checked before the next model request. It then delivers the
available evidence and explicit coverage gaps. This is not a guaranteed
90-second deadline: the current native operation/model request must finish.
Accepted ongoing work retains its configured hard execution budgets. The hard
model allowance is also shared by delegated runs.

Sidebar workspace run IDs remain UI hints. Only an explicit accepted work
agreement selects ongoing execution budgets; report containers keep the
ordinary Chat checkpoint. A review-required responder setup ends tool use for
that turn and presents the actual configuration state for native review in Chat.
The user clicks the native save action to persist and enable a rule. Image
responders use separately authorized generation and persistent native receipts;
Chat can inspect configurations, request a preview test, and read delivery state.

Model requests use a bounded sending view: at most 196 KiB and 224 messages,
with headroom below the Swift transport limits. The configured context window
also limits total tool-body text and drives a conservative token estimate.
Older tool text is shortened before complete older exchanges are removed;
retained observations keep status, source IDs, pagination and coverage fields.
Removed exchanges retain bounded native receipt metadata so completed actions
are not silently forgotten. `contextTruncated` describes only what the model
can currently see; it never changes an operation's real success or failure.

Ordinary Chat with a large current evidence batch delivers a stage answer.
Ongoing accepted work uses the shortened view to continue. System authority,
the latest user request and active provider replay are preserved. This does
not alter the SDK's original session or resumable run state. Token estimates
are approximate; oversized protected prompts or authenticated replay can still
require a smaller request instead of truncating their authority or identities.
