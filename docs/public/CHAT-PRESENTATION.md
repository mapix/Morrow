# Chat presentation and drafts

Sidechat renders OpenUI Lang using Morrow's native profile0.2.0. Read-only BarChart, LineChart, PieChart, Steps and Table results attach to their actual reply and conversation, persist alongside that reply, and remain visible in history. Display charts do not pause authorized operations; forms that require user input do.

Statistics tools provide actual category/month aggregates. Chart requests prioritize OpenUI and have a native fallback from those aggregates. Missing, nonfinite, oversized or invalid chart data is rejected instead of plotted. Mail citations retain the original reply's source boundary.

Markdown uses Swift Markdown/cmark-GFM block parsing, with independent headings, paragraphs, nested lists, task lists, quotes, tables and code blocks. Soft/hard newlines remain explicit. An outer `markdown` code fence is unwrapped; code and literal escapes stay intact.

With Chat focused, Command+Return/Enter or Control+Return/Enter submits once. Plain Enter inserts a new line. Key repeats, unfinished IME composition and a busy conversation do not trigger another request or stop the existing one. Clicking Stop remains an explicit action.

The persistent Drafts sidebar entry collects local manual drafts, AI drafts and queued messages across connected accounts. Subject, recipient, body and sender-mailbox filters help locate a draft. Each AI writing result carries the actual saved draft identifier, with an Edit/Preview card in Chat. Completion opens the saved draft on the left if the user is still in the original conversation and workspace; otherwise the user can open its card later.

The composer has an explicit message Preview using the same sanitized HTML/plain-text rendering engine as original mail. Preview does not queue or send a message. Recipient review and the existing send controls remain the final delivery step.
