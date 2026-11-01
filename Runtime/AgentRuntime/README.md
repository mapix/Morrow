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
iOS retains its native planner until a supported SDK execution host is configured.
